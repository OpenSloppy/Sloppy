import AnyLanguageModel
import Foundation
import PluginSDK

/// A host capability advertised to the model and dispatched through the per-turn handler.
/// The host owns validation, project scoping, and execution. Built-in tools retain precedence.
public struct SloppyHostToolDefinition: Sendable {
    public let name: String
    public let description: String
    private let schema: GenerationSchema

    public init(name: String, description: String, inputSchemaJSON: String) throws {
        self.name = name
        self.description = description
        let decoded = try JSONDecoder().decode(GenerationSchema.self, from: Data(inputSchemaJSON.utf8))
        let normalized = ModelToolSchemaNormalizer.providerSafeObjectSchema(decoded)
        schema = try JSONDecoder().decode(GenerationSchema.self, from: JSONSerialization.data(withJSONObject: normalized))
    }

    var modelTool: any Tool { HostModelTool(name: name, description: description, parameters: schema) }
}

private struct HostModelTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String
    let name: String
    let description: String
    let parameters: GenerationSchema
    // RuntimeSystem invokes the project-scoped host handler, as for built-in workspace tools.
    func call(arguments: GeneratedContent) async throws -> String { "" }
}
