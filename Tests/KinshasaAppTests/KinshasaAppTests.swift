import XCTest
@testable import KinshasaApp

final class KinshasaAppTests: XCTestCase {
    func testToggleModeTriggersOnKeyDownOnly() {
        var interpreter = ShortcutInterpreter(mode: .toggle)

        XCTAssertEqual(interpreter.handle(.down), .toggleRecording)
        XCTAssertNil(interpreter.handle(.up))
    }

    func testHoldModeStartsOnDownAndStopsOnUp() {
        var interpreter = ShortcutInterpreter(mode: .hold)

        XCTAssertEqual(interpreter.handle(.down), .startRecording)
        XCTAssertEqual(interpreter.handle(.up), .stopRecording)
    }

    func testDoubleTapNeedsTwoPressesWithinWindow() {
        let start = Date(timeIntervalSince1970: 1_000)
        var interpreter = ShortcutInterpreter(mode: .doubleTap, doubleTapWindow: 0.35)

        XCTAssertNil(interpreter.handle(.down, now: start))
        XCTAssertEqual(
            interpreter.handle(.down, now: start.addingTimeInterval(0.20)),
            .toggleRecording
        )
    }

    func testDoubleTapResetsAfterWindowExpires() {
        let start = Date(timeIntervalSince1970: 1_000)
        var interpreter = ShortcutInterpreter(mode: .doubleTap, doubleTapWindow: 0.35)

        XCTAssertNil(interpreter.handle(.down, now: start))
        XCTAssertNil(interpreter.handle(.down, now: start.addingTimeInterval(0.40)))
        XCTAssertEqual(
            interpreter.handle(.down, now: start.addingTimeInterval(0.55)),
            .toggleRecording
        )
    }
}
