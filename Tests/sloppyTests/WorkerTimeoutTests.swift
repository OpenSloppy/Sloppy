@testable import AgentRuntime
import Foundation
import Protocols
import Testing
@testable import sloppy

@Suite("Worker timeout scope")
struct WorkerTimeoutTests {
    @Test func conversationWorkersIgnoreLegacyTimeoutEvents() async throws {
        let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
        let ids = await service.makeTimeoutTestWorkers(managed: true)
        await service.handleVisorEvent(EventEnvelope(
            messageType: .visorWorkerTimeout, channelId: "timeout-test",
            workerId: ids[0], payload: .object([
                "elapsed_seconds": .number(1_500), "timeout_seconds": .number(600)
            ])
        ))
        let snapshots = await service.timeoutTestSnapshots()
        #expect(snapshots.count == 2)
        #expect(snapshots.allSatisfy { $0.status == .running })
        await service.stopTimeoutTestWorkers()
    }

    @Test func autopilotWorkersIgnoreLegacyTimeoutEvents() async throws {
        let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
        let ids = await service.makeTimeoutTestWorkers(managed: false)
        await service.handleVisorEvent(EventEnvelope(
            messageType: .visorWorkerTimeout, channelId: "timeout-test",
            workerId: ids[0], payload: .object([
                "elapsed_seconds": .number(1_500), "timeout_seconds": .number(600)
            ])
        ))
        let snapshots = await service.timeoutTestSnapshots()
        #expect(snapshots.count == 2)
        #expect(snapshots.allSatisfy { $0.status == .running })
        // Explicit stop remains available and affects only its target.
        #expect(await service.cancelTimeoutTestWorker(ids[0]))
        let stopped = await service.timeoutTestSnapshots()
        #expect(stopped.first { $0.workerId == ids[0] }?.status == .failed)
        #expect(stopped.first { $0.workerId == ids[1] }?.status == .running)
        await service.stopTimeoutTestWorkers()
    }

    @Test func swarmWaitCompletesWhenTasksSettle() async throws {
        let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
        await service.setSwarmWaitTestStatus(.inProgress)
        let wait = Task { await service.waitForTasksToSettle(projectID: "swarm-wait", taskIDs: ["build"]) }
        try await Task.sleep(for: .milliseconds(100))
        await service.setSwarmWaitTestStatus(.done)
        #expect(await wait.value)
        await service.stopTimeoutTestWorkers()
    }

    @Test func swarmWaitRespondsToExplicitCancellation() async throws {
        let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
        await service.setSwarmWaitTestStatus(.inProgress)
        let wait = Task { await service.waitForTasksToSettle(projectID: "swarm-wait", taskIDs: ["build"]) }
        try await Task.sleep(for: .milliseconds(100))
        wait.cancel()
        #expect(await wait.value == false)
        await service.stopTimeoutTestWorkers()
    }

    @Test func timeoutWithWrongChannelDoesNotCancelWorker() async throws {
        let service = CoreService(config: .test, persistenceBuilder: InMemoryCorePersistenceBuilder())
        let ids = await service.makeTimeoutTestWorkers(managed: false)
        await service.handleVisorEvent(EventEnvelope(
            messageType: .visorWorkerTimeout, channelId: "different-channel",
            workerId: ids[0], payload: .object(["elapsed_seconds": .number(626)])
        ))
        #expect(await service.timeoutTestSnapshots().allSatisfy { $0.status == .running })
        await service.stopTimeoutTestWorkers()
    }
}

private extension CoreService {
    func setSwarmWaitTestStatus(_ status: ProjectTaskStatus) async {
        await store.saveProject(ProjectRecord(
            id: "swarm-wait", name: "Swarm build", description: "", channels: [], tasks: [
                ProjectTask(id: "build", title: "Clean build", description: "", priority: "medium", status: status.rawValue)
            ]
        ))
    }

    func makeTimeoutTestWorkers(managed: Bool) async -> [String] {
        var ids: [String] = []
        for index in 0..<2 {
            let id = await runtime.createWorker(spec: WorkerTaskSpec(
                taskId: "timeout-task-\(index)", channelId: "timeout-test", title: "Build",
                objective: "Build", tools: ["runtime.exec"], mode: .fireAndForget
            ), autoStart: false)
            ids.append(id)
            if managed {
                await runtime.reportManagedWorker(workerId: id)
            } else {
                // Restore an old running worker without racing Core's async executor setup.
                _ = await runtime.workers.updateRecoveredWorker(
                    workerId: id, status: .running, latestReport: nil, artifactId: nil,
                    observedAt: Date().addingTimeInterval(-1_500)
                )
            }
        }
        return ids
    }

    func stopTimeoutTestWorkers() async {
        for worker in await timeoutTestSnapshots() {
            _ = await runtime.cancelWorker(workerId: worker.workerId)
        }
        await stop()
    }

    func cancelTimeoutTestWorker(_ id: String) async -> Bool {
        await runtime.cancelWorker(workerId: id, reason: "User stopped execution")
    }

    func timeoutTestSnapshots() async -> [WorkerSnapshot] {
        await runtime.workerSnapshots().filter { $0.channelId == "timeout-test" }
    }
}
