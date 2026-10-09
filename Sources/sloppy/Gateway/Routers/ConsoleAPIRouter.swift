import Foundation
import Protocols
import SloppyConsoleProtocol
import SloppyRemoteProtocol

struct ConsoleAPIRouter: APIRouter {
    let service: CoreService
    func configure(on router: CoreRouterRegistrar) {
        router.get("/v1/console/model-instances", metadata: RouteMetadata(summary: "Console model instances", description: "Lists the bound Core's Console instances and existing device model access; never grants access or returns credentials", tags: ["Console"])) { request in
            guard await localOwner(request) else { return denied() }
            do { return CoreRouter.encodable(status: 200, payload: try await service.consoleModelInstances()) }
            catch { return CoreRouter.json(status: 409, payload: ["error": "console_model_instances_unavailable", "message": error.localizedDescription]) }
        }
        router.get("/v1/console/account", metadata: RouteMetadata(summary: "Local Console account", description: "Returns metadata only, never OAuth credentials", tags: ["Console"])) { request in
            guard let owner = await accountOwner(request), let environment = environment(request.query["environment"]), let store = await service.consoleTrustStore else { return denied() }
            do {
                let controller = try await service.dashboardConsole()
                let binding = await store.binding()
                let boundEnvironment = await store.environment()
                struct Status: Encodable { var environment: ConsoleEnvironment; var consoleURL: URL; var relayURL: URL; var signedIn: Bool; var account: ConsoleAccount?; var binding: InstanceBinding?; var boundEnvironment: ConsoleEnvironment? }
                var signedIn = await controller.hasSession(owner: owner, environment: environment)
                var account: ConsoleAccount?
                if signedIn {
                    do { account = try await controller.account(owner: owner, environment: environment).account }
                    catch ConsoleDashboardError.cloud(401) { signedIn = false }
                }
                return CoreRouterResponse(status: 200, body: try ConsoleWire.encode(Status(environment: environment, consoleURL: environment.consoleURL, relayURL: environment.relayURL, signedIn: signedIn, account: account, binding: binding, boundEnvironment: binding == nil ? nil : boundEnvironment)), contentType: "application/json")
            } catch { return accountError(error) }
        }
        router.post("/v1/console/account/login", metadata: RouteMetadata(summary: "Start Console sign-in", description: "Starts owner-scoped device authorization", tags: ["Console"])) { request in
            struct Start: Decodable { var environment: ConsoleEnvironment }
            guard let owner = await accountOwner(request), let input = request.decode(Start.self), await allowedEnvironment(input.environment) else { return denied() }
            do { return CoreRouterResponse(status: 200, body: try ConsoleWire.encode(await service.dashboardConsole().start(owner: owner, environment: input.environment)), contentType: "application/json") }
            catch { return accountError(error) }
        }
        router.post("/v1/console/account/poll", metadata: RouteMetadata(summary: "Poll Console sign-in", description: "Stores tokens privately in Core after verified identity", tags: ["Console"])) { request in
            struct Poll: Decodable { var environment: ConsoleEnvironment; var id: UUID }
            guard let owner = await accountOwner(request), let input = request.decode(Poll.self), await allowedEnvironment(input.environment) else { return denied() }
            do {
                let ready = try await service.dashboardConsole().poll(id: input.id, owner: owner, environment: input.environment)
                struct Result: Encodable { var signedIn: Bool }
                return CoreRouter.encodable(status: 200, payload: Result(signedIn: ready))
            } catch { return accountError(error) }
        }
        router.post("/v1/console/account/cancel", metadata: RouteMetadata(summary: "Cancel Console sign-in", description: "Cancels only this local owner's pending login", tags: ["Console"])) { request in
            struct Cancel: Decodable { var id: UUID }
            guard let owner = await accountOwner(request), let input = request.decode(Cancel.self) else { return denied() }
            do { await (try service.dashboardConsole()).cancel(id: input.id, owner: owner); return CoreRouter.json(status: 200, payload: ["status": "cancelled"]) }
            catch { return accountError(error) }
        }
        router.post("/v1/console/account/logout", metadata: RouteMetadata(summary: "Sign out of local Console client", description: "Keeps the instance binding and host relay active", tags: ["Console"])) { request in
            struct Logout: Decodable { var environment: ConsoleEnvironment }
            guard let owner = await accountOwner(request), let input = request.decode(Logout.self) else { return denied() }
            do { try await service.dashboardConsole().signOut(owner: owner, environment: input.environment); return CoreRouter.json(status: 200, payload: ["status": "signed_out"]) }
            catch { return accountError(error) }
        }
        router.post("/v1/console/account/binding", metadata: RouteMetadata(summary: "Review Console binding", description: "Prepares an unsigned binding for explicit local-owner review", tags: ["Console"])) { request in
            struct Prepare: Decodable { var environment: ConsoleEnvironment }
            guard let owner = await accountOwner(request), let input = request.decode(Prepare.self), let store = await service.consoleTrustStore, await allowedEnvironment(input.environment), await store.binding()?.status != .active else { return denied() }
            do {
                let controller = try await service.dashboardConsole()
                let account = try await controller.account(owner: owner, environment: input.environment).account
                let local = await store.identity(), certificate = try await service.consoleTLSIdentity()
                let binding = InstanceBinding(id: local.instanceID, ownerID: account.id, spaceID: account.personalSpaceID, name: ProcessInfo.processInfo.hostName, authorityPublicKey: local.signingPublicKey, hostDeviceID: local.deviceID, hostCertificateFingerprint: ConsoleTrust.fingerprint(certificate.certificateDER))
                let device = ConsoleDevice(id: local.deviceID, accountID: account.id, name: binding.name, signingPublicKey: local.signingPublicKey, certificateDER: certificate.certificateDER)
                let proposal = try await controller.prepareBinding(binding, device: device, owner: owner, environment: input.environment)
                struct Review: Encodable { var environment: ConsoleEnvironment; var account: ConsoleAccount; var binding: InstanceBinding; var proposalID: UUID; var expiresAt: Date }
                return CoreRouterResponse(status: 200, body: try ConsoleWire.encode(Review(environment: input.environment, account: account, binding: try ConsoleWire.decode(InstanceBinding.self, from: proposal.payload), proposalID: proposal.id, expiresAt: proposal.expiresAt)), contentType: "application/json")
            } catch { return accountError(error) }
        }
        router.post("/v1/console/account/binding/confirm", metadata: RouteMetadata(summary: "Confirm Console binding", description: "Signs only the exact proposal reviewed by this local owner", tags: ["Console"])) { request in
            struct Confirm: Decodable { var environment: ConsoleEnvironment; var proposalID: UUID; var confirm: Bool }
            guard let owner = await accountOwner(request), let input = request.decode(Confirm.self), input.confirm, let store = await service.consoleTrustStore, await allowedEnvironment(input.environment), await store.binding()?.status != .active else { return denied() }
            do {
                let controller = try await service.dashboardConsole()
                let proposal = try await controller.reviewedProposal(id: input.proposalID, owner: owner, environment: input.environment)
                let signed = try await store.sign(proposal)
                let key = try await controller.approve(signed, owner: owner, environment: input.environment)
                try await store.installBinding(signed, consolePublicKey: key, environment: input.environment)
                await service.startConsoleRelayIfBound()
                return CoreRouter.json(status: 200, payload: ["status": "bound"])
            } catch { return accountError(error) }
        }
        router.post("/v1/console/account/binding/unbind", metadata: RouteMetadata(summary: "Unbind Console", description: "Revokes cloud and local access after explicit owner confirmation", tags: ["Console"])) { request in
            struct Unbind: Decodable { var environment: ConsoleEnvironment; var confirm: Bool }
            guard let owner = await accountOwner(request), let input = request.decode(Unbind.self), input.confirm,
                  let store = await service.consoleTrustStore, let binding = await store.binding(),
                  await allowedEnvironment(input.environment) else { return denied() }
            do {
                try await service.dashboardConsole().unbind(instanceID: binding.id, owner: owner, environment: input.environment)
                await service.stopConsoleRelay()
                try await store.unbind()
                return CoreRouter.json(status: 200, payload: ["status": "unbound"])
            } catch { return accountError(error) }
        }
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
            struct Install: Decodable { var signed: SignedAccessProposal; var consolePublicKey: Data; var environment: ConsoleEnvironment? }
            do { let payload = try ConsoleWire.decode(Install.self, from: body); try await store.installBinding(payload.signed, consolePublicKey: payload.consolePublicKey, environment: payload.environment ?? .production); await service.startConsoleRelayIfBound(); return CoreRouter.json(status: 200, payload: ["status": "bound"]) }
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
            do { await service.stopConsoleRelay(); try await store.unbind(); return CoreRouter.json(status: 200, payload: ["status": "unbound"]) } catch { return denied() }
        }
    }
    private func environment(_ value: String?) -> ConsoleEnvironment? { value.flatMap(ConsoleEnvironment.init(rawValue:)) ?? (value == nil ? .test : nil) }
    private func allowedEnvironment(_ environment: ConsoleEnvironment) async -> Bool {
        guard let store = await service.consoleTrustStore, await store.binding() != nil else { return true }
        return await store.environment() == environment
    }
    private func accountOwner(_ request: HTTPRequest) async -> String? {
        guard await localOwner(request) else { return nil }
        if await service.identityAuthEnabled() { return await CoreRouter.identityActor(for: request, service: service)?.user.id }
        return "local-owner"
    }
    private func accountError(_ error: Error) -> CoreRouterResponse {
        let code = (error as? ConsoleDashboardError)?.code ?? "console_unavailable"
        // Upstream 401 must never clear the local Dashboard identity session.
        return CoreRouter.json(status: 409, payload: ["error": code])
    }
    private func localOwner(_ request: HTTPRequest) async -> Bool {
        guard let address = request.remoteAddress, address.hasPrefix("127.0.0.1") || address.hasPrefix("[::1]") || address == "::1" else { return false }
        if let origin = request.header("origin"), let url = URL(string: origin), !["localhost", "127.0.0.1", "::1"].contains(url.host ?? "") { return false }
        if await service.identityAuthEnabled() { return await CoreRouter.identityActor(for: request, service: service)?.user.role == .admin }
        return await service.validateDashboardAuthorizationHeader(request.header("authorization"))
    }
    private func denied() -> CoreRouterResponse { CoreRouter.json(status: 403, payload: ["error": "local_owner_required"]) }
}
