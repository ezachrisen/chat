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
    var personaID: UUID
    var personaName: String
    var personaSoul: String
    var personaModelIdentifier: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        chatID: UUID,
        personaID: UUID,
        personaName: String,
        personaSoul: String,
        personaModelIdentifier: String?,
        createdAt: Date = .now
    ) {
        self.id = id
        self.chatID = chatID
        self.personaID = personaID
        self.personaName = personaName
        self.personaSoul = personaSoul
        self.personaModelIdentifier = personaModelIdentifier
        self.createdAt = createdAt
    }

    convenience init(chatID: UUID, persona: Persona) {
        self.init(
            chatID: chatID,
            personaID: persona.id,
            personaName: persona.displayName,
            personaSoul: persona.soul,
            personaModelIdentifier: persona.selectedModelIdentifier
        )
    }

    var mention: String {
        PersonaMention.mention(for: personaName)
    }
}

enum PersonaMention {
    static func mention(for personaName: String) -> String {
        "@\(handle(for: personaName))"
    }

    static func handle(for personaName: String) -> String {
        let handle = personaName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
        return handle.isEmpty ? "persona" : handle
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

extension Persona {
    var mention: String {
        PersonaMention.mention(for: displayName)
    }
}
