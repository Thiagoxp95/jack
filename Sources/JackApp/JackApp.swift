import SwiftUI
import UserNotifications

@main
struct JackApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

// MARK: - Root

/// Creates the ``DictationController``, initializes it, and presents
/// ``ContentView`` (or the onboarding wizard).
private struct RootView: View {
    @StateObject private var controller = DictationController()
    @State private var spaceController = SpaceController()

    var body: some View {
        Group {
            if controller.shouldShowOnboardingWizard {
                OnboardingWizardView(controller: controller)
                    .frame(minWidth: 760, minHeight: 680)
            } else {
                ContentView(
                    controller: controller,
                    spaceController: spaceController,
                    todoListController: TodoListController.shared
                )
                .frame(minWidth: 640, minHeight: 460)
            }
        }
            .task {
                // Wire up controllers immediately (synchronous, no network)
                controller.spaceController = spaceController
                TodoSideSheetController.shared.todoListController = TodoListController.shared
                TodoSideSheetController.shared.spaceController = spaceController
                ChatSideSheetController.shared.chatController = ChatController.shared
                ChatSideSheetController.shared.spaceController = spaceController

                // Check local permissions (fast, no network)
                await controller.initialize()
                PermissionCenter.shared.startMonitoring()
            }
            .onReceive(NotificationCenter.default.publisher(for: .jackPermissionsChanged)) { _ in
                Task {
                    // Keep the controller's cached flags in lockstep with the
                    // live TCC state so features unlock the moment macOS grants.
                    await controller.refreshPermissions(prompt: false)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .todoSheetCommitInput)) { _ in
                TodoSideSheetController.shared.commitTextInput()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                controller.applicationWillTerminate()
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

        // Delay the first update check slightly so launch work settles.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            AppUpdater.shared.start()
        }

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
