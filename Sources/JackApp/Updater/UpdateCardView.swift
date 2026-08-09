import SwiftUI

/// Sidebar card shown only when an update is downloaded and ready, or failed.
struct UpdateCardView: View {
    @ObservedObject var updater: AppUpdater
    var accent: Color

    var body: some View {
        if updater.isCardVisible {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: isError ? "exclamationmark.triangle.fill" : "arrow.down.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(isError ? Color.red : Color.green)
                    Text(isError ? "UPDATE FAILED" : "SOFTWARE UPDATE")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        updater.dismissCard()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }

                Text(titleText)
                    .font(.system(size: 12, weight: .semibold))

                Text(subtitleText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)

                HStack(spacing: 8) {
                    Button {
                        if isError {
                            updater.checkForUpdates()
                        } else {
                            updater.installAndRelaunch()
                        }
                    } label: {
                        Text(buttonText)
                            .font(.system(size: 11, weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .disabled(updater.isInstalling)

                    if !isError {
                        Link(destination: URL(string: "https://github.com/Thiagoxp95/jack/releases")!) {
                            Text("Notes")
                                .font(.system(size: 11))
                        }
                    }
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.quaternary.opacity(0.5))
            )
            .padding(.horizontal, 10)
            .padding(.top, 6)
        }
    }

    private var isError: Bool {
        if case .error = updater.state { return true }
        return false
    }

    private var titleText: String {
        switch updater.state {
        case .readyToInstall(let version):
            return version.isEmpty ? "Update ready to install" : "Ready to install \(version)"
        case .error:
            return "Update failed"
        default:
            return ""
        }
    }

    private var subtitleText: String {
        switch updater.state {
        case .readyToInstall:
            return "Jack has downloaded an update. It will apply after a restart."
        case .error(let message):
            return message
        default:
            return ""
        }
    }

    private var buttonText: String {
        if isError { return "Retry" }
        return updater.isInstalling ? "Restarting…" : "Restart to update"
    }
}
