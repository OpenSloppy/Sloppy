import Foundation
import AppKit
import SloppyClientCore
import SloppyComputerControl

@MainActor
final class DesktopComputerConnection {
    private let http: BackendHTTPClient
    private let capture: DesktopContextCapture
    private let input = DesktopComputerInput()
    private(set) var binding: DesktopComputerBinding?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    var onError: ((String) -> Void)?
    var onAction: (() -> Void)?
    var screenPoint: CGPoint = .zero

    init(baseURL: URL, capture: DesktopContextCapture, tlsFingerprint: String? = nil,
         authSessionStore: AuthSessionStore = .shared) {
        http = BackendHTTPClient(baseURL: baseURL, tlsFingerprint: tlsFingerprint, authSessionStore: authSessionStore)
        self.capture = capture
    }

    func connect(_ binding: DesktopComputerBinding) async throws {
        stopLocally()
        let generation = self.generation
        try await http.post("/v1/desktop-computer/register", body: binding)
        guard self.generation == generation else {
            try? await http.post("/v1/desktop-computer/disconnect", body: binding)
            throw CancellationError()
        }
        self.binding = binding
        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.generation == generation {
                do {
                    let result: DesktopComputerCommands = try await self.http.post("/v1/desktop-computer/poll", body: binding)
                    for command in result.commands {
                        guard !Task.isCancelled, self.generation == generation, self.binding == binding,
                              command.expiresAt > Date() else { continue }
                        let completion = await self.perform(command, binding: binding, generation: generation)
                        guard self.generation == generation, !Task.isCancelled else { return }
                        try await self.http.post("/v1/desktop-computer/complete", body: completion)
                    }
                    try await Task.sleep(for: .milliseconds(300))
                } catch is CancellationError {
                    return
                } catch {
                    guard self.generation == generation else { return }
                    self.stopLocally()
                    self.onError?("Computer control disconnected: " + error.localizedDescription)
                    return
                }
            }
        }
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
        if let old { try? await http.post("/v1/desktop-computer/disconnect", body: old) }
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
