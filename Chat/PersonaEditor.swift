import SwiftUI

#if os(macOS)
import AppKit
#endif

struct PersonasWindow: View {
    @ObservedObject var store: PersonaStore
    @ObservedObject var localModelStore: LocalModelStore
    @ObservedObject var chatStore: ChatStore

    var body: some View {
        NavigationSplitView {
            PersonaSidebar(store: store)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            PersonaEditor(store: store, localModelStore: localModelStore, chatStore: chatStore)
                .navigationSplitViewColumnWidth(min: 420, ideal: 560)
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}

struct PersonaSidebar: View {
    @ObservedObject var store: PersonaStore

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $store.selectedPersonaID) {
                ForEach(store.personas) { persona in
                    Text(persona.displayName)
                        .tag(persona.id)
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    store.addPersona()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add Persona")

                Button {
                    store.removeSelectedPersona()
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(store.selectedPersonaID == nil)
                .help("Remove Persona")

                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }
}

private let minimumSoulEditorHeight: CGFloat = 240
private let maximumSoulEditorHeight: CGFloat = 720

struct PersonaEditor: View {
    @ObservedObject var store: PersonaStore
    @ObservedObject var localModelStore: LocalModelStore
    @ObservedObject var chatStore: ChatStore
    @State private var draftSoul = ""
    @State private var soulEditorHeight: CGFloat = 360

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

    private var personaMemory: Binding<String> {
        Binding {
            selectedPersona?.memoryText ?? ""
        } set: { newValue in
            guard let personaID = selectedPersona?.id else { return }
            store.updatePersonaMemory(id: personaID, memory: newValue)
        }
    }

    var body: some View {
        Group {
            if let selectedPersona {
                editor(for: selectedPersona)
            } else {
                Text("Select or add a persona.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(red: 253 / 255, green: 253 / 255, blue: 252 / 255))
        .onAppear(perform: loadSelectedPersona)
        .onChange(of: store.selectedPersonaID) {
            loadSelectedPersona()
        }
    }

    private func editor(for persona: Persona) -> some View {
        HStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    TextField("Persona name", text: personaName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 22, weight: .semibold))
                        .frame(height: 54)

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
                    .pickerStyle(.menu)
                    .padding(.top, 12)

                    Text("Configure local models in Settings, then choose one for this persona.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)

                    Text("Soul")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.top, 28)
                        .padding(.bottom, 12)

                    ResizableSoulEditor(text: $draftSoul, height: $soulEditorHeight)

                    HStack {
                        Spacer()

                        Button("Save soul") {
                            store.updatePersonaSoul(id: persona.id, soul: draftSoul)
                        }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.top, 18)

                    Text("Memory")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.top, 32)
                        .padding(.bottom, 6)

                    Text("You can edit memory directly. The persona can append new entries, but it cannot change existing text.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 10)

                    PersonaMemoryEditor(text: personaMemory)

                    Text("Memory saves automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)

                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Heartbeats")
                                .font(.system(size: 15, weight: .semibold))

                            Text("Run recurring persona instructions while Chat is open.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            store.addHeartbeat(to: persona.id)
                        } label: {
                            Label("Add heartbeat", systemImage: "plus")
                        }
                    }
                    .padding(.top, 32)
                    .padding(.bottom, 12)

                    VStack(spacing: 12) {
                        ForEach(store.heartbeats(for: persona.id)) { heartbeat in
                            PersonaHeartbeatEditor(
                                heartbeat: heartbeat,
                                store: store,
                                localModelStore: localModelStore,
                                chatStore: chatStore
                            )
                        }

                        if store.heartbeats(for: persona.id).isEmpty {
                            Text("No heartbeats configured.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                        }
                    }
                }
                .frame(maxWidth: 760, alignment: .top)
                .padding(.top, 54)
                .padding(.bottom, 70)
                .padding(.horizontal, 48)
            }
            .frame(maxWidth: 856, maxHeight: .infinity, alignment: .top)

            Spacer(minLength: 0)
        }
    }

    private func loadSelectedPersona() {
        guard let selectedPersona else {
            draftSoul = ""
            return
        }

        load(selectedPersona)
    }

    private func load(_ persona: Persona) {
        draftSoul = persona.soul
    }

    private func isSelectedModelConfigured(_ identifier: String) -> Bool {
        identifier == ChatModelIdentifier.appleFoundation || localModelStore.localModels.contains {
            ChatModelIdentifier.localModelID($0.id) == identifier
        }
    }
}

struct PersonaMemoryEditor: View {
    @Binding var text: String

    var body: some View {
        SoulTextView(text: $text)
            .padding(12)
            .background(.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.gray.opacity(0.22), lineWidth: 1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 170)
    }
}

struct PersonaHeartbeatEditor: View {
    let heartbeat: PersonaHeartbeat
    @ObservedObject var store: PersonaStore
    @ObservedObject var localModelStore: LocalModelStore
    @ObservedObject var chatStore: ChatStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Toggle("Enabled", isOn: isEnabled)
                    .toggleStyle(.switch)

                Spacer()

                Button(role: .destructive) {
                    store.removeHeartbeat(heartbeat)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove heartbeat")
            }

            TextEditor(text: instruction)
                .font(.body)
                .frame(minHeight: 68, maxHeight: 100)
                .padding(6)
                .scrollContentBackground(.hidden)
                .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))

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
            .pickerStyle(.menu)
            .frame(maxWidth: 360)

            HStack(spacing: 18) {
                Stepper(value: intervalMinutes, in: 1...10_080) {
                    Text("Every \(heartbeat.normalizedIntervalMinutes) minutes")
                        .monospacedDigit()
                }

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
                .pickerStyle(.menu)
                .frame(maxWidth: 260)
            }

            if let lastError = heartbeat.lastError {
                Label(lastError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if let lastCompletedAt = heartbeat.lastCompletedAt {
                Text("Last completed \(lastCompletedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("The persona may post a reply, append memory, or pass.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.white.opacity(0.38), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.gray.opacity(0.18), lineWidth: 1)
        }
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

struct ResizableSoulEditor: View {
    @Binding var text: String
    @Binding var height: CGFloat
    @State private var dragStartHeight: CGFloat?

    var body: some View {
        SoulTextView(text: $text)
            .padding(12)
            .padding(.bottom, 8)
            .background(.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.gray.opacity(0.22), lineWidth: 1)
            }
            .overlay(alignment: .bottomTrailing) {
                ResizeGrip()
                    .padding(5)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let startHeight = dragStartHeight ?? height
                                dragStartHeight = startHeight
                                height = min(max(startHeight + value.translation.height, minimumSoulEditorHeight), maximumSoulEditorHeight)
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
        .help("Resize Soul editor")
    }
}
