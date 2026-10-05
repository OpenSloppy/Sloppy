import Foundation
import SwiftUI
import SloppyClientCore
import SloppyClientUI

enum ProjectDetailTab: String, CaseIterable, Hashable {
    case info
    case tasks
    case channels

    var title: String {
        switch self {
        case .info: "INFO"
        case .tasks: "TASKS"
        case .channels: "CHANNELS"
        }
    }
}

struct ProjectDetailView: View {
    let project: APIProjectRecord

    @Environment(\.theme) private var theme
    @State private var selectedTab: ProjectDetailTab = .info

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(ProjectDetailTab.allCases, id: \.self) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            tabContent(selectedTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .mobileScreenBackground()
        .navigationTitle(project.name.uppercased())
        .navigationTitlePosition(.leading)
    }

    @ViewBuilder
    private func tabContent(_ tab: ProjectDetailTab) -> some View {
        switch tab {
        case .info:
            projectInfoTab
        case .tasks:
            projectTasksTab
        case .channels:
            projectChannelsTab
        }
    }

    private var projectInfoTab: some View {
        let c = theme.colors
        let sp = theme.spacing
        let bo = theme.borders

        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                DetailRow("Name", value: project.name)
                DetailRow("Description", value: project.description.isEmpty ? "—" : project.description)
                DetailRow("Tasks", value: "\(project.tasks?.count ?? 0)")
                DetailRow("Channels", value: "\(project.channels?.count ?? 0)")
                DetailRow("Actors", value: "\(project.actors?.count ?? 0)")
                DetailRow("Teams", value: "\(project.teams?.count ?? 0)")
            }
            .padding(sp.l)
            .border(c.border, lineWidth: bo.thin)
            .padding(sp.l)
        }
    }

    private var projectTasksTab: some View {
        let c = theme.colors
        let sp = theme.spacing
        let bo = theme.borders
        let ty = theme.typography

        return ScrollView {
            VStack(alignment: .leading, spacing: sp.s) {
                let tasks = project.tasks ?? []
                if tasks.isEmpty {
                    EmptyStateView("No tasks")
                } else {
                    ForEach(tasks) { task in
                        HStack(spacing: sp.m) {
                            VStack(alignment: .leading, spacing: sp.xs) {
                                Text(task.title)
                                    .font(.system(size: ty.body))
                                    .foregroundColor(c.textPrimary)
                                if let priority = task.priority {
                                    Text(priority.uppercased())
                                        .font(.system(size: ty.micro))
                                        .foregroundColor(c.textMuted)
                                }
                            }
                            Spacer()
                            StatusBadge.forTaskStatus(task.status)
                        }
                        .padding(sp.m)
                        .background(c.surface)
                        .border(c.border, lineWidth: bo.thin)
                    }
                }
            }
            .padding(sp.l)
        }
    }

    private var projectChannelsTab: some View {
        let c = theme.colors
        let sp = theme.spacing
        let bo = theme.borders
        let ty = theme.typography

        return ScrollView {
            VStack(alignment: .leading, spacing: sp.s) {
                let channels = project.channels ?? []
                if channels.isEmpty {
                    EmptyStateView("No channels")
                } else {
                    ForEach(channels) { channel in
                        HStack(spacing: sp.m) {
                            VStack(alignment: .leading, spacing: sp.xs) {
                                Text(channel.title)
                                    .font(.system(size: ty.body))
                                    .foregroundColor(c.textPrimary)
                                Text(channel.channelId)
                                    .font(.system(size: ty.micro))
                                    .foregroundColor(c.textMuted)
                            }
                            Spacer()
                        }
                        .padding(sp.m)
                        .background(c.surface)
                        .border(c.border, lineWidth: bo.thin)
                    }
                }
            }
            .padding(sp.l)
        }
    }
}
