import AppKit

// MARK: - RegionSelectionView

private final class RegionSelectionView: NSView {

    var onComplete: ((CGRect?) -> Void)?

    private var dragOrigin: NSPoint?
    private var currentRect: NSRect = .zero
    private var isShiftHeld: Bool = false

    private let dimensionsLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.backgroundColor = NSColor.black.withAlphaComponent(0.7)
        label.drawsBackground = true
        label.isBezeled = false
        label.alignment = .center
        label.sizeToFit()
        return label
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(dimensionsLabel)
        dimensionsLabel.isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        dragOrigin = convert(event.locationInWindow, from: nil)
        currentRect = .zero
        isShiftHeld = event.modifierFlags.contains(.shift)
        setNeedsDisplay(bounds)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin else { return }
        let current = convert(event.locationInWindow, from: nil)
        isShiftHeld = event.modifierFlags.contains(.shift)

        let width = current.x - origin.x
        var height = current.y - origin.y

        if isShiftHeld {
            height = snapToAspectRatio(width: abs(width), height: abs(height)) * (height < 0 ? -1 : 1)
        }

        let x = width >= 0 ? origin.x : origin.x + width
        let y = height >= 0 ? origin.y : origin.y + height

        currentRect = NSRect(x: x, y: y, width: abs(width), height: abs(height))

        // Update dimensions label
        let displayWidth = Int(abs(width))
        let displayHeight = Int(abs(height))
        dimensionsLabel.stringValue = "  \(displayWidth) x \(displayHeight)  "
        dimensionsLabel.sizeToFit()
        dimensionsLabel.frame.origin = NSPoint(
            x: currentRect.midX - dimensionsLabel.frame.width / 2,
            y: currentRect.maxY + 6
        )
        dimensionsLabel.isHidden = false

        setNeedsDisplay(bounds)
    }

    override func mouseUp(with event: NSEvent) {
        _ = event
        dimensionsLabel.isHidden = true

        if currentRect.width > 10, currentRect.height > 10 {
            // Convert from view coordinates to screen coordinates (flip Y)
            let screenRect = convertToScreenCoordinates(currentRect)
            onComplete?(screenRect)
        } else {
            onComplete?(nil)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Semi-transparent overlay
        NSColor.black.withAlphaComponent(0.3).setFill()
        dirtyRect.fill()

        guard currentRect.width > 0, currentRect.height > 0 else { return }

        // Clear the selection area
        NSGraphicsContext.current?.cgContext.clear(currentRect)

        // Draw white-filled selection rect with transparency
        NSColor.white.withAlphaComponent(0.3).setFill()
        currentRect.fill()

        // White border
        NSColor.white.setStroke()
        let borderPath = NSBezierPath(rect: currentRect)
        borderPath.lineWidth = 1.5
        borderPath.stroke()
    }

    // MARK: - Aspect Ratio Snapping

    private func snapToAspectRatio(width: CGFloat, height: CGFloat) -> CGFloat {
        guard width > 0 else { return height }

        let currentRatio = width / max(height, 1)

        struct AspectRatio {
            let width: CGFloat
            let height: CGFloat
            var ratio: CGFloat { width / height }
        }

        let ratios: [AspectRatio] = [
            AspectRatio(width: 16, height: 9),
            AspectRatio(width: 4, height: 3),
            AspectRatio(width: 1, height: 1),
            AspectRatio(width: 9, height: 16),
        ]

        var closestRatio = currentRatio
        var minDifference: CGFloat = .greatestFiniteMagnitude

        for aspectRatio in ratios {
            let diff = abs(currentRatio - aspectRatio.ratio)
            if diff < minDifference {
                minDifference = diff
                closestRatio = aspectRatio.ratio
            }
        }

        return width / closestRatio
    }

    // MARK: - Coordinate Conversion

    private func convertToScreenCoordinates(_ rect: NSRect) -> CGRect {
        guard let window = self.window, let screen = window.screen ?? NSScreen.main else {
            return rect
        }

        // Convert from view coordinates to window coordinates
        let windowRect = convert(rect, to: nil)

        // Convert from window coordinates to screen coordinates
        let screenOrigin = window.convertPoint(toScreen: NSPoint(x: windowRect.minX, y: windowRect.minY))
        let screenTopRight = window.convertPoint(toScreen: NSPoint(x: windowRect.maxX, y: windowRect.maxY))

        // Flip Y for CGRect screen coordinates (origin at top-left)
        let screenHeight = screen.frame.height
        let flippedY = screenHeight - screenTopRight.y

        return CGRect(
            x: screenOrigin.x,
            y: flippedY,
            width: screenTopRight.x - screenOrigin.x,
            height: screenTopRight.y - screenOrigin.y
        )
    }
}

// MARK: - RegionSelectionController

@MainActor
final class RegionSelectionController {

    private var window: NSWindow?
    private var completion: ((CGRect?) -> Void)?
    private var eventMonitor: Any?

    // MARK: - Select Region

    func selectRegion(completion: @escaping (CGRect?) -> Void) {
        self.completion = completion

        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            completion(nil)
            return
        }

        let screenFrame = screen.frame

        let window = NSWindow(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces]
        window.ignoresMouseEvents = false

        let selectionView = RegionSelectionView(frame: NSRect(origin: .zero, size: screenFrame.size))
        selectionView.onComplete = { [weak self] rect in
            self?.finish(with: rect)
        }
        window.contentView = selectionView

        window.setFrame(screenFrame, display: true)
        window.makeKeyAndOrderFront(nil)

        // Crosshair cursor
        NSCursor.crosshair.push()

        // ESC key monitor
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // ESC
                self?.finish(with: nil)
                return nil
            }
            return event
        }

        self.window = window
    }

    // MARK: - Finish

    func finish(with rect: CGRect?) {
        NSCursor.pop()

        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }

        window?.close()
        window = nil

        let completionHandler = completion
        completion = nil
        completionHandler?(rect)
    }
}
