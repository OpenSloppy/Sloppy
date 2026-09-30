import Foundation
import SwiftUI
import SloppyClientCore
import SloppyClientUI
import UniformTypeIdentifiers
#if canImport(PhotosUI) && !os(macOS)
import PhotosUI
#endif
#if os(iOS)
import UIKit
#endif

fileprivate let chatHeroWidth: CGFloat = 720
fileprivate let chatContentWidth: CGFloat = 960

@MainActor
public struct ChatScreen: View {
    @State private var viewModel: ChatScreenViewModel
    private let rootSafeAreaInsets: EdgeInsets
    private let onOpenSidebar: (@MainActor () -> Void)?
    private let showsContextToolbar: Bool
    private let showsNavigationToolbar: Bool
    private let onAskInSideChat: (@MainActor @Sendable (String) -> Void)?

    public init(
        apiClient: SloppyAPIClient,
        settings: ClientSettings,
        connectionMonitor: ConnectionMonitor,
        onOpenSettings: @escaping @MainActor (ClientSettingsDestination) -> Void,
        rootSafeAreaInsets: EdgeInsets = EdgeInsets(),
        onOpenSidebar: (@MainActor () -> Void)? = nil,
        showsContextToolbar: Bool = true,
        showsNavigationToolbar: Bool = true,
        onAskInSideChat: (@MainActor @Sendable (String) -> Void)? = nil
    ) {
        self.rootSafeAreaInsets = rootSafeAreaInsets
        self.onOpenSidebar = onOpenSidebar
        self.showsContextToolbar = showsContextToolbar
        self.showsNavigationToolbar = showsNavigationToolbar
        self.onAskInSideChat = onAskInSideChat
        self._viewModel = State(
            initialValue: ChatScreenViewModel(
                apiClient: apiClient,
                settings: settings,
                connectionMonitor: connectionMonitor,
                onOpenSettings: onOpenSettings
            )
        )
    }

    public init(
        viewModel: ChatScreenViewModel,
        rootSafeAreaInsets: EdgeInsets = EdgeInsets(),
        onOpenSidebar: (@MainActor () -> Void)? = nil,
        showsContextToolbar: Bool = true,
        showsNavigationToolbar: Bool = true,
        onAskInSideChat: (@MainActor @Sendable (String) -> Void)? = nil
    ) {
        self.rootSafeAreaInsets = rootSafeAreaInsets
        self.onOpenSidebar = onOpenSidebar
        self.showsContextToolbar = showsContextToolbar
        self.showsNavigationToolbar = showsNavigationToolbar
        self.onAskInSideChat = onAskInSideChat
        self.viewModel = viewModel
    }

    public var body: some View {
        ChatScreenContent(
            rootSafeAreaInsets: rootSafeAreaInsets,
            onOpenSidebar: onOpenSidebar,
            composerTabActions: nil
        )
        .modifier(ChatAttachmentDropZone(viewModel: viewModel))
        .modifier(ChatContextToolbarModifier(viewModel: viewModel, isEnabled: showsContextToolbar))
        .modifier(
            ChatNavigationToolbarModifier(
                viewModel: viewModel,
                onOpenSidebar: onOpenSidebar,
                isEnabled: showsNavigationToolbar
            )
        )
        .environment(viewModel)
        .environment(viewModel.connectionMonitor)
        .environment(
            \.chatTextSelectionActions,
            ChatTextSelectionActions(
                addToChat: viewModel.addQuoteToComposer,
                moreDetails: viewModel.askForMoreDetails,
                askInSideChat: onAskInSideChat
            )
        )
        .fileImporter(
            isPresented: $viewModel.isAttachmentPickerShown,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                viewModel.attachFileURLs(urls)
            case .failure:
                break
            }
        }
#if canImport(PhotosUI) && !os(macOS)
        .modifier(ChatPhotoAttachmentPickerModifier(viewModel: viewModel))
#endif
#if os(iOS)
        .modifier(ChatCameraAttachmentPickerModifier(viewModel: viewModel))
#endif
    }
}

#if canImport(PhotosUI) && !os(macOS)
@MainActor
private struct ChatPhotoAttachmentPickerModifier: ViewModifier {
    @State var viewModel: ChatScreenViewModel
    @State private var photoItems: [PhotosPickerItem] = []

    func body(content: Content) -> some View {
        content
            .photosPicker(
                isPresented: $viewModel.isPhotoPickerShown,
                selection: $photoItems,
                maxSelectionCount: 10,
                matching: .images
            )
            .onChange(of: photoItems) { _, items in
                Task { @MainActor in
                    let urls = await attachmentURLs(from: items)
                    viewModel.attachFileURLs(urls)
                    photoItems = []
                }
            }
    }

    private func attachmentURLs(from items: [PhotosPickerItem]) async -> [URL] {
        var urls: [URL] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                continue
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("sloppy-photo-\(UUID().uuidString)")
                .appendingPathExtension("jpg")
            guard (try? data.write(to: url, options: .atomic)) != nil else {
                continue
            }
            urls.append(url)
        }
        return urls
    }
}
#endif

#if os(iOS)
@MainActor
private struct ChatCameraAttachmentPickerModifier: ViewModifier {
    let viewModel: ChatScreenViewModel

    func body(content: Content) -> some View {
        @Bindable var viewModel = viewModel
        return content.fullScreenCover(isPresented: $viewModel.isCameraPickerShown) {
            CameraAttachmentPicker { url in
                viewModel.isCameraPickerShown = false
                if let url {
                    viewModel.attachFileURLs([url])
                }
            }
            .ignoresSafeArea()
        }
    }
}

private struct CameraAttachmentPicker: UIViewControllerRepresentable {
    let onComplete: @MainActor (URL?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onComplete: @MainActor (URL?) -> Void

        init(onComplete: @escaping @MainActor (URL?) -> Void) {
            self.onComplete = onComplete
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            let url: URL? = {
                guard let image = info[.originalImage] as? UIImage,
                      let data = image.jpegData(compressionQuality: 0.9) else {
                    return nil
                }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("sloppy-camera-\(UUID().uuidString)")
                    .appendingPathExtension("jpg")
                return (try? data.write(to: url, options: .atomic)) == nil ? nil : url
            }()
            Task { @MainActor in onComplete(url) }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            Task { @MainActor in onComplete(nil) }
        }
    }
}
#endif

@MainActor
private struct ChatContextToolbarModifier: ViewModifier {
    let viewModel: ChatScreenViewModel
    let isEnabled: Bool

    @Environment(\.userInterfaceIdiom) private var idiom

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(macOS)
        content
        #else
        if idiom == .phone {
            content
        } else if isEnabled {
            content.toolbar(id: "agent.settings") {
                ToolbarItem(id: "agent", placement: .secondaryAction) {
                    ChatAgentToolbarMenu(
                        selectedAgent: viewModel.selectedAgent,
                        agents: viewModel.agents,
                        onSelectAgent: viewModel.pickAgent
                    )
                }
                ToolbarItem(id: "model", placement: .secondaryAction) {
                    ChatModelToolbarMenu(
                        selectedModelId: viewModel.selectedModelId,
                        models: viewModel.availableModels,
                        onSelectModel: viewModel.pickModel
                    )
                }
            }
        } else {
            content
        }
        #endif
    }
}

@MainActor
private struct ChatScreenContent: View {
    let rootSafeAreaInsets: EdgeInsets
    let onOpenSidebar: (@MainActor () -> Void)?
    let composerTabActions: ChatComposerTabActions?

    @Environment(ChatScreenViewModel.self) private var viewModel
    @Environment(ConnectionMonitor.self) private var connectionMonitor

    var body: some View {
        ChatChrome(
            viewModel: viewModel,
            connectionMonitor: connectionMonitor,
            rootSafeAreaInsets: rootSafeAreaInsets,
            composerTabActions: composerTabActions
        )
        .onAppear {
            viewModel.loadInitialData()
        }
    }
}

@MainActor
private struct ChatNavigationToolbarModifier: ViewModifier {
    let viewModel: ChatScreenViewModel
    let onOpenSidebar: (@MainActor () -> Void)?
    let isEnabled: Bool

    @Environment(\.userInterfaceIdiom) private var idiom

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
#if os(iOS)
            if idiom == .phone {
                content
                    .navigationTitle(viewModel.activeSessionTitle)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                viewModel.startNewMessage()
                            } label: {
                                Label("New message", systemImage: "square.and.pencil")
                                    .labelStyle(.iconOnly)
                            }
                            .accessibilityLabel("New message")
                            .accessibilityIdentifier("chat.navigation.new-message")
                            .disabled(viewModel.selectedAgent == nil && viewModel.agents.isEmpty)
                        }
                    }
            } else {
                desktopToolbar(content)
            }
#else
            desktopToolbar(content)
#endif
        } else {
            content
        }
    }

    private func desktopToolbar(_ content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .navigation) {
                ChatNavigationLeadingItems(
                    viewModel: viewModel,
                    onOpenSidebar: onOpenSidebar
                )
            }
        }
    }
}

@MainActor
private struct ChatChrome: View {
    let viewModel: ChatScreenViewModel
    let connectionMonitor: ConnectionMonitor
    let rootSafeAreaInsets: EdgeInsets
    let composerTabActions: ChatComposerTabActions?

    @Environment(\.safeAreaInsets) private var safeAreaInsets
    @Environment(\.userInterfaceIdiom) private var idiom
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if idiom == .phone {
                chromeLayout(contentWidth: phoneContentWidth)
            } else {
                GeometryReader { proxy in
                    chromeLayout(contentWidth: contentWidth(for: proxy.size.width))
                }
            }
        }
    }

    private func chromeLayout(contentWidth: CGFloat) -> some View {
        let heroWidth = heroWidth(for: contentWidth)

        return ZStack(alignment: .bottom) {
            if viewModel.isLoadingTranscript, viewModel.transcript.isEmpty {
                ChatTranscriptLoadingView()
            } else if viewModel.transcript.isEmpty, viewModel.activeInputRequest == nil {
                ChatEmptyChatRegion(
                    viewModel: viewModel,
                    contentWidth: contentWidth,
                    heroWidth: heroWidth,
                    bottomClearance: composerScrollInset
                )
            } else {
                ChatTranscriptRegion(
                    viewModel: viewModel,
                    contentWidth: contentWidth,
                    messagesTopInset: messagesTopInset,
                    composerScrollInset: composerScrollInset,
                    showsThinkingIndicator: showsThinkingIndicator,
                    isRunActive: viewModel.isAwaitingAgentResponse || viewModel.isStopping,
                    runStatusLabel: viewModel.activeRunStatusLabel,
                    runStatusDetails: viewModel.activeRunStatusDetails
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
#if os(macOS)
        .overlay(alignment: .bottomTrailing) {
            if let activity = viewModel.computerUseActivity,
               !viewModel.isComputerUsePreviewHidden {
                ChatComputerUsePictureInPictureView(
                    activity: activity,
                    onHide: viewModel.hideComputerUsePreview
                )
                .padding(.trailing, theme.spacing.l)
                .padding(.bottom, composerScrollInset + theme.spacing.m)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.24), value: viewModel.computerUseActivity)
        .animation(.snappy(duration: 0.2), value: viewModel.isComputerUsePreviewHidden)
#endif
//        .overlay(alignment: .topLeading) {
//            if idiom != .phone {
//                ChatSessionContextBar(viewModel: viewModel)
//                    .padding(.horizontal, theme.spacing.m)
//                    .padding(.top, theme.spacing.s)
//            }
//        }
    }

    private func contentWidth(for availableWidth: CGFloat) -> CGFloat {
        let horizontalInset = idiom == .phone ? theme.spacing.s * 2 : theme.spacing.l * 2
        return max(0, min(chatContentWidth, availableWidth - horizontalInset))
    }

    private func heroWidth(for contentWidth: CGFloat) -> CGFloat {
        min(contentWidth, chatHeroWidth)
    }

    private var pickerWidth: CGFloat {
        if idiom == .phone {
            return max(280, min(320, screenPointWidth - theme.spacing.m * 2))
        }
        return 320
    }

    private var phoneContentWidth: CGFloat {
        let available = max(0, screenPointWidth - rootSafeAreaInsets.leading - rootSafeAreaInsets.trailing)
        return max(0, available - theme.spacing.s * 2)
    }

    private var overlayTopInset: CGFloat {
        ChatOverlayLayout.pickerTopInset(
            isPhone: idiom == .phone,
            rootSafeAreaTop: rootSafeAreaInsets.top,
            effectiveSafeAreaTop: safeAreaInsets.top
        )
    }

    private var composerScrollInset: CGFloat {
        let fallbackHeight = ChatComposerView.panelHeight(for: idiom)
            + (viewModel.composerAttachments.isEmpty
                ? 0
                : ChatComposerView.attachmentStripHeight + theme.spacing.s)
        return (viewModel.composerPanelHeight ?? fallbackHeight) + composerBottomInset + composerScrollGap
    }

    private var composerBottomInset: CGFloat {
        guard idiom == .phone else {
            return theme.spacing.m
        }

        return ChatComposerKeyboardLayout.phoneBottomInset(
            rootSafeAreaBottom: rootSafeAreaInsets.bottom,
            effectiveSafeAreaBottom: safeAreaInsets.bottom,
            normalMinimumSpacing: theme.spacing.s,
            keyboardSpacing: theme.spacing.s
        )
    }

    private var messagesTopInset: CGFloat {
        idiom == .phone ? theme.spacing.s : theme.spacing.l
    }

    private var composerScrollGap: CGFloat {
        idiom == .phone ? theme.spacing.l : theme.spacing.xxl + theme.spacing.l
    }

    private var showsThinkingIndicator: Bool {
        guard viewModel.isAwaitingAgentResponse else { return false }
        let messages = viewModel.transcript.messages
        guard let lastUserIndex = messages.lastIndex(where: { $0.role == .user }) else {
            return true
        }
        let nextIndex = messages.index(after: lastUserIndex)
        guard nextIndex < messages.endIndex else { return true }
        return !messages[nextIndex...].contains(where: { $0.role != .user })
    }

    private var screenPointWidth: CGFloat {
        guard let screen = Screen.main else {
            return 390
        }
        return max(320, screen.size.width)
    }
}

@MainActor
private struct ChatSessionContextBar: View {
    let viewModel: ChatScreenViewModel

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.xs) {
            HStack(spacing: theme.spacing.s) {
                Image(systemName: viewModel.selectedSessionId == nil ? "square.and.pencil" : "bubble.left.and.text.bubble.right")
                Text(viewModel.activeSessionTitle)
                    .lineLimit(1)
                if let sessionId = viewModel.selectedSessionId {
                    Text(String(sessionId.prefix(8)))
                        .foregroundColor(theme.colors.textMuted)
                        .monospaced()
                }
            }
            .font(.system(size: theme.typography.caption, weight: .medium))
            .foregroundColor(theme.colors.textSecondary)

            if let error = viewModel.sendErrorMessage {
                Text(error)
                    .font(.system(size: theme.typography.caption))
                    .foregroundColor(.red)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, theme.spacing.m)
        .padding(.vertical, theme.spacing.s)
        .background(theme.colors.surfaceRaised.opacity(0.9 as CGFloat), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Current session: \(viewModel.activeSessionTitle)")
    }
}

struct ChatComposerKeyboardLayout {
    private static let keyboardSafeAreaEpsilon: CGFloat = 1

    static func phoneBottomInset(
        rootSafeAreaBottom: CGFloat,
        effectiveSafeAreaBottom: CGFloat,
        normalMinimumSpacing: CGFloat,
        keyboardSpacing: CGFloat
    ) -> CGFloat {
        let keyboardSafeAreaIsActive = effectiveSafeAreaBottom > rootSafeAreaBottom + keyboardSafeAreaEpsilon
        if keyboardSafeAreaIsActive {
            return keyboardSpacing
        }

        return max(normalMinimumSpacing, rootSafeAreaBottom + keyboardSpacing)
    }
}

struct ChatOverlayLayout {
    static func pickerTopInset(
        isPhone: Bool,
        rootSafeAreaTop: CGFloat,
        effectiveSafeAreaTop: CGFloat
    ) -> CGFloat {
        if isPhone {
            return rootSafeAreaTop + 52
        }

        return effectiveSafeAreaTop
    }
}

@MainActor
private struct ChatNavigationLeadingItems: View {
    let viewModel: ChatScreenViewModel
    let onOpenSidebar: (@MainActor () -> Void)?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 8) {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(0.72 as CGFloat))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")

            if let onOpenSidebar {
                Button(action: onOpenSidebar) {
                    Icons.symbol(.menu, size: 15)
                        .foregroundColor(.white.opacity(0.72 as CGFloat))
                        .frame(width: 30, height: 30)
                }
            }

            if let activeContextTitle = viewModel.activeContextTitle {
                Text(activeContextTitle)
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.7 as CGFloat))
                    .lineLimit(1)
            }
        }
    }
}

@MainActor
private struct ChatTranscriptRegion: View {
    let viewModel: ChatScreenViewModel
    let contentWidth: CGFloat
    let messagesTopInset: CGFloat
    let composerScrollInset: CGFloat
    let showsThinkingIndicator: Bool
    let isRunActive: Bool
    let runStatusLabel: String
    let runStatusDetails: String?

    var body: some View {
        ChatTranscriptPane(
            transcript: viewModel.transcript,
            isLoadingTranscript: viewModel.isLoadingTranscript,
            scrollToEndRequest: viewModel.transcriptScrollToEndRequest,
            contentWidth: contentWidth,
            messagesTopInset: messagesTopInset,
            composerScrollInset: composerScrollInset,
            showsThinkingIndicator: showsThinkingIndicator,
            isRunActive: isRunActive,
            runStatusLabel: runStatusLabel,
            runStatusDetails: runStatusDetails,
            workingTreeSourceControl: viewModel.workingTreeSourceControl,
            inputRequest: viewModel.activeInputRequest,
            isSubmittingInputResponse: viewModel.isSubmittingInputResponse,
            inputRequestErrorMessage: viewModel.inputRequestErrorMessage,
            providerSettingsRecoveryMessageIDs: viewModel.providerSettingsRecoveryMessageIDs,
            onSubmitInputResponse: viewModel.submitInputResponse,
            onCancelInputRequest: viewModel.cancelInputRequest,
            onForkFromMessage: viewModel.forkSession,
            onOpenProviderSettings: { viewModel.openSettings(.providers) }
        )
    }
}

@MainActor
private struct ChatTranscriptLoadingView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        LoadingSkeleton("Loading conversation…", style: .detail)
        .accessibilityIdentifier("chat.transcript.loading")
    }
}

@MainActor
private struct ChatEmptyChatRegion: View {
    let viewModel: ChatScreenViewModel
    let contentWidth: CGFloat
    let heroWidth: CGFloat
    let bottomClearance: CGFloat

    @Environment(\.userInterfaceIdiom) private var idiom
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: theme.spacing.xl) {
            Spacer(minLength: idiom == .phone ? theme.spacing.xxl : theme.spacing.l)
            ChatGreetingView(
                projects: viewModel.projects,
                selectedProjectId: viewModel.activeProjectIdForWorkspacePanel,
                selectedProjectName: viewModel.activeProjectNameForWorkspacePanel,
                onSelectPersonal: viewModel.pickPersonal,
                onSelectProject: viewModel.pickProject,
                onSelectPrompt: viewModel.useStarterPrompt
            )
                .frame(width: heroWidth)
            Spacer(minLength: bottomClearance)
        }
        .padding(.horizontal, idiom == .phone ? theme.spacing.s : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.dismissComposerFocus()
        }
    }
}

@MainActor
public struct ChatComposerOverlay: View {
    public let viewModel: ChatScreenViewModel
    public let contentWidth: CGFloat
    public let composerBottomInset: CGFloat
    public let tabs: [WorkspaceTab]
    public let tabActions: ChatComposerTabActions?

    @Environment(\.userInterfaceIdiom) private var idiom
    @Environment(\.theme) private var theme

    public init(
        viewModel: ChatScreenViewModel,
        contentWidth: CGFloat,
        composerBottomInset: CGFloat,
        tabs: [WorkspaceTab],
        tabActions: ChatComposerTabActions?
    ) {
        self.viewModel = viewModel
        self.contentWidth = contentWidth
        self.composerBottomInset = composerBottomInset
        self.tabs = tabs
        self.tabActions = tabActions
    }

    public var body: some View {
        HStack {
            Spacer(minLength: 0)
            composerBar
#if os(visionOS)
                .padding3D(.front)
#endif
            Spacer(minLength: 0)
        }
        .padding(.horizontal, idiom == .phone ? theme.spacing.xs : 0)
        .padding(.bottom, composerBottomInset)
        #if os(macOS)
        .background(alignment: .bottom) {
            ComposerBackdrop(
                height: (viewModel.composerPanelHeight ?? ChatComposerView.panelHeight)
                    + composerBottomInset + 40
            )
        }
        #endif
        .dropDestination(for: String.self) { items, _ in
            guard let encoded = items.first,
                  let payload = WorkspacePanelDragPayload.decode(from: encoded) else {
                return false
            }
            viewModel.attachProjectFileReference(
                projectId: payload.projectId,
                path: payload.path,
                type: payload.type
            )
            return true
        }
        .modifier(ChatAttachmentDropZone(viewModel: viewModel))
        .task(id: ObjectIdentifier(viewModel)) {
            viewModel.requestComposerFocus()
        }
    }

    @ViewBuilder
    private var composerBar: some View {
        VStack(spacing: theme.spacing.s) {
            if let approval = viewModel.pendingToolApproval {
                ChatToolApprovalCard(
                    approval: approval,
                    isResolving: viewModel.isResolvingToolApproval,
                    errorMessage: viewModel.toolApprovalErrorMessage,
                    decide: viewModel.resolvePendingToolApproval
                )
                .frame(maxWidth: maximumComposerWidth)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if !viewModel.queuedMessages.isEmpty {
                ChatQueuedMessagesCard(
                    messages: viewModel.queuedMessages,
                    cancel: viewModel.cancelQueuedMessage
                )
                .frame(maxWidth: maximumComposerWidth)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            #if os(macOS)
            if let sourceControl = viewModel.workingTreeSourceControl {
                ChatComposerChangeSummaryView(sourceControl: sourceControl)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            #endif

            ChatComposerView(
                draft: viewModel.composerDraft,
                tabs: tabs,
                viewModel: viewModel,
                tabActions: tabActions
            )
            .frame(maxWidth: maximumComposerWidth)

        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
            viewModel.updateComposerPanelHeight(height)
        }
        .animation(
            .easeInOut(duration: 0.18),
            value: viewModel.workingTreeSourceControl?.diff
        )
        .animation(.easeInOut(duration: 0.18), value: viewModel.pendingToolApproval?.id)
        .animation(.easeInOut(duration: 0.18), value: viewModel.queuedMessages.map(\.id))
    }

    private var maximumComposerWidth: CGFloat {
#if os(macOS)
        min(contentWidth, ChatComposerView.desktopPanelWidth)
#else
        contentWidth
#endif
    }
}

@MainActor
private struct ChatToolApprovalCard: View {
    let approval: PendingToolApprovalRecord
    let isResolving: Bool
    let errorMessage: String?
    let decide: @MainActor (Bool, ClientToolApprovalDecisionScope) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.s) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: theme.spacing.s) {
                    approvalSummary
                    Spacer(minLength: theme.spacing.s)
                    approvalActions
                }
                VStack(alignment: .leading, spacing: theme.spacing.s) {
                    approvalSummary
                    ViewThatFits(in: .horizontal) {
                        approvalActions
                        VStack(alignment: .trailing, spacing: theme.spacing.s) {
                            persistentActions
                            singleCallActions
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
            if let errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(theme.colors.statusBlocked)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, theme.spacing.m)
        .padding(.vertical, theme.spacing.s)
        .background(theme.colors.surfaceRaised.opacity(0.96), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(theme.colors.statusWarning.opacity(0.5), lineWidth: 1)
        }
        .disabled(isResolving)
        .accessibilityIdentifier("chat.tool-approval")
    }

    private var approvalSummary: some View {
        HStack(spacing: theme.spacing.s) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(theme.colors.statusWarning)
            VStack(alignment: .leading, spacing: 2) {
                Text("Action required")
                    .font(.system(size: theme.typography.caption, weight: .semibold))
                Text(summary)
                    .font(.system(size: theme.typography.caption))
                    .foregroundStyle(theme.colors.textSecondary)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private var approvalActions: some View {
        if isResolving {
            ProgressView()
                .controlSize(.small)
        } else {
            HStack(spacing: theme.spacing.s) {
                persistentActions
                singleCallActions
            }
            .fixedSize()
        }
    }

    private var persistentActions: some View {
        HStack(spacing: theme.spacing.s) {
            Button("Always Allow") {
                decide(true, .always)
            }
            .help("Save this permission for this agent across sessions.")
            .accessibilityIdentifier("chat.tool-approval.always")
            Button("Allow for this Session") {
                decide(true, .session)
            }
            .help("Allow this permission for the current chat session.")
            .accessibilityIdentifier("chat.tool-approval.session")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var singleCallActions: some View {
        HStack(spacing: theme.spacing.s) {
            Button("Deny", role: .destructive) {
                decide(false, .once)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("chat.tool-approval.deny")
            Button("Allow") {
                decide(true, .once)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("chat.tool-approval.once")
        }
        .controlSize(.small)
    }

    private var summary: String {
        let reason = approval.reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let reason, !reason.isEmpty {
            return reason
        }
        if let tool = approval.tool, !tool.isEmpty {
            return "Allow \(tool) to continue this chat."
        }
        return "The agent is waiting for your approval."
    }
}

@MainActor
private struct ChatQueuedMessagesCard: View {
    let messages: [ChatQueuedMessage]
    let cancel: @MainActor (UUID) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.xs) {
            HStack {
                Label(
                    messages.count == 1 ? "Message queued" : "\(messages.count) messages queued",
                    systemImage: "clock.arrow.circlepath"
                )
                .font(.system(size: theme.typography.caption, weight: .semibold))
                Spacer()
            }
            ForEach(messages.prefix(3)) { message in
                HStack(spacing: theme.spacing.s) {
                    Text(message.displayText)
                        .font(.system(size: theme.typography.caption))
                        .foregroundStyle(theme.colors.textSecondary)
                        .lineLimit(1)
                    if !message.attachments.isEmpty {
                        Text("+\(message.attachments.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(theme.colors.textMuted)
                    }
                    Spacer(minLength: 0)
                    Button {
                        cancel(message.id)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .help("Remove queued message")
                }
            }
        }
        .padding(.horizontal, theme.spacing.m)
        .padding(.vertical, theme.spacing.s)
        .background(theme.colors.surfaceRaised.opacity(0.9), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("chat.message-queue")
    }
}

@MainActor
private struct ChatTranscriptPane: View {
    let transcript: ChatTranscriptState
    let isLoadingTranscript: Bool
    let scrollToEndRequest: Int
    let contentWidth: CGFloat
    let messagesTopInset: CGFloat
    let composerScrollInset: CGFloat
    let showsThinkingIndicator: Bool
    let isRunActive: Bool
    let runStatusLabel: String
    let runStatusDetails: String?
    let workingTreeSourceControl: ProjectWorkingTreeSourceControlResponse?
    let inputRequest: ChatPlanInputRequest?
    let isSubmittingInputResponse: Bool
    let inputRequestErrorMessage: String?
    let providerSettingsRecoveryMessageIDs: Set<String>
    let onSubmitInputResponse: @MainActor ([ChatPlanInputAnswer]) -> Void
    let onCancelInputRequest: @MainActor () -> Void
    let onForkFromMessage: @MainActor (ChatMessage) -> Void
    let onOpenProviderSettings: @MainActor () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.userInterfaceIdiom) private var idiom
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.chatTextSelectionActions) private var textSelectionActions
    @State private var visibleTranscriptItemID: String?
    @State private var scrollTarget: ChatTranscriptScrollTarget?
    @State private var scrollTargetRequestID: UInt = 0

    var body: some View {
        GeometryReader { proxy in
            ChatNativeTranscriptView(
                items: nativeItems,
                contentWidth: contentWidth,
                topInset: transcript.hasEarlierMessages ? 0 : messagesTopInset,
                bottomInset: composerScrollInset,
                scrollToEndRequest: scrollToEndRequest,
                autoFollowAppendedItems: !isLoadingTranscript,
                autoFollowChangingTail: isRunActive && !isLoadingTranscript,
                scrollTarget: scrollTarget,
                renderRevision: nativeRenderRevision,
                reduceMotion: reduceMotion,
                onVisibleItemChange: { itemID in
                    visibleTranscriptItemID = itemID
                },
                renderer: renderNativeItem
            )
#if os(macOS)
            .overlay(alignment: .leading) {
                if !conversationWaypoints.isEmpty,
                   proxy.size.width >= contentWidth + 2 * (30 + theme.spacing.m) {
                    ChatConversationNavigator(
                        waypoints: conversationWaypoints,
                        activeWaypointID: activeWaypointID,
                        onSelect: scroll(to:)
                    )
                    .padding(.leading, theme.spacing.m)
                }
            }
#endif
        }
    }

    private var conversationWaypoints: [ChatConversationWaypoint] {
        ChatConversationWaypoint.build(from: transcript.messages)
    }

    private var activeWaypointID: ChatConversationWaypoint.ID? {
        guard let visibleTranscriptItemID,
              let visibleIndex = nativeItems.firstIndex(where: { $0.id == visibleTranscriptItemID }) else {
            return conversationWaypoints.last?.id
        }

        return conversationWaypoints.last { waypoint in
            guard let waypointIndex = nativeItems.firstIndex(where: { $0.id == waypoint.targetItemID }) else {
                return false
            }
            return waypointIndex <= visibleIndex
        }?.id ?? conversationWaypoints.first?.id
    }

    private func scroll(to waypoint: ChatConversationWaypoint) {
        scrollTargetRequestID &+= 1
        scrollTarget = ChatTranscriptScrollTarget(
            itemID: waypoint.targetItemID,
            requestID: scrollTargetRequestID
        )
    }

    private var nativeItems: [ChatTranscriptNativeItem] {
        let activeRunMessageIDs = ChatActiveRunMessages.messageIDs(
            in: transcript.messages,
            isRunActive: isRunActive
        )
        var items: [ChatTranscriptNativeItem] = []

        if transcript.hasEarlierMessages {
            items.append(ChatTranscriptNativeItem(
                id: "reveal-earlier",
                content: .revealEarlier(count: min(64, transcript.hiddenMessageCount))
            ))
        }

        var previousEntryDate: Date?
        for (index, entry) in transcript.entries.enumerated() {
            if let previousEntryDate,
               ChatTranscriptDateSeparators.shouldInsert(
                   between: previousEntryDate,
                   and: entry.createdAt
               ) {
                items.append(ChatTranscriptNativeItem(
                    id: "date-separator:\(entry.id)",
                    content: .dateSeparator(entry.createdAt)
                ))
            }

            let bottomSpacing: CGFloat
            if index < transcript.entries.index(before: transcript.entries.endIndex) {
                bottomSpacing = ChatTranscriptGrouping.usesCompactSpacing(
                    between: entry,
                    and: transcript.entries[index + 1]
                ) ? theme.spacing.s : theme.spacing.xl
            } else {
                bottomSpacing = 0
            }

            let entryMessageIDs: Set<ChatMessage.ID>
            switch entry {
            case .message(let message):
                entryMessageIDs = activeRunMessageIDs.contains(message.id) ? [message.id] : []
            case .systemGroup(let messages):
                entryMessageIDs = Set(messages.map(\.id)).intersection(activeRunMessageIDs)
            }
            items.append(ChatTranscriptNativeItem(
                id: "entry:\(entry.id)",
                content: .entry(
                    entry,
                    bottomSpacing: bottomSpacing,
                    activeMessageIDs: entryMessageIDs,
                    providerRecoveryMessageIDs: entryProviderRecoveryMessageIDs(entry)
                )
            ))
            previousEntryDate = entry.createdAt
        }

        if let workingTreeSourceControl {
            items.append(ChatTranscriptNativeItem(
                id: "change-summary",
                content: .changeSummary(workingTreeSourceControl)
            ))
        }
        if showsThinkingIndicator {
            items.append(ChatTranscriptNativeItem(
                id: "thinking-indicator",
                content: .thinking(label: runStatusLabel, details: runStatusDetails)
            ))
        }
        if let inputRequest {
            items.append(ChatTranscriptNativeItem(
                id: "input-request:\(inputRequest.id)",
                content: .inputRequest(
                    request: inputRequest,
                    isSubmitting: isSubmittingInputResponse,
                    errorMessage: inputRequestErrorMessage
                )
            ))
        }
        return items
    }

    private var nativeRenderRevision: UInt {
        var hasher = Hasher()
        hasher.combine(transcript.renderRevision)
        hasher.combine(isRunActive)
        hasher.combine(showsThinkingIndicator)
        hasher.combine(runStatusLabel)
        hasher.combine(runStatusDetails)
        hasher.combine(workingTreeSourceControl?.diff)
        hasher.combine(inputRequest?.id)
        hasher.combine(isSubmittingInputResponse)
        hasher.combine(inputRequestErrorMessage)
        return UInt(bitPattern: hasher.finalize())
    }

    private func renderNativeItem(_ item: ChatTranscriptNativeItem) -> AnyView {
        let rendered: AnyView
        switch item.content {
        case .revealEarlier(let count):
            rendered = AnyView(
                revealEarlierButton(count: count)
                    .padding(.top, messagesTopInset)
                    .padding(.bottom, theme.spacing.m)
            )
        case .dateSeparator(let date):
            rendered = AnyView(
                Text(ChatTranscriptDateSeparators.title(for: date))
                    .font(.system(size: theme.typography.caption, weight: .medium))
                    .foregroundColor(theme.colors.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, theme.spacing.xl)
                    .accessibilityLabel("Conversation continued \(ChatTranscriptDateSeparators.title(for: date))")
            )
        case .entry(
            let entry,
            let bottomSpacing,
            let activeRunMessageIDs,
            let recoveryMessageIDs
        ):
            switch entry {
            case .message(let message):
                rendered = AnyView(
                    ChatBubbleView(
                        message: message,
                        isActivelyWorking: activeRunMessageIDs.contains(message.id),
                        onOpenProviderSettings: recoveryMessageIDs.contains(message.id)
                            ? onOpenProviderSettings
                            : nil,
                        onForkFromMessage: onForkFromMessage
                    )
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .padding(.bottom, bottomSpacing)
                )
            case .systemGroup(let messages):
                rendered = AnyView(
                    ChatSystemMessageGroupView(
                        messages: messages,
                        activeRunMessageIDs: activeRunMessageIDs
                    )
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .padding(.bottom, bottomSpacing)
                )
            }
        case .changeSummary(let sourceControl):
            rendered = AnyView(
                ChatChangeSummaryView(sourceControl: sourceControl)
                    .padding(.top, theme.spacing.m)
            )
        case .thinking(let label, let details):
            rendered = AnyView(
                ChatThinkingIndicator(label: label, details: details)
                    .padding(.top, theme.spacing.s)
            )
        case .inputRequest(let request, let isSubmitting, let errorMessage):
            rendered = AnyView(
                ChatInputRequestView(
                    request: request,
                    isSubmitting: isSubmitting,
                    errorMessage: errorMessage,
                    onSubmit: onSubmitInputResponse,
                    onCancel: onCancelInputRequest
                )
                .padding(.top, theme.spacing.m)
            )
        }
        return AnyView(
            rendered
                .environment(\.theme, theme)
                .environment(\.userInterfaceIdiom, idiom)
                .environment(\.chatTextSelectionActions, textSelectionActions)
        )
    }

    private func entryProviderRecoveryMessageIDs(
        _ entry: ChatTranscriptEntry
    ) -> Set<ChatMessage.ID> {
        switch entry {
        case .message(let message):
            return providerSettingsRecoveryMessageIDs.contains(message.id) ? [message.id] : []
        case .systemGroup(let messages):
            return Set(messages.map(\.id)).intersection(providerSettingsRecoveryMessageIDs)
        }
    }

    private func revealEarlierButton(count: Int) -> some View {
        let c = theme.colors
        let sp = theme.spacing
        let ty = theme.typography

        return HStack {
            Spacer(minLength: 0)
            Button("Show \(count) earlier") {
                transcript.revealEarlierMessages()
            }
            .font(.system(size: ty.caption))
            .foregroundColor(c.textSecondary)
            .padding(.horizontal, sp.m)
            .padding(.vertical, sp.s)
            .background(c.surface.opacity(0.74 as CGFloat))
            .backportGlassEffect(.regular, in: .rect(cornerRadius: 14))

            Spacer(minLength: 0)
        }
    }
}

#Preview {
    let viewModel = ChatScreenViewModel(
        apiClient: .init(baseURL: .debugURL),
        settings: .init(),
        connectionMonitor: .init(baseURL: URL.debugURL),
        onOpenSettings: { _ in }
    )
    NavigationStack {
        ChatScreen(viewModel: viewModel)
#if os(visionOS)
            .backportGlassEffect(.regular, in: .rect(cornerRadius: 24))
#endif
    }
}

#Preview {
    let viewModel = ChatScreenViewModel(
        apiClient: .init(baseURL: .debugURL),
        settings: .init(),
        connectionMonitor: .init(baseURL: URL.debugURL),
        onOpenSettings: { _ in }
    )
    viewModel.transcript.replaceAll([
        .init(role: .assistant, segments: [
            .init(kind: .text)
        ])
    ])
    return NavigationStack {
        ChatScreen(viewModel: viewModel)
#if os(visionOS)
            .backportGlassEffect(.regular, in: .rect(cornerRadius: 24))
#endif
    }
}
