import AppKit

private final class BubbleContentView: NSView {
    private let dotView = NSView()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor

        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 5

        label.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        label.textColor = .labelColor

        [dotView, label].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        NSLayoutConstraint.activate([
            dotView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            dotView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotView.widthAnchor.constraint(equalToConstant: 10),
            dotView.heightAnchor.constraint(equalToConstant: 10),

            label.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(message: String, isRecording: Bool) {
        label.stringValue = message
        dotView.layer?.backgroundColor = (isRecording ? NSColor.systemRed : NSColor.systemBlue).cgColor
    }
}

@MainActor
final class FloatingBubbleController {
    private let panelSize = NSSize(width: 340, height: 58)

    private var panel: NSPanel?
    private var contentView: BubbleContentView?

    func show(message: String, isRecording: Bool) {
        let panel = ensurePanel()
        contentView?.update(message: message, isRecording: isRecording)
        position(panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> NSPanel {
        if let panel {
            return panel
        }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true

        let content = BubbleContentView(frame: NSRect(origin: .zero, size: panelSize))
        content.update(message: "Listening...", isRecording: true)

        panel.contentView = content

        self.contentView = content
        self.panel = panel

        return panel
    }

    private func position(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main

        guard let screen = targetScreen else {
            return
        }

        let visibleFrame = screen.visibleFrame
        let origin = NSPoint(
            x: visibleFrame.midX - panelSize.width / 2,
            y: visibleFrame.maxY - panelSize.height - 42
        )

        panel.setFrame(NSRect(origin: origin, size: panelSize), display: true)
    }
}
