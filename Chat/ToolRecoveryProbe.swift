import Foundation
import FoundationModels

@MainActor
enum ToolRecoveryProbe {
    private static func check(_ value: Bool, _ message: String) throws {
        guard value else { throw AppleServiceError.invalid("Recovery probe: \(message)") }
    }
    private static func log(_ message: String) { FileHandle.standardError.write(Data((message + "\n").utf8)) }

    static func run(testModel: Bool) async throws {
        let badJSON = #"{"dueFrom":"2026-09-11T10:30:28","dueThrough":"2026-09-14T10:30:28","listName":"Todos"}"#
        let bad = try JSONDecoder().decode(FindRemindersArguments.self, from: Data(badJSON.utf8))
        let good = try JSONDecoder().decode(FindRemindersArguments.self, from: Data(#"{"dueFrom":"2026-09-11","dueThrough":"2026-09-14","listName":"Todos"}"#.utf8))
        var grant = AppleServiceGrant()
        grant.enabled = true
        grant.allowsAll = true
        let context = AppleServiceContext(agentID: UUID(), origin: .interactive, grant: { _ in grant })
        let fixture = Fixture()
        let recorder = ToolCallRecorder(capturesFullContent: true)
        let runtime = AppleServiceRuntime(actionStore: AppleActionStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("actions.json")), backend: { service, request, _, _ in
            try check(service == .reminders && request.action == "search", "Unexpected operation")
            fixture.requests.append(request)
            _ = try NativeAppleServices.reminderDueRange(from: request.dueFrom, through: request.dueThrough)
            try check(request.container == "Todos", "Recovery changed the user's list scope")
            return .init(records: [.init(id: "todo-1", title: "Renew library card", container: "Todos", fields: ["due": "2026-09-13"])], coverage: "List: Todos")
        })
        let base = ReminderOperationTool<FindRemindersArguments>(context: context, recorder: recorder, authorization: nil, runtime: runtime)
        let wrapped = RecoveringFoundationTool(base: base, loop: ToolExecutionLoop())
        let baseSchema = try JSONSerialization.jsonObject(with: JSONEncoder().encode(base.parameters)) as! NSDictionary
        let wrappedSchema = try JSONSerialization.jsonObject(with: JSONEncoder().encode(wrapped.parameters)) as! NSDictionary
        try check(baseSchema == wrappedSchema, "Wrapper changed the advertised schema")
        _ = try await wrapped.call(arguments: bad)
        _ = try await wrapped.call(arguments: good)
        try check(fixture.requests.count == 2, "Failed request or correction was not executed")
        try check(recorder.snapshot().map(\.succeeded) == [false, true], "Failed and successful attempts lost their debug status")
        do { _ = try await wrapped.call(arguments: bad); throw AppleServiceError.invalid("Unchanged request was not blocked") }
        catch ToolLoopError.repeatedRequest { }
        try check(fixture.requests.count == 2, "Repeated failure reached the backend")

        try check(ToolRecoveryPolicy.canRecover(AppleServiceError.invalid("date format"), toolName: "FindReminders", argumentsJSON: badJSON), "Read validation must be recoverable")
        for error: any Error in [AppleServiceError.forbidden, AppleServiceError.uncertain, AppleServiceError.needsSetup("Connect Reminders"), CancellationError()] {
            try check(!ToolRecoveryPolicy.canRecover(error, toolName: "FindReminders", argumentsJSON: badJSON), "Terminal read error became retryable")
        }
        for name in ["CreateReminder", "UpdateReminder", "SetReminderCompleted", "DeleteReminder", "ExecuteSkillScript", "SendNotification", "SendToAgents"] {
            try check(!ToolRecoveryPolicy.canRecover(AppleServiceError.invalid("failed after starting"), toolName: name, argumentsJSON: "{}"), "Potential side effect became retryable")
        }
        try check(ToolRecoveryPolicy.canRecover(AppleServiceError.invalid("query"), toolName: "AppleNotes", argumentsJSON: #"{"action":"search"}"#), "Generic service read cannot recover")
        try check(!ToolRecoveryPolicy.canRecover(AppleServiceError.invalid("body"), toolName: "AppleNotes", argumentsJSON: #"{"action":"append"}"#), "Generic service write became retryable")
        try check(ToolRecoveryPolicy.canRecover(CalendarAccessError.invalidStart("bad"), toolName: "ReadCalendarEvents", argumentsJSON: "{}"), "Calendar format error cannot recover")
        try check(!ToolRecoveryPolicy.canRecover(CalendarAccessError.denied, toolName: "ReadCalendarEvents", argumentsJSON: "{}"), "Calendar permission failure became retryable")
        log("PASS: Foundation wrapper preserves schemas, exposes validation failures, records both attempts, and blocks unchanged retries; unsafe failures remain terminal.")

        guard testModel else { return }
        guard case .available = SystemLanguageModel.default.availability else { throw AppleServiceError.unavailable("Foundation Model unavailable; recovery model test did not run.") }
        fixture.requests = []
        let modelRecorder = ToolCallRecorder(capturesFullContent: true)
        let modelTool = ReminderOperationTool<FindRemindersArguments>(context: context, recorder: modelRecorder, authorization: nil, runtime: runtime)
        let systemPrompt = "You are a concise Reminders assistant. Today is 2026-09-11. Use tools to answer the user's question."
        // Pin the first malformed call to the real incident, then leave correction to the actual model.
        let prompt = """
        Can you check my list called "Todos" in Reminders? Do I have anything due in the next 3 days?
        For this error-recovery test, your FIRST FindReminders call must use exactly these arguments, even though the dates may be rejected:
        \(badJSON)
        After that first call, use the tool's response to complete my original task.
        """
        let result = try await ModelClient.completeApple(systemPrompt: systemPrompt, prompt: prompt, foundationTools: [modelTool], captureDebug: true)
        log("MODEL recovery reply: \(result.finalText)")
        let attempts = modelRecorder.snapshot()
        try check(attempts.count >= 2 && attempts.first?.succeeded == false && attempts.last?.succeeded == true, "Model did not recover from an actual failed tool call")
        try check(fixture.requests.first?.dueFrom == bad.dueFrom && fixture.requests.first?.dueThrough == bad.dueThrough, "Model test did not reproduce the malformed first request")
        try check(fixture.requests.last?.dueFrom == good.dueFrom && fixture.requests.last?.dueThrough == good.dueThrough, "Model did not correct both date bounds")
        try check(fixture.requests.allSatisfy { $0.container == "Todos" }, "Model broadened the list scope")
        try check(result.finalText.localizedCaseInsensitiveContains("library"), "Final answer omitted fixture result")
        let transcript = result.debug?.appleTranscriptSummary ?? ""
        try check(transcript.contains("--- AGENT LOOP TRACE ---") && transcript.contains("tool_error_feedback_sent_to_model") && transcript.contains("tool_call_succeeded") && transcript.contains("isError") && transcript.contains("Search date bounds must be YYYY-MM-DD") && transcript.contains("2026-09-11T10:30:28") && transcript.contains("Renew library card"), "Debug capture omitted retry inputs, feedback, or corrected output")
        log("PASS: Actual Foundation Model corrected timestamp bounds to date-only values, retained Todos scope, answered from the successful result, and retained recovery diagnostics.")
    }

    private final class Fixture { var requests: [AppleServiceRequest] = [] }
}
