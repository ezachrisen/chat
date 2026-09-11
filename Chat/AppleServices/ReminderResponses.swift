import Foundation

/// Compact model-facing responses. IDs and edit revisions are never shortened.
nonisolated enum ReminderResponses {
    static func json(_ result: AppleServiceResult, request: AppleServiceRequest, maximumBytes: Int = 4096) throws -> String {
        guard maximumBytes >= 512 else { throw AppleServiceError.invalid("Insufficient reminder response budget.") }
        let isList = request.action == "lists"
        let isPage = isList || request.action == "search"
        var shortened = result.contentTruncated == true
        func short(_ text: String, _ limit: Int) -> String {
            if text.count > limit { shortened = true }
            return String(text.prefix(limit))
        }
        var response: [String: Any] = ["status": result.status]
        if let message = result.message { response["message"] = short(message, 250) }
        if let actionID = result.actionID { response["retryKey"] = actionID }
        var rows: [[String: Any]] = result.records.map { record in
            if isList {
                return ["id": record.id, "name": short(record.title, 120), "account": short(record.fields["account"] ?? "", 80)]
            }
            var row: [String: Any] = ["id": record.id, "title": short(record.title, 160), "due": record.fields["due"].map { $0 as Any } ?? NSNull()]
            if !isPage {
                row["revision"] = record.revision
                row["completed"] = record.fields["completed"] == "true"
                if request.action == "read" {
                    row["list"] = short(record.fields["list"] ?? record.container, 120)
                    for key in ["notes", "priority", "url", "recurrence", "alarms", "timezone"] {
                        if let value = record.fields[key], !value.isEmpty { row[key] = short(value, key == "notes" ? 1200 : 160) }
                    }
                    if let notes = record.fields["notes"], notes.count > 1200 { row["notesTruncated"] = true }
                }
            }
            return row
        }
        let key = isList ? "lists" : "reminders"
        response[key] = rows
        if request.action == "search" { response["scope"] = short(result.coverage, 160) }
        if isPage { response["nextOffset"] = result.nextOffset.map { $0 as Any } ?? NSNull() }
        if shortened { response["contentTruncated"] = true }
        func encode() throws -> Data { try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys, .fragmentsAllowed]) }
        var data = try encode()
        while data.count > maximumBytes && rows.count > 1 && isPage {
            rows.removeLast()
            response[key] = rows
            response["nextOffset"] = request.pageOffset + rows.count
            data = try encode()
        }
        // A single detailed reminder can still be large; shorten content without touching identity/revision.
        if data.count > maximumBytes, !rows.isEmpty {
            for cap in [400, 160, 40, 8, 0] {
                for index in rows.indices {
                    for field in ["notes", "title", "name", "account", "list", "url", "recurrence", "alarms"] {
                        if let value = rows[index][field] as? String, value.count > cap {
                            rows[index][field] = String(value.prefix(cap))
                            if field == "notes" { rows[index]["notesTruncated"] = true }
                        }
                    }
                }
                response[key] = rows
                response["contentTruncated"] = true
                data = try encode()
                if data.count <= maximumBytes { break }
            }
        }
        guard data.count <= maximumBytes else { throw AppleServiceError.invalid("Reminder response exceeds the available budget. Narrow the request.") }
        return String(decoding: data, as: UTF8.self)
    }
}
