import Foundation
import FoundationModels

enum ModelClient {
    static func complete(
        using backend: ChatBackend,
        systemPrompt: String,
        prompt: String,
        tools: AgentToolBox? = nil,
        missingLocalModelMessage: String
    ) async throws -> String {
        switch backend {
        case .appleFoundation:
            let session = LanguageModelSession(
                tools: tools?.appleTools ?? [],
                instructions: systemPrompt
            )
            return try await session.respond(to: prompt).content
        case .openAICompatible(let configuration):
            return try await OpenAICompatibleClient(configuration: configuration).respond(
                systemPrompt: systemPrompt,
                prompt: prompt,
                tools: tools
            )
        case .missingLocalModel:
            throw OpenAICompatibleError.server(statusCode: 0, message: missingLocalModelMessage)
        }
    }

    static func complete(
        using backend: ChatBackend,
        systemPrompt: String,
        messages: [ChatMessage],
        appleFoundationPrompt: String,
        tools: AgentToolBox? = nil,
        missingLocalModelMessage: String
    ) async throws -> String {
        switch backend {
        case .appleFoundation:
            return try await complete(
                using: backend,
                systemPrompt: systemPrompt,
                prompt: appleFoundationPrompt,
                tools: tools,
                missingLocalModelMessage: missingLocalModelMessage
            )
        case .openAICompatible(let configuration):
            return try await OpenAICompatibleClient(configuration: configuration).respond(
                systemPrompt: systemPrompt,
                messages: messages,
                tools: tools
            )
        case .missingLocalModel:
            throw OpenAICompatibleError.server(statusCode: 0, message: missingLocalModelMessage)
        }
    }

    @MainActor
    static func availability(for backend: ChatBackend) -> (canSend: Bool, message: String) {
        switch backend {
        case .openAICompatible(let configuration):
            if let validationError = configuration.validationError {
                return (false, "\(configuration.name): \(validationError)")
            }
            return (true, "\(configuration.name) is ready.")
        case .missingLocalModel:
            return (false, "This chat's local model is no longer configured.")
        case .appleFoundation:
            break
        }

        switch SystemLanguageModel.default.availability {
        case .available:
            return (true, "On-device Foundation model is ready.")
        case .unavailable(.deviceNotEligible):
            return (false, "This device is not eligible for Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return (false, "Turn on Apple Intelligence in Settings to chat.")
        case .unavailable(.modelNotReady):
            return (false, "The on-device model is not ready yet.")
        case .unavailable:
            return (false, "The on-device model is unavailable right now.")
        }
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

    func respond(
        systemPrompt: String,
        messages: [ChatMessage],
        tools: AgentToolBox? = nil
    ) async throws -> String {
        try await respond(
            systemPrompt: systemPrompt,
            apiMessages: messages.map {
                OpenAIChatMessage(role: $0.role.rawValue, content: $0.text)
            },
            tools: tools
        )
    }

    func respond(
        systemPrompt: String,
        prompt: String,
        tools: AgentToolBox? = nil
    ) async throws -> String {
        try await respond(
            systemPrompt: systemPrompt,
            apiMessages: [OpenAIChatMessage(role: "user", content: prompt)],
            tools: tools
        )
    }

    private func respond(
        systemPrompt: String,
        apiMessages: [OpenAIChatMessage],
        tools: AgentToolBox?
    ) async throws -> String {
        var messages = [OpenAIChatMessage(role: "system", content: systemPrompt)] + apiMessages
        let openAITools = tools?.isEmpty == false ? tools?.openAITools : nil
        var remainingRounds = 8

        while remainingRounds > 0 {
            remainingRounds -= 1
            let completion = try await completeOnce(messages: messages, tools: openAITools)
            let message = completion.choices.first?.message
            let toolCalls = message?.toolCalls ?? []

            if !toolCalls.isEmpty, let tools {
                messages.append(
                    OpenAIChatMessage(
                        role: "assistant",
                        content: message?.content,
                        toolCalls: toolCalls
                    )
                )
                for call in toolCalls {
                    let output: String
                    do {
                        output = try await tools.execute(
                            name: call.function.name,
                            argumentsJSON: call.function.arguments
                        )
                    } catch {
                        output = error.localizedDescription
                    }
                    messages.append(
                        OpenAIChatMessage(
                            role: "tool",
                            content: output,
                            toolCallID: call.id
                        )
                    )
                }
                continue
            }

            guard let content = message?.content?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !content.isEmpty else {
                throw OpenAICompatibleError.invalidResponse
            }
            return content
        }

        throw OpenAICompatibleError.server(
            statusCode: 0,
            message: "The model exceeded the maximum number of tool calls."
        )
    }

    private func completeOnce(
        messages: [OpenAIChatMessage],
        tools: [OpenAITool]?
    ) async throws -> OpenAIChatCompletionResponse {
        func performOnce(includingTools: Bool) async throws -> (Data, HTTPURLResponse) {
            var request = makeRequest(url: try configuration.chatCompletionsURL())
            request.httpMethod = "POST"
            request.timeoutInterval = 120
            let requestBody = OpenAIChatCompletionRequest(
                model: configuration.modelID.trimmingCharacters(in: .whitespacesAndNewlines),
                messages: messages,
                tools: includingTools ? tools : nil
            )
            request.httpBody = try JSONEncoder().encode(requestBody)
            return try await performHTTP(request)
        }

        var (data, httpResponse) = try await performOnce(includingTools: tools != nil)
        if tools != nil, !(200...299).contains(httpResponse.statusCode) {
            (data, httpResponse) = try await performOnce(includingTools: false)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data)
            let fallbackMessage = String(data: data, encoding: .utf8) ?? "The local model server returned an error."
            throw OpenAICompatibleError.server(
                statusCode: httpResponse.statusCode,
                message: errorPayload?.error.message ?? fallbackMessage
            )
        }

        return try JSONDecoder().decode(OpenAIChatCompletionResponse.self, from: data)
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
        let (data, httpResponse) = try await performHTTP(request)
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

    private func performHTTP(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAICompatibleError.invalidResponse
        }
        return (data, httpResponse)
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
    var tools: [OpenAITool]?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case tools
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(messages, forKey: .messages)
        try container.encodeIfPresent(tools, forKey: .tools)
    }
}

private struct OpenAIChatMessage: Codable {
    var role: String
    var content: String?
    var toolCalls: [OpenAIToolCall]?
    var toolCallID: String?

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encodeIfPresent(content, forKey: .content)
        try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
    }
}

private struct OpenAIToolCall: Codable {
    var id: String
    var type: String
    var function: OpenAIFunctionCall
}

private struct OpenAIFunctionCall: Codable {
    var name: String
    var arguments: String
}

private struct OpenAIChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
            let toolCalls: [OpenAIToolCall]?

            enum CodingKeys: String, CodingKey {
                case content
                case toolCalls = "tool_calls"
            }
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
