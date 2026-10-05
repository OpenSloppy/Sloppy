import Observation
import SloppyClientCore
import SloppyClientUI
import SwiftUI

private enum ScheduledTaskFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case active = "Active"
    case paused = "Paused"

    var id: Self { self }
}

@Observable
@MainActor
private final class ScheduledTasksViewModel {
    let apiClient: SloppyAPIClient
    var agents: [APIAgentRecord] = []
    var tasks: [ScheduledTask] = []
    var selectedTaskID: ScheduledTask.ID?
    var isLoading = false
    var errorMessage: String?

    init(apiClient: SloppyAPIClient) {
        self.apiClient = apiClient
    }

    var selectedTask: ScheduledTask? {
        tasks.first { $0.id == selectedTaskID }
    }

    func agentName(for id: String) -> String {
        agents.first { $0.id == id }?.displayName ?? id
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let loadedAgents = try await apiClient.fetchAgents()
            let client = apiClient
            let loadedTasks = try await withThrowingTaskGroup(of: [ScheduledTask].self) { group in
                for agent in loadedAgents {
                    group.addTask {
                        try await client.fetchScheduledTasks(agentId: agent.id)
                    }
                }
                var result: [ScheduledTask] = []
                for try await agentTasks in group {
                    result.append(contentsOf: agentTasks)
                }
                let snapshot = result
                return try await ClientBackgroundWork.run { snapshot.sorted { $0.updatedAt > $1.updatedAt } }
            }
            agents = loadedAgents
            tasks = loadedTasks
            if selectedTaskID == nil || !loadedTasks.contains(where: { $0.id == selectedTaskID }) {
                selectedTaskID = loadedTasks.first?.id
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func save(_ draft: ScheduledTaskDraft) async throws {
        if let taskID = draft.taskID {
            _ = try await apiClient.updateScheduledTask(
                agentId: draft.agentID,
                taskId: taskID,
                request: ScheduledTaskUpdateRequest(
                    channelId: draft.channelID,
                    schedule: draft.schedule,
                    command: draft.command,
                    enabled: draft.enabled
                )
            )
        } else {
            _ = try await apiClient.createScheduledTask(
                agentId: draft.agentID,
                request: ScheduledTaskCreateRequest(
                    channelId: draft.channelID,
                    schedule: draft.schedule,
                    command: draft.command,
                    enabled: draft.enabled
                )
            )
        }
        await load()
    }

    func setEnabled(_ enabled: Bool, for task: ScheduledTask) async {
        do {
            _ = try await apiClient.updateScheduledTask(
                agentId: task.agentId,
                taskId: task.id,
                request: ScheduledTaskUpdateRequest(enabled: enabled)
            )
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ task: ScheduledTask) async {
        do {
            try await apiClient.deleteScheduledTask(agentId: task.agentId, taskId: task.id)
            selectedTaskID = nil
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ScheduledTaskDraft {
    var taskID: String?
    var agentID: String
    var channelID: String
    var schedule: String
    var command: String
    var enabled: Bool

    init(task: ScheduledTask? = nil, defaultAgentID: String = "") {
        taskID = task?.id
        agentID = task?.agentId ?? defaultAgentID
        channelID = task?.channelId ?? "main"
        schedule = task?.schedule ?? "0 9 * * *"
        command = task?.command ?? ""
        enabled = task?.enabled ?? true
    }
}

@MainActor
struct ScheduledTasksScreen: View {
    @State private var viewModel: ScheduledTasksViewModel
    @State private var filter: ScheduledTaskFilter = .all
    @State private var searchText = ""
    @State private var presentedDraft: ScheduledTaskDraft?
    @Environment(\.userInterfaceIdiom) private var idiom
    @Environment(\.theme) private var theme

    init(apiClient: SloppyAPIClient) {
        _viewModel = State(initialValue: ScheduledTasksViewModel(apiClient: apiClient))
    }

    private var filteredTasks: [ScheduledTask] {
        viewModel.tasks.filter { task in
            let matchesFilter = switch filter {
            case .all: true
            case .active: task.enabled
            case .paused: !task.enabled
            }
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            return matchesFilter && (query.isEmpty
                || task.command.localizedCaseInsensitiveContains(query)
                || task.schedule.localizedCaseInsensitiveContains(query)
                || viewModel.agentName(for: task.agentId).localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        Group {
            if idiom == .phone {
                compactLayout
            } else {
                desktopLayout
            }
        }
        .background(theme.colors.background)
        .task { await viewModel.load() }
        .onChange(of: filter) { _, _ in reconcileSelection() }
        .onChange(of: searchText) { _, _ in reconcileSelection() }
        .sheet(item: $presentedDraft) { draft in
            ScheduledTaskEditor(
                draft: draft,
                agents: viewModel.agents,
                onSave: { updated in try await viewModel.save(updated) }
            )
        }
    }

    private var desktopLayout: some View {
        HStack(spacing: 0) {
            taskList(navigatesToDetail: false)
                .frame(minWidth: 360, idealWidth: 420, maxWidth: 480)

            Rectangle()
                .fill(theme.colors.border)
                .frame(width: theme.borders.thin)

            detail
                .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var compactLayout: some View {
        NavigationStack {
            taskList(navigatesToDetail: true)
                .navigationDestination(for: ScheduledTask.ID.self) { taskID in
                    if let task = viewModel.tasks.first(where: { $0.id == taskID }) {
                        detail(for: task)
                    } else {
                        ScheduledTaskEmptyState(
                            title: "Task unavailable",
                            message: "This scheduled task may have been removed.",
                            systemImage: "clock.badge.exclamationmark"
                        )
                    }
                }
        }
    }

    private func taskList(navigatesToDetail: Bool) -> some View {
        let c = theme.colors
        let sp = theme.spacing

        return VStack(spacing: 0) {
            taskListHeader

            if viewModel.isLoading && viewModel.tasks.isEmpty {
                loadingList
            } else if filteredTasks.isEmpty {
                emptyListState
            } else if navigatesToDetail {
                compactTaskList
            } else {
                desktopTaskList
            }

            if let errorMessage = viewModel.errorMessage {
                errorBanner(errorMessage)
                    .padding(sp.m)
                    .padding(.top, 0)
            }
        }
        .background(c.background)
        .mobileScreenBackground()
    }

    private var taskListHeader: some View {
        let c = theme.colors
        let sp = theme.spacing
        let ty = theme.typography

        return VStack(alignment: .leading, spacing: sp.m) {
            HStack {
                VStack(alignment: .leading, spacing: sp.xs) {
                    Text("Scheduled tasks")
                        .font(.system(size: ty.heading, weight: .semibold))
                        .foregroundColor(c.textPrimary)

                    Text(taskSummary)
                        .font(.system(size: ty.caption))
                        .foregroundColor(c.textMuted)
                }

                Spacer(minLength: sp.s)

                Button {
                    presentNewTask()
                } label: {
                    Label("Create", systemImage: "plus")
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.regular)
                .tint(Color.accentColor)
                .disabled(viewModel.agents.isEmpty)
                .accessibilityHint("Creates a recurring task")
            }

            HStack(spacing: sp.s) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(c.textMuted)

                TextField("Search by task, agent, or schedule", text: $searchText)
                    .textFieldStyle(.plain)
                    .foregroundColor(c.textPrimary)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(c.textMuted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 38)
            .backportGlassEffect(
                .regular.interactive(),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )

            Picker("Task status", selection: $filter) {
                ForEach(ScheduledTaskFilter.allCases) { item in
                    Text(filterTitle(item)).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Task status filter")
        }
        .padding(sp.l)
        .background(c.surface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(c.border)
                .frame(height: theme.borders.thin)
        }
    }

    private var desktopTaskList: some View {
        List(filteredTasks, selection: $viewModel.selectedTaskID) { task in
            ScheduledTaskRow(
                task: task,
                agentName: viewModel.agentName(for: task.agentId),
                isSelected: viewModel.selectedTaskID == task.id
            )
            .tag(task.id)
            .listRowInsets(.init(top: 5, leading: 12, bottom: 5, trailing: 12))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(theme.colors.background)
        .environment(\.defaultMinListRowHeight, 1)
    }

    private var compactTaskList: some View {
        List(filteredTasks) { task in
            NavigationLink(value: task.id) {
                ScheduledTaskRow(
                    task: task,
                    agentName: viewModel.agentName(for: task.agentId),
                    isSelected: false
                )
            }
            .buttonStyle(.plain)
            .listRowInsets(.init(top: 5, leading: 12, bottom: 5, trailing: 12))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(theme.colors.background)
        .environment(\.defaultMinListRowHeight, 1)
    }

    private var loadingList: some View {
        List(0..<4, id: \.self) { _ in
            ScheduledTaskLoadingRow()
                .listRowInsets(.init(top: 5, leading: 12, bottom: 5, trailing: 12))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(theme.colors.background)
        .redacted(reason: .placeholder)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading scheduled tasks")
    }

    private var emptyListState: some View {
        let hasTasks = !viewModel.tasks.isEmpty
        let hasAgents = !viewModel.agents.isEmpty
        let hasQuery = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let title = if hasTasks {
            "No matching tasks"
        } else if hasAgents {
            "No scheduled tasks"
        } else {
            "No agents available"
        }
        let message = if hasTasks {
            "Adjust the search or status filter to see more results."
        } else if hasAgents {
            "Create a recurring task and Sloppy will run it automatically."
        } else {
            "Connect or create an agent before scheduling recurring work."
        }

        return ScheduledTaskEmptyState(
            title: title,
            message: message,
            systemImage: hasQuery ? "magnifyingglass" : (hasAgents ? "calendar.badge.plus" : "person.crop.circle.badge.plus"),
            actionTitle: hasTasks ? "Clear filters" : (hasAgents ? "Create task" : nil),
            action: hasTasks ? clearFilters : presentNewTask
        )
    }

    private func errorBanner(_ message: String) -> some View {
        let c = theme.colors
        let sp = theme.spacing
        let ty = theme.typography

        return HStack(alignment: .center, spacing: sp.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(c.statusWarning)

            Text(message)
                .font(.system(size: ty.caption))
                .foregroundColor(c.textSecondary)
                .lineLimit(2)

            Spacer(minLength: 0)

            Button("Retry") {
                Task { await viewModel.load() }
            }
            .buttonStyle(.plain)
            .font(.system(size: ty.caption, weight: .semibold))
            .foregroundColor(c.accentCyan)

            Button {
                viewModel.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundColor(c.textMuted)
            .accessibilityLabel("Dismiss error")
        }
        .padding(sp.s)
        .background(c.statusWarning.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(c.statusWarning.opacity(0.28), lineWidth: theme.borders.thin)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let task = viewModel.selectedTask {
            detail(for: task)
        } else {
            ScheduledTaskEmptyState(
                title: "Select a scheduled task",
                message: "Choose a task to review its schedule, delivery channel, and controls.",
                systemImage: "clock.arrow.circlepath"
            )
        }
    }

    private func detail(for task: ScheduledTask) -> some View {
        ScheduledTaskDetail(
            task: task,
            agentName: viewModel.agentName(for: task.agentId),
            onEdit: { presentedDraft = ScheduledTaskDraft(task: task) },
            onToggle: { enabled in Task { await viewModel.setEnabled(enabled, for: task) } },
            onDelete: { Task { await viewModel.delete(task) } }
        )
    }

    private var taskSummary: String {
        guard !viewModel.tasks.isEmpty else { return "Automate recurring work" }
        let activeCount = viewModel.tasks.filter(\.enabled).count
        return "\(activeCount) active · \(viewModel.tasks.count - activeCount) paused"
    }

    private func filterTitle(_ item: ScheduledTaskFilter) -> String {
        let count = switch item {
        case .all: viewModel.tasks.count
        case .active: viewModel.tasks.filter(\.enabled).count
        case .paused: viewModel.tasks.filter { !$0.enabled }.count
        }
        return "\(item.rawValue) \(count)"
    }

    private func presentNewTask() {
        presentedDraft = ScheduledTaskDraft(defaultAgentID: viewModel.agents.first?.id ?? "")
    }

    private func clearFilters() {
        searchText = ""
        filter = .all
    }

    private func reconcileSelection() {
        guard idiom != .phone else { return }
        if let selectedTaskID = viewModel.selectedTaskID,
           filteredTasks.contains(where: { $0.id == selectedTaskID }) {
            return
        }
        viewModel.selectedTaskID = filteredTasks.first?.id
    }
}

private struct ScheduledTaskEmptyState: View {
    let title: String
    let message: String
    let systemImage: String
    var actionTitle: String?
    var action: (() -> Void)?

    @Environment(\.theme) private var theme

    init(
        title: String,
        message: String,
        systemImage: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        let c = theme.colors
        let sp = theme.spacing
        let ty = theme.typography

        return VStack(spacing: sp.m) {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .medium))
                .foregroundColor(c.accentCyan)
                .frame(width: 58, height: 58)
                .backportGlassEffect(
                    .regular.tint(c.accentCyan.opacity(0.14)),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )

            VStack(spacing: sp.s) {
                Text(title)
                    .font(.system(size: ty.heading, weight: .semibold))
                    .foregroundColor(c.textPrimary)

                Text(message)
                    .font(.system(size: ty.body))
                    .foregroundColor(c.textMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .tint(Color.accentColor)
            }
        }
        .padding(sp.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(c.background)
    }
}

private struct ScheduledTaskLoadingRow: View {
    @Environment(\.theme) private var theme

    var body: some View {
        let c = theme.colors
        let sp = theme.spacing

        return HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(c.surfaceRaised)
                .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: sp.s) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(c.surfaceRaised)
                    .frame(width: 190, height: 12)
                RoundedRectangle(cornerRadius: 4)
                    .fill(c.surfaceRaised)
                    .frame(width: 145, height: 9)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(c.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct ScheduledTaskRow: View {
    let task: ScheduledTask
    let agentName: String
    let isSelected: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        let c = theme.colors
        let sp = theme.spacing
        let ty = theme.typography
        let statusColor = task.enabled ? c.statusDone : c.statusNeutral

        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: task.enabled ? "clock.arrow.circlepath" : "pause.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(statusColor)
                .frame(width: 38, height: 38)
                .background(statusColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: sp.s) {
                    Text(task.command)
                        .font(.system(size: ty.body, weight: .semibold))
                        .foregroundColor(c.textPrimary)
                        .lineLimit(2)

                    Spacer(minLength: 0)

                    HStack(spacing: 5) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 6, height: 6)
                        Text(task.enabled ? "Active" : "Paused")
                    }
                    .font(.system(size: ty.micro, weight: .medium))
                    .foregroundColor(statusColor)
                }

                Label(CronDescription.describe(task.schedule), systemImage: "calendar")
                    .font(.system(size: ty.caption))
                    .foregroundColor(c.textSecondary)
                    .lineLimit(1)

                Text("\(agentName) · #\(task.channelId)")
                    .font(.system(size: ty.caption))
                    .foregroundColor(c.textMuted)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected ? Color.accentColor.opacity(0.13) : c.surface,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.50) : c.border, lineWidth: theme.borders.thin)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(task.command), \(task.enabled ? "active" : "paused"), \(CronDescription.describe(task.schedule))"
        )
    }
}

private struct ScheduledTaskDetail: View {
    let task: ScheduledTask
    let agentName: String
    let onEdit: () -> Void
    let onToggle: (Bool) -> Void
    let onDelete: () -> Void

    @State private var isConfirmingDelete = false
    @Environment(\.theme) private var theme

    var body: some View {
        let c = theme.colors
        let sp = theme.spacing
        let ty = theme.typography
        let statusColor = task.enabled ? c.statusDone : c.statusNeutral

        return ScrollView {
            VStack(alignment: .leading, spacing: sp.l) {
                VStack(alignment: .leading, spacing: sp.m) {
                    HStack(alignment: .top, spacing: sp.m) {
                        Image(systemName: task.enabled ? "clock.arrow.circlepath" : "pause.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(statusColor)
                            .frame(width: 52, height: 52)
                            .background(
                                statusColor.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                            )

                        VStack(alignment: .leading, spacing: 6) {
                            Text("SCHEDULED TASK")
                                .font(.system(size: ty.micro, weight: .semibold))
                                .foregroundColor(c.textMuted)
                                .tracking(0.8)

                            Text(task.command)
                                .font(.system(size: ty.title, weight: .semibold))
                                .foregroundColor(c.textPrimary)
                                .textSelection(.enabled)

                            StatusBadge(task.enabled ? "Active" : "Paused", color: statusColor)
                        }

                        Spacer(minLength: 0)
                    }

                    HStack(spacing: sp.s) {
                        Button {
                            onToggle(!task.enabled)
                        } label: {
                            Label(
                                task.enabled ? "Pause" : "Resume",
                                systemImage: task.enabled ? "pause.fill" : "play.fill"
                            )
                        }
                        .buttonStyle(.glass)

                        Button(action: onEdit) {
                            Label("Edit", systemImage: "pencil")
                        }
                        .buttonStyle(.glassProminent)
                        .tint(Color.accentColor)

                        Menu {
                            Button("Delete task", systemImage: "trash", role: .destructive) {
                                isConfirmingDelete = true
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(width: 20)
                        }
                        .accessibilityLabel("More task actions")

                        Spacer(minLength: 0)
                    }
                    .controlSize(.large)
                }

                scheduleCard

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 180), spacing: sp.m)],
                    spacing: sp.m
                ) {
                    ScheduledTaskInfoCard(
                        title: "Agent",
                        value: agentName,
                        systemImage: "person.crop.circle",
                        accent: c.accentCyan
                    )
                    ScheduledTaskInfoCard(
                        title: "Channel",
                        value: "#\(task.channelId)",
                        systemImage: "number",
                        accent: Color.accentColor
                    )
                    ScheduledTaskInfoCard(
                        title: "Updated",
                        value: task.updatedAt.formatted(date: .abbreviated, time: .shortened),
                        systemImage: "arrow.triangle.2.circlepath",
                        accent: c.statusWarning
                    )
                }

                HStack(spacing: sp.s) {
                    Label(
                        "Created \(task.createdAt.formatted(date: .abbreviated, time: .shortened))",
                        systemImage: "calendar.badge.plus"
                    )
                    Text("·")
                    Text("ID \(task.id)")
                        .textSelection(.enabled)
                }
                .font(.system(size: ty.caption))
                .foregroundColor(c.textMuted)
            }
            .padding(sp.xl)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(c.background)
        .confirmationDialog(
            "Delete this scheduled task?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete task", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
    }

    private var scheduleCard: some View {
        let c = theme.colors
        let sp = theme.spacing
        let ty = theme.typography

        return HStack(alignment: .top, spacing: sp.m) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(c.accentCyan)
                .frame(width: 44, height: 44)
                .background(
                    c.accentCyan.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 7) {
                Text("Schedule")
                    .font(.system(size: ty.caption, weight: .semibold))
                    .foregroundColor(c.textMuted)

                Text(CronDescription.describe(task.schedule))
                    .font(.system(size: ty.heading, weight: .semibold))
                    .foregroundColor(c.textPrimary)

                Text(task.schedule)
                    .font(.system(size: ty.caption, design: .monospaced))
                    .foregroundColor(c.textSecondary)
                    .padding(.horizontal, sp.s)
                    .padding(.vertical, sp.xs)
                    .background(c.surfaceRaised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)
        }
        .padding(sp.l)
        .background(c.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(c.border, lineWidth: theme.borders.thin)
        }
    }
}

private struct ScheduledTaskInfoCard: View {
    let title: String
    let value: String
    let systemImage: String
    let accent: Color

    @Environment(\.theme) private var theme

    var body: some View {
        let c = theme.colors
        let sp = theme.spacing
        let ty = theme.typography

        return VStack(alignment: .leading, spacing: sp.m) {
            HStack {
                Image(systemName: systemImage)
                    .foregroundColor(accent)
                Spacer(minLength: 0)
                Text(title.uppercased())
                    .font(.system(size: ty.micro, weight: .semibold))
                    .foregroundColor(c.textMuted)
                    .tracking(0.6)
            }

            Text(value)
                .font(.system(size: ty.body, weight: .medium))
                .foregroundColor(c.textPrimary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .padding(sp.m)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
        .background(c.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(c.border, lineWidth: theme.borders.thin)
        }
    }
}

private struct CronScheduleEditor: View {
    @Binding var expression: String
    @State private var configuration: CronScheduleConfiguration
    @State private var isAdvancedExpanded: Bool
    @Environment(\.theme) private var theme

    init(expression: Binding<String>) {
        _expression = expression
        let configuration = CronScheduleConfiguration(expression: expression.wrappedValue)
        _configuration = State(initialValue: configuration)
        _isAdvancedExpanded = State(initialValue: configuration.mode == .custom)
    }

    var body: some View {
        Picker("Repeat", selection: modeBinding) {
            ForEach(CronScheduleConfiguration.Mode.allCases, id: \.self) { mode in
                Text(mode.title).tag(mode)
            }
        }

        switch configuration.mode {
        case .daily, .weekdays, .weekly:
            DatePicker("Time", selection: timeBinding, displayedComponents: .hourAndMinute)

            if configuration.mode == .weekdays {
                LabeledContent("On", value: "Monday through Friday")
            } else if configuration.mode == .weekly {
                weekdayPicker
            }
        case .interval:
            Picker("Every", selection: intervalBinding) {
                ForEach(intervalOptions, id: \.self) { minutes in
                    Text(intervalTitle(minutes)).tag(minutes)
                }
            }
        case .custom:
            cronExpressionField
        }

        LabeledContent("Runs") {
            Text(configuration.summary)
                .foregroundStyle(configuration.isValid ? theme.colors.textSecondary : theme.colors.statusBlocked)
                .multilineTextAlignment(.trailing)
        }

        if configuration.mode != .custom {
            DisclosureGroup("Advanced", isExpanded: $isAdvancedExpanded) {
                cronExpressionField
                    .padding(.top, theme.spacing.s)
            }
        }

        if !configuration.isValid {
            Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(theme.colors.statusBlocked)
                .accessibilityIdentifier("cron-schedule-validation")
        }
    }

    private var weekdayPicker: some View {
        VStack(alignment: .leading, spacing: theme.spacing.s) {
            Text("Days")
                .font(.caption)
                .foregroundStyle(theme.colors.textSecondary)

            HStack(spacing: theme.spacing.xs) {
                ForEach(CronScheduleConfiguration.Weekday.allCases) { weekday in
                    Toggle(isOn: weekdayBinding(weekday)) {
                        Text(weekday.shortName)
                            .frame(maxWidth: .infinity)
                    }
                    .toggleStyle(.button)
                    .tint(theme.colors.accentCyan)
                    .accessibilityLabel(weekday.name)
                    .accessibilityValue(configuration.weekdays.contains(weekday) ? "Selected" : "Not selected")
                }
            }
        }
    }

    private var cronExpressionField: some View {
        TextField("Cron expression", text: rawExpressionBinding)
            .font(.system(.body, design: .monospaced))
            .accessibilityHint("Five fields: minute, hour, day, month, and weekday")
    }

    private var modeBinding: Binding<CronScheduleConfiguration.Mode> {
        Binding(
            get: { configuration.mode },
            set: { mode in
                configuration.mode = mode
                if mode == .weekly, configuration.weekdays.isEmpty {
                    configuration.weekdays = [.monday]
                }
                if mode == .custom {
                    configuration.customExpression = expression
                    isAdvancedExpanded = true
                }
                updateExpression()
            }
        )
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                var components = DateComponents()
                components.calendar = Calendar.current
                components.year = 2001
                components.month = 1
                components.day = 1
                components.hour = configuration.hour
                components.minute = configuration.minute
                return components.date ?? Date()
            },
            set: { date in
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                configuration.hour = components.hour ?? 0
                configuration.minute = components.minute ?? 0
                updateExpression()
            }
        )
    }

    private var rawExpressionBinding: Binding<String> {
        Binding(
            get: { expression },
            set: { newValue in
                expression = newValue
                configuration = CronScheduleConfiguration(expression: newValue)
            }
        )
    }

    private var intervalOptions: [Int] {
        let defaults = [5, 10, 15, 30, 60, 120, 180, 360, 720]
        return Array(Set(defaults + [configuration.intervalMinutes])).filter { $0 > 0 }.sorted()
    }

    private var intervalBinding: Binding<Int> {
        Binding(
            get: { configuration.intervalMinutes },
            set: { minutes in
                configuration.intervalMinutes = minutes
                updateExpression()
            }
        )
    }

    private var validationMessage: String {
        configuration.mode == .weekly
            ? "Select at least one day."
            : "Enter a supported five-field cron expression."
    }

    private func weekdayBinding(_ weekday: CronScheduleConfiguration.Weekday) -> Binding<Bool> {
        Binding(
            get: { configuration.weekdays.contains(weekday) },
            set: { isSelected in
                if isSelected {
                    configuration.weekdays.insert(weekday)
                } else {
                    configuration.weekdays.remove(weekday)
                }
                updateExpression()
            }
        )
    }

    private func intervalTitle(_ minutes: Int) -> String {
        if minutes == 60 { return "Hour" }
        if minutes.isMultiple(of: 60) { return "\(minutes / 60) hours" }
        return "\(minutes) minutes"
    }

    private func updateExpression() {
        expression = configuration.expression
    }
}

private extension CronScheduleConfiguration.Mode {
    var title: String {
        switch self {
        case .daily: "Daily"
        case .weekdays: "Weekdays"
        case .weekly: "Selected days"
        case .interval: "Interval"
        case .custom: "Custom"
        }
    }
}

private struct ScheduledTaskEditor: View {
    @State var draft: ScheduledTaskDraft
    let agents: [APIAgentRecord]
    let onSave: (ScheduledTaskDraft) async throws -> Void
    @State private var isSaving = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.userInterfaceIdiom) private var idiom
    @Environment(\.theme) private var theme

    var body: some View {
        let c = theme.colors
        let sp = theme.spacing
        let ty = theme.typography

        return VStack(spacing: 0) {
            HStack(spacing: sp.m) {
                Image(systemName: draft.taskID == nil ? "clock.badge.plus" : "clock.arrow.circlepath")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(c.accentCyan)
                    .frame(width: 44, height: 44)
                    .background(
                        c.accentCyan.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: sp.xs) {
                    Text(draft.taskID == nil ? "Create scheduled task" : "Edit scheduled task")
                        .font(.system(size: ty.heading, weight: .semibold))
                        .foregroundColor(c.textPrimary)

                    Text("Choose when Sloppy should run this task and where to deliver it.")
                        .font(.system(size: ty.caption))
                        .foregroundColor(c.textMuted)
                }

                Spacer(minLength: 0)
            }
            .padding(sp.l)

            Divider()

            Form {
                Section("Task") {
                    TextField("What should Sloppy do?", text: $draft.command, axis: .vertical)
                        .lineLimit(3...7)
                }

                Section("Delivery") {
                    Picker("Agent", selection: $draft.agentID) {
                        ForEach(agents) { agent in
                            Text(agent.displayName).tag(agent.id)
                        }
                    }
                    TextField("Channel", text: $draft.channelID)
                }

                Section("Schedule") {
                    CronScheduleEditor(expression: $draft.schedule)

                    Toggle("Task is active", isOn: $draft.enabled)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: ty.caption))
                    .foregroundColor(c.statusBlocked)
                    .padding(.horizontal, sp.l)
                    .padding(.bottom, sp.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack(spacing: sp.s) {
                Spacer()

                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button {
                    save()
                } label: {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(draft.taskID == nil ? "Create task" : "Save changes")
                    }
                }
                .buttonStyle(.glassProminent)
                .tint(Color.accentColor)
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || !isDraftValid)
            }
            .controlSize(.large)
            .padding(sp.l)
        }
        .background(c.background)
        .frame(
            minWidth: idiom == .phone ? nil : 480,
            idealWidth: idiom == .phone ? nil : 560,
            maxWidth: idiom == .phone ? .infinity : 620,
            minHeight: idiom == .phone ? nil : 560,
            idealHeight: idiom == .phone ? nil : 640
        )
        .mobileScreenBackground()
    }

    private var isDraftValid: Bool {
        !draft.agentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.channelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && CronScheduleConfiguration(expression: draft.schedule).isValid
            && !draft.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        isSaving = true
        errorMessage = nil

        Task {
            do {
                try await onSave(draft)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}

extension ScheduledTaskDraft: Identifiable {
    var id: String { taskID ?? "new" }
}

private enum CronDescription {
    static func describe(_ expression: String) -> String {
        CronScheduleConfiguration.describe(expression)
    }
}

private extension ScheduledTask {
    static var preview: ScheduledTask {
        ScheduledTask(
            id: "daily-brief",
            agentId: "codex",
            channelId: "main",
            schedule: "0 9 * * 1",
            command: "Prepare a concise weekly project brief",
            enabled: true,
            createdAt: Date().addingTimeInterval(-86_400),
            updatedAt: Date().addingTimeInterval(-300)
        )
    }
}

#Preview("Scheduled Screen") {
    ScheduledTasksScreen(apiClient: SloppyAPIClient(baseURL: .debugURL))
        .frame(width: 1100, height: 720)
}

#Preview("Scheduled Row") {
    ScheduledTaskRow(task: .preview, agentName: "Codex", isSelected: true)
        .frame(width: 420)
        .padding()
}

#Preview("Scheduled Detail — Dark") {
    ScheduledTaskDetail(
        task: .preview,
        agentName: "Codex",
        onEdit: {},
        onToggle: { _ in },
        onDelete: {}
    )
    .theme(.sloppyDark)
    .frame(width: 700, height: 660)
}

#Preview("Scheduled Detail — Light") {
    ScheduledTaskDetail(
        task: .preview,
        agentName: "Codex",
        onEdit: {},
        onToggle: { _ in },
        onDelete: {}
    )
    .theme(.sloppyLight)
    .frame(width: 700, height: 660)
}

#Preview("Scheduled Editor") {
    ScheduledTaskEditor(
        draft: ScheduledTaskDraft(task: .preview),
        agents: [APIAgentRecord(id: "codex", displayName: "Codex")],
        onSave: { _ in }
    )
}
