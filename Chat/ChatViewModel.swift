import Combine
import Foundation
import SwiftData

@MainActor
final class ChatViewModel: ObservableObject, Identifiable {
    static let typingIndicatorID = UUID()
    private static let messageBatchSize = 40

    var id: UUID { storedChat.id }
    var agentID: Agent.ID { storedChat.agentID }
    var agentName: String { storedChat.agentName }
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
    @Published private(set) var respondingAgentName: String?
    @Published private(set) var availabilityMessage = ""
    @Published private(set) var canSend = false

    private let modelContext: ModelContext
    private let storedChat: StoredChat
    private let agentStore: AgentStore
    private let localModelStore: LocalModelStore
    private let skillCatalog: SkillCatalog
    private let replyFilterStore: ReplyFilterStore
    private let backend: ChatBackend

    var canSubmitDraft: Bool {
        canSend && !isResponding && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(
        storedChat: StoredChat,
        storedMessages: [StoredChatMessage],
        storedGroupParticipants: [StoredGroupChatParticipant],
        agentStore: AgentStore,
        localModelStore: LocalModelStore,
        skillCatalog: SkillCatalog,
        replyFilterStore: ReplyFilterStore,
        modelContext: ModelContext
    ) {
        self.storedChat = storedChat
        self.agentStore = agentStore
        self.localModelStore = localModelStore
        self.skillCatalog = skillCatalog
        self.replyFilterStore = replyFilterStore
        self.modelContext = modelContext
        title = storedChat.title
        let fallbackAssistantName = storedChat.kind == .direct ? storedChat.agentName : nil
        messages = storedMessages.map {
            ChatMessage(storedMessage: $0, fallbackAssistantName: fallbackAssistantName)
        }
        groupParticipants = storedGroupParticipants
        groupSystemInstructions = storedChat.groupSystemInstructions ?? ""
        respondingAgentName = nil
        hasOlderMessages = storedMessages.count == ChatViewModel.messageBatchSize
        backend = localModelStore.backend(for: storedChat.agentModelIdentifier)
        updateAvailability()
    }

    var groupParticipantMentions: [String] {
        groupParticipants.map(\.mention)
    }

    var availableAgentMentions: [String] {
        var mentions = groupParticipantMentions
        mentions.append(contentsOf: agentStore.agents.map(\.mention))
        return Array(Set(mentions)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    var composerPlaceholder: String {
        guard isGroupChat, groupParticipants.isEmpty else { return "Message" }
        guard let firstMention = availableAgentMentions.first else {
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
            let fallbackAssistantName = isGroupChat ? nil : storedChat.agentName
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
                authorAgentID: role == .assistant ? groupParticipants.first?.agentID ?? agentID : nil,
                authorName: role == .assistant ? groupParticipants.first?.agentName ?? agentName : nil,
                createdAt: Date().addingTimeInterval(TimeInterval(offset) * 0.001)
            )
        }

        for storedMessage in storedMessages {
            modelContext.insert(storedMessage)
        }

        storedChat.updatedAt = .now
        saveChanges()
        messages.append(contentsOf: storedMessages.map {
            ChatMessage(storedMessage: $0, fallbackAssistantName: isGroupChat ? nil : agentName)
        })
    }

    func addSlowResponse() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            let participant = groupParticipants.first
            appendMessage(
                role: .assistant,
                text: "Slow response",
                authorAgentID: participant?.agentID ?? (isGroupChat ? nil : agentID),
                authorName: participant?.agentName ?? (isGroupChat ? nil : agentName)
            )
        }
    }

    func send() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)

        guard canSubmitDraft, !prompt.isEmpty else { return }

        if isGroupChat {
            let mentionedHandles = AgentMention.handles(in: prompt)
            addMentionedAgents(matching: mentionedHandles)

            guard !groupParticipants.isEmpty else {
                availabilityMessage = availableAgentMentions.isEmpty
                    ? "Create an agent before starting this group discussion."
                    : "Mention an agent, such as \(availableAgentMentions[0]), to add them."
                return
            }

            let directlyMentionedAgentIDs = Set(
                groupParticipants
                    .filter { mentionedHandles.contains(AgentMention.handle(for: $0.agentName).lowercased()) }
                    .map(\.agentID)
            )

            if title == "Untitled chat" {
                updateTitle(String(prompt.prefix(48)))
            }

            draft = ""
            appendMessage(role: .user, text: prompt)
            isResponding = true

            Task {
                await respondAsGroup(directlyMentionedAgentIDs: directlyMentionedAgentIDs)
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
        as agent: Agent,
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
            addGroupParticipantIfNeeded(agent)
        }

        isResponding = true
        respondingAgentName = agent.displayName
        defer {
            respondingAgentName = nil
            isResponding = false
            updateAvailability()
        }

        let storedMessages = allStoredMessages()
        let generation = generationSupport(for: agent)
        let systemInstructions = ModelPrompts.heartbeatSystemInstructions(
            agentName: agent.displayName,
            soul: agent.soul,
            memory: agent.memoryText,
            isGroupChat: isGroupChat,
            groupInstructions: groupSystemInstructions,
            skillsPrompt: generation.skillsPrompt
        )
        let conversationPrompt = ModelPrompts.heartbeatConversationPrompt(
            agentName: agent.displayName,
            instruction: instruction,
            isGroupChat: isGroupChat,
            transcript: ModelPrompts.heartbeatTranscript(
                messages: storedMessages,
                isGroupChat: isGroupChat,
                fallbackAgentName: storedChat.agentName,
                relativeTo: referenceDate
            ),
            lastCompletedAt: lastCompletedAt,
            unansweredMessageCount: ModelPrompts.unansweredMessageCount(in: storedMessages),
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
            response = try await ModelClient.complete(
                using: localModelStore.backend(for: modelIdentifier),
                systemPrompt: systemInstructions,
                prompt: conversationPrompt,
                tools: generation.tools,
                missingLocalModelMessage: "The selected local model is no longer configured."
            )
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

        let parsedResponse = sanitizedReply(
            response,
            modelIdentifier: modelIdentifier
        )
        agentStore.appendAgentMemoryEntries(
            id: agent.id,
            entries: parsedResponse.output.memoryEntries
        )

        let visibleText = parsedResponse.output.visibleText
        let passed = parsedResponse.isPass
        let posted = !visibleText.isEmpty && !passed
        if posted {
            appendMessage(
                role: .assistant,
                text: visibleText,
                authorAgentID: agent.id,
                authorName: agent.displayName
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

        let memoryCount = parsedResponse.output.memoryEntries.count
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
            let storedMessages = allStoredMessages()
            let generation = generationSupport(for: agentStore.agent(for: storedChat.agentID))
            let systemInstructions = ModelPrompts.agentSystemInstructions(
                agentName: storedChat.agentName,
                soul: currentSoul(
                    for: storedChat.agentID,
                    fallback: storedChat.agentSoul
                ),
                memory: currentMemory(for: storedChat.agentID),
                skillsPrompt: generation.skillsPrompt
            )
            let appleFoundationPrompt = ModelPrompts.directConversationPrompt(
                agentName: storedChat.agentName,
                transcript: ModelPrompts.conversationTranscript(
                    messages: storedMessages,
                    isGroupChat: false,
                    fallbackAgentName: storedChat.agentName
                )
            )
            let response = try await ModelClient.complete(
                using: backend,
                systemPrompt: systemInstructions,
                messages: storedMessages.map {
                    ChatMessage(storedMessage: $0, fallbackAssistantName: storedChat.agentName)
                },
                appleFoundationPrompt: appleFoundationPrompt,
                tools: generation.tools,
                missingLocalModelMessage: "This chat's local model is no longer configured. Choose a configured model for the agent and start a new chat."
            )
            let parsedResponse = sanitizedReply(
                response,
                modelIdentifier: storedChat.agentModelIdentifier
            )
            agentStore.appendAgentMemoryEntries(
                id: storedChat.agentID,
                entries: parsedResponse.output.memoryEntries
            )
            if !parsedResponse.output.visibleText.isEmpty, !parsedResponse.isPass {
                appendMessage(
                    role: .assistant,
                    text: parsedResponse.output.visibleText,
                    authorAgentID: agentID,
                    authorName: agentName
                )
            }
        } catch {
            appendMessage(
                role: .assistant,
                text: "I could not get a response: \(error.localizedDescription)",
                authorAgentID: agentID,
                authorName: agentName
            )
        }

        isResponding = false
        updateAvailability()
    }

    private func addMentionedAgents(matching mentionedHandles: Set<String>) {
        let existingAgentIDs = Set(groupParticipants.map(\.agentID))
        let newAgents = agentStore.agents.filter { agent in
            !existingAgentIDs.contains(agent.id)
                && mentionedHandles.contains(AgentMention.handle(for: agent.displayName).lowercased())
        }

        guard !newAgents.isEmpty else { return }

        for agent in newAgents {
            let participant = StoredGroupChatParticipant(chatID: id, agent: agent)
            modelContext.insert(participant)
            groupParticipants.append(participant)
        }

        storedChat.updatedAt = .now
        saveChanges()
        updateAvailability()
    }

    private func addGroupParticipantIfNeeded(_ agent: Agent) {
        guard isGroupChat,
              !groupParticipants.contains(where: { $0.agentID == agent.id }) else {
            return
        }

        let participant = StoredGroupChatParticipant(chatID: id, agent: agent)
        modelContext.insert(participant)
        groupParticipants.append(participant)
        storedChat.updatedAt = .now
        saveChanges()
        updateAvailability()
    }

    private func respondAsGroup(directlyMentionedAgentIDs: Set<UUID>) async {
        let orderedParticipants = groupParticipants.sorted { left, right in
            let leftWasMentioned = directlyMentionedAgentIDs.contains(left.agentID)
            let rightWasMentioned = directlyMentionedAgentIDs.contains(right.agentID)
            if leftWasMentioned != rightWasMentioned {
                return leftWasMentioned
            }
            return left.createdAt < right.createdAt
        }

        for participant in orderedParticipants {
            guard !Task.isCancelled else { break }
            respondingAgentName = participant.agentName

            do {
                let response = try await groupResponse(
                    from: participant,
                    wasDirectlyMentioned: directlyMentionedAgentIDs.contains(participant.agentID)
                )
                let parsedResponse = sanitizedReply(
                    response,
                    modelIdentifier: participant.agentModelIdentifier
                )
                agentStore.appendAgentMemoryEntries(
                    id: participant.agentID,
                    entries: parsedResponse.output.memoryEntries
                )
                let trimmedResponse = parsedResponse.output.visibleText
                if !trimmedResponse.isEmpty, !parsedResponse.isPass {
                    appendMessage(
                        role: .assistant,
                        text: trimmedResponse,
                        authorAgentID: participant.agentID,
                        authorName: participant.agentName
                    )
                }
            } catch {
                appendMessage(
                    role: .assistant,
                    text: "I could not get a response: \(error.localizedDescription)",
                    authorAgentID: participant.agentID,
                    authorName: participant.agentName
                )
            }
        }

        respondingAgentName = nil
        isResponding = false
        updateAvailability()
    }

    private func groupResponse(
        from participant: StoredGroupChatParticipant,
        wasDirectlyMentioned: Bool
    ) async throws -> String {
        let storedMessages = allStoredMessages()
        let generation = generationSupport(for: agentStore.agent(for: participant.agentID))
        let systemInstructions = ModelPrompts.groupSystemPrompt(
            agentName: participant.agentName,
            soul: currentSoul(
                for: participant.agentID,
                fallback: participant.agentSoul
            ),
            memory: currentMemory(for: participant.agentID),
            groupInstructions: groupSystemInstructions,
            skillsPrompt: generation.skillsPrompt
        )
        let conversationPrompt = ModelPrompts.groupConversationPrompt(
            agentName: participant.agentName,
            transcript: ModelPrompts.conversationTranscript(
                messages: storedMessages,
                isGroupChat: true,
                fallbackAgentName: storedChat.agentName
            ),
            wasDirectlyMentioned: wasDirectlyMentioned
        )

        return try await ModelClient.complete(
            using: localModelStore.backend(for: participant.agentModelIdentifier),
            systemPrompt: systemInstructions,
            prompt: conversationPrompt,
            tools: generation.tools,
            missingLocalModelMessage: "This agent's local model is no longer configured."
        )
    }

    private func generationSupport(for agent: Agent?) -> (tools: AgentToolBox, skillsPrompt: String) {
        let tools = AgentToolBox.make(agent: agent, catalog: skillCatalog)
        return (tools, ModelPrompts.skillsPrompt(for: tools.runtime.skills))
    }

    private func sanitizedReply(_ response: String, modelIdentifier: String?) -> (output: AgentModelOutput, isPass: Bool) {
        ReplySanitizer.process(
            response,
            patterns: replyFilterStore.patterns(
                for: modelIdentifier ?? ChatModelIdentifier.appleFoundation
            )
        )
    }

    private func currentMemory(for agentID: Agent.ID) -> String {
        agentStore.agent(for: agentID)?.memoryText ?? ""
    }

    private func currentSoul(for agentID: Agent.ID, fallback: String) -> String {
        agentStore.agent(for: agentID)?.soul ?? fallback
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

    private func appendMessage(
        role: ChatRole,
        text: String,
        authorAgentID: UUID? = nil,
        authorName: String? = nil
    ) {
        let storedMessage = StoredChatMessage(
            chatID: id,
            role: role,
            text: text,
            authorAgentID: authorAgentID,
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
            canSend = !agentStore.agents.isEmpty || !groupParticipants.isEmpty

            if groupParticipants.isEmpty {
                if let firstMention = availableAgentMentions.first {
                    availabilityMessage = "Mention \(firstMention) to add an agent to the discussion."
                } else {
                    availabilityMessage = "Create an agent before starting this group discussion."
                }
            } else {
                let count = groupParticipants.count
                availabilityMessage = count == 1
                    ? "1 agent is in this discussion."
                    : "\(count) agents are in this discussion."
            }
            return
        }

        let availability = ModelClient.availability(for: backend)
        canSend = availability.canSend
        availabilityMessage = availability.message
    }

    private func saveChanges() {
        guard modelContext.hasChanges else { return }

        do {
            try modelContext.save()
        } catch {
            assertionFailure("Failed to save chat: \(error.localizedDescription)")
        }
    }
}
