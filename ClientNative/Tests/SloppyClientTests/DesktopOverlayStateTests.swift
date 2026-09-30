import Foundation
import SloppyClientCore
import Testing
@testable import SloppyClient

#if os(macOS)
@Suite("Desktop overlay state")
@MainActor
struct DesktopOverlayStateTests {
    @Test func startingAndUpdatingAgentWorkKeepsNotchCollapsed() {
        let state = SloppyDesktopOverlayState()

        state.setActiveAgentRuns([run(stage: .thinking)])
        #expect(state.activityCount == 1)
        #expect(state.mascotState == .thinking)
        #expect(!state.isExpanded)
        #expect(state.activityRevealToken == 0)

        state.setActiveAgentRuns([run(stage: .searching)])
        state.setActiveAgentRuns([run(stage: .responding)])
        state.setActiveAgentRuns([])
        state.setActiveAgentRuns([run(stage: .thinking)])
        #expect(!state.isExpanded)
        #expect(state.activityRevealToken == 0)
    }

    @Test func startingTaskAndAgentWorkKeepsNotchCollapsed() {
        let state = SloppyDesktopOverlayState()

        state.setActiveTasks([task(status: "in_progress")])
        state.setActiveAgentRuns([run(stage: .thinking)])
        #expect(state.activityCount == 2)
        #expect(!state.isExpanded)
        #expect(state.activityRevealToken == 0)
    }

    @Test func workUpdatesPreserveManualExpansion() {
        let state = SloppyDesktopOverlayState()
        state.toggleExpanded()

        state.setActiveAgentRuns([run(stage: .thinking)])
        state.setActiveTasks([task(status: "in_progress")])
        #expect(state.isExpanded)
        #expect(state.activityRevealToken == 0)
    }

    @Test func agentInputAndErrorsRevealOncePerTransition() {
        let state = SloppyDesktopOverlayState()
        state.setActiveAgentRuns([run(stage: .thinking)])

        state.setActiveAgentRuns([run(stage: .paused, needsInput: true)])
        #expect(state.isExpanded)
        #expect(state.activityRevealToken == 1)

        state.setExpanded(false)
        state.setActiveAgentRuns([run(stage: .paused, needsInput: true, details: "Updated prompt")])
        #expect(!state.isExpanded)
        #expect(state.activityRevealToken == 1)

        state.setActiveAgentRuns([run(stage: .thinking)])
        #expect(!state.isExpanded)
        state.setActiveAgentRuns([run(stage: .interrupted)])
        #expect(state.isExpanded)
        #expect(state.activityRevealToken == 2)

        state.setExpanded(false)
        state.setActiveAgentRuns([run(stage: .interrupted, details: "Updated error")])
        #expect(!state.isExpanded)
        #expect(state.activityRevealToken == 2)
    }

    @Test func taskInputAndErrorsRevealOncePerTransition() {
        let state = SloppyDesktopOverlayState()
        state.setActiveTasks([task(status: "in_progress")])

        state.setActiveTasks([task(status: "waiting_input")])
        #expect(state.isExpanded)
        #expect(state.activityRevealToken == 1)

        state.setExpanded(false)
        state.setActiveTasks([task(status: "pending_approval")])
        #expect(!state.isExpanded)
        #expect(state.activityRevealToken == 1)

        state.setActiveTasks([task(status: "blocked")])
        #expect(state.isExpanded)
        #expect(state.activityRevealToken == 2)

        state.setExpanded(false)
        state.setActiveTasks([task(status: "blocked")])
        state.setActiveTasks([task(status: "in_progress")])
        #expect(!state.isExpanded)
        #expect(state.activityRevealToken == 2)
    }

    private func run(
        stage: ChatRunStage,
        needsInput: Bool = false,
        details: String? = nil
    ) -> SloppyDesktopAgentRun {
        SloppyDesktopAgentRun(
            id: "agent/session",
            agentID: "agent",
            sessionID: "session",
            sessionTitle: "Test chat",
            agentName: "Test agent",
            stage: stage,
            statusLabel: stage.rawValue,
            statusDetails: details,
            needsInput: needsInput,
            inputPrompt: nil,
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func task(status: String) -> SloppyDesktopTask {
        SloppyDesktopTask(
            id: "project/task",
            projectID: "project",
            taskID: "task",
            title: "Test task",
            projectName: "Test project",
            status: .inProgress,
            rawStatus: status
        )
    }
}
#endif
