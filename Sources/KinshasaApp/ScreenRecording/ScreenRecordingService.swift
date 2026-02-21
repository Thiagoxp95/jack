import AVFoundation
import Foundation
import ScreenCaptureKit
import os

// MARK: - ScreenRecordingError

enum ScreenRecordingError: LocalizedError {
    case permissionDenied
    case noDisplayFound
    case writerSetupFailed(String)
    case alreadyCapturing
    case notCapturing
    case streamStartFailed(Error)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen recording permission was denied."
        case .noDisplayFound:
            return "No display found for capture."
        case .writerSetupFailed(let detail):
            return "Failed to set up media writer: \(detail)"
        case .alreadyCapturing:
            return "A capture session is already in progress."
        case .notCapturing:
            return "No capture session is in progress."
        case .streamStartFailed(let error):
            return "Failed to start screen capture stream: \(error.localizedDescription)"
        }
    }
}

// MARK: - SampleBufferWriter

/// Thread-safe wrapper around AVAssetWriter / AVAssetWriterInput.
///
/// ScreenCaptureKit delivers sample buffers on arbitrary dispatch queues.
/// `CMSampleBuffer` is not `Sendable`, so hopping to an actor is rejected
/// by Swift 6.2 strict concurrency. Instead we protect mutable writer state
/// with `os_unfair_lock` and call `append` directly from the callback thread,
/// which AVAssetWriterInput explicitly supports when `expectsMediaDataInRealTime`
/// is `true`.
final class SampleBufferWriter: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var sessionStarted = false

    func configure(writer: AVAssetWriter, input: AVAssetWriterInput) {
        os_unfair_lock_lock(&lock)
        self.writer = writer
        self.input = input
        self.sessionStarted = false
        os_unfair_lock_unlock(&lock)
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        os_unfair_lock_lock(&lock)
        guard let writer, let input, input.isReadyForMoreMediaData else {
            os_unfair_lock_unlock(&lock)
            return
        }

        if !sessionStarted {
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startSession(atSourceTime: timestamp)
            sessionStarted = true
        }

        input.append(sampleBuffer)
        os_unfair_lock_unlock(&lock)
    }

    /// Mark the input as finished and return the writer for async finishWriting.
    func finalize() -> AVAssetWriter? {
        os_unfair_lock_lock(&lock)
        let w = writer
        let i = input
        writer = nil
        input = nil
        sessionStarted = false
        os_unfair_lock_unlock(&lock)

        i?.markAsFinished()
        return w
    }

    func reset() {
        os_unfair_lock_lock(&lock)
        writer = nil
        input = nil
        sessionStarted = false
        os_unfair_lock_unlock(&lock)
    }
}

// MARK: - ScreenRecordingService

actor ScreenRecordingService: NSObject, SCStreamOutput, SCStreamDelegate {

    // MARK: - Properties

    private let fps: RecordingFPS
    private let videoOutputURL: URL
    private let audioOutputURL: URL

    private var stream: SCStream?
    private var isCapturing = false

    /// Thread-safe writers accessed directly from the SCStreamOutput callback.
    let videoBufferWriter = SampleBufferWriter()
    let audioBufferWriter = SampleBufferWriter()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.kinshasa",
        category: "ScreenRecording"
    )

    // MARK: - Init

    init(fps: RecordingFPS, videoOutputURL: URL, audioOutputURL: URL) {
        self.fps = fps
        self.videoOutputURL = videoOutputURL
        self.audioOutputURL = audioOutputURL
        super.init()
    }

    // MARK: - Static Permission Methods

    static func requestPermission() async -> Bool {
        do {
            _ = try await SCShareableContent.current
            return true
        } catch {
            return false
        }
    }

    static func hasPermission() async -> Bool {
        do {
            _ = try await SCShareableContent.current
            return true
        } catch {
            return false
        }
    }

    static func availableContent() async throws -> SCShareableContent {
        return try await SCShareableContent.current
    }

    // MARK: - Start Capture

    func startCapture(
        display: SCDisplay? = nil,
        window: SCWindow? = nil,
        region: CGRect? = nil,
        captureSystemAudio: Bool = true,
        excludedWindows: [SCWindow] = []
    ) async throws {
        guard !isCapturing else {
            throw ScreenRecordingError.alreadyCapturing
        }

        // Build content filter
        let filter: SCContentFilter
        if let window {
            filter = SCContentFilter(desktopIndependentWindow: window)
        } else if let display {
            let content = try await Self.availableContent()
            let excludedApps = content.applications.filter { app in
                app.bundleIdentifier == Bundle.main.bundleIdentifier
            }
            filter = SCContentFilter(
                display: display,
                excludingApplications: excludedApps,
                exceptingWindows: []
            )
        } else {
            throw ScreenRecordingError.noDisplayFound
        }

        // Configure stream
        let config = SCStreamConfiguration()
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps.rawValue))
        config.queueDepth = 8
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_32BGRA

        if let region, display != nil {
            // Region capture: set sourceRect and scale dimensions for Retina
            config.sourceRect = region
            config.width = Int(region.width) * 2
            config.height = Int(region.height) * 2
        } else if let display {
            // Full display: use native dimensions x2 for Retina
            config.width = display.width * 2
            config.height = display.height * 2
        } else if window != nil {
            // Window capture: use reasonable defaults; ScreenCaptureKit will
            // adapt to the window's actual size.
            config.width = 3840
            config.height = 2160
        }

        config.capturesAudio = captureSystemAudio
        if captureSystemAudio {
            config.sampleRate = 48_000
            config.channelCount = 2
        }

        // Set up video writer
        try setupVideoWriter(width: config.width, height: config.height)

        // Set up audio writer if needed
        if captureSystemAudio {
            try setupAudioWriter()
        }

        // Create and configure stream
        let captureStream = SCStream(filter: filter, configuration: config, delegate: self)

        try captureStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: nil)

        if captureSystemAudio {
            try captureStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: nil)
        }

        // Start capture
        do {
            try await captureStream.startCapture()
        } catch {
            videoBufferWriter.reset()
            audioBufferWriter.reset()
            throw ScreenRecordingError.streamStartFailed(error)
        }

        stream = captureStream
        isCapturing = true
        Self.logger.info("Screen capture started")
    }

    // MARK: - Stop Capture

    func stopCapture() async {
        guard isCapturing, let stream else { return }

        do {
            try await stream.stopCapture()
        } catch {
            Self.logger.error("Error stopping stream: \(error)")
        }

        self.stream = nil
        isCapturing = false

        // Finalize writers
        let videoWriter = videoBufferWriter.finalize()
        let audioWriter = audioBufferWriter.finalize()

        if let videoWriter, videoWriter.status == .writing {
            await videoWriter.finishWriting()
        }
        if let audioWriter, audioWriter.status == .writing {
            await audioWriter.finishWriting()
        }

        Self.logger.info("Screen capture stopped and writers finalized")
    }

    // MARK: - Writer Setup

    private func setupVideoWriter(width: Int, height: Int) throws {
        removeFileIfExists(at: videoOutputURL)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: videoOutputURL, fileType: .mov)
        } catch {
            throw ScreenRecordingError.writerSetupFailed("Video AVAssetWriter: \(error)")
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            throw ScreenRecordingError.writerSetupFailed("Cannot add video input to writer")
        }

        writer.add(input)
        guard writer.startWriting() else {
            throw ScreenRecordingError.writerSetupFailed(
                writer.error?.localizedDescription ?? "Unknown video writer error"
            )
        }

        videoBufferWriter.configure(writer: writer, input: input)
    }

    private func setupAudioWriter() throws {
        removeFileIfExists(at: audioOutputURL)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: audioOutputURL, fileType: .m4a)
        } catch {
            throw ScreenRecordingError.writerSetupFailed("Audio AVAssetWriter: \(error)")
        }

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]

        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            throw ScreenRecordingError.writerSetupFailed("Cannot add audio input to writer")
        }

        writer.add(input)
        guard writer.startWriting() else {
            throw ScreenRecordingError.writerSetupFailed(
                writer.error?.localizedDescription ?? "Unknown audio writer error"
            )
        }

        audioBufferWriter.configure(writer: writer, input: input)
    }

    // MARK: - Helpers

    private func removeFileIfExists(at url: URL) {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: url)
        }
    }

    // MARK: - SCStreamOutput (nonisolated)

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard sampleBuffer.isValid else { return }

        switch type {
        case .screen:
            videoBufferWriter.append(sampleBuffer)
        case .audio:
            audioBufferWriter.append(sampleBuffer)
        case .microphone:
            break
        @unknown default:
            break
        }
    }

    // MARK: - SCStreamDelegate (nonisolated)

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Self.logger.error("Stream stopped with error: \(error)")
        Task { await stopCapture() }
    }
}
