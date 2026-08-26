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
        updatedAt: Date = .now
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
    private static let messageBatchSize = 40

    @Published var chats: [ChatViewModel] = []
    @Published var selectedChatID: ChatViewModel.ID?

    private let modelContext: ModelContext
    private let agentStore: AgentStore
    private let localModelStore: LocalModelStore
    private let skillCatalog: SkillCatalog
    private let replyFilterStore: ReplyFilterStore

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

        if chats.isEmpty, let agent = agentStore.agents.first {
            startChat(with: agent)
        } else {
            selectedChatID = chats.first?.id
        }
    }

    func startChat(with agent: Agent) {
        let chat = makeDirectChat(with: agent)
        selectedChatID = chat.id
    }

    private func makeDirectChat(with agent: Agent) -> ChatViewModel {
        let storedChat = StoredChat(
            agentID: agent.id,
            agentName: agent.displayName,
            agentSoul: agent.soul,
            agentModelIdentifier: agent.selectedModelIdentifier
        )
        modelContext.insert(storedChat)

        let greeting = StoredChatMessage(
            chatID: storedChat.id,
            role: .assistant,
            text: "New chat with \(agent.displayName). What would you like to ask?",
            authorAgentID: agent.id,
            authorName: agent.displayName
        )
        modelContext.insert(greeting)
        saveChanges()

        let chat = ChatViewModel(
            storedChat: storedChat,
            storedMessages: [greeting],
            storedGroupParticipants: [],
            agentStore: agentStore,
            localModelStore: localModelStore,
            skillCatalog: skillCatalog,
            replyFilterStore: replyFilterStore,
            modelContext: modelContext
        )
        chats.insert(chat, at: 0)
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
        selectedChatID = chat.id
    }

    func chats(for agentID: Agent.ID) -> [ChatViewModel] {
        chats.filter { !$0.isGroupChat && $0.agentID == agentID }
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
        _ heartbeat: AgentHeartbeat,
        onModelInput: ((String) -> Void)? = nil,
        onModelResponseAccepted: (() -> Void)? = nil
    ) async -> HeartbeatExecutionReport {
        let startedAt = Date()
        let fallbackAgentName = "Deleted agent"
        let instruction = heartbeat.instruction.trimmingCharacters(in: .whitespacesAndNewlines)

        if Task.isCancelled {
            return failedHeartbeatReport(
                agentName: agentStore.agent(for: heartbeat.agentID)?.displayName ?? fallbackAgentName,
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

        guard let agent = agentStore.agent(for: heartbeat.agentID) else {
            return failedHeartbeatReport(
                agentName: fallbackAgentName,
                instruction: instruction,
                destination: heartbeatDestinationDescription(for: heartbeat),
                startedAt: startedAt,
                error: HeartbeatExecutionError.agentMissing
            )
        }

        guard !instruction.isEmpty else {
            return failedHeartbeatReport(
                agentName: agent.displayName,
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
                .filter { !$0.isGroupChat && $0.agentID == agent.id }
                .max { $0.updatedAt < $1.updatedAt }
                ?? makeDirectChat(with: agent)
        case .groupChat:
            guard let targetChatID = heartbeat.targetChatID,
                  let groupChat = chats.first(where: { $0.id == targetChatID && $0.isGroupChat }) else {
                return failedHeartbeatReport(
                    agentName: agent.displayName,
                    instruction: instruction,
                    destination: heartbeatDestinationDescription(for: heartbeat),
                    startedAt: startedAt,
                    error: HeartbeatExecutionError.targetMissing
                )
            }
            targetChat = groupChat
        }

        let destination = targetChat.heartbeatDestinationDescription
        let modelIdentifier = heartbeat.modelIdentifier ?? agent.selectedModelIdentifier
        do {
            let exchange = try await targetChat.executeHeartbeat(
                as: agent,
                instruction: instruction,
                modelIdentifier: modelIdentifier,
                lastCompletedAt: heartbeat.lastCompletedAt,
                referenceDate: startedAt,
                onModelInput: onModelInput,
                onModelResponseAccepted: onModelResponseAccepted
            )
            return HeartbeatExecutionReport(
                agentName: agent.displayName,
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
                agentName: agent.displayName,
                instruction: instruction,
                destination: destination,
                startedAt: startedAt,
                modelInput: error.modelInput,
                modelOutput: error.modelOutput,
                error: error
            )
        } catch {
            return failedHeartbeatReport(
                agentName: agent.displayName,
                instruction: instruction,
                destination: destination,
                startedAt: startedAt,
                error: error
            )
        }
    }

    func heartbeatDestinationDescription(for heartbeat: AgentHeartbeat) -> String {
        switch heartbeat.targetKind {
        case .privateChat:
            guard let chat = chats
                .filter({ !$0.isGroupChat && $0.agentID == heartbeat.agentID })
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
        agentName: String,
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
            agentName: agentName,
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
