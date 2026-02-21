import AppKit
import SwiftUI

// MARK: - SetupWindowController

@MainActor
final class SetupWindowController {

    private var panel: NSPanel?

    // MARK: - Show

    func show(controller: RecordingSessionController) {
        if panel != nil { return }

        let size = NSSize(width: 480, height: 520)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.title = "Recording Setup"

        let setupView = RecordingSetupView(controller: controller) { [weak self] in
            self?.hide()
        }
        panel.contentView = NSHostingView(rootView: setupView)

        panel.center()
        panel.makeKeyAndOrderFront(nil)

        self.panel = panel
    }

    // MARK: - Hide

    func hide() {
        panel?.close()
        panel = nil
    }
}
