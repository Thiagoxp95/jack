import XCTest
@testable import JackApp

final class GestureZoomDetectorTests: XCTestCase {

    // MARK: - Helpers

    /// Generate realistic scratch cursor data: pixel-by-pixel movement
    /// simulating CGEvent tap output during a left-right scratch.
    ///
    /// - Parameters:
    ///   - startTime: when the scratch starts
    ///   - oscillations: number of full left-right cycles
    ///   - amplitude: pixels to each side of center (~20px for lottery scratch)
    ///   - frequency: oscillations per second (~5 Hz for a fast scratch)
    ///   - eventRate: simulated CGEvent tap rate in Hz (125 for USB mouse)
    private func makeRealisticScratch(
        at startTime: Double,
        oscillations: Int = 5,
        amplitude: Double = 20.0,
        frequency: Double = 5.0,
        eventRate: Double = 125.0,
        centerX: Double = 500.0,
        centerY: Double = 300.0
    ) -> [CursorEvent] {
        let totalDuration = Double(oscillations) / frequency
        let eventCount = Int(totalDuration * eventRate)
        var events: [CursorEvent] = []

        for i in 0..<eventCount {
            let t = startTime + Double(i) / eventRate
            // Sine wave for smooth left-right motion
            let phase = 2.0 * .pi * frequency * Double(i) / eventRate
            let x = centerX + amplitude * sin(phase)
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
        // Cursor barely moves — simulates idle
        let events = (0..<200).map { i in
            CursorEvent(t: Double(i) * 0.008, x: 500.0 + Double(i) * 0.05, y: 300.0)
        }
        let result = GestureZoomDetector.detect(events: events)
        XCTAssertTrue(result.isEmpty, "Steady cursor should not trigger zoom")
    }

    func testLinearMovementProducesNoZoom() {
        // Cursor moves steadily to the right
        let events = (0..<200).map { i in
            CursorEvent(t: Double(i) * 0.008, x: Double(i) * 2.0, y: 300.0)
        }
        let result = GestureZoomDetector.detect(events: events)
        XCTAssertTrue(result.isEmpty, "Linear movement should not trigger zoom")
    }

    func testNormalMouseNavigationDoesNotTrigger() {
        // Realistic: move to target, small overshoot correction, move to next target
        // Generates pixel-by-pixel events at 125Hz
        var events: [CursorEvent] = []
        let rate = 125.0

        // Move right 200px over 0.3s
        for i in 0..<38 {
            let t = Double(i) / rate
            events.append(CursorEvent(t: t, x: 100.0 + Double(i) * 5.3, y: 200.0))
        }
        // Small 5px correction left over 0.05s
        for i in 0..<6 {
            let t = 0.3 + Double(i) / rate
            events.append(CursorEvent(t: t, x: 300.0 - Double(i) * 0.8, y: 200.0))
        }
        // Pause 0.5s
        events.append(CursorEvent(t: 0.85, x: 295.0, y: 200.0))
        // Move left 150px over 0.25s
        for i in 0..<31 {
            let t = 0.85 + Double(i) / rate
            events.append(CursorEvent(t: t, x: 295.0 - Double(i) * 4.8, y: 200.0))
        }
        // Small 3px correction right
        for i in 0..<4 {
            let t = 1.1 + Double(i) / rate
            events.append(CursorEvent(t: t, x: 145.0 + Double(i) * 0.8, y: 200.0))
        }
        events.append(CursorEvent(t: 2.0, x: 148.0, y: 200.0))

        let result = GestureZoomDetector.detect(events: events)
        XCTAssertTrue(result.isEmpty, "Normal mouse navigation should not trigger zoom")
    }

    func testSlowBackAndForthDoesNotTrigger() {
        // Slow deliberate left-right, ~1 Hz — not a scratch
        let events = makeRealisticScratch(
            at: 0.0, oscillations: 3, amplitude: 20.0, frequency: 1.0
        )
        var all = events
        all.append(CursorEvent(t: 10.0, x: 500.0, y: 300.0))

        let result = GestureZoomDetector.detect(events: all)
        XCTAssertTrue(result.isEmpty, "Slow 1Hz back-and-forth should not trigger zoom")
    }

    // MARK: - Scratch Detection

    func testRealisticScratchTriggersZoom() {
        // 5 Hz scratch, 20px amplitude, 125Hz event rate — the real deal
        var events: [CursorEvent] = []
        events.append(CursorEvent(t: 0.0, x: 500.0, y: 300.0))
        events.append(contentsOf: makeRealisticScratch(at: 1.0))
        events.append(CursorEvent(t: 10.0, x: 500.0, y: 300.0))

        let result = GestureZoomDetector.detect(events: events)
        XCTAssertEqual(result.count, 1, "Realistic scratch should produce one zoom region")
        XCTAssertEqual(result.first?.zoomLevel, 2.0)
    }

    func testScratchZoomRegionIncludesTail() {
        var events: [CursorEvent] = []
        events.append(CursorEvent(t: 0.0, x: 500.0, y: 300.0))
        events.append(contentsOf: makeRealisticScratch(at: 1.0))
        events.append(CursorEvent(t: 10.0, x: 500.0, y: 300.0))

        let result = GestureZoomDetector.detect(events: events)
        XCTAssertEqual(result.count, 1)
        guard let keyframe = result.first else { return }

        // Scratch runs ~1.0-2.0s, tail adds 3.0s
        XCTAssertLessThanOrEqual(keyframe.startTime, 2.0)
        XCTAssertGreaterThanOrEqual(keyframe.endTime, 4.0)
    }

    func testFasterScratchAlsoTriggers() {
        // 8 Hz scratch — very aggressive scratching
        var events: [CursorEvent] = []
        events.append(CursorEvent(t: 0.0, x: 500.0, y: 300.0))
        events.append(contentsOf: makeRealisticScratch(
            at: 1.0, oscillations: 6, amplitude: 15.0, frequency: 8.0
        ))
        events.append(CursorEvent(t: 10.0, x: 500.0, y: 300.0))

        let result = GestureZoomDetector.detect(events: events)
        XCTAssertEqual(result.count, 1, "Fast 8Hz scratch should trigger zoom")
    }

    // MARK: - Merging

    func testNearbyScratchesMerge() {
        var events: [CursorEvent] = []
        events.append(CursorEvent(t: 0.0, x: 500.0, y: 300.0))
        events.append(contentsOf: makeRealisticScratch(at: 1.0, oscillations: 3))
        events.append(CursorEvent(t: 2.5, x: 500.0, y: 300.0))
        events.append(contentsOf: makeRealisticScratch(at: 3.0, oscillations: 3))
        events.append(CursorEvent(t: 20.0, x: 500.0, y: 300.0))

        let result = GestureZoomDetector.detect(events: events)
        XCTAssertEqual(result.count, 1, "Nearby scratches should merge into one zoom region")
    }

    func testDistantScratchesRemainSeparate() {
        var events: [CursorEvent] = []
        events.append(CursorEvent(t: 0.0, x: 500.0, y: 300.0))
        events.append(contentsOf: makeRealisticScratch(at: 1.0, oscillations: 3))
        events.append(CursorEvent(t: 8.0, x: 500.0, y: 300.0))
        events.append(contentsOf: makeRealisticScratch(at: 15.0, oscillations: 3))
        events.append(CursorEvent(t: 30.0, x: 500.0, y: 300.0))

        let result = GestureZoomDetector.detect(events: events)
        XCTAssertEqual(result.count, 2, "Distant scratches should remain separate")
    }

    func testZoomEndTimeExtendsPastRecording() {
        var events: [CursorEvent] = []
        events.append(CursorEvent(t: 0.0, x: 500.0, y: 300.0))
        events.append(contentsOf: makeRealisticScratch(at: 9.0, oscillations: 3))
        events.append(CursorEvent(t: 10.0, x: 500.0, y: 300.0))

        let result = GestureZoomDetector.detect(events: events)
        XCTAssertEqual(result.count, 1)
        XCTAssertGreaterThan(result.first?.endTime ?? 0, 10.0)
    }
}
