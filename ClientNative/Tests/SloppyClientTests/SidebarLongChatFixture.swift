import Foundation
import SloppyClientCore

final class SidebarLongChatFixture: @unchecked Sendable {
    let api: SloppyAPIClient
    private let host: String

    init(delayedAgentID: String? = nil, fails: Bool = false) {
        host = "sidebar-agent-\(UUID().uuidString).invalid"
        SidebarLongChatURLProtocol.storage.register(host: host, delayedAgentID: delayedAgentID, fails: fails)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SidebarLongChatURLProtocol.self]
        api = SloppyAPIClient(baseURL: URL(string: "http://\(host)")!,
                             session: URLSession(configuration: configuration),
                             authSessionStore: AuthSessionStore(persistence: .memory))
    }

    var posts: [URLRequest] { SidebarLongChatURLProtocol.storage.posts(host: host) }
}

private final class SidebarLongChatURLProtocol: URLProtocol, @unchecked Sendable {
    static let storage = Storage()
    private var responseWork: DispatchWorkItem?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        var capturedRequest = request
        if capturedRequest.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            capturedRequest.httpBody = data
        }
        let result = Self.storage.response(to: capturedRequest)
        let work = DispatchWorkItem { [weak self] in
            guard let self, let response = HTTPURLResponse(url: url, statusCode: result.status,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else { return }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: result.data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        responseWork = work
        DispatchQueue.global().asyncAfter(deadline: .now() + result.delay, execute: work)
    }

    override func stopLoading() { responseWork?.cancel() }

    final class Storage: @unchecked Sendable {
        private struct Scenario {
            var delayedAgentID: String?
            var fails: Bool
            var posts: [URLRequest] = []
        }
        private let lock = NSLock()
        private var scenarios: [String: Scenario] = [:]

        func register(host: String, delayedAgentID: String?, fails: Bool) {
            lock.lock()
            defer { lock.unlock() }
            scenarios[host] = Scenario(delayedAgentID: delayedAgentID, fails: fails)
        }

        func posts(host: String) -> [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return scenarios[host]?.posts ?? []
        }

        func response(to request: URLRequest) -> (data: Data, status: Int, delay: Double) {
            lock.lock()
            defer { lock.unlock() }
            let host = request.url?.host ?? ""
            guard request.httpMethod == "POST" else { return (Data("[]".utf8), 200, 0) }
            scenarios[host]?.posts.append(request)
            guard request.url?.path.hasSuffix("/long-chat") == true else { return (Data(), 404, 0) }
            if scenarios[host]?.fails == true { return (Data("{}".utf8), 500, 0) }
            let agentID = request.url?.pathComponents.dropLast().last ?? ""
            let summary = ChatSessionSummary(id: "long-\(agentID)", agentId: agentID, title: "Long chat", kind: "long_chat")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            return ((try? encoder.encode(summary)) ?? Data(), 200, scenarios[host]?.delayedAgentID == agentID ? 0.2 : 0)
        }
    }
}
