import Foundation

nonisolated struct ChatGPTAccountSnapshot: Sendable, Equatable {
    let email: String?
    let planType: String?
}

nonisolated struct ChatGPTModelDescriptor: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let displayName: String
    let description: String
    let isDefault: Bool
    let defaultReasoningEffort: String?
}

nonisolated struct ChatGPTProviderInspection: Sendable {
    let account: ChatGPTAccountSnapshot?
    let models: [ChatGPTModelDescriptor]
    let executableVersion: String
}

nonisolated struct ChatGPTProviderConfiguration: Sendable {
    let executableURL: URL
    let modelID: String?
    let displayName: String
    let contextTokenLimit: Int
    let isAuthenticated: Bool?

    var validationError: String? {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return "The configured Codex executable cannot be run."
        }

        if isAuthenticated == false {
            return "Connect a ChatGPT subscription in Settings → Models."
        }

        if let modelID,
           modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Choose a ChatGPT model."
        }

        return nil
    }
}

nonisolated enum ChatGPTProviderError: LocalizedError {
    case executableNotFound
    case invalidExecutable(String)
    case processLaunchFailed(String)
    case processExited(Int32, String)
    case invalidResponse(String)
    case protocolError(String)
    case notAuthenticated
    case subscriptionRoutingUnavailable
    case noModels
    case loginFailed(String)
    case loginTimedOut
    case browserOpenFailed
    case responseTimedOut
    case interrupted
    case noFinalResponse

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "Codex was not found. Install the ChatGPT app or Codex CLI, or set its executable path in Settings → Models."
        case .invalidExecutable(let path):
            return "Codex cannot be run at \(path)."
        case .processLaunchFailed(let message):
            return "Codex could not start: \(message)"
        case .processExited(let status, let details):
            let suffix = details.isEmpty ? "" : " \(details)"
            return "Codex app-server exited with status \(status).\(suffix)"
        case .invalidResponse(let details):
            return "Codex returned an invalid response. \(details)"
        case .protocolError(let message):
            return "Codex app-server reported an error: \(message)"
        case .notAuthenticated:
            return "Codex is not signed in with ChatGPT. Connect your subscription in Settings → Models. API-key sessions are not used by this provider."
        case .subscriptionRoutingUnavailable:
            return "Codex is configured to use a non-OpenAI model provider. ChatGPT subscription routing requires Codex's built-in OpenAI provider."
        case .noModels:
            return "No ChatGPT models are available for this account."
        case .loginFailed(let message):
            return "ChatGPT sign-in failed: \(message)"
        case .loginTimedOut:
            return "ChatGPT sign-in timed out. Start the connection again when you're ready."
        case .browserOpenFailed:
            return "The ChatGPT sign-in page could not be opened."
        case .responseTimedOut:
            return "Codex did not respond in time. Try again."
        case .interrupted:
            return "The ChatGPT response was cancelled."
        case .noFinalResponse:
            return "ChatGPT completed without returning a reply."
        }
    }
}

nonisolated enum CodexExecutableResolver {
    static func resolve(configuredPath: String) -> URL? {
        let trimmedPath = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPath.isEmpty {
            guard trimmedPath.hasPrefix("/") else { return nil }
            return executableURL(atPath: trimmedPath)
        }

        var candidates: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("codex", isDirectory: false))
        }
        candidates.append(
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex", isDirectory: false)
        )

        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0), isDirectory: true)
                    .appendingPathComponent("codex", isDirectory: false)
            })
        }

        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/codex", isDirectory: false))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/codex", isDirectory: false))

        var seenPaths = Set<String>()
        for candidate in candidates {
            let normalized = candidate.standardizedFileURL
            guard seenPaths.insert(normalized.path).inserted else { continue }
            if let executable = executableURL(atPath: normalized.path) {
                return executable
            }
        }
        return nil
    }

    static func probeVersion(executableURL: URL) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ChatGPTProviderError.invalidExecutable(executableURL.path)
        }

        return try await Task.detached(priority: .utility) {
            try probeVersionSynchronously(executableURL: executableURL)
        }.value
    }

    private static func probeVersionSynchronously(executableURL: URL) throws -> String {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executableURL
        process.arguments = ["--version"]
        process.standardOutput = output
        process.standardError = errors
        let didExit = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in didExit.signal() }

        do {
            try process.run()
        } catch {
            throw ChatGPTProviderError.processLaunchFailed(error.localizedDescription)
        }
        if didExit.wait(timeout: .now() + 10) == .timedOut {
            if process.isRunning { process.terminate() }
            throw ChatGPTProviderError.responseTimedOut
        }

        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        let version = String(data: stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0, !version.isEmpty else {
            let details = CodexAppServerSession.sanitizedDiagnostic(
                String(data: stderr, encoding: .utf8) ?? ""
            )
            throw ChatGPTProviderError.processExited(process.terminationStatus, details)
        }
        return version
    }

    private static func executableURL(atPath path: String) -> URL? {
        let url = URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }
}

enum ChatGPTProviderClient {
    static func inspect(executableURL: URL) async throws -> ChatGPTProviderInspection {
        let version = try await CodexExecutableResolver.probeVersion(executableURL: executableURL)
        let session = try CodexAppServerSession(executableURL: executableURL)
        defer { session.close() }
        let timeout = sessionTimeout(session, after: 30)
        defer { timeout.cancel() }

        return try await withTaskCancellationHandler {
            try await session.initialize(experimentalAPI: false)
            let account = try await readChatGPTAccount(from: session)
            let models = account == nil ? [] : try await readModels(from: session)
            return ChatGPTProviderInspection(
                account: account,
                models: models,
                executableVersion: version
            )
        } onCancel: {
            session.cancel()
        }
    }

    static func login(
        executableURL: URL,
        openURL: @escaping @Sendable (URL) async -> Bool
    ) async throws -> ChatGPTProviderInspection {
        let version = try await CodexExecutableResolver.probeVersion(executableURL: executableURL)
        let session = try CodexAppServerSession(executableURL: executableURL)
        defer { session.close() }
        let cancellation = LoginCancellationCoordinator(session: session)
        let setupTimeout = sessionTimeout(session, after: 30)
        defer { setupTimeout.cancel() }

        return try await withTaskCancellationHandler {
            try await session.initialize(experimentalAPI: false)
            let result = try await session.request(
                method: "account/login/start",
                params: [
                    "type": "chatgpt",
                    "useHostedLoginSuccessPage": true,
                    "appBrand": "chatgpt"
                ]
            )

            guard result["type"] as? String == "chatgpt",
                  let loginID = result["loginId"] as? String,
                  let authorizationURLString = result["authUrl"] as? String,
                  let authorizationURL = validatedAuthorizationURL(authorizationURLString) else {
                throw ChatGPTProviderError.invalidResponse("The sign-in URL was missing or untrusted.")
            }
            cancellation.register(loginID: loginID)
            try Task.checkCancellation()

            guard await openURL(authorizationURL) else {
                throw ChatGPTProviderError.browserOpenFailed
            }
            setupTimeout.cancel()

            let timeout = Task {
                do {
                    try await Task.sleep(nanoseconds: 300_000_000_000)
                } catch {
                    return
                }
                session.cancelLogin(loginID: loginID, error: ChatGPTProviderError.loginTimedOut)
            }
            defer { timeout.cancel() }
            try await waitForLogin(loginID: loginID, session: session)
            timeout.cancel()
            cancellation.clearLogin()
            guard let account = try await readChatGPTAccount(from: session) else {
                throw ChatGPTProviderError.notAuthenticated
            }
            let models = try await readModels(from: session)
            return ChatGPTProviderInspection(
                account: account,
                models: models,
                executableVersion: version
            )
        } onCancel: {
            cancellation.cancel()
        }
    }

    static func generate(
        configuration: ChatGPTProviderConfiguration,
        systemPrompt: String,
        prompt: String,
        tools: AgentToolBox?,
        captureDebug: Bool
    ) async throws -> ModelGenerationResult {
        guard FileManager.default.isExecutableFile(atPath: configuration.executableURL.path) else {
            throw ChatGPTProviderError.invalidExecutable(configuration.executableURL.path)
        }
        if configuration.isAuthenticated == false {
            throw ChatGPTProviderError.notAuthenticated
        }
        if let modelID = configuration.modelID,
           modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ChatGPTProviderError.invalidResponse("The selected ChatGPT model was empty.")
        }

        var partial = ModelGenerationResult(
            finalText: "",
            reasoningTexts: [],
            intermediateAssistantTexts: [],
            openAIRoundCount: 0,
            tokenUsage: .zero,
            debug: nil
        )

        do {
            let dynamicTools = try dynamicToolSpecifications(from: tools)
            let session = try CodexAppServerSession(executableURL: configuration.executableURL)
            defer { session.close() }
            let timeout = sessionTimeout(session, after: 600)
            defer { timeout.cancel() }

            return try await withTaskCancellationHandler {
                try await session.initialize(experimentalAPI: true)
                guard try await readChatGPTAccount(from: session) != nil else {
                    throw ChatGPTProviderError.notAuthenticated
                }

                let temporaryDirectory = try makeIsolatedWorkingDirectory()
                defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

                var threadParams: [String: Any] = [
                    "approvalPolicy": "never",
                    "sandbox": "read-only",
                    "modelProvider": "openai",
                    "cwd": temporaryDirectory.path,
                    "ephemeral": true,
                    "environments": [],
                    "runtimeWorkspaceRoots": [],
                    "personality": "none",
                    "serviceName": "chat",
                    "allowProviderModelFallback": false,
                    "baseInstructions": baseInstructions,
                    "developerInstructions": developerInstructions(
                        systemPrompt: systemPrompt,
                        hasDynamicTools: !dynamicTools.isEmpty
                    )
                ]
                if let modelID = configuration.modelID {
                    threadParams["model"] = modelID
                }
                if !dynamicTools.isEmpty {
                    threadParams["dynamicTools"] = dynamicTools
                }

                let threadResult = try await session.request(
                    method: "thread/start",
                    params: threadParams
                )
                guard let thread = threadResult["thread"] as? [String: Any],
                      let threadID = thread["id"] as? String else {
                    throw ChatGPTProviderError.invalidResponse("The thread identifier was missing.")
                }
                guard threadResult["modelProvider"] as? String == "openai" else {
                    throw ChatGPTProviderError.subscriptionRoutingUnavailable
                }

                let turnResult = try await session.request(
                    method: "turn/start",
                    params: [
                        "threadId": threadID,
                        "input": [["type": "text", "text": prompt]],
                        "approvalPolicy": "never",
                        "sandboxPolicy": ["type": "readOnly", "networkAccess": false],
                        "environments": []
                    ]
                )
                guard let turn = turnResult["turn"] as? [String: Any],
                      let turnID = turn["id"] as? String else {
                    throw ChatGPTProviderError.invalidResponse("The turn identifier was missing.")
                }

                let result = try await collectGeneration(
                    session: session,
                    threadID: threadID,
                    turnID: turnID,
                    modelID: configuration.modelID,
                    tools: tools,
                    captureDebug: captureDebug
                )
                partial = result
                return result
            } onCancel: {
                session.cancel()
            }
        } catch let error as ModelGenerationError {
            throw error
        } catch {
            throw ModelGenerationError(underlying: error, partial: partial)
        }
    }

    private static let baseInstructions = """
    You are the language model powering a conversational chat application. Respond to the user's chat request directly and naturally. Do not behave like a coding workspace agent. Do not inspect files, run commands, modify a workspace, browse the web, or invoke built-in Codex tools. Only use explicitly supplied dynamic function tools when they are relevant to the user's request. Return the user-facing response as your final answer.
    """

    private static func sessionTimeout(
        _ session: CodexAppServerSession,
        after seconds: UInt64
    ) -> Task<Void, Never> {
        Task {
            do {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            } catch {
                return
            }
            session.fail(with: ChatGPTProviderError.responseTimedOut)
        }
    }

    private static func developerInstructions(systemPrompt: String, hasDynamicTools: Bool) -> String {
        let toolBoundary: String
        if hasDynamicTools {
            toolBoundary = "Only the dynamic function tools supplied by this host are available for external actions. Never use built-in shell, file, workspace, browser, web, MCP, collaboration, or patch tools."
        } else {
            toolBoundary = "No external tools are available. Never use built-in shell, file, workspace, browser, web, MCP, collaboration, or patch tools."
        }
        return """
        \(systemPrompt)

        Provider boundary: \(toolBoundary) The working directory is an inert implementation detail and is not user context.
        """
    }

    private static func collectGeneration(
        session: CodexAppServerSession,
        threadID: String,
        turnID: String,
        modelID: String?,
        tools: AgentToolBox?,
        captureDebug: Bool
    ) async throws -> ModelGenerationResult {
        var finalText: String?
        var unknownPhaseTexts: [String] = []
        var intermediateTexts: [String] = []
        var reasoningTexts: [String] = []
        var tokenUsage = TokenUsage.zero
        var toolCallCount = 0
        var lastErrorMessage: String?

        while let message = try await session.nextMessage() {
            if let requestID = message["id"],
               let method = message["method"] as? String {
                switch method {
                case "item/tool/call":
                    toolCallCount += 1
                    await answerDynamicToolCall(
                        requestID: requestID,
                        message: message,
                        expectedThreadID: threadID,
                        expectedTurnID: turnID,
                        tools: tools,
                        session: session
                    )
                case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
                    try session.sendResponse(id: requestID, result: ["decision": "decline"])
                default:
                    try session.sendError(
                        id: requestID,
                        code: -32601,
                        message: "This chat provider does not support \(method)."
                    )
                }
                continue
            }

            guard let method = message["method"] as? String,
                  let params = message["params"] as? [String: Any] else {
                continue
            }

            switch method {
            case "item/completed":
                guard params["threadId"] as? String == threadID,
                      params["turnId"] as? String == turnID,
                      let item = params["item"] as? [String: Any],
                      let type = item["type"] as? String else {
                    continue
                }
                if type == "agentMessage", let text = item["text"] as? String {
                    switch item["phase"] as? String {
                    case "final_answer":
                        finalText = text
                    case "commentary":
                        intermediateTexts.append(text)
                    default:
                        unknownPhaseTexts.append(text)
                    }
                } else if type == "reasoning",
                          let summaries = item["summary"] as? [String] {
                    reasoningTexts.append(contentsOf: summaries.filter { !$0.isEmpty })
                }

            case "thread/tokenUsage/updated":
                guard params["threadId"] as? String == threadID,
                      params["turnId"] as? String == turnID,
                      let usage = params["tokenUsage"] as? [String: Any],
                      let last = usage["last"] as? [String: Any] else {
                    continue
                }
                tokenUsage = TokenUsage(
                    promptTokens: integer(last["inputTokens"]),
                    completionTokens: integer(last["outputTokens"])
                )

            case "error":
                lastErrorMessage = (params["error"] as? [String: Any])?["message"] as? String
                    ?? params["message"] as? String

            case "turn/completed":
                guard params["threadId"] as? String == threadID,
                      let turn = params["turn"] as? [String: Any],
                      turn["id"] as? String == turnID else {
                    continue
                }
                let status = turn["status"] as? String ?? "failed"
                guard status == "completed" else {
                    let turnMessage = (turn["error"] as? [String: Any])?["message"] as? String
                    if status == "interrupted" {
                        throw ChatGPTProviderError.interrupted
                    }
                    throw ChatGPTProviderError.protocolError(
                        turnMessage ?? lastErrorMessage ?? "The turn ended with status \(status)."
                    )
                }

                let resolvedFinalText: String
                if let finalText, !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    resolvedFinalText = finalText
                    intermediateTexts.append(contentsOf: unknownPhaseTexts)
                } else if let compatibilityFinal = unknownPhaseTexts.last,
                          !compatibilityFinal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    resolvedFinalText = compatibilityFinal
                    intermediateTexts.append(contentsOf: unknownPhaseTexts.dropLast())
                } else {
                    throw ChatGPTProviderError.noFinalResponse
                }

                return ModelGenerationResult(
                    finalText: resolvedFinalText,
                    reasoningTexts: reasoningTexts,
                    intermediateAssistantTexts: intermediateTexts,
                    openAIRoundCount: max(1, toolCallCount + 1),
                    tokenUsage: tokenUsage,
                    debug: captureDebug ? debugCapture(
                        modelID: modelID,
                        toolCallCount: toolCallCount
                    ) : nil
                )

            default:
                continue
            }
        }

        throw ChatGPTProviderError.protocolError(
            lastErrorMessage ?? "Codex closed the event stream before the turn completed."
        )
    }

    private static func answerDynamicToolCall(
        requestID: Any,
        message: [String: Any],
        expectedThreadID: String,
        expectedTurnID: String,
        tools: AgentToolBox?,
        session: CodexAppServerSession
    ) async {
        guard let params = message["params"] as? [String: Any],
              params["threadId"] as? String == expectedThreadID,
              params["turnId"] as? String == expectedTurnID,
              let toolName = params["tool"] as? String,
              let tools else {
            try? session.sendResponse(
                id: requestID,
                result: dynamicToolResponse(
                    text: "The requested tool is unavailable.",
                    success: false
                )
            )
            return
        }

        do {
            let argumentsJSON = try jsonString(params["arguments"] ?? [:])
            let output = try await tools.execute(name: toolName, argumentsJSON: argumentsJSON)
            try session.sendResponse(
                id: requestID,
                result: dynamicToolResponse(text: output, success: true)
            )
        } catch {
            try? session.sendResponse(
                id: requestID,
                result: dynamicToolResponse(text: error.localizedDescription, success: false)
            )
        }
    }

    private static func dynamicToolResponse(text: String, success: Bool) -> [String: Any] {
        [
            "contentItems": [["type": "inputText", "text": text]],
            "success": success
        ]
    }

    private static func dynamicToolSpecifications(from tools: AgentToolBox?) throws -> [[String: Any]] {
        guard let tools else { return [] }
        return try tools.openAITools.map { tool in
            let data = try JSONEncoder().encode(tool)
            guard let encoded = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let function = encoded["function"] as? [String: Any],
                  let name = function["name"] as? String,
                  let description = function["description"] as? String,
                  let inputSchema = function["parameters"] else {
                throw ChatGPTProviderError.invalidResponse("A dynamic tool definition could not be encoded.")
            }
            return [
                "type": "function",
                "name": name,
                "description": description,
                "inputSchema": inputSchema
            ]
        }
    }

    private static func readChatGPTAccount(
        from session: CodexAppServerSession
    ) async throws -> ChatGPTAccountSnapshot? {
        let result = try await session.request(
            method: "account/read",
            params: ["refreshToken": true]
        )
        guard let account = result["account"] as? [String: Any],
              account["type"] as? String == "chatgpt" else {
            return nil
        }
        guard result["requiresOpenaiAuth"] as? Bool == true else {
            throw ChatGPTProviderError.subscriptionRoutingUnavailable
        }
        return ChatGPTAccountSnapshot(
            email: account["email"] as? String,
            planType: account["planType"] as? String
        )
    }

    private static func readModels(
        from session: CodexAppServerSession
    ) async throws -> [ChatGPTModelDescriptor] {
        var models: [ChatGPTModelDescriptor] = []
        var seenModelIDs = Set<String>()
        var seenCursors = Set<String>()
        var cursor: String?

        repeat {
            var params: [String: Any] = ["limit": 100, "includeHidden": false]
            if let cursor {
                guard seenCursors.insert(cursor).inserted else {
                    throw ChatGPTProviderError.invalidResponse("Model pagination repeated a cursor.")
                }
                params["cursor"] = cursor
            }

            let result = try await session.request(method: "model/list", params: params)
            guard let data = result["data"] as? [[String: Any]] else {
                throw ChatGPTProviderError.invalidResponse("The model catalog was missing.")
            }

            for item in data where item["hidden"] as? Bool != true {
                guard let modelID = (item["model"] as? String) ?? (item["id"] as? String),
                      !modelID.isEmpty,
                      seenModelIDs.insert(modelID).inserted else {
                    continue
                }
                models.append(
                    ChatGPTModelDescriptor(
                        id: modelID,
                        displayName: item["displayName"] as? String ?? modelID,
                        description: item["description"] as? String ?? "",
                        isDefault: item["isDefault"] as? Bool ?? false,
                        defaultReasoningEffort: item["defaultReasoningEffort"] as? String
                    )
                )
            }
            cursor = result["nextCursor"] as? String
        } while cursor != nil

        guard !models.isEmpty else { throw ChatGPTProviderError.noModels }
        return models.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    private static func waitForLogin(
        loginID: String,
        session: CodexAppServerSession
    ) async throws {
        while let message = try await session.nextMessage() {
            guard message["method"] as? String == "account/login/completed",
                  let params = message["params"] as? [String: Any] else {
                if let requestID = message["id"], message["method"] != nil {
                    try session.sendError(
                        id: requestID,
                        code: -32601,
                        message: "Requests are unavailable while signing in."
                    )
                }
                continue
            }

            if let completedLoginID = params["loginId"] as? String,
               completedLoginID != loginID {
                continue
            }
            guard params["success"] as? Bool == true else {
                throw ChatGPTProviderError.loginFailed(
                    params["error"] as? String ?? "The authorization was not completed."
                )
            }
            return
        }
        throw ChatGPTProviderError.loginFailed("Codex closed before authorization completed.")
    }

    private static func validatedAuthorizationURL(_ value: String) -> URL? {
        guard let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else {
            return nil
        }
        let trusted = host == "openai.com"
            || host.hasSuffix(".openai.com")
            || host == "chatgpt.com"
            || host.hasSuffix(".chatgpt.com")
        return trusted ? url : nil
    }

    private static func makeIsolatedWorkingDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Chat-ChatGPT-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            return root
        } catch {
            throw ChatGPTProviderError.processLaunchFailed(
                "An isolated working directory could not be created: \(error.localizedDescription)"
            )
        }
    }

    private static func integer(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }

    private static func jsonString(_ value: Any) throws -> String {
        if let string = value as? String {
            return string
        }
        guard JSONSerialization.isValidJSONObject(value) else {
            throw ChatGPTProviderError.invalidResponse("Tool arguments were not valid JSON.")
        }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard let string = String(data: data, encoding: .utf8) else {
            throw ChatGPTProviderError.invalidResponse("Tool arguments were not UTF-8 JSON.")
        }
        return string
    }

    private static func debugCapture(modelID: String?, toolCallCount: Int) -> ModelDebugCapture {
        let details: [String: Any] = [
            "provider": "ChatGPT subscription",
            "transport": "Codex app-server",
            "model": modelID ?? "recommended",
            "threadPersistence": "ephemeral",
            "sandbox": "read-only, network disabled",
            "dynamicToolCalls": toolCallCount
        ]
        let data = try? JSONSerialization.data(
            withJSONObject: details,
            options: [.prettyPrinted, .sortedKeys]
        )
        return ModelDebugCapture(
            appleTranscriptSummary: nil,
            openAIMessagesJSON: data.flatMap { String(data: $0, encoding: .utf8) }
        )
    }
}

private nonisolated final class LoginCancellationCoordinator: @unchecked Sendable {
    private let session: CodexAppServerSession
    private let lock = NSLock()
    private var loginID: String?
    private var wasCancelled = false

    init(session: CodexAppServerSession) {
        self.session = session
    }

    func register(loginID: String) {
        lock.lock()
        self.loginID = loginID
        let shouldCancel = wasCancelled
        lock.unlock()

        if shouldCancel {
            session.cancelLogin(loginID: loginID, error: ChatGPTProviderError.interrupted)
        }
    }

    func clearLogin() {
        lock.lock()
        loginID = nil
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        wasCancelled = true
        let loginID = loginID
        lock.unlock()

        if let loginID {
            session.cancelLogin(loginID: loginID, error: ChatGPTProviderError.interrupted)
        } else {
            session.fail(with: ChatGPTProviderError.interrupted)
        }
    }
}

private nonisolated final class CodexAppServerSession: @unchecked Sendable {
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let errorOutput: FileHandle
    private let lineFramer: AppServerLineFramer
    private let stderrCollector: BoundedTextCollector
    private var iterator: AsyncThrowingStream<String, Error>.Iterator
    private var inbox: [[String: Any]] = []
    private var nextRequestID = 1
    private let stateLock = NSLock()
    private var hasClosed = false

    init(executableURL: URL) throws {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ChatGPTProviderError.invalidExecutable(executableURL.path)
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let lineFramer = AppServerLineFramer()
        let stderrCollector = BoundedTextCollector(limit: 16_384)

        self.process = process
        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading
        errorOutput = errorPipe.fileHandleForReading
        self.lineFramer = lineFramer
        self.stderrCollector = stderrCollector
        iterator = lineFramer.stream.makeAsyncIterator()

        process.executableURL = executableURL
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        output.readabilityHandler = { [weak lineFramer] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                lineFramer?.finish()
            } else {
                lineFramer?.append(data)
            }
        }
        errorOutput.readabilityHandler = { [weak stderrCollector] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stderrCollector?.append(data)
            }
        }

        do {
            try process.run()
        } catch {
            output.readabilityHandler = nil
            errorOutput.readabilityHandler = nil
            throw ChatGPTProviderError.processLaunchFailed(error.localizedDescription)
        }
    }

    func initialize(experimentalAPI: Bool) async throws {
        _ = try await request(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "com.lemoncanyon.chat",
                    "title": "Chat",
                    "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1"
                ],
                "capabilities": ["experimentalApi": experimentalAPI]
            ]
        )
        try send(["method": "initialized"])
    }

    func request(method: String, params: [String: Any]) async throws -> [String: Any] {
        let requestID = nextRequestID
        nextRequestID += 1
        try send(["id": requestID, "method": method, "params": params])

        while let message = try await rawNextMessage() {
            if let callbackID = message["id"],
               let callbackMethod = message["method"] as? String {
                switch callbackMethod {
                case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
                    try sendResponse(id: callbackID, result: ["decision": "decline"])
                default:
                    try sendError(
                        id: callbackID,
                        code: -32601,
                        message: "This chat provider does not support \(callbackMethod)."
                    )
                }
                continue
            }
            if (message["id"] as? NSNumber)?.intValue == requestID {
                if let error = message["error"] as? [String: Any] {
                    let message = error["message"] as? String ?? "Unknown protocol error."
                    throw ChatGPTProviderError.protocolError(message)
                }
                guard let result = message["result"] as? [String: Any] else {
                    throw ChatGPTProviderError.invalidResponse("The \(method) result was missing.")
                }
                return result
            }
            inbox.append(message)
        }
        throw processEndedError()
    }

    func nextMessage() async throws -> [String: Any]? {
        if !inbox.isEmpty {
            return inbox.removeFirst()
        }
        return try await rawNextMessage()
    }

    func sendResponse(id: Any, result: [String: Any]) throws {
        try send(["id": id, "result": result])
    }

    func sendError(id: Any, code: Int, message: String) throws {
        try send([
            "id": id,
            "error": ["code": code, "message": message]
        ])
    }

    func cancel() {
        lineFramer.finish(throwing: ChatGPTProviderError.interrupted)
        close()
    }

    func cancelLogin(loginID: String, error terminalError: ChatGPTProviderError) {
        do {
            try send([
                "id": "chat-login-cancel-\(UUID().uuidString)",
                "method": "account/login/cancel",
                "params": ["loginId": loginID]
            ])
        } catch {
            fail(with: terminalError)
            return
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(100)) {
            self.fail(with: terminalError)
        }
    }

    func fail(with error: ChatGPTProviderError) {
        lineFramer.finish(throwing: error)
        close()
    }

    func close() {
        stateLock.lock()
        guard !hasClosed else {
            stateLock.unlock()
            return
        }
        hasClosed = true
        stateLock.unlock()

        output.readabilityHandler = nil
        errorOutput.readabilityHandler = nil
        try? input.close()
        if process.isRunning {
            process.terminate()
        }
        lineFramer.finish()
    }

    fileprivate static func sanitizedDiagnostic(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        text = text.replacingOccurrences(
            of: #"https?://\S+"#,
            with: "<url>",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"[A-Za-z0-9_\-]{48,}"#,
            with: "<redacted>",
            options: .regularExpression
        )
        if text.count > 1_000 {
            text = String(text.prefix(1_000)) + "…"
        }
        return text
    }

    private func rawNextMessage() async throws -> [String: Any]? {
        guard let line = try await iterator.next() else {
            if process.isRunning {
                return nil
            }
            throw processEndedError()
        }
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let message = object as? [String: Any] else {
            throw ChatGPTProviderError.invalidResponse("A non-JSON message was received.")
        }
        return message
    }

    private func send(_ object: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw ChatGPTProviderError.invalidResponse("An outgoing protocol message was not valid JSON.")
        }
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        do {
            try input.write(contentsOf: data)
        } catch {
            throw ChatGPTProviderError.processLaunchFailed(error.localizedDescription)
        }
    }

    private func processEndedError() -> ChatGPTProviderError {
        let status = process.isRunning ? -1 : process.terminationStatus
        return .processExited(
            status,
            Self.sanitizedDiagnostic(stderrCollector.snapshot())
        )
    }
}

private nonisolated final class AppServerLineFramer: @unchecked Sendable {
    let stream: AsyncThrowingStream<String, Error>
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    private let lock = NSLock()
    private var buffer = Data()
    private var isFinished = false

    init() {
        let pair = AsyncThrowingStream<String, Error>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func append(_ data: Data) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[..<newline]
            buffer.removeSubrange(...newline)
            if var line = String(data: lineData, encoding: .utf8) {
                if line.last == "\r" { line.removeLast() }
                if !line.isEmpty { lines.append(line) }
            }
        }
        lock.unlock()

        for line in lines {
            continuation.yield(line)
        }
    }

    func finish(throwing error: Error? = nil) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let remainder = String(data: buffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        buffer.removeAll(keepingCapacity: false)
        lock.unlock()

        if let remainder, !remainder.isEmpty {
            continuation.yield(remainder)
        }
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }
}

private nonisolated final class BoundedTextCollector: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var data = Data()

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ newData: Data) {
        lock.lock()
        data.append(newData)
        if data.count > limit {
            data.removeFirst(data.count - limit)
        }
        lock.unlock()
    }

    func snapshot() -> String {
        lock.lock()
        let snapshot = data
        lock.unlock()
        return String(data: snapshot, encoding: .utf8) ?? ""
    }
}
