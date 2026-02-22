import AVFoundation
import AVKit
import SwiftUI

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

        // Sync play/pause state
        if editor.isPlaying && coordinator.player.rate == 0 {
            // Seek to editor's current time before playing (handles replay from start)
            let target = CMTime(seconds: editor.currentTime, preferredTimescale: 600)
            coordinator.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                coordinator.player.play()
            }
        } else if !editor.isPlaying && coordinator.player.rate != 0 {
            coordinator.player.pause()
        }

        // Sync seek position when user scrubs while paused
        if !editor.isPlaying {
            let target = CMTime(seconds: editor.currentTime, preferredTimescale: 600)
            let current = coordinator.player.currentTime()
            let diff = abs(target.seconds - current.seconds)
            if diff > 0.016 {
                coordinator.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
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

        init(session: RecordingSession, editor: VideoEditorController) {
            self.editor = editor
            let asset = AVURLAsset(url: session.screenVideoURL)
            let playerItem = AVPlayerItem(asset: asset)
            self.player = AVPlayer(playerItem: playerItem)
            self.player.actionAtItemEnd = .pause
            super.init()

            // Observe player time to sync back to editor during playback
            let interval = CMTime(value: 1, timescale: 30) // ~30fps sync
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: interval,
                queue: .main
            ) { [weak self] time in
                MainActor.assumeIsolated {
                    guard let self, let editor = self.editor else { return }
                    if editor.isPlaying {
                        editor.currentTime = time.seconds
                        // Auto-stop at end
                        if time.seconds >= editor.duration && editor.duration > 0 {
                            editor.pause()
                        }
                    }
                }
            }
        }

        func cleanup() {
            if let observer = timeObserver {
                player.removeTimeObserver(observer)
                timeObserver = nil
            }
            player.pause()
        }
    }
}
