import Foundation
import SwiftData

enum SessionStorageProbe {
    static let argument = "--session-storage-self-test"
    static let passTraceArgument = "--heartbeat-pass-storage-self-test"
    private static let generationTimeout: Duration = .seconds(180)

    static var isRequested: Bool {
        CommandLine.arguments.contains(argument)
            || CommandLine.arguments.contains(passTraceArgument)
    }

    static var usesInMemoryStore: Bool {
        CommandLine.arguments.contains(passTraceArgument)
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
        check(ModelPrompts.isPassResponse("[[[PASS]]]"), "extra-bracket PASS sentinel is recognized")
        check(!ModelPrompts.isPassResponse("Please pass this along"), "ordinary pass text is not a PASS sentinel")
        if usesInMemoryStore {
            await verifySyntheticPassStorageOnly(
                container: container,
                agentStore: agentStore,
                chatStore: chatStore,
                skillCatalog: skillCatalog,
                context: container.mainContext,
                check: check
            )
            if failures.isEmpty {
                writeLog("=== heartbeat PASS storage self-test: all checks passed ===")
                exit(0)
            }
            writeLog("=== heartbeat PASS storage self-test: \(failures.count) failure(s) ===")
            for failure in failures {
                writeLog(" - \(failure)")
            }
            exit(1)
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
    private static func verifySyntheticPassStorageOnly(
        container: ModelContainer,
        agentStore: AgentStore,
        chatStore: ChatStore,
        skillCatalog: SkillCatalog,
        context: ModelContext,
        check: (Bool, String) -> Void
    ) async {
        let defaults = UserDefaults.standard
        let previousContentUsed = defaults.object(forKey: "appleServicesContentUsed")
        defer {
            if let previousContentUsed {
                defaults.set(previousContentUsed, forKey: "appleServicesContentUsed")
            } else {
                defaults.removeObject(forKey: "appleServicesContentUsed")
            }
        }

        let debugAgent = makeProbeAgent(
            name: "PASS Probe Debug",
            debug: true,
            agentStore: agentStore,
            skillCatalog: skillCatalog
        )
        var remindersGrant = AppleServiceGrant()
        remindersGrant.enabled = true
        remindersGrant.allowsBackground = true
        debugAgent.setAppleServiceGrant(.reminders, grant: remindersGrant)
        check(debugAgent.isToolEnabled(.reminders), "PASS probe agent has Reminders enabled")
        check(
            debugAgent.appleServiceGrants[AppleServiceID.reminders.rawValue]?.enabled == true,
            "PASS probe agent has an enabled Apple service grant"
        )
        agentStore.updateAgentDebugLog(id: debugAgent.id, enabled: false)
        agentStore.updateAgentDebugLog(id: debugAgent.id, enabled: true)
        check(
            agentStore.agent(for: debugAgent.id)?.isDebugLogEnabled == true,
            "debug logging can be enabled while Apple Services are enabled"
        )
        let debugAgentID = debugAgent.id
        let persistedDebugAgent = try? ModelContext(container).fetch(
            FetchDescriptor<Agent>(predicate: #Predicate { $0.id == debugAgentID })
        ).first
        check(
            persistedDebugAgent?.isDebugLogEnabled == true,
            "Apple Services agent retains debug logging in a fresh store context"
        )
        await verifyAppleServiceTraceCapture(
            container: container,
            agentID: debugAgent.id,
            check: check
        )
        let collaborationTarget = makeProbeAgent(
            name: "PASS Probe Target",
            debug: false,
            agentStore: agentStore,
            skillCatalog: skillCatalog
        )
        chatStore.startChat(with: debugAgent)
        guard let chat = chatStore.chats.first(where: { $0.agentID == debugAgent.id }) else {
            check(false, "synthetic PASS probe chat exists")
            return
        }
        verifySyntheticPassTraces(
            container: container,
            agent: debugAgent,
            collaborationTarget: collaborationTarget,
            chatID: chat.id,
            agentStore: agentStore,
            context: context,
            check: check
        )
    }

    @MainActor
    private static func verifyAppleServiceTraceCapture(
        container: ModelContainer,
        agentID: UUID,
        check: (Bool, String) -> Void
    ) async {
        var grant = AppleServiceGrant()
        grant.enabled = true
        let context = AppleServiceContext(
            agentID: UUID(),
            origin: .interactive,
            grant: { _ in grant }
        )
        let fixtureResult = AppleServiceResult(
            records: [
                AppleServiceRecord(
                    id: "fixture-reminder",
                    title: "Fixture reminder title",
                    container: "fixture-list",
                    fields: ["notes": "fixture reminder details"]
                )
            ]
        )
        let runtime = AppleServiceRuntime(
            actionStore: AppleActionStore(
                url: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathComponent("actions.json")
            ),
            backend: { service, request, _, _ in
                guard service == .reminders, request.action == "search" else {
                    throw AppleServiceError.invalid("Unexpected trace probe request.")
                }
                if request.query == "fixture failure request" {
                    throw AppleServiceError.invalid("Fixture service failure.")
                }
                return fixtureResult
            }
        )
        let request = AppleServiceRequest(
            action: "search",
            query: "fixture reminder query",
            limit: 25
        )

        func arguments(query: String) -> AppleServiceTool.Arguments {
            AppleServiceTool.Arguments(
                action: "search",
                id: nil,
                container: nil,
                query: query,
                title: nil,
                body: nil,
                value: nil,
                due: nil,
                priority: nil,
                email: nil,
                phone: nil,
                familyName: nil,
                recurrence: nil,
                alarm: nil,
                attachmentID: nil,
                recipient: nil,
                sender: nil,
                revision: nil,
                actionID: nil,
                limit: 25,
                offset: nil
            )
        }

        func tool(recorder: ToolCallRecorder) -> AppleServiceTool {
            AppleServiceTool(
                service: .reminders,
                context: context,
                recorder: recorder,
                authorization: nil,
                runtime: runtime
            )
        }

        func persist(
            turnID: UUID,
            debugEnabled: Bool,
            invocations: [CapturedToolInvocation]
        ) {
            GenerationStore.recordTurn(
                draft: GenerationTurnDraft(
                    id: turnID,
                    kind: .direct,
                    chatID: UUID(),
                    userMessageID: nil,
                    assistantMessageID: nil,
                    agentID: agentID,
                    agentName: "Apple trace probe",
                    heartbeatID: nil,
                    heartbeatRunID: nil,
                    modelIdentifier: ChatModelIdentifier.appleFoundation,
                    backendRawValue: ChatBackend.appleFoundation.persistenceName,
                    startedAt: Date(timeIntervalSince1970: 300),
                    completedAt: Date(timeIntervalSince1970: 301),
                    status: .failed,
                    actionSummary: "Apple trace probe",
                    errorMessage: nil,
                    visibleReplyPreview: nil,
                    memoryEntryCount: 0,
                    debugCaptureEnabled: debugEnabled
                ),
                invocations: invocations,
                debug: nil,
                in: container.mainContext
            )
        }

        do {
            let debugRecorder = ToolCallRecorder(capturesFullContent: true)
            let output = try await tool(recorder: debugRecorder).call(
                arguments: arguments(query: "fixture reminder query")
            )
            do {
                _ = try await tool(recorder: debugRecorder).call(
                    arguments: arguments(query: "fixture failure request")
                )
                check(false, "Debug-on Foundation Apple service failure was thrown")
            } catch {
                check(
                    error.localizedDescription == "invalid_request: Fixture service failure.",
                    "Debug-on Foundation Apple service preserves the original failure"
                )
            }
            let debugSnapshot = debugRecorder.snapshot()
            let debugTrace = debugSnapshot.first
            let decodedRequest = debugTrace?.argumentsJSON.data(using: .utf8).flatMap {
                try? JSONDecoder().decode(AppleServiceRequest.self, from: $0)
            }
            check(decodedRequest == request, "Debug-on Apple service trace retains the exact request")
            check(debugTrace?.resultText == output, "Debug-on Apple service trace retains the exact bounded model result")
            check(debugTrace?.resultText.contains("fixture reminder details") == true, "Debug-on Apple service trace retains reminder content")
            check(
                debugSnapshot.last?.resultText == "invalid_request: Fixture service failure."
                    && debugSnapshot.last?.errorMessage == "invalid_request: Fixture service failure.",
                "Debug-on Apple service trace retains the original failure"
            )

            let compactRecorder = ToolCallRecorder()
            _ = try await tool(recorder: compactRecorder).call(
                arguments: arguments(query: "fixture reminder query")
            )
            do {
                _ = try await tool(recorder: compactRecorder).call(
                    arguments: arguments(query: "fixture failure request")
                )
                check(false, "Debug-off Foundation Apple service failure was thrown")
            } catch {
                check(
                    error.localizedDescription == "invalid_request: Fixture service failure.",
                    "Debug-off Foundation Apple service still returns the original failure to the model"
                )
            }
            let compactSnapshot = compactRecorder.snapshot()
            let compactTrace = compactSnapshot.first
            check(compactTrace?.argumentsJSON == AppleServiceDiagnosticTrace.redactedArgumentsJSON, "Debug-off Apple service trace redacts the request")
            check(compactTrace?.resultText == "ok; 1 records; service content omitted", "Debug-off Apple service trace redacts the result")
            check(
                compactSnapshot.last?.argumentsJSON == AppleServiceDiagnosticTrace.redactedArgumentsJSON
                    && compactSnapshot.last?.resultText == "unavailable: Service operation failed; content omitted.",
                "Debug-off Apple service trace redacts failures"
            )

            let debugTurnID = UUID()
            let compactTurnID = UUID()
            persist(
                turnID: debugTurnID,
                debugEnabled: true,
                invocations: debugSnapshot
            )
            persist(
                turnID: compactTurnID,
                debugEnabled: false,
                invocations: compactSnapshot
            )
            try container.mainContext.save()

            let readContext = ModelContext(container)
            let storedDebug = GenerationQuery.fetchToolCalls(
                forTurn: debugTurnID,
                in: readContext
            )
            let storedCompact = GenerationQuery.fetchToolCalls(
                forTurn: compactTurnID,
                in: readContext
            )
            check(storedDebug.count == 2, "Debug-on Foundation Apple service rows persist")
            check(
                storedDebug.first?.argumentsJSON == debugTrace?.argumentsJSON
                    && storedDebug.first?.resultText == output
                    && storedDebug.first?.resultText.contains("fixture reminder details") == true,
                "Debug-on persisted Apple service row contains the request and bounded result"
            )
            check(
                storedDebug.last?.resultText == "invalid_request: Fixture service failure."
                    && storedDebug.last?.succeeded == false,
                "Debug-on persisted Apple service failure contains diagnostics"
            )
            check(storedCompact.count == 2, "Debug-off Foundation Apple service rows persist")
            check(
                storedCompact.allSatisfy {
                    $0.argumentsJSON == AppleServiceDiagnosticTrace.redactedArgumentsJSON
                        && !$0.resultText.contains("fixture reminder")
                },
                "Debug-off persisted Apple service rows omit service content"
            )
            check(
                storedCompact.first?.resultText == "ok; 1 records; service content omitted"
                    && storedCompact.last?.resultText == "unavailable: Service operation failed; content omitted.",
                "Debug-off persisted Apple service success and failure stay redacted"
            )
        } catch {
            check(false, "Apple service trace capture probe completed: \(error.localizedDescription)")
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
                check(
                    inspectorTurn?.id == onTurn.id,
                    "Debug Info context menu can resolve the debug-on assistant bubble"
                )
            }
        }

        await verifyHeartbeat(
            agent: debugAgent,
            chatStore: chatStore,
            agentStore: agentStore,
            context: context,
            check: check
        )
        verifySyntheticPassTraces(
            container: container,
            agent: debugAgent,
            collaborationTarget: quietAgent,
            chatID: debugChat.id,
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
    private static func verifySyntheticPassTraces(
        container: ModelContainer,
        agent: Agent,
        collaborationTarget: Agent,
        chatID: UUID,
        agentStore: AgentStore,
        context: ModelContext,
        check: (Bool, String) -> Void
    ) {
        func tool(_ sequence: Int, _ name: String) -> CapturedToolInvocation {
            CapturedToolInvocation(
                sequence: sequence,
                roundIndex: sequence,
                toolName: name,
                skillName: "probe_skill",
                argumentsJSON: #"{"probe":"arguments"}"#,
                resultText: "probe-result-\(sequence)",
                succeeded: true,
                errorMessage: nil,
                startedAt: Date(timeIntervalSince1970: 100 + Double(sequence)),
                completedAt: Date(timeIntervalSince1970: 101 + Double(sequence))
            )
        }

        func report(
            runID: UUID,
            turnID: UUID,
            status: GenerationStatus,
            debugEnabled: Bool,
            tools: [CapturedToolInvocation],
            rawOutput: String,
            debugPrefix: String = "probe",
            completedAt: Date = Date(timeIntervalSince1970: 200),
            error: String? = nil,
            promptTokens: Int? = nil,
            completionTokens: Int? = nil
        ) -> HeartbeatExecutionReport {
            HeartbeatExecutionReport(
                agentName: agent.displayName,
                instruction: "Synthetic PASS probe",
                destination: "Default chat",
                startedAt: Date(timeIntervalSince1970: 100),
                completedAt: completedAt,
                modelInput: "",
                modelOutput: nil,
                actionSummary: status == .passed
                    ? "The model passed, so no chat message was posted."
                    : "Timed out after 5 minutes. No chat message was posted.",
                errorMessage: error,
                retryDelay: nil,
                runID: runID,
                turnID: turnID,
                chatID: chatID,
                debugCaptureEnabled: debugEnabled,
                generationStatus: status,
                assistantMessageID: nil,
                visibleReplyPreview: nil,
                memoryEntryCount: 0,
                modelIdentifier: agent.selectedModelIdentifier,
                backendRawValue: "probe",
                toolInvocations: tools,
                debug: debugEnabled
                    ? GenerationDebugPayloadDraft(
                        systemPrompt: "\(debugPrefix)-system",
                        conversationPrompt: "\(debugPrefix)-conversation",
                        rawModelOutput: rawOutput,
                        reasoningText: "\(debugPrefix)-reasoning",
                        intermediateAssistantJSON: GenerationJSON.encode(["\(debugPrefix)-intermediate"]),
                        appleTranscriptSummary: "\(debugPrefix)-transcript",
                        openAIMessagesJSON: GenerationJSON.encode(["phase": debugPrefix])
                    )
                    : nil,
                promptTokenCount: promptTokens,
                completionTokenCount: completionTokens
            )
        }

        func storedRun(_ id: UUID, in readContext: ModelContext) -> HeartbeatRun? {
            try? readContext.fetch(
                FetchDescriptor<HeartbeatRun>(predicate: #Predicate { $0.id == id })
            ).first
        }

        func storedTurn(_ id: UUID, in readContext: ModelContext) -> GenerationTurn? {
            GenerationQuery.fetchTurn(id: id, in: readContext)
        }

        let debugRunID = UUID()
        let debugTurnID = UUID()
        let debugHeartbeatID = UUID()
        let debugTools = [tool(0, "RootProbeTool")]
        let childLog = AgentInvocationDebugLog(
            assignment: "probe-assignment",
            systemPrompt: "child-system",
            conversationPrompt: "child-conversation",
            rawModelOutput: "child-raw-reply",
            visibleReply: "child-visible-reply",
            resultPassedToCaller: "child-result-passed-to-caller",
            reasoningTexts: ["child-reasoning"],
            intermediateAssistantTexts: ["child-intermediate"],
            appleTranscriptSummary: "child-transcript",
            openAIMessagesJSON: #"{"child":"messages"}"#,
            toolInvocations: [tool(0, "ChildProbeTool")],
            errorMessage: nil
        )
        let childRecord = AgentInvocationRecord(
            rootInvocationID: debugTurnID,
            callerAgentID: agent.id,
            targetAgentID: collaborationTarget.id,
            callerName: agent.displayName,
            targetName: collaborationTarget.displayName,
            mode: .consult,
            state: .succeeded,
            taskPreview: "probe-assignment",
            resultPreview: "child-visible-reply",
            toolTraceSummary: "ChildProbeTool succeeded",
            debugLogJSON: GenerationJSON.encode(childLog),
            logSuppressed: false,
            modelIdentifier: collaborationTarget.selectedModelIdentifier,
            backendRawValue: "probe",
            depth: 1,
            startedAt: Date(timeIntervalSince1970: 110),
            modelStartedAt: Date(timeIntervalSince1970: 111),
            completedAt: Date(timeIntervalSince1970: 112)
        )
        context.insert(childRecord)
        agentStore.recordHeartbeatCompletion(
            heartbeatID: debugHeartbeatID,
            agentID: agent.id,
            report: report(
                runID: debugRunID,
                turnID: debugTurnID,
                status: .passed,
                debugEnabled: true,
                tools: debugTools,
                rawOutput: "[[PASS]]"
            )
        )

        check(!context.hasChanges, "debug-on PASS was saved to the store")
        let debugReadContext = ModelContext(container)
        let debugRun = storedRun(debugRunID, in: debugReadContext)
        let debugTurn = storedTurn(debugTurnID, in: debugReadContext)
        let storedDebugTools = GenerationQuery.fetchToolCalls(forTurn: debugTurnID, in: debugReadContext)
        let debugPayload = GenerationQuery.fetchDebugPayload(forTurn: debugTurnID, in: debugReadContext)
        let childRows = GenerationQuery.fetchCollaborationInvocations(forTurn: debugTurnID, in: debugReadContext)
        var debugMarkers: [SuppressedAgentInvocationRoot] = []
        do {
            debugMarkers = try debugReadContext.fetch(
                FetchDescriptor<SuppressedAgentInvocationRoot>(
                    predicate: #Predicate { $0.rootInvocationID == debugTurnID }
                )
            )
        } catch {
            check(false, "debug-on PASS suppression markers were queryable")
        }
        let debugRuns = try? debugReadContext.fetch(
            FetchDescriptor<HeartbeatRun>(predicate: #Predicate { $0.id == debugRunID })
        )
        let debugTurns = try? debugReadContext.fetch(
            FetchDescriptor<GenerationTurn>(predicate: #Predicate { $0.id == debugTurnID })
        )
        check(debugRun?.generationTurnID == debugTurnID, "debug-on PASS run links to its generation turn")
        check(debugTurn?.kind == .heartbeat && debugTurn?.status == .passed, "debug-on PASS persists a passed heartbeat turn")
        check(debugRuns?.count == 1 && debugTurns?.count == 1, "debug-on PASS persists exactly one run and turn")
        check(debugTurn?.chatID == chatID, "debug-on PASS is filed in the destination chat history")
        check(debugTurn?.heartbeatID == debugHeartbeatID, "debug-on PASS turn links to its heartbeat")
        check(debugTurn?.heartbeatRunID == debugRunID, "debug-on PASS turn links back to its run")
        check((try? debugReadContext.fetch(GenerationQuery.turnsInChat(chatID)))?.contains(where: { $0.id == debugTurnID }) == true, "destination chat history contains the debug-on PASS turn")
        check(debugTurn?.assistantMessageID == nil, "debug-on PASS still posts no assistant message")
        check(debugTurn?.debugCaptureEnabled == true, "debug-on PASS snapshots debug capture")
        check(debugTurn?.toolCallCount == debugTools.count, "debug-on PASS records its root tool count")
        let storedRootTool = storedDebugTools.first
        check(storedRootTool?.sequence == 0 && storedRootTool?.roundIndex == 0, "debug-on PASS retains root tool ordering")
        check(storedRootTool?.toolName == "RootProbeTool" && storedRootTool?.skillName == "probe_skill", "debug-on PASS retains root tool identity")
        check(storedRootTool?.argumentsJSON == #"{"probe":"arguments"}"#, "debug-on PASS retains root tool arguments")
        check(storedRootTool?.resultText == "probe-result-0" && storedRootTool?.succeeded == true, "debug-on PASS retains root tool result")
        check(storedRootTool?.startedAt == Date(timeIntervalSince1970: 100) && storedRootTool?.completedAt == Date(timeIntervalSince1970: 101), "debug-on PASS retains root tool timing")
        check(debugPayload?.systemPrompt == "probe-system", "debug-on PASS retains its system prompt")
        check(debugPayload?.conversationPrompt == "probe-conversation", "debug-on PASS retains its conversation prompt")
        check(debugPayload?.rawModelOutput == "[[PASS]]", "debug-on PASS retains raw PASS output")
        check(debugPayload?.reasoningText == "probe-reasoning", "debug-on PASS retains reasoning")
        check(debugPayload?.intermediateAssistantJSON == GenerationJSON.encode(["probe-intermediate"]), "debug-on PASS retains intermediate output")
        check(debugPayload?.appleTranscriptSummary == "probe-transcript", "debug-on PASS retains Apple transcript data")
        check(debugPayload?.openAIMessagesJSON == GenerationJSON.encode(["phase": "probe"]), "debug-on PASS retains provider messages")
        check(childRows.count == 1 && childRows.first?.isLogSuppressed == false, "debug-on PASS retains its collaboration row")
        check(childRows.first?.debugLog?.assignment == "probe-assignment", "debug-on PASS retains delegated assignment")
        check(childRows.first?.debugLog?.systemPrompt == "child-system" && childRows.first?.debugLog?.conversationPrompt == "child-conversation", "debug-on PASS retains delegated prompts")
        check(childRows.first?.debugLog?.resultPassedToCaller == "child-result-passed-to-caller", "debug-on PASS retains data passed between agents")
        check(childRows.first?.debugLog?.rawModelOutput == "child-raw-reply", "debug-on PASS retains delegated raw reply")
        check(childRows.first?.debugLog?.visibleReply == "child-visible-reply", "debug-on PASS retains delegated visible reply")
        check(childRows.first?.debugLog?.reasoningTexts == ["child-reasoning"], "debug-on PASS retains delegated reasoning")
        check(childRows.first?.debugLog?.intermediateAssistantTexts == ["child-intermediate"], "debug-on PASS retains delegated intermediate output")
        check(childRows.first?.debugLog?.appleTranscriptSummary == "child-transcript", "debug-on PASS retains delegated Apple transcript data")
        check(childRows.first?.debugLog?.openAIMessagesJSON == #"{"child":"messages"}"#, "debug-on PASS retains delegated provider messages")
        check(childRows.first?.debugLog?.toolInvocations.first?.toolName == "ChildProbeTool", "debug-on PASS retains delegated tool calls")
        check(debugMarkers.isEmpty, "debug-on PASS creates no suppression marker")

        let quietRunID = UUID()
        let quietTurnID = UUID()
        let quietHeartbeatID = UUID()
        var compactTool = tool(0, "CompactProbeTool")
        compactTool.argumentsJSON = String(repeating: "a", count: 5_000)
        compactTool.resultText = String(repeating: "r", count: 9_000)
        agentStore.recordHeartbeatCompletion(
            heartbeatID: quietHeartbeatID,
            agentID: agent.id,
            report: report(
                runID: quietRunID,
                turnID: quietTurnID,
                status: .passed,
                debugEnabled: false,
                tools: [compactTool],
                rawOutput: "[[PASS]]"
            )
        )
        check(!context.hasChanges, "debug-off PASS was saved to the store")
        let quietReadContext = ModelContext(container)
        let quietTurn = storedTurn(quietTurnID, in: quietReadContext)
        check(storedRun(quietRunID, in: quietReadContext)?.generationTurnID == quietTurnID, "debug-off PASS still links a generation turn")
        check(quietTurn?.status == .passed && quietTurn?.debugCaptureEnabled == false, "debug-off PASS persists passed status without debug")
        let compactRows = GenerationQuery.fetchToolCalls(forTurn: quietTurnID, in: quietReadContext)
        check(compactRows.count == 1, "debug-off PASS retains compact tool details")
        check(compactRows.first?.toolName == "CompactProbeTool" && compactRows.first?.skillName == "probe_skill", "debug-off PASS retains compact tool identity")
        check(compactRows.first?.argumentsJSON.count == 4_096 && compactRows.first?.argumentsJSON == String(repeating: "a", count: 4_096), "debug-off PASS bounds tool arguments")
        check(compactRows.first?.resultText.count == 8_192 && compactRows.first?.resultText == String(repeating: "r", count: 8_192), "debug-off PASS bounds tool results")
        check(compactRows.first?.resultTruncated == true, "debug-off PASS marks compact tool truncation")
        do {
            let quietPayloads = try quietReadContext.fetch(GenerationQuery.debugPayload(forTurn: quietTurnID))
            check(quietPayloads.isEmpty, "debug-off PASS omits only the debug payload")
        } catch {
            check(false, "debug-off PASS payload absence was queryable")
        }

        let timeoutRunID = UUID()
        let timeoutTurnID = UUID()
        let timeoutHeartbeatID = UUID()
        let timeoutCompletedAt = Date(timeIntervalSince1970: 200)
        agentStore.recordHeartbeatCompletion(
            heartbeatID: timeoutHeartbeatID,
            agentID: agent.id,
            report: report(
                runID: timeoutRunID,
                turnID: timeoutTurnID,
                status: .timedOut,
                debugEnabled: true,
                tools: [tool(0, "BeforeTimeoutTool")],
                rawOutput: "",
                debugPrefix: "before",
                completedAt: timeoutCompletedAt,
                error: "Timed out after 5 minutes."
            )
        )
        let timeoutChild = AgentInvocationRecord(
            rootInvocationID: timeoutTurnID,
            callerAgentID: agent.id,
            targetAgentID: collaborationTarget.id,
            callerName: agent.displayName,
            targetName: collaborationTarget.displayName,
            mode: .consult,
            state: .succeeded,
            taskPreview: "timeout-child-assignment",
            resultPreview: "timeout-child-result",
            debugLogJSON: GenerationJSON.encode(childLog),
            logSuppressed: false,
            modelIdentifier: collaborationTarget.selectedModelIdentifier,
            backendRawValue: "probe",
            depth: 1,
            startedAt: Date(timeIntervalSince1970: 120),
            completedAt: Date(timeIntervalSince1970: 121)
        )
        context.insert(timeoutChild)
        do {
            try context.save()
        } catch {
            check(false, "timeout collaboration fixture was saved")
        }
        agentStore.refreshTimedOutHeartbeatTrace(
            report: report(
                runID: timeoutRunID,
                turnID: timeoutTurnID,
                status: .passed,
                debugEnabled: true,
                tools: [tool(0, "BeforeTimeoutTool"), tool(1, "AfterTimeoutTool")],
                rawOutput: "[[PASS]]",
                debugPrefix: "late",
                completedAt: Date(timeIntervalSince1970: 300),
                promptTokens: 17,
                completionTokens: 3
            )
        )
        check(!context.hasChanges, "late PASS enrichment was saved to the store")
        let timeoutReadContext = ModelContext(container)
        let timeoutRun = storedRun(timeoutRunID, in: timeoutReadContext)
        let timeoutTurn = storedTurn(timeoutTurnID, in: timeoutReadContext)
        let timeoutTools = GenerationQuery.fetchToolCalls(forTurn: timeoutTurnID, in: timeoutReadContext)
        let timeoutPayload = GenerationQuery.fetchDebugPayload(forTurn: timeoutTurnID, in: timeoutReadContext)
        let timeoutChildren = GenerationQuery.fetchCollaborationInvocations(forTurn: timeoutTurnID, in: timeoutReadContext)
        check(timeoutRun?.generationTurnID == timeoutTurnID, "late PASS keeps the timed-out run linked")
        check(timeoutTurn?.status == .timedOut, "late PASS does not change the timeout outcome")
        check(timeoutTurn?.completedAt == timeoutCompletedAt, "late PASS does not change the timeout completion time")
        check(timeoutTurn?.errorMessage == "Timed out after 5 minutes.", "late PASS does not clear the timeout error")
        check(timeoutTurn?.toolCallCount == 2, "late PASS refreshes the timeout tool count")
        check(timeoutTools.map(\.toolName) == ["BeforeTimeoutTool", "AfterTimeoutTool"], "late PASS replaces the timeout tool snapshot without duplicates")
        check(timeoutPayload?.rawModelOutput == "[[PASS]]", "late PASS enriches the timeout debug payload")
        check(timeoutPayload?.systemPrompt == "late-system" && timeoutPayload?.conversationPrompt == "late-conversation", "late PASS refreshes timeout prompts")
        check(timeoutPayload?.reasoningText == "late-reasoning", "late PASS refreshes timeout reasoning")
        check(timeoutPayload?.intermediateAssistantJSON == GenerationJSON.encode(["late-intermediate"]), "late PASS refreshes timeout intermediate output")
        check(timeoutPayload?.appleTranscriptSummary == "late-transcript", "late PASS refreshes timeout Apple transcript data")
        check(timeoutPayload?.openAIMessagesJSON == GenerationJSON.encode(["phase": "late"]), "late PASS refreshes timeout provider messages")
        check(timeoutChildren.count == 1 && timeoutChildren.first?.id == timeoutChild.id, "late PASS retains timeout collaboration rows")
        check(timeoutRun?.promptTokenCount == 17 && timeoutRun?.completionTokenCount == 3, "late PASS enriches timeout token usage")
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
