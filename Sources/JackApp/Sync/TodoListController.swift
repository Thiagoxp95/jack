import Foundation
import UserNotifications

/// Debug logger that writes to both NSLog AND a file for reliable diagnostics.
private func diagLog(_ message: String) {
    NSLog("%@", message)
    let logFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("jack-reminder-diag.log")
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logFile.path) {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: logFile)
        }
    }
}

/// A to-do item fetched from the Convex backend.
struct ConvexTodo: Identifiable, @unchecked Sendable {
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

    /// Shared instance — lives for the app's entire lifetime so reminder polling
    /// survives window close/hide.
    static let shared = TodoListController()

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

            nonisolated(unsafe) let sendableArgs = args
            _ = try await ConvexHTTPClient.mutation(
                function: "todos:update",
                args: sendableArgs,
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

    /// Start polling for pending reminders every 10 seconds.
    func startReminderPolling() {
        stopReminderPolling()
        diagLog("[REMINDER-DIAG] ======== startReminderPolling() called ========")
        let addr = String(describing: Unmanaged.passUnretained(self).toOpaque())
        diagLog("[REMINDER-DIAG] self = \(type(of: self)), address = \(addr)")
        var pollCount = 0
        reminderPollTask = Task { [weak self] in
            while !Task.isCancelled {
                pollCount += 1
                let alive = self != nil ? "YES" : "NO — DEALLOCATED!"
                diagLog("[REMINDER-DIAG] Poll cycle #\(pollCount) starting (self alive: \(alive))")
                if self == nil {
                    diagLog("[REMINDER-DIAG] *** SELF IS NIL — POLLING IS DEAD ***")
                }
                await self?.pollPendingReminders()
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
            }
            diagLog("[REMINDER-DIAG] Poll loop exited (cancelled: \(Task.isCancelled ? "YES" : "NO"))")
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
            diagLog("[REMINDER-DIAG] Getting auth token...")
            let token = try await ConvexHTTPClient.getToken()
            diagLog("[REMINDER-DIAG] Token obtained (length=\(token.count))")

            diagLog("[REMINDER-DIAG] Querying todos:pendingReminders...")
            let result = try await ConvexHTTPClient.query(
                function: "todos:pendingReminders",
                args: [:],
                token: token
            )

            // Log the RAW result type and value
            diagLog("[REMINDER-DIAG] Raw result type: \(String(describing: type(of: result)))")
            if let jsonData = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted]),
               let jsonStr = String(data: jsonData, encoding: .utf8) {
                diagLog("[REMINDER-DIAG] Raw result value: \(jsonStr)")
            } else {
                diagLog("[REMINDER-DIAG] Raw result (not serializable): \(String(describing: result))")
            }

            guard let items = result as? [[String: Any]] else {
                diagLog("[REMINDER-DIAG] *** GUARD FAILED: result is NOT [[String: Any]] — type is \(String(describing: type(of: result)))")
                // Check if it's an empty array or NSNull
                if result is NSNull {
                    diagLog("[REMINDER-DIAG] Result is NSNull (server returned null)")
                } else if let arr = result as? [Any] {
                    diagLog("[REMINDER-DIAG] Result IS [Any] with \(arr.count) elements, but cast to [[String: Any]] failed")
                    for (i, item) in arr.prefix(3).enumerated() {
                        diagLog("[REMINDER-DIAG]   item[\(i)] type: \(String(describing: type(of: item)))")
                    }
                }
                return
            }

            let fetched = items.compactMap { parseTodo($0) }
            diagLog("[REMINDER-DIAG] Poll: \(items.count) raw items, \(fetched.count) parsed, \(pendingReminderTodos.count) already tracked")

            // Log each raw item's reminders field
            for (i, item) in items.enumerated() {
                let title = item["title"] as? String ?? "?"
                let reminders = item["reminders"]
                diagLog("[REMINDER-DIAG]   raw[\(i)] title=\(title), reminders type=\(String(describing: type(of: reminders as Any))), reminders=\(String(describing: reminders as Any))")
            }

            let existingIds = Set(pendingReminderTodos.map(\.id))
            let newTodos = fetched.filter { !existingIds.contains($0.id) }
            diagLog("[REMINDER-DIAG] existingIds=\(existingIds), newTodos count=\(newTodos.count)")

            pendingReminderTodos = fetched

            for todo in newTodos {
                diagLog("[REMINDER-DIAG] *** NEW REMINDER: title=\(todo.title), id=\(todo.id)")
                fireReminderNotification(for: todo)

                // Acknowledge delivered reminders in reverse order because
                // acknowledgeReminder uses splice (shifts indices).
                if let reminders = todo.reminders {
                    for index in stride(from: reminders.count - 1, through: 0, by: -1) {
                        if reminders[index]["delivered"] as? Bool == true {
                            diagLog("[REMINDER-DIAG] Acknowledging reminder index \(index) for todo \(todo.id)")
                            await acknowledgeReminder(todoId: todo.id, reminderIndex: index)
                        }
                    }
                }
            }
        } catch {
            diagLog("[REMINDER-DIAG] *** POLL FAILED: \(String(describing: error))")
        }
    }

    /// Post a local notification for a pending reminder.
    private func fireReminderNotification(for todo: ConvexTodo) {
        diagLog("[REMINDER-DIAG] fireReminderNotification called for: \(todo.title) (id=\(todo.id))")

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let authStatus = settings.authorizationStatus
            diagLog("[REMINDER-DIAG] Notification auth status: \(authStatus.rawValue) (0=notDetermined, 1=denied, 2=authorized, 3=provisional)")
            diagLog("[REMINDER-DIAG] Alert setting: \(settings.alertSetting.rawValue), Sound setting: \(settings.soundSetting.rawValue), Badge setting: \(settings.badgeSetting.rawValue)")

            guard authStatus == .authorized || authStatus == .provisional else {
                diagLog("[REMINDER-DIAG] *** NOTIFICATIONS NOT AUTHORIZED (status=\(authStatus.rawValue)) — CANNOT FIRE ***")
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "Reminder"
            content.body = todo.title
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "todo-reminder-\(todo.id)",
                content: content,
                trigger: nil // Fire immediately
            )

            diagLog("[REMINDER-DIAG] Posting notification: id=\(request.identifier), title=\(content.title), body=\(content.body)")

            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    diagLog("[REMINDER-DIAG] *** NOTIFICATION FAILED: \(String(describing: error))")
                } else {
                    diagLog("[REMINDER-DIAG] NOTIFICATION POSTED SUCCESSFULLY for: \(todo.title)")
                }
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
