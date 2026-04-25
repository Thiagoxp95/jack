import XCTest
@testable import JackApp

final class NoteServiceTests: XCTestCase {
    func testAppendVoiceNoteCreatesDailyMarkdownFile() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("jack-note-tests-\(UUID().uuidString)", isDirectory: true)
        let notesDir = tempRoot.appendingPathComponent("Jack Notes", isDirectory: true)
        let service = NoteService(notesDirectoryURL: notesDir)
        let firstDate = makeLocalDate(year: 2026, month: 2, day: 20, hour: 9, minute: 15, second: 0)
        let secondDate = makeLocalDate(year: 2026, month: 2, day: 20, hour: 10, minute: 45, second: 12)

        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let firstURL = try service.appendVoiceNote("First note", at: firstDate)
        let secondURL = try service.appendVoiceNote("Second note", at: secondDate)

        XCTAssertEqual(firstURL, secondURL)
        XCTAssertEqual(firstURL.lastPathComponent, "2026-02-20.md")

        let contents = try String(contentsOf: firstURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("# Jack Voice Notes (2026-02-20)"))
        XCTAssertTrue(contents.contains("## 09:15:00"))
        XCTAssertTrue(contents.contains("First note"))
        XCTAssertTrue(contents.contains("## 10:45:12"))
        XCTAssertTrue(contents.contains("Second note"))
    }

    private func makeLocalDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        second: Int
    ) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = .current
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return components.date!
    }
}
