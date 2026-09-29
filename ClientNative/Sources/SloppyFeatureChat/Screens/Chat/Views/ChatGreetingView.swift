import Foundation
import SwiftUI
import SloppyClientCore
import SloppyClientUI

public struct ChatGreetingView: View {
    public let projects: [APIProjectRecord]
    public let selectedProjectId: String?
    public let selectedProjectName: String?
    public let onSelectPersonal: @MainActor () -> Void
    public let onSelectProject: @MainActor (APIProjectRecord) -> Void
    public let onSelectPrompt: @MainActor (String) -> Void

    public init(
        projects: [APIProjectRecord],
        selectedProjectId: String?,
        selectedProjectName: String?,
        onSelectPersonal: @escaping @MainActor () -> Void,
        onSelectProject: @escaping @MainActor (APIProjectRecord) -> Void,
        onSelectPrompt: @escaping @MainActor (String) -> Void
    ) {
        self.projects = projects
        self.selectedProjectId = selectedProjectId
        self.selectedProjectName = selectedProjectName
        self.onSelectPersonal = onSelectPersonal
        self.onSelectProject = onSelectProject
        self.onSelectPrompt = onSelectPrompt
    }

    @Environment(\.userInterfaceIdiom) private var idiom
    @Environment(\.theme) private var theme

    public var body: some View {
        let c = theme.colors
        let sp = theme.spacing
        let ty = theme.typography
        let isPhone = idiom == .phone

        return VStack(alignment: .center, spacing: isPhone ? sp.l : sp.xxl) {
            SloppyAssets.projectLogo
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .foregroundColor(c.textMuted)
                .frame(width: isPhone ? 28 : 38, height: isPhone ? 28 : 38)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: sp.xs) {
                    Text("What should we do in")
                    projectPicker
                    Text("?")
                }
                .fixedSize(horizontal: true, vertical: false)

                VStack(spacing: sp.xs) {
                    Text("What should we do in")
                    HStack(alignment: .firstTextBaseline, spacing: sp.xs) {
                        projectPicker
                        Text("?")
                    }
                }
            }
            .font(.system(size: ty.title))
            .foregroundColor(c.textPrimary)
            .lineLimit(1)
            .multilineTextAlignment(.center)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: sp.s), count: isPhone ? 2 : 4),
                spacing: sp.s
            ) {
                ForEach(Self.starterPrompts) { prompt in
                    StarterPromptButton(
                        prompt: prompt,
                        isPhone: isPhone
                    ) {
                        onSelectPrompt(prompt.prompt)
                    }
                }
            }
        }
        .padding(.horizontal, isPhone ? sp.s : sp.m)
    }

    private var projectPicker: some View {
        Menu {
            Button("Personal", action: onSelectPersonal)
                .accessibilityIdentifier("chat.context.personal")
            Divider()
            if projects.isEmpty {
                Text("No projects")
            } else {
                ForEach(projects) { project in
                    Button(project.name) {
                        onSelectProject(project)
                    }
                }
            }
        } label: {
            Text(projectPickerTitle)
                .underline(pattern: .dot)
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Choose chat context")
        .accessibilityIdentifier("chat.context.picker")
    }

    private var projectPickerTitle: String {
        selectedProjectName
            ?? projects.first(where: { $0.id == selectedProjectId })?.name
            ?? "Personal"
    }

    private struct StarterPrompt: Identifiable {
        let title: String
        let prompt: String
        let symbol: String
        let color: Color

        var id: String { title }
    }

    private struct StarterPromptButton: View {
        let prompt: StarterPrompt
        let isPhone: Bool
        let action: @MainActor () -> Void

        @Environment(\.theme) private var theme
        @State private var isHovered = false

        var body: some View {
            let c = theme.colors
            let sp = theme.spacing
            let ty = theme.typography
            let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

            Button(action: action) {
                VStack(alignment: .leading, spacing: sp.l) {
                    Image(systemName: prompt.symbol)
                        .font(.system(size: ty.heading, weight: .medium))
                        .foregroundColor(prompt.color)
                    Text(prompt.title)
                        .font(.system(size: isPhone ? ty.caption : ty.body, weight: .medium))
                        .foregroundColor(c.textPrimary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                }
                .padding(isPhone ? sp.s : sp.m)
                .frame(maxWidth: .infinity, minHeight: isPhone ? 116 : 150, alignment: .leading)
                .backportGlassEffect(.regular.interactive(), in: shape)
                .overlay {
                    shape.stroke(
                        isHovered ? prompt.color.opacity(0.72) : Color.clear,
                        lineWidth: theme.borders.thin
                    )
                }
                .shadow(
                    color: isHovered ? prompt.color.opacity(0.18) : Color.clear,
                    radius: 14,
                    y: 6
                )
                .scaleEffect(isHovered ? 1.015 : 1)
            }
            .buttonStyle(.plain)
            .contentShape(shape)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.16), value: isHovered)
            .accessibilityLabel(prompt.title)
        }
    }

    private static let starterPrompts = [
        StarterPrompt(
            title: "Explore and understand code",
            prompt: "Explore this project and explain how it is structured.",
            symbol: "binoculars",
            color: .blue
        ),
        StarterPrompt(
            title: "Build a new feature, app, or tool",
            prompt: "Help me build a new feature in this project.",
            symbol: "hammer",
            color: .purple
        ),
        StarterPrompt(
            title: "Review code and suggest changes",
            prompt: "Review this project's code and suggest improvements.",
            symbol: "arrow.triangle.2.circlepath",
            color: .green
        ),
        StarterPrompt(
            title: "Fix issues and failures",
            prompt: "Find and fix the current issues in this project.",
            symbol: "ant",
            color: .orange
        ),
    ]
}

#Preview {
    ChatGreetingView(projects: [
        .init(id: "sloppy", name: "Sloppy"),
        .init(id: "adaengine", name: "AdaEngine"),
    ], selectedProjectId: "sloppy", selectedProjectName: "Sloppy", onSelectPersonal: {}) { _ in
    } onSelectPrompt: { _ in

    }
    .frame(width: 500, height: 900)
}
