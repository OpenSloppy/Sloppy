import SwiftUI
import SloppyClientCore
import SloppyClientUI

/// Task context for Inbox status lists; the surrounding NavigationLink owns the action.
public struct ProjectTaskInboxRow: View {
    private let task: APIProjectTask
    private let actorName: String?
    private let attention: ProactiveFinding?
    private let descriptionPreview: AttributedString?
    @Environment(\.theme) private var theme

    public init(task: APIProjectTask, actorName: String? = nil, attention: ProactiveFinding? = nil) {
        self.task = task
        self.actorName = actorName
        self.attention = attention
        if let description = task.description, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let excerpt = TaskMarkdown.normalized(String(description.prefix(1_000)))
            self.descriptionPreview = Self.preview(excerpt)
        } else {
            self.descriptionPreview = nil
        }
    }

    /// Text renders inline Markdown attributes but doesn't insert block separators.
    nonisolated static func preview(_ excerpt: String) -> AttributedString {
        guard let markdown = try? AttributedString(markdown: excerpt) else { return AttributedString(excerpt) }
        var preview = AttributedString()
        var previousBlock: PresentationIntent?
        for run in markdown.runs {
            if run.presentationIntent != previousBlock, !preview.characters.isEmpty {
                preview.append(AttributedString("\n"))
            }
            preview.append(AttributedString(markdown[run.range]))
            previousBlock = run.presentationIntent
        }
        return preview
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(task.externalMetadata?.externalIssueKey ?? task.id)
                .font(.caption.monospaced())
                .foregroundStyle(theme.colors.textMuted)
            Text(task.title)
                .font(.headline)
                .foregroundStyle(theme.colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                StatusBadge.forTaskStatus(task.status)
                if let priority = task.priority, !priority.isEmpty {
                    TaskPriorityChip(priority: priority)
                }
            }
            if let attention {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Why it matters").font(.caption.weight(.semibold))
                    Text(attention.reason).font(.subheadline).lineLimit(3)
                    Label("Next step", systemImage: "arrow.turn.down.right").font(.caption.weight(.semibold))
                    Text(attention.nextStep).font(.subheadline).lineLimit(3)
                }
                .foregroundStyle(theme.colors.textSecondary)
            } else if let descriptionPreview {
                Text(descriptionPreview)
                    .tint(theme.colors.textPrimary)
                    .font(.subheadline)
                    .foregroundStyle(theme.colors.textSecondary)
                    .lineLimit(3)
                    .accessibilityIdentifier("inbox.task.description.\(task.id)")
            }
            VStack(alignment: .leading, spacing: 6) {
                if let actor = actorName ?? task.claimedActorId ?? task.claimedAgentId ?? task.actorId {
                    Label(actor, systemImage: "person.crop.circle")
                }
                if let updated = task.updatedAt {
                    Label("Updated \(updated.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock")
                }
                if let dependencies = task.dependsOnTaskIds, !dependencies.isEmpty {
                    Label("Depends on \(dependencies.joined(separator: ", "))", systemImage: "arrow.triangle.branch")
                }
            }
            .font(.caption)
            .foregroundStyle(theme.colors.textMuted)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inbox.task.\(task.id)")
    }
}
