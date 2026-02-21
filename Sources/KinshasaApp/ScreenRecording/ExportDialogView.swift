import SwiftUI

// MARK: - ExportDialogView

struct ExportDialogView: View {
    @Bindable var editor: VideoEditorController

    // MARK: - State

    @State private var codec: VideoCodec = .h264
    @State private var quality: ExportQuality = .high
    @State private var resolution: ExportResolution = .original
    @State private var isExporting = false
    @State private var progress: Double = 0

    // MARK: - Closures

    var onExport: (VideoCodec, ExportQuality, ExportResolution) -> Void
    var onCancel: () -> Void

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Title
            Text("Export Recording")
                .font(.title2)
                .fontWeight(.semibold)

            Divider()

            // Codec picker
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

            // Quality picker
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

            // Resolution picker
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

            // Save destination
            VStack(alignment: .leading, spacing: 4) {
                Text("Save to")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .foregroundColor(.secondary)
                    Text("~/Documents/Actionfy Recordings/")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.primary)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
            }

            // Export progress
            if isExporting {
                VStack(spacing: 8) {
                    ProgressView(value: progress, total: 1.0)
                        .progressViewStyle(.linear)
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }

            Divider()

            // Action bar
            HStack {
                Spacer()

                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Button("Export") {
                    isExporting = true
                    onExport(codec, quality, resolution)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isExporting)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 400)
    }
}
