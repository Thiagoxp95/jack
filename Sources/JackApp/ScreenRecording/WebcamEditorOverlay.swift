import AVFoundation
import AVKit
import SwiftUI

// MARK: - WebcamEditorOverlay

/// Shows the recorded webcam video as a circular overlay in the video editor preview.
/// Position and size are controlled by the editor's webcam settings.
/// The AVPlayer is owned by VideoEditorController (created during load()).
struct WebcamEditorOverlay: View {
    @Bindable var editor: VideoEditorController
    let viewSize: CGSize

    var body: some View {
        if let player = editor.webcamPlayer, editor.webcamEnabled {
            WebcamPlayerView(player: player, diameter: diameter)
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(Color.white, lineWidth: 2)
                )
                .shadow(color: .black.opacity(0.5), radius: 6, x: 0, y: 2)
                .position(webcamPosition)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let newX = max(0, min(1, value.location.x / viewSize.width))
                            let newY = max(0, min(1, value.location.y / viewSize.height))
                            editor.webcamPositionX = newX
                            editor.webcamPositionY = newY
                        }
                )
                // Playback sync is handled by MetalPreviewView coordinator
                // alongside mic/system audio for exact timing alignment.
        }
    }

    private var diameter: CGFloat {
        let baseSize = min(viewSize.width, viewSize.height) * 0.18
        return baseSize * editor.webcamScale
    }

    private var webcamPosition: CGPoint {
        CGPoint(
            x: editor.webcamPositionX * viewSize.width,
            y: editor.webcamPositionY * viewSize.height
        )
    }

}

// MARK: - WebcamPlayerView

/// NSViewRepresentable for displaying webcam video in a circle using AVPlayerView.
struct WebcamPlayerView: NSViewRepresentable {
    let player: AVPlayer
    let diameter: CGFloat

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspectFill
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        // No dynamic updates needed — player is set once
    }
}
