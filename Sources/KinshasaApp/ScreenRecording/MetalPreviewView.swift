import AVFoundation
import CoreVideo
import MetalKit
import SwiftUI

// MARK: - MetalPreviewView

struct MetalPreviewView: NSViewRepresentable {
    let session: RecordingSession
    @Bindable var editor: VideoEditorController

    func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = true
        mtkView.delegate = context.coordinator
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        mtkView.layer?.isOpaque = true
        return mtkView
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.currentTime = editor.currentTime
        context.coordinator.cursorPosition = editor.cursorPosition(at: editor.currentTime)
        context.coordinator.cursorScale = editor.cursorScale
        context.coordinator.clickHighlightEnabled = editor.clickHighlightEnabled
        context.coordinator.clickHighlightOpacity = editor.clickHighlightOpacity
        context.coordinator.zoomKeyframes = editor.zoomKeyframes

        // Trigger redraw
        nsView.setNeedsDisplay(nsView.bounds)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    // MARK: - Coordinator

    @MainActor
    class Coordinator: NSObject, MTKViewDelegate {
        let session: RecordingSession
        private let device: MTLDevice?
        private let commandQueue: MTLCommandQueue?

        var currentTime: TimeInterval = 0
        var cursorPosition: CGPoint?
        var cursorScale: Double = 1.5
        var clickHighlightEnabled: Bool = true
        var clickHighlightOpacity: Double = 0.3
        var zoomKeyframes: [ZoomKeyframe] = []

        private var lastRenderedTime: TimeInterval = -1

        init(session: RecordingSession) {
            self.session = session
            self.device = MTLCreateSystemDefaultDevice()
            self.commandQueue = device?.makeCommandQueue()
            super.init()
        }

        // MARK: - MTKViewDelegate

        nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // No-op: handled on next draw
        }

        nonisolated func draw(in view: MTKView) {
            MainActor.assumeIsolated {
                drawOnMainActor(in: view)
            }
        }

        private func drawOnMainActor(in view: MTKView) {
            // Avoid redundant renders
            guard currentTime != lastRenderedTime else { return }
            lastRenderedTime = currentTime

            guard let device = view.device,
                  let commandQueue = self.commandQueue,
                  let drawable = view.currentDrawable,
                  let rpd = view.currentRenderPassDescriptor
            else { return }

            // Calculate zoom interpolation
            let zoomLevel = interpolatedZoomLevel(at: currentTime)

            // Read frame placeholder (returns nil for now)
            let _ = readFrame(at: currentTime)

            // Create a simple render pass that clears to a dark gray
            // (placeholder until MetalVideoRenderer is integrated)
            rpd.colorAttachments[0].clearColor = MTLClearColor(
                red: 0.08, green: 0.08, blue: 0.08, alpha: 1.0
            )
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].storeAction = .store

            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd)
            else { return }

            // In the future, MetalVideoRenderer.renderFrame() will be called here
            // with the pixel buffer, zoom level, and cursor position
            let _ = zoomLevel
            let _ = cursorPosition
            let _ = cursorScale

            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        // MARK: - Frame Reading

        /// Placeholder for reading frames from the video asset.
        /// Returns nil for now; will be implemented with AVAssetImageGenerator
        /// or AVAssetReader in a future task.
        func readFrame(at time: TimeInterval) -> CVPixelBuffer? {
            // Placeholder: will use AVAssetImageGenerator or AVAssetReader
            return nil
        }

        // MARK: - Zoom Interpolation

        private func interpolatedZoomLevel(at time: TimeInterval) -> Double {
            // Find the active zoom keyframe
            for kf in zoomKeyframes {
                if time >= kf.startTime && time <= kf.endTime {
                    return kf.zoomLevel
                }
            }
            return 1.0 // Default: no zoom
        }
    }
}
