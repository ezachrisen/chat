import Foundation
import SwiftData
import SwiftUI

struct HeartbeatCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()
            Button("Heartbeats") {
                openWindow(id: "heartbeats")
            }
        }
    }
}

struct HeartbeatsView: View {
    @ObservedObject var agentStore: AgentStore
    @ObservedObject var chatStore: ChatStore
    @ObservedObject var heartbeatScheduler: HeartbeatScheduler

    private var runningHeartbeatIDs: Set<AgentHeartbeat.ID> {
        Set(heartbeatScheduler.runningHeartbeats.map(\.id))
    }

    private var upcomingHeartbeats: [AgentHeartbeat] {
        agentStore.heartbeats
            .filter {
                $0.isEnabled
                    && $0.nextRunAt != nil
                    && !runningHeartbeatIDs.contains($0.id)
            }
            .sorted { lhs, rhs in
                (lhs.nextRunAt ?? .distantFuture) < (rhs.nextRunAt ?? .distantFuture)
            }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Upcoming") {
                    if upcomingHeartbeats.isEmpty {
                        EmptyHeartbeatRow(
                            title: "No upcoming heartbeats",
                            systemImage: "clock"
                        )
                    } else {
                        ForEach(upcomingHeartbeats) { heartbeat in
                            upcomingHeartbeatRow(heartbeat)
                        }
                    }
                }

                Section("Running") {
                    if heartbeatScheduler.runningHeartbeats.isEmpty {
                        EmptyHeartbeatRow(
                            title: "No running heartbeats",
                            systemImage: "waveform.path.ecg"
                        )
                    } else {
                        ForEach(heartbeatScheduler.runningHeartbeats) { heartbeat in
                            RunningHeartbeatRow(heartbeat: heartbeat)
                                .contentShape(Rectangle())
                                .contextMenu {
                                    Button(role: .destructive) {
                                        heartbeatScheduler.abort(heartbeat.id)
                                    } label: {
                                        Label("Abort", systemImage: "xmark.circle")
                                    }
                                }
                                .help("Right-click to abort")
                        }
                    }
                }

                Section("Completed") {
                    if agentStore.heartbeatRuns.isEmpty {
                        EmptyHeartbeatRow(
                            title: "No completed heartbeats",
                            systemImage: "checkmark.circle"
                        )
                    } else {
                        ForEach(agentStore.heartbeatRuns) { run in
                            CompletedHeartbeatRow(run: run)
                                .onAppear {
                                    if run.id == agentStore.heartbeatRuns.last?.id {
                                        agentStore.loadOlderHeartbeatRuns()
                                    }
                                }
                        }
                    }
                }
            }
            .listStyle(.inset)
            .navigationTitle("Heartbeats")
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    private func agentName(for heartbeat: AgentHeartbeat) -> String {
        agentStore.agent(for: heartbeat.agentID)?.displayName ?? "Deleted agent"
    }

    private func destination(for heartbeat: AgentHeartbeat) -> String {
        chatStore.heartbeatDestinationDescription(for: heartbeat)
    }

    private func upcomingHeartbeatRow(_ heartbeat: AgentHeartbeat) -> some View {
        HStack(spacing: 8) {
            UpcomingHeartbeatRow(
                heartbeat: heartbeat,
                agentName: agentName(for: heartbeat),
                destination: destination(for: heartbeat)
            )

            Menu {
                upcomingHeartbeatActions(heartbeat)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Heartbeat actions")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            upcomingHeartbeatActions(heartbeat)
        }
    }

    @ViewBuilder
    private func upcomingHeartbeatActions(_ heartbeat: AgentHeartbeat) -> some View {
        Group {
            Button {
                heartbeatScheduler.runNow(heartbeat.id)
            } label: {
                Label("Run Now", systemImage: "play.fill")
            }

            Button {
                heartbeatScheduler.skip(heartbeat.id)
            } label: {
                Label("Skip", systemImage: "forward.end")
            }

            Divider()

            Button {
                heartbeatScheduler.disable(heartbeat.id)
            } label: {
                Label("Disable", systemImage: "pause.circle")
            }
        }
    }
}

private struct UpcomingHeartbeatRow: View {
    let heartbeat: AgentHeartbeat
    let agentName: String
    let destination: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
                .frame(width: 18)

            Text(agentName)
                .fontWeight(.medium)
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)

            Text(heartbeat.instruction)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

            Text(destination)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 170, alignment: .leading)

            if let nextRunAt = heartbeat.nextRunAt {
                Text(nextRunAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 92, alignment: .trailing)
                    .help(nextRunAt.formatted(date: .abbreviated, time: .shortened))
            }

        }
        .frame(minHeight: 28)
    }
}

private struct RunningHeartbeatRow: View {
    let heartbeat: RunningHeartbeat

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 18)

            Text(heartbeat.agentName)
                .fontWeight(.medium)
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)

            Text(heartbeat.instruction)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(heartbeat.destination)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 170, alignment: .leading)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsedText = elapsedText(at: context.date)
                Text(elapsedText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 92, alignment: .trailing)
                    .accessibilityLabel("Running for \(elapsedText)")
            }

            Image(systemName: "cursorarrow.click.2")
                .foregroundStyle(.tertiary)
                .frame(width: 18)
        }
        .frame(minHeight: 28)
    }

    private func elapsedText(at date: Date) -> String {
        let elapsedSeconds = max(0, Int(date.timeIntervalSince(heartbeat.startedAt)))
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

private struct CompletedHeartbeatRow: View {
    let run: HeartbeatRun
    @Environment(\.modelContext) private var modelContext
    @State private var isExpanded = false
    @State private var invocations: [ToolInvocationDisplay] = []
    @State private var payload: GenerationDebugPayload?

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                HeartbeatDetailField(title: "Action", text: run.actionSummary)
                HeartbeatDetailField(title: "Duration", text: run.formattedDuration)
                if let tokens = run.formattedTokenUsage {
                    HeartbeatDetailField(
                        title: "Tokens",
                        text: run.tokenUsageHelp ?? tokens
                    )
                }

                if let errorMessage = run.errorMessage {
                    HeartbeatDetailField(title: "Error", text: errorMessage, isError: true)
                }

                if !invocations.isEmpty {
                    GenerationToolCallList(invocations: invocations)
                }

                debugContent
            }
            .padding(.top, 10)
            .padding(.leading, 28)
            .padding(.bottom, 8)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: run.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(run.succeeded ? .green : .orange)
                    .frame(width: 18)

                Text(run.agentName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .frame(width: 120, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text(run.instruction)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(run.actionSummary)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(run.destination)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 170, alignment: .leading)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(
                        run.completedAt.formatted(
                            .dateTime
                                .month(.abbreviated)
                                .day()
                                .hour()
                                .minute()
                        )
                    )
                    Text(HeartbeatRun.metricsLine(duration: run.formattedDuration, tokens: run.formattedTokenUsage))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .help(run.tokenUsageHelp ?? "Duration of this heartbeat run")
                }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 132, alignment: .trailing)
                    .help(run.completedAt.formatted(date: .complete, time: .standard))
            }
            .frame(minHeight: 28)
        }
        .onChange(of: isExpanded) { _, expanded in
            if expanded {
                loadDetails()
            }
        }
    }

    @ViewBuilder
    private var debugContent: some View {
        if !run.modelInput.isEmpty || run.modelOutput != nil {
            GenerationTextBlock(
                title: "Model input",
                text: run.modelInput.isEmpty
                    ? "No model input was constructed."
                    : run.modelInput
            )
            GenerationTextBlock(
                title: "Model output",
                text: run.modelOutput ?? "No model output was received."
            )
        } else if let payload {
            GenerationDebugSections(payload: payload)
        } else {
            Text("Debug log was off for this run.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func loadDetails() {
        guard let turnID = run.generationTurnID else {
            invocations = []
            payload = nil
            return
        }
        invocations = GenerationQuery.fetchToolCalls(forTurn: turnID, in: modelContext).map(ToolInvocationDisplay.init)
        payload = GenerationQuery.fetchDebugPayload(forTurn: turnID, in: modelContext)
    }
}

private struct HeartbeatDetailField: View {
    let title: String
    let text: String
    var isError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .foregroundStyle(isError ? .red : .primary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EmptyHeartbeatRow: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .foregroundStyle(.secondary)
            .frame(minHeight: 28)
    }
}
