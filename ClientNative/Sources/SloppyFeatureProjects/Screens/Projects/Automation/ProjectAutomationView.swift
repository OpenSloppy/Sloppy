import SloppyClientCore
import SloppyClientUI
import SwiftUI

@MainActor
public struct ProjectAutomationView: View {
    let viewModel: ProjectAutomationViewModel
    let projectId: String
    let projectName: String

    @Environment(\.theme) private var theme
    @State private var presentedSheet: ProjectAutomationSheet?

    public init(
        viewModel: ProjectAutomationViewModel,
        projectId: String,
        projectName: String
    ) {
        self.viewModel = viewModel
        self.projectId = projectId
        self.projectName = projectName
    }

    public var body: some View {
        VStack(spacing: 0) {
            #if !os(iOS)
            toolbar

            Rectangle()
                .fill(theme.colors.border)
                .frame(height: theme.borders.thin)
            #endif

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("New Automation", systemImage: "plus") {
                    presentedSheet = .create
                }
                .accessibilityIdentifier("project-automation-create")
            }
        }
        #endif
        .sheet(item: $presentedSheet) { _ in
            ProjectAutomationCreateSheet(
                viewModel: viewModel,
                projectId: projectId,
                projectName: projectName,
                workflows: viewModel.workflows
            )
        }
        .accessibilityIdentifier("project-automation")
    }

    private var toolbar: some View {
        HStack(spacing: theme.spacing.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Automations")
                    .font(.system(size: theme.typography.body, weight: .semibold))
                    .foregroundColor(theme.colors.textPrimary)
                Text("\(viewModel.automations.count) in \(projectName)")
                    .font(.system(size: theme.typography.caption))
                    .foregroundColor(theme.colors.textMuted)
            }

            Spacer()

            Button {
                presentedSheet = .create
            } label: {
                Label("New Automation", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("project-automation-create")

            Button {
                Task { await viewModel.load(projectId: projectId) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isLoading)
            .accessibilityIdentifier("project-automation-refresh")
        }
        .padding(.horizontal, theme.spacing.l)
        .padding(.vertical, 10)
        .background(theme.colors.surface)
    }

    @ViewBuilder
    private var content: some View {
        #if os(iOS)
        ScrollView {
            VStack(alignment: .leading, spacing: theme.spacing.m) {
                Text("\(viewModel.automations.count) automations in \(projectName)")
                    .font(.caption)
                    .foregroundStyle(theme.colors.textMuted)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                if viewModel.isLoading && viewModel.automations.isEmpty {
                    LoadingSkeleton("Loading automations…")
                } else if viewModel.automations.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: theme.spacing.m) {
                        ForEach(viewModel.automations) { automation in
                            automationCard(automation)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                if let errorMessage = viewModel.errorMessage, !viewModel.automations.isEmpty {
                    errorBanner(errorMessage)
                }
            }
            .padding(.bottom, 16)
        }
        .refreshable { await viewModel.load(projectId: projectId) }
        #else
        if viewModel.isLoading && viewModel.automations.isEmpty {
            LoadingSkeleton("Loading automations…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.automations.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 310, maximum: 460), spacing: theme.spacing.m)],
                    alignment: .leading,
                    spacing: theme.spacing.m
                ) {
                    ForEach(viewModel.automations) { automation in
                        automationCard(automation)
                    }
                }
                .padding(theme.spacing.l)
            }
            .overlay(alignment: .top) {
                if let errorMessage = viewModel.errorMessage {
                    errorBanner(errorMessage)
                        .padding(.top, theme.spacing.s)
                }
            }
        }
        #endif
    }

    private var emptyState: some View {
        VStack(spacing: theme.spacing.m) {
            Image(systemName: viewModel.errorMessage == nil ? "gearshape.2" : "exclamationmark.triangle")
                .font(.system(size: 30))
                .foregroundColor(theme.colors.textMuted)

            Text(viewModel.errorMessage == nil ? "No automations yet" : "Automations unavailable")
                .font(.system(size: theme.typography.heading, weight: .semibold))
                .foregroundColor(theme.colors.textPrimary)

            Text(viewModel.errorMessage ?? "Create the first automation for \(projectName).")
                .font(.system(size: theme.typography.body))
                .foregroundColor(theme.colors.textSecondary)
                .multilineTextAlignment(.center)

            if viewModel.errorMessage != nil {
                Button("Try Again") {
                    Task { await viewModel.load(projectId: projectId) }
                }
                .buttonStyle(.borderedProminent)
            } else {
                #if !os(iOS)
                Button {
                    presentedSheet = .create
                } label: {
                    Label("New Automation", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("project-automation-empty-create")
                #endif
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(theme.spacing.l)
    }

    private func automationCard(_ automation: ProjectAutomationDefinition) -> some View {
        VStack(alignment: .leading, spacing: theme.spacing.m) {
            HStack(alignment: .top, spacing: theme.spacing.s) {
                Image(systemName: icon(for: automation.trigger.type))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(theme.colors.accentCyan)
                    .frame(width: 36, height: 36)
                    .background(theme.colors.accentCyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 3) {
                    Text(automation.name)
                        .font(.system(size: theme.typography.body, weight: .semibold))
                        .foregroundColor(theme.colors.textPrimary)
                        .lineLimit(2)
                    Text(automation.trigger.type.title)
                        .font(.system(size: theme.typography.caption))
                        .foregroundColor(theme.colors.textSecondary)
                }

                Spacer(minLength: 4)

                statusBadge(automation.enabled ? "Enabled" : "Disabled", active: automation.enabled)
            }

            if let description = automation.description?.trimmingCharacters(in: .whitespacesAndNewlines),
               !description.isEmpty {
                Text(description)
                    .font(.system(size: theme.typography.caption))
                    .foregroundColor(theme.colors.textSecondary)
                    .lineLimit(3)
            }

            VStack(alignment: .leading, spacing: theme.spacing.xs) {
                metadataRow(icon: "arrow.triangle.branch", value: automation.workflowId)
                metadataRow(icon: "shippingbox", value: automation.repositoryFullName)

                if let run = viewModel.latestRun(for: automation.id) {
                    HStack(spacing: 6) {
                        Image(systemName: runStatusIcon(run.status))
                        Text(run.status.title)
                        Text(run.startedAt, style: .relative)
                    }
                    .font(.system(size: theme.typography.caption))
                    .foregroundColor(runStatusColor(run.status))
                }
            }

            HStack {
                Spacer()
                Button {
                    Task { await viewModel.run(automation, projectId: projectId) }
                } label: {
                    if viewModel.runningAutomationIDs.contains(automation.id) {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Run Now", systemImage: "play.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!automation.enabled || viewModel.runningAutomationIDs.contains(automation.id))
                .accessibilityIdentifier("project-automation-run-\(automation.id)")
            }
        }
        .padding(theme.spacing.m)
        .background(theme.colors.surfaceRaised.opacity(0.82), in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(theme.colors.border, lineWidth: theme.borders.thin)
        }
    }

    private func metadataRow(icon: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .frame(width: 14)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: theme.typography.caption))
        .foregroundColor(theme.colors.textMuted)
    }

    private func statusBadge(_ title: String, active: Bool) -> some View {
        Text(title)
            .font(.system(size: theme.typography.micro, weight: .semibold))
            .foregroundColor(active ? theme.colors.accentCyan : theme.colors.textMuted)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                active ? theme.colors.accentCyan.opacity(0.12) : theme.colors.surface,
                in: Capsule()
            )
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.system(size: theme.typography.caption, weight: .medium))
            .foregroundColor(theme.colors.textPrimary)
            .padding(.horizontal, theme.spacing.m)
            .padding(.vertical, theme.spacing.s)
            .background(.regularMaterial, in: Capsule())
    }

    private func icon(for trigger: ProjectAutomationTriggerKind) -> String {
        switch trigger {
        case .manual: "play.circle"
        case .cron: "calendar.badge.clock"
        case .webhook: "link"
        case .githubPullRequest: "arrow.triangle.pull"
        case .githubPullRequestReview: "text.badge.checkmark"
        }
    }

    private func runStatusIcon(_ status: ProjectAutomationRunStatus) -> String {
        switch status {
        case .queued, .waitingForWorkflow: "clock"
        case .running: "arrow.triangle.2.circlepath"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .cancelled, .ignored: "minus.circle"
        }
    }

    private func runStatusColor(_ status: ProjectAutomationRunStatus) -> Color {
        switch status {
        case .completed: theme.colors.accentCyan
        case .failed: .red
        case .queued, .running, .waitingForWorkflow: .orange
        case .cancelled, .ignored: theme.colors.textMuted
        }
    }
}

private enum ProjectAutomationSheet: String, Identifiable {
    case create

    var id: String { rawValue }
}
