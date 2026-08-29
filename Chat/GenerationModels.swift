import Foundation
import SwiftData

enum GenerationKind: String {
    case direct
    case group
    case heartbeat
}

enum GenerationStatus: String {
    case posted
    case passed
    case emptyVisible
    case failed
    case aborted
    case timedOut
}

@Model
final class GenerationTurn: Identifiable {
    #Index<GenerationTurn>(
        [\.chatID, \.startedAt],
        [\.agentID, \.startedAt],
        [\.userMessageID],
        [\.assistantMessageID]
    )

    @Attribute(.unique) var id: UUID
    var kindRawValue: String
    var chatID: UUID
    var userMessageID: UUID?
    var assistantMessageID: UUID?
    var agentID: UUID
    var agentName: String
    var heartbeatID: UUID?
    var heartbeatRunID: UUID?
    var modelIdentifier: String
    var backendRawValue: String
    var startedAt: Date
    var completedAt: Date
    var statusRawValue: String
    var actionSummary: String
    var errorMessage: String?
    var visibleReplyPreview: String?
    var toolCallCount: Int
    var memoryEntryCount: Int
    var debugCaptureEnabled: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        kind: GenerationKind,
        chatID: UUID,
        userMessageID: UUID? = nil,
        assistantMessageID: UUID? = nil,
        agentID: UUID,
        agentName: String,
        heartbeatID: UUID? = nil,
        heartbeatRunID: UUID? = nil,
        modelIdentifier: String,
        backendRawValue: String,
        startedAt: Date,
        completedAt: Date,
        status: GenerationStatus,
        actionSummary: String,
        errorMessage: String? = nil,
        visibleReplyPreview: String? = nil,
        toolCallCount: Int = 0,
        memoryEntryCount: Int = 0,
        debugCaptureEnabled: Bool = false,
        createdAt: Date = .now
    ) {
        self.id = id
        kindRawValue = kind.rawValue
        self.chatID = chatID
        self.userMessageID = userMessageID
        self.assistantMessageID = assistantMessageID
        self.agentID = agentID
        self.agentName = agentName
        self.heartbeatID = heartbeatID
        self.heartbeatRunID = heartbeatRunID
        self.modelIdentifier = modelIdentifier
        self.backendRawValue = backendRawValue
        self.startedAt = startedAt
        self.completedAt = completedAt
        statusRawValue = status.rawValue
        self.actionSummary = actionSummary
        self.errorMessage = errorMessage
        self.visibleReplyPreview = visibleReplyPreview
        self.toolCallCount = toolCallCount
        self.memoryEntryCount = memoryEntryCount
        self.debugCaptureEnabled = debugCaptureEnabled
        self.createdAt = createdAt
    }

    var kind: GenerationKind {
        GenerationKind(rawValue: kindRawValue) ?? .direct
    }

    var status: GenerationStatus {
        GenerationStatus(rawValue: statusRawValue) ?? .failed
    }
}

@Model
final class ToolInvocation: Identifiable {
    #Index<ToolInvocation>([\.turnID, \.sequence])

    @Attribute(.unique) var id: UUID
    var turnID: UUID
    var sequence: Int
    var roundIndex: Int
    var toolName: String
    var skillName: String?
    var argumentsJSON: String
    var resultText: String
    var resultTruncated: Bool
    var succeeded: Bool
    var errorMessage: String?
    var startedAt: Date
    var completedAt: Date

    init(
        id: UUID = UUID(),
        turnID: UUID,
        sequence: Int,
        roundIndex: Int,
        toolName: String,
        skillName: String? = nil,
        argumentsJSON: String,
        resultText: String,
        resultTruncated: Bool,
        succeeded: Bool,
        errorMessage: String? = nil,
        startedAt: Date,
        completedAt: Date
    ) {
        self.id = id
        self.turnID = turnID
        self.sequence = sequence
        self.roundIndex = roundIndex
        self.toolName = toolName
        self.skillName = skillName
        self.argumentsJSON = argumentsJSON
        self.resultText = resultText
        self.resultTruncated = resultTruncated
        self.succeeded = succeeded
        self.errorMessage = errorMessage
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

@Model
final class GenerationDebugPayload: Identifiable {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var turnID: UUID
    var systemPrompt: String
    var conversationPrompt: String
    var rawModelOutput: String
    var reasoningText: String?
    var intermediateAssistantJSON: String?
    var appleTranscriptSummary: String?
    var openAIMessagesJSON: String?
    var capturedAt: Date

    init(
        id: UUID = UUID(),
        turnID: UUID,
        systemPrompt: String,
        conversationPrompt: String,
        rawModelOutput: String,
        reasoningText: String? = nil,
        intermediateAssistantJSON: String? = nil,
        appleTranscriptSummary: String? = nil,
        openAIMessagesJSON: String? = nil,
        capturedAt: Date = .now
    ) {
        self.id = id
        self.turnID = turnID
        self.systemPrompt = systemPrompt
        self.conversationPrompt = conversationPrompt
        self.rawModelOutput = rawModelOutput
        self.reasoningText = reasoningText
        self.intermediateAssistantJSON = intermediateAssistantJSON
        self.appleTranscriptSummary = appleTranscriptSummary
        self.openAIMessagesJSON = openAIMessagesJSON
        self.capturedAt = capturedAt
    }
}

struct GenerationTurnDraft: Sendable {
    var id: UUID = UUID()
    var kind: GenerationKind
    var chatID: UUID
    var userMessageID: UUID?
    var assistantMessageID: UUID?
    var agentID: UUID
    var agentName: String
    var heartbeatID: UUID?
    var heartbeatRunID: UUID?
    var modelIdentifier: String
    var backendRawValue: String
    var startedAt: Date
    var completedAt: Date
    var status: GenerationStatus
    var actionSummary: String
    var errorMessage: String?
    var visibleReplyPreview: String?
    var memoryEntryCount: Int
    var debugCaptureEnabled: Bool
}

struct GenerationDebugPayloadDraft: Sendable {
    var systemPrompt: String
    var conversationPrompt: String
    var rawModelOutput: String
    var reasoningText: String?
    var intermediateAssistantJSON: String?
    var appleTranscriptSummary: String?
    var openAIMessagesJSON: String?

    init(
        systemPrompt: String,
        conversationPrompt: String,
        rawModelOutput: String,
        reasoningText: String? = nil,
        intermediateAssistantJSON: String? = nil,
        appleTranscriptSummary: String? = nil,
        openAIMessagesJSON: String? = nil
    ) {
        self.systemPrompt = systemPrompt
        self.conversationPrompt = conversationPrompt
        self.rawModelOutput = rawModelOutput
        self.reasoningText = reasoningText
        self.intermediateAssistantJSON = intermediateAssistantJSON
        self.appleTranscriptSummary = appleTranscriptSummary
        self.openAIMessagesJSON = openAIMessagesJSON
    }

    init(systemPrompt: String, conversationPrompt: String, result: ModelGenerationResult) {
        self.systemPrompt = systemPrompt
        self.conversationPrompt = conversationPrompt
        rawModelOutput = result.finalText
        reasoningText = result.reasoningTexts.isEmpty
            ? nil
            : result.reasoningTexts.joined(separator: "\n\n")
        intermediateAssistantJSON = result.intermediateAssistantTexts.isEmpty
            ? nil
            : GenerationJSON.encode(result.intermediateAssistantTexts)
        appleTranscriptSummary = result.debug?.appleTranscriptSummary
        openAIMessagesJSON = result.debug?.openAIMessagesJSON
    }
}
