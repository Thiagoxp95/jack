import AppKit
import SwiftUI

// MARK: - CountdownView

private struct CountdownView: View {
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

            try? await Task.sleep(for: .milliseconds(200))
        }
    }
}

// MARK: - CountdownOverlayController

@MainActor
final class CountdownOverlayController {

    private var window: NSWindow?

    // MARK: - Show

    func show() async {
        guard let screen = NSScreen.main else { return }

        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true

        window.contentView = NSHostingView(rootView: CountdownView())

        self.window = window
        window.orderFrontRegardless()

        // Wait for the full countdown animation (~3.2 seconds)
        try? await Task.sleep(for: .milliseconds(3200))

        window.close()
        self.window = nil
    }
}
