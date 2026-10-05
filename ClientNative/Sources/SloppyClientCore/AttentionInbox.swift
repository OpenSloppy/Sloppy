import Foundation
import Observation

extension ProactiveFinding {
    public func isActiveAttention(at date: Date) -> Bool {
        let isSnoozed = snoozedUntil.map { $0 > date } ?? false
        return outcome != .quiet && dismissedAt == nil && resolvedAt == nil && !isSnoozed
    }

    public func needsAttention(at date: Date) -> Bool {
        readAt == nil && isActiveAttention(at: date)
    }
}

@Observable
@MainActor
public final class AttentionInbox {
    public private(set) var findings: [ProactiveFinding] = []
    public private(set) var agentNames: [String: String] = [:]
    public private(set) var lastCheckedAt: Date?
    public private(set) var pendingAnalysisCount = 0
    public private(set) var errors: [String] = []
    public private(set) var isLoading = false
    public private(set) var hasLoaded = false
    public private(set) var busyFindingIDs: Set<String> = []
    private var inboxes: [String: ProactiveInbox] = [:]
    private var actionRevision = 0
    private let fetchAgents: @Sendable () async throws -> [APIAgentRecord]
    private let fetchInbox: @Sendable (String) async throws -> ProactiveInbox
    private let updateFinding: @Sendable (String, String, ProactiveFindingActionRequest.Action) async throws -> ProactiveFinding

    public convenience init(apiClient: SloppyAPIClient) {
        self.init(fetchAgents: { try await apiClient.fetchAgents() },
                  fetchInbox: { try await apiClient.fetchProactiveInbox(agentId: $0) },
                  updateFinding: { try await apiClient.updateProactiveFinding(agentId: $0, findingId: $1, action: $2) })
    }

    public init(
        fetchAgents: @escaping @Sendable () async throws -> [APIAgentRecord],
        fetchInbox: @escaping @Sendable (String) async throws -> ProactiveInbox,
        updateFinding: @escaping @Sendable (String, String, ProactiveFindingActionRequest.Action) async throws -> ProactiveFinding
    ) {
        self.fetchAgents = fetchAgents
        self.fetchInbox = fetchInbox
        self.updateFinding = updateFinding
    }

    public var unreadCount: Int { unreadCount(at: Date()) }

    public func unreadCount(at date: Date) -> Int {
        findings.filter { $0.needsAttention(at: date) }.count
    }

    public func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let revision = actionRevision
        do {
            let agents = try await fetchAgents()
            let results = await withTaskGroup(of: InboxResult.self) { group in
                for agent in agents {
                    group.addTask { [fetchInbox] in
                        do { return InboxResult(agentID: agent.id, inbox: try await fetchInbox(agent.id), error: nil) }
                        catch { return InboxResult(agentID: agent.id, inbox: nil, error: error.localizedDescription) }
                    }
                }
                var results: [InboxResult] = []
                for await result in group { results.append(result) }
                return results
            }
            guard !Task.isCancelled, revision == actionRevision, busyFindingIDs.isEmpty else { return }
            agentNames = Dictionary(agents.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
            inboxes = inboxes.filter { agentNames[$0.key] != nil }
            var loadErrors: [String] = []
            for result in results {
                if let inbox = result.inbox { inboxes[result.agentID] = inbox }
                if let error = result.error { loadErrors.append("\(agentNames[result.agentID] ?? result.agentID): \(error)") }
            }
            rebuildFindings()
            lastCheckedAt = inboxes.values.compactMap(\.lastCheckedAt).min()
            pendingAnalysisCount = inboxes.values.reduce(0) { $0 + $1.pendingAnalysisCount }
            for agentID in inboxes.keys.sorted() {
                guard let inbox = inboxes[agentID] else { continue }
                let name = agentNames[agentID] ?? agentID
                for source in inbox.sourceErrors.keys.sorted() {
                    loadErrors.append("\(name) · \(source): \(inbox.sourceErrors[source] ?? "")")
                }
                if let error = inbox.lastAnalysisError { loadErrors.append("\(name): \(error)") }
            }
            errors = loadErrors.sorted()
            hasLoaded = true
        } catch is CancellationError { return }
        catch { errors = [error.localizedDescription] }
    }

    public func act(_ finding: ProactiveFinding, action: ProactiveFindingActionRequest.Action) async {
        guard busyFindingIDs.insert(finding.id).inserted else { return }
        actionRevision += 1
        defer {
            busyFindingIDs.remove(finding.id)
            actionRevision += 1
        }
        do {
            let updated = try await updateFinding(finding.agentId, finding.id, action)
            if let index = inboxes[finding.agentId]?.findings.firstIndex(where: { $0.id == finding.id }) {
                inboxes[finding.agentId]?.findings[index] = updated
            }
            rebuildFindings()
        } catch { errors = [error.localizedDescription] }
    }

    private func rebuildFindings() {
        findings = inboxes.values.flatMap(\.findings).sorted {
            $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt
        }
    }

    private struct InboxResult: Sendable {
        let agentID: String
        let inbox: ProactiveInbox?
        let error: String?
    }
}
