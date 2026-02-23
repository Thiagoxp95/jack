# Cinematic Cursor Zoom Design

## Overview

Enhance the existing zoom timeline with cinematic camera-like zoom transitions that follow the cursor. Users click-drag on the zoom timeline to create zoom blocks, each with an adjustable zoom level. Zoom in/out transitions use asymmetric easing curves for a "camera dolly" feel rather than instant digital scaling.

## Approach

Extend the existing `ZoomKeyframe` system — no new data models, no new files. The changes are:

1. Cinematic asymmetric easing curves (replacing symmetric smoothstep)
2. Click-drag creation on the zoom timeline
3. Per-block zoom level adjustment (double-click cycle + scroll wheel)
4. Soft edge clamping for the zoom viewport

## Interaction Model

### Creating zoom blocks
- Click-drag on the zoom timeline track to draw a time range
- Semi-transparent blue block appears during drag as preview
- On release, a `ZoomKeyframe` is created with default 2.0x zoom
- Overlap prevention: new blocks snap to available gaps or are rejected

### Adjusting zoom level
- **Double-click** a block to cycle presets: 1.5x → 2.0x → 2.5x → 3.0x → 1.5x
- **Scroll wheel** while hovering a block for fine-tuning in 0.1x increments (range 1.2x–4.0x)
- Block label updates in real-time to show current zoom level

### Removing blocks
- Right-click → delete, or select + Delete key (existing `removeZoomRegion`)

## Cinematic Easing

### Ramp duration: 0.6s (up from 0.3s)

### Asymmetric curves
- **Zoom-in (ease-out cubic)**: `1 - (1-t)^3` — starts fast, decelerates gently into full zoom. Camera confidently pushes in, then gently lands.
- **Zoom-out (ease-in cubic)**: `t^3` — starts slowly pulling back, then accelerates to settle at 1x. Camera gently lifts off, then pulls out.

The asymmetry creates the "camera dolly" feel — the zoom has weight and momentum. The in-transition feels assertive, the out-transition feels like a gentle release.

### Interpolation phases
For a keyframe with `startTime`, `endTime`, and 0.6s ramp:
1. **Ease-in phase** (0 → 0.6s from start): Zoom from 1.0x to `zoomLevel` using ease-out cubic
2. **Plateau** (middle): Hold at `zoomLevel`
3. **Ease-out phase** (0.6s before end → end): Zoom from `zoomLevel` to 1.0x using ease-in cubic

If the block is shorter than 1.2s, the ramp is clamped to `duration / 2`.

## Soft Edge Clamping

When the cursor is near the edge of the screen recording and the viewport is zoomed:

1. Calculate "safe area" — the region where the zoom viewport fits entirely within the video frame
2. When cursor-following center approaches the safe area boundary, apply exponential decay to panning speed
3. Viewport smoothly decelerates and stops at the edge — no black/empty space revealed
4. Deceleration zone: 5% of viewport width on each side as the margin

Applied in both the Metal shader (export) and preview compositor.

## Files Changed

| File | Change |
|------|--------|
| `MetalVideoRenderer.swift` | New `cinematicEaseIn`/`cinematicEaseOut` functions, updated `interpolateZoom` with 0.6s ramp + asymmetric easing, soft clamping in zoom center calculation |
| `VideoEditorView.swift` | Click-drag gesture on zoom timeline, double-click to cycle zoom level, scroll-wheel to fine-tune, overlap prevention |
| `VideoEditorController.swift` | `updateZoomLevel(id:level:)` method for adjusting per-block zoom |
| `ExportService.swift` | Update ramp duration constant from 0.3 to 0.6 |
| `ZoomCursorCompositor.metal` | Soft clamping logic for zoom center |

No new files. No data model changes (`ZoomKeyframe` already has `zoomLevel`).
