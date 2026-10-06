import AnyLanguageModel
import Foundation
import Protocols

struct FilesWriteTool: CoreTool {
    let domain = "files"
    let title = "Write file"
    let status = "fully_functional"
    let name = "files.write"
    let description = "Create or overwrite UTF-8 file in workspace."

    var parameters: GenerationSchema {
        .objectSchema([
            .init(name: "path", description: "Destination file path", schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "content", description: "UTF-8 content to write", schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "expectedContentHash", description: "SHA-256 contentHash from a complete files.read; reject if the file changed", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "allowEmpty", description: "Allow writing empty content", schema: DynamicGenerationSchema(type: Bool.self), isOptional: true)
        ])
    }

    func invoke(arguments: [String: JSONValue], context: ToolContext) async -> ToolInvocationResult {
        let pathValue = arguments["path"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let content = arguments["content"]?.asString ?? ""
        guard !pathValue.isEmpty else {
            return toolFailure(tool: name, code: "invalid_arguments", message: "`path` is required.", retryable: false)
        }
        guard !content.isEmpty || arguments["allowEmpty"]?.asBool == true else {
            return toolFailure(tool: name, code: "invalid_arguments", message: "`content` is required.", retryable: false)
        }
        guard let fileURL = context.resolveWritablePath(pathValue) else {
            return toolFailure(tool: name, code: "path_not_allowed", message: "File path is outside allowed roots.", retryable: false)
        }
        if context.isAgentsUserOrMemoryMarkdownFile(fileURL) {
            return toolFailure(
                tool: name,
                code: "path_not_allowed",
                message: "USER.md and MEMORY.md must be updated with `agent.documents.set_user_markdown` or `agent.documents.set_memory_markdown`.",
                retryable: false
            )
        }
        let byteCount = content.lengthOfBytes(using: .utf8)
        if byteCount > context.policy.guardrails.maxWriteBytes {
            return toolFailure(tool: name, code: "content_too_large", message: "Content exceeds max writable bytes.", retryable: false)
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            let detail = FileSystemToolErrorMapping.describePathIsDirectory(operation: .write, path: fileURL.path)
            return toolFailure(
                tool: name,
                code: detail.code,
                message: detail.message,
                retryable: detail.retryable,
                hint: detail.hint
            )
        }
        if let expected = arguments["expectedContentHash"], expected != .null {
            guard let hash = expected.asString, hash.count == 64,
                  hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                return toolFailure(tool: name, code: "invalid_arguments", message: "expectedContentHash must be a lowercase SHA-256 digest from files.read.", retryable: false)
            }
        }
        do {
            let outcome = try await context.fileMutations.apply(
                at: fileURL, operation: .write(content),
                expectedContentHash: arguments["expectedContentHash"]?.asString,
                maxBytes: context.policy.guardrails.maxWriteBytes
            )
            return await context.mutationResult(tool: name, outcome: outcome)
        } catch {
            return fileMutationFailure(tool: name, path: fileURL.path, error: error)
        }
    }
}
