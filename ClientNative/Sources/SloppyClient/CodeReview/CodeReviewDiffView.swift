import SloppyClientCore
import SwiftUI

private struct CodeReviewDiffRenderDocument: Sendable {
    struct Item: Identifiable, Sendable {
        enum Content: Sendable {
            case spacing
            case fileHeader(path: String, additions: Int, deletions: Int)
            case hunkHeader(String)
            case code(CodeReviewDiffRow)
        }

        let id: Int
        let filePath: String
        let content: Content
    }

    let items: [Item]
    let codeRowCount: Int
    let maximumLineLength: Int

    init(diff: String, fallbackPath: String, layout: CodeReviewDiffLayout) {
        let files = CodeReviewDiffParser.parse(diff, fallbackPath: fallbackPath)
        var items: [Item] = []
        var nextID = 0
        var codeRowCount = 0

        for (fileIndex, file) in files.enumerated() {
            if fileIndex > 0 {
                items.append(Item(id: nextID, filePath: file.displayPath, content: .spacing))
                nextID += 1
            }
            items.append(
                Item(
                    id: nextID,
                    filePath: file.displayPath,
                    content: .fileHeader(
                        path: file.displayPath,
                        additions: file.additions,
                        deletions: file.deletions
                    )
                )
            )
            nextID += 1

            for hunk in file.hunks {
                items.append(Item(id: nextID, filePath: file.displayPath, content: .hunkHeader(hunk.header)))
                nextID += 1
                let rows = layout == .sideBySide ? hunk.rows : CodeReviewUnifiedDiff.rows(hunk.rows)
                for row in rows {
                    items.append(Item(id: nextID, filePath: file.displayPath, content: .code(row)))
                    nextID += 1
                    codeRowCount += 1
                }
            }
        }

        self.items = items
        self.codeRowCount = codeRowCount
        self.maximumLineLength = files.flatMap(\.hunks).flatMap(\.rows)
            .map { max($0.old.text.utf16.count, $0.new.text.utf16.count) }.max() ?? 0
    }
}

struct CodeReviewSideBySideDiffView: View {
    let diff: String
    var layout = CodeReviewDiffLayout.sideBySide
    var fallbackPath = "Changes"
    var highlightedPath: String?
    var highlightedLine: Int?
    var highlightedSide: CodeReviewDiffSide?
    var maximumHeight: CGFloat?
    var onAddToChat: (@MainActor (CodeReviewLineContext) -> Void)?
    var onAddFix: (@MainActor (CodeReviewLineContext) -> Void)?
    var lineAnnotations: (@MainActor (CodeReviewDiffRow, String) -> AnyView?)?

    @State private var document: CodeReviewDiffRenderDocument?
    @State private var hoveredCellID: String?

    @State private var codeColumnWidth: CGFloat = 620
    @State private var viewportHeight: CGFloat = 0
    @State private var viewportWidth: CGFloat = 1240

    private struct PreparationKey: Equatable {
        var diff: String
        var layout: CodeReviewDiffLayout
    }
    @ScaledMetric(relativeTo: .caption) private var lineHeight: CGFloat = 24
    @ScaledMetric(relativeTo: .caption) private var codeFontSize: CGFloat = 12

    private var reservesActionGutter: Bool { viewportWidth < 600 && (onAddFix != nil || onAddToChat != nil) }
    private var numberWidth: CGFloat { viewportWidth < 600 ? 30 : 46 }
    private var numberPadding: CGFloat { viewportWidth < 600 ? 4 : 8 }
    private var textWidth: CGFloat { CGFloat(document?.maximumLineLength ?? 0) * codeFontSize * 0.65 }
    private var actionGutterWidth: CGFloat { reservesActionGutter ? 28 : 0 }
    private var resolvedColumnWidth: CGFloat { max(codeColumnWidth, textWidth + numberWidth + numberPadding + 24 + actionGutterWidth) }

    var body: some View {
        Group {
            if let document {
                if document.items.isEmpty {
                    ContentUnavailableView("No Code Changes", systemImage: "doc.text.magnifyingglass")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    diffContent(document)
                }
            } else {
                CodeReviewDiffSkeletonView(totalWidth: totalWidth, isCompact: maximumHeight != nil, layout: layout)
            }
        }
        .frame(
            minHeight: maximumHeight == nil ? nil : 90,
            idealHeight: resolvedHeight,
            maxHeight: resolvedHeight
        )
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            codeColumnWidth = max(300, (size.width - 32) / 2)
            viewportHeight = size.height
            viewportWidth = size.width
        }
        .task(id: PreparationKey(diff: diff, layout: layout)) { await prepareDiff() }
        .accessibilityIdentifier(document == nil ? "code-review-diff-skeleton" : "code-review-diff")
        .accessibilityValue(layout.title)
    }

    private func diffContent(_ document: CodeReviewDiffRenderDocument) -> some View {
        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(document.items) { item in
                        render(item)
                            .id(item.id)
                    }
                }
                .frame(minHeight: max(0, viewportHeight - 32), alignment: .topLeading)
                .padding(16)
            }
            .onChange(of: highlightedPath, initial: true) { _, _ in scrollToFocus(document, proxy: proxy) }
            .onChange(of: highlightedLine) { _, _ in scrollToFocus(document, proxy: proxy) }
            .onChange(of: highlightedSide) { _, _ in scrollToFocus(document, proxy: proxy) }
        }
        .background(.background)
    }

    @ViewBuilder
    private func render(_ item: CodeReviewDiffRenderDocument.Item) -> some View {
        switch item.content {
        case .spacing:
            Color.clear
                .frame(width: totalWidth, height: 18)
        case .fileHeader(let path, let additions, let deletions):
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                Text(path)
                    .font(.callout.monospaced().weight(.semibold))
                    .lineLimit(1)
                Text("+\(additions)")
                    .foregroundStyle(.green)
                Text("−\(deletions)")
                    .foregroundStyle(.red)
                Spacer(minLength: 0)
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .frame(width: totalWidth, height: 38)
            .background(.quaternary.opacity(0.5))
            .overlay {
                Rectangle().stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            }
        case .hunkHeader(let header):
            HStack(spacing: 0) {
                Text(header)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                Spacer(minLength: 0)
            }
            .frame(width: totalWidth, height: 26)
            .background(Color.accentColor.opacity(0.08))
        case .code(let row):
            VStack(spacing: 0) {
                if layout == .sideBySide {
                    HStack(spacing: 0) {
                        diffCell(row.old, side: .old, filePath: item.filePath, rowID: row.id)
                        Rectangle()
                            .fill(Color.secondary.opacity(0.2))
                            .frame(width: 1, height: lineHeight)
                        diffCell(row.new, side: .new, filePath: item.filePath, rowID: row.id)
                    }
                } else {
                    let side: CodeReviewDiffSide = row.new.kind == .empty ? .old : .new
                    diffCell(side == .old ? row.old : row.new, side: side, filePath: item.filePath,
                             rowID: row.id, unified: true, oldLineNumber: row.old.lineNumber)
                }
                if let annotations = lineAnnotations?(row, item.filePath) {
                    annotations
                        .frame(width: min(totalWidth, max(280, viewportWidth - 32)), alignment: .leading)
                        .frame(width: totalWidth, alignment: .leading)
                }
            }
        }
    }

    private func diffCell(
        _ cell: CodeReviewDiffCell,
        side: CodeReviewDiffSide,
        filePath: String,
        rowID: Int,
        unified: Bool = false,
        oldLineNumber: Int? = nil
    ) -> some View {
        let cellID = "\(filePath):\(rowID):\(side.rawValue)"
        let showsChatButton = showsDiffChatButton(cellID)
        return HStack(spacing: 0) {
            if reservesActionGutter { Color.clear.frame(width: 28) }
            if unified {
                lineNumber(oldLineNumber)
                lineNumber(side == .new ? cell.lineNumber : nil)
            } else {
                lineNumber(cell.lineNumber)
            }

            Text(cellPrefix(cell.kind))
                .font(.caption.monospaced())
                .foregroundStyle(prefixColor(cell.kind))
                .frame(width: 16, alignment: .center)

            Text(verbatim: cell.text)
                .font(.system(size: codeFontSize, design: .monospaced))
                .foregroundStyle(cell.kind == .empty ? .tertiary : .primary)
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.trailing, 8)
        .frame(width: unified ? totalWidth : resolvedColumnWidth, height: lineHeight)
        .background(cellBackground(cell, isOldSide: side == .old, filePath: filePath))
        .contentShape(Rectangle())
        .contextMenu {
            if let line = cell.lineNumber, cell.kind != .empty {
                let context = CodeReviewLineContext(filePath: filePath, line: line, side: side, content: cell.text)
                if let onAddFix { Button("Add requested fix") { onAddFix(context) } }
                if let onAddToChat { Button("Add line to review") { onAddToChat(context) } }
            }
        }
        .overlay(alignment: .leading) {
            if let line = cell.lineNumber, cell.kind != .empty, (onAddFix != nil || onAddToChat != nil) {
                Button {
                    (onAddFix ?? onAddToChat)?(
                        CodeReviewLineContext(
                            filePath: filePath,
                            line: line,
                            side: side,
                            content: cell.text
                        )
                    )
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .frame(width: 28, height: lineHeight)
                .background(.regularMaterial, in: Capsule())
                .padding(.leading, 3)
                .opacity(showsChatButton ? Double(1) : Double(0))
                .allowsHitTesting(showsChatButton)
                .accessibilityHidden(!showsChatButton)
                .accessibilityLabel(onAddFix == nil ? "Add diff line to chat" : "Add requested fix")
                .help(onAddFix == nil ? "Add this line to the PR chat" : "Write a requested fix for this line")
            }
        }
        .onHover { isHovered in
            if isHovered {
                hoveredCellID = cellID
            } else if hoveredCellID == cellID {
                hoveredCellID = nil
            }
        }
    }

    private func lineNumber(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? "")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: numberWidth, alignment: .trailing)
            .padding(.trailing, numberPadding)
    }

    private func cellPrefix(_ kind: CodeReviewDiffLineKind) -> String {
        switch kind {
        case .deletion: "−"
        case .insertion: "+"
        case .context, .empty: ""
        }
    }

    private func prefixColor(_ kind: CodeReviewDiffLineKind) -> Color {
        switch kind {
        case .deletion: .red
        case .insertion: .green
        case .context, .empty: .secondary
        }
    }

    private func cellBackground(_ cell: CodeReviewDiffCell, isOldSide: Bool, filePath: String) -> Color {
        if let highlightedLine, isHighlighted(filePath), cell.lineNumber == highlightedLine,
           highlightedSide == nil || highlightedSide == (isOldSide ? .old : .new) {
            return Color.accentColor.opacity(0.24)
        }
        switch cell.kind {
        case .deletion:
            return Color.red.opacity(0.16)
        case .insertion:
            return Color.green.opacity(0.16)
        case .empty:
            return Color.secondary.opacity(0.04)
        case .context:
            return isOldSide ? Color.secondary.opacity(0.015) : .clear
        }
    }

    private var totalWidth: CGFloat {
        layout == .sideBySide ? resolvedColumnWidth * 2 + 1
            : max(280, viewportWidth - 32, textWidth + (numberWidth + numberPadding) * 2 + 24 + actionGutterWidth)
    }

    private var resolvedHeight: CGFloat? {
        guard let maximumHeight else { return nil }
        guard let document else { return min(180, maximumHeight) }
        let structuralRows = document.items.count - document.codeRowCount
        let contentHeight = CGFloat(document.codeRowCount) * lineHeight
            + CGFloat(structuralRows) * 30
            + 32
        return min(maximumHeight, max(90, contentHeight))
    }

    private func isHighlighted(_ filePath: String) -> Bool {
        guard let highlightedPath else { return true }
        return normalizedPath(filePath) == normalizedPath(highlightedPath)
    }

    private func normalizedPath(_ value: String) -> String {
        value
            .replacingOccurrences(of: "a/", with: "", options: [.anchored])
            .replacingOccurrences(of: "b/", with: "", options: [.anchored])
    }

    private func showsDiffChatButton(_ cellID: String) -> Bool {
#if os(macOS)
        hoveredCellID == cellID
#else
        true
#endif
    }

    private func scrollToFocus(_ document: CodeReviewDiffRenderDocument, proxy: ScrollViewProxy) {
        guard let path = highlightedPath,
              let item = document.items.first(where: { item in
                  guard normalizedPath(item.filePath) == normalizedPath(path) else { return false }
                  if let line = highlightedLine, case .code(let row) = item.content {
                      switch highlightedSide {
                      case .new: return row.new.lineNumber == line
                      case .old: return row.old.lineNumber == line
                      case nil: return row.new.lineNumber == line || row.old.lineNumber == line
                      }
                  }
                  if highlightedLine == nil, case .fileHeader = item.content { return true }
                  return false
              }) else { return }
        proxy.scrollTo(item.id, anchor: .topLeading)
    }

    private func prepareDiff() async {
        let source = diff
        let path = fallbackPath
        let selectedLayout = layout
        let worker = Task.detached(priority: .userInitiated) {
            CodeReviewDiffRenderDocument(diff: source, fallbackPath: path, layout: selectedLayout)
        }
        let prepared = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled else { return }
        document = prepared
    }
}

private struct CodeReviewDiffSkeletonView: View {
    let totalWidth: CGFloat
    let isCompact: Bool
    let layout: CodeReviewDiffLayout

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                skeletonBar(width: totalWidth, height: 38, opacity: 0.16)
                skeletonBar(width: totalWidth, height: 26, opacity: 0.1)
                ForEach(0..<(isCompact ? 5 : 18), id: \.self) { index in
                    HStack(spacing: 1) {
                        skeletonLine(seed: index)
                        if layout == .sideBySide { skeletonLine(seed: index + 3) }
                    }
                }
            }
            .padding(16)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preparing code diff")
    }

    private func skeletonLine(seed: Int) -> some View {
        HStack(spacing: 10) {
            skeletonBar(width: 38, height: 8, opacity: 0.12)
            skeletonBar(width: CGFloat(180 + (seed % 5) * 58), height: 9, opacity: 0.15)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(width: layout == .sideBySide ? (totalWidth - 1) / 2 : totalWidth, height: 22)
        .background(Color.secondary.opacity(seed.isMultiple(of: 4) ? 0.035 : 0.015))
    }

    private func skeletonBar(width: CGFloat, height: CGFloat, opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: min(5, height / 2), style: .continuous)
            .fill(Color.secondary.opacity(opacity))
            .frame(width: width, height: height)
    }
}

struct CodeReviewInlineDiffView: View {
    let diff: String
    var layout = CodeReviewDiffLayout.sideBySide
    let filePath: String
    let highlightedLine: Int?
    var highlightedSide: CodeReviewDiffSide?

    var body: some View {
        CodeReviewSideBySideDiffView(
            diff: diff,
            layout: layout,
            fallbackPath: filePath,
            highlightedPath: filePath,
            highlightedLine: highlightedLine,
            highlightedSide: highlightedSide,
            maximumHeight: 280,
            onAddToChat: nil
        )
    }
}
