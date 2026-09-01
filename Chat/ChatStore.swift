import Combine
import Foundation
import SwiftData

@Model
final class StoredChat: Identifiable {
    @Attribute(.unique) var id: UUID
    @Attribute(originalName: "personaID") var agentID: UUID
    @Attribute(originalName: "personaName") var agentName: String
    @Attribute(originalName: "personaSoul") var agentSoul: String
    @Attribute(originalName: "personaModelIdentifier") var agentModelIdentifier: String?
    var kindRawValue: String?
    var groupSystemInstructions: String?
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var compactedSummary: String?
    var compactedThroughMessageID: UUID?
    var compactedAt: Date?
    var compactedMessageCount: Int?
    var rendersMarkdown: Bool?
    var isDefaultChat: Bool?
    var clearedThroughMessageID: UUID?

    init(
        id: UUID = UUID(),
        agentID: UUID,
        agentName: String,
        agentSoul: String,
        agentModelIdentifier: String? = nil,
        kind: ChatKind = .direct,
        groupSystemInstructions: String? = nil,
        title: String = "New chat",
        createdAt: Date = .now,
        updatedAt: Date = .now,
        compactedSummary: String? = nil,
        compactedThroughMessageID: UUID? = nil,
        compactedAt: Date? = nil,
        compactedMessageCount: Int? = nil,
        rendersMarkdown: Bool? = nil,
        isDefaultChat: Bool? = nil,
        clearedThroughMessageID: UUID? = nil
    ) {
        self.id = id
        self.agentID = agentID
        self.agentName = agentName
        self.agentSoul = agentSoul
        self.agentModelIdentifier = agentModelIdentifier
        kindRawValue = kind.rawValue
        self.groupSystemInstructions = groupSystemInstructions
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.compactedSummary = compactedSummary
        self.compactedThroughMessageID = compactedThroughMessageID
        self.compactedAt = compactedAt
        self.compactedMessageCount = compactedMessageCount
        self.rendersMarkdown = rendersMarkdown
        self.isDefaultChat = isDefaultChat
        self.clearedThroughMessageID = clearedThroughMessageID
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
    @Attribute(originalName: "authorPersonaID") var authorAgentID: UUID?
    var authorName: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        chatID: UUID,
        role: ChatRole,
        text: String,
        authorAgentID: UUID? = nil,
        authorName: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.chatID = chatID
        self.roleRawValue = role.rawValue
        self.text = text
        self.authorAgentID = authorAgentID
        self.authorName = authorName
        self.createdAt = createdAt
    }

    var role: ChatRole {
        ChatRole(rawValue: roleRawValue) ?? .assistant
    }
}

@MainActor
final class ChatStore: ObservableObject {
    struct AgentDeactivationPlan {
        let agentID: Agent.ID
        fileprivate let groupParticipantObjectIDs: [ChatViewModel.ID: Set<ObjectIdentifier>]
    }

    private static let messageBatchSize = 40

    @Published var chats: [ChatViewModel] = []
    @Published var selectedChatID: ChatViewModel.ID?

    private let modelContext: ModelContext
    private let agentStore: AgentStore
    private let localModelStore: LocalModelStore
    private let skillCatalog: SkillCatalog
    private let replyFilterStore: ReplyFilterStore
    private var agentsCancellable: AnyCancellable?
    private var agentConfigurationCancellable: AnyCancellable?
    private var chatActivityCancellables: [ChatViewModel.ID: AnyCancellable] = [:]

    var selectedChat: ChatViewModel? {
        guard let selectedChatID else { return nil }
        return chats.first { $0.id == selectedChatID }
    }

    init(
        agentStore: AgentStore,
        localModelStore: LocalModelStore,
        skillCatalog: SkillCatalog,
        replyFilterStore: ReplyFilterStore,
        modelContext: ModelContext
    ) {
        self.modelContext = modelContext
        self.agentStore = agentStore
        self.localModelStore = localModelStore
        self.skillCatalog = skillCatalog
        self.replyFilterStore = replyFilterStore
        loadChats()
        ensureDefaultChats(for: agentStore.agents)
        selectedChatID = chats.first?.id

        agentsCancellable = agentStore.$agents
            .sink { [weak self] agents in
                self?.ensureDefaultChats(for: agents)
            }
        agentConfigurationCancellable = agentStore.agentConfigurationDidChange
            .sink { [weak self] agentID in
                guard let self,
                      let agent = self.agentStore.agent(for: agentID) else { return }
                self.defaultChat(for: agentID)?.synchronizeDefaultChat(with: agent)
            }
    }

    func startChat(with agent: Agent) {
        _ = defaultChat(for: agent.id) ?? makeDirectChat(with: agent, isDefault: true)
        let chat = makeDirectChat(with: agent, isDefault: false)
        selectedChatID = chat.id
    }

    @discardableResult
    private func makeDirectChat(with agent: Agent, isDefault: Bool) -> ChatViewModel {
        let storedChat = StoredChat(
            agentID: agent.id,
            agentName: agent.displayName,
            agentSoul: agent.soul,
            agentModelIdentifier: agent.selectedModelIdentifier,
            title: isDefault ? agent.displayName : "New chat",
            isDefaultChat: isDefault
        )
        modelContext.insert(storedChat)

        var storedMessages: [StoredChatMessage] = []
        if !isDefault {
            let greeting = StoredChatMessage(
                chatID: storedChat.id,
                role: .assistant,
                text: "New chat with \(agent.displayName). What would you like to ask?",
                authorAgentID: agent.id,
                authorName: agent.displayName
            )
            modelContext.insert(greeting)
            storedMessages = [greeting]
        }
        saveChanges()

        let chat = ChatViewModel(
            storedChat: storedChat,
            storedMessages: storedMessages,
            storedGroupParticipants: [],
            agentStore: agentStore,
            localModelStore: localModelStore,
            skillCatalog: skillCatalog,
            replyFilterStore: replyFilterStore,
            modelContext: modelContext
        )
        if isDefault {
            chats.append(chat)
        } else {
            chats.insert(chat, at: 0)
        }
        refreshChatActivityObservations()
        return chat
    }

    func startGroupChat() {
        let storedChat = StoredChat(
            agentID: UUID(),
            agentName: "Group chat",
            agentSoul: "",
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
            agentStore: agentStore,
            localModelStore: localModelStore,
            skillCatalog: skillCatalog,
            replyFilterStore: replyFilterStore,
            modelContext: modelContext
        )
        chats.insert(chat, at: 0)
        refreshChatActivityObservations()
        selectedChatID = chat.id
    }

    func chats(for agentID: Agent.ID) -> [ChatViewModel] {
        chats.filter { !$0.isGroupChat && $0.agentID == agentID }
    }

    func extraChats(for agentID: Agent.ID) -> [ChatViewModel] {
        chats.filter { !$0.isGroupChat && $0.agentID == agentID && !$0.isDefaultChat }
    }

    func defaultChat(for agentID: Agent.ID?) -> ChatViewModel? {
        guard let agentID else { return nil }
        return chats.first { !$0.isGroupChat && $0.agentID == agentID && $0.isDefaultChat }
    }

    func selectDefaultChat(for agent: Agent) {
        let chat = defaultChat(for: agent.id) ?? makeDirectChat(with: agent, isDefault: true)
        selectedChatID = chat.id
    }

    var groupChats: [ChatViewModel] {
        chats.filter(\.isGroupChat)
    }

    func stageAgentDeactivation(_ agentID: Agent.ID) -> AgentDeactivationPlan {
        var groupParticipantObjectIDs: [ChatViewModel.ID: Set<ObjectIdentifier>] = [:]
        for chat in groupChats {
            let objectIDs = chat.stageGroupParticipantRemoval(agentID: agentID)
            if !objectIDs.isEmpty {
                groupParticipantObjectIDs[chat.id] = objectIDs
            }
        }
        return AgentDeactivationPlan(
            agentID: agentID,
            groupParticipantObjectIDs: groupParticipantObjectIDs
        )
    }

    @discardableResult
    func applyAgentDeactivation(_ plan: AgentDeactivationPlan) -> Bool {
        for chat in groupChats {
            guard let objectIDs = plan.groupParticipantObjectIDs[chat.id] else { continue }
            chat.removeGroupParticipantsFromLiveRoster(objectIDs: objectIDs)
        }

        let selectedChatWasRemoved = selectedChat.map {
            !$0.isGroupChat && $0.agentID == plan.agentID
        } ?? false
        chats.removeAll { !$0.isGroupChat && $0.agentID == plan.agentID }
        if selectedChatWasRemoved {
            selectedChatID = nil
        }
        refreshChatActivityObservations()
        return selectedChatWasRemoved
    }

    func resetChat(_ chat: ChatViewModel) {
        chat.resetActiveHistory()
    }

    func deleteChat(_ chat: ChatViewModel) {
        guard chat.canDelete, !chat.isResponding else { return }

        let chatID = chat.id
        let agentID = chat.agentID
        let wasSelected = selectedChatID == chatID
        chat.deletePersistedRecords()
        chats.removeAll { $0.id == chatID }
        refreshChatActivityObservations()
        if wasSelected {
            selectedChatID = defaultChat(for: agentID)?.id ?? chats.first?.id
        }
    }

    private func ensureDefaultChats(for agents: [Agent]) {
        for agent in agents {
            let directs = chats.filter { !$0.isGroupChat && $0.agentID == agent.id }
            let defaults = directs.filter(\.isDefaultChat)
            if defaults.count == 1 {
                defaults[0].synchronizeDefaultChat(with: agent)
                continue
            }
            if defaults.count > 1 {
                let keepID = preferredDefault(from: defaults)?.id
                for chat in defaults where chat.id != keepID {
                    chat.setDefaultChat(false)
                }
                preferredDefault(from: defaults)?.synchronizeDefaultChat(with: agent)
                continue
            }
            if let candidate = preferredDefault(from: directs) {
                candidate.setDefaultChat(true)
                candidate.synchronizeDefaultChat(with: agent)
            } else {
                _ = makeDirectChat(with: agent, isDefault: true)
            }
        }
    }

    private func preferredDefault(from chats: [ChatViewModel]) -> ChatViewModel? {
        chats.max { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt < rhs.updatedAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    func addFakeMessagesToSelectedChat(count: Int) {
        selectedChat?.addFakeMessages(count: count)
    }

    func addSlowResponseToSelectedChat() {
        selectedChat?.addSlowResponse()
    }

    func backendPersistenceName(for modelIdentifier: String) -> String {
        localModelStore.backend(for: modelIdentifier).persistenceName
    }

    func executeHeartbeat(
        _ heartbeat: AgentHeartbeat,
        runID: UUID,
        turnID: UUID,
        recorder: ToolCallRecorder,
        debugCaptureEnabled: Bool,
        onDestinationChat: ((UUID) -> Void)? = nil,
        onDebugPrompt: ((String, String) -> Void)? = nil,
        onModelResponseAccepted: (() -> Void)? = nil
    ) async -> HeartbeatExecutionReport {
        let startedAt = Date()
        let fallbackAgentName = "Deleted agent"
        let instruction = heartbeat.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let unresolvedDestination = heartbeatDestinationDescription(for: heartbeat)

        if Task.isCancelled {
            return failedHeartbeatReport(
                agentName: agentStore.agent(for: heartbeat.agentID)?.displayName ?? fallbackAgentName,
                instruction: instruction,
                destination: unresolvedDestination,
                startedAt: startedAt,
                runID: runID,
                turnID: turnID,
                chatID: nil,
                debugCaptureEnabled: debugCaptureEnabled,
                modelIdentifier: heartbeat.modelIdentifier ?? "",
                backendRawValue: ChatBackend.missingLocalModel.persistenceName,
                toolInvocations: recorder.snapshot(),
                error: HeartbeatModelFailure(
                    modelInput: "",
                    modelOutput: nil,
                    message: "Aborted by user.",
                    wasAborted: true,
                    runID: runID,
                    turnID: turnID,
                    chatID: nil,
                    debugCaptureEnabled: debugCaptureEnabled,
                    toolInvocations: recorder.snapshot(),
                    debug: nil,
                    backendRawValue: ChatBackend.missingLocalModel.persistenceName
                )
            )
        }

        guard let agent = agentStore.agent(for: heartbeat.agentID) else {
            return failedHeartbeatReport(
                agentName: fallbackAgentName,
                instruction: instruction,
                destination: unresolvedDestination,
                startedAt: startedAt,
                runID: runID,
                turnID: turnID,
                chatID: nil,
                debugCaptureEnabled: debugCaptureEnabled,
                modelIdentifier: heartbeat.modelIdentifier ?? "",
                backendRawValue: ChatBackend.missingLocalModel.persistenceName,
                toolInvocations: recorder.snapshot(),
                error: HeartbeatExecutionError.agentMissing
            )
        }

        guard !instruction.isEmpty else {
            let modelIdentifier = heartbeat.modelIdentifier ?? agent.selectedModelIdentifier
            return failedHeartbeatReport(
                agentName: agent.displayName,
                instruction: instruction,
                destination: unresolvedDestination,
                startedAt: startedAt,
                runID: runID,
                turnID: turnID,
                chatID: nil,
                debugCaptureEnabled: debugCaptureEnabled,
                modelIdentifier: modelIdentifier,
                backendRawValue: backendPersistenceName(for: modelIdentifier),
                toolInvocations: recorder.snapshot(),
                error: HeartbeatExecutionError.emptyInstruction
            )
        }

        let targetChat: ChatViewModel
        switch heartbeat.targetKind {
        case .privateChat:
            if let targetChatID = heartbeat.targetChatID {
                guard let privateChat = chats.first(where: {
                    $0.id == targetChatID && !$0.isGroupChat && $0.agentID == agent.id
                }) else {
                    let modelIdentifier = heartbeat.modelIdentifier ?? agent.selectedModelIdentifier
                    return failedHeartbeatReport(
                        agentName: agent.displayName,
                        instruction: instruction,
                        destination: unresolvedDestination,
                        startedAt: startedAt,
                        runID: runID,
                        turnID: turnID,
                        chatID: nil,
                        debugCaptureEnabled: debugCaptureEnabled,
                        modelIdentifier: modelIdentifier,
                        backendRawValue: backendPersistenceName(for: modelIdentifier),
                        toolInvocations: recorder.snapshot(),
                        error: HeartbeatExecutionError.targetMissing
                    )
                }
                targetChat = privateChat
            } else {
                targetChat = defaultChat(for: agent.id) ?? makeDirectChat(with: agent, isDefault: true)
            }
        case .groupChat:
            guard let targetChatID = heartbeat.targetChatID,
                  let groupChat = chats.first(where: { $0.id == targetChatID && $0.isGroupChat }) else {
                let modelIdentifier = heartbeat.modelIdentifier ?? agent.selectedModelIdentifier
                return failedHeartbeatReport(
                    agentName: agent.displayName,
                    instruction: instruction,
                    destination: unresolvedDestination,
                    startedAt: startedAt,
                    runID: runID,
                    turnID: turnID,
                    chatID: nil,
                    debugCaptureEnabled: debugCaptureEnabled,
                    modelIdentifier: modelIdentifier,
                    backendRawValue: backendPersistenceName(for: modelIdentifier),
                    toolInvocations: recorder.snapshot(),
                    error: HeartbeatExecutionError.targetMissing
                )
            }
            targetChat = groupChat
        }

        onDestinationChat?(targetChat.id)
        let destination = targetChat.heartbeatDestinationDescription
        let modelIdentifier = heartbeat.modelIdentifier ?? agent.selectedModelIdentifier
        let backendRawValue = backendPersistenceName(for: modelIdentifier)
        do {
            let exchange = try await targetChat.executeHeartbeat(
                as: agent,
                instruction: instruction,
                modelIdentifier: modelIdentifier,
                lastCompletedAt: heartbeat.lastCompletedAt,
                referenceDate: startedAt,
                runID: runID,
                turnID: turnID,
                recorder: recorder,
                debugCaptureEnabled: debugCaptureEnabled,
                onDebugPrompt: onDebugPrompt,
                onModelResponseAccepted: onModelResponseAccepted
            )
            return HeartbeatExecutionReport(
                agentName: agent.displayName,
                instruction: instruction,
                destination: destination,
                startedAt: startedAt,
                completedAt: .now,
                modelInput: "",
                modelOutput: nil,
                actionSummary: exchange.actionSummary,
                errorMessage: nil,
                retryDelay: nil,
                runID: exchange.runID,
                turnID: exchange.turnID,
                chatID: exchange.chatID,
                debugCaptureEnabled: exchange.debugCaptureEnabled,
                generationStatus: exchange.generationStatus,
                assistantMessageID: exchange.assistantMessageID,
                visibleReplyPreview: exchange.visibleReplyPreview,
                memoryEntryCount: exchange.memoryEntryCount,
                modelIdentifier: modelIdentifier,
                backendRawValue: exchange.backendRawValue,
                toolInvocations: exchange.toolInvocations,
                debug: exchange.debug,
                promptTokenCount: exchange.tokenUsage.isEmpty ? nil : exchange.tokenUsage.promptTokens,
                completionTokenCount: exchange.tokenUsage.isEmpty ? nil : exchange.tokenUsage.completionTokens
            )
        } catch let error as HeartbeatModelFailure {
            return failedHeartbeatReport(
                agentName: agent.displayName,
                instruction: instruction,
                destination: destination,
                startedAt: startedAt,
                runID: error.runID,
                turnID: error.turnID,
                chatID: error.chatID ?? targetChat.id,
                debugCaptureEnabled: error.debugCaptureEnabled,
                modelIdentifier: modelIdentifier,
                backendRawValue: error.backendRawValue.isEmpty ? backendRawValue : error.backendRawValue,
                toolInvocations: error.toolInvocations,
                debug: error.debug,
                error: error
            )
        } catch {
            return failedHeartbeatReport(
                agentName: agent.displayName,
                instruction: instruction,
                destination: destination,
                startedAt: startedAt,
                runID: runID,
                turnID: turnID,
                chatID: targetChat.id,
                debugCaptureEnabled: debugCaptureEnabled,
                modelIdentifier: modelIdentifier,
                backendRawValue: backendRawValue,
                toolInvocations: recorder.snapshot(),
                error: error
            )
        }
    }

    func heartbeatDestinationDescription(for heartbeat: AgentHeartbeat) -> String {
        switch heartbeat.targetKind {
        case .privateChat:
            if let targetChatID = heartbeat.targetChatID {
                guard let chat = chats.first(where: {
                    $0.id == targetChatID && !$0.isGroupChat && $0.agentID == heartbeat.agentID
                }) else {
                    return "Missing private chat"
                }
                return chat.heartbeatDestinationDescription
            }
            if let chat = defaultChat(for: heartbeat.agentID) {
                return chat.heartbeatDestinationDescription
            }
            return "Default chat"
        case .groupChat:
            guard let targetChatID = heartbeat.targetChatID,
                  let chat = chats.first(where: { $0.id == targetChatID && $0.isGroupChat }) else {
                return "Missing group chat"
            }
            return chat.heartbeatDestinationDescription
        }
    }

    private func failedHeartbeatReport(
        agentName: String,
        instruction: String,
        destination: String,
        startedAt: Date,
        runID: UUID,
        turnID: UUID,
        chatID: UUID?,
        debugCaptureEnabled: Bool,
        modelIdentifier: String,
        backendRawValue: String,
        toolInvocations: [CapturedToolInvocation],
        debug: GenerationDebugPayloadDraft? = nil,
        error: Error
    ) -> HeartbeatExecutionReport {
        let wasAborted = (error as? HeartbeatModelFailure)?.wasAborted == true
        let actionSummary: String
        if wasAborted {
            actionSummary = "Run was aborted. No chat message was posted."
        } else {
            actionSummary = "No chat message was posted."
        }

        return HeartbeatExecutionReport(
            agentName: agentName,
            instruction: instruction,
            destination: destination,
            startedAt: startedAt,
            completedAt: Date(),
            modelInput: "",
            modelOutput: nil,
            actionSummary: actionSummary,
            errorMessage: wasAborted ? "Aborted by user." : error.localizedDescription,
            retryDelay: nil,
            runID: runID,
            turnID: turnID,
            chatID: chatID,
            debugCaptureEnabled: debugCaptureEnabled,
            generationStatus: wasAborted ? .aborted : .failed,
            assistantMessageID: nil,
            visibleReplyPreview: nil,
            memoryEntryCount: 0,
            modelIdentifier: modelIdentifier,
            backendRawValue: backendRawValue,
            toolInvocations: toolInvocations,
            debug: debugCaptureEnabled ? debug : nil,
            promptTokenCount: storedTokenUsage(from: error)?.promptTokens,
            completionTokenCount: storedTokenUsage(from: error)?.completionTokens
        )
    }

    private func storedTokenUsage(from error: Error) -> TokenUsage? {
        let usage = (error as? HeartbeatModelFailure)?.tokenUsage ?? .zero
        return usage.isEmpty ? nil : usage
    }

    private func loadChats() {
        let descriptor = FetchDescriptor<StoredChat>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )

        do {
            let storedChats = try modelContext.fetch(descriptor)
            let activeAgentIDs = Set(agentStore.agents.map(\.id))
            chats = storedChats.compactMap { storedChat in
                guard storedChat.kind == .group || activeAgentIDs.contains(storedChat.agentID) else {
                    return nil
                }
                return ChatViewModel(
                    storedChat: storedChat,
                    storedMessages: ActiveChatMessages.fetch(
                        chatID: storedChat.id,
                        clearedThroughMessageID: storedChat.clearedThroughMessageID,
                        limit: ChatStore.messageBatchSize,
                        in: modelContext
                    ),
                    storedGroupParticipants: fetchGroupParticipants(
                        for: storedChat.id,
                        activeAgentIDs: activeAgentIDs
                    ),
                    agentStore: agentStore,
                    localModelStore: localModelStore,
                    skillCatalog: skillCatalog,
                    replyFilterStore: replyFilterStore,
                    modelContext: modelContext
                )
            }
        } catch {
            chats = []
        }
        refreshChatActivityObservations()
    }

    private func fetchGroupParticipants(
        for chatID: UUID,
        activeAgentIDs: Set<Agent.ID>
    ) -> [StoredGroupChatParticipant] {
        let descriptor = FetchDescriptor<StoredGroupChatParticipant>(
            predicate: #Predicate { participant in
                participant.chatID == chatID
            },
            sortBy: [SortDescriptor(\.createdAt)]
        )

        do {
            return try modelContext.fetch(descriptor).filter {
                activeAgentIDs.contains($0.agentID)
            }
        } catch {
            return []
        }
    }

    private func refreshChatActivityObservations() {
        chatActivityCancellables = Dictionary(uniqueKeysWithValues: chats.map { chat in
            let cancellable = chat.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            return (chat.id, cancellable)
        })
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

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    let role: ChatRole
    let text: String
    let authorAgentID: UUID?
    let authorName: String?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        role: ChatRole,
        text: String,
        authorAgentID: UUID? = nil,
        authorName: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.authorAgentID = authorAgentID
        self.authorName = authorName
        self.createdAt = createdAt
    }

    init(storedMessage: StoredChatMessage, fallbackAssistantName: String? = nil) {
        id = storedMessage.id
        role = storedMessage.role
        text = storedMessage.text
        authorAgentID = storedMessage.authorAgentID
        authorName = storedMessage.authorName ?? (storedMessage.role == .assistant ? fallbackAssistantName : nil)
        createdAt = storedMessage.createdAt
    }
}

enum ChatRole: String {
    case user
    case assistant
}

enum ActiveChatMessages {
    static func fetch(
        chatID: UUID,
        clearedThroughMessageID: UUID?,
        olderThan: Date? = nil,
        limit: Int? = nil,
        in modelContext: ModelContext
    ) -> [StoredChatMessage] {
        let cutoff = cutoffDate(
            clearedThroughMessageID: clearedThroughMessageID,
            in: modelContext
        )
        let newestFirst = limit != nil
        var descriptor = messageDescriptor(
            chatID: chatID,
            cutoff: cutoff,
            olderThan: olderThan,
            newestFirst: newestFirst
        )
        if let limit {
            descriptor.fetchLimit = limit
        }

        do {
            let fetched = try modelContext.fetch(descriptor)
            return newestFirst ? fetched.reversed() : fetched
        } catch {
            return []
        }
    }

    static func fetchAll(
        chatID: UUID,
        in modelContext: ModelContext
    ) -> [StoredChatMessage] {
        let descriptor = FetchDescriptor<StoredChatMessage>(
            predicate: #Predicate { message in
                message.chatID == chatID
            },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private static func cutoffDate(
        clearedThroughMessageID: UUID?,
        in modelContext: ModelContext
    ) -> Date? {
        guard let clearedThroughMessageID else { return nil }

        var descriptor = FetchDescriptor<StoredChatMessage>(
            predicate: #Predicate { message in
                message.id == clearedThroughMessageID
            }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first?.createdAt
    }

    private static func messageDescriptor(
        chatID: UUID,
        cutoff: Date?,
        olderThan: Date?,
        newestFirst: Bool
    ) -> FetchDescriptor<StoredChatMessage> {
        let sort = SortDescriptor<StoredChatMessage>(
            \.createdAt,
            order: newestFirst ? .reverse : .forward
        )
        if let olderThan, let cutoff {
            return FetchDescriptor(
                predicate: #Predicate { message in
                    message.chatID == chatID
                        && message.createdAt > cutoff
                        && message.createdAt < olderThan
                },
                sortBy: [sort]
            )
        }
        if let olderThan {
            return FetchDescriptor(
                predicate: #Predicate { message in
                    message.chatID == chatID && message.createdAt < olderThan
                },
                sortBy: [sort]
            )
        }
        if let cutoff {
            return FetchDescriptor(
                predicate: #Predicate { message in
                    message.chatID == chatID && message.createdAt > cutoff
                },
                sortBy: [sort]
            )
        }
        return FetchDescriptor(
            predicate: #Predicate { message in
                message.chatID == chatID
            },
            sortBy: [sort]
        )
    }
}
