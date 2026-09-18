import Foundation
import CryptoKit

nonisolated enum AppleServiceID: String, Codable, CaseIterable, Identifiable, Sendable {
    case reminders, notes, contacts, phone, messages, mail
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var toolName: String { "Apple" + title }
    /// Where the user connects this service.
    var settingsLocation: String { "Settings → Tools → \(title)" }
    var bundleID: String? {
        switch self {
        case .notes: "com.apple.Notes"
        case .mail: "com.apple.mail"
        case .messages: "com.apple.MobileSMS"
        case .phone: "com.apple.mobilephone"
        default: nil
        }
    }
    var actions: [String] {
        switch self {
        case .reminders: ["lists", "search", "read", "create", "update", "complete", "reopen", "delete"]
        case .contacts: ["containers", "search", "read", "resolve", "create", "update"]
        case .notes: ["folders", "search", "read", "create", "append", "update", "show"]
        case .mail: ["attachments", "accounts", "mailboxes", "search", "read", "draft", "reply", "update_draft", "prepare_send", "send", "set_read", "set_flagged", "move", "show"]
        case .messages: ["attachments", "accounts", "chats", "search", "read", "prepare", "send"]
        case .phone: ["prepare", "call"]
        }
    }
    var scopeLabel: String {
        switch self {
        case .reminders: "Reminder lists"
        case .notes: "Note folders"
        case .contacts: "Contact accounts"
        case .mail: "Mailboxes"
        case .messages: "Conversations"
        case .phone: "Phone numbers"
        }
    }
}

nonisolated struct AppleServiceGrant: Codable, Equatable, Sendable {
    var enabled = false
    var allowsAll = false
    var resourceIDs: Set<String> = []
    var allowsChanges = false
    var allowsDeletion = false
    var allowsBackground = false
    var allowsDelegation = false
    var allowsHistory = false
    var sendDestinations: Set<String> = []
    var sendingIdentities: Set<String> = []
    func permits(_ id: String) -> Bool { allowsAll || resourceIDs.contains(id) }
}

nonisolated enum AppleServiceOrigin: String, Codable, Sendable { case interactive, heartbeat, delegated, consultation, backgroundDelegated, backgroundConsultation
    var isBackground: Bool { [.heartbeat, .backgroundDelegated, .backgroundConsultation].contains(self) }
    var isDelegated: Bool { [.delegated, .consultation, .backgroundDelegated, .backgroundConsultation].contains(self) }
    var isConsultation: Bool { [.consultation, .backgroundConsultation].contains(self) }
}

nonisolated struct AppleServiceRequest: Codable, Sendable, Equatable {
    var action: String
    var id: String?
    var container: String?
    var listName: String?
    var dueFrom: String?
    var dueThrough: String?
    var query: String?
    var title: String?
    var body: String?
    var value: String?
    var due: String?
    var priority: Int?
    var email: String?
    var phone: String?
    var familyName: String?
    var recurrence: String?
    var alarm: String?
    var attachmentID: String?
    var recipient: String?
    var sender: String?
    var revision: String?
    var actionID: String?
    var limit: Int?
    var offset: Int?

    func required(_ value: String?, _ name: String) throws -> String {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppleServiceError.invalid("\(name) is required.")
        }
        guard value.utf8.count <= 32_000 else { throw AppleServiceError.invalid("\(name) is too large.") }
        return value
    }
    var pageSize: Int { min(max(limit ?? 25, 1), 100) }
    var pageOffset: Int { min(max(offset ?? 0, 0), 10_000) }
    var isRead: Bool { ["attachments", "lists", "containers", "folders", "accounts", "mailboxes", "chats", "search", "read", "resolve"].contains(action) }
    var isPreparedExecution: Bool { ["send", "call"].contains(action) }
    var isPreparation: Bool { ["prepare", "prepare_send"].contains(action) }
}

/// Controls what the generic generation trace stores for a native service
/// call. The service response itself is already bounded before this point.
nonisolated enum AppleServiceDiagnosticTrace {
    static let redactedArgumentsJSON = #"{"content":"redacted"}"#

    static func argumentsJSON(
        for request: AppleServiceRequest,
        capturesFullContent: Bool
    ) -> String {
        guard capturesFullContent else { return redactedArgumentsJSON }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(request) else {
            return #"{"content":"could not encode request"}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func resultText(
        output: String,
        result: AppleServiceResult,
        capturesFullContent: Bool
    ) -> String {
        capturesFullContent
            ? output
            : "\(result.status); \(result.records.count) records; service content omitted"
    }
}

nonisolated struct AppleServiceRecord: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var title: String
    var container: String
    var fields: [String: String] = [:]
    var isReminderSummary = false
    private enum CodingKeys: String, CodingKey { case id, title, container, fields }
    private enum SummaryKeys: String, CodingKey { case id, title, due }

    func encode(to encoder: Encoder) throws {
        if isReminderSummary {
            var values = encoder.container(keyedBy: SummaryKeys.self)
            try values.encode(id, forKey: .id)
            try values.encode(title, forKey: .title)
            try values.encode(fields["due"], forKey: .due)
        } else {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(id, forKey: .id)
            try values.encode(title, forKey: .title)
            try values.encode(container, forKey: .container)
            try values.encode(fields, forKey: .fields)
        }
    }
    var revision: String { Self.digest([id, title, container] + fields.sorted { $0.key < $1.key }.flatMap { [$0.key, $0.value] }) }
    static func digest(_ parts: [String]) -> String {
        let data = (try? JSONEncoder().encode(parts)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated struct AppleServiceResult: Codable, Sendable {
    var status: String = "ok"
    var records: [AppleServiceRecord] = []
    var observedAt = Date()
    var nextOffset: Int?
    var coverage = "local; results may change between pages"
    var message: String?
    var actionID: String?
    var contentTruncated: Bool?
    var revisions: [String: String] { Dictionary(records.filter { !$0.isReminderSummary }.map { ($0.id, $0.revision) }, uniquingKeysWith: { _, last in last }) }
    func json(maximumBytes: Int = 48_000) throws -> String {
        let budget = min(maximumBytes, 48_000)
        guard budget >= 512 else { throw AppleServiceError.invalid("Insufficient result budget.") }
        struct Envelope: Encodable { let result: AppleServiceResult; let revisions: [String: String] }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var bounded = self
        for i in bounded.records.indices {
            bounded.records[i].title = String(bounded.records[i].title.prefix(300))
            let truncatedFields = bounded.records[i].fields.filter { $0.value.count > 12_000 }.keys.sorted()
            bounded.records[i].fields = bounded.records[i].fields.mapValues { String($0.prefix(12_000)) }
            if !truncatedFields.isEmpty {
                bounded.records[i].fields["truncated_fields"] = truncatedFields.joined(separator: ",")
                bounded.contentTruncated = true
            }
        }
        var data = try encoder.encode(Envelope(result: bounded, revisions: revisions))
        while data.count > budget, bounded.records.count > 1 {
            bounded.records.removeLast()
            bounded.contentTruncated = true
            bounded.message = "Output budget reached. Narrow the query."
            bounded.nextOffset = nil
            data = try encoder.encode(Envelope(result: bounded, revisions: revisions.filter { id, _ in bounded.records.contains { $0.id == id } }))
        }
        if data.count > budget, !bounded.records.isEmpty {
            let cap = max(1, budget / (bounded.records[0].fields.count + 4) / 10)
            bounded.records[0].title = String(bounded.records[0].title.prefix(cap))
            bounded.records[0].fields = bounded.records[0].fields.mapValues { String($0.prefix(cap)) }
            bounded.contentTruncated = true
            bounded.message = "Content shortened to the invocation budget."
            data = try encoder.encode(Envelope(result: bounded, revisions: revisions.filter { id, _ in bounded.records.contains { $0.id == id } }))
        }
        guard data.count <= budget else { throw AppleServiceError.invalid("Result exceeds output budget. Narrow the query.") }
        return String(decoding: data, as: UTF8.self)
    }
    static func page(_ records: [AppleServiceRecord], request: AppleServiceRequest, coverage: String = "local") -> Self {
        let start = min(request.pageOffset, records.count)
        let end = min(start + request.pageSize, records.count)
        return Self(records: Array(records[start..<end]), nextOffset: end < records.count ? end : nil, coverage: coverage)
    }
}

nonisolated enum AppleServiceError: LocalizedError, Sendable {
    case invalid(String), needsSetup(String), forbidden, conflict, unsupported(String), unavailable(String), uncertain
    var errorDescription: String? {
        switch self {
        case .invalid(let message): "invalid_request: \(message)"
        case .needsSetup(let message): "needs_setup: \(message)"
        case .forbidden: "not_found_or_forbidden: This resource or operation is not allowed."
        case .conflict: "conflict: The item changed. Read it again before editing."
        case .unsupported(let message): "unsupported_capability: \(message)"
        case .unavailable(let message): "unavailable: \(message)"
        case .uncertain: "uncertain: The action may have happened. Do not repeat it automatically."
        }
    }
}

nonisolated enum AppleServiceValidation {
    static func phone(_ raw: String) throws -> String {
        let number = raw.filter { !" ()-.".contains($0) }
        guard number.first == "+", (8...16).contains(number.count), number.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw AppleServiceError.invalid("Use an exact international phone number starting with + and country code.")
        }
        return number
    }
    static func endpoint(_ raw: String) throws -> String {
        if raw.contains("@") {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.split(separator: "@").count == 2, !text.contains(where: { $0.isWhitespace || $0.isNewline }),
                  !text.contains(where: { "<>,;\"".contains($0) }) else { throw AppleServiceError.invalid("Use one exact email address.") }
            return text
        }
        return try phone(raw)
    }
    static func mailAddress(_ raw: String) throws -> String {
        let candidate: String
        if raw.contains("<") || raw.contains(">") {
            guard let start = raw.firstIndex(of: "<"), let end = raw.firstIndex(of: ">"), start < end,
                  raw.filter({ $0 == "<" }).count == 1, raw.filter({ $0 == ">" }).count == 1,
                  raw[raw.index(after: end)...].trimmingCharacters(in: .whitespaces).isEmpty else { throw AppleServiceError.invalid("Ambiguous sending address.") }
            candidate = String(raw[raw.index(after: start)..<end])
        } else { candidate = raw }
        let address = try endpoint(candidate)
        guard address.contains("@") else { throw AppleServiceError.invalid("Expected an email address.") }
        return address
    }
    static func checkRevision(_ supplied: String?, record: AppleServiceRecord) throws {
        guard let supplied else { throw AppleServiceError.invalid("Read the item and pass its revision before changing it.") }
        guard supplied == record.revision else { throw AppleServiceError.conflict }
    }
}
