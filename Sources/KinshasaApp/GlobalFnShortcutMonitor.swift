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
    var onTodoSwitchKeyPressed: (() -> Void)?

    enum SpaceCycleDirection {
        case left, right
    }

    var onSpaceCycleKeyPressed: ((SpaceCycleDirection) -> Void)?
    var isRecordingForSpaceCycle = false

    var onScreenRecordingKeyPressed: (() -> Void)?

    // Escape interception
    var onEscapePressed: (() -> Void)?
    var escapeToCancelEnabled = false
    var isCurrentlyRecording = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Multi-key invocation shortcut
    private var invocationShortcut: InvocationShortcut = .default
    private var isInvocationShortcutActive = false
    private var currentModifierFlags: NSEvent.ModifierFlags = []

    // Voice note switch (still single-key)
    private var voiceNoteSwitchKeyCode: Int64?
    private var voiceNoteSwitchArmed = false
    private var consumeVoiceNoteSwitchKeyUp = false

    // Todo switch (single-key, mirrors voice note switch)
    private var todoSwitchKeyCode: Int64?
    private var todoSwitchArmed = false
    private var consumeTodoSwitchKeyUp = false

    // Multi-key screen recording shortcut
    private var screenRecordingShortcut: InvocationShortcut?
    private var isScreenRecordingShortcutActive = false

    func setInvocationShortcut(_ shortcut: InvocationShortcut) {
        invocationShortcut = shortcut
        isInvocationShortcutActive = false
    }

    func setVoiceNoteSwitchKeyCode(_ keyCode: Int64?) {
        voiceNoteSwitchKeyCode = keyCode
        consumeVoiceNoteSwitchKeyUp = false
    }

    func setScreenRecordingShortcut(_ shortcut: InvocationShortcut?) {
        screenRecordingShortcut = shortcut
        isScreenRecordingShortcutActive = false
    }

    func setVoiceNoteSwitchArmed(_ armed: Bool) {
        voiceNoteSwitchArmed = armed
        if !armed {
            consumeVoiceNoteSwitchKeyUp = false
        }
    }

    func setTodoSwitchKeyCode(_ keyCode: Int64?) {
        todoSwitchKeyCode = keyCode
        consumeTodoSwitchKeyUp = false
    }

    func setTodoSwitchArmed(_ armed: Bool) {
        todoSwitchArmed = armed
        if !armed {
            consumeTodoSwitchKeyUp = false
        }
    }

    func isInvocationKeyCurrentlyPressed() -> Bool {
        if isInvocationShortcutActive {
            return true
        }
        return isShortcutPhysicallyActive(invocationShortcut)
    }

    func isInvocationKeyPhysicallyPressed() -> Bool {
        return isShortcutPhysicallyActive(invocationShortcut)
    }

    func resetInvocationKeyState() {
        isInvocationShortcutActive = false
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

            if monitor.handleFlagsChanged(event) {
                return nil
            }
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
        isInvocationShortcutActive = false
        voiceNoteSwitchArmed = false
        consumeVoiceNoteSwitchKeyUp = false
        todoSwitchArmed = false
        consumeTodoSwitchKeyUp = false
    }

    // MARK: - Event Handling

    private func handleFlagsChanged(_ event: CGEvent) -> Bool {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        // Update current modifier flags from the event
        let rawFlags = event.flags
        currentModifierFlags = Self.nsModifierFlags(from: rawFlags)

        // Screen recording shortcut: modifier-based matching
        if let srShortcut = screenRecordingShortcut {
            if srShortcut != invocationShortcut {
                let srResult = evaluateModifierShortcut(srShortcut, keyCode: keyCode, isActive: isScreenRecordingShortcutActive)
                if let srResult {
                    if srResult, !isScreenRecordingShortcutActive {
                        isScreenRecordingShortcutActive = true
                        onScreenRecordingKeyPressed?()
                    } else if !srResult {
                        isScreenRecordingShortcutActive = false
                    }
                    return true
                }
            }
        }

        // Invocation shortcut
        if invocationShortcut.isModifierOnly || (invocationShortcut.primaryKeyCode.map { InvocationKey.isModifierKeyCode($0) } ?? false) {
            // Modifier-only or single-modifier shortcut
            let result = evaluateModifierShortcut(invocationShortcut, keyCode: keyCode, isActive: isInvocationShortcutActive)
            if let result {
                if result != isInvocationShortcutActive {
                    if result {
                        isInvocationShortcutActive = true
                        if voiceNoteSwitchKeyCode != nil {
                            voiceNoteSwitchArmed = true
                        }
                        if todoSwitchKeyCode != nil {
                            todoSwitchArmed = true
                        }
                        onEvent?(.down)
                    } else {
                        // Cross-check with HID for Fn/Globe key spurious releases
                        if let primaryKey = invocationShortcut.primaryKeyCode,
                           CGEventSource.keyState(.hidSystemState, key: CGKeyCode(primaryKey)) {
                            return true
                        }
                        isInvocationShortcutActive = false
                        onEvent?(.up)
                    }
                }
                return true
            }
        }

        // For modifier+key shortcuts: track modifier state (key event handles the primary key)
        if let primaryKey = invocationShortcut.primaryKeyCode, !InvocationKey.isModifierKeyCode(primaryKey), invocationShortcut.modifiers != 0 {
            // If the shortcut was active and modifiers were released, fire .up
            if isInvocationShortcutActive {
                let requiredFlags = invocationShortcut.nsModifierFlags
                if !currentModifierFlags.contains(requiredFlags) {
                    isInvocationShortcutActive = false
                    onEvent?(.up)
                    return false
                }
            }
        }

        return false
    }

    private func handleKeyEvent(_ event: CGEvent, isKeyDown: Bool) -> Bool {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        // Escape interception: if enabled and recording, consume escape key
        if escapeToCancelEnabled, isCurrentlyRecording, keyCode == 53, isKeyDown {
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if !isRepeat {
                onEscapePressed?()
            }
            return true
        }

        // Space cycling: intercept left/right arrow keys during recording
        if isRecordingForSpaceCycle, isKeyDown {
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if !isRepeat {
                if keyCode == 123 { // left arrow
                    onSpaceCycleKeyPressed?(.left)
                    return true
                } else if keyCode == 124 { // right arrow
                    onSpaceCycleKeyPressed?(.right)
                    return true
                }
            }
        }

        // Screen recording shortcut (non-modifier key variant)
        if let srShortcut = screenRecordingShortcut, srShortcut != invocationShortcut {
            if matchesKeyEvent(srShortcut, keyCode: keyCode, isKeyDown: isKeyDown) {
                if isKeyDown {
                    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                    if !isRepeat {
                        onScreenRecordingKeyPressed?()
                    }
                }
                return true
            }
        }

        // Voice note switch key
        if let voiceNoteSwitchKeyCode, keyCode == voiceNoteSwitchKeyCode {
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

        // Todo switch key
        if let todoSwitchKeyCode,
           keyCode == todoSwitchKeyCode
        {
            if isKeyDown {
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if isRepeat {
                    return todoSwitchArmed
                }
                guard todoSwitchArmed else {
                    return false
                }
                consumeTodoSwitchKeyUp = true
                onTodoSwitchKeyPressed?()
                return true
            }
            if consumeTodoSwitchKeyUp {
                consumeTodoSwitchKeyUp = false
                return true
            }
            return false
        }

        // Invocation shortcut: key event handling
        if let primaryKey = invocationShortcut.primaryKeyCode, !InvocationKey.isModifierKeyCode(primaryKey) {
            if keyCode == primaryKey {
                if invocationShortcut.modifiers != 0 {
                    // Modifier+key shortcut
                    let requiredFlags = invocationShortcut.nsModifierFlags
                    if isKeyDown {
                        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                        if isRepeat { return true }
                        if currentModifierFlags.contains(requiredFlags), !isInvocationShortcutActive {
                            isInvocationShortcutActive = true
                            if voiceNoteSwitchKeyCode != nil {
                                voiceNoteSwitchArmed = true
                            }
                            if todoSwitchKeyCode != nil {
                                todoSwitchArmed = true
                            }
                            onEvent?(.down)
                            return true
                        }
                    } else {
                        if isInvocationShortcutActive {
                            isInvocationShortcutActive = false
                            onEvent?(.up)
                            return true
                        }
                    }
                    return isInvocationShortcutActive
                } else {
                    // Single key (no modifiers) — legacy behavior
                    if isKeyDown {
                        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                        if isRepeat { return true }
                    }

                    guard isKeyDown != isInvocationShortcutActive else {
                        return true
                    }

                    isInvocationShortcutActive = isKeyDown
                    if isKeyDown, voiceNoteSwitchKeyCode != nil {
                        voiceNoteSwitchArmed = true
                    }
                    if isKeyDown, todoSwitchKeyCode != nil {
                        todoSwitchArmed = true
                    }
                    onEvent?(isKeyDown ? .down : .up)
                    return true
                }
            }
        }

        return false
    }

    // MARK: - Shortcut Matching Helpers

    /// Evaluates whether a modifier-based shortcut is now active based on a flagsChanged event.
    /// Returns true/false for active/inactive, or nil if this event isn't relevant to the shortcut.
    private func evaluateModifierShortcut(_ shortcut: InvocationShortcut, keyCode: Int64, isActive: Bool) -> Bool? {
        if let primaryKey = shortcut.primaryKeyCode, InvocationKey.isModifierKeyCode(primaryKey) {
            // Single modifier key shortcut (e.g. Fn/Globe, Left Command)
            let keyDown = Self.keyStateFromModifierFlags(for: primaryKey, flags: currentModifierFlags)
            if keyCode == primaryKey {
                return keyDown ?? !isActive
            }
            return nil
        }

        if shortcut.primaryKeyCode == nil {
            // Pure modifier-only shortcut (e.g. Ctrl+Shift+Cmd)
            let required = shortcut.nsModifierFlags
            let allHeld = currentModifierFlags.contains(required)
            if allHeld != isActive {
                return allHeld
            }
            return nil
        }

        return nil
    }

    /// Checks if a key event matches a non-modifier shortcut (checks both key code and required modifiers).
    private func matchesKeyEvent(_ shortcut: InvocationShortcut, keyCode: Int64, isKeyDown: Bool) -> Bool {
        guard let primaryKey = shortcut.primaryKeyCode, !InvocationKey.isModifierKeyCode(primaryKey) else {
            return false
        }
        guard keyCode == primaryKey else { return false }

        if shortcut.modifiers != 0 {
            let required = shortcut.nsModifierFlags
            return currentModifierFlags.contains(required)
        }
        return true
    }

    // MARK: - Physical State

    private func isShortcutPhysicallyActive(_ shortcut: InvocationShortcut) -> Bool {
        // Check modifiers
        if shortcut.modifiers != 0 {
            let required = shortcut.nsModifierFlags
            if !NSEvent.modifierFlags.contains(required) {
                return false
            }
        }

        // Check primary key
        if let primaryKey = shortcut.primaryKeyCode {
            if InvocationKey.isModifierKeyCode(primaryKey) {
                // For modifier keys, check via modifier flags
                if let keyDown = Self.keyStateFromModifierFlags(for: primaryKey, flags: NSEvent.modifierFlags) {
                    return keyDown
                }
                return false
            }
            // For regular keys, check CGEventSource
            if CGEventSource.keyState(.hidSystemState, key: CGKeyCode(primaryKey)) {
                return true
            }
            if CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(primaryKey)) {
                return true
            }
            return false
        }

        // Modifier-only: just check flags (already done above)
        return true
    }

    // MARK: - Utilities

    private static func nsModifierFlags(from flags: CGEventFlags) -> NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskAlphaShift) { result.insert(.capsLock) }
        if flags.contains(.maskSecondaryFn) { result.insert(.function) }
        return result
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
