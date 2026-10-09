import Foundation
import Crypto
import AnyLanguageModel
import PluginSDK
import Protocols
import SloppyConsoleProtocol
import Testing
@testable import SloppyRemoteProtocol
@testable import sloppy
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("Console instance model provider", .serialized)
struct ConsoleModelProxyTests {
    @Test func consoleInstancesProvideModelsAndHostToolsOverMutualTLSWithoutManualMesh() async throws {
        let fixture = try await ConsoleModelFixture.make()
        defer { fixture.remove() }
        await fixture.home.service.installConsoleClaudeFixture()
        let instances = try await fixture.work.service.consoleModelBridge.instances()
        #expect(instances.count == 1)
        #expect(instances.first?.id == fixture.home.binding.id)
        #expect(instances.first?.canInfer == true)
        let api = await CoreRouter(service: fixture.work.service).handle(method: "GET", path: "/v1/console/model-instances", body: nil, remoteAddress: "127.0.0.1")
        #expect(api.status == 200)
        let listed = try JSONDecoder().decode([ConsoleModelInstance].self, from: api.body)
        #expect(listed.first?.id == fixture.home.binding.id)
        #expect(!String(decoding: api.body, as: UTF8.self).contains("private-device-token"))
        let denied = await CoreRouter(service: fixture.work.service).handle(method: "GET", path: "/v1/console/model-instances", body: nil, remoteAddress: "192.168.1.2")
        #expect(denied.status == 403)
        let models = try await fixture.work.service.consoleModelBridge.catalog(instanceID: fixture.home.binding.id)
        #expect(models.map(\.id) == ["claude-code:sonnet"])
        var config = CoreConfig.test
        config.models = [.init(title: "Home Console", apiKey: "", apiUrl: "sloppy-console://\(fixture.home.binding.id)", model: "claude-code:sonnet", providerCatalogId: "sloppy")]
        let ids = CoreModelProviderFactory.resolveModelIdentifiers(config: config)
        let bridge = await fixture.work.service.consoleModelBridge
        let provider = try #require(CoreModelProviderFactory.buildModelProvider(config: config, resolvedModels: ids, consoleModelBridge: bridge))
        let model = try await provider.createLanguageModel(for: "sloppy:claude-code:sonnet")
        let counter = ConsoleToolCounter()
        let session = LanguageModelSession(model: model, tools: [ConsoleEchoTool(counter: counter)])
        var result = ""
        for try await update in session.streamResponse(to: "private-console-prompt", generating: String.self) { result = update.content }
        #expect(result == "from-work")
        #expect(await counter.calls == 1)
        #expect(await fixture.work.service.nodeMeshClient == nil)
        let wire = String(decoding: await fixture.hub.bytes.reduce(into: Data()) { $0.append($1) }, as: UTF8.self)
        #expect(!wire.contains("private-console-prompt"))
        #expect(!wire.contains("private-console-thinking"))
        #expect(!wire.contains("local_echo"))
        #expect(!wire.contains("from-work"))
        #expect(await fixture.hub.bytes.count > 4)
        await fixture.close()
    }

    @Test func readOnlyGrantCanLoadCatalogButCannotRunModelAndDoesNotCreateAccess() async throws {
        let fixture = try await ConsoleModelFixture.make(permissions: [.read])
        defer { fixture.remove() }
        let instances = try await fixture.work.service.consoleModelBridge.instances()
        #expect(instances.first?.canInfer == false)
        let models = try await fixture.work.service.consoleModelBridge.catalog(instanceID: fixture.home.binding.id)
        #expect(models.count == 1)
        let before = await fixture.hub.bytes.count
        await #expect(throws: ConsoleModelBridge.BridgeError.self) {
            _ = try await fixture.work.service.consoleModelBridge.infer(instanceID: fixture.home.binding.id, request: fixture.request, onSnapshot: nil)
        }
        #expect(await fixture.hub.bytes.count == before)
        await fixture.close()
    }

    @Test func scopedGrantCannotExposeInstanceWideModels() async throws {
        let fixture = try await ConsoleModelFixture.make(projectIDs: ["project-only"])
        defer { fixture.remove() }
        await #expect(throws: ConsoleModelBridge.BridgeError.self) {
            _ = try await fixture.work.service.consoleModelBridge.catalog(instanceID: fixture.home.binding.id)
        }
        let proof = try await fixture.cloud.proof(instanceID: fixture.home.binding.id, deviceID: fixture.work.local.deviceID)
        let frame = ConsoleModelRequest(id: UUID(), instanceID: fixture.home.binding.id, action: .inference, inference: fixture.request)
        let reply = try await fixture.home.service.handleConsoleRemotePacket(senderID: fixture.work.local.deviceID,
            certificate: fixture.work.tls.certificateDER, packet: .init(kind: "models.request", payload: ConsoleWire.encode(frame), proof: proof))
        let error = try ConsoleWire.decode(ConsoleModelResponse.self, from: #require(reply).payload)
        #expect(error.event == .error)
        #expect(error.accessDenied == true)
        #expect(await fixture.home.service.consoleModelStreams.isEmpty)
        await fixture.close()
    }

    @Test func cancellationStopsGenerationOnTheConsoleInstance() async throws {
        let fixture = try await ConsoleModelFixture.make()
        defer { fixture.remove() }
        let flags = ConsoleCancellationFlags()
        await fixture.home.service.installConsoleBlockingModel(flags)
        let task = Task {
            try await fixture.work.service.consoleModelBridge.infer(instanceID: fixture.home.binding.id, request: fixture.request, onSnapshot: nil)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !(await flags.started), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await flags.started)
        task.cancel()
        if let _ = try? await task.value { Issue.record("Cancelled inference must fail") }
        while !(await flags.cancelled), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await flags.cancelled)
        await fixture.close()
    }

    @Test func revokingConsoleGrantStopsAnActiveModelAndRejectsLaterRequests() async throws {
        let fixture = try await ConsoleModelFixture.make()
        defer { fixture.remove() }
        let flags = ConsoleCancellationFlags()
        await fixture.home.service.installConsoleBlockingModel(flags)
        let task = Task {
            try await fixture.work.service.consoleModelBridge.infer(instanceID: fixture.home.binding.id, request: fixture.request, onSnapshot: nil)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !(await flags.started), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await flags.started)
        await fixture.cloud.revokeGrant()
        let grant = await fixture.cloud.grant
        try await fixture.home.store.synchronize(.init(instance: fixture.home.binding, devices: [fixture.work.device, fixture.home.device], grants: [grant], policies: [], signedChanges: []))
        await fixture.home.service.validateConsoleModelStreams()
        try await fixture.work.service.consoleModelBridge.refreshPins([:])
        if let _ = try? await task.value { Issue.record("Revoked inference must fail") }
        while !(await flags.cancelled), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await flags.cancelled)
        await #expect(throws: ConsoleModelBridge.BridgeError.self) {
            _ = try await fixture.work.service.consoleModelBridge.catalog(instanceID: fixture.home.binding.id)
        }
        await fixture.close()
    }

    @Test(arguments: [false, true]) func wrongCertificateFingerprintAndRevokedGrantFailBeforeSendingPayload(revoked: Bool) async throws {
        let fixture = try await ConsoleModelFixture.make()
        defer { fixture.remove() }
        if revoked { await fixture.cloud.revokeGrant() } else { await fixture.cloud.corruptHostPin() }
        await #expect(throws: ConsoleModelBridge.BridgeError.self) {
            _ = try await fixture.work.service.consoleModelBridge.catalog(instanceID: fixture.home.binding.id)
        }
        #expect(await fixture.hub.bytes.isEmpty)
        await fixture.close()
    }

    @Test(arguments: ["sloppy-console://not-a-uuid", "sloppy-console://00000000-0000-0000-0000-000000000001:42", "sloppy-console://00000000-0000-0000-0000-000000000001/path", "sloppy-console://00000000-0000-0000-0000-000000000001?q=1"])
    func invalidConsoleEndpointsAreRejected(value: String) {
        #expect(throws: ConsoleModelBridge.BridgeError.self) { try ConsoleModelEndpoint.instanceID(value) }
    }
}

private struct ConsoleModelHost {
    let root: URL
    let service: CoreService
    let store: ConsoleInstanceTrustStore
    let local: ConsoleLocalIdentity
    let tls: RemoteTLSIdentity
    let binding: InstanceBinding
    let device: ConsoleDevice
    static func make(name: String, account: ConsoleAccount, consoleKey: Curve25519.Signing.PrivateKey) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("console-model-\(UUID().uuidString)")
        var config = CoreConfig.test
        config.workspace.basePath = root.path
        config.nodeMeshStatePath = root.appendingPathComponent("mesh.json").path
        config.models = [.init(title: "Claude", apiKey: "", apiUrl: "", model: "sonnet", providerCatalogId: "claude-code")]
        let service = CoreService(config: config, currentDirectory: root.path, persistenceBuilder: InMemoryCorePersistenceBuilder(), nodeConfigStore: .init(configURL: root.appendingPathComponent("unused-node.json")))
        let store = try #require(await service.consoleTrustStore)
        let local = await store.identity()
        let tls = try RemoteTLSIdentity(signingPrivateKey: local.signingPrivateKey, deviceID: local.deviceID)
        let binding = InstanceBinding(id: local.instanceID, ownerID: account.id, spaceID: account.personalSpaceID, name: name,
            authorityPublicKey: local.signingPublicKey, hostDeviceID: local.deviceID, hostCertificateFingerprint: ConsoleTrust.fingerprint(tls.certificateDER))
        let proposal = AccessProposal(kind: .bindInstance, actorAccountID: account.id, instanceID: binding.id, targetID: binding.id, version: 1,
            expiresAt: Date().addingTimeInterval(3600), payload: try ConsoleWire.encode(binding))
        try await store.installBinding(store.sign(proposal), consolePublicKey: consoleKey.publicKey.rawRepresentation, environment: .test)
        let installed = try #require(await store.binding())
        return .init(root: root, service: service, store: store, local: local, tls: tls, binding: installed,
            device: .init(id: local.deviceID, accountID: account.id, name: name, signingPublicKey: local.signingPublicKey, certificateDER: tls.certificateDER, status: .active))
    }
}

private struct ConsoleModelFixture {
    let work: ConsoleModelHost
    let home: ConsoleModelHost
    let cloud: ConsoleModelCloud
    let hub: ConsoleModelHub
    let workRemote: ConsoleRemoteConnection
    let homeRemote: ConsoleRemoteConnection
    var request: SloppyInferenceRequest { .init(model: "claude-code:sonnet", transcript: .init(entries: [.prompt(.init(segments: [.text(.init(content: "private-console-prompt"))]))]), tools: [], options: .init()) }
    static func make(permissions: Set<InstancePermission> = [.read, .runAgents], projectIDs: Set<String> = []) async throws -> Self {
        let key = Curve25519.Signing.PrivateKey(), account = ConsoleAccount(issuer: "fixture", subject: "owner", email: "fixture@example.invalid", name: "Owner")
        let work = try await ConsoleModelHost.make(name: "Work", account: account, consoleKey: key)
        let home = try await ConsoleModelHost.make(name: "Home", account: account, consoleKey: key)
        let grantID = UUID()
        let grantRequest = GrantRequest(deviceID: work.local.deviceID, accountID: account.id, signingPublicKey: work.local.signingPublicKey,
            certificateFingerprint: ConsoleTrust.fingerprint(work.tls.certificateDER), permissions: permissions, projectIDs: projectIDs)
        let proposal = AccessProposal(kind: .deviceGrant, actorAccountID: account.id, instanceID: home.binding.id, targetID: grantID,
            version: 1, expiresAt: Date().addingTimeInterval(3600), payload: try ConsoleWire.encode(grantRequest))
        let signed = try ConsoleTrust.sign(proposal, privateKey: key.rawRepresentation)
        let grant = DeviceGrant(id: grantID, instanceID: home.binding.id, deviceID: work.local.deviceID, accountID: account.id, organizationID: nil,
            signingPublicKey: work.local.signingPublicKey, certificateFingerprint: grantRequest.certificateFingerprint, permissions: permissions,
            projectIDs: projectIDs, version: 1, signedProposal: signed)
        try await home.store.synchronize(.init(instance: home.binding, devices: [work.device, home.device], grants: [grant], policies: [], signedChanges: []))
        let cloud = ConsoleModelCloud(account: account, hosts: [work, home], grant: grant, key: key)
        let hub = ConsoleModelHub()
        let workRemote = connection(work, pins: [:], hub: hub)
        let homeRemote = connection(home, pins: [work.local.deviceID: work.tls.certificateDER], hub: hub)
        let workCloud = ConsoleCloudDeviceClient(baseURL: ConsoleEnvironment.test.consoleURL, deviceID: work.local.deviceID, privateKey: work.local.signingPrivateKey,
            transport: { request in try await cloud.send(request, deviceID: work.local.deviceID) })
        await work.service.installConsoleModelTransport(remote: workRemote, cloud: workCloud, store: work.store, host: work)
        await home.service.setConsoleModelRemote(homeRemote)
        await workRemote.setHandler { from, certificate, packet in try await work.service.handleConsoleRemotePacket(senderID: from, certificate: certificate, packet: packet) }
        await homeRemote.setHandler { from, certificate, packet in try await home.service.handleConsoleRemotePacket(senderID: from, certificate: certificate, packet: packet) }
        await workRemote.setDisconnectHandler { await work.service.consoleModelsDisconnected() }
        await homeRemote.setDisconnectHandler { await home.service.consoleModelsDisconnected() }
        try await homeRemote.connect()
        return .init(work: work, home: home, cloud: cloud, hub: hub, workRemote: workRemote, homeRemote: homeRemote)
    }
    private static func connection(_ host: ConsoleModelHost, pins: [UUID: Data], hub: ConsoleModelHub) -> ConsoleRemoteConnection {
        ConsoleRemoteConnection(deviceID: host.local.deviceID, signingPrivateKey: host.local.signingPrivateKey, identity: host.tls,
            relayURL: ConsoleEnvironment.test.relayURL, pins: pins, transportFactory: { ConsoleModelSocket(id: host.local.deviceID, hub: hub) },
            authenticateDevice: {
                .init(device: .init(id: host.local.deviceID, spaceID: UUID(), principalID: UUID(), kind: .host, name: "Fixture",
                    signingPublicKey: host.tls.signingPublicKey, encryptionPublicKey: Data(), encryptionKeySignature: Data(), capabilities: []),
                    token: "fixture", expiresAt: Date().addingTimeInterval(300))
            })
    }
    func close() async { await workRemote.disconnect(); await homeRemote.disconnect(); await work.service.clearConsoleModelFixture() }
    func remove() { try? FileManager.default.removeItem(at: work.root); try? FileManager.default.removeItem(at: home.root) }
}

private actor ConsoleModelCloud {
    let account: ConsoleAccount
    let key: Curve25519.Signing.PrivateKey
    var hosts: [ConsoleModelHost]
    var grant: DeviceGrant
    init(account: ConsoleAccount, hosts: [ConsoleModelHost], grant: DeviceGrant, key: Curve25519.Signing.PrivateKey) { self.account = account; self.hosts = hosts; self.grant = grant; self.key = key }
    func revokeGrant() { grant.status = .revoked; grant.version += 1 }
    func corruptHostPin() { hosts[1] = .init(root: hosts[1].root, service: hosts[1].service, store: hosts[1].store, local: hosts[1].local, tls: hosts[1].tls,
        binding: .init(id: hosts[1].binding.id, ownerID: account.id, spaceID: account.personalSpaceID, name: "Home", authorityPublicKey: hosts[1].local.signingPublicKey,
            hostDeviceID: hosts[1].local.deviceID, hostCertificateFingerprint: "wrong", status: .active), device: hosts[1].device) }
    func proof(instanceID: UUID, deviceID: UUID) throws -> SignedInstanceAccessProof {
        #expect(grant.instanceID == instanceID && grant.deviceID == deviceID)
        return try ConsoleTrust.signProof(.init(accountID: account.id, instanceID: instanceID, deviceID: deviceID, organizationID: nil,
            certificateFingerprint: grant.certificateFingerprint, grantVersion: grant.version, expiresAt: Date().addingTimeInterval(300)), privateKey: key.rawRepresentation)
    }
    func send(_ request: URLRequest, deviceID: UUID) throws -> (Data, Int) {
        let path = request.url?.path ?? ""
        if path == "/v1/host-auth/challenge" {
            struct Challenge: Encodable { var id = UUID(); var nonce = Data("fixture-challenge".utf8) }
            return (try ConsoleWire.encode(Challenge()), 200)
        }
        if path == "/v1/host-auth/session" { return (Data("{\"accessToken\":\"private-device-token\"}".utf8), 200) }
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer private-device-token")
        if path == "/v1/me" {
            struct Directory: Encodable { var account: ConsoleAccount; var instances: [InstanceBinding]; var devices: [ConsoleDevice]; var grants: [DeviceGrant] }
            return (try ConsoleWire.encode(Directory(account: account, instances: hosts.map(\.binding), devices: hosts.map(\.device), grants: [grant])), 200)
        }
        if path == "/v1/instances/\(grant.instanceID)/proof" { return (try ConsoleWire.encode(proof(instanceID: grant.instanceID, deviceID: deviceID)), 200) }
        throw ConsoleModelBridge.BridgeError.invalidResponse
    }
}

private actor ConsoleModelHub {
    var bytes: [Data] = []
    var listeners: [UUID: AsyncThrowingStream<Data, Error>.Continuation] = [:]
    func register(_ id: UUID, _ continuation: AsyncThrowingStream<Data, Error>.Continuation) { listeners[id] = continuation }
    func close(_ id: UUID) { listeners.removeValue(forKey: id)?.finish() }
    func send(_ data: Data) throws {
        let envelope = try JSONDecoder().decode(RemoteSealedEnvelope.self, from: data)
        #expect(envelope.kind == RemoteTLSFrame.kind)
        bytes.append(data)
        guard let target = listeners[envelope.to] else { throw RemoteTLSError.closed }
        if case .dropped = target.yield(data) { throw RemoteTLSError.oversizedMessage }
    }
}
private actor ConsoleModelSocket: ConsoleRemoteTransport {
    nonisolated let messages: AsyncThrowingStream<Data, Error>
    let continuation: AsyncThrowingStream<Data, Error>.Continuation
    let id: UUID
    let hub: ConsoleModelHub
    init(id: UUID, hub: ConsoleModelHub) { self.id = id; self.hub = hub; let pair = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingNewest(128)); messages = pair.stream; continuation = pair.continuation }
    func connect(url: URL, token: String) async throws { await hub.register(id, continuation) }
    func send(_ data: Data) async throws { try await hub.send(data) }
    func close() async { await hub.close(id) }
}

private extension CoreService {
    func setConsoleModelRemote(_ remote: ConsoleRemoteConnection) { consoleRemoteConnection = remote }
    func installConsoleModelTransport(remote: ConsoleRemoteConnection, cloud: ConsoleCloudDeviceClient, store: ConsoleInstanceTrustStore, host: ConsoleModelHost) async {
        consoleRemoteConnection = remote
        consoleRelayTask = Task { try? await Task.sleep(for: .seconds(300)) }
        await consoleModelBridge.configure(.init(remote: remote, cloud: cloud, store: store, identity: host.tls, local: host.local, binding: host.binding))
    }
    func clearConsoleModelFixture() async { consoleRelayTask?.cancel(); consoleRelayTask = nil; await consoleModelBridge.stop() }
    func installConsoleClaudeFixture() {
        modelProvider = AnyModelProviderBox(id: "claude-code", supportedModels: ["claude-code:sonnet"], createLanguageModel: { _ in
            ClaudeCodeLanguageModel(generate: { history, _, _, onText in
                var response = ClaudeCodeResponse(); response.complete = true
                let hasResult = history.messages.last?[claude: "content"].claudeArray.contains { $0[claude: "type"].claudeString == "tool_result" } == true
                if hasResult {
                    #expect(history.messages.last(where: { $0[claude: "role"].claudeString == "assistant" })?[claude: "content"].claudeArray.first?[claude: "signature"] == .string("console-signed-thinking"))
                    response.blocks = [0: ["type": .string("text"), "text": .string("from-work")]]; onText?("from-work")
                } else {
                    response.blocks = [0: ["type": .string("thinking"), "thinking": .string("private-console-thinking"), "signature": .string("console-signed-thinking")],
                        1: ["type": .string("tool_use"), "id": .string("console-call"), "name": .string("local_echo"), "input": .object(["value": .string("requesting-computer")])]]
                }
                return response
            }, reasoningCapture: .init(), tokenUsageCapture: .init())
        })
    }
    func installConsoleBlockingModel(_ flags: ConsoleCancellationFlags) {
        modelProvider = AnyModelProviderBox(id: "claude-code", supportedModels: ["claude-code:sonnet"], createLanguageModel: { _ in ConsoleBlockingModel(flags: flags) })
    }
}
private actor ConsoleToolCounter { var calls = 0; func increment() { calls += 1 } }
private struct ConsoleEchoTool: Tool {
    @Generable struct Arguments { var value: String }
    let name = "local_echo", description = "Work Core tool"
    let counter: ConsoleToolCounter
    func call(arguments: Arguments) async throws -> String { await counter.increment(); return arguments.value }
}
private actor ConsoleCancellationFlags { var started = false; var cancelled = false; func start() { started = true }; func cancel() { cancelled = true } }
private struct ConsoleBlockingModel: LanguageModel {
    typealias UnavailableReason = Never
    let flags: ConsoleCancellationFlags
    func respond<Content: Generable>(within session: LanguageModelSession, to prompt: Prompt, generating type: Content.Type, includeSchemaInPrompt: Bool, options: GenerationOptions) async throws -> LanguageModelSession.Response<Content> { throw CancellationError() }
    func streamResponse<Content: Generable>(within session: LanguageModelSession, to prompt: Prompt, generating type: Content.Type, includeSchemaInPrompt: Bool, options: GenerationOptions) -> sending LanguageModelSession.ResponseStream<Content> {
        .init(stream: AsyncThrowingStream { continuation in Task { await flags.start() }; continuation.onTermination = { _ in Task { await flags.cancel() } } })
    }
}
