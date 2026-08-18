import Foundation

/// Recognizes "tap a modifier twice, quickly, on its own" — used by the
/// double-Shift shortcut that saves the current selection to the knowledge base.
///
/// Kept free of AppKit so the timing rules can be unit tested. The caller feeds
/// it press/release timestamps and reports any other keyboard activity, which
/// invalidates the sequence (otherwise typing capitals would trigger it).
struct DoubleTapModifierDetector {
    /// Longest gap between the first tap's release and the second tap's press.
    var window: TimeInterval
    /// Longest a tap may be held down and still count as a tap.
    var maxHold: TimeInterval

    private var pressStartedAt: TimeInterval?
    private var lastTapEndedAt: TimeInterval?
    /// Set when something else happened while the modifier was down (another
    /// key, another modifier) — that press is typing, not a tap.
    private var pressPolluted = false

    init(window: TimeInterval = 0.4, maxHold: TimeInterval = 0.35) {
        self.window = window
        self.maxHold = maxHold
    }

    mutating func reset() {
        pressStartedAt = nil
        lastTapEndedAt = nil
        pressPolluted = false
    }

    /// Any other key or modifier activity — cancels the pending sequence.
    mutating func noteOtherActivity() {
        if pressStartedAt != nil {
            pressPolluted = true
        }
        lastTapEndedAt = nil
    }

    mutating func modifierPressed(at now: TimeInterval) {
        // A tap that starts too late after the previous one is a fresh first tap.
        if let lastTapEndedAt, now - lastTapEndedAt > window {
            self.lastTapEndedAt = nil
        }
        pressStartedAt = now
        pressPolluted = false
    }

    /// Returns true when this release completes a clean double tap.
    mutating func modifierReleased(at now: TimeInterval) -> Bool {
        defer { pressStartedAt = nil }

        guard let pressStartedAt, !pressPolluted, now - pressStartedAt <= maxHold else {
            pressPolluted = false
            lastTapEndedAt = nil
            return false
        }

        if let lastTapEndedAt, now - lastTapEndedAt <= window {
            self.lastTapEndedAt = nil
            return true
        }

        lastTapEndedAt = now
        return false
    }
}
