import SwiftUI
import SloppyClientCore
import SloppyClientUI

@MainActor
public struct ProjectKanbanView: View {
    @Bindable var viewModel: ProjectKanbanViewModel
    let projectId: String
    let projectName: String
    let onOpenTask: @MainActor (ProjectKanbanCard) -> Void
    let onOpenTaskChat: (@MainActor (APIProjectTask) -> Void)?

    @Environment(\.theme) private var theme
    @State private var previewTask: ProjectKanbanCard?
    @State private var previewModel: TaskDetailViewModel?
    @State private var isCreateTaskPresented = false

    public init(
        viewModel: ProjectKanbanViewModel,
        projectId: String,
        projectName: String,
        onOpenTask: @escaping @MainActor (ProjectKanbanCard) -> Void = { _ in },
        onOpenTaskChat: (@MainActor (APIProjectTask) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.projectId = projectId
        self.projectName = projectName
        self.onOpenTask = onOpenTask
        self.onOpenTaskChat = onOpenTaskChat
    }

    public var body: some View {
        #if os(macOS)
        HSplitView {
            boardContent
                .frame(minWidth: 340)
            if let previewTask, let previewModel {
                TaskDetailView(
                    viewModel: previewModel,
                    projectId: projectId,
                    taskId: previewTask.id,
                    onClose: closePreview,
                    onOpenChat: onOpenTaskChat,
                    onExpand: { onOpenTask(previewTask) },
                    onOpenRelatedTask: { task in
                        openTask(ProjectKanbanCard(id: task.id, title: task.title, status: task.status, priority: task.priority, actorID: task.actorId))
                    },
                    onTaskChanged: { await viewModel.load(projectId: projectId) }
                )
                .id(previewTask.id)
                .frame(minWidth: 360, idealWidth: 480, maxWidth: 720, maxHeight: .infinity)
                .background(theme.colors.background)
                .accessibilityIdentifier("kanban-task-side-panel")
            }
        }
        .onChange(of: projectId) { _, _ in closePreview() }
        #else
        boardContent
        #endif
    }

    private func closePreview() {
        previewTask = nil
        previewModel = nil
    }

    private func openTask(_ card: ProjectKanbanCard) {
        #if os(macOS)
        guard previewTask?.id != card.id else { return }
        previewModel = viewModel.makeTaskDetailViewModel()
        previewTask = card
        #else
        onOpenTask(card)
        #endif
    }

    private var boardContent: some View {
        VStack(spacing: 0) {
            #if !os(iOS)
            boardToolbar
            #endif
            if let error = viewModel.errorMessage, !viewModel.columns.isEmpty {
                Text(error).font(.callout).foregroundStyle(theme.colors.statusBlocked)
                    .padding(.horizontal, theme.spacing.l)
            }

            #if !os(iOS)
            Rectangle()
                .fill(theme.colors.border)
                .frame(height: theme.borders.thin)
            #endif

            if viewModel.isLoading && viewModel.columns.isEmpty {
                LoadingSkeleton("Loading board…", style: .board)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = viewModel.errorMessage, viewModel.columns.isEmpty {
                boardMessage(
                    title: projectName,
                    message: errorMessage,
                    icon: "exclamationmark.triangle"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.columns.allSatisfy({ $0.items.isEmpty }) {
                emptyProjectState
            } else if filteredColumns.allSatisfy({ $0.items.isEmpty }) {
                noFilterResultsState
            } else {
                GeometryReader { geometry in
                    let contentInset = theme.spacing.l
                    let availableWidth = max(0, geometry.size.width - (contentInset * 2))
                    let availableHeight = max(0, geometry.size.height - (contentInset * 2))
                    let columnWidth = min(320, availableWidth)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: theme.spacing.m) {
                            ForEach(filteredColumns) { column in
                                ScrollView(.vertical) {
                                    kanbanColumn(column, minHeight: availableHeight, width: columnWidth)
                                }
                                .frame(width: columnWidth, height: availableHeight)
                            }
                        }
                        .frame(
                            minWidth: availableWidth,
                            minHeight: availableHeight,
                            alignment: .topLeading
                        )
                        .padding(contentInset)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(iOS)
        .searchable(
            text: $viewModel.filters.searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Filter tasks"
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    statusMenu
                    priorityMenu
                    assigneeMenu
                    if viewModel.filters.isActive {
                        Button("Reset filters", systemImage: "line.3.horizontal.decrease.circle") {
                            viewModel.filters = ProjectKanbanFilters()
                        }
                    }
                } label: {
                    Label("Task filters", systemImage: viewModel.filters.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .accessibilityIdentifier("kanban-filters")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("New Task", systemImage: "plus") {
                    isCreateTaskPresented = true
                }
                .accessibilityIdentifier("kanban-create-task")
            }
        }
        #endif
        .task(id: projectId) {
            await viewModel.load(projectId: projectId)
        }
        .task(id: viewModel.filterRevision) {
            await viewModel.updateFilteredColumns()
        }
        .sheet(isPresented: $isCreateTaskPresented) {
            ProjectTaskCreateSheet(
                viewModel: viewModel,
                projectId: projectId,
                projectName: projectName
            )
        }
    }

    private var filteredColumns: [ProjectKanbanColumn] {
        viewModel.filteredColumns
    }

    private var boardToolbar: some View {
#if os(macOS)
        boardToolbarControls
#else
        ScrollView(.horizontal, showsIndicators: false) {
            boardToolbarControls.fixedSize(horizontal: true, vertical: false)
        }
#endif
    }

    private var boardToolbarControls: some View {
        HStack(spacing: theme.spacing.s) {
            HStack(spacing: theme.spacing.s) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(theme.colors.textMuted)

                TextField("Filter tasks", text: $viewModel.filters.searchText)
                    .textFieldStyle(.plain)
                    .foregroundColor(theme.colors.textPrimary)

                if !viewModel.filters.searchText.isEmpty {
                    Button {
                        viewModel.filters.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(theme.colors.textMuted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear task search")
                }
            }
            .padding(.horizontal, 12)
            .frame(minWidth: 180, idealWidth: 250, maxWidth: 320, minHeight: 38)
            .background(
                theme.colors.surfaceRaised,
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )

            statusMenu
            priorityMenu
            assigneeMenu

            if viewModel.filters.isActive {
                Button {
                    viewModel.filters = ProjectKanbanFilters()
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.colors.accentCyan)
                .accessibilityLabel("Reset task filters")
            }

            Spacer(minLength: theme.spacing.s)

            Button {
                isCreateTaskPresented = true
            } label: {
                Label("New Task", systemImage: "plus")
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .tint(Color.accentColor)
            .accessibilityHint("Creates a task in \(projectName)")
        }
        .controlSize(.regular)
        .padding(.horizontal, theme.spacing.l)
        .padding(.vertical, 12)
        .background(theme.colors.surface)
    }

    private var statusMenu: some View {
        Menu {
            Button {
                viewModel.filters.status = .all
            } label: {
                filterMenuLabel("All statuses", selected: viewModel.filters.status == .all)
            }

            Divider()

            ForEach(ProjectKanbanColumnID.allCases, id: \.self) { columnID in
                Button {
                    viewModel.filters.status = .column(columnID)
                } label: {
                    filterMenuLabel(
                        columnID.title,
                        selected: viewModel.filters.status == .column(columnID)
                    )
                }
            }
        } label: {
            filterChip(
                icon: "circle.grid.2x2",
                title: viewModel.filters.status.title,
                isActive: viewModel.filters.status != .all
            )
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("Filter tasks by status")
    }

    private var priorityMenu: some View {
        Menu {
            ForEach(ProjectKanbanPriorityFilter.allCases) { priority in
                Button {
                    viewModel.filters.priority = priority
                } label: {
                    filterMenuLabel(
                        priority.title,
                        selected: viewModel.filters.priority == priority
                    )
                }
            }
        } label: {
            filterChip(
                icon: "exclamationmark.circle",
                title: viewModel.filters.priority.title,
                isActive: viewModel.filters.priority != .all
            )
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("Filter tasks by priority")
    }

    private var assigneeMenu: some View {
        Menu {
            Button {
                viewModel.filters.assignee = .all
            } label: {
                filterMenuLabel("All assignees", selected: viewModel.filters.assignee == .all)
            }

            Button {
                viewModel.filters.assignee = .unassigned
            } label: {
                filterMenuLabel("Unassigned", selected: viewModel.filters.assignee == .unassigned)
            }

            if !viewModel.availableActors.isEmpty {
                Divider()
            }

            ForEach(viewModel.availableActors) { actor in
                Button {
                    viewModel.filters.assignee = .actor(actor.id)
                } label: {
                    filterMenuLabel(
                        actor.title,
                        selected: viewModel.filters.assignee == .actor(actor.id)
                    )
                }
            }
        } label: {
            filterChip(
                icon: "person",
                title: viewModel.assigneeTitle(for: viewModel.filters.assignee),
                isActive: viewModel.filters.assignee != .all
            )
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("Filter tasks by assignee")
    }

    private func filterChip(icon: String, title: String, isActive: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(title)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
        }
        .font(.system(size: theme.typography.caption, weight: .medium))
        .foregroundColor(isActive ? theme.colors.accentCyan : theme.colors.textSecondary)
        .padding(.horizontal, 11)
        .frame(minHeight: 36)
        .background(
            isActive ? theme.colors.accentCyan.opacity(0.10) : theme.colors.surfaceRaised,
            in: Capsule()
        )
        .overlay {
            Capsule()
                .stroke(
                    isActive ? theme.colors.accentCyan.opacity(0.45) : theme.colors.border,
                    lineWidth: theme.borders.thin
                )
        }
    }

    @ViewBuilder
    private func filterMenuLabel(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private var emptyProjectState: some View {
        VStack(spacing: theme.spacing.m) {
            boardMessage(
                title: "No tasks yet",
                message: "Create the first task for \(projectName).",
                icon: "checklist"
            )

            Button {
                isCreateTaskPresented = true
            } label: {
                Label("Create Task", systemImage: "plus")
            }
            .buttonStyle(.glassProminent)
            .tint(Color.accentColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noFilterResultsState: some View {
        VStack(spacing: theme.spacing.m) {
            boardMessage(
                title: "No matching tasks",
                message: "Try changing or clearing the viewModel.filters.",
                icon: "line.3.horizontal.decrease.circle"
            )

            Button("Clear Filters") {
                viewModel.filters = ProjectKanbanFilters()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func boardMessage(title: String, message: String, icon: String) -> some View {
        VStack(spacing: theme.spacing.s) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundColor(theme.colors.textMuted)
            Text(title)
                .font(.system(size: theme.typography.heading, weight: .semibold))
                .foregroundColor(theme.colors.textPrimary)
            Text(message)
                .font(.system(size: theme.typography.body))
                .foregroundColor(theme.colors.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private func kanbanColumn(
        _ column: ProjectKanbanColumn,
        minHeight: CGFloat,
        width: CGFloat
    ) -> some View {
        let contentMinHeight = max(0, minHeight - (theme.spacing.m * 2))

        return LazyVStack(alignment: .leading, spacing: theme.spacing.s) {
            HStack {
                Text(column.title)
                    .font(.system(size: theme.typography.body))
                    .foregroundColor(theme.colors.textPrimary)
                Spacer(minLength: 0)
                Text("\(column.items.count)")
                    .font(.system(size: theme.typography.caption))
                    .foregroundColor(theme.colors.textMuted)
            }

            ForEach(column.items) { card in
                Button {
                    openTask(card)
                } label: {
                    ProjectKanbanCardContent(
                        card: card,
                        columnTitle: column.title,
                        assigneeTitle: card.assigneeID.map { viewModel.assigneeTitle(for: .actor($0)) },
                        instanceTitle: card.executionNodeID.map { viewModel.instanceTitle(for: $0) }
                    )
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if !viewModel.availableInstances.isEmpty {
                        Menu("Run on") {
                            ForEach(viewModel.availableInstances) { instance in
                                Button {
                                    Task {
                                        await viewModel.assignTask(
                                            id: card.id,
                                            to: instance.id,
                                            projectId: projectId
                                        )
                                    }
                                } label: {
                                    if card.executionNodeID == instance.id {
                                        Label(instance.displayName, systemImage: "checkmark")
                                    } else {
                                        Text(instance.displayName)
                                    }
                                }
                            }
                        }
                    }
                }
                .draggable(card.id)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(minHeight: contentMinHeight, alignment: .topLeading)
        .padding(theme.spacing.m)
        .frame(width: width)
        .background(theme.colors.surfaceRaised.opacity(0.82 as CGFloat))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .dropDestination(for: String.self) { taskIDs, _ in
            guard let taskID = taskIDs.first else { return false }
            Task {
                await viewModel.moveTask(id: taskID, to: column.id, projectId: projectId)
            }
            return true
        }
    }
}
