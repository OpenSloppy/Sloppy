import Foundation

extension SloppyAPIClient {
    private func launchPath(agentID: String, sessionID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return "/v1/agents/\(agentID.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")/sessions/\(sessionID.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")/launch"
    }
    public func fetchLaunchState(agentID: String, sessionID: String) async throws -> LaunchSessionState {
        try await http.get(launchPath(agentID: agentID, sessionID: sessionID))
    }
    public func configureLaunch(agentID: String, sessionID: String, request: LaunchConfigurationRequest) async throws -> LaunchSessionState {
        try await http.post(launchPath(agentID: agentID, sessionID: sessionID) + "/configurations", body: request)
    }
    public func selectLaunch(agentID: String, sessionID: String, request: LaunchSelectionRequest) async throws -> LaunchSessionState {
        try await http.post(launchPath(agentID: agentID, sessionID: sessionID) + "/selection", body: request)
    }
    public func startLaunch(agentID: String, sessionID: String, configurationID: String) async throws -> LaunchRun {
        try await http.post(launchPath(agentID: agentID, sessionID: sessionID) + "/configurations/\(configurationID)/start", body: [String: String]())
    }
    public func stopLaunch(agentID: String, sessionID: String, runID: String) async throws -> LaunchSessionState {
        try await http.post(launchPath(agentID: agentID, sessionID: sessionID) + "/runs/\(runID)/stop", body: [String: String]())
    }
    public func removeLaunch(agentID: String, sessionID: String, configurationID: String) async throws -> LaunchSessionState {
        try await http.delete(launchPath(agentID: agentID, sessionID: sessionID) + "/configurations/\(configurationID)")
        return try await fetchLaunchState(agentID: agentID, sessionID: sessionID)
    }
    public func archiveLaunch(agentID: String, sessionID: String, isArchived: Bool) async throws -> LaunchSessionState {
        try await http.post(launchPath(agentID: agentID, sessionID: sessionID) + "/archive", body: LaunchArchiveRequest(isArchived: isArchived))
    }
    public func fetchLaunchSimulators(agentID: String, sessionID: String) async throws -> [LaunchSimulator] {
        try await http.get(launchPath(agentID: agentID, sessionID: sessionID) + "/simulators")
    }
    public func launchPreviewSocketPath(agentID: String, sessionID: String, runID: String) -> String {
        let path = launchPath(agentID: agentID, sessionID: sessionID) + "/runs/\(runID)/preview/ws"
        if case .relay(_, let node) = endpoint {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
            return "/v1/node/mesh/nodes/\(node.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" + path.dropFirst(3)
        }
        return path
    }
}
