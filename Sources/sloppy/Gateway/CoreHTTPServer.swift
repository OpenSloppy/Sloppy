import Foundation
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

private struct WebSocketUpgradeRejected: Error {}

private func normalizeHTTPHeaders(_ headers: HTTPHeaders) -> [String: String] {
    var normalized: [String: String] = [:]
    for header in headers {
        normalized[header.name.lowercased()] = header.value
    }
    return normalized
}

/// Runs HTTP transport for CoreRouter using SwiftNIO HTTP/1.1.
public final class CoreHTTPServer {
    private let host: String
    private let port: Int
    private let router: CoreRouter
    private let logger: Logger
    private let group: MultiThreadedEventLoopGroup
    private var channel: Channel?

    public init(host: String, port: Int, router: CoreRouter, logger: Logger) {
        self.host = host
        self.port = port
        self.router = router
        self.logger = logger
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    }

    /// Binds to host:port and starts accepting HTTP requests.
    public func start() throws {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [router, logger] channel in
                let httpHandler = CoreHTTPHandler(router: router, logger: logger)
                let webSocketUpgrader = NIOWebSocketServerUpgrader(
                    shouldUpgrade: { channel, head in
                        // `makeFutureWithTask` / `completeWithTask` complete the promise on Swift's
                        // concurrent executor, not on `channel.eventLoop`. The upgrade handler then
                        // touches the pipeline off-loop and hits `ChannelPipeline` preconditions.
                        let loop = channel.eventLoop
                        let promise = loop.makePromise(of: HTTPHeaders?.self)
                        let remote = channel.remoteAddress?.ipAddress
                        Task {
                            do {
                                guard await router.canHandleWebSocket(
                                    path: head.uri,
                                    headers: normalizeHTTPHeaders(head.headers),
                                    remoteAddress: remote
                                ) else {
                                    throw WebSocketUpgradeRejected()
                                }
                                loop.execute {
                                    promise.succeed(HTTPHeaders())
                                }
                            } catch {
                                let err = error
                                loop.execute {
                                    promise.fail(err)
                                }
                            }
                        }
                        return promise.futureResult
                    },
                    upgradePipelineHandler: { channel, head in
                        let handler = CoreWebSocketHandler(
                            router: router,
                            logger: logger,
                            path: head.uri,
                            headers: normalizeHTTPHeaders(head.headers),
                            remoteAddress: channel.remoteAddress?.ipAddress
                        )
                        return channel.pipeline.addHandler(handler)
                    }
                )
                let upgradeConfig = NIOHTTPServerUpgradeConfiguration(
                    upgraders: [webSocketUpgrader],
                    completionHandler: { context in
                        // Upgrade completion is not guaranteed to run on the channel loop.
                        context.eventLoop.execute {
                            try? context.pipeline.syncOperations.removeHandler(httpHandler)
                        }
                    }
                )

                return channel.pipeline.configureHTTPServerPipeline(
                    withServerUpgrade: upgradeConfig
                ).flatMap {
                    channel.pipeline.addHandler(httpHandler)
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        channel = try bootstrap.bind(host: host, port: port).wait()
    }

    /// Waits until server channel is closed.
    public func waitUntilClosed() throws {
        guard let channel else {
            return
        }
        try channel.closeFuture.wait()
    }

    /// Returns dynamically bound TCP port (useful when server starts with port 0 in tests).
    public var boundPort: Int? {
        guard let address = channel?.localAddress else {
            return nil
        }
        return address.port
    }

    /// Shuts server down and releases event loops.
    public func shutdown() throws {
        if let channel {
            try channel.close().wait()
        }
        try group.syncShutdownGracefully()
    }
}

private final class CoreHTTPHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let router: CoreRouter
    private let logger: Logger
    private var requestHead: HTTPRequestHead?
    private var requestBody: ByteBuffer?
    private var requestBodyTooLarge = false
    private var streamTask: Task<Void, Never>?

    init(router: CoreRouter, logger: Logger) {
        self.router = router
        self.logger = logger
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)

        switch part {
        case .head(let head):
            streamTask?.cancel()
            streamTask = nil
            requestHead = head
            requestBody = context.channel.allocator.buffer(capacity: 0)
            requestBodyTooLarge = false

        case .body(var bodyPart):
            if requestHead?.uri.hasPrefix("/v1/agent-plugins/uploads") == true,
               (requestBody?.readableBytes ?? 0) + bodyPart.readableBytes > 100 * 1_024 * 1_024 {
                requestBodyTooLarge = true
                return
            }
            guard !requestBodyTooLarge else { return }
            if requestBody == nil {
                requestBody = context.channel.allocator.buffer(capacity: bodyPart.readableBytes)
            }
            requestBody?.writeBuffer(&bodyPart)

        case .end:
            guard let head = requestHead else {
                return
            }

            requestHead = nil
            var bodyBuffer = requestBody
            requestBody = nil

            if requestBodyTooLarge {
                requestBodyTooLarge = false
                writeResponse(
                    context: context,
                    requestHead: head,
                    response: CoreRouter.json(
                        status: 413,
                        payload: ["error": "agent_plugin_archive_too_large", "message": "Agent Plugin ZIP exceeds 100 MiB."]
                    )
                )
                return
            }

            if head.method == .OPTIONS {
                writePreflightResponse(context: context, requestHead: head)
                return
            }

            let method = head.method.rawValue
            let path = head.uri
            let bodyData = readData(from: &bodyBuffer)
            let router = self.router
            let loop = context.eventLoop
            let remoteAddress = context.channel.remoteAddress?.ipAddress

            let promise = loop.makePromise(of: CoreRouterResponse.self)
            Task {
                let response = await router.handle(
                    method: method,
                    path: path,
                    body: bodyData,
                    headers: normalizeHTTPHeaders(head.headers),
                    remoteAddress: remoteAddress
                )
                loop.execute {
                    promise.succeed(response)
                }
            }
            let responseFuture = promise.futureResult

            responseFuture.whenComplete { [weak self] result in
                guard let self else {
                    return
                }
                switch result {
                case .success(let response):
                    self.writeResponse(context: context, requestHead: head, response: response)
                case .failure(let error):
                    self.logger.error("Failed to handle request: \(String(describing: error))")
                    self.writeServerError(context: context, requestHead: head)
                }
            }
        }
    }

    private func writeResponse(
        context: ChannelHandlerContext,
        requestHead: HTTPRequestHead,
        response: CoreRouterResponse
    ) {
        if let sseStream = response.sseStream {
            writeSSEStreamResponse(
                context: context,
                requestHead: requestHead,
                response: response,
                stream: sseStream
            )
            return
        }

        let keepAlive = requestHead.isKeepAlive
        var headers = defaultHeaders(contentType: response.contentType, contentLength: response.body.count)
        for (name, value) in response.headers {
            headers.replaceOrAdd(name: name, value: value)
        }
        headers.replaceOrAdd(name: "connection", value: keepAlive ? "keep-alive" : "close")

        let head = HTTPResponseHead(
            version: requestHead.version,
            status: HTTPResponseStatus(statusCode: response.status),
            headers: headers
        )

        context.write(wrapOutboundOut(.head(head)), promise: nil)

        if requestHead.method != .HEAD {
            var buffer = context.channel.allocator.buffer(capacity: response.body.count)
            buffer.writeBytes(response.body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            guard !keepAlive else {
                return
            }
            context.eventLoop.execute {
                context.close(promise: nil)
            }
        }
    }

    private func writeSSEStreamResponse(
        context: ChannelHandlerContext,
        requestHead: HTTPRequestHead,
        response: CoreRouterResponse,
        stream: AsyncStream<CoreRouterServerSentEvent>
    ) {
        let keepAlive = requestHead.isKeepAlive
        var headers = defaultHeaders(contentType: "\(response.contentType); charset=utf-8")
        headers.replaceOrAdd(name: "connection", value: keepAlive ? "keep-alive" : "close")
        headers.replaceOrAdd(name: "cache-control", value: "no-cache")
        headers.replaceOrAdd(name: "x-accel-buffering", value: "no")
        headers.replaceOrAdd(name: "transfer-encoding", value: "chunked")

        let head = HTTPResponseHead(
            version: requestHead.version,
            status: HTTPResponseStatus(statusCode: response.status),
            headers: headers
        )

        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.flush()

        let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        let eventLoop = context.eventLoop
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else {
                return
            }

            await self.writeStreamChunk(
                eventLoop: eventLoop,
                loopBoundContext: loopBoundContext,
                bytes: Data(": stream-open\n\n".utf8)
            )

            for await event in stream {
                if Task.isCancelled {
                    break
                }
                await self.writeStreamChunk(
                    eventLoop: eventLoop,
                    loopBoundContext: loopBoundContext,
                    bytes: self.encodeSSEPacket(event: event)
                )
            }

            guard !Task.isCancelled else {
                return
            }
            await self.finishStreamResponse(
                eventLoop: eventLoop,
                loopBoundContext: loopBoundContext,
                keepAlive: keepAlive
            )
        }
    }

    private func writePreflightResponse(context: ChannelHandlerContext, requestHead: HTTPRequestHead) {
        var headers = defaultHeaders(contentType: "application/json", contentLength: 0)
        headers.replaceOrAdd(name: "connection", value: requestHead.isKeepAlive ? "keep-alive" : "close")

        let responseHead = HTTPResponseHead(
            version: requestHead.version,
            status: .ok,
            headers: headers
        )

        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            guard !requestHead.isKeepAlive else {
                return
            }
            context.eventLoop.execute {
                context.close(promise: nil)
            }
        }
    }

    private func writeServerError(context: ChannelHandlerContext, requestHead: HTTPRequestHead) {
        let payload = Data("{\"error\":\"internal\"}".utf8)
        let response = CoreRouterResponse(status: 500, body: payload)
        writeResponse(context: context, requestHead: requestHead, response: response)
    }

    private func encodeSSEPacket(event: CoreRouterServerSentEvent) -> Data {
        var lines: [String] = []
        if let id = event.id, !id.isEmpty {
            lines.append("id: \(id)")
        }
        lines.append("event: \(event.event)")

        let payload = String(data: event.data, encoding: .utf8) ?? "{}"
        let payloadLines = payload.split(separator: "\n", omittingEmptySubsequences: false)
        if payloadLines.isEmpty {
            lines.append("data: {}")
        } else {
            for line in payloadLines {
                lines.append("data: \(line)")
            }
        }

        lines.append("")
        lines.append("")
        return Data(lines.joined(separator: "\n").utf8)
    }

    private func writeStreamChunk(
        eventLoop: any EventLoop,
        loopBoundContext: NIOLoopBound<ChannelHandlerContext>,
        bytes: Data
    ) async {
        guard !Task.isCancelled else {
            return
        }
        await withCheckedContinuation { continuation in
            eventLoop.execute { [weak self, loopBoundContext] in
                guard let self else {
                    continuation.resume()
                    return
                }

                let context = loopBoundContext.value
                guard context.channel.isActive else {
                    continuation.resume()
                    return
                }
                var buffer = context.channel.allocator.buffer(capacity: bytes.count)
                buffer.writeBytes(bytes)
                context.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(buffer)))).whenComplete { _ in
                    continuation.resume()
                }
            }
        }
    }

    private func finishStreamResponse(
        eventLoop: any EventLoop,
        loopBoundContext: NIOLoopBound<ChannelHandlerContext>,
        keepAlive: Bool
    ) async {
        guard !Task.isCancelled else {
            return
        }
        await withCheckedContinuation { continuation in
            eventLoop.execute { [weak self, loopBoundContext] in
                guard let self else {
                    continuation.resume()
                    return
                }

                let context = loopBoundContext.value
                guard context.channel.isActive else {
                    continuation.resume()
                    return
                }
                let el = context.eventLoop
                context.writeAndFlush(self.wrapOutboundOut(.end(nil))).whenComplete { _ in
                    if !keepAlive {
                        el.execute {
                            context.close(promise: nil)
                        }
                    }
                    continuation.resume()
                }
            }
        }
    }


    private func readData(from buffer: inout ByteBuffer?) -> Data? {
        guard var buffer else {
            return nil
        }
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        return Data(bytes)
    }

    private func defaultHeaders(contentType: String, contentLength: Int? = nil) -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: contentType)
        if let contentLength {
            headers.add(name: "content-length", value: "\(contentLength)")
        }
        headers.add(name: "access-control-allow-origin", value: "*")
        headers.add(name: "access-control-allow-methods", value: "GET,HEAD,POST,PUT,PATCH,DELETE,OPTIONS")
        headers.add(name: "access-control-allow-headers", value: "content-type,authorization,last-event-id,traceparent,tracestate")
        headers.add(name: "access-control-expose-headers", value: "server-timing,x-sloppy-route")
        headers.add(name: "access-control-max-age", value: "600")
        return headers
    }

    func channelInactive(context: ChannelHandlerContext) {
        streamTask?.cancel()
        streamTask = nil
        context.fireChannelInactive()
    }
}

private final class CoreWebSocketHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let router: CoreRouter
    private let logger: Logger
    private let path: String
    private let headers: [String: String]
    private let remoteAddress: String?
    private var context: ChannelHandlerContext?
    private var routeTask: Task<Void, Never>?
    private var closeRequested = false
    private let inboundMessages: AsyncStream<String>
    private let inboundMessagesContinuation: AsyncStream<String>.Continuation

    init(router: CoreRouter, logger: Logger, path: String, headers: [String: String], remoteAddress: String?) {
        self.router = router
        self.logger = logger
        self.path = path
        self.headers = headers
        self.remoteAddress = remoteAddress
        var continuation: AsyncStream<String>.Continuation?
        self.inboundMessages = AsyncStream<String> { next in
            continuation = next
        }
        self.inboundMessagesContinuation = continuation!
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        let connection = WebSocketConnectionContext(
            sendText: { [weak self] text in
                await self?.sendText(text) ?? false
            },
            close: { [weak self] in
                await self?.close()
            },
            incomingMessages: { [inboundMessages] in
                inboundMessages
            }
        )

        routeTask = Task { [router, path, headers, logger, remoteAddress] in
            let handled = await router.handleWebSocket(
                path: path,
                headers: headers,
                connection: connection,
                remoteAddress: remoteAddress
            )
            if !handled {
                logger.warning("Rejected websocket request", metadata: ["path": .string(path)])
                await connection.close()
            }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .ping:
            let data = frame.unmaskedData
            let pong = WebSocketFrame(fin: true, opcode: .pong, data: data)
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
        case .text:
            var data = frame.unmaskedData
            if let text = data.readString(length: data.readableBytes) {
                inboundMessagesContinuation.yield(text)
            }
        case .connectionClose:
            closeRequested = true
            inboundMessagesContinuation.finish()
            context.close(promise: nil)
        default:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        routeTask?.cancel()
        routeTask = nil
        inboundMessagesContinuation.finish()
        self.context = nil
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.warning(
            "WebSocket channel error",
            metadata: [
                "path": .string(path),
                "error": .string(String(describing: error))
            ]
        )
        context.close(promise: nil)
    }

    private func sendText(_ text: String) async -> Bool {
        guard let context else {
            return false
        }
        let eventLoop = context.eventLoop

        return await withCheckedContinuation { continuation in
            eventLoop.execute {
                guard let context = self.context, context.channel.isActive, !self.closeRequested else {
                    continuation.resume(returning: false)
                    return
                }

                var buffer = context.channel.allocator.buffer(capacity: text.utf8.count)
                buffer.writeString(text)
                let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
                context.writeAndFlush(self.wrapOutboundOut(frame)).whenComplete { result in
                    switch result {
                    case .success:
                        continuation.resume(returning: true)
                    case .failure:
                        continuation.resume(returning: false)
                    }
                }
            }
        }
    }

    private func close() async {
        guard let context else {
            return
        }
        let eventLoop = context.eventLoop

        await withCheckedContinuation { continuation in
            eventLoop.execute {
                guard let context = self.context, context.channel.isActive else {
                    continuation.resume()
                    return
                }

                self.closeRequested = true
                let data = context.channel.allocator.buffer(capacity: 0)
                let frame = WebSocketFrame(fin: true, opcode: .connectionClose, data: data)
                context.writeAndFlush(self.wrapOutboundOut(frame)).whenComplete { _ in
                    context.eventLoop.execute {
                        context.close(promise: nil)
                    }
                    continuation.resume()
                }
            }
        }
    }
}
