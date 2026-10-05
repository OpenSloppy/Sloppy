import SwiftUI
import SloppyClientCore
import SloppyClientUI

@MainActor
struct ProjectTaskCreateSheet: View {
    private enum TaskStatus: String, CaseIterable, Identifiable {
        case backlog
        case ready
        case inProgress = "in_progress"
        case needsReview = "needs_review"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .backlog: "Backlog"
            case .ready: "Ready"
            case .inProgress: "In Progress"
            case .needsReview: "Needs Review"
            }
        }
    }

    private enum TaskPriority: String, CaseIterable, Identifiable {
        case high
        case medium
        case low

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    let viewModel: ProjectKanbanViewModel
    let projectId: String
    let projectName: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var title = ""
    @State private var taskDescription = ""
    @State private var status = TaskStatus.backlog
    @State private var priority = TaskPriority.medium
    @State private var actorID = ""
    @State private var executionNodeID: String
    @State private var tags = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var isTitleFocused: Bool

    private var canCreate: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !executionNodeID.isEmpty
            && !isSaving
    }

    init(viewModel: ProjectKanbanViewModel, projectId: String, projectName: String) {
        self.viewModel = viewModel
        self.projectId = projectId
        self.projectName = projectName
        _executionNodeID = State(initialValue: viewModel.preferredExecutionNodeID)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Task in \(projectName)") {
                    TextField("Title", text: $title)
                        .focused($isTitleFocused)

                    TextField("Description", text: $taskDescription, axis: .vertical)
                        .lineLimit(3...7)
                }

                Section("Planning") {
                    Picker("Status", selection: $status) {
                        ForEach(TaskStatus.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }

                    Picker("Priority", selection: $priority) {
                        ForEach(TaskPriority.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }

                    Picker("Assignee", selection: $actorID) {
                        Text("Unassigned").tag("")
                        ForEach(viewModel.availableActors) { actor in
                            Text(actor.title).tag(actor.id)
                        }
                    }

                    Picker("Runs on", selection: $executionNodeID) {
                        ForEach(viewModel.availableInstances) { instance in
                            Text(instance.displayName).tag(instance.id)
                        }
                    }
                }

                Section {
                    TextField("frontend, bug, release", text: $tags)
                } header: {
                    Text("Tags")
                } footer: {
                    Text("Separate tags with commas.")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(theme.colors.statusBlocked)
                    }
                }
            }
            .formStyle(.grouped)
            .mobileScreenBackground()
            .navigationTitle("New Task")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isSaving)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        createTask()
                    } label: {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Create")
                        }
                    }
                    .disabled(!canCreate)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 500)
        .interactiveDismissDisabled(isSaving)
        .task {
            isTitleFocused = true
        }
    }

    private func createTask() {
        guard canCreate else { return }
        isSaving = true
        errorMessage = nil

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = taskDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedTags = tags
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        Task {
            do {
                try await viewModel.createTask(
                    projectId: projectId,
                    request: APIProjectTaskCreateRequest(
                        title: trimmedTitle,
                        description: trimmedDescription.isEmpty ? nil : trimmedDescription,
                        priority: priority.rawValue,
                        status: status.rawValue,
                        actorId: actorID.isEmpty ? nil : actorID,
                        executionNodeId: executionNodeID,
                        tags: parsedTags.isEmpty ? nil : parsedTags
                    )
                )
                dismiss()
            } catch let error as APIError {
                errorMessage = error.taskCreationMessage
                isSaving = false
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}

private extension APIError {
    var taskCreationMessage: String {
        switch self {
        case .invalidResponse:
            "Core returned an invalid response."
        case let .httpError(statusCode, body):
            body?.isEmpty == false ? body! : "Core returned HTTP \(statusCode)."
        case let .decodingFailed(message):
            message
        }
    }
}
