import AVFoundation
import Foundation

enum AudioCaptureError: LocalizedError {
    case microphonePermissionDenied
    case failedToStart
    case noRecording
    case snapshotFailed

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission is required to start dictation."
        case .failedToStart:
            return "Unable to start audio recording."
        case .noRecording:
            return "No recording is currently in progress."
        case .snapshotFailed:
            return "Unable to capture a live recording snapshot."
        }
    }
}

@MainActor
final class AudioCaptureService {
    struct StoppedRecording {
        let url: URL
        let duration: TimeInterval
    }

    struct RecordingSnapshot {
        let url: URL
        let duration: TimeInterval
    }

    private var recorder: AVAudioRecorder?

    var microphonePermissionGranted: Bool {
        if #available(macOS 14.0, *) {
            return AVAudioApplication.shared.recordPermission == .granted
        }

        return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    var isRecording: Bool {
        recorder?.isRecording == true
    }

    var currentRecordingDuration: TimeInterval {
        recorder?.currentTime ?? 0
    }

    func requestMicrophonePermissionIfNeeded(prompt: Bool = true) async -> Bool {
        if #available(macOS 14.0, *) {
            let permission = AVAudioApplication.shared.recordPermission
            switch permission {
            case .granted:
                return true
            case .undetermined:
                guard prompt else {
                    return false
                }
                return await withCheckedContinuation { continuation in
                    AVAudioApplication.requestRecordPermission { granted in
                        continuation.resume(returning: granted)
                    }
                }
            case .denied:
                return false
            @unknown default:
                return false
            }
        } else {
            let status = AVCaptureDevice.authorizationStatus(for: .audio)

            switch status {
            case .authorized:
                return true
            case .notDetermined:
                guard prompt else {
                    return false
                }
                return await withCheckedContinuation { continuation in
                    AVCaptureDevice.requestAccess(for: .audio) { granted in
                        continuation.resume(returning: granted)
                    }
                }
            case .denied, .restricted:
                return false
            @unknown default:
                return false
            }
        }
    }

    func startRecording() throws {
        guard microphonePermissionGranted else {
            throw AudioCaptureError.microphonePermissionDenied
        }

        if isRecording {
            return
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-recording-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
        ]

        let recorder = try AVAudioRecorder(url: outputURL, settings: settings)
        recorder.prepareToRecord()
        recorder.isMeteringEnabled = true

        guard recorder.record() else {
            throw AudioCaptureError.failedToStart
        }

        self.recorder = recorder
    }

    func stopRecording() throws -> StoppedRecording {
        guard let recorder else {
            throw AudioCaptureError.noRecording
        }

        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        return StoppedRecording(url: recorder.url, duration: duration)
    }

    func makeRecordingSnapshot() throws -> RecordingSnapshot {
        guard let recorder, recorder.isRecording else {
            throw AudioCaptureError.noRecording
        }

        let snapshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-live-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        do {
            try FileManager.default.copyItem(at: recorder.url, to: snapshotURL)
        } catch {
            throw AudioCaptureError.snapshotFailed
        }

        return RecordingSnapshot(url: snapshotURL, duration: recorder.currentTime)
    }

    func currentInputLevelNormalized() -> Double {
        guard let recorder, recorder.isRecording else {
            return 0
        }

        recorder.updateMeters()
        let averagePower = recorder.averagePower(forChannel: 0)
        let peakPower = recorder.peakPower(forChannel: 0)

        // Bias toward peaks so short syllables still drive animation.
        let effectivePower = max(averagePower, peakPower - 6)
        let normalizedDB = Double(min(max((effectivePower + 55) / 55, 0), 1))
        let curved = pow(normalizedDB, 0.72)
        return curved < 0.01 ? 0 : curved
    }
}
