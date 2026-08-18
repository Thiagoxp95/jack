import XCTest
@testable import JackApp

final class DoubleTapModifierDetectorTests: XCTestCase {

    func testTwoQuickTapsFire() {
        var detector = DoubleTapModifierDetector()
        detector.modifierPressed(at: 0)
        XCTAssertFalse(detector.modifierReleased(at: 0.05))
        detector.modifierPressed(at: 0.15)
        XCTAssertTrue(detector.modifierReleased(at: 0.2))
    }

    func testSecondTapOutsideWindowDoesNotFire() {
        var detector = DoubleTapModifierDetector()
        detector.modifierPressed(at: 0)
        XCTAssertFalse(detector.modifierReleased(at: 0.05))
        detector.modifierPressed(at: 1.0)
        XCTAssertFalse(detector.modifierReleased(at: 1.05))
    }

    func testHeldModifierIsNotATap() {
        var detector = DoubleTapModifierDetector()
        detector.modifierPressed(at: 0)
        XCTAssertFalse(detector.modifierReleased(at: 0.05))
        detector.modifierPressed(at: 0.1)
        // Held well past maxHold — shift being used as a modifier, not tapped.
        XCTAssertFalse(detector.modifierReleased(at: 0.9))
    }

    func testTypingBetweenTapsCancels() {
        var detector = DoubleTapModifierDetector()
        detector.modifierPressed(at: 0)
        XCTAssertFalse(detector.modifierReleased(at: 0.05))
        detector.modifierPressed(at: 0.1)
        detector.noteOtherActivity() // e.g. a capital letter typed with shift held
        XCTAssertFalse(detector.modifierReleased(at: 0.15))
    }

    func testTypingBeforeSecondTapCancelsPendingTap() {
        var detector = DoubleTapModifierDetector()
        detector.modifierPressed(at: 0)
        XCTAssertFalse(detector.modifierReleased(at: 0.05))
        detector.noteOtherActivity()
        detector.modifierPressed(at: 0.1)
        XCTAssertFalse(detector.modifierReleased(at: 0.15))
    }

    func testTripleTapFiresOnlyOnce() {
        var detector = DoubleTapModifierDetector()
        detector.modifierPressed(at: 0)
        XCTAssertFalse(detector.modifierReleased(at: 0.05))
        detector.modifierPressed(at: 0.1)
        XCTAssertTrue(detector.modifierReleased(at: 0.15))
        detector.modifierPressed(at: 0.2)
        XCTAssertFalse(detector.modifierReleased(at: 0.25))
    }

    func testResetClearsPendingTap() {
        var detector = DoubleTapModifierDetector()
        detector.modifierPressed(at: 0)
        XCTAssertFalse(detector.modifierReleased(at: 0.05))
        detector.reset()
        detector.modifierPressed(at: 0.1)
        XCTAssertFalse(detector.modifierReleased(at: 0.15))
    }
}
