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
    var isDefaultChat: Bool { storedChat.isDefaultChat == true }
    var canDelete: Bool { !isDefaultChat }
    var canRename: Bool { !isDefaultChat }
    var updatedAt: Date { storedChat.updatedAt }
    var displayTitle: String {
        if isDefaultChat {
            return agentStore.agent(for: agentID)?.displayName ?? storedChat.agentName
        }
        return title
    }
    var heartbeatDestinationDescription: String {
        if isGroupChat {
            return "Group chat “\(title)”"
        }
        if isDefaultChat {
            return "Default chat"
        }
        return "Private chat “\(title)”"
    }

    @Published var draft = ""
    @Published private(set) var title: String
    @Published private(set) var messages: [ChatMessage]
    @Published private(set) var groupParticipants: [StoredGroupChatParticipant]
    @Published private(set) var groupSystemInstructions: String
    @Published private(set) var isLoadingOlderMessages = false
    @Published private(set) var hasOlderMessages: Bool
    @Published private(set) var isResponding = false
    @Published private(set) var isCompacting = false
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

    var rendersMarkdown: Bool {
        storedChat.rendersMarkdown ?? true
    }

    func setRendersMarkdown(_ enabled: Bool) {
        storedChat.rendersMarkdown = enabled
        saveChanges()
        objectWillChange.send()
    }

    var compactionStatus: ConversationCompactionStatus {
        let summary = (storedChat.compactedSummary ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ConversationCompactionStatus(
            summary: summary,
            compactedAt: storedChat.compactedAt,
            coveredMessageCount: storedChat.compactedMessageCount,
            estimatedTokens: ConversationCompaction.estimateTokens(summary)
        )
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

        let fallbackAssistantName = isGroupChat ? nil : storedChat.agentName
        let olderMessages = ActiveChatMessages.fetch(
            chatID: id,
            clearedThroughMessageID: storedChat.clearedThroughMessageID,
            olderThan: oldestMessage.createdAt,
            limit: ChatViewModel.messageBatchSize,
            in: modelContext
        ).map {
            ChatMessage(storedMessage: $0, fallbackAssistantName: fallbackAssistantName)
        }
        hasOlderMessages = olderMessages.count == ChatViewModel.messageBatchSize
        messages.insert(contentsOf: olderMessages, at: 0)
    }

    func rename(to title: String) {
        guard canRename else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = isGroupChat ? "Untitled chat" : "New chat"
        updateTitle(trimmedTitle.isEmpty ? fallbackTitle : trimmedTitle)
    }

    func resetActiveHistory() {
        guard !isResponding, !isCompacting else { return }

        let allMessages = ActiveChatMessages.fetchAll(chatID: id, in: modelContext)
        if let lastMessage = allMessages.last {
            storedChat.clearedThroughMessageID = lastMessage.id
        }
        storedChat.compactedSummary = nil
        storedChat.compactedThroughMessageID = nil
        storedChat.compactedAt = nil
        storedChat.compactedMessageCount = nil
        storedChat.updatedAt = .now
        messages = []
        hasOlderMessages = false
        saveChanges()
        objectWillChange.send()
    }

    func deletePersistedRecords() {
        let chatID = id
        for message in ActiveChatMessages.fetchAll(chatID: chatID, in: modelContext) {
            modelContext.delete(message)
        }
        let participantDescriptor = FetchDescriptor<StoredGroupChatParticipant>(
            predicate: #Predicate { participant in
                participant.chatID == chatID
            }
        )
        if let participants = try? modelContext.fetch(participantDescriptor) {
            for participant in participants {
                modelContext.delete(participant)
            }
        }
        modelContext.delete(storedChat)
        saveChanges()
    }

    func setDefaultChat(_ isDefault: Bool) {
        storedChat.isDefaultChat = isDefault
        saveChanges()
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
            let userMessage = appendMessage(role: .user, text: prompt)
            isResponding = true

            Task {
                await respondAsGroup(
                    userMessageID: userMessage.id,
                    directlyMentionedAgentIDs: directlyMentionedAgentIDs
                )
            }
            return
        }

        if title == "New chat", !isDefaultChat {
            updateTitle(String(prompt.prefix(48)))
        }

        draft = ""
        let userMessage = appendMessage(role: .user, text: prompt)
        isResponding = true

        Task {
            await respond(userMessageID: userMessage.id)
        }
    }

    func executeHeartbeat(
        as agent: Agent,
        instruction: String,
        modelIdentifier: String,
        lastCompletedAt: Date?,
        referenceDate: Date,
        runID: UUID,
        turnID: UUID,
        recorder: ToolCallRecorder,
        debugCaptureEnabled: Bool,
        onDebugPrompt: ((String, String) -> Void)? = nil,
        onModelResponseAccepted: (() -> Void)? = nil
    ) async throws -> HeartbeatModelExchange {
        let backend = localModelStore.backend(for: modelIdentifier)
        func failure(
            message: String,
            wasAborted: Bool,
            partial: ModelGenerationResult? = nil,
            systemPrompt: String = "",
            conversationPrompt: String = ""
        ) -> HeartbeatModelFailure {
            HeartbeatModelFailure(
                modelInput: "",
                modelOutput: partial?.finalText,
                message: message,
                wasAborted: wasAborted,
                runID: runID,
                turnID: turnID,
                chatID: id,
                debugCaptureEnabled: debugCaptureEnabled,
                toolInvocations: recorder.snapshot(),
                debug: debugCaptureEnabled
                    ? GenerationDebugPayloadDraft(
                        systemPrompt: systemPrompt,
                        conversationPrompt: conversationPrompt,
                        result: partial ?? ModelGenerationResult(
                            finalText: "",
                            reasoningTexts: [],
                            intermediateAssistantTexts: [],
                            openAIRoundCount: 0,
                            debug: nil
                        )
                    )
                    : nil,
                backendRawValue: backend.persistenceName,
                tokenUsage: partial?.tokenUsage ?? .zero
            )
        }

        if Task.isCancelled {
            throw failure(message: "Aborted by user.", wasAborted: true)
        }

        if isGroupChat {
            addGroupParticipantIfNeeded(agent)
        }

        let generation = generationSupport(for: agent, recorder: recorder)
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
            lastCompletedAt: lastCompletedAt,
            referenceDate: referenceDate
        )
        if debugCaptureEnabled {
            onDebugPrompt?(systemInstructions, conversationPrompt)
        }

        let result: ModelGenerationResult
        do {
            result = try await ModelClient.complete(
                using: backend,
                systemPrompt: systemInstructions,
                prompt: conversationPrompt,
                tools: generation.tools,
                captureDebug: debugCaptureEnabled,
                missingLocalModelMessage: "The selected local model is no longer configured."
            )
            try Task.checkCancellation()
        } catch {
            let generationError = error as? ModelGenerationError
            let underlying = generationError?.underlying ?? error
            let wasAborted = Task.isCancelled || underlying is CancellationError
            throw failure(
                message: wasAborted ? "Aborted by user." : underlying.localizedDescription,
                wasAborted: wasAborted,
                partial: generationError?.partial,
                systemPrompt: systemInstructions,
                conversationPrompt: conversationPrompt
            )
        }
        onModelResponseAccepted?()

        let parsedResponse = sanitizedReply(
            result.finalText,
            modelIdentifier: modelIdentifier
        )
        agentStore.appendAgentMemoryEntries(
            id: agent.id,
            entries: parsedResponse.output.memoryEntries
        )

        let visibleText = parsedResponse.output.visibleText
        let passed = parsedResponse.isPass
        let posted = shouldPostAssistantReply(visibleText)
        var assistantMessageID: UUID?
        if posted {
            let assistantMessage = appendMessage(
                role: .assistant,
                text: visibleText,
                authorAgentID: agent.id,
                authorName: agent.displayName,
                save: false
            )
            assistantMessageID = assistantMessage.id
        }

        var actions: [String] = []
        let status: GenerationStatus
        if posted {
            actions.append("Posted to \(heartbeatDestinationDescription).")
            status = .posted
        } else if passed {
            actions.append("The model passed, so no chat message was posted.")
            status = .passed
        } else {
            actions.append("The model returned no visible text, so no chat message was posted.")
            status = .emptyVisible
        }

        let memoryCount = parsedResponse.output.memoryEntries.count
        if memoryCount > 0 {
            actions.append("Appended \(memoryCount) memory \(memoryCount == 1 ? "entry" : "entries").")
        }

        return HeartbeatModelExchange(
            modelInput: "",
            modelOutput: result.finalText,
            actionSummary: actions.joined(separator: " "),
            runID: runID,
            turnID: turnID,
            chatID: id,
            debugCaptureEnabled: debugCaptureEnabled,
            generationStatus: status,
            assistantMessageID: assistantMessageID,
            visibleReplyPreview: posted ? visibleText : nil,
            memoryEntryCount: memoryCount,
            backendRawValue: backend.persistenceName,
            toolInvocations: recorder.snapshot(),
            debug: debugCaptureEnabled
                ? GenerationDebugPayloadDraft(
                    systemPrompt: systemInstructions,
                    conversationPrompt: conversationPrompt,
                    result: result
                )
                : nil,
            tokenUsage: result.tokenUsage
        )
    }

    private func respond(userMessageID: UUID) async {
        let startedAt = Date()
        let agent = agentStore.agent(for: storedChat.agentID)
        let debugCaptureEnabled = agent?.isDebugLogEnabled == true
        let recorder = ToolCallRecorder()
        let generation = generationSupport(for: agent, recorder: recorder)
        let storedMessages = allStoredMessages()
        let systemInstructions = ModelPrompts.agentSystemInstructions(
            agentName: storedChat.agentName,
            soul: currentSoul(
                for: storedChat.agentID,
                fallback: storedChat.agentSoul
            ),
            memory: currentMemory(for: storedChat.agentID),
            skillsPrompt: generation.skillsPrompt
        )
        let prepared = await prepareConversation(
            messages: storedMessages,
            backend: backend,
            systemPrompt: systemInstructions,
            toolsEnabled: !generation.tools.isEmpty
        )
        let appleFoundationPrompt = ModelPrompts.directConversationPrompt(
            agentName: storedChat.agentName,
            transcript: ModelPrompts.withDigest(
                prepared.digestText,
                recent: ModelPrompts.conversationTranscript(
                    messages: prepared.tail,
                    isGroupChat: false,
                    fallbackAgentName: storedChat.agentName
                )
            )
        )
        let recordedSystemPrompt: String
        if case .openAICompatible = backend {
            recordedSystemPrompt = systemInstructions + ModelPrompts.digestSystemSection(prepared.digestText)
        } else {
            recordedSystemPrompt = systemInstructions
        }

        do {
            let result = try await ModelClient.complete(
                using: backend,
                systemPrompt: recordedSystemPrompt,
                messages: prepared.tail.map {
                    ChatMessage(storedMessage: $0, fallbackAssistantName: storedChat.agentName)
                },
                appleFoundationPrompt: appleFoundationPrompt,
                tools: generation.tools,
                captureDebug: debugCaptureEnabled,
                missingLocalModelMessage: "This chat's local model is no longer configured. Choose a configured model for the agent and start a new chat."
            )
            let parsedResponse = sanitizedReply(
                result.finalText,
                modelIdentifier: storedChat.agentModelIdentifier
            )
            agentStore.appendAgentMemoryEntries(
                id: storedChat.agentID,
                entries: parsedResponse.output.memoryEntries
            )
            persistChatTurn(
                kind: .direct,
                userMessageID: userMessageID,
                agentID: storedChat.agentID,
                agentName: storedChat.agentName,
                modelIdentifier: storedChat.agentModelIdentifier ?? ChatModelIdentifier.appleFoundation,
                backend: backend,
                startedAt: startedAt,
                parsedResponse: parsedResponse,
                result: result,
                systemPrompt: recordedSystemPrompt,
                conversationPrompt: appleFoundationPrompt,
                debugCaptureEnabled: debugCaptureEnabled,
                recorder: recorder
            )
        } catch {
            persistFailedChatTurn(
                kind: .direct,
                userMessageID: userMessageID,
                agentID: storedChat.agentID,
                agentName: storedChat.agentName,
                modelIdentifier: storedChat.agentModelIdentifier ?? ChatModelIdentifier.appleFoundation,
                backend: backend,
                startedAt: startedAt,
                error: error,
                systemPrompt: recordedSystemPrompt,
                conversationPrompt: appleFoundationPrompt,
                debugCaptureEnabled: debugCaptureEnabled,
                recorder: recorder
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

    private func respondAsGroup(
        userMessageID: UUID,
        directlyMentionedAgentIDs: Set<UUID>
    ) async {
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
            let startedAt = Date()
            let agent = agentStore.agent(for: participant.agentID)
            let debugCaptureEnabled = agent?.isDebugLogEnabled == true
            let recorder = ToolCallRecorder()
            let backend = localModelStore.backend(for: participant.agentModelIdentifier)

            do {
                let generated = try await groupResponse(
                    from: participant,
                    wasDirectlyMentioned: directlyMentionedAgentIDs.contains(participant.agentID),
                    recorder: recorder,
                    captureDebug: debugCaptureEnabled
                )
                let parsedResponse = sanitizedReply(
                    generated.result.finalText,
                    modelIdentifier: participant.agentModelIdentifier
                )
                agentStore.appendAgentMemoryEntries(
                    id: participant.agentID,
                    entries: parsedResponse.output.memoryEntries
                )
                persistChatTurn(
                    kind: .group,
                    userMessageID: userMessageID,
                    agentID: participant.agentID,
                    agentName: participant.agentName,
                    modelIdentifier: participant.agentModelIdentifier ?? ChatModelIdentifier.appleFoundation,
                    backend: backend,
                    startedAt: startedAt,
                    parsedResponse: parsedResponse,
                    result: generated.result,
                    systemPrompt: generated.systemPrompt,
                    conversationPrompt: generated.conversationPrompt,
                    debugCaptureEnabled: debugCaptureEnabled,
                    recorder: recorder
                )
            } catch {
                persistFailedChatTurn(
                    kind: .group,
                    userMessageID: userMessageID,
                    agentID: participant.agentID,
                    agentName: participant.agentName,
                    modelIdentifier: participant.agentModelIdentifier ?? ChatModelIdentifier.appleFoundation,
                    backend: backend,
                    startedAt: startedAt,
                    error: error,
                    systemPrompt: (error as? GroupGenerationError)?.systemPrompt ?? "",
                    conversationPrompt: (error as? GroupGenerationError)?.conversationPrompt ?? "",
                    debugCaptureEnabled: debugCaptureEnabled,
                    recorder: recorder
                )
            }
        }

        respondingAgentName = nil
        isResponding = false
        updateAvailability()
    }

    private struct GroupGeneration {
        var result: ModelGenerationResult
        var systemPrompt: String
        var conversationPrompt: String
    }

    private struct GroupGenerationError: LocalizedError {
        var underlying: Error
        var systemPrompt: String
        var conversationPrompt: String
        var partial: ModelGenerationResult?

        var errorDescription: String? {
            underlying.localizedDescription
        }
    }

    private func groupResponse(
        from participant: StoredGroupChatParticipant,
        wasDirectlyMentioned: Bool,
        recorder: ToolCallRecorder,
        captureDebug: Bool
    ) async throws -> GroupGeneration {
        let storedMessages = allStoredMessages()
        let generation = generationSupport(
            for: agentStore.agent(for: participant.agentID),
            recorder: recorder
        )
        let backend = localModelStore.backend(for: participant.agentModelIdentifier)
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
        let prepared = await prepareConversation(
            messages: storedMessages,
            backend: backend,
            systemPrompt: systemInstructions,
            toolsEnabled: !generation.tools.isEmpty
        )
        let conversationPrompt = ModelPrompts.groupConversationPrompt(
            agentName: participant.agentName,
            transcript: ModelPrompts.withDigest(
                prepared.digestText,
                recent: ModelPrompts.conversationTranscript(
                    messages: prepared.tail,
                    isGroupChat: true,
                    fallbackAgentName: storedChat.agentName
                )
            ),
            wasDirectlyMentioned: wasDirectlyMentioned
        )

        do {
            let result = try await ModelClient.complete(
                using: backend,
                systemPrompt: systemInstructions,
                prompt: conversationPrompt,
                tools: generation.tools,
                captureDebug: captureDebug,
                missingLocalModelMessage: "This agent's local model is no longer configured."
            )
            return GroupGeneration(
                result: result,
                systemPrompt: systemInstructions,
                conversationPrompt: conversationPrompt
            )
        } catch {
            let generationError = error as? ModelGenerationError
            throw GroupGenerationError(
                underlying: generationError?.underlying ?? error,
                systemPrompt: systemInstructions,
                conversationPrompt: conversationPrompt,
                partial: generationError?.partial
            )
        }
    }

    private func generationSupport(
        for agent: Agent?,
        recorder: ToolCallRecorder? = nil
    ) -> (tools: AgentToolBox, skillsPrompt: String) {
        let tools = AgentToolBox.make(agent: agent, catalog: skillCatalog, recorder: recorder)
        return (
            tools,
            ModelPrompts.toolsPrompt(enabledIDs: tools.enabledToolIDs)
                + ModelPrompts.skillsPrompt(for: tools.runtime.skills)
        )
    }

    private func persistChatTurn(
        kind: GenerationKind,
        userMessageID: UUID,
        agentID: UUID,
        agentName: String,
        modelIdentifier: String,
        backend: ChatBackend,
        startedAt: Date,
        parsedResponse: (output: AgentModelOutput, isPass: Bool),
        result: ModelGenerationResult,
        systemPrompt: String,
        conversationPrompt: String,
        debugCaptureEnabled: Bool,
        recorder: ToolCallRecorder
    ) {
        let visibleText = parsedResponse.output.visibleText
        var assistantMessageID: UUID?
        let status: GenerationStatus
        let actionSummary: String
        if shouldPostAssistantReply(visibleText) {
            let assistantMessage = appendMessage(
                role: .assistant,
                text: visibleText,
                authorAgentID: agentID,
                authorName: agentName,
                save: false
            )
            assistantMessageID = assistantMessage.id
            status = .posted
            actionSummary = "Posted."
        } else if parsedResponse.isPass {
            status = .passed
            actionSummary = "Passed."
        } else {
            status = .emptyVisible
            actionSummary = "Empty visible reply."
        }

        GenerationStore.recordTurn(
            draft: GenerationTurnDraft(
                kind: kind,
                chatID: id,
                userMessageID: userMessageID,
                assistantMessageID: assistantMessageID,
                agentID: agentID,
                agentName: agentName,
                modelIdentifier: modelIdentifier,
                backendRawValue: backend.persistenceName,
                startedAt: startedAt,
                completedAt: .now,
                status: status,
                actionSummary: actionSummary,
                visibleReplyPreview: GenerationStore.visibleReplyPreview(from: assistantMessageID == nil ? nil : visibleText),
                memoryEntryCount: parsedResponse.output.memoryEntries.count,
                debugCaptureEnabled: debugCaptureEnabled
            ),
            invocations: recorder.snapshot(),
            debug: debugCaptureEnabled
                ? GenerationDebugPayloadDraft(
                    systemPrompt: systemPrompt,
                    conversationPrompt: conversationPrompt,
                    result: result
                )
                : nil,
            in: modelContext
        )
        saveChanges()
    }

    private func persistFailedChatTurn(
        kind: GenerationKind,
        userMessageID: UUID,
        agentID: UUID,
        agentName: String,
        modelIdentifier: String,
        backend: ChatBackend,
        startedAt: Date,
        error: Error,
        systemPrompt: String,
        conversationPrompt: String,
        debugCaptureEnabled: Bool,
        recorder: ToolCallRecorder
    ) {
        let groupError = error as? GroupGenerationError
        let generationError = error as? ModelGenerationError
        let underlying = groupError?.underlying ?? generationError?.underlying ?? error
        let wasAborted = underlying is CancellationError || Task.isCancelled
        let message = wasAborted ? "Aborted." : underlying.localizedDescription
        var assistantMessageID: UUID?
        let status: GenerationStatus
        if wasAborted {
            status = .aborted
        } else {
            let assistantMessage = appendMessage(
                role: .assistant,
                text: "I could not get a response: \(message)",
                authorAgentID: agentID,
                authorName: agentName,
                save: false
            )
            assistantMessageID = assistantMessage.id
            status = .failed
        }

        let partial = groupError?.partial ?? generationError?.partial
        GenerationStore.recordTurn(
            draft: GenerationTurnDraft(
                kind: kind,
                chatID: id,
                userMessageID: userMessageID,
                assistantMessageID: assistantMessageID,
                agentID: agentID,
                agentName: agentName,
                modelIdentifier: modelIdentifier,
                backendRawValue: backend.persistenceName,
                startedAt: startedAt,
                completedAt: .now,
                status: status,
                actionSummary: message,
                errorMessage: wasAborted ? nil : message,
                visibleReplyPreview: GenerationStore.visibleReplyPreview(
                    from: assistantMessageID == nil ? nil : "I could not get a response: \(message)"
                ),
                memoryEntryCount: 0,
                debugCaptureEnabled: debugCaptureEnabled
            ),
            invocations: recorder.snapshot(),
            debug: debugCaptureEnabled
                ? GenerationDebugPayloadDraft(
                    systemPrompt: systemPrompt,
                    conversationPrompt: conversationPrompt,
                    result: partial ?? ModelGenerationResult(
                        finalText: "",
                        reasoningTexts: [],
                        intermediateAssistantTexts: [],
                        openAIRoundCount: 0,
                        debug: nil
                    )
                )
                : nil,
            in: modelContext
        )
        saveChanges()
    }

    private func sanitizedReply(_ response: String, modelIdentifier: String?) -> (output: AgentModelOutput, isPass: Bool) {
        ReplySanitizer.process(
            response,
            patterns: replyFilterStore.patterns(
                for: modelIdentifier ?? ChatModelIdentifier.appleFoundation
            )
        )
    }

    private func shouldPostAssistantReply(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func currentMemory(for agentID: Agent.ID) -> String {
        agentStore.agent(for: agentID)?.memoryText ?? ""
    }

    private func currentSoul(for agentID: Agent.ID, fallback: String) -> String {
        agentStore.agent(for: agentID)?.soul ?? fallback
    }

    func compactConversation() async {
        guard !isCompacting else { return }
        isCompacting = true
        defer { isCompacting = false }

        let messages = allStoredMessages()
        let generation = generationSupport(for: agentStore.agent(for: storedChat.agentID))
        let systemInstructions = ModelPrompts.agentSystemInstructions(
            agentName: storedChat.agentName,
            soul: currentSoul(for: storedChat.agentID, fallback: storedChat.agentSoul),
            memory: currentMemory(for: storedChat.agentID),
            skillsPrompt: generation.skillsPrompt
        )
        _ = await prepareConversation(
            messages: messages,
            backend: backend,
            systemPrompt: systemInstructions,
            toolsEnabled: !generation.tools.isEmpty,
            aggressive: true
        )
        objectWillChange.send()
    }

    private func prepareConversation(
        messages: [StoredChatMessage],
        backend: ChatBackend,
        systemPrompt: String,
        toolsEnabled: Bool,
        relativeTo: Date? = nil,
        aggressive: Bool = false
    ) async -> ConversationCompaction.Prepared {
        await ConversationCompaction.prepare(
            chat: storedChat,
            messages: messages,
            backend: backend,
            systemPrompt: systemPrompt,
            toolsEnabled: toolsEnabled,
            isGroupChat: isGroupChat,
            fallbackAgentName: storedChat.agentName,
            relativeTo: relativeTo,
            aggressive: aggressive,
            in: modelContext
        )
    }

    private func allStoredMessages() -> [StoredChatMessage] {
        ActiveChatMessages.fetch(
            chatID: id,
            clearedThroughMessageID: storedChat.clearedThroughMessageID,
            in: modelContext
        )
    }

    @discardableResult
    private func appendMessage(
        role: ChatRole,
        text: String,
        authorAgentID: UUID? = nil,
        authorName: String? = nil,
        save: Bool = true
    ) -> StoredChatMessage {
        let storedMessage = StoredChatMessage(
            chatID: id,
            role: role,
            text: text,
            authorAgentID: authorAgentID,
            authorName: authorName
        )
        modelContext.insert(storedMessage)
        storedChat.updatedAt = .now
        if save {
            saveChanges()
        }
        messages.append(ChatMessage(storedMessage: storedMessage))
        return storedMessage
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
