import Foundation
import Logging
import Testing
import SloppyRuntime
@testable import AgentRuntime
@testable import sloppy
@testable import Protocols

@Suite("Session tools")
struct SessionToolsTests {
    private func makeSessionStore(rootURL: URL) -> AgentSessionFileStore {
        AgentSessionFileStore(agentsRootURL: rootURL)
    }

    private func makeCatalogStore(rootURL: URL) -> AgentCatalogFileStore {
        AgentCatalogFileStore(agentsRootURL: rootURL)
    }

    private func setupAgentWithSession(
        agentID: String = "test-agent",
        rootURL: URL
    ) throws -> (store: AgentSessionFileStore, sessionID: String) {
        let catalogStore = makeCatalogStore(rootURL: rootURL)
        _ = try catalogStore.createAgent(
            AgentCreateRequest(id: agentID, displayName: "Test Agent", role: "Testing"),
            availableModels: []
        )

        let sessionStore = makeSessionStore(rootURL: rootURL)
        let session = try sessionStore.createSession(
            agentID: agentID,
            request: AgentSessionCreateRequest(title: "Test session")
        )

        let userEvent = AgentSessionEvent(
            agentId: agentID,
            sessionId: session.id,
            type: .message,
            message: AgentSessionMessage(
                role: .user,
                segments: [AgentMessageSegment(kind: .text, text: "Hello")],
                userId: "user1"
            )
        )
        let assistantEvent = AgentSessionEvent(
            agentId: agentID,
            sessionId: session.id,
            type: .message,
            message: AgentSessionMessage(
                role: .assistant,
                segments: [AgentMessageSegment(kind: .text, text: "Hi there!")],
                userId: "agent"
            )
        )

        try sessionStore.appendEvents(agentID: agentID, sessionID: session.id, events: [userEvent, assistantEvent])
        return (sessionStore, session.id)
    }

    private func makeContext(
        agentID: String = "test-agent",
        sessionID: String,
        sessionStore: AgentSessionFileStore,
        rootURL: URL
    ) -> ToolContext {
        ToolContext(
            agentID: agentID,
            sessionID: sessionID,
            policy: AgentToolsPolicy(),
            workspaceRootURL: rootURL,
            runtime: RuntimeSystem(),
            memoryStore: InMemoryMemoryStore(),
            sessionStore: sessionStore,
            agentCatalogStore: AgentCatalogFileStore(agentsRootURL: rootURL),
            agentSkillsStore: nil,
            processRegistry: SessionProcessRegistry(),
            channelSessionStore: ChannelSessionFileStore(workspaceRootURL: rootURL),
            store: InMemoryCorePersistenceBuilder().makeStore(config: CoreConfig.test),
            searchProviderService: SearchProviderService(config: CoreConfig.default.searchTools),
            mcpRegistry: MCPClientRegistry(config: CoreConfig.default.mcp),
            logger: .sloppy(label: "test"),
            projectService: nil,
            configService: nil,
            skillsService: nil,
            lspManager: nil,
            applyAgentMarkdown: nil,
            delegateSubagent: nil
        )
    }

    @Test("createSession default title includes UUID suffix")
    func createSessionDefaultTitleIncludesUUIDSuffix() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("default-session-title-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let catalogStore = makeCatalogStore(rootURL: rootURL)
        _ = try catalogStore.createAgent(
            AgentCreateRequest(id: "test-agent", displayName: "Test Agent", role: "Testing"),
            availableModels: []
        )

        let store = makeSessionStore(rootURL: rootURL)
        let session = try store.createSession(agentID: "test-agent", request: AgentSessionCreateRequest())
        let expectedSuffix = String(session.id.dropFirst("session-".count).prefix(8))

        #expect(session.title == "Session \(expectedSuffix)")
        #expect(session.title != "Session session-")
    }

    @Test("sessions.history loads current session")
    func sessionsHistoryLoadsCurrent() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-tools-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let (store, sessionID) = try setupAgentWithSession(rootURL: rootURL)
        let context = makeContext(sessionID: sessionID, sessionStore: store, rootURL: rootURL)

        let tool = SessionsHistoryTool()
        let result = await tool.invoke(
            arguments: ["sessionId": .string("current")],
            context: context
        )

        #expect(result.ok == true, "sessions.history should succeed, got error: \(result.error?.message ?? "nil")")

        let events = result.data?.asObject?["events"]?.asArray
        #expect(events != nil)
        #expect((events?.count ?? 0) >= 3)
    }

    @Test("channel.history returns agent session messages for own session ID")
    func channelHistoryReturnsAgentSessionMessages() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("channel-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let (store, sessionID) = try setupAgentWithSession(rootURL: rootURL)
        let context = makeContext(sessionID: sessionID, sessionStore: store, rootURL: rootURL)

        let tool = ChannelHistoryTool()
        let result = await tool.invoke(
            arguments: ["channel_id": .string(sessionID)],
            context: context
        )

        #expect(result.ok == true, "channel.history should succeed for own session ID")

        let count = result.data?.asObject?["count"]?.asNumber
        #expect(count == 2, "Should have 2 messages (user + assistant)")

        let messages = result.data?.asObject?["messages"]?.asArray
        let firstContent = messages?.first?.asObject?["content"]?.asString
        #expect(firstContent == "Hello")
    }

    @Test("channel.history returns agent session messages for full channel ID")
    func channelHistoryReturnsAgentSessionMessagesFullID() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("channel-history-full-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let agentID = "test-agent"
        let (store, sessionID) = try setupAgentWithSession(agentID: agentID, rootURL: rootURL)
        let fullChannelID = "agent:\(agentID):session:\(sessionID)"
        let context = makeContext(agentID: agentID, sessionID: sessionID, sessionStore: store, rootURL: rootURL)

        let tool = ChannelHistoryTool()
        let result = await tool.invoke(
            arguments: ["channel_id": .string(fullChannelID)],
            context: context
        )

        #expect(result.ok == true, "channel.history should succeed for full channel ID")
        let count = result.data?.asObject?["count"]?.asNumber
        #expect(count == 2)
    }

    @Test("sessions.history via invokeToolFromRuntime succeeds")
    func sessionsHistoryViaRuntimeInvocation() async throws {
        let config = CoreConfig.test
        let service = CoreService(config: config)
        let agentID = "hist-runtime-\(UUID().uuidString)"

        _ = try await service.createAgent(
            AgentCreateRequest(id: agentID, displayName: "History Agent", role: "Testing")
        )
        let session = try await service.createAgentSession(
            agentID: agentID,
            request: AgentSessionCreateRequest(title: "History session")
        )

        _ = try await service.postAgentSessionMessage(
            agentID: agentID,
            sessionID: session.id,
            request: AgentSessionPostMessageRequest(
                userId: "cli",
                content: "Hello from user"
            )
        )

        let result = await service.invokeToolFromRuntime(
            agentID: agentID,
            sessionID: session.id,
            request: ToolInvocationRequest(
                tool: "sessions.history",
                arguments: ["sessionId": .string("current")],
                reason: "Test"
            ),
            recordSessionEvents: false
        )

        #expect(result.ok == true, "sessions.history via runtime should succeed, got: \(result.error?.message ?? "nil") code: \(result.error?.code ?? "nil")")
    }

    @Test("channel.history via invokeToolFromRuntime returns messages")
    func channelHistoryViaRuntimeInvocation() async throws {
        let config = CoreConfig.test
        let service = CoreService(config: config)
        let agentID = "ch-hist-runtime-\(UUID().uuidString)"

        _ = try await service.createAgent(
            AgentCreateRequest(id: agentID, displayName: "CH History Agent", role: "Testing")
        )
        let session = try await service.createAgentSession(
            agentID: agentID,
            request: AgentSessionCreateRequest(title: "CH History session")
        )

        _ = try await service.postAgentSessionMessage(
            agentID: agentID,
            sessionID: session.id,
            request: AgentSessionPostMessageRequest(
                userId: "cli",
                content: "Hello for channel history"
            )
        )

        let result = await service.invokeToolFromRuntime(
            agentID: agentID,
            sessionID: session.id,
            request: ToolInvocationRequest(
                tool: "channel.history",
                arguments: ["channel_id": .string(session.id)],
                reason: "Test"
            ),
            recordSessionEvents: false
        )

        #expect(result.ok == true, "channel.history via runtime should succeed")
        let count = result.data?.asObject?["count"]?.asNumber
        #expect((count ?? 0) >= 1, "Should have at least 1 message")
    }

    @Test("sessions.history loads real production session file")
    func sessionsHistoryLoadsRealFile() throws {
        let realFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".sloppy/agents/sloppy/sessions/session-f242efc1-2b84-4f87-b3b9-e72a5dca4a69.jsonl")

        guard FileManager.default.fileExists(atPath: realFile.path) else {
            return
        }

        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("real-session-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let agentDir = rootURL
            .appendingPathComponent("sloppy", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)

        let destFile = agentDir.appendingPathComponent("session-f242efc1-2b84-4f87-b3b9-e72a5dca4a69.jsonl")
        try FileManager.default.copyItem(at: realFile, to: destFile)

        let store = AgentSessionFileStore(agentsRootURL: rootURL)
        let detail = try store.loadSession(
            agentID: "sloppy",
            sessionID: "session-f242efc1-2b84-4f87-b3b9-e72a5dca4a69"
        )

        #expect(!detail.events.isEmpty, "Should have loaded events from real JSONL file")
        let messageEvents = detail.events.filter { $0.type == .message }
        #expect(messageEvents.count >= 2, "Should have at least 2 messages (user + assistant)")
    }

    @Test("sessions.history loads partial production file (33 lines, state at first failure)")
    func sessionsHistoryLoadsPartialFile() throws {
        let realFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".sloppy/agents/sloppy/sessions/session-f242efc1-2b84-4f87-b3b9-e72a5dca4a69.jsonl")

        guard FileManager.default.fileExists(atPath: realFile.path) else {
            return
        }

        let data = try Data(contentsOf: realFile)
        let content = String(data: data, encoding: .utf8)!
        let lines = content.split(whereSeparator: \.isNewline)
        let partialContent = lines.prefix(33).joined(separator: "\n") + "\n"

        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("partial-session-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let agentDir = rootURL
            .appendingPathComponent("sloppy", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)

        let destFile = agentDir.appendingPathComponent("session-f242efc1-2b84-4f87-b3b9-e72a5dca4a69.jsonl")
        try partialContent.data(using: .utf8)!.write(to: destFile)

        let store = AgentSessionFileStore(agentsRootURL: rootURL)
        let detail = try store.loadSession(
            agentID: "sloppy",
            sessionID: "session-f242efc1-2b84-4f87-b3b9-e72a5dca4a69"
        )

        #expect(!detail.events.isEmpty, "Should have loaded events from partial JSONL")
    }

    @Test("loadSession throws sessionFileNotFound for missing agent directory")
    func loadSessionFileNotFoundError() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-agent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let store = AgentSessionFileStore(agentsRootURL: rootURL)

        do {
            _ = try store.loadSession(agentID: "nonexistent", sessionID: "session-000")
            Issue.record("Expected error but loadSession succeeded")
        } catch let error as AgentSessionFileStore.StoreError {
            let desc = String(describing: error)
            #expect(desc.contains("sessionFileNotFound"), "Error should be sessionFileNotFound, got: \(desc)")
            #expect(desc.contains("nonexistent"), "Error should contain agentID")
        }
    }

    @Test("loadSession throws sessionEventsEmpty for empty JSONL content")
    func loadSessionEventsEmptyError() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-events-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let agentDir = rootURL
            .appendingPathComponent("test-agent", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)

        let sessionFile = agentDir.appendingPathComponent("session-empty.jsonl")
        try "not valid json\n".data(using: .utf8)!.write(to: sessionFile)

        let store = AgentSessionFileStore(agentsRootURL: rootURL)

        do {
            _ = try store.loadSession(agentID: "test-agent", sessionID: "session-empty")
            Issue.record("Expected error but loadSession succeeded")
        } catch let error as AgentSessionFileStore.StoreError {
            let desc = String(describing: error)
            #expect(desc.contains("sessionEventsEmpty"), "Error should be sessionEventsEmpty, got: \(desc)")
            #expect(desc.contains("lines=1"), "Error should show line count")
        }
    }

    @Test("channel.history falls back to gateway store for unknown channel")
    func channelHistoryFallsBackForUnknownChannel() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("channel-history-fallback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let (store, sessionID) = try setupAgentWithSession(rootURL: rootURL)
        let context = makeContext(sessionID: sessionID, sessionStore: store, rootURL: rootURL)

        let tool = ChannelHistoryTool()
        let result = await tool.invoke(
            arguments: ["channel_id": .string("some-other-channel")],
            context: context
        )

        #expect(result.ok == true)
        let count = result.data?.asObject?["count"]?.asNumber
        #expect(count == 0)
    }
}
