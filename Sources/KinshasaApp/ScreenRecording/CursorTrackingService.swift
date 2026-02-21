import ApplicationServices
import CoreGraphics
import Foundation
import os

// MARK: - CursorTrackingService

/// Tracks mouse position and clicks during screen recording using a CGEvent tap.
///
/// The service installs a listen-only event tap that records cursor movement and
/// click events with timestamps relative to the recording start. Events are
/// buffered in a ring buffer and flushed periodically to main storage.
actor CursorTrackingService {
    // MARK: - EventBuffer

    /// Thread-safe buffer accessed from the CGEvent tap C callback and from
    /// `@MainActor` methods that manage the tap lifecycle. Uses `os_unfair_lock`
    /// so it is safe to call from any thread without actor isolation.
    final class EventBuffer: @unchecked Sendable {
        private var lock = os_unfair_lock()
        private var buffer: [CursorEvent] = []
        private(set) var startTime: CFAbsoluteTime = 0

        // Event-tap references stored here so @MainActor methods can
        // install and remove the tap without crossing actor boundaries.
        private var _eventTap: CFMachPort?
        private var _runLoopSource: CFRunLoopSource?

        func setStartTime(_ time: CFAbsoluteTime) {
            os_unfair_lock_lock(&lock)
            startTime = time
            os_unfair_lock_unlock(&lock)
        }

        func append(_ event: CursorEvent) {
            os_unfair_lock_lock(&lock)
            buffer.append(event)
            os_unfair_lock_unlock(&lock)
        }

        func drain() -> [CursorEvent] {
            os_unfair_lock_lock(&lock)
            let events = buffer
            buffer.removeAll(keepingCapacity: true)
            os_unfair_lock_unlock(&lock)
            return events
        }

        var count: Int {
            os_unfair_lock_lock(&lock)
            let c = buffer.count
            os_unfair_lock_unlock(&lock)
            return c
        }

        func reset() {
            os_unfair_lock_lock(&lock)
            buffer.removeAll(keepingCapacity: false)
            startTime = 0
            os_unfair_lock_unlock(&lock)
        }

        func storeEventTap(_ tap: CFMachPort, source: CFRunLoopSource?) {
            os_unfair_lock_lock(&lock)
            _eventTap = tap
            _runLoopSource = source
            os_unfair_lock_unlock(&lock)
        }

        func takeEventTap() -> (tap: CFMachPort?, source: CFRunLoopSource?) {
            os_unfair_lock_lock(&lock)
            let tap = _eventTap
            let source = _runLoopSource
            _eventTap = nil
            _runLoopSource = nil
            os_unfair_lock_unlock(&lock)
            return (tap, source)
        }

        /// Re-enable the tap if it was disabled by the system.
        func reenableTapIfNeeded() {
            os_unfair_lock_lock(&lock)
            let tap = _eventTap
            os_unfair_lock_unlock(&lock)
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
    }

    // MARK: - Properties

    private let framerate: Int
    private let flushThreshold = 500
    let eventBuffer = EventBuffer()
    private var collectedEvents: [CursorEvent] = []

    private static let eventMask: CGEventMask =
        CGEventMask(1 << CGEventType.mouseMoved.rawValue)
        | CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
        | CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
        | CGEventMask(1 << CGEventType.leftMouseDragged.rawValue)
        | CGEventMask(1 << CGEventType.rightMouseDragged.rawValue)

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.kinshasa",
        category: "CursorTracking"
    )

    // MARK: - Init

    init(framerate: Int) {
        self.framerate = framerate
    }

    // MARK: - Public API

    /// Install the CGEvent tap on the main run loop and begin tracking.
    @MainActor
    func start() -> Bool {
        let buffer = eventBuffer
        buffer.reset()
        buffer.setStartTime(CFAbsoluteTimeGetCurrent())

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let buf = Unmanaged<CursorTrackingService.EventBuffer>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            // Re-enable if the system disabled it.
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                buf.reenableTapIfNeeded()
                return Unmanaged.passUnretained(event)
            }

            let location = event.location
            let relativeTime = CFAbsoluteTimeGetCurrent() - buf.startTime

            let click: String?
            switch type {
            case .leftMouseDown:
                click = "left"
            case .rightMouseDown:
                click = "right"
            default:
                click = nil
            }

            let cursorEvent = CursorEvent(
                t: relativeTime,
                x: Double(location.x),
                y: Double(location.y),
                click: click
            )

            buf.append(cursorEvent)
            return Unmanaged.passUnretained(event)
        }

        let userInfo = UnsafeMutableRawPointer(
            Unmanaged.passUnretained(buffer).toOpaque()
        )

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: Self.eventMask,
            callback: callback,
            userInfo: userInfo
        ) else {
            Self.logger.error("Failed to create CGEvent tap for cursor tracking")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        buffer.storeEventTap(tap, source: source)

        Self.logger.info("Cursor tracking started")
        return true
    }

    /// Remove the event tap and return all collected cursor data.
    @MainActor
    func stop() async -> CursorTrackingData {
        let buffer = eventBuffer
        let (tap, source) = buffer.takeEventTap()

        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }

        Self.logger.info("Cursor tracking stopped")

        return await finalizeData()
    }

    /// Record a cursor position event. Can be called from any isolation context
    /// since it goes through the thread-safe EventBuffer.
    nonisolated func recordPosition(x: Double, y: Double, click: String? = nil) {
        let relativeTime = CFAbsoluteTimeGetCurrent() - eventBuffer.startTime
        let event = CursorEvent(t: relativeTime, x: x, y: y, click: click)
        eventBuffer.append(event)
    }

    /// Flush buffered events from the ring buffer into main storage.
    /// Call this periodically (e.g. when buffer count exceeds `flushThreshold`).
    func flushBuffer() {
        let drained = eventBuffer.drain()
        if !drained.isEmpty {
            collectedEvents.append(contentsOf: drained)
        }
    }

    /// Encode all collected cursor data as JSON and write atomically to disk.
    func writeToFile(url: URL) throws {
        flushBuffer()
        let data = CursorTrackingData(framerate: framerate, events: collectedEvents)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let jsonData = try encoder.encode(data)
        try jsonData.write(to: url, options: .atomic)
        Self.logger.info("Cursor data written to \(url.path, privacy: .public)")
    }

    // MARK: - Private Helpers

    private func finalizeData() -> CursorTrackingData {
        flushBuffer()
        let data = CursorTrackingData(framerate: framerate, events: collectedEvents)
        collectedEvents.removeAll()
        return data
    }
}
