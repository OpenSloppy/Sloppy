import Foundation
import SloppyRuntime

struct ACPPersistedSessionState: Codable, Sendable, Equatable {
    let targetId: String
    let transportFingerprint: String
    let effectiveCwd: String
    let upstreamSessionId: String
    let agentName: String?
    let agentVersion: String?
    let supportsLoadSession: Bool
}

final class ACPSessionStateStore {
    private let fileManager: FileManager
    private var agentsRootURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(agentsRootURL: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.agentsRootURL = agentsRootURL

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder

        self.decoder = JSONDecoder()
    }

    func updateAgentsRootURL(_ url: URL) {
        agentsRootURL = url
    }

    func load(agentID: String, sessionID: String) throws -> ACPPersistedSessionState? {
        guard let url = sidecarURL(agentID: agentID, sessionID: sessionID),
              fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        return try decoder.decode(ACPPersistedSessionState.self, from: data)
    }

    func save(_ state: ACPPersistedSessionState, agentID: String, sessionID: String) throws {
        guard let url = sidecarURL(agentID: agentID, sessionID: sessionID) else {
            return
        }
        if let directory = url.deletingLastPathComponent() as URL? {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let data = try encoder.encode(state)
        try data.write(to: url, options: .atomic)
    }

    func delete(agentID: String, sessionID: String) throws {
        guard let url = sidecarURL(agentID: agentID, sessionID: sessionID),
              fileManager.fileExists(atPath: url.path) else {
            return
        }
        try fileManager.removeItem(at: url)
    }

    private func sidecarURL(agentID: String, sessionID: String) -> URL? {
        guard let agentDirectory = resolvedAgentDirectoryURL(agentID: agentID) else {
            return nil
        }
        let resolver = AgentSessionPathResolver(agentDirectoryURL: agentDirectory, fileManager: fileManager)
        if let location = resolver.existingLocation(sessionID: sessionID) {
            return location.acpStateURL
        }
        return resolver.legacyLocation(sessionID: sessionID).acpStateURL
    }

    private func resolvedAgentDirectoryURL(agentID: String) -> URL? {
        let regular = agentsRootURL.appendingPathComponent(agentID, isDirectory: true)
        if fileManager.fileExists(atPath: regular.path) {
            return regular
        }
        let system = agentsRootURL.appendingPathComponent(".system", isDirectory: true)
            .appendingPathComponent(agentID, isDirectory: true)
        if fileManager.fileExists(atPath: system.path) {
            return system
        }
        return nil
    }
}
