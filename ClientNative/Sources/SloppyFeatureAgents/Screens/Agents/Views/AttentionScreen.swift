import SwiftUI
import SloppyClientCore
import SloppyClientUI

@MainActor
public struct AttentionScreen: View {
    private let inbox: AttentionInbox
    @Environment(\.theme) private var theme
    @State private var showHistory = false

    public init(inbox: AttentionInbox) {
        self.inbox = inbox
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let findings = inbox.findings.filter { showHistory || $0.isActiveAttention(at: timeline.date) }
            VStack(spacing: 0) {
                header
                GeometryReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: theme.spacing.l) {
                            ForEach(inbox.errors, id: \.self) { error in
                                Label(error, systemImage: "exclamationmark.triangle")
                                    .font(.subheadline)
                                    .foregroundStyle(theme.colors.textSecondary)
                                    .accessibilityIdentifier("attention.error")
                            }
                            if !inbox.hasLoaded && inbox.isLoading {
                                loadingState
                            } else if findings.isEmpty && inbox.errors.isEmpty {
                                emptyState
                            } else {
                                LazyVStack(alignment: .leading, spacing: theme.spacing.l) {
                                    ForEach(findings) { finding in
                                        findingRow(finding, at: timeline.date)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: 960)
                        .frame(minHeight: max(0, proxy.size.height - theme.spacing.l * 2),
                               alignment: findings.isEmpty && inbox.errors.isEmpty ? .center : .top)
                        .padding(theme.spacing.l)
                        .frame(maxWidth: .infinity)
                    }
                    .refreshable { await inbox.refresh() }
                }
            }
        }
        .foregroundStyle(theme.colors.textPrimary)
        .background(theme.colors.background.ignoresSafeArea())
        .mobileScreenBackground()
        .task { await inbox.refresh() }
        .navigationTitle("Attention")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("attention.screen")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: theme.spacing.s) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: theme.spacing.m) {
                    title
                    Spacer(minLength: theme.spacing.m)
                    headerActions
                }
                VStack(alignment: .leading, spacing: theme.spacing.m) {
                    title
                    HStack {
                        headerActions
                        Spacer(minLength: 0)
                    }
                }
            }
            if inbox.lastCheckedAt != nil || inbox.pendingAnalysisCount > 0 {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: theme.spacing.m) { refreshStatus }
                    VStack(alignment: .leading, spacing: theme.spacing.xs) { refreshStatus }
                }
                .font(.caption)
                .foregroundStyle(theme.colors.textMuted)
            }
        }
        .padding(.horizontal, theme.spacing.l)
        .padding(.vertical, theme.spacing.m)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.colors.border).frame(height: theme.borders.thin)
        }
    }

    private var title: some View {
        Text("Attention")
            .font(.system(size: theme.typography.heading, weight: .medium))
            .fixedSize()
    }

    private var headerActions: some View {
        HStack(spacing: theme.spacing.s) {
            HStack(spacing: theme.spacing.xs) {
                filterButton("Active", history: false)
                filterButton("All history", history: true)
            }
            .padding(theme.spacing.xs)
            .background(theme.colors.surface, in: Capsule())
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Finding history")
            .accessibilityIdentifier("attention.filter")

            Button { Task { await inbox.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .disabled(inbox.isLoading)
            .help("Refresh attention")
            .accessibilityLabel("Refresh attention")
            .accessibilityIdentifier("attention.refresh")
        }
    }

    private func filterButton(_ label: String, history: Bool) -> some View {
        Button { showHistory = history } label: {
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(showHistory == history ? theme.colors.textPrimary : theme.colors.textMuted)
                .padding(.horizontal, theme.spacing.m)
                .padding(.vertical, theme.spacing.s)
                .background(showHistory == history ? theme.colors.surfaceRaised : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(showHistory == history ? [.isSelected] : [])
        .accessibilityIdentifier(history ? "attention.filter.history" : "attention.filter.active")
    }

    @ViewBuilder
    private var refreshStatus: some View {
        if let checked = inbox.lastCheckedAt {
            Text("Checked \(checked.formatted(date: .abbreviated, time: .shortened))")
        }
        if inbox.pendingAnalysisCount > 0 {
            Label("\(inbox.pendingAnalysisCount) reviews queued", systemImage: "clock")
        }
    }

    private var loadingState: some View {
        VStack(spacing: theme.spacing.m) {
            ProgressView().controlSize(.small)
            Text("Loading attention…")
                .font(.subheadline)
                .foregroundStyle(theme.colors.textMuted)
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("attention.loading")
    }

    private var emptyState: some View {
        VStack(spacing: theme.spacing.l) {
            Image(systemName: showHistory ? "clock" : "checkmark.circle")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(theme.colors.textMuted)
            VStack(spacing: theme.spacing.s) {
                Text(showHistory ? "No attention history" : "You're all caught up")
                    .font(.system(size: theme.typography.title))
                    .foregroundStyle(theme.colors.textPrimary)
                Text("Updates from your agents will appear here when a task or pull request needs your next step.")
                    .font(.system(size: theme.typography.body))
                    .foregroundStyle(theme.colors.textSecondary)
                    .frame(maxWidth: 420)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("attention.empty")
    }

    private func findingRow(_ finding: ProactiveFinding, at date: Date) -> some View {
        VStack(alignment: .leading, spacing: theme.spacing.m) {
            VStack(alignment: .leading, spacing: theme.spacing.s) {
                HStack(alignment: .top) {
                    Label(finding.source.kind == .task ? "Task" : "Pull request",
                          systemImage: finding.source.kind == .task ? "checklist" : "arrow.triangle.branch")
                    Spacer(minLength: 12)
                    Text(inbox.agentNames[finding.agentId] ?? finding.agentId)
                }
                .font(.caption).foregroundStyle(theme.colors.textMuted)
                Text(finding.source.title).font(.system(size: theme.typography.heading, weight: .semibold)).textSelection(.enabled)
                Text(status(for: finding, at: date))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(theme.colors.surfaceRaised, in: Capsule())
            }
            detail("Why it matters", finding.reason)
            detail("What happened", finding.evidence)
            VStack(alignment: .leading, spacing: theme.spacing.s) {
                Label("Next step", systemImage: "arrow.turn.down.right").font(.caption.weight(.semibold))
                Text(finding.nextStep).font(.subheadline).textSelection(.enabled)
            }
            .padding(theme.spacing.m).frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.colors.surface, in: RoundedRectangle(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .stroke(theme.colors.border, lineWidth: theme.borders.thin)
            }
            if let until = finding.snoozedUntil, until > date {
                Label("Snoozed until \(until.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock")
                    .font(.caption).foregroundStyle(theme.colors.textMuted)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { sourceActions(finding); Spacer(minLength: 0); findingActions(finding) }
                VStack(alignment: .leading, spacing: 12) { sourceActions(finding); findingActions(finding) }
            }
            .controlSize(.regular)
            Rectangle().fill(theme.colors.border).frame(height: theme.borders.thin)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("attention.finding.\(finding.id)")
    }

    private func detail(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: theme.spacing.s) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(theme.colors.textMuted)
            Text(text).font(.subheadline).textSelection(.enabled)
        }
    }

    private func sourceActions(_ finding: ProactiveFinding) -> some View {
        HStack(spacing: 12) {
            if let url = DeepLink.session(agentId: finding.agentId, sessionId: finding.sessionId).url {
                Link(destination: url) { Label("Discuss with agent", systemImage: "bubble") }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("attention.discuss.\(finding.id)")
            }
            if let project = finding.source.projectId, let task = finding.source.taskId,
               let url = DeepLink.task(projectId: project, taskId: task).url {
                Link("Open task", destination: url).buttonStyle(.glass)
            } else if let raw = finding.source.url, let url = URL(string: raw),
                      ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                Link("Open source", destination: url).buttonStyle(.glass)
            }
        }
        .tint(theme.colors.textPrimary)
    }

    private func findingActions(_ finding: ProactiveFinding) -> some View {
        HStack(spacing: 12) {
            Button(finding.readAt == nil ? "Mark read" : "Read", systemImage: "checkmark") {
                Task { await inbox.act(finding, action: .read) }
            }
            .disabled(finding.readAt != nil)
            .accessibilityIdentifier("attention.read.\(finding.id)")
            Menu {
                Button("Snooze 24h", systemImage: "clock") { Task { await inbox.act(finding, action: .snooze) } }
                Button("Dismiss", systemImage: "xmark") { Task { await inbox.act(finding, action: .dismiss) } }
                    .disabled(finding.dismissedAt != nil)
            } label: { Label("More", systemImage: "ellipsis") }
            .accessibilityIdentifier("attention.actions.\(finding.id)")
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.colors.textSecondary)
        .tint(theme.colors.textPrimary)
        .disabled(inbox.busyFindingIDs.contains(finding.id) || finding.resolvedAt != nil || finding.dismissedAt != nil)
    }

    private func status(for finding: ProactiveFinding, at date: Date) -> String {
        if finding.resolvedAt != nil { return "Resolved" }
        if finding.dismissedAt != nil { return "Dismissed" }
        if let until = finding.snoozedUntil, until > date { return "Snoozed" }
        if finding.readAt != nil { return "Read" }
        return finding.outcome == .needsInput ? "Input needed" : "Suggested action"
    }
}
