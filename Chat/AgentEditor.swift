import ShadSwift
import AppKit
import Foundation
import SwiftUI
import SwiftData

struct AgentsPreferencesView: View {
    @ObservedObject var store: AgentStore
    @ObservedObject var localModelStore: LocalModelStore
    @ObservedObject var textToSpeechToolStore: TextToSpeechToolStore
    @ObservedObject var skillCatalog: SkillCatalog
    @ObservedObject var chatStore: ChatStore
    @ObservedObject var heartbeatScheduler: HeartbeatScheduler
    @ObservedObject var dreamScheduler: DreamScheduler
    @State private var isPresentingEditor = false
    @State private var avatarEditorState = ShadAvatarEditorState()
    @State private var editingHeartbeatID: AgentHeartbeat.ID?
    @State private var agentBeingDuplicatedID: Agent.ID?
    @State private var duplicateAgentNameDraft = ""
    @State private var duplicateAgentDialogIsPresented = false
    @State private var agentPendingDeleteID: Agent.ID?
    @State private var deleteAgentDialogIsPresented = false
    @Query(sort: \AgentInvocationRecord.startedAt, order: .reverse)
    private var collaborationInvocations: [AgentInvocationRecord]
    @Environment(\.shadTheme) private var theme

    private var editingHeartbeat: AgentHeartbeat? {
        guard let editingHeartbeatID else { return nil }
        return store.heartbeats.first { $0.id == editingHeartbeatID }
    }

    private var heartbeatEditorIsPresented: Binding<Bool> {
        Binding(
            get: { editingHeartbeat != nil },
            set: { isPresented in
                if !isPresented {
                    editingHeartbeatID = nil
                }
            }
        )
    }

    var body: some View {
        Group {
            if isPresentingEditor {
                agentEditor
            } else {
                agentList
            }
        }
        .background(theme.colors.background)
        .shadAvatarEditor(
            $avatarEditorState,
            title: "Agent avatar",
            description: "Drop an image onto the circle, then drag and zoom to choose its framing.",
            saveTitle: "Save Avatar",
            onSave: saveAvatar
        )
        .shadDialog(isPresented: heartbeatEditorIsPresented) {
            heartbeatEditorDialog
        }
        .shadDialog(isPresented: $duplicateAgentDialogIsPresented) {
            duplicateAgentDialog
        }
        .shadAlertDialog(isPresented: $deleteAgentDialogIsPresented) {
            deleteAgentDialog
        }
        .onChange(of: store.selectedAgentID) {
            editingHeartbeatID = nil
        }
        .onChange(of: store.heartbeats.map(\.id)) {
            guard let editingHeartbeatID,
                  !store.heartbeats.contains(where: { $0.id == editingHeartbeatID }) else {
                return
            }
            self.editingHeartbeatID = nil
        }
        .onChange(of: store.agents.map(\.id)) {
            if let agentBeingDuplicatedID,
               !store.agents.contains(where: { $0.id == agentBeingDuplicatedID }) {
                finishDuplicatingAgent()
            }
            if let agentPendingDeleteID,
               !store.agents.contains(where: { $0.id == agentPendingDeleteID }) {
                finishDeletingAgent()
            }
        }
    }

    private var agentList: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .center) {
                Text("Agents")
                    .font(theme.font(theme.typography.xxl, theme.typography.semibold))
                    .foregroundStyle(theme.colors.foreground)

                Spacer()

                ShadButton("Add Agent", icon: .plus) {
                    store.addAgent()
                    isPresentingEditor = true
                }
            }

            VStack(spacing: 0) {
                ForEach(Array(store.agents.enumerated()), id: \.element.id) { index, agent in
                    ShadItem(size: .sm, action: {
                        store.selectedAgentID = agent.id
                        isPresentingEditor = true
                    }) {
                        ShadItemMedia {
                            AgentAvatar(agent: agent, size: 32)
                        }
                        ShadItemContent {
                            ShadItemTitle(agent.displayName)
                        }
                        if store.isDefaultAgent(agent) {
                            ShadItemActions {
                                ShadBadge("Default", variant: .secondary)
                            }
                        }
                    }
                    .accessibilityLabel("Edit \(agent.displayName)")
                    .contextMenu {
                        Button("Duplicate…") {
                            beginDuplicating(agent)
                        }

                        Divider()

                        Button("Delete…", role: .destructive) {
                            beginDeleting(agent)
                        }
                        .disabled(!canBeginDeleting(agent))
                    }

                    if index < store.agents.count - 1 {
                        ShadSeparator()
                    }
                }
            }
            .shadSettingsCard()

            Spacer(minLength: 0)
        }
        .frame(maxWidth: 800, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 40)
        .padding(.vertical, 36)
    }

    private var agentEditor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ShadBreadcrumb {
                    ShadBreadcrumbList {
                        ShadBreadcrumbItem {
                            ShadBreadcrumbLink("Agents", icon: .users) {
                                editingHeartbeatID = nil
                                isPresentingEditor = false
                            }
                            .accessibilityHint("Return to the agent list")
                        }
                        ShadBreadcrumbSeparator()
                        ShadBreadcrumbItem {
                            ShadBreadcrumbPage(store.selectedAgent?.displayName ?? "Agent")
                        }
                    }
                }

                AgentEditor(
                    store: store,
                    localModelStore: localModelStore,
                    textToSpeechToolStore: textToSpeechToolStore,
                    skillCatalog: skillCatalog,
                    chatStore: chatStore,
                    heartbeatScheduler: heartbeatScheduler,
                    dreamScheduler: dreamScheduler,
                    avatarEditorState: $avatarEditorState,
                    onEditHeartbeat: { heartbeatID in
                        editingHeartbeatID = heartbeatID
                    },
                    onAgentDeleted: {
                        editingHeartbeatID = nil
                        isPresentingEditor = false
                    }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, 40)
            .padding(.vertical, 36)
        }
    }

    private func saveAvatar(_ photo: ShadAvatarPhoto) {
        guard let agentID = store.selectedAgent?.id else { return }

        let imageData = photo.persistentImageData
        guard photo.image == nil || imageData != nil else { return }

        store.updateAgentAvatar(
            id: agentID,
            imageData: imageData,
            cropZoom: photo.crop.zoom,
            cropOffsetX: Double(photo.crop.offset.width),
            cropOffsetY: Double(photo.crop.offset.height)
        )
    }

    @ViewBuilder
    private var duplicateAgentDialog: some View {
        ShadDialogContent(maxWidth: 420, showsCloseButton: false) {
            ShadDialogHeader {
                ShadDialogTitle("Duplicate agent")
                ShadDialogDescription(
                    "Copy this agent's setup into a new agent. Chats, heartbeats, stash entries, and collaboration history won't be copied."
                )
            }
            ShadInput(
                "Agent name",
                text: $duplicateAgentNameDraft,
                onSubmit: duplicateAgent
            )
            .accessibilityLabel("Agent name")
            ShadDialogFooter {
                ShadDialogClose("Cancel") {
                    finishDuplicatingAgent()
                }
                ShadButton("Duplicate", action: duplicateAgent)
                    .disabled(duplicateAgentNameIsEmpty)
            }
        }
    }

    @ViewBuilder
    private var deleteAgentDialog: some View {
        if let agent = agentPendingDelete {
            ShadAlertDialogContent {
                ShadAlertDialogTitle("Delete \(agent.displayName)?")
                ShadAlertDialogDescription(
                    "The agent and its heartbeat schedules will be deleted. Existing messages and generation history are preserved. This cannot be undone."
                )
            } actions: {
                ShadAlertDialogCancel {
                    finishDeletingAgent()
                }
                ShadAlertDialogAction("Delete Agent", variant: .destructive) {
                    confirmAgentDeletion(agent)
                }
            }
        }
    }

    private var agentBeingDuplicated: Agent? {
        agentBeingDuplicatedID.flatMap(store.agent(for:))
    }

    private var agentPendingDelete: Agent? {
        agentPendingDeleteID.flatMap(store.agent(for:))
    }

    private var duplicateAgentNameIsEmpty: Bool {
        duplicateAgentNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func beginDuplicating(_ agent: Agent) {
        agentBeingDuplicatedID = agent.id
        duplicateAgentNameDraft = "\(agent.displayName) Copy"
        duplicateAgentDialogIsPresented = true
    }

    private func finishDuplicatingAgent() {
        agentBeingDuplicatedID = nil
        duplicateAgentNameDraft = ""
        duplicateAgentDialogIsPresented = false
    }

    private func duplicateAgent() {
        guard !duplicateAgentNameIsEmpty,
              let source = agentBeingDuplicated,
              store.duplicateAgent(source, named: duplicateAgentNameDraft) != nil else {
            return
        }
        finishDuplicatingAgent()
        isPresentingEditor = true
    }

    private func canBeginDeleting(_ agent: Agent) -> Bool {
        store.canDeleteAgent(agent) && !hasActiveWork(for: agent)
    }

    private func hasActiveWork(for agent: Agent) -> Bool {
        let hasRunningHeartbeat = heartbeatScheduler.runningHeartbeats.contains {
            $0.agentID == agent.id
        }
        let hasActiveDirectChat = chatStore.chats(for: agent.id).contains {
            $0.isResponding || $0.isCompacting
        }
        let hasActiveGroupChat = chatStore.groupChats.contains { chat in
            (chat.isResponding || chat.isCompacting)
                && chat.groupParticipants.contains { $0.agentID == agent.id }
        }
        let hasActiveDelegatedWork = collaborationInvocations.contains {
            ($0.callerAgentID == agent.id || $0.targetAgentID == agent.id)
                && ($0.state == .queued || $0.state == .running)
        }
        return hasRunningHeartbeat
            || hasActiveDirectChat
            || hasActiveGroupChat
            || hasActiveDelegatedWork
    }

    private func beginDeleting(_ agent: Agent) {
        guard canBeginDeleting(agent) else { return }
        agentPendingDeleteID = agent.id
        deleteAgentDialogIsPresented = true
    }

    private func finishDeletingAgent() {
        agentPendingDeleteID = nil
        deleteAgentDialogIsPresented = false
    }

    private func confirmAgentDeletion(_ agent: Agent) {
        guard canBeginDeleting(agent) else {
            finishDeletingAgent()
            return
        }

        let agentID = agent.id
        var deactivationPlan: ChatStore.AgentDeactivationPlan?
        guard store.removeAgent(
            id: agentID,
            beforeSaving: {
                deactivationPlan = chatStore.stageAgentDeactivation(agentID)
            }
        ) else {
            return
        }

        guard let deactivationPlan else { return }
        let deletedChatWasSelected = chatStore.applyAgentDeactivation(deactivationPlan)
        if deletedChatWasSelected, let nextAgent = store.selectedAgent {
            chatStore.selectDefaultChat(for: nextAgent)
        }
        finishDeletingAgent()
    }

    @ViewBuilder
    private var heartbeatEditorDialog: some View {
        if let editingHeartbeat {
            HeartbeatEditorDialog(
                heartbeat: editingHeartbeat,
                store: store,
                localModelStore: localModelStore,
                chatStore: chatStore,
                heartbeatScheduler: heartbeatScheduler
            )
            .id(editingHeartbeat.id)
        }
    }
}

private let minimumAgentTextEditorHeight: CGFloat = 170
private let maximumAgentTextEditorHeight: CGFloat = 720

private enum VoiceToolChoice: Hashable {
    case none
    case tool(TextToSpeechTool.ID)
}

private enum AgentEditorTab: String, CaseIterable, Hashable {
    case identity = "Identity"
    case soul = "Soul"
    case memory = "Memory"
    case stash = "Stash"
    case voice = "Voice"
    case tools = "Tools"
    case skills = "Skills"
    case collaboration = "Collaboration"
    case heartbeats = "Heartbeats"
    case dreams = "Dream"
    case advanced = "Advanced"
}

struct AgentEditor: View {
    @ObservedObject var store: AgentStore
    @ObservedObject var localModelStore: LocalModelStore
    @ObservedObject var textToSpeechToolStore: TextToSpeechToolStore
    @ObservedObject var skillCatalog: SkillCatalog
    @ObservedObject var chatStore: ChatStore
    @ObservedObject var heartbeatScheduler: HeartbeatScheduler
    @ObservedObject var dreamScheduler: DreamScheduler
    @Binding var avatarEditorState: ShadAvatarEditorState
    @Query(sort: \AgentInvocationRecord.startedAt, order: .reverse)
    private var collaborationInvocations: [AgentInvocationRecord]
    var onEditHeartbeat: (AgentHeartbeat.ID) -> Void = { _ in }
    var onAgentDeleted: () -> Void = {}
    @ObservedObject private var calendarDirectory = CalendarDirectory.shared
    @State private var selectedTab = AgentEditorTab.identity
    @State private var draftSoul = ""
    @State private var soulEditorHeight: CGFloat = 360
    @State private var draftMemory = ""
    @State private var memoryEditorHeight: CGFloat = 240
    @State private var deleteDialogIsPresented = false
    @Environment(\.shadTheme) private var theme

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

    private var routingDescription: Binding<String> {
        Binding {
            selectedAgent?.routingDescriptionText ?? ""
        } set: { newValue in
            guard let agentID = selectedAgent?.id else { return }
            store.updateAgentRoutingDescription(
                id: agentID,
                routingDescription: newValue
            )
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

    private var optionalAgentModel: Binding<String?> {
        Binding(
            get: { agentModel.wrappedValue },
            set: { value in
                guard let value else { return }
                agentModel.wrappedValue = value
            }
        )
    }

    private var agentModelOptions: [ShadSelectOption<String>] {
        var options = localModelStore.selectableModels.map { model in
            ShadSelectOption(model.displayName, value: model.identifier)
        }
        if let identifier = selectedAgent?.selectedModelIdentifier,
           !options.contains(where: { $0.value == identifier }) {
            options.append(
                ShadSelectOption(localModelStore.displayName(for: identifier), value: identifier)
            )
        }
        return options
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

    private var voiceToolChoice: Binding<VoiceToolChoice?> {
        Binding(
            get: {
                if let id = textToSpeechToolID.wrappedValue {
                    return .tool(id)
                }
                return VoiceToolChoice.none
            },
            set: { choice in
                guard let choice else { return }
                switch choice {
                case .none:
                    textToSpeechToolID.wrappedValue = nil
                case .tool(let id):
                    textToSpeechToolID.wrappedValue = id
                }
            }
        )
    }

    private var voiceToolOptions: [ShadSelectOption<VoiceToolChoice>] {
        var options = [ShadSelectOption("None", value: VoiceToolChoice.none)]
        options.append(contentsOf: textToSpeechToolStore.tools.map { tool in
            ShadSelectOption(tool.displayName, value: VoiceToolChoice.tool(tool.id))
        })
        if let selectedToolID = selectedAgent?.textToSpeechToolID,
           !textToSpeechToolStore.tools.contains(where: { $0.id == selectedToolID }) {
            options.append(ShadSelectOption("Missing tool", value: VoiceToolChoice.tool(selectedToolID)))
        }
        return options
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
                    ShadIconView(.custom("person.crop.circle.badge.plus"), size: theme.typography.xxl)
                        .foregroundStyle(theme.colors.primary)

                    Text("Select or add an agent")
                        .font(theme.font(theme.typography.base, theme.typography.semibold))

                    Text("Agent settings will appear here.")
                        .font(theme.font(theme.typography.sm))
                        .foregroundStyle(theme.colors.mutedForeground)
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .shadSettingsCard()
            }
        }
        .onAppear {
            loadSelectedAgent()
            skillCatalog.reload()
            prepareCalendarsIfNeeded()
        }
        .onChange(of: store.selectedAgentID) {
            selectedTab = .identity
            deleteDialogIsPresented = false
            loadSelectedAgent()
            prepareCalendarsIfNeeded()
        }
        .onReceive(store.agentSoulDidChange) { agentID in
            guard selectedAgent?.id == agentID,
                  let agent = store.agent(for: agentID) else { return }
            draftSoul = agent.soul
        }
    }

    private func editor(for agent: Agent) -> some View {
        ShadTabs(selection: $selectedTab, variant: .line, spacing: 24) {
            ShadTabsList {
                ForEach(AgentEditorTab.allCases, id: \.self) { tab in
                    ShadTabsTrigger(tab.rawValue, value: tab)
                }
            }
            ShadTabsContent(value: AgentEditorTab.identity) {
                VStack(alignment: .leading, spacing: 10) {
                    ShadSettingsSectionHeader(
                        title: "Identity",
                        description: "Choose how this agent appears and which model it uses."
                    )

                    VStack(spacing: 0) {
                        ShadSettingsRow(
                            title: "Avatar",
                            description: "Add and crop an image, or choose the background color used by the placeholder avatar."
                        ) {
                            HStack(spacing: 10) {
                                let paletteEntry = AgentAvatarPalette.entry(for: agent, theme: theme)
                                ShadEditableAvatar(
                                    $avatarEditorState,
                                    fallback: agent.avatarInitials,
                                    customSize: 72
                                )
                                .shadTheme { localTheme in
                                    localTheme.colors.muted = paletteEntry.background
                                    localTheme.colors.mutedForeground = paletteEntry.foreground
                                }

                                if !avatarEditorState.photo.isEmpty {
                                    ShadButton("Remove", variant: .outline, size: .sm, icon: .trash) {
                                        removeAvatar(from: agent)
                                    }
                                    .accessibilityLabel("Remove avatar image")
                                } else {
                                    ColorPicker(
                                        "Placeholder color",
                                        selection: placeholderAvatarColor(for: agent),
                                        supportsOpacity: false
                                    )
                                    .labelsHidden()
                                    .accessibilityLabel("Placeholder avatar color")
                                }
                            }
                        }

                        ShadSeparator()

                        ShadSettingsRow(
                            title: "Name",
                            description: "Used in chat labels and @mentions."
                        ) {
                            ShadInput(
                                "Agent name",
                                text: agentName,
                                onSubmit: finalizeSelectedAgentHandle
                            )
                                .frame(width: 320)
                                .accessibilityLabel("Agent name")
                                .onDisappear(perform: finalizeSelectedAgentHandle)
                        }

                        ShadSeparator()

                        ShadSettingsRow(
                            title: "Default model",
                            description: "Used by the default chat and new chats. Heartbeats can override it."
                        ) {
                            ShadSelect(
                                selection: optionalAgentModel,
                                options: agentModelOptions,
                                width: 320
                            )
                            .accessibilityLabel("Default model")
                            .accessibilityValue(localModelStore.displayName(for: agent.selectedModelIdentifier))
                        }
                    }
                    .shadSettingsCard()
                }
            }

            ShadTabsContent(value: AgentEditorTab.soul) {
                VStack(alignment: .leading, spacing: 10) {
                    ShadSettingsSectionHeader(
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

                        ShadSeparator()

                        HStack {
                            Text("Soul changes are applied when you save.")
                                .font(theme.font(theme.typography.xs))
                                .foregroundStyle(theme.colors.mutedForeground)

                            Spacer()

                            if hasUnsavedSoulChanges {
                                ShadButton("Save Soul", size: .sm, icon: .check) {
                                    store.updateAgentSoul(id: agent.id, soul: draftSoul)
                                }
                            }
                        }
                        .padding(14)
                    }
                    .shadSettingsCard()
                }
            }

            ShadTabsContent(value: AgentEditorTab.voice) {
                VStack(alignment: .leading, spacing: 10) {
                    ShadSettingsSectionHeader(
                        title: "Voice",
                        description: "Configure voice input and text-to-speech output for this agent."
                    )

                    VStack(spacing: 0) {
                        ShadSettingsRow(
                            title: "Key phrases",
                            description: "Enter one phrase per line. Voice mode ignores speech until it hears one."
                        ) {
                            ShadTextarea(
                                "Hey \(agent.displayName)\nWake up \(agent.displayName)",
                                text: voiceTriggerPhrasesText,
                                minHeight: 64,
                                maxHeight: 64
                            )
                            .frame(width: 320)
                            .accessibilityLabel("Voice key phrases")
                        }

                        ShadSeparator()

                        ShadSettingsRow(
                            title: "Voice tool",
                            description: "Choose a tool configured in Text to Speech preferences."
                        ) {
                            ShadSelect(
                                selection: voiceToolChoice,
                                options: voiceToolOptions,
                                width: 320
                            )
                            .accessibilityLabel("Voice tool")
                        }

                        ShadSeparator()

                        ShadSettingsRow(
                            title: "Voice name",
                            description: "Free-form voice identifier passed to the selected tool."
                        ) {
                            ShadInput("Voice name", text: textToSpeechVoiceName)
                                .frame(width: 320)
                                .accessibilityLabel("Voice name")
                        }

                        ShadSeparator()

                        ShadSettingsRow(
                            title: "Voice model",
                            description: "Free-form model identifier passed to the selected tool."
                        ) {
                            ShadInput("Voice model", text: textToSpeechVoiceModel)
                                .frame(width: 320)
                                .accessibilityLabel("Voice model")
                        }
                    }
                    .shadSettingsCard()
                }
            }

            ShadTabsContent(value: AgentEditorTab.tools) {
                VStack(alignment: .leading, spacing: 10) {
                    ShadSettingsSectionHeader(
                        title: "Tools",
                        description: "A tool must be on here and in Settings → Tools before this agent can call it."
                    )

                    VStack(spacing: 0) {
                        ForEach(Array(AgentToolID.allCases.enumerated()), id: \.element.id) { index, toolID in
                            VStack(spacing: 0) {
                                ShadSettingsRow(
                                    title: toolID.title,
                                    description: skillCatalog.isToolEnabled(toolID)
                                        ? toolID.description
                                        : "\(toolID.description) This tool is off in Settings → Tools."
                                ) {
                                    ShadSwitch(isOn: toolEnabled(toolID))
                                        .accessibilityLabel(toolID.title)
                                        .disabled(
                                            selectedAgent == nil
                                                || !skillCatalog.isToolEnabled(toolID)
                                        )
                                }

                                if let service = toolID.appleService,
                                   skillCatalog.isToolEnabled(toolID),
                                   let agent = selectedAgent,
                                   agent.isToolEnabled(toolID) {
                                    AgentAppleServicesView(agent: agent, service: service)
                                        .id("\(agent.id)-\(toolID.rawValue)")
                                }

                                if toolID == .readCalendarEvents,
                                   skillCatalog.isToolEnabled(toolID),
                                   selectedAgent?.isToolEnabled(.readCalendarEvents) == true {
                                    ShadSeparator()
                                    calendarAccessPanel
                                }

                                if index < AgentToolID.allCases.count - 1 {
                                    ShadSeparator()
                                }
                            }
                        }
                    }
                    .shadSettingsCard()
                }
            }

            ShadTabsContent(value: AgentEditorTab.skills) {
                VStack(alignment: .leading, spacing: 10) {
                    ShadSettingsSectionHeader(
                        title: "Skills",
                        description: "Off until you enable them here. A skill must also be on in Settings."
                    )

                    if skillCatalog.enabledSkills.isEmpty {
                        VStack(spacing: 8) {
                            Text("No skills are enabled")
                                .font(theme.font(theme.typography.sm, theme.typography.medium))

                            Text("Turn on a skill in Settings → Skills, then it will appear here.")
                                .font(theme.font(theme.typography.sm))
                                .foregroundStyle(theme.colors.mutedForeground)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                        .shadSettingsCard()
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(skillCatalog.enabledSkills.enumerated()), id: \.element.id) { index, skill in
                                ShadSettingsRow(
                                    title: skill.name,
                                    description: skill.description.isEmpty
                                        ? "No description in SKILL.md."
                                        : skill.description
                                ) {
                                    ShadSwitch(isOn: skillEnabled(skill.name))
                                    .accessibilityLabel(skill.name)
                                    .disabled(selectedAgent == nil)
                                }

                                if index < skillCatalog.enabledSkills.count - 1 {
                                    ShadSeparator()
                                }
                            }
                        }
                        .shadSettingsCard()
                    }
                }
            }

            ShadTabsContent(value: AgentEditorTab.collaboration) {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        ShadSettingsSectionHeader(
                            title: "Routing",
                            description: "Give other agents a stable way to identify this agent and understand when its perspective is useful."
                        )

                        VStack(spacing: 0) {
                            ShadSettingsRow(
                                title: "Handle",
                                description: "This routing handle is permanent and does not change when you rename the agent."
                            ) {
                                Text(agent.mention)
                                    .font(theme.font(theme.typography.sm, theme.typography.medium))
                                    .foregroundStyle(theme.colors.accent)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(theme.colors.accent.opacity(0.1), in: Capsule())
                                    .overlay {
                                        Capsule()
                                            .stroke(theme.colors.accent.opacity(0.24), lineWidth: 1)
                                    }
                                    .textSelection(.enabled)
                                    .accessibilityLabel("Agent handle \(agent.mention)")
                            }

                            ShadSeparator()

                            ShadField {
                                ShadFieldLabel("When to ask me")
                                ShadFieldDescription(
                                    "Describe the topics, decisions, or situations where another agent should consult or dispatch to this agent."
                                )
                                ShadTextarea(
                                    "For example: Ask me about planning, deadlines, and prioritization.",
                                    text: routingDescription,
                                    minHeight: 112,
                                    maxHeight: 180
                                )
                                .accessibilityLabel("When to ask \(agent.displayName)")
                            }
                            .padding(16)
                        }
                        .shadSettingsCard()
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        ShadSettingsSectionHeader(
                            title: "Outbound permissions",
                            description: "Consult gathers advice; Dispatch starts independent work. Grants are one-way and non-transitive, and each target’s Soul and enabled tools still govern what it can do."
                        )

                        let collaborationTargets = store.agents.filter { $0.id != agent.id }
                        if collaborationTargets.isEmpty {
                            VStack(spacing: 8) {
                                Text("No other agents")
                                    .font(theme.font(theme.typography.sm, theme.typography.medium))

                                Text("Add another agent to configure directed collaboration permissions.")
                                    .font(theme.font(theme.typography.sm))
                                    .foregroundStyle(theme.colors.mutedForeground)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                            .shadSettingsCard()
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(collaborationTargets.enumerated()), id: \.element.id) { index, target in
                                    ShadSettingsRow(
                                        title: target.displayName,
                                        description: collaborationTargetDescription(target)
                                    ) {
                                        HStack(spacing: 18) {
                                            collaborationPermissionControl(
                                                title: "Consult",
                                                mode: .consult,
                                                callerID: agent.id,
                                                target: target
                                            )
                                            collaborationPermissionControl(
                                                title: "Dispatch",
                                                mode: .dispatch,
                                                callerID: agent.id,
                                                target: target
                                            )
                                        }
                                    }

                                    if index < collaborationTargets.count - 1 {
                                        ShadSeparator()
                                    }
                                }
                            }
                            .shadSettingsCard()
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        ShadSettingsSectionHeader(
                            title: "Recent delegated work",
                            description: "A live execution tree for work this agent requested or received. Stop fences late results so they cannot post afterward."
                        )

                        if recentCollaborationInvocations(for: agent).isEmpty {
                            Text("No delegated work yet.")
                                .font(theme.font(theme.typography.sm))
                                .foregroundStyle(theme.colors.mutedForeground)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 28)
                                .shadSettingsCard()
                        } else {
                            VStack(spacing: 0) {
                                ForEach(
                                    Array(recentCollaborationInvocations(for: agent).enumerated()),
                                    id: \.element.id
                                ) { index, invocation in
                                    collaborationInvocationRow(invocation)
                                        .padding(.leading, CGFloat(max(0, invocation.depth - 1)) * 16)

                                    if index < recentCollaborationInvocations(for: agent).count - 1 {
                                        ShadSeparator()
                                    }
                                }
                            }
                            .shadSettingsCard()
                        }
                    }
                }
            }

            ShadTabsContent(value: AgentEditorTab.advanced) {
                VStack(alignment: .leading, spacing: 10) {
                    ShadSettingsSectionHeader(
                        title: "Diagnostics",
                        description: "Optional logs for inspecting prompts and tool traces."
                    )

                    VStack(spacing: 0) {
                        ShadSettingsRow(
                            title: "Debug log",
                            description: "Store full prompts and intermediate output for chats and heartbeats, plus complete tool and delegated-agent exchanges for heartbeats. PASS runs are included, and Debug remains available with Apple Services enabled. Off by default — this is a lot of data.",
                            labelWidth: 500
                        ) {
                            ShadSwitch(isOn: debugLogEnabled)
                                .accessibilityLabel("Debug log")
                                .disabled(selectedAgent == nil)
                        }
                    }
                    .shadSettingsCard()
                }
            }

            ShadTabsContent(value: AgentEditorTab.memory) {
                VStack(alignment: .leading, spacing: 10) {
                    ShadSettingsSectionHeader(
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

                        ShadSeparator()

                        HStack {
                            Text("Memory changes are applied when you save.")
                                .font(theme.font(theme.typography.xs))
                                .foregroundStyle(theme.colors.mutedForeground)

                            Spacer()

                            if hasUnsavedMemoryChanges {
                                ShadButton("Save Memory", size: .sm, icon: .check) {
                                    store.updateAgentMemory(id: agent.id, memory: draftMemory)
                                }
                            }
                        }
                        .padding(14)
                    }
                    .shadSettingsCard()
                }
            }

            ShadTabsContent(value: AgentEditorTab.stash) {
                AgentStashEditor(agent: agent)
                    .id(agent.id)
            }

            ShadTabsContent(value: AgentEditorTab.heartbeats) {
                AgentHeartbeatsTab(
                    agentID: agent.id,
                    store: store,
                    heartbeatScheduler: heartbeatScheduler,
                    onEditHeartbeat: onEditHeartbeat
                )
                .id(agent.id)
            }

            ShadTabsContent(value: AgentEditorTab.dreams) {
                AgentDreamTab(
                    agent: agent,
                    store: store,
                    localModelStore: localModelStore,
                    scheduler: dreamScheduler
                )
            }

            ShadTabsContent(value: AgentEditorTab.advanced) {
                VStack(alignment: .leading, spacing: 10) {
                    ShadSettingsSectionHeader(
                        title: "Agent",
                        description: "Manage this agent's lifecycle."
                    )

                    VStack(spacing: 0) {
                        ShadSettingsRow(
                            title: "Show in sidebar",
                            description: "Show this agent in the chat sidebar and its New Chat menu.",
                            labelWidth: 500
                        ) {
                            ShadSwitch(isOn: agentSidebarVisibility)
                                .accessibilityLabel("Show in sidebar")
                        }

                        ShadSeparator()

                        ShadSettingsRow(
                            title: store.isDefaultAgent(agent) ? "Default agent" : "Delete agent",
                            description: deletionDescription(for: agent),
                            labelWidth: 500
                        ) {
                            ShadButton("Delete Agent", variant: .outline, size: .sm, icon: .trash) {
                                beginDeleting(agent)
                            }
                            .disabled(!canBeginDeleting(agent))
                            .accessibilityHint(deletionDescription(for: agent))
                        }
                    }
                    .shadSettingsCard()
                }
            }
        }
        .frame(maxWidth: 900, alignment: .topLeading)
        .shadAlertDialog(isPresented: $deleteDialogIsPresented) {
            ShadAlertDialogContent {
                ShadAlertDialogTitle("Delete \(agent.displayName)?")
                ShadAlertDialogDescription(
                    "The agent and its heartbeat schedules will be deleted. Existing messages and generation history are preserved. This cannot be undone."
                )
            } actions: {
                ShadAlertDialogCancel()
                ShadAlertDialogAction("Delete Agent", variant: .destructive) {
                    confirmAgentDeletion(agent)
                }
            }
        }
    }

    private func finalizeSelectedAgentHandle() {
        guard let agentID = selectedAgent?.id else { return }
        store.finalizeAgentMentionHandle(id: agentID)
    }

    private func loadSelectedAgent() {
        guard let selectedAgent else {
            draftSoul = ""
            draftMemory = ""
            avatarEditorState = ShadAvatarEditorState()
            return
        }

        load(selectedAgent)
    }

    private func load(_ agent: Agent) {
        draftSoul = agent.soul
        draftMemory = agent.memoryText
        avatarEditorState = ShadAvatarEditorState(photo: agent.avatarPhoto)
    }

    private func placeholderAvatarColor(for agent: Agent) -> Binding<Color> {
        Binding(
            get: {
                agent.avatarPlaceholderColor
                    ?? AgentAvatarPalette.automaticEntry(for: agent, theme: theme).background
            },
            set: { color in
                guard let colorHex = AgentAvatarPlaceholderColor.encode(color) else { return }
                store.updateAgentAvatarPlaceholderColor(id: agent.id, colorHex: colorHex)
            }
        )
    }

    private func removeAvatar(from agent: Agent) {
        avatarEditorState = ShadAvatarEditorState()
        store.updateAgentAvatar(
            id: agent.id,
            imageData: nil,
            cropZoom: 1,
            cropOffsetX: 0,
            cropOffsetY: 0
        )
    }

    private func canBeginDeleting(_ agent: Agent) -> Bool {
        store.canDeleteAgent(agent) && !hasActiveWork(for: agent)
    }

    private func hasActiveWork(for agent: Agent) -> Bool {
        let hasRunningHeartbeat = heartbeatScheduler.runningHeartbeats.contains {
            $0.agentID == agent.id
        }
        let hasActiveDirectChat = chatStore.chats(for: agent.id).contains {
            $0.isResponding || $0.isCompacting
        }
        let hasActiveGroupChat = chatStore.groupChats.contains { chat in
            (chat.isResponding || chat.isCompacting)
                && chat.groupParticipants.contains { $0.agentID == agent.id }
        }
        let hasActiveDelegatedWork = collaborationInvocations.contains {
            ($0.callerAgentID == agent.id || $0.targetAgentID == agent.id)
                && ($0.state == .queued || $0.state == .running)
        }
        return hasRunningHeartbeat
            || hasActiveDirectChat
            || hasActiveGroupChat
            || hasActiveDelegatedWork
    }

    private func deletionDescription(for agent: Agent) -> String {
        if store.isDefaultAgent(agent) {
            return "The default agent anchors Chat and cannot be deleted."
        }
        if hasActiveWork(for: agent) {
            return "Wait for this agent's active chat, heartbeat, or delegated work to finish before deleting it."
        }
        return "Delete this agent and its heartbeat schedules. Existing messages and generation history are preserved."
    }

    private func beginDeleting(_ agent: Agent) {
        guard canBeginDeleting(agent) else { return }
        deleteDialogIsPresented = true
    }

    private func confirmAgentDeletion(_ agent: Agent) {
        guard canBeginDeleting(agent) else {
            return
        }

        let agentID = agent.id
        var deactivationPlan: ChatStore.AgentDeactivationPlan?
        guard store.removeAgent(
            id: agentID,
            beforeSaving: {
                deactivationPlan = chatStore.stageAgentDeactivation(agentID)
            }
        ) else {
            return
        }

        guard let deactivationPlan else { return }
        let deletedChatWasSelected = chatStore.applyAgentDeactivation(deactivationPlan)
        if deletedChatWasSelected, let nextAgent = store.selectedAgent {
            chatStore.selectDefaultChat(for: nextAgent)
        }
        onAgentDeleted()
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

    private func collaborationPermission(
        _ mode: AgentDelegationMode,
        from callerID: Agent.ID,
        to targetID: Agent.ID
    ) -> Binding<Bool> {
        Binding {
            store.grant(from: callerID, to: targetID)?.allows(mode) == true
        } set: { enabled in
            store.setCollaborationPermission(
                mode,
                enabled: enabled,
                from: callerID,
                to: targetID
            )
        }
    }

    private func recentCollaborationInvocations(for agent: Agent) -> [AgentInvocationRecord] {
        return Array(
            collaborationInvocations
                .lazy
                .filter {
                    $0.callerAgentID == agent.id || $0.targetAgentID == agent.id
                }
                .prefix(20)
        )
    }

    private func collaborationInvocationRow(_ invocation: AgentInvocationRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("\(invocation.callerName) → \(invocation.targetName)")
                    .font(theme.font(theme.typography.sm, theme.typography.medium))
                    .lineLimit(1)

                Text(invocation.mode.displayName)
                    .font(theme.font(theme.typography.xs, theme.typography.medium))
                    .foregroundStyle(theme.colors.mutedForeground)

                Spacer(minLength: 8)

                Text(collaborationStateLabel(invocation.state))
                    .font(theme.font(theme.typography.xs, theme.typography.medium))
                    .foregroundStyle(collaborationStateColor(invocation.state))

                if invocation.state == .queued || invocation.state == .running {
                    ShadButton("Stop", variant: .outline, size: .sm) {
                        chatStore.cancelDelegatedInvocation(invocation.id)
                    }
                    .accessibilityLabel("Stop delegated work for \(invocation.targetName)")
                }
            }

            Text(invocation.taskPreview)
                .font(theme.font(theme.typography.xs))
                .foregroundStyle(theme.colors.mutedForeground)
                .lineLimit(2)

            if let result = invocation.resultPreview, !result.isEmpty {
                Text(result)
                    .font(theme.font(theme.typography.xs))
                    .lineLimit(2)
            } else if let error = invocation.errorMessage, !error.isEmpty {
                Text(error)
                    .font(theme.font(theme.typography.xs))
                    .foregroundStyle(theme.colors.destructive)
                    .lineLimit(2)
            }

            if let toolTrace = invocation.toolTraceSummary, !toolTrace.isEmpty {
                Text("Tools\n\(toolTrace)")
                    .font(theme.font(theme.typography.xs))
                    .foregroundStyle(theme.colors.mutedForeground)
                    .lineLimit(4)
            }
        }
        .padding(14)
    }

    private func collaborationStateLabel(_ state: AgentInvocationState) -> String {
        switch state {
        case .queued: return "Queued"
        case .running: return "Running"
        case .succeeded: return "Completed"
        case .failed: return "Failed"
        case .timedOut: return "Timed out"
        case .cancelled: return "Cancelled"
        case .rejected: return "Rejected"
        }
    }

    private func collaborationStateColor(_ state: AgentInvocationState) -> Color {
        switch state {
        case .queued, .running:
            return theme.colors.accent
        case .succeeded:
            return theme.colors.foreground
        case .failed, .timedOut, .rejected:
            return theme.colors.destructive
        case .cancelled:
            return theme.colors.mutedForeground
        }
    }

    private func collaborationTargetDescription(_ target: Agent) -> String {
        let routingDescription = target.routingDescriptionText
            .split(whereSeparator: { $0.isNewline })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !routingDescription.isEmpty else { return target.mention }
        return "\(target.mention) · \(routingDescription)"
    }

    private func collaborationPermissionControl(
        title: String,
        mode: AgentDelegationMode,
        callerID: Agent.ID,
        target: Agent
    ) -> some View {
        let permission = collaborationPermission(mode, from: callerID, to: target.id)
        return VStack(spacing: 5) {
            Text(title)
                .font(theme.font(theme.typography.xs, theme.typography.medium))
                .foregroundStyle(theme.colors.mutedForeground)

            ShadSwitch(isOn: permission, size: .sm)
                .accessibilityLabel("Allow \(title.lowercased()) with \(target.displayName)")
                .accessibilityValue(permission.wrappedValue ? "Allowed" : "Not allowed")
        }
        .frame(minWidth: 64)
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
        ShadSettingsRow(
            title: "Calendars",
            description: calendarAccessDescription
        ) {
            HStack(spacing: 10) {
                if calendarDirectory.isRequestingAccess {
                    ShadSpinner(size: theme.typography.base)
                }

                ShadTabs(selection: calendarAccessAll, spacing: 0) {
                    ShadTabsList {
                        ShadTabsTrigger("All", value: true)
                        ShadTabsTrigger("Selected", value: false)
                    }
                }
                .frame(width: 200)
                .disabled(selectedAgent == nil)
                .accessibilityLabel("Calendar access")
            }
        }

        ShadSeparator()
        CalendarPermissionView().padding(16)

        if calendarAccessAll.wrappedValue == false, calendarDirectory.hasFullAccess {
            if calendarDirectory.calendars.isEmpty {
                ShadSeparator()
                ShadSettingsRow(
                    title: "No calendars",
                    description: "No calendars were found on this Mac."
                ) {
                    EmptyView()
                }
            } else {
                ForEach(calendarDirectory.calendars) { calendar in
                    ShadSeparator()
                    ShadSettingsRow(
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
                            ShadSwitch(isOn: calendarAllowed(calendar.calendarIdentifier))
                            .accessibilityLabel(calendar.title)
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

    private var agentSidebarVisibility: Binding<Bool> {
        Binding {
            selectedAgent?.isVisibleInSidebar ?? true
        } set: { isVisible in
            guard let agentID = selectedAgent?.id else { return }
            store.updateAgentSidebarVisibility(id: agentID, isVisible: isVisible)
        }
    }
}

private struct AgentHeartbeatsTab: View {
    let agentID: Agent.ID
    @ObservedObject var store: AgentStore
    @ObservedObject var heartbeatScheduler: HeartbeatScheduler
    let onEditHeartbeat: (AgentHeartbeat.ID) -> Void
    @Environment(\.shadTheme) private var theme

    private var heartbeats: [AgentHeartbeat] {
        store.heartbeats(for: agentID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                ShadSettingsSectionHeader(
                    title: "Heartbeats",
                    description: "Manage recurring agent instructions while Chat is open."
                )

                Spacer()

                ShadButton("Add heartbeat", variant: .outline, size: .sm, icon: .plus) {
                    if let heartbeat = store.addHeartbeat(to: agentID) {
                        onEditHeartbeat(heartbeat.id)
                    }
                }
            }

            ShadTable(
                heartbeats,
                columns: heartbeatColumns,
                bordered: true,
                emptyMessage: "No heartbeats configured"
            )
            .accessibilityLabel("Heartbeats")
        }
    }

    private var heartbeatColumns: [ShadTableColumn<AgentHeartbeat>] {
        [
            ShadTableColumn(
                "Title",
                width: .flexible(min: 180),
                canHide: false,
                searchValue: { $0.displayTitle }
            ) { heartbeat in
                HeartbeatEditCellButton(title: heartbeat.displayTitle) {
                    onEditHeartbeat(heartbeat.id)
                } content: {
                    HStack(spacing: 8) {
                        Text(heartbeat.displayTitle)
                            .font(theme.font(theme.typography.sm, theme.typography.medium))
                            .foregroundStyle(theme.colors.foreground)
                            .lineLimit(1)

                        Spacer(minLength: 8)

                        ShadIconView(.chevronRight, size: theme.typography.xs)
                            .foregroundStyle(theme.colors.mutedForeground)
                            .accessibilityHidden(true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Edit heartbeat \(heartbeat.displayTitle)")
                }
            },
            ShadTableColumn(
                "On",
                alignment: .center,
                width: .fixed(48),
                canHide: false,
                searchValue: nil
            ) { heartbeat in
                let isRunning = isHeartbeatRunning(heartbeat)
                ShadSwitch(
                    isOn: Binding(
                        get: { heartbeat.isEnabled },
                        set: { store.updateHeartbeatEnabled(heartbeat, isEnabled: $0) }
                    ),
                    size: .sm
                )
                .disabled(isRunning)
                .accessibilityLabel("\(heartbeat.displayTitle) enabled")
                .accessibilityValue(heartbeat.isEnabled ? "On" : "Off")
                .accessibilityHint(isRunning ? "Wait for the current run to finish before changing this setting." : "Turns future runs on or off.")
                .help(isRunning ? "This heartbeat cannot be changed while it is running." : "Turn this heartbeat on or off.")
            },
            ShadTableColumn(
                "Schedule",
                width: .fixed(160),
                canHide: false,
                searchValue: nil
            ) { heartbeat in
                HeartbeatEditCellButton(title: heartbeat.displayTitle) {
                    onEditHeartbeat(heartbeat.id)
                } content: {
                    Text(heartbeat.scheduleDescription)
                        .font(theme.font(theme.typography.sm))
                        .monospacedDigit()
                        .lineLimit(1)
                }
            },
            ShadTableColumn(
                "Last run",
                width: .fixed(120),
                canHide: false,
                searchValue: nil
            ) { heartbeat in
                let runningHeartbeat = runningHeartbeat(for: heartbeat)
                HeartbeatEditCellButton(title: heartbeat.displayTitle) {
                    onEditHeartbeat(heartbeat.id)
                } content: {
                    HeartbeatLastRunCell(
                        date: runningHeartbeat?.startedAt ?? heartbeat.lastCompletedAt,
                        isRunning: runningHeartbeat != nil
                    )
                }
            },
            ShadTableColumn(
                "Result",
                width: .fixed(120),
                canHide: false,
                searchValue: nil
            ) { heartbeat in
                HeartbeatEditCellButton(title: heartbeat.displayTitle) {
                    onEditHeartbeat(heartbeat.id)
                } content: {
                    HeartbeatLastResultCell(
                        heartbeat: heartbeat,
                        isRunning: isHeartbeatRunning(heartbeat)
                    )
                }
            },
            ShadTableColumn(
                "",
                id: "actions",
                alignment: .trailing,
                width: .fixed(88),
                canHide: false,
                searchValue: nil
            ) { heartbeat in
                let isRunning = isHeartbeatRunning(heartbeat)
                HStack(spacing: 4) {
                    ShadButton(
                        icon: .play,
                        variant: .ghost,
                        size: .icon,
                        accessibilityLabel: "Run \(heartbeat.displayTitle)"
                    ) {
                        heartbeatScheduler.runNow(heartbeat.id)
                    }
                    .disabled(!heartbeatScheduler.runningHeartbeats.isEmpty)
                    .accessibilityHint(runHeartbeatHint)
                    .help(runHeartbeatHelp)

                    ShadButton(
                        icon: .trash,
                        variant: .destructive,
                        size: .icon,
                        accessibilityLabel: "Delete \(heartbeat.displayTitle)"
                    ) {
                        deleteHeartbeat(heartbeat)
                    }
                    .disabled(isRunning)
                    .accessibilityHint(isRunning ? "Wait for the current run to finish before deleting this heartbeat." : "Permanently deletes this heartbeat.")
                    .help(isRunning ? "Wait for this heartbeat to finish before deleting it." : "Delete this heartbeat")
                }
            },
        ]
    }

    private var runHeartbeatHint: String {
        heartbeatScheduler.runningHeartbeats.isEmpty
            ? "Runs this heartbeat now, even when its schedule is disabled."
            : "Wait for the current heartbeat to finish before starting another."
    }

    private var runHeartbeatHelp: String {
        heartbeatScheduler.runningHeartbeats.isEmpty
            ? "Run this heartbeat now"
            : "Wait for the current heartbeat to finish"
    }

    private func isHeartbeatRunning(_ heartbeat: AgentHeartbeat) -> Bool {
        runningHeartbeat(for: heartbeat) != nil
    }

    private func runningHeartbeat(for heartbeat: AgentHeartbeat) -> RunningHeartbeat? {
        heartbeatScheduler.runningHeartbeats.first { $0.id == heartbeat.id }
    }

    private func deleteHeartbeat(_ heartbeat: AgentHeartbeat) {
        guard !isHeartbeatRunning(heartbeat) else { return }
        store.removeHeartbeat(heartbeat)
    }
}

private struct HeartbeatEditCellButton<Content: View>: View {
    let title: String
    let action: () -> Void
    private let content: Content

    init(
        title: String,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.action = action
        self.content = content()
    }

    var body: some View {
        ShadButton(
            variant: .ghost,
            size: .sm,
            fillsWidth: true,
            action: action
        ) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityHint("Opens heartbeat settings for \(title).")
        .help("Edit \(title)")
    }
}

private struct HeartbeatLastRunCell: View {
    let date: Date?
    let isRunning: Bool
    @Environment(\.shadTheme) private var theme

    var body: some View {
        Group {
            if let date {
                VStack(alignment: .leading, spacing: 1) {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                    Text(date.formatted(date: .omitted, time: .shortened))
                }
                .help(date.formatted(date: .complete, time: .standard))
            } else {
                Text("Never")
                    .foregroundStyle(theme.colors.mutedForeground)
            }
        }
        .font(theme.font(theme.typography.xs))
        .monospacedDigit()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        guard let date else { return "Never run" }
        let formattedDate = date.formatted(date: .complete, time: .standard)
        return isRunning ? "Current run started \(formattedDate)" : "Last run completed \(formattedDate)"
    }
}

private struct HeartbeatLastResultCell: View {
    let heartbeat: AgentHeartbeat
    let isRunning: Bool
    @Environment(\.shadTheme) private var theme

    var body: some View {
        Group {
            if isRunning {
                HStack(spacing: 5) {
                    ShadSpinner(size: theme.typography.sm)
                    statusText("Running", color: theme.colors.foreground)
                }
            } else if let lastCompletedAt = heartbeat.lastCompletedAt {
                let succeeded = heartbeat.lastError == nil
                HStack(spacing: 5) {
                    ShadIconView(succeeded ? .circleCheck : .triangleAlert, size: theme.typography.sm)
                    statusText(
                        succeeded ? "Succeeded" : "Failed",
                        color: succeeded ? theme.colors.success : theme.colors.warning
                    )
                }
                .foregroundStyle(succeeded ? theme.colors.success : theme.colors.warning)
                .help(heartbeat.lastError ?? "Completed \(lastCompletedAt.formatted(date: .abbreviated, time: .shortened)).")
            } else {
                HStack(spacing: 5) {
                    ShadIconView(.minus, size: theme.typography.sm)
                    statusText("Not run", color: theme.colors.mutedForeground)
                }
                .foregroundStyle(theme.colors.mutedForeground)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Last result: \(statusLabel)")
    }

    private var statusLabel: String {
        if isRunning {
            return "Running"
        }
        guard heartbeat.lastCompletedAt != nil else {
            return "Not run"
        }
        return heartbeat.lastError == nil ? "Succeeded" : "Failed"
    }

    private func statusText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(theme.font(theme.typography.xs, theme.typography.medium))
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

private func heartbeatFrequencyText(_ minutes: Int) -> String {
    let minutes = min(max(minutes, 1), 10_080)
    if minutes == 10_080 {
        return "Every week"
    }
    if minutes.isMultiple(of: 1_440) {
        let days = minutes / 1_440
        return days == 1 ? "Every day" : "Every \(days) days"
    }
    if minutes.isMultiple(of: 60) {
        let hours = minutes / 60
        return hours == 1 ? "Every hour" : "Every \(hours) hours"
    }
    return minutes == 1 ? "Every minute" : "Every \(minutes) min"
}

private struct HeartbeatEditorDialog: View {
    let heartbeat: AgentHeartbeat
    @ObservedObject var store: AgentStore
    @ObservedObject var localModelStore: LocalModelStore
    @ObservedObject var chatStore: ChatStore
    @ObservedObject var heartbeatScheduler: HeartbeatScheduler

    var body: some View {
        ShadDialogContent(maxWidth: 820) {
            ShadDialogHeader {
                ShadDialogTitle(heartbeat.displayTitle)
                ShadDialogDescription(
                    "\(heartbeat.scheduleDescription). Changes save automatically."
                )
            }

            AgentHeartbeatEditor(
                heartbeat: heartbeat,
                store: store,
                localModelStore: localModelStore,
                chatStore: chatStore,
                heartbeatScheduler: heartbeatScheduler
            )
            .id(heartbeat.id)
        } footer: {
            ShadButton("Run", variant: .secondary, icon: .play) {
                heartbeatScheduler.runNow(heartbeat.id)
            }
            .disabled(!heartbeatScheduler.runningHeartbeats.isEmpty)
            .help(
                heartbeatScheduler.runningHeartbeats.isEmpty
                    ? "Run this heartbeat now, even when disabled"
                    : "Wait for the current heartbeat to finish"
            )
            ShadDialogClose("Done", variant: .default)
        }
    }
}

private enum HeartbeatEditorTab: Hashable {
    case info
    case prompt
    case history
}

struct AgentHeartbeatEditor: View {
    private static let executionHistoryLimit = 50
    private static let tabPanelHeight: CGFloat = 450

    let heartbeat: AgentHeartbeat
    @ObservedObject var store: AgentStore
    @ObservedObject var localModelStore: LocalModelStore
    @ObservedObject var chatStore: ChatStore
    @ObservedObject var heartbeatScheduler: HeartbeatScheduler
    @Query private var executions: [HeartbeatRun]
    @State private var selectedTab = HeartbeatEditorTab.info
    @Environment(\.shadTheme) private var theme

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
        ShadTabs(selection: $selectedTab, variant: .line, spacing: 12) {
            ShadTabsList {
                ShadTabsTrigger("Info", value: HeartbeatEditorTab.info)
                ShadTabsTrigger("Prompt", value: HeartbeatEditorTab.prompt)
                ShadTabsTrigger("History", value: HeartbeatEditorTab.history)
            }
            .accessibilityLabel("Heartbeat editor sections")

            ShadTabsContent(value: HeartbeatEditorTab.info) {
                infoTab
                    .frame(height: Self.tabPanelHeight, alignment: .topLeading)
            }

            ShadTabsContent(value: HeartbeatEditorTab.prompt) {
                promptTab
                    .frame(height: Self.tabPanelHeight, alignment: .topLeading)
            }

            ShadTabsContent(value: HeartbeatEditorTab.history) {
                historyTab
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var infoTab: some View {
        VStack(spacing: 0) {
            ShadSettingsRow(
                title: "Title",
                description: "Shown in the heartbeats table."
            ) {
                ShadInput("Heartbeat title", text: title)
                    .frame(width: 300)
                    .accessibilityLabel("Heartbeat title")
            }

            ShadSeparator()

            ShadSettingsRow(
                title: "Enabled",
                description: runningHeartbeat == nil
                    ? "Run this heartbeat on its schedule."
                    : "Wait for the current run to finish."
            ) {
                ShadSwitch(
                    isOn: isEnabled,
                    size: .sm
                )
                .disabled(runningHeartbeat != nil)
                .accessibilityLabel("Heartbeat enabled")
                .accessibilityValue(heartbeat.isEnabled ? "On" : "Off")
                .accessibilityHint(
                    runningHeartbeat == nil
                        ? "Turns future runs on or off."
                        : "Wait for the current run to finish before changing this setting."
                )
            }

            ShadSeparator()

            ShadSettingsRow(
                title: "Schedule",
                description: "Run repeatedly or at a set time."
            ) {
                ShadSelect(
                    selection: optionalScheduleKind,
                    options: scheduleKindOptions,
                    width: 300
                )
                .accessibilityLabel("Heartbeat schedule type")
            }

            ShadSeparator()

            if heartbeat.scheduleKind == .interval {
                ShadSettingsRow(
                    title: "Interval",
                    description: "Time between eligible runs."
                ) {
                    HStack(spacing: theme.spacing.md) {
                        ShadButton(
                            icon: .minus,
                            variant: .outline,
                            size: .iconSM,
                            accessibilityLabel: "Decrease interval"
                        ) {
                            intervalMinutes.wrappedValue = max(1, intervalMinutes.wrappedValue - 1)
                        }
                        .buttonRepeatBehavior(.enabled)
                        .disabled(intervalMinutes.wrappedValue <= 1)

                        ShadSelect(
                            selection: optionalIntervalMinutes,
                            options: intervalOptions,
                            width: 200
                        )
                        .accessibilityLabel("Heartbeat frequency")
                        .accessibilityValue(heartbeatFrequencyText(heartbeat.normalizedIntervalMinutes))

                        ShadButton(
                            icon: .plus,
                            variant: .outline,
                            size: .iconSM,
                            accessibilityLabel: "Increase interval"
                        ) {
                            intervalMinutes.wrappedValue = min(10_080, intervalMinutes.wrappedValue + 1)
                        }
                        .buttonRepeatBehavior(.enabled)
                        .disabled(intervalMinutes.wrappedValue >= 10_080)
                    }
                    .frame(width: 300)
                }
            } else {
                ShadSettingsRow(
                    title: "Time",
                    description: "Local time on selected days."
                ) {
                    DatePicker(
                        "Run time",
                        selection: scheduledTime,
                        displayedComponents: .hourAndMinute
                    )
                    .labelsHidden()
                    .datePickerStyle(.field)
                    .frame(width: 300, alignment: .trailing)
                    .accessibilityLabel("Heartbeat run time")
                }
            }

            ShadSeparator()

            ShadSettingsRow(
                title: "Days",
                description: "Days when this heartbeat may run."
            ) {
                HStack(spacing: 6) {
                    ForEach(HeartbeatWeekday.allCases) { weekday in
                        let isSelected = heartbeat.runs(on: weekday)
                        ShadButton(
                            weekday.shortLabel,
                            variant: isSelected ? .default : .outline,
                            size: .sm,
                            shape: .pill
                        ) {
                            toggle(weekday)
                        }
                        .frame(width: 34)
                        .accessibilityLabel(weekday.accessibilityLabel)
                        .accessibilityValue(isSelected ? "Selected" : "Not selected")
                    }
                }
                .frame(width: 300, alignment: .trailing)
            }

            ShadSeparator()

            ShadSettingsRow(
                title: "Model",
                description: "Model used for this heartbeat."
            ) {
                ShadSelect(
                    selection: optionalModelIdentifier,
                    sections: heartbeatModelSections,
                    width: 300
                )
                .accessibilityLabel("Heartbeat model")
            }

            ShadSeparator()

            ShadSettingsRow(
                title: "Post to",
                description: "Chat that receives heartbeat output."
            ) {
                ShadSelect(
                    selection: optionalDestination,
                    sections: destinationSections,
                    width: 300
                )
                .accessibilityLabel("Heartbeat destination")
            }
        }
        .shadSettingsCard()
    }

    private var promptTab: some View {
        ShadField {
            ShadFieldDescription("Tell the agent what to consider when this heartbeat runs.")
            MentionHighlightingTextArea(
                placeholder: "Tell the agent what to consider",
                text: instruction,
                recognizedHandles: recognizedMentionHandles
            )
            .frame(height: 168)
            .accessibilityLabel("Heartbeat prompt")
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .shadSettingsCard()
    }

    private var recognizedMentionHandles: Set<String> {
        Set(store.agents.compactMap { agent in
            guard let handle = AgentMention.normalizedHandle(agent.mentionHandle) else {
                return nil
            }
            return AgentMention.lookupKey(for: handle)
        })
    }

    private var historyTab: some View {
        ShadDialogBody(maxHeight: Self.tabPanelHeight) {
            historyContent
        }
        .frame(height: Self.tabPanelHeight, alignment: .topLeading)
    }

    private var historyContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Executions")
                .font(theme.font(theme.typography.sm, theme.typography.medium))

            Text("Every run keeps compact history. Once a destination is resolved, PASS included, it also keeps the generation and tool trace. Debug-enabled runs keep prompts, raw output, provider artifacts, and collaboration details.")
                .font(theme.font(theme.typography.sm))
                .foregroundStyle(theme.colors.mutedForeground)

            if runningHeartbeat != nil || !executions.isEmpty {
                VStack(spacing: 0) {
                    if let runningHeartbeat {
                        HeartbeatRunningExecutionRow(startedAt: runningHeartbeat.startedAt)
                        if !executions.isEmpty {
                            ShadSeparator()
                        }
                    }

                    ForEach(Array(executions.enumerated()), id: \.element.id) { index, run in
                        if index > 0 {
                            ShadSeparator()
                        }
                        HeartbeatExecutionRow(run: run)
                    }
                }
                .padding(.top, 4)
            } else {
                Text("No recorded executions yet.")
                    .font(theme.font(theme.typography.sm))
                    .foregroundStyle(theme.colors.mutedForeground)
                    .padding(.top, 4)
            }
        }
        .padding(16)
        .shadSettingsCard()
    }

    private var isEnabled: Binding<Bool> {
        Binding(
            get: { heartbeat.isEnabled },
            set: { store.updateHeartbeatEnabled(heartbeat, isEnabled: $0) }
        )
    }

    private var title: Binding<String> {
        Binding(
            get: { heartbeat.title ?? "" },
            set: { store.updateHeartbeatTitle(heartbeat, title: $0) }
        )
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

    private var optionalScheduleKind: Binding<HeartbeatScheduleKind?> {
        Binding(
            get: { heartbeat.scheduleKind },
            set: { scheduleKind in
                guard let scheduleKind else { return }
                store.updateHeartbeatScheduleKind(heartbeat, scheduleKind: scheduleKind)
            }
        )
    }

    private var scheduleKindOptions: [ShadSelectOption<HeartbeatScheduleKind>] {
        HeartbeatScheduleKind.allCases.map { kind in
            ShadSelectOption(kind.label, value: kind)
        }
    }

    private var scheduledTime: Binding<Date> {
        Binding(
            get: {
                let calendar = Calendar.autoupdatingCurrent
                let startOfDay = calendar.startOfDay(for: .now)
                return calendar.date(
                    byAdding: .minute,
                    value: heartbeat.normalizedScheduledTimeMinutes,
                    to: startOfDay
                ) ?? startOfDay
            },
            set: { date in
                let components = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: date)
                let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
                store.updateHeartbeatScheduledTime(heartbeat, minutes: minutes)
            }
        )
    }

    private func toggle(_ weekday: HeartbeatWeekday) {
        let currentMask = heartbeat.normalizedWeekdayMask
        let updatedMask = currentMask ^ weekday.bit
        guard updatedMask != 0 else { return }
        store.updateHeartbeatWeekdayMask(heartbeat, weekdayMask: updatedMask)
    }

    private var optionalIntervalMinutes: Binding<Int?> {
        Binding(
            get: { intervalMinutes.wrappedValue },
            set: { value in
                guard let value else { return }
                intervalMinutes.wrappedValue = value
            }
        )
    }

    private var intervalOptions: [ShadSelectOption<Int>] {
        let presets = [1, 5, 15, 30, 60, 120, 360, 720, 1_440, 2_880, 10_080]
        let values = Set(presets + [heartbeat.normalizedIntervalMinutes]).sorted()
        return values.map { minutes in
            ShadSelectOption(
                heartbeatFrequencyText(minutes),
                value: minutes
            )
        }
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

    private var optionalModelIdentifier: Binding<String?> {
        Binding(
            get: { modelIdentifier.wrappedValue },
            set: { newValue in
                guard let newValue else { return }
                modelIdentifier.wrappedValue = newValue
            }
        )
    }

    private var heartbeatModelSections: [ShadSelectSection<String>] {
        var overrides = localModelStore.selectableModels.map { model in
            ShadSelectOption(
                model.displayName,
                value: model.identifier
            )
        }
        if let selectedIdentifier = heartbeat.modelIdentifier,
           !overrides.contains(where: { $0.value == selectedIdentifier }) {
            overrides.append(
                ShadSelectOption(
                    localModelStore.displayName(for: selectedIdentifier),
                    value: selectedIdentifier
                )
            )
        }

        return [
            ShadSelectSection(
                options: [
                    ShadSelectOption(
                        "Agent default (\(agentDefaultModelName))",
                        value: ""
                    )
                ]
            ),
            ShadSelectSection("Override", options: overrides),
        ]
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

    private var optionalDestination: Binding<String?> {
        Binding(
            get: { destination.wrappedValue },
            set: { newValue in
                guard let newValue else { return }
                destination.wrappedValue = newValue
            }
        )
    }

    private var destinationSections: [ShadSelectSection<String>] {
        var sections = [
            ShadSelectSection(
                options: [ShadSelectOption("Default chat", value: "private")]
            )
        ]

        var directOptions = extraDirectChats.map { chat in
            ShadSelectOption(chat.title, value: "direct.\(chat.id.uuidString)")
        }
        if heartbeat.targetKind == .privateChat,
           let targetChatID = heartbeat.targetChatID,
           !extraDirectChats.contains(where: { $0.id == targetChatID }) {
            directOptions.append(
                ShadSelectOption(
                    "Missing private chat",
                    value: "direct.\(targetChatID.uuidString)"
                )
            )
        }
        if !directOptions.isEmpty {
            sections.append(ShadSelectSection("Other chats", options: directOptions))
        }

        var groupOptions = chatStore.groupChats.map { chat in
            ShadSelectOption(chat.title, value: "group.\(chat.id.uuidString)")
        }
        if heartbeat.targetKind == .groupChat,
           let targetChatID = heartbeat.targetChatID,
           !chatStore.groupChats.contains(where: { $0.id == targetChatID }) {
            groupOptions.append(
                ShadSelectOption(
                    "Missing group chat",
                    value: "group.\(targetChatID.uuidString)"
                )
            )
        }
        if !groupOptions.isEmpty {
            sections.append(ShadSelectSection("Group chats", options: groupOptions))
        }

        return sections
    }
}

private struct HeartbeatRunningExecutionRow: View {
    let startedAt: Date
    @Environment(\.shadTheme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ShadSpinner(size: theme.typography.base)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text("Running")
                    .font(theme.font(theme.typography.sm, theme.typography.medium))

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(elapsedText(at: context.date))
                        .font(theme.typography.monoFont(theme.typography.xs))
                        .foregroundStyle(theme.colors.mutedForeground)
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
    @Environment(\.shadTheme) private var theme
    @State private var turn: GenerationTurn?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ShadIconView(run.succeeded ? .circleCheck : .triangleAlert, size: theme.typography.sm)
                .foregroundStyle(run.succeeded ? theme.colors.success : theme.colors.warning)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(run.completedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(theme.font(theme.typography.sm, theme.typography.medium))

                Text(run.errorMessage ?? run.actionSummary)
                    .font(theme.font(theme.typography.xs))
                    .foregroundStyle(run.succeeded ? theme.colors.mutedForeground : theme.colors.warning)
                    .lineLimit(2)

                Text(HeartbeatRun.metricsLine(duration: run.formattedDuration, tokens: run.formattedTokenUsage))
                    .font(theme.typography.monoFont(theme.typography.xs))
                    .foregroundStyle(theme.colors.mutedForeground)
                    .help(run.tokenUsageHelp ?? "Duration of this heartbeat run")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if run.generationTurnID != nil, let turn {
                GenerationInspectorButton(turn: turn)
            }
        }
        .padding(.vertical, 10)
        .task(id: run.generationTurnID) {
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
    @Environment(\.shadTheme) private var theme

    var body: some View {
        ShadTextarea(
            "",
            text: $text,
            minHeight: textareaContentHeight,
            maxHeight: textareaContentHeight
        )
            .accessibilityLabel(editorAccessibilityLabel)
            .overlay(alignment: .bottomTrailing) {
                ResizeGrip(helpText: resizeHelpText)
                    .padding(theme.spacing.sm)
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

    private var textareaContentHeight: CGFloat {
        max(0, height - (theme.spacing.xl + theme.borderWidth * 2))
    }

    private var editorAccessibilityLabel: String {
        resizeHelpText.replacingOccurrences(of: "Resize ", with: "")
    }
}

struct ResizeGrip: View {
    let helpText: String
    @Environment(\.shadTheme) private var theme

    var body: some View {
        Canvas { context, size in
            let stroke = StrokeStyle(lineWidth: theme.borderWidth, lineCap: .round)
            let color = theme.colors.mutedForeground.opacity(0.6)

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

private struct MentionHighlightingTextArea: View {
    @Environment(\.shadTheme) private var theme
    @Binding var text: String
    let placeholder: String
    let recognizedHandles: Set<String>
    @State private var isFocused = false

    init(
        placeholder: String,
        text: Binding<String>,
        recognizedHandles: Set<String>
    ) {
        self.placeholder = placeholder
        _text = text
        self.recognizedHandles = recognizedHandles
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(theme.font(theme.typography.sm))
                    .foregroundStyle(theme.colors.mutedForeground)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .allowsHitTesting(false)
            }

            MentionHighlightingTextView(
                text: $text,
                recognizedHandles: recognizedHandles,
                foregroundColor: NSColor(theme.colors.foreground),
                accentColor: NSColor(theme.colors.accent),
                onFocusChanged: { isFocused = $0 }
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: theme.radius.lg)
                .fill(theme.colorScheme == .dark ? theme.colors.input.opacity(0.3) : .clear)
        )
        .overlay {
            RoundedRectangle(cornerRadius: theme.radius.lg)
                .strokeBorder(
                    isFocused ? theme.colors.ring : theme.colors.input,
                    lineWidth: theme.borderWidth
                )
        }
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: theme.radius.lg + 2)
                    .strokeBorder(theme.colors.ring.opacity(0.18), lineWidth: 3)
                    .padding(-2)
            }
        }
        .animation(theme.interactionAnimation, value: isFocused)
    }
}

private struct MentionHighlightingTextView: NSViewRepresentable {
    @Binding var text: String
    let recognizedHandles: Set<String>
    let foregroundColor: NSColor
    let accentColor: NSColor
    let onFocusChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.drawsBackground = false
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 4, height: 2)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        scrollView.documentView = textView
        context.coordinator.applyHighlighting(to: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(
                NSRange(
                    location: min(selection.location, text.utf16.count),
                    length: 0
                )
            )
        }
        context.coordinator.applyHighlighting(to: textView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private static let mentionExpression = try? NSRegularExpression(
            pattern: "@[\\p{L}\\p{N}_-]+"
        )
        var parent: MentionHighlightingTextView
        private var isApplyingHighlighting = false

        init(parent: MentionHighlightingTextView) {
            self.parent = parent
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.onFocusChanged(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.onFocusChanged(false)
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingHighlighting,
                  let textView = notification.object as? NSTextView else {
                return
            }
            parent.text = textView.string
            applyHighlighting(to: textView)
        }

        func applyHighlighting(to textView: NSTextView) {
            guard !isApplyingHighlighting,
                  let storage = textView.textStorage else {
                return
            }
            isApplyingHighlighting = true
            defer { isApplyingHighlighting = false }

            let selection = textView.selectedRange()
            let fullRange = NSRange(location: 0, length: storage.length)
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = 2
            storage.beginEditing()
            storage.setAttributes(
                [
                    .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                    .foregroundColor: parent.foregroundColor,
                    .paragraphStyle: paragraphStyle,
                    .underlineStyle: 0
                ],
                range: fullRange
            )

            let source = textView.string
            let sourceRange = NSRange(location: 0, length: (source as NSString).length)
            for match in Self.mentionExpression?.matches(in: source, range: sourceRange) ?? [] {
                let mention = (source as NSString).substring(with: match.range)
                guard let lookupKey = AgentMention.lookupHandle(from: mention),
                      parent.recognizedHandles.contains(lookupKey) else {
                    continue
                }
                storage.addAttributes(
                    [
                        .font: NSFont.systemFont(
                            ofSize: NSFont.systemFontSize,
                            weight: .medium
                        ),
                        .foregroundColor: parent.accentColor,
                        .underlineColor: parent.accentColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue
                    ],
                    range: match.range
                )
            }
            storage.endEditing()
            if selection.location <= storage.length {
                textView.setSelectedRange(selection)
            }
        }
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
    private let dreamScheduler: DreamScheduler

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
            dreamScheduler = DreamScheduler(
                agentStore: agentStore,
                localModelStore: localModelStore,
                chatStore: chatStore,
                heartbeatScheduler: heartbeatScheduler
            )
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
            heartbeatScheduler: heartbeatScheduler,
            dreamScheduler: dreamScheduler
        )
        .modelContainer(modelContainer)
        .chatTheme()
        .frame(width: 900, height: 680)
    }
}
