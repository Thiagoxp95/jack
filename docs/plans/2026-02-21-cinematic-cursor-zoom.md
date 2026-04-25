# Cinematic Cursor Zoom Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add cinematic camera-like 2x zoom on cursor with click-drag creation on the zoom timeline, asymmetric easing curves, and soft edge clamping.

**Architecture:** Extend the existing `ZoomKeyframe` + `MetalVideoRenderer.interpolateZoom()` system. Replace the 0.3s symmetric smoothstep easing with 0.6s asymmetric ease-out-cubic (zoom-in) / ease-in-cubic (zoom-out). Add soft edge clamping to the Metal shader's zoom center calculation. Add click-drag gesture to the zoom timeline in `VideoEditorView`.

**Tech Stack:** Swift, SwiftUI, Metal Shading Language, AVFoundation

---

### Task 1: Cinematic Easing in MetalVideoRenderer

Replace the symmetric 0.3s smoothstep easing with asymmetric 0.6s cinematic curves.

**Files:**
- Modify: `Sources/JackApp/ScreenRecording/MetalVideoRenderer.swift:225-281`
- Test: `Tests/JackAppTests/JackAppTests.swift`

**Step 1: Write failing tests for the new easing behavior**

Add a new test class to `Tests/JackAppTests/JackAppTests.swift`:

```swift
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
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter ZoomInterpolationTests 2>&1 | tail -20`
Expected: Tests fail (current smoothstep easing produces different values)

**Step 3: Implement the cinematic easing**

Replace the easing functions in `MetalVideoRenderer.swift` (lines 225-281):

```swift
    /// Default cinematic ramp duration in seconds.
    static let cinematicRampDuration: Double = 0.6

    /// Interpolates zoom level at a given time using cinematic asymmetric easing.
    /// Zoom-in uses ease-out cubic (fast start, gentle landing).
    /// Zoom-out uses ease-in cubic (gentle start, accelerating exit).
    ///
    /// - Parameters:
    ///   - time: Current time in seconds.
    ///   - keyframes: Array of zoom keyframes.
    ///   - rampDuration: Duration of the ease-in/ease-out ramp in seconds.
    /// - Returns: Interpolated zoom level at the given time.
    static func interpolateZoom(
        at time: Double,
        keyframes: [ZoomKeyframe],
        rampDuration: Double
    ) -> Double {
        guard let keyframe = keyframes.first(where: {
            time >= $0.startTime && time <= $0.endTime
        }) else {
            return 1.0
        }

        let duration = keyframe.endTime - keyframe.startTime
        guard duration > 0 else { return keyframe.zoomLevel }

        let ramp = min(rampDuration, duration / 2.0)
        let elapsed = time - keyframe.startTime
        let remaining = keyframe.endTime - time

        if elapsed < ramp {
            // Zoom-in: ease-out cubic — fast approach, gentle landing
            let t = elapsed / ramp
            let eased = cinematicEaseOut(t)
            return 1.0 + (keyframe.zoomLevel - 1.0) * eased
        } else if remaining < ramp {
            // Zoom-out: ease-in cubic — gentle start, accelerating exit
            let t = remaining / ramp
            let eased = cinematicEaseIn(t)
            return 1.0 + (keyframe.zoomLevel - 1.0) * eased
        } else {
            return keyframe.zoomLevel
        }
    }

    /// Ease-out cubic: 1 - (1 - t)^3
    /// Fast start, gentle deceleration. Used for zoom-in transitions.
    static func cinematicEaseOut(_ t: Double) -> Double {
        let clamped = max(0.0, min(1.0, t))
        return 1.0 - pow(1.0 - clamped, 3)
    }

    /// Ease-in cubic: t^3
    /// Gentle start, accelerating. Used for zoom-out (remaining time maps to this).
    static func cinematicEaseIn(_ t: Double) -> Double {
        let clamped = max(0.0, min(1.0, t))
        return clamped * clamped * clamped
    }
```

Remove the old `cubicBezierEase` private function (lines 278-281).

**Step 4: Run tests to verify they pass**

Run: `swift test --filter ZoomInterpolationTests 2>&1 | tail -20`
Expected: All 7 tests PASS

**Step 5: Commit**

```bash
git add Sources/JackApp/ScreenRecording/MetalVideoRenderer.swift Tests/JackAppTests/JackAppTests.swift
git commit -m "feat(editor): replace smoothstep with cinematic asymmetric easing for zoom"
```

---

### Task 2: Update ExportService ramp duration

**Files:**
- Modify: `Sources/JackApp/ScreenRecording/ExportService.swift:239-243`

**Step 1: Update the ramp duration constant**

Change line 242 from `rampDuration: 0.3` to use the new constant:

```swift
            let zoomLevel = MetalVideoRenderer.interpolateZoom(
                at: timeSeconds,
                keyframes: editorState.zoomKeyframes,
                rampDuration: MetalVideoRenderer.cinematicRampDuration
            )
```

**Step 2: Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds

**Step 3: Commit**

```bash
git add Sources/JackApp/ScreenRecording/ExportService.swift
git commit -m "feat(export): use cinematic ramp duration constant"
```

---

### Task 3: Soft Edge Clamping in Metal Shader

Add soft clamping to the zoom center so the viewport decelerates near screen edges instead of revealing black space.

**Files:**
- Modify: `Sources/JackApp/Resources/ZoomCursorCompositor.metal:88-94`

**Step 1: Add the soft clamp function and update zoom transform**

Add a helper function before the kernel, then update the zoom transform section:

```metal
// MARK: - Soft Clamp Helper

/// Soft-clamps a value within [low, high] with exponential deceleration in the margin zone.
/// margin: fraction of the viewport half-size used as the deceleration zone (0.05 = 5%).
static float softClamp(float value, float low, float high, float margin) {
    float range = high - low;
    float softLow = low + range * margin;
    float softHigh = high - range * margin;

    if (value < softLow) {
        // Exponential ease into the lower bound
        float t = (softLow - value) / (softLow - low);
        t = clamp(t, 0.0f, 1.0f);
        return softLow - (softLow - low) * (1.0 - exp(-3.0 * t)) / (1.0 - exp(-3.0));
    } else if (value > softHigh) {
        // Exponential ease into the upper bound
        float t = (value - softHigh) / (high - softHigh);
        t = clamp(t, 0.0f, 1.0f);
        return softHigh + (high - softHigh) * (1.0 - exp(-3.0 * t)) / (1.0 - exp(-3.0));
    }
    return value;
}
```

Then update the zoom transform section (lines 88-94) to apply soft clamping to the zoom center:

```metal
    float2 outUV = (float2(gid) + 0.5) / uniforms.outputSize;

    // ---- Phase 1: Zoom Transform ----
    float invZoom = 1.0 / max(uniforms.zoomLevel, 1e-4);
    float halfView = invZoom * 0.5;

    // Soft-clamp zoom center so viewport doesn't reveal outside the source frame.
    // The safe range for the center is [halfView, 1-halfView].
    float2 clampedCenter = float2(
        softClamp(uniforms.zoomCenter.x, halfView, 1.0 - halfView, 0.05),
        softClamp(uniforms.zoomCenter.y, halfView, 1.0 - halfView, 0.05)
    );

    float2 sourceUV = clampedCenter + (outUV - clampedCenter) * invZoom;
    sourceUV = clamp(sourceUV, float2(0.0), float2(1.0));
```

**Step 2: Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds (Metal shaders are compiled at runtime from source, but SPM will still catch syntax errors in resources)

**Step 3: Commit**

```bash
git add Sources/JackApp/Resources/ZoomCursorCompositor.metal
git commit -m "feat(shader): add soft edge clamping for cinematic zoom viewport"
```

---

### Task 4: updateZoomLevel method on VideoEditorController

**Files:**
- Modify: `Sources/JackApp/ScreenRecording/VideoEditorController.swift:203-207`
- Test: `Tests/JackAppTests/JackAppTests.swift`

**Step 1: Write failing test**

Add to `Tests/JackAppTests/JackAppTests.swift`:

```swift
@MainActor
final class ZoomEditorTests: XCTestCase {
    func testUpdateZoomLevelChangesExistingKeyframe() {
        let session = RecordingSession(
            sessionDirectory: URL(fileURLWithPath: "/tmp/test-\(UUID())"),
            captureSourceType: .screen,
            fps: .thirty
        )
        let editor = VideoEditorController(session: session)
        editor.addZoomRegion(start: 1.0, end: 3.0, level: 2.0)
        let id = editor.zoomKeyframes[0].id

        editor.updateZoomLevel(id: id, level: 3.0)

        XCTAssertEqual(editor.zoomKeyframes.count, 1)
        XCTAssertEqual(editor.zoomKeyframes[0].zoomLevel, 3.0, accuracy: 0.001)
        XCTAssertEqual(editor.zoomKeyframes[0].startTime, 1.0, accuracy: 0.001)
        XCTAssertEqual(editor.zoomKeyframes[0].endTime, 3.0, accuracy: 0.001)
    }

    func testUpdateZoomLevelClampsRange() {
        let session = RecordingSession(
            sessionDirectory: URL(fileURLWithPath: "/tmp/test-\(UUID())"),
            captureSourceType: .screen,
            fps: .thirty
        )
        let editor = VideoEditorController(session: session)
        editor.addZoomRegion(start: 0.0, end: 2.0, level: 2.0)
        let id = editor.zoomKeyframes[0].id

        editor.updateZoomLevel(id: id, level: 10.0)
        XCTAssertEqual(editor.zoomKeyframes[0].zoomLevel, 4.0, accuracy: 0.001)

        editor.updateZoomLevel(id: id, level: 0.5)
        XCTAssertEqual(editor.zoomKeyframes[0].zoomLevel, 1.2, accuracy: 0.001)
    }

    func testUpdateZoomLevelSupportsUndo() {
        let session = RecordingSession(
            sessionDirectory: URL(fileURLWithPath: "/tmp/test-\(UUID())"),
            captureSourceType: .screen,
            fps: .thirty
        )
        let editor = VideoEditorController(session: session)
        editor.addZoomRegion(start: 0.0, end: 2.0, level: 2.0)
        let id = editor.zoomKeyframes[0].id

        editor.updateZoomLevel(id: id, level: 3.0)
        XCTAssertEqual(editor.zoomKeyframes[0].zoomLevel, 3.0, accuracy: 0.001)

        editor.undo()
        XCTAssertEqual(editor.zoomKeyframes[0].zoomLevel, 2.0, accuracy: 0.001)
    }

    func testAddZoomRegionPreventsOverlap() {
        let session = RecordingSession(
            sessionDirectory: URL(fileURLWithPath: "/tmp/test-\(UUID())"),
            captureSourceType: .screen,
            fps: .thirty
        )
        let editor = VideoEditorController(session: session)
        editor.addZoomRegion(start: 2.0, end: 5.0, level: 2.0)

        // Overlapping region should not be added
        editor.addZoomRegion(start: 3.0, end: 6.0, level: 2.0)
        XCTAssertEqual(editor.zoomKeyframes.count, 1)

        // Non-overlapping region should be added
        editor.addZoomRegion(start: 6.0, end: 8.0, level: 2.0)
        XCTAssertEqual(editor.zoomKeyframes.count, 2)
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter ZoomEditorTests 2>&1 | tail -20`
Expected: Fails — `updateZoomLevel` doesn't exist, `addZoomRegion` doesn't check overlap

**Step 3: Implement updateZoomLevel and overlap prevention**

Add to `VideoEditorController.swift` after `removeZoomRegion` (after line 211):

```swift
    func updateZoomLevel(id: UUID, level: Double) {
        pushSnapshot()
        let clamped = max(1.2, min(4.0, level))
        guard let index = zoomKeyframes.firstIndex(where: { $0.id == id }) else { return }
        let existing = zoomKeyframes[index]
        zoomKeyframes[index] = ZoomKeyframe(
            id: existing.id,
            startTime: existing.startTime,
            endTime: existing.endTime,
            zoomLevel: clamped
        )
    }
```

Update `addZoomRegion` to prevent overlaps:

```swift
    func addZoomRegion(start: Double, end: Double, level: Double) {
        // Prevent overlapping zoom regions
        let overlaps = zoomKeyframes.contains { kf in
            start < kf.endTime && end > kf.startTime
        }
        guard !overlaps else { return }

        pushSnapshot()
        let keyframe = ZoomKeyframe(startTime: start, endTime: end, zoomLevel: level)
        zoomKeyframes.append(keyframe)
    }
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter ZoomEditorTests 2>&1 | tail -20`
Expected: All 4 tests PASS

**Step 5: Commit**

```bash
git add Sources/JackApp/ScreenRecording/VideoEditorController.swift Tests/JackAppTests/JackAppTests.swift
git commit -m "feat(editor): add updateZoomLevel with clamping and overlap prevention"
```

---

### Task 5: Click-drag zoom creation on the zoom timeline

Add click-drag gesture to the zoom timeline in `VideoEditorView` so users can draw zoom blocks by dragging.

**Files:**
- Modify: `Sources/JackApp/ScreenRecording/VideoEditorView.swift:5-9,274-308`

**Step 1: Add drag state properties**

Add state variables to `VideoEditorView` (after line 9):

```swift
    @State private var zoomDragStart: CGFloat?
    @State private var zoomDragEnd: CGFloat?
```

**Step 2: Update the zoom timeline with click-drag creation gesture**

Replace the `zoomTimeline` computed property (lines 274-308):

```swift
    @ViewBuilder
    private var zoomTimeline: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height

            ZStack(alignment: .leading) {
                // Track background
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.2))

                // Zoom regions (blue)
                ForEach(editor.zoomKeyframes) { kf in
                    let startX = timeToX(kf.startTime, width: width)
                    let endX = timeToX(kf.endTime, width: width)
                    ZStack {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.blue.opacity(0.4))
                        Text(String(format: "%.1fx", kf.zoomLevel))
                            .font(.system(size: 9))
                            .foregroundColor(.white)
                    }
                    .frame(width: max(0, endX - startX), height: height - 4)
                    .offset(x: startX)
                    .onTapGesture(count: 2) {
                        cycleZoomLevel(id: kf.id, current: kf.zoomLevel)
                    }
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            editor.removeZoomRegion(id: kf.id)
                        }
                    }
                }

                // Drag preview (semi-transparent while drawing)
                if let dragStart = zoomDragStart, let dragEnd = zoomDragEnd {
                    let minX = min(dragStart, dragEnd)
                    let maxX = max(dragStart, dragEnd)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.blue.opacity(0.25))
                        .stroke(Color.blue.opacity(0.6), lineWidth: 1)
                        .frame(width: max(0, maxX - minX), height: height - 4)
                        .offset(x: minX)
                }

                // Playhead
                Rectangle()
                    .fill(Color.white.opacity(0.6))
                    .frame(width: 1, height: height)
                    .offset(x: timeToX(editor.currentTime, width: width))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        guard width > 0 else { return }
                        if zoomDragStart == nil {
                            zoomDragStart = max(0, min(width, value.startLocation.x))
                        }
                        zoomDragEnd = max(0, min(width, value.location.x))
                    }
                    .onEnded { value in
                        guard width > 0,
                              let dragStart = zoomDragStart,
                              let dragEnd = zoomDragEnd else {
                            zoomDragStart = nil
                            zoomDragEnd = nil
                            return
                        }

                        let minX = min(dragStart, dragEnd)
                        let maxX = max(dragStart, dragEnd)
                        let startTime = (minX / width) * editor.duration
                        let endTime = (maxX / width) * editor.duration

                        // Only create if the region is at least 0.2 seconds
                        if endTime - startTime >= 0.2 {
                            editor.addZoomRegion(start: startTime, end: endTime, level: 2.0)
                        }

                        zoomDragStart = nil
                        zoomDragEnd = nil
                    }
            )
            .onScrollWheel { delta, location in
                guard width > 0 else { return }
                let time = (location.x / width) * editor.duration
                if let kf = editor.zoomKeyframes.first(where: {
                    time >= $0.startTime && time <= $0.endTime
                }) {
                    let newLevel = kf.zoomLevel + delta * 0.1
                    editor.updateZoomLevel(id: kf.id, level: newLevel)
                }
            }
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Zoom Helpers

    private func cycleZoomLevel(id: UUID, current: Double) {
        let presets: [Double] = [1.5, 2.0, 2.5, 3.0]
        let nextIndex = presets.firstIndex(where: { $0 > current + 0.05 }) ?? 0
        editor.updateZoomLevel(id: id, level: presets[nextIndex])
    }
```

**Step 3: Add the scroll wheel modifier**

Since SwiftUI doesn't have a native scroll wheel modifier, add a helper at the bottom of `VideoEditorView.swift` before the closing brace of the file:

```swift
// MARK: - Scroll Wheel Modifier

private struct ScrollWheelModifier: ViewModifier {
    let handler: (Double, CGPoint) -> Void

    func body(content: Content) -> some View {
        content.overlay(ScrollWheelView(handler: handler))
    }
}

private struct ScrollWheelView: NSViewRepresentable {
    let handler: (Double, CGPoint) -> Void

    func makeNSView(context: Context) -> ScrollWheelNSView {
        let view = ScrollWheelNSView()
        view.handler = handler
        return view
    }

    func updateNSView(_ nsView: ScrollWheelNSView, context: Context) {
        nsView.handler = handler
    }
}

private class ScrollWheelNSView: NSView {
    var handler: ((Double, CGPoint) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        handler?(Double(event.deltaY), CGPoint(x: location.x, y: location.y))
    }
}

private extension View {
    func onScrollWheel(_ handler: @escaping (Double, CGPoint) -> Void) -> some View {
        modifier(ScrollWheelModifier(handler: handler))
    }
}
```

**Step 4: Verify build**

Run: `swift build 2>&1 | tail -10`
Expected: Build succeeds

**Step 5: Run all tests**

Run: `swift test 2>&1 | tail -10`
Expected: All tests pass

**Step 6: Commit**

```bash
git add Sources/JackApp/ScreenRecording/VideoEditorView.swift
git commit -m "feat(editor): add click-drag zoom creation, double-click cycle, and scroll-wheel adjustment"
```

---

### Task 6: Soft Edge Clamping in Export Service

The Metal shader now does soft clamping, but the export service calculates `zoomCenter` on the CPU before passing it to the shader. We need to apply the same soft clamping logic to the CPU-side zoom center calculation for consistency between the shader's hard clamp and the CPU's centering logic.

**Files:**
- Modify: `Sources/JackApp/ScreenRecording/ExportService.swift:277-287`

**Step 1: Update zoom center calculation**

Replace the zoom center calculation (lines 277-287):

```swift
            // Zoom center follows cursor when zoomed, with soft edge clamping
            let zoomCenter: CGPoint
            if zoomLevel > 1.0, let pos = cursorPosition {
                let rawCenterX = pos.x / naturalSize.width
                let rawCenterY = pos.y / naturalSize.height
                let invZoom = 1.0 / zoomLevel
                let halfView = invZoom * 0.5
                zoomCenter = CGPoint(
                    x: max(halfView, min(1.0 - halfView, rawCenterX)),
                    y: max(halfView, min(1.0 - halfView, rawCenterY))
                )
            } else {
                zoomCenter = CGPoint(x: 0.5, y: 0.5)
            }
```

Note: The hard clamp here is sufficient because the shader applies the soft exponential deceleration on top. This just ensures the center stays in valid range.

**Step 2: Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds

**Step 3: Commit**

```bash
git add Sources/JackApp/ScreenRecording/ExportService.swift
git commit -m "feat(export): clamp zoom center to valid viewport range"
```

---

### Task 7: Integration Testing and Final Verification

**Step 1: Run all tests**

Run: `swift test 2>&1 | tail -20`
Expected: All tests pass

**Step 2: Build the full app**

Run: `swift build 2>&1 | tail -10`
Expected: Clean build with no warnings

**Step 3: Final commit (if any fixups needed)**

Only if adjustments were made during verification.
