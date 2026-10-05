import Foundation
import Protocols

struct SubagentToolApprovalContext: Encodable, Sendable {
    var userRequest: String
    var objective: String
    var acceptanceCriteria: String?
    var readOnly: Bool
    var resourceKeys: [String]
    var workingDirectory: String?
    var tool: String
    var arguments: [String: JSONValue]
    var requestedAccess: [ToolApprovalGrant]
    var reason: String?
}

enum SemanticToolApprovalDecision: String, Sendable {
    case approve
    case reject
    case askUser = "ask_user"
}
