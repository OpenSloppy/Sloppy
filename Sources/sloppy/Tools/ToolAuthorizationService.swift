import Foundation
import Protocols

struct ToolAuthorizationDecision: Sendable {
    let allowed: Bool
    let policy: AgentToolsPolicy
    let error: ToolErrorPayload?
}

actor ToolAuthorizationService {
    private struct CachedPolicy {
        let policy: AgentToolsPolicy
        let modifiedAt: Date?
    }

    private let store: AgentToolsFileStore
    private let mcpRegistry: any MCPToolDiscovering
    private var cache: [String: CachedPolicy] = [:]
    private var invocationsByAgent: [String: [Date]] = [:]

    init(store: AgentToolsFileStore, mcpRegistry: any MCPToolDiscovering) {
        self.store = store
        self.mcpRegistry = mcpRegistry
    }

    init(store: AgentToolsFileStore) {
        self.store = store
        self.mcpRegistry = MCPClientRegistry(config: .init())
    }

    func updateAgentsRootURL(_ url: URL) {
        store.updateAgentsRootURL(url)
        cache.removeAll()
        invocationsByAgent.removeAll()
    }

    func invalidateCachedPolicies() {
        cache.removeAll()
    }

    func policy(agentID: String) async throws -> AgentToolsPolicy {
        let knownToolIDs = await ToolCatalog.knownToolIDs(mcpRegistry: mcpRegistry)
        return try reloadedPolicy(agentID: agentID, knownToolIDs: knownToolIDs)
    }

    func updatePolicy(agentID: String, request: AgentToolsUpdateRequest) async throws -> AgentToolsPolicy {
        let knownToolIDs = await ToolCatalog.knownToolIDs(mcpRegistry: mcpRegistry)
        let updated = try store.updatePolicy(
            agentID: agentID,
            request: request,
            knownToolIDs: knownToolIDs
        )
        let mtime = try? modificationDate(agentID: agentID)
        cache[agentID] = CachedPolicy(policy: updated, modifiedAt: mtime)
        return updated
    }

    func rememberApprovalGrants(agentID: String, grants: [ToolApprovalGrant]) async throws {
        let knownToolIDs = await ToolCatalog.knownToolIDs(mcpRegistry: mcpRegistry)
        let current = try reloadedPolicy(agentID: agentID, knownToolIDs: knownToolIDs)
        var approved = current.approvalGrants
        for grant in grants where !approved.contains(grant) {
            approved.append(grant)
        }
        var tools = current.tools
        for grant in grants where grant.kind == .tool {
            tools[grant.tool] = true
        }
        let updated = try store.updatePolicy(agentID: agentID, request: AgentToolsUpdateRequest(
            version: current.version,
            defaultPolicy: current.defaultPolicy,
            tools: tools,
            approval: current.approval,
            sandbox: current.sandbox,
            preToolsHook: current.preToolsHook,
            approvalGrants: approved,
            guardrails: current.guardrails
        ), knownToolIDs: knownToolIDs)
        cache[agentID] = CachedPolicy(policy: updated, modifiedAt: try? modificationDate(agentID: agentID))
    }

    func authorize(
        agentID: String,
        toolID: String,
        enforceRateLimit: Bool = true,
        sessionMCPRegistry: (any MCPToolDiscovering)? = nil
    ) async throws -> ToolAuthorizationDecision {
        let builtInToolIDs = ToolCatalog.knownToolIDs
        if builtInToolIDs.contains(toolID) {
            let policy = try reloadedPolicy(agentID: agentID, knownToolIDs: builtInToolIDs)
            return authorizeKnownTool(
                agentID: agentID,
                toolID: toolID,
                policy: policy,
                enforceRateLimit: enforceRateLimit
            )
        }

        let dynamicToolIDs = await (sessionMCPRegistry ?? mcpRegistry).dynamicToolIDs()
        let knownToolIDs = builtInToolIDs.union(dynamicToolIDs)
        let policy = try reloadedPolicy(agentID: agentID, knownToolIDs: knownToolIDs)

        guard knownToolIDs.contains(toolID) else {
            return ToolAuthorizationDecision(
                allowed: false,
                policy: policy,
                error: ToolErrorPayload(
                    code: "unknown_tool",
                    message: "Unknown tool '\(toolID)'",
                    retryable: false
                )
            )
        }

        return authorizeKnownTool(
            agentID: agentID,
            toolID: toolID,
            policy: policy,
            enforceRateLimit: enforceRateLimit
        )
    }

    private func authorizeKnownTool(
        agentID: String,
        toolID: String,
        policy: AgentToolsPolicy,
        enforceRateLimit: Bool
    ) -> ToolAuthorizationDecision {
        let explicitlyAllowed = policy.tools[toolID]
        let allowed = explicitlyAllowed ?? (policy.defaultPolicy == .allow)
        guard allowed else {
            return ToolAuthorizationDecision(
                allowed: false,
                policy: policy,
                error: ToolErrorPayload(
                    code: "tool_forbidden",
                    message: "Tool '\(toolID)' is disabled by policy.",
                    retryable: false
                )
            )
        }

        guard enforceRateLimit else {
            return ToolAuthorizationDecision(allowed: true, policy: policy, error: nil)
        }

        let now = Date()
        var timestamps = invocationsByAgent[agentID] ?? []
        let threshold = now.addingTimeInterval(-60)
        timestamps = timestamps.filter { $0 >= threshold }
        if timestamps.count >= policy.guardrails.maxToolCallsPerMinute {
            invocationsByAgent[agentID] = timestamps
            return ToolAuthorizationDecision(
                allowed: false,
                policy: policy,
                error: ToolErrorPayload(
                    code: "rate_limited",
                    message: "Too many tool invocations in a short period.",
                    retryable: true
                )
            )
        }

        timestamps.append(now)
        invocationsByAgent[agentID] = timestamps
        return ToolAuthorizationDecision(allowed: true, policy: policy, error: nil)
    }

    private func reloadedPolicy(agentID: String, knownToolIDs: Set<String>) throws -> AgentToolsPolicy {
        let currentMtime = try? modificationDate(agentID: agentID)
        if let cached = cache[agentID], cached.modifiedAt == currentMtime {
            return cached.policy
        }

        let loaded = try store.getPolicy(agentID: agentID, knownToolIDs: knownToolIDs)
        cache[agentID] = CachedPolicy(policy: loaded, modifiedAt: currentMtime)
        return loaded
    }
    private func modificationDate(agentID: String) throws -> Date? {
        guard let url = store.toolsConfigURL(agentID: agentID) else {
            return nil
        }
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
        return values.contentModificationDate
    }
}
