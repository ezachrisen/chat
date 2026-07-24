import Combine
import Foundation
import Security
import SwiftData

enum ChatModelIdentifier {
    static let appleFoundation = "apple.foundation"

    static func localModelID(_ id: UUID) -> String {
        "local.\(id.uuidString.lowercased())"
    }

    static func localModelUUID(from identifier: String) -> UUID? {
        guard identifier.hasPrefix("local.") else { return nil }
        return UUID(uuidString: String(identifier.dropFirst("local.".count)))
    }
}

@Model
final class LocalModel: Identifiable {
    @Attribute(.unique) var id: UUID
    var name: String
    var endpoint: String
    var modelID: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        endpoint: String,
        modelID: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.modelID = modelID
        self.createdAt = createdAt
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
    case openAICompatible(LocalModelConfiguration)
    case missingLocalModel

    var displayName: String {
        switch self {
        case .appleFoundation:
            return "Apple Foundation Model"
        case .openAICompatible(let configuration):
            return configuration.name
        case .missingLocalModel:
            return "Missing local model"
        }
    }
}

@MainActor
final class LocalModelStore: ObservableObject {
    @Published private(set) var localModels: [LocalModel] = []

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
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

    func bearerToken(for model: LocalModel) -> String {
        LocalModelCredentials.token(for: model.id) ?? ""
    }

    func updateBearerToken(for model: LocalModel, to token: String) {
        LocalModelCredentials.save(token, for: model.id)
    }

    func backend(for identifier: String?) -> ChatBackend {
        let selectedIdentifier = identifier ?? ChatModelIdentifier.appleFoundation
        guard selectedIdentifier != ChatModelIdentifier.appleFoundation else {
            return .appleFoundation
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
            bearerToken: bearerToken(for: model).nilIfEmpty
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

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

enum OpenAICompatibleError: LocalizedError {
    case invalidEndpoint
    case invalidResponse
    case noModels
    case server(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "The local model server URL is invalid."
        case .invalidResponse:
            return "The local model returned an unexpected response."
        case .noModels:
            return "The server did not report any models."
        case .server(_, let message):
            return message
        }
    }
}

struct OpenAICompatibleClient: Sendable {
    private let configuration: LocalModelConfiguration

    init(configuration: LocalModelConfiguration) {
        self.configuration = configuration
    }

    func listModels() async throws -> [String] {
        var request = makeRequest(url: try configuration.modelsURL())
        request.httpMethod = "GET"
        request.timeoutInterval = 10

        let data = try await perform(request)
        let response = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
        let modelIDs = Set(
            response.data
                .map(\.id)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )

        guard !modelIDs.isEmpty else {
            throw OpenAICompatibleError.noModels
        }

        return modelIDs.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func respond(systemPrompt: String, messages: [ChatMessage]) async throws -> String {
        try await respond(
            systemPrompt: systemPrompt,
            apiMessages: messages.map {
                OpenAIChatMessage(role: $0.role.rawValue, content: $0.text)
            }
        )
    }

    func respond(systemPrompt: String, prompt: String) async throws -> String {
        try await respond(
            systemPrompt: systemPrompt,
            apiMessages: [OpenAIChatMessage(role: "user", content: prompt)]
        )
    }

    private func respond(systemPrompt: String, apiMessages: [OpenAIChatMessage]) async throws -> String {
        var request = makeRequest(url: try configuration.chatCompletionsURL())
        request.httpMethod = "POST"

        let requestBody = OpenAIChatCompletionRequest(
            model: configuration.modelID.trimmingCharacters(in: .whitespacesAndNewlines),
            messages: [OpenAIChatMessage(role: "system", content: systemPrompt)] + apiMessages
        )
        request.httpBody = try JSONEncoder().encode(requestBody)

        let data = try await perform(request)
        let completion = try JSONDecoder().decode(OpenAIChatCompletionResponse.self, from: data)
        guard let content = completion.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw OpenAICompatibleError.invalidResponse
        }

        return content
    }

    private func makeRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let bearerToken = configuration.bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }

        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAICompatibleError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data)
            let fallbackMessage = String(data: data, encoding: .utf8) ?? "The local model server returned an error."
            throw OpenAICompatibleError.server(
                statusCode: httpResponse.statusCode,
                message: errorPayload?.error.message ?? fallbackMessage
            )
        }

        return data
    }
}

private struct OpenAIModelsResponse: Decodable {
    struct Model: Decodable {
        let id: String
    }

    let data: [Model]
}

private struct OpenAIChatCompletionRequest: Encodable {
    let model: String
    let messages: [OpenAIChatMessage]
}

private struct OpenAIChatMessage: Codable {
    let role: String
    let content: String
}

private struct OpenAIChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }

        let message: Message
    }

    let choices: [Choice]
}

private struct OpenAIErrorResponse: Decodable {
    struct APIError: Decodable {
        let message: String
    }

    let error: APIError
}
