import Foundation
import AnyLanguageModel
import Protocols

struct LaunchConfigureTool: CoreTool {
    let name = "session.launch.configure"
    let domain = "session"
    let title = "Configure Play"
    let status = "fully_functional"
    let description = "Save a runnable target for this chat's Play button. Use actual checkout/worktree paths and verified build/run commands. Register separate configurations for multiple projects or targets. This saves configuration only; it does not run commands. For libraries without an app, explain that no runnable target exists."
    var parameters: GenerationSchema {
        .objectSchema([
            .init(name: "configuration", description: "Launch configuration JSON: name, target, platform (web/macOS/iOSSimulator), checkoutPath, workingDirectory (relative), build [{executable,arguments}], launch {executable,arguments} for web, webPort/webPath; appPath (relative .app), bundleID/simulatorID for Apple. Optional id updates a saved target; verificationEvidenceIDs references checks performed.", schema: DynamicGenerationSchema(type: String.self))
        ])
    }
    func invoke(arguments: [String: JSONValue], context: ToolContext) async -> ToolInvocationResult {
        do {
            guard let service = context.projectService as? any LaunchToolService,
                  let json = arguments["configuration"]?.asString else {
                return toolFailure(tool: name, code: "invalid_arguments", message: "Provide a launch configuration JSON string.", retryable: false)
            }
            let request = try JSONDecoder().decode(LaunchConfigurationRequest.self, from: Data(json.utf8))
            guard context.resolveExecCwd(request.checkoutPath) != nil else {
                return toolFailure(tool: name, code: "cwd_not_allowed", message: "Checkout is outside allowed execution roots.", retryable: false)
            }
            let state = try await service.configureLaunch(agentID: context.agentID, sessionID: context.sessionID, request: request)
            let data = try JSONEncoder().encode(state)
            return toolSuccess(tool: name, data: try JSONDecoder().decode(JSONValue.self, from: data))
        } catch {
            return toolFailure(tool: name, code: "launch_configuration_invalid", message: error.localizedDescription, retryable: false)
        }
    }
}
