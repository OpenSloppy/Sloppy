import Foundation
import ArgumentParser
import Protocols

struct AgentSessionLaunchCommand: SloppyGroupCommand {
    static let configuration = CommandConfiguration(commandName: "launch", abstract: "Manage runnable chat targets.", subcommands: [AgentSessionLaunchConfigureCommand.self, AgentSessionLaunchListCommand.self])
}

struct AgentSessionLaunchConfigureCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "configure", abstract: "Save a Play recipe from a JSON file (also available to ACP agents).")
    @Argument(help: "Agent ID") var agentId: String
    @Argument(help: "Sloppy session ID") var sessionId: String
    @Option(name: .long, help: "LaunchConfigurationRequest JSON file") var file: String
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Flag(name: .long) var verbose: Bool = false
    mutating func run() async throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: file))
        let configuration = try JSONDecoder().decode(LaunchConfigurationRequest.self, from: data)
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        let result = try await client.post(launchCLIPath(agentId, sessionId) + "/configurations", body: JSONEncoder().encode(configuration))
        CLIFormatters.output(result, format: .json)
    }
}

struct AgentSessionLaunchListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "Show chat launch recipes and recent runs.")
    @Argument(help: "Agent ID") var agentId: String
    @Argument(help: "Sloppy session ID") var sessionId: String
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Flag(name: .long) var verbose: Bool = false
    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        CLIFormatters.output(try await client.get(launchCLIPath(agentId, sessionId)), format: .json)
    }
}

private func launchCLIPath(_ agent: String, _ session: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    return "/v1/agents/\(agent.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")/sessions/\(session.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")/launch"
}
