import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Separate service credential, not a user's Console cookie or Core token.
public struct ConsoleRelayAuthority: Sendable {
    public let baseURL: URL
    private let serviceSecret: String
    public init(baseURL: URL, serviceSecret: String) throws {
        guard baseURL.scheme == "https", baseURL.host != nil, baseURL.user == nil, baseURL.password == nil, serviceSecret.utf8.count >= 32 else { throw ManagedRelayError.forbidden }
        self.baseURL = baseURL; self.serviceSecret = serviceSecret
    }
    public func authorize(deviceID: UUID, peerID: UUID? = nil, byteCount: Int64 = 0) async -> Bool {
        struct Request: Encodable { var deviceID: UUID; var peerID: UUID?; var byteCount: Int64 }
        struct Response: Decodable { var allowed: Bool }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/internal/relay/authorize"))
        request.httpMethod = "POST"; request.timeoutInterval = 5
        request.setValue("Bearer " + serviceSecret, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(Request(deviceID: deviceID, peerID: peerID, byteCount: byteCount))
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForResource = 5
        let session = URLSession(configuration: config, delegate: ConsoleNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse, http.statusCode == 200,
              let result = try? JSONDecoder().decode(Response.self, from: data) else { return false }
        return result.allowed
    }
}

private final class ConsoleNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
