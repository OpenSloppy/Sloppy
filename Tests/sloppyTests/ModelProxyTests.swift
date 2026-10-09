import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import AnyLanguageModel
import PluginSDK
import Protocols
import SloppyNodeCore
import Testing
@testable import sloppy

private typealias JSONValue = Protocols.JSONValue

@Suite("Remote model proxy", .serialized)
struct ModelProxyTests {
    @Test func compatibleAPIRequiresAuthEvenWhenDashboardAuthIsDisabled() async throws {
        let fixture = try ProxyHostFixture(name: "personal")
        defer { fixture.remove() }
        let router = CoreRouter(service: fixture.service)
        let rejected = await router.handle(method: "GET", path: "/v1/models", body: nil)
        #expect(rejected.status == 401)
        let response = await router.handle(method: "GET", path: "/v1/models", body: nil, headers: fixture.headers)
        #expect(response.status == 200)
        let body = try JSONDecoder().decode(JSONValue.self, from: response.body)
        #expect(body.asObject?["object"] == .string("list"))
    }

    @Test(arguments: [false, true]) func standardClientsKeepSignedThinkingAcrossToolRound(streaming: Bool) async throws {
        let fixture = try ProxyHostFixture(name: "personal")
        defer { fixture.remove() }
        await fixture.installClaudeFixture()
        let router = CoreRouter(service: fixture.service)
        let first = await router.handle(method: "POST", path: "/v1/chat/completions", body: try requestData(streaming: streaming), headers: fixture.headers)
        #expect(first.status == 200)
        let reply: JSONValue
        if let stream = first.sseStream {
            var messages: [JSONValue] = []
            var done = false
            for await event in stream {
                if event.data == Data("[DONE]".utf8) { done = true }
                else { messages.append(try JSONDecoder().decode(JSONValue.self, from: event.data)) }
            }
            #expect(done)
            let choices = messages.compactMap { $0.asObject?["choices"]?.asArray?.first?.asObject }
            let toolChoice = choices.first(where: { $0["delta"]?.asObject?["tool_calls"] != nil })
            let choice = try #require(toolChoice)
            let call = try #require(choice["delta"]?.asObject?["tool_calls"]?.asArray?.first)
            reply = .object(["role": .string("assistant"), "content": .string(""), "tool_calls": .array([call])])
        } else {
            let body = try JSONDecoder().decode(JSONValue.self, from: first.body)
            reply = try #require(body.asObject?["choices"]?.asArray?.first?.asObject?["message"])
        }
        let data = try requestData(streaming: false, assistant: reply)
        let second = await router.handle(method: "POST", path: "/v1/chat/completions", body: data, headers: fixture.headers)
        #expect(second.status == 200)
        let result = try JSONDecoder().decode(JSONValue.self, from: second.body)
        #expect(result.asObject?["choices"]?.asArray?.first?.asObject?["message"]?.asObject?["content"] == .string("from-work"))
    }

    @Test func replayIsScopedToCallerModelAndToolCallAndExpires() async {
        let cache = ModelProxyReplayCache()
        let now = Date()
        let replay = SloppyInferenceReplay(provider: "claude-code", model: "claude-code:sonnet", message: .object([:]))
        await cache.store(replay, scope: "work-user", model: "model-one", callIDs: ["one"], now: now)
        #expect(await cache.replay(scope: "work-user", model: "model-one", callIDs: ["one"], now: now) != nil)
        #expect(await cache.replay(scope: "other-user", model: "model-one", callIDs: ["one"], now: now) == nil)
        #expect(await cache.replay(scope: "work-user", model: "other-model", callIDs: ["one"], now: now) == nil)
        #expect(await cache.replay(scope: "work-user", model: "model-one", callIDs: ["other"], now: now) == nil)
        #expect(await cache.replay(scope: "work-user", model: "model-one", callIDs: ["one"], now: now.addingTimeInterval(601)) == nil)
    }

    @Test func alteredVisibleHistoryCannotRestoreSignedState() throws {
        var history = try ClaudeCodeHistory(transcript: .init(entries: [
            .response(.init(assetIDs: [], segments: [.text(.init(content: "edited"))])),
            .prompt(.init(segments: [.text(.init(content: "next"))])),
        ]), names: [:])
        #expect(throws: ClaudeCodeError.self) { try history.restoreReplay(.object(["role": .string("assistant"),
            "content": .array([.object(["type": .string("text"), "text": .string("original")])])])) }
    }

    @Test func ungrantedPeerCannotFetchCatalogOrStartInference() async throws {
        let fixture = try ProxyHostFixture(name: "personal")
        defer { fixture.remove() }
        let envelope = MeshEnvelope(type: .rpcRequest, from: "unknown", to: "personal", payload: .object(["method": .string("models.catalog")]))
        #expect(await fixture.service.handleMeshModelCatalog(envelope).asObject?["ok"] == .bool(false))
        let request = SloppyInferenceRequest(model: "claude-code:sonnet", transcript: .init(), tools: [], options: .init())
        let open = MeshEnvelope(type: .streamOpen, from: "unknown", to: "personal", payload: .object([
            "streamId": .string("unauthorized"), "kind": .string("models.inference"), "params": try JSONValueCoder.encode(request),
        ]))
        let response = await fixture.service.handleMeshModelStream(open)
        #expect(response.first?.type == .streamClose)
        #expect(response.first?.payload.asObject?["ok"] == .bool(false))
    }

    @Test func relayURIsRejectCredentialsAndPaths() throws {
        #expect(try SloppyRelayEndpoint.nodeID("sloppy-relay://personal-node") == "personal-node")
        #expect(throws: SloppyRemoteError.self) { try SloppyRelayEndpoint.nodeID("sloppy-relay://token@personal-node") }
        #expect(throws: SloppyRemoteError.self) { try SloppyRelayEndpoint.nodeID("sloppy-relay://personal-node/v1") }
        #expect(throws: SloppyRemoteError.self) { try SloppyRelayEndpoint.nodeID("sloppy-relay://personal-node?other=1") }
    }

    @Test func ownerCancellationStopsRemoteGenerationAndOtherPeersCannotCancelIt() async throws {
        let fixture = try ProxyHostFixture(name: "personal")
        defer { fixture.remove() }
        let identity = NodeIdentityGenerator.makeIdentity(name: "work", roles: ["worker"], capabilities: ["sloppy.models.inference"])
        _ = try fixture.service.nodeMeshStore.upsertNodeRecord(.init(id: identity.nodeId, name: identity.name, publicKey: identity.publicKey,
            roles: identity.roles, capabilities: identity.capabilities), auditAction: "fixture.register")
        let flags = ProxyCancellationFlags()
        await fixture.service.installBlockingProxyModel(flags)
        let request = SloppyInferenceRequest(model: "claude-code:sonnet", transcript: .init(entries: [.prompt(.init(segments: [.text(.init(content: "Wait"))]))]), tools: [], options: .init())
        let open = MeshEnvelope(type: .streamOpen, from: identity.nodeId, to: "personal", payload: .object([
            "streamId": .string("owner-stream"), "kind": .string("models.inference"), "params": try JSONValueCoder.encode(request),
        ]))
        _ = await fixture.service.handleMeshModelStream(open, send: { _ in })
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while !(await flags.started), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await flags.started)
        let other = MeshEnvelope(type: .streamClose, from: "other-peer", to: "personal", payload: .object(["streamId": .string("owner-stream")]))
        _ = await fixture.service.handleMeshModelStream(other)
        #expect(await fixture.service.meshModelStreams["owner-stream"] != nil)
        var close = other
        close.from = identity.nodeId
        _ = await fixture.service.handleMeshModelStream(close)
        while !(await flags.cancelled), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await flags.cancelled)
        #expect(await fixture.service.meshModelStreams["owner-stream"] == nil)
    }

    @Test func localhostTransportExecutesToolsOnRequestingComputer() async throws {
        let personal = try ProxyHostFixture(name: "personal")
        defer { personal.remove() }
        await personal.installClaudeFixture()
        let server = try personal.startServer()
        defer { try? server.shutdown() }
        let port = try #require(server.boundPort)
        let model = SloppyRemoteModel(baseURL: "http://127.0.0.1:\(port)", accessToken: personal.token, model: "claude-code:sonnet")
        try await assertHostToolRound(model)
    }

    @Test func twoComputersUseAuthenticatedEncryptedRelayWithoutExportingClaudeCredentials() async throws {
        let relay = try ProxyHostFixture(name: "relay")
        let personal = try ProxyHostFixture(name: "personal")
        let work = try ProxyHostFixture(name: "work")
        defer { relay.remove(); personal.remove(); work.remove() }
        await personal.installClaudeFixture()
        let server = try relay.startServer()
        defer { try? server.shutdown() }
        let relayURL = "http://127.0.0.1:\(try #require(server.boundPort))"
        let personalID = NodeIdentityGenerator.makeIdentity(name: "personal", roles: ["worker"], capabilities: ["sloppy.models.inference"])
        let workID = NodeIdentityGenerator.makeIdentity(name: "work", roles: ["worker"], capabilities: ["sloppy.models.inference"])
        for identity in [personalID, workID] {
            _ = try relay.service.nodeMeshStore.upsertNodeRecord(.init(id: identity.nodeId, name: identity.name, publicKey: identity.publicKey,
                roles: identity.roles, capabilities: identity.capabilities, encryptionPublicKey: identity.encryptionPublicKey,
                encryptionKeySignature: identity.encryptionKeySignature), auditAction: "fixture.register")
        }
        try personal.nodeConfig.save(.init(identity: personalID, relayURL: relayURL))
        try work.nodeConfig.save(.init(identity: workID, relayURL: relayURL))
        await personal.service.startNodeMeshClientIfConfigured()
        await work.service.startNodeMeshClientIfConfigured()
        defer { Task { await personal.service.stop(); await work.service.stop() } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        var models: [ProviderModelOption] = []
        while models.isEmpty && ContinuousClock.now < deadline {
            models = (try? await work.service.meshModelBridge.catalog(nodeID: personalID.nodeId)) ?? []
            if models.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(models.contains { $0.id == "claude-code:sonnet" })
        let bridge = await work.service.meshModelBridge
        let model = SloppyRemoteModel(baseURL: "sloppy-relay://\(personalID.nodeId)", accessToken: "", model: "claude-code:sonnet",
            inferenceTransport: { request, callback in try await bridge.infer(nodeID: personalID.nodeId, request: request, onSnapshot: callback) })
        try await assertHostToolRound(model)
        await personal.service.stop()
        await work.service.stop()
    }

    private func assertHostToolRound(_ model: SloppyRemoteModel) async throws {
        let counter = ProxyToolCounter()
        let session = LanguageModelSession(model: model, tools: [ProxyEchoTool(counter: counter)])
        var result = ""
        for try await snapshot in session.streamResponse(to: "Call the requesting computer tool", generating: String.self) { result = snapshot.content }
        #expect(result == "from-work")
        #expect(await counter.calls == 1)
    }

    private func requestData(streaming: Bool, assistant: JSONValue? = nil) throws -> Data {
        var messages: [JSONValue] = [.object(["role": .string("user"), "content": .string("Call the requesting computer tool")])]
        if let assistant {
            messages.append(assistant)
            messages.append(.object(["role": .string("tool"), "tool_call_id": .string("proxy-call"), "content": .string("requesting-computer")]))
        }
        return try JSONEncoder().encode(JSONValue.object(["model": .string("claude-code:sonnet"), "messages": .array(messages), "stream": .bool(streaming),
            "tools": .array([.object(["type": .string("function"), "function": .object(["name": .string("local_echo"), "description": .string("Caller tool"),
                "parameters": .object(["type": .string("object"), "properties": .object(["value": .object(["type": .string("string")])])])])])])]))
    }
}

private struct ProxyHostFixture {
    let root: URL
    let service: CoreService
    let nodeConfig: NodeConfigStore
    let token = "model-proxy-test"
    var headers: [String: String] { ["Authorization": "Bearer \(token)"] }
    init(name: String) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("model-proxy-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        nodeConfig = NodeConfigStore(configURL: root.appendingPathComponent("node.json"))
        var config = CoreConfig.test
        config.workspace.basePath = root.path
        config.nodeMeshStatePath = root.appendingPathComponent("mesh.json").path
        config.auth.token = token
        config.ui.dashboardAuth.enabled = true
        config.ui.dashboardAuth.token = token
        config.models = [.init(title: "Claude fixture", apiKey: "", apiUrl: "", model: "sonnet", providerCatalogId: "claude-code")]
        service = CoreService(config: config, currentDirectory: root.path, persistenceBuilder: InMemoryCorePersistenceBuilder(), nodeConfigStore: nodeConfig)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func startServer() throws -> CoreHTTPServer {
        let server = CoreHTTPServer(host: "127.0.0.1", port: 0, router: CoreRouter(service: service), logger: .sloppy(label: "model.proxy.fixture"))
        try server.start(); return server
    }
    func installClaudeFixture() async {
        await service.installProxyClaudeFixture()
    }
}

private extension CoreService {
    func installBlockingProxyModel(_ flags: ProxyCancellationFlags) {
        modelProvider = AnyModelProviderBox(id: "claude-code", supportedModels: ["claude-code:sonnet"], createLanguageModel: { _ in BlockingProxyModel(flags: flags) })
    }
    func installProxyClaudeFixture() {
        modelProvider = AnyModelProviderBox(id: "claude-code", supportedModels: ["claude-code:sonnet"], createLanguageModel: { _ in
            ClaudeCodeLanguageModel(generate: { history, _, _, callback in
                var response = ClaudeCodeResponse()
                response.complete = true
                response.message = .object(["id": .string(UUID().uuidString)])
                let hasResult = history.messages.last?[claude: "content"].claudeArray.contains { $0[claude: "type"].claudeString == "tool_result" } == true
                if hasResult {
                    let assistant = history.messages.last { $0[claude: "role"].claudeString == "assistant" }
                    #expect(assistant?[claude: "content"].claudeArray.first?[claude: "signature"] == .string("signed-thinking-fixture"))
                    response.blocks = [0: ["type": .string("text"), "text": .string("from-work")]]
                    callback?("from-work")
                } else {
                    response.blocks = [0: ["type": .string("thinking"), "thinking": .string("private reasoning"), "signature": .string("signed-thinking-fixture")],
                        1: ["type": .string("tool_use"), "id": .string("proxy-call"), "name": .string("local_echo"), "input": .object(["value": .string("requesting-computer")])]]
                }
                return response
            }, reasoningCapture: .init(), tokenUsageCapture: .init())
        })
    }
}

private actor ProxyCancellationFlags {
    var started = false
    var cancelled = false
    func start() { started = true }
    func cancel() { cancelled = true }
}
private struct BlockingProxyModel: LanguageModel {
    typealias UnavailableReason = Never
    let flags: ProxyCancellationFlags
    func respond<Content: Generable>(within session: LanguageModelSession, to prompt: Prompt, generating type: Content.Type,
        includeSchemaInPrompt: Bool, options: GenerationOptions) async throws -> LanguageModelSession.Response<Content> { throw CancellationError() }
    func streamResponse<Content: Generable>(within session: LanguageModelSession, to prompt: Prompt, generating type: Content.Type,
        includeSchemaInPrompt: Bool, options: GenerationOptions) -> sending LanguageModelSession.ResponseStream<Content> {
        .init(stream: AsyncThrowingStream { continuation in
            Task { await flags.start() }
            continuation.onTermination = { _ in Task { await flags.cancel() } }
        })
    }
}

private actor ProxyToolCounter { var calls = 0; func increment() { calls += 1 } }
private struct ProxyEchoTool: Tool {
    @Generable struct Arguments { var value: String }
    let name = "local_echo"
    let description = "Only executed on the requesting computer"
    let counter: ProxyToolCounter
    func call(arguments: Arguments) async throws -> String { await counter.increment(); return arguments.value }
}
