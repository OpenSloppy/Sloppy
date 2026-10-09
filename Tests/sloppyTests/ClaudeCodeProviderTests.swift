import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import AnyLanguageModel
import PluginSDK
import Protocols
import Testing
@testable import sloppy

private typealias JSONValue = Protocols.JSONValue

@Suite("Claude Code provider")
struct ClaudeCodeProviderTests {
    @Test func routesSeparatelyFromAnthropicAndKeepsConservativeWindow() throws {
        var config = CoreConfig.test
        config.models = [
            .init(title: "Claude Code", apiKey: "", apiUrl: "", model: "sonnet", providerCatalogId: "claude-code"),
            .init(title: "API", apiKey: "test-key", apiUrl: "https://api.anthropic.com", model: "claude-api", providerCatalogId: "anthropic"),
        ]
        let ids = CoreModelProviderFactory.resolveModelIdentifiers(config: config)
        #expect(ids == ["claude-code:sonnet", "anthropic:claude-api"])
        let provider = try #require(CoreModelProviderFactory.buildModelProvider(config: config, resolvedModels: ids))
        #expect(provider.supports(modelName: "claude-code:opus[1m]"))
        #expect(provider.contextLimits(for: "claude-code:opus")?.contextWindowTokens == 200_000)
        #expect(provider.contextLimits(for: "claude-code:opus[1m]")?.contextWindowTokens == 1_000_000)
        #expect(SloppyTUIProviderDefinition("claude-code").probeID == .claudeCode)
        #expect(CoreService.isRuntimeRoutableModelID("claude-code:opus", config: config, hasOAuthCredentials: false))
    }

    @Test func refusesAPIOverridesWithoutDisclosingSecrets() throws {
        let transport = ClaudeCodeTransport(environment: ["ANTHROPIC_API_KEY": "must-not-appear", "CLAUDE_CODE_USE_VERTEX": "1"])
        do {
            _ = try transport.nativeEnvironment()
            Issue.record("Overrides should fail closed")
        } catch {
            #expect(error.localizedDescription.contains("ANTHROPIC_API_KEY"))
            #expect(!error.localizedDescription.contains("must-not-appear"))
        }
        let clean = try ClaudeCodeTransport(environment: ["CLAUDE_CODE_EXTRA_BODY": "inherited", "CLAUDECODE": "1",
                                                        "CLAUDE_CODE_USE_VERTEX": "false"]).nativeEnvironment()
        #expect(clean["CLAUDE_CODE_EXTRA_BODY"] == nil)
        #expect(clean["CLAUDECODE"] == nil)
    }

    @Test(arguments: [false, true]) func toolsRunOnHostAndSignedThinkingSurvivesFollowUp(streaming: Bool) async throws {
        let fixture = ClaudeCodeModelFixture()
        let reasoning = ReasoningContentCapture()
        let usage = TokenUsageCapture()
        let model = ClaudeCodeLanguageModel(generate: { history, body, _, onText in
            try await fixture.generate(history: history, body: body, onText: onText)
        }, reasoningCapture: reasoning, tokenUsageCapture: usage)
        let session = LanguageModelSession(model: model, tools: [ClaudeCodeEchoTool()])
        session.toolExecutionDelegate = SloppyToolExecutionDelegate { request in
            #expect(request.tool == "echo")
            #expect(request.arguments["value"] == .string("host"))
            await fixture.executed()
            return .init(tool: "echo", ok: true, data: .object(["result": .string("from-host")]))
        }
        if streaming {
            var snapshots: [String] = []
            for try await snapshot in session.streamResponse(to: "Call echo", generating: String.self) { snapshots.append(snapshot.content) }
            #expect(snapshots.contains("done"))
            #expect(snapshots.last == "done")
        } else {
            let result = try await session.respond(to: "Call echo")
            #expect(result.content == "done")
            #expect(result.transcriptEntries.contains { if case .toolOutput = $0 { true } else { false } })
        }
        #expect(await fixture.hostExecutions == 1)
        #expect(await fixture.generations == 2)
        #expect(reasoning.consume() == "analysis")
        #expect(usage.consume()?.prompt == 15)
    }

    @Test func unknownToolsNeverReachTheHostDelegate() async throws {
        let fixture = ClaudeCodeModelFixture()
        let model = ClaudeCodeLanguageModel(generate: { _, _, _, _ in
            var response = ClaudeCodeResponse()
            response.blocks = [0: ["type": .string("tool_use"), "id": .string("call"), "name": .string("Bash"), "input": .object([:])]]
            return response
        }, reasoningCapture: .init(), tokenUsageCapture: .init())
        let session = LanguageModelSession(model: model, tools: [ClaudeCodeEchoTool()])
        session.toolExecutionDelegate = SloppyToolExecutionDelegate { _ in
            await fixture.executed()
            return .init(tool: "Bash", ok: true)
        }
        await #expect(throws: ClaudeCodeError.self) { try await session.respond(to: "Attempt unknown tool") }
        #expect(await fixture.hostExecutions == 0)
    }

    @Test func hostStopPreventsFurtherGenerations() async throws {
        let fixture = ClaudeCodeModelFixture()
        let model = ClaudeCodeLanguageModel(generate: { history, body, _, callback in
            try await fixture.generate(history: history, body: body, onText: callback)
        }, reasoningCapture: .init(), tokenUsageCapture: .init())
        let session = LanguageModelSession(model: model, tools: [ClaudeCodeEchoTool()])
        session.toolExecutionDelegate = SloppyToolExecutionDelegate(toolCallDecisionOverride: { _ in .stop }) { _ in
            Issue.record("Stopped tool must not execute")
            return .init(tool: "echo", ok: false)
        }
        _ = try await session.respond(to: "Call echo")
        #expect(await fixture.generations == 1)
    }

    @Test func nativeStatusAndHistoryReplayUseCLIWithoutCopyingCredentials() async throws {
        let fixture = try ClaudeCodeCLIFixture()
        defer { fixture.remove() }
        let transport = ClaudeCodeTransport(environment: fixture.environment, fixtureTransport: { request in
            #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-native")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "fixture-official-cli")
            let body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())
            #expect(body[claude: "messages"].claudeArray.count == 3)
            return (claudeCodeSSE, try #require(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)))
        })
        try await transport.status(timeout: .seconds(120))
        let transcript = Transcript(entries: [
            .prompt(.init(segments: [.text(.init(content: "old"))])),
            .response(.init(assetIDs: [], segments: [.text(.init(content: "previous"))])),
            .prompt(.init(segments: [.text(.init(content: "new"))])),
        ])
        let response = try await transport.generate(model: "sonnet", history: .init(transcript: transcript, names: [:]),
                                                    extraBody: ["tools": .array([]), "max_tokens": .number(16)], effort: nil)
        #expect(response.complete)
        #expect(response.text == "ok")
    }

    @Test func cancelledProcessAlsoClosesGrandchildrenOutput() async throws {
        let fixture = try ClaudeCodeCLIFixture()
        defer { fixture.remove() }
        let child = ClaudeCodeProcess()
        defer { child.cancel() }
        let events = try child.start(executable: "/usr/bin/python3", arguments: ["-c", """
            import json, subprocess, sys, time
            subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])
            print(json.dumps({'type': 'ready'}), flush=True)
            time.sleep(30)
            """], environment: fixture.environment, cwd: fixture.directory)
        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next()?[claude: "type"] == .string("ready"))
        let started = ContinuousClock.now
        child.cancel()
        #expect(try await iterator.next() == nil)
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func timeoutCancelsNativeProcess() async throws {
        let fixture = try ClaudeCodeCLIFixture()
        defer { fixture.remove() }
        let script = fixture.directory.appendingPathComponent("claude")
        try Data("#!/usr/bin/python3\nimport time\ntime.sleep(30)\n".utf8).write(to: script)
        let transport = ClaudeCodeTransport(environment: fixture.environment, timeout: 0.1)
        let history = try ClaudeCodeHistory(transcript: .init(entries: [.prompt(.init(segments: [.text(.init(content: "test"))]))]), names: [:])
        await #expect(throws: ClaudeCodeError.self) { try await transport.generate(model: "sonnet", history: history, extraBody: [:], effort: nil) }
    }

    @Test func admissionRejectsExtraGenerationsAndUnrelatedPaths() async throws {
        let fixture = ClaudeCodeModelFixture()
        let admission = ClaudeCodeAdmission(session: .init(configuration: .ephemeral), fixtureTransport: { request in
            await fixture.executed()
            return (claudeCodeSSE, try #require(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)))
        })
        let base = try await admission.start()
        let http = URLSession(configuration: .ephemeral)
        var unrelated = URLRequest(url: base.appendingPathComponent("v1/models"))
        unrelated.httpMethod = "POST"
        let (_, denied) = try await http.data(for: unrelated)
        #expect((denied as? HTTPURLResponse)?.statusCode == 403)
        await admission.allowGeneration()
        var request = URLRequest(url: base.appendingPathComponent("v1/messages"))
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        let (_, first) = try await http.data(for: request)
        #expect((first as? HTTPURLResponse)?.statusCode == 200)
        let (_, second) = try await http.data(for: request)
        #expect((second as? HTTPURLResponse)?.statusCode == 403)
        #expect(await fixture.hostExecutions == 1)
        #expect(try await admission.waitForResult().text == "ok")
        http.invalidateAndCancel()
        await admission.stop()
    }

    @Test func incompleteUpstreamIsNotACompletedResponse() async throws {
        let fixture = try ClaudeCodeCLIFixture()
        defer { fixture.remove() }
        let transport = ClaudeCodeTransport(environment: fixture.environment, fixtureTransport: { request in
            let incomplete = Data("data: {\"type\":\"message_start\",\"message\":{\"id\":\"partial\"}}\n\n".utf8)
            return (incomplete, try #require(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)))
        })
        let history = try ClaudeCodeHistory(transcript: .init(entries: [.prompt(.init(segments: [.text(.init(content: "test"))]))]), names: [:])
        await #expect(throws: ClaudeCodeError.self) {
            try await transport.generate(model: "sonnet", history: history, extraBody: [:], effort: nil)
        }
    }

    @Test func streamingGatewayPreservesSSESeparatorsAndSplitUTF8() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaudeCodeSSEURLProtocol.self]
        let admission = ClaudeCodeAdmission(session: URLSession(configuration: configuration))
        let base = try await admission.start()
        await admission.allowGeneration()
        var request = URLRequest(url: base.appendingPathComponent("v1/messages"))
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        #expect(data == ClaudeCodeSSEURLProtocol.payload)
        #expect(try await admission.waitForResult().text == "雪")
        await admission.stop()
    }

    @Test func generationBeforeReplayCompletesNeverReachesUpstream() async throws {
        let fixture = ClaudeCodeModelFixture()
        let admission = ClaudeCodeAdmission(session: .init(configuration: .ephemeral), fixtureTransport: { request in
            await fixture.executed()
            return (claudeCodeSSE, try #require(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)))
        })
        let base = try await admission.start()
        var request = URLRequest(url: base.appendingPathComponent("v1/messages"))
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 403)
        await #expect(throws: ClaudeCodeError.self) { try await admission.waitForResult() }
        #expect(await fixture.hostExecutions == 0)
        await admission.stop()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SLOPPY_TEST_CLAUDE_CODE_LIVE"] == "1"))
    func installedOfficialCLICanReplayAndGenerateWithFixtureUpstream() async throws {
        var environment = ProcessInfo.processInfo.environment
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "ANTHROPIC_FOUNDRY_API_KEY",
                    "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"] { environment.removeValue(forKey: key) }
        // Exercise the official CLI's auth/identity construction without reading
        // a real account's credentials or spending subscription/API credits.
        environment["CLAUDE_CODE_OAUTH_TOKEN"] = "sk-ant-oat01-sloppy-fixture"
        let transport = ClaudeCodeTransport(environment: environment, fixtureTransport: { request in
            let nativeBearerPresent = request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true
            #expect(nativeBearerPresent)
            let officialIdentity = request.value(forHTTPHeaderField: "User-Agent")?.lowercased().contains("claude") == true
            #expect(officialIdentity)
            let body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())
            let toolNames = body[claude: "tools"].claudeArray.compactMap { $0[claude: "name"].claudeString }
            #expect(toolNames == ["echo"])
            return (claudeCodeSSE, try #require(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)))
        })
        try await transport.status()
        let history = try ClaudeCodeHistory(transcript: .init(entries: [
            .prompt(.init(segments: [.text(.init(content: "Sloppy fixture previous question"))])),
            .response(.init(assetIDs: [], segments: [.text(.init(content: "previous fixture response"))])),
            .prompt(.init(segments: [.text(.init(content: "Sloppy fixture current question"))])),
        ]), names: [:])
        let response = try await transport.generate(model: "sonnet", history: history, extraBody: [
            "tools": .array([.object(["name": .string("echo"), "description": .string("Fixture host-only echo"),
                                     "input_schema": .object(["type": .string("object"), "properties": .object([:])])])]),
            "max_tokens": .number(4096),
        ], effort: nil)
        #expect(response.complete)
        #expect(response.text == "ok")
        let fixture = ClaudeCodeModelFixture()
        let toolTransport = ClaudeCodeTransport(environment: environment, fixtureTransport: { request in
            let body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())
            let hasHostResult = body[claude: "messages"].claudeArray.contains { message in
                message[claude: "content"].claudeArray.contains { $0[claude: "type"].claudeString == "tool_result" }
            }
            return (hasHostResult ? claudeCodeSSE : claudeCodeToolSSE,
                    try #require(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)))
        })
        let model = ClaudeCodeLanguageModel(generate: { history, body, effort, onText in
            try await toolTransport.generate(model: "sonnet", history: history, extraBody: body, effort: effort, onText: onText)
        }, reasoningCapture: .init(), tokenUsageCapture: .init())
        let session = LanguageModelSession(model: model, tools: [ClaudeCodeEchoTool()])
        session.toolExecutionDelegate = SloppyToolExecutionDelegate { request in
            #expect(request.tool == "echo")
            await fixture.executed()
            return .init(tool: "echo", ok: true, data: .object(["result": .string("host result")]))
        }
        #expect(try await session.respond(to: "Run the fixture tool").content == "ok")
        #expect(await fixture.hostExecutions == 1)
    }
}

private actor ClaudeCodeModelFixture {
    var generations = 0
    var hostExecutions = 0
    func executed() { hostExecutions += 1 }
    func generate(history: ClaudeCodeHistory, body: [String: JSONValue], onText: (@Sendable (String) -> Void)?) throws -> ClaudeCodeResponse {
        generations += 1
        #expect(body["tools"]?.claudeArray.first?[claude: "name"].claudeString == "echo")
        var response = ClaudeCodeResponse()
        response.complete = true
        response.message = .object(["id": .string("request-\(generations)")])
        response.usage = ["input_tokens": .number(generations == 1 ? 5 : 10), "output_tokens": .number(2)]
        if generations == 1 {
            response.blocks = [
                0: ["type": .string("thinking"), "thinking": .string("analysis"), "signature": .string("signed")],
                1: ["type": .string("tool_use"), "id": .string("echo-call"), "name": .string("echo"), "input": .object(["value": .string("host")])],
            ]
        } else {
            #expect(history.messages[1][claude: "content"].claudeArray[0][claude: "signature"] == .string("signed"))
            #expect(history.messages.last?[claude: "content"].claudeArray.first?[claude: "tool_use_id"] == .string("echo-call"))
            response.blocks = [0: ["type": .string("text"), "text": .string("done")]]
            onText?("do")
            onText?("done")
        }
        return response
    }
}

private struct ClaudeCodeEchoTool: Tool {
    @Generable struct Arguments { var value: String }
    var name: String { "echo" }
    var description: String { "Echo a value on the host" }
    func call(arguments: Arguments) async throws -> String { arguments.value }
}

private let claudeCodeSSE = Data("""
event: message_start
data: {"type":"message_start","message":{"id":"fixture","type":"message","role":"assistant","content":[],"model":"sonnet","usage":{"input_tokens":5,"output_tokens":0}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":1}}

event: message_stop
data: {"type":"message_stop"}


""".utf8)

private let claudeCodeToolSSE = Data("""
event: message_start
data: {"type":"message_start","message":{"id":"fixture-tool","type":"message","role":"assistant","content":[],"model":"sonnet","usage":{"input_tokens":5,"output_tokens":0}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"native-echo","name":"echo","input":{}}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"value\\":\\"host\\"}"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":2}}

event: message_stop
data: {"type":"message_stop"}


""".utf8)

private final class ClaudeCodeSSEURLProtocol: URLProtocol, @unchecked Sendable {
    static let payload = Data(String(decoding: claudeCodeSSE, as: UTF8.self).replacingOccurrences(of: "\"ok\"", with: "\"雪\"")
        .replacingOccurrences(of: "\n", with: "\r\n").utf8)
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api.anthropic.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for offset in stride(from: 0, to: Self.payload.count, by: 7) {
            client?.urlProtocol(self, didLoad: Self.payload.subdata(in: offset..<min(offset + 7, Self.payload.count)))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct ClaudeCodeCLIFixture {
    let directory: URL
    var environment: [String: String] { ["PATH": "/usr/bin:/bin", "SLOPPY_CLAUDE_CODE_COMMAND": directory.appendingPathComponent("claude").path] }
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("claude-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let script = """
        #!/usr/bin/python3
        import json, os, sys, urllib.request
        if sys.argv[1:3] == ['auth', 'status']:
            print(json.dumps({'loggedIn': True, 'authMethod': 'claudeai', 'apiProvider': 'firstParty'}, indent=2))
            sys.exit(0)
        def flag(name): return sys.argv[sys.argv.index(name) + 1]
        assert flag('--tools') == ''
        assert flag('--permission-mode') == 'dontAsk'
        assert flag('--setting-sources') == ''
        assert '--no-session-persistence' in sys.argv
        body = json.loads(json.load(open(flag('--settings')))['env']['CLAUDE_CODE_EXTRA_BODY'])
        body['messages'] = []
        for line in sys.stdin:
            frame = json.loads(line)
            body['messages'].append(frame['message'])
            if frame.get('shouldQuery') is False:
                print(json.dumps({'type': 'result', 'num_turns': 0, 'is_error': False}), flush=True)
            elif frame['type'] == 'user':
                req = urllib.request.Request(os.environ['ANTHROPIC_BASE_URL'] + '/v1/messages', json.dumps(body).encode(),
                    {'Authorization': 'Bearer fixture-native', 'User-Agent': 'fixture-official-cli'})
                with urllib.request.urlopen(req) as r: r.read()
                print(json.dumps({'type': 'result', 'num_turns': 1, 'is_error': False}), flush=True)
        """
        let file = directory.appendingPathComponent("claude")
        try Data(script.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}
