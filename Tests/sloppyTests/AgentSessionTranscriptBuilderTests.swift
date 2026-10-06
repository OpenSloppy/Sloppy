import AnyLanguageModel
import Foundation
import Testing
import SloppyRuntime
@testable import Protocols
@testable import sloppy

@Test
func transcriptBuilderPreservesMessageOrder() {
    let detail = makeTranscriptBuilderDetail(events: [
        messageEvent(role: .user, text: "First"),
        messageEvent(role: .assistant, text: "Second"),
        messageEvent(role: .user, text: "Third")
    ])

    let transcript = AgentSessionTranscriptBuilder.buildRecoveryTranscript(current: detail)

    #expect(transcript.count == 3)
    #expect(promptText(transcript[0]) == "First")
    #expect(responseText(transcript[1]) == "Second")
    #expect(promptText(transcript[2]) == "Third")
}

@Test
func transcriptBuilderPairsToolCallsAndResultsByOrderAndToolName() {
    let callEventID = "call-event-1"
    let detail = makeTranscriptBuilderDetail(events: [
        toolCallEvent(id: callEventID, tool: "files.read", arguments: ["path": Protocols.JSONValue.string("README.md")]),
        toolResultEvent(tool: "files.read", ok: true, data: Protocols.JSONValue.object(["content": .string("hello")]))
    ])

    let transcript = AgentSessionTranscriptBuilder.buildRecoveryTranscript(current: detail)

    #expect(transcript.count == 2)
    let callID = toolCallID(transcript[0])
    #expect(callID == "session-event-\(callEventID)")
    #expect(toolOutputID(transcript[1]) == callID)
    #expect(toolOutputText(transcript[1])?.contains("\"content\":\"hello\"") == true)
}

@Test
func transcriptBuilderIgnoresInterruptedStatusWithoutInventingAssistantResponse() {
    let detail = makeTranscriptBuilderDetail(events: [
        messageEvent(role: .user, text: "Keep going"),
        AgentSessionEvent(
            agentId: "agent",
            sessionId: "session",
            type: .runStatus,
            runStatus: AgentRunStatusEvent(stage: .interrupted, label: "Interrupted")
        )
    ])

    let transcript = AgentSessionTranscriptBuilder.buildRecoveryTranscript(current: detail)

    #expect(transcript.count == 1)
    #expect(promptText(transcript[0]) == "Keep going")
}

@Test
func transcriptBuilderIncludesAttachmentReferencesInUserPrompt() {
    let detail = makeTranscriptBuilderDetail(events: [
        AgentSessionEvent(
            agentId: "agent",
            sessionId: "session",
            type: .message,
            message: AgentSessionMessage(
                role: .user,
                segments: [
                    .init(kind: .text, text: "Review this"),
                    .init(kind: .attachment, attachment: AgentAttachment(
                        id: "asset-1",
                        name: "trace.log",
                        mimeType: "text/plain",
                        sizeBytes: 42,
                        relativePath: "assets/trace.log"
                    ))
                ]
            )
        )
    ])

    let transcript = AgentSessionTranscriptBuilder.buildRecoveryTranscript(current: detail)
    let text = promptText(transcript[0]) ?? ""

    #expect(text.contains("Review this"))
    #expect(text.contains("[Attachment: name: trace.log, type: text/plain, size: 42 bytes, path: assets/trace.log]"))
}

@Test
func transcriptBuilderRetainsInterruptedToolCallsWithUnknownResult() {
    let orphanCallEventID = "orphan-call-event"
    let detail = makeTranscriptBuilderDetail(events: [
        messageEvent(role: .user, text: "Before"),
        toolCallEvent(id: orphanCallEventID, tool: "agents.delegate_task", arguments: ["goal": .string("Do work")]),
        messageEvent(role: .user, text: "After")
    ])

    let transcript = AgentSessionTranscriptBuilder.buildRecoveryTranscript(current: detail)

    #expect(transcript.count == 4)
    #expect(promptText(transcript[0]) == "Before")
    #expect(promptText(transcript[2]) == "After")
    #expect(transcript.contains { entry in
        if case .toolCalls = entry { return true }
        return false
    })
    #expect(toolOutputText(transcript[3])?.contains("tool_execution_interrupted") == true)
}

@Test
func transcriptBuilderKeepsMatchedToolCallsWhenLaterCallsAreUnmatched() {
    let matchedCallEventID = "matched-call-event"
    let orphanCallEventID = "orphan-call-event"
    let detail = makeTranscriptBuilderDetail(events: [
        toolCallEvent(id: matchedCallEventID, tool: "files.read", arguments: ["path": .string("README.md")]),
        toolResultEvent(tool: "files.read", ok: true, data: .object(["content": .string("ok")])),
        toolCallEvent(id: orphanCallEventID, tool: "agents.delegate_task", arguments: ["goal": .string("Do work")])
    ])

    let transcript = AgentSessionTranscriptBuilder.buildRecoveryTranscript(current: detail)

    #expect(transcript.count == 4)
    let callID = toolCallID(transcript[0])
    #expect(callID == "session-event-\(matchedCallEventID)")
    #expect(toolOutputID(transcript[1]) == callID)
}

private func makeTranscriptBuilderDetail(events: [AgentSessionEvent]) -> AgentSessionDetail {
    AgentSessionDetail(
        summary: AgentSessionSummary(
            id: "session",
            agentId: "agent",
            title: "Session",
            messageCount: events.count
        ),
        events: events
    )
}

private func messageEvent(role: AgentMessageRole, text: String) -> AgentSessionEvent {
    AgentSessionEvent(
        agentId: "agent",
        sessionId: "session",
        type: .message,
        message: AgentSessionMessage(role: role, segments: [.init(kind: .text, text: text)])
    )
}

private func toolCallEvent(id: String, tool: String, arguments: [String: Protocols.JSONValue]) -> AgentSessionEvent {
    AgentSessionEvent(
        id: id,
        agentId: "agent",
        sessionId: "session",
        type: .toolCall,
        toolCall: AgentToolCallEvent(tool: tool, arguments: arguments)
    )
}

private func toolResultEvent(tool: String, ok: Bool, data: Protocols.JSONValue?) -> AgentSessionEvent {
    AgentSessionEvent(
        agentId: "agent",
        sessionId: "session",
        type: .toolResult,
        toolResult: AgentToolResultEvent(tool: tool, ok: ok, data: data)
    )
}

private func promptText(_ entry: Transcript.Entry) -> String? {
    guard case .prompt(let prompt) = entry else {
        return nil
    }
    return text(from: prompt.segments)
}

private func responseText(_ entry: Transcript.Entry) -> String? {
    guard case .response(let response) = entry else {
        return nil
    }
    return text(from: response.segments)
}

private func toolCallID(_ entry: Transcript.Entry) -> String? {
    guard case .toolCalls(let calls) = entry else {
        return nil
    }
    return calls.first?.id
}

private func toolOutputID(_ entry: Transcript.Entry) -> String? {
    guard case .toolOutput(let output) = entry else {
        return nil
    }
    return output.id
}

private func toolOutputText(_ entry: Transcript.Entry) -> String? {
    guard case .toolOutput(let output) = entry else {
        return nil
    }
    return text(from: output.segments)
}

private func text(from segments: [Transcript.Segment]) -> String {
    segments.compactMap { segment -> String? in
        if case .text(let text) = segment {
            return text.content
        }
        return nil
    }.joined(separator: "\n")
}
