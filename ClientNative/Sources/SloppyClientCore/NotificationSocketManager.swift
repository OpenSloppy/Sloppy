import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Logging

public actor NotificationSocketManager {
    private let baseURL: URL
    private let logger: Logger
    private let decoder: JSONDecoder
    private let onConnect: (@Sendable () async -> Void)?

    private var task: URLSessionWebSocketTask?
    private var continuation: AsyncStream<AppNotification>.Continuation?
    private var disposed = false
    private var reconnectDelay: Double = 1.0
    private var socketAttempt = 0

    public init(
        baseURL: URL = URL(string: "http://localhost:25101")!,
        logger: Logger = Logger(label: "sloppy.notification-socket"),
        onConnect: (@Sendable () async -> Void)? = nil
    ) {
        self.baseURL = baseURL
        self.logger = logger
        self.onConnect = onConnect

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            if let date = ISO8601DateFormatter().date(from: str) { return date }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: str) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot decode date: \(str)"
            )
        }
        self.decoder = decoder
    }

    public func connect() -> AsyncStream<AppNotification> {
        disposed = false
        reconnectDelay = 1.0
        socketAttempt = 0
        let stream = AsyncStream<AppNotification> { continuation in
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.disconnect() }
            }
        }
        openSocket()
        return stream
    }

    public func disconnect() {
        disposed = true
        logger.info("Disconnecting notification socket for \(baseURL.absoluteString)")
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        continuation?.finish()
        continuation = nil
    }

    private func openSocket() {
        guard !disposed else { return }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        components?.path = "/v1/notifications/ws"
        guard let wsURL = components?.url else {
            logger.error("Could not build notification socket URL from \(baseURL.absoluteString)")
            return
        }

        socketAttempt += 1
        logger.info("Opening notification socket attempt \(socketAttempt): \(wsURL.absoluteString)")
        let wsTask = ClientURLSessionFactory.session(for: baseURL).webSocketTask(with: wsURL)
        self.task = wsTask
        wsTask.resume()

        if let onConnect { Task { await onConnect() } }

        Task { await receiveLoop(task: wsTask) }
    }

    private func receiveLoop(task: URLSessionWebSocketTask) async {
        while !disposed {
            do {
                let message = try await task.receive()
                reconnectDelay = 1.0
                switch message {
                case .string(let text):
                    if let data = text.data(using: .utf8),
                       let notification = try? decoder.decode(AppNotification.self, from: data) {
                        continuation?.yield(notification)
                    }
                case .data(let data):
                    if let notification = try? decoder.decode(AppNotification.self, from: data) {
                        continuation?.yield(notification)
                    }
                @unknown default:
                    break
                }
            } catch {
                guard !disposed else { return }
                let delay = reconnectDelay
                logger.warning("Notification socket attempt \(socketAttempt) disconnected: \(error). Reconnecting in \(delay)s")
                self.task = nil
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                reconnectDelay = min(delay * 2, 30)
                if !disposed {
                    openSocket()
                }
                return
            }
        }
    }
}
