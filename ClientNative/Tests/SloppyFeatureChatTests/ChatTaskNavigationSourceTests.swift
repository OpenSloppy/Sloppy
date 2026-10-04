import Foundation
import Testing

@Suite("Chat task navigation source")
struct ChatTaskNavigationSourceTests {
    private var chatScreenViewModelSource: String {
        get throws {
            let packageRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let sourceURL = packageRoot
                .appendingPathComponent("Sources")
                .appendingPathComponent("SloppyFeatureChat/Screens/Chat/ChatScreenViewModel.swift")
            return try String(contentsOf: sourceURL, encoding: .utf8)
        }
    }

    @Test("empty fork uses its project name instead of the parent chat title")
    func emptyForkUsesProjectName() throws {
        let source = try chatScreenViewModelSource
        let projectNameStart = try #require(source.range(of: "public var activeProjectNameForWorkspacePanel"))
        let nextProperty = try #require(source.range(of: "@ObservationIgnored private let apiClient"))
        let projectNameSource = source[projectNameStart.lowerBound..<nextProperty.lowerBound]

        #expect(projectNameSource.contains("guard let projectId = activeProjectId"))
        #expect(projectNameSource.contains("projects.first(where: { $0.id == projectId })"))
        #expect(projectNameSource.contains("guard selectedSessionId == nil else { return nil }"))

        let selectStart = try #require(source.range(of: "private func selectSession("))
        let blankStart = try #require(source.range(of: "private func routeToBlankChat()"))
        let selectSource = source[selectStart.lowerBound..<blankStart.lowerBound]
        #expect(selectSource.contains("let resolvedProjectId = session?.projectId ?? projectId"))
        #expect(!selectSource.contains("projectId ?? activeProjectId"))
    }

    @Test("task navigation keeps an empty draft until the first send")
    func taskNavigationKeepsAnEmptyDraftUntilTheFirstSend() throws {
        let source = try chatScreenViewModelSource

        #expect(source.contains("private var activeTaskId: String?"))
        #expect(source.contains("activeTaskId = preferredTaskId"))
        #expect(source.contains("let sessionTitle = taskId.map(taskSessionTitle(for:))"))
        #expect(source.contains("let taskId = activeTaskId"))
        #expect(source.contains("projectId: activeProjectId,"))
        #expect(source.contains("taskId: activeTaskId"))
        #expect(source.contains("session.taskId?.caseInsensitiveCompare(taskId) == .orderedSame"))

        let activateStart = try #require(source.range(of: "private func activateProjectContext("))
        let disconnectStart = try #require(source.range(of: "    private func disconnectCurrentSession()"))
        let activateSource = source[activateStart.lowerBound..<disconnectStart.lowerBound]

        #expect(!activateSource.contains("createAgentSession("))
    }

    @Test("project picker opens the main long chat")
    func projectPickerOpensMainChat() throws {
        let source = try chatScreenViewModelSource
        let pickProjectStart = try #require(source.range(of: "public func pickProject("))
        let starterPromptStart = try #require(source.range(of: "public func useStarterPrompt("))
        let pickProjectSource = source[pickProjectStart.lowerBound..<starterPromptStart.lowerBound]

        #expect(pickProjectSource.contains("opensPreferredSession: true"))
        #expect(source.contains("guard opensPreferredSession else"))
    }

    @Test("new message opens an empty draft for the selected project")
    func newMessageOpensEmptyDraftForSelectedProject() throws {
        let source = try chatScreenViewModelSource
        let newMessageStart = try #require(source.range(of: "public func startNewMessage()"))
        let pickProjectStart = try #require(
            source.range(
                of: "public func pickProject(",
                range: newMessageStart.upperBound..<source.endIndex
            )
        )
        let newMessageSource = source[newMessageStart.lowerBound..<pickProjectStart.lowerBound]

        #expect(newMessageSource.contains("guard let projectId = activeProjectId"))
        #expect(newMessageSource.contains("activateProjectContext("))
        #expect(newMessageSource.contains("preferredTaskId: nil"))
        #expect(newMessageSource.contains("opensPreferredSession: false"))
        #expect(!newMessageSource.contains("createAgentSession("))
    }

    @Test("navigation requests can keep a project chat as a new draft")
    func navigationRequestsCanKeepProjectChatAsNewDraft() throws {
        let source = try chatScreenViewModelSource
        let requestSourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/SloppyFeatureChat/Support/ChatNavigationRequest.swift")
        let requestSource = try String(contentsOf: requestSourceURL, encoding: .utf8)

        #expect(requestSource.contains("public var opensPreferredSession: Bool"))
        #expect(requestSource.contains("opensPreferredSession: Bool = true"))
        #expect(source.contains("opensPreferredSession: request.opensPreferredSession"))
    }
}
