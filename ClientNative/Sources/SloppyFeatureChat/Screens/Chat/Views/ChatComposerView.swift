import Foundation
import Observation
import SwiftUI
import SloppyClientUI
import SloppyClientCore
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@Observable
@MainActor
public final class ChatComposerDraft {
    public var text: String {
        didSet {
            if text != oldValue {
                selection = nil
            }
        }
    }
    public var selection: TextSelection?
    
    public init(text: String = "", selection: TextSelection? = nil) {
        self.text = text
        self.selection = selection
    }
}

public struct ChatComposerView: View {
    public static let desktopPanelWidth: CGFloat = 800
    public static let panelWidth: CGFloat = 900
    public static let panelHeight: CGFloat = Constants.fieldHeight
    public static let phonePanelHeight: CGFloat = 56
    public static let expandedPhonePanelHeight: CGFloat = 196
    public static let attachmentStripHeight: CGFloat = 112
    private static let panelRadius: CGFloat = panelHeight / 2
    private static let expandedPhonePanelRadius: CGFloat = 28
    private static let phoneFieldHeight: CGFloat = 48
    fileprivate static let phoneCircleSize: CGFloat = 36
    fileprivate static let buttonSize: CGFloat = panelHeight
    private static let overviewGestureDistance: CGFloat = 220

    private let viewModel: ChatScreenViewModel
    @State private var isOverviewGestureActive = false
    @State private var imageToAnnotate: ChatComposerAttachment?
    let tabs: [WorkspaceTab]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.userInterfaceIdiom) private var idiom
    @Environment(\.theme) private var theme
    @Environment(\.chatComposerConnectionActions) private var connectionActions
    @Environment(\.mobileComposerAvailableHeight) private var mobileComposerAvailableHeight

    @Bindable public var draft: ChatComposerDraft
    public let tabActions: ChatComposerTabActions?

    public init(
        draft: ChatComposerDraft,
        tabs: [WorkspaceTab],
        viewModel: ChatScreenViewModel,
        tabActions: ChatComposerTabActions? = nil
    ) {
        self.draft = draft
        self.tabs = tabs
        self.tabActions = tabActions
        self.viewModel = viewModel
    }
    
    @ViewBuilder
    public var body: some View {
        Group {
            #if os(visionOS)
            regularBody
            #else
            GlassEffectContainer {
                regularBody
            }
            #endif
        }
        .sheet(item: $imageToAnnotate, onDismiss: viewModel.requestComposerFocus) { attachment in
            ChatImageAnnotationEditor(attachment: attachment) { annotations in
                viewModel.updateImageAnnotations(id: attachment.id, annotations: annotations)
            }
        }
    }
    
    private var usesDesktopComposer: Bool {
#if os(macOS)
        true
#elseif os(iOS)
        idiom != .phone
#else
        false
#endif
    }

    private var regularBody: some View {
        let c = theme.colors
        let sp = theme.spacing
        let autocompleteGap = theme.spacing.s

        return VStack(spacing: sp.s) {
            if !usesDesktopComposer {
                if !viewModel.composerQuotes.isEmpty {
                    ChatComposerQuoteStrip(
                        quotes: viewModel.composerQuotes,
                        update: viewModel.updateComposerQuote,
                        remove: viewModel.removeComposerQuote
                    )
                }
                if !viewModel.composerAttachments.isEmpty {
                    ChatComposerAttachmentStrip(
                        attachments: viewModel.composerAttachments,
                        annotate: { imageToAnnotate = $0 },
                        remove: viewModel.removeComposerAttachment
                    )
                    .frame(height: Self.attachmentStripHeight)
                }
            }
            ZStack {
                if viewModel.isShowingDictationComposer {
                    DictationComposerBar(
                        phase: viewModel.dictationPhase,
                        levels: viewModel.dictationLevels,
                        elapsed: viewModel.dictationDuration,
                        stop: viewModel.stopDictation
                    )
                } else {
                    if usesDesktopComposer {
                        HStack(alignment: .bottom, spacing: sp.s) {
                            ComposerAddMenu(
                                viewModel: viewModel,
                                supportsReasoningEffort: selectedModelSupportsReasoningEffort
                            )

                            desktopComposerInputSurface

                            MobileComposerCircleButton(
                                symbol: trailingActionSymbol,
                                foregroundColor: trailingActionForegroundColor,
                                fillColor: c.surfaceRaised,
                                action: handleTrailingAction
                            )
                            .accessibilityLabel(trailingActionLabel)
                            .help(trailingActionLabel)
                        }
                    } else {
#if !os(macOS)
                        mobileComposer
#endif
                    }
                }
            }
            .frame(minHeight: currentPanelHeight, alignment: .bottom)
        }
        .environment(viewModel)
        .padding(.horizontal, sp.s)
        .frame(
            minWidth: 0,
            maxWidth: .infinity,
            minHeight: currentPanelHeight,
            alignment: .leading
        )
        .frame(maxWidth: maximumPanelWidth)
        .overlay(alignment: .top) {
            if !viewModel.composerSuggestions.isEmpty {
                ComposerSuggestionsView(
                    suggestions: viewModel.composerSuggestions,
                    selectedSuggestionID: viewModel.composerSuggestionSelection.selectedID,
                    select: viewModel.applyComposerSuggestion
                )
                .offset(y: -(ComposerSuggestionsView.panelHeight + autocompleteGap))
            }
        }
        .disabled(viewModel.activeInputRequest != nil)
        .accessibilityHint(
            viewModel.activeInputRequest == nil
                ? ""
                : "Answer the agent’s question before sending another message."
        )
        .onDisappear { viewModel.updateMobileComposerExpansion(false) }
        .animation(
            reduceMotion ? nil : .spring(duration: 0.32, bounce: 0.08),
            value: viewModel.isMobileComposerExpanded
        )
    }

    private var maximumPanelWidth: CGFloat {
        usesDesktopComposer ? Self.desktopPanelWidth : Self.panelWidth
    }

    private var desktopComposerInputSurface: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !viewModel.composerQuotes.isEmpty {
                ChatComposerQuoteStrip(
                    quotes: viewModel.composerQuotes,
                    update: viewModel.updateComposerQuote,
                    remove: viewModel.removeComposerQuote
                )
                .padding(.horizontal, theme.spacing.s)
                .padding(.top, theme.spacing.s)
            }

            if !viewModel.composerAttachments.isEmpty {
                ChatComposerAttachmentStrip(
                    attachments: viewModel.composerAttachments,
                    annotate: { imageToAnnotate = $0 },
                    remove: viewModel.removeComposerAttachment
                )
                .frame(height: Self.attachmentStripHeight)
                .padding(.horizontal, theme.spacing.s)
                .padding(.top, theme.spacing.s)
            }

            HStack(alignment: .bottom, spacing: 0) {
                ChatTextField(
                    draft: draft,
                    submit: submit
                )

                HStack(spacing: theme.spacing.s) {
                    ComposerContextUsageView(usage: viewModel.contextUsage)

                    ComposerOptionsMenuView(
                        selectedModelId: viewModel.selectedModelId,
                        models: viewModel.modelPickerOptions,
                        selectedEffort: viewModel.selectedReasoningEffort,
                        supportsReasoningEffort: selectedModelSupportsReasoningEffort,
                        selectedAgent: viewModel.selectedAgent,
                        agents: viewModel.agents,
                        onSelectModel: viewModel.pickModel,
                        onSelectEffort: viewModel.pickReasoningEffort,
                        onSelectAgent: viewModel.pickAgent,
                        onRefreshModels: viewModel.refreshAvailableModels,
                        onEditModels: { viewModel.openSettings(.providers) }
                    )
                }
                .fixedSize(horizontal: true, vertical: false)
                .padding(.trailing, theme.spacing.s)
                .padding(.bottom, theme.spacing.s)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.panelRadius, style: .continuous))
        .glassEffect(
            .regular,
            in: RoundedRectangle(cornerRadius: Self.panelRadius, style: .continuous)
        )
    }

    #if !os(macOS)
    private var mobileComposer: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isExpandedPhoneLayout {
                Button {
                    viewModel.dismissComposerFocus()
                } label: {
                    Capsule()
                        .fill(theme.colors.textMuted.opacity(0.35 as CGFloat))
                        .frame(width: 36, height: 5)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Collapse composer")
                .simultaneousGesture(phoneTabGesture)

                HStack(spacing: theme.spacing.m) {
                    MobileComposerAgentPicker(
                        selectedAgent: viewModel.selectedAgent,
                        agents: viewModel.agents,
                        selectedProjectID: viewModel.activeProjectIdForWorkspacePanel,
                        selectedProjectName: viewModel.activeProjectNameForWorkspacePanel,
                        projects: viewModel.projects,
                        onSelectAgent: viewModel.pickAgent,
                        onSelectProject: viewModel.pickProject,
                        onSelectPersonal: viewModel.pickPersonal
                    )
                    MobileComposerServerPicker(endpoint: viewModel.sessionEndpoint)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, theme.spacing.m)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack(spacing: theme.spacing.s) {
                if !isExpandedPhoneLayout {
                    composerAddMenu
                }

                textFieldContainer(showsGlassBackground: false)
                    .frame(
                        minHeight: Self.phoneFieldHeight,
                        maxHeight: isExpandedPhoneLayout ? .infinity : Self.phoneFieldHeight,
                        alignment: .top
                    )

                if !isExpandedPhoneLayout {
                    trailingActionButton
                }
            }
            .padding(.horizontal, isExpandedPhoneLayout ? theme.spacing.m : theme.spacing.s)

            if isExpandedPhoneLayout {
                HStack(spacing: theme.spacing.s) {
                    composerAddMenu

                    MobileComposerModelPicker(
                        selectedModelId: viewModel.selectedModelId,
                        models: viewModel.modelPickerOptions,
                        selectedEffort: viewModel.selectedReasoningEffort,
                        supportsReasoningEffort: selectedModelSupportsReasoningEffort,
                        onSelectModel: viewModel.pickModel,
                        onSelectEffort: viewModel.pickReasoningEffort
                    )

                    Spacer(minLength: 0)

                    trailingActionButton
                }
                .padding(theme.spacing.s)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(height: currentPanelHeight)
        .highPriorityGesture(phoneTabGesture, including: tabActions != nil || isExpandedPhoneLayout ? .all : .subviews)
        .background(
            theme.colors.surfaceRaised.opacity(0.65 as CGFloat),
            in: RoundedRectangle(cornerRadius: isExpandedPhoneLayout ? Self.expandedPhonePanelRadius : Self.phonePanelHeight / 2)
        )
        .backportGlassEffect(
            .regular.tint(theme.colors.surfaceRaised.opacity(0.3 as CGFloat)).interactive(),
            in: RoundedRectangle(
                cornerRadius: isExpandedPhoneLayout ? Self.expandedPhonePanelRadius : Self.phonePanelHeight / 2,
                style: .continuous
            )
        )
        .accessibilityIdentifier(
            isExpandedPhoneLayout
                ? "chat.composer.expanded"
                : "chat.composer.compact"
        )
    }

    private var composerAddMenu: some View {
        ComposerAddMenu(
            viewModel: viewModel,
            supportsReasoningEffort: selectedModelSupportsReasoningEffort,
            tabActions: tabActions
        )
    }

    private var trailingActionButton: some View {
        MobileComposerCircleButton(
            symbol: trailingActionSymbol,
            foregroundColor: trailingActionForegroundColor,
            fillColor: theme.colors.surfaceRaised,
            action: handleTrailingAction
        )
        .accessibilityLabel(trailingActionLabel)
        .help(trailingActionLabel)
    }
    #endif

    @ViewBuilder
    private func textFieldContainer(showsGlassBackground: Bool) -> some View {
        let field = ChatTextField(
            draft: draft,
            submit: submit,
            onFocusChanged: updatePhoneComposerExpansion
        )
        if showsGlassBackground {
            field.backportGlassEffect(.regular.interactive(), in: Capsule())
        } else {
            field
        }
    }

    private var currentPanelHeight: CGFloat {
        if isExpandedPhoneLayout {
            return viewModel.isMobileComposerFullscreen
                ? max(Self.expandedPhonePanelHeight, mobileComposerAvailableHeight)
                : Self.expandedPhonePanelHeight
        }
        return Self.panelHeight(for: idiom)
    }

    private var isExpandedPhoneLayout: Bool {
        idiom == .phone && viewModel.isMobileComposerExpanded
    }

    private func updatePhoneComposerExpansion(_ isFocused: Bool) {
        guard idiom == .phone else { return }
        viewModel.updateMobileComposerExpansion(isFocused)
    }

    private var trimmedDraftText: String {
        draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trailingActionSymbol: MaterialSymbol {
        if !trimmedDraftText.isEmpty || !viewModel.composerAttachments.isEmpty
            || !viewModel.composerQuotes.isEmpty {
            return viewModel.willQueueMessage ? .timer : .arrowUpward
        }

        return viewModel.shouldShowStopButton ? .stop : .microphone
    }

    private var trailingActionLabel: String {
        if !trimmedDraftText.isEmpty || !viewModel.composerAttachments.isEmpty
            || !viewModel.composerQuotes.isEmpty {
            return viewModel.willQueueMessage ? "Queue message after current turn" : "Send message"
        }
        return viewModel.shouldShowStopButton ? "Stop agent" : "Start dictation"
    }

    private var trailingActionForegroundColor: Color {
        if viewModel.shouldShowStopButton,
           trimmedDraftText.isEmpty,
           viewModel.composerAttachments.isEmpty,
           viewModel.composerQuotes.isEmpty {
            return theme.colors.textPrimary
        }

        if trimmedDraftText.isEmpty {
            return theme.colors.textPrimary
        }

        return !viewModel.canSubmitMessage
            ? theme.colors.textMuted
            : theme.colors.textPrimary
    }

    private var selectedModelSupportsReasoningEffort: Bool {
        guard let selectedModel = viewModel.availableModels.first(where: { $0.id == viewModel.selectedModelId }) else {
            return false
        }
        return selectedModel.supportsReasoningEffort
    }
    
    public static func panelHeight(for idiom: UserInterfaceIdiom) -> CGFloat {
        idiom == .phone ? phonePanelHeight : panelHeight
    }

    private var phoneTabGesture: some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                guard !isExpandedPhoneLayout, tabActions != nil else { return }
                let horizontal = value.translation.width
                let vertical = value.translation.height
                let isOverviewGesture = vertical < 0 && abs(vertical) > abs(horizontal)

                guard isOverviewGesture else {
                    if isOverviewGestureActive {
                        tabActions?.updateOverviewGesture(0)
                    }
                    return
                }

                if !isOverviewGestureActive {
                    isOverviewGestureActive = true
                    tabActions?.beginOverviewGesture()
                }

                let progress = (-vertical / Self.overviewGestureDistance).clamp(0, 1)
                tabActions?.updateOverviewGesture(progress)
            }
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height

                if isExpandedPhoneLayout {
                    if vertical < -40, abs(vertical) > abs(horizontal) {
                        viewModel.expandMobileComposerFullscreen()
                    } else if vertical > 40, vertical > abs(horizontal) {
                        viewModel.dismissComposerFocus()
                    }
                    return
                }

                if isOverviewGestureActive {
                    let progress = (-vertical / Self.overviewGestureDistance).clamp(0, 1)
                    let velocity = -(value.predictedEndTranslation.height - value.translation.height)
                    tabActions?.endOverviewGesture(progress, velocity)
                    isOverviewGestureActive = false
                } else if vertical < -56, abs(vertical) > abs(horizontal) {
                    tabActions?.showOverview()
                } else if vertical > 40, vertical > abs(horizontal), isExpandedPhoneLayout {
                    viewModel.dismissComposerFocus()
                } else if abs(horizontal) > 56, abs(horizontal) > abs(vertical) {
                    tabActions?.selectAdjacentTab(horizontal < 0 ? 1 : -1)
                }
            }
    }
    
    private func submit() {
        let trimmed = trimmedDraftText
        guard (!trimmed.isEmpty || !viewModel.composerAttachments.isEmpty
            || !viewModel.composerQuotes.isEmpty), viewModel.canSubmitMessage else { return }
        if viewModel.sendMessage(content: trimmed) {
            connectionActions?.didSubmit(viewModel)
        }
    }

    private func handleTrailingAction() {
        guard viewModel.activeInputRequest == nil else { return }
        let hasMessage = !trimmedDraftText.isEmpty || !viewModel.composerAttachments.isEmpty
            || !viewModel.composerQuotes.isEmpty
        if hasMessage {
            submit()
        } else if viewModel.shouldShowStopButton {
            viewModel.stopActiveRun()
        } else {
            viewModel.startDictation()
        }
    }
}

public struct ChatComposerTabActions {
    public let tabProgress: @MainActor (CGFloat) -> Void
    public let showOverview: @MainActor () -> Void
    public let beginOverviewGesture: @MainActor () -> Void
    public let updateOverviewGesture: @MainActor (CGFloat) -> Void
    public let endOverviewGesture: @MainActor (CGFloat, CGFloat) -> Void
    public let createTab: @MainActor () -> Void
    public let selectAdjacentTab: @MainActor (Int) -> Void

    public init(
        tabProgress: @escaping @MainActor (CGFloat) -> Void,
        showOverview: @escaping @MainActor () -> Void,
        beginOverviewGesture: @escaping @MainActor () -> Void = {},
        updateOverviewGesture: @escaping @MainActor (CGFloat) -> Void = { _ in },
        endOverviewGesture: @escaping @MainActor (CGFloat, CGFloat) -> Void = { _, _ in },
        createTab: @escaping @MainActor () -> Void,
        selectAdjacentTab: @escaping @MainActor (Int) -> Void = { _ in }
    ) {
        self.tabProgress = tabProgress
        self.showOverview = showOverview
        self.beginOverviewGesture = beginOverviewGesture
        self.updateOverviewGesture = updateOverviewGesture
        self.endOverviewGesture = endOverviewGesture
        self.createTab = createTab
        self.selectAdjacentTab = selectAdjacentTab
    }
}

public struct ChatAgentToolbarMenu: View {
    public let selectedAgent: APIAgentRecord?
    public let agents: [APIAgentRecord]
    public let onSelectAgent: (APIAgentRecord) -> Void

    @Environment(\.theme) private var theme

    public init(
        selectedAgent: APIAgentRecord?,
        agents: [APIAgentRecord],
        onSelectAgent: @escaping (APIAgentRecord) -> Void
    ) {
        self.selectedAgent = selectedAgent
        self.agents = agents
        self.onSelectAgent = onSelectAgent
    }

    public var body: some View {
        Menu {
            Section("Agent") {
                if agents.isEmpty {
                    ComposerMenuItem(title: "No agents", isSelected: false)
                } else {
                    ForEach(agents) { agent in
                        Button {
                            onSelectAgent(agent)
                        } label: {
                            ComposerMenuItem(
                                title: agent.displayName,
                                isSelected: selectedAgent?.id == agent.id
                            )
                        }
                    }
                }
            }
        } label: {
            Label {
                Text(selectedAgent?.displayName ?? "Agent")
            } icon: {
                AgentBotAvatar(agentID: selectedAgent?.id ?? "sloppy", size: 22, paletteID: selectedAgent?.pet?.visual?.paletteId)
            }
                .disabled(agents.isEmpty)
                .labelStyle(.titleOnly)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }
}

#Preview {
    ChatAgentToolbarMenu(
        selectedAgent: .init(
            id: "",
            displayName: "Anton"
        ),
        agents: [],
        onSelectAgent: { _ in }
    )
}

public struct ChatModelToolbarMenu: View {
    public let selectedModelId: String
    public let models: [ChatModelOption]
    public let onSelectModel: (ChatModelOption) -> Void

    public init(
        selectedModelId: String,
        models: [ChatModelOption],
        onSelectModel: @escaping (ChatModelOption) -> Void
    ) {
        self.selectedModelId = selectedModelId
        self.models = models
        self.onSelectModel = onSelectModel
    }

    public var body: some View {
        Menu {
            Section("Model") {
                if models.isEmpty {
                    ComposerMenuItem(title: "No models", isSelected: false)
                } else {
                    ForEach(models) { model in
                        Button {
                            onSelectModel(model)
                        } label: {
                            ComposerMenuItem(
                                title: model.title,
                                subtitle: model.id == model.title ? nil : model.id,
                                isSelected: selectedModelId == model.id
                            )
                        }
                    }
                }
            }
        } label: {
            Label(selectedModelTitle, systemImage: "brain")
                .disabled(models.isEmpty)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }

    private var selectedModelTitle: String {
        guard let selected = models.first(where: { $0.id == selectedModelId }) else {
            return selectedModelId.isEmpty ? "Model" : selectedModelId
        }
        return selected.title
    }
}

public struct ChatContextToolbarMenu: View {
    public let selectedAgent: APIAgentRecord?
    public let agents: [APIAgentRecord]
    public let selectedModelId: String
    public let models: [ChatModelOption]
    public let onSelectAgent: (APIAgentRecord) -> Void
    public let onSelectModel: (ChatModelOption) -> Void

    public init(
        selectedAgent: APIAgentRecord?,
        agents: [APIAgentRecord],
        selectedModelId: String,
        models: [ChatModelOption],
        onSelectAgent: @escaping (APIAgentRecord) -> Void,
        onSelectModel: @escaping (ChatModelOption) -> Void
    ) {
        self.selectedAgent = selectedAgent
        self.agents = agents
        self.selectedModelId = selectedModelId
        self.models = models
        self.onSelectAgent = onSelectAgent
        self.onSelectModel = onSelectModel
    }

    public var body: some View {
        Menu {
            Section("Agent") {
                if agents.isEmpty {
                    ComposerMenuItem(title: "No agents", isSelected: false)
                } else {
                    ForEach(agents) { agent in
                        Button {
                            onSelectAgent(agent)
                        } label: {
                            ComposerMenuItem(
                                title: agent.displayName,
                                isSelected: selectedAgent?.id == agent.id
                            )
                        }
                    }
                }
            }

            Section("Model") {
                if models.isEmpty {
                    ComposerMenuItem(title: "No models", isSelected: false)
                } else {
                    ForEach(models) { model in
                        Button {
                            onSelectModel(model)
                        } label: {
                            ComposerMenuItem(
                                title: model.title,
                                subtitle: model.id == model.title ? nil : model.id,
                                isSelected: selectedModelId == model.id
                            )
                        }
                    }
                }
            }
        } label: {
            Label(selectedAgent?.displayName ?? "Agent", systemImage: "brain")
                .lineLimit(1)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .help("Agent and model")
        .accessibilityLabel("Agent and model")
    }
}

private struct ComposerContextUsageView: View {
    let usage: ChatContextUsage?

    @State private var isDetailsPresented = false
    @Environment(\.theme) private var theme

    var body: some View {
        ProgressView(value: usage?.fraction ?? 0, total: 1)
            .progressViewStyle(.circular)
            .controlSize(.small)
            .tint(progressColor)
            .frame(width: 20, height: 20)
            .contentShape(Circle())
            .onHover { isHovering in
                isDetailsPresented = isHovering && usage != nil
            }
            .popover(isPresented: $isDetailsPresented, arrowEdge: .bottom) {
                if let usage {
                    contextDetails(usage)
                }
            }
            .accessibilityLabel("Context usage")
            .accessibilityValue(accessibilityValue)
            .accessibilityIdentifier("chat.composer.context-usage")
    }

    private var progressColor: Color {
        guard let usage else { return theme.colors.statusNeutral }
        if usage.fraction >= 0.9 {
            return theme.colors.statusBlocked
        }
        if usage.fraction >= 0.75 {
            return theme.colors.statusWarning
        }
        return theme.colors.textSecondary
    }

    private var accessibilityValue: String {
        guard let usage else { return "Unavailable" }
        var value = "\(usage.percentage) percent, \(usage.usedTokens) of \(usage.limitTokens) tokens"
        if let jev = usage.semanticDecisionUsage {
            value += ", routing \(jev.requestCount) decisions, \(formattedJEVCost(jev))"
        }
        return value
    }

    private func contextDetails(_ usage: ChatContextUsage) -> some View {
        VStack(alignment: .leading, spacing: theme.spacing.s) {
            Text("Context usage")
                .font(.system(size: theme.typography.body, weight: .semibold))
                .foregroundColor(theme.colors.textPrimary)

            Text("\(usage.percentage)%")
                .font(.system(size: theme.typography.title, weight: .semibold, design: .rounded))
                .foregroundColor(progressColor)
                .monospacedDigit()

            Grid(alignment: .leading, horizontalSpacing: theme.spacing.l, verticalSpacing: theme.spacing.xs) {
                GridRow {
                    Text("Used")
                        .foregroundColor(theme.colors.textMuted)
                    Text(usage.usedTokens.formatted(.number.grouping(.automatic)))
                        .foregroundColor(theme.colors.textPrimary)
                        .monospacedDigit()
                }
                GridRow {
                    Text("Limit")
                        .foregroundColor(theme.colors.textMuted)
                    Text(usage.limitTokens.formatted(.number.grouping(.automatic)))
                        .foregroundColor(theme.colors.textPrimary)
                        .monospacedDigit()
                }
            }
            .font(.system(size: theme.typography.caption))

            if let jev = usage.semanticDecisionUsage {
                Divider()

                Text("Routing usage")
                    .font(.system(size: theme.typography.caption, weight: .semibold))
                    .foregroundColor(theme.colors.textSecondary)

                Grid(alignment: .leading, horizontalSpacing: theme.spacing.l, verticalSpacing: theme.spacing.xs) {
                    GridRow {
                        Text("Decisions")
                            .foregroundColor(theme.colors.textMuted)
                        Text(jev.requestCount.formatted(.number.grouping(.automatic)))
                            .foregroundColor(theme.colors.textPrimary)
                            .monospacedDigit()
                    }
                    GridRow {
                        Text("Input")
                            .foregroundColor(theme.colors.textMuted)
                        Text("\(jev.inputTokens.formatted(.number.grouping(.automatic))) tokens")
                            .foregroundColor(theme.colors.textPrimary)
                            .monospacedDigit()
                    }
                    GridRow {
                        Text("Cost")
                            .foregroundColor(theme.colors.textMuted)
                        Text(formattedJEVCost(jev))
                            .foregroundColor(theme.colors.textPrimary)
                            .monospacedDigit()
                    }
                }
                .font(.system(size: theme.typography.caption))
            }
        }
        .padding(theme.spacing.m)
        .frame(minWidth: 210, alignment: .leading)
    }

    private func formattedJEVCost(_ usage: ChatSemanticDecisionUsage) -> String {
        let prefix = usage.includesEstimatedCost ? "~" : ""
        let amount = usage.totalCostUSD
        if amount > 0, amount < 0.01 {
            return prefix + String(format: "$%.4f", amount)
        }
        return prefix + String(format: "$%.2f", amount)
    }
}

private struct ComposerOptionsMenuView: View {
    let selectedModelId: String
    let models: [ChatModelOption]
    let selectedEffort: ChatReasoningEffort
    let supportsReasoningEffort: Bool
    let selectedAgent: APIAgentRecord?
    let agents: [APIAgentRecord]
    let onSelectModel: (ChatModelOption) -> Void
    let onSelectEffort: (ChatReasoningEffort) -> Void
    let onSelectAgent: (APIAgentRecord) -> Void
    let onRefreshModels: @MainActor () async -> Void
    let onEditModels: @MainActor () -> Void

    @State private var isPresented = false
    @State private var isModelPickerPresented = false
    @State private var searchText = ""
    @State private var isRefreshing = false
    @FocusState private var isSearchFocused: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        Button {
            isModelPickerPresented = !supportsReasoningEffort
            isPresented.toggle()
        } label: {
            HStack(spacing: theme.spacing.xs) {
                Text(selectedModelTitle)
                    .font(.system(size: theme.typography.body, weight: .medium))
                    .foregroundColor(theme.colors.textPrimary)
                    .lineLimit(1)

                if supportsReasoningEffort {
                    Text("· \(selectedEffort.title)")
                        .font(.system(size: theme.typography.caption, weight: .medium))
                        .foregroundColor(theme.colors.textSecondary)
                        .lineLimit(1)
                }

                Icons.symbol(.expandMore, size: 14)
                    .foregroundColor(theme.colors.textSecondary)
            }
            .padding(.horizontal, theme.spacing.s)
            .frame(height: Constants.modelPickerRowHeight)
        }
        .buttonStyle(.plain)
        .help("Model · \(selectedModelId)")
        .accessibilityLabel("Model \(selectedModelTitle), reasoning \(selectedEffort.title)")
        .accessibilityIdentifier("chat.composer.model-picker")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            pickerContent
                .presentationCompactAdaptation(.popover)
        }
    }

    private var selectedModelTitle: String {
        guard let selected = models.first(where: { $0.id == selectedModelId }) else {
            return selectedModelId.isEmpty ? "Model" : selectedModelId
        }
        return selected.title
    }

    private var filteredModels: [ChatModelOption] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return models
        }
        return models.filter {
            $0.title.localizedStandardContains(query) || $0.id.localizedStandardContains(query)
        }
    }

    private var groupedModels: [ComposerModelGroup] {
        var groups: [ComposerModelGroup] = []
        for model in filteredModels {
            let provider = providerTitle(for: model.id)
            if let index = groups.firstIndex(where: { $0.title == provider }) {
                groups[index].models.append(model)
            } else {
                groups.append(ComposerModelGroup(title: provider, models: [model]))
            }
        }
        return groups
    }

    private var pickerContent: some View {
        Group {
            if isModelPickerPresented {
                modelPickerContent
            } else {
                effortPickerContent
            }
        }
        .frame(width: isModelPickerPresented ? 440 : 360)
    }

    private var effortPickerContent: some View {
        VStack(spacing: 12) {
            ZStack {
                Button {
                    isModelPickerPresented = true
                } label: {
                    VStack(spacing: theme.spacing.xs) {
                        HStack(spacing: theme.spacing.xs) {
                            Text(selectedEffort.title)
                                .font(.system(size: theme.typography.heading, weight: .medium))
                                .foregroundColor(
                                    ComposerEffortPalette.color(for: selectedEffort, theme: theme)
                                )
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(theme.colors.textMuted)
                        }

                        Text(selectedModelTitle)
                            .font(.system(size: theme.typography.body))
                            .foregroundColor(theme.colors.textSecondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(models.isEmpty)
                .accessibilityLabel("Select model, current model \(selectedModelTitle)")

                HStack {
                    Spacer(minLength: 0)

                    Button {
                        onSelectEffort(.default)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(theme.colors.textMuted)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedEffort == .default)
                    .help("Reset effort to Default")
                    .accessibilityLabel("Reset effort to Default")
                }
            }

            ComposerEffortScale(
                selection: selectedEffort,
                onSelect: onSelectEffort
            )
            .disabled(!supportsReasoningEffort)

            if !agents.isEmpty {
                Divider()
                agentPicker
            }
        }
        .padding(.horizontal, theme.spacing.m)
        .padding(.vertical, 14)
        .accessibilityIdentifier("chat.composer.effort-picker")
    }

    private var modelPickerContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: theme.spacing.s) {
                Button {
                    if supportsReasoningEffort {
                        isModelPickerPresented = false
                    } else {
                        isPresented = false
                    }
                } label: {
                    Image(systemName: supportsReasoningEffort ? "chevron.left" : "xmark")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.colors.textSecondary)

                Text("Select model")
                    .font(.system(size: theme.typography.heading + 2, weight: .semibold))
                    .foregroundColor(theme.colors.textPrimary)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, theme.spacing.m)
            .frame(height: 50)

            HStack(spacing: theme.spacing.s) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(theme.colors.textMuted)
                TextField("Search models", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
            }
            .padding(.horizontal, theme.spacing.m)
            .frame(height: 46)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: theme.spacing.xs) {
                    if groupedModels.isEmpty {
                        Text(models.isEmpty ? "No models available" : "No matching models")
                            .font(.system(size: theme.typography.caption))
                            .foregroundColor(theme.colors.textMuted)
                            .frame(maxWidth: .infinity, minHeight: 90)
                    } else {
                        ForEach(groupedModels) { group in
                            Text(group.title)
                                .font(.system(size: theme.typography.caption, weight: .semibold))
                                .foregroundColor(theme.colors.textMuted)
                                .padding(.horizontal, theme.spacing.m)
                                .padding(.top, theme.spacing.s)

                            ForEach(group.models) { model in
                                modelRow(model)
                            }
                        }
                    }
                }
                .padding(.vertical, theme.spacing.s)
            }
            .frame(minHeight: 160, maxHeight: 380)

            Divider()
            modelPickerActions
        }
        .onAppear {
            searchText = ""
            isSearchFocused = true
        }
        .accessibilityIdentifier("chat.composer.model-list")
    }

    private func modelRow(_ model: ChatModelOption) -> some View {
        Button {
            onSelectModel(model)
            if model.supportsReasoningEffort {
                isModelPickerPresented = false
            } else {
                isPresented = false
            }
        } label: {
            HStack(spacing: theme.spacing.s) {
                Text(model.title)
                    .foregroundColor(theme.colors.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: theme.spacing.s)
                if selectedModelId == model.id {
                    Image(systemName: "checkmark")
                        .foregroundColor(theme.colors.textPrimary)
                }
            }
            .padding(.horizontal, theme.spacing.m)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                selectedModelId == model.id
                    ? theme.colors.accent.opacity(0.14 as CGFloat)
                    : Color.clear
            )
        }
        .buttonStyle(.plain)
    }

    private var modelPickerActions: some View {
        HStack(spacing: theme.spacing.s) {
            Button {
                Task {
                    isRefreshing = true
                    await onRefreshModels()
                    isRefreshing = false
                }
            } label: {
                Label(
                    isRefreshing ? "Refreshing…" : "Refresh",
                    systemImage: "arrow.clockwise"
                )
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing)

            Spacer(minLength: 0)

            Button {
                isPresented = false
                onEditModels()
            } label: {
                Label("Edit Models…", systemImage: "gearshape")
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: theme.typography.caption, weight: .medium))
        .foregroundColor(theme.colors.textSecondary)
        .padding(.horizontal, theme.spacing.m)
        .frame(height: 46)
    }

    private var agentPicker: some View {
        Menu {
            ForEach(agents) { agent in
                Button {
                    onSelectAgent(agent)
                } label: {
                    ComposerMenuItem(
                        title: agent.displayName,
                        isSelected: selectedAgent?.id == agent.id
                    )
                }
            }
        } label: {
            HStack(spacing: theme.spacing.s) {
                Image(systemName: "person")
                    .frame(width: 20)
                Text(selectedAgent?.displayName ?? "Agent")
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(theme.colors.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .menuStyle(.button)
        .buttonStyle(.plain)
    }

    private func providerTitle(for modelID: String) -> String {
        let rawProvider = modelID.split(whereSeparator: { $0 == ":" || $0 == "/" }).first.map(String.init) ?? "Models"
        return rawProvider
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .uppercased()
    }
}

private struct ComposerEffortScale: View {
    let selection: ChatReasoningEffort
    let onSelect: (ChatReasoningEffort) -> Void

    @Environment(\.theme) private var theme

    private let height: CGFloat = 36
    private let thumbSize: CGFloat = 24
    private let dotSize: CGFloat = 6
    private let fillTrailingSpacing: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            let efforts = ChatReasoningEffort.allCases
            let segmentWidth = proxy.size.width / CGFloat(efforts.count)
            let selectedIndex = efforts.firstIndex(of: selection) ?? 0
            let thumbCenter = segmentWidth * (CGFloat(selectedIndex) + 0.5)
            let isMaximumEffort = selectedIndex == efforts.count - 1
            let fillWidth = isMaximumEffort
                ? proxy.size.width
                : min(
                    proxy.size.width,
                    thumbCenter + thumbSize / 2 + fillTrailingSpacing
                )
            let levelColor = ComposerEffortPalette.color(for: selection, theme: theme)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.colors.surfaceRaised)

                Capsule()
                    .fill(levelColor)
                    .frame(width: fillWidth)

                HStack(spacing: 0) {
                    ForEach(Array(efforts.enumerated()), id: \.element.id) { index, effort in
                        ZStack {
                            Circle()
                                .fill(index < selectedIndex ? Color.white.opacity(0.36) : theme.colors.textMuted)
                                .frame(width: dotSize, height: dotSize)

                            if effort == selection {
                                Circle()
                                    .fill(Color.white)
                                    .frame(width: thumbSize, height: thumbSize)
                                    .shadow(color: Color.black.opacity(0.18), radius: 2, y: 1)
                            }
                        }
                        .frame(width: segmentWidth, height: height)
                        .accessibilityHidden(true)
                    }
                }
            }
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .stroke(theme.colors.borderBold, lineWidth: theme.borders.thin)
            }
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        selectEffort(at: value.location.x, width: proxy.size.width)
                    }
                    .onEnded { value in
                        selectEffort(at: value.location.x, width: proxy.size.width)
                    }
            )
            .animation(.easeOut(duration: 0.12), value: selection)
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reasoning effort")
        .accessibilityValue(selection.title)
        .accessibilityIdentifier("chat.composer.effort-slider")
        .accessibilityAdjustableAction(adjustEffort)
    }

    private func selectEffort(at location: CGFloat, width: CGFloat) {
        guard width > 0 else { return }
        let efforts = ChatReasoningEffort.allCases
        let normalizedLocation = min(max(location / width, 0), 0.999_999)
        let index = min(Int(normalizedLocation * CGFloat(efforts.count)), efforts.count - 1)
        onSelect(efforts[index])
    }

    private func adjustEffort(_ direction: AccessibilityAdjustmentDirection) {
        let efforts = ChatReasoningEffort.allCases
        let selectedIndex = efforts.firstIndex(of: selection) ?? 0
        let nextIndex: Int
        switch direction {
        case .increment:
            nextIndex = min(selectedIndex + 1, efforts.count - 1)
        case .decrement:
            nextIndex = max(selectedIndex - 1, 0)
        @unknown default:
            return
        }
        onSelect(efforts[nextIndex])
    }
}

private enum ComposerEffortPalette {
    static func color(for effort: ChatReasoningEffort, theme: Theme) -> Color {
        switch effort {
        case .default:
            theme.colors.statusNeutral
        case .low:
            theme.colors.accentCyan
        case .medium:
            theme.colors.accent
        case .high:
            theme.colors.statusWarning
        }
    }
}

private struct ComposerModelGroup: Identifiable {
    let title: String
    var models: [ChatModelOption]

    var id: String { title }
}

private extension ChatReasoningEffort {
    var compactTitle: String {
        switch self {
        case .default: "Auto"
        case .low: "Low"
        case .medium: "Med"
        case .high: "High"
        }
    }
}

private struct ComposerMenuChip: View {
    let title: String
    var isEnabled: Bool = true

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.spacing.xs) {
            Text(title)
                .font(.system(size: theme.typography.body, weight: .semibold))
                .foregroundColor(theme.colors.textPrimary.opacity(isEnabled ? 1 : 0.48))
                .lineLimit(1)

            Icons.symbol(.expandMore, size: 14)
                .foregroundColor(theme.colors.textSecondary.opacity(isEnabled ? 1 : 0.48))
        }
    }
}

#if !os(macOS)
private struct MobileComposerAgentPicker: View {
    let selectedAgent: APIAgentRecord?
    let agents: [APIAgentRecord]
    let selectedProjectID: String?
    let selectedProjectName: String?
    let projects: [APIProjectRecord]
    let onSelectAgent: (APIAgentRecord) -> Void
    let onSelectProject: (APIProjectRecord) -> Void
    let onSelectPersonal: () -> Void

    var body: some View {
        Menu {
            Section("Context") {
                Button(action: onSelectPersonal) {
                    ComposerMenuItem(title: "Personal", isSelected: selectedProjectID == nil)
                }
                ForEach(projects) { project in
                    Button { onSelectProject(project) } label: {
                        ComposerMenuItem(title: project.name, isSelected: selectedProjectID == project.id)
                    }
                }
            }
            Section("Agent") {
                ForEach(agents) { agent in
                    Button { onSelectAgent(agent) } label: {
                        ComposerMenuItem(title: agent.displayName, isSelected: selectedAgent?.id == agent.id)
                    }
                }
            }
        } label: {
            ComposerMenuChip(title: contextTitle, isEnabled: true)
                .frame(minHeight: 32)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Chat context \(contextTitle)")
        .accessibilityIdentifier("chat.composer.agent-picker")
    }

    private var contextTitle: String {
        guard let selectedProjectName else { return selectedAgent?.displayName ?? "Personal" }
        guard let selectedAgent, selectedAgent.displayName != selectedProjectName else { return selectedProjectName }
        return "\(selectedProjectName) \(selectedAgent.displayName)"
    }
}

private struct MobileComposerServerPicker: View {
    let endpoint: SloppyInstanceEndpoint
    @Environment(\.chatComposerConnectionActions) private var actions
    @Environment(\.theme) private var theme

    var body: some View {
        Menu {
            ForEach(actions?.instances ?? []) { instance in
                Button { actions?.selectInstance(instance) } label: {
                    ComposerMenuItem(title: instance.displayName, isSelected: instance.endpoint == endpoint)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "cloud")
                ComposerMenuChip(title: serverTitle, isEnabled: !(actions?.instances.isEmpty ?? true))
            }
            .foregroundColor(theme.colors.textSecondary)
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .disabled(actions?.instances.isEmpty ?? true)
        .accessibilityLabel("Server \(serverTitle)")
        .accessibilityIdentifier("chat.composer.server-picker")
    }

    private var serverTitle: String {
        actions?.instances.first(where: { $0.endpoint == endpoint })?.displayName
            ?? endpoint.coordinatorBaseURL.host ?? "Server"
    }
}

private struct MobileComposerModelPicker: View {
    let selectedModelId: String
    let models: [ChatModelOption]
    let selectedEffort: ChatReasoningEffort
    let supportsReasoningEffort: Bool
    let onSelectModel: (ChatModelOption) -> Void
    let onSelectEffort: (ChatReasoningEffort) -> Void

    var body: some View {
        Menu {
            Section("Model") {
                if models.isEmpty {
                    ComposerMenuItem(title: "No models", isSelected: false)
                } else {
                    ForEach(models) { model in
                        Button {
                            onSelectModel(model)
                        } label: {
                            ComposerMenuItem(
                                title: model.title,
                                subtitle: model.id == model.title ? nil : model.id,
                                isSelected: selectedModelId == model.id
                            )
                        }
                    }
                }
            }

            if supportsReasoningEffort {
                Section("Reasoning") {
                    ForEach(ChatReasoningEffort.allCases) { effort in
                        Button {
                            onSelectEffort(effort)
                        } label: {
                            ComposerMenuItem(
                                title: effort.title,
                                isSelected: selectedEffort == effort
                            )
                        }
                    }
                }
            }
        } label: {
            ComposerMenuChip(title: selectedModelTitle, isEnabled: !models.isEmpty)
                .frame(maxWidth: 180, minHeight: ChatComposerView.phoneCircleSize, alignment: .leading)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .disabled(models.isEmpty)
        .accessibilityLabel("Model \(selectedModelTitle)")
        .accessibilityIdentifier("chat.composer.model-picker")
    }

    private var selectedModelTitle: String {
        guard let selected = models.first(where: { $0.id == selectedModelId }) else {
            return selectedModelId.isEmpty ? "Model" : selectedModelId
        }
        return selected.title
    }
}
#endif

private struct ComposerMenuItem: View {
    let title: String
    var subtitle: String?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                }
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
            }
        }
    }
}

struct ChatTextField: View {
    @Bindable var draft: ChatComposerDraft
    let submit: @MainActor () -> Void
    var onFocusChanged: @MainActor (Bool) -> Void = { _ in }

    @Environment(\.allowsAutomaticComposerFocus) private var allowsAutomaticComposerFocus
    @State private var isTextFieldFocused = false
    @State private var composerCursorOffset: Int?
    @State private var editorHeight = Constants.editorMinimumHeight
    @Environment(\.userInterfaceIdiom) private var idiom
    @Environment(\.theme) private var theme
    @Environment(ChatScreenViewModel.self) private var viewModel

    private var agentDisplayName: String {
        return viewModel.selectedAgent?.displayName ?? "Sloppy"
    }

    var body: some View {
        let c = theme.colors
        let sp = theme.spacing
        let ty = theme.typography
        let fieldInk = c.textPrimary

        return nativeTextEditor(
            fontSize: idiom == .phone ? 17 : ty.body,
            primaryColor: fieldInk,
            placeholderColor: c.textMuted,
            commandColor: c.accentCyan,
            mentionColor: c.accent,
            tagColor: c.accentAcid
        )
            .frame(height: editorHeight)
            .padding(.horizontal, idiom == .phone ? 0 : Constants.fieldHorizontalPadding)
            .padding(.vertical, sp.s)
            .frame(
                minWidth: 0, maxWidth: .infinity, minHeight: Constants.fieldHeight,
                alignment: .leading
            )
            .contentShape(Rectangle())
            #if os(macOS)
            .pointerStyle(.horizontalText)
            #endif
            .clipped()
            .layoutPriority(1)
            .onChange(of: viewModel.composerFocusResetToken) { _, _ in
                isTextFieldFocused = false
            }
            .task(id: viewModel.composerFocusRequestToken) {
                guard allowsAutomaticComposerFocus, viewModel.composerFocusRequestToken > 0 else {
                    return
                }
                await Task.yield()
                isTextFieldFocused = true
            }
            .onChange(of: isTextFieldFocused) { _, isFocused in
                onFocusChanged(isFocused)
            }
            .onChange(of: draft.text) { oldValue, newValue in
                let cursorOffset = composerCursorOffset
                    ?? ChatComposerTextEdit.cursorOffsetAfterEdit(
                        from: oldValue,
                        to: newValue
                    )
                composerCursorOffset = nil
                viewModel.updateComposerSuggestions(
                    for: newValue,
                    cursorOffset: cursorOffset
                )
            }
    }

    @ViewBuilder
    private func nativeTextEditor(
        fontSize: CGFloat,
        primaryColor: Color,
        placeholderColor: Color,
        commandColor: Color,
        mentionColor: Color,
        tagColor: Color
    ) -> some View {
        #if os(macOS)
        AppKitChatComposerTextEditor(
            text: $draft.text,
            selection: $draft.selection,
            isFocused: $isTextFieldFocused,
            measuredHeight: $editorHeight,
            placeholder: idiom == .phone ? "Plan, ask, build…" : "Ask \(agentDisplayName)",
            fontSize: fontSize,
            primaryColor: primaryColor,
            placeholderColor: placeholderColor,
            commandColor: commandColor,
            mentionColor: mentionColor,
            tagColor: tagColor,
            codeBackgroundColor: theme.colors.accentCyan.opacity(0.12),
            maximumVisibleLines: Constants.maximumVisibleLines,
            textContainerInset: CGSize(
                width: Constants.editorContentHorizontalInset,
                height: Constants.editorContentVerticalInset
            ),
            lineFragmentPadding: Constants.editorNativeTextContainerInset,
            cursorOffsetChanged: { composerCursorOffset = $0 },
            moveSuggestionSelection: viewModel.moveComposerSuggestionSelection,
            applySelectedSuggestion: viewModel.applySelectedComposerSuggestion,
            submit: submit,
            pasteAttachment: pasteAttachmentsFromSystemPasteboard
        )
        #else
        UIKitChatComposerTextEditor(
            text: $draft.text,
            selection: $draft.selection,
            isFocused: $isTextFieldFocused,
            measuredHeight: $editorHeight,
            placeholder: idiom == .phone ? "Plan, ask, build…" : "Ask \(agentDisplayName)",
            fontSize: fontSize,
            primaryColor: primaryColor,
            placeholderColor: placeholderColor,
            commandColor: commandColor,
            mentionColor: mentionColor,
            tagColor: tagColor,
            maximumVisibleLines: Constants.maximumVisibleLines,
            textContainerInset: EdgeInsets(
                top: Constants.editorContentVerticalInset,
                leading: idiom == .phone ? 0 : Constants.editorContentHorizontalInset,
                bottom: Constants.editorContentVerticalInset,
                trailing: idiom == .phone ? 0 : Constants.editorContentHorizontalInset
            ),
            lineFragmentPadding: Constants.editorNativeTextContainerInset,
            cursorOffsetChanged: { composerCursorOffset = $0 },
            moveSuggestionSelection: viewModel.moveComposerSuggestionSelection,
            applySelectedSuggestion: viewModel.applySelectedComposerSuggestion,
            submit: submit,
            pasteItemProviders: viewModel.attachItemProviders
        )
        #endif
    }

    #if os(macOS)
    private func pasteAttachmentsFromSystemPasteboard() -> Bool {
        let pasteboard = NSPasteboard.general
        let fileObjects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) ?? []
        let fileURLs = fileObjects.compactMap {
            ($0 as? NSURL)?.filePathURL
        }

        if !fileURLs.isEmpty {
            viewModel.attachFileURLs(fileURLs)
            return true
        }

        if let pngData = pasteboard.data(forType: .png) {
            viewModel.attachData(
                pngData,
                suggestedName: "Pasted Image.png",
                mimeType: "image/png"
            )
            return true
        }

        guard let image = NSImage(pasteboard: pasteboard),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return pasteGenericAttachment(from: pasteboard)
        }

        viewModel.attachData(
            pngData,
            suggestedName: "Pasted Image.png",
            mimeType: "image/png"
        )
        return true
    }

    private func pasteGenericAttachment(from pasteboard: NSPasteboard) -> Bool {
        guard let pasteboardType = pasteboard.types?.first(where: { pasteboardType in
            guard let contentType = UTType(pasteboardType.rawValue) else { return false }
            return ChatComposerPasteboard.isAttachmentType(contentType)
        }),
        let data = pasteboard.data(forType: pasteboardType),
        let contentType = UTType(pasteboardType.rawValue) else {
            return false
        }

        let fileExtension = contentType.preferredFilenameExtension ?? "bin"
        viewModel.attachData(
            data,
            suggestedName: "Pasted Attachment.\(fileExtension)",
            mimeType: contentType.preferredMIMEType ?? "application/octet-stream"
        )
        return true
    }
    #endif
}

private struct ChatComposerAttachmentStrip: View {
    let attachments: [ChatComposerAttachment]
    let annotate: @MainActor (ChatComposerAttachment) -> Void
    let remove: @MainActor (ChatComposerAttachment.ID) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: theme.spacing.s) {
                ForEach(attachments) { attachment in
                    attachmentChip(attachment)
                }
            }
            .padding(.horizontal, theme.spacing.xs)
        }
        .scrollClipDisabled()
        .accessibilityLabel("Attachments")
    }

    private func attachmentChip(_ attachment: ChatComposerAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            Button {
                annotate(attachment)
            } label: {
                ChatComposerAttachmentPreview(attachment: attachment)
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(theme.colors.border, lineWidth: theme.borders.thin)
                    }
                    .overlay(alignment: .bottomLeading) {
                        if !attachment.annotations.isEmpty {
                            Text("\(attachment.annotations.count)")
                                .font(.caption.bold())
                                .foregroundStyle(ChatAnnotationStyle.ink)
                                .padding(6)
                                .background(ChatAnnotationStyle.mint, in: Circle())
                                .padding(6)
                        }
                    }
            }
            .buttonStyle(.plain)
            .disabled(!attachment.mimeType.hasPrefix("image/"))
            .accessibilityLabel("Annotate \(attachment.name)")
            .accessibilityIdentifier("chat.composer.attachment.\(attachment.id).annotate")

            Button {
                remove(attachment.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(
                        theme.colors.textPrimary,
                        theme.colors.surfaceRaised
                    )
            }
            .buttonStyle(.plain)
            .padding(5)
            .accessibilityLabel("Remove \(attachment.name)")
        }
    }
}

private struct ChatComposerAttachmentPreview: View {
    let attachment: ChatComposerAttachment

    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if let image = platformImage {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                VStack(spacing: theme.spacing.xs) {
                    Image(systemName: "doc")
                        .font(.system(size: 26))
                        .foregroundColor(theme.colors.accentCyan)
                    Text(attachment.name)
                        .font(.system(size: theme.typography.micro, weight: .medium))
                        .foregroundColor(theme.colors.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text(
                        ByteCountFormatter.string(
                            fromByteCount: Int64(attachment.sizeBytes),
                            countStyle: .file
                        )
                    )
                    .font(.system(size: theme.typography.micro))
                    .foregroundColor(theme.colors.textMuted)
                }
                .padding(theme.spacing.s)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.colors.surfaceRaised.opacity(0.96))
            }
        }
        .accessibilityLabel(attachment.name)
    }

    private var platformImage: Image? {
        guard attachment.mimeType.hasPrefix("image/") else {
            return nil
        }

        #if os(macOS)
        guard let image = NSImage(data: attachment.data) else {
            return nil
        }
        return Image(nsImage: image)
        #elseif canImport(UIKit)
        guard let image = UIImage(data: attachment.data) else {
            return nil
        }
        return Image(uiImage: image)
        #else
        return nil
        #endif
    }
}

private struct DictationComposerBar: View {
    let phase: ChatComposerDictationPhase
    let levels: [CGFloat]
    let elapsed: TimeInterval
    let stop: @MainActor () -> Void

    @Environment(\.theme) private var theme

    private let elapsedTextWidth: CGFloat = 64
    private let stopButtonSize: CGFloat = 32

    private var trailingControlsWidth: CGFloat {
        elapsedTextWidth + theme.spacing.s + stopButtonSize
    }

    private var isRecording: Bool {
        phase == .recording
    }

    private var elapsedText: String {
        let totalSeconds = Int(elapsed.rounded(.down))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var body: some View {
        HStack(spacing: theme.spacing.s) {
            if isRecording {
                waveformViewport
                    .scaleEffect(x: -1)
            } else {
                Spacer(minLength: 0)
            }
            trailingControls
        }
        .padding(.trailing, theme.spacing.s)
        .padding(.leading, theme.spacing.m)
        .frame(
            maxWidth: .infinity,
            minHeight: ChatComposerView.panelHeight,
            maxHeight: ChatComposerView.panelHeight
        )
        .backportGlassEffect(
            .regular.tint(Color.fromHex(0x1C1C1E)),
            in: .capsule
        )
    }

    private var waveformViewport: some View {
        Color.clear
            .frame(maxWidth: .infinity, alignment: .trailing)
            .overlay(alignment: .trailing) {
                waveformView
                    .allowsHitTesting(false)
            }
            .clipped()
    }

    @ViewBuilder
    private var trailingControls: some View {
        if isRecording {
            HStack(spacing: theme.spacing.s) {
                Text(elapsedText)
                    .font(.system(size: theme.typography.body, weight: .semibold, design: .rounded))
                    .foregroundColor(Color.fromHex(0xFF5A64))
                    .monospacedDigit()
                    .frame(width: elapsedTextWidth, alignment: .trailing)

                Button(action: stop) {
                    ZStack {
                        Circle()
                            .fill(Color.fromHex(0x8E2F35))
                        Icons.symbol(.stop, size: theme.typography.body)
                            .foregroundColor(Color.fromHex(0xFF7078))
                    }
                    .frame(
                        width: stopButtonSize,
                        height: stopButtonSize
                    )
                }
                .buttonStyle(.plain)
                
            }
            .frame(width: trailingControlsWidth, alignment: .trailing)
        } else {
            Text("Transcribing…")
                .font(.system(size: theme.typography.body, weight: .semibold))
                .foregroundColor(Color.fromHex(0xFF5A64))
        }
    }

    private var waveformView: some View {
        HStack(spacing: 3) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .fill(Color.fromHex(0xFF4D57).opacity(isRecording ? 0.92 : 0.38))
                    .frame(width: 3, height: 6 + levels[index] * 14)
            }
        }
        .animation(.easeOut(duration: 0.12), value: levels)
    }
}

extension BinaryFloatingPoint {
    func clamp(_ minValue: Self, _ maxValue: Self) -> Self {
        max(min(self, maxValue), minValue)
    }
}

private struct MobileComposerCircleButton: View {
    let symbol: MaterialSymbol
    var foregroundColor: Color = Theme.sloppyDark.colors.textPrimary
    var fillColor: Color = Color.fromHex(0x1C1C1E).opacity(0.96 as CGFloat)
    let action: @MainActor () -> Void
    
    @Environment(\.theme) private var theme

    var body: some View {
        #if os(macOS)
        Button(action: action) {
            Icons.symbol(symbol, size: theme.typography.heading)
                .foregroundColor(foregroundColor)
                .frame(
                    width: ChatComposerView.buttonSize,
                    height: ChatComposerView.buttonSize
                )
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .buttonBorderShape(.circle)
        .backportGlassEffect(.regular.interactive(), in: .circle)
        .padding(.bottom, (ChatComposerView.panelHeight - ChatComposerView.buttonSize) / 2)
        #else
        Button(action: action) {
            Icons.symbol(symbol, size: 18)
                .foregroundColor(foregroundColor)
                .frame(width: ChatComposerView.phoneCircleSize, height: ChatComposerView.phoneCircleSize)
                .background(theme.colors.textPrimary.opacity(0.10 as CGFloat), in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonBorderShape(.circle)
#if os(visionOS)
        .glassBackgroundEffect()
#else
        .buttonStyle(.plain)
#endif
        #endif
    }
}

private struct ComposerAddMenu: View {
    let viewModel: ChatScreenViewModel
    let supportsReasoningEffort: Bool

    var tabActions: ChatComposerTabActions? = nil
    @Environment(\.theme) private var theme
    @Environment(\.userInterfaceIdiom) private var idiom

    var body: some View {
        Menu {
            if let tabActions {
                Section("Chats") {
                    Button("Show chats", systemImage: "square.stack", action: tabActions.showOverview)
                    Button("New chat", systemImage: "square.and.pencil", action: tabActions.createTab)
                }
            }
            Section("Chat") {
                Button { viewModel.openLongChat() } label: {
                    Label(viewModel.isLongChat ? "Conversation ✓" : "Open conversation", systemImage: "bubble.left.and.bubble.right")
                }
                .accessibilityIdentifier("chat.long-chat.open")
                Button { viewModel.pickNewSession() } label: {
                    Label("New separate chat", systemImage: "square.and.pencil")
                }
                if viewModel.isLongChat && viewModel.activeLongChatTaskCount > 0 {
                    Button("Stop all tasks", role: .destructive) { viewModel.stopLongChatTasks() }
                        .accessibilityIdentifier("chat.long-chat.stop-tasks")
                }
            }

#if os(macOS)
            Button {
                viewModel.isAttachmentPickerShown = true
            } label: {
                Label("Files and Attach", systemImage: "paperclip")
            }

            Button {
                DispatchQueue.main.async {
                    viewModel.insertCodeBlock()
                }
            } label: {
                Label("Code block", systemImage: "chevron.left.forwardslash.chevron.right")
            }
#else
            Button {
                viewModel.isCameraPickerShown = true
            } label: {
                Label("Camera", systemImage: "camera")
            }
#if os(visionOS)
            .disabled(true)
#endif

            Button {
                viewModel.isPhotoPickerShown = true
            } label: {
                Label("Photos", systemImage: "photo.on.rectangle")
            }

            Button {
                viewModel.isAttachmentPickerShown = true
            } label: {
                Label("Files", systemImage: "folder")
            }

            if idiom != .phone {
                agentMenu
                effortMenu
            }
#endif
        } label: {
#if os(macOS)
            Color.clear
                .frame(
                    width: ChatComposerView.buttonSize,
                    height: ChatComposerView.buttonSize
                )
#else
            Icons.symbol(.add, size: 18)
                .foregroundColor(theme.colors.textSecondary)
                .frame(width: ChatComposerView.phoneCircleSize, height: ChatComposerView.phoneCircleSize)
                .background(theme.colors.textPrimary.opacity(0.10 as CGFloat), in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
#endif
        }
#if os(macOS)
        .menuStyle(CustomMenuButtonStyle())
#elseif os(visionOS)
        .menuIndicator(.hidden)
        .buttonBorderShape(.circle)
        .glassBackgroundEffect()
#else
        .menuIndicator(.hidden)
        .buttonBorderShape(.circle)
        .buttonStyle(.plain)
#endif
        .accessibilityLabel("Add")
    }

    private var agentMenu: some View {
        Menu {
            if viewModel.agents.isEmpty {
                Text("No agents")
            } else {
                ForEach(viewModel.agents) { agent in
                    Button {
                        viewModel.pickAgent(agent)
                    } label: {
                        ComposerMenuItem(
                            title: agent.displayName,
                            isSelected: viewModel.selectedAgent?.id == agent.id
                        )
                    }
                }
            }
        } label: {
            Label("Agent", systemImage: "person")
        }
    }

    private var effortMenu: some View {
        Menu {
            ForEach(ChatReasoningEffort.allCases) { effort in
                Button {
                    viewModel.pickReasoningEffort(effort)
                } label: {
                    ComposerMenuItem(
                        title: effort.title,
                        isSelected: viewModel.selectedReasoningEffort == effort
                    )
                }
            }
        } label: {
            Label("Effort", systemImage: "gauge.with.dots.needle.50percent")
        }
        .disabled(!supportsReasoningEffort)
    }
}

private struct ChatComposerCapsuleChrome: View {
    let height: CGFloat
    let aspectRatio: CGFloat
    let accentColor: Color

    @Environment(\.theme) private var theme

    var body: some View {
        Capsule()
            #if os(iOS)
            .fill(theme.colors.background)
            #else
            .fill(Color.black)
            #endif
    }
}

struct SubmitButton: ButtonStyle {

    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    private static let sendSize: CGFloat = 24

    func makeBody(configuration: Configuration) -> some View {
        let actionFill = Color.accentColor

        configuration.label
            .foregroundColor(theme.colors.textPrimary)
            .frame(width: Self.sendSize, height: Self.sendSize)
            .padding(4)
            .backportGlassEffect(
                .regular.tint(actionFill.opacity(isEnabled ? 1 : 0.4)),
                in: Circle()
            )
    }
}

#Preview {
    let viewModel = ChatScreenViewModel(
        apiClient: .init(),
        settings: .init(),
        connectionMonitor: .init(baseURL: URL.debugURL),
        onOpenSettings: { _ in }
    )
    viewModel.sessions = [
        .init(id: "1", agentId: "sloppy", title: "SLOPPY"),
        .init(id: "2", agentId: "sloppy", title: "SLOPPY"),
        .init(id: "3", agentId: "sloppy", title: "SLOPPY"),
    ]

    return VStack(spacing: 16) {
        Section("Phone") {
            ChatComposerView(draft: .init(), tabs: [
                .init(
                    key: .chatSession(""),
                    kind: .chat,
                    title: "ew",
                    payload: .chatSession(sessionID: "", title: "")
                )
            ], viewModel: viewModel)
                .environment(\.userInterfaceIdiom, .phone)
        }
        
        Divider()

        Section("Desktop") {
            ChatComposerView(draft: .init(), tabs: [
                .init(
                    key: .chatSession(""),
                    kind: .chat,
                    title: "ew",
                    payload: .chatSession(sessionID: "", title: "")
                )
            ], viewModel: viewModel)
                .environment(\.userInterfaceIdiom, .desktop)
        }

        Divider()

        Section("Dictation") {
            DictationComposerBar(
                phase: .recording,
                levels: Array(0..<900).map { _ in CGFloat.random(in: 0...1) },
                elapsed: 0.2,
                stop: {}
            )
        }
    }
}

struct CustomMenuButtonStyle: MenuStyle {
    @Environment(\.theme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            Menu(configuration)
                .frame(
                    width: ChatComposerView.buttonSize,
                    height: ChatComposerView.buttonSize
                )
                .contentShape(.circle)
                .menuIndicator(.hidden)
                .menuStyle(.borderlessButton)

            Icons.symbol(.add, size: theme.typography.heading)
                .foregroundColor(theme.colors.textPrimary)
                .allowsHitTesting(false)
        }
        .frame(
            width: ChatComposerView.buttonSize,
            height: ChatComposerView.buttonSize
        )
        .buttonBorderShape(.circle)
        .buttonSizing(.flexible)
        .backportGlassEffect(.regular.interactive(), in: .circle)
        .padding(.bottom, (ChatComposerView.panelHeight - ChatComposerView.buttonSize) / 2)
    }
}

private enum Constants {
    static let fieldHeight: CGFloat = 48
    static let fieldHorizontalPadding: CGFloat = fieldHeight / 2
    static let editorMinimumHeight: CGFloat = 31
    static let editorContentHorizontalInset: CGFloat = 8
    static let editorNativeTextContainerInset: CGFloat = 5
    static let editorContentVerticalInset: CGFloat = 7
    static let maximumVisibleLines = 6
    static let modelPickerRowHeight: CGFloat = 30
}
