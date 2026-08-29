import SwiftData
import SwiftUI

struct GenerationInspectorButton: View {
    let turn: GenerationTurn

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(Color.secondary.opacity(0.10), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Inspect tools and debug log")
        .popover(isPresented: $isPresented, arrowEdge: .leading) {
            GenerationTurnInspector(turn: turn)
                .frame(minWidth: 420, idealWidth: 460, minHeight: 280, idealHeight: 420)
                .padding(16)
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(turn.agentName)
                        .font(.headline)
                    Text(turn.actionSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(turn.kind.rawValue) · \(turn.status.rawValue) · \(turn.toolCallCount) tool\(turn.toolCallCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                if invocations.isEmpty {
                    Text("No tools were called.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    GenerationToolCallList(invocations: invocations)
                }

                if turn.debugCaptureEnabled, let payload {
                    GenerationDebugSections(payload: payload)
                } else if turn.debugCaptureEnabled {
                    Text("Debug log was on, but no payload was stored.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Debug log was off for this run.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tools")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(invocations, id: \ToolInvocationDisplay.id) { invocation in
                toolRow(invocation)
            }
        }
    }

    @ViewBuilder
    private func toolRow(_ invocation: ToolInvocationDisplay) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(invocation.toolName)
                    .font(.body.weight(.medium))
                Spacer()
                Text(invocation.succeeded ? "Succeeded" : "Failed")
                    .font(.caption)
                    .foregroundStyle(invocation.succeeded ? Color.secondary : Color.red)
            }

            if let skillName = invocation.skillName {
                Text("Skill: \(skillName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !invocation.argumentsJSON.isEmpty {
                Text(truncated(invocation.argumentsJSON, limit: 500))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }

            Text(truncated(invocation.resultText, limit: 800))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)

            if invocation.resultTruncated {
                Text("Result truncated")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private func truncated(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n…(truncated)"
    }
}

struct GenerationDebugSections: View {
    let payload: GenerationDebugPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Debug log")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ScrollView {
                Text(text.isEmpty ? "(empty)" : text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 220)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
