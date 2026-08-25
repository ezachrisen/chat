import Foundation
import SwiftData

enum ChatModelContainer {
    static func make() throws -> ModelContainer {
        let configuration = ModelConfiguration()
        do {
            return try make(configuration: configuration)
        } catch {
            try removeStore(at: configuration.url)
            return try make(configuration: configuration)
        }
    }

    private static func make(configuration: ModelConfiguration) throws -> ModelContainer {
        try ModelContainer(
            for: Agent.self,
            AgentHeartbeat.self,
            HeartbeatRun.self,
            LocalModel.self,
            TextToSpeechTool.self,
            StoredChat.self,
            StoredGroupChatParticipant.self,
            StoredChatMessage.self,
            configurations: configuration
        )
    }

    private static func removeStore(at url: URL) throws {
        let fileManager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let fileURL = URL(fileURLWithPath: url.path + suffix)
            guard fileManager.fileExists(atPath: fileURL.path) else { continue }
            try fileManager.removeItem(at: fileURL)
        }
    }
}
