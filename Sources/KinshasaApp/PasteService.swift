import AppKit
import ApplicationServices
import Foundation

@MainActor
final class PasteService {
    @discardableResult
    func copyAndPaste(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard AXIsProcessTrusted(), postCommandV() else {
            return false
        }

        return true
    }

    private func postCommandV() -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            return false
        }

        let vKey: CGKeyCode = 9

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)

        return true
    }
}
