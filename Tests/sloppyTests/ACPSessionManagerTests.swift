import ACP
import ACPModel
import Foundation
import Logging
import Testing
import SloppyRuntime
@testable import Protocols
@testable import sloppy

private typealias SwiftLogger = Logging.Logger

private final class ACPLogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [(level: SwiftLogger.Level, message: String, metadata: [String: String])] = []

    func append(level: SwiftLogger.Level, message: SwiftLogger.Message, metadata: SwiftLogger.Metadata) {
        lock.withLock {
            records.append((
                level: level,
                message: message.description,
                metadata: metadata.mapValues { value in
                    String(describing: value)
                }
            ))
        }
    }

    func snapshot() -> [(level: SwiftLogger.Level, message: String, metadata: [String: String])] {
        lock.withLock {
            records
        }
    }
}

private struct ACPRecordingLogHandler: LogHandler {
    let label: String
    let recorder: ACPLogRecorder
    var metadata: SwiftLogger.Metadata = [:]
    var logLevel: SwiftLogger.Level = .trace

    subscript(metadataKey key: String) -> SwiftLogger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        var merged = metadata
        if let explicitMetadata = event.metadata {
            for (key, value) in explicitMetadata {
                merged[key] = value
            }
        }
        recorder.append(level: event.level, message: event.message, metadata: merged)
    }
}

private func makeRecordingLogger(_ recorder: ACPLogRecorder) -> SwiftLogger {
    SwiftLogger(label: "test.acp") { label in
        ACPRecordingLogHandler(label: label, recorder: recorder)
    }
}

private func makeNoOpLogger() -> SwiftLogger {
    SwiftLogger(label: "sloppy.acp.test") { _ in SwiftLogNoOpLogHandler() }
}

private final class MockACPClientQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var clients: [MockACPTransportClient]

    init(clients: [MockACPTransportClient]) {
        self.clients = clients
    }

    func next() -> MockACPTransportClient {
        lock.withLock {
            clients.removeFirst()
        }
    }
}

private actor MockACPTransportClient: ACPTransportClient {
    private let initializeResponse: InitializeResponse
    private let promptResponse: SessionPromptResponse
    private let newSessionResponse: NewSessionResponse
    private let loadSessionResponse: LoadSessionResponse
    private let loadSessionError: Error?
    private let permissionRequest: RequestPermissionRequest?

    private var delegate: ClientDelegate?
    private var connectCount = 0
    private var newSessionCount = 0
    private var loadSessionCount = 0
    private var setModeCount = 0
    private var sendPromptCount = 0
    private var terminateCount = 0
    private var setModeIDs: [String] = []
    private var sentPromptTexts: [String] = []
    private var sentPromptImageCounts: [Int] = []
    private var lastPermissionOutcome: RequestPermissionResponse?

    private let notificationContinuation: AsyncStream<JSONRPCNotification>.Continuation
    private let notificationStream: AsyncStream<JSONRPCNotification>

    init(
        initializeResponse: InitializeResponse,
        promptResponse: SessionPromptResponse = SessionPromptResponse(stopReason: .endTurn),
        newSessionResponse: NewSessionResponse = NewSessionResponse(sessionId: SessionId("upstream-1")),
        loadSessionResponse: LoadSessionResponse = LoadSessionResponse(sessionId: SessionId("upstream-1")),
        loadSessionError: Error? = nil,
        permissionRequest: RequestPermissionRequest? = nil
    ) {
        self.initializeResponse = initializeResponse
        self.promptResponse = promptResponse
        self.newSessionResponse = newSessionResponse
        self.loadSessionResponse = loadSessionResponse
        self.loadSessionError = loadSessionError
        self.permissionRequest = permissionRequest

        var continuation: AsyncStream<JSONRPCNotification>.Continuation!
        self.notificationStream = AsyncStream { cont in
            continuation = cont
        }
        self.notificationContinuation = continuation
    }

    func setDelegate(_ delegate: ClientDelegate?) async {
        self.delegate = delegate
    }

    func notificationsStream() async -> AsyncStream<JSONRPCNotification> {
        notificationStream
    }

    func connect(
        workingDirectory _: String,
        capabilities _: ClientCapabilities,
        clientInfo _: ClientInfo,
        timeout _: TimeInterval?
    ) async throws -> InitializeResponse {
        connectCount += 1
        return initializeResponse
    }

    func newSession(workingDirectory _: String, timeout _: TimeInterval?) async throws -> NewSessionResponse {
        newSessionCount += 1
        return newSessionResponse
    }

    func loadSession(sessionId _: SessionId, cwd _: String?) async throws -> LoadSessionResponse {
        loadSessionCount += 1
        if let loadSessionError {
            throw loadSessionError
        }
        return loadSessionResponse
    }

    func setMode(sessionId _: SessionId, modeId: String) async throws -> SetModeResponse {
        setModeCount += 1
        setModeIDs.append(modeId)
        return SetModeResponse(success: true)
    }

    func sendPrompt(sessionId _: SessionId, content: [ContentBlock]) async throws -> SessionPromptResponse {
        sendPromptCount += 1
        sentPromptTexts.append(content.compactMap(Self.text(from:)).joined(separator: "\n"))
        sentPromptImageCounts.append(content.filter(Self.isImage(_:)).count)
        if let permissionRequest, let delegate {
            lastPermissionOutcome = try await delegate.handlePermissionRequest(request: permissionRequest)
        }
        return promptResponse
    }

    func cancelSession(sessionId _: SessionId) async throws {}

    func terminate() async {
        terminateCount += 1
        notificationContinuation.finish()
    }

    func snapshot() -> (connects: Int, newSessions: Int, loads: Int, setModes: Int, modeIDs: [String], prompts: Int, terminated: Int, promptTexts: [String], promptImageCounts: [Int], permissionOutcome: RequestPermissionResponse?) {
        (
            connects: connectCount,
            newSessions: newSessionCount,
            loads: loadSessionCount,
            setModes: setModeCount,
            modeIDs: setModeIDs,
            prompts: sendPromptCount,
            terminated: terminateCount,
            promptTexts: sentPromptTexts,
            promptImageCounts: sentPromptImageCounts,
            permissionOutcome: lastPermissionOutcome
        )
    }

    private static func text(from block: ContentBlock) -> String? {
        switch block {
        case .text(let text):
            return text.text
        default:
            return nil
        }
    }

    private static func isImage(_ block: ContentBlock) -> Bool {
        if case .image = block {
            return true
        }
        return false
    }
}

private actor EventRecorder {
    private(set) var events: [AgentSessionEvent] = []
    private(set) var chunks: [String] = []

    func append(event: AgentSessionEvent) {
        events.append(event)
    }

    func append(chunk: String) {
        chunks.append(chunk)
    }
}

private func makeInitializeResponse(loadSession: Bool) -> InitializeResponse {
    InitializeResponse(
        protocolVersion: 1,
        agentCapabilities: AgentCapabilities(
            loadSession: loadSession,
            mcpCapabilities: MCPCapabilities(http: true, sse: false),
            promptCapabilities: PromptCapabilities(image: true),
            sessionCapabilities: SessionCapabilities(list: SessionListCapabilities())
        ),
        agentInfo: AgentInfo(name: "Mock Agent", version: "1.0.0")
    )
}

private func makeSessionManagerFixture(
    target: CoreConfig.ACP.Target,
    clients: [MockACPTransportClient],
    logger: SwiftLogger? = nil
) throws -> (manager: ACPSessionManager, agentsRootURL: URL, sessionID: String) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("acp-session-manager-\(UUID().uuidString)", isDirectory: true)
    let agentsRootURL = root.appendingPathComponent("agents", isDirectory: true)
    let sessionsURL = agentsRootURL.appendingPathComponent("agent-1", isDirectory: true).appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
    let sessionStore = AgentSessionFileStore(agentsRootURL: agentsRootURL)
    let session = try sessionStore.createSession(
        agentID: "agent-1",
        request: AgentSessionCreateRequest(title: "ACP test session"),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    let queue = MockACPClientQueue(clients: clients)
    let manager = ACPSessionManager(
        config: .init(enabled: true, targets: [target]),
        workspaceRootURL: root,
        agentsRootURL: agentsRootURL,
        logger: logger ?? makeNoOpLogger(),
        clientFactory: ACPClientFactory { _ in
            queue.next()
        }
    )

    return (manager, agentsRootURL, session.id)
}

@Test
func acpSessionManagerLogsLifecycleEventsForDashboard() async throws {
    let target = CoreConfig.ACP.Target(
        id: "local",
        title: "Local ACP",
        transport: .stdio,
        command: "/bin/echo"
    )
    let recorder = ACPLogRecorder()
    let logger = makeRecordingLogger(recorder)
    let client = MockACPTransportClient(initializeResponse: makeInitializeResponse(loadSession: true))
    let (manager, _, sessionID) = try makeSessionManagerFixture(
        target: target,
        clients: [client],
        logger: logger
    )

    _ = try await manager.postMessage(
        agentID: "agent-1",
        sloppySessionID: sessionID,
        runtime: .init(type: .acp, acp: .init(targetId: "local")),
        content: [.text(TextContent(text: "hello"))],
        localSessionHadPriorMessages: false,
        primerContent: nil,
        onChunk: { _ in },
        onEvent: { _ in }
    )

    let logs = recorder.snapshot()
    #expect(logs.contains { $0.message == "ACP prompt dispatch started" })
    #expect(logs.contains { $0.message == "ACP client initialized" })
    #expect(logs.contains { $0.message == "ACP upstream session created" })
    #expect(logs.contains { $0.message == "ACP prompt completed" })
    #expect(logs.allSatisfy { $0.metadata["agent_id"] == "agent-1" || $0.metadata["agent_id"] == nil })
}

@Test
func acpSessionManagerCreatesSessionSendsPrimerAndPersistsSidecar() async throws {
    let target = CoreConfig.ACP.Target(
        id: "local",
        title: "Local ACP",
        transport: .stdio,
        command: "/bin/echo"
    )
    let client = MockACPTransportClient(initializeResponse: makeInitializeResponse(loadSession: true))
    let (manager, agentsRootURL, sessionID) = try makeSessionManagerFixture(target: target, clients: [client])
    let recorder = EventRecorder()

    let result = try await manager.postMessage(
        agentID: "agent-1",
        sloppySessionID: sessionID,
        runtime: .init(type: .acp, acp: .init(targetId: "local")),
        content: [.text(TextContent(text: "hello"))],
        localSessionHadPriorMessages: false,
        primerContent: "BOOTSTRAP",
        onChunk: { chunk in await recorder.append(chunk: chunk) },
        onEvent: { event in await recorder.append(event: event) }
    )

    #expect(result.didResetContext == false)

    let snapshot = await client.snapshot()
    #expect(snapshot.newSessions == 1)
    #expect(snapshot.loads == 0)
    #expect(snapshot.prompts == 2)
    #expect(snapshot.promptTexts.first == "BOOTSTRAP")
    #expect(snapshot.promptTexts.last == "hello")

    let sidecarURL = agentsRootURL
        .appendingPathComponent("agent-1", isDirectory: true)
        .appendingPathComponent("sessions", isDirectory: true)
        .appendingPathComponent("2023", isDirectory: true)
        .appendingPathComponent("11", isDirectory: true)
        .appendingPathComponent("14", isDirectory: true)
        .appendingPathComponent(sessionID, isDirectory: true)
        .appendingPathComponent("acp-state.json")
    #expect(FileManager.default.fileExists(atPath: sidecarURL.path))

    let sidecarData = try Data(contentsOf: sidecarURL)
    let sidecar = try JSONDecoder().decode(ACPPersistedSessionState.self, from: sidecarData)
    #expect(sidecar.targetId == "local")
    #expect(sidecar.upstreamSessionId == "upstream-1")
    #expect(sidecar.supportsLoadSession == true)
}

@Test
func acpSessionManagerSendsImageContentBlocks() async throws {
    let target = CoreConfig.ACP.Target(
        id: "local",
        title: "Local ACP",
        transport: .stdio,
        command: "/bin/echo"
    )
    let client = MockACPTransportClient(initializeResponse: makeInitializeResponse(loadSession: true))
    let (manager, _, sessionID) = try makeSessionManagerFixture(target: target, clients: [client])

    _ = try await manager.postMessage(
        agentID: "agent-1",
        sloppySessionID: sessionID,
        runtime: .init(type: .acp, acp: .init(targetId: "local")),
        content: [
            .text(TextContent(text: "inspect this")),
            .image(ImageContent(data: Data([1, 2, 3]).base64EncodedString(), mimeType: "image/png"))
        ],
        localSessionHadPriorMessages: false,
        primerContent: nil,
        onChunk: { _ in },
        onEvent: { _ in }
    )

    let snapshot = await client.snapshot()
    #expect(snapshot.prompts == 1)
    #expect(snapshot.promptTexts == ["inspect this"])
    #expect(snapshot.promptImageCounts == [1])
}

@Test
func acpSessionManagerAppliesRequestedChatModeBeforePrompt() async throws {
    let target = CoreConfig.ACP.Target(
        id: "local",
        title: "Local ACP",
        transport: .stdio,
        command: "/bin/echo"
    )
    let modes = ModesInfo(
        currentModeId: "ask",
        availableModes: [
            ModeInfo(id: "ask", name: "Ask"),
            ModeInfo(id: "code", name: "Code"),
            ModeInfo(id: "plan", name: "Plan"),
            ModeInfo(id: "debug", name: "Debug")
        ]
    )
    let client = MockACPTransportClient(
        initializeResponse: makeInitializeResponse(loadSession: true),
        newSessionResponse: NewSessionResponse(sessionId: SessionId("upstream-1"), modes: modes)
    )
    let (manager, _, sessionID) = try makeSessionManagerFixture(target: target, clients: [client])

    _ = try await manager.postMessage(
        agentID: "agent-1",
        sloppySessionID: sessionID,
        runtime: .init(type: .acp, acp: .init(targetId: "local")),
        content: [.text(TextContent(text: "please edit files"))],
        localSessionHadPriorMessages: false,
        primerContent: nil,
        chatMode: .build,
        onChunk: { _ in },
        onEvent: { _ in }
    )

    let snapshot = await client.snapshot()
    #expect(snapshot.setModes == 1)
    #expect(snapshot.modeIDs == ["code"])
    #expect(snapshot.prompts == 1)
    #expect(snapshot.promptTexts == ["please edit files"])
}

@Test
func acpSessionManagerRestoresMatchingSidecarViaLoadSessionWithoutPrimer() async throws {
    let target = CoreConfig.ACP.Target(
        id: "local",
        title: "Local ACP",
        transport: .stdio,
        command: "/bin/echo"
    )
    let firstClient = MockACPTransportClient(initializeResponse: makeInitializeResponse(loadSession: true))
    let fixture = try makeSessionManagerFixture(target: target, clients: [firstClient])

    _ = try await fixture.manager.postMessage(
        agentID: "agent-1",
        sloppySessionID: fixture.sessionID,
        runtime: .init(type: .acp, acp: .init(targetId: "local")),
        content: [.text(TextContent(text: "first"))],
        localSessionHadPriorMessages: false,
        primerContent: "BOOTSTRAP",
        onChunk: { _ in },
        onEvent: { _ in }
    )

    let secondClient = MockACPTransportClient(initializeResponse: makeInitializeResponse(loadSession: true))
    let queue = MockACPClientQueue(clients: [secondClient])
    let restoredManager = ACPSessionManager(
        config: .init(enabled: true, targets: [target]),
        workspaceRootURL: fixture.agentsRootURL.deletingLastPathComponent(),
        agentsRootURL: fixture.agentsRootURL,
        logger: makeNoOpLogger(),
        clientFactory: ACPClientFactory { _ in queue.next() }
    )

    let result = try await restoredManager.postMessage(
        agentID: "agent-1",
        sloppySessionID: fixture.sessionID,
        runtime: .init(type: .acp, acp: .init(targetId: "local")),
        content: [.text(TextContent(text: "second"))],
        localSessionHadPriorMessages: true,
        primerContent: "BOOTSTRAP",
        onChunk: { _ in },
        onEvent: { _ in }
    )

    #expect(result.didResetContext == false)

    let snapshot = await secondClient.snapshot()
    #expect(snapshot.loads == 1)
    #expect(snapshot.newSessions == 0)
    #expect(snapshot.prompts == 1)
    #expect(snapshot.promptTexts == ["second"])
}

@Test
func acpSessionManagerDropsMismatchedSidecarAndCreatesNewUpstreamSession() async throws {
    let originalTarget = CoreConfig.ACP.Target(
        id: "local",
        title: "Local ACP",
        transport: .stdio,
        command: "/bin/echo"
    )
    let fixture = try makeSessionManagerFixture(
        target: originalTarget,
        clients: [MockACPTransportClient(initializeResponse: makeInitializeResponse(loadSession: true))]
    )

    _ = try await fixture.manager.postMessage(
        agentID: "agent-1",
        sloppySessionID: fixture.sessionID,
        runtime: .init(type: .acp, acp: .init(targetId: "local")),
        content: [.text(TextContent(text: "first"))],
        localSessionHadPriorMessages: false,
        primerContent: "BOOTSTRAP",
        onChunk: { _ in },
        onEvent: { _ in }
    )

    let changedTarget = CoreConfig.ACP.Target(
        id: "local",
        title: "Local ACP",
        transport: .stdio,
        command: "/bin/cat"
    )
    let client = MockACPTransportClient(initializeResponse: makeInitializeResponse(loadSession: true))
    let queue = MockACPClientQueue(clients: [client])
    let manager = ACPSessionManager(
        config: .init(enabled: true, targets: [changedTarget]),
        workspaceRootURL: fixture.agentsRootURL.deletingLastPathComponent(),
        agentsRootURL: fixture.agentsRootURL,
        logger: makeNoOpLogger(),
        clientFactory: ACPClientFactory { _ in queue.next() }
    )

    let result = try await manager.postMessage(
        agentID: "agent-1",
        sloppySessionID: fixture.sessionID,
        runtime: .init(type: .acp, acp: .init(targetId: "local")),
        content: [.text(TextContent(text: "second"))],
        localSessionHadPriorMessages: true,
        primerContent: "BOOTSTRAP",
        onChunk: { _ in },
        onEvent: { _ in }
    )

    #expect(result.didResetContext == true)

    let snapshot = await client.snapshot()
    #expect(snapshot.loads == 0)
    #expect(snapshot.newSessions == 1)
    #expect(snapshot.prompts == 2)
}

@Test
func acpSessionManagerSelectsExactAllowOncePermissionOption() async throws {
    let target = CoreConfig.ACP.Target(
        id: "local",
        title: "Local ACP",
        transport: .stdio,
        command: "/bin/echo",
        permissionMode: .allowOnce
    )
    let client = MockACPTransportClient(
        initializeResponse: makeInitializeResponse(loadSession: false),
        permissionRequest: RequestPermissionRequest(
            message: "Run dangerous tool?",
            options: [
                PermissionOption(kind: "decision", name: "Allow once", optionId: "allow_once"),
                PermissionOption(kind: "decision", name: "Always allow", optionId: "allow_always")
            ]
        )
    )
    let (manager, _, sessionID) = try makeSessionManagerFixture(target: target, clients: [client])
    let recorder = EventRecorder()

    _ = try await manager.postMessage(
        agentID: "agent-1",
        sloppySessionID: sessionID,
        runtime: .init(type: .acp, acp: .init(targetId: "local")),
        content: [.text(TextContent(text: "hello"))],
        localSessionHadPriorMessages: false,
        primerContent: nil,
        onChunk: { _ in },
        onEvent: { event in await recorder.append(event: event) }
    )

    let snapshot = await client.snapshot()
    #expect(snapshot.permissionOutcome?.outcome.optionId == "allow_once")
    let permissionEvent = await recorder.events.last(where: { $0.type == .runStatus })
    #expect(permissionEvent?.runStatus?.details?.contains("allow_once") == true)
}

@Test
func acpSessionManagerFullAccessSelectsBestAllowPermissionOption() async throws {
    let target = CoreConfig.ACP.Target(
        id: "local",
        title: "Local ACP",
        transport: .stdio,
        command: "/bin/echo",
        permissionMode: .fullAccess
    )
    let client = MockACPTransportClient(
        initializeResponse: makeInitializeResponse(loadSession: false),
        permissionRequest: RequestPermissionRequest(
            message: "Run dangerous tool?",
            options: [
                PermissionOption(kind: "decision", name: "Allow once", optionId: "allow_once"),
                PermissionOption(kind: "decision", name: "Always allow", optionId: "allow_always")
            ]
        )
    )
    let (manager, _, sessionID) = try makeSessionManagerFixture(target: target, clients: [client])
    let recorder = EventRecorder()

    _ = try await manager.postMessage(
        agentID: "agent-1",
        sloppySessionID: sessionID,
        runtime: .init(type: .acp, acp: .init(targetId: "local")),
        content: [.text(TextContent(text: "hello"))],
        localSessionHadPriorMessages: false,
        primerContent: nil,
        onChunk: { _ in },
        onEvent: { event in await recorder.append(event: event) }
    )

    let snapshot = await client.snapshot()
    #expect(snapshot.permissionOutcome?.outcome.optionId == "allow_always")
    let permissionEvent = await recorder.events.last(where: { $0.type == .runStatus })
    #expect(permissionEvent?.runStatus?.details?.contains("allow_always") == true)
}

@Test
func acpSessionManagerRejectsWhenAllowOnceIsUnavailableOrDeniedByMode() async throws {
    let target = CoreConfig.ACP.Target(
        id: "local",
        title: "Local ACP",
        transport: .stdio,
        command: "/bin/echo",
        permissionMode: .deny
    )
    let client = MockACPTransportClient(
        initializeResponse: makeInitializeResponse(loadSession: false),
        permissionRequest: RequestPermissionRequest(
            message: "Run dangerous tool?",
            options: [
                PermissionOption(kind: "decision", name: "Allow once", optionId: "allow_once"),
                PermissionOption(kind: "decision", name: "Always allow", optionId: "allow_always")
            ]
        )
    )
    let (manager, _, sessionID) = try makeSessionManagerFixture(target: target, clients: [client])
    let recorder = EventRecorder()

    _ = try await manager.postMessage(
        agentID: "agent-1",
        sloppySessionID: sessionID,
        runtime: .init(type: .acp, acp: .init(targetId: "local")),
        content: [.text(TextContent(text: "hello"))],
        localSessionHadPriorMessages: false,
        primerContent: nil,
        onChunk: { _ in },
        onEvent: { event in await recorder.append(event: event) }
    )

    let snapshot = await client.snapshot()
    #expect(snapshot.permissionOutcome?.outcome.optionId == nil)
    #expect(snapshot.permissionOutcome?.outcome.outcome == "cancelled")
    let permissionEvent = await recorder.events.last(where: { $0.type == .runStatus })
    #expect(permissionEvent?.runStatus?.details?.contains("denied") == true)
}

@Test
func acpSessionManagerRejectsAllowAlwaysFallbackWhenAllowOnceMissing() async throws {
    let target = CoreConfig.ACP.Target(
        id: "local",
        title: "Local ACP",
        transport: .stdio,
        command: "/bin/echo",
        permissionMode: .allowOnce
    )
    let client = MockACPTransportClient(
        initializeResponse: makeInitializeResponse(loadSession: false),
        permissionRequest: RequestPermissionRequest(
            message: "Run dangerous tool?",
            options: [
                PermissionOption(kind: "decision", name: "Always allow", optionId: "allow_always")
            ]
        )
    )
    let (manager, _, sessionID) = try makeSessionManagerFixture(target: target, clients: [client])
    let recorder = EventRecorder()

    _ = try await manager.postMessage(
        agentID: "agent-1",
        sloppySessionID: sessionID,
        runtime: .init(type: .acp, acp: .init(targetId: "local")),
        content: [.text(TextContent(text: "hello"))],
        localSessionHadPriorMessages: false,
        primerContent: nil,
        onChunk: { _ in },
        onEvent: { event in await recorder.append(event: event) }
    )

    let snapshot = await client.snapshot()
    #expect(snapshot.permissionOutcome?.outcome.optionId == nil)
    #expect(snapshot.permissionOutcome?.outcome.outcome == "cancelled")
    let permissionEvent = await recorder.events.last(where: { $0.type == .runStatus })
    #expect(permissionEvent?.runStatus?.details?.contains("allow_once unavailable") == true)
}
