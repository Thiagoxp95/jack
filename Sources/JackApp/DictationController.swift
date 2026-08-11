import ApplicationServices
import AppKit
import FluidAudio
import Foundation
import JackKnowledgeKit
import os.log
import ServiceManagement
import UniformTypeIdentifiers
import UserNotifications

private let slackLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Jack", category: "slackMute")

@inline(__always)
private func runOnMainActorImmediatelyIfPossible(_ operation: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated {
            operation()
        }
    } else {
        // Use DispatchQueue.main directly instead of Task { @MainActor in }
        // to avoid Swift concurrency cooperative scheduling overhead which
        // can add perceptible latency when waking from throttled states.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                operation()
            }
        }
    }
}

enum TranscriptionModelChoice: String, CaseIterable, Identifiable {
    case parakeetV2 = "parakeet-v2"
    case parakeetV3 = "parakeet-v3"
    case aquaVoice = "aqua-voice"
    case gpt4oMiniTranscribe = "gpt-4o-mini-transcribe"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .parakeetV2: return "Parakeet v2 (English)"
        case .parakeetV3: return "Parakeet v3 (Multilingual)"
        case .aquaVoice: return "AquaVoice Avalon (English)"
        case .gpt4oMiniTranscribe: return "GPT-4o Mini Transcribe"
        }
    }

    var subtitle: String {
        switch self {
        case .parakeetV2: return "Optimized for English-only transcription"
        case .parakeetV3: return "Supports multiple languages"
        case .aquaVoice: return "Cloud-based · Optimized for dictation · Low latency"
        case .gpt4oMiniTranscribe: return "Cloud-based · Requires internet · High accuracy"
        }
    }

    var isLocal: Bool {
        switch self {
        case .parakeetV2, .parakeetV3: return true
        case .aquaVoice, .gpt4oMiniTranscribe: return false
        }
    }

    var modelIdentifier: String {
        switch self {
        case .parakeetV2: return "FluidInference/parakeet-tdt-0.6b-v2-coreml"
        case .parakeetV3: return "FluidInference/parakeet-tdt-0.6b-v3-coreml"
        case .aquaVoice: return "avalon-v1-en"
        case .gpt4oMiniTranscribe: return "gpt-4o-mini-transcribe"
        }
    }
}

@MainActor
final class DictationController: ObservableObject {
    static let defaultWordReplacements: [WordReplacement] = [
        WordReplacement(original: "cloud code", replacement: "Claude Code"),
        WordReplacement(original: "cloudcode", replacement: "Claude Code"),
        WordReplacement(original: "clode code", replacement: "Claude Code"),
        WordReplacement(original: "claw code", replacement: "Claude Code"),
        WordReplacement(original: "clawed code", replacement: "Claude Code"),
        WordReplacement(original: "klaudcode", replacement: "Claude Code"),
        WordReplacement(original: "claudcode", replacement: "Claude Code"),
        WordReplacement(original: "codecs", replacement: "Codex"),
        WordReplacement(original: "co decks", replacement: "Codex"),
        WordReplacement(original: "codec", replacement: "Codex"),
        WordReplacement(original: "super base", replacement: "Supabase"),
        WordReplacement(original: "superbase", replacement: "Supabase"),
        WordReplacement(original: "versa cell", replacement: "Vercel"),
        WordReplacement(original: "versa sell", replacement: "Vercel"),
        WordReplacement(original: "next js", replacement: "Next.js"),
        WordReplacement(original: "next.js", replacement: "Next.js"),
        WordReplacement(original: "tail wind", replacement: "Tailwind CSS"),
        WordReplacement(original: "chat GPT", replacement: "ChatGPT"),
        WordReplacement(original: "fire base", replacement: "Firebase"),
        WordReplacement(original: "git hub", replacement: "GitHub"),
        WordReplacement(original: "open AI", replacement: "OpenAI"),
        WordReplacement(original: "type script", replacement: "TypeScript"),
        WordReplacement(original: "java script", replacement: "JavaScript"),
        WordReplacement(original: "post gress", replacement: "PostgreSQL"),
        WordReplacement(original: "postgres", replacement: "PostgreSQL"),
        WordReplacement(original: "wind surf", replacement: "Windsurf"),
    ]

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
    @Published private(set) var screenshotKeyCode: Int64
    @Published private(set) var todoSheetShortcut: InvocationShortcut?
    @Published private(set) var chatSheetShortcut: InvocationShortcut?
    @Published private(set) var todoSwitchKeyCode: Int64
    @Published var isCapturingInvocationKey = false
    @Published var isCapturingScreenshotKey = false
    @Published var isCapturingTodoSwitchKey = false
    @Published var isCapturingTodoSheetKey = false
    @Published var isCapturingChatSheetKey = false
    @Published private(set) var aiSwitchKeyCode: Int64
    @Published var isCapturingAiSwitchKey = false
    @Published var postActionPillEnabled: Bool {
        didSet {
            UserDefaults.standard.set(postActionPillEnabled, forKey: DefaultsKey.postActionPillEnabled)
            if !postActionPillEnabled {
                dismissPostActionPill()
            }
        }
    }
    @Published private(set) var postActionAiKeyCode: Int64
    @Published private(set) var postActionTodoKeyCode: Int64
    /// Last routing decision, surfaced in settings.
    @Published private(set) var lastIntentVerdictSummary: String?
    @Published var statusText: String
    @Published var lastTranscript: String
    @Published private(set) var isStartingRecording = false
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var isPreparingModel = false
    @Published var isDownloadingModel = false
    @Published var modelDownloadProgress: Double = 0.0
    @Published var modelDownloadError: String?
    /// Title of the model currently downloading, so settings can name it.
    @Published private(set) var downloadingModelTitle: String?
    /// "212 MB of 483 MB" for the current download, nil when idle.
    @Published private(set) var modelDownloadByteSummary: String?
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
    @Published private(set) var recordingOutputMode: RecordingOutputMode = .paste
    @Published private(set) var lastTodoSavedAt: Date?
    @Published var selectedTranscriptionModel: TranscriptionModelChoice {
        didSet {
            UserDefaults.standard.set(selectedTranscriptionModel.rawValue, forKey: DefaultsKey.transcriptionModel)
            if oldValue != selectedTranscriptionModel {
                parakeetPreparationTask?.cancel()
                parakeetPreparationTask = nil
                modelDownloadError = nil
                modelDownloadProgress = modelsAlreadyDownloaded(for: selectedTranscriptionModel) ? 1.0 : 0.0
                if selectedTranscriptionModel.isLocal {
                    parakeetConfiguration = nil
                    _ = startParakeetPreparationIfNeeded(showReadyStatus: true)
                } else {
                    parakeetConfiguration = nil
                    statusText = "Ready. Press \(invocationKeyDisplayName) globally (\(mode.title))."
                }
            }
        }
    }
    @Published var cleanupEnabled: Bool {
        didSet {
            UserDefaults.standard.set(cleanupEnabled, forKey: DefaultsKey.cleanupEnabled)
        }
    }
    @Published var cleanupPrompt: String {
        didSet {
            UserDefaults.standard.set(cleanupPrompt, forKey: DefaultsKey.cleanupPrompt)
        }
    }
    /// Everything LLM-shaped in Jack runs through OpenRouter with the user's
    /// own key — no Jack-operated backend sits in the path.
    ///
    /// Stored in the login keychain, not `UserDefaults`: the plist is readable
    /// by any process running as the user, and a key that lives in a defaults
    /// key is a key a stray paste can overwrite. See `KeychainStore`.
    @Published var openRouterApiKey: String {
        didSet {
            guard openRouterApiKey != oldValue else { return }
            KeychainStore.write(openRouterApiKey, account: KeychainStore.openRouterAPIKeyAccount)
            // A new key deserves a fresh verdict — leaving a stale 401 on screen
            // after the user has just fixed it is how a banner loses its meaning.
            // Guarded: this `didSet` runs on every keystroke in the Settings
            // field, i.e. from inside a SwiftUI view update, and publishing a
            // no-op change from there is what produces "Publishing changes from
            // within view updates" at runtime.
            if openRouterAuthFailure != nil { openRouterAuthFailure = nil }
        }
    }
    /// Set when OpenRouter rejects the key outright (401/403). This exists
    /// because the router's failure mode is *silence*: `IntentClassifier` falls
    /// back to plain dictation on any error, so a dead key downgrades Jack to
    /// "everything pastes" with nothing on screen to say why.
    @Published private(set) var openRouterAuthFailure: String?
    @Published var cleanupModelId: String {
        didSet {
            UserDefaults.standard.set(cleanupModelId, forKey: DefaultsKey.cleanupModelId)
        }
    }
    @Published var routingModelId: String {
        didSet {
            UserDefaults.standard.set(routingModelId, forKey: DefaultsKey.routingModelId)
        }
    }
    /// OpenRouter's catalog, loaded on demand for the model pickers.
    @Published private(set) var openRouterModels: [OpenRouterModelInfo] = []
    @Published private(set) var isLoadingOpenRouterModels = false
    @Published private(set) var openRouterModelsError: String?
    @Published var mouseDictationEnabled: Bool {
        didSet {
            UserDefaults.standard.set(mouseDictationEnabled, forKey: DefaultsKey.mouseDictationEnabled)
            if mouseDictationEnabled {
                mouseDictationMonitor.start()
            } else {
                mouseDictationMonitor.stop()
            }
        }
    }

    private var initialized = false
    private var interpreter: ShortcutInterpreter
    private let shortcutMonitor = GlobalFnShortcutMonitor()
    private let mouseDictationMonitor = MouseDictationMonitor()
    private let audioCapture = AudioCaptureService()
    private let transcription = ParakeetTranscriptionService()
    private let pasteService = PasteService()
    private let noteService = NoteService()
    let knowledgeService = KnowledgeService()
    private let noteScreenshot = NoteScreenshotController()
    /// Screenshots captured during the current note-mode recording, attached to
    /// the note once the transcript lands.
    private var pendingNoteScreenshots: [URL] = []
    /// OCR text for those screenshots, kept so auto mode can show the judge
    /// what was on screen (the routing model gets text, never image parts).
    private var pendingNoteScreenshotOCR: [String] = []
    private let intentClassifier = IntentClassifier()
    private let todoTextParser = TodoTextParser()
    /// Frontmost app + window title captured when auto mode was engaged.
    private var routingAppMetadata: (app: String?, window: String?)?
    private let duckingService = SystemAudioDuckingService()
    private let slackMuteService = SlackMuteService()
    private let bubble = FloatingBubbleController()
    private let postActionPill = PostActionPillController()
    /// Transcript + paste bookkeeping held while the post-action split pill is
    /// on screen. `pastedCharacterCount` is nil when nothing was auto-pasted.
    private var pendingPostAction: (text: String, pastedCharacterCount: Int?)?
    private let todoConfirmation = TodoConfirmationController()
    var spaceController: SpaceController? {
        didSet { syncSpaceAppearance() }
    }
    private let bootstrapper = LocalParakeetBootstrapper()
    private let modelDownloader = ParakeetModelDownloader()
    /// Keeps the blocked pill's percentage live while it is on screen.
    private var blockedPillHideTask: Task<Void, Never>?
    private var parakeetConfiguration: ParakeetConfiguration?
    private var parakeetPreparationTask: Task<Bool, Never>?
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
        static let screenshotKeyCode = "voice_note_switch_key_code"
        static let todoSwitchKeyCode = "todo_switch_key_code"
        static let aiSwitchKeyCode = "ai_switch_key_code"
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
        static let cleanupEnabled = "transcription_cleanup_enabled"
        static let cleanupPrompt = "transcription_cleanup_prompt"
        static let cleanupDefaultsMigratedV3 = "transcription_cleanup_defaults_migrated_v3"
        static let openRouterApiKey = "openrouter_api_key"
        static let cleanupModelId = "openrouter_cleanup_model_id"
        static let routingModelId = "openrouter_routing_model_id"
        static let mouseDictationEnabled = "mouse_dictation_enabled"
        static let postActionPillEnabled = "post_action_pill_enabled"
        static let postActionAiKeyCode = "post_action_ai_key_code"
        static let postActionTodoKeyCode = "post_action_todo_key_code"
    }

    private enum KeyCaptureTarget {
        case invocation
        case screenshotKey
        case todoSwitch
        case todoSheet
        case chatSheet
        case aiSwitch
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
            || defaults.object(forKey: DefaultsKey.screenshotKeyCode) != nil
        let hasAllRequiredPermissions = accessibilityGranted && keyboardMonitoringGranted && microphoneGranted
        return hasLegacyConfig || hasAllRequiredPermissions
    }

    init() {
        let defaults = UserDefaults.standard
        let initialAccessibilityGranted = AXIsProcessTrusted()
        let initialKeyboardMonitoringGranted = CGPreflightListenEventAccess()
        let initialMicrophoneGranted = audioCapture.microphonePermissionGranted

        let initialMode = ShortcutMode(rawValue: defaults.string(forKey: DefaultsKey.mode) ?? "") ?? .hold

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

        let initialScreenshotKeyCode: Int64
        if let stored = defaults.object(forKey: DefaultsKey.screenshotKeyCode) as? Int {
            initialScreenshotKeyCode = Int64(stored)
        } else {
            initialScreenshotKeyCode = 45 // N
        }

        let initialTodoSwitchKeyCode: Int64
        if let stored = defaults.object(forKey: DefaultsKey.todoSwitchKeyCode) as? Int {
            initialTodoSwitchKeyCode = Int64(stored)
        } else {
            initialTodoSwitchKeyCode = 17 // T key
        }

        let initialAiSwitchKeyCode: Int64
        if let stored = defaults.object(forKey: DefaultsKey.aiSwitchKeyCode) as? Int {
            initialAiSwitchKeyCode = Int64(stored)
        } else {
            initialAiSwitchKeyCode = 0 // A key default
        }

        let initialTodoSheetShortcut: InvocationShortcut?
        if let jsonData = defaults.data(forKey: DefaultsKey.todoSheetShortcutJSON),
           let decoded = try? JSONDecoder().decode(InvocationShortcut.self, from: jsonData) {
            initialTodoSheetShortcut = decoded
            NSLog("[Jack] Loaded todo sheet shortcut from defaults: primaryKeyCode=\(String(describing: decoded.primaryKeyCode)) modifiers=\(decoded.modifiers) display=\(decoded.displayName)")
        } else {
            // Default: ⌥T (Option+T)
            initialTodoSheetShortcut = InvocationShortcut(primaryKeyCode: 17, modifiers: NSEvent.ModifierFlags.option.rawValue)
            NSLog("[Jack] Using default todo sheet shortcut: ⌥T")
        }

        let initialChatSheetShortcut: InvocationShortcut?
        if let jsonData = defaults.data(forKey: DefaultsKey.chatSheetShortcutJSON),
           let decoded = try? JSONDecoder().decode(InvocationShortcut.self, from: jsonData) {
            initialChatSheetShortcut = decoded
        } else {
            // Default: ⌥L (Option+L)
            initialChatSheetShortcut = InvocationShortcut(primaryKeyCode: 37, modifiers: NSEvent.ModifierFlags.option.rawValue)
        }

        mode = initialMode
        // Infer shortcut type from existing shortcut if not persisted
        if let storedType = ShortcutType(rawValue: defaults.string(forKey: DefaultsKey.shortcutType) ?? "") {
            shortcutType = storedType
        } else {
            shortcutType = initialInvocationShortcut.isSingleKey || initialInvocationShortcut.isModifierOnly ? .singleKey : .combination
        }
        invocationShortcut = initialInvocationShortcut
        screenshotKeyCode = initialScreenshotKeyCode
        todoSwitchKeyCode = initialTodoSwitchKeyCode
        aiSwitchKeyCode = initialAiSwitchKeyCode
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
            wordReplacements = Self.defaultWordReplacements
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

        cleanupEnabled = defaults.object(forKey: DefaultsKey.cleanupEnabled) as? Bool ?? true

        // The key moved from UserDefaults to the keychain. Migrate a legacy
        // value once, but only if it still looks like a key: an earlier build
        // let a dictation land in the focused Settings field and overwrite the
        // key with the transcript, so the legacy slot may hold a sentence.
        // Migrating that would carry the corruption forward. Either way the
        // plaintext copy is removed — that is the point of the move.
        let legacyKey = defaults.string(forKey: DefaultsKey.openRouterApiKey)
        let keychainKey = KeychainStore.read(account: KeychainStore.openRouterAPIKeyAccount)
        switch OpenRouterKeyMigration.plan(keychainValue: keychainKey, legacyValue: legacyKey) {
        case .keychainWins:
            openRouterApiKey = keychainKey ?? ""
        case let .migrate(value):
            KeychainStore.write(value, account: KeychainStore.openRouterAPIKeyAccount)
            openRouterApiKey = value
            NSLog("[Jack] Moved OpenRouter key from UserDefaults to the keychain.")
        case .discard:
            openRouterApiKey = ""
            if legacyKey?.isEmpty == false {
                NSLog("[Jack] Discarded a corrupted OpenRouter key from UserDefaults; re-enter it in Settings.")
            }
        }
        defaults.removeObject(forKey: DefaultsKey.openRouterApiKey)

        // One-time move to the hardened cleanup prompt + Gemini 3.1 Flash Lite.
        // Only untouched settings are migrated: a stored prompt that still
        // matches a prompt Jack shipped, and a model that was a Jack default.
        // Runs once, so a later deliberate choice is never overwritten.
        let needsCleanupMigration = !defaults.bool(forKey: DefaultsKey.cleanupDefaultsMigratedV3)

        let storedPrompt = defaults.string(forKey: DefaultsKey.cleanupPrompt)
        let resolvedPrompt: String
        if let storedPrompt, !(needsCleanupMigration && legacyCleanupPrompts.contains(storedPrompt)) {
            resolvedPrompt = storedPrompt
        } else {
            resolvedPrompt = defaultCleanupPrompt
        }
        cleanupPrompt = resolvedPrompt

        let storedCleanupModel = defaults.string(forKey: DefaultsKey.cleanupModelId)
        let cleanupModelIsStale = storedCleanupModel.map {
            OpenRouterClient.retiredDefaults.contains($0)
                || (needsCleanupMigration && OpenRouterClient.supersededCleanupDefaults.contains($0))
        } ?? true
        let resolvedCleanupModel = cleanupModelIsStale
            ? OpenRouterClient.defaultCleanupModel
            : storedCleanupModel!
        cleanupModelId = resolvedCleanupModel

        if needsCleanupMigration {
            // `didSet` does not fire for assignments made inside `init`, so the
            // migrated values live only in memory unless written by hand — and
            // the flag below would then mark the migration done while the stale
            // values sat on disk, reverting them on the next launch. The locals
            // are written rather than the properties: reading `self` here is
            // illegal before every stored property is initialized.
            defaults.set(resolvedPrompt, forKey: DefaultsKey.cleanupPrompt)
            defaults.set(resolvedCleanupModel, forKey: DefaultsKey.cleanupModelId)
            defaults.set(true, forKey: DefaultsKey.cleanupDefaultsMigratedV3)
        }

        let storedRoutingModel = defaults.string(forKey: DefaultsKey.routingModelId)
        routingModelId = (storedRoutingModel.map(OpenRouterClient.retiredDefaults.contains) ?? true)
            ? OpenRouterClient.defaultRoutingModel
            : storedRoutingModel!
        mouseDictationEnabled = defaults.object(forKey: DefaultsKey.mouseDictationEnabled) as? Bool ?? false
        postActionPillEnabled = defaults.object(forKey: DefaultsKey.postActionPillEnabled) as? Bool ?? true
        postActionAiKeyCode = defaults.object(forKey: DefaultsKey.postActionAiKeyCode) as? Int64 ?? 0 // A
        postActionTodoKeyCode = defaults.object(forKey: DefaultsKey.postActionTodoKeyCode) as? Int64 ?? 2 // D

        accessibilityGranted = initialAccessibilityGranted
        keyboardMonitoringGranted = initialKeyboardMonitoringGranted
        microphoneGranted = initialMicrophoneGranted
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            notificationsGranted = settings.authorizationStatus == .authorized
        }
        shortcutMonitor.setInvocationShortcut(initialInvocationShortcut)
        shortcutMonitor.setScreenshotKeyCode(initialScreenshotKeyCode)
        shortcutMonitor.setTodoSwitchKeyCode(initialTodoSwitchKeyCode)
        shortcutMonitor.setAiSwitchKeyCode(initialAiSwitchKeyCode)
        shortcutMonitor.setPostActionKeyCodes([postActionAiKeyCode, postActionTodoKeyCode])
        shortcutMonitor.escapeToCancelEnabled = escapeToCancelEnabled

        if defaults.object(forKey: DefaultsKey.onboardingCompleted) == nil, inferredOnboardingCompleted {
            defaults.set(true, forKey: DefaultsKey.onboardingCompleted)
        }

        shortcutMonitor.onEvent = { [weak self] event in
            guard let self else { return }
            runOnMainActorImmediatelyIfPossible {
                self.handleShortcutEvent(event)
            }
        }
        mouseDictationMonitor.onEvent = { [weak self] event in
            guard let self else { return }
            runOnMainActorImmediatelyIfPossible {
                self.handleMouseDictationEvent(event)
            }
        }
        shortcutMonitor.onScreenshotKeyPressed = { [weak self] in
            guard let self else { return }
            runOnMainActorImmediatelyIfPossible {
                self.toggleScreenshotOverlay()
            }
        }
        shortcutMonitor.onTodoSwitchKeyPressed = { [weak self] in
            guard let self else { return }
            runOnMainActorImmediatelyIfPossible {
                self.setTodoMode()
            }
        }
        shortcutMonitor.onAiSwitchKeyPressed = { [weak self] in
            guard let self else { return }
            runOnMainActorImmediatelyIfPossible {
                self.setAiChatMode()
            }
        }
        shortcutMonitor.onSpaceCycleKeyPressed = { [weak self] direction in
            guard let self else { return }
            runOnMainActorImmediatelyIfPossible {
                self.cycleSpace(direction: direction)
            }
        }
        if let initialTodoSheetShortcut = todoSheetShortcut {
            shortcutMonitor.setTodoSheetShortcut(initialTodoSheetShortcut)
        }
        shortcutMonitor.onTodoSheetKeyPressed = { [weak self] in
            guard let self else { return }
            runOnMainActorImmediatelyIfPossible {
                self.handleTodoSheetShortcut()
            }
        }
        if let initialChatSheetShortcut = chatSheetShortcut {
            shortcutMonitor.setChatSheetShortcut(initialChatSheetShortcut)
        }
        shortcutMonitor.onChatSheetKeyPressed = { [weak self] in
            guard let self else { return }
            runOnMainActorImmediatelyIfPossible {
                self.handleChatSheetShortcut()
            }
        }
        shortcutMonitor.onPostActionKeyPressed = { [weak self] index in
            guard let self else { return }
            runOnMainActorImmediatelyIfPossible {
                guard let action = PostDictationAction(rawValue: index) else { return }
                self.handlePostAction(action)
            }
        }
        shortcutMonitor.onPostActionDismissRequested = { [weak self] in
            guard let self else { return }
            runOnMainActorImmediatelyIfPossible {
                self.dismissPostActionPill()
            }
        }
        shortcutMonitor.onEscapePressed = { [weak self] in
            guard let self else { return }
            runOnMainActorImmediatelyIfPossible {
                // ESC first dismisses the note-screenshot overlay; only a second
                // ESC (or ESC outside note mode) cancels the recording.
                if self.noteScreenshot.isVisible {
                    self.noteScreenshot.hide()
                } else {
                    self.cancelRecording()
                }
            }
        }

        noteScreenshot.attachmentsDirectoryProvider = { [noteService] in
            try noteService.attachmentsDirectoryURL()
        }
        noteScreenshot.onCapture = { [weak self] fileURL, ocrText in
            guard let self else { return }
            self.pendingNoteScreenshots.append(fileURL)
            self.showBubble(message: "Screenshot attached", isRecording: self.isRecording)
            // OCR text joins the knowledge base alongside the spoken note.
            let trimmedOCR = ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedOCR.isEmpty {
                self.pendingNoteScreenshotOCR.append(trimmedOCR)
                let knowledge = self.knowledgeService
                Task.detached(priority: .utility) {
                    _ = await knowledge.ingest(
                        text: trimmedOCR,
                        source: .screenshotOCR,
                        imagePath: fileURL.path
                    )
                }
            }
        }

        bubble.setPresentation(position: floatingIndicatorPosition, sizePercent: floatingIndicatorSizePercent)
    }

    func initialize() async {
        guard !initialized else {
            return
        }

        initialized = true
        bubble.prepareForImmediatePresentation()
        let shortcutStarted = await refreshPermissions(prompt: false)
        audioCapture.prepareForNextRecordingIfPossible()
        configureKeepModelWarmLoop()

        if selectedTranscriptionModel.isLocal {
            _ = startParakeetPreparationIfNeeded(showReadyStatus: shortcutStarted)
        } else {
            statusText = "Ready. Press \(invocationKeyDisplayName) globally (\(mode.title))."
        }

        bootstrapKnowledgeBase()
    }

    /// One-time migration of pre-existing notes into the knowledge base, then
    /// embed any backlog. Runs off the main actor; failures are non-fatal.
    private func bootstrapKnowledgeBase() {
        let knowledge = knowledgeService
        let existingNotes = noteService.loadAllNotes()
        Task.detached(priority: .utility) {
            let storeDirectory = knowledge.store.directoryURL
            let markerURL = storeDirectory.appendingPathComponent(".migrated")
            if !FileManager.default.fileExists(atPath: markerURL.path) {
                try? FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
                for note in existingNotes {
                    _ = await knowledge.ingest(
                        text: note.text,
                        source: .note,
                        date: note.date,
                        dayStamp: note.dayStamp
                    )
                }
                try? Data().write(to: markerURL)
                if !existingNotes.isEmpty {
                    NSLog("[Jack] Knowledge base: migrated %d existing notes", existingNotes.count)
                }
            }
            let embedded = await knowledge.backfillMissingEmbeddings()
            if embedded > 0 {
                NSLog("[Jack] Knowledge base: backfilled %d embeddings", embedded)
            }
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

    func requestMicrophoneOnly() async -> Bool {
        microphoneGranted = await audioCapture.requestMicrophonePermissionIfNeeded(prompt: true)
        return microphoneGranted
    }

    func startFromUI() {
        beginRecording()
    }

    func stopFromUI() {
        stopRecordingAndTranscribe()
    }

    func toggleFromUI() {
        if isRecording {
            stopRecordingAndTranscribe()
        } else {
            beginRecording()
        }
    }

    var invocationKeyDisplayName: String {
        invocationShortcut.displayName
    }

    var allRequiredPermissionsGranted: Bool {
        accessibilityGranted && keyboardMonitoringGranted && microphoneGranted
    }

    var screenshotKeyDisplayName: String {
        InvocationKey.displayName(for: screenshotKeyCode)
    }

    var todoSwitchKeyDisplayName: String {
        InvocationKey.displayName(for: todoSwitchKeyCode)
    }

    var aiSwitchKeyDisplayName: String {
        InvocationKey.displayName(for: aiSwitchKeyCode)
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

    func applyTodoSheetShortcut(_ shortcut: InvocationShortcut) {
        setTodoSheetShortcut(shortcut)
        statusText = "Todo sheet shortcut set to \(todoSheetKeyDisplayName)."
    }

    func applyChatSheetShortcut(_ shortcut: InvocationShortcut) {
        setChatSheetShortcut(shortcut)
        statusText = "Chat sheet shortcut set to \(chatSheetKeyDisplayName)."
    }

    func startInvocationKeyCapture() {
        guard !isCapturingInvocationKey, !isCapturingScreenshotKey, !isCapturingTodoSwitchKey, !isCapturingTodoSheetKey, !isCapturingChatSheetKey, !isCapturingAiSwitchKey else {
            return
        }

        keyCaptureTarget = .invocation
        isCapturingInvocationKey = true
        isCapturingScreenshotKey = false
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

    func startScreenshotKeyCapture() {
        guard !isCapturingInvocationKey, !isCapturingScreenshotKey, !isCapturingTodoSwitchKey, !isCapturingTodoSheetKey, !isCapturingChatSheetKey, !isCapturingAiSwitchKey else {
            return
        }

        keyCaptureTarget = .screenshotKey
        isCapturingInvocationKey = false
        isCapturingScreenshotKey = true
        statusText = "Press the key to toggle the screenshot overlay while recording."
        installInvocationKeyCaptureMonitors()
    }

    func cancelScreenshotKeyCapture() {
        guard isCapturingScreenshotKey else {
            return
        }

        isCapturingScreenshotKey = false
        keyCaptureTarget = nil
        removeInvocationKeyCaptureMonitors()
        statusText = "Screenshot key capture canceled."
    }

    func startTodoSwitchKeyCapture() {
        guard !isCapturingInvocationKey, !isCapturingScreenshotKey, !isCapturingTodoSwitchKey, !isCapturingTodoSheetKey, !isCapturingChatSheetKey, !isCapturingAiSwitchKey else {
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

    func startAiSwitchKeyCapture() {
        guard !isCapturingInvocationKey, !isCapturingScreenshotKey, !isCapturingTodoSwitchKey, !isCapturingTodoSheetKey, !isCapturingChatSheetKey, !isCapturingAiSwitchKey else {
            return
        }

        keyCaptureTarget = .aiSwitch
        isCapturingAiSwitchKey = true
        statusText = "Press the key to switch to AI mode while recording."
        installInvocationKeyCaptureMonitors()
    }

    func cancelAiSwitchKeyCapture() {
        guard isCapturingAiSwitchKey else {
            return
        }

        isCapturingAiSwitchKey = false
        keyCaptureTarget = nil
        removeInvocationKeyCaptureMonitors()
        statusText = "AI key capture canceled."
    }

    func startTodoSheetKeyCapture() {
        guard !isCapturingInvocationKey, !isCapturingScreenshotKey, !isCapturingTodoSwitchKey, !isCapturingTodoSheetKey, !isCapturingChatSheetKey, !isCapturingAiSwitchKey else {
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

    func clearTodoSheetKey() {
        todoSheetShortcut = nil
        shortcutMonitor.setTodoSheetShortcut(nil)
        UserDefaults.standard.removeObject(forKey: DefaultsKey.todoSheetShortcutJSON)
    }

    func startChatSheetKeyCapture() {
        guard !isCapturingInvocationKey, !isCapturingScreenshotKey, !isCapturingTodoSwitchKey, !isCapturingTodoSheetKey, !isCapturingChatSheetKey, !isCapturingAiSwitchKey else {
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
        parakeetPreparationTask?.cancel()
        parakeetPreparationTask = nil
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
        guard !isCapturingInvocationKey, !isCapturingScreenshotKey, !isCapturingTodoSwitchKey, !isCapturingTodoSheetKey, !isCapturingChatSheetKey, !isCapturingAiSwitchKey else {
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
                beginRecording()
            }
        case .startRecording:
            pendingHoldStopTask?.cancel()
            pendingHoldStopTask = nil
            holdRecordingStartedAt = .now
            wantRecording = true
            beginRecording()
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
            isStartingRecording = false
            shortcutMonitor.setRecordingControlsActive(false)
            if isRecording {
                stopRecordingAndTranscribe()
            } else {
                hideBubbleUnlessDownloadBlocked()
            }
            // If beginRecording() is still in its async setup, the wantRecording
            // flag being false will cause it to stop immediately after starting.
        }
    }

    /// Mouse dictation always uses hold semantics: both buttons down → start,
    /// either button released → stop.
    private func handleMouseDictationEvent(_ event: ShortcutEvent) {
        guard !isCapturingInvocationKey, !isCapturingScreenshotKey, !isCapturingTodoSwitchKey, !isCapturingTodoSheetKey, !isCapturingChatSheetKey, !isCapturingAiSwitchKey else {
            return
        }

        lastShortcutEventAt = .now

        switch event {
        case .down:
            guard !isRecording, !isTranscribing else { return }
            wantRecording = true
            beginRecording()
        case .up:
            wantRecording = false
            isStartingRecording = false
            shortcutMonitor.setRecordingControlsActive(false)
            if isRecording {
                stopRecordingAndTranscribe()
            } else {
                hideBubbleUnlessDownloadBlocked()
            }
        }
    }

    private func handleTodoSheetShortcut() {
        guard !isCapturingInvocationKey, !isCapturingScreenshotKey, !isCapturingTodoSwitchKey, !isCapturingTodoSheetKey, !isCapturingChatSheetKey, !isCapturingAiSwitchKey else {
            return
        }
        TodoSideSheetController.shared.toggle()
    }

    private func handleChatSheetShortcut() {
        guard !isCapturingInvocationKey, !isCapturingScreenshotKey, !isCapturingTodoSwitchKey, !isCapturingTodoSheetKey, !isCapturingChatSheetKey, !isCapturingAiSwitchKey else {
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

    private func setTodoMode() {
        guard isRecording, !isTranscribing else {
            return
        }
        recordingOutputMode = recordingOutputMode == .todo ? .paste : .todo
        statusText = listeningStatusText(isLive: false)
        showBubble(message: listeningBubbleMessage(), isRecording: true)
    }

    private func setAiChatMode() {
        guard isRecording, !isTranscribing else {
            return
        }
        recordingOutputMode = recordingOutputMode == .aiChat ? .paste : .aiChat
        statusText = listeningStatusText(isLive: false)
        showBubble(message: listeningBubbleMessage(), isRecording: true)
    }

    /// The screenshot crosshair covers the screen while toggled on during a
    /// recording; captures land in the knowledge base and feed the router.
    private func toggleScreenshotOverlay() {
        guard isRecording, !isTranscribing else {
            return
        }
        if noteScreenshot.isVisible {
            noteScreenshot.hide()
        } else {
            noteScreenshot.show()
        }
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
        case .todo:
            return "Listening (Todo Mode)..."
        case .aiChat:
            return "Listening (AI Mode)..."
        }
    }

    private func listeningStatusText(isLive: Bool) -> String {
        switch (recordingOutputMode, isLive) {
        case (.paste, false):
            return "Listening..."
        case (.paste, true):
            return "Listening... (live)"
        case (.todo, false):
            return "Listening... (todo mode)"
        case (.todo, true):
            return "Listening... (todo mode, live)"
        case (.aiChat, false):
            return "Listening... (AI mode)"
        case (.aiChat, true):
            return "Listening... (AI mode, live)"
        }
    }

    private func beginRecording() {
        holdDebugLog("beginRecording: START isRecording=\(isRecording) isTranscribing=\(isTranscribing) wantRecording=\(wantRecording)")

        // A new dictation supersedes any lingering post-action split pill.
        dismissPostActionPill()

        guard !isStartingRecording, !isRecording, !isTranscribing else {
            holdDebugLog("beginRecording: BAIL isStartingRecording=\(isStartingRecording) isRecording=\(isRecording) isTranscribing=\(isTranscribing)")
            return
        }

        // Local model still downloading: refuse the dictation and show the
        // blocked pill with the live percentage instead of a dead recording.
        if selectedTranscriptionModel.isLocal, !modelsAlreadyDownloaded(for: selectedTranscriptionModel) {
            presentModelDownloadBlockedPill()
            return
        }

        isStartingRecording = true
        let useLocalModel = selectedTranscriptionModel.isLocal
        let parakeetTask = useLocalModel ? startParakeetPreparationIfNeeded(showReadyStatus: true) : nil

        // Fast path: when microphone permission is already granted (the common
        // case), skip the intermediate "Starting..." bubble and go straight to
        // finishBeginRecording which shows the pill in active recording state.
        if microphoneGranted || audioCapture.microphonePermissionGranted {
            microphoneGranted = true
            finishBeginRecording(useLocalModel: useLocalModel, parakeetTask: parakeetTask)
            return
        }

        // Slow path: need to request permission — show interim pill.
        statusText = "Starting dictation..."
        showBubble(RecordingPresentationState.starting())
        Task(priority: .userInitiated) { @MainActor [weak self] in
            await self?.continueBeginRecording(useLocalModel: useLocalModel, parakeetTask: parakeetTask)
        }
    }

    /// Blocked pill: 🚫 where the space icon sits, download percentage where
    /// the voice meter sits. Stays up briefly, tracking the live percentage.
    private func presentModelDownloadBlockedPill() {
        let choice = selectedTranscriptionModel
        wantRecording = false
        shortcutMonitor.setRecordingControlsActive(false)

        // Make sure something is actually pulling bytes, so the number moves.
        _ = startParakeetPreparationIfNeeded(showReadyStatus: true)

        let percent = Int((modelDownloadProgress * 100).rounded(.down))
        statusText = "\(choice.title) is still downloading — \(percent)%."

        bubbleHideTask?.cancel()
        blockedPillHideTask?.cancel()
        bubble.showDownloadBlocked(percent: percent)

        blockedPillHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, let self, self.bubble.isShowingDownloadBlocked else { return }
            self.bubble.hide()
        }
    }

    /// The blocked pill outlives a key release — hiding it there would flash it
    /// away before the percentage could be read.
    private func hideBubbleUnlessDownloadBlocked() {
        guard !bubble.isShowingDownloadBlocked else { return }
        bubble.hide()
    }

    private func continueBeginRecording(useLocalModel: Bool, parakeetTask: Task<Bool, Never>?) async {
        microphoneGranted = await audioCapture.requestMicrophonePermissionIfNeeded(prompt: true)
        finishBeginRecording(useLocalModel: useLocalModel, parakeetTask: parakeetTask)
    }

    private func finishBeginRecording(useLocalModel: Bool, parakeetTask: Task<Bool, Never>?) {
        defer {
            if !isRecording {
                isStartingRecording = false
            }
        }

        guard microphoneGranted else {
            bubble.hide()
            handleError("Microphone permission is required.")
            return
        }

        // A stop request may have arrived while we were awaiting async setup.
        guard wantRecording else {
            holdDebugLog("beginRecording: BAIL wantRecording=false (stop arrived during setup)")
            bubble.hide()
            shortcutMonitor.setRecordingControlsActive(false)
            return
        }

        do {
            try audioCapture.startRecording()
            holdDebugLog("beginRecording: audio started, setting isRecording=true")
            isStartingRecording = false
            isRecording = true
            recordingOutputMode = .paste
            // Snapshot where the user is *while speaking* — by the time the
            // transcript lands they may have switched apps. The router uses it.
            routingAppMetadata = IntentContext.currentAppMetadata()

            // Show the pill as early as possible — before sounds, haptics,
            // and other non-critical setup that can run after the visual appears.
            statusText = listeningStatusText(isLive: false)
            showBubble(message: listeningBubbleMessage(), isRecording: true)

            shortcutMonitor.setRecordingControlsActive(true)
            playSoundEffect()
            performHaptic()
            latestLiveTranscription = nil
            liveTranscriptionInFlight = false
            liveSnapshotInFlightDuration = nil
            startHoldReleaseWatchdogIfNeeded()

            // Double-check: a stop may have arrived between startRecording and now.
            guard wantRecording else {
                stopRecordingAndTranscribe()
                return
            }
            startRiveReactiveLoopIfNeeded()
            applyDuckingIfNeeded()
            muteSlackIfNeeded()
            if useLocalModel {
                if let configuration = parakeetConfiguration {
                    startLiveTranscriptionLoop(configuration: configuration)
                } else if let parakeetTask {
                    Task(priority: .userInitiated) { @MainActor [weak self] in
                        guard let self else {
                            return
                        }
                        let ready = await parakeetTask.value
                        guard ready,
                              self.isRecording,
                              !self.isTranscribing,
                              self.liveTranscriptionLoopTask == nil,
                              let configuration = self.parakeetConfiguration
                        else {
                            return
                        }
                        self.startLiveTranscriptionLoop(configuration: configuration)
                    }
                }
            }
        } catch {
            bubble.hide()
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
        isStartingRecording = false
        isRecording = false
        shortcutMonitor.setRecordingControlsActive(false)
        noteScreenshot.hide() // pendingNoteScreenshots stay: their OCR feeds the router
        playSoundEffect()
        performHaptic()
        duckingService.restoreIfNeeded()
        let slackService = slackMuteService
        slackService.queue.async {
            slackService.restoreIfNeeded()
        }

        let useLocalModel = selectedTranscriptionModel.isLocal

        do {
            let stoppedRecording = try audioCapture.stopRecording()
            let recordedFile = stoppedRecording.url
            let finalDuration = stoppedRecording.duration

            isTranscribing = true
            stopLiveTranscriptionLoop()
            stopHoldReleaseWatchdog()
            stopRiveReactiveLoop(resetInputs: true)
            statusText = "Transcribing..."
            // The pill stays on screen through transcription so it can break
            // apart into the A/S/D droplets the moment the transcript lands.
            showBubble(.transcribing(outputMode: recordingOutputMode))

            if useLocalModel {
                Task(priority: .userInitiated) { @MainActor [weak self] in
                    guard let self else {
                        try? FileManager.default.removeItem(at: recordedFile)
                        return
                    }
                    let ready = await self.startParakeetPreparationIfNeeded(showReadyStatus: false).value
                    guard ready, let configuration = self.parakeetConfiguration else {
                        self.isTranscribing = false
                        self.recordingOutputMode = .paste
                        try? FileManager.default.removeItem(at: recordedFile)
                        return
                    }
                    self.transcribeLocally(recordedFile: recordedFile, finalDuration: finalDuration, configuration: configuration)
                }
            } else {
                let provider: String
                switch selectedTranscriptionModel {
                case .aquaVoice: provider = "aquavoice"
                default: provider = "openai"
                }
                transcribeViaCloud(recordedFile: recordedFile, model: selectedTranscriptionModel.modelIdentifier, provider: provider)
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
        isStartingRecording = false
        isRecording = false
        shortcutMonitor.setRecordingControlsActive(false)
        duckingService.restoreIfNeeded()
        let slackService = slackMuteService
        slackService.queue.async {
            slackService.restoreIfNeeded()
        }
        _ = try? audioCapture.stopRecording() // Discard audio
        stopLiveTranscriptionLoop()
        stopHoldReleaseWatchdog()
        stopRiveReactiveLoop(resetInputs: true)
        noteScreenshot.hide()
        clearPendingNoteScreenshots()
        recordingOutputMode = .paste
        routingAppMetadata = nil
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

        let shouldUpdateStatus = !isRecording && !isTranscribing && !isStartingRecording
        isPreparingModel = true

        defer {
            isPreparingModel = false
        }

        // Fetch the weights ourselves first so the switch reports real bytes;
        // FluidAudio then finds them cached and goes straight to compiling.
        let choice = selectedTranscriptionModel
        if choice.isLocal, !modelsAlreadyDownloaded(for: choice) {
            do {
                try await downloadModel(for: choice, updatesStatus: shouldUpdateStatus)
            } catch is CancellationError {
                return false
            } catch {
                handleError("Could not download \(choice.title). \(error.localizedDescription)")
                return false
            }
        }

        if shouldUpdateStatus {
            statusText = "Preparing local CoreML speech model (first run may take a minute)..."
        }

        do {
            let configuration = try await bootstrapper.ensureReady(model: parakeetModel)
            if shouldUpdateStatus {
                statusText = "Warming speech engine..."
            }
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

    @discardableResult
    private func startParakeetPreparationIfNeeded(showReadyStatus: Bool) -> Task<Bool, Never> {
        if let existingTask = parakeetPreparationTask {
            return existingTask
        }

        let task = Task(priority: .userInitiated) { @MainActor [weak self] in
            guard let self else {
                return false
            }
            let result = await self.prepareParakeetIfNeeded(showReadyStatus: showReadyStatus)
            self.parakeetPreparationTask = nil
            return result
        }
        parakeetPreparationTask = task
        return task
    }

    func modelsAlreadyDownloaded(for choice: TranscriptionModelChoice) -> Bool {
        guard choice.isLocal else { return true }
        let version = Self.asrVersion(for: choice)
        let cacheDir = AsrModels.defaultCacheDirectory(for: version)
        return AsrModels.modelsExist(at: cacheDir, version: version)
    }

    private static func asrVersion(for choice: TranscriptionModelChoice) -> AsrModelVersion {
        choice == .parakeetV3 ? .v3 : .v2
    }

    /// Pulls the weights for `choice`, publishing byte-accurate progress.
    private func downloadModel(for choice: TranscriptionModelChoice, updatesStatus: Bool) async throws {
        let version = Self.asrVersion(for: choice)

        isDownloadingModel = true
        modelDownloadError = nil
        modelDownloadProgress = 0
        modelDownloadByteSummary = nil
        downloadingModelTitle = choice.title

        defer {
            isDownloadingModel = false
            downloadingModelTitle = nil
            modelDownloadByteSummary = nil
        }

        if updatesStatus {
            statusText = "Downloading \(choice.title)... 0%"
        }

        do {
            try await modelDownloader.download(version: version) { [weak self] progress in
                Task { @MainActor in
                    self?.applyModelDownloadProgress(progress, choice: choice, updatesStatus: updatesStatus)
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            modelDownloadError = error.localizedDescription
            throw error
        }

        modelDownloadProgress = 1.0
        if updatesStatus {
            statusText = "Downloaded \(choice.title). Preparing..."
        }
    }

    private func applyModelDownloadProgress(
        _ progress: ParakeetDownloadProgress,
        choice: TranscriptionModelChoice,
        updatesStatus: Bool
    ) {
        guard isDownloadingModel else { return }

        modelDownloadProgress = progress.fraction
        modelDownloadByteSummary = progress.byteSummary

        if updatesStatus, !isRecording, !isTranscribing {
            statusText = "Downloading \(choice.title)... \(progress.percent)% (\(progress.byteSummary))"
        }

        bubble.updateDownloadBlocked(percent: progress.percent)
    }

    func downloadModelForOnboarding() {
        let choice = selectedTranscriptionModel
        guard choice.isLocal, !modelsAlreadyDownloaded(for: choice) else {
            modelDownloadProgress = 1.0
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.downloadModel(for: choice, updatesStatus: false)
                // Compiling happens on first use; onboarding warms it here so
                // the first dictation isn't the one that pays for it.
                _ = await self.prepareParakeetIfNeeded(showReadyStatus: false)
            } catch {
                // downloadModel already published the message.
            }
        }
    }

    private func transcribeLocally(recordedFile: URL, finalDuration: TimeInterval, configuration: ParakeetConfiguration) {
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
                    }
                    await handleTranscriptionResult(reusedLive.text)
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
                    }
                    await handleTranscriptionResult(reusedLive.text)
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
                        }
                        await handleTranscriptionResult(stitchedText)
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
                }
                await handleTranscriptionResult(result.text)
            } catch {
                await MainActor.run {
                    isTranscribing = false
                    recordingOutputMode = .paste
                    statusText = "No speech detected."
                    bubble.hide()
                }
            }
        }
    }

    private func transcribeViaCloud(recordedFile: URL, model: String, provider: String = "openai") {
        Task(priority: .userInitiated) {
            let startedAt = Date()
            defer {
                try? FileManager.default.removeItem(at: recordedFile)
            }

            do {
                let audioData = try Data(contentsOf: recordedFile)
                let base64Audio = audioData.base64EncodedString()
                let token = try await ConvexHTTPClient.getToken()

                let action: String
                var args: [String: Any] = ["audioBase64": base64Audio]
                switch provider {
                case "aquavoice":
                    action = "transcription:transcribeAquaVoice"
                    args["model"] = model
                default:
                    action = "transcription:transcribe"
                    args["model"] = model
                }

                let result = try await ConvexHTTPClient.action(
                    function: action,
                    args: args,
                    token: token
                )

                let totalLatency = Date().timeIntervalSince(startedAt)
                let text = (result as? String) ?? ""

                await MainActor.run {
                    logPipelineTiming(
                        String(
                            format: "stop->cloud total=%.3fs backend=%@",
                            totalLatency,
                            model
                        )
                    )
                    lastTranscriptionLatency = totalLatency
                    lastTranscriptionBackend = model
                }
                await handleTranscriptionResult(text)
            } catch {
                await MainActor.run {
                    isTranscribing = false
                    recordingOutputMode = .paste
                    statusText = "Cloud transcription failed: \(error.localizedDescription)"
                    bubble.hide()
                }
            }
        }
    }

    private func handleTranscriptionResult(_ text: String) async {
        isTranscribing = false

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Screenshots without speech already landed in the knowledge base
            // (they're ingested at capture time), so there's nothing left to do.
            if !pendingNoteScreenshots.isEmpty {
                statusText = "Screenshots saved to knowledge base."
                clearPendingNoteScreenshots()
            } else {
                statusText = "No speech detected."
            }
            recordingOutputMode = .paste
            bubble.hide()
            return
        }

        let cleaned = wordReplacements.isEmpty ? trimmed : WordReplacementEngine.apply(wordReplacements, to: trimmed)

        var finalText = cleaned
        if cleanupEnabled, !cleanupPrompt.isEmpty {
            guard !openRouterApiKey.isEmpty else {
                NSLog("[Jack] Cleanup skipped: no OpenRouter API key configured")
                lastTranscript = finalText
                return
            }
            NSLog("[Jack] Cleanup enabled, calling OpenRouter with model=%@", cleanupModelId)
            do {
                let result = try await callCleanupDirect(
                    text: cleaned,
                    prompt: cleanupPrompt,
                    model: cleanupModelId,
                    apiKey: openRouterApiKey
                )
                NSLog("[Jack] Cleanup returned %d chars: %@", result.count, String(result.prefix(200)))
                if !result.isEmpty {
                    finalText = result
                }
            } catch {
                NSLog("[Jack] Transcription cleanup failed: %@", String(describing: error))
            }
        }
        lastTranscript = finalText

        // Default dictations run through the router: the model decides whether
        // this was a todo, a question for the AI, or plain dictation. Manual
        // modes (T/A during recording) skip the router entirely. The routed
        // destination is resolved before anything is stored, so the knowledge
        // entry carries the source the user actually got.
        var effectiveMode = recordingOutputMode
        var routedByClassifier = false
        if recordingOutputMode == .paste, !openRouterApiKey.isEmpty {
            statusText = "Routing..."
            showBubble(message: "Deciding...", isRecording: false, isTranscribing: true)
            let verdict = await classifyIntent(transcript: finalText)
            lastIntentVerdictSummary = String(
                format: "%@ · %.0f%% · %@ · %@",
                verdict.intent.rawValue,
                verdict.confidence * 100,
                verdict.backend,
                verdict.reason.isEmpty ? "no reason given" : verdict.reason
            )
            NSLog("[Jack] Router → %@ (%@)", verdict.intent.rawValue, lastIntentVerdictSummary ?? "")
            // A rejected key means the router is dead for every capture from
            // here on, not just this one. Say so once rather than degrading to
            // paste in silence — the silent version of this bug ran for hours
            // before anyone noticed the todos had stopped arriving.
            openRouterAuthFailure = verdict.authFailure
            if let authFailure = verdict.authFailure {
                showBubble(message: "\(authFailure) — pasted instead", isRecording: false)
            }
            // Diverting away from paste is the disruptive outcome; only do it
            // when the model is sure. Anything shaky stays plain dictation.
            if verdict.confidence >= 0.6 {
                switch verdict.intent {
                case .todo:
                    effectiveMode = .todo
                    routedByClassifier = true
                case .question:
                    effectiveMode = .aiChat
                    routedByClassifier = true
                case .dictation:
                    break
                }
            }
        }

        // Everything the user says goes into the local knowledge base,
        // regardless of destination. Fire-and-forget: never on the paste hot path.
        let knowledgeSource: KnowledgeSource
        switch effectiveMode {
        case .paste: knowledgeSource = .paste
        case .todo: knowledgeSource = .todo
        case .aiChat: knowledgeSource = .chat
        }
        let knowledge = knowledgeService
        let transcriptForKnowledge = finalText
        Task.detached(priority: .utility) {
            _ = await knowledge.ingest(text: transcriptForKnowledge, source: knowledgeSource)
        }

        switch effectiveMode {
        case .paste:
            let pasteStartedAt = Date()
            let didPaste: Bool
            // Sampled once: pasting takes long enough for the user to switch
            // apps, and re-reading this below would let the status line claim a
            // missing Accessibility grant for a paste we deliberately withheld.
            let jackWasFrontmost = Self.isJackFrontmost()
            if jackWasFrontmost {
                // Jack's own windows are never a paste target. Settings is full
                // of fields that write straight through on every keystroke, and
                // one of them holds the OpenRouter key — a dictation that landed
                // there replaced the key with the transcript and silently killed
                // the router until someone read the plist. The text is still on
                // the clipboard and still in the knowledge base; only the
                // keystroke injection is suppressed.
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(finalText, forType: .string)
                didPaste = false
                NSLog("[Jack] Suppressed paste into Jack's own window; copied instead.")
            } else if autoCopyToClipboard {
                didPaste = pasteService.copyAndPaste(finalText)
            } else {
                didPaste = pasteService.pasteWithoutCopying(finalText)
            }
            let pasteLatency = Date().timeIntervalSince(pasteStartedAt)
            logPipelineTiming(
                String(
                    format: "paste latency=%.3fs chars=%d success=%@",
                    pasteLatency,
                    finalText.count,
                    didPaste ? "yes" : "no"
                )
            )

            if didPaste {
                statusText = "Transcribed and pasted."
            } else if jackWasFrontmost {
                statusText = "Copied — Jack doesn't paste into its own window."
            } else {
                statusText = "Transcribed and copied. Grant Accessibility for auto-paste."
            }
            clearPendingNoteScreenshots()
            // The pill has been sitting there since the recording stopped: it
            // either splits into the reroute droplets or just goes away. Never
            // re-show it as a transient bubble.
            if postActionPillEnabled {
                presentPostActionPill(
                    text: finalText,
                    pastedCharacterCount: didPaste ? finalText.count : nil
                )
            } else {
                bubble.hide()
            }
        case .todo:
            statusText = routedByClassifier ? "Routed → Todo. Creating..." : "Creating todo..."
            // Screenshots are already on disk and indexed in the knowledge
            // base with their OCR text.
            clearPendingNoteScreenshots()
            Task { await createLocalTodo(text: finalText) }
            bubble.hide()
        case .aiChat:
            statusText = routedByClassifier ? "Routed → AI. Sending..." : "Sending to AI..."
            ChatSideSheetController.shared.openWithMessage(finalText)
            clearPendingNoteScreenshots()
            bubble.hide()
        }

        recordingOutputMode = .paste
        routingAppMetadata = nil
    }

    // MARK: - Post-dictation action pill

    /// After a paste-mode transcript lands, the pill splits into AI/Note/Todo
    /// boxes so the capture can be rerouted with one keypress (default A/S/D).
    private func presentPostActionPill(text: String, pastedCharacterCount: Int?) {
        pendingPostAction = (text, pastedCharacterCount)
        shortcutMonitor.setPostActionKeyCodes([postActionAiKeyCode, postActionTodoKeyCode])
        shortcutMonitor.setPostActionArmed(true)

        // Hand the pill's silhouette over to the split panel: fade its glyphs,
        // let the split take over the same rect, then drop the pill itself.
        let originFrame = bubble.pillScreenFrame
        bubble.fadeContentForSplit(duration: PostActionPillController.handoffFadeDuration)

        postActionPill.show(
            originPillFrame: originFrame,
            keyLabels: [
                .aiChat: InvocationKey.displayName(for: postActionAiKeyCode),
                .todo: InvocationKey.displayName(for: postActionTodoKeyCode),
            ],
            onSplitStarted: { [weak self] in
                self?.bubble.hide()
            },
            onAction: { [weak self] action in
                self?.handlePostAction(action)
            },
            onDismiss: { [weak self] in
                self?.dismissPostActionPill()
            }
        )
    }

    private func dismissPostActionPill() {
        guard postActionPill.isVisible || pendingPostAction != nil else { return }
        shortcutMonitor.setPostActionArmed(false)
        postActionPill.hide()
        pendingPostAction = nil
    }

    private func handlePostAction(_ action: PostDictationAction) {
        guard let pending = pendingPostAction else {
            dismissPostActionPill()
            return
        }
        shortcutMonitor.setPostActionArmed(false)
        postActionPill.hide()
        pendingPostAction = nil

        // The transcript was auto-pasted into whatever input had focus, but the
        // reroute means it was never meant to stay there — erase it first.
        if let pastedCount = pending.pastedCharacterCount {
            pasteService.deleteBackward(count: pastedCount)
        }

        let text = pending.text
        switch action {
        case .aiChat:
            statusText = "Sending to AI..."
            ChatSideSheetController.shared.openWithMessage(text)
        case .todo:
            statusText = "Creating todo..."
            Task { await createLocalTodo(text: text) }
        }
    }

    /// Is Jack itself the app that would receive a synthesized ⌘V?
    ///
    /// Pasting into our own UI is never what the user meant — the dictation
    /// shortcut is global, so Settings, the chat sheet and the todo sheet are
    /// all reachable while recording, and every text field in them is bound to
    /// a `@Published` that persists on each keystroke.
    static func isJackFrontmost() -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return false }
        if let bundleID = Bundle.main.bundleIdentifier, let frontID = frontmost.bundleIdentifier {
            return bundleID == frontID
        }
        // A build with no bundle id (running from the command line) still knows
        // its own pid, which is the identity that actually matters here.
        return frontmost.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    /// Ask the routing model where this capture should land: todo, question, or
    /// plain dictation.
    private func classifyIntent(transcript: String) async -> IntentVerdict {
        let metadata = routingAppMetadata ?? IntentContext.currentAppMetadata()
        let context = IntentContext(
            transcript: transcript,
            screenshotOCR: pendingNoteScreenshotOCR,
            frontmostApp: metadata.app,
            windowTitle: metadata.window,
            spaceName: spaceController?.activeSpace.name,
            capturedAt: .now
        )

        return await intentClassifier.classify(
            context,
            model: routingModelId,
            apiKey: openRouterApiKey
        )
    }

    /// Load OpenRouter's catalog for the model pickers.
    func refreshOpenRouterModels() async {
        guard !isLoadingOpenRouterModels else { return }
        isLoadingOpenRouterModels = true
        openRouterModelsError = nil
        do {
            openRouterModels = try await OpenRouterClient.fetchModels(apiKey: openRouterApiKey)
        } catch {
            openRouterModelsError = error.localizedDescription
            NSLog("[Jack] Failed to load OpenRouter models: %@", String(describing: error))
        }
        isLoadingOpenRouterModels = false
    }

    /// Human-readable label for a model id, falling back to the raw id when the
    /// catalog hasn't loaded.
    func displayName(forModelId id: String) -> String {
        openRouterModels.first { $0.id == id }?.name ?? id
    }

    private func clearPendingNoteScreenshots() {
        pendingNoteScreenshots = []
        pendingNoteScreenshotOCR = []
    }

    /// Transcription cleanup via OpenRouter, straight from this Mac.
    private nonisolated func callCleanupDirect(
        text: String,
        prompt: String,
        model: String,
        apiKey: String
    ) async throws -> String {
        // The reminder after the transcript is the highest-value part of this
        // message: it is the last thing the model reads, so a question at the
        // end of the dictation no longer looks like the newest instruction.
        let content = try await OpenRouterClient.complete(
            model: model,
            messages: [
                .system(prompt),
                .user("""
                <transcript>
                \(text)
                </transcript>

                Return the cleaned transcript. Do not respond to its content.
                """),
            ],
            apiKey: apiKey,
            maxTokens: max(256, text.count / 2),
            timeout: 10
        )

        // Defense in depth: strip any <think>...</think> blocks that slipped through
        // (e.g., provider ignored /no_think). If a <think> is unclosed, thinking was
        // truncated mid-thought — return empty so the caller falls back to the original.
        let stripped = Self.stripThinkBlocks(content).trimmingCharacters(in: .whitespacesAndNewlines)

        // Last line of defence, no model involved: cleanup rewrites the same
        // words, so the result must still look like the input. A model that
        // answered the transcript instead of cleaning it ("I am Google Gemini")
        // shares almost nothing with it — drop it and paste the raw transcript
        // rather than something the user never said.
        guard Self.resemblesCleanup(of: text, candidate: stripped) else {
            NSLog("[Jack] Cleanup output rejected — too little overlap with the transcript: %@", String(stripped.prefix(120)))
            return ""
        }
        return stripped
    }

    /// True when `candidate` plausibly is `original` cleaned up rather than a
    /// reply to it. Compares words rather than characters, and tolerates the
    /// substitutions cleanup is supposed to make (cloud code → Claude Code) by
    /// allowing an edit-distance budget that scales with word length.
    nonisolated static func resemblesCleanup(of original: String, candidate: String) -> Bool {
        let originalWords = normalizedWords(original)
        let candidateWords = normalizedWords(candidate)

        // Nothing to compare against, or a result short enough that the overlap
        // ratio is noise. `isEmpty` handling upstream already covers the rest.
        guard originalWords.count >= 3, candidateWords.count >= 3 else { return true }

        let matched = candidateWords.filter { word in
            originalWords.contains { editDistance($0, word) <= distanceBudget(for: word) }
        }
        return Double(matched.count) / Double(candidateWords.count) >= 0.5
    }

    private nonisolated static func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// Short words need an exact match — at distance 2, "am" would match "are".
    private nonisolated static func distanceBudget(for word: String) -> Int {
        switch word.count {
        case ...3: return 0
        case 4...5: return 1
        default: return 2
        }
    }

    private nonisolated static func editDistance(_ a: String, _ b: String) -> Int {
        if a == b { return 0 }
        let a = Array(a), b = Array(b)
        // Budgets never exceed 2, so anything further apart in length can't match.
        if abs(a.count - b.count) > 2 { return .max }
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var previous = Array(0...b.count)
        var current = previous
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1]
                    ? previous[j - 1]
                    : min(previous[j - 1], previous[j], current[j - 1]) + 1
            }
            previous = current
        }
        return previous[b.count]
    }

    /// Removes `<think>...</think>` reasoning blocks emitted by Qwen3 and other
    /// thinking models. Returns empty string if an unclosed `<think>` is found
    /// (indicates the response was truncated mid-reasoning).
    nonisolated static func stripThinkBlocks(_ content: String) -> String {
        var result = content
        while let startRange = result.range(of: "<think>") {
            guard let endRange = result.range(
                of: "</think>",
                range: startRange.upperBound..<result.endIndex
            ) else {
                // Unclosed <think> — reasoning was truncated, no final answer exists.
                return ""
            }
            result.removeSubrange(startRange.lowerBound..<endRange.upperBound)
        }
        return result
    }

    private func handleError(_ message: String) {
        isStartingRecording = false
        if !isRecording {
            pendingHoldStopTask?.cancel()
            pendingHoldStopTask = nil
            stopHoldReleaseWatchdog()
            stopRiveReactiveLoop(resetInputs: true)
            shortcutMonitor.setRecordingControlsActive(false)
            recordingOutputMode = .paste
        }
        // Always restore ducking and Slack mute as a safety net, regardless of recording state.
        // restoreIfNeeded() is idempotent (no-op when nothing was changed).
        duckingService.restoreIfNeeded()
        let slackService = slackMuteService
        slackService.queue.async {
            slackService.restoreIfNeeded()
        }
        statusText = message
        showTransientBubble(message: "Error", duration: 1.6)
    }

    /// Structure a dictated todo and write it to the local store.
    private func createLocalTodo(text: String) async {
        let spaceId = spaceController?.currentSpaceId

        let parsed = await todoTextParser.parse(
            rawText: text,
            model: routingModelId,
            apiKey: openRouterApiKey
        )

        var listId: String?
        if let listName = parsed.listName {
            listId = await LocalTodoStore.shared.resolveListID(named: listName, spaceId: spaceId)
        }

        let todo = TodoItem(
            id: LocalTodoStore.newID(),
            title: parsed.title,
            description: parsed.description,
            status: "todo",
            priority: parsed.priority,
            listId: listId,
            tags: parsed.tags,
            dueDate: parsed.dueDate,
            dueTime: parsed.dueTime,
            completedAt: nil,
            rawTranscription: text,
            createdAt: Date().timeIntervalSince1970 * 1000,
            spaceId: spaceId,
            reminders: parsed.reminderTimes.isEmpty
                ? nil
                : parsed.reminderTimes.map { TodoReminder(at: $0, delivered: false) }
        )

        await LocalTodoStore.shared.insert(todo)
        lastTodoSavedAt = Date()

        showTodoConfirmation(CreatedTodoInfo(
            id: todo.id,
            title: todo.title,
            description: todo.description,
            dueDate: todo.dueDate,
            dueTime: todo.dueTime,
            priority: todo.priority,
            tags: todo.tags,
            reminderCount: todo.reminders?.count ?? 0,
            listName: parsed.listName
        ))

        // Any todo surface already on screen is showing a stale list now.
        await TodoListController.shared.fetchTodos(spaceId: spaceId)

        statusText = "Todo created."
    }

    private func showTodoConfirmation(_ todo: CreatedTodoInfo) {
        todoConfirmation.onSave = { [weak self] todo, updates in
            await self?.saveTodoEdit(todoId: todo.id, updates: updates)
        }
        todoConfirmation.show(todo: todo)
    }

    private nonisolated func saveTodoEdit(todoId: String, updates: TodoEditUpdates) async {
        var fields: [String: Any] = [
            "title": updates.title,
            "priority": updates.priority,
        ]
        if let dueDate = updates.dueDate { fields["dueDate"] = dueDate }
        if let dueTime = updates.dueTime { fields["dueTime"] = dueTime }
        if let tags = updates.tags { fields["tags"] = tags }

        nonisolated(unsafe) let sendableFields = fields
        await LocalTodoStore.shared.update(id: todoId, fields: sendableFields)
        await MainActor.run { lastTodoSavedAt = Date() }
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
        service.queue.async {
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
            showBubble(RecordingPresentationState.transcribing())
            return
        }

        if isStartingRecording {
            showBubble(RecordingPresentationState.starting())
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

        if isStartingRecording {
            showBubble(RecordingPresentationState.starting())
            return
        }

        if isRecording {
            showBubble(message: listeningBubbleMessage(), isRecording: true)
            return
        }

        if isTranscribing {
            showBubble(RecordingPresentationState.transcribing())
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
            usesActiveAppearance: true,
            isNoteMode: false,
            isAiMode: false,
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
        let presentation = RecordingPresentationState(
            message: message,
            isRecording: isRecording,
            isTranscribing: isTranscribing,
            usesActiveAppearance: isRecording || isTranscribing,
            isNoteMode: false,
            isTodoMode: isRecording && recordingOutputMode == .todo,
            isAiMode: isRecording && recordingOutputMode == .aiChat
        )
        showBubble(presentation)
    }

    private func showBubble(_ presentation: RecordingPresentationState) {
        syncSpaceAppearance()
        indicatorPreviewHideTask?.cancel()
        indicatorPreviewHideTask = nil
        bubbleHideTask?.cancel()
        bubble.show(
            message: presentation.message,
            isRecording: presentation.isRecording,
            isTranscribing: presentation.isTranscribing,
            usesActiveAppearance: presentation.usesActiveAppearance,
            isNoteMode: presentation.isNoteMode,
            isTodoMode: presentation.isTodoMode,
            isAiMode: presentation.isAiMode,
            riveAssetPath: riveAssetPathIfEnabled(forRecordingState: presentation.isRecording),
            htmlIndicatorMarkup: (presentation.isRecording || presentation.isTranscribing) ? preferredCustomSVGMarkup() : nil,
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
            usesActiveAppearance: false,
            isNoteMode: false,
            isAiMode: false,
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

        // Single-key mode: accept any key immediately, no modifier accumulation.
        // Used for invocation (when singleKey mode) and all switch key targets.
        let isSingleKeyCapture = (keyCaptureTarget == .invocation && shortcutType == .singleKey)
            || keyCaptureTarget == .screenshotKey
            || keyCaptureTarget == .todoSwitch
            || keyCaptureTarget == .aiSwitch
        if isSingleKeyCapture {
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
        // Switch keys accept any single key (no modifier required), so skip
        // the isValid check which requires modifiers for regular keys.
        let isSwitchKeyTarget = target == .screenshotKey || target == .todoSwitch || target == .aiSwitch
        if !isSwitchKeyTarget {
            guard shortcut.isValid else {
                statusText = "Invalid shortcut. Try again."
                return
            }
        }

        captureAccumulatedModifiers = []
        captureDebounceTimer?.invalidate()
        captureDebounceTimer = nil

        switch target {
        case .invocation:
            setInvocationShortcut(shortcut)
            statusText = "Invocation key set to \(invocationKeyDisplayName)."
        case .screenshotKey:
            if let primaryKey = shortcut.primaryKeyCode, shortcut.modifiers == 0 {
                setScreenshotKeyCode(primaryKey)
                statusText = "Screenshot key set to \(screenshotKeyDisplayName)."
            } else {
                statusText = "Screenshot key must be a single key."
                return
            }
        case .todoSwitch:
            if let primaryKey = shortcut.primaryKeyCode, shortcut.modifiers == 0 {
                setTodoSwitchKeyCode(primaryKey)
                statusText = "Todo key set to \(todoSwitchKeyDisplayName)."
            } else {
                statusText = "Todo key must be a single key."
                return
            }
        case .aiSwitch:
            if let primaryKey = shortcut.primaryKeyCode, shortcut.modifiers == 0 {
                setAiSwitchKeyCode(primaryKey)
                statusText = "AI key set to \(aiSwitchKeyDisplayName)."
            } else {
                statusText = "AI key must be a single key."
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
        isCapturingScreenshotKey = false
        isCapturingTodoSwitchKey = false
        isCapturingTodoSheetKey = false
        isCapturingChatSheetKey = false
        isCapturingAiSwitchKey = false
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

    private func setScreenshotKeyCode(_ keyCode: Int64) {
        screenshotKeyCode = keyCode
        UserDefaults.standard.set(Int(keyCode), forKey: DefaultsKey.screenshotKeyCode)
        shortcutMonitor.setScreenshotKeyCode(keyCode)
    }

    private func setTodoSheetShortcut(_ shortcut: InvocationShortcut) {
        NSLog("[Jack] setTodoSheetShortcut: primaryKeyCode=\(String(describing: shortcut.primaryKeyCode)) modifiers=\(shortcut.modifiers) display=\(shortcut.displayName)")
        todoSheetShortcut = shortcut
        shortcutMonitor.setTodoSheetShortcut(shortcut)
        if let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.todoSheetShortcutJSON)
        } else {
            NSLog("[Jack] WARNING: Failed to encode todo sheet shortcut")
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

    private func setAiSwitchKeyCode(_ keyCode: Int64) {
        aiSwitchKeyCode = keyCode
        UserDefaults.standard.set(Int(keyCode), forKey: DefaultsKey.aiSwitchKeyCode)
        shortcutMonitor.setAiSwitchKeyCode(keyCode)
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

        if mouseDictationEnabled {
            mouseDictationMonitor.start()
        }

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
