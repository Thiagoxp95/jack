# AI Mode — Design

## Summary

Add "AI mode" as a fourth recording output mode. During dictation, the user presses a configurable switch key to enter AI mode (sparkles icon in bubble). When dictation finishes, the transcribed text is sent to the AI chat side sheet: a new thread is created and the AI response streams in real-time.

## Activation

Same pattern as todo mode: a configurable single-key (the "AI Switch Key") configured in General settings. Pressing it during recording toggles between paste mode and AI mode. Pressing it again toggles back.

## Bubble Icon

When AI mode is active, the bubble icon swaps to `sparkles` (SF Symbol), matching the pattern of `checklist` for todo mode and `note.text` for voice note mode. Bubble message: `"Listening (AI Mode)..."`.

## On Dictation Finish

1. Open the chat side sheet (if not already visible).
2. Create a new thread (title = first ~50 chars of the dictated text).
3. Set the dictated text as the user message.
4. Call `sendAndStream()` so the AI response streams in real-time.
5. Reset recording output mode back to `.paste`.

## Changes by File

| File | Change |
|------|--------|
| `ShortcutTypes.swift` | Add `.aiChat` case to `RecordingOutputMode` |
| `DictationController.swift` | Add `aiSwitchKeyCode` property, capture logic, `.aiChat` case in `handleTranscriptionResult`, `syncAiChatMessage()` method |
| `GlobalFnShortcutMonitor.swift` | Add `onAiSwitchKeyPressed` callback + `aiSwitchKeyCode` property |
| `ContentView.swift` | Add "AI Switch Key" row in General settings |
| `FloatingBubbleController.swift` | Add `isAiMode` flag, show `sparkles` icon |
| `ChatSideSheetController.swift` | Add `openWithMessage(_ text: String)` method |

## What Stays the Same

- Existing chat sheet shortcut (open/close independently) is untouched.
- All existing modes (paste, voiceNote, todo) work exactly as before.
- `RecordingOutputMode` resets to `.paste` after each dictation.
