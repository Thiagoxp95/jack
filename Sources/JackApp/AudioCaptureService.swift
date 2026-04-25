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

struct AudioDevice: Identifiable {
    let uid: String
    let name: String
    let isAvailable: Bool

    var id: String { uid }
}

@MainActor
final class AudioCaptureService {
    private struct PreparedRecorderReservation {
        let recorder: AVAudioRecorder
        let url: URL
    }

    struct StoppedRecording {
        let url: URL
        let duration: TimeInterval
    }

    struct RecordingSnapshot {
        let url: URL
        let duration: TimeInterval
    }

    private var recorder: AVAudioRecorder?
    private var preparedRecorder: PreparedRecorderReservation?
    private var meteringNoiseFloorPower: Double = -55

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
                prepareForNextRecordingIfPossible()
                return true
            case .undetermined:
                guard prompt else {
                    return false
                }
                let granted = await withCheckedContinuation { continuation in
                    AVAudioApplication.requestRecordPermission { granted in
                        continuation.resume(returning: granted)
                    }
                }
                if granted {
                    prepareForNextRecordingIfPossible()
                }
                return granted
            case .denied:
                return false
            @unknown default:
                return false
            }
        } else {
            let status = AVCaptureDevice.authorizationStatus(for: .audio)

            switch status {
            case .authorized:
                prepareForNextRecordingIfPossible()
                return true
            case .notDetermined:
                guard prompt else {
                    return false
                }
                let granted = await withCheckedContinuation { continuation in
                    AVCaptureDevice.requestAccess(for: .audio) { granted in
                        continuation.resume(returning: granted)
                    }
                }
                if granted {
                    prepareForNextRecordingIfPossible()
                }
                return granted
            case .denied, .restricted:
                return false
            @unknown default:
                return false
            }
        }
    }

    func startRecording() throws {
        try startRecordingInternal()
    }

    func prepareForNextRecordingIfPossible() {
        stagePreparedRecorderIfPossible()
    }

    private func startRecordingInternal() throws {
        guard microphonePermissionGranted else {
            throw AudioCaptureError.microphonePermissionDenied
        }

        if isRecording {
            return
        }

        if let prepared = takePreparedRecorder() {
            if prepared.recorder.record() {
                recorder = prepared.recorder
                resetMeteringNoiseFloor()
                return
            }
            try? FileManager.default.removeItem(at: prepared.url)
        }

        let outputURL = makeOutputURL()
        let recorder = try makeRecorder(url: outputURL)
        guard recorder.record() else {
            try? FileManager.default.removeItem(at: outputURL)
            throw AudioCaptureError.failedToStart
        }

        self.recorder = recorder
        resetMeteringNoiseFloor()
    }

    func stopRecording() throws -> StoppedRecording {
        guard let recorder else {
            throw AudioCaptureError.noRecording
        }

        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        stagePreparedRecorderIfPossible()
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
        let averagePower = Double(recorder.averagePower(forChannel: 0))
        let peakPower = Double(recorder.peakPower(forChannel: 0))

        // Learn the room's idle floor while input stays near silence so the
        // indicator does not animate from device self-noise or HVAC hiss.
        if averagePower <= meteringNoiseFloorPower + 8 {
            meteringNoiseFloorPower = (meteringNoiseFloorPower * 0.9) + (averagePower * 0.1)
            meteringNoiseFloorPower = min(max(meteringNoiseFloorPower, -70), -24)
        }

        // Favor sustained speech energy, with a smaller peak bias for
        // consonants. A dynamic gate above the learned floor prevents idle
        // movement in quiet rooms while preserving normal dictation pickup.
        let effectivePower = max(averagePower + 1.5, peakPower - 12)
        let gateFloor = max(meteringNoiseFloorPower + 10, -40)
        let normalizedDB = Double(min(max((effectivePower - gateFloor) / 28, 0), 1))
        let curved = pow(normalizedDB, 0.78)
        return curved < 0.02 ? 0 : curved
    }

    func availableAudioInputDevices() -> [AudioDevice] {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return discoverySession.devices.map { device in
            AudioDevice(uid: device.uniqueID, name: device.localizedName, isAvailable: device.isConnected)
        }
    }

    func startRecording(preferredDeviceUID: String?) throws {
        _ = preferredDeviceUID
        try startRecordingInternal()
    }

    private func stagePreparedRecorderIfPossible() {
        guard recorder == nil, preparedRecorder == nil, microphonePermissionGranted else {
            return
        }

        let outputURL = makeOutputURL()
        do {
            let recorder = try makeRecorder(url: outputURL)
            preparedRecorder = PreparedRecorderReservation(recorder: recorder, url: outputURL)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
        }
    }

    private func takePreparedRecorder() -> PreparedRecorderReservation? {
        defer {
            preparedRecorder = nil
        }
        return preparedRecorder
    }

    private func makeRecorder(url: URL) throws -> AVAudioRecorder {
        let recorder = try AVAudioRecorder(url: url, settings: recordingSettings)
        recorder.prepareToRecord()
        recorder.isMeteringEnabled = true
        return recorder
    }

    private func resetMeteringNoiseFloor() {
        meteringNoiseFloorPower = -55
    }

    private func makeOutputURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-recording-\(UUID().uuidString)")
            .appendingPathExtension("wav")
    }

    private var recordingSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
        ]
    }
}
