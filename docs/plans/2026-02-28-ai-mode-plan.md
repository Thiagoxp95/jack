# AI Mode Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add an "AI mode" recording output mode that sends dictated text to the AI chat side sheet as a new thread with streaming response.

**Architecture:** Follows the exact same pattern as todo mode — a new `RecordingOutputMode` case, a single-key switch during recording, a sparkle icon in the bubble, and a post-transcription handler that opens the chat sheet, creates a thread, and streams the response.

**Tech Stack:** Swift, SwiftUI, AppKit (NSPanel), CGEventTap

---

### Task 1: Add `.aiChat` to `RecordingOutputMode`

**Files:**
- Modify: `Sources/JackApp/ShortcutTypes.swift:194-211`

**Step 1: Add the new enum case**

In `RecordingOutputMode`, add `case aiChat` after `todo` and update `title`:

```swift
enum RecordingOutputMode: String, CaseIterable, Identifiable {
    case paste
    case voiceNote
    case todo
    case aiChat

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paste:
            return "Paste"
        case .voiceNote:
            return "Voice Note"
        case .todo:
            return "Todo"
        case .aiChat:
            return "AI Chat"
        }
    }
}
```

**Step 2: Build to find all exhaustive switch sites**

Run: `swift build 2>&1 | head -40`
Expected: Build errors at every `switch recordingOutputMode` that needs a new case. Note all locations — they'll be fixed in subsequent tasks.

**Step 3: Commit**

```bash
git add Sources/JackApp/ShortcutTypes.swift
git commit -m "feat: add aiChat case to RecordingOutputMode"
```

---

### Task 2: Add AI switch key storage and capture to `DictationController`

**Files:**
- Modify: `Sources/JackApp/DictationController.swift`

**Step 1: Add DefaultsKey**

In the `DefaultsKey` enum (~line 337), add:

```swift
static let aiSwitchKeyCode = "ai_switch_key_code"
```

**Step 2: Add KeyCaptureTarget case**

In the `KeyCaptureTarget` enum (~line 367), add:

```swift
case aiSwitch
```

**Step 3: Add published properties**

Near the existing `todoSwitchKeyCode` and `isCapturingTodoSwitchKey` properties (~lines 75-79), add:

```swift
@Published private(set) var aiSwitchKeyCode: Int64
@Published var isCapturingAiSwitchKey = false
```

**Step 4: Load from UserDefaults in `init()`**

After the `initialTodoSwitchKeyCode` block (~line 427), add:

```swift
let initialAiSwitchKeyCode: Int64
if let stored = defaults.object(forKey: DefaultsKey.aiSwitchKeyCode) as? Int {
    initialAiSwitchKeyCode = Int64(stored)
} else {
    initialAiSwitchKeyCode = 0 // A key (same pattern as voice note switch — user must configure)
}
```

Then assign it alongside the other key codes (~line 474):

```swift
aiSwitchKeyCode = initialAiSwitchKeyCode
```

**Step 5: Wire up the monitor**

After `shortcutMonitor.setTodoSwitchKeyCode(initialTodoSwitchKeyCode)` (~line 540), add:

```swift
shortcutMonitor.setAiSwitchKeyCode(initialAiSwitchKeyCode)
```

After the `onTodoSwitchKeyPressed` callback block (~line 562), add:

```swift
shortcutMonitor.onAiSwitchKeyPressed = { [weak self] in
    Task { @MainActor [weak self] in
        self?.setAiChatMode()
    }
}
```

**Step 6: Add display name computed property**

After `todoSwitchKeyDisplayName` (~line 654), add:

```swift
var aiSwitchKeyDisplayName: String {
    InvocationKey.displayName(for: aiSwitchKeyCode)
}
```

**Step 7: Add capture start/cancel methods**

After `cancelTodoSwitchKeyCapture()` (~line 851), add:

```swift
func startAiSwitchKeyCapture() {
    guard !isCapturingInvocationKey, !isCapturingVoiceNoteSwitchKey, !isCapturingScreenRecordingKey, !isCapturingTodoSwitchKey, !isCapturingTodoSheetKey, !isCapturingChatSheetKey, !isCapturingAiSwitchKey else {
        return
    }

    keyCaptureTarget = .aiSwitch
    isCapturingAiSwitchKey = true
    statusText = "Press the key to switch to AI mode while recording."
    installInvocationKeyCaptureMonitors()
}

func cancelAiSwitchKeyCapture() {
    guard isCapturingAiSwitchKey else {
        return
    }

    isCapturingAiSwitchKey = false
    keyCaptureTarget = nil
    removeInvocationKeyCaptureMonitors()
    statusText = "AI key capture canceled."
}
```

**Step 8: Add `setAiSwitchKeyCode` private method**

After `setTodoSwitchKeyCode` (~line 2393), add:

```swift
private func setAiSwitchKeyCode(_ keyCode: Int64) {
    aiSwitchKeyCode = keyCode
    UserDefaults.standard.set(Int(keyCode), forKey: DefaultsKey.aiSwitchKeyCode)
    shortcutMonitor.setAiSwitchKeyCode(keyCode)
}
```

**Step 9: Add `setAiChatMode` toggle method**

After `setTodoMode()` (~line 1190), add:

```swift
private func setAiChatMode() {
    guard isRecording, !isTranscribing else {
        return
    }
    recordingOutputMode = recordingOutputMode == .aiChat ? .paste : .aiChat
    statusText = listeningStatusText(isLive: false)
    showBubble(message: listeningBubbleMessage(), isRecording: true)
}
```

**Step 10: Add `.aiSwitch` to `finalizeCapturedShortcut`**

In `finalizeCapturedShortcut` (~line 2324), after the `.todoSwitch` case, add:

```swift
case .aiSwitch:
    if let primaryKey = shortcut.primaryKeyCode, shortcut.modifiers == 0 {
        setAiSwitchKeyCode(primaryKey)
        statusText = "AI key set to \(aiSwitchKeyDisplayName)."
    } else {
        statusText = "AI key must be a single key."
        return
    }
```

**Step 11: Update all `isCapturing` guard checks**

Every guard that checks `!isCapturingTodoSwitchKey` etc. must also check `!isCapturingAiSwitchKey`. These are in:
- `startInvocationKeyCapture()`, `startVoiceNoteSwitchKeyCapture()`, `startScreenRecordingKeyCapture()`, `startTodoSwitchKeyCapture()`, `startTodoSheetKeyCapture()`, `startChatSheetKeyCapture()`, `startAiSwitchKeyCapture()`
- `handleShortcutEvent()`, `handleScreenRecordingShortcut()`, `handleTodoSheetShortcut()`, `handleChatSheetShortcut()`

Also add to the cleanup block at the bottom of `finalizeCapturedShortcut` (~line 2342):

```swift
isCapturingAiSwitchKey = false
```

**Step 12: Commit**

```bash
git add Sources/JackApp/DictationController.swift
git commit -m "feat: add AI switch key storage and capture to DictationController"
```

---

### Task 3: Add AI switch key handling to `GlobalFnShortcutMonitor`

**Files:**
- Modify: `Sources/JackApp/GlobalFnShortcutMonitor.swift`

**Step 1: Add callback and state properties**

After `onTodoSwitchKeyPressed` (~line 50), add:

```swift
var onAiSwitchKeyPressed: (() -> Void)?
```

After the todo switch state variables (~line 82), add:

```swift
// AI switch (single-key, mirrors todo switch)
private var aiSwitchKeyCode: Int64?
private var aiSwitchArmed = false
private var consumeAiSwitchKeyUp = false
```

**Step 2: Add `setAiSwitchKeyCode` and arm methods**

After `setTodoSwitchArmed` (~line 140), add:

```swift
func setAiSwitchKeyCode(_ keyCode: Int64?) {
    aiSwitchKeyCode = keyCode
    consumeAiSwitchKeyUp = false
}

func setAiSwitchArmed(_ armed: Bool) {
    aiSwitchArmed = armed
    if !armed {
        consumeAiSwitchKeyUp = false
    }
}
```

**Step 3: Update `setRecordingControlsActive`**

In `setRecordingControlsActive` (~line 142), add after `setTodoSwitchArmed(active)`:

```swift
setAiSwitchArmed(active)
```

**Step 4: Add key event handling**

In `handleKeyEvent`, after the todo switch key block (~line 485), add the same pattern:

```swift
// AI switch key
if !invocationHasPriority,
   let aiSwitchKeyCode,
   keyCode == aiSwitchKeyCode
{
    if isKeyDown {
        if isRepeat {
            return aiSwitchArmed
        }

        if aiSwitchArmed {
            consumeAiSwitchKeyUp = true
            onAiSwitchKeyPressed?()
            return true
        }
    } else if consumeAiSwitchKeyUp {
        consumeAiSwitchKeyUp = false
        return true
    }
}
```

**Step 5: Commit**

```bash
git add Sources/JackApp/GlobalFnShortcutMonitor.swift
git commit -m "feat: add AI switch key handling to GlobalFnShortcutMonitor"
```

---

### Task 4: Add `.aiChat` handling to bubble and status text

**Files:**
- Modify: `Sources/JackApp/DictationController.swift`
- Modify: `Sources/JackApp/FloatingBubbleController.swift`

**Step 1: Update `listeningBubbleMessage()`**

In `listeningBubbleMessage()` (~line 1219), add the new case:

```swift
case .aiChat:
    return "Listening (AI Mode)..."
```

**Step 2: Update `listeningStatusText(isLive:)`**

In `listeningStatusText(isLive:)` (~line 1230), add the new cases:

```swift
case (.aiChat, false):
    return "Listening... (AI mode)"
case (.aiChat, true):
    return "Listening... (AI mode, live)"
```

**Step 3: Update `showBubble` to pass `isAiMode`**

In the `showBubble` method (~line 2131), add the `isAiMode` parameter:

```swift
private func showBubble(message: String, isRecording: Bool, isTranscribing: Bool = false) {
    bubble.show(
        message: message,
        isRecording: isRecording,
        isTranscribing: isTranscribing,
        isNoteMode: recordingOutputMode == .voiceNote,
        isTodoMode: recordingOutputMode == .todo,
        isAiMode: recordingOutputMode == .aiChat,
        riveAssetPath: riveAssetPathIfEnabled(forRecordingState: isRecording),
        htmlIndicatorMarkup: (isRecording || isTranscribing) ? preferredCustomSVGMarkup() : nil,
        useBuiltInWaveIndicator: builtInWaveIndicatorEnabled
    )
}
```

Also update the transient bubble call that passes `isNoteMode: false` — add `isAiMode: false` after it.

**Step 4: Update `FloatingBubbleController.show()` signature**

In `FloatingBubbleController`, update the `show()` method (~line 299) to accept `isAiMode`:

```swift
func show(
    message _: String,
    isRecording: Bool,
    isTranscribing: Bool,
    isNoteMode: Bool = false,
    isTodoMode: Bool = false,
    isAiMode: Bool = false,
    riveAssetPath _: String?,
    htmlIndicatorMarkup _: String?,
    useBuiltInWaveIndicator _: Bool
) {
    currentIsRecording = isRecording
    currentIsTranscribing = isTranscribing
    currentIsNoteMode = isNoteMode
    currentIsTodoMode = isTodoMode
    currentIsAiMode = isAiMode
    // ... rest unchanged
}
```

Add stored property `currentIsAiMode`:

```swift
private var currentIsAiMode = false
```

Pass it to `pillView?.update()` calls.

**Step 5: Update `PillIndicatorView.update()` in FloatingBubbleController**

Update signature to accept `isAiMode`:

```swift
func update(isRecording: Bool, isTranscribing: Bool, isNoteMode: Bool, isTodoMode: Bool, isAiMode: Bool, level: Double, shouldPulse: Bool) {
```

Update the mode icon swap logic:

```swift
let newMode: Int = isAiMode ? 3 : (isTodoMode ? 2 : (isNoteMode ? 1 : 0))
if newMode != currentMode {
    currentMode = newMode
    if isAiMode {
        if let img = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "AI") {
            iconImageView.image = img
        }
        iconEmojiLabel.isHidden = true
        iconImageView.isHidden = false
    } else if isTodoMode {
        // ... existing code
```

**Step 6: Commit**

```bash
git add Sources/JackApp/DictationController.swift Sources/JackApp/FloatingBubbleController.swift
git commit -m "feat: add sparkle icon and status text for AI mode"
```

---

### Task 5: Add `openWithMessage` to `ChatSideSheetController`

**Files:**
- Modify: `Sources/JackApp/ChatSideSheetController.swift`

**Step 1: Add the `openWithMessage` method**

After `createNewThread()` (~line 254), add:

```swift
/// Opens the chat side sheet, creates a new thread with the given text, and streams the AI response.
func openWithMessage(_ text: String) {
    // Show the sheet if not already visible
    if !sheetState.isVisible {
        show()
    }

    Task {
        let defaultModel = UserDefaults.standard.string(forKey: "chat_last_used_model") ?? "anthropic/claude-sonnet-4"
        // Use first ~50 chars as thread title
        let titleEnd = text.index(text.startIndex, offsetBy: min(50, text.count))
        let title = String(text[text.startIndex..<titleEnd])

        guard let threadId = await chatController.createThread(
            title: title,
            model: defaultModel,
            spaceId: spaceController.currentSpaceId
        ) else { return }

        await chatController.fetchThreads(spaceId: spaceController.currentSpaceId)
        sheetState.selectedThreadId = threadId
        await chatController.fetchMessages(threadId: threadId)

        // Send the dictated text and stream the AI response
        await chatController.sendAndStream(threadId: threadId, content: text)
    }
}
```

**Step 2: Commit**

```bash
git add Sources/JackApp/ChatSideSheetController.swift
git commit -m "feat: add openWithMessage to ChatSideSheetController"
```

---

### Task 6: Add `.aiChat` case to `handleTranscriptionResult`

**Files:**
- Modify: `Sources/JackApp/DictationController.swift`

**Step 1: Add the `.aiChat` case**

In `handleTranscriptionResult` (~line 1613), after the `.todo` case, add:

```swift
case .aiChat:
    statusText = "Sending to AI..."
    ChatSideSheetController.shared.openWithMessage(cleaned)
    bubble.hide()
```

**Step 2: Build and verify**

Run: `swift build 2>&1 | tail -20`
Expected: Clean build (all `switch recordingOutputMode` sites should now be exhaustive).

**Step 3: Commit**

```bash
git add Sources/JackApp/DictationController.swift
git commit -m "feat: send dictation to AI chat on aiChat mode completion"
```

---

### Task 7: Add "AI Switch Key" UI in ContentView

**Files:**
- Modify: `Sources/JackApp/ContentView.swift`

**Step 1: Add the UI row**

After the Todo Switch Key section (~line 406, after the `Divider()`), add:

```swift
// AI Switch
HStack {
    Image(systemName: "sparkles")
        .foregroundStyle(.secondary)
        .frame(width: 20)
    Text("AI Switch Key")
        .font(.body.weight(.medium))

    Spacer()

    Button {
        if controller.isCapturingAiSwitchKey {
            controller.cancelAiSwitchKeyCapture()
        } else {
            controller.startAiSwitchKeyCapture()
        }
    } label: {
        HStack(spacing: 4) {
            Text(controller.isCapturingAiSwitchKey ? "Press a key…" : controller.aiSwitchKeyDisplayName)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
    .buttonStyle(.bordered)
    .disabled(controller.isCapturingInvocationKey)
}
.padding(.horizontal, 14)
.padding(.vertical, 10)
.background(
    RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(.black.opacity(0.15))
)

Text("While recording, press this key to switch output to AI Chat mode.")
    .font(.caption)
    .foregroundStyle(.secondary)

Divider()
```

**Step 2: Build and verify**

Run: `swift build 2>&1 | tail -10`
Expected: Clean build.

**Step 3: Commit**

```bash
git add Sources/JackApp/ContentView.swift
git commit -m "feat: add AI Switch Key setting in General tab"
```

---

### Task 8: Final build verification and cleanup

**Step 1: Full build**

Run: `swift build 2>&1 | tail -20`
Expected: Clean build with no errors (pre-existing Sendable warnings are OK).

**Step 2: Verify all switch statements are exhaustive**

Run: `grep -n "switch recordingOutputMode" Sources/JackApp/DictationController.swift`
Check each location has a `.aiChat` case.

**Step 3: Commit any remaining fixes if needed**

```bash
git add -A && git commit -m "fix: address remaining build issues for AI mode"
```
