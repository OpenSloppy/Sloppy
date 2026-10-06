import Foundation
import Testing

@Suite("ChatScreen rendering")
struct ChatScreenRenderingTests {
    @Test("desktop chat toolbar provides a dismiss back button")
    func desktopChatToolbarProvidesDismissBackButton() throws {
        let source = try chatScreenSource

        #expect(source.contains("@Environment(\\.dismiss) private var dismiss"))
        #expect(source.contains("Image(systemName: \"chevron.left\")"))
        #expect(source.contains("Button(action: { dismiss() })"))
        #expect(source.contains(".accessibilityLabel(\"Back\")"))
    }

    private var chatScreenSource: String {
        get throws {
            let packageRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let sourceURL = packageRoot
                .appendingPathComponent("Sources")
                .appendingPathComponent("SloppyFeatureChat")
                .appendingPathComponent("Screens")
                .appendingPathComponent("Chat")
                .appendingPathComponent("ChatScreen.swift")
            return try String(contentsOf: sourceURL, encoding: .utf8)
        }
    }

    private var nativeTranscriptSource: String {
        get throws {
            let packageRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            return try String(
                contentsOf: packageRoot
                    .appendingPathComponent("Sources/SloppyFeatureChat/Screens/Chat/Views/ChatNativeTranscriptView.swift"),
                encoding: .utf8
            )
        }
    }

    @Test("root chat content delegates rendering to chat chrome and loads initial data on appear")
    func rootChatContentDelegatesRenderingToChatChrome() throws {
        let source = try chatScreenSource
        let contentStart = try #require(source.range(of: "private struct ChatScreenContent: View"))
        let chromeStart = try #require(source.range(of: "private struct ChatChrome: View"))
        let contentSource = source[contentStart.lowerBound..<chromeStart.lowerBound]

        #expect(contentSource.contains("ChatChrome("))
        #expect(source.contains("ChatNavigationToolbarModifier"))
        #expect(contentSource.contains("viewModel.loadInitialData()"))
    }

    @Test("phone navigation uses a native title without a custom capsule or burger")
    func phoneNavigationUsesNativeTitle() throws {
        let source = try chatScreenSource

        #expect(source.contains(".navigationTitle(viewModel.activeSessionTitle)"))
        #expect(source.contains(".navigationBarTitleDisplayMode(.inline)"))
        #expect(!source.contains("MobileChatNavigationHeader"))
        #expect(!source.contains("MobileChatNavigationCenterCapsule"))
        #expect(!source.contains("MobileChatNavigationIconButton(symbol: .menu"))
    }

    @Test("phone navigation offers a new message button")
    func phoneNavigationOffersNewMessageButton() throws {
        let source = try chatScreenSource

        #expect(source.contains("Label(\"New message\", systemImage: \"square.and.pencil\")"))
        #expect(source.contains("viewModel.startNewMessage()"))
        #expect(source.contains(".accessibilityLabel(\"New message\")"))
        #expect(source.contains(".accessibilityIdentifier(\"chat.navigation.new-message\")"))
    }

    @Test("attachment importer accepts arbitrary files")
    func attachmentImporterAcceptsArbitraryFiles() throws {
        let source = try chatScreenSource

        #expect(source.contains("allowedContentTypes: [.item]"))
        #expect(!source.contains("allowedContentTypes: []"))
    }

    @Test("connection failures do not cover the chat with a banner")
    func connectionFailuresDoNotCoverChatWithBanner() throws {
        let source = try chatScreenSource

        #expect(!source.contains("ChatConnectionBar"))
        #expect(!source.contains("ConnectionBanner"))
    }

    @Test("empty mobile chat keeps composer pinned to bottom")
    func emptyMobileChatKeepsComposerPinnedToBottom() throws {
        let source = try chatScreenSource

        #expect(source.contains("bottomClearance: composerScrollInset"))
        #expect(source.contains(".padding(.bottom, bottomClearance)"))
    }

    @Test("composer reports its growing height to transcript clearance")
    func composerReportsGrowingHeightToTranscriptClearance() throws {
        let source = try chatScreenSource
        let nativeSource = try nativeTranscriptSource

        #expect(source.contains("viewModel.composerPanelHeight ?? fallbackHeight"))
        #expect(source.contains(".onGeometryChange(for: CGFloat.self, of: { $0.size.height })"))
        #expect(source.contains("viewModel.updateComposerPanelHeight(height)"))
        #expect(source.contains("bottomInset: composerScrollInset"))
        #expect(nativeSource.contains("bottomInsetChanged"))
        #expect(nativeSource.contains("collectionView.contentInset"))
        #expect(nativeSource.contains("scrollView.contentInsets"))
    }

    @Test("composer overlay respects the desktop maximum width")
    func composerOverlayRespectsDesktopMaximumWidth() throws {
        let source = try chatScreenSource

        #expect(source.contains(".frame(maxWidth: maximumComposerWidth)"))
        #expect(source.contains("min(contentWidth, ChatComposerView.desktopPanelWidth)"))
        #expect(source.contains("#else\n        contentWidth\n#endif"))
        #expect(!source.contains(".frame(width: contentWidth)"))
    }

    @Test("empty task draft surfaces the active context to the user")
    func emptyTaskDraftSurfacesTheActiveContextToTheUser() throws {
        let source = try chatScreenSource

        #expect(source.contains("if let activeContextTitle = viewModel.activeContextTitle"))
        #expect(source.contains("Text(activeContextTitle)"))
    }

    @Test("empty chat offers project picker and starter prompts")
    func emptyChatOffersProjectPickerAndStarterPrompts() throws {
        let source = try chatScreenSource
        let greetingSource = try chatGreetingSource

        #expect(source.contains("projects: viewModel.projects"))
        #expect(source.contains("onSelectProject: viewModel.pickProject"))
        #expect(source.contains("selectedProjectName: viewModel.activeProjectNameForWorkspacePanel"))
        #expect(source.contains("onSelectPrompt: viewModel.useStarterPrompt"))
        #expect(greetingSource.contains("Menu {"))
        #expect(greetingSource.contains("What should we do in"))
        #expect(greetingSource.contains("Explore and understand code"))
        #expect(greetingSource.contains("Fix issues and failures"))
    }

    @Test("starter prompt cards expose a visible hover state")
    func starterPromptCardsExposeVisibleHoverState() throws {
        let source = try chatGreetingSource

        #expect(source.contains("@State private var isHovered = false"))
        #expect(source.contains(".onHover { isHovered = $0 }"))
        #expect(source.contains("isHovered ? prompt.color.opacity"))
        #expect(source.contains(".scaleEffect(isHovered ?"))
    }

    @Test("empty chat uses the muted Sloppy logo")
    func emptyChatUsesMutedSloppyLogo() throws {
        let source = try chatGreetingSource

        #expect(source.contains("SloppyAssets.projectLogo"))
        #expect(source.contains(".renderingMode(.template)"))
        #expect(source.contains(".foregroundColor(c.textMuted)"))
        #expect(!source.contains("Image(systemName: \"terminal\")"))
    }

    @Test("mobile navigation label shows the active context for drafts")
    func mobileNavigationLabelShowsTheActiveContextForDrafts() throws {
        let source = try chatScreenSource

        #expect(source.contains("viewModel.activeSessionTitle"))
    }

    @Test("desktop chat identifies the active session and surfaces send failures")
    func desktopChatIdentifiesTheActiveSessionAndSurfacesSendFailures() throws {
        let source = try chatScreenSource

        #expect(source.contains("ChatSessionContextBar(viewModel: viewModel)"))
        #expect(source.contains("viewModel.activeSessionTitle"))
        #expect(source.contains("viewModel.sendErrorMessage"))
        #expect(source.contains("providerSettingsRecoveryMessageIDs.contains(message.id)"))
        #expect(source.contains("viewModel.openSettings(.providers)"))
        #expect(source.contains("Current session:"))
    }

    @Test("agent selection is not embedded into the phone navigation title")
    func agentSelectionIsNotEmbeddedIntoPhoneNavigationTitle() throws {
        let source = try chatScreenSource

        #expect(!source.contains("Picker(\"\", selection: selectedAgentId"))
        #expect(source.contains("ChatContextToolbarModifier"))
        #expect(source.contains("if idiom == .phone {\n            content\n        } else if isEnabled"))
    }

    @Test("empty transcript shows progress while session history is loading")
    func emptyTranscriptShowsLoadingProgress() throws {
        let source = try chatScreenSource

        #expect(source.contains("viewModel.isLoadingTranscript, viewModel.transcript.isEmpty"))
        #expect(source.contains("private struct ChatTranscriptLoadingView"))
        #expect(source.contains(".accessibilityLabel(\"Loading conversation\")"))
        #expect(source.contains("chat.transcript.loading"))
    }

    @Test("chat only follows new messages while the transcript is near the bottom")
    func chatOnlyFollowsNewMessagesNearBottom() throws {
        let source = try chatScreenSource
        let nativeSource = try nativeTranscriptSource

        #expect(source.contains("ChatNativeTranscriptView("))
        #expect(nativeSource.contains("private struct ViewportAnchor"))
        #expect(nativeSource.contains("followsBottom: isNearBottom && followsBottom"))
        #expect(nativeSource.contains("contentBottom - 44"))
        #expect(nativeSource.contains("visibleBottom >= contentHeight + parent.bottomInset - 44"))
        #expect(nativeSource.contains("self.restoreViewport(viewportAnchor)"))
        #expect(nativeSource.contains("attributes.frame.minY - anchor.itemOffset"))
        #expect(nativeSource.contains("self.parentUpdateGeneration == generation"))
    }

    @Test("opening a chat always starts at the end of the transcript")
    func openingChatStartsAtTranscriptEnd() throws {
        let source = try chatScreenSource
        let nativeSource = try nativeTranscriptSource

        #expect(source.contains("scrollToEndRequest: viewModel.transcriptScrollToEndRequest"))
        #expect(source.contains("scrollToEndRequest: scrollToEndRequest"))
        #expect(nativeSource.contains("previousScrollRequest != parent.scrollToEndRequest"))
        #expect(nativeSource.contains("scrollToBottom"))
    }

    @Test("short chats align their first message to the top")
    func shortChatsAlignFirstMessageToTop() throws {
        let source = try chatScreenSource

        #expect(source.contains("topInset: viewModel.hasEarlierTranscriptMessages ? 0 : messagesTopInset"))
    }

    @Test("desktop chat uses a wide transparent transcript with time separators")
    func desktopChatUsesTransparentTranscriptChrome() throws {
        let source = try chatScreenSource

        #expect(source.contains("fileprivate let chatContentWidth: CGFloat = 960"))
        #expect(!source.contains(".background(theme.colors.background)"))
        #expect(!source.contains("theme.colors.background.opacity(0.88 as Double)"))
        #expect(source.contains("ChatTranscriptDateSeparators.shouldInsert"))
        #expect(source.contains("case .dateSeparator(let date)"))
        #expect(source.contains(".frame(maxWidth: maximumComposerWidth)"))
    }

    @Test("chat groups system activity and shows a shimmering thinking state")
    func chatGroupsSystemActivityAndShowsThinkingState() throws {
        let source = try chatScreenSource

        #expect(source.contains("for (index, entry) in transcript.entries.enumerated()"))
        #expect(source.contains("ChatSystemMessageGroupView("))
        #expect(source.contains("activeRunMessageIDs: activeRunMessageIDs"))
        #expect(source.contains("ChatThinkingIndicator(label: label, details: details)"))
        #expect(source.contains("viewModel.isAwaitingAgentResponse"))
        #expect(source.contains("ChatActiveRunMessages.messageIDs"))
        #expect(source.contains("activeRunMessageIDs.contains(message.id)"))
        #expect(source.contains("content: .thinking(label: runStatusLabel, details: runStatusDetails)"))
    }

    @Test("transcript does not intercept text-selection gestures")
    func transcriptDoesNotInterceptTextSelectionGestures() throws {
        let source = try chatScreenSource
        let transcriptStart = try #require(source.range(of: "private struct ChatTranscriptRegion"))
        let emptyChatStart = try #require(source.range(of: "private struct ChatEmptyChatRegion"))
        let transcriptSource = source[transcriptStart.lowerBound..<emptyChatStart.lowerBound]

        #expect(!transcriptSource.contains(".onTapGesture"))
        #expect(!transcriptSource.contains(".contentShape"))
    }

    private var chatGreetingSource: String {
        get throws {
            let packageRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            return try String(
                contentsOf: packageRoot
                    .appendingPathComponent("Sources/SloppyFeatureChat/Screens/Chat/Views/ChatGreetingView.swift"),
                encoding: .utf8
            )
        }
    }
}
