import Combine
import Foundation
import os
import SwiftData

@MainActor
final class AgentStore: ObservableObject {
    private static let logger = Logger(subsystem: "Chat", category: "Agents")

    @Published private(set) var agents: [Agent] = []
    @Published private(set) var collaborationGrants: [AgentCollaborationGrant] = []
    @Published private(set) var heartbeats: [AgentHeartbeat] = []
    @Published private(set) var heartbeatRuns: [HeartbeatRun] = []
    @Published private(set) var dreamSettings: DreamConfiguration
    @Published private(set) var hasOlderHeartbeatRuns = false
    @Published var selectedAgentID: Agent.ID?
    let agentConfigurationDidChange = PassthroughSubject<Agent.ID, Never>()
    let agentSoulDidChange = PassthroughSubject<Agent.ID, Never>()

    private static let heartbeatRunBatchSize = 200

    let modelContext: ModelContext
    private var isLoadingOlderHeartbeatRuns = false

    var selectedAgent: Agent? {
        guard let selectedAgentID else { return nil }
        return agents.first { $0.id == selectedAgentID }
    }

    var defaultAgent: Agent? {
        agents.first
    }

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        dreamSettings = Self.loadOrCreateDreamSettings(in: modelContext)
        loadAgents()
        loadCollaborationGrants()
        loadHeartbeats()
        loadHeartbeatRuns()
    }

    var grants: [AgentCollaborationGrant] {
        collaborationGrants
    }

    func addAgent() {
        let agent = Agent(
            name: "",
            soul: ""
        )
        modelContext.insert(agent)
        saveChanges()
        loadAgents(selecting: agent.id)
    }

    @discardableResult
    func duplicateAgent(_ source: Agent, named name: String) -> Agent? {
        guard let source = agent(for: source.id) else { return nil }
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return nil }

        let duplicate = Agent(
            name: normalizedName,
            soul: source.soul,
            mentionHandle: uniqueMentionHandle(for: normalizedName),
            routingDescription: source.routingDescription,
            memory: source.memory,
            modelIdentifier: source.modelIdentifier,
            voiceTriggerPhrase: source.voiceTriggerPhrase,
            textToSpeechToolID: source.textToSpeechToolID,
            textToSpeechVoiceName: source.textToSpeechVoiceName,
            textToSpeechVoiceModel: source.textToSpeechVoiceModel,
            enabledToolIDsJSON: source.enabledToolIDsJSON,
            enabledSkillIDsJSON: source.enabledSkillIDsJSON,
            debugLogEnabled: source.debugLogEnabled,
            calendarAccessAll: source.calendarAccessAll,
            allowedCalendarIDsJSON: source.allowedCalendarIDsJSON,
            avatarImageData: source.avatarImageData,
            avatarCropZoom: source.avatarCropZoom,
            avatarCropOffsetX: source.avatarCropOffsetX,
            avatarCropOffsetY: source.avatarCropOffsetY,
            avatarPlaceholderColorHex: source.avatarPlaceholderColorHex,
            dreamOverrideRawValue: source.dreamOverrideRawValue,
            dreamLightPromptOverride: source.dreamLightPromptOverride,
            dreamREMPromptOverride: source.dreamREMPromptOverride,
            dreamUsesScheduleOverride: source.dreamUsesScheduleOverride,
            dreamScheduleKindRawValue: source.dreamScheduleKindRawValue,
            dreamIntervalMinutes: source.dreamIntervalMinutes,
            dreamWeekdayMask: source.dreamWeekdayMask,
            dreamScheduledTimeMinutes: source.dreamScheduledTimeMinutes,
            dreamLightModelIdentifierOverride: source.dreamLightModelIdentifierOverride,
            dreamREMModelIdentifierOverride: source.dreamREMModelIdentifierOverride
        )
        duplicate.appleServiceGrantsJSON = source.appleServiceGrantsJSON
        modelContext.insert(duplicate)

        let previousSelection = selectedAgentID
        guard saveChanges() else {
            modelContext.rollback()
            loadAgents(selecting: previousSelection)
            return nil
        }
        loadAgents(selecting: duplicate.id)
        return agent(for: duplicate.id)
    }

    func isDefaultAgent(_ agent: Agent) -> Bool {
        defaultAgent?.id == agent.id
    }

    func canDeleteAgent(_ agent: Agent) -> Bool {
        !isDefaultAgent(agent)
    }

    @discardableResult
    func removeAgent(
        id agentID: Agent.ID,
        beforeSaving: () -> Void
    ) -> Bool {
        guard let index = agents.firstIndex(where: { $0.id == agentID }),
              index > agents.startIndex else {
            return false
        }
        let queued = AgentInvocationState.queued.rawValue
        let running = AgentInvocationState.running.rawValue
        let activeAgentID = agentID
        var activeInvocationDescriptor = FetchDescriptor<AgentInvocationRecord>(
            predicate: #Predicate { invocation in
                (invocation.callerAgentID == activeAgentID
                    || invocation.targetAgentID == activeAgentID)
                    && (invocation.stateRawValue == queued
                        || invocation.stateRawValue == running)
            }
        )
        activeInvocationDescriptor.fetchLimit = 1
        do {
            guard try modelContext.fetch(activeInvocationDescriptor).first == nil else {
                return false
            }
        } catch {
            Self.logger.error(
                "Failed to verify active delegations: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
        let deletedAgentID = agentID
        let invocationDescriptor = FetchDescriptor<AgentInvocationRecord>(
            predicate: #Predicate { invocation in
                invocation.callerAgentID == deletedAgentID
                    || invocation.targetAgentID == deletedAgentID
            }
        )
        let invocationRecords: [AgentInvocationRecord]
        do {
            invocationRecords = try modelContext.fetch(invocationDescriptor)
        } catch {
            Self.logger.error(
                "Failed to load delegation history for redaction: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
        let affectedRootIDs = Set(invocationRecords.map(\.rootInvocationID))
        var rootInvocationRecordsByID = Dictionary(
            uniqueKeysWithValues: invocationRecords.map { ($0.id, $0) }
        )
        do {
            for rootID in affectedRootIDs {
                let rootDescriptor = FetchDescriptor<AgentInvocationRecord>(
                    predicate: #Predicate { $0.rootInvocationID == rootID }
                )
                for record in try modelContext.fetch(rootDescriptor) {
                    rootInvocationRecordsByID[record.id] = record
                }
            }
        } catch {
            Self.logger.error(
                "Failed to load complete collaboration roots for redaction: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }

        let stashDescriptor = FetchDescriptor<AgentStashEntry>(
            predicate: #Predicate { $0.agentID == deletedAgentID }
        )
        let stashEntries: [AgentStashEntry]
        do {
            stashEntries = try modelContext.fetch(stashDescriptor)
        } catch {
            Self.logger.error(
                "Failed to load agent stash for deletion: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }

        let previousSelection = selectedAgentID
        let nextSelection: Agent.ID?
        if agents.count <= 1 {
            nextSelection = nil
        } else {
            let nextIndex = min(index, agents.count - 2)
            nextSelection = agents[nextIndex == index ? index + 1 : nextIndex].id
        }

        let heartbeatsToDelete = heartbeats.filter { $0.agentID == agentID }
        for heartbeat in heartbeatsToDelete {
            modelContext.delete(heartbeat)
        }
        heartbeats.removeAll { $0.agentID == agentID }

        let grantsToDelete = collaborationGrants.filter {
            $0.callerAgentID == agentID || $0.targetAgentID == agentID
        }
        for grant in grantsToDelete {
            modelContext.delete(grant)
        }
        for entry in stashEntries {
            modelContext.delete(entry)
        }
        collaborationGrants.removeAll {
            $0.callerAgentID == agentID || $0.targetAgentID == agentID
        }
        for invocation in rootInvocationRecordsByID.values {
            invocation.contentRedacted = true
            invocation.taskPreview = "(redacted when agent was deleted)"
            invocation.resultPreview = nil
            invocation.errorMessage = nil
            invocation.toolTraceSummary = nil
            invocation.debugLogJSON = nil
            if invocation.callerAgentID == agentID || invocation.targetAgentID == agentID {
                invocation.pendingDeliveryText = nil
                invocation.deliveryCompletedAt = nil
            }
        }
        do {
            try redactGenerationLogs(forCollaborationRoots: affectedRootIDs)
        } catch {
            Self.logger.error(
                "Failed to redact correlated generation logs: \(error.localizedDescription, privacy: .public)"
            )
            modelContext.rollback()
            loadAgents(selecting: previousSelection)
            loadCollaborationGrants()
            loadHeartbeats()
            return false
        }
        AppleServiceRuntime.shared.revoke(agentID: agents[index].id)
        modelContext.delete(agents[index])
        beforeSaving()
        guard saveChanges() else {
            modelContext.rollback()
            loadAgents(selecting: previousSelection)
            loadCollaborationGrants()
            loadHeartbeats()
            return false
        }
        loadAgents(selecting: nextSelection)
        return true
    }

    private func redactGenerationLogs(forCollaborationRoots rootIDs: Set<UUID>) throws {
        let collaborationToolNames: Set<String> = [
            AgentToolID.askAgents.rawValue,
            AgentToolID.sendToAgents.rawValue,
        ]
        for rootID in rootIDs {
            var turnDescriptor = FetchDescriptor<GenerationTurn>(
                predicate: #Predicate { $0.id == rootID }
            )
            turnDescriptor.fetchLimit = 1
            if let turn = try modelContext.fetch(turnDescriptor).first {
                turn.debugContentRedacted = true
            }
            let toolRows = try modelContext.fetch(
                GenerationQuery.toolCalls(forTurn: rootID)
            )
            for row in toolRows where collaborationToolNames.contains(row.toolName) {
                row.argumentsJSON = "(redacted when an involved agent was deleted)"
                row.resultText = "(redacted when an involved agent was deleted)"
                row.resultTruncated = false
                row.errorMessage = nil
            }
            var payloadDescriptor = GenerationQuery.debugPayload(forTurn: rootID)
            payloadDescriptor.fetchLimit = 1
            if let payload = try modelContext.fetch(payloadDescriptor).first {
                modelContext.delete(payload)
            }
        }
    }

    func updateAgentName(id: Agent.ID, name: String) {
        guard let agent = agents.first(where: { $0.id == id }) else { return }

        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        agent.name = normalizedName
        saveChanges()
        objectWillChange.send()
        agentConfigurationDidChange.send(id)
    }

    func finalizeAgentMentionHandle(id: Agent.ID) {
        guard let agent = agent(for: id) else { return }
        let normalizedName = agent.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return }
        let isMissing = AgentMention.normalizedHandle(agent.mentionHandle) == nil
        let isDefaultPlaceholder = isDefaultAgent(agent)
            && AgentMention.isDefaultPlaceholder(agent.mentionHandle, agentName: normalizedName)
        guard isMissing || isDefaultPlaceholder else { return }
        agent.mentionHandle = uniqueMentionHandle(for: normalizedName, excluding: id)
        guard saveChanges() else { return }
        objectWillChange.send()
        agentConfigurationDidChange.send(id)
    }

    func updateAgentRoutingDescription(id: Agent.ID, routingDescription: String) {
        guard let agent = agents.first(where: { $0.id == id }) else { return }

        agent.routingDescription = routingDescription.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        saveChanges()
        objectWillChange.send()
        agentConfigurationDidChange.send(id)
    }

    @discardableResult
    func updateAgentSoul(id: Agent.ID, soul: String) -> Bool {
        guard persistAgentSoul(id: id, soul: soul) else { return false }
        agentConfigurationDidChange.send(id)
        return true
    }

    @discardableResult
    func updateAgentSoulFromTool(id: Agent.ID, soul: String) -> Bool {
        guard persistAgentSoul(id: id, soul: soul) else { return false }
        agentSoulDidChange.send(id)
        return true
    }

    private func persistAgentSoul(id: Agent.ID, soul: String) -> Bool {
        guard let agent = agents.first(where: { $0.id == id }) else { return false }

        agent.soul = soul
        let previousSelection = selectedAgentID
        guard saveChanges() else {
            modelContext.rollback()
            loadAgents(selecting: previousSelection)
            return false
        }
        objectWillChange.send()
        return true
    }

    func updateAgentAvatar(
        id: Agent.ID,
        imageData: Data?,
        cropZoom: Double,
        cropOffsetX: Double,
        cropOffsetY: Double
    ) {
        guard let agent = agents.first(where: { $0.id == id }) else { return }

        agent.avatarImageData = imageData
        agent.avatarCropZoom = imageData == nil ? nil : max(1, cropZoom)
        agent.avatarCropOffsetX = imageData == nil ? nil : cropOffsetX
        agent.avatarCropOffsetY = imageData == nil ? nil : cropOffsetY
        saveChanges()
        objectWillChange.send()
    }

    func updateAgentAvatarPlaceholderColor(id: Agent.ID, colorHex: String) {
        guard let agent = agents.first(where: { $0.id == id }) else { return }

        agent.avatarPlaceholderColorHex = colorHex
        saveChanges()
        objectWillChange.send()
    }

    func updateAgentMemory(id: Agent.ID, memory: String) {
        guard let agent = agents.first(where: { $0.id == id }) else { return }

        agent.memory = memory
        saveChanges()
        objectWillChange.send()
        agentConfigurationDidChange.send(id)
    }

    func updateAgentVoiceTriggerPhrases(id: Agent.ID, phrasesText: String) {
        guard let agent = agents.first(where: { $0.id == id }) else { return }

        agent.voiceTriggerPhrase = phrasesText
        saveChanges()
        objectWillChange.send()
    }

    func updateAgentTextToSpeechTool(id: Agent.ID, toolID: TextToSpeechTool.ID?) {
        guard let agent = agents.first(where: { $0.id == id }) else { return }

        agent.textToSpeechToolID = toolID
        saveChanges()
        objectWillChange.send()
    }

    func updateAgentTextToSpeechVoiceName(id: Agent.ID, voiceName: String) {
        guard let agent = agents.first(where: { $0.id == id }) else { return }

        agent.textToSpeechVoiceName = voiceName
        saveChanges()
        objectWillChange.send()
    }

    func updateAgentTextToSpeechVoiceModel(id: Agent.ID, voiceModel: String) {
        guard let agent = agents.first(where: { $0.id == id }) else { return }

        agent.textToSpeechVoiceModel = voiceModel
        saveChanges()
        objectWillChange.send()
    }

    func appendAgentMemoryEntries(id: Agent.ID, entries: [String]) {
        guard let agent = agents.first(where: { $0.id == id }) else { return }

        let newEntries = entries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !newEntries.isEmpty else { return }

        let existingMemory = (agent.memory ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let appendedMemory = newEntries.joined(separator: "\n\n")
        agent.memory = existingMemory.isEmpty
            ? appendedMemory
            : "\(existingMemory)\n\n\(appendedMemory)"
        saveChanges()
        objectWillChange.send()
    }

    func updateAgentModelIdentifier(id: Agent.ID, modelIdentifier: String) {
        guard let agent = agents.first(where: { $0.id == id }) else { return }

        agent.modelIdentifier = modelIdentifier
        saveChanges()
        objectWillChange.send()
        agentConfigurationDidChange.send(id)
    }

    func setTool(_ toolID: AgentToolID, enabled: Bool, for agentID: Agent.ID) {
        guard let agent = agents.first(where: { $0.id == agentID }) else { return }
        AppleServiceRuntime.shared.revoke(agentID: agentID)
        // Settle the one-time split first so it never overrides this choice.
        agent.migrateSplitAppleServiceTools()
        agent.setTool(toolID, enabled: enabled)
        saveChanges()
        objectWillChange.send()
        agentConfigurationDidChange.send(agentID)
    }

    func setCalendarAccessAll(_ all: Bool, selecting ids: [String] = [], for agentID: Agent.ID) {
        guard let agent = agents.first(where: { $0.id == agentID }) else { return }
        agent.setCalendarAccessAll(all, selecting: ids)
        saveChanges()
        objectWillChange.send()
        agentConfigurationDidChange.send(agentID)
    }

    func setAllowedCalendarID(_ id: String, enabled: Bool, for agentID: Agent.ID) {
        guard let agent = agents.first(where: { $0.id == agentID }) else { return }
        agent.setAllowedCalendarID(id, enabled: enabled)
        saveChanges()
        objectWillChange.send()
        agentConfigurationDidChange.send(agentID)
    }

    func setSkill(_ skillID: String, enabled: Bool, for agentID: Agent.ID) {
        guard let agent = agents.first(where: { $0.id == agentID }) else { return }
        agent.setSkill(skillID, enabled: enabled)
        saveChanges()
        objectWillChange.send()
        agentConfigurationDidChange.send(agentID)
    }

    func updateAgentDebugLog(id: Agent.ID, enabled: Bool) {
        guard let agent = agents.first(where: { $0.id == id }) else { return }
        agent.debugLogEnabled = enabled
        saveChanges()
        objectWillChange.send()
    }

    func updateAgentSidebarVisibility(id: Agent.ID, isVisible: Bool) {
        guard let agent = agents.first(where: { $0.id == id }) else { return }
        agent.hiddenFromSidebar = isVisible ? nil : true
        saveChanges()
        objectWillChange.send()
    }

    func loadOlderHeartbeatRuns() {
        guard hasOlderHeartbeatRuns,
              !isLoadingOlderHeartbeatRuns,
              let oldest = heartbeatRuns.last else {
            return
        }

        isLoadingOlderHeartbeatRuns = true
        defer { isLoadingOlderHeartbeatRuns = false }

        let oldestDate = oldest.completedAt
        var descriptor = FetchDescriptor<HeartbeatRun>(
            predicate: #Predicate { $0.completedAt < oldestDate },
            sortBy: [SortDescriptor(\.completedAt, order: .reverse)]
        )
        descriptor.fetchLimit = Self.heartbeatRunBatchSize

        do {
            let older = try modelContext.fetch(descriptor)
            hasOlderHeartbeatRuns = older.count == Self.heartbeatRunBatchSize
            heartbeatRuns.append(contentsOf: older)
        } catch {
            hasOlderHeartbeatRuns = false
        }
    }

    func agent(for id: Agent.ID) -> Agent? {
        agents.first { $0.id == id }
    }

    func agent(matchingMention mention: String) -> Agent? {
        guard let lookupHandle = AgentMention.lookupHandle(from: mention) else { return nil }
        return agents.first {
            guard let handle = AgentMention.normalizedHandle($0.mentionHandle) else { return false }
            return AgentMention.lookupKey(for: handle) == lookupHandle
        }
    }

    func grant(
        from callerAgentID: Agent.ID,
        to targetAgentID: Agent.ID
    ) -> AgentCollaborationGrant? {
        collaborationGrants.first {
            $0.callerAgentID == callerAgentID && $0.targetAgentID == targetAgentID
        }
    }

    func canDelegate(
        _ mode: AgentDelegationMode,
        from callerAgentID: Agent.ID,
        to targetAgentID: Agent.ID
    ) -> Bool {
        grant(from: callerAgentID, to: targetAgentID)?.allows(mode) == true
    }

    func canDelegate(
        from callerAgentID: Agent.ID,
        to targetAgentID: Agent.ID,
        mode: AgentDelegationMode
    ) -> Bool {
        canDelegate(mode, from: callerAgentID, to: targetAgentID)
    }

    @discardableResult
    func setCollaborationPermission(
        _ mode: AgentDelegationMode,
        enabled: Bool,
        from callerAgentID: Agent.ID,
        to targetAgentID: Agent.ID
    ) -> AgentCollaborationGrant? {
        guard callerAgentID != targetAgentID,
              let callerAgent = agent(for: callerAgentID),
              agent(for: targetAgentID) != nil else {
            return nil
        }
        finalizeAgentMentionHandle(id: callerAgentID)
        finalizeAgentMentionHandle(id: targetAgentID)
        guard AgentMention.normalizedHandle(callerAgent.mentionHandle) != nil,
              let targetAgent = agent(for: targetAgentID),
              AgentMention.normalizedHandle(targetAgent.mentionHandle) != nil else {
            return nil
        }

        if enabled {
            let toolID: AgentToolID = mode == .consult ? .askAgents : .sendToAgents
            callerAgent.setTool(toolID, enabled: true)
        }

        let changedGrant: AgentCollaborationGrant
        if let existingGrant = grant(from: callerAgentID, to: targetAgentID) {
            existingGrant.setAllowed(enabled, for: mode)
            existingGrant.updatedAt = .now
            changedGrant = existingGrant
        } else {
            guard enabled else { return nil }
            let canConsult: Bool
            let canDispatch: Bool
            switch mode {
            case .consult:
                canConsult = true
                canDispatch = false
            case .dispatch:
                canConsult = false
                canDispatch = true
            }
            let newGrant = AgentCollaborationGrant(
                callerAgentID: callerAgentID,
                targetAgentID: targetAgentID,
                canConsult: canConsult,
                canDispatch: canDispatch
            )
            modelContext.insert(newGrant)
            collaborationGrants.append(newGrant)
            changedGrant = newGrant
        }

        guard saveChanges() else {
            modelContext.rollback()
            loadCollaborationGrants()
            objectWillChange.send()
            return grant(from: callerAgentID, to: targetAgentID)
        }
        objectWillChange.send()
        agentConfigurationDidChange.send(callerAgentID)
        return changedGrant
    }

    func heartbeats(for agentID: Agent.ID) -> [AgentHeartbeat] {
        heartbeats.filter { $0.agentID == agentID }
    }

    @discardableResult
    func addHeartbeat(to agentID: Agent.ID) -> AgentHeartbeat? {
        let heartbeat = AgentHeartbeat(
            agentID: agentID,
            title: nextAvailableHeartbeatTitle(for: agentID)
        )
        modelContext.insert(heartbeat)
        heartbeats.append(heartbeat)
        guard saveChanges() else {
            modelContext.rollback()
            heartbeats.removeAll { $0.id == heartbeat.id }
            objectWillChange.send()
            return nil
        }
        objectWillChange.send()
        return heartbeat
    }

    @discardableResult
    func removeHeartbeat(_ heartbeat: AgentHeartbeat) -> Bool {
        modelContext.delete(heartbeat)
        heartbeats.removeAll { $0.id == heartbeat.id }
        guard saveChanges() else {
            modelContext.rollback()
            loadHeartbeats()
            objectWillChange.send()
            return false
        }
        objectWillChange.send()
        return true
    }

    func updateHeartbeatInstruction(_ heartbeat: AgentHeartbeat, instruction: String) {
        heartbeat.instruction = instruction
        saveChanges()
        objectWillChange.send()
    }

    func updateHeartbeatTitle(_ heartbeat: AgentHeartbeat, title: String) {
        heartbeat.title = title
        saveChanges()
        objectWillChange.send()
    }

    func updateHeartbeatInterval(_ heartbeat: AgentHeartbeat, minutes: Int) {
        heartbeat.intervalMinutes = min(max(minutes, 1), 10_080)
        rescheduleEnabledHeartbeat(heartbeat, after: .now)
        saveChanges()
        objectWillChange.send()
    }

    func updateHeartbeatScheduleKind(
        _ heartbeat: AgentHeartbeat,
        scheduleKind: HeartbeatScheduleKind
    ) {
        heartbeat.scheduleKindRawValue = scheduleKind.rawValue
        rescheduleEnabledHeartbeat(heartbeat, after: .now)
        saveChanges()
        objectWillChange.send()
    }

    func updateHeartbeatWeekdayMask(_ heartbeat: AgentHeartbeat, weekdayMask: Int) {
        let validMask = weekdayMask & HeartbeatWeekday.allMask
        guard validMask != 0 else { return }
        heartbeat.weekdayMask = validMask
        rescheduleEnabledHeartbeat(heartbeat, after: .now)
        saveChanges()
        objectWillChange.send()
    }

    func updateHeartbeatScheduledTime(_ heartbeat: AgentHeartbeat, minutes: Int) {
        heartbeat.scheduledTimeMinutes = min(max(minutes, 0), (24 * 60) - 1)
        rescheduleEnabledHeartbeat(heartbeat, after: .now)
        saveChanges()
        objectWillChange.send()
    }

    func updateHeartbeatEnabled(_ heartbeat: AgentHeartbeat, isEnabled: Bool) {
        heartbeat.isEnabled = isEnabled
        heartbeat.nextRunAt = isEnabled
            ? heartbeat.nextScheduledRun(after: .now)
            : nil
        saveChanges()
        objectWillChange.send()
    }

    func updateHeartbeatDestination(
        _ heartbeat: AgentHeartbeat,
        targetKind: HeartbeatTargetKind,
        targetChatID: UUID?
    ) {
        heartbeat.targetKindRawValue = targetKind.rawValue
        heartbeat.targetChatID = targetChatID
        saveChanges()
        objectWillChange.send()
    }

    func updateHeartbeatModelIdentifier(
        _ heartbeat: AgentHeartbeat,
        modelIdentifier: String?
    ) {
        heartbeat.modelIdentifier = modelIdentifier
        saveChanges()
        objectWillChange.send()
    }

    func claimNextDueHeartbeat(at date: Date) -> AgentHeartbeat? {
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
        claimedHeartbeat.nextRunAt = claimedHeartbeat.nextScheduledRun(after: date)

        for heartbeat in dueHeartbeats.dropFirst() {
            deferHeartbeatToNextSchedule(heartbeat, from: date)
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
            deferHeartbeatToNextSchedule(heartbeat, from: date)
        }
        saveChanges()
        objectWillChange.send()
    }

    func deferHeartbeatForOverlap(id: AgentHeartbeat.ID, at date: Date) {
        guard let heartbeat = heartbeats.first(where: { $0.id == id }), heartbeat.isEnabled else {
            return
        }

        deferHeartbeatToNextSchedule(heartbeat, from: date)
        saveChanges()
        objectWillChange.send()
    }

    func skipHeartbeat(id: AgentHeartbeat.ID, at date: Date) {
        guard let heartbeat = heartbeats.first(where: { $0.id == id }), heartbeat.isEnabled else {
            return
        }

        let scheduledDate = max(heartbeat.nextRunAt ?? date, date)
        heartbeat.nextRunAt = heartbeat.nextScheduledRun(after: scheduledDate)
        saveChanges()
        objectWillChange.send()
    }

    func claimHeartbeatForImmediateRun(
        id: AgentHeartbeat.ID,
        at date: Date
    ) -> AgentHeartbeat? {
        guard let heartbeat = heartbeats.first(where: { $0.id == id }) else {
            return nil
        }

        heartbeat.lastRunAt = date
        if heartbeat.isEnabled {
            heartbeat.nextRunAt = heartbeat.nextScheduledRun(after: date)
        } else {
            heartbeat.nextRunAt = nil
        }
        saveChanges()
        objectWillChange.send()
        return heartbeat
    }

    func rescheduleHeartbeatAfterTimeout(id: AgentHeartbeat.ID, at date: Date) {
        guard let heartbeat = heartbeats.first(where: { $0.id == id }), heartbeat.isEnabled else {
            return
        }

        heartbeat.nextRunAt = heartbeat.nextScheduledRun(after: date)
        saveChanges()
        objectWillChange.send()
    }

    func recordHeartbeatCompletion(
        heartbeatID: AgentHeartbeat.ID,
        agentID: Agent.ID,
        report: HeartbeatExecutionReport
    ) {
        if let heartbeat = heartbeats.first(where: { $0.id == heartbeatID }) {
            heartbeat.lastCompletedAt = report.completedAt
            heartbeat.lastError = report.errorMessage
            if heartbeat.isEnabled, let retryDelay = report.retryDelay {
                heartbeat.nextRunAt = report.completedAt.addingTimeInterval(retryDelay)
            }
        }

        let shouldInsertTurn = report.chatID != nil
        let redactsDebugContent = shouldInsertTurn
            ? heartbeatRootHasRedactedContent(report.turnID)
            : false
        let persistedInvocations = redactsDebugContent
            ? Self.redactingCollaborationContent(in: report.toolInvocations)
            : report.toolInvocations
        let run = HeartbeatRun(
            id: report.runID,
            heartbeatID: heartbeatID,
            agentID: agentID,
            agentName: report.agentName,
            instruction: report.instruction,
            destination: report.destination,
            startedAt: report.startedAt,
            completedAt: report.completedAt,
            modelInput: "",
            modelOutput: nil,
            actionSummary: report.actionSummary,
            errorMessage: report.errorMessage,
            generationTurnID: shouldInsertTurn ? report.turnID : nil,
            debugCaptureEnabled: report.debugCaptureEnabled,
            promptTokenCount: report.promptTokenCount,
            completionTokenCount: report.completionTokenCount
        )
        modelContext.insert(run)
        heartbeatRuns.insert(run, at: 0)

        if shouldInsertTurn, let chatID = report.chatID {
            let turn = GenerationStore.recordTurn(
                draft: GenerationTurnDraft(
                    id: report.turnID,
                    kind: .heartbeat,
                    chatID: chatID,
                    userMessageID: nil,
                    assistantMessageID: report.assistantMessageID,
                    agentID: agentID,
                    agentName: report.agentName,
                    heartbeatID: heartbeatID,
                    heartbeatRunID: report.runID,
                    modelIdentifier: report.modelIdentifier,
                    backendRawValue: report.backendRawValue,
                    startedAt: report.startedAt,
                    completedAt: report.completedAt,
                    status: report.generationStatus,
                    actionSummary: report.actionSummary,
                    errorMessage: report.errorMessage,
                    visibleReplyPreview: GenerationStore.visibleReplyPreview(from: report.visibleReplyPreview),
                    memoryEntryCount: report.memoryEntryCount,
                    debugCaptureEnabled: report.debugCaptureEnabled
                ),
                invocations: persistedInvocations,
                debug: report.debugCaptureEnabled && !redactsDebugContent ? report.debug : nil,
                in: modelContext
            )
            if redactsDebugContent {
                turn.debugContentRedacted = true
            }
        }

        saveChanges()
        objectWillChange.send()
    }

    private func heartbeatRootHasRedactedContent(_ rootInvocationID: UUID) -> Bool {
        let descriptor = FetchDescriptor<AgentInvocationRecord>(
            predicate: #Predicate { $0.rootInvocationID == rootInvocationID }
        )
        do {
            return try modelContext.fetch(descriptor).contains(where: \.isContentRedacted)
        } catch {
            // Privacy is fail-closed: omit the debug payload if its durable
            // redaction state cannot be read.
            Self.logger.error(
                "Failed to inspect heartbeat redaction state for \(rootInvocationID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return true
        }
    }

    private static func redactingCollaborationContent(
        in invocations: [CapturedToolInvocation]
    ) -> [CapturedToolInvocation] {
        let collaborationToolNames: Set<String> = [
            AgentToolID.askAgents.rawValue,
            AgentToolID.sendToAgents.rawValue,
        ]
        return invocations.map { invocation in
            guard collaborationToolNames.contains(invocation.toolName) else {
                return invocation
            }
            var redacted = invocation
            redacted.argumentsJSON = "(redacted when an involved agent was deleted)"
            redacted.resultText = "(redacted when an involved agent was deleted)"
            redacted.errorMessage = nil
            return redacted
        }
    }

    /// A provider may ignore cancellation and exit after the scheduler has
    /// already committed the terminal timeout. Enrich that exact debug turn
    /// without changing its outcome, timestamps, scheduling, or chat state.
    func refreshTimedOutHeartbeatTrace(report: HeartbeatExecutionReport) {
        let runID = report.runID
        var descriptor = FetchDescriptor<HeartbeatRun>(
            predicate: #Predicate { $0.id == runID }
        )
        descriptor.fetchLimit = 1
        guard let run = try? modelContext.fetch(descriptor).first,
              run.generationTurnID == report.turnID else {
            return
        }

        guard report.debugCaptureEnabled,
              GenerationStore.refreshTimedOutHeartbeatTrace(
                turnID: report.turnID,
                invocations: report.toolInvocations,
                debug: report.debug,
                in: modelContext
              ) else {
            return
        }
        run.promptTokenCount = report.promptTokenCount
        run.completionTokenCount = report.completionTokenCount
        guard saveChanges() else {
            modelContext.rollback()
            return
        }
        objectWillChange.send()
    }

    private func deferHeartbeatToNextSchedule(_ heartbeat: AgentHeartbeat, from date: Date) {
        heartbeat.nextRunAt = heartbeat.nextScheduledRun(after: date)
    }

    private func rescheduleEnabledHeartbeat(_ heartbeat: AgentHeartbeat, after date: Date) {
        guard heartbeat.isEnabled else { return }
        heartbeat.nextRunAt = heartbeat.nextScheduledRun(after: date)
    }

    private func loadAgents(selecting selection: Agent.ID? = nil) {
        let descriptor = FetchDescriptor<Agent>(
            sortBy: [SortDescriptor(\.createdAt)]
        )

        do {
            agents = try modelContext.fetch(descriptor)
        } catch {
            agents = []
        }

        if agents.isEmpty {
            let agent = Agent(name: "Default", soul: "You are a concise, very quirky and goofy assistant inside a simple chat app.")
            modelContext.insert(agent)
            agents = [agent]
        }

        backfillAgentMentionHandles()
        for agent in agents { agent.migrateSplitAppleServiceTools() }
        saveChanges()

        selectedAgentID = selection.flatMap { selectedID in
            agents.contains { $0.id == selectedID } ? selectedID : nil
        } ?? selectedAgentID.flatMap { selectedID in
            agents.contains { $0.id == selectedID } ? selectedID : nil
        } ?? agents.first?.id
    }

    private func loadCollaborationGrants() {
        let descriptor = FetchDescriptor<AgentCollaborationGrant>(
            sortBy: [SortDescriptor(\.createdAt)]
        )

        do {
            collaborationGrants = try modelContext.fetch(descriptor)
        } catch {
            collaborationGrants = []
        }
    }

    private func backfillAgentMentionHandles() {
        var usedHandles = Set<String>()

        if let defaultAgent = agents.first,
           AgentMention.isDefaultPlaceholder(
               defaultAgent.mentionHandle,
               agentName: defaultAgent.name
           ) {
            defaultAgent.mentionHandle = nil
        }

        for agent in agents {
            guard let existing = AgentMention.normalizedHandle(agent.mentionHandle) else { continue }
            let unique = uniqueMentionHandle(base: existing, usedHandles: usedHandles)
            if agent.mentionHandle != unique {
                agent.mentionHandle = unique
            }
            usedHandles.insert(AgentMention.lookupKey(for: unique))
        }

        for agent in agents where AgentMention.normalizedHandle(agent.mentionHandle) == nil {
            let normalizedName = agent.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedName.isEmpty else { continue }
            let base = AgentMention.handle(for: normalizedName)
            let unique = uniqueMentionHandle(base: base, usedHandles: usedHandles)
            agent.mentionHandle = unique
            usedHandles.insert(AgentMention.lookupKey(for: unique))
        }
    }

    private func uniqueMentionHandle(
        for agentName: String,
        excluding agentID: Agent.ID? = nil
    ) -> String {
        let usedHandles = Set(
            agents.compactMap { agent -> String? in
                guard agent.id != agentID,
                      let handle = AgentMention.normalizedHandle(agent.mentionHandle) else {
                    return nil
                }
                return AgentMention.lookupKey(for: handle)
            }
        )
        return uniqueMentionHandle(
            base: AgentMention.handle(for: agentName),
            usedHandles: usedHandles
        )
    }

    private func uniqueMentionHandle(base: String, usedHandles: Set<String>) -> String {
        let normalizedBase = AgentMention.normalizedHandle(base) ?? "agent"
        guard usedHandles.contains(AgentMention.lookupKey(for: normalizedBase)) else {
            return normalizedBase
        }

        var suffix = 2
        while usedHandles.contains(AgentMention.lookupKey(for: "\(normalizedBase)\(suffix)")) {
            suffix += 1
        }
        return "\(normalizedBase)\(suffix)"
    }

    private func loadHeartbeats() {
        let descriptor = FetchDescriptor<AgentHeartbeat>(
            sortBy: [SortDescriptor(\.createdAt)]
        )

        do {
            heartbeats = try modelContext.fetch(descriptor)
        } catch {
            heartbeats = []
        }

        backfillHeartbeatTitles()

        let now = Date()
        for heartbeat in heartbeats where heartbeat.isEnabled && heartbeat.nextRunAt == nil {
            heartbeat.nextRunAt = heartbeat.nextScheduledRun(after: now)
        }
        saveChanges()
    }

    private func nextAvailableHeartbeatTitle(for agentID: Agent.ID) -> String {
        let usedTitles = Set(
            heartbeats(for: agentID).map { $0.displayTitle.lowercased() }
        )
        var number = 1
        while usedTitles.contains("heartbeat \(number)") {
            number += 1
        }
        return "Heartbeat \(number)"
    }

    private func backfillHeartbeatTitles() {
        var usedTitlesByAgent: [Agent.ID: Set<String>] = [:]
        for heartbeat in heartbeats {
            guard let title = normalizedHeartbeatTitle(heartbeat.title) else { continue }
            usedTitlesByAgent[heartbeat.agentID, default: []].insert(title.lowercased())
        }

        for heartbeat in heartbeats where heartbeat.title == nil {
            let baseTitle = heartbeatTitleSeed(from: heartbeat.instruction)
            var candidate = baseTitle
            var suffix = 2
            var usedTitles = usedTitlesByAgent[heartbeat.agentID, default: []]
            while usedTitles.contains(candidate.lowercased()) {
                candidate = "\(baseTitle) \(suffix)"
                suffix += 1
            }
            heartbeat.title = candidate
            usedTitles.insert(candidate.lowercased())
            usedTitlesByAgent[heartbeat.agentID] = usedTitles
        }
    }

    private func heartbeatTitleSeed(from instruction: String) -> String {
        let normalizedInstruction = instruction
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !normalizedInstruction.isEmpty else { return "Heartbeat" }
        guard normalizedInstruction.count > 60 else { return normalizedInstruction }
        return String(normalizedInstruction.prefix(59)) + "…"
    }

    private func normalizedHeartbeatTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let normalizedTitle = title
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return normalizedTitle.isEmpty ? nil : normalizedTitle
    }

    private func loadHeartbeatRuns() {
        var descriptor = FetchDescriptor<HeartbeatRun>(
            sortBy: [SortDescriptor(\.completedAt, order: .reverse)]
        )
        descriptor.fetchLimit = Self.heartbeatRunBatchSize

        do {
            heartbeatRuns = try modelContext.fetch(descriptor)
            hasOlderHeartbeatRuns = heartbeatRuns.count == Self.heartbeatRunBatchSize
        } catch {
            heartbeatRuns = []
            hasOlderHeartbeatRuns = false
        }

        let heartbeatsByID = Dictionary(uniqueKeysWithValues: heartbeats.map { ($0.id, $0) })
        var synchronizedHeartbeatIDs = Set<AgentHeartbeat.ID>()

        for run in heartbeatRuns where synchronizedHeartbeatIDs.insert(run.heartbeatID).inserted {
            guard let heartbeat = heartbeatsByID[run.heartbeatID] else { continue }
            // A newer completion may come from an older build that omitted
            // PASS history rows. Do not roll its scheduling state back.
            if heartbeat.lastCompletedAt.map({ $0 > run.completedAt }) == true {
                continue
            }
            heartbeat.lastCompletedAt = run.completedAt
            heartbeat.lastError = run.errorMessage
        }

        for heartbeat in heartbeats
        where heartbeat.lastCompletedAt == nil && !synchronizedHeartbeatIDs.contains(heartbeat.id) {
            let heartbeatID = heartbeat.id
            var latestRunDescriptor = FetchDescriptor<HeartbeatRun>(
                predicate: #Predicate { $0.heartbeatID == heartbeatID },
                sortBy: [SortDescriptor(\.completedAt, order: .reverse)]
            )
            latestRunDescriptor.fetchLimit = 1
            if let latestRun = try? modelContext.fetch(latestRunDescriptor).first {
                heartbeat.lastCompletedAt = latestRun.completedAt
                heartbeat.lastError = latestRun.errorMessage
            }
        }
        saveChanges()
    }

    @discardableResult
    private func saveChanges() -> Bool {
        guard modelContext.hasChanges else { return true }

        do {
            try modelContext.save()
            return true
        } catch {
            Self.logger.error("Failed to save agents: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

@Model
final class AgentCollaborationGrant: Identifiable {
    #Unique<AgentCollaborationGrant>([\.callerAgentID, \.targetAgentID])
    #Index<AgentCollaborationGrant>(
        [\.callerAgentID, \.targetAgentID],
        [\.targetAgentID]
    )

    @Attribute(.unique) var id: UUID
    var callerAgentID: UUID
    var targetAgentID: UUID
    var canConsult: Bool
    var canDispatch: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        callerAgentID: UUID,
        targetAgentID: UUID,
        canConsult: Bool = false,
        canDispatch: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.callerAgentID = callerAgentID
        self.targetAgentID = targetAgentID
        self.canConsult = canConsult
        self.canDispatch = canDispatch
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func allows(_ mode: AgentDelegationMode) -> Bool {
        switch mode {
        case .consult:
            return canConsult
        case .dispatch:
            return canDispatch
        }
    }

    func setAllowed(_ allowed: Bool, for mode: AgentDelegationMode) {
        switch mode {
        case .consult:
            canConsult = allowed
        case .dispatch:
            canDispatch = allowed
        }
    }
}

@Model
final class SuppressedAgentInvocationRoot {
    @Attribute(.unique) var rootInvocationID: UUID
    var createdAt: Date
    /// Retained only for compatibility with stores written by builds that
    /// suppressed heartbeat PASS traces. New runs never set this flag.
    var generationTraceSuppressionPending: Bool?

    init(
        rootInvocationID: UUID,
        createdAt: Date = .now,
        generationTraceSuppressionPending: Bool = false
    ) {
        self.rootInvocationID = rootInvocationID
        self.createdAt = createdAt
        self.generationTraceSuppressionPending = generationTraceSuppressionPending
    }
}

@Model
final class AgentInvocationRecord: Identifiable {
    #Index<AgentInvocationRecord>(
        [\.rootInvocationID, \.startedAt],
        [\.parentInvocationID],
        [\.callerAgentID, \.startedAt],
        [\.targetAgentID, \.startedAt]
    )

    @Attribute(.unique) var id: UUID
    var rootInvocationID: UUID
    var parentInvocationID: UUID?
    var callerAgentID: UUID
    var targetAgentID: UUID
    var callerName: String
    var targetName: String
    var modeRawValue: String
    var stateRawValue: String
    var taskPreview: String
    var resultPreview: String?
    var errorMessage: String?
    var toolTraceSummary: String?
    var debugLogJSON: String?
    /// Compatibility bit written by older builds that hid heartbeat PASS
    /// traces. New runs leave it false and startup migration clears old flags.
    var logSuppressed: Bool?
    /// Set when an involved agent is deleted. This is a durable tombstone so
    /// cancellation-resistant providers cannot repopulate redacted content.
    var contentRedacted: Bool?
    var modelIdentifier: String
    var backendRawValue: String
    var depth: Int
    var startedAt: Date
    var modelStartedAt: Date?
    var completedAt: Date?
    var promptTokenCount: Int?
    var completionTokenCount: Int?
    var pendingDeliveryText: String?
    var deliveryCompletedAt: Date?

    init(
        id: UUID = UUID(),
        rootInvocationID: UUID,
        parentInvocationID: UUID? = nil,
        callerAgentID: UUID,
        targetAgentID: UUID,
        callerName: String,
        targetName: String,
        mode: AgentDelegationMode,
        state: AgentInvocationState,
        taskPreview: String,
        resultPreview: String? = nil,
        errorMessage: String? = nil,
        toolTraceSummary: String? = nil,
        debugLogJSON: String? = nil,
        logSuppressed: Bool? = nil,
        contentRedacted: Bool? = nil,
        modelIdentifier: String,
        backendRawValue: String,
        depth: Int,
        startedAt: Date = .now,
        modelStartedAt: Date? = nil,
        completedAt: Date? = nil,
        promptTokenCount: Int? = nil,
        completionTokenCount: Int? = nil,
        pendingDeliveryText: String? = nil,
        deliveryCompletedAt: Date? = nil
    ) {
        self.id = id
        self.rootInvocationID = rootInvocationID
        self.parentInvocationID = parentInvocationID
        self.callerAgentID = callerAgentID
        self.targetAgentID = targetAgentID
        self.callerName = callerName
        self.targetName = targetName
        modeRawValue = mode.rawValue
        stateRawValue = state.rawValue
        self.taskPreview = taskPreview
        self.resultPreview = resultPreview
        self.errorMessage = errorMessage
        self.toolTraceSummary = toolTraceSummary
        self.debugLogJSON = debugLogJSON
        self.logSuppressed = logSuppressed
        self.contentRedacted = contentRedacted
        self.modelIdentifier = modelIdentifier
        self.backendRawValue = backendRawValue
        self.depth = depth
        self.startedAt = startedAt
        self.modelStartedAt = modelStartedAt
        self.completedAt = completedAt
        self.promptTokenCount = promptTokenCount
        self.completionTokenCount = completionTokenCount
        self.pendingDeliveryText = pendingDeliveryText
        self.deliveryCompletedAt = deliveryCompletedAt
    }

    var mode: AgentDelegationMode {
        AgentDelegationMode(rawValue: modeRawValue) ?? .consult
    }

    var state: AgentInvocationState {
        get { AgentInvocationState(rawValue: stateRawValue) ?? .failed }
        set { stateRawValue = newValue.rawValue }
    }

    var totalTokenCount: Int? {
        guard promptTokenCount != nil || completionTokenCount != nil else { return nil }
        return (promptTokenCount ?? 0) + (completionTokenCount ?? 0)
    }

    var debugLog: AgentInvocationDebugLog? {
        AgentInvocationDebugLog.decode(debugLogJSON)
    }

    var isLogSuppressed: Bool {
        logSuppressed == true
    }

    var isContentRedacted: Bool {
        contentRedacted == true
    }
}

@Model
final class Agent: Identifiable {
    @Attribute(.unique) var id: UUID
    var name: String
    var soul: String
    var mentionHandle: String?
    var routingDescription: String?
    var memory: String?
    var modelIdentifier: String?
    var voiceTriggerPhrase: String?
    var textToSpeechToolID: UUID?
    var textToSpeechVoiceName: String?
    var textToSpeechVoiceModel: String?
    var enabledToolIDsJSON: String?
    var enabledSkillIDsJSON: String?
    var debugLogEnabled: Bool?
    var hiddenFromSidebar: Bool?
    var calendarAccessAll: Bool?
    var allowedCalendarIDsJSON: String?
    var appleServiceGrantsJSON: String?
    @Attribute(.externalStorage) var avatarImageData: Data?
    var avatarCropZoom: Double?
    var avatarCropOffsetX: Double?
    var avatarCropOffsetY: Double?
    var avatarPlaceholderColorHex: String?
    var dreamOverrideRawValue: String?
    var dreamLightPromptOverride: String?
    var dreamREMPromptOverride: String?
    var dreamUsesScheduleOverride: Bool?
    var dreamScheduleKindRawValue: String?
    var dreamIntervalMinutes: Int?
    var dreamWeekdayMask: Int?
    var dreamScheduledTimeMinutes: Int?
    var dreamLightModelIdentifierOverride: String?
    var dreamREMModelIdentifierOverride: String?
    var lastDreamCompletedAt: Date?
    var nextDreamRunAt: Date?
    var lastDreamError: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        soul: String,
        mentionHandle: String? = nil,
        routingDescription: String? = nil,
        memory: String? = nil,
        modelIdentifier: String? = nil,
        voiceTriggerPhrase: String? = nil,
        textToSpeechToolID: UUID? = nil,
        textToSpeechVoiceName: String? = nil,
        textToSpeechVoiceModel: String? = nil,
        enabledToolIDsJSON: String? = nil,
        enabledSkillIDsJSON: String? = nil,
        debugLogEnabled: Bool? = nil,
        hiddenFromSidebar: Bool? = nil,
        calendarAccessAll: Bool? = nil,
        allowedCalendarIDsJSON: String? = nil,
        avatarImageData: Data? = nil,
        avatarCropZoom: Double? = nil,
        avatarCropOffsetX: Double? = nil,
        avatarCropOffsetY: Double? = nil,
        avatarPlaceholderColorHex: String? = nil,
        dreamOverrideRawValue: String? = nil,
        dreamLightPromptOverride: String? = nil,
        dreamREMPromptOverride: String? = nil,
        dreamUsesScheduleOverride: Bool? = nil,
        dreamScheduleKindRawValue: String? = nil,
        dreamIntervalMinutes: Int? = nil,
        dreamWeekdayMask: Int? = nil,
        dreamScheduledTimeMinutes: Int? = nil,
        dreamLightModelIdentifierOverride: String? = nil,
        dreamREMModelIdentifierOverride: String? = nil,
        lastDreamCompletedAt: Date? = nil,
        nextDreamRunAt: Date? = nil,
        lastDreamError: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.soul = soul
        self.mentionHandle = mentionHandle
        self.routingDescription = routingDescription
        self.memory = memory
        self.modelIdentifier = modelIdentifier
        self.voiceTriggerPhrase = voiceTriggerPhrase
        self.textToSpeechToolID = textToSpeechToolID
        self.textToSpeechVoiceName = textToSpeechVoiceName
        self.textToSpeechVoiceModel = textToSpeechVoiceModel
        self.enabledToolIDsJSON = enabledToolIDsJSON
        self.enabledSkillIDsJSON = enabledSkillIDsJSON
        self.debugLogEnabled = debugLogEnabled
        self.hiddenFromSidebar = hiddenFromSidebar
        self.calendarAccessAll = calendarAccessAll
        self.allowedCalendarIDsJSON = allowedCalendarIDsJSON
        self.avatarImageData = avatarImageData
        self.avatarCropZoom = avatarCropZoom
        self.avatarCropOffsetX = avatarCropOffsetX
        self.avatarCropOffsetY = avatarCropOffsetY
        self.avatarPlaceholderColorHex = avatarPlaceholderColorHex
        self.dreamOverrideRawValue = dreamOverrideRawValue
        self.dreamLightPromptOverride = dreamLightPromptOverride
        self.dreamREMPromptOverride = dreamREMPromptOverride
        self.dreamUsesScheduleOverride = dreamUsesScheduleOverride
        self.dreamScheduleKindRawValue = dreamScheduleKindRawValue
        self.dreamIntervalMinutes = dreamIntervalMinutes
        self.dreamWeekdayMask = dreamWeekdayMask
        self.dreamScheduledTimeMinutes = dreamScheduledTimeMinutes
        self.dreamLightModelIdentifierOverride = dreamLightModelIdentifierOverride
        self.dreamREMModelIdentifierOverride = dreamREMModelIdentifierOverride
        self.lastDreamCompletedAt = lastDreamCompletedAt
        self.nextDreamRunAt = nextDreamRunAt
        self.lastDreamError = lastDreamError
        self.createdAt = createdAt
    }

    var appleServiceGrants: [String: AppleServiceGrant] {
        guard let data = appleServiceGrantsJSON?.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: AppleServiceGrant].self, from: data)) ?? [:]
    }

    @MainActor
    func setAppleServiceGrant(_ service: AppleServiceID, grant: AppleServiceGrant) {
        AppleServiceRuntime.shared.revoke(agentID: id)
        var grants = appleServiceGrants
        grants[service.rawValue] = grant
        if let data = try? JSONEncoder().encode(grants) { appleServiceGrantsJSON = String(decoding: data, as: UTF8.self) }
        if grant.enabled {
            UserDefaults.standard.set(true, forKey: "appleServicesContentUsed")
        }
    }

    var displayName: String {
        name.isEmpty ? "Untitled Agent" : name
    }

    var routingDescriptionText: String {
        routingDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var selectedModelIdentifier: String {
        modelIdentifier ?? ChatModelIdentifier.appleFoundation
    }

    var memoryText: String {
        memory ?? ""
    }

    var isDebugLogEnabled: Bool {
        debugLogEnabled == true
    }

    var isVisibleInSidebar: Bool {
        hiddenFromSidebar != true
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

    func isToolEnabled(_ toolID: AgentToolID) -> Bool {
        enabledIDs(from: enabledToolIDsJSON).contains(toolID.rawValue)
    }

    func isSkillEnabled(_ skillID: String) -> Bool {
        enabledIDs(from: enabledSkillIDsJSON).contains(skillID)
    }

    /// Applies the one-time split of the old combined Apple Services tool; see
    /// `AgentToolID.migratingLegacyAppleServices`. Service grants still decide access.
    @discardableResult
    func migrateSplitAppleServiceTools() -> Bool {
        let ids = enabledIDs(from: enabledToolIDsJSON)
        let migrated = AgentToolID.migratingLegacyAppleServices(ids)
        guard migrated != ids, let data = try? JSONEncoder().encode(migrated.sorted()) else { return false }
        enabledToolIDsJSON = String(decoding: data, as: UTF8.self)
        return true
    }

    func setTool(_ toolID: AgentToolID, enabled: Bool) {
        enabledToolIDsJSON = updatedEnabledIDs(enabledToolIDsJSON, id: toolID.rawValue, enabled: enabled)
        if toolID == .readCalendarEvents, enabled, calendarAccessAll == nil {
            calendarAccessAll = true
        }
    }

    var allowsAllCalendars: Bool {
        calendarAccessAll ?? true
    }

    var allowedCalendarIDs: Set<String> {
        enabledIDs(from: allowedCalendarIDsJSON)
    }

    var calendarAccessPolicy: CalendarAccessPolicy {
        CalendarAccessPolicy(allowsAll: allowsAllCalendars, allowedIDs: allowedCalendarIDs)
    }

    func setCalendarAccessAll(_ all: Bool, selecting ids: [String] = []) {
        calendarAccessAll = all
        if !all, allowedCalendarIDs.isEmpty, !ids.isEmpty {
            var json: String?
            for id in ids {
                json = updatedEnabledIDs(json, id: id, enabled: true)
            }
            allowedCalendarIDsJSON = json
        }
    }

    func setAllowedCalendarID(_ id: String, enabled: Bool) {
        calendarAccessAll = false
        allowedCalendarIDsJSON = updatedEnabledIDs(allowedCalendarIDsJSON, id: id, enabled: enabled)
    }

    func setSkill(_ skillID: String, enabled: Bool) {
        enabledSkillIDsJSON = updatedEnabledIDs(enabledSkillIDsJSON, id: skillID, enabled: enabled)
    }

    private func enabledIDs(from json: String?) -> Set<String> {
        guard let json, let data = json.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(values)
    }

    private func updatedEnabledIDs(_ json: String?, id: String, enabled: Bool) -> String? {
        var ids = enabledIDs(from: json)
        if enabled {
            ids.insert(id)
        } else {
            ids.remove(id)
        }
        guard !ids.isEmpty,
              let data = try? JSONEncoder().encode(ids.sorted()),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
