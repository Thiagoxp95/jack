import AppKit
import XCTest
@testable import JackApp

final class JackAppTests: XCTestCase {
    func testStartingPresentationShowsImmediateFeedbackWithoutRecordingAnimation() {
        let presentation = RecordingPresentationState.starting()

        XCTAssertEqual(presentation.message, "Starting...")
        XCTAssertFalse(presentation.isRecording)
        XCTAssertFalse(presentation.isTranscribing)
        XCTAssertTrue(presentation.usesActiveAppearance)
        XCTAssertFalse(presentation.isNoteMode)
        XCTAssertFalse(presentation.isTodoMode)
        XCTAssertFalse(presentation.isAiMode)
    }

    func testListeningPresentationReflectsCurrentOutputMode() {
        let presentation = RecordingPresentationState.listening(outputMode: .todo, isLive: false)

        XCTAssertEqual(presentation.message, "Listening... (Todo Mode)")
        XCTAssertTrue(presentation.isRecording)
        XCTAssertFalse(presentation.isTranscribing)
        XCTAssertTrue(presentation.usesActiveAppearance)
        XCTAssertFalse(presentation.isNoteMode)
        XCTAssertTrue(presentation.isTodoMode)
        XCTAssertFalse(presentation.isAiMode)
    }

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

    func testSingleKeyInvocationKeepsPriorityEvenWithExtraModifiers() {
        let invocation = InvocationShortcut(primaryKeyCode: 0, modifiers: 0)

        XCTAssertTrue(
            GlobalFnShortcutMonitor.invocationShouldTakePriority(
                forKeyCode: 0,
                currentModifierFlags: [.command],
                invocationShortcut: invocation
            )
        )
    }

    func testCombinationInvocationRequiresItsModifiersBeforeTakingPriority() {
        let invocation = InvocationShortcut(primaryKeyCode: 0, modifiers: NSEvent.ModifierFlags.command.rawValue)

        XCTAssertFalse(
            GlobalFnShortcutMonitor.invocationShouldTakePriority(
                forKeyCode: 0,
                currentModifierFlags: [],
                invocationShortcut: invocation
            )
        )
        XCTAssertTrue(
            GlobalFnShortcutMonitor.invocationShouldTakePriority(
                forKeyCode: 0,
                currentModifierFlags: [.command, .shift],
                invocationShortcut: invocation
            )
        )
    }

    func testInferOnboardingCompletionHonorsStoredValue() {
        let defaults = makeTestDefaults()
        defaults.set(false, forKey: "onboarding_completed")

        let inferred = DictationController.inferOnboardingCompletion(
            defaults: defaults,
            accessibilityGranted: true,
            keyboardMonitoringGranted: true,
            microphoneGranted: true
        )

        XCTAssertFalse(inferred)
    }

    func testInferOnboardingCompletionReturnsTrueForExistingConfig() {
        let defaults = makeTestDefaults()
        defaults.set(ShortcutMode.toggle.rawValue, forKey: "shortcut_mode")

        let inferred = DictationController.inferOnboardingCompletion(
            defaults: defaults,
            accessibilityGranted: false,
            keyboardMonitoringGranted: false,
            microphoneGranted: false
        )

        XCTAssertTrue(inferred)
    }

    func testInferOnboardingCompletionReturnsTrueWhenAllPermissionsGranted() {
        let defaults = makeTestDefaults()

        let inferred = DictationController.inferOnboardingCompletion(
            defaults: defaults,
            accessibilityGranted: true,
            keyboardMonitoringGranted: true,
            microphoneGranted: true
        )

        XCTAssertTrue(inferred)
    }

    func testInferOnboardingCompletionReturnsFalseWithoutConfigOrPermissions() {
        let defaults = makeTestDefaults()

        let inferred = DictationController.inferOnboardingCompletion(
            defaults: defaults,
            accessibilityGranted: false,
            keyboardMonitoringGranted: false,
            microphoneGranted: false
        )

        XCTAssertFalse(inferred)
    }

    private func makeTestDefaults() -> UserDefaults {
        let suiteName = "jack-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

final class TranscriptionResultTests: XCTestCase {
    func testWordTimingStruct() {
        let timing = WordTiming(word: "hello", startTime: 0.5, endTime: 1.0, confidence: 0.9)
        XCTAssertEqual(timing.word, "hello")
        XCTAssertEqual(timing.startTime, 0.5)
        XCTAssertEqual(timing.endTime, 1.0)
        XCTAssertEqual(timing.confidence, 0.9, accuracy: 0.001)
    }

    func testTranscriptionResultContainsTimings() {
        let timings = [
            WordTiming(word: "hello", startTime: 0.5, endTime: 1.0, confidence: 0.9),
            WordTiming(word: "world", startTime: 1.1, endTime: 1.6, confidence: 0.85),
        ]
        let result = TranscriptionResult(
            text: "hello world",
            backend: "test",
            wordTimings: timings
        )
        XCTAssertEqual(result.wordTimings.count, 2)
        XCTAssertEqual(result.wordTimings[0].word, "hello")
    }
}
