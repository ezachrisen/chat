import Foundation
import Combine
import SwiftData
import SwiftUI

@main
struct ChatApp: App {
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
            heartbeatScheduler.start()
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
                    textToSpeechToolStore: textToSpeechToolStore
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
                            onRenameChat: beginRenaming
                        ) {
                            groupChatsAreCollapsed.toggle()
                        }
                    }

                    ForEach(agentStore.agents) { agent in
                        let chats = chatStore.chats(for: agent.id)

                        if !chats.isEmpty {
                            AgentProjectSection(
                                agent: agent,
                                chats: chats,
                                selectedChatID: $chatStore.selectedChatID,
                                isCollapsed: collapsedAgentIDs.contains(agent.id),
                                onRenameChat: beginRenaming,
                                onNewChat: {
                                    startChat(with: agent)
                                }
                            ) {
                                toggleAgent(agent.id)
                            }
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
    }

    private func beginRenaming(_ chat: ChatViewModel) {
        chatBeingRenamed = chat
        renameDraft = chat.title
        renameAlertIsPresented = true
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

struct AgentProjectSection: View {
    let agent: Agent
    let chats: [ChatViewModel]
    @Binding var selectedChatID: ChatViewModel.ID?
    let isCollapsed: Bool
    let onRenameChat: (ChatViewModel) -> Void
    let onNewChat: () -> Void
    let onToggle: () -> Void
    @State private var isHoveringHeader = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .trailing) {
                Button(action: onToggle) {
                    HStack(spacing: 10) {
                        Image(systemName: "folder")
                            .font(.body)
                            .frame(width: 20, height: 20)

                        Text(agent.displayName)
                            .font(.body)
                            .lineLimit(1)

                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(isCollapsed ? -90 : 0))

                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.primary)
                    .padding(.leading, 12)
                    .padding(.trailing, 40)
                    .frame(height: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isHoveringHeader {
                    Button(action: onNewChat) {
                        Image(systemName: "plus")
                            .font(.body.weight(.medium))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 6)
                    .help("New chat with \(agent.displayName)")
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onHover { isHovering in
                withAnimation(.easeInOut(duration: 0.12)) {
                    isHoveringHeader = isHovering
                }
            }

            if !isCollapsed {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(chats) { chat in
                        ChatRow(
                            chat: chat,
                            isSelected: selectedChatID == chat.id,
                            onRename: {
                                onRenameChat(chat)
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

struct GroupChatSection: View {
    let chats: [ChatViewModel]
    @Binding var selectedChatID: ChatViewModel.ID?
    let isCollapsed: Bool
    let onRenameChat: (ChatViewModel) -> Void
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
    let onRename: () -> Void
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
            Button("Rename chat") {
                onRename()
            }
        }
    }
}

struct ChatDetailView: View {
    private static let voiceGenerationIndicatorID = UUID()

    @ObservedObject var chat: ChatViewModel
    @ObservedObject var agentStore: AgentStore
    @ObservedObject var textToSpeechToolStore: TextToSpeechToolStore
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
                    scrollToBottomAfterLayout(with: proxy)
                }
                .onChange(of: chat.messages) {
                    speakNewAssistantMessagesIfNeeded()
                    scrollToNewestMessageIfNeeded(with: proxy)
                }
                .onChange(of: chat.isResponding) {
                    submitPendingVoiceDraftIfPossible()

                    if latestMessageIsVisible {
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
        .navigationTitle(chat.title)
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
    let audioChunkIndexes: [Int]
    let playingAudioChunkIndex: Int?
    let playbackCurrentTime: TimeInterval
    let playbackDuration: TimeInterval
    let onToggleAudio: (Int) -> Void
    let onSeekAudio: (TimeInterval) -> Void

    @ViewBuilder
    var body: some View {
        if message.role == .assistant {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .bottom, spacing: 6) {
                    bubble

                    audioControls

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

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 5) {
            if message.role == .assistant, let authorName = message.authorName {
                Text(authorName)
                    .font(.body.weight(.bold))
            }

            Text(message.text)
                .textSelection(.enabled)
                .font(.body)
        }
            .foregroundStyle(message.role == .user ? .white : .primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(message.role == .user ? Color.accentColor : Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: 620, alignment: message.role == .user ? .trailing : .leading)
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
            let container = try ModelContainer(
                for: Agent.self,
                AgentHeartbeat.self,
                HeartbeatRun.self,
                LocalModel.self,
                ReplyFilterSet.self,
                TextToSpeechTool.self,
                StoredChat.self,
                StoredGroupChatParticipant.self,
                StoredChatMessage.self,
                configurations: configuration
            )
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
