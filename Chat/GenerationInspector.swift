import ShadSwift
import SwiftData
import SwiftUI

struct GenerationInspectorButton: View {
    let turn: GenerationTurn

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

    @Environment(\.modelContext) private var modelContext
    @State private var invocations: [ToolInvocationDisplay] = []
    @State private var payload: GenerationDebugPayload?
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

                if invocations.isEmpty {
                    ShadItem(variant: .muted, size: .xs) {
                        ShadItemDescription("No tools were called.")
                    }
                } else {
                    GenerationToolCallList(invocations: invocations)
                }

                if turn.debugCaptureEnabled, let payload {
                    GenerationDebugSections(payload: payload)
                } else if turn.debugCaptureEnabled {
                    ShadItem(variant: .muted, size: .xs) {
                        ShadItemDescription("Debug log was on, but no payload was stored.")
                    }
                } else {
                    ShadItem(variant: .muted, size: .xs) {
                        ShadItemDescription("Debug log was off for this run.")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: load)
    }

    private func load() {
        invocations = GenerationQuery.fetchToolCalls(forTurn: turn.id, in: modelContext).map(ToolInvocationDisplay.init)
        if turn.debugCaptureEnabled {
            payload = GenerationQuery.fetchDebugPayload(forTurn: turn.id, in: modelContext)
        }
    }
}

struct GenerationToolCallList: View {
    let invocations: [ToolInvocationDisplay]
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

                if !invocation.argumentsJSON.isEmpty {
                    Text(truncated(invocation.argumentsJSON, limit: 500))
                        .font(theme.monoFont(theme.typography.xs))
                        .textSelection(.enabled)
                        .foregroundStyle(theme.colors.mutedForeground)
                }

                Text(truncated(invocation.resultText, limit: 800))
                    .font(theme.monoFont(theme.typography.xs))
                    .textSelection(.enabled)

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
