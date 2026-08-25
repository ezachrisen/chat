import Combine
import Foundation
import SwiftData

@Model
final class TextToSpeechTool: Identifiable {
    @Attribute(.unique) var id: UUID
    var name: String
    var path: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        path: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.createdAt = createdAt
    }

    var displayName: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? "Untitled text-to-speech tool" : trimmedName
    }
}

struct TextToSpeechToolConfiguration: Sendable {
    let id: UUID
    let name: String
    let path: String

    var validationError: String? {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return "Enter the path to the CLI executable."
        }

        guard URL(fileURLWithPath: trimmedPath).path == trimmedPath,
              trimmedPath.hasPrefix("/") else {
            return "Enter an absolute path to the CLI executable."
        }

        return nil
    }
}

@MainActor
final class TextToSpeechToolStore: ObservableObject {
    @Published private(set) var tools: [TextToSpeechTool] = []

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        loadTools()
    }

    func addTool() {
        let tool = TextToSpeechTool(
            name: "Text-to-speech tool",
            path: ""
        )
        modelContext.insert(tool)
        saveChanges()
        loadTools()
    }

    func remove(_ tool: TextToSpeechTool) {
        modelContext.delete(tool)
        saveChanges()
        loadTools()
    }

    func updateName(for tool: TextToSpeechTool, to name: String) {
        tool.name = name
        saveChanges()
        objectWillChange.send()
    }

    func updatePath(for tool: TextToSpeechTool, to path: String) {
        tool.path = path
        saveChanges()
        objectWillChange.send()
    }

    func configuration(for tool: TextToSpeechTool) -> TextToSpeechToolConfiguration {
        TextToSpeechToolConfiguration(
            id: tool.id,
            name: tool.displayName,
            path: tool.path
        )
    }

    func playbackConfiguration(for agent: Agent) -> TextToSpeechPlaybackConfiguration? {
        guard let toolID = agent.textToSpeechToolID,
              let tool = tools.first(where: { $0.id == toolID }) else {
            return nil
        }

        let voiceName = (agent.textToSpeechVoiceName ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let voiceModel = (agent.textToSpeechVoiceModel ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !voiceName.isEmpty, !voiceModel.isEmpty else { return nil }

        return TextToSpeechPlaybackConfiguration(
            executablePath: tool.path,
            voiceName: voiceName,
            voiceModel: voiceModel
        )
    }

    private func loadTools() {
        let descriptor = FetchDescriptor<TextToSpeechTool>(
            sortBy: [SortDescriptor(\.createdAt)]
        )

        do {
            tools = try modelContext.fetch(descriptor)
        } catch {
            tools = []
        }
    }

    private func saveChanges() {
        guard modelContext.hasChanges else { return }

        do {
            try modelContext.save()
        } catch {
            assertionFailure("Failed to save text-to-speech tools: \(error.localizedDescription)")
        }
    }
}
