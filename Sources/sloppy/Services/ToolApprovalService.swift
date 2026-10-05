import Foundation
import AgentRuntime
import Protocols

enum ToolApprovalWaitResult: Sendable, Equatable {
    case approved(ToolApprovalRecord)
    case rejected(ToolApprovalRecord)
    case timedOut(ToolApprovalRecord)
}

actor ToolApprovalService {
    private struct PendingApproval {
        var record: ToolApprovalRecord
        var continuations: [CheckedContinuation<ToolApprovalWaitResult, Never>]
        var requestPublished: Bool
    }

    static let defaultTimeoutSeconds: TimeInterval = 600

    private let eventBus: EventBus
    private let notificationService: NotificationService
    private var pending: [String: PendingApproval] = [:]
    private var resolvedBeforeWait: [String: ToolApprovalRecord] = [:]
    private let isoFormatter = ISO8601DateFormatter()

    init(eventBus: EventBus, notificationService: NotificationService) {
        self.eventBus = eventBus
        self.notificationService = notificationService
    }

    func listPending(includeUnpublished: Bool = false) -> [ToolApprovalRecord] {
        pending.values
            .filter { includeUnpublished || $0.requestPublished }
            .map(\.record)
            .filter { $0.status == .pending }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func createPending(
        agentId: String,
        sessionId: String?,
        displaySessionId: String? = nil,
        channelId: String?,
        topicId: String?,
        toolCallId: String? = nil,
        request: ToolInvocationRequest,
        approvalKind: ToolApprovalKind? = nil,
        grants: [ToolApprovalGrant] = [],
        requestedBy: String? = nil,
        timeoutSeconds: TimeInterval = ToolApprovalService.defaultTimeoutSeconds,
        publishRequest: Bool = true
    ) async -> ToolApprovalRecord {
        let now = Date()
        let record = ToolApprovalRecord(
            approvalKind: approvalKind,
            agentId: agentId,
            sessionId: sessionId,
            displaySessionId: displaySessionId,
            channelId: channelId,
            topicId: topicId,
            toolCallId: toolCallId,
            tool: request.tool,
            arguments: request.arguments,
            grants: grants,
            reason: request.reason,
            requestedBy: requestedBy,
            createdAt: now,
            updatedAt: now,
            expiresAt: now.addingTimeInterval(timeoutSeconds)
        )
        pending[record.id] = PendingApproval(record: record, continuations: [], requestPublished: false)
        if publishRequest { await publishPendingRequest(id: record.id) }
        return record
    }

    func publishPendingRequest(id: String) async {
        guard var entry = pending[id], entry.record.status == .pending, !entry.requestPublished else { return }
        entry.requestPublished = true
        pending[id] = entry
        let record = entry.record
        await emit(record: record, messageType: .toolApprovalRequested)
        await notificationService.pushToolApproval(record)
    }

    func waitForDecision(id: String, timeoutSeconds: TimeInterval = ToolApprovalService.defaultTimeoutSeconds) async -> ToolApprovalWaitResult {
        if let existing = pending[id]?.record, existing.status != .pending {
            return waitResult(for: existing)
        }
        if let resolved = resolvedBeforeWait.removeValue(forKey: id) {
            return waitResult(for: resolved)
        }

        let timeoutNanoseconds = UInt64(max(0.1, timeoutSeconds) * 1_000_000_000)
        Task {
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            _ = await self.timeout(id: id)
        }

        return await withCheckedContinuation { continuation in
            guard var entry = pending[id] else {
                continuation.resume(returning: .timedOut(ToolApprovalRecord(
                    id: id,
                    status: .timedOut,
                    agentId: "",
                    tool: "",
                    expiresAt: Date()
                )))
                return
            }
            if entry.record.status != .pending {
                continuation.resume(returning: waitResult(for: entry.record))
                return
            }
            entry.continuations.append(continuation)
            pending[id] = entry
        }
    }

    func approve(id: String, decidedBy: String?, decisionReason: String? = nil) async -> ToolApprovalRecord? {
        await resolve(id: id, status: .approved, decidedBy: decidedBy, decisionReason: decisionReason)
    }

    func reject(id: String, decidedBy: String?, decisionReason: String? = nil) async -> ToolApprovalRecord? {
        await resolve(id: id, status: .rejected, decidedBy: decidedBy, decisionReason: decisionReason)
    }

    @discardableResult
    func timeout(id: String) async -> ToolApprovalRecord? {
        await resolve(id: id, status: .timedOut, decidedBy: nil, decisionReason: nil)
    }

    private func resolve(
        id: String,
        status: ToolApprovalStatus,
        decidedBy: String?,
        decisionReason: String?
    ) async -> ToolApprovalRecord? {
        guard var entry = pending[id], entry.record.status == .pending else {
            return pending[id]?.record
        }

        entry.record.status = status
        entry.record.decidedBy = decidedBy
        entry.record.decisionReason = decisionReason
        entry.record.updatedAt = Date()
        pending[id] = entry

        let result = waitResult(for: entry.record)
        let continuations = entry.continuations
        if continuations.isEmpty {
            resolvedBeforeWait[id] = entry.record
            if resolvedBeforeWait.count > 256,
               let oldestID = resolvedBeforeWait.min(by: { $0.value.updatedAt < $1.value.updatedAt })?.key
            {
                resolvedBeforeWait.removeValue(forKey: oldestID)
            }
        }
        pending[id]?.continuations.removeAll()
        if status != .pending {
            pending.removeValue(forKey: id)
        }
        for continuation in continuations {
            continuation.resume(returning: result)
        }

        await emit(record: entry.record, messageType: .toolApprovalResolved)
        await notificationService.pushToolApproval(entry.record)
        return entry.record
    }

    private func waitResult(for record: ToolApprovalRecord) -> ToolApprovalWaitResult {
        switch record.status {
        case .approved:
            return .approved(record)
        case .rejected:
            return .rejected(record)
        case .pending, .timedOut:
            return .timedOut(record)
        }
    }

    private func emit(record: ToolApprovalRecord, messageType: MessageType) async {
        var payload: [String: JSONValue] = [
            "approvalId": .string(record.id),
            "status": .string(record.status.rawValue),
            "agentId": .string(record.agentId),
            "tool": .string(record.tool),
            "arguments": .object(record.arguments),
            "grants": .array(record.grants.map { grant in
                var object: [String: JSONValue] = [
                    "kind": .string(grant.kind.rawValue),
                    "tool": .string(grant.tool)
                ]
                if let operation = grant.operation { object["operation"] = .string(operation) }
                if let resource = grant.resource { object["resource"] = .string(resource) }
                return .object(object)
            }),
            "createdAt": .string(isoFormatter.string(from: record.createdAt)),
            "updatedAt": .string(isoFormatter.string(from: record.updatedAt)),
            "expiresAt": .string(isoFormatter.string(from: record.expiresAt))
        ]
        if let approvalKind = record.approvalKind { payload["approvalKind"] = .string(approvalKind.rawValue) }
        if let sessionId = record.sessionId { payload["sessionId"] = .string(sessionId) }
        if let displaySessionId = record.displaySessionId { payload["displaySessionId"] = .string(displaySessionId) }
        if let channelId = record.channelId { payload["channelId"] = .string(channelId) }
        if let topicId = record.topicId { payload["topicId"] = .string(topicId) }
        if let toolCallId = record.toolCallId { payload["toolCallId"] = .string(toolCallId) }
        if let reason = record.reason { payload["reason"] = .string(reason) }
        if let requestedBy = record.requestedBy { payload["requestedBy"] = .string(requestedBy) }
        if let decidedBy = record.decidedBy { payload["decidedBy"] = .string(decidedBy) }
        if let decisionReason = record.decisionReason { payload["decisionReason"] = .string(decisionReason) }

        await eventBus.publish(EventEnvelope(
            messageType: messageType,
            channelId: record.channelId ?? record.displaySessionId ?? record.sessionId ?? "agent:\(record.agentId)",
            payload: .object(payload)
        ))
    }
}
