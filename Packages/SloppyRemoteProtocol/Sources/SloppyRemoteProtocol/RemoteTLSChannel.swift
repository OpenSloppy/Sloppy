import Foundation
import NIOCore
import NIOEmbedded
import NIOPosix
import NIOTLS
import NIOSSL

public struct RemoteTLSResult: Sendable {
    public var records: [Data]
    public var messages: [Data]
    public var handshakeComplete: Bool
}

public enum RemoteTLSError: Error, Sendable { case invalidPeer, handshakeIncomplete, oversizedMessage, closed, invalidFrame }

extension RemoteTLSError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidPeer: "The secure Sloppy connection could not verify the other device. Reconnect using the host's connection code."
        case .handshakeIncomplete: "The secure connection to your Sloppy host did not finish. Check that the host is online and try again."
        case .oversizedMessage: "The Sloppy response exceeded the connection limit. Try loading it again."
        case .closed: "The connection to your Sloppy host was interrupted. Try again."
        case .invalidFrame: "The secure Sloppy connection received an invalid response. Reconnect and try again."
        }
    }
}

/// TLS is an endpoint layer. The Relay sees only its output records. Each
/// channel owns a fresh SSL context, preventing ticket resumption across
/// channels. Neither client session reuse nor early data is enabled.
private final class TLSExecutor: SerialExecutor, @unchecked Sendable {
    static let shared = TLSExecutor()
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    var eventLoop: any EventLoop { group.next() }
    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        eventLoop.execute { job.runSynchronously(on: self.asUnownedSerialExecutor()) }
    }
}

public actor RemoteTLSChannel {
    private nonisolated let executor = TLSExecutor.shared
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private var channel: EmbeddedChannel!
    private var observer: TLSObserver!
    private var pending = Data()
    private var closed = false
    private static let maximumMessageBytes = 4 * 1024 * 1024
    public init(identity: RemoteTLSIdentity, peerCertificate: Data, isClient: Bool) async throws {
        let memory = try await executor.eventLoop.submit {
            try TLSMemoryState(identity: identity, peerCertificate: peerCertificate, isClient: isClient)
        }.get()
        self.channel = memory.channel; self.observer = memory.observer
    }

    public func start() throws -> RemoteTLSResult { try drain() }
    public func receive(_ records: Data) throws -> RemoteTLSResult {
        guard !closed, records.count <= Self.maximumMessageBytes + 65536 else { throw RemoteTLSError.closed }
        var buffer = channel.allocator.buffer(capacity: records.count); buffer.writeBytes(records)
        try channel.writeInbound(buffer); channel.embeddedEventLoop.run()
        return try drain()
    }
    public func send(_ message: Data) throws -> RemoteTLSResult {
        guard !closed else { throw RemoteTLSError.closed }
        guard observer.complete else { throw RemoteTLSError.handshakeIncomplete }
        guard message.count <= Self.maximumMessageBytes else { throw RemoteTLSError.oversizedMessage }
        var buffer = channel.allocator.buffer(capacity: message.count + 4); buffer.writeInteger(UInt32(message.count)); buffer.writeBytes(message)
        try channel.writeOutbound(buffer); channel.embeddedEventLoop.run()
        return try drain()
    }
    public func close() {
        guard let channel else { return }; closed = true
        channel.close(promise: nil)
        channel.embeddedEventLoop.advanceTime(by: .seconds(6))
        _ = try? channel.finish(acceptAlreadyClosed: true); pending.removeAll()
        self.channel = nil; self.observer = nil
    }
    private func drain() throws -> RemoteTLSResult {
        if let failure = observer.failure { closed = true; throw failure }
        try channel.throwIfErrorCaught()
        var records: [Data] = []
        while let buffer = try channel.readOutbound(as: ByteBuffer.self) { records.append(Data(buffer.readableBytesView)) }
        while let buffer = try channel.readInbound(as: ByteBuffer.self) { pending.append(contentsOf: buffer.readableBytesView) }
        guard pending.count <= Self.maximumMessageBytes + 4 else { closed = true; throw RemoteTLSError.oversizedMessage }
        var messages: [Data] = []
        while pending.count >= 4 {
            let length = pending.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length <= Self.maximumMessageBytes else { closed = true; throw RemoteTLSError.oversizedMessage }
            guard pending.count >= Int(length) + 4 else { break }
            messages.append(Data(pending.dropFirst(4).prefix(Int(length)))); pending.removeFirst(Int(length) + 4)
        }
        return RemoteTLSResult(records: records, messages: messages, handshakeComplete: observer.complete)
    }
}

private final class TLSMemoryState: @unchecked Sendable {
    let channel: EmbeddedChannel
    let observer: TLSObserver
    init(identity: RemoteTLSIdentity, peerCertificate: Data, isClient: Bool) throws {
        guard !peerCertificate.isEmpty else { throw RemoteTLSError.invalidPeer }
        let certificate = try NIOSSLCertificate(bytes: Array(identity.certificateDER), format: .der)
        let privateKey = try NIOSSLPrivateKey(bytes: Array(identity.privateKeyDER), format: .der)
        var configuration = isClient ? TLSConfiguration.makeClientConfiguration() : TLSConfiguration.makeServerConfiguration(certificateChain: [.certificate(certificate)], privateKey: .privateKey(privateKey))
        configuration.minimumTLSVersion = .tlsv13; configuration.maximumTLSVersion = .tlsv13
        configuration.verifySignatureAlgorithms = [.ed25519]
        configuration.signingSignatureAlgorithms = [.ed25519]
        configuration.certificateChain = [.certificate(certificate)]; configuration.privateKey = .privateKey(privateKey)
        configuration.certificateVerification = .noHostnameVerification
        configuration.applicationProtocols = ["sloppy-remote-v2"]
        let context = try NIOSSLContext(configuration: configuration)
        let verification: NIOSSLCustomVerificationCallback = { chain, promise in
            let matches = chain.first.flatMap { try? Data($0.toDERBytes()) } == peerCertificate
            promise.succeed(matches ? .certificateVerified : .failed)
        }
        let observer = TLSObserver()
        let handler: ChannelHandler = isClient ? try NIOSSLClientHandler(context: context, serverHostname: nil, customVerificationCallback: verification) : NIOSSLServerHandler(context: context, customVerificationCallback: verification)
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(handler)
        try channel.pipeline.syncOperations.addHandler(observer)
        channel.pipeline.fireChannelActive()
        channel.embeddedEventLoop.run()
        self.channel = channel; self.observer = observer
    }
}

private final class TLSObserver: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    var complete = false
    var failure: (any Error)?
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? TLSUserEvent, case .handshakeCompleted(let negotiatedProtocol) = event {
            if negotiatedProtocol == "sloppy-remote-v2" { complete = true } else { failure = RemoteTLSError.invalidPeer }
        }
        context.fireUserInboundEventTriggered(event)
    }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { failure = error; context.close(promise: nil) }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) { context.fireChannelRead(data) }
}

public struct RemoteTLSFrame: Codable, Sendable {
    public static let kind = "console.tls.v2"
    public var version: Int = 2
    public var sessionID: UUID
    public var sequence: UInt64
    public var from: UUID
    public var to: UUID
    public var records: Data
    public init(sessionID: UUID, sequence: UInt64, from: UUID, to: UUID, records: Data) {
        self.sessionID = sessionID; self.sequence = sequence; self.from = from; self.to = to; self.records = records
    }
}
