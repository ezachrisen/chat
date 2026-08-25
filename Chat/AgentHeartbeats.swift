import Combine
import Foundation
import SwiftData

enum HeartbeatTargetKind: String {
    case privateChat
    case groupChat
}

enum HeartbeatExecutionError: LocalizedError {
    static let busyDestinationRetryDelay: TimeInterval = 60

    case agentMissing
    case emptyInstruction
    case targetMissing
    case chatBusy

    var errorDescription: String? {
        switch self {
        case .agentMissing:
            return "The agent no longer exists."
        case .emptyInstruction:
            return "Add an instruction before enabling this heartbeat."
        case .targetMissing:
            return "The selected destination no longer exists."
        case .chatBusy:
            return "The destination chat is already generating a response."
        }
    }

    var retryDelay: TimeInterval? {
        switch self {
        case .chatBusy:
            return Self.busyDestinationRetryDelay
        case .agentMissing, .emptyInstruction, .targetMissing:
            return nil
        }
    }
}

@Model
final class AgentHeartbeat: Identifiable {
    @Attribute(.unique) var id: UUID
    @Attribute(originalName: "personaID") var agentID: UUID
    var instruction: String
    var intervalMinutes: Int
    var isEnabled: Bool
    var targetKindRawValue: String
    var targetChatID: UUID?
    var modelIdentifier: String?
    var lastRunAt: Date?
    var lastCompletedAt: Date?
    var nextRunAt: Date?
    var lastError: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        agentID: UUID,
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
        errorMessage: String?
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
    }

    var succeeded: Bool {
        errorMessage == nil
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
}

struct RunningHeartbeat: Identifiable {
    let id: AgentHeartbeat.ID
    let agentID: Agent.ID
    let agentName: String
    let instruction: String
    let destination: String
    let startedAt: Date
}

struct HeartbeatModelExchange {
    let modelInput: String
    let modelOutput: String
    let actionSummary: String
}

struct HeartbeatModelFailure: LocalizedError {
    let modelInput: String
    let modelOutput: String?
    let message: String
    let wasAborted: Bool

    var errorDescription: String? {
        message
    }
}

struct AgentModelOutput {
    let visibleText: String
    let memoryEntries: [String]
}

enum AgentMemoryHarness {
    private static let memoryExpression = try! NSRegularExpression(
        pattern: #"\[\[MEMORY\]\](.*?)\[\[/MEMORY\]\]"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    static func instructionSection(memory: String) -> String {
        let trimmedMemory = memory.trimmingCharacters(in: .whitespacesAndNewlines)
        let memoryContent = trimmedMemory.isEmpty ? "(No stored memory.)" : trimmedMemory

        return """
        Persistent memory:
        --- BEGIN MEMORY ---
        \(memoryContent)
        --- END MEMORY ---

        Memory rules:
        - Treat the existing memory as read-only. Never rewrite, delete, or replace an existing entry.
        - You may append a new memory when something will be useful in future conversations.
        - To append memory, include each new entry inside [[MEMORY]] and [[/MEMORY]] markers.
        - Memory markers are control data and will not be shown as part of your reply.
        - Do not add transient details, repeated facts, or instructions to yourself as memory.
        """
    }

    static func parse(_ response: String) -> AgentModelOutput {
        let fullRange = NSRange(response.startIndex..<response.endIndex, in: response)
        let matches = memoryExpression.matches(in: response, range: fullRange)
        var entries: [String] = []

        for match in matches {
            guard match.numberOfRanges > 1,
                  let entryRange = Range(match.range(at: 1), in: response) else {
                continue
            }
            let entry = response[entryRange].trimmingCharacters(in: .whitespacesAndNewlines)
            if !entry.isEmpty {
                entries.append(entry)
            }
        }

        let visibleResponse = NSMutableString(string: response)
        for match in matches.reversed() {
            visibleResponse.replaceCharacters(in: match.range, with: "")
        }

        let visibleText = String(visibleResponse)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")

        return AgentModelOutput(visibleText: visibleText, memoryEntries: entries)
    }
}

@MainActor
final class HeartbeatScheduler: ObservableObject {
    private static let executionTimeout: Duration = .seconds(300)

    @Published private(set) var runningHeartbeats: [RunningHeartbeat] = []

    private let agentStore: AgentStore
    private let chatStore: ChatStore
    private var schedulerTask: Task<Void, Never>?
    private var executionTasks: [AgentHeartbeat.ID: (token: UUID, task: Task<Void, Never>)] = [:]
    private var timeoutTasks: [AgentHeartbeat.ID: (token: UUID, task: Task<Void, Never>)] = [:]
    private var runningModelInputs: [AgentHeartbeat.ID: String] = [:]

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
        let runningHeartbeat = RunningHeartbeat(
            id: heartbeat.id,
            agentID: heartbeat.agentID,
            agentName: agentStore.agent(for: heartbeat.agentID)?.displayName ?? "Deleted agent",
            instruction: heartbeat.instruction.trimmingCharacters(in: .whitespacesAndNewlines),
            destination: chatStore.heartbeatDestinationDescription(for: heartbeat),
            startedAt: .now
        )
        runningHeartbeats.append(runningHeartbeat)

        let task = Task { [weak self] in
            guard let self else { return }
            let report = await chatStore.executeHeartbeat(
                heartbeat,
                onModelInput: { modelInput in
                    guard self.executionTasks[heartbeat.id]?.token == executionToken else { return }
                    self.runningModelInputs[heartbeat.id] = modelInput
                },
                onModelResponseAccepted: {
                    guard self.executionTasks[heartbeat.id]?.token == executionToken else { return }
                    self.timeoutTasks[heartbeat.id]?.task.cancel()
                    self.timeoutTasks[heartbeat.id] = nil
                }
            )
            guard executionTasks[heartbeat.id]?.token == executionToken else { return }

            timeoutTasks[heartbeat.id]?.task.cancel()
            timeoutTasks[heartbeat.id] = nil
            agentStore.recordHeartbeatCompletion(
                heartbeatID: heartbeat.id,
                agentID: heartbeat.agentID,
                report: report
            )
            executionTasks[heartbeat.id] = nil
            runningModelInputs[heartbeat.id] = nil
            runningHeartbeats.removeAll { $0.id == heartbeat.id }
        }
        executionTasks[heartbeat.id] = (executionToken, task)

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
        guard let execution = executionTasks[heartbeatID],
              execution.token == executionToken,
              let runningHeartbeat = runningHeartbeats.first(where: { $0.id == heartbeatID }) else {
            return
        }

        execution.task.cancel()
        executionTasks[heartbeatID] = nil
        timeoutTasks[heartbeatID] = nil
        runningHeartbeats.removeAll { $0.id == heartbeatID }

        let completionDate = Date()
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
                modelInput: runningModelInputs[heartbeatID] ?? "",
                modelOutput: nil,
                actionSummary: "Timed out after 5 minutes. No chat message was posted.",
                errorMessage: "Timed out after 5 minutes.",
                retryDelay: nil
            )
        )
        runningModelInputs[heartbeatID] = nil
    }
}
