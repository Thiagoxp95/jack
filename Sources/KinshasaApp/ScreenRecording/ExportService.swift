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
    let fileFormat: ExportFileFormat
    let aspectRatio: ExportAspectRatio
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

// MARK: - ResumeOnce

/// Thread-safe single-use continuation resumer.
/// Prevents double-resume crashes when cancel races with normal completion.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let continuation: CheckedContinuation<Void, Error>

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func succeed() {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        continuation.resume()
    }

    func fail(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        continuation.resume(throwing: error)
    }
}

// MARK: - ExportService

/// Exports recorded video with Metal-rendered effects (zoom, cursor, click highlights).
///
/// Architecture: all tracks (video + audio) processed via `requestMediaDataWhenReady`
/// on dedicated serial GCD queues. A `DispatchGroup` coordinates completion, and
/// `withCheckedThrowingContinuation` bridges back to `async throws`.
/// Video frames use a zero-copy Metal pipeline: the GPU renders directly into
/// IOSurface-backed pixel buffers from the writer's pool.
final class ExportService: @unchecked Sendable {

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.kinshasa",
        category: "ExportService"
    )

    // MARK: - Instance Properties (retained for lifetime of export)

    private var writer: AVAssetWriter?
    private var reader: AVAssetReader?
    private var videoInput: AVAssetWriterInput?
    private var videoReaderOutput: AVAssetReaderTrackOutput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioPairs: [(input: AVAssetWriterInput, readerOutput: AVAssetReaderTrackOutput, reader: AVAssetReader, asset: AVURLAsset)] = []
    private var renderer: MetalVideoRenderer?
    private var metalTextureCache: CVMetalTextureCache?

    private var _isCancelled = false
    private let cancelLock = NSLock()

    /// Thread-safe cancellation flag. Written from the caller's thread,
    /// read from GCD export queues.
    private var isCancelled: Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return _isCancelled
    }

    // MARK: - Cancel

    func cancel() {
        cancelLock.lock()
        _isCancelled = true
        cancelLock.unlock()
    }

    // MARK: - Zero-Copy Texture Helper

    /// Creates a Metal texture backed by the same IOSurface memory as the pixel buffer.
    /// GPU writes go directly into the pixel buffer — no blit or memcpy needed.
    private func makeOutputTexture(from pixelBuffer: CVPixelBuffer, size: CGSize) -> MTLTexture? {
        guard let cache = metalTextureCache else { return nil }

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            Int(size.width),
            Int(size.height),
            0,
            &cvTexture
        )

        guard status == kCVReturnSuccess, let unwrapped = cvTexture else {
            return nil
        }

        return CVMetalTextureGetTexture(unwrapped)
    }

    // MARK: - Export With Effects

    func exportWithEffects(
        session: RecordingSession,
        editor: VideoEditorController,
        config: ExportConfiguration,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        // 1. Setup Metal renderer
        guard let metalRenderer = MetalVideoRenderer() else {
            throw ExportError.metalInitFailed
        }
        renderer = metalRenderer

        // Create texture cache for zero-copy output path
        var cache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            metalRenderer.device,
            nil,
            &cache
        )
        guard cacheStatus == kCVReturnSuccess, let validCache = cache else {
            throw ExportError.metalInitFailed
        }
        metalTextureCache = validCache

        // 2. Snapshot editor state on MainActor
        let editorState = await MainActor.run {
            EditorSnapshot(
                segments: editor.segments,
                zoomKeyframes: editor.zoomKeyframes,
                markers: editor.markers,
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
                webcamStartOffset: editor.webcamStartOffset
            )
        }

        let cursorData: CursorTrackingData? = await MainActor.run {
            editor.cursorData
        }

        // 2b. Pre-render cursor texture for Metal compositing
        let cursorTexture = metalRenderer.createCursorTexture(style: editorState.cursorStyle)

        // 2c. Set up webcam reader if enabled
        var webcamReaderOutput: AVAssetReaderTrackOutput?
        var webcamAssetReader: AVAssetReader?
        if editorState.webcamEnabled {
            let webcamURL = session.webcamVideoURL
            if FileManager.default.fileExists(atPath: webcamURL.path) {
                do {
                    let webcamAsset = AVURLAsset(url: webcamURL)
                    let webcamTracks = try await webcamAsset.loadTracks(withMediaType: .video)
                    if let webcamTrack = webcamTracks.first {
                        let reader = try AVAssetReader(asset: webcamAsset)
                        let output = AVAssetReaderTrackOutput(
                            track: webcamTrack,
                            outputSettings: [
                                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                            ]
                        )
                        output.alwaysCopiesSampleData = false
                        if reader.canAdd(output) {
                            reader.add(output)
                            reader.startReading()
                            webcamAssetReader = reader
                            webcamReaderOutput = output
                        }
                    }
                } catch {
                    Self.logger.warning("Failed to set up webcam reader: \(error)")
                }
            }
        }

        // 3. Load source asset
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

        // Compute canvas size, content size, and content offset.
        // When an aspect ratio is selected AND a resolution is set, the resolution
        // target applies to the canvas dimensions (the full output including bars).
        let canvasSize: CGSize
        let contentSize: CGSize
        let contentOffset: CGPoint

        if let targetRatio = config.aspectRatio.ratio {
            let sourceAspect = naturalSize.width / naturalSize.height

            // Determine canvas dimensions — resolution targets the canvas
            let rawCanvas: CGSize
            switch config.resolution {
            case .original:
                // Expand from natural size to fill the target aspect ratio
                if sourceAspect > targetRatio {
                    rawCanvas = CGSize(width: naturalSize.width,
                                       height: (naturalSize.width / targetRatio).rounded(.down))
                } else {
                    rawCanvas = CGSize(width: (naturalSize.height * targetRatio).rounded(.down),
                                       height: naturalSize.height)
                }
            case .p1080:
                rawCanvas = CGSize(width: (1080.0 * targetRatio).rounded(.down), height: 1080)
            case .p720:
                rawCanvas = CGSize(width: (720.0 * targetRatio).rounded(.down), height: 720)
            }

            // Ensure even dimensions for video codecs
            canvasSize = CGSize(
                width: rawCanvas.width - rawCanvas.width.truncatingRemainder(dividingBy: 2),
                height: rawCanvas.height - rawCanvas.height.truncatingRemainder(dividingBy: 2)
            )

            // Fit the source content inside the canvas maintaining its native aspect ratio
            if sourceAspect > targetRatio {
                // Source wider → match canvas width, content shorter
                let h = (canvasSize.width / sourceAspect).rounded(.down)
                contentSize = CGSize(width: canvasSize.width,
                                     height: h - h.truncatingRemainder(dividingBy: 2))
            } else {
                // Source taller → match canvas height, content narrower
                let w = (canvasSize.height * sourceAspect).rounded(.down)
                contentSize = CGSize(width: w - w.truncatingRemainder(dividingBy: 2),
                                     height: canvasSize.height)
            }

            contentOffset = CGPoint(
                x: (canvasSize.width - contentSize.width) / 2,
                y: (canvasSize.height - contentSize.height) / 2
            )
        } else {
            contentSize = resolvedSize(natural: naturalSize, resolution: config.resolution)
            canvasSize = contentSize
            contentOffset = .zero
        }

        let outputSize = canvasSize

        // Cursor events are in screen-point coordinates (CGEvent.location), but the
        // video is captured at 2× (or Nx) resolution. Compute scale factors to map
        // point-space cursor positions into output pixel coordinates.
        let screenSize = session.screenSize
        let coordScaleX: CGFloat = screenSize.width > 0 ? contentSize.width / screenSize.width : 1.0
        let coordScaleY: CGFloat = screenSize.height > 0 ? contentSize.height / screenSize.height : 1.0

        // 4. Set up AVAssetReader
        let assetReader: AVAssetReader
        do {
            assetReader = try AVAssetReader(asset: sourceAsset)
        } catch {
            throw ExportError.assetReaderSetupFailed(error.localizedDescription)
        }
        reader = assetReader

        let readerOutputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        let readerOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: readerOutputSettings
        )
        readerOutput.alwaysCopiesSampleData = false
        videoReaderOutput = readerOutput

        guard assetReader.canAdd(readerOutput) else {
            throw ExportError.assetReaderSetupFailed("Cannot add video output to reader")
        }
        assetReader.add(readerOutput)

        // 5. Set up AVAssetWriter
        let fm = FileManager.default
        if fm.fileExists(atPath: config.outputURL.path) {
            try? fm.removeItem(at: config.outputURL)
        }

        let assetWriter: AVAssetWriter
        do {
            assetWriter = try AVAssetWriter(outputURL: config.outputURL, fileType: config.fileFormat.avFileType)
        } catch {
            throw ExportError.assetWriterSetupFailed(error.localizedDescription)
        }
        writer = assetWriter

        // 6. Create video input + pixel buffer adaptor
        let videoSettings = videoWriterSettings(
            codec: config.codec,
            quality: config.quality,
            size: outputSize
        )
        let vidInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vidInput.expectsMediaDataInRealTime = false
        videoInput = vidInput

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(outputSize.width),
            kCVPixelBufferHeightKey as String: Int(outputSize.height),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vidInput,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )
        pixelBufferAdaptor = adaptor

        guard assetWriter.canAdd(vidInput) else {
            throw ExportError.assetWriterSetupFailed("Cannot add video input to writer")
        }
        assetWriter.add(vidInput)

        // 7. Add audio tracks (passthrough — no re-encoding)
        try await addAudioTracks(to: assetWriter, session: session, editor: editorState)

        // 8. Start reading and writing
        guard assetReader.startReading() else {
            throw ExportError.assetReaderSetupFailed(
                assetReader.error?.localizedDescription ?? "Unknown reader error"
            )
        }

        guard assetWriter.startWriting() else {
            throw ExportError.assetWriterSetupFailed(
                assetWriter.error?.localizedDescription ?? "Unknown writer error"
            )
        }
        assetWriter.startSession(atSourceTime: .zero)

        // 9. Process all tracks via requestMediaDataWhenReady + DispatchGroup.
        //    Video and each audio track run on dedicated serial queues.
        //    DispatchGroup coordinates completion; ResumeOnce bridges back to async.

        let completionGroup = DispatchGroup()

        // Prepare nonisolated(unsafe) captures for GCD callbacks
        nonisolated(unsafe) let capturedReaderOutput = readerOutput
        nonisolated(unsafe) let capturedVidInput = vidInput
        nonisolated(unsafe) let capturedAdaptor = adaptor
        nonisolated(unsafe) let capturedWriter = assetWriter
        nonisolated(unsafe) let capturedRenderer = metalRenderer
        nonisolated(unsafe) let capturedCursorTexture = cursorTexture
        nonisolated(unsafe) let capturedWebcamOutput = webcamReaderOutput
        nonisolated(unsafe) let capturedWebcamReader = webcamAssetReader

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumer = ResumeOnce(continuation)

            // Enter all groups upfront before any processing starts
            completionGroup.enter() // video
            for _ in self.audioPairs {
                completionGroup.enter()
            }

            // --- Video track ---
            let videoQueue = DispatchQueue(label: "com.kinshasa.export.video")
            nonisolated(unsafe) var previousCursorPos = CGPoint(x: -100, y: -100)
            nonisolated(unsafe) var lastWebcamCGImage: CGImage? = nil
            nonisolated(unsafe) var lastWebcamTime: Double = -1.0
            // Use the same broadcast-style lazy camera as the preview so zoom
            // framing matches exactly. The tracker is only called from videoQueue.
            nonisolated(unsafe) let exportCameraTracker = CameraTracker()

            capturedVidInput.requestMediaDataWhenReady(on: videoQueue) { [self] in
                while capturedVidInput.isReadyForMoreMediaData {
                    // Check cancellation
                    if self.isCancelled {
                        capturedWebcamReader?.cancelReading()
                        capturedVidInput.markAsFinished()
                        completionGroup.leave()
                        resumer.fail(ExportError.cancelled)
                        return
                    }

                    // Check writer health
                    guard capturedWriter.status == .writing else {
                        capturedVidInput.markAsFinished()
                        completionGroup.leave()
                        resumer.fail(ExportError.writerFailed(
                            capturedWriter.error?.localizedDescription ?? "Writer not in writing state"
                        ))
                        return
                    }

                    guard let sampleBuffer = capturedReaderOutput.copyNextSampleBuffer() else {
                        // End of video stream
                        capturedVidInput.markAsFinished()
                        completionGroup.leave()
                        return
                    }

                    autoreleasepool {
                        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                        let timeSeconds = presentationTime.seconds

                        // Skip frames in disabled segments
                        if self.isInDisabledSegment(time: timeSeconds, segments: editorState.segments) {
                            return // from autoreleasepool, not from outer while
                        }

                        // Report progress
                        if totalDuration > 0 {
                            progress(min(timeSeconds / totalDuration, 1.0))
                        }

                        // Get source pixel buffer
                        guard let sourcePixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                            return
                        }

                        // Compute zoom level
                        let zoomLevel = MetalVideoRenderer.interpolateZoom(
                            at: timeSeconds,
                            keyframes: editorState.zoomKeyframes,
                            rampDuration: MetalVideoRenderer.cinematicRampDuration
                        )

                        // Compute cursor position (map from screen points → output pixels)
                        var cursorPosition: CGPoint?
                        // Raw position before smoothing — used for CameraTracker
                        // to match preview behavior (preview feeds raw cursor to tracker).
                        var rawCursorContentPos: CGPoint?
                        if let cursorData, !cursorData.events.isEmpty {
                            cursorPosition = self.interpolatedCursorPosition(
                                at: timeSeconds,
                                events: cursorData.events
                            )

                            // Scale from point coordinates to output pixel coordinates
                            if let pos = cursorPosition {
                                let scaled = CGPoint(
                                    x: pos.x * coordScaleX,
                                    y: pos.y * coordScaleY
                                )
                                cursorPosition = scaled
                                rawCursorContentPos = scaled
                            }

                            if editorState.cursorSmoothingEnabled, let pos = cursorPosition {
                                let smoothed = MetalVideoRenderer.smoothCursorPosition(
                                    previous: previousCursorPos,
                                    current: pos
                                )
                                cursorPosition = smoothed
                                previousCursorPos = smoothed
                            }
                        }

                        // Compute click highlight phase (expanding ring)
                        var clickPhase: Double = 0
                        // Compute cursor click scale (press animation matching CursorOverlayView)
                        var cursorClickScale: Double = 1.0
                        if editorState.clickHighlightEnabled, let cursorData {
                            let clickWindow = 0.15
                            let clickAnimDuration = 0.25
                            let clickPressDepth = 0.25

                            if let clickEvent = cursorData.events.first(where: {
                                $0.click != nil && $0.t <= timeSeconds && (timeSeconds - $0.t) < max(clickWindow, clickAnimDuration)
                            }) {
                                // Click highlight ring
                                let elapsed = timeSeconds - clickEvent.t
                                if elapsed >= 0 && elapsed < clickWindow {
                                    clickPhase = 1.0 - (elapsed / clickWindow)
                                }

                                // Cursor press animation (shrink then bounce back)
                                if elapsed >= 0 && elapsed < clickAnimDuration {
                                    let progress = elapsed / clickAnimDuration
                                    let pressAmount = sin(.pi * sqrt(progress))
                                    cursorClickScale = 1.0 - clickPressDepth * pressAmount
                                }
                            }
                        }

                        // Use the same broadcast-style lazy camera as the preview.
                        // CameraTracker produces a normalized anchor (0-1) that the
                        // shader uses as zoom center. Feed RAW cursor (before smoothing)
                        // to match preview behavior where CameraTracker gets unsmoothed input.
                        let cursorNormX: Double
                        let cursorNormY: Double
                        if let rawPos = rawCursorContentPos {
                            cursorNormX = rawPos.x / contentSize.width
                            cursorNormY = rawPos.y / contentSize.height
                        } else {
                            cursorNormX = 0.5
                            cursorNormY = 0.5
                        }

                        let anchor = exportCameraTracker.update(
                            cursorNormX: cursorNormX,
                            cursorNormY: cursorNormY,
                            zoomLevel: zoomLevel,
                            timestamp: timeSeconds
                        )
                        let zoomCenter = CGPoint(x: anchor.x, y: anchor.y)

                        // Transform cursor position from source-space to zoomed content-space.
                        // The shader zooms the video content, so the cursor must track where
                        // its source position appears in the zoomed view.
                        if zoomLevel > 1.0, let pos = cursorPosition {
                            let normalizedX = pos.x / contentSize.width
                            let normalizedY = pos.y / contentSize.height
                            // Inverse of shader's: sourceUV = center + (outUV - center) * invZoom
                            let zoomedX = zoomCenter.x + (normalizedX - zoomCenter.x) * zoomLevel
                            let zoomedY = zoomCenter.y + (normalizedY - zoomCenter.y) * zoomLevel
                            cursorPosition = CGPoint(
                                x: zoomedX * contentSize.width + contentOffset.x,
                                y: zoomedY * contentSize.height + contentOffset.y
                            )
                        } else if let pos = cursorPosition {
                            // No zoom: offset cursor into canvas space
                            cursorPosition = CGPoint(
                                x: pos.x + contentOffset.x,
                                y: pos.y + contentOffset.y
                            )
                        }

                        let clickColor = SIMD4<Float>(
                            1.0, 0.8, 0.0,
                            Float(editorState.clickHighlightOpacity)
                        )

                        // Zero-copy render path:
                        // 1. Get pixel buffer from writer's pool (IOSurface-backed)
                        guard let pool = capturedAdaptor.pixelBufferPool else {
                            Self.logger.warning("Pixel buffer pool unavailable at \(timeSeconds)s")
                            return
                        }
                        var outputPixelBuffer: CVPixelBuffer?
                        let pbStatus = CVPixelBufferPoolCreatePixelBuffer(
                            kCFAllocatorDefault, pool, &outputPixelBuffer
                        )
                        guard pbStatus == kCVReturnSuccess, let outputPB = outputPixelBuffer else {
                            Self.logger.warning("Failed to get pixel buffer from pool at \(timeSeconds)s")
                            return
                        }

                        // 2. Create Metal texture from the pixel buffer's IOSurface
                        guard let outputTexture = self.makeOutputTexture(from: outputPB, size: outputSize) else {
                            Self.logger.warning("Failed to create output texture at \(timeSeconds)s")
                            return
                        }

                        // 3. Render directly into the pixel buffer's memory — zero CPU copies.
                        // Cursor overlay is rendered via Core Graphics (step 3b) for
                        // pixel-perfect vector quality matching the SwiftUI preview.
                        // Click highlight still renders in Metal using cursorPosition.
                        let cursorSizeScale = coordScaleX * zoomLevel
                        let success = capturedRenderer.renderIntoTexture(
                            sourcePixelBuffer: sourcePixelBuffer,
                            outputTexture: outputTexture,
                            zoomCenter: zoomCenter,
                            zoomLevel: zoomLevel,
                            cursorPosition: cursorPosition,
                            cursorScale: editorState.cursorScale * cursorSizeScale,
                            cursorClickScale: cursorClickScale,
                            renderCursorOverlay: false,
                            clickPhase: clickPhase,
                            clickColor: clickColor,
                            clickRadius: 30.0 * cursorSizeScale,
                            cursorTexture: capturedCursorTexture,
                            contentOffset: contentOffset
                        )

                        guard success else {
                            Self.logger.warning("Metal render failed for frame at \(timeSeconds)s")
                            return
                        }

                        // 3b. Composite cursor using Core Graphics for crisp vector rendering
                        if let pos = cursorPosition {
                            Self.compositeCursor(
                                onto: outputPB,
                                outputSize: outputSize,
                                position: pos,
                                cursorScale: editorState.cursorScale,
                                cursorSizeScale: cursorSizeScale,
                                clickScale: cursorClickScale,
                                style: editorState.cursorStyle
                            )
                        }

                        // 3c. Composite webcam overlay (CPU, Core Graphics)
                        // Apply webcamStartOffset: webcam starts recording AFTER screen,
                        // so subtract the delay to align webcam with composition time.
                        if let webcamOut = capturedWebcamOutput {
                            let webcamTimeSeconds = max(0, timeSeconds - editorState.webcamStartOffset)
                            if let webcamImage = Self.advanceWebcamReader(
                                output: webcamOut,
                                toTime: webcamTimeSeconds,
                                lastTime: &lastWebcamTime,
                                lastImage: &lastWebcamCGImage
                            ) {
                                Self.compositeWebcam(
                                    image: webcamImage,
                                    onto: outputPB,
                                    outputSize: outputSize,
                                    contentSize: contentSize,
                                    contentOffset: contentOffset,
                                    webcamScale: editorState.webcamScale,
                                    webcamPositionX: editorState.webcamPositionX,
                                    webcamPositionY: editorState.webcamPositionY
                                )
                            }
                        }

                        // 4. Append — the pixel buffer already contains the rendered data
                        guard capturedWriter.status == .writing else { return }
                        capturedAdaptor.append(outputPB, withPresentationTime: presentationTime)
                    }
                }
            }

            // --- Audio tracks ---
            for pair in self.audioPairs {
                let audioQueue = DispatchQueue(label: "com.kinshasa.export.audio.\(UUID().uuidString)")
                nonisolated(unsafe) let audioWriterInput = pair.input
                nonisolated(unsafe) let audioReaderOutput = pair.readerOutput
                audioWriterInput.requestMediaDataWhenReady(on: audioQueue) { [self] in
                    while audioWriterInput.isReadyForMoreMediaData {
                        if self.isCancelled {
                            audioWriterInput.markAsFinished()
                            completionGroup.leave()
                            return
                        }
                        guard capturedWriter.status == .writing else {
                            audioWriterInput.markAsFinished()
                            completionGroup.leave()
                            return
                        }
                        if let sampleBuffer = audioReaderOutput.copyNextSampleBuffer() {
                            _ = autoreleasepool {
                                audioWriterInput.append(sampleBuffer)
                            }
                        } else {
                            audioWriterInput.markAsFinished()
                            completionGroup.leave()
                            return
                        }
                    }
                }
            }

            // --- Finalization ---
            // When all tracks finish (video + audio), finalize the writer.
            completionGroup.notify(queue: .global()) { [self] in
                // Keep readers/assets alive until processing completes
                withExtendedLifetime(self.audioPairs) {}
                withExtendedLifetime((capturedWebcamReader, capturedWebcamOutput)) {}

                if self.isCancelled {
                    capturedWriter.cancelWriting()
                    resumer.fail(ExportError.cancelled)
                    return
                }

                capturedWriter.finishWriting {
                    if capturedWriter.status == .failed {
                        resumer.fail(ExportError.writerFailed(
                            capturedWriter.error?.localizedDescription ?? "Unknown writer error"
                        ))
                    } else {
                        resumer.succeed()
                    }
                }
            }
        }

        // Flush texture cache to release CVMetalTexture references
        if let cache = metalTextureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }

        progress(1.0)
        Self.logger.info("Export completed to \(config.outputURL.path)")
    }

    // MARK: - Audio Track Setup

    private func addAudioTracks(
        to writer: AVAssetWriter,
        session: RecordingSession,
        editor: EditorSnapshot
    ) async throws {
        let fm = FileManager.default

        // Microphone audio
        if !editor.micMuted && fm.fileExists(atPath: session.micAudioURL.path) {
            try await addAudioPair(
                url: session.micAudioURL,
                writer: writer,
                label: "mic"
            )
        }

        // System audio
        if !editor.systemMuted && fm.fileExists(atPath: session.systemAudioURL.path) {
            try await addAudioPair(
                url: session.systemAudioURL,
                writer: writer,
                label: "system"
            )
        }
    }

    /// Adds an audio reader/writer pair.
    /// For compressed sources (AAC), uses passthrough (no re-encoding).
    /// For uncompressed sources (PCM), decodes and re-encodes to AAC.
    private func addAudioPair(
        url: URL,
        writer: AVAssetWriter,
        label: String
    ) async throws {
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            Self.logger.warning("Failed to load \(label) audio tracks: \(error)")
            return
        }

        guard let audioTrack = tracks.first else {
            Self.logger.info("No \(label) audio track found, skipping")
            return
        }

        // Detect whether the source is compressed (AAC) or uncompressed (PCM).
        let formatDescriptions = try await audioTrack.load(.formatDescriptions)
        let isCompressed: Bool
        if let desc = formatDescriptions.first {
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)
            let formatID = asbd?.pointee.mFormatID ?? 0
            isCompressed = formatID != kAudioFormatLinearPCM
        } else {
            isCompressed = true // Assume compressed if we can't tell
        }

        let audioReader: AVAssetReader
        do {
            audioReader = try AVAssetReader(asset: asset)
        } catch {
            Self.logger.warning("Failed to create \(label) audio reader: \(error)")
            return
        }

        let readerOutput: AVAssetReaderTrackOutput
        let audioInput: AVAssetWriterInput

        if isCompressed {
            // Passthrough: compressed AAC buffers copied directly
            readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
        } else {
            // Decode PCM source to raw samples, then encode to AAC for export
            let decodingSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false,
            ]
            readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: decodingSettings)

            let encodingSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000,
            ]
            audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: encodingSettings)
        }

        audioInput.expectsMediaDataInRealTime = false

        guard audioReader.canAdd(readerOutput) else {
            Self.logger.warning("Cannot add \(label) audio reader output")
            return
        }
        audioReader.add(readerOutput)

        guard audioReader.startReading() else {
            Self.logger.warning("Cannot start reading \(label) audio")
            return
        }

        guard writer.canAdd(audioInput) else {
            Self.logger.warning("Cannot add \(label) audio input to writer")
            return
        }
        writer.add(audioInput)

        audioPairs.append((input: audioInput, readerOutput: readerOutput, reader: audioReader, asset: asset))
    }

    // MARK: - Resolved Size

    func resolvedSize(natural: CGSize, resolution: ExportResolution) -> CGSize {
        switch resolution {
        case .original:
            return natural
        case .p1080:
            let targetHeight: CGFloat = 1080
            let aspect = natural.width / natural.height
            let targetWidth = (targetHeight * aspect).rounded(.down)
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

    // MARK: - Webcam Compositing

    /// Advances the webcam reader to the given time, returning the most recent frame.
    /// Consumes samples up to the target time, keeping the last valid frame.
    private static func advanceWebcamReader(
        output: AVAssetReaderTrackOutput,
        toTime targetTime: Double,
        lastTime: inout Double,
        lastImage: inout CGImage?
    ) -> CGImage? {
        // If we're before the last consumed frame, return cached
        if targetTime <= lastTime {
            return lastImage
        }

        // Consume samples until we reach the target time.
        // Only create CGImage for the final frame to avoid wasting CPU
        // on intermediate frames that would be immediately discarded.
        var latestBuffer: CMSampleBuffer?

        while true {
            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                break // End of webcam stream — keep showing last frame
            }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            latestBuffer = sampleBuffer

            if pts >= targetTime {
                lastTime = pts
                break
            }
        }

        if let buffer = latestBuffer,
           let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) {
            var cgImage: CGImage?
            VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
            if let img = cgImage {
                lastImage = img
                lastTime = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            }
        }

        return lastImage
    }

    /// Composites a webcam CGImage as a circular overlay onto a pixel buffer.
    /// Called after Metal rendering — draws on top of the existing frame content.
    private static func compositeWebcam(
        image: CGImage,
        onto pixelBuffer: CVPixelBuffer,
        outputSize: CGSize,
        contentSize: CGSize = .zero,
        contentOffset: CGPoint = .zero,
        webcamScale: Double,
        webcamPositionX: Double,
        webcamPositionY: Double
    ) {
        let width = Int(outputSize.width)
        let height = Int(outputSize.height)

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        // Create CGContext from the pixel buffer (BGRA, premultiplied alpha)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGBitmapInfo.byteOrder32Little.rawValue |
            CGImageAlphaInfo.premultipliedFirst.rawValue
        )
        guard let ctx = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return }

        // Flip to top-left origin (video coordinate system)
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1.0, y: -1.0)

        // Calculate webcam circle geometry (matches WebcamEditorOverlay formula).
        // Position webcam relative to content area so it isn't drawn on black bars.
        let activeSize = contentSize.width > 0 ? contentSize : outputSize
        let diameter = min(activeSize.width, activeSize.height) * 0.18 * webcamScale
        let centerX = contentOffset.x + webcamPositionX * activeSize.width
        let centerY = contentOffset.y + webcamPositionY * activeSize.height
        let radius = diameter / 2.0

        let circleRect = CGRect(
            x: centerX - radius,
            y: centerY - radius,
            width: diameter,
            height: diameter
        )

        // 1. Draw shadow behind the circle
        ctx.saveGState()
        // Negative height because the context is Y-flipped (top-left origin)
        ctx.setShadow(
            offset: CGSize(width: 0, height: -2),
            blur: 6,
            color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.5)
        )

        // Fill a solid circle (generates the shadow)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fillEllipse(in: circleRect)
        ctx.restoreGState()

        // 2. Clip to circle and draw webcam image (aspect fill)
        ctx.saveGState()
        ctx.addEllipse(in: circleRect)
        ctx.clip()

        let imgWidth = CGFloat(image.width)
        let imgHeight = CGFloat(image.height)
        let imgAspect = imgWidth / imgHeight

        let drawRect: CGRect
        if imgAspect > 1.0 {
            // Image is wider: match height, crop sides
            let drawHeight = diameter
            let drawWidth = diameter * imgAspect
            drawRect = CGRect(
                x: centerX - drawWidth / 2.0,
                y: centerY - drawHeight / 2.0,
                width: drawWidth,
                height: drawHeight
            )
        } else {
            // Image is taller: match width, crop top/bottom
            let drawWidth = diameter
            let drawHeight = diameter / imgAspect
            drawRect = CGRect(
                x: centerX - drawWidth / 2.0,
                y: centerY - drawHeight / 2.0,
                width: drawWidth,
                height: drawHeight
            )
        }

        // Flip the image locally to counter CGImage's bottom-up orientation
        // in the already-flipped (top-left origin) context.
        ctx.translateBy(x: drawRect.origin.x, y: drawRect.origin.y + drawRect.height)
        ctx.scaleBy(x: 1.0, y: -1.0)
        ctx.draw(image, in: CGRect(origin: .zero, size: drawRect.size))
        ctx.restoreGState()

        // 3. White border ring
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.setLineWidth(2.0)
        let borderRect = circleRect.insetBy(dx: 1.0, dy: 1.0)
        ctx.strokeEllipse(in: borderRect)
    }

    // MARK: - Cursor Compositing

    /// Composites a vector-rendered cursor arrow onto a pixel buffer using Core Graphics.
    /// Produces pixel-perfect anti-aliased results matching the SwiftUI CursorOverlayView
    /// (which renders as vector shapes at display resolution).
    private static func compositeCursor(
        onto pixelBuffer: CVPixelBuffer,
        outputSize: CGSize,
        position: CGPoint,
        cursorScale: Double,
        cursorSizeScale: Double,
        clickScale: Double,
        style: CursorStyle
    ) {
        let width = Int(outputSize.width)
        let height = Int(outputSize.height)

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGBitmapInfo.byteOrder32Little.rawValue |
            CGImageAlphaInfo.premultipliedFirst.rawValue
        )
        guard let ctx = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return }

        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        ctx.interpolationQuality = .high

        // Flip to top-left origin (video coordinate system)
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1.0, y: -1.0)

        // Compute cursor size. In the SwiftUI preview:
        //   frame = 14 * cursorScale * clickScale  ×  20 * cursorScale * clickScale
        //   then .scaleEffect(zoomLevel) scales everything (including the 1.5pt stroke).
        // cursorSizeScale = coordScaleX * zoomLevel maps points→output pixels + zoom.
        let totalScale = cursorScale * cursorSizeScale * clickScale
        let cursorW = 14.0 * totalScale
        let cursorH = 20.0 * totalScale

        // Build cursor arrow path at exact output pixel size.
        // Same geometry as CursorShape in CursorOverlayView.
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: cursorH * 0.85))
        path.addLine(to: CGPoint(x: cursorW * 0.3, y: cursorH * 0.65))
        path.addLine(to: CGPoint(x: cursorW * 0.5, y: cursorH))
        path.addLine(to: CGPoint(x: cursorW * 0.7, y: cursorH * 0.92))
        path.addLine(to: CGPoint(x: cursorW * 0.48, y: cursorH * 0.58))
        path.addLine(to: CGPoint(x: cursorW * 0.9, y: cursorH * 0.55))
        path.closeSubpath()

        let fillColor = MetalVideoRenderer.cgColor(fromHex: style.fillHex)
        let strokeColor = MetalVideoRenderer.cgColor(fromHex: style.strokeHex)

        // In SwiftUI, stroke lineWidth = 1.5 (in the pre-zoom frame), then
        // .scaleEffect(zoom) scales it. So output stroke = 1.5 * cursorSizeScale.
        let strokeWidth = 1.5 * cursorSizeScale

        // Shadow matching CursorOverlayView: .shadow(color: .black.opacity(0.4), radius: 2, x: 1, y: 1)
        // Scale shadow parameters by cursorSizeScale to match .scaleEffect behavior.
        ctx.saveGState()
        ctx.translateBy(x: position.x, y: position.y)

        ctx.setShadow(
            offset: CGSize(width: cursorSizeScale, height: -cursorSizeScale),
            blur: 2.0 * cursorSizeScale,
            color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.4)
        )

        // Fill (shadow is applied to this draw call)
        ctx.addPath(path)
        ctx.setFillColor(fillColor)
        ctx.fillPath()

        // Turn off shadow for the stroke to avoid double-shadow
        ctx.setShadow(offset: .zero, blur: 0, color: nil)

        // Stroke with round joins/caps matching the preview
        ctx.addPath(path)
        ctx.setStrokeColor(strokeColor)
        ctx.setLineWidth(strokeWidth)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.strokePath()

        ctx.restoreGState()
    }

    // MARK: - Frame Helpers

    private func isInDisabledSegment(time: Double, segments: [TimelineSegment]) -> Bool {
        for segment in segments {
            if time >= segment.sourceStart && time < segment.sourceEnd {
                return !segment.enabled
            }
        }
        return false
    }

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
}
