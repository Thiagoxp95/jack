import AppKit
import Foundation

// MARK: - PillIndicatorView

/// Floating pill indicator: space icon on the left, Slack-style vertical voice bars on the right.
/// Solid black background with full-pill corner radius.
private final class PillIndicatorView: NSView {
    private static let fallbackSpaceImage = NSImage(systemSymbolName: "building.2.fill", accessibilityDescription: "Space")
    private static let noteImage = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Note")
    private static let todoImage = NSImage(systemSymbolName: "checklist", accessibilityDescription: "Todo")
    private static let aiImage = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "AI")

    // Voice state
    private var volumeLevel: CGFloat = 0
    private var targetVolume: CGFloat = 0
    private var isActive = false
    private var isListening = false
    private var usesActiveAppearance = false
    private var animationTime: CGFloat = 0

    // Voice bar layers (vertical bars like Slack)
    private let barCount = 5
    private var barLayers: [CALayer] = []

    // Background
    private let bgLayer = CALayer()

    // Space icon
    private let iconImageView = NSImageView()
    private let iconEmojiLabel = NSTextField(labelWithString: "")
    private var currentMode: Int = 0  // 0=space, 1=note, 2=todo, 3=ai
    private var savedSpaceIcon: SpaceIcon?
    private var spaceColor: NSColor = .systemBlue

    // Blocked state: the speech model is still downloading, so the bars are
    // replaced by the percentage and the icon becomes a blocker.
    private static let blockedEmoji = "🚫"
    private let progressLabel = NSTextField(labelWithString: "")
    private var blockedPercent: Int?

    // Animation timer
    private var displayTimer: Timer?
    /// Wall-clock stamp of the previous tick. The timer is a best-effort 60Hz
    /// that slips whenever the main run loop is busy — local transcription
    /// running mid-dictation is enough to do it — so every rate below is
    /// expressed per second and integrated against the real elapsed time.
    private var lastTickAt: CFTimeInterval = 0

    /// Volume smoothing rates, per second. Rise fast on a syllable onset, fall
    /// gently after it. `1 - exp(-34/60) ≈ 0.43` and `1 - exp(-11/60) ≈ 0.17`,
    /// so a healthy 60Hz tick behaves as before.
    private static let volumeAttackRate: CGFloat = 34
    private static let volumeReleaseRate: CGFloat = 11

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

        // Solid black pill background
        bgLayer.backgroundColor = NSColor.black.cgColor
        bgLayer.masksToBounds = true
        layer?.addSublayer(bgLayer)

        // Space icon (SF Symbol)
        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        iconImageView.contentTintColor = .white
        addSubview(iconImageView)

        // Space icon (emoji)
        iconEmojiLabel.textColor = .white
        iconEmojiLabel.backgroundColor = .clear
        iconEmojiLabel.isBezeled = false
        iconEmojiLabel.isEditable = false
        iconEmojiLabel.isSelectable = false
        iconEmojiLabel.alignment = .center
        iconEmojiLabel.isHidden = true
        addSubview(iconEmojiLabel)

        // Download percentage, shown where the voice bars normally sit
        progressLabel.textColor = .white
        progressLabel.backgroundColor = .clear
        progressLabel.isBezeled = false
        progressLabel.isEditable = false
        progressLabel.isSelectable = false
        progressLabel.alignment = .right
        progressLabel.isHidden = true
        addSubview(progressLabel)

        // Voice bars — thin vertical rounded rectangles
        for _ in 0..<barCount {
            let bar = CALayer()
            bar.backgroundColor = NSColor.white.withAlphaComponent(0.5).cgColor
            layer?.addSublayer(bar)
            barLayers.append(bar)
        }

        iconImageView.image = Self.fallbackSpaceImage
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        layoutElements()
    }

    private func layoutElements() {
        let h = bounds.height
        let w = bounds.width
        guard h > 0, w > 0 else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Background
        bgLayer.frame = bounds
        bgLayer.cornerRadius = h / 2

        // Icon on the left
        let iconSize = round(h * 0.45)
        let iconX = round(h * 0.32)
        let iconY = round((h - iconSize) / 2)
        iconImageView.frame = NSRect(x: iconX, y: iconY, width: iconSize, height: iconSize)
        iconImageView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: round(iconSize * 0.85), weight: .semibold
        )
        // Emoji glyphs run wider and taller than their point size, so the label
        // gets its own box around the icon's centre rather than the icon frame.
        let emojiFontSize = round(iconSize * 0.9)
        let emojiWidth = round(emojiFontSize * 1.5)
        let emojiHeight = round(emojiFontSize * 1.35)
        iconEmojiLabel.frame = NSRect(
            x: round(iconX + (iconSize - emojiWidth) / 2),
            y: round(iconY + (iconSize - emojiHeight) / 2),
            width: emojiWidth,
            height: emojiHeight
        )
        iconEmojiLabel.font = NSFont.systemFont(ofSize: emojiFontSize)

        // Voice bars on the right
        let barWidth = round(h * 0.07)
        let barGap = round(h * 0.09)
        let barCorner = barWidth / 2
        let minBarH = round(h * 0.12)
        let totalBarsWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap
        let barsEndX = w - round(h * 0.35)
        let barsStartX = barsEndX - totalBarsWidth
        let barCenterY = h / 2

        for (i, bar) in barLayers.enumerated() {
            let x = barsStartX + CGFloat(i) * (barWidth + barGap)
            bar.frame = NSRect(x: x, y: barCenterY - minBarH / 2, width: barWidth, height: minBarH)
            bar.cornerRadius = barCorner
        }

        // Percentage occupies the whole strip between the icon and the bars'
        // right edge, so it stays put as the digits change.
        let labelFontSize = round(h * 0.26)
        let labelHeight = round(labelFontSize * 1.4)
        let labelX = iconX + iconSize + round(h * 0.18)
        progressLabel.font = NSFont.monospacedDigitSystemFont(ofSize: labelFontSize, weight: .semibold)
        progressLabel.frame = NSRect(
            x: labelX,
            y: round((h - labelHeight) / 2),
            width: max(0, barsEndX - labelX),
            height: labelHeight
        )

        CATransaction.commit()
    }

    // MARK: - Animation

    func startAnimating() {
        guard displayTimer == nil else { return }
        lastTickAt = 0
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    func stopAnimating() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    private func tick() {
        guard blockedPercent == nil else { return }

        // Advance on real elapsed time, not on a hoped-for 1/60. Assuming the
        // nominal interval meant that whenever the run loop got busy the wave
        // slowed down in lockstep with the dropped frames and the smoothing
        // stretched out — the bars went sluggish exactly when the app was
        // working hardest, which is a few seconds into a dictation. Capped so
        // a long stall resumes rather than jumping.
        let now = CACurrentMediaTime()
        let dt = lastTickAt == 0 ? 1.0 / 60.0 : min(0.25, now - lastTickAt)
        lastTickAt = now

        animationTime += CGFloat(dt)
        if animationTime > 1000 { animationTime -= 1000 }

        // Smooth volume toward target. Asymmetric on purpose: the controller
        // already smooths the level, so all this needs to do is take the step
        // out of the 30ms polls. A symmetric lerp here was a second lag stage
        // on top of that one, and between them the bars stopped tracking
        // individual syllables at all.
        let rate = targetVolume > volumeLevel ? Self.volumeAttackRate : Self.volumeReleaseRate
        let k = 1 - exp(-rate * CGFloat(dt))
        volumeLevel += (targetVolume - volumeLevel) * k
        if volumeLevel < 0.005 { volumeLevel = 0 }

        let h = bounds.height
        guard h > 0 else { return }

        let barWidth = round(h * 0.07)
        let barGap = round(h * 0.09)
        let barCorner = barWidth / 2
        let minBarH = round(h * 0.12)
        let maxBarH = h * 0.65
        let barCenterY = h / 2

        let totalBarsWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap
        let barsEndX = bounds.width - round(h * 0.35)
        let barsStartX = barsEndX - totalBarsWidth

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        for (i, bar) in barLayers.enumerated() {
            // Each bar gets a different phase for the wave effect
            let phase = CGFloat(i) * 1.1
            // Bars animate at different frequencies for organic feel
            let freq1: CGFloat = 3.5 + CGFloat(i) * 0.4
            let freq2: CGFloat = 5.2 - CGFloat(i) * 0.3

            let wave = (sin(animationTime * freq1 + phase) + sin(animationTime * freq2 + phase * 0.7)) / 2.0

            let idleBarH = minBarH + abs(wave) * h * 0.06
            let transcribingBarH = minBarH + abs(wave) * h * 0.04
            // The wave only shapes the voice response, it no longer halves it:
            // `abs(wave)` passes through zero often, and at 0.5/0.5 that pulled
            // every bar back to the floor mid-syllable.
            let activeBarH = minBarH + (maxBarH - minBarH) * volumeLevel * (0.62 + 0.38 * abs(wave))
            let barH: CGFloat
            if isListening {
                // Idle shimmer is the floor while listening, so a pause reads as
                // breathing rather than as a dead meter.
                barH = volumeLevel > 0.01 ? max(activeBarH, idleBarH) : idleBarH
            } else if isActive {
                barH = transcribingBarH
            } else {
                barH = idleBarH
            }

            let x = barsStartX + CGFloat(i) * (barWidth + barGap)
            bar.frame = NSRect(x: x, y: barCenterY - barH / 2, width: barWidth, height: barH)
            bar.cornerRadius = barCorner
        }

        CATransaction.commit()
    }

    // MARK: - Public API

    /// Blocked mode: the local speech model is still downloading. The icon
    /// becomes a blocker and the voice meter is replaced by the percentage.
    /// Pass `nil` to return the pill to its normal appearance.
    func setBlockedDownload(percent: Int?) {
        blockedPercent = percent

        guard let percent else {
            progressLabel.isHidden = true
            for bar in barLayers {
                bar.isHidden = false
            }
            // Force the icon back on the next update() pass.
            currentMode = -1
            return
        }

        progressLabel.stringValue = "\(max(0, min(100, percent)))%"
        progressLabel.isHidden = false
        for bar in barLayers {
            bar.isHidden = true
        }

        iconEmojiLabel.stringValue = Self.blockedEmoji
        iconEmojiLabel.isHidden = false
        iconImageView.isHidden = true
    }

    func update(isRecording: Bool, isTranscribing: Bool, usesActiveAppearance: Bool, isNoteMode: Bool, isTodoMode: Bool, isAiMode: Bool, level: Double, shouldPulse: Bool) {
        let normalizedLevel = max(0, min(1, CGFloat(level)))

        // While blocked, nothing else may touch the icon or the meter.
        guard blockedPercent == nil else {
            self.usesActiveAppearance = usesActiveAppearance
            isListening = false
            isActive = false
            targetVolume = 0
            return
        }

        isListening = isRecording
        self.usesActiveAppearance = usesActiveAppearance
        isActive = isRecording || isTranscribing || usesActiveAppearance

        // Mode icon swap
        let newMode: Int = isAiMode ? 3 : (isTodoMode ? 2 : (isNoteMode ? 1 : 0))
        if newMode != currentMode {
            currentMode = newMode
            if isAiMode {
                iconImageView.image = Self.aiImage
                iconEmojiLabel.isHidden = true
                iconImageView.isHidden = false
            } else if isTodoMode {
                iconImageView.image = Self.todoImage
                iconEmojiLabel.isHidden = true
                iconImageView.isHidden = false
            } else if isNoteMode {
                iconImageView.image = Self.noteImage
                iconEmojiLabel.isHidden = true
                iconImageView.isHidden = false
            } else if let saved = savedSpaceIcon {
                applyIcon(saved)
            } else {
                iconImageView.image = Self.fallbackSpaceImage
                iconImageView.isHidden = false
                iconEmojiLabel.isHidden = true
            }
        }

        // Voice gating
        let gated: CGFloat = normalizedLevel <= 0.07 ? 0 : (normalizedLevel - 0.07) / 0.93
        targetVolume = isActive ? pow(gated, 0.8) : 0

        // Bar color: space color when active, dim white when idle
        let barColor = isActive ? spaceColor : NSColor.white.withAlphaComponent(0.5)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bar in barLayers {
            bar.backgroundColor = barColor.cgColor
        }
        CATransaction.commit()

        // Icon tint
        iconImageView.contentTintColor = isActive
            ? spaceColor
            : NSColor.white.withAlphaComponent(0.7)
    }

    func updateSpaceAppearance(color: NSColor, icon: SpaceIcon) {
        spaceColor = color
        savedSpaceIcon = icon
        guard blockedPercent == nil, currentMode == 0 else { return }
        applyIcon(icon)
    }

    func prepareForDisplay() {
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    /// Fades the icon and voice bars out while the black capsule stays put, so
    /// the split panel can take over an identical silhouette without a seam.
    func fadeContentForSplit(duration: TimeInterval) {
        stopAnimating()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            iconImageView.animator().alphaValue = 0
            iconEmojiLabel.animator().alphaValue = 0
            progressLabel.animator().alphaValue = 0
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        for bar in barLayers {
            bar.opacity = 0
        }
        CATransaction.commit()
    }

    /// Undoes `fadeContentForSplit` before the pill is shown again.
    func resetContentOpacity() {
        iconImageView.alphaValue = 1
        iconEmojiLabel.alphaValue = 1
        progressLabel.alphaValue = 1

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bar in barLayers {
            bar.opacity = 1
        }
        CATransaction.commit()
    }

    // MARK: - Private

    private func applyIcon(_ icon: SpaceIcon) {
        switch icon {
        case .symbol(let name):
            if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
                iconImageView.image = img
            } else {
                iconImageView.image = Self.fallbackSpaceImage
            }
            iconImageView.isHidden = false
            iconEmojiLabel.isHidden = true
        case .emoji(let char):
            iconEmojiLabel.stringValue = char
            iconImageView.isHidden = true
            iconEmojiLabel.isHidden = false
        }
    }
}

// MARK: - FloatingBubbleController

@MainActor
final class FloatingBubbleController {
    /// Base pill dimensions at 100%. Default sizePercent (35%) yields ~32x77pt pill.
    private let basePillHeight: CGFloat = 90
    private let basePillWidth: CGFloat = 220
    private let bottomOffset: CGFloat = 48

    private var panel: NSPanel?
    private var pillView: PillIndicatorView?
    private var currentIsRecording = false
    private var currentIsTranscribing = false
    private var currentUsesActiveAppearance = false
    private var currentIsNoteMode = false
    private var currentIsTodoMode = false
    private var currentIsAiMode = false
    private var currentLevel: Double = 0
    private var pendingSpaceColor: NSColor?
    private var pendingSpaceIcon: SpaceIcon?
    private var sizePercent: Double = 100
    private var blockedDownloadPercent: Int?

    // MARK: - Public API

    /// Where the pill sits on screen right now — or where it would sit if shown.
    /// The post-action split starts from exactly this rect.
    var pillScreenFrame: NSRect {
        if let panel, panel.isVisible {
            return panel.frame
        }
        let size = computePanelSize()
        guard let screen = activeScreen() else {
            return NSRect(origin: .zero, size: size)
        }
        let visibleFrame = screen.visibleFrame
        return NSRect(
            x: round(visibleFrame.midX - size.width / 2),
            y: round(visibleFrame.origin.y + bottomOffset),
            width: size.width,
            height: size.height
        )
    }

    /// Fades the pill's glyphs so another panel can take over its silhouette.
    func fadeContentForSplit(duration: TimeInterval) {
        pillView?.fadeContentForSplit(duration: duration)
    }

    func setPresentation(position _: FloatingIndicatorPosition, sizePercent: Double) {
        self.sizePercent = sizePercent
        repositionIfVisible()
    }

    func setSpaceAppearance(color: NSColor, icon: SpaceIcon) {
        pendingSpaceColor = color
        pendingSpaceIcon = icon
        pillView?.updateSpaceAppearance(color: color, icon: icon)
    }

    func prepareForImmediatePresentation() {
        let panelSize = computePanelSize()
        let panel = ensurePanel(size: panelSize)
        resize(panel, size: panelSize)
        positionPanel(panel, size: panelSize)
        pillView?.prepareForDisplay()
    }

    /// Shows the pill in its blocked state: dictation can't start because the
    /// local speech model is still downloading.
    func showDownloadBlocked(percent: Int) {
        blockedDownloadPercent = percent

        let panelSize = computePanelSize()
        let panel = ensurePanel(size: panelSize)
        panel.alphaValue = 1

        resize(panel, size: panelSize)
        positionPanel(panel, size: panelSize)

        pillView?.stopAnimating()
        pillView?.setBlockedDownload(percent: percent)
        panel.orderFrontRegardless()
    }

    /// Live-updates the percentage while the blocked pill stays on screen.
    func updateDownloadBlocked(percent: Int) {
        guard blockedDownloadPercent != nil else { return }
        blockedDownloadPercent = percent
        pillView?.setBlockedDownload(percent: percent)
    }

    var isShowingDownloadBlocked: Bool {
        blockedDownloadPercent != nil && panel?.isVisible == true
    }

    func show(
        message _: String,
        isRecording: Bool,
        isTranscribing: Bool,
        usesActiveAppearance: Bool,
        isNoteMode: Bool = false,
        isTodoMode: Bool = false,
        isAiMode: Bool = false,
        riveAssetPath _: String?,
        htmlIndicatorMarkup _: String?,
        useBuiltInWaveIndicator _: Bool
    ) {
        clearBlockedDownloadIfNeeded()

        currentIsRecording = isRecording
        currentIsTranscribing = isTranscribing
        currentUsesActiveAppearance = usesActiveAppearance
        currentIsNoteMode = isNoteMode
        currentIsTodoMode = isTodoMode
        currentIsAiMode = isAiMode

        let panelSize = computePanelSize()
        let panel = ensurePanel(size: panelSize)

        panel.alphaValue = 1
        pillView?.resetContentOpacity()

        if let color = pendingSpaceColor, let icon = pendingSpaceIcon {
            pillView?.updateSpaceAppearance(color: color, icon: icon)
        }

        resize(panel, size: panelSize)
        positionPanel(panel, size: panelSize)

        pillView?.startAnimating()
        pillView?.update(
            isRecording: isRecording,
            isTranscribing: isTranscribing,
            usesActiveAppearance: usesActiveAppearance,
            isNoteMode: isNoteMode,
            isTodoMode: isTodoMode,
            isAiMode: isAiMode,
            level: currentLevel,
            shouldPulse: false
        )

        panel.orderFrontRegardless()
    }

    func hide() {
        clearBlockedDownloadIfNeeded()
        guard let panel, panel.isVisible else { return }
        pillView?.stopAnimating()
        panel.alphaValue = 0
        panel.orderOut(nil)
        panel.alphaValue = 1
        pillView?.resetContentOpacity()
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

    private func clearBlockedDownloadIfNeeded() {
        guard blockedDownloadPercent != nil else { return }
        blockedDownloadPercent = nil
        pillView?.setBlockedDownload(percent: nil)
    }

    private func applyReactiveUpdate(listening: Bool, transcribing: Bool, level: Double, shouldPulse: Bool) {
        currentLevel = max(0, min(1, level))
        currentIsRecording = listening
        currentIsTranscribing = transcribing

        pillView?.update(
            isRecording: currentIsRecording,
            isTranscribing: currentIsTranscribing,
            usesActiveAppearance: currentUsesActiveAppearance,
            isNoteMode: currentIsNoteMode,
            isTodoMode: currentIsTodoMode,
            isAiMode: currentIsAiMode,
            level: currentLevel,
            shouldPulse: shouldPulse
        )
    }

    private func computePanelSize() -> NSSize {
        let scale = CGFloat(sizePercent / 100.0)
        return NSSize(
            width: round(basePillWidth * scale),
            height: round(basePillHeight * scale)
        )
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
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none

        let pillView = PillIndicatorView(frame: NSRect(origin: .zero, size: size))
        panel.contentView = pillView
        self.pillView = pillView
        self.panel = panel

        if let color = pendingSpaceColor, let icon = pendingSpaceIcon {
            pillView.updateSpaceAppearance(color: color, icon: icon)
        }

        return panel
    }

    private func resize(_ panel: NSPanel, size: NSSize) {
        guard panel.frame.size != size || panel.contentView?.frame.size != size else {
            return
        }
        let frame = NSRect(origin: panel.frame.origin, size: size)
        panel.setFrame(frame, display: true)
        panel.contentView?.frame = NSRect(origin: .zero, size: size)
        pillView?.prepareForDisplay()
    }

    private func positionPanel(_ panel: NSPanel, size: NSSize) {
        guard let screen = activeScreen() else { return }
        let visibleFrame = screen.visibleFrame
        let x = round(visibleFrame.midX - size.width / 2)
        let y = round(visibleFrame.origin.y + bottomOffset)
        let origin = NSPoint(x: x, y: y)
        guard panel.frame.origin != origin else {
            return
        }
        panel.setFrameOrigin(origin)
    }

    private func repositionIfVisible() {
        guard let panel, panel.isVisible else { return }
        let size = computePanelSize()
        resize(panel, size: size)
        positionPanel(panel, size: size)
    }

    private func activeScreen() -> NSScreen? {
        if let panelScreen = panel?.screen { return panelScreen }
        if let keyScreen = NSApp.keyWindow?.screen { return keyScreen }
        if let main = NSScreen.main { return main }
        return NSScreen.screens.first
    }
}
