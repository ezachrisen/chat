import XCTest
import SQLite3
@testable import ChatAppleServices

final class ContractsTests: XCTestCase {
    func testPhoneRejectsURLsAndAmbiguousLocalNumbers() throws {
        XCTAssertEqual(try AppleServiceValidation.phone("+1 (415) 555-0123"), "+14155550123")
        for input in ["4155550123", "+14155550123?body=bad", "+14155550123;123", "tel:+14155550123", "+１２３４５６７８９"] {
            XCTAssertThrowsError(try AppleServiceValidation.phone(input))
        }
    }
    func testBudgetTruncationPreservesMutationOutcome() throws {
        let result = AppleServiceResult(status: "applied", records: [.init(id: "one", title: "note", container: "folder", fields: ["text": String(repeating: "🦊", count: 20_000)])])
        let encoded = try result.json(maximumBytes: 2048)
        XCTAssertLessThanOrEqual(encoded.utf8.count, 2048)
        let envelope = try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as! [String: Any]
        let record = envelope["result"] as! [String: Any]
        XCTAssertEqual(record["status"] as? String, "applied")
        XCTAssertEqual(record["contentTruncated"] as? Bool, true)
    }
    func testDiagnosticTraceIncludesServiceContentOnlyWhenDebugIsEnabled() throws {
        let request = AppleServiceRequest(
            action: "search",
            query: "fixture reminder query",
            limit: 25
        )
        let result = AppleServiceResult(
            records: [
                .init(
                    id: "fixture-id",
                    title: "Fixture reminder",
                    container: "fixture-list",
                    fields: ["notes": "fixture reminder details"]
                )
            ]
        )
        let output = try result.json()

        let compactArguments = AppleServiceDiagnosticTrace.argumentsJSON(
            for: request,
            capturesFullContent: false
        )
        let compactResult = AppleServiceDiagnosticTrace.resultText(
            output: output,
            result: result,
            capturesFullContent: false
        )
        XCTAssertEqual(compactArguments, #"{"content":"redacted"}"#)
        XCTAssertEqual(compactResult, "ok; 1 records; service content omitted")
        XCTAssertFalse(compactResult.contains("Fixture reminder"))

        let debugArguments = AppleServiceDiagnosticTrace.argumentsJSON(
            for: request,
            capturesFullContent: true
        )
        let decodedRequest = try JSONDecoder().decode(
            AppleServiceRequest.self,
            from: Data(debugArguments.utf8)
        )
        XCTAssertEqual(decodedRequest, request)
        XCTAssertEqual(
            AppleServiceDiagnosticTrace.resultText(
                output: output,
                result: result,
                capturesFullContent: true
            ),
            output
        )
        let envelope = try JSONSerialization.jsonObject(with: Data(output.utf8)) as! [String: Any]
        let encodedResult = envelope["result"] as! [String: Any]
        let records = encodedResult["records"] as! [[String: Any]]
        let fields = records[0]["fields"] as! [String: String]
        XCTAssertEqual(fields["notes"], "fixture reminder details")
    }
    func testRevisionCoversContentAndContainer() throws {
        let original = AppleServiceRecord(id: "one", title: "Note", container: "allowed", fields: ["text": "before"])
        var changed = original; changed.fields["text"] = "after"
        XCTAssertThrowsError(try AppleServiceValidation.checkRevision(original.revision, record: changed))
        changed = original; changed.container = "other"
        XCTAssertThrowsError(try AppleServiceValidation.checkRevision(original.revision, record: changed))
        XCTAssertThrowsError(try AppleServiceValidation.checkRevision(nil, record: original))
    }
    func testNotesRejectRichContentAndEscapeText() {
        XCTAssertTrue(ScriptableAppleServices.isSimpleNote("<div>Hello</div><div><br></div>"))
        for html in ["<table><tr><td>A</td></tr></table>", "<div class='Apple-dash-list'>A</div>", "<img src=x>", "<object data=x></object>"] {
            XCTAssertFalse(ScriptableAppleServices.isSimpleNote(html))
        }
        XCTAssertEqual(ScriptableAppleServices.noteHTML("<script>\n&"), "<div>&lt;script&gt;</div><div>&amp;</div>")
    }
    func testDateOnlyDoesNotAcquireATime() throws {
        let due = try NativeAppleServices.dueComponents("2026-03-08")
        XCTAssertEqual(due.year, 2026); XCTAssertEqual(due.month, 3); XCTAssertEqual(due.day, 8)
        XCTAssertNil(due.hour); XCTAssertNil(due.timeZone)
        XCTAssertThrowsError(try NativeAppleServices.dueComponents("2026-02-30"))
        XCTAssertThrowsError(try NativeAppleServices.dueComponents("2026-03-08T02:30:00"))
    }
    func testAppleEventsEncodeStringsAsData() {
        let text = "\" & do shell script \"anything\""
        let spec = AppleEventsTransport.object("note", selector: .init(string: text))
        XCTAssertEqual(spec.forKeyword( AppleEventsTransport.code("seld"))?.stringValue, text)
        XCTAssertEqual(spec.descriptorType, AppleEventsTransport.code("obj "))
    }
    func testAttributedBodyDecoderHandlesNativeArchivesAndRejectsUnknownFormats() {
        for count in [0, 5, 127, 128, 255, 256, 8192] {
            let text = String(repeating: "x", count: count) + "🌤️"
            let archive = NSArchiver.archivedData(withRootObject: NSAttributedString(string: text))
            XCTAssertEqual(TypedStreamParser.parseAttributedBody(archive), text)
        }
        XCTAssertNil(TypedStreamParser.parseAttributedBody(Data([1, 2, 3])))
        XCTAssertNil(TypedStreamParser.parseAttributedBody(Data(repeating: 0, count: 1_048_577)))
        XCTAssertNil(TypedStreamParser.parseAttributedBody(Data([0xff, 0xfe, 0x61])))
        let hostile = Data([4, 11] + Array("streamtyped".utf8) + [1, 43, 0x82, 255, 255, 255, 255])
        XCTAssertNil(TypedStreamParser.parseAttributedBody(hostile))
    }
    func testMailboxReferencesKeepAccountAndPath() throws {
        let a = MailLocator(account: "A", path: ["Inbox", "Projects"], message: 42)
        let b = MailLocator(account: "B", path: ["Inbox", "Projects"], message: 42)
        XCTAssertNotEqual(a.encoded, b.encoded)
        let stable = a.encoded
        for _ in 0..<100 { XCTAssertEqual(try MailLocator.decode(stable).encoded, stable) }
        XCTAssertEqual(try MailLocator.decode(a.encoded).message, 42)
        XCTAssertThrowsError(try MailLocator.decode("not-an-id"))
    }
}

final class ReminderSearchTests: XCTestCase {
    func testDueRangeIncludesEntireLastDayAndRejectsInvalidBounds() throws {
        let range = try NativeAppleServices.reminderDueRange(from: "2026-09-11", through: "2026-09-14")
        XCTAssertEqual(range.start, try NativeAppleServices.dueComponents("2026-09-11").date)
        XCTAssertEqual(range.end, try NativeAppleServices.dueComponents("2026-09-15").date)
        XCTAssertThrowsError(try NativeAppleServices.reminderDueRange(from: "2026-09-15", through: "2026-09-14"))
        XCTAssertThrowsError(try NativeAppleServices.reminderDueRange(from: "2026-02-30", through: nil))
        XCTAssertNil(try NativeAppleServices.reminderDueRange(from: nil, through: nil).start)
    }

    func testListScopeNeverFallsBackToAllForUnknownOrAmbiguousNames() throws {
        let lists = [(id: "work", name: "Work"), (id: "home", name: "Shopping List"), (id: "other", name: "Work")]
        XCTAssertEqual(try NativeAppleServices.reminderListIDs(lists: lists, container: nil, name: nil), ["work", "home", "other"])
        XCTAssertEqual(try NativeAppleServices.reminderListIDs(lists: lists, container: nil, name: "Shopping List"), ["home"])
        XCTAssertEqual(try NativeAppleServices.reminderListIDs(lists: lists, container: "Shopping List", name: nil), ["home"])
        XCTAssertEqual(try NativeAppleServices.reminderListIDs(lists: lists, container: "Shopping List", name: "Shopping List"), ["home"])
        XCTAssertThrowsError(try NativeAppleServices.reminderListIDs(lists: lists, container: "Work", name: nil))
        XCTAssertThrowsError(try NativeAppleServices.reminderListIDs(lists: lists, container: "Missing", name: nil))
        XCTAssertThrowsError(try NativeAppleServices.reminderListIDs(lists: Array(lists.prefix(1)), container: "Shopping List", name: nil))
        XCTAssertEqual(try NativeAppleServices.reminderListIDs(lists: lists, container: "work", name: "Work"), ["work"])
        XCTAssertThrowsError(try NativeAppleServices.reminderListIDs(lists: lists, container: nil, name: "Work"))
        XCTAssertThrowsError(try NativeAppleServices.reminderListIDs(lists: lists, container: nil, name: "Missing"))
        XCTAssertThrowsError(try NativeAppleServices.reminderListIDs(lists: lists, container: "work", name: "Shopping List"))
    }

    func testContainerIDTakesPrecedenceOverAnotherListsName() throws {
        let lists = [(id: "abc", name: "Work"), (id: "def", name: "abc")]
        XCTAssertEqual(try NativeAppleServices.reminderListIDs(lists: lists, container: "abc", name: nil), ["abc"])
        XCTAssertThrowsError(try NativeAppleServices.reminderListIDs(lists: lists, container: "abc", name: "abc"))
    }

    func testReminderSummaryOmitsDetailsAndRevisionsButRetainsDueAndPagination() throws {
        let records = [
            AppleServiceRecord(id: "one", title: "One", container: "work", fields: ["due": "2026-09-14", "notes": String(repeating: "private", count: 3000)], isReminderSummary: true),
            AppleServiceRecord(id: "two", title: "Two", container: "home", isReminderSummary: true)
        ]
        let json = try AppleServiceResult(records: records, nextOffset: 2).json(maximumBytes: 2048)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])
        let rows = try XCTUnwrap(result["records"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows[0].keys), ["id", "title", "due"])
        XCTAssertEqual(rows[0]["due"] as? String, "2026-09-14")
        XCTAssertTrue(rows[1]["due"] is NSNull)
        XCTAssertEqual(result["nextOffset"] as? Int, 2)
        XCTAssertEqual((envelope["revisions"] as? [String: String])?.count, 0)
        XCTAssertFalse(json.contains("private"))
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var now: Date {
        calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 9,
            day: 9,
            hour: 14
        ))!
    }

    private func due(_ year: Int, _ month: Int, _ day: Int, hour: Int? = nil) -> DateComponents {
        DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour
        )
    }

    private func matches(
        isCompleted: Bool,
        due: DateComponents? = nil,
        state: String? = nil
    ) -> Bool {
        NativeAppleServices.reminderMatchesSearch(
            title: "Fixture reminder",
            notes: "Fixture notes",
            isCompleted: isCompleted,
            due: due,
            request: AppleServiceRequest(action: "search", value: state),
            now: now,
            calendar: calendar
        )
    }

    func testDefaultSearchExcludesCompletedReminders() {
        XCTAssertTrue(matches(isCompleted: false))
        XCTAssertFalse(matches(isCompleted: true))
        XCTAssertTrue(matches(isCompleted: false, state: " incomplete "))
        XCTAssertFalse(matches(isCompleted: true, state: "INCOMPLETE"))
        XCTAssertFalse(matches(isCompleted: true, state: "unexpected"))
    }

    func testCompletedSearchReturnsOnlyCompletedReminders() {
        XCTAssertFalse(matches(isCompleted: false, state: "completed"))
        XCTAssertTrue(matches(isCompleted: true, state: "completed"))
    }

    func testAllSearchIncludesIncompleteAndCompletedReminders() {
        XCTAssertTrue(matches(isCompleted: false, state: "all"))
        XCTAssertTrue(matches(isCompleted: true, state: "all"))
    }

    func testOverdueSearchReturnsOnlyIncompleteRemindersPastTheirApplicableCutoff() {
        XCTAssertTrue(matches(isCompleted: false, due: due(2026, 9, 8), state: "overdue"))
        XCTAssertFalse(matches(isCompleted: false, due: due(2026, 9, 9), state: "overdue"))
        XCTAssertTrue(matches(isCompleted: false, due: due(2026, 9, 9, hour: 13), state: "overdue"))
        XCTAssertFalse(matches(isCompleted: false, due: due(2026, 9, 9, hour: 14), state: "overdue"))
        XCTAssertFalse(matches(isCompleted: false, due: due(2026, 9, 10), state: "overdue"))
        XCTAssertFalse(matches(isCompleted: false, state: "overdue"))
        XCTAssertFalse(matches(isCompleted: true, due: due(2026, 9, 8), state: "overdue"))
    }
}

@MainActor
final class ActionTests: XCTestCase {
    private func store() -> AppleActionStore { AppleActionStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("actions.json")) }
    private func context(_ grant: AppleServiceGrant, id: UUID = UUID(), origin: AppleServiceOrigin = .interactive) -> AppleServiceContext {
        AppleServiceContext(agentID: id, origin: origin, grant: { _ in grant })
    }
    func testDefaultDenyAndBackgroundDeny() async throws {
        let runtime = AppleServiceRuntime(actionStore: store(), backend: { _, _, _, _ in XCTFail("Backend must not run"); return AppleServiceResult() })
        do { _ = try await runtime.execute(.reminders, .init(action: "lists"), context: context(.init())); XCTFail("Expected denied") } catch {}
        var grant = AppleServiceGrant(); grant.enabled = true
        for origin in [AppleServiceOrigin.heartbeat, .delegated, .backgroundDelegated, .backgroundConsultation] {
            do { _ = try await runtime.execute(.reminders, .init(action: "lists"), context: context(grant, origin: origin)); XCTFail("Expected denied") } catch {}
        }
    }
    func testConsultationCannotMutateEvenWithWriteGrant() async throws {
        var grant = AppleServiceGrant(); grant.enabled = true; grant.allowsChanges = true; grant.allowsDelegation = true
        let runtime = AppleServiceRuntime(actionStore: store(), backend: { _, _, _, _ in XCTFail("Backend must not run"); return AppleServiceResult() })
        do { _ = try await runtime.execute(.reminders, .init(action: "create", title: "x", actionID: "key"), context: context(grant, origin: .consultation)); XCTFail("Expected denied") } catch {}
    }
    func testDuplicateMutationHasOneSideEffect() async throws {
        var count = 0
        let runtime = AppleServiceRuntime(actionStore: store(), backend: { _, _, _, _ in count += 1; return AppleServiceResult(status: "applied") })
        var grant = AppleServiceGrant(); grant.enabled = true; grant.allowsChanges = true
        let context = context(grant)
        let request = AppleServiceRequest(action: "create", title: "x", actionID: "same")
        _ = try await runtime.execute(.reminders, request, context: context)
        _ = try await runtime.execute(.reminders, request, context: context)
        XCTAssertEqual(count, 1)
        var changed = request; changed.title = "other"
        do { _ = try await runtime.execute(.reminders, changed, context: context); XCTFail("Expected conflict") } catch {}
        XCTAssertEqual(count, 1)
    }
    func testUncertainMutationIsNotRetried() async throws {
        var count = 0
        let runtime = AppleServiceRuntime(actionStore: store(), backend: { _, _, _, _ in count += 1; throw AppleServiceError.uncertain })
        var grant = AppleServiceGrant(); grant.enabled = true; grant.allowsChanges = true
        let context = context(grant)
        let request = AppleServiceRequest(action: "create", title: "x", actionID: "same")
        do { _ = try await runtime.execute(.reminders, request, context: context) } catch {}
        let receipt = try await runtime.execute(.reminders, request, context: context)
        XCTAssertEqual(receipt.status, "uncertain"); XCTAssertEqual(count, 1)
    }
    func testPreparedCallNeedsApprovalAndCannotChangeDestination() async throws {
        var recipients: [String] = []
        let runtime = AppleServiceRuntime(actionStore: store(), backend: { _, request, _, _ in recipients.append(request.recipient!); return AppleServiceResult(status: "handed_off") })
        var grant = AppleServiceGrant(); grant.enabled = true
        let context = context(grant)
        let prepared = try await runtime.execute(.phone, .init(action: "prepare", recipient: "+14155550123"), context: context)
        let call = AppleServiceRequest(action: "call", recipient: "+14155550999", actionID: prepared.actionID)
        let needsApproval = try await runtime.execute(.phone, call, context: context)
        XCTAssertEqual(needsApproval.status, "needs_approval")
        XCTAssertTrue(recipients.isEmpty)
        _ = try await runtime.execute(.phone, call, context: context, approved: true)
        _ = try await runtime.execute(.phone, call, context: context, approved: true)
        XCTAssertEqual(recipients, ["+14155550123"])
    }
    func testMessagesRejectsMixedConversationAndRecipientBeforeBackend() async throws {
        var grant = AppleServiceGrant(); grant.enabled = true
        let runtime = AppleServiceRuntime(actionStore: store(), backend: { _, _, _, _ in XCTFail("Must not inspect or send an ambiguous target"); return AppleServiceResult() })
        do {
            _ = try await runtime.execute(.messages, .init(action: "prepare", id: "group", body: "x", recipient: "+14155550123"), context: context(grant))
            XCTFail("Expected mixed-target rejection")
        } catch {}
    }
    func testGrantRevocationCancelsPreparedActions() async throws {
        var grant = AppleServiceGrant(); grant.enabled = true
        let runtime = AppleServiceRuntime(actionStore: store(), backend: { _, _, _, _ in XCTFail("Cancelled action must not run"); return AppleServiceResult() })
        let context = context(grant)
        let prepared = try await runtime.execute(.phone, .init(action: "prepare", recipient: "+14155550123"), context: context)
        runtime.revoke(agentID: context.agentID)
        let receipt = try await runtime.execute(.phone, .init(action: "call", actionID: prepared.actionID), context: context, approved: true)
        XCTAssertEqual(receipt.status, "cancelled")
    }
    func testAgentCannotUseAnotherAgentsAction() async throws {
        let runtime = AppleServiceRuntime(actionStore: store(), backend: { _, _, _, _ in XCTFail("Backend must not run"); return AppleServiceResult() })
        var grant = AppleServiceGrant(); grant.enabled = true; grant.sendDestinations = ["+14155550123"]
        let prepared = try await runtime.execute(.phone, .init(action: "prepare", recipient: "+14155550123"), context: context(grant))
        do { _ = try await runtime.execute(.phone, .init(action: "call", actionID: prepared.actionID), context: context(grant)); XCTFail("Expected denied") } catch {}
    }
    func testRevocationDiscardsReadResult() async throws {
        var grant = AppleServiceGrant(); grant.enabled = true
        let context = AppleServiceContext(agentID: UUID(), origin: .interactive, grant: { _ in grant })
        let runtime = AppleServiceRuntime(actionStore: store(), backend: { _, _, _, _ in grant.enabled = false; return AppleServiceResult(records: [.init(id: "private", title: "secret", container: "x")]) })
        do { _ = try await runtime.execute(.reminders, .init(action: "lists"), context: context); XCTFail("Expected denied") } catch {}
    }
    func testRestartMarksExecutingUncertainAndMalformedStoreBlocksWrites() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AppleActionStore(url: url)
        let action = ApplePreparedAction(id: "one", agentID: UUID(), service: .phone, request: .init(action: "call"), origin: .interactive, destinations: [], summary: "call", state: "executing")
        try store.save(action)
        XCTAssertEqual(AppleActionStore(url: url).actions.first?.state, "uncertain")
        try Data("broken".utf8).write(to: url)
        XCTAssertThrowsError(try AppleActionStore(url: url).save(action))
    }
}

final class MessageHistoryTests: XCTestCase {
    func testScopeQueryBindingPaginationAndReadOnly() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db); try? FileManager.default.removeItem(at: url) }
        let sql = """
        PRAGMA journal_mode=WAL;
        CREATE TABLE message (guid TEXT, text TEXT, date INTEGER, is_from_me INTEGER, handle_id INTEGER, attributedBody BLOB);
        CREATE TABLE chat (guid TEXT);
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
        CREATE TABLE handle (id TEXT);
        INSERT INTO chat VALUES ('allowed'),('forbidden');
        INSERT INTO handle VALUES ('+14155550123');
        INSERT INTO message VALUES ('one','hello',800000000000000000,0,1,NULL),('two','world',800000001000000000,1,1,NULL),('three','private',800000002000000000,0,1,NULL),('four',NULL,800000003000000000,0,1,X'010203');
        INSERT INTO chat_message_join VALUES (1,1),(1,2),(2,3),(1,4);
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        let reader = MessagesHistoryService(databaseURL: url)
        var grant = AppleServiceGrant(); grant.enabled = true; grant.allowsHistory = true; grant.resourceIDs = ["allowed"]
        let result = try await reader.execute(.init(action: "read", id: "allowed", limit: 2), grant: grant, fence: AppleServiceFence())
        XCTAssertEqual(result.records.map(\.id), ["four", "two"])
        XCTAssertEqual(result.nextOffset, 2)
        XCTAssertTrue(result.records[0].fields["content_status"]!.contains("unsupported_content"))
        let next = try await reader.execute(.init(action: "read", id: "allowed", limit: 2, offset: 2), grant: grant, fence: AppleServiceFence())
        XCTAssertEqual(next.records.map(\.id), ["one"])
        let injection = try await reader.execute(.init(action: "search", id: "allowed", query: "' OR 1=1 --"), grant: grant, fence: AppleServiceFence())
        XCTAssertTrue(injection.records.isEmpty)
        do { _ = try await reader.execute(.init(action: "read", id: "forbidden"), grant: grant, fence: AppleServiceFence()); XCTFail("Expected denied") } catch {}
        let reread = try await reader.execute(.init(action: "read", id: "allowed", limit: 100), grant: grant, fence: AppleServiceFence())
        XCTAssertEqual(reread.records.count, 3)
    }
}

@MainActor
final class AttachmentTests: XCTestCase {
    func testImportedReferencesAreAgentScopedAndDetectTampering() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.txt")
        try Data("safe".utf8).write(to: source)
        let store = AppleAttachmentStore(directory: directory.appendingPathComponent("imported"))
        let owner = UUID()
        let item = try store.importFile(source, agentID: owner)
        XCTAssertThrowsError(try store.resolve(item.id, agentID: UUID()))
        XCTAssertThrowsError(try store.resolve(source.path, agentID: owner))
        let resolved = try store.resolve(item.id, agentID: owner)
        XCTAssertEqual(resolved.0.name, "source.txt")
        try Data("evil".utf8).write(to: resolved.1)
        XCTAssertThrowsError(try store.resolve(item.id, agentID: owner))
    }
}
