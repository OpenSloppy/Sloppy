import Foundation
import Logging
import Observation

@Observable
@MainActor
public final class ConnectionMonitor {
    public private(set) var state: ConnectionState = .disconnected
    public private(set) var checkedURL: URL?
    public private(set) var lastFailureMessage: String?

    private var baseURL: URL
    private var endpoint: SloppyInstanceEndpoint
    private var checkTask: Task<Void, Never>?
    private let logger: Logger
    private let checkInterval: TimeInterval = 10
    private var healthCheckAttempt = 0

    public init(
        baseURL: URL,
        logger: Logger = Logger(label: "sloppy.connection-monitor")
    ) {
        self.baseURL = baseURL
        self.endpoint = .direct(baseURL: baseURL)
        self.logger = logger
    }

    public func start(baseURL: URL) {
        start(endpoint: .direct(baseURL: baseURL))
    }

    public func start(endpoint: SloppyInstanceEndpoint) {
        self.endpoint = endpoint
        self.baseURL = endpoint.coordinatorBaseURL
        stop()
        state = .reconnecting
        checkedURL = baseURL.appendingPathComponent("health")
        lastFailureMessage = nil
        healthCheckAttempt = 0
        logger.info("Starting connection monitor for \(baseURL.absoluteString)")
        checkTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    public func stop() {
        if checkTask != nil {
            logger.info("Stopping connection monitor for \(baseURL.absoluteString)")
        }
        checkTask?.cancel()
        checkTask = nil
    }

    public func markDisconnected() {
        state = .disconnected
    }

    public func markReconnecting() {
        state = .reconnecting
    }

    private func runLoop() async {
        while !Task.isCancelled {
            let reachable = await checkHealth()
            if !Task.isCancelled {
                state = reachable ? .connected : .disconnected
            }
            try? await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))
        }
    }

    private func checkHealth() async -> Bool {
        checkedURL = baseURL.appendingPathComponent("health")
        healthCheckAttempt += 1

        let result = await HealthService(http: BackendHTTPClient(endpoint: endpoint)).check()
        lastFailureMessage = result.failureMessage

        if !result.isHealthy {
            logger.warning("Health check attempt \(healthCheckAttempt) failed: \(result.failureMessage ?? "unknown error")")
        }

        return result.isHealthy
    }
}
