import Foundation
import JackKnowledgeKit

// MARK: - MCPServer

/// Model Context Protocol server over Jack's knowledge base.
/// Transport-agnostic: `handle(line:)` takes one JSON-RPC message and returns
/// the serialized response line, or nil for notifications.
public final class MCPServer: Sendable {
    public static let protocolVersion = "2025-06-18"
    public static let serverName = "jack-knowledge"

    private let knowledge: KnowledgeService
    private let version: String

    public init(knowledge: KnowledgeService, version: String = "1.0.0") {
        self.knowledge = knowledge
        self.version = version
    }

    // MARK: - Transport entry point

    /// Process one incoming line. Returns the response JSON (single line, no
    /// trailing newline) or nil when no response should be sent.
    public func handle(line: String) async -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let request: JSONRPCRequest
        do {
            request = try JSONDecoder().decode(JSONRPCRequest.self, from: Data(trimmed.utf8))
        } catch {
            return encode(JSONRPCResponse(id: nil, error: .parseError()))
        }

        let response = await dispatch(request)
        return response.map(encode)
    }

    // MARK: - Dispatch

    public func dispatch(_ request: JSONRPCRequest) async -> JSONRPCResponse? {
        switch request.method {
        case "initialize":
            return JSONRPCResponse(id: request.id, result: initializeResult(params: request.params))
        case "notifications/initialized", "notifications/cancelled":
            return nil
        case "ping":
            return JSONRPCResponse(id: request.id, result: .object([:]))
        case "tools/list":
            return JSONRPCResponse(id: request.id, result: toolsListResult())
        case "tools/call":
            return await toolsCall(request)
        default:
            // Notifications for unknown methods get no response per JSON-RPC.
            guard let id = request.id else { return nil }
            return JSONRPCResponse(id: id, error: .methodNotFound(request.method))
        }
    }

    // MARK: - initialize

    private func initializeResult(params: JSONValue?) -> JSONValue {
        // Echo the client's protocol version when it's one we can speak.
        let requested = params?["protocolVersion"]?.stringValue
        let known = ["2024-11-05", "2025-03-26", "2025-06-18"]
        let negotiated = (requested.flatMap { known.contains($0) ? $0 : nil }) ?? Self.protocolVersion
        return .object([
            "protocolVersion": .string(negotiated),
            "capabilities": .object(["tools": .object([:])]),
            "serverInfo": .object([
                "name": .string(Self.serverName),
                "version": .string(version),
            ]),
        ])
    }

    // MARK: - tools/list

    private func toolsListResult() -> JSONValue {
        let sourceEnum = JSONValue.array(KnowledgeSource.allCases.map { .string($0.rawValue) })
        let searchTool = JSONValue.object([
            "name": .string("search_knowledge"),
            "description": .string(
                "Semantic search over everything the user has ever dictated with Jack "
                + "(voice notes, dictations, todos, chat messages, and OCR text from note screenshots). "
                + "Returns the most relevant entries with timestamps."
            ),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Natural-language search query."),
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Max results (default 10, max 50)."),
                    ]),
                    "source": .object([
                        "type": .string("string"),
                        "enum": sourceEnum,
                        "description": .string("Optionally restrict to one source type."),
                    ]),
                ]),
                "required": .array([.string("query")]),
            ]),
        ])
        let recentTool = JSONValue.object([
            "name": .string("recent_entries"),
            "description": .string(
                "List the most recent knowledge-base entries (things the user said), newest first."
            ),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Max results (default 20, max 100)."),
                    ]),
                    "source": .object([
                        "type": .string("string"),
                        "enum": sourceEnum,
                        "description": .string("Optionally restrict to one source type."),
                    ]),
                    "since": .object([
                        "type": .string("string"),
                        "description": .string("ISO-8601 timestamp; only entries at or after this moment."),
                    ]),
                ]),
            ]),
        ])
        return .object(["tools": .array([searchTool, recentTool])])
    }

    // MARK: - tools/call

    private func toolsCall(_ request: JSONRPCRequest) async -> JSONRPCResponse? {
        guard let id = request.id else { return nil }
        guard let name = request.params?["name"]?.stringValue else {
            return JSONRPCResponse(id: id, error: .invalidParams("Missing tool name"))
        }
        let arguments = request.params?["arguments"] ?? .object([:])

        switch name {
        case "search_knowledge":
            guard let query = arguments["query"]?.stringValue, !query.isEmpty else {
                return JSONRPCResponse(id: id, error: .invalidParams("search_knowledge requires a non-empty 'query'"))
            }
            let limit = min(max(arguments["limit"]?.intValue ?? 10, 1), 50)
            let source = arguments["source"]?.stringValue.flatMap(KnowledgeSource.init(rawValue:))
            let result = await knowledge.search(query: query, limit: limit, source: source)
            var payload: [String: JSONValue] = [
                "results": .array(result.hits.map { hitJSON($0) }),
                "search_mode": .string(result.usedVectorSearch ? "semantic" : "substring_fallback"),
            ]
            if !result.usedVectorSearch {
                payload["note"] = .string(
                    "Embedding model assets are not available; results come from substring matching."
                )
            }
            return JSONRPCResponse(id: id, result: toolResult(payload))

        case "recent_entries":
            let limit = min(max(arguments["limit"]?.intValue ?? 20, 1), 100)
            let source = arguments["source"]?.stringValue.flatMap(KnowledgeSource.init(rawValue:))
            let since = arguments["since"]?.stringValue.flatMap { ISO8601DateFormatter().date(from: $0) }
            let entries = await knowledge.recent(limit: limit, source: source, since: since)
            let payload: [String: JSONValue] = [
                "results": .array(entries.map { entryJSON($0, score: nil) }),
            ]
            return JSONRPCResponse(id: id, result: toolResult(payload))

        default:
            return JSONRPCResponse(id: id, error: .invalidParams("Unknown tool: \(name)"))
        }
    }

    // MARK: - Serialization helpers

    private func hitJSON(_ hit: KnowledgeSearchHit) -> JSONValue {
        entryJSON(hit.entry, score: hit.score)
    }

    private func entryJSON(_ entry: KnowledgeEntry, score: Float?) -> JSONValue {
        var object: [String: JSONValue] = [
            "text": .string(entry.text),
            "source": .string(entry.source.rawValue),
            "timestamp": .string(entry.ts),
        ]
        if let score { object["score"] = .number(Double(score)) }
        if let dayStamp = entry.dayStamp { object["dayStamp"] = .string(dayStamp) }
        if let imagePath = entry.imagePath { object["imagePath"] = .string(imagePath) }
        if let sourceApp = entry.sourceApp { object["sourceApp"] = .string(sourceApp) }
        return .object(object)
    }

    /// Wrap a payload in the MCP tool-result content envelope.
    private func toolResult(_ payload: [String: JSONValue]) -> JSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let text = (try? encoder.encode(JSONValue.object(payload)))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return .object([
            "content": .array([
                .object(["type": .string("text"), "text": .string(text)])
            ]),
            "isError": .bool(false),
        ])
    }

    private func encode(_ response: JSONRPCResponse) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(response),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Encoding failure"}}"#
        }
        return text
    }
}
