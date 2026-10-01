import Foundation
import SwiftUI
import SloppyClientCore
import SloppyClientUI
import Textual

struct ChatTextSelectionActions {
    var addToChat: (@MainActor @Sendable (String) -> Void)?
    var moreDetails: (@MainActor @Sendable (String) -> Void)?
    var askInSideChat: (@MainActor @Sendable (String) -> Void)?

    var textualActions: [TextSelectionAction] {
        [
            addToChat.map { handler in
                TextSelectionAction("Add to chat") { text in
                    // The selection menu still owns first responder while its action runs.
                    DispatchQueue.main.async {
                        handler(text)
                    }
                }
            },
            moreDetails.map { handler in
                TextSelectionAction("More details") { text in
                    DispatchQueue.main.async {
                        handler(text)
                    }
                }
            },
            askInSideChat.map { handler in
                TextSelectionAction("Ask in side chat", handler: handler)
            },
        ].compactMap { $0 }
    }
}

extension EnvironmentValues {
    @Entry var chatTextSelectionActions = ChatTextSelectionActions()
}

public struct ChatBubbleView: View {
    private static let userBubbleRadius: CGFloat = 18

    public let message: ChatMessage
    public let isActivelyWorking: Bool
    public let onOpenProviderSettings: (@MainActor () -> Void)?
    public let onForkFromMessage: (@MainActor (ChatMessage) -> Void)?

    public init(
        message: ChatMessage,
        isActivelyWorking: Bool = false,
        onOpenProviderSettings: (@MainActor () -> Void)? = nil,
        onForkFromMessage: (@MainActor (ChatMessage) -> Void)? = nil
    ) {
        self.message = message
        self.isActivelyWorking = isActivelyWorking
        self.onOpenProviderSettings = onOpenProviderSettings
        self.onForkFromMessage = onForkFromMessage
    }

    @Environment(\.userInterfaceIdiom) private var idiom
    @Environment(\.theme) private var theme
    private var isStreamingAssistant: Bool { message.id.hasPrefix("streaming-assistant-") }
    private var showsMessageActions: Bool {
        !isStreamingAssistant
            && !isActivelyWorking
            && message.role == .assistant
            && message.segments.contains { $0.kind == .text }
            && message.segments.allSatisfy { $0.kind == .text || $0.kind == .status }
    }

    public var body: some View {
        switch message.role {
        case .user:
            userMessage
                .multilineTextAlignment(.leading)
                .padding(.bottom, 16)
        case .system:
            systemMessage
                .multilineTextAlignment(.leading)
        case .assistant:
            assistantMessage
                .multilineTextAlignment(.leading)
        }
    }

    @ViewBuilder
    private var userMessage: some View {
        desktopUserMessage
    }

    private var desktopUserMessage: some View {
        let c = theme.colors
        let sp = theme.spacing

        return HStack(spacing: 0) {
            Spacer(minLength: sp.xxl)

            ChatUserMessageContent {
                renderedSegmentStack(forceCollapsible: false)
            }
                .id(message.id)
                .padding(.horizontal, sp.m)
                .padding(.vertical, sp.s)
                .background {
                    RoundedRectangle(cornerRadius: Self.userBubbleRadius)
                        .fill(c.surfaceGlow)
                        .overlay {
                            RoundedRectangle(cornerRadius: Self.userBubbleRadius)
                                .stroke(c.border.opacity(0.72), lineWidth: theme.borders.thin)
                        }
                }
        }
    }

    @ViewBuilder
    private var assistantMessage: some View {
        desktopAssistantMessage
    }

    private var desktopAssistantMessage: some View {
        let sp = theme.spacing

        return VStack(alignment: .leading, spacing: sp.m) {
            renderedSegmentStack(forceCollapsible: false)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            if let onOpenProviderSettings {
                Button(action: onOpenProviderSettings) {
                    Label("Provider Settings", systemImage: "gearshape")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if showsMessageActions {
                HStack {
                    Button(action: {
                        UIClipboard.setString(message.textContent)
                    }, label: {
                        Image(systemName: "rectangle.on.rectangle")
                            .scaleEffect(x: -1)
                            .padding(.all, 4)
                    })
                    .accessibilityLabel("Copy response")

                    Button(action: {
                        onForkFromMessage?(message)
                    }, label: {
                        Image(systemName: "arrow.trianglehead.branch")
                            .rotationEffect(.degrees(90))
                            .padding(.all, 4)
                    })
                    .disabled(onForkFromMessage == nil)
                    .accessibilityLabel("Fork session from this response")
                }
                .font(.system(size: theme.typography.body, weight: .semibold))
                .foregroundStyle(theme.colors.textSecondary)
                #if os(visionOS)
                .backportGlassEffect(.regular, in: .capsule)
                #else
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                #endif
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private var systemMessage: some View {
        ChatSystemMessageGroupView(
            messages: [message],
            activeRunMessageIDs: isActivelyWorking ? [message.id] : []
        )
    }

    @ViewBuilder
    private func renderedSegmentStack(forceCollapsible: Bool) -> some View {
        VStack(alignment: .leading, spacing: theme.spacing.m) {
            ForEach(Array(message.segments.enumerated()), id: \.offset) { index, segment in
                if let progress = segment.buildProgress {
                    ChatBuildProgressView(progress: progress)
                } else if shouldRenderAsCollapsible(segment, forceCollapsible: forceCollapsible) {
                    ChatSegmentCollapsibleCard(
                        message: message,
                        segment: segment,
                        isRunning: isSegmentRunning(segment)
                            || (isActivelyWorking && segment.kind == .thinking)
                    )
                } else if message.role == .user {
                    if let text = segment.text,
                       text.hasPrefix("> ") || !ChatComposerCodeFence.ranges(in: text).isEmpty {
                        ChatMarkdownTextStack(text: text)
                    } else {
                        // Plain user input has an intrinsic size before markdown parses.
                        Text(verbatim: segment.text ?? "…")
                            .font(.system(size: theme.typography.body))
                            .foregroundStyle(theme.colors.textPrimary)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    ChatMarkdownTextStack(
                        text: segment.text ?? "…",
                        allowsTextSelection: !isStreamingAssistant && !isActivelyWorking,
                        renderImmediately: !isStreamingAssistant
                    )
                }
            }
        }
    }

    private func shouldRenderAsCollapsible(_ segment: ChatMessageSegment, forceCollapsible: Bool) -> Bool {
        if forceCollapsible {
            return true
        }

        switch segment.kind {
        case .text:
            return false
        case .thinking, .attachment, .toolCall, .toolResult, .status, .buildProgress:
            return true
        }
    }

    private func isSegmentRunning(_ segment: ChatMessageSegment) -> Bool {
        isActivelyWorking && segment.isExecutionRunning
    }
}

/// Measures the rendered content so wrapping, markdown and multiple segments share one budget.
struct ChatUserMessageContent<Content: View>: View {
    static var previewLineLimit: Int { 12 }

    @ViewBuilder let content: () -> Content
    @State private var isExpanded = false
    @State private var contentHeight: CGFloat = 0
    @State private var lineHeight: CGFloat = 0
    @Environment(\.theme) private var theme

    private var previewHeight: CGFloat {
        let measuredLineHeight = lineHeight > 0 ? lineHeight : ceil(theme.typography.body * 1.3)
        return measuredLineHeight * CGFloat(Self.previewLineLimit)
            + 4 * CGFloat(Self.previewLineLimit - 1)
    }

    private var canCollapse: Bool { contentHeight > previewHeight + 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.s) {
            content()
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.height
                } action: { height in
                    contentHeight = height
                }
                .frame(maxHeight: isExpanded ? nil : previewHeight, alignment: .top)
                .clipped()

            if canCollapse {
                Button {
                    isExpanded.toggle()
                } label: {
                    Label(isExpanded ? "Show less" : "Show more",
                          systemImage: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: theme.typography.caption))
                        .foregroundStyle(theme.colors.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat.user-message.toggle-expansion")
            }
        }
        .background(alignment: .topLeading) {
            // SwiftUI's line metrics differ from AppKit/UIKit's font metrics.
            Text("Ag")
                .font(.system(size: theme.typography.body))
                .fixedSize()
                .hidden()
                .accessibilityHidden(true)
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.height
                } action: { height in
                    lineHeight = height
                }
        }
    }
}

struct ChatSystemMessageGroupView: View {
    private static let activityHeight: CGFloat = 260

    let messages: [ChatMessage]
    var activeRunMessageIDs: Set<ChatMessage.ID> = []

    @State private var isExpanded = false
    @Environment(\.theme) private var theme

    var body: some View {
        let items = segmentItems
        let visibleItems = ChatSystemActivityVisibility.visibleItems(
            from: items,
            isExpanded: isExpanded
        )

        VStack(alignment: .leading, spacing: theme.spacing.s) {
            groupHeader(items: items)

            if isExpanded && !visibleItems.isEmpty {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: theme.spacing.xs) {
                        ForEach(visibleItems) { item in
                            segmentRow(item, insideScroll: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: Self.activityHeight)
                .padding(.leading, 28)
            } else if !visibleItems.isEmpty {
                VStack(alignment: .leading, spacing: theme.spacing.xs) {
                    ForEach(visibleItems) { item in
                        segmentRow(item, insideScroll: false)
                    }
                }
                .padding(.leading, 28)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private func groupHeader(items: [ChatSystemSegmentItem]) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: theme.spacing.s) {
                Icons.symbol(isExpanded ? .collapseContent : .expandMore, size: theme.typography.caption)
                    .foregroundColor(theme.colors.textMuted)

                Text(summaryTitle(for: items))
                    .font(.system(size: theme.typography.caption))
                    .foregroundColor(theme.colors.textSecondary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Collapse activity" : "Expand activity")
    }

    private func segmentRow(_ item: ChatSystemSegmentItem, insideScroll: Bool) -> some View {
        ChatSegmentCollapsibleCard(
            message: item.message,
            segment: item.segment,
            isRunning: item.isRunning,
            isInsideActivityScroll: insideScroll
        )
    }

    private var segmentItems: [ChatSystemSegmentItem] {
        messages.flatMap { message in
            message.segments.enumerated().map { index, segment in
                ChatSystemSegmentItem(
                    id: "\(message.id):\(index)",
                    message: message,
                    segment: segment,
                    isRunning: activeRunMessageIDs.contains(message.id)
                        && segment.isExecutionRunning
                )
            }
        }
    }

    private func summaryTitle(for items: [ChatSystemSegmentItem]) -> String {
        let titles = items.compactMap { item -> String? in
            guard let title = item.segment.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else {
                return nil
            }
            return title
        }
        return titles.isEmpty ? "Activity" : titles.prefix(3).joined(separator: " · ")
    }
}

struct ChatSystemSegmentItem: Identifiable {
    let id: String
    let message: ChatMessage
    let segment: ChatMessageSegment
    let isRunning: Bool

    init(
        id: String,
        message: ChatMessage,
        segment: ChatMessageSegment,
        isRunning: Bool? = nil
    ) {
        self.id = id
        self.message = message
        self.segment = segment
        self.isRunning = isRunning ?? segment.isExecutionRunning
    }

    var toolExecutionKey: String? {
        guard let title = segment.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return nil
        }
        return title
    }
}

enum ChatSystemActivityVisibility {
    static func visibleItems(
        from items: [ChatSystemSegmentItem],
        isExpanded: Bool
    ) -> [ChatSystemSegmentItem] {
        guard !isExpanded else { return items }

        var pendingCallIndicesByTool: [String: [Int]] = [:]
        for (index, item) in items.enumerated() {
            guard let toolKey = item.toolExecutionKey else { continue }

            switch item.segment.kind {
            case .toolCall where item.isRunning:
                pendingCallIndicesByTool[toolKey, default: []].append(index)
            case .toolResult:
                guard pendingCallIndicesByTool[toolKey]?.isEmpty == false else { continue }
                pendingCallIndicesByTool[toolKey]?.removeFirst()
            case .text, .thinking, .attachment, .toolCall, .status, .buildProgress:
                continue
            }
        }

        let pendingIndices = Set(pendingCallIndicesByTool.values.joined())
        return items.enumerated().compactMap { index, item in
            pendingIndices.contains(index) ? item : nil
        }
    }
}

struct ChatThinkingIndicator: View {
    let label: String
    let details: String?

    @Environment(\.theme) private var theme

    var body: some View {
        HStack {
            ChatShimmerText(text: label)
                .font(.system(size: theme.typography.body, weight: .medium))
            Spacer(minLength: 0)
        }
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        guard let details, !details.isEmpty else { return label }
        return "\(label). \(details)"
    }
}

private struct ChatMarkdownTextStack: View {
    let text: String
    var allowsTextSelection = true
    var renderImmediately = true

    @Environment(\.theme) private var theme
    @Environment(\.chatTextSelectionActions) private var selectionActions

    @ViewBuilder
    var body: some View {
        #if os(macOS)
        if allowsTextSelection {
            structuredText
                .textual.textSelection(.enabled)
                .textual.textSelectionActions(selectionActions.textualActions)
        } else {
            structuredText
        }
        #else
        if allowsTextSelection {
            structuredText
                .textual.textSelection(.enabled)
        } else {
            structuredText
        }
        #endif
    }

    private var structuredText: some View {
        let ty = theme.typography

        return StructuredText(markdown: text, renderImmediately: renderImmediately)
            .textual.structuredTextStyle(.gitHub)
            .font(.system(size: ty.body))
            .lineSpacing(4)
            .foregroundColor(theme.colors.textPrimary)
            .tint(theme.colors.accentCyan)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ChatSegmentCollapsibleCard: View {
    private static let detailHeight: CGFloat = 260

    let message: ChatMessage
    let segment: ChatMessageSegment
    let isRunning: Bool
    var isInsideActivityScroll = false

    @State private var isExpanded = false
    @Environment(\.theme) private var theme

    var body: some View {
        let sp = theme.spacing

        VStack(alignment: .leading, spacing: sp.s) {
            if showsLiveDuration {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    timelineRow(durationText: durationLabel(at: timeline.date))
                }
            } else {
                timelineRow(durationText: staticDurationLabel)
            }

            if isExpanded {
                Group {
                    if isInsideActivityScroll {
                        detailContent
                    } else {
                        ScrollView(.vertical) {
                            detailContent
                        }
                        .frame(height: Self.detailHeight)
                    }
                }
                .padding(.leading, 28)
            }
        }
        .padding(.vertical, sp.xs)
    }

    @ViewBuilder
    private var detailContent: some View {
        if segment.kind == .toolCall || segment.kind == .toolResult {
            terminalDetail
        } else {
            VStack(alignment: .leading, spacing: theme.spacing.s) {
                if let text = segment.text, !text.isEmpty {
                    ChatMarkdownTextStack(text: text, allowsTextSelection: !isRunning)
                }
                metadataRows
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var terminalDetail: some View {
        let c = theme.colors
        let sp = theme.spacing
        let metadata = segment.metadata ?? [:]
        let inputKey = ["cmd", "command", "script", "input"].first { metadata[$0] != nil }

        return VStack(alignment: .leading, spacing: sp.s) {
            Text(segment.kind == .toolCall ? "input" : "output")
                .font(.system(size: theme.typography.micro, design: .monospaced))
                .foregroundColor(c.textMuted)

            if let inputKey, let input = metadata[inputKey] {
                Text(verbatim: "$ \(input)")
                    .foregroundColor(c.textPrimary)
                    .textSelection(.enabled)
            }

            if let text = segment.text, !text.isEmpty {
                Text(verbatim: text)
                    .foregroundColor(c.textSecondary)
                    .textSelection(.enabled)
            }

            metadataRows(excluding: inputKey)
        }
        .font(.system(size: theme.typography.caption, design: .monospaced))
        .lineSpacing(4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(sp.m)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(c.surfaceGlow)
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(c.borderBold, lineWidth: theme.borders.thin)
                }
        }
    }

    @ViewBuilder
    private var metadataRows: some View {
        metadataRows(excluding: nil)
    }

    @ViewBuilder
    private func metadataRows(excluding excludedKey: String?) -> some View {
        if let metadata = segment.metadata, !metadata.isEmpty {
            VStack(alignment: .leading, spacing: theme.spacing.xs) {
                ForEach(metadata.keys.sorted().filter { $0 != excludedKey }, id: \.self) { key in
                    HStack(alignment: .top, spacing: theme.spacing.xs) {
                        Text(key)
                            .font(.system(size: theme.typography.micro, design: .monospaced))
                            .foregroundColor(theme.colors.textMuted)
                        metadataValue(metadata[key] ?? "")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func metadataValue(_ value: String) -> some View {
        let text = Text(value)
            .font(.system(size: theme.typography.caption, design: .monospaced))
            .foregroundColor(theme.colors.textSecondary)

        if isRunning {
            text
        } else {
            text.textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func timelineRow(durationText: String?) -> some View {
        let c = theme.colors
        let sp = theme.spacing

        HStack(spacing: sp.s) {
            Image(systemName: segmentSystemImage)
                .font(.system(size: theme.typography.caption))
                .foregroundColor(c.textMuted)
                .frame(width: 18)

            if isRunning {
                ChatShimmerText(text: segmentTitle)
                    .font(.system(size: theme.typography.caption))
            } else {
                Text(segmentTitle)
                    .font(.system(size: theme.typography.caption))
                    .foregroundColor(c.textSecondary)
                    .lineLimit(1)
            }

            if let durationText {
                Text(durationText)
                    .font(.system(size: theme.typography.micro))
                    .foregroundColor(c.textMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if hasExpandableContent {
                Icons.symbol(isExpanded ? .collapseContent : .expandMore, size: theme.typography.caption)
                    .foregroundColor(c.textMuted)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.1)) {
                isExpanded.toggle()
            }
        }
    }

    private var hasExpandableContent: Bool {
        if let text = segment.text, !text.isEmpty {
            return true
        }
        return segment.metadata?.isEmpty == false
    }

    private var segmentSystemImage: String {
        switch segment.kind {
        case .text:
            return "text.alignleft"
        case .thinking:
            return "brain.head.profile"
        case .attachment:
            return "paperclip"
        case .toolCall:
            return "terminal"
        case .toolResult:
            return "book.closed"
        case .status:
            return "circle.dotted"
        case .buildProgress:
            return "chart.bar"
        }
    }

    private var segmentTitle: String {
        if let attachmentName = segment.attachment?.name.trimmingCharacters(in: .whitespacesAndNewlines),
           !attachmentName.isEmpty {
            return attachmentName
        }
        if let title = segment.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }

        switch segment.kind {
        case .text:
            return message.role == .system ? "System" : "Message"
        case .thinking:
            return "Thinking"
        case .attachment:
            return "Attachment"
        case .toolCall:
            return "Tool call"
        case .toolResult:
            return "Tool result"
        case .status:
            return "Status"
        case .buildProgress:
            return "Progress"
        }
    }

    private var showsLiveDuration: Bool {
        isRunning && segment.startedAt != nil && segment.finishedAt == nil
    }

    private var staticDurationLabel: String? {
        durationLabel(at: segment.finishedAt ?? Date())
    }

    private func durationLabel(at now: Date) -> String? {
        guard let startedAt = segment.startedAt else { return nil }
        let end = segment.finishedAt ?? now
        return ChatCompactDurationFormatter.string(for: end.timeIntervalSince(startedAt))
    }
}

private struct ChatShimmerText: View {
    let text: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.theme) private var theme

    var body: some View {
        if reduceMotion {
            Text(text)
                .foregroundStyle(theme.colors.textSecondary)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                let progress = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 1.8) / 1.8
                let center = -0.35 + progress * 1.7

                Text(text)
                    .foregroundStyle(theme.colors.textMuted)
                    .overlay {
                        GeometryReader { geometry in
                            LinearGradient(
                                colors: [
                                    theme.colors.textPrimary.opacity(0 as Double),
                                    theme.colors.textPrimary,
                                    theme.colors.textPrimary.opacity(0 as Double),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: geometry.size.width * 0.7)
                            .offset(x: geometry.size.width * (center - 0.35))
                        }
                        .mask(Text(text))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
            }
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        ChatBubbleView(message: .init(role: .user, segments: [
            .init(kind: .text, text: "# Note\n\nPlease read `main.swift`.")
        ]))

        ChatBubbleView(message: .init(role: .system, segments: [
            .init(kind: .status, text: "Waiting for approval", title: "System", status: "running", startedAt: Date().addingTimeInterval(-12))
        ]))

        ChatBubbleView(message: .init(role: .assistant, segments: [
            .init(kind: .thinking, text: "Comparing two implementations", status: "running", startedAt: Date().addingTimeInterval(-8)),
            .init(kind: .toolCall, text: "Sources/App.swift", title: "Read file", status: "running", startedAt: Date().addingTimeInterval(-4)),
            .init(kind: .text, text: "## Result\n\n```swift\nlet value = 42\n```\n\nSee [docs](https://example.com).")
        ]))

        Spacer()
    }
    .padding(.all, 16)
    .environment(\.userInterfaceIdiom, .desktop)
    #if os(macOS)
    .frame(width: 1024, height: 800)
    #endif
}


#Preview {
    VStack(spacing: 16) {
        ChatBubbleView(message: .init(role: .user, segments: [
            .init(kind: .text, text: "# Note\n\nPlease read `main.swift`.")
        ]))

        ChatBubbleView(message: .init(role: .system, segments: [
            .init(kind: .status, text: "Waiting for approval", title: "System", status: "running", startedAt: Date().addingTimeInterval(-12))
        ]))

        ChatBubbleView(message: .init(role: .assistant, segments: [
            .init(kind: .thinking, text: "Comparing two implementations", status: "running", startedAt: Date().addingTimeInterval(-8)),
            .init(kind: .toolCall, text: "Sources/App.swift", title: "Read file", status: "running", startedAt: Date().addingTimeInterval(-4)),
            .init(kind: .text, text: "## Result\n\n```swift\nlet value = 42\n```\n\nSee [docs](https://example.com).")
        ]))

        Spacer()
    }
    .padding(.all, 16)
    .environment(\.userInterfaceIdiom, .phone)
#if os(macOS)
    .frame(width: 1024, height: 800)
#endif
}
