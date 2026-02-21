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
    @Published private(set) var voiceNoteSwitchKeyCode: Int64
    @Published var isCapturingInvocationKey = false
    @Published var isCapturingVoiceNoteSwitchKey = false
    @Published var statusText: String
    @Published var lastTranscript: String
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var isPreparingModel = false
    @Published var accessibilityGranted = AXIsProcessTrusted()
    @Published var keyboardMonitoringGranted = CGPreflightListenEventAccess()
    @Published var microphoneGranted = false
    @Published private(set) var hasCompletedOnboarding: Bool
    @Published var shouldShowOnboardingWizard: Bool
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
    @Published var builtInWaveIndicatorEnabled: Bool {
        didSet {
            UserDefaults.standard.set(builtInWaveIndicatorEnabled, forKey: DefaultsKey.builtInWaveIndicatorEnabled)
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
    @Published var appMode: AppMode = .dictation
    @Published private(set) var recordingOutputMode: RecordingOutputMode = .paste

    private var initialized = false
    private var interpreter: ShortcutInterpreter
    private let shortcutMonitor = GlobalFnShortcutMonitor()
    private let audioCapture = AudioCaptureService()
    private let transcription = ParakeetTranscriptionService()
    private let pasteService = PasteService()
    private let noteService = NoteService()
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
    private var keyCaptureTarget: KeyCaptureTarget?

    private let liveSnapshotMinDuration: TimeInterval = 0.75
    private let liveSnapshotInterval: TimeInterval = 0.80
    private let liveStreamingWindowDuration: TimeInterval = 1.65
    private let riveReactivePollInterval: TimeInterval = 0.05
    private let riveReactivePulseThreshold: Double = 0.14
    private let riveReactivePulseCooldown: TimeInterval = 0.40
    private let keepModelWarmInterval: TimeInterval = 45
    private let liveReuseMaxAudioGap: TimeInterval = 0.30
    private let liveReuseMaxAge: TimeInterval = 1.30
    private let liveReuseWaitTimeout: TimeInterval = 0.24
    private let liveImmediateReuseMaxGap: TimeInterval = 0.16
    private let liveReuseMinCoverageRatio: Double = 0.82
    private let liveTailPatchMaxAudioGap: TimeInterval = 1.10
    private let liveTailPatchMaxAge: TimeInterval = 1.90
    private let liveTailPatchMinCoverageRatio: Double = 0.55
    private let liveTailPatchWaitTimeout: TimeInterval = 0.42
    private let liveTailPatchOverlap: TimeInterval = 0.22
    private let holdReleaseWatchPollInterval: TimeInterval = 0.05
    private let holdReleaseDebounce: TimeInterval = 0.12
    private let pipelineTimingEnabled = ProcessInfo.processInfo.environment["KINSHASA_TIMING"] == "1"

    private enum DefaultsKey {
        static let mode = "shortcut_mode"
        static let invocationKeyCode = "shortcut_invocation_key_code"
        static let voiceNoteSwitchKeyCode = "voice_note_switch_key_code"
        static let onboardingCompleted = "onboarding_completed"
        static let duckingEnabled = "ducking_enabled"
        static let duckingAmountPercent = "ducking_amount_percent"
        static let keepModelWarmEnabled = "keep_model_warm_enabled"
        static let keepModelWarmOnlyOnPower = "keep_model_warm_only_on_power"
        static let riveIndicatorEnabled = "rive_indicator_enabled"
        static let listeningRiveAssetPath = "listening_rive_asset_path"
        static let customSVGIndicatorEnabled = "custom_svg_indicator_enabled"
        static let customSVGIndicatorMarkup = "custom_svg_indicator_markup"
        static let builtInWaveIndicatorEnabled = "built_in_wave_indicator_enabled"
        static let floatingIndicatorPosition = "floating_indicator_position"
        static let floatingIndicatorSizePercent = "floating_indicator_size_percent"
    }

    private enum KeyCaptureTarget {
        case invocation
        case voiceNoteSwitch
    }

    nonisolated static func inferOnboardingCompletion(
        defaults: UserDefaults,
        accessibilityGranted: Bool,
        keyboardMonitoringGranted: Bool,
        microphoneGranted: Bool
    ) -> Bool {
        if let stored = defaults.object(forKey: DefaultsKey.onboardingCompleted) as? Bool {
            return stored
        }

        let hasLegacyConfig = defaults.object(forKey: DefaultsKey.mode) != nil
            || defaults.object(forKey: DefaultsKey.invocationKeyCode) != nil
            || defaults.object(forKey: DefaultsKey.voiceNoteSwitchKeyCode) != nil
        let hasAllRequiredPermissions = accessibilityGranted && keyboardMonitoringGranted && microphoneGranted
        return hasLegacyConfig || hasAllRequiredPermissions
    }

    init() {
        let defaults = UserDefaults.standard
        let initialAccessibilityGranted = AXIsProcessTrusted()
        let initialKeyboardMonitoringGranted = CGPreflightListenEventAccess()
        let initialMicrophoneGranted = audioCapture.microphonePermissionGranted

        let initialMode = ShortcutMode(rawValue: defaults.string(forKey: DefaultsKey.mode) ?? "") ?? .toggle
        let initialInvocationKeyCode: Int64
        if let stored = defaults.object(forKey: DefaultsKey.invocationKeyCode) as? Int {
            initialInvocationKeyCode = Int64(stored)
        } else {
            initialInvocationKeyCode = InvocationKey.defaultKeyCode
        }
        let initialVoiceNoteSwitchKeyCode: Int64
        if let stored = defaults.object(forKey: DefaultsKey.voiceNoteSwitchKeyCode) as? Int {
            initialVoiceNoteSwitchKeyCode = Int64(stored)
        } else {
            initialVoiceNoteSwitchKeyCode = 0 // A
        }

        mode = initialMode
        invocationKeyCode = initialInvocationKeyCode
        voiceNoteSwitchKeyCode = initialVoiceNoteSwitchKeyCode
        duckingEnabled = defaults.object(forKey: DefaultsKey.duckingEnabled) as? Bool ?? false
        let storedDuckingAmount = defaults.object(forKey: DefaultsKey.duckingAmountPercent) as? Double ?? 40
        duckingAmountPercent = min(max(storedDuckingAmount, 0), 90)
        keepModelWarmEnabled = defaults.object(forKey: DefaultsKey.keepModelWarmEnabled) as? Bool ?? false
        keepModelWarmOnlyOnPower = defaults.object(forKey: DefaultsKey.keepModelWarmOnlyOnPower) as? Bool ?? true
        let defaultRiveAssetPath = Self.defaultListeningRiveAssetPath()
        listeningRiveAssetPath = defaults.string(forKey: DefaultsKey.listeningRiveAssetPath) ?? defaultRiveAssetPath
        riveIndicatorEnabled = defaults.object(forKey: DefaultsKey.riveIndicatorEnabled) as? Bool ?? !defaultRiveAssetPath.isEmpty
        customSVGIndicatorMarkup = defaults.string(forKey: DefaultsKey.customSVGIndicatorMarkup) ?? ""
        customSVGIndicatorEnabled = defaults.object(forKey: DefaultsKey.customSVGIndicatorEnabled) as? Bool ?? false
        builtInWaveIndicatorEnabled = defaults.object(forKey: DefaultsKey.builtInWaveIndicatorEnabled) as? Bool ?? false
        let rawPosition = defaults.string(forKey: DefaultsKey.floatingIndicatorPosition) ?? FloatingIndicatorPosition.centerTop.rawValue
        floatingIndicatorPosition = FloatingIndicatorPosition(rawValue: rawPosition) ?? .centerTop
        let storedIndicatorSize = defaults.object(forKey: DefaultsKey.floatingIndicatorSizePercent) as? Double ?? 35
        floatingIndicatorSizePercent = min(max(storedIndicatorSize, 18), 140)
        let inferredOnboardingCompleted = Self.inferOnboardingCompletion(
            defaults: defaults,
            accessibilityGranted: initialAccessibilityGranted,
            keyboardMonitoringGranted: initialKeyboardMonitoringGranted,
            microphoneGranted: initialMicrophoneGranted
        )
        hasCompletedOnboarding = inferredOnboardingCompleted
        shouldShowOnboardingWizard = !inferredOnboardingCompleted
        keepModelWarmStatus = "Off"
        interpreter = ShortcutInterpreter(mode: initialMode)
        statusText = "Preparing CoreML speech model..."
        lastTranscript = ""

        parakeetModel = ProcessInfo.processInfo.environment["KINSHASA_COREML_MODEL"]
            ?? ProcessInfo.processInfo.environment["PARAKEET_MODEL"]
            ?? "FluidInference/parakeet-tdt-0.6b-v2-coreml"

        accessibilityGranted = initialAccessibilityGranted
        keyboardMonitoringGranted = initialKeyboardMonitoringGranted
        microphoneGranted = initialMicrophoneGranted
        shortcutMonitor.setInvocationKeyCode(initialInvocationKeyCode)
        shortcutMonitor.setVoiceNoteSwitchKeyCode(initialVoiceNoteSwitchKeyCode)

        if defaults.object(forKey: DefaultsKey.onboardingCompleted) == nil, inferredOnboardingCompleted {
            defaults.set(true, forKey: DefaultsKey.onboardingCompleted)
        }

        shortcutMonitor.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleShortcutEvent(event)
            }
        }
        shortcutMonitor.onVoiceNoteSwitchKeyPressed = { [weak self] in
            Task { @MainActor [weak self] in
                self?.switchRecordingOutputToVoiceNote()
            }
        }

        bubble.setPresentation(position: floatingIndicatorPosition, sizePercent: floatingIndicatorSizePercent)
    }

    func initialize() async {
        guard !initialized else {
            return
        }

        initialized = true
        let shortcutStarted = await refreshPermissions(prompt: false)
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
        markOnboardingCompleteIfReady()
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

    var allRequiredPermissionsGranted: Bool {
        accessibilityGranted && keyboardMonitoringGranted && microphoneGranted
    }

    var voiceNoteSwitchKeyDisplayName: String {
        InvocationKey.displayName(for: voiceNoteSwitchKeyCode)
    }

    func showOnboardingWizard() {
        shouldShowOnboardingWizard = true
    }

    func dismissOnboardingWizard() {
        shouldShowOnboardingWizard = false
    }

    func completeOnboardingWizard() {
        hasCompletedOnboarding = true
        shouldShowOnboardingWizard = false
        UserDefaults.standard.set(true, forKey: DefaultsKey.onboardingCompleted)
    }

    var notesDirectoryPathText: String {
        noteService.notesDirectoryPath()
    }

    var recordingOutputModeText: String {
        recordingOutputMode.title
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
        guard !isCapturingInvocationKey, !isCapturingVoiceNoteSwitchKey else {
            return
        }

        keyCaptureTarget = .invocation
        isCapturingInvocationKey = true
        isCapturingVoiceNoteSwitchKey = false
        statusText = "Press the key to use globally (left/right modifiers supported)."
        installInvocationKeyCaptureMonitors()
    }

    func cancelInvocationKeyCapture() {
        guard isCapturingInvocationKey else {
            return
        }

        isCapturingInvocationKey = false
        keyCaptureTarget = nil
        removeInvocationKeyCaptureMonitors()
        statusText = "Invocation key capture canceled."
    }

    func startVoiceNoteSwitchKeyCapture() {
        guard !isCapturingInvocationKey, !isCapturingVoiceNoteSwitchKey else {
            return
        }

        keyCaptureTarget = .voiceNoteSwitch
        isCapturingInvocationKey = false
        isCapturingVoiceNoteSwitchKey = true
        statusText = "Press the key to switch to Voice Note mode while recording."
        installInvocationKeyCaptureMonitors()
    }

    func cancelVoiceNoteSwitchKeyCapture() {
        guard isCapturingVoiceNoteSwitchKey else {
            return
        }

        isCapturingVoiceNoteSwitchKey = false
        keyCaptureTarget = nil
        removeInvocationKeyCaptureMonitors()
        statusText = "Voice Note key capture canceled."
    }

    func requestKeyboardPrompt() {
        keyboardMonitoringGranted = requestKeyboardMonitoringPermission(prompt: true)
        _ = startShortcutMonitor()
    }

    func requestVoicePermissionsPrompt() {
        Task {
            accessibilityGranted = requestAccessibilityPermission(prompt: true)
            keyboardMonitoringGranted = requestKeyboardMonitoringPermission(prompt: true)
            microphoneGranted = await audioCapture.requestMicrophonePermissionIfNeeded(prompt: true)
            markOnboardingCompleteIfReady()
            _ = startShortcutMonitor()
            if !isRecording, !isTranscribing, !isPreparingModel {
                statusText = "Voice permissions updated."
            }
        }
    }

    func recheckVoicePermissions() {
        Task {
            accessibilityGranted = requestAccessibilityPermission(prompt: false)
            keyboardMonitoringGranted = requestKeyboardMonitoringPermission(prompt: false)
            microphoneGranted = await audioCapture.requestMicrophonePermissionIfNeeded(prompt: false)
            markOnboardingCompleteIfReady()
            _ = startShortcutMonitor()
        }
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
        shortcutMonitor.setVoiceNoteSwitchArmed(false)
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
        guard !isCapturingInvocationKey, !isCapturingVoiceNoteSwitchKey else {
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

    private func switchRecordingOutputToVoiceNote() {
        guard isRecording, !isTranscribing else {
            return
        }

        guard recordingOutputMode != .voiceNote else {
            return
        }

        recordingOutputMode = .voiceNote
        statusText = listeningStatusText(isLive: false)
        showBubble(message: listeningBubbleMessage(), isRecording: true)
    }

    private func listeningBubbleMessage() -> String {
        switch recordingOutputMode {
        case .paste:
            return "Listening..."
        case .voiceNote:
            return "Listening (Note Mode)..."
        }
    }

    private func listeningStatusText(isLive: Bool) -> String {
        switch (recordingOutputMode, isLive) {
        case (.paste, false):
            return "Listening..."
        case (.paste, true):
            return "Listening... (live)"
        case (.voiceNote, false):
            return "Listening... (note mode)"
        case (.voiceNote, true):
            return "Listening... (live, note mode)"
        }
    }

    private func beginRecording() async {
        guard appMode == .dictation else {
            return
        }

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
            recordingOutputMode = .paste
            shortcutMonitor.setVoiceNoteSwitchArmed(true)
            latestLiveTranscription = nil
            liveTranscriptionInFlight = false
            liveSnapshotInFlightDuration = nil
            startHoldReleaseWatchdogIfNeeded()
            statusText = listeningStatusText(isLive: false)
            showBubble(message: listeningBubbleMessage(), isRecording: true)
            startRiveReactiveLoopIfNeeded()
            applyDuckingIfNeeded()
            startLiveTranscriptionLoop(configuration: configuration)
        } catch {
            shortcutMonitor.setVoiceNoteSwitchArmed(false)
            recordingOutputMode = .paste
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
            shortcutMonitor.setVoiceNoteSwitchArmed(false)
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

                    let shouldWaitForTailPatch = shouldWaitForTailPatchLiveTranscription(finalDuration: finalDuration)
                    let tailPatchLive: LiveTranscriptionResult?
                    if let immediateTailPatch = tailPatchLiveTranscription(finalDuration: finalDuration) {
                        tailPatchLive = immediateTailPatch
                    } else if shouldWaitForTailPatch {
                        tailPatchLive = await waitForTailPatchLiveTranscription(
                            finalDuration: finalDuration,
                            timeout: liveTailPatchWaitTimeout
                        )
                    } else {
                        tailPatchLive = nil
                    }

                    if let tailPatchLive {
                        let tailStartSeconds = max(0, tailPatchLive.snapshotDuration - liveTailPatchOverlap)
                        do {
                            let tailResult = try await transcription.transcribe(
                                audioFileURL: recordedFile,
                                configuration: configuration,
                                startSeconds: tailStartSeconds,
                                backendLabel: "CoreML Streaming (tail patch)"
                            )
                            let stitchedText = mergeLiveAndTail(base: tailPatchLive.text, tail: tailResult.text)
                            let totalLatency = Date().timeIntervalSince(startedAt)
                            let waitLatency = Date().timeIntervalSince(waitStartedAt)
                            await MainActor.run {
                                logPipelineTiming(
                                    String(
                                        format: "stop->tail-patch total=%.3fs wait=%.3fs tail=%.3fs start=%.3fs backend=%@",
                                        totalLatency,
                                        waitLatency,
                                        max(0, finalDuration - tailPatchLive.snapshotDuration),
                                        tailStartSeconds,
                                        tailResult.backend
                                    )
                                )
                                lastTranscriptionLatency = totalLatency
                                lastTranscriptionBackend = "\(tailResult.backend) + live reuse"
                                handleTranscriptionResult(stitchedText)
                            }
                            return
                        } catch {
                            await MainActor.run {
                                logPipelineTiming("stop->tail-patch failed fallback=full error=\(error.localizedDescription)")
                            }
                        }
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
            shortcutMonitor.setVoiceNoteSwitchArmed(false)
            recordingOutputMode = .paste
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
        statusText = "Preparing local CoreML speech model (first run may take a minute)..."

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
            handleError("Could not prepare local CoreML speech model. \(error.localizedDescription)")
            return false
        }
    }

    private func handleTranscriptionResult(_ text: String) {
        isTranscribing = false

        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            recordingOutputMode = .paste
            statusText = "No speech detected."
            showTransientBubble(message: "No speech detected")
            return
        }

        lastTranscript = cleaned

        switch recordingOutputMode {
        case .paste:
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
                bubble.hide()
            } else {
                statusText = "Transcribed and copied. Grant Accessibility for auto-paste."
                showTransientBubble(message: "Copied")
            }
        case .voiceNote:
            do {
                let fileURL = try noteService.appendVoiceNote(cleaned)
                statusText = "Saved to Voice Note (\(fileURL.lastPathComponent))."
                showTransientBubble(message: "Saved to note")
            } catch {
                handleError("Could not save voice note. \(error.localizedDescription)")
            }
        }

        recordingOutputMode = .paste
    }

    private func handleError(_ message: String) {
        if !isRecording {
            stopHoldReleaseWatchdog()
            stopRiveReactiveLoop(resetInputs: true)
            shortcutMonitor.setVoiceNoteSwitchArmed(false)
            recordingOutputMode = .paste
            duckingService.restoreIfNeeded()
        }
        statusText = message
        showTransientBubble(message: "Error", duration: 1.6)
    }

    private func markOnboardingCompleteIfReady() {
        guard !hasCompletedOnboarding, allRequiredPermissionsGranted else {
            return
        }

        hasCompletedOnboarding = true
        UserDefaults.standard.set(true, forKey: DefaultsKey.onboardingCompleted)
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

        showBubble(message: listeningBubbleMessage(), isRecording: true)
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
        bubble.updateWaveReactiveInputs(listening: true, transcribing: false, level: 0, shouldPulse: false)

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
            bubble.updateWaveReactiveInputs(listening: false, transcribing: false, level: 0, shouldPulse: false)
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
        bubble.updateWaveReactiveInputs(listening: true, transcribing: false, level: level, shouldPulse: shouldPulse)
    }

    private func syncFloatingIndicatorPresentationForCurrentSession(previewIfIdle: Bool) {
        bubble.setPresentation(position: floatingIndicatorPosition, sizePercent: floatingIndicatorSizePercent)

        if isRecording {
            showBubble(message: listeningBubbleMessage(), isRecording: true)
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
            htmlIndicatorMarkup: preferredCustomSVGMarkup(),
            useBuiltInWaveIndicator: builtInWaveIndicatorEnabled
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
        true
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
            htmlIndicatorMarkup: (isRecording || isTranscribing) ? preferredCustomSVGMarkup() : nil,
            useBuiltInWaveIndicator: builtInWaveIndicatorEnabled
        )
    }

    private func showTransientBubble(message: String, duration: TimeInterval = 0.95) {
        bubbleHideTask?.cancel()
        bubble.show(
            message: message,
            isRecording: false,
            isTranscribing: false,
            riveAssetPath: nil,
            htmlIndicatorMarkup: nil,
            useBuiltInWaveIndicator: false
        )

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
        if NSWorkspace.shared.open(url) {
            return
        }

        if let settingsURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") {
            NSWorkspace.shared.open(settingsURL)
        }
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
        guard let keyCaptureTarget else {
            return
        }

        if event.type == .keyDown, event.isARepeat {
            return
        }

        let capturedKeyCode = Int64(event.keyCode)
        switch keyCaptureTarget {
        case .invocation:
            setInvocationKeyCode(capturedKeyCode)
            statusText = "Invocation key set to \(invocationKeyDisplayName)."
        case .voiceNoteSwitch:
            guard capturedKeyCode != invocationKeyCode else {
                statusText = "Voice Note key must be different from invocation key."
                return
            }
            setVoiceNoteSwitchKeyCode(capturedKeyCode)
            statusText = "Voice Note key set to \(voiceNoteSwitchKeyDisplayName)."
        }

        isCapturingInvocationKey = false
        isCapturingVoiceNoteSwitchKey = false
        self.keyCaptureTarget = nil
        removeInvocationKeyCaptureMonitors()
    }

    private func setInvocationKeyCode(_ keyCode: Int64) {
        invocationKeyCode = keyCode
        UserDefaults.standard.set(Int(keyCode), forKey: DefaultsKey.invocationKeyCode)
        shortcutMonitor.setInvocationKeyCode(keyCode)
    }

    private func setVoiceNoteSwitchKeyCode(_ keyCode: Int64) {
        voiceNoteSwitchKeyCode = keyCode
        UserDefaults.standard.set(Int(keyCode), forKey: DefaultsKey.voiceNoteSwitchKeyCode)
        shortcutMonitor.setVoiceNoteSwitchKeyCode(keyCode)
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

        let snapshot: AudioCaptureService.RecordingSnapshot
        do {
            snapshot = try audioCapture.makeRecordingSnapshot()
        } catch {
            return
        }

        let liveChunkStartSeconds = max(0, snapshot.duration - liveStreamingWindowDuration)
        liveTranscriptionInFlight = true
        liveSnapshotInFlightDuration = snapshot.duration
        let transcriptionService = transcription

        Task(priority: .utility) { [weak self] in
            defer {
                try? FileManager.default.removeItem(at: snapshot.url)
            }

            do {
                let result = try await transcriptionService.transcribe(
                    audioFileURL: snapshot.url,
                    configuration: configuration,
                    startSeconds: liveChunkStartSeconds,
                    backendLabel: "CoreML Streaming (live chunk)"
                )
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

                    let mergedText: String
                    if liveChunkStartSeconds > 0,
                       let previous = self.latestLiveTranscription,
                       previous.snapshotDuration < snapshot.duration
                    {
                        mergedText = self.mergeLiveAndTail(base: previous.text, tail: cleaned)
                    } else {
                        mergedText = cleaned
                    }

                    self.latestLiveTranscription = LiveTranscriptionResult(
                        text: mergedText,
                        backend: result.backend,
                        snapshotDuration: snapshot.duration,
                        completedAt: .now
                    )

                    if self.isRecording {
                        self.lastTranscript = mergedText
                        self.lastTranscriptionBackend = "\(result.backend) (live)"
                        self.statusText = self.listeningStatusText(isLive: true)
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

    private func tailPatchLiveTranscription(finalDuration: TimeInterval) -> LiveTranscriptionResult? {
        guard let latestLiveTranscription else {
            return nil
        }

        let missingTail = finalDuration - latestLiveTranscription.snapshotDuration
        let age = Date().timeIntervalSince(latestLiveTranscription.completedAt)
        let coverageRatio = finalDuration > 0 ? latestLiveTranscription.snapshotDuration / finalDuration : 1

        guard missingTail > liveReuseMaxAudioGap,
              missingTail <= liveTailPatchMaxAudioGap,
              age <= liveTailPatchMaxAge,
              coverageRatio >= liveTailPatchMinCoverageRatio
        else {
            return nil
        }

        return latestLiveTranscription
    }

    private func shouldWaitForTailPatchLiveTranscription(finalDuration: TimeInterval) -> Bool {
        guard liveTranscriptionInFlight,
              let snapshotDuration = liveSnapshotInFlightDuration
        else {
            return false
        }

        let missingTail = finalDuration - snapshotDuration
        return missingTail > liveReuseMaxAudioGap && missingTail <= liveTailPatchMaxAudioGap
    }

    private func waitForTailPatchLiveTranscription(finalDuration: TimeInterval, timeout: TimeInterval) async -> LiveTranscriptionResult? {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let live = tailPatchLiveTranscription(finalDuration: finalDuration) {
                return live
            }

            guard liveTranscriptionInFlight else {
                break
            }

            try? await Task.sleep(nanoseconds: 80_000_000)
        }

        return tailPatchLiveTranscription(finalDuration: finalDuration)
    }

    private func mergeLiveAndTail(base: String, tail: String) -> String {
        let left = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = tail.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !left.isEmpty else {
            return right
        }
        guard !right.isEmpty else {
            return left
        }

        let leftTokens = left.split(whereSeparator: \.isWhitespace).map(String.init)
        let rightTokens = right.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !leftTokens.isEmpty, !rightTokens.isEmpty else {
            return "\(left) \(right)"
        }

        let overlap = overlapTokenCount(baseTokens: leftTokens, tailTokens: rightTokens)
        if overlap == 0 {
            return "\(left) \(right)"
        }

        let mergedTail = rightTokens.dropFirst(overlap).joined(separator: " ")
        return mergedTail.isEmpty ? left : "\(left) \(mergedTail)"
    }

    private func overlapTokenCount(baseTokens: [String], tailTokens: [String]) -> Int {
        let maxOverlap = min(10, baseTokens.count, tailTokens.count)
        guard maxOverlap > 0 else {
            return 0
        }

        for size in stride(from: maxOverlap, through: 1, by: -1) {
            var matched = true
            for index in 0..<size {
                let lhsIndex = baseTokens.count - size + index
                if normalizedMergeToken(baseTokens[lhsIndex]) != normalizedMergeToken(tailTokens[index]) {
                    matched = false
                    break
                }
            }

            if matched {
                return size
            }
        }

        return 0
    }

    private func normalizedMergeToken(_ token: String) -> String {
        let normalized = token
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
            .lowercased()
        return normalized.isEmpty ? token.lowercased() : normalized
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
