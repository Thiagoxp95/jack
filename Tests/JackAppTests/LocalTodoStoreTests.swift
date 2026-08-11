import XCTest
@testable import JackApp

final class LocalTodoStoreTests: XCTestCase {

    private func makeStore() -> (store: LocalTodoStore, root: URL, file: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jack-todo-tests-\(UUID().uuidString)", isDirectory: true)
        let file = root.appendingPathComponent("todos.json")
        return (LocalTodoStore(fileURL: file), root, file)
    }

    private func makeTodo(
        title: String,
        spaceId: String? = nil,
        createdAt: Double = 1_000,
        reminders: [TodoReminder]? = nil
    ) -> TodoItem {
        TodoItem(
            id: LocalTodoStore.newID(),
            title: title,
            description: nil,
            status: "todo",
            priority: "none",
            listId: nil,
            tags: nil,
            dueDate: nil,
            dueTime: nil,
            completedAt: nil,
            rawTranscription: nil,
            createdAt: createdAt,
            spaceId: spaceId,
            reminders: reminders
        )
    }

    func testInsertedTodoSurvivesAReload() async throws {
        let (store, root, file) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let todo = makeTodo(title: "Call the dentist")
        await store.insert(todo)

        // A fresh store instance reads the same file from scratch.
        let reopened = LocalTodoStore(fileURL: file)
        let reloaded = await reopened.todos(spaceId: nil)

        XCTAssertEqual(reloaded.map(\.title), ["Call the dentist"])
        XCTAssertEqual(reloaded.first?.id, todo.id)
    }

    func testTodosAreFilteredBySpaceAndSortedNewestFirst() async {
        let (store, root, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        await store.insert(makeTodo(title: "Older personal", createdAt: 100))
        await store.insert(makeTodo(title: "Newer personal", createdAt: 200))
        await store.insert(makeTodo(title: "Team", spaceId: "space-1", createdAt: 300))

        let personal = await store.todos(spaceId: nil)
        XCTAssertEqual(personal.map(\.title), ["Newer personal", "Older personal"])

        let team = await store.todos(spaceId: "space-1")
        XCTAssertEqual(team.map(\.title), ["Team"])
    }

    func testMarkingDoneStampsCompletionAndReopeningClearsIt() async {
        let (store, root, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let todo = makeTodo(title: "Ship it")
        await store.insert(todo)

        await store.update(id: todo.id, fields: ["status": "done"])
        var stored = await store.todos(spaceId: nil).first
        XCTAssertEqual(stored?.status, "done")
        XCTAssertNotNil(stored?.completedAt)

        await store.update(id: todo.id, fields: ["status": "todo"])
        stored = await store.todos(spaceId: nil).first
        XCTAssertNil(stored?.completedAt)
    }

    func testResolveListIDReusesAListRegardlessOfCase() async {
        let (store, root, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = await store.resolveListID(named: "Groceries", spaceId: nil)
        let second = await store.resolveListID(named: "groceries", spaceId: nil)

        let lists = await store.lists(spaceId: nil)
        XCTAssertEqual(first, second)
        XCTAssertEqual(lists.count, 1)
    }

    func testDueRemindersAreClaimedOnlyOnce() async {
        let (store, root, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let past = (now.timeIntervalSince1970 - 60) * 1000
        let future = (now.timeIntervalSince1970 + 600) * 1000

        await store.insert(makeTodo(title: "Due now", reminders: [TodoReminder(at: past, delivered: false)]))
        await store.insert(makeTodo(title: "Later", reminders: [TodoReminder(at: future, delivered: false)]))

        let firstPass = await store.claimDueReminders(now: now)
        XCTAssertEqual(firstPass.map(\.title), ["Due now"])

        let secondPass = await store.claimDueReminders(now: now)
        XCTAssertTrue(secondPass.isEmpty)
    }

    func testCompletedTodosDoNotFireReminders() async {
        let (store, root, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let past = (now.timeIntervalSince1970 - 60) * 1000
        let todo = makeTodo(title: "Already handled", reminders: [TodoReminder(at: past, delivered: false)])
        await store.insert(todo)
        await store.update(id: todo.id, fields: ["status": "done"])

        let fired = await store.claimDueReminders(now: now)
        XCTAssertTrue(fired.isEmpty)
    }
}

final class TodoTextParserTests: XCTestCase {

    func testFirstJSONObjectSurvivesFencesAndBracesInStrings() {
        let reply = """
        Sure, here you go:
        ```json
        {"title":"Fix the { brace }","priority":"high"}
        ```
        """
        let json = TodoTextParser.firstJSONObject(in: reply)
        XCTAssertEqual(json?["title"] as? String, "Fix the { brace }")
        XCTAssertEqual(json?["priority"] as? String, "high")
    }

    func testNaiveDateTimeIsReadInTheGivenTimezone() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Toronto"))
        let date = try XCTUnwrap(TodoTextParser.parseLocalDateTime("2026-08-10T17:42:00", timeZone: zone))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)

        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 8)
        XCTAssertEqual(parts.day, 10)
        XCTAssertEqual(parts.hour, 17)
        XCTAssertEqual(parts.minute, 42)
    }

    func testMissingKeyFallsBackToTheRawTranscript() async {
        // An empty key short-circuits the network call and returns the fallback.
        let parsed = await TodoTextParser().parse(rawText: "  buy milk  ", model: "x", apiKey: "")
        XCTAssertEqual(parsed.title, "buy milk")
        XCTAssertEqual(parsed.priority, "none")
        XCTAssertEqual(parsed.backend, "raw")
        XCTAssertTrue(parsed.reminderTimes.isEmpty)
    }
}
