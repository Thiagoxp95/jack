# Professional Timeline Editor Design

**Date**: 2026-02-22
**Status**: Approved

## Overview

Upgrade the video editor timeline from a basic scrub-and-cut interface to a professional editing experience with pinch-to-zoom, blade tool, ripple delete, markers, audio waveforms, and wizard-aligned visual design.

## Design Language Alignment

Bring the editor in line with the onboarding wizard aesthetic:

| Element | Current | New |
|---|---|---|
| Background | Pure black | `#1C1C1E` |
| Timeline track bg | Hardcoded dark gray | `#2C2C2E` (card color) |
| Playhead | White line | White line with glow |
| Cut regions | Red overlay | Soft red with 0.25 opacity, red border |
| Zoom blocks | Blue 0.3 opacity | Accent gradient (#5E5CE6 to #007AFF) 0.3 opacity |
| Buttons | System defaults | Accent gradient primary, subtle stroke secondary |
| Toolbar | Plain | `#2C2C2E` card bg with subtle top divider |
| Section headers | None | 10pt bold uppercase, 0.5 letter spacing |
| Corner radius | 4-6px | 10-12px |

## Feature 1: Timeline Zoom (Pinch-to-Zoom)

### State
- `timelineScale: CGFloat = 1.0` — pixels-per-second multiplier (1.0 = fit-to-width)
- `timelineScrollOffset: CGFloat = 0` — horizontal scroll position
- `visibleTimeRange: ClosedRange<TimeInterval>` — computed from scale + offset

### Gesture
- `MagnifyGesture` on the timeline area
- Zoom anchored to pinch center (time under fingers stays fixed)
- Min scale: 1.0 (fit entire duration), Max scale: ~50.0
- Smooth transitions via `withAnimation(.interactiveSpring)`

### Scroll
- Horizontal `ScrollView` wrapping timeline content
- Timeline width = `duration * pixelsPerSecond * timelineScale`
- Two-finger horizontal scroll to pan when zoomed in
- Auto-scroll to keep playhead visible during playback

### Minimap
- 8px tall bar above the timeline showing full recording
- Semi-transparent viewport rectangle for visible region
- `#2C2C2E` card background
- Click/drag minimap to navigate

### Impact
- `timeToX()` / `xToTime()` update to account for scale and offset

## Feature 2: Blade Tool & Ripple Delete

### Data Model Change

Replace `cuts: [CutRegion]` with segments:

```swift
struct TimelineSegment: Identifiable, Equatable {
    let id: UUID
    let sourceStart: TimeInterval  // position in original recording
    let sourceEnd: TimeInterval    // position in original recording
    var enabled: Bool              // false = deleted
}
```

Initially: one segment `[0, duration]`. Splitting at time T creates two segments.

### Ripple Delete
When a segment is disabled, the visible timeline collapses — subsequent segments shift left. `effectiveTime` computed by summing enabled segment durations only.

### UI Interaction
- Blade mode toggle in toolbar (scissors icon) + `B` key shortcut
- In blade mode: vertical red line follows cursor on timeline
- Click to split at that point
- Click a segment to select it (accent gradient border highlight)
- `Delete`/`Backspace` removes selected segment (ripple)
- `Cmd+Z` undoes via existing undo system

### Export Impact
Export iterates enabled segments, mapping each to source time ranges. Replaces `isInCutRegion()` check.

### Migration
Existing `CutRegion` data converts to segments at load time: the full timeline minus cut regions becomes the enabled segments.

## Feature 3: Markers

### Data Model
```swift
struct TimelineMarker: Identifiable, Equatable {
    let id: UUID
    var time: TimeInterval
    var label: String
    var color: MarkerColor  // blue, red, green, yellow, orange, purple
}
```

### Interaction
- Press `M` at playhead to add marker (default: "Marker N", blue)
- Double-click marker to rename inline
- Right-click for color picker + delete option
- Click marker to jump playhead
- Snap: playhead snaps to markers within 5px proximity

### Visual
- Small triangular flag on top edge of video timeline track
- Colored by marker color
- Label tooltip on hover

## Feature 4: Audio Waveform Visualization

### Loading
- Read audio files (system_audio.caf, mic_audio.caf) via `AVAudioFile` at editor load time
- Downsample to ~200 samples/second

### Visual
- Filled waveform path in audio track area
- Mic: accent blue, System: green
- Fill opacity 0.6, top edge 0.9 opacity
- Scales with timeline zoom
- Muted: dims to 0.2 opacity

### Performance
- Pre-computed at load time
- Rendered as `Canvas` view (no per-frame recomputation)

## Files Affected

- `VideoEditorView.swift` — Major rewrite of timeline UI, new components
- `VideoEditorController.swift` — New state (segments, markers, zoom, waveform data), new methods
- `RecordingTypes.swift` — New types (TimelineSegment, TimelineMarker, MarkerColor)
- `ExportService.swift` — Update export to use segments instead of CutRegion
- `EditorWindowController.swift` — Minor: pass new state through

## Undo/Redo

All new operations (split, delete segment, add/remove marker, move marker) push to the existing undo stack. `EditorSnapshot` expands to include segments and markers.
