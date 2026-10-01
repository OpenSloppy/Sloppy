import Foundation
import Observation
import SloppyClientCore
import SloppyClientUI
import SloppyFeatureChat

#if os(macOS)
import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class SloppyDesktopOverlay {
    private let state = SloppyDesktopOverlayState()
    private weak var window: NSWindow?
    private var overlayPanel: SloppyNotchPanel?
    private var screenObserver: NSObjectProtocol?
    private var apiClient = SloppyAPIClient()
    private var closeBehavior: ClientWindowCloseBehavior = .keepProcess
    private var activityRefreshTask: Task<Void, Never>?
    private var panelResizeTask: Task<Void, Never>?
    private var agentRunCache: [String: SloppyDesktopAgentRunCacheEntry] = [:]
    var onOpenTask: (@MainActor (String, String) -> Void)?
    var onOpenSettings: (@MainActor (ClientSettingsDestination) -> Void)?

    func start(settings: ClientSettings, baseURL: URL? = nil) {
        closeBehavior = settings.windowCloseBehavior
        let resolvedBaseURL = baseURL ?? settings.baseURL
        if apiClient.baseURL != resolvedBaseURL {
            agentRunCache.removeAll()
            state.resetChatContext()
        }
        apiClient = SloppyAPIClient(baseURL: resolvedBaseURL)
        state.onOpenTask = { [weak self] task in
            self?.onOpenTask?(task.projectID, task.taskID)
        }
        state.onOpenDeepLink = { url in
            NSWorkspace.shared.open(url)
        }
        state.onMakeChatViewModel = { [weak self, apiClient, settings] in
            ChatScreenViewModel(
                apiClient: apiClient,
                cacheStore: ClientCacheStore(namespace: apiClient.endpoint.cacheNamespace),
                settings: settings,
                connectionMonitor: ConnectionMonitor(baseURL: apiClient.baseURL),
                restoresLastSession: false,
                onOpenSettings: { [weak self] destination in self?.onOpenSettings?(destination) }
            )
        }
        state.onCreateTask = { [weak self] project, title in
            guard let self else { return }
            _ = try await self.apiClient.createProjectTask(
                projectId: project.id,
                request: APIProjectTaskCreateRequest(
                    title: title,
                    status: "ready",
                    actorId: project.actorID
                )
            )
        }
        startActivityRefresh()
        ensureOverlayPanel()
        if let window {
            configureTransparentWindow(window)
        }
        applyCloseBehavior(settings.windowCloseBehavior)
    }

    func attach(window: NSWindow) {
        let isNewWindow = self.window !== window
        self.window = window
        configureTransparentWindow(window)
        guard isNewWindow else { return }
        if let overlayPanel {
            position(panel: overlayPanel, animated: false)
        }
        applyCloseBehavior(closeBehavior)
    }

    func applyCloseBehavior(_ behavior: ClientWindowCloseBehavior) {
        closeBehavior = behavior
    }

    func presentMainWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func updateToolApproval(_ notification: AppNotification) {
        state.apply(notification)
        overlayPanel?.orderFrontRegardless()
    }

    private func ensureOverlayPanel() {
        if let overlayPanel {
            position(panel: overlayPanel, animated: false)
            overlayPanel.orderFrontRegardless()
            return
        }

        let panel = SloppyNotchPanel(
            contentRect: NSRect(origin: .zero, size: SloppyDesktopNotchView.collapsedSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let hostingView = NSHostingView(
            rootView: SloppyDesktopNotchView(
                state: state,
                isPointerInsidePanel: { [weak panel] in
                    guard let panel else { return false }
                    return panel.frame.contains(NSEvent.mouseLocation)
                }
            )
        )
        // The panel owns its size. SwiftUI's intrinsic-size constraints must not
        // resize/recenter the window when the expanded content is inserted.
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        overlayPanel = panel
        state.onExpansionChanged = { [weak self] in
            guard let self, let panel = self.overlayPanel else { return }
            self.position(panel: panel, animated: true)
        }
        position(panel: panel, animated: false)
        panel.orderFrontRegardless()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let panel = self.overlayPanel else { return }
                self.position(panel: panel, animated: false)
            }
        }
    }

    private func position(panel: NSPanel, animated: Bool) {
        panelResizeTask?.cancel()
        guard let screen = window?.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let geometry = SloppyDesktopNotchGeometry(screen: screen)
        if state.notchGeometry != geometry {
            state.notchGeometry = geometry
        }
        let size = SloppyDesktopNotchView.size(for: state)
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.setFrame(frame, display: true)
            return
        }
        let initialFrame = panel.frame
        let expanding = state.isExpanded
        let duration = expanding ? 0.24 : 0.16
        // NSWindow's animator clamps overshoot, so interpolate the frame directly.
        // Starting from the current frame also keeps interrupted transitions continuous.
        panelResizeTask = Task { @MainActor [weak panel] in
            let start = CACurrentMediaTime()
            while !Task.isCancelled {
                guard let panel else { return }
                let time = min((CACurrentMediaTime() - start) / duration, 1)
                guard time < 1 else {
                    panel.setFrame(frame, display: true)
                    return
                }
                let remaining = time - 1
                let progress = expanding
                    ? 1 + 1.9 * remaining * remaining * remaining + 0.9 * remaining * remaining
                    : 1 + remaining * remaining * remaining
                let width = initialFrame.width + (frame.width - initialFrame.width) * progress
                let height = initialFrame.height + (frame.height - initialFrame.height) * progress
                panel.setFrame(NSRect(
                    x: screen.frame.midX - width / 2,
                    y: screen.frame.maxY - height,
                    width: width,
                    height: height
                ), display: false)
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
    }

    private func startActivityRefresh() {
        activityRefreshTask?.cancel()
        activityRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshActiveActivity()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func refreshActiveActivity() async {
        let endpoint = apiClient.endpoint
        async let projectsRequest = apiClient.fetchProjects()
        async let agentsRequest = apiClient.fetchAgents()

        let projects = try? await projectsRequest
        let agents = try? await agentsRequest
        guard !Task.isCancelled, apiClient.endpoint == endpoint else { return }

        if let projects {
            state.setProjects(projects.map {
                SloppyDesktopProject(
                    id: $0.id,
                    name: $0.name,
                    actorID: $0.actors?.first
                )
            })
            let activeTasks = projects.flatMap { project in
                (project.tasks ?? []).compactMap { task -> SloppyDesktopTask? in
                    let requiresInput = task.status == "waiting_input"
                        || task.status == "pending_approval"
                    let isError = task.status == "blocked"
                    guard task.normalizedKanbanColumnID == .inProgress
                        || task.normalizedKanbanColumnID == .needsReview
                        || requiresInput
                        || isError else { return nil }
                    return SloppyDesktopTask(
                        id: "\(project.id)/\(task.id)",
                        projectID: project.id,
                        taskID: task.id,
                        title: task.title,
                        projectName: project.name,
                        status: task.normalizedKanbanColumnID,
                        rawStatus: task.status,
                        agentID: task.claimedAgentId
                    )
                }
            }
            state.setActiveTasks(activeTasks)
        }
        if let agents {
            state.agents = agents
            state.agentPalettes = Dictionary(uniqueKeysWithValues: agents.compactMap { agent -> (String, String)? in
                guard let paletteID = agent.pet?.visual?.paletteId else { return nil }
                return (agent.id, paletteID)
            })
            let activity = await fetchAgentActivity(for: agents)
            guard !Task.isCancelled, apiClient.endpoint == endpoint else { return }
            state.setActiveAgentRuns(activity.activeRuns)
            state.setRecentChats(activity.recentChats)
        }
    }

    private func fetchAgentActivity(for agents: [APIAgentRecord]) async -> SloppyDesktopAgentActivity {
        let sessionsByAgent = await withTaskGroup(
            of: (APIAgentRecord, [ChatSessionSummary]).self,
            returning: [(APIAgentRecord, [ChatSessionSummary])].self
        ) { group in
            for agent in agents {
                group.addTask { [apiClient] in
                    let sessions = (try? await apiClient.fetchAgentSessions(
                        agentId: agent.id,
                        limit: 8
                    )) ?? []
                    return (agent, sessions)
                }
            }

            var result: [(APIAgentRecord, [ChatSessionSummary])] = []
            for await item in group {
                result.append(item)
            }
            return result
        }

        let recentChats = sessionsByAgent.flatMap { agent, sessions in
            sessions.map { session in
                SloppyDesktopRecentChat(
                    id: "\(agent.id)/\(session.id)",
                    agentID: agent.id,
                    sessionID: session.id,
                    title: session.title,
                    agentName: agent.displayName,
                    updatedAt: session.updatedAt,
                    projectID: session.projectId,
                    projectName: state.projects.first { $0.id == session.projectId }?.name,
                    taskID: session.taskId
                )
            }
        }
        .sorted { $0.updatedAt > $1.updatedAt }
        .prefix(24)

        let cachedRuns = agentRunCache
        let lookups = await withTaskGroup(
            of: SloppyDesktopAgentRunLookup.self,
            returning: [SloppyDesktopAgentRunLookup].self
        ) { group in
            for (agent, sessions) in sessionsByAgent {
                for session in sessions {
                    let cacheID = "\(agent.id)/\(session.id)"
                    group.addTask { [apiClient] in
                        if let cached = cachedRuns[cacheID], cached.updatedAt == session.updatedAt {
                            return SloppyDesktopAgentRunLookup(
                                id: cacheID,
                                updatedAt: session.updatedAt,
                                run: cached.run
                            )
                        }
                        guard let detail = try? await apiClient.fetchAgentSession(
                            agentId: agent.id,
                            sessionId: session.id
                        ),
                        let status = detail.latestRunStatus else {
                            return SloppyDesktopAgentRunLookup(
                                id: cacheID,
                                updatedAt: session.updatedAt,
                                run: nil
                            )
                        }
                        let inputRequest = detail.pendingInputRequest
                        let isRecentError = status.stage == .interrupted
                            && abs(Date().timeIntervalSince(session.updatedAt)) < 600
                        guard status.stage.isWorking || inputRequest != nil || isRecentError else {
                            return SloppyDesktopAgentRunLookup(
                                id: cacheID,
                                updatedAt: session.updatedAt,
                                run: nil
                            )
                        }
                        let inputPrompt = inputRequest?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                        let fallbackPrompt = inputRequest?.questions.first?.question
                        return SloppyDesktopAgentRunLookup(
                            id: cacheID,
                            updatedAt: session.updatedAt,
                            run: SloppyDesktopAgentRun(
                                id: cacheID,
                                agentID: agent.id,
                                sessionID: session.id,
                                sessionTitle: session.title,
                                agentName: agent.displayName,
                                stage: status.stage,
                                statusLabel: status.label,
                                statusDetails: status.details,
                                needsInput: inputRequest != nil,
                                inputPrompt: inputPrompt?.isEmpty == false ? inputPrompt : fallbackPrompt,
                                updatedAt: session.updatedAt
                            )
                        )
                    }
                }
            }

            var result: [SloppyDesktopAgentRunLookup] = []
            for await lookup in group {
                result.append(lookup)
            }
            return result
        }

        agentRunCache = Dictionary(uniqueKeysWithValues: lookups.map {
            ($0.id, SloppyDesktopAgentRunCacheEntry(updatedAt: $0.updatedAt, run: $0.run))
        })
        return SloppyDesktopAgentActivity(
            activeRuns: lookups.compactMap(\.run).sorted { $0.updatedAt > $1.updatedAt },
            recentChats: Array(recentChats)
        )
    }

    private func configureTransparentWindow(_ window: NSWindow) {
        if window.isOpaque {
            window.isOpaque = false
        }
        if window.backgroundColor != .clear {
            window.backgroundColor = .clear
        }
        window.hasShadow = true
        if window.titleVisibility != .hidden {
            window.titleVisibility = .hidden
        }
        if !window.titlebarAppearsTransparent {
            window.titlebarAppearsTransparent = true
        }
        if window.titlebarSeparatorStyle != .none {
            window.titlebarSeparatorStyle = .none
        }
        if window.toolbarStyle != .unified {
            window.toolbarStyle = .unified
        }
        window.isMovableByWindowBackground = false
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
    }
}

private final class SloppyNotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // A notch sits at the physical screen edge, including the menu-bar area.
        frameRect
    }
}

struct SloppyDesktopNotchView: View {
    static let collapsedSize = CGSize(width: 340, height: 28)
    static let expandedHeaderHeight: CGFloat = 32
    static let expandedSize = CGSize(width: 340, height: 148)
    static let wideWidth: CGFloat = 480

    static func size(for state: SloppyDesktopOverlayState) -> CGSize {
        guard state.isExpanded else {
            return state.notchGeometry.collapsedSize
        }
        return expandedPanelSize(for: state)
    }

    private static func expandedPanelSize(for state: SloppyDesktopOverlayState) -> CGSize {
        CGSize(width: state.notchGeometry.expandedWidth, height: 460)
    }

    let state: SloppyDesktopOverlayState
    let isPointerInsidePanel: @MainActor () -> Bool
    @Namespace private var petTransitionNamespace
    @State private var isHovered = false
    @State private var isPetExpanded = false
    @State private var hoverCollapseTask: Task<Void, Never>?
    @FocusState private var isTaskComposerFocused: Bool

    init(
        state: SloppyDesktopOverlayState,
        isPointerInsidePanel: @escaping @MainActor () -> Bool = { false }
    ) {
        self.state = state
        self.isPointerInsidePanel = isPointerInsidePanel
    }

    var body: some View {
        headerContent
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .top) {
            // The fixed-width details must not impose their width on the header
            // or the collapsed panel. Reveal them below the stationary header.
            revealedContent.padding(.top, state.notchGeometry.expandedHeaderHeight)
        }
        .foregroundStyle(.white)
        .background {
            UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14)
                .fill(.black.opacity(isHovered ? 0.96 : 0.92))
                .overlay {
                    UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                }
        }
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14))
        .onHover(perform: handleHoverChange)
        .onDisappear {
            hoverCollapseTask?.cancel()
        }
        .onAppear {
            isPetExpanded = state.isExpanded
        }
        .task(id: state.activityRevealToken) {
            await autoCollapseActiveContent()
        }
        .onChange(of: state.isExpanded) { _, expanded in
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                isPetExpanded = expanded
            } else {
                withAnimation(.spring(response: expanded ? 0.30 : 0.22, dampingFraction: 0.82)) {
                    isPetExpanded = expanded
                }
            }
            if !expanded {
                isTaskComposerFocused = false
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sloppy desktop notch")
    }

    @ViewBuilder
    private var headerContent: some View {
        if state.isExpanded {
            HStack(spacing: 0) {
                if state.notchGeometry.hardwareWidth > 0 {
                    sectionButtons
                        .frame(width: state.notchGeometry.headerSideWidth, alignment: .leading)
                    Color.clear.frame(width: state.notchGeometry.reservedCenterWidth)
                    HStack(spacing: 4) {
                        newChatButton
                        Spacer(minLength: 0)
                        collapseButton
                    }
                    .frame(width: state.notchGeometry.headerSideWidth)
                } else {
                    sectionButtons
                    newChatButton
                    Spacer()
                    collapseButton
                }
            }
            .padding(.horizontal, 12)
            .frame(height: state.notchGeometry.expandedHeaderHeight)
        } else {
            collapsedHeaderContent
        }
    }

    private var sectionButtons: some View {
        HStack(spacing: 4) {
            ForEach(SloppyDesktopNotchSection.allCases) { section in
                Button { state.selectSection(section) } label: {
                    Image(systemName: section.systemImage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(state.selectedSection == section ? .white : .gray)
                        .frame(width: 36, height: 27)
                        .background(state.selectedSection == section ? .white.opacity(0.13) : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
                .help(section.title)
                .accessibilityLabel(section.title)
                .accessibilityAddTraits(state.selectedSection == section ? .isSelected : [])
                .accessibilityIdentifier("notch.tab.\(section.rawValue)")
            }
        }
    }

    private var newChatButton: some View {
        Button { state.startNewChat() } label: {
            Image(systemName: "plus").frame(width: 28, height: 27)
        }
        .buttonStyle(.plain)
        .help("New chat")
        .accessibilityLabel("New chat")
        .accessibilityIdentifier("notch.new-chat")
    }

    private var collapseButton: some View {
        Button { state.setExpanded(false) } label: {
            Image(systemName: "chevron.up").font(.system(size: 10)).frame(width: 22, height: 27)
        }
        .buttonStyle(.plain)
        .help("Hide notch")
        .accessibilityLabel("Hide notch")
    }

    private var collapsedHeaderContent: some View {
        HStack(spacing: state.isExpanded ? 7 : 4) {
            if state.toolApproval == nil {
                ZStack {
                    if !isPetExpanded {
                        SloppyNotchPetView(
                            agentID: state.mascotAgentID,
                            paletteID: state.mascotPaletteID,
                            state: state.mascotState,
                            onClick: { _ = state.openMascotDestination() }
                        )
                            .matchedGeometryEffect(
                                id: "notch-mascot",
                                in: petTransitionNamespace
                            )
                            .transition(.identity)
                    }
                }
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            } else {
                Button {
                    if !state.openMascotDestination() {
                        state.toggleExpanded()
                    }
                } label: {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(compactTitle)
                .accessibilityLabel(compactTitle)
            }
            Spacer(minLength: max(2, state.notchGeometry.reservedCenterWidth))
            if state.activityCount > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "bolt.fill")
                    if state.isExpanded {
                        Text("\(state.activityCount)")
                    }
                }
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.cyan)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(state.activityCount) active items")
            }
            Button {
                state.toggleExpanded()
            } label: {
                Image(systemName: state.isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(state.isExpanded ? "Hide details" : "Show details")
        }
        .padding(.horizontal, state.isExpanded ? 12 : 8)
        .frame(height: state.notchGeometry.collapsedSize.height)
    }

    private var revealedContent: some View {
        let size = Self.expandedPanelSize(for: state)
        let opacity: Double = state.isExpanded ? 1 : 0
        return VStack(spacing: 0) {
            Divider().opacity(0.35)
            expandedContent
        }
        // Keep text, rows and native controls at their final layout size.
        // Only the surrounding panel clips/reveals them during resizing.
        .frame(
            width: size.width,
            height: size.height - state.notchGeometry.expandedHeaderHeight,
            alignment: .top
        )
        .opacity(opacity)
        .animation(
            state.isExpanded ? .easeOut(duration: 0.16).delay(0.03) : .easeOut(duration: 0.08),
            value: state.isExpanded
        )
        .allowsHitTesting(state.isExpanded)
        .disabled(!state.isExpanded)
        .accessibilityHidden(!state.isExpanded)
    }

    private var compactTitle: String {
        switch state.mascotState {
        case .error:
            return "Something went wrong"
        case .needsInput:
            if state.toolApproval != nil {
                return "Approval needed"
            }
            return state.mascotPrimaryRun.map { "\($0.agentName) needs input" } ?? "Input needed"
        case .thinking:
            return state.mascotPrimaryRun.map { "\($0.agentName) is thinking" } ?? "Thinking"
        case .working:
            if state.activeAgentRuns.count == 1 {
                return "\(state.activeAgentRuns[0].agentName) is working"
            }
            if state.activeAgentRuns.count > 1 {
                return "\(state.activeAgentRuns.count) agents working"
            }
            return "Sloppy is working"
        case .idle:
            return "Sloppy"
        }
    }

    private func handleHoverChange(_ hovering: Bool) {
        hoverCollapseTask?.cancel()
        hoverCollapseTask = nil

        guard hovering else {
            scheduleHoverCollapse()
            return
        }

        isHovered = true
        state.setExpanded(true)
    }

    private func scheduleHoverCollapse() {
        guard state.selectedRecentChatID == nil,
              !state.hasTaskDraft,
              !isTaskComposerFocused else { return }

        hoverCollapseTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                guard state.selectedRecentChatID == nil else { return }
                guard !state.hasTaskDraft, !isTaskComposerFocused else { return }
                guard !isPointerInsidePanel() else { continue }

                isHovered = false
                state.setExpanded(false)
                return
            }
        }
    }

    private func autoCollapseActiveContent() async {
        guard state.activityRevealToken > 0 else { return }
        try? await Task.sleep(for: .seconds(3))
        guard !Task.isCancelled else { return }

        while isPointerInsidePanel() {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
        }

        guard state.activityCount > 0,
              state.selectedRecentChatID == nil,
              !state.hasTaskDraft,
              !isTaskComposerFocused else { return }
        isHovered = false
        state.setExpanded(false)
    }

    private var expandedContent: some View {
        SloppyDesktopNotchContent(state: state) {
            taskComposerContent
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private var taskComposerContent: some View {
        VStack(alignment: .leading, spacing: 5) {
            Menu {
                Picker(
                    "Project",
                    selection: Binding(
                        get: { state.selectedProjectID ?? "" },
                        set: { state.selectProject(id: $0) }
                    )
                ) {
                    if state.projects.isEmpty {
                        Text("No projects").tag("")
                    } else {
                        ForEach(state.projects) { project in
                            Text(project.name).tag(project.id)
                        }
                    }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 5) {
                    Text(state.projects.first { $0.id == state.selectedProjectID }?.name ?? "No projects")
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 19)
            .disabled(state.projects.isEmpty)
            .help("Project for the new task")

            HStack(spacing: 7) {
                TextField(
                    "New task for agent…",
                    text: Binding(
                        get: { state.taskDraft },
                        set: { state.updateTaskDraft($0) }
                    )
                )
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(.white.opacity(0.09), in: Capsule())
                .focused($isTaskComposerFocused)
                .onSubmit {
                    state.submitTask()
                }

                Button {
                    state.submitTask()
                } label: {
                    if state.isCreatingTask {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 26, height: 26)
                    } else {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 26, height: 26)
                    }
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .disabled(!state.canCreateTask)
                .help("Create task")
            }

            if let taskCreationError = state.taskCreationError {
                Text(taskCreationError)
                    .font(.system(size: 9))
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
    }
}

@MainActor
struct TransparentWindowConfigurationView: NSViewRepresentable {
    let onWindowAvailable: @MainActor (NSWindow) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onWindowAvailable: onWindowAvailable)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        configureWindow(from: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configureWindow(from: nsView, coordinator: context.coordinator)
    }

    private func configureWindow(from view: NSView, coordinator: Coordinator) {
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            coordinator.observe(window)
            onWindowAvailable(window)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        private weak var window: NSWindow?
        private let onWindowAvailable: @MainActor (NSWindow) -> Void

        init(onWindowAvailable: @escaping @MainActor (NSWindow) -> Void) {
            self.onWindowAvailable = onWindowAvailable
        }

        func observe(_ window: NSWindow) {
            guard self.window !== window else { return }
            if self.window != nil {
                NotificationCenter.default.removeObserver(self)
            }
            self.window = window
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidUpdate(_:)),
                name: NSWindow.didUpdateNotification,
                object: window
            )
        }

        @objc private func windowDidUpdate(_ notification: Notification) {
            guard let window = notification.object as? NSWindow,
                  window === self.window else { return }
            onWindowAvailable(window)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}

@MainActor
struct WindowDragHandleStrip: NSViewRepresentable {
    let height: CGFloat

    func makeNSView(context: Context) -> WindowDragHandleNSView {
        WindowDragHandleNSView()
    }

    func updateNSView(_ nsView: WindowDragHandleNSView, context: Context) {
        _ = height
    }
}

final class WindowDragHandleNSView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        self
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

@Observable
@MainActor
final class SloppyDesktopOverlayState {
    var notchGeometry = SloppyDesktopNotchGeometry()
    var agentPalettes: [String: String] = [:]
    var agents: [APIAgentRecord] = []
    var selectedSection: SloppyDesktopNotchSection = .home
    private(set) var selectedChat: SloppyDesktopRecentChat?
    private(set) var chatViewModel: ChatScreenViewModel?
    var toolApproval: AppNotification?
    var activeAgentRuns: [SloppyDesktopAgentRun] = []
    var activeTasks: [SloppyDesktopTask] = []
    var recentChats: [SloppyDesktopRecentChat] = []
    var projects: [SloppyDesktopProject] = []
    var isExpanded = false
    var errorMessage: String?
    var activityRevealToken = 0
    var selectedRecentChatID: String? { selectedChat?.id }
    var selectedProjectID: String?
    var taskDraft = ""
    var isCreatingTask = false
    var taskCreationError: String?
    var onExpansionChanged: (@MainActor () -> Void)?
    var onOpenTask: (@MainActor (SloppyDesktopTask) -> Void)?
    var onOpenDeepLink: (@MainActor (URL) -> Void)?
    var onMakeChatViewModel: (@MainActor () -> ChatScreenViewModel)?
    var onCreateTask: (@MainActor (SloppyDesktopProject, String) async throws -> Void)?

    var usesWideLayout: Bool {
        true
    }

    var activityCount: Int {
        activeAgentRuns.count + activeTasks.count
    }

    var primaryAgentRun: SloppyDesktopAgentRun? {
        guard toolApproval == nil, activeAgentRuns.count == 1 else { return nil }
        return activeAgentRuns[0]
    }

    var mascotState: SloppyNotchPetState {
        if mascotErrorMessage != nil
            || activeAgentRuns.contains(where: { $0.stage == .interrupted })
            || activeTasks.contains(where: \.isError) {
            return .error
        }
        if toolApproval != nil
            || activeAgentRuns.contains(where: \.needsInput)
            || activeTasks.contains(where: \.requiresInput) {
            return .needsInput
        }
        if activeAgentRuns.contains(where: { $0.stage == .thinking }) {
            return .thinking
        }
        return activityCount > 0 ? .working : .idle
    }

    var mascotPaletteID: String? { agentPalettes[mascotAgentID] }

    var mascotAgentID: String {
        if let agentID = toolApproval?.metadata["agentId"] { return agentID }
        if let agentID = mascotPrimaryRun?.agentID { return agentID }
        if let agentID = activeTasks.first(where: \.isError)?.agentID { return agentID }
        if let agentID = activeTasks.first(where: \.requiresInput)?.agentID { return agentID }
        return activeTasks.first?.agentID ?? "sloppy"
    }

    var mascotPrimaryRun: SloppyDesktopAgentRun? {
        activeAgentRuns.first(where: { $0.stage == .interrupted })
            ?? activeAgentRuns.first(where: \.needsInput)
            ?? activeAgentRuns.first(where: { $0.stage == .thinking })
            ?? primaryAgentRun
            ?? activeAgentRuns.first
    }

    var mascotErrorMessage: String? {
        [errorMessage, chatViewModel?.sendErrorMessage, taskCreationError]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
            ?? activeAgentRuns.first(where: { $0.stage == .interrupted })?.statusDetails
            ?? activeTasks.first(where: \.isError).map { "\($0.title) · \($0.projectName)" }
    }

    var mascotNeedsInputMessage: String? {
        toolApproval?.message
            ?? activeAgentRuns.first(where: \.needsInput)?.inputPrompt
            ?? activeAgentRuns.first(where: \.needsInput)?.statusDetails
            ?? activeTasks.first(where: \.requiresInput).map { "\($0.title) · \($0.projectName)" }
    }

    var hasMascotDestination: Bool {
        mascotDeepLink != nil
    }

    var hasTaskDraft: Bool {
        !taskDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canCreateTask: Bool {
        hasTaskDraft
            && selectedProject != nil
            && !isCreatingTask
    }

    var hasContentBeforeTaskComposer: Bool {
        activityCount > 0 || !recentChats.isEmpty
    }

    private var selectedProject: SloppyDesktopProject? {
        guard let selectedProjectID else { return nil }
        return projects.first { $0.id == selectedProjectID }
    }

    func toggleExpanded() {
        setExpanded(!isExpanded)
    }

    func setExpanded(_ expanded: Bool) {
        guard isExpanded != expanded else { return }
        isExpanded = expanded
        onExpansionChanged?()
    }

    func selectSection(_ section: SloppyDesktopNotchSection) {
        selectedSection = section
        selectedChat = nil
        setExpanded(true)
        onExpansionChanged?()
    }

    func openAgentRun(_ run: SloppyDesktopAgentRun) {
        openRecentChat(SloppyDesktopRecentChat(
            id: run.id, agentID: run.agentID, sessionID: run.sessionID,
            title: run.sessionTitle, agentName: run.agentName, updatedAt: run.updatedAt
        ))
    }

    func openRecentChat(_ chat: SloppyDesktopRecentChat) {
        selectedChat = chat
        selectedSection = .chats
        if chatViewModel == nil { chatViewModel = onMakeChatViewModel?() }
        chatViewModel?.closeSession()
        chatViewModel?.openSessionFromSummary(chat.sessionSummary)
        setExpanded(true)
        onExpansionChanged?()
    }

    func backToChats() {
        selectSection(.chats)
    }

    func resetChatContext() {
        chatViewModel?.closeSession()
        chatViewModel = nil
        selectedChat = nil
        agents = []
        recentChats = []
        activeAgentRuns = []
        activeTasks = []
        agentPalettes = [:]
        onExpansionChanged?()
    }

    func startNewChat(agentID: String? = nil) {
        guard let agent = teamAgents.first(where: { $0.id == agentID }) ?? teamAgents.first else { return }
        let chat = SloppyDesktopRecentChat(
            id: "draft/\(UUID().uuidString)", agentID: agent.id, sessionID: "",
            title: "New chat", agentName: agent.displayName, updatedAt: Date()
        )
        selectedChat = chat
        selectedSection = .chats
        if chatViewModel == nil { chatViewModel = onMakeChatViewModel?() }
        if let model = chatViewModel {
            model.closeSession()
            Task { @MainActor [weak self] in
                await model.waitForInitialData()
                guard self?.selectedChat?.id == chat.id, self?.chatViewModel === model else { return }
                model.startNewMessage(agentID: agent.id)
            }
        }
        setExpanded(true)
        onExpansionChanged?()
    }

    var teamAgents: [APIAgentRecord] {
        if !agents.isEmpty { return agents }
        var seen: Set<String> = []
        return (activeAgentRuns.map { APIAgentRecord(id: $0.agentID, displayName: $0.agentName) }
                + recentChats.map { APIAgentRecord(id: $0.agentID, displayName: $0.agentName) })
            .filter { seen.insert($0.id).inserted }
    }

    func openAgent(_ agent: APIAgentRecord) {
        if let run = activeAgentRuns.first(where: { $0.agentID == agent.id }) {
            openAgentRun(run)
        } else if let chat = recentChats.first(where: { $0.agentID == agent.id }) {
            openRecentChat(chat)
        } else {
            startNewChat(agentID: agent.id)
        }
    }

    func openTask(_ task: SloppyDesktopTask) {
        setExpanded(false)
        onOpenTask?(task)
    }

    @discardableResult
    func openMascotDestination() -> Bool {
        if let approval = toolApproval,
           let agentID = approval.metadata["agentId"],
           let sessionID = approval.metadata["displaySessionId"] ?? approval.metadata["sessionId"] {
            openRecentChat(SloppyDesktopRecentChat(
                id: "\(agentID)/\(sessionID)", agentID: agentID, sessionID: sessionID,
                title: "Approval needed", agentName: teamAgents.first { $0.id == agentID }?.displayName ?? agentID,
                updatedAt: Date()
            ))
            return true
        }
        if let run = mascotPrimaryRun {
            openAgentRun(run)
            return true
        }
        guard let url = mascotDeepLink else { return false }
        setExpanded(false)
        onOpenDeepLink?(url)
        return true
    }

    private var mascotDeepLink: URL? {
        if let approval = toolApproval,
           let agentID = approval.metadata["agentId"],
           let sessionID = approval.metadata["displaySessionId"] ?? approval.metadata["sessionId"] {
            return DeepLink.session(agentId: agentID, sessionId: sessionID).url
        }
        if let run = mascotPrimaryRun {
            return DeepLink.session(agentId: run.agentID, sessionId: run.sessionID).url
        }
        if let task = activeTasks.first(where: { $0.isError || $0.requiresInput })
            ?? activeTasks.first {
            return DeepLink.task(projectId: task.projectID, taskId: task.taskID).url
        }
        return nil
    }

    func selectProject(id: String) {
        selectedProjectID = projects.contains { $0.id == id } ? id : nil
        taskCreationError = nil
    }

    func updateTaskDraft(_ draft: String) {
        taskDraft = draft
        taskCreationError = nil
    }

    func submitTask() {
        let title = taskDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty,
              !isCreatingTask,
              let selectedProject,
              let onCreateTask else { return }

        isCreatingTask = true
        taskCreationError = nil
        Task { @MainActor in
            do {
                try await onCreateTask(selectedProject, title)
                taskDraft = ""
            } catch {
                taskCreationError = error.localizedDescription
            }
            isCreatingTask = false
            onExpansionChanged?()
        }
    }

    func setActiveTasks(_ tasks: [SloppyDesktopTask]) {
        let previouslyUsedWideLayout = usesWideLayout
        let hadActiveTasks = !activeTasks.isEmpty
        let tasksChanged = activeTasks != tasks
        let hasNewAttention = tasks.contains { task in
            let previous = activeTasks.first { $0.id == task.id }
            return (task.requiresInput && previous?.requiresInput != true)
                || (task.isError && previous?.isError != true)
        }
        activeTasks = tasks
        if hasNewAttention {
            revealActivityTemporarily()
        }
        if tasksChanged || previouslyUsedWideLayout != usesWideLayout || hadActiveTasks != !tasks.isEmpty {
            onExpansionChanged?()
        }
    }

    func setActiveAgentRuns(_ runs: [SloppyDesktopAgentRun]) {
        let previouslyUsedWideLayout = usesWideLayout
        let hadActivity = activityCount > 0
        let runsChanged = activeAgentRuns != runs
        let hasNewAttention = runs.contains { run in
            let previous = activeAgentRuns.first { $0.id == run.id }
            return (run.needsInput && previous?.needsInput != true)
                || (run.stage == .interrupted && previous?.stage != .interrupted)
        }
        activeAgentRuns = runs
        if hasNewAttention {
            revealActivityTemporarily()
        }
        if runsChanged || previouslyUsedWideLayout != usesWideLayout || hadActivity != (activityCount > 0) {
            onExpansionChanged?()
        }
    }

    func setRecentChats(_ chats: [SloppyDesktopRecentChat]) {
        let previouslyUsedWideLayout = usesWideLayout
        let chatsChanged = recentChats != chats
        recentChats = chats
        if chatsChanged || previouslyUsedWideLayout != usesWideLayout {
            onExpansionChanged?()
        }
    }

    func setProjects(_ projects: [SloppyDesktopProject]) {
        let projectsChanged = self.projects != projects
        self.projects = projects
        if selectedProject == nil {
            selectedProjectID = projects.first?.id
        }
        if projectsChanged {
            onExpansionChanged?()
        }
    }

    private func revealActivityTemporarily() {
        isExpanded = true
        activityRevealToken &+= 1
    }

    func apply(_ notification: AppNotification) {
        guard notification.type == .toolApproval else { return }

        let status = notification.metadata["status"] ?? "pending"
        if status == "pending" {
            toolApproval = notification
            errorMessage = nil
            onExpansionChanged?()
            return
        }
        if toolApproval?.metadata["approvalId"] == notification.metadata["approvalId"] {
            toolApproval = nil
            onExpansionChanged?()
        }
    }
}

struct SloppyDesktopTask: Identifiable, Equatable {
    let id: String
    let projectID: String
    let taskID: String
    let title: String
    let projectName: String
    let status: ProjectKanbanColumnID
    let rawStatus: String
    var agentID: String? = nil

    var requiresInput: Bool {
        rawStatus == "waiting_input" || rawStatus == "pending_approval"
    }

    var isError: Bool {
        rawStatus == "blocked"
    }

    var statusTitle: String {
        if requiresInput {
            return "Waiting for input"
        }
        if isError {
            return "Blocked"
        }
        switch status {
        case .inProgress: return "In progress"
        case .needsReview: return "Needs review"
        case .todo: return "To do"
        case .done: return "Done"
        case .other: return "Other"
        }
    }
}

struct SloppyDesktopProject: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let actorID: String?
}

struct SloppyDesktopAgentRun: Identifiable, Equatable, Sendable {
    let id: String
    let agentID: String
    let sessionID: String
    let sessionTitle: String
    let agentName: String
    let stage: ChatRunStage
    let statusLabel: String
    let statusDetails: String?
    let needsInput: Bool
    let inputPrompt: String?
    let updatedAt: Date

    var subtitle: String {
        let detail = statusDetails?.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = detail?.isEmpty == false ? detail! : statusLabel
        return "\(agentName) · \(status)"
    }
}

struct SloppyDesktopRecentChat: Identifiable, Equatable, Sendable {
    let id: String
    let agentID: String
    let sessionID: String
    let title: String
    let agentName: String
    let updatedAt: Date
    var projectID: String? = nil
    var projectName: String? = nil
    var taskID: String? = nil

    var sessionSummary: ChatSessionSummary {
        ChatSessionSummary(
            id: sessionID, agentId: agentID, title: title, updatedAt: updatedAt,
            projectId: projectID, taskId: taskID
        )
    }
}

private struct SloppyDesktopAgentActivity: Sendable {
    let activeRuns: [SloppyDesktopAgentRun]
    let recentChats: [SloppyDesktopRecentChat]
}

private struct SloppyDesktopAgentRunCacheEntry: Sendable {
    let updatedAt: Date
    let run: SloppyDesktopAgentRun?
}

private struct SloppyDesktopAgentRunLookup: Sendable {
    let id: String
    let updatedAt: Date
    let run: SloppyDesktopAgentRun?
}

@MainActor
private struct SloppyDesktopOverlayPreviewCase {
    let title: String
    let state: SloppyDesktopOverlayState

    static var all: [SloppyDesktopOverlayPreviewCase] {
        [
            .init(title: "Collapsed", state: makeState()),
            .init(title: "Running", state: makeState(isExpanded: true)),
            .init(
                title: "Agent working",
                state: makeState(
                    isExpanded: true,
                    activeAgentRuns: makeAgentRuns(),
                    recentChats: makeRecentChats()
                )
            ),
            .init(
                title: "Recent chats",
                state: makeState(isExpanded: true, recentChats: makeRecentChats())
            ),
            .init(
                title: "Active tasks",
                state: makeState(isExpanded: true, activeTasks: makeTasks())
            ),
            .init(
                title: "Tool approval",
                state: makeState(
                    approval: makeApproval()
                )
            ),
            .init(
                title: "Tasks and approval",
                state: makeState(
                    isExpanded: true,
                    approval: makeApproval(),
                    activeTasks: makeTasks()
                )
            ),
        ]
    }

    private static func makeState(
        isExpanded: Bool = false,
        errorMessage: String? = nil,
        approval: AppNotification? = nil,
        activeAgentRuns: [SloppyDesktopAgentRun] = [],
        recentChats: [SloppyDesktopRecentChat] = [],
        activeTasks: [SloppyDesktopTask] = []
    ) -> SloppyDesktopOverlayState {
        let state = SloppyDesktopOverlayState()
        state.isExpanded = isExpanded
        state.errorMessage = errorMessage
        state.toolApproval = approval
        state.activeAgentRuns = activeAgentRuns
        state.recentChats = recentChats
        state.activeTasks = activeTasks
        state.projects = [
            SloppyDesktopProject(
                id: "sloppy-client",
                name: "Sloppy Client",
                actorID: "sloppy"
            ),
            SloppyDesktopProject(
                id: "ada-engine",
                name: "AdaEngine",
                actorID: "sloppy"
            ),
        ]
        state.selectedProjectID = state.projects.first?.id
        return state
    }

    private static func makeAgentRuns() -> [SloppyDesktopAgentRun] {
        [
            SloppyDesktopAgentRun(
                id: "sloppy/preview-session",
                agentID: "sloppy",
                sessionID: "preview-session",
                sessionTitle: "Fix the desktop Notch status",
                agentName: "Sloppy",
                stage: .responding,
                statusLabel: "Working",
                statusDetails: "Inspecting runtime state",
                needsInput: false,
                inputPrompt: nil,
                updatedAt: Date()
            )
        ]
    }

    private static func makeRecentChats() -> [SloppyDesktopRecentChat] {
        [
            SloppyDesktopRecentChat(
                id: "sloppy/recent-1",
                agentID: "sloppy",
                sessionID: "recent-1",
                title: "Polish the desktop Notch",
                agentName: "Sloppy",
                updatedAt: Date()
            ),
            SloppyDesktopRecentChat(
                id: "reviewer/recent-2",
                agentID: "reviewer",
                sessionID: "recent-2",
                title: "Review overlay interactions",
                agentName: "Reviewer",
                updatedAt: Date().addingTimeInterval(-120)
            ),
            SloppyDesktopRecentChat(
                id: "planner/recent-3",
                agentID: "planner",
                sessionID: "recent-3",
                title: "Plan the next client release",
                agentName: "Planner",
                updatedAt: Date().addingTimeInterval(-240)
            ),
        ]
    }

    private static func makeTasks() -> [SloppyDesktopTask] {
        [
            SloppyDesktopTask(
                id: "preview-task-1",
                projectID: "sloppy-client",
                taskID: "preview-task-1",
                title: "Implement backend installer",
                projectName: "Sloppy Client",
                status: .inProgress,
                rawStatus: "in_progress"
            ),
            SloppyDesktopTask(
                id: "preview-task-2",
                projectID: "sloppy-client",
                taskID: "preview-task-2",
                title: "Review desktop overlay changes",
                projectName: "Sloppy Client",
                status: .needsReview,
                rawStatus: "needs_review"
            ),
        ]
    }

    private static func makeApproval() -> AppNotification {
        AppNotification(
            id: "preview-tool-approval",
            type: .toolApproval,
            title: "Allow file access?",
            message: "The agent wants to read Package.swift to inspect project dependencies.",
            metadata: [
                "approvalId": "preview-approval-id",
                "status": "pending",
                "tool": "read_file",
            ]
        )
    }
}

#Preview("Overlay states") {
    ScrollView {
        VStack(alignment: .leading, spacing: 28) {
            ForEach(SloppyDesktopOverlayPreviewCase.all, id: \.title) { preview in
                VStack(alignment: .leading, spacing: 8) {
                    Text(preview.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    SloppyDesktopNotchView(state: preview.state)
                        .frame(
                            width: SloppyDesktopNotchView.size(for: preview.state).width,
                            height: SloppyDesktopNotchView.size(for: preview.state).height
                        )
                }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(width: 720, height: 900)
    .background(.gray.opacity(0.12))
}

#endif
