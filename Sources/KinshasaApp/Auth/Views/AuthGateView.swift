import ClerkKit
import SwiftUI

/// Root view that gates the entire app behind Clerk authentication.
///
/// States:
/// 1. Clerk not loaded -> loading spinner (auto-retries, shows error after max attempts)
/// 2. No session -> ``SignInView``
/// 3. Signed in -> authenticated root (``ContentView``)
struct AuthGateView: View {
    @Environment(Clerk.self) private var clerk
    @State private var authController = AuthController()
    @State private var spaceController = SpaceController()
    @State private var loadFailed = false
    @State private var isRetrying = false
    @State private var diagnosticMessage = ""
    @State private var attemptCount = 0

    /// Max automatic retries before showing error UI.
    private let maxAutoRetries = 5
    /// Delay between automatic retries.
    private let retryDelay: Duration = .seconds(3)

    var body: some View {
        Group {
            if !clerk.isLoaded {
                loadingView
            } else if clerk.session == nil {
                SignInView(onSignedIn: {
                    initializeConvexIfNeeded()
                })
            } else {
                AuthenticatedRootView(authController: authController, spaceController: spaceController)
            }
        }
        .animation(.default, value: clerk.isLoaded)
        .animation(.default, value: clerk.session != nil)
        .task {
            await waitForClerkWithRetries()
        }
        .onChange(of: clerk.isLoaded) { _, loaded in
            if loaded {
                NSLog("[Actionfy] Clerk isLoaded changed to true")
                loadFailed = false
                isRetrying = false
            }
        }
        .onChange(of: clerk.session != nil) { _, isSignedIn in
            if isSignedIn {
                initializeConvexIfNeeded()
            }
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 16) {
            if loadFailed {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("Unable to connect to Clerk")
                    .font(.headline)
                Text("Could not reach ample-mink-80.clerk.accounts.dev")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if !diagnosticMessage.isEmpty {
                    Text(diagnosticMessage)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .padding(.horizontal)
                        .frame(maxWidth: 400)
                }
                Button {
                    manualRetry()
                } label: {
                    if isRetrying {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Retry")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRetrying)
                .padding(.top, 4)
            } else {
                ProgressView()
                    .controlSize(.large)
                Text(attemptCount > 0 ? "Connecting... (attempt \(attemptCount + 1))" : "Loading...")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Retry Logic

    /// Wait for Clerk to load, with automatic retries.
    private func waitForClerkWithRetries() async {
        guard !clerk.isLoaded else {
            NSLog("[Actionfy] Clerk already loaded")
            return
        }

        NSLog("[Actionfy] Waiting for Clerk SDK to load (env=%d, client=%d)",
              clerk.environment != nil ? 1 : 0, clerk.client != nil ? 1 : 0)

        // Give the SDK's own loading a chance first (it fires in configure())
        try? await Task.sleep(for: .seconds(5))

        if clerk.isLoaded {
            NSLog("[Actionfy] Clerk loaded via SDK init")
            return
        }

        // SDK's own loading didn't complete - start manual retries
        NSLog("[Actionfy] SDK init didn't complete, starting manual retries")
        for attempt in 0..<maxAutoRetries {
            guard !Task.isCancelled, !clerk.isLoaded else { return }
            attemptCount = attempt

            NSLog("[Actionfy] Retry attempt %d/%d", attempt + 1, maxAutoRetries)
            let success = await attemptRefresh()
            if success || clerk.isLoaded {
                NSLog("[Actionfy] Loaded on attempt %d", attempt + 1)
                return
            }

            if attempt < maxAutoRetries - 1 {
                try? await Task.sleep(for: retryDelay)
            }
        }

        // All retries exhausted
        if !clerk.isLoaded {
            NSLog("[Actionfy] All %d retries exhausted", maxAutoRetries)
            await captureClerkError()
            loadFailed = true
        }
    }

    /// Single refresh attempt. Returns true if Clerk is now loaded.
    private func attemptRefresh() async -> Bool {
        do {
            try await Clerk.shared.refreshEnvironment()
        } catch {
            NSLog("[Actionfy] refreshEnvironment failed: %@", "\(error)")
        }
        do {
            try await Clerk.shared.refreshClient()
        } catch {
            NSLog("[Actionfy] refreshClient failed: %@", "\(error)")
        }
        return clerk.isLoaded
    }

    private func manualRetry() {
        isRetrying = true
        loadFailed = false
        diagnosticMessage = ""
        attemptCount = 0
        Task {
            await waitForClerkWithRetries()
            isRetrying = false
        }
    }

    /// Capture detailed error for the diagnostic UI.
    private func captureClerkError() async {
        var errors: [String] = []

        if clerk.environment == nil {
            do {
                try await Clerk.shared.refreshEnvironment()
            } catch {
                errors.append("env: \(error.localizedDescription)")
            }
        }

        if clerk.client == nil {
            do {
                try await Clerk.shared.refreshClient()
            } catch {
                errors.append("client: \(error.localizedDescription)")
            }
        }

        diagnosticMessage = errors.isEmpty
            ? "env=\(clerk.environment != nil), client=\(clerk.client != nil)"
            : errors.joined(separator: "\n")
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
    let spaceController: SpaceController

    @StateObject private var controller = DictationController()
    @State private var recordingController = RecordingSessionController()
    @State private var todoSheetController = TodoSideSheetController()
    @State private var todoListController = TodoListController()

    var body: some View {
        Group {
            if controller.shouldShowOnboardingWizard {
                OnboardingWizardView(controller: controller)
                    .frame(minWidth: 640, minHeight: 460)
            } else {
                ContentView(
                    controller: controller,
                    recordingController: recordingController,
                    spaceController: spaceController,
                    authController: authController,
                    todoListController: todoListController
                )
                .frame(minWidth: 640, minHeight: 460)
            }
        }
            .task {
                // 1. Wire up controllers immediately (synchronous, no network)
                recordingController.authController = authController
                recordingController.spaceController = spaceController
                controller.spaceController = spaceController
                todoSheetController.todoListController = todoListController
                todoSheetController.spaceController = spaceController

                // 2. Check local permissions first (fast, no network)
                await controller.initialize()
                await recordingController.initialize()

                // 3. Fetch spaces via HTTP client (uses Clerk JWT directly,
                //    does NOT depend on ConvexMobile bridge)
                await spaceController.refreshSpaces()

                // 4. Convex auth (may be slow due to ConvexMobile bridge —
                //    run last so it doesn't block spaces or permissions)
                if authController.convexClient == nil {
                    authController.initializeConvex(deploymentUrl: AppConfig.convexDeploymentUrl)
                    await authController.authenticateConvex()
                }

                // 5. Start reminder polling at the app level so it survives
                //    window close/hide (not tied to ContentView lifecycle)
                todoListController.startReminderPolling()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleScreenRecording)) { _ in
                Task {
                    await toggleScreenRecordingFromShortcut()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleTodoSheet)) { _ in
                todoSheetController.toggle()
            }
            .onReceive(NotificationCenter.default.publisher(for: .todoSheetCommitInput)) { _ in
                todoSheetController.commitTextInput()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                controller.applicationWillTerminate()
            }
    }

    private func toggleScreenRecordingFromShortcut() async {
        switch recordingController.state {
        case .recording, .paused:
            await recordingController.stopRecording()
        case .idle:
            do {
                try await recordingController.startRecording()
            } catch {
                NSLog("[Actionfy] Quick screen recording failed: %@", "\(error)")
            }
        default:
            break
        }
    }
}
