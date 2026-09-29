import Foundation
import Protocols

struct DesktopComputerBinding: Codable, Sendable, Equatable {
    var connectionId: String
    var deviceId: String
    var agentId: String
    var sessionId: String
}

struct DesktopComputerCommand: Codable, Sendable {
    var id: String
    var name: String
    var input: JSONValue
    var expiresAt: Date
}

struct DesktopComputerCommands: Codable, Sendable {
    var commands: [DesktopComputerCommand]
}

struct DesktopComputerCompletion: Codable, Sendable {
    var binding: DesktopComputerBinding
    var commandId: String
    var data: JSONValue?
    var imageBase64: String?
    var error: String?
}

enum DesktopComputerBridgeError: Error, LocalizedError, Equatable {
    case unavailable, conflict, unknownCommand, timedOut, commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "The desktop companion is disconnected or computer control is stopped. Reconnect it on the original Mac."
        case .conflict: "This session belongs to another desktop companion."
        case .unknownCommand: "The computer command has expired or belongs to another connection."
        case .timedOut: "The computer command timed out. Capture the screen before trying another action."
        case .commandFailed(let message): message
        }
    }
}

/// Outbound polling keeps the companion behind the Core's existing authentication.
/// Durable device assignments forbid falling back to Core's computer after disconnect/restart.
actor DesktopComputerBridgeService {
    private struct Connection {
        var binding: DesktopComputerBinding
        var lastSeen: Date
    }
    private struct Pending {
        var binding: DesktopComputerBinding
        var command: DesktopComputerCommand
        var continuation: CheckedContinuation<JSONValue, Error>
        var timer: Task<Void, Never>
    }
    private var assignments: [String: String]
    private var connections: [String: Connection] = [:]
    private var pending: [String: Pending] = [:]
    private var queues: [String: [String]] = [:]
    private let assignmentsURL: URL?
    private let lease: TimeInterval
    private let commandTimeout: TimeInterval

    init(assignmentsURL: URL? = nil, lease: TimeInterval = 10, commandTimeout: TimeInterval = 15) {
        self.assignmentsURL = assignmentsURL
        self.lease = lease
        self.commandTimeout = commandTimeout
        if let assignmentsURL, FileManager.default.fileExists(atPath: assignmentsURL.path) {
            // A damaged or unreadable registry fails closed.
            self.assignments = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: assignmentsURL))) ?? ["*": "invalid"]
        } else {
            self.assignments = [:]
        }
    }

    private func key(agentID: String, sessionID: String) -> String { agentID + "/" + sessionID }

    func isAssigned(agentID: String, sessionID: String) -> Bool {
        assignments["*"] != nil || assignments[key(agentID: agentID, sessionID: sessionID)] != nil
    }

    /// Delegated sessions retain the device restriction. They cannot silently control Core's host.
    func inheritAssignment(parentSessionID: String, agentID: String, sessionID: String) throws {
        guard let parent = assignments.first(where: { $0.key.hasSuffix("/" + parentSessionID) }) else { return }
        var next = assignments
        next[key(agentID: agentID, sessionID: sessionID)] = parent.value
        if let assignmentsURL {
            try FileManager.default.createDirectory(at: assignmentsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: assignmentsURL, options: .atomic)
        }
        assignments = next
    }

    func register(_ binding: DesktopComputerBinding) throws {
        guard UUID(uuidString: binding.connectionId) != nil, UUID(uuidString: binding.deviceId) != nil,
              !binding.agentId.isEmpty, !binding.sessionId.isEmpty, assignments["*"] == nil else {
            throw DesktopComputerBridgeError.unavailable
        }
        let key = key(agentID: binding.agentId, sessionID: binding.sessionId)
        if let device = assignments[key], device != binding.deviceId { throw DesktopComputerBridgeError.conflict }
        if let connection = connections[key], connection.binding != binding {
            guard Date().timeIntervalSince(connection.lastSeen) > lease else { throw DesktopComputerBridgeError.conflict }
            disconnect(connection.binding)
        }
        var next = assignments
        next[key] = binding.deviceId
        if let assignmentsURL {
            try FileManager.default.createDirectory(at: assignmentsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: assignmentsURL, options: .atomic)
        }
        assignments = next
        connections[key] = Connection(binding: binding, lastSeen: Date())
    }

    func poll(_ binding: DesktopComputerBinding) throws -> DesktopComputerCommands {
        try validate(binding)
        connections[key(agentID: binding.agentId, sessionID: binding.sessionId)]?.lastSeen = Date()
        let ids = queues.removeValue(forKey: binding.connectionId) ?? []
        return DesktopComputerCommands(commands: ids.compactMap { pending[$0]?.command })
    }

    func complete(_ result: DesktopComputerCompletion) throws {
        try validate(result.binding)
        guard let command = pending[result.commandId], command.binding == result.binding else {
            throw DesktopComputerBridgeError.unknownCommand
        }
        pending.removeValue(forKey: result.commandId)
        command.timer.cancel()
        if let error = result.error {
            command.continuation.resume(throwing: DesktopComputerBridgeError.commandFailed(error))
        } else {
            var data = result.data?.asObject ?? [:]
            if let image = result.imageBase64 { data["imageBase64"] = .string(image) }
            data["deviceId"] = .string(result.binding.deviceId)
            data["surface"] = .string("desktop_companion")
            command.continuation.resume(returning: .object(data))
        }
    }

    func run(agentID: String, sessionID: String, name: String, input: JSONValue) async throws -> JSONValue {
        let key = key(agentID: agentID, sessionID: sessionID)
        guard let connection = connections[key], Date().timeIntervalSince(connection.lastSeen) <= lease else {
            throw DesktopComputerBridgeError.unavailable
        }
        guard !pending.values.contains(where: { $0.binding == connection.binding }) else {
            throw DesktopComputerBridgeError.commandFailed("Another computer action is still running.")
        }
        let id = UUID().uuidString
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let command = DesktopComputerCommand(id: id, name: name, input: input,
                                                     expiresAt: Date().addingTimeInterval(commandTimeout))
                let timer = Task {
                    do { try await Task.sleep(for: .seconds(commandTimeout)) } catch { return }
                    finish(id, error: DesktopComputerBridgeError.timedOut)
                }
                pending[id] = Pending(binding: connection.binding, command: command, continuation: continuation, timer: timer)
                queues[connection.binding.connectionId, default: []].append(id)
            }
        } onCancel: {
            Task { await self.finish(id, error: CancellationError()) }
        }
    }

    func disconnect(_ binding: DesktopComputerBinding) {
        let key = key(agentID: binding.agentId, sessionID: binding.sessionId)
        guard connections[key]?.binding == binding else { return }
        connections.removeValue(forKey: key)
        queues.removeValue(forKey: binding.connectionId)
        for id in pending.keys.filter({ pending[$0]?.binding == binding }) {
            finish(id, error: DesktopComputerBridgeError.unavailable)
        }
    }

    func cleanup(sessionID: String) {
        for connection in Array(connections.values) where connection.binding.sessionId == sessionID { disconnect(connection.binding) }
    }

    func shutdown() { for connection in Array(connections.values) { disconnect(connection.binding) } }

    private func validate(_ binding: DesktopComputerBinding) throws {
        guard let connection = connections[key(agentID: binding.agentId, sessionID: binding.sessionId)],
              connection.binding == binding, Date().timeIntervalSince(connection.lastSeen) <= lease else {
            throw DesktopComputerBridgeError.unavailable
        }
    }

    private func finish(_ id: String, error: Error) {
        guard let command = pending.removeValue(forKey: id) else { return }
        queues[command.binding.connectionId]?.removeAll { $0 == id }
        command.timer.cancel()
        command.continuation.resume(throwing: error)
    }
}
