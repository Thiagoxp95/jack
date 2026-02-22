import AVFoundation
import CoreVideo
import Foundation
import Metal
import VideoToolbox
import os

// MARK: - ExportConfiguration

struct ExportConfiguration {
    let codec: VideoCodec
    let quality: ExportQuality
    let resolution: ExportResolution
    let outputURL: URL
}

// MARK: - ExportError

enum ExportError: LocalizedError {
    case metalInitFailed
    case assetReaderSetupFailed(String)
    case assetWriterSetupFailed(String)
    case noVideoTrack
    case renderFailed
    case writerFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .metalInitFailed:
            return "Failed to initialize Metal renderer."
        case .assetReaderSetupFailed(let detail):
            return "Failed to set up asset reader: \(detail)"
        case .assetWriterSetupFailed(let detail):
            return "Failed to set up asset writer: \(detail)"
        case .noVideoTrack:
            return "No video track found in recording."
        case .renderFailed:
            return "Metal render pass failed."
        case .writerFailed(let detail):
            return "Asset writer error: \(detail)"
        case .cancelled:
            return "Export was cancelled."
        }
    }
}

// MARK: - ExportService

actor ExportService {

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.kinshasa",
        category: "ExportService"
    )

    // MARK: - Export With Effects

    /// Exports the edited recording with Metal-rendered effects applied.
    ///
    /// - Parameters:
    ///   - session: The recording session containing source file paths.
    ///   - editor: The video editor controller with edit state (cuts, zoom, cursor settings).
    ///   - config: Export configuration (codec, quality, resolution, output URL).
    ///   - progress: A callback reporting export progress from 0.0 to 1.0.
    func exportWithEffects(
        session: RecordingSession,
        editor: VideoEditorController,
        config: ExportConfiguration,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        // Create the Metal renderer
        guard let renderer = MetalVideoRenderer() else {
            throw ExportError.metalInitFailed
        }

        // Snapshot editor state from the main actor
        let editorState = await MainActor.run {
            EditorSnapshot(
                cuts: editor.cuts,
                zoomKeyframes: editor.zoomKeyframes,
                cursorScale: editor.cursorScale,
                cursorStyle: editor.cursorStyle,
                clickHighlightEnabled: editor.clickHighlightEnabled,
                clickHighlightOpacity: editor.clickHighlightOpacity,
                cursorSmoothingEnabled: editor.cursorSmoothingEnabled,
                micVolume: editor.micVolume,
                systemVolume: editor.systemVolume,
                micMuted: editor.micMuted,
                systemMuted: editor.systemMuted,
                webcamEnabled: editor.webcamEnabled,
                webcamScale: editor.webcamScale,
                webcamPositionX: editor.webcamPositionX,
                webcamPositionY: editor.webcamPositionY,
                inPoint: editor.inPoint,
                outPoint: editor.outPoint
            )
        }

        // Load cursor data from editor
        let cursorData: CursorTrackingData? = await MainActor.run {
            editor.cursorData
        }

        // Set up source asset and reader
        let sourceAsset = AVURLAsset(url: session.screenVideoURL)
        let duration: CMTime
        let videoTrack: AVAssetTrack

        do {
            duration = try await sourceAsset.load(.duration)
            let tracks = try await sourceAsset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else {
                throw ExportError.noVideoTrack
            }
            videoTrack = track
        } catch let error as ExportError {
            throw error
        } catch {
            throw ExportError.assetReaderSetupFailed(error.localizedDescription)
        }

        let naturalSize: CGSize
        do {
            naturalSize = try await videoTrack.load(.naturalSize)
        } catch {
            throw ExportError.assetReaderSetupFailed("Failed to load natural size: \(error)")
        }

        let totalDuration = duration.seconds
        let outputSize = resolvedSize(natural: naturalSize, resolution: config.resolution)

        // Set up AVAssetReader
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: sourceAsset)
        } catch {
            throw ExportError.assetReaderSetupFailed(error.localizedDescription)
        }

        let readerOutputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        let readerOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: readerOutputSettings
        )
        readerOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(readerOutput) else {
            throw ExportError.assetReaderSetupFailed("Cannot add video output to reader")
        }
        reader.add(readerOutput)

        // Set up AVAssetWriter
        let fm = FileManager.default
        if fm.fileExists(atPath: config.outputURL.path) {
            try? fm.removeItem(at: config.outputURL)
        }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: config.outputURL, fileType: .mp4)
        } catch {
            throw ExportError.assetWriterSetupFailed(error.localizedDescription)
        }

        let videoSettings = videoWriterSettings(
            codec: config.codec,
            quality: config.quality,
            size: outputSize
        )
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(outputSize.width),
            kCVPixelBufferHeightKey as String: Int(outputSize.height),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )

        guard writer.canAdd(videoInput) else {
            throw ExportError.assetWriterSetupFailed("Cannot add video input to writer")
        }
        writer.add(videoInput)

        // Add audio tracks
        let audioInputs = try await addAudioTracks(to: writer, session: session, editor: editorState)

        // Start reading and writing
        guard reader.startReading() else {
            throw ExportError.assetReaderSetupFailed(
                reader.error?.localizedDescription ?? "Unknown reader error"
            )
        }

        guard writer.startWriting() else {
            throw ExportError.assetWriterSetupFailed(
                writer.error?.localizedDescription ?? "Unknown writer error"
            )
        }
        writer.startSession(atSourceTime: .zero)

        // Start audio processing concurrently to avoid AVAssetWriter interleaving deadlock.
        // The writer expects interleaved audio+video data. If we only feed video first,
        // the writer's buffer fills up and it refuses more video until audio catches up.
        var audioCompletionTasks: [Task<Void, Never>] = []
        for audioInput in audioInputs {
            let task = Self.startAudioProcessing(
                writerInput: audioInput.input,
                readerOutput: audioInput.readerOutput,
                reader: audioInput.reader,
                asset: audioInput.asset
            )
            audioCompletionTasks.append(task)
        }

        // Process video frames
        var previousCursorPos = CGPoint(x: -100, y: -100)

        while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
            // Check for cancellation
            if Task.isCancelled {
                reader.cancelReading()
                writer.cancelWriting()
                throw ExportError.cancelled
            }

            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let timeSeconds = presentationTime.seconds

            // Skip frames in cut regions
            if isInCutRegion(time: timeSeconds, cuts: editorState.cuts) {
                continue
            }

            // Report progress
            if totalDuration > 0 {
                progress(min(timeSeconds / totalDuration, 1.0))
            }

            // Get source pixel buffer
            guard let sourcePixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                continue
            }

            // Compute zoom level at this timestamp
            let zoomLevel = MetalVideoRenderer.interpolateZoom(
                at: timeSeconds,
                keyframes: editorState.zoomKeyframes,
                rampDuration: MetalVideoRenderer.cinematicRampDuration
            )

            // Compute cursor position
            var cursorPosition: CGPoint?
            if let cursorData, !cursorData.events.isEmpty {
                cursorPosition = interpolatedCursorPosition(
                    at: timeSeconds,
                    events: cursorData.events
                )

                if editorState.cursorSmoothingEnabled, let pos = cursorPosition {
                    let smoothed = MetalVideoRenderer.smoothCursorPosition(
                        previous: previousCursorPos,
                        current: pos
                    )
                    cursorPosition = smoothed
                    previousCursorPos = smoothed
                }
            }

            // Compute click highlight phase
            var clickPhase: Double = 0
            if editorState.clickHighlightEnabled, let cursorData {
                let clickWindow = 0.15
                if let clickEvent = cursorData.events.first(where: {
                    $0.click != nil && abs($0.t - timeSeconds) < clickWindow
                }) {
                    let elapsed = timeSeconds - clickEvent.t
                    if elapsed >= 0 && elapsed < clickWindow {
                        clickPhase = 1.0 - (elapsed / clickWindow)
                    }
                }
            }

            // Zoom center follows cursor when zoomed, with edge clamping
            let zoomCenter: CGPoint
            if zoomLevel > 1.0, let pos = cursorPosition {
                let rawCenterX = pos.x / naturalSize.width
                let rawCenterY = pos.y / naturalSize.height
                let invZoom = 1.0 / zoomLevel
                let halfView = invZoom * 0.5
                zoomCenter = CGPoint(
                    x: max(halfView, min(1.0 - halfView, rawCenterX)),
                    y: max(halfView, min(1.0 - halfView, rawCenterY))
                )
            } else {
                zoomCenter = CGPoint(x: 0.5, y: 0.5)
            }

            let clickColor = SIMD4<Float>(
                1.0, 0.8, 0.0,
                Float(editorState.clickHighlightOpacity)
            )

            // Render through Metal
            guard let outputTexture = renderer.renderFrame(
                sourcePixelBuffer: sourcePixelBuffer,
                outputSize: outputSize,
                zoomCenter: zoomCenter,
                zoomLevel: zoomLevel,
                cursorPosition: cursorPosition,
                cursorScale: editorState.cursorScale,
                clickPhase: clickPhase,
                clickColor: clickColor,
                clickRadius: 30.0
            ) else {
                Self.logger.warning("Metal render failed for frame at \(timeSeconds)s")
                continue
            }

            // Wait for the video input to be ready
            while !videoInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            }

            // Copy rendered texture to a pixel buffer for writing
            guard let outputPixelBuffer = pixelBufferFromTexture(
                outputTexture,
                device: renderer.device,
                adaptor: pixelBufferAdaptor
            ) else {
                Self.logger.warning("Failed to create pixel buffer from texture at \(timeSeconds)s")
                continue
            }

            pixelBufferAdaptor.append(outputPixelBuffer, withPresentationTime: presentationTime)
        }

        // Finalize video
        videoInput.markAsFinished()

        // Wait for concurrent audio processing to complete
        // (audio inputs mark themselves as finished in their callbacks)
        for task in audioCompletionTasks {
            await task.value
        }

        await writer.finishWriting()

        if writer.status == .failed {
            throw ExportError.writerFailed(
                writer.error?.localizedDescription ?? "Unknown writer error"
            )
        }

        progress(1.0)
        Self.logger.info("Export completed to \(config.outputURL.path)")
    }

    // MARK: - Resolved Size

    /// Calculates output dimensions maintaining aspect ratio.
    func resolvedSize(natural: CGSize, resolution: ExportResolution) -> CGSize {
        switch resolution {
        case .original:
            return natural
        case .p1080:
            let targetHeight: CGFloat = 1080
            let aspect = natural.width / natural.height
            let targetWidth = (targetHeight * aspect).rounded(.down)
            // Ensure even dimensions for video encoding
            return CGSize(
                width: targetWidth - targetWidth.truncatingRemainder(dividingBy: 2),
                height: targetHeight
            )
        case .p720:
            let targetHeight: CGFloat = 720
            let aspect = natural.width / natural.height
            let targetWidth = (targetHeight * aspect).rounded(.down)
            return CGSize(
                width: targetWidth - targetWidth.truncatingRemainder(dividingBy: 2),
                height: targetHeight
            )
        }
    }

    // MARK: - Video Writer Settings

    /// Builds AVAssetWriter video settings dictionary.
    func videoWriterSettings(
        codec: VideoCodec,
        quality: ExportQuality,
        size: CGSize
    ) -> [String: Any] {
        let codecType: AVVideoCodecType
        let profileLevel: String

        switch codec {
        case .h264:
            codecType = .h264
            profileLevel = AVVideoProfileLevelH264HighAutoLevel
        case .h265:
            codecType = .hevc
            profileLevel = kVTProfileLevel_HEVC_Main_AutoLevel as String
        }

        let bitRate: Int
        switch quality {
        case .low:
            bitRate = 2_000_000
        case .medium:
            bitRate = 5_000_000
        case .high:
            bitRate = 10_000_000
        case .lossless:
            bitRate = 50_000_000
        }

        var compressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: bitRate,
        ]

        // Profile level only applies to H.264; HEVC selects automatically.
        if codec == .h264 {
            compressionProperties[AVVideoProfileLevelKey] = profileLevel
        }

        return [
            AVVideoCodecKey: codecType,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: compressionProperties,
        ]
    }

    // MARK: - Audio Track Helper

    /// Represents a paired audio writer input and reader output for processing.
    /// Retains the asset and reader to prevent deallocation while processing.
    private struct AudioTrackPair {
        let input: AVAssetWriterInput
        let readerOutput: AVAssetReaderTrackOutput
        let reader: AVAssetReader
        let asset: AVURLAsset
    }

    /// Adds mic and system audio writer inputs if their files exist and are not muted.
    private func addAudioTracks(
        to writer: AVAssetWriter,
        session: RecordingSession,
        editor: EditorSnapshot
    ) async throws -> [AudioTrackPair] {
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]

        var pairs: [AudioTrackPair] = []
        let fm = FileManager.default

        // Microphone audio
        if !editor.micMuted && fm.fileExists(atPath: session.micAudioURL.path) {
            if let pair = try await makeAudioPair(
                url: session.micAudioURL,
                settings: audioSettings,
                writer: writer,
                label: "mic"
            ) {
                pairs.append(pair)
            }
        }

        // System audio
        if !editor.systemMuted && fm.fileExists(atPath: session.systemAudioURL.path) {
            if let pair = try await makeAudioPair(
                url: session.systemAudioURL,
                settings: audioSettings,
                writer: writer,
                label: "system"
            ) {
                pairs.append(pair)
            }
        }

        return pairs
    }

    private func makeAudioPair(
        url: URL,
        settings: [String: Any],
        writer: AVAssetWriter,
        label: String
    ) async throws -> AudioTrackPair? {
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            Self.logger.warning("Failed to load \(label) audio tracks: \(error)")
            return nil
        }

        guard let audioTrack = tracks.first else {
            Self.logger.info("No \(label) audio track found, skipping")
            return nil
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            Self.logger.warning("Failed to create \(label) audio reader: \(error)")
            return nil
        }

        let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
        guard reader.canAdd(readerOutput) else {
            Self.logger.warning("Cannot add \(label) audio reader output")
            return nil
        }
        reader.add(readerOutput)

        guard reader.startReading() else {
            Self.logger.warning("Cannot start reading \(label) audio")
            return nil
        }

        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        audioInput.expectsMediaDataInRealTime = false

        guard writer.canAdd(audioInput) else {
            Self.logger.warning("Cannot add \(label) audio input to writer")
            return nil
        }
        writer.add(audioInput)

        return AudioTrackPair(input: audioInput, readerOutput: readerOutput, reader: reader, asset: asset)
    }

    // MARK: - Audio Processing

    /// Wraps a non-Sendable value for safe transfer across concurrency boundaries.
    /// Safety: the wrapped value must only be accessed from a single context after transfer.
    private final class SendableBox<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    /// Starts audio processing on a concurrent task with its own serial DispatchQueue.
    /// Must be `nonisolated static` so the closure doesn't capture the actor.
    /// The `reader` and `asset` parameters are retained by the task closure to prevent
    /// ARC from deallocating them while the callback is still reading samples.
    private nonisolated static func startAudioProcessing(
        writerInput: AVAssetWriterInput,
        readerOutput: AVAssetReaderTrackOutput,
        reader: AVAssetReader,
        asset: AVURLAsset
    ) -> Task<Void, Never> {
        let writerBox = SendableBox(writerInput)
        let readerBox = SendableBox(readerOutput)
        let readerOwner = SendableBox(reader)
        let assetOwner = SendableBox(asset)

        return Task {
            let writerInput = writerBox.value
            let readerOutput = readerBox.value

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                nonisolated(unsafe) var finished = false
                let queue = DispatchQueue(label: "com.kinshasa.export.audio.\(UUID().uuidString)")
                writerInput.requestMediaDataWhenReady(on: queue) {
                    while writerInput.isReadyForMoreMediaData {
                        if let sampleBuffer = readerOutput.copyNextSampleBuffer() {
                            writerInput.append(sampleBuffer)
                        } else {
                            if !finished {
                                finished = true
                                writerInput.markAsFinished()
                                continuation.resume()
                            }
                            return
                        }
                    }
                }
            }

            // Keep reader and asset alive until processing completes
            withExtendedLifetime((readerOwner, assetOwner)) {}
        }
    }

    // MARK: - Frame Helpers

    /// Checks whether a given timestamp falls within any cut region.
    private func isInCutRegion(time: Double, cuts: [CutRegion]) -> Bool {
        for cut in cuts {
            if time >= cut.inPoint && time < cut.outPoint {
                return true
            }
        }
        return false
    }

    /// Interpolates cursor position from cursor events at a given time.
    private func interpolatedCursorPosition(
        at time: Double,
        events: [CursorEvent]
    ) -> CGPoint? {
        guard !events.isEmpty else { return nil }

        if time <= events[0].t {
            return CGPoint(x: events[0].x, y: events[0].y)
        }
        if time >= events[events.count - 1].t {
            let last = events[events.count - 1]
            return CGPoint(x: last.x, y: last.y)
        }

        // Binary search for bracketing events
        var lo = 0
        var hi = events.count - 1

        while lo <= hi {
            let mid = (lo + hi) / 2
            if events[mid].t <= time {
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }

        let event = events[hi]
        return CGPoint(x: event.x, y: event.y)
    }

    // MARK: - Texture to PixelBuffer

    /// Copies a Metal texture into a CVPixelBuffer suitable for AVAssetWriter.
    private func pixelBufferFromTexture(
        _ texture: MTLTexture,
        device: MTLDevice,
        adaptor: AVAssetWriterInputPixelBufferAdaptor
    ) -> CVPixelBuffer? {
        let width = texture.width
        let height = texture.height

        // Get a pixel buffer from the adaptor's pool
        guard let pool = adaptor.pixelBufferPool else { return nil }

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            pool,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let outputBuffer = pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(outputBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(outputBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(outputBuffer) else {
            return nil
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(outputBuffer)

        // The texture is .private storage, so we need to blit it to a shared buffer first.
        let bufferLength = bytesPerRow * height
        guard let sharedBuffer = device.makeBuffer(length: bufferLength, options: .storageModeShared) else {
            return nil
        }

        guard let commandQueue = device.makeCommandQueue(),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let blitEncoder = commandBuffer.makeBlitCommandEncoder()
        else {
            return nil
        }

        blitEncoder.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: sharedBuffer,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: bufferLength
        )
        blitEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Copy from the shared Metal buffer to the CVPixelBuffer
        memcpy(baseAddress, sharedBuffer.contents(), bufferLength)

        return outputBuffer
    }
}
