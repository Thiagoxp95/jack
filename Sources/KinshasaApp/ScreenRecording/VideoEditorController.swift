import AVFoundation
import CoreGraphics
import Foundation
import os

// MARK: - EditorSnapshot

struct EditorSnapshot {
    let segments: [TimelineSegment]
    let zoomKeyframes: [ZoomKeyframe]
    let markers: [TimelineMarker]
    let cursorScale: Double
    let cursorStyle: CursorStyle
    let clickHighlightEnabled: Bool
    let clickHighlightOpacity: Double
    let cursorSmoothingEnabled: Bool
    let micVolume: Float
    let systemVolume: Float
    let micMuted: Bool
    let systemMuted: Bool
    let webcamEnabled: Bool
    let webcamScale: Double
    let webcamPositionX: Double
    let webcamPositionY: Double
    let webcamStartOffset: TimeInterval
}

// MARK: - VideoEditorController

@Observable
@MainActor
final class VideoEditorController {

    // MARK: - State

    private(set) var duration: TimeInterval = 0
    private(set) var isPlaying = false
    var currentTime: TimeInterval = 0

    var segments: [TimelineSegment] = []
    var zoomKeyframes: [ZoomKeyframe] = []
    var markers: [TimelineMarker] = []
    var selectedSegmentID: UUID?
    var isBladeMode: Bool = false

    // Timeline zoom
    var timelineScale: CGFloat = 1.0
    var timelineScrollOffset: CGFloat = 0

    // Waveform data (pre-computed at load)
    private(set) var micWaveform: [Float] = []
    private(set) var systemWaveform: [Float] = []
    private(set) var waveformSamplesPerSecond: Double = 200

    var cursorScale: Double = 1.5
    var cursorStyle: CursorStyle = .white
    var clickHighlightEnabled: Bool = true
    var clickHighlightOpacity: Double = 0.3
    var cursorSmoothingEnabled: Bool = true

    /// Timestamp of the last `currentTime` sync from AVPlayer.
    /// Used for predictive timing between observer callbacks.
    var lastTimeSyncDate: Date = .now

    /// During playback, predicts the current time by extrapolating from the
    /// last AVPlayer sync using wall-clock elapsed time. This provides
    /// sub-frame accuracy so the cursor can be rendered at display refresh rate.
    var smoothTime: TimeInterval {
        guard isPlaying else { return currentTime }
        let elapsed = Date.now.timeIntervalSince(lastTimeSyncDate)
        return min(currentTime + elapsed, duration)
    }

    var micVolume: Float = 1.0
    var systemVolume: Float = 1.0
    var micMuted: Bool = false
    var systemMuted: Bool = false

    var aspectRatio: ExportAspectRatio = .original

    var webcamEnabled: Bool = true
    var webcamScale: Double = 1.0
    /// Relative X position (0 = left, 1 = right)
    var webcamPositionX: Double = 0.08
    /// Relative Y position (0 = top, 1 = bottom)
    var webcamPositionY: Double = 0.88

    private(set) var cursorData: CursorTrackingData?
    private(set) var hasWebcamRecording = false
    private(set) var webcamPlayer: AVPlayer?
    /// Seconds to skip at the start of the webcam file to compensate for
    /// AVCaptureMovieFileOutput's pre-recording buffer. Computed in load()
    /// as max(0, webcamDuration − screenDuration).
    private(set) var webcamStartOffset: TimeInterval = 0

    // AVMutableComposition: single timeline with screen video + audio tracks
    private(set) var composition: AVMutableComposition?
    private(set) var audioMix: AVMutableAudioMix?
    private var micTrackID: CMPersistentTrackID?
    private var systemTrackID: CMPersistentTrackID?

    // MARK: - Private

    let session: RecordingSession
    private var playbackTask: Task<Void, Never>?
    private var undoStack: [EditorSnapshot] = []
    private var redoStack: [EditorSnapshot] = []

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.kinshasa",
        category: "VideoEditor"
    )

    // MARK: - Init

    init(session: RecordingSession) {
        self.session = session
    }

    // MARK: - Loading

    func load() async {
        // Load video duration from AVURLAsset
        let screenAsset = AVURLAsset(url: session.screenVideoURL)
        do {
            let cmDuration = try await screenAsset.load(.duration)
            duration = cmDuration.seconds
        } catch {
            Self.logger.error("Failed to load video duration: \(error)")
            duration = session.duration
        }

        // Build AVMutableComposition: one timeline with screen video + audio tracks
        let comp = AVMutableComposition()
        let screenDuration = CMTime(seconds: duration, preferredTimescale: 600)

        // Add screen video track
        do {
            let screenVideoTracks = try await screenAsset.loadTracks(withMediaType: .video)
            if let sourceTrack = screenVideoTracks.first {
                let compTrack = comp.addMutableTrack(
                    withMediaType: .video,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                )
                try compTrack?.insertTimeRange(
                    CMTimeRange(start: .zero, duration: screenDuration),
                    of: sourceTrack,
                    at: .zero
                )
                Self.logger.fault("[Editor] Screen video track added to composition")
            }
        } catch {
            Self.logger.error("Failed to add screen video track: \(error)")
        }

        // Add mic audio track
        let micAudioURL = session.micAudioURL
        if FileManager.default.fileExists(atPath: micAudioURL.path) {
            do {
                let micAsset = AVURLAsset(url: micAudioURL)
                let micAudioTracks = try await micAsset.loadTracks(withMediaType: .audio)
                if let sourceTrack = micAudioTracks.first {
                    let compTrack = comp.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    )
                    let micDuration = try await micAsset.load(.duration)
                    let insertDuration = CMTimeMinimum(micDuration, screenDuration)
                    try compTrack?.insertTimeRange(
                        CMTimeRange(start: .zero, duration: insertDuration),
                        of: sourceTrack,
                        at: .zero
                    )
                    micTrackID = compTrack?.trackID
                    Self.logger.fault("[Editor] Mic audio track added to composition (trackID=\(self.micTrackID ?? -1))")
                }
            } catch {
                Self.logger.error("Failed to add mic audio track: \(error)")
            }
        }

        // Add system audio track
        let sysAudioURL = session.systemAudioURL
        if FileManager.default.fileExists(atPath: sysAudioURL.path) {
            do {
                let sysAsset = AVURLAsset(url: sysAudioURL)
                let sysAudioTracks = try await sysAsset.loadTracks(withMediaType: .audio)
                if let sourceTrack = sysAudioTracks.first {
                    let compTrack = comp.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    )
                    let sysDuration = try await sysAsset.load(.duration)
                    let insertDuration = CMTimeMinimum(sysDuration, screenDuration)
                    try compTrack?.insertTimeRange(
                        CMTimeRange(start: .zero, duration: insertDuration),
                        of: sourceTrack,
                        at: .zero
                    )
                    systemTrackID = compTrack?.trackID
                    Self.logger.fault("[Editor] System audio track added to composition (trackID=\(self.systemTrackID ?? -1))")
                }
            } catch {
                Self.logger.error("Failed to add system audio track: \(error)")
            }
        }

        composition = comp
        rebuildAudioMix()

        // Check for webcam recording and set up player (separate — visual overlay only)
        let webcamURL = session.webcamVideoURL
        let webcamExists = FileManager.default.fileExists(atPath: webcamURL.path)
        let webcamSize = (try? FileManager.default.attributesOfItem(atPath: webcamURL.path)[.size] as? Int) ?? 0
        Self.logger.fault("[Editor] Webcam file: exists=\(webcamExists), size=\(webcamSize), path=\(webcamURL.path)")
        hasWebcamRecording = webcamExists && webcamSize > 0

        if hasWebcamRecording {
            let asset = AVURLAsset(url: webcamURL)
            let item = AVPlayerItem(asset: asset)
            let p = AVPlayer(playerItem: item)
            p.actionAtItemEnd = .pause
            p.isMuted = true
            webcamPlayer = p

            // Compute webcam start delay: the webcam starts recording AFTER the screen
            // (screen capture is async-awaited before mic/webcam start). The delay is the
            // difference in file durations. In playback, we subtract this from composition
            // time to align the webcam with the audio.
            do {
                let webcamDuration = try await asset.load(.duration).seconds
                webcamStartOffset = max(0, duration - webcamDuration)
                let msg = "[WEBCAM-OFFSET] webcamDuration=\(String(format: "%.3f", webcamDuration))s screenDuration=\(String(format: "%.3f", duration))s delay=\(String(format: "%.3f", webcamStartOffset))s"
                print(msg)
                Self.logger.fault("\(msg)")
            } catch {
                print("[WEBCAM-OFFSET] ERROR loading webcam duration: \(error)")
                Self.logger.error("Failed to load webcam duration for offset: \(error)")
                webcamStartOffset = 0
            }
        }

        // Load cursor data from JSON
        let cursorURL = session.cursorDataURL
        if FileManager.default.fileExists(atPath: cursorURL.path) {
            do {
                let data = try Data(contentsOf: cursorURL)
                cursorData = try JSONDecoder().decode(CursorTrackingData.self, from: data)
                Self.logger.info("Loaded cursor data with \(self.cursorData?.events.count ?? 0) events")
            } catch {
                Self.logger.error("Failed to load cursor data: \(error)")
            }
        }

        // Initialize segments (one segment covering full duration)
        if segments.isEmpty {
            segments = [TimelineSegment(sourceStart: 0, sourceEnd: duration)]
        }

        // Load audio waveforms
        micWaveform = await loadWaveform(url: session.micAudioURL)
        systemWaveform = await loadWaveform(url: session.systemAudioURL)
    }

    // MARK: - Audio Mix

    /// Rebuilds the AVAudioMix from current volume/mute state.
    /// Called when volumes change — triggers @Observable update so MetalPreviewView reapplies.
    func rebuildAudioMix() {
        guard let comp = composition else { return }
        var params: [AVMutableAudioMixInputParameters] = []

        if let trackID = micTrackID,
           let track = comp.track(withTrackID: trackID) {
            let p = AVMutableAudioMixInputParameters(track: track)
            let vol = micMuted ? Float(0) : micVolume
            p.setVolume(vol, at: .zero)
            params.append(p)
        }

        if let trackID = systemTrackID,
           let track = comp.track(withTrackID: trackID) {
            let p = AVMutableAudioMixInputParameters(track: track)
            let vol = systemMuted ? Float(0) : systemVolume
            p.setVolume(vol, at: .zero)
            params.append(p)
        }

        let mix = AVMutableAudioMix()
        mix.inputParameters = params
        audioMix = mix
    }

    // MARK: - Waveform Loading

    private func loadWaveform(url: URL) async -> [Float] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            let frameCount = AVAudioFrameCount(file.length)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return [] }
            try file.read(into: buffer)

            guard let floatData = buffer.floatChannelData?[0] else { return [] }
            let sampleRate = format.sampleRate
            let samplesPerBucket = Int(sampleRate / waveformSamplesPerSecond)
            guard samplesPerBucket > 0 else { return [] }

            let bucketCount = Int(frameCount) / samplesPerBucket
            var waveform = [Float](repeating: 0, count: bucketCount)
            for i in 0..<bucketCount {
                var peak: Float = 0
                let start = i * samplesPerBucket
                let end = min(start + samplesPerBucket, Int(frameCount))
                for j in start..<end {
                    let val = abs(floatData[j])
                    if val > peak { peak = val }
                }
                waveform[i] = peak
            }
            return waveform
        } catch {
            Self.logger.error("Failed to load waveform: \(error)")
            return []
        }
    }

    // MARK: - Playback

    func play() {
        guard !isPlaying else { return }

        // If at the end, restart from beginning
        if currentTime >= duration {
            currentTime = 0
        }

        isPlaying = true
        // AVPlayer playback is driven by MetalPreviewView's coordinator
        // which observes isPlaying and syncs currentTime back via time observer
    }

    func pause() {
        isPlaying = false
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    // MARK: - Stepping

    func stepForward() {
        pause()
        currentTime = min(currentTime + 1.0 / 60.0, duration)
    }

    func stepBackward() {
        pause()
        currentTime = max(currentTime - 1.0 / 60.0, 0)
    }

    // MARK: - Segment Helpers

    /// Total edited duration (sum of enabled segments)
    var editedDuration: TimeInterval {
        segments.filter(\.enabled).reduce(0) { $0 + $1.sourceDuration }
    }

    /// Convert edited-timeline time to source time
    func sourceTime(forEditedTime editedTime: TimeInterval) -> TimeInterval {
        var accumulated: TimeInterval = 0
        for segment in segments where segment.enabled {
            let segDur = segment.sourceDuration
            if accumulated + segDur > editedTime {
                return segment.sourceStart + (editedTime - accumulated)
            }
            accumulated += segDur
        }
        return segments.last?.sourceEnd ?? 0
    }

    /// Convert source time to edited-timeline time
    func editedTime(forSourceTime sourceTime: TimeInterval) -> TimeInterval? {
        var accumulated: TimeInterval = 0
        for segment in segments where segment.enabled {
            if sourceTime >= segment.sourceStart && sourceTime < segment.sourceEnd {
                return accumulated + (sourceTime - segment.sourceStart)
            }
            accumulated += segment.sourceDuration
        }
        return nil
    }

    /// The segment containing a given source time
    func segment(atSourceTime time: TimeInterval) -> TimelineSegment? {
        segments.first { $0.sourceStart <= time && time < $0.sourceEnd }
    }

    // MARK: - Blade / Split

    func splitAtPlayhead() {
        let srcTime = sourceTime(forEditedTime: currentTime)
        guard let idx = segments.firstIndex(where: { $0.sourceStart < srcTime && srcTime < $0.sourceEnd }) else { return }
        pushSnapshot()
        let seg = segments[idx]
        let left = TimelineSegment(sourceStart: seg.sourceStart, sourceEnd: srcTime, enabled: seg.enabled)
        let right = TimelineSegment(sourceStart: srcTime, sourceEnd: seg.sourceEnd, enabled: seg.enabled)
        segments.replaceSubrange(idx...idx, with: [left, right])
    }

    func splitAtSourceTime(_ srcTime: TimeInterval) {
        guard let idx = segments.firstIndex(where: { $0.sourceStart < srcTime && srcTime < $0.sourceEnd }) else { return }
        pushSnapshot()
        let seg = segments[idx]
        let left = TimelineSegment(sourceStart: seg.sourceStart, sourceEnd: srcTime, enabled: seg.enabled)
        let right = TimelineSegment(sourceStart: srcTime, sourceEnd: seg.sourceEnd, enabled: seg.enabled)
        segments.replaceSubrange(idx...idx, with: [left, right])
    }

    func deleteSelectedSegment() {
        guard let selID = selectedSegmentID,
              let idx = segments.firstIndex(where: { $0.id == selID }) else { return }
        pushSnapshot()
        segments[idx] = TimelineSegment(
            id: segments[idx].id,
            sourceStart: segments[idx].sourceStart,
            sourceEnd: segments[idx].sourceEnd,
            enabled: false
        )
        selectedSegmentID = nil
        // Clamp playhead to edited duration
        let edited = editedDuration
        if currentTime > edited { currentTime = edited }
    }

    func toggleBladeMode() {
        isBladeMode.toggle()
        selectedSegmentID = nil
    }

    func selectSegment(_ id: UUID?) {
        selectedSegmentID = id
    }

    // MARK: - Markers

    func addMarker() {
        pushSnapshot()
        let srcTime = sourceTime(forEditedTime: currentTime)
        let index = markers.filter({ $0.time <= srcTime }).count + 1
        markers.append(TimelineMarker(time: srcTime, label: "Marker \(index)"))
    }

    func removeMarker(id: UUID) {
        pushSnapshot()
        markers.removeAll { $0.id == id }
    }

    func updateMarkerLabel(id: UUID, label: String) {
        guard let idx = markers.firstIndex(where: { $0.id == id }) else { return }
        pushSnapshot()
        markers[idx].label = label
    }

    func updateMarkerColor(id: UUID, color: MarkerColor) {
        guard let idx = markers.firstIndex(where: { $0.id == id }) else { return }
        pushSnapshot()
        markers[idx].color = color
    }

    func jumpToMarker(id: UUID) {
        guard let marker = markers.first(where: { $0.id == id }) else { return }
        if let edited = editedTime(forSourceTime: marker.time) {
            pause()
            currentTime = edited
        }
    }

    // MARK: - Zoom Regions

    func addZoomRegion(start: Double, end: Double, level: Double) {
        // Prevent overlapping zoom regions
        let overlaps = zoomKeyframes.contains { kf in
            start < kf.endTime && end > kf.startTime
        }
        guard !overlaps else { return }

        pushSnapshot()
        let keyframe = ZoomKeyframe(startTime: start, endTime: end, zoomLevel: level)
        zoomKeyframes.append(keyframe)
    }

    func removeZoomRegion(id: UUID) {
        pushSnapshot()
        zoomKeyframes.removeAll { $0.id == id }
    }

    func updateZoomLevel(id: UUID, level: Double) {
        pushSnapshot()
        let clamped = max(1.2, min(4.0, level))
        guard let index = zoomKeyframes.firstIndex(where: { $0.id == id }) else { return }
        let existing = zoomKeyframes[index]
        zoomKeyframes[index] = ZoomKeyframe(
            id: existing.id,
            startTime: existing.startTime,
            endTime: existing.endTime,
            zoomLevel: clamped
        )
    }

    func updateZoomRegionTimes(id: UUID, startTime: Double? = nil, endTime: Double? = nil, pushUndo: Bool = false) {
        if pushUndo { pushSnapshot() }
        guard let index = zoomKeyframes.firstIndex(where: { $0.id == id }) else { return }
        let existing = zoomKeyframes[index]
        let newStart = startTime ?? existing.startTime
        let newEnd = endTime ?? existing.endTime
        guard newEnd - newStart >= 0.2 else { return }
        let overlaps = zoomKeyframes.contains { kf in
            kf.id != id && newStart < kf.endTime && newEnd > kf.startTime
        }
        guard !overlaps else { return }
        zoomKeyframes[index] = ZoomKeyframe(
            id: existing.id,
            startTime: newStart,
            endTime: newEnd,
            zoomLevel: existing.zoomLevel
        )
    }

    // MARK: - Cursor Helpers

    func cursorPosition(at time: TimeInterval) -> CGPoint? {
        guard let events = cursorData?.events, events.count >= 2 else {
            if let e = cursorData?.events.first {
                return CGPoint(x: e.x, y: e.y)
            }
            return nil
        }

        // Binary search for the index of the last event with t <= time
        if time <= events[0].t { return CGPoint(x: events[0].x, y: events[0].y) }
        let last = events.count - 1
        if time >= events[last].t { return CGPoint(x: events[last].x, y: events[last].y) }

        var lo = 0
        var hi = last
        while lo <= hi {
            let mid = (lo + hi) / 2
            if events[mid].t <= time {
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        // hi = index of last event with t <= time
        let i = hi

        guard cursorSmoothingEnabled else {
            // No smoothing: linear interpolation between two nearest points
            let a = events[i]
            let b = events[min(i + 1, last)]
            let span = b.t - a.t
            let frac = span > 0 ? (time - a.t) / span : 0
            return CGPoint(
                x: a.x + (b.x - a.x) * frac,
                y: a.y + (b.y - a.y) * frac
            )
        }

        // Catmull-Rom spline interpolation for smooth movement
        let i0 = max(i - 1, 0)
        let i1 = i
        let i2 = min(i + 1, last)
        let i3 = min(i + 2, last)

        let p0 = CGPoint(x: events[i0].x, y: events[i0].y)
        let p1 = CGPoint(x: events[i1].x, y: events[i1].y)
        let p2 = CGPoint(x: events[i2].x, y: events[i2].y)
        let p3 = CGPoint(x: events[i3].x, y: events[i3].y)

        let span = events[i2].t - events[i1].t
        let t = span > 0 ? (time - events[i1].t) / span : 0

        return catmullRom(p0: p0, p1: p1, p2: p2, p3: p3, t: t)
    }

    /// Catmull-Rom spline interpolation between p1 and p2 at parameter t ∈ [0, 1].
    /// p0 and p3 are the surrounding control points for curvature.
    private func catmullRom(
        p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint, t: Double
    ) -> CGPoint {
        let t2 = t * t
        let t3 = t2 * t

        let x = 0.5 * (
            (2 * p1.x) +
            (-p0.x + p2.x) * t +
            (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 +
            (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3
        )
        let y = 0.5 * (
            (2 * p1.y) +
            (-p0.y + p2.y) * t +
            (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 +
            (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3
        )

        return CGPoint(x: x, y: y)
    }

    func clickAtTime(_ time: TimeInterval, window: TimeInterval = 0.1) -> CursorEvent? {
        guard let events = cursorData?.events else { return nil }
        let lower = time - window
        let upper = time + window

        return events.first { event in
            event.click != nil && event.t >= lower && event.t <= upper
        }
    }

    // MARK: - Undo / Redo

    private func makeSnapshot() -> EditorSnapshot {
        EditorSnapshot(
            segments: segments,
            zoomKeyframes: zoomKeyframes,
            markers: markers,
            cursorScale: cursorScale,
            cursorStyle: cursorStyle,
            clickHighlightEnabled: clickHighlightEnabled,
            clickHighlightOpacity: clickHighlightOpacity,
            cursorSmoothingEnabled: cursorSmoothingEnabled,
            micVolume: micVolume,
            systemVolume: systemVolume,
            micMuted: micMuted,
            systemMuted: systemMuted,
            webcamEnabled: webcamEnabled,
            webcamScale: webcamScale,
            webcamPositionX: webcamPositionX,
            webcamPositionY: webcamPositionY,
            webcamStartOffset: webcamStartOffset
        )
    }

    private func pushSnapshot() {
        undoStack.append(makeSnapshot())
        redoStack.removeAll()
    }

    private func applySnapshot(_ snapshot: EditorSnapshot) {
        segments = snapshot.segments
        zoomKeyframes = snapshot.zoomKeyframes
        markers = snapshot.markers
        cursorScale = snapshot.cursorScale
        cursorStyle = snapshot.cursorStyle
        clickHighlightEnabled = snapshot.clickHighlightEnabled
        clickHighlightOpacity = snapshot.clickHighlightOpacity
        cursorSmoothingEnabled = snapshot.cursorSmoothingEnabled
        micVolume = snapshot.micVolume
        systemVolume = snapshot.systemVolume
        micMuted = snapshot.micMuted
        systemMuted = snapshot.systemMuted
        webcamEnabled = snapshot.webcamEnabled
        webcamScale = snapshot.webcamScale
        webcamPositionX = snapshot.webcamPositionX
        webcamPositionY = snapshot.webcamPositionY
    }

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(makeSnapshot())
        applySnapshot(snapshot)
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(makeSnapshot())
        applySnapshot(snapshot)
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
}
