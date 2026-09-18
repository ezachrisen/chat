import Foundation
import FoundationModels
import SwiftData
import SwiftUI
import AppKit

/// Runs without accounts, service permissions, network, or the user's persistent chat store.
@MainActor
enum AppleServicesProbe {
    static var isRequested: Bool { CommandLine.arguments.contains("--apple-services-self-test") || CommandLine.arguments.contains("--apple-services-ui-snapshot") || CommandLine.arguments.contains("--reminders-model-self-test") || CommandLine.arguments.contains("--tool-recovery-self-test") || CommandLine.arguments.contains("--heartbeat-spiral-self-test") || CommandLine.arguments.contains("--conversation-transcript-model-self-test") || CommandLine.arguments.contains("--agent-stash-self-test") || CommandLine.arguments.contains("--agent-stash-ui-snapshot") || CommandLine.arguments.contains("--agent-soul-tool-self-test") }
    static func run(container: ModelContainer) {
        do {
            func check(_ value: Bool, _ message: String = "Self-test invariant failed") throws {
                guard value else { throw AppleServiceError.invalid(message) }
            }
            let mentionContainer = try ChatModelContainer.make(
                configuration: ModelConfiguration(isStoredInMemoryOnly: true)
            )
            let legacyDefault = Agent(
                name: "Jo",
                soul: "",
                mentionHandle: "Default"
            )
            mentionContainer.mainContext.insert(legacyDefault)
            try mentionContainer.mainContext.save()
            let mentionStore = AgentStore(modelContext: mentionContainer.mainContext)
            try check(
                mentionStore.defaultAgent?.mention == "@Jo",
                "Renamed default agent retained the @Default placeholder"
            )
            mentionStore.updateAgentName(id: legacyDefault.id, name: "Joseph")
            mentionStore.finalizeAgentMentionHandle(id: legacyDefault.id)
            try check(
                mentionStore.defaultAgent?.mention == "@Jo",
                "Migrated mention handle did not remain stable"
            )
            let context = container.mainContext
            let agent = Agent(name: "Service test", soul: "")
            context.insert(agent)
            try check(agent.appleServiceGrants.isEmpty, "New/migrated agents must default deny")
            let splitTools = Set(AgentToolID.appleServiceTools.map(\.rawValue))
            let fromLegacy = AgentToolID.migratingLegacyAppleServices(["AppleServices"])
            try check(splitTools.isSubset(of: fromLegacy) && !fromLegacy.contains("AppleServices"), "Legacy Apple Services must enable every split tool")
            let afterFirstSplit = AgentToolID.migratingLegacyAppleServices(["AppleServices", "AppleServicesSplit.v1", "Reminders"])
            try check(afterFirstSplit.intersection(splitTools) == ["Reminders", "Contacts", "Phone"], "Second split must not re-enable tools turned off after the first")
            try check(AgentToolID.migratingLegacyAppleServices([]).isDisjoint(with: splitTools), "Split must not enable tools that were off")
            let migratedOnce = AgentToolID.migratingLegacyAppleServices(["AppleServices"]).subtracting(["Notes"])
            try check(AgentToolID.migratingLegacyAppleServices(migratedOnce) == migratedOnce, "Split migration must run once")
            agent.setTool(.readCalendarEvents, enabled: true)
            agent.setCalendarAccessAll(false, selecting: ["fixture-calendar"])
            for tool in AgentToolID.appleServiceTools { agent.setTool(tool, enabled: true) }
            agent.setTool(.agentStash, enabled: true)
            var grants: [String: AppleServiceGrant] = [:]
            for service in AppleServiceID.allCases {
                var grant = AppleServiceGrant(); grant.enabled = true
                grants[service.rawValue] = grant
            }
            agent.appleServiceGrantsJSON = String(decoding: try JSONEncoder().encode(grants), as: UTF8.self)
            agent.debugLogEnabled = true
            try context.save()
            let fetched = try context.fetch(FetchDescriptor<Agent>()).first { $0.id == agent.id }!
            try check(fetched.appleServiceGrants.count == 6)
            try check(fetched.isDebugLogEnabled, "Apple Services must not disable an agent's Debug log")
            try check(!fetched.allowsAllCalendars && fetched.allowedCalendarIDs == ["fixture-calendar"])
            let catalog = SkillCatalog(defaults: UserDefaults(suiteName: "ChatAppleServiceProbe")!)
            let probeAgentStore = AgentStore(modelContext: context)
            let tools = AgentToolBox.make(agent: fetched, catalog: catalog)
            let expected = Set(AppleServiceID.allCases.filter { $0 != .reminders }.map(\.toolName) + [AgentToolID.readCalendarEvents.rawValue])
                .union(ReminderTools.readNames)
                .union(AgentStashTools.allNames)
            try check(Set(tools.foundationModelTools.map(\.name)) == expected)
            try check(Set(tools.openAITools.map { $0.function.name }) == expected)
            try runConversationContextProbe(
                foundationTools: tools.foundationModelTools,
                check: check
            )
            let consultationTools = AgentToolBox.make(
                agent: fetched,
                catalog: catalog,
                allowedToolIDs: [AgentToolID.agentStash.rawValue],
                serviceOrigin: .consultation
            )
            try check(
                Set(consultationTools.foundationModelTools.map(\.name)) == AgentStashTools.readNames,
                "Consultations must not expose stash writes"
            )
            let schemaData = try JSONEncoder().encode(AppleServiceTool.Arguments.generationSchema)
            let schema = try JSONSerialization.jsonObject(with: schemaData) as! [String: Any]
            let properties = schema["properties"] as? [String: Any]
            guard let properties else { throw AppleServiceError.invalid("Foundation Models schema shape changed: \(String(decoding: schemaData, as: UTF8.self))") }
            for service in AppleServiceID.allCases where service != .reminders {
                let jsonSchema = AppleServiceTool.schema(service).function.parameters
                try check(Set(jsonSchema.properties.keys) == Set(properties.keys), "Provider parameter mismatch")
                try check(jsonSchema.required == ["action"])
            }
            if CommandLine.arguments.contains("--apple-services-ui-snapshot") {
                let view = NSHostingView(rootView: AppleServicesPreferencesView(navigation: PreferencesNavigation()).frame(width: 900, height: 1000).background(Color(nsColor: .windowBackgroundColor)))
                let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 900, height: 1000), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: .aqua)
                window.contentView = view
                window.orderFront(nil)
                defer { window.close() }
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                view.frame = NSRect(x: 0, y: 0, width: 900, height: 1000)
                view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw AppleServiceError.unavailable("Cannot render settings preview.") }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw AppleServiceError.unavailable("Cannot encode preview.") }
                try png.write(to: URL(fileURLWithPath: "/private/tmp/chat-apple-services-settings.png"))
            }
            Task {
                do {
                    try await ReminderToolsProbe.run(testModel: CommandLine.arguments.contains("--reminders-model-self-test"))
                    try await ToolRecoveryProbe.run(
                        testModel: CommandLine.arguments.contains("--tool-recovery-self-test"),
                        testHeartbeatSpiral: CommandLine.arguments.contains("--heartbeat-spiral-self-test")
                    )
                    if CommandLine.arguments.contains("--conversation-transcript-model-self-test") {
                        try await runConversationModelProbe()
                    }
                    if CommandLine.arguments.contains("--agent-soul-tool-self-test") {
                        try await AgentSoulToolProbe.run(
                            agentID: fetched.id,
                            agentStore: probeAgentStore,
                            catalog: catalog
                        )
                    }
                    try await AgentStashProbe.run(agent: fetched, container: container)
                    FileHandle.standardError.write(Data("PASS: SwiftData grants, Calendar preservation, service tools, provider schema parity, focused Reminders tools.\n".utf8))
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("FAIL: \(error.localizedDescription)\n".utf8))
                    exit(1)
                }
            }
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func runConversationContextProbe(
        foundationTools: [any Tool],
        check: (Bool, String) throws -> Void
    ) throws {
        let greeting = ChatMessage(role: .assistant, text: "Hello")
        let earlierUser = ChatMessage(role: .user, text: "My project is Atlas.")
        let earlierAssistant = ChatMessage(role: .assistant, text: "Understood.")
        let latestUser = ChatMessage(role: .user, text: "What is my project called?")
        let conversation = ModelConversationContext(
            systemPrompt: "SYSTEM RULES",
            digest: "The user prefers concise answers.",
            messages: [greeting, earlierUser, earlierAssistant, latestUser],
            labeledPrompt: "legacy fallback"
        )

        try check(
            conversation.messagesIncludingDigest.map(\.role) == [.user, .assistant, .user, .assistant, .user],
            "OpenAI conversation roles were flattened or reordered"
        )
        try check(
            conversation.messagesIncludingDigest.first?.text.contains("summarized") == true,
            "OpenAI conversation omitted the compacted-history message"
        )

        guard let seed = ModelClient.appleConversationSeed(
            conversation: conversation,
            tools: foundationTools
        ) else {
            throw AppleServiceError.invalid("Apple conversation seed was not created")
        }
        try check(seed.prompt == latestUser.text, "Apple seed duplicated or rewrote the latest user prompt")

        var kinds: [String] = []
        var transcriptText = ""
        var toolNames: Set<String> = []
        for entry in seed.transcript {
            switch entry {
            case .instructions(let instructions):
                kinds.append("instructions")
                transcriptText += text(from: instructions.segments)
                toolNames.formUnion(instructions.toolDefinitions.map(\.name))
            case .prompt(let prompt):
                kinds.append("prompt")
                transcriptText += text(from: prompt.segments)
            case .response(let response):
                kinds.append("response")
                transcriptText += text(from: response.segments)
            default:
                kinds.append("other")
            }
        }
        try check(kinds == ["instructions", "prompt", "response"], "Apple transcript roles were malformed")
        try check(transcriptText.contains("SYSTEM RULES"), "Apple transcript omitted system instructions")
        try check(transcriptText.contains(ToolExecutionLoop.instructions), "Apple transcript omitted tool-loop instructions")
        try check(transcriptText.contains("The user prefers concise answers."), "Apple transcript omitted compacted history")
        try check(transcriptText.contains(earlierUser.text) && transcriptText.contains(earlierAssistant.text), "Apple transcript omitted recent turns")
        try check(!transcriptText.contains(greeting.text), "Apple transcript retained an invalid leading assistant greeting")
        try check(!transcriptText.contains(latestUser.text), "Apple transcript duplicated the current user prompt")
        try check(toolNames == Set(foundationTools.map(\.name)), "Apple transcript tool definitions diverged from callable tools")

        let digestOnlyConversation = ModelConversationContext(
            systemPrompt: "SYSTEM RULES",
            digest: "The user's project is Atlas.",
            messages: [greeting, latestUser],
            labeledPrompt: "legacy fallback"
        )
        guard let digestOnlySeed = ModelClient.appleConversationSeed(
            conversation: digestOnlyConversation,
            tools: []
        ) else {
            throw AppleServiceError.invalid("Digest-only Apple conversation seed was not created")
        }
        try check(
            digestOnlySeed.prompt.contains("The user's project is Atlas.")
                && digestOnlySeed.prompt.contains(latestUser.text),
            "Apple seed lost digest context when no alternating history remained"
        )
        try check(Array(digestOnlySeed.transcript).count == 1, "Apple seed retained a leading assistant greeting")
    }

    private static func text(from segments: [Transcript.Segment]) -> String {
        segments.compactMap { segment in
            guard case .text(let text) = segment else { return nil }
            return text.content
        }
        .joined()
    }

    private static func runConversationModelProbe() async throws {
        guard case .available = SystemLanguageModel.default.availability else {
            throw AppleServiceError.unavailable("Foundation Model unavailable; conversation transcript model test did not run.")
        }
        let conversation = ModelConversationContext(
            systemPrompt: "Answer the user's latest question using the supplied conversation history. Be concise.",
            digest: "",
            messages: [
                ChatMessage(role: .user, text: "The verification code is ALBATROSS. Remember it for my next message."),
                ChatMessage(role: .assistant, text: "I will remember it."),
                ChatMessage(role: .user, text: "What is the verification code? Reply with only the code.")
            ],
            labeledPrompt: "legacy fallback must not be used"
        )
        let result = try await ModelClient.complete(
            using: .appleFoundation,
            conversation: conversation,
            captureDebug: true,
            missingLocalModelMessage: "Foundation Model unavailable."
        )
        guard result.finalText.localizedCaseInsensitiveContains("ALBATROSS") else {
            throw AppleServiceError.invalid("Foundation Model did not use native transcript history: \(result.finalText)")
        }
        let debug = result.debug?.appleTranscriptSummary ?? ""
        guard debug.contains("The verification code is ALBATROSS")
                && debug.contains("I will remember it.")
                && debug.contains("What is the verification code?") else {
            throw AppleServiceError.invalid("Conversation debug omitted native transcript turns")
        }
        FileHandle.standardError.write(Data("PASS: Foundation Model answered from native transcript history and debug captured every turn.\n".utf8))
    }
}
