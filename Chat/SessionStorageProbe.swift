import Foundation
import SwiftData

enum SessionStorageProbe {
    static let argument = "--session-storage-self-test"
    private static let generationTimeout: Duration = .seconds(180)

    static var isRequested: Bool {
        CommandLine.arguments.contains(argument)
    }

    private static let logURL = URL(fileURLWithPath: "/tmp/chat-session-storage-test/probe.log")

    private static func writeLog(_ line: String) {
        let text = line + "\n"
        if let data = text.data(using: .utf8) {
            FileHandle.standardError.write(data)
            try? FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: logURL) {
                _ = try? handle.seekToEnd()
                handle.write(data)
                try? handle.close()
            }
        }
    }

    @MainActor
    static func maybeRun(
        container: ModelContainer,
        agentStore: AgentStore,
        chatStore: ChatStore,
        skillCatalog: SkillCatalog
    ) async {
        guard isRequested else { return }

        try? FileManager.default.removeItem(at: logURL)
        writeLog("=== session storage self-test ===")

        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition {
                failures.append(message)
                writeLog("FAIL \(message)")
            } else {
                writeLog("PASS \(message)")
            }
        }
        writeLog("default store URL: \(ChatModelContainer.defaultStoreURL().path)")
        writeLog("active store URL: \(container.configurations.first?.url.path ?? "(unknown)")")

        await verifyIncompatibleStoreIsNotWiped(check: check)
        await verifyGenerations(
            container: container,
            agentStore: agentStore,
            chatStore: chatStore,
            skillCatalog: skillCatalog,
            check: check
        )

        if failures.isEmpty {
            writeLog("=== session storage self-test: all checks passed ===")
            exit(0)
        } else {
            writeLog("=== session storage self-test: \(failures.count) failure(s) ===")
            for failure in failures {
                writeLog(" - \(failure)")
            }
            exit(1)
        }
    }

    @MainActor
    private static func verifyIncompatibleStoreIsNotWiped(check: (Bool, String) -> Void) async {
        let copyURL = URL(fileURLWithPath: "/tmp/chat-session-storage-test/store-copy/default.store")
        let markerURL = URL(fileURLWithPath: "/tmp/chat-session-storage-test/copy-stat.txt")
        guard FileManager.default.fileExists(atPath: copyURL.path) else {
            check(false, "copied on-disk store exists at \(copyURL.path)")
            return
        }

        let before = fileIdentity(copyURL)
        var opened = false
        var openError: String?
        do {
            _ = try ChatModelContainer.make(configuration: ModelConfiguration(url: copyURL))
            opened = true
        } catch {
            openError = error.localizedDescription
        }
        let after = fileIdentity(copyURL)
        let markerUnchanged = (try? String(contentsOf: markerURL, encoding: .utf8))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "\(after.size) \(after.mtime)" } ?? false

        check(FileManager.default.fileExists(atPath: copyURL.path), "copied store file still exists")
        if opened {
            writeLog("NOTE copied foreign store opened; lightweight migration may have rewritten it")
            writeLog("copy sha before=\(before.sha256) after=\(after.sha256)")
        } else {
            writeLog("incompatible-store open error: \(openError ?? "unknown")")
            check(after.sha256 == before.sha256, "failed ModelContainer init did not delete or rewrite the copied store")
            check(markerUnchanged || after.size == before.size, "copied store size still matches pre-open marker")
        }
    }

    @MainActor
    private static func verifyGenerations(
        container: ModelContainer,
        agentStore: AgentStore,
        chatStore: ChatStore,
        skillCatalog: SkillCatalog,
        check: (Bool, String) -> Void
    ) async {
        let context = container.mainContext
        let existingAgents = agentStore.agents.count
        let existingChats = chatStore.chats.count
        writeLog("fresh store loaded agents=\(existingAgents) chats=\(existingChats)")
        check(existingAgents > 0, "agents load after container init")
        check(existingChats > 0, "chats load after container init")

        let quietAgent = makeProbeAgent(
            name: "Probe Quiet",
            debug: false,
            agentStore: agentStore,
            skillCatalog: skillCatalog
        )
        let debugAgent = makeProbeAgent(
            name: "Probe Debug",
            debug: true,
            agentStore: agentStore,
            skillCatalog: skillCatalog
        )
        check(quietAgent.isDebugLogEnabled == false, "quiet agent debug defaults off")
        check(debugAgent.isDebugLogEnabled == true, "debug agent debug log enabled")

        let recorder = ToolCallRecorder()
        let toolbox = AgentToolBox.make(agent: debugAgent, catalog: skillCatalog, recorder: recorder)
        do {
            let output = try await toolbox.execute(
                name: AgentToolID.executeSkillScript.rawValue,
                argumentsJSON: #"{"skill_name":"get_peripheral_battery_levels","script_name":"get_battery_levels.sh"}"#
            )
            let invocations = recorder.snapshot()
            check(!invocations.isEmpty, "toolbox recorder captured ExecuteSkillScript")
            check(invocations.first?.skillName == "get_peripheral_battery_levels", "captured skill_name")
            check(!output.isEmpty, "skill script returned output")
            writeLog("skill output prefix: \(output.prefix(160))")
        } catch {
            check(false, "ExecuteSkillScript recorder path: \(error.localizedDescription)")
        }

        let quietChat = chatStore.chats.first(where: { $0.agentID == quietAgent.id })
            ?? {
                chatStore.startChat(with: quietAgent)
                return chatStore.chats.first { $0.agentID == quietAgent.id }
            }()
        let debugChat = chatStore.chats.first(where: { $0.agentID == debugAgent.id })
            ?? {
                chatStore.startChat(with: debugAgent)
                return chatStore.chats.first { $0.agentID == debugAgent.id }
            }()
        guard let quietChat, let debugChat else {
            check(false, "direct chats exist for probe agents")
            return
        }

        let greetingID = quietChat.messages.first?.id
        if let greetingID {
            let greetingTurn = GenerationQuery.fetchTurn(forAssistantMessage: greetingID, in: context)
            check(greetingTurn == nil, "greeting has no generation turn")
        }

        writeLog("quiet availability: \(quietChat.availabilityMessage) canSend=\(quietChat.canSend)")
        writeLog("debug availability: \(debugChat.availabilityMessage) canSend=\(debugChat.canSend)")

        let offTurn = await sendAndWait(
            chat: quietChat,
            context: context,
            prompt: "Reply with exactly the word pong and nothing else.",
            check: check,
            label: "debug-off reply"
        )
        if let offTurn {
            check(offTurn.kind == .direct, "debug-off turn kind is direct")
            check(offTurn.debugCaptureEnabled == false, "debug-off turn did not snapshot debug")
            let payload = GenerationQuery.fetchDebugPayload(forTurn: offTurn.id, in: context)
            check(payload == nil, "debug-off did not write GenerationDebugPayload")
            check(offTurn.assistantMessageID != nil || offTurn.status == .passed || offTurn.status == .emptyVisible,
                  "debug-off turn has status \(offTurn.status.rawValue)")
        }

        let onTurn = await sendAndWait(
            chat: debugChat,
            context: context,
            prompt: "Use ExecuteSkillScript with skill_name get_peripheral_battery_levels and script_name get_battery_levels.sh if you can. Then reply with exactly the word pong.",
            check: check,
            label: "debug-on reply"
        )
        if let onTurn {
            check(onTurn.debugCaptureEnabled == true, "debug-on turn snapshotted debug flag")
            let payload = GenerationQuery.fetchDebugPayload(forTurn: onTurn.id, in: context)
            check(payload != nil, "debug-on wrote GenerationDebugPayload")
            if let payload {
                check(!payload.systemPrompt.isEmpty, "debug payload has system prompt")
                check(!payload.conversationPrompt.isEmpty, "debug payload has conversation prompt")
                check(!payload.rawModelOutput.isEmpty || onTurn.status == .failed, "debug payload has raw output")
                writeLog("debug payload system prompt chars=\(payload.systemPrompt.count) conversation chars=\(payload.conversationPrompt.count) raw chars=\(payload.rawModelOutput.count)")
            }
            if onTurn.assistantMessageID != nil {
                let inspectorTurn = GenerationQuery.fetchTurn(forAssistantMessage: onTurn.assistantMessageID!, in: context)
                check(inspectorTurn?.id == onTurn.id, "inspector lookup by assistantMessageID")
                let shouldShow = onTurn.toolCallCount > 0 || onTurn.debugCaptureEnabled
                check(shouldShow, "inspector control would appear on debug-on assistant bubble")
            }
        }

        await verifyHeartbeat(
            agent: debugAgent,
            chatStore: chatStore,
            agentStore: agentStore,
            context: context,
            check: check
        )

        let allTurns = (try? context.fetch(GenerationQuery.turnsInChat(quietChat.id))) ?? []
        let debugTurns = (try? context.fetch(GenerationQuery.turnsInChat(debugChat.id))) ?? []
        writeLog("quiet chat turns=\(allTurns.count) debug chat turns=\(debugTurns.count) heartbeat runs=\(agentStore.heartbeatRuns.count)")
        check(!allTurns.isEmpty || offTurn != nil, "quiet chat has persisted turns")
        check(!debugTurns.isEmpty || onTurn != nil, "debug chat has persisted turns")
    }

    @MainActor
    private static func verifyHeartbeat(
        agent: Agent,
        chatStore: ChatStore,
        agentStore: AgentStore,
        context: ModelContext,
        check: (Bool, String) -> Void
    ) async {
        agentStore.addHeartbeat(to: agent.id)
        guard let heartbeat = agentStore.heartbeats.last(where: { $0.agentID == agent.id }) else {
            check(false, "heartbeat row inserted")
            return
        }
        agentStore.updateHeartbeatInstruction(
            heartbeat,
            instruction: "Reply with exactly the word pong and nothing else."
        )
        agentStore.updateHeartbeatEnabled(heartbeat, isEnabled: true)

        let scheduler = HeartbeatScheduler(agentStore: agentStore, chatStore: chatStore)
        let runsBefore = agentStore.heartbeatRuns.count
        scheduler.runNow(heartbeat.id)

        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if scheduler.runningHeartbeats.isEmpty,
               agentStore.heartbeatRuns.count > runsBefore {
                break
            }
            try? await Task.sleep(for: .milliseconds(200))
        }

        let run = agentStore.heartbeatRuns.first { $0.heartbeatID == heartbeat.id }
        check(run != nil, "heartbeat completion inserted HeartbeatRun")
        guard let run else { return }

        check(run.modelInput.isEmpty, "new HeartbeatRun.modelInput is empty")
        check(run.modelOutput == nil, "new HeartbeatRun.modelOutput is nil")
        writeLog("heartbeat action: \(run.actionSummary) error=\(run.errorMessage ?? "nil")")

        if let turnID = run.generationTurnID {
            let turn = try? context.fetch(
                FetchDescriptor<GenerationTurn>(predicate: #Predicate { $0.id == turnID })
            ).first
            check(turn != nil, "heartbeat run links to GenerationTurn")
            check(turn?.kind == .heartbeat, "heartbeat turn kind")
            check(turn?.heartbeatRunID == run.id, "turn.heartbeatRunID points at run")
            if turn?.debugCaptureEnabled == true {
                let payload = GenerationQuery.fetchDebugPayload(forTurn: turnID, in: context)
                check(payload != nil, "debug-on heartbeat wrote payload instead of HeartbeatRun.modelInput")
            }
            let tools = GenerationQuery.fetchToolCalls(forTurn: turnID, in: context)
            writeLog("heartbeat tools=\(tools.count) debug=\(turn?.debugCaptureEnabled ?? false) status=\(turn?.status.rawValue ?? "?")")
        } else {
            check(false, "heartbeat with known destination inserted a generation turn")
        }
    }

    @MainActor
    private static func sendAndWait(
        chat: ChatViewModel,
        context: ModelContext,
        prompt: String,
        check: (Bool, String) -> Void,
        label: String
    ) async -> GenerationTurn? {
        if !chat.canSend {
            check(false, "\(label) can send (\(chat.availabilityMessage))")
            return nil
        }

        let messageCountBefore = chat.messages.count
        chat.draft = prompt
        chat.send()
        let deadline = Date().addingTimeInterval(180)
        while chat.isResponding, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        check(!chat.isResponding, "\(label) finished before timeout")

        let newAssistant = chat.messages.dropFirst(messageCountBefore).last { $0.role == .assistant }
        let user = chat.messages.dropFirst(messageCountBefore).last { $0.role == .user }
        check(user != nil, "\(label) persisted user message")

        if let newAssistant {
            writeLog("\(label) assistant: \(newAssistant.text.prefix(240))")
            let turn = GenerationQuery.fetchTurn(forAssistantMessage: newAssistant.id, in: context)
            check(turn != nil, "\(label) inspector can fetch turn for assistant bubble")
            if let turn {
                writeLog("\(label) turn status=\(turn.status.rawValue) tools=\(turn.toolCallCount) debug=\(turn.debugCaptureEnabled) summary=\(turn.actionSummary)")
            }
            return turn
        }

        if let user {
            let turns = (try? context.fetch(GenerationQuery.turns(forUserMessage: user.id))) ?? []
            check(!turns.isEmpty, "\(label) wrote a turn even without an assistant bubble")
            return turns.first
        }
        return nil
    }

    @MainActor
    private static func makeProbeAgent(
        name: String,
        debug: Bool,
        agentStore: AgentStore,
        skillCatalog: SkillCatalog
    ) -> Agent {
        agentStore.addAgent()
        guard let agent = agentStore.selectedAgent else {
            fatalError("addAgent did not select an agent")
        }
        agentStore.updateAgentName(id: agent.id, name: name)
        agentStore.updateAgentSoul(id: agent.id, soul: "You are a terse test agent. Follow instructions exactly.")
        agentStore.updateAgentDebugLog(id: agent.id, enabled: debug)
        for tool in AgentToolID.allCases {
            agentStore.setTool(tool, enabled: true, for: agent.id)
        }
        if let skill = skillCatalog.skills.first(where: { $0.name == "get_peripheral_battery_levels" }) {
            agentStore.setSkill(skill.name, enabled: true, for: agent.id)
        }
        return agentStore.agent(for: agent.id) ?? agent
    }

    private static func fileIdentity(_ url: URL) -> (size: Int, mtime: Int, sha256: String) {
        let path = url.path
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? -1
        let mtime = Int((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        let sha = sha256(of: path)
        return (size, mtime, sha)
    }

    private static func sha256(of path: String) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        proc.arguments = ["-a", "256", path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try? proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .split(separator: " ").first
            .map(String.init) ?? ""
    }
}
