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
        let suiteName = "kinshasa-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

final class ZoomInterpolationTests: XCTestCase {
    // Test: outside all keyframes returns 1.0
    func testInterpolateZoomReturns1WhenNoKeyframeActive() {
        let keyframes = [ZoomKeyframe(startTime: 2.0, endTime: 5.0, zoomLevel: 2.0)]
        let result = MetalVideoRenderer.interpolateZoom(at: 0.5, keyframes: keyframes, rampDuration: 0.6)
        XCTAssertEqual(result, 1.0, accuracy: 0.001)
    }

    // Test: plateau returns full zoom level
    func testInterpolateZoomReturnsPlateau() {
        let keyframes = [ZoomKeyframe(startTime: 0.0, endTime: 5.0, zoomLevel: 2.0)]
        let result = MetalVideoRenderer.interpolateZoom(at: 2.5, keyframes: keyframes, rampDuration: 0.6)
        XCTAssertEqual(result, 2.0, accuracy: 0.001)
    }

    // Test: ease-in phase starts at 1.0
    func testInterpolateZoomEaseInStartsAt1() {
        let keyframes = [ZoomKeyframe(startTime: 0.0, endTime: 5.0, zoomLevel: 2.0)]
        let result = MetalVideoRenderer.interpolateZoom(at: 0.0, keyframes: keyframes, rampDuration: 0.6)
        XCTAssertEqual(result, 1.0, accuracy: 0.001)
    }

    // Test: ease-in phase reaches full zoom at ramp boundary
    func testInterpolateZoomEaseInReachesFullZoom() {
        let keyframes = [ZoomKeyframe(startTime: 0.0, endTime: 5.0, zoomLevel: 2.0)]
        let result = MetalVideoRenderer.interpolateZoom(at: 0.6, keyframes: keyframes, rampDuration: 0.6)
        XCTAssertEqual(result, 2.0, accuracy: 0.001)
    }

    // Test: ease-out phase returns to 1.0 at end
    func testInterpolateZoomEaseOutReturnsTo1() {
        let keyframes = [ZoomKeyframe(startTime: 0.0, endTime: 5.0, zoomLevel: 2.0)]
        let result = MetalVideoRenderer.interpolateZoom(at: 5.0, keyframes: keyframes, rampDuration: 0.6)
        XCTAssertEqual(result, 1.0, accuracy: 0.001)
    }

    // Test: midpoint of ease-in is NOT 0.5 (asymmetric curve, ease-out cubic)
    func testInterpolateZoomEaseInMidpointIsAsymmetric() {
        let keyframes = [ZoomKeyframe(startTime: 0.0, endTime: 5.0, zoomLevel: 2.0)]
        let result = MetalVideoRenderer.interpolateZoom(at: 0.3, keyframes: keyframes, rampDuration: 0.6)
        // ease-out cubic at t=0.5 is 1-(1-0.5)^3 = 0.875
        XCTAssertEqual(result, 1.0 + (2.0 - 1.0) * 0.875, accuracy: 0.001)
    }

    // Test: short keyframe clamps ramp to half duration
    func testInterpolateZoomShortKeyframeClamps() {
        let keyframes = [ZoomKeyframe(startTime: 0.0, endTime: 0.8, zoomLevel: 2.0)]
        // Ramp clamps to 0.4s. At t=0.2 (midpoint of ramp), ease-out cubic at 0.5
        let result = MetalVideoRenderer.interpolateZoom(at: 0.2, keyframes: keyframes, rampDuration: 0.6)
        let eased = 1.0 - pow(1.0 - 0.5, 3) // 0.875
        XCTAssertEqual(result, 1.0 + (2.0 - 1.0) * eased, accuracy: 0.001)
    }
}
