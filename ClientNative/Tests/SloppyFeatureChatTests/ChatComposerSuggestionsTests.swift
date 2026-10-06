import Foundation
import Testing
@testable import SloppyFeatureChat

@Suite("Chat composer suggestions")
struct ChatComposerSuggestionsTests {
    @Test("parses supported triggers at the current token")
    func parsesTriggers() {
        #expect(ChatComposerQuery.parse("/")?.trigger == "/")
        #expect(ChatComposerQuery.parse("hello @read")?.term == "read")
        #expect(ChatComposerQuery.parse("check #task")?.trigger == "#")
        #expect(ChatComposerQuery.parse("email@example.com") == nil)
    }

    @Test("parses every supported trigger at the cursor when text follows it")
    func parsesTriggersBeforeExistingText() throws {
        let cases: [(text: String, trigger: Character, term: String)] = [
            ("/ruДавай спроектируем игру", "/", "ru"),
            ("@loДавай спроектируем игру", "@", "lo"),
            ("#taДавай спроектируем игру", "#", "ta"),
        ]

        for testCase in cases {
            let query = try #require(ChatComposerQuery.parse(testCase.text, cursorOffset: 3))
            #expect(query.trigger == testCase.trigger)
            #expect(query.term == testCase.term)
            #expect(String(testCase.text[query.range]) == "\(testCase.trigger)\(testCase.term)")
        }
    }

    @Test("selection replaces only the active token")
    func appliesSuggestion() throws {
        let text = "Please inspect @rea"
        let query = try #require(ChatComposerQuery.parse(text))
        let suggestion = ChatComposerSuggestion(
            id: "file:README.md",
            kind: .file,
            title: "README.md",
            subtitle: "Project file",
            insertion: "@README.md"
        )

        #expect(query.applying(suggestion, to: text).text == "Please inspect @README.md ")
    }

    @Test("selection replaces the active token without deleting following text")
    func appliesSuggestionBeforeExistingText() throws {
        let text = "Please @rea this file"
        let query = try #require(ChatComposerQuery.parse(text, cursorOffset: 11))
        let suggestion = ChatComposerSuggestion(
            id: "file:README.md",
            kind: .file,
            title: "README.md",
            subtitle: "Project file",
            insertion: "@README.md"
        )

        let application = query.applying(suggestion, to: text)
        #expect(application.text == "Please @README.md this file")
        #expect(application.cursorOffset == 17)
    }

    @Test("infers the cursor from text edits without reading stale string indices")
    func infersCursorFromTextEdits() {
        #expect(ChatComposerTextEdit.cursorOffsetAfterEdit(
            from: "Давай спроектируем игру",
            to: "@Давай спроектируем игру"
        ) == 1)
        #expect(ChatComposerTextEdit.cursorOffsetAfterEdit(
            from: "@lДавай спроектируем игру",
            to: "@loДавай спроектируем игру"
        ) == 3)
        #expect(ChatComposerTextEdit.cursorOffsetAfterEdit(
            from: "Ask @old about it",
            to: "Ask @new about it"
        ) == 8)
        #expect(ChatComposerTextEdit.cursorOffsetAfterEdit(
            from: "Ask #task about it",
            to: "Ask #tas about it"
        ) == 8)
    }

    @Test("finds every supported token for composer highlighting")
    func findsAllHighlightedTokens() {
        let text = "Run /review with @game_studio for #ui next"
        let tokens = ChatComposerToken.parseAll(in: text)

        #expect(tokens.map(\.kind) == [.command, .mention, .tag])
        #expect(tokens.map { String(text[$0.range]) } == ["/review", "@game_studio", "#ui"])
    }

    @Test("only highlights triggers at token boundaries")
    func ignoresEmbeddedTriggers() {
        let text = "mail@example.com https://example.com plain#tag @"
        let tokens = ChatComposerToken.parseAll(in: text)

        #expect(tokens.map(\.kind) == [.mention])
        #expect(tokens.map { String(text[$0.range]) } == ["@"])
    }

    @Test("selection moves with arrow directions and stays within bounds")
    func movesSelection() throws {
        let suggestions = [
            ChatComposerSuggestion(id: "one", kind: .command, title: "/one", subtitle: "", insertion: "/one"),
            ChatComposerSuggestion(id: "two", kind: .command, title: "/two", subtitle: "", insertion: "/two"),
            ChatComposerSuggestion(id: "three", kind: .command, title: "/three", subtitle: "", insertion: "/three"),
        ]
        var selection = ChatComposerSuggestionSelection()

        selection.reconcile(with: suggestions)
        #expect(selection.selectedID == "one")
        let didMoveNext = selection.move(.next, in: suggestions)
        #expect(didMoveNext)
        #expect(selection.selectedID == "two")
        let didMovePrevious = selection.move(.previous, in: suggestions)
        #expect(didMovePrevious)
        #expect(selection.selectedID == "one")
        let didStayAtFirst = selection.move(.previous, in: suggestions)
        #expect(didStayAtFirst)
        #expect(selection.selectedID == "one")
        #expect(selection.selectedSuggestion(in: suggestions)?.id == "one")
    }

    @Test("selection resets when suggestions disappear")
    func resetsSelection() {
        let suggestion = ChatComposerSuggestion(
            id: "one",
            kind: .command,
            title: "/one",
            subtitle: "",
            insertion: "/one"
        )
        var selection = ChatComposerSuggestionSelection()

        selection.reconcile(with: [suggestion])
        selection.reconcile(with: [])

        #expect(selection.selectedID == nil)
        let didMove = selection.move(.next, in: [])
        #expect(!didMove)
    }

    @Test("file suggestions use the server search and are not hidden behind skills")
    func searchesProjectFilesBeforeSkills() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/SloppyFeatureChat/Screens/Chat/ChatScreenViewModel.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains("apiClient.searchProjectFiles("))
        #expect(source.contains("Array((await files).prefix(6))"))
        #expect(source.contains("loadProjectFilesByWalking(matching: query, projectId: projectId)"))
    }
}
