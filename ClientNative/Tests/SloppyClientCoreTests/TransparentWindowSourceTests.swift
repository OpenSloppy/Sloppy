import Foundation
import Testing

@Suite("Transparent window source")
struct TransparentWindowSourceTests {
    private func source(_ path: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: packageRoot.appendingPathComponent(path), encoding: .utf8)
    }

    @Test("app scene clears the system window background")
    func appSceneClearsSystemWindowBackground() throws {
        let appSource = try source("Sources/SloppyClient/App/SloppyClientApp.swift")

        #expect(appSource.contains(".containerBackground(.clear, for: .window)"))
        #expect(appSource.contains(".modifier(MainWindowChromeModifier())"))
        #expect(appSource.contains("toolbarBackgroundVisibility(.hidden, for: .windowToolbar)"))
        #expect(appSource.contains("toolbarBackground(.hidden, for: .windowToolbar)"))
    }

    @Test("root shell installs the transparent window bridge")
    func rootShellInstallsTransparentWindowBridge() throws {
        let rootShell = try source("Sources/SloppyClient/Root/RootShellView.swift")

        #expect(rootShell.contains("TransparentWindowConfigurationView { window in"))
        #expect(rootShell.contains("WindowDragHandleStrip(height:"))
        #expect(rootShell.contains("max(0, safeAreaInsets.top)"))
        #expect(rootShell.contains(".allowsHitTesting(false)"))
        #expect(!rootShell.contains("WindowDragHandleStrip(height: 36)"))
    }

    @Test("window bridge reapplies transparent chrome after SwiftUI installs its toolbar")
    func windowBridgeReappliesTransparentChrome() throws {
        let overlay = try source("Sources/SloppyClient/Overlays/SloppyDesktopOverlay.swift")

        #expect(overlay.contains("let isNewWindow = self.window !== window"))
        #expect(overlay.contains("configureTransparentWindow(window)\n        guard isNewWindow else { return }"))
        #expect(overlay.contains("name: NSWindow.didUpdateNotification"))
        #expect(overlay.contains("onWindowAvailable(window)"))
    }

    @Test("desktop overlay configures a non-opaque titlebar-transparent window")
    func desktopOverlayConfiguresNonOpaqueTransparentTitlebarWindow() throws {
        let overlay = try source("Sources/SloppyClient/Overlays/SloppyDesktopOverlay.swift")

        #expect(overlay.contains("window.isOpaque = false"))
        #expect(overlay.contains("window.backgroundColor = .clear"))
        #expect(overlay.contains("window.titlebarAppearsTransparent = true"))
        #expect(overlay.contains("window.isMovableByWindowBackground = false"))
    }

    @Test("desktop overlay opts into unified toolbar chrome")
    func desktopOverlayOptsIntoUnifiedToolbarChrome() throws {
        let overlay = try source("Sources/SloppyClient/Overlays/SloppyDesktopOverlay.swift")

        #expect(overlay.contains("window.titlebarSeparatorStyle = .none"))
        #expect(overlay.contains("window.toolbarStyle = .unified"))
    }

    @Test("desktop overlay creates an always-on interactive notch panel")
    func desktopOverlayCreatesAnAlwaysOnInteractiveNotchPanel() throws {
        let overlay = try source("Sources/SloppyClient/Overlays/SloppyDesktopOverlay.swift")
        let pet = try source("Sources/SloppyClient/Overlays/SloppyNotchPetView.swift")
        let hero = try source("Sources/SloppyClient/Overlays/SloppyDesktopNotchHeroView.swift")
        let rootModel = try source("Sources/SloppyClient/Root/RootShellViewModel.swift")

        #expect(overlay.contains("SloppyNotchPanel"))
        #expect(overlay.contains("SloppyDesktopNotchView"))
        #expect(overlay.contains("onClick: { _ = state.openMascotDestination() }"))
        #expect(!overlay.contains("SloppyAssets.projectLogo"))
        #expect(pet.contains("NSViewRepresentable"))
        #expect(pet.contains("SKView"))
        #expect(pet.contains("pointerPositionInScene()"))
        #expect(pet.contains("RunLoop.main.add(timer, forMode: .common)"))
        #expect(pet.contains("presentationScale"))
        #expect(pet.contains("enum SloppyNotchPetState"))
        #expect(pet.contains("case needsInput"))
        #expect(pet.contains("case error"))
        #expect(pet.contains("handlePointerMove"))
        #expect(pet.contains("handlePoke"))
        #expect(pet.contains("onClick?()"))
        #expect(pet.contains("case happy"))
        #expect(pet.contains("case angry"))
        #expect(!pet.contains("truncatingRemainder(dividingBy: 18)"))
        #expect(overlay.contains("detail.pendingInputRequest"))
        #expect(overlay.contains("stage: status.stage"))
        #expect(overlay.contains("task.status == \"waiting_input\""))
        #expect(overlay.contains("task.status == \"pending_approval\""))
        #expect(overlay.contains("task.status == \"blocked\""))
        #expect(overlay.contains("var mascotState: SloppyNotchPetState"))
        #expect(overlay.contains("expandedHeroHeight: CGFloat = 104"))
        #expect(overlay.contains("@Namespace private var petTransitionNamespace"))
        #expect(overlay.contains("@State private var isPetExpanded = false"))
        #expect(overlay.contains("withAnimation(.spring("))
        #expect(overlay.contains("id: \"notch-mascot\""))
        #expect(overlay.contains("showsMascot: isPetExpanded"))
        #expect(overlay.contains("ScrollView(.vertical)"))
        #expect(overlay.contains("expandedSections"))
        #expect(hero.contains("presentationScale: 3.4"))
        #expect(hero.contains("state: state.mascotState"))
        #expect(!hero.contains(".allowsHitTesting(false)"))
        #expect(hero.contains("if showsMascot"))
        #expect(hero.contains("matchedGeometryEffect("))
        #expect(hero.contains("Your approval is needed"))
        #expect(hero.contains("Watching your workspace"))
        #expect(overlay.contains("panel.level = .statusBar"))
        #expect(overlay.contains(".canJoinAllSpaces"))
        #expect(!overlay.contains("private func approvalContent"))
        #expect(overlay.contains("DeepLink.session(agentId: run.agentID, sessionId: run.sessionID).url"))
        #expect(overlay.contains("DeepLink.task(projectId: task.projectID, taskId: task.taskID).url"))
        #expect(overlay.contains(".onHover(perform: handleHoverChange)"))
        #expect(overlay.contains("state.setExpanded(true)"))
        #expect(overlay.contains("state.setExpanded(false)"))
        #expect(rootModel.contains("desktopOverlay.start(settings: settings)"))
    }

    @Test("desktop overlay can expand while Sloppy Client is active")
    func desktopOverlayCanExpandWhileSloppyClientIsActive() throws {
        let overlay = try source("Sources/SloppyClient/Overlays/SloppyDesktopOverlay.swift")

        #expect(!overlay.contains("NSApp.isActive"))
        #expect(!overlay.contains("NSApplication.didBecomeActiveNotification"))
        #expect(overlay.contains("self.position(panel: panel, animated: true)"))
    }

    @Test("desktop overlay shows typed active agent run status")
    func desktopOverlayShowsTypedActiveAgentRunStatus() throws {
        let overlay = try source("Sources/SloppyClient/Overlays/SloppyDesktopOverlay.swift")
        let rootModel = try source("Sources/SloppyClient/Root/RootShellViewModel.swift")

        #expect(overlay.contains("status.stage.isWorking"))
        #expect(overlay.contains("Agents working"))
        #expect(overlay.contains("state.setActiveAgentRuns(activity.activeRuns)"))
        #expect(overlay.contains("apiClient.fetchAgentSessions("))
        #expect(rootModel.contains("desktopOverlay.start(settings: settings, baseURL: url)"))
    }

    @Test("desktop overlay collapses active details after three seconds")
    func desktopOverlayCollapsesActiveDetailsAfterThreeSeconds() throws {
        let overlay = try source("Sources/SloppyClient/Overlays/SloppyDesktopOverlay.swift")

        #expect(overlay.contains(".task(id: state.activityRevealToken)"))
        #expect(overlay.contains("Task.sleep(for: .seconds(3))"))
        #expect(overlay.contains("while isPointerInsidePanel()"))
        #expect(overlay.contains("state.setExpanded(false)"))
        #expect(overlay.contains("activityRevealToken &+= 1"))
    }

    @Test("desktop overlay opens the selected agent session in the main window")
    func desktopOverlayOpensSelectedAgentSessionInMainWindow() throws {
        let overlay = try source("Sources/SloppyClient/Overlays/SloppyDesktopOverlay.swift")
        let rootModel = try source("Sources/SloppyClient/Root/RootShellViewModel.swift")
        let rootView = try source("Sources/SloppyClient/Root/RootShellView.swift")

        #expect(overlay.contains("state.openAgentRun(run)"))
        #expect(overlay.contains("arrow.up.forward.app"))
        #expect(overlay.contains("window?.makeKeyAndOrderFront(nil)"))
        #expect(rootModel.contains(".session(agentId: agentID, sessionId: sessionID)"))
        #expect(rootModel.contains("desktopOverlay.presentMainWindow()"))
        #expect(rootView.contains("openWindow(id: \"main\")"))
    }

    @Test("desktop overlay shows three recent chats and sends an inline prompt")
    func desktopOverlayShowsRecentChatsAndSendsInlinePrompt() throws {
        let overlay = try source("Sources/SloppyClient/Overlays/SloppyDesktopOverlay.swift")

        #expect(overlay.contains(".prefix(3)"))
        #expect(overlay.contains("Label(\"Recent chats\""))
        #expect(overlay.contains("state.setRecentChats(activity.recentChats)"))
        #expect(overlay.contains("state.togglePromptComposer(for: chat)"))
        #expect(overlay.contains("TextField("))
        #expect(overlay.contains("paperplane.fill"))
        #expect(overlay.contains("apiClient.postSessionMessage("))
        #expect(overlay.contains("state.submitPrompt(to: chat)"))
        #expect(overlay.contains("state.openRecentChat(chat)"))
    }

    @Test("desktop overlay creates an agent task in the selected project")
    func desktopOverlayCreatesAgentTaskInSelectedProject() throws {
        let overlay = try source("Sources/SloppyClient/Overlays/SloppyDesktopOverlay.swift")

        #expect(overlay.contains("Picker("))
        #expect(overlay.contains("New task for agent…"))
        #expect(overlay.contains("state.setProjects(projects.map"))
        #expect(overlay.contains("apiClient.createProjectTask("))
        #expect(overlay.contains("status: \"ready\""))
        #expect(overlay.contains("actorId: project.actorID"))
        #expect(overlay.contains("state.submitTask()"))
    }

    @Test("desktop overlay ignores transient hover exits caused by panel resizing")
    func desktopOverlayIgnoresTransientHoverExits() throws {
        let overlay = try source("Sources/SloppyClient/Overlays/SloppyDesktopOverlay.swift")

        #expect(overlay.contains("isPointerInsidePanel"))
        #expect(overlay.contains("Task.sleep(for: .milliseconds(120))"))
        #expect(overlay.contains("guard !isPointerInsidePanel() else { continue }"))
        #expect(overlay.contains("hoverCollapseTask?.cancel()"))
    }

    @Test("desktop overlay keeps the inline prompt open when the pointer leaves")
    func desktopOverlayKeepsInlinePromptOpenWhenPointerLeaves() throws {
        let overlay = try source("Sources/SloppyClient/Overlays/SloppyDesktopOverlay.swift")

        #expect(overlay.contains("state.selectedRecentChatID == nil"))
        #expect(overlay.contains("!state.hasTaskDraft"))
        #expect(overlay.contains("!isTaskComposerFocused"))
    }

    @Test("desktop overlay uses compact panel dimensions")
    func desktopOverlayUsesCompactPanelDimensions() throws {
        let overlay = try source("Sources/SloppyClient/Overlays/SloppyDesktopOverlay.swift")

        #expect(overlay.contains("collapsedSize = CGSize(width: 76, height: 28)"))
        #expect(overlay.contains("expandedSize = CGSize(width: 340, height: 148)"))
        #expect(overlay.contains("wideWidth: CGFloat = 480"))
    }
}
