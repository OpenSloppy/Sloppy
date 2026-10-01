import ArgumentParser
import Foundation
import SloppyNodeCLI
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct SloppyApp: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sloppy",
        abstract: "AI agent runtime and CLI.",
        subcommands: [
            RunCommand.self,
            ServiceCommand.self,
            AgentCommand.self,
            ProjectCommand.self,
            ChannelCommand.self,
            EventsCommand.self,
            AuthCommand.self,
            ConsoleCommand.self,
            ConfigCommand.self,
            CoffeeCommand.self,
            DeepResearchCommand.self,
            ProvidersCommand.self,
            ActorCommand.self,
            PluginCommand.self,
            AgentPluginCommandGroup.self,
            NodeCommand.self,
            SourceControlCommand.self,
            MCPCommand.self,
            ACPCommand.self,
            VisorCommand.self,
            SkillsCommand.self,
            StatusCommand.self,
            UpdateCommand.self,
            TuiCommand.self,
            ModelsCommand.self,
            LogsCommand.self,
            WorkersCommand.self,
            BulletinsCommand.self,
            TokenUsageCommand.self,
        ]
    )

    @Flag(name: .customLong("version"), help: "Print the current sloppy version.")
    var printVersion: Bool = false

    @Option(name: [.short, .long], help: "Resume the TUI directly from an agent session ID.")
    var session: String?

    @Option(name: [.customShort("p"), .long], help: "Run one non-interactive prompt and print the final answer.")
    var prompt: String?

    @Option(name: .long, help: "Agent ID for non-interactive prompt mode.")
    var agent: String?

    @Option(name: .long, help: "Path to JSON config file for non-interactive prompt mode.")
    var configPath: String?

    @Option(name: .long, help: "Working directory for non-interactive prompt mode.")
    var cwd: String?

    @Option(name: .long, help: "Chat mode for non-interactive prompt mode: ask, build, plan, debug, or auto.")
    var mode: String?

    mutating func run() async throws {
        if printVersion {
            print("sloppy \(SloppyVersion.current)")
            return
        }
        if let prompt {
            do {
                let answer = try await OneShotPromptRunner.run(
                    OneShotPromptOptions(
                        prompt: prompt,
                        agentID: agent,
                        sessionID: session,
                        configPath: configPath,
                        cwd: cwd,
                        mode: mode
                    )
                )
                if !answer.isEmpty {
                    print(answer)
                }
                return
            } catch {
                CLIStyle.error(error.localizedDescription)
                throw ExitCode.failure
            }
        }
        guard Self.shouldStartTUI(
            prompt: prompt,
            stdinIsTTY: isatty(STDIN_FILENO) != 0,
            stdoutIsTTY: isatty(STDOUT_FILENO) != 0
        ) else {
            CLIStyle.error("Refusing to start the interactive TUI on non-interactive stdio. Use `sloppy acp serve` for ACP stdio or `sloppy -p <prompt>` for one-shot prompts.")
            throw ExitCode.failure
        }
        try await SloppyTUIApp(requestedSessionID: session).run()
    }

    static func shouldStartTUI(prompt: String?, stdinIsTTY: Bool, stdoutIsTTY: Bool) -> Bool {
        prompt == nil && stdinIsTTY && stdoutIsTTY
    }
}

@main
enum SloppyMain {
    static func main() async {
        await SloppyApp.mainWithStyledHelp()
    }
}

extension SloppyApp {
    static func mainWithStyledHelp(_ arguments: [String]? = nil) async {
        do {
            var command = try parseAsRoot(arguments)
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch {
            let fullText = CLIStyle.colorizedHelp(fullMessage(for: error))
            if !fullText.isEmpty {
                if exitCode(for: error) == .success {
                    print(fullText)
                } else {
                    FileHandle.standardError.write(Data((fullText + "\n").utf8))
                }
            }
            platformExit(exitCode(for: error).rawValue)
        }
    }

    private static func platformExit(_ code: Int32) -> Never {
        #if canImport(Darwin)
        Darwin.exit(code)
        #elseif canImport(Glibc)
        Glibc.exit(code)
        #endif
    }
}
