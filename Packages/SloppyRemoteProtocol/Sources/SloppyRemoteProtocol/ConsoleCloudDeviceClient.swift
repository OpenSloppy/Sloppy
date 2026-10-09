import Crypto
import Foundation
import SloppyConsoleProtocol
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public actor ConsoleCloudDeviceClient {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)
    public struct Directory: Codable, Sendable {
        public var account: ConsoleAccount
        public var instances: [InstanceBinding]
        public var devices: [ConsoleDevice]
        public var grants: [DeviceGrant]
    }
    private let baseURL: URL
    private let deviceID: UUID
    private let privateKey: Data
    private let transport: Transport
    private var token: String?
    private var expiresAt = Date.distantPast
    public init(baseURL: URL, deviceID: UUID, privateKey: Data) {
        self.baseURL = baseURL; self.deviceID = deviceID; self.privateKey = privateKey
        transport = { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }
    init(baseURL: URL, deviceID: UUID, privateKey: Data, transport: @escaping Transport) {
        self.baseURL = baseURL; self.deviceID = deviceID; self.privateKey = privateKey; self.transport = transport
    }
    public func trust(instanceID: UUID) async throws -> ConsoleTrustSnapshot {
        try await authenticate()
        return try await request("v1/instances/\(instanceID)/trust")
    }
    public func directory() async throws -> Directory {
        try await authenticate()
        return try await request("v1/me")
    }
    public func proof(instanceID: UUID) async throws -> SignedInstanceAccessProof {
        try await authenticate()
        struct Request: Encodable { var deviceID: UUID }
        return try await request("v1/instances/\(instanceID)/proof", body: ConsoleWire.encode(Request(deviceID: deviceID)))
    }
    private func authenticate() async throws {
        guard expiresAt < Date().addingTimeInterval(30) else { return }
        struct Challenge: Decodable { var id: UUID; var nonce: Data }
        struct SessionRequest: Encodable { var challengeID: UUID; var signature: Data }
        struct SessionResponse: Decodable { var accessToken: String }
        let challenge: Challenge = try await request("v1/host-auth/challenge", body: ConsoleWire.encode(["deviceID": deviceID.uuidString]), authorized: false)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
        let response: SessionResponse = try await request("v1/host-auth/session", body: ConsoleWire.encode(SessionRequest(challengeID: challenge.id, signature: key.signature(for: challenge.nonce))), authorized: false)
        token = response.accessToken; expiresAt = Date().addingTimeInterval(300)
    }
    private func request<T: Decodable>(_ path: String, body: Data? = nil, authorized: Bool = true) async throws -> T {
        guard baseURL.scheme == "https", baseURL.user == nil, baseURL.password == nil else { throw RemoteTLSError.invalidPeer }
        var request = URLRequest(url: baseURL.appendingPathComponent(path)); request.httpMethod = body == nil ? "GET" : "POST"; request.httpBody = body; request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authorized, let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let (data, status) = try await transport(request)
        guard status == 200 else { expiresAt = .distantPast; throw RemoteTLSError.invalidPeer }
        return try ConsoleWire.decode(T.self, from: data)
    }
}
