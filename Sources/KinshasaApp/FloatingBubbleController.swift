import AppKit
import Foundation

private final class NotchIndicatorContentView: NSView {
    private let shellView = NSView()
    private let micIconView = NSImageView()
    private var currentIconSymbol = "mic.fill"
    private let meterContainerView = NSView()
    private var meterBars: [NSView] = []
    private var meterBarHeightConstraints: [NSLayoutConstraint] = []
    private var meterDisplayedLevel: CGFloat = 0
    private var meterPerBarLevels: [CGFloat] = []
    private var lastMeterUpdateUptime: TimeInterval?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        shellView.layer?.shadowPath = CGPath(
            roundedRect: shellView.bounds,
            cornerWidth: shellView.layer?.cornerRadius ?? 0,
            cornerHeight: shellView.layer?.cornerRadius ?? 0,
            transform: nil
        )
    }

    func update(message _: String, isRecording: Bool, isTranscribing: Bool, isNoteMode: Bool, level: Double, shouldPulse: Bool) {
        let normalizedLevel = max(0, min(1, level))
        let isActive = isRecording || isTranscribing

        let targetSymbol = isNoteMode ? "note.text" : "mic.fill"
        if currentIconSymbol != targetSymbol,
           let newImage = NSImage(systemSymbolName: targetSymbol, accessibilityDescription: isNoteMode ? "Note" : "Microphone")
        {
            currentIconSymbol = targetSymbol
            micIconView.image = newImage
        }

        if isRecording {
            micIconView.contentTintColor = .systemRed
        } else if isTranscribing {
            micIconView.contentTintColor = .systemBlue
        } else {
            micIconView.contentTintColor = NSColor.white.withAlphaComponent(0.72)
        }

        meterContainerView.alphaValue = isActive ? 1 : 0.22
        updateMeterBars(level: normalizedLevel, active: isActive)

        if shouldPulse {
            runPulseAnimation()
        }
    }

    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        shellView.wantsLayer = true
        shellView.layer?.cornerRadius = 12
        shellView.layer?.cornerCurve = .continuous
        shellView.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        shellView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.94).cgColor
        shellView.layer?.shadowColor = NSColor.black.cgColor
        shellView.layer?.shadowOpacity = 0.26
        shellView.layer?.shadowRadius = 10
        shellView.layer?.shadowOffset = NSSize(width: 0, height: -1)

        if let micImage = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Microphone") {
            micIconView.image = micImage
        }
        micIconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        micIconView.contentTintColor = NSColor.white.withAlphaComponent(0.72)
        micIconView.imageScaling = .scaleProportionallyUpOrDown

        meterContainerView.wantsLayer = true
        meterContainerView.layer?.backgroundColor = NSColor.clear.cgColor

        let barWidth: CGFloat = 2
        let barSpacing: CGFloat = 5
        let barCount = 7
        let totalMeterWidth = (CGFloat(barCount) * barWidth) + (CGFloat(barCount - 1) * barSpacing)

        for index in 0 ..< barCount {
            let bar = NSView()
            bar.wantsLayer = true
            bar.layer?.cornerRadius = barWidth / 2
            bar.layer?.cornerCurve = .continuous
            bar.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.95).cgColor
            bar.translatesAutoresizingMaskIntoConstraints = false
            meterContainerView.addSubview(bar)
            meterBars.append(bar)

            let height = bar.heightAnchor.constraint(equalToConstant: 3.2)
            meterBarHeightConstraints.append(height)
            NSLayoutConstraint.activate([
                bar.leadingAnchor.constraint(
                    equalTo: meterContainerView.leadingAnchor,
                    constant: CGFloat(index) * (barWidth + barSpacing)
                ),
                bar.centerYAnchor.constraint(equalTo: meterContainerView.centerYAnchor),
                bar.widthAnchor.constraint(equalToConstant: barWidth),
                height,
            ])
        }
        meterPerBarLevels = Array(repeating: 0, count: meterBars.count)

        [shellView, micIconView, meterContainerView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        addSubview(shellView)
        shellView.addSubview(micIconView)
        shellView.addSubview(meterContainerView)

        NSLayoutConstraint.activate([
            shellView.leadingAnchor.constraint(equalTo: leadingAnchor),
            shellView.trailingAnchor.constraint(equalTo: trailingAnchor),
            shellView.topAnchor.constraint(equalTo: topAnchor),
            shellView.bottomAnchor.constraint(equalTo: bottomAnchor),

            micIconView.leadingAnchor.constraint(equalTo: shellView.leadingAnchor, constant: 14),
            micIconView.centerYAnchor.constraint(equalTo: shellView.centerYAnchor),
            micIconView.widthAnchor.constraint(equalToConstant: 14),
            micIconView.heightAnchor.constraint(equalToConstant: 14),

            meterContainerView.leadingAnchor.constraint(greaterThanOrEqualTo: micIconView.trailingAnchor, constant: 12),
            meterContainerView.trailingAnchor.constraint(equalTo: shellView.trailingAnchor, constant: -14),
            meterContainerView.centerYAnchor.constraint(equalTo: shellView.centerYAnchor),
            meterContainerView.heightAnchor.constraint(equalToConstant: 14),
            meterContainerView.widthAnchor.constraint(equalToConstant: totalMeterWidth),
        ])
    }

    private func runPulseAnimation() {
        guard let layer = shellView.layer else {
            return
        }

        layer.removeAnimation(forKey: "notch-pulse")

        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = 1.0
        animation.toValue = 1.015
        animation.duration = 0.10
        animation.autoreverses = true
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "notch-pulse")
    }

    private func updateMeterBars(level: Double, active: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        let dt: CGFloat
        if let lastMeterUpdateUptime {
            dt = max(1 / 180, min(0.1, CGFloat(now - lastMeterUpdateUptime)))
        } else {
            dt = 1 / 60
        }
        lastMeterUpdateUptime = now

        let clampedLevel = max(0, min(1, CGFloat(level)))
        let noiseGate: CGFloat = 0.07
        let gatedLevel: CGFloat
        if clampedLevel <= noiseGate {
            gatedLevel = 0
        } else {
            gatedLevel = (clampedLevel - noiseGate) / (1 - noiseGate)
        }

        let compressedLevel = pow(gatedLevel, 1.65)
        let targetEnvelope: CGFloat = active ? compressedLevel : 0
        let envelopeTau: CGFloat = targetEnvelope > meterDisplayedLevel ? 0.010 : 0.014
        let envelopeAlpha = 1 - exp(-dt / max(0.001, envelopeTau))
        meterDisplayedLevel += (targetEnvelope - meterDisplayedLevel) * envelopeAlpha
        if targetEnvelope == 0, meterDisplayedLevel < 0.004 {
            meterDisplayedLevel = 0
        }

        let baseHeight: CGFloat = 1.6
        let maxHeight: CGFloat = 11.2
        let perBarScale: [CGFloat] = [0.62, 0.80, 0.70, 0.92, 0.72, 0.82, 0.64]

        for (index, constraint) in meterBarHeightConstraints.enumerated() {
            let target = max(0, min(1, meterDisplayedLevel * perBarScale[index]))

            let current = meterPerBarLevels[index]
            let barTau: CGFloat = target > current ? 0.009 : 0.012
            let barAlpha = 1 - exp(-dt / max(0.001, barTau))
            let next = current + (target - current) * barAlpha
            meterPerBarLevels[index] = (target == 0 && next < 0.004) ? 0 : next

            let renderedLevel = meterPerBarLevels[index]
            let targetHeight = baseHeight + (maxHeight - baseHeight) * renderedLevel
            constraint.constant = max(baseHeight, active ? targetHeight : baseHeight)
            meterBars[index].alphaValue = active ? (0.16 + renderedLevel * 0.84) : 0.16
        }
    }
}

@MainActor
final class FloatingBubbleController {
    private struct NotchGeometry {
        let centerX: CGFloat
        let width: CGFloat
        let height: CGFloat
    }

    private let indicatorHeightBoost: CGFloat = -3
    private let fallbackPanelSize = NSSize(width: 220, height: 31)
    private let minPanelWidth: CGFloat = 188
    private let maxPanelWidth: CGFloat = 340
    private let minPanelHeight: CGFloat = 32
    private let maxPanelHeight: CGFloat = 40
    private let expandCollapseDuration: TimeInterval = 0.22

    private var panel: NSPanel?
    private var contentView: NotchIndicatorContentView?
    private var currentMessage = ""
    private var currentIsRecording = false
    private var currentIsTranscribing = false
    private var currentIsNoteMode = false
    private var currentLevel: Double = 0
    private var hideWorkItem: DispatchWorkItem?

    func setPresentation(position _: FloatingIndicatorPosition, sizePercent _: Double) {
        // Unified notch indicator ignores custom placement/size and stays top-center.
        repositionIfVisible()
    }

    func show(
        message: String,
        isRecording: Bool,
        isTranscribing: Bool,
        isNoteMode: Bool = false,
        riveAssetPath _: String?,
        htmlIndicatorMarkup _: String?,
        useBuiltInWaveIndicator _: Bool
    ) {
        cancelPendingHide()
        currentMessage = message
        currentIsRecording = isRecording
        currentIsTranscribing = isTranscribing
        currentIsNoteMode = isNoteMode

        let screen = activeScreen()
        let isActive = isRecording || isTranscribing
        let expandedSize = desiredSize(screen: screen, isActive: true)
        let collapsedSize = desiredSize(screen: screen, isActive: false)
        let targetSize = isActive ? expandedSize : collapsedSize
        let panel = ensurePanel(size: targetSize)
        let wasVisible = panel.isVisible

        if !wasVisible {
            let initialSize = isActive ? collapsedSize : targetSize
            resize(panel, size: initialSize)
            position(panel, size: initialSize, on: screen)
        }

        contentView?.update(
            message: message,
            isRecording: isRecording,
            isTranscribing: isTranscribing,
            isNoteMode: isNoteMode,
            level: currentLevel,
            shouldPulse: false
        )

        panel.orderFrontRegardless()

        if isActive, !wasVisible {
            animatePanelFrame(
                panel,
                size: targetSize,
                on: screen,
                duration: expandCollapseDuration,
                timingFunction: CAMediaTimingFunction(name: .easeOut)
            )
            return
        }

        if shouldAnimateSizeChange(from: panel.frame.size, to: targetSize) {
            let timing = targetSize.width >= panel.frame.size.width
                ? CAMediaTimingFunction(name: .easeOut)
                : CAMediaTimingFunction(name: .easeIn)
            animatePanelFrame(
                panel,
                size: targetSize,
                on: screen,
                duration: expandCollapseDuration,
                timingFunction: timing
            )
        } else {
            position(panel, size: targetSize, on: screen)
        }
    }

    func hide() {
        guard let panel, panel.isVisible else {
            return
        }

        cancelPendingHide()
        let screen = panel.screen ?? activeScreen()
        let collapsedSize = desiredSize(screen: screen, isActive: false)
        animatePanelFrame(
            panel,
            size: collapsedSize,
            on: screen,
            duration: expandCollapseDuration,
            timingFunction: CAMediaTimingFunction(name: .easeIn)
        )

        let workItem = DispatchWorkItem { [weak panel] in
            panel?.orderOut(nil)
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + expandCollapseDuration, execute: workItem)
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

    private func applyReactiveUpdate(listening: Bool, transcribing: Bool, level: Double, shouldPulse: Bool) {
        currentLevel = max(0, min(1, level))
        currentIsRecording = listening
        currentIsTranscribing = transcribing

        if let panel, panel.isVisible {
            let screen = panel.screen ?? activeScreen()
            let size = desiredSize(screen: screen)
            if shouldAnimateSizeChange(from: panel.frame.size, to: size) {
                let timing = size.width >= panel.frame.size.width
                    ? CAMediaTimingFunction(name: .easeOut)
                    : CAMediaTimingFunction(name: .easeIn)
                animatePanelFrame(
                    panel,
                    size: size,
                    on: screen,
                    duration: expandCollapseDuration,
                    timingFunction: timing
                )
            } else {
                position(panel, size: size, on: screen)
            }
        }

        contentView?.update(
            message: currentMessage,
            isRecording: currentIsRecording,
            isTranscribing: currentIsTranscribing,
            isNoteMode: currentIsNoteMode,
            level: currentLevel,
            shouldPulse: shouldPulse
        )
    }

    private func desiredSize(screen: NSScreen? = nil, isActive: Bool? = nil) -> NSSize {
        guard let screen else {
            return fallbackPanelSize
        }

        guard let notchGeometry = notchGeometry(on: screen) else {
            return fallbackPanelSize
        }

        let active = isActive ?? (currentIsRecording || currentIsTranscribing)
        let horizontalExpansion: CGFloat = if active {
            50
        } else {
            0
        }

        let shellWidth = min(
            max(notchGeometry.width + (horizontalExpansion * 2), minPanelWidth),
            maxPanelWidth
        )
        let shellHeight = min(
            max(
                notchGeometry.height + (active ? 3 : 2) + indicatorHeightBoost,
                minPanelHeight
            ),
            maxPanelHeight
        )
        return NSSize(width: shellWidth, height: shellHeight)
    }

    private func ensurePanel(size: NSSize) -> NSPanel {
        if let panel {
            return panel
        }

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

        let contentView = NotchIndicatorContentView(frame: NSRect(origin: .zero, size: size))
        panel.contentView = contentView
        self.contentView = contentView
        self.panel = panel
        return panel
    }

    private func resize(_ panel: NSPanel, size: NSSize) {
        let frame = NSRect(origin: panel.frame.origin, size: size)
        panel.setFrame(frame, display: true)
        panel.contentView?.frame = NSRect(origin: .zero, size: size)
    }

    private func position(_ panel: NSPanel, size: NSSize, on preferredScreen: NSScreen? = nil) {
        guard let screen = preferredScreen ?? activeScreen() else {
            return
        }

        panel.setFrameOrigin(frame(for: size, on: screen).origin)
    }

    private func repositionIfVisible() {
        guard let panel, panel.isVisible else {
            return
        }

        let screen = panel.screen ?? activeScreen()
        let size = desiredSize(screen: screen)
        resize(panel, size: size)
        position(panel, size: size, on: screen)
    }

    private func frame(for size: NSSize, on screen: NSScreen) -> NSRect {
        let frame = screen.frame
        let centerX = notchGeometry(on: screen)?.centerX ?? frame.midX
        let x = centerX - (size.width / 2)
        let y = frame.maxY - size.height
        return NSRect(x: x, y: y, width: size.width, height: size.height).integral
    }

    private func animatePanelFrame(
        _ panel: NSPanel,
        size: NSSize,
        on preferredScreen: NSScreen?,
        duration: TimeInterval,
        timingFunction: CAMediaTimingFunction
    ) {
        guard let screen = preferredScreen ?? activeScreen() else {
            resize(panel, size: size)
            return
        }

        let targetFrame = frame(for: size, on: screen)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = timingFunction
            panel.animator().setFrame(targetFrame, display: true)
        }
    }

    private func shouldAnimateSizeChange(from current: NSSize, to target: NSSize) -> Bool {
        abs(current.width - target.width) > 0.5 || abs(current.height - target.height) > 0.5
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

    private func notchGeometry(on screen: NSScreen) -> NotchGeometry? {
        guard
            let leftArea = screen.auxiliaryTopLeftArea,
            let rightArea = screen.auxiliaryTopRightArea,
            !leftArea.isEmpty,
            !rightArea.isEmpty
        else {
            return nil
        }

        let notchWidth = screen.frame.width - leftArea.width - rightArea.width
        let notchHeight = max(leftArea.height, rightArea.height)
        guard notchWidth > 0, notchHeight > 0 else {
            return nil
        }

        let notchCenterX = leftArea.maxX + (notchWidth / 2)
        return NotchGeometry(centerX: notchCenterX, width: notchWidth, height: notchHeight)
    }
}
