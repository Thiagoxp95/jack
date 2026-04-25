import MarkdownUI
import SwiftUI

struct ChatSideSheetView: View {
    @Bindable var sheetState: ChatSideSheetState
    @Bindable var chatController: ChatController
    var spaceController: SpaceController
    var onResize: ((CGFloat) -> Void)?

    // Local state
    @State private var selectedModelForNewThread = "anthropic/claude-sonnet-4"
    @FocusState private var isInputFocused: Bool

    private let sidebarWidth: CGFloat = 160

    var body: some View {
        HStack(spacing: 0) {
            resizeHandle
            threadSidebar
                .frame(width: sidebarWidth)
            Divider().opacity(0.3)
            chatArea
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .padding(4)
        .preferredColorScheme(.dark)
        .onChange(of: spaceController.activeSpace) { _, _ in
            Task {
                await chatController.fetchThreads(spaceId: spaceController.currentSpaceId)
                sheetState.selectedThreadId = chatController.threads.first?.id
                if let threadId = sheetState.selectedThreadId {
                    await chatController.fetchMessages(threadId: threadId)
                }
            }
        }
        .alert("Delete Chat?", isPresented: $sheetState.isConfirmingDelete) {
            Button("Delete", role: .destructive) {
                if let threadId = sheetState.selectedThreadId {
                    Task {
                        await chatController.deleteThread(threadId: threadId)
                        await chatController.fetchThreads(spaceId: spaceController.currentSpaceId)
                        sheetState.selectedThreadId = chatController.threads.first?.id
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete this chat and all its messages.")
        }
    }

    // MARK: - Resize Handle

    private var resizeHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 6)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { _ in
                        // Panel is right-aligned to screen edge; compute width from mouse position.
                        let mouseX = NSEvent.mouseLocation.x
                        let screenRight = NSScreen.screens.first(where: {
                            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
                        })?.visibleFrame.maxX ?? NSScreen.main?.visibleFrame.maxX ?? 1440
                        let newWidth = screenRight - mouseX
                        onResize?(newWidth)
                    }
            )
    }

    // MARK: - Thread Sidebar

    private var threadSidebar: some View {
        VStack(spacing: 0) {
            threadSidebarHeader
            Divider().opacity(0.3)
            threadList
        }
    }

    private var threadSidebarHeader: some View {
        HStack {
            Text("Chats")
                .font(.system(size: 13, weight: .semibold))

            Spacer()

            Button {
                createNewThreadQuick()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Thread List

    private var threadList: some View {
        Group {
            if chatController.threads.isEmpty && !chatController.isLoading {
                threadEmptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if chatController.isLoading && chatController.threads.isEmpty {
                            HStack {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Loading...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                        } else {
                            ForEach(chatController.threads) { thread in
                                threadRow(thread)
                            }
                        }
                    }
                }
            }
        }
    }

    private var threadEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text("No chats yet")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text("Press \u{2318}N")
                .font(.caption2)
                .foregroundStyle(.quaternary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func threadRow(_ thread: ConvexChatThread) -> some View {
        let isSelected = sheetState.selectedThreadId == thread.id

        return VStack(alignment: .leading, spacing: 3) {
            Text(thread.title)
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(isSelected ? .primary : .secondary)

            HStack(spacing: 4) {
                Text(modelShortName(thread.model))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                Spacer()

                Text(relativeTime(thread.updatedAt))
                    .font(.system(size: 9))
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : .clear)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectThread(thread.id)
        }
        .contextMenu {
            Button(role: .destructive) {
                Task {
                    await chatController.deleteThread(threadId: thread.id)
                    if sheetState.selectedThreadId == thread.id {
                        sheetState.selectedThreadId = nil
                    }
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Chat Area

    private var chatArea: some View {
        Group {
            if let threadId = sheetState.selectedThreadId,
               let thread = chatController.threads.first(where: { $0.id == threadId }) {
                chatContent(thread: thread)
            } else {
                chatEmptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var chatEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("Select or create a chat")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
            Text("\u{2318}N to start")
                .font(.system(size: 11))
                .foregroundStyle(.quaternary)
        }
    }

    private func chatContent(thread: ConvexChatThread) -> some View {
        VStack(spacing: 0) {
            chatTopBar(thread: thread)
            Divider().opacity(0.3)
            messagesView
            Divider().opacity(0.3)
            inputBar
        }
    }

    // MARK: - Chat Top Bar

    private func chatTopBar(thread: ConvexChatThread) -> some View {
        HStack(spacing: 8) {
            Text(thread.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)

            modelSwitcher(thread: thread)

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func modelSwitcher(thread: ConvexChatThread) -> some View {
        Menu {
            let favorites = chatController.availableModels.filter {
                chatController.favoriteModelIds.contains($0.id)
            }

            if !favorites.isEmpty {
                Section("Favorites") {
                    ForEach(favorites) { model in
                        Button {
                            switchModel(threadId: thread.id, modelId: model.id)
                        } label: {
                            HStack {
                                Text(model.name)
                                if model.id == thread.model {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }

            Section("All Models") {
                ForEach(chatController.availableModels) { model in
                    Button {
                        switchModel(threadId: thread.id, modelId: model.id)
                    } label: {
                        HStack {
                            Text(model.name)
                            if model.id == thread.model {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(modelShortName(thread.model))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Messages View

    private var messagesView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(chatController.messages) { message in
                        messageBubble(message)
                            .id(message.id)
                    }

                    if chatController.isStreaming {
                        if chatController.streamedContent.isEmpty {
                            thinkingBubble
                                .id("thinking-bubble")
                        } else {
                            streamingBubble
                                .id("streaming-bubble")
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .onChange(of: chatController.messages.count) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: chatController.streamedContent) { _, _ in
                scrollToBottom(proxy: proxy)
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            if chatController.isStreaming {
                if chatController.streamedContent.isEmpty {
                    proxy.scrollTo("thinking-bubble", anchor: .bottom)
                } else {
                    proxy.scrollTo("streaming-bubble", anchor: .bottom)
                }
            } else if let lastMessage = chatController.messages.last {
                proxy.scrollTo(lastMessage.id, anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func messageBubble(_ message: ConvexChatMessage) -> some View {
        let isUser = message.role == "user"

        HStack {
            if isUser { Spacer(minLength: 40) }

            if isUser {
                Text(message.content)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.accentColor.opacity(0.2))
                    )
            } else {
                Markdown(message.content)
                    .markdownTheme(.chatAssistant)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
            }

            if !isUser { Spacer(minLength: 40) }
        }
    }

    private var thinkingBubble: some View {
        HStack {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Thinking…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )

            Spacer(minLength: 40)
        }
    }

    private var streamingBubble: some View {
        HStack {
            HStack(alignment: .top, spacing: 6) {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
                    .padding(.top, 5)

                Markdown(chatController.streamedContent)
                    .markdownTheme(.chatAssistant)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )

            Spacer(minLength: 40)
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message...", text: $sheetState.inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...4)
                .focused($isInputFocused)
                .onSubmit { sendMessage() }
                .onChange(of: sheetState.shouldFocusInput) { _, shouldFocus in
                    if shouldFocus {
                        isInputFocused = true
                        sheetState.shouldFocusInput = false
                    }
                }

            Button {
                sendMessage()
            } label: {
                Image(systemName: chatController.isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(
                        canSend || chatController.isStreaming ? Color.accentColor : Color.secondary.opacity(0.4)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSend && !chatController.isStreaming)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var canSend: Bool {
        let text = sheetState.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && sheetState.selectedThreadId != nil
    }

    // MARK: - Actions

    private func selectThread(_ threadId: String) {
        sheetState.selectedThreadId = threadId
        Task { await chatController.fetchMessages(threadId: threadId) }
    }

    private func switchModel(threadId: String, modelId: String) {
        Task {
            await chatController.updateThread(threadId: threadId, title: nil, model: modelId)
            await chatController.fetchThreads(spaceId: spaceController.currentSpaceId)
            UserDefaults.standard.set(modelId, forKey: "chat_last_used_model")
        }
    }

    private func createNewThreadQuick() {
        Task {
            let model = selectedModelForNewThread
            if let threadId = await chatController.createThread(
                title: "New Chat",
                model: model,
                spaceId: spaceController.currentSpaceId
            ) {
                await chatController.fetchThreads(spaceId: spaceController.currentSpaceId)
                sheetState.selectedThreadId = threadId
                await chatController.fetchMessages(threadId: threadId)
                sheetState.shouldFocusInput = true
            }
        }
    }

    private func sendMessage() {
        if chatController.isStreaming {
            chatController.cancelStream()
            return
        }
        let text = sheetState.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let threadId = sheetState.selectedThreadId else { return }
        sheetState.inputText = ""

        // Optimistically add user message to local state
        chatController.addOptimisticUserMessage(threadId: threadId, content: text)

        Task { await chatController.sendAndStream(threadId: threadId, content: text) }
    }

    // MARK: - Helpers

    private func modelShortName(_ modelId: String) -> String {
        // Extract last component after "/", e.g. "anthropic/claude-sonnet-4" -> "claude-sonnet-4"
        if let lastComponent = modelId.split(separator: "/").last {
            return String(lastComponent)
        }
        return modelId
    }

    private func relativeTime(_ timestamp: Double) -> String {
        let date = Date(timeIntervalSince1970: timestamp / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Markdown Theme

extension MarkdownUI.Theme {
    nonisolated(unsafe) static let chatAssistant = Theme()
        .text {
            FontSize(13)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(12)
            ForegroundColor(.pink)
        }
        .codeBlock { configuration in
            ScrollView(.horizontal) {
                configuration.label
                    .monospaced()
                    .font(Font.system(size: 12))
                    .padding(10)
            }
            .background(Color.black.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .heading1 { configuration in
            configuration.label
                .font(Font.system(size: 16, weight: .bold))
                .padding(.bottom, 2)
        }
        .heading2 { configuration in
            configuration.label
                .font(Font.system(size: 15, weight: .semibold))
                .padding(.bottom, 2)
        }
        .heading3 { configuration in
            configuration.label
                .font(Font.system(size: 14, weight: .semibold))
                .padding(.bottom, 1)
        }
        .listItem { configuration in
            configuration.label
                .font(Font.system(size: 13))
        }
        .blockquote { configuration in
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor.opacity(0.5))
                    .frame(width: 3)
                configuration.label
                    .foregroundStyle(.secondary)
            }
        }
        .strong {
            FontWeight(.bold)
        }
}
