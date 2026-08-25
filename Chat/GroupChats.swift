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
    var createdAt: Date

    init(
        id: UUID = UUID(),
        chatID: UUID,
        agentID: UUID,
        agentName: String,
        agentSoul: String,
        agentModelIdentifier: String?,
        createdAt: Date = .now
    ) {
        self.id = id
        self.chatID = chatID
        self.agentID = agentID
        self.agentName = agentName
        self.agentSoul = agentSoul
        self.agentModelIdentifier = agentModelIdentifier
        self.createdAt = createdAt
    }

    convenience init(chatID: UUID, agent: Agent) {
        self.init(
            chatID: chatID,
            agentID: agent.id,
            agentName: agent.displayName,
            agentSoul: agent.soul,
            agentModelIdentifier: agent.selectedModelIdentifier
        )
    }

    var mention: String {
        AgentMention.mention(for: agentName)
    }
}

enum AgentMention {
    static func mention(for agentName: String) -> String {
        "@\(handle(for: agentName))"
    }

    static func handle(for agentName: String) -> String {
        let handle = agentName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
        return handle.isEmpty ? "agent" : handle
    }

    static func handles(in text: String) -> Set<String> {
        guard let expression = try? NSRegularExpression(pattern: "@[\\p{L}\\p{N}_]+") else {
            return []
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return Set(expression.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            return text[matchRange].dropFirst().lowercased()
        })
    }
}

extension Agent {
    var mention: String {
        AgentMention.mention(for: displayName)
    }
}
