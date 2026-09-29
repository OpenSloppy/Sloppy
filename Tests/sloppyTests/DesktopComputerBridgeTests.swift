import Foundation
import Protocols
import Testing
@testable import sloppy

@Suite("Desktop computer bridge")
struct DesktopComputerBridgeTests {
    private func binding(session: String = "session", device: String = UUID().uuidString) -> DesktopComputerBinding {
        .init(connectionId: UUID().uuidString, deviceId: device, agentId: "agent", sessionId: session)
    }

    private func next(_ bridge: DesktopComputerBridgeService, _ binding: DesktopComputerBinding) async throws -> DesktopComputerCommand {
        for _ in 0..<100 {
            if let command = try await bridge.poll(binding).commands.first { return command }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw DesktopComputerBridgeError.timedOut
    }


    @Test func delegatedSessionsDoNotFallBackToCoreComputer() async throws {
        let bridge = DesktopComputerBridgeService()
        let parent = binding(session: "parent")
        try await bridge.register(parent)
        try await bridge.inheritAssignment(parentSessionID: "parent", agentID: "delegate", sessionID: "child")
        try await bridge.inheritAssignment(parentSessionID: "child", agentID: "delegate", sessionID: "grandchild")
        #expect(await bridge.isAssigned(agentID: "delegate", sessionID: "grandchild"))
        await #expect(throws: DesktopComputerBridgeError.unavailable) {
            try await bridge.run(agentID: "delegate", sessionID: "grandchild", name: "computer.click", input: .object([:]))
        }
        try await bridge.inheritAssignment(parentSessionID: "ordinary", agentID: "delegate", sessionID: "unrelated")
        #expect(await bridge.isAssigned(agentID: "delegate", sessionID: "unrelated") == false)
    }

    @Test func commandsAndResultsStayOnOriginalConnection() async throws {
        let bridge = DesktopComputerBridgeService()
        let first = binding(session: "first"), second = binding(session: "second")
        try await bridge.register(first)
        try await bridge.register(second)
        let task = Task {
            try await bridge.run(agentID: first.agentId, sessionID: first.sessionId, name: "computer.click",
                                 input: .object(["x": .number(-1400), "y": .number(400)]))
        }
        let command = try await next(bridge, first)
        #expect(command.name == "computer.click")
        #expect(command.input.asObject?["x"]?.asNumber == -1400)
        #expect(try await bridge.poll(second).commands.isEmpty)
        await #expect(throws: DesktopComputerBridgeError.unknownCommand) {
            try await bridge.complete(.init(binding: second, commandId: command.id, data: .object([:]), imageBase64: nil, error: nil))
        }
        try await bridge.complete(.init(binding: first, commandId: command.id, data: .object(["ok": .bool(true)]), imageBase64: nil, error: nil))
        #expect(try await task.value.asObject?["deviceId"]?.asString == first.deviceId)
        await #expect(throws: DesktopComputerBridgeError.unknownCommand) {
            try await bridge.complete(.init(binding: first, commandId: command.id, data: nil, imageBase64: nil, error: nil))
        }
    }

    @Test func disconnectFailsPendingAndNeverFallsBackToCore() async throws {
        let bridge = DesktopComputerBridgeService()
        let owner = binding()
        try await bridge.register(owner)
        let task = Task { try await bridge.run(agentID: owner.agentId, sessionID: owner.sessionId, name: "computer.type", input: .object([:])) }
        _ = try await next(bridge, owner)
        await bridge.disconnect(owner)
        await #expect(throws: DesktopComputerBridgeError.unavailable) { try await task.value }
        #expect(await bridge.isAssigned(agentID: owner.agentId, sessionID: owner.sessionId))
        await #expect(throws: DesktopComputerBridgeError.unavailable) {
            try await bridge.run(agentID: owner.agentId, sessionID: owner.sessionId, name: "computer.click", input: .object([:]))
        }
    }

    @Test func deviceAssignmentSurvivesRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("assignments.json")
        let owner = binding()
        let original = DesktopComputerBridgeService(assignmentsURL: file)
        try await original.register(owner)
        await original.shutdown()
        let restored = DesktopComputerBridgeService(assignmentsURL: file)
        #expect(await restored.isAssigned(agentID: owner.agentId, sessionID: owner.sessionId))
        await #expect(throws: DesktopComputerBridgeError.conflict) { try await restored.register(binding()) }
        var reconnected = owner
        reconnected.connectionId = UUID().uuidString
        try await restored.register(reconnected)
    }

    @Test func corruptedRegistryFailsClosed() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("broken".utf8).write(to: file)
        let bridge = DesktopComputerBridgeService(assignmentsURL: file)
        #expect(await bridge.isAssigned(agentID: "agent", sessionID: "session"))
        await #expect(throws: DesktopComputerBridgeError.unavailable) { try await bridge.register(binding()) }
    }

    @Test func expiryAndCancellationRemoveQueuedCommands() async throws {
        let bridge = DesktopComputerBridgeService(commandTimeout: 0.02)
        let owner = binding()
        try await bridge.register(owner)
        await #expect(throws: DesktopComputerBridgeError.timedOut) {
            try await bridge.run(agentID: owner.agentId, sessionID: owner.sessionId, name: "computer.click", input: .object([:]))
        }
        #expect(try await bridge.poll(owner).commands.isEmpty)
        let task = Task { try await bridge.run(agentID: owner.agentId, sessionID: owner.sessionId, name: "computer.click", input: .object([:])) }
        _ = try await next(bridge, owner)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await bridge.poll(owner).commands.isEmpty)
    }

    @Test func routeRequiresExistingSessionAndReturnsCommand() async throws {
        let service = CoreService(config: .test)
        let router = CoreRouter(service: service)
        let agentID = "desktop-test-" + UUID().uuidString.lowercased()
        _ = try await service.createAgent(.init(id: agentID, displayName: "Desktop test", role: "Testing"))
        let session = try await service.createAgentSession(agentID: agentID, request: .init(title: "Desktop"))
        var owner = binding()
        owner.agentId = agentID
        owner.sessionId = session.id
        let encoder = JSONEncoder()
        let body = try encoder.encode(owner)
        let registered = await router.handle(method: "POST", path: "/v1/desktop-computer/register", body: body)
        #expect(registered.status == 200)
        let bridge = await service.toolExecution.desktopComputerBridge
        let task = Task { try await bridge.run(agentID: agentID, sessionID: session.id, name: "computer.screenshot", input: .object([:])) }
        _ = try await next(bridge, owner)
        let disconnected = await router.handle(method: "POST", path: "/v1/desktop-computer/disconnect", body: body)
        #expect(disconnected.status == 200)
        await #expect(throws: DesktopComputerBridgeError.unavailable) { try await task.value }
        owner.sessionId = "missing"
        let unknown = await router.handle(method: "POST", path: "/v1/desktop-computer/register", body: try encoder.encode(owner))
        #expect(unknown.status == 404)
    }
}
