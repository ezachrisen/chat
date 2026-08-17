import Foundation
import FoundationModels
import Combine
import SwiftData
import SwiftUI

@main
struct ChatApp: App {
    private let modelContainer: ModelContainer
    @StateObject private var personaStore: PersonaStore
    @StateObject private var localModelStore: LocalModelStore
    @StateObject private var textToSpeechToolStore: TextToSpeechToolStore
    @StateObject private var chatStore: ChatStore
    @StateObject private var heartbeatScheduler: HeartbeatScheduler
    @StateObject private var preferencesNavigation: PreferencesNavigation

    init() {
        do {
            let container = try ModelContainer(
                for: Persona.self,
                PersonaHeartbeat.self,
                HeartbeatRun.self,
                LocalModel.self,
                TextToSpeechTool.self,
                StoredChat.self,
                StoredGroupChatParticipant.self,
                StoredChatMessage.self
            )
            let personaStore = PersonaStore(modelContext: container.mainContext)
            let localModelStore = LocalModelStore(modelContext: container.mainContext)
            let textToSpeechToolStore = TextToSpeechToolStore(modelContext: container.mainContext)
            let chatStore = ChatStore(
                personaStore: personaStore,
                localModelStore: localModelStore,
                modelContext: container.mainContext
            )
            let heartbeatScheduler = HeartbeatScheduler(personaStore: personaStore, chatStore: chatStore)
            let preferencesNavigation = PreferencesNavigation()
            modelContainer = container
            _personaStore = StateObject(wrappedValue: personaStore)
            _localModelStore = StateObject(wrappedValue: localModelStore)
            _textToSpeechToolStore = StateObject(wrappedValue: textToSpeechToolStore)
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
                personaStore: personaStore,
                textToSpeechToolStore: textToSpeechToolStore,
                chatStore: chatStore
            )
                .modelContainer(modelContainer)
        }
        .commands {
#if os(macOS)
            PersonaCommands(navigation: preferencesNavigation)
#endif
            HeartbeatCommands()
            DeveloperCommands(chatStore: chatStore)
        }

        Window("Heartbeats", id: "heartbeats") {
            HeartbeatsView(
                personaStore: personaStore,
                chatStore: chatStore,
                heartbeatScheduler: heartbeatScheduler
            )
                .modelContainer(modelContainer)
        }

#if os(macOS)
        Settings {
            PreferencesView(
                personaStore: personaStore,
                localModelStore: localModelStore,
                textToSpeechToolStore: textToSpeechToolStore,
                chatStore: chatStore,
                navigation: preferencesNavigation
            )
            .modelContainer(modelContainer)
        }
#endif
    }
}

struct ContentView: View {
    @ObservedObject private var personaStore: PersonaStore
    @ObservedObject private var textToSpeechToolStore: TextToSpeechToolStore
    @ObservedObject private var chatStore: ChatStore

    init(
        personaStore: PersonaStore,
        textToSpeechToolStore: TextToSpeechToolStore,
        chatStore: ChatStore
    ) {
        self.personaStore = personaStore
        self.textToSpeechToolStore = textToSpeechToolStore
        self.chatStore = chatStore
    }

    var body: some View {
        NavigationSplitView {
            ChatSidebar(personaStore: personaStore, chatStore: chatStore)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            if let chat = chatStore.selectedChat {
                ChatDetailView(
                    chat: chat,
                    personaStore: personaStore,
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
    @ObservedObject var personaStore: PersonaStore
    @ObservedObject var chatStore: ChatStore
    @State private var collapsedPersonaIDs: Set<Persona.ID> = []
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

                    ForEach(personaStore.personas) { persona in
                        let chats = chatStore.chats(for: persona.id)

                        if !chats.isEmpty {
                            PersonaProjectSection(
                                persona: persona,
                                chats: chats,
                                selectedChatID: $chatStore.selectedChatID,
                                isCollapsed: collapsedPersonaIDs.contains(persona.id),
                                onRenameChat: beginRenaming,
                                onNewChat: {
                                    startChat(with: persona)
                                }
                            ) {
                                togglePersona(persona.id)
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

    private func togglePersona(_ personaID: Persona.ID) {
        if collapsedPersonaIDs.contains(personaID) {
            collapsedPersonaIDs.remove(personaID)
        } else {
            collapsedPersonaIDs.insert(personaID)
        }
    }

    private func startChat(with persona: Persona) {
        collapsedPersonaIDs.remove(persona.id)
        chatStore.startChat(with: persona)
    }

    @ViewBuilder
    private var newChatControl: some View {
        Menu {
            Button {
                chatStore.startGroupChat()
            } label: {
                Label("Group chat", systemImage: "person.2")
            }

            if !personaStore.personas.isEmpty {
                Divider()

                ForEach(personaStore.personas) { persona in
                    Button(persona.displayName) {
                        startChat(with: persona)
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

struct PersonaProjectSection: View {
    let persona: Persona
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

                        Text(persona.displayName)
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
                    .help("New chat with \(persona.displayName)")
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
    @ObservedObject var personaStore: PersonaStore
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
                                GroupChatEmptyState(mentions: chat.availablePersonaMentions)
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
                                TypingBubble(personaName: chat.respondingPersonaName)
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
            return "Configure a voice tool, voice name, and model for this persona"
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
                    ? "Set a Voice phrase for a persona in this chat"
                    : "Set a phrase in this persona's Voice settings"
            }
            if !replyReadingIsConfigured {
                return "Configure a voice tool, voice name, and model for this persona"
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
        return "Listening for any configured persona phrase"
    }

    private var voicePersonaIDs: Set<Persona.ID> {
        chat.isGroupChat
            ? Set(chat.groupParticipants.map(\.personaID))
            : [chat.personaID]
    }

    private var voiceTriggerPhrases: [String] {
        var normalizedPhrases = Set<String>()
        return personaStore.personas
            .filter { voicePersonaIDs.contains($0.id) }
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
        personaStore.personas
            .filter { voicePersonaIDs.contains($0.id) }
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
            guard let personaID = message.authorPersonaID ?? (chat.isGroupChat ? nil : chat.personaID),
                  let persona = personaStore.persona(for: personaID),
                  let configuration = textToSpeechToolStore.playbackConfiguration(for: persona) else {
                continue
            }

            let personaName = persona.displayName
            voicePlayback.enqueue(
                messageID: message.id,
                text: message.text,
                configuration: configuration
            ) { error in
                voiceErrorMessage = "Could not play \(personaName)'s response. \(error.localizedDescription)"
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
    let personaName: String?

    var body: some View {
        HStack {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)

                Text(personaName.map { "\($0) is thinking" } ?? "Thinking")
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

                    Text("These instructions are sent with each persona's individual instructions.")
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
            return "Create a persona, then mention them in your first message."
        }
        return "Mention personas in your first message, such as \(mentions.prefix(2).joined(separator: " and "))."
    }
}

#if os(macOS)
struct PersonaCommands: Commands {
    @ObservedObject var navigation: PreferencesNavigation
    @Environment(\.openSettings) private var openSettings

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Button("Personas") {
                navigation.selection = .personas
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

@MainActor
final class PersonaStore: ObservableObject {
    @Published private(set) var personas: [Persona] = []
    @Published private(set) var heartbeats: [PersonaHeartbeat] = []
    @Published private(set) var heartbeatRuns: [HeartbeatRun] = []
    @Published var selectedPersonaID: Persona.ID?

    private let modelContext: ModelContext

    var selectedPersona: Persona? {
        guard let selectedPersonaID else { return nil }
        return personas.first { $0.id == selectedPersonaID }
    }

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        loadPersonas()
        loadHeartbeats()
        loadHeartbeatRuns()
    }

    func addPersona() {
        let persona = Persona(name: "", soul: "")
        modelContext.insert(persona)
        saveChanges()
        loadPersonas(selecting: persona.id)
    }

    func removeSelectedPersona() {
        guard let selectedPersonaID,
              let index = personas.firstIndex(where: { $0.id == selectedPersonaID }) else {
            return
        }

        let nextSelection: Persona.ID?
        if personas.count <= 1 {
            nextSelection = nil
        } else {
            let nextIndex = min(index, personas.count - 2)
            nextSelection = personas[nextIndex == index ? index + 1 : nextIndex].id
        }

        let heartbeatsToDelete = heartbeats.filter { $0.personaID == selectedPersonaID }
        for heartbeat in heartbeatsToDelete {
            modelContext.delete(heartbeat)
        }
        heartbeats.removeAll { $0.personaID == selectedPersonaID }
        modelContext.delete(personas[index])
        saveChanges()
        loadPersonas(selecting: nextSelection)
    }

    func updatePersonaName(id: Persona.ID, name: String) {
        guard let persona = personas.first(where: { $0.id == id }) else { return }

        persona.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        saveChanges()
        objectWillChange.send()
    }

    func updatePersonaSoul(id: Persona.ID, soul: String) {
        guard let persona = personas.first(where: { $0.id == id }) else { return }

        persona.soul = soul
        saveChanges()
        objectWillChange.send()
    }

    func updatePersonaMemory(id: Persona.ID, memory: String) {
        guard let persona = personas.first(where: { $0.id == id }) else { return }

        persona.memory = memory
        saveChanges()
        objectWillChange.send()
    }

    func updatePersonaVoiceTriggerPhrases(id: Persona.ID, phrasesText: String) {
        guard let persona = personas.first(where: { $0.id == id }) else { return }

        persona.voiceTriggerPhrase = phrasesText
        saveChanges()
        objectWillChange.send()
    }

    func updatePersonaTextToSpeechTool(id: Persona.ID, toolID: TextToSpeechTool.ID?) {
        guard let persona = personas.first(where: { $0.id == id }) else { return }

        persona.textToSpeechToolID = toolID
        saveChanges()
        objectWillChange.send()
    }

    func updatePersonaTextToSpeechVoiceName(id: Persona.ID, voiceName: String) {
        guard let persona = personas.first(where: { $0.id == id }) else { return }

        persona.textToSpeechVoiceName = voiceName
        saveChanges()
        objectWillChange.send()
    }

    func updatePersonaTextToSpeechVoiceModel(id: Persona.ID, voiceModel: String) {
        guard let persona = personas.first(where: { $0.id == id }) else { return }

        persona.textToSpeechVoiceModel = voiceModel
        saveChanges()
        objectWillChange.send()
    }

    func appendPersonaMemoryEntries(id: Persona.ID, entries: [String]) {
        guard let persona = personas.first(where: { $0.id == id }) else { return }

        let newEntries = entries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !newEntries.isEmpty else { return }

        let existingMemory = (persona.memory ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let appendedMemory = newEntries.joined(separator: "\n\n")
        persona.memory = existingMemory.isEmpty
            ? appendedMemory
            : "\(existingMemory)\n\n\(appendedMemory)"
        saveChanges()
        objectWillChange.send()
    }

    func updatePersonaModelIdentifier(id: Persona.ID, modelIdentifier: String) {
        guard let persona = personas.first(where: { $0.id == id }) else { return }

        persona.modelIdentifier = modelIdentifier
        saveChanges()
        objectWillChange.send()
    }

    func persona(for id: Persona.ID) -> Persona? {
        personas.first { $0.id == id }
    }

    func heartbeats(for personaID: Persona.ID) -> [PersonaHeartbeat] {
        heartbeats.filter { $0.personaID == personaID }
    }

    func addHeartbeat(to personaID: Persona.ID) {
        let heartbeat = PersonaHeartbeat(personaID: personaID)
        modelContext.insert(heartbeat)
        heartbeats.append(heartbeat)
        saveChanges()
        objectWillChange.send()
    }

    func removeHeartbeat(_ heartbeat: PersonaHeartbeat) {
        modelContext.delete(heartbeat)
        heartbeats.removeAll { $0.id == heartbeat.id }
        saveChanges()
        objectWillChange.send()
    }

    func updateHeartbeatInstruction(_ heartbeat: PersonaHeartbeat, instruction: String) {
        heartbeat.instruction = instruction
        heartbeat.lastError = nil
        saveChanges()
        objectWillChange.send()
    }

    func updateHeartbeatInterval(_ heartbeat: PersonaHeartbeat, minutes: Int) {
        heartbeat.intervalMinutes = min(max(minutes, 1), 10_080)
        if heartbeat.isEnabled {
            heartbeat.nextRunAt = Date().addingTimeInterval(TimeInterval(heartbeat.intervalMinutes * 60))
        }
        saveChanges()
        objectWillChange.send()
    }

    func updateHeartbeatEnabled(_ heartbeat: PersonaHeartbeat, isEnabled: Bool) {
        heartbeat.isEnabled = isEnabled
        heartbeat.nextRunAt = isEnabled
            ? Date().addingTimeInterval(TimeInterval(heartbeat.normalizedIntervalMinutes * 60))
            : nil
        heartbeat.lastError = nil
        saveChanges()
        objectWillChange.send()
    }

    func updateHeartbeatDestination(
        _ heartbeat: PersonaHeartbeat,
        targetKind: HeartbeatTargetKind,
        targetChatID: UUID?
    ) {
        heartbeat.targetKindRawValue = targetKind.rawValue
        heartbeat.targetChatID = targetKind == .groupChat ? targetChatID : nil
        heartbeat.lastError = nil
        saveChanges()
        objectWillChange.send()
    }

    func updateHeartbeatModelIdentifier(
        _ heartbeat: PersonaHeartbeat,
        modelIdentifier: String?
    ) {
        heartbeat.modelIdentifier = modelIdentifier
        heartbeat.lastError = nil
        saveChanges()
        objectWillChange.send()
    }

    func claimNextDueHeartbeat(at date: Date) -> PersonaHeartbeat? {
        let dueHeartbeats = heartbeats
            .filter { heartbeat in
                heartbeat.isEnabled && (heartbeat.nextRunAt ?? .distantFuture) <= date
            }
            .sorted { lhs, rhs in
                let lhsNextRunAt = lhs.nextRunAt ?? .distantFuture
                let rhsNextRunAt = rhs.nextRunAt ?? .distantFuture
                if lhsNextRunAt != rhsNextRunAt {
                    return lhsNextRunAt < rhsNextRunAt
                }

                let lhsLastRunAt = lhs.lastRunAt ?? .distantPast
                let rhsLastRunAt = rhs.lastRunAt ?? .distantPast
                if lhsLastRunAt != rhsLastRunAt {
                    return lhsLastRunAt < rhsLastRunAt
                }

                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }

        guard let claimedHeartbeat = dueHeartbeats.first else { return nil }

        claimedHeartbeat.lastRunAt = date
        claimedHeartbeat.nextRunAt = date.addingTimeInterval(
            TimeInterval(claimedHeartbeat.normalizedIntervalMinutes * 60)
        )
        claimedHeartbeat.lastError = nil

        for heartbeat in dueHeartbeats.dropFirst() {
            deferHeartbeatByInterval(heartbeat, from: date)
        }
        saveChanges()
        objectWillChange.send()
        return claimedHeartbeat
    }

    func deferDueHeartbeatsForOverlap(at date: Date) {
        let dueHeartbeats = heartbeats.filter { heartbeat in
            heartbeat.isEnabled && (heartbeat.nextRunAt ?? .distantFuture) <= date
        }
        guard !dueHeartbeats.isEmpty else { return }

        for heartbeat in dueHeartbeats {
            deferHeartbeatByInterval(heartbeat, from: date)
        }
        saveChanges()
        objectWillChange.send()
    }

    func deferHeartbeatForOverlap(id: PersonaHeartbeat.ID, at date: Date) {
        guard let heartbeat = heartbeats.first(where: { $0.id == id }), heartbeat.isEnabled else {
            return
        }

        deferHeartbeatByInterval(heartbeat, from: date)
        saveChanges()
        objectWillChange.send()
    }

    func skipHeartbeat(id: PersonaHeartbeat.ID, at date: Date) {
        guard let heartbeat = heartbeats.first(where: { $0.id == id }), heartbeat.isEnabled else {
            return
        }

        let scheduledDate = max(heartbeat.nextRunAt ?? date, date)
        heartbeat.nextRunAt = scheduledDate.addingTimeInterval(
            TimeInterval(heartbeat.normalizedIntervalMinutes * 60)
        )
        heartbeat.lastError = nil
        saveChanges()
        objectWillChange.send()
    }

    func claimHeartbeatForImmediateRun(
        id: PersonaHeartbeat.ID,
        at date: Date
    ) -> PersonaHeartbeat? {
        guard let heartbeat = heartbeats.first(where: { $0.id == id }), heartbeat.isEnabled else {
            return nil
        }

        heartbeat.lastRunAt = date
        heartbeat.nextRunAt = date.addingTimeInterval(
            TimeInterval(heartbeat.normalizedIntervalMinutes * 60)
        )
        heartbeat.lastError = nil
        saveChanges()
        objectWillChange.send()
        return heartbeat
    }

    func rescheduleHeartbeatAfterTimeout(id: PersonaHeartbeat.ID, at date: Date) {
        guard let heartbeat = heartbeats.first(where: { $0.id == id }), heartbeat.isEnabled else {
            return
        }

        heartbeat.nextRunAt = date.addingTimeInterval(
            TimeInterval(heartbeat.normalizedIntervalMinutes * 60)
        )
        saveChanges()
        objectWillChange.send()
    }

    func recordHeartbeatCompletion(
        heartbeatID: PersonaHeartbeat.ID,
        personaID: Persona.ID,
        report: HeartbeatExecutionReport
    ) {
        if let heartbeat = heartbeats.first(where: { $0.id == heartbeatID }) {
            heartbeat.lastCompletedAt = report.completedAt
            heartbeat.lastError = report.errorMessage
            if heartbeat.isEnabled, let retryDelay = report.retryDelay {
                heartbeat.nextRunAt = report.completedAt.addingTimeInterval(retryDelay)
            }
        }

        let run = HeartbeatRun(
            heartbeatID: heartbeatID,
            personaID: personaID,
            personaName: report.personaName,
            instruction: report.instruction,
            destination: report.destination,
            startedAt: report.startedAt,
            completedAt: report.completedAt,
            modelInput: report.modelInput,
            modelOutput: report.modelOutput,
            actionSummary: report.actionSummary,
            errorMessage: report.errorMessage
        )
        modelContext.insert(run)
        heartbeatRuns.insert(run, at: 0)
        saveChanges()
        objectWillChange.send()
    }

    private func deferHeartbeatByInterval(_ heartbeat: PersonaHeartbeat, from date: Date) {
        heartbeat.nextRunAt = date.addingTimeInterval(
            TimeInterval(heartbeat.normalizedIntervalMinutes * 60)
        )
    }

    private func loadPersonas(selecting selection: Persona.ID? = nil) {
        let descriptor = FetchDescriptor<Persona>(
            sortBy: [SortDescriptor(\.createdAt)]
        )

        do {
            personas = try modelContext.fetch(descriptor)
        } catch {
            personas = []
        }

        if personas.isEmpty {
            let persona = Persona(name: "Default", soul: "You are a concise, very quirky and goofy assistant inside a simple chat app.")
            modelContext.insert(persona)
            saveChanges()
            personas = [persona]
        }

        selectedPersonaID = selection.flatMap { selectedID in
            personas.contains { $0.id == selectedID } ? selectedID : nil
        } ?? selectedPersonaID.flatMap { selectedID in
            personas.contains { $0.id == selectedID } ? selectedID : nil
        } ?? personas.first?.id
    }

    private func loadHeartbeats() {
        let descriptor = FetchDescriptor<PersonaHeartbeat>(
            sortBy: [SortDescriptor(\.createdAt)]
        )

        do {
            heartbeats = try modelContext.fetch(descriptor)
        } catch {
            heartbeats = []
        }

        let now = Date()
        for heartbeat in heartbeats where heartbeat.isEnabled && heartbeat.nextRunAt == nil {
            heartbeat.nextRunAt = now.addingTimeInterval(
                TimeInterval(heartbeat.normalizedIntervalMinutes * 60)
            )
        }
        saveChanges()
    }

    private func loadHeartbeatRuns() {
        let descriptor = FetchDescriptor<HeartbeatRun>(
            sortBy: [SortDescriptor(\.completedAt, order: .reverse)]
        )

        do {
            heartbeatRuns = try modelContext.fetch(descriptor)
        } catch {
            heartbeatRuns = []
        }

        for heartbeat in heartbeats where heartbeat.lastCompletedAt == nil {
            heartbeat.lastCompletedAt = heartbeatRuns.first {
                $0.heartbeatID == heartbeat.id
            }?.completedAt
        }
        saveChanges()
    }

    private func saveChanges() {
        guard modelContext.hasChanges else { return }

        do {
            try modelContext.save()
        } catch {
            assertionFailure("Failed to save personas: \(error.localizedDescription)")
        }
    }
}

@Model
final class Persona: Identifiable {
    @Attribute(.unique) var id: UUID
    var name: String
    var soul: String
    var memory: String?
    var modelIdentifier: String?
    var voiceTriggerPhrase: String?
    var textToSpeechToolID: UUID?
    var textToSpeechVoiceName: String?
    var textToSpeechVoiceModel: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        soul: String,
        memory: String? = nil,
        modelIdentifier: String? = nil,
        voiceTriggerPhrase: String? = nil,
        textToSpeechToolID: UUID? = nil,
        textToSpeechVoiceName: String? = nil,
        textToSpeechVoiceModel: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.soul = soul
        self.memory = memory
        self.modelIdentifier = modelIdentifier
        self.voiceTriggerPhrase = voiceTriggerPhrase
        self.textToSpeechToolID = textToSpeechToolID
        self.textToSpeechVoiceName = textToSpeechVoiceName
        self.textToSpeechVoiceModel = textToSpeechVoiceModel
        self.createdAt = createdAt
    }

    var displayName: String {
        name.isEmpty ? "Untitled Persona" : name
    }

    var selectedModelIdentifier: String {
        modelIdentifier ?? ChatModelIdentifier.appleFoundation
    }

    var memoryText: String {
        memory ?? ""
    }

    var voiceTriggerPhrases: [String] {
        var normalizedPhrases = Set<String>()
        return (voiceTriggerPhrase ?? "")
            .split(whereSeparator: { $0.isNewline })
            .compactMap { line in
                let phrase = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !phrase.isEmpty else { return nil }
                let normalizedPhrase = phrase.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                )
                .lowercased(with: .current)
                guard normalizedPhrases.insert(normalizedPhrase).inserted else { return nil }
                return phrase
            }
    }
}

@Model
final class StoredChat: Identifiable {
    @Attribute(.unique) var id: UUID
    var personaID: UUID
    var personaName: String
    var personaSoul: String
    var personaModelIdentifier: String?
    var kindRawValue: String?
    var groupSystemInstructions: String?
    var title: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        personaID: UUID,
        personaName: String,
        personaSoul: String,
        personaModelIdentifier: String? = nil,
        kind: ChatKind = .direct,
        groupSystemInstructions: String? = nil,
        title: String = "New chat",
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.personaID = personaID
        self.personaName = personaName
        self.personaSoul = personaSoul
        self.personaModelIdentifier = personaModelIdentifier
        kindRawValue = kind.rawValue
        self.groupSystemInstructions = groupSystemInstructions
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var kind: ChatKind {
        ChatKind(rawValue: kindRawValue ?? "") ?? .direct
    }
}

@Model
final class StoredChatMessage: Identifiable {
    @Attribute(.unique) var id: UUID
    var chatID: UUID
    var roleRawValue: String
    var text: String
    var authorPersonaID: UUID?
    var authorName: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        chatID: UUID,
        role: ChatRole,
        text: String,
        authorPersonaID: UUID? = nil,
        authorName: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.chatID = chatID
        self.roleRawValue = role.rawValue
        self.text = text
        self.authorPersonaID = authorPersonaID
        self.authorName = authorName
        self.createdAt = createdAt
    }

    var role: ChatRole {
        ChatRole(rawValue: roleRawValue) ?? .assistant
    }
}

@MainActor
final class ChatStore: ObservableObject {
    private static let messageBatchSize = 40

    @Published var chats: [ChatViewModel] = []
    @Published var selectedChatID: ChatViewModel.ID?

    private let modelContext: ModelContext
    private let personaStore: PersonaStore
    private let localModelStore: LocalModelStore

    var selectedChat: ChatViewModel? {
        guard let selectedChatID else { return nil }
        return chats.first { $0.id == selectedChatID }
    }

    init(personaStore: PersonaStore, localModelStore: LocalModelStore, modelContext: ModelContext) {
        self.modelContext = modelContext
        self.personaStore = personaStore
        self.localModelStore = localModelStore
        loadChats()

        if chats.isEmpty, let persona = personaStore.personas.first {
            startChat(with: persona)
        } else {
            selectedChatID = chats.first?.id
        }
    }

    func startChat(with persona: Persona) {
        let chat = makeDirectChat(with: persona)
        selectedChatID = chat.id
    }

    private func makeDirectChat(with persona: Persona) -> ChatViewModel {
        let storedChat = StoredChat(
            personaID: persona.id,
            personaName: persona.displayName,
            personaSoul: persona.soul,
            personaModelIdentifier: persona.selectedModelIdentifier
        )
        modelContext.insert(storedChat)

        let greeting = StoredChatMessage(
            chatID: storedChat.id,
            role: .assistant,
            text: "New chat with \(persona.displayName). What would you like to ask?",
            authorPersonaID: persona.id,
            authorName: persona.displayName
        )
        modelContext.insert(greeting)
        saveChanges()

        let chat = ChatViewModel(
            storedChat: storedChat,
            storedMessages: [greeting],
            storedGroupParticipants: [],
            personaStore: personaStore,
            localModelStore: localModelStore,
            modelContext: modelContext
        )
        chats.insert(chat, at: 0)
        return chat
    }

    func startGroupChat() {
        let storedChat = StoredChat(
            personaID: UUID(),
            personaName: "Group chat",
            personaSoul: "",
            kind: .group,
            groupSystemInstructions: "",
            title: "Untitled chat"
        )
        modelContext.insert(storedChat)
        saveChanges()

        let chat = ChatViewModel(
            storedChat: storedChat,
            storedMessages: [],
            storedGroupParticipants: [],
            personaStore: personaStore,
            localModelStore: localModelStore,
            modelContext: modelContext
        )
        chats.insert(chat, at: 0)
        selectedChatID = chat.id
    }

    func chats(for personaID: Persona.ID) -> [ChatViewModel] {
        chats.filter { !$0.isGroupChat && $0.personaID == personaID }
    }

    var groupChats: [ChatViewModel] {
        chats.filter(\.isGroupChat)
    }

    func addFakeMessagesToSelectedChat(count: Int) {
        selectedChat?.addFakeMessages(count: count)
    }

    func addSlowResponseToSelectedChat() {
        selectedChat?.addSlowResponse()
    }

    func executeHeartbeat(
        _ heartbeat: PersonaHeartbeat,
        onModelInput: ((String) -> Void)? = nil,
        onModelResponseAccepted: (() -> Void)? = nil
    ) async -> HeartbeatExecutionReport {
        let startedAt = Date()
        let fallbackPersonaName = "Deleted persona"
        let instruction = heartbeat.instruction.trimmingCharacters(in: .whitespacesAndNewlines)

        if Task.isCancelled {
            return failedHeartbeatReport(
                personaName: personaStore.persona(for: heartbeat.personaID)?.displayName ?? fallbackPersonaName,
                instruction: instruction,
                destination: heartbeatDestinationDescription(for: heartbeat),
                startedAt: startedAt,
                error: HeartbeatModelFailure(
                    modelInput: "",
                    modelOutput: nil,
                    message: "Aborted by user.",
                    wasAborted: true
                )
            )
        }

        guard let persona = personaStore.persona(for: heartbeat.personaID) else {
            return failedHeartbeatReport(
                personaName: fallbackPersonaName,
                instruction: instruction,
                destination: heartbeatDestinationDescription(for: heartbeat),
                startedAt: startedAt,
                error: HeartbeatExecutionError.personaMissing
            )
        }

        guard !instruction.isEmpty else {
            return failedHeartbeatReport(
                personaName: persona.displayName,
                instruction: instruction,
                destination: heartbeatDestinationDescription(for: heartbeat),
                startedAt: startedAt,
                error: HeartbeatExecutionError.emptyInstruction
            )
        }

        let targetChat: ChatViewModel
        switch heartbeat.targetKind {
        case .privateChat:
            targetChat = chats
                .filter { !$0.isGroupChat && $0.personaID == persona.id }
                .max { $0.updatedAt < $1.updatedAt }
                ?? makeDirectChat(with: persona)
        case .groupChat:
            guard let targetChatID = heartbeat.targetChatID,
                  let groupChat = chats.first(where: { $0.id == targetChatID && $0.isGroupChat }) else {
                return failedHeartbeatReport(
                    personaName: persona.displayName,
                    instruction: instruction,
                    destination: heartbeatDestinationDescription(for: heartbeat),
                    startedAt: startedAt,
                    error: HeartbeatExecutionError.targetMissing
                )
            }
            targetChat = groupChat
        }

        let destination = targetChat.heartbeatDestinationDescription
        let modelIdentifier = heartbeat.modelIdentifier ?? persona.selectedModelIdentifier
        do {
            let exchange = try await targetChat.executeHeartbeat(
                as: persona,
                instruction: instruction,
                modelIdentifier: modelIdentifier,
                lastCompletedAt: heartbeat.lastCompletedAt,
                referenceDate: startedAt,
                onModelInput: onModelInput,
                onModelResponseAccepted: onModelResponseAccepted
            )
            return HeartbeatExecutionReport(
                personaName: persona.displayName,
                instruction: instruction,
                destination: destination,
                startedAt: startedAt,
                completedAt: .now,
                modelInput: exchange.modelInput,
                modelOutput: exchange.modelOutput,
                actionSummary: exchange.actionSummary,
                errorMessage: nil,
                retryDelay: nil
            )
        } catch let error as HeartbeatModelFailure {
            return failedHeartbeatReport(
                personaName: persona.displayName,
                instruction: instruction,
                destination: destination,
                startedAt: startedAt,
                modelInput: error.modelInput,
                modelOutput: error.modelOutput,
                error: error
            )
        } catch {
            return failedHeartbeatReport(
                personaName: persona.displayName,
                instruction: instruction,
                destination: destination,
                startedAt: startedAt,
                error: error
            )
        }
    }

    func heartbeatDestinationDescription(for heartbeat: PersonaHeartbeat) -> String {
        switch heartbeat.targetKind {
        case .privateChat:
            guard let chat = chats
                .filter({ !$0.isGroupChat && $0.personaID == heartbeat.personaID })
                .max(by: { $0.updatedAt < $1.updatedAt }) else {
                return "New private chat"
            }
            return chat.heartbeatDestinationDescription
        case .groupChat:
            guard let targetChatID = heartbeat.targetChatID,
                  let chat = chats.first(where: { $0.id == targetChatID && $0.isGroupChat }) else {
                return "Missing group chat"
            }
            return chat.heartbeatDestinationDescription
        }
    }

    private func failedHeartbeatReport(
        personaName: String,
        instruction: String,
        destination: String,
        startedAt: Date,
        modelInput: String = "",
        modelOutput: String? = nil,
        error: Error
    ) -> HeartbeatExecutionReport {
        let wasAborted = (error as? HeartbeatModelFailure)?.wasAborted == true
        let retryDelay = (error as? HeartbeatExecutionError)?.retryDelay
        let actionSummary: String
        if wasAborted {
            actionSummary = "Run was aborted. No chat message was posted."
        } else if retryDelay != nil {
            actionSummary = "No chat message was posted. Scheduled a retry in 1 minute."
        } else {
            actionSummary = "No chat message was posted."
        }

        return HeartbeatExecutionReport(
            personaName: personaName,
            instruction: instruction,
            destination: destination,
            startedAt: startedAt,
            completedAt: Date(),
            modelInput: modelInput,
            modelOutput: modelOutput,
            actionSummary: actionSummary,
            errorMessage: wasAborted ? "Aborted by user." : error.localizedDescription,
            retryDelay: retryDelay
        )
    }

    private func loadChats() {
        let descriptor = FetchDescriptor<StoredChat>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )

        do {
            let storedChats = try modelContext.fetch(descriptor)
            chats = storedChats.map { storedChat in
                ChatViewModel(
                    storedChat: storedChat,
                    storedMessages: fetchMessages(for: storedChat.id),
                    storedGroupParticipants: fetchGroupParticipants(for: storedChat.id),
                    personaStore: personaStore,
                    localModelStore: localModelStore,
                    modelContext: modelContext
                )
            }
        } catch {
            chats = []
        }
    }

    private func fetchGroupParticipants(for chatID: UUID) -> [StoredGroupChatParticipant] {
        let descriptor = FetchDescriptor<StoredGroupChatParticipant>(
            predicate: #Predicate { participant in
                participant.chatID == chatID
            },
            sortBy: [SortDescriptor(\.createdAt)]
        )

        do {
            return try modelContext.fetch(descriptor)
        } catch {
            return []
        }
    }

    private func fetchMessages(for chatID: UUID) -> [StoredChatMessage] {
        var descriptor = FetchDescriptor<StoredChatMessage>(
            predicate: #Predicate { message in
                message.chatID == chatID
            },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = ChatStore.messageBatchSize

        do {
            return try modelContext.fetch(descriptor).reversed()
        } catch {
            return []
        }
    }

    private func saveChanges() {
        guard modelContext.hasChanges else { return }

        do {
            try modelContext.save()
        } catch {
            assertionFailure("Failed to save chats: \(error.localizedDescription)")
        }
    }
}

@MainActor
final class ChatViewModel: ObservableObject, Identifiable {
    static let typingIndicatorID = UUID()
    private static let messageBatchSize = 40

    var id: UUID { storedChat.id }
    var personaID: Persona.ID { storedChat.personaID }
    var personaName: String { storedChat.personaName }
    var isGroupChat: Bool { storedChat.kind == .group }
    var updatedAt: Date { storedChat.updatedAt }
    var heartbeatDestinationDescription: String {
        "\(isGroupChat ? "Group chat" : "Private chat") “\(title)”"
    }

    @Published var draft = ""
    @Published private(set) var title: String
    @Published private(set) var messages: [ChatMessage]
    @Published private(set) var groupParticipants: [StoredGroupChatParticipant]
    @Published private(set) var groupSystemInstructions: String
    @Published private(set) var isLoadingOlderMessages = false
    @Published private(set) var hasOlderMessages: Bool
    @Published private(set) var isResponding = false
    @Published private(set) var respondingPersonaName: String?
    @Published private(set) var availabilityMessage = ""
    @Published private(set) var canSend = false

    private let model = SystemLanguageModel.default
    private let modelContext: ModelContext
    private let storedChat: StoredChat
    private let personaStore: PersonaStore
    private let localModelStore: LocalModelStore
    private let backend: ChatBackend

    var canSubmitDraft: Bool {
        canSend && !isResponding && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(
        storedChat: StoredChat,
        storedMessages: [StoredChatMessage],
        storedGroupParticipants: [StoredGroupChatParticipant],
        personaStore: PersonaStore,
        localModelStore: LocalModelStore,
        modelContext: ModelContext
    ) {
        self.storedChat = storedChat
        self.personaStore = personaStore
        self.localModelStore = localModelStore
        self.modelContext = modelContext
        title = storedChat.title
        let fallbackAssistantName = storedChat.kind == .direct ? storedChat.personaName : nil
        messages = storedMessages.map {
            ChatMessage(storedMessage: $0, fallbackAssistantName: fallbackAssistantName)
        }
        groupParticipants = storedGroupParticipants
        groupSystemInstructions = storedChat.groupSystemInstructions ?? ""
        respondingPersonaName = nil
        hasOlderMessages = storedMessages.count == ChatViewModel.messageBatchSize
        backend = localModelStore.backend(for: storedChat.personaModelIdentifier)
        updateAvailability()
    }

    var groupParticipantMentions: [String] {
        groupParticipants.map(\.mention)
    }

    var availablePersonaMentions: [String] {
        var mentions = groupParticipantMentions
        mentions.append(contentsOf: personaStore.personas.map(\.mention))
        return Array(Set(mentions)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    var composerPlaceholder: String {
        guard isGroupChat, groupParticipants.isEmpty else { return "Message" }
        guard let firstMention = availablePersonaMentions.first else {
            return "Message"
        }
        return "Message \(firstMention) to add them"
    }

    func loadOlderMessages() {
        guard hasOlderMessages,
              !isLoadingOlderMessages,
              let oldestMessage = messages.first else {
            return
        }

        isLoadingOlderMessages = true
        defer { isLoadingOlderMessages = false }

        let oldestMessageDate = oldestMessage.createdAt
        var descriptor = FetchDescriptor<StoredChatMessage>(
            predicate: #Predicate { message in
                message.chatID == id && message.createdAt < oldestMessageDate
            },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = ChatViewModel.messageBatchSize

        do {
            let fallbackAssistantName = isGroupChat ? nil : storedChat.personaName
            let olderMessages = try modelContext.fetch(descriptor).reversed().map {
                ChatMessage(storedMessage: $0, fallbackAssistantName: fallbackAssistantName)
            }
            hasOlderMessages = olderMessages.count == ChatViewModel.messageBatchSize
            messages.insert(contentsOf: olderMessages, at: 0)
        } catch {
            hasOlderMessages = false
        }
    }

    func rename(to title: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = isGroupChat ? "Untitled chat" : "New chat"
        updateTitle(trimmedTitle.isEmpty ? fallbackTitle : trimmedTitle)
    }

    func updateGroupSystemInstructions(_ instructions: String) {
        guard isGroupChat else { return }
        groupSystemInstructions = instructions
        storedChat.groupSystemInstructions = instructions
        storedChat.updatedAt = .now
        saveChanges()
    }

    func addFakeMessages(count: Int) {
        guard count > 0 else { return }

        let startingIndex = messages.count + 1
        let storedMessages = (0..<count).map { offset in
            let messageNumber = startingIndex + offset
            let role: ChatRole = messageNumber.isMultiple(of: 2) ? .assistant : .user
            return StoredChatMessage(
                chatID: id,
                role: role,
                text: "Fake message \(messageNumber)",
                authorPersonaID: role == .assistant ? groupParticipants.first?.personaID ?? personaID : nil,
                authorName: role == .assistant ? groupParticipants.first?.personaName ?? personaName : nil,
                createdAt: Date().addingTimeInterval(TimeInterval(offset) * 0.001)
            )
        }

        for storedMessage in storedMessages {
            modelContext.insert(storedMessage)
        }

        storedChat.updatedAt = .now
        saveChanges()
        messages.append(contentsOf: storedMessages.map {
            ChatMessage(storedMessage: $0, fallbackAssistantName: isGroupChat ? nil : personaName)
        })
    }

    func addSlowResponse() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            let participant = groupParticipants.first
            appendMessage(
                role: .assistant,
                text: "Slow response",
                authorPersonaID: participant?.personaID ?? (isGroupChat ? nil : personaID),
                authorName: participant?.personaName ?? (isGroupChat ? nil : personaName)
            )
        }
    }

    func send() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)

        guard canSubmitDraft, !prompt.isEmpty else { return }

        if isGroupChat {
            let mentionedHandles = PersonaMention.handles(in: prompt)
            addMentionedPersonas(matching: mentionedHandles)

            guard !groupParticipants.isEmpty else {
                availabilityMessage = availablePersonaMentions.isEmpty
                    ? "Create a persona before starting this group discussion."
                    : "Mention a persona, such as \(availablePersonaMentions[0]), to add them."
                return
            }

            let directlyMentionedPersonaIDs = Set(
                groupParticipants
                    .filter { mentionedHandles.contains(PersonaMention.handle(for: $0.personaName).lowercased()) }
                    .map(\.personaID)
            )

            if title == "Untitled chat" {
                updateTitle(String(prompt.prefix(48)))
            }

            draft = ""
            appendMessage(role: .user, text: prompt)
            isResponding = true

            Task {
                await respondAsGroup(directlyMentionedPersonaIDs: directlyMentionedPersonaIDs)
            }
            return
        }

        if title == "New chat" {
            updateTitle(String(prompt.prefix(48)))
        }

        draft = ""
        appendMessage(role: .user, text: prompt)
        isResponding = true

        Task {
            await respond()
        }
    }

    func executeHeartbeat(
        as persona: Persona,
        instruction: String,
        modelIdentifier: String,
        lastCompletedAt: Date?,
        referenceDate: Date,
        onModelInput: ((String) -> Void)? = nil,
        onModelResponseAccepted: (() -> Void)? = nil
    ) async throws -> HeartbeatModelExchange {
        if Task.isCancelled {
            throw HeartbeatModelFailure(
                modelInput: "",
                modelOutput: nil,
                message: "Aborted by user.",
                wasAborted: true
            )
        }

        guard !isResponding else {
            throw HeartbeatExecutionError.chatBusy
        }

        if isGroupChat {
            addGroupParticipantIfNeeded(persona)
        }

        isResponding = true
        respondingPersonaName = persona.displayName
        defer {
            respondingPersonaName = nil
            isResponding = false
            updateAvailability()
        }

        let systemInstructions = heartbeatSystemInstructions(for: persona)
        let conversationPrompt = heartbeatConversationPrompt(
            personaName: persona.displayName,
            instruction: instruction,
            lastCompletedAt: lastCompletedAt,
            referenceDate: referenceDate
        )
        let modelInput = """
        SYSTEM
        \(systemInstructions)

        USER
        \(conversationPrompt)
        """
        onModelInput?(modelInput)

        let response: String
        do {
            switch localModelStore.backend(for: modelIdentifier) {
            case .appleFoundation:
                let session = LanguageModelSession(instructions: systemInstructions)
                response = try await session.respond(to: conversationPrompt).content
            case .openAICompatible(let configuration):
                response = try await OpenAICompatibleClient(configuration: configuration).respond(
                    systemPrompt: systemInstructions,
                    prompt: conversationPrompt
                )
            case .missingLocalModel:
                throw OpenAICompatibleError.server(
                    statusCode: 0,
                    message: "The selected local model is no longer configured."
                )
            }
            try Task.checkCancellation()
        } catch {
            let wasAborted = Task.isCancelled || error is CancellationError
            throw HeartbeatModelFailure(
                modelInput: modelInput,
                modelOutput: nil,
                message: wasAborted ? "Aborted by user." : error.localizedDescription,
                wasAborted: wasAborted
            )
        }
        onModelResponseAccepted?()

        let parsedResponse = PersonaMemoryHarness.parse(response)
        personaStore.appendPersonaMemoryEntries(
            id: persona.id,
            entries: parsedResponse.memoryEntries
        )

        let visibleText = parsedResponse.visibleText
        let passed = ChatViewModel.isPassResponse(visibleText)
        let posted = !visibleText.isEmpty && !passed
        if posted {
            appendMessage(
                role: .assistant,
                text: visibleText,
                authorPersonaID: persona.id,
                authorName: persona.displayName
            )
        }

        var actions: [String] = []
        if posted {
            actions.append("Posted to \(heartbeatDestinationDescription).")
        } else if passed {
            actions.append("The model passed, so no chat message was posted.")
        } else {
            actions.append("The model returned no visible text, so no chat message was posted.")
        }

        let memoryCount = parsedResponse.memoryEntries.count
        if memoryCount > 0 {
            actions.append("Appended \(memoryCount) memory \(memoryCount == 1 ? "entry" : "entries").")
        }

        return HeartbeatModelExchange(
            modelInput: modelInput,
            modelOutput: response,
            actionSummary: actions.joined(separator: " ")
        )
    }

    private func respond() async {
        do {
            let systemInstructions = ChatViewModel.personaSystemInstructions(
                personaName: storedChat.personaName,
                soul: currentSoul(
                    for: storedChat.personaID,
                    fallback: storedChat.personaSoul
                ),
                memory: currentMemory(for: storedChat.personaID)
            )
            let response: String
            switch backend {
            case .appleFoundation:
                let session = LanguageModelSession(instructions: systemInstructions)
                response = try await session.respond(to: directConversationPrompt()).content
            case .openAICompatible(let configuration):
                response = try await OpenAICompatibleClient(configuration: configuration).respond(
                    systemPrompt: systemInstructions,
                    messages: allStoredMessages().map {
                        ChatMessage(storedMessage: $0, fallbackAssistantName: storedChat.personaName)
                    }
                )
            case .missingLocalModel:
                throw OpenAICompatibleError.server(
                    statusCode: 0,
                    message: "This chat's local model is no longer configured. Choose a configured model for the persona and start a new chat."
                )
            }
            let parsedResponse = PersonaMemoryHarness.parse(response)
            personaStore.appendPersonaMemoryEntries(
                id: storedChat.personaID,
                entries: parsedResponse.memoryEntries
            )
            if !parsedResponse.visibleText.isEmpty {
                appendMessage(
                    role: .assistant,
                    text: parsedResponse.visibleText,
                    authorPersonaID: personaID,
                    authorName: personaName
                )
            }
        } catch {
            appendMessage(
                role: .assistant,
                text: "I could not get a response: \(error.localizedDescription)",
                authorPersonaID: personaID,
                authorName: personaName
            )
        }

        isResponding = false
        updateAvailability()
    }

    private func addMentionedPersonas(matching mentionedHandles: Set<String>) {
        let existingPersonaIDs = Set(groupParticipants.map(\.personaID))
        let newPersonas = personaStore.personas.filter { persona in
            !existingPersonaIDs.contains(persona.id)
                && mentionedHandles.contains(PersonaMention.handle(for: persona.displayName).lowercased())
        }

        guard !newPersonas.isEmpty else { return }

        for persona in newPersonas {
            let participant = StoredGroupChatParticipant(chatID: id, persona: persona)
            modelContext.insert(participant)
            groupParticipants.append(participant)
        }

        storedChat.updatedAt = .now
        saveChanges()
        updateAvailability()
    }

    private func addGroupParticipantIfNeeded(_ persona: Persona) {
        guard isGroupChat,
              !groupParticipants.contains(where: { $0.personaID == persona.id }) else {
            return
        }

        let participant = StoredGroupChatParticipant(chatID: id, persona: persona)
        modelContext.insert(participant)
        groupParticipants.append(participant)
        storedChat.updatedAt = .now
        saveChanges()
        updateAvailability()
    }

    private func respondAsGroup(directlyMentionedPersonaIDs: Set<UUID>) async {
        let orderedParticipants = groupParticipants.sorted { left, right in
            let leftWasMentioned = directlyMentionedPersonaIDs.contains(left.personaID)
            let rightWasMentioned = directlyMentionedPersonaIDs.contains(right.personaID)
            if leftWasMentioned != rightWasMentioned {
                return leftWasMentioned
            }
            return left.createdAt < right.createdAt
        }

        for participant in orderedParticipants {
            guard !Task.isCancelled else { break }
            respondingPersonaName = participant.personaName

            do {
                let response = try await groupResponse(
                    from: participant,
                    wasDirectlyMentioned: directlyMentionedPersonaIDs.contains(participant.personaID)
                )
                let parsedResponse = PersonaMemoryHarness.parse(response)
                personaStore.appendPersonaMemoryEntries(
                    id: participant.personaID,
                    entries: parsedResponse.memoryEntries
                )
                let trimmedResponse = parsedResponse.visibleText
                if !trimmedResponse.isEmpty, !ChatViewModel.isPassResponse(trimmedResponse) {
                    appendMessage(
                        role: .assistant,
                        text: trimmedResponse,
                        authorPersonaID: participant.personaID,
                        authorName: participant.personaName
                    )
                }
            } catch {
                appendMessage(
                    role: .assistant,
                    text: "I could not get a response: \(error.localizedDescription)",
                    authorPersonaID: participant.personaID,
                    authorName: participant.personaName
                )
            }
        }

        respondingPersonaName = nil
        isResponding = false
        updateAvailability()
    }

    private func groupResponse(
        from participant: StoredGroupChatParticipant,
        wasDirectlyMentioned: Bool
    ) async throws -> String {
        let systemInstructions = groupSystemPrompt(for: participant)
        let conversationPrompt = groupConversationPrompt(
            for: participant,
            wasDirectlyMentioned: wasDirectlyMentioned
        )

        switch localModelStore.backend(for: participant.personaModelIdentifier) {
        case .appleFoundation:
            let session = LanguageModelSession(instructions: systemInstructions)
            return try await session.respond(to: conversationPrompt).content
        case .openAICompatible(let configuration):
            return try await OpenAICompatibleClient(configuration: configuration).respond(
                systemPrompt: systemInstructions,
                prompt: conversationPrompt
            )
        case .missingLocalModel:
            throw OpenAICompatibleError.server(
                statusCode: 0,
                message: "This persona's local model is no longer configured."
            )
        }
    }

    private func groupSystemPrompt(for participant: StoredGroupChatParticipant) -> String {
        let individualInstructions = ChatViewModel.instructions(
            for: currentSoul(
                for: participant.personaID,
                fallback: participant.personaSoul
            )
        )
        let memoryInstructions = PersonaMemoryHarness.instructionSection(
            memory: currentMemory(for: participant.personaID)
        )
        let trimmedGroupInstructions = groupSystemInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let groupInstructions = trimmedGroupInstructions.isEmpty
            ? "Let the discussion develop naturally. Be concise and avoid repeating points already made."
            : trimmedGroupInstructions

        return """
        You are \(participant.personaName), a participant in an open group discussion.

        Individual persona instructions:
        \(individualInstructions)

        \(memoryInstructions)

        Group chat system instructions:
        \(groupInstructions)

        Discussion behavior:
        - You see the complete conversation between the user and every persona in the group.
        - Messages labeled with another persona's name were written by that persona, not by you.
        - You may respond to the user or to another persona when it adds something natural to the discussion.
        - A direct @mention gives that comment extra emphasis, but it does not prevent other personas from replying.
        - Do not prefix your reply with your name; the interface adds it for you.
        - If you have nothing useful to add, reply with exactly [[PASS]].
        """
    }

    private func groupConversationPrompt(
        for participant: StoredGroupChatParticipant,
        wasDirectlyMentioned: Bool
    ) -> String {
        let transcript = allStoredMessages().map { message in
            let speaker = message.role == .user ? "User" : message.authorName ?? "Persona"
            return "\(speaker): \(message.text)"
        }.joined(separator: "\n\n")

        let emphasis = wasDirectlyMentioned
            ? "The latest user message directly mentions you. Treat it with extra emphasis and usually respond."
            : "The latest user message does not directly mention you. You may still respond if it feels natural and useful."

        return """
        Here is the complete group conversation so far:

        \(transcript)

        \(emphasis)
        Continue the discussion as \(participant.personaName), or return [[PASS]] if you would only repeat what has already been said.
        """
    }

    private func directConversationPrompt() -> String {
        """
        Here is the complete private conversation so far:

        \(storedConversationTranscript())

        Reply to the latest user message as \(storedChat.personaName).
        """
    }

    private func heartbeatSystemInstructions(for persona: Persona) -> String {
        let personaInstructions = ChatViewModel.personaSystemInstructions(
            personaName: persona.displayName,
            soul: persona.soul,
            memory: persona.memoryText
        )

        guard isGroupChat else {
            return """
            \(personaInstructions)

            You are running a scheduled heartbeat for your private chat.
            Follow the heartbeat instruction using the conversation as context.
            If there is nothing worth posting, reply with exactly [[PASS]].
            You may still append memory even when you pass.
            """
        }

        let trimmedGroupInstructions = groupSystemInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let groupInstructions = trimmedGroupInstructions.isEmpty
            ? "Let the discussion develop naturally. Be concise and avoid repeating points already made."
            : trimmedGroupInstructions

        return """
        \(personaInstructions)

        Group chat system instructions:
        \(groupInstructions)

        You are running a scheduled heartbeat for this group discussion.
        You see the complete conversation between the user and every persona in the group.
        Messages labeled with another persona's name were written by that persona, not by you.
        Follow the heartbeat instruction and post only when it adds something natural or useful.
        Do not prefix your reply with your name; the interface adds it for you.
        If there is nothing worth posting, reply with exactly [[PASS]].
        You may still append memory even when you pass.
        """
    }

    private func heartbeatConversationPrompt(
        personaName: String,
        instruction: String,
        lastCompletedAt: Date?,
        referenceDate: Date
    ) -> String {
        let messages = allStoredMessages()
        let unansweredMessageCount = Self.unansweredMessageCount(in: messages)
        let lastCompletionDescription: String
        if let lastCompletedAt {
            lastCompletionDescription = "\(Self.compactElapsedTime(from: lastCompletedAt, to: referenceDate)) ago"
        } else {
            lastCompletionDescription = "never"
        }

        return """
        Here is the complete \(isGroupChat ? "group" : "private") conversation so far:
        Message ages are relative to the start of this heartbeat run.

        \(heartbeatConversationTranscript(messages: messages, relativeTo: referenceDate))

        Time since this heartbeat last completed: \(lastCompletionDescription).
        Number of unanswered messages in this chat: \(unansweredMessageCount).

        Scheduled heartbeat instruction:
        \(instruction)

        Decide whether to post as \(personaName). Return [[PASS]] if no message should be posted.
        """
    }

    private func heartbeatConversationTranscript(
        messages: [StoredChatMessage],
        relativeTo referenceDate: Date
    ) -> String {
        guard !messages.isEmpty else { return "(No messages yet.)" }

        return messages.map { message in
            let speaker = message.role == .user
                ? "User"
                : message.authorName ?? (isGroupChat ? "Persona" : storedChat.personaName)
            let age = Self.compactElapsedTime(from: message.createdAt, to: referenceDate)
            return "[\(age) ago] \(speaker): \(message.text)"
        }.joined(separator: "\n\n")
    }

    private static func unansweredMessageCount(in messages: [StoredChatMessage]) -> Int {
        var count = 0
        for message in messages.reversed() {
            guard message.role != .user else { break }
            count += 1
        }
        return count
    }

    private func storedConversationTranscript() -> String {
        allStoredMessages().map { message in
            let speaker = message.role == .user
                ? "User"
                : message.authorName ?? (isGroupChat ? "Persona" : storedChat.personaName)
            return "\(speaker): \(message.text)"
        }.joined(separator: "\n\n")
    }

    private func currentMemory(for personaID: Persona.ID) -> String {
        personaStore.persona(for: personaID)?.memoryText ?? ""
    }

    private func currentSoul(for personaID: Persona.ID, fallback: String) -> String {
        personaStore.persona(for: personaID)?.soul ?? fallback
    }

    private func allStoredMessages() -> [StoredChatMessage] {
        let descriptor = FetchDescriptor<StoredChatMessage>(
            predicate: #Predicate { message in
                message.chatID == id
            },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private static func compactElapsedTime(from date: Date, to referenceDate: Date) -> String {
        let seconds = max(0, Int(referenceDate.timeIntervalSince(date)))
        switch seconds {
        case 0..<60:
            return "\(seconds)s"
        case 60..<3_600:
            return "\(seconds / 60)m"
        case 3_600..<86_400:
            return "\(seconds / 3_600)h"
        case 86_400..<604_800:
            return "\(seconds / 86_400)d"
        case 604_800..<2_592_000:
            return "\(seconds / 604_800)w"
        case 2_592_000..<31_536_000:
            return "\(seconds / 2_592_000)mo"
        default:
            return "\(seconds / 31_536_000)y"
        }
    }

    private static func isPassResponse(_ response: String) -> Bool {
        ["[[pass]]", "[pass]", "pass"].contains(response.lowercased())
    }

    private func appendMessage(
        role: ChatRole,
        text: String,
        authorPersonaID: UUID? = nil,
        authorName: String? = nil
    ) {
        let storedMessage = StoredChatMessage(
            chatID: id,
            role: role,
            text: text,
            authorPersonaID: authorPersonaID,
            authorName: authorName
        )
        modelContext.insert(storedMessage)
        storedChat.updatedAt = .now
        saveChanges()
        messages.append(ChatMessage(storedMessage: storedMessage))
    }

    private func updateTitle(_ newTitle: String) {
        title = newTitle
        storedChat.title = newTitle
        storedChat.updatedAt = .now
        saveChanges()
    }

    private func updateAvailability() {
        if isGroupChat {
            canSend = !personaStore.personas.isEmpty || !groupParticipants.isEmpty

            if groupParticipants.isEmpty {
                if let firstMention = availablePersonaMentions.first {
                    availabilityMessage = "Mention \(firstMention) to add a persona to the discussion."
                } else {
                    availabilityMessage = "Create a persona before starting this group discussion."
                }
            } else {
                let count = groupParticipants.count
                availabilityMessage = count == 1
                    ? "1 persona is in this discussion."
                    : "\(count) personas are in this discussion."
            }
            return
        }

        switch backend {
        case .openAICompatible(let configuration):
            if let validationError = configuration.validationError {
                canSend = false
                availabilityMessage = "\(configuration.name): \(validationError)"
            } else {
                canSend = true
                availabilityMessage = "\(configuration.name) is ready."
            }
            return
        case .missingLocalModel:
            canSend = false
            availabilityMessage = "This chat's local model is no longer configured."
            return
        case .appleFoundation:
            break
        }

        switch model.availability {
        case .available:
            canSend = true
            availabilityMessage = "On-device Foundation model is ready."
        case .unavailable(.deviceNotEligible):
            canSend = false
            availabilityMessage = "This device is not eligible for Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            canSend = false
            availabilityMessage = "Turn on Apple Intelligence in Settings to chat."
        case .unavailable(.modelNotReady):
            canSend = false
            availabilityMessage = "The on-device model is not ready yet."
        case .unavailable:
            canSend = false
            availabilityMessage = "The on-device model is unavailable right now."
        }
    }

    private func saveChanges() {
        guard modelContext.hasChanges else { return }

        do {
            try modelContext.save()
        } catch {
            assertionFailure("Failed to save chat: \(error.localizedDescription)")
        }
    }

    private static func instructions(for soul: String) -> String {
        let trimmedSoul = soul.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedSoul.isEmpty ? """
        You are a concise assistant inside a simple chat app.
        Answer conversationally, and don't feel the need to ask a follow-up question unless it's natural.
        """ : trimmedSoul
    }

    private static func personaSystemInstructions(
        personaName: String,
        soul: String,
        memory: String
    ) -> String {
        """
        Your persona name is \(personaName).

        Individual persona instructions:
        \(instructions(for: soul))

        \(PersonaMemoryHarness.instructionSection(memory: memory))
        """
    }
}

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    let role: ChatRole
    let text: String
    let authorPersonaID: UUID?
    let authorName: String?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        role: ChatRole,
        text: String,
        authorPersonaID: UUID? = nil,
        authorName: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.authorPersonaID = authorPersonaID
        self.authorName = authorName
        self.createdAt = createdAt
    }

    init(storedMessage: StoredChatMessage, fallbackAssistantName: String? = nil) {
        id = storedMessage.id
        role = storedMessage.role
        text = storedMessage.text
        authorPersonaID = storedMessage.authorPersonaID
        authorName = storedMessage.authorName ?? (storedMessage.role == .assistant ? fallbackAssistantName : nil)
        createdAt = storedMessage.createdAt
    }
}

enum ChatRole: String {
    case user
    case assistant
}

#Preview {
    ContentViewPreview()
}

struct ContentViewPreview: View {
    private let modelContainer: ModelContainer
    private let personaStore: PersonaStore
    private let textToSpeechToolStore: TextToSpeechToolStore
    private let chatStore: ChatStore

    init() {
        do {
            let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
            let container = try ModelContainer(
                for: Persona.self,
                PersonaHeartbeat.self,
                HeartbeatRun.self,
                LocalModel.self,
                TextToSpeechTool.self,
                StoredChat.self,
                StoredGroupChatParticipant.self,
                StoredChatMessage.self,
                configurations: configuration
            )
            let personaStore = PersonaStore(modelContext: container.mainContext)
            let localModelStore = LocalModelStore(modelContext: container.mainContext)
            let textToSpeechToolStore = TextToSpeechToolStore(modelContext: container.mainContext)
            modelContainer = container
            self.personaStore = personaStore
            self.textToSpeechToolStore = textToSpeechToolStore
            chatStore = ChatStore(personaStore: personaStore, localModelStore: localModelStore, modelContext: container.mainContext)
        } catch {
            fatalError("Failed to create preview model container: \(error.localizedDescription)")
        }
    }

    var body: some View {
        ContentView(
            personaStore: personaStore,
            textToSpeechToolStore: textToSpeechToolStore,
            chatStore: chatStore
        )
            .modelContainer(modelContainer)
    }
}
