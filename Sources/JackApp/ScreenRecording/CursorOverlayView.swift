import SwiftUI

// MARK: - CursorSmoother

/// Frame-rate-independent critically-damped spring for cursor position.
/// Unlike simple exponential smoothing (which only tracks position and
/// constantly "chases" the target), this tracks both position **and velocity**,
/// producing fluid acceleration/deceleration with natural momentum and no
/// overshoot.  The result is cinematic cursor movement that feels like it
/// glides rather than snapping from point to point.
final class CursorSmoother {
    private var position: CGPoint = .zero
    private var velocity: CGPoint = .zero
    private var lastTimestamp: TimeInterval = 0
    private var initialized = false

    /// Natural frequency of the critically-damped spring.
    /// Higher = more responsive, lower = smoother/floatier.
    /// 16 gives fluid tracking with imperceptible lag (~0.19s to 95%).
    private let omega: Double = 16.0

    func update(target: CGPoint, timestamp: TimeInterval) -> CGPoint {
        guard initialized else {
            position = target
            velocity = .zero
            lastTimestamp = timestamp
            initialized = true
            return target
        }

        let dt = timestamp - lastTimestamp
        // Ignore duplicate calls within the same frame
        guard dt > 0.0001 else { return position }
        // Cap dt to avoid jumps after pauses or large gaps
        let clampedDt = min(dt, 1.0 / 30.0)
        lastTimestamp = timestamp

        // Analytical solution for a critically-damped spring:
        //   x(t) = (d + (v + ω·d)·t) · e^(-ω·t)
        //   ẋ(t) = (v·(1 - ω·t) - ω²·d·t) · e^(-ω·t)
        // where d = displacement from target, v = current velocity.
        let expTerm = exp(-omega * clampedDt)

        let dx = position.x - target.x
        let dy = position.y - target.y

        position.x = target.x + (dx + (velocity.x + omega * dx) * clampedDt) * expTerm
        position.y = target.y + (dy + (velocity.y + omega * dy) * clampedDt) * expTerm

        velocity.x = (velocity.x * (1.0 - omega * clampedDt) - omega * omega * dx * clampedDt) * expTerm
        velocity.y = (velocity.y * (1.0 - omega * clampedDt) - omega * omega * dy * clampedDt) * expTerm

        return position
    }

    func reset() {
        initialized = false
    }

    func snap(to point: CGPoint) {
        position = point
        velocity = .zero
        initialized = true
    }
}

// MARK: - CursorOverlayView

/// Renders a custom cursor on top of the video preview using tracked cursor data.
/// Uses TimelineView for display-rate rendering and exponential smoothing
/// for butter-smooth sub-pixel cursor movement.
struct CursorOverlayView: View {
    @Bindable var editor: VideoEditorController
    @State private var smoother = CursorSmoother()

    var body: some View {
        // TimelineView fires at display refresh rate (120Hz on ProMotion)
        // during playback, enabling sub-frame cursor interpolation.
        TimelineView(.animation(minimumInterval: nil, paused: !editor.isPlaying)) { timeline in
            GeometryReader { geometry in
                cursorContent(
                    viewSize: geometry.size,
                    timestamp: timeline.date.timeIntervalSinceReferenceDate
                )
            }
        }
        .allowsHitTesting(false)
    }

    /// Duration of the click press animation in seconds.
    private let clickAnimDuration: TimeInterval = 0.25
    /// How much the cursor shrinks at peak press (0.25 = shrinks to 75%).
    private let clickPressDepth: Double = 0.25

    @ViewBuilder
    private func cursorContent(viewSize: CGSize, timestamp: TimeInterval) -> some View {
        let screenSize = editor.session.screenSize
        // Use predictive timing during playback for sub-frame accuracy
        let time = editor.isPlaying ? editor.smoothTime : editor.currentTime

        if screenSize.width > 0, screenSize.height > 0,
           let pos = editor.cursorPosition(at: time)
        {
            let mapped = mapToView(
                cursorPoint: pos,
                screenSize: screenSize,
                viewSize: viewSize
            )

            // During playback, apply spring smoothing for butter-smooth rendering.
            // When paused/scrubbing, use exact position (TimelineView timestamp
            // doesn't advance so the smoother would return stale positions).
            let displayed = smoothedPosition(mapped: mapped, timestamp: timestamp)

            let fillColor = Color(hex: editor.cursorStyle.fillHex)
            let strokeColor = Color(hex: editor.cursorStyle.strokeHex)

            // Click press animation: cursor scales down then back up
            let clickScale = clickScaleFactor(at: time)
            let effectiveScale = editor.cursorScale * clickScale

            // Cursor arrow
            CursorShape()
                .fill(fillColor)
                .overlay(
                    CursorShape()
                        .stroke(strokeColor, lineWidth: 1.5)
                )
                .frame(
                    width: 14 * effectiveScale,
                    height: 20 * effectiveScale
                )
                // Offset so the tip of the arrow is at the cursor position
                .position(
                    x: displayed.x + 7 * effectiveScale,
                    y: displayed.y + 10 * effectiveScale
                )
                .shadow(color: .black.opacity(0.4), radius: 2, x: 1, y: 1)
                .allowsHitTesting(false)
        }
    }

    /// Apply spring smoothing during playback, snap during scrubbing.
    /// Extracted from @ViewBuilder to avoid mixing imperative code with view building.
    private func smoothedPosition(mapped: CGPoint, timestamp: TimeInterval) -> CGPoint {
        if editor.isPlaying {
            return smoother.update(target: mapped, timestamp: timestamp)
        } else {
            smoother.snap(to: mapped)
            return mapped
        }
    }

    /// Compute click animation scale factor based on proximity to a click event.
    /// Returns 1.0 normally, dips to ~0.75 during a click press, then returns to 1.0.
    /// Uses asymmetric timing: quick press (first 25% of duration), slower release.
    private func clickScaleFactor(at time: TimeInterval) -> Double {
        guard editor.clickHighlightEnabled,
              let click = editor.clickAtTime(time, window: clickAnimDuration)
        else { return 1.0 }

        let elapsed = time - click.t
        guard elapsed >= 0, elapsed < clickAnimDuration else { return 1.0 }

        // Normalize to [0, 1]
        let progress = elapsed / clickAnimDuration
        // sin(π * √t) peaks at t=0.25 (quick press) and returns to 0 at t=1.0 (slower release)
        let pressAmount = sin(.pi * sqrt(progress))
        return 1.0 - clickPressDepth * pressAmount
    }

    /// Map cursor position from screen coordinates to view coordinates,
    /// accounting for aspect-ratio letterboxing (resizeAspect).
    private func mapToView(
        cursorPoint: CGPoint,
        screenSize: CGSize,
        viewSize: CGSize
    ) -> CGPoint {
        let videoAspect = screenSize.width / screenSize.height
        let viewAspect = viewSize.width / viewSize.height

        let renderSize: CGSize
        let offset: CGPoint

        if videoAspect > viewAspect {
            // Video is wider than view — letterboxed top/bottom
            let renderWidth = viewSize.width
            let renderHeight = renderWidth / videoAspect
            renderSize = CGSize(width: renderWidth, height: renderHeight)
            offset = CGPoint(x: 0, y: (viewSize.height - renderHeight) / 2)
        } else {
            // Video is taller than view — pillarboxed left/right
            let renderHeight = viewSize.height
            let renderWidth = renderHeight * videoAspect
            renderSize = CGSize(width: renderWidth, height: renderHeight)
            offset = CGPoint(x: (viewSize.width - renderWidth) / 2, y: 0)
        }

        // Map screen coordinates to rendered video region
        let x = (cursorPoint.x / screenSize.width) * renderSize.width + offset.x
        let y = (cursorPoint.y / screenSize.height) * renderSize.height + offset.y

        return CGPoint(x: x, y: y)
    }
}

// MARK: - CursorShape

/// A macOS-style arrow cursor shape.
struct CursorShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height

        // Arrow cursor pointing top-left
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: h * 0.85))
        path.addLine(to: CGPoint(x: w * 0.3, y: h * 0.65))
        path.addLine(to: CGPoint(x: w * 0.5, y: h))
        path.addLine(to: CGPoint(x: w * 0.7, y: h * 0.92))
        path.addLine(to: CGPoint(x: w * 0.48, y: h * 0.58))
        path.addLine(to: CGPoint(x: w * 0.9, y: h * 0.55))
        path.closeSubpath()

        return path
    }
}

// MARK: - Color Hex Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let scanner = Scanner(string: hex)
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >> 8) & 0xFF) / 255.0
        let b = Double(rgb & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
