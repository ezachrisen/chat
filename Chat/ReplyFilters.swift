import Combine
import Foundation
import SwiftData

@Model
final class ReplyFilterSet: Identifiable {
    @Attribute(.unique) var modelIdentifier: String
    var patternsText: String
    var createdAt: Date

    init(
        modelIdentifier: String,
        patternsText: String = "",
        createdAt: Date = .now
    ) {
        self.modelIdentifier = modelIdentifier
        self.patternsText = patternsText
        self.createdAt = createdAt
    }
}

enum ReplySanitizer {
    static let appleFoundationDefaultPatternsText = """
    \\[MEMORY\\].*?\\[/MEMORY\\]
    \\[PASS\\]
    """

    static func process(_ response: String, patterns: [String]) -> (output: AgentModelOutput, isPass: Bool) {
        let parsed = AgentMemoryHarness.parse(response)
        let wasPass = ModelPrompts.isPassResponse(parsed.visibleText)
        var visible = apply(patterns, to: parsed.visibleText)
        visible = visible.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        visible = visible.trimmingCharacters(in: .whitespacesAndNewlines)
        let isPass = wasPass || ModelPrompts.isPassResponse(visible)
        if isPass || visible.isEmpty {
            visible = ""
        }
        return (
            AgentModelOutput(
                visibleText: visible,
                memoryEntries: parsed.memoryEntries
            ),
            isPass
        )
    }

    static func patternList(from text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            return trimmed
        }
    }

    static func apply(_ patterns: [String], to text: String) -> String {
        var result = text
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            ) else {
                continue
            }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = expression.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: ""
            )
        }
        return result
    }
}

@MainActor
final class ReplyFilterStore: ObservableObject {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        seedAppleFoundationDefaultsIfNeeded()
    }

    func patterns(for modelIdentifier: String) -> [String] {
        ReplySanitizer.patternList(from: patternsText(for: modelIdentifier))
    }

    func patternsText(for modelIdentifier: String) -> String {
        filterSet(for: modelIdentifier)?.patternsText ?? ""
    }

    func updatePatternsText(for modelIdentifier: String, text: String) {
        let set = filterSet(for: modelIdentifier) ?? {
            let created = ReplyFilterSet(modelIdentifier: modelIdentifier)
            modelContext.insert(created)
            return created
        }()
        set.patternsText = text
        saveChanges()
        objectWillChange.send()
    }

    func removeFilters(for modelIdentifier: String) {
        if let set = filterSet(for: modelIdentifier) {
            modelContext.delete(set)
            saveChanges()
        }
    }

    private func seedAppleFoundationDefaultsIfNeeded() {
        let identifier = ChatModelIdentifier.appleFoundation
        guard filterSet(for: identifier) == nil else { return }
        modelContext.insert(
            ReplyFilterSet(
                modelIdentifier: identifier,
                patternsText: ReplySanitizer.appleFoundationDefaultPatternsText
            )
        )
        saveChanges()
    }

    private func filterSet(for modelIdentifier: String) -> ReplyFilterSet? {
        let identifier = modelIdentifier
        var descriptor = FetchDescriptor<ReplyFilterSet>(
            predicate: #Predicate { $0.modelIdentifier == identifier }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private func saveChanges() {
        guard modelContext.hasChanges else { return }
        do {
            try modelContext.save()
        } catch {
            assertionFailure("Failed to save reply filters: \(error.localizedDescription)")
        }
    }
}
