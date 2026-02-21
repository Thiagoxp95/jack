# Screen Recording Feature — Design Document

**Date**: 2026-02-21
**Status**: Approved

## Summary

Add a Screen Studio-like screen recording feature to Actionfy. Users record their screen (full display, specific window, or freeform region), optionally with microphone, system audio, and webcam overlay. After recording, a built-in video editor supports cutting, cinematic auto-zoom (follows cursor with smooth interpolation), cursor enlargement, and click highlights. The rendering pipeline uses Metal compute shaders for real-time preview and export.

## Decisions

- **Mode**: Separate from dictation for now; architect for future simultaneous use
- **Architecture**: ScreenCaptureKit + Metal custom renderer (Approach 3)
- **Webcam**: Captured live as an on-screen window (not composited in post)
- **Cursor enlargement**: Post-processing in editor, adjustable scale
- **Zoom**: Auto-follows cursor position, user defines timing and zoom level on timeline
- **Region selection**: Freeform drag + shift-snap to aspect ratios (16:9, 4:3, 1:1, 9:16)
- **Audio**: Separate tracks (system + mic) with independent volume/mute in editor
- **Export**: H.264 and H.265 with quality presets (Low/Medium/High/Lossless)
- **Storage**: Exports to `~/Documents/Actionfy Recordings/`, raw files discarded after export
- **Cursor tracking**: Record mouse position + clicks during capture as JSON sidecar

---

## 1. Service Architecture

### New Services

| Service | Type | Responsibility |
|---------|------|----------------|
| `ScreenRecordingService` | `actor` | Manages SCStream lifecycle, frame capture, writes raw video/audio to disk |
| `WebcamCaptureService` | `actor` | AVCaptureSession for camera, delivers CMSampleBuffers |
| `CursorTrackingService` | `actor` | CGEvent tap for mouse position + clicks at capture framerate, writes JSON sidecar |
| `RecordingSessionController` | `@Observable @MainActor` | Orchestrates all recording services, manages state machine, publishes UI state |
| `MetalVideoRenderer` | `class` | Metal pipeline for compositing zoom, cursor enlargement, click highlights |
| `VideoEditorController` | `@Observable @MainActor` | Editor state: timeline position, cuts, zoom keyframes, export |

### State Machine

```
idle → setup → recording → paused → recording → stopped → editing → exporting → idle
```

### Data Flow — Recording

```
SCStream ──► Raw video frames (CMSampleBuffer) ──► AVAssetWriter (screen.mov)
SCStream ──► System audio (CMSampleBuffer) ──► AVAssetWriter (system-audio.m4a)
AVCaptureSession ──► Webcam frames ──► AVAssetWriter (webcam.mov)
CGEvent tap ──► cursor positions + clicks ──► JSON sidecar (cursor-data.json)
```

All raw files go to a temp session directory: `~/Library/Caches/Actionfy/recordings/<session-uuid>/`

### Data Flow — Editing/Export

```
Raw video + cursor data ──► MetalVideoRenderer ──► MTKView (preview)
                                                ──► AVAssetWriter (final export)
```

### Integration

- `DictationController` gets `appMode: AppMode` enum (`.dictation` | `.screenRecording`)
- `RecordingSessionController` lives alongside `DictationController`, both injected into environment
- ContentView sidebar gets a "Screen Recording" section
- `FloatingBubbleController` pattern reused for recording status bubble (new instance)

---

## 2. Setup Window

### Specs
- `NSPanel`, `.floating` level, non-activating
- ~480 x 520, centered on screen
- Dark theme (`#1C1C1E`), Raycast-inspired aesthetic

### Layout

**Source Selection** — Three toggle buttons: Screen | Window | Region
- Screen: dropdown of available displays
- Window: thumbnail grid of open windows (from `SCShareableContent.current`)
- Region: triggers freeform drag overlay (shift-snap to ratios)
- Live preview thumbnail below

**Audio Options**
- Microphone: toggle + device dropdown + level meter
- System Audio: toggle (label: "Record system sounds")

**Webcam Options**
- Webcam: toggle + camera dropdown
- When enabled: preview circle, position presets (BL/BR/TL/TR), size slider (80/120/180px)

**Recording Options**
- FPS: segmented control — 30 | 60 | 120
- Estimated file size note

**Actions**
- Cancel (left), Start Recording (right, accent)

### Region Selection Overlay
- Full-screen semi-transparent dark overlay (`NSWindow`, `.screenSaver` level)
- Crosshair cursor, drag to define rectangle (live WxH label)
- Shift to snap to aspect ratios
- Enter/double-click to confirm, Escape to cancel
- Handles for resizing confirmed region

---

## 3. Recording Status Bubble

### Specs
- `NSPanel`, `.floating`, joins all spaces
- ~200 x 44, pill shape, bottom-center of screen (~40px above dock)
- Dark frosted glass (`NSVisualEffectView`, `.hudWindow` material)
- Draggable to reposition

### Layout

```
[ 🔴 ] [ 00:03:42 ] [ ⏸ ] [ ⏹ ]
```

- Red dot: pulsing animation (recording), yellow when paused
- Timer: monospaced `HH:MM:SS`, grays out when paused
- Pause/Stop buttons, expand labels on hover

### Behavior
- 3-2-1 fullscreen countdown before recording starts
- Slide-up appear animation with bounce
- Slide-down on stop, then editor opens

### Webcam Overlay (during recording)
- Separate `NSPanel`, `.floating`, circular mask
- `AVCaptureVideoPreviewLayer` inside
- Draggable + resizable (pinch/scroll) during recording
- 2px white ring border with drop shadow
- Default: bottom-left, 120px diameter
- Captured by SCStream as part of the screen (not excluded)

---

## 4. Video Editor

### Window Specs
- Standard `NSWindow`, resizable, minimum 900 x 600
- Dark theme, title: "Actionfy — Edit Recording"

### Layout

```
┌──────────────────────────────────────────────┐
│ Toolbar: [Undo] [Redo]     [Export ▾] [Done] │
├──────────────────────────────────────────────┤
│                                              │
│         Video Preview (MTKView)              │
│      Real-time Metal rendering               │
│                                              │
├──────────────────────────────────────────────┤
│ Cursor Effects Panel (collapsible):          │
│   Size: [1x ────── 3x]                      │
│   Click highlight: [on/off] [color] [opacity]│
│   Cursor smoothing: [on/off]                 │
├──────────────────────────────────────────────┤
│ Video Timeline (thumbnails + playhead)       │
│ ├──|████████████████████████████|──┤         │
│                                              │
│ Zoom Timeline                                │
│ ├────[===2x===]──────[==1.5x==]────┤        │
│                                              │
│ Audio Tracks                                 │
│ 🎤 Mic:    waveform  [🔊] [mute]           │
│ 🔊 System: waveform  [🔊] [mute]           │
└──────────────────────────────────────────────┘
```

### Video Timeline
- Horizontal scrollable, thumbnail strip (~2s intervals)
- Draggable playhead
- Cut: `I` for in-point, `O` for out-point, Delete to remove segment
- Non-destructive edit decision list

### Zoom Timeline
- Same time scale as video timeline
- Click-drag to create zoom regions
- Each region: duration handles, zoom level (drag up/down, 1.5x–4x)
- Auto-follows cursor position within video
- Cinematic transitions: cubic bezier ease-in (300ms), hold, ease-out (300ms)
- Delete selected region with Delete key

### Audio Tracks
- Two waveform visualizations (mic + system)
- Independent volume slider + mute per track
- Cuts apply to all tracks equally

### Export Dialog (sheet)
- Codec: H.264 | H.265
- Quality: Low | Medium | High | Lossless (with estimated file size)
- Resolution: Original | 1080p | 720p
- Destination: `~/Documents/Actionfy Recordings/` + filename preview
- Progress bar during export

### Keyboard Shortcuts

| Key | Action |
|-----|--------|
| Space | Play/Pause |
| ← / → | Frame step |
| I / O | Set in/out points |
| Delete | Remove selected region |
| Cmd+Z / Cmd+Shift+Z | Undo / Redo |
| Cmd+E | Export |

---

## 5. Permissions & Onboarding

### New Permissions

| Permission | API | Purpose |
|------------|-----|---------|
| Screen Recording | `SCShareableContent.current` (triggers prompt) | Capture screen/window content |
| Camera | `AVCaptureDevice.requestAccess(for: .video)` | Webcam overlay |

### Onboarding Wizard

New optional step between "Permissions" and "Shortcut Setup":
- Two-column layout (matching redesign)
- Screen Recording + Camera permission cards with status badges
- "Skip for now" link (permissions requestable lazily on first use)

### Sidebar

New section at bottom of sidebar:
- Status card ("Ready to record" / "Recording..." / "No permission")
- Start Recording button
- Recent recordings list (last 5, thumbnails)
- Default settings (FPS, source, webcam position)

---

## 6. Metal Rendering Pipeline

### Compute Shader: ZoomAndCursorCompositor

```
Input frame (CVPixelBuffer) + cursor data + zoom keyframes
    │
    ├── Phase 1: Zoom Transform
    │   ├── Zoom center = cursor position with exponential smoothing
    │   │   smoothed = lerp(previous, current, 0.15) per frame
    │   ├── Zoom level from keyframes with cubic bezier easing
    │   ├── Compute source rect, bicubic sample → output texture
    │
    ├── Phase 2: Cursor Overlay
    │   ├── Scale cursor texture to user-defined size (1x–3x)
    │   ├── Position at tracked coords (adjusted for zoom)
    │   └── Alpha-blend onto output
    │
    └── Phase 3: Click Highlight
        ├── Expanding circle at click positions (~400ms, ease-out)
        ├── Radial gradient, user-defined color + opacity
    │
    ▼
Output → MTKView (preview) or AVAssetWriter (export)
```

### Zoom Interpolation
- Ease curve: cubic bezier `(0.25, 0.1, 0.25, 1.0)`
- Ramp: 300ms in, 300ms out
- Cursor trailing: exponential smoothing factor 0.15 per frame

### Performance
- Metal compute handles 4K@120fps on Apple Silicon
- Ring buffer of ±5 decoded frames for smooth scrubbing
- Batch rendering for export

### Cursor Data Format

```json
{
  "framerate": 60,
  "events": [
    { "t": 0.000, "x": 512, "y": 384 },
    { "t": 0.016, "x": 515, "y": 386 },
    { "t": 0.033, "x": 518, "y": 386, "click": "left" }
  ]
}
```

Timestamps relative to recording start. Click type inline.
