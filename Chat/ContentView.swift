import Foundation
import Combine
import ShadSwift
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
                let usesChatGPT = agentStore.agents.contains {
                    ChatModelIdentifier.isChatGPT($0.selectedModelIdentifier)
                } || agentStore.heartbeats.contains {
                    $0.modelIdentifier.map(ChatModelIdentifier.isChatGPT) == true
                } || chatStore.chats.contains {
                    $0.usesChatGPTModel
                }
                if usesChatGPT {
                    Task { @MainActor in
                        await localModelStore.refreshChatGPT()
                    }
                }
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
                .shadTheme(ChatShadTheme.theme)
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
                .shadTheme(ChatShadTheme.theme)
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
            .shadTheme(ChatShadTheme.theme)
        }
#endif
    }
}

final class ChatSidebarPresentation: ObservableObject {
    @Published var chatBeingRenamed: ChatViewModel?
    @Published var renameDraft = ""
    @Published var renameDialogIsPresented = false
    @Published var chatPendingReset: ChatViewModel?
    @Published var resetDialogIsPresented = false
    @Published var chatPendingDelete: ChatViewModel?
    @Published var deleteDialogIsPresented = false

    func beginRenaming(_ chat: ChatViewModel) {
        guard chat.canRename else { return }
        chatBeingRenamed = chat
        renameDraft = chat.title
        renameDialogIsPresented = true
    }

    func beginReset(_ chat: ChatViewModel) {
        chatPendingReset = chat
        resetDialogIsPresented = true
    }

    func beginDelete(_ chat: ChatViewModel) {
        guard chat.canDelete else { return }
        chatPendingDelete = chat
        deleteDialogIsPresented = true
    }

    func commitRename() {
        chatBeingRenamed?.rename(to: renameDraft)
        chatBeingRenamed = nil
        renameDialogIsPresented = false
    }
}

struct ContentView: View {
    @ObservedObject private var agentStore: AgentStore
    @ObservedObject private var textToSpeechToolStore: TextToSpeechToolStore
    @ObservedObject private var chatStore: ChatStore
    @StateObject private var sidebarState = ShadSidebarState(
        isOpen: true,
        width: 280,
        iconWidth: 48
    )
    @StateObject private var sidebarPresentation = ChatSidebarPresentation()
    @State private var compactionStatusIsPresented = false
    @State private var voiceErrorMessage: String?
    @Environment(\.shadTheme) private var theme

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
        ShadSidebarProvider(state: sidebarState) {
            ShadSidebar(variant: .sidebar, collapsible: .offcanvas) {
                ChatSidebar(
                    agentStore: agentStore,
                    chatStore: chatStore,
                    presentation: sidebarPresentation
                )
            }

            ShadSidebarInset(variant: .sidebar) {
                NavigationStack {
                    if let chat = chatStore.selectedChat {
                        ChatDetailView(
                            chat: chat,
                            agentStore: agentStore,
                            textToSpeechToolStore: textToSpeechToolStore,
                            voiceErrorMessage: $voiceErrorMessage,
                            onPresentCompactionStatus: {
                                compactionStatusIsPresented = true
                            },
                            onResetChat: {
                                sidebarPresentation.beginReset(chat)
                            },
                            onDeleteChat: {
                                sidebarPresentation.beginDelete(chat)
                            }
                        )
                        .id(chat.id)
                    } else {
                        Text("Start a new chat.")
                            .font(theme.font(theme.typography.sm))
                            .foregroundStyle(theme.colors.mutedForeground)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        ShadSidebarTrigger()
                    }
                }
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .shadDialog(isPresented: $sidebarPresentation.renameDialogIsPresented) {
            ShadDialogContent(maxWidth: 420) {
                ShadDialogHeader {
                    ShadDialogTitle("Rename chat")
                    ShadDialogDescription("Choose a name for this conversation.")
                }
                ShadInput(
                    "Chat name",
                    text: $sidebarPresentation.renameDraft,
                    onSubmit: sidebarPresentation.commitRename
                )
                .accessibilityLabel("Chat name")
                ShadDialogFooter {
                    ShadDialogClose("Cancel") {
                        sidebarPresentation.chatBeingRenamed = nil
                    }
                    ShadButton("Rename", action: sidebarPresentation.commitRename)
                }
            }
        }
        .shadAlertDialog(isPresented: $sidebarPresentation.resetDialogIsPresented) {
            ShadAlertDialogContent {
                ShadAlertDialogTitle("Reset chat?")
                ShadAlertDialogDescription(
                    "Previous messages stay saved but will no longer appear or be sent to the model."
                )
            } actions: {
                ShadAlertDialogCancel {
                    sidebarPresentation.chatPendingReset = nil
                }
                ShadAlertDialogAction("Reset Chat", variant: .destructive) {
                    if let chat = sidebarPresentation.chatPendingReset {
                        chatStore.resetChat(chat)
                    }
                    sidebarPresentation.chatPendingReset = nil
                }
            }
        }
        .shadAlertDialog(isPresented: $sidebarPresentation.deleteDialogIsPresented) {
            ShadAlertDialogContent {
                ShadAlertDialogTitle("Delete chat?")
                ShadAlertDialogDescription(
                    "This chat will be removed from the sidebar. This cannot be undone."
                )
            } actions: {
                ShadAlertDialogCancel {
                    sidebarPresentation.chatPendingDelete = nil
                }
                ShadAlertDialogAction("Delete Chat", variant: .destructive) {
                    if let chat = sidebarPresentation.chatPendingDelete {
                        chatStore.deleteChat(chat)
                    }
                    sidebarPresentation.chatPendingDelete = nil
                }
            }
        }
        .shadDialog(isPresented: $compactionStatusIsPresented) {
            if let chat = chatStore.selectedChat {
                ShadDialogContent(maxWidth: 560, showsCloseButton: false) {
                    CompactionStatusView(chat: chat)
                }
            }
        }
        .shadDialog(isPresented: voiceErrorIsPresented) {
            ShadDialogContent(maxWidth: 448, showsCloseButton: false) {
                ShadDialogHeader {
                    ShadDialogTitle("Voice error")
                    ShadDialogDescription(
                        voiceErrorMessage ?? "Voice input could not be started."
                    )
                }
                ShadDialogFooter {
                    ShadDialogClose("OK") {
                        voiceErrorMessage = nil
                    }
                }
            }
        }
        .onChange(of: chatStore.selectedChatID) {
            compactionStatusIsPresented = false
            voiceErrorMessage = nil
        }
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
}

struct ChatSidebar: View {
    @ObservedObject var agentStore: AgentStore
    @ObservedObject var chatStore: ChatStore
    @ObservedObject var presentation: ChatSidebarPresentation
    @State private var collapsedAgentIDs: Set<Agent.ID> = []
    @State private var groupChatsAreCollapsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ShadSidebarHeader {
                newChatControl
            }

            ShadSidebarContent {
                ShadSidebarGroup("Chats") {
                    ShadSidebarMenu {
                        if !chatStore.groupChats.isEmpty {
                            GroupChatSection(
                                chats: chatStore.groupChats,
                                selectedChatID: $chatStore.selectedChatID,
                                isCollapsed: groupChatsAreCollapsed,
                                onRenameChat: presentation.beginRenaming,
                                onResetChat: presentation.beginReset,
                                onDeleteChat: presentation.beginDelete
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
                                onRenameChat: presentation.beginRenaming,
                                onResetChat: presentation.beginReset,
                                onDeleteChat: presentation.beginDelete,
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
                }
            }
        }
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
        ShadDropdownMenu(alignment: .bottomLeading, minWidth: 200) { _ in
            NewChatLabel()
        } content: {
            ShadDropdownMenuItem("Group chat", icon: .users) {
                chatStore.startGroupChat()
            }

            if !agentStore.agents.isEmpty {
                ShadDropdownMenuSeparator()

                ForEach(agentStore.agents) { agent in
                    ShadDropdownMenuItem(agent.displayName, icon: .bot) {
                        startChat(with: agent)
                    }
                }
            }
        }
        .help("Start a new chat")
    }
}

struct NewChatLabel: View {
    var body: some View {
        ShadSidebarMenuButtonLabel(
            title: "New chat",
            icon: .custom("square.and.pencil")
        )
    }
}

struct AgentAvatar: View {
    let agent: Agent
    var size: CGFloat = 20
    @Environment(\.shadTheme) private var theme

    var body: some View {
        let paletteEntry = paletteEntry
        ShadAvatar(photo: agent.avatarPhoto, fallback: agent.avatarInitials, customSize: size)
            .shadTheme { localTheme in
                localTheme.colors.muted = paletteEntry.background
                localTheme.colors.mutedForeground = paletteEntry.foreground
            }
            .accessibilityHidden(true)
    }

    private var paletteEntry: (background: Color, foreground: Color) {
        let colors: [(background: Color, foreground: Color)] = [
            (theme.colors.primary, theme.colors.primaryForeground),
            (theme.colors.success, theme.colors.successForeground),
            (theme.colors.destructive, theme.colors.destructiveForeground),
            (theme.colors.warning, theme.colors.warningForeground),
            (theme.colors.info, theme.colors.infoForeground),
            (theme.colors.chart1, theme.colors.bubbleSentForeground),
            (theme.colors.chart2, theme.colors.successForeground),
            (
                theme.colors.chart4,
                theme.colorScheme == .dark
                    ? theme.colors.foreground
                    : theme.colors.warningForeground
            )
        ]
        let index = agent.id.uuidString.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
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
    @Environment(\.shadTheme) private var theme

    private var isDefaultSelected: Bool {
        defaultChat.map { selectedChatID == $0.id } ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ShadSidebarMenuItem {
                Button(action: onSelectDefault) {
                    HStack(spacing: 10) {
                        AgentAvatar(agent: agent)

                        Text(agent.displayName)
                            .font(theme.font(theme.typography.sm, theme.typography.medium))
                            .lineLimit(1)

                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(theme.colors.sidebarForeground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.shad(.ghost, size: .sm, fillsWidth: true))
                .background(
                    ShadRoundedRectangle(cornerRadius: theme.radius.md)
                        .fill(isDefaultSelected ? theme.colors.sidebarAccent : .clear)
                )
                .accessibilityAddTraits(isDefaultSelected ? .isSelected : [])

                if !extraChats.isEmpty {
                    ShadSidebarMenuAction(action: onToggle) {
                        ShadIconView(.chevronDown, size: theme.typography.xs)
                            .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                    }
                    .help(isCollapsed ? "Show chats" : "Hide chats")
                    .accessibilityLabel(
                        isCollapsed
                            ? "Show chats for \(agent.displayName)"
                            : "Hide chats for \(agent.displayName)"
                    )
                }
            }
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
                ShadSidebarMenuSub {
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
            ShadSidebarMenuButton(
                "Group chats",
                icon: .users,
                action: onToggle
            ) {
                ShadIconView(.chevronDown, size: 12)
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0))
            }

            if !isCollapsed {
                ShadSidebarMenuSub {
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
        ShadSidebarMenuSubButton(chat.title, isActive: isSelected, action: onSelect)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
    @Binding var voiceErrorMessage: String?
    let onPresentCompactionStatus: () -> Void
    let onResetChat: () -> Void
    let onDeleteChat: () -> Void
    @StateObject private var voiceInput = VoiceInputService()
    @StateObject private var voicePlayback = TextToSpeechPlaybackService()
    @StateObject private var messageScroller = ShadMessageScrollerModel(
        autoScroll: true,
        defaultScrollPosition: .end,
        preserveScrollOnPrepend: true
    )
    @FocusState private var composerIsFocused: Bool
    @State private var newestMessageID: ChatMessage.ID?
    @State private var hasUnreadNewMessages = false
    @State private var voiceDraftPrefix = ""
    @State private var voiceSendIsPending = false
    @State private var readRepliesOnlyIsEnabled = false
    @State private var automaticReplyReadingStartedAt: Date?
    @State private var voiceObservedMessageIDs: Set<ChatMessage.ID> = []
    @Environment(\.shadTheme) private var theme

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

            ShadMessageScrollerProvider(messageScroller) {
                ShadMessageScroller {
                    ShadMessageScrollerViewport {
                        ShadMessageScrollerContent(ids: transcriptRowIDs, spacing: theme.spacing.lg) {
                            if chat.isGroupChat, chat.messages.isEmpty {
                                GroupChatEmptyState(mentions: chat.availableAgentMentions)
                            }

                            ForEach(chat.messages) { message in
                                ShadMessageScrollerItem(messageId: message.id) {
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
                                }
                            }

                            if voicePlayback.isGenerating {
                                ShadMessageScrollerItem(messageId: Self.voiceGenerationIndicatorID) {
                                    VoiceGenerationIndicator {
                                        voicePlayback.cancelGeneration()
                                    }
                                }
                            }

                            if chat.isResponding {
                                ShadMessageScrollerItem(messageId: ChatViewModel.typingIndicatorID) {
                                    TypingBubble(agentName: chat.respondingAgentName)
                                }
                            }
                        }
                    }

                    if shouldShowMoreMessagesButton {
                        ShadMessageScrollerButton(edge: .end, title: moreMessagesButtonTitle)
                            .simultaneousGesture(TapGesture().onEnded {
                                hasUnreadNewMessages = false
                            })
                    }
                }
                .background(theme.colors.muted.opacity(0.45))
                .onAppear {
                    voiceObservedMessageIDs = Set(chat.messages.map(\.id))
                    newestMessageID = chat.messages.last?.id
                    hasUnreadNewMessages = false
                    messageScroller.onReachStart = {
                        chat.loadOlderMessages()
                    }
                    if messageScroller.isAtStart {
                        chat.loadOlderMessages()
                    }
                }
                .onChange(of: chat.id) {
                    stopVoiceModes()
                    voicePlayback.clearGeneratedAudio()
                    voiceSendIsPending = false
                    voiceDraftPrefix = chat.draft
                    voiceObservedMessageIDs = Set(chat.messages.map(\.id))
                    hasUnreadNewMessages = false
                    messageScroller.scrollToEnd(animated: false)
                }
                .onChange(of: chat.messages) {
                    speakNewAssistantMessagesIfNeeded()
                    scrollToNewestMessageIfNeeded()
                }
                .onChange(of: chat.isResponding) {
                    submitPendingVoiceDraftIfPossible()

                    if chat.isResponding, latestMessageIsVisible {
                        messageScroller.scrollToEnd()
                    }
                }
                .onChange(of: voicePlayback.isGenerating) {
                    if voicePlayback.isGenerating, latestMessageIsVisible {
                        messageScroller.scrollToEnd()
                    }
                }
                .onChange(of: messageScroller.visibleMessageIds) {
                    if latestMessageIsVisible {
                        hasUnreadNewMessages = false
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            composer
                .padding(theme.spacing.xl)
                .background(theme.colors.background)
        }
        .navigationTitle(chat.displayTitle)
        .toolbar {
            ToolbarItem {
                ShadDropdownMenu(alignment: .bottomTrailing) { _ in
                    Group {
                        if chat.isCompacting {
                            ShadSpinner(size: theme.typography.base)
                        } else {
                            ShadIconView(.moreHorizontal, size: theme.typography.base)
                        }
                    }
                    .frame(width: theme.spacing.xxl, height: theme.spacing.xxl)
                    .contentShape(
                        ShadRoundedRectangle(cornerRadius: theme.radius.md)
                    )
                } content: {
                    ShadDropdownMenuCheckboxItem("Render Markdown", isOn: rendersMarkdown)

                    ShadDropdownMenuSeparator()

                    ShadDropdownMenuItem(
                        chat.isCompacting ? "Compacting…" : "Compact",
                        icon: chat.isCompacting
                            ? .loaderCircle
                            : .custom("rectangle.compress.vertical")
                    ) {
                        Task {
                            await chat.compactConversation()
                        }
                    }
                    .disabled(chat.isResponding || chat.isCompacting)

                    ShadDropdownMenuItem("Compaction Status", icon: .info) {
                        onPresentCompactionStatus()
                    }

                    ShadDropdownMenuSeparator()

                    ShadDropdownMenuItem("Reset Chat", icon: .refresh) {
                        onResetChat()
                    }
                    .disabled(chat.isResponding || chat.isCompacting)

                    if chat.canDelete {
                        ShadDropdownMenuItem(
                            "Delete Chat",
                            icon: .trash,
                            variant: .destructive
                        ) {
                            onDeleteChat()
                        }
                        .disabled(chat.isResponding)
                    }
                }
                .help("Chat actions")
                .accessibilityLabel("Chat actions")
            }
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
    }

    private var rendersMarkdown: Binding<Bool> {
        Binding(
            get: { chat.rendersMarkdown },
            set: { chat.setRendersMarkdown($0) }
        )
    }

    private var modelStatus: some View {
        ShadItem(variant: .muted, size: .sm) {
            ShadItemMedia(variant: .default, size: theme.spacing.xxl) {
                ShadIconView(modelStatusIcon, size: theme.typography.base)
                    .foregroundStyle(modelStatusColor)
            }
            ShadItemContent {
                ShadItemDescription(chat.availabilityMessage)
            }
        }
    }

    private var modelStatusIcon: ShadIcon {
        if chat.isGroupChat { return .users }
        return chat.canSend ? .circleCheck : .triangleAlert
    }

    private var modelStatusColor: Color {
        if chat.isGroupChat { return theme.colors.primary }
        return chat.canSend ? theme.colors.success : theme.colors.warning
    }

    private var transcriptRowIDs: [AnyHashable] {
        var ids = chat.messages.map { AnyHashable($0.id) }
        if voicePlayback.isGenerating {
            ids.append(AnyHashable(Self.voiceGenerationIndicatorID))
        }
        if chat.isResponding {
            ids.append(AnyHashable(ChatViewModel.typingIndicatorID))
        }
        return ids
    }

    private var shouldShowMoreMessagesButton: Bool {
        hasUnreadNewMessages || isScrolledMoreThanFiveMessagesFromLatest
    }

    private var moreMessagesButtonTitle: String {
        hasUnreadNewMessages ? "New messages" : "More messages"
    }

    private var latestMessageIsVisible: Bool {
        guard let latestMessageID = chat.messages.last?.id else { return true }
        return messageScroller.visibleMessageIds.contains(AnyHashable(latestMessageID))
    }

    private var isScrolledMoreThanFiveMessagesFromLatest: Bool {
        guard !messageScroller.visibleMessageIds.isEmpty,
              chat.messages.count > 5,
              let newestVisibleIndex = chat.messages.lastIndex(where: {
                  messageScroller.visibleMessageIds.contains(AnyHashable($0.id))
              }) else {
            return false
        }

        return newestVisibleIndex < chat.messages.count - 5
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: theme.spacing.lg) {
            HStack(alignment: .bottom, spacing: theme.spacing.xs) {
                TextField(chat.composerPlaceholder, text: $chat.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(theme.font(theme.typography.sm))
                    .foregroundStyle(theme.colors.foreground)
                    .lineLimit(1...5)
                    .padding(.leading, theme.spacing.lg)
                    .padding(.vertical, theme.spacing.lg)
                    .focused($composerIsFocused)
                    .submitLabel(.send)
                    .onSubmit {
                        submitDraft()
                    }
                    .disabled(!chat.canSend || chat.isResponding || voiceInput.isActive)

                HStack(spacing: theme.spacing(0.5)) {
                    replyReadingModeButton
                    voiceModeButton
                }
                .padding(.trailing, theme.spacing.sm)
                .padding(.bottom, theme.spacing.xs)
            }
            .background(
                ShadRoundedRectangle(cornerRadius: theme.radius.lg)
                    .fill(theme.colors.muted.opacity(0.65))
            )
            .overlay {
                ShadRoundedRectangle(cornerRadius: theme.radius.lg)
                    .strokeBorder(theme.colors.input, lineWidth: theme.borderWidth)
            }
            .modifier(VoiceDictationGlow(isActive: voiceInput.isTranscribing))

            ShadButton(
                icon: .custom("paperplane.fill"),
                size: .iconLG,
                accessibilityLabel: "Send message"
            ) {
                submitDraft()
            }
            .disabled(!chat.canSubmitDraft || voiceInput.isActive)
            .help("Send message")
        }
    }

    private var voiceModeButton: some View {
        let isLoading = voiceInput.state == .requestingPermission || voiceInput.state == .preparing
        return ShadButton(
            icon: .custom("mic.fill"),
            variant: voiceInput.isActive ? .secondary : .ghost,
            size: .icon,
            shape: .pill,
            accessibilityLabel: voiceModeAccessibilityLabel,
            isLoading: isLoading
        ) {
            toggleVoiceMode()
        }
        .shadTheme { localTheme in
            if voiceInput.isActive {
                localTheme.colors.secondary = localTheme.colors.destructive.opacity(
                    localTheme.colorScheme == .dark ? 0.20 : 0.12
                )
                localTheme.colors.secondaryForeground = localTheme.colors.destructive
            }
        }
        .disabled(!voiceInput.isActive && (!chat.canSend || !voiceModeIsConfigured))
        .help(voiceModeHelpText)
        .accessibilityLabel(voiceModeAccessibilityLabel)
    }

    private var replyReadingModeButton: some View {
        ShadButton(
            icon: .custom(
                readRepliesOnlyIsEnabled ? "speaker.wave.2.fill" : "speaker.wave.2"
            ),
            variant: readRepliesOnlyIsEnabled ? .secondary : .ghost,
            size: .icon,
            shape: .pill,
            accessibilityLabel: readRepliesOnlyIsEnabled
                ? "Turn off reading replies"
                : "Turn on reading replies without dictation"
        ) {
            toggleReplyReadingMode()
        }
        .shadTheme { localTheme in
            if readRepliesOnlyIsEnabled {
                let blueAccent = ChatShadTheme.blueAccent(for: localTheme.colorScheme)
                localTheme.colors.secondary = blueAccent.opacity(0.15)
                localTheme.colors.secondaryForeground = blueAccent
            }
        }
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

    private func scrollToNewestMessageIfNeeded() {
        let previousNewestMessageID = newestMessageID
        let latestMessageID = chat.messages.last?.id
        defer { newestMessageID = latestMessageID }

        guard latestMessageID != previousNewestMessageID else { return }

        if previousNewestMessageID == nil
            || previousNewestMessageID.map({
                messageScroller.visibleMessageIds.contains(AnyHashable($0))
            }) == true {
            hasUnreadNewMessages = false
            messageScroller.scrollToEnd()
        } else {
            hasUnreadNewMessages = true
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
    @Environment(\.shadTheme) private var theme
    @State private var generationTurn: GenerationTurn?

    var body: some View {
        Group {
            if message.role == .assistant {
                ShadMessage(align: .start, spacing: theme.spacing.sm) {
                    ShadMessageContent {
                        if let authorName = message.authorName {
                            ShadMessageHeader(authorName)
                        }

                        HStack(alignment: .bottom, spacing: theme.spacing.sm) {
                            bubble
                            audioControls
                            inspectorControl
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
                }
            } else {
                ShadMessage(align: .end, spacing: theme.spacing.sm) {
                    ShadMessageContent {
                        bubble
                    }
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
            VStack(spacing: theme.spacing.xs) {
                ForEach(audioChunkIndexes, id: \.self) { chunkIndex in
                    let isPlaying = playingAudioChunkIndex == chunkIndex
                    ShadButton(
                        variant: isPlaying ? .secondary : .ghost,
                        size: .iconSM,
                        shape: .pill
                    ) {
                        onToggleAudio(chunkIndex)
                    } label: {
                        ZStack(alignment: .bottomTrailing) {
                            ShadIconView(
                                .custom(isPlaying ? "speaker.wave.2.fill" : "speaker.wave.2"),
                                size: theme.typography.xs,
                                weight: theme.typography.semibold
                            )

                            if audioChunkIndexes.count > 1 {
                                Text("\(chunkIndex + 1)")
                                    .font(theme.font(theme.typography.xs * 0.67, .bold))
                                    .offset(x: 3, y: 3)
                            }
                        }
                    }
                    .shadTheme { localTheme in
                        if isPlaying {
                            let blueAccent = ChatShadTheme.blueAccent(for: localTheme.colorScheme)
                            localTheme.colors.secondary = blueAccent.opacity(0.15)
                            localTheme.colors.secondaryForeground = blueAccent
                        }
                    }
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
        ShadBubble(
            variant: message.role == .user ? .sent : .received,
            align: message.role == .user ? .end : .start
        ) {
            ShadBubbleContent {
                messageText
                    .textSelection(.enabled)
            }
        }
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
    @Environment(\.shadTheme) private var theme

    private var safeDuration: TimeInterval {
        guard duration.isFinite, duration > 0 else { return 0.01 }
        return duration
    }

    private var safeCurrentTime: TimeInterval {
        guard currentTime.isFinite else { return 0 }
        return min(max(currentTime, 0), safeDuration)
    }

    var body: some View {
        ShadItem(variant: .muted, size: .xs) {
            HStack(spacing: theme.spacing.md) {
                Text(formattedTime(safeCurrentTime))
                    .frame(minWidth: 30, alignment: .trailing)

                ShadSlider(
                    value: Binding(
                        get: { safeCurrentTime },
                        set: onSeek
                    ),
                    in: 0...safeDuration
                )
                .accessibilityLabel("Audio playback position")
                .accessibilityValue("\(formattedTime(safeCurrentTime)) of \(formattedTime(duration))")

                Text(formattedTime(duration))
                    .frame(minWidth: 30, alignment: .leading)
            }
            .font(theme.monoFont(theme.typography.xs).monospacedDigit())
            .foregroundStyle(theme.colors.mutedForeground)
        }
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
        ShadMessage(align: .start) {
            ShadTypingIndicator(agentName.map { "\($0) is thinking" } ?? "Thinking")
        }
    }
}

struct VoiceGenerationIndicator: View {
    let onCancel: () -> Void

    var body: some View {
        ShadMessage(align: .start) {
            ShadMarker(action: onCancel) {
                ShadMarkerIcon {
                    ShadSpinner(size: 14)
                }
                ShadMarkerContent("Generating audio…", shimmer: true)
                ShadMarkerIcon(.circleX)
            }
            .help("Cancel remaining audio generation")
            .accessibilityLabel("Cancel audio generation")
        }
    }
}

struct GroupChatConfigurationView: View {
    @ObservedObject var chat: ChatViewModel
    @State private var instructionsAreExpanded = false
    @Environment(\.shadTheme) private var theme

    var body: some View {
        ShadCard(size: .sm) {
            ShadCardHeader {
                HStack(spacing: theme.spacing.md) {
                    ShadIconView(.users, size: theme.typography.sm)
                        .foregroundStyle(theme.colors.primary)
                    ShadCardTitle("Participants")

                    if chat.groupParticipantMentions.isEmpty {
                        ShadCardDescription("Add one with an @mention")
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: theme.spacing.sm) {
                                ForEach(chat.groupParticipantMentions, id: \.self) { mention in
                                    ShadBadge(
                                        mention,
                                        variant: .secondary,
                                        color: .blue
                                    )
                                }
                            }
                        }
                    }

                    Spacer(minLength: 0)
                }
            }

            ShadCardContent {
                VStack(alignment: .leading, spacing: theme.spacing.md) {
                    ShadButton(
                        variant: .ghost,
                        size: .sm,
                        fillsWidth: true
                    ) {
                        withAnimation(theme.interactionAnimation) {
                            instructionsAreExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: theme.spacing.sm) {
                            Text("Group instructions")
                            Spacer(minLength: 0)
                            ShadIconView(.chevronDown, size: theme.typography.xs)
                                .rotationEffect(.degrees(instructionsAreExpanded ? 0 : -90))
                        }
                    }
                    .accessibilityValue(instructionsAreExpanded ? "Expanded" : "Collapsed")
                    .accessibilityHint(
                        instructionsAreExpanded
                            ? "Collapse group instructions"
                            : "Expand group instructions"
                    )

                    if instructionsAreExpanded {
                        ShadField {
                            ShadTextarea(
                                "Instructions for every participant",
                                text: groupInstructions,
                                minHeight: 72,
                                maxHeight: 120
                            )
                            .accessibilityLabel("Group instructions")
                            ShadFieldDescription(
                                "These instructions are sent with each agent's individual instructions."
                            )
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
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
    @Environment(\.shadTheme) private var theme

    var body: some View {
        VStack(spacing: theme.spacing.lg) {
            ShadIconView(.users, size: theme.typography.xxl)
                .foregroundStyle(theme.colors.mutedForeground)

            Text("Start the discussion")
                .font(theme.font(theme.typography.lg, theme.typography.semibold))
                .foregroundStyle(theme.colors.foreground)

            Text(emptyStateDescription)
                .font(theme.font(theme.typography.sm))
                .foregroundStyle(theme.colors.mutedForeground)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 420)
        .padding(.vertical, theme.spacing(14))
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
    @Environment(\.shadTheme) private var theme
    @State private var tokenCount: Int?

    private var status: ConversationCompactionStatus {
        chat.compactionStatus
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.xl) {
            HStack {
                ShadDialogTitle("Compaction Status")
                Spacer()
                ShadDialogClose("Done")
                    .keyboardShortcut(.cancelAction)
            }

            if status.hasDigest {
                ShadItemGroup(isBordered: true) {
                    if let compactedAt = status.compactedAt {
                        statusRow(
                            "Last compacted",
                            compactedAt.formatted(date: .abbreviated, time: .shortened)
                        )
                    } else {
                        statusRow("Last compacted", "Unknown")
                    }

                    if let covered = status.coveredMessageCount {
                        ShadItemSeparator()
                        statusRow("Messages covered", "\(covered)")
                    }

                    ShadItemSeparator()
                    statusRow(
                        "Summary tokens",
                        tokenCount.map(String.init) ?? "About \(status.estimatedTokens)"
                    )
                }

                VStack(alignment: .leading, spacing: theme.spacing.sm) {
                    Text("Current summary")
                        .font(theme.font(theme.typography.xs, theme.typography.semibold))
                        .foregroundStyle(theme.colors.mutedForeground)

                    ShadItem(variant: .muted, size: .sm) {
                        ScrollView {
                            Text(status.summary)
                                .font(theme.monoFont(theme.typography.sm))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            } else {
                ShadItem(variant: .muted, size: .sm) {
                    ShadItemDescription(
                        "This chat has not been compacted yet. Older messages are sent in full until they exceed the model’s context window."
                    )
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
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

    private func statusRow(_ title: String, _ value: String) -> some View {
        ShadItem(size: .xs) {
            ShadItemContent {
                ShadItemTitle(title)
            }
            ShadItemActions {
                Text(value)
                    .font(theme.font(theme.typography.sm))
                    .foregroundStyle(theme.colors.mutedForeground)
            }
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
            .shadTheme(ChatShadTheme.theme)
    }
}
