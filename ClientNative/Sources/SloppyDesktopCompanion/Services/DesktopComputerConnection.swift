import Foundation
import AppKit
import SloppyClientCore
import SloppyComputerControl

@MainActor
final class DesktopComputerConnection {
    struct Dependencies {
        var register: (DesktopComputerBinding) async throws -> Void
        var poll: (DesktopComputerBinding) async throws -> DesktopComputerCommands
        var complete: (DesktopComputerCompletion) async throws -> Void
        var disconnect: (DesktopComputerBinding) async throws -> Void
        var sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    }

    private let dependencies: Dependencies
    private let capture: DesktopContextCapture
    private let input = DesktopComputerInput()
    private(set) var binding: DesktopComputerBinding?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    var onError: ((String) -> Void)?
    var onAction: (() -> Void)?
    var onReconnected: (() -> Void)?
    var screenPoint: CGPoint = .zero

    init(baseURL: URL, capture: DesktopContextCapture, tlsFingerprint: String? = nil,
         authSessionStore: AuthSessionStore = .shared) {
        let http = BackendHTTPClient(baseURL: baseURL, tlsFingerprint: tlsFingerprint, authSessionStore: authSessionStore)
        dependencies = Dependencies(
            register: { try await http.post("/v1/desktop-computer/register", body: $0) },
            poll: { try await http.post("/v1/desktop-computer/poll", body: $0) },
            complete: { try await http.post("/v1/desktop-computer/complete", body: $0) },
            disconnect: { try await http.post("/v1/desktop-computer/disconnect", body: $0) }
        )
        self.capture = capture
    }

    init(capture: DesktopContextCapture, dependencies: Dependencies) {
        self.capture = capture
        self.dependencies = dependencies
    }

    func connect(_ binding: DesktopComputerBinding) async throws {
        stopLocally()
        let generation = self.generation
        self.binding = binding
        var needsRegistration = false
        do {
            try await register(binding, generation: generation)
        } catch {
            guard self.generation == generation else { throw CancellationError() }
            if Task.isCancelled { stopLocally(); throw CancellationError() }
            guard Self.canRetry(error) else { stopLocally(); throw error }
            needsRegistration = true
            reportRetry(error)
        }
        task = Task { [weak self, needsRegistration] in
            guard let self else { return }
            await self.poll(binding, generation: generation, needsRegistration: needsRegistration)
        }
    }

    private func register(_ binding: DesktopComputerBinding, generation: UUID) async throws {
        try await dependencies.register(binding)
        guard self.generation == generation, !Task.isCancelled else {
            try? await dependencies.disconnect(binding)
            throw CancellationError()
        }
    }

    private func poll(_ binding: DesktopComputerBinding, generation: UUID, needsRegistration: Bool) async {
        var needsRegistration = needsRegistration
        while !Task.isCancelled, self.generation == generation {
            do {
                if needsRegistration {
                    try await dependencies.sleep(.seconds(3))
                    guard self.generation == generation, !Task.isCancelled else { return }
                    try await register(binding, generation: generation)
                    needsRegistration = false
                    onReconnected?()
                }
                let result = try await dependencies.poll(binding)
                for command in result.commands {
                    guard !Task.isCancelled, self.generation == generation, self.binding == binding,
                          command.expiresAt > Date() else { continue }
                    let completion = await perform(command, binding: binding, generation: generation)
                    guard self.generation == generation, !Task.isCancelled else { return }
                    // A failed delivery must never replay the computer action.
                    try await dependencies.complete(completion)
                }
                try await dependencies.sleep(.milliseconds(300))
            } catch is CancellationError {
                return
            } catch {
                guard self.generation == generation, !Task.isCancelled else { return }
                guard Self.canRetry(error) else {
                    stopLocally()
                    onError?("Computer control disconnected: " + error.localizedDescription)
                    return
                }
                needsRegistration = true
                reportRetry(error)
            }
        }
    }

    private func reportRetry(_ error: Error) {
        onError?("Computer control reconnecting in 3 seconds: " + error.localizedDescription)
    }

    private static func canRetry(_ error: Error) -> Bool {
        if let apiError = error as? APIError, let status = apiError.statusCode {
            return status == 404 || status == 408 || status == 429 || status >= 500
        }
        return error is URLError && (error as? URLError)?.code != .cancelled
    }

    /// Revoke locally before any network await: Stop must not wait for Core.
    func stopLocally() {
        generation = UUID()
        task?.cancel()
        task = nil
        binding = nil
    }

    func disconnect() async {
        let old = binding
        stopLocally()
        if let old { try? await dependencies.disconnect(old) }
    }

    private func perform(_ command: DesktopComputerCommand, binding: DesktopComputerBinding, generation: UUID) async -> DesktopComputerCompletion {
        do {
            guard self.generation == generation, command.expiresAt > Date() else { throw CancellationError() }
            if command.name == "computer.screenshot" {
                let image = try await capture.captureDisplay(at: screenPoint)
                return .init(binding: binding, commandId: command.id, data: image.result, imageBase64: image.png.base64EncodedString())
            }
            guard AXIsProcessTrusted() else {
                throw ComputerControlError.permissionDenied("Enable Accessibility for Sloppy Desktop Companion.")
            }
            onAction?()
            switch command.name {
            case "computer.click":
                try input.click(command.input)
            case "computer.type":
                try await input.type(command.input.text ?? "") {
                    self.generation == generation && command.expiresAt > Date()
                }
            case "computer.key":
                try input.key(command.input)
            default:
                throw ComputerControlError.invalidArguments("Unsupported desktop command.")
            }
            return .init(binding: binding, commandId: command.id, data: .init())
        } catch {
            return .init(binding: binding, commandId: command.id, error: error.localizedDescription)
        }
    }
}
