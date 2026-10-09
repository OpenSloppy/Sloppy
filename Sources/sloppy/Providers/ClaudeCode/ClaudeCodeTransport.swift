import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import AnyLanguageModel
import PluginSDK
import Protocols

struct ClaudeCodeTransport: Sendable {
    var environment: [String: String] = ProcessInfo.processInfo.environment
    var proxy: CoreConfig.Proxy? = nil
    var timeout: Double = 300
    var fixtureTransport: ClaudeCodeAdmission.FixtureTransport? = nil

    static let modelCatalog: [ProviderModelOption] = [
        .init(id: "sonnet", title: "Claude Sonnet", contextWindow: "200K", capabilities: ["tools", "vision", "reasoning"]),
        .init(id: "opus", title: "Claude Opus", contextWindow: "200K", capabilities: ["tools", "vision", "reasoning"]),
        .init(id: "haiku", title: "Claude Haiku", contextWindow: "200K", capabilities: ["tools", "vision"]),
    ]

    func resolvedExecutable(fileManager: FileManager = .default) throws -> String {
        if let override = environment["SLOPPY_CLAUDE_CODE_COMMAND"], !override.isEmpty {
            guard fileManager.isExecutableFile(atPath: override) else { throw ClaudeCodeError.missingCLI }
            return override
        }
        let home = CoreConfig.resolvedHomeDirectoryPath(environment: environment)
        let directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["\(home)/.local/bin", "\(home)/.claude/local", "\(home)/.npm-global/bin", "\(home)/.bun/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        for directory in directories where directory.hasPrefix("/") {
            let path = URL(fileURLWithPath: directory).appendingPathComponent("claude").path
            if fileManager.isExecutableFile(atPath: path) { return path }
        }
        throw ClaudeCodeError.missingCLI
    }

    func nativeEnvironment() throws -> [String: String] {
        let auth = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "ANTHROPIC_FOUNDRY_API_KEY"]
        let backends = ["CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"]
        let conflicts = auth.filter { !(environment[$0] ?? "").isEmpty } + backends.filter {
            !["", "0", "false", "no", "off"].contains((environment[$0] ?? "").lowercased())
        }
        guard conflicts.isEmpty else { throw ClaudeCodeError.conflictingEnvironment(conflicts) }
        var env = environment
        if let directory = env["SLOPPY_CLAUDE_CODE_CONFIG_DIR"], !directory.isEmpty { env["CLAUDE_CONFIG_DIR"] = directory }
        for key in ["CLAUDE_CODE_EXTRA_BODY", "CLAUDE_CODE_EFFORT_LEVEL", "CLAUDECODE"] { env.removeValue(forKey: key) }
        env["CLAUDE_CODE_MAX_RETRIES"] = "0"
        env["ENABLE_TOOL_SEARCH"] = "false"
        env["DISABLE_AUTO_COMPACT"] = "1"
        env["DISABLE_COMPACT"] = "1"
        env["DISABLE_AUTOUPDATER"] = "1"
        return env
    }

    func status(timeout: Duration = .seconds(10)) async throws {
        let executable = try resolvedExecutable()
        let environment = try nativeEnvironment()
        let child = ClaudeCodeProcess()
        let directory = try makeDirectory()
        let workingDirectory = try ClaudeCodeWorkingDirectory.shared.directory.get()
        defer { child.cancel(); try? FileManager.default.removeItem(at: directory) }
        let events = try child.start(executable: executable, arguments: ["auth", "status", "--json"],
                                     environment: environment, cwd: workingDirectory, singleJSON: true)
        child.closeInput()
        let deadline = ContinuousClock.now.advanced(by: timeout)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    for try await event in events {
                        guard ContinuousClock.now < deadline else { throw ClaudeCodeError.timeout }
                        guard event[claude: "loggedIn"] == .bool(true),
                              ["claudeai", "oauth_token"].contains(event[claude: "authMethod"].claudeString ?? ""),
                              event[claude: "apiProvider"].claudeString == "firstParty" else { throw ClaudeCodeError.loggedOut }
                        return
                    }
                    throw ClaudeCodeError.loggedOut
                } onCancel: { child.cancel() }
            }
            group.addTask { try await ContinuousClock().sleep(until: deadline); throw ClaudeCodeError.timeout }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    func generate(model: String, history: ClaudeCodeHistory, extraBody: [String: JSONValue], effort: String?,
                  onText: (@Sendable (String) -> Void)? = nil, usageContext: ModelUsageContext? = nil) async throws -> ClaudeCodeResponse {
        let executable = try resolvedExecutable()
        var env = try nativeEnvironment()
        let directory = try makeDirectory()
        let workingDirectory = try ClaudeCodeWorkingDirectory.shared.directory.get()
        let child = ClaudeCodeProcess()
        let configuration = ProxySessionFactory.makeSession(proxy: proxy ?? CoreConfig.Proxy()).configuration
        let http = URLSession(configuration: configuration, delegate: ClaudeCodeNoRedirectDelegate(), delegateQueue: nil)
        let admission = ClaudeCodeAdmission(session: http, fixtureTransport: fixtureTransport, onText: onText)
        do {
            let localURL = try await admission.start()
            env["ANTHROPIC_BASE_URL"] = localURL.absoluteString
            env["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] = String(extraBody["max_tokens"]?.claudeInt ?? 4096)
            let systemFile = directory.appendingPathComponent("system.md")
            let settingsFile = directory.appendingPathComponent("settings.json")
            try Data(history.system.utf8).write(to: systemFile)
            let body = String(decoding: try JSONEncoder().encode(extraBody), as: UTF8.self)
            try JSONEncoder().encode(JSONValue.object(["env": .object(["CLAUDE_CODE_EXTRA_BODY": .string(body)])])).write(to: settingsFile)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: systemFile.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsFile.path)
            var args = ["-p", "--model", model, "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                        "--include-partial-messages", "--tools", "", "--system-prompt-file", systemFile.path,
                        "--settings", settingsFile.path, "--setting-sources", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
                        "--disable-slash-commands", "--max-turns", "1", "--permission-mode", "dontAsk", "--no-session-persistence", "--no-chrome"]
            if let effort { args += ["--effort", effort] }
            let events = try child.start(executable: executable, arguments: args, environment: env, cwd: workingDirectory)
            let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
            let response = try await withThrowingTaskGroup(of: ClaudeCodeResponse.self) { group in
                group.addTask { try await admission.waitForResult() }
                group.addTask {
                    try await withTaskCancellationHandler {
                        var iterator = events.makeAsyncIterator()
                        for (index, message) in history.messages.enumerated() {
                            let role = message[claude: "role"].claudeString ?? ""
                            var frame: [String: JSONValue] = ["type": .string(role), "message": message]
                            let replay = role == "user" && index < history.messages.count - 1
                            if replay { frame["shouldQuery"] = .bool(false) }
                            if index == history.messages.count - 1 { await admission.allowGeneration() }
                            try await child.write(.object(frame))
                            if replay {
                                var acknowledged = false
                                while let event = try await iterator.next() {
                                    if event[claude: "type"].claudeString == "result" {
                                        guard event[claude: "num_turns"] == .number(0), event[claude: "is_error"] != .bool(true) else {
                                            throw ClaudeCodeError.unsupportedReplay
                                        }
                                        acknowledged = true
                                        break
                                    }
                                }
                                guard acknowledged else { throw ClaudeCodeError.unsupportedReplay }
                            }
                        }
                        child.closeInput()
                        var nativeCode = "no_admitted_response"
                        while let event = try await iterator.next() {
                            if let code = event[claude: "error"].claudeString { nativeCode = code }
                        }
                        guard ContinuousClock.now < deadline else { throw ClaudeCodeError.timeout }
                        if let response = await admission.resultIfComplete() { return response }
                        throw ClaudeCodeError.nativeFailure(nativeCode)
                    } onCancel: { child.cancel() }
                }
                group.addTask { try await ContinuousClock().sleep(until: deadline); throw ClaudeCodeError.timeout }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw ClaudeCodeError.invalidStream }
                guard ContinuousClock.now < deadline else { throw ClaudeCodeError.timeout }
                return result
            }
            child.cancel()
            await recordUsage(admission, context: usageContext, failed: false)
            await admission.stop()
            try? FileManager.default.removeItem(at: directory)
            return response
        } catch {
            child.cancel()
            await recordUsage(admission, context: usageContext, failed: true)
            await admission.stop()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func recordUsage(_ admission: ClaudeCodeAdmission, context: ModelUsageContext?, failed: Bool) async {
        guard let context, let body = await admission.requestBody else { return }
        let response = await admission.responseBody
        let record = await UsageWireDecoder(context: context).record(requestId: admission.requestID, body: body,
            response: response, createdAt: admission.createdAt, failed: failed, truncated: failed)
        await context.onRequest(record)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sloppy-claude-code-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory
    }
}

/// A stable, private cwd keeps the CLI's environment prefix cacheable. Request
/// files live separately and are removed after every request.
private final class ClaudeCodeWorkingDirectory: Sendable {
    static let shared = ClaudeCodeWorkingDirectory()
    let directory: Result<URL, Error>
    private init() {
        directory = Result {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("sloppy-claude-code-cwd-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            return url
        }
    }
    deinit { if let url = try? directory.get() { try? FileManager.default.removeItem(at: url) } }
}
