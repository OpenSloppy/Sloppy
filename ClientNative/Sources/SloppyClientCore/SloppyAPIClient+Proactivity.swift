import Foundation

extension SloppyAPIClient {
    public func fetchProactiveInbox(agentId: String) async throws -> ProactiveInbox {
        try await http.get("/v1/agents/\(proactivePathComponent(agentId))/proactivity")
    }

    public func fetchProactiveSettings(agentId: String) async throws -> ProactiveSettingsResponse {
        try await http.get("/v1/agents/\(proactivePathComponent(agentId))/proactivity/settings")
    }

    public func updateProactiveSettings(agentId: String, request: ProactiveSettingsRequest) async throws -> ProactiveSettingsResponse {
        try await http.put("/v1/agents/\(proactivePathComponent(agentId))/proactivity/settings", body: request)
    }

    public func updateProactiveFinding(agentId: String, findingId: String, action: ProactiveFindingActionRequest.Action) async throws -> ProactiveFinding {
        try await http.post("/v1/agents/\(proactivePathComponent(agentId))/proactivity/findings/\(proactivePathComponent(findingId))/action", body: ProactiveFindingActionRequest(action: action))
    }

    public func fetchAllProactiveFindings() async throws -> [ProactiveFinding] {
        let agents = try await fetchAgents()
        return await withTaskGroup(of: [ProactiveFinding].self) { group in
            for agent in agents {
                group.addTask { (try? await self.fetchProactiveInbox(agentId: agent.id).findings) ?? [] }
            }
            var findings: [ProactiveFinding] = []
            for await batch in group { findings += batch }
            return findings.sorted { $0.createdAt > $1.createdAt }
        }
    }

    private func proactivePathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(.init(charactersIn: "/?#%"))) ?? ""
    }
}
