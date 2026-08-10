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

    @discardableResult
    func pasteWithoutCopying(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        // Save current clipboard
        let savedItems = pasteboard.pasteboardItems?.compactMap { item -> (NSPasteboard.PasteboardType, Data)? in
            guard let type = item.types.first, let data = item.data(forType: type) else { return nil }
            return (type, data)
        } ?? []

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard AXIsProcessTrusted(), postCommandV() else {
            return false
        }

        // Restore clipboard after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            pasteboard.clearContents()
            for (type, data) in savedItems {
                pasteboard.setData(data, forType: type)
            }
        }

        return true
    }

    /// Erases the last `count` characters from the focused input by posting
    /// backspace key events — used when a pasted transcript is rerouted to a
    /// note/todo/AI and shouldn't stay in the field it landed in.
    @discardableResult
    func deleteBackward(count: Int) -> Bool {
        guard count > 0, AXIsProcessTrusted(), let source = CGEventSource(stateID: .hidSystemState) else {
            return false
        }

        let deleteKey: CGKeyCode = 51
        for _ in 0..<count {
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: deleteKey, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: deleteKey, keyDown: false)
            else {
                return false
            }
            keyDown.post(tap: .cgAnnotatedSessionEventTap)
            keyUp.post(tap: .cgAnnotatedSessionEventTap)
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
