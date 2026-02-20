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
          lastTranscribing: null,
          levelEMA: 0,
          lastTickAt: 0,
          clickBudget: 0,
          lastDrivenLevel: 0,
          autoClickEnabled: null
        };
        window.__kinshasaDispatchClick = function() {
          try {
            const target = document.querySelector('.scene-container') || document.querySelector('svg') || document.body;
            const click = new MouseEvent('click', { bubbles: true, cancelable: true, view: window });
            if (target) {
              target.dispatchEvent(click);
            }
            document.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
            if (typeof window.dispatchEvent === 'function') {
              window.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
            }
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
            const state = window.__kinshasaState;
            if (state.autoClickEnabled === null) {
              const hasOrbWrapper = !!(document.getElementById('siri-orb') || document.querySelector('.orb-wrapper'));
              const scriptText = Array.from(document.querySelectorAll('script'))
                .map((s) => s.textContent || '')
                .join('\\n');
              const hasSelfMicScript = /getUserMedia|AudioContext|webkitAudioContext/.test(scriptText);
              state.autoClickEnabled = !(hasOrbWrapper || hasSelfMicScript);
            }
            state.levelEMA += (clampedLevel - state.levelEMA) * 0.18;
            const drivenLevel = Math.max(clampedLevel, state.levelEMA * 0.9);
            const risingEdge = Math.max(0, drivenLevel - (state.lastDrivenLevel || 0));
            state.lastDrivenLevel = drivenLevel;
            const now = (typeof performance !== 'undefined' && performance.now) ? performance.now() : Date.now();
            if (!state.lastTickAt || !Number.isFinite(state.lastTickAt)) {
              state.lastTickAt = now;
            }
            const deltaMs = Math.max(0, Math.min(200, now - state.lastTickAt));
            state.lastTickAt = now;
            const deltaSeconds = deltaMs / 1000;
            const strobe = (listening && drivenLevel > 0.3) ? (Math.sin(now * 0.03) * drivenLevel * 0.4) : 0;
            const brightness = Math.max(0.6, 0.6 + (drivenLevel * 2.0) + strobe);
            const pulseSpeed = listening ? Math.max(0.4, 2.5 - (drivenLevel * 2.1)) : (transcribing ? 0.8 : 2.5);
            const auraBaseShadow = 15 + (drivenLevel * 35);
            const auraPeakShadow = 35 + (drivenLevel * 85);
            const auraBaseOpacity = 0.1 + (drivenLevel * 0.5);
            const auraPeakOpacity = Math.min(1, 0.35 + (drivenLevel * 0.65));

            document.documentElement.style.setProperty('--core-brightness', brightness.toFixed(4));
            document.documentElement.style.setProperty('--pulse-speed', pulseSpeed.toFixed(4) + 's');
            document.documentElement.style.setProperty('--pulse-delay', (pulseSpeed / 2).toFixed(4) + 's');
            document.documentElement.style.setProperty('--aura-base-shadow', auraBaseShadow.toFixed(2) + 'px');
            document.documentElement.style.setProperty('--aura-peak-shadow', auraPeakShadow.toFixed(2) + 'px');
            document.documentElement.style.setProperty('--aura-base-opacity', auraBaseOpacity.toFixed(4));
            document.documentElement.style.setProperty('--aura-peak-opacity', auraPeakOpacity.toFixed(4));

            const orb = document.getElementById('siri-orb') || document.querySelector('.orb-wrapper');
            const svg = document.querySelector('.siri-svg');
            const status = document.getElementById('status-text');
            const classicContainer = document.getElementById('mic-container') || document.querySelector('.container');
            const glowReactor = document.getElementById('glow-reactor');

            // Compatibility mode for orb templates that try to own getUserMedia in-page.
            if (orb) {
              const orbShouldBeActive = listening || transcribing;
              orb.classList.toggle('active', orbShouldBeActive);
              if (listening) {
                const dynamicScale = 1.3 + (drivenLevel * 0.42);
                orb.style.transform = 'scale(' + dynamicScale.toFixed(4) + ')';
              } else if (transcribing) {
                orb.style.transform = 'scale(1.18)';
              } else {
                orb.style.transform = '';
              }
            }
            if (svg) {
              if (listening) {
                const brightness = 1 + (drivenLevel * 0.72);
                svg.style.filter = 'brightness(' + brightness.toFixed(4) + ')';
              } else if (transcribing) {
                svg.style.filter = 'brightness(1.18)';
              } else {
                svg.style.filter = '';
              }
            }
            if (classicContainer) {
              if (listening) {
                const classicScale = 1 + (drivenLevel * 0.10);
                classicContainer.style.transform = 'scale(' + classicScale.toFixed(4) + ')';
                classicContainer.style.transition = 'transform 0.05s ease-out';
              } else if (transcribing) {
                classicContainer.style.transform = 'scale(1.03)';
                classicContainer.style.transition = 'transform 0.18s ease-out';
              } else {
                classicContainer.style.transform = '';
                classicContainer.style.transition = '';
              }
            }
            if (glowReactor) {
              glowReactor.style.filter = 'brightness(' + brightness.toFixed(4) + ')';
            }
            if (status) {
              if (listening) {
                status.textContent = 'Listening...';
              } else if (transcribing) {
                status.textContent = 'Transcribing...';
              } else {
                status.textContent = 'Ready';
              }
            }

            if (listening) {
              let targetClicksPerSecond = 0;
              if (drivenLevel > 0.03) {
                targetClicksPerSecond = Math.pow(drivenLevel, 1.6) * 52;
                targetClicksPerSecond += risingEdge * 24;
              }
              if (pulseActive && drivenLevel > 0.05) {
                state.clickBudget += 0.8;
              }
              targetClicksPerSecond = Math.min(48, targetClicksPerSecond);
              document.documentElement.style.setProperty('--mic-click-rate', targetClicksPerSecond.toFixed(2));

              if (state.autoClickEnabled) {
                state.clickBudget += targetClicksPerSecond * deltaSeconds;
                state.clickBudget = Math.min(state.clickBudget, 12);
                const maxBurst = pulseActive ? 6 : 4;
                let fired = 0;
                while (state.clickBudget >= 1 && fired < maxBurst) {
                  window.__kinshasaDispatchClick();
                  state.lastClickAt = Date.now();
                  state.clickBudget -= 1;
                  fired += 1;
                }
              }
            } else {
              state.levelEMA = 0;
              state.clickBudget = 0;
              state.lastDrivenLevel = 0;
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
        let sanitizedMarkup = stripInPageMicScriptsIfNeeded(rawMarkup)
        let lowercased = sanitizedMarkup.lowercased()
        var document: String

        if lowercased.contains("<html") {
            document = sanitizedMarkup
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
                \(sanitizedMarkup)
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

    static func preferredBaseSize(from rawMarkup: String) -> NSSize? {
        let styleSource = extractStyleBlocks(from: rawMarkup)
        let source = styleSource.isEmpty ? rawMarkup : styleSource

        let widths = pixelValues(for: "width", in: source).filter { $0 >= 140 && $0 <= 1200 }
        let heights = pixelValues(for: "height", in: source).filter { $0 >= 140 && $0 <= 1200 }

        if let width = widths.max(), let height = heights.max() {
            return NSSize(width: width, height: height)
        }

        if let viewBoxSize = svgViewBoxSize(from: rawMarkup) {
            let clampedWidth = min(max(viewBoxSize.width, 140), 1200)
            let clampedHeight = min(max(viewBoxSize.height, 140), 1200)
            return NSSize(width: clampedWidth, height: clampedHeight)
        }

        return nil
    }

    private static func inject(_ snippet: String, into document: String, beforeClosingTag closingTag: String) -> String {
        guard let range = document.range(of: closingTag, options: [.caseInsensitive, .backwards]) else {
            return document + "\n" + snippet
        }

        var mutated = document
        mutated.insert(contentsOf: "\n\(snippet)\n", at: range.lowerBound)
        return mutated
    }

    private static func stripInPageMicScriptsIfNeeded(_ markup: String) -> String {
        let lower = markup.lowercased()
        guard lower.contains("getusermedia")
            || lower.contains("audiocontext")
            || lower.contains("webkitaudiocontext")
        else {
            return markup
        }

        return markup.replacingOccurrences(
            of: "<script\\b[^>]*>[\\s\\S]*?<\\/script>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    private static func extractStyleBlocks(from markup: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<style\\b[^>]*>([\\s\\S]*?)<\\/style>", options: [.caseInsensitive]) else {
            return ""
        }

        let nsRange = NSRange(markup.startIndex..., in: markup)
        let matches = regex.matches(in: markup, options: [], range: nsRange)
        guard !matches.isEmpty else {
            return ""
        }

        var chunks: [String] = []
        chunks.reserveCapacity(matches.count)
        for match in matches {
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: markup)
            else {
                continue
            }
            chunks.append(String(markup[range]))
        }

        return chunks.joined(separator: "\n")
    }

    private static func pixelValues(for property: String, in source: String) -> [CGFloat] {
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: property))\\s*:\\s*([0-9]+(?:\\.[0-9]+)?)px"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        let nsRange = NSRange(source.startIndex..., in: source)
        let matches = regex.matches(in: source, options: [], range: nsRange)
        var values: [CGFloat] = []
        values.reserveCapacity(matches.count)

        for match in matches {
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: source),
                  let value = Double(source[range])
            else {
                continue
            }
            values.append(CGFloat(value))
        }

        return values
    }

    private static func svgViewBoxSize(from markup: String) -> NSSize? {
        guard let regex = try? NSRegularExpression(pattern: "viewBox\\s*=\\s*['\\\"]([^'\\\"]+)['\\\"]", options: [.caseInsensitive]) else {
            return nil
        }

        let nsRange = NSRange(markup.startIndex..., in: markup)
        guard let match = regex.firstMatch(in: markup, options: [], range: nsRange),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: markup)
        else {
            return nil
        }

        let raw = markup[range]
        let parts = raw
            .split { $0 == " " || $0 == "," || $0 == "\t" || $0 == "\n" || $0 == "\r" }
            .compactMap { Double($0) }

        guard parts.count >= 4 else {
            return nil
        }

        return NSSize(width: CGFloat(parts[2]), height: CGFloat(parts[3]))
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
    private var activeHTMLBasePanelSize: NSSize
    private var indicatorPosition: FloatingIndicatorPosition = .centerTop
    private var indicatorScale: CGFloat = 1.0

    init() {
        activeHTMLBasePanelSize = baseHTMLPanelSize
    }

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
        activeHTMLBasePanelSize = HTMLIndicatorContentView.preferredBaseSize(from: markup) ?? baseHTMLPanelSize
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
        scaled(activeHTMLBasePanelSize)
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
