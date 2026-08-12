import AppKit
@preconcurrency import ScreenCaptureKit
import Vision

// MARK: - NoteCrosshairView

/// Full-screen drag-select view for note-mode screenshots. Unlike
/// `RegionSelectionView` it stays up after a capture (multi-screenshot) and
/// ignores tiny drags instead of dismissing.
private final class NoteCrosshairView: NSView {

    /// Selection rect in this view's coordinates.
    var onSelection: ((NSRect) -> Void)?

    private var dragOrigin: NSPoint?
    private var currentRect: NSRect = .zero

    private let hintLabel: NSTextField = {
        let label = NSTextField(labelWithString: "  Drag to attach a screenshot to this note · esc to dismiss  ")
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.backgroundColor = NSColor.black.withAlphaComponent(0.7)
        label.drawsBackground = true
        label.isBezeled = false
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.cornerRadius = 6
        label.layer?.masksToBounds = true
        label.sizeToFit()
        return label
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(hintLabel)
        hintLabel.frame.origin = NSPoint(
            x: frameRect.midX - hintLabel.frame.width / 2,
            y: frameRect.maxY - 80
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        dragOrigin = convert(event.locationInWindow, from: nil)
        currentRect = .zero
        setNeedsDisplay(bounds)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin else { return }
        let current = convert(event.locationInWindow, from: nil)
        currentRect = NSRect(
            x: min(origin.x, current.x),
            y: min(origin.y, current.y),
            width: abs(current.x - origin.x),
            height: abs(current.y - origin.y)
        )
        setNeedsDisplay(bounds)
    }

    override func mouseUp(with event: NSEvent) {
        _ = event
        let rect = currentRect
        dragOrigin = nil
        currentRect = .zero
        setNeedsDisplay(bounds)

        // Stray clicks while talking are likely; require a real drag.
        if rect.width > 10, rect.height > 10 {
            onSelection?(rect)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Lighter dim than region-recording: this overlay can stay up a while.
        NSColor.black.withAlphaComponent(0.15).setFill()
        dirtyRect.fill()

        guard currentRect.width > 0, currentRect.height > 0 else { return }

        NSGraphicsContext.current?.cgContext.clear(currentRect)
        NSColor.white.withAlphaComponent(0.25).setFill()
        currentRect.fill()
        NSColor.white.setStroke()
        let borderPath = NSBezierPath(rect: currentRect)
        borderPath.lineWidth = 1.5
        borderPath.stroke()
    }
}

// MARK: - NoteScreenshotController

/// While note-mode dictation is active, covers every screen with a crosshair
/// overlay. Each click-drag captures that region as a PNG, hands the file back
/// via `onCapture`, and re-arms for the next capture. ESC (or mode change)
/// dismisses without touching the recording.
@MainActor
final class NoteScreenshotController {

    /// Saved screenshot file + recognized OCR text (empty when none).
    var onCapture: ((URL, String) -> Void)?

    /// Provides the directory to save screenshots into.
    var attachmentsDirectoryProvider: (() throws -> URL)?

    private(set) var isVisible = false
    private var windows: [NSWindow] = []
    private var eventMonitor: Any?
    private var isCapturing = false

    // MARK: - Show / Hide

    func show() {
        guard !isVisible else { return }
        isVisible = true

        for screen in NSScreen.screens {
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.ignoresMouseEvents = false
            window.isReleasedWhenClosed = false

            let view = NoteCrosshairView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onSelection = { [weak self, weak window] viewRect in
                guard let self, let window else { return }
                self.captureSelection(viewRect: viewRect, window: window)
            }
            window.contentView = view
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            windows.append(window)
        }

        NSCursor.crosshair.push()

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // ESC
                self?.hide()
                return nil
            }
            return event
        }
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false

        NSCursor.pop()
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows = []
    }

    // MARK: - Capture

    private func captureSelection(viewRect: NSRect, window: NSWindow) {
        guard !isCapturing, let screen = window.screen ?? NSScreen.main else { return }
        isCapturing = true

        // View → Cocoa global (bottom-left origin) coordinates.
        let windowRect = window.contentView?.convert(viewRect, to: nil) ?? viewRect
        let cocoaOrigin = window.convertPoint(toScreen: NSPoint(x: windowRect.minX, y: windowRect.minY))
        let cocoaRect = CGRect(origin: cocoaOrigin, size: windowRect.size)

        Task { [weak self] in
            guard let self else { return }
            defer { self.isCapturing = false }

            // Drop the overlay out of the frame before capturing.
            let visibleWindows = self.windows
            for overlay in visibleWindows { overlay.orderOut(nil) }
            defer {
                if self.isVisible {
                    for overlay in visibleWindows { overlay.orderFrontRegardless() }
                }
            }
            try? await Task.sleep(for: .milliseconds(80))

            do {
                let image = try await Self.captureRegion(cocoaRect: cocoaRect, screen: screen)
                let fileURL = try self.savePNG(image)
                let ocrText = await Self.recognizeText(in: image)
                self.onCapture?(fileURL, ocrText)
                NSSound(named: "Pop")?.play()
            } catch {
                NSLog("[Silky] Note screenshot capture failed: %@", String(describing: error))
            }
        }
    }

    /// Capture a Cocoa-global rect from the display backing `screen`.
    private static func captureRegion(cocoaRect: CGRect, screen: NSScreen) async throws -> CGImage {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            throw CocoaError(.featureUnsupported)
        }

        // Cocoa global (bottom-left origin, y up) → CG global (top-left origin, y down).
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        let cgGlobalRect = CGRect(
            x: cocoaRect.minX,
            y: primaryHeight - cocoaRect.maxY,
            width: cocoaRect.width,
            height: cocoaRect.height
        )

        // CG global → display-relative points for SCStreamConfiguration.sourceRect.
        let displayBounds = CGDisplayBounds(displayID)
        let sourceRect = cgGlobalRect.offsetBy(dx: -displayBounds.minX, dy: -displayBounds.minY)

        let content = try await SCShareableContent.current
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CocoaError(.featureUnsupported)
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        let scale = screen.backingScaleFactor
        configuration.sourceRect = sourceRect
        configuration.width = Int(sourceRect.width * scale)
        configuration.height = Int(sourceRect.height * scale)
        configuration.showsCursor = false
        configuration.captureResolution = .best

        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    private func savePNG(_ image: CGImage) throws -> URL {
        guard let directory = try attachmentsDirectoryProvider?() else {
            throw CocoaError(.fileNoSuchFile)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HHmmss"
        var name = "\(formatter.string(from: .now)).png"
        var fileURL = directory.appendingPathComponent(name)
        var counter = 1
        while FileManager.default.fileExists(atPath: fileURL.path) {
            name = "\(formatter.string(from: .now))-\(counter).png"
            fileURL = directory.appendingPathComponent(name)
            counter += 1
        }

        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: fileURL)
        return fileURL
    }

    // MARK: - OCR

    private static func recognizeText(in image: CGImage) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                let handler = VNImageRequestHandler(cgImage: image)
                do {
                    try handler.perform([request])
                    let lines = (request.results ?? [])
                        .compactMap { $0.topCandidates(1).first?.string }
                    continuation.resume(returning: lines.joined(separator: "\n"))
                } catch {
                    continuation.resume(returning: "")
                }
            }
        }
    }
}
