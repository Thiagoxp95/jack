# Todo Side Sheet Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a keyboard-driven floating side sheet (NSPanel) that shows todos for the current space, invokable via a configurable global combo shortcut.

**Architecture:** NSPanel subclass wrapping SwiftUI via NSHostingView. New shortcut slot in GlobalFnShortcutMonitor (same pattern as screen recording). Panel pre-created, toggled visible/hidden for instant appearance. All keyboard interaction handled via NSPanel keyDown override.

**Tech Stack:** Swift, AppKit (NSPanel), SwiftUI, existing TodoListController + SpaceController

---

### Task 1: Add Todo Sheet Shortcut to GlobalFnShortcutMonitor

**Files:**
- Modify: `Sources/JackApp/GlobalFnShortcutMonitor.swift`

**Step 1: Add state properties after line 74**

After the screen recording shortcut properties, add the todo sheet shortcut:

```swift
// Multi-key todo sheet shortcut
var onTodoSheetKeyPressed: (() -> Void)?
private var todoSheetShortcut: InvocationShortcut?
private var isTodoSheetShortcutActive = false
```

**Step 2: Add setter method after `setScreenRecordingShortcut` (line 89)**

```swift
func setTodoSheetShortcut(_ shortcut: InvocationShortcut?) {
    todoSheetShortcut = shortcut
    isTodoSheetShortcutActive = false
}
```

**Step 3: Add modifier-based matching in `handleFlagsChanged` (after the screen recording block, ~line 237)**

Insert before the `// Invocation shortcut` comment at line 239:

```swift
// Todo sheet shortcut: modifier-based matching
if let tsShortcut = todoSheetShortcut {
    if tsShortcut != invocationShortcut {
        let tsResult = evaluateModifierShortcut(tsShortcut, keyCode: keyCode, isActive: isTodoSheetShortcutActive)
        if let tsResult {
            if tsResult, !isTodoSheetShortcutActive {
                isTodoSheetShortcutActive = true
                onTodoSheetKeyPressed?()
            } else if !tsResult {
                isTodoSheetShortcutActive = false
            }
            return true
        }
    }
}
```

**Step 4: Add key event matching in `handleKeyEvent` (after the screen recording block, ~line 355)**

Insert before the `// Voice note switch key` comment at line 357:

```swift
// Todo sheet shortcut (non-modifier key variant)
if let tsShortcut = todoSheetShortcut, tsShortcut != invocationShortcut {
    if matchesKeyEvent(tsShortcut, keyCode: keyCode, isKeyDown: isKeyDown) {
        if isKeyDown {
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if !isRepeat {
                onTodoSheetKeyPressed?()
            }
        }
        return true
    }
}
```

**Step 5: Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded

**Step 6: Commit**

```
feat: add todo sheet shortcut slot to GlobalFnShortcutMonitor
```

---

### Task 2: Add Todo Sheet Shortcut Persistence to DictationController

**Files:**
- Modify: `Sources/JackApp/DictationController.swift`

**Step 1: Add published property after `screenRecordingShortcut` (line 72)**

```swift
@Published private(set) var todoSheetShortcut: InvocationShortcut?
```

**Step 2: Add capturing flag after `isCapturingTodoSwitchKey` (line 77)**

```swift
@Published var isCapturingTodoSheetKey = false
```

**Step 3: Add DefaultsKey after `screenRecordingShortcutJSON` (line 334)**

```swift
static let todoSheetShortcutJSON = "todo_sheet_shortcut_json"
```

**Step 4: Add KeyCaptureTarget case after `todoSwitch` (line 364)**

```swift
case todoSheet
```

**Step 5: Load from UserDefaults in `init()` — after the screen recording shortcut loading block (~line 432)**

```swift
let initialTodoSheetShortcut: InvocationShortcut?
if let jsonData = defaults.data(forKey: DefaultsKey.todoSheetShortcutJSON),
   let decoded = try? JSONDecoder().decode(InvocationShortcut.self, from: jsonData) {
    initialTodoSheetShortcut = decoded
} else {
    initialTodoSheetShortcut = nil
}
```

Then after `screenRecordingShortcut = initialScreenRecordingShortcut` (~line 444), add:

```swift
todoSheetShortcut = initialTodoSheetShortcut
```

**Step 6: Wire the shortcut monitor in `setupShortcutMonitor()` — after `shortcutMonitor.onScreenRecordingKeyPressed` block (~line 539)**

```swift
if let initialTodoSheetShortcut {
    shortcutMonitor.setTodoSheetShortcut(initialTodoSheetShortcut)
}
shortcutMonitor.onTodoSheetKeyPressed = { [weak self] in
    Task { @MainActor [weak self] in
        self?.handleTodoSheetShortcut()
    }
}
```

**Step 7: Add display name computed property after `screenRecordingKeyDisplayName` (~line 609)**

```swift
var todoSheetKeyDisplayName: String {
    todoSheetShortcut?.displayName ?? "Not Set"
}
```

**Step 8: Add apply/clear methods after `clearScreenRecordingKey()` (~line 790)**

```swift
func applyTodoSheetShortcut(_ shortcut: InvocationShortcut) {
    setTodoSheetShortcut(shortcut)
    statusText = "Todo sheet shortcut set to \(todoSheetKeyDisplayName)."
}

func clearTodoSheetKey() {
    todoSheetShortcut = nil
    shortcutMonitor.setTodoSheetShortcut(nil)
    UserDefaults.standard.removeObject(forKey: DefaultsKey.todoSheetShortcutJSON)
}
```

**Step 9: Add persistence setter (near `setScreenRecordingShortcut`, ~line 2160)**

Find the `private func setScreenRecordingShortcut` method and add after it:

```swift
private func setTodoSheetShortcut(_ shortcut: InvocationShortcut) {
    todoSheetShortcut = shortcut
    shortcutMonitor.setTodoSheetShortcut(shortcut)
    if let data = try? JSONEncoder().encode(shortcut) {
        UserDefaults.standard.set(data, forKey: DefaultsKey.todoSheetShortcutJSON)
    }
}
```

**Step 10: Add handler method after `handleScreenRecordingShortcut()` (~line 999)**

```swift
private func handleTodoSheetShortcut() {
    guard !isCapturingInvocationKey, !isCapturingVoiceNoteSwitchKey, !isCapturingScreenRecordingKey, !isCapturingTodoSwitchKey, !isCapturingTodoSheetKey else {
        return
    }
    NotificationCenter.default.post(name: .toggleTodoSheet, object: nil)
}
```

**Step 11: Add capture methods after `cancelTodoSwitchKeyCapture()` (~line 784)**

```swift
func startTodoSheetKeyCapture() {
    guard !isCapturingInvocationKey, !isCapturingVoiceNoteSwitchKey, !isCapturingScreenRecordingKey, !isCapturingTodoSwitchKey, !isCapturingTodoSheetKey else {
        return
    }

    keyCaptureTarget = .todoSheet
    isCapturingTodoSheetKey = true
    statusText = "Press a key combination for the Todo Sheet shortcut."
    installInvocationKeyCaptureMonitors()
}

func cancelTodoSheetKeyCapture() {
    guard isCapturingTodoSheetKey else {
        return
    }

    isCapturingTodoSheetKey = false
    keyCaptureTarget = nil
    removeInvocationKeyCaptureMonitors()
    statusText = "Todo Sheet key capture canceled."
}
```

**Step 12: Add the Notification.Name extension**

Find where `.toggleScreenRecording` is defined and add nearby:

```swift
static let toggleTodoSheet = Notification.Name("toggleTodoSheet")
```

**Step 13: Handle the `.todoSheet` case in the key capture completion handler**

Find the switch on `keyCaptureTarget` that handles `.screenRecording` and add the `.todoSheet` case:

```swift
case .todoSheet:
    isCapturingTodoSheetKey = false
    keyCaptureTarget = nil
    removeInvocationKeyCaptureMonitors()
    setTodoSheetShortcut(captured)
    statusText = "Todo sheet shortcut set to \(todoSheetKeyDisplayName)."
```

**Step 14: Update all guard clauses that check `isCapturing*` flags**

In `startInvocationKeyCapture`, `startVoiceNoteSwitchKeyCapture`, `startScreenRecordingKeyCapture`, and `startTodoSwitchKeyCapture` — add `!isCapturingTodoSheetKey` to each guard.

**Step 15: Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded

**Step 16: Commit**

```
feat: add todo sheet shortcut persistence to DictationController
```

---

### Task 3: Create TodoSideSheetController (NSPanel management)

**Files:**
- Create: `Sources/JackApp/TodoSideSheetController.swift`

This is the core controller that manages the NSPanel lifecycle and keyboard routing.

**Step 1: Create the file**

```swift
import AppKit
import SwiftUI

// MARK: - TodoSheetKeyboardDelegate

protocol TodoSheetKeyboardDelegate: AnyObject {
    func todoSheetDidPressEscape()
    func todoSheetDidPressArrow(direction: TodoSideSheetController.ArrowDirection)
    func todoSheetDidPressEnter()
    func todoSheetDidPressDelete()
    func todoSheetDidPressTab(shiftHeld: Bool)
    func todoSheetDidPressN()
    func todoSheetDidPressE()
    func todoSheetDidPressP()
}

// MARK: - KeyInterceptingPanel

private final class KeyInterceptingPanel: NSPanel {
    weak var keyboardDelegate: TodoSheetKeyboardDelegate?
    /// When true, regular key presses (N, E, P) are NOT intercepted (user is typing).
    var isTextInputActive = false

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        let keyCode = event.keyCode
        let isRepeat = event.isARepeat
        let shiftHeld = event.modifierFlags.contains(.shift)

        // Always handle these regardless of text input state
        switch keyCode {
        case 53: // Escape
            if !isRepeat { keyboardDelegate?.todoSheetDidPressEscape() }
            return
        default:
            break
        }

        // Block navigation/action keys during text input
        guard !isTextInputActive else {
            super.keyDown(with: event)
            return
        }

        switch keyCode {
        case 126: // Up arrow
            if !isRepeat { keyboardDelegate?.todoSheetDidPressArrow(direction: .up) }
        case 125: // Down arrow
            if !isRepeat { keyboardDelegate?.todoSheetDidPressArrow(direction: .down) }
        case 36, 49: // Enter (36), Space (49)
            if !isRepeat { keyboardDelegate?.todoSheetDidPressEnter() }
        case 51, 117: // Backspace (51), Forward Delete (117)
            if !isRepeat { keyboardDelegate?.todoSheetDidPressDelete() }
        case 48: // Tab
            if !isRepeat { keyboardDelegate?.todoSheetDidPressTab(shiftHeld: shiftHeld) }
        case 45: // N
            if !isRepeat { keyboardDelegate?.todoSheetDidPressN() }
        case 14: // E
            if !isRepeat { keyboardDelegate?.todoSheetDidPressE() }
        case 35: // P
            if !isRepeat { keyboardDelegate?.todoSheetDidPressP() }
        default:
            super.keyDown(with: event)
        }
    }
}

// MARK: - TodoSideSheetState

@MainActor @Observable
final class TodoSideSheetState {
    var isVisible = false
    var selectedIndex = 0
    var isCreating = false
    var isEditing = false
    var editText = ""

    func reset() {
        selectedIndex = 0
        isCreating = false
        isEditing = false
        editText = ""
    }
}

// MARK: - TodoSideSheetController

@MainActor
final class TodoSideSheetController: TodoSheetKeyboardDelegate {

    enum ArrowDirection { case up, down }

    private var panel: KeyInterceptingPanel?
    let sheetState = TodoSideSheetState()
    var todoListController: TodoListController?
    var spaceController: SpaceController?
    var onSpaceCycled: (() -> Void)?

    private static let sheetWidth: CGFloat = 320

    // MARK: - Toggle

    func toggle() {
        if sheetState.isVisible {
            hide()
        } else {
            show()
        }
    }

    // MARK: - Show

    func show() {
        guard !sheetState.isVisible else { return }

        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let sheetHeight = screenFrame.height
        let size = NSSize(width: Self.sheetWidth, height: sheetHeight)

        if panel == nil {
            let p = KeyInterceptingPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.isReleasedWhenClosed = false
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.hidesOnDeactivate = false
            p.isFloatingPanel = true
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.keyboardDelegate = self
            panel = p
        }

        guard let panel else { return }

        sheetState.reset()
        sheetState.isVisible = true

        let sheetView = TodoSideSheetView(
            sheetState: sheetState,
            todoListController: todoListController!,
            spaceController: spaceController!
        )
        .frame(width: size.width, height: size.height)

        let hostingView = NSHostingView(rootView: sheetView)
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hostingView
        panel.setContentSize(size)

        // Start off-screen right
        let finalX = screenFrame.maxX - Self.sheetWidth
        let finalY = screenFrame.minY
        let startX = screenFrame.maxX

        panel.setFrameOrigin(NSPoint(x: startX, y: finalY))
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.makeKey()

        // Slide in
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrameOrigin(NSPoint(x: finalX, y: finalY))
        }

        // Fetch todos
        Task {
            await todoListController?.fetchTodos(spaceId: spaceController?.currentSpaceId)
        }
    }

    // MARK: - Hide

    func hide() {
        guard let panel, sheetState.isVisible else { return }
        sheetState.isVisible = false

        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let targetX = screenFrame.maxX

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrameOrigin(NSPoint(x: targetX, y: panel.frame.origin.y))
        }, completionHandler: {
            Task { @MainActor [weak self] in
                self?.panel?.orderOut(nil)
            }
        })
    }

    // MARK: - TodoSheetKeyboardDelegate

    func todoSheetDidPressEscape() {
        if sheetState.isCreating || sheetState.isEditing {
            sheetState.isCreating = false
            sheetState.isEditing = false
            sheetState.editText = ""
            panel?.isTextInputActive = false
        } else {
            hide()
        }
    }

    func todoSheetDidPressArrow(direction: ArrowDirection) {
        guard let todos = todoListController?.todos, !todos.isEmpty else { return }
        switch direction {
        case .up:
            sheetState.selectedIndex = max(0, sheetState.selectedIndex - 1)
        case .down:
            sheetState.selectedIndex = min(todos.count - 1, sheetState.selectedIndex + 1)
        }
    }

    func todoSheetDidPressEnter() {
        guard let todos = todoListController?.todos,
              sheetState.selectedIndex < todos.count else { return }

        let todo = todos[sheetState.selectedIndex]
        let newStatus = todo.status == "done" ? "todo" : "done"

        Task {
            await todoListController?.updateTodo(todoId: todo.id, fields: ["status": newStatus])
            await todoListController?.fetchTodos(spaceId: spaceController?.currentSpaceId)
        }
    }

    func todoSheetDidPressDelete() {
        guard let todos = todoListController?.todos,
              sheetState.selectedIndex < todos.count else { return }

        let todo = todos[sheetState.selectedIndex]

        Task {
            await todoListController?.deleteTodo(todoId: todo.id)
            if sheetState.selectedIndex >= (todoListController?.todos.count ?? 0) {
                sheetState.selectedIndex = max(0, (todoListController?.todos.count ?? 1) - 1)
            }
        }
    }

    func todoSheetDidPressTab(shiftHeld: Bool) {
        guard let sc = spaceController else { return }
        let spaces = sc.availableSpaces
        guard spaces.count > 1 else { return }

        guard let currentIndex = spaces.firstIndex(where: { $0.id == sc.activeSpace.id }) else { return }

        let nextIndex: Int
        if shiftHeld {
            nextIndex = currentIndex == 0 ? spaces.count - 1 : currentIndex - 1
        } else {
            nextIndex = (currentIndex + 1) % spaces.count
        }

        sc.switchSpace(to: spaces[nextIndex])
        sheetState.selectedIndex = 0
        onSpaceCycled?()

        Task {
            await todoListController?.fetchTodos(spaceId: sc.currentSpaceId)
        }
    }

    func todoSheetDidPressN() {
        sheetState.isCreating = true
        sheetState.isEditing = false
        sheetState.editText = ""
        panel?.isTextInputActive = true
    }

    func todoSheetDidPressE() {
        guard let todos = todoListController?.todos,
              sheetState.selectedIndex < todos.count else { return }

        sheetState.isEditing = true
        sheetState.isCreating = false
        sheetState.editText = todos[sheetState.selectedIndex].title
        panel?.isTextInputActive = true
    }

    func todoSheetDidPressP() {
        guard let todos = todoListController?.todos,
              sheetState.selectedIndex < todos.count else { return }

        let todo = todos[sheetState.selectedIndex]
        let priorities = ["none", "low", "medium", "high"]
        let currentIdx = priorities.firstIndex(of: todo.priority) ?? 0
        let nextPriority = priorities[(currentIdx + 1) % priorities.count]

        Task {
            await todoListController?.updateTodo(todoId: todo.id, fields: ["priority": nextPriority])
            await todoListController?.fetchTodos(spaceId: spaceController?.currentSpaceId)
        }
    }

    /// Called when the SwiftUI view submits a new todo or finishes editing.
    func commitTextInput() {
        let text = sheetState.editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            sheetState.isCreating = false
            sheetState.isEditing = false
            sheetState.editText = ""
            panel?.isTextInputActive = false
            return
        }

        if sheetState.isCreating {
            Task {
                await todoListController?.createTodo(title: text, spaceId: spaceController?.currentSpaceId)
                await todoListController?.fetchTodos(spaceId: spaceController?.currentSpaceId)
            }
        } else if sheetState.isEditing, let todos = todoListController?.todos, sheetState.selectedIndex < todos.count {
            let todo = todos[sheetState.selectedIndex]
            Task {
                await todoListController?.updateTodo(todoId: todo.id, fields: ["title": text])
                await todoListController?.fetchTodos(spaceId: spaceController?.currentSpaceId)
            }
        }

        sheetState.isCreating = false
        sheetState.isEditing = false
        sheetState.editText = ""
        panel?.isTextInputActive = false
    }
}
```

**Step 2: Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded (view file doesn't exist yet, but controller compiles alone since TodoSideSheetView is referenced only via type)

Actually — TodoSideSheetView is referenced in show(). We need to create a stub first or create both files together. Create both in Task 3 and 4 as a single commit.

---

### Task 4: Create TodoSideSheetView (SwiftUI)

**Files:**
- Create: `Sources/JackApp/TodoSideSheetView.swift`

**Step 1: Create the file**

```swift
import SwiftUI

struct TodoSideSheetView: View {
    @Bindable var sheetState: TodoSideSheetState
    @Bindable var todoListController: TodoListController
    var spaceController: SpaceController

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider().opacity(0.3)

            if sheetState.isCreating {
                createInputView
                Divider().opacity(0.3)
            }

            todoListView

            Divider().opacity(0.3)
            keyboardHintsView
        }
        .background(
            RoundedRectangle(cornerRadius: 0)
                .fill(.ultraThinMaterial)
        )
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 8) {
            spaceIconView(spaceController.activeSpaceIcon, size: 14)
                .foregroundStyle(spaceController.activeSpaceColor.color)

            Text(spaceController.activeSpace.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)

            Spacer()

            if spaceController.availableSpaces.count > 1 {
                Text("← Tab →")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Create Input

    private var createInputView: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            TextField("New todo...", text: $sheetState.editText, onCommit: {
                NotificationCenter.default.post(name: .todoSheetCommitInput, object: nil)
            })
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .onExitCommand {
                sheetState.isCreating = false
                sheetState.editText = ""
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.05))
    }

    // MARK: - Todo List

    private var todoListView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if todoListController.isLoading && todoListController.todos.isEmpty {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    } else if todoListController.todos.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "checklist")
                                .font(.system(size: 24))
                                .foregroundStyle(.tertiary)
                            Text("No todos")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text("Press N to create one")
                                .font(.caption2)
                                .foregroundStyle(.quaternary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    } else {
                        ForEach(Array(todoListController.todos.enumerated()), id: \.element.id) { index, todo in
                            todoRow(todo: todo, index: index)
                                .id(todo.id)
                        }
                    }
                }
            }
            .onChange(of: sheetState.selectedIndex) { _, newIndex in
                if let todos = Optional(todoListController.todos), newIndex < todos.count {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(todos[newIndex].id, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - Todo Row

    private func todoRow(todo: ConvexTodo, index: Int) -> some View {
        let isSelected = index == sheetState.selectedIndex
        let isDone = todo.status == "done"

        return HStack(spacing: 10) {
            // Status indicator
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isDone ? .green : .secondary)

            // Title (or edit field)
            if sheetState.isEditing && isSelected {
                TextField("Edit todo...", text: $sheetState.editText, onCommit: {
                    NotificationCenter.default.post(name: .todoSheetCommitInput, object: nil)
                })
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onExitCommand {
                    sheetState.isEditing = false
                    sheetState.editText = ""
                }
            } else {
                Text(todo.title)
                    .font(.system(size: 13))
                    .strikethrough(isDone)
                    .foregroundStyle(isDone ? .secondary : .primary)
                    .lineLimit(2)
            }

            Spacer()

            // Due date indicator
            if let dueDate = todo.dueDate {
                Text(formatShortDate(dueDate))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            // Priority dot
            priorityDot(todo.priority)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? spaceController.activeSpaceColor.color.opacity(0.15) : .clear)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
    }

    // MARK: - Priority Dot

    private func priorityDot(_ priority: String) -> some View {
        Circle()
            .fill(priorityColor(priority))
            .frame(width: 6, height: 6)
    }

    private func priorityColor(_ priority: String) -> Color {
        switch priority {
        case "high": return .red
        case "medium": return .orange
        case "low": return .blue
        default: return .gray.opacity(0.4)
        }
    }

    // MARK: - Keyboard Hints

    private var keyboardHintsView: some View {
        VStack(spacing: 2) {
            HStack(spacing: 12) {
                hintPill("↑↓", "Navigate")
                hintPill("⏎", "Done")
                hintPill("⌫", "Delete")
            }
            HStack(spacing: 12) {
                hintPill("N", "New")
                hintPill("E", "Edit")
                hintPill("P", "Priority")
            }
            HStack(spacing: 12) {
                hintPill("Tab", "Space")
                hintPill("Esc", "Close")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func hintPill(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(.white.opacity(0.1))
                )
            Text(label)
                .font(.system(size: 9))
        }
        .foregroundStyle(.tertiary)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func spaceIconView(_ icon: SpaceIcon, size: CGFloat) -> some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size))
        case .emoji(let char):
            Text(char)
                .font(.system(size: size))
        }
    }

    private func formatShortDate(_ dateString: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dateString) else { return dateString }

        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInTomorrow(date) {
            return "Tmrw"
        } else {
            let display = DateFormatter()
            display.dateFormat = "MMM d"
            return display.string(from: date)
        }
    }
}

extension Notification.Name {
    static let todoSheetCommitInput = Notification.Name("todoSheetCommitInput")
}
```

**Step 2: Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded

**Step 3: Commit**

```
feat: add TodoSideSheetController and TodoSideSheetView
```

---

### Task 5: Wire Todo Sheet into AuthenticatedRootView

**Files:**
- Modify: `Sources/JackApp/Auth/Views/AuthGateView.swift`

**Step 1: Add the controller state in `AuthenticatedRootView` (after line 217)**

```swift
@State private var todoSheetController = TodoSideSheetController()
```

**Step 2: Wire controllers in the `.task` block (~line 238)**

After `controller.spaceController = spaceController` add:

```swift
todoSheetController.todoListController = TodoListController()
todoSheetController.spaceController = spaceController
```

**Step 3: Add notification receiver for `.toggleTodoSheet` (after the `.toggleScreenRecording` handler, ~line 259)**

```swift
.onReceive(NotificationCenter.default.publisher(for: .toggleTodoSheet)) { _ in
    todoSheetController.toggle()
}
.onReceive(NotificationCenter.default.publisher(for: .todoSheetCommitInput)) { _ in
    todoSheetController.commitTextInput()
}
```

**Step 4: Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded

**Step 5: Commit**

```
feat: wire TodoSideSheetController into app lifecycle
```

---

### Task 6: Add Todo Sheet Shortcut UI to ContentView

**Files:**
- Modify: `Sources/JackApp/ContentView.swift`

**Step 1: Add sheet state (after `showScreenRecordingCapture`, ~line 19)**

```swift
@State private var showTodoSheetCapture = false
```

**Step 2: Add the shortcut row in the Recording Controls section (after the Quick Screen Recording block, ~line 425)**

After the screen recording description text and before the closing `}` of the Recording Controls card:

```swift
Divider()

// Todo Side Sheet
HStack {
    Image(systemName: "sidebar.right")
        .foregroundStyle(.secondary)
        .frame(width: 20)
    Text("Todo Side Sheet")
        .font(.body.weight(.medium))

    Spacer()

    if controller.todoSheetShortcut != nil {
        Button {
            controller.clearTodoSheetKey()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Remove shortcut")
    }

    Button {
        showTodoSheetCapture = true
    } label: {
        Text(controller.todoSheetKeyDisplayName)
            .font(.body.weight(.medium))
    }
    .buttonStyle(.bordered)
}
.padding(.horizontal, 14)
.padding(.vertical, 10)
.background(
    RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(.black.opacity(0.15))
)

Text("Press to open/close the Todo side sheet overlay.")
    .font(.caption)
    .foregroundStyle(.secondary)
```

**Step 3: Add the sheet modifier (after `showScreenRecordingCapture` sheet, ~line 180)**

```swift
.sheet(isPresented: $showTodoSheetCapture) {
    ShortcutCaptureView(
        title: "Record Todo Sheet Shortcut",
        onSave: { shortcut in
            controller.applyTodoSheetShortcut(shortcut)
            showTodoSheetCapture = false
        },
        onCancel: {
            showTodoSheetCapture = false
        }
    )
}
```

**Step 4: Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded

**Step 5: Commit**

```
feat: add Todo Sheet shortcut capture UI to settings
```

---

### Task 7: Final Integration Test & Polish

**Step 1: Build the full app**

Run: `swift build 2>&1 | tail -10`
Expected: Build succeeded

**Step 2: Verify Notification.Name definitions don't conflict**

Search for duplicate `.toggleTodoSheet` definitions. Should only appear once.

**Step 3: Commit the full feature**

```
feat: complete todo side sheet feature with keyboard controls
```
