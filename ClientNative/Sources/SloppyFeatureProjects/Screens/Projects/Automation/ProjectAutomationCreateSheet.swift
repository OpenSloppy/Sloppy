import SloppyClientCore
import SloppyClientUI
import SwiftUI

@MainActor
struct ProjectAutomationCreateSheet: View {
    let viewModel: ProjectAutomationViewModel
    let projectId: String
    let projectName: String
    let workflows: [ProjectAutomationWorkflowSummary]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var name = ""
    @State private var description = ""
    @State private var workflowID: String
    @State private var repositoryFullName = ""
    @State private var triggerKind = ProjectAutomationTriggerKind.manual
    @State private var schedule = ""
    @State private var webhookSecretID = ""
    @State private var githubActions = ""
    @State private var reviewStates = ""
    @State private var branchPatterns = ""
    @State private var taskMode = ProjectAutomationTaskMode.none
    @State private var model = ""
    @State private var permissionsScope = ProjectAutomationPermissionsScope.private
    @State private var enabled = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    init(
        viewModel: ProjectAutomationViewModel,
        projectId: String,
        projectName: String,
        workflows: [ProjectAutomationWorkflowSummary]
    ) {
        self.viewModel = viewModel
        self.projectId = projectId
        self.projectName = projectName
        self.workflows = workflows
        _workflowID = State(initialValue: workflows.first(where: \.enabled)?.id ?? workflows.first?.id ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .focused($focusedField, equals: .name)

                    TextField("Description (optional)", text: $description, axis: .vertical)
                        .lineLimit(2...4)

                    Toggle("Enabled", isOn: $enabled)
                } header: {
                    Text("General")
                } footer: {
                    Text("This automation will be created only for \(projectName).")
                }

                Section("Workflow") {
                    if workflows.isEmpty {
                        Label(
                            "This project has no workflows. Create one before adding an automation.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(theme.colors.textSecondary)
                    } else {
                        Picker("Workflow", selection: $workflowID) {
                            ForEach(workflows) { workflow in
                                Text(workflow.enabled ? workflow.name : "\(workflow.name) (Disabled)")
                                    .tag(workflow.id)
                            }
                        }
                    }

                    TextField("Repository (owner/repo)", text: $repositoryFullName)
                        .focused($focusedField, equals: .repository)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                }

                Section("Trigger") {
                    Picker("Type", selection: $triggerKind) {
                        ForEach(ProjectAutomationTriggerKind.allCases, id: \.self) { trigger in
                            Text(trigger.title).tag(trigger)
                        }
                    }

                    triggerConfiguration
                }

                Section("Execution") {
                    Picker("Task handling", selection: $taskMode) {
                        ForEach(ProjectAutomationTaskMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }

                    TextField("Model override (optional)", text: $model)

                    Picker("Visibility", selection: $permissionsScope) {
                        ForEach(ProjectAutomationPermissionsScope.allCases, id: \.self) { scope in
                            Text(scope.title).tag(scope)
                        }
                    }
                }

                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red)
                    }
                } else if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .mobileScreenBackground()
            .navigationTitle("New Automation")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Create")
                        }
                    }
                    .disabled(validationMessage != nil || isSaving)
                    .accessibilityIdentifier("project-automation-create-confirm")
                }
            }
            .onAppear {
                focusedField = .name
            }
        }
        #if os(macOS)
        .frame(width: 560, height: 650)
        #endif
        .accessibilityIdentifier("project-automation-create-sheet")
    }

    @ViewBuilder
    private var triggerConfiguration: some View {
        switch triggerKind {
        case .manual:
            Text("Run this automation manually from its project card.")
                .foregroundStyle(theme.colors.textSecondary)
        case .cron:
            TextField("Cron schedule", text: $schedule)
                .focused($focusedField, equals: .triggerConfiguration)
                .autocorrectionDisabled()
            Text("Example: 0 9 * * 1-5")
                .font(.caption)
                .foregroundStyle(theme.colors.textMuted)
        case .webhook:
            TextField("Secret ID", text: $webhookSecretID)
                .focused($focusedField, equals: .triggerConfiguration)
                .autocorrectionDisabled()
        case .githubPullRequest:
            TextField("Actions (comma-separated, optional)", text: $githubActions)
                .focused($focusedField, equals: .triggerConfiguration)
            TextField("Branch patterns (comma-separated, optional)", text: $branchPatterns)
        case .githubPullRequestReview:
            TextField("Review states (comma-separated, optional)", text: $reviewStates)
                .focused($focusedField, equals: .triggerConfiguration)
            TextField("Branch patterns (comma-separated, optional)", text: $branchPatterns)
        }
    }

    private var validationMessage: String? {
        if workflows.isEmpty {
            return "A project workflow is required."
        }
        if trimmed(name).isEmpty {
            return "Enter an automation name."
        }
        if workflowID.isEmpty {
            return "Select a workflow."
        }

        let repository = trimmed(repositoryFullName)
        if repository.split(separator: "/").count != 2 || repository.contains(" ") {
            return "Enter the repository as owner/repo."
        }

        switch triggerKind {
        case .cron where trimmed(schedule).isEmpty:
            return "Enter a cron schedule."
        case .webhook where trimmed(webhookSecretID).isEmpty:
            return "Enter a webhook secret ID."
        default:
            return nil
        }
    }

    private var request: ProjectAutomationDefinitionUpsertRequest {
        ProjectAutomationDefinitionUpsertRequest(
            name: trimmed(name),
            description: optional(description),
            enabled: enabled,
            workflowId: workflowID,
            repositoryFullName: trimmed(repositoryFullName),
            trigger: ProjectAutomationTrigger(type: triggerKind, config: triggerConfig),
            taskMode: taskMode,
            model: optional(model),
            permissionsScope: permissionsScope
        )
    }

    private var triggerConfig: [String: ProjectAutomationJSONValue] {
        switch triggerKind {
        case .manual:
            return [:]
        case .cron:
            return ["schedule": .string(trimmed(schedule))]
        case .webhook:
            return ["secretId": .string(trimmed(webhookSecretID))]
        case .githubPullRequest:
            return compactConfig([
                "actions": listValue(githubActions),
                "branchPatterns": listValue(branchPatterns),
            ])
        case .githubPullRequestReview:
            return compactConfig([
                "reviewStates": listValue(reviewStates),
                "branchPatterns": listValue(branchPatterns),
            ])
        }
    }

    private func save() async {
        guard validationMessage == nil else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            try await viewModel.create(request: request, projectId: projectId)
            dismiss()
        } catch let apiError as APIError {
            errorMessage = "Could not create automation (\(apiError.diagnosticDescription))."
        } catch {
            errorMessage = "Could not create automation."
        }
    }

    private func listValue(_ value: String) -> ProjectAutomationJSONValue? {
        let values = value
            .split(separator: ",")
            .map { trimmed(String($0)) }
            .filter { !$0.isEmpty }
        return values.isEmpty ? nil : .array(values.map(ProjectAutomationJSONValue.string))
    }

    private func compactConfig(
        _ values: [String: ProjectAutomationJSONValue?]
    ) -> [String: ProjectAutomationJSONValue] {
        values.reduce(into: [:]) { result, entry in
            if let value = entry.value {
                result[entry.key] = value
            }
        }
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func optional(_ value: String) -> String? {
        let value = trimmed(value)
        return value.isEmpty ? nil : value
    }

    private enum Field: Hashable {
        case name
        case repository
        case triggerConfiguration
    }
}
