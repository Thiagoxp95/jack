import Foundation

/// File-backed store for todos and todo lists.
///
/// Jack dropped accounts, and with them the Convex backend todos used to be
/// written to — every write threw `notSignedIn` and nothing persisted. Todos now
/// live in a single JSON file under Application Support, so a capture survives a
/// relaunch with no network round-trip and no auth.
actor LocalTodoStore {

    static let shared = LocalTodoStore()

    /// On-disk shape. Versioned so a future migration has something to branch on.
    private struct Snapshot: Codable {
        var version: Int = 1
        var todos: [TodoItem] = []
        var lists: [TodoList] = []
    }

    private let fileURL: URL
    private var snapshot = Snapshot()
    private var isLoaded = false

    init(fileURL: URL = LocalTodoStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    static func defaultFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Jack", isDirectory: true)
            .appendingPathComponent("todos.json")
    }

    var storePath: String { fileURL.path }

    // MARK: - Reads

    /// Todos in a space, newest first. `nil` means the personal space.
    func todos(spaceId: String?) -> [TodoItem] {
        load()
        return snapshot.todos
            .filter { $0.spaceId == spaceId }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func lists(spaceId: String?) -> [TodoList] {
        load()
        return snapshot.lists
            .filter { $0.spaceId == spaceId }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Todo writes

    @discardableResult
    func insert(_ todo: TodoItem) -> TodoItem {
        load()
        snapshot.todos.append(todo)
        save()
        return todo
    }

    /// Apply a partial update. Unknown keys are ignored, matching the loose
    /// `[String: Any]` field bags the todo views already pass around.
    func update(id: String, fields: [String: Any]) {
        load()
        guard let index = snapshot.todos.firstIndex(where: { $0.id == id }) else { return }
        var todo = snapshot.todos[index]

        if let title = fields["title"] as? String { todo.title = title }
        if let description = fields["description"] as? String { todo.description = description }
        if let priority = fields["priority"] as? String { todo.priority = priority }
        if let listId = fields["listId"] as? String { todo.listId = listId }
        if let tags = fields["tags"] as? [String] { todo.tags = tags }
        if let dueDate = fields["dueDate"] as? String { todo.dueDate = dueDate }
        if let dueTime = fields["dueTime"] as? String { todo.dueTime = dueTime }
        if let status = fields["status"] as? String {
            todo.status = status
            // Completion time is derived, never passed in by a caller.
            todo.completedAt = status == "done" ? Date().timeIntervalSince1970 * 1000 : nil
        }

        snapshot.todos[index] = todo
        save()
    }

    func delete(id: String) {
        load()
        snapshot.todos.removeAll { $0.id == id }
        save()
    }

    // MARK: - List writes

    @discardableResult
    func createList(name: String, color: String?, spaceId: String?) -> TodoList {
        load()
        let list = TodoList(id: Self.newID(), name: name, color: color, spaceId: spaceId)
        snapshot.lists.append(list)
        save()
        return list
    }

    /// Find a list by name in a space, creating it when it doesn't exist yet.
    /// Dictation names lists in prose ("add it to groceries"), so matching is
    /// case-insensitive.
    func resolveListID(named name: String, spaceId: String?) -> String {
        load()
        if let match = snapshot.lists.first(where: {
            $0.spaceId == spaceId && $0.name.lowercased() == name.lowercased()
        }) {
            return match.id
        }
        return createList(name: name, color: nil, spaceId: spaceId).id
    }

    // MARK: - Reminders

    /// Return todos with a reminder that has come due, marking those reminders
    /// delivered in the same step so the caller can't fire them twice.
    func claimDueReminders(now: Date = Date()) -> [TodoItem] {
        load()
        let nowMs = now.timeIntervalSince1970 * 1000
        var fired: [TodoItem] = []

        for index in snapshot.todos.indices {
            guard var reminders = snapshot.todos[index].reminders, !reminders.isEmpty else { continue }
            guard snapshot.todos[index].status != "done" else { continue }

            var didFire = false
            for reminderIndex in reminders.indices
            where reminders[reminderIndex].delivered != true && reminders[reminderIndex].at <= nowMs {
                reminders[reminderIndex].delivered = true
                didFire = true
            }

            if didFire {
                snapshot.todos[index].reminders = reminders
                fired.append(snapshot.todos[index])
            }
        }

        if !fired.isEmpty { save() }
        return fired
    }

    // MARK: - Persistence

    static func newID() -> String {
        UUID().uuidString
    }

    private func load() {
        guard !isLoaded else { return }
        isLoaded = true

        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        } catch {
            // A corrupt file would otherwise be silently overwritten on the next
            // write, so keep a copy before starting fresh.
            NSLog("[LocalTodoStore] Could not decode %@: %@", fileURL.path, String(describing: error))
            let backup = fileURL.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[LocalTodoStore] Could not write %@: %@", fileURL.path, String(describing: error))
        }
    }
}
