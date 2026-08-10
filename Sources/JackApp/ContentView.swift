import JackKnowledgeKit
import MarkdownUI
import SwiftUI


struct ContentView: View {
    @ObservedObject var controller: DictationController
    @ObservedObject private var permissionCenter = PermissionCenter.shared
    var spaceController: SpaceController
    @State private var selectedSection: SettingsSection = .overview
    @State private var showCreateSpace = false
    @State private var noteListController = NoteListController()
    var todoListController: TodoListController
    @State private var showSpaceSettings = false
    @State private var showWordReplacements = false
    @State private var knowledgeStats: KnowledgeStats?
    @State private var embeddingAssetsAvailable: Bool?
    @State private var isDownloadingAssets = false
    @State private var isBackfilling = false
    @State private var didCopyMCPCommand = false
    @State private var showShortcutCapture = false
    @State private var showTodoSheetCapture = false
    @State private var showChatSheetCapture = false
    @State private var knowledgeTab: KnowledgeTab = .notes

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

                // Section list — Overview, Knowledge Center
                List(SettingsSection.allCases, selection: $selectedSection) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                }
                .listStyle(.sidebar)
                .tint(spaceController.activeSpaceColor.color)
            }
            .navigationTitle("")
            // "Knowledge Center" truncates at the default sidebar width.
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 320)
            .safeAreaInset(edge: .bottom) {
                UpdateCardView(updater: AppUpdater.shared, accent: spaceController.activeSpaceColor.color)
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
        .sheet(isPresented: $showChatSheetCapture) {
            ShortcutCaptureView(
                title: "Record AI Chat Shortcut",
                onSave: { shortcut in
                    controller.applyChatSheetShortcut(shortcut)
                    showChatSheetCapture = false
                },
                onCancel: {
                    showChatSheetCapture = false
                }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSection)) { notification in
            if let name = notification.userInfo?["section"] as? String {
                if let section = SettingsSection(rawValue: name) {
                    selectedSection = section
                } else if let tab = KnowledgeTab(rawValue: name) {
                    // Notes and Todos now live inside the Knowledge Center.
                    selectedSection = .knowledge
                    knowledgeTab = tab
                }
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
        case .knowledge:
            knowledgeSection
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
            settingsCard(title: "Recording Controls", subtitle: "Activation shortcut, mode, and switch keys.") {
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

                Text("While recording, press this key to switch output to Todo mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                // AI Switch
                HStack {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text("AI Switch Key")
                        .font(.body.weight(.medium))

                    Spacer()

                    Button {
                        if controller.isCapturingAiSwitchKey {
                            controller.cancelAiSwitchKeyCapture()
                        } else {
                            controller.startAiSwitchKeyCapture()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(controller.isCapturingAiSwitchKey ? "Press a key…" : controller.aiSwitchKeyDisplayName)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(controller.isCapturingInvocationKey)
                }

                Text("While recording, press this key to switch output to AI Chat mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                // Auto Switch
                HStack {
                    Image(systemName: "wand.and.stars")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text("Auto Switch Key")
                        .font(.body.weight(.medium))

                    Spacer()

                    Button {
                        if controller.isCapturingAutoSwitchKey {
                            controller.cancelAutoSwitchKeyCapture()
                        } else {
                            controller.startAutoSwitchKeyCapture()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(controller.isCapturingAutoSwitchKey ? "Press a key…" : controller.autoSwitchKeyDisplayName)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(controller.isCapturingInvocationKey)
                }

                Text("While recording, press this key to let the model decide whether this becomes a note or a todo. Screenshots work here too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // 2b. Shortcuts
            settingsCard(title: "Shortcuts", subtitle: "Global keyboard shortcuts for quick actions.") {
                // Todo Side Sheet
                shortcutRow(
                    icon: "sidebar.right",
                    title: "Todo Side Sheet",
                    displayName: controller.todoSheetKeyDisplayName,
                    hasShortcut: controller.todoSheetShortcut != nil,
                    onCapture: { showTodoSheetCapture = true },
                    onClear: { controller.clearTodoSheetKey() }
                )

                Text("Open/close the Todo side sheet overlay.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                // AI Chat Side Sheet
                shortcutRow(
                    icon: "bubble.left.and.bubble.right",
                    title: "AI Chat",
                    displayName: controller.chatSheetKeyDisplayName,
                    hasShortcut: controller.chatSheetShortcut != nil,
                    onCapture: { showChatSheetCapture = true },
                    onClear: { controller.clearChatSheetKey() }
                )

                Text("Open/close the AI Chat side sheet overlay.")
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

            // 5a. OpenRouter — the one place a key is entered.
            settingsCard(
                title: "OpenRouter",
                subtitle: "Your key, stored on this Mac. Jack calls openrouter.ai directly — no Jack server in between."
            ) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("API Key")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SecureField("sk-or-v1-...", text: $controller.openRouterApiKey)
                        .textFieldStyle(.roundedBorder)
                }

                HStack(spacing: 8) {
                    Circle()
                        .fill(controller.openRouterApiKey.isEmpty ? Color.orange : Color.green)
                        .frame(width: 8, height: 8)
                    Text(controller.openRouterApiKey.isEmpty
                         ? "No key — cleanup and auto mode are disabled"
                         : "Key set · \(controller.openRouterModels.count) models available")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button(controller.isLoadingOpenRouterModels ? "Loading…" : "Refresh Models") {
                        Task { await controller.refreshOpenRouterModels() }
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                    .disabled(controller.isLoadingOpenRouterModels)
                }

                if let error = controller.openRouterModelsError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Text("Get a key at openrouter.ai/keys. It never leaves this Mac except in requests to OpenRouter.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .task {
                if controller.openRouterModels.isEmpty {
                    await controller.refreshOpenRouterModels()
                }
            }

            // 5b. Transcription Cleanup
            settingsCard(title: "Transcription Cleanup", subtitle: "Clean up transcribed text with an LLM before output.") {
                Toggle("Enable cleanup", isOn: $controller.cleanupEnabled)

                if controller.cleanupEnabled {
                    ModelPickerField(
                        icon: "wand.and.rays",
                        title: "Cleanup Model",
                        models: controller.openRouterModels,
                        selection: $controller.cleanupModelId
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Cleanup Prompt")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $controller.cleanupPrompt)
                            .font(.body)
                            .frame(minHeight: 80, maxHeight: 200)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.primary.opacity(0.05))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                            )
                    }
                }
            }

            // 5b. Auto-mode routing + knowledge base plumbing
            smartRoutingCard
            knowledgeSettingsCards

            // 6. Permissions (at bottom)
            settingsCard(title: "Permissions", subtitle: "Live status — drag & drop Jack into System Settings to grant.") {
                ForEach(JackPermission.allCases) { permission in
                    permissionRow(
                        title: permission.title,
                        granted: permissionCenter.isGranted(permission),
                        detail: permission.detail,
                        dragInstall: permission.supportsDragInstall,
                        action: { permissionCenter.beginGrant(permission) }
                    )
                }
            }
        }
    }

    // MARK: - Notes

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if noteListController.isLoading {
                settingsCard(title: "Loading Notes...", subtitle: "Reading local notes.") {
                    ProgressView()
                        .controlSize(.small)
                }
            } else if let error = noteListController.error {
                settingsCard(title: "Error", subtitle: "Could not load notes.") {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button("Retry") {
                        noteListController.refresh()
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
                            noteCard(note)
                        }
                    }
                }
            }
        }
        .task {
            noteListController.refresh()
        }
        .onChange(of: controller.lastNoteSavedAt) { _, _ in
            noteListController.refresh()
        }
    }

    /// Note text; when the note carries screenshot markdown links, render as
    /// markdown with relative image paths resolved against the local notes dir.
    @ViewBuilder
    private func noteBodyView(_ text: String) -> some View {
        if text.contains("![") {
            Markdown(rewriteRelativeImagePaths(in: text))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        } else {
            Text(text)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    /// Rewrite `![...](attachments/...)` links to absolute file:// URLs so
    /// MarkdownUI can load the local screenshots.
    private func rewriteRelativeImagePaths(in text: String) -> String {
        // absoluteString is percent-encoded (the notes dir contains a space).
        var base = NoteService.defaultNotesDirectoryURL().absoluteString
        if !base.hasSuffix("/") { base += "/" }
        return text.replacingOccurrences(
            of: #"\]\((attachments/[^)]+)\)"#,
            with: "](\(base)$1)",
            options: .regularExpression
        )
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

            noteBodyView(note.text)
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
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(note.text, forType: .string)
            } label: {
                Label("Copy Text", systemImage: "doc.on.doc")
            }

            Divider()

            Button(role: .destructive) {
                noteListController.deleteNote(note)
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

    // MARK: - Knowledge Base

    private var knowledgeSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            knowledgeStatsHeader

            // Segmented style drops icons, so label the tabs with text only.
            Picker("", selection: $knowledgeTab) {
                ForEach(KnowledgeTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 260, alignment: .leading)

            switch knowledgeTab {
            case .notes:
                notesSection
            case .todos:
                todosSection
            }
        }
        .task {
            await refreshKnowledgeStatus()
        }
    }

    /// Compact stats strip above the Notes | Todos tabs.
    private var knowledgeStatsHeader: some View {
        HStack(spacing: 24) {
            if let stats = knowledgeStats {
                knowledgeStat(value: stats.entryCount, label: "entries")
                knowledgeStat(value: stats.embeddedCount, label: "embedded")
                knowledgeStat(value: stats.backlogCount, label: "pending")
            } else {
                ProgressView()
                    .controlSize(.small)
            }

            Spacer()

            Text(KnowledgeStore.defaultDirectoryURL().path)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
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
    }

    // MARK: - Knowledge settings (shown in Overview)

    private var knowledgeSettingsCards: some View {
        Group {
            settingsCard(title: "On-Device Embeddings", subtitle: "Semantic search runs fully offline via Apple's NaturalLanguage model.") {
                HStack(spacing: 8) {
                    Circle()
                        .fill(embeddingAssetsAvailable == true ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(embeddingAssetsAvailable == true
                         ? "Embedding model ready"
                         : "Embedding model not downloaded — search falls back to keyword matching")
                        .font(.caption)
                }

                if embeddingAssetsAvailable != true {
                    Button(isDownloadingAssets ? "Downloading..." : "Download Embedding Model") {
                        isDownloadingAssets = true
                        Task {
                            _ = await controller.knowledgeService.embeddings.downloadAssetsIfNeeded()
                            await refreshKnowledgeStatus()
                            isDownloadingAssets = false
                        }
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                    .disabled(isDownloadingAssets)
                }

                if let stats = knowledgeStats, stats.backlogCount > 0, embeddingAssetsAvailable == true {
                    Button(isBackfilling ? "Embedding \(stats.backlogCount) entries..." : "Embed \(stats.backlogCount) Pending Entries") {
                        isBackfilling = true
                        Task {
                            _ = await controller.knowledgeService.backfillMissingEmbeddings()
                            await refreshKnowledgeStatus()
                            isBackfilling = false
                        }
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                    .disabled(isBackfilling)
                }
            }

            settingsCard(title: "Agent Access (MCP)", subtitle: "Let Claude Code or any MCP client search everything you've said.") {
                Text("Jack ships an MCP server that exposes semantic search over your knowledge base. Register it with:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text(mcpSetupCommand)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)

                    Spacer()

                    Button(didCopyMCPCommand ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(mcpSetupCommand, forType: .string)
                        didCopyMCPCommand = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            didCopyMCPCommand = false
                        }
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )

                Text("Tools: search_knowledge (semantic search), recent_entries. The server reads the local store only — nothing leaves your Mac until an agent you run queries it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Auto-mode routing: which model decides note-vs-todo.
    private var smartRoutingCard: some View {
        settingsCard(
            title: "Smart Routing (Auto Mode)",
            subtitle: "Press \(controller.autoSwitchKeyDisplayName) while recording and a model decides: note or todo."
        ) {
            ModelPickerField(
                icon: "arrow.triangle.branch",
                title: "Routing Model",
                models: controller.openRouterModels,
                selection: $controller.routingModelId
            )

            if let verdict = controller.lastIntentVerdictSummary {
                Text("Last decision: \(verdict)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Text("The transcript, OCR text from any screenshots you grabbed, and the frontmost app/window are sent to the model. Screenshots go as recognized text, not as images. Undecidable captures become notes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func knowledgeStat(value: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.title3.weight(.semibold).monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var mcpSetupCommand: String {
        let mcpURL = (Bundle.main.executableURL?.deletingLastPathComponent() ?? URL(fileURLWithPath: "/Applications/Jackly.app/Contents/MacOS"))
            .appendingPathComponent("JackMCP")
        return "claude mcp add jack -- \"\(mcpURL.path)\""
    }

    private func refreshKnowledgeStatus() async {
        knowledgeStats = await controller.knowledgeService.stats()
        embeddingAssetsAvailable = await controller.knowledgeService.embeddings.assetState() == .available
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

    private func shortcutRow(
        icon: String,
        title: String,
        displayName: String,
        hasShortcut: Bool,
        onCapture: @escaping () -> Void,
        onClear: @escaping () -> Void
    ) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(title)
                .font(.body.weight(.medium))

            Spacer()

            if hasShortcut {
                Button {
                    onClear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove shortcut")
            }

            Button {
                onCapture()
            } label: {
                Text(displayName)
                    .font(.body.weight(.medium))
            }
            .buttonStyle(.bordered)
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

    private func permissionRow(title: String, granted: Bool, detail: String, dragInstall: Bool = false, action: @escaping () -> Void) -> some View {
        HStack {
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

            Spacer()

            if !granted {
                Button(dragInstall ? "Grant…" : "Grant") {
                    action()
                }
                .buttonStyle(.borderedProminent)
                .font(.caption)
            } else {
                Button("Open Settings") {
                    action()
                }
                .buttonStyle(.bordered)
                .font(.caption)
            }
        }
    }
}

private extension ContentView {
    enum SettingsSection: String, CaseIterable, Identifiable {
        case overview
        case knowledge

        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview:
                return "Overview"
            case .knowledge:
                return "Knowledge Center"
            }
        }

        var systemImage: String {
            switch self {
            case .overview:
                return "rectangle.grid.1x2"
            case .knowledge:
                return "brain"
            }
        }
    }

    /// The two tabs inside the Knowledge Center.
    enum KnowledgeTab: String, CaseIterable, Identifiable {
        case notes
        case todos

        var id: String { rawValue }

        var title: String {
            switch self {
            case .notes:
                return "Notes"
            case .todos:
                return "Todos"
            }
        }

        var systemImage: String {
            switch self {
            case .notes:
                return "note.text"
            case .todos:
                return "checklist"
            }
        }
    }
}
