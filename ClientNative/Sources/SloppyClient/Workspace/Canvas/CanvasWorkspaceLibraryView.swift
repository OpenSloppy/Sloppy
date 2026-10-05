import Foundation
import SloppyClientCore
import SloppyClientUI
import SwiftUI

private enum CanvasWorkspaceLibraryLayout: String {
    case list
    case cards
}

@MainActor
struct CanvasWorkspaceLibraryView: View {
    let viewModel: CanvasWorkspaceViewModel
    var allowsProjectSelection = true
    @Environment(\.canvasWorkspaceToolbarEnabled) private var toolbarEnabled

    @State private var searchText = ""
    @State private var isCreateSheetPresented = false
    @AppStorage("canvas-workspace-library-layout")
    private var libraryLayout = CanvasWorkspaceLibraryLayout.list

    private var filteredWorkspaces: [CanvasWorkspaceSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return viewModel.workspaces
        }
        return viewModel.workspaces.filter { workspace in
            workspace.title.localizedStandardContains(query)
                || workspace.description.localizedStandardContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            libraryHeader
            Divider()

            if let error = viewModel.libraryError {
                libraryErrorBanner(error)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
            }

            libraryContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .mobileScreenBackground()
        .navigationTitle(viewModel.libraryTitle)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search canvases"
        )
        .refreshable { await viewModel.refreshLibrary() }
#endif
        .toolbar {
            if toolbarEnabled {
                #if os(iOS)
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Workspace layout", selection: $libraryLayout) {
                            Label("List", systemImage: "list.bullet").tag(CanvasWorkspaceLibraryLayout.list)
                            Label("Cards", systemImage: "square.grid.2x2").tag(CanvasWorkspaceLibraryLayout.cards)
                        }
                    } label: {
                        Label("Workspace layout", systemImage: libraryLayout == .list ? "list.bullet" : "square.grid.2x2")
                    }
                    .accessibilityIdentifier("canvas-workspace-layout-picker")
                }
                #endif
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isCreateSheetPresented = true
                    } label: {
                        Label("New Workspace", systemImage: "plus")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityLabel("New Workspace")
                    .accessibilityIdentifier("canvas-workspace-create")
                }
            }
        }
        .accessibilityIdentifier("canvas-workspace-library")
        .sheet(isPresented: $isCreateSheetPresented) {
            CanvasWorkspaceCreateSheet(viewModel: viewModel)
        }
    }

    private var libraryHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text(viewModel.librarySubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if allowsProjectSelection {
                    projectPicker
                }

                if viewModel.isResolving, !viewModel.workspaces.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Refreshing workspaces")
                }
            }

            #if !os(iOS)
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)

                    TextField("Search canvases", text: $searchText)
                        .textFieldStyle(.plain)

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear workspace search")
                    }

                    Divider()
                        .frame(height: 16)

                    Text("\(filteredWorkspaces.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Button {
                        Task {
                            await viewModel.refreshLibrary()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isResolving)
                    .help("Refresh Workspaces")
                    .accessibilityLabel("Refresh workspaces")
                }
                .padding(.horizontal, 11)
                .frame(maxWidth: 440, minHeight: 32)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                }

                Picker("Workspace layout", selection: $libraryLayout) {
                    Label("List", systemImage: "list.bullet")
                        .labelStyle(.iconOnly)
                        .tag(CanvasWorkspaceLibraryLayout.list)
                    Label("Cards", systemImage: "square.grid.2x2")
                        .labelStyle(.iconOnly)
                        .tag(CanvasWorkspaceLibraryLayout.cards)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Choose list or card layout")
                .accessibilityIdentifier("canvas-workspace-layout-picker")
            }
            #endif
        }
        .padding(.horizontal, 20)
        .padding(.vertical, headerVerticalPadding)
    }

    private var headerVerticalPadding: CGFloat {
        #if os(iOS)
        8
        #else
        18
        #endif
    }

    private var projectPicker: some View {
        Menu {
            Button {
                Task {
                    await viewModel.selectProject(nil)
                }
            } label: {
                projectPickerLabel(
                    title: CanvasWorkspaceViewModel.personalWorkspaceName,
                    systemImage: "person.crop.circle",
                    isSelected: viewModel.projectID == nil
                )
            }

            if !viewModel.projects.isEmpty {
                Divider()
            }

            ForEach(viewModel.projects) { project in
                Button {
                    Task {
                        await viewModel.selectProject(project)
                    }
                } label: {
                    projectPickerLabel(
                        title: project.name,
                        systemImage: project.semanticIconName,
                        isSelected: viewModel.projectID == project.id
                    )
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selectedProject?.semanticIconName ?? "person.crop.circle")
                Text(
                    selectedProject?.name
                        ?? viewModel.projectName
                        ?? CanvasWorkspaceViewModel.personalWorkspaceName
                )
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 9)
            .frame(minHeight: 28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .fixedSize()
        .disabled(viewModel.isResolving && viewModel.projects.isEmpty)
        .accessibilityLabel("Choose project")
        .accessibilityIdentifier("canvas-project-picker")
    }

    private var selectedProject: APIProjectRecord? {
        guard let projectID = viewModel.projectID else {
            return nil
        }
        return viewModel.projects.first { $0.id == projectID }
    }

    private func projectPickerLabel(
        title: String,
        systemImage: String,
        isSelected: Bool
    ) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            if isSelected {
                Image(systemName: "checkmark")
            }
        }
    }

    @ViewBuilder
    private var libraryContent: some View {
        if viewModel.isResolving, viewModel.workspaces.isEmpty {
            LoadingSkeleton("Loading workspaces…")
        } else if filteredWorkspaces.isEmpty {
            ContentUnavailableView {
                Label(
                    searchText.isEmpty ? "No Canvases" : "No Results",
                    systemImage: searchText.isEmpty ? "square.grid.2x2" : "magnifyingglass"
                )
            } description: {
                Text(
                    searchText.isEmpty
                        ? "Create a native canvas for notes, sketches, and agent-built artifacts."
                        : "No canvas matches “\(searchText)”."
                )
            } actions: {
                if searchText.isEmpty {
                    Button("Create Workspace") {
                        isCreateSheetPresented = true
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .buttonBorderShape(.capsule)
                    .accessibilityIdentifier("canvas-workspace-empty-create")
                } else {
                    Button("Clear Search") {
                        searchText = ""
                    }
                }
            }
        } else {
            switch libraryLayout {
            case .list:
                workspaceList
            case .cards:
                workspaceCards
            }
        }
    }

    private var workspaceList: some View {
        List(filteredWorkspaces) { workspace in
            CanvasWorkspaceLibraryRow(
                workspace: workspace,
                isSuggested: workspace.id == viewModel.suggestedWorkspaceID
            ) {
                viewModel.openWorkspace(workspace)
            }
            .listRowBackground(Color.clear)
            .accessibilityIdentifier("canvas-workspace-\(workspace.id)")
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var workspaceCards: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 230, maximum: 340), spacing: 16)],
                alignment: .leading,
                spacing: 16
            ) {
                ForEach(filteredWorkspaces) { workspace in
                    CanvasWorkspaceLibraryCard(
                        workspace: workspace,
                        isSuggested: workspace.id == viewModel.suggestedWorkspaceID
                    ) {
                        viewModel.openWorkspace(workspace)
                    }
                    .accessibilityIdentifier("canvas-workspace-card-\(workspace.id)")
                }
            }
            .padding(20)
        }
    }

    private func libraryErrorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Couldn’t load workspaces")
                .font(.callout.weight(.medium))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button("Retry") {
                Task {
                    await viewModel.refreshLibrary()
                }
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

@MainActor
private struct CanvasWorkspaceLibraryCard: View {
    let workspace: CanvasWorkspaceSummary
    let isSuggested: Bool
    let action: @MainActor () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                CanvasWorkspaceCardPreview(workspace: workspace)
                    .aspectRatio(16 / 9, contentMode: .fit)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 7) {
                        Text(workspace.title)
                            .font(.body.weight(.semibold))
                            .lineLimit(1)

                        if isSuggested {
                            Text("Linked")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                        }

                        Spacer(minLength: 0)
                    }

                    Text(workspace.description.isEmpty ? "Canvas workspace" : workspace.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(minHeight: 32, alignment: .topLeading)

                    HStack {
                        Text("Revision \(workspace.revision)")
                            .font(.caption2.monospacedDigit())
                        Spacer()
                        Text(workspace.updatedAt, style: .relative)
                            .font(.caption2)
                    }
                    .foregroundStyle(.tertiary)
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        isHovered ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.2),
                        lineWidth: 1
                    )
            }
            .shadow(color: .black.opacity(isHovered ? 0.12 : 0.05), radius: isHovered ? 10 : 4, y: 3)
            .scaleEffect(isHovered ? 1.01 : 1)
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("Open \(workspace.title)")
        .accessibilityHint("Opens the native workspace editor")
    }
}

private struct CanvasWorkspaceCardPreview: View {
    let workspace: CanvasWorkspaceSummary

    var body: some View {
        Group {
            if let coverURL {
                AsyncImage(url: coverURL) { phase in
                    switch phase {
                    case .empty:
                        placeholder
                            .overlay { ProgressView().controlSize(.small) }
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        placeholder
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .accessibilityHidden(true)
    }

    private var coverURL: URL? {
        guard let cover = workspace.cover?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: cover),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            return nil
        }
        return url
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.22),
                    Color.secondary.opacity(0.06),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Image(systemName: "circle.grid.3x3.fill")
                .font(.system(size: 74))
                .foregroundStyle(Color.secondary.opacity(0.08))

            HStack(alignment: .bottom, spacing: 18) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.orange.opacity(0.78))
                    .frame(width: 62, height: 72)
                    .rotationEffect(.degrees(-5))
                    .overlay {
                        Image(systemName: "lightbulb.fill")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.9))
                    }

                VStack(alignment: .leading, spacing: 7) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.2))
                        .frame(width: 72, height: 7)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 96, height: 7)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 54, height: 7)
                }
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .rotationEffect(.degrees(3))
            }
        }
    }
}

@MainActor
private struct CanvasWorkspaceLibraryRow: View {
    let workspace: CanvasWorkspaceSummary
    let isSuggested: Bool
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 38, height: 38)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(workspace.title)
                            .font(.body.weight(.medium))
                            .lineLimit(1)

                        if isSuggested {
                            Text("Linked")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                        }
                    }

                    Text(workspace.description.isEmpty ? "Canvas workspace" : workspace.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 16)

                VStack(alignment: .trailing, spacing: 3) {
                    Text("Revision \(workspace.revision)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(workspace.updatedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(workspace.title)")
        .accessibilityHint("Opens the native workspace editor")
    }
}
