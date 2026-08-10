import AppKit

/// Destination the user picks from the post-dictation split pill.
enum PostDictationAction: Int, CaseIterable {
    case aiChat = 0
    case note = 1
    case todo = 2

    var title: String {
        switch self {
        case .aiChat: return "AI"
        case .note: return "Note"
        case .todo: return "Todo"
        }
    }

    var symbolName: String {
        switch self {
        case .aiChat: return "sparkles"
        case .note: return "note.text"
        case .todo: return "checklist"
        }
    }
}

// MARK: - Segment view

/// One clickable box of the split pill: icon, title, and a keycap badge.
private final class PostActionSegmentView: NSView {
    let action: PostDictationAction
    var onClick: ((PostDictationAction) -> Void)?

    private let bgLayer = CALayer()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let keycapLabel = NSTextField(labelWithString: "")
    private let keycapBg = CALayer()
    private var isHovered = false

    init(action: PostDictationAction, keyLabel: String) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true

        bgLayer.backgroundColor = NSColor.black.cgColor
        bgLayer.cornerRadius = 10
        bgLayer.masksToBounds = true
        layer?.addSublayer(bgLayer)

        iconView.image = NSImage(systemSymbolName: action.symbolName, accessibilityDescription: action.title)
        iconView.contentTintColor = .white
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        titleLabel.stringValue = action.title
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.backgroundColor = .clear
        titleLabel.isBezeled = false
        addSubview(titleLabel)

        keycapBg.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        keycapBg.cornerRadius = 4
        layer?.addSublayer(keycapBg)

        keycapLabel.stringValue = keyLabel
        keycapLabel.textColor = NSColor.white.withAlphaComponent(0.85)
        keycapLabel.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
        keycapLabel.backgroundColor = .clear
        keycapLabel.isBezeled = false
        keycapLabel.alignment = .center
        addSubview(keycapLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        ))
    }

    override func mouseEntered(with _: NSEvent) {
        isHovered = true
        bgLayer.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
    }

    override func mouseExited(with _: NSEvent) {
        isHovered = false
        bgLayer.backgroundColor = NSColor.black.cgColor
    }

    override func mouseDown(with _: NSEvent) {
        onClick?(action)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bgLayer.frame = bounds

        let h = bounds.height
        let iconSize: CGFloat = 15
        iconView.frame = NSRect(x: 10, y: (h - iconSize) / 2, width: iconSize, height: iconSize)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)

        titleLabel.sizeToFit()
        titleLabel.setFrameOrigin(NSPoint(x: 30, y: (h - titleLabel.frame.height) / 2))

        let capW: CGFloat = 18
        let capH: CGFloat = 16
        keycapBg.frame = NSRect(x: bounds.width - capW - 8, y: (h - capH) / 2, width: capW, height: capH)
        keycapLabel.frame = keycapBg.frame.insetBy(dx: 0, dy: 1)
        CATransaction.commit()
    }
}

// MARK: - Controller

/// After a paste-mode dictation lands, the pill "splits" into three boxes so
/// the transcript can be rerouted to AI chat, a note, or a todo — via the
/// configured keys (default A/S/D) or a click. Auto-dismisses after a timeout,
/// on Escape, on any other typing, or on a click elsewhere.
@MainActor
final class PostActionPillController {
    private let segmentWidth: CGFloat = 96
    private let segmentHeight: CGFloat = 36
    private let segmentGap: CGFloat = 8
    private let bottomOffset: CGFloat = 48
    private let displayTimeout: TimeInterval = 6.0

    private var panel: NSPanel?
    private var timeoutTask: Task<Void, Never>?
    private var outsideClickMonitor: Any?
    private var onAction: ((PostDictationAction) -> Void)?
    private var onDismiss: (() -> Void)?

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    func show(
        keyLabels: [PostDictationAction: String],
        onAction: @escaping (PostDictationAction) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        hide()
        self.onAction = onAction
        self.onDismiss = onDismiss

        let totalWidth = segmentWidth * 3 + segmentGap * 2
        let size = NSSize(width: totalWidth, height: segmentHeight)

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
        panel.animationBehavior = .none

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        for (index, action) in PostDictationAction.allCases.enumerated() {
            let segment = PostActionSegmentView(action: action, keyLabel: keyLabels[action] ?? "")
            segment.frame = NSRect(
                x: CGFloat(index) * (segmentWidth + segmentGap),
                y: 0,
                width: segmentWidth,
                height: segmentHeight
            )
            segment.onClick = { [weak self] action in
                self?.onAction?(action)
            }
            container.addSubview(segment)
        }
        panel.contentView = container
        self.panel = panel

        position(panel, size: size)
        panel.orderFrontRegardless()

        // A click anywhere outside the pill means the user moved on.
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
        timeoutTask?.cancel()
        timeoutTask = nil
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        onAction = nil
        onDismiss = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func position(_ panel: NSPanel, size: NSSize) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visibleFrame = screen.visibleFrame
        let x = round(visibleFrame.midX - size.width / 2)
        let y = round(visibleFrame.origin.y + bottomOffset)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
