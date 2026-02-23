import ApplicationServices
import AppKit
import Foundation

final class GlobalFnShortcutMonitor {
    enum StartResult: Equatable {
        case started
        case missingKeyboardPermission
        case eventTapUnavailable
    }

    private static let eventMask =
        CGEventMask(1 << CGEventType.flagsChanged.rawValue) |
        CGEventMask(1 << CGEventType.keyDown.rawValue) |
        CGEventMask(1 << CGEventType.keyUp.rawValue)

    var onEvent: ((ShortcutEvent) -> Void)?
    var onVoiceNoteSwitchKeyPressed: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var invocationKeyCode: Int64 = InvocationKey.defaultKeyCode
    private var isInvocationKeyPressed = false
    private var voiceNoteSwitchKeyCode: Int64?
    private var voiceNoteSwitchArmed = false
    private var consumeVoiceNoteSwitchKeyUp = false

    func setInvocationKeyCode(_ keyCode: Int64) {
        invocationKeyCode = keyCode
        isInvocationKeyPressed = false
    }

    func setVoiceNoteSwitchKeyCode(_ keyCode: Int64?) {
        voiceNoteSwitchKeyCode = keyCode
        consumeVoiceNoteSwitchKeyUp = false
    }

    func setVoiceNoteSwitchArmed(_ armed: Bool) {
        voiceNoteSwitchArmed = armed
        if !armed {
            consumeVoiceNoteSwitchKeyUp = false
        }
    }

    func isInvocationKeyCurrentlyPressed() -> Bool {
        if let keyDownFromModifiers = Self.keyStateFromModifierFlags(for: invocationKeyCode, flags: NSEvent.modifierFlags) {
            return keyDownFromModifiers
        }

        return CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(invocationKeyCode))
    }

    func start() -> StartResult {
        guard eventTap == nil else {
            return .started
        }

        guard CGPreflightListenEventAccess() else {
            return .missingKeyboardPermission
        }

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let monitor = Unmanaged<GlobalFnShortcutMonitor>.fromOpaque(userInfo).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = monitor.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            guard type == .flagsChanged else {
                if type == .keyDown {
                    if monitor.handleKeyEvent(event, isKeyDown: true) {
                        return nil
                    }
                } else if type == .keyUp {
                    if monitor.handleKeyEvent(event, isKeyDown: false) {
                        return nil
                    }
                }
                return Unmanaged.passUnretained(event)
            }

            monitor.handleFlagsChanged(event)
            return Unmanaged.passUnretained(event)
        }

        let userInfo = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.eventMask,
            callback: callback,
            userInfo: userInfo
        ) else {
            return .eventTapUnavailable
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        return .started
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }

        if let tap = eventTap {
            CFMachPortInvalidate(tap)
        }

        runLoopSource = nil
        eventTap = nil
        isInvocationKeyPressed = false
        voiceNoteSwitchArmed = false
        consumeVoiceNoteSwitchKeyUp = false
    }

    private func handleFlagsChanged(_ event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == invocationKeyCode else {
            return
        }

        let keyDown = Self.keyStateFromModifierFlags(for: invocationKeyCode, flags: event.flags) ?? !isInvocationKeyPressed
        guard keyDown != isInvocationKeyPressed else {
            return
        }

        isInvocationKeyPressed = keyDown
        if keyDown, voiceNoteSwitchKeyCode != nil {
            voiceNoteSwitchArmed = true
        }
        onEvent?(keyDown ? .down : .up)
    }

    private func handleKeyEvent(_ event: CGEvent, isKeyDown: Bool) -> Bool {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        if let voiceNoteSwitchKeyCode,
           keyCode == voiceNoteSwitchKeyCode
        {
            if isKeyDown {
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if isRepeat {
                    return voiceNoteSwitchArmed
                }

                guard voiceNoteSwitchArmed else {
                    return false
                }

                consumeVoiceNoteSwitchKeyUp = true
                onVoiceNoteSwitchKeyPressed?()
                return true
            }

            if consumeVoiceNoteSwitchKeyUp {
                consumeVoiceNoteSwitchKeyUp = false
                return true
            }

            return false
        }

        guard keyCode == invocationKeyCode else {
            return false
        }

        if isKeyDown {
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if isRepeat {
                return false
            }
        }

        guard isKeyDown != isInvocationKeyPressed else {
            return false
        }

        isInvocationKeyPressed = isKeyDown
        if isKeyDown, voiceNoteSwitchKeyCode != nil {
            voiceNoteSwitchArmed = true
        }
        onEvent?(isKeyDown ? .down : .up)
        return false
    }

    private static func keyStateFromModifierFlags(for keyCode: Int64, flags: CGEventFlags) -> Bool? {
        switch keyCode {
        case 55, 54:
            return flags.contains(.maskCommand)
        case 56, 60:
            return flags.contains(.maskShift)
        case 58, 61:
            return flags.contains(.maskAlternate)
        case 59, 62:
            return flags.contains(.maskControl)
        case 57:
            return flags.contains(.maskAlphaShift)
        case 63:
            return flags.contains(.maskSecondaryFn)
        default:
            return nil
        }
    }

    private static func keyStateFromModifierFlags(for keyCode: Int64, flags: NSEvent.ModifierFlags) -> Bool? {
        switch keyCode {
        case 55, 54:
            return flags.contains(.command)
        case 56, 60:
            return flags.contains(.shift)
        case 58, 61:
            return flags.contains(.option)
        case 59, 62:
            return flags.contains(.control)
        case 57:
            return flags.contains(.capsLock)
        case 63:
            return flags.contains(.function)
        default:
            return nil
        }
    }
}
