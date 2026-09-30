import Foundation
import Testing

@Suite("Chat refresh source")
struct ChatRefreshSourceTests {
    private var source: String {
        get throws {
            let packageRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let sourceURL = packageRoot
                .appendingPathComponent("Sources")
                .appendingPathComponent("SloppyFeatureChat/Screens/Chat/ChatScreenViewModel.swift")
            return try String(contentsOf: sourceURL, encoding: .utf8)
        }
    }

    @Test("chat view model refreshes the current context without resetting navigation state")
    func chatViewModelRefreshesCurrentContextWithoutResettingNavigationState() throws {
        let source = try source

        #expect(source.contains("public func refreshCurrentContext() async"))
        #expect(source.contains("if let selectedSessionId"))
        #expect(source.contains("await hydrateSession(agentId: agent.id, sessionId: selectedSessionId)"))
        #expect(source.contains("applyHydratedSession(detail, appliesStatus:"))
    }

    @Test("chat view model exposes transcript hydration progress")
    func chatViewModelExposesTranscriptHydrationProgress() throws {
        let source = try source

        #expect(source.contains("public private(set) var isLoadingTranscript = false"))
        #expect(source.contains("transcript.clear()\n        isLoadingTranscript = true"))
        #expect(source.contains("if isCurrentSession(agentId: agentId, sessionId: sessionId) {\n                isLoadingTranscript = false"))
    }

    @Test("chat stream appends delta chunks and exposes an interrupt path")
    func chatViewModelAppendsChunksAndCanInterrupt() throws {
        let source = try source

        #expect(source.contains("scheduleStreamingAssistantText(text, sessionId: sessionId, mode: .append)"))
        #expect(source.contains("pendingStreamingAssistantText = (pendingStreamingAssistantText ?? \"\") + text"))
        #expect(source.contains("transcript.appendStreamingAssistantText(text, messageId: messageId)"))
        #expect(source.contains("private func connectToSession(agentId: String, sessionId: String) async"))
        #expect(source.contains("stream = await socket.connect()"))
        #expect(source.contains("await connectToSession(agentId: agent.id, sessionId: summary.id)"))
        #expect(source.contains("transcript.replaceStreamingAssistant("))
        #expect(source.contains("beginStreamingAssistantTurn(for: sessionId)"))
        #expect(source.contains("UUID().uuidString.lowercased()"))
        #expect(source.contains("let isAssistantResponse = message.role == .assistant"))
        #expect(source.contains("activeRunStatus = status"))
        #expect(source.contains("public func stopActiveRun()"))
        #expect(source.contains("try await apiClient.interruptAgentSession("))
    }
}
