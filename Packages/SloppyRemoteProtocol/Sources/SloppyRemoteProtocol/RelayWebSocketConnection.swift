import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOWebSocket

/// Cross-platform WebSocket transport; never terminates the inner peer TLS.
public actor RelayWebSocketConnection {
    private static let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var channel: (any Channel)?
    public let messages: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    public init() {
        let pair = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .bufferingNewest(16))
        messages = pair.stream; continuation = pair.continuation
    }
    public func connect(url: URL, token: String) async throws {
        guard channel == nil, url.scheme == "https", let host = url.host, url.user == nil, url.password == nil else { throw RemoteTLSError.invalidPeer }
        let ready = Self.group.next().makePromise(of: Void.self)
        let continuation = continuation
        let requester = UpgradeRequestHandler(host: host, token: token, ready: ready)
        let upgrader = NIOWebSocketClientUpgrader(maxFrameSize: 4 * 1024 * 1024 + 65536) { channel, _ in
            channel.pipeline.addHandler(RelayFrameHandler(continuation: continuation)).map { ready.succeed(()) }
        }
        let ssl = try NIOSSLContext(configuration: .makeClientConfiguration())
        let connection = try await ClientBootstrap(group: Self.group).connectTimeout(.seconds(10))
            .channelInitializer { channel in
                do {
                    let handler = try NIOSSLClientHandler(context: ssl, serverHostname: host)
                    return channel.pipeline.addHandler(handler).flatMap {
                        channel.pipeline.addHTTPClientHandlers(withClientUpgrade: (upgraders: [upgrader], completionHandler: { context in context.pipeline.removeHandler(requester, promise: nil) }))
                    }.flatMap { channel.pipeline.addHandler(requester) }
                } catch { return channel.eventLoop.makeFailedFuture(error) }
            }.connect(host: host, port: url.port ?? 443).get()
        let timeout = connection.eventLoop.scheduleTask(in: .seconds(15)) { ready.fail(RemoteTLSError.handshakeIncomplete); connection.close(promise: nil) }
        do { try await ready.futureResult.get(); timeout.cancel(); channel = connection }
        catch { timeout.cancel(); try? await connection.close().get(); throw error }
    }
    public func send(_ data: Data) async throws {
        guard let channel, channel.isActive, channel.isWritable, data.count <= 4 * 1024 * 1024 + 65536 else { throw RemoteTLSError.closed }
        var buffer = channel.allocator.buffer(capacity: data.count); buffer.writeBytes(data)
        try await channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .text, maskKey: .random(), data: buffer)).get()
    }
    public func close() async { continuation.finish(); try? await channel?.close().get(); channel = nil }
}

private final class UpgradeRequestHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    private let host: String
    private let token: String
    private let ready: EventLoopPromise<Void>
    init(host: String, token: String, ready: EventLoopPromise<Void>) { self.host = host; self.token = token; self.ready = ready }
    func channelActive(context: ChannelHandlerContext) {
        var headers = HTTPHeaders(); headers.add(name: "Host", value: host); headers.add(name: "Authorization", value: "Bearer " + token)
        context.write(NIOAny(HTTPClientRequestPart.head(HTTPRequestHead(version: .http1_1, method: .GET, uri: "/v1/relay/ws", headers: headers))), promise: nil)
        context.writeAndFlush(NIOAny(HTTPClientRequestPart.end(nil)), promise: nil)
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if case .head(let head) = unwrapInboundIn(data), head.status != .switchingProtocols { ready.fail(RemoteTLSError.invalidPeer); context.close(promise: nil) }
    }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { ready.fail(error); context.close(promise: nil) }
}

private final class RelayFrameHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    init(continuation: AsyncThrowingStream<Data, any Error>.Continuation) { self.continuation = continuation }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .text, .binary:
            guard frame.fin else { continuation.finish(throwing: RemoteTLSError.invalidFrame); context.close(promise: nil); return }
            if case .dropped = continuation.yield(Data(frame.unmaskedData.readableBytesView)) { continuation.finish(throwing: RemoteTLSError.oversizedMessage); context.close(promise: nil) }
        case .ping: context.writeAndFlush(NIOAny(WebSocketFrame(fin: true, opcode: .pong, maskKey: .random(), data: frame.unmaskedData)), promise: nil)
        case .connectionClose: continuation.finish(); context.close(promise: nil)
        default: break
        }
    }
    func channelInactive(context: ChannelHandlerContext) { continuation.finish() }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { continuation.finish(throwing: error); context.close(promise: nil) }
}
