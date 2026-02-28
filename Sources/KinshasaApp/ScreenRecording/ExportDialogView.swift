import AppKit
import SwiftUI

// MARK: - ExportPhase

enum ExportPhase: Equatable {
    case exporting
    case done(URL)
    case error(String)
}

// MARK: - Notification

extension Notification.Name {
    static let recordingExported = Notification.Name("recordingExported")
    static let showRecordingsTab = Notification.Name("showRecordingsTab")
    static let showSection = Notification.Name("showSection")
    static let toggleScreenRecording = Notification.Name("toggleScreenRecording")
    static let toggleTodoSheet = Notification.Name("toggleTodoSheet")
    static let statusBarVisibilityChanged = Notification.Name("statusBarVisibilityChanged")
}

// MARK: - ExportDialogView

struct ExportDialogView: View {
    @Bindable var editor: VideoEditorController
    var spaceController: SpaceController?

    // MARK: - State

    @State private var phase: ExportPhase = .exporting
    @State private var progress: Double = 0
    @State private var exportTask: Task<Void, Never>?
    @State private var exportService: ExportService?

    // MARK: - Closures

    var onDismiss: () -> Void

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch phase {
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
        .interactiveDismissDisabled(phase == .exporting)
        .task {
            startExport()
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
                exportService?.cancel()
                exportTask?.cancel()
                onDismiss()
            }
        }
    }

    // MARK: - Done Phase

    @ViewBuilder
    private func doneContent(url: URL) -> some View {
        Text("Upload Queued")
            .font(.title2)
            .fontWeight(.semibold)

        Divider()

        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.title3)
            Text("Recording will upload in the background.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Divider()

        HStack {
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
            Button("Retry") {
                startExport()
            }
            Button("Close", action: onDismiss)
                .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: - Export

    private func generateOutputURL() -> URL {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let exportDir = cacheDir.appendingPathComponent("Actionfy/exports", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: exportDir.path) {
            try? fm.createDirectory(at: exportDir, withIntermediateDirectories: true)
        }
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return exportDir.appendingPathComponent("Recording-\(timestamp).mp4")
    }

    private func startExport() {
        phase = .exporting
        progress = 0

        let outputURL = generateOutputURL()

        let config = ExportConfiguration(
            codec: .h265,
            quality: .high,
            resolution: .original,
            fileFormat: .mp4,
            aspectRatio: editor.aspectRatio,
            outputURL: outputURL
        )

        let session = editor.session
        let editorRef = editor

        exportTask = Task {
            do {
                let service = ExportService()
                await MainActor.run { exportService = service }
                try await service.exportWithEffects(
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
                    // Enqueue for background upload
                    let title = outputURL.deletingPathExtension().lastPathComponent
                    let duration = editorRef.session.duration
                    UploadQueue.shared.enqueue(
                        filePath: outputURL.path,
                        title: title,
                        duration: duration,
                        spaceId: spaceController?.currentSpaceId
                    )
                    phase = .done(outputURL)
                }
            } catch is CancellationError {
                await MainActor.run {
                    onDismiss()
                }
            } catch {
                await MainActor.run {
                    phase = .error(error.localizedDescription)
                }
            }
        }
    }
}
