import Foundation

/// Which provider transcription cleanup calls. Cleanup is the one hot-path LLM
/// call in Jack — it sits between the last word spoken and the paste — so it is
/// the one place where routing to Groq's inference hardware instead of
/// OpenRouter's aggregation is worth a second key. Routing and chat stay on
/// OpenRouter; they are not latency-critical in the same way.
enum CleanupProvider: String, CaseIterable, Identifiable, Sendable {
    case openRouter = "openrouter"
    case groq = "groq"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .openRouter: return "OpenRouter"
        case .groq: return "Groq"
        }
    }

    /// Parse a stored value, falling back to the shipped default rather than
    /// failing — an unknown string on disk means a downgrade, not a crash.
    static func resolve(_ stored: String?) -> CleanupProvider {
        stored.flatMap(CleanupProvider.init(rawValue:)) ?? .openRouter
    }
}

/// Thin Groq client for cleanup. Groq exposes an OpenAI-compatible surface, so
/// this is nearly the same request as `OpenRouterClient` — kept separate rather
/// than parameterised because the two differ in exactly the places that matter:
/// Groq rejects unknown body fields (no `reasoning` object), has no pricing in
/// its catalog, and lists speech models alongside chat ones.
enum GroqClient {

    static let chatCompletionsURL = "https://api.groq.com/openai/v1/chat/completions"
    static let modelsURL = "https://api.groq.com/openai/v1/models"

    /// Groq's smallest instruct model. Cleanup is a rewrite, not reasoning, and
    /// this is the one on Groq that finishes fastest — which is the entire
    /// reason to point cleanup at Groq in the first place.
    static let defaultCleanupModel = "llama-3.1-8b-instant"

    enum Failure: LocalizedError {
        case missingKey
        case http(status: Int, body: String)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .missingKey:
                return "No Groq API key set. Add one in Settings → Transcription Cleanup."
            case let .http(status, body):
                return "Groq HTTP \(status): \(body)"
            case .malformedResponse:
                return "Unexpected response shape from Groq."
            }
        }

        var isAuthFailure: Bool {
            switch self {
            case .missingKey: return true
            case let .http(status, _): return status == 401 || status == 403
            case .malformedResponse: return false
            }
        }

        var userFacingSummary: String {
            switch self {
            case .missingKey:
                return "No Groq key set"
            case let .http(status, _) where status == 401 || status == 403:
                return "Groq rejected your API key (\(status))"
            case let .http(status, _):
                return "Groq error \(status)"
            case .malformedResponse:
                return "Unexpected reply from Groq"
            }
        }
    }

    // MARK: - Completions

    static func complete(
        model: String,
        messages: [OpenRouterClient.Message],
        apiKey: String,
        maxTokens: Int,
        timeout: TimeInterval
    ) async throws -> String {
        guard !apiKey.isEmpty else { throw Failure.missingKey }
        guard let url = URL(string: chatCompletionsURL) else { throw Failure.malformedResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeout

        // Same trap as OpenRouter: Qwen3 reasons by default and spends the whole
        // budget before writing a word.
        let lowercased = model.lowercased()
        let isQwen3 = lowercased.contains("qwen3") || lowercased.contains("qwen-3")

        var body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "max_tokens": maxTokens,
            "messages": messages.map { message -> [String: String] in
                let content = (isQwen3 && message.role == "user")
                    ? "\(message.content) /no_think"
                    : message.content
                return ["role": message.role, "content": content]
            },
        ]
        // Only the gpt-oss family accepts this; sending it to a Llama model is a
        // 400, which is why it is not set unconditionally the way OpenRouter's
        // `reasoning` object is.
        if lowercased.contains("gpt-oss") {
            body["reasoning_effort"] = "low"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            throw Failure.http(status: status, body: String(data: data.prefix(400), encoding: .utf8) ?? "")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            throw Failure.malformedResponse
        }

        return content
    }

    // MARK: - Catalog

    /// Groq's catalog mixes chat models with speech ones (Whisper, PlayAI TTS).
    /// Those 400 on `/chat/completions`, so they are dropped here rather than
    /// offered in a picker that only feeds cleanup.
    static func isChatModel(id: String) -> Bool {
        let lowercased = id.lowercased()
        let speechMarkers = ["whisper", "tts", "playai"]
        return !speechMarkers.contains { lowercased.contains($0) }
    }

    /// Unlike OpenRouter's, this catalog requires a key — there is no anonymous
    /// listing endpoint.
    static func fetchModels(apiKey: String) async throws -> [LLMModelInfo] {
        guard !apiKey.isEmpty else { throw Failure.missingKey }
        guard let url = URL(string: modelsURL) else { throw Failure.malformedResponse }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            throw Failure.http(status: status, body: String(data: data.prefix(400), encoding: .utf8) ?? "")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]]
        else {
            throw Failure.malformedResponse
        }

        return parseModels(items)
    }

    /// Split out so the catalog's shape can be tested without a network.
    static func parseModels(_ items: [[String: Any]]) -> [LLMModelInfo] {
        items.compactMap { item -> LLMModelInfo? in
            guard let id = item["id"] as? String, isChatModel(id: id) else { return nil }
            // A deactivated model still lists but fails at request time.
            if let active = item["active"] as? Bool, !active { return nil }
            return LLMModelInfo(
                id: id,
                // Groq has no display names — the id is the name everywhere in
                // its own docs and console.
                name: id,
                contextLength: (item["context_window"] as? NSNumber)?.intValue,
                // Groq is paid-only; a free badge here would be a lie.
                isFree: false
            )
        }
        .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }
}
