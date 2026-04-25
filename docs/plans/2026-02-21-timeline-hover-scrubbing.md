# Timeline Hover Scrubbing Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Enable hover-based video scrubbing on the editor timeline — moving the mouse over the timeline scrubs the video and updates the main preview in real-time.

**Architecture:** Replace the existing `DragGesture` on the video timeline with `.onContinuousHover`. On hover, calculate time from X position, pause playback, and set `editor.currentTime`. The existing AVPlayer seek logic in MetalPreviewView handles the rest. Add throttling (~30fps) to avoid overwhelming AVPlayer with seeks.

**Tech Stack:** SwiftUI (`.onContinuousHover`), AVFoundation (existing seeking)

---

### Task 1: Add hover scrubbing to the video timeline

**Files:**
- Modify: `Sources/JackApp/ScreenRecording/VideoEditorView.swift:195-248` (videoTimeline section)

**Step 1: Replace the DragGesture with `.onContinuousHover`**

In the `videoTimeline` `@ViewBuilder`, replace lines 238-245:

```swift
// CURRENT CODE (remove this):
.gesture(
    DragGesture(minimumDistance: 0)
        .onChanged { value in
            let ratio = max(0, min(1, value.location.x / width))
            editor.currentTime = ratio * editor.duration
        }
)
```

With:

```swift
.onContinuousHover { phase in
    switch phase {
    case .active(let location):
        // Pause playback when scrubbing starts
        if editor.isPlaying {
            editor.pause()
        }
        let ratio = max(0, min(1, location.x / width))
        editor.currentTime = ratio * editor.duration
    case .ended:
        // Playhead stays at last hover position — nothing to do
        break
    }
}
```

**Step 2: Add click-to-seek via tap gesture**

After the `.onContinuousHover`, add a tap gesture so clicking on the timeline also works (replaces the old drag "tap" behavior):

```swift
.onTapGesture { location in
    let ratio = max(0, min(1, location.x / width))
    editor.currentTime = ratio * editor.duration
}
```

Note: `.onTapGesture` with a location parameter requires a `CoordinateSpace`. We need to use a named coordinate space on the GeometryReader. Full replacement looks like:

```swift
GeometryReader { geometry in
    let width = geometry.size.width
    let height = geometry.size.height

    ZStack(alignment: .leading) {
        // ... existing content (track background, cut regions, markers, playhead) ...
    }
    .contentShape(Rectangle())
    .onContinuousHover { phase in
        switch phase {
        case .active(let location):
            if editor.isPlaying {
                editor.pause()
            }
            let ratio = max(0, min(1, location.x / width))
            editor.currentTime = ratio * editor.duration
        case .ended:
            break
        }
    }
    .gesture(
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if editor.isPlaying {
                    editor.pause()
                }
                let ratio = max(0, min(1, value.location.x / width))
                editor.currentTime = ratio * editor.duration
            }
    )
}
```

We keep the `DragGesture(minimumDistance: 0)` as a fallback for click-and-drag (it also handles taps since `minimumDistance: 0`). The `.onContinuousHover` handles hover scrubbing. Both coexist — hover triggers on mouse move, drag triggers on click.

**Step 3: Build and verify**

Run: `swift build`
Expected: Builds successfully with no errors.

**Step 4: Commit**

```bash
git add Sources/JackApp/ScreenRecording/VideoEditorView.swift
git commit -m "feat(editor): add hover scrubbing on video timeline"
```

---

### Task 2: Add seek throttling for smooth scrubbing

**Files:**
- Modify: `Sources/JackApp/ScreenRecording/VideoEditorView.swift` (videoTimeline section)

The `.onContinuousHover` fires on every mouse move event, which can be very frequent (>60fps on a retina display). We should throttle how often we update `editor.currentTime` to ~30fps.

**Step 1: Add a `lastScrubTime` state variable**

Add a `@State` property to `VideoEditorView`:

```swift
@State private var lastScrubTime: Date = .distantPast
```

**Step 2: Gate hover updates behind the throttle**

Update the `.onContinuousHover` to check the time since last update:

```swift
.onContinuousHover { phase in
    switch phase {
    case .active(let location):
        let now = Date()
        guard now.timeIntervalSince(lastScrubTime) >= 1.0 / 30.0 else { return }
        lastScrubTime = now

        if editor.isPlaying {
            editor.pause()
        }
        let ratio = max(0, min(1, location.x / width))
        editor.currentTime = ratio * editor.duration
    case .ended:
        break
    }
}
```

This caps scrub updates at ~30fps — fast enough to feel responsive, slow enough to avoid seek overload.

**Step 3: Build and verify**

Run: `swift build`
Expected: Builds successfully.

**Step 4: Commit**

```bash
git add Sources/JackApp/ScreenRecording/VideoEditorView.swift
git commit -m "perf(editor): throttle hover scrub to 30fps"
```

---

### Task 3: Reduce seek threshold for tighter scrubbing

**Files:**
- Modify: `Sources/JackApp/ScreenRecording/MetalPreviewView.swift:36-43`

The existing seek-while-paused code in MetalPreviewView has a 50ms threshold (`diff > 0.05`). This was fine for occasional seeks but may feel sluggish during continuous hover scrubbing. Lower it to 16ms (~one frame at 60fps) for tighter response.

**Step 1: Lower the seek threshold**

Change line 40 from:

```swift
if diff > 0.05 {
```

To:

```swift
if diff > 0.016 {
```

**Step 2: Build and verify**

Run: `swift build`
Expected: Builds successfully.

**Step 3: Commit**

```bash
git add Sources/JackApp/ScreenRecording/MetalPreviewView.swift
git commit -m "perf(editor): lower seek threshold for smoother scrubbing"
```
