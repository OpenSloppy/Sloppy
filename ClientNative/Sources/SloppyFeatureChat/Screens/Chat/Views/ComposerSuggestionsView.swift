//
//  ComposerSuggestionsView.swift
//  SloppyClient
//
//  Created by Vladislav Prusakov on 12.07.2026.
//

import SwiftUI

struct ComposerSuggestionsView: View {
    static let panelHeight: CGFloat = 320

    let suggestions: [ChatComposerSuggestion]
    let selectedSuggestionID: ChatComposerSuggestion.ID?
    let select: @MainActor (ChatComposerSuggestion) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                        if index == 0 || suggestions[index - 1].kind != suggestion.kind {
                            Text(groupTitle(for: suggestion.kind))
                                .font(.caption).foregroundStyle(theme.colors.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, theme.spacing.m).padding(.top, theme.spacing.s)
                        }
                        Button {
                            select(suggestion)
                        } label: {
                            HStack(spacing: theme.spacing.s) {
                                Image(systemName: symbol(for: suggestion.kind))
                                    .frame(width: 20)
                                    .foregroundColor(theme.colors.textSecondary)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(suggestion.title)
                                        .foregroundColor(theme.colors.textPrimary)
                                        .lineLimit(1)
                                    if !suggestion.subtitle.isEmpty {
                                        Text(suggestion.subtitle)
                                            .font(.caption)
                                            .foregroundColor(theme.colors.textSecondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, theme.spacing.m)
                            .padding(.vertical, theme.spacing.xs)
                            .background {
                                if selectedSuggestionID == suggestion.id {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(theme.colors.surfaceRaised)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(suggestion.id)
                        .accessibilityIdentifier("chat.composer.suggestion.\(suggestion.id)")
                    }
                }
                .padding(theme.spacing.xs)
            }
            .onChange(of: selectedSuggestionID) { _, selectedID in
                guard let selectedID else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(selectedID, anchor: .center)
                }
            }
        }
        .frame(
            maxWidth: ChatComposerView.panelWidth,
            minHeight: Self.panelHeight,
            maxHeight: Self.panelHeight,
            alignment: .top
        )
        .backportGlassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        .padding(.horizontal, theme.spacing.s)
    }

    private func groupTitle(for kind: ChatComposerSuggestionKind) -> String {
        switch kind {
        case .command: "Commands"
        case .skill: "Skills"
        case .file: "Files"
        case .task: "Tasks"
        case .session: "Sessions"
        }
    }

    private func symbol(for kind: ChatComposerSuggestionKind) -> String {
        switch kind {
        case .command: "command"
        case .skill: "sparkles"
        case .file: "doc"
        case .task: "checkmark.circle"
        case .session: "bubble.left.and.bubble.right"
        }
    }
}

#Preview {
    ComposerSuggestionsView(suggestions: [
        ChatComposerSuggestion(id: "1", kind: ChatComposerSuggestionKind.skill, title: "skill", subtitle: "skill", insertion: "eee"),
        ChatComposerSuggestion(id: "12", kind: ChatComposerSuggestionKind.skill, title: "skill", subtitle: "skill", insertion: "eee"),
        ChatComposerSuggestion(id: "2", kind: ChatComposerSuggestionKind.skill, title: "skill", subtitle: "skill", insertion: "eee"),
        ChatComposerSuggestion(id: "3", kind: ChatComposerSuggestionKind.skill, title: "skill", subtitle: "skill", insertion: "eee"),
        ChatComposerSuggestion(id: "4", kind: ChatComposerSuggestionKind.skill, title: "skill", subtitle: "skill", insertion: "eee"),
        ChatComposerSuggestion(id: "33", kind: ChatComposerSuggestionKind.skill, title: "skill", subtitle: "skill", insertion: "eee"),
        ChatComposerSuggestion(id: "22", kind: ChatComposerSuggestionKind.skill, title: "skill", subtitle: "skill", insertion: "eee"),
        ChatComposerSuggestion(id: "11", kind: ChatComposerSuggestionKind.skill, title: "skill", subtitle: "skill", insertion: "eee")
    ], selectedSuggestionID: "1", select: { _ in

    })
}
