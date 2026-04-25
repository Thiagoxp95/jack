# Space Cycling During Dictation — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Allow users to cycle through spaces using left/right arrow keys while recording, updating the bubble indicator and persisting the space change.

**Architecture:** Add a `SpaceCycleDirection` enum and `isRecordingForSpaceCycle` flag to `GlobalFnShortcutMonitor` so it intercepts and consumes left/right arrow keys during recording. Wire a new callback in `DictationController` that computes the next space circularly and updates both `SpaceController` and the bubble.

**Tech Stack:** Swift, AppKit (CGEvent tap), macOS

---

### Task 1: Add SpaceCycleDirection enum and new properties to GlobalFnShortcutMonitor

**Files:**
- Modify: `Sources/JackApp/GlobalFnShortcutMonitor.swift:5` (inside class)

**Step 1: Add the enum and new properties**

Add these after line 18 (`var onVoiceNoteSwitchKeyPressed: (() -> Void)?`):

```swift
enum SpaceCycleDirection {
    case left, right
}

var onSpaceCycleKeyPressed: ((SpaceCycleDirection) -> Void)?
var isRecordingForSpaceCycle = false
```

**Step 2: Verify it compiles**

Run: `swift build` (or Xcode build)
Expected: Compiles with no errors

**Step 3: Commit**

```bash
git add Sources/JackApp/GlobalFnShortcutMonitor.swift
git commit -m "feat: add SpaceCycleDirection enum and properties to GlobalFnShortcutMonitor"
```

---

### Task 2: Intercept left/right arrow keys in handleKeyEvent

**Files:**
- Modify: `Sources/JackApp/GlobalFnShortcutMonitor.swift:178` (`handleKeyEvent` method)

**Step 1: Add arrow key interception at the top of handleKeyEvent**

Insert at the beginning of `handleKeyEvent(_:isKeyDown:)`, right after `let keyCode = ...` (line 179), before the voice note switch key check (line 181):

```swift
// Space cycling: intercept left/right arrow keys during recording
if isRecordingForSpaceCycle, isKeyDown {
    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    if !isRepeat {
        if keyCode == 123 { // left arrow
            onSpaceCycleKeyPressed?(.left)
            return true
        } else if keyCode == 124 { // right arrow
            onSpaceCycleKeyPressed?(.right)
            return true
        }
    }
}
```

This goes before the voice-note-switch-key check so arrow keys are handled first. We only fire on non-repeat keyDown events to avoid rapid cycling from held keys. The event is consumed (returns `true` → CGEvent callback returns `nil`).

**Step 2: Verify it compiles**

Run: `swift build`
Expected: Compiles with no errors

**Step 3: Commit**

```bash
git add Sources/JackApp/GlobalFnShortcutMonitor.swift
git commit -m "feat: intercept left/right arrow keys during recording for space cycling"
```

---

### Task 3: Wire up space cycling in DictationController

**Files:**
- Modify: `Sources/JackApp/DictationController.swift:298-307` (callback wiring in init)
- Modify: `Sources/JackApp/DictationController.swift:731-732` (beginRecording)
- Modify: `Sources/JackApp/DictationController.swift:764-765` (stopRecordingAndTranscribe)

**Step 1: Add the callback wiring after the existing onVoiceNoteSwitchKeyPressed setup (after line 307)**

```swift
shortcutMonitor.onSpaceCycleKeyPressed = { [weak self] direction in
    Task { @MainActor [weak self] in
        self?.cycleSpace(direction: direction)
    }
}
```

**Step 2: Add cycleSpace method to DictationController**

Add near `toggleRecordingOutputMode()` (after line 676):

```swift
private func cycleSpace(direction: GlobalFnShortcutMonitor.SpaceCycleDirection) {
    guard isRecording, !isTranscribing else {
        return
    }
    guard let sc = spaceController else {
        return
    }

    let spaces = sc.availableSpaces
    guard spaces.count > 1 else {
        return
    }

    let currentIndex = spaces.firstIndex(where: { $0.id == sc.activeSpace.id }) ?? 0
    let nextIndex: Int
    switch direction {
    case .left:
        nextIndex = (currentIndex - 1 + spaces.count) % spaces.count
    case .right:
        nextIndex = (currentIndex + 1) % spaces.count
    }

    let nextSpace = spaces[nextIndex]
    sc.switchSpace(to: nextSpace)
    syncSpaceAppearance()
}
```

**Step 3: Set isRecordingForSpaceCycle in beginRecording**

In `beginRecording()`, after `isRecording = true` (line 732), add:

```swift
shortcutMonitor.isRecordingForSpaceCycle = true
```

**Step 4: Clear isRecordingForSpaceCycle in stopRecordingAndTranscribe**

In `stopRecordingAndTranscribe()`, after `isRecording = false` (line 765), add:

```swift
shortcutMonitor.isRecordingForSpaceCycle = false
```

Also in the early-return guard at line 705 area — check if there are other paths that set `isRecording = false`. The `wantRecording = false` and `isRecording = false` at line 764-765 is the main path. The error path at line 773-774 also returns early, but `isRecording` was never set to true in that flow so no action needed there.

**Step 5: Verify it compiles**

Run: `swift build`
Expected: Compiles with no errors

**Step 6: Commit**

```bash
git add Sources/JackApp/DictationController.swift
git commit -m "feat: wire up space cycling with left/right arrow keys during recording"
```

---

### Task 4: Manual testing checklist

Since this is a macOS app with hardware-dependent keyboard event taps, verify manually:

1. **Start recording** (any mode: toggle, hold, double-tap)
2. **Press right arrow** — bubble icon/color should change to next space
3. **Press right arrow again** — should advance to next space; wraps to first space after last
4. **Press left arrow** — should go back to previous space; wraps to last space from first
5. **Stop recording** — the app should remain on whichever space you last cycled to
6. **Start voice note recording, cycle space, stop** — note should save to the cycled-to space (verify in Convex dashboard or local file)
7. **Arrow keys when NOT recording** — should pass through normally to other apps
8. **Only 1 space available** — arrow keys should be no-ops (no crash, no visual change)
9. **Hold arrow key** — should NOT rapid-fire cycle (auto-repeat events are ignored)
