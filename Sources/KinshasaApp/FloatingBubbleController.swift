import AppKit
import Foundation

// MARK: - SiriOrbView

/// A circular glowing orb with voice-reactive animations.
/// Layers (back to front):
///   1. Radial glow — space color, voice-reactive opacity & scale
///   2. Dark glass orb body — black @ 0.7, circular, thin white border
///   3. Rotating conic gradient — space color shades, voice-reactive rotation speed
///   4. Space icon — SF Symbol or emoji, voice-reactive brightness
private final class SiriOrbView: NSView {
    // Layers
    private let glowLayer = CAGradientLayer()
    private let orbLayer = CALayer()
    private let gradientLayer = CAGradientLayer()
    private let gradientMaskLayer = CAShapeLayer()

    // Icon views — one visible at a time
    private let iconImageView = NSImageView()    // SF Symbol
    private let iconEmojiLabel = NSTextField(labelWithString: "")  // Emoji

    // State
    private var spaceColor: NSColor = .systemBlue
    private var currentIsNoteMode = false
    private var savedSpaceIcon: SpaceIcon?

    // Voice-reactive smoothing
    private var displayedLevel: CGFloat = 0
    private var displayedIconLevel: CGFloat = 0
    private var lastLevelUpdateUptime: TimeInterval?
    private var gradientAngle: CGFloat = 0

    // Animation timer (30 FPS)
    private var animationTimer: Timer?

    // Target level set by the controller
    private var targetLevel: CGFloat = 0
    private var isActive = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        // 1. Radial glow layer
        glowLayer.type = .radial
        glowLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        glowLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
        updateGlowColors()
        glowLayer.opacity = 0.3
        layer?.addSublayer(glowLayer)

        // 2. Orb body
        orbLayer.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        orbLayer.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        orbLayer.borderWidth = 0.5
        layer?.addSublayer(orbLayer)

        // 3. Conic gradient overlay
        gradientLayer.type = .conic
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 0)
        updateGradientColors()
        gradientLayer.opacity = 0.6
        gradientLayer.mask = gradientMaskLayer
        gradientMaskLayer.fillColor = NSColor.white.cgColor
        layer?.addSublayer(gradientLayer)

        // 4. Icon views
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        iconImageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        iconImageView.contentTintColor = NSColor.white.withAlphaComponent(0.35)
        addSubview(iconImageView)

        iconEmojiLabel.translatesAutoresizingMaskIntoConstraints = false
        iconEmojiLabel.font = NSFont.systemFont(ofSize: 22)
        iconEmojiLabel.textColor = .white
        iconEmojiLabel.backgroundColor = .clear
        iconEmojiLabel.isBezeled = false
        iconEmojiLabel.isEditable = false
        iconEmojiLabel.isSelectable = false
        iconEmojiLabel.alignment = .center
        iconEmojiLabel.isHidden = true
        addSubview(iconEmojiLabel)

        NSLayoutConstraint.activate([
            iconImageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 24),
            iconImageView.heightAnchor.constraint(equalToConstant: 24),

            iconEmojiLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconEmojiLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        // Set default icon
        if let img = NSImage(systemSymbolName: "building.2.fill", accessibilityDescription: "Space") {
            iconImageView.image = img
        }

        startAnimationTimer()
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        updateLayerFrames()
    }

    private func updateLayerFrames() {
        let bounds = self.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // The orb sits centered in the view.
        // The view includes glow padding on all sides.
        let orbDiameter = min(bounds.width, bounds.height) * (1.0 / 1.8)
        let orbRadius = orbDiameter / 2
        let orbOrigin = CGPoint(
            x: bounds.midX - orbRadius,
            y: bounds.midY - orbRadius
        )
        let orbRect = CGRect(origin: orbOrigin, size: CGSize(width: orbDiameter, height: orbDiameter))

        // Glow fills the entire view
        glowLayer.frame = bounds

        // Orb body
        orbLayer.frame = orbRect
        orbLayer.cornerRadius = orbRadius

        // Conic gradient — same size as orb
        gradientLayer.frame = orbRect
        let maskPath = CGPath(ellipseIn: CGRect(origin: .zero, size: orbRect.size), transform: nil)
        gradientMaskLayer.path = maskPath

        CATransaction.commit()
    }

    // MARK: - Public API

    func update(isRecording: Bool, isTranscribing: Bool, isNoteMode: Bool, level: Double, shouldPulse: Bool) {
        let normalizedLevel = max(0, min(1, CGFloat(level)))
        isActive = isRecording || isTranscribing

        // Detect note mode transitions
        if isNoteMode != currentIsNoteMode {
            currentIsNoteMode = isNoteMode
            if isNoteMode {
                if let img = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Note") {
                    iconImageView.image = img
                }
                iconImageView.isHidden = false
                iconEmojiLabel.isHidden = true
            } else if let saved = savedSpaceIcon {
                applyIcon(saved)
            }
            runPulseAnimation()
        }

        // Set target level for the animation timer to smooth
        targetLevel = normalizedLevel

        if shouldPulse {
            runPulseAnimation()
        }
    }

    func updateSpaceAppearance(color: NSColor, icon: SpaceIcon) {
        spaceColor = color
        savedSpaceIcon = icon
        updateGlowColors()
        updateGradientColors()

        guard !currentIsNoteMode else { return }
        applyIcon(icon)
    }

    func stopAnimationTimer() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    // MARK: - Animation Timer

    private func startAnimationTimer() {
        animationTimer?.invalidate()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.tick()
            }
        }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt: CGFloat
        if let last = lastLevelUpdateUptime {
            dt = max(1.0 / 180.0, min(0.1, CGFloat(now - last)))
        } else {
            dt = 1.0 / 60.0
        }
        lastLevelUpdateUptime = now

        // Voice level smoothing
        let clamped = max(0, min(1, targetLevel))
        let gated: CGFloat = clamped <= 0.07 ? 0 : (clamped - 0.07) / 0.93
        let target: CGFloat = isActive ? pow(gated, 0.8) : 0

        if target == 0 && displayedLevel < 0.005 {
            displayedLevel = 0
        } else {
            let tau: CGFloat = 0.008
            let alpha = 1 - exp(-dt / max(0.001, tau))
            displayedLevel += (target - displayedLevel) * alpha
        }

        // Icon brightness smoothing (same tau)
        let iconTarget: CGFloat = isActive ? pow(gated, 1.4) : 0
        if iconTarget == 0 && displayedIconLevel < 0.005 {
            displayedIconLevel = 0
        } else {
            let tau: CGFloat = 0.008
            let alpha = 1 - exp(-dt / max(0.001, tau))
            displayedIconLevel += (iconTarget - displayedIconLevel) * alpha
        }

        // Rotate conic gradient
        let idleRotationSpeed: CGFloat = 0.015
        let peakRotationSpeed: CGFloat = 0.08
        let rotationSpeed = idleRotationSpeed + (peakRotationSpeed - idleRotationSpeed) * displayedLevel
        gradientAngle += rotationSpeed

        applyAnimatedState()
    }

    private func applyAnimatedState() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Glow: opacity 0.3 idle -> 0.8 speaking, scale 1.0 -> 1.15
        let glowOpacity = Float(0.3 + displayedLevel * 0.5)
        glowLayer.opacity = glowOpacity
        let glowScale: CGFloat = 1.0 + displayedLevel * 0.15
        glowLayer.transform = CATransform3DMakeScale(glowScale, glowScale, 1)

        // Conic gradient rotation
        gradientLayer.transform = CATransform3DMakeRotation(gradientAngle, 0, 0, 1)

        // Icon brightness
        let baseAlpha: CGFloat = isActive ? 0.7 : 0.35
        let iconAlpha = baseAlpha + displayedIconLevel * (1.0 - baseAlpha)

        iconImageView.contentTintColor = isActive
            ? spaceColor.withAlphaComponent(iconAlpha)
            : NSColor.white.withAlphaComponent(0.35)
        iconEmojiLabel.alphaValue = isActive ? iconAlpha : 0.5

        CATransaction.commit()
    }

    // MARK: - Colors

    private func updateGlowColors() {
        glowLayer.colors = [
            spaceColor.withAlphaComponent(0.6).cgColor,
            spaceColor.withAlphaComponent(0.2).cgColor,
            NSColor.clear.cgColor,
        ]
        glowLayer.locations = [0.0, 0.4, 1.0]
    }

    private func updateGradientColors() {
        // Space color + lighter/darker/accent variants
        let lighter = spaceColor.blended(withFraction: 0.3, of: .white) ?? spaceColor
        let darker = spaceColor.blended(withFraction: 0.3, of: .black) ?? spaceColor
        let accent = spaceColor.blended(withFraction: 0.5, of: .cyan) ?? spaceColor

        gradientLayer.colors = [
            spaceColor.cgColor,
            lighter.cgColor,
            accent.cgColor,
            darker.cgColor,
            spaceColor.cgColor,
        ]
    }

    // MARK: - Icon

    private func applyIcon(_ icon: SpaceIcon) {
        switch icon {
        case .symbol(let name):
            if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
                iconImageView.image = img
            }
            iconImageView.isHidden = false
            iconEmojiLabel.isHidden = true
        case .emoji(let char):
            iconEmojiLabel.stringValue = char
            iconImageView.isHidden = true
            iconEmojiLabel.isHidden = false
        }
    }

    // MARK: - Pulse

    private func runPulseAnimation() {
        guard let layer = orbLayer.superlayer else { return }
        orbLayer.removeAnimation(forKey: "orb-pulse")

        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = 1.0
        animation.toValue = 1.04
        animation.duration = 0.12
        animation.autoreverses = true
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        orbLayer.add(animation, forKey: "orb-pulse")
        _ = layer // silence unused variable warning
    }
}

// MARK: - FloatingBubbleController

@MainActor
final class FloatingBubbleController {
    private let baseOrbDiameter: CGFloat = 72
    private let bottomOffset: CGFloat = 48

    private var panel: NSPanel?
    private var orbView: SiriOrbView?
    private var currentIsRecording = false
    private var currentIsTranscribing = false
    private var currentIsNoteMode = false
    private var currentLevel: Double = 0
    private var hideWorkItem: DispatchWorkItem?
    private var pendingSpaceColor: NSColor?
    private var pendingSpaceIcon: SpaceIcon?
    private var sizePercent: Double = 100

    // MARK: - Public API

    func setPresentation(position _: FloatingIndicatorPosition, sizePercent: Double) {
        self.sizePercent = sizePercent
        repositionIfVisible()
    }

    func setSpaceAppearance(color: NSColor, icon: SpaceIcon) {
        pendingSpaceColor = color
        pendingSpaceIcon = icon
        orbView?.updateSpaceAppearance(color: color, icon: icon)
    }

    func show(
        message _: String,
        isRecording: Bool,
        isTranscribing: Bool,
        isNoteMode: Bool = false,
        riveAssetPath _: String?,
        htmlIndicatorMarkup _: String?,
        useBuiltInWaveIndicator _: Bool
    ) {
        cancelPendingHide()
        currentIsRecording = isRecording
        currentIsTranscribing = isTranscribing
        currentIsNoteMode = isNoteMode

        let panelSize = computePanelSize()
        let panel = ensurePanel(size: panelSize)

        // Cancel any in-progress fade-out and restore full opacity
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        panel.animator().alphaValue = 1
        NSAnimationContext.endGrouping()
        panel.alphaValue = 1

        // Re-apply pending space appearance
        if let color = pendingSpaceColor, let icon = pendingSpaceIcon {
            orbView?.updateSpaceAppearance(color: color, icon: icon)
        }

        // Resize and position
        let size = computePanelSize()
        resize(panel, size: size)
        positionPanel(panel, size: size)

        orbView?.update(
            isRecording: isRecording,
            isTranscribing: isTranscribing,
            isNoteMode: isNoteMode,
            level: currentLevel,
            shouldPulse: false
        )

        panel.orderFrontRegardless()
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        cancelPendingHide()

        panel.alphaValue = 0
        panel.orderOut(nil)
        panel.alphaValue = 1
    }

    func updateRiveReactiveInputs(listening: Bool, level: Double, shouldPulse: Bool) {
        applyReactiveUpdate(listening: listening, transcribing: false, level: level, shouldPulse: shouldPulse)
    }

    func updateHTMLReactiveInputs(listening: Bool, transcribing: Bool, level: Double, shouldPulse: Bool) {
        applyReactiveUpdate(listening: listening, transcribing: transcribing, level: level, shouldPulse: shouldPulse)
    }

    func updateWaveReactiveInputs(listening: Bool, transcribing: Bool, level: Double, shouldPulse: Bool) {
        applyReactiveUpdate(listening: listening, transcribing: transcribing, level: level, shouldPulse: shouldPulse)
    }

    // MARK: - Private

    private func applyReactiveUpdate(listening: Bool, transcribing: Bool, level: Double, shouldPulse: Bool) {
        currentLevel = max(0, min(1, level))
        currentIsRecording = listening
        currentIsTranscribing = transcribing

        orbView?.update(
            isRecording: currentIsRecording,
            isTranscribing: currentIsTranscribing,
            isNoteMode: currentIsNoteMode,
            level: currentLevel,
            shouldPulse: shouldPulse
        )
    }

    private func computeOrbDiameter() -> CGFloat {
        baseOrbDiameter * CGFloat(sizePercent / 100.0)
    }

    private func computePanelSize() -> NSSize {
        let orbDiameter = computeOrbDiameter()
        let glowPadding = orbDiameter * 0.4
        let side = orbDiameter + glowPadding * 2
        return NSSize(width: side, height: side)
    }

    private func ensurePanel(size: NSSize) -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true

        let orbView = SiriOrbView(frame: NSRect(origin: .zero, size: size))
        panel.contentView = orbView
        self.orbView = orbView
        self.panel = panel

        if let color = pendingSpaceColor, let icon = pendingSpaceIcon {
            orbView.updateSpaceAppearance(color: color, icon: icon)
        }

        return panel
    }

    private func resize(_ panel: NSPanel, size: NSSize) {
        let frame = NSRect(origin: panel.frame.origin, size: size)
        panel.setFrame(frame, display: true)
        panel.contentView?.frame = NSRect(origin: .zero, size: size)
    }

    private func positionPanel(_ panel: NSPanel, size: NSSize) {
        guard let screen = activeScreen() else { return }

        let visibleFrame = screen.visibleFrame
        let x = round(visibleFrame.midX - size.width / 2)
        let y = round(visibleFrame.origin.y + bottomOffset)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func repositionIfVisible() {
        guard let panel, panel.isVisible else { return }
        let size = computePanelSize()
        resize(panel, size: size)
        positionPanel(panel, size: size)
    }

    private func cancelPendingHide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
    }

    private func activeScreen() -> NSScreen? {
        if let panelScreen = panel?.screen {
            return panelScreen
        }
        if let keyScreen = NSApp.keyWindow?.screen {
            return keyScreen
        }
        if let main = NSScreen.main {
            return main
        }
        return NSScreen.screens.first
    }
}
