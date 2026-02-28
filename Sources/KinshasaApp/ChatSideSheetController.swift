import AppKit
import SwiftUI

// MARK: - ChatSheetKeyboardDelegate

@MainActor protocol ChatSheetKeyboardDelegate: AnyObject {
    func chatSheetDidPressEscape()
    func chatSheetDidPressCommandN()
    func chatSheetDidPressCommandDelete()
}

// MARK: - ChatKeyInterceptingPanel

private final class ChatKeyInterceptingPanel: NSPanel {
    weak var keyboardDelegate: ChatSheetKeyboardDelegate?

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        let keyCode = event.keyCode
        let isRepeat = event.isARepeat
        let hasCommand = event.modifierFlags.contains(.command)

        // Escape always handled
        if keyCode == 53 {
            if !isRepeat { keyboardDelegate?.chatSheetDidPressEscape() }
            return
        }

        // Cmd+N: new thread
        if hasCommand && keyCode == 45 {
            if !isRepeat { keyboardDelegate?.chatSheetDidPressCommandN() }
            return
        }

        // Cmd+Delete / Cmd+Forward Delete: delete thread
        if hasCommand && (keyCode == 51 || keyCode == 117) {
            if !isRepeat { keyboardDelegate?.chatSheetDidPressCommandDelete() }
            return
        }

        // Everything else passes through to SwiftUI for text input
        super.keyDown(with: event)
    }
}

// MARK: - ChatSideSheetState

@MainActor @Observable
final class ChatSideSheetState {
    var isVisible = false
    var selectedThreadId: String?
    var isCreatingThread = false
    var newThreadTitle = ""
    var inputText = ""
    var isConfirmingDelete = false

    func reset() {
        selectedThreadId = nil
        isCreatingThread = false
        newThreadTitle = ""
        inputText = ""
        isConfirmingDelete = false
    }
}

// MARK: - ChatSideSheetController

@MainActor
final class ChatSideSheetController: ChatSheetKeyboardDelegate {

    static let shared = ChatSideSheetController()

    private var panel: ChatKeyInterceptingPanel?
    let sheetState = ChatSideSheetState()
    var chatController: ChatController = .shared
    var spaceController: SpaceController = SpaceController()

    // Width constants
    private static let defaultWidth: CGFloat = 550
    private static let minWidth: CGFloat = 400
    private static let maxWidth: CGFloat = 800

    // Persisted width
    private var currentWidth: CGFloat {
        get {
            let stored = UserDefaults.standard.double(forKey: "chat_sheet_width")
            return stored > 0 ? stored : Self.defaultWidth
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "chat_sheet_width")
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
            let p = ChatKeyInterceptingPanel(
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

        let sheetView = ChatSideSheetView(
            sheetState: sheetState,
            chatController: chatController,
            spaceController: spaceController,
            onResize: { [weak self] newWidth in
                guard let self else { return }
                let clamped = min(Self.maxWidth, max(Self.minWidth, newWidth))
                self.currentWidth = clamped
                self.updatePanelFrame()
            }
        )
        .frame(width: size.width, height: size.height)

        let hostingView = NSHostingView(rootView: sheetView)
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hostingView
        panel.setContentSize(size)

        let finalX = screenFrame.maxX - width
        let finalY = screenFrame.minY

        // Position at final location immediately so the panel is never stuck off-screen
        panel.setFrameOrigin(NSPoint(x: finalX, y: finalY))
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.makeKey()

        // Fetch threads and models
        Task {
            await chatController.fetchThreads(spaceId: spaceController.currentSpaceId)
            await chatController.fetchModels()

            // Auto-select first thread if none selected
            if sheetState.selectedThreadId == nil, let firstThread = chatController.threads.first {
                sheetState.selectedThreadId = firstThread.id
                await chatController.fetchMessages(threadId: firstThread.id)
            }
        }
    }

    // MARK: - Hide

    func hide() {
        guard let panel, sheetState.isVisible else { return }
        chatController.cancelStream()
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
        let size = NSSize(width: width, height: sheetHeight)

        let finalX = screenFrame.maxX - width
        let finalY = screenFrame.minY

        panel.setFrame(NSRect(origin: NSPoint(x: finalX, y: finalY), size: size), display: true)

        if let hostingView = panel.contentView as? NSHostingView<AnyView> {
            hostingView.frame = NSRect(origin: .zero, size: size)
        }
    }

    // MARK: - ChatSheetKeyboardDelegate

    func chatSheetDidPressEscape() {
        if sheetState.isCreatingThread {
            sheetState.isCreatingThread = false
            sheetState.newThreadTitle = ""
        } else if sheetState.isConfirmingDelete {
            sheetState.isConfirmingDelete = false
        } else {
            hide()
        }
    }

    func chatSheetDidPressCommandN() {
        sheetState.isCreatingThread = true
        sheetState.newThreadTitle = ""
    }

    func chatSheetDidPressCommandDelete() {
        guard sheetState.selectedThreadId != nil else { return }
        sheetState.isConfirmingDelete = true
    }
}
