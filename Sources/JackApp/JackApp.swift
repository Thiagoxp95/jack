import ClerkKit
import SwiftUI
import UserNotifications

/// App-level debug logger (mirrors TodoListController's diagLog).
private func appDiagLog(_ message: String) {
    NSLog("%@", message)
    let logFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("jack-reminder-diag.log")
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logFile.path) {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: logFile)
        }
    }
}

@main
struct JackApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        NSLog("[Jack] Configuring Clerk with key prefix: %@", String(AppConfig.clerkPublishableKey.prefix(20)))
        let redirectConfig = Clerk.Options.RedirectConfig(
            redirectUrl: "jack://oauth-callback",
            callbackUrlScheme: "jack"
        )
        Clerk.configure(
            publishableKey: AppConfig.clerkPublishableKey,
            options: .init(redirectConfig: redirectConfig)
        )
        NSLog("[Jack] Clerk configured. isLoaded=%d", Clerk.shared.isLoaded ? 1 : 0)
    }

    var body: some Scene {
        WindowGroup {
            AuthGateView()
                .environment(Clerk.shared)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let statusBarController = StatusBarController()
    /// Prevent App Nap so the global keyboard shortcut stays responsive.
    /// Without this, macOS throttles the run loop for LSUIElement apps with
    /// no visible windows, causing a noticeable delay before the pill appears.
    private var appNapActivity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        appNapActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Global keyboard shortcut must respond instantly"
        )
        statusBarController.setup()

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }

        let defaults = UserDefaults.standard
        let showInDock = defaults.object(forKey: "show_in_dock") as? Bool ?? true
        if !showInDock {
            NSApp.setActivationPolicy(.accessory)
        }

        let showInStatusBar = defaults.object(forKey: "show_in_status_bar") as? Bool ?? true
        if !showInStatusBar {
            statusBarController.hide()
        }

        appDiagLog("[APP] applicationDidFinishLaunching — starting Clerk watch loop")

        // Start reminder polling once Clerk session is available.
        // Poll every 2s until Clerk is loaded + has a session, then start.
        Task { @MainActor in
            let clerk = Clerk.shared
            var waitCount = 0
            // Wait for Clerk to load and have a session
            while !clerk.isLoaded || clerk.session == nil {
                waitCount += 1
                appDiagLog("[APP] Waiting for Clerk... attempt \(waitCount), isLoaded=\(clerk.isLoaded), session=\(clerk.session != nil ? "YES" : "nil")")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            appDiagLog("[APP] Clerk session ready — starting reminder polling")
            TodoListController.shared.startReminderPolling()
        }
    }

    // Show notifications even when the app is in the foreground.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Re-open the main window when the Dock icon is clicked and all windows are closed.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSApp.activate()
        }
        return true
    }
}
