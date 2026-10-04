#if os(macOS)
import SloppyClientCore
import SloppyClientUI
import SwiftUI

/// Compact presentation of the same session and transcript used by the main chat.
@MainActor
public struct NotchChatView: View {
    public let viewModel: ChatScreenViewModel
    public let agentID: String
    public let agentName: String
    public let paletteID: String?
    public let isPresented: Bool
    @FocusState private var isComposerFocused: Bool

    public init(viewModel: ChatScreenViewModel, agentID: String, agentName: String, paletteID: String? = nil,
                isPresented: Bool = true) {
        self.viewModel = viewModel
        self.agentID = agentID
        self.agentName = agentName
        self.paletteID = paletteID
        self.isPresented = isPresented
    }

    public var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                if viewModel.isLoadingTranscript && viewModel.transcript.isEmpty {
                    ProgressView("Loading chat…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.transcript.isEmpty && viewModel.activeInputRequest == nil {
                    Text(viewModel.didLoadInitialData && viewModel.selectedAgent == nil
                         ? "This agent is unavailable."
                         : "Start a conversation with \(agentName).")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    transcript(width: max(1, geometry.size.width - 16))
                }
            }
            if let approval = viewModel.pendingToolApproval {
                ChatToolApprovalCard(
                    approval: approval,
                    isResolving: viewModel.isResolvingToolApproval,
                    errorMessage: viewModel.toolApprovalErrorMessage,
                    decide: viewModel.resolvePendingToolApproval
                )
            }
            if !viewModel.queuedMessages.isEmpty {
                ChatQueuedMessagesCard(messages: viewModel.queuedMessages, cancel: viewModel.cancelQueuedMessage)
            }
            if let error = viewModel.sendErrorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            composer
                .layoutPriority(1)
        }
        .environment(\.theme, .sloppyDark)
        .environment(\.userInterfaceIdiom, .desktop)
        .preferredColorScheme(.dark)
        .onAppear { isComposerFocused = isPresented }
        .onChange(of: isPresented) { _, visible in isComposerFocused = visible }
        .onChange(of: viewModel.selectedSessionId) { _, _ in isComposerFocused = isPresented }
        .onChange(of: viewModel.composerFocusRequestToken) { _, _ in isComposerFocused = isPresented }
        .accessibilityIdentifier("notch.chat")
    }

    private func transcript(width: CGFloat) -> some View {
        ChatTranscriptPane(
            transcript: viewModel.transcript,
            isLoadingTranscript: viewModel.isLoadingTranscript,
            scrollToEndRequest: viewModel.transcriptScrollToEndRequest,
            contentWidth: width,
            messagesTopInset: 8,
            composerScrollInset: 8,
            showsThinkingIndicator: viewModel.isAwaitingAgentResponse && !viewModel.messages.contains {
                $0.id.hasPrefix("streaming-assistant-")
            },
            isRunActive: viewModel.isAwaitingAgentResponse || viewModel.isStopping,
            runStatusLabel: viewModel.activeRunStatusLabel,
            runStatusDetails: viewModel.activeRunStatusDetails,
            workingTreeSourceControl: nil,
            inputRequest: viewModel.activeInputRequest,
            isSubmittingInputResponse: viewModel.isSubmittingInputResponse,
            inputRequestErrorMessage: viewModel.inputRequestErrorMessage,
            providerSettingsRecoveryMessageIDs: viewModel.providerSettingsRecoveryMessageIDs,
            onSubmitInputResponse: viewModel.submitInputResponse,
            onCancelInputRequest: viewModel.cancelInputRequest,
            onForkFromMessage: viewModel.forkSession,
            onOpenProviderSettings: { viewModel.openSettings(.providers) },
            agentAvatarID: agentID,
            agentPaletteID: paletteID,
            userBubbleAgentID: viewModel.isLongChat ? agentID : nil,
            userBubblePaletteID: paletteID
        )
    }

    private var composer: some View {
        @Bindable var draft = viewModel.composerDraft
        return HStack(alignment: .bottom, spacing: 8) {
            TextField("Message \(agentName)…", text: $draft.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(1...4)
                .focused($isComposerFocused)
                .onSubmit(send)
                .disabled(viewModel.selectedAgent == nil || viewModel.activeInputRequest != nil)
                .accessibilityIdentifier("notch.chat.composer")
            if viewModel.shouldShowStopButton {
                Button(action: viewModel.stopActiveRun) {
                    Image(systemName: "stop.fill").frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isStopping)
                .help("Stop agent")
                .accessibilityLabel("Stop agent")
            }
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.9), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || viewModel.selectedAgent == nil || viewModel.activeInputRequest != nil)
            .help("Send message")
            .accessibilityLabel("Send message")
            .accessibilityIdentifier("notch.chat.send")
        }
        .padding(8)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
    }

    private func send() {
        let content = viewModel.composerDraft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        viewModel.sendMessage(content: content)
        isComposerFocused = true
    }
}
#endif
