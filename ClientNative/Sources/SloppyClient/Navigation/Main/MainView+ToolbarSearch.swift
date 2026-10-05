import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import SloppyClientCore
import SloppyClientUI
import SloppyFeatureAgents
import SloppyFeatureChat
import SloppyFeatureProjects
import SloppyFeatureSettings
import SloppyFeatureSites

@MainActor
extension MainView {
#if os(macOS)
    var toolbarApprovalButton: some View {
        Button {
            guard !approvalRequiredSessionIDs.isEmpty else { return }
            withAnimation(.easeInOut(duration: 0.16)) {
                showsApprovalRequiredChatsOnly.toggle()
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: showsApprovalRequiredChatsOnly ? "bell.fill" : "bell")
                    .frame(width: 24, height: 24)

                if !approvalRequiredSessionIDs.isEmpty {
                    Text(approvalRequiredSessionIDs.count > 99 ? "99+" : "\(approvalRequiredSessionIDs.count)")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 14, minHeight: 14)
                        .background(.red, in: Capsule())
                        .offset(x: 6, y: -5)
                }
            }
        }
        .foregroundStyle(showsApprovalRequiredChatsOnly ? Color.accentColor : Color.primary)
        .help(showsApprovalRequiredChatsOnly ? "Show all chats" : "Show chats requiring approval")
        .accessibilityLabel("Chats requiring approval")
        .accessibilityValue("\(approvalRequiredSessionIDs.count)")
        .accessibilityIdentifier("toolbar.approval-chats")
    }

    var toolbarSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search chats and projects", text: $toolbarSearchText)
                .textFieldStyle(.plain)
                .focused($isToolbarSearchFocused)
                .onKeyPress(.downArrow) {
                    moveToolbarSearchSelection(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    moveToolbarSearchSelection(by: -1)
                    return .handled
                }
                .onSubmit {
                    openSelectedToolbarSearchResult()
                }
                .onExitCommand {
                    dismissToolbarSearch()
                }

            if !toolbarSearchText.isEmpty {
                Button {
                    dismissToolbarSearch(keepsFocus: true)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(minWidth: 280, idealWidth: 420, maxWidth: 560, minHeight: 30)
        .onChange(of: toolbarSearchText) { _, text in
            isToolbarSearchResultsPresented = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            toolbarSearchSelectionID = toolbarSearchResults.first?.id
        }
        .onChange(of: toolbarSearchResultIDs) { _, resultIDs in
            if let toolbarSearchSelectionID,
               resultIDs.contains(toolbarSearchSelectionID) {
                return
            }
            toolbarSearchSelectionID = resultIDs.first
        }
    }

    var toolbarSearchQuery: String {
        toolbarSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var matchingToolbarChatSessions: [ChatSessionSummary] {
        guard !toolbarSearchQuery.isEmpty else {
            return []
        }
        return viewModel.chatViewModel.sessionCatalog.filter {
            $0.title.localizedStandardContains(toolbarSearchQuery)
        }
    }

    var matchingToolbarProjects: [APIProjectRecord] {
        guard !toolbarSearchQuery.isEmpty else {
            return []
        }
        return viewModel.projects.filter {
            $0.name.localizedStandardContains(toolbarSearchQuery)
        }
    }

    var visibleToolbarChatSessions: [ChatSessionSummary] {
        Array(matchingToolbarChatSessions.prefix(8))
    }

    var visibleToolbarProjects: [APIProjectRecord] {
        Array(matchingToolbarProjects.prefix(8))
    }

    var toolbarSearchResults: [ToolbarSearchResult] {
        visibleToolbarChatSessions.map(ToolbarSearchResult.chat)
        + visibleToolbarProjects.map(ToolbarSearchResult.project)
    }

    var toolbarSearchResultIDs: [ToolbarSearchResult.ID] {
        toolbarSearchResults.map(\.id)
    }

    var toolbarSearchResultsPanelHeight: CGFloat {
        let resultCount = visibleToolbarChatSessions.count + visibleToolbarProjects.count
        let sectionCount = (matchingToolbarChatSessions.isEmpty ? 0 : 1)
        + (matchingToolbarProjects.isEmpty ? 0 : 1)
        return min(420, max(64, CGFloat(resultCount) * 38 + CGFloat(sectionCount) * 30 + 16))
    }

    @ViewBuilder
    var toolbarSearchResultsOverlay: some View {
        if isToolbarSearchResultsPresented && !isCanvasWorkspaceSelected {
            toolbarSearchResultsPanel
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(10)
                .animation(.easeOut(duration: 0.14), value: isToolbarSearchResultsPresented)
        }
    }

    var toolbarSearchResultsPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    toolbarSearchSuggestions
                }
                .padding(8)
            }
            .onChange(of: toolbarSearchSelectionID) { _, selectionID in
                guard let selectionID else {
                    return
                }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(selectionID, anchor: .center)
                }
            }
        }
        .frame(width: 560, height: toolbarSearchResultsPanelHeight)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.8), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
    }

    @ViewBuilder
    var toolbarSearchSuggestions: some View {
        if !matchingToolbarChatSessions.isEmpty {
            Text("Chats")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .frame(height: 28)

            ForEach(visibleToolbarChatSessions) { session in
                let result = ToolbarSearchResult.chat(session)
                ToolbarSearchResultRow(
                    title: session.displayTitle,
                    subtitle: "Chat",
                    systemImage: "bubble.left",
                    isSelected: toolbarSearchSelectionID == result.id,
                    onHover: {
                        toolbarSearchSelectionID = result.id
                    },
                    action: {
                        openToolbarSearchResult(result)
                    }
                )
                .id(result.id)
            }
        }

        if !matchingToolbarProjects.isEmpty {
            Text("Projects")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .frame(height: 28)

            ForEach(visibleToolbarProjects) { project in
                let result = ToolbarSearchResult.project(project)
                ToolbarSearchResultRow(
                    title: project.name,
                    subtitle: project.kind == .workspace ? "Workspace" : "Project",
                    systemImage: project.semanticIconName,
                    isSelected: toolbarSearchSelectionID == result.id,
                    onHover: {
                        toolbarSearchSelectionID = result.id
                    },
                    action: {
                        openToolbarSearchResult(result)
                    }
                )
                .id(result.id)
            }
        }

        if !toolbarSearchQuery.isEmpty,
           matchingToolbarChatSessions.isEmpty,
           matchingToolbarProjects.isEmpty {
            Text("No chats or projects found")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 48)
        }
    }

    func moveToolbarSearchSelection(by offset: Int) {
        let results = toolbarSearchResults
        guard !results.isEmpty else {
            toolbarSearchSelectionID = nil
            return
        }

        guard let toolbarSearchSelectionID,
              let selectedIndex = results.firstIndex(where: { $0.id == toolbarSearchSelectionID }) else {
            self.toolbarSearchSelectionID = offset < 0 ? results.last?.id : results.first?.id
            return
        }

        let nextIndex = (selectedIndex + offset + results.count) % results.count
        self.toolbarSearchSelectionID = results[nextIndex].id
    }

    func openSelectedToolbarSearchResult() {
        let result = toolbarSearchResults.first {
            $0.id == toolbarSearchSelectionID
        } ?? toolbarSearchResults.first
        guard let result else {
            return
        }
        openToolbarSearchResult(result)
    }

    func openToolbarSearchResult(_ result: ToolbarSearchResult) {
        switch result {
        case .chat(let session):
            viewModel.openSessionChatTab(session)
        case .project(let project):
            viewModel.openProjectKanbanTab(project: project)
        }
        dismissToolbarSearch()
    }

    func dismissToolbarSearch(keepsFocus: Bool = false) {
        toolbarSearchText = ""
        toolbarSearchSelectionID = nil
        isToolbarSearchResultsPresented = false
        if !keepsFocus {
            isToolbarSearchFocused = false
        }
    }
#endif
}

