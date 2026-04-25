import ApplicationServices
import AppKit
import Foundation

/// Monitors for simultaneous left + right mouse button holds on text inputs
/// to trigger dictation. Uses a CGEventTap at the HID layer so the gesture
/// is detected globally, and suppresses the right-click context menu when
/// the dictation gesture fires.
final class MouseDictationMonitor {

    var onEvent: ((ShortcutEvent) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var leftButtonDown = false
    private var rightButtonDown = false
    private var gestureActive = false
    /// When the first button goes down we record it so we can require the
    /// second button to arrive within a short window.
    private var firstButtonDownAt: Date?

    /// Maximum gap between the first and second button presses to recognise
    /// the gesture (prevents accidental activation during normal clicks).
    private let simultaneousWindow: TimeInterval = 0.25

    private static let eventMask: CGEventMask =
        CGEventMask(1 << CGEventType.leftMouseDown.rawValue) |
        CGEventMask(1 << CGEventType.leftMouseUp.rawValue) |
        CGEventMask(1 << CGEventType.rightMouseDown.rawValue) |
        CGEventMask(1 << CGEventType.rightMouseUp.rawValue)

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    func start() {
        guard eventTap == nil else { return }

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let monitor = Unmanaged<MouseDictationMonitor>.fromOpaque(userInfo).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = monitor.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            return monitor.handleMouseEvent(type: type, event: event)
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
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        runLoopSource = nil
        eventTap = nil
        resetState()
    }

    // MARK: - Event Handling

    private func handleMouseEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .leftMouseDown:
            leftButtonDown = true
            if !rightButtonDown {
                firstButtonDownAt = Date()
            }
            return checkGestureStart(event: event) ?? Unmanaged.passUnretained(event)

        case .rightMouseDown:
            rightButtonDown = true
            if !leftButtonDown {
                firstButtonDownAt = Date()
            }
            return checkGestureStart(event: event) ?? Unmanaged.passUnretained(event)

        case .leftMouseUp:
            leftButtonDown = false
            if gestureActive {
                endGesture()
                // Suppress the mouse-up so apps don't see a stale click
                return nil
            }
            return Unmanaged.passUnretained(event)

        case .rightMouseUp:
            rightButtonDown = false
            if gestureActive {
                endGesture()
                return nil
            }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// Checks whether both buttons are now held and the cursor is over a text
    /// input. Returns `nil` (suppress event) when the gesture activates, or
    /// an `Unmanaged` passthrough otherwise.
    private func checkGestureStart(event: CGEvent) -> Unmanaged<CGEvent>? {
        guard leftButtonDown, rightButtonDown, !gestureActive else {
            return nil // let the caller return the default passthrough
        }

        // Require both buttons to arrive within the simultaneousness window
        if let first = firstButtonDownAt, Date().timeIntervalSince(first) > simultaneousWindow {
            return nil
        }

        // Check if the cursor is over a text input
        guard cursorIsOverTextInput() else {
            return nil
        }

        gestureActive = true
        firstButtonDownAt = nil
        onEvent?(.down)
        // Suppress the event that completed the gesture (right-click context
        // menu or selection start) so the app under the cursor only sees the
        // first single-button press.
        return nil
    }

    private func endGesture() {
        gestureActive = false
        firstButtonDownAt = nil
        onEvent?(.up)
    }

    private func resetState() {
        leftButtonDown = false
        rightButtonDown = false
        gestureActive = false
        firstButtonDownAt = nil
    }

    // MARK: - Text Input Detection (Accessibility)

    private func cursorIsOverTextInput() -> Bool {
        let location = NSEvent.mouseLocation

        // Convert from bottom-left (AppKit) to top-left (CG / Accessibility)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(location) })
                ?? NSScreen.main else {
            return false
        }
        let cgPoint = CGPoint(
            x: location.x,
            y: screen.frame.maxY - location.y + screen.frame.origin.y
        )

        let systemElement = AXUIElementCreateSystemWide()
        var elementRef: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(systemElement, Float(cgPoint.x), Float(cgPoint.y), &elementRef)
        guard result == .success, let element = elementRef else {
            return false
        }

        return isTextInput(element)
    }

    /// Walks up the accessibility tree (up to a small limit) looking for a
    /// text-capable role. Many apps wrap text areas inside generic groups, so
    /// checking ancestors is important.
    private func isTextInput(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<6 {
            guard let el = current else { break }
            if let role = axString(el, kAXRoleAttribute) {
                switch role {
                case kAXTextFieldRole as String,
                     kAXTextAreaRole as String,
                     kAXComboBoxRole as String,
                     "AXSearchField",
                     "AXWebArea":
                    return true
                default:
                    break
                }
            }
            // Check for a sub-role that indicates text editing
            if let subRole = axString(el, kAXSubroleAttribute) {
                if subRole == "AXSearchField" || subRole == "AXSecureTextField" {
                    return true
                }
            }
            // Walk to parent
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &parentRef) == .success else {
                break
            }
            current = (parentRef as! AXUIElement)
        }
        return false
    }

    private func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }
}
