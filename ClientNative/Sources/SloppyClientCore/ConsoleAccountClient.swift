import Crypto
import Foundation
import Security
@_exported import SloppyConsoleProtocol
import SloppyRemoteProtocol

public enum ConsoleAccountError: LocalizedError, Sendable, Equatable {
    case signInRequired, identityVerificationRequired, accessDenied, unavailable, deviceApprovalRequired, deviceRevoked

    public var errorDescription: String? {
        switch self {
        case .signInRequired: "Your Console session expired. Sign in to continue."
        case .identityVerificationRequired: "Confirm your identity with your passkey or authenticator code to continue."
        case .accessDenied: "Console denied access. Check that this instance belongs to the signed-in account."
        case .unavailable: "Console is unavailable. Try again when the connection is restored."
        case .deviceApprovalRequired: "This device is registered in Sloppy Cloud. Approve its access to this server in Console → Mesh & devices, then refresh."
        case .deviceRevoked: "This device’s access was revoked in Console. Contact the server owner to restore access."
        }
    }

    static func response(status: Int, data: Data) -> Self {
        struct Failure: Decodable { var error: String }
        if status == 401 { return .signInRequired }
        if status == 403 {
            return (try? JSONDecoder().decode(Failure.self, from: data))?.error == "identityVerificationRequired"
                ? .identityVerificationRequired : .accessDenied
        }
        return .unavailable
    }
}

public actor ConsoleAccountClient {
    public static let shared = ConsoleAccountClient()
    public static let consoleURL = URL(string: "https://console.sloppy.team")!
    public struct Snapshot: Codable, Sendable {
        public var account: ConsoleAccount
        public var organizations: [ConsoleOrganization]
        public var devices: [ConsoleDevice]
        public var instances: [InstanceBinding]
        public var grants: [DeviceGrant]
        public var proposals: [AccessProposal]
        public var entitlement: ConsoleEntitlement
    }
    private struct StoredSession: Codable { var accessToken: String; var refreshToken: String?; var expiresAt: Date? }
    private struct Tokens: Decodable, Sendable { var accessToken: String; var refreshToken: String? }
    private var token: String?
    private var refreshToken: String?
    private var tokenExpiresAt = Date.distantPast
    private var refreshTask: Task<Tokens, any Error>?
    private var snapshotTask: Task<Snapshot, any Error>?
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let transport: Transport?
    private let deviceCredential: @Sendable () throws -> ConsoleDeviceCredential
    private let deviceName: String

    public static var currentDeviceName: String {
        #if os(iOS)
        "Sloppy iOS"
        #elseif os(macOS)
        String("Sloppy macOS · \(ProcessInfo.processInfo.hostName)".prefix(80))
        #elseif os(visionOS)
        "Sloppy visionOS"
        #elseif os(watchOS)
        "Sloppy watchOS"
        #else
        "Sloppy Client"
        #endif
    }
    public init() {
        transport = nil
        deviceCredential = { try ConsoleDeviceCredential.createIfNeeded() }
        deviceName = Self.currentDeviceName
        let stored = Self.loadSession(); token = stored?.accessToken; refreshToken = stored?.refreshToken; tokenExpiresAt = stored?.expiresAt ?? .distantPast
    }
    init(token: String, deviceName: String, credential: ConsoleDeviceCredential, transport: @escaping Transport) {
        self.token = token
        self.deviceName = deviceName
        self.deviceCredential = { credential }
        self.transport = transport
        tokenExpiresAt = .distantFuture
    }
    public func isSignedIn() -> Bool { token != nil }
    public func loginURL(verifier: String, state: String, stepUp: Bool = true) -> URL {
        var url = URLComponents(url: Self.consoleURL.appendingPathComponent("auth/start"), resolvingAgainstBaseURL: false)!
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        url.queryItems = [.init(name: "client_challenge", value: challenge), .init(name: "client_state", value: state), .init(name: "redirect_uri", value: "sloppy://console-login"), .init(name: "step_up", value: stepUp ? "1" : "0")]
        return url.url!
    }
    public func exchange(callback: URL, verifier: String, state: String) async throws {
        let params = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard callback.scheme == "sloppy", callback.host == "console-login", params.first(where: { $0.name == "state" })?.value == state,
              let code = params.first(where: { $0.name == "code" })?.value else { throw ConsoleTrustError.invalidSignature }
        struct Exchange: Encodable { var code: String; var verifier: String }
        let tokens: Tokens = try await request("v1/auth/native/exchange", method: "POST", body: ConsoleWire.encode(Exchange(code: code, verifier: verifier)), authenticated: false)
        token = tokens.accessToken; refreshToken = tokens.refreshToken; tokenExpiresAt = Date().addingTimeInterval(3600)
        try Self.saveSession(StoredSession(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken, expiresAt: tokenExpiresAt))
        _ = try await snapshot()
    }
    public func proof(instanceID: UUID, deviceID: UUID, organizationID: UUID?) async throws -> SignedInstanceAccessProof {
        struct ProofRequest: Encodable { var deviceID: UUID; var organizationID: UUID? }
        return try await request("v1/instances/\(instanceID)/proof", method: "POST", body: ConsoleWire.encode(ProofRequest(deviceID: deviceID, organizationID: organizationID)))
    }
    public func snapshot() async throws -> Snapshot {
        if let task = snapshotTask { return try await task.value }
        let task = Task { try await registeredSnapshot() }
        snapshotTask = task
        do {
            let value = try await task.value
            snapshotTask = nil
            return value
        } catch {
            snapshotTask = nil
            throw error
        }
    }
    private func registeredSnapshot() async throws -> Snapshot {
        var current: Snapshot = try await request("v1/me")
        let credential = try deviceCredential()
        let existing = current.devices.first(where: { $0.id == credential.deviceID })
        if let device = existing {
            guard device.accountID == current.account.id,
                  device.signingPublicKey == credential.tls.signingPublicKey,
                  device.certificateDER == credential.tls.certificateDER else { throw ConsoleAccountError.accessDenied }
            guard device.status != .revoked else { throw ConsoleAccountError.deviceRevoked }
            // Migrate the old generic label while keeping user-assigned names.
            guard device.name == "Sloppy Client" || device.name == deviceName else { return current }
            if device.name == deviceName { return current }
        }
        let device = ConsoleDevice(id: credential.deviceID, accountID: current.account.id, name: deviceName,
                                   signingPublicKey: credential.tls.signingPublicKey, certificateDER: credential.tls.certificateDER)
        let registered: ConsoleDevice
        do {
            registered = try await request("v1/devices", method: "POST", body: ConsoleWire.encode(device))
        } catch {
            // Older Console versions reject an existing ID. A cosmetic rename
            // must not block access; missing enrollment still fails and retries.
            if existing != nil { return current }
            throw error
        }
        current.devices.removeAll { $0.id == registered.id }
        current.devices.append(registered)
        return current
    }
    public func signOut() async throws {
        _ = try? await rawRequest("v1/auth/logout", method: "POST")
        token = nil; refreshToken = nil; try Self.saveSession(nil)
        await ConsoleRemoteClientRegistry.shared.disconnectAll()
    }
    public func bind(localCoreURL: URL) async throws {
        let snapshot = try await snapshot()
        let core = BackendHTTPClient(baseURL: localCoreURL)
        struct LocalIdentity: Decodable { var instanceID: UUID; var deviceID: UUID; var signingPublicKey: Data; var certificateDER: Data }
        let local = try ConsoleWire.decode(LocalIdentity.self, from: await core.getData("/v1/console/identity"))
        if !snapshot.devices.contains(where: { $0.id == local.deviceID }) {
            let device = ConsoleDevice(id: local.deviceID, accountID: snapshot.account.id, name: "Sloppy Host", signingPublicKey: local.signingPublicKey, certificateDER: local.certificateDER)
            let _: ConsoleDevice = try await request("v1/devices", method: "POST", body: ConsoleWire.encode(device))
        }
        let binding = InstanceBinding(id: local.instanceID, ownerID: snapshot.account.id, spaceID: snapshot.account.personalSpaceID, name: "Sloppy Instance", authorityPublicKey: local.signingPublicKey, hostDeviceID: local.deviceID, hostCertificateFingerprint: ConsoleTrust.fingerprint(local.certificateDER))
        let proposal: AccessProposal = try await request("v1/instances", method: "POST", body: ConsoleWire.encode(binding))
        try await approve(proposal, localCoreURL: localCoreURL)
    }
    public func approve(_ proposal: AccessProposal, localCoreURL: URL) async throws {
        let core = BackendHTTPClient(baseURL: localCoreURL)
        let signed = try ConsoleWire.decode(SignedAccessProposal.self, from: await core.postData("/v1/console/approve", data: ConsoleWire.encode(proposal)))
        _ = try await rawRequest("v1/proposals/approve", method: "POST", body: ConsoleWire.encode(signed))
        if proposal.kind == .bindInstance {
            struct Key: Decodable { var publicKey: String }; let key: Key = try await request("v1/proof-key")
            guard let publicKey = Data(base64Encoded: key.publicKey) else { throw ConsoleTrustError.invalidConfiguration }
            struct Install: Encodable { var signed: SignedAccessProposal; var consolePublicKey: Data }
            _ = try await core.postData("/v1/console/binding", data: ConsoleWire.encode(Install(signed: signed, consolePublicKey: publicKey)))
        }
        if let instanceID = proposal.instanceID {
            let trust: ConsoleTrustSnapshot = try await request("v1/instances/\(instanceID)/trust")
            _ = try await core.postData("/v1/console/trust", data: ConsoleWire.encode(trust))
        }
    }
    public func revoke(deviceID: UUID) async throws { _ = try await rawRequest("v1/devices/\(deviceID)", method: "DELETE") }
    public func unbind(instanceID: UUID, localCoreURL: URL) async throws {
        _ = try await rawRequest("v1/instances/\(instanceID)", method: "DELETE")
        try await BackendHTTPClient(baseURL: localCoreURL).delete("/v1/console/binding")
    }
    private func request<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil, authenticated: Bool = true) async throws -> T {
        try ConsoleWire.decode(T.self, from: await rawRequest(path, method: method, body: body, authenticated: authenticated))
    }
    private func rawRequest(_ path: String, method: String = "GET", body: Data? = nil, authenticated: Bool = true) async throws -> Data {
        var request = URLRequest(url: Self.consoleURL.appendingPathComponent(path)); request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated { try await refreshIfNeeded(); guard let token else { throw ConsoleAccountError.signInRequired }; request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let data: Data, http: HTTPURLResponse
        if let transport {
            (data, http) = try await transport(request)
        } else {
            let session = URLSession(configuration: .ephemeral, delegate: ConsoleAccountNoRedirect(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (value, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw ConsoleAccountError.unavailable }
            (data, http) = (value, response)
        }
        guard (200..<300).contains(http.statusCode) else { throw ConsoleAccountError.response(status: http.statusCode, data: data) }
        return data
    }
    public static func randomToken() -> String {
        Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "team.sloppy.console", kSecAttrAccount as String: "session"] }
    private static func loadSession() -> StoredSession? {
        var query = query; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?; guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        if let stored = try? ConsoleWire.decode(StoredSession.self, from: data) { return stored }
        return String(data: data, encoding: .utf8).map { StoredSession(accessToken: $0, refreshToken: nil, expiresAt: nil) }
    }
    private func refreshIfNeeded() async throws {
        guard tokenExpiresAt < Date().addingTimeInterval(30), let refreshToken else { return }
        let task: Task<Tokens, any Error>
        if let running = refreshTask { task = running }
        else {
            task = Task {
                try await request("v1/auth/native/refresh", method: "POST", body: ConsoleWire.encode(["refreshToken": refreshToken]), authenticated: false)
            }
            refreshTask = task
        }
        do {
            let tokens = try await task.value; token = tokens.accessToken; self.refreshToken = tokens.refreshToken; tokenExpiresAt = Date().addingTimeInterval(3600)
            try Self.saveSession(StoredSession(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken, expiresAt: tokenExpiresAt)); refreshTask = nil
        } catch { refreshTask = nil; throw error }
    }

    private static func saveSession(_ stored: StoredSession?) throws {
        SecItemDelete(query as CFDictionary)
        guard let stored else { return }
        var value = query; value[kSecValueData as String] = try ConsoleWire.encode(stored); value[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(value as CFDictionary, nil) == errSecSuccess else { throw ConsoleTrustError.invalidConfiguration }
    }
}

private final class ConsoleAccountNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
