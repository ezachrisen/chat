import Foundation
import SwiftData

enum ChatKind: String {
    case direct
    case group
}

@Model
final class StoredGroupChatParticipant: Identifiable {
    @Attribute(.unique) var id: UUID
    var chatID: UUID
    @Attribute(originalName: "personaID") var agentID: UUID
    @Attribute(originalName: "personaName") var agentName: String
    @Attribute(originalName: "personaSoul") var agentSoul: String
    @Attribute(originalName: "personaModelIdentifier") var agentModelIdentifier: String?
    var agentMentionHandle: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        chatID: UUID,
        agentID: UUID,
        agentName: String,
        agentSoul: String,
        agentModelIdentifier: String?,
        agentMentionHandle: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.chatID = chatID
        self.agentID = agentID
        self.agentName = agentName
        self.agentSoul = agentSoul
        self.agentModelIdentifier = agentModelIdentifier
        self.agentMentionHandle = agentMentionHandle
        self.createdAt = createdAt
    }

    convenience init(chatID: UUID, agent: Agent) {
        self.init(
            chatID: chatID,
            agentID: agent.id,
            agentName: agent.displayName,
            agentSoul: agent.soul,
            agentModelIdentifier: agent.selectedModelIdentifier,
            agentMentionHandle: agent.resolvedMentionHandle
        )
    }

    var resolvedMentionHandle: String {
        AgentMention.normalizedHandle(agentMentionHandle) ?? AgentMention.handle(for: agentName)
    }

    var mention: String {
        AgentMention.mention(forHandle: resolvedMentionHandle)
    }

    func isMentioned(in handles: Set<String>) -> Bool {
        handles.contains(AgentMention.lookupKey(for: resolvedMentionHandle))
    }
}

enum AgentMention {
    static func mention(for agentName: String) -> String {
        "@\(handle(for: agentName))"
    }

    static func mention(forHandle handle: String) -> String {
        "@\(normalizedHandle(handle) ?? "agent")"
    }

    static func handle(for agentName: String) -> String {
        normalizedHandle(agentName) ?? "agent"
    }

    static func normalizedHandle(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutAt = trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
        let handle = withoutAt
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
        return handle.isEmpty ? nil : handle
    }

    static func lookupKey(for handle: String) -> String {
        handle.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .lowercased()
    }

    static func lookupHandle(from mention: String) -> String? {
        guard let handle = normalizedHandle(mention) else { return nil }
        return lookupKey(for: handle)
    }

    static func handles(in text: String) -> Set<String> {
        guard let expression = try? NSRegularExpression(pattern: "@[\\p{L}\\p{N}_-]+") else {
            return []
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return Set(expression.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            return lookupHandle(from: String(text[matchRange]))
        })
    }
}

extension Agent {
    var resolvedMentionHandle: String {
        AgentMention.normalizedHandle(mentionHandle) ?? AgentMention.handle(for: displayName)
    }

    var mention: String {
        AgentMention.mention(forHandle: resolvedMentionHandle)
    }

    var routingLabel: String {
        let routing = routingDescriptionText
        return routing.isEmpty ? displayName : routing
    }
}
