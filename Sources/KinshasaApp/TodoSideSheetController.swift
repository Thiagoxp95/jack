import AppKit
import SwiftUI

// MARK: - TodoSheetKeyboardDelegate

@MainActor protocol TodoSheetKeyboardDelegate: AnyObject {
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
    var isTextInputActive = false

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        let keyCode = event.keyCode
        let isRepeat = event.isARepeat
        let shiftHeld = event.modifierFlags.contains(.shift)

        // Escape always handled
        if keyCode == 53 {
            if !isRepeat { keyboardDelegate?.todoSheetDidPressEscape() }
            return
        }

        // During text input, pass through to SwiftUI
        guard !isTextInputActive else {
            super.keyDown(with: event)
            return
        }

        switch keyCode {
        case 126: // Up arrow
            if !isRepeat { keyboardDelegate?.todoSheetDidPressArrow(direction: .up) }
        case 125: // Down arrow
            if !isRepeat { keyboardDelegate?.todoSheetDidPressArrow(direction: .down) }
        case 36, 49: // Enter, Space
            if !isRepeat { keyboardDelegate?.todoSheetDidPressEnter() }
        case 51, 117: // Backspace, Forward Delete
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
