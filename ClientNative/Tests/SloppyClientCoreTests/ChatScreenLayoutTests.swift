import Foundation
import Testing

@Suite("Chat screen layout")
struct ChatScreenLayoutTests {
    private func source(_ path: String...) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = path.reduce(packageRoot) { $0.appendingPathComponent($1) }
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("phone chat layout avoids geometry reader on first render")
    func phoneChatLayoutAvoidsGeometryReaderOnFirstRender() throws {
        let source = try source("Sources", "SloppyFeatureChat", "Screens", "Chat", "ChatScreen.swift")

        #expect(source.contains("if idiom == .phone"))
        #expect(source.contains("chromeLayout(contentWidth: phoneContentWidth)"))
        #expect(source.contains("private var phoneContentWidth: CGFloat"))
        #expect(source.contains("screenPointWidth - rootSafeAreaInsets.leading - rootSafeAreaInsets.trailing"))
    }

    @Test("mobile composer expands to available width with dedicated circle buttons")
    func mobileComposerExpandsToAvailableWidthWithDedicatedCircleButtons() throws {
        let source = try source("Sources", "SloppyFeatureChat", "Screens", "Chat", "Views", "ChatComposerView.swift")

        #expect(source.contains("private struct MobileComposerCircleButton"))
        #expect(source.contains("maxWidth: .infinity,\n            minHeight: currentPanelHeight,\n            alignment: .leading"))
        #expect(source.contains("width: ChatComposerView.phoneCircleSize,"))
        #expect(source.contains("height: 44"))
        #expect(source.contains(".buttonBorderShape(.circle)"))
        #expect(source.contains(".buttonStyle(.plain)"))
        #expect(!source.contains(".debugOverlay(.layoutBounds)"))
    }

    @Test("composer uses a compact searchable model picker")
    func composerUsesCompactSearchableModelPicker() throws {
        let source = try source("Sources", "SloppyFeatureChat", "Screens", "Chat", "Views", "ChatComposerView.swift")

        #expect(source.contains("private struct ComposerOptionsMenuView"))
        #expect(source.contains("TextField(\"Search models\", text: $searchText)"))
        #expect(source.contains(".popover(isPresented: $isPresented"))
        #expect(source.contains("onRefreshModels: viewModel.refreshAvailableModels"))
        #expect(source.contains("onEditModels: { viewModel.openSettings(.providers) }"))
    }

    @Test("desktop transcript keeps full width scroll host with centered content column")
    func desktopTranscriptKeepsFullWidthScrollHostWithCenteredContentColumn() throws {
        let source = try source("Sources", "SloppyFeatureChat", "Screens", "Chat", "ChatScreen.swift")
        let nativeSource = try self.source("Sources", "SloppyFeatureChat", "Screens", "Chat", "Views", "ChatNativeTranscriptView.swift")

        #expect(source.contains("ChatNativeTranscriptView("))
        #expect(nativeSource.contains(".frame(width: parent.contentWidth)"))
        #expect(nativeSource.contains(".frame(width: viewportWidth)"))
        #expect(source.contains(".frame(maxWidth: .infinity)"))
        #expect(!source.contains(".frame(width: contentWidth)\n                .frame(maxHeight: .infinity)"))
    }

    @Test("transcript virtualizes markdown message rows during scrolling")
    func transcriptUsesNativeCollectionForMarkdownMessageRows() throws {
        let source = try source("Sources", "SloppyFeatureChat", "Screens", "Chat", "ChatScreen.swift")
        let nativeSource = try self.source("Sources", "SloppyFeatureChat", "Screens", "Chat", "Views", "ChatNativeTranscriptView.swift")

        #expect(source.contains("ChatNativeTranscriptView("))
        #expect(nativeSource.contains("NSCollectionViewDiffableDataSource"))
        #expect(nativeSource.contains("UICollectionViewDiffableDataSource"))
    }

    @Test("tapping chat content dismisses composer focus")
    func tappingChatContentDismissesComposerFocus() throws {
        let source = try source("Sources", "SloppyFeatureChat", "Screens", "Chat", "ChatScreen.swift")

        #expect(source.contains(".contentShape(Rectangle())"))
        #expect(source.contains(".onTapGesture {"))
        #expect(source.contains("viewModel.dismissComposerFocus()"))
    }
}
