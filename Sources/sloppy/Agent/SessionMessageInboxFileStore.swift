import Foundation
import Protocols

/// Owned by CoreService; an accepted receipt always follows an atomic write.
final class SessionMessageInboxFileStore {
    enum State: String, Codable, Sendable { case queued, processing, delivered, failed, interrupted }
    struct Entry: Codable, Sendable {
        var id: String
        var agentId: String
        var sessionId: String
        var request: AgentSessionPostMessageRequest
        var origin: AgentSessionPeerOrigin?
        var state: State = .queued
        var error: String?
    }

    private let url: URL
    private let scopesURL: URL
    private(set) var scopes: [String: [String]]
    private(set) var entries: [Entry]

    init(root: URL) throws {
        url = root.appendingPathComponent("session-messages/inbox.json")
        scopesURL = root.appendingPathComponent("session-messages/worker-scopes.json")
        scopes = FileManager.default.fileExists(atPath: scopesURL.path)
            ? try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: scopesURL)) : [:]
        entries = FileManager.default.fileExists(atPath: url.path)
            ? try JSONDecoder().decode([Entry].self, from: Data(contentsOf: url)) : []
    }

    func transaction(_ update: (inout [Entry]) throws -> Void) throws {
        var next = entries
        try update(&next)
        let data = try JSONEncoder().encode(next)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        entries = next
    }

    func enqueue(_ entry: Entry) throws -> Entry {
        if let existing = entries.first(where: { $0.id == entry.id }) {
            guard existing.agentId == entry.agentId, existing.sessionId == entry.sessionId,
                  existing.request.content == entry.request.content,
                  existing.origin?.agentId == entry.origin?.agentId,
                  existing.origin?.sessionId == entry.origin?.sessionId else { throw PeerSessionMessageError.conflict }
            return existing
        }
        try transaction { $0.append(entry) }
        return entry
    }

    func rememberScope(sessionID: String, toolIDs: Set<String>) throws {
        var next = scopes
        next[sessionID] = toolIDs.sorted()
        try FileManager.default.createDirectory(at: scopesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: scopesURL, options: .atomic)
        scopes = next
    }

    func update(id: String, state: State, error: String? = nil) throws {
        try transaction { entries in
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
            entries[index].state = state
            entries[index].error = error
        }
    }
}

enum PeerSessionMessageError: Error {
    case conflict, invalidArguments, chainLimit, selfMessage, workerUnavailable
    var code: String {
        switch self {
        case .conflict: "message_id_conflict"
        case .invalidArguments: "invalid_arguments"
        case .chainLimit: "message_chain_limit"
        case .selfMessage: "self_message"
        case .workerUnavailable: "worker_scope_unavailable"
        }
    }
    var description: String {
        switch self {
        case .conflict: "This messageId was already used for a different delivery."
        case .invalidArguments: "A valid target, nonempty content and an optional UUID messageId are required."
        case .chainLimit: "This automatic message chain has reached eight deliveries. Wait for a new user turn."
        case .selfMessage: "Use the current context directly; a session cannot message itself."
        case .workerUnavailable: "The worker's original execution scope is unavailable."
        }
    }
}
