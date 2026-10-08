import Foundation
import SwiftUI
import SloppyClientCore
import SloppyClientUI
import SloppyFeatureChat

struct AgentChatView: View {
    let agent: APIAgentRecord
    let apiClient: SloppyAPIClient

    @State private var sessionToRename: ChatSessionSummary?
    @State private var sessions: [ChatSessionSummary] = []
    @State private var selectedSessionId: String?
    @State private var showTranscript = false
    @State private var messages: [ChatMessage] = []
    @State private var isLoadingSessions = false
    @State private var didLoadSessions = false
    @State private var isSending = false
    @State private var composerDraft = ChatComposerDraft()
    @State private var socketManager: SessionSocketManager?
    @State private var streamTask: Task<Void, Never>?
    @State private var streamingFlushTask: Task<Void, Never>?
    @State private var pendingStreamingSessionId: String?
    @State private var pendingStreamingAssistantText: String?
    @State private var sessionActionStatus: String?
    @State private var settings = ClientSettings()
    @Environment(\.theme) private var theme

    var body: some View {
        sessionListView
            .sheet(item: $sessionToRename) { session in
                ChatRenameSheet(title: session.title) { title in
                    let updated = try await apiClient.renameAgentSession(agentId: agent.id, sessionId: session.id, title: title)
                    sessions = sessions.map { $0.id == updated.id ? updated : $0 }
                }
            }
            .sheet(isPresented: $showTranscript, onDismiss: { loadSessions(force: true) }) {
                if let sessionId = selectedSessionId {
                    ChatTranscriptView(
                        sessionId: sessionId,
                        agentId: agent.id,
                        messages: $messages,
                        composerDraft: composerDraft,
                        isSending: isSending,
                        onSend: { content in
                            sendMessage(agentId: agent.id, sessionId: sessionId, content: content)
                        },
                        onForkFromMessage: forkSession
                    )
                }
            }
    }

    private var sessionListView: some View {
        let c = theme.colors
        let sp = theme.spacing
        let ty = theme.typography

        return VStack(alignment: .leading, spacing: sp.m) {
            HStack(spacing: sp.s) {
                SectionHeader("Chats")
                if !sessions.isEmpty {
                    Text("\(sessions.count)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(c.textMuted)
                }
                Spacer()
                Button(action: createSession) {
                    Label("New chat", systemImage: "plus")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
                .tint(c.textSecondary)
                .controlSize(.regular)
                .accessibilityIdentifier("agent-chats.new-chat")
            }
            .padding(.horizontal, sp.l)

            if sessions.isEmpty {
                EmptyStateView(isLoadingSessions ? "Loading..." : "No sessions")
                    .padding(.vertical, sp.xl)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(sessions) { session in
                            sessionRow(session: session)
                            if session.id != sessions.last?.id {
                                Divider()
                                    .overlay(c.border.opacity(0.5))
                                    .padding(.leading, 52)
                            }
                        }
                    }
                    .padding(.horizontal, sp.l)
                }
            }

            if let sessionActionStatus {
                Text(sessionActionStatus)
                    .font(.system(size: ty.micro))
                    .foregroundColor(c.textMuted)
                    .lineLimit(2)
                    .padding(.horizontal, sp.l)
            }
        }
        .padding(.top, sp.l)
        .padding(.bottom, sp.m)
        .onAppear { loadSessions() }
    }

    private func sessionRow(session: ChatSessionSummary) -> some View {
        let isPinned = settings.isSessionPinned(session.id)

        return AgentChatSessionRow(
            session: session,
            isPinned: isPinned,
            onOpen: { selectSession(session.id) }
        )
        .contextMenu {
            Button("Rename Chat…", systemImage: "pencil") { sessionToRename = session }
            Button(isPinned ? "Unpin Chat" : "Pin Chat") {
                toggleSessionPinned(session)
            }

            Button("Copy Session File Debug Link") {
                copyDebugSessionFileLink(session)
            }

            Button("Delete Chat", role: .destructive) {
                deleteSession(session)
            }
        }
    }

    // MARK: - Session management

    private func selectSession(_ sessionId: String) {
        disconnectSocket()
        messages = []
        selectedSessionId = sessionId
        showTranscript = true
        loadSessionAndConnect(sessionId: sessionId)
    }

    private func disconnectAndClearSession() {
        disconnectSocket()
        messages = []
        selectedSessionId = nil
        showTranscript = false
    }

    private func disconnectSocket() {
        let manager = socketManager
        streamTask?.cancel()
        streamTask = nil
        cancelPendingStreamingAssistantText()
        socketManager = nil
        if let manager {
            Task { await manager.disconnect() }
        }
    }

    // MARK: - Actions

    private func deleteSession(_ session: ChatSessionSummary) {
        Task { @MainActor in
            do {
                try await apiClient.deleteAgentSession(agentId: agent.id, sessionId: session.id)
                settings.setSessionPinned(session.id, isPinned: false)
                sessions.removeAll { $0.id == session.id }

                if selectedSessionId == session.id {
                    disconnectAndClearSession()
                }

                showSessionStatus("Deleted \(displayTitle(for: session))")
            } catch {
                showSessionStatus("Could not delete \(displayTitle(for: session))")
            }
        }
    }

    private func toggleSessionPinned(_ session: ChatSessionSummary) {
        let nextPinned = !settings.isSessionPinned(session.id)
        settings.setSessionPinned(session.id, isPinned: nextPinned)
        sessions = sortSessions(sessions)
        showSessionStatus(nextPinned ? "Pinned \(displayTitle(for: session))" : "Unpinned \(displayTitle(for: session))")
    }

    private func copyDebugSessionFileLink(_ session: ChatSessionSummary) {
        let url = debugSessionFilePathURL(for: session)
        UIClipboard.setString(url.absoluteString)
        showSessionStatus("Copied session file debug link")
    }

    private func loadSessions(force: Bool = false) {
        guard force || !didLoadSessions else { return }
        guard !isLoadingSessions else { return }

        isLoadingSessions = true
        Task { @MainActor in
            defer {
                didLoadSessions = true
                isLoadingSessions = false
            }
            sessions = sortSessions((try? await apiClient.fetchAgentSessions(agentId: agent.id)) ?? [])
        }
    }

    private func createSession() {
        Task { @MainActor in
            guard let summary = try? await apiClient.createAgentSession(
                agentId: agent.id,
                title: nil
            ) else { return }
            sessions.insert(summary, at: 0)
            sessions = sortSessions(sessions)
            selectSession(summary.id)
        }
    }

    private func forkSession(from message: ChatMessage) {
        guard let parentSessionId = selectedSessionId else { return }
        let parent = sessions.first { $0.id == parentSessionId }
        let responseTitle = message.textContent
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String
        if let responseTitle, !responseTitle.isEmpty {
            title = "Fork: \(String(responseTitle.prefix(48)))"
        } else {
            title = "Fork of \(parent.map(displayTitle(for:)) ?? "Session")"
        }

        Task { @MainActor in
            do {
                let summary = try await apiClient.createAgentSession(
                    agentId: agent.id,
                    title: title,
                    parentSessionId: parentSessionId,
                    projectId: parent?.projectId,
                    workspaceId: parent?.workspaceId
                )
                sessions.insert(summary, at: 0)
                sessions = sortSessions(sessions)
                selectSession(summary.id)
            } catch {
                showSessionStatus("Could not fork session")
            }
        }
    }

    private func loadSessionAndConnect(sessionId: String) {
        let manager = SessionSocketManager(endpoint: apiClient.endpoint, agentId: agent.id, sessionId: sessionId)
        socketManager = manager

        streamTask = Task { @MainActor in
            defer {
                Task { await manager.disconnect() }
            }

            let stream = await manager.connect()

            if let detail = try? await apiClient.fetchAgentSession(agentId: agent.id, sessionId: sessionId) {
                guard selectedSessionId == sessionId else { return }
                messages = detail.messages
            }

            for await update in stream {
                guard selectedSessionId == sessionId else { return }
                await handleStreamUpdate(update, agentId: agent.id, sessionId: sessionId)
            }
        }
    }

    private func handleStreamUpdate(
        _ update: ChatStreamUpdate,
        agentId: String,
        sessionId: String
    ) async {
        switch update.kind {
        case .sessionReady:
            if let detail = try? await apiClient.fetchAgentSession(agentId: agentId, sessionId: sessionId) {
                messages = detail.messages
            }
        case .sessionEvent, .sessionDelta:
            if update.kind == .sessionDelta, let text = update.messageText {
                scheduleStreamingAssistantText(text, sessionId: sessionId)
            } else if let msg = update.message {
                upsertMessage(msg, sessionId: sessionId)
            }
        case .sessionClosed, .sessionError:
            flushPendingStreamingAssistantText()
        case .heartbeat:
            break
        }
    }

    private func upsertMessage(_ message: ChatMessage, sessionId: String) {
        if message.role == .assistant {
            cancelPendingStreamingAssistantText(for: sessionId)
            messages.removeAll { $0.id == streamingAssistantMessageId(for: sessionId) }
        } else if message.role == .user {
            messages.removeAll { $0.id.hasPrefix("optimistic-user-") }
        }

        if let idx = messages.firstIndex(where: { $0.id == message.id }) {
            messages[idx] = message
        } else {
            messages.append(message)
        }
    }

    private func scheduleStreamingAssistantText(_ text: String, sessionId: String) {
        guard !text.isEmpty else { return }
        pendingStreamingSessionId = sessionId
        pendingStreamingAssistantText = (pendingStreamingAssistantText ?? "") + text

        guard streamingFlushTask == nil else {
            return
        }

        streamingFlushTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            flushPendingStreamingAssistantText()
        }
    }

    private func flushPendingStreamingAssistantText() {
        guard let sessionId = pendingStreamingSessionId,
              let text = pendingStreamingAssistantText else {
            streamingFlushTask = nil
            return
        }

        pendingStreamingSessionId = nil
        pendingStreamingAssistantText = nil
        streamingFlushTask = nil
        applyStreamingAssistantText(text, sessionId: sessionId)
    }

    private func cancelPendingStreamingAssistantText(for sessionId: String? = nil) {
        guard sessionId == nil || pendingStreamingSessionId == sessionId else {
            return
        }

        streamingFlushTask?.cancel()
        streamingFlushTask = nil
        pendingStreamingSessionId = nil
        pendingStreamingAssistantText = nil
    }

    private func applyStreamingAssistantText(_ text: String, sessionId: String) {
        guard !text.isEmpty else { return }

        let id = streamingAssistantMessageId(for: sessionId)
        if let idx = messages.firstIndex(where: { $0.id == id }) {
            var message = messages[idx]
            if let segmentIndex = message.segments.lastIndex(where: { $0.kind == .text }) {
                message.segments[segmentIndex].text = (message.segments[segmentIndex].text ?? "") + text
            } else {
                message.segments.append(ChatMessageSegment(kind: .text, text: text))
            }
            messages[idx] = message
        } else {
            messages.append(
                ChatMessage(
                    id: id,
                    role: .assistant,
                    segments: [ChatMessageSegment(kind: .text, text: text)]
                )
            )
        }
    }

    private func streamingAssistantMessageId(for sessionId: String) -> String {
        "streaming-assistant-\(sessionId)"
    }

    private func sortSessions(_ sessions: [ChatSessionSummary]) -> [ChatSessionSummary] {
        sessions.sorted { lhs, rhs in
            let lhsPinned = settings.isSessionPinned(lhs.id)
            let rhsPinned = settings.isSessionPinned(rhs.id)
            if lhsPinned != rhsPinned {
                return lhsPinned
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private func debugSessionFilePathURL(for session: ChatSessionSummary) -> URL {
        var components = URLComponents(url: apiClient.baseURL, resolvingAgainstBaseURL: false)
        ?? URLComponents()
        components.path = "/v1/debug/session-file-path/\(Self.urlPathEscape(agent.id))/\(Self.urlPathEscape(session.id))"
        components.queryItems = nil
        return components.url ?? apiClient.baseURL
    }

    private static func urlPathEscape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    private func displayTitle(for session: ChatSessionSummary) -> String {
        session.displayTitle.isEmpty ? "Session" : session.displayTitle
    }

    private func showSessionStatus(_ status: String) {
        sessionActionStatus = status
    }

    private func sendMessage(agentId: String, sessionId: String, content: String) {
        guard !isSending else { return }
        isSending = true

        let optimisticId = "optimistic-user-\(UUID().uuidString)"
        let optimistic = ChatMessage(
            id: optimisticId,
            role: .user,
            segments: [ChatMessageSegment(kind: .text, text: content)]
        )
        messages.append(optimistic)

        Task { @MainActor in
            _ = try? await apiClient.postSessionMessage(
                agentId: agentId,
                sessionId: sessionId,
                content: content
            )
            isSending = false
        }
    }
}

private struct AgentChatSessionRow: View {
    let session: ChatSessionSummary
    let isPinned: Bool
    let onOpen: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        let c = theme.colors

        Button(action: onOpen) {
            HStack(spacing: 14) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 16))
                    .foregroundStyle(c.textMuted)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(session.displayTitle.isEmpty ? "Untitled chat" : session.displayTitle)
                            .font(.body.weight(.medium))
                            .foregroundStyle(c.textPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if isPinned {
                            Image(systemName: "pin.fill")
                                .font(.caption2)
                                .foregroundStyle(c.textMuted)
                                .accessibilityLabel("Pinned")
                        }
                    }
                    Text(session.messageCount == 1 ? "1 message" : "\(session.messageCount) messages")
                        .font(.caption)
                        .foregroundStyle(c.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(session.updatedAt, format: .dateTime.month(.abbreviated).day())
                    .font(.caption)
                    .foregroundStyle(c.textMuted)
                    .fixedSize()

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(c.textMuted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovered ? c.surfaceRaised : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityIdentifier("agent-chats.session.\(session.id)")
    }
}

struct ChatTranscriptView: View {
    let sessionId: String
    let agentId: String
    @Binding var messages: [ChatMessage]
    let composerDraft: ChatComposerDraft
    let isSending: Bool
    let onSend: (String) -> Void
    let onForkFromMessage: @MainActor @Sendable (ChatMessage) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        let c = theme.colors
        let sp = theme.spacing

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: sp.m) {
                BackButton("Sessions", action: { dismiss() })
                Spacer()
            }
            .padding(.horizontal, sp.l)
            .padding(.vertical, sp.m)

            GeometryReader { proxy in
                let contentWidth = transcriptContentWidth(for: proxy.size.width)

                ZStack(alignment: .bottom) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            if messages.isEmpty {
                                HStack {
                                    Spacer(minLength: 0)
                                    EmptyStateView("No messages yet")
                                        .padding(.vertical, sp.xl)
                                        .padding(sp.m)
                                        .padding(.bottom, composerScrollInset)
                                        .frame(width: contentWidth)
                                    Spacer(minLength: 0)
                                }
                            } else {
                                HStack {
                                    Spacer(minLength: 0)
                                    LazyVStack(alignment: .leading, spacing: sp.s) {
                                        ForEach(messages) { msg in
                                            ChatBubbleView(
                                                message: msg,
                                                isActivelyWorking: msg.id == "streaming-assistant-\(sessionId)",
                                                onForkFromMessage: onForkFromMessage
                                            )
                                                .frame(minWidth: 0, maxWidth: .infinity)
                                        }
                                    }
                                    .padding(sp.m)
                                    .padding(.bottom, composerScrollInset)
                                    .frame(width: contentWidth)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                        .onChange(of: messages.count) { oldCount, newCount in
                            guard newCount > oldCount,
                                  oldCount == 0 || proxy.isNearBottom(threshold: 220),
                                  let lastMessageId = messages.last?.id else {
                                return
                            }

                            Task { @MainActor in
                                proxy.scrollTo(lastMessageId, anchor: .bottom)
                            }
                        }
                        .onChange(of: latestAssistantMessageLayoutKey) { _, _ in
                            guard proxy.isNearBottom(threshold: 480),
                                  let lastMessage = messages.last,
                                  lastMessage.role == .assistant else {
                                return
                            }

                            Task { @MainActor in
                                proxy.scrollTo(lastMessage.id, anchor: .bottom)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(c.background)
    }

    private var composerScrollInset: CGFloat {
        ChatComposerView.panelHeight + theme.spacing.xxl
    }

    private var latestAssistantMessageLayoutKey: String {
        guard let message = messages.last,
              message.role == .assistant else {
            return ""
        }
        return "\(message.id):\(message.textContent.count)"
    }

    private func transcriptContentWidth(for availableWidth: CGFloat) -> CGFloat {
        max(0, min(availableWidth, ChatComposerView.panelWidth))
    }
}
