import AppKit
import AVFoundation
import os

// MARK: - WebcamPreviewView

private final class WebcamPreviewView: NSView {

    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var borderLayer: CAShapeLayer?
    private let minDiameter: CGFloat = 60
    private let maxDiameter: CGFloat = 300

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupCircularMask()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        previewLayer.frame = bounds
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.cornerRadius = bounds.width / 2
        previewLayer.masksToBounds = true
        layer?.addSublayer(previewLayer)

        // Add white border
        let border = CAShapeLayer()
        border.path = CGPath(ellipseIn: bounds, transform: nil)
        border.strokeColor = NSColor.white.cgColor
        border.fillColor = nil
        border.lineWidth = 2
        layer?.addSublayer(border)
        self.borderLayer = border

        // Drop shadow on the view's layer
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.4
        layer?.shadowRadius = 8
        layer?.shadowOffset = NSSize(width: 0, height: -2)
    }

    override func layout() {
        super.layout()
        let diameter = bounds.width
        layer?.cornerRadius = diameter / 2
        layer?.masksToBounds = false

        previewLayer?.frame = bounds
        previewLayer?.cornerRadius = diameter / 2

        borderLayer?.path = CGPath(ellipseIn: bounds, transform: nil)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let window = self.window else { return }

        let delta = event.scrollingDeltaY
        let currentSize = window.frame.size.width
        let newDiameter = max(minDiameter, min(maxDiameter, currentSize + delta))

        // Resize keeping center
        let centerX = window.frame.midX
        let centerY = window.frame.midY
        let newOrigin = NSPoint(
            x: centerX - newDiameter / 2,
            y: centerY - newDiameter / 2
        )
        let newFrame = NSRect(origin: newOrigin, size: NSSize(width: newDiameter, height: newDiameter))
        window.setFrame(newFrame, display: true)
    }

    private func setupCircularMask() {
        guard let layer else { return }
        layer.cornerRadius = bounds.width / 2
        layer.masksToBounds = true
    }
}

// MARK: - WebcamOverlayController

@MainActor
final class WebcamOverlayController {

    private var panel: NSPanel?
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.kinshasa",
        category: "WebcamOverlay"
    )

    /// The current origin of the webcam panel (reflects user drag).
    var currentOrigin: NSPoint? {
        panel?.frame.origin
    }

    // MARK: - Show

    func show(service: WebcamCaptureService, origin: NSPoint?, diameter: CGFloat) {
        if panel != nil { return }

        guard let previewLayer = service.previewLayer else { return }

        let panelSize = NSSize(width: diameter, height: diameter)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true

        let previewView = WebcamPreviewView(frame: NSRect(origin: .zero, size: panelSize))
        previewView.configure(previewLayer: previewLayer)
        panel.contentView = previewView

        if let origin {
            panel.setFrameOrigin(origin)
        } else {
            // Default to bottom-left of screen
            let screen = NSScreen.main ?? NSScreen.screens.first
            let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let margin: CGFloat = 20
            panel.setFrameOrigin(NSPoint(x: visibleFrame.minX + margin, y: visibleFrame.minY + margin))
        }
        panel.orderFrontRegardless()

        self.panel = panel
    }

    // MARK: - Resize

    func resize(diameter: CGFloat) {
        guard let panel else { return }
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let newOrigin = NSPoint(x: center.x - diameter / 2, y: center.y - diameter / 2)
        panel.setFrame(NSRect(origin: newOrigin, size: NSSize(width: diameter, height: diameter)), display: true)
    }

    // MARK: - Hide

    func hide() {
        panel?.contentView = nil
        panel?.orderOut(nil)
        panel = nil
    }
}
