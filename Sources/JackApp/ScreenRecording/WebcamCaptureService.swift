import AppKit
import AVFoundation
import os

// MARK: - WebcamCaptureError

enum WebcamCaptureError: LocalizedError {
    case cameraPermissionDenied
    case noCameraAvailable
    case failedToCreateInput
    case failedToAddInput
    case sessionAlreadyRunning
    case failedToAddFileOutput

    var errorDescription: String? {
        switch self {
        case .cameraPermissionDenied:
            return "Camera permission is required to show the webcam overlay."
        case .noCameraAvailable:
            return "No camera device is available."
        case .failedToCreateInput:
            return "Unable to create camera input."
        case .failedToAddInput:
            return "Unable to add camera input to capture session."
        case .sessionAlreadyRunning:
            return "A webcam capture session is already running."
        case .failedToAddFileOutput:
            return "Unable to add file output to capture session."
        }
    }
}

// MARK: - WebcamCaptureService

@MainActor
final class WebcamCaptureService: NSObject, @unchecked Sendable {

    // MARK: - Properties

    private var captureSession: AVCaptureSession?
    private var _previewLayer: AVCaptureVideoPreviewLayer?
    private var fileOutput: AVCaptureMovieFileOutput?
    private var recordingURL: URL?
    private var isRecordingToFile = false

    /// Continuation that resolves when the delegate confirms the file is finalized.
    private var recordingFinishedContinuation: CheckedContinuation<Void, Never>?

    private nonisolated static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.jack",
        category: "WebcamCapture"
    )

    var previewLayer: AVCaptureVideoPreviewLayer? {
        _previewLayer
    }

    var isRunning: Bool {
        captureSession?.isRunning == true
    }

    // MARK: - Permissions

    static var hasPermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    /// Check permission status without prompting the user.
    static func checkPermission() async -> Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    static func requestPermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)

        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Device Discovery

    static var availableCameras: [AVCaptureDevice] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        return session.devices
    }

    // MARK: - Session Control

    func start(device: AVCaptureDevice? = nil) throws {
        guard !isRunning else {
            throw WebcamCaptureError.sessionAlreadyRunning
        }

        guard Self.hasPermission else {
            throw WebcamCaptureError.cameraPermissionDenied
        }

        let camera: AVCaptureDevice
        if let device {
            camera = device
        } else {
            guard let defaultCamera = Self.availableCameras.first else {
                throw WebcamCaptureError.noCameraAvailable
            }
            camera = defaultCamera
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: camera)
        } catch {
            throw WebcamCaptureError.failedToCreateInput
        }

        let session = AVCaptureSession()
        session.sessionPreset = .medium

        guard session.canAddInput(input) else {
            throw WebcamCaptureError.failedToAddInput
        }
        session.addInput(input)

        // Pre-add file output now so attaching it later doesn't reconfigure
        // the running session and cause the preview layer to flash/blank.
        // Recording only begins when startRecordingToFile() calls startRecording().
        let output = AVCaptureMovieFileOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            self.fileOutput = output
        }

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill

        session.startRunning()

        self.captureSession = session
        self._previewLayer = layer
    }

    /// Stop the capture session. Waits for file recording to finalize if active.
    func stop() async {
        if isRecordingToFile {
            await stopRecordingToFileAsync()
        }
        captureSession?.stopRunning()
        captureSession = nil
        _previewLayer = nil
        fileOutput = nil
    }

    // MARK: - File Recording

    func startRecordingToFile(url: URL) {
        guard !isRecordingToFile else { return }

        // File output was pre-added in start() to avoid reconfiguring the
        // running session (which causes the preview to flash).
        // Fallback: add it now if it wasn't pre-added for some reason.
        if fileOutput == nil, let session = captureSession {
            let output = AVCaptureMovieFileOutput()
            guard session.canAddOutput(output) else {
                Self.logger.error("Cannot add file output to session")
                return
            }
            session.beginConfiguration()
            session.addOutput(output)
            session.commitConfiguration()
            self.fileOutput = output
        }

        guard let output = fileOutput else { return }

        recordingURL = url
        isRecordingToFile = true
        output.startRecording(to: url, recordingDelegate: self)
        Self.logger.fault("Webcam recording started to \(url.path)")
    }

    /// Stop file recording and wait for the file to be fully written to disk.
    func stopRecordingToFileAsync() async {
        guard let output = fileOutput, isRecordingToFile else { return }

        await withCheckedContinuation { continuation in
            self.recordingFinishedContinuation = continuation
            output.stopRecording()
        }
        isRecordingToFile = false
        Self.logger.info("Webcam recording stopped and file finalized")
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension WebcamCaptureService: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: (any Error)?
    ) {
        if let error {
            Self.logger.error("Webcam recording error: \(error)")
        } else {
            Self.logger.info("Webcam recording saved to \(outputFileURL.path)")
        }

        // Resume the continuation so stop() can return
        Task { @MainActor in
            self.recordingFinishedContinuation?.resume()
            self.recordingFinishedContinuation = nil
        }
    }
}
