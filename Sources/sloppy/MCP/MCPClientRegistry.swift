import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Logging
import MCP
import Protocols
#if canImport(System)
import System
#else
@preconcurrency import SystemPackage
#endif

enum MCPRegistryError: Error, LocalizedError {
    case unknownServer(String)
    case disabledServer(String)
    case invalidConfiguration(String)
    case invalidResult(String)

    var errorDescription: String? {
        switch self {
        case .unknownServer(let serverID):
            return "Unknown MCP server '\(serverID)'."
        case .disabledServer(let serverID):
            return "MCP server '\(serverID)' is disabled."
        case .invalidConfiguration(let message):
            return message
        case .invalidResult(let message):
            return message
        }
    }
}

struct MCPServerSummary: Sendable {
    let id: String
    let transport: String
    let enabled: Bool
    let exposeTools: Bool
    let exposeResources: Bool
    let exposePrompts: Bool
    let toolPrefix: String?
}

struct MCPServerStatus: Encodable, Sendable {
    let id: String
    let transport: String
    let enabled: Bool
    let connected: Bool
    let exposeTools: Bool
    let exposeResources: Bool
    let exposePrompts: Bool
    let toolPrefix: String?
    let message: String?
}

struct MCPDynamicTool: Sendable {
    let id: String
    let serverID: String
    let toolName: String
    let title: String
    let description: String
    let inputSchema: JSONValue
    let readOnlyHint: Bool

    init(id: String, serverID: String, toolName: String, title: String, description: String, inputSchema: JSONValue, readOnlyHint: Bool = false) {
        self.id = id
        self.serverID = serverID
        self.toolName = toolName
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.readOnlyHint = readOnlyHint
    }
}

private final class DiscoveryTimeoutBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var tasks: [Task<Void, Never>] = []
    private var completed = false

    func setContinuation(_ continuation: CheckedContinuation<T, any Error>) {
        lock.lock()
        if completed {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func setTasks(_ tasks: [Task<Void, Never>]) {
        lock.lock()
        if completed {
            lock.unlock()
            tasks.forEach { $0.cancel() }
            return
        }
        self.tasks = tasks
        lock.unlock()
    }

    func resume(_ result: Result<T, any Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuation = self.continuation
        let tasks = self.tasks
        self.continuation = nil
        self.tasks = []
        lock.unlock()

        tasks.forEach { $0.cancel() }
        switch result {
        case .success(let value):
            continuation?.resume(returning: value)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }

    func cancel() {
        resume(.failure(CancellationError()))
    }
}

actor ManagedMCPStdioTransport: Transport {
    nonisolated let logger: Logging.Logger

    private let command: String
    private let arguments: [String]
    private let cwd: String?
    private let configuredEnvironment: [String: String]
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var innerTransport: StdioTransport?
    private var relayTask: Task<Void, Never>?
    private let messageStream: AsyncThrowingStream<Data, Error>
    private let messageContinuation: AsyncThrowingStream<Data, Error>.Continuation

    init(command: String, arguments: [String], cwd: String?, environment: [String: String] = [:], logger: Logging.Logger) {
        self.command = command
        self.arguments = arguments
        self.cwd = cwd
        self.configuredEnvironment = environment
        self.logger = logger
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        self.messageStream = AsyncThrowingStream { continuation = $0 }
        self.messageContinuation = continuation
    }

    func connect() async throws {
        guard innerTransport == nil else {
            return
        }

        let environment = childProcessEnvironment()
        let inputPipe = try makeProcessInputPipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let process = Process()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        if command.hasPrefix("/") || command.hasPrefix(".") || command.contains("/") {
            let executableURL = resolveCommandURL(command, cwd: cwd)
            guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
                throw MCPRegistryError.invalidConfiguration("Command not found: \(command)")
            }
            process.executableURL = executableURL
            process.arguments = arguments
        } else {
            guard let executablePath = findExecutable(command, environment: environment) else {
                throw MCPRegistryError.invalidConfiguration("Command not found: \(command)")
            }
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
        }

        if let cwd,
           !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        }

        process.environment = environment.merging(configuredEnvironment) { _, configured in configured }

        do {
            try process.run()
        } catch {
            throw MCPRegistryError.invalidConfiguration(
                "Failed to start MCP command '\(command)': \(error.localizedDescription)"
            )
        }

        let transport = StdioTransport(
            input: FileDescriptor(rawValue: outputPipe.fileHandleForReading.fileDescriptor),
            output: FileDescriptor(rawValue: inputPipe.fileHandleForWriting.fileDescriptor),
            logger: logger
        )
        try await transport.connect()

        self.process = process
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        self.innerTransport = transport
        self.relayTask = Task { [weak self] in
            let stream = await transport.receive()
            do {
                for try await data in stream {
                    await self?.yieldMessage(data)
                }
                await self?.finishMessages()
            } catch {
                await self?.finishMessages()
            }
        }
    }

    func disconnect() async {
        relayTask?.cancel()
        relayTask = nil
        if let innerTransport {
            await innerTransport.disconnect()
        }

        if let process, process.isRunning {
            process.terminate()
        }

        self.process = nil
        self.inputPipe = nil
        self.outputPipe = nil
        self.errorPipe = nil
        self.innerTransport = nil
        messageContinuation.finish()
    }

    func send(_ data: Data) async throws {
        guard let innerTransport else {
            throw MCPRegistryError.invalidConfiguration("MCP stdio transport is not connected.")
        }
        try await innerTransport.send(data)
    }

    func receive() -> AsyncThrowingStream<Data, Error> {
        messageStream
    }

    private func yieldMessage(_ data: Data) {
        messageContinuation.yield(data)
    }

    private func finishMessages() {
        // The SDK reconnects after a clean stream end. Stdio EOF is terminal;
        // throwing prevents it from spinning on this already-finished stream.
        messageContinuation.finish(throwing: MCPRegistryError.invalidResult("MCP server closed its output stream."))
    }

    private func resolveCommandURL(_ command: String, cwd: String?) -> URL {
        if command.hasPrefix("/") {
            return URL(fileURLWithPath: command)
        }
        let base = cwd?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? cwd!
            : FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent(command)
    }

    private func findExecutable(_ command: String, environment: [String: String]) -> String? {
        let path = environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                .appendingPathComponent(command)
                .path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}

actor MCPServerConnection {
    private let config: CoreConfig.MCP.Server
    private let logger: Logging.Logger
    private var client: Client?
    private var transport: (any Transport)?
    private var pendingClient: Client?
    private var connectionTask: Task<Client, any Error>?

    init(config: CoreConfig.MCP.Server, logger: Logging.Logger) {
        self.config = config
        self.logger = logger
    }

    func disconnect() async {
        let clientToDisconnect = client ?? pendingClient
        let transportToDisconnect = transport
        connectionTask?.cancel()
        connectionTask = nil
        client = nil
        pendingClient = nil
        transport = nil
        if let clientToDisconnect {
            await clientToDisconnect.disconnect()
        } else if let transportToDisconnect {
            await transportToDisconnect.disconnect()
        }
    }

    func listTools(cursor: String? = nil) async throws -> (tools: [MCP.Tool], nextCursor: String?) {
        let client = try await ensureClient()
        return try await client.listTools(cursor: cursor)
    }

    func callTool(name: String, arguments: [String: Value]?) async throws -> (content: [MCP.Tool.Content], isError: Bool?) {
        let client = try await ensureClient()
        return try await client.callTool(name: name, arguments: arguments)
    }

    func listResources(cursor: String? = nil) async throws -> (resources: [Resource], nextCursor: String?) {
        let client = try await ensureClient()
        return try await client.listResources(cursor: cursor)
    }

    func readResource(uri: String) async throws -> [Resource.Content] {
        let client = try await ensureClient()
        return try await client.readResource(uri: uri)
    }

    func listPrompts(cursor: String? = nil) async throws -> (prompts: [Prompt], nextCursor: String?) {
        let client = try await ensureClient()
        return try await client.listPrompts(cursor: cursor)
    }

    func getPrompt(name: String, arguments: [String: String]?) async throws -> (description: String?, messages: [Prompt.Message]) {
        let client = try await ensureClient()
        return try await client.getPrompt(name: name, arguments: arguments)
    }

    func probe() async throws {
        _ = try await ensureClient()
    }

    private func ensureClient() async throws -> Client {
        if let client { return client }
        if let connectionTask { return try await connectionTask.value }

        let transport = try makeTransport()
        let candidate = Client(name: "sloppy", version: "1.0.0", capabilities: .init())
        pendingClient = candidate
        self.transport = transport
        let task = Task {
            do {
                _ = try await candidate.connect(transport: transport)
                try Task.checkCancellation()
                return candidate
            } catch {
                await candidate.disconnect()
                throw error
            }
        }
        connectionTask = task
        do {
            let connected = try await task.value
            guard pendingClient === candidate else { throw CancellationError() }
            client = connected
            pendingClient = nil
            connectionTask = nil
            return connected
        } catch {
            if pendingClient === candidate {
                pendingClient = nil
                connectionTask = nil
                self.transport = nil
            }
            throw error
        }
    }

    private func makeTransport() throws -> any Transport {
        switch config.transport {
        case .stdio:
            let command = config.command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !command.isEmpty else {
                throw MCPRegistryError.invalidConfiguration("MCP server '\(config.id)' uses stdio but command is missing.")
            }
            return ManagedMCPStdioTransport(
                command: command,
                arguments: config.arguments,
                cwd: config.cwd,
                environment: config.environment,
                logger: logger
            )
        case .http:
            let endpointRaw = config.endpoint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let endpoint = URL(string: endpointRaw), !endpointRaw.isEmpty else {
                throw MCPRegistryError.invalidConfiguration("MCP server '\(config.id)' uses http but endpoint is missing.")
            }
            let sessionConfiguration = URLSessionConfiguration.default
            sessionConfiguration.timeoutIntervalForRequest = TimeInterval(max(config.timeoutMs, 250)) / 1_000
            let headers = config.headers
            return HTTPClientTransport(
                endpoint: endpoint,
                configuration: sessionConfiguration,
                streaming: true,
                requestModifier: { request in
                    var request = request
                    for (name, value) in headers {
                        request.setValue(value, forHTTPHeaderField: name)
                    }
                    return request
                },
                logger: logger
            )
        }
    }
}

actor MCPClientRegistry {
    private static let failedDiscoveryRetryInterval: TimeInterval = 30

    private var config: CoreConfig.MCP
    private let logger: Logging.Logger
    private var connections: [String: MCPServerConnection] = [:]
    private var dynamicToolsByID: [String: MCPDynamicTool] = [:]
    private var dynamicDiscoveryLoaded = false
    private var dynamicDiscoveryLastFailureAt: Date?

    init(config: CoreConfig.MCP, logger: Logging.Logger = Logging.Logger.sloppy(label: "sloppy.mcp")) {
        self.config = config
        self.logger = logger
    }

    func updateConfig(_ config: CoreConfig.MCP) async {
        let nextIDs = Set(config.servers.map(\.id))
        let obsolete = connections.keys.filter { !nextIDs.contains($0) }
        for serverID in obsolete {
            if let connection = connections.removeValue(forKey: serverID) {
                await connection.disconnect()
            }
        }
        self.config = config
        self.dynamicToolsByID = [:]
        self.dynamicDiscoveryLoaded = false
        self.dynamicDiscoveryLastFailureAt = nil
    }

    func listServers() -> [MCPServerSummary] {
        config.servers.map { server in
            MCPServerSummary(
                id: server.id,
                transport: server.transport.rawValue,
                enabled: server.enabled,
                exposeTools: server.exposeTools,
                exposeResources: server.exposeResources,
                exposePrompts: server.exposePrompts,
                toolPrefix: server.toolPrefix
            )
        }
    }

    func serverStatuses() async -> [MCPServerStatus] {
        var statuses: [MCPServerStatus] = []
        statuses.reserveCapacity(config.servers.count)

        for server in config.servers {
            guard server.enabled else {
                statuses.append(
                    MCPServerStatus(
                        id: server.id,
                        transport: server.transport.rawValue,
                        enabled: false,
                        connected: false,
                        exposeTools: server.exposeTools,
                        exposeResources: server.exposeResources,
                        exposePrompts: server.exposePrompts,
                        toolPrefix: server.toolPrefix,
                        message: "disabled"
                    )
                )
                continue
            }

            do {
                let connection = try connection(for: server.id)
                try await withDiscoveryTimeout(milliseconds: max(250, server.timeoutMs)) {
                    try await connection.probe()
                }
                statuses.append(
                    MCPServerStatus(
                        id: server.id,
                        transport: server.transport.rawValue,
                        enabled: true,
                        connected: true,
                        exposeTools: server.exposeTools,
                        exposeResources: server.exposeResources,
                        exposePrompts: server.exposePrompts,
                        toolPrefix: server.toolPrefix,
                        message: nil
                    )
                )
            } catch {
                await connections[server.id]?.disconnect()
                statuses.append(
                    MCPServerStatus(
                        id: server.id,
                        transport: server.transport.rawValue,
                        enabled: true,
                        connected: false,
                        exposeTools: server.exposeTools,
                        exposeResources: server.exposeResources,
                        exposePrompts: server.exposePrompts,
                        toolPrefix: server.toolPrefix,
                        message: String(describing: error)
                    )
                )
            }
        }

        return statuses
    }

    func listTools(serverID: String, cursor: String? = nil) async throws -> (tools: [MCP.Tool], nextCursor: String?) {
        let connection = try connection(for: serverID)
        return try await connection.listTools(cursor: cursor)
    }

    func callTool(serverID: String, name: String, arguments: [String: JSONValue]) async throws -> (content: [MCP.Tool.Content], isError: Bool?) {
        let connection = try connection(for: serverID)
        let convertedArguments = arguments.mapValues(Self.mcpValue(from:))
        return try await connection.callTool(name: name, arguments: convertedArguments)
    }

    func listResources(serverID: String, cursor: String? = nil) async throws -> (resources: [Resource], nextCursor: String?) {
        let connection = try connection(for: serverID)
        return try await connection.listResources(cursor: cursor)
    }

    func readResource(serverID: String, uri: String) async throws -> [Resource.Content] {
        let connection = try connection(for: serverID)
        return try await connection.readResource(uri: uri)
    }

    func listPrompts(serverID: String, cursor: String? = nil) async throws -> (prompts: [Prompt], nextCursor: String?) {
        let connection = try connection(for: serverID)
        return try await connection.listPrompts(cursor: cursor)
    }

    func getPrompt(serverID: String, name: String, arguments: [String: JSONValue]) async throws -> (description: String?, messages: [Prompt.Message]) {
        let connection = try connection(for: serverID)
        let convertedArguments = arguments.mapValues { jsonValue -> String in
            switch jsonValue {
            case .string(let s): return s
            case .number(let n): return String(n)
            case .bool(let b): return String(b)
            case .array(let arr): return arr.description
            case .object(let obj): return obj.description
            case .null: return ""
            }
        }
        return try await connection.getPrompt(name: name, arguments: convertedArguments)
    }

    func dynamicTools() async -> [MCPDynamicTool] {
        await refreshDynamicToolsIfNeeded()
        return dynamicToolsByID.values.sorted { $0.id < $1.id }
    }

    func dynamicToolIDs() async -> Set<String> {
        Set(await dynamicTools().map(\.id))
    }

    func isDynamicToolID(_ toolID: String) async -> Bool {
        await refreshDynamicToolsIfNeeded()
        return dynamicToolsByID[toolID] != nil
    }

    func dynamicTool(for toolID: String) async -> MCPDynamicTool? {
        await refreshDynamicToolsIfNeeded()
        return dynamicToolsByID[toolID]
    }

    func invokeDynamicTool(toolID: String, arguments: [String: JSONValue]) async throws -> ToolInvocationResult? {
        await refreshDynamicToolsIfNeeded()
        guard let dynamicTool = dynamicToolsByID[toolID] else {
            return nil
        }

        let result = try await callTool(
            serverID: dynamicTool.serverID,
            name: dynamicTool.toolName,
            arguments: arguments
        )
        let payload: JSONValue = .object([
            "server": .string(dynamicTool.serverID),
            "tool": .string(dynamicTool.toolName),
            "isError": result.isError.map(JSONValue.bool) ?? .null,
            "content": .array(result.content.map(Self.jsonValue(from:)))
        ])
        return ToolInvocationResult(
            tool: toolID,
            ok: result.isError != true,
            data: result.isError == true ? nil : payload,
            error: result.isError == true
                ? ToolErrorPayload(
                    code: "mcp_tool_error",
                    message: "MCP tool '\(dynamicTool.toolName)' on server '\(dynamicTool.serverID)' returned an error result.",
                    retryable: false
                )
                : nil
        )
    }

    func decodeJSONTextResult<T: Decodable>(serverID: String, toolName: String, arguments: [String: JSONValue], as type: T.Type) async throws -> T {
        let result = try await callTool(serverID: serverID, name: toolName, arguments: arguments)
        guard result.isError != true else {
            throw MCPRegistryError.invalidResult("MCP tool '\(toolName)' on server '\(serverID)' returned an error result.")
        }
        let textPayload = Self.flattenText(from: result.content)
        guard let data = textPayload.data(using: .utf8) else {
            throw MCPRegistryError.invalidResult("MCP tool '\(toolName)' on server '\(serverID)' returned empty text.")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func connection(for serverID: String) throws -> MCPServerConnection {
        guard let server = config.servers.first(where: { $0.id == serverID }) else {
            throw MCPRegistryError.unknownServer(serverID)
        }
        guard server.enabled else {
            throw MCPRegistryError.disabledServer(serverID)
        }
        if let existing = connections[serverID] {
            return existing
        }
        let connection = MCPServerConnection(
            config: server,
            logger: Logging.Logger.sloppy(label: "sloppy.mcp.\(serverID)")
        )
        connections[serverID] = connection
        return connection
    }

    private func refreshDynamicToolsIfNeeded() async {
        if dynamicDiscoveryLoaded {
            return
        }
        if let dynamicDiscoveryLastFailureAt,
           Date().timeIntervalSince(dynamicDiscoveryLastFailureAt) < Self.failedDiscoveryRetryInterval {
            return
        }

        var discovered: [String: MCPDynamicTool] = [:]
        var failedServers: [String] = []
        for server in config.servers where server.enabled && server.exposeTools {
            do {
                let response = try await withDiscoveryTimeout(milliseconds: max(250, server.timeoutMs)) {
                    try await self.listTools(serverID: server.id)
                }
                for tool in response.tools {
                    let toolID = Self.dynamicToolID(
                        serverID: server.id,
                        toolName: tool.name,
                        prefix: server.toolPrefix
                    )
                    discovered[toolID] = MCPDynamicTool(
                        id: toolID,
                        serverID: server.id,
                        toolName: tool.name,
                        title: tool.title ?? tool.name,
                        description: tool.description ?? "MCP tool from server '\(server.id)'",
                        inputSchema: Self.jsonValue(from: tool.inputSchema),
                        readOnlyHint: tool.annotations.readOnlyHint == true
                    )
                }
            } catch {
                failedServers.append(server.id)
                if let failedConnection = connections.removeValue(forKey: server.id) {
                    await failedConnection.disconnect()
                }
                logger.warning(
                    "Failed to discover MCP tools for server \(server.id): \(String(describing: error))"
                )
            }
        }
        if !discovered.isEmpty || failedServers.isEmpty {
            dynamicToolsByID = discovered
            dynamicDiscoveryLoaded = failedServers.isEmpty
            dynamicDiscoveryLastFailureAt = failedServers.isEmpty ? nil : Date()
        } else {
            dynamicDiscoveryLastFailureAt = Date()
        }
    }

    private func withDiscoveryTimeout<T: Sendable>(
        milliseconds: Int,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let box = DiscoveryTimeoutBox<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                box.setContinuation(continuation)
                let operationTask = Task {
                    do {
                        let value = try await operation()
                        box.resume(.success(value))
                    } catch {
                        box.resume(.failure(error))
                    }
                }
                let timeoutTask = Task {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(max(1, milliseconds)) * 1_000_000)
                        operationTask.cancel()
                        box.resume(.failure(MCPRegistryError.invalidResult("Timed out while discovering MCP tools.")))
                    } catch {
                        box.resume(.failure(error))
                    }
                }
                box.setTasks([operationTask, timeoutTask])
            }
        } onCancel: {
            box.cancel()
        }
    }

    static func dynamicToolID(serverID: String, toolName: String, prefix: String?) -> String {
        let base = prefix?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBase = (base?.isEmpty == false ? base! : "mcp.\(serverID)")
        return "\(normalizedBase).\(toolName)"
    }

    static func mcpValue(from value: JSONValue) -> Value {
        switch value {
        case .string(let string):
            return .string(string)
        case .number(let number):
            if number.rounded(.towardZero) == number {
                return .int(Int(number))
            }
            return .double(number)
        case .bool(let bool):
            return .bool(bool)
        case .object(let object):
            return .object(object.mapValues(mcpValue(from:)))
        case .array(let array):
            return .array(array.map(mcpValue(from:)))
        case .null:
            return .null
        }
    }

    static func jsonValue(from value: Value) -> JSONValue {
        switch value {
        case .null:
            return .null
        case .bool(let bool):
            return .bool(bool)
        case .int(let int):
            return .number(Double(int))
        case .double(let double):
            return .number(double)
        case .string(let string):
            return .string(string)
        case .data(let mimeType, let data):
            return .object([
                "mimeType": mimeType.map(JSONValue.string) ?? .null,
                "data": .string(data.base64EncodedString())
            ])
        case .array(let array):
            return .array(array.map(jsonValue(from:)))
        case .object(let object):
            return .object(object.mapValues(jsonValue(from:)))
        }
    }

    static func flattenText(from content: [MCP.Tool.Content]) -> String {
        content.compactMap { item -> String? in
            switch item {
            case .text(let text, _, _):
                return text
            case .resource(let resource, _, _):
                return resource.text
            default:
                return nil
            }
        }
        .joined(separator: "\n")
    }

    static func jsonValue(from tool: MCP.Tool) -> JSONValue {
        .object([
            "name": .string(tool.name),
            "title": tool.title.map(JSONValue.string) ?? .null,
            "description": tool.description.map(JSONValue.string) ?? .null,
            "inputSchema": jsonValue(from: tool.inputSchema),
            "outputSchema": tool.outputSchema.map(jsonValue(from:)) ?? .null,
            "annotations": .object([
                "title": tool.annotations.title.map(JSONValue.string) ?? .null,
                "readOnlyHint": tool.annotations.readOnlyHint.map(JSONValue.bool) ?? .null,
                "destructiveHint": tool.annotations.destructiveHint.map(JSONValue.bool) ?? .null,
                "idempotentHint": tool.annotations.idempotentHint.map(JSONValue.bool) ?? .null,
                "openWorldHint": tool.annotations.openWorldHint.map(JSONValue.bool) ?? .null
            ])
        ])
    }

    static func jsonValue(from resource: Resource) -> JSONValue {
        var dict: [String: JSONValue] = [
            "name": .string(resource.name),
            "uri": .string(resource.uri)
        ]
        if let title = resource.title {
            dict["title"] = .string(title)
        }
        if let description = resource.description {
            dict["description"] = .string(description)
        }
        if let mimeType = resource.mimeType {
            dict["mimeType"] = .string(mimeType)
        }
        var annotationsDict: [String: JSONValue] = [:]
        if let audience = resource.annotations?.audience {
            annotationsDict["audience"] = .array(audience.map { .string($0.rawValue) })
        }
        if let priority = resource.annotations?.priority {
            annotationsDict["priority"] = .number(priority)
        }
        if let lastModified = resource.annotations?.lastModified {
            annotationsDict["lastModified"] = .string(lastModified)
        }
        dict["annotations"] = .object(annotationsDict)
        if let meta = resource._meta {
            dict["_meta"] = jsonValue(from: meta)
        }
        return .object(dict)
    }

    static func jsonValue(from resourceContent: Resource.Content) -> JSONValue {
        .object([
            "uri": .string(resourceContent.uri),
            "mimeType": resourceContent.mimeType.map(JSONValue.string) ?? .null,
            "text": resourceContent.text.map(JSONValue.string) ?? .null,
            "blob": resourceContent.blob.map(JSONValue.string) ?? .null
        ])
    }

    static func jsonValue(from prompt: Prompt) -> JSONValue {
        .object([
            "name": .string(prompt.name),
            "title": prompt.title.map(JSONValue.string) ?? .null,
            "description": prompt.description.map(JSONValue.string) ?? .null,
            "arguments": .array((prompt.arguments ?? []).map { argument in
                .object([
                    "name": .string(argument.name),
                    "title": argument.title.map(JSONValue.string) ?? .null,
                    "description": argument.description.map(JSONValue.string) ?? .null,
                    "required": argument.required.map(JSONValue.bool) ?? .null
                ])
            })
        ])
    }

    static func jsonValue(from message: Prompt.Message) -> JSONValue {
        .object([
            "role": .string(message.role.rawValue),
            "content": jsonValue(from: message.content)
        ])
    }

    static func jsonValue(from content: Prompt.Message.Content) -> JSONValue {
        switch content {
        case .text(let text):
            return .object([
                "type": .string("text"),
                "text": .string(text)
            ])
        case .image(let data, let mimeType):
            return .object([
                "type": .string("image"),
                "data": .string(data),
                "mimeType": .string(mimeType)
            ])
        case .audio(let data, let mimeType):
            return .object([
                "type": .string("audio"),
                "data": .string(data),
                "mimeType": .string(mimeType)
            ])
        case .resource(let resource, _, _):
            return .object([
                "type": .string("resource"),
                "resource": jsonValue(from: resource)
            ])
        case .resourceLink(let uri, let name, let title, let description, let mimeType, _):
            return .object([
                "type": .string("resource_link"),
                "uri": .string(uri),
                "name": .string(name),
                "title": title.map(JSONValue.string) ?? .null,
                "description": description.map(JSONValue.string) ?? .null,
                "mimeType": mimeType.map(JSONValue.string) ?? .null
            ])
        }
    }

    static func jsonValue(from content: MCP.Tool.Content) -> JSONValue {
        switch content {
        case .text(let text, _, _):
            return .object([
                "type": .string("text"),
                "text": .string(text)
            ])
        case .image(let data, let mimeType, _, _):
            return .object([
                "type": .string("image"),
                "data": .string(data),
                "mimeType": .string(mimeType)
            ])
        case .audio(let data, let mimeType, _, _):
            return .object([
                "type": .string("audio"),
                "data": .string(data),
                "mimeType": .string(mimeType)
            ])
        case .resource(let resource, _, _):
            return .object([
                "type": .string("resource"),
                "resource": jsonValue(from: resource)
            ])
        case .resourceLink(let uri, let name, let title, let description, let mimeType, _):
            return .object([
                "type": .string("resource_link"),
                "uri": .string(uri),
                "name": .string(name),
                "title": title.map(JSONValue.string) ?? .null,
                "description": description.map(JSONValue.string) ?? .null,
                "mimeType": mimeType.map(JSONValue.string) ?? .null
            ])
        }
    }

    static func jsonValue(from metadata: Metadata) -> JSONValue {
        .object(metadata.fields.mapValues(jsonValue(from:)))
    }
}

extension MCPClientRegistry: MCPToolDiscovering {}
