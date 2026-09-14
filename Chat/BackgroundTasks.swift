import Combine
import Foundation
import ShadSwift
import SwiftData
import SwiftUI

enum BackgroundTaskKind: String {
    case heartbeat
    case dream

    var displayName: String {
        switch self {
        case .heartbeat: "Heartbeat"
        case .dream: "Dream"
        }
    }
}

enum BackgroundTaskStatus: String {
    case running
    case succeeded
    case failed
    case cancelled
    case timedOut

    var displayName: String {
        switch self {
        case .running: "Running"
        case .succeeded: "Succeeded"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .timedOut: "Timed out"
        }
    }
}

struct BackgroundTaskLogEntry: Codable, Identifiable {
    var id: UUID = UUID()
    var timestamp: Date = .now
    var stage: String
    var label: String
    var content: String
}

@Model
final class BackgroundTaskRun: Identifiable {
    @Attribute(.unique) var id: UUID
    var kindRawValue: String
    var statusRawValue: String
    var title: String
    var agentID: UUID?
    var agentName: String
    var detail: String
    var startedAt: Date
    var completedAt: Date?
    var errorMessage: String?
    var logEntriesJSON: String = "[]"

    init(
        id: UUID = UUID(),
        kind: BackgroundTaskKind,
        status: BackgroundTaskStatus = .running,
        title: String,
        agentID: UUID?,
        agentName: String,
        detail: String,
        startedAt: Date = .now,
        completedAt: Date? = nil,
        errorMessage: String? = nil,
        logEntries: [BackgroundTaskLogEntry] = []
    ) {
        self.id = id
        kindRawValue = kind.rawValue
        statusRawValue = status.rawValue
        self.title = title
        self.agentID = agentID
        self.agentName = agentName
        self.detail = detail
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.errorMessage = errorMessage
        logEntriesJSON = Self.encode(logEntries)
    }

    var kind: BackgroundTaskKind {
        BackgroundTaskKind(rawValue: kindRawValue) ?? .heartbeat
    }

    var status: BackgroundTaskStatus {
        BackgroundTaskStatus(rawValue: statusRawValue) ?? .failed
    }

    var logEntries: [BackgroundTaskLogEntry] {
        (try? JSONDecoder().decode([BackgroundTaskLogEntry].self, from: Data(logEntriesJSON.utf8))) ?? []
    }

    func formattedDuration(at date: Date = .now) -> String {
        let end = completedAt ?? date
        let total = max(0, end.timeIntervalSince(startedAt))
        if total < 10 { return String(format: "%.1fs", total) }
        if total < 60 { return String(format: "%.0fs", total) }
        let minutes = Int(total) / 60
        let seconds = Int(total.rounded(.towardZero)) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    static func encode(_ entries: [BackgroundTaskLogEntry]) -> String {
        guard let data = try? JSONEncoder().encode(entries) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor
final class BackgroundTaskTracker: ObservableObject {
    @Published private(set) var runs: [BackgroundTaskRun] = []

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        loadRuns()
        closeInterruptedRuns()
        importExistingHeartbeatRuns()
        backfillHeartbeatLogs()
    }

    @discardableResult
    func start(
        id: UUID = UUID(),
        kind: BackgroundTaskKind,
        title: String,
        agentID: UUID?,
        agentName: String,
        detail: String,
        at startedAt: Date = .now
    ) -> UUID {
        if let existing = runs.first(where: { $0.id == id }) {
            return existing.id
        }
        let run = BackgroundTaskRun(
            id: id,
            kind: kind,
            title: title,
            agentID: agentID,
            agentName: agentName,
            detail: detail,
            startedAt: startedAt
        )
        modelContext.insert(run)
        runs.insert(run, at: 0)
        save()
        return run.id
    }

    func update(_ id: UUID, detail: String) {
        guard let run = runs.first(where: { $0.id == id }), run.status == .running else { return }
        run.detail = detail
        save()
        objectWillChange.send()
    }

    func append(
        _ id: UUID,
        stage: String,
        label: String,
        content: String,
        at timestamp: Date = .now
    ) {
        guard let run = runs.first(where: { $0.id == id }) else { return }
        var entries = run.logEntries
        entries.append(
            BackgroundTaskLogEntry(
                timestamp: timestamp,
                stage: stage,
                label: label,
                content: content
            )
        )
        run.logEntriesJSON = BackgroundTaskRun.encode(entries)
        save()
        objectWillChange.send()
    }

    func finish(
        _ id: UUID,
        status: BackgroundTaskStatus,
        errorMessage: String? = nil,
        at completedAt: Date = .now
    ) {
        guard let run = runs.first(where: { $0.id == id }), run.status == .running else { return }
        run.statusRawValue = status.rawValue
        run.completedAt = completedAt
        run.errorMessage = errorMessage
        save()
        objectWillChange.send()
    }

    private func loadRuns() {
        let descriptor = FetchDescriptor<BackgroundTaskRun>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        runs = (try? modelContext.fetch(descriptor)) ?? []
    }

    private func closeInterruptedRuns() {
        let now = Date()
        var changed = false
        for run in runs where run.status == .running {
            run.statusRawValue = BackgroundTaskStatus.cancelled.rawValue
            run.completedAt = now
            run.errorMessage = "Interrupted when Chat last exited."
            changed = true
        }
        if changed { save() }
    }

    private func importExistingHeartbeatRuns() {
        let knownIDs = Set(runs.map(\.id))
        let heartbeatRuns = (try? modelContext.fetch(FetchDescriptor<HeartbeatRun>())) ?? []
        guard heartbeatRuns.contains(where: { !knownIDs.contains($0.id) }) else { return }

        let heartbeats = (try? modelContext.fetch(FetchDescriptor<AgentHeartbeat>())) ?? []
        let heartbeatsByID = Dictionary(uniqueKeysWithValues: heartbeats.map { ($0.id, $0) })
        for heartbeatRun in heartbeatRuns where !knownIDs.contains(heartbeatRun.id) {
            let run = BackgroundTaskRun(
                id: heartbeatRun.id,
                kind: .heartbeat,
                status: importedStatus(for: heartbeatRun),
                title: heartbeatsByID[heartbeatRun.heartbeatID]?.displayTitle ?? "Heartbeat",
                agentID: heartbeatRun.agentID,
                agentName: heartbeatRun.agentName,
                detail: heartbeatRun.destination,
                startedAt: heartbeatRun.startedAt,
                completedAt: heartbeatRun.completedAt,
                errorMessage: heartbeatRun.errorMessage,
                logEntries: basicHeartbeatLogs(for: heartbeatRun)
            )
            modelContext.insert(run)
            runs.append(run)
        }
        runs.sort { $0.startedAt > $1.startedAt }
        save()
    }

    private func backfillHeartbeatLogs() {
        let runsByID = Dictionary(uniqueKeysWithValues: runs.map { ($0.id, $0) })
        let heartbeatRuns = (try? modelContext.fetch(FetchDescriptor<HeartbeatRun>())) ?? []
        let turns = (try? modelContext.fetch(FetchDescriptor<GenerationTurn>())) ?? []
        let turnsByRunID = Dictionary(
            uniqueKeysWithValues: turns.compactMap { turn in
                turn.heartbeatRunID.map { ($0, turn) }
            }
        )
        var changed = false

        for heartbeatRun in heartbeatRuns {
            guard let tracked = runsByID[heartbeatRun.id], tracked.logEntries.isEmpty else { continue }
            var entries = basicHeartbeatLogs(for: heartbeatRun)
            if let turn = turnsByRunID[heartbeatRun.id] {
                let turnID = turn.id
                var debugDescriptor = FetchDescriptor<GenerationDebugPayload>(
                    predicate: #Predicate { $0.turnID == turnID }
                )
                debugDescriptor.fetchLimit = 1
                if let debug = try? modelContext.fetch(debugDescriptor).first {
                    entries.append(contentsOf: debugEntries(debug))
                }

                let invocationDescriptor = FetchDescriptor<ToolInvocation>(
                    predicate: #Predicate { $0.turnID == turnID },
                    sortBy: [SortDescriptor(\.sequence)]
                )
                if let invocations = try? modelContext.fetch(invocationDescriptor) {
                    entries.append(contentsOf: invocations.map {
                        BackgroundTaskLogEntry(
                            timestamp: $0.completedAt,
                            stage: "Execution",
                            label: "Tool · \($0.toolName)",
                            content: "Arguments:\n\($0.argumentsJSON)\n\nResult:\n\($0.resultText)"
                        )
                    })
                }
            }
            tracked.logEntriesJSON = BackgroundTaskRun.encode(entries)
            changed = true
        }
        if changed { save() }
    }

    private func basicHeartbeatLogs(for run: HeartbeatRun) -> [BackgroundTaskLogEntry] {
        var entries = [
            BackgroundTaskLogEntry(timestamp: run.startedAt, stage: "Setup", label: "Instruction", content: run.instruction),
            BackgroundTaskLogEntry(timestamp: run.startedAt, stage: "Setup", label: "Destination", content: run.destination),
            BackgroundTaskLogEntry(timestamp: run.completedAt, stage: "Result", label: "Action", content: run.actionSummary),
        ]
        if !run.modelInput.isEmpty {
            entries.append(BackgroundTaskLogEntry(timestamp: run.startedAt, stage: "Execution", label: "Model Input", content: run.modelInput))
        }
        if let output = run.modelOutput {
            entries.append(BackgroundTaskLogEntry(timestamp: run.completedAt, stage: "Execution", label: "Model Output", content: output))
        }
        if let error = run.errorMessage {
            entries.append(BackgroundTaskLogEntry(timestamp: run.completedAt, stage: "Result", label: "Error", content: error))
        }
        return entries
    }

    private func debugEntries(_ debug: GenerationDebugPayload) -> [BackgroundTaskLogEntry] {
        var entries = [
            BackgroundTaskLogEntry(timestamp: debug.capturedAt, stage: "Execution", label: "System Prompt", content: debug.systemPrompt),
            BackgroundTaskLogEntry(timestamp: debug.capturedAt, stage: "Execution", label: "Conversation Prompt", content: debug.conversationPrompt),
            BackgroundTaskLogEntry(timestamp: debug.capturedAt, stage: "Execution", label: "Model Output", content: debug.rawModelOutput),
        ]
        if let reasoning = debug.reasoningText {
            entries.append(BackgroundTaskLogEntry(timestamp: debug.capturedAt, stage: "Execution", label: "Reasoning", content: reasoning))
        }
        if let intermediate = debug.intermediateAssistantJSON {
            entries.append(BackgroundTaskLogEntry(timestamp: debug.capturedAt, stage: "Execution", label: "Intermediate Output", content: intermediate))
        }
        return entries
    }

    private func importedStatus(for run: HeartbeatRun) -> BackgroundTaskStatus {
        guard let error = run.errorMessage else { return .succeeded }
        if error.localizedCaseInsensitiveContains("timed out") { return .timedOut }
        if error.localizedCaseInsensitiveContains("abort") { return .cancelled }
        return .failed
    }

    private func save() {
        try? modelContext.save()
    }
}

struct BackgroundTaskCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()
            Button("Background Tasks") {
                openWindow(id: "background-tasks")
            }
        }
    }
}

struct BackgroundTasksView: View {
    @Environment(\.shadTheme) private var theme
    @ObservedObject var tracker: BackgroundTaskTracker

    private var runningRuns: [BackgroundTaskRun] {
        tracker.runs.filter { $0.status == .running }
    }

    private var completedRuns: [BackgroundTaskRun] {
        tracker.runs.filter { $0.status != .running }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.spacing.xxl) {
                VStack(alignment: .leading, spacing: theme.spacing.sm) {
                    Text("Background Tasks")
                        .font(theme.font(theme.typography.xxl, theme.typography.semibold))
                        .foregroundStyle(theme.colors.foreground)
                    Text("Heartbeats and dreams running now, plus their completed history.")
                        .font(theme.font(theme.typography.sm))
                        .foregroundStyle(theme.colors.mutedForeground)
                }

                taskSection("Running", count: runningRuns.count) {
                    if runningRuns.isEmpty {
                        emptyRow("No background tasks are running")
                    } else {
                        taskRows(runningRuns)
                    }
                }

                taskSection("History", count: completedRuns.count) {
                    if completedRuns.isEmpty {
                        emptyRow("No background tasks have run yet")
                    } else {
                        taskRows(completedRuns)
                    }
                }
            }
            .padding(theme.spacing.xxl)
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(theme.colors.background)
        .frame(minWidth: 700, minHeight: 480)
    }

    private func taskSection<Content: View>(
        _ title: String,
        count: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ShadCard(size: .sm) {
            ShadCardHeader(showsSeparator: true) {
                HStack {
                    ShadCardTitle(title)
                    Spacer()
                    ShadBadge("\(count)", variant: .secondary)
                }
            }
            ShadCardContent { content() }
        }
    }

    private func taskRows(_ runs: [BackgroundTaskRun]) -> some View {
        ShadItemGroup(spacing: 0) {
            ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
                if index > 0 { ShadItemSeparator() }
                BackgroundTaskRow(run: run)
            }
        }
    }

    private func emptyRow(_ title: String) -> some View {
        ShadItem(size: .sm) {
            ShadItemMedia {
                ShadIconView(.clock, size: 16)
                    .foregroundStyle(theme.colors.mutedForeground)
            }
            ShadItemContent {
                ShadItemDescription(title)
            }
        }
    }
}

private struct BackgroundTaskRow: View {
    @Environment(\.shadTheme) private var theme
    let run: BackgroundTaskRun
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.sm) {
            ShadItem(size: .sm, action: {
                withAnimation(theme.interactionAnimation) { isExpanded.toggle() }
            }) {
                ShadItemMedia {
                    if run.status == .running {
                        ShadSpinner(size: 16)
                    } else {
                        ShadIconView(statusIcon, size: 16)
                            .foregroundStyle(statusColor)
                    }
                }

                HStack(spacing: theme.spacing.lg) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: theme.spacing.sm) {
                            Text(run.title)
                                .font(theme.font(theme.typography.sm, theme.typography.medium))
                                .foregroundStyle(theme.colors.foreground)
                                .lineLimit(1)
                            ShadBadge(run.kind.displayName, variant: .secondary)
                        }
                        Text(summary)
                            .font(theme.font(theme.typography.xs))
                            .foregroundStyle(run.errorMessage == nil ? theme.colors.mutedForeground : theme.colors.warning)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(run.agentName)
                        .font(theme.font(theme.typography.sm))
                        .foregroundStyle(theme.colors.mutedForeground)
                        .lineLimit(1)
                        .frame(width: 130, alignment: .leading)

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(run.status.displayName)
                        durationText
                    }
                    .font(theme.monoFont(theme.typography.xs))
                    .foregroundStyle(theme.colors.mutedForeground)
                    .frame(width: 100, alignment: .trailing)

                    Text(run.startedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                        .font(theme.font(theme.typography.xs))
                        .foregroundStyle(theme.colors.mutedForeground)
                        .lineLimit(1)
                        .frame(width: 112, alignment: .trailing)
                        .help(run.startedAt.formatted(date: .complete, time: .standard))

                    ShadIconView(isExpanded ? .chevronDown : .chevronRight, size: 14)
                        .foregroundStyle(theme.colors.mutedForeground)
                }
            }
            .accessibilityHint(isExpanded ? "Hide execution log" : "Show execution log")

            if isExpanded {
                VStack(alignment: .leading, spacing: theme.spacing.lg) {
                    if run.logEntries.isEmpty {
                        Text("No detailed log was captured for this older task.")
                            .font(theme.font(theme.typography.sm))
                            .foregroundStyle(theme.colors.mutedForeground)
                    } else {
                        ForEach(run.logEntries) { entry in
                            VStack(alignment: .leading, spacing: theme.spacing.xs) {
                                HStack {
                                    Text(entry.stage)
                                        .font(theme.font(theme.typography.xs, theme.typography.semibold))
                                    Spacer()
                                    Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                        .font(theme.monoFont(theme.typography.xs))
                                }
                                .foregroundStyle(theme.colors.mutedForeground)

                                GenerationTextBlock(title: entry.label, text: entry.content)
                            }
                        }
                    }
                }
                .padding(.leading, theme.spacing.xxl)
                .padding(.bottom, theme.spacing.md)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var summary: String {
        run.errorMessage ?? (run.detail.isEmpty ? run.status.displayName : run.detail)
    }

    @ViewBuilder
    private var durationText: some View {
        if run.status == .running {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(run.formattedDuration(at: context.date))
            }
        } else {
            Text(run.formattedDuration())
        }
    }

    private var statusIcon: ShadIcon {
        switch run.status {
        case .succeeded: .circleCheck
        case .failed, .timedOut: .triangleAlert
        case .cancelled: .x
        case .running: .clock
        }
    }

    private var statusColor: Color {
        switch run.status {
        case .succeeded: theme.colors.success
        case .failed, .timedOut: theme.colors.warning
        case .cancelled, .running: theme.colors.mutedForeground
        }
    }
}
