import Foundation
#if canImport(Network)
import Network
#endif

#if canImport(Network)
/// A loopback listener per preview. Each browser TCP connection gets an authenticated Core stream.
/// The stream carries raw bytes, including WebSocket upgrades, through existing Sloppy transports.
@MainActor
public final class LaunchPreviewTunnel {
    private let apiClient: SloppyAPIClient
    private var listener: NWListener?
    private var readiness: CheckedContinuation<UInt16, Error>?
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var connections: [UUID: NWConnection] = [:]
    private let queue = DispatchQueue(label: "sloppy.launch-preview")

    public init(apiClient: SloppyAPIClient) { self.apiClient = apiClient }

    public func open(agentID: String, sessionID: String, run: LaunchRun) async throws -> URL {
        stop()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection, agentID: agentID, sessionID: sessionID, runID: run.id) }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self, self.listener === listener else { return }
                switch state {
                case .ready:
                    if let port = listener?.port?.rawValue { self.readiness?.resume(returning: port); self.readiness = nil }
                case .failed(let error): self.readiness?.resume(throwing: error); self.readiness = nil
                case .cancelled: self.readiness?.resume(throwing: CancellationError()); self.readiness = nil
                default: break
                }
            }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            readiness = continuation; listener.start(queue: queue)
        }
        guard let url = URL(string: "http://127.0.0.1:\(port)\(run.configuration.request.webPath ?? "/")") else { throw APIError.invalidResponse }
        return url
    }

    public func stop() {
        self.readiness?.resume(throwing: CancellationError()); self.readiness = nil
        listener?.cancel(); listener = nil
        tasks.values.forEach { $0.cancel() }; tasks = [:]
        connections.values.forEach { $0.cancel() }; connections = [:]
    }

    private func accept(_ connection: NWConnection, agentID: String, sessionID: String, runID: String) {
        let id = UUID(); connections[id] = connection
        connection.start(queue: queue)
        tasks[id] = Task {
            let channel = LaunchPreviewChannel(apiClient: apiClient)
            do {
                let incoming = try await channel.open(agentID: agentID, sessionID: sessionID, runID: runID)
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        do {
                            for try await data in incoming {
                                try await Self.write(data, to: connection)
                            }
                        } catch { }
                    }
                    group.addTask {
                        do {
                            while !Task.isCancelled {
                                guard let data = try await Self.read(connection) else { break }
                                try await channel.send(data)
                            }
                        } catch { }
                    }
                    _ = await group.next(); group.cancelAll()
                    connection.cancel(); await channel.close()
                }
            } catch { connection.cancel(); await channel.close() }
            connections[id] = nil; tasks[id] = nil
        }
    }

    private nonisolated static func read(_ connection: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: (data?.isEmpty == false) ? data : (complete ? nil : Data())) }
            }
        }
    }
    private nonisolated static func write(_ data: Data, to connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}

private actor LaunchPreviewChannel {
    private let apiClient: SloppyAPIClient
    private var socket: URLSessionWebSocketTask?
    private var streamID: UUID?
    private var deviceID: UUID?
    private var receiveTask: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    init(apiClient: SloppyAPIClient) { self.apiClient = apiClient }

    func open(agentID: String, sessionID: String, runID: String) async throws -> AsyncThrowingStream<Data, Error> {
        let path = await apiClient.launchPreviewSocketPath(agentID: agentID, sessionID: sessionID, runID: runID)
        let stream = AsyncThrowingStream<Data, Error>.makeStream()
        continuation = stream.continuation
        if case .managed(_, let deviceID) = apiClient.endpoint {
            let managed = try await ManagedRemoteConnection.shared.openStream(to: deviceID, kind: "preview.stream", path: path)
            self.streamID = managed.id; self.deviceID = deviceID
            receiveTask = Task {
                for await frame in managed.frames {
                    if frame.action == .close { break }
                    if let bytes = frame.data, let data = Data(base64Encoded: String(decoding: bytes, as: UTF8.self)) { continuation?.yield(data) }
                }
                continuation?.finish()
            }
        } else {
            var components = URLComponents(url: apiClient.baseURL, resolvingAgainstBaseURL: false)
            components?.scheme = apiClient.baseURL.scheme == "https" ? "wss" : "ws"
            components?.path = path; components?.query = nil
            guard let url = components?.url else { throw APIError.invalidResponse }
            var request = URLRequest(url: url)
            if let token = await apiClient.currentAccessToken() { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let socket = ClientURLSessionFactory.session(for: apiClient.baseURL).webSocketTask(with: request)
            self.socket = socket; socket.resume()
            receiveTask = Task {
                do {
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        let text: String
                        switch message { case .string(let value): text = value; case .data(let value): text = String(decoding: value, as: UTF8.self); @unknown default: continue }
                        guard let data = Data(base64Encoded: text) else { throw APIError.decodingFailed("Invalid preview frame") }
                        continuation?.yield(data)
                    }
                    continuation?.finish()
                } catch { continuation?.finish(throwing: error) }
            }
        }
        return stream.stream
    }
    func send(_ data: Data) async throws {
        let text = data.base64EncodedString()
        if let streamID, let deviceID {
            try await ManagedRemoteConnection.shared.sendStreamData(id: streamID, hostID: deviceID, kind: "preview.stream", data: Data(text.utf8))
        } else if let socket { try await socket.send(.string(text)) }
    }
    func close() async {
        receiveTask?.cancel(); receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        if let streamID, let deviceID { await ManagedRemoteConnection.shared.closeStream(id: streamID, hostID: deviceID, kind: "preview.stream") }
        continuation?.finish(); continuation = nil; streamID = nil; deviceID = nil
    }
}
#endif
