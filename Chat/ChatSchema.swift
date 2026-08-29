import Foundation
import os
import SwiftData

enum ChatModelContainer {
    private static let logger = Logger(subsystem: "Chat", category: "Persistence")

    static func defaultStoreURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("com.zachrisen.chat", isDirectory: true)
            .appendingPathComponent("default.store")
    }

    static func make() throws -> ModelContainer {
        let configuration = resolvedConfiguration()
        logger.info("Opening SwiftData store at \(configuration.url.path, privacy: .public)")
        do {
            return try make(configuration: configuration)
        } catch {
            logger.error("Failed to create ModelContainer: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    static func resolvedConfiguration() -> ModelConfiguration {
        let raw = ProcessInfo.processInfo.environment["CHAT_STORE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let url: URL
        if raw.isEmpty {
            url = defaultStoreURL()
        } else {
            url = URL(fileURLWithPath: raw)
        }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return ModelConfiguration(url: url)
    }

    static func make(configuration: ModelConfiguration) throws -> ModelContainer {
        try ModelContainer(
            for: Agent.self,
            AgentHeartbeat.self,
            HeartbeatRun.self,
            LocalModel.self,
            ReplyFilterSet.self,
            TextToSpeechTool.self,
            StoredChat.self,
            StoredGroupChatParticipant.self,
            StoredChatMessage.self,
            GenerationTurn.self,
            ToolInvocation.self,
            GenerationDebugPayload.self,
            configurations: configuration
        )
    }
}
