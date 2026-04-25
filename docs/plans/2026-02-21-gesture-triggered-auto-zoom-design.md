# Gesture-Triggered Auto-Zoom Design

**Date:** 2026-02-21
**Status:** Approved

## Overview

Automatically detect mouse gestures (jiggling and circling) during screen recording and convert them into zoom keyframes that appear in the video editor. The user jiggles or circles the cursor to highlight something on screen, and after recording, those moments appear as 2.0x zoom blocks on the zoom timeline.

## Decisions

- **Approach:** Sliding window direction-reversal detector (Approach A)
- **Sensitivity:** High — quick back-and-forth or circular motion within ~100-150px over ~0.3-0.5s triggers
- **Timing:** Post-recording analysis of cursor_data.json, before editor opens
- **Zoom level:** Fixed 2.0x for all auto-detected gestures (user can adjust in editor)
- **Merge logic:** Merge regions with gaps < 2 seconds

## Gesture Detection Algorithm

New file: `GestureZoomDetector.swift` — a pure, stateless struct.

**Input:** `[CursorEvent]` from `cursor_data.json`
**Output:** `[ZoomKeyframe]` ready to inject into the editor

### Jiggle Detection (horizontal back-and-forth)

- Sliding window of 0.5 seconds over cursor events
- Compute X-velocity between consecutive events
- Count X-direction reversals (sign changes in X-velocity, ignoring near-zero velocities below a deadzone of ~2px/sample to filter noise)
- **Trigger:** 3+ reversals in 0.5s window = jiggle detected
- Gesture center = average position of events during the gesture window

### Circle Detection (cursor orbiting a point)

- Sliding window of 1.0 seconds, tracking angular displacement around centroid
- For each consecutive pair of events, compute angle change relative to window centroid using atan2
- Accumulate total absolute angular change
- **Trigger:** cumulative angle >= 270° (~4.7 radians) in 1.0s window = circle detected

### Gesture Region Building

1. Walk through events chronologically
2. At each event, evaluate both detectors on the trailing window
3. If either triggers, mark the event's time as "in gesture"
4. Region starts at first "in gesture" event, extends until no gesture for 0.3s (settle threshold)
5. After gesture ends, append +3.0 seconds as zoom tail
6. All regions get zoom level 2.0x

### Merging

- After all regions built, merge any two where gap between one's end (including tail) and next's start is < 2.0 seconds
- Merged region spans from earliest start to latest end (including tail)

### Overlap Prevention

- Check auto-generated keyframes against any existing keyframes
- Drop auto-keyframes that overlap

## Integration with Recording Pipeline

### Current flow

```
stopRecording() → save cursor data → save video → transition to .editing → open VideoEditorView
```

### New flow

```
stopRecording() → save cursor data → save video → run GestureZoomDetector → inject keyframes → transition to .editing → open VideoEditorView
```

After `CursorTrackingService.stopTracking()` returns `CursorTrackingData`, pass `cursorData.events` to `GestureZoomDetector.detect(events:)`. Set `videoEditorController.zoomKeyframes = detectedKeyframes` before transitioning to `.editing`.

Runs synchronously — cursor data is small (few thousand events) so detection is sub-millisecond.

## Editor UI

Auto-detected zoom keyframes are identical to manually-created ones. Blue blocks labeled "2.0x" on the zoom timeline. All existing interactions work:

- Double-click to cycle zoom level
- Scroll wheel to fine-tune
- Right-click to delete
- Undo/redo (initial auto-detected state captured in first editor snapshot)

No new UI elements needed.

## Constants

| Constant | Value | Purpose |
|----------|-------|---------|
| `jiggleWindow` | 0.5s | Time window for reversal counting |
| `jiggleReversalThreshold` | 3 | Min X-reversals to trigger |
| `velocityDeadzone` | 2.0 px | Ignore tiny movements as noise |
| `circleWindow` | 1.0s | Time window for angular analysis |
| `circleAngleThreshold` | 270° (4.7 rad) | Min angular sweep to trigger |
| `settleTimeout` | 0.3s | Cursor rest time to end gesture |
| `zoomTailDuration` | 3.0s | Extra zoom time after gesture ends |
| `mergeGapThreshold` | 2.0s | Max gap between regions to merge |
| `defaultZoomLevel` | 2.0 | Zoom level for all auto-detected regions |

## Files Touched

- **NEW:** `Sources/JackApp/ScreenRecording/GestureZoomDetector.swift`
- **EDIT:** `Sources/JackApp/ScreenRecording/RecordingSessionController.swift` (~5 lines: call detector, set keyframes before editor opens)

## Data Flow

```
RECORDING: CGEvent tap → CursorTrackingService → [CursorEvent] → cursor_data.json
POST-REC:  cursor_data.json → GestureZoomDetector.detect(events:) → [ZoomKeyframe]
EDITOR:    [ZoomKeyframe] → videoEditorController.zoomKeyframes → zoom timeline + renderer + export
```
