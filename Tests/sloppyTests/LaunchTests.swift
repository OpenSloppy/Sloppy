import Foundation
import Testing
import Protocols
@testable import sloppy

private func launchFixture(root: URL, id: String = "target-a", build: [LaunchCommand] = [], launch: LaunchCommand? = nil, port: Int = 49171) -> LaunchConfiguration {
    LaunchConfiguration(id: id, agentID: "agent", sessionID: "chat", projectID: "project", hostName: "Test Mac",
                        request: .init(name: id, target: id, platform: .web, checkoutPath: root.path,
                                       build: build, launch: launch ?? .init(executable: "/bin/sleep", arguments: ["30"]), webPort: port), updatedAt: Date())
}

@Test func launchSelectionSurvivesRecommendationAndSQLiteReopen() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SQLiteStore(path: directory.appendingPathComponent("state.sqlite").path, schemaSQL: "")
    let service = LaunchRunService(store: store, processes: SessionProcessRegistry())
    let first = launchFixture(root: directory)
    _ = try await service.configure(first)
    _ = try await service.select(agentID: "agent", sessionID: "chat", request: .init(configurationID: first.id))
    let second = launchFixture(root: directory, id: "target-b")
    let state = try await service.configure(second)
    #expect(state.selectedConfiguration?.id == first.id)
    #expect(state.recommendedConfigurationID == second.id)
    let reopened = SQLiteStore(path: directory.appendingPathComponent("state.sqlite").path, schemaSQL: "")
    let recovered = LaunchRunService(store: reopened, processes: SessionProcessRegistry())
    let saved = try await recovered.state(agentID: "agent", sessionID: "chat")
    #expect(saved.configurations.count == 2)
    #expect(saved.selectedConfiguration?.id == first.id)
    #expect(try await recovered.retainsCheckout(directory.path))
    _ = try await recovered.remove(agentID: "agent", sessionID: "chat", configurationID: first.id)
    _ = try await recovered.remove(agentID: "agent", sessionID: "chat", configurationID: second.id)
    #expect(try await !recovered.retainsCheckout(directory.path))
}

@Test func launchFailedBuildPreventsStartAndCapturesLogs() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = InMemoryCorePersistenceBuilder().makeStore(config: .test)
    let service = LaunchRunService(store: store, processes: SessionProcessRegistry())
    let config = launchFixture(root: root,
                               build: [.init(executable: "/bin/sh", arguments: ["-c", "printf 'compile-error'; exit 7"])],
                               launch: .init(executable: "/usr/bin/touch", arguments: ["should-not-launch"]))
    _ = try await service.configure(config)
    let run = try await service.start(configuration: config, environment: [:], timeoutMs: 5_000, maxProcesses: 4)
    for _ in 0..<100 {
        let state = try await service.state(agentID: "agent", sessionID: "chat")
        if let current = state.runs.first, !current.status.isActive {
            #expect(current.status == .failed)
            #expect(current.logs.contains("compile-error"))
            #expect(!current.buildSucceeded)
            #expect(!current.launchSucceeded)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("should-not-launch").path))
            return
        }
        try await Task.sleep(for: .milliseconds(50))
    }
    _ = try await service.stop(agentID: "agent", sessionID: "chat", runID: run.id)
    Issue.record("Launch did not finish")
}

@Test func launchUsesDirtySubprojectAndRejectsDuplicateStart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let sub = root.appendingPathComponent("second-project")
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    try Data("uncommitted".utf8).write(to: sub.appendingPathComponent("input.txt"))
    defer { try? FileManager.default.removeItem(at: root) }
    let store = InMemoryCorePersistenceBuilder().makeStore(config: .test)
    let service = LaunchRunService(store: store, processes: SessionProcessRegistry())
    var config = launchFixture(root: root, build: [.init(executable: "/bin/sh", arguments: ["-c", "cat input.txt > built.txt; sleep 1"])])
    config.request.workingDirectory = "second-project"
    _ = try await service.configure(config)
    let run = try await service.start(configuration: config, environment: [:], timeoutMs: 5_000, maxProcesses: 4)
    await #expect(throws: LaunchRunService.Failure.self) {
        try await service.start(configuration: config, environment: [:], timeoutMs: 5_000, maxProcesses: 4)
    }
    for _ in 0..<100 {
        if FileManager.default.fileExists(atPath: sub.appendingPathComponent("built.txt").path) { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(try String(contentsOf: sub.appendingPathComponent("built.txt"), encoding: .utf8) == "uncommitted")
    let stopped = try await service.stop(agentID: "agent", sessionID: "chat", runID: run.id)
    #expect(stopped.runs.first?.status == .stopped)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("built.txt").path))
}

@Test func launchRecoveryMarksStaleRunAndScopesSessionHistory() async throws {
    let root = FileManager.default.temporaryDirectory
    let store = InMemoryCorePersistenceBuilder().makeStore(config: .test)
    var record = LaunchSessionState(agentID: "agent", sessionID: "chat")
    let configuration = launchFixture(root: root)
    record.configurations = [configuration]
    record.runs = [LaunchRun(id: "stale", configurationID: configuration.id, configuration: configuration,
                            status: .running, buildSucceeded: true, launchSucceeded: true, logs: "old run", startedAt: Date())]
    try await store.saveLaunchSession(record)
    let service = LaunchRunService(store: store, processes: SessionProcessRegistry())
    let recovered = try await service.state(agentID: "agent", sessionID: "chat")
    #expect(recovered.runs.first?.status == .failed)
    #expect(recovered.runs.first?.error?.contains("restarted") == true)
    #expect(try await service.state(agentID: "other", sessionID: "chat").runs.isEmpty)
    await #expect(throws: LaunchRunService.Failure.self) {
        try await service.stop(agentID: "other", sessionID: "chat", runID: "stale")
    }
}
