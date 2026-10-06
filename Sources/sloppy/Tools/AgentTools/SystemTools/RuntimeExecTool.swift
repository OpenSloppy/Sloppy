import AnyLanguageModel
import Foundation
import Logging
import Protocols

struct RuntimeExecTool: CoreTool {
    let domain = "runtime"
    let title = "Exec command"
    let status = "fully_functional"
    let name = "runtime.exec"
    let description = "Run one foreground command with timeout and output limits. Full stdout/stderr are saved at stdoutArtifact.path and stderrArtifact.path; use files.read to inspect sections omitted from the preview. Omit timeoutMs for builds and other long-running commands to use the configured maximum; clean builds can take 20 minutes or longer. Set a shorter timeout only when intentionally limiting the command. Successful recognized build, test, lint/typecheck, and run commands return `verificationEvidence.id` for `session.complete`. The `sloppy` CLI is available in PATH — use it to manage agents, projects, channels, providers, and more (e.g. `sloppy agent list`, `sloppy project task create`)."

    var parameters: GenerationSchema {
        .objectSchema([
            .init(name: "command", description: "Executable name or path (e.g. 'bash', '/bin/ls', 'git'). Do NOT repeat the command name in arguments.", schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "arguments", description: "Array of arguments passed to the command (argv). For shell one-liners use command='bash' arguments=['-lc', 'your command here']. Do NOT include the command name itself.", schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self)), isOptional: true),
            .init(name: "cwd", description: "Working directory (absolute path or relative to current session directory). Defaults to current session directory if omitted.", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "timeoutMs", description: "Optional command deadline in milliseconds, capped by policy. Omit for long builds/tests to use the configured maximum. A short value terminates the command when reached.", schema: DynamicGenerationSchema(type: Int.self), isOptional: true)
        ])
    }

    func invoke(arguments: [String: JSONValue], context: ToolContext) async -> ToolInvocationResult {
        let command = arguments["command"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !command.isEmpty else {
            return toolFailure(tool: name, code: "invalid_arguments", message: "`command` is required.", retryable: false)
        }
        guard isCommandAllowed(command, deniedPrefixes: context.policy.guardrails.deniedCommandPrefixes) else {
            return toolFailure(tool: name, code: "command_blocked", message: "Command blocked by guardrail denylist.", retryable: false)
        }

        let args = arguments["arguments"]?.asArray?.compactMap(\.asString) ?? []
        let timeoutMs = resolvedExecTimeoutMs(arguments: arguments, guardrails: context.policy.guardrails)
        let cwdValue = arguments["cwd"]?.asString

        let cwdURL: URL?
        if let cwdValue, !cwdValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let resolved = context.resolveExecCwd(cwdValue) else {
                return toolFailure(tool: name, code: "cwd_not_allowed", message: "CWD is outside allowed execution roots.", retryable: false)
            }
            cwdURL = resolved
        } else {
            cwdURL = context.currentDirectoryURL
        }

        do {
            let payload = try await runForegroundProcess(
                command: command,
                arguments: args,
                cwd: cwdURL,
                timeoutMs: timeoutMs,
                maxOutputBytes: context.policy.guardrails.maxExecOutputBytes,
                environmentOverrides: context.environmentOverrides,
                outputArtifacts: context.outputArtifacts
            )
            if payload.asObject?["timedOut"]?.asBool == true {
                return ToolInvocationResult(
                    tool: name,
                    ok: false,
                    data: payload,
                    error: ToolErrorPayload(
                        code: "tool_timeout",
                        message: "Command execution timed out after \(timeoutMs) ms.",
                        retryable: true,
                        hint: "Effective timeout: \(timeoutMs) ms; configured maximum: \(context.policy.guardrails.maxExecTimeoutMs) ms. For long builds, omit timeoutMs or set a sufficient deadline within that maximum. Check existing build output before retrying."
                    )
                )
            }
            return toolSuccess(tool: name, data: payload)
        } catch {
            context.logger.error(
                "Command execution failed",
                metadata: [
                    "tool": .string(name),
                    "command": .string(command),
                    "error": .string(String(describing: error))
                ]
            )
            return toolFailure(tool: name, code: "exec_failed", message: "Command execution failed: \(error.localizedDescription)", retryable: true)
        }
    }
}
