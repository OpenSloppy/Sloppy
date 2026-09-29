import Foundation
import Crypto

public enum MigrationSourceKind: String, Codable, Sendable, CaseIterable {
    case codex, claude, openclaw, hermes
    public var directoryName: String { "." + rawValue }
}

public enum MigrationCategory: String, Codable, Sendable, CaseIterable {
    case skill, mcp, project, session, memory, instructions
}

public struct MigrationSource: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var kind: MigrationSourceKind
    public var path: String
    public var readable: Bool
    public init(kind: MigrationSourceKind, path: String, readable: Bool = true) {
        self.kind = kind; self.path = path; self.readable = readable
        id = MigrationDigest.id(kind.rawValue + ":" + path)
    }
}

public struct MigrationFile: Codable, Sendable, Equatable {
    public var path: String
    public var content: Data
    public var executable: Bool
    public init(path: String, content: Data, executable: Bool = false) {
        self.path = path; self.content = content; self.executable = executable
    }
}

public struct MigrationMessage: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case user, assistant, toolCall, toolResult }
    public var id: String
    public var kind: Kind
    public var text: String
    public var tool: String?
    public var callID: String?
    public var createdAt: Date
    public init(id: String, kind: Kind, text: String, tool: String? = nil, callID: String? = nil, createdAt: Date) {
        self.id = id; self.kind = kind; self.text = text; self.tool = tool; self.callID = callID; self.createdAt = createdAt
    }
}

public struct MigrationMCP: Codable, Sendable, Equatable {
    public var command: String?
    public var arguments: [String]
    public var cwd: String?
    public var endpoint: String?
    public var environment: [String: String]
    public var headers: [String: String]
    public init(command: String? = nil, arguments: [String] = [], cwd: String? = nil, endpoint: String? = nil,
                environment: [String: String] = [:], headers: [String: String] = [:]) {
        self.command = command; self.arguments = arguments; self.cwd = cwd; self.endpoint = endpoint
        self.environment = environment; self.headers = headers
    }
}

/// Normalized data, never executable commands to be run by the importer.
public struct MigrationItem: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var source: MigrationSource
    public var externalID: String
    public var profile: String
    public var category: MigrationCategory
    public var title: String
    public var description: String? = nil
    public var projectPath: String?
    public var parentExternalID: String?
    public var createdAt: Date?
    public var archived: Bool
    public var files: [MigrationFile]
    public var messages: [MigrationMessage]
    public var mcp: MigrationMCP?
    public var warnings: [String]
    public init(source: MigrationSource, externalID: String, profile: String = "default", category: MigrationCategory,
                title: String, description: String? = nil, projectPath: String? = nil, parentExternalID: String? = nil, createdAt: Date? = nil,
                archived: Bool = false, files: [MigrationFile] = [], messages: [MigrationMessage] = [],
                mcp: MigrationMCP? = nil, warnings: [String] = []) {
        self.source = source; self.externalID = externalID; self.profile = profile; self.category = category
        self.title = title; self.description = description; self.projectPath = projectPath; self.parentExternalID = parentExternalID
        self.createdAt = createdAt; self.archived = archived; self.files = files; self.messages = messages
        self.mcp = mcp; self.warnings = warnings
        id = MigrationDigest.id(source.id + ":" + profile + ":" + category.rawValue + ":" + externalID)
    }
    public var profileKey: String { source.id + ":" + profile }
    public var sizeBytes: Int { files.reduce(0) { $0 + $1.content.count } + messages.reduce(0) { $0 + $1.text.utf8.count } }
    public var checksum: String { MigrationDigest.sha256((try? MigrationDigest.encoder.encode(self)) ?? Data()) }
}

public struct MigrationCatalog: Codable, Sendable {
    public var sources: [MigrationSource]
    public var items: [MigrationItem]
    public var warnings: [String]
    public init(sources: [MigrationSource] = [], items: [MigrationItem] = [], warnings: [String] = []) {
        self.sources = sources; self.items = items; self.warnings = warnings
    }
}

public struct MigrationSelection: Codable, Sendable {
    public var warnings: [String]? = nil
    public var items: [MigrationItem]
    /// Profile key -> existing agent ID. Missing keys create separate native profiles.
    public var agentMappings: [String: String]
    /// Source project path -> destination folder. Empty means import context without binding a folder.
    public var projectMappings: [String: String]
    public init(items: [MigrationItem], agentMappings: [String: String] = [:], projectMappings: [String: String] = [:], warnings: [String] = []) {
        self.warnings = warnings
        self.items = items; self.agentMappings = agentMappings; self.projectMappings = projectMappings
    }
}

public struct MigrationPreview: Codable, Sendable {
    public var totalBytes: Int
    public var counts: [String: Int]
    public var duplicates: [String]
    public var conflicts: [String]
    public var warnings: [String]
    public init(selection: MigrationSelection, duplicates: [String] = [], conflicts: [String] = [], warnings: [String] = []) {
        totalBytes = selection.items.reduce(0) { $0 + $1.sizeBytes }
        counts = Dictionary(grouping: selection.items, by: { $0.category.rawValue }).mapValues(\.count)
        self.duplicates = duplicates; self.conflicts = conflicts
        self.warnings = warnings + (selection.warnings ?? []) + selection.items.flatMap(\.warnings)
    }
}

public enum MigrationJobStatus: String, Codable, Sendable {
    case uploading, queued, running, waitingForModel, completed, completedWithIssues, cancelled, failed
}
public enum MigrationStage: String, Codable, Sendable { case transfer, importing, memory, verifying, result }
public struct MigrationOutcome: Codable, Sendable, Identifiable {
    public var id: String
    public var category: MigrationCategory
    public var title: String
    public var status: String
    public var agentID: String?
    public var projectID: String?
    public var sessionID: String?
    public var mcpID: String?
    public var message: String?
    public init(item: MigrationItem, status: String, agentID: String? = nil, projectID: String? = nil,
                sessionID: String? = nil, mcpID: String? = nil, message: String? = nil) {
        id = item.id; category = item.category; title = item.title; self.status = status
        self.agentID = agentID; self.projectID = projectID; self.sessionID = sessionID; self.mcpID = mcpID; self.message = message
    }
}
public struct MigrationJob: Codable, Sendable, Identifiable {
    public var id: String
    public var destination: String
    public var status: MigrationJobStatus
    public var stage: MigrationStage
    public var totalItems: Int
    public var uploadedBytes: Int
    public var totalBytes: Int
    public var outcomes: [MigrationOutcome]
    public var warnings: [String]
    public var memoryCompletedUnits: Int
    public var memoryTotalUnits: Int
    public var createdAt: Date
    public init(id: String = UUID().uuidString.lowercased(), destination: String, totalItems: Int, totalBytes: Int) {
        self.id = id; self.destination = destination; self.totalItems = totalItems; self.totalBytes = totalBytes
        status = .uploading; stage = .transfer; uploadedBytes = 0; outcomes = []; warnings = []
        memoryCompletedUnits = 0; memoryTotalUnits = 0; createdAt = Date()
    }
}
public struct MigrationCreateRequest: Codable, Sendable {
    public var destination: String
    public var totalBytes: Int
    public var sha256: String
    public var totalItems: Int
    public init(destination: String, totalBytes: Int, sha256: String, totalItems: Int) {
        self.destination = destination; self.totalBytes = totalBytes; self.sha256 = sha256; self.totalItems = totalItems
    }
}
public struct MigrationUploadChunk: Codable, Sendable {
    public var offset: Int
    public var data: Data
    public init(offset: Int, data: Data) { self.offset = offset; self.data = data }
}
public struct MigrationScanRequest: Codable, Sendable {
    public var sources: [MigrationSource]
    public init(sources: [MigrationSource]) { self.sources = sources }
}
public enum MigrationError: Error, LocalizedError {
    case invalid(String), missing, integrity
    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .missing: return "Migration object not found."
        case .integrity: return "Migration data failed integrity verification."
        }
    }
}
public enum MigrationDigest {
    public static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func id(_ text: String) -> String { String(sha256(Data(text.utf8)).prefix(24)) }
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601; return encoder
    }
    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
    }
    public static func safeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0") &&
        path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

public struct MigrationMCPConnectionStatus: Codable, Sendable {
    public var id: String
    public var connected: Bool
    public var error: String?
    public init(id: String, connected: Bool, error: String?) {
        self.id = id; self.connected = connected; self.error = error
    }
}
