import Foundation
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
    @ObservedObject var personaStore: PersonaStore
    @ObservedObject var chatStore: ChatStore
    @ObservedObject var heartbeatScheduler: HeartbeatScheduler

    private var runningHeartbeatIDs: Set<PersonaHeartbeat.ID> {
        Set(heartbeatScheduler.runningHeartbeats.map(\.id))
    }

    private var upcomingHeartbeats: [PersonaHeartbeat] {
        personaStore.heartbeats
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
                    if personaStore.heartbeatRuns.isEmpty {
                        EmptyHeartbeatRow(
                            title: "No completed heartbeats",
                            systemImage: "checkmark.circle"
                        )
                    } else {
                        ForEach(personaStore.heartbeatRuns) { run in
                            CompletedHeartbeatRow(run: run)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .navigationTitle("Heartbeats")
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    private func personaName(for heartbeat: PersonaHeartbeat) -> String {
        personaStore.persona(for: heartbeat.personaID)?.displayName ?? "Deleted persona"
    }

    private func destination(for heartbeat: PersonaHeartbeat) -> String {
        chatStore.heartbeatDestinationDescription(for: heartbeat)
    }

    private func upcomingHeartbeatRow(_ heartbeat: PersonaHeartbeat) -> some View {
        HStack(spacing: 8) {
            UpcomingHeartbeatRow(
                heartbeat: heartbeat,
                personaName: personaName(for: heartbeat),
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
    private func upcomingHeartbeatActions(_ heartbeat: PersonaHeartbeat) -> some View {
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
    let heartbeat: PersonaHeartbeat
    let personaName: String
    let destination: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
                .frame(width: 18)

            Text(personaName)
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

            Text(heartbeat.personaName)
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
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                HeartbeatDetailField(title: "Action", text: run.actionSummary)

                if let errorMessage = run.errorMessage {
                    HeartbeatDetailField(title: "Error", text: errorMessage, isError: true)
                }

                HeartbeatTextBlock(
                    title: "Model input",
                    text: run.modelInput.isEmpty
                        ? "No model input was constructed."
                        : run.modelInput
                )
                HeartbeatTextBlock(
                    title: "Model output",
                    text: run.modelOutput ?? "No model output was received."
                )
            }
            .padding(.top, 10)
            .padding(.leading, 28)
            .padding(.bottom, 8)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: run.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(run.succeeded ? .green : .orange)
                    .frame(width: 18)

                Text(run.personaName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .frame(width: 120, alignment: .leading)

                Text(run.instruction)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(run.destination)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 170, alignment: .leading)

                Text(
                    run.completedAt.formatted(
                        .dateTime
                            .month(.abbreviated)
                            .day()
                            .hour()
                            .minute()
                    )
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 132, alignment: .trailing)
                    .help(run.completedAt.formatted(date: .complete, time: .standard))
            }
            .frame(minHeight: 28)
        }
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

private struct HeartbeatTextBlock: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ScrollView {
                Text(text)
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

private struct EmptyHeartbeatRow: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .foregroundStyle(.secondary)
            .frame(minHeight: 28)
    }
}
