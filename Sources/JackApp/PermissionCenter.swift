import AppKit
import AVFoundation
import ApplicationServices
import SwiftUI
import UserNotifications

// MARK: - Permission Model

enum JackPermission: String, CaseIterable, Identifiable {
    case inputMonitoring
    case accessibility
    case microphone
    case screenRecording
    case notifications

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inputMonitoring: return "Input Monitoring"
        case .accessibility: return "Accessibility"
        case .microphone: return "Microphone"
        case .screenRecording: return "Screen Recording"
        case .notifications: return "Notifications"
        }
    }

    var detail: String {
        switch self {
        case .inputMonitoring: return "Global invocation shortcut"
        case .accessibility: return "Paste transcript into focused app"
        case .microphone: return "Voice capture input"
        case .screenRecording: return "Capture screen content"
        case .notifications: return "Todo reminders and alerts"
        }
    }

    var settingsURLString: String {
        switch self {
        case .inputMonitoring:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        case .accessibility:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .microphone:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .screenRecording:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .notifications:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Notifications"
        }
    }

    /// System Settings panes whose app list accepts a dragged .app bundle
    /// (they have a +/− toolbar under the list). Microphone and Notifications
    /// lists are system-populated toggles — no drag support.
    var supportsDragInstall: Bool {
        switch self {
        case .inputMonitoring, .accessibility, .screenRecording: return true
        case .microphone, .notifications: return false
        }
    }
}

extension Notification.Name {
    static let jackPermissionsChanged = Notification.Name("jackPermissionsChanged")
}

// MARK: - Permission Center

/// Single source of truth for permission state. Polls macOS every second and
/// on app activation, so the UI always mirrors what System Settings says —
/// no manual refresh, no stale "Missing" badges.
@MainActor
final class PermissionCenter: ObservableObject {
    static let shared = PermissionCenter()

    @Published private(set) var granted: [JackPermission: Bool] = [:]

    private var timer: Timer?
    private var activationObserver: Any?
    private var monitoring = false

    private init() {
        refreshNow()
    }

    func isGranted(_ permission: JackPermission) -> Bool {
        granted[permission] ?? false
    }

    func startMonitoring() {
        guard !monitoring else { return }
        monitoring = true
        refreshNow()

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }
    }

    func refreshNow() {
        var next = granted
        next[.inputMonitoring] = CGPreflightListenEventAccess()
        next[.accessibility] = AXIsProcessTrusted()
        next[.microphone] = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        next[.screenRecording] = CGPreflightScreenCaptureAccess()
        applyIfChanged(next)

        Task { @MainActor [weak self] in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            guard let self else { return }
            var updated = self.granted
            updated[.notifications] = settings.authorizationStatus == .authorized
            self.applyIfChanged(updated)
        }
    }

    private func applyIfChanged(_ next: [JackPermission: Bool]) {
        guard next != granted else { return }
        granted = next
        NotificationCenter.default.post(name: .jackPermissionsChanged, object: nil)
    }

    /// Starts the grant flow for a permission: for drag-capable panes, opens
    /// System Settings and shows the floating drag-and-drop helper; for
    /// microphone/notifications, triggers the system prompt (or opens the
    /// pane if the user already denied it).
    func beginGrant(_ permission: JackPermission) {
        switch permission {
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in
                    Task { @MainActor in PermissionCenter.shared.refreshNow() }
                }
            } else {
                openSettings(for: permission)
            }
        case .notifications:
            Task { @MainActor in
                let status = await UNUserNotificationCenter.current()
                    .notificationSettings().authorizationStatus
                if status == .notDetermined {
                    _ = try? await UNUserNotificationCenter.current()
                        .requestAuthorization(options: [.alert, .sound, .badge])
                    self.refreshNow()
                } else {
                    self.openSettings(for: permission)
                }
            }
        case .inputMonitoring, .accessibility, .screenRecording:
            openSettings(for: permission)
            if !isGranted(permission) {
                PermissionDropPanelController.shared.show(for: permission)
            }
        }
    }

    private func openSettings(for permission: JackPermission) {
        if let url = URL(string: permission.settingsURLString) {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Floating Drop Panel

/// ChatGPT-style floating helper: a small always-on-top panel showing the app
/// icon so the user can drag Jack straight into the System Settings list.
/// Auto-dismisses once the permission flips to granted.
@MainActor
final class PermissionDropPanelController {
    static let shared = PermissionDropPanelController()

    private var panel: NSPanel?

    func show(for permission: JackPermission) {
        close()

        let view = PermissionDropView(permission: permission) { [weak self] in
            self?.close()
        }
        let hosting = NSHostingController(rootView: view)

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentViewController = hosting
        panel.setContentSize(hosting.view.fittingSize)

        // Bottom-center of the main screen, out of the way of the
        // System Settings window the user is about to drop onto.
        if let screen = NSScreen.main {
            let frame = panel.frame
            let x = screen.visibleFrame.midX - frame.width / 2
            let y = screen.visibleFrame.minY + 120
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() {
        panel?.close()
        panel = nil
    }
}

private struct PermissionDropView: View {
    let permission: JackPermission
    let onClose: () -> Void

    @ObservedObject private var center = PermissionCenter.shared
    @State private var dismissTask: Task<Void, Never>?

    private var isGranted: Bool { center.isGranted(permission) }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                .resizable()
                .frame(width: 88, height: 88)
                .onDrag {
                    NSItemProvider(contentsOf: Bundle.main.bundleURL) ?? NSItemProvider()
                }
                .overlay(alignment: .bottomTrailing) {
                    if isGranted {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(.white, .green)
                            .offset(x: 6, y: 6)
                    }
                }

            if isGranted {
                Text("\(permission.title) granted!")
                    .font(.headline)
                    .foregroundStyle(.green)
            } else {
                VStack(spacing: 4) {
                    Text("Drag Jack into the \(permission.title) list")
                        .font(.headline)
                    Text("Drop the icon above onto the System Settings window.\nIf an old “JackApp” entry is already there, remove it with − first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for permission…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Reveal Jack in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .padding(24)
        .frame(width: 320)
        .onChange(of: isGranted) { _, granted in
            guard granted else { return }
            dismissTask = Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if !Task.isCancelled { onClose() }
            }
        }
        .onDisappear { dismissTask?.cancel() }
    }
}
