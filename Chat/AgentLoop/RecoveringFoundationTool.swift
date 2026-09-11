import Foundation
import FoundationModels

/// Preserve the exact advertised schema while turning safe, actionable errors into model-visible tool output.
struct RecoveringFoundationTool<Base: Tool>: Tool {
    let base: Base
    let loop: ToolExecutionLoop
    typealias Arguments = Base.Arguments
    var name: String { base.name }
    var description: String { base.description }
    var parameters: GenerationSchema { base.parameters }
    var includesSchemaInInstructions: Bool { base.includesSchemaInInstructions }

    func call(arguments: Arguments) async throws -> Prompt {
        let json = (arguments as? any ConvertibleToGeneratedContent)?.generatedContent.jsonString ?? String(reflecting: arguments)
        let key = try await loop.begin(toolName: name, argumentsJSON: json)
        do {
            let output = try await base.call(arguments: arguments)
            try Task.checkCancellation()
            await loop.succeeded(toolName: name, requestKey: key, output: output as? String)
            return Prompt(output)
        } catch {
            let feedback = try await loop.feedback(for: error, requestKey: key,
                                                   recoverable: ToolRecoveryPolicy.canRecover(error, toolName: name, argumentsJSON: json))
            return Prompt(feedback)
        }
    }
}

enum FoundationToolRecovery {
    static func wrap(_ tools: [any Tool], loop: ToolExecutionLoop) -> [any Tool] {
        func wrapOne<T: Tool>(_ tool: T) -> any Tool { RecoveringFoundationTool(base: tool, loop: loop) }
        return tools.map { wrapOne($0) }
    }
}
