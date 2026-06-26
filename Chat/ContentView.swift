import Foundation
import FoundationModels
import Combine
import SwiftData
import SwiftUI

#if os(macOS)
import AppKit
#endif

@main
struct ChatApp: App {
    private let modelContainer: ModelContainer
    @StateObject private var personaStore: PersonaStore

    init() {
        do {
            let container = try ModelContainer(for: Persona.self)
            modelContainer = container
            _personaStore = StateObject(wrappedValue: PersonaStore(modelContext: container.mainContext))
        } catch {
            fatalError("Failed to create model container: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(personaStore: personaStore)
                .modelContainer(modelContainer)
        }
        .commands {
            PersonaCommands()
        }

        Window("Personas", id: "personas") {
            PersonasWindow(store: personaStore)
                .modelContainer(modelContainer)
        }
    }
}

struct ContentView: View {
    @ObservedObject private var personaStore: PersonaStore
    @StateObject private var chatStore: ChatStore

    init(personaStore: PersonaStore) {
        self.personaStore = personaStore
        _chatStore = StateObject(wrappedValue: ChatStore(personaStore: personaStore))
    }

    var body: some View {
        NavigationSplitView {
            ChatSidebar(personaStore: personaStore, chatStore: chatStore)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            if let chat = chatStore.selectedChat {
                ChatDetailView(chat: chat)
            } else {
                Text("Start a new chat.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 820, minHeight: 560)
    }
}

struct ChatSidebar: View {
    @ObservedObject var personaStore: PersonaStore
    @ObservedObject var chatStore: ChatStore
    @State private var collapsedPersonaIDs: Set<Persona.ID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            newChatControl
                .padding(.top, 20)
                .padding(.horizontal, 20)

            Text("Projects")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.top, 28)
                .padding(.horizontal, 20)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(personaStore.personas) { persona in
                        let chats = chatStore.chats(for: persona.id)

                        if !chats.isEmpty {
                            PersonaProjectSection(
                                persona: persona,
                                chats: chats,
                                selectedChatID: $chatStore.selectedChatID,
                                isCollapsed: collapsedPersonaIDs.contains(persona.id)
                            ) {
                                togglePersona(persona.id)
                            }
                        }
                    }
                }
                .padding(.top, 14)
                .padding(.horizontal, 12)
            }
        }
    }

    private func togglePersona(_ personaID: Persona.ID) {
        if collapsedPersonaIDs.contains(personaID) {
            collapsedPersonaIDs.remove(personaID)
        } else {
            collapsedPersonaIDs.insert(personaID)
        }
    }

    @ViewBuilder
    private var newChatControl: some View {
        if personaStore.personas.count > 1 {
            Menu {
                ForEach(personaStore.personas) { persona in
                    Button(persona.displayName) {
                        chatStore.startChat(with: persona)
                    }
                }
            } label: {
                NewChatLabel()
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .help("Start a new chat")
        } else {
            Button {
                guard let persona = personaStore.personas.first else { return }
                chatStore.startChat(with: persona)
            } label: {
                NewChatLabel()
            }
            .buttonStyle(.plain)
            .disabled(personaStore.personas.isEmpty)
            .help("Start a new chat")
        }
    }
}

struct NewChatLabel: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 18, weight: .regular))
                .frame(width: 24, height: 24)

            Text("New chat")
                .font(.system(size: 20, weight: .regular))

            Spacer()
        }
        .foregroundStyle(.primary)
        .contentShape(Rectangle())
    }
}

struct PersonaProjectSection: View {
    let persona: Persona
    let chats: [ChatViewModel]
    @Binding var selectedChatID: ChatViewModel.ID?
    let isCollapsed: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .font(.system(size: 17, weight: .regular))
                        .frame(width: 22, height: 22)

                    Text(persona.displayName)
                        .font(.system(size: 19, weight: .regular))
                        .lineLimit(1)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0))

                    Spacer(minLength: 0)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .frame(height: 42)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(chats) { chat in
                        ChatRow(
                            chat: chat,
                            isSelected: selectedChatID == chat.id
                        ) {
                            selectedChatID = chat.id
                        }
                    }
                }
                .padding(.bottom, 16)
            }
        }
    }
}

struct ChatRow: View {
    @ObservedObject var chat: ChatViewModel
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 0) {
                Text(chat.title)
                    .font(.system(size: 18, weight: .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }
            .foregroundStyle(.primary)
            .padding(.leading, 64)
            .padding(.trailing, 12)
            .frame(height: 38)
            .background(isSelected ? Color.primary.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ChatDetailView: View {
    @ObservedObject var chat: ChatViewModel
    @FocusState private var composerIsFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            modelStatus
                .padding(.horizontal)
                .padding(.top)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(chat.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }

                        if chat.isResponding {
                            TypingBubble()
                                .id(ChatViewModel.typingIndicatorID)
                        }
                    }
                    .padding()
                }
                .background(Color.secondary.opacity(0.08))
                .onChange(of: chat.messages) {
                    scrollToBottom(with: proxy)
                }
                .onChange(of: chat.isResponding) {
                    scrollToBottom(with: proxy)
                }
            }

            composer
                .padding()
                .background(.bar)
        }
        .navigationTitle(chat.title)
    }

    private var modelStatus: some View {
        HStack(spacing: 10) {
            Image(systemName: chat.canSend ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(chat.canSend ? .green : .orange)

            Text(chat.availabilityMessage)
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message", text: $chat.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(12)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .focused($composerIsFocused)
                .submitLabel(.send)
                .onSubmit {
                    submitDraft()
                }
                .disabled(!chat.canSend || chat.isResponding)

            Button {
                submitDraft()
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!chat.canSubmitDraft)
            .help("Send message")
        }
    }

    private func submitDraft() {
        chat.send()
        composerIsFocused = true
    }

    private func scrollToBottom(with proxy: ScrollViewProxy) {
        let target = chat.isResponding ? ChatViewModel.typingIndicatorID : chat.messages.last?.id

        guard let target else { return }

        withAnimation(.snappy) {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .assistant {
                bubble
                Spacer(minLength: 40)
            } else {
                Spacer(minLength: 40)
                bubble
            }
        }
    }

    private var bubble: some View {
        Text(message.text)
            .textSelection(.enabled)
            .font(.body)
            .foregroundStyle(message.role == .user ? .white : .primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(message.role == .user ? Color.accentColor : Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: 620, alignment: message.role == .user ? .trailing : .leading)
    }
}

struct TypingBubble: View {
    var body: some View {
        HStack {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)

                Text("Thinking")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))

            Spacer(minLength: 40)
        }
    }
}

struct PersonaCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Button("Personas") {
                openWindow(id: "personas")
            }
        }
    }
}

struct PersonasWindow: View {
    @ObservedObject var store: PersonaStore

    var body: some View {
        NavigationSplitView {
            PersonaSidebar(store: store)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            PersonaEditor(store: store)
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
            VStack(alignment: .leading, spacing: 0) {
                TextField("Persona name", text: personaName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .semibold))
                    .frame(height: 54)

                Text("Soul")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.top, 34)
                    .padding(.bottom, 12)

                ResizableSoulEditor(text: $draftSoul, height: $soulEditorHeight)

                HStack {
                    Spacer()

                    Button("Save") {
                        store.updatePersonaSoul(id: persona.id, soul: draftSoul)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                }
                .padding(.top, 22)
            }
            .frame(maxWidth: 760, maxHeight: .infinity, alignment: .top)
            .padding(.top, 70)
            .padding(.bottom, 70)
            .padding(.horizontal, 48)

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

@MainActor
final class PersonaStore: ObservableObject {
    @Published private(set) var personas: [Persona] = []
    @Published var selectedPersonaID: Persona.ID?

    private let modelContext: ModelContext

    var selectedPersona: Persona? {
        guard let selectedPersonaID else { return nil }
        return personas.first { $0.id == selectedPersonaID }
    }

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        loadPersonas()
    }

    func addPersona() {
        let persona = Persona(name: "", soul: "")
        modelContext.insert(persona)
        saveChanges()
        loadPersonas(selecting: persona.id)
    }

    func removeSelectedPersona() {
        guard let selectedPersonaID,
              let index = personas.firstIndex(where: { $0.id == selectedPersonaID }) else {
            return
        }

        let nextSelection: Persona.ID?
        if personas.count <= 1 {
            nextSelection = nil
        } else {
            let nextIndex = min(index, personas.count - 2)
            nextSelection = personas[nextIndex == index ? index + 1 : nextIndex].id
        }

        modelContext.delete(personas[index])
        saveChanges()
        loadPersonas(selecting: nextSelection)
    }

    func updatePersonaName(id: Persona.ID, name: String) {
        guard let persona = personas.first(where: { $0.id == id }) else { return }

        persona.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        saveChanges()
        objectWillChange.send()
    }

    func updatePersonaSoul(id: Persona.ID, soul: String) {
        guard let persona = personas.first(where: { $0.id == id }) else { return }

        persona.soul = soul
        saveChanges()
        objectWillChange.send()
    }

    private func loadPersonas(selecting selection: Persona.ID? = nil) {
        let descriptor = FetchDescriptor<Persona>(
            sortBy: [SortDescriptor(\.createdAt)]
        )

        do {
            personas = try modelContext.fetch(descriptor)
        } catch {
            personas = []
        }

        if personas.isEmpty {
            let persona = Persona(name: "Default", soul: "You are a concise, very quirky and goofy assistant inside a simple chat app.")
            modelContext.insert(persona)
            saveChanges()
            personas = [persona]
        }

        selectedPersonaID = selection.flatMap { selectedID in
            personas.contains { $0.id == selectedID } ? selectedID : nil
        } ?? selectedPersonaID.flatMap { selectedID in
            personas.contains { $0.id == selectedID } ? selectedID : nil
        } ?? personas.first?.id
    }

    private func saveChanges() {
        guard modelContext.hasChanges else { return }

        do {
            try modelContext.save()
        } catch {
            assertionFailure("Failed to save personas: \(error.localizedDescription)")
        }
    }
}

@Model
final class Persona: Identifiable {
    @Attribute(.unique) var id: UUID
    var name: String
    var soul: String
    var createdAt: Date

    init(id: UUID = UUID(), name: String, soul: String, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.soul = soul
        self.createdAt = createdAt
    }

    var displayName: String {
        name.isEmpty ? "Untitled Persona" : name
    }
}

@MainActor
final class ChatStore: ObservableObject {
    @Published var chats: [ChatViewModel] = []
    @Published var selectedChatID: ChatViewModel.ID?

    var selectedChat: ChatViewModel? {
        guard let selectedChatID else { return nil }
        return chats.first { $0.id == selectedChatID }
    }

    init(personaStore: PersonaStore) {
        if let persona = personaStore.personas.first {
            startChat(with: persona)
        }
    }

    func startChat(with persona: Persona) {
        let chat = ChatViewModel(persona: persona)
        chats.insert(chat, at: 0)
        selectedChatID = chat.id
    }

    func chats(for personaID: Persona.ID) -> [ChatViewModel] {
        chats.filter { $0.personaID == personaID }
    }
}

@MainActor
final class ChatViewModel: ObservableObject, Identifiable {
    static let typingIndicatorID = UUID()

    let id = UUID()
    let personaID: Persona.ID
    let personaName: String

    @Published var draft = ""
    @Published private(set) var title = "New chat"
    @Published private(set) var messages: [ChatMessage]
    @Published private(set) var isResponding = false
    @Published private(set) var availabilityMessage = ""
    @Published private(set) var canSend = false

    private let model = SystemLanguageModel.default
    private var session: LanguageModelSession

    var canSubmitDraft: Bool {
        canSend && !isResponding && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(persona: Persona) {
        personaID = persona.id
        personaName = persona.displayName
        messages = [
            ChatMessage(role: .assistant, text: "New chat with \(persona.displayName). What would you like to ask?")
        ]
        session = ChatViewModel.makeSession(soul: persona.soul)
        updateAvailability()
    }

    func send() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)

        guard canSubmitDraft, !prompt.isEmpty else { return }

        if title == "New chat" {
            title = String(prompt.prefix(48))
        }

        draft = ""
        messages.append(ChatMessage(role: .user, text: prompt))
        isResponding = true

        Task {
            await respond(to: prompt)
        }
    }

    private func respond(to prompt: String) async {
        do {
            let response = try await session.respond(to: prompt)
            messages.append(ChatMessage(role: .assistant, text: response.content))
        } catch {
            messages.append(ChatMessage(role: .assistant, text: "I could not get a response: \(error.localizedDescription)"))
        }

        isResponding = false
        updateAvailability()
    }

    private func updateAvailability() {
        switch model.availability {
        case .available:
            canSend = true
            availabilityMessage = "On-device Foundation model is ready."
        case .unavailable(.deviceNotEligible):
            canSend = false
            availabilityMessage = "This device is not eligible for Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            canSend = false
            availabilityMessage = "Turn on Apple Intelligence in Settings to chat."
        case .unavailable(.modelNotReady):
            canSend = false
            availabilityMessage = "The on-device model is not ready yet."
        case .unavailable:
            canSend = false
            availabilityMessage = "The on-device model is unavailable right now."
        }
    }

    private static func makeSession(soul: String) -> LanguageModelSession {
        let trimmedSoul = soul.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructions = trimmedSoul.isEmpty ? """
        You are a concise assistant inside a simple chat app.
        Answer conversationally, and don't feel the need to ask a follow-up question unless it's natural.
        """ : trimmedSoul

        return LanguageModelSession(instructions: instructions)
    }
}

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: ChatRole
    let text: String
}

enum ChatRole {
    case user
    case assistant
}

#Preview {
    ContentViewPreview()
}

struct ContentViewPreview: View {
    private let modelContainer: ModelContainer
    private let personaStore: PersonaStore

    init() {
        do {
            let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
            let container = try ModelContainer(for: Persona.self, configurations: configuration)
            modelContainer = container
            personaStore = PersonaStore(modelContext: container.mainContext)
        } catch {
            fatalError("Failed to create preview model container: \(error.localizedDescription)")
        }
    }

    var body: some View {
        ContentView(personaStore: personaStore)
            .modelContainer(modelContainer)
    }
}
