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
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.jack",
        category: "SampleBufferWriter"
    )
    private var lock = os_unfair_lock()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var sessionStarted = false
    private var sampleCount = 0
    private var skippedCount = 0
    private var expectedWidth = 0
    private var expectedHeight = 0
    let label: String

    init(label: String) {
        self.label = label
    }

    func configure(writer: AVAssetWriter, input: AVAssetWriterInput, width: Int = 0, height: Int = 0) {
        os_unfair_lock_lock(&lock)
        self.writer = writer
        self.input = input
        self.sessionStarted = false
        self.sampleCount = 0
        self.skippedCount = 0
        self.expectedWidth = width
        self.expectedHeight = height
        os_unfair_lock_unlock(&lock)
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        os_unfair_lock_lock(&lock)
        guard let writer, let input else {
            os_unfair_lock_unlock(&lock)
            return
        }

        guard writer.status == .writing else {
            let status = writer.status.rawValue
            let err = writer.error?.localizedDescription ?? "none"
            os_unfair_lock_unlock(&lock)
            if sampleCount == 0 {
                Self.logger.error("[\(self.label)] Writer not in writing state: \(status), error: \(err)")
            }
            return
        }

        // Reject frames whose dimensions don't match the writer config.
        // Presenter Overlay Large can change the stream dimensions mid-recording,
        // which would corrupt the AVAssetWriter.
        if expectedWidth > 0, let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let w = CVPixelBufferGetWidth(imageBuffer)
            let h = CVPixelBufferGetHeight(imageBuffer)
            if w != expectedWidth || h != expectedHeight {
                skippedCount += 1
                if skippedCount == 1 || skippedCount % 100 == 0 {
                    Self.logger.warning("[\(self.label)] Skipped \(self.skippedCount) frames with mismatched dimensions (\(w)x\(h) vs expected \(self.expectedWidth)x\(self.expectedHeight))")
                }
                os_unfair_lock_unlock(&lock)
                return
            }
        }

        guard input.isReadyForMoreMediaData else {
            os_unfair_lock_unlock(&lock)
            return
        }

        if !sessionStarted {
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startSession(atSourceTime: timestamp)
            sessionStarted = true
            Self.logger.fault("[\(self.label)] Session started at \(timestamp.seconds)s")
        }

        input.append(sampleBuffer)
        sampleCount += 1

        if sampleCount == 1 || sampleCount % 300 == 0 {
            Self.logger.fault("[\(self.label)] Appended \(self.sampleCount) samples")
        }

        os_unfair_lock_unlock(&lock)
    }

    /// Mark the input as finished and return the writer for async finishWriting.
    func finalize() -> AVAssetWriter? {
        os_unfair_lock_lock(&lock)
        let w = writer
        let i = input
        let count = sampleCount
        let started = sessionStarted
        writer = nil
        input = nil
        sessionStarted = false
        sampleCount = 0
        os_unfair_lock_unlock(&lock)

        Self.logger.fault("[\(self.label)] Finalizing: \(count) samples appended, session started: \(started)")
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

/// Manages SCStream lifecycle, frame capture, and writes raw video/audio to disk.
///
/// This is a plain NSObject subclass (not an actor) because:
///   - SCStreamOutput/SCStreamDelegate are Objective-C protocols requiring NSObject
///   - The Objective-C runtime retains/releases the delegate from arbitrary threads
///   - Mixing actor isolation with NSObject retain/release causes EXC_BAD_ACCESS
///
/// Thread safety: All mutable buffer state is protected by `SampleBufferWriter`
/// (os_unfair_lock). The `stream`/`isCapturing` properties are only accessed
/// from `@MainActor` callers (RecordingSessionController).
@MainActor
final class ScreenRecordingService: NSObject, @unchecked Sendable {

    // MARK: - Properties

    private let fps: RecordingFPS
    private let videoOutputURL: URL
    private let audioOutputURL: URL

    private var stream: SCStream?
    private var isCapturing = false

    /// Thread-safe writers accessed directly from the SCStreamOutput callback.
    nonisolated let videoBufferWriter = SampleBufferWriter(label: "video")
    nonisolated let audioBufferWriter = SampleBufferWriter(label: "audio")

    private nonisolated static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.jack",
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

    nonisolated static func requestPermission() async -> Bool {
        do {
            _ = try await SCShareableContent.current
            return true
        } catch {
            return false
        }
    }

    nonisolated static func hasPermission() async -> Bool {
        do {
            _ = try await SCShareableContent.current
            return true
        } catch {
            return false
        }
    }

    nonisolated static func availableContent() async throws -> SCShareableContent {
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

        Self.logger.fault("[SCR-01] startCapture: building content filter")

        // Build content filter
        let filter: SCContentFilter
        if let window {
            filter = SCContentFilter(desktopIndependentWindow: window)
        } else if let display {
            Self.logger.fault("[SCR-02] startCapture: fetching available content")
            let content = try await Self.availableContent()
            Self.logger.fault("[SCR-03] startCapture: got content, building filter")
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

        Self.logger.fault("[SCR-04] startCapture: configuring stream")

        // Configure stream
        let config = SCStreamConfiguration()
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps.rawValue))
        config.queueDepth = 8
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        if #available(macOS 14.0, *) {
            config.presenterOverlayPrivacyAlertSetting = .never
        }

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

        Self.logger.fault("[SCR-05] startCapture: setting up video writer (\(config.width)x\(config.height))")

        // Set up video writer
        try setupVideoWriter(width: config.width, height: config.height)

        // Set up audio writer if needed
        if captureSystemAudio {
            Self.logger.fault("[SCR-06] startCapture: setting up audio writer")
            try setupAudioWriter()
        }

        Self.logger.fault("[SCR-07] startCapture: creating SCStream")

        // Create and configure stream.
        let captureStream = SCStream(
            filter: filter,
            configuration: config,
            delegate: self
        )

        try captureStream.addStreamOutput(
            self, type: .screen, sampleHandlerQueue: nil
        )

        if captureSystemAudio {
            try captureStream.addStreamOutput(
                self, type: .audio, sampleHandlerQueue: nil
            )
        }

        Self.logger.fault("[SCR-08] startCapture: calling captureStream.startCapture()")

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
        Self.logger.fault("[SCR-09] startCapture: complete, stream is running")
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

        if let videoWriter {
            Self.logger.fault("[STOP] Video writer status before finalize: \(videoWriter.status.rawValue)")
            if videoWriter.status == .writing {
                await videoWriter.finishWriting()
                Self.logger.fault("[STOP] Video writer status after finalize: \(videoWriter.status.rawValue)")
                if videoWriter.status == .failed {
                    Self.logger.error("[STOP] Video writer error: \(videoWriter.error?.localizedDescription ?? "unknown")")
                }
            } else if videoWriter.status == .failed {
                Self.logger.error("[STOP] Video writer already failed: \(videoWriter.error?.localizedDescription ?? "unknown")")
            }
        } else {
            Self.logger.error("[STOP] No video writer available")
        }

        if let audioWriter {
            Self.logger.fault("[STOP] Audio writer status before finalize: \(audioWriter.status.rawValue)")
            if audioWriter.status == .writing {
                await audioWriter.finishWriting()
            }
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

        videoBufferWriter.configure(writer: writer, input: input, width: width, height: height)
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
}

// MARK: - SCStreamOutput + SCStreamDelegate

extension ScreenRecordingService: SCStreamOutput, SCStreamDelegate {

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard sampleBuffer.isValid else { return }

        switch type {
        case .screen:
            // ScreenCaptureKit delivers status-only samples (no pixel data) alongside
            // real video frames. Appending non-video samples to AVAssetWriterInput
            // causes the writer to fail, so filter them out.
            guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
            videoBufferWriter.append(sampleBuffer)
        case .audio:
            // Only append audio samples that have valid data
            guard CMSampleBufferGetDataBuffer(sampleBuffer) != nil else { return }
            audioBufferWriter.append(sampleBuffer)
        case .microphone:
            break
        @unknown default:
            break
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Self.logger.error("Stream stopped with error: \(error)")
        Task { @MainActor in
            await self.stopCapture()
        }
    }
}
