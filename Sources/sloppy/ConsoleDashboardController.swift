import Foundation
import SloppyConsoleProtocol
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum ConsoleDashboardError: Error {
    case unauthorized, conflict, expired, unavailable, cloud(Int)
    var code: String {
        switch self {
        case .unauthorized: "console_sign_in_required"
        case .conflict: "console_environment_or_owner_conflict"
        case .expired: "console_login_expired"
        case .unavailable: "console_unavailable"
        case .cloud(let status): status == 401 ? "console_sign_in_required" : status == 403 ? "console_mfa_or_access_required" : "console_request_failed"
        }
    }
}

/// Owner-scoped BFF for the local Dashboard. Neither OAuth token is returned
/// to JavaScript. Only allowlisted Console environments can be contacted.
actor ConsoleDashboardController {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)
    struct Session: Codable, Sendable {
        var ownerID: String
        var environment: ConsoleEnvironment
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
    }
    struct Login: Codable, Sendable {
        var id: UUID
        var userCode: String
        var verificationURL: URL
        var expiresAt: Date
        var interval: Int
    }
    private struct Pending { var login: Login; var owner: String; var environment: ConsoleEnvironment; var upstreamID: String; var lastPoll: Date }
    private struct Tokens: Decodable { var accessToken: String; var refreshToken: String; var expiresIn: Int }
    struct AccountSnapshot: Decodable, Sendable { var account: ConsoleAccount; var devices: [ConsoleDevice]; var instances: [InstanceBinding]; var proposals: [AccessProposal] }
    private let file: URL
    private let transport: Transport
    private var session: Session?
    private var pending: Pending?
    private var refreshTask: Task<Session, Error>?
    private var proposal: (AccessProposal, ConsoleEnvironment, String)?

    init(file: URL, transport: @escaping Transport = ConsoleDashboardController.network) throws {
        self.file = file; self.transport = transport
        if FileManager.default.fileExists(atPath: file.path) {
            session = try ConsoleWire.decode(Session.self, from: Data(contentsOf: file))
        }
    }
    func hasSession(owner: String, environment: ConsoleEnvironment) -> Bool { session?.ownerID == owner && session?.environment == environment }
    func account(owner: String, environment: ConsoleEnvironment) async throws -> AccountSnapshot {
        try await fetch("v1/me", owner: owner, environment: environment)
    }
    func start(owner: String, environment: ConsoleEnvironment) async throws -> Login {
        if let session, session.ownerID != owner { throw ConsoleDashboardError.conflict }
        if let pending, pending.owner != owner { throw ConsoleDashboardError.conflict }
        struct Start: Decodable { var flowID: String; var userCode: String; var verificationURL: URL; var expiresIn: Int; var interval: Int }
        let value: Start = try await send("v1/auth/device/start", environment: environment, method: "POST", body: Data("{}".utf8))
        let expectedHost = environment == .test ? "auth-test.sloppy.team" : "auth.sloppy.team"
        guard value.verificationURL.scheme == "https", value.verificationURL.host == expectedHost,
              value.verificationURL.user == nil, value.verificationURL.password == nil else { throw ConsoleDashboardError.unavailable }
        let login = Login(id: UUID(), userCode: value.userCode, verificationURL: value.verificationURL,
            expiresAt: Date().addingTimeInterval(Double(min(value.expiresIn, 600))), interval: max(value.interval, 5))
        pending = Pending(login: login, owner: owner, environment: environment, upstreamID: value.flowID, lastPoll: .distantPast)
        proposal = nil
        return login
    }
    func poll(id: UUID, owner: String, environment: ConsoleEnvironment) async throws -> Bool {
        guard var current = pending, current.owner == owner, current.environment == environment, current.login.id == id else { throw ConsoleDashboardError.unauthorized }
        guard current.login.expiresAt > Date() else { pending = nil; throw ConsoleDashboardError.expired }
        guard Date().timeIntervalSince(current.lastPoll) >= Double(current.login.interval) else { return false }
        current.lastPoll = Date(); pending = current
        struct Result: Decodable { var accessToken: String?; var refreshToken: String?; var expiresIn: Int?; var status: String? }
        let value: Result = try await send("v1/auth/device/poll", environment: environment, method: "POST", body: ConsoleWire.encode(["flowID": current.upstreamID]))
        guard pending?.login.id == id else { throw ConsoleDashboardError.expired }
        guard let access = value.accessToken, let refresh = value.refreshToken else { return false }
        let next = Session(ownerID: owner, environment: environment, accessToken: access, refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(Double(value.expiresIn ?? 3600)))
        try persist(next); session = next; pending = nil
        return true
    }
    func cancel(id: UUID, owner: String) { if pending?.owner == owner && pending?.login.id == id { pending = nil } }
    func prepareBinding(_ binding: InstanceBinding, device: ConsoleDevice, owner: String, environment: ConsoleEnvironment) async throws -> AccessProposal {
        let snapshot = try await account(owner: owner, environment: environment)
        guard snapshot.account.id == binding.ownerID, snapshot.account.personalSpaceID == binding.spaceID else { throw ConsoleDashboardError.conflict }
        if !snapshot.devices.contains(where: { $0.id == device.id }) {
            let _: ConsoleDevice = try await fetch("v1/devices", owner: owner, environment: environment, method: "POST", body: ConsoleWire.encode(device))
        }
        let existing = snapshot.proposals.first { $0.kind == .bindInstance && $0.instanceID == binding.id && $0.actorAccountID == binding.ownerID && $0.expiresAt > Date() }
        let next: AccessProposal
        if let existing { next = existing }
        else { next = try await fetch("v1/instances", owner: owner, environment: environment, method: "POST", body: ConsoleWire.encode(binding)) }
        let reviewed = try ConsoleWire.decode(InstanceBinding.self, from: next.payload)
        guard next.kind == .bindInstance, next.targetID == binding.id, next.instanceID == binding.id,
              next.actorAccountID == binding.ownerID, next.expiresAt > Date(),
              reviewed.id == binding.id, reviewed.ownerID == binding.ownerID, reviewed.spaceID == binding.spaceID,
              reviewed.authorityPublicKey == binding.authorityPublicKey, reviewed.hostDeviceID == binding.hostDeviceID,
              reviewed.hostCertificateFingerprint == binding.hostCertificateFingerprint else { throw ConsoleDashboardError.conflict }
        proposal = (next, environment, owner)
        return next
    }
    func reviewedProposal(id: UUID, owner: String, environment: ConsoleEnvironment) throws -> AccessProposal {
        guard let current = proposal, current.0.id == id, current.1 == environment, current.2 == owner else { throw ConsoleDashboardError.unauthorized }
        guard current.0.expiresAt > Date() else { throw ConsoleDashboardError.expired }
        return current.0
    }
    func approve(_ signed: SignedAccessProposal, owner: String, environment: ConsoleEnvironment) async throws -> Data {
        let current = try reviewedProposal(id: signed.proposal.id, owner: owner, environment: environment)
        guard current == signed.proposal else { throw ConsoleDashboardError.conflict }
        struct Key: Decodable { var publicKey: String }
        let key: Key = try await fetch("v1/proof-key", owner: owner, environment: environment)
        guard let bytes = Data(base64Encoded: key.publicKey), bytes.count == 32 else { throw ConsoleDashboardError.unavailable }
        try await fetchEmpty("v1/proposals/approve", owner: owner, environment: environment, method: "POST", body: ConsoleWire.encode(signed))
        proposal = nil
        return bytes
    }
    func unbind(instanceID: UUID, owner: String, environment: ConsoleEnvironment) async throws {
        let snapshot = try await account(owner: owner, environment: environment)
        guard snapshot.instances.contains(where: { $0.id == instanceID && $0.ownerID == snapshot.account.id }) else { throw ConsoleDashboardError.unauthorized }
        try await fetchEmpty("v1/instances/" + instanceID.uuidString, owner: owner, environment: environment, method: "DELETE")
        proposal = nil
    }
    func signOut(owner: String, environment: ConsoleEnvironment) async throws {
        if let session, session.ownerID != owner || session.environment != environment { throw ConsoleDashboardError.conflict }
        if session != nil { try? await fetchEmpty("v1/auth/logout", owner: owner, environment: environment, method: "POST") }
        try persist(nil); session = nil; pending = nil; proposal = nil
    }
    private func credential(owner: String, environment: ConsoleEnvironment) async throws -> Session {
        guard let current = session, current.ownerID == owner, current.environment == environment else { throw ConsoleDashboardError.unauthorized }
        if current.expiresAt > Date().addingTimeInterval(30) { return current }
        let task: Task<Session, Error>
        if let existing = refreshTask { task = existing } else {
            task = Task {
                let value: Tokens = try await self.send("v1/auth/native/refresh", environment: environment, method: "POST", body: ConsoleWire.encode(["refreshToken": current.refreshToken]))
                return Session(ownerID: owner, environment: environment, accessToken: value.accessToken, refreshToken: value.refreshToken, expiresAt: Date().addingTimeInterval(Double(value.expiresIn)))
            }
            refreshTask = task
        }
        do {
            let next = try await task.value
            if session?.ownerID == owner, session?.environment == environment, session?.refreshToken == next.refreshToken { return next }
            guard session?.ownerID == owner, session?.environment == environment, session?.refreshToken == current.refreshToken else { throw ConsoleDashboardError.conflict }
            try persist(next); session = next; refreshTask = nil; return next
        } catch {
            refreshTask = nil
            if case ConsoleDashboardError.cloud(401) = error, session?.refreshToken == current.refreshToken {
                try persist(nil); session = nil
            }
            throw error
        }
    }
    private func fetch<T: Decodable>(_ path: String, owner: String, environment: ConsoleEnvironment, method: String = "GET", body: Data? = nil) async throws -> T {
        let token = try await credential(owner: owner, environment: environment).accessToken
        do { return try await send(path, environment: environment, method: method, body: body, token: token) }
        catch {
            if case ConsoleDashboardError.cloud(401) = error, session?.accessToken == token {
                try persist(nil); session = nil
            }
            throw error
        }
    }
    private func fetchEmpty(_ path: String, owner: String, environment: ConsoleEnvironment, method: String, body: Data? = nil) async throws {
        let token = try await credential(owner: owner, environment: environment).accessToken
        _ = try await data(path, environment: environment, method: method, body: body, token: token)
    }
    private func send<T: Decodable>(_ path: String, environment: ConsoleEnvironment, method: String = "GET", body: Data? = nil, token: String? = nil) async throws -> T {
        try ConsoleWire.decode(T.self, from: await data(path, environment: environment, method: method, body: body, token: token))
    }
    private func data(_ path: String, environment: ConsoleEnvironment, method: String, body: Data?, token: String?) async throws -> Data {
        var request = URLRequest(url: environment.consoleURL.appendingPathComponent(path)); request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let (data, status) = try await transport(request)
        guard (200..<300).contains(status) else { throw ConsoleDashboardError.cloud(status) }
        return data
    }
    private func persist(_ session: Session?) throws {
        if let session {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try ConsoleWire.encode(session).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } else if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
    static func network(_ request: URLRequest) async throws -> (Data, Int) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 25
        let session = URLSession(configuration: configuration, delegate: ConsoleDashboardNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard data.count <= 2 * 1024 * 1024, let response = response as? HTTPURLResponse else { throw ConsoleDashboardError.unavailable }
        return (data, response.statusCode)
    }
}

private final class ConsoleDashboardNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

extension CoreService {
    func dashboardConsole() throws -> ConsoleDashboardController {
        if let consoleDashboardController { return consoleDashboardController }
        let controller = try ConsoleDashboardController(file: workspaceRootURL.appendingPathComponent("console-dashboard-session.json"))
        consoleDashboardController = controller
        return controller
    }
}
