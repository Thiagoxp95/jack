import ApplicationServices
import AppKit
import Foundation

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
    private var keepModelWarmTask: Task<Void, Never>?
    private var liveTranscriptionInFlight = false
    private var liveSnapshotInFlightDuration: TimeInterval?
    private var latestLiveTranscription: LiveTranscriptionResult?
    private var lastKeepModelWarmAt: Date?
    private var localKeyCaptureMonitor: Any?
    private var globalKeyCaptureMonitor: Any?

    private let liveSnapshotMinDuration: TimeInterval = 0.85
    private let liveSnapshotInterval: TimeInterval = 0.90
    private let keepModelWarmInterval: TimeInterval = 45
    private let liveReuseMaxAudioGap: TimeInterval = 0.28
    private let liveReuseMaxAge: TimeInterval = 1.30
    private let liveReuseWaitTimeout: TimeInterval = 0.24
    private let pipelineTimingEnabled = ProcessInfo.processInfo.environment["KINSHASA_TIMING"] == "1"

    private enum DefaultsKey {
        static let mode = "shortcut_mode"
        static let invocationKeyCode = "shortcut_invocation_key_code"
        static let duckingEnabled = "ducking_enabled"
        static let duckingAmountPercent = "ducking_amount_percent"
        static let keepModelWarmEnabled = "keep_model_warm_enabled"
        static let keepModelWarmOnlyOnPower = "keep_model_warm_only_on_power"
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
        keepModelWarmEnabled = defaults.object(forKey: DefaultsKey.keepModelWarmEnabled) as? Bool ?? false
        keepModelWarmOnlyOnPower = defaults.object(forKey: DefaultsKey.keepModelWarmOnlyOnPower) as? Bool ?? true
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
        keepModelWarmTask?.cancel()
        keepModelWarmTask = nil
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
            statusText = "Listening..."
            showBubble(message: "Listening...", isRecording: true)
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
            duckingService.restoreIfNeeded()
            statusText = "Transcribing..."
            showBubble(message: "Transcribing...", isRecording: false)

            Task(priority: .userInitiated) {
                let startedAt = Date()
                defer {
                    try? FileManager.default.removeItem(at: recordedFile)
                }

                do {
                    let waitStartedAt = Date()
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

    private func showBubble(message: String, isRecording: Bool) {
        bubbleHideTask?.cancel()
        bubble.show(message: message, isRecording: isRecording)
    }

    private func showTransientBubble(message: String, duration: TimeInterval = 0.95) {
        bubbleHideTask?.cancel()
        bubble.show(message: message, isRecording: false)

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

        guard audioCapture.currentRecordingDuration >= liveSnapshotMinDuration else {
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

        Task(priority: .userInitiated) { [weak self] in
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

        guard missingTail >= 0,
              missingTail <= liveReuseMaxAudioGap,
              age <= liveReuseMaxAge
        else {
            return nil
        }

        return latestLiveTranscription
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
