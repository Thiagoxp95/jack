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

    /// Synthesizes a Return keypress into the frontmost app — used by
    /// "press Return after pasting" so a dictated message sends itself.
    ///
    /// Posted on its own after the ⌘V events so the target app has processed
    /// the paste first; a Return that races the paste sends an empty message.
    @discardableResult
    func postReturn() -> Bool {
        guard AXIsProcessTrusted(), let source = CGEventSource(stateID: .hidSystemState) else {
            return false
        }

        let returnKey: CGKeyCode = 36
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: false)
        else {
            return false
        }

        // Modifiers the user is still physically holding (the dictation
        // shortcut is often a modifier chord) would turn this into ⇧↵ or ⌘↵,
        // which means something different in every chat app.
        keyDown.flags = []
        keyUp.flags = []

        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)

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
