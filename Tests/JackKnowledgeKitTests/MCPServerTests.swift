import Foundation
import Testing
@testable import JackKnowledgeKit
@testable import JackMCPCore

// MARK: - Helpers

private func makeServer() -> (MCPServer, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("jack-mcp-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let knowledge = KnowledgeService(directoryURL: dir, readOnly: false, allowsAssetRequests: false)
    return (MCPServer(knowledge: knowledge, version: "test"), dir)
}

private func json(_ line: String) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
    return object as? [String: Any] ?? [:]
}

// MARK: - Tests

@Suite("MCPServer")
struct MCPServerTests {

    @Test("initialize handshake")
    func initializeHandshake() async throws {
        let (server, dir) = makeServer()
        defer { try? FileManager.default.removeItem(at: dir) }

        let response = await server.handle(
            line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}"#
        )
        let object = try json(try #require(response))
        let result = try #require(object["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        let serverInfo = try #require(result["serverInfo"] as? [String: Any])
        #expect(serverInfo["name"] as? String == "jack-knowledge")
    }

    @Test("initialized notification gets no response")
    func initializedNotification() async throws {
        let (server, dir) = makeServer()
        defer { try? FileManager.default.removeItem(at: dir) }
        let response = await server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        #expect(response == nil)
    }

    @Test("tools/list exposes both tools")
    func toolsList() async throws {
        let (server, dir) = makeServer()
        defer { try? FileManager.default.removeItem(at: dir) }

        let response = await server.handle(line: #"{"jsonrpc":"2.0","id":"a","method":"tools/list"}"#)
        let object = try json(try #require(response))
        #expect(object["id"] as? String == "a") // string id round-trips
        let result = try #require(object["result"] as? [String: Any])
        let tools = try #require(result["tools"] as? [[String: Any]])
        #expect(Set(tools.compactMap { $0["name"] as? String }) == ["search_knowledge", "recent_entries"])
    }

    @Test("tools/call search_knowledge returns stored entries")
    func toolsCallSearch() async throws {
        let (server, dir) = makeServer()
        defer { try? FileManager.default.removeItem(at: dir) }

        let knowledge = KnowledgeService(directoryURL: dir, allowsAssetRequests: false)
        _ = await knowledge.ingest(text: "remember to renew the passport", source: .note)

        let response = await server.handle(
            line: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"search_knowledge","arguments":{"query":"passport"}}}"#
        )
        let object = try json(try #require(response))
        let result = try #require(object["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        let text = try #require(content.first?["text"] as? String)
        #expect(text.contains("passport"))
    }

    @Test("tools/call recent_entries returns newest first")
    func toolsCallRecent() async throws {
        let (server, dir) = makeServer()
        defer { try? FileManager.default.removeItem(at: dir) }

        let knowledge = KnowledgeService(directoryURL: dir, allowsAssetRequests: false)
        _ = await knowledge.ingest(text: "older thing", source: .paste, date: Date(timeIntervalSinceNow: -100))
        _ = await knowledge.ingest(text: "newer thing", source: .paste)

        let response = await server.handle(
            line: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"recent_entries","arguments":{"limit":1}}}"#
        )
        let object = try json(try #require(response))
        let result = try #require(object["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        let text = try #require(content.first?["text"] as? String)
        #expect(text.contains("newer thing"))
        #expect(!text.contains("older thing"))
    }

    @Test("unknown method is -32601")
    func unknownMethod() async throws {
        let (server, dir) = makeServer()
        defer { try? FileManager.default.removeItem(at: dir) }
        let response = await server.handle(line: #"{"jsonrpc":"2.0","id":4,"method":"bogus/method"}"#)
        let object = try json(try #require(response))
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32601)
    }

    @Test("unknown tool is -32602")
    func unknownTool() async throws {
        let (server, dir) = makeServer()
        defer { try? FileManager.default.removeItem(at: dir) }
        let response = await server.handle(
            line: #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"nope","arguments":{}}}"#
        )
        let object = try json(try #require(response))
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32602)
    }

    @Test("malformed JSON is -32700")
    func malformedJSON() async throws {
        let (server, dir) = makeServer()
        defer { try? FileManager.default.removeItem(at: dir) }
        let response = await server.handle(line: "this is not json")
        let object = try json(try #require(response))
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32700)
    }

    @Test("ping returns empty object")
    func ping() async throws {
        let (server, dir) = makeServer()
        defer { try? FileManager.default.removeItem(at: dir) }
        let response = await server.handle(line: #"{"jsonrpc":"2.0","id":6,"method":"ping"}"#)
        let object = try json(try #require(response))
        let result = try #require(object["result"] as? [String: Any])
        #expect(result.isEmpty)
    }
}
