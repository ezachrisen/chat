import Foundation
import FoundationModels
import os
import SwiftData

struct ConversationCompactionStatus {
    var summary: String
    var compactedAt: Date?
    var coveredMessageCount: Int?
    var estimatedTokens: Int

    var hasDigest: Bool {
        !summary.isEmpty
    }
}

@Generable
struct ConversationDigest {
    @Guide(description: "Standing facts, names, preferences, and constraints that should survive later folds.")
    var standingFacts: String

    @Guide(description: "Decisions already made.")
    var decisions: String

    @Guide(description: "Unfinished tasks or open questions.")
    var openThreads: String

    @Guide(description: "Time span covered, such as from 3 days ago through 2 hours ago.")
    var timeSpan: String

    @Guide(description: "A dense narrative of what happened. No chit-chat.")
    var narrative: String
}

@MainActor
enum ConversationCompaction {
    static let localModelDefaultContextTokens = 8_192
    static let minimumContextTokens = 1_024
    static let maximumContextTokens = 1_000_000

    private static let logger = Logger(subsystem: "Chat", category: "Compaction")
    private static let appleFillRatio = 0.88
    private static let localFillRatio = 0.75
    private static let replyReserveRatio = 0.15
    private static let toolReplyReserveRatio = 0.25
    private static let minimumReplyReserve = 256
    private static let minimumConversationBudget = 400
    private static let aggressiveTailRatio = 0.12
    private static let summarizerOutputReserve = 900
    private static var foldingChatIDs: Set<UUID> = []

    struct Prepared {
        var digestText: String
        var tail: [StoredChatMessage]
    }

    static func contextWindow(for backend: ChatBackend) -> Int {
        switch backend {
        case .appleFoundation:
            let size = SystemLanguageModel.default.contextSize
            return size > 0 ? size : 4_096
        case .openAICompatible(let configuration):
            return configuration.contextTokenLimit
        case .missingLocalModel:
            return localModelDefaultContextTokens
        }
    }

    static func prepare(
        chat: StoredChat,
        messages: [StoredChatMessage],
        backend: ChatBackend,
        systemPrompt: String,
        toolsEnabled: Bool,
        isGroupChat: Bool,
        fallbackAgentName: String,
        relativeTo: Date? = nil,
        aggressive: Bool = false,
        in modelContext: ModelContext
    ) async -> Prepared {
        let budget = conversationBudget(
            backend: backend,
            systemPrompt: systemPrompt,
            toolsEnabled: toolsEnabled
        )
        let effectiveBudget = aggressive
            ? aggressiveBudget(budget, window: contextWindow(for: backend))
            : budget
        var prepared = split(
            chat: chat,
            messages: messages,
            isGroupChat: isGroupChat,
            fallbackAgentName: fallbackAgentName,
            relativeTo: relativeTo,
            budget: effectiveBudget
        )

        var previousOverflow = Int.max
        while !prepared.overflow.isEmpty, prepared.overflow.count < previousOverflow {
            previousOverflow = prepared.overflow.count
            await fold(
                chat: chat,
                overflow: prepared.overflow,
                isGroupChat: isGroupChat,
                fallbackAgentName: fallbackAgentName,
                relativeTo: relativeTo,
                in: modelContext
            )
            prepared = split(
                chat: chat,
                messages: messages,
                isGroupChat: isGroupChat,
                fallbackAgentName: fallbackAgentName,
                relativeTo: relativeTo,
                budget: effectiveBudget
            )
        }

        if !prepared.overflow.isEmpty {
            logger.info(
                "Prompt-only truncation chat=\(chat.id.uuidString, privacy: .public) dropped=\(prepared.overflow.count) kept=\(prepared.tail.count)"
            )
        }

        return Prepared(digestText: prepared.digestText, tail: prepared.tail)
    }

    private struct Split {
        var digestText: String
        var overflow: [StoredChatMessage]
        var tail: [StoredChatMessage]
    }

    private static func split(
        chat: StoredChat,
        messages: [StoredChatMessage],
        isGroupChat: Bool,
        fallbackAgentName: String,
        relativeTo: Date?,
        budget: Int
    ) -> Split {
        let digestText = resolvedDigest(for: chat, messages: messages)
        let after = messagesAfterWatermark(chat: chat, messages: messages)
        guard !after.isEmpty else {
            return Split(digestText: digestText, overflow: [], tail: [])
        }

        let digestCost = estimateTokens(digestSection(digestText))
        var used = digestCost
        var tail: [StoredChatMessage] = []
        var overflow = after

        while let last = overflow.last {
            let lineCost = estimateTokens(
                transcriptLine(
                    last,
                    isGroupChat: isGroupChat,
                    fallbackAgentName: fallbackAgentName,
                    relativeTo: relativeTo
                )
            ) + 2
            if !tail.isEmpty, used + lineCost > budget {
                break
            }
            overflow.removeLast()
            tail.insert(last, at: 0)
            used += lineCost
        }

        if tail.isEmpty, let last = overflow.popLast() {
            tail = [last]
        }

        return Split(digestText: digestText, overflow: overflow, tail: tail)
    }

    private static func fold(
        chat: StoredChat,
        overflow: [StoredChatMessage],
        isGroupChat: Bool,
        fallbackAgentName: String,
        relativeTo: Date?,
        in modelContext: ModelContext
    ) async {
        let chatID = chat.id
        while foldingChatIDs.contains(chatID) {
            await Task.yield()
        }
        foldingChatIDs.insert(chatID)
        defer { foldingChatIDs.remove(chatID) }
        await performFold(
            chat: chat,
            overflow: overflow,
            isGroupChat: isGroupChat,
            fallbackAgentName: fallbackAgentName,
            relativeTo: relativeTo,
            in: modelContext
        )
    }

    private static func performFold(
        chat: StoredChat,
        overflow: [StoredChatMessage],
        isGroupChat: Bool,
        fallbackAgentName: String,
        relativeTo: Date?,
        in modelContext: ModelContext
    ) async {
        guard !overflow.isEmpty else { return }
        guard isSummarizerAvailable else {
            logger.info("Summarizer unavailable; leaving digest unchanged")
            return
        }

        let existing = (chat.compactedSummary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let chunks = chunk(
            overflow,
            isGroupChat: isGroupChat,
            fallbackAgentName: fallbackAgentName,
            relativeTo: relativeTo
        )

        do {
            var chunkSummaries: [String] = []
            for (index, chunkMessages) in chunks.enumerated() {
                let text = transcript(
                    chunkMessages,
                    isGroupChat: isGroupChat,
                    fallbackAgentName: fallbackAgentName,
                    relativeTo: relativeTo
                )
                let summary = try await summarizeChunk(
                    text,
                    span: "\(index + 1) of \(chunks.count)"
                )
                chunkSummaries.append(summary)
            }

            let merged = try await mergeDigest(
                existing: existing,
                newMaterial: chunkSummaries.joined(separator: "\n\n")
            )
            chat.compactedSummary = merged
            chat.compactedThroughMessageID = overflow.last?.id
            chat.compactedAt = .now
            let priorCount = existing.isEmpty ? 0 : (chat.compactedMessageCount ?? 0)
            chat.compactedMessageCount = priorCount + overflow.count
            if modelContext.hasChanges {
                try modelContext.save()
            }
            logger.info(
                "Folded chat=\(chat.id.uuidString, privacy: .public) overflow=\(overflow.count) chunks=\(chunks.count) digest_chars=\(merged.count)"
            )
        } catch {
            logger.error("Fold failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static var isSummarizerAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability {
            return true
        }
        return false
    }

    private static func summarizeChunk(_ transcript: String, span: String) async throws -> String {
        let session = LanguageModelSession(
            instructions: summarizerInstructions
        )
        let prompt = """
        Summarize this span of a chat (\(span)). It will be merged with other spans.
        Preserve names, decisions, constraints, and unfinished work. Drop chit-chat.

        \(transcript)
        """
        let digest = try await session.respond(to: prompt, generating: ConversationDigest.self).content
        return format(digest)
    }

    private static func mergeDigest(existing: String, newMaterial: String) async throws -> String {
        let session = LanguageModelSession(
            instructions: summarizerInstructions
        )
        let prompt: String
        if existing.isEmpty {
            prompt = """
            Produce one bounded running summary of this chat material.
            Preserve names, decisions, constraints, and unfinished work.

            \(newMaterial)
            """
        } else {
            prompt = """
            Merge the existing running summary with new material into one bounded summary covering the whole span.
            Preserve standing facts; do not drop names, decisions, or open threads. Drop chit-chat.

            Existing summary:
            \(existing)

            New material:
            \(newMaterial)
            """
        }
        let digest = try await session.respond(to: prompt, generating: ConversationDigest.self).content
        return format(digest)
    }

    private static let summarizerInstructions = """
    You compress chat history for a later model call.
    Preserve names, decisions, constraints, and unfinished work.
    Drop jokes, filler, and repeated details.
    Be dense. Do not invent facts. Leave a section empty if there is nothing to record.
    """

    private static func format(_ digest: ConversationDigest) -> String {
        func section(_ title: String, _ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return "\(title):\n\(trimmed)"
        }

        return [
            section("Time span", digest.timeSpan),
            section("Standing facts", digest.standingFacts),
            section("Decisions", digest.decisions),
            section("Open threads", digest.openThreads),
            section("What happened", digest.narrative)
        ]
        .compactMap { $0 }
        .joined(separator: "\n\n")
    }

    private static func chunk(
        _ messages: [StoredChatMessage],
        isGroupChat: Bool,
        fallbackAgentName: String,
        relativeTo: Date?
    ) -> [[StoredChatMessage]] {
        let budget = summarizerChunkBudget()
        var chunks: [[StoredChatMessage]] = []
        var current: [StoredChatMessage] = []
        var used = 0

        for message in messages {
            let cost = estimateTokens(
                transcriptLine(
                    message,
                    isGroupChat: isGroupChat,
                    fallbackAgentName: fallbackAgentName,
                    relativeTo: relativeTo
                )
            ) + 2
            if !current.isEmpty, used + cost > budget {
                chunks.append(current)
                current = []
                used = 0
            }
            current.append(message)
            used += cost
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks.isEmpty ? [messages] : chunks
    }

    private static func summarizerChunkBudget() -> Int {
        let window = SystemLanguageModel.default.contextSize
        let resolved = window > 0 ? window : 4_096
        return max(800, resolved - summarizerOutputReserve - 500)
    }

    private static func conversationBudget(
        backend: ChatBackend,
        systemPrompt: String,
        toolsEnabled: Bool
    ) -> Int {
        let window = contextWindow(for: backend)
        let reserveRatio = toolsEnabled ? toolReplyReserveRatio : replyReserveRatio
        let replyReserve = max(minimumReplyReserve, Int(Double(window) * reserveRatio))
        let fillRatio = backend.isAppleFoundation ? appleFillRatio : localFillRatio
        let inputBudget = Int(Double(max(window - replyReserve, minimumConversationBudget)) * fillRatio)
        return max(minimumConversationBudget, inputBudget - estimateTokens(systemPrompt))
    }

    private static func aggressiveBudget(_ autoBudget: Int, window: Int) -> Int {
        min(autoBudget, max(minimumConversationBudget, Int(Double(window) * aggressiveTailRatio)))
    }

    private static func resolvedDigest(for chat: StoredChat, messages: [StoredChatMessage]) -> String {
        let text = (chat.compactedSummary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        guard let watermark = chat.compactedThroughMessageID,
              messages.contains(where: { $0.id == watermark }) else {
            return ""
        }
        return text
    }

    private static func messagesAfterWatermark(
        chat: StoredChat,
        messages: [StoredChatMessage]
    ) -> [StoredChatMessage] {
        guard let watermark = chat.compactedThroughMessageID,
              let index = messages.firstIndex(where: { $0.id == watermark }),
              resolvedDigest(for: chat, messages: messages).isEmpty == false else {
            return messages
        }
        let next = messages.index(after: index)
        guard next < messages.endIndex else { return [] }
        return Array(messages[next...])
    }

    private static func transcript(
        _ messages: [StoredChatMessage],
        isGroupChat: Bool,
        fallbackAgentName: String,
        relativeTo: Date?
    ) -> String {
        messages.map {
            transcriptLine(
                $0,
                isGroupChat: isGroupChat,
                fallbackAgentName: fallbackAgentName,
                relativeTo: relativeTo
            )
        }
        .joined(separator: "\n\n")
    }

    private static func transcriptLine(
        _ message: StoredChatMessage,
        isGroupChat: Bool,
        fallbackAgentName: String,
        relativeTo: Date?
    ) -> String {
        let speaker = message.role == .user
            ? "User"
            : message.authorName ?? (isGroupChat ? "Agent" : fallbackAgentName)
        if let relativeTo {
            let age = ModelPrompts.compactElapsedTime(from: message.createdAt, to: relativeTo)
            return "[\(age) ago] \(speaker): \(message.text)"
        }
        return "\(speaker): \(message.text)"
    }

    private static func digestSection(_ digest: String) -> String {
        let trimmed = digest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return """
        Earlier in this conversation (summarized):
        \(trimmed)

        Recent messages:
        """
    }

    static func estimateTokens(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return max(1, (trimmed.count + 2) / 3)
    }

    static func tokenCount(for text: String) async -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        do {
            return try await SystemLanguageModel.default.tokenCount(for: trimmed)
        } catch {
            return estimateTokens(trimmed)
        }
    }
}

private extension ChatBackend {
    var isAppleFoundation: Bool {
        if case .appleFoundation = self { return true }
        return false
    }
}
