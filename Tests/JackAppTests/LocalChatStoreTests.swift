import XCTest
@testable import JackApp

final class LocalChatStoreTests: XCTestCase {

    private func makeStore() -> (store: LocalChatStore, root: URL, file: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jack-chat-tests-\(UUID().uuidString)", isDirectory: true)
        let file = root.appendingPathComponent("chats.json")
        return (LocalChatStore(fileURL: file), root, file)
    }

    private func makeMessage(
        threadId: String,
        role: String,
        content: String,
        createdAt: Double
    ) -> ChatMessage {
        ChatMessage(
            id: LocalChatStore.newID(),
            threadId: threadId,
            role: role,
            content: content,
            model: role == "assistant" ? "test/model" : nil,
            createdAt: createdAt
        )
    }

    func testAThreadAndItsMessagesSurviveAReload() async throws {
        let (store, root, file) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let thread = await store.createThread(title: "Why is the sky blue", model: "test/model", spaceId: nil)
        await store.append(makeMessage(threadId: thread.id, role: "user", content: "why?", createdAt: 100))
        await store.append(makeMessage(threadId: thread.id, role: "assistant", content: "Rayleigh scattering.", createdAt: 200))

        // A fresh store instance reads the same file from scratch.
        let reopened = LocalChatStore(fileURL: file)
        let threads = await reopened.threads(spaceId: nil)
        let messages = await reopened.messages(threadId: thread.id)

        XCTAssertEqual(threads.map(\.title), ["Why is the sky blue"])
        XCTAssertEqual(messages.map(\.role), ["user", "assistant"])
        XCTAssertEqual(messages.map(\.content), ["why?", "Rayleigh scattering."])
    }

    func testMessagesComeBackOldestFirst() async {
        let (store, root, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let thread = await store.createThread(title: "T", model: "m", spaceId: nil)
        await store.append(makeMessage(threadId: thread.id, role: "assistant", content: "second", createdAt: 300))
        await store.append(makeMessage(threadId: thread.id, role: "user", content: "first", createdAt: 100))

        let messages = await store.messages(threadId: thread.id)
        XCTAssertEqual(messages.map(\.content), ["first", "second"])
    }

    func testAppendingBumpsTheThreadToTheTopOfTheSidebar() async {
        let (store, root, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let older = await store.createThread(title: "Older", model: "m", spaceId: nil)
        let newer = await store.createThread(title: "Newer", model: "m", spaceId: nil)

        // Newest thread leads until the older one is replied to.
        var threads = await store.threads(spaceId: nil)
        XCTAssertEqual(threads.first?.id, newer.id)

        await store.append(makeMessage(
            threadId: older.id,
            role: "user",
            content: "still going",
            createdAt: LocalChatStore.nowMilliseconds() + 10_000
        ))

        threads = await store.threads(spaceId: nil)
        XCTAssertEqual(threads.first?.id, older.id)
    }

    func testThreadsAreScopedToTheirSpace() async {
        let (store, root, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        await store.createThread(title: "Personal", model: "m", spaceId: nil)
        await store.createThread(title: "Team", model: "m", spaceId: "space-1")

        let personal = await store.threads(spaceId: nil)
        let team = await store.threads(spaceId: "space-1")

        XCTAssertEqual(personal.map(\.title), ["Personal"])
        XCTAssertEqual(team.map(\.title), ["Team"])
    }

    func testDeletingAThreadTakesItsMessagesWithIt() async {
        let (store, root, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let thread = await store.createThread(title: "Doomed", model: "m", spaceId: nil)
        await store.append(makeMessage(threadId: thread.id, role: "user", content: "hi", createdAt: 100))

        await store.deleteThread(id: thread.id)

        let threads = await store.threads(spaceId: nil)
        let messages = await store.messages(threadId: thread.id)
        XCTAssertTrue(threads.isEmpty)
        XCTAssertTrue(messages.isEmpty)
    }

    func testUpdatingAThreadKeepsTheFieldsItWasNotGiven() async {
        let (store, root, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let thread = await store.createThread(title: "Original", model: "old/model", spaceId: nil)
        await store.updateThread(id: thread.id, title: nil, model: "new/model")

        let stored = await store.thread(id: thread.id)
        XCTAssertEqual(stored?.title, "Original")
        XCTAssertEqual(stored?.model, "new/model")
    }

    func testABlankTitleNeverBecomesABlankSidebarRow() async {
        let (store, root, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let thread = await store.createThread(title: "", model: "m", spaceId: nil)
        XCTAssertEqual(thread.title, "New Chat")
    }

    func testAFileFromAnotherVersionIsSetAsideRatherThanOverwritten() async throws {
        let (_, root, file) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{ not json at all".utf8).write(to: file)

        let store = LocalChatStore(fileURL: file)
        let threads = await store.threads(spaceId: nil)
        XCTAssertTrue(threads.isEmpty)

        // Writing again must not destroy what could not be read.
        await store.createThread(title: "Fresh start", model: "m", spaceId: nil)
        let backup = file.appendingPathExtension("corrupt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    }

    func testTheSnapshotOnDiskCarriesItsVersion() async throws {
        let (store, root, file) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        await store.createThread(title: "Versioned", model: "m", spaceId: nil)

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        XCTAssertEqual(json?["version"] as? Int, 1)
    }
}

final class OpenRouterStreamParsingTests: XCTestCase {

    func testAContentDeltaIsExtracted() {
        let line = #"data: {"choices":[{"delta":{"content":"Hello"}}]}"#
        XCTAssertEqual(OpenRouterClient.parseStreamLine(line), .token("Hello"))
    }

    func testDeltasAccumulateInOrder() {
        let lines = [
            #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#,
            #"data: {"choices":[{"delta":{"content":"Ray"}}]}"#,
            #"data: {"choices":[{"delta":{"content":"leigh"}}]}"#,
            "data: [DONE]",
        ]

        var accumulated = ""
        var finished = false
        for line in lines {
            switch OpenRouterClient.parseStreamLine(line) {
            case .token(let content): accumulated += content
            case .done: finished = true
            case .ignore: continue
            }
        }

        XCTAssertEqual(accumulated, "Rayleigh")
        XCTAssertTrue(finished)
    }

    func testDoneTerminatesTheStream() {
        XCTAssertEqual(OpenRouterClient.parseStreamLine("data: [DONE]"), .done)
        // OpenRouter is not consistent about the space after the colon.
        XCTAssertEqual(OpenRouterClient.parseStreamLine("data:[DONE]"), .done)
    }

    func testKeepAliveCommentsAndBlankLinesAreIgnored() {
        XCTAssertEqual(OpenRouterClient.parseStreamLine(": OPENROUTER PROCESSING"), .ignore)
        XCTAssertEqual(OpenRouterClient.parseStreamLine(""), .ignore)
        XCTAssertEqual(OpenRouterClient.parseStreamLine("event: message"), .ignore)
    }

    func testMalformedFramesAreSkippedNotThrownOn() {
        // Truncated JSON, right shape but wrong types, and an empty delta.
        XCTAssertEqual(OpenRouterClient.parseStreamLine(#"data: {"choices":[{"delta":{"cont"#), .ignore)
        XCTAssertEqual(OpenRouterClient.parseStreamLine(#"data: {"choices":[{"delta":{"content":42}}]}"#), .ignore)
        XCTAssertEqual(OpenRouterClient.parseStreamLine(#"data: {"choices":[]}"#), .ignore)
        XCTAssertEqual(OpenRouterClient.parseStreamLine(#"data: {"choices":[{"delta":{"content":""}}]}"#), .ignore)
    }

    func testRoleOnlyFirstDeltaIsIgnored() {
        XCTAssertEqual(
            OpenRouterClient.parseStreamLine(#"data: {"choices":[{"delta":{"role":"assistant","content":null}}]}"#),
            .ignore
        )
    }
}

final class ChatModelDefaultTests: XCTestCase {

    func testNoStoredPreferenceUsesTheShippedDefault() {
        XCTAssertEqual(OpenRouterClient.resolveChatModel(nil), OpenRouterClient.defaultChatModel)
        XCTAssertEqual(OpenRouterClient.resolveChatModel(""), OpenRouterClient.defaultChatModel)
    }

    func testTheStaleShippedDefaultIsRepointed() {
        XCTAssertEqual(
            OpenRouterClient.resolveChatModel("anthropic/claude-sonnet-4"),
            OpenRouterClient.defaultChatModel
        )
    }

    func testAModelTheUserActuallyPickedIsLeftAlone() {
        XCTAssertEqual(
            OpenRouterClient.resolveChatModel("google/gemini-3.1-flash-lite"),
            "google/gemini-3.1-flash-lite"
        )
    }
}
