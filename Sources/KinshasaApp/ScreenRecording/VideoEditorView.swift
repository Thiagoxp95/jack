import SwiftUI

// MARK: - VideoEditorView

struct VideoEditorView: View {
    @Bindable var editor: VideoEditorController
    var onDone: () -> Void
    var onExport: () -> Void
    @State private var lastScrubTime: Date = .distantPast

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

            Button("Export", action: onExport)
                .buttonStyle(.borderedProminent)

            Button("Done", action: onDone)
        }
    }

    // MARK: - Video Preview

    @ViewBuilder
    private var videoPreview: some View {
        GeometryReader { geometry in
            ZStack {
                MetalPreviewView(session: editor.session, editor: editor)
                    .background(Color.black)
                    .overlay {
                        // Custom cursor overlay
                        CursorOverlayView(editor: editor)
                    }

                // Webcam overlay
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
        }
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
                }

                // Playhead
                Rectangle()
                    .fill(Color.white.opacity(0.6))
                    .frame(width: 1, height: height)
                    .offset(x: timeToX(editor.currentTime, width: width))
            }
        }
        .padding(.horizontal, 8)
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

                // Click highlight toggle
                Toggle("Click Highlight", isOn: $editor.clickHighlightEnabled)
                    .font(.caption)

                if editor.clickHighlightEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Highlight Opacity: \(String(format: "%.0f%%", editor.clickHighlightOpacity * 100))")
                            .font(.caption)
                        Slider(value: $editor.clickHighlightOpacity, in: 0.1...1.0, step: 0.05)
                    }
                }

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
