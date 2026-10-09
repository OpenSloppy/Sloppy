import Foundation
import PluginSDK
import SloppyNodeCore
import Testing
@testable import sloppy

@Suite("Manual relay disconnect", .serialized)
struct MeshRelayDisconnectTests {
    @Test func disconnectRequiresAuthAndPreservesIdentityAndOtherConfig() async throws {
        let fixture = try DisconnectFixture(name: "home")
        defer { fixture.remove() }
        let original = try fixture.store.load()
        let router = CoreRouter(service: fixture.service)
        let body = try JSONEncoder().encode(MeshRelayDisconnectRequest(nodeId: original.identity.nodeId, relayURL: original.relayURL ?? ""))
        let denied = await router.handle(method: "POST", path: "/v1/node/mesh/relay/disconnect", body: body)
        #expect(denied.status == 401)
        #expect(try fixture.store.load() == original)
        let response = await router.handle(method: "POST", path: "/v1/node/mesh/relay/disconnect", body: body, headers: fixture.headers)
        #expect(response.status == 200)
        let saved = try fixture.store.load()
        #expect(saved.identity == original.identity)
        #expect(saved.networkId == original.networkId)
        #expect(saved.networkName == original.networkName)
        #expect(saved.relayURL == nil)
        #expect(!String(decoding: response.body, as: UTF8.self).contains(original.identity.privateKey))
        let repeated = await router.handle(method: "POST", path: "/v1/node/mesh/relay/disconnect", body: body, headers: fixture.headers)
        #expect(repeated.status == 200)
        await fixture.service.startNodeMeshClientIfConfigured()
        #expect(await fixture.service.nodeMeshClient == nil)
    }

    @Test func staleConfirmationAndInvalidBodyDoNotDisconnectAnotherNodeOrRelay() async throws {
        let fixture = try DisconnectFixture(name: "home")
        defer { fixture.remove() }
        let original = try fixture.store.load()
        let router = CoreRouter(service: fixture.service)
        for request in [MeshRelayDisconnectRequest(nodeId: "another-computer", relayURL: original.relayURL ?? ""),
                        MeshRelayDisconnectRequest(nodeId: original.identity.nodeId, relayURL: "http://127.0.0.1:9999")] {
            let result = await router.handle(method: "POST", path: "/v1/node/mesh/relay/disconnect",
                body: try JSONEncoder().encode(request), headers: fixture.headers)
            #expect(result.status == 409)
            #expect(try fixture.store.load() == original)
        }
        let invalid = await router.handle(method: "POST", path: "/v1/node/mesh/relay/disconnect", body: Data("{}".utf8), headers: fixture.headers)
        #expect(invalid.status == 400)
        #expect(try fixture.store.load() == original)
    }

    @Test func disconnectClosesLiveWebSocketWithoutRemovingRegistryOrConsoleConnection() async throws {
        let relay = try DisconnectFixture(name: "relay")
        let home = try DisconnectFixture(name: "home")
        defer { relay.remove(); home.remove() }
        let server = CoreHTTPServer(host: "127.0.0.1", port: 0, router: CoreRouter(service: relay.service), logger: .sloppy(label: "disconnect.fixture"))
        try server.start()
        defer { try? server.shutdown() }
        var config = try home.store.load()
        config.relayURL = "http://127.0.0.1:\(try #require(server.boundPort))"
        try home.store.save(config)
        let identity = config.identity
        _ = try relay.service.nodeMeshStore.upsertNodeRecord(.init(id: identity.nodeId, name: identity.name, publicKey: identity.publicKey,
            roles: identity.roles, capabilities: identity.capabilities, encryptionPublicKey: identity.encryptionPublicKey,
            encryptionKeySignature: identity.encryptionKeySignature), auditAction: "fixture.register")
        await home.service.startNodeMeshClientIfConfigured()
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while try relay.service.nodeMeshStore.listNodes().first(where: { $0.id == identity.nodeId })?.status != .online,
              ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(try relay.service.nodeMeshStore.listNodes().first(where: { $0.id == identity.nodeId })?.status == .online)
        let consoleTask = Task<Void, Never> { try? await Task.sleep(for: .seconds(300)) }
        defer { consoleTask.cancel() }
        await home.service.installDisconnectConsoleTask(consoleTask)
        let router = CoreRouter(service: home.service)
        let response = await router.handle(method: "POST", path: "/v1/node/mesh/relay/disconnect",
            body: try JSONEncoder().encode(MeshRelayDisconnectRequest(nodeId: identity.nodeId, relayURL: config.relayURL ?? "")), headers: home.headers)
        #expect(response.status == 200)
        #expect(await home.service.nodeMeshClient == nil)
        #expect(await home.service.nodeMeshClientTask == nil)
        #expect(!consoleTask.isCancelled)
        #expect(await home.service.consoleRelayTask?.isCancelled == false)
        await #expect(throws: MeshModelBridge.BridgeError.self) { _ = try await home.service.meshModelBridge.catalog(nodeID: identity.nodeId) }
        while try relay.service.nodeMeshStore.listNodes().first(where: { $0.id == identity.nodeId })?.status == .online,
              ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let registered = try #require(relay.service.nodeMeshStore.listNodes().first(where: { $0.id == identity.nodeId }))
        #expect(registered.status == .offline)
        #expect(registered.publicKey == identity.publicKey)
        #expect(try home.store.load().identity == identity)
        #expect(try home.store.load().relayURL == nil)
        await home.service.stop()
    }
}

private extension CoreService {
    func installDisconnectConsoleTask(_ task: Task<Void, Never>) { consoleRelayTask = task }
}

private struct DisconnectFixture {
    let root: URL
    let store: NodeConfigStore
    let service: CoreService
    let headers = ["Authorization": "Bearer disconnect-fixture"]

    init(name: String) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-disconnect-\(UUID().uuidString)")
        store = NodeConfigStore(configURL: root.appendingPathComponent("node.json"))
        _ = try store.initialize(name: name, roles: ["worker"], capabilities: ["sloppy.models.inference"],
            relayURL: "http://127.0.0.1:9", networkId: "personal", networkName: "VPS registry")
        var config = CoreConfig.test
        config.workspace.basePath = root.path
        config.nodeMeshStatePath = root.appendingPathComponent("mesh.json").path
        config.auth.token = "disconnect-fixture"
        config.ui.dashboardAuth.enabled = true
        config.ui.dashboardAuth.token = "disconnect-fixture"
        service = CoreService(config: config, currentDirectory: root.path, persistenceBuilder: InMemoryCorePersistenceBuilder(), nodeConfigStore: store)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
