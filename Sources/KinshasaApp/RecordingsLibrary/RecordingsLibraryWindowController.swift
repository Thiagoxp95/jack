import AppKit
import SwiftUI

@MainActor
final class RecordingsLibraryWindowController {
    private var window: NSWindow?

    func show(spaceController: SpaceController, authController: AuthController) {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = RecordingsLibraryView(
            spaceController: spaceController,
            authController: authController
        )

        let hostingController = NSHostingController(rootView: view)
        let newWindow = NSWindow(contentViewController: hostingController)
        newWindow.title = "Recordings Library"
        newWindow.setContentSize(NSSize(width: 800, height: 600))
        newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        newWindow.minSize = NSSize(width: 600, height: 400)
        newWindow.center()
        newWindow.makeKeyAndOrderFront(nil)
        window = newWindow
    }
}
