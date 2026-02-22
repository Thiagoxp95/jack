import SwiftUI

// MARK: - VideoEditorView

struct VideoEditorView: View {
    @Bindable var editor: VideoEditorController
    var onDone: () -> Void
    @State private var showExportSheet = false
    @State private var lastScrubTime: Date = .distantPast
    @State private var zoomDragStart: CGFloat?
    @State private var zoomDragEnd: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            editorToolbar
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Main content
            HStack(spacing: 0) {
                // Left: Video preview + timeline
                VStack(spacing: 0) {
                    videoPreview
                        .frame(minHeight: 300)

                    Divider()

                    timelinePanel
                        .frame(minHeight: 200)
                }
                .frame(maxWidth: .infinity)

                Divider()

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
                .background(Color(nsColor: .controlBackgroundColor))
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

            Text(formatTime(editor.currentTime))
                .font(.system(.title3, design: .monospaced))
                .foregroundColor(.white)

            Text(" / ")
                .foregroundColor(.gray)

            Text(formatTime(editor.duration))
                .font(.system(.title3, design: .monospaced))
                .foregroundColor(.gray)

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
            let time = editor.isPlaying ? editor.smoothTime : editor.currentTime
            let zoomLevel = MetalVideoRenderer.interpolateZoom(
                at: time,
                keyframes: editor.zoomKeyframes,
                rampDuration: MetalVideoRenderer.cinematicRampDuration
            )
            let anchor = previewZoomAnchor(at: time, viewSize: geometry.size)

            ZStack {
                // Zoomable content: video + cursor (zoomed together)
                MetalPreviewView(session: editor.session, editor: editor)
                    .background(Color.black)
                    .overlay {
                        CursorOverlayView(editor: editor)
                    }
                    .scaleEffect(zoomLevel, anchor: anchor)

                // Webcam overlay (not zoomed — it's a separate camera feed)
                WebcamEditorOverlay(editor: editor, viewSize: geometry.size)

                // Play/Pause overlay
                if !editor.isPlaying {
                    Button(action: editor.togglePlayPause) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 64))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .clipped()
        }
    }

    /// Computes the zoom anchor point in view coordinates, centered on the cursor.
    /// The cursor is always the anchor so it's always visible in the zoomed viewport.
    /// .clipped() on the parent prevents overflow — no clamping needed.
    private func previewZoomAnchor(at time: TimeInterval, viewSize: CGSize) -> UnitPoint {
        let screenSize = editor.session.screenSize
        guard screenSize.width > 0, screenSize.height > 0,
              let pos = editor.cursorPosition(at: time) else {
            return .center
        }

        // Map cursor from screen coords to view coords (accounting for letterboxing)
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

        // Shift anchor from cursor tip to cursor body center so the full
        // arrow shape is visible at edges. The cursor arrow extends right
        // and down from the tip by (14*scale, 20*scale).
        let bodyX = viewX + 7.0 * editor.cursorScale
        let bodyY = viewY + 10.0 * editor.cursorScale

        // Normalize to UnitPoint (0-1 relative to view), clamped to bounds
        let normX = max(0, min(1, bodyX / viewSize.width))
        let normY = max(0, min(1, bodyY / viewSize.height))

        return UnitPoint(x: normX, y: normY)
    }

    // MARK: - Timeline Panel

    @ViewBuilder
    private var timelinePanel: some View {
        VStack(spacing: 4) {
            // Video timeline
            VStack(alignment: .leading, spacing: 2) {
                Text("Video")
                    .font(.caption)
                    .foregroundColor(.gray)
                    .padding(.leading, 8)

                videoTimeline
                    .frame(height: 40)
            }

            // Zoom timeline
            VStack(alignment: .leading, spacing: 2) {
                Text("Zoom")
                    .font(.caption)
                    .foregroundColor(.gray)
                    .padding(.leading, 8)

                zoomTimeline
                    .frame(height: 30)
            }

            // Playback controls
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

                Button("Set In") {
                    editor.setInPoint()
                }
                .font(.caption)

                Button("Set Out") {
                    editor.setOutPoint()
                }
                .font(.caption)

                Button("Delete Selection") {
                    editor.deleteSelection()
                }
                .font(.caption)
                .disabled(editor.inPoint == nil || editor.outPoint == nil)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Video Timeline

    @ViewBuilder
    private var videoTimeline: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height

            ZStack(alignment: .leading) {
                // Track background
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.3))

                // Cut regions (red overlays)
                ForEach(editor.cuts) { cut in
                    let startX = timeToX(cut.inPoint, width: width)
                    let endX = timeToX(cut.outPoint, width: width)
                    Rectangle()
                        .fill(Color.red.opacity(0.4))
                        .frame(width: max(0, endX - startX), height: height)
                        .offset(x: startX)
                }

                // In point marker (yellow line)
                if let inPt = editor.inPoint {
                    Rectangle()
                        .fill(Color.yellow)
                        .frame(width: 2, height: height)
                        .offset(x: timeToX(inPt, width: width))
                }

                // Out point marker (yellow line)
                if let outPt = editor.outPoint {
                    Rectangle()
                        .fill(Color.yellow)
                        .frame(width: 2, height: height)
                        .offset(x: timeToX(outPt, width: width))
                }

                // Playhead (white line)
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: height)
                    .offset(x: timeToX(editor.currentTime, width: width))
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    guard width > 0 else { return }
                    let now = Date()
                    guard now.timeIntervalSince(lastScrubTime) >= 1.0 / 30.0 else { return }
                    lastScrubTime = now

                    if editor.isPlaying {
                        editor.pause()
                    }
                    let ratio = max(0, min(1, location.x / width))
                    editor.currentTime = ratio * editor.duration
                case .ended:
                    break
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard width > 0 else { return }
                        if editor.isPlaying {
                            editor.pause()
                        }
                        let ratio = max(0, min(1, value.location.x / width))
                        editor.currentTime = ratio * editor.duration
                    }
            )
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Zoom Timeline

    @ViewBuilder
    private var zoomTimeline: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height

            ZStack(alignment: .leading) {
                // Track background
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.2))

                // Zoom regions (blue)
                ForEach(editor.zoomKeyframes) { kf in
                    let startX = timeToX(kf.startTime, width: width)
                    let endX = timeToX(kf.endTime, width: width)
                    ZStack {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.blue.opacity(0.4))
                        Text(String(format: "%.1fx", kf.zoomLevel))
                            .font(.system(size: 9))
                            .foregroundColor(.white)
                    }
                    .frame(width: max(0, endX - startX), height: height - 4)
                    .offset(x: startX)
                    .onTapGesture(count: 2) {
                        cycleZoomLevel(id: kf.id, current: kf.zoomLevel)
                    }
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            editor.removeZoomRegion(id: kf.id)
                        }
                    }
                }

                // Drag preview (semi-transparent while drawing)
                if let dragStart = zoomDragStart, let dragEnd = zoomDragEnd {
                    let minX = min(dragStart, dragEnd)
                    let maxX = max(dragStart, dragEnd)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.blue.opacity(0.25))
                        .stroke(Color.blue.opacity(0.6), lineWidth: 1)
                        .frame(width: max(0, maxX - minX), height: height - 4)
                        .offset(x: minX)
                }

                // Playhead
                Rectangle()
                    .fill(Color.white.opacity(0.6))
                    .frame(width: 1, height: height)
                    .offset(x: timeToX(editor.currentTime, width: width))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        guard width > 0 else { return }
                        if zoomDragStart == nil {
                            zoomDragStart = max(0, min(width, value.startLocation.x))
                        }
                        zoomDragEnd = max(0, min(width, value.location.x))
                    }
                    .onEnded { value in
                        guard width > 0,
                              let dragStart = zoomDragStart,
                              let dragEnd = zoomDragEnd else {
                            zoomDragStart = nil
                            zoomDragEnd = nil
                            return
                        }

                        let minX = min(dragStart, dragEnd)
                        let maxX = max(dragStart, dragEnd)
                        let startTime = (minX / width) * editor.duration
                        let endTime = (maxX / width) * editor.duration

                        // Only create if the region is at least 0.2 seconds
                        if endTime - startTime >= 0.2 {
                            editor.addZoomRegion(start: startTime, end: endTime, level: 2.0)
                        }

                        zoomDragStart = nil
                        zoomDragEnd = nil
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
        .padding(.horizontal, 8)
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
                    // Webcam scale slider
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Size: \(String(format: "%.0f%%", editor.webcamScale * 100))")
                            .font(.caption)
                        Slider(value: $editor.webcamScale, in: 0.5...2.0, step: 0.1)
                    }

                    Text("Drag the webcam circle in the preview to reposition.")
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                }
            }
            .padding(.top, 4)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
    }

    // MARK: - Cursor Effects Panel

    @ViewBuilder
    private var cursorEffectsPanel: some View {
        DisclosureGroup("Cursor Effects") {
            VStack(alignment: .leading, spacing: 12) {
                // Cursor style picker
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

                // Cursor scale slider
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cursor Scale: \(String(format: "%.1fx", editor.cursorScale))")
                        .font(.caption)
                    Slider(value: $editor.cursorScale, in: 1...5, step: 0.5)
                }

                // Click press animation toggle
                Toggle("Click Animation", isOn: $editor.clickHighlightEnabled)
                    .font(.caption)

                // Cursor smoothing toggle
                Toggle("Cursor Smoothing", isOn: $editor.cursorSmoothingEnabled)
                    .font(.caption)
            }
            .padding(.top, 4)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
    }

    // MARK: - Audio Tracks Panel

    @ViewBuilder
    private var audioTracksPanel: some View {
        DisclosureGroup("Audio") {
            VStack(spacing: 12) {
                // Microphone track
                audioTrack(
                    label: "Microphone",
                    icon: "mic.fill",
                    volume: $editor.micVolume,
                    muted: $editor.micMuted
                )

                // System audio track
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
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
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

            // Waveform placeholder
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.gray.opacity(0.2))
                .frame(height: 24)
                .overlay {
                    Text("Waveform")
                        .font(.system(size: 9))
                        .foregroundColor(.gray)
                }

            // Volume slider
            HStack {
                Text("Vol")
                    .font(.system(size: 9))
                    .foregroundColor(.gray)
                Slider(value: volume, in: 0...2)
                Text(String(format: "%.0f%%", volume.wrappedValue * 100))
                    .font(.system(size: 9))
                    .foregroundColor(.gray)
                    .frame(width: 32, alignment: .trailing)
            }
        }
    }

    // MARK: - Helpers

    private func timeToX(_ time: TimeInterval, width: CGFloat) -> CGFloat {
        guard editor.duration > 0 else { return 0 }
        return CGFloat(time / editor.duration) * width
    }

    // MARK: - Keyboard Shortcuts

    private var editorShortcuts: [EditorShortcut] {
        [
            EditorShortcut(key: " ", modifiers: []) { editor.togglePlayPause() },
            EditorShortcut(key: .rightArrow, modifiers: []) { editor.stepForward() },
            EditorShortcut(key: .leftArrow, modifiers: []) { editor.stepBackward() },
        ]
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
