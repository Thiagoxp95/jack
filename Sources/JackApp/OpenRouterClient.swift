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
