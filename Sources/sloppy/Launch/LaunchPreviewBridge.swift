import Foundation
import NIOCore
import NIOPosix
import SloppyNodeCore

private final class LaunchPreviewInbound: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let continuation: AsyncStream<Data>.Continuation
    init(_ continuation: AsyncStream<Data>.Continuation) { self.continuation = continuation }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        switch continuation.yield(Data(buffer.readableBytesView)) {
        case .enqueued: break
        default: context.close(promise: nil) // Disconnect on overflow rather than silently corrupting TCP bytes.
        }
    }
    func channelInactive(context: ChannelHandlerContext) { continuation.finish() }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        continuation.finish(); context.close(promise: nil)
    }
}

/// Each authenticated connection forwards raw TCP bytes to one registered run's loopback port.
/// This preserves HTTP, assets and WebSocket upgrades without rewriting application content.
enum LaunchPreviewBridge {
    static func forward(port: Int, connection: WebSocketConnectionContext,
                        isActive: @escaping @Sendable () async -> Bool) async {
        do {
            let bytes = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(512))
            let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .channelInitializer { channel in channel.pipeline.addHandler(LaunchPreviewInbound(bytes.continuation)) }
                .connect(host: "127.0.0.1", port: port).get()
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await data in bytes.stream {
                        guard await connection.sendText(data.base64EncodedString()) else { break }
                    }
                }
                group.addTask {
                    for await text in connection.incomingMessages() {
                        guard let data = Data(base64Encoded: text), data.count <= 1024 * 1024 else { break }
                        var buffer = channel.allocator.buffer(capacity: data.count); buffer.writeBytes(data)
                        do { try await channel.writeAndFlush(buffer).get() } catch { break }
                    }
                }
                group.addTask {
                    while !Task.isCancelled {
                        guard await isActive() else { break }
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
                _ = await group.next()
                group.cancelAll()
                try? await channel.close().get()
                await connection.close()
                bytes.continuation.finish()
            }
        } catch { await connection.close() }
    }
}

extension CoreService {
    func handleLaunchPreview(agentID: String, sessionID: String, runID: String, connection: WebSocketConnectionContext) async {
        do {
            _ = try getAgentSession(agentID: agentID, sessionID: sessionID)
            let port = try await launches.previewPort(agentID: agentID, sessionID: sessionID, runID: runID)
            await LaunchPreviewBridge.forward(port: port, connection: connection) { [weak self] in
                guard let self else { return false }
                return (try? await self.launches.previewPort(agentID: agentID, sessionID: sessionID, runID: runID)) != nil
            }
        } catch { await connection.close() }
    }

    func openMeshLaunchPreview(nodeID: String, agentID: String, sessionID: String, runID: String) async throws -> NodeMeshStream {
        guard let nodeMeshClient else { throw MeshCoreProxyError.missingLocalNodeConfig }
        return try await nodeMeshClient.openStream(to: nodeID, kind: "launch.preview", params: .object([
            "agentId": .string(agentID), "sessionId": .string(sessionID), "runId": .string(runID)
        ]))
    }

    func sendMeshLaunchPreview(nodeID: String, streamID: String, data: String) async throws {
        try await nodeMeshClient?.sendStreamChunk(streamID: streamID, to: nodeID, data: .string(data))
    }

    func forwardMeshLaunchPreview(nodeID: String, agentID: String, sessionID: String, runID: String, connection: WebSocketConnectionContext) async {
        do {
            let stream = try await openMeshLaunchPreview(nodeID: nodeID, agentID: agentID, sessionID: sessionID, runID: runID)
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    do {
                        for try await value in stream.messages {
                            guard let text = value.asString, await connection.sendText(text) else { break }
                        }
                    } catch { }
                }
                group.addTask {
                    for await text in connection.incomingMessages() {
                        do { try await self.sendMeshLaunchPreview(nodeID: nodeID, streamID: stream.id, data: text) } catch { break }
                    }
                }
                _ = await group.next(); group.cancelAll()
                await self.closeMeshAgentSessionStream(streamID: stream.id, nodeID: nodeID)
                await connection.close()
            }
        } catch { await connection.close() }
    }
}

extension CoreService {
    func finishMeshLaunchPreview(streamID: String) {
        meshLaunchPreviewOwners[streamID] = nil
        meshLaunchPreviewInputs.removeValue(forKey: streamID)?.finish()
        meshTerminalForwardTasks[streamID] = nil
    }
}
