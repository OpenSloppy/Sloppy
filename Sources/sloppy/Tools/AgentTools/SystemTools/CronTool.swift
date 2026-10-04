import AnyLanguageModel
import Foundation
import Protocols

struct CronTool: CoreTool {
    let domain = "automation"
    let title = "Schedule cron job"
    let status = "fully_functional"
    let name = "cron"
    let description = "Schedule a recurring cron job that resumes the current chat by default. Target 'main' to create a new agent chat on each run, or use a session ID to resume an existing chat. Explicit external channel IDs deliver through the channel runtime."

    var parameters: GenerationSchema {
        .objectSchema([
            .init(name: "schedule", description: "Cron expression (e.g. '0 9 * * *' for every day at 9 AM)", schema: DynamicGenerationSchema(type: String.self), isOptional: false),
            .init(name: "command", description: "Message text or trigger command to send on each cron tick", schema: DynamicGenerationSchema(type: String.self), isOptional: false),
            .init(name: "channel_id", description: "Target session or channel ID; defaults to the current chat. Use 'main' for a new chat on every run.", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
        ])
    }

    func invoke(arguments: [String: JSONValue], context: ToolContext) async -> ToolInvocationResult {
        let schedule = arguments["schedule"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let command = arguments["command"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let channelId = arguments["channel_id"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? sessionChannelID(agentID: context.agentID, sessionID: context.sessionID)

        guard CronEvaluator.isValid(cronExpression: schedule), !command.isEmpty else {
            return toolFailure(tool: name, code: "invalid_arguments", message: "A valid five-field `schedule` and nonempty `command` are required.", retryable: false)
        }

        let task = AgentCronTask(
            id: UUID().uuidString,
            agentId: context.agentID,
            channelId: channelId,
            schedule: schedule,
            command: command,
            enabled: true
        )
        await context.store.saveCronTask(task)

        return toolSuccess(tool: name, data: .object([
            "task_id": .string(task.id),
            "status": .string("created")
        ]))
    }
}
