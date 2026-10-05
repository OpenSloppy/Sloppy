import Foundation
import Testing

@Suite("ChatComposer rendering")
struct ChatComposerRenderingTests {
    private var chatComposerSource: String {
        get throws {
            let packageRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let sourceURL = packageRoot
                .appendingPathComponent("Sources")
                .appendingPathComponent("SloppyFeatureChat/Screens/Chat/Views/ChatComposerView.swift")
            return try String(contentsOf: sourceURL, encoding: .utf8)
        }
    }

    private var composerSuggestionsSource: String {
        get throws {
            let packageRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let sourceURL = packageRoot
                .appendingPathComponent("Sources")
                .appendingPathComponent("SloppyFeatureChat/Screens/Chat/Views/ComposerSuggestionsView.swift")
            return try String(contentsOf: sourceURL, encoding: .utf8)
        }
    }

    private var nativeComposerSource: String {
        get throws {
            let packageRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let sourceURL = packageRoot
                .appendingPathComponent("Sources")
                .appendingPathComponent("SloppyFeatureChat/Screens/Chat/Views/ChatNativeTextEditor.swift")
            return try String(contentsOf: sourceURL, encoding: .utf8)
        }
    }

    @Test("composer text field uses white caret")
    func composerTextFieldUsesWhiteCaret() throws {
        let source = try chatComposerSource
        let nativeSource = try nativeComposerSource

        #expect(nativeSource.contains("textView.tintColor = .white"))
        #expect(nativeSource.contains("textView.insertionPointColor = .white"))
        #expect(source.contains(".pointerStyle(.horizontalText)"))
        #expect(source.contains(".contentShape(Rectangle())"))
        #expect(!source.contains(".focusable()"))
    }

    @Test("composer visually distinguishes command mention and tag tokens")
    func composerHighlightsTokens() throws {
        let source = try chatComposerSource
        let nativeSource = try nativeComposerSource

        #expect(nativeSource.contains("ChatComposerToken.parseAll(in: text)"))
        #expect(nativeSource.contains("case .command: style.commandColor"))
        #expect(nativeSource.contains("case .mention: style.mentionColor"))
        #expect(nativeSource.contains("case .tag: style.tagColor"))
        #expect(source.contains("commandColor: c.accentCyan"))
        #expect(source.contains("mentionColor: c.accent"))
        #expect(source.contains("tagColor: c.accentAcid"))
        #expect(nativeSource.contains("textStorage.setAttributes("))
        #expect(!source.contains("text: attributedDraftBinding("))
        #expect(!source.contains("AttributedTextSelection"))
    }

    @Test("mobile composer uses compact symbols with accessible touch targets")
    func mobileComposerHasCompactAccessibleControls() throws {
        let source = try chatComposerSource

        #expect(source.contains("private struct MobileComposerCircleButton"))
        #expect(source.contains(".frame("))
        #expect(source.contains("width: ChatComposerView.phoneCircleSize"))
        #expect(source.contains("height: 44"))
        #expect(source.contains(".buttonBorderShape(.circle)"))
        #expect(source.contains(".buttonStyle(.plain)"))
        #expect(source.contains("Icons.symbol(.add, size: 18)"))
    }

    @Test("desktop composer uses a compact single-row layout")
    func desktopComposerUsesCompactSingleRowLayout() throws {
        let source = try chatComposerSource

        #expect(source.contains("public static let desktopPanelWidth: CGFloat = 800"))
        #expect(source.contains("public static let panelWidth: CGFloat = 900"))
        #expect(source.contains("#if os(macOS)\n        Self.desktopPanelWidth\n#else\n        Self.panelWidth\n#endif"))
        #expect(source.contains("public static let panelHeight: CGFloat = Constants.fieldHeight"))
        #expect(source.contains("private static let panelRadius: CGFloat = panelHeight / 2"))
        #expect(source.contains("width: ChatComposerView.buttonSize"))
        #expect(source.contains("height: ChatComposerView.buttonSize"))
        #expect(source.contains("HStack(alignment: .bottom, spacing: 0)"))
        #expect(source.contains(".fixedSize(horizontal: true, vertical: false)"))
        #expect(!source.contains("modelPickerBottomPadding"))
    }

    @Test("desktop composer keeps add and trailing actions outside the text field")
    func desktopComposerKeepsActionsOutsideTextField() throws {
        let source = try chatComposerSource
        let surfaceStart = try #require(source.range(of: "private var macComposerInputSurface"))
        let mobileStart = try #require(source.range(of: "#if !os(macOS)", range: surfaceStart.upperBound..<source.endIndex))
        let surfaceSource = source[surfaceStart.lowerBound..<mobileStart.lowerBound]

        #expect(source.contains("HStack(alignment: .bottom, spacing: sp.s)"))
        #expect(source.contains("ComposerAddMenu("))
        #expect(source.contains("macComposerInputSurface"))
        #expect(source.contains("MobileComposerCircleButton("))
        #expect(!surfaceSource.contains("ComposerAddMenu("))
        #expect(!surfaceSource.contains("MobileComposerCircleButton("))
        #expect(surfaceSource.contains(".glassEffect("))
        #expect(!surfaceSource.contains("theme.colors.surface.opacity(0.98)"))
    }

    @Test("desktop model controls stay bottom-right without a button background")
    func desktopModelControlsStayBottomRightWithoutButtonBackground() throws {
        let source = try chatComposerSource

        #expect(source.contains("ComposerContextUsageView(usage: viewModel.contextUsage)"))
        #expect(source.contains(".padding(.trailing, theme.spacing.s)"))
        #expect(source.contains(".padding(.bottom, theme.spacing.s)"))
        #expect(!source.contains("theme.colors.surfaceRaised.opacity(0.72"))
    }

    @Test("context usage is a circular progress view with hover details")
    func contextUsageIsCircularProgressViewWithHoverDetails() throws {
        let source = try chatComposerSource

        #expect(source.contains("private struct ComposerContextUsageView"))
        #expect(source.contains("ProgressView(value: usage?.fraction ?? 0, total: 1)"))
        #expect(source.contains(".progressViewStyle(.circular)"))
        #expect(source.contains(".onHover { isHovering in"))
        #expect(source.contains(".popover(isPresented: $isDetailsPresented"))
        #expect(source.contains("Text(\"Used\")"))
        #expect(source.contains("Text(\"Limit\")"))
    }

    @Test("reasoning picker keeps agent selection as a padded menu row")
    func reasoningPickerKeepsAgentSelectionAsPaddedMenuRow() throws {
        let source = try chatComposerSource

        #expect(source.components(separatedBy: ".menuStyle(.borderlessButton)").count == 2)
        #expect(source.contains("private var agentPicker: some View"))
        #expect(source.contains("Text(selectedAgent?.displayName ?? \"Agent\")"))
        #expect(source.contains(".menuIndicator(.hidden)"))
        #expect(source.contains(".buttonStyle(.plain)"))
        #expect(source.contains(".frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)"))
        #expect(source.contains(".padding(.horizontal, theme.spacing.m)"))
    }

    @Test("desktop add glyph is centered independently from the menu indicator")
    func desktopAddGlyphIsCenteredIndependentlyFromMenuIndicator() throws {
        let source = try chatComposerSource

        #expect(source.contains("struct CustomMenuButtonStyle: MenuStyle"))
        #expect(source.contains("Color.clear"))
        #expect(source.contains("ZStack {\n            Menu(configuration)"))
        #expect(source.contains("Icons.symbol(.add, size: 18)"))
        #expect(source.contains(".allowsHitTesting(false)"))
    }

    @Test("composer add button exposes platform-specific picker menus")
    func composerAddButtonExposesPlatformSpecificPickerMenus() throws {
        let source = try chatComposerSource

        #expect(source.contains("private struct ComposerAddMenu"))
        #expect(source.contains("Label(\"Files and Attach\""))
        #expect(source.contains("private struct ComposerOptionsMenuView"))
        #expect(source.contains("Label(\"Camera\""))
        #expect(source.contains("Label(\"Photos\""))
        #expect(source.contains("Label(\"Files\""))
        #expect(source.contains("Label(\"Agent\""))
        #expect(source.contains("Label(\"Effort\""))
        #expect(source.contains(".menuIndicator(.hidden)"))
        #expect(source.contains(".menuStyle(.button)"))
    }

    @Test("chat composer phone layout exposes tab action hooks")
    func chatComposerPhoneLayoutExposesTabActionHooks() throws {
        let source = try chatComposerSource

        #expect(source.contains("public struct ChatComposerTabActions"))
        #expect(source.contains("public let tabActions: ChatComposerTabActions?"))
        #expect(source.contains("tabActions?.selectAdjacentTab(horizontal < 0 ? 1 : -1)"))
        #expect(source.contains("tabActions?.showOverview()"))
        #expect(source.contains("maxHeight: isExpandedPhoneLayout ? .infinity : Self.phoneFieldHeight"))
        #expect(source.contains(".frame(height: currentPanelHeight, alignment: .bottom)"))
    }

    @Test("phone composer expands on focus and exposes agent and model pickers")
    func phoneComposerExpandsOnFocusWithContextPickers() throws {
        let source = try chatComposerSource

        #expect(source.contains("idiom == .phone && viewModel.isMobileComposerExpanded"))
        #expect(source.contains("public static let expandedPhonePanelHeight: CGFloat = 196"))
        #expect(source.contains("onFocusChanged: updatePhoneComposerExpansion"))
        #expect(source.contains(".onChange(of: isTextFieldFocused)"))
        #expect(source.contains("private var isExpandedPhoneLayout: Bool"))
        #expect(source.contains("textFieldContainer(showsGlassBackground: false)"))
        #expect(!source.contains("private var expandedPhoneComposer: some View"))
        #expect(source.contains("MobileComposerAgentPicker("))
        #expect(source.contains("MobileComposerModelPicker("))
        #expect(source.contains("chat.composer.expanded"))
        #expect(source.contains("chat.composer.agent-picker"))
        #expect(source.contains("chat.composer.model-picker"))
        #expect(source.contains("if idiom != .phone"))
    }

    @Test("composer text fields are focusable and can be blurred externally")
    func composerTextFieldsAreFocusableAndCanBeBlurredExternally() throws {
        let source = try chatComposerSource
        let nativeSource = try nativeComposerSource

        #expect(source.contains("@State private var isTextFieldFocused = false"))
        #expect(source.contains("isFocused: $isTextFieldFocused"))
        #expect(source.contains(".onChange(of: viewModel.composerFocusResetToken)"))
        #expect(source.contains("isTextFieldFocused = false"))
        #expect(nativeSource.contains("textViewDidBeginEditing"))
        #expect(nativeSource.contains("textDidBeginEditing"))
        #expect(nativeSource.contains("synchronizeFocus"))
    }

    @Test("composer submit delegates clearing to the view model send path")
    func composerSubmitDelegatesClearingToViewModelSendPath() throws {
        let source = try chatComposerSource

        #expect(source.contains("viewModel.sendMessage(content: trimmed)"))
        #expect(!source.contains("draft.text = \"\""))
    }

    @Test("composer always uses the currently selected chat view model")
    func composerUsesCurrentlySelectedChatViewModel() throws {
        let source = try chatComposerSource

        #expect(source.contains("private let viewModel: ChatScreenViewModel"))
        #expect(source.contains("self.viewModel = viewModel"))
        #expect(!source.contains("@State private var viewModel: ChatScreenViewModel"))
        #expect(!source.contains("State(initialValue: viewModel)"))
    }

    @Test("composer renders removable attachments and accepts clipboard files")
    func composerRendersAttachmentsAndAcceptsPaste() throws {
        let source = try chatComposerSource
        let nativeSource = try nativeComposerSource

        #expect(source.contains("private struct ChatComposerAttachmentStrip"))
        #expect(source.contains("viewModel.composerAttachments"))
        #expect(source.contains("remove: viewModel.removeComposerAttachment"))
        #expect(source.contains("pasteItemProviders: viewModel.attachItemProviders"))
        #expect(nativeSource.contains("override func paste(_ sender: Any?)"))
        #expect(nativeSource.contains("UIPasteboard.general.itemProviders"))
        #expect(nativeSource.contains("onPasteItemProviders?(attachmentProviders)"))
        #expect(nativeSource.contains("onPasteAttachment?()"))
        #expect(source.contains("NSPasteboard.general"))
        #expect(source.contains("pasteboard.data(forType: .png)"))
        #expect(source.contains("NSImage(pasteboard: pasteboard)"))
        #expect(source.contains("pasteAttachmentsFromSystemPasteboard()"))
        #expect(source.contains("private struct ChatComposerAttachmentPreview"))
        #expect(source.contains("Image(nsImage: image)"))
        #expect(source.contains("Image(systemName: \"xmark.circle.fill\")"))
        #expect(source.contains("HStack(alignment: .bottom, spacing: sp.s)"))
    }

    @Test("attachment-only drafts expose the send action")
    func attachmentOnlyDraftsCanSubmit() throws {
        let source = try chatComposerSource

        #expect(source.contains("!trimmedDraftText.isEmpty || !viewModel.composerAttachments.isEmpty"))
        #expect(source.contains("!trimmed.isEmpty || !viewModel.composerAttachments.isEmpty"))
        #expect(source.contains("|| !viewModel.composerQuotes.isEmpty"))
    }

    @Test("composer text fields submit on enter")
    func composerTextFieldsSubmitOnEnter() throws {
        let nativeSource = try nativeComposerSource

        #expect(nativeSource.contains("textView.returnKeyType = .send"))
        #expect(nativeSource.contains("shouldChangeTextIn range: NSRange"))
        #expect(nativeSource.contains("onSubmit?()"))
    }

    @Test("shift return inserts a newline without submitting")
    func shiftReturnInsertsNewlineWithoutSubmitting() throws {
        let nativeSource = try nativeComposerSource

        #expect(nativeSource.contains("override func pressesBegan"))
        #expect(nativeSource.contains("key.modifierFlags.contains(.shift)"))
        #expect(nativeSource.contains("isInsertingModifiedNewline = true"))
        #expect(nativeSource.contains("override func keyDown(with event: NSEvent)"))
        #expect(nativeSource.contains("event.modifierFlags.contains(.shift)"))
        #expect(nativeSource.contains("insertText(\"\\n\""))
        #expect(nativeSource.contains("ChatComposerNativeSelection.textSelection("))
    }

    @Test("composer wraps long text without reserving its maximum height")
    func composerTextFieldWrapsLongTextWithoutInflating() throws {
        let source = try chatComposerSource
        let nativeSource = try nativeComposerSource

        #expect(!source.contains("text: attributedDraftBinding("))
        #expect(source.contains("UIKitChatComposerTextEditor("))
        #expect(source.contains("AppKitChatComposerTextEditor("))
        #expect(source.contains("Constants.editorContentHorizontalInset"))
        #expect(source.contains("static let editorContentHorizontalInset: CGFloat = 8"))
        #expect(source.contains("static let editorContentVerticalInset: CGFloat = 7"))
        #expect(source.contains(".frame(height: editorHeight)"))
        #expect(source.contains("static let maximumVisibleLines = 6"))
        #expect(nativeSource.contains("sizeThatFits("))
        #expect(nativeSource.contains("layoutManager.usedRect(for: textContainer)"))
        #expect(source.contains(".frame(minHeight: currentPanelHeight, alignment: .bottom)"))
        #expect(!source.contains("maximumPanelHeight"))
        #expect(source.contains("private static let panelRadius: CGFloat = panelHeight / 2"))
        #expect(source.contains("static let fieldHorizontalPadding: CGFloat = fieldHeight / 2"))
        #expect(source.contains("RoundedRectangle(cornerRadius: Self.panelRadius, style: .continuous)"))
        #expect(source.contains(".padding(.horizontal, idiom == .phone ? 0 : Constants.fieldHorizontalPadding)"))
        #expect(source.contains(".padding(.vertical, sp.s)"))
    }

    @Test("long composer text stays bounded and scrolls vertically")
    func longComposerTextStaysBoundedAndScrollable() throws {
        let source = try chatComposerSource
        let nativeSource = try nativeComposerSource

        #expect(source.contains(".clipped()"))
        #expect(source.contains(".layoutPriority(1)"))
        #expect(nativeSource.contains("textView.isScrollEnabled = shouldScroll"))
        #expect(nativeSource.contains("scrollView.hasVerticalScroller = shouldScroll"))
        #expect(nativeSource.contains("maximumVisibleLines"))
    }

    @Test("composer draft is observable so trailing action reacts while typing")
    func composerDraftIsObservable() throws {
        let source = try chatComposerSource

        #expect(source.contains("@Observable"))
        #expect(source.contains("@Bindable public var draft: ChatComposerDraft"))
        #expect(source.contains("@Bindable var draft: ChatComposerDraft"))
        #expect(source.contains("ChatTextField("))
        #expect(source.contains("draft: draft,"))
        #expect(source.contains("text: $draft.text"))
        #expect(source.contains("selection: $draft.selection"))
    }

    @Test("composer command suggestions use a full-size panel")
    func composerSuggestionsUseFullSizePanel() throws {
        let composerSource = try chatComposerSource
        let suggestionsSource = try composerSuggestionsSource

        #expect(suggestionsSource.contains("static let panelHeight: CGFloat = 320"))
        #expect(suggestionsSource.contains("minHeight: Self.panelHeight"))
        #expect(suggestionsSource.contains("maxHeight: Self.panelHeight"))
        #expect(composerSource.contains(".overlay(alignment: .top)"))
        #expect(composerSource.contains(".offset(y: -(ComposerSuggestionsView.panelHeight + autocompleteGap))"))
        #expect(!composerSource.contains(".alignmentGuide(.top)"))
        #expect(!composerSource.contains("composerSuggestionsOffset"))
    }

    @Test("composer trailing action swaps between dictation send queue and stop")
    func composerTrailingActionSupportsDictationSendingAndStoppingRuns() throws {
        let source = try chatComposerSource

        #expect(source.contains("DictationComposerBar("))
        #expect(source.contains("if viewModel.isShowingDictationComposer"))
        #expect(source.contains("return viewModel.willQueueMessage ? .timer : .arrowUpward"))
        #expect(source.contains("viewModel.startDictation()"))
        #expect(source.contains("stop: viewModel.stopDictation"))
        #expect(source.contains("viewModel.stopActiveRun()"))
        #expect(source.contains("guard (!trimmed.isEmpty || !viewModel.composerAttachments.isEmpty"))
        #expect(source.contains("|| !viewModel.composerQuotes.isEmpty), viewModel.canSubmitMessage else { return }"))
    }

    @Test("composer dictation bar replaces controls with waveform timer and stop button")
    func composerDictationBarReplacesControls() throws {
        let source = try chatComposerSource

        #expect(source.contains("private struct DictationComposerBar"))
        #expect(source.contains("ForEach(levels.indices, id: \\.self)"))
        #expect(source.contains("Text(elapsedText)"))
        #expect(source.contains("Icons.symbol(.stop"))
        #expect(!source.contains("draft.requestDictation()"))
    }

    @Test("dictation bar keeps trailing controls fixed while waveform can overflow left")
    func dictationBarKeepsTrailingControlsFixed() throws {
        let source = try chatComposerSource
        let dictationStart = try #require(source.range(of: "private struct DictationComposerBar"))
        let customTabStart = try #require(source.range(of: "extension BinaryFloatingPoint"))
        let dictationSource = source[dictationStart.lowerBound..<customTabStart.lowerBound]

        #expect(source.contains("private let elapsedTextWidth: CGFloat = 64"))
        #expect(source.contains("private let stopButtonSize: CGFloat = 32"))
        #expect(source.contains("private var trailingControlsWidth: CGFloat {"))
        #expect(source.contains("elapsedTextWidth + theme.spacing.s + stopButtonSize"))
        #expect(source.contains("waveformViewport"))
        #expect(source.contains("waveformView"))
        #expect(source.contains("trailingControls"))
        #expect(source.contains(".frame(maxWidth: .infinity, alignment: .trailing)"))
        #expect(source.contains(".overlay(alignment: .trailing)"))
        #expect(source.contains("Color.clear"))
        #expect(source.contains(".allowsHitTesting(false)"))
        #expect(!dictationSource.contains(".containerRelativeFrame(.horizontal)"))
    }

    @Test("desktop composer exposes an effort scale above a searchable model picker")
    func desktopComposerExposesEffortScaleAndSearchableModelPicker() throws {
        let source = try chatComposerSource

        #expect(source.contains("private struct ComposerOptionsMenuView"))
        #expect(source.contains("Text(selectedModelTitle)"))
        #expect(source.contains("Text(\"· \\(selectedEffort.title)\")"))
        #expect(!source.contains("Text(supportsReasoningEffort ? \"Select effort\" : selectedModelTitle)"))
        #expect(source.contains("private struct ComposerEffortScale"))
        #expect(source.contains("let efforts = ChatReasoningEffort.allCases"))
        #expect(source.contains("let thumbCenter = segmentWidth * (CGFloat(selectedIndex) + 0.5)"))
        #expect(source.contains("private let fillTrailingSpacing: CGFloat = 8"))
        #expect(source.contains("let isMaximumEffort = selectedIndex == efforts.count - 1"))
        #expect(source.contains("? proxy.size.width"))
        #expect(source.contains("thumbCenter + thumbSize / 2 + fillTrailingSpacing"))
        #expect(source.contains("Capsule()\n                    .fill(levelColor)"))
        #expect(source.contains(".clipShape(Capsule())"))
        #expect(source.contains("Text(selectedEffort.title)"))
        #expect(source.contains("Text(selectedModelTitle)"))
        #expect(source.contains("onSelectEffort(.default)"))
        #expect(source.contains("chat.composer.effort-picker"))
        #expect(source.contains("chat.composer.effort-slider"))
        #expect(source.contains("DragGesture(minimumDistance: 0, coordinateSpace: .local)"))
        #expect(source.contains("selectEffort(at: value.location.x, width: proxy.size.width)"))
        #expect(source.contains("private let height: CGFloat = 36"))
        #expect(source.contains("private enum ComposerEffortPalette"))
        #expect(source.contains("theme.colors.statusNeutral"))
        #expect(source.contains("theme.colors.accentCyan"))
        #expect(source.contains("theme.colors.statusWarning"))
        #expect(!source.contains("Image(systemName: \"bolt\")"))
        #expect(source.contains("Text(\"Select model\")"))
        #expect(source.contains(".frame(width: isModelPickerPresented ? 440 : 360)"))
        #expect(source.contains(".frame(minHeight: 160, maxHeight: 380)"))
        #expect(source.contains(".frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)"))
        #expect(source.contains("TextField(\"Search models\", text: $searchText)"))
        #expect(source.contains("groupedModels"))
        #expect(source.contains("Constants.modelPickerRowHeight"))
        #expect(source.contains("isRefreshing ? \"Refreshing…\" : \"Refresh\""))
        #expect(source.contains("Edit Models…"))
        #expect(source.contains("chat.composer.model-picker"))
        #expect(source.contains("chat.composer.model-list"))
        #expect(source.contains("private struct ComposerMenuItem"))
        #expect(source.contains("private var selectedModelTitle: String"))
        #expect(source.contains(".popover(isPresented: $isPresented"))
    }
}
