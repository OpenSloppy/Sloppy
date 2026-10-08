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
                "Delegate tasks asynchronously and return IDs immediately. Supply a typed assignment object. acceptanceCriteria is one string describing all criteria. Stable requestKey deduplicates within the originating user turn. Include context, attachment paths and exact scope in objectives. Validation failures include correction guidance: fix the specified fields and call again with the same requestKey. Never wait for completion."
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
                .init(name: "assignment", description: description, schema: Self.assignmentSchema)
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

    static var assignmentSchema: DynamicGenerationSchema {
        DynamicGenerationSchema(name: "LongChatAssignment", properties: [
            .init(name: "requestKey", description: "Stable key reused when correcting this assignment.", schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "title", description: "Assignment title.", schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "acceptanceCriteria", description: "One string containing all acceptance criteria; use newlines for multiple criteria.", schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "tasks", description: "One to twenty tasks with unique keys and acyclic dependencies.", schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(name: "LongChatTask", properties: [
                .init(name: "key", description: "Unique task key.", schema: DynamicGenerationSchema(type: String.self)),
                .init(name: "title", description: "Task title.", schema: DynamicGenerationSchema(type: String.self)),
                .init(name: "objective", description: "Full authorized objective, including context and attachment paths. Workers do not inherit the conversation.", schema: DynamicGenerationSchema(type: String.self)),
                .init(name: "resourceKeys", description: "Stable IDs for every resource to mutate; empty for read-only work.", schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self))),
                .init(name: "dependsOn", description: "Other task keys that must finish first.", schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self))),
                .init(name: "projectId", description: "Optional project ID.", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
                .init(name: "readOnly", description: "True for inspection, false for authorized changes.", schema: DynamicGenerationSchema(type: Bool.self)),
            ]))),
        ])
    }
    func invoke(arguments: [String: JSONValue], context: ToolContext) async -> ToolInvocationResult {
        toolFailure(
            tool: name, code: "long_chat_required", message: "Only available through a long chat coordinator.",
            retryable: false)
    }
}
