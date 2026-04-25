import SwiftUI

struct ShortcutCaptureView: View {
    let title: String
    let onSave: (InvocationShortcut) -> Void
    let onCancel: () -> Void

    enum CaptureState {
        case idle
        case recording
        case captured
    }

    @State private var captureState: CaptureState = .idle
    @State private var accumulatedModifiers: NSEvent.ModifierFlags = []
    @State private var capturedKeyCode: Int64?
    @State private var debounceTask: Task<Void, Never>?
    @State private var eventMonitor: Any?

    private var currentShortcut: InvocationShortcut {
        InvocationShortcut(
            primaryKeyCode: capturedKeyCode,
            modifiers: accumulatedModifiers.rawValue
        )
    }

    private var isValid: Bool {
        currentShortcut.isValid
    }

    /// Check if the captured shortcut conflicts with common macOS system shortcuts.
    private var systemConflictWarning: String? {
        guard let keyCode = capturedKeyCode, !InvocationKey.isModifierKeyCode(keyCode) else {
            return nil
        }
        let flags = NSEvent.ModifierFlags(rawValue: accumulatedModifiers.rawValue)

        // Common ⌘+key combos
        if flags == .command {
            let conflicting: [Int64: String] = [
                8: "⌘C (Copy)", 9: "⌘V (Paste)", 7: "⌘X (Cut)", 6: "⌘Z (Undo)",
                0: "⌘A (Select All)", 1: "⌘S (Save)", 12: "⌘Q (Quit)",
                13: "⌘W (Close Window)", 17: "⌘T (New Tab)", 45: "⌘N (New)",
                35: "⌘P (Print)", 3: "⌘F (Find)", 4: "⌘H (Hide)",
                46: "⌘M (Minimize)",
            ]
            if let name = conflicting[keyCode] {
                return "This shortcut conflicts with \(name). It may interfere with system operations."
            }
        }

        // ⌘⇧ combos
        if flags == [.command, .shift] {
            let conflicting: [Int64: String] = [
                6: "⌘⇧Z (Redo)", 45: "⌘⇧N (New Folder)",
            ]
            if let name = conflicting[keyCode] {
                return "This shortcut conflicts with \(name). It may interfere with system operations."
            }
        }

        return nil
    }

    /// Split the current shortcut into individual key symbol strings for badge display.
    private var keyBadges: [String] {
        var badges: [String] = []
        let flags = NSEvent.ModifierFlags(rawValue: accumulatedModifiers.rawValue)
        if flags.contains(.control) { badges.append("\u{2303}") }  // ⌃
        if flags.contains(.option) { badges.append("\u{2325}") }   // ⌥
        if flags.contains(.shift) { badges.append("\u{21E7}") }    // ⇧
        if flags.contains(.command) { badges.append("\u{2318}") }  // ⌘
        if flags.contains(.function) { badges.append("Fn") }

        if let keyCode = capturedKeyCode, !InvocationKey.isModifierKeyCode(keyCode) {
            badges.append(InvocationKey.displayName(for: keyCode))
        }
        return badges
    }

    var body: some View {
        VStack(spacing: 20) {
            Text(title)
                .font(.system(size: 18, weight: .bold))

            switch captureState {
            case .idle:
                idleContent
            case .recording:
                recordingContent
            case .captured:
                capturedContent
            }
        }
        .padding(28)
        .frame(width: 380)
        .onDisappear {
            debounceTask?.cancel()
            removeMonitor()
        }
    }

    // MARK: - Idle State

    private var idleContent: some View {
        VStack(spacing: 20) {
            Button {
                startRecording()
            } label: {
                Text("Click here to start recording.")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.pink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 64)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.pink.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(.pink, lineWidth: 2)
                    )
            }
            .buttonStyle(.plain)

            Button("Cancel") {
                onCancel()
            }
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Recording State

    private var recordingContent: some View {
        VStack(spacing: 20) {
            Text("Press the keys you want to use for your shortcut. The shortcut must include at least one modifier key (\u{2318}, \u{2325}, \u{2303}, \u{21E7}) and one regular key (except function keys).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            keyBadgeArea(borderColor: systemConflictWarning != nil ? .pink : (keyBadges.isEmpty ? .primary.opacity(0.2) : .green))

            if let warning = systemConflictWarning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.pink)
                    .multilineTextAlignment(.center)
            }

            Button("Cancel") {
                cancelRecording()
            }
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Captured State

    private var capturedContent: some View {
        let hasConflict = systemConflictWarning != nil

        return VStack(spacing: 16) {
            keyBadgeArea(borderColor: hasConflict ? .pink : .green)

            if let warning = systemConflictWarning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.pink)
                    .multilineTextAlignment(.center)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.title2)
                    Text("Shortcut Successfully Recorded")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.green)
                }
            }

            HStack(spacing: 12) {
                Button("Record Again") {
                    resetAndStartRecording()
                }
                .buttonStyle(.bordered)

                Button("Save") {
                    onSave(currentShortcut)
                }
                .buttonStyle(.borderedProminent)
                .tint(.pink)
                .disabled(!isValid)
            }
        }
    }

    // MARK: - Key Badge Area

    private func keyBadgeArea(borderColor: Color) -> some View {
        HStack(spacing: 8) {
            if keyBadges.isEmpty {
                Text("Waiting for keys…")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(keyBadges.enumerated()), id: \.offset) { _, badge in
                    Text(badge)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .frame(width: 44, height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.ultraThinMaterial)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(.primary.opacity(0.15), lineWidth: 1)
                        )
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 72)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(borderColor, lineWidth: 2)
        )
    }

    // MARK: - Event Handling

    private func startRecording() {
        accumulatedModifiers = []
        capturedKeyCode = nil
        captureState = .recording
        installMonitor()
    }

    private func cancelRecording() {
        removeMonitor()
        debounceTask?.cancel()
        captureState = .idle
        accumulatedModifiers = []
        capturedKeyCode = nil
    }

    private func resetAndStartRecording() {
        removeMonitor()
        debounceTask?.cancel()
        accumulatedModifiers = []
        capturedKeyCode = nil
        captureState = .recording
        installMonitor()
    }

    private func installMonitor() {
        removeMonitor()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handleCaptureEvent(event)
            return nil
        }
    }

    private func removeMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func handleCaptureEvent(_ event: NSEvent) {
        guard captureState == .recording else { return }

        if event.type == .flagsChanged {
            let keyCode = Int64(event.keyCode)
            if InvocationKey.isModifierKeyCode(keyCode) {
                let flag = InvocationKey.modifierFlag(for: keyCode)
                accumulatedModifiers.insert(flag)
            }

            debounceTask?.cancel()
            debounceTask = Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    captureState = .captured
                    removeMonitor()
                }
            }
            return
        }

        if event.type == .keyDown, !event.isARepeat {
            debounceTask?.cancel()
            capturedKeyCode = Int64(event.keyCode)
            captureState = .captured
            removeMonitor()
        }
    }
}
