import SwiftUI

struct ChatSideSheetView: View {
    @Bindable var sheetState: ChatSideSheetState
    @Bindable var chatController: ChatController
    var spaceController: SpaceController
    var onResize: ((CGFloat) -> Void)?

    // Local state
    @State private var selectedModelForNewThread = "anthropic/claude-sonnet-4"

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
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        // The panel is right-aligned, so dragging left increases width.
                        // We need the panel frame to compute the new width.
                        if let panel = NSApp.keyWindow {
                            let panelRight = panel.frame.maxX
                            let newWidth = panelRight - value.location.x
                            onResize?(newWidth)
                        }
                    }
            )
    }

    // MARK: - Thread Sidebar

    private var threadSidebar: some View {
        VStack(spacing: 0) {
            threadSidebarHeader
            Divider().opacity(0.3)

            if sheetState.isCreatingThread {
                newThreadInput
                Divider().opacity(0.3)
            }

            threadList
        }
    }

    private var threadSidebarHeader: some View {
        HStack {
            Text("Chats")
                .font(.system(size: 13, weight: .semibold))

            Spacer()

            Button {
                sheetState.isCreatingThread = true
                sheetState.newThreadTitle = ""
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

    // MARK: - New Thread Input

    private var newThreadInput: some View {
        VStack(spacing: 6) {
            TextField("Thread title...", text: $sheetState.newThreadTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit { createNewThread() }

            modelPicker
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.05))
    }

    private var modelPicker: some View {
        Menu {
            let favorites = chatController.availableModels.filter {
                chatController.favoriteModelIds.contains($0.id)
            }

            if !favorites.isEmpty {
                Section("Favorites") {
                    ForEach(favorites) { model in
                        Button {
                            selectedModelForNewThread = model.id
                        } label: {
                            HStack {
                                Text(model.name)
                                if selectedModelForNewThread == model.id {
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
                        selectedModelForNewThread = model.id
                    } label: {
                        HStack {
                            Text(model.name)
                            if selectedModelForNewThread == model.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(modelShortName(selectedModelForNewThread))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
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

            Text(modelShortName(thread.model))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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

                    if chatController.isStreaming && !chatController.streamedContent.isEmpty {
                        streamingBubble
                            .id("streaming-bubble")
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
                proxy.scrollTo("streaming-bubble", anchor: .bottom)
            } else if let lastMessage = chatController.messages.last {
                proxy.scrollTo(lastMessage.id, anchor: .bottom)
            }
        }
    }

    private func messageBubble(_ message: ConvexChatMessage) -> some View {
        let isUser = message.role == "user"

        return HStack {
            if isUser { Spacer(minLength: 40) }

            Text(message.content)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isUser ? Color.accentColor.opacity(0.2) : Color.white.opacity(0.08))
                )

            if !isUser { Spacer(minLength: 40) }
        }
    }

    private var streamingBubble: some View {
        HStack {
            HStack(alignment: .top, spacing: 6) {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
                    .padding(.top, 5)

                Text(chatController.streamedContent)
                    .font(.system(size: 13))
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
                .onSubmit { sendMessage() }

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

    private func createNewThread() {
        let title = sheetState.newThreadTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        Task {
            if let threadId = await chatController.createThread(
                title: title,
                model: selectedModelForNewThread,
                spaceId: spaceController.currentSpaceId
            ) {
                await chatController.fetchThreads(spaceId: spaceController.currentSpaceId)
                sheetState.selectedThreadId = threadId
                sheetState.isCreatingThread = false
                sheetState.newThreadTitle = ""
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
