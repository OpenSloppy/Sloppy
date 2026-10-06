import AnyLanguageModel
import Foundation
import Protocols

struct FilesEditTool: CoreTool {
    let domain = "files"
    let title = "Edit file"
    let status = "fully_functional"
    let name = "files.edit"
    let description = "Replace a unique exact text fragment in a file. Read the file first and pass its contentHash as expectedContentHash to reject stale edits. Use all=true only to intentionally replace every match."

    var parameters: GenerationSchema {
        .objectSchema([
            .init(name: "path", description: "File path to edit", schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "search", description: "Exact text to search for", schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "replace", description: "Replacement text", schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "expectedContentHash", description: "SHA-256 contentHash from a complete files.read; reject if the file changed", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "all", description: "Replace all occurrences", schema: DynamicGenerationSchema(type: Bool.self), isOptional: true)
        ])
    }

    func invoke(arguments: [String: JSONValue], context: ToolContext) async -> ToolInvocationResult {
        let pathValue = arguments["path"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let search = arguments["search"]?.asString ?? ""
        let replace = arguments["replace"]?.asString ?? ""
        let replaceAll = arguments["all"]?.asBool ?? false

        guard !pathValue.isEmpty, !search.isEmpty else {
            return toolFailure(tool: name, code: "invalid_arguments", message: "`path` and `search` are required.", retryable: false)
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
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            let detail = FileSystemToolErrorMapping.describePathIsDirectory(operation: .read, path: fileURL.path)
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
                at: fileURL,
                operation: .edit(search: search, replacement: replace, all: replaceAll),
                expectedContentHash: arguments["expectedContentHash"]?.asString,
                maxBytes: context.policy.guardrails.maxWriteBytes
            )
            return await context.mutationResult(tool: name, outcome: outcome)
        } catch {
            return fileMutationFailure(tool: name, path: fileURL.path, error: error)
        }
    }
}
