import Foundation
import Observation
import SwiftUI
import SloppyClientCore
import SloppyClientUI

@Observable
@MainActor
public final class TaskDetailViewModel {
    public private(set) var projectName: String = ""
    public private(set) var task: APIProjectTask?
    public private(set) var projectTasks: [APIProjectTask] = []
    public private(set) var availableActors: [APIAgentRecord] = []
    public let activity: TaskActivityViewModel
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?

    @ObservationIgnored private let apiClient: SloppyAPIClient

    public init(apiClient: SloppyAPIClient) {
        self.apiClient = apiClient
        self.activity = TaskActivityViewModel(api: apiClient)
    }

    public func load(projectId: String, taskId: String) async {
        isLoading = true
        task = nil
        projectTasks = []
        errorMessage = nil
        defer { isLoading = false }

        do {
            async let projectRequest = apiClient.fetchProject(id: projectId)

            let project = try await projectRequest

            try Task.checkCancellation()
            projectName = project.name
            projectTasks = project.tasks ?? []
            task = project.tasks?.first(where: { $0.id == taskId })

            if task == nil {
                errorMessage = "Could not find this task in the project."
            } else {
                errorMessage = nil
            }
        } catch is CancellationError {
            return
        } catch {
            projectName = ""
            task = nil
            projectTasks = []
            errorMessage = "Could not load task details."
        }
    }

    public func loadActors() async {
        availableActors = (try? await apiClient.fetchAgents()) ?? []
    }

    public func updateTask(projectId: String, taskId: String, request: APIProjectTaskUpdateRequest) async throws {
        let project = try await apiClient.updateProjectTask(projectId: projectId, taskId: taskId, request: request)
        projectName = project.name
        projectTasks = project.tasks ?? []
        task = projectTasks.first(where: { $0.id == taskId })
    }
}

@MainActor
public struct TaskDetailView: View {
    let viewModel: TaskDetailViewModel
    let projectId: String
    let taskId: String
    let onClose: @MainActor () -> Void
    let onOpenChat: (@MainActor (APIProjectTask) -> Void)?
    let onExpand: (@MainActor () -> Void)?
    let onOpenRelatedTask: (@MainActor (APIProjectTask) -> Void)?
    let onTaskChanged: (@MainActor () async -> Void)?

    @Environment(\.theme) private var theme
    @State private var isEditingProperties = false

    public init(
        viewModel: TaskDetailViewModel,
        projectId: String,
        taskId: String,
        onClose: @escaping @MainActor () -> Void = {},
        onOpenChat: (@MainActor (APIProjectTask) -> Void)? = nil,
        onExpand: (@MainActor () -> Void)? = nil,
        onOpenRelatedTask: (@MainActor (APIProjectTask) -> Void)? = nil,
        onTaskChanged: (@MainActor () async -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.projectId = projectId
        self.taskId = taskId
        self.onClose = onClose
        self.onOpenChat = onOpenChat
        self.onExpand = onExpand
        self.onOpenRelatedTask = onOpenRelatedTask
        self.onTaskChanged = onTaskChanged
    }

    public var body: some View {
        VStack(spacing: 0) {
            #if !os(iOS)
            closeButtonBar
            #endif

            Group {
                if viewModel.isLoading && viewModel.task == nil {
                    LoadingSkeleton("Loading task…", style: .detail)
                } else if let errorMessage = viewModel.errorMessage, viewModel.task == nil {
                    contentState(title: "Task Detail", message: errorMessage)
                } else if let task = viewModel.task {
                    ScrollView {
                        VStack(alignment: .leading, spacing: sectionSpacing) {
                            header(task: task)
                            metadata(task: task)
                            description(task: task)
                            TaskActivityView(model: viewModel.activity, projectId: projectId, task: task, projectTasks: viewModel.projectTasks, onOpenRelated: onOpenRelatedTask, onReviewChanged: {
                                    await viewModel.load(projectId: projectId, taskId: taskId)
                                    await onTaskChanged?()
                                })
                                .id(task.id)
                        }
                        .padding(contentPadding)
                        .frame(maxWidth: 920, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                } else {
                    contentState(title: "Task Detail", message: "No task data available.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, alignment: .leading, spacing: 0) {
            if let task = viewModel.task, let onOpenChat {
                Button {
                    onOpenChat(task)
                } label: {
                    Label("Open Chat", systemImage: "bubble.left.and.bubble.right")
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.glassProminent)
                .tint(theme.colors.accent)
                .controlSize(.large)
                .buttonBorderShape(.capsule)
                .contentShape(Rectangle())
                .accessibilityIdentifier("task-detail-open-chat")
                .padding(theme.spacing.l)
            }
        }
        .mobileScreenBackground()
        #if os(iOS)
        .navigationTitle(viewModel.projectName.isEmpty ? "Task" : viewModel.projectName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                editPropertiesButton
                    .disabled(viewModel.task == nil)
            }
        }
        #endif
        .task(id: "\(projectId):\(taskId)") {
            await viewModel.load(projectId: projectId, taskId: taskId)
        }
        .sheet(isPresented: $isEditingProperties) {
            if let task = viewModel.task {
                TaskPropertiesEditSheet(task: task, viewModel: viewModel, projectId: projectId) {
                    await onTaskChanged?()
                }
            }
        }
    }

    private var contentPadding: CGFloat {
        #if os(iOS)
        16
        #else
        theme.spacing.xl
        #endif
    }

    private var sectionSpacing: CGFloat {
        #if os(iOS)
        24
        #else
        theme.spacing.l
        #endif
    }

    private var sectionPadding: CGFloat {
        #if os(iOS)
        0
        #else
        theme.spacing.l
        #endif
    }

    private var editPropertiesButton: some View {
        Button("Edit", systemImage: "square.and.pencil") {
            isEditingProperties = true
        }
        .accessibilityIdentifier("task-detail-edit-properties")
    }

    private var closeButtonBar: some View {
        HStack {
            Button(action: onClose) {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(.glass)
            .keyboardShortcut(.cancelAction)
            .help("Close task details")
            .accessibilityLabel("Close task details")

            Spacer(minLength: 0)
            if let onExpand {
                Button(action: onExpand) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.plain)
                .help("Expand task")
                .accessibilityLabel("Expand task")
                .accessibilityIdentifier("task-detail-expand")
            }
        }
        .padding(.horizontal, theme.spacing.xl)
        .padding(.top, theme.spacing.l)
        .frame(maxWidth: 920)
        .frame(maxWidth: .infinity)
    }

    private func header(task: APIProjectTask) -> some View {
        VStack(alignment: .leading, spacing: theme.spacing.s) {
            #if !os(iOS)
            Text(viewModel.projectName)
                .font(.system(size: theme.typography.caption))
                .foregroundColor(theme.colors.textMuted)
            #endif

            Text(task.title)
                .font(.system(size: theme.typography.title))
                .foregroundColor(theme.colors.textPrimary)

            TaskChipFlowLayout {
                StatusBadge.forTaskStatus(task.status)

                if let priority = task.priority, !priority.isEmpty {
                    TaskPriorityChip(priority: priority)
                }
            }
        }
    }

    private func metadata(task: APIProjectTask) -> some View {
        VStack(alignment: .leading, spacing: theme.spacing.s) {
            HStack {
                Text("Properties")
                    .font(.headline)
                Spacer()
                #if !os(iOS)
                editPropertiesButton.buttonStyle(.glass)
                #endif
            }
            detailRow(label: "Task ID", value: task.id)
            detailRow(label: "Actor", value: task.actorId)
            detailRow(label: "Runs on", value: task.executionNodeId)
            detailRow(label: "Claimed By", value: task.claimedActorId ?? task.claimedAgentId)
            detailRow(label: "Created By", value: task.createdBy)
            detailRow(label: "Updated", value: task.updatedAt.map(Self.dateFormatter.string(from:)))

            if let metadata = task.externalMetadata {
                TaskExternalMetadataChips(metadata: metadata, allowsLink: true)
            }

            if let tags = task.tags, !tags.isEmpty {
                TaskTagChips(tags: tags)
            }
        }
        .padding(sectionPadding)
        #if !os(iOS)
        .background(theme.colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        #endif
    }

    @ViewBuilder
    private func description(task: APIProjectTask) -> some View {
        VStack(alignment: .leading, spacing: theme.spacing.s) {
            Text("Description")
                .font(.system(size: theme.typography.body))
                .foregroundColor(theme.colors.textPrimary)

            TaskMarkdownView(text: task.description?.isEmpty == false ? task.description! : "No description")
                .font(.system(size: theme.typography.body))
                .foregroundColor(theme.colors.textSecondary)
                .textSelection(.enabled)
        }
        .padding(sectionPadding)
        #if !os(iOS)
        .background(theme.colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        #endif
    }

    private func detailRow(label: String, value: String?) -> some View {
        HStack(alignment: .top, spacing: theme.spacing.s) {
            Text(label)
                .font(.system(size: theme.typography.caption))
                .foregroundColor(theme.colors.textMuted)
                .frame(width: 86, alignment: .leading)

            Text(value?.isEmpty == false ? value! : "—")
                .font(.system(size: theme.typography.body))
                .foregroundColor(theme.colors.textSecondary)
                .textSelection(.enabled)

            Spacer(minLength: 0)
        }
    }

    private func contentState(title: String, message: String) -> some View {
        VStack(spacing: theme.spacing.m) {
            Text(title)
                .font(.system(size: theme.typography.title))
                .foregroundColor(theme.colors.textPrimary)
            Text(message)
                .font(.system(size: theme.typography.body))
                .foregroundColor(theme.colors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
