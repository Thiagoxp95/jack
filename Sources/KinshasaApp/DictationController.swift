import ApplicationServices
import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class DictationController: ObservableObject {
    private struct LiveTranscriptionResult {
        let text: String
        let backend: String
        let snapshotDuration: TimeInterval
        let completedAt: Date
    }

    @Published var mode: ShortcutMode {
        didSet {
            interpreter.setMode(mode)
            UserDefaults.standard.set(mode.rawValue, forKey: DefaultsKey.mode)
            if isRecording {
                startHoldReleaseWatchdogIfNeeded()
            }
            if !isRecording, !isTranscribing, !isPreparingModel {
                if keyboardMonitoringGranted {
                    statusText = "Ready. Shortcut mode: \(mode.title)."
                } else {
                    statusText = "Shortcut mode: \(mode.title). Grant Input Monitoring for global \(invocationKeyDisplayName)."
                }
            }
        }
    }

    @Published private(set) var invocationKeyCode: Int64
    @Published var isCapturingInvocationKey = false
    @Published var statusText: String
    @Published var lastTranscript: String
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var isPreparingModel = false
    @Published var accessibilityGranted = AXIsProcessTrusted()
    @Published var keyboardMonitoringGranted = CGPreflightListenEventAccess()
    @Published var microphoneGranted = false
    @Published var duckingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(duckingEnabled, forKey: DefaultsKey.duckingEnabled)
            syncDuckingForCurrentSession()
        }
    }
    @Published var duckingAmountPercent: Double {
        didSet {
            let clamped = min(max(duckingAmountPercent, 0), 90)
            if clamped != duckingAmountPercent {
                duckingAmountPercent = clamped
                return
            }

            UserDefaults.standard.set(clamped, forKey: DefaultsKey.duckingAmountPercent)
            syncDuckingForCurrentSession()
        }
    }
    @Published var keepModelWarmEnabled: Bool {
        didSet {
            UserDefaults.standard.set(keepModelWarmEnabled, forKey: DefaultsKey.keepModelWarmEnabled)
            configureKeepModelWarmLoop()
        }
    }
    @Published var keepModelWarmOnlyOnPower: Bool {
        didSet {
            UserDefaults.standard.set(keepModelWarmOnlyOnPower, forKey: DefaultsKey.keepModelWarmOnlyOnPower)
            configureKeepModelWarmLoop()
        }
    }
    @Published var riveIndicatorEnabled: Bool {
        didSet {
            UserDefaults.standard.set(riveIndicatorEnabled, forKey: DefaultsKey.riveIndicatorEnabled)
            syncRiveIndicatorForCurrentSession()
        }
    }
    @Published var listeningRiveAssetPath: String {
        didSet {
            UserDefaults.standard.set(listeningRiveAssetPath, forKey: DefaultsKey.listeningRiveAssetPath)
            syncRiveIndicatorForCurrentSession()
        }
    }
    @Published var customSVGIndicatorEnabled: Bool {
        didSet {
            UserDefaults.standard.set(customSVGIndicatorEnabled, forKey: DefaultsKey.customSVGIndicatorEnabled)
            syncRiveIndicatorForCurrentSession()
        }
    }
    @Published var customSVGIndicatorMarkup: String {
        didSet {
            UserDefaults.standard.set(customSVGIndicatorMarkup, forKey: DefaultsKey.customSVGIndicatorMarkup)
            syncRiveIndicatorForCurrentSession()
        }
    }
    @Published var floatingIndicatorPosition: FloatingIndicatorPosition {
        didSet {
            UserDefaults.standard.set(floatingIndicatorPosition.rawValue, forKey: DefaultsKey.floatingIndicatorPosition)
            syncFloatingIndicatorPresentationForCurrentSession(previewIfIdle: true)
        }
    }
    @Published var floatingIndicatorSizePercent: Double {
        didSet {
            let clamped = min(max(floatingIndicatorSizePercent, 18), 140)
            if clamped != floatingIndicatorSizePercent {
                floatingIndicatorSizePercent = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: DefaultsKey.floatingIndicatorSizePercent)
            syncFloatingIndicatorPresentationForCurrentSession(previewIfIdle: isAdjustingIndicatorSize)
        }
    }
    @Published private(set) var keepModelWarmStatus: String
    @Published var lastShortcutEventAt: Date?
    @Published var lastTranscriptionLatency: TimeInterval?
    @Published var lastTranscriptionBackend: String?

    private var initialized = false
    private var interpreter: ShortcutInterpreter
    private let shortcutMonitor = GlobalFnShortcutMonitor()
    private let audioCapture = AudioCaptureService()
    private let transcription = ParakeetTranscriptionService()
    private let pasteService = PasteService()
    private let duckingService = SystemAudioDuckingService()
    private let bubble = FloatingBubbleController()
    private let bootstrapper = LocalParakeetBootstrapper()
    private var parakeetConfiguration: ParakeetConfiguration?
    private let parakeetModel: String
    private var bubbleHideTask: Task<Void, Never>?
    private var liveTranscriptionLoopTask: Task<Void, Never>?
    private var riveReactiveLoopTask: Task<Void, Never>?
    private var keepModelWarmTask: Task<Void, Never>?
    private var holdReleaseWatchdogTask: Task<Void, Never>?
    private var indicatorPreviewHideTask: Task<Void, Never>?
    private var liveTranscriptionInFlight = false
    private var liveSnapshotInFlightDuration: TimeInterval?
    private var latestLiveTranscription: LiveTranscriptionResult?
    private var lastKeepModelWarmAt: Date?
    private var smoothedRiveLevel: Double = 0
    private var previousRiveLevel: Double = 0
    private var riveObservedPeakLevel: Double = 0.25
    private var lastRivePulseAt: Date?
    private var holdReleaseMissingSince: Date?
    private var isAdjustingIndicatorSize = false
    private var localKeyCaptureMonitor: Any?
    private var globalKeyCaptureMonitor: Any?

    private let liveSnapshotMinDuration: TimeInterval = 0.75
    private let liveSnapshotInterval: TimeInterval = 0.80
    private let liveSnapshotMaxDuration: TimeInterval = 2.30
    private let riveReactivePollInterval: TimeInterval = 0.05
    private let riveReactivePulseThreshold: Double = 0.14
    private let riveReactivePulseCooldown: TimeInterval = 0.40
    private let keepModelWarmInterval: TimeInterval = 45
    private let liveReuseMaxAudioGap: TimeInterval = 0.30
    private let liveReuseMaxAge: TimeInterval = 1.30
    private let liveReuseWaitTimeout: TimeInterval = 0.24
    private let liveImmediateReuseMaxGap: TimeInterval = 0.16
    private let liveReuseMinCoverageRatio: Double = 0.82
    private let holdReleaseWatchPollInterval: TimeInterval = 0.05
    private let holdReleaseDebounce: TimeInterval = 0.12
    private let pipelineTimingEnabled = ProcessInfo.processInfo.environment["KINSHASA_TIMING"] == "1"

    private enum DefaultsKey {
        static let mode = "shortcut_mode"
        static let invocationKeyCode = "shortcut_invocation_key_code"
        static let duckingEnabled = "ducking_enabled"
        static let duckingAmountPercent = "ducking_amount_percent"
        static let keepModelWarmEnabled = "keep_model_warm_enabled"
        static let keepModelWarmOnlyOnPower = "keep_model_warm_only_on_power"
        static let riveIndicatorEnabled = "rive_indicator_enabled"
        static let listeningRiveAssetPath = "listening_rive_asset_path"
        static let customSVGIndicatorEnabled = "custom_svg_indicator_enabled"
        static let customSVGIndicatorMarkup = "custom_svg_indicator_markup"
        static let floatingIndicatorPosition = "floating_indicator_position"
        static let floatingIndicatorSizePercent = "floating_indicator_size_percent"
    }

    init() {
        let defaults = UserDefaults.standard
        let initialMode = ShortcutMode(rawValue: defaults.string(forKey: DefaultsKey.mode) ?? "") ?? .toggle
        let initialInvocationKeyCode: Int64
        if let stored = defaults.object(forKey: DefaultsKey.invocationKeyCode) as? Int {
            initialInvocationKeyCode = Int64(stored)
        } else {
            initialInvocationKeyCode = InvocationKey.defaultKeyCode
        }

        mode = initialMode
        invocationKeyCode = initialInvocationKeyCode
        duckingEnabled = defaults.object(forKey: DefaultsKey.duckingEnabled) as? Bool ?? false
        let storedDuckingAmount = defaults.object(forKey: DefaultsKey.duckingAmountPercent) as? Double ?? 40
        duckingAmountPercent = min(max(storedDuckingAmount, 0), 90)
        keepModelWarmEnabled = true
        keepModelWarmOnlyOnPower = false
        UserDefaults.standard.set(true, forKey: DefaultsKey.keepModelWarmEnabled)
        UserDefaults.standard.set(false, forKey: DefaultsKey.keepModelWarmOnlyOnPower)
        let defaultRiveAssetPath = Self.defaultListeningRiveAssetPath()
        listeningRiveAssetPath = defaults.string(forKey: DefaultsKey.listeningRiveAssetPath) ?? defaultRiveAssetPath
        riveIndicatorEnabled = defaults.object(forKey: DefaultsKey.riveIndicatorEnabled) as? Bool ?? !defaultRiveAssetPath.isEmpty
        customSVGIndicatorMarkup = defaults.string(forKey: DefaultsKey.customSVGIndicatorMarkup) ?? ""
        customSVGIndicatorEnabled = defaults.object(forKey: DefaultsKey.customSVGIndicatorEnabled) as? Bool ?? false
        let rawPosition = defaults.string(forKey: DefaultsKey.floatingIndicatorPosition) ?? FloatingIndicatorPosition.centerTop.rawValue
        floatingIndicatorPosition = FloatingIndicatorPosition(rawValue: rawPosition) ?? .centerTop
        let storedIndicatorSize = defaults.object(forKey: DefaultsKey.floatingIndicatorSizePercent) as? Double ?? 35
        floatingIndicatorSizePercent = min(max(storedIndicatorSize, 18), 140)
        keepModelWarmStatus = "Off"
        interpreter = ShortcutInterpreter(mode: initialMode)
        statusText = "Preparing local speech model..."
        lastTranscript = ""

        parakeetModel = ProcessInfo.processInfo.environment["PARAKEET_MODEL"]
            ?? "mlx-community/parakeet-tdt-0.6b-v2"

        microphoneGranted = audioCapture.microphonePermissionGranted
        shortcutMonitor.setInvocationKeyCode(initialInvocationKeyCode)

        shortcutMonitor.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleShortcutEvent(event)
            }
        }

        bubble.setPresentation(position: floatingIndicatorPosition, sizePercent: floatingIndicatorSizePercent)
    }

    func initialize() async {
        guard !initialized else {
            return
        }

        initialized = true
        let shortcutStarted = await refreshPermissions(prompt: true)
        configureKeepModelWarmLoop()

        Task {
            _ = await prepareParakeetIfNeeded(showReadyStatus: shortcutStarted)
        }
    }

    @discardableResult
    func refreshPermissions(prompt: Bool) async -> Bool {
        accessibilityGranted = requestAccessibilityPermission(prompt: prompt)
        keyboardMonitoringGranted = requestKeyboardMonitoringPermission(prompt: prompt)
        microphoneGranted = await audioCapture.requestMicrophonePermissionIfNeeded(prompt: prompt)
        return startShortcutMonitor()
    }

    func startFromUI() {
        Task {
            await beginRecording()
        }
    }

    func stopFromUI() {
        stopRecordingAndTranscribe()
    }

    func toggleFromUI() {
        if isRecording {
            stopRecordingAndTranscribe()
        } else {
            Task {
                await beginRecording()
            }
        }
    }

    var invocationKeyDisplayName: String {
        InvocationKey.displayName(for: invocationKeyCode)
    }

    var activeModelText: String {
        parakeetModel
    }

    var duckingAmountText: String {
        "\(Int(duckingAmountPercent.rounded()))%"
    }

    var listeningRiveAssetPathText: String {
        let trimmed = listeningRiveAssetPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Not set" : trimmed
    }

    var customSVGIndicatorSummaryText: String {
        let trimmed = customSVGIndicatorMarkup.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "No markup"
        }

        return "\(trimmed.count) chars"
    }

    var floatingIndicatorSizeText: String {
        "\(Int(floatingIndicatorSizePercent.rounded()))%"
    }

    var keepModelWarmStatusText: String {
        guard keepModelWarmEnabled else {
            return "Off"
        }

        guard let lastKeepModelWarmAt else {
            return keepModelWarmStatus
        }

        return "\(keepModelWarmStatus) · last ping \(lastKeepModelWarmAt.formatted(date: .omitted, time: .standard))"
    }

    var lastLatencyText: String {
        guard let lastTranscriptionLatency else {
            return "No transcription completed yet"
        }
        return String(format: "%.2fs", lastTranscriptionLatency)
    }

    var lastBackendText: String {
        lastTranscriptionBackend ?? "No transcription completed yet"
    }

    func startInvocationKeyCapture() {
        guard !isCapturingInvocationKey else {
            return
        }

        isCapturingInvocationKey = true
        statusText = "Press the key to use globally (left/right modifiers supported)."
        installInvocationKeyCaptureMonitors()
    }

    func cancelInvocationKeyCapture() {
        guard isCapturingInvocationKey else {
            return
        }

        isCapturingInvocationKey = false
        removeInvocationKeyCaptureMonitors()
        statusText = "Invocation key capture canceled."
    }

    func requestKeyboardPrompt() {
        keyboardMonitoringGranted = requestKeyboardMonitoringPermission(prompt: true)
        _ = startShortcutMonitor()
    }

    func chooseListeningRiveAsset() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "riv")].compactMap { $0 }
        panel.directoryURL = URL(fileURLWithPath: ("~/Downloads" as NSString).expandingTildeInPath, isDirectory: true)

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return
        }

        listeningRiveAssetPath = selectedURL.path
    }

    func clearListeningRiveAsset() {
        listeningRiveAssetPath = ""
    }

    func pasteCustomSVGIndicatorMarkupFromClipboard() {
        let pasteboard = NSPasteboard.general
        guard let rawString = pasteboard.string(forType: .string) else {
            return
        }

        customSVGIndicatorMarkup = rawString
    }

    func chooseCustomSVGIndicatorFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "html"),
            UTType(filenameExtension: "htm"),
            UTType(filenameExtension: "svg"),
            UTType.plainText,
        ].compactMap { $0 }
        panel.directoryURL = URL(fileURLWithPath: ("~/Downloads" as NSString).expandingTildeInPath, isDirectory: true)

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return
        }

        guard let rawData = try? Data(contentsOf: selectedURL),
              let rawString = String(data: rawData, encoding: .utf8)
        else {
            return
        }

        customSVGIndicatorMarkup = rawString
    }

    func clearCustomSVGIndicatorMarkup() {
        customSVGIndicatorMarkup = ""
    }

    func setFloatingIndicatorSizeEditing(_ editing: Bool) {
        isAdjustingIndicatorSize = editing
        if editing {
            showIndicatorPreview()
        } else {
            scheduleIndicatorPreviewHide(delay: 0.6)
        }
    }

    func openInputMonitoringSettings() {
        openSettingsURL("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    func openAccessibilitySettings() {
        openSettingsURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openMicrophoneSettings() {
        openSettingsURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    func revealCurrentAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func applicationWillTerminate() {
        riveReactiveLoopTask?.cancel()
        riveReactiveLoopTask = nil
        stopHoldReleaseWatchdog()
        keepModelWarmTask?.cancel()
        keepModelWarmTask = nil
        indicatorPreviewHideTask?.cancel()
        indicatorPreviewHideTask = nil
        duckingService.restoreIfNeeded()
    }

    var currentAppIdentityText: String {
        let bundleName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "Unknown"
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown.bundle.id"
        return "\(bundleName) (\(bundleID))"
    }

    var currentAppPathText: String {
        Bundle.main.bundleURL.path
    }

    var lastShortcutSignalText: String {
        guard let lastShortcutEventAt else {
            return "No \(invocationKeyDisplayName) events detected yet"
        }
        return "Last detected at \(lastShortcutEventAt.formatted(date: .omitted, time: .standard))"
    }

    private func handleShortcutEvent(_ event: ShortcutEvent) {
        guard !isCapturingInvocationKey else {
            return
        }

        lastShortcutEventAt = .now

        guard let action = interpreter.handle(event) else {
            return
        }

        switch action {
        case .toggleRecording:
            if isRecording {
                stopRecordingAndTranscribe()
            } else {
                Task {
                    await beginRecording()
                }
            }
        case .startRecording:
            Task {
                await beginRecording()
            }
        case .stopRecording:
            stopRecordingAndTranscribe()
        }
    }

    private func beginRecording() async {
        guard !isRecording, !isTranscribing else {
            return
        }

        guard await prepareParakeetIfNeeded(showReadyStatus: true) else {
            return
        }

        guard let configuration = parakeetConfiguration else {
            handleError("Speech model is still preparing. Try again in a few seconds.")
            return
        }

        microphoneGranted = await audioCapture.requestMicrophonePermissionIfNeeded(prompt: true)
        guard microphoneGranted else {
            handleError("Microphone permission is required.")
            return
        }

        do {
            try audioCapture.startRecording()
            isRecording = true
            latestLiveTranscription = nil
            liveTranscriptionInFlight = false
            liveSnapshotInFlightDuration = nil
            startHoldReleaseWatchdogIfNeeded()
            statusText = "Listening..."
            showBubble(message: "Listening...", isRecording: true)
            startRiveReactiveLoopIfNeeded()
            applyDuckingIfNeeded()
            startLiveTranscriptionLoop(configuration: configuration)
        } catch {
            handleError(error.localizedDescription)
        }
    }

    private func stopRecordingAndTranscribe() {
        guard isRecording else {
            return
        }

        guard let configuration = parakeetConfiguration else {
            handleError("Speech model is still preparing. Try again in a few seconds.")
            return
        }

        do {
            let stoppedRecording = try audioCapture.stopRecording()
            let recordedFile = stoppedRecording.url
            let finalDuration = stoppedRecording.duration

            isRecording = false
            isTranscribing = true
            stopLiveTranscriptionLoop()
            stopHoldReleaseWatchdog()
            stopRiveReactiveLoop(resetInputs: false)
            duckingService.restoreIfNeeded()
            statusText = "Transcribing..."
            showBubble(message: "Transcribing...", isRecording: false, isTranscribing: true)

            Task(priority: .userInitiated) {
                let startedAt = Date()
                defer {
                    try? FileManager.default.removeItem(at: recordedFile)
                }

                do {
                    let waitStartedAt = Date()
                    if let reusedLive = reusableLiveTranscription(finalDuration: finalDuration),
                       shouldImmediatelyReuseLiveTranscription(reusedLive, finalDuration: finalDuration)
                    {
                        let totalLatency = Date().timeIntervalSince(startedAt)
                        let waitLatency = Date().timeIntervalSince(waitStartedAt)
                        await MainActor.run {
                            logPipelineTiming(
                                String(
                                    format: "stop->reuse total=%.3fs wait=%.3fs tail=%.3fs backend=%@",
                                    totalLatency,
                                    waitLatency,
                                    finalDuration - reusedLive.snapshotDuration,
                                    reusedLive.backend
                                )
                            )
                            lastTranscriptionLatency = totalLatency
                            lastTranscriptionBackend = "\(reusedLive.backend) (live reuse)"
                            handleTranscriptionResult(reusedLive.text)
                        }
                        return
                    }

                    let shouldWaitForLiveReuse = shouldWaitForReusableLiveTranscription(finalDuration: finalDuration)

                    if shouldWaitForLiveReuse,
                       let reusedLive = await waitForReusableLiveTranscription(finalDuration: finalDuration, timeout: liveReuseWaitTimeout)
                    {
                        let totalLatency = Date().timeIntervalSince(startedAt)
                        let waitLatency = Date().timeIntervalSince(waitStartedAt)
                        await MainActor.run {
                            logPipelineTiming(
                                String(
                                    format: "stop->reuse total=%.3fs wait=%.3fs tail=%.3fs backend=%@",
                                    totalLatency,
                                    waitLatency,
                                    finalDuration - reusedLive.snapshotDuration,
                                    reusedLive.backend
                                )
                            )
                            lastTranscriptionLatency = totalLatency
                            lastTranscriptionBackend = "\(reusedLive.backend) (live reuse)"
                            handleTranscriptionResult(reusedLive.text)
                        }
                        return
                    }

                    let waitLatency = Date().timeIntervalSince(waitStartedAt)
                    let result = try await transcription.transcribe(audioFileURL: recordedFile, configuration: configuration)

                    let totalLatency = Date().timeIntervalSince(startedAt)
                    await MainActor.run {
                        logPipelineTiming(
                            String(
                                format: "stop->final total=%.3fs wait=%.3fs backend=%@",
                                totalLatency,
                                waitLatency,
                                result.backend
                            )
                        )
                        lastTranscriptionLatency = totalLatency
                        lastTranscriptionBackend = result.backend
                        handleTranscriptionResult(result.text)
                    }
                } catch {
                    await MainActor.run {
                        handleError(error.localizedDescription)
                        isTranscribing = false
                    }
                }
            }
        } catch {
            stopHoldReleaseWatchdog()
            stopRiveReactiveLoop(resetInputs: true)
            duckingService.restoreIfNeeded()
            handleError(error.localizedDescription)
        }
    }

    private func prepareParakeetIfNeeded(showReadyStatus: Bool) async -> Bool {
        if parakeetConfiguration != nil {
            return true
        }

        isPreparingModel = true
        statusText = "Preparing local speech model (first run may take a minute)..."

        defer {
            isPreparingModel = false
        }

        do {
            let configuration = try await bootstrapper.ensureReady(model: parakeetModel)
            statusText = "Warming speech engine..."
            try await transcription.prepare(configuration: configuration)
            parakeetConfiguration = configuration

            if showReadyStatus, !isRecording, !isTranscribing {
                statusText = "Ready. Press \(invocationKeyDisplayName) globally (\(mode.title))."
            }

            return true
        } catch {
            handleError("Could not prepare local speech model. \(error.localizedDescription)")
            return false
        }
    }

    private func handleTranscriptionResult(_ text: String) {
        isTranscribing = false

        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            statusText = "No speech detected."
            showTransientBubble(message: "No speech detected")
            return
        }

        lastTranscript = cleaned

        let pasteStartedAt = Date()
        let didPaste = pasteService.copyAndPaste(cleaned)
        let pasteLatency = Date().timeIntervalSince(pasteStartedAt)
        logPipelineTiming(
            String(
                format: "paste latency=%.3fs chars=%d success=%@",
                pasteLatency,
                cleaned.count,
                didPaste ? "yes" : "no"
            )
        )
        if didPaste {
            statusText = "Transcribed and pasted."
            showTransientBubble(message: "Pasted")
        } else {
            statusText = "Transcribed and copied. Grant Accessibility for auto-paste."
            showTransientBubble(message: "Copied")
        }
    }

    private func handleError(_ message: String) {
        if !isRecording {
            stopHoldReleaseWatchdog()
            stopRiveReactiveLoop(resetInputs: true)
            duckingService.restoreIfNeeded()
        }
        statusText = message
        showTransientBubble(message: "Error", duration: 1.6)
    }

    private func applyDuckingIfNeeded() {
        guard duckingEnabled else {
            duckingService.restoreIfNeeded()
            return
        }

        _ = duckingService.applyDucking(reductionPercent: duckingAmountPercent)
    }

    private func syncDuckingForCurrentSession() {
        guard isRecording else {
            if !duckingEnabled {
                duckingService.restoreIfNeeded()
            }
            return
        }

        applyDuckingIfNeeded()
    }

    private func startHoldReleaseWatchdogIfNeeded() {
        stopHoldReleaseWatchdog()

        guard mode == .hold else {
            return
        }

        holdReleaseMissingSince = nil
        let pollNanos = UInt64(holdReleaseWatchPollInterval * 1_000_000_000)

        holdReleaseWatchdogTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else {
                return
            }

            while !Task.isCancelled {
                self.tickHoldReleaseWatchdog()
                guard !Task.isCancelled else {
                    return
                }
                try? await Task.sleep(nanoseconds: pollNanos)
            }
        }
    }

    private func stopHoldReleaseWatchdog() {
        holdReleaseWatchdogTask?.cancel()
        holdReleaseWatchdogTask = nil
        holdReleaseMissingSince = nil
    }

    private func tickHoldReleaseWatchdog() {
        guard isRecording, mode == .hold else {
            holdReleaseMissingSince = nil
            return
        }

        let isPressed = shortcutMonitor.isInvocationKeyCurrentlyPressed()
        if isPressed {
            holdReleaseMissingSince = nil
            return
        }

        if holdReleaseMissingSince == nil {
            holdReleaseMissingSince = .now
            return
        }

        guard let holdReleaseMissingSince,
              Date().timeIntervalSince(holdReleaseMissingSince) >= holdReleaseDebounce
        else {
            return
        }

        stopRecordingAndTranscribe()
    }

    private func syncRiveIndicatorForCurrentSession() {
        syncFloatingIndicatorPresentationForCurrentSession(previewIfIdle: false)
        if isTranscribing {
            showBubble(message: "Transcribing...", isRecording: false, isTranscribing: true)
            return
        }

        guard isRecording else {
            stopRiveReactiveLoop(resetInputs: true)
            return
        }

        showBubble(message: "Listening...", isRecording: true)
        startRiveReactiveLoopIfNeeded()
    }

    private func startRiveReactiveLoopIfNeeded() {
        stopRiveReactiveLoop(resetInputs: false)

        guard shouldRunReactiveIndicatorLoopDuringRecording() else {
            return
        }

        smoothedRiveLevel = 0
        previousRiveLevel = 0
        riveObservedPeakLevel = 0.25
        lastRivePulseAt = nil
        if riveAssetPathIfEnabled(forRecordingState: true) != nil {
            bubble.updateRiveReactiveInputs(listening: true, level: 0, shouldPulse: false)
        }
        if customSVGMarkupIfEnabled(forRecordingState: true) != nil {
            bubble.updateHTMLReactiveInputs(listening: true, transcribing: false, level: 0, shouldPulse: false)
        }

        let pollNanos = UInt64(riveReactivePollInterval * 1_000_000_000)
        riveReactiveLoopTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else {
                return
            }

            while !Task.isCancelled {
                await self.tickRiveReactiveInputs()
                guard !Task.isCancelled else {
                    return
                }
                try? await Task.sleep(nanoseconds: pollNanos)
            }
        }
    }

    private func stopRiveReactiveLoop(resetInputs: Bool) {
        riveReactiveLoopTask?.cancel()
        riveReactiveLoopTask = nil
        smoothedRiveLevel = 0
        previousRiveLevel = 0
        riveObservedPeakLevel = 0.25
        lastRivePulseAt = nil

        if resetInputs {
            bubble.updateRiveReactiveInputs(listening: false, level: 0, shouldPulse: false)
            bubble.updateHTMLReactiveInputs(listening: false, transcribing: false, level: 0, shouldPulse: false)
        }
    }

    private func tickRiveReactiveInputs() async {
        guard isRecording, shouldRunReactiveIndicatorLoopDuringRecording() else {
            return
        }

        let rawLevel = audioCapture.currentInputLevelNormalized()
        riveObservedPeakLevel = max(riveObservedPeakLevel * 0.996, rawLevel)
        let leveled = min(max(rawLevel / max(riveObservedPeakLevel, 0.15), 0), 1)

        let alpha = leveled > smoothedRiveLevel ? 0.46 : 0.20
        smoothedRiveLevel += (leveled - smoothedRiveLevel) * alpha
        let level = smoothedRiveLevel < 0.02 ? 0 : smoothedRiveLevel

        let now = Date()
        let crossedThreshold = previousRiveLevel <= riveReactivePulseThreshold && level > riveReactivePulseThreshold
        let cooldownPassed = now.timeIntervalSince(lastRivePulseAt ?? .distantPast) >= riveReactivePulseCooldown
        let shouldPulse = crossedThreshold && cooldownPassed
        if shouldPulse {
            lastRivePulseAt = now
        }

        previousRiveLevel = level
        if riveAssetPathIfEnabled(forRecordingState: true) != nil {
            bubble.updateRiveReactiveInputs(listening: true, level: level, shouldPulse: shouldPulse)
        }
        if customSVGMarkupIfEnabled(forRecordingState: true) != nil {
            bubble.updateHTMLReactiveInputs(listening: true, transcribing: false, level: level, shouldPulse: shouldPulse)
        }
    }

    private func syncFloatingIndicatorPresentationForCurrentSession(previewIfIdle: Bool) {
        bubble.setPresentation(position: floatingIndicatorPosition, sizePercent: floatingIndicatorSizePercent)

        if isRecording {
            showBubble(message: "Listening...", isRecording: true)
            return
        }

        if isTranscribing {
            showBubble(message: "Transcribing...", isRecording: false, isTranscribing: true)
            return
        }

        if previewIfIdle, !isTranscribing, !isPreparingModel {
            showIndicatorPreview()
        }
    }

    private func configureKeepModelWarmLoop() {
        keepModelWarmTask?.cancel()
        keepModelWarmTask = nil
        lastKeepModelWarmAt = nil

        guard keepModelWarmEnabled else {
            keepModelWarmStatus = "Off"
            return
        }

        keepModelWarmStatus = "Armed"
        let intervalNanos = UInt64(keepModelWarmInterval * 1_000_000_000)

        keepModelWarmTask = Task(priority: .background) { [weak self] in
            guard let self else {
                return
            }

            while !Task.isCancelled {
                await self.runKeepModelWarmTick()
                guard !Task.isCancelled else {
                    return
                }
                try? await Task.sleep(nanoseconds: intervalNanos)
            }
        }
    }

    private func runKeepModelWarmTick() async {
        guard keepModelWarmEnabled else {
            keepModelWarmStatus = "Off"
            return
        }

        guard !isRecording, !isTranscribing, !isPreparingModel, !liveTranscriptionInFlight else {
            keepModelWarmStatus = "Paused while dictating"
            return
        }

        guard PowerStateService.shouldRunKeepWarm(onlyWhenPluggedIn: keepModelWarmOnlyOnPower) else {
            if PowerStateService.isLowPowerModeEnabled() {
                keepModelWarmStatus = "Paused (Low Power Mode)"
            } else {
                keepModelWarmStatus = "Paused on battery"
            }
            return
        }

        guard let configuration = parakeetConfiguration else {
            keepModelWarmStatus = "Waiting for model"
            return
        }

        do {
            try await transcription.keepWarm(configuration: configuration)
            keepModelWarmStatus = "Running"
            lastKeepModelWarmAt = .now
        } catch {
            keepModelWarmStatus = "Retrying after warmup error"
        }
    }

    private func showIndicatorPreview() {
        guard !isRecording, !isTranscribing, !isPreparingModel else {
            return
        }

        indicatorPreviewHideTask?.cancel()
        bubble.show(
            message: "Indicator Preview",
            isRecording: true,
            isTranscribing: false,
            riveAssetPath: preferredRiveAssetPath(),
            htmlIndicatorMarkup: preferredCustomSVGMarkup()
        )

        if !isAdjustingIndicatorSize {
            scheduleIndicatorPreviewHide(delay: 0.9)
        }
    }

    private func scheduleIndicatorPreviewHide(delay: TimeInterval) {
        indicatorPreviewHideTask?.cancel()
        indicatorPreviewHideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                guard let self, !self.isRecording else {
                    return
                }
                self.bubble.hide()
            }
        }
    }

    private func shouldRunReactiveIndicatorLoopDuringRecording() -> Bool {
        let hasRiveReactive = riveAssetPathIfEnabled(forRecordingState: true) != nil
        let hasCustomReactive = customSVGMarkupIfEnabled(forRecordingState: true) != nil
        return hasRiveReactive || hasCustomReactive
    }

    private func preferredRiveAssetPath() -> String? {
        guard riveIndicatorEnabled else {
            return nil
        }

        let trimmed = listeningRiveAssetPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func preferredCustomSVGMarkup() -> String? {
        guard customSVGIndicatorEnabled else {
            return nil
        }

        let trimmed = customSVGIndicatorMarkup.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func riveAssetPathIfEnabled(forRecordingState isRecording: Bool) -> String? {
        guard riveIndicatorEnabled, isRecording else {
            return nil
        }

        return preferredRiveAssetPath()
    }

    private func customSVGMarkupIfEnabled(forRecordingState isRecording: Bool) -> String? {
        guard customSVGIndicatorEnabled, isRecording else {
            return nil
        }

        return preferredCustomSVGMarkup()
    }

    private static func defaultListeningRiveAssetPath() -> String {
        let downloadsCandidate = ("~/Downloads/5628-11215-wave-hear-and-talk.riv" as NSString).expandingTildeInPath
        return FileManager.default.fileExists(atPath: downloadsCandidate) ? downloadsCandidate : ""
    }

    private func showBubble(message: String, isRecording: Bool, isTranscribing: Bool = false) {
        indicatorPreviewHideTask?.cancel()
        indicatorPreviewHideTask = nil
        bubbleHideTask?.cancel()
        bubble.show(
            message: message,
            isRecording: isRecording,
            isTranscribing: isTranscribing,
            riveAssetPath: riveAssetPathIfEnabled(forRecordingState: isRecording),
            htmlIndicatorMarkup: (isRecording || isTranscribing) ? preferredCustomSVGMarkup() : nil
        )
    }

    private func showTransientBubble(message: String, duration: TimeInterval = 0.95) {
        bubbleHideTask?.cancel()
        bubble.show(message: message, isRecording: false, isTranscribing: false, riveAssetPath: nil, htmlIndicatorMarkup: nil)

        bubbleHideTask = Task { [weak self] in
            let nanos = UInt64(duration * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                self?.bubble.hide()
            }
        }
    }

    private func requestAccessibilityPermission(prompt: Bool) -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func requestKeyboardMonitoringPermission(prompt: Bool) -> Bool {
        if prompt {
            _ = CGRequestListenEventAccess()
        }
        return CGPreflightListenEventAccess()
    }

    private func openSettingsURL(_ rawURL: String) {
        guard let url = URL(string: rawURL) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func installInvocationKeyCaptureMonitors() {
        removeInvocationKeyCaptureMonitors()

        localKeyCaptureMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handleInvocationCaptureEvent(event)
            return event
        }

        globalKeyCaptureMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleInvocationCaptureEvent(event)
            }
        }
    }

    private func removeInvocationKeyCaptureMonitors() {
        if let localKeyCaptureMonitor {
            NSEvent.removeMonitor(localKeyCaptureMonitor)
        }

        if let globalKeyCaptureMonitor {
            NSEvent.removeMonitor(globalKeyCaptureMonitor)
        }

        localKeyCaptureMonitor = nil
        globalKeyCaptureMonitor = nil
    }

    private func handleInvocationCaptureEvent(_ event: NSEvent) {
        guard isCapturingInvocationKey else {
            return
        }

        if event.type == .keyDown, event.isARepeat {
            return
        }

        let capturedKeyCode = Int64(event.keyCode)
        setInvocationKeyCode(capturedKeyCode)

        isCapturingInvocationKey = false
        removeInvocationKeyCaptureMonitors()
        statusText = "Invocation key set to \(invocationKeyDisplayName)."
    }

    private func setInvocationKeyCode(_ keyCode: Int64) {
        invocationKeyCode = keyCode
        UserDefaults.standard.set(Int(keyCode), forKey: DefaultsKey.invocationKeyCode)
        shortcutMonitor.setInvocationKeyCode(keyCode)
    }

    private func startLiveTranscriptionLoop(configuration: ParakeetConfiguration) {
        stopLiveTranscriptionLoop()

        liveTranscriptionLoopTask = Task { [weak self] in
            guard let self else {
                return
            }

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(liveSnapshotInterval * 1_000_000_000))
                guard !Task.isCancelled else {
                    return
                }
                await enqueueLiveTranscriptionIfNeeded(configuration: configuration)
            }
        }
    }

    private func stopLiveTranscriptionLoop() {
        liveTranscriptionLoopTask?.cancel()
        liveTranscriptionLoopTask = nil
    }

    private func enqueueLiveTranscriptionIfNeeded(configuration: ParakeetConfiguration) async {
        guard isRecording, !isTranscribing, !liveTranscriptionInFlight else {
            return
        }

        let currentDuration = audioCapture.currentRecordingDuration
        guard currentDuration >= liveSnapshotMinDuration else {
            return
        }

        // Keep live previews cheap; long full-recording snapshots can block final transcription.
        guard currentDuration <= liveSnapshotMaxDuration else {
            return
        }

        let snapshot: AudioCaptureService.RecordingSnapshot
        do {
            snapshot = try audioCapture.makeRecordingSnapshot()
        } catch {
            return
        }

        liveTranscriptionInFlight = true
        liveSnapshotInFlightDuration = snapshot.duration
        let transcriptionService = transcription

        Task(priority: .utility) { [weak self] in
            defer {
                try? FileManager.default.removeItem(at: snapshot.url)
            }

            do {
                let result = try await transcriptionService.transcribe(audioFileURL: snapshot.url, configuration: configuration)
                await MainActor.run {
                    guard let self else {
                        return
                    }

                    self.liveTranscriptionInFlight = false
                    self.liveSnapshotInFlightDuration = nil

                    let cleaned = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cleaned.isEmpty else {
                        return
                    }

                    self.latestLiveTranscription = LiveTranscriptionResult(
                        text: cleaned,
                        backend: result.backend,
                        snapshotDuration: snapshot.duration,
                        completedAt: .now
                    )

                    if self.isRecording {
                        self.lastTranscript = cleaned
                        self.lastTranscriptionBackend = "\(result.backend) (live)"
                        self.statusText = "Listening... (live)"
                    }
                }
            } catch {
                await MainActor.run {
                    self?.liveTranscriptionInFlight = false
                    self?.liveSnapshotInFlightDuration = nil
                }
            }
        }
    }

    private func reusableLiveTranscription(finalDuration: TimeInterval) -> LiveTranscriptionResult? {
        guard let latestLiveTranscription else {
            return nil
        }

        let missingTail = finalDuration - latestLiveTranscription.snapshotDuration
        let age = Date().timeIntervalSince(latestLiveTranscription.completedAt)
        let coverageRatio = finalDuration > 0 ? latestLiveTranscription.snapshotDuration / finalDuration : 1

        guard missingTail >= 0,
              missingTail <= liveReuseMaxAudioGap,
              age <= liveReuseMaxAge,
              coverageRatio >= liveReuseMinCoverageRatio
        else {
            return nil
        }

        return latestLiveTranscription
    }

    private func shouldImmediatelyReuseLiveTranscription(_ live: LiveTranscriptionResult, finalDuration: TimeInterval) -> Bool {
        // If another live request is still running, only reuse now when tail gap is tiny.
        if !liveTranscriptionInFlight {
            return true
        }

        let missingTail = finalDuration - live.snapshotDuration
        return missingTail >= 0 && missingTail <= liveImmediateReuseMaxGap
    }

    private func waitForReusableLiveTranscription(finalDuration: TimeInterval, timeout: TimeInterval) async -> LiveTranscriptionResult? {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let live = reusableLiveTranscription(finalDuration: finalDuration) {
                return live
            }

            guard liveTranscriptionInFlight else {
                break
            }

            try? await Task.sleep(nanoseconds: 80_000_000)
        }

        return reusableLiveTranscription(finalDuration: finalDuration)
    }

    private func shouldWaitForReusableLiveTranscription(finalDuration: TimeInterval) -> Bool {
        guard liveTranscriptionInFlight,
              let snapshotDuration = liveSnapshotInFlightDuration
        else {
            return false
        }

        let missingTail = finalDuration - snapshotDuration
        return missingTail >= 0 && missingTail <= liveReuseMaxAudioGap
    }

    private func logPipelineTiming(_ message: String) {
        guard pipelineTimingEnabled else {
            return
        }
        NSLog("[PipelineTiming] \(message)")
    }

    @discardableResult
    private func startShortcutMonitor() -> Bool {
        let startResult = shortcutMonitor.start()
        let started = startResult == .started

        guard !isRecording, !isTranscribing, !isPreparingModel else {
            return started
        }

        if started {
            statusText = "Ready. Press \(invocationKeyDisplayName) globally (\(mode.title))."
            return true
        }

        switch startResult {
        case .missingKeyboardPermission:
            statusText = "Global shortcut disabled. Grant Input Monitoring and relaunch."
        case .eventTapUnavailable:
            statusText = "Global shortcut monitor unavailable. Checking local speech model..."
        case .started:
            break
        }

        return false
    }
}
