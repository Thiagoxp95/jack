import XCTest
@testable import KinshasaApp

final class GestureZoomDetectorTests: XCTestCase {

    // MARK: - Jiggle Detection

    func testNoEventsReturnsEmpty() {
        let result = GestureZoomDetector.detect(events: [])
        XCTAssertTrue(result.isEmpty)
    }

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

    func testHorizontalJiggleTriggersZoom() {
        var events: [CursorEvent] = []
        let baseTime = 1.0
        for i in 0..<8 {
            let t = baseTime + Double(i) * 0.05
            let x = i % 2 == 0 ? 500.0 : 600.0
            events.append(CursorEvent(t: t, x: x, y: 300.0))
        }
        events.insert(CursorEvent(t: 0.0, x: 500.0, y: 300.0), at: 0)
        events.append(CursorEvent(t: 10.0, x: 500.0, y: 300.0))

        let result = GestureZoomDetector.detect(events: events)
        XCTAssertEqual(result.count, 1, "Jiggle should produce one zoom region")
        XCTAssertEqual(result.first?.zoomLevel, 2.0)
    }

    // MARK: - Circle Detection

    func testCircularMotionTriggersZoom() {
        var events: [CursorEvent] = []
        events.append(CursorEvent(t: 0.0, x: 500.0, y: 300.0))

        let centerX = 500.0
        let centerY = 300.0
        let radius = 80.0
        let numPoints = 30
        for i in 0..<numPoints {
            let t = 1.0 + Double(i) * (0.8 / Double(numPoints))
            let angle = (Double(i) / Double(numPoints)) * 2.0 * .pi
            let x = centerX + radius * cos(angle)
            let y = centerY + radius * sin(angle)
            events.append(CursorEvent(t: t, x: x, y: y))
        }
        events.append(CursorEvent(t: 10.0, x: 500.0, y: 300.0))

        let result = GestureZoomDetector.detect(events: events)
        XCTAssertEqual(result.count, 1, "Circular motion should produce one zoom region")
        XCTAssertEqual(result.first?.zoomLevel, 2.0)
    }

    func testSmallArcDoesNotTrigger() {
        var events: [CursorEvent] = []
        events.append(CursorEvent(t: 0.0, x: 500.0, y: 300.0))

        let centerX = 500.0
        let centerY = 300.0
        let radius = 80.0
        let numPoints = 10
        for i in 0..<numPoints {
            let t = 1.0 + Double(i) * 0.05
            let angle = (Double(i) / Double(numPoints)) * 0.5 * .pi
            let x = centerX + radius * cos(angle)
            let y = centerY + radius * sin(angle)
            events.append(CursorEvent(t: t, x: x, y: y))
        }
        events.append(CursorEvent(t: 10.0, x: 500.0, y: 300.0))

        let result = GestureZoomDetector.detect(events: events)
        XCTAssertTrue(result.isEmpty, "Small arc should not trigger circle detection")
    }

    // MARK: - Tail Duration

    func testJiggleZoomRegionIncludesTail() {
        var events: [CursorEvent] = []
        events.append(CursorEvent(t: 0.0, x: 500.0, y: 300.0))
        for i in 0..<8 {
            let t = 1.0 + Double(i) * 0.05
            let x = i % 2 == 0 ? 500.0 : 600.0
            events.append(CursorEvent(t: t, x: x, y: 300.0))
        }
        events.append(CursorEvent(t: 10.0, x: 500.0, y: 300.0))

        let result = GestureZoomDetector.detect(events: events)
        XCTAssertEqual(result.count, 1)
        guard let keyframe = result.first else { return }

        XCTAssertLessThanOrEqual(keyframe.startTime, 1.25)
        XCTAssertGreaterThanOrEqual(keyframe.endTime, 4.0)
        XCTAssertLessThanOrEqual(keyframe.endTime, 5.0)
    }

    // MARK: - Merging

    func testNearbyGesturesMergeIntoOneRegion() {
        var events: [CursorEvent] = []
        events.append(CursorEvent(t: 0.0, x: 500.0, y: 300.0))

        // First jiggle at t=1.0
        for i in 0..<8 {
            let t = 1.0 + Double(i) * 0.05
            let x = i % 2 == 0 ? 500.0 : 600.0
            events.append(CursorEvent(t: t, x: x, y: 300.0))
        }

        // Quiet gap
        events.append(CursorEvent(t: 2.0, x: 500.0, y: 300.0))

        // Second jiggle at t=2.5
        for i in 0..<8 {
            let t = 2.5 + Double(i) * 0.05
            let x = i % 2 == 0 ? 500.0 : 600.0
            events.append(CursorEvent(t: t, x: x, y: 300.0))
        }

        events.append(CursorEvent(t: 20.0, x: 500.0, y: 300.0))

        let result = GestureZoomDetector.detect(events: events)
        XCTAssertEqual(result.count, 1, "Nearby jiggles should merge into one zoom region")
    }

    func testDistantGesturesRemainSeparate() {
        var events: [CursorEvent] = []
        events.append(CursorEvent(t: 0.0, x: 500.0, y: 300.0))

        // First jiggle at t=1.0
        for i in 0..<8 {
            let t = 1.0 + Double(i) * 0.05
            let x = i % 2 == 0 ? 500.0 : 600.0
            events.append(CursorEvent(t: t, x: x, y: 300.0))
        }

        // Long quiet period
        events.append(CursorEvent(t: 8.0, x: 500.0, y: 300.0))

        // Second jiggle at t=15.0
        for i in 0..<8 {
            let t = 15.0 + Double(i) * 0.05
            let x = i % 2 == 0 ? 500.0 : 600.0
            events.append(CursorEvent(t: t, x: x, y: 300.0))
        }

        events.append(CursorEvent(t: 30.0, x: 500.0, y: 300.0))

        let result = GestureZoomDetector.detect(events: events)
        XCTAssertEqual(result.count, 2, "Distant jiggles should remain separate zoom regions")
    }

    // MARK: - False Positive Rejection

    func testSmallAmplitudeJiggleDoesNotTrigger() {
        // Rapid back-and-forth but only ~20px wide — too small, not a deliberate highlight
        var events: [CursorEvent] = []
        events.append(CursorEvent(t: 0.0, x: 500.0, y: 300.0))
        for i in 0..<12 {
            let t = 1.0 + Double(i) * 0.04
            let x = i % 2 == 0 ? 500.0 : 520.0  // only 20px spread
            events.append(CursorEvent(t: t, x: x, y: 300.0))
        }
        events.append(CursorEvent(t: 10.0, x: 500.0, y: 300.0))

        let result = GestureZoomDetector.detect(events: events)
        XCTAssertTrue(result.isEmpty, "Small amplitude jiggle (<50px) should not trigger zoom")
    }

    func testSmallRadiusCircleDoesNotTrigger() {
        // Full circle but only ~15px radius — too tight, not a deliberate highlight
        var events: [CursorEvent] = []
        events.append(CursorEvent(t: 0.0, x: 500.0, y: 300.0))

        let centerX = 500.0
        let centerY = 300.0
        let radius = 15.0  // ~3mm on screen, too small
        let numPoints = 30
        for i in 0..<numPoints {
            let t = 1.0 + Double(i) * (0.8 / Double(numPoints))
            let angle = (Double(i) / Double(numPoints)) * 2.0 * .pi
            let x = centerX + radius * cos(angle)
            let y = centerY + radius * sin(angle)
            events.append(CursorEvent(t: t, x: x, y: y))
        }
        events.append(CursorEvent(t: 10.0, x: 500.0, y: 300.0))

        let result = GestureZoomDetector.detect(events: events)
        XCTAssertTrue(result.isEmpty, "Small radius circle (<25px) should not trigger zoom")
    }

    func testVerticalJiggleDoesNotTrigger() {
        // Rapid up-down movement — we only detect left-right scratching
        var events: [CursorEvent] = []
        events.append(CursorEvent(t: 0.0, x: 500.0, y: 300.0))
        for i in 0..<12 {
            let t = 1.0 + Double(i) * 0.04
            let y = i % 2 == 0 ? 200.0 : 400.0  // big vertical swing
            events.append(CursorEvent(t: t, x: 500.0, y: y))  // X stays constant
        }
        events.append(CursorEvent(t: 10.0, x: 500.0, y: 300.0))

        let result = GestureZoomDetector.detect(events: events)
        XCTAssertTrue(result.isEmpty, "Vertical-only movement should not trigger zoom")
    }

    // MARK: - Edge Cases

    func testTooFewEventsReturnsEmpty() {
        let events = [
            CursorEvent(t: 0.0, x: 100.0, y: 100.0),
            CursorEvent(t: 0.5, x: 200.0, y: 100.0),
        ]
        let result = GestureZoomDetector.detect(events: events)
        XCTAssertTrue(result.isEmpty)
    }

    func testZoomEndTimeExtendsPastRecording() {
        // Jiggle near the very end of recording
        var events: [CursorEvent] = []
        events.append(CursorEvent(t: 0.0, x: 500.0, y: 300.0))
        for i in 0..<8 {
            let t = 9.6 + Double(i) * 0.05
            let x = i % 2 == 0 ? 500.0 : 600.0
            events.append(CursorEvent(t: t, x: x, y: 300.0))
        }
        events.append(CursorEvent(t: 10.0, x: 500.0, y: 300.0))

        let result = GestureZoomDetector.detect(events: events)
        XCTAssertEqual(result.count, 1)
        // Tail extends past recording — the editor/renderer will clamp to video duration
        XCTAssertGreaterThan(result.first?.endTime ?? 0, 10.0)
    }
}
