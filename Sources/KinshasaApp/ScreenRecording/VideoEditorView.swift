import AVFoundation
import QuartzCore
import SwiftUI

// MARK: - CameraTracker

/// Broadcast-style lazy camera that only pans when the cursor approaches
/// the edge of the zoomed viewport. Creates a cinematic "soccer camera" feel
/// where the subject moves freely within a deadzone and the camera follows
/// smoothly when the subject nears the frame edge.
final class CameraTracker {
    private var anchorX: Double = 0.5
    private var anchorY: Double = 0.5
    private var lastTimestamp: TimeInterval = 0
    private var wasZoomed = false

    /// Fraction of the viewport where the cursor moves freely (no camera pan).
    /// 0.6 means the inner 60% is a deadzone; camera only reacts in the outer 20% on each side.
    private let deadzoneRatio: Double = 0.6

    /// Camera stiffness — higher = more responsive.
    /// 6.0 gives ~0.4s to settle (cinematic broadcast feel).
    private let stiffness: Double = 6.0

    /// Compute the lazy-follow anchor for `scaleEffect`.
    ///
    /// - Parameters:
    ///   - cursorNormX: Cursor X in normalized view coords (0-1).
    ///   - cursorNormY: Cursor Y in normalized view coords (0-1).
    ///   - zoomLevel: Current interpolated zoom level.
    ///   - timestamp: Explicit timestamp (for export). If nil, uses wall-clock time.
    /// - Returns: A `UnitPoint` anchor for `scaleEffect`.
    func update(
        cursorNormX: Double,
        cursorNormY: Double,
        zoomLevel: Double,
        timestamp: TimeInterval? = nil
    ) -> UnitPoint {
        // Not zoomed — reset and center
        guard zoomLevel > 1.01 else {
            reset()
            return .center
        }

        let now = timestamp ?? CACurrentMediaTime()

        // First frame entering a zoom region: snap to cursor
        if !wasZoomed {
            anchorX = cursorNormX
            anchorY = cursorNormY
            lastTimestamp = now
            wasZoomed = true
            return UnitPoint(x: anchorX, y: anchorY)
        }

        let dt = now - lastTimestamp
        guard dt > 0.0001 else { return UnitPoint(x: anchorX, y: anchorY) }
        let clampedDt = min(dt, 1.0 / 30.0)
        lastTimestamp = now

        // Compute target anchors using deadzone logic
        let targetX = targetAnchor(cursor: cursorNormX, current: anchorX, zoom: zoomLevel)
        let targetY = targetAnchor(cursor: cursorNormY, current: anchorY, zoom: zoomLevel)

        // Frame-rate independent exponential smoothing
        let factor = 1.0 - exp(-stiffness * clampedDt)
        anchorX += (targetX - anchorX) * factor
        anchorY += (targetY - anchorY) * factor

        // Clamp to valid range
        anchorX = max(0, min(1, anchorX))
        anchorY = max(0, min(1, anchorY))

        return UnitPoint(x: anchorX, y: anchorY)
    }

    /// For a single axis, compute the target anchor that keeps the cursor
    /// within the deadzone. If cursor is already inside, don't move.
    private func targetAnchor(cursor: Double, current: Double, zoom: Double) -> Double {
        // Where the cursor appears within the viewport (0 = left edge, 1 = right edge)
        let cursorInViewport = cursor * zoom - current * (zoom - 1)
        let margin = (1.0 - deadzoneRatio) / 2.0

        if cursorInViewport < margin {
            // Cursor is leaving through the left/top — pan to bring it to deadzone edge
            return max(0, min(1, (cursor * zoom - margin) / (zoom - 1)))
        } else if cursorInViewport > 1.0 - margin {
            // Cursor is leaving through the right/bottom — pan to bring it to deadzone edge
            return max(0, min(1, (cursor * zoom - (1.0 - margin)) / (zoom - 1)))
        }

        // Cursor is inside the deadzone — don't move
        return current
    }

    func reset() {
        anchorX = 0.5
        anchorY = 0.5
        wasZoomed = false
    }
}

// MARK: - VideoEditorView

struct VideoEditorView: View {
    @Bindable var editor: VideoEditorController
    var onDone: () -> Void
    @State private var showExportSheet = false
    @State private var lastScrubTime: Date = .distantPast
    @State private var zoomDragStart: CGFloat?
    @State private var zoomDragEnd: CGFloat?
    @State private var zoomHoverX: CGFloat?
    @State private var resizingKeyframeID: UUID?
    @State private var resizingEdge: ZoomResizeEdge?
    @State private var cameraTracker = CameraTracker()
    @State private var lastMagnifyScale: CGFloat = 1.0
    @State private var bladeHoverX: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            editorToolbar
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(EditorColors.background)

            Rectangle().fill(EditorColors.divider).frame(height: 1)

            // Aspect ratio picker
            HStack(spacing: 8) {
                Text("Aspect Ratio")
                    .font(.caption)
                    .foregroundColor(EditorColors.secondary)
                HStack(spacing: 1) {
                    ForEach(ExportAspectRatio.allCases) { ratio in
                        Button {
                            editor.aspectRatio = ratio
                        } label: {
                            Text(ratio.label)
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(
                                    editor.aspectRatio == ratio
                                        ? AnyShapeStyle(EditorColors.accentGradient)
                                        : AnyShapeStyle(EditorColors.card)
                                )
                                .foregroundColor(
                                    editor.aspectRatio == ratio ? .white : .primary
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(EditorColors.background)

            Rectangle().fill(EditorColors.divider).frame(height: 1)

            // Main content
            HStack(spacing: 0) {
                // Left: Video preview + timeline
                VStack(spacing: 0) {
                    videoPreview
                        .frame(minHeight: 300)

                    Rectangle().fill(EditorColors.divider).frame(height: 1)

                    timelinePanel
                        .frame(minHeight: 220)
                }
                .frame(maxWidth: .infinity)

                Rectangle().fill(EditorColors.divider).frame(width: 1)

                // Right: Effects + Audio panel
                ScrollView {
                    VStack(spacing: 16) {
                        if editor.hasWebcamRecording {
                            webcamPanel
                        }
                        cursorEffectsPanel
                        audioTracksPanel
                    }
                    .padding(12)
                }
                .frame(width: 280)
                .background(EditorColors.background)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(Color.black)
        .preferredColorScheme(.dark)
        .keyboardShortcut(shortcuts: editorShortcuts)
        .sheet(isPresented: $showExportSheet) {
            ExportDialogView(
                editor: editor,
                onDismiss: { showExportSheet = false }
            )
        }
        .onChange(of: editor.micMuted) { _, _ in updateAudioVolumes() }
        .onChange(of: editor.systemMuted) { _, _ in updateAudioVolumes() }
        .onChange(of: editor.micVolume) { _, _ in updateAudioVolumes() }
        .onChange(of: editor.systemVolume) { _, _ in updateAudioVolumes() }
        .onAppear { updateAudioVolumes() }
    }

    // MARK: - Toolbar

    @ViewBuilder
    private var editorToolbar: some View {
        HStack {
            Button(action: editor.undo) {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(!editor.canUndo)

            Button(action: editor.redo) {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .disabled(!editor.canRedo)

            Spacer()

            // Blade mode toggle
            Button {
                editor.toggleBladeMode()
            } label: {
                Label("Blade", systemImage: "scissors")
                    .foregroundColor(editor.isBladeMode ? .white : EditorColors.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        editor.isBladeMode
                            ? AnyShapeStyle(EditorColors.accentGradient)
                            : AnyShapeStyle(Color.clear)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            // Add marker button
            Button {
                editor.addMarker()
            } label: {
                Label("Marker", systemImage: "flag.fill")
            }
            .buttonStyle(.plain)

            Spacer()

            Text(formatTime(editor.currentTime))
                .font(.system(.title3, design: .monospaced))
                .foregroundColor(.white)

            Text(" / ")
                .foregroundColor(EditorColors.secondary)

            Text(formatTime(editor.editedDuration))
                .font(.system(.title3, design: .monospaced))
                .foregroundColor(EditorColors.secondary)

            Spacer()

            Button("Export") { showExportSheet = true }
                .buttonStyle(.borderedProminent)

            Button("Done", action: onDone)
        }
    }

    // MARK: - Video Preview

    @ViewBuilder
    private var videoPreview: some View {
        GeometryReader { geometry in
            let previewSize: CGSize = {
                guard let targetRatio = editor.aspectRatio.ratio else {
                    return geometry.size
                }
                let availableAspect = geometry.size.width / geometry.size.height
                if availableAspect > targetRatio {
                    let w = geometry.size.height * targetRatio
                    return CGSize(width: w, height: geometry.size.height)
                } else {
                    let h = geometry.size.width / targetRatio
                    return CGSize(width: geometry.size.width, height: h)
                }
            }()

            let videoAspect = editor.session.screenSize.width / max(editor.session.screenSize.height, 1)

            let videoGroupSize: CGSize = {
                let containerAspect = previewSize.width / previewSize.height
                if videoAspect > containerAspect {
                    let h = previewSize.width / videoAspect
                    return CGSize(width: previewSize.width, height: h)
                } else {
                    let w = previewSize.height * videoAspect
                    return CGSize(width: w, height: previewSize.height)
                }
            }()

            let time = editor.isPlaying ? editor.smoothTime : editor.currentTime
            let zoomLevel = MetalVideoRenderer.interpolateZoom(
                at: time,
                keyframes: editor.zoomKeyframes,
                rampDuration: MetalVideoRenderer.cinematicRampDuration
            )
            let anchor = lazyZoomAnchor(at: time, zoomLevel: zoomLevel, viewSize: videoGroupSize)

            ZStack {
                MetalPreviewView(session: editor.session, editor: editor)
                    .overlay {
                        CursorOverlayView(editor: editor)
                    }
                    .aspectRatio(videoAspect, contentMode: .fit)
                    .scaleEffect(zoomLevel, anchor: anchor)
                    .clipped()

                WebcamEditorOverlay(editor: editor, viewSize: videoGroupSize)
                    .frame(width: videoGroupSize.width, height: videoGroupSize.height)

                if !editor.isPlaying {
                    Button(action: editor.togglePlayPause) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 64))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: previewSize.width, height: previewSize.height)
            .background(Color.black)
            .clipped()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Broadcast-style lazy camera anchor.
    private func lazyZoomAnchor(
        at time: TimeInterval,
        zoomLevel: Double,
        viewSize: CGSize
    ) -> UnitPoint {
        let screenSize = editor.session.screenSize
        guard screenSize.width > 0, screenSize.height > 0,
              let pos = editor.cursorPosition(at: time) else {
            cameraTracker.reset()
            return .center
        }

        let videoAspect = screenSize.width / screenSize.height
        let viewAspect = viewSize.width / viewSize.height

        let renderSize: CGSize
        let offset: CGPoint

        if videoAspect > viewAspect {
            let renderWidth = viewSize.width
            let renderHeight = renderWidth / videoAspect
            renderSize = CGSize(width: renderWidth, height: renderHeight)
            offset = CGPoint(x: 0, y: (viewSize.height - renderHeight) / 2)
        } else {
            let renderHeight = viewSize.height
            let renderWidth = renderHeight * videoAspect
            renderSize = CGSize(width: renderWidth, height: renderHeight)
            offset = CGPoint(x: (viewSize.width - renderWidth) / 2, y: 0)
        }

        let viewX = (pos.x / screenSize.width) * renderSize.width + offset.x
        let viewY = (pos.y / screenSize.height) * renderSize.height + offset.y

        let normX = max(0, min(1, viewX / viewSize.width))
        let normY = max(0, min(1, viewY / viewSize.height))

        return cameraTracker.update(
            cursorNormX: normX,
            cursorNormY: normY,
            zoomLevel: zoomLevel
        )
    }

    // MARK: - Timeline Panel

    @ViewBuilder
    private var timelinePanel: some View {
        VStack(spacing: 0) {
            // Scrollable tracks area
            GeometryReader { outerGeo in
                let baseWidth = outerGeo.size.width
                let scaledWidth = max(baseWidth, baseWidth * editor.timelineScale)

                ScrollView(.horizontal, showsIndicators: editor.timelineScale > 1.05) {
                    VStack(alignment: .leading, spacing: 4) {
                        // Time ruler
                        timeRuler
                            .frame(height: 16)

                        sectionHeader("VIDEO")
                        videoTimeline
                            .frame(height: 44)

                        sectionHeader("ZOOM")
                        zoomTimeline
                            .frame(height: 30)

                        sectionHeader("AUDIO")
                        HStack(spacing: 4) {
                            waveformView(samples: editor.micWaveform, color: EditorColors.micWaveform, label: "Mic")
                                .frame(height: 28)
                            waveformView(samples: editor.systemWaveform, color: EditorColors.systemWaveform, label: "Sys")
                                .frame(height: 28)
                        }

                        if !editor.markers.isEmpty {
                            sectionHeader("MARKERS")
                            markersRow
                                .frame(height: 20)
                        }
                    }
                    .frame(width: scaledWidth)
                    .padding(.horizontal, 8)
                }
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            let delta = value.magnification / lastMagnifyScale
                            editor.timelineScale = max(1.0, min(10.0, editor.timelineScale * delta))
                            lastMagnifyScale = value.magnification
                        }
                        .onEnded { _ in
                            lastMagnifyScale = 1.0
                        }
                )
            }

            // Playback controls (fixed below scroll area)
            HStack(spacing: 12) {
                Button(action: editor.stepBackward) {
                    Image(systemName: "backward.frame.fill")
                }
                .buttonStyle(.plain)

                Button(action: editor.togglePlayPause) {
                    Image(systemName: editor.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)

                Button(action: editor.stepForward) {
                    Image(systemName: "forward.frame.fill")
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    editor.splitAtPlayhead()
                } label: {
                    Label("Split", systemImage: "scissors")
                        .font(.caption)
                }

                Button {
                    editor.deleteSelectedSegment()
                } label: {
                    Label("Delete", systemImage: "trash")
                        .font(.caption)
                }
                .disabled(editor.selectedSegmentID == nil)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(EditorColors.card)
        }
        .background(EditorColors.background)
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(EditorColors.secondary)
            .tracking(0.5)
            .padding(.leading, 8)
    }

    // MARK: - Time Ruler

    @ViewBuilder
    private var timeRuler: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            Canvas { context, size in
                let duration = editor.duration
                guard duration > 0, width > 0 else { return }

                let pxPerSec = Double(width) / duration
                let tickInterval: Double
                if pxPerSec > 80 { tickInterval = 1 }
                else if pxPerSec > 20 { tickInterval = 5 }
                else if pxPerSec > 8 { tickInterval = 15 }
                else { tickInterval = 30 }

                var t: Double = 0
                while t <= duration {
                    let x = CGFloat(t / duration) * width

                    // Tick mark
                    let tickPath = Path { p in
                        p.move(to: CGPoint(x: x, y: size.height - 4))
                        p.addLine(to: CGPoint(x: x, y: size.height))
                    }
                    context.stroke(tickPath, with: .color(Color.gray.opacity(0.5)), lineWidth: 1)

                    // Time label
                    let label = formatTimeCompact(t)
                    let text = Text(label)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(Color.gray)
                    context.draw(text, at: CGPoint(x: x + 2, y: size.height / 2 - 2), anchor: .leading)

                    t += tickInterval
                }
            }
        }
    }

    private func formatTimeCompact(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if mins > 0 {
            return String(format: "%d:%02d", mins, secs)
        }
        return String(format: "%ds", secs)
    }

    // MARK: - Video Timeline

    @ViewBuilder
    private var videoTimeline: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let segmentGap: CGFloat = 1.5

            ZStack(alignment: .leading) {
                // Track background
                RoundedRectangle(cornerRadius: 6)
                    .fill(EditorColors.trackBackground)

                // Segments with visual gap
                ForEach(editor.segments) { segment in
                    let rawStartX = sourceTimeToX(segment.sourceStart, width: width)
                    let rawEndX = sourceTimeToX(segment.sourceEnd, width: width)
                    let startX = rawStartX + segmentGap
                    let endX = rawEndX - segmentGap
                    let segWidth = max(0, endX - startX)
                    let isSelected = editor.selectedSegmentID == segment.id

                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            segment.enabled
                                ? (isSelected ? Color.white.opacity(0.12) : EditorColors.subtleFill)
                                : EditorColors.disabledSegment
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(
                                    isSelected
                                        ? AnyShapeStyle(EditorColors.selectedSegmentBorder)
                                        : AnyShapeStyle(EditorColors.subtleStroke),
                                    lineWidth: isSelected ? 2 : 0.5
                                )
                        )
                        .frame(width: segWidth, height: height - 6)
                        .offset(x: startX, y: 3)
                        .allowsHitTesting(false) // Selection handled by drag gesture below
                }

                // Disabled segment red overlay
                ForEach(editor.segments.filter { !$0.enabled }) { segment in
                    let startX = sourceTimeToX(segment.sourceStart, width: width) + segmentGap
                    let endX = sourceTimeToX(segment.sourceEnd, width: width) - segmentGap
                    Rectangle()
                        .fill(EditorColors.cutRegion)
                        .frame(width: max(0, endX - startX), height: height - 6)
                        .offset(x: startX, y: 3)
                        .allowsHitTesting(false)
                }

                // Blade hover indicator
                if editor.isBladeMode, let hoverX = bladeHoverX {
                    Rectangle()
                        .fill(EditorColors.bladeIndicator)
                        .frame(width: 2, height: height)
                        .offset(x: hoverX)
                        .allowsHitTesting(false)
                }

                // Playhead (positioned at source time)
                let playheadSrcTime = editor.sourceTime(forEditedTime: editor.currentTime)
                let playheadX = sourceTimeToX(playheadSrcTime, width: width)
                VStack(spacing: 0) {
                    // Top handle
                    RoundedRectangle(cornerRadius: 2)
                        .fill(EditorColors.playhead)
                        .frame(width: 8, height: 6)
                    // Vertical line
                    Rectangle()
                        .fill(EditorColors.playhead)
                        .frame(width: 2)
                }
                .frame(height: height + 4)
                .offset(x: playheadX - 4, y: -2)
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    if editor.isBladeMode {
                        bladeHoverX = location.x
                        NSCursor.crosshair.set()
                    }
                case .ended:
                    bladeHoverX = nil
                    if editor.isBladeMode { NSCursor.arrow.set() }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard width > 0 else { return }
                        if editor.isBladeMode {
                            bladeHoverX = value.location.x
                        } else {
                            // Scrub: convert click X → source time → edited time
                            if editor.isPlaying { editor.pause() }
                            let srcTime = max(0, min(editor.duration, (value.location.x / width) * editor.duration))
                            if let editedT = editor.editedTime(forSourceTime: srcTime) {
                                editor.currentTime = editedT
                            }
                        }
                    }
                    .onEnded { value in
                        guard width > 0 else { return }
                        let dragDist = abs(value.location.x - value.startLocation.x)
                            + abs(value.location.y - value.startLocation.y)

                        if editor.isBladeMode {
                            let srcTime = (value.location.x / width) * editor.duration
                            editor.splitAtSourceTime(srcTime)
                        } else if dragDist < 4 {
                            // Short tap → toggle segment selection
                            let srcTime = (value.location.x / width) * editor.duration
                            if let seg = editor.segment(atSourceTime: srcTime) {
                                editor.selectSegment(
                                    editor.selectedSegmentID == seg.id ? nil : seg.id
                                )
                            }
                        }
                    }
            )
        }
    }

    // MARK: - Zoom Timeline

    @ViewBuilder
    private var zoomTimeline: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let edgeThreshold: CGFloat = 6

            ZStack(alignment: .leading) {
                // Track background
                RoundedRectangle(cornerRadius: 6)
                    .fill(EditorColors.trackBackground)

                // Ghost block on hover
                if let hoverX = zoomHoverX, zoomDragStart == nil, resizingKeyframeID == nil {
                    let ghostDuration = min(3.0, max(0.5, editor.duration * 0.1))
                    let ghostHalfWidth = zoomTimeToX(ghostDuration / 2, width: width)
                    let ghostStart = max(0, hoverX - ghostHalfWidth)
                    let ghostEnd = min(width, hoverX + ghostHalfWidth)
                    let ghostStartTime = (ghostStart / width) * editor.duration
                    let ghostEndTime = (ghostEnd / width) * editor.duration
                    let overlapsExisting = editor.zoomKeyframes.contains { kf in
                        ghostStartTime < kf.endTime && ghostEndTime > kf.startTime
                    }
                    if !overlapsExisting {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.blue.opacity(0.15))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                            )
                            .frame(width: max(0, ghostEnd - ghostStart), height: height - 4)
                            .offset(x: ghostStart, y: 2)
                            .allowsHitTesting(false)
                    }
                }

                // Zoom regions
                ForEach(editor.zoomKeyframes) { kf in
                    let startX = zoomTimeToX(kf.startTime, width: width)
                    let endX = zoomTimeToX(kf.endTime, width: width)
                    ZStack {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(EditorColors.zoomBlock)
                        Text(String(format: "%.1fx", kf.zoomLevel))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white)
                    }
                    .frame(width: max(0, endX - startX), height: height - 4)
                    .offset(x: startX, y: 2)
                    .onTapGesture(count: 2) {
                        cycleZoomLevel(id: kf.id, current: kf.zoomLevel)
                    }
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            editor.removeZoomRegion(id: kf.id)
                        }
                    }
                }

                // Drag preview
                if let dragStart = zoomDragStart, let dragEnd = zoomDragEnd {
                    let minX = min(dragStart, dragEnd)
                    let maxX = max(dragStart, dragEnd)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.blue.opacity(0.25))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.blue.opacity(0.6), lineWidth: 1)
                        )
                        .frame(width: max(0, maxX - minX), height: height - 4)
                        .offset(x: minX, y: 2)
                }

                // Playhead
                Rectangle()
                    .fill(EditorColors.playhead.opacity(0.6))
                    .frame(width: 1, height: height)
                    .offset(x: zoomTimeToX(editor.currentTime, width: width))
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    zoomHoverX = location.x
                    var nearEdge = false
                    for kf in editor.zoomKeyframes {
                        let leftEdge = zoomTimeToX(kf.startTime, width: width)
                        let rightEdge = zoomTimeToX(kf.endTime, width: width)
                        if abs(location.x - leftEdge) < edgeThreshold || abs(location.x - rightEdge) < edgeThreshold {
                            nearEdge = true
                            break
                        }
                    }
                    if nearEdge {
                        NSCursor.resizeLeftRight.set()
                    } else {
                        NSCursor.arrow.set()
                    }
                case .ended:
                    zoomHoverX = nil
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard width > 0 else { return }

                        if zoomDragStart == nil && resizingKeyframeID == nil {
                            let startX = value.startLocation.x

                            for kf in editor.zoomKeyframes {
                                let leftEdge = zoomTimeToX(kf.startTime, width: width)
                                let rightEdge = zoomTimeToX(kf.endTime, width: width)
                                if abs(startX - leftEdge) < edgeThreshold {
                                    resizingKeyframeID = kf.id
                                    resizingEdge = .left
                                    editor.updateZoomRegionTimes(id: kf.id, pushUndo: true)
                                    return
                                }
                                if abs(startX - rightEdge) < edgeThreshold {
                                    resizingKeyframeID = kf.id
                                    resizingEdge = .right
                                    editor.updateZoomRegionTimes(id: kf.id, pushUndo: true)
                                    return
                                }
                            }

                            zoomDragStart = max(0, min(width, value.startLocation.x))
                        }

                        if let id = resizingKeyframeID, let edge = resizingEdge {
                            let time = max(0, min(editor.duration, (value.location.x / width) * editor.duration))
                            switch edge {
                            case .left:
                                editor.updateZoomRegionTimes(id: id, startTime: time)
                            case .right:
                                editor.updateZoomRegionTimes(id: id, endTime: time)
                            }
                        } else {
                            zoomDragEnd = max(0, min(width, value.location.x))
                        }
                    }
                    .onEnded { value in
                        if resizingKeyframeID != nil {
                            resizingKeyframeID = nil
                            resizingEdge = nil
                            return
                        }

                        guard width > 0 else {
                            zoomDragStart = nil
                            zoomDragEnd = nil
                            return
                        }

                        let savedStart = zoomDragStart
                        let savedEnd = zoomDragEnd
                        zoomDragStart = nil
                        zoomDragEnd = nil

                        guard let start = savedStart, let end = savedEnd else {
                            let time = (value.location.x / width) * editor.duration
                            let blockDuration = min(3.0, max(0.5, editor.duration * 0.1))
                            let startTime = max(0, time - blockDuration / 2)
                            let endTime = min(editor.duration, time + blockDuration / 2)
                            if endTime - startTime >= 0.2 {
                                editor.addZoomRegion(start: startTime, end: endTime, level: 2.0)
                            }
                            return
                        }

                        let minX = min(start, end)
                        let maxX = max(start, end)
                        let dragDistance = maxX - minX

                        if dragDistance < 4 {
                            let time = (value.location.x / width) * editor.duration
                            let blockDuration = min(3.0, max(0.5, editor.duration * 0.1))
                            let startTime = max(0, time - blockDuration / 2)
                            let endTime = min(editor.duration, time + blockDuration / 2)
                            if endTime - startTime >= 0.2 {
                                editor.addZoomRegion(start: startTime, end: endTime, level: 2.0)
                            }
                        } else {
                            let startTime = (minX / width) * editor.duration
                            let endTime = (maxX / width) * editor.duration
                            if endTime - startTime >= 0.2 {
                                editor.addZoomRegion(start: startTime, end: endTime, level: 2.0)
                            }
                        }
                    }
            )
            .onScrollWheel { delta, location in
                guard width > 0 else { return }
                let time = (location.x / width) * editor.duration
                if let kf = editor.zoomKeyframes.first(where: {
                    time >= $0.startTime && time <= $0.endTime
                }) {
                    let newLevel = kf.zoomLevel + delta * 0.1
                    editor.updateZoomLevel(id: kf.id, level: newLevel)
                }
            }
        }
    }

    // MARK: - Waveform View

    @ViewBuilder
    private func waveformView(samples: [Float], color: Color, label: String) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height

            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(EditorColors.trackBackground)

                if samples.isEmpty {
                    Text(label)
                        .font(.system(size: 9))
                        .foregroundColor(EditorColors.secondary)
                } else {
                    Canvas { context, size in
                        let count = samples.count
                        guard count > 0 else { return }
                        let barWidth = size.width / CGFloat(count)
                        let midY = size.height / 2

                        for i in 0..<count {
                            let amplitude = CGFloat(samples[i])
                            let barHeight = max(1, amplitude * midY)
                            let x = CGFloat(i) * barWidth
                            let rect = CGRect(
                                x: x,
                                y: midY - barHeight,
                                width: max(1, barWidth - 0.5),
                                height: barHeight * 2
                            )
                            context.fill(Path(rect), with: .color(color.opacity(0.6)))
                        }
                    }
                }

                // Playhead
                Rectangle()
                    .fill(EditorColors.playhead.opacity(0.4))
                    .frame(width: 1, height: height)
                    .offset(x: sourceTimeToX(
                        editor.sourceTime(forEditedTime: editor.currentTime),
                        width: width
                    ))
            }
        }
    }

    // MARK: - Markers Row

    @ViewBuilder
    private var markersRow: some View {
        GeometryReader { geometry in
            let width = geometry.size.width

            ZStack(alignment: .leading) {
                ForEach(editor.markers) { marker in
                    let x = sourceTimeToX(marker.time, width: width)
                    MarkerFlag(color: marker.color.color)
                        .frame(width: 10, height: 16)
                        .offset(x: x - 5)
                        .onTapGesture {
                            editor.jumpToMarker(id: marker.id)
                        }
                        .contextMenu {
                            Text(marker.label.isEmpty ? "Marker" : marker.label)
                            ForEach(MarkerColor.allCases) { mc in
                                Button {
                                    editor.updateMarkerColor(id: marker.id, color: mc)
                                } label: {
                                    Label(mc.rawValue.capitalized, systemImage: "circle.fill")
                                }
                            }
                            Divider()
                            Button("Delete", role: .destructive) {
                                editor.removeMarker(id: marker.id)
                            }
                        }
                }
            }
        }
    }

    // MARK: - Zoom Helpers

    private func cycleZoomLevel(id: UUID, current: Double) {
        let presets: [Double] = [1.5, 2.0, 2.5, 3.0]
        let nextIndex = presets.firstIndex(where: { $0 > current + 0.05 }) ?? 0
        editor.updateZoomLevel(id: id, level: presets[nextIndex])
    }

    // MARK: - Webcam Panel

    @ViewBuilder
    private var webcamPanel: some View {
        DisclosureGroup("Webcam") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Show Webcam", isOn: $editor.webcamEnabled)
                    .font(.caption)

                if editor.webcamEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Size: \(String(format: "%.0f%%", editor.webcamScale * 100))")
                            .font(.caption)
                        Slider(value: $editor.webcamScale, in: 0.5...2.0, step: 0.1)
                    }

                    Text("Drag the webcam circle in the preview to reposition.")
                        .font(.system(size: 10))
                        .foregroundColor(EditorColors.secondary)
                }
            }
            .padding(.top, 4)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(EditorColors.card))
    }

    // MARK: - Cursor Effects Panel

    @ViewBuilder
    private var cursorEffectsPanel: some View {
        DisclosureGroup("Cursor Effects") {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cursor Color")
                        .font(.caption)
                    HStack(spacing: 6) {
                        ForEach(CursorStyle.allCases) { style in
                            Button {
                                editor.cursorStyle = style
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(Color(hex: style.fillHex))
                                        .frame(width: 24, height: 24)
                                    Circle()
                                        .stroke(
                                            editor.cursorStyle == style
                                                ? Color.accentColor
                                                : Color(hex: style.strokeHex).opacity(0.5),
                                            lineWidth: editor.cursorStyle == style ? 2.5 : 1
                                        )
                                        .frame(width: 24, height: 24)
                                }
                            }
                            .buttonStyle(.plain)
                            .help(style.label)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Cursor Scale: \(String(format: "%.1fx", editor.cursorScale))")
                        .font(.caption)
                    Slider(value: $editor.cursorScale, in: 1...5, step: 0.5)
                }

                Toggle("Click Animation", isOn: $editor.clickHighlightEnabled)
                    .font(.caption)

                Toggle("Cursor Smoothing", isOn: $editor.cursorSmoothingEnabled)
                    .font(.caption)
            }
            .padding(.top, 4)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(EditorColors.card))
    }

    // MARK: - Audio Tracks Panel

    @ViewBuilder
    private var audioTracksPanel: some View {
        DisclosureGroup("Audio") {
            VStack(spacing: 12) {
                audioTrack(
                    label: "Microphone",
                    icon: "mic.fill",
                    volume: $editor.micVolume,
                    muted: $editor.micMuted
                )

                audioTrack(
                    label: "System Audio",
                    icon: "speaker.wave.2.fill",
                    volume: $editor.systemVolume,
                    muted: $editor.systemMuted
                )
            }
            .padding(.top, 4)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(EditorColors.card))
    }

    @ViewBuilder
    private func audioTrack(
        label: String,
        icon: String,
        volume: Binding<Float>,
        muted: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon)
                    .font(.caption)
                Text(label)
                    .font(.caption)
                Spacer()
                Button(action: { muted.wrappedValue.toggle() }) {
                    Image(systemName: muted.wrappedValue ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.caption)
                        .foregroundColor(muted.wrappedValue ? .red : .primary)
                }
                .buttonStyle(.plain)
            }

            HStack {
                Text("Vol")
                    .font(.system(size: 9))
                    .foregroundColor(EditorColors.secondary)
                Slider(value: volume, in: 0...2)
                Text(String(format: "%.0f%%", volume.wrappedValue * 100))
                    .font(.system(size: 9))
                    .foregroundColor(EditorColors.secondary)
                    .frame(width: 32, alignment: .trailing)
            }
        }
    }

    // MARK: - Helpers

    /// Map source time to X position (for segment rendering on the full source timeline)
    private func sourceTimeToX(_ time: TimeInterval, width: CGFloat) -> CGFloat {
        guard editor.duration > 0 else { return 0 }
        return CGFloat(time / editor.duration) * width
    }

    /// Map edited-timeline time to X position (for playhead and waveform overlay)
    private func editedTimeToX(_ time: TimeInterval, width: CGFloat) -> CGFloat {
        guard editor.editedDuration > 0 else { return 0 }
        return CGFloat(time / editor.editedDuration) * width
    }

    /// Map source time to X for zoom timeline (always uses full source duration)
    private func zoomTimeToX(_ time: TimeInterval, width: CGFloat) -> CGFloat {
        guard editor.duration > 0 else { return 0 }
        return CGFloat(time / editor.duration) * width
    }

    // MARK: - Audio Sync

    private func updateAudioVolumes() {
        editor.rebuildAudioMix()
    }

    // MARK: - Keyboard Shortcuts

    private var editorShortcuts: [EditorShortcut] {
        [
            EditorShortcut(key: " ", modifiers: []) { editor.togglePlayPause() },
            EditorShortcut(key: .rightArrow, modifiers: []) { editor.stepForward() },
            EditorShortcut(key: .leftArrow, modifiers: []) { editor.stepBackward() },
            EditorShortcut(key: "b", modifiers: []) { editor.toggleBladeMode() },
            EditorShortcut(key: "m", modifiers: []) { editor.addMarker() },
            EditorShortcut(key: .delete, modifiers: []) { editor.deleteSelectedSegment() },
        ]
    }
}

// MARK: - MarkerFlag Shape

private struct MarkerFlag: View {
    let color: Color

    var body: some View {
        ZStack {
            Triangle()
                .fill(color)
            Triangle()
                .stroke(color.opacity(0.8), lineWidth: 1)
        }
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Keyboard Shortcut Support

private struct EditorShortcut {
    let key: KeyEquivalent
    let modifiers: EventModifiers
    let action: () -> Void
}

private extension View {
    func keyboardShortcut(shortcuts: [EditorShortcut]) -> some View {
        self.background(
            ForEach(0..<shortcuts.count, id: \.self) { index in
                Button("") { shortcuts[index].action() }
                    .keyboardShortcut(shortcuts[index].key, modifiers: shortcuts[index].modifiers)
                    .frame(width: 0, height: 0)
                    .opacity(0)
            }
        )
    }
}

// MARK: - Time Formatting

func formatTime(_ seconds: TimeInterval) -> String {
    let totalSeconds = Int(seconds)
    let minutes = totalSeconds / 60
    let secs = totalSeconds % 60
    let frames = Int((seconds - Double(totalSeconds)) * 60) // frame count at 60fps
    return String(format: "%02d:%02d.%02d", minutes, secs, frames)
}

// MARK: - Scroll Wheel Modifier

private struct ScrollWheelModifier: ViewModifier {
    let handler: (Double, CGPoint) -> Void

    func body(content: Content) -> some View {
        content.background(ScrollWheelView(handler: handler))
    }
}

private struct ScrollWheelView: NSViewRepresentable {
    let handler: (Double, CGPoint) -> Void

    func makeNSView(context: Context) -> ScrollWheelNSView {
        let view = ScrollWheelNSView()
        view.handler = handler
        return view
    }

    func updateNSView(_ nsView: ScrollWheelNSView, context: Context) {
        nsView.handler = handler
    }
}

private class ScrollWheelNSView: NSView {
    var handler: ((Double, CGPoint) -> Void)?
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil // Never intercept mouse clicks or drags
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let handler = self.handler else { return event }
                let location = self.convert(event.locationInWindow, from: nil)
                if self.bounds.contains(location) {
                    handler(Double(event.deltaY), CGPoint(x: location.x, y: location.y))
                }
                return event
            }
        }
    }

    override func removeFromSuperview() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        super.removeFromSuperview()
    }
}

private extension View {
    func onScrollWheel(_ handler: @escaping (Double, CGPoint) -> Void) -> some View {
        modifier(ScrollWheelModifier(handler: handler))
    }
}

// MARK: - Zoom Resize Edge

private enum ZoomResizeEdge {
    case left, right
}
