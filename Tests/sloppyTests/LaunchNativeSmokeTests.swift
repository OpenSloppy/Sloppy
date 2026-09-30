import Foundation
import Testing
import Protocols
@testable import sloppy
#if os(macOS)
import CoreGraphics
import Darwin

@Suite("Play native smoke", .serialized)
struct LaunchNativeSmokeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SLOPPY_PLAY_MAC_CHECKOUT"] != nil))
    func launchMacApplicationThroughRunner() async throws {
        let root = try #require(ProcessInfo.processInfo.environment["SLOPPY_PLAY_MAC_CHECKOUT"])
        let app = try #require(ProcessInfo.processInfo.environment["SLOPPY_PLAY_MAC_APP"])
        let service = LaunchRunService(store: InMemoryCorePersistenceBuilder().makeStore(config: .test), processes: SessionProcessRegistry())
        let config = LaunchConfiguration(id: "mac-smoke", agentID: "smoke", sessionID: "mac", hostName: "Test Mac",
            request: .init(name: "Smoke", target: "macOS", platform: .macOS, checkoutPath: root, appPath: app), updatedAt: Date())
        _ = try await service.configure(config)
        let run = try await service.start(configuration: config, environment: [:], timeoutMs: 60_000, maxProcesses: 2)
        var launched: LaunchRun?
        for _ in 0..<200 {
            launched = try await service.state(agentID: "smoke", sessionID: "mac").runs.first
            if launched?.status == .running || launched?.status == .failed { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(launched?.error == nil)
        #expect(launched?.launchSucceeded == true)
        let pid = try #require(launched?.processID)
        var visibleWindow = false
        for _ in 0..<100 {
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            visibleWindow = windows.contains { ($0[kCGWindowOwnerPID as String] as? Int) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
            if visibleWindow { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(visibleWindow)
        let stopped = try await service.stop(agentID: "smoke", sessionID: "mac", runID: run.id)
        #expect(stopped.runs.first?.status == .stopped)
        for _ in 0..<100 {
            if kill(Int32(pid), 0) != 0 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(kill(Int32(pid), 0) != 0)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SLOPPY_PLAY_IOS_CHECKOUT"] != nil))
    func launchSimulatorApplicationThroughRunner() async throws {
        let root = try #require(ProcessInfo.processInfo.environment["SLOPPY_PLAY_IOS_CHECKOUT"])
        let app = try #require(ProcessInfo.processInfo.environment["SLOPPY_PLAY_IOS_APP"])
        let device = try #require(ProcessInfo.processInfo.environment["SLOPPY_PLAY_SIMULATOR"])
        let bundle = try #require(ProcessInfo.processInfo.environment["SLOPPY_PLAY_IOS_BUNDLE"])
        let service = LaunchRunService(store: InMemoryCorePersistenceBuilder().makeStore(config: .test), processes: SessionProcessRegistry())
        let config = LaunchConfiguration(id: "ios-smoke", agentID: "smoke", sessionID: "ios", hostName: "Test Mac",
            request: .init(name: "Smoke", target: "iOS", platform: .iOSSimulator, checkoutPath: root,
                           appPath: app, bundleID: bundle, simulatorID: device), updatedAt: Date())
        _ = try await service.configure(config)
        let run = try await service.start(configuration: config, environment: [:], timeoutMs: 120_000, maxProcesses: 2)
        var other = config
        other.id = "second-ios-profile"
        _ = try await service.configure(other)
        await #expect(throws: LaunchRunService.Failure.self) {
            try await service.start(configuration: other, environment: [:], timeoutMs: 120_000, maxProcesses: 2)
        }
        var launched: LaunchRun?
        for _ in 0..<600 {
            launched = try await service.state(agentID: "smoke", sessionID: "ios").runs.first
            if launched?.status == .running || launched?.status == .failed { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(launched?.error == nil)
        #expect(launched?.launchSucceeded == true)
        #expect(launched?.processID != nil)
        let stopped = try await service.stop(agentID: "smoke", sessionID: "ios", runID: run.id)
        #expect(stopped.runs.first?.status == .stopped)
    }
}
#endif
