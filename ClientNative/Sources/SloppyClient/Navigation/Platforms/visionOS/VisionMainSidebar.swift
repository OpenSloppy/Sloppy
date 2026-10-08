#if os(visionOS)
import SloppyFeatureAgents
import SloppyFeatureSites
import SwiftUI

@MainActor
struct PlatformMainSidebar: View {
    let viewModel: MainViewModel
    let isOverlay: Bool

    var body: some View {
        @Bindable var viewModel = viewModel
        TabView(selection: $viewModel.selectedAppSection) {
            Tab("Attention", systemImage: "bell.badge", value: MainAppSection.attention) {
                AttentionScreen(inbox: viewModel.attentionInbox)
            }
            .badge(viewModel.attentionInbox.unreadCount)
            Tab("Agents", systemImage: "person.2", value: MainAppSection.agents) {
                AgentsScreen(apiClient: viewModel.apiClient)
            }
            Tab("Usage", systemImage: "chart.bar", value: MainAppSection.usage) {
                ChatUsageScreen(
                    apiClient: viewModel.apiClient,
                    instanceTitle: viewModel.apiClient.baseURL.host ?? "Connected instance",
                    onOpenSession: viewModel.openSessionChatTab
                )
            }
            Tab("Chats", systemImage: "message", value: MainAppSection.chats) {
                ScrollView { SidebarRecentsList(viewModel: viewModel) }
            }
            Tab("Pull Requests", systemImage: "arrow.triangle.branch", value: MainAppSection.pullRequests) {
                PullRequestsScreen(
                    apiClient: viewModel.apiClient,
                    onBeginReview: viewModel.beginPullRequestReview,
                    onLinkChat: { detail, session in try await viewModel.linkPullRequestChat(detail, session: session) },
                    onSendReview: { detail, submission in try await viewModel.sendPullRequestReview(detail, submission: submission) }
                )
            }
            Tab("Sites", systemImage: "globe", value: MainAppSection.sites) {
                SitesScreen(
                    apiClient: viewModel.apiClient,
                    onCreate: viewModel.createSiteFromChat
                )
            }
            Tab("Workspace", systemImage: "square.grid.2x2", value: MainAppSection.workspace) {
                Color.clear
            }
        }
        .refreshable { await viewModel.refreshContent() }
    }
}

#Preview("visionOS Sidebar") {
    PlatformMainSidebar(viewModel: .preview(), isOverlay: false)
}
#endif
