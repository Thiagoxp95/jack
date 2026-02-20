import AppKit
import Foundation
import RiveRuntime
import WebKit

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

private final class RiveIndicatorContentView: NSView {
    private enum ReactiveInputs {
        static let stateMachineCandidates = ["MicReactiveVM", "MicReactive", "State Machine 1", "MainStateMachine"]
        static let listening = "Listening"
        static let level = "Level"
        static let pulse = "Pulse"
    }

    private var loadedAssetPath: String?
    private var riveViewModel: RiveViewModel?
    private var riveView: RiveView?
    private var activeStateMachineName: String?
    private var hasListeningInput = false
    private var hasLevelInput = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func loadRiveAsset(at assetPath: String) -> Bool {
        if loadedAssetPath == assetPath {
            riveViewModel?.play()
            return true
        }

        guard FileManager.default.fileExists(atPath: assetPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: assetPath))
        else {
            return false
        }

        let bytes = [UInt8](data)
        guard let riveFile = try? RiveFile(byteArray: bytes, loadCdn: false) else {
            return false
        }

        let model = RiveModel(riveFile: riveFile)
        let viewModel = RiveViewModel(
            model,
            animationName: nil,
            fit: .contain,
            alignment: .center,
            autoPlay: true,
            artboardName: nil
        )
        selectBestStateMachineIfAvailable(viewModel)

        let view = viewModel.createRiveView()
        view.translatesAutoresizingMaskIntoConstraints = false

        clearCurrentRiveView()
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        loadedAssetPath = assetPath
        riveViewModel = viewModel
        riveView = view
        viewModel.play()
        let activeName = activeStateMachineName ?? "<none>"
        NSLog(
            "[RiveIndicator] stateMachine=%@ listening=%@ level=%@",
            activeName,
            hasListeningInput ? "yes" : "no",
            hasLevelInput ? "yes" : "no"
        )
        return true
    }

    private func selectBestStateMachineIfAvailable(_ viewModel: RiveViewModel) {
        // Keep the runtime-selected default as a safe fallback, then try known names.
        let fallbackStateMachineName = viewModel.riveModel?.stateMachine?.name()
        var selectedStateMachineName = fallbackStateMachineName
        var selectedHasListeningInput = viewModel.boolInput(named: ReactiveInputs.listening) != nil
        var selectedHasLevelInput = viewModel.numberInput(named: ReactiveInputs.level) != nil

        if selectedHasLevelInput {
            activeStateMachineName = selectedStateMachineName
            hasListeningInput = selectedHasListeningInput
            hasLevelInput = selectedHasLevelInput
            return
        }

        for candidate in ReactiveInputs.stateMachineCandidates where candidate != fallbackStateMachineName {
            do {
                try viewModel.configureModel(stateMachineName: candidate)
            } catch {
                continue
            }

            let candidateHasListeningInput = viewModel.boolInput(named: ReactiveInputs.listening) != nil
            let candidateHasLevelInput = viewModel.numberInput(named: ReactiveInputs.level) != nil
            if candidateHasLevelInput {
                selectedStateMachineName = candidate
                selectedHasListeningInput = candidateHasListeningInput
                selectedHasLevelInput = true
                break
            }
        }

        // Failed candidate attempts can clear the active state machine; restore a valid one.
        if let selectedStateMachineName {
            try? viewModel.configureModel(stateMachineName: selectedStateMachineName)
        } else {
            try? viewModel.configureModel()
            selectedStateMachineName = viewModel.riveModel?.stateMachine?.name()
            selectedHasListeningInput = viewModel.boolInput(named: ReactiveInputs.listening) != nil
            selectedHasLevelInput = viewModel.numberInput(named: ReactiveInputs.level) != nil
        }

        activeStateMachineName = selectedStateMachineName
        hasListeningInput = selectedHasListeningInput
        hasLevelInput = selectedHasLevelInput
    }

    func updateReactiveInputs(listening: Bool, level: Double, shouldPulse: Bool) {
        guard let riveViewModel else {
            return
        }

        if hasListeningInput {
            riveViewModel.setInput(ReactiveInputs.listening, value: listening)
        }
        if hasLevelInput {
            riveViewModel.setInput(ReactiveInputs.level, value: level)
        }
        if shouldPulse {
            riveViewModel.triggerInput(ReactiveInputs.pulse)
        }
    }

    private func clearCurrentRiveView() {
        riveView?.removeFromSuperview()
        riveView = nil
        riveViewModel = nil
        loadedAssetPath = nil
        activeStateMachineName = nil
        hasListeningInput = false
        hasLevelInput = false
    }
}

private final class HTMLIndicatorContentView: NSView, WKNavigationDelegate {
    private enum Runtime {
        static let style = """
        <style id="kinshasa-runtime-style">
        html, body {
          margin: 0 !important;
          padding: 0 !important;
          width: 100% !important;
          height: 100% !important;
          background: transparent !important;
          overflow: hidden !important;
        }
        .scene-container {
          width: 100% !important;
          height: 100% !important;
          max-width: none !important;
          max-height: none !important;
          cursor: default !important;
        }
        </style>
        """

        static let script = """
        <script id="kinshasa-runtime-script">
        window.__kinshasaState = {
          lastClickAt: 0,
          lastTranscribing: null
        };
        window.__kinshasaDispatchClick = function() {
          try {
            const target = document.querySelector('.scene-container') || document.querySelector('svg') || document.body;
            if (!target) return;
            if (typeof PointerEvent === 'function') {
              const pDown = new PointerEvent('pointerdown', { bubbles: true, cancelable: true, view: window, pointerType: 'mouse', isPrimary: true });
              const pUp = new PointerEvent('pointerup', { bubbles: true, cancelable: true, view: window, pointerType: 'mouse', isPrimary: true });
              target.dispatchEvent(pDown);
              target.dispatchEvent(pUp);
            }
            const down = new MouseEvent('mousedown', { bubbles: true, cancelable: true, view: window });
            const up = new MouseEvent('mouseup', { bubbles: true, cancelable: true, view: window });
            const click = new MouseEvent('click', { bubbles: true, cancelable: true, view: window });
            target.dispatchEvent(down);
            target.dispatchEvent(up);
            target.dispatchEvent(click);
          } catch (_) {}
        };
        window.__kinshasaApplyTranscribingClass = function(transcribing) {
          try {
            const next = !!transcribing;
            if (window.__kinshasaState.lastTranscribing === next) return;
            window.__kinshasaState.lastTranscribing = next;

            const root = document.documentElement;
            if (root) {
              root.classList.toggle('is-transcribing', next);
            }

            const all = document.querySelectorAll('*');
            for (const node of all) {
              node.classList.toggle('is-transcribing', next);
            }
          } catch (_) {}
        };
        window.__kinshasaSetState = function(isListening, isTranscribing, level, pulse) {
          try {
            const listening = !!isListening;
            const transcribing = !!isTranscribing;
            const pulseActive = !!pulse;
            window.__kinshasaApplyTranscribingClass(transcribing);
            const body = document.body;
            if (body) {
              body.classList.toggle('is-listening', listening);
              body.style.background = 'transparent';
            }
            const scene = document.querySelector('.scene-container');
            if (scene) {
              scene.classList.toggle('is-listening', listening);
            }
            const clampedLevel = Math.max(0, Math.min(1, Number(level) || 0));
            document.documentElement.style.setProperty('--mic-level', String(clampedLevel));
            if (listening) {
              const now = Date.now();
              const interval = Math.max(70, 360 - Math.round(clampedLevel * 300));
              const shouldAutoClick = pulseActive || (clampedLevel > 0.04 && (now - window.__kinshasaState.lastClickAt) >= interval);
              if (shouldAutoClick) {
                window.__kinshasaDispatchClick();
                window.__kinshasaState.lastClickAt = now;
              }
            }
          } catch (_) {}
        };
        </script>
        """
    }

    private var webView: WKWebView?
    private var loadedMarkupSignature: Int?
    private var pageLoaded = false
    private var pendingListeningState = false
    private var pendingTranscribingState = false
    private var pendingMicLevel: Double = 0
    private var pendingPulse = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func loadMarkup(_ rawMarkup: String, listening: Bool, transcribing: Bool, micLevel: Double = 0, shouldPulse: Bool = false) -> Bool {
        let trimmed = rawMarkup.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }

        let document = Self.prepareHTMLDocument(from: trimmed)
        let signature = document.hashValue
        pendingListeningState = listening
        pendingTranscribingState = transcribing
        pendingMicLevel = micLevel
        pendingPulse = shouldPulse

        if loadedMarkupSignature == signature {
            setState(listening: listening, transcribing: transcribing, micLevel: micLevel, shouldPulse: shouldPulse)
            return true
        }

        let webView = ensureWebView()
        pageLoaded = false
        loadedMarkupSignature = signature
        webView.loadHTMLString(document, baseURL: nil)
        return true
    }

    func setState(listening: Bool, transcribing: Bool, micLevel: Double = 0, shouldPulse: Bool = false) {
        pendingListeningState = listening
        pendingTranscribingState = transcribing
        pendingMicLevel = micLevel
        pendingPulse = shouldPulse

        guard pageLoaded, let webView else {
            return
        }

        let clampedLevel = max(0, min(1, micLevel))
        let js = String(
            format: "window.__kinshasaSetState && window.__kinshasaSetState(%@, %@, %.4f, %@);",
            listening ? "true" : "false",
            transcribing ? "true" : "false",
            clampedLevel,
            shouldPulse ? "true" : "false"
        )
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        pageLoaded = true
        setState(
            listening: pendingListeningState,
            transcribing: pendingTranscribingState,
            micLevel: pendingMicLevel,
            shouldPulse: pendingPulse
        )
    }

    private func ensureWebView() -> WKWebView {
        if let webView {
            return webView
        }

        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: bounds, configuration: configuration)
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.setValue(false, forKey: "drawsBackground")
        webView.wantsLayer = true
        webView.layer?.backgroundColor = NSColor.clear.cgColor

        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        self.webView = webView
        return webView
    }

    private static func prepareHTMLDocument(from rawMarkup: String) -> String {
        let lowercased = rawMarkup.lowercased()
        var document: String

        if lowercased.contains("<html") {
            document = rawMarkup
        } else {
            document = """
            <!DOCTYPE html>
            <html lang="en">
            <head>
              <meta charset="UTF-8" />
              <meta name="viewport" content="width=device-width, initial-scale=1.0" />
            </head>
            <body>
              <div class="scene-container">
                \(rawMarkup)
              </div>
            </body>
            </html>
            """
        }

        // Convert hover-driven animations into explicit transcribing-state class toggles.
        document = document.replacingOccurrences(of: ":hover", with: ".is-transcribing")
        document = inject(Runtime.style, into: document, beforeClosingTag: "</head>")
        document = inject(Runtime.script, into: document, beforeClosingTag: "</body>")
        return document
    }

    private static func inject(_ snippet: String, into document: String, beforeClosingTag closingTag: String) -> String {
        guard let range = document.range(of: closingTag, options: [.caseInsensitive, .backwards]) else {
            return document + "\n" + snippet
        }

        var mutated = document
        mutated.insert(contentsOf: "\n\(snippet)\n", at: range.lowerBound)
        return mutated
    }
}

@MainActor
final class FloatingBubbleController {
    private let basePanelSize = NSSize(width: 340, height: 58)
    private let baseRivePanelSize = NSSize(width: 180, height: 180)
    private let baseHTMLPanelSize = NSSize(width: 220, height: 220)
    private let minScale: CGFloat = 0.18
    private let maxScale: CGFloat = 1.40
    private let edgePadding: CGFloat = 24

    private var panel: NSPanel?
    private var contentView: BubbleContentView?

    private var rivePanel: NSPanel?
    private var riveContentView: RiveIndicatorContentView?
    private var htmlPanel: NSPanel?
    private var htmlContentView: HTMLIndicatorContentView?
    private var indicatorPosition: FloatingIndicatorPosition = .centerTop
    private var indicatorScale: CGFloat = 1.0

    func setPresentation(position: FloatingIndicatorPosition, sizePercent: Double) {
        indicatorPosition = position
        let normalizedScale = CGFloat(max(18, min(140, sizePercent))) / 100
        indicatorScale = max(minScale, min(maxScale, normalizedScale))
        applyPresentationToVisiblePanels()
    }

    func show(message: String, isRecording: Bool, isTranscribing: Bool, riveAssetPath: String?, htmlIndicatorMarkup: String?) {
        if (isRecording || isTranscribing),
           let htmlIndicatorMarkup,
           showHTMLIndicator(markup: htmlIndicatorMarkup, listening: isRecording, transcribing: isTranscribing)
        {
            panel?.orderOut(nil)
            rivePanel?.orderOut(nil)
            return
        }

        if isRecording,
           let riveAssetPath,
           showRiveIndicator(assetPath: riveAssetPath)
        {
            panel?.orderOut(nil)
            htmlPanel?.orderOut(nil)
            return
        }

        rivePanel?.orderOut(nil)
        htmlPanel?.orderOut(nil)
        let panel = ensurePanel()
        contentView?.update(message: message, isRecording: isRecording)
        let size = panelSize()
        resize(panel, panelSize: size)
        position(panel, panelSize: size, topPadding: 42)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        rivePanel?.orderOut(nil)
        htmlPanel?.orderOut(nil)
    }

    func updateRiveReactiveInputs(listening: Bool, level: Double, shouldPulse: Bool) {
        riveContentView?.updateReactiveInputs(listening: listening, level: level, shouldPulse: shouldPulse)
    }

    func updateHTMLReactiveInputs(listening: Bool, transcribing: Bool, level: Double, shouldPulse: Bool) {
        htmlContentView?.setState(
            listening: listening,
            transcribing: transcribing,
            micLevel: level,
            shouldPulse: shouldPulse
        )
    }

    private func showRiveIndicator(assetPath: String) -> Bool {
        let panel = ensureRivePanel()
        guard riveContentView?.loadRiveAsset(at: assetPath) == true else {
            return false
        }

        let size = rivePanelSize()
        resize(panel, panelSize: size)
        position(panel, panelSize: size, topPadding: 24)
        panel.orderFrontRegardless()
        return true
    }

    private func showHTMLIndicator(markup: String, listening: Bool, transcribing: Bool) -> Bool {
        let panel = ensureHTMLPanel()
        guard htmlContentView?.loadMarkup(markup, listening: listening, transcribing: transcribing) == true else {
            return false
        }

        let size = htmlPanelSize()
        resize(panel, panelSize: size)
        position(panel, panelSize: size, topPadding: 24)
        panel.orderFrontRegardless()
        return true
    }

    private func ensurePanel() -> NSPanel {
        if let panel {
            return panel
        }

        let size = panelSize()
        let panel = makePanel(size: size)
        let content = BubbleContentView(frame: NSRect(origin: .zero, size: size))
        content.update(message: "Listening...", isRecording: true)
        panel.contentView = content
        self.contentView = content
        self.panel = panel
        return panel
    }

    private func ensureRivePanel() -> NSPanel {
        if let rivePanel {
            return rivePanel
        }

        let size = rivePanelSize()
        let panel = makePanel(size: size)
        panel.hasShadow = false
        let content = RiveIndicatorContentView(frame: NSRect(origin: .zero, size: size))
        panel.contentView = content
        self.riveContentView = content
        self.rivePanel = panel
        return panel
    }

    private func ensureHTMLPanel() -> NSPanel {
        if let htmlPanel {
            return htmlPanel
        }

        let size = htmlPanelSize()
        let panel = makePanel(size: size)
        panel.hasShadow = false
        let content = HTMLIndicatorContentView(frame: NSRect(origin: .zero, size: size))
        panel.contentView = content
        htmlContentView = content
        htmlPanel = panel
        return panel
    }

    private func makePanel(size: NSSize) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
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
        return panel
    }

    private func panelSize() -> NSSize {
        scaled(basePanelSize)
    }

    private func rivePanelSize() -> NSSize {
        scaled(baseRivePanelSize)
    }

    private func htmlPanelSize() -> NSSize {
        scaled(baseHTMLPanelSize)
    }

    private func scaled(_ base: NSSize) -> NSSize {
        NSSize(width: base.width * indicatorScale, height: base.height * indicatorScale)
    }

    private func applyPresentationToVisiblePanels() {
        if let panel {
            let size = panelSize()
            resize(panel, panelSize: size)
            position(panel, panelSize: size, topPadding: 42)
        }

        if let rivePanel {
            let size = rivePanelSize()
            resize(rivePanel, panelSize: size)
            position(rivePanel, panelSize: size, topPadding: 24)
        }

        if let htmlPanel {
            let size = htmlPanelSize()
            resize(htmlPanel, panelSize: size)
            position(htmlPanel, panelSize: size, topPadding: 24)
        }
    }

    private func resize(_ panel: NSPanel, panelSize: NSSize) {
        let current = panel.frame
        let origin = NSPoint(x: current.origin.x, y: current.origin.y)
        panel.setFrame(NSRect(origin: origin, size: panelSize), display: true)
        panel.contentView?.frame = NSRect(origin: .zero, size: panelSize)
    }

    private func position(_ panel: NSPanel, panelSize: NSSize, topPadding: CGFloat) {
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main

        guard let screen = targetScreen else {
            return
        }

        let visibleFrame = screen.visibleFrame
        var origin: NSPoint

        switch indicatorPosition {
        case .centerLeft:
            origin = NSPoint(
                x: visibleFrame.minX + edgePadding,
                y: visibleFrame.midY - panelSize.height / 2
            )
        case .centerTop:
            origin = NSPoint(
                x: visibleFrame.midX - panelSize.width / 2,
                y: visibleFrame.maxY - panelSize.height - topPadding
            )
        case .centerRight:
            origin = NSPoint(
                x: visibleFrame.maxX - panelSize.width - edgePadding,
                y: visibleFrame.midY - panelSize.height / 2
            )
        case .bottomLeft:
            origin = NSPoint(
                x: visibleFrame.minX + edgePadding,
                y: visibleFrame.minY + edgePadding
            )
        case .bottomCenter:
            origin = NSPoint(
                x: visibleFrame.midX - panelSize.width / 2,
                y: visibleFrame.minY + edgePadding
            )
        case .bottomRight:
            origin = NSPoint(
                x: visibleFrame.maxX - panelSize.width - edgePadding,
                y: visibleFrame.minY + edgePadding
            )
        }

        origin.x = min(max(origin.x, visibleFrame.minX), visibleFrame.maxX - panelSize.width)
        origin.y = min(max(origin.y, visibleFrame.minY), visibleFrame.maxY - panelSize.height)

        panel.setFrame(NSRect(origin: origin, size: panelSize), display: true)
    }
}
