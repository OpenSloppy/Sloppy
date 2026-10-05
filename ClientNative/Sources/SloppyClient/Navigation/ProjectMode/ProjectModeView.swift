import SloppyClientCore
import SloppyClientUI
import SloppyFeatureChat
import SloppyFeatureProjects
import SwiftUI

@MainActor
struct ProjectModeView: View {
    let project: APIProjectRecord
    let state: ProjectKanbanTabState
    let rootSafeAreaInsets: EdgeInsets
    let onSelectSection: @MainActor (ProjectModeSection) -> Void
    let onOpenTask: @MainActor (ProjectKanbanCard) -> Void
    var onOpenTaskChat: (@MainActor (APIProjectTask) -> Void)? = nil

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
#if os(macOS)
            HStack(spacing: 0) {
                projectContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if state.selectedSection == .workspaces, !state.workspaceViewModel.isShowingLibrary {
                            HStack { workspaceBackButton; Spacer() }
                                .padding(12)
                                .background(theme.colors.surface)
                        }
                    }
                ProjectModeRail(selectedSection: state.selectedSection, onSelect: onSelectSection)
            }
#elseif os(iOS)
            TabView(selection: Binding(
                get: { state.selectedSection },
                set: { onSelectSection($0) }
            )) {
                ForEach(ProjectModeSection.allCases) { section in
                    Tab(section.title, systemImage: section.systemImage, value: section) {
                        IOSProjectSectionNavigation(
                            project: project,
                            state: state,
                            onOpenTaskChat: onOpenTaskChat
                        ) { openTask in
                            projectContent(for: section, onOpenTaskOverride: openTask)
                                .mobileScreenBackground()
                                .navigationTitle(project.name)
                                .navigationBarTitleDisplayMode(.inline)
                                .toolbar {
                                    ToolbarItem(placement: .topBarLeading) {
                                        Button("Close", systemImage: "xmark") { dismiss() }
                                            .accessibilityIdentifier("project-mode-close")
                                    }
                                    if section == .workspaces, !state.workspaceViewModel.isShowingLibrary {
                                        ToolbarItem(placement: .topBarTrailing) { workspaceBackButton }
                                    }
                                }
                        }
                        .modifier(IOSComposerContainer(
                            composer: {
                                AnyView(ChatComposerOverlay(
                                    viewModel: state.chatViewModel,
                                    contentWidth: ChatComposerView.panelWidth,
                                    composerBottomInset: 8,
                                    tabs: [],
                                    tabActions: nil
                                ))
                            },
                            viewModel: state.chatViewModel,
                            allowsAutomaticFocus: section == .chats
                        ))
                        .environment(\.isChatComposerInset, true)
                    }
                }
            }
#else
            VStack(spacing: 0) {
                projectModeChrome
                projectContent
            }
#endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("project-mode")
    }

    private var projectModeChrome: some View {
        ZStack {
            ScrollView(.horizontal, showsIndicators: false) {
                projectModePicker(showsTitles: true)
                    .fixedSize(horizontal: true, vertical: false)
            }

            if state.selectedSection == .workspaces,
               !state.workspaceViewModel.isShowingLibrary {
                HStack {
                    workspaceBackButton

                    Spacer()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(theme.colors.surface.opacity(0.7))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var workspaceBackButton: some View {
        Button {
            state.workspaceViewModel.showLibrary()
            Task { await state.workspaceViewModel.refreshLibrary() }
        } label: {
            Label("Workspaces", systemImage: "chevron.left")
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.colors.textSecondary)
        .accessibilityIdentifier("project-mode-workspaces-back")
    }

    private func projectModePicker(showsTitles: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(ProjectModeSection.allCases) { section in
                Button {
                    onSelectSection(section)
                } label: {
                    projectModeLabel(section, showsTitle: showsTitles)
                        .font(.system(size: theme.typography.caption, weight: .semibold))
                        .lineLimit(1)
                        .padding(.horizontal, showsTitles ? 14 : 12)
                        .frame(minHeight: 32)
                        .contentShape(Capsule())
                        .background {
                            if state.selectedSection == section {
                                Capsule()
                                    .fill(theme.colors.surfaceRaised)
                                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    state.selectedSection == section
                        ? theme.colors.textPrimary
                        : theme.colors.textSecondary
                )
                .accessibilityIdentifier("project-mode-\(section.rawValue)")
            }
        }
        .padding(3)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(theme.colors.border.opacity(0.7), lineWidth: theme.borders.thin)
        }
    }

    @ViewBuilder
    private func projectModeLabel(_ section: ProjectModeSection, showsTitle: Bool) -> some View {
        if showsTitle {
            Label(section.title, systemImage: section.systemImage)
        } else {
            Label(section.title, systemImage: section.systemImage)
                .labelStyle(.iconOnly)
        }
    }

    @ViewBuilder
    private var projectContent: some View {
        projectContent(for: state.selectedSection)
    }

    @ViewBuilder
    private func projectContent(
        for section: ProjectModeSection,
        onOpenTaskOverride: (@MainActor (ProjectKanbanCard) -> Void)? = nil
    ) -> some View {
        switch section {
        case .kanban:
            ProjectKanbanView(
                viewModel: state.viewModel,
                projectId: project.id,
                projectName: project.name,
                onOpenTask: onOpenTaskOverride ?? onOpenTask,
                onOpenTaskChat: onOpenTaskChat
            )
        case .workspaces:

            CanvasWorkspaceSurface(
                viewModel: state.workspaceViewModel,
                allowsProjectSelection: false
            )
        case .automation:

            ProjectAutomationView(
                viewModel: state.automationViewModel,
                projectId: project.id,
                projectName: project.name
            )
        case .chats:

            ChatScreen(
                viewModel: state.chatViewModel,
                rootSafeAreaInsets: rootSafeAreaInsets,
                showsContextToolbar: false,
                showsNavigationToolbar: false
            )
            .id(ObjectIdentifier(state.chatViewModel))

        }
    }
}

#if os(iOS)
/// Each project tab owns its task navigation history.
@MainActor
private struct IOSProjectSectionNavigation<Content: View>: View {
    let project: APIProjectRecord
    let state: ProjectKanbanTabState
    let onOpenTaskChat: (@MainActor (APIProjectTask) -> Void)?
    @ViewBuilder let content: (@escaping @MainActor (ProjectKanbanCard) -> Void) -> Content
    @State private var taskPath: [String] = []

    var body: some View {
        NavigationStack(path: $taskPath) {
            content { card in taskPath.append(card.id) }
                .navigationDestination(for: String.self) { taskID in
                    IOSProjectTaskDetail(
                        project: project,
                        taskID: taskID,
                        state: state,
                        onOpenChat: onOpenTaskChat,
                        onOpenRelated: { taskPath.append($0.id) }
                    )
                }
        }
    }
}

@MainActor
private struct IOSProjectTaskDetail: View {
    let project: APIProjectRecord
    let taskID: String
    let state: ProjectKanbanTabState
    let onOpenChat: (@MainActor (APIProjectTask) -> Void)?
    let onOpenRelated: @MainActor (APIProjectTask) -> Void
    @State private var detail: TaskDetailViewModel
    @Environment(\.dismiss) private var dismiss

    init(
        project: APIProjectRecord,
        taskID: String,
        state: ProjectKanbanTabState,
        onOpenChat: (@MainActor (APIProjectTask) -> Void)?,
        onOpenRelated: @escaping @MainActor (APIProjectTask) -> Void
    ) {
        self.project = project
        self.taskID = taskID
        self.state = state
        self.onOpenChat = onOpenChat
        self.onOpenRelated = onOpenRelated
        _detail = State(initialValue: state.viewModel.makeTaskDetailViewModel())
    }

    var body: some View {
        TaskDetailView(
            viewModel: detail,
            projectId: project.id,
            taskId: taskID,
            onClose: { dismiss() },
            onOpenChat: onOpenChat.map { action in
                { @MainActor @Sendable task in action(task) }
            },
            onOpenRelatedTask: { task in onOpenRelated(task) },
            onTaskChanged: { await state.viewModel.load(projectId: project.id) }
        )
        .mobileScreenBackground()
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
