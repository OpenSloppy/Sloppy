import Foundation
import SloppyClientCore
import SloppyClientUI
import SwiftUI

@MainActor
struct PullRequestDetailView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case summary = "Summary"
        case code = "Code"

        var id: Self { self }
    }

    let apiClient: SloppyAPIClient
    let item: CodeReviewItem
    let showsBackButton: Bool
    let onBack: @MainActor () -> Void
    var onBeginReview: @MainActor () -> Void = {}
    let onLinkChat: @MainActor (CodeReviewDetail, ChatSessionSummary) async throws -> Void
    let onSendReview: @MainActor (CodeReviewDetail, CodeReviewSubmission) async throws -> Void

    @Environment(\.openURL) private var openURL
    @State private var mode = Mode.code
    @AppStorage("client_code_review_diff_layout") private var diffLayout = CodeReviewDiffLayout.sideBySide
    @AppStorage("client_code_review_mobile_diff_layout") private var mobileDiffLayout = CodeReviewDiffLayout.oneSide
#if !os(macOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
#endif

    private var isCompact: Bool {
#if os(macOS)
        false
#else
        horizontalSizeClass == .compact
#endif
    }

    private var effectiveDiffLayout: CodeReviewDiffLayout { isCompact ? mobileDiffLayout : diffLayout }
    private var diffLayoutBinding: Binding<CodeReviewDiffLayout> {
        Binding(get: { effectiveDiffLayout }, set: { layout in
            if isCompact { mobileDiffLayout = layout } else { diffLayout = layout }
        })
    }
    @State private var detail: CodeReviewDetail?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var focusedComment: CodeReviewComment?
    @State private var hoveredCommentID: String?
    @State private var replyingCommentID: String?
    @State private var replyDrafts: [String: String] = [:]
    @State private var postingReplyCommentIDs: Set<String> = []
    @State private var replyError: String?
    @State private var fixDrafts: [CodeReviewFixDraft] = []
    @State private var files: [CodeReviewDiffFile] = []
    @State private var focusedFilePath: String?
    @State private var linkedSessions: [ChatSessionSummary] = []
    @State private var isChatBusy = false
    @State private var reviewSelection = CodeReviewSelection()
    @State private var chatError: String?
    @State private var isShowingChatLink = false
    @State private var draftStatus: String?
    @State private var chatActionTask: Task<Void, Never>?
    @FocusState private var focusedFixID: UUID?
    private let draftStore = CodeReviewDraftStore()

    var body: some View {
        VStack(spacing: 0) {
#if os(iOS)
            modePicker.padding(.horizontal, 12).padding(.vertical, 8)
#else
            header
#endif
            Divider()
            if !isCompact {
                reviewToolbar
                Divider()
            }
            if let chatError {
                Label(chatError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
#if os(iOS)
        .navigationTitle(item.number.map { "PR #\($0)" } ?? "Pull Request")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { moreMenu }
        }
#endif
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isCompact { reviewToolbar.background(.background) }
        }
        .task(id: item.id) {
            onBeginReview()
            fixDrafts = draftStore.load(item: item, endpoint: apiClient.endpoint)
            reviewSelection = draftStore.loadSelection(item: item, endpoint: apiClient.endpoint)
            await load()
            guard let detail, !Task.isCancelled else { return }
            linkedSessions = (try? await apiClient.fetchCodeReviewSessions(detail.item)) ?? []
        }
        .onChange(of: fixDrafts) { _, drafts in
            draftStore.save(drafts, item: item, endpoint: apiClient.endpoint)
        }
        .onChange(of: reviewSelection) { _, selection in
            draftStore.saveSelection(selection, item: item, endpoint: apiClient.endpoint)
        }
        .onDisappear { chatActionTask?.cancel() }
        .sheet(isPresented: $isShowingChatLink) {
            CodeReviewChatLinkSheet(apiClient: apiClient) { session in
                runReviewAction { detail in try await onLinkChat(detail, session) }
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        if isCompact {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    backButton
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.callout.weight(.semibold))
                            .lineLimit(2)
                        Text(item.number.map { "PR #\($0)" } ?? item.providerName)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 12) {
                    modePicker.frame(maxWidth: .infinity)
                    moreMenu.frame(width: 44, height: 44)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        } else {
            HStack(spacing: 10) {
                backButton
                Image(systemName: "arrow.triangle.branch").foregroundStyle(stateColor)
                Text(item.title).font(.callout.weight(.medium)).lineLimit(1)
                Spacer(minLength: 12)
                modePicker.frame(width: 150)
                moreMenu.frame(width: 32, height: 32)
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
        }
    }

    @ViewBuilder
    private var backButton: some View {
        if showsBackButton {
            Button(action: onBack) { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .frame(width: isCompact ? 36 : 24, height: isCompact ? 44 : 32)
                .accessibilityLabel("Back to pull requests")
        }
    }

    private var modePicker: some View {
        Picker("View", selection: $mode) {
            ForEach(Mode.allCases) { mode in Text(mode.rawValue).tag(mode) }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
    }

    private var moreMenu: some View {
        Menu {
            Button("Open pull request in browser", systemImage: "arrow.up.right.square") {
                if let url = URL(string: item.url) { openURL(url) }
            }
            if isCompact {
                Picker("Diff layout", selection: diffLayoutBinding) {
                    ForEach(CodeReviewDiffLayout.allCases) { layout in Text(layout.title).tag(layout) }
                }
            }
            if let detail {
                Button("Add open comments to review", systemImage: "text.bubble") {
                    includeOpenComments(detail)
                }
            }
            if !linkedSessions.isEmpty {
                Section("Send review to") {
                    ForEach(linkedSessions) { session in
                        Button("\(session.title) · \(session.agentId)") {
                            runReviewAction { detail in try await onLinkChat(detail, session) }
                        }
                    }
                }
            }
            Button("Link working chat…", systemImage: "link") { isShowingChatLink = true }
        } label: {
            Image(systemName: "ellipsis").frame(width: isCompact ? 44 : 32, height: isCompact ? 44 : 32)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(isChatBusy)
        .accessibilityLabel("Pull request actions")
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && detail == nil {
            LoadingSkeleton("Loading pull request…")
        } else if let detail {
            switch mode {
            case .summary:
                summary(detail)
            case .code:
                code(detail)
            }
        } else if let errorMessage {
            ContentUnavailableView {
                Label("Couldn’t Load Pull Request", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
                    .textSelection(.enabled)
            } actions: {
                Button("Try Again") { Task { await load() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func summary(_ detail: CodeReviewDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                summaryHeader(detail)

                if let description = detail.description?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !description.isEmpty {
                    reviewSection("Description") {
                        markdown(description)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }

                reviewSection(
                    "Comments",
                    count: detail.comments.count,
                    actionTitle: "Add open comments",
                    actionSystemImage: "sparkles",
                    actionDisabled: CodeReviewChatPromptBuilder.openComments(in: detail).isEmpty,
                    action: {
                        includeOpenComments(detail)
                    }
                ) {
                    comments(detail)
                }

                if !fixDrafts.isEmpty {
                    reviewSection("Requested fixes", count: fixDrafts.count) {
                        ForEach(fixDrafts) { fixComposer($0) }
                    }
                }

                if detail.diffTruncated {
                    Label(
                        "The code diff was truncated to keep review navigation responsive.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.callout)
                    .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: 780, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
    }

    private func summaryHeader(_ detail: CodeReviewDetail) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(detail.item.title)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)

            HStack(spacing: 7) {
                Image(systemName: "person.crop.circle")
                Text(detail.item.author ?? "Unknown author")
                if let updatedAt = detail.item.updatedAt {
                    Text("·")
                    Text(updatedAt, format: .relative(presentation: .named))
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                metadataRow(
                    "Branch",
                    systemImage: "arrow.triangle.branch",
                    value: branchTitle(detail)
                )
                metadataRow(
                    "Reviewers",
                    systemImage: "person.2",
                    value: detail.reviewers.isEmpty ? "No reviewers" : detail.reviewers.joined(separator: ", ")
                )
                metadataRow(
                    "Comments",
                    systemImage: "bubble.left.and.bubble.right",
                    value: "\(detail.comments.count) comments"
                )
                metadataRow(
                    "Checks",
                    systemImage: "checkmark.seal",
                    value: detail.item.checksStatus ?? "No CI checks"
                )
                metadataRow(
                    "Status",
                    systemImage: "circlebadge",
                    value: statusTitle(detail.item)
                )
            }
            .font(.callout)
        }
    }

    @ViewBuilder
    private func comments(_ detail: CodeReviewDetail) -> some View {
        if let commentsError = detail.commentsError {
            Label(commentsError, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, detail.comments.isEmpty ? 0 : 10)
        }

        if detail.comments.isEmpty {
            Text("No review comments")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 14)
        } else {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(threadedComments(detail.comments)) { row in
                    VStack(alignment: .leading, spacing: 8) {
                        commentCard(row.comment)
                        commentActions(row.comment)
                        if replyingCommentID == row.comment.id {
                            replyComposer(for: row.comment)
                        }
                    }
                    .padding(.leading, CGFloat(row.depth) * 26)
                    .overlay(alignment: .leading) {
                        if row.depth > 0 {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.24))
                                .frame(width: 1)
                                .padding(.vertical, 8)
                                .padding(.leading, CGFloat(row.depth - 1) * 26 + 12)
                        }
                    }
                }
            }
        }
    }

    private func commentCard(_ comment: CodeReviewComment) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            commentHeader(comment)

            if let filePath = comment.filePath {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                    Text(filePath)
                    if let line = comment.line ?? comment.originalLine {
                        Text(":\(line)")
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("Show in Code") {
                        focusedComment = comment
                        mode = .code
                    }
                    .buttonStyle(.borderless)
                }
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }

            if let diffHunk = comment.diffHunk, !diffHunk.isEmpty {
                CodeReviewInlineDiffView(
                    diff: diffHunk,
                    layout: effectiveDiffLayout,
                    filePath: comment.filePath ?? "Changes",
                    highlightedLine: comment.line ?? comment.originalLine,
                    highlightedSide: comment.diffSide
                )
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 3)
                }
            }

            markdown(comment.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .textSelection(.enabled)
        }
        .background(Color.secondary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { isHovered in
            if isHovered {
                hoveredCommentID = comment.id
            } else if hoveredCommentID == comment.id {
                hoveredCommentID = nil
            }
        }
    }

    private func commentHeader(_ comment: CodeReviewComment) -> some View {
        let showsChatButton = showsCommentChatButton(comment.id)
        let isIncluded = reviewSelection.comments.contains { $0.id == comment.id }
        return HStack(spacing: 8) {
            Image(systemName: "person.crop.circle.fill")
                .foregroundStyle(.secondary)
            Text(comment.author ?? "Unknown reviewer")
                .font(.subheadline.weight(.semibold))

            if comment.isResolved == true {
                statusBadge("Resolved", color: .green)
            } else if comment.isOutdated == true {
                statusBadge("Outdated", color: .secondary)
            } else if let status = comment.status, !status.isEmpty {
                statusBadge(status.replacingOccurrences(of: "_", with: " ").capitalized, color: .orange)
            }

            Spacer(minLength: 8)

            Button { toggleReviewComment(comment) } label: {
                Image(systemName: isIncluded ? "checkmark.circle.fill" : "plus.bubble")
            }
            .buttonStyle(.borderless)
            .opacity(showsChatButton || isIncluded ? Double(1) : Double(0))
            .allowsHitTesting(showsChatButton || isIncluded)
            .accessibilityHidden(!showsChatButton && !isIncluded)
            .disabled(isChatBusy)
            .frame(width: isCompact ? 44 : 28, height: isCompact ? 44 : 28)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isIncluded ? "Remove comment from review" : "Add comment to review")
            .accessibilityValue(isIncluded ? "Included" : "Not included")
            .accessibilityIdentifier("code-review-select-comment-\(comment.id)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { toggleReviewComment(comment) }
            .help("Include this comment in Send Review")

            if let createdAt = comment.createdAt {
                Text(createdAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 42)
        .background(Color.secondary.opacity(0.055))
    }

    private func toggleReviewComment(_ comment: CodeReviewComment) {
        guard !isChatBusy else { return }
        if reviewSelection.comments.contains(where: { $0.id == comment.id }) {
            reviewSelection.comments.removeAll { $0.id == comment.id }
        } else {
            reviewSelection.comments.append(comment)
        }
        draftStatus = nil
    }

    private func includeOpenComments(_ detail: CodeReviewDetail) {
        guard !isChatBusy else { return }
        let included = Set(reviewSelection.comments.map(\.id))
        reviewSelection.comments.append(contentsOf: CodeReviewChatPromptBuilder.openComments(in: detail).filter { !included.contains($0.id) })
        draftStatus = nil
    }

    @ViewBuilder
    private func code(_ detail: CodeReviewDetail) -> some View {
        if let diffError = detail.diffError {
            ContentUnavailableView {
                Label("Couldn’t Load Code Diff", systemImage: "exclamationmark.triangle")
            } description: {
                Text(diffError).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        CodeReviewSideBySideDiffView(
                            diff: detail.diff,
                            layout: effectiveDiffLayout,
                            highlightedPath: focusedComment?.filePath ?? focusedFilePath,
                            highlightedLine: focusedComment?.line,
                            highlightedSide: focusedComment?.diffSide,
                            onAddToChat: addFix,
                            onAddFix: addFix,
                            lineAnnotations: { row, path in inlineAnnotations(row: row, path: path) }
                        )
                        if detail.diffTruncated {
                            Text("Diff is truncated. Review comments are available in Summary.")
                                .font(.caption).foregroundStyle(.secondary).padding(8)
                        }

                    }
#if os(macOS)
                    Divider()
                    fileNavigator(detail)
                        .frame(width: 220)
#endif
                }
            }
        }
    }

    private func runReviewAction(_ action: @escaping @MainActor (CodeReviewDetail) async throws -> Void) {
        guard let detail, !isChatBusy else { return }
        isChatBusy = true
        chatActionTask = Task { @MainActor in
            defer { isChatBusy = false }
            do {
                try await action(detail)
                linkedSessions = (try? await apiClient.fetchCodeReviewSessions(detail.item)) ?? linkedSessions
                chatError = nil
            } catch is CancellationError {
            } catch { chatError = error.localizedDescription }
        }
    }

    private func addFix(_ line: CodeReviewLineContext) {
        guard !isChatBusy else { return }
        draftStatus = nil
        if let existing = fixDrafts.first(where: { $0.filePath == line.filePath && $0.line == line.line && $0.side == line.side }) {
            focusedFixID = existing.id
        } else {
            let draft = CodeReviewFixDraft(line: line)
            fixDrafts.append(draft)
            focusedFixID = draft.id
        }
    }

    private func matches(_ draft: CodeReviewFixDraft, row: CodeReviewDiffRow, path: String) -> Bool {
        draft.isAnchored(to: row, filePath: path)
    }

    private func inlineAnnotations(row: CodeReviewDiffRow, path: String) -> AnyView? {
        let drafts = fixDrafts.filter { matches($0, row: row, path: path) }
        guard !drafts.isEmpty else { return nil }
        return AnyView(VStack(alignment: .leading, spacing: 12) {
            ForEach(drafts) { fixComposer($0) }
        }
        .frame(maxWidth: 800, alignment: .leading)
        .padding(.horizontal, isCompact ? 8 : 48)
        .padding(.vertical, 12))
    }

    private func fixComposer(_ draft: CodeReviewFixDraft) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Requested fix", systemImage: "text.bubble")
                    .font(.callout.weight(.semibold))
                Spacer()
                Button { fixDrafts.removeAll { $0.id == draft.id } } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).accessibilityLabel("Remove requested fix")
            }
            Text("\(draft.filePath):\(draft.line) · \(draft.side.rawValue)")
                .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            TextEditor(text: Binding(
                get: { fixDrafts.first { $0.id == draft.id }?.body ?? "" },
                set: { body in
                    if let index = fixDrafts.firstIndex(where: { $0.id == draft.id }) {
                        fixDrafts[index].body = body
                        draftStatus = nil
                    }
                }
            ))
            .font(.callout)
            .scrollContentBackground(.hidden)
            .frame(height: 74)
            .overlay(alignment: .topLeading) {
                if draft.body.isEmpty {
                    Text("Describe what should be fixed…").foregroundStyle(.tertiary)
                        .padding(.horizontal, 5).padding(.top, 8).allowsHitTesting(false)
                }
            }
            .focused($focusedFixID, equals: draft.id)
            .accessibilityLabel("Requested fix at \(draft.filePath) line \(draft.line)")
        }
        .padding(14)
        .background(Color.fromHex(0xc8e2ae).opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.22)) }
        .disabled(isChatBusy)
        .accessibilityIdentifier("code-review-fix-\(draft.id)")
    }

    private var diffLayoutPicker: some View {
        Picker("Diff layout", selection: diffLayoutBinding) {
            ForEach(CodeReviewDiffLayout.allCases) { layout in Text(layout.title).tag(layout) }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 220)
        .accessibilityIdentifier("code-review-diff-layout")
    }

    private var reviewCount: Int {
        fixDrafts.filter { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count + reviewSelection.comments.count
    }

    private var reviewToolbar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(reviewCount == 1 ? "1 comment" : "\(reviewCount) comments")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if !isCompact, mode == .code { diffLayoutPicker }
                Button(action: sendReview) {
                    HStack(spacing: 6) {
                        if isChatBusy { ProgressView().controlSize(.small) }
                        Text("Send Review").fontWeight(.semibold)
                    }
                    .frame(minHeight: isCompact ? 28 : 18)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.fromHex(0xc8e2ae))
                .foregroundStyle(reviewCount == 0 || detail == nil || isChatBusy ? Color.secondary : Color.fromHex(0x242521))
                .disabled(reviewCount == 0 || detail == nil || isChatBusy)
                .accessibilityIdentifier("code-review-send-review")
            }
            if let draftStatus { Text(draftStatus).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func sendReview() {
        guard let detail, reviewCount > 0, !isChatBusy else { return }
        let fixes = fixDrafts.filter { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let comments = reviewSelection.comments
        let content = CodeReviewChatPromptBuilder.promptForReview(fixes: fixes, comments: comments, in: detail)
        if reviewSelection.pendingContent != content {
            reviewSelection.requestID = UUID()
            reviewSelection.pendingContent = content
        }
        draftStore.saveSelection(reviewSelection, item: item, endpoint: apiClient.endpoint)
        let submission = CodeReviewSubmission(id: reviewSelection.requestID, content: content)
        focusedFixID = nil
        runReviewAction { detail in
            try await onSendReview(detail, submission)
            let submitted = Set(fixes.map(\.id))
            fixDrafts.removeAll { submitted.contains($0.id) }
            reviewSelection = .init()
            draftStore.save(fixDrafts, item: item, endpoint: apiClient.endpoint)
            draftStore.saveSelection(reviewSelection, item: item, endpoint: apiClient.endpoint)
            draftStatus = "Review sent"
        }
    }

    private func fileNavigator(_ detail: CodeReviewDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("Changed files").font(.headline).padding(.bottom, 6)
                ForEach(files) { file in
                    Button {
                        focusedComment = nil
                        focusedFilePath = file.displayPath
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text")
                            Text(file.displayPath).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                            Text("+\(file.additions) −\(file.deletions)").font(.caption.monospacedDigit())
                        }
                        .font(.caption).padding(7)
                        .background(focusedFilePath == file.displayPath ? Color.secondary.opacity(0.12) : .clear)
                    }
                    .buttonStyle(.plain)
                }
            }.padding(12)
        }
    }

    private func commentActions(_ comment: CodeReviewComment) -> some View {
        HStack(spacing: 10) {
            if item.providerId == "arcadia-code-review" {
                Button(replyingCommentID == comment.id ? "Cancel reply" : "Reply") {
                    if replyingCommentID == comment.id {
                        replyingCommentID = nil
                    } else {
                        replyingCommentID = comment.id
                        replyError = nil
                    }
                }
                .buttonStyle(.borderless)
            }
            if let replyTo = comment.inReplyToId {
                Text("Reply to #\(replyTo)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption.weight(.medium))
        .padding(.leading, 4)
    }

    private func replyComposer(for comment: CodeReviewComment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: replyBinding(for: comment.id))
                .font(.callout)
                .frame(minHeight: 74, maxHeight: 120)
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.secondary.opacity(0.24), lineWidth: 1)
                }
            if let replyError {
                Label(replyError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Send reply") { Task { await sendReply(to: comment) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        replyDrafts[comment.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || postingReplyCommentIDs.contains(comment.id)
                    )
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func replyBinding(for commentID: String) -> Binding<String> {
        Binding(
            get: { replyDrafts[commentID, default: ""] },
            set: { replyDrafts[commentID] = $0 }
        )
    }

    private func sendReply(to comment: CodeReviewComment) async {
        let body = replyDrafts[comment.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        postingReplyCommentIDs.insert(comment.id)
        defer { postingReplyCommentIDs.remove(comment.id) }
        do {
            var reply = try await apiClient.replyToCodeReviewComment(
                providerID: item.providerId,
                reviewID: item.id,
                parentCommentID: comment.id,
                body: body
            )
            if reply.inReplyToId == nil { reply.inReplyToId = comment.id }
            detail?.comments.append(reply)
            replyDrafts[comment.id] = ""
            replyingCommentID = nil
            replyError = nil
        } catch {
            replyError = error.localizedDescription
        }
    }

    private func threadedComments(_ comments: [CodeReviewComment]) -> [ThreadedComment] {
        CodeReviewCommentThread.group(comments).flatMap { thread in
            thread.comments.enumerated().map { index, comment in
                ThreadedComment(comment: comment, depth: index == 0 ? 0 : 1)
            }
        }
    }

    private func reviewSection<Content: View>(
        _ title: String,
        count: Int? = nil,
        actionTitle: String? = nil,
        actionSystemImage: String? = nil,
        actionDisabled: Bool = false,
        action: (@MainActor () -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                if let count {
                    Text("\(count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
                Spacer(minLength: 8)
                if let actionTitle, let action {
                    Button(action: action) {
                        if let actionSystemImage {
                            Label(actionTitle, systemImage: actionSystemImage)
                        } else {
                            Text(actionTitle)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(actionDisabled)
                }
            }
            Divider()
            content()
        }
    }

    private func metadataRow(_ title: String, systemImage: String, value: String) -> some View {
        GridRow {
            Label(title, systemImage: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 105, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
        }
    }

    private func markdown(_ value: String) -> Text {
        if let attributed = try? AttributedString(markdown: value) {
            return Text(attributed)
        }
        return Text(value)
    }

    private func statusBadge(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func showsCommentChatButton(_ commentID: String) -> Bool { true }

    private func branchTitle(_ detail: CodeReviewDetail) -> String {
        let source = detail.sourceBranch ?? "head"
        let target = detail.targetBranch ?? "base"
        return "\(source)  →  \(target)"
    }

    private func statusTitle(_ item: CodeReviewItem) -> String {
        if item.isDraft { return "Draft" }
        if let decision = item.reviewDecision, !decision.isEmpty {
            return decision.replacingOccurrences(of: "_", with: " ").capitalized
        }
        return switch item.state {
        case .open, .all: "Ready for review"
        case .closed: "Closed"
        case .merged: "Merged"
        }
    }

    private var stateColor: Color {
        switch item.state {
        case .open, .all: .green
        case .closed: .red
        case .merged: .purple
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await apiClient.fetchCodeReviewDetail(
                providerID: item.providerId,
                reviewID: item.id
            )
            let parsed = await Task.detached(priority: .userInitiated) {
                CodeReviewDiffParser.parse(loaded.diff)
            }.value
            guard !Task.isCancelled else { return }
            detail = loaded
            files = parsed
            errorMessage = nil
        } catch {
            detail = nil
            errorMessage = error.localizedDescription
        }
    }
}

private struct ThreadedComment: Identifiable {
    let comment: CodeReviewComment
    let depth: Int

    var id: String { comment.id }
}
