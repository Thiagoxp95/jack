import SwiftUI
import AppKit
import UniformTypeIdentifiers
import os

// MARK: - ExportPhase

enum ExportPhase: Equatable {
    case settings
    case exporting
    case done(URL)
    case error(String)
}

// MARK: - ExportDialogView

struct ExportDialogView: View {
    @Bindable var editor: VideoEditorController

    // MARK: - State

    @State private var codec: VideoCodec = .h264
    @State private var quality: ExportQuality = .high
    @State private var resolution: ExportResolution = .original
    @State private var phase: ExportPhase = .settings
    @State private var progress: Double = 0
    @State private var exportTask: Task<Void, Never>?

    // MARK: - Closures

    var onDismiss: () -> Void

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch phase {
            case .settings:
                settingsContent
            case .exporting:
                exportingContent
            case .done(let url):
                doneContent(url: url)
            case .error(let message):
                errorContent(message: message)
            }
        }
        .padding(24)
        .frame(width: 400)
    }

    // MARK: - Settings Phase

    @ViewBuilder
    private var settingsContent: some View {
        Text("Export Recording")
            .font(.title2)
            .fontWeight(.semibold)

        Divider()

        VStack(alignment: .leading, spacing: 6) {
            Text("Codec")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Picker("Codec", selection: $codec) {
                ForEach(VideoCodec.allCases) { c in
                    Text(c.label).tag(c)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }

        VStack(alignment: .leading, spacing: 6) {
            Text("Quality")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Picker("Quality", selection: $quality) {
                ForEach(ExportQuality.allCases) { q in
                    Text(q.label).tag(q)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }

        VStack(alignment: .leading, spacing: 6) {
            Text("Resolution")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Picker("Resolution", selection: $resolution) {
                ForEach(ExportResolution.allCases) { r in
                    Text(r.label).tag(r)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }

        Divider()

        HStack {
            Spacer()

            Button("Cancel", action: onDismiss)
                .keyboardShortcut(.cancelAction)

            Button("Export...") {
                presentSavePanel()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Exporting Phase

    @ViewBuilder
    private var exportingContent: some View {
        Text("Exporting...")
            .font(.title2)
            .fontWeight(.semibold)

        Divider()

        VStack(spacing: 8) {
            ProgressView(value: progress, total: 1.0)
                .progressViewStyle(.linear)
            Text("\(Int(progress * 100))%")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }

        Divider()

        HStack {
            Spacer()
            Button("Cancel") {
                exportTask?.cancel()
                phase = .settings
            }
        }
    }

    // MARK: - Done Phase

    @ViewBuilder
    private func doneContent(url: URL) -> some View {
        Text("Export Complete")
            .font(.title2)
            .fontWeight(.semibold)

        Divider()

        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.title3)
            Text(url.lastPathComponent)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        }

        Divider()

        HStack {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Spacer()
            Button("Done", action: onDismiss)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Error Phase

    @ViewBuilder
    private func errorContent(message: String) -> some View {
        Text("Export Failed")
            .font(.title2)
            .fontWeight(.semibold)

        Divider()

        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
                .font(.title3)
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
        }

        Divider()

        HStack {
            Spacer()
            Button("Back") {
                phase = .settings
            }
            Button("Close", action: onDismiss)
                .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: - NSSavePanel

    private func presentSavePanel() {
        let panel = NSSavePanel()
        panel.title = "Export Recording"
        panel.nameFieldStringValue = defaultFilename()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true

        let exportDir = RecordingSessionController.exportDirectory
        let fm = FileManager.default
        if !fm.fileExists(atPath: exportDir.path) {
            try? fm.createDirectory(at: exportDir, withIntermediateDirectories: true)
        }
        panel.directoryURL = exportDir

        guard panel.runModal() == .OK, let url = panel.url else { return }

        startExport(outputURL: url)
    }

    private func defaultFilename() -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return "Recording-\(timestamp).mp4"
    }

    // MARK: - Export Execution

    private func startExport(outputURL: URL) {
        phase = .exporting
        progress = 0

        let config = ExportConfiguration(
            codec: codec,
            quality: quality,
            resolution: resolution,
            outputURL: outputURL
        )

        let session = editor.session
        let editorRef = editor

        exportTask = Task {
            do {
                let exportService = ExportService()
                try await exportService.exportWithEffects(
                    session: session,
                    editor: editorRef,
                    config: config,
                    progress: { value in
                        Task { @MainActor in
                            progress = value
                        }
                    }
                )

                await MainActor.run {
                    phase = .done(outputURL)
                }
            } catch is CancellationError {
                await MainActor.run {
                    phase = .settings
                }
            } catch {
                await MainActor.run {
                    phase = .error(error.localizedDescription)
                }
            }
        }
    }
}
