import Foundation

/// File-backed store for chat threads and their messages.
///
/// The same story as `LocalTodoStore`: chat used to live in Convex, and every
/// call started with `ConvexHTTPClient.getToken()`, which throws `notSignedIn`
/// ever since accounts were dropped. So `createThread` returned nil, the caller
/// bailed on a `guard`, and pressing A on the post-dictation pill opened an
/// empty sheet that never sent anything. Threads now live in a single JSON file
/// under Application Support — no auth, no round-trip, and a conversation
/// survives a relaunch.
actor LocalChatStore {

    static let shared = LocalChatStore()

    /// On-disk shape. Versioned so a future migration has something to branch on.
    private struct Snapshot: Codable {
        var version: Int = 1
        var threads: [ChatThread] = []
        var messages: [ChatMessage] = []
    }

    private let fileURL: URL
    private var snapshot = Snapshot()
    private var isLoaded = false

    init(fileURL: URL = LocalChatStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    static func defaultFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Jack", isDirectory: true)
            .appendingPathComponent("chats.json")
    }

    var storePath: String { fileURL.path }

    // MARK: - Reads

    /// Threads in a space, most recently touched first — the sidebar order.
    /// `nil` means the personal space.
    func threads(spaceId: String?) -> [ChatThread] {
        load()
        return snapshot.threads
            .filter { $0.spaceId == spaceId }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// A thread's messages oldest first, which is the order they are read in.
    func messages(threadId: String) -> [ChatMessage] {
        load()
        return snapshot.messages
            .filter { $0.threadId == threadId }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func thread(id: String) -> ChatThread? {
        load()
        return snapshot.threads.first { $0.id == id }
    }

    // MARK: - Thread writes

    @discardableResult
    func createThread(title: String, model: String, spaceId: String?) -> ChatThread {
        load()
        let now = Self.nowMilliseconds()
        let thread = ChatThread(
            id: Self.newID(),
            // A thread titled with an empty string is a blank row in the
            // sidebar the user can't tell apart from any other blank row.
            title: title.isEmpty ? "New Chat" : title,
            model: model,
            spaceId: spaceId,
            createdAt: now,
            updatedAt: now
        )
        snapshot.threads.append(thread)
        save()
        return thread
    }

    /// Partial update — a nil field is "leave it alone", not "clear it".
    func updateThread(id: String, title: String?, model: String?) {
        load()
        guard let index = snapshot.threads.firstIndex(where: { $0.id == id }) else { return }
        if let title { snapshot.threads[index].title = title }
        if let model { snapshot.threads[index].model = model }
        snapshot.threads[index].updatedAt = Self.nowMilliseconds()
        save()
    }

    /// Deleting a thread takes its messages with it — orphaned turns would sit
    /// in the file forever with nothing able to show or remove them.
    func deleteThread(id: String) {
        load()
        snapshot.threads.removeAll { $0.id == id }
        snapshot.messages.removeAll { $0.threadId == id }
        save()
    }

    // MARK: - Message writes

    @discardableResult
    func append(_ message: ChatMessage) -> ChatMessage {
        load()
        snapshot.messages.append(message)
        // Appending is the only thing that makes a thread "recent", so the
        // sidebar's sort key is maintained here rather than by every caller.
        if let index = snapshot.threads.firstIndex(where: { $0.id == message.threadId }) {
            snapshot.threads[index].updatedAt = message.createdAt
        }
        save()
        return message
    }

    // MARK: - Persistence

    static func newID() -> String {
        UUID().uuidString
    }

    static func nowMilliseconds() -> Double {
        Date().timeIntervalSince1970 * 1000
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
            NSLog("[LocalChatStore] Could not decode %@: %@", fileURL.path, String(describing: error))
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
            NSLog("[LocalChatStore] Could not write %@: %@", fileURL.path, String(describing: error))
        }
    }
}
