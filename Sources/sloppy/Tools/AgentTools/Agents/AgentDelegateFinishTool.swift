import AnyLanguageModel
import Foundation
import Protocols

struct AgentDelegateFinishTool: CoreTool {
    let domain = "agent_delegate"
    let title = "Finish delegated task"
    let status = "fully_functional"
    let name = "agent_delegate.finish"
    let toolAliases = ["agents.delegate_finish"]
    let description = """
    Finish the current delegated subagent task with a structured outcome. Use this as the final step when the delegated goal is complete, blocked, or failed. `status` must be completed, failed, or blocked.
    """

    var parameters: GenerationSchema {
        .objectSchema([
            .init(name: "evidence", description: "Verification evidence for the outcome", schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self)), isOptional: true),
            .init(name: "artifacts", description: "Artifact URLs or paths", schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self)), isOptional: true),
            .init(
                name: "status",
                description: "Outcome status: completed, failed, or blocked.",
                schema: DynamicGenerationSchema(type: String.self)
            ),
            .init(
                name: "summary",
                description: "Concise final result, evidence, or blocker summary for the parent agent.",
                schema: DynamicGenerationSchema(type: String.self)
            ),
            .init(
                name: "error",
                description: "Required for failed/blocked outcomes when there is a concrete error or blocker.",
                schema: DynamicGenerationSchema(type: String.self),
                isOptional: true
            ),
        ])
    }

    func invoke(arguments: [String: JSONValue], context _: ToolContext) async -> ToolInvocationResult {
        let rawStatus = arguments["status"]?.asString?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let normalizedStatus: String
        switch rawStatus {
        case "completed", "complete", "done", "success", "succeeded":
            normalizedStatus = "completed"
        case "failed", "fail", "error":
            normalizedStatus = "failed"
        case "blocked", "blocker":
            normalizedStatus = "blocked"
        default:
            return toolFailure(
                tool: name,
                code: "invalid_arguments",
                message: "`status` must be one of: completed, failed, blocked.",
                retryable: false
            )
        }

        let summary = arguments["summary"]?.asString?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !summary.isEmpty else {
            return toolFailure(
                tool: name,
                code: "invalid_arguments",
                message: "`summary` is required.",
                retryable: false
            )
        }

        let error = arguments["error"]?.asString?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedStatus == "completed", !(error ?? "").isEmpty {
            return toolFailure(
                tool: name,
                code: "invalid_arguments",
                message: "Use status `blocked` or `failed` when reporting an error; completed outcomes must not include `error`.",
                retryable: false
            )
        }
        if normalizedStatus != "completed", (error ?? "").isEmpty {
            return toolFailure(
                tool: name,
                code: "invalid_arguments",
                message: "`error` is required when status is failed or blocked.",
                retryable: false
            )
        }

        return toolSuccess(tool: name, data: .object([
            "evidence": .array(arguments["evidence"]?.asArray ?? []),
            "artifacts": .array(arguments["artifacts"]?.asArray ?? []),
            "finished": .bool(true),
            "status": .string(normalizedStatus),
            "summary": .string(summary),
            "error": error.map(JSONValue.string) ?? .null,
        ]))
    }
}
