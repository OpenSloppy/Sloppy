import Foundation
import PluginSDK
import Protocols
import SloppyConsoleProtocol
import SloppyRemoteProtocol

enum ConsoleModelEndpoint {
    static func isConsole(_ value: String) -> Bool { value.lowercased().hasPrefix("sloppy-console:") }
    static func instanceID(_ value: String) throws -> UUID {
        guard let url = URLComponents(string: value), url.scheme == "sloppy-console",
              let host = url.host, let id = UUID(uuidString: host), url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else {
            throw ConsoleModelBridge.BridgeError.invalidEndpoint
        }
        return id
    }
}

struct ConsoleModelInstance: Codable, Sendable {
    var id: UUID
    var name: String
    var status: String
    var canInfer: Bool
    var message: String?
}

struct ConsoleModelRequest: Codable, Sendable {
    enum Action: String, Codable, Sendable { case catalog, inference, cancel }
    var id: UUID
    var instanceID: UUID
    var action: Action
    var inference: SloppyInferenceRequest?
}

struct ConsoleModelResponse: Codable, Sendable {
    enum Event: String, Codable, Sendable { case catalog, snapshot, complete, error }
    var id: UUID
    var event: Event
    var models: [ProviderModelOption]? = nil
    var response: SloppyInferenceResponse? = nil
    var message: String? = nil
    var accessDenied: Bool? = nil
}

enum ConsoleModelAuthorization {
    static func require(_ context: ConsoleAuthorizationContext, inference: Bool) throws {
        guard context.expiresAt > Date(), context.permissions.contains(.administer)
            || (context.permissions.contains(inference ? .runAgents : .read) && context.projectIDs.isEmpty) else {
            throw ConsoleTrustError.forbidden
        }
    }
}

/// Shares the Core's Console device identity and TLS connection. No Mesh invite
/// or OAuth credential is forwarded to the instance serving the model.
actor ConsoleModelBridge {
    enum BridgeError: Error, LocalizedError {
        case notBound, invalidEndpoint, unavailable, accessDenied, invalidResponse
        var errorDescription: String? {
            switch self {
            case .notBound: "Bind this Core to Sloppy Console in Settings → Console to use Console instances."
            case .invalidEndpoint: "Choose a Sloppy Console instance."
            case .unavailable: "The Console instance or secure relay connection is unavailable."
            case .accessDenied: "Approve this Core's device for Read and Run agents on the target instance in Sloppy Console, with instance-wide access."
            case .invalidResponse: "The Console instance returned an invalid or incomplete model response."
            }
        }
    }
    struct Context: Sendable {
        var remote: ConsoleRemoteConnection
        var cloud: ConsoleCloudDeviceClient
        var store: ConsoleInstanceTrustStore
        var identity: RemoteTLSIdentity
        var local: ConsoleLocalIdentity
        var binding: InstanceBinding
    }
    private struct Pending {
        var peerID: UUID
        var inference: Bool
        var continuation: AsyncThrowingStream<ConsoleModelResponse, Error>.Continuation
    }
    private var context: Context?
    private var generation = UUID()
    private var inboundPins: [UUID: Data] = [:]
    private var targets: [UUID: Data] = [:]
    private var pending: [UUID: Pending] = [:]

    func configure(_ value: Context) { context = value; generation = UUID(); inboundPins = [:]; targets = [:] }
    func stop() {
        context = nil; generation = UUID(); targets.removeAll(); inboundPins.removeAll()
        failPending()
    }
    func failPending() {
        let requests = Array(pending.values); pending.removeAll()
        for item in requests { item.continuation.finish(throwing: BridgeError.unavailable) }
    }
    private func current() async throws -> Context {
        guard let context, let binding = await context.store.binding(), binding.status == .active,
              binding.id == context.binding.id, binding.ownerID == context.binding.ownerID else { throw BridgeError.notBound }
        return context
    }
    func instances() async throws -> [ConsoleModelInstance] {
        let context = try await current()
        let directory = try await context.cloud.directory()
        return directory.instances.filter { $0.status == .active && $0.id != context.binding.id && $0.ownerID == context.binding.ownerID }.map { instance in
            let grant = directory.grants.first { $0.instanceID == instance.id && $0.deviceID == context.local.deviceID && $0.organizationID == nil && $0.status == .active }
            let allowed = grant.map { $0.permissions.contains(.administer) || ($0.permissions.contains(.read) && $0.permissions.contains(.runAgents) && $0.projectIDs.isEmpty) } ?? false
            return .init(id: instance.id, name: instance.name, status: instance.status.rawValue, canInfer: allowed,
                message: allowed ? nil : "In Sloppy Console, approve Core device \(context.binding.name) (\(context.local.deviceID.uuidString)) for Read and Run agents on \(instance.name), without project restrictions.")
        }
    }
    func refreshPins(_ pins: [UUID: Data]) async throws {
        inboundPins = pins
        guard let context else { return }
        if !targets.isEmpty {
            let revision = generation
            let directory = try await context.cloud.directory()
            guard generation == revision else { throw BridgeError.unavailable }
            targets = targets.filter { peerID, certificate in
                directory.instances.contains { instance in
                    instance.status == .active && instance.ownerID == context.binding.ownerID && instance.hostDeviceID == peerID
                        && instance.hostCertificateFingerprint == ConsoleTrust.fingerprint(certificate)
                        && directory.devices.contains { $0.id == peerID && $0.status == .active && $0.certificateDER == certificate }
                        && directory.grants.contains { $0.instanceID == instance.id && $0.deviceID == context.local.deviceID && $0.status == .active && $0.organizationID == nil
                            && ($0.permissions.contains(.administer) || ($0.permissions.contains(.read) && $0.projectIDs.isEmpty)) }
                }
            }
            for (id, item) in pending {
                let instance = directory.instances.first { $0.hostDeviceID == item.peerID && $0.status == .active && $0.ownerID == context.binding.ownerID }
                let grant = directory.grants.first { $0.instanceID == instance?.id && $0.deviceID == context.local.deviceID && $0.status == .active && $0.organizationID == nil }
                let allowed = targets[item.peerID] != nil && (grant.map {
                    $0.permissions.contains(.administer) || ($0.projectIDs.isEmpty && $0.permissions.contains(.read) && (!item.inference || $0.permissions.contains(.runAgents)))
                } ?? false)
                if !allowed { pending[id] = nil; item.continuation.finish(throwing: BridgeError.accessDenied) }
            }
        }
        await context.remote.updatePins(inboundPins.merging(targets) { _, outgoing in outgoing })
    }
    private func target(_ id: UUID, inference: Bool) async throws -> (Context, InstanceBinding, SignedInstanceAccessProof) {
        let revision = generation
        let context = try await current()
        let directory = try await context.cloud.directory()
        guard directory.account.id == context.binding.ownerID,
              let instance = directory.instances.first(where: { $0.id == id && $0.status == .active && $0.ownerID == context.binding.ownerID && $0.id != context.binding.id }),
              let host = directory.devices.first(where: { $0.id == instance.hostDeviceID && $0.status == .active && $0.accountID == instance.ownerID }),
              host.signingPublicKey == instance.authorityPublicKey,
              ConsoleTrust.fingerprint(host.certificateDER) == instance.hostCertificateFingerprint,
              let grant = directory.grants.first(where: { $0.instanceID == id && $0.deviceID == context.local.deviceID && $0.organizationID == nil && $0.status == .active }),
              let key = await context.store.consolePublicKey() else { throw BridgeError.accessDenied }
        let proof = try await context.cloud.proof(instanceID: id)
        do {
            let authorization = try ConsoleAuthorizationContext(proof: proof, consolePublicKey: key, grant: grant,
                instanceAuthority: instance.authorityPublicKey, instanceID: id, peerCertificate: context.identity.certificateDER,
                minimumVersion: grant.version, instanceOwnerID: instance.ownerID)
            try ConsoleModelAuthorization.require(authorization, inference: inference)
        } catch { throw BridgeError.accessDenied }
        guard generation == revision else { throw BridgeError.unavailable }
        targets[instance.hostDeviceID] = host.certificateDER
        await context.remote.updatePins(inboundPins.merging(targets) { _, outgoing in outgoing })
        return (context, instance, proof)
    }
    func receive(from peerID: UUID, response: ConsoleModelResponse) -> Bool {
        guard let item = pending[response.id], item.peerID == peerID else { return false }
        if case .dropped = item.continuation.yield(response) {
            pending[response.id] = nil; item.continuation.finish(throwing: BridgeError.invalidResponse); return true
        }
        if response.event != .snapshot { pending[response.id] = nil; item.continuation.finish() }
        return true
    }
    private func request(instanceID: UUID, inference: SloppyInferenceRequest?, onSnapshot: (@Sendable (SloppyInferenceResponse) -> Void)?) async throws -> ConsoleModelResponse {
        let (context, instance, proof) = try await target(instanceID, inference: inference != nil)
        guard pending.count < 16 else { throw BridgeError.unavailable }
        let id = UUID(), pair = AsyncThrowingStream<ConsoleModelResponse, Error>.makeStream(bufferingPolicy: .bufferingNewest(32))
        pending[id] = .init(peerID: instance.hostDeviceID, inference: inference != nil, continuation: pair.continuation)
        let message = ConsoleModelRequest(id: id, instanceID: instanceID, action: inference == nil ? .catalog : .inference, inference: inference)
        do {
            return try await withThrowingTaskGroup(of: ConsoleModelResponse.self) { group in
                group.addTask {
                    try await context.remote.send(.init(kind: "models.request", payload: ConsoleWire.encode(message), proof: proof), to: instance.hostDeviceID)
                    for try await response in pair.stream {
                        try Task.checkCancellation()
                        if response.event == .error { throw response.accessDenied == true ? BridgeError.accessDenied : BridgeError.unavailable }
                        if response.event == .snapshot {
                            guard let value = response.response, inference != nil else { throw BridgeError.invalidResponse }
                            onSnapshot?(value)
                        } else { return response }
                    }
                    throw BridgeError.invalidResponse
                }
                group.addTask { try await Task.sleep(for: .seconds(inference == nil ? 30 : 300)); throw BridgeError.unavailable }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw BridgeError.invalidResponse }
                return result
            }
        } catch {
            pending[id] = nil; pair.continuation.finish(throwing: error)
            let cancel = ConsoleModelRequest(id: id, instanceID: instanceID, action: .cancel)
            Task { try? await context.remote.send(.init(kind: "models.request", payload: ConsoleWire.encode(cancel), proof: proof), to: instance.hostDeviceID) }
            throw error
        }
    }
    func catalog(instanceID: UUID) async throws -> [ProviderModelOption] {
        let result = try await request(instanceID: instanceID, inference: nil, onSnapshot: nil)
        guard result.event == .catalog, let models = result.models else { throw BridgeError.invalidResponse }
        return models
    }
    func infer(instanceID: UUID, request: SloppyInferenceRequest, onSnapshot: (@Sendable (SloppyInferenceResponse) -> Void)?) async throws -> SloppyInferenceResponse {
        let result = try await self.request(instanceID: instanceID, inference: request, onSnapshot: onSnapshot)
        guard result.event == .complete, let response = result.response else { throw BridgeError.invalidResponse }
        return response
    }
}
