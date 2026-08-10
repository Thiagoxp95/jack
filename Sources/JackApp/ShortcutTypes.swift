import AppKit
import Foundation

// MARK: - InvocationShortcut

struct InvocationShortcut: Codable, Equatable {
    /// The primary (non-modifier) key code, or nil for modifier-only shortcuts (e.g. Ctrl+Shift+Cmd).
    var primaryKeyCode: Int64?
    /// Raw value of NSEvent.ModifierFlags (masked to device-independent bits).
    var modifiers: UInt

    var isValid: Bool {
        if let keyCode = primaryKeyCode {
            if InvocationKey.isStandaloneValidKeyCode(keyCode) || InvocationKey.isModifierKeyCode(keyCode) {
                return true
            }
            // Regular keys require at least one modifier
            return modifiers != 0
        }
        // Modifier-only: need at least one modifier
        return modifiers != 0
    }

    var isModifierOnly: Bool {
        if let keyCode = primaryKeyCode {
            return InvocationKey.isModifierKeyCode(keyCode)
        }
        return true
    }

    var isSingleKey: Bool {
        return modifiers == 0 && primaryKeyCode != nil
    }

    var displayName: String {
        var parts: [String] = []
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        if flags.contains(.control) { parts.append("^") }
        if flags.contains(.option) { parts.append("\u{2325}") }
        if flags.contains(.shift) { parts.append("\u{21E7}") }
        if flags.contains(.command) { parts.append("\u{2318}") }
        if flags.contains(.function) { parts.append("Fn") }

        if let keyCode = primaryKeyCode {
            if !InvocationKey.isModifierKeyCode(keyCode) {
                parts.append(InvocationKey.displayName(for: keyCode))
            } else if parts.isEmpty {
                // Modifier-only shortcut using legacy single modifier key
                parts.append(InvocationKey.displayName(for: keyCode))
            }
        }

        return parts.joined(separator: "")
    }

    var nsModifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers)
    }

    static let `default` = InvocationShortcut(primaryKeyCode: 54, modifiers: 0) // Right Command

    static func fromLegacyKeyCode(_ keyCode: Int64) -> InvocationShortcut {
        // Legacy shortcuts were always single-key, so modifiers should be 0.
        // The event monitor detects modifier keys via flagsChanged regardless.
        return InvocationShortcut(primaryKeyCode: keyCode, modifiers: 0)
    }
}

// MARK: - WordReplacement

struct WordReplacement: Codable, Identifiable, Equatable {
    var id: UUID
    var original: String
    var replacement: String

    init(id: UUID = UUID(), original: String, replacement: String) {
        self.id = id
        self.original = original
        self.replacement = replacement
    }
}

// MARK: - InvocationKey

struct InvocationKey: Equatable {
    static let defaultKeyCode: Int64 = 54 // Right Command

    static func displayName(for keyCode: Int64) -> String {
        if let name = knownKeyNames[keyCode] {
            return name
        }
        return "Key \(keyCode)"
    }

    /// F1-F17, Fn/Globe, Escape — these can be used alone without modifiers.
    static func isStandaloneValidKeyCode(_ keyCode: Int64) -> Bool {
        // F-keys: F1(122), F2(120), F3(99), F4(118), F5(96), F6(97), F7(98), F8(100),
        // F9(101), F10(109), F11(103), F12(111), F13(105), F14(107), F15(113), F16(106), F17(64)
        let fKeys: Set<Int64> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64]
        if fKeys.contains(keyCode) { return true }
        if keyCode == 63 { return true } // Fn/Globe
        if keyCode == 53 { return true } // Escape
        return false
    }

    /// Key codes 54-63 are modifier keys (Command, Shift, Option, Control, CapsLock, Fn).
    static func isModifierKeyCode(_ keyCode: Int64) -> Bool {
        return keyCode >= 54 && keyCode <= 63
    }

    /// Maps a modifier key code to its corresponding NSEvent.ModifierFlags.
    static func modifierFlag(for keyCode: Int64) -> NSEvent.ModifierFlags {
        switch keyCode {
        case 55, 54: return .command
        case 56, 60: return .shift
        case 58, 61: return .option
        case 59, 62: return .control
        case 57: return .capsLock
        case 63: return .function
        default: return []
        }
    }

    private static let knownKeyNames: [Int64: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
        20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
        29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N",
        46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`", 51: "Delete", 53: "Escape",
        54: "Right Command", 55: "Left Command", 56: "Left Shift", 57: "Caps Lock",
        58: "Left Option", 59: "Left Control", 60: "Right Shift", 61: "Right Option",
        62: "Right Control", 63: "Fn/Globe", 64: "F17", 65: "Keypad .", 67: "Keypad *",
        69: "Keypad +", 71: "Keypad Clear", 75: "Keypad /", 76: "Keypad Enter",
        78: "Keypad -", 81: "Keypad =", 82: "Keypad 0", 83: "Keypad 1", 84: "Keypad 2",
        85: "Keypad 3", 86: "Keypad 4", 87: "Keypad 5", 88: "Keypad 6", 89: "Keypad 7",
        91: "Keypad 8", 92: "Keypad 9", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
        101: "F9", 103: "F11", 105: "F13", 106: "F16", 107: "F14", 109: "F10",
        111: "F12", 113: "F15", 114: "Help", 115: "Home", 116: "Page Up", 117: "Forward Delete",
        118: "F4", 119: "End", 120: "F2", 121: "Page Down", 122: "F1", 123: "Left Arrow",
        124: "Right Arrow", 125: "Down Arrow", 126: "Up Arrow",
    ]
}

enum ShortcutType: String, CaseIterable, Identifiable {
    case singleKey
    case combination

    var id: String { rawValue }

    var title: String {
        switch self {
        case .singleKey: return "Single Key"
        case .combination: return "Combination"
        }
    }
}

enum ShortcutMode: String, CaseIterable, Identifiable {
    case toggle
    case hold
    case doubleTap

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toggle:
            return "Toggle"
        case .hold:
            return "Hold"
        case .doubleTap:
            return "Double Tap"
        }
    }

    var iconName: String {
        switch self {
        case .toggle: return "arrow.triangle.2.circlepath"
        case .hold: return "hand.tap.fill"
        case .doubleTap: return "hand.tap"
        }
    }

    var shortDescription: String {
        switch self {
        case .toggle: return "Press to start, press to stop"
        case .hold: return "Hold to record, release to stop"
        case .doubleTap: return "Double-tap to toggle"
        }
    }
}

enum RecordingOutputMode: String, CaseIterable, Identifiable {
    case paste
    case voiceNote
    case todo
    case aiChat
    /// Capture now, let the classifier decide note-vs-todo once the transcript lands.
    case auto

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paste:
            return "Paste"
        case .voiceNote:
            return "Voice Note"
        case .todo:
            return "Todo"
        case .aiChat:
            return "AI Chat"
        case .auto:
            return "Auto"
        }
    }
}

enum ShortcutEvent: Equatable {
    case down
    case up
}

enum ShortcutAction: Equatable {
    case startRecording
    case stopRecording
    case toggleRecording
}

struct ShortcutInterpreter {
    private(set) var mode: ShortcutMode
    private var lastTapAt: Date?
    private let doubleTapWindow: TimeInterval

    init(mode: ShortcutMode, doubleTapWindow: TimeInterval = 0.35) {
        self.mode = mode
        self.doubleTapWindow = doubleTapWindow
    }

    mutating func setMode(_ newMode: ShortcutMode) {
        mode = newMode
        lastTapAt = nil
    }

    mutating func handle(_ event: ShortcutEvent, now: Date = .now) -> ShortcutAction? {
        switch mode {
        case .toggle:
            return event == .down ? .toggleRecording : nil
        case .hold:
            return event == .down ? .startRecording : .stopRecording
        case .doubleTap:
            guard event == .down else {
                return nil
            }

            if let lastTapAt, now.timeIntervalSince(lastTapAt) <= doubleTapWindow {
                self.lastTapAt = nil
                return .toggleRecording
            }

            lastTapAt = now
            return nil
        }
    }
}
