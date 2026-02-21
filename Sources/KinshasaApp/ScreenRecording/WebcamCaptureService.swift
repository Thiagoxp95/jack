import AppKit
import AVFoundation

// MARK: - WebcamCaptureError

enum WebcamCaptureError: LocalizedError {
    case cameraPermissionDenied
    case noCameraAvailable
    case failedToCreateInput
    case failedToAddInput
    case sessionAlreadyRunning

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
        }
    }
}

// MARK: - WebcamCaptureService

@MainActor
final class WebcamCaptureService {

    // MARK: - Properties

    private var captureSession: AVCaptureSession?
    private var _previewLayer: AVCaptureVideoPreviewLayer?

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
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
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

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill

        session.startRunning()

        self.captureSession = session
        self._previewLayer = layer
    }

    func stop() {
        captureSession?.stopRunning()
        captureSession = nil
        _previewLayer = nil
    }
}
