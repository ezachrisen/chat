import Foundation
import XCTest
@testable import AgentLoopCore

final class ToolExecutionLoopTests: XCTestCase {
    private enum FixtureError: LocalizedError { case invalid, denied
        var errorDescription: String? { self == .invalid ? "Search date bounds must be YYYY-MM-DD." : "Permission denied" }
    }

    func testInvalidDatesReturnFeedbackAndAllowCorrectedRequest() async throws {
        let loop = ToolExecutionLoop()
        let first = try await loop.begin(toolName: "FindReminders", argumentsJSON: #"{"listName":"Todos","dueFrom":"2026-09-11T10:30:28"}"#)
        let output = try await loop.feedback(for: FixtureError.invalid, requestKey: first, recoverable: true)
        let feedback = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(feedback["isError"] as? Bool, true)
        XCTAssertEqual(feedback["correctionAttemptsRemaining"] as? Int, 2)
        XCTAssertEqual(feedback["error"] as? String, FixtureError.invalid.localizedDescription)
        _ = try await loop.begin(toolName: "FindReminders", argumentsJSON: #"{"listName":"Todos","dueFrom":"2026-09-11"}"#)
        let trace = loop.trace.json()
        XCTAssertTrue(trace.contains("tool_call_started"))
        XCTAssertTrue(trace.contains("tool_error_feedback_sent_to_model"))
        XCTAssertTrue(trace.contains("Search date bounds must be YYYY-MM-DD"))
        XCTAssertTrue(trace.contains("correctionAttemptsRemaining"))
    }

    func testReformattedIdenticalFailureIsBlockedBeforeExecution() async throws {
        let loop = ToolExecutionLoop()
        let first = try await loop.begin(toolName: "FindReminders", argumentsJSON: #"{"listName":"Todos","dueFrom":"bad"}"#)
        _ = try await loop.feedback(for: FixtureError.invalid, requestKey: first, recoverable: true)
        do {
            _ = try await loop.begin(toolName: "FindReminders", argumentsJSON: #"{ "dueFrom": "bad", "listName": "Todos" }"#)
            XCTFail("Unchanged failed request executed again")
        } catch ToolLoopError.repeatedRequest(let name) { XCTAssertEqual(name, "FindReminders") }
    }

    func testChangedFailuresStopAtThreeAndCannotResetBySwitchingTools() async throws {
        let loop = ToolExecutionLoop()
        for index in 0..<3 {
            let key = try await loop.begin(toolName: "Read\(index)", argumentsJSON: "{}")
            do {
                _ = try await loop.feedback(for: FixtureError.invalid, requestKey: key, recoverable: true)
                XCTAssertLessThan(index, 2)
            } catch ToolLoopError.failureLimit(let count, let message) {
                XCTAssertEqual(index, 2)
                XCTAssertEqual(count, 3)
                XCTAssertTrue(message.contains("YYYY-MM-DD"))
            }
        }
        do { _ = try await loop.begin(toolName: "Other", argumentsJSON: "{}"); XCTFail("Stopped loop restarted") }
        catch ToolLoopError.failureLimit { }
    }

    func testSuccessfulCallsStillHaveAnOverallLimit() async throws {
        let loop = ToolExecutionLoop(maximumCalls: 4)
        for _ in 0..<4 { _ = try await loop.begin(toolName: "Read", argumentsJSON: "{}") }
        do { _ = try await loop.begin(toolName: "Read", argumentsJSON: "{}"); XCTFail("Call limit ignored") }
        catch ToolLoopError.callLimit(let count) { XCTAssertEqual(count, 4) }
        XCTAssertTrue(loop.trace.json().contains("loop_stopped"))
    }

    func testConcurrentCallsShareOneBudget() async {
        let loop = ToolExecutionLoop(maximumCalls: 4)
        let successes = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<20 {
                group.addTask { (try? await loop.begin(toolName: "Read\(index)", argumentsJSON: "{}")) != nil }
            }
            var count = 0
            for await success in group where success { count += 1 }
            return count
        }
        XCTAssertEqual(successes, 4)
    }

    func testTerminalFailureAndCancellationAreNotConvertedToFeedback() async throws {
        for error: any Error in [FixtureError.denied, CancellationError()] {
            let loop = ToolExecutionLoop()
            let key = try await loop.begin(toolName: "Read", argumentsJSON: "{}")
            do { _ = try await loop.feedback(for: error, requestKey: key, recoverable: error is CancellationError); XCTFail("Terminal error swallowed") }
            catch { XCTAssertFalse(error is ToolLoopError) }
            do { _ = try await loop.begin(toolName: "Other", argumentsJSON: "{}"); XCTFail("Continued after terminal failure") }
            catch { XCTAssertFalse(error is ToolLoopError) }
        }
    }

    func testFeedbackIsBoundedAndBudgetsArePerGeneration() async throws {
        struct LargeError: LocalizedError { var errorDescription: String? { String(repeating: "🛒", count: 100_000) } }
        let firstLoop = ToolExecutionLoop(maximumCalls: 1)
        let key = try await firstLoop.begin(toolName: "Read", argumentsJSON: "{}")
        let output = try await firstLoop.feedback(for: LargeError(), requestKey: key, recoverable: true)
        XCTAssertLessThan(output.utf8.count, 1500)
        _ = try await ToolExecutionLoop(maximumCalls: 1).begin(toolName: "Read", argumentsJSON: "{}")
    }

    func testCancelledTaskCannotStartATool() async throws {
        let loop = ToolExecutionLoop(maximumCalls: 1)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await loop.begin(toolName: "Read", argumentsJSON: "{}")
        }
        do { _ = try await task.value; XCTFail("Cancelled task started a tool") }
        catch is CancellationError { }
        // Cancellation before begin did not spend the available execution slot.
        _ = try await loop.begin(toolName: "Read", argumentsJSON: "{}")
    }
}
