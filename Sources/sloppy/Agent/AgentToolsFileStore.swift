import Foundation
import Protocols

final class AgentToolsFileStore {
    enum StoreError: Error {
        case invalidAgentID
        case invalidPayload
        case agentNotFound
        case storageFailure
    }

    private let fileManager: FileManager
    private var agentsRootURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(agentsRootURL: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.agentsRootURL = agentsRootURL

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        self.decoder = JSONDecoder()
    }

    func updateAgentsRootURL(_ url: URL) {
        self.agentsRootURL = url
    }

    func defaultPolicy() -> AgentToolsPolicy {
        AgentToolsPolicy(
            version: 1,
            defaultPolicy: .allow,
            tools: [:],
            approval: .init(enabled: false),
            sandbox: .init(),
            preToolsHook: .init(),
            guardrails: .init()
        )
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

    func getPolicy(agentID: String, knownToolIDs: Set<String>) throws -> AgentToolsPolicy {
        let normalizedAgentID = try normalizedAgentID(agentID)
        guard let agentDirectory = resolvedAgentDirectoryURL(agentID: normalizedAgentID) else {
            throw StoreError.agentNotFound
        }

        let url = agentDirectory
            .appendingPathComponent("tools", isDirectory: true)
            .appendingPathComponent("tools.json")
        if !fileManager.fileExists(atPath: url.path) {
            let created = defaultPolicy()
            try writePolicy(created, agentDirectory: agentDirectory)
            return created
        }

        do {
            let data = try Data(contentsOf: url)
            let decoded = try decoder.decode(AgentToolsPolicy.self, from: data)
            return try validated(decoded, knownToolIDs: knownToolIDs)
        } catch {
            throw StoreError.invalidPayload
        }
    }

    func updatePolicy(
        agentID: String,
        request: AgentToolsUpdateRequest,
        knownToolIDs: Set<String>
    ) throws -> AgentToolsPolicy {
        let normalizedAgentID = try normalizedAgentID(agentID)
        guard let agentDirectory = resolvedAgentDirectoryURL(agentID: normalizedAgentID) else {
            throw StoreError.agentNotFound
        }

        let version = request.version ?? 1
        let savedGrants = try request.approvalGrants ?? getPolicy(
            agentID: normalizedAgentID, knownToolIDs: knownToolIDs
        ).approvalGrants
        let approvalGrants = savedGrants.filter { request.tools[$0.tool] != false }
        let policy = AgentToolsPolicy(
            version: version,
            defaultPolicy: request.defaultPolicy,
            tools: request.tools,
            approval: request.approval,
            sandbox: request.sandbox,
            preToolsHook: request.preToolsHook,
            approvalGrants: approvalGrants,
            guardrails: request.guardrails
        )
        let validated = try validated(policy, knownToolIDs: knownToolIDs)

        do {
            try writePolicy(validated, agentDirectory: agentDirectory)
            return validated
        } catch {
            throw StoreError.storageFailure
        }
    }

    func toolsConfigURL(agentID: String) -> URL? {
        resolvedAgentDirectoryURL(agentID: agentID)?
            .appendingPathComponent("tools", isDirectory: true)
            .appendingPathComponent("tools.json")
    }

    private func writePolicy(_ policy: AgentToolsPolicy, agentDirectory: URL) throws {
        let toolsDirectory = agentDirectory.appendingPathComponent("tools", isDirectory: true)
        try fileManager.createDirectory(at: toolsDirectory, withIntermediateDirectories: true)

        let url = toolsDirectory.appendingPathComponent("tools.json")
        let payload = try encoder.encode(policy) + Data("\n".utf8)
        try payload.write(to: url, options: .atomic)
    }

    private func validated(_ policy: AgentToolsPolicy, knownToolIDs: Set<String>) throws -> AgentToolsPolicy {
        var policy = policy
        if policy.guardrails.maxExecTimeoutMs == AgentToolsGuardrails.legacyDefaultMaxExecTimeoutMs {
            policy.guardrails.maxExecTimeoutMs = AgentToolsGuardrails.defaultMaxExecTimeoutMs
        }

        guard policy.version == 1 else {
            throw StoreError.invalidPayload
        }

        if policy.guardrails.maxReadBytes <= 0 ||
            policy.guardrails.maxWriteBytes <= 0 ||
            policy.guardrails.execTimeoutMs <= 0 ||
            policy.guardrails.maxExecTimeoutMs <= 0 ||
            policy.guardrails.maxExecOutputBytes <= 0 ||
            policy.guardrails.maxProcessesPerSession <= 0 ||
            policy.guardrails.maxToolCallsPerMinute <= 0 ||
            policy.guardrails.toolLoopWindowSeconds <= 0 ||
            policy.guardrails.maxConsecutiveIdenticalToolCalls <= 0 ||
            policy.guardrails.maxIdenticalToolCallsPerWindow <= 0 ||
            policy.guardrails.maxRepeatedNonRetryableFailures <= 0 ||
            policy.guardrails.webTimeoutMs <= 0 ||
            policy.guardrails.webMaxBytes <= 0 {
            throw StoreError.invalidPayload
        }

        let unknownIDs = Set(policy.tools.keys).subtracting(knownToolIDs)
        if !unknownIDs.isEmpty {
            throw StoreError.invalidPayload
        }

        return policy
    }

    private func normalizedAgentID(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw StoreError.invalidAgentID
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard trimmed.rangeOfCharacter(from: allowed.inverted) == nil else {
            throw StoreError.invalidAgentID
        }
        return trimmed
    }
}
