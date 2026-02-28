import ApplicationServices
import AppKit
import Foundation

/// Temporary debug logger — writes to /tmp/hold-debug.log so we can `tail -f` it.
private let _holdDebugLogURL = URL(fileURLWithPath: "/tmp/hold-debug.log")
private let _holdDebugQueue = DispatchQueue(label: "hold-debug-log")
func holdDebugLog(_ msg: String) {
    let ts = String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1_000_000))
    let line = "[\(ts)] \(msg)\n"
    _holdDebugQueue.async {
        if let data = line.data(using: .utf8) {
            if let fh = try? FileHandle(forWritingTo: _holdDebugLogURL) {
                fh.seekToEndOfFile()
                fh.write(data)
                fh.closeFile()
            } else {
                try? data.write(to: _holdDebugLogURL)
            }
        }
    }
}

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

    // Multi-key todo sheet shortcut
    var onTodoSheetKeyPressed: (() -> Void)?
    private var todoSheetShortcut: InvocationShortcut?
    private var isTodoSheetShortcutActive = false

    // Multi-key chat sheet shortcut
    var onChatSheetKeyPressed: (() -> Void)?
    private var chatSheetShortcut: InvocationShortcut?
    private var isChatSheetShortcutActive = false

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

    func setTodoSheetShortcut(_ shortcut: InvocationShortcut?) {
        todoSheetShortcut = shortcut
        isTodoSheetShortcutActive = false
    }

    func setChatSheetShortcut(_ shortcut: InvocationShortcut?) {
        chatSheetShortcut = shortcut
        isChatSheetShortcutActive = false
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

    func setRecordingControlsActive(_ active: Bool) {
        isRecordingForSpaceCycle = active
        isCurrentlyRecording = active
        setVoiceNoteSwitchArmed(active)
        setTodoSwitchArmed(active)
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
        setRecordingControlsActive(false)
    }

    // MARK: - Event Handling

    private func handleFlagsChanged(_ event: CGEvent) -> Bool {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        // Update current modifier flags from the event
        let rawFlags = event.flags
        currentModifierFlags = Self.nsModifierFlags(from: rawFlags)

        holdDebugLog("flagsChanged: keyCode=\(keyCode) flags=\(rawFlags.rawValue) modifiers=\(currentModifierFlags.rawValue) isActive=\(isInvocationShortcutActive)")

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

        // Todo sheet shortcut: modifier-based matching
        if let tsShortcut = todoSheetShortcut {
            if tsShortcut != invocationShortcut {
                let tsResult = evaluateModifierShortcut(tsShortcut, keyCode: keyCode, isActive: isTodoSheetShortcutActive)
                if let tsResult {
                    if tsResult, !isTodoSheetShortcutActive {
                        isTodoSheetShortcutActive = true
                        onTodoSheetKeyPressed?()
                    } else if !tsResult {
                        isTodoSheetShortcutActive = false
                    }
                    return true
                }
            }
        }

        // Chat sheet shortcut: modifier-based matching
        if let csShortcut = chatSheetShortcut {
            if csShortcut != invocationShortcut {
                let csResult = evaluateModifierShortcut(csShortcut, keyCode: keyCode, isActive: isChatSheetShortcutActive)
                if let csResult {
                    if csResult, !isChatSheetShortcutActive {
                        isChatSheetShortcutActive = true
                        onChatSheetKeyPressed?()
                    } else if !csResult {
                        isChatSheetShortcutActive = false
                    }
                    return true
                }
            }
        }

        // Invocation shortcut
        if invocationShortcut.isModifierOnly || (invocationShortcut.primaryKeyCode.map { InvocationKey.isModifierKeyCode($0) } ?? false) {
            // Modifier-only or single-modifier shortcut
            let result = evaluateModifierShortcut(invocationShortcut, keyCode: keyCode, isActive: isInvocationShortcutActive)
            holdDebugLog("evaluateModifier: result=\(String(describing: result)) isActive=\(isInvocationShortcutActive)")
            if let result {
                if result != isInvocationShortcutActive {
                    if result {
                        isInvocationShortcutActive = true
                        holdDebugLog(">>> FIRING .down")
                        onEvent?(.down)
                    } else {
                        // Cross-check with HID for Fn/Globe key spurious releases.
                        // macOS Globe behavior can clear .function flag even while
                        // the key is physically held — check multiple sources.
                        if let primaryKey = invocationShortcut.primaryKeyCode {
                            let hidState = CGEventSource.keyState(.hidSystemState, key: CGKeyCode(primaryKey))
                            let combinedState = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(primaryKey))
                            holdDebugLog("HID cross-check: hid=\(hidState) combined=\(combinedState)")
                            if hidState {
                                return true
                            }
                            if combinedState {
                                return true
                            }
                        }

                        holdDebugLog(">>> FIRING .up")
                        isInvocationShortcutActive = false
                        onEvent?(.up)
                    }
                }
                return true
            } else if isInvocationShortcutActive {
                // evaluateModifierShortcut returned nil (event was for a different
                // key code), but the invocation shortcut is active.  Another modifier
                // changing state can spuriously clear the invocation modifier flag
                // (especially .function on Globe key).  Re-check physically before
                // allowing the active state to be invalidated by a later event.
                if let primaryKey = invocationShortcut.primaryKeyCode {
                    let stillHeld = CGEventSource.keyState(.hidSystemState, key: CGKeyCode(primaryKey))
                        || CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(primaryKey))
                    if !stillHeld {
                        // Modifier flags say not held AND physical check also says not held.
                        // Verify via modifier flags too before firing .up.
                        let flagCheck = Self.keyStateFromModifierFlags(for: primaryKey, flags: currentModifierFlags)
                        if flagCheck == false || flagCheck == nil {
                            holdDebugLog(">>> FIRING .up (cross-key flagsChanged, physical check confirms release)")
                            isInvocationShortcutActive = false
                            onEvent?(.up)
                            return true
                        }
                    }
                }
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
        let eventModifierFlags = Self.nsModifierFlags(from: event.flags)
        currentModifierFlags = eventModifierFlags
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let invocationHasPriority = Self.invocationShouldTakePriority(
            forKeyCode: keyCode,
            currentModifierFlags: eventModifierFlags,
            invocationShortcut: invocationShortcut
        )

        // Escape interception: if enabled and recording, consume escape key
        if !invocationHasPriority, escapeToCancelEnabled, isCurrentlyRecording, keyCode == 53, isKeyDown {
            if !isRepeat {
                onEscapePressed?()
            }
            return true
        }

        // Space cycling: intercept left/right arrow keys during recording
        if !invocationHasPriority, isRecordingForSpaceCycle, isKeyDown {
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

        // Todo sheet shortcut (non-modifier key variant)
        if let tsShortcut = todoSheetShortcut, tsShortcut != invocationShortcut {
            if matchesKeyEvent(tsShortcut, keyCode: keyCode, isKeyDown: isKeyDown) {
                if isKeyDown {
                    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                    if !isRepeat {
                        onTodoSheetKeyPressed?()
                    }
                }
                return true
            }
        }

        // Chat sheet shortcut (non-modifier key variant)
        if let csShortcut = chatSheetShortcut, csShortcut != invocationShortcut {
            if matchesKeyEvent(csShortcut, keyCode: keyCode, isKeyDown: isKeyDown) {
                if isKeyDown {
                    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                    if !isRepeat {
                        onChatSheetKeyPressed?()
                    }
                }
                return true
            }
        }

        // Voice note switch key
        if !invocationHasPriority,
           let voiceNoteSwitchKeyCode,
           keyCode == voiceNoteSwitchKeyCode
        {
            if isKeyDown {
                if isRepeat {
                    return voiceNoteSwitchArmed
                }

                if voiceNoteSwitchArmed {
                    consumeVoiceNoteSwitchKeyUp = true
                    onVoiceNoteSwitchKeyPressed?()
                    return true
                }
            } else if consumeVoiceNoteSwitchKeyUp {
                consumeVoiceNoteSwitchKeyUp = false
                return true
            }
        }

        // Todo switch key
        if !invocationHasPriority,
           let todoSwitchKeyCode,
           keyCode == todoSwitchKeyCode
        {
            if isKeyDown {
                if isRepeat {
                    return todoSwitchArmed
                }

                if todoSwitchArmed {
                    consumeTodoSwitchKeyUp = true
                    onTodoSwitchKeyPressed?()
                    return true
                }
            } else if consumeTodoSwitchKeyUp {
                consumeTodoSwitchKeyUp = false
                return true
            }
        }

        // Invocation shortcut: key event handling
        if let primaryKey = invocationShortcut.primaryKeyCode, !InvocationKey.isModifierKeyCode(primaryKey) {
            if keyCode == primaryKey {
                holdDebugLog("keyEvent: keyCode=\(keyCode) isKeyDown=\(isKeyDown) isActive=\(isInvocationShortcutActive)")
                if invocationShortcut.modifiers != 0 {
                    // Modifier+key shortcut
                    let requiredFlags = invocationShortcut.nsModifierFlags
                    if isKeyDown {
                        if isRepeat { return true }
                        if currentModifierFlags.contains(requiredFlags), !isInvocationShortcutActive {
                            isInvocationShortcutActive = true
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
                        if isRepeat { return true }
                    }

                    guard isKeyDown != isInvocationShortcutActive else {
                        return true
                    }

                    isInvocationShortcutActive = isKeyDown
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

    static func invocationShouldTakePriority(
        forKeyCode keyCode: Int64,
        currentModifierFlags: NSEvent.ModifierFlags,
        invocationShortcut: InvocationShortcut
    ) -> Bool {
        guard let primaryKey = invocationShortcut.primaryKeyCode,
              !InvocationKey.isModifierKeyCode(primaryKey),
              keyCode == primaryKey
        else {
            return false
        }

        if invocationShortcut.modifiers == 0 {
            return true
        }

        let required = invocationShortcut.nsModifierFlags
        return currentModifierFlags.contains(required)
    }

    // MARK: - Physical State

    private func isShortcutPhysicallyActive(_ shortcut: InvocationShortcut) -> Bool {
        if let primaryKey = shortcut.primaryKeyCode {
            if InvocationKey.isModifierKeyCode(primaryKey) {
                // Single-modifier-key shortcut (e.g. Fn/Globe).
                // Check modifier flags first, then fall through to CGEventSource
                // because macOS Globe behavior can clear .function even while held.
                if let keyDown = Self.keyStateFromModifierFlags(for: primaryKey, flags: NSEvent.modifierFlags) {
                    if keyDown { return true }
                }
                if CGEventSource.keyState(.hidSystemState, key: CGKeyCode(primaryKey)) {
                    return true
                }
                if CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(primaryKey)) {
                    return true
                }
                return false
            }

            // Modifier+key shortcut: check required modifiers first
            if shortcut.modifiers != 0 {
                let required = shortcut.nsModifierFlags
                if !NSEvent.modifierFlags.contains(required) {
                    return false
                }
            }

            // Check the primary key via CGEventSource
            if CGEventSource.keyState(.hidSystemState, key: CGKeyCode(primaryKey)) {
                return true
            }
            if CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(primaryKey)) {
                return true
            }
            return false
        }

        // Modifier-only (no primary key): just check flags
        if shortcut.modifiers != 0 {
            let required = shortcut.nsModifierFlags
            return NSEvent.modifierFlags.contains(required)
        }
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
