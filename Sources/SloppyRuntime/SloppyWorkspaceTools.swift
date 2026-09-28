import AnyLanguageModel
import Foundation
import PluginSDK
import Protocols

/// Project-scoped tools for an embedded runtime. No process or host filesystem tools are exposed.
public actor SloppyWorkspaceToolExecutor {
    private static let maximumReadBytes = 128 * 1024
    private static let maximumWriteBytes = 256 * 1024
    private static let writableRoots: Set<String> = ["Sources", "Scenes", "Assets"]
    private static let writableExtensions: Set<String> = ["ada", "ascn", "json", "md", "txt"]

    private let rootURL: URL
    private let fileManager: FileManager
    private let build: (@Sendable () async -> SloppyBuildResult)?

    public init(rootURL: URL, fileManager: FileManager = .default, build: (@Sendable () async -> SloppyBuildResult)? = nil) {
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.fileManager = fileManager
        self.build = build
    }

    static var modelTools: [any Tool] {
        [WorkspaceListTool(), WorkspaceReadTool(), WorkspaceWriteTool(), WorkspaceBuildTool()]
    }

    public func invoke(_ request: ToolInvocationRequest) async -> ToolInvocationResult {
        switch request.tool {
        case "files.list":
            return list(path: request.arguments["path"]?.asString ?? ".")
        case "files.read":
            return read(path: request.arguments["path"]?.asString ?? "")
        case "files.write":
            return write(
                path: request.arguments["path"]?.asString ?? "",
                content: request.arguments["content"]?.asString ?? ""
            )
        case "editor.build":
            guard let build else {
                return failure(request.tool, code: "unavailable", message: "Project build is unavailable.")
            }
            let result = await build()
            if result.ok {
                return ToolInvocationResult(tool: request.tool, ok: true, data: .object(["summary": .string(result.summary)]))
            }
            return failure(request.tool, code: "build_failed", message: result.summary)
        default:
            return failure(request.tool, code: "unknown_tool", message: "This tool is unavailable on mobile.")
        }
    }

    private func list(path: String) -> ToolInvocationResult {
        guard let directory = resolve(path == "." ? "" : path),
              let values = try? directory.resourceValues(forKeys: [.isDirectoryKey]),
              values.isDirectory == true else {
            return failure("files.list", code: "invalid_path", message: "Directory is outside the project or does not exist.")
        }
        do {
            let entries = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            let names = entries.prefix(200).map { entry -> JSONValue in
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                return .object(["name": .string(entry.lastPathComponent), "directory": .bool(isDirectory)])
            }
            return ToolInvocationResult(tool: "files.list", ok: true, data: .object(["entries": .array(names)]))
        } catch {
            return failure("files.list", code: "read_failed", message: error.localizedDescription)
        }
    }

    private func read(path: String) -> ToolInvocationResult {
        guard let file = resolve(path), fileManager.fileExists(atPath: file.path) else {
            return failure("files.read", code: "invalid_path", message: "File is outside the project or does not exist.")
        }
        do {
            let data = try Data(contentsOf: file)
            guard data.count <= Self.maximumReadBytes, let text = String(data: data, encoding: .utf8) else {
                return failure("files.read", code: "invalid_content", message: "File must be UTF-8 and at most 128 KB.")
            }
            return ToolInvocationResult(tool: "files.read", ok: true, data: .object(["path": .string(path), "content": .string(text)]))
        } catch {
            return failure("files.read", code: "read_failed", message: error.localizedDescription)
        }
    }

    private func write(path: String, content: String) -> ToolInvocationResult {
        let components = path.split(separator: "/").map(String.init)
        guard components.count >= 2,
              Self.writableRoots.contains(components[0]),
              Self.writableExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()),
              let file = resolve(path) else {
            return failure("files.write", code: "path_not_allowed", message: "Write a project text file under Sources, Scenes, or Assets.")
        }
        let data = Data(content.utf8)
        guard data.count <= Self.maximumWriteBytes else {
            return failure("files.write", code: "content_too_large", message: "File exceeds 256 KB.")
        }
        do {
            try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return ToolInvocationResult(tool: "files.write", ok: true, data: .object([
                "path": .string(path), "sizeBytes": .number(Double(data.count))
            ]))
        } catch {
            return failure("files.write", code: "write_failed", message: error.localizedDescription)
        }
    }

    private func resolve(_ path: String) -> URL? {
        guard !path.hasPrefix("/"), !path.hasPrefix("~") else { return nil }
        let components = path.split(separator: "/").map(String.init)
        let isReadOnlyManifest = path == ".ada/project.json"
        guard !components.contains(".."),
              !components.contains("."),
              (isReadOnlyManifest || !components.contains(where: { $0.hasPrefix(".") })) else {
            return nil
        }
        var file = rootURL
        for component in components {
            file.appendPathComponent(component)
            if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                return nil
            }
        }
        let resolved = file.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved == rootURL || resolved.path.hasPrefix(rootURL.path + "/") else { return nil }
        return resolved
    }

    private func failure(_ tool: String, code: String, message: String) -> ToolInvocationResult {
        ToolInvocationResult(
            tool: tool,
            ok: false,
            error: ToolErrorPayload(code: code, message: message, retryable: false)
        )
    }
}

private struct WorkspaceListTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String
    let name = "files.list"
    let description = "List files in the current game project. Use path '.' for its root."
    var parameters: GenerationSchema {
        workspaceObjectSchema([.init(name: "path", description: "Project-relative directory or '.'", schema: DynamicGenerationSchema(type: String.self))])
    }
    func call(arguments: GeneratedContent) async throws -> String { "" }
}

private struct WorkspaceReadTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String
    let name = "files.read"
    let description = "Read a UTF-8 file in the current game project."
    var parameters: GenerationSchema {
        workspaceObjectSchema([.init(name: "path", description: "Project-relative file path", schema: DynamicGenerationSchema(type: String.self))])
    }
    func call(arguments: GeneratedContent) async throws -> String { "" }
}

private struct WorkspaceWriteTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String
    let name = "files.write"
    let description = "Create or replace a UTF-8 .ada, .ascn, .json, .md, or .txt file under Sources, Scenes, or Assets."
    var parameters: GenerationSchema {
        workspaceObjectSchema([
            .init(name: "path", description: "Project-relative destination", schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "content", description: "Complete UTF-8 file content", schema: DynamicGenerationSchema(type: String.self)),
        ])
    }
    func call(arguments: GeneratedContent) async throws -> String { "" }
}

private struct WorkspaceBuildTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String
    let name = "editor.build"
    let description = "Build the current AdaScript game project in the editor and return errors or a success summary."
    var parameters: GenerationSchema { workspaceObjectSchema([]) }
    func call(arguments: GeneratedContent) async throws -> String { "" }
}

private func workspaceObjectSchema(_ properties: [DynamicGenerationSchema.Property]) -> GenerationSchema {
    let schema = DynamicGenerationSchema(name: "Arguments", properties: properties)
    guard let generated = try? GenerationSchema(root: schema, dependencies: []) else {
        return String.generationSchema
    }
    let normalized = ModelToolSchemaNormalizer.providerSafeObjectSchema(generated)
    guard let data = try? JSONSerialization.data(withJSONObject: normalized),
          let decoded = try? JSONDecoder().decode(GenerationSchema.self, from: data) else {
        return generated
    }
    return decoded
}
