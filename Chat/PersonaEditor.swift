import SwiftUI
import SwiftData

#if os(macOS)
import AppKit
#endif

struct PersonasPreferencesView: View {
    @ObservedObject var store: PersonaStore
    @ObservedObject var localModelStore: LocalModelStore
    @ObservedObject var textToSpeechToolStore: TextToSpeechToolStore
    @ObservedObject var chatStore: ChatStore
    @State private var isPresentingEditor = false

    var body: some View {
        Group {
            if isPresentingEditor {
                personaEditor
            } else {
                personaList
            }
        }
        .background(OpenUITheme.background)
    }

    private var personaList: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .center) {
                Text("Personas")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(OpenUITheme.foreground)

                Spacer()

                Button {
                    store.addPersona()
                    isPresentingEditor = true
                } label: {
                    Label("Add Persona", systemImage: "plus")
                }
                .buttonStyle(OpenUIPrimaryButtonStyle())
            }

            VStack(spacing: 0) {
                ForEach(Array(store.personas.enumerated()), id: \.element.id) { index, persona in
                    Button {
                        store.selectedPersonaID = persona.id
                        isPresentingEditor = true
                    } label: {
                        HStack {
                            Text(persona.displayName)
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
                    .accessibilityLabel("Edit \(persona.displayName)")

                    if index < store.personas.count - 1 {
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

    private var personaEditor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 16) {
                    Button("Personas") {
                        isPresentingEditor = false
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(OpenUITheme.foregroundMuted)
                    .accessibilityHint("Return to the persona list")

                    Image(systemName: "chevron.right")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(OpenUITheme.foregroundSubtle)

                    Text(store.selectedPersona?.displayName ?? "Persona")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(OpenUITheme.foreground)
                        .lineLimit(1)
                }

                PersonaEditor(
                    store: store,
                    localModelStore: localModelStore,
                    textToSpeechToolStore: textToSpeechToolStore,
                    chatStore: chatStore
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, 40)
            .padding(.vertical, 36)
        }
    }
}

private let minimumPersonaTextEditorHeight: CGFloat = 170
private let maximumPersonaTextEditorHeight: CGFloat = 720

struct PersonaEditor: View {
    @ObservedObject var store: PersonaStore
    @ObservedObject var localModelStore: LocalModelStore
    @ObservedObject var textToSpeechToolStore: TextToSpeechToolStore
    @ObservedObject var chatStore: ChatStore
    @State private var draftSoul = ""
    @State private var soulEditorHeight: CGFloat = 360
    @State private var draftMemory = ""
    @State private var memoryEditorHeight: CGFloat = 240

    private var selectedPersona: Persona? {
        store.selectedPersona
    }

    private var personaName: Binding<String> {
        Binding {
            selectedPersona?.name ?? ""
        } set: { newValue in
            guard let personaID = selectedPersona?.id else { return }
            store.updatePersonaName(id: personaID, name: newValue)
        }
    }

    private var personaModel: Binding<String> {
        Binding {
            selectedPersona?.selectedModelIdentifier ?? ChatModelIdentifier.appleFoundation
        } set: { newValue in
            guard let personaID = selectedPersona?.id else { return }
            store.updatePersonaModelIdentifier(id: personaID, modelIdentifier: newValue)
        }
    }

    private var voiceTriggerPhrasesText: Binding<String> {
        Binding {
            selectedPersona?.voiceTriggerPhrase ?? ""
        } set: { newValue in
            guard let personaID = selectedPersona?.id else { return }
            store.updatePersonaVoiceTriggerPhrases(id: personaID, phrasesText: newValue)
        }
    }

    private var textToSpeechToolID: Binding<TextToSpeechTool.ID?> {
        Binding {
            selectedPersona?.textToSpeechToolID
        } set: { newValue in
            guard let personaID = selectedPersona?.id else { return }
            store.updatePersonaTextToSpeechTool(id: personaID, toolID: newValue)
        }
    }

    private var textToSpeechVoiceName: Binding<String> {
        Binding {
            selectedPersona?.textToSpeechVoiceName ?? ""
        } set: { newValue in
            guard let personaID = selectedPersona?.id else { return }
            store.updatePersonaTextToSpeechVoiceName(id: personaID, voiceName: newValue)
        }
    }

    private var textToSpeechVoiceModel: Binding<String> {
        Binding {
            selectedPersona?.textToSpeechVoiceModel ?? ""
        } set: { newValue in
            guard let personaID = selectedPersona?.id else { return }
            store.updatePersonaTextToSpeechVoiceModel(id: personaID, voiceModel: newValue)
        }
    }

    private var hasUnsavedSoulChanges: Bool {
        draftSoul != selectedPersona?.soul
    }

    private var hasUnsavedMemoryChanges: Bool {
        draftMemory != selectedPersona?.memoryText
    }

    var body: some View {
        Group {
            if let selectedPersona {
                editor(for: selectedPersona)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 26))
                        .foregroundStyle(OpenUITheme.accent)

                    Text("Select or add a persona")
                        .font(.system(size: 15, weight: .semibold))

                    Text("Persona settings will appear here.")
                        .font(.system(size: 13))
                        .foregroundStyle(OpenUITheme.foregroundMuted)
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .openUICard()
            }
        }
        .onAppear(perform: loadSelectedPersona)
        .onChange(of: store.selectedPersonaID) {
            loadSelectedPersona()
        }
    }

    private func editor(for persona: Persona) -> some View {
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
                            TextField("Persona name", text: personaName)
                                .openUIInput()
                                .frame(width: 320)
                        }

                        OpenUIDivider()

                        OpenUISettingsRow(
                            title: "Default model",
                            description: "Heartbeats can override this selection individually."
                        ) {
                            Picker("Model", selection: personaModel) {
                                Text("Apple Foundation Model")
                                    .tag(ChatModelIdentifier.appleFoundation)

                                ForEach(localModelStore.localModels) { model in
                                    Text(model.displayName)
                                        .tag(ChatModelIdentifier.localModelID(model.id))
                                }

                                if !isSelectedModelConfigured(persona.selectedModelIdentifier) {
                                    Text("Missing local model")
                                        .tag(persona.selectedModelIdentifier)
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
                        ResizablePersonaTextEditor(
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
                                    store.updatePersonaSoul(id: persona.id, soul: draftSoul)
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
                        description: "Configure voice input and text-to-speech output for this persona."
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
                                    Text("Hey \(persona.displayName)\nWake up \(persona.displayName)")
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

                                if let selectedToolID = persona.textToSpeechToolID,
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
                        title: "Memory",
                        description: "You can edit all memory; the persona can only append new entries."
                    )

                    VStack(spacing: 0) {
                        ResizablePersonaTextEditor(
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
                                    store.updatePersonaMemory(id: persona.id, memory: draftMemory)
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
                            description: "Run recurring persona instructions while Chat is open."
                        )

                        Spacer()

                        Button {
                            store.addHeartbeat(to: persona.id)
                        } label: {
                            Label("Add heartbeat", systemImage: "plus")
                        }
                        .buttonStyle(OpenUISecondaryButtonStyle())
                    }

                    if store.heartbeats(for: persona.id).isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "waveform.path.ecg")
                                .font(.system(size: 22))
                                .foregroundStyle(OpenUITheme.foregroundSubtle)

                            Text("No heartbeats configured")
                                .font(.system(size: 14, weight: .medium))

                            Text("Add one to let this persona check in on a schedule.")
                                .font(.system(size: 13))
                                .foregroundStyle(OpenUITheme.foregroundMuted)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                        .openUICard()
                    } else {
                        VStack(spacing: 16) {
                            ForEach(store.heartbeats(for: persona.id)) { heartbeat in
                                PersonaHeartbeatEditor(
                                    heartbeat: heartbeat,
                                    store: store,
                                    localModelStore: localModelStore,
                                    chatStore: chatStore
                                )
                            }
                        }
                    }
                }
        }
        .frame(maxWidth: 720, alignment: .topLeading)
    }

    private func loadSelectedPersona() {
        guard let selectedPersona else {
            draftSoul = ""
            draftMemory = ""
            return
        }

        load(selectedPersona)
    }

    private func load(_ persona: Persona) {
        draftSoul = persona.soul
        draftMemory = persona.memoryText
    }

    private func isSelectedModelConfigured(_ identifier: String) -> Bool {
        identifier == ChatModelIdentifier.appleFoundation || localModelStore.localModels.contains {
            ChatModelIdentifier.localModelID($0.id) == identifier
        }
    }
}

struct PersonaHeartbeatEditor: View {
    let heartbeat: PersonaHeartbeat
    @ObservedObject var store: PersonaStore
    @ObservedObject var localModelStore: LocalModelStore
    @ObservedObject var chatStore: ChatStore

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

                Text("Tell the persona what to consider when this heartbeat runs.")
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
                description: "Override the persona's default for this heartbeat."
            ) {
                Picker("Model", selection: modelIdentifier) {
                    Text("Persona default (\(personaDefaultModelName))")
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
                description: "Select the private or group chat that receives posts."
            ) {
                Picker("Post to", selection: destination) {
                    Text("Private chat")
                        .tag("private")

                    if !chatStore.groupChats.isEmpty {
                        Section("Group chats") {
                            ForEach(chatStore.groupChats) { chat in
                                Text(chat.title)
                                    .tag("group.\(chat.id.uuidString)")
                            }
                        }
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

            if let lastError = heartbeat.lastError {
                OpenUIDivider()

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")

                    Text(lastError)
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .foregroundStyle(OpenUITheme.warningForeground)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(OpenUITheme.warningBackground)
            } else if let lastCompletedAt = heartbeat.lastCompletedAt {
                OpenUIDivider()

                Text("Last completed \(lastCompletedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 12))
                    .foregroundStyle(OpenUITheme.foregroundSubtle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            } else {
                OpenUIDivider()

                Text("The persona may post a reply, append memory, or pass.")
                    .font(.system(size: 12))
                    .foregroundStyle(OpenUITheme.foregroundSubtle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
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

    private var personaDefaultModelName: String {
        guard let persona = store.persona(for: heartbeat.personaID) else {
            return "Missing persona"
        }
        return localModelStore.displayName(for: persona.selectedModelIdentifier)
    }

    private func isModelConfigured(_ identifier: String) -> Bool {
        identifier == ChatModelIdentifier.appleFoundation || localModelStore.localModels.contains {
            ChatModelIdentifier.localModelID($0.id) == identifier
        }
    }

    private var destination: Binding<String> {
        Binding {
            guard heartbeat.targetKind == .groupChat,
                  let targetChatID = heartbeat.targetChatID else {
                return "private"
            }
            return "group.\(targetChatID.uuidString)"
        } set: { newValue in
            guard newValue.hasPrefix("group."),
                  let targetChatID = UUID(uuidString: String(newValue.dropFirst("group.".count))) else {
                store.updateHeartbeatDestination(
                    heartbeat,
                    targetKind: .privateChat,
                    targetChatID: nil
                )
                return
            }
            store.updateHeartbeatDestination(
                heartbeat,
                targetKind: .groupChat,
                targetChatID: targetChatID
            )
        }
    }
}

struct ResizablePersonaTextEditor: View {
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
                                    max(startHeight + value.translation.height, minimumPersonaTextEditorHeight),
                                    maximumPersonaTextEditorHeight
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

#Preview("Personas Preferences") {
    PersonasPreferencesViewPreview()
}

private struct PersonasPreferencesViewPreview: View {
    private let modelContainer: ModelContainer
    private let personaStore: PersonaStore
    private let localModelStore: LocalModelStore
    private let textToSpeechToolStore: TextToSpeechToolStore
    private let chatStore: ChatStore

    init() {
        do {
            let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
            let container = try ModelContainer(
                for: Persona.self,
                PersonaHeartbeat.self,
                HeartbeatRun.self,
                LocalModel.self,
                TextToSpeechTool.self,
                StoredChat.self,
                StoredGroupChatParticipant.self,
                StoredChatMessage.self,
                configurations: configuration
            )
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
                    Persona(
                        name: name,
                        soul: "Be a thoughtful participant in the conversation.",
                        modelIdentifier: ChatModelIdentifier.localModelID(localModel.id)
                    )
                )
            }
            try context.save()

            let personaStore = PersonaStore(modelContext: context)
            let localModelStore = LocalModelStore(modelContext: context)
            let textToSpeechToolStore = TextToSpeechToolStore(modelContext: context)
            modelContainer = container
            self.personaStore = personaStore
            self.localModelStore = localModelStore
            self.textToSpeechToolStore = textToSpeechToolStore
            chatStore = ChatStore(
                personaStore: personaStore,
                localModelStore: localModelStore,
                modelContext: context
            )
        } catch {
            fatalError("Failed to create Personas preferences preview: \(error.localizedDescription)")
        }
    }

    var body: some View {
        PersonasPreferencesView(
            store: personaStore,
            localModelStore: localModelStore,
            textToSpeechToolStore: textToSpeechToolStore,
            chatStore: chatStore
        )
        .modelContainer(modelContainer)
        .frame(width: 900, height: 680)
    }
}
