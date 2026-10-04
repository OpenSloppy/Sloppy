import SloppyClientCore
import SloppyClientUI
import SwiftUI

struct SidebarSessionAvatarAgent: Identifiable {
    let id: String
    let agentID: String
    var paletteID: String? = nil
    var emotion: AgentBotEmotion = .idle
}

extension SidebarSessionActivity {
    var avatarEmotion: AgentBotEmotion {
        switch self {
        case .working: .working
        case .completed: .happy
        case .waitingForInput: .needsInput
        case .failed: .error
        }
    }
}

@MainActor
struct SidebarSessionAvatar: View {
    let agentID: String
    var agents: [SidebarSessionAvatarAgent] = []
    var activity: SidebarSessionActivity? = nil
    var requiresApproval = false
    var size: CGFloat = 24

    @Environment(\.theme) private var theme

    private var visibleAgents: [SidebarSessionAvatarAgent] {
        Array(agents.prefix(3))
    }

    private var emotion: AgentBotEmotion {
        requiresApproval ? .needsInput : activity?.avatarEmotion ?? .idle
    }

    var body: some View {
        ZStack {
            if visibleAgents.count > 1 {
                ForEach(Array(visibleAgents.enumerated()), id: \.element.id) { index, agent in
                    AgentBotAvatar(agentID: agent.agentID, size: size * 0.64, paletteID: agent.paletteID,
                                   emotion: index == 0 ? emotion : agent.emotion, isAnimated: true)
                        .background(theme.colors.background, in: Circle())
                        .offset(x: index == 0 ? 0 : (index == 1 ? -size * 0.22 : size * 0.22),
                                y: index == 0 ? -size * 0.2 : size * 0.18)
                }
            } else {
                AgentBotAvatar(agentID: agentID, size: size, paletteID: agents.first?.paletteID,
                               emotion: emotion, isAnimated: true)
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .topTrailing) {
            if requiresApproval || activity != nil {
                statusBadge
                    .offset(x: 2, y: -1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(requiresApproval ? "Agent requires approval" : statusLabel)
        .accessibilityIdentifier("sidebar.session.avatar")
        .help(requiresApproval ? "Requires approval" : statusLabel)
    }

    private var statusLabel: String {
        switch activity {
        case .working: "Agent is working"
        case .completed: "Task completed"
        case .waitingForInput: "Agent is waiting for input"
        case .failed: "Task was interrupted"
        case .none: "Agent \(agentID)"
        }
    }

    private var statusBadge: some View {
        ZStack {
            Circle().fill(badgeColor)
            if let symbol = badgeSymbol {
                Image(systemName: symbol)
                    .font(.system(size: 7, weight: .heavy))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 12, height: 12)
        .overlay { Circle().strokeBorder(theme.colors.background, lineWidth: 2) }
    }

    private var badgeColor: Color {
        if requiresApproval { return theme.colors.statusWarning }
        switch activity {
        case .working: return theme.colors.statusActive
        case .completed: return theme.colors.statusReady
        case .waitingForInput: return theme.colors.statusWarning
        case .failed: return theme.colors.statusBlocked
        case .none: return .clear
        }
    }

    private var badgeSymbol: String? {
        if requiresApproval { return "questionmark" }
        switch activity {
        case .completed: return "checkmark"
        case .waitingForInput: return "questionmark"
        case .failed: return "exclamationmark"
        case .working, .none: return nil
        }
    }
}
