import Foundation
import Testing
@testable import SloppyFeatureProjects

@Suite("Inbox task previews")
struct ProjectTaskInboxPreviewTests {
    @Test func markdownBlocksHaveReadableSeparators() {
        let preview = ProjectTaskInboxRow.preview("## Goal\n\nFirst **paragraph**.\n\nSecond paragraph.\n\n- One\n- Two")
        #expect(String(preview.characters) == "Goal\nFirst paragraph.\nSecond paragraph.\nOne\nTwo")
        #expect(preview.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    }

    @Test func inlineRunsStayTogetherAndPreserveLinks() {
        let preview = ProjectTaskInboxRow.preview("Review the [report](https://example.test/report) and `changes`.")
        #expect(String(preview.characters) == "Review the report and changes.")
        #expect(preview.runs.contains { $0.link == URL(string: "https://example.test/report") })
        #expect(preview.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
    }
}
