import ShadSwift
import SwiftData
import SwiftUI

struct GenerationInspectorButton: View {
    let turn: GenerationTurn

    @Environment(\.modelContext) private var modelContext
    @State private var isPresented = false

    var body: some View {
        ShadButton(
            icon: .custom("wrench.and.screwdriver"),
            variant: .ghost,
            size: .iconSM,
            shape: .pill,
            accessibilityLabel: "Inspect tools and debug log"
        ) {
            isPresented.toggle()
        }
        .help("Inspect tools and debug log")
        .shadPopover(
            isPresented: $isPresented,
            configuration: ShadPopoverConfiguration(
                alignment: .trailingBottom,
                maxHeight: 460,
                becomesKey: true
            )
        ) {
            ShadPopoverSurface(padding: 16) {
                GenerationTurnInspector(turn: turn)
                    .frame(minWidth: 420, idealWidth: 460, minHeight: 280, idealHeight: 420)
                    .environment(\.modelContext, modelContext)
            }
        }
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

    init(_ invocation: ToolInvocation) {
        id = invocation.id
        toolName = invocation.toolName
        skillName = invocation.skillName
        argumentsJSON = invocation.argumentsJSON
        resultText = invocation.resultText
        resultTruncated = invocation.resultTruncated
        succeeded = invocation.succeeded
    }
}

struct GenerationTurnInspector: View {
    let turn: GenerationTurn

    @Environment(\.shadTheme) private var theme
    @Query private var suppressionMarkers: [SuppressedAgentInvocationRoot]

    init(turn: GenerationTurn) {
        self.turn = turn
        let turnID = turn.id
        _suppressionMarkers = Query(
            filter: #Predicate<SuppressedAgentInvocationRoot> {
                $0.rootInvocationID == turnID
            }
        )
    }

    var body: some View {
        if !suppressionMarkers.isEmpty {
            ShadItem(variant: .muted, size: .sm) {
                ShadItemDescription("The model returned PASS. No detailed log was stored.")
            }
        } else {
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
}

struct GenerationDebugLogSection: View {
    @Query private var turns: [GenerationTurn]
    @Query private var payloads: [GenerationDebugPayload]
    @Query private var suppressionMarkers: [SuppressedAgentInvocationRoot]
    let debugCaptureEnabled: Bool

    init(turnID: UUID, debugCaptureEnabled: Bool) {
        let storedTurnID = turnID
        _turns = Query(
            filter: #Predicate<GenerationTurn> { $0.id == storedTurnID }
        )
        _payloads = Query(
            filter: #Predicate<GenerationDebugPayload> { $0.turnID == storedTurnID }
        )
        _suppressionMarkers = Query(
            filter: #Predicate<SuppressedAgentInvocationRoot> {
                $0.rootInvocationID == storedTurnID
            }
        )
        self.debugCaptureEnabled = debugCaptureEnabled
    }

    var body: some View {
        if !suppressionMarkers.isEmpty {
            ShadItem(variant: .muted, size: .xs) {
                ShadItemDescription("The model returned PASS. No detailed log was stored.")
            }
        } else if turns.first?.isDebugContentRedacted == true {
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
    @Query private var suppressionMarkers: [SuppressedAgentInvocationRoot]
    let showsFullDetails: Bool
    let showsEmptyState: Bool

    init(turnID: UUID, showsFullDetails: Bool, showsEmptyState: Bool = false) {
        let storedTurnID = turnID
        _storedInvocations = Query(
            filter: #Predicate<ToolInvocation> { $0.turnID == storedTurnID },
            sort: [SortDescriptor(\.sequence)]
        )
        _suppressionMarkers = Query(
            filter: #Predicate<SuppressedAgentInvocationRoot> {
                $0.rootInvocationID == storedTurnID
            }
        )
        self.showsFullDetails = showsFullDetails
        self.showsEmptyState = showsEmptyState
    }

    var body: some View {
        let invocations = storedInvocations.map(ToolInvocationDisplay.init)
        if !suppressionMarkers.isEmpty {
            if showsEmptyState {
                ShadItem(variant: .muted, size: .xs) {
                    ShadItemDescription("The model returned PASS. No detailed log was stored.")
                }
            }
        } else if invocations.isEmpty {
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
    @Query private var suppressionMarkers: [SuppressedAgentInvocationRoot]

    init(rootInvocationID: UUID) {
        let rootID = rootInvocationID
        _storedInvocations = Query(
            filter: #Predicate<AgentInvocationRecord> { $0.rootInvocationID == rootID },
            sort: [SortDescriptor(\.startedAt)]
        )
        _suppressionMarkers = Query(
            filter: #Predicate<SuppressedAgentInvocationRoot> { $0.rootInvocationID == rootID }
        )
    }

    var body: some View {
        let rootIsSuppressed = !suppressionMarkers.isEmpty
            || storedInvocations.contains(where: \.isLogSuppressed)
        let visibleInvocations = rootIsSuppressed ? [] : storedInvocations
        if !visibleInvocations.isEmpty {
            AgentCollaborationDebugList(invocations: visibleInvocations)
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
                                GenerationTextBlock(title: "Apple transcript", text: transcript)
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
                GenerationTextBlock(title: "Apple transcript", text: summary)
            }
            if let messages = payload.openAIMessagesJSON, !messages.isEmpty {
                GenerationTextBlock(title: "OpenAI messages", text: messages)
            }
        }
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
                ScrollView {
                    Text(text.isEmpty ? "(empty)" : text)
                        .font(theme.monoFont(theme.typography.xs))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
