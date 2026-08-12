import Foundation

/// A chat thread. Persisted on disk by `LocalChatStore`.
///
/// These used to be `ConvexChatThread`/`ConvexChatMessage` and were read back
/// from a backend. Nothing about them is Convex-shaped any more — the ids are
/// UUIDs Jack mints itself and the timestamps are stamped on this Mac — so the
/// names no longer carry a lie.
struct ChatThread: Identifiable, Codable, Sendable, Equatable {
    var id: String
    var title: String
    /// OpenRouter model id, e.g. `anthropic/claude-sonnet-5`.
    var model: String
    var spaceId: String?
    var createdAt: Double         // ms since epoch
    var updatedAt: Double         // ms since epoch
}

/// One turn in a thread.
struct ChatMessage: Identifiable, Codable, Sendable, Equatable {
    var id: String
    var threadId: String
    var role: String              // "user" or "assistant"
    var content: String
    /// Which model produced this turn. Nil for user messages.
    var model: String?
    var createdAt: Double         // ms since epoch
}
