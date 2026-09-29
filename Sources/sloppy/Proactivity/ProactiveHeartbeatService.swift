import Foundation
import Protocols

enum ProactivePersistenceError: Error { case database }
enum ProactiveHeartbeatError: Error { case findingNotFound, invalidReport, missingReport, modelUnavailable, configurationChanged }

struct ProactiveSnapshot: Codable, Sendable, Equatable {
    var source: ProactiveSource
    var scope: String
    var revision: String
    var summary: String
    var updatedAt: Date?

    static func revision(of text: String) -> String {
        // Stable across processes; this is an identity checksum, never a security hash.
        let hash = text.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        return String(hash, radix: 16)
    }
}

struct ProactiveCollection: Sendable {
    var snapshots: [ProactiveSnapshot] = []
    var completeScopes: Set<String> = []
    var errors: [String: String] = [:]
}

struct ProactiveReport: Sendable, Equatable {
    var sourceID: String
    var outcome: ProactiveReportOutcome
    var reason: String
    var evidence: String
    var nextStep: String
}

struct ProactiveAnalysisBatch: Sendable {
    var sessionID: String
    var reports: [ProactiveReport]
}

private struct ProactiveCandidate: Codable, Sendable {
    var snapshot: ProactiveSnapshot
    var firstSeenAt: Date
    var evaluatedAt: Date?
    var evaluateAfter: Date?
    var choice: String?
    var confidence: Double?
    var policyRevision: String?
    var pendingAnalysis = false
    var fallback = false
    var analyzeAfter: Date?
}

private struct ProactiveAttempt: Codable, Sendable {
    var date: Date
    var fallback: Bool
}

private struct ProactiveAgentState: Codable, Sendable {
    var candidates: [String: ProactiveCandidate] = [:]
    var findings: [ProactiveFinding] = []
    var attempts: [ProactiveAttempt] = []
    var lastCollectedAt: Date?
    var needsRefresh = false
    var sourceErrors: [String: String] = [:]
    var lastAnalysisError: String?
}

/// The actor owns decisions, the durable queue and inbox. Model/network work is injected;
/// no model text is used as a control-flow signal.
actor ProactiveHeartbeatService {
    typealias Collector = @Sendable (String, AgentProactiveSettings) async -> ProactiveCollection
    typealias Chooser = @Sendable (String, String) async throws -> SemanticChoiceResponse
    typealias Analyzer = @Sendable (String, [ProactiveSnapshot], String) async throws -> ProactiveAnalysisBatch
    typealias Delivery = @Sendable (String, [ProactiveFinding]) async -> Void

    private var store: any PersistenceStore
    private var storeGeneration = 0
    private let collect: Collector
    private let choose: Chooser
    private let analyze: Analyzer
    private let deliver: Delivery
    private var states: [String: ProactiveAgentState] = [:]
    private var activeAgents: Set<String> = []

    init(store: any PersistenceStore, collect: @escaping Collector, choose: @escaping Chooser,
         analyze: @escaping Analyzer, deliver: @escaping Delivery) {
        self.store = store; self.collect = collect; self.choose = choose; self.analyze = analyze; self.deliver = deliver
    }

    func updateStore(_ store: any PersistenceStore) {
        self.store = store
        storeGeneration += 1
        states.removeAll()
    }

    func markDirty(agentID: String) async throws {
        try await load(agentID)
        states[agentID]?.needsRefresh = true
        try await persist(agentID)
    }

    func inbox(agentID: String) async throws -> ProactiveInbox {
        try await load(agentID)
        let state = states[agentID] ?? .init()
        return ProactiveInbox(
            findings: state.findings.sorted { $0.createdAt > $1.createdAt }, lastCheckedAt: state.lastCollectedAt,
            pendingAnalysisCount: state.candidates.values.filter { $0.pendingAnalysis }.count,
            sourceErrors: state.sourceErrors, lastAnalysisError: state.lastAnalysisError
        )
    }

    func act(agentID: String, findingID: String, action: ProactiveFindingActionRequest.Action, now: Date = Date()) async throws -> ProactiveFinding {
        try await load(agentID)
        guard let index = states[agentID]?.findings.firstIndex(where: { $0.id == findingID }) else {
            throw ProactiveHeartbeatError.findingNotFound
        }
        switch action {
        case .read: states[agentID]?.findings[index].readAt = now
        case .dismiss: states[agentID]?.findings[index].dismissedAt = now
        case .snooze:
            states[agentID]?.findings[index].snoozedUntil = now.addingTimeInterval(86_400)
            states[agentID]?.findings[index].deliveredAt = nil
        }
        try await persist(agentID)
        guard let finding = states[agentID]?.findings[index] else { throw ProactiveHeartbeatError.findingNotFound }
        return finding
    }

    func run(agentID: String, heartbeat: AgentHeartbeatSettings, instructions: String,
             minimumConfidence: Double, now suppliedNow: Date? = nil) async throws {
        let now = suppliedNow ?? Date()
        guard heartbeat.enabled, heartbeat.mode == .proactive, activeAgents.insert(agentID).inserted else { return }
        defer { activeAgents.remove(agentID) }
        let generation = storeGeneration
        try await load(agentID)
        guard generation == storeGeneration else { return }
        let settings = heartbeat.proactive
        guard settings.isValid, !settings.analysisModel.isEmpty else { throw ProactiveHeartbeatError.modelUnavailable }
        var removedSource = false
        for (id, candidate) in states[agentID]?.candidates ?? [:] where !sourceSelected(candidate.snapshot.source, settings: settings) {
            states[agentID]?.candidates.removeValue(forKey: id)
            resolveOlderFindings(agentID: agentID, sourceID: id, revision: nil, now: now)
            removedSource = true
        }
        if removedSource { try await persist(agentID) }
        let scopeRevision = ProactiveSnapshot.revision(of: settings.projectIds.sorted().joined(separator: "\n")
            + settings.reviewProviderIds.sorted().joined(separator: "\n"))
        let policyRevision = ProactiveSnapshot.revision(of: instructions + scopeRevision)
        let previous = states[agentID] ?? .init()
        let elapsed = now.timeIntervalSince(previous.lastCollectedAt ?? .distantPast)
        if elapsed >= Double(max(5, heartbeat.intervalMinutes) * 60) || (previous.needsRefresh && elapsed >= 300) {
            states[agentID]?.needsRefresh = false
            let collection = await collect(agentID, settings)
            guard generation == storeGeneration else { return }
            states[agentID]?.lastCollectedAt = now
            states[agentID]?.sourceErrors = collection.errors
            let seen = Set(collection.snapshots.map { $0.source.id })
            for snapshot in collection.snapshots {
                let old = states[agentID]?.candidates[snapshot.source.id]
                if old?.snapshot.revision != snapshot.revision {
                    states[agentID]?.candidates[snapshot.source.id] = ProactiveCandidate(snapshot: snapshot, firstSeenAt: now)
                    resolveOlderFindings(agentID: agentID, sourceID: snapshot.source.id, revision: snapshot.revision, now: now)
                } else {
                    states[agentID]?.candidates[snapshot.source.id]?.snapshot = snapshot
                }
            }
            for (id, candidate) in states[agentID]?.candidates ?? [:] {
                let selected = settings.projectIds.contains(candidate.snapshot.source.projectId ?? "")
                    || settings.reviewProviderIds.contains(candidate.snapshot.source.providerId ?? "")
                if !selected || (collection.completeScopes.contains(candidate.snapshot.scope) && !seen.contains(id)) {
                    states[agentID]?.candidates.removeValue(forKey: id)
                    resolveOlderFindings(agentID: agentID, sourceID: id, revision: nil, now: now)
                }
            }
            try await persist(agentID)
        }

        let due = (states[agentID]?.candidates.values ?? Dictionary<String, ProactiveCandidate>().values)
            .filter { !$0.pendingAnalysis && ($0.evaluatedAt == nil || $0.policyRevision != policyRevision || ($0.evaluateAfter ?? .distantFuture) <= now) }
            .sorted { $0.firstSeenAt < $1.firstSeenAt }
        for candidate in due.prefix(50) {
            guard !Task.isCancelled else { return }
            let id = candidate.snapshot.source.id
            var choice = "investigate"
            var confidence: Double?
            var fallback = false
            let priorFindings = (states[agentID]?.findings ?? []).filter { $0.source.id == id }.suffix(3)
            var compactSnapshot = candidate.snapshot
            compactSnapshot.summary = String(compactSnapshot.summary.prefix(3_000))
            compactSnapshot.source.title = String(compactSnapshot.source.title.prefix(256))
            let request = DecisionState(snapshot: compactSnapshot, instructions: String(instructions.prefix(4_000)),
                                        previousChoice: candidate.choice, previousFindings: priorFindings.map(PreviousFinding.init), now: now)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(request)
            do {
                let response = try await choose(agentID, String(decoding: data, as: UTF8.self))
                guard generation == storeGeneration else { return }
                confidence = response.confidence
                if response.confidence >= minimumConfidence && ["ignore", "defer", "investigate"].contains(response.choice) {
                    choice = response.choice
                } else { fallback = true }
            } catch { fallback = true }
            guard generation == storeGeneration else { return }
            states[agentID]?.candidates[id]?.choice = choice
            states[agentID]?.candidates[id]?.confidence = confidence
            states[agentID]?.candidates[id]?.policyRevision = policyRevision
            states[agentID]?.candidates[id]?.evaluatedAt = now
            states[agentID]?.candidates[id]?.evaluateAfter = now.addingTimeInterval(choice == "defer" ? 1_800 : 86_400)
            states[agentID]?.candidates[id]?.pendingAnalysis = choice == "investigate"
            states[agentID]?.candidates[id]?.fallback = fallback
            try await persist(agentID)
        }

        states[agentID]?.attempts.removeAll { now.timeIntervalSince($0.date) >= 3_600 }
        let attempts = states[agentID]?.attempts ?? []
        let canFallback = attempts.filter(\.fallback).count < 2
        let pending = (states[agentID]?.candidates.values ?? Dictionary<String, ProactiveCandidate>().values)
            .filter { $0.pendingAnalysis && ($0.analyzeAfter ?? .distantPast) <= now && (!$0.fallback || canFallback) }
            .sorted { $0.firstSeenAt < $1.firstSeenAt }
        if attempts.count < 4 && !pending.isEmpty && !Task.isCancelled {
            let batch = Array(pending.prefix(20))
            states[agentID]?.attempts.append(.init(date: now, fallback: batch.contains { $0.fallback }))
            // Reserve capacity durably before starting the expensive call.
            try await persist(agentID)
            do {
                let result = try await analyze(agentID, batch.map(\.snapshot), settings.analysisModel)
                guard generation == storeGeneration else { return }
                let reports = Dictionary(result.reports.map { ($0.sourceID, $0) }, uniquingKeysWith: { first, _ in first })
                guard reports.count == batch.count, batch.allSatisfy({ reports[$0.snapshot.source.id] != nil }) else {
                    throw ProactiveHeartbeatError.missingReport
                }
                guard reports.values.allSatisfy({ report in
                    report.outcome == .quiet || [report.reason, report.evidence, report.nextStep].allSatisfy {
                        !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }
                }) else { throw ProactiveHeartbeatError.invalidReport }
                for candidate in batch {
                    let id = candidate.snapshot.source.id
                    guard let report = reports[id], states[agentID]?.candidates[id]?.snapshot.revision == candidate.snapshot.revision else { continue }
                    states[agentID]?.candidates[id]?.pendingAnalysis = false
                    states[agentID]?.candidates[id]?.analyzeAfter = nil
                    if report.outcome == .quiet {
                        resolveOlderFindings(agentID: agentID, sourceID: id, revision: nil, now: now)
                        continue
                    }
                    let duplicate = states[agentID]?.findings.contains { $0.source.id == id && $0.revision == candidate.snapshot.revision } ?? false
                    if !duplicate {
                        states[agentID]?.findings.append(ProactiveFinding(
                            agentId: agentID, source: candidate.snapshot.source, revision: candidate.snapshot.revision,
                            outcome: report.outcome, reason: report.reason, evidence: report.evidence,
                            nextStep: report.nextStep, sessionId: result.sessionID, createdAt: now
                        ))
                    }
                }
                states[agentID]?.lastAnalysisError = nil
            } catch {
                guard generation == storeGeneration else { return }
                states[agentID]?.lastAnalysisError = String(describing: error)
                for candidate in batch {
                    states[agentID]?.candidates[candidate.snapshot.source.id]?.analyzeAfter = now.addingTimeInterval(1_800)
                }
            }
            try await persist(agentID)
        }
        guard generation == storeGeneration else { return }
        try await flushNotifications(agentID: agentID, settings: settings, now: suppliedNow ?? Date())
    }

    private func flushNotifications(agentID: String, settings: AgentProactiveSettings, now: Date) async throws {
        guard settings.permitsNotification(at: now) else { return }
        let due = (states[agentID]?.findings ?? []).filter {
            $0.deliveredAt == nil && $0.dismissedAt == nil && $0.resolvedAt == nil
                && sourceSelected($0.source, settings: settings)
                && ($0.snoozedUntil.map { $0 <= now } ?? true)
                && ($0.readAt == nil || $0.snoozedUntil != nil)
        }
        guard !due.isEmpty else { return }
        let ids = Set(due.map(\.id))
        for index in (states[agentID]?.findings ?? []).indices where ids.contains(states[agentID]?.findings[index].id ?? "") {
            states[agentID]?.findings[index].deliveredAt = now
            states[agentID]?.findings[index].snoozedUntil = nil
        }
        // Clients recover from a dropped live event by fetching this durable inbox.
        try await persist(agentID)
        await deliver(agentID, due)
    }

    private func sourceSelected(_ source: ProactiveSource, settings: AgentProactiveSettings) -> Bool {
        switch source.kind {
        case .task: return settings.projectIds.contains(source.projectId ?? "")
        case .pullRequest: return settings.reviewProviderIds.contains(source.providerId ?? "")
        }
    }

    private func resolveOlderFindings(agentID: String, sourceID: String, revision: String?, now: Date) {
        for index in (states[agentID]?.findings ?? []).indices {
            guard let finding = states[agentID]?.findings[index], finding.source.id == sourceID,
                  finding.revision != revision, finding.resolvedAt == nil else { continue }
            states[agentID]?.findings[index].resolvedAt = now
        }
    }

    private func load(_ agentID: String) async throws {
        guard states[agentID] == nil else { return }
        let generation = storeGeneration
        let data = try await store.loadProactiveState(agentId: agentID)
        guard generation == storeGeneration else { throw ProactiveHeartbeatError.configurationChanged }
        // Another actor invocation may have loaded and modified this state during the await.
        guard states[agentID] == nil else { return }
        states[agentID] = try data.map { try JSONDecoder().decode(ProactiveAgentState.self, from: $0) } ?? .init()
    }

    private func persist(_ agentID: String) async throws {
        guard let state = states[agentID] else { return }
        let data = try JSONEncoder().encode(state)
        try await store.saveProactiveState(agentId: agentID, data: data)
    }

    private struct DecisionState: Encodable {
        var snapshot: ProactiveSnapshot
        var instructions: String
        var previousChoice: String?
        var previousFindings: [PreviousFinding]
        var now: Date
    }

    private struct PreviousFinding: Encodable {
        var revision: String
        var outcome: ProactiveReportOutcome
        var reason: String
        var evidence: String
        var readAt: Date?
        var dismissedAt: Date?
        var snoozedUntil: Date?
        var resolvedAt: Date?
        init(_ finding: ProactiveFinding) {
            revision = finding.revision; outcome = finding.outcome
            reason = String(finding.reason.prefix(500)); evidence = String(finding.evidence.prefix(250))
            readAt = finding.readAt; dismissedAt = finding.dismissedAt; snoozedUntil = finding.snoozedUntil; resolvedAt = finding.resolvedAt
        }
    }
}
