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
    @State private var noteListController = NoteListController()
    var todoListController: TodoListController
    @State private var showSpaceSettings = false
    @State private var showWordReplacements = false
    @State private var showShortcutCapture = false
    @State private var showScreenRecordingCapture = false
    @State private var showTodoSheetCapture = false

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                // Space selector dropdown
                Menu {
                    ForEach(spaceController.availableSpaces) { space in
                        Button {
                            spaceController.switchSpace(to: space)
                        } label: {
                            Label {
                                Text(space.name)
                            } icon: {
                                spaceIconView(spaceController.icon(for: space), size: 14)
                                    .foregroundStyle(spaceController.color(for: space).color)
                            }
                        }
                    }
                    Divider()
                    Button {
                        showCreateSpace = true
                    } label: {
                        Label("New Space", systemImage: "plus")
                    }
                    Button {
                        showSpaceSettings = true
                    } label: {
                        Label("Space Settings", systemImage: "gearshape")
                    }
                } label: {
                    HStack(spacing: 8) {
                        spaceIconView(spaceController.activeSpaceIcon, size: 16)
                            .foregroundStyle(spaceController.activeSpaceColor.color)
                        Text(spaceController.activeSpace.name)
                            .font(.headline)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.quaternary)
                    )
                    .contentShape(Rectangle())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)

                // Section list — only Overview, Notes, Screen Recording
                List(SettingsSection.allCases, selection: $selectedSection) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                }
                .listStyle(.sidebar)
                .tint(spaceController.activeSpaceColor.color)
            }
            .navigationTitle("")
            .safeAreaInset(edge: .bottom) {
                if let user = Clerk.shared.user {
                    HStack(spacing: 10) {
                        AsyncImage(url: URL(string: user.imageUrl)) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .scaledToFill()
                            default:
                                Text(userInitials(user))
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .background(spaceController.activeSpaceColor.color.gradient)
                            }
                        }
                        .frame(width: 32, height: 32)
                        .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 1) {
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

                        Spacer()

                        Button {
                            Task {
                                try? await Clerk.shared.auth.signOut()
                            }
                        } label: {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Sign Out")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
            }
            .tint(spaceController.activeSpaceColor.color)
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
        .sheet(isPresented: $showCreateSpace) {
            CreateSpaceView(spaceController: spaceController) { newSpace in
                showCreateSpace = false
                spaceController.switchSpace(to: newSpace)
            }
        }
        .sheet(isPresented: $showSpaceSettings) {
            SpaceSettingsSheet(spaceController: spaceController)
        }
        .sheet(isPresented: $showWordReplacements) {
            WordReplacementsView(replacements: $controller.wordReplacements)
                .frame(minWidth: 400, minHeight: 300)
        }
        .sheet(isPresented: $showShortcutCapture) {
            ShortcutCaptureView(
                title: "Record Keyboard Shortcut",
                onSave: { shortcut in
                    controller.applyInvocationShortcut(shortcut)
                    showShortcutCapture = false
                },
                onCancel: {
                    showShortcutCapture = false
                }
            )
        }
        .sheet(isPresented: $showScreenRecordingCapture) {
            ShortcutCaptureView(
                title: "Record Screen Recording Shortcut",
                onSave: { shortcut in
                    controller.applyScreenRecordingShortcut(shortcut)
                    showScreenRecordingCapture = false
                },
                onCancel: {
                    showScreenRecordingCapture = false
                }
            )
        }
        .sheet(isPresented: $showTodoSheetCapture) {
            ShortcutCaptureView(
                title: "Record Todo Sheet Shortcut",
                onSave: { shortcut in
                    controller.applyTodoSheetShortcut(shortcut)
                    showTodoSheetCapture = false
                },
                onCancel: {
                    showTodoSheetCapture = false
                }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .showRecordingsTab)) { _ in
            selectedSection = .screenRecording
            NSApp.activate()
            NSApp.keyWindow?.makeKeyAndOrderFront(nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSection)) { notification in
            if let name = notification.userInfo?["section"] as? String,
               let section = SettingsSection(rawValue: name) {
                selectedSection = section
            }
            NSApp.activate()
            NSApp.keyWindow?.makeKeyAndOrderFront(nil)
        }
    }

    @ViewBuilder
    private func sectionView(_ section: SettingsSection) -> some View {
        switch section {
        case .overview:
            overviewSection
        case .notes:
            notesSection
        case .todos:
            todosSection
        case .screenRecording:
            screenRecordingSection
        }
    }

    // MARK: - Overview (consolidated settings)

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 1. Behavior
            settingsCard(title: "Behavior", subtitle: "General application behavior.") {
                toggleRow(icon: "power", title: "Launch at Login", isOn: $controller.launchAtLoginEnabled)
                toggleRow(icon: "dock.rectangle", title: "Show in Dock", isOn: $controller.showInDock)
                toggleRow(icon: "menubar.rectangle", title: "Show in Status Bar", isOn: $controller.showInStatusBar)
                toggleRow(icon: "escape", title: "Escape to Cancel Recording", isOn: $controller.escapeToCancelEnabled)
            }

            // 2. Recording Controls
            settingsCard(title: "Recording Controls", subtitle: "Activation shortcut and mode.") {
                // Type selector (segmented)
                Picker("Type", selection: $controller.shortcutType) {
                    ForEach(ShortcutType.allCases) { type in
                        Text(type.title).tag(type)
                    }
                }
                .pickerStyle(.segmented)

                // Inline row: Mode + Key
                HStack {
                    Image(systemName: "command")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text("Activation Keys")
                        .font(.body.weight(.medium))

                    Spacer()

                    Picker("Mode", selection: $controller.mode) {
                        ForEach(ShortcutMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()

                    if controller.shortcutType == .singleKey {
                        // Single key: inline capture button
                        Button {
                            if controller.isCapturingInvocationKey {
                                controller.cancelInvocationKeyCapture()
                            } else {
                                controller.startInvocationKeyCapture()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(controller.isCapturingInvocationKey ? "Press key…" : controller.invocationKeyDisplayName)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(controller.isCapturingVoiceNoteSwitchKey)
                    } else {
                        // Combination: open capture sheet
                        Button {
                            showShortcutCapture = true
                        } label: {
                            HStack(spacing: 4) {
                                Text(controller.invocationKeyDisplayName)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(controller.isCapturingVoiceNoteSwitchKey)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.black.opacity(0.15))
                )

                if controller.isCapturingInvocationKey {
                    Text("Press a single key (Fn, F-key, or any key).")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("Toggle (tap to start/stop), Hold (record while pressed), or Double Tap (tap twice quickly).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                // Voice Note Switch
                HStack {
                    Image(systemName: "note.text")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text("Voice Note Switch Key")
                        .font(.body.weight(.medium))

                    Spacer()

                    Button {
                        if controller.isCapturingVoiceNoteSwitchKey {
                            controller.cancelVoiceNoteSwitchKeyCapture()
                        } else {
                            controller.startVoiceNoteSwitchKeyCapture()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(controller.isCapturingVoiceNoteSwitchKey ? "Press a key…" : controller.voiceNoteSwitchKeyDisplayName)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(controller.isCapturingInvocationKey)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.black.opacity(0.15))
                )

                Text("While recording, press this key to switch output to Voice Note mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                // Todo Switch
                HStack {
                    Image(systemName: "checklist")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text("Todo Switch Key")
                        .font(.body.weight(.medium))

                    Spacer()

                    Button {
                        if controller.isCapturingTodoSwitchKey {
                            controller.cancelTodoSwitchKeyCapture()
                        } else {
                            controller.startTodoSwitchKeyCapture()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(controller.isCapturingTodoSwitchKey ? "Press a key…" : controller.todoSwitchKeyDisplayName)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(controller.isCapturingInvocationKey)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.black.opacity(0.15))
                )

                Text("While recording, press this key to switch output to Todo mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                // Quick Screen Recording
                HStack {
                    Image(systemName: "record.circle")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text("Quick Screen Recording")
                        .font(.body.weight(.medium))

                    Spacer()

                    if controller.screenRecordingShortcut != nil {
                        Button {
                            controller.clearScreenRecordingKey()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove shortcut")
                    }

                    Button {
                        showScreenRecordingCapture = true
                    } label: {
                        Text(controller.screenRecordingKeyDisplayName)
                            .font(.body.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.black.opacity(0.15))
                )

                Text("Press to instantly start/stop recording your screen with default settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                // Todo Side Sheet
                HStack {
                    Image(systemName: "sidebar.right")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text("Todo Side Sheet")
                        .font(.body.weight(.medium))

                    Spacer()

                    if controller.todoSheetShortcut != nil {
                        Button {
                            controller.clearTodoSheetKey()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove shortcut")
                    }

                    Button {
                        showTodoSheetCapture = true
                    } label: {
                        Text(controller.todoSheetKeyDisplayName)
                            .font(.body.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.black.opacity(0.15))
                )

                Text("Press to open/close the Todo side sheet overlay.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // 3. Audio & Feedback
            settingsCard(title: "Audio & Feedback", subtitle: "Sound, haptics, and audio behavior.") {
                toggleRow(icon: "speaker.wave.2", title: "Sound Effects", isOn: $controller.soundEffectsEnabled)
                toggleRow(icon: "hand.tap", title: "Haptic Feedback", isOn: $controller.hapticFeedbackEnabled)
                toggleRow(icon: "speaker.slash", title: "Mute Slack While Recording", isOn: $controller.slackMuteEnabled)

                Divider()

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

            // 4. Text Handling
            settingsCard(title: "Text Handling", subtitle: "How transcriptions are processed and output.") {
                toggleRow(icon: "doc.on.clipboard", title: "Auto-Copy to Clipboard", isOn: $controller.autoCopyToClipboard)

                HStack {
                    Image(systemName: "arrow.left.arrow.right")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text("Word Replacements")
                        .font(.body.weight(.medium))
                    Spacer()
                    Text("\(controller.wordReplacements.count) rules")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        showWordReplacements = true
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }

                HStack {
                    Image(systemName: "keyboard")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text("Text Input Method")
                        .font(.body.weight(.medium))
                    Spacer()
                    Text("Paste (Cmd+V)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // 5. Transcription Model
            settingsCard(title: "Transcription Model", subtitle: "Choose the speech recognition model.") {
                Picker("Model", selection: $controller.selectedTranscriptionModel) {
                    ForEach(TranscriptionModelChoice.allCases) { model in
                        Text(model.title).tag(model)
                    }
                }
                .pickerStyle(.radioGroup)

                Text(controller.selectedTranscriptionModel.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // 6. Permissions (at bottom)
            settingsCard(title: "Permissions", subtitle: "Input Monitoring, Accessibility, Microphone, and Screen Recording.") {
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

                permissionRow(
                    title: "Screen Recording",
                    granted: recordingController.hasScreenPermission,
                    detail: "Capture screen content"
                )

                permissionRow(
                    title: "Notifications",
                    granted: controller.notificationsGranted,
                    detail: "Todo reminders and alerts"
                )

                HStack(spacing: 10) {
                    Button("Request Voice Permissions") {
                        controller.requestVoicePermissionsPrompt()
                    }

                    Button("Re-check") {
                        controller.recheckVoicePermissions()
                        Task { await recordingController.refreshPermissions() }
                    }
                }

                if !controller.allRequiredPermissionsGranted || !recordingController.hasScreenPermission {
                    Text("Some permissions are still missing.")
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

    // MARK: - Notes

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if noteListController.isLoading {
                settingsCard(title: "Loading Notes...", subtitle: "Fetching from server.") {
                    ProgressView()
                        .controlSize(.small)
                }
            } else if let error = noteListController.error {
                settingsCard(title: "Error", subtitle: "Could not load notes.") {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button("Retry") {
                        Task {
                            await noteListController.fetchNotes(
                                spaceId: spaceController.currentSpaceId
                            )
                        }
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                }
            } else if noteListController.notes.isEmpty {
                settingsCard(title: "No Notes Yet", subtitle: "Voice notes will appear here.") {
                    Text("Press the voice note switch key during recording to save a note.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                // Group notes by day
                let grouped = Dictionary(grouping: noteListController.notes) { $0.dayStamp }
                let sortedDays = grouped.keys.sorted(by: >)

                ForEach(sortedDays, id: \.self) { day in
                    let dayNotes = grouped[day] ?? []
                    let displayDate = formatDayHeader(day)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(displayDate)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(dayNotes) { note in
                            convexNoteCard(note)
                        }
                    }
                }
            }
        }
        .task(id: spaceController.activeSpace.id) {
            await noteListController.fetchNotes(
                spaceId: spaceController.currentSpaceId
            )
        }
        .onChange(of: controller.lastNoteSavedAt) { _, _ in
            Task {
                await noteListController.fetchNotes(
                    spaceId: spaceController.currentSpaceId
                )
            }
        }
    }

    private func convexNoteCard(_ note: ConvexNote) -> some View {
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
            if spaceController.availableSpaces.count > 1 {
                Menu("Move to...") {
                    ForEach(spaceController.availableSpaces) { space in
                        let targetSpaceId = space.isPersonal ? nil : space.id
                        if targetSpaceId != note.spaceId {
                            Button(space.name) {
                                Task {
                                    await noteListController.moveNote(
                                        noteId: note.id,
                                        toSpaceId: targetSpaceId
                                    )
                                    await noteListController.fetchNotes(
                                        spaceId: spaceController.currentSpaceId
                                    )
                                }
                            }
                        }
                    }
                }
            }

            Divider()

            Button(role: .destructive) {
                Task {
                    await noteListController.deleteNote(noteId: note.id)
                }
            } label: {
                Label("Delete", systemImage: "trash")
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

    // MARK: - Todos

    private var todosSection: some View {
        TodosView(controller: todoListController, spaceController: spaceController)
            .task(id: spaceController.activeSpace.id) {
                await todoListController.fetchTodos(spaceId: spaceController.currentSpaceId)
                await todoListController.fetchLists(spaceId: spaceController.currentSpaceId)
            }
            .onChange(of: controller.lastTodoSavedAt) { _, _ in
                Task {
                    await todoListController.fetchTodos(spaceId: spaceController.currentSpaceId)
                }
            }
    }

    // MARK: - Screen Recording

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
                        recordingController.discardEditing()
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
                EmptyView()
            }

            RecordingsLibraryView(
                spaceController: spaceController,
                onStartRecording: {
                    isLoadingSetup = true
                    Task {
                        await recordingController.openSetup()
                        setupWindow.show(controller: recordingController)
                        isLoadingSetup = false
                    }
                },
                isLoadingSetup: isLoadingSetup,
                showStartButton: recordingController.state == .idle || recordingController.state == .setup
            )
        }
    }

    // MARK: - Reusable Components

    private func settingsCard<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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

    private func toggleRow(icon: String, title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Toggle(title, isOn: isOn)
        }
    }

    @ViewBuilder
    private func spaceIconView(_ icon: SpaceIcon, size: CGFloat) -> some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size))
        case .emoji(let char):
            Text(char)
                .font(.system(size: size))
        }
    }

    private func userInitials(_ user: ClerkKit.User) -> String {
        let first = user.firstName?.prefix(1) ?? ""
        let last = user.lastName?.prefix(1) ?? ""
        let initials = "\(first)\(last)"
        return initials.isEmpty ? "?" : initials.uppercased()
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
        case todos
        case screenRecording

        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview:
                return "Overview"
            case .notes:
                return "Notes"
            case .todos:
                return "Todos"
            case .screenRecording:
                return "Screen Recording"
            }
        }

        var systemImage: String {
            switch self {
            case .overview:
                return "rectangle.grid.1x2"
            case .notes:
                return "note.text"
            case .todos:
                return "checklist"
            case .screenRecording:
                return "record.circle"
            }
        }
    }
}
