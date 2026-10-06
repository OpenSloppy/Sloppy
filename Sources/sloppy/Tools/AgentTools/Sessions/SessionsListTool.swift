import AnyLanguageModel
import Foundation
import Protocols

struct SessionsListTool: CoreTool {
    let domain = "session"
    let title = "List sessions"
    let status = "fully_functional"
    let name = "sessions.list"
    let description = "Discover sessions, including workers. Use scope=all to find other agents; use returned agentId and id for history or messaging."

    var parameters: GenerationSchema {
        .objectSchema([
            .init(name: "scope", description: "current (default) or all agents", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "agentId", description: "Filter by agent", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "projectId", description: "Filter by project", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "query", description: "Search title, agent or session ID", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "limit", description: "Maximum results (default 50, max 500)", schema: DynamicGenerationSchema(type: Int.self), isOptional: true),
            .init(name: "offset", description: "Pagination offset", schema: DynamicGenerationSchema(type: Int.self), isOptional: true),
        ])
    }

    func invoke(arguments: [String: JSONValue], context: ToolContext) async -> ToolInvocationResult {
        do {
            let scope = arguments["scope"]?.asString ?? "current"
            guard ["current", "all"].contains(scope) else {
                return toolFailure(tool: name, code: "invalid_arguments", message: "scope must be current or all.", retryable: false)
            }
            let sessions = try SessionToolQuery.list(
                agentID: arguments["agentId"]?.asString ?? (scope == "all" ? nil : context.agentID),
                projectID: arguments["projectId"]?.asString, query: arguments["query"]?.asString,
                limit: arguments["limit"]?.asInt ?? 50, offset: arguments["offset"]?.asInt ?? 0, includeWorkers: true,
                catalog: context.agentCatalogStore, store: context.sessionStore
            )
            return toolSuccess(tool: name, data: encodeJSONValue(sessions))
        } catch {
            return toolFailure(tool: name, code: "session_list_failed", message: "Failed to list sessions.", retryable: true)
        }
    }
}
