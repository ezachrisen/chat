import Foundation
import XCTest
@testable import ChatAppleServices

final class ReminderResponseTests: XCTestCase {
    private func object(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    func testSearchIsOnlyIdentityTitleAndDueWithScopeOnce() throws {
        let record = AppleServiceRecord(id: "reminder-id", title: "Milk", container: "shopping", fields: ["notes": "private details", "due": "2026-09-14", "completed": "false"])
        let json = try ReminderResponses.json(.init(records: [record], nextOffset: 5, coverage: "List: Shopping List"), request: .init(action: "search", limit: 5))
        let result = try object(json)
        let rows = try XCTUnwrap(result["reminders"] as? [[String: Any]])
        XCTAssertEqual(Set(rows[0].keys), ["id", "title", "due"])
        XCTAssertEqual(result["scope"] as? String, "List: Shopping List")
        XCTAssertEqual(result["nextOffset"] as? Int, 5)
        XCTAssertFalse(json.contains("private"))
        XCTAssertFalse(json.contains("revision"))
        XCTAssertFalse(json.contains("observedAt"))
    }

    func testUndatedAndEmptyPagesAreExplicit() throws {
        let result = try object(ReminderResponses.json(.init(records: [.init(id: "id", title: "Milk", container: "shopping")]), request: .init(action: "search")))
        let row = try XCTUnwrap((result["reminders"] as? [[String: Any]])?.first)
        XCTAssertTrue(row["due"] is NSNull)
        XCTAssertTrue(result["nextOffset"] is NSNull)
        let empty = try object(ReminderResponses.json(.init(records: [], coverage: "All allowed lists"), request: .init(action: "search")))
        XCTAssertEqual((empty["reminders"] as? [[String: Any]])?.count, 0)
        XCTAssertTrue(empty["nextOffset"] is NSNull)
    }

    func testListDiscoveryHasAccountButNoRevisionEnvelope() throws {
        let json = try ReminderResponses.json(.init(records: [.init(id: "list-id", title: "Shopping List", container: "list-id", fields: ["account": "iCloud", "writable": "true"])]), request: .init(action: "lists"))
        let result = try object(json)
        let row = try XCTUnwrap((result["lists"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(row.keys), ["id", "name", "account"])
        XCTAssertEqual(row["account"] as? String, "iCloud")
        XCTAssertFalse(json.contains("revision"))
    }

    func testByteBudgetShrinksPageWithoutSkippingRecords() throws {
        let records = (0..<5).map { AppleServiceRecord(id: "id-\($0)", title: String(repeating: "🛒", count: 160), container: "shopping") }
        let request = AppleServiceRequest(action: "search", limit: 5, offset: 10)
        let json = try ReminderResponses.json(.init(records: records, nextOffset: 15), request: request, maximumBytes: 1500)
        XCTAssertLessThanOrEqual(json.utf8.count, 1500)
        let result = try object(json)
        let rows = try XCTUnwrap(result["reminders"] as? [[String: Any]])
        XCTAssertLessThan(rows.count, 5)
        XCTAssertGreaterThan(rows.count, 0)
        XCTAssertEqual(result["nextOffset"] as? Int, 10 + rows.count)
        XCTAssertEqual(rows.compactMap { $0["id"] as? String }, Array(records.prefix(rows.count)).map(\.id))

        // If the source thought this was the final page, omitted rows must still remain reachable.
        let final = try object(ReminderResponses.json(.init(records: records), request: request, maximumBytes: 1500))
        XCTAssertEqual(final["nextOffset"] as? Int, 10 + (final["reminders"] as! [[String: Any]]).count)
    }

    func testLargeDetailsPreserveOriginalRevisionAndMarkTruncatedNotes() throws {
        let record = AppleServiceRecord(id: "stable-id", title: String(repeating: "🛒", count: 300), container: "shopping", fields: ["list": "Shopping List", "notes": String(repeating: "🛒", count: 9000), "completed": "false", "due": "2026-09-14"])
        for budget in [4096, 2000, 512] {
            let json = try ReminderResponses.json(.init(records: [record]), request: .init(action: "read", id: record.id), maximumBytes: budget)
            XCTAssertLessThanOrEqual(json.utf8.count, budget)
            let result = try object(json)
            let row = try XCTUnwrap((result["reminders"] as? [[String: Any]])?.first)
            XCTAssertEqual(row["id"] as? String, record.id)
            XCTAssertEqual(row["revision"] as? String, record.revision)
            XCTAssertEqual(row["notesTruncated"] as? Bool, true)
            XCTAssertEqual(result["contentTruncated"] as? Bool, true)
            XCTAssertEqual(row["completed"] as? Bool, false)
        }
    }

    func testMutationReceiptIsCompactAndKeepsOutcomeAndRetryKey() throws {
        let record = AppleServiceRecord(id: "id", title: "Milk", container: "shopping", fields: ["notes": String(repeating: "notes", count: 5000), "completed": "true"])
        let json = try ReminderResponses.json(.init(status: "applied", records: [record], actionID: "retry-id"), request: .init(action: "complete"))
        let result = try object(json)
        XCTAssertEqual(result["status"] as? String, "applied")
        XCTAssertEqual(result["retryKey"] as? String, "retry-id")
        let row = try XCTUnwrap((result["reminders"] as? [[String: Any]])?.first)
        XCTAssertEqual(row["revision"] as? String, record.revision)
        XCTAssertEqual(row["completed"] as? Bool, true)
        XCTAssertNil(row["notes"])
        XCTAssertLessThan(json.utf8.count, 400)
    }
}
