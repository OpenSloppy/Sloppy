import Foundation
import Testing
@testable import AgentRuntime
@testable import Protocols

// MARK: - Helpers

private func makeWorkerSnapshot(
    workerId: String = UUID().uuidString,
    channelId: String = "ch1",
    taskId: String = "t1",
    status: WorkerStatus = .running,
    startedAt: Date? = Date()
) -> WorkerSnapshot {
    WorkerSnapshot(
        workerId: workerId,
        channelId: channelId,
        taskId: taskId,
        status: status,
        mode: .interactive,
        tools: [],
        latestReport: nil,
        startedAt: startedAt  // placed last per WorkerSnapshot.init signature
    )
}

private func makeWorkerSnapshotWith(
    workerId: String = UUID().uuidString,
    status: WorkerStatus,
    startedAt: Date?
) -> WorkerSnapshot {
    WorkerSnapshot(
        workerId: workerId,
        channelId: "ch1",
        taskId: "t1",
        status: status,
        mode: .interactive,
        tools: [],
        latestReport: nil,
        startedAt: startedAt
    )
}

private func makeBranchSnapshot(
    branchId: String = UUID().uuidString,
    channelId: String = "ch1",
    createdAt: Date = Date()
) -> BranchSnapshot {
    BranchSnapshot(
        branchId: branchId,
        channelId: channelId,
        prompt: "test prompt",
        workerId: nil,
        createdAt: createdAt
    )
}

private actor EventCollector {
    var events: [EventEnvelope] = []
    func record(_ event: EventEnvelope) { events.append(event) }
    func all() -> [EventEnvelope] { events }
    func ofType(_ type: MessageType) -> [EventEnvelope] { events.filter { $0.messageType == type } }
}

// MARK: - Long-running workers

@Test func visorDoesNotTimeoutWorkersRegardlessOfAge() async throws {
    let bus = EventBus()
    let visor = Visor(eventBus: bus, memoryStore: InMemoryMemoryStore())
    let oldDate = Date().addingTimeInterval(-24 * 60 * 60)
    let workers = [
        makeWorkerSnapshotWith(workerId: "autopilot-build", status: .running, startedAt: oldDate),
        makeWorkerSnapshotWith(workerId: "conversation-build", status: .running, startedAt: oldDate),
        makeWorkerSnapshotWith(workerId: "approval", status: .waitingInput, startedAt: oldDate),
    ]
    let stream = await bus.subscribe()
    let collector = EventCollector()
    let collectTask = Task {
        for await event in stream { await collector.record(event) }
    }
    await visor.startSupervision(
        tickInterval: .milliseconds(10), workerTimeoutSeconds: 1,
        branchTimeoutSeconds: 60, maintenanceIntervalSeconds: 3_600,
        decayRatePerDay: 0.05, pruneImportanceThreshold: 0.1, pruneMinAgeDays: 30,
        snapshotProvider: { ([], workers) }, branchProvider: { [] }, branchForceTimeout: { _ in }
    )
    try await Task.sleep(for: .milliseconds(100))
    #expect(await visor.isReady)
    await visor.stopSupervision()
    collectTask.cancel()
    #expect(await collector.ofType(.visorWorkerTimeout).isEmpty)
}

// MARK: - Branch timeout

private actor TimeoutTracker {
    var ids: [String] = []
    func record(_ id: String) { ids.append(id) }
    func all() -> [String] { ids }
}

@Test func visorDetectsAndTimeoutsStaleBranch() async {
    let bus = EventBus()
    let memory = InMemoryMemoryStore()
    let visor = Visor(eventBus: bus, memoryStore: memory)

    let staleBranch = makeBranchSnapshot(branchId: "b1", createdAt: Date().addingTimeInterval(-120))
    let freshBranch = makeBranchSnapshot(branchId: "b2", createdAt: Date())

    let tracker = TimeoutTracker()
    await visor.checkBranchHealth(
        branches: [staleBranch, freshBranch],
        branchTimeoutSeconds: 60,
        forceTimeout: { @Sendable id in await tracker.record(id) }
    )

    let timedOutIds = await tracker.all()
    #expect(timedOutIds == ["b1"])
}

// MARK: - Memory decay and prune

@Test func visorDecaysOldMemories() async {
    let bus = EventBus()
    let memory = InMemoryMemoryStore()
    let visor = Visor(eventBus: bus, memoryStore: memory)

    let oldDate = Date().addingTimeInterval(-2 * 86_400)
    let ref = await memory.save(
        entry: MemoryWriteRequest(
            note: "some decision",
            kind: .decision,
            importance: 0.8,
            updatedAt: oldDate
        )
    )

    await visor.runMemoryMaintenance(
        decayRatePerDay: 0.05,
        pruneImportanceThreshold: 0.1,
        pruneMinAgeDays: 30
    )

    let entries = await memory.entries(filter: .default)
    let updated = entries.first(where: { $0.id == ref.id })
    #expect(updated != nil)
    #expect((updated?.importance ?? 1.0) < 0.8)
}

@Test func visorPrunesLowImportanceOldMemories() async {
    let bus = EventBus()
    let memory = InMemoryMemoryStore()
    let visor = Visor(eventBus: bus, memoryStore: memory)

    let veryOldDate = Date().addingTimeInterval(-40 * 86_400)
    let ref = await memory.save(
        entry: MemoryWriteRequest(
            note: "stale fact",
            kind: .fact,
            importance: 0.05,
            updatedAt: veryOldDate
        )
    )

    await visor.runMemoryMaintenance(
        decayRatePerDay: 0.5,
        pruneImportanceThreshold: 0.1,
        pruneMinAgeDays: 30
    )

    let filter = MemoryEntryFilter(includeDeleted: true)
    let entries = await memory.entries(filter: filter)
    let entry = entries.first(where: { $0.id == ref.id })
    #expect(entry?.deletedAt != nil)
}

@Test func visorSkipsIdentityMemoriesInMaintenance() async {
    let bus = EventBus()
    let memory = InMemoryMemoryStore()
    let visor = Visor(eventBus: bus, memoryStore: memory)

    let oldDate = Date().addingTimeInterval(-50 * 86_400)
    let ref = await memory.save(
        entry: MemoryWriteRequest(
            note: "identity note",
            kind: .identity,
            importance: 0.8,
            updatedAt: oldDate
        )
    )

    await visor.runMemoryMaintenance(
        decayRatePerDay: 0.5,
        pruneImportanceThreshold: 0.1,
        pruneMinAgeDays: 30
    )

    let entries = await memory.entries(filter: .default)
    let entry = entries.first(where: { $0.id == ref.id })
    #expect(entry?.importance == 0.8)
    #expect(entry?.deletedAt == nil)
}

@Test func visorEmitsMaintenanceEventAfterRun() async {
    let bus = EventBus()
    let memory = InMemoryMemoryStore()
    let visor = Visor(eventBus: bus, memoryStore: memory)

    let stream = await bus.subscribe()
    let collector = EventCollector()
    let collectTask = Task {
        for await event in stream {
            await collector.record(event)
        }
    }

    await visor.runMemoryMaintenance(decayRatePerDay: 0.05, pruneImportanceThreshold: 0.1, pruneMinAgeDays: 30)
    try? await Task.sleep(for: .milliseconds(50))
    collectTask.cancel()

    let maintenanceEvents = await collector.ofType(.visorMemoryMaintained)
    #expect(maintenanceEvents.count == 1)
}

// MARK: - InMemoryMemoryStore updateImportance / softDelete

@Test func inMemoryStoreUpdateImportanceWorks() async {
    let store = InMemoryMemoryStore()
    let ref = await store.save(entry: MemoryWriteRequest(note: "test", importance: 0.8))

    let ok = await store.updateImportance(id: ref.id, importance: 0.3)
    #expect(ok == true)

    let entries = await store.entries(filter: .default)
    let entry = entries.first(where: { $0.id == ref.id })
    #expect(entry?.importance == 0.3)
}

@Test func inMemoryStoreSoftDeleteWorks() async {
    let store = InMemoryMemoryStore()
    let ref = await store.save(entry: MemoryWriteRequest(note: "test"))

    let ok = await store.softDelete(id: ref.id)
    #expect(ok == true)

    let visible = await store.entries(filter: .default)
    #expect(visible.first(where: { $0.id == ref.id }) == nil)

    let all = await store.entries(filter: MemoryEntryFilter(includeDeleted: true))
    let entry = all.first(where: { $0.id == ref.id })
    #expect(entry?.deletedAt != nil)
}

@Test func inMemoryStoreUpdateEntryWorks() async {
    let store = InMemoryMemoryStore()
    let ref = await store.save(entry: MemoryWriteRequest(note: "original note", importance: 0.5, confidence: 0.7))

    let updated = await store.updateEntry(id: ref.id, note: "updated note", summary: nil, kind: .goal, importance: 0.9, confidence: nil)
    #expect(updated != nil)
    #expect(updated?.note == "updated note")
    #expect(updated?.kind == .goal)
    #expect(updated?.importance == 0.9)
    #expect(updated?.confidence == 0.7)

    let entries = await store.entries(filter: .default)
    let entry = entries.first(where: { $0.id == ref.id })
    #expect(entry?.note == "updated note")
    #expect(entry?.kind == .goal)
}

@Test func inMemoryStoreUpdateEntryReturnsNilForDeletedEntry() async {
    let store = InMemoryMemoryStore()
    let ref = await store.save(entry: MemoryWriteRequest(note: "to be deleted"))

    _ = await store.softDelete(id: ref.id)
    let updated = await store.updateEntry(id: ref.id, note: "should fail", summary: nil, kind: nil, importance: nil, confidence: nil)
    #expect(updated == nil)
}

@Test func inMemoryStoreUpdateEntryReturnsNilForMissingId() async {
    let store = InMemoryMemoryStore()
    let updated = await store.updateEntry(id: "nonexistent", note: "nope", summary: nil, kind: nil, importance: nil, confidence: nil)
    #expect(updated == nil)
}

// MARK: - Memory merge

@Test func visorMergesSimilarMemories() async {
    let bus = EventBus()
    let memory = InMemoryMemoryStore()
    let visor = Visor(
        eventBus: bus,
        memoryStore: memory,
        completionProvider: { prompt, _ in "merged content" }
    )

    let oldDate = Date().addingTimeInterval(-2 * 86_400)
    let refA = await memory.save(entry: MemoryWriteRequest(
        note: "user likes coffee", kind: .fact, importance: 0.7, updatedAt: oldDate
    ))
    let refB = await memory.save(entry: MemoryWriteRequest(
        note: "user likes coffee very much", kind: .fact, importance: 0.6, updatedAt: oldDate
    ))

    await visor.runMemoryMerge(similarityThreshold: 0.0, maxPerRun: 10)

    let filter = MemoryEntryFilter(includeDeleted: true)
    let all = await memory.entries(filter: filter)

    let deletedIDs = all.filter { $0.deletedAt != nil }.map(\.id)
    #expect(deletedIDs.contains(refA.id) || deletedIDs.contains(refB.id))

    let mergedEntry = all.first { $0.source?.type == "visor.merge" }
    #expect(mergedEntry != nil)
    #expect(mergedEntry?.note == "merged content")
}

@Test func visorSkipsMergeBelowThreshold() async {
    let bus = EventBus()
    let memory = InMemoryMemoryStore()
    let visor = Visor(eventBus: bus, memoryStore: memory)

    let oldDate = Date().addingTimeInterval(-2 * 86_400)
    let refA = await memory.save(entry: MemoryWriteRequest(
        note: "cats are fluffy animals", kind: .fact, updatedAt: oldDate
    ))
    let refB = await memory.save(entry: MemoryWriteRequest(
        note: "quantum physics is complex", kind: .fact, updatedAt: oldDate
    ))

    // Threshold 1.0 means only identical memories would merge — nothing should happen
    await visor.runMemoryMerge(similarityThreshold: 1.0, maxPerRun: 10)

    let visible = await memory.entries(filter: .default)
    #expect(visible.first(where: { $0.id == refA.id }) != nil)
    #expect(visible.first(where: { $0.id == refB.id }) != nil)
}

@Test func visorSkipsIdentityInMerge() async {
    let bus = EventBus()
    let memory = InMemoryMemoryStore()
    let visor = Visor(
        eventBus: bus,
        memoryStore: memory,
        completionProvider: { _, _ in "merged" }
    )

    let oldDate = Date().addingTimeInterval(-2 * 86_400)
    let identityRef = await memory.save(entry: MemoryWriteRequest(
        note: "user name is Alice", kind: .identity, importance: 0.9, updatedAt: oldDate
    ))
    _ = await memory.save(entry: MemoryWriteRequest(
        note: "user name is Alice too", kind: .fact, importance: 0.8, updatedAt: oldDate
    ))

    await visor.runMemoryMerge(similarityThreshold: 0.0, maxPerRun: 10)

    let filter = MemoryEntryFilter(includeDeleted: true)
    let all = await memory.entries(filter: filter)
    let identity = all.first(where: { $0.id == identityRef.id })
    #expect(identity?.deletedAt == nil)
}

@Test func visorMergeFallbackWithoutLLM() async {
    let bus = EventBus()
    let memory = InMemoryMemoryStore()
    let visor = Visor(eventBus: bus, memoryStore: memory)

    let oldDate = Date().addingTimeInterval(-2 * 86_400)
    _ = await memory.save(entry: MemoryWriteRequest(
        note: "alpha fact", kind: .fact, importance: 0.7, updatedAt: oldDate
    ))
    _ = await memory.save(entry: MemoryWriteRequest(
        note: "alpha fact extended", kind: .fact, importance: 0.6, updatedAt: oldDate
    ))

    await visor.runMemoryMerge(similarityThreshold: 0.0, maxPerRun: 10)

    let filter = MemoryEntryFilter(includeDeleted: false)
    let visible = await memory.entries(filter: filter)
    let merged = visible.first { $0.source?.type == "visor.merge" }
    #expect(merged != nil)
    #expect(merged?.note.contains("|") == true)
}

@Test func visorEmitsMergeEvent() async {
    let bus = EventBus()
    let memory = InMemoryMemoryStore()
    let visor = Visor(eventBus: bus, memoryStore: memory)

    let stream = await bus.subscribe()
    let collector = EventCollector()
    let collectTask = Task {
        for await event in stream {
            await collector.record(event)
        }
    }

    let oldDate = Date().addingTimeInterval(-2 * 86_400)
    _ = await memory.save(entry: MemoryWriteRequest(note: "beta one", kind: .fact, updatedAt: oldDate))
    _ = await memory.save(entry: MemoryWriteRequest(note: "beta two", kind: .fact, updatedAt: oldDate))

    await visor.runMemoryMerge(similarityThreshold: 0.0, maxPerRun: 10)
    try? await Task.sleep(for: .milliseconds(50))
    collectTask.cancel()

    let mergeEvents = await collector.ofType(.visorMemoryMerged)
    #expect(mergeEvents.count == 1)
}

@Test func visorMergeRespectsMaxPerRun() async {
    let bus = EventBus()
    let memory = InMemoryMemoryStore()
    let visor = Visor(
        eventBus: bus,
        memoryStore: memory,
        completionProvider: { _, _ in "merged" }
    )

    let oldDate = Date().addingTimeInterval(-2 * 86_400)
    for i in 1...6 {
        _ = await memory.save(entry: MemoryWriteRequest(
            note: "same topic about things \(i)", kind: .fact, importance: 0.5, updatedAt: oldDate
        ))
    }

    await visor.runMemoryMerge(similarityThreshold: 0.0, maxPerRun: 2)

    let filter = MemoryEntryFilter(includeDeleted: true)
    let all = await memory.entries(filter: filter)
    let deleted = all.filter { $0.deletedAt != nil }
    // maxPerRun: 2 means at most 2 merges, consuming at most 4 originals
    #expect(deleted.count <= 4)
}

// MARK: - latestBulletinDigest

@Test func visorLatestBulletinDigestNilBeforeGeneration() async {
    let bus = EventBus()
    let memory = InMemoryMemoryStore()
    let visor = Visor(eventBus: bus, memoryStore: memory)

    let digest = await visor.latestBulletinDigest()
    #expect(digest == nil)
}

@Test func visorLatestBulletinDigestAvailableAfterGeneration() async {
    let bus = EventBus()
    let memory = InMemoryMemoryStore()
    let visor = Visor(eventBus: bus, memoryStore: memory)

    let channel = ChannelSnapshot(channelId: "ch1", messages: [], contextUtilization: 0, activeWorkerIds: [], lastDecision: nil)
    _ = await visor.generateBulletin(channels: [channel], workers: [])

    let digest = await visor.latestBulletinDigest()
    #expect(digest != nil)
    #expect(digest?.isEmpty == false)
}
