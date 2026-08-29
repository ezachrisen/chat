import Foundation
import os
import SwiftData

enum GenerationJSON {
    static func encode(_ value: some Encodable) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }
}

enum GenerationStore {
    private static let logger = Logger(subsystem: "Chat", category: "Generation")
    private static let compactArgumentsLimit = 4_096
    private static let compactResultLimit = 8_192
    private static let debugFieldLimit = 1_000_000
    static let visiblePreviewLimit = 280

    @discardableResult
    static func recordTurn(
        draft: GenerationTurnDraft,
        invocations: [CapturedToolInvocation],
        debug: GenerationDebugPayloadDraft?,
        in modelContext: ModelContext
    ) -> GenerationTurn {
        let debugOn = draft.debugCaptureEnabled
        let turn = GenerationTurn(
            id: draft.id,
            kind: draft.kind,
            chatID: draft.chatID,
            userMessageID: draft.userMessageID,
            assistantMessageID: draft.assistantMessageID,
            agentID: draft.agentID,
            agentName: draft.agentName,
            heartbeatID: draft.heartbeatID,
            heartbeatRunID: draft.heartbeatRunID,
            modelIdentifier: draft.modelIdentifier,
            backendRawValue: draft.backendRawValue,
            startedAt: draft.startedAt,
            completedAt: draft.completedAt,
            status: draft.status,
            actionSummary: draft.actionSummary,
            errorMessage: draft.errorMessage,
            visibleReplyPreview: draft.visibleReplyPreview,
            toolCallCount: invocations.count,
            memoryEntryCount: draft.memoryEntryCount,
            debugCaptureEnabled: debugOn
        )
        modelContext.insert(turn)

        for invocation in invocations {
            let arguments: TruncatedText
            let result: TruncatedText
            if debugOn {
                arguments = limit(invocation.argumentsJSON, max: debugFieldLimit, addEllipsis: true)
                result = limit(invocation.resultText, max: debugFieldLimit, addEllipsis: true)
            } else {
                arguments = limit(invocation.argumentsJSON, max: compactArgumentsLimit, addEllipsis: false)
                result = limit(invocation.resultText, max: compactResultLimit, addEllipsis: false)
            }

            let row = ToolInvocation(
                turnID: turn.id,
                sequence: invocation.sequence,
                roundIndex: invocation.roundIndex,
                toolName: invocation.toolName,
                skillName: invocation.skillName,
                argumentsJSON: arguments.value,
                resultText: result.value,
                resultTruncated: arguments.truncated || result.truncated,
                succeeded: invocation.succeeded,
                errorMessage: invocation.errorMessage,
                startedAt: invocation.startedAt,
                completedAt: invocation.completedAt
            )
            modelContext.insert(row)
        }

        if debugOn, let debug {
            let payload = GenerationDebugPayload(
                turnID: turn.id,
                systemPrompt: limit(debug.systemPrompt, max: debugFieldLimit, addEllipsis: true).value,
                conversationPrompt: limit(debug.conversationPrompt, max: debugFieldLimit, addEllipsis: true).value,
                rawModelOutput: limit(debug.rawModelOutput, max: debugFieldLimit, addEllipsis: true).value,
                reasoningText: debug.reasoningText.map {
                    limit($0, max: debugFieldLimit, addEllipsis: true).value
                },
                intermediateAssistantJSON: debug.intermediateAssistantJSON.map {
                    limit($0, max: debugFieldLimit, addEllipsis: true).value
                },
                appleTranscriptSummary: debug.appleTranscriptSummary.map {
                    limit($0, max: debugFieldLimit, addEllipsis: true).value
                },
                openAIMessagesJSON: debug.openAIMessagesJSON.map {
                    limit($0, max: debugFieldLimit, addEllipsis: true).value
                }
            )
            modelContext.insert(payload)
        }

        let durationMS = max(0, Int(draft.completedAt.timeIntervalSince(draft.startedAt) * 1_000))
        logger.info(
            "Persisted turn kind=\(draft.kind.rawValue, privacy: .public) status=\(draft.status.rawValue, privacy: .public) tools=\(invocations.count) debug=\(debugOn) duration_ms=\(durationMS)"
        )
        return turn
    }

    static func visibleReplyPreview(from text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(visiblePreviewLimit))
    }

    private struct TruncatedText {
        var value: String
        var truncated: Bool
    }

    private static func limit(_ text: String, max: Int, addEllipsis: Bool) -> TruncatedText {
        guard text.count > max else {
            return TruncatedText(value: text, truncated: false)
        }
        let prefix = String(text.prefix(max))
        return TruncatedText(
            value: addEllipsis ? prefix + "\n…(truncated)" : prefix,
            truncated: true
        )
    }
}

enum GenerationQuery {
    static func turnsInChat(_ chatID: UUID, newestFirst: Bool = true) -> FetchDescriptor<GenerationTurn> {
        FetchDescriptor<GenerationTurn>(
            predicate: #Predicate { $0.chatID == chatID },
            sortBy: [SortDescriptor(\.startedAt, order: newestFirst ? .reverse : .forward)]
        )
    }

    static func turnsInChat(_ chatID: UUID, from: Date, to: Date) -> FetchDescriptor<GenerationTurn> {
        FetchDescriptor<GenerationTurn>(
            predicate: #Predicate { turn in
                turn.chatID == chatID && turn.startedAt >= from && turn.startedAt < to
            },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
    }

    static func turnsForAgent(_ agentID: UUID, from: Date, to: Date) -> FetchDescriptor<GenerationTurn> {
        FetchDescriptor<GenerationTurn>(
            predicate: #Predicate { turn in
                turn.agentID == agentID && turn.startedAt >= from && turn.startedAt < to
            },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
    }

    static func turn(forAssistantMessage messageID: UUID) -> FetchDescriptor<GenerationTurn> {
        let optionalID: UUID? = messageID
        var descriptor = FetchDescriptor<GenerationTurn>(
            predicate: #Predicate { $0.assistantMessageID == optionalID }
        )
        descriptor.fetchLimit = 1
        return descriptor
    }

    static func turns(forUserMessage messageID: UUID) -> FetchDescriptor<GenerationTurn> {
        let optionalID: UUID? = messageID
        return FetchDescriptor<GenerationTurn>(
            predicate: #Predicate { $0.userMessageID == optionalID },
            sortBy: [SortDescriptor(\.startedAt)]
        )
    }

    static func toolCalls(forTurn turnID: UUID) -> FetchDescriptor<ToolInvocation> {
        FetchDescriptor<ToolInvocation>(
            predicate: #Predicate { $0.turnID == turnID },
            sortBy: [SortDescriptor(\.sequence)]
        )
    }

    static func debugPayload(forTurn turnID: UUID) -> FetchDescriptor<GenerationDebugPayload> {
        var descriptor = FetchDescriptor<GenerationDebugPayload>(
            predicate: #Predicate { $0.turnID == turnID }
        )
        descriptor.fetchLimit = 1
        return descriptor
    }

    static func heartbeatRunsForAgent(_ agentID: UUID) -> FetchDescriptor<HeartbeatRun> {
        FetchDescriptor<HeartbeatRun>(
            predicate: #Predicate { $0.agentID == agentID },
            sortBy: [SortDescriptor(\.completedAt, order: .reverse)]
        )
    }

    static func fetchTurn(id: UUID, in context: ModelContext) -> GenerationTurn? {
        var descriptor = FetchDescriptor<GenerationTurn>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    static func fetchTurn(forAssistantMessage messageID: UUID, in context: ModelContext) -> GenerationTurn? {
        try? context.fetch(turn(forAssistantMessage: messageID)).first
    }

    static func fetchToolCalls(forTurn turnID: UUID, in context: ModelContext) -> [ToolInvocation] {
        (try? context.fetch(toolCalls(forTurn: turnID))) ?? []
    }

    static func fetchDebugPayload(forTurn turnID: UUID, in context: ModelContext) -> GenerationDebugPayload? {
        try? context.fetch(debugPayload(forTurn: turnID)).first
    }
}
