import SwiftUI
import SloppyClientCore
import SloppyClientUI

struct TaskPropertiesDraft: Equatable {
    var title: String
    var description: String
    var status: String
    var priority: String
    var actorId: String
    var executionNodeId: String
    var tags: String

    init(task: APIProjectTask) {
        title = task.title
        description = task.description ?? ""
        status = task.status
        priority = task.priority ?? ""
        actorId = task.actorId ?? ""
        executionNodeId = task.executionNodeId ?? ""
        tags = (task.tags ?? []).joined(separator: ", ")
    }

    var normalizedTags: [String] {
        tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func updateRequest(comparedTo task: APIProjectTask) -> APIProjectTaskUpdateRequest {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let actorId = actorId.trimmingCharacters(in: .whitespacesAndNewlines)
        let executionNodeId = executionNodeId.trimmingCharacters(in: .whitespacesAndNewlines)
        return APIProjectTaskUpdateRequest(
            title: title == task.title ? nil : title,
            description: description == (task.description ?? "") ? nil : description,
            priority: priority.isEmpty || priority == task.priority ? nil : priority,
            status: status == task.status ? nil : status,
            actorId: actorId == (task.actorId ?? "") ? nil : actorId,
            executionNodeId: executionNodeId == (task.executionNodeId ?? "") ? nil : executionNodeId,
            tags: normalizedTags == (task.tags ?? []) ? nil : normalizedTags
        )
    }
}

@MainActor
struct TaskPropertiesEditSheet: View {
    let task: APIProjectTask
    let viewModel: TaskDetailViewModel
    let projectId: String
    let onSaved: @MainActor () async -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var draft: TaskPropertiesDraft
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var isTitleFocused: Bool

    private let statuses = [
        ("pending_approval", "Pending approval"), ("backlog", "Backlog"),
        ("ready", "Ready"), ("in_progress", "In progress"),
        ("waiting_input", "Waiting for input"), ("needs_review", "Needs review"),
        ("blocked", "Blocked"), ("done", "Done"), ("cancelled", "Cancelled")
    ]

    init(task: APIProjectTask, viewModel: TaskDetailViewModel, projectId: String,
         onSaved: @escaping @MainActor () async -> Void) {
        self.task = task
        self.viewModel = viewModel
        self.projectId = projectId
        self.onSaved = onSaved
        _draft = State(initialValue: TaskPropertiesDraft(task: task))
    }

    private var canSave: Bool {
        guard !isSaving, !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let request = draft.updateRequest(comparedTo: task)
        return request.title != nil || request.description != nil || request.priority != nil
            || request.status != nil || request.actorId != nil || request.executionNodeId != nil
            || request.tags != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Task") {
                    TextField("Title", text: $draft.title)
                        .focused($isTitleFocused)
                    TextField("Description", text: $draft.description, axis: .vertical)
                        .lineLimit(4...10)
                }
                Section("Planning") {
                    Picker("Status", selection: $draft.status) {
                        if !statuses.contains(where: { $0.0 == task.status }) {
                            Text(task.status).tag(task.status)
                        }
                        ForEach(statuses, id: \.0) { status in
                            Text(status.1).tag(status.0)
                        }
                    }
                    Picker("Priority", selection: $draft.priority) {
                        if task.priority == nil {
                            Text("Not set").tag("")
                        }
                        if !["high", "medium", "low"].contains(task.priority ?? "medium") {
                            Text(task.priority ?? "").tag(task.priority ?? "")
                        }
                        Text("High").tag("high")
                        Text("Medium").tag("medium")
                        Text("Low").tag("low")
                    }
                    Picker("Actor", selection: $draft.actorId) {
                        Text("Unassigned").tag("")
                        if !draft.actorId.isEmpty && !viewModel.availableActors.contains(where: { $0.id == draft.actorId }) {
                            Text(draft.actorId).tag(draft.actorId)
                        }
                        ForEach(viewModel.availableActors) { actor in
                            Text(actor.displayName).tag(actor.id)
                        }
                    }
                    TextField("Runs on (node ID)", text: $draft.executionNodeId)
                }
                Section("Tags") {
                    TextField("frontend, bug, release", text: $draft.tags)
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(theme.colors.statusBlocked)
                    }
                }
            }
            .formStyle(.grouped)
            .mobileScreenBackground()
            .navigationTitle("Edit Task Properties")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 520)
        .interactiveDismissDisabled(isSaving)
        .task { await viewModel.loadActors() }
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        errorMessage = nil
        let request = draft.updateRequest(comparedTo: task)
        Task {
            do {
                try await viewModel.updateTask(projectId: projectId, taskId: task.id, request: request)
                await onSaved()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}
