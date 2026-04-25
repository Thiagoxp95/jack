# Timeline Hover Scrubbing Design

**Date:** 2026-02-21
**Status:** Approved

## Summary

Add hover-based scrubbing to the video editor timeline. Moving the mouse over the timeline scrubs the video — the main preview updates in real-time to show the frame at the hover position. The playhead stays at the last hovered position when the mouse leaves.

## Behavior

- **Trigger:** Mouse hover over the video timeline (no click needed)
- **Preview:** Main video preview (AVPlayer) updates in real-time
- **On mouse leave:** Playhead stays at last hover position
- **Playback:** Pauses when hover scrubbing starts

## Approach

Use SwiftUI `.onContinuousHover` modifier (Approach 1 — simplest, leverages existing seek infrastructure).

## Implementation Details

1. **Replace `DragGesture` with `.onContinuousHover`** on the video timeline GeometryReader. Compute `ratio = location.x / width`, clamp to [0,1], set `editor.currentTime = ratio * editor.duration`.

2. **Pause playback on hover start.** If the video is playing when hovering begins, pause it so scrubbing takes over.

3. **Throttle seek calls** to ~30fps (~33ms intervals) to avoid overwhelming AVPlayer while still feeling responsive. The existing MetalPreviewView already guards against seeks <50ms apart.

4. **Visual playhead follows hover.** The white playhead line already renders at `editor.currentTime / editor.duration * width`, so it naturally follows.

5. **Keep click-to-seek.** Add a tap gesture so clicking on the timeline sets the playhead directly.

## Files Changed

- `Sources/JackApp/ScreenRecording/VideoEditorView.swift` — timeline gesture/hover logic
- `Sources/JackApp/ScreenRecording/MetalPreviewView.swift` — minor seek throttling adjustment if needed
