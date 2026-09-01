import Combine
import Foundation
import SwiftData

enum HeartbeatTargetKind: String {
    case privateChat
    case groupChat
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

    var displayTitle: String {
        let normalizedTitle = title?
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ") ?? ""
        return normalizedTitle.isEmpty ? "Untitled heartbeat" : normalizedTitle
    }
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
        self.promptTokenCount = promptTokenCount
        self.completionTokenCount = completionTokenCount
    }

    var succeeded: Bool {
        errorMessage == nil
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
        let recorder = ToolCallRecorder()
        let debugCaptureEnabled = agentStore.agent(for: heartbeat.agentID)?.isDebugLogEnabled == true
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
