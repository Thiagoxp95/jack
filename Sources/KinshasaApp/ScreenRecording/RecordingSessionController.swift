import AVFoundation
import Foundation
import ScreenCaptureKit
import os

// MARK: - RecordingSessionError

enum RecordingSessionError: LocalizedError {
    case screenPermissionDenied
    case noDisplayAvailable
    case noWindowSelected
    case sessionDirectoryCreationFailed
    case invalidState(String)

    var errorDescription: String? {
        switch self {
        case .screenPermissionDenied:
            return "Screen recording permission is required."
        case .noDisplayAvailable:
            return "No display is available for recording."
        case .noWindowSelected:
            return "No window has been selected for recording."
        case .sessionDirectoryCreationFailed:
            return "Failed to create session directory."
        case .invalidState(let detail):
            return "Invalid recording state: \(detail)"
        }
    }
}

// MARK: - RecordingSessionController

@Observable
@MainActor
final class RecordingSessionController {

    // MARK: - Observable State

    private(set) var state: RecordingState = .idle
    private(set) var elapsedTime: TimeInterval = 0
    private(set) var currentSession: RecordingSession?
    private(set) var availableDisplays: [SCDisplay] = []
    private(set) var availableWindows: [SCWindow] = []
    private(set) var hasScreenPermission = false

    // MARK: - User-Editable Setup Config

    var sourceType: CaptureSourceType = .screen
    var selectedDisplayIndex: Int = 0
    var selectedWindowID: UInt32?
    var selectedRegion: CGRect?
    var recordMicrophone: Bool = true
    var recordSystemAudio: Bool = true
    var recordWebcam: Bool = true
    var webcamDiameter: CGFloat = WebcamDefaults.defaultDiameter
    var fps: RecordingFPS = .sixty
    private(set) var isWebcamVisible = false

    // Device selection
    var selectedMicDeviceID: String?
    var selectedCameraDeviceID: String?

    var availableMicDevices: [AVCaptureDevice] {
        MicrophoneCaptureService.availableInputDevices
    }

    var availableCameras: [AVCaptureDevice] {
        WebcamCaptureService.availableCameras
    }

    // MARK: - Services (private)

    private var screenService: ScreenRecordingService?
    private var cursorService: CursorTrackingService?
    private let micService = MicrophoneCaptureService()
    private var webcamService: WebcamCaptureService?
    private var webcamOverlay: WebcamOverlayController?
    /// Camera session started during countdown so hardware is warm when recording begins.
    private var preWarmedWebcamService: WebcamCaptureService?

    // MARK: - UI Controllers (private)

    private let countdownOverlay = CountdownOverlayController()
    private let recordingBubble = RecordingBubbleController()
    private let editorWindow = EditorWindowController()

    // MARK: - Timer State

    private var timerTask: Task<Void, Never>?
    private var recordingStartDate: Date?

    // MARK: - Directories

    static let cacheDirectory: URL = {
        let path = ("~/Library/Caches/Actionfy/recordings" as NSString).expandingTildeInPath
        return URL(fileURLWithPath: path, isDirectory: true)
    }()

    static let exportDirectory: URL = {
        let path = ("~/Documents/Actionfy Recordings" as NSString).expandingTildeInPath
        return URL(fileURLWithPath: path, isDirectory: true)
    }()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.kinshasa",
        category: "RecordingSession"
    )

    // MARK: - Initialization

    func initialize() async {
        await refreshPermissions()
        await refreshAvailableSources()
    }

    // MARK: - Permissions

    func refreshPermissions() async {
        hasScreenPermission = await ScreenRecordingService.hasPermission()
    }

    func refreshAvailableSources() async {
        do {
            let content = try await ScreenRecordingService.availableContent()
            availableDisplays = content.displays
            availableWindows = content.windows.filter { $0.isOnScreen }
        } catch {
            Self.logger.error("Failed to refresh available sources: \(error)")
            availableDisplays = []
            availableWindows = []
        }
    }

    // MARK: - Setup

    func openSetup() async {
        state = .setup
        await refreshAvailableSources()
    }

    func cancelSetup() {
        let wasCountdown = state == .countdown
        state = .idle
        countdownOverlay.cleanup()
        cleanUpPreWarmedWebcam()
        if wasCountdown {
            recordingBubble.hide()
        }
    }

    // MARK: - Recording Lifecycle

    func startRecording() async throws {
        guard state == .setup || state == .idle else {
            throw RecordingSessionError.invalidState("Cannot start recording from state: \(state)")
        }

        Self.logger.fault("[REC-01] startRecording: creating session directory")

        // Create session directory
        let sessionID = UUID()
        let sessionDir = Self.cacheDirectory.appendingPathComponent(sessionID.uuidString)
        let fm = FileManager.default

        do {
            try fm.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        } catch {
            throw RecordingSessionError.sessionDirectoryCreationFailed
        }

        // Create session
        var session = RecordingSession(
            id: sessionID,
            sessionDirectory: sessionDir,
            captureSourceType: sourceType,
            fps: fps
        )
        currentSession = session

        // Pre-warm webcam camera hardware before countdown.
        // Camera cold-start takes 1-2s; warming it up here means the overlay
        // appears instantly after the countdown finishes.
        if recordWebcam {
            Self.logger.fault("[REC-PRE] Pre-warming webcam camera")
            await preWarmWebcam()
        }

        // Transition to countdown
        state = .countdown

        Self.logger.fault("[REC-02] startRecording: showing countdown overlay")

        // Show countdown overlay first (at .screenSaver level, above everything).
        // Hide the app AFTER the countdown finishes so the overlay is always visible.
        await countdownOverlay.show()

        // Hide only normal-level app windows (setup, main window) so they don't
        // appear in the recording. Floating panels (webcam overlay, recording
        // bubble) must stay visible — NSApp.hide(nil) would hide those too.
        for window in NSApplication.shared.windows where window.level == .normal && window.isVisible {
            window.orderOut(nil)
        }

        Self.logger.fault("[REC-03] startRecording: countdown done, app hidden")

        guard state == .countdown else {
            Self.logger.fault("[REC-XX] startRecording: cancelled during countdown")
            countdownOverlay.cleanup()
            cleanUpPreWarmedWebcam()
            return
        }

        Self.logger.fault("[REC-04] startRecording: creating ScreenRecordingService")

        // Start screen recording service
        let screenSvc = ScreenRecordingService(
            fps: fps,
            videoOutputURL: session.screenVideoURL,
            audioOutputURL: session.systemAudioURL
        )
        screenService = screenSvc

        Self.logger.fault("[REC-05] startRecording: determining capture source (\(self.sourceType.rawValue))")

        // Determine capture source
        let captureDisplay: SCDisplay?
        let captureWindow: SCWindow?

        switch sourceType {
        case .screen:
            guard selectedDisplayIndex < availableDisplays.count else {
                cleanUpPreWarmedWebcam()
                throw RecordingSessionError.noDisplayAvailable
            }
            captureDisplay = availableDisplays[selectedDisplayIndex]
            captureWindow = nil

        case .window:
            guard let windowID = selectedWindowID,
                  let window = availableWindows.first(where: { $0.windowID == windowID })
            else {
                cleanUpPreWarmedWebcam()
                throw RecordingSessionError.noWindowSelected
            }
            captureDisplay = nil
            captureWindow = window

        case .region:
            guard selectedDisplayIndex < availableDisplays.count else {
                cleanUpPreWarmedWebcam()
                throw RecordingSessionError.noDisplayAvailable
            }
            captureDisplay = availableDisplays[selectedDisplayIndex]
            captureWindow = nil
        }

        let captureRegion = sourceType == .region ? selectedRegion : nil

        // Store screen dimensions for cursor coordinate mapping
        if let region = captureRegion {
            session.screenSize = CGSize(width: region.width, height: region.height)
        } else if let display = captureDisplay {
            session.screenSize = CGSize(width: CGFloat(display.width), height: CGFloat(display.height))
        } else if let window = captureWindow {
            session.screenSize = CGSize(width: window.frame.width, height: window.frame.height)
        }
        currentSession = session

        // --- Show user-visible UI first for instant post-countdown feedback ---

        // Activate pre-warmed webcam (overlay + file recording — nearly instant)
        if recordWebcam {
            Self.logger.fault("[REC-11] startRecording: activating pre-warmed webcam")
            activateWebcam(session: session)
        }

        // Transition to recording and start timer immediately
        Self.logger.fault("[REC-12] startRecording: transitioning to recording state")
        state = .recording
        recordingStartDate = Date()
        elapsedTime = 0
        startElapsedTimer()

        // Show recording bubble
        recordingBubble.show(controller: self)

        // --- Now start backend capture services ---

        Self.logger.fault("[REC-06] startRecording: calling startCapture")

        do {
            try await screenSvc.startCapture(
                display: captureDisplay,
                window: captureWindow,
                region: captureRegion,
                captureSystemAudio: recordSystemAudio
            )
        } catch {
            Self.logger.error("[REC-ERR] Screen capture failed: \(error)")
            await tearDownAfterStartupFailure()
            throw error
        }

        Self.logger.fault("[REC-07] startRecording: screen capture started, starting cursor tracking")

        // Start cursor tracking
        let cursorSvc = CursorTrackingService(framerate: fps.rawValue)
        cursorService = cursorSvc
        _ = cursorSvc.start()

        Self.logger.fault("[REC-08] startRecording: cursor tracking started")

        // Start microphone and webcam file recording together so they are
        // time-aligned. Both start AFTER screen capture is running.
        if recordMicrophone {
            Self.logger.fault("[REC-09] startRecording: starting microphone")
            do {
                try micService.startRecording(to: session.micAudioURL)
            } catch {
                Self.logger.error("[REC-09E] Failed to start microphone: \(error)")
            }
        }

        if recordWebcam {
            Self.logger.fault("[REC-09W] startRecording: starting webcam file recording (synced with mic)")
            startWebcamFileRecording(session: session)
        }

        Self.logger.fault("[REC-13] startRecording: complete (countdown window stays hidden, cleaned up on stop)")

        Self.logger.fault("[REC-14] startRecording: all done for session \(sessionID.uuidString)")
    }

    func pauseRecording() {
        guard state == .recording else { return }

        state = .paused
        micService.pause()
        stopElapsedTimer()

        Self.logger.info("Recording paused")
    }

    func resumeRecording() {
        guard state == .paused else { return }

        state = .recording
        micService.resume()
        recordingStartDate = Date().addingTimeInterval(-elapsedTime)
        startElapsedTimer()

        Self.logger.info("Recording resumed")
    }

    func stopRecording() async {
        guard state == .recording || state == .paused else { return }

        stopElapsedTimer()

        // Hide UI overlays
        recordingBubble.hide()
        countdownOverlay.cleanup()

        // Stop screen capture
        if let screenSvc = screenService {
            await screenSvc.stopCapture()
            screenService = nil
        }

        // Stop cursor tracking, write data, and detect gesture zooms
        var detectedZoomKeyframes: [ZoomKeyframe] = []
        if let cursorSvc = cursorService {
            let cursorData = await cursorSvc.stop()
            if let session = currentSession {
                do {
                    try await cursorSvc.writeToFile(url: session.cursorDataURL)
                } catch {
                    Self.logger.error("Failed to write cursor data: \(error)")
                }
            }

            // Detect gesture-triggered zoom regions
            detectedZoomKeyframes = GestureZoomDetector.detect(events: cursorData.events)
            if !detectedZoomKeyframes.isEmpty {
                Self.logger.info("Auto-detected \(detectedZoomKeyframes.count) gesture zoom region(s)")
            }

            cursorService = nil
        }

        // Stop microphone
        if micService.isRecording {
            _ = micService.stopRecording()
        }

        // Stop webcam (awaits file finalization)
        await stopWebcam()

        // Update session duration
        currentSession?.duration = elapsedTime

        state = .editing

        // Open the video editor window
        if let session = currentSession {
            editorWindow.show(
                session: session,
                initialZoomKeyframes: detectedZoomKeyframes,
                onDone: { [weak self] in
                    self?.finishEditing()
                }
            )
        }

        Self.logger.info("Recording stopped, entering editing state")
    }

    func finishEditing() {
        // Dismiss editor window
        editorWindow.hide()

        // Ensure UI overlays are dismissed
        recordingBubble.hide()
        countdownOverlay.cleanup()

        // Clean up temp files
        if let session = currentSession {
            let fm = FileManager.default
            try? fm.removeItem(at: session.sessionDirectory)
        }

        currentSession = nil
        elapsedTime = 0
        recordingStartDate = nil
        state = .idle

        Self.logger.info("Editing finished, reset to idle")
    }

    // MARK: - Formatted Time

    var formattedElapsedTime: String {
        let totalSeconds = Int(elapsedTime)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    // MARK: - Export Directory

    static func ensureExportDirectory() throws -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: exportDirectory.path) {
            try fm.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        }
        return exportDirectory
    }

    // MARK: - Webcam

    /// Start the camera capture session so hardware is warm before the countdown finishes.
    private func preWarmWebcam() async {
        let granted = await WebcamCaptureService.requestPermission()
        guard granted else {
            Self.logger.error("[REC-PRE] Camera permission denied")
            return
        }

        let svc = WebcamCaptureService()
        do {
            try svc.start()
            preWarmedWebcamService = svc
            Self.logger.fault("[REC-PRE] Webcam camera pre-warmed")
        } catch {
            Self.logger.error("[REC-PRE] Failed to pre-warm webcam: \(error)")
        }
    }

    /// Activate webcam overlay using a pre-warmed or new service.
    /// Shows the floating circle preview immediately. File recording is
    /// started separately via ``startWebcamFileRecording(session:)`` so it
    /// can be synchronized with the microphone start.
    private func activateWebcam(session: RecordingSession) {
        let svc: WebcamCaptureService

        if let preWarmed = preWarmedWebcamService {
            svc = preWarmed
            preWarmedWebcamService = nil
            Self.logger.fault("[REC-WC] Using pre-warmed webcam service")
        } else {
            // Fallback: cold start (permission already granted from setup)
            guard WebcamCaptureService.hasPermission else {
                Self.logger.error("[REC-WC] Camera permission not granted")
                return
            }
            let newSvc = WebcamCaptureService()
            do {
                try newSvc.start()
            } catch {
                Self.logger.error("[REC-WC] Failed to cold-start webcam: \(error)")
                return
            }
            svc = newSvc
        }

        webcamService = svc

        // Show floating circle overlay (file recording started later for sync)
        let overlay = WebcamOverlayController()
        webcamOverlay = overlay
        overlay.show(service: svc, origin: nil, diameter: webcamDiameter)
        isWebcamVisible = true
    }

    /// Start writing the webcam capture session to disk.
    /// Called after screen capture begins so the file aligns with mic audio.
    private func startWebcamFileRecording(session: RecordingSession) {
        guard let svc = webcamService else { return }
        svc.startRecordingToFile(url: session.webcamVideoURL)
        Self.logger.info("Webcam file recording started (synced with mic)")
    }

    private func cleanUpPreWarmedWebcam() {
        guard let svc = preWarmedWebcamService else { return }
        preWarmedWebcamService = nil
        Task { await svc.stop() }
    }

    /// Tear down UI and services when screen capture fails after the timer/bubble were already shown.
    private func tearDownAfterStartupFailure() async {
        stopElapsedTimer()
        recordingBubble.hide()
        countdownOverlay.cleanup()

        screenService = nil
        cursorService = nil

        await stopWebcam()
        cleanUpPreWarmedWebcam()

        currentSession = nil
        elapsedTime = 0
        recordingStartDate = nil
        state = .idle
    }

    private func stopWebcam() async {
        webcamOverlay?.hide()
        webcamOverlay = nil
        if let svc = webcamService {
            await svc.stop()
            webcamService = nil
        }
        isWebcamVisible = false
    }

    /// Toggle webcam circle overlay visibility during recording.
    /// File recording continues regardless — this only controls the preview circle.
    func toggleWebcamOverlay() {
        guard let svc = webcamService else { return }
        if isWebcamVisible {
            webcamOverlay?.hide()
            isWebcamVisible = false
        } else {
            if webcamOverlay == nil {
                webcamOverlay = WebcamOverlayController()
            }
            webcamOverlay?.show(service: svc, origin: nil, diameter: webcamDiameter)
            isWebcamVisible = true
        }
    }

    // MARK: - Elapsed Timer

    private func startElapsedTimer() {
        stopElapsedTimer()

        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                guard !Task.isCancelled else { return }
                guard let self, let startDate = self.recordingStartDate else { return }
                self.elapsedTime = Date().timeIntervalSince(startDate)
            }
        }
    }

    private func stopElapsedTimer() {
        timerTask?.cancel()
        timerTask = nil
    }
}
