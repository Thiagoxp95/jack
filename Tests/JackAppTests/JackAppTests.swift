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

final class FuzzyMatchTests: XCTestCase {
    private let catalog = [
        LLMModelInfo(id: "google/gemini-3.1-flash-lite", name: "Google: Gemini 3.1 Flash Lite", contextLength: 1_048_576, isFree: false),
        LLMModelInfo(id: "google/gemini-3.1-flash-lite-image", name: "Google: Gemini 3.1 Flash Lite Image", contextLength: 65_536, isFree: false),
        LLMModelInfo(id: "anthropic/claude-haiku-4.5", name: "Anthropic: Claude Haiku 4.5", contextLength: 200_000, isFree: false),
        LLMModelInfo(id: "openai/gpt-5-nano", name: "OpenAI: GPT-5 Nano", contextLength: 400_000, isFree: false),
    ]

    func testAbbreviationMatchesAcrossSegments() {
        // "g31fl" is a subsequence of the id — a contains() filter finds nothing.
        let ranked = FuzzyMatch.rank(query: "g31fl", models: catalog)
        XCTAssertEqual(ranked.first?.id, "google/gemini-3.1-flash-lite")
    }

    func testShorterCandidateWinsTieOnPrefixMatch() {
        let ranked = FuzzyMatch.rank(query: "gemini31flashlite", models: catalog)
        XCTAssertEqual(ranked.first?.id, "google/gemini-3.1-flash-lite")
        XCTAssertEqual(ranked.count, 2)
    }

    func testNonSubsequenceIsExcluded() {
        XCTAssertNil(FuzzyMatch.score(query: "zzz", candidate: "google/gemini-3.1-flash-lite"))
        XCTAssertTrue(FuzzyMatch.rank(query: "zzz", models: catalog).isEmpty)
    }

    func testEmptyQueryReturnsCatalogUnchanged() {
        XCTAssertEqual(FuzzyMatch.rank(query: "   ", models: catalog).map(\.id), catalog.map(\.id))
    }

    func testMatchesOnDisplayNameNotJustId() {
        let ranked = FuzzyMatch.rank(query: "anthropic claude", models: catalog)
        XCTAssertEqual(ranked.first?.id, "anthropic/claude-haiku-4.5")
    }
}

final class CleanupGuardTests: XCTestCase {
    func testRejectsAnswerToTheTranscript() {
        // The reported failure: the model answered instead of cleaning.
        XCTAssertFalse(DictationController.resemblesCleanup(
            of: "Witch LLM model are you?",
            candidate: "I am Google Gemini."
        ))
    }

    func testAcceptsOrdinaryFillerRemoval() {
        XCTAssertTrue(DictationController.resemblesCleanup(
            of: "so um I mean like the thing is you know basically it works",
            candidate: "The thing is, it works."
        ))
    }

    func testAcceptsTechNameCorrections() {
        XCTAssertTrue(DictationController.resemblesCleanup(
            of: "I was using cloud code with super base and versa cell yesterday",
            candidate: "I was using Claude Code with Supabase and Vercel yesterday."
        ))
    }

    func testAcceptsQuestionCleanedAsAQuestion() {
        XCTAssertTrue(DictationController.resemblesCleanup(
            of: "Witch LLM model are you?",
            candidate: "Which LLM model are you?"
        ))
    }

    func testShortTranscriptsSkipTheGuard() {
        // Too few words for the ratio to mean anything; upstream handles empties.
        XCTAssertTrue(DictationController.resemblesCleanup(of: "cloud code", candidate: "Claude Code"))
    }
}

final class GroqCatalogTests: XCTestCase {
    private let raw: [[String: Any]] = [
        ["id": "llama-3.1-8b-instant", "active": true, "context_window": 131_072],
        ["id": "whisper-large-v3-turbo", "active": true, "context_window": 448],
        ["id": "playai-tts", "active": true],
        ["id": "openai/gpt-oss-120b", "active": true, "context_window": 131_072],
        ["id": "retired-model", "active": false, "context_window": 8_192],
        ["context_window": 4_096], // no id at all
    ]

    func testSpeechModelsAreExcluded() {
        // Whisper and TTS 400 on /chat/completions, so a cleanup picker that
        // offers them is offering a guaranteed failure.
        let ids = GroqClient.parseModels(raw).map(\.id)
        XCTAssertFalse(ids.contains("whisper-large-v3-turbo"))
        XCTAssertFalse(ids.contains("playai-tts"))
    }

    func testInactiveAndMalformedEntriesAreDropped() {
        let ids = GroqClient.parseModels(raw).map(\.id)
        XCTAssertFalse(ids.contains("retired-model"))
        XCTAssertEqual(ids, ["llama-3.1-8b-instant", "openai/gpt-oss-120b"])
    }

    func testContextWindowMapsToContextLength() {
        let model = GroqClient.parseModels(raw).first { $0.id == "llama-3.1-8b-instant" }
        XCTAssertEqual(model?.contextLength, 131_072)
        // Groq has no free tier in the catalog sense; a "free" badge would lie.
        XCTAssertEqual(model?.isFree, false)
    }
}

final class CleanupProviderTests: XCTestCase {
    func testStoredValueRoundTrips() {
        XCTAssertEqual(CleanupProvider.resolve("groq"), .groq)
        XCTAssertEqual(CleanupProvider.resolve("openrouter"), .openRouter)
    }

    func testUnknownOrMissingValueFallsBackToOpenRouter() {
        // A downgrade must not strand cleanup on a provider that no longer exists.
        XCTAssertEqual(CleanupProvider.resolve(nil), .openRouter)
        XCTAssertEqual(CleanupProvider.resolve("anthropic"), .openRouter)
    }
}
