import ArgumentParser
import Foundation

struct AgentCommand: SloppyGroupCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent",
        abstract: "Manage agents, sessions, memories, cron, skills.",
        subcommands: [
            AgentListCommand.self,
            AgentGetCommand.self,
            AgentCreateCommand.self,
            AgentDeleteCommand.self,
            AgentConfigCommand.self,
            AgentToolsCommand.self,
            AgentSessionCommand.self,
            AgentMemoryCommand.self,
            AgentCronCommand.self,
            AgentSkillCommand.self,
            AgentTokenUsageCommand.self,
        ]
    )
}

// MARK: - List / Get / Create / Delete

struct AgentListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List all agents.")

    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Option(name: .long) var format: String = "json"
    @Flag(name: .long) var verbose: Bool = false
    @Flag(name: .long, inversion: .prefixedNo, help: "Include system agents") var system: Bool = true

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        do {
            let data = try await client.get("/v1/agents", query: ["system": system ? "true" : "false"])
            CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

struct AgentGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get agent details.")

    @Argument(help: "Agent ID") var agentId: String
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Option(name: .long) var format: String = "json"
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        do {
            let data = try await client.get("/v1/agents/\(agentId)")
            CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

struct AgentCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a new agent.")

    @Option(name: .long, help: "Agent ID") var id: String?
    @Option(name: .long, help: "Agent name") var name: String = ""
    @Option(name: .long, help: "Agent role description") var role: String?
    @Option(name: .long, help: "Model identifier (e.g. openai-api:gpt-5.4-mini)") var model: String?
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Option(name: .long) var format: String = "json"
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        var payload: [String: Any] = [:]
        if let id { payload["id"] = id }
        if !name.isEmpty { payload["name"] = name }
        if let role { payload["role"] = role }
        if let model { payload["selectedModel"] = model }
        do {
            let body = try JSONSerialization.data(withJSONObject: payload)
            let data = try await client.post("/v1/agents", body: body)
            CLIStyle.success("Agent created.")
            CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

struct AgentDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete an agent.")

    @Argument(help: "Agent ID") var agentId: String
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        do {
            _ = try await client.delete("/v1/agents/\(agentId)")
            CLIStyle.success("Agent \(CLIStyle.whiteBold(agentId)) deleted.")
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

// MARK: - Config

struct AgentConfigCommand: SloppyGroupCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "View or update agent configuration.",
        subcommands: [AgentConfigGetCommand.self, AgentConfigSetCommand.self]
    )
}

struct AgentConfigGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get agent config.")

    @Argument(help: "Agent ID") var agentId: String
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Option(name: .long) var format: String = "json"
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        do {
            let data = try await client.get("/v1/agents/\(agentId)/config")
            CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

struct AgentConfigSetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Update agent config.")

    @Argument(help: "Agent ID") var agentId: String
    @Option(name: .long, help: "Model identifier") var model: String?
    @Option(name: .long, help: "Agent name") var name: String?
    @Option(name: .long, help: "Agent role description") var role: String?
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Option(name: .long) var format: String = "json"
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        var payload: [String: Any] = [:]
        if let model { payload["selectedModel"] = model }
        if let name { payload["name"] = name }
        if let role { payload["role"] = role }
        do {
            let body = try JSONSerialization.data(withJSONObject: payload)
            let data = try await client.put("/v1/agents/\(agentId)/config", body: body)
            CLIStyle.success("Agent config updated.")
            CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

// MARK: - Tools

struct AgentToolsCommand: SloppyGroupCommand {
    static let configuration = CommandConfiguration(
        commandName: "tools",
        abstract: "View or update agent tool policy.",
        subcommands: [AgentToolsListCommand.self, AgentToolsCatalogCommand.self, AgentToolsSetCommand.self]
    )
}

struct AgentToolsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "Get agent tool policy.")

    @Argument(help: "Agent ID") var agentId: String
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Option(name: .long) var format: String = "json"
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        do {
            let data = try await client.get("/v1/agents/\(agentId)/tools")
            CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

struct AgentToolsCatalogCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "catalog", abstract: "Get tool catalog for agent.")

    @Argument(help: "Agent ID") var agentId: String
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Option(name: .long) var format: String = "json"
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        do {
            let data = try await client.get("/v1/agents/\(agentId)/tools/catalog")
            CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

struct AgentToolsSetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Update agent tool policy from a JSON file.")

    @Argument(help: "Agent ID") var agentId: String
    @Option(name: .long, help: "Path to JSON policy file") var file: String
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Option(name: .long) var format: String = "json"
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        do {
            let body = try Data(contentsOf: URL(fileURLWithPath: file))
            let data = try await client.put("/v1/agents/\(agentId)/tools", body: body)
            CLIStyle.success("Agent tool policy updated.")
            CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

// MARK: - Sessions

struct AgentSessionCommand: SloppyGroupCommand {
    static let configuration = CommandConfiguration(
        commandName: "session",
        abstract: "Manage agent sessions.",
        subcommands: [
            AgentSessionListCommand.self,
            AgentSessionGetCommand.self,
            AgentSessionCreateCommand.self,
            AgentSessionDeleteCommand.self,
            AgentSessionMessageCommand.self,
            AgentSessionLaunchCommand.self,
        ]
    )
}

struct AgentSessionListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List agent sessions.")

    @Argument(help: "Agent ID") var agentId: String
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Option(name: .long) var format: String = "json"
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        do {
            let data = try await client.get("/v1/agents/\(agentId)/sessions")
            CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

struct AgentSessionGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get session details.")

    @Argument(help: "Agent ID") var agentId: String
    @Argument(help: "Session ID") var sessionId: String
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Option(name: .long) var format: String = "json"
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        do {
            let data = try await client.get("/v1/agents/\(agentId)/sessions/\(sessionId)")
            CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

struct AgentSessionCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a new agent session.")

    @Argument(help: "Agent ID") var agentId: String
    @Option(name: .long, help: "Session title") var title: String?
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Option(name: .long) var format: String = "json"
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        var payload: [String: Any] = [:]
        if let title { payload["title"] = title }
        do {
            let body = try JSONSerialization.data(withJSONObject: payload)
            let data = try await client.post("/v1/agents/\(agentId)/sessions", body: body)
            CLIStyle.success("Session created.")
            CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

struct AgentSessionDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete an agent session.")

    @Argument(help: "Agent ID") var agentId: String
    @Argument(help: "Session ID") var sessionId: String
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        do {
            _ = try await client.delete("/v1/agents/\(agentId)/sessions/\(sessionId)")
            CLIStyle.success("Session \(CLIStyle.whiteBold(sessionId)) deleted.")
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

struct AgentSessionMessageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "message", abstract: "Send a message to a session.")

    @Argument(help: "Agent ID") var agentId: String
    @Argument(help: "Session ID") var sessionId: String
    @Option(name: .long, help: "Message content") var content: String
    @Option(name: .long, help: "User ID") var userId: String = "cli"
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Option(name: .long) var format: String = "json"
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        let payload: [String: Any] = ["content": content, "userId": userId]
        do {
            let body = try JSONSerialization.data(withJSONObject: payload)
            let data = try await client.post("/v1/agents/\(agentId)/sessions/\(sessionId)/messages", body: body)
            CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

// MARK: - Memory

struct AgentMemoryCommand: SloppyGroupCommand {
    static let configuration = CommandConfiguration(
        commandName: "memory",
        abstract: "Manage agent memories.",
        subcommands: [AgentMemoryListCommand.self, AgentMemoryUpdateCommand.self, AgentMemoryDeleteCommand.self]
    )
}

struct AgentMemoryListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List agent memories.")

    @Argument(help: "Agent ID") var agentId: String
    @Option(name: .long, help: "Search query") var search: String?
    @Option(name: .long, help: "Filter: all, episodic, identity, etc.") var filter: String = "all"
    @Option(name: .long, help: "Number of results") var limit: Int = 20
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Option(name: .long) var format: String = "json"
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        var query: [String: String] = ["filter": filter, "limit": "\(limit)"]
        if let search { query["search"] = search }
        do {
            let data = try await client.get("/v1/agents/\(agentId)/memories", query: query)
            CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

struct AgentMemoryUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a memory entry.")

    @Argument(help: "Agent ID") var agentId: String
    @Argument(help: "Memory ID") var memoryId: String
    @Option(name: .long, help: "Memory note text") var note: String?
    @Option(name: .long, help: "Importance 0.0-1.0") var importance: Double?
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Option(name: .long) var format: String = "json"
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        var payload: [String: Any] = [:]
        if let note { payload["note"] = note }
        if let importance { payload["importance"] = importance }
        do {
            let body = try JSONSerialization.data(withJSONObject: payload)
            let data = try await client.patch("/v1/agents/\(agentId)/memories/\(memoryId)", body: body)
            CLIStyle.success("Memory updated.")
            CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

struct AgentMemoryDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a memory entry.")

    @Argument(help: "Agent ID") var agentId: String
    @Argument(help: "Memory ID") var memoryId: String
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        do {
            _ = try await client.delete("/v1/agents/\(agentId)/memories/\(memoryId)")
            CLIStyle.success("Memory \(CLIStyle.whiteBold(memoryId)) deleted.")
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

// MARK: - Cron

struct AgentCronCommand: SloppyGroupCommand {
    static let configuration = CommandConfiguration(
        commandName: "cron",
        abstract: "Manage agent cron tasks.",
        subcommands: [
            AgentCronListCommand.self,
            AgentCronCreateCommand.self,
            AgentCronUpdateCommand.self,
            AgentCronDeleteCommand.self,
        ]
    )
}

struct AgentCronListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List agent cron tasks.")

    @Argument(help: "Agent ID") var agentId: String
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Option(name: .long) var format: String = "json"
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        do {
            let data = try await client.get("/v1/agents/\(agentId)/cron")
            CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

struct AgentCronCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a cron task.")

    @Argument(help: "Agent ID") var agentId: String
    @Option(name: .long, help: "Cron expression (e.g. '0 9 * * *')") var schedule: String
    @Option(name: .long, help: "Command to run") var command: String
    @Option(name: .long, help: "Channel ID to deliver to") var channelId: String?
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Option(name: .long) var format: String = "json"
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        var payload: [String: Any] = ["schedule": schedule, "command": command]
        if let channelId { payload["channelId"] = channelId }
        do {
            let body = try JSONSerialization.data(withJSONObject: payload)
            let data = try await client.post("/v1/agents/\(agentId)/cron", body: body)
            CLIStyle.success("Cron task created.")
            CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

struct AgentCronUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a cron task.")

    @Argument(help: "Agent ID") var agentId: String
    @Argument(help: "Cron task ID") var cronId: String
    @Option(name: .long, help: "New cron expression") var schedule: String?
    @Option(name: .long, help: "New command") var command: String?
    @Option(name: .long, help: "Enable or disable") var enabled: Bool?
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Option(name: .long) var format: String = "json"
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        var payload: [String: Any] = [:]
        if let schedule { payload["schedule"] = schedule }
        if let command { payload["command"] = command }
        if let enabled { payload["enabled"] = enabled }
        do {
            let body = try JSONSerialization.data(withJSONObject: payload)
            let data = try await client.put("/v1/agents/\(agentId)/cron/\(cronId)", body: body)
            CLIStyle.success("Cron task updated.")
            CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

struct AgentCronDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a cron task.")

    @Argument(help: "Agent ID") var agentId: String
    @Argument(help: "Cron task ID") var cronId: String
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        do {
            _ = try await client.delete("/v1/agents/\(agentId)/cron/\(cronId)")
            CLIStyle.success("Cron task \(CLIStyle.whiteBold(cronId)) deleted.")
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

// MARK: - Skills

struct AgentSkillCommand: SloppyGroupCommand {
    static let configuration = CommandConfiguration(
        commandName: "skill",
        abstract: "Manage agent skills.",
        subcommands: [AgentSkillListCommand.self, AgentSkillInstallCommand.self, AgentSkillUninstallCommand.self]
    )
}

struct AgentSkillListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List installed agent skills.")

    @Argument(help: "Agent ID") var agentId: String
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Option(name: .long) var format: String = "json"
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        do {
            let data = try await client.get("/v1/agents/\(agentId)/skills")
            CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

struct AgentSkillInstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "install", abstract: "Install a skill for an agent.")

    @Argument(help: "Agent ID") var agentId: String
    @Option(name: .long, help: "GitHub owner. Required unless --local-path is provided.") var owner: String?
    @Option(name: .long, help: "GitHub repo. Required unless --local-path is provided.") var repo: String?
    @Option(name: .long, help: "Local skill directory containing SKILL.md") var localPath: String?
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Option(name: .long) var format: String = "json"
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        let payload = try Self.makePayload(owner: owner, repo: repo, localPath: localPath)
        do {
            let body = try JSONSerialization.data(withJSONObject: payload)
            let data = try await client.post("/v1/agents/\(agentId)/skills", body: body)
            CLIStyle.success("Skill installed.")
            CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
        } catch let error as ValidationError {
            CLIStyle.error(error.message)
            throw ExitCode.failure
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }

    struct ValidationError: Error {
        let message: String
    }

    static func makePayload(owner: String?, repo: String?, localPath: String?) throws -> [String: Any] {
        var payload: [String: Any] = [:]
        let trimmedOwner = owner?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedRepo = repo?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedLocalPath = localPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedLocalPath.isEmpty {
            payload["localPath"] = trimmedLocalPath
            if !trimmedOwner.isEmpty { payload["owner"] = trimmedOwner }
            if !trimmedRepo.isEmpty { payload["repo"] = trimmedRepo }
        } else if !trimmedOwner.isEmpty && !trimmedRepo.isEmpty {
            payload["owner"] = trimmedOwner
            payload["repo"] = trimmedRepo
        } else {
            throw ValidationError(message: "Provide either --local-path or both --owner and --repo.")
        }
        return payload
    }
}

struct AgentSkillUninstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "uninstall", abstract: "Uninstall a skill from an agent.")

    @Argument(help: "Agent ID") var agentId: String
    @Argument(help: "Skill ID") var skillId: String
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        do {
            _ = try await client.delete("/v1/agents/\(agentId)/skills/\(skillId)")
            CLIStyle.success("Skill \(CLIStyle.whiteBold(skillId)) uninstalled.")
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}

// MARK: - Token Usage

struct AgentTokenUsageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "token-usage", abstract: "View agent token usage.")

    @Argument(help: "Agent ID") var agentId: String
    @Option(name: .long) var url: String?
    @Option(name: .long) var token: String?
    @Option(name: .long) var format: String = "json"
    @Flag(name: .long) var verbose: Bool = false

    mutating func run() async throws {
        let client = SloppyCLIClient.resolve(url: url, token: token, verbose: verbose)
        do {
            let data = try await client.get("/v1/agents/\(agentId)/token-usage")
            CLIFormatters.output(data, format: CLIFormatters.resolveFormat(format))
        } catch {
            CLIStyle.error(error.localizedDescription); throw ExitCode.failure
        }
    }
}
