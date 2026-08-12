import AppKit
import Combine
import Foundation
import Sparkle

/// App auto-update state, driven by Sparkle.
///
/// UX mirrors "silent download, single action": updates are checked and
/// downloaded in the background; the UI only surfaces a card once an update is
/// fully downloaded and ready ("Restart to update"), or on a non-network error.
enum UpdateState: Equatable {
    case idle
    case checking
    case downloading(version: String)
    case readyToInstall(version: String)
    case error(message: String)

    var isCardVisible: Bool {
        switch self {
        case .readyToInstall, .error: return true
        default: return false
        }
    }
}

@MainActor
final class AppUpdater: NSObject, ObservableObject {
    static let shared = AppUpdater()

    @Published private(set) var state: UpdateState = .idle
    @Published private(set) var isInstalling = false
    @Published var dismissedVersion: String?

    /// True when the running bundle is configured for Sparkle (packaged app).
    private(set) var isAvailable = false

    private var updater: SPUUpdater?
    private var pendingChoiceReply: ((SPUUserUpdateChoice) -> Void)?
    private var userInitiatedCheck = false
    private var pollTimer: Timer?

    /// How often to look for a new build.
    ///
    /// Sparkle will not honour this on its own: `SPUUpdaterSettings.minimumUpdateCheckInterval`
    /// returns one hour in release builds and `SPUUpdater` silently clamps
    /// `updateCheckInterval` up to it, so assigning 5 minutes there would read
    /// as configured and behave as hourly. The 60-second override Sparkle does
    /// expose is `#if DEBUG` only. So the schedule is ours, driven by the timer
    /// below calling `checkForUpdatesInBackground()`.
    ///
    /// A check that finds nothing is one conditional GET of a small XML file —
    /// 288 a day is nothing, and it is the difference between hearing about a
    /// fix now and hearing about it after lunch.
    static let pollInterval: TimeInterval = 5 * 60

    /// Delay before the launch check, so it lands after the app has finished
    /// coming up rather than competing with it.
    private static let launchCheckDelay: TimeInterval = 5

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var availableVersion: String? {
        switch state {
        case .downloading(let v), .readyToInstall(let v): return v
        default: return nil
        }
    }

    func start() {
        guard updater == nil else { return }
        // Bare `swift run` builds have no Info.plist feed; skip silently.
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") is String,
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") is String
        else { return }

        let updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: self,
            delegate: nil
        )
        updater.automaticallyChecksForUpdates = true
        updater.automaticallyDownloadsUpdates = true
        // Left at Sparkle's own floor rather than a smaller number it would
        // silently raise. Our timer is what actually sets the cadence.
        updater.updateCheckInterval = 60 * 60
        do {
            try updater.start()
            self.updater = updater
            isAvailable = true
            scheduleBackgroundChecks()
        } catch {
            NSLog("Sparkle failed to start: \(error.localizedDescription)")
        }
    }

    /// Check on launch, then every `pollInterval`.
    ///
    /// The launch check matters on its own: Sparkle schedules from
    /// `lastUpdateCheckDate`, so quitting and reopening does *not* check — it
    /// resumes the countdown from the last check, and a relaunch five minutes
    /// after one is told nothing for another fifty-five. Restarting an app to
    /// pick up an update and being told nothing is exactly the case this
    /// covers.
    private func scheduleBackgroundChecks() {
        pollTimer?.invalidate()

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchCheckDelay) { [weak self] in
            self?.checkInBackground()
        }

        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkInBackground() }
        }
        // Tolerance lets the OS coalesce this with other wakeups; nothing here
        // needs to land on the second, and a laptop on battery would rather it
        // did not.
        timer.tolerance = 30
        // .common so the timer keeps firing while a menu is open or a window is
        // being resized — modes where the default runloop mode is starved.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// A silent check. Never surfaces "you're up to date", never interrupts a
    /// download or an install already under way, and stops asking once an
    /// update is sitting there waiting to be installed.
    private func checkInBackground() {
        guard let updater, !isInstalling else { return }
        if case .readyToInstall = state { return }
        guard !updater.sessionInProgress else { return }
        updater.checkForUpdatesInBackground()
    }

    /// Menu item action — surfaces feedback even when nothing is available.
    func checkForUpdates() {
        userInitiatedCheck = true
        updater?.checkForUpdates()
    }

    func installAndRelaunch() {
        guard case .readyToInstall = state, let reply = pendingChoiceReply else { return }
        isInstalling = true
        pendingChoiceReply = nil
        reply(.install)
    }

    func dismissCard() {
        switch state {
        case .readyToInstall(let version):
            dismissedVersion = version
        case .error:
            state = .idle
        default:
            break
        }
    }

    var isCardVisible: Bool {
        guard state.isCardVisible else { return false }
        if case .readyToInstall(let v) = state, v == dismissedVersion { return false }
        return true
    }

    private static let networkErrorMarkers = [
        "offline", "timed out", "network connection", "could not connect",
        "cannot connect", "not connected", "dns", "host", "socket",
    ]

    private func reportError(_ error: Error) {
        let ns = error as NSError
        // Sparkle uses SUError codes; no-update-found surfaces as an "error" too.
        if ns.domain == "SUSparkleErrorDomain", ns.code == 1001 {  // SUNoUpdateError
            state = .idle
            if userInitiatedCheck { showUpToDateAlert() }
            return
        }
        let message = error.localizedDescription
        let lowered = message.lowercased()
        if Self.networkErrorMarkers.contains(where: { lowered.contains($0) }) {
            // Transient network problems: log, stay quiet, retry next interval.
            NSLog("Updater network error (suppressed): \(message)")
            state = .idle
            return
        }
        state = .error(message: message)
    }

    private func showUpToDateAlert() {
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = "Silky \(currentVersion) is the latest version."
        alert.runModal()
    }
}

/// Sparkle's reply callbacks are not Sendable; they are only ever invoked on
/// the main actor here.
private struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
}

// MARK: - SPUUserDriver

extension AppUpdater: SPUUserDriver {
    nonisolated func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping @Sendable (SUUpdatePermissionResponse) -> Void
    ) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    nonisolated func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        Task { @MainActor in self.state = .checking }
    }

    nonisolated func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state updateState: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        let version = appcastItem.displayVersionString
        let stage = updateState.stage
        let boxed = UncheckedSendable(value: reply)
        Task { @MainActor in
            switch stage {
            case .downloaded, .installing:
                // Background download finished (or resumed): ready now.
                self.pendingChoiceReply = boxed.value
                self.state = .readyToInstall(version: version)
            case .notDownloaded:
                // Proceed silently; Sparkle downloads in the background.
                self.state = .downloading(version: version)
                boxed.value(.install)
            @unknown default:
                boxed.value(.install)
            }
            self.userInitiatedCheck = false
        }
    }

    nonisolated func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    nonisolated func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    nonisolated func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        Task { @MainActor in
            self.state = .idle
            if self.userInitiatedCheck {
                self.userInitiatedCheck = false
                self.showUpToDateAlert()
            }
        }
    }

    nonisolated func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        Task { @MainActor in
            self.reportError(error)
            self.userInitiatedCheck = false
            self.isInstalling = false
        }
    }

    nonisolated func showDownloadInitiated(cancellation: @escaping () -> Void) {}

    nonisolated func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}

    nonisolated func showDownloadDidReceiveData(ofLength length: UInt64) {}

    nonisolated func showDownloadDidStartExtractingUpdate() {}

    nonisolated func showExtractionReceivedProgress(_ progress: Double) {}

    nonisolated func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let boxed = UncheckedSendable(value: reply)
        Task { @MainActor in
            self.pendingChoiceReply = boxed.value
            self.state = .readyToInstall(version: self.availableVersion ?? "")
        }
    }

    nonisolated func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {}

    nonisolated func showUpdateInstalledAndRelaunched(
        _ relaunched: Bool, acknowledgement: @escaping () -> Void
    ) {
        acknowledgement()
    }

    nonisolated func showUpdateInFocus() {}

    nonisolated func dismissUpdateInstallation() {
        Task { @MainActor in
            self.isInstalling = false
            if case .checking = self.state { self.state = .idle }
        }
    }
}
