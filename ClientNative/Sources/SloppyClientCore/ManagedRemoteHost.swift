import Foundation
import SloppyRemoteProtocol

public actor ManagedRemoteHost {
    private let connection: ManagedRemoteConnection
    private let localCoreURL: URL

    public init(localCoreURL: URL, connection: ManagedRemoteConnection = ManagedRemoteConnection()) {
        self.localCoreURL = localCoreURL
        self.connection = connection
    }

    public func run() async {
        let coreURL = localCoreURL
        let streams = ManagedRemoteHostStreams(localCoreURL: coreURL, connection: connection)
        await connection.setCoreRequestHandler { request in
            await Self.handle(request, at: coreURL)
        }
        await connection.setStreamFrameHandler { senderID, kind, frame in
            await streams.handle(senderID: senderID, kind: kind, frame: frame)
        }
        while !Task.isCancelled {
            do {
                try await connection.connect()
            } catch {
                // The host stays available locally and retries the relay connection.
            }
            try? await Task.sleep(for: .seconds(5))
        }
        await connection.disconnect()
    }

    private static func handle(_ remote: RemoteCoreRequest, at baseURL: URL) async -> RemoteCoreResponse {
        guard remote.path.hasPrefix("/v1/"),
              !remote.path.contains(".."),
              ["GET", "POST", "PUT", "PATCH", "DELETE"].contains(remote.method),
              let url = URL(string: remote.path, relativeTo: baseURL)?.absoluteURL,
              url.host == baseURL.host,
              url.port == baseURL.port,
              url.path.hasPrefix("/v1/"),
              url.user == nil,
              url.password == nil else {
            return RemoteCoreResponse(
                requestID: remote.requestID,
                status: 400,
                body: Data(#"{"error":"invalid_remote_request"}"#.utf8)
            )
        }
        do {
            var token = await AuthSessionStore.shared.session(for: baseURL)?.accessToken
            var (data, http) = try await perform(remote, url: url, token: token)
            if http.statusCode == 401 {
                let recovery = await AuthSessionStore.shared.recoverSession(
                    for: baseURL,
                    rejectedAccessToken: token
                ) { refreshToken in
                    await refreshCoreSession(at: baseURL, refreshToken: refreshToken)
                }
                if case .recovered(let session) = recovery {
                    token = session.accessToken
                    (data, http) = try await perform(remote, url: url, token: token)
                }
            }
            return RemoteCoreResponse(
                requestID: remote.requestID,
                status: http.statusCode,
                body: data,
                contentType: http.value(forHTTPHeaderField: "Content-Type") ?? "application/json"
            )
        } catch {
            return RemoteCoreResponse(
                requestID: remote.requestID,
                status: 502,
                body: Data(#"{"error":"host_core_unavailable"}"#.utf8)
            )
        }
    }

    private static func perform(
        _ remote: RemoteCoreRequest,
        url: URL,
        token: String?
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = remote.method
        request.httpBody = remote.body
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if remote.body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ManagedRemoteError.invalidResponse
        }
        return (data, http)
    }

    private static func refreshCoreSession(at baseURL: URL, refreshToken: String) async -> AuthSession? {
        guard let url = URL(string: "/v1/auth/refresh", relativeTo: baseURL)?.absoluteURL else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["refreshToken": refreshToken])
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return nil }
        return try? JSONDecoder().decode(AuthSession.self, from: data)
    }
}

private actor ManagedRemoteHostStreams {
    private struct Key: Hashable {
        var senderID: UUID
        var streamID: UUID
    }

    private let localCoreURL: URL
    private let connection: ManagedRemoteConnection
    private var sockets: [Key: URLSessionWebSocketTask] = [:]

    init(localCoreURL: URL, connection: ManagedRemoteConnection) {
        self.localCoreURL = localCoreURL
        self.connection = connection
    }

    func handle(senderID: UUID, kind: String, frame: RemoteStreamFrame) async {
        let key = Key(senderID: senderID, streamID: frame.streamID)
        switch frame.action {
        case .open:
            await open(key: key, kind: kind, path: frame.path)
        case .data:
            guard let socket = sockets[key], let data = frame.data else { return }
            try? await socket.send(.string(String(decoding: data, as: UTF8.self)))
        case .close:
            sockets.removeValue(forKey: key)?.cancel(with: .goingAway, reason: nil)
        }
    }

    private func open(key: Key, kind: String, path: String?) async {
        guard sockets[key] == nil,
              let path, allowed(path: path, kind: kind),
              var components = URLComponents(url: localCoreURL, resolvingAgainstBaseURL: false) else {
            try? await connection.sendStreamReply(
                RemoteStreamFrame(streamID: key.streamID, action: .close),
                to: key.senderID,
                kind: kind
            )
            return
        }
        _ = try? await BackendHTTPClient(baseURL: localCoreURL).getData("/v1/me")
        guard let token = await AuthSessionStore.shared.session(for: localCoreURL)?.accessToken,
              !token.isEmpty else {
            try? await connection.sendStreamReply(
                RemoteStreamFrame(streamID: key.streamID, action: .close),
                to: key.senderID,
                kind: kind
            )
            return
        }
        components.scheme = localCoreURL.scheme == "https" ? "wss" : "ws"
        components.path = path
        guard let url = components.url else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        sockets[key] = socket
        socket.resume()
        if kind == "terminal.stream" {
            let authentication = ["type": "auth", "token": token]
            if let data = try? JSONEncoder().encode(authentication) {
                try? await socket.send(.string(String(decoding: data, as: UTF8.self)))
            }
        }
        Task { await receiveLocal(socket: socket, key: key, kind: kind) }
    }

    private func receiveLocal(
        socket: URLSessionWebSocketTask,
        key: Key,
        kind: String
    ) async {
        do {
            while !Task.isCancelled {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case .string(let text): data = Data(text.utf8)
                case .data(let value): data = value
                @unknown default: continue
                }
                try await connection.sendStreamReply(
                    RemoteStreamFrame(streamID: key.streamID, action: .data, data: data),
                    to: key.senderID,
                    kind: kind
                )
            }
        } catch {
            sockets[key] = nil
            try? await connection.sendStreamReply(
                RemoteStreamFrame(streamID: key.streamID, action: .close),
                to: key.senderID,
                kind: kind
            )
        }
    }

    private func allowed(path: String, kind: String) -> Bool {
        if kind == "terminal.stream" {
            return path == "/v1/dashboard/terminal/ws"
        }
        let parts = path.split(separator: "/")
        if kind == "preview.stream" {
            return parts.count == 10 && parts[0] == "v1" && parts[1] == "agents"
                && parts[3] == "sessions" && parts[5] == "launch" && parts[6] == "runs"
                && parts[8] == "preview" && parts[9] == "ws" && !path.contains("..")
        }
        return kind == "session.stream" &&
            parts.count == 6 &&
            parts[0] == "v1" && parts[1] == "agents" &&
            parts[3] == "sessions" && parts[5] == "ws" &&
            !path.contains("..")
    }
}

public actor ManagedRemoteHostManager {
    public static let shared = ManagedRemoteHostManager()
    private var task: Task<Void, Never>?

    public func startIfNeeded(localCoreURL: URL) {
        guard task == nil,
              ManagedRemoteCredentialStore.load()?.device.kind == .host else { return }
        let host = ManagedRemoteHost(localCoreURL: localCoreURL)
        task = Task { await host.run() }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }
}
