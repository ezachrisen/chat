import Foundation
import FoundationModels

/// Exercises the actual tool wrappers against fixtures, never the user's Reminders database.
@MainActor
enum ReminderToolsProbe {
    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw AppleServiceError.invalid(message) }
    }
    private static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    static func run(testModel: Bool) async throws {
        func parity<A: ReminderOperation>(_ type: A.Type) throws {
            let data = try JSONEncoder().encode(A.generationSchema)
            let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let properties = object["properties"] as! [String: Any]
            try check(Set(properties.keys) == Set(A.properties.keys), "\(A.toolName): provider fields differ")
            try check(Set(object["required"] as? [String] ?? []) == Set(A.required), "\(A.toolName): provider required fields differ")
            for (key, json) in A.properties {
                let foundation = properties[key] as! [String: Any]
                try check(foundation["type"] as? String == json.type, "\(A.toolName).\(key): provider field types differ")
                if let values = json.enumValues {
                    try check(foundation["enum"] as? [String] == values, "\(A.toolName).\(key): provider allowed values differ")
                }
            }
        }
        try parity(ListReminderListsArguments.self)
        try parity(FindRemindersArguments.self)
        try parity(ReadReminderArguments.self)
        try parity(CreateReminderArguments.self)
        try parity(UpdateReminderArguments.self)
        try parity(SetReminderCompletedArguments.self)
        try parity(DeleteReminderArguments.self)

        var grant = AppleServiceGrant()
        grant.enabled = true
        let context = AppleServiceContext(agentID: UUID(), origin: .interactive, grant: { _ in grant })
        func names(_ changes: Bool, _ deletion: Bool, _ origin: AppleServiceOrigin = .interactive) -> Set<String> {
            var scoped = context
            scoped.origin = origin
            return Set(ReminderTools.entries(context: scoped, recorder: nil, authorization: nil, allowsChanges: changes, allowsDeletion: deletion).map { $0.tool.name })
        }
        try check(names(false, false) == ReminderTools.readNames, "Read-only grant exposed mutation tools")
        try check(names(false, true) == ReminderTools.readNames, "Deletion cannot override read-only grant")
        try check(names(true, false) == ReminderTools.allNames.subtracting(["DeleteReminder"]), "Edit tool visibility mismatch")
        try check(names(true, true) == ReminderTools.allNames, "Missing writable tools")
        try check(names(true, true, .consultation) == ReminderTools.readNames, "Consultation exposed changes")
        try check(names(true, true, .backgroundConsultation) == ReminderTools.readNames, "Background consultation exposed changes")

        let fixture = Fixture()
        let runtime = AppleServiceRuntime(actionStore: AppleActionStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("actions.json")), backend: { service, request, _, _ in
            try check(service == .reminders, "Unexpected service")
            return try fixture.execute(request)
        })
        let recorder = ToolCallRecorder(capturesFullContent: true)
        let tool = ReminderOperationTool<FindRemindersArguments>(context: context, recorder: recorder, authorization: nil, runtime: runtime)
        let json = #"{"listName":"Shopping List"}"#
        let output = try await tool.executeJSON(json)
        try check(output.contains("Milk") && !output.contains("Basil"), "Named-list search included Work")
        try check(fixture.requests.last?.query == nil && fixture.requests.last?.value == "incomplete" && fixture.requests.last?.limit == 5, "Search defaults drifted")
        let typed = try JSONDecoder().decode(FindRemindersArguments.self, from: Data(json.utf8))
        let foundationOutput = try await tool.call(arguments: typed)
        try check(foundationOutput == output, "Provider execution parity failed")
        try check(recorder.snapshot().allSatisfy { $0.toolName == "FindReminders" && $0.argumentsJSON == json && $0.resultText == output }, "Debug trace lost tool name, arguments, or output")
        for badJSON in [#"{"query":"Shopping List"}"#, #"{"action":"search"}"#, #"{"status":"unknown"}"#, #"{"offset":-1}"#] {
            var rejected = false
            do { _ = try await tool.executeJSON(badJSON) } catch { rejected = true }
            try check(rejected, "Unexpected inputs silently accepted: \(badJSON)")
        }
        try check(recorder.snapshot().suffix(4).allSatisfy { !$0.succeeded }, "Rejected calls missing from debug log")
        let privateRecorder = ToolCallRecorder(capturesFullContent: false)
        let privateTool = ReminderOperationTool<FindRemindersArguments>(context: context, recorder: privateRecorder, authorization: nil, runtime: runtime)
        _ = try await privateTool.executeJSON(json)
        try check(privateRecorder.snapshot().first?.argumentsJSON == AppleServiceDiagnosticTrace.redactedArgumentsJSON, "Debug-off arguments leaked")
        try check(privateRecorder.snapshot().first?.resultText.contains("Milk") == false, "Debug-off content leaked")

        let create = try JSONDecoder().decode(CreateReminderArguments.self, from: Data(#"{"listName":"Shopping List","title":"Milk","retryKey":"create-one","notes":"2 cartons","due":"2026-09-14"}"#.utf8)).request()
        try check(create.action == "create" && create.container == "Shopping List" && create.body == "2 cartons" && create.actionID == "create-one", "Create mapping failed")
        let update = try JSONDecoder().decode(UpdateReminderArguments.self, from: Data(#"{"id":"milk","revision":"rev","retryKey":"edit-one","notes":"","due":""}"#.utf8)).request()
        try check(update.action == "update" && update.body == "" && update.due == "" && update.title == nil && update.revision == "rev", "Update clearing/preservation failed")
        for completed in [true, false] {
            let mapped = try SetReminderCompletedArguments(id: "milk", revision: "rev", completed: completed, retryKey: "complete-one").request()
            try check(mapped.action == (completed ? "complete" : "reopen"), "Completion mapping failed")
        }
        log("PASS: seven matching operation schemas; permission-based visibility; provider execution parity; defaults, validation, and debug capture.")
        if testModel { try await evaluateModel(context: context, runtime: runtime, fixture: fixture) }
    }

    private static func evaluateModel(context: AppleServiceContext, runtime: AppleServiceRuntime, fixture: Fixture) async throws {
        guard case .available = SystemLanguageModel.default.availability else {
            throw AppleServiceError.unavailable("Foundation Model is not available; model evaluation was not run.")
        }
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "yyyy-MM-dd"
        let today = date.string(from: .now)
        let through = date.string(from: Calendar.current.date(byAdding: .day, value: 3, to: .now)!)
        let cases: [(String, Bool, (AppleServiceRequest) -> Bool)] = [
            ("Do I have anything on my Shopping List in Reminders?", false, { ["Shopping List", "shopping"].contains($0.container ?? "") && ($0.query ?? "").isEmpty }),
            ("Find reminders containing passport.", false, { ($0.container ?? "").isEmpty && $0.query?.lowercased() == "passport" }),
            ("What reminders are due today through three days from today?", false, { ($0.container ?? "").isEmpty && ($0.query ?? "").isEmpty && $0.dueFrom == today && $0.dueThrough == through }),
            ("Do I have anything on my Shopping List in Reminders?", true, { ["Shopping List", "shopping"].contains($0.container ?? "") && ($0.query ?? "").isEmpty })
        ]
        let instructions = ModelPrompts.agentSystemInstructions(agentName: "Reminder test", soul: "You are a concise assistant. Use the available tools for reminder questions.", memory: "", skillsPrompt: ModelPrompts.toolsPrompt(enabledIDs: [AgentToolID.appleServices.rawValue]))
        for (prompt, advertiseChanges, correct) in cases {
            fixture.requests = []
            // Also check the larger schema surface seen by agents with editing/deletion enabled.
            // The fixture runtime remains read-only throughout this model evaluation.
            let entries = ReminderTools.entries(context: context, recorder: nil, authorization: nil, allowsChanges: advertiseChanges, allowsDeletion: advertiseChanges, runtime: runtime)
            let session = LanguageModelSession(tools: entries.map(\.tool), instructions: instructions)
            log("MODEL input (\(entries.count) tools): \(prompt)")
            let response = try await session.respond(to: prompt).content
            log("MODEL reply: \(response)")
            let searches = fixture.requests.filter { $0.action == "search" }
            try check(!searches.isEmpty && searches.allSatisfy(correct), "Foundation Model chose incorrect search scope or filters")
            log("PASS: Foundation Model used the intended Reminders filters.")
        }
    }

    private final class Fixture {
        var requests: [AppleServiceRequest] = []
        func execute(_ request: AppleServiceRequest) throws -> AppleServiceResult {
            requests.append(request)
            guard requests.count <= 20 else { throw AppleServiceError.invalid("Fixture call budget exceeded") }
            log("TOOL fixture request: \(String(decoding: try JSONEncoder().encode(request), as: UTF8.self))")
            let lists = [(id: "shopping", name: "Shopping List"), (id: "work", name: "Work")]
            if request.action == "lists" {
                return .page(lists.map { .init(id: $0.id, title: $0.name, container: $0.id, fields: ["account": "Fixture"]) }, request: request)
            }
            let all = [AppleServiceRecord(id: "milk", title: "Milk", container: "shopping"), AppleServiceRecord(id: "basil", title: "Basil", container: "work", fields: ["notes": "Shopping List recipe"]), AppleServiceRecord(id: "passport", title: "Renew passport", container: "work")]
            if request.action == "read", let record = all.first(where: { $0.id == request.id }) { return .init(records: [record]) }
            guard request.action == "search" else { throw AppleServiceError.invalid("Unexpected fixture operation") }
            let ids = try NativeAppleServices.reminderListIDs(lists: lists, container: request.container, name: request.listName)
            let records = all.filter { record in
                // These fixtures are undated, so none match an explicit date range.
                request.dueFrom == nil && request.dueThrough == nil && ids.contains(record.container)
                    && (request.query.map { query in (record.title + (record.fields["notes"] ?? "")).localizedCaseInsensitiveContains(query) } ?? true)
            }
            return .page(records, request: request, coverage: request.container.map { "List: \($0)" } ?? "All allowed lists")
        }
    }
}
