import Combine
import Foundation
import SwiftData

@MainActor
final class AgentStore: ObservableObject {
    @Published private(set) var agents: [Agent] = []
    @Published private(set) var heartbeats: [AgentHeartbeat] = []
    @Published private(set) var heartbeatRuns: [HeartbeatRun] = []
    @Published private(set) var hasOlderHeartbeatRuns = false
    @Published var selectedAgentID: Agent.ID?

    private static let heartbeatRunBatchSize = 200

    private let modelContext: ModelContext
    private var isLoadingOlderHeartbeatRuns = false

    var selectedAgent: Agent? {
        guard let selectedAgentID else { return nil }
        return agents.first { $0.id == selectedAgentID }
    }

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        loadAgents()
        loadHeartbeats()
        loadHeartbeatRuns()
    }

    func addAgent() {
        let agent = Agent(name: "", soul: "")
        modelContext.insert(agent)
        saveChanges()
        loadAgents(selecting: agent.id)
    }

    func removeSelectedAgent() {
        guard let selectedAgentID,
              let index = agents.firstIndex(where: { $0.id == selectedAgentID }) else {
            return
        }

        let nextSelection: Agent.ID?
        if agents.count <= 1 {
            nextSelection = nil
        } else {
            let nextIndex = min(index, agents.count - 2)
            nextSelection = agents[nextIndex == index ? index + 1 : nextIndex].id
        }

        let heartbeatsToDelete = heartbeats.filter { $0.agentID == selectedAgentID }
        for heartbeat in heartbeatsToDelete {
            modelContext.delete(heartbeat)
        }
        heartbeats.removeAll { $0.agentID == selectedAgentID }
        modelContext.delete(agents[index])
        saveChanges()
        loadAgents(selecting: nextSelection)
    }

    func updateAgentName(id: Agent.ID, name: String) {
        guard let agent = agents.first(where: { $0.id == id }) else { return }

        agent.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        saveChanges()
        objectWillChange.send()
    }

    func updateAgentSoul(id: Agent.ID, soul: String) {
        guard let agent = agents.first(where: { $0.id == id }) else { return }

        agent.soul = soul
        saveChanges()
        objectWillChange.send()
    }

    func updateAgentMemory(id: Agent.ID, memory: String) {
        guard let agent = agents.first(where: { $0.id == id }) else { return }

        agent.memory = memory
        saveChanges()
        objectWillChange.send()
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
    }

    func setTool(_ toolID: AgentToolID, enabled: Bool, for agentID: Agent.ID) {
        guard let agent = agents.first(where: { $0.id == agentID }) else { return }
        agent.setTool(toolID, enabled: enabled)
        saveChanges()
        objectWillChange.send()
    }

    func setCalendarAccessAll(_ all: Bool, selecting ids: [String] = [], for agentID: Agent.ID) {
        guard let agent = agents.first(where: { $0.id == agentID }) else { return }
        agent.setCalendarAccessAll(all, selecting: ids)
        saveChanges()
        objectWillChange.send()
    }

    func setAllowedCalendarID(_ id: String, enabled: Bool, for agentID: Agent.ID) {
        guard let agent = agents.first(where: { $0.id == agentID }) else { return }
        agent.setAllowedCalendarID(id, enabled: enabled)
        saveChanges()
        objectWillChange.send()
    }

    func setSkill(_ skillID: String, enabled: Bool, for agentID: Agent.ID) {
        guard let agent = agents.first(where: { $0.id == agentID }) else { return }
        agent.setSkill(skillID, enabled: enabled)
        saveChanges()
        objectWillChange.send()
    }

    func updateAgentDebugLog(id: Agent.ID, enabled: Bool) {
        guard let agent = agents.first(where: { $0.id == id }) else { return }
        agent.debugLogEnabled = enabled
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

    func heartbeats(for agentID: Agent.ID) -> [AgentHeartbeat] {
        heartbeats.filter { $0.agentID == agentID }
    }

    func addHeartbeat(to agentID: Agent.ID) {
        let heartbeat = AgentHeartbeat(agentID: agentID)
        modelContext.insert(heartbeat)
        heartbeats.append(heartbeat)
        saveChanges()
        objectWillChange.send()
    }

    func removeHeartbeat(_ heartbeat: AgentHeartbeat) {
        modelContext.delete(heartbeat)
        heartbeats.removeAll { $0.id == heartbeat.id }
        saveChanges()
        objectWillChange.send()
    }

    func updateHeartbeatInstruction(_ heartbeat: AgentHeartbeat, instruction: String) {
        heartbeat.instruction = instruction
        heartbeat.lastError = nil
        saveChanges()
        objectWillChange.send()
    }

    func updateHeartbeatInterval(_ heartbeat: AgentHeartbeat, minutes: Int) {
        heartbeat.intervalMinutes = min(max(minutes, 1), 10_080)
        if heartbeat.isEnabled {
            heartbeat.nextRunAt = Date().addingTimeInterval(TimeInterval(heartbeat.intervalMinutes * 60))
        }
        saveChanges()
        objectWillChange.send()
    }

    func updateHeartbeatEnabled(_ heartbeat: AgentHeartbeat, isEnabled: Bool) {
        heartbeat.isEnabled = isEnabled
        heartbeat.nextRunAt = isEnabled
            ? Date().addingTimeInterval(TimeInterval(heartbeat.normalizedIntervalMinutes * 60))
            : nil
        heartbeat.lastError = nil
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
        heartbeat.lastError = nil
        saveChanges()
        objectWillChange.send()
    }

    func updateHeartbeatModelIdentifier(
        _ heartbeat: AgentHeartbeat,
        modelIdentifier: String?
    ) {
        heartbeat.modelIdentifier = modelIdentifier
        heartbeat.lastError = nil
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

    func deferHeartbeatForOverlap(id: AgentHeartbeat.ID, at date: Date) {
        guard let heartbeat = heartbeats.first(where: { $0.id == id }), heartbeat.isEnabled else {
            return
        }

        deferHeartbeatByInterval(heartbeat, from: date)
        saveChanges()
        objectWillChange.send()
    }

    func skipHeartbeat(id: AgentHeartbeat.ID, at date: Date) {
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
        id: AgentHeartbeat.ID,
        at date: Date
    ) -> AgentHeartbeat? {
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

    func rescheduleHeartbeatAfterTimeout(id: AgentHeartbeat.ID, at date: Date) {
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
            promptTokenCount: report.promptTokenCount,
            completionTokenCount: report.completionTokenCount
        )
        modelContext.insert(run)
        heartbeatRuns.insert(run, at: 0)

        if let chatID = report.chatID {
            GenerationStore.recordTurn(
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
                invocations: report.toolInvocations,
                debug: report.debugCaptureEnabled ? report.debug : nil,
                in: modelContext
            )
        }

        saveChanges()
        objectWillChange.send()
    }

    private func deferHeartbeatByInterval(_ heartbeat: AgentHeartbeat, from date: Date) {
        heartbeat.nextRunAt = date.addingTimeInterval(
            TimeInterval(heartbeat.normalizedIntervalMinutes * 60)
        )
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
            saveChanges()
            agents = [agent]
        }

        selectedAgentID = selection.flatMap { selectedID in
            agents.contains { $0.id == selectedID } ? selectedID : nil
        } ?? selectedAgentID.flatMap { selectedID in
            agents.contains { $0.id == selectedID } ? selectedID : nil
        } ?? agents.first?.id
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

        let now = Date()
        for heartbeat in heartbeats where heartbeat.isEnabled && heartbeat.nextRunAt == nil {
            heartbeat.nextRunAt = now.addingTimeInterval(
                TimeInterval(heartbeat.normalizedIntervalMinutes * 60)
            )
        }
        saveChanges()
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

        for heartbeat in heartbeats where heartbeat.lastCompletedAt == nil {
            let heartbeatID = heartbeat.id
            var latestRunDescriptor = FetchDescriptor<HeartbeatRun>(
                predicate: #Predicate { $0.heartbeatID == heartbeatID },
                sortBy: [SortDescriptor(\.completedAt, order: .reverse)]
            )
            latestRunDescriptor.fetchLimit = 1
            heartbeat.lastCompletedAt = try? modelContext.fetch(latestRunDescriptor).first?.completedAt
        }
        saveChanges()
    }

    private func saveChanges() {
        guard modelContext.hasChanges else { return }

        do {
            try modelContext.save()
        } catch {
            assertionFailure("Failed to save agents: \(error.localizedDescription)")
        }
    }
}

@Model
final class Agent: Identifiable {
    @Attribute(.unique) var id: UUID
    var name: String
    var soul: String
    var memory: String?
    var modelIdentifier: String?
    var voiceTriggerPhrase: String?
    var textToSpeechToolID: UUID?
    var textToSpeechVoiceName: String?
    var textToSpeechVoiceModel: String?
    var enabledToolIDsJSON: String?
    var enabledSkillIDsJSON: String?
    var debugLogEnabled: Bool?
    var calendarAccessAll: Bool?
    var allowedCalendarIDsJSON: String?
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
        enabledToolIDsJSON: String? = nil,
        enabledSkillIDsJSON: String? = nil,
        debugLogEnabled: Bool? = nil,
        calendarAccessAll: Bool? = nil,
        allowedCalendarIDsJSON: String? = nil,
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
        self.enabledToolIDsJSON = enabledToolIDsJSON
        self.enabledSkillIDsJSON = enabledSkillIDsJSON
        self.debugLogEnabled = debugLogEnabled
        self.calendarAccessAll = calendarAccessAll
        self.allowedCalendarIDsJSON = allowedCalendarIDsJSON
        self.createdAt = createdAt
    }

    var displayName: String {
        name.isEmpty ? "Untitled Agent" : name
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
