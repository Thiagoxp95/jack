import AppKit
import SwiftUI

/// Data model for a newly created todo, passed from processAndCreate response.
struct CreatedTodoInfo: Sendable {
    let id: String
    let title: String
    let description: String?
    let dueDate: String?
    let dueTime: String?
    let priority: String
    let tags: [String]?
    let reminderCount: Int
    let listName: String?
}

/// Edits made in the floating todo editor.
struct TodoEditUpdates: Sendable {
    let title: String
    let priority: String
    let dueDate: String?
    let dueTime: String?
    let tags: [String]?
}

@MainActor
final class TodoConfirmationController {
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    private var isEditing = false
    private let bottomOffset: CGFloat = 48
    private let cardWidth: CGFloat = 320

    // Callback for when user saves an edit — caller wires this to Convex mutation.
    var onSave: ((CreatedTodoInfo, TodoEditUpdates) async -> Void)?

    func show(todo: CreatedTodoInfo) {
        dismissTask?.cancel()
        isEditing = false

        let panel = ensurePanel()
        let hostingView = NSHostingView(
            rootView: TodoConfirmationView(
                todo: todo,
                onOK: { [weak self] in self?.hide() },
                onEdit: { [weak self] in self?.enterEditMode(todo: todo) }
            )
        )
        panel.contentView = hostingView

        // Let SwiftUI determine the intrinsic height
        let fittingSize = hostingView.fittingSize
        let size = NSSize(width: cardWidth, height: fittingSize.height)
        resize(panel, size: size)
        positionPanel(panel, size: size)

        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            panel.animator().alphaValue = 1
        }

        startAutoDismiss()
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        dismissTask?.cancel()

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.panel?.orderOut(nil)
                self?.panel?.alphaValue = 1
            }
        })
    }

    // MARK: - Private

    private func enterEditMode(todo: CreatedTodoInfo) {
        isEditing = true
        dismissTask?.cancel()

        guard let panel else { return }
        let hostingView = NSHostingView(
            rootView: TodoEditView(
                todo: todo,
                onCancel: { [weak self] in self?.hide() },
                onSave: { [weak self] updates in
                    guard let self else { return }
                    await self.onSave?(todo, updates)
                    self.hide()
                }
            )
        )
        panel.contentView = hostingView

        let fittingSize = hostingView.fittingSize
        let size = NSSize(width: cardWidth, height: fittingSize.height)
        resize(panel, size: size)
        positionPanel(panel, size: size)
    }

    private func startAutoDismiss() {
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.hide() }
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: cardWidth, height: 200)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = false

        self.panel = panel
        return panel
    }

    private func resize(_ panel: NSPanel, size: NSSize) {
        let frame = NSRect(origin: panel.frame.origin, size: size)
        panel.setFrame(frame, display: true)
    }

    private func positionPanel(_ panel: NSPanel, size: NSSize) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visibleFrame = screen.visibleFrame
        let x = round(visibleFrame.midX - size.width / 2)
        let y = round(visibleFrame.origin.y + bottomOffset)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
