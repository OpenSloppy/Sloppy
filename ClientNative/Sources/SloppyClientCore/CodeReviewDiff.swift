import Foundation

public enum CodeReviewDiffLineKind: Sendable, Equatable {
    case context
    case deletion
    case insertion
    case empty
}

public enum CodeReviewDiffSide: String, Codable, Sendable, Equatable {
    case old
    case new
}

public enum CodeReviewDiffLayout: String, Codable, Sendable, CaseIterable, Identifiable {
    case sideBySide = "side_by_side"
    case oneSide = "one_side"

    public var id: Self { self }
    public var title: String {
        switch self {
        case .sideBySide: "Side by side"
        case .oneSide: "One side"
        }
    }
}

/// Reconstruct patch order from aligned rows: deletions, then additions in each change block.
/// Source row IDs are preserved so annotations can follow their original line and side.
public enum CodeReviewUnifiedDiff {
    public static func rows(_ source: [CodeReviewDiffRow]) -> [CodeReviewDiffRow] {
        var result: [CodeReviewDiffRow] = []
        var changes: [CodeReviewDiffRow] = []
        let empty = CodeReviewDiffCell(lineNumber: nil, text: "", kind: .empty)
        func flush() {
            for row in changes where row.old.kind != .empty {
                result.append(.init(id: row.id, old: row.old, new: empty))
            }
            for row in changes where row.new.kind != .empty {
                result.append(.init(id: row.id, old: empty, new: row.new))
            }
            changes.removeAll(keepingCapacity: true)
        }
        for row in source {
            if row.old.kind == .context || row.new.kind == .context {
                flush()
                result.append(row)
            } else {
                changes.append(row)
            }
        }
        flush()
        return result
    }
}

public struct CodeReviewLineContext: Sendable, Equatable {
    public var filePath: String
    public var line: Int
    public var side: CodeReviewDiffSide
    public var content: String

    public init(filePath: String, line: Int, side: CodeReviewDiffSide, content: String) {
        self.filePath = filePath
        self.line = line
        self.side = side
        self.content = content
    }
}

public struct CodeReviewDiffCell: Sendable, Equatable {
    public var lineNumber: Int?
    public var text: String
    public var kind: CodeReviewDiffLineKind

    public init(lineNumber: Int?, text: String, kind: CodeReviewDiffLineKind) {
        self.lineNumber = lineNumber
        self.text = text
        self.kind = kind
    }
}

public struct CodeReviewDiffRow: Sendable, Equatable, Identifiable {
    public var id: Int
    public var old: CodeReviewDiffCell
    public var new: CodeReviewDiffCell

    public init(id: Int, old: CodeReviewDiffCell, new: CodeReviewDiffCell) {
        self.id = id
        self.old = old
        self.new = new
    }
}

public struct CodeReviewDiffHunk: Sendable, Equatable, Identifiable {
    public var id: Int
    public var header: String
    public var rows: [CodeReviewDiffRow]

    public init(id: Int, header: String, rows: [CodeReviewDiffRow]) {
        self.id = id
        self.header = header
        self.rows = rows
    }
}

public struct CodeReviewDiffFile: Sendable, Equatable, Identifiable {
    public var id: String
    public var oldPath: String?
    public var newPath: String?
    public var hunks: [CodeReviewDiffHunk]

    public init(id: String, oldPath: String?, newPath: String?, hunks: [CodeReviewDiffHunk]) {
        self.id = id
        self.oldPath = oldPath
        self.newPath = newPath
        self.hunks = hunks
    }

    public var displayPath: String {
        newPath ?? oldPath ?? id
    }

    public var additions: Int {
        hunks.flatMap(\.rows).filter { $0.new.kind == .insertion }.count
    }

    public var deletions: Int {
        hunks.flatMap(\.rows).filter { $0.old.kind == .deletion }.count
    }
}

public enum CodeReviewDiffParser {
    public static func parse(_ diff: String, fallbackPath: String = "Changes") -> [CodeReviewDiffFile] {
        guard !diff.isEmpty else { return [] }

        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var files: [CodeReviewDiffFile] = []
        var file = FileBuilder(id: fallbackPath)
        var hunk: HunkBuilder?
        var nextHunkID = 0
        var nextRowID = 0

        func finishHunk() {
            guard var current = hunk else { return }
            current.flushChanges(nextRowID: &nextRowID)
            file.hunks.append(
                CodeReviewDiffHunk(id: nextHunkID, header: current.header, rows: current.rows)
            )
            nextHunkID += 1
            hunk = nil
        }

        func finishFile() {
            finishHunk()
            guard !file.hunks.isEmpty || file.oldPath != nil || file.newPath != nil else { return }
            let identity = file.newPath ?? file.oldPath ?? "\(fallbackPath)-\(files.count)"
            files.append(
                CodeReviewDiffFile(
                    id: "\(identity)-\(files.count)",
                    oldPath: file.oldPath,
                    newPath: file.newPath,
                    hunks: file.hunks
                )
            )
        }

        for (index, line) in lines.enumerated() {
            if index.isMultiple(of: 512), Task.isCancelled {
                return []
            }
            if line.hasPrefix("diff --git ") {
                finishFile()
                file = FileBuilder(id: fallbackPath)
                let parts = line.split(separator: " ", maxSplits: 3).map(String.init)
                if parts.count == 4 {
                    file.oldPath = normalizedPath(parts[2])
                    file.newPath = normalizedPath(parts[3])
                }
                continue
            }

            if line.hasPrefix("--- ") {
                file.oldPath = normalizedPath(String(line.dropFirst(4)))
                continue
            }

            if line.hasPrefix("+++ ") {
                file.newPath = normalizedPath(String(line.dropFirst(4)))
                continue
            }

            if line.hasPrefix("@@") {
                finishHunk()
                let ranges = hunkRanges(line)
                hunk = HunkBuilder(
                    header: line,
                    oldLine: ranges.old,
                    newLine: ranges.new
                )
                continue
            }

            guard var current = hunk else { continue }
            current.consume(line, nextRowID: &nextRowID)
            hunk = current
        }

        finishFile()
        return files
    }

    private static func normalizedPath(_ path: String) -> String? {
        let path = path.split(separator: "\t", maxSplits: 1).first.map(String.init) ?? path
        guard path != "/dev/null" else { return nil }
        if path.hasPrefix("a/") || path.hasPrefix("b/") {
            return String(path.dropFirst(2))
        }
        return path
    }

    private static func hunkRanges(_ header: String) -> (old: Int, new: Int) {
        let parts = header.split(separator: " ")
        guard parts.count >= 3 else { return (1, 1) }
        return (
            rangeStart(String(parts[1]), marker: "-") ?? 1,
            rangeStart(String(parts[2]), marker: "+") ?? 1
        )
    }

    private static func rangeStart(_ value: String, marker: Character) -> Int? {
        guard value.first == marker else { return nil }
        guard let rawStart = value.dropFirst().split(separator: ",", maxSplits: 1).first else {
            return nil
        }
        return Int(rawStart)
    }

    private struct FileBuilder {
        var id: String
        var oldPath: String?
        var newPath: String?
        var hunks: [CodeReviewDiffHunk] = []
    }

    private struct HunkBuilder {
        var header: String
        var oldLine: Int
        var newLine: Int
        var rows: [CodeReviewDiffRow] = []
        var pendingOld: [CodeReviewDiffCell] = []
        var pendingNew: [CodeReviewDiffCell] = []

        mutating func consume(_ line: String, nextRowID: inout Int) {
            guard let prefix = line.first else {
                flushChanges(nextRowID: &nextRowID)
                appendContext("", nextRowID: &nextRowID)
                return
            }

            switch prefix {
            case "-":
                pendingOld.append(
                    CodeReviewDiffCell(lineNumber: oldLine, text: String(line.dropFirst()), kind: .deletion)
                )
                oldLine += 1
            case "+":
                pendingNew.append(
                    CodeReviewDiffCell(lineNumber: newLine, text: String(line.dropFirst()), kind: .insertion)
                )
                newLine += 1
            case " ":
                flushChanges(nextRowID: &nextRowID)
                appendContext(String(line.dropFirst()), nextRowID: &nextRowID)
            case "\\":
                break
            default:
                flushChanges(nextRowID: &nextRowID)
                appendContext(line, nextRowID: &nextRowID)
            }
        }

        mutating func flushChanges(nextRowID: inout Int) {
            let count = max(pendingOld.count, pendingNew.count)
            guard count > 0 else { return }

            for index in 0..<count {
                let old = index < pendingOld.count
                    ? pendingOld[index]
                    : CodeReviewDiffCell(lineNumber: nil, text: "", kind: .empty)
                let new = index < pendingNew.count
                    ? pendingNew[index]
                    : CodeReviewDiffCell(lineNumber: nil, text: "", kind: .empty)
                rows.append(CodeReviewDiffRow(id: nextRowID, old: old, new: new))
                nextRowID += 1
            }
            pendingOld.removeAll(keepingCapacity: true)
            pendingNew.removeAll(keepingCapacity: true)
        }

        private mutating func appendContext(_ text: String, nextRowID: inout Int) {
            rows.append(
                CodeReviewDiffRow(
                    id: nextRowID,
                    old: CodeReviewDiffCell(lineNumber: oldLine, text: text, kind: .context),
                    new: CodeReviewDiffCell(lineNumber: newLine, text: text, kind: .context)
                )
            )
            nextRowID += 1
            oldLine += 1
            newLine += 1
        }
    }
}

public enum CodeReviewChatPromptBuilder {
    public static func prompt(for detail: CodeReviewDetail) -> String {
        var lines = [
            "Help me address the review feedback in this pull request.",
            "",
            "Pull request: \(detail.item.title)",
            "PR ID: \(detail.item.id)",
            "Provider ID: \(detail.item.providerId)",
            "Repository: \(detail.item.repository)",
            "Provider: \(detail.item.providerName)",
            "URL: \(detail.item.url)",
        ]

        if let source = detail.sourceBranch, !source.isEmpty {
            lines.append("Branch: \(source) -> \(detail.targetBranch ?? "default")")
        }

        let actionableComments = openComments(in: detail)
        if !actionableComments.isEmpty {
            lines.append(contentsOf: ["", "Review comments:"])
            for comment in actionableComments.prefix(20) {
                let location = comment.filePath.map {
                    if let line = comment.line ?? comment.originalLine {
                        return "\($0):\(line)"
                    }
                    return $0
                } ?? "General"
                let author = comment.author ?? "Reviewer"
                let body = String(comment.body.prefix(1_500))
                    .replacingOccurrences(of: "\n", with: " ")
                lines.append("- [\(location)] \(author): \(body)")
            }
        }

        lines.append(contentsOf: [
            "",
            "Inspect the current checkout, verify which comments still apply, implement the fixes, and run focused tests. Do not publish or merge unless I ask.",
        ])
        return lines.joined(separator: "\n")
    }

    public static func prompt(for comment: CodeReviewComment, in detail: CodeReviewDetail) -> String {
        var lines = reviewHeader(
            instruction: "Help me address this pull request review comment.",
            detail: detail
        )
        lines.append(contentsOf: [
            "",
            "Selected review comment:",
            "Comment ID: \(comment.id)",
            "Location: \(location(for: comment))",
            "Author: \(comment.author ?? "Reviewer")",
        ])
        if let parentID = comment.inReplyToId {
            lines.append("Reply to comment: \(parentID)")
        }
        lines.append("Comment: \(bounded(comment.body, limit: 4_000))")
        if let diffHunk = comment.diffHunk, !diffHunk.isEmpty {
            lines.append(contentsOf: ["", "Relevant diff:", "```diff", bounded(diffHunk, limit: 6_000), "```"])
        }
        lines.append(contentsOf: [
            "",
            completionInstruction,
        ])
        return lines.joined(separator: "\n")
    }

    public static func prompt(for line: CodeReviewLineContext, in detail: CodeReviewDetail) -> String {
        var lines = reviewHeader(
            instruction: "Help me inspect and address this pull request diff line.",
            detail: detail
        )
        lines.append(contentsOf: [
            "",
            "Selected diff line:",
            "Location: \(line.filePath):\(line.line)",
            "Side: \(line.side.rawValue)",
            "```",
            bounded(line.content, limit: 4_000),
            "```",
            "",
            completionInstruction,
        ])
        return lines.joined(separator: "\n")
    }

    public static func promptForOpenIssues(in detail: CodeReviewDetail) -> String {
        let comments = openComments(in: detail)
        var lines = reviewHeader(
            instruction: "Resolve all open review issues in this pull request.",
            detail: detail
        )
        lines.append(contentsOf: ["", "Open review issues (\(comments.count)):"])
        for comment in comments.prefix(50) {
            let author = comment.author ?? "Reviewer"
            let body = bounded(comment.body, limit: 1_500)
                .replacingOccurrences(of: "\n", with: " ")
            lines.append("- [\(location(for: comment))] \(author): \(body)")
        }
        lines.append(contentsOf: [
            "",
            "Work through every issue above, keeping each fix scoped to the feedback and verifying the affected behavior. \(completionInstruction)",
        ])
        return lines.joined(separator: "\n")
    }

    public static func openComments(in detail: CodeReviewDetail) -> [CodeReviewComment] {
        detail.comments.filter { $0.isResolved != true && $0.isOutdated != true }
    }

    private static let completionInstruction =
        "Inspect the current checkout, implement the fix, and run focused tests. Do not publish or merge unless I ask."

    private static func reviewHeader(instruction: String, detail: CodeReviewDetail) -> [String] {
        var lines = [
            instruction,
            "",
            "Pull request: \(detail.item.title)",
            "PR ID: \(detail.item.id)",
            "Provider ID: \(detail.item.providerId)",
            "Repository: \(detail.item.repository)",
            "Provider: \(detail.item.providerName)",
            "URL: \(detail.item.url)",
        ]
        if let source = detail.sourceBranch, !source.isEmpty {
            lines.append("Branch: \(source) -> \(detail.targetBranch ?? "default")")
        }
        return lines
    }

    private static func location(for comment: CodeReviewComment) -> String {
        guard let filePath = comment.filePath else { return "General" }
        guard let line = comment.line ?? comment.originalLine else { return filePath }
        return "\(filePath):\(line)"
    }

    private static func bounded(_ value: String, limit: Int) -> String {
        String(value.prefix(limit))
    }
}
