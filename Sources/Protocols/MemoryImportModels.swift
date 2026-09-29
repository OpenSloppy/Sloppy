import Foundation

public enum MemoryImportStatus: String, Codable, Sendable {
    case queued, running, completed, failed, cancelling, cancelled
}

public struct MemoryImportRequest: Codable, Sendable {
    public var projectId: String? = nil
    public var sessionId: String?
    public var attachments: [AgentAttachmentUpload]

    public init(sessionId: String? = nil, attachments: [AgentAttachmentUpload], projectId: String? = nil) {
        self.projectId = projectId
        self.sessionId = sessionId
        self.attachments = attachments
    }
}

public struct MemoryImportSourceInfo: Codable, Sendable {
    public var id: String
    public var name: String
    public var sha256: String
    public var sizeBytes: Int
    public var totalUnits: Int
    public var completedUnits: Int

    public init(id: String, name: String, sha256: String, sizeBytes: Int, totalUnits: Int, completedUnits: Int) {
        self.id = id; self.name = name; self.sha256 = sha256; self.sizeBytes = sizeBytes
        self.totalUnits = totalUnits; self.completedUnits = completedUnits
    }
}

public struct MemoryImportJob: Codable, Sendable {
    public var projectId: String? = nil
    public var id: String
    public var agentId: String
    public var sessionId: String
    public var status: MemoryImportStatus
    public var sources: [MemoryImportSourceInfo]
    public var totalUnits: Int
    public var completedUnits: Int
    public var savedCount: Int
    public var duplicateCount: Int
    public var ignoredCount: Int
    public var error: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var parts: [MemoryImportPart]

    public init(id: String, agentId: String, sessionId: String, status: MemoryImportStatus,
                sources: [MemoryImportSourceInfo], totalUnits: Int, completedUnits: Int,
                savedCount: Int, duplicateCount: Int, ignoredCount: Int, error: String?, createdAt: Date, updatedAt: Date, parts: [MemoryImportPart] = [], projectId: String? = nil) {
        self.projectId = projectId
        self.id = id; self.agentId = agentId; self.sessionId = sessionId; self.status = status
        self.sources = sources; self.totalUnits = totalUnits; self.completedUnits = completedUnits
        self.savedCount = savedCount; self.duplicateCount = duplicateCount; self.ignoredCount = ignoredCount
        self.error = error; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.parts = parts
    }
}

public struct MemoryImportPart: Codable, Sendable {
    public var id: String
    public var sourceId: String
    public var startUTF8: Int
    public var endUTF8: Int
    public var completed: Bool
    public var disposition: String?
    public var reason: String?
    public var memoryIds: [String]

    public init(id: String, sourceId: String, startUTF8: Int, endUTF8: Int, completed: Bool, disposition: String?, reason: String?, memoryIds: [String]) {
        self.id = id; self.sourceId = sourceId; self.startUTF8 = startUTF8; self.endUTF8 = endUTF8
        self.completed = completed; self.disposition = disposition; self.reason = reason; self.memoryIds = memoryIds
    }
}

public struct MemoryImportSourceContent: Codable, Sendable {
    public var name: String
    public var sha256: String
    public var content: String

    public init(name: String, sha256: String, content: String) {
        self.name = name; self.sha256 = sha256; self.content = content
    }
}

public struct MemoryImportSourceLocation: Codable, Sendable {
    public var jobId: String
    public var sourceId: String
    public var name: String
    public var startUTF8: Int
    public var endUTF8: Int

    public init(jobId: String, sourceId: String, name: String, startUTF8: Int, endUTF8: Int) {
        self.jobId = jobId; self.sourceId = sourceId; self.name = name
        self.startUTF8 = startUTF8; self.endUTF8 = endUTF8
    }
}
