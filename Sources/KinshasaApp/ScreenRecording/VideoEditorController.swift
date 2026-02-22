import AVFoundation
import CoreGraphics
import Foundation
import os

// MARK: - EditorSnapshot

struct EditorSnapshot {
    let cuts: [CutRegion]
    let zoomKeyframes: [ZoomKeyframe]
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
    let inPoint: TimeInterval?
    let outPoint: TimeInterval?
}

// MARK: - VideoEditorController

@Observable
@MainActor
final class VideoEditorController {

    // MARK: - State

    private(set) var duration: TimeInterval = 0
    private(set) var isPlaying = false
    var currentTime: TimeInterval = 0

    var cuts: [CutRegion] = []
    var zoomKeyframes: [ZoomKeyframe] = []

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

    var webcamEnabled: Bool = true
    var webcamScale: Double = 1.0
    /// Relative X position (0 = left, 1 = right)
    var webcamPositionX: Double = 0.08
    /// Relative Y position (0 = top, 1 = bottom)
    var webcamPositionY: Double = 0.88

    var inPoint: TimeInterval?
    var outPoint: TimeInterval?

    private(set) var cursorData: CursorTrackingData?
    private(set) var hasWebcamRecording = false
    private(set) var webcamPlayer: AVPlayer?

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
        let asset = AVURLAsset(url: session.screenVideoURL)
        do {
            let cmDuration = try await asset.load(.duration)
            duration = cmDuration.seconds
        } catch {
            Self.logger.error("Failed to load video duration: \(error)")
            duration = session.duration
        }

        // Check for webcam recording and set up player
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
            Self.logger.fault("[Editor] Webcam player created")
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

    // MARK: - In/Out Points

    func setInPoint() {
        pushSnapshot()
        inPoint = currentTime
    }

    func setOutPoint() {
        pushSnapshot()
        outPoint = currentTime
    }

    func deleteSelection() {
        guard let inPt = inPoint, let outPt = outPoint, inPt < outPt else { return }
        pushSnapshot()
        cuts.append(CutRegion(inPoint: inPt, outPoint: outPt))
        inPoint = nil
        outPoint = nil
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
            cuts: cuts,
            zoomKeyframes: zoomKeyframes,
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
            inPoint: inPoint,
            outPoint: outPoint
        )
    }

    private func pushSnapshot() {
        undoStack.append(makeSnapshot())
        redoStack.removeAll()
    }

    private func applySnapshot(_ snapshot: EditorSnapshot) {
        cuts = snapshot.cuts
        zoomKeyframes = snapshot.zoomKeyframes
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
        inPoint = snapshot.inPoint
        outPoint = snapshot.outPoint
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
