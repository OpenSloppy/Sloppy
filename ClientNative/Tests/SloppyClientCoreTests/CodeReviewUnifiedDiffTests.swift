import Foundation
import Testing
@testable import SloppyClientCore

@Suite("One side PR diff")
struct CodeReviewUnifiedDiffTests {
    @Test func replacementsShowAllDeletionsBeforeAdditionsAndRetainSourceRowIDs() throws {
        let files = CodeReviewDiffParser.parse("""
        @@ -10,3 +10,4 @@
        -old first
        -old second
        +new first
        +new second
        +new third
         context
        """)
        let source = try #require(files.first?.hunks.first?.rows)
        let rows = CodeReviewUnifiedDiff.rows(source)
        #expect(rows.map { $0.new.kind == .empty ? $0.old.text : $0.new.text } == [
            "old first", "old second", "new first", "new second", "new third", "context",
        ])
        #expect(rows.prefix(2).allSatisfy { $0.old.kind == .deletion && $0.new.kind == .empty })
        #expect(rows[2].id == source[0].id)
        #expect(rows[2].new.lineNumber == 10)
        #expect(rows[0].old.lineNumber == 10)
        #expect(rows.last?.old.lineNumber == 12)
        #expect(rows.last?.new.lineNumber == 13)
    }

    @Test func additionsAndDeletionsDoNotCreateEmptyVisualRows() throws {
        let added = try #require(CodeReviewDiffParser.parse("@@ -0,0 +1,2 @@\n+first\n+second").first?.hunks.first)
        #expect(CodeReviewUnifiedDiff.rows(added.rows).count == 2)
        #expect(CodeReviewUnifiedDiff.rows(added.rows).allSatisfy { $0.new.kind == .insertion })
        let removed = try #require(CodeReviewDiffParser.parse("@@ -1,2 +0,0 @@\n-first\n-second").first?.hunks.first)
        #expect(CodeReviewUnifiedDiff.rows(removed.rows).count == 2)
        #expect(CodeReviewUnifiedDiff.rows(removed.rows).allSatisfy { $0.old.kind == .deletion })
        #expect(CodeReviewUnifiedDiff.rows([]).isEmpty)
    }

    @Test func annotationsKeepTheirOldOrNewSideWhenARowIsSplit() throws {
        let row = CodeReviewDiffRow(id: 42, old: .init(lineNumber: 10, text: "old", kind: .deletion),
                                   new: .init(lineNumber: 10, text: "new", kind: .insertion))
        let rows = CodeReviewUnifiedDiff.rows([row])
        let old = CodeReviewFixDraft(line: .init(filePath: "File.swift", line: 10, side: .old, content: "old"))
        let new = CodeReviewFixDraft(line: .init(filePath: "File.swift", line: 10, side: .new, content: "new"))
        #expect(old.isAnchored(to: rows[0], filePath: "File.swift"))
        #expect(!old.isAnchored(to: rows[1], filePath: "File.swift"))
        #expect(new.isAnchored(to: rows[1], filePath: "File.swift"))
        #expect(!new.isAnchored(to: rows[0], filePath: "File.swift"))
        let comments = try JSONDecoder().decode([CodeReviewComment].self, from: Data(#"[{"id":"left","body":"old","filePath":"File.swift","line":10,"side":"LEFT"},{"id":"right","body":"new","filePath":"File.swift","line":10,"side":"RIGHT"}]"#.utf8))
        let threads = CodeReviewCommentThread.group(comments)
        #expect(threads[0].isAnchored(to: rows[0], filePath: "File.swift"))
        #expect(!threads[0].isAnchored(to: rows[1], filePath: "File.swift"))
        #expect(threads[1].isAnchored(to: rows[1], filePath: "File.swift"))
        #expect(!threads[1].isAnchored(to: rows[0], filePath: "File.swift"))
    }
}
