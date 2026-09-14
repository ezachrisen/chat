import Foundation
import FoundationModels

@MainActor
enum AgentSoulToolProbe {
    static func run(
        agentID: Agent.ID,
        agentStore: AgentStore,
        catalog: SkillCatalog
    ) async throws {
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw AgentSoulToolError.invalid("Soul tool probe: \(message)") }
        }

        guard let agent = agentStore.agent(for: agentID) else {
            throw AgentSoulToolError.unavailable
        }
        let originalSoul = agent.soul
        let wasGloballyEnabled = catalog.isToolEnabled(.updateAgentSoul)
        let wasEnabledForAgent = agent.isToolEnabled(.updateAgentSoul)
        defer {
            catalog.setToolEnabled(.updateAgentSoul, enabled: wasGloballyEnabled)
            agentStore.setTool(.updateAgentSoul, enabled: wasEnabledForAgent, for: agentID)
            agentStore.updateAgentSoul(id: agentID, soul: originalSoul)
        }

        catalog.setToolEnabled(.updateAgentSoul, enabled: true)
        agentStore.setTool(.updateAgentSoul, enabled: true, for: agentID)

        let debugRecorder = ToolCallRecorder(capturesFullContent: true)
        let tools = AgentToolBox.make(
            agent: agentStore.agent(for: agentID),
            catalog: catalog,
            recorder: debugRecorder,
            agentStore: agentStore
        )
        try check(
            tools.foundationModelTools.contains { $0.name == AgentToolID.updateAgentSoul.rawValue },
            "Foundation Models tool is missing"
        )
        guard let openAITool = tools.openAITools.first(where: {
            $0.function.name == AgentToolID.updateAgentSoul.rawValue
        }) else {
            throw AgentSoulToolError.invalid("Soul tool probe: OpenAI tool is missing")
        }
        try check(
            Set(openAITool.function.parameters.properties.keys) == ["soul"]
                && openAITool.function.parameters.required == ["soul"],
            "provider schemas differ"
        )

        let firstSoul = "Be concise. This is the OpenAI execution path."
        let firstJSON = try JSONSerialization.data(
            withJSONObject: ["soul": firstSoul],
            options: [.sortedKeys]
        )
        _ = try await tools.execute(
            name: AgentToolID.updateAgentSoul.rawValue,
            argumentsJSON: String(decoding: firstJSON, as: UTF8.self)
        )
        try check(agentStore.agent(for: agentID)?.soul == firstSoul, "OpenAI path did not persist")
        try check(
            debugRecorder.snapshot().last?.argumentsJSON.contains(firstSoul) == true,
            "debug logging omitted the replacement Soul"
        )

        guard let foundationTool = tools.foundationModelTools.first(where: {
            $0.name == AgentToolID.updateAgentSoul.rawValue
        }) as? UpdateAgentSoulTool else {
            throw AgentSoulToolError.invalid("Soul tool probe: Foundation tool type differs")
        }
        let secondSoul = "Be thoughtful. This is the Foundation Models execution path."
        _ = try await foundationTool.call(arguments: .init(soul: secondSoul))
        try check(agentStore.agent(for: agentID)?.soul == secondSoul, "Foundation path did not persist")

        let quietRecorder = ToolCallRecorder(capturesFullContent: false)
        let quietTools = AgentToolBox.make(
            agent: agentStore.agent(for: agentID),
            catalog: catalog,
            recorder: quietRecorder,
            agentStore: agentStore
        )
        _ = try await quietTools.execute(
            name: AgentToolID.updateAgentSoul.rawValue,
            argumentsJSON: #"{"soul":"Private replacement"}"#
        )
        try check(
            quietRecorder.snapshot().last?.argumentsJSON == "{\"content\":\"redacted\"}",
            "non-debug logging retained Soul content"
        )

        agentStore.setTool(.updateAgentSoul, enabled: false, for: agentID)
        do {
            _ = try await tools.execute(
                name: AgentToolID.updateAgentSoul.rawValue,
                argumentsJSON: #"{"soul":"Must not be saved"}"#
            )
            throw AgentSoulToolError.invalid("Soul tool probe: revoked permission still wrote")
        } catch AgentSoulToolError.unavailable {
            // Expected: the live permission check invalidates an already-created toolbox.
        }

        agentStore.setTool(.updateAgentSoul, enabled: true, for: agentID)
        catalog.setToolEnabled(.updateAgentSoul, enabled: false)
        do {
            _ = try await tools.execute(
                name: AgentToolID.updateAgentSoul.rawValue,
                argumentsJSON: #"{"soul":"Must also not be saved"}"#
            )
            throw AgentSoulToolError.invalid("Soul tool probe: global revocation still wrote")
        } catch AgentSoulToolError.unavailable {
            // Expected: both permission layers are checked at execution time.
        }

        FileHandle.standardError.write(
            Data("PASS: UpdateAgentSoul scope, persistence, provider parity, debug capture, redaction, and live revocation.\n".utf8)
        )
    }
}
