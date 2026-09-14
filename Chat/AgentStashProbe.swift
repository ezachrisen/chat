import Foundation
import FoundationModels
import AppKit
import ShadSwift
import SwiftData
import SwiftUI

/// Exercises the persisted stash and its actual Foundation/OpenAI tool wrappers.
@MainActor
enum AgentStashProbe {
    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw AgentStashError.invalid("Stash probe: \(message)") }
    }

    static func run(agent: Agent, container: ModelContainer) async throws {
        func parity<A: AgentStashOperation>(_ type: A.Type) throws {
            let data = try JSONEncoder().encode(A.generationSchema)
            let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let properties = object["properties"] as! [String: Any]
            try check(Set(properties.keys) == Set(A.properties.keys), "\(A.toolName) provider fields differ")
            try check(
                Set(object["required"] as? [String] ?? []) == Set(A.required),
                "\(A.toolName) provider required fields differ"
            )
        }
        try parity(ListAgentStashArguments.self)
        try parity(ReadAgentStashArguments.self)
        try parity(WriteAgentStashArguments.self)

        guard let runtime = AgentStashRuntime(agent: agent) else {
            throw AgentStashError.unavailable
        }
        let recorder = ToolCallRecorder(capturesFullContent: true)
        let entries = AgentStashTools.entries(
            runtime: runtime,
            recorder: recorder,
            authorization: nil,
            allowsWrite: true
        )
        try check(Set(entries.map { $0.tool.name }) == AgentStashTools.allNames, "writable tool visibility differs")

        let write = entries.first { $0.tool.name == "WriteAgentStash" }!
        let originalJSON = #"{"key":"Weather","value":"Sunny, 68 at 2pm\nBring sunglasses"}"#
        _ = try await write.execute(originalJSON)

        let readTool = AgentStashOperationTool<ReadAgentStashArguments>(
            runtime: runtime,
            recorder: recorder,
            authorization: nil
        )
        let readOutput = try await readTool.call(arguments: .init(key: "weather"))
        try check(readOutput.contains("Sunny, 68 at 2pm\\nBring sunglasses"), "multiline value did not round-trip")
        try check(readOutput.contains("updatedAt"), "read omitted freshness timestamp")

        _ = try await write.execute(#"{"key":"WEATHER","value":"Cloudy later"}"#)
        let stored = try AgentStashDatabase.entries(agentID: agent.id, in: container.mainContext)
        try check(stored.count == 1 && stored[0].key == "WEATHER", "case-insensitive upsert created a duplicate")

        try AgentStashDatabase.update(
            entry: stored[0],
            key: "Forecast",
            value: "Line one\nLine two",
            agentID: agent.id,
            in: container.mainContext
        )
        try check(try AgentStashDatabase.entry(key: "forecast", agentID: agent.id, in: container.mainContext).value.contains("\n"), "editor update lost multiline content")

        let list = entries.first { $0.tool.name == "ListAgentStash" }!
        let listOutput = try await list.execute("{}")
        try check(listOutput.contains("Forecast") && !listOutput.contains("Line one"), "list should return metadata, not values")
        try check(recorder.snapshot().contains { $0.argumentsJSON == originalJSON && $0.resultText.contains("updatedAt") }, "debug log omitted exact write arguments or receipt")

        let privateRecorder = ToolCallRecorder(capturesFullContent: false)
        let privateRead = AgentStashOperationTool<ReadAgentStashArguments>(
            runtime: runtime,
            recorder: privateRecorder,
            authorization: nil
        )
        _ = try await privateRead.call(arguments: .init(key: "Forecast"))
        try check(privateRecorder.snapshot().first?.argumentsJSON == #"{"content":"redacted"}"#, "debug-off arguments leaked")
        try check(privateRecorder.snapshot().first?.resultText == "ok; stash content omitted", "debug-off result leaked")

        var rejected = false
        do { _ = try await readTool.executeJSON(#"{"key":"Forecast","extra":true}"#) } catch { rejected = true }
        try check(rejected, "unknown fields were accepted")
        try check(
            ToolRecoveryPolicy.canRecover(
                AgentStashError.notFound("Missing"),
                toolName: "ReadAgentStash",
                argumentsJSON: #"{"key":"Missing"}"#
            ),
            "missing read cannot be corrected by the agent loop"
        )
        try check(
            !ToolRecoveryPolicy.canRecover(
                AgentStashError.invalid("bad value"),
                toolName: "WriteAgentStash",
                argumentsJSON: "{}"
            ),
            "write failure became automatically retryable"
        )

        agent.setTool(.agentStash, enabled: false)
        do {
            _ = try runtime.read(key: "Forecast")
            throw AgentStashError.invalid("revoked tool still read the stash")
        } catch AgentStashError.unavailable {
            // Expected.
        }
        agent.setTool(.agentStash, enabled: true)
        try container.mainContext.save()

        if CommandLine.arguments.contains("--agent-stash-ui-snapshot") {
            let view = NSHostingView(
                rootView: ScrollView {
                    AgentStashEditor(agent: agent)
                        .padding(24)
                }
                .modelContainer(container)
                .chatTheme()
                .frame(width: 760, height: 920)
                .background(Color(nsColor: .windowBackgroundColor))
            )
            let window = NSWindow(
                contentRect: NSRect(x: -10_000, y: -10_000, width: 760, height: 920),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = view
            window.orderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(300))
            view.frame = NSRect(x: 0, y: 0, width: 760, height: 920)
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw AgentStashError.invalid("Could not render the stash editor preview.")
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw AgentStashError.invalid("Could not encode the stash editor preview.")
            }
            try png.write(to: URL(fileURLWithPath: "/private/tmp/chat-agent-stash-editor.png"))
        }

        FileHandle.standardError.write(
            Data("PASS: Agent stash persistence, multiline editing, focused tools, timestamps, schema parity, revocation, recovery policy, and debug redaction.\n".utf8)
        )
    }
}
