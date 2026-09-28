import Foundation

public enum PromptProcessKind: String, Sendable {
    case agentSessionBootstrap = "agent_session_bootstrap"
    case swarmPlanner = "swarm_planner"

    public var templateName: String {
        rawValue
    }
}
