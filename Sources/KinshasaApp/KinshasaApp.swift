import ClerkKit
import SwiftUI
import UserNotifications

@main
struct KinshasaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        NSLog("[Actionfy] Configuring Clerk with key prefix: %@", String(AppConfig.clerkPublishableKey.prefix(20)))
        let redirectConfig = Clerk.Options.RedirectConfig(
            redirectUrl: "actionfy://oauth-callback",
            callbackUrlScheme: "actionfy"
        )
        Clerk.configure(
            publishableKey: AppConfig.clerkPublishableKey,
            options: .init(redirectConfig: redirectConfig)
        )
        NSLog("[Actionfy] Clerk configured. isLoaded=%d", Clerk.shared.isLoaded ? 1 : 0)
    }

    var body: some Scene {
        WindowGroup {
            AuthGateView()
                .environment(Clerk.shared)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusBarController = StatusBarController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBarController.setup()

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }

        let defaults = UserDefaults.standard
        let showInDock = defaults.object(forKey: "show_in_dock") as? Bool ?? true
        if !showInDock {
            NSApp.setActivationPolicy(.accessory)
        }

        let showInStatusBar = defaults.object(forKey: "show_in_status_bar") as? Bool ?? true
        if !showInStatusBar {
            statusBarController.hide()
        }
    }

    /// Re-open the main window when the Dock icon is clicked and all windows are closed.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSApp.activate()
        }
        return true
    }
}
