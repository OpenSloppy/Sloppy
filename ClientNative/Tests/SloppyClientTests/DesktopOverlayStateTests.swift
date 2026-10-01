import Foundation
import SloppyClientCore
import Testing
@testable import SloppyClient

#if os(macOS)
@Suite("Desktop overlay state")
@MainActor
struct DesktopOverlayStateTests {
    @Test func selectingChatKeepsNotchOpenAndPreservesProjectContext() {
        let state = SloppyDesktopOverlayState()
        let chat = chat(agentID: "agent-a", sessionID: "session", projectID: "project")

        state.openRecentChat(chat)

        #expect(state.isExpanded)
        #expect(state.selectedSection == .chats)
        #expect(state.selectedChat == chat)
        #expect(state.selectedRecentChatID == "agent-a/session")
        #expect(state.selectedChat?.sessionSummary.projectId == "project")
        #expect(state.activityRevealToken == 0)
    }

    @Test func recentChatRefreshDoesNotEvictTheOpenConversation() {
        let state = SloppyDesktopOverlayState()
        let opened = chat(agentID: "agent-a", sessionID: "old")
        state.setRecentChats([opened])
        state.openRecentChat(opened)

        state.setRecentChats([chat(agentID: "agent-b", sessionID: "new")])

        #expect(state.selectedChat == opened)
        #expect(state.isExpanded)
        state.backToChats()
        #expect(state.selectedChat == nil)
        #expect(state.selectedSection == .chats)
        #expect(state.recentChats.count == 1)
    }

    @Test func sectionNavigationAndCollapsingPreserveTheirIntendedSelection() {
        let state = SloppyDesktopOverlayState()
        state.openRecentChat(chat(agentID: "agent-a", sessionID: "session"))
        state.setExpanded(false)
        #expect(state.selectedChat != nil)
        state.setExpanded(true)
        #expect(state.selectedChat?.sessionID == "session")
        state.selectSection(.tasks)
        #expect(state.selectedChat == nil)
        #expect(state.selectedSection == .tasks)
        #expect(state.isExpanded)
    }

    @Test func clickingAnAgentRunOpensItsExactChatInsideTheNotch() {
        let state = SloppyDesktopOverlayState()
        state.openAgentRun(run(stage: .thinking))
        #expect(state.selectedChat?.agentID == "agent")
        #expect(state.selectedChat?.sessionID == "session")
        #expect(state.isExpanded)
        #expect(state.selectedSection == .chats)
    }

    @Test func sameSessionIDUnderDifferentAgentsDoesNotShareSelection() {
        let state = SloppyDesktopOverlayState()
        state.openRecentChat(chat(agentID: "agent-a", sessionID: "shared"))
        state.openRecentChat(chat(agentID: "agent-b", sessionID: "shared"))
        #expect(state.selectedRecentChatID == "agent-b/shared")
        #expect(state.selectedChat?.sessionSummary.agentId == "agent-b")
    }

    @Test func agentFacesUseTypedActivityAndDoNotGuessFromStatusText() {
        let state = SloppyDesktopOverlayState()
        state.setActiveAgentRuns([run(stage: .thinking, details: "Needs attention")])
        #expect(state.agentEmotion(for: "agent") == .thinking)
        state.setActiveAgentRuns([run(stage: .paused, needsInput: true)])
        #expect(state.agentEmotion(for: "agent") == .needsInput)
        state.setActiveAgentRuns([run(stage: .interrupted)])
        #expect(state.agentEmotion(for: "agent") == .error)
        #expect(state.agentEmotion(for: "other-agent") == .idle)
    }

    @Test func changingServerClearsItsChatAndAgentIdentities() {
        let state = SloppyDesktopOverlayState()
        state.setRecentChats([chat(agentID: "agent", sessionID: "session")])
        state.openRecentChat(state.recentChats[0])
        state.resetChatContext()
        #expect(state.selectedChat == nil)
        #expect(state.chatViewModel == nil)
        #expect(state.recentChats.isEmpty)
        #expect(state.teamAgents.isEmpty)
    }

    private func chat(agentID: String, sessionID: String, projectID: String? = nil) -> SloppyDesktopRecentChat {
        SloppyDesktopRecentChat(
            id: "\(agentID)/\(sessionID)", agentID: agentID, sessionID: sessionID,
            title: "Test chat", agentName: "Test agent", updatedAt: Date(timeIntervalSince1970: 0),
            projectID: projectID
        )
    }

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
