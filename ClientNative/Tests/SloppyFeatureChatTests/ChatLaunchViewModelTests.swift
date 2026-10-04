import Foundation
import SwiftUI
import Testing
import SloppyUITestSupport
import SloppyClientCore
@testable import SloppyFeatureChat
#if os(macOS)
import AppKit
#endif

@Suite("Chat Play", .serialized, .appKitUI)
@MainActor
struct ChatLaunchViewModelTests {
    @Test func playDoesNotAskModelAndDuplicateClickDoesNotStartTwice() async throws {
        let fixture = ChatPlayFixture()
        let api = makeAPI(fixture)
        let model = ChatLaunchViewModel(apiClient: api)
        let observing = Task { await model.observe(agentID: "agent", sessionID: "chat") }
        defer { observing.cancel(); ChatPlayURLProtocol.install(nil) }
        for _ in 0..<100 {
            if model.selected != nil { break }; try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.title == "Second App · macOS")
        async let first: Void = model.play()
        async let second: Void = model.play()
        _ = await (first, second)
        #expect(fixture.startCount == 1)
        #expect(!fixture.paths.contains { $0.hasSuffix("/messages") })
        #expect(model.run?.configuration.request.checkoutPath == "/tmp/worktree-two")
        #expect(model.showsLogs)
        await model.stop()
        #expect(model.run?.status == .stopped)
    }

    @Test func prepareLaunchPreservesComposerDraftAndRendersSelectedTarget() async throws {
        let fixture = ChatPlayFixture()
        let api = makeAPI(fixture)
        let settings = ClientSettings()
        let savedAgent = settings.lastAgentId, savedSession = settings.lastSessionId, savedProject = settings.lastProjectId
        let model = ChatScreenViewModel(apiClient: api, cacheStore: ClientCacheStore(path: ":memory:"),
                                        settings: settings, connectionMonitor: ConnectionMonitor(baseURL: api.baseURL),
                                        restoresLastSession: false, responseNotificationScheduler: ChatPlayNotifications(), onOpenSettings: { _ in })
        defer {
            model.pickPersonal()
            settings.lastAgentId = savedAgent; settings.lastSessionId = savedSession; settings.lastProjectId = savedProject
            ChatPlayURLProtocol.install(nil)
        }
        model.pickAgent(APIAgentRecord(id: "agent", displayName: "Agent"))
        model.selectedSessionId = "chat"
        model.composerDraft.text = "My unfinished question"
        model.prepareLaunch()
        #expect(model.composerDraft.text == "My unfinished question")
        #expect(model.isSending)
        for _ in 0..<100 {
            if fixture.paths.contains(where: { $0.hasSuffix("/messages") }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fixture.paths.contains { $0.hasSuffix("/messages") })
#if os(macOS)
        if let output = ProcessInfo.processInfo.environment["SLOPPY_PLAY_CONTROLS_PNG"] {
            let observing = Task { await model.launch.observe(agentID: "agent", sessionID: "chat") }
            defer { observing.cancel() }
            for _ in 0..<100 {
                if model.launch.selected != nil { break }; try await Task.sleep(for: .milliseconds(10))
            }
            let content = ChatLaunchControls(viewModel: model, onOpenPreview: { _ in })
                .padding(16).frame(width: 560, height: 72).background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .dark)
            let hosting = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 72),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.orderFront(nil)
            defer { window.close() }
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
        }
#endif
    }

    private func makeAPI(_ fixture: ChatPlayFixture) -> SloppyAPIClient {
        ChatPlayURLProtocol.install { fixture.response($0) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ChatPlayURLProtocol.self]
        return SloppyAPIClient(baseURL: URL(string: "https://play-ui.invalid")!, session: URLSession(configuration: config), authSessionStore: AuthSessionStore(persistence: .memory))
    }
}

#if os(macOS)
@Suite("Chat launch button", .serialized, .appKitUI)
@MainActor
struct ChatLaunchButtonTests {
    @Test func clickRunsAndHoldOnlyOpensOptions() async throws {
        var runs = 0
        var menus = 0
        let host = NSHostingView(rootView: ChatLaunchButton(
            systemImage: "play.fill", title: "Run", canPerformAction: true,
            onAction: { runs += 1 }, onShowOptions: { menus += 1 }
        ).frame(width: 80, height: 80))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 80, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(100))

        try sendMouse(.leftMouseDown, to: window)
        try await Task.sleep(for: .milliseconds(60))
        try sendMouse(.leftMouseUp, to: window)
        try await Task.sleep(for: .milliseconds(100))
        #expect(runs == 1)
        #expect(menus == 0)

        try sendMouse(.leftMouseDown, to: window)
        try await Task.sleep(for: .milliseconds(650))
        // Other native suites share the main run loop; wait for gesture delivery
        // while keeping the mouse held, rather than asserting on a wall-clock deadline.
        for _ in 0..<40 {
            if menus == 1 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(menus == 1)
        #expect(runs == 1)
        try sendMouse(.leftMouseUp, to: window)
        try await Task.sleep(for: .milliseconds(100))
        #expect(menus == 1)
        #expect(runs == 1)

        try sendMouse(.leftMouseDown, to: window)
        try await Task.sleep(for: .milliseconds(60))
        try sendMouse(.leftMouseUp, to: window)
        try await Task.sleep(for: .milliseconds(100))
        #expect(runs == 2)
        #expect(menus == 1)
    }

    @Test func unavailableRunStillAllowsChoosingLaunchOptions() async throws {
        var runs = 0
        var menus = 0
        let host = NSHostingView(rootView: ChatLaunchButton(
            systemImage: "play.fill", title: "Run", canPerformAction: false,
            onAction: { runs += 1 }, onShowOptions: { menus += 1 }
        ).frame(width: 80, height: 80))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 80, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(100))

        try sendMouse(.leftMouseDown, to: window)
        try await Task.sleep(for: .milliseconds(60))
        try sendMouse(.leftMouseUp, to: window)
        try await Task.sleep(for: .milliseconds(100))
        #expect(runs == 0)

        try sendMouse(.leftMouseDown, to: window)
        try await Task.sleep(for: .milliseconds(650))
        try sendMouse(.leftMouseUp, to: window)
        try await Task.sleep(for: .milliseconds(100))
        #expect(runs == 0)
        #expect(menus == 1)
    }

    private func sendMouse(_ type: NSEvent.EventType, to window: NSWindow) throws {
        let event = try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: 40, y: 40),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        window.sendEvent(event)
    }
}
#endif

private final class ChatPlayFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [String] = []
    private var starts = 0
    private var state: LaunchSessionState
    var paths: [String] { lock.withLock { requests } }
    var startCount: Int { lock.withLock { starts } }
    init() {
        state = LaunchSessionState(agentID: "agent", sessionID: "chat")
        let configuration = LaunchConfiguration(id: "two", agentID: "agent", sessionID: "chat", hostName: "Build Mac",
            request: .init(name: "Second App", target: "Client", platform: .macOS, checkoutPath: "/tmp/worktree-two", workingDirectory: "Client", appPath: "dist/App.app"), updatedAt: Date())
        state.configurations = [configuration]; state.selectedConfigurationID = "two"
    }
    func response(_ request: URLRequest) -> (Int, Data) {
        lock.withLock {
            let path = request.url?.path ?? ""; requests.append(path)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            if path.hasSuffix("/start") {
                starts += 1
                let run = LaunchRun(id: "run", configurationID: "two", configuration: state.configurations[0], status: .preparing,
                                    buildSucceeded: false, launchSucceeded: false, logs: "", startedAt: Date())
                state.runs = [run]
                return (200, try! encoder.encode(run))
            }
            if path.hasSuffix("/stop"), !state.runs.isEmpty { state.runs[0].status = .stopped }
            if path.contains("/launch") { return (200, try! encoder.encode(state)) }
            if path.hasSuffix("/messages") {
                let summary = ChatSessionSummary(id: "chat", agentId: "agent", title: "Play")
                return (200, try! encoder.encode(["summary": summary]))
            }
            return (200, Data("[]".utf8))
        }
    }
}

private final class ChatPlayURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (Int, Data)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?
    static func install(_ handler: Handler?) { lock.withLock { self.handler = handler } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "play-ui.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.lock.withLock({ Self.handler }), let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else { return }
        let (_, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
private final class ChatPlayNotifications: AgentResponseNotificationScheduling {
    func prepareAuthorization() async {}
    func schedule(_ notification: AgentResponseCompletionNotification) async {}
}
