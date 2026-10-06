import Foundation

public struct SloppyConfig: Codable, Sendable {
    public struct Listen: Codable, Sendable {
        public var host: String
        public var port: Int

        public init(host: String = "0.0.0.0", port: Int = 25101) {
            self.host = host
            self.port = port
        }
    }

    public struct Workspace: Codable, Sendable {
        public var name: String
        public var basePath: String

        public init(name: String = ".sloppy", basePath: String = ".") {
            self.name = name
            self.basePath = basePath
        }
    }

    public struct Auth: Codable, Sendable {
        public var token: String

        public init(token: String = "dev-token") {
            self.token = token
        }
    }

    public struct Onboarding: Codable, Sendable {
        public var completed: Bool

        public init(completed: Bool = false) {
            self.completed = completed
        }
    }

    public struct ModelConfig: Codable, Sendable {
        public var title: String
        public var apiKey: String
        public var apiUrl: String
        public var model: String
        /// When `true`, this row is ignored for inference and routing (Dashboard).
        public var disabled: Bool
        /// Dashboard catalog id (e.g. `openai-api`, `openrouter`) to disambiguate multiple rows of the same kind.
        public var providerCatalogId: String?

        public var contextWindowTokens: Int?
        public var maxInputTokens: Int?
        public var maxOutputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case title
            case apiKey
            case apiUrl
            case model
            case disabled
            case providerCatalogId
            case contextWindowTokens
            case maxInputTokens
            case maxOutputTokens
        }

        public init(
            title: String,
            apiKey: String,
            apiUrl: String,
            model: String,
            disabled: Bool = false,
            providerCatalogId: String? = nil,
            contextWindowTokens: Int? = nil,
            maxInputTokens: Int? = nil,
            maxOutputTokens: Int? = nil
        ) {
            self.title = title
            self.apiKey = apiKey
            self.apiUrl = apiUrl
            self.model = model
            self.disabled = disabled
            self.providerCatalogId = providerCatalogId
            self.contextWindowTokens = contextWindowTokens
            self.maxInputTokens = maxInputTokens
            self.maxOutputTokens = maxOutputTokens
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try container.decode(String.self, forKey: .title)
            apiKey = try container.decode(String.self, forKey: .apiKey)
            apiUrl = try container.decode(String.self, forKey: .apiUrl)
            model = try container.decode(String.self, forKey: .model)
            disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
            providerCatalogId = try container.decodeIfPresent(String.self, forKey: .providerCatalogId)
            contextWindowTokens = try container.decodeIfPresent(Int.self, forKey: .contextWindowTokens)
            maxInputTokens = try container.decodeIfPresent(Int.self, forKey: .maxInputTokens)
            maxOutputTokens = try container.decodeIfPresent(Int.self, forKey: .maxOutputTokens)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(title, forKey: .title)
            try container.encode(apiKey, forKey: .apiKey)
            try container.encode(apiUrl, forKey: .apiUrl)
            try container.encode(model, forKey: .model)
            try container.encode(disabled, forKey: .disabled)
            try container.encodeIfPresent(providerCatalogId, forKey: .providerCatalogId)
            try container.encodeIfPresent(contextWindowTokens, forKey: .contextWindowTokens)
            try container.encodeIfPresent(maxInputTokens, forKey: .maxInputTokens)
            try container.encodeIfPresent(maxOutputTokens, forKey: .maxOutputTokens)
        }
    }

    public struct PluginConfig: Codable, Sendable {
        public var title: String
        public var apiKey: String
        public var apiUrl: String
        public var plugin: String

        public init(title: String, apiKey: String, apiUrl: String, plugin: String) {
            self.title = title
            self.apiKey = apiKey
            self.apiUrl = apiUrl
            self.plugin = plugin
        }
    }

    public struct Memory: Codable, Sendable {
        public struct Retrieval: Codable, Sendable {
            public var topK: Int
            public var semanticWeight: Double
            public var keywordWeight: Double
            public var graphWeight: Double

            public init(topK: Int = 8, semanticWeight: Double = 0.55, keywordWeight: Double = 0.35, graphWeight: Double = 0.10) {
                self.topK = topK
                self.semanticWeight = semanticWeight
                self.keywordWeight = keywordWeight
                self.graphWeight = graphWeight
            }
        }

        public struct Retention: Codable, Sendable {
            public var episodicDays: Int
            public var todoCompletedDays: Int
            public var bulletinDays: Int

            public init(episodicDays: Int = 90, todoCompletedDays: Int = 30, bulletinDays: Int = 180) {
                self.episodicDays = episodicDays
                self.todoCompletedDays = todoCompletedDays
                self.bulletinDays = bulletinDays
            }
        }

        public var backend: String
        public var retrieval: Retrieval
        public var retention: Retention

        public init(backend: String = "sqlite-local-vectors", retrieval: Retrieval = Retrieval(), retention: Retention = Retention()) {
            self.backend = backend
            self.retrieval = retrieval
            self.retention = retention
        }

        private enum CodingKeys: String, CodingKey {
            case backend, retrieval, retention
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            backend = try container.decode(String.self, forKey: .backend)
            retrieval = try container.decodeIfPresent(Retrieval.self, forKey: .retrieval) ?? Retrieval()
            retention = try container.decodeIfPresent(Retention.self, forKey: .retention) ?? Retention()
        }
    }

    public struct ChannelConfig: Codable, Sendable {
        public struct Telegram: Codable, Sendable {
            public var botToken: String
            public var channelChatMap: [String: Int64]
            public var topicChannelMap: [String: String]
            public var allowedUserIds: [Int64]
            public var allowedChatIds: [Int64]

            public init(
                botToken: String = "",
                channelChatMap: [String: Int64] = [:],
                topicChannelMap: [String: String] = [:],
                allowedUserIds: [Int64] = [],
                allowedChatIds: [Int64] = []
            ) {
                self.botToken = botToken
                self.channelChatMap = channelChatMap
                self.topicChannelMap = topicChannelMap
                self.allowedUserIds = allowedUserIds
                self.allowedChatIds = allowedChatIds
            }

            private enum CodingKeys: String, CodingKey {
                case botToken, channelChatMap, topicChannelMap, allowedUserIds, allowedChatIds
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                botToken = try container.decodeIfPresent(String.self, forKey: .botToken) ?? ""
                channelChatMap = try container.decodeIfPresent([String: Int64].self, forKey: .channelChatMap) ?? [:]
                topicChannelMap = try container.decodeIfPresent([String: String].self, forKey: .topicChannelMap) ?? [:]
                allowedUserIds = try container.decodeIfPresent([Int64].self, forKey: .allowedUserIds) ?? []
                allowedChatIds = try container.decodeIfPresent([Int64].self, forKey: .allowedChatIds) ?? []
            }
        }

        public struct Discord: Codable, Sendable {
            public var botToken: String
            public var channelDiscordChannelMap: [String: String]
            public var allowedGuildIds: [String]
            public var allowedChannelIds: [String]
            public var allowedUserIds: [String]

            public init(
                botToken: String = "",
                channelDiscordChannelMap: [String: String] = [:],
                allowedGuildIds: [String] = [],
                allowedChannelIds: [String] = [],
                allowedUserIds: [String] = []
            ) {
                self.botToken = botToken
                self.channelDiscordChannelMap = channelDiscordChannelMap
                self.allowedGuildIds = allowedGuildIds
                self.allowedChannelIds = allowedChannelIds
                self.allowedUserIds = allowedUserIds
            }

            private enum CodingKeys: String, CodingKey {
                case botToken, channelDiscordChannelMap, allowedGuildIds, allowedChannelIds, allowedUserIds
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                botToken = try container.decodeIfPresent(String.self, forKey: .botToken) ?? ""
                channelDiscordChannelMap = try container.decodeIfPresent([String: String].self, forKey: .channelDiscordChannelMap) ?? [:]
                allowedGuildIds = try container.decodeIfPresent([String].self, forKey: .allowedGuildIds) ?? []
                allowedChannelIds = try container.decodeIfPresent([String].self, forKey: .allowedChannelIds) ?? []
                allowedUserIds = try container.decodeIfPresent([String].self, forKey: .allowedUserIds) ?? []
            }
        }

        public var telegram: Telegram?
        public var discord: Discord?
        public var channelInactivityDays: Int

        public init(
            telegram: Telegram? = nil,
            discord: Discord? = nil,
            channelInactivityDays: Int = 2
        ) {
            self.telegram = telegram
            self.discord = discord
            self.channelInactivityDays = channelInactivityDays
        }

        private enum CodingKeys: String, CodingKey {
            case telegram, discord, channelInactivityDays
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            telegram = try container.decodeIfPresent(Telegram.self, forKey: .telegram)
            discord = try container.decodeIfPresent(Discord.self, forKey: .discord)
            channelInactivityDays = try container.decodeIfPresent(Int.self, forKey: .channelInactivityDays) ?? 2
        }
    }

    public struct Node: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var title: String
        public var url: String
        public var token: String
        public var tokenEnv: String
        public var enabled: Bool
        public var kind: String

        public init(
            id: String,
            title: String = "",
            url: String = "",
            token: String = "",
            tokenEnv: String = "",
            enabled: Bool = true,
            kind: String = "sloppy_instance"
        ) {
            self.id = id
            self.title = title
            self.url = url
            self.token = token
            self.tokenEnv = tokenEnv
            self.enabled = enabled
            self.kind = kind
        }

        private enum CodingKeys: String, CodingKey {
            case id, title, url, token, tokenEnv, enabled, kind
        }

        public init(from decoder: Decoder) throws {
            if let legacy = try? decoder.singleValueContainer().decode(String.self) {
                id = legacy
                title = legacy
                url = ""
                token = ""
                tokenEnv = ""
                enabled = true
                kind = legacy == "local" ? "local" : "legacy"
                return
            }

            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
            title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
            url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
            token = try container.decodeIfPresent(String.self, forKey: .token) ?? ""
            tokenEnv = try container.decodeIfPresent(String.self, forKey: .tokenEnv) ?? ""
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "sloppy_instance"
        }
    }

    public struct SearchTools: Codable, Sendable {
        public struct Provider: Codable, Sendable {
            public var apiKey: String

            public init(apiKey: String = "") {
                self.apiKey = apiKey
            }
        }

        public struct Providers: Codable, Sendable {
            public var brave: Provider
            public var perplexity: Provider

            public init(brave: Provider = Provider(), perplexity: Provider = Provider()) {
                self.brave = brave
                self.perplexity = perplexity
            }
        }

        public var activeProvider: String
        public var providers: Providers

        public init(activeProvider: String = "perplexity", providers: Providers = Providers()) {
            self.activeProvider = activeProvider
            self.providers = providers
        }
    }

    public struct Browser: Codable, Sendable {
        public var enabled: Bool
        public var executablePath: String
        public var cdpEndpoint: String
        public var profileName: String
        public var profilePath: String
        public var headless: Bool
        public var startupTimeoutMs: Int
        public var additionalArguments: [String]

        public init(
            enabled: Bool = false,
            executablePath: String = "",
            cdpEndpoint: String = "",
            profileName: String = "default",
            profilePath: String = "",
            headless: Bool = false,
            startupTimeoutMs: Int = 10_000,
            additionalArguments: [String] = []
        ) {
            self.enabled = enabled
            self.executablePath = executablePath
            self.cdpEndpoint = cdpEndpoint
            self.profileName = profileName
            self.profilePath = profilePath
            self.headless = headless
            self.startupTimeoutMs = startupTimeoutMs
            self.additionalArguments = additionalArguments
        }

        private enum CodingKeys: String, CodingKey {
            case enabled, executablePath, cdpEndpoint, profileName, profilePath, headless, startupTimeoutMs, additionalArguments
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            executablePath = try container.decodeIfPresent(String.self, forKey: .executablePath) ?? ""
            cdpEndpoint = try container.decodeIfPresent(String.self, forKey: .cdpEndpoint) ?? ""
            profileName = try container.decodeIfPresent(String.self, forKey: .profileName) ?? "default"
            profilePath = try container.decodeIfPresent(String.self, forKey: .profilePath) ?? ""
            headless = try container.decodeIfPresent(Bool.self, forKey: .headless) ?? false
            startupTimeoutMs = try container.decodeIfPresent(Int.self, forKey: .startupTimeoutMs) ?? 10_000
            additionalArguments = try container.decodeIfPresent([String].self, forKey: .additionalArguments) ?? []
        }
    }

    public struct MCP: Codable, Sendable {
        public var servers: [MCPServer]

        public init(servers: [MCPServer] = []) {
            self.servers = servers
        }
    }

    public struct MCPServer: Codable, Sendable, Identifiable {
        public var id: String
        public var transport: String
        public var command: String
        public var arguments: [String]
        public var cwd: String
        public var endpoint: String
        public var headers: [String: String]
        public var environment: [String: String]
        public var timeoutMs: Int
        public var enabled: Bool
        public var exposeTools: Bool
        public var exposeResources: Bool
        public var exposePrompts: Bool
        public var toolPrefix: String

        public init(
            id: String = "new-mcp-server",
            transport: String = "stdio",
            command: String = "npx",
            arguments: [String] = [],
            cwd: String = "",
            endpoint: String = "",
            headers: [String: String] = [:],
            environment: [String: String] = [:],
            timeoutMs: Int = 15_000,
            enabled: Bool = true,
            exposeTools: Bool = true,
            exposeResources: Bool = true,
            exposePrompts: Bool = true,
            toolPrefix: String = ""
        ) {
            self.id = id
            self.transport = transport
            self.command = command
            self.arguments = arguments
            self.cwd = cwd
            self.endpoint = endpoint
            self.headers = headers
            self.environment = environment
            self.timeoutMs = timeoutMs
            self.enabled = enabled
            self.exposeTools = exposeTools
            self.exposeResources = exposeResources
            self.exposePrompts = exposePrompts
            self.toolPrefix = toolPrefix
        }

        private enum CodingKeys: String, CodingKey {
            case id, transport, command, arguments, cwd, endpoint, headers, environment, timeoutMs, enabled, exposeTools, exposeResources, exposePrompts, toolPrefix
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            transport = try container.decodeIfPresent(String.self, forKey: .transport) ?? "stdio"
            command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
            arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
            cwd = try container.decodeIfPresent(String.self, forKey: .cwd) ?? ""
            endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint) ?? ""
            headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
            environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
            timeoutMs = try container.decodeIfPresent(Int.self, forKey: .timeoutMs) ?? 15_000
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            exposeTools = try container.decodeIfPresent(Bool.self, forKey: .exposeTools) ?? true
            exposeResources = try container.decodeIfPresent(Bool.self, forKey: .exposeResources) ?? true
            exposePrompts = try container.decodeIfPresent(Bool.self, forKey: .exposePrompts) ?? true
            toolPrefix = try container.decodeIfPresent(String.self, forKey: .toolPrefix) ?? ""
        }
    }

    public struct Proxy: Codable, Sendable {
        public var enabled: Bool
        public var type: String
        public var host: String
        public var port: Int
        public var username: String
        public var password: String

        public init(enabled: Bool = false, type: String = "socks5", host: String = "", port: Int = 1080, username: String = "", password: String = "") {
            self.enabled = enabled
            self.type = type
            self.host = host
            self.port = port
            self.username = username
            self.password = password
        }

        private enum CodingKeys: String, CodingKey {
            case enabled, type, host, port, username, password
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            type = try container.decodeIfPresent(String.self, forKey: .type) ?? "socks5"
            host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
            port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 1080
            username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
            password = try container.decodeIfPresent(String.self, forKey: .password) ?? ""
        }
    }

    public struct UI: Codable, Sendable {
        public struct DashboardAuth: Codable, Sendable {
            public var enabled: Bool
            public var token: String

            public init(enabled: Bool = false, token: String = "") {
                self.enabled = enabled
                self.token = token
            }
        }

        public struct DashboardTerminal: Codable, Sendable {
            public var enabled: Bool
            public var localOnly: Bool

            public init(enabled: Bool = false, localOnly: Bool = true) {
                self.enabled = enabled
                self.localOnly = localOnly
            }
        }

        public var dashboardAuth: DashboardAuth
        public var dashboardTerminal: DashboardTerminal

        public init(
            dashboardAuth: DashboardAuth = DashboardAuth(),
            dashboardTerminal: DashboardTerminal = DashboardTerminal()
        ) {
            self.dashboardAuth = dashboardAuth
            self.dashboardTerminal = dashboardTerminal
        }
    }

    public struct TUI: Codable, Sendable {
        public var defaultEditor: String

        public init(defaultEditor: String = "") {
            self.defaultEditor = defaultEditor
        }
    }

    public struct ToolHooks: Codable, Sendable {
        public struct PreTools: Codable, Sendable {
            public var enabled: Bool
            public var command: String
            public var arguments: [String]
            public var timeoutMs: Int
            public var maxOutputBytes: Int
            public var failurePolicy: String

            public init(
                enabled: Bool = false,
                command: String = "",
                arguments: [String] = [],
                timeoutMs: Int = 2_000,
                maxOutputBytes: Int = 65_536,
                failurePolicy: String = "block"
            ) {
                self.enabled = enabled
                self.command = command
                self.arguments = arguments
                self.timeoutMs = timeoutMs
                self.maxOutputBytes = maxOutputBytes
                self.failurePolicy = failurePolicy
            }
        }

        public var preTools: PreTools

        public init(preTools: PreTools = PreTools()) {
            self.preTools = preTools
        }
    }

    public struct Compactor: Codable, Sendable {
        public struct Level: Codable, Sendable, Identifiable {
            public var id: String { level }
            public var level: String
            public var utilizationThreshold: Double
            public var targetReductionPercent: Int
            public var preserveRecentMessages: Int
            public var preserveRecentTokens: Int

            public init(
                level: String,
                utilizationThreshold: Double,
                targetReductionPercent: Int,
                preserveRecentMessages: Int = 8,
                preserveRecentTokens: Int = 2_000
            ) {
                self.level = level
                self.utilizationThreshold = utilizationThreshold
                self.targetReductionPercent = targetReductionPercent
                self.preserveRecentMessages = preserveRecentMessages
                self.preserveRecentTokens = preserveRecentTokens
            }
        }

        public struct Retry: Codable, Sendable {
            public var maxAttempts: Int
            public var initialBackoffMs: Int
            public var multiplier: Double
            public var maxBackoffMs: Int

            public init(
                maxAttempts: Int = 3,
                initialBackoffMs: Int = 250,
                multiplier: Double = 2.0,
                maxBackoffMs: Int = 2_000
            ) {
                self.maxAttempts = maxAttempts
                self.initialBackoffMs = initialBackoffMs
                self.multiplier = multiplier
                self.maxBackoffMs = maxBackoffMs
            }
        }

        public var enabled: Bool
        public var contextWindowTokens: Int
        public var levels: [Level]
        public var retry: Retry

        public init(
            enabled: Bool = true,
            contextWindowTokens: Int = 32_000,
            levels: [Level] = [
                Level(level: "soft", utilizationThreshold: 0.8, targetReductionPercent: 30),
                Level(level: "aggressive", utilizationThreshold: 0.85, targetReductionPercent: 50),
                Level(level: "emergency", utilizationThreshold: 0.95, targetReductionPercent: 70),
            ],
            retry: Retry = Retry()
        ) {
            self.enabled = enabled
            self.contextWindowTokens = contextWindowTokens
            self.levels = levels
            self.retry = retry
        }
    }

    public struct Visor: Codable, Sendable {
        public struct Scheduler: Codable, Sendable {
            public var enabled: Bool
            public var intervalSeconds: Int
            public var jitterSeconds: Int

            public init(enabled: Bool = true, intervalSeconds: Int = 300, jitterSeconds: Int = 60) {
                self.enabled = enabled
                self.intervalSeconds = intervalSeconds
                self.jitterSeconds = jitterSeconds
            }
        }

        public var scheduler: Scheduler
        public var tickIntervalSeconds: Int
        /// Legacy config field; worker age no longer triggers cancellation.
        public var workerTimeoutSeconds: Int
        public var branchTimeoutSeconds: Int
        public var idleThresholdSeconds: Int
        public var mergeEnabled: Bool

        public init(
            scheduler: Scheduler = Scheduler(),
            tickIntervalSeconds: Int = 30,
            workerTimeoutSeconds: Int = 600,
            branchTimeoutSeconds: Int = 60,
            idleThresholdSeconds: Int = 1800,
            mergeEnabled: Bool = false
        ) {
            self.scheduler = scheduler
            self.tickIntervalSeconds = tickIntervalSeconds
            self.workerTimeoutSeconds = workerTimeoutSeconds
            self.branchTimeoutSeconds = branchTimeoutSeconds
            self.idleThresholdSeconds = idleThresholdSeconds
            self.mergeEnabled = mergeEnabled
        }

        private enum CodingKeys: String, CodingKey {
            case scheduler, tickIntervalSeconds, workerTimeoutSeconds, branchTimeoutSeconds, idleThresholdSeconds, mergeEnabled
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            scheduler = try container.decodeIfPresent(Scheduler.self, forKey: .scheduler) ?? Scheduler()
            tickIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .tickIntervalSeconds) ?? 30
            workerTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .workerTimeoutSeconds) ?? 600
            branchTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .branchTimeoutSeconds) ?? 60
            idleThresholdSeconds = try container.decodeIfPresent(Int.self, forKey: .idleThresholdSeconds) ?? 1800
            mergeEnabled = try container.decodeIfPresent(Bool.self, forKey: .mergeEnabled) ?? false
        }
    }

    public struct GitSync: Codable, Sendable {
        public struct Schedule: Codable, Sendable {
            public var frequency: String
            public var time: String

            public init(frequency: String = "daily", time: String = "18:00") {
                self.frequency = frequency
                self.time = time
            }
        }

        public var enabled: Bool
        public var authToken: String
        public var repository: String
        public var branch: String
        public var schedule: Schedule
        public var conflictStrategy: String

        public init(enabled: Bool = false, authToken: String = "", repository: String = "", branch: String = "main", schedule: Schedule = Schedule(), conflictStrategy: String = "remote_wins") {
            self.enabled = enabled
            self.authToken = authToken
            self.repository = repository
            self.branch = branch
            self.schedule = schedule
            self.conflictStrategy = conflictStrategy
        }

        private enum CodingKeys: String, CodingKey {
            case enabled, authToken, repository, branch, schedule, conflictStrategy
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            authToken = try container.decodeIfPresent(String.self, forKey: .authToken) ?? ""
            repository = try container.decodeIfPresent(String.self, forKey: .repository) ?? ""
            branch = try container.decodeIfPresent(String.self, forKey: .branch) ?? "main"
            schedule = try container.decodeIfPresent(Schedule.self, forKey: .schedule) ?? Schedule()
            conflictStrategy = try container.decodeIfPresent(String.self, forKey: .conflictStrategy) ?? "remote_wins"
        }
    }

    public struct ACP: Codable, Sendable {
        public var enabled: Bool
        public var targets: [ACPTarget]

        public init(enabled: Bool = false, targets: [ACPTarget] = []) {
            self.enabled = enabled
            self.targets = targets
        }

        private enum CodingKeys: String, CodingKey {
            case enabled, targets
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            targets = try container.decodeIfPresent([ACPTarget].self, forKey: .targets) ?? []
        }
    }

    public struct ACPTarget: Codable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var command: String
        public var enabled: Bool

        public init(id: String, title: String, command: String, enabled: Bool = true) {
            self.id = id
            self.title = title
            self.command = command
            self.enabled = enabled
        }

        private enum CodingKeys: String, CodingKey {
            case id, title, command, enabled
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            title = try container.decodeIfPresent(String.self, forKey: .title) ?? id
            command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        }
    }

    public var listen: Listen
    public var workspace: Workspace
    public var auth: Auth
    public var onboarding: Onboarding
    public var models: [ModelConfig]
    public var semanticDecisions: SemanticDecisions
    public var memory: Memory
    public var nodes: [Node]
    public var plugins: [PluginConfig]
    public var channels: ChannelConfig
    public var searchTools: SearchTools
    public var browser: Browser
    public var proxy: Proxy
    public var mcp: MCP
    public var visor: Visor
    public var gitSync: GitSync
    public var acp: ACP
    public var ui: UI
    public var tui: TUI
    public var toolHooks: ToolHooks
    public struct ExperimentalFlags: Codable, Sendable, Equatable {
        public var disableToolBudgetAndLoopGuard: Bool
        public var toolBudgetEnabled: Bool

        public init(disableToolBudgetAndLoopGuard: Bool = true, toolBudgetEnabled: Bool = false) {
            self.disableToolBudgetAndLoopGuard = disableToolBudgetAndLoopGuard
            self.toolBudgetEnabled = toolBudgetEnabled
        }

        enum CodingKeys: String, CodingKey {
            case disableToolBudgetAndLoopGuard
            case toolBudgetEnabled
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            disableToolBudgetAndLoopGuard = try container.decodeIfPresent(Bool.self, forKey: .disableToolBudgetAndLoopGuard) ?? true
            toolBudgetEnabled = try container.decodeIfPresent(Bool.self, forKey: .toolBudgetEnabled) ?? false
        }
    }

    public var experimentalFlags: ExperimentalFlags
    public var toolBudgetExhausted: Int
    public var modelRouting: [String: String]
    public var compactor: Compactor
    public var sqlitePath: String

    public init(
        listen: Listen = Listen(),
        workspace: Workspace = Workspace(),
        auth: Auth = Auth(),
        onboarding: Onboarding = Onboarding(),
        models: [ModelConfig] = [],
        semanticDecisions: SemanticDecisions = SemanticDecisions(),
        memory: Memory = Memory(),
        nodes: [Node] = [Node(id: "local", title: "Local", kind: "local")],
        plugins: [PluginConfig] = [],
        channels: ChannelConfig = ChannelConfig(),
        searchTools: SearchTools = SearchTools(),
        browser: Browser = Browser(),
        proxy: Proxy = Proxy(),
        mcp: MCP = MCP(),
        visor: Visor = Visor(),
        gitSync: GitSync = GitSync(),
        acp: ACP = ACP(),
        ui: UI = UI(),
        tui: TUI = TUI(),
        toolHooks: ToolHooks = ToolHooks(),
        experimentalFlags: ExperimentalFlags = ExperimentalFlags(),
        toolBudgetExhausted: Int = 60,
        modelRouting: [String: String] = [:],
        compactor: Compactor = Compactor(),
        sqlitePath: String = "memory/core.sqlite"
    ) {
        self.listen = listen
        self.workspace = workspace
        self.auth = auth
        self.onboarding = onboarding
        self.models = models
        self.semanticDecisions = semanticDecisions
        self.memory = memory
        self.nodes = nodes
        self.plugins = plugins
        self.channels = channels
        self.searchTools = searchTools
        self.browser = browser
        self.proxy = proxy
        self.mcp = mcp
        self.visor = visor
        self.gitSync = gitSync
        self.acp = acp
        self.ui = ui
        self.tui = tui
        self.toolHooks = toolHooks
        self.experimentalFlags = experimentalFlags
        self.toolBudgetExhausted = toolBudgetExhausted
        self.modelRouting = modelRouting
        self.compactor = compactor
        self.sqlitePath = sqlitePath
    }

    private enum CodingKeys: String, CodingKey {
        case listen, workspace, auth, onboarding, models, semanticDecisions, memory, nodes, plugins, channels, searchTools, browser, proxy, mcp, visor, gitSync, acp, ui, tui, toolHooks, experimentalFlags, toolBudgetExhausted, modelRouting, compactor, sqlitePath
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case toolBudgetEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        listen = try container.decode(Listen.self, forKey: .listen)
        workspace = try container.decodeIfPresent(Workspace.self, forKey: .workspace) ?? Workspace()
        auth = try container.decode(Auth.self, forKey: .auth)
        onboarding = try container.decodeIfPresent(Onboarding.self, forKey: .onboarding) ?? Onboarding()
        models = try container.decodeIfPresent([ModelConfig].self, forKey: .models) ?? []
        semanticDecisions = try container.decodeIfPresent(SemanticDecisions.self, forKey: .semanticDecisions) ?? SemanticDecisions()
        memory = try container.decode(Memory.self, forKey: .memory)
        nodes = try container.decodeIfPresent([Node].self, forKey: .nodes) ?? []
        plugins = try container.decodeIfPresent([PluginConfig].self, forKey: .plugins) ?? []
        channels = try container.decodeIfPresent(ChannelConfig.self, forKey: .channels) ?? ChannelConfig()
        searchTools = try container.decodeIfPresent(SearchTools.self, forKey: .searchTools) ?? SearchTools()
        browser = try container.decodeIfPresent(Browser.self, forKey: .browser) ?? Browser()
        proxy = try container.decodeIfPresent(Proxy.self, forKey: .proxy) ?? Proxy()
        mcp = try container.decodeIfPresent(MCP.self, forKey: .mcp) ?? MCP()
        visor = try container.decodeIfPresent(Visor.self, forKey: .visor) ?? Visor()
        gitSync = try container.decodeIfPresent(GitSync.self, forKey: .gitSync) ?? GitSync()
        acp = try container.decodeIfPresent(ACP.self, forKey: .acp) ?? ACP()
        ui = try container.decodeIfPresent(UI.self, forKey: .ui) ?? UI()
        tui = try container.decodeIfPresent(TUI.self, forKey: .tui) ?? TUI()
        toolHooks = try container.decodeIfPresent(ToolHooks.self, forKey: .toolHooks) ?? ToolHooks()
        experimentalFlags = try container.decodeIfPresent(ExperimentalFlags.self, forKey: .experimentalFlags) ?? .init()
        let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
        if let legacyToolBudgetEnabled = try legacyContainer.decodeIfPresent(Bool.self, forKey: .toolBudgetEnabled) {
            let hasNestedBudget: Bool
            if container.contains(.experimentalFlags) {
                let flags = try container.nestedContainer(keyedBy: ExperimentalFlags.CodingKeys.self, forKey: .experimentalFlags)
                hasNestedBudget = flags.contains(.toolBudgetEnabled)
            } else {
                hasNestedBudget = false
            }
            if !hasNestedBudget {
                experimentalFlags.toolBudgetEnabled = legacyToolBudgetEnabled
            }
        }
        toolBudgetExhausted = try container.decodeIfPresent(Int.self, forKey: .toolBudgetExhausted) ?? 60
        modelRouting = try container.decodeIfPresent([String: String].self, forKey: .modelRouting) ?? [:]
        compactor = try container.decodeIfPresent(Compactor.self, forKey: .compactor) ?? Compactor()
        sqlitePath = try container.decodeIfPresent(String.self, forKey: .sqlitePath) ?? "memory/core.sqlite"
    }
}

public extension URL {
    static let debugURL = URL(string: "http://localhost:25101")!
}
