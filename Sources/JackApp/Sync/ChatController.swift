import Foundation

/// Drives the chat side sheet: threads and messages out of `LocalChatStore`,
/// replies streamed straight from OpenRouter with the user's own key.
///
/// Everything here used to go through `ConvexHTTPClient`, whose `getToken()`
/// throws `notSignedIn` now that accounts are gone. Every method swallowed that
/// into a `NSLog` and a nil, which is why a dead feature looked like an empty
/// one. Failures now land in `error`, and the sheet renders it.
@MainActor @Observable
final class ChatController {

    static let shared = ChatController()

    private(set) var threads: [ChatThread] = []
    private(set) var messages: [ChatMessage] = []
    private(set) var availableModels: [OpenRouterModelInfo] = []
    private(set) var isLoading = false
    private(set) var isStreaming = false
    var streamedContent: String = ""
    var error: String?

    var favoriteModelIds: Set<String> {
        didSet { saveFavorites() }
    }

    private let store: LocalChatStore
    private var streamTask: Task<Void, Never>?

    init(store: LocalChatStore = .shared) {
        self.store = store
        if let saved = UserDefaults.standard.array(forKey: "chat_favorite_models") as? [String] {
            favoriteModelIds = Set(saved)
        } else {
            favoriteModelIds = []
        }
    }

    /// The key lives in the login keychain, written by Settings. Read on demand
    /// rather than cached so replacing a rejected key takes effect immediately.
    private var apiKey: String {
        KeychainStore.read(account: KeychainStore.openRouterAPIKeyAccount) ?? ""
    }

    /// Whether chat can actually reach a model right now.
    var hasAPIKey: Bool { !apiKey.isEmpty }

    /// The model a new thread should open on.
    var defaultModelId: String {
        OpenRouterClient.resolveChatModel(UserDefaults.standard.string(forKey: "chat_last_used_model"))
    }

    // MARK: - Threads

    func fetchThreads(spaceId: String?) async {
        isLoading = true
        threads = await store.threads(spaceId: spaceId)
        isLoading = false

        // Said on open rather than on first send: an empty sheet with no
        // explanation is exactly the failure this release exists to remove.
        if !hasAPIKey {
            error = OpenRouterClient.Failure.missingKey.errorDescription
        } else if error == OpenRouterClient.Failure.missingKey.errorDescription {
            error = nil
        }
    }

    /// Create a new chat thread. Returns the created thread ID, or nil on failure.
    func createThread(title: String, model: String, spaceId: String?) async -> String? {
        let thread = await store.createThread(title: title, model: model, spaceId: spaceId)
        threads = await store.threads(spaceId: spaceId)
        return thread.id
    }

    func updateThread(threadId: String, title: String?, model: String?) async {
        await store.updateThread(id: threadId, title: title, model: model)
    }

    func deleteThread(threadId: String) async {
        let spaceId = threads.first { $0.id == threadId }?.spaceId
        await store.deleteThread(id: threadId)
        threads = await store.threads(spaceId: spaceId)
        messages = messages.filter { $0.threadId != threadId }
    }

    // MARK: - Messages

    func fetchMessages(threadId: String) async {
        messages = await store.messages(threadId: threadId)
    }

    /// Show the user's turn the instant they hit send. `sendAndStream` persists
    /// the real one and reloads, which replaces this placeholder in place.
    func addOptimisticUserMessage(threadId: String, content: String) {
        messages.append(ChatMessage(
            id: "optimistic-\(UUID().uuidString)",
            threadId: threadId,
            role: "user",
            content: content,
            model: nil,
            createdAt: LocalChatStore.nowMilliseconds()
        ))
    }

    // MARK: - Streaming

    /// Persist the user's turn, then stream the assistant's reply from OpenRouter.
    func sendAndStream(threadId: String, content: String) async {
        guard !isStreaming else { return }
        error = nil

        let key = apiKey
        guard !key.isEmpty else {
            error = OpenRouterClient.Failure.missingKey.errorDescription
            return
        }

        await store.append(ChatMessage(
            id: LocalChatStore.newID(),
            threadId: threadId,
            role: "user",
            content: content,
            model: nil,
            createdAt: LocalChatStore.nowMilliseconds()
        ))
        messages = await store.messages(threadId: threadId)

        let model = threads.first { $0.id == threadId }?.model ?? defaultModelId
        let spaceId = threads.first { $0.id == threadId }?.spaceId
        // The whole thread goes up every turn — OpenRouter is stateless, and
        // without the history the model answers each message in isolation.
        let history = messages.map { OpenRouterClient.Message(role: $0.role, content: $0.content) }

        isStreaming = true
        streamedContent = ""

        streamTask = Task { [weak self] in
            var accumulated = ""
            var failure: String?

            do {
                for try await token in OpenRouterClient.streamChat(
                    model: model,
                    messages: history,
                    apiKey: key
                ) {
                    if Task.isCancelled { break }
                    accumulated += token
                    self?.streamedContent = accumulated
                }
            } catch is CancellationError {
                // The user pressed stop; whatever arrived is still worth keeping.
            } catch {
                NSLog("[ChatController] Stream failed: %@", String(describing: error))
                failure = (error as? OpenRouterClient.Failure)?.errorDescription
                    ?? error.localizedDescription
            }

            guard let self else { return }

            if !accumulated.isEmpty {
                await self.store.append(ChatMessage(
                    id: LocalChatStore.newID(),
                    threadId: threadId,
                    role: "assistant",
                    content: accumulated,
                    model: model,
                    createdAt: LocalChatStore.nowMilliseconds()
                ))
            }

            self.messages = await self.store.messages(threadId: threadId)
            self.threads = await self.store.threads(spaceId: spaceId)
            self.isStreaming = false
            self.streamedContent = ""

            if let failure {
                self.error = failure
            } else if accumulated.isEmpty {
                // A 200 with nothing in it is still a failed turn to the person
                // watching the spinner stop.
                self.error = "\(model) returned an empty reply."
            }
        }
    }

    func cancelStream() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        streamedContent = ""
    }

    // MARK: - Models

    /// Populate the model picker from OpenRouter's public catalog.
    func fetchModels() async {
        do {
            availableModels = try await OpenRouterClient.fetchModels(apiKey: apiKey)
        } catch {
            NSLog("[ChatController] Failed to load models: %@", String(describing: error))
            self.error = (error as? OpenRouterClient.Failure)?.errorDescription
                ?? error.localizedDescription
        }
    }

    // MARK: - Favorites

    func toggleFavorite(modelId: String) {
        if favoriteModelIds.contains(modelId) {
            favoriteModelIds.remove(modelId)
        } else {
            favoriteModelIds.insert(modelId)
        }
    }

    // MARK: - Private

    private func saveFavorites() {
        UserDefaults.standard.set(Array(favoriteModelIds), forKey: "chat_favorite_models")
    }
}
