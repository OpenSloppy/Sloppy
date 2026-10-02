import AnyLanguageModel
import Foundation
import Protocols

struct LongChatTool: CoreTool {
    let action: String
    var name: String { "long_chat.\(action)" }
    let domain = "long_chat"
    var title: String { "Long chat \(action)" }
    let status = "fully_functional"
    var description: String {
        switch action {
        case "delegate":
            return
                "Delegate tasks asynchronously and return IDs immediately. assignment is a JSON string: {requestKey,title,acceptanceCriteria,tasks:[{key,title,objective,resourceKeys:[stable resource IDs to mutate; empty for read-only],dependsOn:[task keys],projectId?:string,readOnly?:boolean}]}. Stable requestKey deduplicates within the originating user turn. Include context and exact scope in objectives. Never wait for completion."
        case "status": return "Read persisted assignments, tasks and attempts in this long chat."
        case "message":
            return "Send a clarification to an existing task. Do not use this to expand the user's authorization."
        case "cancel": return "Cancel a task, or all active tasks when taskId is omitted."
        default:
            return
                "Create a new attempt for a failed task within its original objective and permissions. At most two automatic retries."
        }
    }
    var parameters: GenerationSchema {
        switch action {
        case "delegate":
            return .objectSchema([
                .init(name: "assignment", description: description, schema: DynamicGenerationSchema(type: String.self))
            ])
        case "status":
            return .objectSchema([
                .init(
                    name: "taskId", description: "Optional task ID for full objective and attempt history",
                    schema: DynamicGenerationSchema(type: String.self), isOptional: true)
            ])
        case "message":
            return .objectSchema([
                .init(
                    name: "taskId", description: "Existing task ID", schema: DynamicGenerationSchema(type: String.self)),
                .init(
                    name: "content", description: "Clarification", schema: DynamicGenerationSchema(type: String.self)),
            ])
        default:
            return .objectSchema([
                .init(
                    name: "taskId", description: "Existing task ID", schema: DynamicGenerationSchema(type: String.self),
                    isOptional: action == "cancel")
            ])
        }
    }
    func invoke(arguments: [String: JSONValue], context: ToolContext) async -> ToolInvocationResult {
        toolFailure(
            tool: name, code: "long_chat_required", message: "Only available through a long chat coordinator.",
            retryable: false)
    }
}
