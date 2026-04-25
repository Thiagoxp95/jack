# Space Cycling During Dictation

## Overview

While recording (regardless of shortcut mode or output mode), left and right arrow keys cycle through available spaces. The bubble indicator updates to show the new space's icon and color. The space change is persistent via `spaceController.switchSpace(to:)`.

## Requirements

- Left/right arrow keys cycle spaces while recording and indicator is visible
- Works in all shortcut modes (toggle, hold, double-tap) and all output modes (paste, voice note)
- Bubble indicator updates icon + color to reflect the new space
- Wraps around circularly in both directions
- Arrow key events are consumed (not passed to other apps) during recording
- Space change is persistent — app stays on the new space after recording ends

## Architecture

### Keyboard Layer — GlobalFnShortcutMonitor

- New callback: `onSpaceCycleKeyPressed: ((SpaceCycleDirection) -> Void)?`
- New property: `var isRecording: Bool` — set by DictationController
- In `handleKeyEvent()`: when `isRecording` is true, intercept left arrow (keyCode 123) and right arrow (keyCode 124) on keyDown
- Consume events by returning `nil` from CGEvent callback

### Controller Layer — DictationController

- Wire up `onSpaceCycleKeyPressed` callback
- Compute next/previous space from `spaceController.availableSpaces` (circular wrap)
- Call `spaceController.switchSpace(to:)` to persist
- Call `floatingBubble.setSpaceAppearance(color:icon:)` to update visual
- Set `shortcutMonitor.isRecording = true` in `beginRecording()`, `false` in `stopRecordingAndTranscribe()`

### No Changes Needed

- `FloatingBubbleController` — already has `setSpaceAppearance(color:icon:)`
- `SpaceController` — already has `switchSpace(to:)` and `availableSpaces`
- Note saving — already reads `spaceController.currentSpaceId` at save time

## Data Flow

```
Arrow key pressed during recording
  -> GlobalFnShortcutMonitor intercepts & consumes event
  -> Calls onSpaceCycleKeyPressed(.left/.right)
  -> DictationController computes next space (circular)
  -> spaceController.switchSpace(to: nextSpace)  [persistent]
  -> floatingBubble.setSpaceAppearance(...)       [visual update]
```

## Edge Cases

- Only 1 space: cycling is a no-op
- Spaces list changes during recording: use current `availableSpaces` at keypress time
- Arrow keys outside recording: pass through normally, no interception
