import AVFoundation
import Foundation

// MARK: - MicrophoneCaptureError

enum MicrophoneCaptureError: LocalizedError {
    case microphonePermissionDenied
    case failedToStart
    case noActiveRecording
    case alreadyRecording

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission is required to record audio."
        case .failedToStart:
            return "Unable to start microphone recording."
        case .noActiveRecording:
            return "No microphone recording is currently in progress."
        case .alreadyRecording:
            return "A microphone recording is already in progress."
        }
    }
}

// MARK: - MicrophoneCaptureService

@MainActor
final class MicrophoneCaptureService {

    // MARK: - Properties

    private var audioRecorder: AVAudioRecorder?
    private var outputURL: URL?

    var isRecording: Bool {
        audioRecorder?.isRecording == true
    }

    // MARK: - Device Discovery

    static var availableInputDevices: [AVCaptureDevice] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified
        )
        return session.devices
    }

    // MARK: - Recording Control

    func startRecording(to url: URL, device: AVCaptureDevice? = nil) throws {
        guard !isRecording else {
            throw MicrophoneCaptureError.alreadyRecording
        }

        // Record as Linear PCM — zero encoder priming delay.
        // AAC encoding adds ~2048 samples (~43ms at 48kHz) of silent priming
        // at the file start, which desynchronizes mic audio from the webcam
        // video during editor playback. PCM has no such delay.
        // The export pipeline re-encodes to AAC when building the final file.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
        ]

        let recorder: AVAudioRecorder
        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
        } catch {
            throw MicrophoneCaptureError.failedToStart
        }

        recorder.prepareToRecord()
        recorder.isMeteringEnabled = true

        guard recorder.record() else {
            throw MicrophoneCaptureError.failedToStart
        }

        self.audioRecorder = recorder
        self.outputURL = url
    }

    func stopRecording() -> URL? {
        guard let recorder = audioRecorder else {
            return nil
        }

        recorder.stop()
        let url = outputURL
        self.audioRecorder = nil
        self.outputURL = nil
        return url
    }

    func pause() {
        audioRecorder?.pause()
    }

    func resume() {
        audioRecorder?.record()
    }

    // MARK: - Metering

    /// Returns the current microphone input level normalized to 0-1.
    ///
    /// Uses the same metering pattern as `AudioCaptureService`:
    /// bias toward peaks, normalize from dB, apply a power curve of 0.72,
    /// and gate noise below 0.01.
    func currentLevel() -> Float {
        guard let recorder = audioRecorder, recorder.isRecording else {
            return 0
        }

        recorder.updateMeters()
        let averagePower = recorder.averagePower(forChannel: 0)
        let peakPower = recorder.peakPower(forChannel: 0)

        // Bias toward peaks so short syllables still drive animation.
        let effectivePower = max(averagePower, peakPower - 6)
        let normalizedDB = Float(min(max((effectivePower + 55) / 55, 0), 1))
        let curved = pow(normalizedDB, 0.72)
        return curved < 0.01 ? 0 : curved
    }
}
