import Foundation

/// One model as advertised by OpenRouter's public catalog.
struct OpenRouterModelInfo: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let contextLength: Int?
    let isFree: Bool

    /// "Gemini 2.0 Flash — 1M ctx"
    var displayName: String {
        guard let contextLength, contextLength > 0 else { return name }
        return "\(name) — \(Self.formatContext(contextLength))"
    }

    private static func formatContext(_ tokens: Int) -> String {
        if tokens >= 1_000_000 { return "\(tokens / 1_000_000)M ctx" }
        if tokens >= 1_000 { return "\(tokens / 1_000)K ctx" }
        return "\(tokens) ctx"
    }
}

/// Thin OpenRouter client. Calls go straight from this Mac to openrouter.ai
/// with the user's own key — there is no Jack backend in the path.
enum OpenRouterClient {

    static let chatCompletionsURL = "https://openrouter.ai/api/v1/chat/completions"
    static let modelsURL = "https://openrouter.ai/api/v1/models"

    /// Fast, cheap, and — unlike 2.5 Flash Lite — reliable at treating the
    /// transcript as data instead of answering questions inside it.
    static let defaultCleanupModel = "google/gemini-3.1-flash-lite"
    /// Note-vs-todo is a one-line classification; a cheaper model is plenty.
    static let defaultRoutingModel = "google/gemini-2.5-flash-lite"

    /// The chat sheet's default. Unlike cleanup and routing, this one is a
    /// conversation the user reads, so it gets a general-purpose model rather
    /// than the cheapest thing that can follow an instruction.
    static let defaultChatModel = "anthropic/claude-sonnet-5"

    /// Chat defaults Jack shipped before. `anthropic/claude-sonnet-4` still
    /// resolves at OpenRouter, so this is not about a dead id — it is that the
    /// value was never chosen by anyone. Chat has been broken since accounts
    /// were removed, so nothing ever wrote `chat_last_used_model`; any copy of
    /// it on disk is the old hardcoded fallback leaking into storage.
    static let supersededChatDefaults: Set<String> = ["anthropic/claude-sonnet-4"]

    /// Resolve the stored chat-model preference, re-pointing the stale default.
    static func resolveChatModel(_ stored: String?) -> String {
        guard let stored, !stored.isEmpty else { return defaultChatModel }
        return supersededChatDefaults.contains(stored) ? defaultChatModel : stored
    }

    /// Model ids Jack once shipped as defaults that OpenRouter has since
    /// retired. Stored settings pointing at these are silently re-pointed.
    static let retiredDefaults: Set<String> = ["google/gemini-2.0-flash-001"]

    /// Cleanup models Jack shipped as the default before and has since moved
    /// off, plus the unversioned "latest" aliases — those silently drift onto
    /// whatever Google promotes next, which is how a cleanup setting ends up on
    /// a model nobody chose. These still work, so they are only re-pointed by
    /// the one-time migration in `DictationController` — never on every launch,
    /// or a user who deliberately picks one would have it overwritten forever.
    static let supersededCleanupDefaults: Set<String> = [
        "google/gemini-2.5-flash-lite",
        "google/gemini-flash-latest",
        "~google/gemini-flash-latest",
        "google/gemini-flash-lite-latest",
        "~google/gemini-flash-lite-latest",
    ]

    struct Message {
        let role: String
        let content: String

        static func system(_ content: String) -> Message { Message(role: "system", content: content) }
        static func user(_ content: String) -> Message { Message(role: "user", content: content) }
    }

    enum Failure: LocalizedError {
        case missingKey
        case http(status: Int, body: String)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .missingKey:
                return "No OpenRouter API key set. Add one in Settings → Transcription Cleanup."
            case let .http(status, body):
                return "OpenRouter HTTP \(status): \(body)"
            case .malformedResponse:
                return "Unexpected response shape from OpenRouter."
            }
        }

        /// A rejected key is a user-fixable configuration problem, not a blip.
        /// Callers that otherwise swallow errors (the router, cleanup) use this
        /// to decide what deserves saying out loud — a 401 means every
        /// subsequent capture will fail the same way until the key is replaced,
        /// whereas a 429 or a 502 will likely be gone by the next one.
        var isAuthFailure: Bool {
            switch self {
            case .missingKey: return true
            case let .http(status, _): return status == 401 || status == 403
            case .malformedResponse: return false
            }
        }

        /// Short enough for a status line; the full body goes to the log.
        var userFacingSummary: String {
            switch self {
            case .missingKey:
                return "No OpenRouter key set"
            case let .http(status, _) where status == 401 || status == 403:
                return "OpenRouter rejected your API key (\(status))"
            case let .http(status, _):
                return "OpenRouter error \(status)"
            case .malformedResponse:
                return "Unexpected reply from OpenRouter"
            }
        }
    }

    // MARK: - Completions

    static func complete(
        model: String,
        messages: [Message],
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
        // OpenRouter uses these for attribution on its model-usage leaderboards.
        request.setValue("https://github.com/Thiagoxp95/jack", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Jack", forHTTPHeaderField: "X-Title")
        request.timeoutInterval = timeout

        // Qwen3 reasons by default and burns the whole token budget before answering.
        let lowercased = model.lowercased()
        let isQwen3 = lowercased.contains("qwen3") || lowercased.contains("qwen-3")

        let body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "max_tokens": maxTokens,
            // Cleanup and routing need zero reasoning, and thinking tokens are
            // pure latency on the paste hot path. OpenRouter drops this for
            // providers that don't support it.
            "reasoning": ["enabled": false],
            "messages": messages.map { message -> [String: String] in
                let content = (isQwen3 && message.role == "user")
                    ? "\(message.content) /no_think"
                    : message.content
                return ["role": message.role, "content": content]
            },
        ]
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

    // MARK: - Streaming

    /// One line of an OpenRouter SSE stream, reduced to what chat cares about.
    enum StreamEvent: Equatable {
        case token(String)
        case done
        /// Keep-alive comments, blank separators, role-only first deltas, and
        /// anything unparseable. A malformed line is skipped rather than thrown
        /// on: one bad frame should not discard a reply that is already
        /// half-rendered on screen.
        case ignore
    }

    /// Pure so the stream's grammar can be tested without a network.
    static func parseStreamLine(_ line: String) -> StreamEvent {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // OpenRouter sends ": OPENROUTER PROCESSING" comments to hold the
        // connection open while a provider is still cold.
        guard trimmed.hasPrefix("data:") else { return .ignore }

        let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }

        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let content = delta["content"] as? String,
              !content.isEmpty
        else { return .ignore }

        return .token(content)
    }

    /// Stream a chat completion, yielding content deltas as they arrive.
    ///
    /// The stream finishes on `data: [DONE]` or when the body ends, and throws
    /// a `Failure` for anything the caller should show the user. Cancelling the
    /// consuming task tears the HTTP request down with it.
    static func streamChat(
        model: String,
        messages: [Message],
        apiKey: String,
        timeout: TimeInterval = 120
    ) -> AsyncThrowingStream<String, Swift.Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    guard !apiKey.isEmpty else { throw Failure.missingKey }
                    guard let url = URL(string: chatCompletionsURL) else { throw Failure.malformedResponse }

                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("https://github.com/Thiagoxp95/jack", forHTTPHeaderField: "HTTP-Referer")
                    request.setValue("Jack", forHTTPHeaderField: "X-Title")
                    request.timeoutInterval = timeout

                    let body: [String: Any] = [
                        "model": model,
                        "stream": true,
                        "messages": messages.map { ["role": $0.role, "content": $0.content] },
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1

                    guard status == 200 else {
                        // The error body arrives down the same byte stream, so
                        // it has to be drained to be reported at all.
                        var detail = ""
                        for try await line in bytes.lines {
                            detail += line
                            if detail.count > 400 { break }
                        }
                        throw Failure.http(status: status, body: String(detail.prefix(400)))
                    }

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        switch parseStreamLine(line) {
                        case .token(let content):
                            continuation.yield(content)
                        case .done:
                            continuation.finish()
                            return
                        case .ignore:
                            continue
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in work.cancel() }
        }
    }

    // MARK: - Catalog

    /// The model catalog is public — the key is sent when present only so
    /// OpenRouter can surface models gated to that account.
    static func fetchModels(apiKey: String) async throws -> [OpenRouterModelInfo] {
        guard let url = URL(string: modelsURL) else { throw Failure.malformedResponse }

        var request = URLRequest(url: url)
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
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

        return items.compactMap { item -> OpenRouterModelInfo? in
            guard let id = item["id"] as? String else { return nil }
            let pricing = item["pricing"] as? [String: Any]
            let promptPrice = (pricing?["prompt"] as? String).flatMap(Double.init) ?? 1
            let completionPrice = (pricing?["completion"] as? String).flatMap(Double.init) ?? 1
            return OpenRouterModelInfo(
                id: id,
                name: (item["name"] as? String) ?? id,
                contextLength: (item["context_length"] as? NSNumber)?.intValue,
                isFree: promptPrice == 0 && completionPrice == 0
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
