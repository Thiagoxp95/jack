import Foundation

/// A chat thread from the Convex backend.
struct ConvexChatThread: Identifiable {
    let id: String
    let title: String
    let model: String
    let spaceId: String?
    let createdAt: Double
    let updatedAt: Double
}

/// A chat message from the Convex backend.
struct ConvexChatMessage: Identifiable {
    let id: String
    let threadId: String
    let role: String       // "user" or "assistant"
    let content: String
    let model: String?
    let createdAt: Double
}

/// An OpenRouter model available for chat.
struct OpenRouterModel: Identifiable {
    let id: String
    let name: String
    let provider: String
}

/// Manages chat threads, messages, and streaming responses via the Convex backend.
@MainActor @Observable
final class ChatController {

    static let shared = ChatController()

    private(set) var threads: [ConvexChatThread] = []
    private(set) var messages: [ConvexChatMessage] = []
    private(set) var availableModels: [OpenRouterModel] = []
    private(set) var isLoading = false
    private(set) var isStreaming = false
    var streamedContent: String = ""
    var error: String?

    var favoriteModelIds: Set<String> {
        didSet { saveFavorites() }
    }

    private var streamTask: Task<Void, Never>?

    private init() {
        if let saved = UserDefaults.standard.array(forKey: "chat_favorite_models") as? [String] {
            favoriteModelIds = Set(saved)
        } else {
            favoriteModelIds = []
        }
    }

    // MARK: - Threads

    /// Fetch chat threads for the given space from Convex.
    func fetchThreads(spaceId: String?) async {
        isLoading = true
        error = nil

        do {
            let token = try await ConvexHTTPClient.getToken()

            var args: [String: Any] = [:]
            if let spaceId {
                args["spaceId"] = spaceId
            }

            let result = try await ConvexHTTPClient.query(
                function: "chats:listThreads",
                args: args,
                token: token
            )

            guard let items = result as? [[String: Any]] else {
                threads = []
                isLoading = false
                return
            }

            threads = items.compactMap { parseThread($0) }
        } catch {
            self.error = error.localizedDescription
            NSLog("[ChatController] Failed to fetch threads: %@", String(describing: error))
        }

        isLoading = false
    }

    /// Create a new chat thread. Returns the created thread ID, or nil on failure.
    func createThread(title: String, model: String, spaceId: String?) async -> String? {
        do {
            let token = try await ConvexHTTPClient.getToken()

            var args: [String: Any] = [
                "title": title,
                "model": model,
            ]
            if let spaceId {
                args["spaceId"] = spaceId
            }

            nonisolated(unsafe) let sendableArgs = args
            let result = try await ConvexHTTPClient.mutation(
                function: "chats:createThread",
                args: sendableArgs,
                token: token
            )

            return result as? String
        } catch {
            NSLog("[ChatController] Failed to create thread: %@", String(describing: error))
            self.error = error.localizedDescription
            return nil
        }
    }

    /// Update a chat thread's title and/or model.
    func updateThread(threadId: String, title: String?, model: String?) async {
        do {
            let token = try await ConvexHTTPClient.getToken()

            var args: [String: Any] = ["threadId": threadId]
            if let title {
                args["title"] = title
            }
            if let model {
                args["model"] = model
            }

            nonisolated(unsafe) let sendableArgs = args
            _ = try await ConvexHTTPClient.mutation(
                function: "chats:updateThread",
                args: sendableArgs,
                token: token
            )
        } catch {
            NSLog("[ChatController] Failed to update thread: %@", String(describing: error))
            self.error = error.localizedDescription
        }
    }

    /// Delete a chat thread.
    func deleteThread(threadId: String) async {
        do {
            let token = try await ConvexHTTPClient.getToken()

            _ = try await ConvexHTTPClient.mutation(
                function: "chats:deleteThread",
                args: ["threadId": threadId],
                token: token
            )

            threads.removeAll { $0.id == threadId }
        } catch {
            NSLog("[ChatController] Failed to delete thread: %@", String(describing: error))
            self.error = error.localizedDescription
        }
    }

    // MARK: - Messages

    /// Fetch messages for a given thread from Convex.
    func fetchMessages(threadId: String) async {
        do {
            let token = try await ConvexHTTPClient.getToken()

            let result = try await ConvexHTTPClient.query(
                function: "chats:getMessages",
                args: ["threadId": threadId],
                token: token
            )

            guard let items = result as? [[String: Any]] else {
                messages = []
                return
            }

            messages = items.compactMap { parseMessage($0) }
        } catch {
            NSLog("[ChatController] Failed to fetch messages: %@", String(describing: error))
            self.error = error.localizedDescription
        }
    }

    // MARK: - Streaming

    /// Send a user message and stream the assistant response via SSE.
    func sendAndStream(threadId: String, content: String) async {
        guard !isStreaming else { return }
        isStreaming = true
        streamedContent = ""

        streamTask = Task { [weak self] in
            do {
                let token = try await ConvexHTTPClient.getToken()

                let url = URL(string: "\(AppConfig.convexSiteUrl)/chat/stream")!
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

                let body: [String: Any] = [
                    "threadId": threadId,
                    "messageContent": content,
                ]
                request.httpBody = try JSONSerialization.data(withJSONObject: body)

                let (bytes, response) = try await URLSession.shared.bytes(for: request)

                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                guard statusCode == 200 else {
                    await MainActor.run {
                        self?.error = "Stream failed with HTTP \(statusCode)"
                        self?.isStreaming = false
                    }
                    return
                }

                for try await line in bytes.lines {
                    if Task.isCancelled { break }

                    guard line.hasPrefix("data: ") else { continue }
                    let payload = String(line.dropFirst(6))

                    if payload == "[DONE]" { break }

                    guard let data = payload.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let choices = json["choices"] as? [[String: Any]],
                          let delta = choices.first?["delta"] as? [String: Any],
                          let tokenContent = delta["content"] as? String
                    else { continue }

                    await MainActor.run {
                        self?.streamedContent += tokenContent
                    }
                }

                // Refresh messages and threads after streaming completes
                await self?.fetchMessages(threadId: threadId)
                let spaceId = self?.threads.first(where: { $0.id == threadId })?.spaceId
                await self?.fetchThreads(spaceId: spaceId)

            } catch {
                if !Task.isCancelled {
                    await MainActor.run {
                        self?.error = error.localizedDescription
                        NSLog("[ChatController] Stream error: %@", String(describing: error))
                    }
                }
            }

            await MainActor.run {
                self?.isStreaming = false
                self?.streamedContent = ""
            }
        }
    }

    /// Cancel an in-progress streaming response.
    func cancelStream() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        streamedContent = ""
    }

    // MARK: - Models

    /// Fetch available OpenRouter models from Convex.
    func fetchModels() async {
        do {
            let token = try await ConvexHTTPClient.getToken()

            let result = try await ConvexHTTPClient.action(
                function: "chats:listModels",
                args: [:],
                token: token
            )

            guard let items = result as? [[String: Any]] else {
                availableModels = []
                return
            }

            availableModels = items.compactMap { item in
                guard let id = item["id"] as? String,
                      let name = item["name"] as? String,
                      let provider = item["provider"] as? String
                else { return nil }

                return OpenRouterModel(id: id, name: name, provider: provider)
            }
        } catch {
            NSLog("[ChatController] Failed to fetch models: %@", String(describing: error))
            self.error = error.localizedDescription
        }
    }

    // MARK: - Favorites

    /// Toggle a model ID in the favorites set.
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

    private func parseThread(_ item: [String: Any]) -> ConvexChatThread? {
        guard let id = item["_id"] as? String,
              let title = item["title"] as? String,
              let model = item["model"] as? String,
              let createdAt = item["_creationTime"] as? Double,
              let updatedAt = item["updatedAt"] as? Double
        else { return nil }

        return ConvexChatThread(
            id: id,
            title: title,
            model: model,
            spaceId: item["spaceId"] as? String,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func parseMessage(_ item: [String: Any]) -> ConvexChatMessage? {
        guard let id = item["_id"] as? String,
              let threadId = item["threadId"] as? String,
              let role = item["role"] as? String,
              let content = item["content"] as? String,
              let createdAt = item["_creationTime"] as? Double
        else { return nil }

        return ConvexChatMessage(
            id: id,
            threadId: threadId,
            role: role,
            content: content,
            model: item["model"] as? String,
            createdAt: createdAt
        )
    }
}
