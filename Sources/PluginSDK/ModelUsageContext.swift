import Foundation
import Protocols

public struct UsageSkillDescriptor: Sendable {
    public var id: String
    public var directory: String
    public var catalogEntry: String
    public init(id: String, directory: String, catalogEntry: String) {
        self.id = id; self.directory = directory; self.catalogEntry = catalogEntry
    }
}

public struct UsageProvenance: Sendable {
    public var toolNameMap: [String: String] = [:]
    public var toolServers: [String: String] = [:]
    public var skills: [UsageSkillDescriptor] = []
    public init() {}
}

public struct ModelUsageContext: Sendable {
    public var channelId: String
    public var provider: String
    public var model: String
    public var provenance: UsageProvenance
    public var provenanceProvider: (@Sendable () async -> UsageProvenance)?
    public var onRequest: @Sendable (UsageRequestRecord) async -> Void
    public init(channelId: String, provider: String, model: String, provenance: UsageProvenance = .init(),
                provenanceProvider: (@Sendable () async -> UsageProvenance)? = nil,
                onRequest: @escaping @Sendable (UsageRequestRecord) async -> Void) {
        self.channelId = channelId; self.provider = provider; self.model = model
        self.provenance = provenance; self.provenanceProvider = provenanceProvider; self.onRequest = onRequest
    }
}
