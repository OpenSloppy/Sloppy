import Foundation
import SwiftUI
import SloppyClientCore
import SloppyClientUI

struct AgentListView: View {
    let agents: [APIAgentRecord]
    let snapshots: [String: AgentListSnapshot]
    let isLoading: Bool
    let errorMessage: String?
    let onRefresh: () async -> Void

    @Environment(\.theme) private var theme
    @State private var searchText = ""

    private var filteredAgents: [APIAgentRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return agents }
        return agents.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.role.localizedCaseInsensitiveContains(query)
                || $0.id.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        let c = theme.colors
        let sp = theme.spacing
        let ty = theme.typography

        ScrollView {
            VStack(alignment: .leading, spacing: sp.l) {
                summaryHeader

                if let errorMessage, agents.isEmpty {
                    ContentUnavailableView(
                        "Couldn’t load agents",
                        systemImage: "wifi.exclamationmark",
                        description: Text(errorMessage)
                    )
                    .frame(maxWidth: .infinity, minHeight: 280)
                } else if isLoading && agents.isEmpty {
                    LazyVGrid(columns: gridColumns, spacing: sp.m) {
                        ForEach(0..<4, id: \.self) { _ in
                            AgentCardPlaceholder()
                        }
                    }
                } else if filteredAgents.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? "No agents yet" : "No matching agents",
                        systemImage: searchText.isEmpty ? "person.2.slash" : "magnifyingglass",
                        description: Text(searchText.isEmpty ? "Agents will appear here after they are registered." : "Try another name, role, or identifier.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 280)
                } else {
                    LazyVGrid(columns: gridColumns, spacing: sp.m) {
                        ForEach(filteredAgents) { agent in
                            NavigationLink(value: agent.id) {
                                AgentCard(agent: agent, snapshot: snapshots[agent.id])
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("agents.card.\(agent.id)")
                        }
                    }
                }
            }
            .padding(sp.l)
        }
        .background(c.background)
        .navigationTitle("Agents")
        .navigationTitlePosition(.leading)
        .searchable(text: $searchText, prompt: "Search agents")
        .navigationBarTrailingItems {
            Button {
                Task { await onRefresh() }
            } label: {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .disabled(isLoading)
            .foregroundColor(c.accentCyan)
            .font(.system(size: ty.caption, weight: .medium))
            .accessibilityIdentifier("agents.refresh")
        }
        .refreshable { await onRefresh() }
    }

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 300, maximum: 460), spacing: theme.spacing.m, alignment: .top)]
    }

    private var summaryHeader: some View {
        let c = theme.colors
        let sp = theme.spacing
        let activeAgents = snapshots.values.count { $0.activeTaskCount > 0 }
        let totalRuns = snapshots.values.reduce(0) { $0 + $1.sessionCount }

        return HStack(alignment: .center, spacing: sp.m) {
            VStack(alignment: .leading, spacing: sp.xs) {
                Text("Your agent team")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(c.textPrimary)
                Text("Track work, usage, skills, and files in one place.")
                    .font(.subheadline)
                    .foregroundStyle(c.textSecondary)
            }
            Spacer(minLength: sp.m)
            HStack(spacing: sp.s) {
                HeaderMetric(value: "\(activeAgents)", label: "Active", color: c.statusActive)
                HeaderMetric(value: "\(totalRuns)", label: "Runs", color: c.accent)
            }
        }
    }
}

private struct AgentCard: View {
    let agent: APIAgentRecord
    let snapshot: AgentListSnapshot?

    @Environment(\.theme) private var theme

    private var status: (label: String, color: Color) {
        let c = theme.colors
        switch snapshot?.currentTaskStatus {
        case "in_progress": return ("Working", c.statusActive)
        case "needs_review", "pending_approval": return ("Review", c.statusWarning)
        case "ready": return ("Ready", c.statusReady)
        case "blocked": return ("Blocked", c.statusBlocked)
        default: return ("Idle", c.statusNeutral)
        }
    }

    var body: some View {
        let c = theme.colors
        let sp = theme.spacing

        VStack(alignment: .leading, spacing: sp.m) {
            HStack(spacing: sp.m) {
                AgentAvatar(agentID: agent.id, color: status.color, paletteID: agent.pet?.visual?.paletteId)
                VStack(alignment: .leading, spacing: 3) {
                    Text(agent.displayName)
                        .font(.headline)
                        .foregroundStyle(c.textPrimary)
                        .lineLimit(1)
                    Text(agent.role.isEmpty ? agent.id : agent.role)
                        .font(.caption)
                        .foregroundStyle(c.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                StatusBadge(status.label, color: status.color)
            }

            Divider().overlay(c.border)

            VStack(alignment: .leading, spacing: 6) {
                Text("CURRENT TASK")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(c.textMuted)
                Text(snapshot?.currentTaskTitle ?? "No assigned work")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(snapshot?.currentTaskTitle == nil ? c.textMuted : c.textPrimary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
            }

            HStack(spacing: sp.m) {
                AgentMiniMetric(icon: "checklist", value: "\(snapshot?.activeTaskCount ?? 0)/\(snapshot?.totalTaskCount ?? 0)", label: "tasks")
                AgentMiniMetric(icon: "play.circle", value: "\(snapshot?.sessionCount ?? 0)", label: "runs")
                AgentMiniMetric(icon: "sum", value: abbreviated(snapshot?.totalTokens ?? 0), label: "tokens")
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(c.textMuted)
            }
        }
        .padding(sp.m)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(c.surfaceRaised.opacity(0.72))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(c.border, lineWidth: 1)
                }
        }
        .contentShape(.rect)
    }

    private func abbreviated(_ value: Int) -> String {
        switch value {
        case 1_000_000...: String(format: "%.1fM", Double(value) / 1_000_000)
        case 1_000...: String(format: "%.1fK", Double(value) / 1_000)
        default: "\(value)"
        }
    }
}

struct AgentAvatar: View {
    let agentID: String
    let color: Color
    var size: CGFloat = 32
    var paletteID: String? = nil

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            AgentBotAvatar(agentID: agentID, size: size, paletteID: paletteID)
            Circle()
                .fill(color)
                .frame(width: max(9, size * 0.22), height: max(9, size * 0.22))
                .overlay { Circle().stroke(.black.opacity(0.45), lineWidth: 2) }
        }
        .accessibilityHidden(true)
    }
}

private struct AgentMiniMetric: View {
    let icon: String
    let value: String
    let label: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).foregroundStyle(theme.colors.textMuted)
            Text(value).foregroundStyle(theme.colors.textPrimary)
            Text(label).foregroundStyle(theme.colors.textMuted)
        }
        .font(.caption.monospacedDigit())
    }
}

private struct HeaderMetric: View {
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.headline.monospacedDigit()).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(minWidth: 62)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct AgentCardPlaceholder: View {
    @Environment(\.theme) private var theme

    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(theme.colors.surfaceRaised)
            .frame(height: 190)
            .redacted(reason: .placeholder)
            .opacity(0.55)
    }
}
