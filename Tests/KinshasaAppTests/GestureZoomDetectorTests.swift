import XCTest
@testable import KinshasaApp

final class GestureZoomDetectorTests: XCTestCase {

    // MARK: - Helpers

    /// Generate a lottery-ticket scratch: rapid left-right at ~20px amplitude.
    private func makeScratchEvents(
        at startTime: Double,
        oscillations: Int = 8,
        amplitude: Double = 20.0,
        interval: Double = 0.03,
        centerX: Double = 500.0,
        centerY: Double = 300.0
    ) -> [CursorEvent] {
        var events: [CursorEvent] = []
        for i in 0..<(oscillations * 2) {
            let t = startTime + Double(i) * interval
            let x = i % 2 == 0 ? centerX - amplitude : centerX + amplitude
            events.append(CursorEvent(t: t, x: x, y: centerY))
        }
        return events
    }

    // MARK: - Basic Guards

    func testNoEventsReturnsEmpty() {
        let result = GestureZoomDetector.detect(events: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testTooFewEventsReturnsEmpty() {
        let events = [
            CursorEvent(t: 0.0, x: 100.0, y: 100.0),
            CursorEvent(t: 0.5, x: 200.0, y: 100.0),
        ]
        let result = GestureZoomDetector.detect(events: events)
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - False Positive Rejection

    func testSteadyCursorProducesNoZoom() {
        let events = (0..<100).map { i in
            CursorEvent(t: Double(i) * 0.05, x: 500.0 + Double(i) * 0.1, y: 300.0)
        }
        let result = GestureZoomDetector.detect(events: events)
        XCTAssertTrue(result.isEmpty, "Steady cursor should not trigger zoom")
    }

    func testLinearMovementProducesNoZoom() {
        let events = (0..<100).map { i in
            CursorEvent(t: Double(i) * 0.01, x: Double(i) * 10.0, y: 300.0)
        }
        let result = GestureZoomDetector.detect(events: events)
        XCTAssertTrue(result.isEmpty, "Linear movement should not trigger zoom")
    }

    func testNormalMouseNavigationDoesNotTrigger() {
        // Simulate: move to button, pause, move to another button, pause, click
        // This has direction changes but they're slow and separated
        let events: [CursorEvent] = [
            CursorEvent(t: 0.0, x: 100.0, y: 100.0),
            CursorEvent(t: 0.1, x: 200.0, y: 150.0),
            CursorEvent(t: 0.2, x: 300.0, y: 150.0),
            CursorEvent(t: 0.5, x: 280.0, y: 140.0),  // small correction
            CursorEvent(t: 0.6, x: 290.0, y: 145.0),  // another correction
            CursorEvent(t: 1.0, x: 500.0, y: 200.0),
            CursorEvent(t: 1.1, x: 480.0, y: 195.0),  // overshoot correction
            CursorEvent(t: 1.2, x: 490.0, y: 198.0),
            CursorEvent(t: 1.5, x: 600.0, y: 300.0),
            CursorEvent(t: 2.0, x: 610.0, y: 305.0),
            CursorEvent(t: 2.5, x: 400.0, y: 250.0),
            CursorEvent(t: 3.0, x: 410.0, y: 248.0),
            CursorEvent(t: 3.5, x: 300.0, y: 200.0),
            CursorEvent(t: 4.0, x: 310.0, y: 205.0),
            CursorEvent(t: 5.0, x: 500.0, y: 300.0),
        ]
        let result = GestureZoomDetector.detect(events: events)
        XCTAssertTrue(result.isEmpty, "Normal mouse navigation should not trigger zoom")
    }

    func testSlowBackAndForthDoesNotTrigger() {
        // Moving left-right but slowly — only 2-3 reversals in a second
        var events: [CursorEvent] = []
        events.append(CursorEvent(t: 0.0, x: 500.0, y: 300.0))
        for i in 0..<6 {
            let t = 1.0 + Double(i) * 0.25  // 250ms between each = too slow
            let x = i % 2 == 0 ? 480.0 : 520.0
            events.append(CursorEvent(t: t, x: x, y: 300.0))
        }
        events.append(CursorEvent(t: 10.0, x: 500.0, y: 300.0))

        let result = GestureZoomDetector.detect(events: events)
        XCTAssertTrue(result.isEmpty, "Slow back-and-forth should not trigger zoom")
    }

    // MARK: - Scratch Detection

    func testRapidScratchTriggersZoom() {
        // Lottery ticket scratch: ~20px left-right, 8 oscillations in ~0.5s
        var events: [CursorEvent] = []
        events.append(CursorEvent(t: 0.0, x: 500.0, y: 300.0))
        events.append(contentsOf: makeScratchEvents(at: 1.0))
        events.append(CursorEvent(t: 10.0, x: 500.0, y: 300.0))

        let result = GestureZoomDetector.detect(events: events)
        XCTAssertEqual(result.count, 1, "Rapid scratch should produce one zoom region")
        XCTAssertEqual(result.first?.zoomLevel, 2.0)
    }

    func testScratchZoomRegionIncludesTail() {
        var events: [CursorEvent] = []
        events.append(CursorEvent(t: 0.0, x: 500.0, y: 300.0))
        events.append(contentsOf: makeScratchEvents(at: 1.0))
        events.append(CursorEvent(t: 10.0, x: 500.0, y: 300.0))

        let result = GestureZoomDetector.detect(events: events)
        XCTAssertEqual(result.count, 1)
        guard let keyframe = result.first else { return }

        // Scratch starts ~1.0s, ends ~1.48s, tail adds 3.0s → endTime ~4.48s
        XCTAssertLessThanOrEqual(keyframe.startTime, 1.5)
        XCTAssertGreaterThanOrEqual(keyframe.endTime, 4.0)
        XCTAssertLessThanOrEqual(keyframe.endTime, 5.5)
    }

    // MARK: - Merging

    func testNearbyScratchesMerge() {
        var events: [CursorEvent] = []
        events.append(CursorEvent(t: 0.0, x: 500.0, y: 300.0))
        events.append(contentsOf: makeScratchEvents(at: 1.0))
        events.append(CursorEvent(t: 2.0, x: 500.0, y: 300.0))
        events.append(contentsOf: makeScratchEvents(at: 2.5))
        events.append(CursorEvent(t: 20.0, x: 500.0, y: 300.0))

        let result = GestureZoomDetector.detect(events: events)
        XCTAssertEqual(result.count, 1, "Nearby scratches should merge into one zoom region")
    }

    func testDistantScratchesRemainSeparate() {
        var events: [CursorEvent] = []
        events.append(CursorEvent(t: 0.0, x: 500.0, y: 300.0))
        events.append(contentsOf: makeScratchEvents(at: 1.0))
        events.append(CursorEvent(t: 8.0, x: 500.0, y: 300.0))
        events.append(contentsOf: makeScratchEvents(at: 15.0))
        events.append(CursorEvent(t: 30.0, x: 500.0, y: 300.0))

        let result = GestureZoomDetector.detect(events: events)
        XCTAssertEqual(result.count, 2, "Distant scratches should remain separate")
    }

    func testZoomEndTimeExtendsPastRecording() {
        var events: [CursorEvent] = []
        events.append(CursorEvent(t: 0.0, x: 500.0, y: 300.0))
        events.append(contentsOf: makeScratchEvents(at: 9.5))
        events.append(CursorEvent(t: 10.0, x: 500.0, y: 300.0))

        let result = GestureZoomDetector.detect(events: events)
        XCTAssertEqual(result.count, 1)
        XCTAssertGreaterThan(result.first?.endTime ?? 0, 10.0)
    }
}
