import Foundation

public struct AgentSessionImportOrigin: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable { case codex, claude, openclaw, hermes }
    public var source: Source
    public var sourceID: String
    public var externalID: String
    public var jobID: String
    public var archived: Bool
    public init(source: Source, sourceID: String, externalID: String, jobID: String, archived: Bool = false) {
        self.source = source; self.sourceID = sourceID; self.externalID = externalID; self.jobID = jobID; self.archived = archived
    }
}
