import SloppyClientCore
import SloppyClientUI
import SloppyFeatureChat
import SwiftUI

enum SidebarSessionActivity: String, Equatable {
    case working
    case completed
    case waitingForInput
    case failed

    static func resolve(
        isSending: Bool = false,
        isAwaitingAgentResponse: Bool = false,
        hasPendingInputRequest: Bool = false,
        runStage: ChatRunStage?
    ) -> SidebarSessionActivity? {
        if hasPendingInputRequest || runStage == .paused {
            return .waitingForInput
        }
        if isSending || isAwaitingAgentResponse || runStage?.isWorking == true {
            return .working
        }
        switch runStage {
        case .done:
            return .completed
        case .interrupted:
            return .failed
        case .thinking, .searching, .responding, .paused, .none:
            return nil
        }
    }
}

struct SidebarSessionActivityRecord: Equatable {
    let activity: SidebarSessionActivity
    let eventID: String?

    func visibleActivity(readEventID: String?) -> SidebarSessionActivity? {
        if (activity == .completed || activity == .failed),
           let eventID, eventID == readEventID {
            return nil
        }
        return activity
    }
}

@MainActor
struct SidebarSessionRow: View {
    let session: ChatSessionSummary
    let projectName: String?
    var instanceName: String? = nil
    var showsProjectName = true
    let isPinned: Bool
    let isSelected: Bool
    var requiresApproval = false
    var activity: SidebarSessionActivity? = nil
    var chatColor: SidebarProjectColor? = nil
    var avatarAgents: [SidebarSessionAvatarAgent] = []
    let onOpen: @MainActor () -> Void
    let onTogglePin: @MainActor () -> Void
    let onCopyDebugLink: @MainActor () -> Void
    let onDelete: @MainActor () -> Void
    var onRename: (@MainActor (String) async throws -> Void)? = nil
    var onSetChatColor: (@MainActor (String?) -> Void)? = nil

    @Environment(\.theme) private var theme
    @State private var isHovered = false
    @State private var isRenamePresented = false

    private var title: String { session.displayTitle.isEmpty ? "Chat" : session.displayTitle }
    private var resolvedProjectName: String { projectName ?? "No project" }

    var body: some View {
        primaryAction
        .buttonStyle(SidebarHoverButtonStyle(isHovered: isHovered, isSelected: isSelected))
        .onHover { isHovered = $0 }
        .sheet(isPresented: $isRenamePresented) {
            ChatRenameSheet(title: session.title) { title in
                try await onRename?(title)
            }
        }
        .contextMenu {
            if onRename != nil {
                Button("Rename Chat…", systemImage: "pencil") { isRenamePresented = true }
            }
            Button(isPinned ? "Unpin Chat" : "Pin Chat", action: onTogglePin)
            Menu {
                Button { onSetChatColor?(nil) } label: {
                    SidebarColorMenuOption(
                        title: "Default",
                        color: nil,
                        isSelected: chatColor == nil
                    )
                }
                Divider()
                ForEach(SidebarProjectColor.allCases, id: \.self) { tint in
                    Button {
                        onSetChatColor?(tint.rawValue)
                    } label: {
                        SidebarColorMenuOption(
                            title: tint.rawValue.capitalized,
                            color: tint,
                            isSelected: chatColor == tint
                        )
                    }
                }
            } label: {
                Label("Chat Color", systemImage: "paintpalette")
            }
            Button("Copy Session File Debug Link", action: onCopyDebugLink)
            Button("Delete Chat", role: .destructive, action: onDelete)
        }
        .accessibilityHint(projectName.map { "Project \($0)" } ?? "")
    }

    @ViewBuilder
    private var primaryAction: some View {
        #if os(macOS)
        Button(action: onOpen) {
            content
        }
        #else
        NavigationLink(value: MainSidebarSelection.chats) {
            content
        }
        .simultaneousGesture(TapGesture().onEnded { onOpen() })
        #endif
    }

    private var content: some View {
        HStack(spacing: theme.spacing.s) {
            SidebarSessionAvatar(agentID: session.agentId, agents: avatarAgents,
                                 activity: activity, requiresApproval: requiresApproval)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: theme.typography.body))
                    .foregroundColor(isSelected ? theme.colors.textPrimary : theme.colors.textSecondary)
                    .lineLimit(1)

                if showsProjectName {
                    HStack(spacing: theme.spacing.xs) {
                        Image(systemName: "folder")
                            .font(.system(size: theme.typography.caption))
                        Text(resolvedProjectName)
                            .font(.system(size: theme.typography.caption))
                            .lineLimit(1)
                    }
                    .foregroundColor(theme.colors.textMuted)
                }
                if let instanceName {
                    Label(instanceName, systemImage: "desktopcomputer")
                        .font(.system(size: theme.typography.micro))
                        .foregroundColor(theme.colors.textMuted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if isPinned {
                Icons.symbol(.pushPin, size: theme.typography.caption)
                    .foregroundColor(theme.colors.textMuted)
            }
        }
        .padding(.horizontal, theme.spacing.s)
        .padding(.vertical, 6)
        .frame(minHeight: MainSidebarView.rowMinimumHeight)
        .background {
            if let chatColor {
                RoundedRectangle(cornerRadius: 12)
                    .fill(chatColor.color.opacity(isSelected ? 0.2 : 0.12))
            }
        }
        .contentShape(Rectangle())
    }
}

#Preview("Session Row") {
    SidebarSessionRow(
        session: ChatSessionSummary(
            id: "preview-session",
            agentId: "codex",
            title: "Refactor platform navigation",
            messageCount: 12,
            updatedAt: Date().addingTimeInterval(-180),
            projectId: "sloppy"
        ),
        projectName: "Sloppy",
        isPinned: true,
        isSelected: true,
        activity: .working,
        onOpen: {},
        onTogglePin: {},
        onCopyDebugLink: {},
        onDelete: {}
    )
    .frame(width: 340, height: 56)
    .padding()
}
