import AppKit
import os
import SwiftUI

// MARK: - CountdownView

private struct CountdownView: View {
    var onComplete: @MainActor () -> Void

    @State private var currentNumber = 3
    @State private var numberScale: CGFloat = 0.5
    @State private var numberOpacity: Double = 0
    @State private var backgroundOpacity: Double = 0

    var body: some View {
        ZStack {
            Color.black.opacity(0.4 * backgroundOpacity)
                .ignoresSafeArea()

            if currentNumber > 0 {
                Text("\(currentNumber)")
                    .font(.system(size: 120, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: 4)
                    .scaleEffect(numberScale)
                    .opacity(numberOpacity)
            }
        }
        .task {
            // Fade in the background
            withAnimation(.easeIn(duration: 0.2)) {
                backgroundOpacity = 1
            }

            // Count from 3 down to 1
            for number in stride(from: 3, through: 1, by: -1) {
                currentNumber = number

                // Animate number appearing: scale up + fade in
                withAnimation(.spring(duration: 0.3, bounce: 0.2)) {
                    numberScale = 1.0
                    numberOpacity = 1.0
                }

                // Hold for a moment, then fade out before next number
                try? await Task.sleep(for: .milliseconds(700))

                withAnimation(.easeOut(duration: 0.25)) {
                    numberScale = 1.5
                    numberOpacity = 0
                }

                try? await Task.sleep(for: .milliseconds(300))

                // Reset scale for next number entrance
                numberScale = 0.5
            }

            // Final fade out
            currentNumber = 0
            withAnimation(.easeOut(duration: 0.2)) {
                backgroundOpacity = 0
            }

            try? await Task.sleep(for: .milliseconds(250))

            // Signal the controller that animation is done
            onComplete()
        }
    }
}

// MARK: - CountdownOverlayController

@MainActor
final class CountdownOverlayController {

    private var window: NSWindow?

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.jack",
        category: "CountdownOverlay"
    )

    // MARK: - Show

    /// Shows the countdown overlay and waits for animation to complete.
    /// After this returns the window is hidden but NOT destroyed.
    /// Call `cleanup()` later to release resources.
    /// - Parameter targetScreen: The screen to display the countdown on.
    ///   When `nil`, falls back to the screen under the mouse cursor, then `NSScreen.main`.
    func show(on targetScreen: NSScreen? = nil) async {
        let mouseLocation = NSEvent.mouseLocation
        let mouseScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
        let screen = targetScreen ?? mouseScreen ?? NSScreen.main ?? NSScreen.screens.first

        Self.logger.fault("[CDN-01] show: targetScreen=\(targetScreen != nil), mouseScreen=\(mouseScreen != nil), NSApp.isHidden=\(NSApp.isHidden)")

        guard let screen else {
            Self.logger.fault("[CDN-01] show: NO SCREEN AVAILABLE, aborting")
            return
        }

        Self.logger.fault("[CDN-02] show: creating window for screen \(screen.frame.debugDescription)")

        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true

        self.window = window

        Self.logger.fault("[CDN-03] show: window created, level=\(window.level.rawValue), calling orderFrontRegardless. NSApp.isHidden=\(NSApp.isHidden)")

        // Wait for the SwiftUI countdown animation to signal completion
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let view = CountdownView {
                continuation.resume()
            }
            window.contentView = NSHostingView(rootView: view)
            window.orderFrontRegardless()

            Self.logger.fault("[CDN-04] show: orderFrontRegardless called. isVisible=\(window.isVisible), isOnActiveSpace=\(window.isOnActiveSpace), NSApp.isHidden=\(NSApp.isHidden), windowNumber=\(window.windowNumber)")
        }

        Self.logger.fault("[CDN-05] show: animation done, hiding window")

        // Animation done — just hide. Don't tear down yet.
        window.orderOut(nil)
    }

    // MARK: - Cleanup

    /// Releases the window and hosting view. Safe to call at any time.
    func cleanup() {
        guard let window else { return }
        window.contentView = nil
        window.orderOut(nil)
        self.window = nil
    }
}
