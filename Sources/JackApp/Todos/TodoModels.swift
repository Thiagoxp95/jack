import Foundation

/// A scheduled reminder on a todo. `at` is milliseconds since the epoch.
struct TodoReminder: Codable, Sendable, Equatable {
    var at: Double
    var delivered: Bool?
}

/// A to-do item. Persisted on disk by `LocalTodoStore`.
struct TodoItem: Identifiable, Codable, Sendable, Equatable {
    var id: String
    var title: String
    var description: String?
    var status: String            // "todo", "in_progress", "done"
    var priority: String          // "none", "low", "medium", "high"
    var listId: String?
    var tags: [String]?
    var dueDate: String?          // yyyy-MM-dd, in the user's local timezone
    var dueTime: String?          // HH:mm, in the user's local timezone
    var completedAt: Double?      // ms since epoch
    var rawTranscription: String?
    var createdAt: Double         // ms since epoch
    var spaceId: String?
    var reminders: [TodoReminder]?
}

/// A grouping container for todos.
struct TodoList: Identifiable, Codable, Sendable, Equatable {
    var id: String
    var name: String
    var color: String?
    var spaceId: String?
}
