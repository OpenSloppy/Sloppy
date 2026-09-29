import Foundation
import Observation
import SloppyClientCore
import SloppyClientUI
import SwiftUI
import UniformTypeIdentifiers

public enum ChatComposerDictationPhase: Sendable, Equatable {
    case idle
    case recording
    case transcribing
}

public struct ChatComposerAttachment: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let mimeType: String
    public let data: Data

    public init(
        id: UUID = UUID(),
        name: String,
        mimeType: String,
        data: Data
    ) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.data = data
    }

    public var sizeBytes: Int {
        data.count
    }

    var upload: ChatAttachmentUpload {
        ChatAttachmentUpload(
            name: name,
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            contentBase64: data.base64EncodedString()
        )
    }

    var messageAttachment: ChatAttachment {
        ChatAttachment(
            id: id.uuidString.lowercased(),
            name: name,
            mimeType: mimeType,
            sizeBytes: sizeBytes
        )
    }
}

public struct ChatComposerQuote: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let text: String

    public init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }

    static func messageContent(_ content: String, quotes: [Self]) -> String {
        let quotedText = quotes.map { quote in
            quote.text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: "\n")
                .map { "> \($0)" }
                .joined(separator: "\n")
        }.joined(separator: "\n\n")
        guard !quotedText.isEmpty else { return content }
        return content.isEmpty ? quotedText : "\(quotedText)\n\n\(content)"
    }
}

private struct StoredComposerDraft {
    var text: String
    var attachments: [ChatComposerAttachment]
    var quotes: [ChatComposerQuote]
}

private enum PendingComposerTextMutation {
    case append(String)
    case replace(String)
}

struct ChatMessageSendFailurePolicy {
    static func shouldRestoreDraft(
        after error: Error,
        optimisticMessageIsPresent: Bool
    ) -> Bool {
        guard optimisticMessageIsPresent else {
            return false
        }

        if let apiError = error as? APIError,
           case .decodingFailed = apiError {
            return false
        }

        return true
    }
}

private struct SessionCatalogFetchResult: Sendable {
    var agentId: String
    var sessions: [ChatSessionSummary]?
}

struct ChatStreamingTurnTracker {
    private struct Turn {
        let sessionId: String
        let messageId: String
        var didReceiveFinalMessage = false
    }

    private var turns: [Turn] = []

    mutating func begin(sessionId: String, messageId: String) {
        turns.append(Turn(sessionId: sessionId, messageId: messageId))
    }

    func currentMessageId(for sessionId: String) -> String? {
        turns.first(where: { $0.sessionId == sessionId })?.messageId
    }

    mutating func claimFinalMessageId(for sessionId: String) -> String? {
        guard let index = turns.firstIndex(where: {
            $0.sessionId == sessionId && !$0.didReceiveFinalMessage
        }) else {
            return nil
        }
        turns[index].didReceiveFinalMessage = true
        return turns[index].messageId
    }

    @discardableResult
    mutating func completeNextTurn(for sessionId: String) -> String? {
        guard let index = turns.firstIndex(where: { $0.sessionId == sessionId }) else { return nil }
        return turns.remove(at: index).messageId
    }

    mutating func clear(sessionId: String? = nil) {
        guard let sessionId else {
            turns.removeAll()
            return
        }
        turns.removeAll { $0.sessionId == sessionId }
    }
}

struct ChatQueuedMessage: Identifiable, Equatable, Sendable {
    let id: UUID
    let content: String
    let attachments: [ChatComposerAttachment]
    let quotes: [ChatComposerQuote]

    init(
        id: UUID = UUID(),
        content: String,
        attachments: [ChatComposerAttachment],
        quotes: [ChatComposerQuote] = []
    ) {
        self.id = id
        self.content = content
        self.attachments = attachments
        self.quotes = quotes
    }

    var displayText: String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return quotes.isEmpty ? "Attachments only" : "Quoted text"
    }
}

struct ChatMessageQueue {
    private(set) var messages: [ChatQueuedMessage] = []

    var isEmpty: Bool { messages.isEmpty }

    @discardableResult
    mutating func enqueue(
        content: String,
        attachments: [ChatComposerAttachment],
        quotes: [ChatComposerQuote] = []
    ) -> ChatQueuedMessage {
        let message = ChatQueuedMessage(content: content, attachments: attachments, quotes: quotes)
        messages.append(message)
        return message
    }

    mutating func dequeue() -> ChatQueuedMessage? {
        guard !messages.isEmpty else { return nil }
        return messages.removeFirst()
    }

    mutating func cancel(id: UUID) {
        messages.removeAll { $0.id == id }
    }
}

@Observable
@MainActor
public final class ChatTranscriptState {
    private static let initialVisibleWindowSize = 64
    private static let revealStep = 64

    private var allMessages: [ChatMessage] = []
    private var visibleStartIndex = 0

    public private(set) var messages: [ChatMessage] = []
    private(set) var entries: [ChatTranscriptEntry] = []
    private(set) var renderRevision: UInt = 0
    private(set) var identityRevision: UInt = 0

    var isEmpty: Bool {
        allMessages.isEmpty
    }

    var lastMessage: ChatMessage? {
        allMessages.last
    }

    var hasEarlierMessages: Bool {
        visibleStartIndex > 0
    }

    var hiddenMessageCount: Int {
        visibleStartIndex
    }

    func replaceAll(_ newMessages: [ChatMessage]) {
        allMessages = newMessages
        visibleStartIndex = max(0, newMessages.count - Self.initialVisibleWindowSize)
        refreshVisibleMessages()
    }

    func reconcile(with newMessages: [ChatMessage]) {
        guard !allMessages.isEmpty else {
            replaceAll(newMessages)
            return
        }

        var reconciledMessages = allMessages
        for message in newMessages {
            if let index = reconciledMessages.firstIndex(where: { $0.id == message.id }) {
                reconciledMessages[index] = message
                continue
            }

            let insertionIndex = reconciledMessages.firstIndex {
                $0.createdAt > message.createdAt
            } ?? reconciledMessages.endIndex
            reconciledMessages.insert(message, at: insertionIndex)
        }

        allMessages = reconciledMessages
        visibleStartIndex = min(visibleStartIndex, max(0, allMessages.count - 1))
        refreshVisibleMessages()
    }

    func clear() {
        allMessages = []
        visibleStartIndex = 0
        messages = []
        entries = []
        renderRevision &+= 1
        identityRevision &+= 1
    }

    func append(_ message: ChatMessage) {
        allMessages.append(message)
        refreshVisibleMessages()
    }

    func removeAll(where shouldBeRemoved: (ChatMessage) -> Bool) {
        allMessages.removeAll(where: shouldBeRemoved)
        visibleStartIndex = min(visibleStartIndex, allMessages.count)
        refreshVisibleMessages()
    }

    func upsert(_ message: ChatMessage, before anchorMessageId: String? = nil) {
        if let idx = allMessages.firstIndex(where: { $0.id == message.id }) {
            allMessages[idx] = message
        } else if let anchorMessageId,
                  let anchorIndex = allMessages.firstIndex(where: { $0.id == anchorMessageId }) {
            allMessages.insert(message, at: anchorIndex)
        } else {
            allMessages.append(message)
        }
        refreshVisibleMessages()
    }

    func replaceStreamingAssistant(messageId: String, with message: ChatMessage) {
        if let idx = allMessages.firstIndex(where: { $0.id == messageId }) {
            allMessages[idx] = message
        } else if let idx = allMessages.firstIndex(where: { $0.id == message.id }) {
            allMessages[idx] = message
        } else {
            allMessages.append(message)
        }
        refreshVisibleMessages()
    }

    func appendStreamingAssistantText(_ text: String, messageId: String) {
        if let messageIndex = allMessages.lastIndex(where: { $0.id == messageId }) {
            var message = allMessages[messageIndex]
            if let segmentIndex = message.segments.lastIndex(where: { $0.kind == .text }) {
                message.segments[segmentIndex].text = (message.segments[segmentIndex].text ?? "") + text
            } else {
                message.segments.append(ChatMessageSegment(kind: .text, text: text))
            }
            allMessages[messageIndex] = message
            // Text growth cannot change grouping or identity. Update the affected row
            // without rebuilding the transcript and all of its activity groups.
            let visibleIndex = messageIndex - visibleStartIndex
            if messages.indices.contains(visibleIndex),
               let entryIndex = entries.lastIndex(where: { $0.id == "message:\(messageId)" }),
               case .message = entries[entryIndex] {
                messages[visibleIndex] = message
                entries[entryIndex] = .message(message)
                renderRevision &+= 1
                return
            }
        } else {
            allMessages.append(
                ChatMessage(
                    id: messageId,
                    role: .assistant,
                    segments: [ChatMessageSegment(kind: .text, text: text)]
                )
            )
        }
        refreshVisibleMessages()
    }

    func revealEarlierMessages() {
        visibleStartIndex = max(0, visibleStartIndex - Self.revealStep)
        refreshVisibleMessages()
    }

    private func refreshVisibleMessages() {
        guard !allMessages.isEmpty else {
            let hadEntries = !entries.isEmpty
            messages = []
            entries = []
            visibleStartIndex = 0
            renderRevision &+= 1
            if hadEntries {
                identityRevision &+= 1
            }
            return
        }

        visibleStartIndex = max(0, min(visibleStartIndex, allMessages.count - 1))
        let visibleMessages = Array(allMessages[visibleStartIndex...])
        let nextEntries = ChatTranscriptGrouping.entries(from: visibleMessages)
        if entries.map(\.id) != nextEntries.map(\.id) {
            identityRevision &+= 1
        }
        messages = visibleMessages
        entries = nextEntries
        renderRevision &+= 1
    }
}

@Observable
@MainActor
public final class ChatScreenViewModel {
    private static let maximumAttachmentCount = 10
    private static let maximumAttachmentSize = 25 * 1_024 * 1_024

    public private(set) var agents: [APIAgentRecord] = []
    public private(set) var projects: [APIProjectRecord] = []
    public private(set) var selectedAgent: APIAgentRecord?
    public private(set) var availableModels: [ChatModelOption] = []
    public private(set) var selectedModelId: String = ""
    public private(set) var selectedReasoningEffort: ChatReasoningEffort = .default
    public private(set) var contextTokenUsage: ChatTokenUsage?
    public private(set) var semanticDecisionUsage: ChatSemanticDecisionUsage?
    public internal(set) var sessions: [ChatSessionSummary] = []
    public private(set) var sessionCatalog: [ChatSessionSummary] = []
    public var selectedSessionId: String?
    public var pinnedSessionIds: Set<String> { settings.pinnedSessionIds }
    public private(set) var activeContextTitle: String?
    public private(set) var sessionActionStatus: String?
    public private(set) var sendErrorMessage: String?
    public private(set) var isLoadingSessions = false
    public private(set) var isLoadingTranscript = false
    public private(set) var isSending = false
    public private(set) var isAwaitingAgentResponse = false
    public private(set) var isStopping = false
    public private(set) var pendingToolApproval: PendingToolApprovalRecord?
    public private(set) var isResolvingToolApproval = false
    public private(set) var toolApprovalErrorMessage: String?
    public private(set) var activeInputRequest: ChatPlanInputRequest?
    public private(set) var isSubmittingInputResponse = false
    public private(set) var inputRequestErrorMessage: String?
    public private(set) var activeRunStatus: ChatRunStatusEvent?
    private(set) var computerUseActivity: ChatComputerUseActivity?
    private(set) var isComputerUsePreviewHidden = false
    public private(set) var workingTreeSourceControl: ProjectWorkingTreeSourceControlResponse?
    public private(set) var didLoadInitialData = false
    public private(set) var transcriptScrollToEndRequest = 0
    private(set) var providerSettingsRecoveryMessageIDs: Set<String> = []
    public private(set) var composerFocusResetToken = 0
    public private(set) var composerFocusRequestToken = 0
    public private(set) var composerPanelHeight: CGFloat?
    private(set) var composerSuggestions: [ChatComposerSuggestion] = []
    private(set) var composerSuggestionSelection = ChatComposerSuggestionSelection()
    public let transcript = ChatTranscriptState()
    public let composerDraft = ChatComposerDraft()
    public private(set) var composerAttachments: [ChatComposerAttachment] = []
    public private(set) var composerQuotes: [ChatComposerQuote] = []
    private(set) var queuedMessages: [ChatQueuedMessage] = []
    public var isAttachmentPickerShown = false
    public var isCameraPickerShown = false
    public var isPhotoPickerShown = false
    public private(set) var dictationPhase: ChatComposerDictationPhase = .idle
    public private(set) var dictationLevels: [CGFloat] = Array(repeating: 0.12, count: 48)
    public private(set) var dictationDuration: TimeInterval = 0

    public var messages: [ChatMessage] {
        transcript.messages
    }

    public var modelPickerOptions: [ChatModelOption] {
        [ChatModelSelection.automaticJEVOption] + availableModels
    }

    public var isAutomaticModelSelection: Bool {
        selectedModelId == ChatModelSelection.automaticJEVId
    }

    public var isShowingDictationComposer: Bool {
        dictationPhase != .idle
    }

    func updateComposerPanelHeight(_ height: CGFloat) {
        guard height.isFinite, height > 0 else { return }
        guard composerPanelHeight.map({ abs($0 - height) > 0.5 }) ?? true else { return }
        composerPanelHeight = height
    }

    public var activeProjectIdForWorkspacePanel: String? {
        activeProjectId
    }

    public var activeWorkspaceIdForCanvas: String? {
        guard let selectedSessionId else {
            return nil
        }
        return sessions.first(where: { $0.id == selectedSessionId })?.workspaceId
    }

    public var shouldShowStopButton: Bool {
        isAwaitingAgentResponse || isStopping
    }

    public var contextUsage: ChatContextUsage? {
        let contextModelId = isAutomaticModelSelection
            ? activeRunStatus?.selectedModel ?? availableModels.first?.id
            : selectedModelId
        guard let model = availableModels.first(where: { $0.id == contextModelId }),
              let limitTokens = model.contextWindowTokens else {
            return nil
        }
        return ChatContextUsage(
            usedTokens: contextTokenUsage?.total ?? 0,
            limitTokens: limitTokens,
            semanticDecisionUsage: semanticDecisionUsage
        )
    }

    public var canSubmitMessage: Bool {
        selectedAgent != nil
            && activeInputRequest == nil
    }

    public var activeRunStatusLabel: String {
        ChatRunStatusPresentation.label(
            status: activeRunStatus,
            isStopping: isStopping,
            isSending: isSending,
            isAutomaticModelSelection: isAutomaticModelSelection,
            availableModels: availableModels
        )
    }

    public var activeRunStatusDetails: String? {
        activeRunStatus?.details?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func hideComputerUsePreview() {
        isComputerUsePreviewHidden = true
    }

    public var activeSessionTitle: String {
        guard let selectedSessionId else {
            return activeContextTitle ?? "New chat"
        }
        return sessions.first(where: { $0.id == selectedSessionId })?.title
            ?? activeContextTitle
            ?? "Session \(selectedSessionId.prefix(8))"
    }

    public var activeProjectNameForWorkspacePanel: String? {
        guard let projectId = activeProjectId else { return nil }
        if let project = projects.first(where: { $0.id == projectId }) {
            return project.name
        }
        guard selectedSessionId == nil else { return nil }
        guard let title = activeContextTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return nil
        }
        if title.hasPrefix("Project: ") {
            return String(title.dropFirst("Project: ".count))
        }
        if let slashRange = title.range(of: " / ") {
            return String(title[..<slashRange.lowerBound])
        }
        return nil
    }

    @ObservationIgnored private let apiClient: SloppyAPIClient
    @ObservationIgnored private let cacheStore: ClientCacheStore
    @ObservationIgnored private let settings: ClientSettings
    @ObservationIgnored private let restoresLastSession: Bool
    @ObservationIgnored private let loadsGlobalSessionCatalog: Bool
    @ObservationIgnored private let onSessionSummaryChange: @MainActor (ChatSessionSummary) -> Void
    @ObservationIgnored private let onPlanArtifact: @MainActor (ChatPlanArtifactPresentation) -> Void
    @ObservationIgnored private let responseNotificationScheduler: any AgentResponseNotificationScheduling
    public let connectionMonitor: ConnectionMonitor
    @ObservationIgnored private let onOpenSettings: @MainActor (ClientSettingsDestination) -> Void

    @ObservationIgnored private var socketManager: SessionSocketManager?
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var sessionStatusTask: Task<Void, Never>?
    @ObservationIgnored private var streamingFlushTask: Task<Void, Never>?
    @ObservationIgnored private var pendingStreamingSessionId: String?
    @ObservationIgnored private var pendingStreamingAssistantMessageId: String?
    @ObservationIgnored private var pendingStreamingAssistantText: String?
    @ObservationIgnored private var pendingStreamingTextUpdateMode: StreamingTextUpdateMode?
    @ObservationIgnored private var streamingTurnTracker = ChatStreamingTurnTracker()
    @ObservationIgnored private var pendingNavigationRequest: ChatNavigationRequest?
    @ObservationIgnored private var pendingSessionSummary: ChatSessionSummary?
    @ObservationIgnored private var lastAppliedNavigationRequestId: Int?
    @ObservationIgnored private var activeProjectId: String?
    @ObservationIgnored private var activeTaskId: String?
    @ObservationIgnored private var isLoadingInitialData = false
    @ObservationIgnored private var initialDataTask: Task<Void, Never>?
    @ObservationIgnored private var sessionLoadGeneration = 0
    @ObservationIgnored private var composerDraftsByKey: [String: StoredComposerDraft] = [:]
    @ObservationIgnored private var activeComposerDraftKey: String?
    @ObservationIgnored private var pendingComposerTextMutation: PendingComposerTextMutation?
    @ObservationIgnored private var pendingComposerQuotes: [ChatComposerQuote] = []
    @ObservationIgnored private let dictationRecorder = DictationRecorder()
    @ObservationIgnored private var dictationMeterTask: Task<Void, Never>?
    @ObservationIgnored private var suggestionTask: Task<Void, Never>?
    @ObservationIgnored private var workingTreeSourceControlTask: Task<Void, Never>?
    @ObservationIgnored private var isForkingSession = false
    @ObservationIgnored private var composerSuggestionCursorOffset: Int?
    @ObservationIgnored private var composerSuggestionRequestID: UInt = 0
    @ObservationIgnored private var presentedPlanArtifactEventIDs: Set<String> = []
    @ObservationIgnored private var messageQueue = ChatMessageQueue()
    @ObservationIgnored private var isDrainingQueuedMessages = false
    @ObservationIgnored private var queuedMessageInterruptRequested = false
    @ObservationIgnored private var resolvedToolApprovalIDs: Set<String> = []
    @ObservationIgnored private let modelPreferences: ChatModelPreferenceStore

    public init(
        apiClient: SloppyAPIClient,
        cacheStore: ClientCacheStore = ClientCacheStore(),
        settings: ClientSettings,
        connectionMonitor: ConnectionMonitor,
        modelPreferences: ChatModelPreferenceStore = ChatModelPreferenceStore(),
        restoresLastSession: Bool = true,
        loadsGlobalSessionCatalog: Bool = false,
        onSessionSummaryChange: @escaping @MainActor (ChatSessionSummary) -> Void = { _ in },
        onPlanArtifact: @escaping @MainActor (ChatPlanArtifactPresentation) -> Void = { _ in },
        responseNotificationScheduler: any AgentResponseNotificationScheduling = LocalAgentResponseNotificationScheduler.shared,
        onOpenSettings: @escaping @MainActor (ClientSettingsDestination) -> Void
    ) {
        self.apiClient = apiClient
        self.cacheStore = cacheStore
        self.settings = settings
        self.connectionMonitor = connectionMonitor
        self.modelPreferences = modelPreferences
        self.restoresLastSession = restoresLastSession
        self.loadsGlobalSessionCatalog = loadsGlobalSessionCatalog
        self.onSessionSummaryChange = onSessionSummaryChange
        self.onPlanArtifact = onPlanArtifact
        self.responseNotificationScheduler = responseNotificationScheduler
        self.onOpenSettings = onOpenSettings
    }

    public func openSettings(_ destination: ClientSettingsDestination = .general) {
        onOpenSettings(destination)
    }

    public func dismissComposerFocus() {
        composerFocusResetToken += 1
    }

    public func requestComposerFocus() {
        composerFocusRequestToken += 1
    }

    public func requestTranscriptScrollToEnd() {
        transcriptScrollToEndRequest &+= 1
    }

    func updateComposerSuggestions(for text: String, cursorOffset: Int? = nil) {
        suggestionTask?.cancel()
        composerSuggestionCursorOffset = cursorOffset
        composerSuggestionRequestID &+= 1
        let requestID = composerSuggestionRequestID
        guard let query = ChatComposerQuery.parse(text, cursorOffset: cursorOffset),
              let agent = selectedAgent else {
            setComposerSuggestions([])
            return
        }

        suggestionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let suggestions = await loadComposerSuggestions(query: query, agentId: agent.id)
            guard !Task.isCancelled, composerSuggestionRequestID == requestID else { return }
            setComposerSuggestions(suggestions)
        }
    }

    @discardableResult
    func moveComposerSuggestionSelection(_ direction: ChatComposerSuggestionSelectionDirection) -> Bool {
        composerSuggestionSelection.move(direction, in: composerSuggestions)
    }

    @discardableResult
    func applySelectedComposerSuggestion() -> Bool {
        guard let suggestion = composerSuggestionSelection.selectedSuggestion(in: composerSuggestions) else {
            return false
        }
        applyComposerSuggestion(suggestion)
        return true
    }

    func applyComposerSuggestion(_ suggestion: ChatComposerSuggestion) {
        guard let query = ChatComposerQuery.parse(
            composerDraft.text,
            cursorOffset: composerSuggestionCursorOffset
        ) else { return }
        let application = query.applying(suggestion, to: composerDraft.text)
        composerDraft.text = application.text
        let insertionPoint = composerDraft.text.index(
            composerDraft.text.startIndex,
            offsetBy: application.cursorOffset
        )
        composerDraft.selection = TextSelection(insertionPoint: insertionPoint)
        setComposerSuggestions([])
    }

    private func setComposerSuggestions(_ suggestions: [ChatComposerSuggestion]) {
        composerSuggestions = suggestions
        composerSuggestionSelection.reconcile(with: suggestions)
    }

    private func loadComposerSuggestions(query: ChatComposerQuery, agentId: String) async -> [ChatComposerSuggestion] {
        switch query.trigger {
        case "/":
            let response = try? await apiClient.fetchChatSlashCommands(agentId: agentId)
            return filterCommands(response?.commands ?? [], query: query.term, skillsOnly: false)
        case "@":
            async let commands = try? await apiClient.fetchChatSlashCommands(agentId: agentId)
            async let files = loadProjectFiles(matching: query.term, projectId: activeProjectId)
            let skillItems = filterCommands((await commands)?.commands ?? [], query: query.term, skillsOnly: true)
            return Array(((await files) + skillItems).prefix(12))
        case "#":
            guard let projectId = activeProjectId,
                  let project = try? await apiClient.fetchProject(id: projectId) else { return [] }
            return (project.tasks ?? [])
                .filter { matches(query.term, in: $0.title) || matches(query.term, in: $0.id) }
                .prefix(12)
                .map {
                    ChatComposerSuggestion(
                        id: "task:\($0.id)", kind: .task, title: $0.title,
                        subtitle: $0.status.replacingOccurrences(of: "_", with: " "), insertion: "#\($0.id)"
                    )
                }
        default:
            return []
        }
    }

    private func filterCommands(
        _ commands: [AgentChatSlashCommandItem],
        query: String,
        skillsOnly: Bool
    ) -> [ChatComposerSuggestion] {
        commands
            .filter { !skillsOnly || $0.source == "skill" }
            .filter { matches(query, in: $0.name) || matches(query, in: $0.description) }
            .prefix(12)
            .map {
                let isSkill = $0.source == "skill"
                let prefix = skillsOnly ? "@" : "/"
                return ChatComposerSuggestion(
                    id: "\($0.source):\($0.skillId ?? $0.name)",
                    kind: isSkill ? .skill : .command,
                    title: prefix + $0.name,
                    subtitle: $0.description,
                    insertion: prefix + $0.name
                )
            }
    }

    private func loadProjectFiles(
        matching query: String,
        projectId: String?
    ) async -> [ChatComposerSuggestion] {
        guard let projectId else { return [] }

        do {
            return try await apiClient.searchProjectFiles(
                projectId: projectId,
                query: query,
                limit: 50
            )
            .filter { $0.type == .file }
            .map { projectFileSuggestion(path: $0.path) }
        } catch let error as APIError where error.statusCode == 404 {
            return await loadProjectFilesByWalking(matching: query, projectId: projectId)
        } catch {
            return []
        }
    }

    private func loadProjectFilesByWalking(
        matching query: String,
        projectId: String
    ) async -> [ChatComposerSuggestion] {
        var pending = [""]
        var results: [ChatComposerSuggestion] = []
        var visitedDirectoryCount = 0
        while let directory = pending.popLast(),
              results.count < 12,
              visitedDirectoryCount < 500,
              !Task.isCancelled {
            visitedDirectoryCount += 1
            guard let entries = try? await apiClient.fetchProjectFiles(projectId: projectId, path: directory) else { continue }
            for entry in entries {
                let path = directory.isEmpty ? entry.name : "\(directory)/\(entry.name)"
                if entry.type == .directory {
                    pending.append(path)
                } else if matches(query, in: path) {
                    results.append(projectFileSuggestion(path: path))
                    if results.count == 12 { break }
                }
            }
        }
        return results
    }

    private func projectFileSuggestion(path: String) -> ChatComposerSuggestion {
        ChatComposerSuggestion(
            id: "file:\(path)",
            kind: .file,
            title: path,
            subtitle: "Project file",
            insertion: "@\(path)"
        )
    }

    private func matches(_ query: String, in value: String) -> Bool {
        query.isEmpty || value.localizedCaseInsensitiveContains(query)
    }

    public func loadInitialData() {
        guard !didLoadInitialData, initialDataTask == nil else { return }

        initialDataTask = Task { @MainActor [weak self] in
            await self?.performInitialDataLoad()
        }
    }

    public func waitForInitialData() async {
        loadInitialData()
        let task = initialDataTask
        await task?.value
    }

    private func performInitialDataLoad() async {
        guard !didLoadInitialData, !isLoadingInitialData else { return }

        isLoadingInitialData = true
        await restoreInitialDataFromCache()

        // Cached data is enough to render the workspace. Network refreshes
        // continue after this flag releases the initial loading screen.
        didLoadInitialData = true

        await revalidateInitialData()
        isLoadingInitialData = false
        initialDataTask = nil
    }

    public func installAggregatedSessionCatalog(_ sessions: [ChatSessionSummary]) {
        sessionLoadGeneration += 1
        isLoadingSessions = false
        sessionCatalog = sortSessions(
            ChatSessionCatalog.mergeAggregated(existing: sessionCatalog, incoming: sessions)
        )
    }

    public func removeSessionFromCatalog(_ session: ChatSessionSummary) {
        sessionCatalog.removeAll { $0.storageID == session.storageID }
    }

    public func loadSessions(for agent: APIAgentRecord, projectId: String? = nil) async {
        sessionLoadGeneration += 1
        let generation = sessionLoadGeneration
        isLoadingSessions = true

        let cached = await cacheStore.loadSessions(agentId: agent.id, projectId: projectId)
        guard generation == sessionLoadGeneration else { return }
        sessions = sortSessions(cached.filter { $0.kind != "heartbeat" })

        do {
            let fetched = try await apiClient.fetchAgentSessions(agentId: agent.id, projectId: projectId)
            guard generation == sessionLoadGeneration else { return }
            let filtered = fetched.filter { $0.kind != "heartbeat" }
            sessions = sortSessions(filtered)
            await cacheStore.cacheSessions(agentId: agent.id, projectId: projectId, sessions: filtered)
        } catch {
            // Keep the cached snapshot visible while offline.
        }

        if generation == sessionLoadGeneration {
            isLoadingSessions = false
        }
    }

    private func loadSessionCatalog(for agents: [APIAgentRecord]) async {
        sessionLoadGeneration += 1
        let generation = sessionLoadGeneration
        isLoadingSessions = true

        var cachedBatches: [[ChatSessionSummary]] = []
        for agent in agents {
            cachedBatches.append(await cacheStore.loadSessions(agentId: agent.id))
        }
        guard generation == sessionLoadGeneration else { return }
        sessionCatalog = sortSessions(ChatSessionCatalog.merge(cachedBatches))

        let apiClient = apiClient
        let results = await withTaskGroup(
            of: SessionCatalogFetchResult.self,
            returning: [SessionCatalogFetchResult].self
        ) { group in
            for agent in agents {
                group.addTask {
                    SessionCatalogFetchResult(
                        agentId: agent.id,
                        sessions: try? await apiClient.fetchAgentSessions(agentId: agent.id)
                    )
                }
            }

            var results: [SessionCatalogFetchResult] = []
            for await result in group {
                results.append(result)
            }
            return results
        }

        guard generation == sessionLoadGeneration else { return }
        var batches: [[ChatSessionSummary]] = []
        for result in results {
            if let fetched = result.sessions {
                let filtered = fetched.filter { $0.kind != "heartbeat" }
                batches.append(filtered)
                await cacheStore.cacheSessions(
                    agentId: result.agentId,
                    projectId: nil,
                    sessions: filtered
                )
            } else {
                batches.append(await cacheStore.loadSessions(agentId: result.agentId))
            }
        }

        guard generation == sessionLoadGeneration else { return }
        sessionCatalog = sortSessions(ChatSessionCatalog.merge(batches))
        isLoadingSessions = false
    }

    public func refreshCurrentContext() async {
        guard let agent = selectedAgent else {
            return
        }

        if loadsGlobalSessionCatalog {
            await loadSessionCatalog(for: agents)
        }
        await loadSessions(for: agent, projectId: activeTaskId == nil ? activeProjectId : nil)

        if let selectedSessionId {
            await hydrateSession(agentId: agent.id, sessionId: selectedSessionId)
        }
    }

    private func restoreInitialDataFromCache() async {
        async let cachedAgentsRequest = cacheStore.loadAgents()
        async let cachedProjectsRequest = cacheStore.loadProjects()

        agents = await cachedAgentsRequest
        projects = await cachedProjectsRequest
        restoreLastProjectContextIfAvailable()
        await restoreInitialAgentContext(using: agents, loadsCachedSessionsOnly: true)
    }

    private func revalidateInitialData() async {
        async let agentsRequest: [APIAgentRecord]? = try? await apiClient.fetchAgents()
        async let modelsRequest: [ChatModelOption]? = try? await apiClient.fetchAvailableModels()
        async let projectsRequest: [APIProjectRecord]? = try? await apiClient.fetchProjects()

        let fetchedAgents = await agentsRequest
        let fetchedModels = await modelsRequest
        let fetchedProjects = await projectsRequest

        if let fetchedAgents {
            agents = fetchedAgents
            await cacheStore.cacheAgents(fetchedAgents)
        }
        if let fetchedModels {
            applyAvailableModels(fetchedModels)
        }
        if let fetchedProjects {
            projects = fetchedProjects
            await cacheStore.cacheProjects(fetchedProjects)
            restoreLastProjectContextIfAvailable()
        }

        await restoreInitialAgentContext(using: agents, loadsCachedSessionsOnly: false)
    }

    private func restoreInitialAgentContext(
        using availableAgents: [APIAgentRecord],
        loadsCachedSessionsOnly: Bool
    ) async {
        let preferredAgentId = selectedAgent?.id ?? settings.lastAgentId
        guard let agent = availableAgents.first(where: { $0.id == preferredAgentId })
            ?? availableAgents.first else {
            return
        }

        selectedAgent = agent
        settings.lastAgentId = agent.id
        restoreModelSelection(agentId: agent.id, sessionId: selectedSessionId)

        if loadsGlobalSessionCatalog {
            if loadsCachedSessionsOnly {
                var batches: [[ChatSessionSummary]] = []
                for availableAgent in availableAgents {
                    batches.append(await cacheStore.loadSessions(agentId: availableAgent.id))
                }
                sessionCatalog = sortSessions(ChatSessionCatalog.merge(batches))
            } else {
                await loadSessionCatalog(for: availableAgents)
            }
            sessions = sortSessions(sessionCatalog.filter {
                $0.agentId == agent.id
                    && (activeSessionProjectFilter == nil || $0.projectId == activeSessionProjectFilter)
            })
        } else if loadsCachedSessionsOnly {
            let cached = await cacheStore.loadSessions(
                agentId: agent.id,
                projectId: activeSessionProjectFilter
            )
            sessions = sortSessions(cached.filter { $0.kind != "heartbeat" })
        } else {
            await loadSessions(for: agent, projectId: activeSessionProjectFilter)
        }

        restorePendingOrLastSession(for: agent)
        if let pendingNavigationRequest {
            applyNavigationRequest(pendingNavigationRequest)
        }
    }

    private func restoreLastProjectContextIfAvailable() {
        guard activeProjectId == nil,
              activeTaskId == nil,
              selectedSessionId == nil,
              pendingNavigationRequest == nil,
              let projectId = settings.lastProjectId,
              let project = projects.first(where: { $0.id == projectId }) else {
            return
        }

        activeProjectId = project.id
        activeContextTitle = "Project: \(project.name)"
    }

    private func restorePendingOrLastSession(for agent: APIAgentRecord) {
        if let pendingSessionSummary {
            openSessionFromSummary(pendingSessionSummary)
            return
        }

        if selectedSessionId == nil,
           restoresLastSession,
           let lastSessionId = settings.lastSessionId,
           sessions.contains(where: { $0.id == lastSessionId }) {
            selectSession(lastSessionId)
            return
        }

        guard selectedSessionId == nil else { return }
        if transcript.isEmpty {
            syncComposerDraft(
                toSessionId: nil,
                projectId: activeProjectId,
                taskId: activeTaskId,
                agentId: agent.id
            )
        }
    }

    private var activeSessionProjectFilter: String? {
        activeTaskId == nil ? activeProjectId : nil
    }

    public func pickAgent(_ agent: APIAgentRecord) {
        switchAgent(agent)
    }

    public func pickModel(_ model: ChatModelOption) {
        selectedModelId = model.id
        selectedReasoningEffort = .default
        if let agentId = selectedAgent?.id {
            modelPreferences.setSelection(
                model.id,
                server: apiClient.endpoint.cacheNamespace,
                agentId: agentId,
                sessionId: selectedSessionId
            )
        }
    }

    public func pickReasoningEffort(_ effort: ChatReasoningEffort) {
        selectedReasoningEffort = effort
    }

    public func refreshAvailableModels() async {
        do {
            applyAvailableModels(try await apiClient.fetchAvailableModels())
        } catch {
            showSessionStatus("Couldn’t refresh models: \(error.localizedDescription)")
        }
    }

    public func pickSession(_ session: ChatSessionSummary) {
        openSession(session)
    }

    public func pickNewSession() {
        startNewSession()
    }

    public func startNewMessage() {
        guard let agent = selectedAgent ?? agents.first else { return }

        guard let projectId = activeProjectId else {
            activateDraft(agent: agent, contextTitle: nil)
            return
        }

        let projectName = projects.first(where: { $0.id == projectId })?.name
        let contextTitle = projectName.map { "Project: \($0)" } ?? activeContextTitle
        activateProjectContext(
            agent: agent,
            projectId: projectId,
            contextTitle: contextTitle ?? "Project",
            preferredSessionTitle: nil,
            preferredTaskId: nil,
            opensPreferredSession: false
        )
    }

    public func pickPersonal() {
        settings.lastProjectId = nil
        settings.lastSessionId = nil
        routeToBlankChat()
        requestComposerFocus()
    }

    public func pickProject(_ project: APIProjectRecord) {
        guard let agent = selectedAgent ?? agents.first else { return }
        activateProjectContext(
            agent: agent,
            projectId: project.id,
            contextTitle: "Project: \(project.name)",
            preferredSessionTitle: nil,
            preferredTaskId: nil,
            opensPreferredSession: false
        )
    }

    public func useStarterPrompt(_ prompt: String) {
        composerDraft.text = prompt
        saveActiveComposerDraft()
    }

    public func addTextSelectionToComposer(_ selectedText: String) {
        let selectedText = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedText.isEmpty else { return }

        applyComposerTextMutation(.append(selectedText))
    }

    public func addQuoteToComposer(_ selectedText: String) {
        let selectedText = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedText.isEmpty else { return }

        let quote = ChatComposerQuote(text: selectedText)
        if activeComposerDraftKey == nil {
            pendingComposerQuotes.append(quote)
        }
        composerQuotes.append(quote)
        saveActiveComposerDraft()
        requestComposerFocus()
    }

    public func removeComposerQuote(id: ChatComposerQuote.ID) {
        composerQuotes.removeAll { $0.id == id }
        pendingComposerQuotes.removeAll { $0.id == id }
        saveActiveComposerDraft()
    }

    public func insertCodeBlock() {
        let text = composerDraft.text
        let range = ChatComposerNativeSelection.nativeRange(
            from: composerDraft.selection,
            in: text
        ).flatMap { Range($0, in: text) } ?? text.endIndex..<text.endIndex
        let selectedText = String(text[range])
        let needsLeadingNewline = range.lowerBound > text.startIndex
            && text[text.index(before: range.lowerBound)] != "\n"
        let needsTrailingNewline = range.upperBound < text.endIndex
            && text[range.upperBound] != "\n"
        let leadingNewline = needsLeadingNewline ? "\n" : ""
        let trailingNewline = needsTrailingNewline ? "\n" : ""
        let replacement = "\(leadingNewline)```\n\(selectedText)\n```\(trailingNewline)"
        let cursorOffset = text.distance(from: text.startIndex, to: range.lowerBound)
            + leadingNewline.count + 4 + selectedText.count
        composerDraft.text = text.replacingCharacters(in: range, with: replacement)
        let cursor = composerDraft.text.index(composerDraft.text.startIndex, offsetBy: cursorOffset)
        composerDraft.selection = TextSelection(insertionPoint: cursor)
        saveActiveComposerDraft()
        requestComposerFocus()
    }

    public func askForMoreDetails(about selectedText: String) {
        let selectedText = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedText.isEmpty else { return }

        applyComposerTextMutation(.replace("Tell me more about this:\n\n\(selectedText)"))
    }

    private func applyComposerTextMutation(_ mutation: PendingComposerTextMutation) {
        if activeComposerDraftKey == nil {
            pendingComposerTextMutation = mutation
        }

        switch mutation {
        case .append(let text):
            composerDraft.text = composerDraft.text.isEmpty
                ? text
                : "\(composerDraft.text)\n\(text)"
        case .replace(let text):
            composerDraft.text = text
        }
        saveActiveComposerDraft()
        requestComposerFocus()
    }

    public func deleteSession(_ session: ChatSessionSummary) {
        Task { @MainActor in
            do {
                try await apiClient.deleteAgentSession(agentId: session.agentId, sessionId: session.id)
                modelPreferences.removeSession(
                    server: apiClient.endpoint.cacheNamespace,
                    agentId: session.agentId,
                    sessionId: session.id
                )
                settings.setSessionPinned(session.storageID, isPinned: false)
                sessions.removeAll { $0.storageID == session.storageID }
                sessionCatalog.removeAll { $0.storageID == session.storageID }

                if selectedSessionId == session.id {
                    disconnectCurrentSession()
                    selectedSessionId = nil
                    restoreModelSelection(agentId: session.agentId, sessionId: nil)
                    settings.lastSessionId = nil
                    transcript.clear()
                    activeContextTitle = nil
                    activeProjectId = nil
                    activeTaskId = nil
                }

                showSessionStatus("Deleted \(displayTitle(for: session))")
            } catch {
                showSessionStatus("Could not delete \(displayTitle(for: session))")
            }
        }
    }


    public func toggleSessionPinned(_ session: ChatSessionSummary) {
        let nextPinned = !settings.isSessionPinned(session.storageID)
        settings.setSessionPinned(session.storageID, isPinned: nextPinned)
        sessions = sortSessions(sessions)
        sessionCatalog = sortSessions(sessionCatalog)
        showSessionStatus(nextPinned ? "Pinned \(displayTitle(for: session))" : "Unpinned \(displayTitle(for: session))")
    }

    public func copyDebugSessionLink(_ session: ChatSessionSummary) {
        copyDebugSessionFileLink(session)
    }

    public func copyDebugSessionFileLink(_ session: ChatSessionSummary) {
        let url = debugSessionFilePathURL(for: session)
        UIClipboard.setString(url.absoluteString)
        showSessionStatus("Copied session file debug link")
    }

    public func openSessionFromSummary(_ session: ChatSessionSummary) {
        if agents.isEmpty {
            pendingSessionSummary = session
            loadInitialData()
            return
        }

        pendingSessionSummary = nil
        openSession(session)
    }

    public func forkSession(from message: ChatMessage) {
        guard !isForkingSession,
              let agent = selectedAgent,
              let parentSessionId = selectedSessionId else {
            return
        }

        let parent = sessions.first { $0.id == parentSessionId }
        let projectId = parent?.projectId ?? activeProjectId
        let workspaceId = parent?.workspaceId
        let responseTitle = message.textContent
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String
        if let responseTitle, !responseTitle.isEmpty {
            title = "Fork: \(String(responseTitle.prefix(48)))"
        } else {
            title = "Fork of \(activeSessionTitle)"
        }

        isForkingSession = true
        sendErrorMessage = nil
        Task { @MainActor in
            defer { isForkingSession = false }
            do {
                let summary = try await apiClient.createAgentSession(
                    agentId: agent.id,
                    title: title,
                    parentSessionId: parentSessionId,
                    projectId: projectId,
                    workspaceId: workspaceId
                )
                upsertSessionSummary(summary)
                selectSession(
                    summary.id,
                    contextTitle: displayTitle(for: summary),
                    projectId: projectId
                )
            } catch {
                sendErrorMessage = "Could not fork session: \(error.localizedDescription)"
            }
        }
    }

    public func attachProjectFileReference(projectId: String, path: String, type: String) {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return }

        let reference = type == "directory"
            ? "@project[\(projectId)]:dir:\(trimmedPath)"
            : "@project[\(projectId)]:file:\(trimmedPath)"
        composerDraft.text = composerDraft.text.isEmpty
            ? reference
            : "\(composerDraft.text)\n\(reference)"
        saveActiveComposerDraft()
    }

    public func attachFileURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let maximumAttachmentSize = Self.maximumAttachmentSize
        Task { @MainActor in
            let results = await Task.detached(priority: .userInitiated) {
                urls.map { url in
                    Self.loadAttachmentResult(
                        from: url,
                        maximumSize: maximumAttachmentSize
                    )
                }
            }.value

            for result in results {
                acceptAttachmentLoadResult(result)
            }
        }
    }

    public func attachData(_ data: Data, suggestedName: String, mimeType: String) {
        guard composerAttachments.count < Self.maximumAttachmentCount else {
            sendErrorMessage = "You can attach up to \(Self.maximumAttachmentCount) files"
            return
        }
        guard data.count <= Self.maximumAttachmentSize else {
            sendErrorMessage = "\(suggestedName) is larger than 25 MB"
            return
        }

        let trimmedName = suggestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMIMEType = mimeType.trimmingCharacters(in: .whitespacesAndNewlines)
        composerAttachments.append(
            ChatComposerAttachment(
                name: trimmedName.isEmpty ? "Attachment" : trimmedName,
                mimeType: trimmedMIMEType.isEmpty ? "application/octet-stream" : trimmedMIMEType,
                data: data
            )
        )
        sendErrorMessage = nil
        saveActiveComposerDraft()
    }

    public func removeComposerAttachment(id: ChatComposerAttachment.ID) {
        composerAttachments.removeAll { $0.id == id }
        saveActiveComposerDraft()
    }

    @discardableResult
    public func attachItemProviders(_ providers: [NSItemProvider]) -> Bool {
        var didAcceptProvider = false
        let maximumAttachmentSize = Self.maximumAttachmentSize

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                didAcceptProvider = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
                    guard let url = Self.fileURL(from: item) else { return }
                    let result = Self.loadAttachmentResult(
                        from: url,
                        maximumSize: maximumAttachmentSize
                    )
                    Task { @MainActor [weak self] in
                        self?.acceptAttachmentLoadResult(result)
                    }
                }
                continue
            }

            let registeredTypes = provider.registeredTypeIdentifiers.compactMap(UTType.init)
            if let directoryType = registeredTypes.first(where: { $0.conforms(to: .directory) }) {
                didAcceptProvider = true
                provider.loadFileRepresentation(forTypeIdentifier: directoryType.identifier) { [weak self] url, _ in
                    guard let url else { return }
                    let result = Self.loadAttachmentResult(
                        from: url,
                        maximumSize: maximumAttachmentSize
                    )
                    Task { @MainActor [weak self] in
                        self?.acceptAttachmentLoadResult(result)
                    }
                }
                continue
            }

            guard let contentType = registeredTypes.first(where: { $0.conforms(to: .image) })
                ?? registeredTypes.first(where: ChatComposerPasteboard.isAttachmentType)
                ?? registeredTypes.first(where: { $0.conforms(to: .data) || $0.conforms(to: .url) }) else {
                continue
            }

            didAcceptProvider = true
            let suggestedName = Self.suggestedAttachmentName(
                providerName: provider.suggestedName,
                contentType: contentType
            )
            provider.loadDataRepresentation(forTypeIdentifier: contentType.identifier) { [weak self] data, _ in
                guard let data else {
                    Task { @MainActor in
                        self?.sendErrorMessage = "Could not load dropped attachment"
                    }
                    return
                }
                Task { @MainActor in
                    if contentType.conforms(to: .text),
                       let text = String(data: data, encoding: .utf8),
                       let payload = WorkspacePanelDragPayload.decode(from: text) {
                        self?.attachProjectFileReference(
                            projectId: payload.projectId,
                            path: payload.path,
                            type: payload.type
                        )
                        return
                    }
                    self?.attachData(
                        data,
                        suggestedName: suggestedName,
                        mimeType: contentType.preferredMIMEType ?? "application/octet-stream"
                    )
                }
            }
        }

        return didAcceptProvider
    }

    private nonisolated static func loadAttachmentResult(
        from url: URL,
        maximumSize: Int
    ) -> ChatComposerAttachmentLoadResult {
        do {
            return .success(
                try ChatComposerAttachmentLoader.load(
                    url: url,
                    maximumSize: maximumSize
                )
            )
        } catch {
            return .failure(
                "Could not attach \(url.lastPathComponent): \(error.localizedDescription)"
            )
        }
    }

    private func acceptAttachmentLoadResult(_ result: ChatComposerAttachmentLoadResult) {
        switch result {
        case .success(let attachment):
            attachData(
                attachment.data,
                suggestedName: attachment.name,
                mimeType: attachment.mimeType
            )
        case .failure(let message):
            sendErrorMessage = message
        }
    }

    private nonisolated static func fileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }
        if let data = item as? Data,
           let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters) {
            return URL(string: value)
        }
        if let value = item as? String {
            return URL(string: value)
        }
        return nil
    }

    private nonisolated static func suggestedAttachmentName(
        providerName: String?,
        contentType: UTType
    ) -> String {
        let trimmedName = providerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedName, !trimmedName.isEmpty {
            return trimmedName
        }
        return "Attachment.\(contentType.preferredFilenameExtension ?? "bin")"
    }

    #if DEBUG
    public func downloadSession(_ session: ChatSessionSummary) {
        guard let agent = selectedAgent else { return }
        Task { @MainActor in
            do {
                let data = try await apiClient.fetchAgentSessionData(agentId: agent.id, sessionId: session.id)
                let fileURL = try saveDebugSessionData(data, session: session)
                showSessionStatus("Saved \(fileURL.lastPathComponent)")
            } catch {
                showSessionStatus("Could not save \(displayTitle(for: session))")
            }
        }
    }
    #endif

    public func applyNavigationRequest(_ request: ChatNavigationRequest?) {
        guard let request else { return }
        guard lastAppliedNavigationRequestId != request.id else { return }

        if agents.isEmpty {
            pendingNavigationRequest = request
            return
        }

        pendingNavigationRequest = nil
        lastAppliedNavigationRequestId = request.id

        switch request.context {
        case .blank:
            routeToBlankChat()
        case .project(let projectId, let projectName, _):
            routeToContext(
                request,
                projectId: projectId,
                title: "Project: \(projectName)",
                opensPreferredSession: request.opensPreferredSession
            )
        case .task(let projectId, let projectName, let taskId, let taskTitle, _):
            routeToContext(
                request,
                projectId: projectId,
                title: "\(projectName) / \(taskTitle)",
                preferredSessionTitle: taskTitle,
                preferredTaskId: taskId,
                opensPreferredSession: request.opensPreferredSession
            )
        }
    }

    private func switchAgent(_ agent: APIAgentRecord) {
        disconnectCurrentSession()
        saveActiveComposerDraft()
        selectedAgent = agent
        selectedSessionId = nil
        restoreModelSelection(agentId: agent.id, sessionId: nil)
        transcript.clear()
        activeContextTitle = nil
        activeProjectId = nil
        activeTaskId = nil
        settings.lastAgentId = agent.id
        settings.lastSessionId = nil
        syncComposerDraft(toSessionId: nil, projectId: nil, taskId: nil, agentId: agent.id)
        Task { @MainActor in
            await loadSessions(for: agent)
        }
    }

    private func startNewSession() {
        guard let agent = selectedAgent else { return }
        disconnectCurrentSession()
        let contextTitle = activeContextTitle
        let projectId = activeProjectId
        let taskId = activeTaskId
        saveActiveComposerDraft()
        transcript.clear()
        selectedSessionId = nil
        restoreModelSelection(agentId: agent.id, sessionId: nil)
        activeContextTitle = contextTitle
        activeProjectId = projectId
        activeTaskId = taskId
        syncComposerDraft(toSessionId: nil, projectId: projectId, taskId: taskId, agentId: agent.id)
        Task { @MainActor in
            let sessionTitle = taskId.map(taskSessionTitle(for:))
            guard let summary = try? await apiClient.createAgentSession(
                agentId: agent.id,
                title: sessionTitle,
                projectId: projectId,
                taskId: taskId
            ) else { return }
            upsertSessionSummary(summary)
            selectedSessionId = summary.id
            rememberCurrentModelSelection(agentId: agent.id, sessionId: summary.id)
            settings.lastSessionId = summary.id
            await connectToSession(agentId: agent.id, sessionId: summary.id)
        }
    }

    private func openSession(_ session: ChatSessionSummary) {
        let nextAgent = agents.first {
            $0.id.caseInsensitiveCompare(session.agentId) == .orderedSame
        } ?? selectedAgent

        if let nextAgent, selectedAgent?.id != nextAgent.id {
            selectedAgent = nextAgent
            settings.lastAgentId = nextAgent.id
        }

        selectSession(
            session.id,
            contextTitle: displayTitle(for: session),
            projectId: session.projectId,
            taskId: session.taskId
        )
    }

    private func selectSession(
        _ sessionId: String,
        contextTitle: String? = nil,
        projectId: String? = nil,
        taskId: String? = nil
    ) {
        guard let agent = selectedAgent else { return }
        let session = sessions.first(where: { $0.id == sessionId })
            ?? sessionCatalog.first(where: { $0.id == sessionId })
        let resolvedContextTitle = contextTitle ?? session.map(displayTitle) ?? activeContextTitle
        let resolvedProjectId = session?.projectId ?? projectId
        let resolvedTaskId = session?.taskId ?? taskId
        saveActiveComposerDraft()
        disconnectCurrentSession()
        transcript.clear()
        isLoadingTranscript = true
        selectedSessionId = sessionId
        restoreModelSelection(agentId: agent.id, sessionId: sessionId)
        rememberCurrentModelSelection(agentId: agent.id, sessionId: sessionId)
        activeContextTitle = resolvedContextTitle
        activeProjectId = resolvedProjectId
        activeTaskId = resolvedTaskId
        settings.lastSessionId = sessionId
        if let resolvedProjectId {
            settings.lastProjectId = resolvedProjectId
        }
        syncComposerDraft(
            toSessionId: sessionId,
            projectId: resolvedProjectId,
            taskId: resolvedTaskId,
            agentId: agent.id
        )
        requestTranscriptScrollToEnd()
        Task { @MainActor in
            await connectToSession(agentId: agent.id, sessionId: sessionId)
        }
    }

    private func routeToBlankChat() {
        let agent = selectedAgent ?? agents.first
        guard let agent else {
            selectedAgent = nil
            selectedSessionId = nil
            transcript.clear()
            activeContextTitle = nil
            activeProjectId = nil
            activeTaskId = nil
            return
        }

        activateDraft(agent: agent, contextTitle: nil)
    }

    private func routeToContext(
        _ request: ChatNavigationRequest,
        projectId: String,
        title: String,
        preferredSessionTitle: String? = nil,
        preferredTaskId: String? = nil,
        opensPreferredSession: Bool = true
    ) {
        let agent = agentForNavigation(request) ?? selectedAgent ?? agents.first
        guard let agent else {
            selectedAgent = nil
            selectedSessionId = nil
            transcript.clear()
            activeContextTitle = title
            activeProjectId = projectId
            activeTaskId = preferredTaskId
            return
        }

        activateProjectContext(
            agent: agent,
            projectId: projectId,
            contextTitle: title,
            preferredSessionTitle: preferredSessionTitle,
            preferredTaskId: preferredTaskId,
            opensPreferredSession: opensPreferredSession
        )
    }

    private func agentForNavigation(_ request: ChatNavigationRequest) -> APIAgentRecord? {
        guard let preferredAgentId = request.preferredAgentId else { return nil }
        return agents.first {
            $0.id.caseInsensitiveCompare(preferredAgentId) == .orderedSame
        }
    }

    private func activateDraft(agent: APIAgentRecord, contextTitle: String?) {
        disconnectCurrentSession()
        saveActiveComposerDraft()
        selectedAgent = agent
        selectedSessionId = nil
        restoreModelSelection(agentId: agent.id, sessionId: nil)
        transcript.clear()
        activeContextTitle = contextTitle
        activeProjectId = nil
        activeTaskId = nil
        settings.lastAgentId = agent.id
        settings.lastSessionId = nil
        syncComposerDraft(toSessionId: nil, projectId: nil, taskId: nil, agentId: agent.id)

        Task { @MainActor in
            await loadSessions(for: agent)
        }
    }

    private func activateProjectContext(
        agent: APIAgentRecord,
        projectId: String,
        contextTitle: String,
        preferredSessionTitle: String?,
        preferredTaskId: String?,
        opensPreferredSession: Bool = true
    ) {
        disconnectCurrentSession()
        saveActiveComposerDraft()
        selectedAgent = agent
        selectedSessionId = nil
        restoreModelSelection(agentId: agent.id, sessionId: nil)
        transcript.clear()
        activeContextTitle = contextTitle
        activeProjectId = projectId
        activeTaskId = preferredTaskId
        settings.lastAgentId = agent.id
        settings.lastProjectId = projectId
        settings.lastSessionId = nil
        syncComposerDraft(
            toSessionId: nil,
            projectId: projectId,
            taskId: preferredTaskId,
            agentId: agent.id
        )

        Task { @MainActor in
            await loadSessions(for: agent, projectId: preferredTaskId == nil ? projectId : nil)
            guard selectedAgent?.id == agent.id,
                  activeProjectId == projectId,
                  selectedSessionId == nil else {
                return
            }

            guard opensPreferredSession else {
                return
            }

            guard let session = preferredSession(
                in: sessions,
                title: preferredSessionTitle,
                taskId: preferredTaskId,
                projectId: projectId,
                allowsFallback: preferredTaskId == nil
            ) else {
                return
            }

            selectSession(session.id, contextTitle: contextTitle, projectId: projectId, taskId: preferredTaskId)
        }
    }

    private func disconnectCurrentSession() {
        cancelDictationIfNeeded()
        let manager = socketManager
        streamTask?.cancel()
        streamTask = nil
        cancelPendingStreamingAssistantText()
        clearActiveStreamingAssistantTurn()
        socketManager = nil
        isAwaitingAgentResponse = false
        isStopping = false
        isLoadingTranscript = false
        activeInputRequest = nil
        isSubmittingInputResponse = false
        inputRequestErrorMessage = nil
        pendingToolApproval = nil
        toolApprovalErrorMessage = nil
        activeRunStatus = nil
        contextTokenUsage = nil
        semanticDecisionUsage = nil
        computerUseActivity = nil
        isComputerUsePreviewHidden = false
        clearWorkingTreeSourceControl()
        messageQueue = ChatMessageQueue()
        queuedMessages = []
        queuedMessageInterruptRequested = false
        resolvedToolApprovalIDs = []
        if let manager {
            Task { await manager.disconnect() }
        }
    }

    private func connectToSession(agentId: String, sessionId: String) async {
        guard isCurrentSession(agentId: agentId, sessionId: sessionId) else { return }
        defer {
            if isCurrentSession(agentId: agentId, sessionId: sessionId) {
                isLoadingTranscript = false
            }
        }

        if let cached = await cacheStore.loadSessionDetail(agentId: agentId, sessionId: sessionId) {
            guard isCurrentSession(agentId: agentId, sessionId: sessionId) else { return }
            applyHydratedSession(cached)
        }

        let manager = SessionSocketManager(endpoint: apiClient.endpoint, agentId: agentId, sessionId: sessionId)
        socketManager = manager
        // Start the socket before yielding back to callers that may immediately
        // POST a prompt into a newly-created session.
        let stream = await manager.connect()

        await hydrateSession(agentId: agentId, sessionId: sessionId)
        guard isCurrentSession(agentId: agentId, sessionId: sessionId) else {
            await manager.disconnect()
            return
        }

        streamTask = Task { @MainActor in
            defer {
                Task { await manager.disconnect() }
            }

            for await update in stream {
                guard isCurrentSession(agentId: agentId, sessionId: sessionId) else { return }
                await handleStreamUpdate(update, agentId: agentId, sessionId: sessionId)
            }
        }
    }

    private func hydrateSession(agentId: String, sessionId: String) async {
        if transcript.isEmpty,
           let cached = await cacheStore.loadSessionDetail(agentId: agentId, sessionId: sessionId) {
            guard isCurrentSession(agentId: agentId, sessionId: sessionId) else { return }
            applyHydratedSession(cached)
        }

        guard let detail = try? await apiClient.fetchAgentSession(agentId: agentId, sessionId: sessionId) else {
            return
        }
        guard isCurrentSession(agentId: agentId, sessionId: sessionId) else { return }
        applyHydratedSession(detail)
        await refreshPendingToolApproval(agentId: agentId, sessionId: sessionId)
        await refreshSemanticDecisionUsage(agentId: agentId, sessionId: sessionId)
        await cacheStore.cacheSessionDetail(agentId: agentId, detail: detail)
    }

    private func applyHydratedSession(_ detail: ChatSessionDetail) {
        transcript.reconcile(with: detail.messages)
        if let runStatus = detail.latestRunStatus {
            handleRunStatus(runStatus, sessionId: detail.summary.id)
        } else {
            refreshWorkingTreeSourceControl()
        }
        let previousInputRequestID = activeInputRequest?.id
        activeInputRequest = detail.pendingInputRequest
        if activeInputRequest?.id != previousInputRequestID {
            inputRequestErrorMessage = nil
        }
        if activeInputRequest != nil {
            isAwaitingAgentResponse = false
        }
        for presentation in detail.planArtifactPresentations {
            presentPlanArtifactIfNeeded(presentation)
        }
    }

    private func presentPlanArtifactIfNeeded(_ presentation: ChatPlanArtifactPresentation) {
        guard presentedPlanArtifactEventIDs.insert(presentation.eventID).inserted else { return }
        onPlanArtifact(presentation)
    }

    private func handleStreamUpdate(
        _ update: ChatStreamUpdate,
        agentId: String,
        sessionId: String
    ) async {
        switch update.kind {
        case .sessionReady:
            await hydrateSession(agentId: agentId, sessionId: sessionId)
        case .sessionEvent, .sessionDelta:
            if update.kind == .sessionDelta, let text = update.messageText {
                scheduleStreamingAssistantText(text, sessionId: sessionId, mode: .append)
            } else if let msg = update.message {
                upsertMessage(msg, sessionId: sessionId)
                updateComputerUseActivity(from: msg)
            }
            if let runStatus = update.streamEvent?.runStatus {
                handleRunStatus(runStatus, sessionId: sessionId)
                if runStatus.selectedModel != nil {
                    await refreshSemanticDecisionUsage(agentId: agentId, sessionId: sessionId)
                }
            }
            if let inputRequest = update.streamEvent?.inputRequest {
                flushPendingStreamingAssistantText()
                streamingTurnTracker.completeNextTurn(for: sessionId)
                activeInputRequest = inputRequest
                inputRequestErrorMessage = nil
                isAwaitingAgentResponse = false
                isStopping = false
            }
            if let inputResponse = update.streamEvent?.inputResponse,
               inputResponse.requestId == activeInputRequest?.id {
                activeInputRequest = nil
                inputRequestErrorMessage = nil
            }
        case .sessionClosed, .sessionError:
            isAwaitingAgentResponse = false
            isStopping = false
            activeRunStatus = nil
            flushPendingStreamingAssistantText()
            streamingTurnTracker.clear(sessionId: sessionId)
            refreshWorkingTreeSourceControl()
        case .heartbeat:
            break
        }
    }

    private func isCurrentSession(agentId: String, sessionId: String) -> Bool {
        selectedAgent?.id == agentId && selectedSessionId == sessionId
    }

    private func upsertMessage(_ message: ChatMessage, sessionId: String) {
        let isAssistantResponse = message.role == .assistant
            && message.segments.contains(where: { $0.kind == .text })

        if isAssistantResponse {
            cancelPendingStreamingAssistantText(for: sessionId)
            if let streamingMessageId = streamingTurnTracker.claimFinalMessageId(for: sessionId) {
                transcript.replaceStreamingAssistant(
                    messageId: streamingMessageId,
                    with: message
                )
            } else {
                transcript.upsert(message)
            }
            return
        } else if message.role == .user {
            transcript.removeAll { $0.id.hasPrefix("optimistic-user-") }
        }

        transcript.upsert(
            message,
            before: currentStreamingAssistantMessageId(for: sessionId)
        )
    }

    private func updateComputerUseActivity(from message: ChatMessage) {
        let previousActivity = computerUseActivity
        computerUseActivity = ChatComputerUseEventReducer.reduce(
            current: computerUseActivity,
            message: message
        )
        if previousActivity == nil, computerUseActivity != nil {
            isComputerUsePreviewHidden = false
        }
    }

    private enum StreamingTextUpdateMode {
        case append
        case replace
    }

    private func scheduleStreamingAssistantText(
        _ text: String,
        sessionId: String,
        mode: StreamingTextUpdateMode
    ) {
        guard !text.isEmpty else { return }
        let messageId = ensureActiveStreamingAssistantTurn(for: sessionId)
        if let pendingMessageId = pendingStreamingAssistantMessageId,
           pendingMessageId != messageId {
            flushPendingStreamingAssistantText()
        }
        pendingStreamingSessionId = sessionId
        pendingStreamingAssistantMessageId = messageId
        isAwaitingAgentResponse = true
        switch mode {
        case .append:
            pendingStreamingAssistantText = (pendingStreamingAssistantText ?? "") + text
            if pendingStreamingTextUpdateMode != .replace {
                pendingStreamingTextUpdateMode = .append
            }
        case .replace:
            pendingStreamingAssistantText = text
            pendingStreamingTextUpdateMode = .replace
        }

        guard streamingFlushTask == nil else {
            return
        }

        streamingFlushTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 33_000_000)
            guard !Task.isCancelled else { return }
            flushPendingStreamingAssistantText()
        }
    }

    private func flushPendingStreamingAssistantText() {
        streamingFlushTask?.cancel()
        streamingFlushTask = nil
        guard pendingStreamingSessionId != nil,
              let messageId = pendingStreamingAssistantMessageId,
              let text = pendingStreamingAssistantText,
              let mode = pendingStreamingTextUpdateMode else {
            streamingFlushTask = nil
            return
        }

        pendingStreamingSessionId = nil
        pendingStreamingAssistantMessageId = nil
        pendingStreamingAssistantText = nil
        pendingStreamingTextUpdateMode = nil
        streamingFlushTask = nil
        applyStreamingAssistantText(text, messageId: messageId, mode: mode)
    }

    private func cancelPendingStreamingAssistantText(for sessionId: String? = nil) {
        guard sessionId == nil || pendingStreamingSessionId == sessionId else {
            return
        }

        streamingFlushTask?.cancel()
        streamingFlushTask = nil
        pendingStreamingSessionId = nil
        pendingStreamingAssistantMessageId = nil
        pendingStreamingAssistantText = nil
        pendingStreamingTextUpdateMode = nil
    }

    private func applyStreamingAssistantText(
        _ text: String,
        messageId: String,
        mode: StreamingTextUpdateMode
    ) {
        switch mode {
        case .append:
            transcript.appendStreamingAssistantText(text, messageId: messageId)
        case .replace:
            transcript.upsert(
                ChatMessage(
                    id: messageId,
                    role: .assistant,
                    segments: [ChatMessageSegment(kind: .text, text: text)]
                )
            )
        }
    }

    private func handleRunStatus(_ status: ChatRunStatusEvent, sessionId: String) {
        if let tokenUsage = status.tokenUsage {
            contextTokenUsage = tokenUsage
        }
        if status.stage.isWorking {
            _ = ensureActiveStreamingAssistantTurn(for: sessionId)
            clearWorkingTreeSourceControl()
            Task { @MainActor in
                await refreshPendingToolApproval()
            }
        }
        activeRunStatus = status
        if status.stage == .interrupted,
           let details = status.details?.trimmingCharacters(in: .whitespacesAndNewlines),
           !details.isEmpty,
           let failedMessage = transcript.messages.last(where: {
               $0.role == .assistant
                   && $0.textContent.trimmingCharacters(in: .whitespacesAndNewlines) == details
           }) {
            providerSettingsRecoveryMessageIDs.insert(failedMessage.id)
        }
        if status.stage == .responding,
           let expandedText = status.expandedText,
           !expandedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            scheduleStreamingAssistantText(expandedText, sessionId: sessionId, mode: .replace)
        }

        switch status.stage {
        case .thinking, .searching, .responding:
            isAwaitingAgentResponse = true
        case .paused, .done, .interrupted:
            flushPendingStreamingAssistantText()
            let completedMessageId = streamingTurnTracker.completeNextTurn(for: sessionId)
            isAwaitingAgentResponse = false
            isStopping = false
            if let activity = computerUseActivity, activity.phase == .active {
                computerUseActivity = activity.finishing(
                    failed: status.stage == .interrupted
                )
            }
            refreshWorkingTreeSourceControl()
            if status.stage == .done, let completedMessageId {
                scheduleResponseCompletionNotification(
                    sessionId: sessionId,
                    messageId: completedMessageId
                )
            }
            queuedMessageInterruptRequested = false
            if status.stage == .paused {
                Task { @MainActor in
                    await refreshPendingToolApproval()
                    await sendNextQueuedMessageIfIdle()
                }
            } else {
                pendingToolApproval = nil
                Task { @MainActor in
                    await sendNextQueuedMessageIfIdle()
                }
            }
        }
    }

    private func refreshSemanticDecisionUsage(agentId: String, sessionId: String) async {
        guard isCurrentSession(agentId: agentId, sessionId: sessionId) else { return }
        guard let response = try? await apiClient.fetchSessionTokenUsage(
            agentId: agentId,
            sessionId: sessionId
        ) else {
            return
        }
        guard isCurrentSession(agentId: agentId, sessionId: sessionId) else { return }
        semanticDecisionUsage = response.semanticDecisionUsage
    }

    private func clearWorkingTreeSourceControl() {
        workingTreeSourceControlTask?.cancel()
        workingTreeSourceControlTask = nil
        workingTreeSourceControl = nil
    }

    private func refreshWorkingTreeSourceControl() {
        workingTreeSourceControlTask?.cancel()
        guard let projectId = activeProjectId,
              let sessionId = selectedSessionId else {
            workingTreeSourceControl = nil
            return
        }
        let taskId = activeTaskId

        workingTreeSourceControlTask = Task { @MainActor in
            let response = try? await apiClient.fetchProjectWorkingTreeSourceControl(
                projectId: projectId,
                taskId: taskId
            )
            guard !Task.isCancelled,
                  activeProjectId == projectId,
                  activeTaskId == taskId,
                  selectedSessionId == sessionId else {
                return
            }
            workingTreeSourceControl = response
        }
    }

    private func scheduleResponseCompletionNotification(
        sessionId: String,
        messageId: String
    ) {
        guard let agent = selectedAgent else { return }
        let responsePreview = transcript.messages.last(where: {
            $0.role == .assistant
                && !$0.textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })?.textContent
        let notification = AgentResponseCompletionNotification(
            agentName: agent.displayName,
            sessionTitle: activeSessionTitle,
            responsePreview: responsePreview,
            agentId: agent.id,
            sessionId: sessionId,
            messageId: messageId
        )
        Task { @MainActor [responseNotificationScheduler] in
            await responseNotificationScheduler.schedule(notification)
        }
    }

    @discardableResult
    private func beginStreamingAssistantTurn(for sessionId: String) -> String {
        flushPendingStreamingAssistantText()
        if computerUseActivity?.phase != .active {
            computerUseActivity = nil
            isComputerUsePreviewHidden = false
        }
        let messageId = "streaming-assistant-\(sessionId)-\(UUID().uuidString.lowercased())"
        streamingTurnTracker.begin(sessionId: sessionId, messageId: messageId)
        return messageId
    }

    private func ensureActiveStreamingAssistantTurn(for sessionId: String) -> String {
        currentStreamingAssistantMessageId(for: sessionId)
            ?? beginStreamingAssistantTurn(for: sessionId)
    }

    private func currentStreamingAssistantMessageId(for sessionId: String) -> String? {
        streamingTurnTracker.currentMessageId(for: sessionId)
    }

    private func clearActiveStreamingAssistantTurn(for sessionId: String? = nil) {
        streamingTurnTracker.clear(sessionId: sessionId)
    }

    private func displayTitle(for session: ChatSessionSummary) -> String {
        session.title.isEmpty ? "Chat" : session.title
    }

    private func taskSessionTitle(for taskId: String) -> String {
        "task-\(taskId)"
    }

    private func sortSessions(_ sessions: [ChatSessionSummary]) -> [ChatSessionSummary] {
        sessions.sorted { lhs, rhs in
            let lhsPinned = settings.isSessionPinned(lhs.storageID)
            let rhsPinned = settings.isSessionPinned(rhs.storageID)
            if lhsPinned != rhsPinned {
                return lhsPinned
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private func upsertSessionSummary(_ summary: ChatSessionSummary) {
        sessions.removeAll { $0.storageID == summary.storageID }
        sessions.append(summary)
        sessions = sortSessions(sessions)

        sessionCatalog.removeAll { $0.storageID == summary.storageID }
        sessionCatalog.append(summary)
        sessionCatalog = sortSessions(sessionCatalog)
        onSessionSummaryChange(summary)
    }

    public func mergeSessionSummary(_ summary: ChatSessionSummary) {
        upsertSessionSummary(summary)
    }

    private func debugSessionFilePathURL(for session: ChatSessionSummary) -> URL {
        var components = URLComponents(url: apiClient.baseURL, resolvingAgainstBaseURL: false)
            ?? URLComponents()
        let agentId = session.agentId
        components.path = "/v1/debug/session-file-path/\(Self.urlPathEscape(agentId))/\(Self.urlPathEscape(session.id))"
        components.queryItems = nil
        return components.url ?? apiClient.baseURL
    }

    private static func urlPathEscape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    private func preferredSession(
        in sessions: [ChatSessionSummary],
        title: String?,
        taskId: String? = nil,
        projectId: String? = nil,
        allowsFallback: Bool = true
    ) -> ChatSessionSummary? {
        let candidates = sessions
            .filter { $0.kind != "heartbeat" }
            .sorted { $0.updatedAt > $1.updatedAt }

        if let taskId = taskId?.trimmingCharacters(in: .whitespacesAndNewlines), !taskId.isEmpty {
            var normalizedTaskTitles = [taskSessionTitle(for: taskId)]
            if let projectId = projectId?.trimmingCharacters(in: .whitespacesAndNewlines), !projectId.isEmpty {
                normalizedTaskTitles.append("task-comment:\(projectId):\(taskId)")
            }
            normalizedTaskTitles = normalizedTaskTitles.map { $0.lowercased() }

            if let taskSession = candidates.first(where: { session in
                session.taskId?.caseInsensitiveCompare(taskId) == .orderedSame
                    || normalizedTaskTitles.contains(session.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            }) {
                return taskSession
            }
        }

        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return allowsFallback ? candidates.first : nil
        }

        let normalizedTitle = title.lowercased()
        let titleMatch = candidates.first {
            let sessionTitle = $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return sessionTitle == normalizedTitle || sessionTitle.contains(normalizedTitle)
        }

        return titleMatch ?? (allowsFallback ? candidates.first : nil)
    }

    private func showSessionStatus(_ status: String) {
        sessionStatusTask?.cancel()
        sessionActionStatus = status
        sessionStatusTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled {
                sessionActionStatus = nil
            }
        }
    }

    #if DEBUG
    private func saveDebugSessionData(_ data: Data, session: ChatSessionSummary) throws -> URL {
        let fileManager = FileManager.default
        let fileName = "sloppy-session-\(safeFileName(displayTitle(for: session)))-\(session.id).json"
        let searchDirectories: [FileManager.SearchPathDirectory] = [
            .downloadsDirectory,
            .documentDirectory,
        ]

        var lastError: Error?
        for directory in searchDirectories {
            do {
                let directoryURL = try fileManager.url(
                    for: directory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
                let fileURL = directoryURL.appendingPathComponent(fileName)
                try data.write(to: fileURL, options: .atomic)
                return fileURL
            } catch {
                lastError = error
            }
        }

        throw lastError ?? CocoaError(.fileWriteUnknown)
    }

    private func safeFileName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitizedScalars = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(sanitizedScalars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "chat" : String(collapsed.prefix(48))
    }
    #endif

    public func sendMessage(content: String) {
        guard let agent = selectedAgent,
              activeInputRequest == nil else {
            return
        }
        let attachments = composerAttachments
        let quotes = composerQuotes
        guard !content.isEmpty || !attachments.isEmpty || !quotes.isEmpty else { return }

        if isSending || isAwaitingAgentResponse || isStopping || pendingToolApproval != nil {
            enqueueMessage(content: content, attachments: attachments, quotes: quotes)
            if isAwaitingAgentResponse,
               !isStopping,
               pendingToolApproval == nil,
               !queuedMessageInterruptRequested {
                queuedMessageInterruptRequested = true
                stopActiveRun()
            }
            return
        }

        sendMessageImmediately(content: content, attachments: attachments, quotes: quotes, agent: agent)
    }

    public func cancelQueuedMessage(id: UUID) {
        messageQueue.cancel(id: id)
        queuedMessages = messageQueue.messages
    }

    private func enqueueMessage(
        content: String,
        attachments: [ChatComposerAttachment],
        quotes: [ChatComposerQuote]
    ) {
        messageQueue.enqueue(content: content, attachments: attachments, quotes: quotes)
        queuedMessages = messageQueue.messages
        clearActiveComposerDraft()
        dismissComposerFocus()
    }

    private func sendMessageImmediately(
        content: String,
        attachments: [ChatComposerAttachment],
        quotes: [ChatComposerQuote],
        agent: APIAgentRecord
    ) {
        let messageContent = ChatComposerQuote.messageContent(content, quotes: quotes)
        sendErrorMessage = nil
        clearWorkingTreeSourceControl()
        clearActiveComposerDraft()
        dismissComposerFocus()
        isSending = true
        isAwaitingAgentResponse = true
        activeRunStatus = nil
        Task { @MainActor [responseNotificationScheduler] in
            await responseNotificationScheduler.prepareAuthorization()
        }
        var optimisticSegments: [ChatMessageSegment] = []
        if !messageContent.isEmpty {
            optimisticSegments.append(ChatMessageSegment(kind: .text, text: messageContent))
        }
        optimisticSegments += attachments.map {
            ChatMessageSegment(kind: .attachment, attachment: $0.messageAttachment)
        }
        let optimistic = ChatMessage(
            id: "optimistic-user-\(UUID().uuidString)",
            role: .user,
            segments: optimisticSegments
        )
        if let sessionId = selectedSessionId {
            beginStreamingAssistantTurn(for: sessionId)
        }
        transcript.append(optimistic)

        if selectedSessionId == nil {
            Task { @MainActor in
                do {
                    let summary = try await apiClient.createAgentSession(
                        agentId: agent.id,
                        title: activeTaskId.map(taskSessionTitle(for:)),
                        projectId: activeProjectId,
                        taskId: activeTaskId
                    )
                    upsertSessionSummary(summary)
                    selectedSessionId = summary.id
                    rememberCurrentModelSelection(agentId: agent.id, sessionId: summary.id)
                    beginStreamingAssistantTurn(for: summary.id)
                    settings.lastSessionId = summary.id
                    syncComposerDraft(
                        toSessionId: summary.id,
                        projectId: activeProjectId,
                        taskId: activeTaskId,
                        agentId: agent.id
                    )
                    await connectToSession(agentId: agent.id, sessionId: summary.id)
                    await postMessage(
                        content: messageContent,
                        draftContent: content,
                        attachments: attachments,
                        quotes: quotes,
                        agentId: agent.id,
                        sessionId: summary.id,
                        optimistic: optimistic
                    )
                } catch {
                    isSending = false
                    isAwaitingAgentResponse = false
                    activeRunStatus = nil
                    transcript.removeAll { $0.id == optimistic.id }
                    restoreComposerDraft(content: content, attachments: attachments, quotes: quotes)
                    sendErrorMessage = "Could not create session: \(error.localizedDescription)"
                }
            }
            return
        }

        guard let sessionId = selectedSessionId else { return }
        Task { @MainActor in
            await postMessage(
                content: messageContent,
                draftContent: content,
                attachments: attachments,
                quotes: quotes,
                agentId: agent.id,
                sessionId: sessionId,
                optimistic: optimistic
            )
        }
    }

    public func submitInputResponse(_ answers: [ChatPlanInputAnswer]) {
        answerInputRequest(status: .answered, answers: answers)
    }

    public func cancelInputRequest() {
        answerInputRequest(status: .cancelled, answers: [])
    }

    private func answerInputRequest(
        status: ChatPlanInputResponseStatus,
        answers: [ChatPlanInputAnswer]
    ) {
        guard let agentId = selectedAgent?.id,
              let sessionId = selectedSessionId,
              let inputRequest = activeInputRequest,
              !isSubmittingInputResponse else {
            return
        }

        isSubmittingInputResponse = true
        clearWorkingTreeSourceControl()
        inputRequestErrorMessage = nil
        if status == .answered {
            _ = ensureActiveStreamingAssistantTurn(for: sessionId)
        }
        Task { @MainActor in
            defer { isSubmittingInputResponse = false }
            do {
                let summary = try await apiClient.answerSessionInputRequest(
                    agentId: agentId,
                    sessionId: sessionId,
                    requestId: inputRequest.id,
                    request: ChatPlanInputAnswerRequest(
                        status: status,
                        answers: answers
                    )
                )
                guard isCurrentSession(agentId: agentId, sessionId: sessionId),
                      activeInputRequest?.id == inputRequest.id else {
                    return
                }
                activeInputRequest = nil
                upsertSessionSummary(summary)
                if status == .answered {
                    isAwaitingAgentResponse = true
                    activeRunStatus = nil
                }
                await hydrateSession(agentId: agentId, sessionId: sessionId)
            } catch {
                guard isCurrentSession(agentId: agentId, sessionId: sessionId),
                      activeInputRequest?.id == inputRequest.id else {
                    return
                }
                if status == .answered {
                    streamingTurnTracker.completeNextTurn(for: sessionId)
                }
                inputRequestErrorMessage = "Answers were not sent: \(error.localizedDescription)"
            }
        }
    }

    private func postMessage(
        content: String,
        draftContent: String,
        attachments: [ChatComposerAttachment],
        quotes: [ChatComposerQuote],
        agentId: String,
        sessionId: String,
        optimistic: ChatMessage
    ) async {
        defer { isSending = false }
        do {
            let summary = try await apiClient.postSessionMessage(
                agentId: agentId,
                sessionId: sessionId,
                content: content,
                attachments: attachments.map(\.upload),
                selectedModel: ChatModelSelection.requestOverride(for: selectedModelId),
                reasoningEffort: selectedModelSupportsReasoningEffort ? selectedReasoningEffort.payloadValue : nil
            )
            upsertSessionSummary(summary)
        } catch {
            let shouldRestoreDraft = ChatMessageSendFailurePolicy.shouldRestoreDraft(
                after: error,
                optimisticMessageIsPresent: transcript.messages.contains { $0.id == optimistic.id }
            )
            guard shouldRestoreDraft else {
                return
            }

            transcript.removeAll { $0.id == optimistic.id }
            isAwaitingAgentResponse = false
            activeRunStatus = nil
            restoreComposerDraft(content: draftContent, attachments: attachments, quotes: quotes)
            sendErrorMessage = "Message was not sent: \(error.localizedDescription)"
            Task { @MainActor in
                await sendNextQueuedMessageIfIdle()
            }
        }
    }

    private func sendNextQueuedMessageIfIdle() async {
        guard !isSending,
              !isAwaitingAgentResponse,
              !isStopping,
              !isDrainingQueuedMessages,
              activeInputRequest == nil,
              pendingToolApproval == nil,
              let agent = selectedAgent,
              let message = messageQueue.dequeue() else {
            return
        }

        isDrainingQueuedMessages = true
        queuedMessages = messageQueue.messages
        sendMessageImmediately(
            content: message.content,
            attachments: message.attachments,
            quotes: message.quotes,
            agent: agent
        )
        isDrainingQueuedMessages = false
    }

    public func refreshPendingToolApproval() async {
        guard let agentId = selectedAgent?.id,
              let sessionId = selectedSessionId else {
            pendingToolApproval = nil
            return
        }
        await refreshPendingToolApproval(agentId: agentId, sessionId: sessionId)
    }

    private func refreshPendingToolApproval(agentId: String, sessionId: String) async {
        guard let approvals = try? await apiClient.fetchPendingToolApprovals(),
              isCurrentSession(agentId: agentId, sessionId: sessionId) else {
            return
        }
        pendingToolApproval = approvals.first { approval in
            approval.status == "pending"
                && !resolvedToolApprovalIDs.contains(approval.id)
                && (approval.displaySessionId == sessionId || approval.sessionId == sessionId)
                && (approval.agentId == nil || approval.agentId == agentId)
        }
        if pendingToolApproval == nil {
            toolApprovalErrorMessage = nil
        }
    }

    public func resolvePendingToolApproval(approved: Bool) {
        guard let approval = pendingToolApproval,
              !isResolvingToolApproval else {
            return
        }
        isResolvingToolApproval = true
        toolApprovalErrorMessage = nil
        Task { @MainActor in
            defer { isResolvingToolApproval = false }
            do {
                try await apiClient.resolveToolApproval(id: approval.id, approved: approved)
                resolvedToolApprovalIDs.insert(approval.id)
                guard pendingToolApproval?.id == approval.id else { return }
                pendingToolApproval = nil
                isAwaitingAgentResponse = true
            } catch {
                toolApprovalErrorMessage = error.localizedDescription
            }
        }
    }

    public func stopActiveRun() {
        guard let agentId = selectedAgent?.id,
              let sessionId = selectedSessionId,
              shouldShowStopButton,
              !isStopping else {
            return
        }

        isStopping = true
        Task { @MainActor in
            do {
                try await apiClient.interruptAgentSession(
                    agentId: agentId,
                    sessionId: sessionId,
                    includeSubsessions: true,
                    reason: "Interrupted from Apple client"
                )
            } catch {
                isStopping = false
            }
        }
    }

    public func startDictation() {
        guard dictationPhase == .idle, !shouldShowStopButton, !isSending else {
            return
        }

        Task { @MainActor in
            do {
                try await dictationRecorder.start()
                dictationPhase = .recording
                dictationDuration = 0
                dictationLevels = Array(repeating: 0.12, count: 48)
                beginDictationMetering()
            } catch {
                resetDictationState()
                showSessionStatus(error.localizedDescription)
            }
        }
    }

    public func stopDictation() {
        guard dictationPhase == .recording else {
            return
        }

        dictationPhase = .transcribing
        dictationMeterTask?.cancel()
        dictationMeterTask = nil

        Task { @MainActor in
            do {
                let capture = try await dictationRecorder.stop()
                dictationDuration = capture.duration
                let transcript = try await transcribeDictationCapture(capture)
                composerDraft.text = transcript
                saveActiveComposerDraft()
                resetDictationState()
            } catch {
                await dictationRecorder.cancel()
                resetDictationState()
                showSessionStatus(error.localizedDescription)
            }
        }
    }

    private var selectedModelSupportsReasoningEffort: Bool {
        guard let selectedModel = availableModels.first(where: { $0.id == selectedModelId }) else {
            return false
        }
        return selectedModel.supportsReasoningEffort
    }

    private func restoreModelSelection(agentId: String, sessionId: String?) {
        selectedModelId = modelPreferences.selection(
            server: apiClient.endpoint.cacheNamespace,
            agentId: agentId,
            sessionId: sessionId
        ) ?? availableModels.first?.id ?? ""
        selectedReasoningEffort = .default
    }

    private func rememberCurrentModelSelection(agentId: String, sessionId: String) {
        guard !selectedModelId.isEmpty else { return }
        modelPreferences.rememberSessionSelection(
            selectedModelId,
            server: apiClient.endpoint.cacheNamespace,
            agentId: agentId,
            sessionId: sessionId
        )
    }

    private func applyAvailableModels(_ models: [ChatModelOption]) {
        availableModels = models
        if selectedModelId == ChatModelSelection.automaticJEVId {
            return
        }
        guard !models.isEmpty else {
            selectedModelId = ""
            selectedReasoningEffort = .default
            return
        }

        if !models.contains(where: { $0.id == selectedModelId }) {
            selectedModelId = models[0].id
            selectedReasoningEffort = .default
        }
    }

    private func beginDictationMetering() {
        dictationMeterTask?.cancel()
        dictationMeterTask = Task { @MainActor in
            while !Task.isCancelled, dictationPhase == .recording {
                let snapshot = await dictationRecorder.snapshot()
                dictationDuration = snapshot.elapsed
                appendDictationLevel(snapshot.level)
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
        }
    }

    private func appendDictationLevel(_ level: Double) {
        dictationLevels.removeFirst()
        dictationLevels.append(max(0.08, min(1, CGFloat(level))))
    }

    private func transcribeDictationCapture(_ capture: DictationCapture) async throws -> String {
        defer {
            try? FileManager.default.removeItem(at: capture.fileURL)
        }

        let audioData = try Data(contentsOf: capture.fileURL)
        if !audioData.isEmpty {
            do {
                let response = try await apiClient.transcribeVoice(
                    VoiceTranscriptionRequest(
                        audioBase64: audioData.base64EncodedString(),
                        mimeType: capture.mimeType,
                        language: Locale.current.identifier
                    )
                )
                let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    return text
                }
            } catch {
                let fallback = try await AppleSpeechTranscriber.transcribe(
                    fileURL: capture.fileURL,
                    localeIdentifier: Locale.current.identifier
                )
                let text = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    return text
                }
                throw error
            }
        }

        let fallback = try await AppleSpeechTranscriber.transcribe(
            fileURL: capture.fileURL,
            localeIdentifier: Locale.current.identifier
        )
        let text = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            return text
        }
        throw DictationRecorderError.noCapture
    }

    private func resetDictationState() {
        dictationMeterTask?.cancel()
        dictationMeterTask = nil
        dictationPhase = .idle
        dictationDuration = 0
        dictationLevels = Array(repeating: 0.12, count: 48)
    }

    private func cancelDictationIfNeeded() {
        guard dictationPhase != .idle else {
            return
        }
        resetDictationState()
        Task {
            await dictationRecorder.cancel()
        }
    }

    private func syncComposerDraft(
        toSessionId sessionId: String?,
        projectId: String?,
        taskId: String?,
        agentId: String?
    ) {
        let nextKey = composerDraftKey(
            sessionId: sessionId,
            projectId: projectId,
            taskId: taskId,
            agentId: agentId
        )
        activeComposerDraftKey = nextKey
        let storedDraft = composerDraftsByKey[nextKey]
        composerDraft.text = storedDraft?.text ?? ""
        composerAttachments = storedDraft?.attachments ?? []
        composerQuotes = storedDraft?.quotes ?? []
        if !pendingComposerQuotes.isEmpty {
            composerQuotes.append(contentsOf: pendingComposerQuotes)
            pendingComposerQuotes = []
            saveActiveComposerDraft()
        }
        if let pendingComposerTextMutation {
            self.pendingComposerTextMutation = nil
            applyComposerTextMutation(pendingComposerTextMutation)
        }
    }

    private func saveActiveComposerDraft() {
        guard let activeComposerDraftKey else { return }
        if composerDraft.text.isEmpty && composerAttachments.isEmpty && composerQuotes.isEmpty {
            composerDraftsByKey.removeValue(forKey: activeComposerDraftKey)
        } else {
            composerDraftsByKey[activeComposerDraftKey] = StoredComposerDraft(
                text: composerDraft.text,
                attachments: composerAttachments,
                quotes: composerQuotes
            )
        }
    }

    private func clearActiveComposerDraft() {
        guard let activeComposerDraftKey else {
            composerDraft.text = ""
            composerAttachments = []
            composerQuotes = []
            return
        }
        composerDraft.text = ""
        composerAttachments = []
        composerQuotes = []
        composerDraftsByKey.removeValue(forKey: activeComposerDraftKey)
    }

    private func restoreComposerDraft(
        content: String,
        attachments: [ChatComposerAttachment],
        quotes: [ChatComposerQuote]
    ) {
        composerDraft.text = content
        composerAttachments = attachments
        composerQuotes = quotes
        saveActiveComposerDraft()
    }

    private func composerDraftKey(
        sessionId: String?,
        projectId: String?,
        taskId: String?,
        agentId: String?
    ) -> String {
        if let sessionId, !sessionId.isEmpty {
            return "session:\(sessionId)"
        }

        let resolvedAgentId = agentId ?? selectedAgent?.id ?? "none"
        return "draft:\(resolvedAgentId):\(projectId ?? "-"):\(taskId ?? "-")"
    }
}
