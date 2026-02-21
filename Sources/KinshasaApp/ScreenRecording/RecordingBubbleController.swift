import AppKit
import SwiftUI

// MARK: - RecordingBubbleView

private struct RecordingBubbleView: View {
    @Bindable var controller: RecordingSessionController

    var body: some View {
        HStack(spacing: 10) {
            // Pulsing status dot
            Circle()
                .fill(controller.state == .paused ? Color.yellow : Color.red)
                .frame(width: 8, height: 8)
                .opacity(controller.state == .paused ? 1 : pulsingOpacity)
                .animation(
                    controller.state == .recording
                        ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                        : .default,
                    value: controller.state
                )

            // Timer display
            Text(controller.formattedElapsedTime)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)

            // Divider
            Capsule()
                .fill(Color.white.opacity(0.25))
                .frame(width: 1, height: 16)

            // Pause / Resume button
            Button {
                if controller.state == .paused {
                    controller.resumeRecording()
                } else {
                    controller.pauseRecording()
                }
            } label: {
                Image(systemName: controller.state == .paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Stop button
            Button {
                Task {
                    await controller.stopRecording()
                }
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
        )
        .preferredColorScheme(.dark)
    }

    @State private var pulsingOpacity: Double = 1.0
}

// MARK: - RecordingBubbleController

@MainActor
final class RecordingBubbleController {

    private var panel: NSPanel?

    // MARK: - Show

    func show(controller: RecordingSessionController) {
        if panel != nil { return }

        let size = NSSize(width: 220, height: 44)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let bubbleView = RecordingBubbleView(controller: controller)
        let hostingView = NSHostingView(rootView: bubbleView)
        hostingView.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hostingView

        // Position: bottom-center of main screen, 40px above dock
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            self.panel = panel
            panel.makeKeyAndOrderFront(nil)
            return
        }

        let screenFrame = screen.visibleFrame
        let finalX = screenFrame.midX - (size.width / 2)
        let finalY = screenFrame.minY + 40
        let startY = finalY - 60

        // Start below final position for slide-up animation
        panel.setFrameOrigin(NSPoint(x: finalX, y: startY))
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        self.panel = panel

        // Slide-up animation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.4
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrameOrigin(NSPoint(x: finalX, y: finalY))
            panel.animator().alphaValue = 1
        }
    }

    // MARK: - Hide

    func hide() {
        guard let panel, panel.isVisible else { return }

        let currentFrame = panel.frame
        let targetY = currentFrame.origin.y - 60

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrameOrigin(NSPoint(x: currentFrame.origin.x, y: targetY))
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor [weak self] in
                self?.panel?.close()
                self?.panel = nil
            }
        })
    }
}
