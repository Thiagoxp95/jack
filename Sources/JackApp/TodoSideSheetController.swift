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
        case 126: // Up arrow (allow repeats for fast navigation)
            keyboardDelegate?.todoSheetDidPressArrow(direction: .up)
        case 125: // Down arrow (allow repeats for fast navigation)
            keyboardDelegate?.todoSheetDidPressArrow(direction: .down)
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

    static let shared = TodoSideSheetController()

    enum ArrowDirection { case up, down }

    private var panel: KeyInterceptingPanel?
    let sheetState = TodoSideSheetState()
    var todoListController: TodoListController = .shared
    var spaceController: SpaceController = SpaceController()

    // Width constants
    private static let defaultWidth: CGFloat = 320
    private static let minWidth: CGFloat = 260
    private static let maxWidth: CGFloat = 600

    // Persisted width
    private var currentWidth: CGFloat {
        get {
            let stored = UserDefaults.standard.double(forKey: "todo_sheet_width")
            return stored > 0 ? stored : Self.defaultWidth
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "todo_sheet_width")
        }
    }

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

        // Use the screen containing the mouse cursor (most intuitive for the user).
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let sheetHeight = screenFrame.height
        let width = currentWidth
        let size = NSSize(width: width, height: sheetHeight)

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
            todoListController: todoListController,
            spaceController: spaceController,
            onResize: { [weak self] newWidth in
                guard let self else { return }
                let clamped = min(Self.maxWidth, max(Self.minWidth, newWidth))
                self.currentWidth = clamped
                self.updatePanelFrame()
            }
        )

        let hostingView = NSHostingView(rootView: sheetView)
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        panel.setContentSize(size)

        let finalX = screenFrame.maxX - width
        let finalY = screenFrame.minY

        // Position at final location immediately so the panel is never stuck off-screen
        panel.setFrameOrigin(NSPoint(x: finalX, y: finalY))
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.makeKey()

        // Fetch todos
        Task {
            await todoListController.fetchTodos(spaceId: spaceController.currentSpaceId)
        }
    }

    // MARK: - Hide

    func hide() {
        guard let panel, sheetState.isVisible else { return }
        sheetState.isVisible = false
        panel.contentView = nil
        panel.orderOut(nil)
    }

    // MARK: - Panel Frame Update

    private func updatePanelFrame() {
        guard let panel, sheetState.isVisible else { return }

        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = currentWidth
        let sheetHeight = screenFrame.height

        let finalX = screenFrame.maxX - width
        let finalY = screenFrame.minY

        panel.setFrame(NSRect(x: finalX, y: finalY, width: width, height: sheetHeight), display: true)
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
        let todos = todoListController.todos
        guard !todos.isEmpty else { return }
        switch direction {
        case .up:
            sheetState.selectedIndex = max(0, sheetState.selectedIndex - 1)
        case .down:
            sheetState.selectedIndex = min(todos.count - 1, sheetState.selectedIndex + 1)
        }
    }

    func todoSheetDidPressEnter() {
        let todos = todoListController.todos
        guard sheetState.selectedIndex < todos.count else { return }

        let todo = todos[sheetState.selectedIndex]
        let newStatus = todo.status == "done" ? "todo" : "done"

        Task {
            await todoListController.updateTodo(todoId: todo.id, fields: ["status": newStatus])
            await todoListController.fetchTodos(spaceId: spaceController.currentSpaceId)
        }
    }

    func todoSheetDidPressDelete() {
        let todos = todoListController.todos
        guard sheetState.selectedIndex < todos.count else { return }

        let todo = todos[sheetState.selectedIndex]

        Task {
            await todoListController.deleteTodo(todoId: todo.id)
            await todoListController.fetchTodos(spaceId: spaceController.currentSpaceId)
            let count = todoListController.todos.count
            if sheetState.selectedIndex >= count {
                sheetState.selectedIndex = max(0, count - 1)
            }
        }
    }

    func todoSheetDidPressTab(shiftHeld: Bool) {
        let sc = spaceController
        let spaces = sc.availableSpaces
        guard spaces.count > 1 else { return }

        guard let currentIndex = spaces.firstIndex(where: { $0.id == sc.activeSpace.id }) else { return }

        let nextIndex: Int
        if shiftHeld {
            nextIndex = currentIndex == 0 ? spaces.count - 1 : currentIndex - 1
        } else {
            nextIndex = (currentIndex + 1) % spaces.count
        }

        let nextSpace = spaces[nextIndex]
        sc.switchSpace(to: nextSpace)
        sheetState.selectedIndex = 0

        // Use the target space ID directly to avoid any timing issues
        let nextSpaceId = nextSpace.isPersonal ? nil : nextSpace.id
        Task {
            await todoListController.fetchTodos(spaceId: nextSpaceId)
        }
    }

    func todoSheetDidPressN() {
        sheetState.isCreating = true
        sheetState.isEditing = false
        sheetState.editText = ""
        panel?.isTextInputActive = true
    }

    func todoSheetDidPressE() {
        let todos = todoListController.todos
        guard sheetState.selectedIndex < todos.count else { return }

        sheetState.isEditing = true
        sheetState.isCreating = false
        sheetState.editText = todos[sheetState.selectedIndex].title
        panel?.isTextInputActive = true
    }

    func todoSheetDidPressP() {
        let todos = todoListController.todos
        guard sheetState.selectedIndex < todos.count else { return }

        let todo = todos[sheetState.selectedIndex]
        let priorities = ["none", "low", "medium", "high"]
        let currentIdx = priorities.firstIndex(of: todo.priority) ?? 0
        let nextPriority = priorities[(currentIdx + 1) % priorities.count]

        Task {
            await todoListController.updateTodo(todoId: todo.id, fields: ["priority": nextPriority])
            await todoListController.fetchTodos(spaceId: spaceController.currentSpaceId)
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
                await todoListController.createTodo(title: text, spaceId: spaceController.currentSpaceId)
                await todoListController.fetchTodos(spaceId: spaceController.currentSpaceId)
            }
        } else if sheetState.isEditing, sheetState.selectedIndex < todoListController.todos.count {
            let todo = todoListController.todos[sheetState.selectedIndex]
            Task {
                await todoListController.updateTodo(todoId: todo.id, fields: ["title": text])
                await todoListController.fetchTodos(spaceId: spaceController.currentSpaceId)
            }
        }

        sheetState.isCreating = false
        sheetState.isEditing = false
        sheetState.editText = ""
        panel?.isTextInputActive = false
    }
}
