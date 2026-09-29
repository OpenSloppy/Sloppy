import Foundation
import TOMLKit
import Yams

public enum MigrationScanner {
    public static func discover(home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) -> [MigrationSource] {
        MigrationSourceKind.allCases.compactMap { kind in
            let url = home.appendingPathComponent(kind.directoryName)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path), attributes[.type] as? FileAttributeType == .typeDirectory else { return nil }
            return .init(kind: kind, path: url.path, readable: FileManager.default.isReadableFile(atPath: url.path))
        }
    }
    public static func scan(sources: [MigrationSource]) throws -> MigrationCatalog {
        let normalized = sources.map { MigrationSource(kind: $0.kind, path: URL(fileURLWithPath: $0.path).standardizedFileURL.path, readable: $0.readable) }
        var result = MigrationCatalog(sources: normalized)
        for source in normalized {
            try Task.checkCancellation()
            let reader = SourceReader(source: source)
            switch source.kind {
            case .codex: try CodexMigrationAdapter.read(reader)
            case .claude: try ClaudeMigrationAdapter.read(reader)
            case .openclaw: try OpenClawMigrationAdapter.read(reader)
            case .hermes: try HermesMigrationAdapter.read(reader)
            }
            result.items += reader.items; result.warnings += reader.warnings
        }
        var seen = Set<String>()
        result.items = result.items.filter { seen.insert($0.id).inserted }
        return result
    }
}

final class SourceReader {
    let source: MigrationSource
    let root: URL
    var items: [MigrationItem] = []
    var warnings: [String] = []
    init(source: MigrationSource) { self.source = source; root = URL(fileURLWithPath: source.path, isDirectory: true) }
    func warn(_ url: URL, _ message: String) { warnings.append("\(source.kind.rawValue): \(url.lastPathComponent): \(message)") }
    func data(_ url: URL, limit: Int = 32 * 1024 * 1024) throws -> Data {
        try Task.checkCancellation()
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= limit else { throw MigrationError.invalid("File exceeds \(limit) bytes; choose a smaller export.") }
        return try Data(contentsOf: url)
    }
    func optionalJSON(_ url: URL) -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do { let decoder = JSONDecoder(); decoder.allowsJSON5 = true
            return try decoder.decode([String: MigrationConfigValue].self, from: data(url)).mapValues(\.foundationValue)
        } catch { warn(url, "Invalid or unreadable configuration."); return [:] }
    }
    func config(_ url: URL) -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do {
            let text = String(decoding: try data(url), as: UTF8.self)
            if url.pathExtension == "toml" {
                return try JSONSerialization.jsonObject(with: Data(TOMLTable(string: text).convert(to: .json).utf8)) as? [String: Any] ?? [:]
            }
            if ["yaml", "yml"].contains(url.pathExtension) { return try Yams.load(yaml: text) as? [String: Any] ?? [:] }
            return optionalJSON(url)
        } catch { warn(url, "Invalid or unreadable configuration."); return [:] }
    }
    func files(_ folder: URL, extensions: Set<String>? = nil) -> [URL] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        guard let iterator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles], errorHandler: { url, _ in self.warn(url, "Access unavailable."); return true }) else { return [] }
        var urls: [URL] = []
        for case let url as URL in iterator {
            if ["node_modules", ".git", "backups", "logs", "cache", "__pycache__"].contains(url.lastPathComponent) { iterator.skipDescendants(); continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { iterator.skipDescendants(); warn(url, "Linked files require selecting their source folder separately."); continue }
            if values?.isRegularFile == true, extensions == nil || extensions!.contains(url.pathExtension.lowercased()) { urls.append(url) }
        }
        return urls.sorted { $0.path < $1.path }
    }
    func markdown(_ url: URL, category: MigrationCategory, profile: String = "default", project: String? = nil) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let content = try data(url, limit: 1024 * 1024)
            guard String(data: content, encoding: .utf8) != nil else { throw MigrationError.invalid("Expected UTF-8 Markdown.") }
            items.append(.init(source: source, externalID: url.path, profile: profile, category: category, title: url.lastPathComponent,
                               projectPath: project, files: [.init(path: url.lastPathComponent, content: content)],
                               warnings: category == .instructions && content.count > 20_000 ? ["Long instructions are preserved in full; runtime context uses bounded excerpts."] : []))
        } catch { warn(url, error.localizedDescription) }
    }
    func documents(_ folder: URL, profile: String = "default", project: String? = nil) {
        for name in ["AGENTS.md", "CLAUDE.md", "USER.md", "SOUL.md", "IDENTITY.md"] {
            markdown(folder.appendingPathComponent(name), category: .instructions, profile: profile, project: project)
        }
        markdown(folder.appendingPathComponent("MEMORY.md"), category: .memory, profile: profile, project: project)
        for dir in ["memories", "memory"] {
            for url in files(folder.appendingPathComponent(dir), extensions: ["md", "markdown"]) { markdown(url, category: .memory, profile: profile, project: project) }
        }
        for url in files(folder.appendingPathComponent("rules"), extensions: ["md"]) {
            markdown(url, category: .instructions, profile: profile, project: project)
            if let last = items.indices.last { items[last].warnings.append("Path-scoped rules are preserved as documents; review their scope before use.") }
        }
    }
    func skills(_ folder: URL, profile: String = "default", project: String? = nil) {
        for entrypoint in files(folder, extensions: ["md"]).filter({ $0.lastPathComponent == "SKILL.md" }) {
            let directory = entrypoint.deletingLastPathComponent()
            do {
                let bundle = try files(directory).map { file -> MigrationFile in
                    let path = String(file.path.dropFirst(directory.path.count + 1))
                    return .init(path: path, content: try data(file, limit: 10 * 1024 * 1024), executable: FileManager.default.isExecutableFile(atPath: file.path))
                }
                let text = String(decoding: try data(entrypoint), as: UTF8.self)
                let metadata = text.components(separatedBy: "---").dropFirst().first.flatMap { try? Yams.load(yaml: $0) as? [String: Any] } ?? [:]
                let unsupported = ["hooks", "context", "agent", "allowed-tools", "disallowed-tools", "disable-model-invocation", "user-invocable"].filter { metadata[$0] != nil }
                items.append(.init(source: source, externalID: directory.path, profile: profile, category: .skill, title: metadata["name"] as? String ?? directory.lastPathComponent,
                                   description: metadata["description"] as? String, projectPath: project, files: bundle, warnings: unsupported.isEmpty ? [] : ["Review unsupported skill fields: " + unsupported.joined(separator: ", ")]))
            } catch { warn(entrypoint, error.localizedDescription) }
        }
    }
    func commands(_ folder: URL, profile: String = "default", project: String? = nil) {
        for url in files(folder, extensions: ["md"]) {
            do {
                let content = String(decoding: try data(url, limit: 1024 * 1024), as: UTF8.self)
                let name = url.deletingPathExtension().lastPathComponent
                let skill = "---\nname: \(name)\ndescription: Imported command; invoke explicitly\ncontext: task\n---\n\n" + content
                items.append(.init(source: source, externalID: url.path, profile: profile, category: .skill, title: name, projectPath: project,
                                   files: [.init(path: "SKILL.md", content: Data(skill.utf8))], warnings: ["Imported command: invoke explicitly; review source-specific arguments and macros."]))
            } catch { warn(url, error.localizedDescription) }
        }
    }
    func mcp(_ raw: [String: Any], profile: String = "default", project: String? = nil, origin: String = "config") {
        for (name, value) in raw.sorted(by: { $0.key < $1.key }) {
            guard let config = value as? [String: Any] else { continue }
            let endpoint = config["url"] as? String ?? config["endpoint"] as? String
            let command = config["command"] as? String
            guard endpoint != nil || command != nil else { warnings.append("\(name): unsupported MCP transport."); continue }
            let unsupported = ["bearer_token_env_var", "env_http_headers", "env_vars", "oauth", "auth", "http_headers_helper", "enabled_tools", "disabled_tools", "toolFilter", "tls"].filter { config[$0] != nil }
            let environment = config["env"] as? [String: Any] ?? [:]
            let headers = config["headers"] as? [String: Any] ?? config["http_headers"] as? [String: Any] ?? [:]
            let secretKeys = environment.filter { !($0.value is String) }.map(\.key) + headers.filter { !($0.value is String) }.map(\.key)
            var diagnostics = unsupported.isEmpty ? [] : ["Configure destination MCP fields manually: " + unsupported.joined(separator: ", ")]
            if !secretKeys.isEmpty { diagnostics.append("Resolve destination MCP secret references: " + secretKeys.sorted().joined(separator: ", ")) }
            if config["transport"] as? String == "sse" || config["type"] as? String == "sse" { diagnostics.append("Legacy SSE needs a compatible destination endpoint before enabling.") }
            let mcp = MigrationMCP(command: command, arguments: config["args"] as? [String] ?? [], cwd: config["cwd"] as? String,
                                   endpoint: endpoint, environment: environment.compactMapValues { $0 as? String },
                                   headers: headers.compactMapValues { $0 as? String })
            items.append(.init(source: source, externalID: origin + ":" + name, profile: profile, category: .mcp, title: name, projectPath: project, mcp: mcp,
                               warnings: diagnostics))
        }
    }
    func project(_ path: String, profile: String = "default") {
        guard !path.isEmpty, !items.contains(where: { $0.category == .project && $0.projectPath == path && $0.profile == profile }) else { return }
        items.append(.init(source: source, externalID: path, profile: profile, category: .project, title: URL(fileURLWithPath: path).lastPathComponent, projectPath: path))
        if source.kind == .codex || source.kind == .hermes {
            let folder = URL(fileURLWithPath: path)
            for name in ["AGENTS.md", "CLAUDE.md", "USER.md", "SOUL.md", "IDENTITY.md"] {
                markdown(folder.appendingPathComponent(name), category: .instructions, profile: profile, project: path)
            }
        }
    }
    func lines(_ url: URL) -> [[String: Any]] {
        do {
            let text = String(decoding: try data(url), as: UTF8.self)
            var result: [[String: Any]] = []
            for (index, line) in text.split(separator: "\n").enumerated() {
                if let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] { result.append(row) }
                else { warn(url, "Unreadable JSONL record \(index + 1) skipped.") }
            }
            return result
        } catch { warn(url, error.localizedDescription); return [] }
    }
    static func date(_ value: Any?) -> Date {
        if let number = value as? Double { return Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1000 : number) }
        if let text = value as? String {
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: text) { return date }
        }
        return Date(timeIntervalSince1970: 0)
    }
    static func json(_ value: Any) -> String { (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])).map { String(decoding: $0, as: UTF8.self) } ?? "" }
    static func content(_ value: Any?) -> String {
        if let text = value as? String { return text }
        guard let blocks = value as? [[String: Any]] else { return "" }
        return blocks.compactMap { block in
            guard ["text", "input_text", "output_text"].contains(block["type"] as? String ?? "") else { return nil }
            return block["text"] as? String
        }.joined(separator: "\n")
    }
    static func messages(_ raw: [String: Any], fallbackID: String, timestamp: Any?) -> [MigrationMessage] {
        let id = raw["id"] as? String ?? fallbackID
        let date = Self.date(raw["timestamp"] ?? timestamp)
        let role = raw["role"] as? String ?? ""
        var result: [MigrationMessage] = []
        if role == "user" || role == "assistant" {
            let text = content(raw["content"])
            if !text.isEmpty { result.append(.init(id: id, kind: role == "user" ? .user : .assistant, text: text, createdAt: date)) }
        }
        if role == "tool" || role == "toolResult" { result.append(.init(id: id, kind: .toolResult, text: content(raw["content"]), tool: raw["name"] as? String ?? raw["tool_name"] as? String, callID: raw["tool_call_id"] as? String ?? raw["toolCallId"] as? String, createdAt: date)) }
        for (index, call) in (raw["tool_calls"] as? [[String: Any]] ?? []).enumerated() {
            let function = call["function"] as? [String: Any] ?? call
            result.append(.init(id: id + ":call:\(index)", kind: .toolCall, text: function["arguments"] as? String ?? json(function["arguments"] ?? [:]), tool: function["name"] as? String, callID: call["id"] as? String, createdAt: date))
        }
        for (index, block) in (raw["content"] as? [[String: Any]] ?? []).enumerated() {
            if ["tool_use", "toolCall"].contains(block["type"] as? String ?? "") {
                result.append(.init(id: id + ":call:\(index)", kind: .toolCall, text: json(block["input"] ?? block["arguments"] ?? [:]), tool: block["name"] as? String, callID: block["id"] as? String, createdAt: date))
            } else if block["type"] as? String == "tool_result" {
                result.append(.init(id: id + ":result:\(index)", kind: .toolResult, text: content(block["content"]), callID: block["tool_use_id"] as? String, createdAt: date))
            }
        }
        return result
    }
}

private enum MigrationConfigValue: Decodable {
    case string(String), number(Double), bool(Bool), null, array([Self]), object([String: Self])
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode([Self].self) { self = .array(value) }
        else { self = .object(try container.decode([String: Self].self)) }
    }
    var foundationValue: Any {
        switch self {
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .null: return NSNull()
        case .array(let value): return value.map(\.foundationValue)
        case .object(let value): return value.mapValues(\.foundationValue)
        }
    }
}
