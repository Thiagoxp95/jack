import ClerkKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var controller: DictationController
    @Bindable var recordingController: RecordingSessionController
    var spaceController: SpaceController
    var authController: AuthController
    @State private var selectedSection: SettingsSection = .overview
    @State private var isLoadingSetup = false
    @State private var setupWindow = SetupWindowController()
    @State private var showCreateSpace = false

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                // Space selector dropdown
                Menu {
                    ForEach(spaceController.availableSpaces) { space in
                        Button {
                            Task { await spaceController.switchSpace(to: space) }
                        } label: {
                            Label(
                                space.name,
                                systemImage: space.isPersonal ? "person.fill" : "building.2.fill"
                            )
                        }
                    }
                    Divider()
                    Button {
                        showCreateSpace = true
                    } label: {
                        Label("Create Space", systemImage: "plus")
                    }
                } label: {
                    HStack {
                        Image(systemName: spaceController.activeSpace.isPersonal ? "person.fill" : "building.2.fill")
                            .foregroundStyle(.secondary)
                        Text(spaceController.activeSpace.name)
                            .font(.headline)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)

                Divider()

                // Existing section list
                List(SettingsSection.allCases, selection: $selectedSection) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                }
                .listStyle(.sidebar)
            }
            .navigationTitle("Actionfy")
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Button("Open Setup Wizard") {
                        controller.showOnboardingWizard()
                    }
                    .buttonStyle(.borderedProminent)

                    Divider()

                    if let user = Clerk.shared.user {
                        VStack(alignment: .leading, spacing: 2) {
                            if let firstName = user.firstName, let lastName = user.lastName {
                                Text("\(firstName) \(lastName)")
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                            }
                            if let email = user.emailAddresses.first?.emailAddress {
                                Text(email)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }

                    Button("Sign Out", role: .destructive) {
                        Task {
                            try? await Clerk.shared.auth.signOut()
                        }
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    sectionView(selectedSection)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.visible)
        }
        .sheet(isPresented: $controller.shouldShowOnboardingWizard) {
            OnboardingWizardView(controller: controller)
        }
        .sheet(isPresented: $showCreateSpace) {
            CreateOrganizationView { org in
                showCreateSpace = false
                spaceController.refreshSpaces()
                Task {
                    let newSpace = Space(id: org.id, name: org.name, isPersonal: false)
                    await spaceController.switchSpace(to: newSpace)
                }
            }
        }
    }

    @ViewBuilder
    private func sectionView(_ section: SettingsSection) -> some View {
        switch section {
        case .overview:
            overviewSection
        case .notes:
            notesSection
        case .shortcuts:
            shortcutsSection
        case .audioModel:
            audioModelSection
        case .screenRecording:
            screenRecordingSection
        case .spaceSettings:
            spaceSettingsSection
        case .advanced:
            advancedSection
        }
    }

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsCard(title: "Voice To Text Permissions", subtitle: "Input Monitoring, Accessibility, and Microphone for dictation.") {
                permissionRow(
                    title: "Input Monitoring",
                    granted: controller.keyboardMonitoringGranted,
                    detail: "Global invocation shortcut"
                )

                permissionRow(
                    title: "Accessibility",
                    granted: controller.accessibilityGranted,
                    detail: "Paste transcript into focused app"
                )

                permissionRow(
                    title: "Microphone",
                    granted: controller.microphoneGranted,
                    detail: "Voice capture input"
                )

                HStack(spacing: 10) {
                    Button("Request Voice Permissions") {
                        controller.requestVoicePermissionsPrompt()
                    }

                    Button("Re-check Voice") {
                        controller.recheckVoicePermissions()
                    }
                }

                if !controller.allRequiredPermissionsGranted {
                    Text("Some voice permissions are still missing.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack(spacing: 10) {
                    Button("Open Input Monitoring") {
                        controller.openInputMonitoringSettings()
                    }
                    .buttonStyle(.bordered)

                    Button("Open Accessibility") {
                        controller.openAccessibilitySettings()
                    }
                    .buttonStyle(.bordered)

                    Button("Open Microphone") {
                        controller.openMicrophoneSettings()
                    }
                    .buttonStyle(.bordered)
                }
                .font(.caption)
            }

        }
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsCard(title: "Output Destination", subtitle: "Control where transcriptions go.") {
                LabeledContent("Default", value: "Paste")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Current Recording", value: controller.recordingOutputModeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Voice Note Switch Key", value: controller.voiceNoteSwitchKeyDisplayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button(controller.isCapturingVoiceNoteSwitchKey ? "Listening for key..." : "Change Voice Note Key") {
                        controller.startVoiceNoteSwitchKeyCapture()
                    }
                    .disabled(controller.isCapturingVoiceNoteSwitchKey || controller.isCapturingInvocationKey)

                    if controller.isCapturingVoiceNoteSwitchKey {
                        Button("Cancel") {
                            controller.cancelVoiceNoteSwitchKeyCapture()
                        }
                    }
                }

                if controller.isCapturingVoiceNoteSwitchKey {
                    Text("Press one key. During recording, pressing this key switches output to Voice Note for the current session only.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("While recording, press this key to switch from Paste to Voice Note. The key press is consumed and not typed in the focused app.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text(controller.notesDirectoryPathText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }

            let notes = controller.loadAllNotes()

            if notes.isEmpty {
                settingsCard(title: "No Notes Yet", subtitle: "Voice notes will appear here.") {
                    Text("Press the voice note switch key during recording to save a note.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(controller.notesDirectoryPathText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
            } else {
                // Group notes by day
                let grouped = Dictionary(grouping: notes) { $0.dayStamp }
                let sortedDays = grouped.keys.sorted(by: >)

                ForEach(sortedDays, id: \.self) { day in
                    let dayNotes = grouped[day] ?? []
                    let displayDate = formatDayHeader(day)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(displayDate)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(dayNotes) { note in
                            noteCard(note)
                        }
                    }
                }
            }
        }
    }

    private func noteCard(_ note: VoiceNote) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "mic.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(note.timestamp)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Text(note.text)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .contextMenu {
            Menu("Move to...") {
                ForEach(spaceController.availableSpaces) { space in
                    Button(space.name) {
                        // Note: VoiceNote is loaded from local markdown files and does not
                        // have a Convex document ID yet. The actual moveToSpace call will
                        // need to wait until notes are loaded from Convex.
                        // TODO: Wire up actual move when VoiceNote has Convex ID
                    }
                }
            }
        }
    }

    private func formatDayHeader(_ dayStamp: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dayStamp) else { return dayStamp }

        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let display = DateFormatter()
            display.dateStyle = .medium
            return display.string(from: date)
        }
    }

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsCard(title: "Shortcut Mode", subtitle: "Choose how the invocation key behaves.") {
                Picker("Shortcut Mode", selection: $controller.mode) {
                    ForEach(ShortcutMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            settingsCard(title: "Invocation Key", subtitle: "Main global trigger for dictation.") {
                LabeledContent("Current Key", value: controller.invocationKeyDisplayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button(controller.isCapturingInvocationKey ? "Listening for key..." : "Change Invocation Key") {
                        controller.startInvocationKeyCapture()
                    }
                    .disabled(controller.isCapturingInvocationKey || controller.isCapturingVoiceNoteSwitchKey)

                    if controller.isCapturingInvocationKey {
                        Button("Cancel") {
                            controller.cancelInvocationKeyCapture()
                        }
                    }
                }

                if controller.isCapturingInvocationKey {
                    Text("Press any physical key now. Left and right modifier keys are distinct.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

        }
    }

    private var audioModelSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsCard(title: "Audio Ducking", subtitle: "Lower output volume while recording.") {
                Toggle("Lower system output volume while recording", isOn: $controller.duckingEnabled)

                HStack(spacing: 10) {
                    Text("Lower By")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $controller.duckingAmountPercent, in: 0 ... 90, step: 5)
                        .disabled(!controller.duckingEnabled)
                    Text(controller.duckingAmountText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                }

                Text("Volume is restored automatically when recording stops.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

        }
    }

    private var screenRecordingSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !recordingController.hasScreenPermission {
                settingsCard(title: "Screen Permission", subtitle: "Screen Recording access is required.") {
                    Text("Grant Screen Recording permission in System Settings to capture your screen.")
                        .font(.caption)
                        .foregroundStyle(.orange)

                    Button("Open Screen Recording Settings") {
                        controller.openAccessibilitySettings()
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)

                    Button("Re-check") {
                        Task { await recordingController.refreshPermissions() }
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                }
            }

            switch recordingController.state {
            case .recording, .paused:
                settingsCard(title: "Recording In Progress", subtitle: "Use the floating bubble to pause or stop.") {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(recordingController.state == .paused ? Color.yellow : Color.red)
                            .frame(width: 10, height: 10)
                        Text(recordingController.formattedElapsedTime)
                            .font(.system(size: 18, weight: .medium, design: .monospaced))
                        Text(recordingController.state == .paused ? "Paused" : "Recording")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button("Stop Recording") {
                        Task { await recordingController.stopRecording() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }

            case .editing:
                settingsCard(title: "Editing Recording", subtitle: "Duration: \(recordingController.formattedElapsedTime)") {
                    Text("The video editor is open in a separate window.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Discard Recording") {
                        recordingController.finishEditing()
                    }
                    .buttonStyle(.bordered)
                    .foregroundStyle(.red)
                }

            case .countdown:
                settingsCard(title: "Starting...", subtitle: "Recording begins after countdown.") {
                    ProgressView()
                        .controlSize(.small)
                }

            default:
                settingsCard(title: "Start Recording", subtitle: "Capture your screen, audio, and camera.") {
                    Button {
                        isLoadingSetup = true
                        Task {
                            await recordingController.openSetup()
                            setupWindow.show(controller: recordingController)
                            isLoadingSetup = false
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if isLoadingSetup {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text("Start Recording")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(isLoadingSetup)
                }
            }

            if recordingController.state == .idle || recordingController.state == .setup {
                settingsCard(title: "Default FPS", subtitle: "Frame rate used for new recordings.") {
                    Picker("FPS", selection: $recordingController.fps) {
                        ForEach(RecordingFPS.allCases) { fpsOption in
                            Text(fpsOption.label).tag(fpsOption)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
    }

    @ViewBuilder
    private var spaceSettingsSection: some View {
        if let org = Clerk.shared.user?.organizationMemberships?.first?.organization {
            OrganizationSettingsView(organization: org)
        } else {
            settingsCard(title: "No Organization", subtitle: "You are not a member of any organization.") {
                Text("Create or join an organization to manage members and settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsCard(title: "Diagnostics", subtitle: "Detailed runtime information.") {
                LabeledContent("Active Model", value: controller.activeModelText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Last Transcription", value: controller.lastLatencyText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Backend", value: controller.lastBackendText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Shortcut Signal", value: controller.lastShortcutSignalText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Current App", value: controller.currentAppIdentityText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(controller.currentAppPathText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)

                HStack(spacing: 10) {
                    Button("Reveal This App in Finder") {
                        controller.revealCurrentAppInFinder()
                    }
                    .buttonStyle(.bordered)

                    Button("Open Setup Wizard") {
                        controller.showOnboardingWizard()
                    }
                    .buttonStyle(.bordered)
                }
                .font(.caption)
            }
        }
    }

    private func settingsCard<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func permissionRow(title: String, granted: Bool, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Circle()
                    .fill(granted ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(granted ? "Granted" : "Missing")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(granted ? .green : .orange)
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(.clear)
                    .frame(width: 8, height: 8)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private extension ContentView {
    enum SettingsSection: String, CaseIterable, Identifiable {
        case overview
        case notes
        case shortcuts
        case audioModel
        case screenRecording
        case spaceSettings
        case advanced

        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview:
                return "Overview"
            case .notes:
                return "Notes"
            case .shortcuts:
                return "Shortcuts"
            case .audioModel:
                return "Audio & Model"
            case .screenRecording:
                return "Screen Recording"
            case .spaceSettings:
                return "Space Settings"
            case .advanced:
                return "Advanced"
            }
        }

        var subtitle: String {
            switch self {
            case .overview:
                return "Core controls and current health at a glance."
            case .notes:
                return "Voice notes captured during recordings."
            case .shortcuts:
                return "Configure invocation behavior and output routing."
            case .audioModel:
                return "Recording volume behavior and model warm-up settings."
            case .screenRecording:
                return "Capture and edit recordings."
            case .spaceSettings:
                return "Manage your space, members, and invitations."
            case .advanced:
                return "Detailed runtime diagnostics and identity information."
            }
        }

        var systemImage: String {
            switch self {
            case .overview:
                return "rectangle.grid.1x2"
            case .notes:
                return "note.text"
            case .shortcuts:
                return "command"
            case .audioModel:
                return "waveform"
            case .screenRecording:
                return "record.circle"
            case .spaceSettings:
                return "building.2"
            case .advanced:
                return "wrench.and.screwdriver"
            }
        }
    }
}
