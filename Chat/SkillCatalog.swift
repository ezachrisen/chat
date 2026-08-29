import Combine
import Foundation

struct DiscoveredSkill: Identifiable, Sendable, Equatable {
    var id: String { name }
    let name: String
    let description: String
    let directoryName: String
    let directoryURL: URL
}

struct SkillRuntime: Sendable {
    let skills: [DiscoveredSkill]

    func skill(named name: String) -> DiscoveredSkill? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let match = skills.first(where: { $0.name == trimmed }) {
            return match
        }
        let lowered = trimmed.lowercased()
        return skills.first {
            $0.name.lowercased() == lowered || $0.directoryName.lowercased() == lowered
        }
    }
}

enum AgentToolID: String, CaseIterable, Identifiable {
    case readSkillFile = "ReadSkillFileTool"
    case executeSkillScript = "ExecuteSkillScript"
    case sendNotification = "SendNotification"
    case readCalendarEvents = "ReadCalendarEvents"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .readSkillFile:
            return "Read skill file"
        case .executeSkillScript:
            return "Execute skill script"
        case .sendNotification:
            return "Send notification"
        case .readCalendarEvents:
            return "Read calendar events"
        }
    }

    var description: String {
        switch self {
        case .readSkillFile:
            return "Read a file inside an enabled skill folder, such as SKILL.md."
        case .executeSkillScript:
            return "Run a script inside an enabled skill folder and return stdout and stderr."
        case .sendNotification:
            return "Show a macOS notification with a title and body."
        case .readCalendarEvents:
            return "Read events from the Mac calendars you allow for this agent."
        }
    }

    var toolDescription: String {
        switch self {
        case .readSkillFile:
            return "Read a file from an installed skill. file_name is relative to the skill folder (for example SKILL.md). Paths may not escape the skill folder."
        case .executeSkillScript:
            return "Execute a script from an installed skill. script_name is relative to the skill folder. Optional arguments is a whitespace-separated string. The working directory is the skill folder. Paths may not escape the skill folder."
        case .sendNotification:
            return "Send a macOS notification. You must call this tool to notify the user; writing the message in your chat reply does not send a notification. body is required. title is optional and defaults to the agent name."
        case .readCalendarEvents:
            return "Read calendar events between start and end. start and end are ISO 8601 dates or date-times (for example 2026-08-01 or 2026-08-01T09:00:00). Optional calendar_ids is a comma-separated list of calendar IDs, not names. Omit calendar_ids to query every calendar this agent is allowed to read. Timed start and end times in the result are already converted to the user's current time zone, which is named in the result; all-day events are calendar dates. When talking to the user, use those local times and name the time zone. Notes longer than 250 characters are truncated."
        }
    }
}

@MainActor
final class SkillCatalog: ObservableObject {
    @Published private(set) var skills: [DiscoveredSkill] = []
    @Published private(set) var enabledSkillIDs: Set<String> = []

    private let defaults: UserDefaults
    private static let enabledIDsKey = "enabledSkillIDs"

    var enabledSkills: [DiscoveredSkill] {
        skills.filter { enabledSkillIDs.contains($0.name) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabledSkillIDs = Self.loadEnabledIDs(from: defaults)
        reload()
    }

    var skillsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".chat", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
    }

    func reload() {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: skillsDirectory, withIntermediateDirectories: true)

        guard let contents = try? fileManager.contentsOfDirectory(
            at: skillsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            skills = []
            return
        }

        skills = contents.compactMap { url -> DiscoveredSkill? in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  let skillFileURL = Self.skillMarkdownURL(in: url),
                  let markdown = try? String(contentsOf: skillFileURL, encoding: .utf8) else {
                return nil
            }

            let frontMatter = SkillFrontMatter.parse(markdown)
            let directoryName = url.lastPathComponent
            let name = frontMatter.name?.nilIfEmpty ?? directoryName
            let description = frontMatter.description?
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            return DiscoveredSkill(
                name: name,
                description: description,
                directoryName: directoryName,
                directoryURL: url.resolvingSymlinksInPath().standardizedFileURL
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func isEnabled(_ skillID: String) -> Bool {
        enabledSkillIDs.contains(skillID)
    }

    func setEnabled(_ skillID: String, enabled: Bool) {
        if enabled {
            enabledSkillIDs.insert(skillID)
        } else {
            enabledSkillIDs.remove(skillID)
        }
        saveEnabledIDs()
    }

    func runtime(for agent: Agent?) -> SkillRuntime {
        let available = enabledSkills.filter { skill in
            agent?.isSkillEnabled(skill.name) ?? false
        }
        return SkillRuntime(skills: available)
    }

    func enabledToolIDs(for agent: Agent?) -> Set<String> {
        Set(AgentToolID.allCases.filter { agent?.isToolEnabled($0) ?? false }.map(\.rawValue))
    }

    private func saveEnabledIDs() {
        let sorted = enabledSkillIDs.sorted()
        defaults.set(sorted, forKey: Self.enabledIDsKey)
    }

    private static func loadEnabledIDs(from defaults: UserDefaults) -> Set<String> {
        Set(defaults.stringArray(forKey: enabledIDsKey) ?? [])
    }

    private static func skillMarkdownURL(in directory: URL) -> URL? {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        return files.first { $0.lastPathComponent.lowercased() == "skill.md" }
    }
}

enum SkillFrontMatter {
    static func parse(_ markdown: String) -> (name: String?, description: String?) {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---") else {
            return (nil, nil)
        }

        let rest = normalized.dropFirst(3).drop(while: { $0 == "\n" || $0 == "\r" })
        guard let endRange = rest.range(of: "\n---") else {
            return (nil, nil)
        }

        let block = String(rest[..<endRange.lowerBound])
        var values: [String: String] = [:]
        var pendingKey: String?
        var pendingLines: [String] = []

        func flushPending() {
            guard let key = pendingKey else { return }
            values[key] = pendingLines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            pendingKey = nil
            pendingLines = []
        }

        for rawLine in block.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if let key = pendingKey {
                if line.hasPrefix("  ") || line.hasPrefix("\t") || line.trimmingCharacters(in: .whitespaces).isEmpty {
                    pendingLines.append(
                        line.trimmingCharacters(in: .init(charactersIn: " \t"))
                    )
                    continue
                } else {
                    flushPending()
                }
            }

            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }

            if value == ">" || value == "|" || value == ">-" || value == "|-" {
                pendingKey = key
                pendingLines = []
            } else {
                values[key] = unquote(value)
            }
        }
        flushPending()

        return (values["name"].flatMap(\.nilIfEmpty), values["description"])
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}

private extension String {
    var nilIfEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
