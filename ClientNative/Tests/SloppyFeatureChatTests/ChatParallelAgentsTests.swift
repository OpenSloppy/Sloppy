import Foundation
import Testing
import SloppyClientCore
@testable import SloppyFeatureChat

@Suite("Parallel chat agents")
@MainActor
struct ChatParallelAgentsTests {
    @Test("links are deduplicated and isolated to the supplied parent history")
    func links() {
        let event = ChatEventEnvelope(id: "one", type: "sub_session", subSession: .init(childSessionId: "child", title: "Review"))
        let empty = ChatEventEnvelope(id: "empty", type: "sub_session", subSession: .init(childSessionId: "", title: ""))
        #expect(ChatParallelAgentsViewModel.links(in: [event, event, empty]).map(\.childSessionId) == ["child"])
        #expect(ChatParallelAgentsViewModel.links(in: []).isEmpty)
    }

    @Test("only working typed stages advertise active work", arguments: [ChatRunStage.thinking, .searching, .responding, .paused, .done, .interrupted])
    func status(stage: ChatRunStage) {
        let summary = ChatSessionSummary(id: "child", agentId: "agent", title: "Review")
        let detail = ChatSessionDetail(summary: summary, events: [
            ChatEventEnvelope(id: "status", type: "run_status", runStatus: .init(stage: stage, label: "State")),
        ])
        let agent = ChatParallelAgent(detail: detail)
        #expect(agent.isWorking == stage.isWorking)
        #expect(agent.summary.id == "child")
        #expect(agent.status == (stage.isWorking ? "State" : stage.rawValue.capitalized))
    }

    @Test("unavailable status is not mistaken for working")
    func unknownStatus() {
        let agent = ChatParallelAgent(detail: .init(summary: .init(id: "child", agentId: "agent", title: "Review")))
        #expect(!agent.isWorking)
        #expect(agent.status == "Status unavailable")
    }

    @Test("pending input overrides working status")
    func pendingInput() {
        let request = ChatPlanInputRequest(id: "input", questions: [])
        let detail = ChatSessionDetail(summary: .init(id: "child", agentId: "agent", title: "Review"), events: [
            .init(id: "run", type: "run_status", runStatus: .init(stage: .thinking, label: "Thinking")),
            .init(id: "input", type: "input_request", inputRequest: request),
        ])
        #expect(!ChatParallelAgent(detail: detail).isWorking)
        #expect(ChatParallelAgent(detail: detail).status == "Waiting for input")
    }
}
