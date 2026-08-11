import Foundation
import UserNotifications

/// Reads and writes todos through `LocalTodoStore`, filtered by space, and
/// fires local notifications when a reminder comes due.
@MainActor @Observable
final class TodoListController {

    /// Shared instance — lives for the app's entire lifetime so reminder polling
    /// survives window close/hide.
    static let shared = TodoListController()

    private(set) var todos: [TodoItem] = []
    private(set) var lists: [TodoList] = []
    private(set) var pendingReminderTodos: [TodoItem] = []
    private(set) var isLoading = false
    var error: String?

    private let store: LocalTodoStore
    private var reminderPollTask: Task<Void, Never>?

    init(store: LocalTodoStore = .shared) {
        self.store = store
    }

    // MARK: - Todos

    /// Load todos for the given space. Pass nil spaceId for personal space.
    func fetchTodos(spaceId: String?) async {
        isLoading = true
        error = nil
        todos = await store.todos(spaceId: spaceId)
        isLoading = false
    }

    /// Apply a partial update to a todo, then refresh the cached list in place.
    func updateTodo(todoId: String, fields: [String: Any]) async {
        nonisolated(unsafe) let sendableFields = fields
        await store.update(id: todoId, fields: sendableFields)
    }

    func deleteTodo(todoId: String) async {
        await store.delete(id: todoId)
        todos.removeAll { $0.id == todoId }
    }

    func createTodo(
        title: String,
        spaceId: String?,
        listId: String? = nil,
        priority: String? = nil,
        dueDate: String? = nil
    ) async {
        let todo = TodoItem(
            id: LocalTodoStore.newID(),
            title: title,
            description: nil,
            status: "todo",
            priority: priority ?? "none",
            listId: listId,
            tags: nil,
            dueDate: dueDate,
            dueTime: nil,
            completedAt: nil,
            rawTranscription: nil,
            createdAt: Date().timeIntervalSince1970 * 1000,
            spaceId: spaceId,
            reminders: nil
        )
        await store.insert(todo)
    }

    // MARK: - Lists

    func fetchLists(spaceId: String?) async {
        lists = await store.lists(spaceId: spaceId)
    }

    func createList(name: String, color: String?, spaceId: String?) async {
        await store.createList(name: name, color: color, spaceId: spaceId)
        await fetchLists(spaceId: spaceId)
    }

    // MARK: - Reminder Polling

    /// Start polling for due reminders every 10 seconds.
    func startReminderPolling() {
        stopReminderPolling()
        reminderPollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollDueReminders()
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
            }
        }
    }

    func stopReminderPolling() {
        reminderPollTask?.cancel()
        reminderPollTask = nil
    }

    // MARK: - Private

    /// Claim reminders that have come due and fire a notification for each.
    /// The store marks them delivered as it hands them over, so a reminder can't
    /// fire twice even if a poll overlaps the next one.
    private func pollDueReminders() async {
        let due = await store.claimDueReminders()
        guard !due.isEmpty else { return }

        pendingReminderTodos = due
        for todo in due {
            fireReminderNotification(for: todo)
        }
    }

    /// Post a local notification for a due reminder.
    private func fireReminderNotification(for todo: TodoItem) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            guard status == .authorized || status == .provisional else {
                NSLog("[TodoList] Reminder for %@ suppressed: notifications not authorized", todo.title)
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "Reminder"
            content.body = todo.title
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "todo-reminder-\(todo.id)-\(Int(Date().timeIntervalSince1970))",
                content: content,
                trigger: nil // Fire immediately
            )

            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    NSLog("[TodoList] Reminder notification failed: %@", String(describing: error))
                }
            }
        }
    }
}
