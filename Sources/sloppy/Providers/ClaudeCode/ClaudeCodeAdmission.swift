import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NIOCore
import NIOHTTP1
import NIOPosix
import PluginSDK
import Protocols

/// Ephemeral loopback gateway: preserves the official CLI's identity and admits
/// exactly one Messages request. Credentials never reach persistence or logs.
actor ClaudeCodeAdmission {
    typealias FixtureTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let nonce = UUID().uuidString
    private let session: URLSession
    private let fixtureTransport: FixtureTransport?
    private let onText: (@Sendable (String) -> Void)?
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var server: Channel?
    private var connections: [Channel] = []
    private var admitted = false
    private var generationAllowed = false
    private var outcome: Result<ClaudeCodeResponse, Error>?
    private var waiter: CheckedContinuation<ClaudeCodeResponse, Error>?
    private var forwarding: Task<Void, Never>?
    private(set) var requestBody: Data?
    private(set) var responseBody = Data()
    private(set) var requestID = UUID().uuidString
    private(set) var createdAt = Date()

    init(session: URLSession, fixtureTransport: FixtureTransport? = nil, onText: (@Sendable (String) -> Void)? = nil) {
        self.session = session
        self.fixtureTransport = fixtureTransport
        self.onText = onText
    }

    func start() async throws -> URL {
        let channel = try await ServerBootstrap(group: group)
            .childChannelInitializer { [self] channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(ClaudeCodeAdmissionHandler(admission: self))
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        server = channel
        guard let port = channel.localAddress?.port, let url = URL(string: "http://127.0.0.1:\(port)/\(nonce)") else {
            throw ClaudeCodeError.invalidStream
        }
        return url
    }

    func handle(head: HTTPRequestHead, body: Data, channel: Channel) async {
        connections.append(channel)
        guard head.method == .POST, head.uri.split(separator: "?", maxSplits: 1).first == "/\(nonce)/v1/messages",
              head.headers.first(name: "origin") == nil, !admitted, body.count <= 32 * 1024 * 1024 else {
            await reject(channel, status: .forbidden)
            return
        }
        guard generationAllowed else {
            finish(.failure(ClaudeCodeError.unsupportedReplay))
            await reject(channel, status: .forbidden)
            return
        }
        admitted = true
        requestBody = body
        createdAt = Date()
        forwarding = Task { [self] in await forward(head: head, body: body, channel: channel) }
    }

    func allowGeneration() { generationAllowed = true }

    func waitForResult() async throws -> ClaudeCodeResponse {
        if let outcome { return try outcome.get() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { waiter = $0 }
        } onCancel: { Task { await self.finish(.failure(CancellationError())) } }
    }

    func resultIfComplete() -> ClaudeCodeResponse? { try? outcome?.get() }

    func stop() async {
        forwarding?.cancel()
        session.invalidateAndCancel()
        finish(.failure(CancellationError()))
        for connection in connections { try? await connection.close().get() }
        if let server { try? await server.close().get() }
        try? await group.shutdownGracefully()
    }

    private func forward(head: HTTPRequestHead, body: Data, channel: Channel) async {
        var responseStarted = false
        do {
            // Fixed destination; the local nonce/path never reaches Anthropic.
            let query = head.uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first
            let suffix = query.map { "?\($0)" } ?? ""
            guard let url = URL(string: "https://api.anthropic.com/v1/messages" + suffix) else { throw ClaudeCodeError.invalidStream }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = body
            request.timeoutInterval = 300
            let excluded = Set(["host", "connection", "content-length", "transfer-encoding", "accept-encoding"])
            for header in head.headers where !excluded.contains(header.name.lowercased()) {
                request.setValue(header.value, forHTTPHeaderField: header.name)
            }
            var parsed = ClaudeCodeResponse()
            if let fixtureTransport {
                let (data, response) = try await fixtureTransport(request)
                guard response.statusCode == 200 else { throw ClaudeCodeError.upstream(response.statusCode) }
                try await sendHead(channel)
                responseStarted = true
                responseBody = data
                for line in String(decoding: data, as: UTF8.self).components(separatedBy: "\n") {
                    try parse(line, into: &parsed)
                }
                try await send(data, channel: channel)
            } else {
#if canImport(FoundationNetworking)
                let (bytes, response) = try await session.linuxBytes(for: request)
#else
                let (bytes, response) = try await session.bytes(for: request)
#endif
                guard let response = response as? HTTPURLResponse else { throw ClaudeCodeError.invalidStream }
                guard response.statusCode == 200 else { throw ClaudeCodeError.upstream(response.statusCode) }
                requestID = response.value(forHTTPHeaderField: "request-id") ?? requestID
                try await sendHead(channel)
                responseStarted = true
                var line = Data()
                for try await byte in bytes {
                    guard responseBody.count < 64 * 1024 * 1024 else { throw ClaudeCodeError.invalidStream }
                    responseBody.append(byte)
                    line.append(byte)
                    if byte == 10 {
                        try Task.checkCancellation()
                        try parse(String(decoding: line.dropLast(), as: UTF8.self), into: &parsed)
                        // Preserve empty lines and CRLF: they delimit SSE frames.
                        try await send(line, channel: channel)
                        line.removeAll(keepingCapacity: true)
                    }
                }
                if !line.isEmpty {
                    try parse(String(decoding: line, as: UTF8.self), into: &parsed)
                    try await send(line, channel: channel)
                }
            }
            guard parsed.complete, !parsed.message.claudeObject.isEmpty else { throw ClaudeCodeError.invalidStream }
            try await channel.writeAndFlush(HTTPServerResponsePart.end(nil)).get()
            finish(.success(parsed))
        } catch {
            finish(.failure(error))
            // Do not echo CLI credentials, prompts, or upstream error bodies.
            if responseStarted { try? await channel.close().get() }
            else { await reject(channel, status: .badGateway) }
        }
    }

    private func parse(_ line: String, into response: inout ClaudeCodeResponse) throws {
        guard line.hasPrefix("data:") else { return }
        let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !json.isEmpty else { return }
        try response.receive(JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
        onText?(response.text)
    }

    private func finish(_ result: Result<ClaudeCodeResponse, Error>) {
        guard outcome == nil else { return }
        outcome = result
        waiter?.resume(with: result)
        waiter = nil
    }

    private func sendHead(_ channel: Channel) async throws {
        let headers = HTTPHeaders([("Content-Type", "text/event-stream"), ("Connection", "close")])
        try await channel.writeAndFlush(HTTPServerResponsePart.head(.init(version: .http1_1, status: .ok, headers: headers))).get()
    }

    private func send(_ data: Data, channel: Channel) async throws {
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer))).get()
    }

    private func reject(_ channel: Channel, status: HTTPResponseStatus) async {
        let headers = HTTPHeaders([("Content-Length", "0"), ("Connection", "close")])
        try? await channel.writeAndFlush(HTTPServerResponsePart.head(.init(version: .http1_1, status: status, headers: headers))).get()
        try? await channel.writeAndFlush(HTTPServerResponsePart.end(nil)).get()
        try? await channel.close().get()
    }
}

// Mutable request state is accessed only on this connection's NIO event loop.
private final class ClaudeCodeAdmissionHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    private let admission: ClaudeCodeAdmission
    private var head: HTTPRequestHead?
    private var body = Data()

    init(admission: ClaudeCodeAdmission) { self.admission = admission }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head): self.head = head
        case .body(var buffer):
            guard body.count + buffer.readableBytes <= 32 * 1024 * 1024 else { context.close(promise: nil); return }
            if let bytes = buffer.readBytes(length: buffer.readableBytes) { body.append(contentsOf: bytes) }
        case .end:
            guard let head else { context.close(promise: nil); return }
            let channel = context.channel
            let body = self.body
            self.head = nil
            self.body = Data()
            Task { [admission] in await admission.handle(head: head, body: body, channel: channel) }
        }
    }
}

/// A redirect must never move the native bearer to another host.
final class ClaudeCodeNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
#if canImport(Security)
        if SloppyExtraCertificateAuthority.handle(challenge: challenge, completionHandler: completionHandler) { return }
#endif
        completionHandler(.performDefaultHandling, nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
