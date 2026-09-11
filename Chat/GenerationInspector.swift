import ShadSwift
import SwiftData
import SwiftUI

struct GenerationInspectorButton: View {
    let turn: GenerationTurn

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ShadButton(
            icon: .custom("wrench.and.screwdriver"),
            variant: .ghost,
            size: .iconSM,
            shape: .pill,
            accessibilityLabel: "Inspect tools and debug log"
        ) {
            openWindow(id: "generation-debug", value: turn.id)
        }
        .help("Inspect tools and debug log")
    }
}

struct GenerationDebugWindow: View {
    @Query private var turns: [GenerationTurn]

    init(turnID: UUID) {
        _turns = Query(filter: #Predicate<GenerationTurn> { $0.id == turnID })
    }

    var body: some View {
        Group {
            if let turn = turns.first {
                GenerationTurnInspector(turn: turn)
                    .padding(20)
                    .navigationTitle("Debug — \(turn.agentName)")
            } else {
                ContentUnavailableView("Debug history unavailable", systemImage: "doc.text.magnifyingglass", description: Text("This generation may have been deleted."))
            }
        }
        .frame(minWidth: 560, minHeight: 400)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

nonisolated struct ToolInvocationDisplay: Identifiable, Sendable {
    let id: UUID
    let toolName: String
    let skillName: String?
    let argumentsJSON: String
    let resultText: String
    let resultTruncated: Bool
    let succeeded: Bool
    let sequence: Int
    let roundIndex: Int

    init(_ invocation: ToolInvocation) {
        id = invocation.id
        toolName = invocation.toolName
        skillName = invocation.skillName
        argumentsJSON = invocation.argumentsJSON
        resultText = invocation.resultText
        resultTruncated = invocation.resultTruncated
        succeeded = invocation.succeeded
        sequence = invocation.sequence
        roundIndex = invocation.roundIndex
    }
}

struct GenerationTurnInspector: View {
    let turn: GenerationTurn

    @Environment(\.shadTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.spacing.lg) {
                ShadItem(variant: .muted, size: .sm) {
                    ShadItemContent {
                        ShadItemTitle(turn.agentName)
                        ShadItemDescription(turn.actionSummary)
                        Text("\(turn.kind.rawValue) · \(turn.status.rawValue) · \(turn.toolCallCount) tool\(turn.toolCallCount == 1 ? "" : "s")")
                            .font(theme.font(theme.typography.xs))
                            .foregroundStyle(theme.colors.mutedForeground)
                    }
                }

                GenerationToolCallSection(
                    turnID: turn.id,
                    showsFullDetails: turn.debugCaptureEnabled,
                    showsEmptyState: true
                )

                AgentCollaborationDebugSection(rootInvocationID: turn.id)

                GenerationDebugLogSection(
                    turnID: turn.id,
                    debugCaptureEnabled: turn.debugCaptureEnabled
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct GenerationDebugLogSection: View {
    @Query private var turns: [GenerationTurn]
    @Query private var payloads: [GenerationDebugPayload]
    let debugCaptureEnabled: Bool

    init(turnID: UUID, debugCaptureEnabled: Bool) {
        let storedTurnID = turnID
        _turns = Query(
            filter: #Predicate<GenerationTurn> { $0.id == storedTurnID }
        )
        _payloads = Query(
            filter: #Predicate<GenerationDebugPayload> { $0.turnID == storedTurnID }
        )
        self.debugCaptureEnabled = debugCaptureEnabled
    }

    var body: some View {
        if turns.first?.isDebugContentRedacted == true {
            ShadItem(variant: .muted, size: .xs) {
                ShadItemDescription("Debug content was redacted because an involved agent was deleted.")
            }
        } else if let payload = payloads.first {
            GenerationDebugSections(payload: payload)
        } else if debugCaptureEnabled {
            ShadItem(variant: .muted, size: .xs) {
                ShadItemDescription("Debug log was on, but no model payload was stored.")
            }
        } else {
            ShadItem(variant: .muted, size: .xs) {
                ShadItemDescription("Debug log was off for this run.")
            }
        }
    }
}

struct GenerationToolCallSection: View {
    @Query private var storedInvocations: [ToolInvocation]
    let showsFullDetails: Bool
    let showsEmptyState: Bool

    init(turnID: UUID, showsFullDetails: Bool, showsEmptyState: Bool = false) {
        let storedTurnID = turnID
        _storedInvocations = Query(
            filter: #Predicate<ToolInvocation> { $0.turnID == storedTurnID },
            sort: [SortDescriptor(\.sequence)]
        )
        self.showsFullDetails = showsFullDetails
        self.showsEmptyState = showsEmptyState
    }

    var body: some View {
        let invocations = storedInvocations.map(ToolInvocationDisplay.init)
        if invocations.isEmpty {
            if showsEmptyState {
                ShadItem(variant: .muted, size: .xs) {
                    ShadItemDescription("No tools were called.")
                }
            }
        } else {
            GenerationToolCallList(
                invocations: invocations,
                showsFullDetails: showsFullDetails
            )
        }
    }
}

struct AgentCollaborationDebugSection: View {
    @Query private var storedInvocations: [AgentInvocationRecord]

    init(rootInvocationID: UUID) {
        let rootID = rootInvocationID
        _storedInvocations = Query(
            filter: #Predicate<AgentInvocationRecord> { $0.rootInvocationID == rootID },
            sort: [SortDescriptor(\.startedAt)]
        )
    }

    var body: some View {
        if !storedInvocations.isEmpty {
            AgentCollaborationDebugList(invocations: storedInvocations)
        }
    }
}

struct GenerationToolCallList: View {
    let invocations: [ToolInvocationDisplay]
    var showsFullDetails = false
    @Environment(\.shadTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.md) {
            Text("Tools")
                .font(theme.font(theme.typography.xs, theme.typography.semibold))
                .foregroundStyle(theme.colors.mutedForeground)

            ShadItemGroup(spacing: theme.spacing.md) {
                ForEach(invocations, id: \ToolInvocationDisplay.id) { invocation in
                    toolRow(invocation)
                }
            }
        }
    }

    @ViewBuilder
    private func toolRow(_ invocation: ToolInvocationDisplay) -> some View {
        ShadItem(variant: .muted, size: .sm) {
            VStack(alignment: .leading, spacing: theme.spacing.sm) {
                HStack {
                    ShadItemTitle(invocation.toolName)
                    ShadBadge("#\(invocation.sequence + 1) · round \(invocation.roundIndex + 1)", variant: .outline)
                    Spacer()
                    ShadBadge(
                        invocation.succeeded ? "Succeeded" : "Failed",
                        variant: .secondary,
                        color: invocation.succeeded ? .green : .red
                    )
                }

                if let skillName = invocation.skillName {
                    ShadItemDescription("Skill: \(skillName)")
                }

                if showsFullDetails, !invocation.argumentsJSON.isEmpty {
                    GenerationTextBlock(title: "Arguments", text: invocation.argumentsJSON)
                } else if !invocation.argumentsJSON.isEmpty {
                    Text(truncated(invocation.argumentsJSON, limit: 500))
                        .font(theme.monoFont(theme.typography.xs))
                        .textSelection(.enabled)
                        .foregroundStyle(theme.colors.mutedForeground)
                }

                if showsFullDetails {
                    GenerationTextBlock(title: "Result", text: invocation.resultText)
                } else {
                    Text(truncated(invocation.resultText, limit: 800))
                        .font(theme.monoFont(theme.typography.xs))
                        .textSelection(.enabled)
                }

                if invocation.resultTruncated {
                    ShadBadge("Result truncated", variant: .outline)
                }
            }
        }
    }

    private func truncated(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n…(truncated)"
    }
}

struct AgentCollaborationDebugList: View {
    let invocations: [AgentInvocationRecord]
    @Environment(\.shadTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.md) {
            Text("Agent collaboration")
                .font(theme.font(theme.typography.xs, theme.typography.semibold))
                .foregroundStyle(theme.colors.mutedForeground)

            ForEach(invocations) { invocation in
                ShadItem(variant: .muted, size: .sm) {
                    VStack(alignment: .leading, spacing: theme.spacing.md) {
                        HStack(spacing: theme.spacing.sm) {
                            ShadItemTitle("\(invocation.callerName) → \(invocation.targetName)")
                            ShadBadge(invocation.mode.displayName, variant: .outline)
                            Spacer()
                            ShadBadge(invocation.state.rawValue, variant: .secondary)
                        }

                        if let debugLog = invocation.debugLog {
                            GenerationTextBlock(title: "Assignment", text: debugLog.assignment)
                            GenerationTextBlock(
                                title: invocation.modelStartedAt == nil ? "System prompt prepared" : "System prompt sent",
                                text: debugLog.systemPrompt
                            )
                            GenerationTextBlock(
                                title: invocation.modelStartedAt == nil ? "Conversation prompt prepared" : "Conversation prompt sent",
                                text: debugLog.conversationPrompt
                            )

                            if let rawOutput = debugLog.rawModelOutput {
                                GenerationTextBlock(title: "Raw agent reply", text: rawOutput)
                            }
                            if let visibleReply = debugLog.visibleReply {
                                GenerationTextBlock(title: "Visible reply", text: visibleReply)
                            }
                            if let passedResult = debugLog.resultPassedToCaller {
                                GenerationTextBlock(title: "Caller received", text: passedResult)
                            }
                            if !debugLog.reasoningTexts.isEmpty {
                                GenerationTextBlock(
                                    title: "Reasoning",
                                    text: debugLog.reasoningTexts.joined(separator: "\n\n")
                                )
                            }
                            if !debugLog.intermediateAssistantTexts.isEmpty,
                               let intermediate = GenerationJSON.encode(debugLog.intermediateAssistantTexts) {
                                GenerationTextBlock(title: "Intermediate output", text: intermediate)
                            }
                            if let transcript = debugLog.appleTranscriptSummary {
                                let parts = AppleDebugTraceParts(transcript)
                                if let loop = parts.loopTrace {
                                    GenerationTextBlock(title: "Agent loop", text: loop)
                                }
                                GenerationTextBlock(title: "Apple transcript", text: parts.transcript)
                            }
                            if let messages = debugLog.openAIMessagesJSON {
                                GenerationTextBlock(title: "OpenAI messages", text: messages)
                            }
                            if !debugLog.toolInvocations.isEmpty,
                               let toolCalls = GenerationJSON.encode(debugLog.toolInvocations) {
                                GenerationTextBlock(title: "Agent tool calls", text: toolCalls)
                            }
                            if let errorMessage = debugLog.errorMessage ?? invocation.errorMessage {
                                GenerationTextBlock(title: "Error", text: errorMessage)
                            }
                        } else if let rawDebugLog = invocation.debugLogJSON {
                            GenerationTextBlock(title: "Agent trace", text: rawDebugLog)
                        } else if let errorMessage = invocation.errorMessage {
                            GenerationTextBlock(title: "Error", text: errorMessage)
                        }
                    }
                    .padding(.leading, CGFloat(max(0, invocation.depth - 1)) * theme.spacing.lg)
                }
            }
        }
    }
}

struct GenerationDebugSections: View {
    let payload: GenerationDebugPayload
    @Environment(\.shadTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.lg) {
            Text("Debug log")
                .font(theme.font(theme.typography.xs, theme.typography.semibold))
                .foregroundStyle(theme.colors.mutedForeground)

            GenerationTextBlock(title: "System prompt", text: payload.systemPrompt)
            GenerationTextBlock(title: "Conversation prompt", text: payload.conversationPrompt)
            if let reasoningText = payload.reasoningText, !reasoningText.isEmpty {
                GenerationTextBlock(title: "Reasoning", text: reasoningText)
            }
            if let intermediate = payload.intermediateAssistantJSON, !intermediate.isEmpty {
                GenerationTextBlock(title: "Intermediate output", text: intermediate)
            }
            GenerationTextBlock(title: "Raw model output", text: payload.rawModelOutput)
            if let summary = payload.appleTranscriptSummary, !summary.isEmpty {
                let parts = AppleDebugTraceParts(summary)
                if let loop = parts.loopTrace {
                    GenerationTextBlock(title: "Agent loop", text: loop)
                }
                GenerationTextBlock(title: "Apple transcript", text: parts.transcript)
            }
            if let messages = payload.openAIMessagesJSON, !messages.isEmpty {
                GenerationTextBlock(title: "OpenAI messages", text: messages)
            }
        }
    }
}

nonisolated struct AppleDebugTraceParts {
    let loopTrace: String?
    let transcript: String

    init(_ text: String) {
        let loopMarker = "--- AGENT LOOP TRACE ---\n"
        let transcriptMarker = "\n\n--- FOUNDATION TRANSCRIPT ---\n"
        guard text.hasPrefix(loopMarker), let range = text.range(of: transcriptMarker) else {
            loopTrace = nil
            transcript = text
            return
        }
        loopTrace = String(text[text.index(text.startIndex, offsetBy: loopMarker.count)..<range.lowerBound])
        transcript = String(text[range.upperBound...])
    }
}

struct GenerationTextBlock: View {
    let title: String
    let text: String
    @Environment(\.shadTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.sm) {
            Text(title)
                .font(theme.font(theme.typography.xs, theme.typography.semibold))
                .foregroundStyle(theme.colors.mutedForeground)

            ShadItem(variant: .muted, size: .sm) {
                Text(text.isEmpty ? "(empty)" : text)
                    .font(theme.monoFont(theme.typography.xs))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
