import Foundation
import SQLite3

/// Compatibility reader. It never creates, migrates, or writes Apple's database.
nonisolated final class MessagesHistoryService: @unchecked Sendable {
    static let shared = MessagesHistoryService()
    private let queue = DispatchQueue(label: "Chat.AppleServices.messagesHistory", qos: .userInitiated)
    private let databaseURL: URL
    init(databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db")) { self.databaseURL = databaseURL }

    func execute(_ request: AppleServiceRequest, grant: AppleServiceGrant, fence: AppleServiceFence) async throws -> AppleServiceResult {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try self.read(request, grant: grant, fence: fence)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func read(_ r: AppleServiceRequest, grant: AppleServiceGrant, fence: AppleServiceFence) throws -> AppleServiceResult {
        guard grant.allowsHistory else { throw AppleServiceError.forbidden }
        let chatID = try r.required(r.id, "id (conversation GUID)")
        guard grant.permits(chatID) else { throw AppleServiceError.forbidden }
        var database: OpaquePointer?
        let opened = sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard opened == SQLITE_OK, let db = database else {
            if let database { sqlite3_close(database) }
            throw AppleServiceError.needsSetup("Messages history needs Full Disk Access for Chat. Enable it in System Settings and restart Chat.")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        let box = Unmanaged.passRetained(fence)
        defer { sqlite3_progress_handler(db, 0, nil, nil); box.release() }
        sqlite3_progress_handler(db, 1000, { pointer in
            guard let pointer else { return 1 }
            return (try? Unmanaged<AppleServiceFence>.fromOpaque(pointer).takeUnretainedValue().check()) == nil ? 1 : 0
        }, box.toOpaque())
        try fence.check()
        let columns = try query(db, sql: "PRAGMA table_info(message)", values: []).compactMap { $0["name"] }
        guard Set(["guid", "text", "date", "is_from_me", "handle_id"]).isSubset(of: Set(columns)) else {
            throw AppleServiceError.unsupported("This macOS Messages schema is not supported.")
        }
        let hasAttributedBody = columns.contains("attributedBody")
        let attributed = hasAttributedBody ? "CASE WHEN length(m.attributedBody) <= 1048576 THEN hex(m.attributedBody) ELSE '' END" : "''"
        let sql = """
        SELECT m.guid AS id, COALESCE(m.text, '') AS text, m.date AS date,
               m.is_from_me AS outgoing, COALESCE(h.id, '') AS sender,
               \(attributed) AS attributed_body
        FROM message m JOIN chat_message_join j ON j.message_id = m.ROWID
        JOIN chat c ON c.ROWID = j.chat_id LEFT JOIN handle h ON h.ROWID = m.handle_id
        WHERE c.guid = ?
        ORDER BY m.date DESC, m.ROWID DESC LIMIT ? OFFSET ?
        """
        let rows = try query(db, sql: sql, values: [chatID, String(r.pageSize + 1), String(r.pageOffset)])
        let records = rows.prefix(r.pageSize).map { row -> AppleServiceRecord in
            var fields = ["text": row["text"] ?? "", "sender": row["sender"] ?? "", "outgoing": row["outgoing"] ?? "0"]
            if let value = Double(row["date"] ?? "") {
                let seconds = abs(value) > 100_000_000_000 ? value / 1_000_000_000 : value
                fields["date"] = ISO8601DateFormatter().string(from: Date(timeIntervalSinceReferenceDate: seconds))
            }
            if fields["text"]?.isEmpty != false {
                let hex = row["attributed_body"] ?? ""
                if let data = Self.decodeHex(hex), let text = TypedStreamParser.parseAttributedBody(data) { fields["text"] = text }
                else { fields["content_status"] = "unsupported_content: no supported text body; open Messages to inspect" }
            }
            return AppleServiceRecord(id: row["id"] ?? "", title: String((fields["text"] ?? "").prefix(120)), container: chatID, fields: fields)
        }
        return AppleServiceResult(records: records.filter { r.query == nil || $0.fields["text", default: ""].localizedStandardContains(r.query!) }, nextOffset: rows.count > r.pageSize ? r.pageOffset + r.pageSize : nil,
                                  coverage: "local history with supported attributed text; attachments, edits and reactions may be unavailable; newest first; search filters the scanned page, continue nextOffset even if empty")
    }
    private static func decodeHex(_ hex: String) -> Data? {
        guard !hex.isEmpty, hex.count <= 2_097_152, hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte); index = next
        }
        return Data(bytes)
    }
    private func query(_ db: OpaquePointer, sql: String, values: [String]) throws -> [[String: String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw AppleServiceError.unsupported("Messages database schema or query is unavailable.") }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK else { throw AppleServiceError.invalid("Could not bind query.") }
        }
        var rows: [[String: String]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw AppleServiceError.unavailable("History query interrupted or database busy. Narrow the query.") }
            var row: [String: String] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                if let value = sqlite3_column_text(statement, index) {
                    row[String(cString: sqlite3_column_name(statement, index))] = String(cString: value)
                }
            }
            rows.append(row)
            guard rows.count <= 200 else { throw AppleServiceError.invalid("Query budget exceeded.") }
        }
        return rows
    }
}
