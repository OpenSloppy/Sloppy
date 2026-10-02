import Foundation
import Protocols

/// CoreService owns this store. Transactions write atomically before publishing their new state.
final class LongChatFileStore {
    enum StoreError: Error { case invalidPayload, notFound, conflict, retryLimit }

    struct Turn: Codable, Sendable {
        var id: String
        var agentId: String
        var sessionId: String
        var request: AgentSessionPostMessageRequest
        var isNotification: Bool
        var processing = false
        var delivered = false
    }

    struct State: Codable {
        var conversations: [LongChatConversation] = []
        var turns: [Turn] = []
        var cancelledSourceMessageIds: [String]?
    }

    private let url: URL
    private(set) var state: State

    init(root: URL) throws {
        url = root.appendingPathComponent("long-chat/state.json")
        if FileManager.default.fileExists(atPath: url.path) {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
        } else {
            state = State()
        }
    }

    @discardableResult
    func transaction<T>(_ body: (inout State) throws -> T) throws -> T {
        var next = state
        let result = try body(&next)
        let data = try JSONEncoder().encode(next)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        state = next
        return result
    }

    func conversation(sessionId: String) throws -> LongChatConversation {
        guard let result = state.conversations.first(where: { $0.sessionId == sessionId }) else {
            throw StoreError.notFound
        }
        return result
    }

    func delegate(sessionId: String, sourceMessageId: String, request: LongChatDelegationRequest) throws
        -> LongChatAssignment
    {
        try transaction { state in
            guard state.cancelledSourceMessageIds?.contains(sourceMessageId) != true else { throw StoreError.conflict }
            guard let index = state.conversations.firstIndex(where: { $0.sessionId == sessionId }) else {
                throw StoreError.notFound
            }
            if let existing = state.conversations[index].assignments.first(where: {
                $0.sourceMessageId == sourceMessageId && $0.requestKey == request.requestKey
            }) {
                return existing
            }
            let keys = Set(request.tasks.map(\.key))
            guard !request.requestKey.isEmpty, !request.title.isEmpty, !request.acceptanceCriteria.isEmpty,
                !request.tasks.isEmpty, request.tasks.count <= 20, keys.count == request.tasks.count,
                request.tasks.allSatisfy({
                    !$0.key.isEmpty && !$0.title.isEmpty && !$0.objective.isEmpty
                        && Set($0.dependsOn).isSubset(of: keys) && !$0.dependsOn.contains($0.key)
                })
            else { throw StoreError.invalidPayload }
            var resolved = Set<String>()
            while resolved.count < keys.count {
                let ready = request.tasks.filter {
                    !resolved.contains($0.key) && Set($0.dependsOn).isSubset(of: resolved)
                }
                guard !ready.isEmpty else { throw StoreError.invalidPayload }
                resolved.formUnion(ready.map(\.key))
            }
            let assignment = LongChatAssignment(
                id: UUID().uuidString, sourceMessageId: sourceMessageId, requestKey: request.requestKey,
                title: request.title, acceptanceCriteria: request.acceptanceCriteria,
                tasks: request.tasks.map { task in
                    LongChatTask(
                        id: UUID().uuidString, key: task.key, title: task.title, objective: task.objective,
                        projectId: task.projectId, resourceKeys: task.resourceKeys, dependsOn: task.dependsOn,
                        attempts: [LongChatAttempt(number: 1)], readOnly: task.readOnly ?? task.resourceKeys.isEmpty)
                }, createdAt: Date()
            )
            state.conversations[index].assignments.append(assignment)
            return assignment
        }
    }

    func updateTask<T>(sessionId: String, taskId: String, _ body: (inout LongChatTask) throws -> T) throws -> T {
        try transaction { state in
            guard let c = state.conversations.firstIndex(where: { $0.sessionId == sessionId }) else {
                throw StoreError.notFound
            }
            for a in state.conversations[c].assignments.indices {
                if let t = state.conversations[c].assignments[a].tasks.firstIndex(where: { $0.id == taskId }) {
                    return try body(&state.conversations[c].assignments[a].tasks[t])
                }
            }
            throw StoreError.notFound
        }
    }

    /// Fail dependent work when a prerequisite fails; restore only never-started dependent work after repair.
    func resolveDependencies(sessionId: String) throws -> [(String, LongChatTaskStatus)] {
        try transaction { state in
            guard let c = state.conversations.firstIndex(where: { $0.sessionId == sessionId }) else {
                throw StoreError.notFound
            }
            var changes: [(String, LongChatTaskStatus)] = []
            for a in state.conversations[c].assignments.indices {
                var tasks = state.conversations[c].assignments[a].tasks
                var changed = true
                while changed {
                    changed = false
                    for i in tasks.indices {
                        let dependencies = tasks.filter { tasks[i].dependsOn.contains($0.key) }
                        let failed = dependencies.first { $0.status == .failed || $0.status == .cancelled }
                        let attempt = tasks[i].attempts.count - 1
                        if tasks[i].status == .queued, let failed {
                            tasks[i].attempts[attempt].status = .failed
                            tasks[i].attempts[attempt].blockedByTaskId = failed.id
                            tasks[i].attempts[attempt].summary = "Prerequisite \(failed.title) did not complete."
                            tasks[i].attempts[attempt].automaticRetryAllowed = false
                            changes.append((tasks[i].id, .failed))
                            changed = true
                        } else if tasks[i].status == .failed, tasks[i].attempts[attempt].blockedByTaskId != nil,
                            tasks[i].attempts[attempt].sessionId == nil, failed == nil
                        {
                            tasks[i].attempts[attempt].status = .queued
                            tasks[i].attempts[attempt].blockedByTaskId = nil
                            tasks[i].attempts[attempt].summary = nil
                            tasks[i].attempts[attempt].automaticRetryAllowed = nil
                            changes.append((tasks[i].id, .queued))
                            changed = true
                        }
                    }
                }
                state.conversations[c].assignments[a].tasks = tasks
            }
            return changes
        }
    }

    /// Resource locks are global; concurrency is bounded per conversation.
    func runnableTasks(sessionId: String) throws -> [(assignment: LongChatAssignment, task: LongChatTask)] {
        let conversation = try conversation(sessionId: sessionId)
        let all = state.conversations.flatMap(\.assignments).flatMap(\.tasks)
        let occupied = Set(
            all.filter {
                $0.readOnly != true
                    && ($0.status == .running || $0.status == .waitingInput
                        || ($0.status.isTerminal && $0.attempts.last?.executionStopped == false))
            }.flatMap(\.resourceKeys))
        let active = conversation.assignments.flatMap(\.tasks).filter {
            $0.status == .running || $0.status == .waitingInput
                || ($0.status.isTerminal && $0.attempts.last?.executionStopped == false)
        }.count
        var locks = occupied
        var result: [(LongChatAssignment, LongChatTask)] = []
        for assignment in conversation.assignments {
            for task in assignment.tasks where task.status == .queued {
                guard result.count < max(0, 3 - active),
                    task.readOnly == true || locks.isDisjoint(with: task.resourceKeys),
                    task.dependsOn.allSatisfy({ key in
                        assignment.tasks.contains { $0.key == key && $0.status == .completed }
                    })
                else { continue }
                result.append((assignment, task))
                if task.readOnly != true { locks.formUnion(task.resourceKeys) }
            }
        }
        return result
    }
}
