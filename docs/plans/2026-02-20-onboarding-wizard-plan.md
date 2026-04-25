# Onboarding Wizard Redesign — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the basic OnboardingWizardView with a polished, Raycast-inspired dark wizard featuring two-column layouts, vibrant gradients, and smooth horizontal transitions.

**Architecture:** Single-file replacement of `OnboardingWizardView.swift`. The view uses the same `DictationController` API surface — no controller changes needed. All design tokens (colors, spacing) are defined as private extensions within the file. Step transitions use SwiftUI's `.transition()` with asymmetric slide + spring animation.

**Tech Stack:** SwiftUI (macOS 14+), SF Symbols, no additional dependencies.

---

### Task 1: Scaffold the new OnboardingWizardView with design tokens and step enum

**Files:**
- Replace: `Sources/JackApp/OnboardingWizardView.swift`

**Step 1: Write the design token extensions and updated Step enum**

Replace the entire file with the scaffolding. This includes color constants, the Step enum, and the outer body shell with dark background + bottom navigation bar. No step content yet — just placeholders.

```swift
import SwiftUI

struct OnboardingWizardView: View {
    @ObservedObject var controller: DictationController
    @State private var step: Step = .welcome
    @State private var direction: NavigationDirection = .forward
    @State private var isRequestingPermissions = false

    var body: some View {
        VStack(spacing: 0) {
            // Step content area
            ZStack {
                stepContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            // Bottom navigation bar
            bottomBar
        }
        .frame(width: 700, height: 500)
        .background(WizardColors.background)
        .preferredColorScheme(.dark)
        .onDisappear {
            controller.cancelInvocationKeyCapture()
            controller.cancelVoiceNoteSwitchKeyCapture()
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)

            HStack {
                Button("Skip") {
                    controller.dismissOnboardingWizard()
                }
                .buttonStyle(.plain)
                .foregroundStyle(WizardColors.secondary)
                .font(.system(size: 13))

                Spacer()

                stepDots

                Spacer()

                HStack(spacing: 8) {
                    if step != .welcome {
                        Button("Back") {
                            navigateBack()
                        }
                        .buttonStyle(.bordered)
                        .tint(WizardColors.secondary)
                    }

                    Button(step.primaryButtonTitle) {
                        handlePrimaryAction()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(WizardColors.accentFrom)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Step Dots

    private var stepDots: some View {
        HStack(spacing: 8) {
            ForEach(Step.allCases, id: \.self) { s in
                Circle()
                    .fill(s == step ? WizardColors.accentFrom : Color.white.opacity(0.2))
                    .frame(width: s == step ? 8 : 6, height: s == step ? 8 : 6)
                    .animation(.spring(response: 0.3), value: step)
            }
        }
    }

    // MARK: - Step Content (placeholder for now)

    @ViewBuilder
    private var stepContent: some View {
        Text(step.title)
            .font(.title)
            .foregroundStyle(.white)
            .id(step)
            .transition(stepTransition)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: step)
    }

    // MARK: - Navigation

    private var stepTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: direction == .forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: direction == .forward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    private func navigateBack() {
        guard let prev = Step(rawValue: step.rawValue - 1) else { return }
        direction = .backward
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            step = prev
        }
    }

    private func handlePrimaryAction() {
        if step == .done {
            controller.completeOnboardingWizard()
            return
        }
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        direction = .forward
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            step = next
        }
    }

    private func requestPermissions(prompt: Bool = true) {
        guard !isRequestingPermissions else { return }
        isRequestingPermissions = true
        Task {
            _ = await controller.refreshPermissions(prompt: prompt)
            await MainActor.run { isRequestingPermissions = false }
        }
    }
}

// MARK: - Design Tokens

private enum WizardColors {
    static let background = Color(red: 0.11, green: 0.11, blue: 0.118)   // #1C1C1E
    static let card = Color(red: 0.173, green: 0.173, blue: 0.18)         // #2C2C2E
    static let secondary = Color(red: 0.557, green: 0.557, blue: 0.576)   // #8E8E93
    static let accentFrom = Color(red: 0.369, green: 0.361, blue: 0.902)  // #5E5CE6
    static let accentTo = Color(red: 0, green: 0.478, blue: 1)            // #007AFF
    static let success = Color(red: 0.188, green: 0.82, blue: 0.345)      // #30D158
    static let warning = Color(red: 1, green: 0.624, blue: 0.039)         // #FF9F0A

    static var accentGradient: LinearGradient {
        LinearGradient(colors: [accentFrom, accentTo], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var successGradient: LinearGradient {
        LinearGradient(colors: [success, Color(red: 0, green: 0.78, blue: 0.745)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Step Enum

private extension OnboardingWizardView {
    enum Step: Int, CaseIterable {
        case welcome, permissions, shortcut, done

        var title: String {
            switch self {
            case .welcome: "Welcome"
            case .permissions: "Permissions"
            case .shortcut: "Shortcut"
            case .done: "Finish"
            }
        }

        var primaryButtonTitle: String {
            switch self {
            case .welcome: "Get Started"
            case .permissions: "Continue"
            case .shortcut: "Continue"
            case .done: "Start Dictating"
            }
        }
    }

    enum NavigationDirection {
        case forward, backward
    }
}
```

**Step 2: Build and verify the scaffold compiles**

Run: `swift build` from project root.
Expected: Compiles successfully. The wizard shows a dark window with step title placeholder and bottom nav bar.

**Step 3: Commit**

```bash
git add Sources/JackApp/OnboardingWizardView.swift
git commit -m "refactor: scaffold new Raycast-inspired onboarding wizard shell"
```

---

### Task 2: Implement Step 1 — Welcome (Full-Width Hero)

**Files:**
- Modify: `Sources/JackApp/OnboardingWizardView.swift`

**Step 1: Add the welcome step view**

Replace the placeholder `stepContent` with a switch, starting with the welcome case. Add a helper `heroIcon` view for the glowing SF Symbol.

```swift
// Replace stepContent with:
@ViewBuilder
private var stepContent: some View {
    Group {
        switch step {
        case .welcome:
            welcomeStep
        case .permissions:
            Text("Permissions")
                .foregroundStyle(.white)
        case .shortcut:
            Text("Shortcut")
                .foregroundStyle(.white)
        case .done:
            Text("Done")
                .foregroundStyle(.white)
        }
    }
    .id(step)
    .transition(stepTransition)
    .animation(.spring(response: 0.4, dampingFraction: 0.85), value: step)
}

// Add new computed property:
private var welcomeStep: some View {
    VStack(spacing: 20) {
        Spacer()

        heroIcon(
            systemName: "wand.and.stars.inverse",
            gradient: WizardColors.accentGradient,
            size: 56
        )

        Text("Welcome to Jack")
            .font(.system(size: 28, weight: .bold))
            .foregroundStyle(.white)

        Text("Press a key, speak, and your words appear anywhere on your Mac.")
            .font(.system(size: 15))
            .foregroundStyle(WizardColors.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 400)

        VStack(alignment: .leading, spacing: 12) {
            checklistItem("Grant system permissions")
            checklistItem("Choose your invocation key")
            checklistItem("Pick your shortcut mode")
        }
        .padding(.top, 8)

        Spacer()
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 40)
}

// Add helpers:
private func heroIcon(systemName: String, gradient: LinearGradient, size: CGFloat) -> some View {
    ZStack {
        Circle()
            .fill(gradient.opacity(0.15))
            .frame(width: size * 1.8, height: size * 1.8)
            .blur(radius: 20)

        Image(systemName: systemName)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(gradient)
    }
}

private func checklistItem(_ text: String) -> some View {
    HStack(spacing: 10) {
        Image(systemName: "circle")
            .font(.system(size: 12))
            .foregroundStyle(WizardColors.secondary.opacity(0.5))
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(WizardColors.secondary)
    }
}
```

**Step 2: Build and verify**

Run: `swift build`
Expected: Compiles. Welcome step shows hero icon, title, subtitle, and checklist.

**Step 3: Commit**

```bash
git add Sources/JackApp/OnboardingWizardView.swift
git commit -m "feat: add Welcome step with hero icon and checklist"
```

---

### Task 3: Implement Step 2 — Permissions (Two-Column)

**Files:**
- Modify: `Sources/JackApp/OnboardingWizardView.swift`

**Step 1: Add the permissions step view**

Add a `twoColumnLayout` helper and the permissions step with dark cards for each permission.

```swift
// Replace permissions placeholder in stepContent switch:
case .permissions:
    permissionsStep

// Add:
private var permissionsStep: some View {
    twoColumnLayout(
        icon: "lock.shield.fill",
        gradient: WizardColors.successGradient,
        title: "Permissions",
        subtitle: "Jack needs three macOS permissions to work."
    ) {
        VStack(spacing: 12) {
            permissionCard(
                icon: "keyboard.fill",
                title: "Input Monitoring",
                detail: "Global shortcut detection",
                granted: controller.keyboardMonitoringGranted,
                settingsAction: controller.openInputMonitoringSettings
            )
            permissionCard(
                icon: "accessibility",
                title: "Accessibility",
                detail: "Auto-paste into focused apps",
                granted: controller.accessibilityGranted,
                settingsAction: controller.openAccessibilitySettings
            )
            permissionCard(
                icon: "mic.fill",
                title: "Microphone",
                detail: "Capture your voice",
                granted: controller.microphoneGranted,
                settingsAction: controller.openMicrophoneSettings
            )

            HStack(spacing: 10) {
                Button {
                    requestPermissions()
                } label: {
                    HStack(spacing: 6) {
                        if isRequestingPermissions {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(isRequestingPermissions ? "Requesting..." : "Request All")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(WizardColors.accentFrom)
                .disabled(isRequestingPermissions)

                Button("Re-check") {
                    requestPermissions(prompt: false)
                }
                .buttonStyle(.bordered)
                .tint(WizardColors.secondary)
                .disabled(isRequestingPermissions)
            }
            .padding(.top, 4)

            if !controller.allRequiredPermissionsGranted {
                Text("You can continue, but dictation won't fully work until all permissions are granted.")
                    .font(.system(size: 11))
                    .foregroundStyle(WizardColors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// Add helpers:
private func twoColumnLayout(
    icon: String,
    gradient: LinearGradient,
    title: String,
    subtitle: String,
    @ViewBuilder rightContent: () -> some View
) -> some View {
    HStack(alignment: .top, spacing: 0) {
        // Left column
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            heroIcon(systemName: icon, gradient: gradient, size: 44)
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(WizardColors.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .frame(width: 220)
        .padding(.leading, 36)

        // Right column
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            rightContent()
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 28)
    }
}

private func permissionCard(
    icon: String,
    title: String,
    detail: String,
    granted: Bool,
    settingsAction: @escaping () -> Void
) -> some View {
    HStack(spacing: 12) {
        Image(systemName: icon)
            .font(.system(size: 16))
            .foregroundStyle(granted ? WizardColors.success : WizardColors.secondary)
            .frame(width: 32, height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(WizardColors.card)
            )

        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)

                Text(granted ? "Granted" : "Missing")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(granted ? WizardColors.success : WizardColors.warning)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill((granted ? WizardColors.success : WizardColors.warning).opacity(0.15))
                    )
            }
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(WizardColors.secondary)
        }

        Spacer()

        Button {
            settingsAction()
        } label: {
            Image(systemName: "arrow.up.forward.square")
                .font(.system(size: 12))
                .foregroundStyle(WizardColors.secondary)
        }
        .buttonStyle(.plain)
    }
    .padding(12)
    .background(
        RoundedRectangle(cornerRadius: 12)
            .fill(WizardColors.card)
    )
}
```

**Step 2: Build and verify**

Run: `swift build`
Expected: Compiles. Permissions step shows two-column layout with three permission cards.

**Step 3: Commit**

```bash
git add Sources/JackApp/OnboardingWizardView.swift
git commit -m "feat: add Permissions step with two-column layout and permission cards"
```

---

### Task 4: Implement Step 3 — Shortcut Setup (Two-Column)

**Files:**
- Modify: `Sources/JackApp/OnboardingWizardView.swift`

**Step 1: Add the shortcut step view**

Includes the invocation key card with pulsing capture state, mode selection tiles, and optional voice note key.

```swift
// Replace shortcut placeholder in stepContent switch:
case .shortcut:
    shortcutStep

// Add:
private var shortcutStep: some View {
    twoColumnLayout(
        icon: "keyboard.fill",
        gradient: WizardColors.accentGradient,
        title: "Shortcut",
        subtitle: "Choose how you'll trigger dictation."
    ) {
        VStack(alignment: .leading, spacing: 16) {
            // Invocation Key Card
            VStack(alignment: .leading, spacing: 10) {
                Text("Invocation Key")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(WizardColors.secondary)
                    .textCase(.uppercase)

                HStack {
                    Text(controller.invocationKeyDisplayName)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Spacer()

                    if controller.isCapturingInvocationKey {
                        Button("Cancel") {
                            controller.cancelInvocationKeyCapture()
                        }
                        .buttonStyle(.bordered)
                        .tint(WizardColors.secondary)
                        .controlSize(.small)
                    } else {
                        Button("Change Key") {
                            controller.startInvocationKeyCapture()
                        }
                        .buttonStyle(.bordered)
                        .tint(WizardColors.accentFrom)
                        .controlSize(.small)
                        .disabled(controller.isCapturingVoiceNoteSwitchKey)
                    }
                }

                if controller.isCapturingInvocationKey {
                    Text("Press any physical key now...")
                        .font(.system(size: 11))
                        .foregroundStyle(WizardColors.warning)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(WizardColors.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(
                                controller.isCapturingInvocationKey
                                    ? WizardColors.accentFrom.opacity(0.6)
                                    : Color.clear,
                                lineWidth: 1.5
                            )
                    )
            )
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: controller.isCapturingInvocationKey)

            // Shortcut Mode
            Text("Shortcut Mode")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(WizardColors.secondary)
                .textCase(.uppercase)

            HStack(spacing: 8) {
                ForEach(ShortcutMode.allCases) { mode in
                    modeTile(mode: mode, selected: controller.mode == mode)
                        .onTapGesture { controller.mode = mode }
                }
            }

            // Voice Note Key (optional, compact)
            HStack(spacing: 8) {
                Image(systemName: "note.text")
                    .font(.system(size: 11))
                    .foregroundStyle(WizardColors.secondary)
                Text("Voice Note Key:")
                    .font(.system(size: 11))
                    .foregroundStyle(WizardColors.secondary)
                Text(controller.voiceNoteSwitchKeyDisplayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)

                Spacer()

                if controller.isCapturingVoiceNoteSwitchKey {
                    Button("Cancel") {
                        controller.cancelVoiceNoteSwitchKeyCapture()
                    }
                    .controlSize(.mini)
                } else {
                    Button("Change") {
                        controller.startVoiceNoteSwitchKeyCapture()
                    }
                    .controlSize(.mini)
                    .disabled(controller.isCapturingInvocationKey)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(WizardColors.card.opacity(0.6))
            )

            if controller.isCapturingVoiceNoteSwitchKey {
                Text("Press a key to set the voice note switch...")
                    .font(.system(size: 11))
                    .foregroundStyle(WizardColors.warning)
            }
        }
    }
}

private func modeTile(mode: ShortcutMode, selected: Bool) -> some View {
    VStack(spacing: 6) {
        Image(systemName: mode.iconName)
            .font(.system(size: 18))
            .foregroundStyle(selected ? .white : WizardColors.secondary)

        Text(mode.title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(selected ? .white : WizardColors.secondary)

        Text(mode.shortDescription)
            .font(.system(size: 10))
            .foregroundStyle(WizardColors.secondary)
            .multilineTextAlignment(.center)
            .lineLimit(2)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 12)
    .padding(.horizontal, 4)
    .background(
        RoundedRectangle(cornerRadius: 10)
            .fill(selected ? WizardColors.accentFrom.opacity(0.2) : WizardColors.card)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? WizardColors.accentFrom : Color.clear, lineWidth: 1.5)
            )
    )
    .contentShape(Rectangle())
}
```

**Step 2: Add helper properties to ShortcutMode**

In `Sources/JackApp/ShortcutTypes.swift`, add `iconName` and `shortDescription` to the `ShortcutMode` enum:

```swift
// Add to ShortcutMode enum body:
var iconName: String {
    switch self {
    case .toggle: return "arrow.triangle.2.circlepath"
    case .hold: return "hand.tap.fill"
    case .doubleTap: return "hand.tap"
    }
}

var shortDescription: String {
    switch self {
    case .toggle: return "Press to start, press to stop"
    case .hold: return "Hold to record, release to stop"
    case .doubleTap: return "Double-tap to toggle"
    }
}
```

**Step 3: Build and verify**

Run: `swift build`
Expected: Compiles. Shortcut step shows key card, mode tiles, and voice note key row.

**Step 4: Commit**

```bash
git add Sources/JackApp/OnboardingWizardView.swift Sources/JackApp/ShortcutTypes.swift
git commit -m "feat: add Shortcut step with key card, mode tiles, and voice note key"
```

---

### Task 5: Implement Step 4 — Finish (Full-Width Hero)

**Files:**
- Modify: `Sources/JackApp/OnboardingWizardView.swift`

**Step 1: Add the finish step view**

```swift
// Replace done placeholder in stepContent switch:
case .done:
    finishStep

// Add:
private var finishStep: some View {
    VStack(spacing: 20) {
        Spacer()

        heroIcon(
            systemName: "checkmark.seal.fill",
            gradient: WizardColors.successGradient,
            size: 56
        )

        Text("You're All Set")
            .font(.system(size: 28, weight: .bold))
            .foregroundStyle(.white)

        Text("Here's your setup summary.")
            .font(.system(size: 15))
            .foregroundStyle(WizardColors.secondary)

        VStack(alignment: .leading, spacing: 12) {
            summaryRow(label: "Invocation Key", value: controller.invocationKeyDisplayName)
            summaryRow(label: "Shortcut Mode", value: controller.mode.title)
            summaryRow(
                label: "Permissions",
                value: controller.allRequiredPermissionsGranted ? "All Granted" : "Some Missing",
                valueColor: controller.allRequiredPermissionsGranted ? WizardColors.success : WizardColors.warning
            )
        }
        .padding(20)
        .frame(width: 380)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(WizardColors.card)
        )

        Spacer()
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 40)
}

private func summaryRow(label: String, value: String, valueColor: Color = .white) -> some View {
    HStack {
        Text(label)
            .font(.system(size: 13))
            .foregroundStyle(WizardColors.secondary)
        Spacer()
        Text(value)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(valueColor)
    }
}
```

**Step 2: Build and verify**

Run: `swift build`
Expected: Compiles. Finish step shows hero checkmark, summary card with key, mode, and permissions.

**Step 3: Commit**

```bash
git add Sources/JackApp/OnboardingWizardView.swift
git commit -m "feat: add Finish step with summary card"
```

---

### Task 6: Polish — verify transitions, test full flow, final adjustments

**Files:**
- Modify: `Sources/JackApp/OnboardingWizardView.swift` (if needed)

**Step 1: Build the full app and run**

Run: `swift build && swift run` (or use the project's compile_and_run.sh script)
Expected: App launches, wizard appears. Navigate through all 4 steps forward and back.

**Step 2: Verify visuals**

Check each step:
- Welcome: Hero icon glows, checklist items visible, "Get Started" button works
- Permissions: Two-column layout, cards show correct granted/missing state, "Open Settings" links work, "Request All" button works
- Shortcut: Key card shows current key, mode tiles are selectable, voice note key row works, capturing state pulses
- Finish: Summary card shows correct values, "Start Dictating" completes wizard

**Step 3: Verify transitions**

- Forward: Content slides left
- Back: Content slides right
- Step dots animate correctly
- Back button hidden on welcome step

**Step 4: Fix any visual issues found during testing**

Adjust spacing, alignment, or colors as needed.

**Step 5: Commit**

```bash
git add Sources/JackApp/OnboardingWizardView.swift
git commit -m "polish: finalize wizard transitions and visual adjustments"
```
