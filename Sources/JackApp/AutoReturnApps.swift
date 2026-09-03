import AppKit
import Foundation

/// One app the user opted into "press Return after pasting".
///
/// Bundle id is the identity; the name is only kept so the settings list can
/// still show something readable for an app that isn't installed any more.
struct AutoReturnApp: Codable, Identifiable, Equatable {
    var bundleID: String
    var name: String

    var id: String { bundleID }

    init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

enum AutoReturnRule {
    /// Should a Return be synthesized after the transcript was pasted?
    ///
    /// Pure so it can be tested without a running app: the caller samples the
    /// frontmost bundle id at paste time and hands it in. Matching is
    /// case-insensitive because bundle ids are compared case-insensitively by
    /// Launch Services and users type them by hand in the settings list.
    static func shouldPressReturn(
        enabled: Bool,
        didPaste: Bool,
        frontmostBundleID: String?,
        apps: [AutoReturnApp]
    ) -> Bool {
        guard enabled, didPaste, let frontmostBundleID, !frontmostBundleID.isEmpty else {
            return false
        }
        return apps.contains { $0.bundleID.caseInsensitiveCompare(frontmostBundleID) == .orderedSame }
    }
}

// MARK: - App discovery

enum AutoReturnAppCatalog {
    /// Apps the user could plausibly be dictating into: everything with a Dock
    /// icon, minus Silky itself (which never receives a paste anyway).
    @MainActor
    static func runningApps() -> [AutoReturnApp] {
        let ownBundleID = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> AutoReturnApp? in
                guard let bundleID = app.bundleIdentifier, bundleID != ownBundleID else { return nil }
                return AutoReturnApp(bundleID: bundleID, name: app.localizedName ?? bundleID)
            }
            .reduce(into: [AutoReturnApp]()) { unique, app in
                if !unique.contains(where: { $0.bundleID == app.bundleID }) {
                    unique.append(app)
                }
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Reads an app bundle picked from disk, for apps that aren't running.
    static func app(atBundleURL url: URL) -> AutoReturnApp? {
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return nil }
        let name = (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return AutoReturnApp(bundleID: bundleID, name: name)
    }

    @MainActor
    static func icon(for bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
