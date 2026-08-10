import Foundation
import JackKnowledgeKit
import JackMCPCore

// JackMCP — stdio MCP server over Jack's local knowledge base.
// Reads newline-delimited JSON-RPC 2.0 from stdin, writes responses to stdout.
// All logging goes to stderr; stdout carries protocol messages only.

let knowledge = KnowledgeService(
    readOnly: true, // the app is the sole writer
    allowsAssetRequests: false // never trigger a model download from a headless process
)
let server = MCPServer(
    knowledge: knowledge,
    version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
)

FileHandle.standardError.write(Data("[JackMCP] serving knowledge base at \(KnowledgeStore.defaultDirectoryURL().path)\n".utf8))

while let line = readLine(strippingNewline: true) {
    let response = await server.handle(line: line)
    if let response {
        FileHandle.standardOutput.write(Data((response + "\n").utf8))
    }
}
// stdin EOF → clean exit.
