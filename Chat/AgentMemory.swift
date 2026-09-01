import Foundation

struct AgentModelOutput {
    let visibleText: String
    let memoryEntries: [String]
}

enum AgentMemoryHarness {
    private static let memoryExpression = try! NSRegularExpression(
        pattern: #"(?:\[\[MEMORY\]\]|\[MEMORY\])(.*?)(?:\[\[/MEMORY\]\]|\[/MEMORY\])"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    static func instructionSection(memory: String) -> String {
        let trimmedMemory = memory.trimmingCharacters(in: .whitespacesAndNewlines)
        let memoryContent = trimmedMemory.isEmpty ? "(No stored memory.)" : trimmedMemory

        return """
        Persistent memory:
        --- BEGIN MEMORY ---
        \(memoryContent)
        --- END MEMORY ---

        Memory rules:
        - Treat the existing memory as read-only. Never rewrite, delete, or replace an existing entry.
        - You may append a new memory when something will be useful in future conversations.
        - To append memory, include each new entry inside [[MEMORY]] and [[/MEMORY]] markers.
        - Memory markers are control data and will not be shown as part of your reply.
        - Do not add transient details, repeated facts, or instructions to yourself as memory.
        """
    }

    static func parse(_ response: String) -> AgentModelOutput {
        let fullRange = NSRange(response.startIndex..<response.endIndex, in: response)
        let matches = memoryExpression.matches(in: response, range: fullRange)
        var entries: [String] = []

        for match in matches {
            guard match.numberOfRanges > 1,
                  let entryRange = Range(match.range(at: 1), in: response) else {
                continue
            }
            let entry = response[entryRange].trimmingCharacters(in: .whitespacesAndNewlines)
            if !entry.isEmpty {
                entries.append(entry)
            }
        }

        let visibleResponse = NSMutableString(string: response)
        for match in matches.reversed() {
            visibleResponse.replaceCharacters(in: match.range, with: "")
        }

        let visibleText = String(visibleResponse)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")

        return AgentModelOutput(visibleText: visibleText, memoryEntries: entries)
    }
}
