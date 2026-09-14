import ShadSwift
import SwiftUI

struct DreamPreferencesView: View {
    @ObservedObject var store: AgentStore
    @ObservedObject var localModelStore: LocalModelStore
    @ObservedObject var scheduler: DreamScheduler
    @Environment(\.shadTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ShadSettingsPageHeader(
                    title: "Dream",
                    description: "Let agents reflect on recent conversations in Light Sleep, then consolidate durable memories during REM Sleep. Agents dream one at a time."
                )

                VStack(spacing: 0) {
                    ShadSettingsRow(
                        title: "Dreaming",
                        description: "The default for agents that do not override this setting."
                    ) {
                        ShadSwitch(isOn: Binding(
                            get: { store.dreamSettings.isEnabled },
                            set: store.updateDreamEnabled
                        ))
                    }
                    ShadSeparator()
                    DreamScheduleEditor(
                        schedule: store.dreamSettings.schedule,
                        nextRunAt: store.dreamSettings.nextRunAt,
                        onChange: { kind, interval, days, time in
                            store.updateDreamSchedule(
                                kind: kind,
                                intervalMinutes: interval,
                                weekdayMask: days,
                                scheduledTimeMinutes: time
                            )
                        }
                    )
                }
                .shadSettingsCard()

                stageCard(
                    title: "Light Sleep",
                    explanation: "Reads every eligible message in bounded, full-text chunks and saves candidate memories in Stash under “Light Dream”.",
                    prompt: Binding(
                        get: { store.dreamSettings.lightPrompt },
                        set: store.updateDreamLightPrompt
                    ),
                    model: Binding(
                        get: { store.dreamSettings.lightModelIdentifier },
                        set: { store.updateDreamModels(light: $0, rem: store.dreamSettings.remModelIdentifier) }
                    )
                )

                stageCard(
                    title: "REM Sleep",
                    explanation: "Reads the Light Dream stash and promotes only selected candidates to permanent Memory.",
                    prompt: Binding(
                        get: { store.dreamSettings.remPrompt },
                        set: store.updateDreamREMPrompt
                    ),
                    model: Binding(
                        get: { store.dreamSettings.remModelIdentifier },
                        set: { store.updateDreamModels(light: store.dreamSettings.lightModelIdentifier, rem: $0) }
                    )
                )

                if let running = scheduler.runningDream {
                    Text("\(running.agentName) is in \(running.stage). \(scheduler.queuedAgentIDs.count) agent(s) waiting.")
                        .font(theme.font(theme.typography.sm))
                        .foregroundStyle(theme.colors.mutedForeground)
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, 36)
        }
        .background(theme.colors.background)
    }

    private func stageCard(
        title: String,
        explanation: String,
        prompt: Binding<String>,
        model: Binding<String?>
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ShadSettingsSectionHeader(title: title, description: explanation)
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: prompt)
                    .font(theme.font(theme.typography.sm))
                    .frame(minHeight: 145)
                    .padding(8)
                    .background(theme.colors.muted.opacity(0.35))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                DreamModelPicker(
                    title: "Model",
                    selection: model,
                    localModelStore: localModelStore,
                    includesInheritance: false
                )
            }
            .padding(16)
            .shadSettingsCard()
        }
    }
}

struct AgentDreamTab: View {
    let agent: Agent
    @ObservedObject var store: AgentStore
    @ObservedObject var localModelStore: LocalModelStore
    @ObservedObject var scheduler: DreamScheduler
    @State private var lightPrompt = ""
    @State private var remPrompt = ""
    @Environment(\.shadTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                ShadSettingsSectionHeader(
                    title: "Dream",
                    description: "Override app-wide reflection and memory-consolidation settings for this agent."
                )
                Spacer()
                ShadButton("Dream Now", variant: .outline, size: .sm, icon: .custom("moon.stars")) {
                    scheduler.dreamNow(agentID: agent.id)
                }
                .disabled(scheduler.runningDream?.agentID == agent.id || scheduler.queuedAgentIDs.contains(agent.id))
            }

            VStack(spacing: 0) {
                ShadSettingsRow(title: "Participation", description: "Inherit the app setting, or explicitly enable or disable dreaming.") {
                    Picker("Participation", selection: Binding(
                        get: { agent.dreamOverride },
                        set: { store.updateAgentDreamOverride(agent, override: $0) }
                    )) {
                        ForEach(DreamOverride.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
                ShadSeparator()
                ShadSettingsRow(title: "Own schedule", description: "Run this agent on a separate schedule instead of the app-wide schedule.") {
                    ShadSwitch(isOn: Binding(
                        get: { agent.usesDreamScheduleOverride },
                        set: { store.updateAgentDreamScheduleOverride(agent, enabled: $0) }
                    ))
                }
                if agent.usesDreamScheduleOverride {
                    ShadSeparator()
                    DreamScheduleEditor(
                        schedule: agent.dreamSchedule,
                        nextRunAt: agent.nextDreamRunAt,
                        onChange: { kind, interval, days, time in
                            store.updateAgentDreamSchedule(
                                agent,
                                kind: kind,
                                intervalMinutes: interval,
                                weekdayMask: days,
                                scheduledTimeMinutes: time
                            )
                        }
                    )
                }
            }
            .shadSettingsCard()

            overrideStage(
                title: "Light Sleep",
                prompt: $lightPrompt,
                model: Binding(
                    get: { agent.dreamLightModelIdentifierOverride },
                    set: { store.updateAgentDreamModels(agent, light: $0, rem: agent.dreamREMModelIdentifierOverride) }
                ),
                inheritedPrompt: store.dreamSettings.lightPrompt
            )
            overrideStage(
                title: "REM Sleep",
                prompt: $remPrompt,
                model: Binding(
                    get: { agent.dreamREMModelIdentifierOverride },
                    set: { store.updateAgentDreamModels(agent, light: agent.dreamLightModelIdentifierOverride, rem: $0) }
                ),
                inheritedPrompt: store.dreamSettings.remPrompt
            )

            VStack(alignment: .leading, spacing: 5) {
                if let date = agent.lastDreamCompletedAt {
                    Text("Last dream completed \(date.formatted(date: .abbreviated, time: .shortened)).")
                } else {
                    Text("This agent has not completed a dream yet. Its first dream reviews the previous 24 hours.")
                }
                if let error = agent.lastDreamError?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
                    Text("Last attempt failed: \(error)").foregroundStyle(theme.colors.destructive)
                }
            }
            .font(theme.font(theme.typography.sm))
            .foregroundStyle(theme.colors.mutedForeground)
        }
        .onAppear { loadDrafts() }
        .onChange(of: agent.id) { loadDrafts() }
    }

    private func overrideStage(
        title: String,
        prompt: Binding<String>,
        model: Binding<String?>,
        inheritedPrompt: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ShadSettingsSectionHeader(title: title, description: "Leave the prompt blank to inherit the app-wide prompt.")
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: prompt)
                    .font(theme.font(theme.typography.sm))
                    .frame(minHeight: 120)
                    .padding(8)
                    .background(theme.colors.muted.opacity(0.35))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .topLeading) {
                        if prompt.wrappedValue.isEmpty {
                            Text(String(inheritedPrompt.prefix(110)))
                                .font(theme.font(theme.typography.sm))
                                .foregroundStyle(theme.colors.mutedForeground.opacity(0.55))
                                .padding(14)
                                .allowsHitTesting(false)
                        }
                    }
                    .onChange(of: prompt.wrappedValue) {
                        store.updateAgentDreamPrompts(agent, light: lightPrompt, rem: remPrompt)
                    }
                DreamModelPicker(
                    title: "Model",
                    selection: model,
                    localModelStore: localModelStore,
                    includesInheritance: true
                )
            }
            .padding(16)
            .shadSettingsCard()
        }
    }

    private func loadDrafts() {
        lightPrompt = agent.dreamLightPromptOverride ?? ""
        remPrompt = agent.dreamREMPromptOverride ?? ""
    }
}

private struct DreamModelPicker: View {
    let title: String
    @Binding var selection: String?
    @ObservedObject var localModelStore: LocalModelStore
    let includesInheritance: Bool

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Picker(title, selection: $selection) {
                if includesInheritance {
                    Text("Use app setting").tag(String?.none)
                    Text("Agent default model").tag(String?.some(DreamModelChoice.agentDefault))
                } else {
                    Text("Each agent’s default model").tag(String?.none)
                }
                ForEach(localModelStore.selectableModels) { model in
                    Text(model.displayName).tag(String?.some(model.identifier))
                }
            }
            .labelsHidden()
            .frame(width: 260)
        }
    }
}

private struct DreamScheduleEditor: View {
    let schedule: DreamSchedule
    let nextRunAt: Date?
    let onChange: (HeartbeatScheduleKind?, Int?, Int?, Int?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Schedule")
                Spacer()
                Picker("Schedule", selection: Binding(
                    get: { schedule.kind },
                    set: { onChange($0, nil, nil, nil) }
                )) {
                    ForEach(HeartbeatScheduleKind.allCases, id: \.self) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
            }

            if schedule.kind == .interval {
                Stepper(
                    "Every \(intervalDescription(schedule.normalizedIntervalMinutes))",
                    value: Binding(
                        get: { schedule.normalizedIntervalMinutes },
                        set: { onChange(nil, $0, nil, nil) }
                    ),
                    in: 1...10_080,
                    step: 60
                )
            } else {
                DatePicker(
                    "Start time",
                    selection: Binding(
                        get: { dateFor(minutes: schedule.normalizedScheduledTimeMinutes) },
                        set: {
                            let components = Calendar.current.dateComponents([.hour, .minute], from: $0)
                            onChange(nil, nil, nil, (components.hour ?? 0) * 60 + (components.minute ?? 0))
                        }
                    ),
                    displayedComponents: .hourAndMinute
                )
            }

            HStack(spacing: 7) {
                Text("Days")
                Spacer()
                ForEach(HeartbeatWeekday.allCases) { day in
                    let selected = schedule.normalizedWeekdayMask & day.bit != 0
                    Button(day.shortLabel) {
                        let changed = selected
                            ? schedule.normalizedWeekdayMask & ~day.bit
                            : schedule.normalizedWeekdayMask | day.bit
                        if changed != 0 { onChange(nil, nil, changed, nil) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(selected ? .accentColor : .gray.opacity(0.35))
                    .accessibilityLabel(day.accessibilityLabel)
                }
            }

            if let nextRunAt {
                Text("Next start: \(nextRunAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    private func dateFor(minutes: Int) -> Date {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: .now) ?? .now
    }

    private func intervalDescription(_ minutes: Int) -> String {
        if minutes.isMultiple(of: 60) {
            let hours = minutes / 60
            return hours == 1 ? "hour" : "\(hours) hours"
        }
        return minutes == 1 ? "minute" : "\(minutes) minutes"
    }
}
