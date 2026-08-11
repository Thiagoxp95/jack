import AppKit

/// Destination the user picks from the post-dictation split pill.
enum PostDictationAction: Int, CaseIterable {
    case aiChat = 0
    case todo = 1

    var title: String {
        switch self {
        case .aiChat: return "AI"
        case .todo: return "Todo"
        }
    }

    var symbolName: String {
        switch self {
        case .aiChat: return "sparkles"
        case .todo: return "checklist"
        }
    }
}

// MARK: - Easing

/// Smoothstep: eases in and out with zero velocity at both ends. The slow
/// start is what makes the pill look like it's resisting before it tears.
private func smoothstep(_ t: CGFloat) -> CGFloat {
    let x = min(1, max(0, t))
    return x * x * (3 - 2 * x)
}

private func clamp01(_ v: CGFloat) -> CGFloat { min(1, max(0, v)) }

private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

// MARK: - Metaball

/// The liquid "neck" between two circles that are pulling apart.
///
/// Returns the filled connector shape, or `nil` once the circles are too far
/// apart for surface tension to hold — that's the moment the neck snaps.
/// `v` controls how much the goo clings (0 = none, 1 = maximum).
private func metaballConnector(
    c1: CGPoint, r1: CGFloat,
    c2: CGPoint, r2: CGFloat,
    v: CGFloat,
    handleSize: CGFloat,
    maxDistance: CGFloat
) -> NSBezierPath? {
    guard r1 > 0.01, r2 > 0.01 else { return nil }
    let d = hypot(c2.x - c1.x, c2.y - c1.y)
    guard d > abs(r1 - r2) + 0.01, d < maxDistance else { return nil }

    func safeACos(_ x: CGFloat) -> CGFloat { acos(min(1, max(-1, x))) }
    func point(_ origin: CGPoint, _ radius: CGFloat, _ angle: CGFloat) -> CGPoint {
        CGPoint(x: origin.x + radius * cos(angle), y: origin.y + radius * sin(angle))
    }

    // How far around each circle the neck wraps.
    var u1: CGFloat = 0
    var u2: CGFloat = 0
    if d < r1 + r2 {
        u1 = safeACos((r1 * r1 + d * d - r2 * r2) / (2 * r1 * d))
        u2 = safeACos((r2 * r2 + d * d - r1 * r1) / (2 * r2 * d))
    }

    let between = atan2(c2.y - c1.y, c2.x - c1.x)
    let maxSpread = safeACos((r1 - r2) / d)

    let angle1a = between + u1 + (maxSpread - u1) * v
    let angle1b = between - u1 - (maxSpread - u1) * v
    let angle2a = between + .pi - u2 - (.pi - u2 - maxSpread) * v
    let angle2b = between - .pi + u2 + (.pi - u2 - maxSpread) * v

    let p1a = point(c1, r1, angle1a)
    let p1b = point(c1, r1, angle1b)
    let p2a = point(c2, r2, angle2a)
    let p2b = point(c2, r2, angle2b)

    let totalRadius = r1 + r2
    var handle = min(v * handleSize, hypot(p2a.x - p1a.x, p2a.y - p1a.y) / totalRadius)
    handle *= min(1, d * 2 / totalRadius)
    let h1 = r1 * handle
    let h2 = r2 * handle

    let path = NSBezierPath()
    path.move(to: p1a)
    path.curve(
        to: p2a,
        controlPoint1: point(p1a, h1, angle1a - .pi / 2),
        controlPoint2: point(p2a, h2, angle2a + .pi / 2)
    )
    path.line(to: p2b)
    path.curve(
        to: p1b,
        controlPoint1: point(p2b, h2, angle2b - .pi / 2),
        controlPoint2: point(p1b, h1, angle1b + .pi / 2)
    )
    path.close()
    return path
}

// MARK: - Glyph overlay

/// Icon plus keycap badge that rides on top of one droplet.
private final class ActionGlyphView: NSView {
    private let iconView = NSImageView()
    private let keycapLabel = NSTextField(labelWithString: "")
    private let keycapBg = CALayer()

    init(action: PostDictationAction, keyLabel: String) {
        super.init(frame: .zero)
        wantsLayer = true

        iconView.image = NSImage(systemSymbolName: action.symbolName, accessibilityDescription: action.title)
        iconView.contentTintColor = .white
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        keycapBg.backgroundColor = NSColor.white.withAlphaComponent(0.20).cgColor
        layer?.addSublayer(keycapBg)

        keycapLabel.stringValue = keyLabel
        keycapLabel.textColor = NSColor.white.withAlphaComponent(0.9)
        keycapLabel.backgroundColor = .clear
        keycapLabel.isBezeled = false
        keycapLabel.alignment = .center
        addSubview(keycapLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let d = min(bounds.width, bounds.height)
        guard d > 0 else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let iconSize = round(d * 0.34)
        iconView.frame = NSRect(
            x: round((bounds.width - iconSize) / 2),
            y: round(bounds.midY + d * 0.06),
            width: iconSize,
            height: iconSize
        )
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: round(iconSize * 0.92), weight: .semibold
        )

        let capW = round(d * 0.30)
        let capH = round(d * 0.22)
        let capY = round(bounds.midY - d * 0.06 - capH)
        keycapBg.frame = NSRect(x: round((bounds.width - capW) / 2), y: capY, width: capW, height: capH)
        keycapBg.cornerRadius = min(3, capH / 2)

        keycapLabel.font = .monospacedSystemFont(ofSize: max(7, round(d * 0.17)), weight: .bold)
        keycapLabel.frame = NSRect(
            x: keycapBg.frame.minX,
            y: capY - round(capH * 0.08),
            width: capW,
            height: capH
        )

        CATransaction.commit()
    }
}

// MARK: - Liquid split view

/// Draws the pill breaking apart into three droplets: the body contracts into
/// the middle droplet while the two end caps travel outward, joined by necks
/// that thin out and snap. All one filled path, so the blobs read as one body
/// of liquid until they separate.
private final class LiquidSplitView: NSView {
    var onClick: ((PostDictationAction) -> Void)?

    private let pillSize: NSSize
    private let diameter: CGFloat
    private let gap: CGFloat
    private let padding: CGFloat
    private let duration: CFTimeInterval = 0.52

    private var glyphs: [ActionGlyphView] = []
    private var progress: CGFloat = 0
    private var elapsed: CFTimeInterval = 0
    private var timer: Timer?
    private var hovered: Int?

    init(pillSize: NSSize, diameter: CGFloat, gap: CGFloat, padding: CGFloat, keyLabels: [PostDictationAction: String]) {
        self.pillSize = pillSize
        self.diameter = diameter
        self.gap = gap
        self.padding = padding
        super.init(frame: .zero)
        wantsLayer = true

        for action in PostDictationAction.allCases {
            let glyph = ActionGlyphView(action: action, keyLabel: keyLabels[action] ?? "")
            glyph.alphaValue = 0
            addSubview(glyph)
            glyphs.append(glyph)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Panel size that fits the fully-separated droplets plus slack for the
    /// settle wobble and the drop shadow.
    static func canvasSize(pillSize: NSSize, diameter: CGFloat, gap: CGFloat, padding: CGFloat) -> NSSize {
        NSSize(
            width: max(diameter * 3 + gap * 2, pillSize.width) + padding * 2,
            height: max(diameter, pillSize.height) + padding * 2
        )
    }

    // MARK: Animation

    func startSplit() {
        stop()
        progress = 0
        elapsed = 0
        needsDisplay = true
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        elapsed += 1.0 / 60.0
        progress = clamp01(CGFloat(elapsed / duration))
        layoutGlyphs()
        needsDisplay = true
        if progress >= 1 {
            stop()
        }
    }

    // MARK: Geometry

    private var isSettled: Bool { progress >= 0.995 }

    /// Outward travel of the droplets; also drives the body's contraction.
    /// Warped so the tear starts early and the tail is spent settling, rather
    /// than smoothstep's symmetric curve sitting still for the first 150ms.
    private var travel: CGFloat { smoothstep(pow(progress, 0.8)) }

    /// Surface-tension wobble once the droplets are nearly home.
    private var wobble: CGFloat {
        let settle = clamp01((progress - 0.55) / 0.45)
        guard settle > 0 else { return 0 }
        return sin(settle * .pi * 3.1) * exp(-settle * 4.4) * 0.085
    }

    private var startRadius: CGFloat { pillSize.height / 2 }
    private var endRadius: CGFloat { diameter / 2 }

    /// Distance from centre to each outer droplet. Starts at the pill's end
    /// caps, so frame zero is pixel-identical to the pill it replaced.
    private var outerOffset: CGFloat {
        lerp((pillSize.width - pillSize.height) / 2, diameter + gap, travel)
    }

    private var radius: CGFloat { lerp(startRadius, endRadius, travel) }

    /// The contracting body: a capsule that ends up as the middle droplet.
    private var bodySize: NSSize {
        NSSize(
            width: lerp(pillSize.width, diameter, travel),
            height: lerp(pillSize.height, diameter, travel)
        )
    }

    private func centre() -> CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

    private func dropletCentres() -> [CGPoint] {
        let c = centre()
        let off = outerOffset
        return [
            CGPoint(x: c.x - off, y: c.y),
            c,
            CGPoint(x: c.x + off, y: c.y),
        ]
    }

    private func bodyRect() -> NSRect {
        let c = centre()
        let s = bodySize
        let w = wobble
        return NSRect(
            x: c.x - s.width * (1 - w) / 2,
            y: c.y - s.height * (1 + w) / 2,
            width: s.width * (1 - w),
            height: s.height * (1 + w)
        )
    }

    private func outerRect(at centre: CGPoint) -> NSRect {
        let r = radius
        let w = wobble
        let rx = r * (1 - w)
        let ry = r * (1 + w)
        return NSRect(x: centre.x - rx, y: centre.y - ry, width: rx * 2, height: ry * 2)
    }

    private func layoutGlyphs() {
        let centres = dropletCentres()
        let alpha = clamp01((progress - 0.58) / 0.28)
        for (i, glyph) in glyphs.enumerated() {
            let d = diameter
            glyph.frame = NSRect(
                x: centres[i].x - d / 2,
                y: centres[i].y - d / 2,
                width: d,
                height: d
            )
            glyph.alphaValue = alpha
        }
    }

    // MARK: Drawing

    /// One outline for body + droplets + necks. A real boolean union, not
    /// stacked subpaths: overlapping subpaths would cancel under the non-zero
    /// winding rule and carve notches out of the goo.
    private func gooPath() -> CGPath {
        let centres = dropletCentres()
        let body = bodyRect()
        let r = radius

        // The body's end caps are what the necks actually hang off of.
        let capRadius = min(body.width, body.height) / 2
        let leftCap = CGPoint(x: body.minX + capRadius, y: body.midY)
        let rightCap = CGPoint(x: body.maxX - capRadius, y: body.midY)

        var path = CGPath(
            roundedRect: body,
            cornerWidth: body.height / 2,
            cornerHeight: body.height / 2,
            transform: nil
        )
        path = path.union(CGPath(ellipseIn: outerRect(at: centres[0]), transform: nil))
        path = path.union(CGPath(ellipseIn: outerRect(at: centres[2]), transform: nil))

        // Surface tension eases off as the droplets get away from the body.
        let cling = lerp(0.78, 0.5, progress)
        let maxDistance = (r + capRadius) * 1.34
        for (cap, droplet) in [(leftCap, centres[0]), (rightCap, centres[2])] {
            guard let neck = metaballConnector(
                c1: cap, r1: capRadius, c2: droplet, r2: r,
                v: cling, handleSize: 2.4, maxDistance: maxDistance
            ) else { continue }
            path = path.union(neck.cgPath)
        }
        return path
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current else { return }
        let cg = context.cgContext

        context.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.38)
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.set()
        cg.addPath(gooPath())
        cg.setFillColor(NSColor.black.cgColor)
        cg.fillPath()
        context.restoreGraphicsState()

        // Hover highlight only once the droplets are separate and clickable.
        if isSettled, let hovered {
            NSColor(white: 0.18, alpha: 1).setFill()
            if hovered == 1 {
                let body = bodyRect()
                NSBezierPath(roundedRect: body, xRadius: body.height / 2, yRadius: body.height / 2).fill()
            } else {
                NSBezierPath(ovalIn: outerRect(at: dropletCentres()[hovered])).fill()
            }
        }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self
        ))
    }

    /// Clicks land only on a settled droplet; everything else falls through so
    /// the panel isn't a transparent wall over the screen.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isSettled else { return nil }
        let local = convert(point, from: superview)
        return dropletIndex(at: local) != nil ? self : nil
    }

    private func dropletIndex(at point: NSPoint) -> Int? {
        let centres = dropletCentres()
        let r = max(radius, diameter / 2)
        for (i, c) in centres.enumerated() where hypot(point.x - c.x, point.y - c.y) <= r {
            return i
        }
        return nil
    }

    override func mouseMoved(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let index = dropletIndex(at: local)
        guard index != hovered else { return }
        hovered = index
        needsDisplay = true
    }

    override func mouseExited(with _: NSEvent) {
        guard hovered != nil else { return }
        hovered = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        guard let index = dropletIndex(at: local),
              let action = PostDictationAction(rawValue: index)
        else { return }
        onClick?(action)
    }
}

// MARK: - Controller

/// After a paste-mode dictation lands, the floating pill breaks apart like a
/// drop of water into three droplets — AI, Note, Todo — so the capture can be
/// rerouted with one keypress (default A/S/D) or a click. Auto-dismisses after
/// a timeout, on Escape, on any other typing, or on a click elsewhere.
@MainActor
final class PostActionPillController {
    /// How long the pill's own glyphs get to fade before the split panel takes
    /// over the exact same silhouette. Keeps the handoff invisible.
    static let handoffFadeDuration: TimeInterval = 0.09

    private let gapRatio: CGFloat = 0.42
    private let padding: CGFloat = 16
    private let bottomOffset: CGFloat = 48
    private let displayTimeout: TimeInterval = 6.0

    private var panel: NSPanel?
    private var splitView: LiquidSplitView?
    private var handoffTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var outsideClickMonitor: Any?
    private var onAction: ((PostDictationAction) -> Void)?
    private var onDismiss: (() -> Void)?

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    /// - Parameters:
    ///   - originPillFrame: screen rect of the floating pill this splits out of.
    ///   - onSplitStarted: called the instant the split panel is on screen, so
    ///     the caller can drop the original pill without a visible seam.
    func show(
        originPillFrame: NSRect,
        keyLabels: [PostDictationAction: String],
        onSplitStarted: @escaping () -> Void,
        onAction: @escaping (PostDictationAction) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        hide()
        self.onAction = onAction
        self.onDismiss = onDismiss

        let pillSize = originPillFrame.size
        let diameter = min(64, max(40, pillSize.height * 1.4))
        let gap = round(diameter * gapRatio)
        let canvas = LiquidSplitView.canvasSize(
            pillSize: pillSize, diameter: diameter, gap: gap, padding: padding
        )

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: canvas),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The goo draws its own shadow; the window's cached one can't keep up.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true

        let splitView = LiquidSplitView(
            pillSize: pillSize,
            diameter: diameter,
            gap: gap,
            padding: padding,
            keyLabels: keyLabels
        )
        splitView.frame = NSRect(origin: .zero, size: canvas)
        splitView.onClick = { [weak self] action in
            self?.onAction?(action)
        }
        panel.contentView = splitView
        self.panel = panel
        self.splitView = splitView

        position(panel, size: canvas, centeredOn: originPillFrame)

        // Wait out the pill's glyph fade, then take over its silhouette and
        // start pulling it apart.
        handoffTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.handoffFadeDuration * 1_000_000_000))
            guard !Task.isCancelled, let self, let panel = self.panel else { return }
            panel.orderFrontRegardless()
            onSplitStarted()
            self.splitView?.startSplit()
        }

        // A click anywhere outside the droplets means the user moved on.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onDismiss?()
            }
        }

        timeoutTask = Task { [displayTimeout, weak self] in
            try? await Task.sleep(nanoseconds: UInt64(displayTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.onDismiss?()
        }
    }

    func hide() {
        handoffTask?.cancel()
        handoffTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        onAction = nil
        onDismiss = nil
        splitView?.stop()
        splitView = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func position(_ panel: NSPanel, size: NSSize, centeredOn pill: NSRect) {
        let x = round(pill.midX - size.width / 2)
        var y = round(pill.midY - size.height / 2)

        // Never let the droplets hang off the bottom of the screen.
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(pill) }) ?? NSScreen.main {
            let floor = screen.visibleFrame.origin.y + bottomOffset - size.height / 2
            y = max(y, round(floor))
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
