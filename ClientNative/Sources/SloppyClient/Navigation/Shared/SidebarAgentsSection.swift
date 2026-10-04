import SloppyClientCore
import SloppyClientUI
import SwiftUI

@MainActor
struct SidebarAgentsSection: View {
    let agents: [APIAgentRecord]
    let selectedAgentID: String?
    var isLoading = false
    var errorMessage: String? = nil
    let onSelect: @MainActor (APIAgentRecord) -> Void
    let onInfo: @MainActor (APIAgentRecord) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Agents")
                .font(.system(size: theme.typography.body))
                .foregroundStyle(theme.colors.textMuted)
                .padding(.horizontal, theme.spacing.s)
                .padding(.vertical, theme.spacing.s)

            ForEach(agents) { agent in
                SidebarAgentRow(
                    agent: agent,
                    isSelected: selectedAgentID == agent.id,
                    onSelect: { onSelect(agent) },
                    onInfo: { onInfo(agent) }
                )
            }

            if agents.isEmpty {
                Text(isLoading ? "Loading agents…" : "No agents yet")
                    .font(.system(size: theme.typography.caption))
                    .foregroundStyle(theme.colors.textMuted)
                    .padding(.horizontal, theme.spacing.s)
                    .padding(.vertical, theme.spacing.s)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: theme.typography.caption))
                    .foregroundStyle(theme.colors.statusWarning)
                    .lineLimit(2)
                    .padding(theme.spacing.s)
            }
        }
        .padding(.horizontal, theme.spacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar.agents")
    }
}

@MainActor
private struct SidebarAgentRow: View {
    let agent: APIAgentRecord
    let isSelected: Bool
    let onSelect: @MainActor () -> Void
    let onInfo: @MainActor () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: theme.spacing.s) {
                AgentBotAvatar(agentID: agent.id, size: 20, paletteID: agent.pet?.visual?.paletteId,
                               isAnimated: isHovered)
                    .accessibilityHidden(true)
                    .frame(width: 22)
                Text(agent.displayName)
                    .font(.system(size: theme.typography.body))
                    .foregroundStyle(isSelected ? theme.colors.textPrimary : theme.colors.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
            .frame(minHeight: MainSidebarView.rowMinimumHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarHoverButtonStyle(isHovered: isHovered, isSelected: isSelected))
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Info", systemImage: "info.circle", action: onInfo)
                .accessibilityIdentifier("sidebar.agent.info.\(agent.id)")
        }
        .help(agent.displayName)
        .accessibilityLabel(agent.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("sidebar.agent.\(agent.id)")
    }
}
