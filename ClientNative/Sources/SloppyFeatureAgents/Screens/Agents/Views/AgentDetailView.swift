import Foundation
import SwiftUI
import SloppyClientCore
import SloppyClientUI

enum AgentDetailTab: String, CaseIterable, Hashable {
    case overview
    case attention
    case tasks
    case skills
    case files
    case chat

    var title: String {
        switch self {
        case .overview: "Overview"
        case .attention: "Attention"
        case .tasks: "Tasks"
        case .skills: "Skills"
        case .files: "Files"
        case .chat: "Chat"
        }
    }

    var icon: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .attention: "bell.badge"
        case .tasks: "checklist"
        case .skills: "sparkles"
        case .files: "folder"
        case .chat: "bubble.left.and.bubble.right"
        }
    }
}

private struct AgentDetailSnapshot {
    var tasks: [APIAgentTaskRecord] = []
    var sessions: [ChatSessionSummary] = []
    var usage = AgentTokenUsageResponse()

    var activeTasks: [APIAgentTaskRecord] {
        tasks.filter { ["in_progress", "ready", "needs_review", "pending_approval"].contains($0.task.status) }
    }

    var status: String {
        if tasks.contains(where: { $0.task.status == "in_progress" }) { return "Working" }
        if tasks.contains(where: { ["needs_review", "pending_approval"].contains($0.task.status) }) { return "Review" }
        if tasks.contains(where: { $0.task.status == "ready" }) { return "Ready" }
        return "Idle"
    }
}

struct AgentDetailView: View {
    let agent: APIAgentRecord
    let apiClient: SloppyAPIClient

    @Environment(\.theme) private var theme
    @State private var selectedTab: AgentDetailTab = .overview
    @State private var snapshot = AgentDetailSnapshot()
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            agentHeader
            tabBar
            Divider().overlay(theme.colors.border)
            tabContent(selectedTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(theme.colors.background)
        .navigationTitle(agent.displayName)
        .navigationTitlePosition(.leading)
        .task(id: agent.id) { await loadOverview() }
        .navigationBarTrailingItems {
            Button {
                Task { await loadOverview() }
            } label: {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .disabled(isLoading)
            .accessibilityLabel("Refresh agent")
            .accessibilityIdentifier("agent-detail.refresh")
        }
    }

    private var statusColor: Color {
        let c = theme.colors
        switch snapshot.status {
        case "Working": return c.statusActive
        case "Review": return c.statusWarning
        case "Ready": return c.statusReady
        default: return c.statusNeutral
        }
    }

    private var agentHeader: some View {
        let c = theme.colors
        let sp = theme.spacing

        return VStack(alignment: .leading, spacing: sp.m) {
            HStack(spacing: sp.m) {
                AgentAvatar(agentID: agent.id, color: statusColor, size: 58, paletteID: agent.pet?.visual?.paletteId)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: sp.s) {
                        Text(agent.displayName)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(c.textPrimary)
                        if agent.isSystem == true {
                            Text("SYSTEM")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(c.accentCyan)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(c.accentCyan.opacity(0.10), in: Capsule())
                        }
                    }
                    Text(agent.role.isEmpty ? "No role configured" : agent.role)
                        .font(.subheadline)
                        .foregroundStyle(c.textSecondary)
                    Text(agent.id)
                        .font(.caption.monospaced())
                        .foregroundStyle(c.textMuted)
                }
                Spacer()
                StatusBadge(snapshot.status, color: statusColor)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: sp.s)], spacing: sp.s) {
                AgentStatCard(label: "Active tasks", value: "\(snapshot.activeTasks.count)", icon: "bolt.fill", color: c.statusActive)
                AgentStatCard(label: "Runs", value: "\(snapshot.sessions.count)", icon: "play.circle.fill", color: c.accent)
                AgentStatCard(label: "Messages", value: "\(snapshot.sessions.reduce(0) { $0 + $1.messageCount })", icon: "bubble.left.fill", color: c.accentCyan)
                AgentStatCard(label: "Tokens", value: formatted(snapshot.usage.totalTokens), icon: "sum", color: c.accentAcid)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(c.statusWarning)
            }
        }
        .padding(sp.l)
    }

    private var tabBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: theme.spacing.xs) {
                ForEach(AgentDetailTab.allCases, id: \.self) { tab in
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { selectedTab = tab }
                    } label: {
                        Label(tab.title, systemImage: tab.icon)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .foregroundStyle(selectedTab == tab ? theme.colors.textPrimary : theme.colors.textSecondary)
                            .background(
                                selectedTab == tab ? theme.colors.surfaceRaised : Color.clear,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("agent-detail.tab.\(tab.rawValue)")
                }
            }
            .padding(.horizontal, theme.spacing.l)
            .padding(.bottom, theme.spacing.m)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func tabContent(_ tab: AgentDetailTab) -> some View {
        switch tab {
        case .overview:
            AgentOverviewContent(agent: agent, snapshot: snapshot, isLoading: isLoading)
        case .attention:
            AgentProactivityScreen(agentID: agent.id, apiClient: apiClient)
        case .tasks:
            AgentTasksContent(tasks: snapshot.tasks, isLoading: isLoading)
        case .skills:
            AgentSkillsView(agent: agent, apiClient: apiClient)
        case .files:
            AgentFilesView(agent: agent, apiClient: apiClient)
        case .chat:
            AgentChatView(agent: agent, apiClient: apiClient)
        }
    }

    private func loadOverview() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        async let tasksRequest = try apiClient.fetchAgentTasks(agentId: agent.id)
        async let sessionsRequest = try apiClient.fetchAgentSessions(agentId: agent.id, limit: 500)
        async let usageRequest = try apiClient.fetchAgentTokenUsage(agentId: agent.id)

        do {
            let (tasks, sessions, usage) = try await (tasksRequest, sessionsRequest, usageRequest)
            snapshot = AgentDetailSnapshot(tasks: tasks, sessions: sessions, usage: usage)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func formatted(_ value: Int) -> String {
        value.formatted(.number.notation(value >= 10_000 ? .compactName : .automatic))
    }
}

private struct AgentOverviewContent: View {
    let agent: APIAgentRecord
    let snapshot: AgentDetailSnapshot
    let isLoading: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: theme.spacing.m, alignment: .top)], spacing: theme.spacing.m) {
                AgentSectionCard(title: "Current work", icon: "bolt") {
                    if isLoading && snapshot.tasks.isEmpty {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                    } else if snapshot.activeTasks.isEmpty {
                        AgentInlineEmpty(icon: "checkmark.circle", title: "Nothing active", detail: "This agent has no current tasks.")
                    } else {
                        VStack(spacing: 0) {
                            ForEach(snapshot.activeTasks.prefix(4)) { record in
                                AgentTaskRow(record: record)
                            }
                        }
                    }
                }

                AgentSectionCard(title: "Recent runs", icon: "clock.arrow.circlepath") {
                    if isLoading && snapshot.sessions.isEmpty {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                    } else if snapshot.sessions.isEmpty {
                        AgentInlineEmpty(icon: "play.slash", title: "No runs yet", detail: "A run appears after the first session.")
                    } else {
                        VStack(spacing: 0) {
                            ForEach(snapshot.sessions.sorted { $0.updatedAt > $1.updatedAt }.prefix(5)) { session in
                                HStack(spacing: theme.spacing.s) {
                                    Image(systemName: session.kind == "heartbeat" ? "heart.text.square" : "bubble.left")
                                        .foregroundStyle(theme.colors.accentCyan)
                                        .frame(width: 22)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(session.title.isEmpty ? "Untitled run" : session.title)
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(theme.colors.textPrimary)
                                            .lineLimit(1)
                                        Text(session.updatedAt.formatted(.relative(presentation: .named)))
                                            .font(.caption)
                                            .foregroundStyle(theme.colors.textMuted)
                                    }
                                    Spacer()
                                    Text("\(session.messageCount)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(theme.colors.textSecondary)
                                }
                                .padding(.vertical, 10)
                            }
                        }
                    }
                }

                AgentSectionCard(title: "Usage", icon: "chart.bar") {
                    VStack(spacing: 0) {
                        UsageRow(label: "Input tokens", value: snapshot.usage.inputTokens)
                        UsageRow(label: "Output tokens", value: snapshot.usage.outputTokens)
                        UsageRow(label: "Cached input", value: snapshot.usage.cachedTokens)
                        UsageRow(label: "Reasoning", value: snapshot.usage.reasoningTokens)
                        HStack {
                            Text("Estimated cost")
                            Spacer()
                            Text(snapshot.usage.totalCostUSD > 0 ? snapshot.usage.totalCostUSD.formatted(.currency(code: "USD")) : "—")
                                .monospacedDigit()
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(theme.colors.textPrimary)
                        .padding(.vertical, 10)
                    }
                }

                AgentSectionCard(title: "Identity", icon: "person.text.rectangle") {
                    VStack(spacing: 0) {
                        IdentityRow(label: "Name", value: agent.displayName)
                        IdentityRow(label: "Role", value: agent.role.isEmpty ? "—" : agent.role)
                        IdentityRow(label: "Identifier", value: agent.id, monospaced: true)
                        IdentityRow(label: "Type", value: agent.isSystem == true ? "System agent" : "User agent")
                    }
                }
            }
            .padding(theme.spacing.l)
        }
    }
}

private struct AgentTasksContent: View {
    let tasks: [APIAgentTaskRecord]
    let isLoading: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.spacing.m) {
                if isLoading && tasks.isEmpty {
                    ProgressView("Loading tasks…")
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else if tasks.isEmpty {
                    ContentUnavailableView("No assigned tasks", systemImage: "checklist", description: Text("Tasks claimed by this agent will appear here."))
                        .frame(maxWidth: .infinity, minHeight: 280)
                } else {
                    ForEach(tasks) { record in
                        AgentTaskRow(record: record, showsDescription: true)
                            .padding(theme.spacing.m)
                            .background(theme.colors.surfaceRaised.opacity(0.65), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(theme.colors.border, lineWidth: 1) }
                    }
                }
            }
            .padding(theme.spacing.l)
        }
    }
}

private struct AgentTaskRow: View {
    let record: APIAgentTaskRecord
    var showsDescription = false
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: theme.spacing.m) {
            VStack(alignment: .leading, spacing: 5) {
                Text(record.task.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(theme.colors.textPrimary)
                HStack(spacing: 6) {
                    Text(record.projectName)
                    if let priority = record.task.priority, !priority.isEmpty {
                        Text("•")
                        Text(priority.capitalized)
                    }
                }
                .font(.caption)
                .foregroundStyle(theme.colors.textMuted)
                if showsDescription, let description = record.task.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(theme.colors.textSecondary)
                        .lineLimit(3)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: theme.spacing.s)
            StatusBadge.forTaskStatus(record.task.status)
        }
        .padding(.vertical, showsDescription ? 0 : 10)
    }
}

private struct AgentSectionCard<Content: View>: View {
    let title: String
    let icon: String
    let content: Content
    @Environment(\.theme) private var theme

    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.s) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(theme.colors.textPrimary)
                .padding(.bottom, 4)
            content
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(theme.spacing.m)
        .background(theme.colors.surfaceRaised.opacity(0.60), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(theme.colors.border, lineWidth: 1) }
    }
}

private struct AgentStatCard: View {
    let label: String
    let value: String
    let icon: String
    let color: Color
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.headline.monospacedDigit()).foregroundStyle(theme.colors.textPrimary)
                Text(label).font(.caption).foregroundStyle(theme.colors.textMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(color.opacity(0.18), lineWidth: 1) }
    }
}

private struct AgentInlineEmpty: View {
    let icon: String
    let title: String
    let detail: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.spacing.m) {
            Image(systemName: icon).font(.title2).foregroundStyle(theme.colors.textMuted)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(theme.colors.textPrimary)
                Text(detail).font(.caption).foregroundStyle(theme.colors.textMuted)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
    }
}

private struct UsageRow: View {
    let label: String
    let value: Int
    @Environment(\.theme) private var theme

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value.formatted()).monospacedDigit()
        }
        .font(.subheadline)
        .foregroundStyle(theme.colors.textSecondary)
        .padding(.vertical, 8)
    }
}

private struct IdentityRow: View {
    let label: String
    let value: String
    var monospaced = false
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(theme.colors.textMuted)
            Spacer()
            Text(value)
                .font(monospaced ? .caption.monospaced() : .subheadline)
                .foregroundStyle(theme.colors.textPrimary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.vertical, 8)
    }
}
