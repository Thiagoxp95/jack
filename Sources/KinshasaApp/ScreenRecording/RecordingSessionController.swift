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
    private(set) var hasCameraPermission = false

    // MARK: - User-Editable Setup Config

    var sourceType: CaptureSourceType = .screen
    var selectedDisplayIndex: Int = 0
    var selectedWindowID: UInt32?
    var selectedRegion: CGRect?
    var recordMicrophone: Bool = true
    var recordSystemAudio: Bool = true
    var enableWebcam: Bool = false
    var webcamPosition: WebcamPosition = .bottomLeft
    var webcamSize: WebcamSize = .medium
    var fps: RecordingFPS = .sixty

    // MARK: - Services (private)

    private var screenService: ScreenRecordingService?
    private var cursorService: CursorTrackingService?
    private let webcamService = WebcamCaptureService()
    private let micService = MicrophoneCaptureService()

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
        hasCameraPermission = await WebcamCaptureService.requestPermission()
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
        state = .idle
        webcamService.stop()
    }

    // MARK: - Recording Lifecycle

    func startRecording() async throws {
        guard state == .setup || state == .idle else {
            throw RecordingSessionError.invalidState("Cannot start recording from state: \(state)")
        }

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
        let session = RecordingSession(
            id: sessionID,
            sessionDirectory: sessionDir,
            captureSourceType: sourceType,
            fps: fps
        )
        currentSession = session

        // Transition to countdown
        state = .countdown
        Self.logger.info("Countdown started")

        // 3-second countdown
        try await Task.sleep(nanoseconds: 3_000_000_000)

        guard state == .countdown else {
            // User may have cancelled during countdown
            return
        }

        // Start screen recording service
        let screenSvc = ScreenRecordingService(
            fps: fps,
            videoOutputURL: session.screenVideoURL,
            audioOutputURL: session.systemAudioURL
        )
        screenService = screenSvc

        // Determine capture source.
        // SCDisplay / SCWindow are not formally Sendable, but they are
        // immutable value-like objects from ScreenCaptureKit. We use
        // nonisolated(unsafe) to safely pass them across isolation boundaries.
        nonisolated(unsafe) let captureDisplay: SCDisplay?
        nonisolated(unsafe) let captureWindow: SCWindow?

        switch sourceType {
        case .screen:
            guard selectedDisplayIndex < availableDisplays.count else {
                throw RecordingSessionError.noDisplayAvailable
            }
            captureDisplay = availableDisplays[selectedDisplayIndex]
            captureWindow = nil

        case .window:
            guard let windowID = selectedWindowID,
                  let window = availableWindows.first(where: { $0.windowID == windowID })
            else {
                throw RecordingSessionError.noWindowSelected
            }
            captureDisplay = nil
            captureWindow = window

        case .region:
            guard selectedDisplayIndex < availableDisplays.count else {
                throw RecordingSessionError.noDisplayAvailable
            }
            captureDisplay = availableDisplays[selectedDisplayIndex]
            captureWindow = nil
        }

        let captureRegion = sourceType == .region ? selectedRegion : nil
        let captureSystemAudio = recordSystemAudio
        nonisolated(unsafe) let noWindows: [SCWindow] = []

        try await screenSvc.startCapture(
            display: captureDisplay,
            window: captureWindow,
            region: captureRegion,
            captureSystemAudio: captureSystemAudio,
            excludedWindows: noWindows
        )

        // Start cursor tracking
        let cursorSvc = CursorTrackingService(framerate: fps.rawValue)
        cursorService = cursorSvc
        _ = cursorSvc.start()

        // Start microphone if enabled
        if recordMicrophone {
            do {
                try micService.startRecording(to: session.micAudioURL)
            } catch {
                Self.logger.error("Failed to start microphone: \(error)")
            }
        }

        // Start webcam if enabled
        if enableWebcam, hasCameraPermission {
            do {
                try webcamService.start()
            } catch {
                Self.logger.error("Failed to start webcam: \(error)")
            }
        }

        // Transition to recording and start timer
        state = .recording
        recordingStartDate = Date()
        elapsedTime = 0
        startElapsedTimer()

        Self.logger.info("Recording started for session \(sessionID.uuidString)")
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

        // Stop screen capture
        if let screenSvc = screenService {
            await screenSvc.stopCapture()
            screenService = nil
        }

        // Stop cursor tracking and write data
        if let cursorSvc = cursorService {
            _ = await cursorSvc.stop()
            if let session = currentSession {
                do {
                    try await cursorSvc.writeToFile(url: session.cursorDataURL)
                } catch {
                    Self.logger.error("Failed to write cursor data: \(error)")
                }
            }
            cursorService = nil
        }

        // Stop microphone
        if micService.isRecording {
            _ = micService.stopRecording()
        }

        // Stop webcam
        webcamService.stop()

        // Update session duration
        currentSession?.duration = elapsedTime

        state = .editing

        Self.logger.info("Recording stopped, entering editing state")
    }

    func finishEditing() {
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
