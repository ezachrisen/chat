import Combine
import Foundation
import FoundationModels
import SwiftData

enum DreamOverride: String, CaseIterable, Identifiable {
    case inherit
    case enabled
    case disabled

    var id: Self { self }

    var label: String {
        switch self {
        case .inherit: "Use app setting"
        case .enabled: "Enabled"
        case .disabled: "Disabled"
        }
    }
}

enum DreamModelChoice {
    static let agentDefault = "__agent_default__"
}

@Model
final class DreamConfiguration {
    @Attribute(.unique) var id: UUID
    var isEnabled: Bool
    var lightPrompt: String
    var remPrompt: String
    var scheduleKindRawValue: String
    var intervalMinutes: Int
    var weekdayMask: Int
    var scheduledTimeMinutes: Int
    var lightModelIdentifier: String?
    var remModelIdentifier: String?
    var lastRunAt: Date?
    var nextRunAt: Date?

    init(
        id: UUID = UUID(),
        isEnabled: Bool = false,
        lightPrompt: String = DreamDefaults.lightPrompt,
        remPrompt: String = DreamDefaults.remPrompt,
        scheduleKind: HeartbeatScheduleKind = .interval,
        intervalMinutes: Int = 12 * 60,
        weekdayMask: Int = HeartbeatWeekday.allMask,
        scheduledTimeMinutes: Int = 2 * 60,
        lightModelIdentifier: String? = nil,
        remModelIdentifier: String? = nil,
        lastRunAt: Date? = nil,
        nextRunAt: Date? = nil
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.lightPrompt = lightPrompt
        self.remPrompt = remPrompt
        self.scheduleKindRawValue = scheduleKind.rawValue
        self.intervalMinutes = intervalMinutes
        self.weekdayMask = weekdayMask
        self.scheduledTimeMinutes = scheduledTimeMinutes
        self.lightModelIdentifier = lightModelIdentifier
        self.remModelIdentifier = remModelIdentifier
        self.lastRunAt = lastRunAt
        self.nextRunAt = nextRunAt
    }

    var scheduleKind: HeartbeatScheduleKind {
        HeartbeatScheduleKind(rawValue: scheduleKindRawValue) ?? .interval
    }

    var schedule: DreamSchedule {
        DreamSchedule(
            kind: scheduleKind,
            intervalMinutes: intervalMinutes,
            weekdayMask: weekdayMask,
            scheduledTimeMinutes: scheduledTimeMinutes
        )
    }
}

struct DreamSchedule {
    var kind: HeartbeatScheduleKind
    var intervalMinutes: Int
    var weekdayMask: Int
    var scheduledTimeMinutes: Int

    var normalizedIntervalMinutes: Int { min(max(intervalMinutes, 1), 10_080) }
    var normalizedWeekdayMask: Int {
        let value = weekdayMask & HeartbeatWeekday.allMask
        return value == 0 ? HeartbeatWeekday.allMask : value
    }
    var normalizedScheduledTimeMinutes: Int { min(max(scheduledTimeMinutes, 0), 1_439) }

    func nextRun(after date: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        switch kind {
        case .interval:
            var candidate = date.addingTimeInterval(TimeInterval(normalizedIntervalMinutes * 60))
            for _ in 0..<8 {
                if allows(candidate, calendar: calendar) { return candidate }
                candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
            }
            return candidate
        case .specificTime:
            let components = DateComponents(
                hour: normalizedScheduledTimeMinutes / 60,
                minute: normalizedScheduledTimeMinutes % 60
            )
            var cursor = date
            for _ in 0..<14 {
                guard let candidate = calendar.nextDate(
                    after: cursor,
                    matching: components,
                    matchingPolicy: .nextTime,
                    repeatedTimePolicy: .first
                ) else { break }
                if allows(candidate, calendar: calendar) { return candidate }
                cursor = candidate.addingTimeInterval(1)
            }
            return date.addingTimeInterval(86_400)
        }
    }

    private func allows(_ date: Date, calendar: Calendar) -> Bool {
        guard let weekday = HeartbeatWeekday(rawValue: calendar.component(.weekday, from: date)) else {
            return true
        }
        return normalizedWeekdayMask & weekday.bit != 0
    }
}

enum DreamDefaults {
    static let lightPrompt = """
    Review the supplied conversation transcript as a light-sleep reflection. Identify only facts, preferences, relationships, commitments, recurring patterns, and lessons that may remain useful in future conversations. Produce concise candidate memories. Do not promote anything to permanent memory yet. Ignore routine chatter, transient status, and information already present in permanent memory.
    """

    static let remPrompt = """
    Review the Light Dream candidate memories against the agent's existing permanent Memory. Promote only durable, genuinely useful information that is not already stored. Put each memory to append inside [[MEMORY]] and [[/MEMORY]] markers. Never rewrite or delete existing memory. If nothing deserves promotion, return exactly [[PASS]].
    """
}

extension Agent {
    var dreamOverride: DreamOverride {
        DreamOverride(rawValue: dreamOverrideRawValue ?? "") ?? .inherit
    }

    var usesDreamScheduleOverride: Bool { dreamUsesScheduleOverride == true }

    var dreamSchedule: DreamSchedule {
        DreamSchedule(
            kind: HeartbeatScheduleKind(rawValue: dreamScheduleKindRawValue ?? "") ?? .interval,
            intervalMinutes: dreamIntervalMinutes ?? (12 * 60),
            weekdayMask: dreamWeekdayMask ?? HeartbeatWeekday.allMask,
            scheduledTimeMinutes: dreamScheduledTimeMinutes ?? (2 * 60)
        )
    }
}

@MainActor
extension AgentStore {
    static func loadOrCreateDreamSettings(in context: ModelContext) -> DreamConfiguration {
        var descriptor = FetchDescriptor<DreamConfiguration>()
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first { return existing }
        let settings = DreamConfiguration()
        context.insert(settings)
        try? context.save()
        return settings
    }

    func prepareDreamSchedule(at date: Date) {
        if dreamSettings.nextRunAt == nil {
            dreamSettings.nextRunAt = dreamSettings.schedule.nextRun(after: date)
        }
        for agent in agents where agent.usesDreamScheduleOverride && agent.nextDreamRunAt == nil {
            agent.nextDreamRunAt = agent.dreamSchedule.nextRun(after: date)
        }
        try? modelContext.save()
        objectWillChange.send()
    }

    func isDreamEnabled(for agent: Agent) -> Bool {
        switch agent.dreamOverride {
        case .inherit: dreamSettings.isEnabled
        case .enabled: true
        case .disabled: false
        }
    }

    func claimAgentsDueToDream(at date: Date) -> [Agent.ID] {
        var due: [(date: Date, createdAt: Date, id: Agent.ID)] = []
        if (dreamSettings.nextRunAt ?? .distantFuture) <= date {
            let scheduled = dreamSettings.nextRunAt ?? date
            for agent in agents where !agent.usesDreamScheduleOverride && isDreamEnabled(for: agent) {
                due.append((scheduled, agent.createdAt, agent.id))
            }
            dreamSettings.lastRunAt = date
            dreamSettings.nextRunAt = dreamSettings.schedule.nextRun(after: date)
        }

        for agent in agents where agent.usesDreamScheduleOverride && isDreamEnabled(for: agent) {
            guard let next = agent.nextDreamRunAt, next <= date else { continue }
            due.append((next, agent.createdAt, agent.id))
            agent.nextDreamRunAt = agent.dreamSchedule.nextRun(after: date)
        }
        guard !due.isEmpty else { return [] }
        try? modelContext.save()
        objectWillChange.send()
        return due.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }.map { $0.id }
    }

    func updateDreamEnabled(_ enabled: Bool) {
        dreamSettings.isEnabled = enabled
        persistDreamSettings()
    }

    func updateDreamLightPrompt(_ prompt: String) {
        dreamSettings.lightPrompt = prompt
        persistDreamSettings()
    }

    func updateDreamREMPrompt(_ prompt: String) {
        dreamSettings.remPrompt = prompt
        persistDreamSettings()
    }

    func updateDreamSchedule(
        kind: HeartbeatScheduleKind? = nil,
        intervalMinutes: Int? = nil,
        weekdayMask: Int? = nil,
        scheduledTimeMinutes: Int? = nil
    ) {
        if let kind { dreamSettings.scheduleKindRawValue = kind.rawValue }
        if let intervalMinutes { dreamSettings.intervalMinutes = min(max(intervalMinutes, 1), 10_080) }
        if let weekdayMask, weekdayMask & HeartbeatWeekday.allMask != 0 {
            dreamSettings.weekdayMask = weekdayMask & HeartbeatWeekday.allMask
        }
        if let scheduledTimeMinutes {
            dreamSettings.scheduledTimeMinutes = min(max(scheduledTimeMinutes, 0), 1_439)
        }
        dreamSettings.nextRunAt = dreamSettings.schedule.nextRun(after: .now)
        persistDreamSettings()
    }

    func updateDreamModels(light: String?, rem: String?) {
        dreamSettings.lightModelIdentifier = light
        dreamSettings.remModelIdentifier = rem
        persistDreamSettings()
    }

    func updateAgentDreamOverride(_ agent: Agent, override: DreamOverride) {
        agent.dreamOverrideRawValue = override.rawValue
        persistDreamSettings()
    }

    func updateAgentDreamPrompts(_ agent: Agent, light: String?, rem: String?) {
        agent.dreamLightPromptOverride = normalizedDreamText(light)
        agent.dreamREMPromptOverride = normalizedDreamText(rem)
        persistDreamSettings()
    }

    func updateAgentDreamModels(_ agent: Agent, light: String?, rem: String?) {
        agent.dreamLightModelIdentifierOverride = light
        agent.dreamREMModelIdentifierOverride = rem
        persistDreamSettings()
    }

    func updateAgentDreamScheduleOverride(_ agent: Agent, enabled: Bool) {
        agent.dreamUsesScheduleOverride = enabled
        agent.nextDreamRunAt = enabled ? agent.dreamSchedule.nextRun(after: .now) : nil
        persistDreamSettings()
    }

    func updateAgentDreamSchedule(
        _ agent: Agent,
        kind: HeartbeatScheduleKind? = nil,
        intervalMinutes: Int? = nil,
        weekdayMask: Int? = nil,
        scheduledTimeMinutes: Int? = nil
    ) {
        if let kind { agent.dreamScheduleKindRawValue = kind.rawValue }
        if let intervalMinutes { agent.dreamIntervalMinutes = min(max(intervalMinutes, 1), 10_080) }
        if let weekdayMask, weekdayMask & HeartbeatWeekday.allMask != 0 {
            agent.dreamWeekdayMask = weekdayMask & HeartbeatWeekday.allMask
        }
        if let scheduledTimeMinutes {
            agent.dreamScheduledTimeMinutes = min(max(scheduledTimeMinutes, 0), 1_439)
        }
        if agent.usesDreamScheduleOverride {
            agent.nextDreamRunAt = agent.dreamSchedule.nextRun(after: .now)
        }
        persistDreamSettings()
    }

    func recordDreamCompletion(agentID: Agent.ID, through: Date?, error: String?) {
        guard let agent = agent(for: agentID) else { return }
        if let through { agent.lastDreamCompletedAt = through }
        agent.lastDreamError = error
        persistDreamSettings()
    }

    private func persistDreamSettings() {
        try? modelContext.save()
        objectWillChange.send()
    }
}

nonisolated struct DreamTranscriptMessage: Sendable {
    var chatTitle: String
    var role: ChatRole
    var authorName: String?
    var text: String
    var createdAt: Date
}

nonisolated struct DreamTranscriptChunk: Sendable {
    var text: String
    var nextCursor: Int?
    var messageCount: Int
}

/// A bounded, cursor-based reader over a stable snapshot of full chat messages.
/// Each Light Sleep model call receives one chunk and is discarded before the next
/// chunk is processed, so tool output from earlier chunks cannot fill later contexts.
nonisolated struct DreamMessageReader: Sendable {
    let messages: [DreamTranscriptMessage]
    let maximumCharacters: Int

    func read(cursor: Int = 0) -> DreamTranscriptChunk {
        guard cursor < messages.count else {
            return DreamTranscriptChunk(text: "(No more messages.)", nextCursor: nil, messageCount: 0)
        }
        let formatter = ISO8601DateFormatter()
        var lines: [String] = []
        var used = 0
        var index = cursor
        while index < messages.count {
            let message = messages[index]
            let speaker = message.role == .user ? "User" : (message.authorName ?? "Agent")
            let line = "[\(formatter.string(from: message.createdAt))] [\(message.chatTitle)] \(speaker): \(message.text)"
            if !lines.isEmpty, used + line.count + 2 > maximumCharacters { break }
            lines.append(line)
            used += line.count + 2
            index += 1
        }
        return DreamTranscriptChunk(
            text: lines.joined(separator: "\n\n"),
            nextCursor: index < messages.count ? index : nil,
            messageCount: lines.count
        )
    }
}

@Generable
nonisolated struct ReadDreamMessagesArguments: Codable, Sendable {
    @Guide(description: "Zero-based cursor supplied by the dream prompt or returned as nextCursor. Omit for the first chunk.")
    var cursor: Int?
}

struct ReadDreamMessagesTool: Tool {
    let reader: DreamMessageReader

    let name = "ReadDreamMessages"
    let description = "Read one bounded, chronological chunk of full-text messages from the current dream window. Continue with nextCursor until it is absent."

    func call(arguments: ReadDreamMessagesArguments) async throws -> String {
        try Self.output(reader.read(cursor: max(0, arguments.cursor ?? 0)))
    }

    func executeJSON(_ json: String) async throws -> String {
        let arguments = try JSONDecoder().decode(ReadDreamMessagesArguments.self, from: Data(json.utf8))
        return try await call(arguments: arguments)
    }

    var schema: OpenAITool {
        .function(
            name: name,
            description: description,
            properties: [
                "cursor": OpenAIJSONProperty(
                    type: "integer",
                    description: "Zero-based cursor supplied by the dream prompt or returned as nextCursor. Omit for the first chunk."
                )
            ],
            required: []
        )
    }

    private static func output(_ chunk: DreamTranscriptChunk) throws -> String {
        let object: [String: Any] = [
            "messages": chunk.text,
            "messageCount": chunk.messageCount,
            "nextCursor": chunk.nextCursor.map { $0 as Any } ?? NSNull()
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

struct DreamMessageToolEntry: Sendable {
    let tool: ReadDreamMessagesTool
    var schema: OpenAITool { tool.schema }
    func execute(_ json: String) async throws -> String { try await tool.executeJSON(json) }
}

struct RunningDream: Identifiable {
    var id: Agent.ID { agentID }
    let agentID: Agent.ID
    let agentName: String
    let startedAt: Date
    var stage: String
}

@MainActor
final class DreamScheduler: ObservableObject {
    @Published private(set) var runningDream: RunningDream?
    @Published private(set) var queuedAgentIDs: [Agent.ID] = []

    private let agentStore: AgentStore
    private let localModelStore: LocalModelStore
    private let chatStore: ChatStore
    private weak var heartbeatScheduler: HeartbeatScheduler?
    private var schedulerTask: Task<Void, Never>?
    private var executionTask: Task<Void, Never>?

    init(
        agentStore: AgentStore,
        localModelStore: LocalModelStore,
        chatStore: ChatStore,
        heartbeatScheduler: HeartbeatScheduler
    ) {
        self.agentStore = agentStore
        self.localModelStore = localModelStore
        self.chatStore = chatStore
        self.heartbeatScheduler = heartbeatScheduler
    }

    func start() {
        guard schedulerTask == nil else { return }
        agentStore.prepareDreamSchedule(at: .now)
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.checkSchedule(at: .now)
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
    }

    func dreamNow(agentID: Agent.ID) {
        enqueue([agentID])
    }

    private func checkSchedule(at date: Date) {
        guard executionTask == nil, heartbeatScheduler?.runningHeartbeats.isEmpty != false else { return }
        enqueue(agentStore.claimAgentsDueToDream(at: date))
    }

    private func enqueue(_ agentIDs: [Agent.ID]) {
        for id in agentIDs where runningDream?.agentID != id && !queuedAgentIDs.contains(id) {
            queuedAgentIDs.append(id)
        }
        startNextIfPossible()
    }

    private func startNextIfPossible() {
        guard executionTask == nil,
              heartbeatScheduler?.runningHeartbeats.isEmpty != false,
              let agentID = queuedAgentIDs.first else { return }
        queuedAgentIDs.removeFirst()
        executionTask = Task { [weak self] in
            guard let self else { return }
            await run(agentID: agentID)
            executionTask = nil
            runningDream = nil
            startNextIfPossible()
        }
    }

    private func run(agentID: Agent.ID) async {
        guard let agent = agentStore.agent(for: agentID) else { return }
        let startedAt = Date()
        runningDream = RunningDream(
            agentID: agent.id,
            agentName: agent.displayName,
            startedAt: startedAt,
            stage: "Light Sleep"
        )

        let since = agent.lastDreamCompletedAt ?? startedAt.addingTimeInterval(-86_400)
        let messages = chatStore.dreamMessages(for: agent.id, since: since, through: startedAt)
        let lightModel = resolvedModel(
            agentOverride: agent.dreamLightModelIdentifierOverride,
            appChoice: agentStore.dreamSettings.lightModelIdentifier,
            agentDefault: agent.selectedModelIdentifier
        )
        let lightBackend = localModelStore.backend(for: lightModel)
        let contextCharacters = max(
            2_000,
            min(48_000, ConversationCompaction.contextWindow(for: lightBackend) * 3 / 2)
        )
        let reader = DreamMessageReader(messages: messages, maximumCharacters: contextCharacters)
        var cursor = 0
        var candidates: [String] = []

        do {
            repeat {
                let chunk = reader.read(cursor: cursor)
                guard chunk.messageCount > 0 else { break }
                let result = try await ModelClient.complete(
                    using: lightBackend,
                    systemPrompt: lightSystemPrompt(agent: agent),
                    prompt: """
                    \(resolvedLightPrompt(for: agent))

                    Call ReadDreamMessages once with cursor \(cursor), review every returned message, and return candidate memories only. Do not request another cursor in this model call; the dream scheduler will start a fresh context for it.
                    """,
                    tools: AgentToolBox.dream(reader: reader),
                    missingLocalModelMessage: "The Light Sleep model is no longer configured."
                )
                let trimmed = result.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, !ModelPrompts.isPassResponse(trimmed) { candidates.append(trimmed) }
                guard let next = chunk.nextCursor else { break }
                cursor = next
            } while true

            let lightDream = boundedStashValue(
                candidates.isEmpty ? "No candidate memories were found." : candidates.joined(separator: "\n\n")
            )
            _ = try AgentStashDatabase.upsert(
                key: "Light Dream",
                value: lightDream,
                agentID: agent.id,
                in: agentStore.modelContext,
                now: startedAt
            )

            runningDream?.stage = "REM Sleep"
            let remModel = resolvedModel(
                agentOverride: agent.dreamREMModelIdentifierOverride,
                appChoice: agentStore.dreamSettings.remModelIdentifier,
                agentDefault: agent.selectedModelIdentifier
            )
            let result = try await ModelClient.complete(
                using: localModelStore.backend(for: remModel),
                systemPrompt: remSystemPrompt(agent: agent),
                prompt: """
                \(resolvedREMPrompt(for: agent))

                --- BEGIN LIGHT DREAM STASH ---
                \(lightDream)
                --- END LIGHT DREAM STASH ---
                """,
                missingLocalModelMessage: "The REM Sleep model is no longer configured."
            )
            let parsed = AgentMemoryHarness.parse(result.finalText)
            agentStore.appendAgentMemoryEntries(id: agent.id, entries: parsed.memoryEntries)
            agentStore.recordDreamCompletion(agentID: agent.id, through: startedAt, error: nil)
        } catch {
            agentStore.recordDreamCompletion(agentID: agent.id, through: nil, error: error.localizedDescription)
        }
    }

    private func resolvedLightPrompt(for agent: Agent) -> String {
        normalizedDreamText(agent.dreamLightPromptOverride) ?? agentStore.dreamSettings.lightPrompt
    }

    private func resolvedREMPrompt(for agent: Agent) -> String {
        normalizedDreamText(agent.dreamREMPromptOverride) ?? agentStore.dreamSettings.remPrompt
    }

    private func resolvedModel(agentOverride: String?, appChoice: String?, agentDefault: String) -> String {
        if let agentOverride {
            return agentOverride == DreamModelChoice.agentDefault ? agentDefault : agentOverride
        }
        return appChoice ?? agentDefault
    }

    private func lightSystemPrompt(agent: Agent) -> String {
        """
        You are \(agent.displayName) reflecting privately during Light Sleep.
        \(agent.soul)

        Existing permanent Memory is reference material only. Do not emit memory control markers during Light Sleep.
        --- BEGIN MEMORY ---
        \(agent.memoryText.isEmpty ? "(No stored memory.)" : agent.memoryText)
        --- END MEMORY ---
        """
    }

    private func remSystemPrompt(agent: Agent) -> String {
        """
        You are \(agent.displayName) consolidating memory privately during REM Sleep.
        \(agent.soul)

        \(AgentMemoryHarness.instructionSection(memory: agent.memoryText))
        Your response is internal. Emit no conversational reply.
        """
    }

    private func boundedStashValue(_ value: String) -> String {
        var text = value
        while text.utf8.count > AgentStashDatabase.maximumValueBytes, !text.isEmpty {
            text.removeLast(max(1, text.count / 20))
        }
        return text
    }
}

private func normalizedDreamText(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
