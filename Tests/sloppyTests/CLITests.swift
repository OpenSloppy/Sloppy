import Foundation
import Testing
@testable import sloppy
import Protocols
import ArgumentParser

// MARK: - CLIStyle tests

@Test
func cliStyleColorDisabledWhenNoColor() {
    // CLIStyle.isColor is computed at init time from env; we test the helper functions
    // by checking that non-color output equals input when colors are stripped.
    let raw = "hello"
    let colored = CLIStyle.green(raw)
    // If color is enabled the output contains ANSI codes; if not it equals raw.
    // Either way it must contain the original string.
    #expect(colored.contains(raw))
}

@Test
func cliStyleBoldContainsInput() {
    #expect(CLIStyle.bold("test").contains("test"))
}

@Test
func cliStyleDimContainsInput() {
    #expect(CLIStyle.dim("info").contains("info"))
}

@Test
func cliStyleCyanBoldContainsInput() {
    #expect(CLIStyle.cyanBold("cmd").contains("cmd"))
}

@Test
func cliStyleRedBoldContainsInput() {
    #expect(CLIStyle.redBold("err").contains("err"))
}

@Test
func cliStyleWhiteBoldContainsInput() {
    #expect(CLIStyle.whiteBold("id-123").contains("id-123"))
}

@Test
func rootCommandDoesNotStartTUIWhenStdioIsNotInteractive() {
    #expect(!SloppyApp.shouldStartTUI(prompt: nil, stdinIsTTY: false, stdoutIsTTY: false))
    #expect(!SloppyApp.shouldStartTUI(prompt: nil, stdinIsTTY: true, stdoutIsTTY: false))
    #expect(!SloppyApp.shouldStartTUI(prompt: nil, stdinIsTTY: false, stdoutIsTTY: true))
}

@Test
func rootCommandAllowsTUIOnlyForInteractiveStdioWithoutPrompt() {
    #expect(SloppyApp.shouldStartTUI(prompt: nil, stdinIsTTY: true, stdoutIsTTY: true))
    #expect(!SloppyApp.shouldStartTUI(prompt: "hello", stdinIsTTY: true, stdoutIsTTY: true))
}

@Test
func rootCommandIncludesSloppyNodeCommandTree() {
    let rootSubcommands = SloppyApp.configuration.subcommands.compactMap { $0.configuration.commandName }
    #expect(rootSubcommands.contains("node"))
    #expect(rootSubcommands.contains("deepresearch"))

    let nodeCommand = SloppyApp.configuration.subcommands.first { $0.configuration.commandName == "node" }
    let nodeSubcommands = nodeCommand?.configuration.subcommands.compactMap { $0.configuration.commandName } ?? []
    #expect(nodeSubcommands.contains("init"))
    #expect(nodeSubcommands.contains("start"))
    #expect(nodeSubcommands.contains("invoke"))
    #expect(nodeSubcommands.contains("task-create"))
}

// MARK: - Service command tests

@Test
func serviceLaunchAgentPathCombinesInstallEnvironmentWithFallbacks() {
    let path = ServiceManager.launchAgentPATH(
        environment: ["PATH": "/custom/bin:/usr/bin:/custom/bin"]
    )
    let components = path.split(separator: ":").map(String.init)

    #expect(components.prefix(2) == ["/custom/bin", "/usr/bin"])
    #expect(components.contains("/opt/homebrew/bin"))
    #expect(components.contains("/usr/local/bin"))
    #expect(components.contains("/bin"))
    #expect(components.filter { $0 == "/custom/bin" }.count == 1)
    #expect(components.filter { $0 == "/usr/bin" }.count == 1)
}

@Test
func serviceLaunchAgentPlistIncludesPathEnvironmentOnly() throws {
    let plist = ServiceManager.makePlist(
        executablePath: "/tmp/sloppy&server",
        configPath: "/tmp/sloppy <config>.json",
        environment: [
            "PATH": "/custom/bin",
            "SLOPPY_TOKEN": "secret",
        ]
    )
    let data = try #require(plist.data(using: .utf8))
    let rootObject = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    let root = try #require(rootObject as? [String: Any])
    let environment = try #require(root["EnvironmentVariables"] as? [String: String])
    let programArguments = try #require(root["ProgramArguments"] as? [String])

    #expect(environment == ["PATH": ServiceManager.launchAgentPATH(environment: ["PATH": "/custom/bin"])])
    #expect(programArguments == ["/tmp/sloppy&server", "run", "--config-path", "/tmp/sloppy <config>.json"])
    #expect(!plist.contains("SLOPPY_TOKEN"))
    #expect(!plist.contains("secret"))
}

@Test
func serviceMacOSRestartReloadsLaunchAgentPlist() {
    let commands = ServiceManager.macOSRestartCommands(
        plistPath: "/Users/example/Library/LaunchAgents/com.sloppy.server.plist"
    )

    #expect(commands == [
        ["launchctl", "unload", "-w", "/Users/example/Library/LaunchAgents/com.sloppy.server.plist"],
        ["launchctl", "load", "-w", "/Users/example/Library/LaunchAgents/com.sloppy.server.plist"],
    ])
}

@Test(arguments: [false, true])
func serviceMacOSStartLoadsStoppedJobOrKickstartsLoadedJob(loaded: Bool) {
    var commands: [[String]] = []
    let status = ServiceManager.startMacOS(plistPath: "/tmp/sloppy.plist", userID: 501) { args in
        commands.append(args)
        return args[1] == "print" && !loaded ? 113 : 0
    }
    #expect(status == 0)
    #expect(commands == [
        ["launchctl", "print", "gui/501/com.sloppy.server"],
        loaded ? ["launchctl", "kickstart", "gui/501/com.sloppy.server"]
            : ["launchctl", "bootstrap", "gui/501", "/tmp/sloppy.plist"],
    ])
}

@Test(arguments: [false, true])
func serviceMacOSStopRemovesKeepAliveJobAndIsIdempotent(loaded: Bool) {
    var commands: [[String]] = []
    let status = ServiceManager.stopMacOS(userID: 501, shellStatus: { args in
        commands.append(args)
        return args[1] == "print" && (!loaded || commands.count > 2) ? 113 : 0
    }, wait: {})
    #expect(status == 0)
    #expect(commands == (loaded ? [
        ["launchctl", "print", "gui/501/com.sloppy.server"],
        ["launchctl", "bootout", "gui/501/com.sloppy.server"],
        ["launchctl", "print", "gui/501/com.sloppy.server"],
    ] : [["launchctl", "print", "gui/501/com.sloppy.server"]]))
}

@Test
func serviceMacOSStartAndStopPropagateLaunchctlFailures() {
    #expect(ServiceManager.startMacOS(plistPath: "/tmp/sloppy.plist", userID: 501) { args in
        args[1] == "print" ? 0 : 5
    } == 5)
    #expect(ServiceManager.startMacOS(plistPath: "/tmp/sloppy.plist", userID: 501) { args in
        args[1] == "print" ? 113 : 5
    } == 5)
    #expect(ServiceManager.startMacOS(plistPath: "/tmp/sloppy.plist", userID: 501) { _ in 1 } == 1)
    #expect(ServiceManager.stopMacOS(userID: 501, shellStatus: { args in
        args[1] == "print" ? 0 : 5
    }) == 5)
    #expect(ServiceManager.stopMacOS(userID: 501, shellStatus: { _ in 1 }) == 1)
}

@Test
func serviceMacOSStopWaitsForPendingBootoutAndFailsIfItNeverFinishes() {
    var bootedOut = false
    var waits = 0
    let status = ServiceManager.stopMacOS(userID: 501, shellStatus: { args in
        if args[1] == "bootout" { bootedOut = true }
        return bootedOut && waits == 2 ? 113 : 0
    }, wait: { waits += 1 })
    #expect(status == 0)
    #expect(waits == 2)

    #expect(ServiceManager.stopMacOS(userID: 501, shellStatus: { _ in 0 }, wait: {}) != 0)
}

@Test
func serviceEnsureLinuxUserLingerRunsLoginctlEnableLinger() {
    var commands: [[String]] = []

    let enabled = ServiceManager.ensureLinuxUserLinger(
        username: "vlad",
        shell: { args in
            commands.append(args)
            return "Linger=no\n"
        },
        shellStatus: { args in
            commands.append(args)
            return 0
        }
    )

    #expect(enabled == .enabledNow)
    #expect(commands == [
        ["loginctl", "show-user", "vlad", "-p", "Linger"],
        ["loginctl", "enable-linger", "vlad"],
    ])
}

@Test
func serviceEnsureLinuxUserLingerSkipsEnableWhenAlreadyConfigured() {
    var commands: [[String]] = []

    let enabled = ServiceManager.ensureLinuxUserLinger(
        username: "vlad",
        shell: { args in
            commands.append(args)
            return "Linger=yes\n"
        },
        shellStatus: { args in
            commands.append(args)
            return 0
        }
    )

    #expect(enabled == .alreadyEnabled)
    #expect(commands == [["loginctl", "show-user", "vlad", "-p", "Linger"]])
}

@Test
func serviceEnsureLinuxUserLingerReturnsManualSetupWhenLoginctlFails() {
    let enabled = ServiceManager.ensureLinuxUserLinger(
        username: "vlad",
        shell: { _ in "Linger=no\n" },
        shellStatus: { _ in 1 }
    )

    #expect(enabled == .requiresManualSetup)
}

@Test
func serviceLinuxLingerHintIncludesRecoveryCommand() {
    let hint = ServiceManager.linuxLingerHint(username: "vlad")

    #expect(hint.contains("sudo loginctl enable-linger vlad"))
    #expect(hint.contains("without an active login session"))
}

// MARK: - CLIFormatters tests

@Test
func eventWatchFormatterOutputsInputRequestAsJSONL() throws {
    let request = PlanInputRequest(
        id: "input-1",
        mode: "plan",
        title: "Pick a path",
        questions: [
            PlanInputQuestion(
                id: "q1",
                question: "Which path?",
                options: [
                    PlanInputOption(id: "a", label: "A"),
                    PlanInputOption(id: "b", label: "B"),
                ]
            ),
        ]
    )
    let event = AgentSessionEvent(
        id: "event-1",
        agentId: "agent-1",
        sessionId: "session-1",
        type: .inputRequest,
        createdAt: Date(timeIntervalSince1970: 10),
        inputRequest: request
    )
    let update = AgentSessionStreamUpdate(
        kind: .sessionEvent,
        cursor: 4,
        event: event,
        createdAt: Date(timeIntervalSince1970: 11)
    )

    let line = try #require(EventWatchOutputFormatter.line(for: update, format: .jsonl))
    let data = try #require(line.data(using: .utf8))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(object["kind"] as? String == "session_event")
    #expect(object["event_type"] as? String == "input_request")
    #expect(object["agent_id"] as? String == "agent-1")
    #expect(object["session_id"] as? String == "session-1")
    #expect(object["request_id"] as? String == "input-1")
    #expect(object["title"] as? String == "Pick a path")
}

@Test
func eventWatchFormatterOutputsRunStatusAsPrettyLine() throws {
    let event = AgentSessionEvent(
        id: "event-2",
        agentId: "agent-1",
        sessionId: "session-1",
        type: .runStatus,
        createdAt: Date(timeIntervalSince1970: 10),
        runStatus: AgentRunStatusEvent(stage: .responding, label: "Responding")
    )
    let update = AgentSessionStreamUpdate(kind: .sessionEvent, cursor: 7, event: event)

    let line = try #require(EventWatchOutputFormatter.line(for: update, format: .pretty))

    #expect(line.contains("run_status"))
    #expect(line.contains("responding"))
    #expect(line.contains("Responding"))
}

@Test
func cliFormattersResolvesKnownFormats() {
    #expect(CLIFormatters.resolveFormat("json") == .json)
    #expect(CLIFormatters.resolveFormat("table") == .table)
    #expect(CLIFormatters.resolveFormat("JSON") == .json)
}

@Test
func cliFormattersResolvesUnknownAsJSON() {
    #expect(CLIFormatters.resolveFormat("xml") == .json)
    #expect(CLIFormatters.resolveFormat("") == .json)
}

@Test
func cliFormattersOutputJSONParseable() {
    let json = #"{"key":"value"}"#.data(using: .utf8)!
    // printJSON should not crash on valid JSON data
    // We just verify it does not throw
    CLIFormatters.printJSON(json)
}

@Test
func cliFormattersPrintTableEmpty() {
    // Printing an empty table should produce "(no results)"  output without crashing
    CLIFormatters.printTable(
        rows: [String](),
        columns: [(header: "ID", value: { $0 })]
    )
}

@Test
func cliFormattersPrintTableNonEmpty() {
    let rows = ["alpha", "beta", "gamma"]
    CLIFormatters.printTable(
        rows: rows,
        columns: [
            (header: "Name", value: { $0 }),
            (header: "Length", value: { "\($0.count)" }),
        ]
    )
}

// MARK: - SloppyCLIClient resolve tests

@Test
func cliClientResolveUsesDefaultURL() {
    let client = SloppyCLIClient.resolve(url: nil, token: nil, verbose: false)
    // When no env or config is set falls back to the default
    #expect(client.baseURL.hasPrefix("http"))
    #expect(!client.baseURL.hasSuffix("/"))
}

@Test
func cliClientResolveUsesExplicitURL() {
    let client = SloppyCLIClient.resolve(url: "http://example.com:9999", token: "tok", verbose: false)
    #expect(client.baseURL == "http://example.com:9999")
    #expect(client.token == "tok")
}

@Test
func cliClientResolveStripsTrailingSlash() {
    let client = SloppyCLIClient.resolve(url: "http://localhost:8080/", token: nil, verbose: false)
    #expect(!client.baseURL.hasSuffix("/"))
}

@Test
func cliClientVerboseFlagPropagates() {
    let client = SloppyCLIClient.resolve(url: nil, token: nil, verbose: true)
    #expect(client.verbose == true)
}

@Test
func runCommandParsesRelayStartupFlags() throws {
    let command = try RunCommand.parse([
        "--relay-only",
        "--relay-public-url",
        "https://sloppy.example.com",
        "--no-gui",
    ])

    #expect(command.relayOnly)
    #expect(command.relayPublicURL == "https://sloppy.example.com")
    #expect(command.gui == false)
}

// MARK: - Plugin install source path tests

@Test
func pluginInstallSourceResolvesExplicitLocalRelativeDirectory() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("plugin-cli-local-source-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("arcadia-source-control", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

    let resolved = PluginSourcePathResolver.installRequestSource(
        from: "arcadia-source-control",
        localDirectory: true,
        currentDirectoryPath: root.path
    )

    #expect(resolved == source.standardizedFileURL.path)
}

@Test
func pluginInstallSourceResolvesExplicitLocalDotToCurrentDirectory() {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("plugin-cli-dot-source-\(UUID().uuidString)", isDirectory: true)

    let resolved = PluginSourcePathResolver.installRequestSource(
        from: ".",
        localDirectory: true,
        currentDirectoryPath: root.path
    )

    #expect(resolved == root.standardizedFileURL.path)
}

@Test
func pluginInstallSourceResolvesExistingLocalDirectoryByDefault() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("plugin-cli-auto-source-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("local-plugin", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

    let resolved = PluginSourcePathResolver.installRequestSource(
        from: "local-plugin",
        localDirectory: nil,
        currentDirectoryPath: root.path
    )

    #expect(resolved == source.standardizedFileURL.path)
}

@Test
func pluginInstallSourceKeepsGitSourceWhenLocalDirectoryIsFalse() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("plugin-cli-git-source-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("local-plugin", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

    let resolved = PluginSourcePathResolver.installRequestSource(
        from: "local-plugin",
        localDirectory: false,
        currentDirectoryPath: root.path
    )

    #expect(resolved == "local-plugin")
}

@Test
func childProcessEnvironmentAddsHomebrewNodePathWhenAvailable() {
    let nodePath = "/opt/homebrew/opt/node@24/bin"
    guard FileManager.default.fileExists(atPath: nodePath) else {
        return
    }

    let env = childProcessEnvironment(base: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])

    #expect(env["PATH"]?.split(separator: ":").contains(Substring(nodePath)) == true)
}

// MARK: - CLIClientError descriptions

@Test
func cliClientErrorNotConnectedDescription() {
    let err = CLIClientError.notConnected("http://localhost:1234")
    #expect(err.errorDescription?.contains("http://localhost:1234") == true)
}

@Test
func cliClientErrorHTTPErrorDescription() {
    let err = CLIClientError.httpError(404, "not found")
    #expect(err.errorDescription?.contains("404") == true)
}

@Test
func cliClientErrorHTTPErrorUsesServerMessage() {
    let err = CLIClientError.httpError(
        400,
        #"{"error":"invalid_plugin_payload","message":"Expected sourceUrl."}"#
    )

    #expect(err.errorDescription == "Server returned 400: Expected sourceUrl. (invalid_plugin_payload)")
}

@Test
func cliClientErrorInvalidURLDescription() {
    let err = CLIClientError.invalidURL
    #expect(err.errorDescription != nil)
}

// MARK: - OpenAI device auth flow

@Test
func openAIDeviceAuthorizationFlowApprovesAfterPendingPoll() async throws {
    let clock = MutableTestClock(now: Date(timeIntervalSince1970: 0))
    let poller = PollResponseSequence(
        responses: [
            .init(status: "pending", ok: false, message: "Waiting"),
            .init(status: "approved", ok: true, message: "Connected", accountId: "acct_123", planType: "plus"),
        ]
    )
    let sleeps = SleepRecorder()

    let response = try await OpenAIDeviceAuthorizationFlow.pollUntilApproved(
        request: .init(deviceAuthId: "device_123", userCode: "ABCD-1234"),
        initialInterval: 5,
        timeoutSeconds: 30,
        poll: { _ in
            try poller.next()
        },
        sleep: { seconds in
            sleeps.append(seconds)
            clock.advance(by: seconds)
        },
        now: { clock.now }
    )

    #expect(response.status == "approved")
    #expect(response.ok == true)
    #expect(response.accountId == "acct_123")
    #expect(sleeps.values == [5])
}

@Test
func openAIDeviceAuthorizationFlowBacksOffWhenServerRequestsSlowDown() async throws {
    let clock = MutableTestClock(now: Date(timeIntervalSince1970: 0))
    let poller = PollResponseSequence(
        responses: [
            .init(status: "slow_down", ok: false, message: "Slow down"),
            .init(status: "approved", ok: true, message: "Connected"),
        ]
    )
    let sleeps = SleepRecorder()

    let response = try await OpenAIDeviceAuthorizationFlow.pollUntilApproved(
        request: .init(deviceAuthId: "device_123", userCode: "ABCD-1234"),
        initialInterval: 5,
        timeoutSeconds: 30,
        poll: { _ in
            try poller.next()
        },
        sleep: { seconds in
            sleeps.append(seconds)
            clock.advance(by: seconds)
        },
        now: { clock.now }
    )

    #expect(response.status == "approved")
    #expect(sleeps.values == [10])
}

@Test
func openAIDeviceAuthorizationFlowTimesOutAfterExpiration() async throws {
    let clock = MutableTestClock(now: Date(timeIntervalSince1970: 0))
    let poller = PollResponseSequence(
        responses: [
            .init(status: "pending", ok: false, message: "Waiting"),
            .init(status: "pending", ok: false, message: "Still waiting"),
        ]
    )
    let sleeps = SleepRecorder()

    do {
        _ = try await OpenAIDeviceAuthorizationFlow.pollUntilApproved(
            request: .init(deviceAuthId: "device_123", userCode: "ABCD-1234"),
            initialInterval: 5,
            timeoutSeconds: 5,
            poll: { _ in
                try poller.next()
            },
            sleep: { seconds in
                sleeps.append(seconds)
                clock.advance(by: seconds)
            },
            now: { clock.now }
        )
        Issue.record("Expected device authorization flow to time out.")
    } catch let error as OpenAIDeviceAuthorizationFlow.FlowError {
        switch error {
        case let .timedOut(seconds):
            #expect(seconds == 5)
        default:
            Issue.record("Expected timeout error, got \(error.localizedDescription)")
        }
    }

    #expect(sleeps.values == [5])
}

private final class MutableTestClock: @unchecked Sendable {
    var now: Date

    init(now: Date) {
        self.now = now
    }

    func advance(by seconds: Int) {
        now = now.addingTimeInterval(TimeInterval(seconds))
    }
}

private final class SleepRecorder: @unchecked Sendable {
    private(set) var values: [Int] = []

    func append(_ value: Int) {
        values.append(value)
    }
}

private final class PollResponseSequence: @unchecked Sendable {
    private var responses: [OpenAIDeviceCodePollResponse]

    init(responses: [OpenAIDeviceCodePollResponse]) {
        self.responses = responses
    }

    func next() throws -> OpenAIDeviceCodePollResponse {
        guard !responses.isEmpty else {
            throw CLIClientError.noData
        }
        return responses.removeFirst()
    }
}
