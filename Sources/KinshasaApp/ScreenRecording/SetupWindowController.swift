import AppKit
import SwiftUI

// MARK: - SetupWindowController

@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {

    private var panel: NSPanel?
    private weak var recordingController: RecordingSessionController?

    // MARK: - Show

    func show(controller: RecordingSessionController) {
        // If already visible, just bring to front
        if let existing = panel {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        self.recordingController = controller

        let size = NSSize(width: 420, height: 580)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .windowBackgroundColor
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.title = ""
        panel.delegate = self

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
        guard let p = panel else { return }
        panel = nil
        p.delegate = nil
        p.contentView = nil
        p.close()
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.recordingController?.cancelSetup()
            self?.panel = nil
        }
    }
}
