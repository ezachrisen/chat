import Foundation

/// One budget per generation, shared by every tool, including parallel calls.
/// Returning a failure as data lets the model choose corrected arguments; this never retries a call itself.
actor ToolExecutionLoop {
    nonisolated static let instructions = """
    Tool errors are not successful results. If a tool returns isError=true, read its error and correct the arguments before trying again. Do not repeat the unchanged failed request or widen the user's requested scope. Use only advertised tools. Stop and explain if you cannot safely correct the request. Never repeat an uncertain write, send, or other external action.
    """
    let maximumCalls: Int
    let maximumFailures: Int
    private var calls = 0
    private var failures = 0
    private var failedRequests: Set<String> = []
    private var terminalError: (any Error)?
    nonisolated let trace = ToolLoopTrace()

    init(maximumCalls: Int = 12, maximumFailures: Int = 3) {
        self.maximumCalls = maximumCalls
        self.maximumFailures = maximumFailures
    }

    func begin(toolName: String, argumentsJSON: String) throws -> String {
        do { try Task.checkCancellation() }
        catch {
            trace.append(kind: "loop_stopped", toolName: toolName, argumentsJSON: argumentsJSON,
                         output: error.localizedDescription, calls: calls, failures: failures)
            throw error
        }
        if let terminalError { throw terminalError }
        let key = toolName + "\n" + Self.canonicalJSON(argumentsJSON)
        if failedRequests.contains(key) {
            let error = ToolLoopError.repeatedRequest(toolName)
            terminalError = error
            trace.append(kind: "loop_stopped", toolName: toolName, argumentsJSON: Self.canonicalJSON(argumentsJSON),
                         output: error.localizedDescription, calls: calls, failures: failures)
            throw error
        }
        guard calls < maximumCalls else {
            let error = ToolLoopError.callLimit(maximumCalls)
            terminalError = error
            trace.append(kind: "loop_stopped", toolName: toolName, argumentsJSON: Self.canonicalJSON(argumentsJSON),
                         output: error.localizedDescription, calls: calls, failures: failures)
            throw error
        }
        calls += 1
        trace.append(kind: "tool_call_started", toolName: toolName, argumentsJSON: Self.canonicalJSON(argumentsJSON),
                     output: nil, calls: calls, failures: failures)
        return key
    }

    func succeeded(toolName: String, requestKey: String, output: String?) {
        trace.append(kind: "tool_call_succeeded", toolName: toolName,
                     argumentsJSON: Self.arguments(from: requestKey), output: output.map(Self.bounded),
                     calls: calls, failures: failures)
    }

    func feedback(for error: any Error, requestKey: String, recoverable: Bool) throws -> String {
        if Task.isCancelled { terminalError = CancellationError(); throw CancellationError() }
        if let terminalError { throw terminalError }
        guard recoverable, !(error is CancellationError) else {
            terminalError = error
            trace.append(kind: "terminal_tool_error", toolName: Self.toolName(from: requestKey),
                         argumentsJSON: Self.arguments(from: requestKey), output: Self.bounded(error.localizedDescription),
                         calls: calls, failures: failures)
            throw error
        }
        failures += 1
        failedRequests.insert(requestKey)
        guard failures < maximumFailures else {
            let stopped = ToolLoopError.failureLimit(maximumFailures, lastError: Self.bounded(error.localizedDescription))
            terminalError = stopped
            trace.append(kind: "loop_stopped", toolName: Self.toolName(from: requestKey),
                         argumentsJSON: Self.arguments(from: requestKey), output: stopped.localizedDescription,
                         calls: calls, failures: failures)
            throw stopped
        }
        let payload = Feedback(isError: true, error: Self.bounded(error.localizedDescription), correctionAttemptsRemaining: maximumFailures - failures)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let output = String(decoding: try encoder.encode(payload), as: UTF8.self)
        trace.append(kind: "tool_error_feedback_sent_to_model", toolName: Self.toolName(from: requestKey),
                     argumentsJSON: Self.arguments(from: requestKey), output: output,
                     calls: calls, failures: failures)
        return output
    }

    // Includes key ordering/whitespace normalization, so reformatting the same bad JSON is not progress.
    nonisolated static func canonicalJSON(_ input: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(input.utf8), options: [.fragmentsAllowed]),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]) else { return input }
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated private static func bounded(_ text: String) -> String {
        // Tool feedback must be small even if the original error contains a large payload.
        String(decoding: text.utf8.prefix(1200), as: UTF8.self)
    }

    nonisolated private static func toolName(from requestKey: String) -> String {
        requestKey.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? requestKey
    }

    nonisolated private static func arguments(from requestKey: String) -> String {
        requestKey.split(separator: "\n", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
    }

    nonisolated private struct Feedback: Encodable {
        let isError: Bool
        let error: String
        let correctionAttemptsRemaining: Int
    }
}

nonisolated final class ToolLoopTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [Event] = []

    func append(kind: String, toolName: String?, argumentsJSON: String?, output: String?, calls: Int, failures: Int) {
        lock.lock()
        defer { lock.unlock() }
        events.append(Event(sequence: events.count, kind: kind, toolName: toolName,
                            argumentsJSON: argumentsJSON, output: output,
                            totalCalls: calls, totalFailures: failures))
    }

    func json() -> String {
        lock.lock()
        defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? String(decoding: encoder.encode(events), as: UTF8.self)) ?? "[]"
    }

    private struct Event: Encodable {
        let sequence: Int
        let kind: String
        let toolName: String?
        let argumentsJSON: String?
        let output: String?
        let totalCalls: Int
        let totalFailures: Int
    }
}

nonisolated enum ToolLoopError: LocalizedError {
    case repeatedRequest(String)
    case callLimit(Int)
    case failureLimit(Int, lastError: String)

    var errorDescription: String? {
        switch self {
        case .repeatedRequest(let name): "Stopped: the agent repeated an unchanged failed \(name) request. No repeated tool execution was performed."
        case .callLimit(let count): "Stopped after \(count) tool calls in one generation. Please narrow the task or continue in a new turn."
        case .failureLimit(let count, let lastError): "Stopped after \(count) tool failures in one generation. Last error: \(lastError)"
        }
    }
}
