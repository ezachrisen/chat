import Foundation
import ShadSwift
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
    @Environment(\.shadTheme) private var theme
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
        ScrollView {
            VStack(alignment: .leading, spacing: theme.spacing.xxl) {
                VStack(alignment: .leading, spacing: theme.spacing.sm) {
                    Text("Heartbeats")
                        .font(theme.font(theme.typography.xxl, theme.typography.semibold))
                        .foregroundStyle(theme.colors.foreground)
                    Text("Scheduled agent work, live executions, and recent results.")
                        .font(theme.font(theme.typography.sm))
                        .foregroundStyle(theme.colors.mutedForeground)
                }

                heartbeatSection("Upcoming", count: upcomingHeartbeats.count) {
                    if upcomingHeartbeats.isEmpty {
                        EmptyHeartbeatRow(title: "No upcoming heartbeats", icon: .clock)
                    } else {
                        ShadItemGroup(spacing: 0) {
                            ForEach(Array(upcomingHeartbeats.enumerated()), id: \.element.id) { index, heartbeat in
                                if index > 0 { ShadItemSeparator() }
                                upcomingHeartbeatRow(heartbeat)
                            }
                        }
                    }
                }

                heartbeatSection("Running", count: heartbeatScheduler.runningHeartbeats.count) {
                    if heartbeatScheduler.runningHeartbeats.isEmpty {
                        EmptyHeartbeatRow(title: "No running heartbeats", icon: .custom("waveform.path.ecg"))
                    } else {
                        ShadItemGroup(spacing: 0) {
                            ForEach(Array(heartbeatScheduler.runningHeartbeats.enumerated()), id: \.element.id) { index, heartbeat in
                                if index > 0 { ShadItemSeparator() }
                                runningHeartbeatRow(heartbeat)
                            }
                        }
                    }
                }

                heartbeatSection("Completed", countLabel: "\(agentStore.heartbeatRuns.count) loaded") {
                    if agentStore.heartbeatRuns.isEmpty {
                        EmptyHeartbeatRow(title: "No completed heartbeats", icon: .circleCheck)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(agentStore.heartbeatRuns.enumerated()), id: \.element.id) { index, run in
                                if index > 0 { ShadItemSeparator() }
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
            }
            .padding(theme.spacing.xxl)
            .frame(maxWidth: 1120, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(theme.colors.background)
        .frame(minWidth: 760, minHeight: 520)
    }

    private func heartbeatSection<Content: View>(
        _ title: String,
        count: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        heartbeatSection(title, countLabel: "\(count)", content: content)
    }

    private func heartbeatSection<Content: View>(
        _ title: String,
        countLabel: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ShadCard(size: .sm) {
            ShadCardHeader(showsSeparator: true) {
                HStack(spacing: theme.spacing.md) {
                    ShadCardTitle(title)
                    Spacer(minLength: 0)
                    ShadBadge(countLabel, variant: .secondary)
                }
            }
            ShadCardContent {
                content()
            }
        }
    }

    private func agentName(for heartbeat: AgentHeartbeat) -> String {
        agentStore.agent(for: heartbeat.agentID)?.displayName ?? "Deleted agent"
    }

    private func destination(for heartbeat: AgentHeartbeat) -> String {
        chatStore.heartbeatDestinationDescription(for: heartbeat)
    }

    private func upcomingHeartbeatRow(_ heartbeat: AgentHeartbeat) -> some View {
        ShadItem(size: .sm) {
            UpcomingHeartbeatRow(
                heartbeat: heartbeat,
                agentName: agentName(for: heartbeat),
                destination: destination(for: heartbeat)
            )

            ShadItemActions {
                heartbeatActionsMenu {
                    ShadDropdownMenuItem("Run now", icon: .play) {
                        heartbeatScheduler.runNow(heartbeat.id)
                    }
                    ShadDropdownMenuItem("Skip", icon: .arrowRight) {
                        heartbeatScheduler.skip(heartbeat.id)
                    }
                    ShadDropdownMenuSeparator()
                    ShadDropdownMenuItem("Disable", icon: .pause) {
                        heartbeatScheduler.disable(heartbeat.id)
                    }
                }
            }
        }
        .contextMenu {
            Button("Run Now") { heartbeatScheduler.runNow(heartbeat.id) }
            Button("Skip") { heartbeatScheduler.skip(heartbeat.id) }
            Divider()
            Button("Disable") { heartbeatScheduler.disable(heartbeat.id) }
        }
    }

    private func runningHeartbeatRow(_ heartbeat: RunningHeartbeat) -> some View {
        ShadItem(size: .sm) {
            RunningHeartbeatRow(heartbeat: heartbeat)
            ShadItemActions {
                heartbeatActionsMenu {
                    ShadDropdownMenuItem("Abort", icon: .x, variant: .destructive) {
                        heartbeatScheduler.abort(heartbeat.id)
                    }
                }
            }
        }
        .contextMenu {
            Button("Abort", role: .destructive) { heartbeatScheduler.abort(heartbeat.id) }
        }
        .help("Open actions or right-click to abort")
    }

    private func heartbeatActionsMenu<Content: View>(
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        ShadDropdownMenu(alignment: .bottomTrailing, minWidth: 168) { isOpen in
            ShadIconView(.moreHorizontal, size: 16)
                .foregroundStyle(theme.colors.mutedForeground)
                .frame(width: 28, height: 28)
                .background(
                    theme.colors.accent.opacity(isOpen ? 1 : 0),
                    in: ShadRoundedRectangle(cornerRadius: theme.radius.md)
                )
                .contentShape(Rectangle())
                .accessibilityLabel("Heartbeat actions")
        } content: {
            content()
        }
    }
}

private struct UpcomingHeartbeatRow: View {
    @Environment(\.shadTheme) private var theme
    let heartbeat: AgentHeartbeat
    let agentName: String
    let destination: String

    var body: some View {
        HStack(spacing: 12) {
            ShadIconView(.clock, size: 16)
                .foregroundStyle(theme.colors.mutedForeground)
                .frame(width: 18)

            Text(agentName)
                .font(theme.font(theme.typography.sm, theme.typography.medium))
                .foregroundStyle(theme.colors.foreground)
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)

            Text(heartbeat.instruction)
                .font(theme.font(theme.typography.sm))
                .foregroundStyle(theme.colors.mutedForeground)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

            Text(destination)
                .font(theme.font(theme.typography.sm))
                .foregroundStyle(theme.colors.mutedForeground)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 170, alignment: .leading)

            if let nextRunAt = heartbeat.nextRunAt {
                Text(nextRunAt, style: .relative)
                    .font(theme.font(theme.typography.xs))
                    .foregroundStyle(theme.colors.mutedForeground)
                    .lineLimit(1)
                    .frame(width: 92, alignment: .trailing)
                    .help(nextRunAt.formatted(date: .abbreviated, time: .shortened))
            }

        }
        .frame(minHeight: 28)
    }
}

private struct RunningHeartbeatRow: View {
    @Environment(\.shadTheme) private var theme
    let heartbeat: RunningHeartbeat

    var body: some View {
        HStack(spacing: 12) {
            ShadSpinner(size: 16)
                .frame(width: 18)

            Text(heartbeat.agentName)
                .font(theme.font(theme.typography.sm, theme.typography.medium))
                .foregroundStyle(theme.colors.foreground)
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)

            Text(heartbeat.instruction)
                .font(theme.font(theme.typography.sm))
                .foregroundStyle(theme.colors.mutedForeground)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(heartbeat.destination)
                .font(theme.font(theme.typography.sm))
                .foregroundStyle(theme.colors.mutedForeground)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 170, alignment: .leading)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsedText = elapsedText(at: context.date)
                Text(elapsedText)
                    .font(theme.monoFont(theme.typography.xs))
                    .foregroundStyle(theme.colors.mutedForeground)
                    .lineLimit(1)
                    .frame(width: 92, alignment: .trailing)
                    .accessibilityLabel("Running for \(elapsedText)")
            }
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
    @Environment(\.shadTheme) private var theme
    let run: HeartbeatRun
    @Environment(\.modelContext) private var modelContext
    @State private var isExpanded = false
    @State private var invocations: [ToolInvocationDisplay] = []
    @State private var payload: GenerationDebugPayload?

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.sm) {
            ShadItem(size: .sm, action: {
                withAnimation(theme.interactionAnimation) { isExpanded.toggle() }
            }) {
                ShadItemMedia {
                    ShadIconView(run.succeeded ? .circleCheck : .triangleAlert, size: 16)
                        .foregroundStyle(run.succeeded ? theme.colors.success : theme.colors.warning)
                        .frame(width: 18)
                }

                completedSummary

                ShadIconView(isExpanded ? .chevronDown : .chevronRight, size: 14)
                    .foregroundStyle(theme.colors.mutedForeground)
            }
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Collapse heartbeat details" : "Expand heartbeat details")

            if isExpanded {
                ShadItem(variant: .muted, size: .sm) {
                    VStack(alignment: .leading, spacing: theme.spacing.lg) {
                        HeartbeatDetailField(title: "Action", text: run.actionSummary)
                        HeartbeatDetailField(title: "Duration", text: run.formattedDuration)
                        if let tokens = run.formattedTokenUsage {
                            HeartbeatDetailField(title: "Tokens", text: run.tokenUsageHelp ?? tokens)
                        }
                        if let errorMessage = run.errorMessage {
                            HeartbeatDetailField(title: "Error", text: errorMessage, isError: true)
                        }
                        if !invocations.isEmpty {
                            GenerationToolCallList(invocations: invocations)
                        }
                        debugContent
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, theme.spacing.xxl)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onChange(of: isExpanded) { _, expanded in
            if expanded {
                loadDetails()
            }
        }
    }

    private var completedSummary: some View {
        HStack(spacing: theme.spacing.lg) {
            Text(run.agentName)
                .font(theme.font(theme.typography.sm, theme.typography.medium))
                .foregroundStyle(theme.colors.foreground)
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(run.instruction)
                    .font(theme.font(theme.typography.sm))
                    .foregroundStyle(theme.colors.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(run.actionSummary)
                    .font(theme.font(theme.typography.xs))
                    .foregroundStyle(theme.colors.mutedForeground.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(run.destination)
                .font(theme.font(theme.typography.sm))
                .foregroundStyle(theme.colors.mutedForeground)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 170, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                Text(
                    run.completedAt.formatted(
                        .dateTime.month(.abbreviated).day().hour().minute()
                    )
                )
                Text(HeartbeatRun.metricsLine(duration: run.formattedDuration, tokens: run.formattedTokenUsage))
                    .font(theme.monoFont(theme.typography.xs))
                    .foregroundStyle(theme.colors.mutedForeground.opacity(0.8))
                    .help(run.tokenUsageHelp ?? "Duration of this heartbeat run")
            }
            .font(theme.font(theme.typography.xs))
            .foregroundStyle(theme.colors.mutedForeground)
            .lineLimit(1)
            .frame(width: 132, alignment: .trailing)
            .help(run.completedAt.formatted(date: .complete, time: .standard))
        }
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
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
                .font(theme.font(theme.typography.xs))
                .foregroundStyle(theme.colors.mutedForeground)
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
    @Environment(\.shadTheme) private var theme
    let title: String
    let text: String
    var isError = false

    var body: some View {
        ShadField {
            ShadFieldLabel(title)
            Text(text)
                .font(theme.font(theme.typography.sm))
                .foregroundStyle(isError ? theme.colors.destructive : theme.colors.foreground)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EmptyHeartbeatRow: View {
    let title: String
    let icon: ShadIcon

    var body: some View {
        ShadItem(variant: .muted, size: .sm) {
            ShadItemMedia(icon: icon, size: 32, iconSize: 15)
            ShadItemContent {
                ShadItemDescription(title)
            }
        }
    }
}
