import XCTest
@testable import JackApp

/// Covers the migration decision only — the keychain calls themselves need a
/// real keychain and a signed host, which is not something a unit test should
/// depend on. The decision is where the risk lives anyway: it is what decides
/// whether a corrupted key gets carried forward into its new home.
final class OpenRouterKeyMigrationTests: XCTestCase {

    // MARK: - Shape detection

    func testRecognisesARealKey() {
        XCTAssertTrue(OpenRouterKeyMigration.looksLikeAPIKey("sk-or-v1-0123456789abcdef0123456789abcdef"))
    }

    func testTolerartesSurroundingWhitespace() {
        XCTAssertTrue(OpenRouterKeyMigration.looksLikeAPIKey("  sk-or-v1-0123456789abcdef0123456789abcdef\n"))
    }

    /// The exact failure that started this: a dictation landed in the focused
    /// Settings field and replaced the key with the sentence.
    func testRejectsADictationTranscript() {
        XCTAssertFalse(OpenRouterKeyMigration.looksLikeAPIKey("I have to buy bananas."))
    }

    func testRejectsEmptyAndShortValues() {
        XCTAssertFalse(OpenRouterKeyMigration.looksLikeAPIKey(""))
        XCTAssertFalse(OpenRouterKeyMigration.looksLikeAPIKey("sk-or-v1-"))
    }

    /// A key with an embedded space is not a key, however well it starts —
    /// this is what catches a transcript that happens to begin with the prefix.
    func testRejectsInternalWhitespace() {
        XCTAssertFalse(OpenRouterKeyMigration.looksLikeAPIKey("sk-or-v1-abc def ghi jkl mno pqr stu"))
    }

    func testRejectsAKeyForADifferentService() {
        XCTAssertFalse(OpenRouterKeyMigration.looksLikeAPIKey("sk-proj-0123456789abcdef0123456789"))
    }

    // MARK: - Migration plan

    func testKeychainValueWinsOverLegacy() {
        let plan = OpenRouterKeyMigration.plan(
            keychainValue: "sk-or-v1-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            legacyValue: "sk-or-v1-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        )
        XCTAssertEqual(plan, .keychainWins)
    }

    /// Even a corrupt legacy value must not displace a good keychain value.
    func testKeychainValueWinsOverCorruptLegacy() {
        let plan = OpenRouterKeyMigration.plan(
            keychainValue: "sk-or-v1-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            legacyValue: "I have to buy bananas."
        )
        XCTAssertEqual(plan, .keychainWins)
    }

    func testMigratesAGoodLegacyKey() {
        let key = "sk-or-v1-cccccccccccccccccccccccccccccccc"
        XCTAssertEqual(
            OpenRouterKeyMigration.plan(keychainValue: nil, legacyValue: key),
            .migrate(key)
        )
    }

    func testEmptyKeychainStringCountsAsAbsent() {
        let key = "sk-or-v1-dddddddddddddddddddddddddddddddd"
        XCTAssertEqual(
            OpenRouterKeyMigration.plan(keychainValue: "", legacyValue: key),
            .migrate(key)
        )
    }

    /// The corrupted value is dropped rather than carried into the keychain,
    /// so the user gets "no key" (which the UI says out loud) instead of a
    /// key that fails every call.
    func testDiscardsCorruptLegacyValue() {
        XCTAssertEqual(
            OpenRouterKeyMigration.plan(keychainValue: nil, legacyValue: "I have to buy bananas."),
            .discard
        )
    }

    func testDiscardsWhenNothingIsStoredAnywhere() {
        XCTAssertEqual(OpenRouterKeyMigration.plan(keychainValue: nil, legacyValue: nil), .discard)
        XCTAssertEqual(OpenRouterKeyMigration.plan(keychainValue: nil, legacyValue: ""), .discard)
    }
}

/// The router's failure taxonomy: which OpenRouter errors are worth telling the
/// user about, and which are transient noise that the dictation fallback should
/// keep absorbing.
final class OpenRouterFailureTests: XCTestCase {

    func testRejectedKeyIsAnAuthFailure() {
        XCTAssertTrue(OpenRouterClient.Failure.http(status: 401, body: "").isAuthFailure)
        XCTAssertTrue(OpenRouterClient.Failure.http(status: 403, body: "").isAuthFailure)
        XCTAssertTrue(OpenRouterClient.Failure.missingKey.isAuthFailure)
    }

    /// Rate limits and upstream outages fix themselves; surfacing them would
    /// train the user to ignore the banner that matters.
    func testTransientErrorsAreNotAuthFailures() {
        XCTAssertFalse(OpenRouterClient.Failure.http(status: 429, body: "").isAuthFailure)
        XCTAssertFalse(OpenRouterClient.Failure.http(status: 502, body: "").isAuthFailure)
        XCTAssertFalse(OpenRouterClient.Failure.malformedResponse.isAuthFailure)
    }

    func testSummaryNamesTheKeyForAuthFailures() {
        let summary = OpenRouterClient.Failure.http(status: 401, body: "Missing Authentication header").userFacingSummary
        XCTAssertTrue(summary.contains("401"))
        XCTAssertTrue(summary.lowercased().contains("key"))
    }

    /// The body can carry the key back in an echoed request; the short summary
    /// goes on screen, so it must never include it.
    func testSummaryDoesNotLeakTheResponseBody() {
        let summary = OpenRouterClient.Failure.http(status: 401, body: "sk-or-v1-secret").userFacingSummary
        XCTAssertFalse(summary.contains("sk-or-v1-secret"))
    }
}

/// The classifier's contract with its caller: it never throws, and it flags an
/// auth failure instead of hiding it inside the plain-dictation fallback.
final class IntentClassifierAuthTests: XCTestCase {

    func testEmptyKeyReportsAuthFailureAndFallsBackToDictation() async {
        let verdict = await IntentClassifier().classify(
            IntentContext(transcript: "I have to buy bananas."),
            model: "google/gemini-2.5-flash-lite",
            apiKey: ""
        )
        XCTAssertEqual(verdict.intent, .dictation)
        XCTAssertEqual(verdict.confidence, 0)
        XCTAssertNotNil(verdict.authFailure)
    }

    /// A well-formed verdict carries no auth failure — this is what keeps the
    /// red dot off the screen during normal operation.
    func testParsedVerdictHasNoAuthFailure() throws {
        let verdict = try XCTUnwrap(
            IntentClassifier.parse(#"{"kind":"todo","confidence":0.9,"reason":"buy bananas"}"#, backend: "test")
        )
        XCTAssertEqual(verdict.intent, .todo)
        XCTAssertEqual(verdict.confidence, 0.9, accuracy: 0.001)
        XCTAssertNil(verdict.authFailure)
    }
}
