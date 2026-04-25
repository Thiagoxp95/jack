# Gesture-Triggered Auto-Zoom Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Automatically detect mouse jiggle and circle gestures from recorded cursor data and pre-populate the editor's zoom timeline with 2.0x zoom keyframes.

**Architecture:** Post-recording analysis of `CursorTrackingData.events` using a sliding-window direction-reversal detector. A new `GestureZoomDetector` struct walks cursor events, identifies gesture regions, appends a 3-second tail, merges nearby regions, and returns `[ZoomKeyframe]`. These are injected into `VideoEditorController.zoomKeyframes` before the editor opens.

**Tech Stack:** Swift 6.2, Foundation (math only, no new dependencies)

---

### Task 1: GestureZoomDetector — Jiggle Detection Tests

**Files:**
- Create: `Tests/JackAppTests/GestureZoomDetectorTests.swift`

**Step 1: Write the failing tests**

```swift
import XCTest
@testable import JackApp

final class GestureZoomDetectorTests: XCTestCase {

    // MARK: - Jiggle Detection

    func testNoEventsReturnsEmpty() {
        let result = GestureZoomDetector.detect(events: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testSteadyCursorProducesNoZoom() {
        // Cursor barely moves over 5 seconds — no gesture
        let events = (0..<100).map { i in
            CursorEvent(t: Double(i) * 0.05, x: 500.0 + Double(i) * 0.1, y: 300.0)
        }
        let result = GestureZoomDetector.detect(events: events)
        XCTAssertTrue(result.isEmpty, "Steady cursor should not trigger zoom")
    }

    func testLinearMovementProducesNoZoom() {
        // Cursor moves steadily left to right — no reversals
        let events = (0..<100).map { i in
            CursorEvent(t: Double(i) * 0.01, x: Double(i) * 10.0, y: 300.0)
        }
        let result = GestureZoomDetector.detect(events: events)
        XCTAssertTrue(result.isEmpty, "Linear movement should not trigger zoom")
    }

    func testHorizontalJiggleTriggersZoom() {
        // Rapid left-right-left-right over 0.4 seconds
        var events: [CursorEvent] = []
        let baseTime = 1.0
        for i in 0..<8 {
            let t = baseTime + Double(i) * 0.05
            let x = i % 2 == 0 ? 500.0 : 600.0
            events.append(CursorEvent(t: t, x: x, y: 300.0))
        }
        // Add quiet period before and after so region boundaries are clean
        events.insert(CursorEvent(t: 0.0, x: 500.0, y: 300.0), at: 0)
        events.append(CursorEvent(t: 10.0, x: 500.0, y: 300.0))

        let result = GestureZoomDetector.detect(events: events)
        XCTAssertEqual(result.count, 1, "Jiggle should produce one zoom region")
        XCTAssertEqual(result.first?.zoomLevel, 2.0)
    }

    func testJiggleZoomRegionIncludesTail() {
        // Jiggle at t=1.0..1.4, expect zoom end = last gesture + 3.0s
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

        // Gesture starts around t=1.0, ends around t=1.35
        // Tail adds 3.0s, so endTime should be ~4.35
        XCTAssertLessThanOrEqual(keyframe.startTime, 1.1)
        XCTAssertGreaterThanOrEqual(keyframe.endTime, 4.0)
        XCTAssertLessThanOrEqual(keyframe.endTime, 5.0)
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter GestureZoomDetectorTests 2>&1 | tail -20`
Expected: FAIL — `GestureZoomDetector` does not exist yet

**Step 3: Commit**

```bash
git add Tests/JackAppTests/GestureZoomDetectorTests.swift
git commit -m "test: add jiggle detection tests for GestureZoomDetector"
```

---

### Task 2: GestureZoomDetector — Implement Jiggle Detection

**Files:**
- Create: `Sources/JackApp/ScreenRecording/GestureZoomDetector.swift`

**Step 1: Write the minimal implementation**

```swift
import Foundation

/// Detects mouse gesture patterns (jiggle, circle) in recorded cursor data
/// and returns zoom keyframes for the video editor.
struct GestureZoomDetector {

    // MARK: - Constants

    /// Time window for counting X-direction reversals (seconds).
    static let jiggleWindow: Double = 0.5

    /// Minimum X-velocity sign changes within the window to trigger jiggle.
    static let jiggleReversalThreshold: Int = 3

    /// Ignore velocity changes smaller than this (pixels per event gap).
    static let velocityDeadzone: Double = 2.0

    /// Time window for angular displacement analysis (seconds).
    static let circleWindow: Double = 1.0

    /// Minimum cumulative angle (radians) to trigger circle detection (~270 degrees).
    static let circleAngleThreshold: Double = 4.712

    /// How long the cursor must be still to end a gesture region (seconds).
    static let settleTimeout: Double = 0.3

    /// Extra zoom time appended after the gesture ends (seconds).
    static let zoomTailDuration: Double = 3.0

    /// Maximum gap between two gesture regions to merge them (seconds).
    static let mergeGapThreshold: Double = 2.0

    /// Zoom level assigned to all auto-detected regions.
    static let defaultZoomLevel: Double = 2.0

    // MARK: - Detection

    /// Analyze cursor events and return zoom keyframes for detected gestures.
    static func detect(events: [CursorEvent]) -> [ZoomKeyframe] {
        guard events.count >= 4 else { return [] }

        // Step 1: Mark each event as "in gesture" or not
        var gestureFlags = [Bool](repeating: false, count: events.count)

        for i in 0..<events.count {
            if isJiggle(events: events, at: i) {
                gestureFlags[i] = true
            }
        }

        // Step 2: Build gesture regions from contiguous flagged events
        var rawRegions = buildRegions(events: events, flags: gestureFlags)

        // Step 3: Add tail duration
        rawRegions = rawRegions.map { region in
            (start: region.start, end: region.end + zoomTailDuration)
        }

        // Step 4: Merge nearby regions
        let merged = mergeRegions(rawRegions)

        // Step 5: Convert to ZoomKeyframes
        return merged.map { region in
            ZoomKeyframe(
                startTime: region.start,
                endTime: region.end,
                zoomLevel: defaultZoomLevel
            )
        }
    }

    // MARK: - Jiggle Detector

    /// Check if the cursor is jiggling at the given event index
    /// by counting X-direction reversals in a trailing time window.
    private static func isJiggle(events: [CursorEvent], at index: Int) -> Bool {
        let currentTime = events[index].t
        let windowStart = currentTime - jiggleWindow

        // Collect events in the trailing window
        var reversals = 0
        var lastSign: Int = 0 // -1, 0, +1

        // Walk backward from index to find window start
        var start = index
        while start > 0 && events[start - 1].t >= windowStart {
            start -= 1
        }

        guard index - start >= 2 else { return false }

        for j in (start + 1)...index {
            let dx = events[j].x - events[j - 1].x
            let dt = events[j].t - events[j - 1].t
            guard dt > 0 else { continue }

            // Skip tiny movements (noise)
            if abs(dx) < velocityDeadzone { continue }

            let sign = dx > 0 ? 1 : -1
            if lastSign != 0 && sign != lastSign {
                reversals += 1
            }
            lastSign = sign
        }

        return reversals >= jiggleReversalThreshold
    }

    // MARK: - Region Building

    private static func buildRegions(
        events: [CursorEvent],
        flags: [Bool]
    ) -> [(start: Double, end: Double)] {
        var regions: [(start: Double, end: Double)] = []
        var regionStart: Double?
        var lastGestureTime: Double = 0

        for i in 0..<events.count {
            if flags[i] {
                if regionStart == nil {
                    regionStart = events[i].t
                }
                lastGestureTime = events[i].t
            } else if let start = regionStart {
                // Check if we've settled (no gesture for settleTimeout)
                if events[i].t - lastGestureTime >= settleTimeout {
                    regions.append((start: start, end: lastGestureTime))
                    regionStart = nil
                }
            }
        }

        // Close any open region
        if let start = regionStart {
            regions.append((start: start, end: lastGestureTime))
        }

        return regions
    }

    // MARK: - Merging

    private static func mergeRegions(
        _ regions: [(start: Double, end: Double)]
    ) -> [(start: Double, end: Double)] {
        guard !regions.isEmpty else { return [] }

        var merged = [regions[0]]
        for i in 1..<regions.count {
            let current = regions[i]
            let lastIndex = merged.count - 1

            if current.start - merged[lastIndex].end <= mergeGapThreshold {
                // Merge: extend the end of the last region
                merged[lastIndex].end = max(merged[lastIndex].end, current.end)
            } else {
                merged.append(current)
            }
        }

        return merged
    }
}
```

**Step 2: Run tests to verify they pass**

Run: `swift test --filter GestureZoomDetectorTests 2>&1 | tail -20`
Expected: All 5 tests PASS

**Step 3: Commit**

```bash
git add Sources/JackApp/ScreenRecording/GestureZoomDetector.swift
git commit -m "feat: add GestureZoomDetector with jiggle detection"
```

---

### Task 3: GestureZoomDetector — Circle Detection Tests

**Files:**
- Modify: `Tests/JackAppTests/GestureZoomDetectorTests.swift`

**Step 1: Add circle detection tests**

Append to `GestureZoomDetectorTests`:

```swift
    // MARK: - Circle Detection

    func testCircularMotionTriggersZoom() {
        // Cursor traces a circle (~360 degrees) over 0.8 seconds
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
        // Only ~90 degrees of arc — should NOT trigger circle detection
        var events: [CursorEvent] = []
        events.append(CursorEvent(t: 0.0, x: 500.0, y: 300.0))

        let centerX = 500.0
        let centerY = 300.0
        let radius = 80.0
        let numPoints = 10
        for i in 0..<numPoints {
            let t = 1.0 + Double(i) * 0.05
            let angle = (Double(i) / Double(numPoints)) * 0.5 * .pi  // only 90 degrees
            let x = centerX + radius * cos(angle)
            let y = centerY + radius * sin(angle)
            events.append(CursorEvent(t: t, x: x, y: y))
        }
        events.append(CursorEvent(t: 10.0, x: 500.0, y: 300.0))

        let result = GestureZoomDetector.detect(events: events)
        XCTAssertTrue(result.isEmpty, "Small arc should not trigger circle detection")
    }
```

**Step 2: Run tests to verify the new ones fail**

Run: `swift test --filter GestureZoomDetectorTests 2>&1 | tail -20`
Expected: `testCircularMotionTriggersZoom` FAILS, `testSmallArcDoesNotTrigger` passes (no false positive)

**Step 3: Commit**

```bash
git add Tests/JackAppTests/GestureZoomDetectorTests.swift
git commit -m "test: add circle detection tests for GestureZoomDetector"
```

---

### Task 4: GestureZoomDetector — Implement Circle Detection

**Files:**
- Modify: `Sources/JackApp/ScreenRecording/GestureZoomDetector.swift`

**Step 1: Add circle detector and wire it into detect()**

Add the `isCircle` method to `GestureZoomDetector`:

```swift
    // MARK: - Circle Detector

    /// Check if the cursor is making a circular motion at the given event index
    /// by measuring cumulative angular displacement around the window centroid.
    private static func isCircle(events: [CursorEvent], at index: Int) -> Bool {
        let currentTime = events[index].t
        let windowStart = currentTime - circleWindow

        // Find window start index
        var start = index
        while start > 0 && events[start - 1].t >= windowStart {
            start -= 1
        }

        let windowEvents = Array(events[start...index])
        guard windowEvents.count >= 6 else { return false }

        // Compute centroid of events in window
        let centroidX = windowEvents.reduce(0.0) { $0 + $1.x } / Double(windowEvents.count)
        let centroidY = windowEvents.reduce(0.0) { $0 + $1.y } / Double(windowEvents.count)

        // Accumulate angular displacement
        var totalAngle: Double = 0
        for j in 1..<windowEvents.count {
            let angle0 = atan2(windowEvents[j - 1].y - centroidY, windowEvents[j - 1].x - centroidX)
            let angle1 = atan2(windowEvents[j].y - centroidY, windowEvents[j].x - centroidX)
            var delta = angle1 - angle0

            // Normalize to [-pi, pi]
            while delta > .pi { delta -= 2.0 * .pi }
            while delta < -.pi { delta += 2.0 * .pi }

            totalAngle += abs(delta)
        }

        return totalAngle >= circleAngleThreshold
    }
```

Update the `detect` method's Step 1 loop to also check for circles:

```swift
        for i in 0..<events.count {
            if isJiggle(events: events, at: i) || isCircle(events: events, at: i) {
                gestureFlags[i] = true
            }
        }
```

**Step 2: Run tests to verify they all pass**

Run: `swift test --filter GestureZoomDetectorTests 2>&1 | tail -20`
Expected: All 7 tests PASS

**Step 3: Commit**

```bash
git add Sources/JackApp/ScreenRecording/GestureZoomDetector.swift
git commit -m "feat: add circle detection to GestureZoomDetector"
```

---

### Task 5: GestureZoomDetector — Merge and Edge Case Tests

**Files:**
- Modify: `Tests/JackAppTests/GestureZoomDetectorTests.swift`

**Step 1: Add merge and edge case tests**

Append to `GestureZoomDetectorTests`:

```swift
    // MARK: - Merging

    func testNearbyGesturesMergeIntoOneRegion() {
        // Two jiggles 1 second apart — should merge (gap < 2s after tail)
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
        // Two jiggles 15 seconds apart — should NOT merge
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

    // MARK: - Edge Cases

    func testTooFewEventsReturnsEmpty() {
        let events = [
            CursorEvent(t: 0.0, x: 100.0, y: 100.0),
            CursorEvent(t: 0.5, x: 200.0, y: 100.0),
        ]
        let result = GestureZoomDetector.detect(events: events)
        XCTAssertTrue(result.isEmpty)
    }

    func testZoomEndTimeDoesNotExceedLastEvent() {
        // Jiggle near the very end of recording (t=9.6..10.0, recording ends at t=10.0)
        // Tail should not extend infinitely — capped at recording end + tail
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
        // Tail extends past recording but that's fine — the editor/renderer
        // will clamp to video duration. Just verify it was created.
        XCTAssertGreaterThan(result.first?.endTime ?? 0, 10.0)
    }
```

**Step 2: Run all tests**

Run: `swift test --filter GestureZoomDetectorTests 2>&1 | tail -20`
Expected: All 11 tests PASS

**Step 3: Commit**

```bash
git add Tests/JackAppTests/GestureZoomDetectorTests.swift
git commit -m "test: add merge and edge case tests for GestureZoomDetector"
```

---

### Task 6: Wire GestureZoomDetector into RecordingSessionController

**Files:**
- Modify: `Sources/JackApp/ScreenRecording/RecordingSessionController.swift:309-361`
- Modify: `Sources/JackApp/ScreenRecording/EditorWindowController.swift:14-17`

**Step 1: Update EditorWindowController.show() to accept initial zoom keyframes**

In `EditorWindowController.swift`, change the `show` method signature and pass keyframes to the editor:

```swift
    func show(
        session: RecordingSession,
        initialZoomKeyframes: [ZoomKeyframe] = [],
        onDone: @escaping @MainActor () -> Void
    ) {
        if window != nil { return }

        let editor = VideoEditorController(session: session)
        editor.zoomKeyframes = initialZoomKeyframes
        self.editorController = editor
```

Everything else in the method stays the same.

**Step 2: Update RecordingSessionController.stopRecording() to run gesture detection**

In `RecordingSessionController.swift`, after cursor data is written to file (line 334) and before `state = .editing` (line 348), add gesture detection:

```swift
        // Detect gesture-triggered zoom regions from cursor data
        var detectedZoomKeyframes: [ZoomKeyframe] = []
        if let cursorSvc = cursorService {
            // cursorService is already stopped and data finalized above,
            // but we need the events. Re-read from the file we just wrote.
        }
```

Wait — looking at the code more carefully, `cursorService` is set to `nil` on line 334. The cursor data has been written to `session.cursorDataURL` by that point. We should read it back from disk, or better: capture the events before nil-ing the service.

Revised approach — restructure the cursor stop block in `stopRecording()`:

Replace lines 325-335 with:

```swift
        // Stop cursor tracking, write data, and detect gesture zooms
        var detectedZoomKeyframes: [ZoomKeyframe] = []
        if let cursorSvc = cursorService {
            let cursorData = await cursorSvc.stop()
            if let session = currentSession {
                do {
                    try await cursorSvc.writeToFile(url: session.cursorDataURL)
                } catch {
                    Self.logger.error("Failed to write cursor data: \(error)")
                }
            }

            // Detect gesture-triggered zoom regions
            detectedZoomKeyframes = GestureZoomDetector.detect(events: cursorData.events)
            if !detectedZoomKeyframes.isEmpty {
                Self.logger.info("Auto-detected \(detectedZoomKeyframes.count) gesture zoom region(s)")
            }

            cursorService = nil
        }
```

Then update the editor window call (around line 352) to pass the keyframes:

```swift
        if let session = currentSession {
            editorWindow.show(
                session: session,
                initialZoomKeyframes: detectedZoomKeyframes,
                onDone: { [weak self] in
                    self?.finishEditing()
                }
            )
        }
```

**Step 3: Run all tests to verify nothing broke**

Run: `swift test 2>&1 | tail -20`
Expected: All tests PASS

**Step 4: Build the project**

Run: `swift build 2>&1 | tail -20`
Expected: Build succeeds

**Step 5: Commit**

```bash
git add Sources/JackApp/ScreenRecording/RecordingSessionController.swift Sources/JackApp/ScreenRecording/EditorWindowController.swift
git commit -m "feat: wire GestureZoomDetector into recording stop flow and editor"
```

---

### Task 7: Final Verification and Cleanup

**Step 1: Run the full test suite**

Run: `swift test 2>&1 | tail -30`
Expected: All tests PASS

**Step 2: Build the full app**

Run: `swift build 2>&1 | tail -20`
Expected: Build succeeds with no warnings related to GestureZoomDetector

**Step 3: Review all changes**

Run: `git diff main --stat`
Verify only expected files are changed:
- `Sources/JackApp/ScreenRecording/GestureZoomDetector.swift` (new)
- `Sources/JackApp/ScreenRecording/RecordingSessionController.swift` (modified)
- `Sources/JackApp/ScreenRecording/EditorWindowController.swift` (modified)
- `Tests/JackAppTests/GestureZoomDetectorTests.swift` (new)
- `docs/plans/` (design doc + plan)
