import Foundation
import Protocols
import SloppyRuntime

protocol SessionToolService: Sendable {
    func linkCurrentSessionToCodeReview(providerID: String, reviewID: String, agentID: String, sessionID: String) async throws -> AgentSessionSummary
    func sendPeerSessionMessage(
        senderAgentID: String, senderSessionID: String, targetAgentID: String, targetSessionID: String,
        content: String, messageID: String?
    ) async throws -> JSONValue
}

enum SessionToolQuery {
    enum QueryError: Error { case invalidArguments, invalidCursor }

    static func agentID(_ arguments: [String: JSONValue], context: ToolContext) throws -> String {
        let agentID = arguments["agentId"]?.asString ?? context.agentID
        _ = try context.agentCatalogStore.getAgent(id: agentID)
        if agentID != context.agentID {
            guard let sessionID = arguments["sessionId"]?.asString, !sessionID.isEmpty,
                  !["current", "self"].contains(sessionID) else { throw QueryError.invalidArguments }
        }
        return agentID
    }

    static func list(
        agentID: String?, projectID: String?, query: String?, limit: Int?, offset: Int, includeWorkers: Bool,
        catalog: AgentCatalogFileStore, store: AgentSessionFileStore
    ) throws -> [AgentSessionSummary] {
        let agents = try agentID.map { [try catalog.getAgent(id: $0)] } ?? catalog.listAgents()
        var sessions = try agents.flatMap { try store.listSessions(agentID: $0.id) }
        if !includeWorkers {
            let coordinatorIDs = Set(sessions.filter { $0.kind == .longChat }.map(\.id))
            sessions.removeAll { $0.kind == .longChatWorker || $0.parentSessionId.map(coordinatorIDs.contains) == true }
        }
        if let projectID, !projectID.isEmpty { sessions.removeAll { $0.projectId != projectID } }
        if let query, !query.isEmpty {
            sessions.removeAll { ![$0.title, $0.agentId, $0.id].contains(where: { $0.localizedCaseInsensitiveContains(query) }) }
        }
        sessions.sort { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
        let page = sessions.dropFirst(max(0, offset))
        return Array(page.prefix(limit.map { max(0, min(500, $0)) } ?? page.count))
    }

    static func history(_ detail: AgentSessionDetail, arguments: [String: JSONValue]) throws -> JSONValue {
        let limit = min(500, max(1, arguments["limit"]?.asInt ?? 100))
        let end: Int
        if let cursor = arguments["beforeEventId"]?.asString {
            guard let index = detail.events.firstIndex(where: { $0.id == cursor }) else { throw QueryError.invalidCursor }
            end = index
        } else { end = detail.events.count }
        let start = max(0, end - limit)
        let events = Array(detail.events[start..<end])
        var value = encodeJSONValue(detail).asObject ?? [:]
        value["events"] = encodeJSONValue(events)
        value["hasMore"] = .bool(start > 0)
        value["beforeEventId"] = start > 0 ? events.first.map { .string($0.id) } ?? .null : .null
        return .object(value)
    }
}
