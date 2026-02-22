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
}
