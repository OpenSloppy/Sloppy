import Foundation
import Testing
import Protocols
@testable import sloppy
#if canImport(CSQLite3)
import CSQLite3

@Test func launchStorageFailureNeverLeavesDeadProcessReportedAsRunning() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("launch.sqlite").path
    let store = SQLiteStore(path: path, schemaSQL: "")
    let service = LaunchRunService(store: store, processes: SessionProcessRegistry())
    let configuration = LaunchConfiguration(id: "storage-failure", agentID: "agent", sessionID: "chat", hostName: "Test Mac",
        request: .init(name: "Web", target: "web", platform: .web, checkoutPath: root.path,
                       build: [.init(executable: "/bin/sh", arguments: ["-c", "touch started; sleep 0.5; echo build-finished"])],
                       launch: .init(executable: "/usr/bin/touch", arguments: ["should-not-launch"]), webPort: 49203), updatedAt: Date())
    _ = try await service.configure(configuration)
    _ = try await service.start(configuration: configuration, environment: [:], timeoutMs: 5_000, maxProcesses: 2)
    for _ in 0..<100 {
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("started").path) { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("started").path))
    var database: OpaquePointer?
    #expect(sqlite3_open(path, &database) == SQLITE_OK)
    defer { sqlite3_close(database) }
    #expect(sqlite3_exec(database, "DROP TABLE session_launch_state", nil, nil, nil) == SQLITE_OK)
    for _ in 0..<100 {
        if try await service.state(agentID: "agent", sessionID: "chat").runs.first?.status == .failed { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    let state = try await service.state(agentID: "agent", sessionID: "chat")
    #expect(state.runs.first?.status == .failed)
    #expect(state.runs.first?.error != nil)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("should-not-launch").path))
}
#endif
