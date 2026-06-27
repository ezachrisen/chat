import Foundation
import FoundationModels
import Combine
import SwiftData
import SwiftUI

@main
struct ChatApp: App {
    private let modelContainer: ModelContainer
    @StateObject private var personaStore: PersonaStore
    @StateObject private var chatStore: ChatStore

    init() {
        do {
            let container = try ModelContainer(for: Persona.self, StoredChat.self, StoredChatMessage.self)
            let personaStore = PersonaStore(modelContext: container.mainContext)
            modelContainer = container
            _personaStore = StateObject(wrappedValue: personaStore)
            _chatStore = StateObject(wrappedValue: ChatStore(personaStore: personaStore, modelContext: container.mainContext))
        } catch {
            fatalError("Failed to create model container: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(personaStore: personaStore, chatStore: chatStore)
                .modelContainer(modelContainer)
        }
        .commands {
            PersonaCommands()
            DeveloperCommands(chatStore: chatStore)
        }

        Window("Personas", id: "personas") {
            PersonasWindow(store: personaStore)
                .modelContainer(modelContainer)
        }
    }
}

struct ContentView: View {
    @ObservedObject private var personaStore: PersonaStore
    @ObservedObject private var chatStore: ChatStore

    init(personaStore: PersonaStore, chatStore: ChatStore) {
        self.personaStore = personaStore
        self.chatStore = chatStore
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
    @State private var chatBeingRenamed: ChatViewModel?
    @State private var renameDraft = ""
    @State private var renameAlertIsPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            newChatControl
                .padding(.top, 20)
                .padding(.horizontal, 20)

            Text("Chats")
                .font(.body.weight(.medium))
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
                                isCollapsed: collapsedPersonaIDs.contains(persona.id),
                                onRenameChat: beginRenaming
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
        .alert("Rename chat", isPresented: $renameAlertIsPresented) {
            TextField("Chat name", text: $renameDraft)

            Button("Cancel", role: .cancel) { }
            Button("Rename") {
                chatBeingRenamed?.rename(to: renameDraft)
            }
        }
    }

    private func beginRenaming(_ chat: ChatViewModel) {
        chatBeingRenamed = chat
        renameDraft = chat.title
        renameAlertIsPresented = true
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
                .font(.body)
                .frame(width: 20, height: 20)

            Text("New chat")
                .font(.body)

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
    let onRenameChat: (ChatViewModel) -> Void
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .font(.body)
                        .frame(width: 20, height: 20)

                    Text(persona.displayName)
                        .font(.body)
                        .lineLimit(1)

                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0))

                    Spacer(minLength: 0)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(chats) { chat in
                        ChatRow(
                            chat: chat,
                            isSelected: selectedChatID == chat.id,
                            onRename: {
                                onRenameChat(chat)
                            }
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
    let onRename: () -> Void
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 0) {
                Text(chat.title)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }
            .foregroundStyle(.primary)
            .padding(.leading, 64)
            .padding(.trailing, 12)
            .frame(height: 30)
            .background(isSelected ? Color.primary.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename chat") {
                onRename()
            }
        }
    }
}

struct ChatDetailView: View {
    @ObservedObject var chat: ChatViewModel
    @FocusState private var composerIsFocused: Bool
    @State private var newestMessageID: ChatMessage.ID?
    @State private var visibleMessageIDs: Set<ChatMessage.ID> = []
    @State private var hasUnreadNewMessages = false

    var body: some View {
        VStack(spacing: 0) {
            modelStatus
                .padding(.horizontal)
                .padding(.top)

            ScrollViewReader { proxy in
                ZStack(alignment: .bottom) {
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            ForEach(chat.messages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                                    .onAppear {
                                        visibleMessageIDs.insert(message.id)

                                        if message.id == chat.messages.last?.id {
                                            hasUnreadNewMessages = false
                                        }

                                        if message.id == chat.messages.first?.id {
                                            chat.loadOlderMessages()
                                        }
                                    }
                                    .onDisappear {
                                        visibleMessageIDs.remove(message.id)
                                    }
                            }

                            if chat.isResponding {
                                TypingBubble()
                                    .id(ChatViewModel.typingIndicatorID)
                            }
                        }
                        .padding()
                    }
                    .background(Color.secondary.opacity(0.08))

                    if shouldShowMoreMessagesButton {
                        Button {
                            hasUnreadNewMessages = false
                            scrollToBottom(with: proxy)
                        } label: {
                            Label(moreMessagesButtonTitle, systemImage: "arrow.down")
                                .font(.callout.weight(.medium))
                                .padding(.horizontal, 18)
                                .padding(.vertical, 10)
                                .background(.regularMaterial, in: Capsule())
                                .overlay {
                                    Capsule()
                                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                                }
                        }
                        .buttonStyle(.plain)
                        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                        .padding(.bottom, 14)
                    }
                }
                .onAppear {
                    scrollToBottomAfterLayout(with: proxy)
                }
                .onChange(of: chat.id) {
                    visibleMessageIDs.removeAll()
                    hasUnreadNewMessages = false
                    scrollToBottomAfterLayout(with: proxy)
                }
                .onChange(of: chat.messages) {
                    scrollToNewestMessageIfNeeded(with: proxy)
                }
                .onChange(of: chat.isResponding) {
                    if latestMessageIsVisible {
                        scrollToBottom(with: proxy)
                    }
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

    private var shouldShowMoreMessagesButton: Bool {
        hasUnreadNewMessages || isScrolledMoreThanFiveMessagesFromLatest
    }

    private var moreMessagesButtonTitle: String {
        hasUnreadNewMessages ? "New messages" : "More messages"
    }

    private var latestMessageIsVisible: Bool {
        guard let latestMessageID = chat.messages.last?.id else { return true }
        return visibleMessageIDs.contains(latestMessageID)
    }

    private var isScrolledMoreThanFiveMessagesFromLatest: Bool {
        guard !visibleMessageIDs.isEmpty,
              chat.messages.count > 5,
              let newestVisibleIndex = chat.messages.lastIndex(where: { visibleMessageIDs.contains($0.id) }) else {
            return false
        }

        return newestVisibleIndex < chat.messages.count - 5
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

    private func scrollToNewestMessageIfNeeded(with proxy: ScrollViewProxy) {
        let previousNewestMessageID = newestMessageID
        let latestMessageID = chat.messages.last?.id
        defer { newestMessageID = latestMessageID }

        guard latestMessageID != previousNewestMessageID else { return }

        if previousNewestMessageID == nil || previousNewestMessageID.map(visibleMessageIDs.contains) == true {
            hasUnreadNewMessages = false
            scrollToBottom(with: proxy)
        } else {
            hasUnreadNewMessages = true
        }
    }

    private func scrollToBottomAfterLayout(with proxy: ScrollViewProxy) {
        newestMessageID = chat.messages.last?.id
        hasUnreadNewMessages = false

        Task { @MainActor in
            await Task.yield()
            scrollToBottom(with: proxy, animated: false)
        }
    }

    private func scrollToBottom(with proxy: ScrollViewProxy, animated: Bool = true) {
        let target = chat.isResponding ? ChatViewModel.typingIndicatorID : chat.messages.last?.id

        guard let target else { return }

        if animated {
            withAnimation(.snappy) {
                proxy.scrollTo(target, anchor: .bottom)
            }
        } else {
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

struct DeveloperCommands: Commands {
    @ObservedObject var chatStore: ChatStore

    var body: some Commands {
        CommandMenu("Developer") {
            Button("Add 1,000 messages") {
                chatStore.addFakeMessagesToSelectedChat(count: 1_000)
            }
            .disabled(chatStore.selectedChat == nil)

            Button("Slow response") {
                chatStore.addSlowResponseToSelectedChat()
            }
            .disabled(chatStore.selectedChat == nil)
        }
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

@Model
final class StoredChat: Identifiable {
    @Attribute(.unique) var id: UUID
    var personaID: UUID
    var personaName: String
    var personaSoul: String
    var title: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        personaID: UUID,
        personaName: String,
        personaSoul: String,
        title: String = "New chat",
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.personaID = personaID
        self.personaName = personaName
        self.personaSoul = personaSoul
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class StoredChatMessage: Identifiable {
    @Attribute(.unique) var id: UUID
    var chatID: UUID
    var roleRawValue: String
    var text: String
    var createdAt: Date

    init(id: UUID = UUID(), chatID: UUID, role: ChatRole, text: String, createdAt: Date = .now) {
        self.id = id
        self.chatID = chatID
        self.roleRawValue = role.rawValue
        self.text = text
        self.createdAt = createdAt
    }

    var role: ChatRole {
        ChatRole(rawValue: roleRawValue) ?? .assistant
    }
}

@MainActor
final class ChatStore: ObservableObject {
    private static let messageBatchSize = 40

    @Published var chats: [ChatViewModel] = []
    @Published var selectedChatID: ChatViewModel.ID?

    private let modelContext: ModelContext

    var selectedChat: ChatViewModel? {
        guard let selectedChatID else { return nil }
        return chats.first { $0.id == selectedChatID }
    }

    init(personaStore: PersonaStore, modelContext: ModelContext) {
        self.modelContext = modelContext
        loadChats()

        if chats.isEmpty, let persona = personaStore.personas.first {
            startChat(with: persona)
        } else {
            selectedChatID = chats.first?.id
        }
    }

    func startChat(with persona: Persona) {
        let storedChat = StoredChat(
            personaID: persona.id,
            personaName: persona.displayName,
            personaSoul: persona.soul
        )
        modelContext.insert(storedChat)

        let greeting = StoredChatMessage(
            chatID: storedChat.id,
            role: .assistant,
            text: "New chat with \(persona.displayName). What would you like to ask?"
        )
        modelContext.insert(greeting)
        saveChanges()

        let chat = ChatViewModel(storedChat: storedChat, storedMessages: [greeting], modelContext: modelContext)
        chats.insert(chat, at: 0)
        selectedChatID = chat.id
    }

    func chats(for personaID: Persona.ID) -> [ChatViewModel] {
        chats.filter { $0.personaID == personaID }
    }

    func addFakeMessagesToSelectedChat(count: Int) {
        selectedChat?.addFakeMessages(count: count)
    }

    func addSlowResponseToSelectedChat() {
        selectedChat?.addSlowResponse()
    }

    private func loadChats() {
        let descriptor = FetchDescriptor<StoredChat>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )

        do {
            let storedChats = try modelContext.fetch(descriptor)
            chats = storedChats.map { storedChat in
                ChatViewModel(
                    storedChat: storedChat,
                    storedMessages: fetchMessages(for: storedChat.id),
                    modelContext: modelContext
                )
            }
        } catch {
            chats = []
        }
    }

    private func fetchMessages(for chatID: UUID) -> [StoredChatMessage] {
        var descriptor = FetchDescriptor<StoredChatMessage>(
            predicate: #Predicate { message in
                message.chatID == chatID
            },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = ChatStore.messageBatchSize

        do {
            return try modelContext.fetch(descriptor).reversed()
        } catch {
            return []
        }
    }

    private func saveChanges() {
        guard modelContext.hasChanges else { return }

        do {
            try modelContext.save()
        } catch {
            assertionFailure("Failed to save chats: \(error.localizedDescription)")
        }
    }
}

@MainActor
final class ChatViewModel: ObservableObject, Identifiable {
    static let typingIndicatorID = UUID()
    private static let messageBatchSize = 40

    var id: UUID { storedChat.id }
    var personaID: Persona.ID { storedChat.personaID }
    var personaName: String { storedChat.personaName }

    @Published var draft = ""
    @Published private(set) var title: String
    @Published private(set) var messages: [ChatMessage]
    @Published private(set) var isLoadingOlderMessages = false
    @Published private(set) var hasOlderMessages: Bool
    @Published private(set) var isResponding = false
    @Published private(set) var availabilityMessage = ""
    @Published private(set) var canSend = false

    private let model = SystemLanguageModel.default
    private let modelContext: ModelContext
    private let storedChat: StoredChat
    private var session: LanguageModelSession

    var canSubmitDraft: Bool {
        canSend && !isResponding && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(storedChat: StoredChat, storedMessages: [StoredChatMessage], modelContext: ModelContext) {
        self.storedChat = storedChat
        self.modelContext = modelContext
        title = storedChat.title
        messages = storedMessages.map(ChatMessage.init(storedMessage:))
        hasOlderMessages = storedMessages.count == ChatViewModel.messageBatchSize
        session = ChatViewModel.makeSession(soul: storedChat.personaSoul)
        updateAvailability()
    }

    func loadOlderMessages() {
        guard hasOlderMessages,
              !isLoadingOlderMessages,
              let oldestMessage = messages.first else {
            return
        }

        isLoadingOlderMessages = true
        defer { isLoadingOlderMessages = false }

        let oldestMessageDate = oldestMessage.createdAt
        var descriptor = FetchDescriptor<StoredChatMessage>(
            predicate: #Predicate { message in
                message.chatID == id && message.createdAt < oldestMessageDate
            },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = ChatViewModel.messageBatchSize

        do {
            let olderMessages = try modelContext.fetch(descriptor).reversed().map(ChatMessage.init(storedMessage:))
            hasOlderMessages = olderMessages.count == ChatViewModel.messageBatchSize
            messages.insert(contentsOf: olderMessages, at: 0)
        } catch {
            hasOlderMessages = false
        }
    }

    func rename(to title: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        updateTitle(trimmedTitle.isEmpty ? "New chat" : trimmedTitle)
    }

    func addFakeMessages(count: Int) {
        guard count > 0 else { return }

        let startingIndex = messages.count + 1
        let storedMessages = (0..<count).map { offset in
            let messageNumber = startingIndex + offset
            let role: ChatRole = messageNumber.isMultiple(of: 2) ? .assistant : .user
            return StoredChatMessage(
                chatID: id,
                role: role,
                text: "Fake message \(messageNumber)",
                createdAt: Date().addingTimeInterval(TimeInterval(offset) * 0.001)
            )
        }

        for storedMessage in storedMessages {
            modelContext.insert(storedMessage)
        }

        storedChat.updatedAt = .now
        saveChanges()
        messages.append(contentsOf: storedMessages.map(ChatMessage.init(storedMessage:)))
    }

    func addSlowResponse() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            appendMessage(role: .assistant, text: "Slow response")
        }
    }

    func send() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)

        guard canSubmitDraft, !prompt.isEmpty else { return }

        if title == "New chat" {
            updateTitle(String(prompt.prefix(48)))
        }

        draft = ""
        appendMessage(role: .user, text: prompt)
        isResponding = true

        Task {
            await respond(to: prompt)
        }
    }

    private func respond(to prompt: String) async {
        do {
            let response = try await session.respond(to: prompt)
            appendMessage(role: .assistant, text: response.content)
        } catch {
            appendMessage(role: .assistant, text: "I could not get a response: \(error.localizedDescription)")
        }

        isResponding = false
        updateAvailability()
    }

    private func appendMessage(role: ChatRole, text: String) {
        let storedMessage = StoredChatMessage(chatID: id, role: role, text: text)
        modelContext.insert(storedMessage)
        storedChat.updatedAt = .now
        saveChanges()
        messages.append(ChatMessage(storedMessage: storedMessage))
    }

    private func updateTitle(_ newTitle: String) {
        title = newTitle
        storedChat.title = newTitle
        storedChat.updatedAt = .now
        saveChanges()
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

    private func saveChanges() {
        guard modelContext.hasChanges else { return }

        do {
            try modelContext.save()
        } catch {
            assertionFailure("Failed to save chat: \(error.localizedDescription)")
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
    let id: UUID
    let role: ChatRole
    let text: String
    let createdAt: Date

    init(id: UUID = UUID(), role: ChatRole, text: String, createdAt: Date = .now) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }

    init(storedMessage: StoredChatMessage) {
        id = storedMessage.id
        role = storedMessage.role
        text = storedMessage.text
        createdAt = storedMessage.createdAt
    }
}

enum ChatRole: String {
    case user
    case assistant
}

#Preview {
    ContentViewPreview()
}

struct ContentViewPreview: View {
    private let modelContainer: ModelContainer
    private let personaStore: PersonaStore
    private let chatStore: ChatStore

    init() {
        do {
            let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
            let container = try ModelContainer(for: Persona.self, StoredChat.self, StoredChatMessage.self, configurations: configuration)
            let personaStore = PersonaStore(modelContext: container.mainContext)
            modelContainer = container
            self.personaStore = personaStore
            chatStore = ChatStore(personaStore: personaStore, modelContext: container.mainContext)
        } catch {
            fatalError("Failed to create preview model container: \(error.localizedDescription)")
        }
    }

    var body: some View {
        ContentView(personaStore: personaStore, chatStore: chatStore)
            .modelContainer(modelContainer)
    }
}
