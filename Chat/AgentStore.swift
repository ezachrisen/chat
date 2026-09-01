import Combine
import Foundation
import os
import SwiftData

@MainActor
final class AgentStore: ObservableObject {
    private static let logger = Logger(subsystem: "Chat", category: "Agents")

    @Published private(set) var agents: [Agent] = []
    @Published private(set) var heartbeats: [AgentHeartbeat] = []
    @Published private(set) var heartbeatRuns: [HeartbeatRun] = []
    @Published private(set) var hasOlderHeartbeatRuns = false
    @Published var selectedAgentID: Agent.ID?
    let agentConfigurationDidChange = PassthroughSubject<Agent.ID, Never>()

    private static let heartbeatRunBatchSize = 200

    private let modelContext: ModelContext
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
        modelContext.delete(agents[index])
        beforeSaving()
        guard saveChanges() else {
            modelContext.rollback()
            loadAgents(selecting: previousSelection)
            loadHeartbeats()
            return false
        }
        loadAgents(selecting: nextSelection)
        return true
    }

    func updateAgentName(id: Agent.ID, name: String) {
        guard let agent = agents.first(where: { $0.id == id }) else { return }

        agent.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        saveChanges()
        objectWillChange.send()
        agentConfigurationDidChange.send(id)
    }

    func updateAgentSoul(id: Agent.ID, soul: String) {
        guard let agent = agents.first(where: { $0.id == id }) else { return }

        agent.soul = soul
        saveChanges()
        objectWillChange.send()
        agentConfigurationDidChange.send(id)
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
        agentConfigurationDidChange.send(id)
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
        claimedHeartbeat.nextRunAt = date.addingTimeInterval(
            TimeInterval(claimedHeartbeat.normalizedIntervalMinutes * 60)
        )

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

        backfillHeartbeatTitles()

        let now = Date()
        for heartbeat in heartbeats where heartbeat.isEnabled && heartbeat.nextRunAt == nil {
            heartbeat.nextRunAt = now.addingTimeInterval(
                TimeInterval(heartbeat.normalizedIntervalMinutes * 60)
            )
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
    @Attribute(.externalStorage) var avatarImageData: Data?
    var avatarCropZoom: Double?
    var avatarCropOffsetX: Double?
    var avatarCropOffsetY: Double?
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
        avatarImageData: Data? = nil,
        avatarCropZoom: Double? = nil,
        avatarCropOffsetX: Double? = nil,
        avatarCropOffsetY: Double? = nil,
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
        self.avatarImageData = avatarImageData
        self.avatarCropZoom = avatarCropZoom
        self.avatarCropOffsetX = avatarCropOffsetX
        self.avatarCropOffsetY = avatarCropOffsetY
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
