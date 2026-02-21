import AVFoundation
import CoreGraphics
import Foundation
import os

// MARK: - EditorSnapshot

struct EditorSnapshot {
    let cuts: [CutRegion]
    let zoomKeyframes: [ZoomKeyframe]
    let cursorScale: Double
    let clickHighlightEnabled: Bool
    let clickHighlightOpacity: Double
    let cursorSmoothingEnabled: Bool
    let micVolume: Float
    let systemVolume: Float
    let micMuted: Bool
    let systemMuted: Bool
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
    var clickHighlightEnabled: Bool = true
    var clickHighlightOpacity: Double = 0.3
    var cursorSmoothingEnabled: Bool = true

    var micVolume: Float = 1.0
    var systemVolume: Float = 1.0
    var micMuted: Bool = false
    var systemMuted: Bool = false

    var inPoint: TimeInterval?
    var outPoint: TimeInterval?

    private(set) var cursorData: CursorTrackingData?

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
        isPlaying = true

        playbackTask = Task { [weak self] in
            guard let self else { return }
            let frameInterval: UInt64 = 16_666_667 // ~60fps (1/60 sec in nanoseconds)

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: frameInterval)
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    guard self.isPlaying else { return }

                    self.currentTime += 1.0 / 60.0

                    // Skip cut regions
                    for cut in self.cuts {
                        if self.currentTime >= cut.inPoint && self.currentTime < cut.outPoint {
                            self.currentTime = cut.outPoint
                        }
                    }

                    // Stop at end
                    if self.currentTime >= self.duration {
                        self.currentTime = self.duration
                        self.pause()
                    }
                }
            }
        }
    }

    func pause() {
        isPlaying = false
        playbackTask?.cancel()
        playbackTask = nil
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
        pushSnapshot()
        let keyframe = ZoomKeyframe(startTime: start, endTime: end, zoomLevel: level)
        zoomKeyframes.append(keyframe)
    }

    func removeZoomRegion(id: UUID) {
        pushSnapshot()
        zoomKeyframes.removeAll { $0.id == id }
    }

    // MARK: - Cursor Helpers

    func cursorPosition(at time: TimeInterval) -> CGPoint? {
        guard let events = cursorData?.events, !events.isEmpty else { return nil }

        // Binary search for the closest event at or before the given time
        var lo = 0
        var hi = events.count - 1

        if time <= events[lo].t { return CGPoint(x: events[lo].x, y: events[lo].y) }
        if time >= events[hi].t { return CGPoint(x: events[hi].x, y: events[hi].y) }

        while lo <= hi {
            let mid = (lo + hi) / 2
            if events[mid].t <= time {
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }

        // hi is now the index of the last event with t <= time
        let event = events[hi]
        return CGPoint(x: event.x, y: event.y)
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
            clickHighlightEnabled: clickHighlightEnabled,
            clickHighlightOpacity: clickHighlightOpacity,
            cursorSmoothingEnabled: cursorSmoothingEnabled,
            micVolume: micVolume,
            systemVolume: systemVolume,
            micMuted: micMuted,
            systemMuted: systemMuted,
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
        clickHighlightEnabled = snapshot.clickHighlightEnabled
        clickHighlightOpacity = snapshot.clickHighlightOpacity
        cursorSmoothingEnabled = snapshot.cursorSmoothingEnabled
        micVolume = snapshot.micVolume
        systemVolume = snapshot.systemVolume
        micMuted = snapshot.micMuted
        systemMuted = snapshot.systemMuted
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
