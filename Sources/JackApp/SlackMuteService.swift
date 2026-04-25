import ApplicationServices
import AppKit
import Carbon.HIToolbox
import Foundation
import os.log

private let slackLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Jack", category: "slackMute")

/// Automatically mutes/unmutes Slack during dictation.
///
/// **Strategy (hybrid):**
/// 1. **State detection** via AX API — scan Slack's accessibility tree for any
///    element whose text contains "mute" / "unmute" to determine whether the
///    user is currently muted.
/// 2. **State change** via Cmd+Shift+Space keystroke — Slack's native toggle.
///    AXPressAction returns `.success` on Electron but doesn't actually fire
///    the web-app click handler, so we use a real keystroke instead.
///
/// The host app must have Accessibility permission in System Settings.
final class SlackMuteService: @unchecked Sendable {
    private static let slackBundleID = "com.tinyspeck.slackmacgap"

    private static let maxAXDepth = 20
    private static let maxAXVisits = 8000

    /// Serial queue that ensures mute and restore never overlap.
    let queue = DispatchQueue(label: "com.jack.slackMute", qos: .userInitiated)

    private var didMuteSlack = false

    // MARK: - Diagnostics

    private func diag(_ msg: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
        let path = "/tmp/slack_mute_diag.txt"
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(line.data(using: .utf8) ?? Data())
            fh.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
        }
    }

    // MARK: - Public API

    /// Call when dictation recording starts.
    func muteIfInCall() {
        didMuteSlack = false
        diag("muteIfInCall: CALLED")

        guard AXIsProcessTrusted() else {
            slackLog.error("muteIfInCall: no Accessibility permission")
            diag("muteIfInCall: AX NOT TRUSTED")
            return
        }

        guard let slackApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == Self.slackBundleID }) else {
            slackLog.info("muteIfInCall: Slack not running")
            diag("muteIfInCall: Slack not running")
            return
        }

        let pid = slackApp.processIdentifier
        diag("muteIfInCall: Slack PID=\(pid)")

        let axApp = AXUIElementCreateApplication(pid)
        let state = detectMuteState(in: axApp)
        diag("muteIfInCall: state=\(state)")

        switch state {
        case .muted:
            slackLog.info("muteIfInCall: already muted, leaving alone")
            diag("muteIfInCall: already muted — no action")
            return
        case .unmuted:
            slackLog.info("muteIfInCall: unmuted in call — will mute via keystroke")
            diag("muteIfInCall: unmuted — sending Cmd+Shift+Space")
            sendMuteToggle(to: slackApp)
            didMuteSlack = true
            diag("muteIfInCall: keystroke sent, didMuteSlack=true")
        case .notInCall:
            slackLog.info("muteIfInCall: no mute element found — not in a call")
            diag("muteIfInCall: not in a call")
            return
        }
    }

    /// Call when dictation recording stops.
    func restoreIfNeeded() {
        guard didMuteSlack else { return }
        defer { didMuteSlack = false }
        diag("restoreIfNeeded: CALLED (didMuteSlack was true)")

        guard let slackApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == Self.slackBundleID }) else {
            slackLog.warning("restoreIfNeeded: Slack no longer running")
            diag("restoreIfNeeded: Slack not running")
            return
        }

        let pid = slackApp.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        let state = detectMuteState(in: axApp)
        diag("restoreIfNeeded: state=\(state)")

        switch state {
        case .muted:
            slackLog.info("restoreIfNeeded: still muted (by us) — unmuting via keystroke")
            diag("restoreIfNeeded: sending Cmd+Shift+Space to unmute")
            sendMuteToggle(to: slackApp)
            diag("restoreIfNeeded: keystroke sent")
        case .unmuted:
            slackLog.info("restoreIfNeeded: already unmuted (user toggled manually?)")
            diag("restoreIfNeeded: already unmuted — no action")
        case .notInCall:
            slackLog.info("restoreIfNeeded: call ended")
            diag("restoreIfNeeded: not in call anymore")
        }
    }

    // MARK: - Mute state detection via AX

    private enum MuteState: CustomStringConvertible {
        case muted, unmuted, notInCall

        var description: String {
            switch self {
            case .muted: return "muted"
            case .unmuted: return "unmuted"
            case .notInCall: return "notInCall"
            }
        }
    }

    /// Diagnostic: collects details of every mute-related element found during search.
    private var diagLines: [String] = []

    private func detectMuteState(in root: AXUIElement) -> MuteState {
        var visited = 0
        diagLines = ["=== Slack AX Mute Scan @ \(Date()) ==="]
        let result = searchForMuteText(in: root, depth: 0, visited: &visited)
        diagLines.append("Total visited: \(visited), result: \(result?.description ?? "nil")")
        let diagText = diagLines.joined(separator: "\n")
        try? diagText.write(toFile: "/tmp/slack_ax_dump.txt", atomically: true, encoding: .utf8)
        return result ?? .notInCall
    }

    private func searchForMuteText(
        in element: AXUIElement,
        depth: Int,
        visited: inout Int
    ) -> MuteState? {
        guard depth < Self.maxAXDepth, visited < Self.maxAXVisits else { return nil }
        visited += 1

        let title = axString(element, kAXTitleAttribute) ?? ""
        let desc = axString(element, kAXDescriptionAttribute) ?? ""
        let help = axString(element, kAXHelpAttribute) ?? ""
        let roleDesc = axString(element, kAXRoleDescriptionAttribute) ?? ""
        let value = axString(element, kAXValueAttribute) ?? ""
        let label = axString(element, "AXLabel") ?? ""
        let identifier = axString(element, kAXIdentifierAttribute) ?? ""

        let combined = "\(title) \(desc) \(help) \(roleDesc) \(value) \(label) \(identifier)".lowercased()

        if combined.contains("mute") {
            let role = axString(element, kAXRoleAttribute) ?? "?"
            let visitCount = visited
            diagLines.append("""
                [depth=\(depth) visited=\(visitCount)] role=\(role) \
                title="\(title)" desc="\(desc)" value="\(value)" \
                label="\(label)" id="\(identifier)" help="\(help)" roleDesc="\(roleDesc)"
                """)

            // "unmute" in text → currently muted. "mute" without "un" → unmuted.
            // We look for the first element that has "mute" text — this indicates
            // the user is in a call with mute controls visible.
            if combined.contains("unmute") {
                return .muted
            } else {
                return .unmuted
            }
        }

        // Recurse into children.
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &childrenRef
        ) == .success,
            let children = childrenRef as? [AXUIElement]
        else {
            return nil
        }

        for child in children {
            if let result = searchForMuteText(in: child, depth: depth + 1, visited: &visited) {
                return result
            }
        }

        return nil
    }

    // MARK: - Keystroke toggle

    /// Send Cmd+Shift+Space to Slack to toggle mute.
    ///
    /// Brings Slack to front briefly, sends the keystroke, then restores
    /// the original app. This is necessary because Slack (Electron) only
    /// processes keyboard shortcuts when it's the frontmost app.
    private func sendMuteToggle(to slackApp: NSRunningApplication) {
        let currentApp = NSWorkspace.shared.frontmostApplication
        diag("sendMuteToggle: current frontmost=\(currentApp?.localizedName ?? "nil")")

        // Activate Slack
        slackApp.activate()

        // Small delay for Slack to become frontmost
        usleep(150_000) // 150ms

        // Send Cmd+Shift+Space
        let keyCode = UInt16(kVK_Space)
        let flags: CGEventFlags = [.maskCommand, .maskShift]

        if let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
           let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        {
            keyDown.flags = flags
            keyUp.flags = flags
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            diag("sendMuteToggle: Cmd+Shift+Space posted to HID tap")
        } else {
            diag("sendMuteToggle: FAILED to create CGEvent")
            slackLog.error("sendMuteToggle: failed to create CGEvent")
        }

        // Small delay for keystroke to be processed
        usleep(100_000) // 100ms

        // Restore original app
        if let currentApp = currentApp {
            currentApp.activate()
            diag("sendMuteToggle: restored frontmost to \(currentApp.localizedName ?? "?")")
        }
    }

    // MARK: - Helpers

    private func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }
}
