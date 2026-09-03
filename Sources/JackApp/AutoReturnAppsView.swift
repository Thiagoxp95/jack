import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Picks the apps where a pasted transcript should be followed by Return.
///
/// Running apps are offered as checkboxes because that's where the user just
/// dictated; anything not running is added through the file picker.
struct AutoReturnAppsView: View {
    @Binding var apps: [AutoReturnApp]
    @State private var runningApps: [AutoReturnApp] = []

    /// Selected apps first, then everything else that's running.
    private var listedApps: [AutoReturnApp] {
        var listed = apps
        for running in runningApps where !listed.contains(where: { $0.bundleID == running.bundleID }) {
            listed.append(running)
        }
        return listed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Press Return In")
                .font(.headline)

            Text("After a transcript is pasted into one of these apps, Silky presses Return — so a dictated message sends itself. Every other app is left alone.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach(listedApps) { app in
                    Toggle(isOn: binding(for: app)) {
                        HStack(spacing: 8) {
                            appIcon(for: app.bundleID)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.name)
                                    .font(.body)
                                Text(app.bundleID)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 200, maxHeight: 340)

            HStack {
                Button("Add App…") {
                    chooseApp()
                }
                Spacer()
                Text("\(apps.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .onAppear {
            runningApps = AutoReturnAppCatalog.runningApps()
        }
    }

    @ViewBuilder
    private func appIcon(for bundleID: String) -> some View {
        if let icon = AutoReturnAppCatalog.icon(for: bundleID) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 18, height: 18)
        } else {
            Image(systemName: "app.dashed")
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
        }
    }

    private func binding(for app: AutoReturnApp) -> Binding<Bool> {
        Binding(
            get: { apps.contains { $0.bundleID == app.bundleID } },
            set: { isOn in
                if isOn {
                    guard !apps.contains(where: { $0.bundleID == app.bundleID }) else { return }
                    apps.append(app)
                } else {
                    apps.removeAll { $0.bundleID == app.bundleID }
                }
            }
        )
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"

        guard panel.runModal() == .OK,
              let url = panel.url,
              let app = AutoReturnAppCatalog.app(atBundleURL: url)
        else {
            return
        }

        guard !apps.contains(where: { $0.bundleID == app.bundleID }) else { return }
        apps.append(app)
    }
}
