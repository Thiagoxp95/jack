import AppKit
import SwiftUI

// MARK: - EditorWindowController

@MainActor
final class EditorWindowController {

    private var window: NSWindow?
    private var editorController: VideoEditorController?

    // MARK: - Show

    func show(
        session: RecordingSession,
        initialZoomKeyframes: [ZoomKeyframe] = [],
        spaceController: SpaceController?,
        onSave: @escaping @MainActor (VideoEditorController, String) -> Void,
        onDiscard: @escaping @MainActor () -> Void
    ) {
        if window != nil { return }

        let editor = VideoEditorController(session: session)
        editor.zoomKeyframes = initialZoomKeyframes
        self.editorController = editor

        let editorView = VideoEditorView(
            editor: editor,
            spaceController: spaceController,
            onSave: { [weak self] title in
                guard let self, let editor = self.editorController else { return }
                self.hide()
                onSave(editor, title)
            },
            onDiscard: { [weak self] in
                self?.hide()
                onDiscard()
            }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.title = "Video Editor"
        window.backgroundColor = .black
        window.minSize = NSSize(width: 900, height: 600)

        let hostingView = NSHostingView(rootView: editorView)
        window.contentView = hostingView

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        self.window = window

        // Load video data
        Task {
            await editor.load()
        }
    }

    // MARK: - Hide

    func hide() {
        editorController?.pause()
        window?.contentView = nil
        window?.orderOut(nil)
        window = nil
        editorController = nil
    }
}
