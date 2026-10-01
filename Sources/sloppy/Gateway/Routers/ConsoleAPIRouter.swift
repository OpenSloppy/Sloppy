import Foundation
import Protocols
import SloppyConsoleProtocol
import SloppyRemoteProtocol

struct ConsoleAPIRouter: APIRouter {
    let service: CoreService
    func configure(on router: CoreRouterRegistrar) {
        router.get("/v1/console/identity", metadata: RouteMetadata(summary: "Local Console identity", description: "Returns the local instance identity to its authenticated local owner", tags: ["Console"])) { request in
            guard await localOwner(request), let store = await service.consoleTrustStore else { return denied() }
            do {
                let local = await store.identity()
                let certificate = try await service.consoleTLSIdentity()
                struct Identity: Encodable { var instanceID: UUID; var deviceID: UUID; var signingPublicKey: Data; var certificateDER: Data }
                return CoreRouter.encodable(status: 200, payload: Identity(instanceID: local.instanceID, deviceID: local.deviceID, signingPublicKey: local.signingPublicKey, certificateDER: certificate.certificateDER))
            } catch { return denied() }
        }
        router.post("/v1/console/approve", metadata: RouteMetadata(summary: "Sign Console proposal", description: "The local owner confirms the exact proposal reviewed in Sloppy", tags: ["Console"])) { request in
            guard await localOwner(request), let store = await service.consoleTrustStore, let body = request.body else { return denied() }
            do {
                let proposal = try ConsoleWire.decode(AccessProposal.self, from: body)
                let signed = try await store.sign(proposal)
                return CoreRouterResponse(status: 200, body: try ConsoleWire.encode(signed), contentType: "application/json")
            } catch { return denied() }
        }
        router.post("/v1/console/binding", metadata: RouteMetadata(summary: "Install confirmed Console binding", description: "Pins the Console proof key after a locally signed binding", tags: ["Console"])) { request in
            guard await localOwner(request), let store = await service.consoleTrustStore, let body = request.body else { return denied() }
            struct Install: Decodable { var signed: SignedAccessProposal; var consolePublicKey: Data }
            do { let payload = try ConsoleWire.decode(Install.self, from: body); try await store.installBinding(payload.signed, consolePublicKey: payload.consolePublicKey); await service.startConsoleRelayIfBound(); return CoreRouter.json(status: 200, payload: ["status": "bound"]) }
            catch { return denied() }
        }
        router.post("/v1/console/trust", metadata: RouteMetadata(summary: "Synchronize signed Console trust", description: "Accepts signed grants and monotonic revocations without trusting directory keys", tags: ["Console"])) { request in
            guard await localOwner(request), let store = await service.consoleTrustStore, let body = request.body else { return denied() }
            do { try await store.synchronize(ConsoleWire.decode(ConsoleTrustSnapshot.self, from: body)); return CoreRouter.json(status: 200, payload: ["status": "synchronized"]) }
            catch { return denied() }
        }
        router.post("/v1/console/migration", metadata: RouteMetadata(summary: "Confirm legacy account migration", description: "The local admin maps active users to approved Console accounts and confirms backup pairing", tags: ["Console"])) { request in
            guard await localOwner(request), let store = await service.consoleTrustStore, let body = request.body,
                  let actor = await CoreRouter.identityActor(for: request, service: service) else { return denied() }
            do {
                let users = try await service.listIdentityUsers(actor: actor)
                let migration = try ConsoleWire.decode(ConsoleAccountMigration.self, from: body)
                try await store.confirmMigration(migration, activeLocalUserIDs: Set(users.filter { $0.status == .active }.map(\.id)))
                return CoreRouter.json(status: 200, payload: ["status": "migrated"])
            } catch { return denied() }
        }
        router.delete("/v1/console/binding", metadata: RouteMetadata(summary: "Unbind Console locally", description: "Revokes local cloud grants without deleting instance data", tags: ["Console"])) { request in
            guard await localOwner(request), let store = await service.consoleTrustStore else { return denied() }
            do { try await store.unbind(); return CoreRouter.json(status: 200, payload: ["status": "unbound"]) } catch { return denied() }
        }
    }
    private func localOwner(_ request: HTTPRequest) async -> Bool {
        guard let address = request.remoteAddress, address.hasPrefix("127.0.0.1") || address.hasPrefix("[::1]") || address == "::1" else { return false }
        if let origin = request.header("origin"), let url = URL(string: origin), !["localhost", "127.0.0.1", "::1"].contains(url.host ?? "") { return false }
        if await service.identityAuthEnabled() { return await CoreRouter.identityActor(for: request, service: service)?.user.role == .admin }
        return await service.validateDashboardAuthorizationHeader(request.header("authorization"))
    }
    private func denied() -> CoreRouterResponse { CoreRouter.json(status: 403, payload: ["error": "local_owner_required"]) }
}
