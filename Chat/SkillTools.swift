import Foundation
import FoundationModels

nonisolated enum SkillAccessError: LocalizedError {
    case unknownSkill(String)
    case emptyPath
    case pathEscape
    case notFound(String)
    case notAFile
    case unreadable
    case tooLarge
    case timedOut
    case startFailed(String)

    var errorDescription: String? {
        switch self {
        case .unknownSkill(let name):
            return "Unknown or disabled skill “\(name)”."
        case .emptyPath:
            return "A relative file path is required."
        case .pathEscape:
            return "The path must stay inside the skill folder."
        case .notFound(let path):
            return "No file named “\(path)” was found in that skill."
        case .notAFile:
            return "That path is not a file."
        case .unreadable:
            return "The file could not be read as UTF-8 text."
        case .tooLarge:
            return "The file is too large to read."
        case .timedOut:
            return "The script timed out after 30 seconds."
        case .startFailed(let message):
            return message
        }
    }
}

nonisolated enum SkillFileAccess {
    static let maxFileBytes = 256_000
    static let scriptTimeout: TimeInterval = 30

    static func read(skillName: String, fileName: String, runtime: SkillRuntime) throws -> String {
        let skill = try requireSkill(named: skillName, runtime: runtime)
        let url = try confinedFileURL(skillRoot: skill.directoryURL, relativePath: fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SkillAccessError.notFound(fileName)
        }

        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard !isDirectory.boolValue else {
            throw SkillAccessError.notAFile
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? NSNumber, size.intValue > maxFileBytes {
            throw SkillAccessError.tooLarge
        }

        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            throw SkillAccessError.unreadable
        }
        return contents
    }

    static func execute(
        skillName: String,
        scriptName: String,
        arguments: String?,
        runtime: SkillRuntime
    ) async throws -> String {
        let skill = try requireSkill(named: skillName, runtime: runtime)
        let scriptURL = try confinedFileURL(skillRoot: skill.directoryURL, relativePath: scriptName)
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw SkillAccessError.notFound(scriptName)
        }

        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: scriptURL.path, isDirectory: &isDirectory)
        guard !isDirectory.boolValue else {
            throw SkillAccessError.notAFile
        }

        let extraArguments = (arguments ?? "")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)

        let process = Process()
        process.currentDirectoryURL = skill.directoryURL
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path] + extraArguments
        process.environment = ProcessInfo.processInfo.environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw SkillAccessError.startFailed(error.localizedDescription)
        }

        let finished: Bool = await withCheckedContinuation { continuation in
            let lock = NSLock()
            var didResume = false
            func resume(_ value: Bool) {
                lock.lock()
                defer { lock.unlock() }
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: value)
            }

            let timeout = DispatchWorkItem {
                if process.isRunning {
                    process.terminate()
                }
                resume(false)
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + scriptTimeout,
                execute: timeout
            )
            process.terminationHandler = { _ in
                timeout.cancel()
                resume(true)
            }
        }

        if process.isRunning {
            process.terminate()
        }

        let output = string(from: stdout.fileHandleForReading)
        let errorOutput = string(from: stderr.fileHandleForReading)
        if !finished {
            throw SkillAccessError.timedOut
        }

        var parts: [String] = []
        if !output.isEmpty {
            parts.append(output)
        }
        if !errorOutput.isEmpty {
            parts.append("stderr:\n\(errorOutput)")
        }
        if process.terminationStatus != 0 {
            parts.append("exit status \(process.terminationStatus)")
        }
        if parts.isEmpty {
            return "(no output)"
        }
        return parts.joined(separator: "\n\n")
    }

    static func confinedFileURL(skillRoot: URL, relativePath: String) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SkillAccessError.emptyPath
        }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            throw SkillAccessError.pathEscape
        }

        let root = skillRoot.resolvingSymlinksInPath().standardizedFileURL
        var url = root
        for component in trimmed.split(separator: "/").map(String.init) {
            if component == "." { continue }
            if component.isEmpty || component == ".." {
                throw SkillAccessError.pathEscape
            }
            url.appendPathComponent(component)
        }

        url = url.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = root.path
        let resolvedPath = url.path
        guard resolvedPath == rootPath || resolvedPath.hasPrefix(rootPath + "/") else {
            throw SkillAccessError.pathEscape
        }

        if !FileManager.default.fileExists(atPath: url.path),
           url.lastPathComponent.lowercased() == "skill.md" {
            let sibling = url.deletingLastPathComponent().appendingPathComponent("SKILL.md")
            let siblingResolved = sibling.resolvingSymlinksInPath().standardizedFileURL
            if siblingResolved.path.hasPrefix(rootPath),
               FileManager.default.fileExists(atPath: siblingResolved.path) {
                return siblingResolved
            }
        }

        return url
    }

    private static func requireSkill(named name: String, runtime: SkillRuntime) throws -> DiscoveredSkill {
        guard let skill = runtime.skill(named: name) else {
            throw SkillAccessError.unknownSkill(name)
        }
        return skill
    }

    private static func string(from handle: FileHandle) -> String {
        let data = handle.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > maxFileBytes {
            return String(trimmed.prefix(maxFileBytes)) + "\n…(truncated)"
        }
        return trimmed
    }
}

nonisolated struct CapturedToolInvocation: Sendable {
    var sequence: Int
    var roundIndex: Int
    var toolName: String
    var skillName: String?
    var argumentsJSON: String
    var resultText: String
    var succeeded: Bool
    var errorMessage: String?
    var startedAt: Date
    var completedAt: Date
}

nonisolated final class ToolCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var invocations: [CapturedToolInvocation] = []
    private var nextSequence = 0
    var roundProvider: @Sendable () -> Int = { 0 }

    func snapshot() -> [CapturedToolInvocation] {
        lock.lock()
        defer { lock.unlock() }
        return invocations
    }

    func record(
        startedAt: Date,
        toolName: String,
        argumentsJSON: String,
        skillName: String?,
        result: Result<String, Error>
    ) {
        lock.lock()
        defer { lock.unlock() }

        let completedAt = Date()
        let sequence = nextSequence
        nextSequence += 1
        let roundIndex = roundProvider()

        switch result {
        case .success(let text):
            invocations.append(
                CapturedToolInvocation(
                    sequence: sequence,
                    roundIndex: roundIndex,
                    toolName: toolName,
                    skillName: skillName,
                    argumentsJSON: argumentsJSON,
                    resultText: text,
                    succeeded: true,
                    errorMessage: nil,
                    startedAt: startedAt,
                    completedAt: completedAt
                )
            )
        case .failure(let error):
            let message = error.localizedDescription
            invocations.append(
                CapturedToolInvocation(
                    sequence: sequence,
                    roundIndex: roundIndex,
                    toolName: toolName,
                    skillName: skillName,
                    argumentsJSON: argumentsJSON,
                    resultText: message,
                    succeeded: false,
                    errorMessage: message,
                    startedAt: startedAt,
                    completedAt: completedAt
                )
            )
        }
    }
}

nonisolated enum ToolArgumentsJSON {
    static func encode(_ pairs: [String: String?]) -> String {
        let object = pairs.compactMapValues { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : value
        }
        guard let data = try? JSONEncoder().encode(object),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    static func skillName(from argumentsJSON: String) -> String? {
        struct SkillNameOnly: Decodable {
            var skill_name: String
        }

        guard let data = argumentsJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(SkillNameOnly.self, from: data) else {
            return nil
        }
        let name = decoded.skill_name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}

struct ReadSkillFileTool: Tool {
    let runtime: SkillRuntime
    let recorder: ToolCallRecorder?

    var name: String { AgentToolID.readSkillFile.rawValue }
    var description: String { AgentToolID.readSkillFile.toolDescription }

    @Generable
    struct Arguments {
        @Guide(description: "The skill name from the available skills list.")
        var skill_name: String

        @Guide(description: "A file path relative to the skill folder, such as SKILL.md.")
        var file_name: String
    }

    func call(arguments: Arguments) async throws -> String {
        let startedAt = Date()
        let argumentsJSON = ToolArgumentsJSON.encode([
            "skill_name": arguments.skill_name,
            "file_name": arguments.file_name
        ])
        var capturedResult: Result<String, Error> = .failure(
            SkillAccessError.startFailed("Tool did not return a result.")
        )
        defer {
            recorder?.record(
                startedAt: startedAt,
                toolName: name,
                argumentsJSON: argumentsJSON,
                skillName: arguments.skill_name,
                result: capturedResult
            )
        }

        do {
            let output = try SkillFileAccess.read(
                skillName: arguments.skill_name,
                fileName: arguments.file_name,
                runtime: runtime
            )
            capturedResult = .success(output)
            return output
        } catch {
            capturedResult = .failure(error)
            throw error
        }
    }
}

struct SendNotificationTool: Tool {
    let agentName: String
    let recorder: ToolCallRecorder?

    var name: String { AgentToolID.sendNotification.rawValue }
    var description: String { AgentToolID.sendNotification.toolDescription }

    @Generable
    struct Arguments {
        @Guide(description: "The notification body shown to the user.")
        var body: String

        @Guide(description: "Optional short title. Defaults to the agent name.")
        var title: String?
    }

    func call(arguments: Arguments) async throws -> String {
        let startedAt = Date()
        let argumentsJSON = ToolArgumentsJSON.encode([
            "title": arguments.title,
            "body": arguments.body
        ])
        var capturedResult: Result<String, Error> = .failure(
            SkillAccessError.startFailed("Tool did not return a result.")
        )
        defer {
            recorder?.record(
                startedAt: startedAt,
                toolName: name,
                argumentsJSON: argumentsJSON,
                skillName: nil,
                result: capturedResult
            )
        }

        do {
            let output = try await AppNotifications.send(
                title: AppNotifications.resolvedTitle(
                    title: arguments.title,
                    fallback: agentName
                ),
                body: arguments.body
            )
            capturedResult = .success(output)
            return output
        } catch {
            capturedResult = .failure(error)
            throw error
        }
    }
}

struct ReadCalendarEventsTool: Tool {
    let policy: CalendarAccessPolicy
    let recorder: ToolCallRecorder?

    var name: String { AgentToolID.readCalendarEvents.rawValue }
    var description: String { AgentToolID.readCalendarEvents.toolDescription }

    @Generable
    struct Arguments {
        @Guide(description: "Start of the range as an ISO 8601 date or date-time in the user's current time zone, for example 2026-08-01 or 2026-08-01T09:00:00.")
        var start: String

        @Guide(description: "End of the range as an ISO 8601 date or date-time in the user's current time zone, for example 2026-08-31 or 2026-08-31T17:00:00. A date-only end is inclusive of that day.")
        var end: String

        @Guide(description: "Optional comma-separated calendar IDs to query. Use IDs from previous results, not calendar names. Omit to query every calendar this agent is allowed to read.")
        var calendar_ids: String?
    }

    func call(arguments: Arguments) async throws -> String {
        let startedAt = Date()
        let argumentsJSON = ToolArgumentsJSON.encode([
            "start": arguments.start,
            "end": arguments.end,
            "calendar_ids": arguments.calendar_ids
        ])
        var capturedResult: Result<String, Error> = .failure(
            SkillAccessError.startFailed("Tool did not return a result.")
        )
        defer {
            recorder?.record(
                startedAt: startedAt,
                toolName: name,
                argumentsJSON: argumentsJSON,
                skillName: nil,
                result: capturedResult
            )
        }

        do {
            let output = try await CalendarDirectory.shared.readEvents(
                start: arguments.start,
                end: arguments.end,
                calendarIDsRaw: arguments.calendar_ids,
                policy: policy
            )
            capturedResult = .success(output)
            return output
        } catch {
            capturedResult = .failure(error)
            throw error
        }
    }
}

struct ExecuteSkillScriptTool: Tool {
    let runtime: SkillRuntime
    let recorder: ToolCallRecorder?

    var name: String { AgentToolID.executeSkillScript.rawValue }
    var description: String { AgentToolID.executeSkillScript.toolDescription }

    @Generable
    struct Arguments {
        @Guide(description: "The skill name from the available skills list.")
        var skill_name: String

        @Guide(description: "A script path relative to the skill folder, such as get_battery_levels.sh.")
        var script_name: String

        @Guide(description: "Optional extra command-line arguments as one whitespace-separated string.")
        var arguments: String?
    }

    func call(arguments: Arguments) async throws -> String {
        let startedAt = Date()
        let argumentsJSON = ToolArgumentsJSON.encode([
            "skill_name": arguments.skill_name,
            "script_name": arguments.script_name,
            "arguments": arguments.arguments
        ])
        var capturedResult: Result<String, Error> = .failure(
            SkillAccessError.startFailed("Tool did not return a result.")
        )
        defer {
            recorder?.record(
                startedAt: startedAt,
                toolName: name,
                argumentsJSON: argumentsJSON,
                skillName: arguments.skill_name,
                result: capturedResult
            )
        }

        do {
            let output = try await SkillFileAccess.execute(
                skillName: arguments.skill_name,
                scriptName: arguments.script_name,
                arguments: arguments.arguments,
                runtime: runtime
            )
            capturedResult = .success(output)
            return output
        } catch {
            capturedResult = .failure(error)
            throw error
        }
    }
}

// Only one of Apple Tool.call vs OpenAI execute runs for a given generation.
// Record in both; do not also record from transcript .toolCalls.
struct AgentToolBox: Sendable {
    let runtime: SkillRuntime
    let enabledToolIDs: Set<String>
    let recorder: ToolCallRecorder?
    let agentName: String
    let calendarPolicy: CalendarAccessPolicy

    var isEmpty: Bool {
        appleTools.isEmpty
    }

    var appleTools: [any Tool] {
        var tools: [any Tool] = []
        if enabledToolIDs.contains(AgentToolID.readSkillFile.rawValue) {
            tools.append(ReadSkillFileTool(runtime: runtime, recorder: recorder))
        }
        if enabledToolIDs.contains(AgentToolID.executeSkillScript.rawValue) {
            tools.append(ExecuteSkillScriptTool(runtime: runtime, recorder: recorder))
        }
        if enabledToolIDs.contains(AgentToolID.sendNotification.rawValue) {
            tools.append(SendNotificationTool(agentName: agentName, recorder: recorder))
        }
        if enabledToolIDs.contains(AgentToolID.readCalendarEvents.rawValue) {
            tools.append(ReadCalendarEventsTool(policy: calendarPolicy, recorder: recorder))
        }
        return tools
    }

    var openAITools: [OpenAITool] {
        appleTools.map { tool in
            switch tool.name {
            case AgentToolID.readSkillFile.rawValue:
                return OpenAITool.function(
                    name: tool.name,
                    description: tool.description,
                    properties: [
                        "skill_name": OpenAIJSONProperty(type: "string", description: "The skill name from the available skills list."),
                        "file_name": OpenAIJSONProperty(type: "string", description: "A file path relative to the skill folder, such as SKILL.md.")
                    ],
                    required: ["skill_name", "file_name"]
                )
            case AgentToolID.executeSkillScript.rawValue:
                return OpenAITool.function(
                    name: tool.name,
                    description: tool.description,
                    properties: [
                        "skill_name": OpenAIJSONProperty(type: "string", description: "The skill name from the available skills list."),
                        "script_name": OpenAIJSONProperty(type: "string", description: "A script path relative to the skill folder."),
                        "arguments": OpenAIJSONProperty(type: "string", description: "Optional extra command-line arguments as one whitespace-separated string.")
                    ],
                    required: ["skill_name", "script_name"]
                )
            case AgentToolID.sendNotification.rawValue:
                return OpenAITool.function(
                    name: tool.name,
                    description: tool.description,
                    properties: [
                        "body": OpenAIJSONProperty(type: "string", description: "The notification body shown to the user."),
                        "title": OpenAIJSONProperty(type: "string", description: "Optional short title. Defaults to the agent name.")
                    ],
                    required: ["body"]
                )
            case AgentToolID.readCalendarEvents.rawValue:
                return OpenAITool.function(
                    name: tool.name,
                    description: tool.description,
                    properties: [
                        "start": OpenAIJSONProperty(type: "string", description: "Start of the range as an ISO 8601 date or date-time in the user's current time zone, for example 2026-08-01 or 2026-08-01T09:00:00."),
                        "end": OpenAIJSONProperty(type: "string", description: "End of the range as an ISO 8601 date or date-time in the user's current time zone, for example 2026-08-31 or 2026-08-31T17:00:00. A date-only end is inclusive of that day."),
                        "calendar_ids": OpenAIJSONProperty(type: "string", description: "Optional comma-separated calendar IDs to query. Use IDs, not names. Omit to query every allowed calendar.")
                    ],
                    required: ["start", "end"]
                )
            default:
                return OpenAITool.function(
                    name: tool.name,
                    description: tool.description,
                    properties: [:],
                    required: []
                )
            }
        }
    }

    func execute(name: String, argumentsJSON: String) async throws -> String {
        let startedAt = Date()
        var capturedResult: Result<String, Error> = .failure(
            SkillAccessError.startFailed("Tool did not return a result.")
        )
        defer {
            recorder?.record(
                startedAt: startedAt,
                toolName: name,
                argumentsJSON: argumentsJSON,
                skillName: ToolArgumentsJSON.skillName(from: argumentsJSON),
                result: capturedResult
            )
        }

        do {
            let data = Data(argumentsJSON.utf8)
            let output: String
            switch name {
            case AgentToolID.readSkillFile.rawValue:
                let arguments = try JSONDecoder().decode(ReadSkillFileCall.self, from: data)
                output = try SkillFileAccess.read(
                    skillName: arguments.skill_name,
                    fileName: arguments.file_name,
                    runtime: runtime
                )
            case AgentToolID.executeSkillScript.rawValue:
                let arguments = try JSONDecoder().decode(ExecuteSkillScriptCall.self, from: data)
                output = try await SkillFileAccess.execute(
                    skillName: arguments.skill_name,
                    scriptName: arguments.script_name,
                    arguments: arguments.arguments,
                    runtime: runtime
                )
            case AgentToolID.sendNotification.rawValue:
                let arguments = try JSONDecoder().decode(SendNotificationCall.self, from: data)
                output = try await AppNotifications.send(
                    title: AppNotifications.resolvedTitle(
                        title: arguments.title,
                        fallback: agentName
                    ),
                    body: arguments.body
                )
            case AgentToolID.readCalendarEvents.rawValue:
                let arguments = try JSONDecoder().decode(ReadCalendarEventsCall.self, from: data)
                output = try await CalendarDirectory.shared.readEvents(
                    start: arguments.start,
                    end: arguments.end,
                    calendarIDsRaw: arguments.calendar_ids,
                    policy: calendarPolicy
                )
            default:
                throw SkillAccessError.startFailed("Unknown tool “\(name)”.")
            }
            capturedResult = .success(output)
            return output
        } catch {
            capturedResult = .failure(error)
            throw error
        }
    }

    @MainActor
    static func make(
        agent: Agent?,
        catalog: SkillCatalog,
        recorder: ToolCallRecorder? = nil
    ) -> AgentToolBox {
        AgentToolBox(
            runtime: catalog.runtime(for: agent),
            enabledToolIDs: catalog.enabledToolIDs(for: agent),
            recorder: recorder,
            agentName: agent?.displayName ?? "Chat",
            calendarPolicy: agent?.calendarAccessPolicy ?? .none
        )
    }
}

private struct ReadSkillFileCall: Decodable {
    var skill_name: String
    var file_name: String
}

private struct ExecuteSkillScriptCall: Decodable {
    var skill_name: String
    var script_name: String
    var arguments: String?
}

private struct SendNotificationCall: Decodable {
    var title: String?
    var body: String
}

private struct ReadCalendarEventsCall: Decodable {
    var start: String
    var end: String
    var calendar_ids: String?
}

struct OpenAITool: Encodable, Sendable {
    var type = "function"
    var function: OpenAIFunctionDefinition

    static func function(
        name: String,
        description: String,
        properties: [String: OpenAIJSONProperty],
        required: [String]
    ) -> OpenAITool {
        OpenAITool(
            function: OpenAIFunctionDefinition(
                name: name,
                description: description,
                parameters: OpenAIJSONSchema(properties: properties, required: required)
            )
        )
    }
}

struct OpenAIFunctionDefinition: Encodable, Sendable {
    var name: String
    var description: String
    var parameters: OpenAIJSONSchema
}

struct OpenAIJSONSchema: Encodable, Sendable {
    var type = "object"
    var properties: [String: OpenAIJSONProperty]
    var required: [String]
}

struct OpenAIJSONProperty: Encodable, Sendable {
    var type: String
    var description: String
}
