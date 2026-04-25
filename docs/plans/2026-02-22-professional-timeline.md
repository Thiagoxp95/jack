# Professional Timeline Editor Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Transform the video editor timeline into a professional editing tool with pinch-to-zoom, blade/ripple-delete, markers, audio waveforms, and wizard-aligned design language.

**Architecture:** We replace the `CutRegion`-based editing model with a segment-based model where the timeline is an ordered list of `TimelineSegment` objects. Splits create new segment boundaries; deletes disable segments and ripple the timeline. A `TimelineZoomState` manages the zoom viewport. Waveform data is pre-computed at load time and rendered via `Canvas`.

**Tech Stack:** SwiftUI, AVFoundation (audio loading), `@Observable`, `Canvas` (waveforms), `MagnifyGesture` (pinch-to-zoom)

**Design doc:** `docs/plans/2026-02-22-professional-timeline-design.md`

---

## Task 1: Add New Types to RecordingTypes.swift

**Files:**
- Modify: `Sources/JackApp/ScreenRecording/RecordingTypes.swift`

**Step 1: Add MarkerColor enum after CursorStyle (after line ~249)**

```swift
enum MarkerColor: String, CaseIterable, Identifiable {
    case blue, red, green, yellow, orange, purple

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .blue: return .blue
        case .red: return .red
        case .green: return .green
        case .yellow: return .yellow
        case .orange: return .orange
        case .purple: return .purple
        }
    }
}
```

Note: Add `import SwiftUI` at the top of RecordingTypes.swift (it currently only imports Foundation).

**Step 2: Add TimelineMarker struct after MarkerColor**

```swift
struct TimelineMarker: Identifiable, Equatable {
    let id: UUID
    var time: TimeInterval
    var label: String
    var color: MarkerColor

    init(id: UUID = UUID(), time: TimeInterval, label: String = "", color: MarkerColor = .blue) {
        self.id = id
        self.time = time
        self.label = label
        self.color = color
    }
}
```

**Step 3: Add TimelineSegment struct after TimelineMarker**

```swift
struct TimelineSegment: Identifiable, Equatable {
    let id: UUID
    let sourceStart: TimeInterval
    let sourceEnd: TimeInterval
    var enabled: Bool

    init(id: UUID = UUID(), sourceStart: TimeInterval, sourceEnd: TimeInterval, enabled: Bool = true) {
        self.id = id
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.enabled = enabled
    }

    var sourceDuration: TimeInterval {
        sourceEnd - sourceStart
    }
}
```

**Step 4: Build to verify**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds

**Step 5: Commit**

```
feat(types): add TimelineSegment, TimelineMarker, MarkerColor types
```

---

## Task 2: Add EditorColors Design Tokens

**Files:**
- Create: `Sources/JackApp/ScreenRecording/EditorColors.swift`

**Step 1: Create the color constants file**

```swift
import SwiftUI

enum EditorColors {
    static let background = Color(red: 0.11, green: 0.11, blue: 0.118)
    static let card = Color(red: 0.173, green: 0.173, blue: 0.18)
    static let secondary = Color(red: 0.557, green: 0.557, blue: 0.576)
    static let divider = Color.primary.opacity(0.08)
    static let subtleFill = Color.primary.opacity(0.05)
    static let subtleStroke = Color.primary.opacity(0.15)

    static let accentGradient = LinearGradient(
        colors: [Color(red: 0.369, green: 0.361, blue: 0.902), Color(red: 0, green: 0.478, blue: 1)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // Timeline-specific
    static let trackBackground = Color(red: 0.173, green: 0.173, blue: 0.18)
    static let playhead = Color.white
    static let cutRegion = Color.red.opacity(0.25)
    static let cutRegionBorder = Color.red.opacity(0.6)
    static let zoomBlock = LinearGradient(
        colors: [Color(red: 0.369, green: 0.361, blue: 0.902).opacity(0.35), Color(red: 0, green: 0.478, blue: 1).opacity(0.35)],
        startPoint: .leading,
        endPoint: .trailing
    )
    static let disabledSegment = Color.gray.opacity(0.15)
    static let selectedSegmentBorder = LinearGradient(
        colors: [Color(red: 0.369, green: 0.361, blue: 0.902), Color(red: 0, green: 0.478, blue: 1)],
        startPoint: .leading,
        endPoint: .trailing
    )
    static let bladeIndicator = Color.red
    static let micWaveform = Color(red: 0, green: 0.478, blue: 1)
    static let systemWaveform = Color.green
}
```

**Step 2: Build**

Run: `swift build 2>&1 | tail -5`

**Step 3: Commit**

```
feat(editor): add EditorColors design token system
```

---

## Task 3: Update VideoEditorController — Segments, Markers, Zoom State, Waveforms

**Files:**
- Modify: `Sources/JackApp/ScreenRecording/VideoEditorController.swift`

This is the core controller rewrite. We add segment-based editing, markers, timeline zoom, and waveform loading.

**Step 1: Update EditorSnapshot (lines 8-26) to include segments and markers**

Replace the EditorSnapshot struct:

```swift
struct EditorSnapshot {
    let segments: [TimelineSegment]
    let zoomKeyframes: [ZoomKeyframe]
    let markers: [TimelineMarker]
    let cursorScale: Double
    let cursorStyle: CursorStyle
    let clickHighlightEnabled: Bool
    let clickHighlightOpacity: Double
    let cursorSmoothingEnabled: Bool
    let micVolume: Float
    let systemVolume: Float
    let micMuted: Bool
    let systemMuted: Bool
    let webcamEnabled: Bool
    let webcamScale: Double
    let webcamPositionX: Double
    let webcamPositionY: Double
}
```

Note: `cuts`, `inPoint`, `outPoint` are removed. `segments` and `markers` are added.

**Step 2: Replace cuts with segments in the controller state (around lines 38-77)**

Replace:
```swift
var cuts: [CutRegion] = []
```
With:
```swift
var segments: [TimelineSegment] = []
var markers: [TimelineMarker] = []
var selectedSegmentID: UUID?
var isBladeMode: Bool = false

// Timeline zoom
var timelineScale: CGFloat = 1.0
var timelineScrollOffset: CGFloat = 0

// Waveform data (pre-computed at load)
private(set) var micWaveform: [Float] = []
private(set) var systemWaveform: [Float] = []
private(set) var waveformSamplesPerSecond: Double = 200
```

Remove `inPoint` and `outPoint` (lines 76-77).

**Step 3: Add segment helper computed properties after the state section**

```swift
// MARK: - Segment Helpers

/// Total edited duration (sum of enabled segments)
var editedDuration: TimeInterval {
    segments.filter(\.enabled).reduce(0) { $0 + $1.sourceDuration }
}

/// Convert edited-timeline time to source time
func sourceTime(forEditedTime editedTime: TimeInterval) -> TimeInterval {
    var accumulated: TimeInterval = 0
    for segment in segments where segment.enabled {
        let segDur = segment.sourceDuration
        if accumulated + segDur > editedTime {
            return segment.sourceStart + (editedTime - accumulated)
        }
        accumulated += segDur
    }
    return segments.last?.sourceEnd ?? 0
}

/// Convert source time to edited-timeline time
func editedTime(forSourceTime sourceTime: TimeInterval) -> TimeInterval? {
    var accumulated: TimeInterval = 0
    for segment in segments where segment.enabled {
        if sourceTime >= segment.sourceStart && sourceTime < segment.sourceEnd {
            return accumulated + (sourceTime - segment.sourceStart)
        }
        accumulated += segment.sourceDuration
    }
    return nil
}

/// The segment containing a given source time
func segment(atSourceTime time: TimeInterval) -> TimelineSegment? {
    segments.first { $0.sourceStart <= time && time < $0.sourceEnd }
}
```

**Step 4: Update `load()` — initialize segments and load waveforms**

At the end of the existing `load()` function (after cursor data loading, around line 166), add:

```swift
// Initialize segments (one segment covering full duration)
if segments.isEmpty {
    segments = [TimelineSegment(sourceStart: 0, sourceEnd: duration)]
}

// Load audio waveforms
micWaveform = await loadWaveform(url: session.micAudioURL)
systemWaveform = await loadWaveform(url: session.systemAudioURL)
```

**Step 5: Add waveform loading helper**

```swift
// MARK: - Waveform Loading

private func loadWaveform(url: URL) async -> [Float] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    do {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return [] }
        try file.read(into: buffer)

        guard let floatData = buffer.floatChannelData?[0] else { return [] }
        let sampleRate = format.sampleRate
        let samplesPerBucket = Int(sampleRate / waveformSamplesPerSecond)
        guard samplesPerBucket > 0 else { return [] }

        let bucketCount = Int(frameCount) / samplesPerBucket
        var waveform = [Float](repeating: 0, count: bucketCount)
        for i in 0..<bucketCount {
            var peak: Float = 0
            let start = i * samplesPerBucket
            let end = min(start + samplesPerBucket, Int(frameCount))
            for j in start..<end {
                let val = abs(floatData[j])
                if val > peak { peak = val }
            }
            waveform[i] = peak
        }
        return waveform
    } catch {
        Self.logger.error("Failed to load waveform: \(error)")
        return []
    }
}
```

**Step 6: Replace setInPoint/setOutPoint/deleteSelection with segment operations**

Remove `setInPoint()`, `setOutPoint()`, `deleteSelection()` (lines 209-225).

Add:

```swift
// MARK: - Blade / Split

func splitAtPlayhead() {
    let srcTime = sourceTime(forEditedTime: currentTime)
    guard let idx = segments.firstIndex(where: { $0.sourceStart < srcTime && srcTime < $0.sourceEnd }) else { return }
    pushSnapshot()
    let seg = segments[idx]
    let left = TimelineSegment(sourceStart: seg.sourceStart, sourceEnd: srcTime, enabled: seg.enabled)
    let right = TimelineSegment(sourceStart: srcTime, sourceEnd: seg.sourceEnd, enabled: seg.enabled)
    segments.replaceSubrange(idx...idx, with: [left, right])
}

func splitAtSourceTime(_ srcTime: TimeInterval) {
    guard let idx = segments.firstIndex(where: { $0.sourceStart < srcTime && srcTime < $0.sourceEnd }) else { return }
    pushSnapshot()
    let seg = segments[idx]
    let left = TimelineSegment(sourceStart: seg.sourceStart, sourceEnd: srcTime, enabled: seg.enabled)
    let right = TimelineSegment(sourceStart: srcTime, sourceEnd: seg.sourceEnd, enabled: seg.enabled)
    segments.replaceSubrange(idx...idx, with: [left, right])
}

func deleteSelectedSegment() {
    guard let selID = selectedSegmentID,
          let idx = segments.firstIndex(where: { $0.id == selID }) else { return }
    pushSnapshot()
    segments[idx] = TimelineSegment(
        id: segments[idx].id,
        sourceStart: segments[idx].sourceStart,
        sourceEnd: segments[idx].sourceEnd,
        enabled: false
    )
    selectedSegmentID = nil
    // Clamp playhead to edited duration
    let edited = editedDuration
    if currentTime > edited { currentTime = edited }
}

func toggleBladeMode() {
    isBladeMode.toggle()
    selectedSegmentID = nil
}

func selectSegment(_ id: UUID?) {
    selectedSegmentID = id
}
```

**Step 7: Add marker management methods**

```swift
// MARK: - Markers

func addMarker() {
    pushSnapshot()
    let srcTime = sourceTime(forEditedTime: currentTime)
    let index = markers.filter({ $0.time <= srcTime }).count + 1
    markers.append(TimelineMarker(time: srcTime, label: "Marker \(index)"))
}

func removeMarker(id: UUID) {
    pushSnapshot()
    markers.removeAll { $0.id == id }
}

func updateMarkerLabel(id: UUID, label: String) {
    guard let idx = markers.firstIndex(where: { $0.id == id }) else { return }
    pushSnapshot()
    markers[idx].label = label
}

func updateMarkerColor(id: UUID, color: MarkerColor) {
    guard let idx = markers.firstIndex(where: { $0.id == id }) else { return }
    pushSnapshot()
    markers[idx].color = color
}

func jumpToMarker(id: UUID) {
    guard let marker = markers.first(where: { $0.id == id }) else { return }
    if let edited = editedTime(forSourceTime: marker.time) {
        pause()
        currentTime = edited
    }
}
```

**Step 8: Update makeSnapshot/applySnapshot to use segments and markers**

Replace `makeSnapshot()`:
```swift
private func makeSnapshot() -> EditorSnapshot {
    EditorSnapshot(
        segments: segments,
        zoomKeyframes: zoomKeyframes,
        markers: markers,
        cursorScale: cursorScale,
        cursorStyle: cursorStyle,
        clickHighlightEnabled: clickHighlightEnabled,
        clickHighlightOpacity: clickHighlightOpacity,
        cursorSmoothingEnabled: cursorSmoothingEnabled,
        micVolume: micVolume,
        systemVolume: systemVolume,
        micMuted: micMuted,
        systemMuted: systemMuted,
        webcamEnabled: webcamEnabled,
        webcamScale: webcamScale,
        webcamPositionX: webcamPositionX,
        webcamPositionY: webcamPositionY
    )
}
```

Replace `applySnapshot(_:)`:
```swift
private func applySnapshot(_ snapshot: EditorSnapshot) {
    segments = snapshot.segments
    zoomKeyframes = snapshot.zoomKeyframes
    markers = snapshot.markers
    cursorScale = snapshot.cursorScale
    cursorStyle = snapshot.cursorStyle
    clickHighlightEnabled = snapshot.clickHighlightEnabled
    clickHighlightOpacity = snapshot.clickHighlightOpacity
    cursorSmoothingEnabled = snapshot.cursorSmoothingEnabled
    micVolume = snapshot.micVolume
    systemVolume = snapshot.systemVolume
    micMuted = snapshot.micMuted
    systemMuted = snapshot.systemMuted
    webcamEnabled = snapshot.webcamEnabled
    webcamScale = snapshot.webcamScale
    webcamPositionX = snapshot.webcamPositionX
    webcamPositionY = snapshot.webcamPositionY
}
```

**Step 9: Build and fix any compile errors**

Run: `swift build 2>&1 | tail -20`
Fix any remaining references to `cuts`, `inPoint`, `outPoint` in the controller. The `init(session:, initialZoomKeyframes:)` should still work since we removed the `cuts` parameter.

**Step 10: Commit**

```
feat(editor): replace cuts with segments, add markers, zoom state, waveform loading
```

---

## Task 4: Update ExportService to Use Segments

**Files:**
- Modify: `Sources/JackApp/ScreenRecording/ExportService.swift`

**Step 1: Update EditorSnapshot usage in export**

The export service creates its own `EditorSnapshot` at line ~181. Update it to pass `segments` and `markers` instead of `cuts`. The snapshot construction in the export mirrors the controller's `makeSnapshot` — update it to match the new struct.

**Step 2: Replace `isInCutRegion` with segment-based skip logic**

Replace the `isInCutRegion` function (lines ~1223-1230) with:

```swift
private func isInDisabledSegment(time: Double, segments: [TimelineSegment]) -> Bool {
    for segment in segments {
        if time >= segment.sourceStart && time < segment.sourceEnd {
            return !segment.enabled
        }
    }
    return false
}
```

**Step 3: Update the frame processing loop**

At line ~485, replace:
```swift
if self.isInCutRegion(time: timeSeconds, cuts: editorState.cuts) {
```
With:
```swift
if self.isInDisabledSegment(time: timeSeconds, segments: editorState.segments) {
```

**Step 4: Build**

Run: `swift build 2>&1 | tail -10`

**Step 5: Commit**

```
feat(export): update export pipeline to use segment-based editing
```

---

## Task 5: Update VideoEditorView — Design Language + Timeline Zoom

**Files:**
- Modify: `Sources/JackApp/ScreenRecording/VideoEditorView.swift`

This is the largest UI task. We refactor the existing view to use EditorColors and add zoom support.

**Step 1: Replace hardcoded colors**

Throughout the view:
- `Color.gray.opacity(0.3)` track backgrounds → `EditorColors.trackBackground`
- `Color.red.opacity(0.4)` cut regions → `EditorColors.cutRegion`
- `Color.blue.opacity(0.4)` zoom blocks → replace with `EditorColors.zoomBlock`
- `Color.yellow` in/out markers → remove (replaced by blade tool)
- `Color.white` playhead → `EditorColors.playhead`
- Any `.black` backgrounds → `EditorColors.background`

**Step 2: Add timeline zoom state to the view**

Add to the VideoEditorView struct:
```swift
@State private var magnifyScale: CGFloat = 1.0
@State private var lastMagnifyScale: CGFloat = 1.0
```

**Step 3: Rewrite `timeToX` to account for zoom scale**

```swift
private func timeToX(_ time: TimeInterval, width: CGFloat) -> CGFloat {
    guard editor.duration > 0 else { return 0 }
    let editedDur = editor.editedDuration
    guard editedDur > 0 else { return 0 }
    return CGFloat(time / editedDur) * width * editor.timelineScale
}

private func xToTime(_ x: CGFloat, width: CGFloat) -> TimeInterval {
    let editedDur = editor.editedDuration
    guard editedDur > 0 else { return 0 }
    let scaledWidth = width * editor.timelineScale
    guard scaledWidth > 0 else { return 0 }
    return max(0, min(editedDur, Double(x / scaledWidth) * editedDur))
}
```

**Step 4: Wrap timelines in ScrollView with MagnifyGesture**

The video timeline and zoom timeline sections get wrapped in a `ScrollViewReader` + horizontal `ScrollView`. Content width scales with `editor.timelineScale`. Add `MagnifyGesture`:

```swift
.gesture(
    MagnifyGesture()
        .onChanged { value in
            let newScale = lastMagnifyScale * value.magnification
            editor.timelineScale = max(1.0, min(50.0, newScale))
        }
        .onEnded { _ in
            lastMagnifyScale = editor.timelineScale
        }
)
```

**Step 5: Add minimap view above timeline**

A thin 8px bar showing full recording with viewport rectangle:
```swift
@ViewBuilder
private func timelineMinimap(width: CGFloat) -> some View {
    if editor.timelineScale > 1.0 {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(EditorColors.trackBackground)
            // Viewport indicator
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.white.opacity(0.3))
                .frame(width: width / editor.timelineScale)
                .offset(x: editor.timelineScrollOffset / editor.timelineScale)
        }
        .frame(height: 8)
        .padding(.horizontal, 8)
    }
}
```

**Step 6: Build and iterate**

Run: `swift build 2>&1 | tail -20`
Fix compile errors incrementally.

**Step 7: Commit**

```
feat(editor): apply wizard design language and add timeline zoom
```

---

## Task 6: Update VideoEditorView — Blade Tool & Segment Rendering

**Files:**
- Modify: `Sources/JackApp/ScreenRecording/VideoEditorView.swift`

**Step 1: Replace video timeline rendering**

Instead of rendering cut regions as red overlays, render **segments**. Each enabled segment is a block. Disabled segments are dimmed/collapsed (not shown, since ripple delete). The selected segment gets an accent gradient border.

The video timeline iterates `editor.segments.filter(\.enabled)` and renders each as a block. Between segments, there's a thin split line (1px vertical white line at 0.3 opacity).

**Step 2: Add blade cursor**

When `editor.isBladeMode`, show a vertical red dashed line following the mouse:
```swift
if editor.isBladeMode {
    Rectangle()
        .fill(EditorColors.bladeIndicator)
        .frame(width: 1)
        .offset(x: hoverX)
        .allowsHitTesting(false)
}
```

**Step 3: Add blade click handler**

On tap in blade mode:
```swift
.onTapGesture { location in
    if editor.isBladeMode {
        let time = xToTime(location.x, width: geo.size.width)
        let srcTime = editor.sourceTime(forEditedTime: time)
        editor.splitAtSourceTime(srcTime)
    }
}
```

On tap NOT in blade mode (clicking a segment):
```swift
// Determine which segment was clicked
let time = xToTime(location.x, width: geo.size.width)
let srcTime = editor.sourceTime(forEditedTime: time)
if let seg = editor.segment(atSourceTime: srcTime), seg.enabled {
    editor.selectSegment(seg.id)
}
```

**Step 4: Add blade toggle + delete button to toolbar**

In the toolbar section, add a scissors button for blade mode and update the delete button:
```swift
Button { editor.toggleBladeMode() } label: {
    Image(systemName: "scissors")
        .foregroundStyle(editor.isBladeMode ? .white : EditorColors.secondary)
}
.help("Blade Tool (B)")

if editor.selectedSegmentID != nil {
    Button { editor.deleteSelectedSegment() } label: {
        Image(systemName: "trash")
            .foregroundStyle(.red)
    }
    .help("Delete Selected Segment")
}
```

**Step 5: Add keyboard shortcuts for blade + delete + markers**

Update `editorShortcuts` array:
```swift
EditorShortcut(key: "b", modifiers: []) { editor.toggleBladeMode() },
EditorShortcut(key: "m", modifiers: []) { editor.addMarker() },
EditorShortcut(key: .delete, modifiers: []) { editor.deleteSelectedSegment() },
```

**Step 6: Remove old in/out point UI**

Remove the in/out point buttons, yellow marker rendering, and "Delete Selection" button from the timeline panel. These are replaced by blade + segment selection.

**Step 7: Build and fix**

Run: `swift build 2>&1 | tail -20`

**Step 8: Commit**

```
feat(editor): add blade tool with segment rendering and ripple delete
```

---

## Task 7: Update VideoEditorView — Markers

**Files:**
- Modify: `Sources/JackApp/ScreenRecording/VideoEditorView.swift`

**Step 1: Add marker flags to video timeline**

Above the video track, render small triangular marker flags:
```swift
ForEach(editor.markers) { marker in
    if let editedT = editor.editedTime(forSourceTime: marker.time) {
        let x = timeToX(editedT, width: geo.size.width)
        MarkerFlag(color: marker.color.color)
            .offset(x: x - 4) // center the 8px wide flag
            .onTapGesture { editor.jumpToMarker(id: marker.id) }
            .contextMenu {
                ForEach(MarkerColor.allCases) { c in
                    Button { editor.updateMarkerColor(id: marker.id, color: c) } label: {
                        Label(c.rawValue.capitalized, systemImage: "circle.fill")
                    }
                }
                Divider()
                Button(role: .destructive) { editor.removeMarker(id: marker.id) } label: {
                    Label("Delete Marker", systemImage: "trash")
                }
            }
    }
}
```

**Step 2: Create MarkerFlag shape**

```swift
private struct MarkerFlag: View {
    let color: Color
    var body: some View {
        VStack(spacing: 0) {
            color
                .frame(width: 8, height: 8)
                .clipShape(Triangle())
            color
                .frame(width: 2, height: 6)
        }
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.closeSubpath()
        }
    }
}
```

**Step 3: Add snap-to-marker behavior**

When scrubbing, snap to markers within 5px:
```swift
private func snapToMarker(_ time: TimeInterval, width: CGFloat) -> TimeInterval {
    for marker in editor.markers {
        if let editedT = editor.editedTime(forSourceTime: marker.time) {
            let markerX = timeToX(editedT, width: width)
            let timeX = timeToX(time, width: width)
            if abs(markerX - timeX) < 5 {
                return editedT
            }
        }
    }
    return time
}
```

**Step 4: Build**

Run: `swift build 2>&1 | tail -10`

**Step 5: Commit**

```
feat(editor): add color-coded timeline markers with snap and context menu
```

---

## Task 8: Update VideoEditorView — Audio Waveforms

**Files:**
- Modify: `Sources/JackApp/ScreenRecording/VideoEditorView.swift`

**Step 1: Replace audio track placeholders with waveform Canvas**

In the audio tracks panel section (currently placeholder text), replace with:

```swift
@ViewBuilder
private func waveformView(samples: [Float], color: Color, muted: Bool, width: CGFloat, height: CGFloat) -> some View {
    Canvas { context, size in
        guard !samples.isEmpty else { return }
        let barCount = Int(size.width)
        let samplesPerBar = max(1, samples.count / max(1, barCount))

        var path = Path()
        let midY = size.height / 2

        for i in 0..<barCount {
            let sampleIdx = min(i * samplesPerBar, samples.count - 1)
            let endIdx = min(sampleIdx + samplesPerBar, samples.count)
            var peak: Float = 0
            for j in sampleIdx..<endIdx {
                if samples[j] > peak { peak = samples[j] }
            }
            let barHeight = CGFloat(peak) * size.height * 0.9
            let x = CGFloat(i)
            path.move(to: CGPoint(x: x, y: midY - barHeight / 2))
            path.addLine(to: CGPoint(x: x, y: midY + barHeight / 2))
        }

        context.stroke(path, with: .color(color.opacity(muted ? 0.2 : 0.6)), lineWidth: 1)
    }
    .frame(width: width, height: height)
}
```

**Step 2: Use waveform view in mic and system audio track areas**

Replace the placeholder text/rectangles in the audio section with:
```swift
waveformView(
    samples: editor.micWaveform,
    color: EditorColors.micWaveform,
    muted: editor.micMuted,
    width: geo.size.width,
    height: 32
)
```
And similarly for system audio.

**Step 3: Build**

Run: `swift build 2>&1 | tail -10`

**Step 4: Commit**

```
feat(editor): add audio waveform visualization with Canvas rendering
```

---

## Task 9: Fix All Remaining Compile Errors & Integration

**Files:**
- Modify: `Sources/JackApp/ScreenRecording/EditorWindowController.swift`
- Modify: `Sources/JackApp/ScreenRecording/ExportDialogView.swift`
- Modify: Any other files referencing `cuts`, `inPoint`, `outPoint`

**Step 1: Search for all remaining references to old API**

Search for `\.cuts`, `.inPoint`, `.outPoint`, `CutRegion` across the codebase. Update each:
- `editor.cuts` → `editor.segments`
- `EditorSnapshot` construction in export → use new fields
- Any `CutRegion` usage → use `TimelineSegment`
- `editor.inPoint` / `editor.outPoint` → remove
- `deleteSelection()` → `deleteSelectedSegment()`

**Step 2: Update EditorWindowController**

The `show(session:initialZoomKeyframes:)` method should still work. If it passes initial cuts, update accordingly.

**Step 3: Full build and test**

Run: `swift build 2>&1 | tail -20`
Fix all errors until build succeeds.

**Step 4: Commit**

```
fix(editor): resolve all compile errors from segment migration
```

---

## Task 10: Manual Testing & Polish

**Step 1: Build and run**

Run: `swift build && open .build/debug/JackApp.app` (or use the app's packaging script)

**Step 2: Test checklist**

- [ ] Timeline renders with wizard color scheme
- [ ] Pinch-to-zoom on timeline spreads/compresses the view
- [ ] Minimap appears when zoomed in
- [ ] Horizontal scroll works when zoomed
- [ ] Press `B` to enter blade mode — red line follows cursor
- [ ] Click in blade mode splits the timeline
- [ ] Click a segment to select it (accent border)
- [ ] Press Delete to remove selected segment (ripple)
- [ ] Undo/Redo works for all operations
- [ ] Press `M` to add marker at playhead
- [ ] Click marker to jump to it
- [ ] Right-click marker for color/delete menu
- [ ] Audio waveforms display in audio tracks
- [ ] Waveforms dim when track is muted
- [ ] Export works correctly (skips disabled segments)
- [ ] Zoom keyframes still work in zoom timeline

**Step 3: Commit any polish fixes**

```
fix(editor): polish timeline interactions and visual refinements
```
