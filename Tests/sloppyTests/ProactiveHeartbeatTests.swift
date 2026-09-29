import Foundation
import Testing
@testable import sloppy
import Protocols

private actor ProactiveFixture {
    var collection: ProactiveCollection
    var choice = "investigate"
    var confidence = 1.0
    var failsChoice = false
    var failsAnalysis = false
    var outcome = ProactiveReportOutcome.notify
    var choices = 0
    var analyses = 0
    var deliveries: [[ProactiveFinding]] = []
    var models: [String] = []

    init(collection: ProactiveCollection = .init(snapshots: [ProactiveFixture.snapshot()], completeScopes: ["project:p"])) {
        self.collection = collection
    }
    static func snapshot(revision: String = "v1", id: String = "task:p:t") -> ProactiveSnapshot {
        .init(source: .init(id: id, kind: .task, title: "Review needed", projectId: "p", taskId: "t"),
              scope: "project:p", revision: revision, summary: "needs_review", updatedAt: .distantPast)
    }
    func setChoice(_ value: String, confidence: Double = 1, fails: Bool = false) { choice = value; self.confidence = confidence; failsChoice = fails }
    func setCollection(_ value: ProactiveCollection) { collection = value }
    func setOutcome(_ value: ProactiveReportOutcome) { outcome = value }
    func setAnalysisFailure(_ value: Bool) { failsAnalysis = value }
    func collect() -> ProactiveCollection { collection }
    func choose() throws -> SemanticChoiceResponse {
        choices += 1
        if failsChoice { throw ProactiveHeartbeatError.modelUnavailable }
        return .init(choice: choice, confidence: confidence, probabilities: [:], usage: .init(inputTokens: 1, outputTokens: 1, costUSD: 0, costIsEstimated: false))
    }
    func analyze(_ snapshots: [ProactiveSnapshot], model: String) throws -> ProactiveAnalysisBatch {
        analyses += 1; models.append(model)
        if failsAnalysis { throw ProactiveHeartbeatError.invalidReport }
        return .init(sessionID: "session-\(analyses)", reports: snapshots.map {
            .init(sourceID: $0.source.id, outcome: outcome, reason: "Review required", evidence: "Task is needs_review", nextStep: "Open the task")
        })
    }
    func deliver(_ findings: [ProactiveFinding]) { deliveries.append(findings) }
}

private let proactiveNow = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15 11:00 Moscow
private let proactiveHeartbeat = AgentHeartbeatSettings(enabled: true, mode: .proactive,
    proactive: .init(projectIds: ["p"], analysisModel: "strong", notificationStartHour: 0, notificationEndHour: 24))

private func makeProactiveEngine(_ fixture: ProactiveFixture, store: any PersistenceStore = InMemoryPersistenceStore()) -> ProactiveHeartbeatService {
    .init(store: store, collect: { _, _ in await fixture.collect() }, choose: { _, _ in try await fixture.choose() },
          analyze: { _, sources, model in try await fixture.analyze(sources, model: model) },
          deliver: { _, findings in await fixture.deliver(findings) })
}

private func tick(_ engine: ProactiveHeartbeatService, now: Date = proactiveNow, settings: AgentHeartbeatSettings = proactiveHeartbeat) async throws {
    try await engine.run(agentID: "a", heartbeat: settings, instructions: "Check tasks", minimumConfidence: 0.75, now: now)
}

@Suite("Proactive heartbeat")
struct ProactiveHeartbeatTests {
    @Test func legacySettingsAndNewDefaults() throws {
        let old = try JSONDecoder().decode(AgentHeartbeatSettings.self, from: Data("{\"enabled\":true,\"intervalMinutes\":5}".utf8))
        #expect(old.mode == .checklist)
        #expect(AgentHeartbeatSettings(mode: .proactive).intervalMinutes == 30)
        #expect(AgentProactiveSettings().timeZone == "Europe/Moscow")
    }

    @Test func ignoreDoesNotCallStrongModelAndUnchangedStateIsSkipped() async throws {
        let fixture = ProactiveFixture(); await fixture.setChoice("ignore")
        let engine = makeProactiveEngine(fixture)
        try await tick(engine)
        try await tick(engine, now: proactiveNow.addingTimeInterval(1_800))
        #expect(await fixture.choices == 1)
        #expect(await fixture.analyses == 0)
        #expect(try await engine.inbox(agentID: "a").findings.isEmpty)
    }

    @Test(arguments: [false, true]) func lowConfidenceOrFailureEscalates(fails: Bool) async throws {
        let fixture = ProactiveFixture(); await fixture.setChoice("ignore", confidence: 0.2, fails: fails)
        let engine = makeProactiveEngine(fixture)
        try await tick(engine)
        #expect(await fixture.analyses == 1)
        #expect(await fixture.models == ["strong"])
        #expect(try await engine.inbox(agentID: "a").findings.count == 1)
    }

    @Test func deferIsReevaluatedAfterThirtyMinutes() async throws {
        let fixture = ProactiveFixture(); await fixture.setChoice("defer")
        let engine = makeProactiveEngine(fixture)
        try await tick(engine)
        try await tick(engine, now: proactiveNow.addingTimeInterval(60))
        #expect(await fixture.choices == 1)
        try await tick(engine, now: proactiveNow.addingTimeInterval(1_800))
        #expect(await fixture.choices == 2)
    }

    @Test func findingsAreDedupedButMeaningfulChangesCreateNewRevision() async throws {
        let fixture = ProactiveFixture()
        let actual = makeProactiveEngine(fixture)
        try await tick(actual)
        try await tick(actual, now: proactiveNow.addingTimeInterval(1_800))
        #expect(await fixture.deliveries.count == 1)
        let finding = try #require(try await actual.inbox(agentID: "a").findings.first)
        _ = try await actual.act(agentID: "a", findingID: finding.id, action: .dismiss, now: proactiveNow)
        await fixture.setCollection(.init(snapshots: [ProactiveFixture.snapshot(revision: "v2")], completeScopes: ["project:p"]))
        try await tick(actual, now: proactiveNow.addingTimeInterval(3_600))
        let inbox = try await actual.inbox(agentID: "a")
        #expect(inbox.findings.count == 2)
        #expect(inbox.findings.first?.revision == "v2")
        #expect(inbox.findings.last?.resolvedAt != nil)
    }

    @Test func quietHoursAccumulateAndMorningDeliversOneBatchWithoutNewAnalysis() async throws {
        let fixture = ProactiveFixture(collection: .init(snapshots: [ProactiveFixture.snapshot(), ProactiveFixture.snapshot(id: "task:p:u")], completeScopes: ["project:p"]))
        let engine = makeProactiveEngine(fixture)
        let night = try #require(ISO8601DateFormatter().date(from: "2026-09-29T05:59:00Z"))
        var settings = proactiveHeartbeat; settings.proactive.notificationStartHour = 9; settings.proactive.notificationEndHour = 21
        try await tick(engine, now: night, settings: settings)
        #expect(await fixture.deliveries.isEmpty)
        try await tick(engine, now: night.addingTimeInterval(60), settings: settings)
        #expect(await fixture.analyses == 1)
        #expect(await fixture.deliveries.count == 1)
        #expect(await fixture.deliveries.first?.count == 2)
        #expect(!settings.proactive.permitsNotification(at: try #require(ISO8601DateFormatter().date(from: "2026-09-29T18:00:00Z"))))
    }

    @Test func sourceFailureDoesNotResolveExistingFindings() async throws {
        let fixture = ProactiveFixture()
        let actual = makeProactiveEngine(fixture)
        try await tick(actual)
        await fixture.setCollection(.init(errors: ["project:p": "Unavailable"]))
        try await tick(actual, now: proactiveNow.addingTimeInterval(1_800))
        let inbox = try await actual.inbox(agentID: "a")
        #expect(inbox.findings.first?.resolvedAt == nil)
        #expect(inbox.sourceErrors["project:p"] == "Unavailable")
    }

    @Test func snoozeAndReadSurviveRestartWithoutRepeatedLiveNotifications() async throws {
        let store = InMemoryPersistenceStore(), fixture = ProactiveFixture()
        let engine = makeProactiveEngine(fixture, store: store)
        try await tick(engine)
        let id = try #require(try await engine.inbox(agentID: "a").findings.first?.id)
        _ = try await engine.act(agentID: "a", findingID: id, action: .read, now: proactiveNow)
        _ = try await engine.act(agentID: "a", findingID: id, action: .snooze, now: proactiveNow)
        let reopened = makeProactiveEngine(fixture, store: store)
        #expect(try await reopened.inbox(agentID: "a").findings.first?.readAt != nil)
        try await tick(reopened, now: proactiveNow.addingTimeInterval(1_800))
        #expect(await fixture.deliveries.count == 1)
        try await tick(reopened, now: proactiveNow.addingTimeInterval(86_400))
        #expect(await fixture.deliveries.count == 2)
    }

    @Test func fallbackCapPreservesQueueAcrossRestart() async throws {
        let fixture = ProactiveFixture(); await fixture.setChoice("investigate", fails: true)
        let store = InMemoryPersistenceStore()
        var engine = makeProactiveEngine(fixture, store: store)
        for index in 0..<3 {
            let now = proactiveNow.addingTimeInterval(Double(index * 300))
            await fixture.setCollection(.init(snapshots: [ProactiveFixture.snapshot(revision: "v\(index)")], completeScopes: ["project:p"]))
            try await engine.markDirty(agentID: "a")
            try await tick(engine, now: now)
            engine = makeProactiveEngine(fixture, store: store)
        }
        #expect(await fixture.analyses == 2)
        #expect(try await engine.inbox(agentID: "a").pendingAnalysisCount == 1)
        try await tick(engine, now: proactiveNow.addingTimeInterval(3_601))
        #expect(await fixture.analyses == 3)
    }

    @Test func failedAnalysisRetainsQueueAndErrorSeparately() async throws {
        let fixture = ProactiveFixture(); await fixture.setAnalysisFailure(true)
        let engine = makeProactiveEngine(fixture)
        try await tick(engine)
        let inbox = try await engine.inbox(agentID: "a")
        #expect(inbox.findings.isEmpty)
        #expect(inbox.pendingAnalysisCount == 1)
        #expect(inbox.lastAnalysisError != nil)
        await fixture.setAnalysisFailure(false)
        try await tick(engine, now: proactiveNow.addingTimeInterval(1_800))
        #expect(try await engine.inbox(agentID: "a").lastAnalysisError == nil)
    }

    @Test func normalAnalysisCapAndTaskEventSpacingPreservePendingWork() async throws {
        let fixture = ProactiveFixture()
        let actual = makeProactiveEngine(fixture)
        try await tick(actual)
        try await actual.markDirty(agentID: "a")
        try await tick(actual, now: proactiveNow.addingTimeInterval(299))
        #expect(await fixture.choices == 1)
        for index in 1...4 {
            await fixture.setCollection(.init(snapshots: [ProactiveFixture.snapshot(revision: "v\(index + 1)")], completeScopes: ["project:p"]))
            try await actual.markDirty(agentID: "a")
            try await tick(actual, now: proactiveNow.addingTimeInterval(Double(index * 300)))
        }
        #expect(await fixture.analyses == 4)
        #expect(try await actual.inbox(agentID: "a").pendingAnalysisCount == 1)
        try await tick(actual, now: proactiveNow.addingTimeInterval(3_601))
        #expect(await fixture.analyses == 5)
    }

    @Test func removingScopeStopsQueuedAnalysisBeforeTheNextCollection() async throws {
        let fixture = ProactiveFixture(); await fixture.setAnalysisFailure(true)
        let engine = makeProactiveEngine(fixture)
        try await tick(engine)
        #expect(try await engine.inbox(agentID: "a").pendingAnalysisCount == 1)
        var changed = proactiveHeartbeat; changed.proactive.projectIds = ["another-project"]
        await fixture.setAnalysisFailure(false)
        try await tick(engine, now: proactiveNow.addingTimeInterval(60), settings: changed)
        #expect(await fixture.analyses == 1)
        #expect(try await engine.inbox(agentID: "a").pendingAnalysisCount == 0)
    }

    @Test func reportRejectsMutationUnknownSourcesAndFreeTextOutcomes() async throws {
        let recorder = ProactiveReportRecorder(sourceIDs: ["task:p:t"])
        let mutation = await recorder.invoke(.init(tool: "project.task_update", arguments: [:]))
        #expect(!mutation.ok)
        #expect(mutation.error?.code == "proactive_tool_forbidden")
        let bad = await recorder.invoke(.init(tool: "heartbeat.report", arguments: ["sourceId": .string("unknown"), "outcome": .string("quiet")]))
        #expect(!bad.ok)
        #expect(throws: ProactiveHeartbeatError.self) { try HeartbeatReportTool.decode(["sourceId": .string("task:p:t"), "outcome": .string("I'll inspect")]) }
        let good = await recorder.invoke(.init(tool: "heartbeat.report", arguments: ["sourceId": .string("task:p:t"), "outcome": .string("quiet")]))
        #expect(good.ok)
        #expect(try await recorder.result().first?.outcome == .quiet)
    }

    @Test func sqliteReopeningRestoresDurableQueueAndFindings() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("proactive-\(UUID().uuidString).sqlite").path
        let fixture = ProactiveFixture()
        let store = SQLiteStore(path: path, schemaSQL: "")
        let engine = makeProactiveEngine(fixture, store: store)
        try await tick(engine)
        let reopened = SQLiteStore(path: path, schemaSQL: "")
        let inbox = try await makeProactiveEngine(fixture, store: reopened).inbox(agentID: "a")
        #expect(inbox.findings.count == 1)
        #expect(inbox.findings.first?.sessionId == "session-1")
    }
}
