import AppKit
import ApplicationServices
import Foundation

/// Reads whatever text is highlighted in the frontmost app.
///
/// Tries Accessibility first (`AXSelectedText`, no side effects). Apps that
/// don't expose it — Chrome-family browsers, Electron, some editors — fall back
/// to a synthesized ⌘C with the clipboard saved and restored around it.
@MainActor
final class SelectionCaptureService {

    enum Outcome {
        case captured(text: String, sourceApp: String?)
        case emptySelection
        case missingAccessibilityPermission
    }

    /// How long to wait for the fallback ⌘C to land on the pasteboard.
    private let copyTimeout: TimeInterval = 0.45
    private let pollInterval: TimeInterval = 0.02

    func captureSelection() async -> Outcome {
        guard AXIsProcessTrusted() else {
            return .missingAccessibilityPermission
        }

        let sourceApp = Self.sourceAppDescription()

        if let text = Self.accessibilitySelectedText(), !text.isEmpty {
            return .captured(text: text, sourceApp: sourceApp)
        }

        if let text = await copySelectionViaPasteboard(), !text.isEmpty {
            return .captured(text: text, sourceApp: sourceApp)
        }

        return .emptySelection
    }

    // MARK: - Accessibility

    private static func accessibilitySelectedText() -> String? {
        let systemWide = AXUIElementCreateSystemWide()

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused,
              CFGetTypeID(focused) == AXUIElementGetTypeID()
        else {
            return nil
        }

        // swiftlint:disable:next force_cast
        let element = focused as! AXUIElement
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let text = selected as? String
        else {
            return nil
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sourceAppDescription() -> String? {
        let metadata = IntentContext.currentAppMetadata()
        switch (metadata.app, metadata.window) {
        case let (app?, window?): return "\(app) — \(window)"
        case let (app?, nil): return app
        default: return nil
        }
    }

    // MARK: - Pasteboard fallback

    private func copySelectionViaPasteboard() async -> String? {
        let pasteboard = NSPasteboard.general
        let saved = Self.snapshot(pasteboard)
        let changeCountBefore = pasteboard.changeCount

        guard Self.postCommandC() else {
            return nil
        }

        var copied: String?
        let deadline = Date().addingTimeInterval(copyTimeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            if pasteboard.changeCount != changeCountBefore {
                copied = pasteboard.string(forType: .string)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        Self.restore(saved, to: pasteboard)
        return copied
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        pasteboard.pasteboardItems?.map { item in
            var contents: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    contents[type] = data
                }
            }
            return contents
        } ?? []
    }

    private static func restore(_ saved: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        // Always clear: an empty snapshot means the clipboard was empty before,
        // and the synthesized ⌘C must not leave the selection behind.
        pasteboard.clearContents()
        guard !saved.isEmpty else { return }
        let items: [NSPasteboardItem] = saved.map { contents in
            let item = NSPasteboardItem()
            for (type, data) in contents {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(items)
    }

    private static func postCommandC() -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }

        let cKey: CGKeyCode = 8
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: false)
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
