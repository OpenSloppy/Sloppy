import AnyLanguageModel
import Foundation
import Protocols

/// Handles both `sessions.send` and `messages.send` tool IDs.
struct SessionsSendTool: CoreTool {
    let domain = "messages"
    let title = "Send message"
    let status = "fully_functional"
    let name = "messages.send"
    let description = "Queue a message to another session, including another agent. Supply a sessionId from sessions.list; self-messaging is rejected. Returns a delivery receipt immediately; the recipient handles it after its current turn. Sender identity is server-assigned."

    var toolAliases: [String] { ["sessions.send"] }

    var parameters: GenerationSchema {
        .objectSchema([
            .init(name: "content", description: "Message content", schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "sessionId", description: "Target session ID (defaults to current)", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "agentId", description: "Target agent (defaults to current)", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "messageId", description: "Stable UUID for deduplicating a retry", schema: DynamicGenerationSchema(type: String.self), isOptional: true)
        ])
    }

    func invoke(arguments: [String: JSONValue], context: ToolContext) async -> ToolInvocationResult {
        let content = arguments["content"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !content.isEmpty else {
            return toolFailure(tool: name, code: "invalid_arguments", message: "content is required.", retryable: false)
        }
        guard let service = context.sessionService else {
            return toolFailure(tool: name, code: "session_service_unavailable", message: "Session delivery is unavailable.", retryable: false)
        }
        do {
            let targetAgent = try SessionToolQuery.agentID(arguments, context: context)
            let result = try await service.sendPeerSessionMessage(
                senderAgentID: context.agentID, senderSessionID: context.sessionID,
                targetAgentID: targetAgent,
                targetSessionID: resolveSessionID(arguments["sessionId"]?.asString, context: context),
                content: content, messageID: arguments["messageId"]?.asString
            )
            return toolSuccess(tool: name, data: result)
        } catch let error as PeerSessionMessageError {
            return toolFailure(tool: name, code: error.code, message: error.description, retryable: false)
        } catch {
            return toolFailure(tool: name, code: "session_send_failed", message: "Session delivery failed: \(error)", retryable: false)
        }
    }
}
