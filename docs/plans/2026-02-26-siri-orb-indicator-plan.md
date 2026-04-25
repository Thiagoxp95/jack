# Siri-Inspired Orb Indicator Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the notch-hugging recording indicator with a Siri-inspired glowing orb at the bottom of the screen, using space color and icon.

**Architecture:** Rewrite `FloatingBubbleController.swift` in place. Delete `VoiceWaveView` and `NotchIndicatorContentView`, replace with `SiriOrbView` that uses Core Animation gradient layers for the swirling glow effect. Keep the same public API so `DictationController` requires zero changes.

**Tech Stack:** AppKit, Core Animation (`CAGradientLayer`, `CABasicAnimation`), `NSPanel`

---

### Task 1: Replace VoiceWaveView and NotchIndicatorContentView with SiriOrbView

**Files:**
- Rewrite: `Sources/JackApp/FloatingBubbleController.swift` (entire file)

**Step 1: Write the new SiriOrbView class**

Replace everything from line 1 through line 403 (the old `VoiceWaveView` and `NotchIndicatorContentView` classes) with the new `SiriOrbView`. This is a single `NSView` subclass with these layers:

```swift
import AppKit
import Foundation

// MARK: - SiriOrbView

/// Siri-inspired glowing orb indicator.
/// Layers (bottom to top): glow → dark glass base → rotating gradient → space icon.
/// Voice amplitude drives glow radius/brightness, gradient rotation speed, and icon brightness.
private final class SiriOrbView: NSView {

    // MARK: - Configuration

    /// Diameter of the inner orb (not including glow). Set externally.
    var orbDiameter: CGFloat = 72 {
        didSet { needsLayout = true }
    }

    // MARK: - Layers

    /// Soft radial glow behind the orb — voice-reactive radius & opacity.
    private let glowLayer = CAGradientLayer()

    /// Dark glass circle — the orb body.
    private let orbLayer = CALayer()

    /// Rotating gradient overlay on the orb — swirling color effect.
    private let gradientLayer = CAGradientLayer()

    /// Mask to clip the gradient to a circle.
    private let gradientMask = CAShapeLayer()

    /// SF Symbol icon (image layer).
    private let iconImageView = NSImageView()

    /// Emoji label (for emoji-type space icons).
    private let iconEmojiLabel = NSTextField(labelWithString: "")

    // MARK: - State

    private var spaceColor: NSColor = .systemBlue
    private var displayedLevel: CGFloat = 0
    private var targetLevel: CGFloat = 0
    private var displayedIconLevel: CGFloat = 0
    private var lastLevelUpdateUptime: TimeInterval?
    private var animationTimer: Timer?
    private var gradientRotation: CGFloat = 0
    private var currentIsNoteMode = false
    private var savedSpaceIcon: SpaceIcon?

    // MARK: - Init

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

        // --- Glow layer (radial gradient) ---
        glowLayer.type = .radial
        glowLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        glowLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
        glowLayer.opacity = 0.3
        updateGlowColors()
        layer?.addSublayer(glowLayer)

        // --- Orb body (dark glass) ---
        orbLayer.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        orbLayer.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        orbLayer.borderWidth = 0.5
        layer?.addSublayer(orbLayer)

        // --- Gradient overlay (conic rotating) ---
        gradientLayer.type = .conic
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 0)
        updateGradientColors()
        gradientLayer.mask = gradientMask
        layer?.addSublayer(gradientLayer)

        // --- Icon (SF Symbol) ---
        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        iconImageView.contentTintColor = NSColor.white.withAlphaComponent(0.5)
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconImageView)

        // --- Icon (Emoji) ---
        iconEmojiLabel.font = NSFont.systemFont(ofSize: 24)
        iconEmojiLabel.textColor = .white
        iconEmojiLabel.backgroundColor = .clear
        iconEmojiLabel.isBezeled = false
        iconEmojiLabel.isEditable = false
        iconEmojiLabel.isSelectable = false
        iconEmojiLabel.alignment = .center
        iconEmojiLabel.isHidden = true
        iconEmojiLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconEmojiLabel)

        // Icon constraints — centered in view
        NSLayoutConstraint.activate([
            iconImageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 28),
            iconImageView.heightAnchor.constraint(equalToConstant: 28),

            iconEmojiLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconEmojiLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        startAnimationTimer()
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        layoutLayers()
    }

    private func layoutLayers() {
        let bounds = self.bounds
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let orbRadius = orbDiameter / 2

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Glow: extends beyond orb
        let glowPadding = orbDiameter * 0.4
        let glowSize = orbDiameter + glowPadding * 2
        glowLayer.frame = CGRect(
            x: center.x - glowSize / 2,
            y: center.y - glowSize / 2,
            width: glowSize,
            height: glowSize
        )
        glowLayer.cornerRadius = glowSize / 2

        // Orb body
        orbLayer.frame = CGRect(
            x: center.x - orbRadius,
            y: center.y - orbRadius,
            width: orbDiameter,
            height: orbDiameter
        )
        orbLayer.cornerRadius = orbRadius

        // Gradient overlay (same size as orb)
        gradientLayer.frame = orbLayer.frame
        gradientMask.frame = gradientLayer.bounds
        gradientMask.path = CGPath(
            ellipseIn: gradientLayer.bounds, transform: nil
        )

        CATransaction.commit()

        // Update icon size proportionally
        let iconSize = max(16, orbDiameter * 0.38)
        for constraint in iconImageView.constraints {
            if constraint.firstAttribute == .width || constraint.firstAttribute == .height {
                constraint.constant = iconSize
            }
        }
        iconImageView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: iconSize * 0.7, weight: .semibold
        )
        iconEmojiLabel.font = NSFont.systemFont(ofSize: iconSize * 0.85)
    }

    // MARK: - Update

    func update(isRecording: Bool, isTranscribing: Bool, isNoteMode: Bool, level: Double, shouldPulse: Bool) {
        let normalizedLevel = max(0, min(1, level))
        let isActive = isRecording || isTranscribing

        // Note mode icon swap
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

        // Voice level target
        let gated: CGFloat = normalizedLevel <= 0.07 ? 0 : (CGFloat(normalizedLevel) - 0.07) / 0.93
        targetLevel = isActive ? pow(gated, 0.8) : 0

        // Icon brightness
        updateIconBrightness(level: normalizedLevel, active: isActive)

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

    // MARK: - Private helpers

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

    private func updateGlowColors() {
        glowLayer.colors = [
            spaceColor.withAlphaComponent(0.6).cgColor,
            spaceColor.withAlphaComponent(0.2).cgColor,
            NSColor.clear.cgColor,
        ]
        glowLayer.locations = [0.0, 0.5, 1.0]
    }

    private func updateGradientColors() {
        // Conic gradient: space color through lighter and darker shades
        let lighter = spaceColor.blended(withFraction: 0.4, of: .white) ?? spaceColor
        let darker = spaceColor.blended(withFraction: 0.3, of: .black) ?? spaceColor
        let accent = spaceColor.blended(withFraction: 0.5, of: .systemPurple) ?? spaceColor

        gradientLayer.colors = [
            spaceColor.withAlphaComponent(0.6).cgColor,
            lighter.withAlphaComponent(0.5).cgColor,
            accent.withAlphaComponent(0.4).cgColor,
            darker.withAlphaComponent(0.5).cgColor,
            spaceColor.withAlphaComponent(0.6).cgColor,
        ]
    }

    private func updateIconBrightness(level: Double, active: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        let dt: CGFloat
        if let last = lastLevelUpdateUptime {
            dt = max(1 / 180, min(0.1, CGFloat(now - last)))
        } else {
            dt = 1 / 60
        }
        lastLevelUpdateUptime = now

        let clamped = max(0, min(1, CGFloat(level)))
        let gated: CGFloat = clamped <= 0.07 ? 0 : (clamped - 0.07) / 0.93
        let target: CGFloat = active ? pow(gated, 1.4) : 0

        if target == 0 {
            displayedIconLevel = 0
        } else {
            let tau: CGFloat = 0.008
            let alpha = 1 - exp(-dt / max(0.001, tau))
            displayedIconLevel += (target - displayedIconLevel) * alpha
        }

        let baseAlpha: CGFloat = active ? 0.7 : 0.5
        let iconAlpha = baseAlpha + displayedIconLevel * (1.0 - baseAlpha)

        iconImageView.contentTintColor = active
            ? NSColor.white.withAlphaComponent(iconAlpha)
            : NSColor.white.withAlphaComponent(0.5)

        iconEmojiLabel.alphaValue = active ? iconAlpha : 0.5
    }

    private func runPulseAnimation() {
        guard let layer else { return }
        layer.removeAnimation(forKey: "orb-pulse")

        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = 1.0
        animation.toValue = 1.03
        animation.duration = 0.15
        animation.autoreverses = true
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "orb-pulse")
    }

    // MARK: - Animation Timer (30 FPS)

    private func startAnimationTimer() {
        animationTimer?.invalidate()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stopAnimationTimer() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func tick() {
        // Smooth level
        let alpha: CGFloat = 0.08
        displayedLevel += (targetLevel - displayedLevel) * alpha
        if displayedLevel < 0.005 { displayedLevel = 0 }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // --- Glow: voice-reactive opacity and scale ---
        let glowBaseOpacity: Float = 0.3
        let glowMaxOpacity: Float = 0.8
        glowLayer.opacity = glowBaseOpacity + Float(displayedLevel) * (glowMaxOpacity - glowBaseOpacity)

        let glowScale: CGFloat = 1.0 + displayedLevel * 0.15
        glowLayer.transform = CATransform3DMakeScale(glowScale, glowScale, 1)

        // --- Gradient rotation: slow idle, faster when speaking ---
        let baseSpeed: CGFloat = 0.015       // ~4s per revolution at 30fps
        let maxSpeed: CGFloat = 0.08          // ~1.3s per revolution at peak
        let rotationSpeed = baseSpeed + displayedLevel * (maxSpeed - baseSpeed)
        gradientRotation += rotationSpeed
        gradientLayer.transform = CATransform3DMakeRotation(gradientRotation, 0, 0, 1)

        // --- Gradient opacity: more visible when speaking ---
        gradientLayer.opacity = Float(0.4 + displayedLevel * 0.5)

        CATransaction.commit()
    }
}
```

**Step 2: Rewrite FloatingBubbleController positioning**

Replace the `FloatingBubbleController` class (lines 405-705) with a simplified version. Key changes:
- Remove `NotchGeometry`, all notch detection
- Position panel at bottom center of screen
- Size based on `sizePercent` → orb diameter mapping

```swift
// MARK: - FloatingBubbleController

@MainActor
final class FloatingBubbleController {
    private let baseOrbDiameter: CGFloat = 72
    private let glowPaddingRatio: CGFloat = 0.4
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

        let screen = activeScreen()
        let panelSize = desiredPanelSize()

        let panel = ensurePanel(size: panelSize)

        // Reset opacity (cancel any fade-out)
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        panel.animator().alphaValue = 1
        NSAnimationContext.endGrouping()
        panel.alphaValue = 1

        // Apply pending appearance
        if let color = pendingSpaceColor, let icon = pendingSpaceIcon {
            orbView?.updateSpaceAppearance(color: color, icon: icon)
        }

        // Update orb diameter
        orbView?.orbDiameter = orbDiameter()

        // Size and position
        resize(panel, size: panelSize)
        positionAtBottom(panel, size: panelSize, on: screen)

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

    private func orbDiameter() -> CGFloat {
        baseOrbDiameter * CGFloat(sizePercent / 100.0)
    }

    private func desiredPanelSize() -> NSSize {
        let diameter = orbDiameter()
        let glowPadding = diameter * glowPaddingRatio
        let side = diameter + glowPadding * 2
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
        orbView.orbDiameter = orbDiameter()
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

    private func positionAtBottom(_ panel: NSPanel, size: NSSize, on preferredScreen: NSScreen? = nil) {
        guard let screen = preferredScreen ?? activeScreen() else { return }

        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - size.width / 2
        let y = screenFrame.origin.y + bottomOffset - (size.height - orbDiameter()) / 2
        panel.setFrameOrigin(NSPoint(x: x, y: y).integral())
    }

    private func repositionIfVisible() {
        guard let panel, panel.isVisible else { return }
        let size = desiredPanelSize()
        orbView?.orbDiameter = orbDiameter()
        resize(panel, size: size)
        positionAtBottom(panel, size: size)
    }

    private func cancelPendingHide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
    }

    private func activeScreen() -> NSScreen? {
        if let panelScreen = panel?.screen { return panelScreen }
        if let keyScreen = NSApp.keyWindow?.screen { return keyScreen }
        if let main = NSScreen.main { return main }
        return NSScreen.screens.first
    }
}
```

**Step 3: Build and verify**

Run: `swift build` (or the project's build script)
Expected: Compiles with no errors. DictationController needs zero changes.

**Step 4: Manual test**

1. Launch the app
2. Start dictation — orb should appear at bottom center
3. Speak — glow should expand, gradient should spin faster, icon should brighten
4. Stop — orb should disappear
5. Change space — orb color should update

**Step 5: Commit**

```bash
git add Sources/JackApp/FloatingBubbleController.swift
git commit -m "feat: replace notch indicator with Siri-inspired glowing orb

- Remove VoiceWaveView and NotchIndicatorContentView
- Add SiriOrbView with radial glow, rotating conic gradient, space icon
- Position at bottom center of screen
- Voice-reactive glow, rotation speed, and icon brightness
- User-configurable size via existing sizePercent setting
- Zero changes to DictationController integration"
```

### Task 2: Fix NSPoint.integral() if needed

**Files:**
- Modify: `Sources/JackApp/FloatingBubbleController.swift`

`NSPoint` doesn't have `.integral()` — the old code used `NSRect.integral`. If the build fails on this, replace `NSPoint(x: x, y: y).integral()` with:

```swift
NSPoint(x: round(x), y: round(y))
```

**Step 1: Fix and rebuild**

**Step 2: Commit if changed**

```bash
git add Sources/JackApp/FloatingBubbleController.swift
git commit -m "fix: use round() for panel origin instead of NSPoint.integral()"
```

### Task 3: Visual polish pass

After seeing the orb in action, likely tweaks:

**Potential adjustments:**
- Glow color opacity values
- Gradient rotation speed (base and max)
- Icon size ratio
- Bottom offset from screen edge
- Orb background opacity (darker/lighter glass)
- Border brightness

This is an iterative task — build, test visually, adjust constants, repeat.
