import AnyLanguageModel
import Foundation
import Protocols

struct SessionsStatusTool: CoreTool {
    let domain = "session"
    let title = "Session status"
    let status = "fully_functional"
    let name = "sessions.status"
    let description = "Read summary status for one session."

    var parameters: GenerationSchema {
        .objectSchema([
            .init(name: "agentId", description: "Target agent (defaults to current)", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "sessionId", description: "Target session ID (defaults to current)", schema: DynamicGenerationSchema(type: String.self), isOptional: true)
        ])
    }

    func invoke(arguments: [String: JSONValue], context: ToolContext) async -> ToolInvocationResult {
        let targetSession = await resolveSessionIDForStatus(arguments["sessionId"]?.asString, context: context)
        do {
            let targetAgent = try SessionToolQuery.agentID(arguments, context: context)
            let detail = try context.sessionStore.loadSession(agentID: targetAgent, sessionID: targetSession)
            let activeProcesses = await context.processRegistry.activeCount(sessionID: targetSession)
            let sessionStatus = SessionStatusResponse(
                sessionId: targetSession,
                status: statusFrom(events: detail.events),
                messageCount: detail.summary.messageCount,
                updatedAt: detail.summary.updatedAt,
                activeProcessCount: activeProcesses
            )
            return toolSuccess(tool: name, data: encodeJSONValue(sessionStatus))
        } catch {
            if arguments["agentId"]?.asString == nil || arguments["agentId"]?.asString == context.agentID,
               let channelStatus = await loadChannelSessionStatusIfAvailable(
                sessionID: targetSession,
                context: context
            ) {
                return toolSuccess(tool: name, data: encodeJSONValue(channelStatus))
            }
            return toolFailure(tool: name, code: "session_status_failed", message: "Failed to load session status.", retryable: true)
        }
    }

    private func resolveSessionIDForStatus(_ raw: String?, context: ToolContext) async -> String {
        let resolved = resolveSessionID(raw, context: context)
        guard resolved == context.sessionID,
              let channelID = context.channelID,
              !channelID.isEmpty,
              !resolved.hasPrefix("session-")
        else {
            return resolved
        }

        let sessions = (try? await context.channelSessionStore.listSessions(
            status: .open,
            channelIds: Set([channelID]),
            limit: 1
        )) ?? []
        return sessions.first?.sessionId ?? resolved
    }

    private func loadChannelSessionStatusIfAvailable(
        sessionID: String,
        context: ToolContext
    ) async -> SessionStatusResponse? {
        guard let channelID = context.channelID,
              !channelID.isEmpty
        else {
            return nil
        }
        let sessions = (try? await context.channelSessionStore.listSessions(
            status: .open,
            channelIds: Set([channelID]),
            limit: 1
        )) ?? []
        guard let summary = sessions.first,
              summary.sessionId == sessionID
        else {
            return nil
        }
        return SessionStatusResponse(
            sessionId: summary.sessionId,
            status: summary.status.rawValue,
            messageCount: summary.messageCount,
            updatedAt: summary.updatedAt,
            activeProcessCount: 0
        )
    }
}
