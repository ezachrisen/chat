import Foundation

enum ModelPrompts {
    static let defaultGroupInstructions = "Let the discussion develop naturally. Be concise and avoid repeating points already made."

    static func individualInstructions(soul: String) -> String {
        let trimmedSoul = soul.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedSoul.isEmpty ? """
        You are a concise assistant inside a simple chat app.
        Answer conversationally, and don't feel the need to ask a follow-up question unless it's natural.
        """ : trimmedSoul
    }

    static func resolvedGroupInstructions(_ stored: String) -> String {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultGroupInstructions : trimmed
    }

    static func currentDateTimeSection(now: Date = .now) -> String {
        let timeZone = TimeZone.current

        let readable = DateFormatter()
        readable.locale = Locale.current
        readable.timeZone = timeZone
        readable.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm:ss a zzz"

        let iso = ISO8601DateFormatter()
        iso.timeZone = timeZone
        iso.formatOptions = [.withInternetDateTime]

        return """
        Current date and time: \(readable.string(from: now)) (\(iso.string(from: now)), \(timeZone.identifier))
        """
    }

    static func agentSystemInstructions(
        agentName: String,
        soul: String,
        memory: String,
        skillsPrompt: String = ""
    ) -> String {
        """
        Your agent name is \(agentName).

        \(currentDateTimeSection())

        Individual agent instructions:
        \(individualInstructions(soul: soul))

        \(AgentMemoryHarness.instructionSection(memory: memory))
        \(skillsPrompt)
        """
    }

    static func toolsPrompt(enabledIDs: Set<String>) -> String {
        let enabled = AgentToolID.allCases.filter { enabledIDs.contains($0.rawValue) }
        guard !enabled.isEmpty else { return "" }

        let lines = enabled.map { tool in
            "- \(tool.rawValue): \(tool.toolDescription)"
        }.joined(separator: "\n")

        return """

        Available tools:
        \(lines)

        Call a tool by its exact name when the instruction requires it. You may call multiple tools in sequence. Describing a tool or putting its intended output in your reply does not invoke it.
        """
    }

    static func skillsPrompt(for skills: [DiscoveredSkill]) -> String {
        guard !skills.isEmpty else { return "" }

        let lines = skills.map { skill in
            let description = skill.description.isEmpty ? "No description provided." : skill.description
            return "- \(skill.name): \(description)"
        }.joined(separator: "\n")

        return """

        Available skills:
        \(lines)

        To use a skill, first read SKILL.md with ReadSkillFileTool using skill_name and file_name.
        Then run scripts with ExecuteSkillScript using skill_name, script_name, and optional arguments.
        file_name and script_name are relative to the skill folder and cannot go above it.
        """
    }

    static func groupSystemPrompt(
        agentName: String,
        soul: String,
        memory: String,
        groupInstructions: String,
        skillsPrompt: String = ""
    ) -> String {
        """
        You are \(agentName), a participant in an open group discussion.

        \(currentDateTimeSection())

        Individual agent instructions:
        \(individualInstructions(soul: soul))

        \(AgentMemoryHarness.instructionSection(memory: memory))
        \(skillsPrompt)

        Group chat system instructions:
        \(resolvedGroupInstructions(groupInstructions))

        Discussion behavior:
        - You see the complete conversation between the user and every agent in the group.
        - Messages labeled with another agent's name were written by that agent, not by you.
        - You may respond to the user or to another agent when it adds something natural to the discussion.
        - A direct @mention gives that comment extra emphasis, but it does not prevent other agents from replying.
        - Do not prefix your reply with your name; the interface adds it for you.
        - If you have nothing useful to add, reply with exactly [[PASS]].
        """
    }

    static func groupConversationPrompt(
        agentName: String,
        transcript: String,
        wasDirectlyMentioned: Bool
    ) -> String {
        let emphasis = wasDirectlyMentioned
            ? "The latest user message directly mentions you. Treat it with extra emphasis and usually respond."
            : "The latest user message does not directly mention you. You may still respond if it feels natural and useful."

        return """
        Here is the group conversation so far:

        \(transcript)

        \(emphasis)
        Continue the discussion as \(agentName), or return [[PASS]] if you would only repeat what has already been said.
        """
    }

    static func directConversationPrompt(agentName: String, transcript: String) -> String {
        """
        Here is the private conversation so far:

        \(transcript)

        Reply to the latest user message as \(agentName).
        """
    }

    static func withDigest(_ digest: String, recent: String) -> String {
        let trimmed = digest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return recent }
        let recentText = recent.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        Earlier in this conversation (summarized):
        \(trimmed)

        Recent messages:
        \(recentText.isEmpty ? "(none)" : recentText)
        """
    }

    static func digestSystemSection(_ digest: String) -> String {
        let trimmed = digest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return """

        Earlier in this conversation (summarized):
        \(trimmed)

        Recent messages follow as native chat turns.
        """
    }

    static func heartbeatSystemInstructions(
        agentName: String,
        soul: String,
        memory: String,
        isGroupChat: Bool,
        groupInstructions: String,
        skillsPrompt: String = ""
    ) -> String {
        let agentInstructions = agentSystemInstructions(
            agentName: agentName,
            soul: soul,
            memory: memory,
            skillsPrompt: skillsPrompt
        )

        guard isGroupChat else {
            return """
            \(agentInstructions)

            You are running a scheduled heartbeat for your private chat.
            This run is standalone. You do not have the chat transcript or prior messages.
            Follow the heartbeat instruction, including any tool calls it requires.
            Tool calls are not chat messages.
            If nothing should be posted to the chat, reply with exactly [[PASS]] after you finish any required tools.
            You may still append memory even when you pass.
            """
        }

        return """
        \(agentInstructions)

        Group chat system instructions:
        \(resolvedGroupInstructions(groupInstructions))

        You are running a scheduled heartbeat for this group discussion.
        This run is standalone. You do not have the chat transcript or prior messages.
        Follow the heartbeat instruction, including any tool calls it requires.
        Tool calls are not chat messages.
        Do not prefix your reply with your name; the interface adds it for you.
        If nothing should be posted to the chat, reply with exactly [[PASS]] after you finish any required tools.
        You may still append memory even when you pass.
        """
    }

    static func heartbeatConversationPrompt(
        agentName: String,
        instruction: String,
        lastCompletedAt: Date?,
        referenceDate: Date
    ) -> String {
        let lastCompletionDescription: String
        if let lastCompletedAt {
            lastCompletionDescription = "\(compactElapsedTime(from: lastCompletedAt, to: referenceDate)) ago"
        } else {
            lastCompletionDescription = "never"
        }

        return """
        This is a standalone scheduled heartbeat. You do not have the chat transcript.

        Time since this heartbeat last completed: \(lastCompletionDescription).

        Scheduled heartbeat instruction:
        \(instruction)

        Follow that instruction completely, including any tools it names.
        Then decide whether to post as \(agentName). Return [[PASS]] if no chat message should be posted.
        """
    }

    static func conversationTranscript(
        messages: [StoredChatMessage],
        isGroupChat: Bool,
        fallbackAgentName: String
    ) -> String {
        messages.map { message in
            let speaker = message.role == .user
                ? "User"
                : message.authorName ?? (isGroupChat ? "Agent" : fallbackAgentName)
            return "\(speaker): \(message.text)"
        }.joined(separator: "\n\n")
    }

    static func isPassResponse(_ response: String) -> Bool {
        ["[[pass]]", "[pass]", "pass"].contains(response.lowercased())
    }

    static func compactElapsedTime(from date: Date, to referenceDate: Date) -> String {
        let seconds = max(0, Int(referenceDate.timeIntervalSince(date)))
        switch seconds {
        case 0..<60:
            return "\(seconds)s"
        case 60..<3_600:
            return "\(seconds / 60)m"
        case 3_600..<86_400:
            return "\(seconds / 3_600)h"
        case 86_400..<604_800:
            return "\(seconds / 86_400)d"
        case 604_800..<2_592_000:
            return "\(seconds / 604_800)w"
        case 2_592_000..<31_536_000:
            return "\(seconds / 2_592_000)mo"
        default:
            return "\(seconds / 31_536_000)y"
        }
    }
}
