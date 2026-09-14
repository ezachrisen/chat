import Foundation
import FoundationModels
import SwiftData

nonisolated enum AgentSoulToolError: LocalizedError {
    case invalid(String)
    case unavailable
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .invalid(let message):
            return "invalid_request: \(message)"
        case .unavailable:
            return "unavailable: Editing this agent's Soul is no longer allowed."
        case .saveFailed:
            return "save_failed: The updated Soul could not be saved."
        }
    }
}

@MainActor
final class AgentSoulRuntime: @unchecked Sendable {
    static let maximumCharacters = 50_000

    private let agentID: Agent.ID
    private weak var agentStore: AgentStore?
    private weak var catalog: SkillCatalog?

    init(agentID: Agent.ID, agentStore: AgentStore, catalog: SkillCatalog) {
        self.agentID = agentID
        self.agentStore = agentStore
        self.catalog = catalog
    }

    func update(soul: String) throws -> String {
        guard soul.count <= Self.maximumCharacters else {
            throw AgentSoulToolError.invalid(
                "soul must be at most \(Self.maximumCharacters) characters."
            )
        }
        guard let agentStore,
              catalog?.isToolEnabled(.updateAgentSoul) == true,
              let agent = agentStore.agent(for: agentID),
              !agent.isDeleted,
              agent.isToolEnabled(.updateAgentSoul) else {
            throw AgentSoulToolError.unavailable
        }
        guard agentStore.updateAgentSoulFromTool(id: agentID, soul: soul) else {
            throw AgentSoulToolError.saveFailed
        }
        return "Soul updated. The new instructions apply to future turns."
    }
}

struct UpdateAgentSoulTool: Tool {
    let runtime: AgentSoulRuntime
    let recorder: ToolCallRecorder?
    let authorization: AgentToolAuthorization?

    var name: String { AgentToolID.updateAgentSoul.rawValue }
    var description: String { AgentToolID.updateAgentSoul.toolDescription }

    @Generable
    struct Arguments {
        @Guide(description: "The complete replacement Soul instructions. Include everything that should remain.")
        var soul: String
    }

    func call(arguments: Arguments) async throws -> String {
        try Task.checkCancellation()
        try await authorization?.check(toolName: name)
        let startedAt = Date()
        let fullArgumentsJSON = ToolArgumentsJSON.encode(["soul": arguments.soul])
        let recordedArgumentsJSON = recorder?.capturesFullContent == true
            ? fullArgumentsJSON
            : "{\"content\":\"redacted\"}"
        var capturedResult: Result<String, Error> = .failure(AgentSoulToolError.unavailable)
        defer {
            recorder?.record(
                startedAt: startedAt,
                toolName: name,
                argumentsJSON: recordedArgumentsJSON,
                skillName: nil,
                result: capturedResult
            )
        }

        do {
            let output = try await runtime.update(soul: arguments.soul)
            let validated = try await authorization?.validatedOutput(output, toolName: name) ?? output
            capturedResult = .success(validated)
            return validated
        } catch {
            capturedResult = .failure(error)
            throw error
        }
    }
}
