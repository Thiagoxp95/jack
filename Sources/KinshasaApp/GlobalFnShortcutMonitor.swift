import ApplicationServices
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

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var invocationKeyCode: Int64 = InvocationKey.defaultKeyCode
    private var isInvocationKeyPressed = false

    func setInvocationKeyCode(_ keyCode: Int64) {
        invocationKeyCode = keyCode
        isInvocationKeyPressed = false
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
                    monitor.handleKeyEvent(event, isKeyDown: true)
                } else if type == .keyUp {
                    monitor.handleKeyEvent(event, isKeyDown: false)
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
            options: .listenOnly,
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
    }

    private func handleFlagsChanged(_ event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == invocationKeyCode else {
            return
        }

        // flagsChanged fires for modifier key transitions. Toggling state on each
        // event keyed by physical keycode preserves left/right specificity.
        isInvocationKeyPressed.toggle()
        onEvent?(isInvocationKeyPressed ? .down : .up)
    }

    private func handleKeyEvent(_ event: CGEvent, isKeyDown: Bool) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == invocationKeyCode else {
            return
        }

        if isKeyDown {
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if isRepeat {
                return
            }
        }

        guard isKeyDown != isInvocationKeyPressed else {
            return
        }

        isInvocationKeyPressed = isKeyDown
        onEvent?(isKeyDown ? .down : .up)
    }
}
