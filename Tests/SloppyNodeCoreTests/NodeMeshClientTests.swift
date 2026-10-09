import Foundation
import Protocols
import Testing
@testable import SloppyNodeCore

@Suite("NodeMeshClient")
struct NodeMeshClientTests {
    @Test("sensitive mesh payload is opaque to relay and authenticated end to end")
    func sensitivePayloadIsSealedEndToEnd() throws {
        let sender = NodeIdentityGenerator.makeIdentity(
            name: "Work",
            roles: ["client"],
            capabilities: ["sloppy.core.remote"]
        )
        let recipient = NodeIdentityGenerator.makeIdentity(
            name: "Home",
            roles: ["worker"],
            capabilities: ["sloppy.core.remote"]
        )
        let envelope = MeshEnvelope(
            id: "e2e_core_request",
            type: .rpcRequest,
            from: sender.nodeId,
            to: recipient.nodeId,
            payload: .object([
                "method": .string("core.http"),
                "params": .object([
                    "path": .string("/v1/projects"),
                    "headers": .object(["authorization": .string("Bearer secret")]),
                ]),
            ])
        )
        let recipientRecord = MeshNodeRecord(
            id: recipient.nodeId,
            name: recipient.name,
            publicKey: recipient.publicKey,
            roles: recipient.roles,
            capabilities: recipient.capabilities,
            encryptionPublicKey: recipient.encryptionPublicKey,
            encryptionKeySignature: recipient.encryptionKeySignature
        )

        let sealed = try NodeMeshPayloadCrypto.seal(
            envelope.payload,
            envelope: envelope,
            sender: sender,
            recipient: recipientRecord
        )

        #expect(sealed.asObject?["method"] == .string("core.http"))
        #expect(sealed.asObject?["params"] == nil)
        #expect(String(describing: sealed).contains("Bearer secret") == false)
        let opened = try NodeMeshPayloadCrypto.open(
            sealed,
            envelope: envelope,
            recipient: recipient,
            senderSigningPublicKey: sender.publicKey
        )
        #expect(opened == envelope.payload)
    }

    @Test("relay URL resolves to mesh websocket endpoint")
    func relayURLResolvesToMeshWebSocketEndpoint() throws {
        #expect(try NodeMeshClient.resolveRelayWebSocketURL("https://sloppy.example.com").absoluteString == "wss://sloppy.example.com/v1/node/mesh/ws")
        #expect(try NodeMeshClient.resolveRelayWebSocketURL("http://127.0.0.1:8787/").absoluteString == "ws://127.0.0.1:8787/v1/node/mesh/ws")
        #expect(try NodeMeshClient.resolveRelayWebSocketURL("ws://localhost:8787/custom").absoluteString == "ws://localhost:8787/custom")
        #expect(try NodeMeshClient.resolveRelayWebSocketURL("wss://relay.local/custom").absoluteString == "wss://relay.local/custom")
        #expect(throws: NodeMeshClientError.insecureRelayURL("ws://relay.local/custom")) {
            try NodeMeshClient.resolveRelayWebSocketURL("ws://relay.local/custom")
        }
    }

    @Test(arguments: ["192.168.3.199", "192.168.0.0", "192.168.255.255", "10.0.0.1", "172.16.0.0", "172.31.255.255", "127.0.0.2", "[::1]"])
    func privateRelayWorksWithoutTLS(host: String) throws {
        #expect(try NodeMeshClient.resolveRelayWebSocketURL("http://\(host):25102").absoluteString == "ws://\(host):25102/v1/node/mesh/ws")
        #expect(try NodeMeshClient.resolveRelayWebSocketURL("ws://\(host):25102/custom").absoluteString == "ws://\(host):25102/custom")
    }

    @Test(arguments: ["172.15.255.255", "172.32.0.0", "192.169.0.1", "8.8.8.8", "0.0.0.0", "relay.example.com", "192.168.3.199.example.com", "192.168.3.999", "010.0.0.1", "10.1", "2130706433"])
    func publicAndNoncanonicalRelayAddressesStillRequireTLS(host: String) {
        let url = "http://\(host):25102"
        #expect(throws: NodeMeshClientError.insecureRelayURL(url)) {
            try NodeMeshClient.resolveRelayWebSocketURL(url)
        }
    }

    #if canImport(CryptoKit) && !os(Linux)
    @Test func modelTransportAutomaticallySealsMessagesAndRejectsPlaintextOrMissingKeys() async throws {
        let sender = NodeIdentityGenerator.makeIdentity(name: "Work", roles: ["worker"], capabilities: ["sloppy.models.inference"])
        let recipient = NodeIdentityGenerator.makeIdentity(name: "Home", roles: ["worker"], capabilities: ["sloppy.models.inference"])
        let stateURL = temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }
        let store = NodeMeshStore(stateURL: stateURL)
        for identity in [sender, recipient] {
            _ = try store.upsertNodeRecord(.init(id: identity.nodeId, name: identity.name, publicKey: identity.publicKey,
                roles: identity.roles, capabilities: identity.capabilities, encryptionPublicKey: identity.encryptionPublicKey,
                encryptionKeySignature: identity.encryptionKeySignature), auditAction: "fixture.register")
        }
        let work = NodeMeshClient(config: .init(identity: sender), meshStore: store)
        let home = NodeMeshClient(config: .init(identity: recipient), meshStore: store)
        let unconfigured = NodeMeshClient(config: .init(identity: sender))
        for (index, type) in [MeshMessageType.rpcRequest, .rpcResponse, .streamOpen, .streamChunk, .streamClose].enumerated() {
            let envelope = MeshEnvelope(id: "encrypted-model-\(index)", type: type, from: sender.nodeId, to: recipient.nodeId,
                payload: .object(["method": .string("models.catalog"), "kind": .string("models.inference"),
                    "streamId": .string("model-stream"), "params": .object(["prompt": .string("private-model-prompt")]),
                    "data": .string("private-model-response")]))
            let sealed = try await work.prepareOutbound(envelope)
            #expect(NodeMeshPayloadCrypto.isSealed(sealed.payload))
            #expect(sealed.payload.asObject?["params"] == nil)
            #expect(sealed.payload.asObject?["data"] == nil)
            let wire = String(decoding: try JSONEncoder().encode(sealed), as: UTF8.self)
            #expect(!wire.contains("private-model-prompt"))
            #expect(!wire.contains("private-model-response"))
            #expect(try await home.prepareInbound(sealed) == envelope)
            await #expect(throws: NodeMeshPayloadCryptoError.self) { try await home.prepareInbound(envelope) }
            var forgedRelay = envelope
            forgedRelay.from = "relay"
            await #expect(throws: NodeMeshPayloadCryptoError.self) { try await home.prepareInbound(forgedRelay) }
            await #expect(throws: NodeMeshPayloadCryptoError.self) { try await unconfigured.prepareOutbound(envelope) }
        }
        let failure = MeshEnvelope(type: .streamClose, from: "relay", to: recipient.nodeId,
            payload: .object(["streamId": .string("model-stream"), "ok": .bool(false)]))
        #expect(try await home.prepareInbound(failure) == failure)
    }
    #endif

    @Test func modelCatalogRPCRejectsForeignPeersRelaySuccessAndMissingEncryptionMethod() async throws {
        let manager = NodeMeshRPCManager()
        let request = MeshEnvelope(type: .rpcRequest, from: "work", to: "home",
            payload: .object(["method": .string("models.catalog")]))
        let result = try await manager.send(request, timeout: 5) { _ in
            for source in ["stranger", "relay"] {
                #expect(await manager.receive(.init(type: .rpcResponse, from: source, to: "work",
                    payload: .object(["requestId": .string(request.id), "method": .string("models.catalog"), "ok": .bool(true)]))) == false)
            }
            #expect(await manager.receive(.init(type: .rpcResponse, from: "home", to: "work",
                payload: .object(["requestId": .string(request.id), "ok": .bool(true)]))) == false)
            #expect(await manager.receive(.init(type: .rpcResponse, from: "home", to: "work",
                payload: .object(["requestId": .string(request.id), "method": .string("models.catalog"), "ok": .bool(true)]))))
        }
        #expect(result.from == "home")
        let failed = try await manager.send(request, timeout: 5) { _ in
            #expect(await manager.receive(.init(type: .rpcResponse, from: "relay", to: "work",
                payload: .object(["requestId": .string(request.id), "ok": .bool(false)]))))
        }
        #expect(failed.payload.asObject?["ok"] == .bool(false))
    }

    @Test("hello envelope includes identity roles and capabilities")
    func helloEnvelopeIncludesIdentityRolesAndCapabilities() {
        let identity = NodeIdentity(
            nodeId: "node_laptop",
            name: "Laptop",
            publicKey: "ed25519:laptop",
            privateKey: "ed25519:private",
            roles: ["client", "worker"],
            capabilities: ["git", "run_agent"]
        )

        let envelope = NodeMeshClient.makeHelloEnvelope(identity: identity)

        #expect(envelope.type == .nodeHello)
        #expect(envelope.from == "node_laptop")
        #expect(envelope.payload.asObject?["name"] == .string("Laptop"))
        #expect(envelope.payload.asObject?["publicKey"] == .string("ed25519:laptop"))
        #expect(envelope.payload.asObject?["roles"] == .array([.string("client"), .string("worker")]))
        #expect(envelope.payload.asObject?["capabilities"] == .array([.string("git"), .string("run_agent")]))
    }

    @Test("client builds typed rpc request envelope")
    func clientBuildsTypedRPCRequestEnvelope() {
        let identity = NodeIdentityGenerator.makeIdentity(name: "Laptop", roles: ["client"], capabilities: [])
        let envelope = NodeMeshClient.makeRPCRequestEnvelope(
            identity: identity,
            to: "node_worker",
            method: "node.status",
            params: .object(["verbose": .bool(true)])
        )

        #expect(envelope.type == .rpcRequest)
        #expect(envelope.from == identity.nodeId)
        #expect(envelope.to == "node_worker")
        #expect(envelope.payload.asObject?["method"] == .string("node.status"))
        #expect(envelope.payload.asObject?["params"]?.asObject?["verbose"] == .bool(true))
    }

    @Test("live rpc requires relay url")
    func liveRPCRequiresRelayURL() async throws {
        let identity = NodeIdentityGenerator.makeIdentity(name: "Laptop", roles: ["client"], capabilities: [])
        let config = NodeConfig(identity: identity, relayURL: nil)
        let client = NodeMeshClient(config: config)

        do {
            _ = try await client.sendRPCRequest(to: "node_worker", method: "node.ping", timeout: 0.01)
            Issue.record("Expected missing relay URL error")
        } catch let error as NodeMeshClientError {
            #expect(error == .missingRelayURL)
        }
    }

    @Test("stream writes report an unavailable platform transport")
    func streamWritesReportUnavailablePlatformTransport() async throws {
        let identity = NodeIdentityGenerator.makeIdentity(name: "Laptop", roles: ["client"], capabilities: [])
        let client = NodeMeshClient(config: NodeConfig(identity: identity))

        do {
            try await client.sendStreamChunk(
                streamID: "stream_1",
                to: "node_worker",
                data: .string("hello")
            )
            Issue.record("Expected unavailable relay transport error")
        } catch {
            #if os(Linux)
            #expect(error as? NodeMeshClientError == .unsupportedRelayScheme("linux-urlsession-websocket"))
            #else
            #expect(error as? NodeMeshStreamError == .relayNotConnected)
            #endif
        }
    }

    @Test("client handles node ping rpc request")
    func clientHandlesNodePingRPCRequest() async throws {
        let identity = NodeIdentityGenerator.makeIdentity(
            name: "Worker",
            roles: ["worker"],
            capabilities: ["run_agent", "git"]
        )
        let daemon = NodeDaemon(config: NodeConfig(identity: identity))
        await daemon.connect()
        let client = NodeMeshClient(config: NodeConfig(identity: identity), daemon: daemon)
        _ = try await client.response(to: authChallengeEnvelope(for: identity, nonce: "nonce_ping"))

        let response = try #require(await client.response(
            to: MeshEnvelope(
                id: "rpc_1",
                type: .rpcRequest,
                from: "node_laptop",
                to: identity.nodeId,
                payload: .object([
                    "method": .string("node.ping"),
                    "params": .object([:]),
                ])
            )
        ))

        #expect(response.type == .rpcResponse)
        #expect(response.from == identity.nodeId)
        #expect(response.to == "node_laptop")
        #expect(response.payload.asObject?["requestId"] == .string("rpc_1"))
        #expect(response.payload.asObject?["ok"] == .bool(true))
        #expect(response.payload.asObject?["method"] == .string("node.ping"))
    }

    @Test("client delegates unknown rpc to custom handler")
    func clientDelegatesUnknownRPCToCustomHandler() async throws {
        let identity = NodeIdentityGenerator.makeIdentity(
            name: "Worker",
            roles: ["worker"],
            capabilities: ["run_agent", "git"]
        )
        let client = NodeMeshClient(
            config: NodeConfig(identity: identity),
            rpcHandler: { envelope, method, params in
                #expect(envelope.id == "rpc_core_http")
                #expect(method == "core.http")
                #expect(params.asObject?["path"] == .string("/v1/projects"))
                return .object([
                    "requestId": .string(envelope.id),
                    "method": .string(method),
                    "ok": .bool(true),
                    "result": .object(["status": .number(200)]),
                ])
            }
        )
        _ = try await client.response(to: authChallengeEnvelope(for: identity, nonce: "nonce_custom_rpc"))

        let response = try #require(await client.response(
            to: MeshEnvelope(
                id: "rpc_core_http",
                type: .rpcRequest,
                from: "node_laptop",
                to: identity.nodeId,
                payload: .object([
                    "method": .string("core.http"),
                    "params": .object(["path": .string("/v1/projects")]),
                ])
            )
        ))

        #expect(response.type == .rpcResponse)
        #expect(response.payload.asObject?["requestId"] == .string("rpc_core_http"))
        #expect(response.payload.asObject?["method"] == .string("core.http"))
        #expect(response.payload.asObject?["ok"] == .bool(true))
    }

    @Test("client returns mailbox handler response envelopes")
    func clientReturnsMailboxHandlerResponseEnvelopes() async throws {
        let identity = NodeIdentityGenerator.makeIdentity(
            name: "Worker",
            roles: ["worker"],
            capabilities: ["run_agent", "git"]
        )
        let client = NodeMeshClient(
            config: NodeConfig(identity: identity),
            onEnvelope: { envelope in
                #expect(envelope.id == "mailbox_1")
                return [
                    MeshEnvelope(
                        type: .eventAck,
                        from: identity.nodeId,
                        to: envelope.from,
                        payload: .object(["messageId": .string(envelope.id)])
                    ),
                ]
            }
        )
        _ = try await client.response(to: authChallengeEnvelope(for: identity, nonce: "nonce_mailbox_handler"))

        let response = try #require(await client.response(to: MeshEnvelope(
            id: "mailbox_1",
            type: .eventPublish,
            from: "node_safari",
            to: identity.nodeId,
            payload: .object(["kind": .string("agent.browser_context_message")])
        )))

        #expect(response.type == .eventAck)
        #expect(response.from == identity.nodeId)
        #expect(response.to == "node_safari")
        #expect(response.payload.asObject?["messageId"] == .string("mailbox_1"))
    }

    @Test("client signs relay auth challenge")
    func clientSignsRelayAuthChallenge() async throws {
        let identity = NodeIdentityGenerator.makeIdentity(
            name: "Worker",
            roles: ["worker"],
            capabilities: ["run_agent", "git"]
        )
        let client = NodeMeshClient(config: NodeConfig(identity: identity))

        let response = try #require(await client.response(to: authChallengeEnvelope(for: identity, nonce: "nonce_auth")))
        let payload = try JSONValueCoder.decode(MeshAuthResponsePayload.self, from: response.payload)

        #expect(response.type == .authResponse)
        #expect(response.from == identity.nodeId)
        #expect(response.to == "relay")
        #expect(payload.nonce == "nonce_auth")
        #expect(payload.nodeId == identity.nodeId)
        #expect(payload.publicKey == identity.publicKey)
        #expect(NodeIdentityGenerator.verify(signature: payload.signature, challenge: Data("nonce_auth".utf8), publicKey: identity.publicKey))
    }

    @Test("client ignores rpc before relay auth completes")
    func clientIgnoresRPCBeforeRelayAuthCompletes() async throws {
        let identity = NodeIdentityGenerator.makeIdentity(
            name: "Worker",
            roles: ["worker"],
            capabilities: ["run_agent", "git"]
        )
        let client = NodeMeshClient(config: NodeConfig(identity: identity))

        let response = await client.response(
            to: MeshEnvelope(
                id: "rpc_before_auth",
                type: .rpcRequest,
                from: "node_laptop",
                to: identity.nodeId,
                payload: .object([
                    "method": .string("node.ping"),
                    "params": .object([:]),
                ])
            )
        )

        #expect(response == nil)
    }

    @Test("rpc manager correlates matching response")
    func rpcManagerCorrelatesMatchingResponse() async throws {
        let manager = NodeMeshRPCManager()
        let request = MeshEnvelope(
            id: "rpc_waiting",
            type: .rpcRequest,
            from: "node_laptop",
            to: "node_worker",
            payload: .object([
                "method": .string("node.ping"),
                "params": .object([:]),
            ])
        )

        async let response = manager.send(request, timeout: 1) { envelope in
            #expect(envelope.id == "rpc_waiting")
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        let delivered = await manager.receive(MeshEnvelope(
            type: .rpcResponse,
            from: "node_worker",
            to: "node_laptop",
            payload: .object([
                "requestId": .string("rpc_waiting"),
                "ok": .bool(true),
            ])
        ))

        #expect(delivered)
        #expect(try await response.payload.asObject?["ok"] == JSONValue.bool(true))
    }

    @Test("rpc manager times out and ignores late response")
    func rpcManagerTimesOutAndIgnoresLateResponse() async throws {
        let manager = NodeMeshRPCManager()
        let request = MeshEnvelope(
            id: "rpc_timeout",
            type: .rpcRequest,
            from: "node_laptop",
            to: "node_worker",
            payload: .object([
                "method": .string("node.status"),
                "params": .object([:]),
            ])
        )

        do {
            _ = try await manager.send(request, timeout: 0.01) { _ in }
            Issue.record("Expected RPC timeout")
        } catch let error as NodeMeshRPCError {
            #expect(error == .timeout("rpc_timeout"))
        }

        let delivered = await manager.receive(MeshEnvelope(
            type: .rpcResponse,
            from: "node_worker",
            to: "node_laptop",
            payload: .object([
                "requestId": .string("rpc_timeout"),
                "ok": .bool(true),
            ])
        ))
        #expect(delivered == false)
    }

    @Test("client handles shared project list and get rpc")
    func clientHandlesSharedProjectListAndGetRPC() async throws {
        let worker = NodeIdentityGenerator.makeIdentity(name: "Worker", roles: ["worker"], capabilities: ["git"])
        let laptop = NodeIdentityGenerator.makeIdentity(name: "Laptop", roles: ["client"], capabilities: ["git"])
        let outsider = NodeIdentityGenerator.makeIdentity(name: "Outsider", roles: ["client"], capabilities: [])
        let store = NodeMeshStore(stateURL: temporaryStateURL())
        try store.registerNode(worker)
        try store.registerNode(laptop)
        try store.registerNode(outsider)
        let project = try store.createSharedProject(name: "Mesh Project", repoUrl: "git@example.com:mesh.git")
        _ = try store.attachMember(
            projectIdOrName: project.id,
            nodeId: laptop.nodeId,
            localRepoPath: "/Users/laptop/mesh",
            role: "controller",
            permissions: [MeshPermission.projectRead.rawValue, MeshPermission.nodeRPC.rawValue]
        )
        _ = try store.attachMember(
            projectIdOrName: project.id,
            nodeId: worker.nodeId,
            localRepoPath: "/Users/worker/mesh",
            role: "worker",
            permissions: MeshPermission.workerDefaults.rawValues
        )
        let client = NodeMeshClient(config: NodeConfig(identity: worker), meshStore: store)
        _ = try await client.response(to: authChallengeEnvelope(for: worker, nonce: "nonce_shared_projects"))

        let listResponse = try #require(await client.response(to: MeshEnvelope(
            id: "rpc_project_list",
            type: .rpcRequest,
            from: laptop.nodeId,
            to: worker.nodeId,
            payload: .object([
                "method": .string("shared_project.list"),
                "params": .object([:]),
            ])
        )))
        let listedProjects = try #require(listResponse.payload.asObject?["result"]?.asObject?["projects"]?.asArray)
        #expect(listedProjects.count == 1)
        #expect(listedProjects.first?.asObject?["id"] == JSONValue.string(project.id))
        #expect(listedProjects.first?.asObject?["repoUrl"] == JSONValue.string("git@example.com:mesh.git"))

        let getResponse = try #require(await client.response(to: MeshEnvelope(
            id: "rpc_project_get",
            type: .rpcRequest,
            from: laptop.nodeId,
            to: worker.nodeId,
            payload: .object([
                "method": .string("shared_project.get"),
                "params": .object(["id": .string(project.id)]),
            ])
        )))
        #expect(getResponse.payload.asObject?["ok"] == JSONValue.bool(true))
        #expect(getResponse.payload.asObject?["result"]?.asObject?["id"] == JSONValue.string(project.id))

        let forbidden = try #require(await client.response(to: MeshEnvelope(
            id: "rpc_project_forbidden",
            type: .rpcRequest,
            from: outsider.nodeId,
            to: worker.nodeId,
            payload: .object([
                "method": .string("shared_project.get"),
                "params": .object(["id": .string(project.id)]),
            ])
        )))
        #expect(forbidden.payload.asObject?["ok"] == JSONValue.bool(false))
        #expect(forbidden.payload.asObject?["error"]?.asObject?["code"] == JSONValue.string("forbidden"))
    }

    @Test("project status reports local shared project git state")
    func projectStatusReportsLocalSharedProjectGitState() async throws {
        let worker = NodeIdentityGenerator.makeIdentity(name: "Worker", roles: ["worker"], capabilities: ["git"])
        let laptop = NodeIdentityGenerator.makeIdentity(name: "Laptop", roles: ["client"], capabilities: ["git"])
        let repoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sloppy-mesh-project-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], at: repoURL)

        let store = NodeMeshStore(stateURL: temporaryStateURL())
        try store.registerNode(worker)
        try store.registerNode(laptop)
        let project = try store.createSharedProject(name: "Mesh Project", repoUrl: "git@example.com:mesh.git")
        _ = try store.attachMember(
            projectIdOrName: project.id,
            nodeId: laptop.nodeId,
            localRepoPath: "/Users/laptop/mesh",
            role: "controller",
            permissions: [MeshPermission.projectRead.rawValue, MeshPermission.nodeRPC.rawValue]
        )
        _ = try store.attachMember(
            projectIdOrName: project.id,
            nodeId: worker.nodeId,
            localRepoPath: repoURL.path,
            role: "worker",
            permissions: MeshPermission.workerDefaults.rawValues
        )
        let client = NodeMeshClient(config: NodeConfig(identity: worker), meshStore: store)
        _ = try await client.response(to: authChallengeEnvelope(for: worker, nonce: "nonce_project_status"))

        let response = try #require(await client.response(to: MeshEnvelope(
            id: "rpc_project_status",
            type: .rpcRequest,
            from: laptop.nodeId,
            to: worker.nodeId,
            payload: .object([
                "method": .string("project.status"),
                "params": .object(["sharedProjectId": .string(project.id)]),
            ])
        )))

        let result = try #require(response.payload.asObject?["result"]?.asObject)
        #expect(response.payload.asObject?["ok"] == JSONValue.bool(true))
        #expect(result["sharedProjectId"] == JSONValue.string(project.id))
        #expect(result["localRepoPath"] == JSONValue.string(repoURL.path))
        #expect(result["gitBranch"] == JSONValue.string("main"))
        #expect(result["dirty"] == JSONValue.bool(false))
    }

    @Test("client claims task dispatch for configured shared project")
    func clientClaimsTaskDispatchForConfiguredSharedProject() async throws {
        let worker = NodeIdentityGenerator.makeIdentity(name: "Worker", roles: ["worker"], capabilities: ["git"])
        let laptop = NodeIdentityGenerator.makeIdentity(name: "Laptop", roles: ["client"], capabilities: ["git"])
        let store = NodeMeshStore(stateURL: temporaryStateURL())
        try store.registerNode(worker)
        try store.registerNode(laptop)
        let project = try store.createSharedProject(name: "Mesh Project", repoUrl: "git@example.com:mesh.git")
        _ = try store.attachMember(
            projectIdOrName: project.id,
            nodeId: worker.nodeId,
            localRepoPath: "/Users/worker/mesh",
            role: "worker",
            permissions: MeshPermission.workerDefaults.rawValues
        )
        let task = try store.dispatchTask(
            projectIdOrName: project.id,
            title: "Implement feature",
            assignedNodeId: worker.nodeId,
            actor: laptop.nodeId
        )
        let client = NodeMeshClient(config: NodeConfig(identity: worker), meshStore: store)
        _ = try await client.response(to: authChallengeEnvelope(for: worker, nonce: "nonce_task_dispatch"))

        let response = try #require(await client.response(to: MeshEnvelope(
            id: "dispatch_1",
            type: .taskDispatch,
            from: laptop.nodeId,
            to: worker.nodeId,
            scope: project.eventScope,
            payload: .object([
                "taskId": .string(task.id),
                "projectId": .string(project.id),
                "title": .string(task.title),
            ])
        )))

        #expect(response.type == .taskStatusUpdate)
        #expect(response.from == worker.nodeId)
        #expect(response.to == laptop.nodeId)
        #expect(response.payload.asObject?["taskId"] == .string(task.id))
        #expect(response.payload.asObject?["projectId"] == .string(project.id))
        #expect(response.payload.asObject?["nodeId"] == .string(worker.nodeId))
        #expect(response.payload.asObject?["status"] == .string("claimed"))
        #expect(try store.load().tasks.first(where: { $0.id == task.id })?.status == .started)
    }

    @Test("client emits claimed and started responses for accepted task dispatch")
    func clientEmitsClaimedAndStartedResponsesForAcceptedTaskDispatch() async throws {
        let worker = NodeIdentityGenerator.makeIdentity(name: "Worker", roles: ["worker"], capabilities: ["git"])
        let laptop = NodeIdentityGenerator.makeIdentity(name: "Laptop", roles: ["client"], capabilities: ["git"])
        let store = NodeMeshStore(stateURL: temporaryStateURL())
        try store.registerNode(worker)
        try store.registerNode(laptop)
        let project = try store.createSharedProject(name: "Mesh Project", repoUrl: "git@example.com:mesh.git")
        _ = try store.attachMember(
            projectIdOrName: project.id,
            nodeId: worker.nodeId,
            localRepoPath: "/Users/worker/mesh",
            role: "worker",
            permissions: MeshPermission.workerDefaults.rawValues
        )
        let task = try store.dispatchTask(
            projectIdOrName: project.id,
            title: "Implement feature",
            assignedNodeId: worker.nodeId,
            actor: laptop.nodeId
        )
        let client = NodeMeshClient(config: NodeConfig(identity: worker), meshStore: store)
        _ = try await client.response(to: authChallengeEnvelope(for: worker, nonce: "nonce_task_dispatch_multi"))

        let responses = await client.responses(to: MeshEnvelope(
            id: "dispatch_multi",
            type: .taskDispatch,
            from: laptop.nodeId,
            to: worker.nodeId,
            scope: project.eventScope,
            payload: .object([
                "taskId": .string(task.id),
                "projectId": .string(project.id),
                "title": .string(task.title),
            ])
        ))

        #expect(responses.count == 2)
        #expect(responses.map { $0.payload.asObject?["status"] } == [.string("claimed"), .string("started")])
        for response in responses {
            #expect(response.type == .taskStatusUpdate)
            #expect(response.from == worker.nodeId)
            #expect(response.to == laptop.nodeId)
            #expect(response.payload.asObject?["taskId"] == .string(task.id))
            #expect(response.payload.asObject?["projectId"] == .string(project.id))
            #expect(response.payload.asObject?["nodeId"] == .string(worker.nodeId))
        }
        #expect(try store.load().tasks.first(where: { $0.id == task.id })?.status == .started)
    }

    @Test("client blocks task dispatch assigned to another node")
    func clientBlocksTaskDispatchAssignedToAnotherNode() async throws {
        let worker = NodeIdentityGenerator.makeIdentity(name: "Worker", roles: ["worker"], capabilities: ["git"])
        let otherWorker = NodeIdentityGenerator.makeIdentity(name: "Other", roles: ["worker"], capabilities: ["git"])
        let laptop = NodeIdentityGenerator.makeIdentity(name: "Laptop", roles: ["client"], capabilities: ["git"])
        let store = NodeMeshStore(stateURL: temporaryStateURL())
        try store.registerNode(worker)
        try store.registerNode(otherWorker)
        try store.registerNode(laptop)
        let project = try store.createSharedProject(name: "Mesh Project", repoUrl: "git@example.com:mesh.git")
        _ = try store.attachMember(
            projectIdOrName: project.id,
            nodeId: worker.nodeId,
            localRepoPath: "/Users/worker/mesh",
            role: "worker",
            permissions: MeshPermission.workerDefaults.rawValues
        )
        _ = try store.attachMember(
            projectIdOrName: project.id,
            nodeId: otherWorker.nodeId,
            localRepoPath: "/Users/other/mesh",
            role: "worker",
            permissions: MeshPermission.workerDefaults.rawValues
        )
        let task = try store.dispatchTask(
            projectIdOrName: project.id,
            title: "Implement feature",
            assignedNodeId: otherWorker.nodeId,
            actor: laptop.nodeId
        )
        let client = NodeMeshClient(config: NodeConfig(identity: worker), meshStore: store)
        _ = try await client.response(to: authChallengeEnvelope(for: worker, nonce: "nonce_task_wrong_assignee"))

        let response = try #require(await client.response(to: MeshEnvelope(
            id: "dispatch_wrong_assignee",
            type: .taskDispatch,
            from: laptop.nodeId,
            to: worker.nodeId,
            scope: project.eventScope,
            payload: .object([
                "taskId": .string(task.id),
                "projectId": .string(project.id),
                "title": .string(task.title),
            ])
        )))

        #expect(response.type == .taskStatusUpdate)
        #expect(response.payload.asObject?["taskId"] == .string(task.id))
        #expect(response.payload.asObject?["status"] == .string("blocked"))
        #expect(response.payload.asObject?["summary"] == .string("Task is not assigned to this node."))
        #expect(try store.load().tasks.first(where: { $0.id == task.id })?.status == .dispatched)
    }

    @Test("client blocks task dispatch for unknown shared project")
    func clientBlocksTaskDispatchForUnknownSharedProject() async throws {
        let worker = NodeIdentityGenerator.makeIdentity(name: "Worker", roles: ["worker"], capabilities: ["git"])
        let store = NodeMeshStore(stateURL: temporaryStateURL())
        try store.registerNode(worker)
        let client = NodeMeshClient(config: NodeConfig(identity: worker), meshStore: store)
        _ = try await client.response(to: authChallengeEnvelope(for: worker, nonce: "nonce_task_blocked"))

        let response = try #require(await client.response(to: MeshEnvelope(
            id: "dispatch_unknown_project",
            type: .taskDispatch,
            from: "node_laptop",
            to: worker.nodeId,
            scope: "sharedProject:sp_missing",
            payload: .object([
                "taskId": .string("mesh_task_missing"),
                "projectId": .string("sp_missing"),
                "title": .string("Implement feature"),
            ])
        )))

        #expect(response.type == .taskStatusUpdate)
        #expect(response.payload.asObject?["taskId"] == .string("mesh_task_missing"))
        #expect(response.payload.asObject?["projectId"] == .string("sp_missing"))
        #expect(response.payload.asObject?["status"] == .string("blocked"))
        #expect(response.payload.asObject?["summary"] == .string("Shared project is not configured on this node."))
    }

    @Test("stream manager delivers chunks and a clean remote close")
    func streamManagerDeliversChunksAndClose() async throws {
        let manager = NodeMeshStreamManager()
        let stream = await manager.register(streamID: "stream-1")
        var iterator = stream.messages.makeAsyncIterator()

        #expect(await manager.receive(MeshEnvelope(
            type: .streamChunk,
            from: "node_home",
            to: "node_work",
            payload: .object([
                "streamId": .string("stream-1"),
                "data": .object(["type": .string("output"), "data": .string("hello")]),
            ])
        )))
        #expect(try await iterator.next()?.asObject?["data"] == .string("hello"))

        #expect(await manager.receive(MeshEnvelope(
            type: .streamClose,
            from: "node_home",
            to: "node_work",
            payload: .object([
                "streamId": .string("stream-1"),
                "ok": .bool(true),
            ])
        )))
        #expect(try await iterator.next() == nil)
    }

    private func authChallengeEnvelope(for identity: NodeIdentity, nonce: String) throws -> MeshEnvelope {
        MeshEnvelope(
            type: .authChallenge,
            from: "relay",
            to: identity.nodeId,
            payload: try JSONValueCoder.encode(
                MeshAuthChallengePayload(
                    nonce: nonce,
                    nodeId: identity.nodeId,
                    publicKey: identity.publicKey,
                    issuedAt: Date(timeIntervalSince1970: 1_716_000_000)
                )
            )
        )
    }

    private func temporaryStateURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sloppy-mesh-client-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("mesh.json")
    }

    private func runGit(_ arguments: [String], at directoryURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = directoryURL
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
