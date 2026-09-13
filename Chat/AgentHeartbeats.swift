import Combine
import Foundation
import SwiftData

enum HeartbeatTargetKind: String {
    case privateChat
    case groupChat
}

enum HeartbeatScheduleKind: String, CaseIterable, Hashable {
    case interval
    case specificTime

    var label: String {
        switch self {
        case .interval:
            return "At an interval"
        case .specificTime:
            return "At a specific time"
        }
    }
}

enum HeartbeatWeekday: Int, CaseIterable, Identifiable {
    case sunday = 1
    case monday
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday

    var id: Int { rawValue }

    var shortLabel: String {
        switch self {
        case .sunday: return "S"
        case .monday: return "M"
        case .tuesday: return "T"
        case .wednesday: return "W"
        case .thursday: return "T"
        case .friday: return "F"
        case .saturday: return "S"
        }
    }

    var summaryLabel: String {
        String(accessibilityLabel.prefix(3))
    }

    var accessibilityLabel: String {
        switch self {
        case .sunday: return "Sunday"
        case .monday: return "Monday"
        case .tuesday: return "Tuesday"
        case .wednesday: return "Wednesday"
        case .thursday: return "Thursday"
        case .friday: return "Friday"
        case .saturday: return "Saturday"
        }
    }

    var bit: Int { 1 << (rawValue - 1) }

    static let allMask = allCases.reduce(0) { $0 | $1.bit }
    static let weekdaysMask = [monday, tuesday, wednesday, thursday, friday]
        .reduce(0) { $0 | $1.bit }
    static let weekendMask = [sunday, saturday].reduce(0) { $0 | $1.bit }
}

enum HeartbeatExecutionError: LocalizedError {
    case agentMissing
    case emptyInstruction
    case targetMissing

    var errorDescription: String? {
        switch self {
        case .agentMissing:
            return "The agent no longer exists."
        case .emptyInstruction:
            return "Add an instruction before enabling this heartbeat."
        case .targetMissing:
            return "The selected destination no longer exists."
        }
    }
}

@Model
final class AgentHeartbeat: Identifiable {
    @Attribute(.unique) var id: UUID
    @Attribute(originalName: "personaID") var agentID: UUID
    var title: String?
    var instruction: String
    var intervalMinutes: Int
    /// Optional schedule fields preserve compatibility with stores created
    /// before weekday and time-of-day scheduling was introduced.
    var scheduleKindRawValue: String?
    var weekdayMask: Int?
    var scheduledTimeMinutes: Int?
    var isEnabled: Bool
    var targetKindRawValue: String
    var targetChatID: UUID?
    var modelIdentifier: String?
    var lastRunAt: Date?
    var lastCompletedAt: Date?
    var nextRunAt: Date?
    /// The error from the most recently completed run. Pair with `lastCompletedAt`
    /// to distinguish a successful run from a heartbeat that has never run.
    var lastError: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        agentID: UUID,
        title: String? = nil,
        instruction: String = "Check whether you have anything useful to add.",
        intervalMinutes: Int = 60,
        scheduleKind: HeartbeatScheduleKind = .interval,
        weekdayMask: Int? = nil,
        scheduledTimeMinutes: Int? = nil,
        isEnabled: Bool = false,
        targetKind: HeartbeatTargetKind = .privateChat,
        targetChatID: UUID? = nil,
        modelIdentifier: String? = nil,
        lastRunAt: Date? = nil,
        lastCompletedAt: Date? = nil,
        nextRunAt: Date? = nil,
        lastError: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.agentID = agentID
        self.title = title
        self.instruction = instruction
        self.intervalMinutes = intervalMinutes
        scheduleKindRawValue = scheduleKind.rawValue
        self.weekdayMask = weekdayMask
        self.scheduledTimeMinutes = scheduledTimeMinutes
        self.isEnabled = isEnabled
        targetKindRawValue = targetKind.rawValue
        self.targetChatID = targetChatID
        self.modelIdentifier = modelIdentifier
        self.lastRunAt = lastRunAt
        self.lastCompletedAt = lastCompletedAt
        self.nextRunAt = nextRunAt
        self.lastError = lastError
        self.createdAt = createdAt
    }

    var targetKind: HeartbeatTargetKind {
        HeartbeatTargetKind(rawValue: targetKindRawValue) ?? .privateChat
    }

    var normalizedIntervalMinutes: Int {
        min(max(intervalMinutes, 1), 10_080)
    }

    var scheduleKind: HeartbeatScheduleKind {
        HeartbeatScheduleKind(rawValue: scheduleKindRawValue ?? "") ?? .interval
    }

    var normalizedWeekdayMask: Int {
        let storedMask = weekdayMask ?? HeartbeatWeekday.allMask
        let validMask = storedMask & HeartbeatWeekday.allMask
        return validMask == 0 ? HeartbeatWeekday.allMask : validMask
    }

    var normalizedScheduledTimeMinutes: Int {
        min(max(scheduledTimeMinutes ?? (17 * 60), 0), (24 * 60) - 1)
    }

    func runs(on weekday: HeartbeatWeekday) -> Bool {
        normalizedWeekdayMask & weekday.bit != 0
    }

    func nextScheduledRun(after date: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        switch scheduleKind {
        case .interval:
            let candidate = date.addingTimeInterval(TimeInterval(normalizedIntervalMinutes * 60))
            return nextAllowedIntervalDate(onOrAfter: candidate, calendar: calendar)
        case .specificTime:
            return nextSpecificTimeDate(after: date, calendar: calendar)
        }
    }

    var scheduleDescription: String {
        let base: String
        switch scheduleKind {
        case .interval:
            base = heartbeatIntervalDescription(normalizedIntervalMinutes)
        case .specificTime:
            let calendar = Calendar.autoupdatingCurrent
            let startOfDay = calendar.startOfDay(for: .now)
            let date = calendar.date(
                byAdding: .minute,
                value: normalizedScheduledTimeMinutes,
                to: startOfDay
            ) ?? startOfDay
            base = date.formatted(date: .omitted, time: .shortened)
        }

        let days = weekdayDescription
        return days == "Every day" ? base : "\(base) · \(days)"
    }

    var weekdayDescription: String {
        switch normalizedWeekdayMask {
        case HeartbeatWeekday.allMask:
            return "Every day"
        case HeartbeatWeekday.weekdaysMask:
            return "Weekdays"
        case HeartbeatWeekday.weekendMask:
            return "Weekends"
        default:
            return HeartbeatWeekday.allCases
                .filter(runs(on:))
                .map(\.summaryLabel)
                .joined(separator: ", ")
        }
    }

    private func nextAllowedIntervalDate(onOrAfter candidate: Date, calendar: Calendar) -> Date {
        guard normalizedWeekdayMask != HeartbeatWeekday.allMask else {
            return candidate
        }

        var eligibleDate = candidate
        for _ in 0..<7 {
            if let weekday = HeartbeatWeekday(rawValue: calendar.component(.weekday, from: eligibleDate)),
               runs(on: weekday) {
                return eligibleDate
            }
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: eligibleDate) else {
                break
            }
            eligibleDate = nextDay
        }
        return candidate
    }

    private func nextSpecificTimeDate(after date: Date, calendar: Calendar) -> Date {
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
                repeatedTimePolicy: .first,
                direction: .forward
            ) else {
                break
            }
            if let weekday = HeartbeatWeekday(rawValue: calendar.component(.weekday, from: candidate)),
               runs(on: weekday) {
                return candidate
            }
            cursor = candidate.addingTimeInterval(1)
        }

        return date.addingTimeInterval(24 * 60 * 60)
    }

    var displayTitle: String {
        let normalizedTitle = title?
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ") ?? ""
        return normalizedTitle.isEmpty ? "Untitled heartbeat" : normalizedTitle
    }
}

private func heartbeatIntervalDescription(_ minutes: Int) -> String {
    let minutes = min(max(minutes, 1), 10_080)
    if minutes == 10_080 {
        return "Every week"
    }
    if minutes.isMultiple(of: 1_440) {
        let days = minutes / 1_440
        return days == 1 ? "Every day" : "Every \(days) days"
    }
    if minutes.isMultiple(of: 60) {
        let hours = minutes / 60
        return hours == 1 ? "Every hour" : "Every \(hours) hours"
    }
    return minutes == 1 ? "Every minute" : "Every \(minutes) min"
}

@Model
final class HeartbeatRun: Identifiable {
    @Attribute(.unique) var id: UUID
    var heartbeatID: UUID
    @Attribute(originalName: "personaID") var agentID: UUID
    @Attribute(originalName: "personaName") var agentName: String
    var instruction: String
    var destination: String
    var startedAt: Date
    var completedAt: Date
    var modelInput: String
    var modelOutput: String?
    var actionSummary: String
    var errorMessage: String?
    var generationTurnID: UUID?
    /// Snapshotted when the run starts so failures that happen before a
    /// generation turn exists can still describe their debug-capture state.
    var debugCaptureEnabled: Bool?
    var promptTokenCount: Int?
    var completionTokenCount: Int?

    init(
        id: UUID = UUID(),
        heartbeatID: UUID,
        agentID: UUID,
        agentName: String,
        instruction: String,
        destination: String,
        startedAt: Date,
        completedAt: Date,
        modelInput: String,
        modelOutput: String?,
        actionSummary: String,
        errorMessage: String?,
        generationTurnID: UUID? = nil,
        debugCaptureEnabled: Bool? = nil,
        promptTokenCount: Int? = nil,
        completionTokenCount: Int? = nil
    ) {
        self.id = id
        self.heartbeatID = heartbeatID
        self.agentID = agentID
        self.agentName = agentName
        self.instruction = instruction
        self.destination = destination
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.modelInput = modelInput
        self.modelOutput = modelOutput
        self.actionSummary = actionSummary
        self.errorMessage = errorMessage
        self.generationTurnID = generationTurnID
        self.debugCaptureEnabled = debugCaptureEnabled
        self.promptTokenCount = promptTokenCount
        self.completionTokenCount = completionTokenCount
    }

    var succeeded: Bool {
        errorMessage == nil
    }

    var passedWithoutDebugLog: Bool {
        generationTurnID == nil
            && errorMessage == nil
            && actionSummary.hasPrefix("The model passed, so no chat message was posted.")
    }

    var duration: TimeInterval {
        max(0, completedAt.timeIntervalSince(startedAt))
    }

    var formattedDuration: String {
        Self.formatDuration(duration)
    }

    var totalTokenCount: Int? {
        guard promptTokenCount != nil || completionTokenCount != nil else { return nil }
        return (promptTokenCount ?? 0) + (completionTokenCount ?? 0)
    }

    var formattedTokenUsage: String? {
        guard let totalTokenCount else { return nil }
        return "\(totalTokenCount.formatted()) tok"
    }

    var tokenUsageHelp: String? {
        guard let promptTokenCount, let completionTokenCount else { return formattedTokenUsage }
        return "\(promptTokenCount.formatted()) prompt · \(completionTokenCount.formatted()) completion"
    }

    static func formatDuration(_ interval: TimeInterval) -> String {
        let total = max(0, interval)
        if total < 10 {
            return String(format: "%.1fs", total)
        }
        if total < 60 {
            return String(format: "%.0fs", total)
        }
        let minutes = Int(total) / 60
        let seconds = Int(total.rounded(.towardZero)) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    static func metricsLine(duration: String, tokens: String?) -> String {
        guard let tokens else { return duration }
        return "\(duration) · \(tokens)"
    }
}

struct HeartbeatExecutionReport {
    let agentName: String
    let instruction: String
    let destination: String
    let startedAt: Date
    let completedAt: Date
    let modelInput: String
    let modelOutput: String?
    let actionSummary: String
    let errorMessage: String?
    let retryDelay: TimeInterval?
    let runID: UUID
    let turnID: UUID
    let chatID: UUID?
    let debugCaptureEnabled: Bool
    let generationStatus: GenerationStatus
    let assistantMessageID: UUID?
    let visibleReplyPreview: String?
    let memoryEntryCount: Int
    let modelIdentifier: String
    let backendRawValue: String
    let toolInvocations: [CapturedToolInvocation]
    let debug: GenerationDebugPayloadDraft?
    var promptTokenCount: Int? = nil
    var completionTokenCount: Int? = nil
}

struct RunningHeartbeat: Identifiable {
    let id: AgentHeartbeat.ID
    let agentID: Agent.ID
    let agentName: String
    let instruction: String
    let destination: String
    let startedAt: Date
    var chatID: UUID?
    var debugCaptureEnabled: Bool
}

struct HeartbeatModelExchange {
    let modelInput: String
    let modelOutput: String
    let actionSummary: String
    let runID: UUID
    let turnID: UUID
    let chatID: UUID
    let debugCaptureEnabled: Bool
    let generationStatus: GenerationStatus
    let assistantMessageID: UUID?
    let visibleReplyPreview: String?
    let memoryEntryCount: Int
    let backendRawValue: String
    let toolInvocations: [CapturedToolInvocation]
    let debug: GenerationDebugPayloadDraft?
    var tokenUsage: TokenUsage = .zero
}

struct HeartbeatModelFailure: LocalizedError {
    let modelInput: String
    let modelOutput: String?
    let message: String
    let wasAborted: Bool
    var runID: UUID
    var turnID: UUID
    var chatID: UUID?
    var debugCaptureEnabled: Bool
    var toolInvocations: [CapturedToolInvocation]
    var debug: GenerationDebugPayloadDraft?
    var backendRawValue: String
    var tokenUsage: TokenUsage = .zero

    var errorDescription: String? {
        message
    }
}

enum HeartbeatSlotOutcome {
    case running
    case timedOut
}

struct HeartbeatExecutionSlot {
    var token: UUID
    var task: Task<Void, Never>
    var runID: UUID
    var turnID: UUID
    var recorder: ToolCallRecorder
    var chatID: UUID?
    var debugCaptureEnabled: Bool
    var debugSystemPrompt: String?
    var debugConversationPrompt: String?
    var outcome: HeartbeatSlotOutcome
}

@MainActor
final class HeartbeatScheduler: ObservableObject {
    private static let executionTimeout: Duration = .seconds(300)

    @Published private(set) var runningHeartbeats: [RunningHeartbeat] = []

    private let agentStore: AgentStore
    private let chatStore: ChatStore
    private var schedulerTask: Task<Void, Never>?
    private var executionTasks: [AgentHeartbeat.ID: HeartbeatExecutionSlot] = [:]
    private var timeoutTasks: [AgentHeartbeat.ID: (token: UUID, task: Task<Void, Never>)] = [:]

    init(agentStore: AgentStore, chatStore: ChatStore) {
        self.agentStore = agentStore
        self.chatStore = chatStore
    }

    func start() {
        guard schedulerTask == nil else { return }

        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                runDueHeartbeats()

                do {
                    try await Task.sleep(for: .seconds(15))
                } catch {
                    return
                }
            }
        }
    }

    func skip(_ heartbeatID: AgentHeartbeat.ID) {
        guard executionTasks[heartbeatID] == nil else { return }
        agentStore.skipHeartbeat(id: heartbeatID, at: .now)
    }

    func disable(_ heartbeatID: AgentHeartbeat.ID) {
        guard executionTasks[heartbeatID] == nil,
              let heartbeat = agentStore.heartbeats.first(where: { $0.id == heartbeatID }) else {
            return
        }
        agentStore.updateHeartbeatEnabled(heartbeat, isEnabled: false)
    }

    func runNow(_ heartbeatID: AgentHeartbeat.ID) {
        guard executionTasks[heartbeatID] == nil else { return }

        let requestDate = Date()
        guard executionTasks.isEmpty else {
            agentStore.deferHeartbeatForOverlap(id: heartbeatID, at: requestDate)
            return
        }

        guard
              let heartbeat = agentStore.claimHeartbeatForImmediateRun(
                id: heartbeatID,
                at: requestDate
              ) else {
            return
        }
        startExecution(heartbeat)
    }

    func abort(_ heartbeatID: AgentHeartbeat.ID) {
        executionTasks[heartbeatID]?.task.cancel()
    }

    private func runDueHeartbeats() {
        let checkDate = Date()
        guard executionTasks.isEmpty else {
            agentStore.deferDueHeartbeatsForOverlap(at: checkDate)
            return
        }

        guard let heartbeat = agentStore.claimNextDueHeartbeat(at: checkDate) else { return }
        startExecution(heartbeat)
    }

    private func startExecution(_ heartbeat: AgentHeartbeat) {
        guard executionTasks[heartbeat.id] == nil else { return }
        guard executionTasks.isEmpty else {
            agentStore.deferHeartbeatForOverlap(id: heartbeat.id, at: .now)
            return
        }

        let executionToken = UUID()
        let runID = UUID()
        let turnID = UUID()
        let debugCaptureEnabled = agentStore.agent(for: heartbeat.agentID)?.isDebugLogEnabled == true
        let recorder = ToolCallRecorder(capturesFullContent: debugCaptureEnabled)
        let runningHeartbeat = RunningHeartbeat(
            id: heartbeat.id,
            agentID: heartbeat.agentID,
            agentName: agentStore.agent(for: heartbeat.agentID)?.displayName ?? "Deleted agent",
            instruction: heartbeat.instruction.trimmingCharacters(in: .whitespacesAndNewlines),
            destination: chatStore.heartbeatDestinationDescription(for: heartbeat),
            startedAt: .now,
            chatID: nil,
            debugCaptureEnabled: debugCaptureEnabled
        )
        runningHeartbeats.append(runningHeartbeat)

        let task = Task { [weak self] in
            guard let self else { return }
            let report = await chatStore.executeHeartbeat(
                heartbeat,
                runID: runID,
                turnID: turnID,
                recorder: recorder,
                debugCaptureEnabled: debugCaptureEnabled,
                onDestinationChat: { chatID in
                    guard var slot = self.executionTasks[heartbeat.id],
                          slot.token == executionToken else { return }
                    slot.chatID = chatID
                    self.executionTasks[heartbeat.id] = slot
                    if let index = self.runningHeartbeats.firstIndex(where: { $0.id == heartbeat.id }) {
                        self.runningHeartbeats[index].chatID = chatID
                    }
                },
                onDebugPrompt: { systemPrompt, conversationPrompt in
                    guard var slot = self.executionTasks[heartbeat.id],
                          slot.token == executionToken else { return }
                    slot.debugSystemPrompt = systemPrompt
                    slot.debugConversationPrompt = conversationPrompt
                    self.executionTasks[heartbeat.id] = slot
                },
                onModelResponseAccepted: {
                    guard self.executionTasks[heartbeat.id]?.token == executionToken else { return }
                    self.timeoutTasks[heartbeat.id]?.task.cancel()
                    self.timeoutTasks[heartbeat.id] = nil
                }
            )
            guard executionTasks[heartbeat.id]?.token == executionToken,
                  executionTasks[heartbeat.id]?.outcome == .running else {
                agentStore.refreshTimedOutHeartbeatTrace(report: report)
                return
            }

            timeoutTasks[heartbeat.id]?.task.cancel()
            timeoutTasks[heartbeat.id] = nil
            agentStore.recordHeartbeatCompletion(
                heartbeatID: heartbeat.id,
                agentID: heartbeat.agentID,
                report: report
            )
            executionTasks[heartbeat.id] = nil
            runningHeartbeats.removeAll { $0.id == heartbeat.id }
        }
        executionTasks[heartbeat.id] = HeartbeatExecutionSlot(
            token: executionToken,
            task: task,
            runID: runID,
            turnID: turnID,
            recorder: recorder,
            chatID: nil,
            debugCaptureEnabled: debugCaptureEnabled,
            debugSystemPrompt: nil,
            debugConversationPrompt: nil,
            outcome: .running
        )

        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: HeartbeatScheduler.executionTimeout)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }

            guard let self else { return }
            timeOut(heartbeat.id, executionToken: executionToken)
        }
        timeoutTasks[heartbeat.id] = (executionToken, timeoutTask)
    }

    private func timeOut(
        _ heartbeatID: AgentHeartbeat.ID,
        executionToken: UUID
    ) {
        guard var slot = executionTasks[heartbeatID],
              slot.token == executionToken,
              slot.outcome == .running,
              let runningHeartbeat = runningHeartbeats.first(where: { $0.id == heartbeatID }) else {
            return
        }

        slot.outcome = .timedOut
        executionTasks[heartbeatID] = slot
        slot.task.cancel()
        let invocations = slot.recorder.snapshot()
        executionTasks[heartbeatID] = nil
        timeoutTasks[heartbeatID] = nil
        runningHeartbeats.removeAll { $0.id == heartbeatID }

        let completionDate = Date()
        let modelIdentifier = agentStore.heartbeats.first(where: { $0.id == heartbeatID }).map {
            $0.modelIdentifier ?? agentStore.agent(for: $0.agentID)?.selectedModelIdentifier ?? ""
        } ?? ""
        let backendRawValue = chatStore.backendPersistenceName(for: modelIdentifier)
        let debug: GenerationDebugPayloadDraft?
        if slot.debugCaptureEnabled {
            debug = GenerationDebugPayloadDraft(
                systemPrompt: slot.debugSystemPrompt ?? "",
                conversationPrompt: slot.debugConversationPrompt ?? "",
                rawModelOutput: ""
            )
        } else {
            debug = nil
        }

        agentStore.rescheduleHeartbeatAfterTimeout(id: heartbeatID, at: completionDate)
        agentStore.recordHeartbeatCompletion(
            heartbeatID: heartbeatID,
            agentID: runningHeartbeat.agentID,
            report: HeartbeatExecutionReport(
                agentName: runningHeartbeat.agentName,
                instruction: runningHeartbeat.instruction,
                destination: runningHeartbeat.destination,
                startedAt: runningHeartbeat.startedAt,
                completedAt: completionDate,
                modelInput: "",
                modelOutput: nil,
                actionSummary: "Timed out after 5 minutes. No chat message was posted.",
                errorMessage: "Timed out after 5 minutes.",
                retryDelay: nil,
                runID: slot.runID,
                turnID: slot.turnID,
                chatID: slot.chatID,
                debugCaptureEnabled: slot.debugCaptureEnabled,
                generationStatus: .timedOut,
                assistantMessageID: nil,
                visibleReplyPreview: nil,
                memoryEntryCount: 0,
                modelIdentifier: modelIdentifier,
                backendRawValue: backendRawValue,
                toolInvocations: invocations,
                debug: debug,
                promptTokenCount: nil,
                completionTokenCount: nil
            )
        )
    }
}
