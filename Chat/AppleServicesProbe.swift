import Foundation
import FoundationModels
import SwiftData
import SwiftUI
import AppKit

/// Runs without accounts, service permissions, network, or the user's persistent chat store.
@MainActor
enum AppleServicesProbe {
    static var isRequested: Bool { CommandLine.arguments.contains("--apple-services-self-test") || CommandLine.arguments.contains("--apple-services-ui-snapshot") || CommandLine.arguments.contains("--reminders-model-self-test") || CommandLine.arguments.contains("--tool-recovery-self-test") || CommandLine.arguments.contains("--agent-stash-self-test") || CommandLine.arguments.contains("--agent-stash-ui-snapshot") }
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
            agent.setTool(.readCalendarEvents, enabled: true)
            agent.setCalendarAccessAll(false, selecting: ["fixture-calendar"])
            agent.setTool(.appleServices, enabled: true)
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
            let tools = AgentToolBox.make(agent: fetched, catalog: catalog)
            let expected = Set(AppleServiceID.allCases.filter { $0 != .reminders }.map(\.toolName) + [AgentToolID.readCalendarEvents.rawValue])
                .union(ReminderTools.readNames)
                .union(AgentStashTools.allNames)
            try check(Set(tools.foundationModelTools.map(\.name)) == expected)
            try check(Set(tools.openAITools.map { $0.function.name }) == expected)
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
                let view = NSHostingView(rootView: AppleServicesPreferencesView().frame(width: 900, height: 1000).background(Color(nsColor: .windowBackgroundColor)))
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
                    try await ToolRecoveryProbe.run(testModel: CommandLine.arguments.contains("--tool-recovery-self-test"))
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
}
