import ClerkKit
import SwiftUI

/// Root view that gates the entire app behind Clerk authentication.
///
/// States:
/// 1. Clerk not loaded -> loading spinner
/// 2. No session -> ``SignInView``
/// 3. Signed in but no organization -> ``OrganizationPickerView``
/// 4. Signed in with organization -> authenticated root (``ContentView``)
struct AuthGateView: View {
    @Environment(Clerk.self) private var clerk
    @State private var authController = AuthController()

    var body: some View {
        Group {
            if !clerk.isLoaded {
                loadingView
            } else if clerk.session == nil {
                SignInView(onSignedIn: {
                    initializeConvexIfNeeded()
                })
            } else if (clerk.user?.organizationMemberships ?? []).isEmpty {
                OrganizationPickerView(onOrganizationSelected: { _ in
                    initializeConvexIfNeeded()
                })
            } else {
                AuthenticatedRootView(authController: authController)
            }
        }
        .animation(.default, value: clerk.isLoaded)
        .animation(.default, value: clerk.session != nil)
        .onChange(of: clerk.session != nil) { _, isSignedIn in
            if isSignedIn {
                initializeConvexIfNeeded()
            }
        }
    }

    // MARK: - Private

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Loading...")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func initializeConvexIfNeeded() {
        guard authController.convexClient == nil else { return }
        authController.initializeConvex(deploymentUrl: AppConfig.convexDeploymentUrl)
        Task {
            await authController.authenticateConvex()
        }
    }
}

// MARK: - Authenticated Root

/// Replicates the old ``RootView`` behavior: creates the ``DictationController``
/// and ``RecordingSessionController``, initializes them, and presents
/// ``ContentView``.
private struct AuthenticatedRootView: View {
    let authController: AuthController

    @StateObject private var controller = DictationController()
    @State private var recordingController = RecordingSessionController()

    var body: some View {
        ContentView(controller: controller, recordingController: recordingController)
            .frame(minWidth: 640, minHeight: 460)
            .task {
                await controller.initialize()
                await recordingController.initialize()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                controller.applicationWillTerminate()
            }
    }
}
