import SwiftUI
import SwiftData

#if os(macOS)
import AppKit
#endif

struct AgentsPreferencesView: View {
    @ObservedObject var store: AgentStore
    @ObservedObject var localModelStore: LocalModelStore
    @ObservedObject var textToSpeechToolStore: TextToSpeechToolStore
    @ObservedObject var skillCatalog: SkillCatalog
    @ObservedObject var chatStore: ChatStore
    @ObservedObject var heartbeatScheduler: HeartbeatScheduler
    @State private var isPresentingEditor = false

    var body: some View {
        Group {
            if isPresentingEditor {
                agentEditor
            } else {
                agentList
            }
        }
        .background(OpenUITheme.background)
    }

    private var agentList: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .center) {
                Text("Agents")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(OpenUITheme.foreground)

                Spacer()

                Button {
                    store.addAgent()
                    isPresentingEditor = true
                } label: {
                    Label("Add Agent", systemImage: "plus")
                }
                .buttonStyle(OpenUIPrimaryButtonStyle())
            }

            VStack(spacing: 0) {
                ForEach(Array(store.agents.enumerated()), id: \.element.id) { index, agent in
                    Button {
                        store.selectedAgentID = agent.id
                        isPresentingEditor = true
                    } label: {
                        HStack {
                            Text(agent.displayName)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(OpenUITheme.foreground)
                                .lineLimit(1)

                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, 18)
                        .frame(minHeight: 56)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Edit \(agent.displayName)")

                    if index < store.agents.count - 1 {
                        OpenUIDivider()
                    }
                }
            }
            .openUICard()

            Spacer(minLength: 0)
        }
        .frame(maxWidth: 800, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 40)
        .padding(.vertical, 36)
    }

    private var agentEditor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 16) {
                    Button("Agents") {
                        isPresentingEditor = false
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(OpenUITheme.foregroundMuted)
                    .accessibilityHint("Return to the agent list")

                    Image(systemName: "chevron.right")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(OpenUITheme.foregroundSubtle)

                    Text(store.selectedAgent?.displayName ?? "Agent")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(OpenUITheme.foreground)
                        .lineLimit(1)
                }

                AgentEditor(
                    store: store,
                    localModelStore: localModelStore,
                    textToSpeechToolStore: textToSpeechToolStore,
                    skillCatalog: skillCatalog,
                    chatStore: chatStore,
                    heartbeatScheduler: heartbeatScheduler
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, 40)
            .padding(.vertical, 36)
        }
    }
}

private let minimumAgentTextEditorHeight: CGFloat = 170
private let maximumAgentTextEditorHeight: CGFloat = 720

struct AgentEditor: View {
    @ObservedObject var store: AgentStore
    @ObservedObject var localModelStore: LocalModelStore
    @ObservedObject var textToSpeechToolStore: TextToSpeechToolStore
    @ObservedObject var skillCatalog: SkillCatalog
    @ObservedObject var chatStore: ChatStore
    @ObservedObject var heartbeatScheduler: HeartbeatScheduler
    @ObservedObject private var calendarDirectory = CalendarDirectory.shared
    @State private var draftSoul = ""
    @State private var soulEditorHeight: CGFloat = 360
    @State private var draftMemory = ""
    @State private var memoryEditorHeight: CGFloat = 240

    private var selectedAgent: Agent? {
        store.selectedAgent
    }

    private var agentName: Binding<String> {
        Binding {
            selectedAgent?.name ?? ""
        } set: { newValue in
            guard let agentID = selectedAgent?.id else { return }
            store.updateAgentName(id: agentID, name: newValue)
        }
    }

    private var agentModel: Binding<String> {
        Binding {
            selectedAgent?.selectedModelIdentifier ?? ChatModelIdentifier.appleFoundation
        } set: { newValue in
            guard let agentID = selectedAgent?.id else { return }
            store.updateAgentModelIdentifier(id: agentID, modelIdentifier: newValue)
        }
    }

    private var voiceTriggerPhrasesText: Binding<String> {
        Binding {
            selectedAgent?.voiceTriggerPhrase ?? ""
        } set: { newValue in
            guard let agentID = selectedAgent?.id else { return }
            store.updateAgentVoiceTriggerPhrases(id: agentID, phrasesText: newValue)
        }
    }

    private var textToSpeechToolID: Binding<TextToSpeechTool.ID?> {
        Binding {
            selectedAgent?.textToSpeechToolID
        } set: { newValue in
            guard let agentID = selectedAgent?.id else { return }
            store.updateAgentTextToSpeechTool(id: agentID, toolID: newValue)
        }
    }

    private var textToSpeechVoiceName: Binding<String> {
        Binding {
            selectedAgent?.textToSpeechVoiceName ?? ""
        } set: { newValue in
            guard let agentID = selectedAgent?.id else { return }
            store.updateAgentTextToSpeechVoiceName(id: agentID, voiceName: newValue)
        }
    }

    private var textToSpeechVoiceModel: Binding<String> {
        Binding {
            selectedAgent?.textToSpeechVoiceModel ?? ""
        } set: { newValue in
            guard let agentID = selectedAgent?.id else { return }
            store.updateAgentTextToSpeechVoiceModel(id: agentID, voiceModel: newValue)
        }
    }

    private var hasUnsavedSoulChanges: Bool {
        draftSoul != selectedAgent?.soul
    }

    private var hasUnsavedMemoryChanges: Bool {
        draftMemory != selectedAgent?.memoryText
    }

    var body: some View {
        Group {
            if let selectedAgent {
                editor(for: selectedAgent)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 26))
                        .foregroundStyle(OpenUITheme.accent)

                    Text("Select or add an agent")
                        .font(.system(size: 15, weight: .semibold))

                    Text("Agent settings will appear here.")
                        .font(.system(size: 13))
                        .foregroundStyle(OpenUITheme.foregroundMuted)
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .openUICard()
            }
        }
        .onAppear {
            loadSelectedAgent()
            skillCatalog.reload()
            prepareCalendarsIfNeeded()
        }
        .onChange(of: store.selectedAgentID) {
            loadSelectedAgent()
            prepareCalendarsIfNeeded()
        }
    }

    private func editor(for agent: Agent) -> some View {
        VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    OpenUISectionHeader(
                        title: "Identity"
                        )

                    VStack(spacing: 0) {
                        OpenUISettingsRow(
                            title: "Name",
                            description: "Used in chat labels and @mentions."
                        ) {
                            TextField("Agent name", text: agentName)
                                .openUIInput()
                                .frame(width: 320)
                        }

                        OpenUIDivider()

                        OpenUISettingsRow(
                            title: "Default model",
                            description: "Heartbeats can override this selection individually."
                        ) {
                            Picker("Model", selection: agentModel) {
                                Text("Apple Foundation Model")
                                    .tag(ChatModelIdentifier.appleFoundation)

                                ForEach(localModelStore.localModels) { model in
                                    Text(model.displayName)
                                        .tag(ChatModelIdentifier.localModelID(model.id))
                                }

                                if !isSelectedModelConfigured(agent.selectedModelIdentifier) {
                                    Text("Missing local model")
                                        .tag(agent.selectedModelIdentifier)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 320)
                        }
                    }
                    .openUICard()
                }

                VStack(alignment: .leading, spacing: 10) {
                    OpenUISectionHeader(
                        title: "Soul",
                        description: "Your agent's personality and motivations."
                    )

                    VStack(spacing: 0) {
                        ResizableAgentTextEditor(
                            text: $draftSoul,
                            height: $soulEditorHeight,
                            resizeHelpText: "Resize Soul editor"
                        )
                            .padding(16)

                        OpenUIDivider()

                        HStack {
                            Text("Soul changes are applied when you save.")
                                .font(.system(size: 12))
                                .foregroundStyle(OpenUITheme.foregroundSubtle)

                            Spacer()

                            if hasUnsavedSoulChanges {
                                Button("Save Soul") {
                                    store.updateAgentSoul(id: agent.id, soul: draftSoul)
                                }
                                .buttonStyle(OpenUIPrimaryButtonStyle())
                            }
                        }
                        .padding(14)
                    }
                    .openUICard()
                }

                VStack(alignment: .leading, spacing: 10) {
                    OpenUISectionHeader(
                        title: "Voice",
                        description: "Configure voice input and text-to-speech output for this agent."
                    )

                    VStack(spacing: 0) {
                        OpenUISettingsRow(
                            title: "Key phrases",
                            description: "Enter one phrase per line. Voice mode ignores speech until it hears one."
                        ) {
                            ZStack(alignment: .topLeading) {
                                TextEditor(text: voiceTriggerPhrasesText)
                                    .font(.system(size: 14))
                                    .scrollContentBackground(.hidden)
                                    .padding(6)

                                if voiceTriggerPhrasesText.wrappedValue.isEmpty {
                                    Text("Hey \(agent.displayName)\nWake up \(agent.displayName)")
                                        .font(.system(size: 14))
                                        .foregroundStyle(OpenUITheme.foregroundSubtle)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 10)
                                        .allowsHitTesting(false)
                                }
                            }
                            .frame(height: 82)
                            .background(OpenUITheme.surface, in: RoundedRectangle(cornerRadius: 10))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(OpenUITheme.border, lineWidth: 1)
                            }
                            .frame(width: 320)
                        }

                        OpenUIDivider()

                        OpenUISettingsRow(
                            title: "Voice tool",
                            description: "Choose a tool configured in Text to Speech preferences."
                        ) {
                            Picker("Voice tool", selection: textToSpeechToolID) {
                                Text("None")
                                    .tag(nil as TextToSpeechTool.ID?)

                                ForEach(textToSpeechToolStore.tools) { tool in
                                    Text(tool.displayName)
                                        .tag(tool.id as TextToSpeechTool.ID?)
                                }

                                if let selectedToolID = agent.textToSpeechToolID,
                                   !textToSpeechToolStore.tools.contains(where: { $0.id == selectedToolID }) {
                                    Text("Missing tool")
                                        .tag(selectedToolID as TextToSpeechTool.ID?)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 320)
                        }

                        OpenUIDivider()

                        OpenUISettingsRow(
                            title: "Voice name",
                            description: "Free-form voice identifier passed to the selected tool."
                        ) {
                            TextField("Voice name", text: textToSpeechVoiceName)
                                .openUIInput()
                                .frame(width: 320)
                        }

                        OpenUIDivider()

                        OpenUISettingsRow(
                            title: "Voice model",
                            description: "Free-form model identifier passed to the selected tool."
                        ) {
                            TextField("Voice model", text: textToSpeechVoiceModel)
                                .openUIInput()
                                .frame(width: 320)
                        }
                    }
                    .openUICard()
                }

                VStack(alignment: .leading, spacing: 10) {
                    OpenUISectionHeader(
                        title: "Tools",
                        description: "Off until you enable them. The agent can only call tools that are on."
                    )

                    VStack(spacing: 0) {
                        ForEach(Array(AgentToolID.allCases.enumerated()), id: \.element.id) { index, toolID in
                            VStack(spacing: 0) {
                                OpenUISettingsRow(
                                    title: toolID.title,
                                    description: toolID.description
                                ) {
                                    Toggle(
                                        toolID.title,
                                        isOn: toolEnabled(toolID)
                                    )
                                    .toggleStyle(.switch)
                                    .labelsHidden()
                                    .tint(OpenUITheme.accent)
                                    .disabled(selectedAgent == nil)
                                }

                                if toolID == .readCalendarEvents,
                                   selectedAgent?.isToolEnabled(.readCalendarEvents) == true {
                                    OpenUIDivider()
                                    calendarAccessPanel
                                }

                                if index < AgentToolID.allCases.count - 1 {
                                    OpenUIDivider()
                                }
                            }
                        }
                    }
                    .openUICard()
                }

                VStack(alignment: .leading, spacing: 10) {
                    OpenUISectionHeader(
                        title: "Skills",
                        description: "Off until you enable them here. A skill must also be on in Settings."
                    )

                    if skillCatalog.enabledSkills.isEmpty {
                        VStack(spacing: 8) {
                            Text("No skills are enabled")
                                .font(.system(size: 14, weight: .medium))

                            Text("Turn on a skill in Settings → Skills, then it will appear here.")
                                .font(.system(size: 13))
                                .foregroundStyle(OpenUITheme.foregroundMuted)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                        .openUICard()
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(skillCatalog.enabledSkills.enumerated()), id: \.element.id) { index, skill in
                                OpenUISettingsRow(
                                    title: skill.name,
                                    description: skill.description.isEmpty
                                        ? "No description in SKILL.md."
                                        : skill.description
                                ) {
                                    Toggle(
                                        skill.name,
                                        isOn: skillEnabled(skill.name)
                                    )
                                    .toggleStyle(.switch)
                                    .labelsHidden()
                                    .tint(OpenUITheme.accent)
                                    .disabled(selectedAgent == nil)
                                }

                                if index < skillCatalog.enabledSkills.count - 1 {
                                    OpenUIDivider()
                                }
                            }
                        }
                        .openUICard()
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    OpenUISectionHeader(
                        title: "Diagnostics",
                        description: "Optional logs for inspecting prompts and tool traces."
                    )

                    VStack(spacing: 0) {
                        OpenUISettingsRow(
                            title: "Debug log",
                            description: "Store the full model prompt and intermediate output for this agent’s chats and heartbeats. Off by default — this is a lot of data."
                        ) {
                            Toggle("Debug log", isOn: debugLogEnabled)
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .tint(OpenUITheme.accent)
                                .disabled(selectedAgent == nil)
                        }
                    }
                    .openUICard()
                }

                VStack(alignment: .leading, spacing: 10) {
                    OpenUISectionHeader(
                        title: "Memory",
                        description: "You can edit all memory; the agent can only append new entries."
                    )

                    VStack(spacing: 0) {
                        ResizableAgentTextEditor(
                            text: $draftMemory,
                            height: $memoryEditorHeight,
                            resizeHelpText: "Resize Memory editor"
                        )
                            .padding(16)

                        OpenUIDivider()

                        HStack {
                            Text("Memory changes are applied when you save.")
                                .font(.system(size: 12))
                                .foregroundStyle(OpenUITheme.foregroundSubtle)

                            Spacer()

                            if hasUnsavedMemoryChanges {
                                Button("Save Memory") {
                                    store.updateAgentMemory(id: agent.id, memory: draftMemory)
                                }
                                .buttonStyle(OpenUIPrimaryButtonStyle())
                            }
                        }
                        .padding(14)
                    }
                    .openUICard()
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 16) {
                        OpenUISectionHeader(
                            title: "Heartbeats",
                            description: "Run recurring agent instructions while Chat is open."
                        )

                        Spacer()

                        Button {
                            store.addHeartbeat(to: agent.id)
                        } label: {
                            Label("Add heartbeat", systemImage: "plus")
                        }
                        .buttonStyle(OpenUISecondaryButtonStyle())
                    }

                    if store.heartbeats(for: agent.id).isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "waveform.path.ecg")
                                .font(.system(size: 22))
                                .foregroundStyle(OpenUITheme.foregroundSubtle)

                            Text("No heartbeats configured")
                                .font(.system(size: 14, weight: .medium))

                            Text("Add one to let this agent check in on a schedule.")
                                .font(.system(size: 13))
                                .foregroundStyle(OpenUITheme.foregroundMuted)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                        .openUICard()
                    } else {
                        VStack(spacing: 16) {
                            ForEach(store.heartbeats(for: agent.id)) { heartbeat in
                                AgentHeartbeatEditor(
                                    heartbeat: heartbeat,
                                    store: store,
                                    localModelStore: localModelStore,
                                    chatStore: chatStore,
                                    heartbeatScheduler: heartbeatScheduler
                                )
                            }
                        }
                    }
                }
        }
        .frame(maxWidth: 720, alignment: .topLeading)
    }

    private func loadSelectedAgent() {
        guard let selectedAgent else {
            draftSoul = ""
            draftMemory = ""
            return
        }

        load(selectedAgent)
    }

    private func load(_ agent: Agent) {
        draftSoul = agent.soul
        draftMemory = agent.memoryText
    }

    private func isSelectedModelConfigured(_ identifier: String) -> Bool {
        identifier == ChatModelIdentifier.appleFoundation || localModelStore.localModels.contains {
            ChatModelIdentifier.localModelID($0.id) == identifier
        }
    }

    private func toolEnabled(_ toolID: AgentToolID) -> Binding<Bool> {
        Binding {
            selectedAgent?.isToolEnabled(toolID) ?? false
        } set: { newValue in
            guard let agentID = selectedAgent?.id else { return }
            store.setTool(toolID, enabled: newValue, for: agentID)
            if toolID == .readCalendarEvents, newValue {
                Task { await calendarDirectory.prepare() }
            }
        }
    }

    private var calendarAccessAll: Binding<Bool> {
        Binding {
            selectedAgent?.allowsAllCalendars ?? true
        } set: { newValue in
            guard let agentID = selectedAgent?.id else { return }
            store.setCalendarAccessAll(
                newValue,
                selecting: newValue ? [] : calendarDirectory.calendars.map(\.id),
                for: agentID
            )
        }
    }

    @ViewBuilder
    private var calendarAccessPanel: some View {
        OpenUISettingsRow(
            title: "Calendars",
            description: calendarAccessDescription
        ) {
            HStack(spacing: 10) {
                if calendarDirectory.isRequestingAccess {
                    ProgressView()
                        .controlSize(.small)
                }

                Picker("Calendars", selection: calendarAccessAll) {
                    Text("All").tag(true)
                    Text("Selected").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
                .disabled(selectedAgent == nil)
            }
        }

        if let message = calendarDirectory.accessMessage {
            OpenUIDivider()
            OpenUISettingsRow(
                title: "Calendar access",
                description: message
            ) {
                if calendarDirectory.canRequestAccess {
                    Button("Allow") {
                        Task { await calendarDirectory.prepare() }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }

        if calendarAccessAll.wrappedValue == false, calendarDirectory.hasFullAccess {
            if calendarDirectory.calendars.isEmpty {
                OpenUIDivider()
                OpenUISettingsRow(
                    title: "No calendars",
                    description: "No calendars were found on this Mac."
                ) {
                    EmptyView()
                }
            } else {
                ForEach(calendarDirectory.calendars) { calendar in
                    OpenUIDivider()
                    OpenUISettingsRow(
                        title: calendar.title,
                        description: calendar.subtitle.isEmpty
                            ? "Stored as calendar ID \(calendar.calendarIdentifier)."
                            : calendar.subtitle
                    ) {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(
                                    Color(
                                        red: calendar.colorRed,
                                        green: calendar.colorGreen,
                                        blue: calendar.colorBlue
                                    )
                                )
                                .frame(width: 8, height: 8)
                            Toggle(
                                calendar.title,
                                isOn: calendarAllowed(calendar.calendarIdentifier)
                            )
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .tint(OpenUITheme.accent)
                            .disabled(selectedAgent == nil)
                        }
                    }
                }
            }
        }
    }

    private var calendarAccessDescription: String {
        if selectedAgent?.allowsAllCalendars ?? true {
            if calendarDirectory.hasFullAccess {
                let count = calendarDirectory.calendars.count
                if count == 1 {
                    return "This agent can read the 1 calendar Chat can access."
                }
                return "This agent can read all \(count) calendars Chat can access."
            }
            return "This agent can read every calendar Chat is allowed to access."
        }
        let selectedCount = selectedAgent?.allowedCalendarIDs.count ?? 0
        if selectedCount == 0 {
            return "No calendars are selected. The agent will not be able to read events until you pick at least one."
        }
        if selectedCount == 1 {
            return "This agent can read 1 selected calendar. Names are shown here; the agent uses calendar IDs."
        }
        return "This agent can read \(selectedCount) selected calendars. Names are shown here; the agent uses calendar IDs."
    }

    private func calendarAllowed(_ calendarID: String) -> Binding<Bool> {
        Binding {
            selectedAgent?.allowedCalendarIDs.contains(calendarID) ?? false
        } set: { newValue in
            guard let agentID = selectedAgent?.id else { return }
            store.setAllowedCalendarID(calendarID, enabled: newValue, for: agentID)
        }
    }

    private func prepareCalendarsIfNeeded() {
        guard selectedAgent?.isToolEnabled(.readCalendarEvents) == true else { return }
        Task { await calendarDirectory.prepare() }
    }

    private func skillEnabled(_ skillID: String) -> Binding<Bool> {
        Binding {
            selectedAgent?.isSkillEnabled(skillID) ?? false
        } set: { newValue in
            guard let agentID = selectedAgent?.id else { return }
            store.setSkill(skillID, enabled: newValue, for: agentID)
        }
    }

    private var debugLogEnabled: Binding<Bool> {
        Binding {
            selectedAgent?.isDebugLogEnabled ?? false
        } set: { newValue in
            guard let agentID = selectedAgent?.id else { return }
            store.updateAgentDebugLog(id: agentID, enabled: newValue)
        }
    }
}

struct AgentHeartbeatEditor: View {
    private static let executionHistoryLimit = 50

    let heartbeat: AgentHeartbeat
    @ObservedObject var store: AgentStore
    @ObservedObject var localModelStore: LocalModelStore
    @ObservedObject var chatStore: ChatStore
    @ObservedObject var heartbeatScheduler: HeartbeatScheduler
    @Query private var executions: [HeartbeatRun]

    init(
        heartbeat: AgentHeartbeat,
        store: AgentStore,
        localModelStore: LocalModelStore,
        chatStore: ChatStore,
        heartbeatScheduler: HeartbeatScheduler
    ) {
        self.heartbeat = heartbeat
        _store = ObservedObject(wrappedValue: store)
        _localModelStore = ObservedObject(wrappedValue: localModelStore)
        _chatStore = ObservedObject(wrappedValue: chatStore)
        _heartbeatScheduler = ObservedObject(wrappedValue: heartbeatScheduler)
        let heartbeatID = heartbeat.id
        var descriptor = FetchDescriptor<HeartbeatRun>(
            predicate: #Predicate { $0.heartbeatID == heartbeatID },
            sortBy: [SortDescriptor(\.completedAt, order: .reverse)]
        )
        descriptor.fetchLimit = Self.executionHistoryLimit
        _executions = Query(descriptor)
    }

    private var runningHeartbeat: RunningHeartbeat? {
        heartbeatScheduler.runningHeartbeats.first { $0.id == heartbeat.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Heartbeat")
                        .font(.system(size: 15, weight: .semibold))

                    Text("Runs every \(heartbeat.normalizedIntervalMinutes) minutes")
                        .font(.system(size: 12))
                        .foregroundStyle(OpenUITheme.foregroundSubtle)
                        .monospacedDigit()
                }

                Spacer()

                Toggle("Enabled", isOn: isEnabled)
                    .toggleStyle(.switch)
                    .tint(OpenUITheme.accent)

                Button(role: .destructive) {
                    store.removeHeartbeat(heartbeat)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .buttonStyle(OpenUIDangerButtonStyle())
            }
            .padding(16)

            OpenUIDivider()

            VStack(alignment: .leading, spacing: 7) {
                Text("Instruction")
                    .font(.system(size: 14, weight: .medium))

                Text("Tell the agent what to consider when this heartbeat runs.")
                    .font(.system(size: 13))
                    .foregroundStyle(OpenUITheme.foregroundMuted)

                TextEditor(text: instruction)
                    .font(.system(size: 14))
                    .frame(minHeight: 76, maxHeight: 110)
                    .padding(8)
                    .scrollContentBackground(.hidden)
                    .background(OpenUITheme.surfaceMuted, in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(OpenUITheme.border, lineWidth: 1)
                    }
            }
            .padding(16)

            OpenUIDivider()

            OpenUISettingsRow(
                title: "Model",
                description: "Override the agent's default for this heartbeat."
            ) {
                Picker("Model", selection: modelIdentifier) {
                    Text("Agent default (\(agentDefaultModelName))")
                        .tag("")

                    Section("Override") {
                        Text("Apple Foundation Model")
                            .tag(ChatModelIdentifier.appleFoundation)

                        ForEach(localModelStore.localModels) { model in
                            Text(model.displayName)
                                .tag(ChatModelIdentifier.localModelID(model.id))
                        }
                    }

                    if let selectedIdentifier = heartbeat.modelIdentifier,
                       !isModelConfigured(selectedIdentifier) {
                        Text("Missing local model")
                            .tag(selectedIdentifier)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 300)
            }

            OpenUIDivider()

            OpenUISettingsRow(
                title: "Schedule",
                description: "Choose an interval from one minute to one week."
            ) {
                Stepper(value: intervalMinutes, in: 1...10_080) {
                    Text("Every \(heartbeat.normalizedIntervalMinutes) minutes")
                        .font(.system(size: 13))
                        .monospacedDigit()
                }
                .frame(width: 300)
            }

            OpenUIDivider()

            OpenUISettingsRow(
                title: "Post to",
                description: "Heartbeats post to this agent's default chat unless you pick another chat."
            ) {
                Picker("Post to", selection: destination) {
                    Text("Default chat")
                        .tag("private")

                    if !extraDirectChats.isEmpty {
                        Section("Other chats") {
                            ForEach(extraDirectChats) { chat in
                                Text(chat.title)
                                    .tag("direct.\(chat.id.uuidString)")
                            }
                        }
                    }

                    if !chatStore.groupChats.isEmpty {
                        Section("Group chats") {
                            ForEach(chatStore.groupChats) { chat in
                                Text(chat.title)
                                    .tag("group.\(chat.id.uuidString)")
                            }
                        }
                    }

                    if heartbeat.targetKind == .privateChat,
                       let targetChatID = heartbeat.targetChatID,
                       !extraDirectChats.contains(where: { $0.id == targetChatID }) {
                        Text("Missing private chat")
                            .tag("direct.\(targetChatID.uuidString)")
                    }

                    if heartbeat.targetKind == .groupChat,
                       let targetChatID = heartbeat.targetChatID,
                       !chatStore.groupChats.contains(where: { $0.id == targetChatID }) {
                        Text("Missing group chat")
                            .tag("group.\(targetChatID.uuidString)")
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 300)
            }

            OpenUIDivider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Executions")
                    .font(.system(size: 14, weight: .medium))

                Text("Each run is recorded even if the agent posts nothing. Open a run to view tools and the debug log.")
                    .font(.system(size: 13))
                    .foregroundStyle(OpenUITheme.foregroundMuted)

                if runningHeartbeat != nil || !executions.isEmpty {
                    VStack(spacing: 0) {
                        if let runningHeartbeat {
                            HeartbeatRunningExecutionRow(startedAt: runningHeartbeat.startedAt)
                            if !executions.isEmpty {
                                OpenUIDivider()
                            }
                        }

                        ForEach(Array(executions.enumerated()), id: \.element.id) { index, run in
                            if index > 0 {
                                OpenUIDivider()
                            }
                            HeartbeatExecutionRow(run: run)
                        }
                    }
                    .padding(.top, 4)
                } else {
                    Text("No executions yet. The agent may post a reply, append memory, or pass.")
                        .font(.system(size: 13))
                        .foregroundStyle(OpenUITheme.foregroundSubtle)
                        .padding(.top, 4)
                }
            }
            .padding(16)
        }
        .openUICard()
    }

    private var instruction: Binding<String> {
        Binding(
            get: { heartbeat.instruction },
            set: { store.updateHeartbeatInstruction(heartbeat, instruction: $0) }
        )
    }

    private var intervalMinutes: Binding<Int> {
        Binding(
            get: { heartbeat.normalizedIntervalMinutes },
            set: { store.updateHeartbeatInterval(heartbeat, minutes: $0) }
        )
    }

    private var isEnabled: Binding<Bool> {
        Binding(
            get: { heartbeat.isEnabled },
            set: { store.updateHeartbeatEnabled(heartbeat, isEnabled: $0) }
        )
    }

    private var modelIdentifier: Binding<String> {
        Binding(
            get: { heartbeat.modelIdentifier ?? "" },
            set: {
                store.updateHeartbeatModelIdentifier(
                    heartbeat,
                    modelIdentifier: $0.isEmpty ? nil : $0
                )
            }
        )
    }

    private var extraDirectChats: [ChatViewModel] {
        chatStore.extraChats(for: heartbeat.agentID)
    }

    private var agentDefaultModelName: String {
        guard let agent = store.agent(for: heartbeat.agentID) else {
            return "Missing agent"
        }
        return localModelStore.displayName(for: agent.selectedModelIdentifier)
    }

    private func isModelConfigured(_ identifier: String) -> Bool {
        identifier == ChatModelIdentifier.appleFoundation || localModelStore.localModels.contains {
            ChatModelIdentifier.localModelID($0.id) == identifier
        }
    }

    private var destination: Binding<String> {
        Binding {
            guard let targetChatID = heartbeat.targetChatID else {
                return "private"
            }
            if heartbeat.targetKind == .groupChat {
                return "group.\(targetChatID.uuidString)"
            }
            return "direct.\(targetChatID.uuidString)"
        } set: { newValue in
            if newValue.hasPrefix("group."),
               let targetChatID = UUID(uuidString: String(newValue.dropFirst("group.".count))) {
                store.updateHeartbeatDestination(
                    heartbeat,
                    targetKind: .groupChat,
                    targetChatID: targetChatID
                )
                return
            }
            if newValue.hasPrefix("direct."),
               let targetChatID = UUID(uuidString: String(newValue.dropFirst("direct.".count))) {
                store.updateHeartbeatDestination(
                    heartbeat,
                    targetKind: .privateChat,
                    targetChatID: targetChatID
                )
                return
            }
            store.updateHeartbeatDestination(
                heartbeat,
                targetKind: .privateChat,
                targetChatID: nil
            )
        }
    }
}

private struct HeartbeatRunningExecutionRow: View {
    let startedAt: Date

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text("Running")
                    .font(.system(size: 13, weight: .medium))

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(elapsedText(at: context.date))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(OpenUITheme.foregroundSubtle)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }

    private func elapsedText(at date: Date) -> String {
        let elapsedSeconds = max(0, Int(date.timeIntervalSince(startedAt)))
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        return String(format: "Elapsed %d:%02d", minutes, seconds)
    }
}

private struct HeartbeatExecutionRow: View {
    let run: HeartbeatRun

    @Environment(\.modelContext) private var modelContext
    @State private var turn: GenerationTurn?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: run.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(run.succeeded ? Color(red: 22 / 255, green: 163 / 255, blue: 74 / 255) : OpenUITheme.warningForeground)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(run.completedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 13, weight: .medium))

                Text(run.errorMessage ?? run.actionSummary)
                    .font(.system(size: 12))
                    .foregroundStyle(run.succeeded ? OpenUITheme.foregroundMuted : OpenUITheme.warningForeground)
                    .lineLimit(2)

                Text(HeartbeatRun.metricsLine(duration: run.formattedDuration, tokens: run.formattedTokenUsage))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(OpenUITheme.foregroundSubtle)
                    .help(run.tokenUsageHelp ?? "Duration of this heartbeat run")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let turn {
                GenerationInspectorButton(turn: turn)
            }
        }
        .padding(.vertical, 10)
        .task(id: run.id) {
            loadTurn()
        }
    }

    private func loadTurn() {
        guard let turnID = run.generationTurnID else {
            turn = nil
            return
        }
        turn = GenerationQuery.fetchTurn(id: turnID, in: modelContext)
    }
}

struct ResizableAgentTextEditor: View {
    @Binding var text: String
    @Binding var height: CGFloat
    let resizeHelpText: String
    @State private var dragStartHeight: CGFloat?

    var body: some View {
        SoulTextView(text: $text)
            .padding(12)
            .padding(.bottom, 8)
            .background(OpenUITheme.surfaceMuted, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(OpenUITheme.border, lineWidth: 1)
            }
            .overlay(alignment: .bottomTrailing) {
                ResizeGrip(helpText: resizeHelpText)
                    .padding(5)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let startHeight = dragStartHeight ?? height
                                dragStartHeight = startHeight
                                height = min(
                                    max(startHeight + value.translation.height, minimumAgentTextEditorHeight),
                                    maximumAgentTextEditorHeight
                                )
                            }
                            .onEnded { _ in
                                dragStartHeight = nil
                            }
                    )
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
    }
}

#if os(macOS)
struct SoulTextView: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        textView.delegate = context.coordinator
        textView.string = text
        textView.font = .systemFont(ofSize: 15)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = .zero
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        if textView.string != text {
            textView.string = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }
    }
}
#else
struct SoulTextView: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 15))
            .scrollContentBackground(.hidden)
            .scrollIndicators(.automatic)
    }
}
#endif

struct ResizeGrip: View {
    let helpText: String

    var body: some View {
        Canvas { context, size in
            let stroke = StrokeStyle(lineWidth: 1.2, lineCap: .round)
            let color = Color.gray.opacity(0.55)

            for offset in stride(from: 0.0, through: 8.0, by: 4.0) {
                var path = Path()
                path.move(to: CGPoint(x: size.width - offset, y: size.height))
                path.addLine(to: CGPoint(x: size.width, y: size.height - offset))
                context.stroke(path, with: .color(color), style: stroke)
            }
        }
        .frame(width: 14, height: 14)
        .contentShape(Rectangle())
        .help(helpText)
    }
}

#Preview("Agents Preferences") {
    AgentsPreferencesViewPreview()
}

private struct AgentsPreferencesViewPreview: View {
    private let modelContainer: ModelContainer
    private let agentStore: AgentStore
    private let localModelStore: LocalModelStore
    private let textToSpeechToolStore: TextToSpeechToolStore
    private let skillCatalog: SkillCatalog
    private let chatStore: ChatStore
    private let heartbeatScheduler: HeartbeatScheduler

    init() {
        do {
            let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
            let container = try ChatModelContainer.make(configuration: configuration)
            let context = container.mainContext
            let localModel = LocalModel(
                name: "Studio Qwen",
                endpoint: "http://127.0.0.1:1234/v1",
                modelID: "qwen3-8b"
            )
            context.insert(localModel)
            context.insert(
                TextToSpeechTool(
                    name: "Studio Voice",
                    path: "/usr/local/bin/studio-voice"
                )
            )

            for name in ["Joe", "Maya", "Rowan", "Sam"] {
                context.insert(
                    Agent(
                        name: name,
                        soul: "Be a thoughtful participant in the conversation.",
                        modelIdentifier: ChatModelIdentifier.localModelID(localModel.id)
                    )
                )
            }
            try context.save()

            let agentStore = AgentStore(modelContext: context)
            let localModelStore = LocalModelStore(modelContext: context)
            let textToSpeechToolStore = TextToSpeechToolStore(modelContext: context)
            let skillCatalog = SkillCatalog()
            let replyFilterStore = ReplyFilterStore(modelContext: context)
            modelContainer = container
            self.agentStore = agentStore
            self.localModelStore = localModelStore
            self.textToSpeechToolStore = textToSpeechToolStore
            self.skillCatalog = skillCatalog
            chatStore = ChatStore(
                agentStore: agentStore,
                localModelStore: localModelStore,
                skillCatalog: skillCatalog,
                replyFilterStore: replyFilterStore,
                modelContext: context
            )
            heartbeatScheduler = HeartbeatScheduler(agentStore: agentStore, chatStore: chatStore)
        } catch {
            fatalError("Failed to create Agents preferences preview: \(error.localizedDescription)")
        }
    }

    var body: some View {
        AgentsPreferencesView(
            store: agentStore,
            localModelStore: localModelStore,
            textToSpeechToolStore: textToSpeechToolStore,
            skillCatalog: skillCatalog,
            chatStore: chatStore,
            heartbeatScheduler: heartbeatScheduler
        )
        .modelContainer(modelContainer)
        .frame(width: 900, height: 680)
    }
}
