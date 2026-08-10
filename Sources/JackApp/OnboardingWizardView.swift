import AppKit
import SwiftUI

// MARK: - Design Tokens

private enum WizardColors {
    static let background = Color(nsColor: .windowBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let primaryText = Color(nsColor: .labelColor)
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let divider = Color.primary.opacity(0.08)
    static let subtleFill = Color.primary.opacity(0.05)
    static let subtleStroke = Color.primary.opacity(0.15)
    static let accentFrom = Color(red: 0x5E / 255, green: 0x5C / 255, blue: 0xE6 / 255)
    static let accentTo = Color(red: 0x00 / 255, green: 0x7A / 255, blue: 0xFF / 255)
    static let success = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)

    static let accentGradient = LinearGradient(
        colors: [accentFrom, accentTo],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let successGradient = LinearGradient(
        colors: [success, Color(red: 0x00 / 255, green: 0xC7 / 255, blue: 0xBE / 255)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// MARK: - Step Enum

private enum WizardStep: Int, CaseIterable {
    case welcome = 0
    case permissions
    case screenCapturePermission
    case shortcut
    case modelDownload
    case done

    var primaryButtonTitle: String {
        switch self {
        case .welcome: return "Get Started"
        case .permissions: return "Continue"
        case .screenCapturePermission: return "Continue"
        case .shortcut: return "Continue"
        case .modelDownload: return "Continue"
        case .done: return "Start Dictating"
        }
    }
}

// MARK: - Main View

struct OnboardingWizardView: View {
    @ObservedObject var controller: DictationController
    @State private var step: WizardStep = .welcome
    @State private var direction: NavigationDirection = .forward
    @State private var isRequestingPermissions = false

    private enum NavigationDirection {
        case forward, backward
    }

    var body: some View {
        VStack(spacing: 0) {
            // Step content area
            ZStack {
                stepContentView
                    .id(step)
                    .transition(slideTransition)
            }
            .clipped()
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Bottom navigation bar
            bottomBar
        }
        .frame(width: 760, height: 680)
        .background(WizardColors.background)
        .onDisappear {
            controller.cancelInvocationKeyCapture()
            controller.cancelVoiceNoteSwitchKeyCapture()
        }
    }

    // MARK: - Slide Transition

    private var slideTransition: AnyTransition {
        switch direction {
        case .forward:
            return .asymmetric(
                insertion: .move(edge: .trailing),
                removal: .move(edge: .leading)
            )
        case .backward:
            return .asymmetric(
                insertion: .move(edge: .leading),
                removal: .move(edge: .trailing)
            )
        }
    }

    // MARK: - Step Content Router

    @ViewBuilder
    private var stepContentView: some View {
        switch step {
        case .welcome:
            WelcomeStep()
        case .permissions:
            PermissionsStep(controller: controller, isRequestingPermissions: $isRequestingPermissions)
        case .screenCapturePermission:
            ScreenCapturePermissionStep(onSkip: { navigateForward() })
        case .shortcut:
            ShortcutStep(controller: controller)
        case .modelDownload:
            ModelDownloadStep(controller: controller)
        case .done:
            FinishStep(controller: controller)
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            // Skip (left)
            Button("Skip") {
                controller.dismissOnboardingWizard()
            }
            .buttonStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(WizardColors.secondary)

            Spacer()

            // Step dots (center)
            HStack(spacing: 8) {
                ForEach(WizardStep.allCases, id: \.rawValue) { wizardStep in
                    Circle()
                        .fill(wizardStep == step ? WizardColors.primaryText : WizardColors.primaryText.opacity(0.25))
                        .frame(width: 7, height: 7)
                }
            }

            Spacer()

            // Back + Primary (right)
            HStack(spacing: 10) {
                if step.rawValue > 0 {
                    Button("Back") {
                        navigateBack()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(WizardColors.secondary)
                }

                Button(action: handlePrimaryAction) {
                    Text(step.primaryButtonTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7)
                        .background(WizardColors.accentGradient, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(step == .modelDownload && controller.modelDownloadProgress < 1.0)
                .opacity(step == .modelDownload && controller.modelDownloadProgress < 1.0 ? 0.5 : 1.0)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(WizardColors.background)
    }

    // MARK: - Navigation

    private func navigateForward() {
        guard let next = WizardStep(rawValue: step.rawValue + 1) else { return }
        direction = .forward
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            step = next
        }
    }

    private func navigateBack() {
        guard let prev = WizardStep(rawValue: step.rawValue - 1) else { return }
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
        navigateForward()
    }
}

// MARK: - Step 1: Welcome

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Glow circle + icon
            ZStack {
                Circle()
                    .fill(WizardColors.accentGradient)
                    .frame(width: 100, height: 100)
                    .blur(radius: 30)
                    .opacity(0.5)

                Image(systemName: "wand.and.stars.inverse")
                    .font(.system(size: 56, weight: .medium))
                    .foregroundStyle(WizardColors.accentGradient)
            }

            Text("Welcome to Jack")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(WizardColors.primaryText)

            Text("Press a key, speak, and your words appear anywhere on your Mac.")
                .font(.system(size: 15))
                .foregroundStyle(WizardColors.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            // Checklist
            VStack(alignment: .leading, spacing: 12) {
                checklistItem(icon: "checkmark.circle.fill", text: "Grant permissions for global access")
                checklistItem(icon: "checkmark.circle.fill", text: "Choose your invocation shortcut")
                checklistItem(icon: "checkmark.circle.fill", text: "Start dictating instantly")
            }
            .padding(.top, 8)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
    }

    private func checklistItem(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(WizardColors.accentGradient)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(WizardColors.primaryText.opacity(0.85))
        }
    }
}

// MARK: - Step 2: Permissions

private struct PermissionsStep: View {
    @ObservedObject var controller: DictationController
    @Binding var isRequestingPermissions: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Left column
            VStack(alignment: .leading, spacing: 12) {
                Spacer()

                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(WizardColors.successGradient)

                Text("Permissions")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(WizardColors.primaryText)

                Text("Jack needs a few system permissions to work globally across all apps.")
                    .font(.system(size: 13))
                    .foregroundStyle(WizardColors.secondary)
                    .lineSpacing(2)

                Spacer()
            }
            .frame(width: 220)
            .padding(.leading, 28)
            .padding(.trailing, 16)

            // Right column
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 12) {
                    permissionCard(
                        icon: "keyboard.fill",
                        title: "Input Monitoring",
                        description: "Detect your global invocation shortcut",
                        granted: controller.keyboardMonitoringGranted,
                        buttonLabel: "Grant Access",
                        openAction: { PermissionCenter.shared.beginGrant(.inputMonitoring) }
                    )

                    permissionCard(
                        icon: "hand.raised.fill",
                        title: "Accessibility",
                        description: "Auto-paste transcribed text into focused apps",
                        granted: controller.accessibilityGranted,
                        buttonLabel: "Grant Access",
                        openAction: { PermissionCenter.shared.beginGrant(.accessibility) }
                    )

                    permissionCard(
                        icon: "mic.fill",
                        title: "Microphone",
                        description: "Capture your voice for transcription",
                        granted: controller.microphoneGranted,
                        buttonLabel: "Grant Access",
                        openAction: {
                            Task {
                                _ = await controller.requestMicrophoneOnly()
                            }
                        }
                    )

                    Button(action: { recheckPermissions() }) {
                        Text("Re-check Permissions")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(WizardColors.primaryText.opacity(0.8))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(WizardColors.subtleStroke, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isRequestingPermissions)
                    .padding(.top, 4)

                    if !controller.allRequiredPermissionsGranted {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(WizardColors.warning)
                            Text("Dictation requires all permissions. You can grant them later from System Settings.")
                                .font(.system(size: 11))
                                .foregroundStyle(WizardColors.warning)
                                .lineSpacing(1)
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.vertical, 20)
                .padding(.trailing, 28)
                .padding(.leading, 8)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func permissionCard(
        icon: String,
        title: String,
        description: String,
        granted: Bool,
        buttonLabel: String = "Open Settings",
        openAction: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(granted ? WizardColors.success : WizardColors.secondary)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(WizardColors.subtleFill)
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(WizardColors.primaryText)

                    Text(granted ? "Granted" : "Required")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(granted ? WizardColors.success : WizardColors.warning)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(
                                (granted ? WizardColors.success : WizardColors.warning).opacity(0.15)
                            )
                        )
                }

                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(WizardColors.secondary)
            }

            Spacer()

            if !granted {
                Button(action: openAction) {
                    Text(buttonLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(WizardColors.accentGradient, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(WizardColors.card)
        )
    }

    private func recheckPermissions() {
        guard !isRequestingPermissions else { return }
        isRequestingPermissions = true
        Task {
            _ = await controller.refreshPermissions(prompt: false)
            await MainActor.run {
                isRequestingPermissions = false
            }
        }
    }
}

// MARK: - Step 3: Screen Capture Permission

private struct ScreenCapturePermissionStep: View {
    var onSkip: () -> Void
    @State private var screenPermission = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Left column
            VStack(alignment: .leading, spacing: 12) {
                Spacer()

                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(WizardColors.accentGradient)

                Text("Screen Capture")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(WizardColors.primaryText)

                Text("Optional permission for attaching screenshots to your notes.")
                    .font(.system(size: 13))
                    .foregroundStyle(WizardColors.secondary)
                    .lineSpacing(2)

                Spacer()
            }
            .frame(width: 220)
            .padding(.leading, 28)
            .padding(.trailing, 16)

            // Right column
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 12) {
                    permissionCard(
                        icon: "rectangle.dashed",
                        title: "Screen Recording",
                        description: "Attach screen region screenshots to notes",
                        granted: screenPermission,
                        openAction: { PermissionCenter.shared.beginGrant(.screenRecording) }
                    )

                    Button(action: onSkip) {
                        Text("Skip for now")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(WizardColors.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                }
                .padding(.vertical, 20)
                .padding(.trailing, 28)
                .padding(.leading, 8)
            }
            .frame(maxWidth: .infinity)
        }
        .task {
            await refreshPermissions()
        }
    }

    private func permissionCard(
        icon: String,
        title: String,
        description: String,
        granted: Bool,
        openAction: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(granted ? WizardColors.success : WizardColors.secondary)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(WizardColors.subtleFill)
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(WizardColors.primaryText)

                    Text(granted ? "Granted" : "Not Set")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(granted ? WizardColors.success : WizardColors.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(
                                (granted ? WizardColors.success : WizardColors.secondary).opacity(0.15)
                            )
                        )
                }

                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(WizardColors.secondary)
            }

            Spacer()

            if !granted {
                Button(action: openAction) {
                    HStack(spacing: 4) {
                        Text("Open Settings")
                            .font(.system(size: 11, weight: .medium))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(WizardColors.primaryText.opacity(0.75))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(WizardColors.card)
        )
    }

    private func refreshPermissions() async {
        screenPermission = CGPreflightScreenCaptureAccess()
    }
}

// MARK: - Step 4: Shortcut Setup

private struct ShortcutStep: View {
    @ObservedObject var controller: DictationController
    @State private var capturePulse = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Left column
            VStack(alignment: .leading, spacing: 12) {
                Spacer()

                Image(systemName: "keyboard.fill")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(WizardColors.accentGradient)

                Text("Shortcut")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(WizardColors.primaryText)

                Text("Configure how you trigger dictation with a global keyboard shortcut.")
                    .font(.system(size: 13))
                    .foregroundStyle(WizardColors.secondary)
                    .lineSpacing(2)

                Spacer()
            }
            .frame(width: 220)
            .padding(.leading, 28)
            .padding(.trailing, 16)

            // Right column
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 16) {
                    // Invocation key card
                    invocationKeyCard

                    // Shortcut mode tiles
                    VStack(alignment: .leading, spacing: 8) {
                        Text("SHORTCUT MODE")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(WizardColors.secondary)
                            .tracking(0.5)

                        VStack(spacing: 8) {
                            ForEach(ShortcutMode.allCases) { mode in
                                shortcutModeTile(mode: mode)
                            }
                        }
                    }

                    // Voice note key row
                    voiceNoteKeyRow
                }
                .padding(.vertical, 20)
                .padding(.trailing, 28)
                .padding(.leading, 8)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var invocationKeyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("INVOCATION KEY")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(WizardColors.secondary)
                .tracking(0.5)

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(controller.invocationKeyDisplayName)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(WizardColors.primaryText)

                    Text("Press this key globally to start/stop dictation")
                        .font(.system(size: 11))
                        .foregroundStyle(WizardColors.secondary)
                }

                Spacer()

                if controller.isCapturingInvocationKey {
                    Button("Cancel") {
                        controller.cancelInvocationKeyCapture()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(WizardColors.warning)
                } else {
                    Button(action: { controller.startInvocationKeyCapture() }) {
                        Text("Change Key")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(WizardColors.primaryText.opacity(0.85))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(WizardColors.subtleStroke, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(controller.isCapturingVoiceNoteSwitchKey)
                }
            }

            if controller.isCapturingInvocationKey {
                Text("Press any physical key now. Left/right modifiers are distinct.")
                    .font(.system(size: 11))
                    .foregroundStyle(WizardColors.warning)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(WizardColors.card)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(
                            controller.isCapturingInvocationKey
                                ? WizardColors.accentFrom.opacity(capturePulse ? 0.8 : 0.2)
                                : Color.clear,
                            lineWidth: 1.5
                        )
                        .animation(.easeInOut(duration: 0.8), value: capturePulse)
                )
        )
        .onChange(of: controller.isCapturingInvocationKey) { _, capturing in
            if capturing {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    capturePulse = true
                }
            } else {
                capturePulse = false
            }
        }
    }

    private func shortcutModeTile(mode: ShortcutMode) -> some View {
        Button(action: { controller.mode = mode }) {
            HStack(spacing: 12) {
                Image(systemName: mode.iconName)
                    .font(.system(size: 18))
                    .foregroundStyle(
                        controller.mode == mode
                            ? WizardColors.accentGradient
                            : LinearGradient(colors: [WizardColors.secondary], startPoint: .top, endPoint: .bottom)
                    )
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(WizardColors.primaryText)

                    Text(mode.shortDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(WizardColors.secondary)
                }

                Spacer()

                if controller.mode == mode {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(WizardColors.accentGradient)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(WizardColors.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(
                                controller.mode == mode
                                    ? WizardColors.accentFrom.opacity(0.4)
                                    : Color.clear,
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var voiceNoteKeyRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("VOICE NOTE KEY")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(WizardColors.secondary)
                    .tracking(0.5)

                Text(controller.voiceNoteSwitchKeyDisplayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(WizardColors.primaryText.opacity(0.85))
            }

            Spacer()

            if controller.isCapturingVoiceNoteSwitchKey {
                HStack(spacing: 8) {
                    Text("Press a key...")
                        .font(.system(size: 11))
                        .foregroundStyle(WizardColors.warning)

                    Button("Cancel") {
                        controller.cancelVoiceNoteSwitchKeyCapture()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(WizardColors.warning)
                }
            } else {
                Button(action: { controller.startVoiceNoteSwitchKeyCapture() }) {
                    Text("Change")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(WizardColors.primaryText.opacity(0.75))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(WizardColors.subtleStroke.opacity(0.85), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(controller.isCapturingInvocationKey)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(WizardColors.card)
        )
    }
}

// MARK: - Step 5: Model Download

private struct ModelDownloadStep: View {
    @ObservedObject var controller: DictationController
    @State private var selectedModel: TranscriptionModelChoice = .parakeetV2

    private var localModels: [TranscriptionModelChoice] {
        [.parakeetV2, .parakeetV3]
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Left column
            VStack(alignment: .leading, spacing: 12) {
                Spacer()

                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(WizardColors.accentGradient)

                Text("Speech Model")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(WizardColors.primaryText)

                Text("Choose and download a speech recognition model. Models run entirely on-device for privacy and speed.")
                    .font(.system(size: 13))
                    .foregroundStyle(WizardColors.secondary)
                    .lineSpacing(2)

                Spacer()
            }
            .frame(width: 220)
            .padding(.leading, 28)
            .padding(.trailing, 16)

            // Right column
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 16) {
                    // Model tiles
                    VStack(alignment: .leading, spacing: 8) {
                        Text("SELECT MODEL")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(WizardColors.secondary)
                            .tracking(0.5)

                        ForEach(localModels) { model in
                            modelTile(model: model)
                        }
                    }

                    // Download status card
                    downloadStatusCard
                }
                .padding(.vertical, 20)
                .padding(.trailing, 28)
                .padding(.leading, 8)
            }
            .frame(maxWidth: .infinity)
        }
        .task {
            syncSelection()
            checkIfAlreadyDownloaded()
        }
        .onChange(of: selectedModel) { _, _ in
            controller.selectedTranscriptionModel = selectedModel
            controller.modelDownloadProgress = 0.0
            controller.modelDownloadError = nil
            controller.isDownloadingModel = false
            checkIfAlreadyDownloaded()
        }
    }

    private func syncSelection() {
        if controller.selectedTranscriptionModel.isLocal {
            selectedModel = controller.selectedTranscriptionModel
        } else {
            selectedModel = .parakeetV2
            controller.selectedTranscriptionModel = .parakeetV2
        }
    }

    private func checkIfAlreadyDownloaded() {
        if controller.modelsAlreadyDownloaded(for: selectedModel) {
            controller.modelDownloadProgress = 1.0
        }
    }

    private func modelTile(model: TranscriptionModelChoice) -> some View {
        let isSelected = selectedModel == model
        return Button(action: { selectedModel = model }) {
            HStack(spacing: 12) {
                Image(systemName: model == .parakeetV2 ? "text.bubble.fill" : "globe")
                    .font(.system(size: 18))
                    .foregroundStyle(
                        isSelected
                            ? WizardColors.accentGradient
                            : LinearGradient(
                                colors: [WizardColors.secondary], startPoint: .top, endPoint: .bottom)
                    )
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(WizardColors.primaryText)

                    Text(model.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(WizardColors.secondary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(WizardColors.accentGradient)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(WizardColors.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(
                                isSelected ? WizardColors.accentFrom.opacity(0.4) : Color.clear,
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(controller.isDownloadingModel)
        .opacity(controller.isDownloadingModel && !isSelected ? 0.5 : 1.0)
    }

    @ViewBuilder
    private var downloadStatusCard: some View {
        VStack(spacing: 10) {
            if let error = controller.modelDownloadError {
                // Error state
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(WizardColors.warning)

                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(WizardColors.warning)
                        .lineLimit(2)
                }

                Button(action: { controller.downloadModelForOnboarding() }) {
                    Text("Retry Download")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(WizardColors.accentGradient, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            } else if controller.modelDownloadProgress >= 1.0 && !controller.isDownloadingModel {
                // Complete / already cached
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(WizardColors.success)

                    Text(controller.modelsAlreadyDownloaded(for: selectedModel) ? "Model Ready" : "Download Complete")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(WizardColors.success)
                }
            } else if controller.isDownloadingModel {
                // Downloading
                VStack(spacing: 8) {
                    if controller.modelDownloadProgress >= 1.0 {
                        // Compiling
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Compiling model...")
                                .font(.system(size: 12))
                                .foregroundStyle(WizardColors.secondary)
                        }
                    } else {
                        HStack(spacing: 8) {
                            Text("Downloading...")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(WizardColors.primaryText)

                            Spacer()

                            Text("\(Int(controller.modelDownloadProgress * 100))%")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(WizardColors.primaryText)
                        }

                        ProgressView(value: controller.modelDownloadProgress)
                            .tint(WizardColors.accentFrom)
                    }
                }
            } else {
                // Ready to download
                VStack(spacing: 6) {
                    Button(action: { controller.downloadModelForOnboarding() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 14))
                            Text("Download Model")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(WizardColors.accentGradient, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)

                    Text("~600 MB download")
                        .font(.system(size: 11))
                        .foregroundStyle(WizardColors.secondary)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(WizardColors.card)
        )
    }
}

// MARK: - Step 6: Finish

private struct FinishStep: View {
    @ObservedObject var controller: DictationController

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Glow circle + icon
            ZStack {
                Circle()
                    .fill(WizardColors.successGradient)
                    .frame(width: 100, height: 100)
                    .blur(radius: 30)
                    .opacity(0.5)

                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 56, weight: .medium))
                    .foregroundStyle(WizardColors.successGradient)
            }

            Text("You're All Set")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(WizardColors.primaryText)

            // Summary card
            VStack(spacing: 14) {
                summaryRow(label: "Invocation Key", value: controller.invocationKeyDisplayName)
                Divider().overlay(WizardColors.divider)
                summaryRow(label: "Shortcut Mode", value: controller.mode.title)
                Divider().overlay(WizardColors.divider)
                summaryRow(label: "Speech Model", value: controller.selectedTranscriptionModel.title)
                Divider().overlay(WizardColors.divider)
                summaryRow(
                    label: "Permissions",
                    value: controller.allRequiredPermissionsGranted ? "All Granted" : "Some Missing",
                    valueColor: controller.allRequiredPermissionsGranted ? WizardColors.success : WizardColors.warning
                )
            }
            .padding(16)
            .frame(width: 380)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(WizardColors.card)
            )

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
    }

    private func summaryRow(label: String, value: String, valueColor: Color = WizardColors.primaryText) -> some View {
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
}
