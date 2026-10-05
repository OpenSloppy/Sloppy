import Foundation
import SwiftUI
import SloppyClientCore
import SloppyClientUI

struct ProjectListView: View {
    let projects: [APIProjectRecord]
    let isLoading: Bool
    let onRefresh: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        let c = theme.colors
        let sp = theme.spacing
        let ty = theme.typography

        return ScrollView {
            VStack(alignment: .leading, spacing: sp.l) {
                if isLoading && projects.isEmpty {
                    LoadingSkeleton("Loading projects…")
                } else if projects.isEmpty {
                    EmptyStateView("No projects found")
                } else {
                    LazyVStack(alignment: .leading, spacing: sp.s) {
                        ForEach(projects) { project in
                            NavigationLink(value: project.id) {
                                EntityCard(
                                    title: project.name,
                                    subtitle: project.description.isEmpty ? "No description" : project.description,
                                    trailing: taskSummary(project),
                                    accentColor: c.accent
                                )
                            }
                        }
                    }
                }
            }
            .padding(sp.l)
        }
        .mobileScreenBackground()
        .navigationTitle("Projects")
        .navigationTitlePosition(.leading)
        .navigationBarTrailingItems {
            Button("REFRESH") { onRefresh() }
                .foregroundColor(c.accent)
                .font(.system(size: ty.caption))
        }
    }

    private func taskSummary(_ project: APIProjectRecord) -> String {
        let total = project.tasks?.count ?? 0
        let active = project.tasks?.filter {
            ["in_progress", "ready", "needs_review"].contains($0.status)
        }.count ?? 0
        return "\(active)/\(total)"
    }
}
