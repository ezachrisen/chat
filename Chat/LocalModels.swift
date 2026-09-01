import Combine
import Foundation
import Security
import SwiftData

#if os(macOS)
import AppKit
#endif

nonisolated enum ChatModelIdentifier {
    static let appleFoundation = "apple.foundation"
    static let chatGPTDefault = "chatgpt.default"
    private static let chatGPTModelPrefix = "chatgpt.model."

    static func localModelID(_ id: UUID) -> String {
        "local.\(id.uuidString.lowercased())"
    }

    static func localModelUUID(from identifier: String) -> UUID? {
        guard identifier.hasPrefix("local.") else { return nil }
        return UUID(uuidString: String(identifier.dropFirst("local.".count)))
    }

    static func chatGPTModelID(_ modelID: String) -> String {
        chatGPTModelPrefix + modelID
    }

    static func chatGPTModelID(from identifier: String) -> String? {
        guard identifier.hasPrefix(chatGPTModelPrefix) else { return nil }
        let modelID = String(identifier.dropFirst(chatGPTModelPrefix.count))
        return modelID.isEmpty ? nil : modelID
    }

    static func isChatGPT(_ identifier: String) -> Bool {
        identifier == chatGPTDefault || chatGPTModelID(from: identifier) != nil
    }
}

@Model
final class LocalModel: Identifiable {
    @Attribute(.unique) var id: UUID
    var name: String
    var endpoint: String
    var modelID: String
    var createdAt: Date
    var contextTokenLimit: Int?

    init(
        id: UUID = UUID(),
        name: String,
        endpoint: String,
        modelID: String,
        createdAt: Date = .now,
        contextTokenLimit: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.modelID = modelID
        self.createdAt = createdAt
        self.contextTokenLimit = contextTokenLimit
    }

    var resolvedContextTokenLimit: Int {
        let value = contextTokenLimit ?? ConversationCompaction.localModelDefaultContextTokens
        return min(max(value, ConversationCompaction.minimumContextTokens), ConversationCompaction.maximumContextTokens)
    }

    var displayName: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? "Untitled local model" : trimmedName
    }
}

struct LocalModelConfiguration: Sendable {
    let id: UUID
    let name: String
    let endpoint: String
    let modelID: String
    let bearerToken: String?
    let contextTokenLimit: Int

    var endpointValidationError: String? {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            return "Enter a valid server URL."
        }

        return nil
    }

    var validationError: String? {
        if let endpointValidationError {
            return endpointValidationError
        }

        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Choose a model from the server."
        }

        return nil
    }

    func chatCompletionsURL() throws -> URL {
        guard validationError == nil,
              var url = endpointURL() else {
            throw OpenAICompatibleError.invalidEndpoint
        }

        let normalizedPath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalizedPath != "chat/completions" && !normalizedPath.hasSuffix("/chat/completions") {
            url.appendPathComponent("chat")
            url.appendPathComponent("completions")
        }

        return url
    }

    func modelsURL() throws -> URL {
        guard endpointValidationError == nil,
              var url = endpointURL() else {
            throw OpenAICompatibleError.invalidEndpoint
        }

        var normalizedPath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalizedPath == "models" || normalizedPath.hasSuffix("/models") {
            return url
        }

        if normalizedPath == "chat/completions" || normalizedPath.hasSuffix("/chat/completions") {
            url.deleteLastPathComponent()
            url.deleteLastPathComponent()
            normalizedPath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }

        if normalizedPath != "models" && !normalizedPath.hasSuffix("/models") {
            url.appendPathComponent("models")
        }

        return url
    }

    private func endpointURL() -> URL? {
        URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

enum ChatBackend {
    case appleFoundation
    case chatGPT(ChatGPTProviderConfiguration)
    case openAICompatible(LocalModelConfiguration)
    case missingChatGPTProvider
    case missingLocalModel

    var displayName: String {
        switch self {
        case .appleFoundation:
            return "Apple Foundation Model"
        case .chatGPT(let configuration):
            return configuration.displayName
        case .openAICompatible(let configuration):
            return configuration.name
        case .missingChatGPTProvider:
            return "ChatGPT"
        case .missingLocalModel:
            return "Missing local model"
        }
    }

    var persistenceName: String {
        switch self {
        case .appleFoundation:
            return "appleFoundation"
        case .chatGPT:
            return "chatGPTSubscription"
        case .openAICompatible:
            return "openAICompatible"
        case .missingChatGPTProvider:
            return "missingChatGPTProvider"
        case .missingLocalModel:
            return "missingLocalModel"
        }
    }
}

enum ChatGPTConnectionState {
    case idle
    case checking
    case signedOut
    case connecting
    case connected(ChatGPTAccountSnapshot)
    case unavailable(String)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .checking, .connecting:
            return true
        default:
            return false
        }
    }

    var isAuthenticated: Bool? {
        switch self {
        case .connected:
            return true
        case .signedOut, .connecting:
            return false
        case .unavailable, .failed:
            return false
        case .idle, .checking:
            return nil
        }
    }
}

struct ChatModelSelection: Identifiable, Equatable {
    let identifier: String
    let displayName: String

    var id: String { identifier }
}

@MainActor
final class LocalModelStore: ObservableObject {
    @Published private(set) var localModels: [LocalModel] = []
    @Published private(set) var chatGPTModels: [ChatGPTModelDescriptor]
    @Published private(set) var chatGPTConnectionState: ChatGPTConnectionState = .idle
    @Published private(set) var configuredCodexExecutablePath: String
    @Published private(set) var resolvedCodexExecutableURL: URL?

    private let modelContext: ModelContext
    private static let codexExecutablePathDefaultsKey = "chatgptProvider.codexExecutablePath"
    private var chatGPTOperationID = UUID()

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        configuredCodexExecutablePath = UserDefaults.standard.string(
            forKey: Self.codexExecutablePathDefaultsKey
        ) ?? ""
        chatGPTModels = ChatGPTModelCatalogCache.load()
        resolvedCodexExecutableURL = CodexExecutableResolver.resolve(
            configuredPath: configuredCodexExecutablePath
        )
        loadModels()
    }

    func addLocalModel() {
        let model = LocalModel(
            name: "Local model",
            endpoint: "http://127.0.0.1:1234/v1",
            modelID: ""
        )
        modelContext.insert(model)
        saveChanges()
        loadModels()
    }

    func remove(_ model: LocalModel) {
        LocalModelCredentials.deleteToken(for: model.id)
        let identifier = ChatModelIdentifier.localModelID(model.id)
        let descriptor = FetchDescriptor<ReplyFilterSet>(
            predicate: #Predicate { $0.modelIdentifier == identifier }
        )
        if let filters = try? modelContext.fetch(descriptor) {
            for set in filters {
                modelContext.delete(set)
            }
        }
        modelContext.delete(model)
        saveChanges()
        loadModels()
    }

    func updateName(for model: LocalModel, to name: String) {
        model.name = name
        saveChanges()
        objectWillChange.send()
    }

    func updateEndpoint(for model: LocalModel, to endpoint: String) {
        model.endpoint = endpoint
        saveChanges()
        objectWillChange.send()
    }

    func updateModelID(for model: LocalModel, to modelID: String) {
        let previousModelID = model.modelID
        model.modelID = modelID
        if model.name == "Local model" || model.name == previousModelID {
            model.name = modelID
        }
        saveChanges()
        objectWillChange.send()
    }

    func updateContextTokenLimit(for model: LocalModel, to limit: Int?) {
        if let limit {
            model.contextTokenLimit = min(
                max(limit, ConversationCompaction.minimumContextTokens),
                ConversationCompaction.maximumContextTokens
            )
        } else {
            model.contextTokenLimit = nil
        }
        saveChanges()
        objectWillChange.send()
    }

    func bearerToken(for model: LocalModel) -> String {
        LocalModelCredentials.token(for: model.id) ?? ""
    }

    func updateBearerToken(for model: LocalModel, to token: String) {
        LocalModelCredentials.save(token, for: model.id)
    }

    var selectableModels: [ChatModelSelection] {
        var selections = [
            ChatModelSelection(
                identifier: ChatModelIdentifier.appleFoundation,
                displayName: "Apple Foundation Model"
            ),
            ChatModelSelection(
                identifier: ChatModelIdentifier.chatGPTDefault,
                displayName: "ChatGPT (recommended model)"
            )
        ]
        selections.append(contentsOf: chatGPTModels.map { model in
            ChatModelSelection(
                identifier: ChatModelIdentifier.chatGPTModelID(model.id),
                displayName: "ChatGPT · \(model.displayName)"
            )
        })
        selections.append(contentsOf: localModels.map { model in
            ChatModelSelection(
                identifier: ChatModelIdentifier.localModelID(model.id),
                displayName: model.displayName
            )
        })
        return selections
    }

    func isConfiguredModelIdentifier(_ identifier: String) -> Bool {
        if identifier == ChatModelIdentifier.appleFoundation || ChatModelIdentifier.isChatGPT(identifier) {
            return true
        }
        return localModels.contains {
            ChatModelIdentifier.localModelID($0.id) == identifier
        }
    }

    func updateCodexExecutablePath(_ path: String) {
        chatGPTOperationID = UUID()
        configuredCodexExecutablePath = path
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPath.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.codexExecutablePathDefaultsKey)
        } else {
            UserDefaults.standard.set(trimmedPath, forKey: Self.codexExecutablePathDefaultsKey)
        }
        resolvedCodexExecutableURL = CodexExecutableResolver.resolve(configuredPath: trimmedPath)
        chatGPTModels = []
        ChatGPTModelCatalogCache.save([])
        chatGPTConnectionState = .idle
    }

    func refreshChatGPT() async {
        guard !chatGPTConnectionState.isBusy else { return }
        let operationID = UUID()
        chatGPTOperationID = operationID
        chatGPTConnectionState = .checking

        guard let executableURL = CodexExecutableResolver.resolve(
            configuredPath: configuredCodexExecutablePath
        ) else {
            guard chatGPTOperationID == operationID else { return }
            resolvedCodexExecutableURL = nil
            chatGPTModels = []
            ChatGPTModelCatalogCache.save([])
            chatGPTConnectionState = .unavailable(ChatGPTProviderError.executableNotFound.localizedDescription)
            return
        }
        resolvedCodexExecutableURL = executableURL

        do {
            let inspection = try await ChatGPTProviderClient.inspect(executableURL: executableURL)
            guard chatGPTOperationID == operationID else { return }
            applyChatGPTInspection(inspection)
        } catch {
            guard chatGPTOperationID == operationID else { return }
            chatGPTConnectionState = .failed(error.localizedDescription)
        }
    }

    func connectChatGPT() async {
        guard !chatGPTConnectionState.isBusy else { return }
        let operationID = UUID()
        chatGPTOperationID = operationID

        guard let executableURL = CodexExecutableResolver.resolve(
            configuredPath: configuredCodexExecutablePath
        ) else {
            guard chatGPTOperationID == operationID else { return }
            resolvedCodexExecutableURL = nil
            chatGPTModels = []
            ChatGPTModelCatalogCache.save([])
            chatGPTConnectionState = .unavailable(ChatGPTProviderError.executableNotFound.localizedDescription)
            return
        }
        resolvedCodexExecutableURL = executableURL
        chatGPTConnectionState = .connecting

        do {
            let inspection = try await ChatGPTProviderClient.login(
                executableURL: executableURL
            ) { authorizationURL in
#if os(macOS)
                await MainActor.run {
                    NSWorkspace.shared.open(authorizationURL)
                }
#else
                false
#endif
            }
            guard chatGPTOperationID == operationID else { return }
            applyChatGPTInspection(inspection)
        } catch {
            guard chatGPTOperationID == operationID else { return }
            chatGPTConnectionState = .failed(error.localizedDescription)
        }
    }

    private func applyChatGPTInspection(_ inspection: ChatGPTProviderInspection) {
        chatGPTModels = inspection.models
        ChatGPTModelCatalogCache.save(inspection.models)

        if let account = inspection.account {
            chatGPTConnectionState = .connected(account)
        } else {
            chatGPTConnectionState = .signedOut
        }
    }

    func backend(for identifier: String?) -> ChatBackend {
        let selectedIdentifier = identifier ?? ChatModelIdentifier.appleFoundation
        guard selectedIdentifier != ChatModelIdentifier.appleFoundation else {
            return .appleFoundation
        }

        if ChatModelIdentifier.isChatGPT(selectedIdentifier) {
            guard let executableURL = resolvedCodexExecutableURL
                ?? CodexExecutableResolver.resolve(configuredPath: configuredCodexExecutablePath) else {
                return .missingChatGPTProvider
            }
            let modelID = ChatModelIdentifier.chatGPTModelID(from: selectedIdentifier)
            let descriptor = modelID.flatMap { selectedModelID in
                chatGPTModels.first { $0.id == selectedModelID }
            }
            let displayName = modelID.map {
                "ChatGPT · \(descriptor?.displayName ?? $0)"
            } ?? "ChatGPT (recommended model)"
            return .chatGPT(
                ChatGPTProviderConfiguration(
                    executableURL: executableURL,
                    modelID: modelID,
                    displayName: displayName,
                    contextTokenLimit: ConversationCompaction.chatGPTDefaultContextTokens,
                    isAuthenticated: chatGPTConnectionState.isAuthenticated
                )
            )
        }

        guard let modelID = ChatModelIdentifier.localModelUUID(from: selectedIdentifier),
              let model = localModels.first(where: { $0.id == modelID }) else {
            return .missingLocalModel
        }

        return .openAICompatible(configuration(for: model))
    }

    func configuration(for model: LocalModel) -> LocalModelConfiguration {
        LocalModelConfiguration(
            id: model.id,
            name: model.displayName,
            endpoint: model.endpoint,
            modelID: model.modelID,
            bearerToken: bearerToken(for: model).nilIfEmpty,
            contextTokenLimit: model.resolvedContextTokenLimit
        )
    }

    func displayName(for identifier: String?) -> String {
        backend(for: identifier).displayName
    }

    private func loadModels() {
        let descriptor = FetchDescriptor<LocalModel>(
            sortBy: [SortDescriptor(\.createdAt)]
        )

        do {
            localModels = try modelContext.fetch(descriptor)
        } catch {
            localModels = []
        }
    }

    private func saveChanges() {
        guard modelContext.hasChanges else { return }

        do {
            try modelContext.save()
        } catch {
            assertionFailure("Failed to save local models: \(error.localizedDescription)")
        }
    }
}

private enum LocalModelCredentials {
    private static let service = "com.lemoncanyon.chat.local-models"

    static func token(for id: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String, for id: UUID) {
        let account = id.uuidString
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedToken.isEmpty else {
            deleteToken(for: id)
            return
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let data = Data(trimmedToken.utf8)
        let attributes = [kSecValueData as String: data]

        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = data
            SecItemAdd(newItem as CFDictionary, nil)
        }
    }

    static func deleteToken(for id: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private enum ChatGPTModelCatalogCache {
    private static let defaultsKey = "chatgptProvider.modelCatalog"

    static func load() -> [ChatGPTModelDescriptor] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let models = try? JSONDecoder().decode([ChatGPTModelDescriptor].self, from: data) else {
            return []
        }
        return models
    }

    static func save(_ models: [ChatGPTModelDescriptor]) {
        guard let data = try? JSONEncoder().encode(models) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
