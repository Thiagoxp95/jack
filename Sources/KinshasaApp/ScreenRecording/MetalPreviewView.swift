import AVFoundation
import AVKit
import SwiftUI
import os

private let syncLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.kinshasa",
    category: "PlaybackSync"
)

// MARK: - MetalPreviewView

/// Video preview using AVPlayerView for playback, synced to the editor's currentTime.
/// Named MetalPreviewView for compatibility with VideoEditorView.
struct MetalPreviewView: NSViewRepresentable {
    let session: RecordingSession
    @Bindable var editor: VideoEditorController

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.player = context.coordinator.player
        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspect
        return playerView
    }

    func updateNSView(_ playerView: AVPlayerView, context: Context) {
        let coordinator = context.coordinator

        // Swap to composition-backed player item once load() finishes.
        // makeCoordinator() may run before load() completes, so the player
        // initially uses raw screen video. This upgrades it to the composition
        // (screen video + mic + system audio on one timeline).
        if let composition = editor.composition, !coordinator.hasAppliedComposition {
            let newItem = AVPlayerItem(asset: composition)
            newItem.audioMix = editor.audioMix
            coordinator.player.replaceCurrentItem(with: newItem)
            coordinator.hasAppliedComposition = true
        }

        // Reapply audioMix when it changes (volume/mute updates)
        if let currentMix = editor.audioMix,
           coordinator.player.currentItem?.audioMix !== currentMix {
            coordinator.player.currentItem?.audioMix = currentMix
        }

        // Sync play/pause — composition player has screen video + audio in one timeline.
        // Webcam is the only secondary player (visual overlay, no audio).
        if editor.isPlaying && coordinator.player.rate == 0 {
            let target = CMTime(seconds: editor.currentTime, preferredTimescale: 600)

            // Start composition player with exact seek, then start webcam
            // at the same moment so they're synchronized.
            let seekStart = CACurrentMediaTime()
            coordinator.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                let seekDuration = CACurrentMediaTime() - seekStart
                coordinator.player.play()
                coordinator.syncWebcamPlay(at: coordinator.player.currentTime())
                syncLogger.fault("[SYNC] play-start: seek took \(seekDuration, format: .fixed(precision: 3))s, both players started together")
            }
        } else if !editor.isPlaying && coordinator.player.rate != 0 {
            coordinator.player.pause()
            coordinator.pauseWebcam()
        }

        // Sync seek position when user scrubs while paused
        if !editor.isPlaying {
            let target = CMTime(seconds: editor.currentTime, preferredTimescale: 600)
            let current = coordinator.player.currentTime()
            let diff = abs(target.seconds - current.seconds)
            if diff > 0.016 {
                coordinator.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                coordinator.seekWebcam(to: target)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, editor: editor)
    }

    // MARK: - Coordinator

    @MainActor
    class Coordinator: NSObject {
        let player: AVPlayer
        nonisolated(unsafe) private var timeObserver: Any?
        private weak var editor: VideoEditorController?
        /// Tracks whether the composition-backed player item has been applied.
        var hasAppliedComposition = false
        /// Boundary observer that fires when composition reaches the webcam start point.
        private var webcamBoundaryObserver: Any?

        init(session: RecordingSession, editor: VideoEditorController) {
            self.editor = editor

            // Create player from composition (screen video + audio in one timeline)
            if let composition = editor.composition {
                let playerItem = AVPlayerItem(asset: composition)
                playerItem.audioMix = editor.audioMix
                self.player = AVPlayer(playerItem: playerItem)
                self.hasAppliedComposition = true
            } else {
                // Fallback: play raw screen video until composition is ready
                let asset = AVURLAsset(url: session.screenVideoURL)
                let playerItem = AVPlayerItem(asset: asset)
                self.player = AVPlayer(playerItem: playerItem)
            }
            self.player.actionAtItemEnd = .pause
            super.init()

            // Observe player time to sync back to editor during playback.
            // 120fps sync for butter-smooth cursor overlay rendering.
            let interval = CMTime(value: 1, timescale: 120)
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: interval,
                queue: .main
            ) { [weak self] time in
                MainActor.assumeIsolated {
                    guard let self, let editor = self.editor else { return }
                    if editor.isPlaying {
                        editor.currentTime = time.seconds
                        editor.lastTimeSyncDate = .now

                        // Webcam drift correction during playback
                        if let webcam = editor.webcamPlayer {
                            let offset = editor.webcamStartOffset
                            let expectedWebcam = time.seconds - offset

                            if expectedWebcam < 0 {
                                // Before webcam content — keep paused at first frame
                                if webcam.rate != 0 {
                                    webcam.pause()
                                    webcam.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                                }
                            } else {
                                // Webcam should be playing — correct drift if > 100ms
                                let actual = webcam.currentTime().seconds
                                let drift = actual - expectedWebcam
                                if abs(drift) > 0.1 {
                                    let corrected = CMTime(seconds: expectedWebcam, preferredTimescale: 600)
                                    webcam.seek(to: corrected, toleranceBefore: .zero, toleranceAfter: .zero)
                                    syncLogger.fault("[SYNC] drift correction: drift=\(drift, format: .fixed(precision: 3))s, corrected to \(expectedWebcam, format: .fixed(precision: 3))s")
                                }
                            }
                        }

                        // Auto-stop at end
                        if time.seconds >= editor.duration && editor.duration > 0 {
                            editor.pause()
                        }
                    }
                }
            }
        }

        // MARK: - Webcam Sync

        /// Converts composition time to webcam file time.
        /// The webcam starts recording AFTER the screen, so webcam file T=0
        /// corresponds to composition T=offset. Returns nil if composition
        /// time is before the webcam started.
        private func webcamTime(for compositionTime: CMTime) -> CMTime? {
            guard let editor else { return compositionTime }
            let delay = CMTime(seconds: editor.webcamStartOffset, preferredTimescale: 600)
            let target = CMTimeSubtract(compositionTime, delay)
            if target < .zero { return nil }
            return target
        }

        func syncWebcamPlay(at compositionTime: CMTime) {
            guard let webcam = editor?.webcamPlayer, let editor else { return }

            // Cancel any previous boundary observer
            removeBoundaryObserver()

            let offset = editor.webcamStartOffset

            if let target = webcamTime(for: compositionTime) {
                // Webcam content is available — seek and play immediately
                webcam.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                    webcam.play()
                }
            } else if offset > 0 {
                // Composition is before webcam content starts.
                // Show first frame (paused), then start webcam when composition
                // reaches the offset point via a boundary time observer.
                webcam.pause()
                webcam.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)

                let boundaryTime = CMTime(seconds: offset, preferredTimescale: 600)
                webcamBoundaryObserver = player.addBoundaryTimeObserver(
                    forTimes: [NSValue(time: boundaryTime)],
                    queue: .main
                ) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, let editor = self.editor, editor.isPlaying else { return }
                        guard let webcam = editor.webcamPlayer else { return }
                        // Composition just reached the offset — start webcam from T=0
                        webcam.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                            webcam.play()
                        }
                        self.removeBoundaryObserver()
                    }
                }
            } else {
                // No offset — play from same position
                webcam.seek(to: compositionTime, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                    webcam.play()
                }
            }
        }

        func pauseWebcam() {
            removeBoundaryObserver()
            editor?.webcamPlayer?.pause()
        }

        func seekWebcam(to compositionTime: CMTime) {
            guard let webcam = editor?.webcamPlayer else { return }
            // For scrubbing while paused: show first frame if before webcam start
            let target = webcamTime(for: compositionTime) ?? .zero
            let current = webcam.currentTime()
            if abs(target.seconds - current.seconds) > 0.05 {
                webcam.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }

        private func removeBoundaryObserver() {
            if let obs = webcamBoundaryObserver {
                player.removeTimeObserver(obs)
                webcamBoundaryObserver = nil
            }
        }

        func cleanup() {
            removeBoundaryObserver()
            if let observer = timeObserver {
                player.removeTimeObserver(observer)
                timeObserver = nil
            }
            player.pause()
            editor?.webcamPlayer?.pause()
        }
    }
}
