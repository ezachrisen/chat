import Foundation
import Combine
import SwiftData
import SwiftUI

@main
struct ChatApp: App {
    @NSApplicationDelegateAdaptor(ChatAppDelegate.self) private var appDelegate
    private let modelContainer: ModelContainer
    @StateObject private var agentStore: AgentStore
    @StateObject private var localModelStore: LocalModelStore
    @StateObject private var textToSpeechToolStore: TextToSpeechToolStore
    @StateObject private var skillCatalog: SkillCatalog
    @StateObject private var replyFilterStore: ReplyFilterStore
    @StateObject private var chatStore: ChatStore
    @StateObject private var heartbeatScheduler: HeartbeatScheduler
    @StateObject private var preferencesNavigation: PreferencesNavigation

    init() {
        do {
            let container = try ChatModelContainer.make()
            let agentStore = AgentStore(modelContext: container.mainContext)
            let localModelStore = LocalModelStore(modelContext: container.mainContext)
            let textToSpeechToolStore = TextToSpeechToolStore(modelContext: container.mainContext)
            let skillCatalog = SkillCatalog()
            let replyFilterStore = ReplyFilterStore(modelContext: container.mainContext)
            let chatStore = ChatStore(
                agentStore: agentStore,
                localModelStore: localModelStore,
                skillCatalog: skillCatalog,
                replyFilterStore: replyFilterStore,
                modelContext: container.mainContext
            )
            let heartbeatScheduler = HeartbeatScheduler(agentStore: agentStore, chatStore: chatStore)
            let preferencesNavigation = PreferencesNavigation()
            modelContainer = container
            _agentStore = StateObject(wrappedValue: agentStore)
            _localModelStore = StateObject(wrappedValue: localModelStore)
            _textToSpeechToolStore = StateObject(wrappedValue: textToSpeechToolStore)
            _skillCatalog = StateObject(wrappedValue: skillCatalog)
            _replyFilterStore = StateObject(wrappedValue: replyFilterStore)
            _chatStore = StateObject(wrappedValue: chatStore)
            _heartbeatScheduler = StateObject(wrappedValue: heartbeatScheduler)
            _preferencesNavigation = StateObject(wrappedValue: preferencesNavigation)
            if SessionStorageProbe.isRequested {
                Task { @MainActor in
                    await SessionStorageProbe.maybeRun(
                        container: container,
                        agentStore: agentStore,
                        chatStore: chatStore,
                        skillCatalog: skillCatalog
                    )
                }
            } else {
                heartbeatScheduler.start()
            }
        } catch {
            fatalError("Failed to create model container: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                agentStore: agentStore,
                textToSpeechToolStore: textToSpeechToolStore,
                chatStore: chatStore
            )
                .modelContainer(modelContainer)
        }
        .commands {
#if os(macOS)
            AgentCommands(navigation: preferencesNavigation)
#endif
            HeartbeatCommands()
            DeveloperCommands(chatStore: chatStore)
        }

        Window("Heartbeats", id: "heartbeats") {
            HeartbeatsView(
                agentStore: agentStore,
                chatStore: chatStore,
                heartbeatScheduler: heartbeatScheduler
            )
                .modelContainer(modelContainer)
        }

#if os(macOS)
        Settings {
            PreferencesView(
                agentStore: agentStore,
                localModelStore: localModelStore,
                textToSpeechToolStore: textToSpeechToolStore,
                skillCatalog: skillCatalog,
                replyFilterStore: replyFilterStore,
                chatStore: chatStore,
                heartbeatScheduler: heartbeatScheduler,
                navigation: preferencesNavigation
            )
            .modelContainer(modelContainer)
        }
#endif
    }
}

struct ContentView: View {
    @ObservedObject private var agentStore: AgentStore
    @ObservedObject private var textToSpeechToolStore: TextToSpeechToolStore
    @ObservedObject private var chatStore: ChatStore

    init(
        agentStore: AgentStore,
        textToSpeechToolStore: TextToSpeechToolStore,
        chatStore: ChatStore
    ) {
        self.agentStore = agentStore
        self.textToSpeechToolStore = textToSpeechToolStore
        self.chatStore = chatStore
    }

    var body: some View {
        NavigationSplitView {
            ChatSidebar(agentStore: agentStore, chatStore: chatStore)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            if let chat = chatStore.selectedChat {
                ChatDetailView(
                    chat: chat,
                    agentStore: agentStore,
                    textToSpeechToolStore: textToSpeechToolStore,
                    chatStore: chatStore
                )
            } else {
                Text("Start a new chat.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 820, minHeight: 560)
    }
}

struct ChatSidebar: View {
    @ObservedObject var agentStore: AgentStore
    @ObservedObject var chatStore: ChatStore
    @State private var collapsedAgentIDs: Set<Agent.ID> = []
    @State private var groupChatsAreCollapsed = false
    @State private var chatBeingRenamed: ChatViewModel?
    @State private var renameDraft = ""
    @State private var renameAlertIsPresented = false
    @State private var chatPendingReset: ChatViewModel?
    @State private var resetConfirmationIsPresented = false
    @State private var chatPendingDelete: ChatViewModel?
    @State private var deleteConfirmationIsPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            newChatControl
                .padding(.top, 20)
                .padding(.horizontal, 20)

            Text("Chats")
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.top, 28)
                .padding(.horizontal, 20)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !chatStore.groupChats.isEmpty {
                        GroupChatSection(
                            chats: chatStore.groupChats,
                            selectedChatID: $chatStore.selectedChatID,
                            isCollapsed: groupChatsAreCollapsed,
                            onRenameChat: beginRenaming,
                            onResetChat: beginReset,
                            onDeleteChat: beginDelete
                        ) {
                            groupChatsAreCollapsed.toggle()
                        }
                    }

                    ForEach(agentStore.agents) { agent in
                        AgentSidebarSection(
                            agent: agent,
                            defaultChat: chatStore.defaultChat(for: agent.id),
                            extraChats: chatStore.extraChats(for: agent.id),
                            selectedChatID: $chatStore.selectedChatID,
                            isCollapsed: collapsedAgentIDs.contains(agent.id),
                            onRenameChat: beginRenaming,
                            onResetChat: beginReset,
                            onDeleteChat: beginDelete,
                            onNewChat: {
                                startChat(with: agent)
                            },
                            onSelectDefault: {
                                chatStore.selectDefaultChat(for: agent)
                            }
                        ) {
                            toggleAgent(agent.id)
                        }
                    }
                }
                .padding(.top, 14)
                .padding(.horizontal, 12)
            }
        }
        .alert("Rename chat", isPresented: $renameAlertIsPresented) {
            TextField("Chat name", text: $renameDraft)

            Button("Cancel", role: .cancel) { }
            Button("Rename") {
                chatBeingRenamed?.rename(to: renameDraft)
            }
        }
        .confirmationDialog(
            "Reset chat?",
            isPresented: $resetConfirmationIsPresented,
            titleVisibility: .visible,
            presenting: chatPendingReset
        ) { chat in
            Button("Reset Chat", role: .destructive) {
                chatStore.resetChat(chat)
            }
        } message: { _ in
            Text("Previous messages stay saved but will no longer appear or be sent to the model.")
        }
        .confirmationDialog(
            "Delete chat?",
            isPresented: $deleteConfirmationIsPresented,
            titleVisibility: .visible,
            presenting: chatPendingDelete
        ) { chat in
            Button("Delete Chat", role: .destructive) {
                chatStore.deleteChat(chat)
            }
        } message: { _ in
            Text("This chat will be removed from the sidebar. This cannot be undone.")
        }
    }

    private func beginRenaming(_ chat: ChatViewModel) {
        guard chat.canRename else { return }
        chatBeingRenamed = chat
        renameDraft = chat.title
        renameAlertIsPresented = true
    }

    private func beginReset(_ chat: ChatViewModel) {
        chatPendingReset = chat
        resetConfirmationIsPresented = true
    }

    private func beginDelete(_ chat: ChatViewModel) {
        guard chat.canDelete else { return }
        chatPendingDelete = chat
        deleteConfirmationIsPresented = true
    }

    private func toggleAgent(_ agentID: Agent.ID) {
        if collapsedAgentIDs.contains(agentID) {
            collapsedAgentIDs.remove(agentID)
        } else {
            collapsedAgentIDs.insert(agentID)
        }
    }

    private func startChat(with agent: Agent) {
        collapsedAgentIDs.remove(agent.id)
        chatStore.startChat(with: agent)
    }

    @ViewBuilder
    private var newChatControl: some View {
        Menu {
            Button {
                chatStore.startGroupChat()
            } label: {
                Label("Group chat", systemImage: "person.2")
            }

            if !agentStore.agents.isEmpty {
                Divider()

                ForEach(agentStore.agents) { agent in
                    Button(agent.displayName) {
                        startChat(with: agent)
                    }
                }
            }
        } label: {
            NewChatLabel()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .help("Start a new chat")
    }
}

struct NewChatLabel: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.and.pencil")
                .font(.body)
                .frame(width: 20, height: 20)

            Text("New chat")
                .font(.body)

            Spacer()
        }
        .foregroundStyle(.primary)
        .contentShape(Rectangle())
    }
}

struct AgentAvatar: View {
    let name: String
    let id: UUID
    var size: CGFloat = 20

    var body: some View {
        ZStack {
            Circle()
                .fill(backgroundColor)

            Text(initials)
                .font(.system(size: max(9, size * 0.42), weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var initials: String {
        let parts = name.split { $0.isWhitespace || $0.isNewline }.filter { !$0.isEmpty }
        if parts.count >= 2 {
            return String((parts[0].prefix(1) + parts[1].prefix(1))).uppercased()
        }
        if let first = parts.first, let character = first.first {
            return String(character).uppercased()
        }
        return "?"
    }

    private var backgroundColor: Color {
        let colors: [Color] = [
            Color(red: 0.31, green: 0.45, blue: 0.85),
            Color(red: 0.18, green: 0.60, blue: 0.52),
            Color(red: 0.75, green: 0.35, blue: 0.38),
            Color(red: 0.61, green: 0.38, blue: 0.75),
            Color(red: 0.85, green: 0.52, blue: 0.22),
            Color(red: 0.22, green: 0.55, blue: 0.72),
            Color(red: 0.45, green: 0.52, blue: 0.38),
            Color(red: 0.70, green: 0.32, blue: 0.55)
        ]
        let index = id.uuidString.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        return colors[Int(UInt(bitPattern: index) % UInt(colors.count))]
    }
}

struct AgentSidebarSection: View {
    let agent: Agent
    let defaultChat: ChatViewModel?
    let extraChats: [ChatViewModel]
    @Binding var selectedChatID: ChatViewModel.ID?
    let isCollapsed: Bool
    let onRenameChat: (ChatViewModel) -> Void
    let onResetChat: (ChatViewModel) -> Void
    let onDeleteChat: (ChatViewModel) -> Void
    let onNewChat: () -> Void
    let onSelectDefault: () -> Void
    let onToggle: () -> Void

    private var isDefaultSelected: Bool {
        defaultChat.map { selectedChatID == $0.id } ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Button(action: onSelectDefault) {
                    HStack(spacing: 10) {
                        AgentAvatar(name: agent.displayName, id: agent.id)

                        Text(agent.displayName)
                            .font(.body)
                            .lineLimit(1)

                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.primary)
                    .padding(.leading, 12)
                    .padding(.trailing, 8)
                    .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if !extraChats.isEmpty {
                    Button(action: onToggle) {
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                            .frame(width: 28, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isCollapsed ? "Show chats" : "Hide chats")
                }
            }
            .frame(maxWidth: .infinity)
            .background(
                isDefaultSelected ? Color.primary.opacity(0.10) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(Rectangle())
            .contextMenu {
                Button("New chat") {
                    onNewChat()
                }
                if let defaultChat {
                    Button("Reset chat") {
                        onResetChat(defaultChat)
                    }
                    .disabled(defaultChat.isResponding || defaultChat.isCompacting)
                }
            }

            if !isCollapsed, !extraChats.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(extraChats) { chat in
                        ChatRow(
                            chat: chat,
                            isSelected: selectedChatID == chat.id,
                            onRename: {
                                onRenameChat(chat)
                            },
                            onReset: {
                                onResetChat(chat)
                            },
                            onDelete: {
                                onDeleteChat(chat)
                            }
                        ) {
                            selectedChatID = chat.id
                        }
                    }
                }
                .padding(.leading, 30)
                .padding(.bottom, 16)
            } else {
                Color.clear.frame(height: 4)
            }
        }
    }
}

struct GroupChatSection: View {
    let chats: [ChatViewModel]
    @Binding var selectedChatID: ChatViewModel.ID?
    let isCollapsed: Bool
    let onRenameChat: (ChatViewModel) -> Void
    let onResetChat: (ChatViewModel) -> Void
    let onDeleteChat: (ChatViewModel) -> Void
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    Image(systemName: "person.2")
                        .font(.body)
                        .frame(width: 20, height: 20)

                    Text("Group chats")
                        .font(.body.weight(.medium))

                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0))

                    Spacer(minLength: 0)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(chats) { chat in
                        ChatRow(
                            chat: chat,
                            isSelected: selectedChatID == chat.id,
                            onRename: {
                                onRenameChat(chat)
                            },
                            onReset: {
                                onResetChat(chat)
                            },
                            onDelete: {
                                onDeleteChat(chat)
                            }
                        ) {
                            selectedChatID = chat.id
                        }
                    }
                }
                .padding(.bottom, 16)
            }
        }
    }
}

struct ChatRow: View {
    @ObservedObject var chat: ChatViewModel
    let isSelected: Bool
    let onRename: (() -> Void)?
    let onReset: () -> Void
    let onDelete: (() -> Void)?
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 0) {
                Text(chat.title)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }
            .foregroundStyle(.primary)
            .padding(.leading, 12)
            .padding(.trailing, 12)
            .frame(height: 30)
            .background(isSelected ? Color.primary.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let onRename {
                Button("Rename chat") {
                    onRename()
                }
            }
            Button("Reset chat") {
                onReset()
            }
            .disabled(chat.isResponding || chat.isCompacting)
            if let onDelete {
                Button("Delete chat", role: .destructive) {
                    onDelete()
                }
                .disabled(chat.isResponding)
            }
        }
    }
}

struct ChatDetailView: View {
    private static let voiceGenerationIndicatorID = UUID()

    @ObservedObject var chat: ChatViewModel
    @ObservedObject var agentStore: AgentStore
    @ObservedObject var textToSpeechToolStore: TextToSpeechToolStore
    @ObservedObject var chatStore: ChatStore
    @StateObject private var voiceInput = VoiceInputService()
    @StateObject private var voicePlayback = TextToSpeechPlaybackService()
    @FocusState private var composerIsFocused: Bool
    @State private var newestMessageID: ChatMessage.ID?
    @State private var visibleMessageIDs: Set<ChatMessage.ID> = []
    @State private var hasUnreadNewMessages = false
    @State private var voiceDraftPrefix = ""
    @State private var voiceSendIsPending = false
    @State private var readRepliesOnlyIsEnabled = false
    @State private var automaticReplyReadingStartedAt: Date?
    @State private var voiceObservedMessageIDs: Set<ChatMessage.ID> = []
    @State private var voiceErrorMessage: String?
    @State private var isCompactionStatusPresented = false
    @State private var resetConfirmationIsPresented = false
    @State private var deleteConfirmationIsPresented = false

    var body: some View {
        VStack(spacing: 0) {
            modelStatus
                .padding(.horizontal)
                .padding(.top)

            if chat.isGroupChat {
                GroupChatConfigurationView(chat: chat)
                    .padding(.horizontal)
                    .padding(.top, 10)
            }

            ScrollViewReader { proxy in
                ZStack(alignment: .bottom) {
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            if chat.isGroupChat, chat.messages.isEmpty {
                                GroupChatEmptyState(mentions: chat.availableAgentMentions)
                            }

                            ForEach(chat.messages) { message in
                                MessageBubble(
                                    message: message,
                                    rendersMarkdown: chat.rendersMarkdown,
                                    audioChunkIndexes: voicePlayback
                                        .generatedAudioChunkIndexesByMessageID[message.id] ?? [],
                                    playingAudioChunkIndex: voicePlayback.playingMessageID == message.id
                                        ? voicePlayback.playingChunkIndex
                                        : nil,
                                    playbackCurrentTime: voicePlayback.playingMessageID == message.id
                                        ? voicePlayback.playbackCurrentTime
                                        : 0,
                                    playbackDuration: voicePlayback.playingMessageID == message.id
                                        ? voicePlayback.playbackDuration
                                        : 0,
                                    onToggleAudio: { chunkIndex in
                                        toggleAudio(for: message, chunkIndex: chunkIndex)
                                    },
                                    onSeekAudio: { time in
                                        voicePlayback.seekPlayback(to: time)
                                    }
                                )
                                    .id(message.id)
                                    .onAppear {
                                        visibleMessageIDs.insert(message.id)

                                        if message.id == chat.messages.last?.id {
                                            hasUnreadNewMessages = false
                                        }

                                        if message.id == chat.messages.first?.id {
                                            chat.loadOlderMessages()
                                        }
                                    }
                                    .onDisappear {
                                        visibleMessageIDs.remove(message.id)
                                    }
                            }

                            if voicePlayback.isGenerating {
                                VoiceGenerationIndicator {
                                    voicePlayback.cancelGeneration()
                                }
                                .id(Self.voiceGenerationIndicatorID)
                            }

                            if chat.isResponding {
                                TypingBubble(agentName: chat.respondingAgentName)
                                    .id(ChatViewModel.typingIndicatorID)
                            }
                        }
                        .padding()
                    }
                    .background(Color.secondary.opacity(0.08))

                    if shouldShowMoreMessagesButton {
                        Button {
                            hasUnreadNewMessages = false
                            scrollToBottom(with: proxy)
                        } label: {
                            Label(moreMessagesButtonTitle, systemImage: "arrow.down")
                                .font(.callout.weight(.medium))
                                .padding(.horizontal, 18)
                                .padding(.vertical, 10)
                                .background(.regularMaterial, in: Capsule())
                                .overlay {
                                    Capsule()
                                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                                }
                        }
                        .buttonStyle(.plain)
                        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                        .padding(.bottom, 14)
                    }
                }
                .onAppear {
                    voiceObservedMessageIDs = Set(chat.messages.map(\.id))
                    scrollToBottomAfterLayout(with: proxy)
                }
                .onChange(of: chat.id) {
                    stopVoiceModes()
                    voicePlayback.clearGeneratedAudio()
                    voiceSendIsPending = false
                    voiceDraftPrefix = chat.draft
                    voiceObservedMessageIDs = Set(chat.messages.map(\.id))
                    visibleMessageIDs.removeAll()
                    hasUnreadNewMessages = false
                    isCompactionStatusPresented = false
                    scrollToBottomAfterLayout(with: proxy)
                }
                .onChange(of: chat.messages) {
                    speakNewAssistantMessagesIfNeeded()
                    scrollToNewestMessageIfNeeded(with: proxy)
                }
                .onChange(of: chat.isResponding) {
                    submitPendingVoiceDraftIfPossible()

                    if chat.isResponding, latestMessageIsVisible {
                        scrollToBottom(with: proxy)
                    }
                }
                .onChange(of: voicePlayback.isGenerating) {
                    if voicePlayback.isGenerating, latestMessageIsVisible {
                        scrollToBottom(with: proxy)
                    }
                }
            }

            composer
                .padding()
                .background(.bar)
        }
        .navigationTitle(chat.displayTitle)
        .toolbar {
            ToolbarItem {
                Menu {
                    Toggle("Render Markdown", isOn: rendersMarkdown)

                    Divider()

                    Button {
                        Task {
                            await chat.compactConversation()
                        }
                    } label: {
                        if chat.isCompacting {
                            Label("Compacting…", systemImage: "ellipsis")
                        } else {
                            Label("Compact", systemImage: "rectangle.compress.vertical")
                        }
                    }
                    .disabled(chat.isResponding || chat.isCompacting)

                    Button("Compaction Status") {
                        isCompactionStatusPresented = true
                    }

                    Divider()

                    Button("Reset Chat") {
                        resetConfirmationIsPresented = true
                    }
                    .disabled(chat.isResponding || chat.isCompacting)

                    if chat.canDelete {
                        Button("Delete Chat", role: .destructive) {
                            deleteConfirmationIsPresented = true
                        }
                        .disabled(chat.isResponding)
                    }
                } label: {
                    if chat.isCompacting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                .help("Chat actions")
            }
        }
        .sheet(isPresented: $isCompactionStatusPresented) {
            CompactionStatusView(chat: chat)
        }
        .confirmationDialog(
            "Reset chat?",
            isPresented: $resetConfirmationIsPresented,
            titleVisibility: .visible
        ) {
            Button("Reset Chat", role: .destructive) {
                chatStore.resetChat(chat)
            }
        } message: {
            Text("Previous messages stay saved but will no longer appear or be sent to the model.")
        }
        .confirmationDialog(
            "Delete chat?",
            isPresented: $deleteConfirmationIsPresented,
            titleVisibility: .visible
        ) {
            Button("Delete Chat", role: .destructive) {
                chatStore.deleteChat(chat)
            }
        } message: {
            Text("This chat will be removed from the sidebar. This cannot be undone.")
        }
        .onDisappear {
            stopVoiceModes()
            voicePlayback.clearGeneratedAudio()
        }
        .onChange(of: voiceTriggerPhrases) {
            guard voiceInput.isActive else { return }

            if voiceTriggerPhrases.isEmpty {
                stopVoiceModes()
            } else {
                voiceInput.updateTriggerPhrases(voiceTriggerPhrases)
                voiceDraftPrefix = chat.draft
                voiceSendIsPending = false
            }
        }
        .onChange(of: voiceInput.isTranscribing) {
            if voiceInput.isTranscribing {
                VoiceChimePlayer.shared.play(.dictationStarted)
            }
        }
        .alert("Voice error", isPresented: voiceErrorIsPresented) {
            Button("OK") {
                voiceErrorMessage = nil
            }
        } message: {
            Text(voiceErrorMessage ?? "Voice input could not be started.")
        }
    }

    private var rendersMarkdown: Binding<Bool> {
        Binding(
            get: { chat.rendersMarkdown },
            set: { chat.setRendersMarkdown($0) }
        )
    }

    private var modelStatus: some View {
        HStack(spacing: 10) {
            Image(
                systemName: chat.isGroupChat
                    ? "person.2.fill"
                    : chat.canSend ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(chat.isGroupChat ? Color.accentColor : chat.canSend ? .green : .orange)

            Text(chat.availabilityMessage)
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var shouldShowMoreMessagesButton: Bool {
        hasUnreadNewMessages || isScrolledMoreThanFiveMessagesFromLatest
    }

    private var moreMessagesButtonTitle: String {
        hasUnreadNewMessages ? "New messages" : "More messages"
    }

    private var latestMessageIsVisible: Bool {
        guard let latestMessageID = chat.messages.last?.id else { return true }
        return visibleMessageIDs.contains(latestMessageID)
    }

    private var isScrolledMoreThanFiveMessagesFromLatest: Bool {
        guard !visibleMessageIDs.isEmpty,
              chat.messages.count > 5,
              let newestVisibleIndex = chat.messages.lastIndex(where: { visibleMessageIDs.contains($0.id) }) else {
            return false
        }

        return newestVisibleIndex < chat.messages.count - 5
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            HStack(alignment: .bottom, spacing: 4) {
                TextField(chat.composerPlaceholder, text: $chat.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .padding(.leading, 12)
                    .padding(.vertical, 12)
                    .focused($composerIsFocused)
                    .submitLabel(.send)
                    .onSubmit {
                        submitDraft()
                    }
                    .disabled(!chat.canSend || chat.isResponding || voiceInput.isActive)

                HStack(spacing: 2) {
                    replyReadingModeButton
                    voiceModeButton
                }
                .padding(.trailing, 6)
                .padding(.bottom, 4)
            }
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .modifier(VoiceDictationGlow(isActive: voiceInput.isTranscribing))

            Button {
                submitDraft()
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!chat.canSubmitDraft || voiceInput.isActive)
            .help("Send message")
        }
    }

    private var voiceModeButton: some View {
        Button {
            toggleVoiceMode()
        } label: {
            Group {
                if voiceInput.state == .requestingPermission || voiceInput.state == .preparing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(voiceInput.isActive ? Color.red : Color.secondary)
                }
            }
            .frame(width: 32, height: 32)
            .background {
                if voiceInput.isActive {
                    Circle()
                        .fill(Color.red.opacity(0.12))
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!voiceInput.isActive && (!chat.canSend || !voiceModeIsConfigured))
        .help(voiceModeHelpText)
        .accessibilityLabel(voiceModeAccessibilityLabel)
    }

    private var replyReadingModeButton: some View {
        Button {
            toggleReplyReadingMode()
        } label: {
            Image(systemName: readRepliesOnlyIsEnabled ? "speaker.wave.2.fill" : "speaker.wave.2")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(readRepliesOnlyIsEnabled ? Color.accentColor : Color.secondary)
                .frame(width: 32, height: 32)
                .background {
                    if readRepliesOnlyIsEnabled {
                        Circle()
                            .fill(Color.accentColor.opacity(0.12))
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(
            !readRepliesOnlyIsEnabled
                && (!chat.canSend || !replyReadingIsConfigured)
        )
        .help(replyReadingModeHelpText)
        .accessibilityLabel(
            readRepliesOnlyIsEnabled
                ? "Turn off reading replies"
                : "Turn on reading replies without dictation"
        )
    }

    private var replyReadingModeHelpText: String {
        if readRepliesOnlyIsEnabled {
            return "Reading replies; click to turn off"
        }
        if !replyReadingIsConfigured {
            return "Configure a voice tool, voice name, and model for this agent"
        }
        return voiceInput.isActive
            ? "Switch to reading replies without dictation"
            : "Read replies without dictation"
    }

    private var voiceModeHelpText: String {
        switch voiceInput.state {
        case .idle:
            if voiceTriggerPhrases.isEmpty {
                return chat.isGroupChat
                    ? "Set a Voice phrase for an agent in this chat"
                    : "Set a phrase in this agent's Voice settings"
            }
            if !replyReadingIsConfigured {
                return "Configure a voice tool, voice name, and model for this agent"
            }
            return readRepliesOnlyIsEnabled
                ? "Switch to complete voice mode; \(waitingForVoicePhraseHelp.lowercased())"
                : "Start complete voice mode; \(waitingForVoicePhraseHelp.lowercased())"
        case .requestingPermission:
            return "Requesting voice input permission"
        case .preparing:
            return "Preparing voice input"
        case .listening:
            return voiceInput.isTranscribing
                ? "Transcribing; pause for 3 seconds to send"
                : "\(waitingForVoicePhraseHelp); click to stop"
        }
    }

    private var voiceModeAccessibilityLabel: String {
        if voiceInput.state == .listening {
            return voiceInput.isTranscribing
                ? "Stop voice mode; transcribing message"
                : "Stop voice mode; \(waitingForVoicePhraseHelp.lowercased())"
        }
        return "Turn on complete voice mode"
    }

    private var waitingForVoicePhraseHelp: String {
        if voiceTriggerPhrases.count == 1, let phrase = voiceTriggerPhrases.first {
            return "Listening for “\(phrase)”"
        }
        return "Listening for any configured agent phrase"
    }

    private var voiceAgentIDs: Set<Agent.ID> {
        chat.isGroupChat
            ? Set(chat.groupParticipants.map(\.agentID))
            : [chat.agentID]
    }

    private var voiceTriggerPhrases: [String] {
        var normalizedPhrases = Set<String>()
        return agentStore.agents
            .filter { voiceAgentIDs.contains($0.id) }
            .flatMap(\.voiceTriggerPhrases)
            .filter { phrase in
                let normalizedPhrase = phrase.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                )
                .lowercased(with: .current)
                return normalizedPhrases.insert(normalizedPhrase).inserted
            }
    }

    private var voiceModeIsConfigured: Bool {
        !voiceTriggerPhrases.isEmpty && replyReadingIsConfigured
    }

    private var replyReadingIsConfigured: Bool {
        agentStore.agents
            .filter { voiceAgentIDs.contains($0.id) }
            .contains { textToSpeechToolStore.playbackConfiguration(for: $0) != nil }
    }

    private var automaticReplyReadingIsEnabled: Bool {
        voiceInput.isActive || readRepliesOnlyIsEnabled
    }

    private var voiceErrorIsPresented: Binding<Bool> {
        Binding(
            get: { voiceErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    voiceErrorMessage = nil
                }
            }
        )
    }

    private func toggleVoiceMode() {
        if voiceInput.isActive {
            stopVoiceModes()
            voiceSendIsPending = false
            voiceDraftPrefix = chat.draft
            composerIsFocused = true
            return
        }

        let wasReadingRepliesOnly = readRepliesOnlyIsEnabled
        beginTrackingAutomaticRepliesIfNeeded()
        readRepliesOnlyIsEnabled = false
        voiceDraftPrefix = chat.draft
        voiceSendIsPending = false
        voiceErrorMessage = nil
        composerIsFocused = false

        Task { @MainActor in
            do {
                try await voiceInput.start(triggerPhrases: voiceTriggerPhrases) { transcript in
                    chat.draft = draftByAppendingVoiceTranscript(transcript)
                } onUtterance: {
                    finishVoiceUtterance()
                } onError: { error in
                    handleVoiceInputFailure(
                        error,
                        restoreReplyReadingMode: wasReadingRepliesOnly
                    )
                }
            } catch {
                handleVoiceInputFailure(
                    error,
                    restoreReplyReadingMode: wasReadingRepliesOnly
                )
            }
        }
    }

    private func toggleReplyReadingMode() {
        if readRepliesOnlyIsEnabled {
            stopVoiceModes()
            composerIsFocused = true
            return
        }

        beginTrackingAutomaticRepliesIfNeeded()
        voiceInput.stop()
        voiceSendIsPending = false
        voiceDraftPrefix = chat.draft
        readRepliesOnlyIsEnabled = true
        voiceErrorMessage = nil
        composerIsFocused = true
    }

    private func beginTrackingAutomaticRepliesIfNeeded() {
        guard automaticReplyReadingStartedAt == nil else { return }
        automaticReplyReadingStartedAt = .now
        voiceObservedMessageIDs = Set(chat.messages.map(\.id))
    }

    private func handleVoiceInputFailure(
        _ error: Error,
        restoreReplyReadingMode: Bool
    ) {
        voiceInput.stop()
        if restoreReplyReadingMode {
            readRepliesOnlyIsEnabled = true
            beginTrackingAutomaticRepliesIfNeeded()
        } else {
            stopVoiceModes()
        }
        voiceErrorMessage = error.localizedDescription
        composerIsFocused = true
    }

    private func draftByAppendingVoiceTranscript(_ transcript: String) -> String {
        guard !voiceDraftPrefix.isEmpty else { return transcript }
        guard voiceDraftPrefix.last?.isWhitespace != true else {
            return voiceDraftPrefix + transcript
        }
        return voiceDraftPrefix + " " + transcript
    }

    private func finishVoiceUtterance() {
        VoiceChimePlayer.shared.play(.utteranceSent)

        guard chat.canSubmitDraft else {
            voiceSendIsPending = true
            voiceDraftPrefix = chat.draft
            return
        }

        voiceSendIsPending = false
        chat.send()
        voiceDraftPrefix = chat.draft
    }

    private func submitPendingVoiceDraftIfPossible() {
        guard voiceSendIsPending, chat.canSubmitDraft else { return }

        voiceSendIsPending = false
        chat.send()
        voiceDraftPrefix = chat.draft
    }

    private func speakNewAssistantMessagesIfNeeded() {
        let newMessages = chat.messages.filter { !voiceObservedMessageIDs.contains($0.id) }
        voiceObservedMessageIDs.formUnion(newMessages.map(\.id))

        guard automaticReplyReadingIsEnabled,
              let automaticReplyReadingStartedAt else { return }

        for message in newMessages
        where message.role == .assistant && message.createdAt >= automaticReplyReadingStartedAt {
            guard let agentID = message.authorAgentID ?? (chat.isGroupChat ? nil : chat.agentID),
                  let agent = agentStore.agent(for: agentID),
                  let configuration = textToSpeechToolStore.playbackConfiguration(for: agent) else {
                continue
            }

            let agentName = agent.displayName
            VoiceChimePlayer.shared.play(.responseReady)
            voicePlayback.enqueue(
                messageID: message.id,
                text: message.text,
                configuration: configuration
            ) { error in
                voiceErrorMessage = "Could not play \(agentName)'s response. \(error.localizedDescription)"
            }
        }
    }

    private func replayAudio(for message: ChatMessage, chunkIndex: Int) {
        voicePlayback.replay(messageID: message.id, chunkIndex: chunkIndex) { error in
            let author = message.authorName.map { "\($0)'s" } ?? "the"
            voiceErrorMessage = "Could not replay part \(chunkIndex + 1) of \(author) response. \(error.localizedDescription)"
        }
    }

    private func toggleAudio(for message: ChatMessage, chunkIndex: Int) {
        if voicePlayback.playingMessageID == message.id,
           voicePlayback.playingChunkIndex == chunkIndex {
            voicePlayback.stopPlayback()
        } else {
            replayAudio(for: message, chunkIndex: chunkIndex)
        }
    }

    private func stopVoiceModes() {
        voiceInput.stop()
        readRepliesOnlyIsEnabled = false
        voicePlayback.stop()
        VoiceChimePlayer.shared.stopAll()
        automaticReplyReadingStartedAt = nil
    }

    private func submitDraft() {
        chat.send()
        composerIsFocused = true
    }

    private func scrollToNewestMessageIfNeeded(with proxy: ScrollViewProxy) {
        let previousNewestMessageID = newestMessageID
        let latestMessageID = chat.messages.last?.id
        defer { newestMessageID = latestMessageID }

        guard latestMessageID != previousNewestMessageID else { return }

        if previousNewestMessageID == nil || previousNewestMessageID.map(visibleMessageIDs.contains) == true {
            hasUnreadNewMessages = false
            scrollToBottom(with: proxy)
        } else {
            hasUnreadNewMessages = true
        }
    }

    private func scrollToBottomAfterLayout(with proxy: ScrollViewProxy) {
        newestMessageID = chat.messages.last?.id
        hasUnreadNewMessages = false

        Task { @MainActor in
            await Task.yield()
            scrollToBottom(with: proxy, animated: false)
        }
    }

    private func scrollToBottom(with proxy: ScrollViewProxy, animated: Bool = true) {
        let target: UUID?
        if chat.isResponding {
            target = ChatViewModel.typingIndicatorID
        } else if voicePlayback.isGenerating {
            target = Self.voiceGenerationIndicatorID
        } else {
            target = chat.messages.last?.id
        }

        guard let target else { return }

        if animated {
            withAnimation(.snappy) {
                proxy.scrollTo(target, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    var rendersMarkdown = false
    let audioChunkIndexes: [Int]
    let playingAudioChunkIndex: Int?
    let playbackCurrentTime: TimeInterval
    let playbackDuration: TimeInterval
    let onToggleAudio: (Int) -> Void
    let onSeekAudio: (TimeInterval) -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var generationTurn: GenerationTurn?

    var body: some View {
        Group {
            if message.role == .assistant {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .bottom, spacing: 6) {
                        bubble

                        audioControls
                        inspectorControl

                        Spacer(minLength: 40)
                    }

                    if playingAudioChunkIndex != nil {
                        AudioPlaybackTimeline(
                            currentTime: playbackCurrentTime,
                            duration: playbackDuration,
                            onSeek: onSeekAudio
                        )
                        .frame(maxWidth: 340)
                    }
                }
            } else {
                HStack(alignment: .bottom, spacing: 6) {
                    Spacer(minLength: 40)
                    bubble
                }
            }
        }
        .task(id: message.id) {
            loadGenerationTurn()
        }
    }

    @ViewBuilder
    private var audioControls: some View {
        if !audioChunkIndexes.isEmpty {
            VStack(spacing: 4) {
                ForEach(audioChunkIndexes, id: \.self) { chunkIndex in
                    let isPlaying = playingAudioChunkIndex == chunkIndex
                    Button {
                        onToggleAudio(chunkIndex)
                    } label: {
                        ZStack(alignment: .bottomTrailing) {
                            Image(systemName: isPlaying ? "speaker.wave.2.fill" : "speaker.wave.2")
                                .font(.system(size: 12, weight: .semibold))

                            if audioChunkIndexes.count > 1 {
                                Text("\(chunkIndex + 1)")
                                    .font(.system(size: 8, weight: .bold))
                                    .offset(x: 3, y: 3)
                            }
                        }
                        .foregroundStyle(isPlaying ? Color.accentColor : Color.secondary)
                        .frame(width: 26, height: 26)
                        .background(Color.secondary.opacity(0.10), in: Circle())
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(isPlaying ? "Stop audio" : "Replay audio part \(chunkIndex + 1)")
                    .accessibilityLabel(isPlaying ? "Stop audio" : "Replay audio part \(chunkIndex + 1)")
                }
            }
        }
    }

    @ViewBuilder
    private var inspectorControl: some View {
        if let generationTurn,
           generationTurn.toolCallCount > 0 || generationTurn.debugCaptureEnabled {
            GenerationInspectorButton(turn: generationTurn)
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 5) {
            if message.role == .assistant, let authorName = message.authorName {
                Text(authorName)
                    .font(.body.weight(.bold))
            }

            messageText
                .textSelection(.enabled)
                .font(.body)
        }
            .foregroundStyle(message.role == .user ? .white : .primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(message.role == .user ? Color.accentColor : Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: 620, alignment: message.role == .user ? .trailing : .leading)
    }

    @ViewBuilder
    private var messageText: some View {
        if message.role == .assistant, rendersMarkdown {
            MarkdownMessageView(text: message.text)
        } else {
            Text(message.text)
        }
    }
}

private extension MessageBubble {
    func loadGenerationTurn() {
        guard message.role == .assistant else {
            generationTurn = nil
            return
        }
        generationTurn = GenerationQuery.fetchTurn(forAssistantMessage: message.id, in: modelContext)
    }
}

struct AudioPlaybackTimeline: View {
    let currentTime: TimeInterval
    let duration: TimeInterval
    let onSeek: (TimeInterval) -> Void

    private var safeDuration: TimeInterval {
        guard duration.isFinite, duration > 0 else { return 0.01 }
        return duration
    }

    private var safeCurrentTime: TimeInterval {
        guard currentTime.isFinite else { return 0 }
        return min(max(currentTime, 0), safeDuration)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(formattedTime(safeCurrentTime))
                .frame(minWidth: 30, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { safeCurrentTime },
                    set: onSeek
                ),
                in: 0...safeDuration
            )
            .controlSize(.small)
            .accessibilityLabel("Audio playback position")
            .accessibilityValue("\(formattedTime(safeCurrentTime)) of \(formattedTime(duration))")

            Text(formattedTime(duration))
                .frame(minWidth: 30, alignment: .leading)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.10), in: Capsule())
    }

    private func formattedTime(_ time: TimeInterval) -> String {
        guard time.isFinite, time > 0 else { return "0:00" }
        let wholeSeconds = Int(time.rounded(.down))
        return String(format: "%d:%02d", wholeSeconds / 60, wholeSeconds % 60)
    }
}

struct TypingBubble: View {
    let agentName: String?

    var body: some View {
        HStack {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)

                Text(agentName.map { "\($0) is thinking" } ?? "Thinking")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))

            Spacer(minLength: 40)
        }
    }
}

struct VoiceGenerationIndicator: View {
    let onCancel: () -> Void

    var body: some View {
        HStack {
            Button(action: onCancel) {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)

                    Text("Generating audio…")
                        .font(.callout)

                    Image(systemName: "xmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("Cancel remaining audio generation")
            .accessibilityLabel("Cancel audio generation")

            Spacer(minLength: 40)
        }
    }
}

struct GroupChatConfigurationView: View {
    @ObservedObject var chat: ChatViewModel
    @State private var instructionsAreExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label("Participants", systemImage: "person.2")
                    .font(.callout.weight(.medium))

                if chat.groupParticipantMentions.isEmpty {
                    Text("Add one with an @mention")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(chat.groupParticipantMentions, id: \.self) { mention in
                                Text(mention)
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                            }
                        }
                    }
                }

                Spacer(minLength: 0)
            }

            DisclosureGroup("Group instructions", isExpanded: $instructionsAreExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: groupInstructions)
                        .font(.body)
                        .frame(minHeight: 72, maxHeight: 120)
                        .padding(6)
                        .scrollContentBackground(.hidden)
                        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))

                    Text("These instructions are sent with each agent's individual instructions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }
            .font(.callout.weight(.medium))
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var groupInstructions: Binding<String> {
        Binding(
            get: { chat.groupSystemInstructions },
            set: { chat.updateGroupSystemInstructions($0) }
        )
    }
}

struct GroupChatEmptyState: View {
    let mentions: [String]

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.2")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)

            Text("Start the discussion")
                .font(.headline)

            Text(emptyStateDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 420)
        .padding(.vertical, 56)
    }

    private var emptyStateDescription: String {
        guard !mentions.isEmpty else {
            return "Create an agent, then mention them in your first message."
        }
        return "Mention agents in your first message, such as \(mentions.prefix(2).joined(separator: " and "))."
    }
}

#if os(macOS)
struct AgentCommands: Commands {
    @ObservedObject var navigation: PreferencesNavigation
    @Environment(\.openSettings) private var openSettings

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Button("Agents") {
                navigation.selection = .agents
                openSettings()
            }
        }
    }
}
#endif

private struct CompactionStatusView: View {
    @ObservedObject var chat: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var tokenCount: Int?

    private var status: ConversationCompactionStatus {
        chat.compactionStatus
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Compaction Status")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }

            if status.hasDigest {
                VStack(alignment: .leading, spacing: 8) {
                    if let compactedAt = status.compactedAt {
                        LabeledContent("Last compacted") {
                            Text(compactedAt.formatted(date: .abbreviated, time: .shortened))
                        }
                    } else {
                        LabeledContent("Last compacted") {
                            Text("Unknown")
                        }
                    }

                    if let covered = status.coveredMessageCount {
                        LabeledContent("Messages covered") {
                            Text("\(covered)")
                        }
                    }

                    LabeledContent("Summary tokens") {
                        if let tokenCount {
                            Text("\(tokenCount)")
                        } else {
                            Text("About \(status.estimatedTokens)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.callout)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Current summary")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ScrollView {
                        Text(status.summary)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(10)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
            } else {
                Text("This chat has not been compacted yet. Older messages are sent in full until they exceed the model’s context window.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(20)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 360, idealHeight: 480)
        .task(id: status.summary) {
            guard status.hasDigest else {
                tokenCount = nil
                return
            }
            tokenCount = nil
            tokenCount = await ConversationCompaction.tokenCount(for: status.summary)
        }
    }
}

struct DeveloperCommands: Commands {
    @ObservedObject var chatStore: ChatStore

    var body: some Commands {
        CommandMenu("Developer") {
            Button("Add 1,000 messages") {
                chatStore.addFakeMessagesToSelectedChat(count: 1_000)
            }
            .disabled(chatStore.selectedChat == nil)

            Button("Slow response") {
                chatStore.addSlowResponseToSelectedChat()
            }
            .disabled(chatStore.selectedChat == nil)

            Button("Compact conversation") {
                guard let chat = chatStore.selectedChat else { return }
                Task {
                    await chat.compactConversation()
                }
            }
            .disabled(chatStore.selectedChat == nil || chatStore.selectedChat?.isCompacting == true)

            Button("Send test notification") {
                Task {
                    await AppNotifications.sendDeveloperTest()
                }
            }
        }
    }
}

#Preview {
    ContentViewPreview()
}

struct ContentViewPreview: View {
    private let modelContainer: ModelContainer
    private let agentStore: AgentStore
    private let textToSpeechToolStore: TextToSpeechToolStore
    private let chatStore: ChatStore

    init() {
        do {
            let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
            let container = try ChatModelContainer.make(configuration: configuration)
            let agentStore = AgentStore(modelContext: container.mainContext)
            let localModelStore = LocalModelStore(modelContext: container.mainContext)
            let textToSpeechToolStore = TextToSpeechToolStore(modelContext: container.mainContext)
            modelContainer = container
            self.agentStore = agentStore
            self.textToSpeechToolStore = textToSpeechToolStore
            chatStore = ChatStore(
                agentStore: agentStore,
                localModelStore: localModelStore,
                skillCatalog: SkillCatalog(),
                replyFilterStore: ReplyFilterStore(modelContext: container.mainContext),
                modelContext: container.mainContext
            )
        } catch {
            fatalError("Failed to create preview model container: \(error.localizedDescription)")
        }
    }

    var body: some View {
        ContentView(
            agentStore: agentStore,
            textToSpeechToolStore: textToSpeechToolStore,
            chatStore: chatStore
        )
            .modelContainer(modelContainer)
    }
}
