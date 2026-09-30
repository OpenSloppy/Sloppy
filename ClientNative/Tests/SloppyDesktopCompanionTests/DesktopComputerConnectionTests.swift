import Foundation
import Testing
import SloppyClientCore
@testable import SloppyDesktopCompanion

@Suite("Desktop computer reconnection")
@MainActor
struct DesktopComputerConnectionTests {
    @MainActor
    private final class Harness {
        struct Sleep {
            var duration: Duration
            var resume: () -> Void
        }
        var registrations: [DesktopComputerBinding] = []
        var polls = 0
        var completions = 0
        var disconnects: [DesktopComputerBinding] = []
        var sleeps: [Sleep] = []
        var registrationFailures = 0
        var pollError: Error?
        var command: DesktopComputerCommand?
        var completionError: Error?

        func dependencies() -> DesktopComputerConnection.Dependencies {
            .init(
                register: { binding in
                    self.registrations.append(binding)
                    if self.registrationFailures > 0 {
                        self.registrationFailures -= 1
                        throw URLError(.cannotConnectToHost)
                    }
                },
                poll: { _ in
                    self.polls += 1
                    if let error = self.pollError { self.pollError = nil; throw error }
                    let commands = self.command.map { [$0] } ?? []
                    self.command = nil
                    return .init(commands: commands)
                },
                complete: { _ in
                    self.completions += 1
                    if let error = self.completionError { throw error }
                },
                disconnect: { self.disconnects.append($0) },
                sleep: { duration in
                    let (stream, continuation) = AsyncStream<Void>.makeStream()
                    self.sleeps.append(.init(duration: duration, resume: { continuation.yield(()); continuation.finish() }))
                    for await _ in stream { break }
                    try Task.checkCancellation()
                }
            )
        }
    }

    private func binding() -> DesktopComputerBinding {
        .init(connectionId: UUID().uuidString, deviceId: UUID().uuidString, agentId: "agent", sessionId: "session")
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        #expect(condition(), "Connection did not reach the expected state")
        throw CancellationError()
    }

    @Test func expiredBindingRegistersAgainAfterDelayAndResumesPolling() async throws {
        let harness = Harness()
        harness.pollError = APIError.httpError(statusCode: 404, body: "computer_binding_unavailable")
        let connection = DesktopComputerConnection(capture: DesktopContextCapture(), dependencies: harness.dependencies())
        defer { connection.stopLocally() }
        var restored = 0
        connection.onReconnected = { restored += 1 }
        let binding = binding()
        try await connection.connect(binding)
        try await waitUntil { harness.sleeps.count == 1 }
        #expect(harness.sleeps[0].duration == .seconds(3))
        #expect(harness.registrations == [binding])
        harness.sleeps[0].resume()
        try await waitUntil { harness.sleeps.count == 2 }
        #expect(harness.registrations == [binding, binding])
        #expect(harness.polls == 2 && restored == 1)
        #expect(harness.sleeps[1].duration == .milliseconds(300))
    }

    @Test func initialNetworkFailureKeepsRetryingWithDelay() async throws {
        let harness = Harness()
        harness.registrationFailures = 2
        let connection = DesktopComputerConnection(capture: DesktopContextCapture(), dependencies: harness.dependencies())
        defer { connection.stopLocally() }
        try await connection.connect(binding())
        try await waitUntil { harness.sleeps.count == 1 }
        harness.sleeps[0].resume()
        try await waitUntil { harness.sleeps.count == 2 }
        #expect(harness.polls == 0)
        #expect(harness.sleeps.allSatisfy { $0.duration == .seconds(3) })
        harness.sleeps[1].resume()
        try await waitUntil { harness.sleeps.count == 3 }
        #expect(harness.registrations.count == 3 && harness.polls == 1)
    }

    @Test func stopDuringDelayPreventsRegistration() async throws {
        let harness = Harness()
        harness.pollError = URLError(.networkConnectionLost)
        let connection = DesktopComputerConnection(capture: DesktopContextCapture(), dependencies: harness.dependencies())
        try await connection.connect(binding())
        try await waitUntil { harness.sleeps.count == 1 }
        connection.stopLocally()
        harness.sleeps[0].resume()
        for _ in 0..<20 { await Task.yield() }
        #expect(connection.binding == nil)
        #expect(harness.registrations.count == 1 && harness.polls == 1)
    }

    @Test func replacingConnectionCancelsOldRetry() async throws {
        let harness = Harness()
        harness.pollError = URLError(.networkConnectionLost)
        let connection = DesktopComputerConnection(capture: DesktopContextCapture(), dependencies: harness.dependencies())
        defer { connection.stopLocally() }
        let old = binding(), next = binding()
        try await connection.connect(old)
        try await waitUntil { harness.sleeps.count == 1 }
        try await connection.connect(next)
        try await waitUntil { harness.sleeps.count == 2 }
        harness.sleeps[0].resume()
        for _ in 0..<20 { await Task.yield() }
        #expect(connection.binding == next)
        #expect(harness.registrations == [old, next])
    }

    @Test func authenticationFailureStopsWithoutAutomaticRetry() async throws {
        let harness = Harness()
        harness.pollError = APIError.httpError(statusCode: 401, body: nil)
        let connection = DesktopComputerConnection(capture: DesktopContextCapture(), dependencies: harness.dependencies())
        var reportedError: String?
        connection.onError = { reportedError = $0 }
        try await connection.connect(binding())
        try await waitUntil { reportedError != nil }
        #expect(connection.binding == nil)
        #expect(harness.registrations.count == 1 && harness.sleeps.isEmpty)
    }

    @Test func failedCompletionDeliveryDoesNotReplayCommand() async throws {
        let harness = Harness()
        harness.command = try JSONDecoder().decode(DesktopComputerCommand.self, from: Data(
            """
            {"id":"command","name":"unsupported","input":{},"expiresAt":\(Date().addingTimeInterval(60).timeIntervalSinceReferenceDate)}
            """.utf8))
        harness.completionError = URLError(.networkConnectionLost)
        let connection = DesktopComputerConnection(capture: DesktopContextCapture(), dependencies: harness.dependencies())
        defer { connection.stopLocally() }
        try await connection.connect(binding())
        try await waitUntil { harness.sleeps.count == 1 }
        harness.sleeps[0].resume()
        try await waitUntil { harness.sleeps.count == 2 }
        #expect(harness.completions == 1)
        #expect(harness.registrations.count == 2 && harness.polls == 2)
    }
}
