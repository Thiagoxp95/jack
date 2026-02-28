import ApplicationServices
import AppKit
import Foundation
import os.log
import ServiceManagement
import UniformTypeIdentifiers
import UserNotifications

private let slackLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Kinshasa", category: "slackMute")

enum TranscriptionModelChoice: String, CaseIterable, Identifiable {
    case parakeetV2 = "parakeet-v2"
    case parakeetV3 = "parakeet-v3"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .parakeetV2: return "Parakeet v2 (English)"
        case .parakeetV3: return "Parakeet v3 (Multilingual)"
        }
    }

    var subtitle: String {
        switch self {
        case .parakeetV2: return "Optimized for English-only transcription"
        case .parakeetV3: return "Supports multiple languages"
        }
    }

    var modelIdentifier: String {
        switch self {
        case .parakeetV2: return "FluidInference/parakeet-tdt-0.6b-v2-coreml"
        case .parakeetV3: return "FluidInference/parakeet-tdt-0.6b-v3-coreml"
        }
    }
}

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

    @Published var shortcutType: ShortcutType {
        didSet {
            UserDefaults.standard.set(shortcutType.rawValue, forKey: DefaultsKey.shortcutType)
        }
    }
    @Published private(set) var invocationShortcut: InvocationShortcut
    @Published private(set) var voiceNoteSwitchKeyCode: Int64
    @Published private(set) var screenRecordingShortcut: InvocationShortcut?
    @Published private(set) var todoSheetShortcut: InvocationShortcut?
    @Published private(set) var chatSheetShortcut: InvocationShortcut?
    @Published private(set) var todoSwitchKeyCode: Int64
    @Published var isCapturingInvocationKey = false
    @Published var isCapturingVoiceNoteSwitchKey = false
    @Published var isCapturingScreenRecordingKey = false
    @Published var isCapturingTodoSwitchKey = false
    @Published var isCapturingTodoSheetKey = false
    @Published var isCapturingChatSheetKey = false
    @Published var statusText: String
    @Published var lastTranscript: String
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var isPreparingModel = false
    @Published var accessibilityGranted = AXIsProcessTrusted()
    @Published var keyboardMonitoringGranted = CGPreflightListenEventAccess()
    @Published var microphoneGranted = false
    @Published var notificationsGranted = false
    @Published private(set) var hasCompletedOnboarding: Bool
    @Published var shouldShowOnboardingWizard: Bool
    @Published var escapeToCancelEnabled: Bool {
        didSet {
            UserDefaults.standard.set(escapeToCancelEnabled, forKey: DefaultsKey.escapeToCancelEnabled)
            shortcutMonitor.escapeToCancelEnabled = escapeToCancelEnabled
        }
    }
    @Published var launchAtLoginEnabled: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLoginEnabled, forKey: DefaultsKey.launchAtLogin)
            if launchAtLoginEnabled {
                try? SMAppService.mainApp.register()
            } else {
                try? SMAppService.mainApp.unregister()
            }
        }
    }
    @Published var showInDock: Bool {
        didSet {
            guard showInDock || showInStatusBar else {
                showInDock = true
                return
            }
            UserDefaults.standard.set(showInDock, forKey: DefaultsKey.showInDock)
            NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
        }
    }
    @Published var showInStatusBar: Bool {
        didSet {
            guard showInStatusBar || showInDock else {
                showInStatusBar = true
                return
            }
            UserDefaults.standard.set(showInStatusBar, forKey: DefaultsKey.showInStatusBar)
            NotificationCenter.default.post(name: .statusBarVisibilityChanged, object: nil, userInfo: ["visible": showInStatusBar])
        }
    }
    @Published var soundEffectsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(soundEffectsEnabled, forKey: DefaultsKey.soundEffectsEnabled)
        }
    }
    @Published var hapticFeedbackEnabled: Bool {
        didSet {
            UserDefaults.standard.set(hapticFeedbackEnabled, forKey: DefaultsKey.hapticFeedbackEnabled)
        }
    }
    @Published var autoCopyToClipboard: Bool {
        didSet {
            UserDefaults.standard.set(autoCopyToClipboard, forKey: DefaultsKey.autoCopyToClipboard)
        }
    }
    @Published var wordReplacements: [WordReplacement] {
        didSet {
            if let data = try? JSONEncoder().encode(wordReplacements) {
                UserDefaults.standard.set(data, forKey: DefaultsKey.wordReplacementsJSON)
            }
        }
    }
    @Published var microphonePriorityUIDs: [String] {
        didSet {
            if let data = try? JSONEncoder().encode(microphonePriorityUIDs) {
                UserDefaults.standard.set(data, forKey: DefaultsKey.microphonePriorityUIDs)
            }
        }
    }
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
    @Published var slackMuteEnabled: Bool {
        didSet {
            UserDefaults.standard.set(slackMuteEnabled, forKey: DefaultsKey.slackMuteEnabled)
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
    private let floatingIndicatorSizePercent: Double = 38
    @Published private(set) var keepModelWarmStatus: String
    @Published var lastShortcutEventAt: Date?
    @Published var lastTranscriptionLatency: TimeInterval?
    @Published var lastTranscriptionBackend: String?
    @Published var appMode: AppMode = .dictation
    @Published private(set) var recordingOutputMode: RecordingOutputMode = .paste
    @Published private(set) var lastNoteSavedAt: Date?
    @Published private(set) var lastTodoSavedAt: Date?
    @Published var selectedTranscriptionModel: TranscriptionModelChoice {
        didSet {
            UserDefaults.standard.set(selectedTranscriptionModel.rawValue, forKey: DefaultsKey.transcriptionModel)
            if oldValue != selectedTranscriptionModel {
                parakeetConfiguration = nil
                Task { _ = await prepareParakeetIfNeeded(showReadyStatus: true) }
            }
        }
    }

    private var initialized = false
    private var interpreter: ShortcutInterpreter
    private let shortcutMonitor = GlobalFnShortcutMonitor()
    private let audioCapture = AudioCaptureService()
    private let transcription = ParakeetTranscriptionService()
    private let pasteService = PasteService()
    private let noteService = NoteService()
    private let duckingService = SystemAudioDuckingService()
    private let slackMuteService = SlackMuteService()
    private let bubble = FloatingBubbleController()
    private let todoConfirmation = TodoConfirmationController()
    var spaceController: SpaceController? {
        didSet { syncSpaceAppearance() }
    }
    private let bootstrapper = LocalParakeetBootstrapper()
    private var parakeetConfiguration: ParakeetConfiguration?
    private var parakeetModel: String {
        ProcessInfo.processInfo.environment["KINSHASA_COREML_MODEL"]
            ?? ProcessInfo.processInfo.environment["PARAKEET_MODEL"]
            ?? selectedTranscriptionModel.modelIdentifier
    }
    private var bubbleHideTask: Task<Void, Never>?
    private var liveTranscriptionLoopTask: Task<Void, Never>?
    private var riveReactiveLoopTask: Task<Void, Never>?
    private var keepModelWarmTask: Task<Void, Never>?
    private var holdReleaseWatchdogTask: Task<Void, Never>?
    private var pendingHoldStopTask: Task<Void, Never>?
    private var indicatorPreviewHideTask: Task<Void, Never>?
    private var liveTranscriptionInFlight = false
    private var liveSnapshotInFlightDuration: TimeInterval?
    private var latestLiveTranscription: LiveTranscriptionResult?
    private var lastKeepModelWarmAt: Date?
    private var smoothedRiveLevel: Double = 0
    private var previousRiveLevel: Double = 0
    private var riveObservedPeakLevel: Double = 0.25
    private var lastRivePulseAt: Date?
    /// Counts consecutive ticks where raw level is below the voice gate.
    /// After enough quiet ticks, the level decays smoothly to zero.
    private var silenceTickCount: Int = 0
    private var holdReleaseMissingSince: Date?
    /// Timestamp when the most recent hold-mode `.startRecording` was received.
    /// Used to suppress spurious `.up` events that arrive within a few ms of
    /// key-down (common with macOS Globe/Fn key clearing `.function` flag).
    private var holdRecordingStartedAt: Date?
    /// Set synchronously on `.startRecording`/`.stopRecording` so the intent
    /// survives the gap while `beginRecording()` is awaiting async setup.
    private var wantRecording = false
    private var localKeyCaptureMonitor: Any?
    private var globalKeyCaptureMonitor: Any?
    private var keyCaptureTarget: KeyCaptureTarget?
    private var captureAccumulatedModifiers: NSEvent.ModifierFlags = []
    private var captureDebounceTimer: Timer?

    private let liveSnapshotMinDuration: TimeInterval = 0.75
    private let liveSnapshotInterval: TimeInterval = 0.80
    private let liveStreamingWindowDuration: TimeInterval = 1.65
    private let riveReactivePollInterval: TimeInterval = 0.03
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
    /// Safety-net debounce for the hold-release watchdog.  CGEventSource.keyState
    /// is unreliable for certain modifier keys (e.g. Right Command on macOS) —
    /// it can report "not pressed" while the key is still held.  A longer
    /// debounce prevents the watchdog from killing a recording prematurely;
    /// normal releases are detected via the event tap's `.up` event instead.
    private let holdReleaseDebounce: TimeInterval = 3.0
    /// Minimum gap before we trust a hold-mode release immediately. Faster
    /// releases are confirmed shortly after to filter spurious modifier `.up`s
    /// without making genuine short holds feel stuck.
    private let holdMinimumDuration: TimeInterval = 0.08
    private let pipelineTimingEnabled = ProcessInfo.processInfo.environment["KINSHASA_TIMING"] == "1"

    private enum DefaultsKey {
        static let mode = "shortcut_mode"
        static let shortcutType = "shortcut_type"
        static let invocationKeyCode = "shortcut_invocation_key_code" // Legacy
        static let invocationShortcutJSON = "invocation_shortcut_json"
        static let voiceNoteSwitchKeyCode = "voice_note_switch_key_code"
        static let todoSwitchKeyCode = "todo_switch_key_code"
        static let screenRecordingKeyCode = "screen_recording_key_code" // Legacy
        static let screenRecordingShortcutJSON = "screen_recording_shortcut_json"
        static let todoSheetShortcutJSON = "todo_sheet_shortcut_json"
        static let chatSheetShortcutJSON = "chat_sheet_shortcut_json"
        static let onboardingCompleted = "onboarding_completed"
        static let escapeToCancelEnabled = "escape_to_cancel_enabled"
        static let launchAtLogin = "launch_at_login"
        static let showInDock = "show_in_dock"
        static let showInStatusBar = "show_in_status_bar"
        static let soundEffectsEnabled = "sound_effects_enabled"
        static let hapticFeedbackEnabled = "haptic_feedback_enabled"
        static let autoCopyToClipboard = "auto_copy_to_clipboard"
        static let wordReplacementsJSON = "word_replacements_json"
        static let microphonePriorityUIDs = "microphone_priority_uids"
        static let duckingEnabled = "ducking_enabled"
        static let duckingAmountPercent = "ducking_amount_percent"
        static let slackMuteEnabled = "slack_mute_enabled"
        static let keepModelWarmEnabled = "keep_model_warm_enabled"
        static let keepModelWarmOnlyOnPower = "keep_model_warm_only_on_power"
        static let riveIndicatorEnabled = "rive_indicator_enabled"
        static let listeningRiveAssetPath = "listening_rive_asset_path"
        static let customSVGIndicatorEnabled = "custom_svg_indicator_enabled"
        static let customSVGIndicatorMarkup = "custom_svg_indicator_markup"
        static let builtInWaveIndicatorEnabled = "built_in_wave_indicator_enabled"
        static let floatingIndicatorPosition = "floating_indicator_position"
        static let floatingIndicatorSizePercent = "floating_indicator_size_percent"
        static let transcriptionModel = "transcription_model"
    }

    private enum KeyCaptureTarget {
        case invocation
        case voiceNoteSwitch
        case screenRecording
        case todoSwitch
        case todoSheet
        case chatSheet
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

        // Migrate invocation shortcut from legacy key code
        let initialInvocationShortcut: InvocationShortcut
        if let jsonData = defaults.data(forKey: DefaultsKey.invocationShortcutJSON),
           let decoded = try? JSONDecoder().decode(InvocationShortcut.self, from: jsonData) {
            initialInvocationShortcut = decoded
        } else if let legacyCode = defaults.object(forKey: DefaultsKey.invocationKeyCode) as? Int {
            initialInvocationShortcut = InvocationShortcut.fromLegacyKeyCode(Int64(legacyCode))
            if let data = try? JSONEncoder().encode(initialInvocationShortcut) {
                defaults.set(data, forKey: DefaultsKey.invocationShortcutJSON)
            }
        } else {
            initialInvocationShortcut = .default
        }

        let initialVoiceNoteSwitchKeyCode: Int64
        if let stored = defaults.object(forKey: DefaultsKey.voiceNoteSwitchKeyCode) as? Int {
            initialVoiceNoteSwitchKeyCode = Int64(stored)
        } else {
            initialVoiceNoteSwitchKeyCode = 0 // A
        }

        let initialTodoSwitchKeyCode: Int64
        if let stored = defaults.object(forKey: DefaultsKey.todoSwitchKeyCode) as? Int {
            initialTodoSwitchKeyCode = Int64(stored)
        } else {
            initialTodoSwitchKeyCode = 17 // T key
        }

        // Migrate screen recording shortcut from legacy key code
        let initialScreenRecordingShortcut: InvocationShortcut?
        if let jsonData = defaults.data(forKey: DefaultsKey.screenRecordingShortcutJSON),
           let decoded = try? JSONDecoder().decode(InvocationShortcut.self, from: jsonData) {
            initialScreenRecordingShortcut = decoded
        } else if let legacyCode = defaults.object(forKey: DefaultsKey.screenRecordingKeyCode) as? Int {
            initialScreenRecordingShortcut = InvocationShortcut.fromLegacyKeyCode(Int64(legacyCode))
            if let data = try? JSONEncoder().encode(initialScreenRecordingShortcut) {
                defaults.set(data, forKey: DefaultsKey.screenRecordingShortcutJSON)
            }
        } else {
            initialScreenRecordingShortcut = nil
        }

        let initialTodoSheetShortcut: InvocationShortcut?
        if let jsonData = defaults.data(forKey: DefaultsKey.todoSheetShortcutJSON),
           let decoded = try? JSONDecoder().decode(InvocationShortcut.self, from: jsonData) {
            initialTodoSheetShortcut = decoded
        } else {
            // Default: ⌃⇧T (Control+Shift+T)
            let controlShift = NSEvent.ModifierFlags.control.rawValue | NSEvent.ModifierFlags.shift.rawValue
            initialTodoSheetShortcut = InvocationShortcut(primaryKeyCode: 17, modifiers: controlShift)
        }

        let initialChatSheetShortcut: InvocationShortcut?
        if let jsonData = defaults.data(forKey: DefaultsKey.chatSheetShortcutJSON),
           let decoded = try? JSONDecoder().decode(InvocationShortcut.self, from: jsonData) {
            initialChatSheetShortcut = decoded
        } else {
            // Default: ⌃⇧A (Control+Shift+A)
            let controlShift = NSEvent.ModifierFlags.control.rawValue | NSEvent.ModifierFlags.shift.rawValue
            initialChatSheetShortcut = InvocationShortcut(primaryKeyCode: 0, modifiers: controlShift)
        }

        mode = initialMode
        // Infer shortcut type from existing shortcut if not persisted
        if let storedType = ShortcutType(rawValue: defaults.string(forKey: DefaultsKey.shortcutType) ?? "") {
            shortcutType = storedType
        } else {
            shortcutType = initialInvocationShortcut.isSingleKey || initialInvocationShortcut.isModifierOnly ? .singleKey : .combination
        }
        invocationShortcut = initialInvocationShortcut
        voiceNoteSwitchKeyCode = initialVoiceNoteSwitchKeyCode
        todoSwitchKeyCode = initialTodoSwitchKeyCode
        screenRecordingShortcut = initialScreenRecordingShortcut
        todoSheetShortcut = initialTodoSheetShortcut
        chatSheetShortcut = initialChatSheetShortcut

        escapeToCancelEnabled = defaults.object(forKey: DefaultsKey.escapeToCancelEnabled) as? Bool ?? false
        launchAtLoginEnabled = defaults.object(forKey: DefaultsKey.launchAtLogin) as? Bool ?? false
        showInDock = defaults.object(forKey: DefaultsKey.showInDock) as? Bool ?? true
        showInStatusBar = defaults.object(forKey: DefaultsKey.showInStatusBar) as? Bool ?? true
        soundEffectsEnabled = defaults.object(forKey: DefaultsKey.soundEffectsEnabled) as? Bool ?? false
        hapticFeedbackEnabled = defaults.object(forKey: DefaultsKey.hapticFeedbackEnabled) as? Bool ?? false
        autoCopyToClipboard = defaults.object(forKey: DefaultsKey.autoCopyToClipboard) as? Bool ?? true

        if let wrData = defaults.data(forKey: DefaultsKey.wordReplacementsJSON),
           let decoded = try? JSONDecoder().decode([WordReplacement].self, from: wrData) {
            wordReplacements = decoded
        } else {
            wordReplacements = []
        }

        if let mpData = defaults.data(forKey: DefaultsKey.microphonePriorityUIDs),
           let decoded = try? JSONDecoder().decode([String].self, from: mpData) {
            microphonePriorityUIDs = decoded
        } else {
            microphonePriorityUIDs = []
        }

        duckingEnabled = defaults.object(forKey: DefaultsKey.duckingEnabled) as? Bool ?? false
        let storedDuckingAmount = defaults.object(forKey: DefaultsKey.duckingAmountPercent) as? Double ?? 40
        duckingAmountPercent = min(max(storedDuckingAmount, 0), 90)
        slackMuteEnabled = defaults.object(forKey: DefaultsKey.slackMuteEnabled) as? Bool ?? false
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

        let storedModelRaw = defaults.string(forKey: DefaultsKey.transcriptionModel) ?? ""
        selectedTranscriptionModel = TranscriptionModelChoice(rawValue: storedModelRaw) ?? .parakeetV2

        accessibilityGranted = initialAccessibilityGranted
        keyboardMonitoringGranted = initialKeyboardMonitoringGranted
        microphoneGranted = initialMicrophoneGranted
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            notificationsGranted = settings.authorizationStatus == .authorized
        }
        shortcutMonitor.setInvocationShortcut(initialInvocationShortcut)
        shortcutMonitor.setVoiceNoteSwitchKeyCode(initialVoiceNoteSwitchKeyCode)
        shortcutMonitor.setTodoSwitchKeyCode(initialTodoSwitchKeyCode)
        shortcutMonitor.setScreenRecordingShortcut(initialScreenRecordingShortcut)
        shortcutMonitor.escapeToCancelEnabled = escapeToCancelEnabled

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
                self?.toggleRecordingOutputMode()
            }
        }
        shortcutMonitor.onTodoSwitchKeyPressed = { [weak self] in
            Task { @MainActor [weak self] in
                self?.setTodoMode()
            }
        }
        shortcutMonitor.onSpaceCycleKeyPressed = { [weak self] direction in
            Task { @MainActor [weak self] in
                self?.cycleSpace(direction: direction)
            }
        }
        shortcutMonitor.onScreenRecordingKeyPressed = { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleScreenRecordingShortcut()
            }
        }
        if let initialTodoSheetShortcut = todoSheetShortcut {
            shortcutMonitor.setTodoSheetShortcut(initialTodoSheetShortcut)
        }
        shortcutMonitor.onTodoSheetKeyPressed = { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleTodoSheetShortcut()
            }
        }
        if let initialChatSheetShortcut = chatSheetShortcut {
            shortcutMonitor.setChatSheetShortcut(initialChatSheetShortcut)
        }
        shortcutMonitor.onChatSheetKeyPressed = { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleChatSheetShortcut()
            }
        }
        shortcutMonitor.onEscapePressed = { [weak self] in
            Task { @MainActor [weak self] in
                self?.cancelRecording()
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
        invocationShortcut.displayName
    }

    var allRequiredPermissionsGranted: Bool {
        accessibilityGranted && keyboardMonitoringGranted && microphoneGranted
    }

    var voiceNoteSwitchKeyDisplayName: String {
        InvocationKey.displayName(for: voiceNoteSwitchKeyCode)
    }

    var todoSwitchKeyDisplayName: String {
        InvocationKey.displayName(for: todoSwitchKeyCode)
    }

    var screenRecordingKeyDisplayName: String {
        screenRecordingShortcut?.displayName ?? "Not Set"
    }

    var todoSheetKeyDisplayName: String {
        todoSheetShortcut?.displayName ?? "Not Set"
    }

    var chatSheetKeyDisplayName: String {
        chatSheetShortcut?.displayName ?? "Not Set"
    }

    func showOnboardingWizard() {
        shouldShowOnboardingWizard = true
    }

    func dismissOnboardingWizard() {
        hasCompletedOnboarding = true
        shouldShowOnboardingWizard = false
        UserDefaults.standard.set(true, forKey: DefaultsKey.onboardingCompleted)
    }

    func completeOnboardingWizard() {
        hasCompletedOnboarding = true
        shouldShowOnboardingWizard = false
        UserDefaults.standard.set(true, forKey: DefaultsKey.onboardingCompleted)
    }

    var notesDirectoryPathText: String {
        noteService.notesDirectoryPath()
    }

    func loadAllNotes() -> [VoiceNote] {
        noteService.loadAllNotes()
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

    func applyInvocationShortcut(_ shortcut: InvocationShortcut) {
        setInvocationShortcut(shortcut)
        statusText = "Invocation key set to \(invocationKeyDisplayName)."
    }

    func applyScreenRecordingShortcut(_ shortcut: InvocationShortcut) {
        setScreenRecordingShortcut(shortcut)
        statusText = "Screen recording shortcut set to \(screenRecordingKeyDisplayName)."
    }

    func applyTodoSheetShortcut(_ shortcut: InvocationShortcut) {
        setTodoSheetShortcut(shortcut)
        statusText = "Todo sheet shortcut set to \(todoSheetKeyDisplayName)."
    }

    func applyChatSheetShortcut(_ shortcut: InvocationShortcut) {
        setChatSheetShortcut(shortcut)
        statusText = "Chat sheet shortcut set to \(chatSheetKeyDisplayName)."
    }

    func startInvocationKeyCapture() {
        guard !isCapturingInvocationKey, !isCapturingVoiceNoteSwitchKey, !isCapturingScreenRecordingKey, !isCapturingTodoSwitchKey, !isCapturingTodoSheetKey, !isCapturingChatSheetKey else {
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
        guard !isCapturingInvocationKey, !isCapturingVoiceNoteSwitchKey, !isCapturingScreenRecordingKey, !isCapturingTodoSwitchKey, !isCapturingTodoSheetKey, !isCapturingChatSheetKey else {
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

    func startScreenRecordingKeyCapture() {
        guard !isCapturingInvocationKey, !isCapturingVoiceNoteSwitchKey, !isCapturingScreenRecordingKey, !isCapturingTodoSwitchKey, !isCapturingTodoSheetKey, !isCapturingChatSheetKey else {
            return
        }

        keyCaptureTarget = .screenRecording
        isCapturingScreenRecordingKey = true
        statusText = "Press a key for the quick screen recording shortcut."
        installInvocationKeyCaptureMonitors()
    }

    func cancelScreenRecordingKeyCapture() {
        guard isCapturingScreenRecordingKey else {
            return
        }

        isCapturingScreenRecordingKey = false
        keyCaptureTarget = nil
        removeInvocationKeyCaptureMonitors()
        statusText = "Screen recording key capture canceled."
    }

    func startTodoSwitchKeyCapture() {
        guard !isCapturingInvocationKey, !isCapturingVoiceNoteSwitchKey, !isCapturingScreenRecordingKey, !isCapturingTodoSwitchKey, !isCapturingTodoSheetKey, !isCapturingChatSheetKey else {
            return
        }

        keyCaptureTarget = .todoSwitch
        isCapturingTodoSwitchKey = true
        statusText = "Press the key to switch to Todo mode while recording."
        installInvocationKeyCaptureMonitors()
    }

    func cancelTodoSwitchKeyCapture() {
        guard isCapturingTodoSwitchKey else {
            return
        }

        isCapturingTodoSwitchKey = false
        keyCaptureTarget = nil
        removeInvocationKeyCaptureMonitors()
        statusText = "Todo key capture canceled."
    }

    func startTodoSheetKeyCapture() {
        guard !isCapturingInvocationKey, !isCapturingVoiceNoteSwitchKey, !isCapturingScreenRecordingKey, !isCapturingTodoSwitchKey, !isCapturingTodoSheetKey, !isCapturingChatSheetKey else {
            return
        }

        keyCaptureTarget = .todoSheet
        isCapturingTodoSheetKey = true
        statusText = "Press a key combination for the Todo Sheet shortcut."
        installInvocationKeyCaptureMonitors()
    }

    func cancelTodoSheetKeyCapture() {
        guard isCapturingTodoSheetKey else {
            return
        }

        isCapturingTodoSheetKey = false
        keyCaptureTarget = nil
        removeInvocationKeyCaptureMonitors()
        statusText = "Todo Sheet key capture canceled."
    }

    func clearScreenRecordingKey() {
        screenRecordingShortcut = nil
        shortcutMonitor.setScreenRecordingShortcut(nil)
        UserDefaults.standard.removeObject(forKey: DefaultsKey.screenRecordingShortcutJSON)
    }

    func clearTodoSheetKey() {
        todoSheetShortcut = nil
        shortcutMonitor.setTodoSheetShortcut(nil)
        UserDefaults.standard.removeObject(forKey: DefaultsKey.todoSheetShortcutJSON)
    }

    func startChatSheetKeyCapture() {
        guard !isCapturingInvocationKey, !isCapturingVoiceNoteSwitchKey, !isCapturingScreenRecordingKey, !isCapturingTodoSwitchKey, !isCapturingTodoSheetKey, !isCapturingChatSheetKey else {
            return
        }

        keyCaptureTarget = .chatSheet
        isCapturingChatSheetKey = true
        statusText = "Press a key combination for the Chat Sheet shortcut."
        installInvocationKeyCaptureMonitors()
    }

    func cancelChatSheetKeyCapture() {
        guard isCapturingChatSheetKey else {
            return
        }

        isCapturingChatSheetKey = false
        keyCaptureTarget = nil
        removeInvocationKeyCaptureMonitors()
        statusText = "Chat Sheet key capture canceled."
    }

    func clearChatSheetKey() {
        chatSheetShortcut = nil
        shortcutMonitor.setChatSheetShortcut(nil)
        UserDefaults.standard.removeObject(forKey: DefaultsKey.chatSheetShortcutJSON)
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
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            notificationsGranted = settings.authorizationStatus == .authorized
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
        pendingHoldStopTask?.cancel()
        pendingHoldStopTask = nil
        shortcutMonitor.setRecordingControlsActive(false)
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
        guard !isCapturingInvocationKey, !isCapturingVoiceNoteSwitchKey, !isCapturingScreenRecordingKey, !isCapturingTodoSwitchKey, !isCapturingTodoSheetKey, !isCapturingChatSheetKey else {
            holdDebugLog("handleShortcutEvent: BLOCKED by capture mode")
            return
        }

        lastShortcutEventAt = .now
        holdDebugLog("handleShortcutEvent: event=\(event) mode=\(mode) isRecording=\(isRecording) wantRecording=\(wantRecording) isTranscribing=\(isTranscribing)")

        guard let action = interpreter.handle(event) else {
            holdDebugLog("handleShortcutEvent: interpreter returned nil")
            return
        }

        holdDebugLog("handleShortcutEvent: action=\(action)")

        switch action {
        case .toggleRecording:
            pendingHoldStopTask?.cancel()
            pendingHoldStopTask = nil
            if isRecording {
                wantRecording = false
                stopRecordingAndTranscribe()
            } else {
                wantRecording = true
                Task {
                    await beginRecording()
                }
            }
        case .startRecording:
            pendingHoldStopTask?.cancel()
            pendingHoldStopTask = nil
            holdRecordingStartedAt = .now
            wantRecording = true
            Task {
                await beginRecording()
            }
        case .stopRecording:
            // Guard against spurious rapid releases.  Modifier keys (especially
            // Fn/Globe) can emit a flagsChanged that clears the modifier flag
            // within milliseconds of the key-down, even though the key is still
            // physically held.  If the .up arrives too fast, ignore it — the
            // hold-release watchdog will detect the real release independently.
            if let started = holdRecordingStartedAt {
                let elapsed = Date.now.timeIntervalSince(started)
                holdDebugLog(".stopRecording: elapsed since start = \(elapsed)s, threshold = \(holdMinimumDuration)s")
                if elapsed < holdMinimumDuration {
                    holdDebugLog(".stopRecording: deferring confirmation")
                    scheduleHoldStopConfirmation(after: holdMinimumDuration - elapsed)
                    return
                }
            } else {
                holdDebugLog(".stopRecording: holdRecordingStartedAt is nil")
            }
            pendingHoldStopTask?.cancel()
            pendingHoldStopTask = nil
            holdRecordingStartedAt = nil
            wantRecording = false
            shortcutMonitor.setRecordingControlsActive(false)
            if isRecording {
                stopRecordingAndTranscribe()
            }
            // If beginRecording() is still in its async setup, the wantRecording
            // flag being false will cause it to stop immediately after starting.
        }
    }

    private func handleScreenRecordingShortcut() {
        guard !isCapturingInvocationKey, !isCapturingVoiceNoteSwitchKey, !isCapturingScreenRecordingKey, !isCapturingTodoSwitchKey, !isCapturingTodoSheetKey, !isCapturingChatSheetKey else {
            return
        }
        NotificationCenter.default.post(name: .toggleScreenRecording, object: nil)
    }

    private func handleTodoSheetShortcut() {
        guard !isCapturingInvocationKey, !isCapturingVoiceNoteSwitchKey, !isCapturingScreenRecordingKey, !isCapturingTodoSwitchKey, !isCapturingTodoSheetKey, !isCapturingChatSheetKey else {
            return
        }
        TodoSideSheetController.shared.toggle()
    }

    private func handleChatSheetShortcut() {
        guard !isCapturingInvocationKey, !isCapturingVoiceNoteSwitchKey, !isCapturingScreenRecordingKey, !isCapturingTodoSwitchKey, !isCapturingTodoSheetKey, !isCapturingChatSheetKey else {
            return
        }
        ChatSideSheetController.shared.toggle()
    }

    private func scheduleHoldStopConfirmation(after delay: TimeInterval) {
        pendingHoldStopTask?.cancel()
        let delayNanos = UInt64(max(0, delay) * 1_000_000_000)

        pendingHoldStopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNanos)
            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                guard let self else {
                    return
                }

                self.pendingHoldStopTask = nil
                guard self.mode == .hold else {
                    return
                }
                guard !self.shortcutMonitor.isInvocationKeyPhysicallyPressed() else {
                    holdDebugLog(".stopRecording: deferred stop canceled (key still pressed)")
                    return
                }

                holdDebugLog(".stopRecording: deferred stop confirmed")
                self.holdRecordingStartedAt = nil
                self.wantRecording = false
                self.shortcutMonitor.setRecordingControlsActive(false)
                if self.isRecording {
                    self.stopRecordingAndTranscribe()
                }
            }
        }
    }

    private func toggleRecordingOutputMode() {
        guard isRecording, !isTranscribing else {
            return
        }

        recordingOutputMode = recordingOutputMode == .voiceNote ? .paste : .voiceNote
        statusText = listeningStatusText(isLive: false)
        showBubble(message: listeningBubbleMessage(), isRecording: true)
    }

    private func setTodoMode() {
        guard isRecording, !isTranscribing else {
            return
        }
        recordingOutputMode = recordingOutputMode == .todo ? .paste : .todo
        statusText = listeningStatusText(isLive: false)
        showBubble(message: listeningBubbleMessage(), isRecording: true)
    }

    private func cycleSpace(direction: GlobalFnShortcutMonitor.SpaceCycleDirection) {
        guard isRecording, !isTranscribing else {
            return
        }
        guard let sc = spaceController else {
            return
        }

        let spaces = sc.availableSpaces
        guard spaces.count > 1 else {
            return
        }

        let currentIndex = spaces.firstIndex(where: { $0.id == sc.activeSpace.id }) ?? 0
        let nextIndex: Int
        switch direction {
        case .left:
            nextIndex = (currentIndex - 1 + spaces.count) % spaces.count
        case .right:
            nextIndex = (currentIndex + 1) % spaces.count
        }

        let nextSpace = spaces[nextIndex]
        sc.switchSpace(to: nextSpace)
        syncSpaceAppearance()
    }

    private func listeningBubbleMessage() -> String {
        switch recordingOutputMode {
        case .paste:
            return "Listening..."
        case .voiceNote:
            return "Listening (Note Mode)..."
        case .todo:
            return "Listening (Todo Mode)..."
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
        case (.todo, false):
            return "Listening... (todo mode)"
        case (.todo, true):
            return "Listening... (todo mode, live)"
        }
    }

    private func beginRecording() async {
        holdDebugLog("beginRecording: START appMode=\(appMode) isRecording=\(isRecording) isTranscribing=\(isTranscribing) wantRecording=\(wantRecording)")
        guard appMode == .dictation else {
            holdDebugLog("beginRecording: BAIL appMode != dictation")
            return
        }

        guard !isRecording, !isTranscribing else {
            holdDebugLog("beginRecording: BAIL isRecording=\(isRecording) isTranscribing=\(isTranscribing)")
            return
        }

        guard await prepareParakeetIfNeeded(showReadyStatus: true) else {
            holdDebugLog("beginRecording: BAIL parakeet not ready")
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

        // A stop request may have arrived while we were awaiting async setup.
        guard wantRecording else {
            holdDebugLog("beginRecording: BAIL wantRecording=false (stop arrived during setup)")
            shortcutMonitor.setRecordingControlsActive(false)
            return
        }

        do {
            try audioCapture.startRecording()
            holdDebugLog("beginRecording: audio started, setting isRecording=true")
            isRecording = true
            shortcutMonitor.setRecordingControlsActive(true)
            playSoundEffect()
            performHaptic()
            recordingOutputMode = .paste
            latestLiveTranscription = nil
            liveTranscriptionInFlight = false
            liveSnapshotInFlightDuration = nil
            startHoldReleaseWatchdogIfNeeded()

            // Double-check: a stop may have arrived between startRecording and now.
            guard wantRecording else {
                stopRecordingAndTranscribe()
                return
            }

            statusText = listeningStatusText(isLive: false)
            showBubble(message: listeningBubbleMessage(), isRecording: true)
            startRiveReactiveLoopIfNeeded()
            applyDuckingIfNeeded()
            muteSlackIfNeeded()
            startLiveTranscriptionLoop(configuration: configuration)
        } catch {
            shortcutMonitor.setRecordingControlsActive(false)
            recordingOutputMode = .paste
            handleError(error.localizedDescription)
        }
    }

    private func stopRecordingAndTranscribe() {
        holdDebugLog("stopRecordingAndTranscribe: isRecording=\(isRecording)")
        // Log the call stack to see WHO called this
        Thread.callStackSymbols.prefix(6).forEach { holdDebugLog("  \($0)") }
        guard isRecording else {
            return
        }

        // Always restore volume ducking when leaving the recording state,
        // regardless of which path we take (success, error, or early return).
        pendingHoldStopTask?.cancel()
        pendingHoldStopTask = nil
        holdRecordingStartedAt = nil
        wantRecording = false
        isRecording = false
        shortcutMonitor.setRecordingControlsActive(false)
        playSoundEffect()
        performHaptic()
        duckingService.restoreIfNeeded()
        let slackService = slackMuteService
        DispatchQueue.global(qos: .userInitiated).async {
            slackService.restoreIfNeeded()
        }

        guard let configuration = parakeetConfiguration else {
            stopLiveTranscriptionLoop()
            stopHoldReleaseWatchdog()
            stopRiveReactiveLoop(resetInputs: true)
            recordingOutputMode = .paste
            handleError("Speech model is still preparing. Try again in a few seconds.")
            return
        }

        do {
            let stoppedRecording = try audioCapture.stopRecording()
            let recordedFile = stoppedRecording.url
            let finalDuration = stoppedRecording.duration

            isTranscribing = true
            stopLiveTranscriptionLoop()
            stopHoldReleaseWatchdog()
            stopRiveReactiveLoop(resetInputs: true)
            statusText = "Transcribing..."
            bubble.hide()

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
                        // Don't call handleError here — it would re-show the
                        // bubble via showTransientBubble after it was already
                        // hidden in stopRecordingAndTranscribe.
                        isTranscribing = false
                        recordingOutputMode = .paste
                        statusText = "No speech detected."
                        bubble.hide()
                    }
                }
            }
        } catch {
            recordingOutputMode = .paste
            stopLiveTranscriptionLoop()
            stopHoldReleaseWatchdog()
            stopRiveReactiveLoop(resetInputs: true)
            handleError(error.localizedDescription)
        }
    }

    func cancelRecording() {
        holdDebugLog("cancelRecording called, isRecording=\(isRecording)")
        guard isRecording else { return }

        pendingHoldStopTask?.cancel()
        pendingHoldStopTask = nil
        holdRecordingStartedAt = nil
        wantRecording = false
        isRecording = false
        shortcutMonitor.setRecordingControlsActive(false)
        duckingService.restoreIfNeeded()
        let slackService = slackMuteService
        DispatchQueue.global(qos: .userInitiated).async {
            slackService.restoreIfNeeded()
        }
        _ = try? audioCapture.stopRecording() // Discard audio
        stopLiveTranscriptionLoop()
        stopHoldReleaseWatchdog()
        stopRiveReactiveLoop(resetInputs: true)
        recordingOutputMode = .paste
        statusText = "Recording cancelled."
        showTransientBubble(message: "Cancelled", duration: 0.8)
        playSoundEffect()
    }

    private func playSoundEffect() {
        guard soundEffectsEnabled else { return }
        NSSound(named: "Tink")?.play()
    }

    private func performHaptic() {
        guard hapticFeedbackEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
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

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            recordingOutputMode = .paste
            statusText = "No speech detected."
            bubble.hide()
            return
        }

        let cleaned = wordReplacements.isEmpty ? trimmed : WordReplacementEngine.apply(wordReplacements, to: trimmed)
        lastTranscript = cleaned

        switch recordingOutputMode {
        case .paste:
            let pasteStartedAt = Date()
            let didPaste: Bool
            if autoCopyToClipboard {
                didPaste = pasteService.copyAndPaste(cleaned)
            } else {
                didPaste = pasteService.pasteWithoutCopying(cleaned)
            }
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
            } else {
                statusText = "Transcribed and copied. Grant Accessibility for auto-paste."
            }
            // The indicator was already hidden when recording stopped;
            // don't re-show it with a transient bubble.
            bubble.hide()
        case .voiceNote:
            do {
                let fileURL = try noteService.appendVoiceNote(cleaned)
                statusText = "Saved to Voice Note (\(fileURL.lastPathComponent))."
                Task { await syncNoteToConvex(text: cleaned) }
            } catch {
                handleError("Could not save voice note. \(error.localizedDescription)")
            }
            bubble.hide()
        case .todo:
            statusText = "Creating todo..."
            Task { await syncTodoToConvex(text: cleaned) }
            bubble.hide()
        }

        recordingOutputMode = .paste
    }

    private func handleError(_ message: String) {
        if !isRecording {
            pendingHoldStopTask?.cancel()
            pendingHoldStopTask = nil
            stopHoldReleaseWatchdog()
            stopRiveReactiveLoop(resetInputs: true)
            shortcutMonitor.setRecordingControlsActive(false)
            recordingOutputMode = .paste
        }
        // Always restore ducking as a safety net, regardless of recording state.
        // restoreIfNeeded() is idempotent (no-op when savedState is nil).
        duckingService.restoreIfNeeded()
        statusText = message
        showTransientBubble(message: "Error", duration: 1.6)
    }

    private func syncNoteToConvex(text: String) async {
        let now = Date()
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"

        do {
            let token = try await ConvexHTTPClient.getToken()
            var args: [String: Any] = [
                "text": text,
                "dayStamp": dayFormatter.string(from: now),
                "timestamp": timeFormatter.string(from: now),
            ]
            if let spaceId = spaceController?.currentSpaceId {
                args["spaceId"] = spaceId
            }
            _ = try await ConvexHTTPClient.mutation(
                function: "notes:create",
                args: args,
                token: token
            )
            lastNoteSavedAt = now
        } catch {
            NSLog("[DictationController] Failed to sync note to Convex: %@", String(describing: error))
        }
    }

    private func syncTodoToConvex(text: String) async {
        do {
            let token = try await ConvexHTTPClient.getToken()
            var args: [String: Any] = [
                "rawText": text,
                "timezone": TimeZone.current.identifier,
            ]
            if let spaceId = spaceController?.currentSpaceId {
                args["spaceId"] = spaceId
            }
            let result = try await ConvexHTTPClient.action(
                function: "todos:processAndCreate",
                args: args,
                token: token
            )
            lastTodoSavedAt = Date()

            // Parse the returned JSON and show confirmation card
            if let jsonString = result as? String,
               let data = jsonString.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

                let info = CreatedTodoInfo(
                    id: json["id"] as? String ?? "",
                    title: json["title"] as? String ?? text,
                    description: json["description"] as? String,
                    dueDate: json["dueDate"] as? String,
                    dueTime: json["dueTime"] as? String,
                    priority: json["priority"] as? String ?? "none",
                    tags: json["tags"] as? [String],
                    reminderCount: (json["reminders"] as? [[String: Any]])?.count ?? 0,
                    listName: json["listName"] as? String
                )
                showTodoConfirmation(info)
            }

            statusText = "Todo created."
        } catch {
            handleError("Could not create todo. \(error.localizedDescription)")
        }
    }

    private func showTodoConfirmation(_ todo: CreatedTodoInfo) {
        todoConfirmation.onSave = { [weak self] todo, updates in
            await self?.saveTodoEdit(todoId: todo.id, updates: updates)
        }
        todoConfirmation.show(todo: todo)
    }

    private nonisolated func saveTodoEdit(todoId: String, updates: TodoEditUpdates) async {
        do {
            let token = try await ConvexHTTPClient.getToken()
            var args: [String: Any] = [
                "todoId": todoId,
                "title": updates.title,
                "priority": updates.priority,
            ]
            if let dueDate = updates.dueDate { args["dueDate"] = dueDate }
            if let dueTime = updates.dueTime { args["dueTime"] = dueTime }
            if let tags = updates.tags { args["tags"] = tags }
            _ = try await ConvexHTTPClient.mutation(
                function: "todos:update",
                args: args,
                token: token
            )
            await MainActor.run { lastTodoSavedAt = Date() }
        } catch {
            NSLog("[DictationController] Failed to update todo: %@", String(describing: error))
        }
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

    private func muteSlackIfNeeded() {
        slackLog.info("muteSlackIfNeeded: slackMuteEnabled=\(self.slackMuteEnabled)")
        guard slackMuteEnabled else { return }
        // Run on a background thread to avoid blocking the main thread
        // (the mute toggle uses usleep for timing, which would freeze the UI).
        let service = slackMuteService
        DispatchQueue.global(qos: .userInitiated).async {
            service.muteIfInCall()
        }
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

        // Check both the event-tap's logical state AND the hardware state.
        // CGEventSource.keyState is unreliable for modifier keys (especially
        // Fn/Globe) — it can report "not pressed" while the key is still
        // physically held.  The event-tap's internal flag tracks the actual
        // flagsChanged events we receive, so if it says the key is down we
        // trust it.  The watchdog only fires when BOTH agree the key is up.
        let physicallyPressed = shortcutMonitor.isInvocationKeyPhysicallyPressed()
        let logicallyPressed = shortcutMonitor.isInvocationKeyCurrentlyPressed()
        let isPressed = physicallyPressed || logicallyPressed
        if isPressed {
            holdReleaseMissingSince = nil
            return
        }

        holdDebugLog("watchdog: key NOT pressed! holdReleaseMissingSince=\(String(describing: holdReleaseMissingSince))")

        if holdReleaseMissingSince == nil {
            holdReleaseMissingSince = .now
            return
        }

        guard let holdReleaseMissingSince,
              Date().timeIntervalSince(holdReleaseMissingSince) >= holdReleaseDebounce
        else {
            return
        }

        holdDebugLog("watchdog: STOPPING recording (debounce elapsed: \(Date().timeIntervalSince(holdReleaseMissingSince))s)")
        // Clear the stale internal flag so the next key-down is recognized
        // correctly (otherwise handleFlagsChanged would see keyDown == isInvocationKeyPressed
        // and suppress it).
        shortcutMonitor.resetInvocationKeyState()
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
        silenceTickCount = 0
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
        silenceTickCount = 0

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
        riveObservedPeakLevel = max(riveObservedPeakLevel * 0.985, rawLevel)
        let leveled = min(max(rawLevel / max(riveObservedPeakLevel, 0.15), 0), 1)

        // Heavy smoothing for gentle VU-meter feel.
        // Track consecutive quiet ticks; after a sustained silence period,
        // smoothly decay to zero (no abrupt snap).
        if leveled < 0.10 {
            silenceTickCount += 1
            // ~5 ticks at 30ms = ~150ms of confirmed silence before decaying.
            // Decay smoothly rather than snapping to zero.
            if silenceTickCount >= 5 {
                smoothedRiveLevel *= 0.80 // Smooth exponential decay
                if smoothedRiveLevel < 0.01 {
                    smoothedRiveLevel = 0
                }
            }
            // During the grace period (< 5 ticks), hold the current level
            // to avoid cutting off between syllables.
        } else {
            silenceTickCount = 0
            smoothedRiveLevel += (leveled - smoothedRiveLevel) * 0.15
        }
        let level = smoothedRiveLevel

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
            isNoteMode: false,
            riveAssetPath: preferredRiveAssetPath(),
            htmlIndicatorMarkup: preferredCustomSVGMarkup(),
            useBuiltInWaveIndicator: builtInWaveIndicatorEnabled
        )

        scheduleIndicatorPreviewHide(delay: 0.9)
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

    private func syncSpaceAppearance() {
        guard let sc = spaceController else { return }
        bubble.setSpaceAppearance(
            color: sc.activeSpaceColor.nsColor,
            icon: sc.activeSpaceIcon
        )
    }

    private func showBubble(message: String, isRecording: Bool, isTranscribing: Bool = false) {
        syncSpaceAppearance()
        indicatorPreviewHideTask?.cancel()
        indicatorPreviewHideTask = nil
        bubbleHideTask?.cancel()
        bubble.show(
            message: message,
            isRecording: isRecording,
            isTranscribing: isTranscribing,
            isNoteMode: recordingOutputMode == .voiceNote,
            isTodoMode: recordingOutputMode == .todo,
            riveAssetPath: riveAssetPathIfEnabled(forRecordingState: isRecording),
            htmlIndicatorMarkup: (isRecording || isTranscribing) ? preferredCustomSVGMarkup() : nil,
            useBuiltInWaveIndicator: builtInWaveIndicatorEnabled
        )
    }

    private func showTransientBubble(message: String, duration: TimeInterval = 0.95) {
        syncSpaceAppearance()
        bubbleHideTask?.cancel()
        bubble.show(
            message: message,
            isRecording: false,
            isTranscribing: false,
            isNoteMode: false,
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

        let capturedKeyCode = Int64(event.keyCode)

        // Single-key mode for invocation: accept any key immediately, no modifier accumulation
        if keyCaptureTarget == .invocation, shortcutType == .singleKey {
            if event.type == .flagsChanged {
                // Modifier key pressed — use it as the single key
                if InvocationKey.isModifierKeyCode(capturedKeyCode) {
                    let shortcut = InvocationShortcut(primaryKeyCode: capturedKeyCode, modifiers: 0)
                    finalizeCapturedShortcut(shortcut, for: keyCaptureTarget)
                }
                return
            }
            if event.type == .keyDown {
                if event.isARepeat { return }
                let shortcut = InvocationShortcut(primaryKeyCode: capturedKeyCode, modifiers: 0)
                finalizeCapturedShortcut(shortcut, for: keyCaptureTarget)
            }
            return
        }

        // Combination mode: accumulate modifiers, finalize on regular key press
        if event.type == .flagsChanged {
            // Accumulate modifier flags
            if InvocationKey.isModifierKeyCode(capturedKeyCode) {
                let flag = InvocationKey.modifierFlag(for: capturedKeyCode)
                captureAccumulatedModifiers.insert(flag)
            }

            // Reset debounce timer for modifier-only shortcuts
            captureDebounceTimer?.invalidate()
            captureDebounceTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.finalizeCaptureAsModifierOnly()
                }
            }
            return
        }

        if event.type == .keyDown {
            if event.isARepeat { return }

            // A non-modifier key was pressed — finalize as modifier+key or single key
            captureDebounceTimer?.invalidate()
            captureDebounceTimer = nil

            let shortcut = InvocationShortcut(
                primaryKeyCode: capturedKeyCode,
                modifiers: captureAccumulatedModifiers.rawValue
            )
            finalizeCapturedShortcut(shortcut, for: keyCaptureTarget)
        }
    }

    private func finalizeCaptureAsModifierOnly() {
        guard let keyCaptureTarget else { return }
        guard !captureAccumulatedModifiers.isEmpty else { return }

        let shortcut = InvocationShortcut(primaryKeyCode: nil, modifiers: captureAccumulatedModifiers.rawValue)
        finalizeCapturedShortcut(shortcut, for: keyCaptureTarget)
    }

    private func finalizeCapturedShortcut(_ shortcut: InvocationShortcut, for target: KeyCaptureTarget) {
        guard shortcut.isValid else {
            statusText = "Invalid shortcut. Try again."
            return
        }

        captureAccumulatedModifiers = []
        captureDebounceTimer?.invalidate()
        captureDebounceTimer = nil

        switch target {
        case .invocation:
            setInvocationShortcut(shortcut)
            statusText = "Invocation key set to \(invocationKeyDisplayName)."
        case .voiceNoteSwitch:
            if let primaryKey = shortcut.primaryKeyCode, shortcut.modifiers == 0 {
                setVoiceNoteSwitchKeyCode(primaryKey)
                statusText = "Voice Note key set to \(voiceNoteSwitchKeyDisplayName)."
            } else {
                statusText = "Voice Note key must be a single key."
                return
            }
        case .screenRecording:
            setScreenRecordingShortcut(shortcut)
            statusText = "Screen recording key set to \(screenRecordingKeyDisplayName)."
        case .todoSwitch:
            if let primaryKey = shortcut.primaryKeyCode, shortcut.modifiers == 0 {
                setTodoSwitchKeyCode(primaryKey)
                statusText = "Todo key set to \(todoSwitchKeyDisplayName)."
            } else {
                statusText = "Todo key must be a single key."
                return
            }
        case .todoSheet:
            isCapturingTodoSheetKey = false
            keyCaptureTarget = nil
            removeInvocationKeyCaptureMonitors()
            setTodoSheetShortcut(shortcut)
            statusText = "Todo sheet shortcut set to \(todoSheetKeyDisplayName)."
        case .chatSheet:
            isCapturingChatSheetKey = false
            keyCaptureTarget = nil
            removeInvocationKeyCaptureMonitors()
            setChatSheetShortcut(shortcut)
            statusText = "Chat sheet shortcut set to \(chatSheetKeyDisplayName)."
        }

        isCapturingInvocationKey = false
        isCapturingVoiceNoteSwitchKey = false
        isCapturingScreenRecordingKey = false
        isCapturingTodoSwitchKey = false
        isCapturingTodoSheetKey = false
        isCapturingChatSheetKey = false
        self.keyCaptureTarget = nil
        removeInvocationKeyCaptureMonitors()
    }

    private func setInvocationShortcut(_ shortcut: InvocationShortcut) {
        invocationShortcut = shortcut
        if let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.invocationShortcutJSON)
        }
        shortcutMonitor.setInvocationShortcut(shortcut)
    }

    private func setVoiceNoteSwitchKeyCode(_ keyCode: Int64) {
        voiceNoteSwitchKeyCode = keyCode
        UserDefaults.standard.set(Int(keyCode), forKey: DefaultsKey.voiceNoteSwitchKeyCode)
        shortcutMonitor.setVoiceNoteSwitchKeyCode(keyCode)
    }

    private func setScreenRecordingShortcut(_ shortcut: InvocationShortcut) {
        screenRecordingShortcut = shortcut
        if let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.screenRecordingShortcutJSON)
        }
        shortcutMonitor.setScreenRecordingShortcut(shortcut)
    }

    private func setTodoSheetShortcut(_ shortcut: InvocationShortcut) {
        todoSheetShortcut = shortcut
        shortcutMonitor.setTodoSheetShortcut(shortcut)
        if let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.todoSheetShortcutJSON)
        }
    }

    private func setChatSheetShortcut(_ shortcut: InvocationShortcut) {
        chatSheetShortcut = shortcut
        shortcutMonitor.setChatSheetShortcut(shortcut)
        if let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.chatSheetShortcutJSON)
        }
    }

    private func setTodoSwitchKeyCode(_ keyCode: Int64) {
        todoSwitchKeyCode = keyCode
        UserDefaults.standard.set(Int(keyCode), forKey: DefaultsKey.todoSwitchKeyCode)
        shortcutMonitor.setTodoSwitchKeyCode(keyCode)
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
