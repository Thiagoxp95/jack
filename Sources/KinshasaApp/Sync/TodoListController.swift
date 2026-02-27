import Foundation
import UserNotifications

/// A to-do item fetched from the Convex backend.
struct ConvexTodo: Identifiable {
    let id: String               // Convex document _id
    let title: String
    let description: String?
    let status: String           // "todo", "in_progress", "done"
    let priority: String         // "none", "low", "medium", "high"
    let listId: String?
    let tags: [String]?
    let dueDate: String?
    let dueTime: String?
    let completedAt: Double?
    let rawTranscription: String?
    let createdAt: Double
    let spaceId: String?
    let reminders: [[String: Any]]?
}

/// A to-do list (grouping container) fetched from the Convex backend.
struct ConvexTodoList: Identifiable {
    let id: String               // Convex document _id
    let name: String
    let color: String?
    let spaceId: String?
}

/// Fetches and caches todos and todo lists from the Convex HTTP API, filtered by space.
@MainActor @Observable
final class TodoListController {

    private(set) var todos: [ConvexTodo] = []
    private(set) var lists: [ConvexTodoList] = []
    private(set) var pendingReminderTodos: [ConvexTodo] = []
    private(set) var isLoading = false
    var error: String?

    private var reminderPollTask: Task<Void, Never>?

    // MARK: - Todos

    /// Fetch todos for the given space from Convex.
    /// Pass nil spaceId for personal space.
    func fetchTodos(spaceId: String?) async {
        isLoading = true
        error = nil

        do {
            let token = try await ConvexHTTPClient.getToken()

            var args: [String: Any] = [:]
            if let spaceId {
                args["spaceId"] = spaceId
            }

            let result = try await ConvexHTTPClient.query(
                function: "todos:list",
                args: args,
                token: token
            )

            guard let items = result as? [[String: Any]] else {
                todos = []
                isLoading = false
                return
            }

            todos = items.compactMap { parseTodo($0) }
        } catch {
            self.error = error.localizedDescription
            NSLog("[TodoList] Failed to fetch todos: %@", String(describing: error))
        }

        isLoading = false
    }

    /// Update a todo via Convex mutation.
    func updateTodo(todoId: String, fields: [String: Any]) async {
        do {
            let token = try await ConvexHTTPClient.getToken()

            var args: [String: Any] = ["todoId": todoId]
            for (key, value) in fields {
                args[key] = value
            }

            _ = try await ConvexHTTPClient.mutation(
                function: "todos:update",
                args: args,
                token: token
            )
        } catch {
            NSLog("[TodoList] Failed to update todo: %@", String(describing: error))
            self.error = error.localizedDescription
        }
    }

    /// Delete a todo via Convex mutation.
    func deleteTodo(todoId: String) async {
        do {
            let token = try await ConvexHTTPClient.getToken()

            _ = try await ConvexHTTPClient.mutation(
                function: "todos:remove",
                args: ["todoId": todoId],
                token: token
            )

            todos.removeAll { $0.id == todoId }
        } catch {
            NSLog("[TodoList] Failed to delete todo: %@", String(describing: error))
            self.error = error.localizedDescription
        }
    }

    /// Create a new todo via Convex mutation.
    func createTodo(
        title: String,
        spaceId: String?,
        listId: String? = nil,
        priority: String? = nil,
        dueDate: String? = nil
    ) async {
        do {
            let token = try await ConvexHTTPClient.getToken()

            var args: [String: Any] = ["title": title]
            if let spaceId {
                args["spaceId"] = spaceId
            }
            if let listId {
                args["listId"] = listId
            }
            if let priority {
                args["priority"] = priority
            }
            if let dueDate {
                args["dueDate"] = dueDate
            }

            _ = try await ConvexHTTPClient.mutation(
                function: "todos:create",
                args: args,
                token: token
            )
        } catch {
            NSLog("[TodoList] Failed to create todo: %@", String(describing: error))
            self.error = error.localizedDescription
        }
    }

    // MARK: - Lists

    /// Fetch todo lists for the given space from Convex.
    func fetchLists(spaceId: String?) async {
        do {
            let token = try await ConvexHTTPClient.getToken()

            var args: [String: Any] = [:]
            if let spaceId {
                args["spaceId"] = spaceId
            }

            let result = try await ConvexHTTPClient.query(
                function: "todoLists:list",
                args: args,
                token: token
            )

            guard let items = result as? [[String: Any]] else {
                lists = []
                return
            }

            lists = items.compactMap { item in
                guard let id = item["_id"] as? String,
                      let name = item["name"] as? String
                else { return nil }

                return ConvexTodoList(
                    id: id,
                    name: name,
                    color: item["color"] as? String,
                    spaceId: item["spaceId"] as? String
                )
            }
        } catch {
            NSLog("[TodoList] Failed to fetch lists: %@", String(describing: error))
            self.error = error.localizedDescription
        }
    }

    /// Create a new todo list via Convex mutation.
    func createList(name: String, color: String?, spaceId: String?) async {
        do {
            let token = try await ConvexHTTPClient.getToken()

            var args: [String: Any] = ["name": name]
            if let color {
                args["color"] = color
            }
            if let spaceId {
                args["spaceId"] = spaceId
            }

            _ = try await ConvexHTTPClient.mutation(
                function: "todoLists:create",
                args: args,
                token: token
            )
        } catch {
            NSLog("[TodoList] Failed to create list: %@", String(describing: error))
            self.error = error.localizedDescription
        }
    }

    // MARK: - Reminder Polling

    /// Start polling for pending reminders every 30 seconds.
    func startReminderPolling() {
        stopReminderPolling()
        reminderPollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollPendingReminders()
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds
            }
        }
    }

    /// Stop polling for pending reminders.
    func stopReminderPolling() {
        reminderPollTask?.cancel()
        reminderPollTask = nil
    }

    /// Acknowledge a specific reminder on a todo.
    func acknowledgeReminder(todoId: String, reminderIndex: Int) async {
        do {
            let token = try await ConvexHTTPClient.getToken()

            _ = try await ConvexHTTPClient.mutation(
                function: "todos:acknowledgeReminder",
                args: [
                    "todoId": todoId,
                    "reminderIndex": reminderIndex,
                ],
                token: token
            )
        } catch {
            NSLog("[TodoList] Failed to acknowledge reminder: %@", String(describing: error))
            self.error = error.localizedDescription
        }
    }

    // MARK: - Private

    /// Poll Convex for pending reminders and fire local notifications for new ones.
    private func pollPendingReminders() async {
        do {
            let token = try await ConvexHTTPClient.getToken()

            let result = try await ConvexHTTPClient.query(
                function: "todos:pendingReminders",
                args: [:],
                token: token
            )

            guard let items = result as? [[String: Any]] else { return }

            let fetched = items.compactMap { parseTodo($0) }

            // Determine which todos are newly pending (not already in the list).
            let existingIds = Set(pendingReminderTodos.map(\.id))
            let newTodos = fetched.filter { !existingIds.contains($0.id) }

            pendingReminderTodos = fetched

            for todo in newTodos {
                fireReminderNotification(for: todo)
            }
        } catch {
            NSLog("[TodoList] Failed to poll pending reminders: %@", String(describing: error))
        }
    }

    /// Post a local notification for a pending reminder.
    private func fireReminderNotification(for todo: ConvexTodo) {
        let content = UNMutableNotificationContent()
        content.title = "Reminder"
        content.body = todo.title
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "todo-reminder-\(todo.id)",
            content: content,
            trigger: nil // Fire immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("[TodoList] Failed to post notification: %@", String(describing: error))
            }
        }
    }

    /// Parse a raw Convex dictionary into a `ConvexTodo`.
    private func parseTodo(_ item: [String: Any]) -> ConvexTodo? {
        guard let id = item["_id"] as? String,
              let title = item["title"] as? String,
              let status = item["status"] as? String,
              let priority = item["priority"] as? String,
              let createdAt = item["_creationTime"] as? Double
        else { return nil }

        return ConvexTodo(
            id: id,
            title: title,
            description: item["description"] as? String,
            status: status,
            priority: priority,
            listId: item["listId"] as? String,
            tags: item["tags"] as? [String],
            dueDate: item["dueDate"] as? String,
            dueTime: item["dueTime"] as? String,
            completedAt: item["completedAt"] as? Double,
            rawTranscription: item["rawTranscription"] as? String,
            createdAt: createdAt,
            spaceId: item["spaceId"] as? String,
            reminders: item["reminders"] as? [[String: Any]]
        )
    }
}
