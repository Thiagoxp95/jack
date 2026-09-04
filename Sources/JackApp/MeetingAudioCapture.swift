import AVFoundation
import AppKit
@preconcurrency import ScreenCaptureKit
import Foundation

/// Records a meeting as two parallel 16 kHz mono tracks — the microphone and
/// everything coming out of the speakers — sliced into chunks small enough for
/// a batch transcription request.
///
/// The two tracks stay separate all the way to the transcriber on purpose.
/// Muse's speaker labels are scoped to one request, so nothing stitches
/// "Speaker A" across chunk boundaries; keeping the microphone on its own track
/// means at least *you* are identified the same way for the whole meeting,
/// by construction rather than by clustering.
@MainActor
final class MeetingAudioCapture {

    /// One slice of the meeting: the same wall-clock window on both tracks.
    /// Either side may be nil when that track held nothing but silence.
    struct Chunk: Sendable {
        let index: Int
        let micURL: URL?
        let systemURL: URL?
        /// Seconds from the start of the meeting to the start of this chunk.
        let startOffset: TimeInterval
        let duration: TimeInterval
    }

    enum Failure: LocalizedError {
        case microphonePermissionDenied
        case screenRecordingPermissionDenied
        case noDisplayAvailable
        case micEngineFailed(String)
        case systemAudioFailed(String)

        var errorDescription: String? {
            switch self {
            case .microphonePermissionDenied:
                return "Microphone permission is required for meeting mode."
            case .screenRecordingPermissionDenied:
                return "Screen Recording permission is required to capture the other side of the call. Grant it in System Settings → Privacy & Security → Screen Recording, then restart Silky."
            case .noDisplayAvailable:
                return "No display available to attach system-audio capture to."
            case let .micEngineFailed(details):
                return "Could not start the microphone: \(details)"
            case let .systemAudioFailed(details):
                return "Could not start system-audio capture: \(details)"
            }
        }
    }

    /// 8 minutes: comfortably inside Muse's 10 minute / 32 MB per-file ceiling
    /// (a 16 kHz mono 16-bit chunk runs ~15 MB) while keeping the number of
    /// chunks — and so the number of independent speaker-label namespaces — as
    /// low as that ceiling allows.
    static let chunkDuration: TimeInterval = 8 * 60

    private(set) var isRunning = false
    /// Seconds since `start()` returned.
    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    /// Fires on the main actor each time a chunk closes, mid-meeting.
    var onChunkReady: ((Chunk) -> Void)?

    private var startedAt: Date?
    private var chunkIndex = 0
    private var chunkStartedAt: Date?
    private var rotationTimer: Timer?

    private let directory: URL
    private let micTrack = MeetingTrackWriter(label: "mic")
    private let systemTrack = MeetingTrackWriter(label: "system")

    private let engine = AVAudioEngine()
    private var micTapInstalled = false
    private var stream: SCStream?
    private var systemOutput: SystemAudioOutput?

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("silky-meetings/\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: - Permissions

    static var hasScreenRecordingPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Asks for Screen Recording. macOS only ever shows this prompt once per
    /// app version and answers `false` immediately, so a first "no" here means
    /// "the sheet is on screen", not "the user declined".
    @discardableResult
    static func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    // MARK: - Lifecycle

    func start() async throws {
        guard !isRunning else { return }

        guard await requestMicrophonePermission() else {
            throw Failure.microphonePermissionDenied
        }
        guard Self.hasScreenRecordingPermission || Self.requestScreenRecordingPermission() else {
            throw Failure.screenRecordingPermissionDenied
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        chunkIndex = 0
        micTrack.open(url: fileURL(track: "mic", chunk: 0))
        systemTrack.open(url: fileURL(track: "system", chunk: 0))

        do {
            try startMicrophone()
        } catch {
            closeTracks()
            throw Failure.micEngineFailed(error.localizedDescription)
        }

        do {
            try await startSystemAudio()
        } catch {
            stopMicrophone()
            closeTracks()
            throw Failure.systemAudioFailed(error.localizedDescription)
        }

        let now = Date()
        startedAt = now
        chunkStartedAt = now
        isRunning = true
        scheduleRotation()
    }

    /// Stops both tracks and returns the final partial chunk, if it holds sound.
    func stop() async -> Chunk? {
        guard isRunning else { return nil }
        isRunning = false

        rotationTimer?.invalidate()
        rotationTimer = nil

        stopMicrophone()
        await stopSystemAudio()

        let chunk = closeChunk()
        startedAt = nil
        chunkStartedAt = nil
        return chunk
    }

    /// Tears everything down and deletes the working directory. Safe to call
    /// twice; used both after a normal stop and when a meeting is abandoned.
    func discard() async {
        _ = await stop()
        closeTracks()
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Chunking

    private func scheduleRotation() {
        rotationTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.chunkDuration, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rotateChunk()
            }
        }
        // Chunk rotation must keep firing while menus or the settings window
        // are tracking, or a meeting held with a menu open overruns the limit.
        RunLoop.main.add(timer, forMode: .common)
        rotationTimer = timer
    }

    private func rotateChunk() {
        guard isRunning else { return }
        let finished = closeChunk()
        chunkIndex += 1
        chunkStartedAt = Date()
        micTrack.open(url: fileURL(track: "mic", chunk: chunkIndex))
        systemTrack.open(url: fileURL(track: "system", chunk: chunkIndex))
        if let finished {
            onChunkReady?(finished)
        }
    }

    /// Closes both writers and packages what they produced. Silent tracks are
    /// deleted rather than uploaded — Muse bills per processed minute, and a
    /// muted microphone would otherwise cost as much as a talkative one.
    private func closeChunk() -> Chunk? {
        let mic = micTrack.close()
        let system = systemTrack.close()
        let startOffset = (chunkStartedAt?.timeIntervalSince(startedAt ?? Date())) ?? 0
        let duration = max(mic?.duration ?? 0, system?.duration ?? 0)

        let micURL = usableURL(mic)
        let systemURL = usableURL(system)
        guard micURL != nil || systemURL != nil else { return nil }

        return Chunk(
            index: chunkIndex,
            micURL: micURL,
            systemURL: systemURL,
            startOffset: max(0, startOffset),
            duration: duration
        )
    }

    private func usableURL(_ track: MeetingTrackWriter.Finished?) -> URL? {
        guard let track else { return nil }
        guard track.duration >= 0.5, track.peak >= MeetingTrackWriter.silenceFloor else {
            try? FileManager.default.removeItem(at: track.url)
            return nil
        }
        return track.url
    }

    private func closeTracks() {
        _ = micTrack.close()
        _ = systemTrack.close()
    }

    private func fileURL(track: String, chunk: Int) -> URL {
        directory.appendingPathComponent(String(format: "%@-%03d.wav", track, chunk))
    }

    // MARK: - Microphone

    private func requestMicrophonePermission() async -> Bool {
        if #available(macOS 14.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                return true
            case .undetermined:
                return await withCheckedContinuation { continuation in
                    AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
                }
            default:
                return false
            }
        }
        return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    private func startMicrophone() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw Failure.micEngineFailed("input device reported no sample rate")
        }

        let track = micTrack
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { buffer, _ in
            track.append(buffer)
        }
        micTapInstalled = true

        engine.prepare()
        try engine.start()
    }

    private func stopMicrophone() {
        if micTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            micTapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
    }

    // MARK: - System audio

    private func startSystemAudio() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw Failure.noDisplayAvailable
        }

        // Audio-only capture still needs a content filter and still runs a
        // video path, so the frames are shrunk to nothing and slowed to one a
        // second. Silky's own output is excluded so its sounds — and any
        // playback of a meeting — never loop back into the recording.
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3

        let output = SystemAudioOutput(writer: systemTrack)
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(
            output,
            type: .audio,
            sampleHandlerQueue: DispatchQueue(label: "com.jack.meeting.system-audio")
        )
        try await stream.startCapture()

        self.stream = stream
        systemOutput = output
    }

    private func stopSystemAudio() async {
        guard let stream else { return }
        self.stream = nil
        systemOutput = nil
        try? await stream.stopCapture()
    }
}

// MARK: - SystemAudioOutput

/// Bridges ScreenCaptureKit's CMSampleBuffers onto a track writer. Lives on
/// ScreenCaptureKit's own queue, so it holds nothing but the (thread-safe)
/// writer.
private final class SystemAudioOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let writer: MeetingTrackWriter

    init(writer: MeetingTrackWriter) {
        self.writer = writer
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let buffer = Self.pcmBuffer(from: sampleBuffer) else { return }
        writer.append(buffer)
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(description)
        else { return nil }

        var asbd = asbdPointer.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }

        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }
}

// MARK: - MeetingTrackWriter

/// One track's rolling WAV file. Audio arrives on a capture queue and chunk
/// rotation happens on the main actor, so every operation takes the same lock.
///
/// Input arrives at whatever rate and channel count the device or the system
/// mixer happens to use; everything is converted to the 16 kHz mono the
/// transcription endpoint wants before it is written, so no chunk needs a
/// second pass before upload.
final class MeetingTrackWriter: @unchecked Sendable {

    /// Peak amplitude below which a chunk is treated as silence and dropped.
    /// About -46 dBFS: quiet enough to keep a whisper, loud enough to discard
    /// an idle microphone's self-noise.
    static let silenceFloor: Float = 0.005

    struct Finished: Sendable {
        let url: URL
        let duration: TimeInterval
        let peak: Float
    }

    private let label: String
    private let lock = NSLock()
    private let targetFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!

    private var file: AVAudioFile?
    private var url: URL?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var framesWritten: AVAudioFramePosition = 0
    private var peak: Float = 0

    init(label: String) {
        self.label = label
    }

    func open(url: URL) {
        lock.lock()
        defer { lock.unlock() }

        closeLocked()
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
        ]
        do {
            file = try AVAudioFile(forWriting: url, settings: settings)
            self.url = url
            framesWritten = 0
            peak = 0
        } catch {
            NSLog("[Silky] Meeting %@ track could not open %@: %@", label, url.lastPathComponent, String(describing: error))
            file = nil
            self.url = nil
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }

        guard let file, buffer.frameLength > 0 else { return }
        guard let converted = convertLocked(buffer) else { return }

        do {
            try file.write(from: converted)
            framesWritten += AVAudioFramePosition(converted.frameLength)
            peak = max(peak, Self.peakAmplitude(of: converted))
        } catch {
            NSLog("[Silky] Meeting %@ track write failed: %@", label, String(describing: error))
        }
    }

    @discardableResult
    func close() -> Finished? {
        lock.lock()
        defer { lock.unlock() }
        return closeLocked()
    }

    @discardableResult
    private func closeLocked() -> Finished? {
        defer {
            file = nil
            url = nil
            framesWritten = 0
            peak = 0
        }
        guard let url, file != nil else { return nil }
        return Finished(
            url: url,
            duration: Double(framesWritten) / targetFormat.sampleRate,
            peak: peak
        )
    }

    // MARK: - Conversion

    private func convertLocked(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == targetFormat { return buffer }

        if converter == nil || converterInputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            converterInputFormat = buffer.format
        }
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        // The extra frame absorbs the resampler's rounding; a short output
        // buffer makes AVAudioConverter fail the whole call.
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard capacity > 0, let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, output.frameLength > 0 else {
            if let conversionError {
                NSLog("[Silky] Meeting %@ track conversion failed: %@", label, conversionError.localizedDescription)
            }
            return nil
        }
        return output
    }

    private static func peakAmplitude(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        var maximum: Float = 0
        for frame in 0 ..< Int(buffer.frameLength) {
            maximum = max(maximum, abs(channel[frame]))
        }
        return maximum
    }
}
