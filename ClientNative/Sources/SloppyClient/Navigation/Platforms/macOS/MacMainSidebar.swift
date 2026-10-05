#if os(macOS)
import Foundation
import SloppyClientCore
import SloppyClientUI
import SwiftUI

@MainActor
struct PlatformMainSidebar: View {
    let viewModel: MainViewModel
    let isOverlay: Bool
    var composerBackdropHeight: CGFloat? = nil
    var approvalRequiredSessionIDs: Set<String> = []
    var showsApprovalRequiredChatsOnly = false

    @Environment(\.theme) private var theme
    @State private var isSettingsHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                MacSidebarPrimaryActions(viewModel: viewModel)

                if !viewModel.settings.hiddenSidebarItems.contains("agents") {
                    SidebarAgentsSection(
                        agents: viewModel.chatViewModel.agents,
                        selectedAgentID: viewModel.sidebarSelectedAgentID,
                        isLoading: !viewModel.chatViewModel.didLoadInitialData,
                        errorMessage: viewModel.sidebarAgentChatError,
                        onSelect: viewModel.selectSidebarAgent,
                        onInfo: viewModel.showSidebarAgentInfo
                    )
                }

                SidebarRecentsList(
                    viewModel: viewModel,
                    approvalRequiredSessionIDs: approvalRequiredSessionIDs,
                    showsApprovalRequiredOnly: showsApprovalRequiredChatsOnly
                )
            }
            .frame(maxHeight: .infinity)
            .modifier(SidebarScrollFade())
            .refreshable { await viewModel.refreshContent() }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: theme.spacing.s) {
                    Menu {
                        Button {
                            viewModel.selectInstance(.all)
                        } label: {
                            instanceMenuLabel(
                                title: "All",
                                systemImage: "square.stack.3d.up",
                                isSelected: viewModel.settings.instanceSelection == .all
                            )
                        }

                        Divider()

                        ForEach(viewModel.settings.discoveredInstances) { instance in
                            Button {
                                viewModel.selectInstance(.instance(instance.id))
                            } label: {
                                instanceMenuLabel(
                                    title: instance.displayName,
                                    systemImage: instance.isLocal ? "desktopcomputer" : "network",
                                    isSelected: viewModel.settings.instanceSelection == .instance(instance.id)
                                )
                            }
                        }

                        Divider()

                        Button("Connect via Relay…") {
                            viewModel.onOpenWorkspace()
                        }
                        .accessibilityIdentifier("sidebar.connectRelay")

                        Button("Manage Instances…") {
                            viewModel.onOpenSettings(.general)
                        }
                    } label: {
                        HStack(spacing: theme.spacing.s) {
                            Image(systemName: selectedInstanceSystemImage)
                                .font(.system(size: theme.typography.body, weight: .semibold))
                                .foregroundColor(theme.colors.textPrimary)
                                .frame(width: 32, height: 32)
                                .background(theme.colors.accent, in: Circle())

                            VStack(alignment: .leading, spacing: 2) {
                                Text(viewModel.selectedInstanceTitle)
                                    .font(.system(size: theme.typography.body, weight: .medium))
                                    .foregroundColor(theme.colors.textPrimary)
                                    .lineLimit(1)

                                Text(selectedInstanceSubtitle)
                                    .font(.system(size: theme.typography.micro))
                                    .foregroundColor(theme.colors.textMuted)
                                    .lineLimit(1)
                            }

                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: theme.typography.micro, weight: .semibold))
                                .foregroundColor(theme.colors.textMuted)
                        }
                        .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: theme.spacing.s)

                    SloppyUpdateReminderView()

                    SidebarCustomizationMenu(settings: viewModel.settings)

                    Button {
                        viewModel.onOpenSettings(.account)
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: theme.typography.heading))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(SidebarHoverButtonStyle(isHovered: isSettingsHovered))
                    .onHover { isSettingsHovered = $0 }
                    .help("Open settings")
                    .accessibilityLabel("Open settings")
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, theme.spacing.m)
                .frame(maxWidth: .infinity, minHeight: 64)
            }
            .background {
                SidebarFooterBackground()
            }
        }
        .background(alignment: .bottom) {
            if let composerBackdropHeight {
                ComposerBackdrop(height: composerBackdropHeight)
            }
        }
    }

    private var selectedInstanceSystemImage: String {
        guard let instance = viewModel.selectedInstance else {
            return "square.stack.3d.up"
        }
        return instance.isLocal ? "desktopcomputer" : "network"
    }

    private var selectedInstanceSubtitle: String {
        guard let instance = viewModel.selectedInstance else {
            let count = viewModel.settings.discoveredInstances.count
            return "\(count) \(count == 1 ? "instance" : "instances")"
        }
        if instance.isLocal { return "Local" }
        return instance.status == .online ? "Relay · Online" : "Relay · Offline"
    }

    private func instanceMenuLabel(title: String, systemImage: String, isSelected: Bool) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: isSelected ? "checkmark" : systemImage)
        }
    }
}

@MainActor
private struct MacSidebarPrimaryActions: View {
    let viewModel: MainViewModel

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !viewModel.settings.hiddenSidebarItems.contains("newChat") {
                SidebarNavigationRow(
                    icon: .new,
                    title: "New chat",
                    isSelected: false,
                    navigationValue: .chats,
                    action: viewModel.selectNewChat
                )
            }

            if !viewModel.settings.hiddenSidebarItems.contains("attention") {
                TimelineView(.periodic(from: .now, by: 30)) { timeline in
                    SidebarNavigationRow(
                        icon: .attention,
                        title: "Attention",
                        badgeCount: viewModel.attentionInbox.unreadCount(at: timeline.date),
                        isSelected: viewModel.selectedAppSection == .attention,
                        navigationValue: .attention,
                        action: viewModel.selectAttention
                    )
                    .accessibilityIdentifier("sidebar.attention")
                }
            }

            if !viewModel.settings.hiddenSidebarItems.contains("sites") {
                SidebarNavigationRow(
                    icon: .language,
                    title: "Sites",
                    isSelected: viewModel.selectedAppSection == .sites,
                    navigationValue: .sites,
                    action: viewModel.selectSites
                )
            }

            if !viewModel.settings.hiddenSidebarItems.contains("pullRequests") {
                SidebarNavigationRow(
                    icon: .pullRequest,
                    title: "Pull Requests",
                    isSelected: viewModel.selectedAppSection == .pullRequests,
                    navigationValue: .pullRequests,
                    action: viewModel.selectPullRequests
                )
            }

            if !viewModel.settings.hiddenSidebarItems.contains("scheduled") {
                SidebarNavigationRow(
                    icon: .timer,
                    title: "Scheduled",
                    isSelected: viewModel.selectedAppSection == .scheduled,
                    navigationValue: .scheduled,
                    action: viewModel.selectScheduled
                )
            }

            if !viewModel.settings.hiddenSidebarItems.contains("workspace") {
                SidebarNavigationRow(
                    icon: .workspace,
                    title: "Workspace",
                    isSelected: viewModel.selectedAppSection == .workspace,
                    action: viewModel.selectWorkspace
                )
            }

            if !viewModel.settings.hiddenSidebarItems.contains("usage") {
                SidebarNavigationRow(
                    icon: .usage,
                    title: "Usage",
                    isSelected: viewModel.selectedAppSection == .usage,
                    navigationValue: .usage,
                    action: viewModel.selectUsage
                )
            }
            
            if !viewModel.settings.hiddenSidebarItems.contains("artifacts") {
                SidebarNavigationRow(
                    icon: .description,
                    title: "Artifacts",
                    isSelected: viewModel.selectedAppSection == .artifacts,
                    navigationValue: .artifacts,
                    action: viewModel.selectArtifacts
                )
            }
        }
        .padding(.horizontal, theme.spacing.xs)
    }
}

@MainActor
private struct SidebarCustomizationMenu: View {
    let settings: ClientSettings

    @Environment(\.theme) private var theme

    var body: some View {
        Menu {
            Toggle("New chat", isOn: visibility(for: "newChat"))
            Toggle("Attention", isOn: visibility(for: "attention"))
            Toggle("Sites", isOn: visibility(for: "sites"))
            Toggle("Pull Requests", isOn: visibility(for: "pullRequests"))
            Toggle("Scheduled", isOn: visibility(for: "scheduled"))
            Toggle("Agents", isOn: visibility(for: "agents"))
            Toggle("Usage", isOn: visibility(for: "usage"))
            Toggle("Workspace", isOn: visibility(for: "workspace"))
            Toggle("Artifacts", isOn: visibility(for: "artifacts"))
            Divider()
            Button("Restore Default Sidebar") { settings.hiddenSidebarItems = [] }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: theme.typography.heading))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Customize sidebar")
        .accessibilityLabel("Customize sidebar")
    }

    private func visibility(for item: String) -> Binding<Bool> {
        Binding(
            get: { !settings.hiddenSidebarItems.contains(item) },
            set: { isVisible in
                if isVisible {
                    settings.hiddenSidebarItems.remove(item)
                } else {
                    settings.hiddenSidebarItems.insert(item)
                }
            }
        )
    }
}

#Preview("macOS Sidebar") {
    PlatformMainSidebar(viewModel: .preview(), isOverlay: false)
        .frame(width: 348, height: 700)
}
#endif
