import AgentRuntime
import Foundation
import PluginSDK
import Protocols

public struct SloppyBuildResult: Sendable {
    public let ok: Bool
    public let summary: String

    public init(ok: Bool, summary: String) {
        self.ok = ok
        self.summary = summary
    }
}

public struct SloppyChatMessage: Identifiable, Sendable {
    public enum Role: Equatable, Sendable {
        case user
        case assistant
    }

    public let id: String
    public let role: Role
    public let text: String
    public let createdAt: Date

    public init(id: String, role: Role, text: String, createdAt: Date) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}

/// An in-process Sloppy model loop that can be hosted by a mobile app.
public actor SloppyRuntimeHost {
    private static let agentID = "mobile"

    public enum HostError: Error, LocalizedError, Sendable {
        case missingCredentials
        case missingModel
        case invalidAPIURL
        case emptyPrompt
        case emptyResponse
        case runtimeFailure(String)

        public var errorDescription: String? {
            switch self {
            case .missingCredentials: "Add an OpenAI API key in Agent settings."
            case .missingModel: "Choose a model in Agent settings."
            case .invalidAPIURL: "Enter a valid API URL in Agent settings."
            case .emptyPrompt: "Describe what the agent should create."
            case .emptyResponse: "The model did not return a response. Try again."
            case .runtimeFailure(let message): message
            }
        }
    }

    private actor ResponseSnapshot {
        var text = ""
        var outcome: NativeAgentLoopOutcome?
        var events: [AgentSessionEvent] = []
        func update(_ value: String) { text = value }
        func finish(_ value: NativeAgentLoopOutcome) { outcome = value }

        func record(_ observation: RuntimeResponseObservation, sessionID: String) {
            switch observation {
            case .toolCall(let request):
                events.append(AgentSessionEvent(
                    agentId: SloppyRuntimeHost.agentID,
                    sessionId: sessionID,
                    type: .toolCall,
                    toolCall: AgentToolCallEvent(tool: request.tool, arguments: request.arguments)
                ))
            case .toolResult(let result):
                events.append(AgentSessionEvent(
                    agentId: SloppyRuntimeHost.agentID,
                    sessionId: sessionID,
                    type: .toolResult,
                    toolResult: AgentToolResultEvent(
                        tool: result.tool,
                        ok: result.ok,
                        data: result.data,
                        error: result.error
                    )
                ))
            case .thinking, .usage:
                break
            }
        }
    }

    private let runtime: RuntimeSystem
    private var modelID: String?
    private var configuredKey: String?

    public init() {
        runtime = SloppyRuntimeBootstrap.makeSystem(
            modelProvider: nil,
            memoryStore: InMemoryMemoryStore(),
            configuration: SloppyRuntimeConfiguration()
        )
    }

    public func configureOpenAI(apiKey: String, model: String, apiURL: String = "https://api.openai.com/v1") async throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw HostError.missingCredentials }
        let rawModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawModel.isEmpty else { throw HostError.missingModel }
        guard let baseURL = URL(string: apiURL), baseURL.host != nil else { throw HostError.invalidAPIURL }
        let selectedModel = rawModel.hasPrefix("openai-api:") ? rawModel : "openai-api:\(rawModel)"
        if modelID == selectedModel, configuredKey == key { return }
        let provider = OpenAIModelProvider(
            supportedModels: [selectedModel],
            settings: .init(apiKey: { key }, baseURL: baseURL),
            tools: SloppyWorkspaceToolExecutor.modelTools
        )
        await runtime.updateModelProvider(modelProvider: provider, defaultModel: selectedModel)
        modelID = selectedModel
        configuredKey = key
    }

    public func configureCodex(
        tokenProvider: @escaping @Sendable () -> String,
        accountID: String?,
        model: String,
        refreshIfNeeded: @escaping @Sendable () async throws -> Void,
        refreshAfterInvalidToken: @escaping @Sendable () async throws -> Void
    ) async throws {
        let token = tokenProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw HostError.missingCredentials }
        let rawModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawModel.isEmpty else { throw HostError.missingModel }
        let selectedModel = rawModel.hasPrefix("openai-api:") ? rawModel : "openai-api:\(rawModel)"
        if modelID == selectedModel, configuredKey == token { return }
        let provider = OpenAIModelProvider(
            supportedModels: [selectedModel],
            settings: .init(
                apiKey: tokenProvider,
                accountId: accountID,
                refreshTokenIfNeeded: refreshIfNeeded,
                refreshTokenAfterInvalidToken: refreshAfterInvalidToken,
                useOpenAICodexOAuthPath: true
            ),
            tools: SloppyWorkspaceToolExecutor.modelTools
        )
        await runtime.updateModelProvider(modelProvider: provider, defaultModel: selectedModel)
        modelID = selectedModel
        configuredKey = token
    }

    /// Sends a user turn through Sloppy's native loop. `onText` receives full text snapshots.
    public func send(
        prompt: String,
        sessionID: String,
        workspaceURL: URL,
        build: @escaping @Sendable () async -> SloppyBuildResult,
        onText: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        let content = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw HostError.emptyPrompt }
        guard let modelID else { throw HostError.missingCredentials }

        let (sessionStore, storedSessionID) = try await prepareSession(
            channelID: sessionID,
            workspaceURL: workspaceURL
        )
        try sessionStore.appendEvents(agentID: Self.agentID, sessionID: storedSessionID, events: [
            AgentSessionEvent(
                agentId: Self.agentID,
                sessionId: storedSessionID,
                type: .message,
                message: AgentSessionMessage(
                    role: .user,
                    segments: [AgentMessageSegment(kind: .text, text: content)],
                    userId: "user"
                )
            )
        ])
        let workspace = SloppyWorkspaceToolExecutor(rootURL: workspaceURL, build: build)
        await runtime.setChannelBootstrap(
            channelId: sessionID,
            content: "You are an AdaScript game creation agent. This is a portable AdaScript project, not a SwiftPM project. Read .ada/project.json for its configuration; edit Sources/*.ada and Assets/Scenes/*.ascn using files.list, files.read, and files.write. Keep changes inside the project. Use editor.build after changes; fix errors it reports before finishing. Summarize the files you changed and the build result."
        )
        let snapshot = ResponseSnapshot()
        _ = await runtime.postMessage(
            channelId: sessionID,
            request: ChannelMessageRequest(userId: "user", content: content, model: modelID),
            onResponseChunk: { text in
                await snapshot.update(text)
                await onText(text)
                return true
            },
            toolInvoker: { request in await workspace.invoke(request) },
            observationHandler: { observation in
                await snapshot.record(observation, sessionID: storedSessionID)
            },
            nativeLoopConfig: NativeAgentLoopConfig(maxToolRounds: 20),
            nativeLoopOutcomeHandler: { outcome in await snapshot.finish(outcome) }
        )
        let toolEvents = await snapshot.events
        if !toolEvents.isEmpty {
            try sessionStore.appendEvents(agentID: Self.agentID, sessionID: storedSessionID, events: toolEvents)
        }
        if let outcome = await snapshot.outcome,
           !outcome.finishedNaturally || outcome.turnExitReason == .fallbackNoModel {
            let message = outcome.lastAssistantText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw HostError.runtimeFailure(message.isEmpty ? outcome.turnExitReason.rawValue : message)
        }
        let result = await snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw HostError.emptyResponse }
        try sessionStore.appendEvents(agentID: Self.agentID, sessionID: storedSessionID, events: [
            AgentSessionEvent(
                agentId: Self.agentID,
                sessionId: storedSessionID,
                type: .message,
                message: AgentSessionMessage(
                    role: .assistant,
                    segments: [AgentMessageSegment(kind: .text, text: result)]
                )
            )
        ])
        return result
    }

    /// Reads persisted conversation turns for a mobile project without creating a new session.
    public func messages(workspaceURL: URL) throws -> [SloppyChatMessage] {
        let agentsRoot = workspaceURL.appendingPathComponent(".ada/workspace/agents", isDirectory: true)
        let agentDirectory = agentsRoot.appendingPathComponent(Self.agentID, isDirectory: true)
        guard FileManager.default.fileExists(atPath: agentDirectory.path) else { return [] }
        let store = AgentSessionFileStore(agentsRootURL: agentsRoot)
        guard let summary = try store.listSessions(agentID: Self.agentID, limit: 1).first else { return [] }
        let detail = try store.loadSession(agentID: Self.agentID, sessionID: summary.id)
        return detail.events.compactMap { event in
            guard let message = event.message else { return nil }
            let role: SloppyChatMessage.Role
            switch message.role {
            case .user: role = .user
            case .assistant: role = .assistant
            case .system: return nil
            }
            let text = message.segments.compactMap(\.text).joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return SloppyChatMessage(id: event.id, role: role, text: text, createdAt: event.createdAt)
        }
    }

    private func prepareSession(channelID: String, workspaceURL: URL) async throws -> (AgentSessionFileStore, String) {
        let agentsRoot = workspaceURL.appendingPathComponent(".ada/workspace/agents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: agentsRoot.appendingPathComponent(Self.agentID, isDirectory: true),
            withIntermediateDirectories: true
        )
        let store = AgentSessionFileStore(agentsRootURL: agentsRoot)
        let summaries = try store.listSessions(agentID: Self.agentID, limit: 1)
        let summary = try summaries.first ?? store.createSession(
            agentID: Self.agentID,
            request: AgentSessionCreateRequest(title: "Mobile game", projectId: channelID)
        )
        let hasLiveSession = await runtime.hasCachedChannelSession(channelId: channelID)
        if !hasLiveSession {
            let detail = try store.loadSession(agentID: Self.agentID, sessionID: summary.id)
            let transcript = AgentSessionTranscriptBuilder.buildRecoveryTranscript(current: detail)
            if AgentSessionTranscriptBuilder.hasRecoverableEntries(transcript) {
                await runtime.setChannelRecoveryTranscript(channelId: channelID, transcript: transcript)
            }
        }
        return (store, summary.id)
    }
}
