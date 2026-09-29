import Foundation
import AppKit
import Observation
import CryptoKit
import SloppyClientCore

@Observable
@MainActor
final class DesktopCompanionModel {
    private(set) var coreAddress: String
    var agents: [APIAgentRecord] = []
    var selectedAgentID: String
    var messages: [ChatMessage] = []
    var draft = ""
    var context: DesktopPointerContext?
    var image: DesktopImageCapture?
    var error: String?
    var shortcutError: String?
    var isConnecting = false
    var isSending = false
    var isStopping = false
    var isWorking = false
    var isRecording = false
    var isTranscribing = false
    var isConnected = false
    var audioLevel: Double = 0
    var status = "Connecting to Sloppy desktop…"
    var expanded = false
    var chatPresentationID = UUID()
    var responsePresentationID = UUID()
    var panelVisible = true
    var showHistory = false
    var composerPanelHeight: CGFloat = 44
    var responsePanelHeight: CGFloat = 56
    var lastSubmittedPrompt: String?
    var selectedAction: DesktopPointerAction?
    var pendingInput: ChatPlanInputRequest?
    var pendingApproval: PendingToolApprovalRecord?
    var inputAnswers: [String: String] = [:]
    var selectedInputOptions: [String: String] = [:]
    var shortcutMode: DesktopPointerShortcutMode
    var optionKeyCode: Int
    var rightCommandEnabled: Bool
    var magicPointerEnabled: Bool
    var voiceRepliesEnabled: Bool
    var voiceLocaleIdentifier: String
    var magicPointer: MagicPointerConversationController?
    var onPanelChanged: (() -> Void)?
    var onLayoutChanged: (() -> Void)?
    var onYieldInputFocus: (() -> Void)?
    var onDesktopOpened: (() -> Void)?
    var onMessageSubmitted: (() -> Void)?
    var onActionRingRequested: (() -> Void)?
    let capture = DesktopContextCapture()

    @ObservationIgnored private var client: SloppyAPIClient?
    @ObservationIgnored private var computer: DesktopComputerConnection?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private let recorder = DictationRecorder()
    @ObservationIgnored private let magicRecorder = DictationRecorder()
    @ObservationIgnored private let speechPlayer = MagicPointerSpeechPlayer()
    @ObservationIgnored private var voiceResponseBaseline: Set<String> = []
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let deviceID: String
    @ObservationIgnored private var sessionID: String?
    @ObservationIgnored private var connectedAgentID = ""
    @ObservationIgnored private var configurationID = UUID()
    @ObservationIgnored private var captureID = UUID()
    @ObservationIgnored private var workID = UUID()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        coreAddress = (try? DesktopLocalSloppyConfiguration.load())?.baseURL.absoluteString ?? "No local instance selected"
        selectedAgentID = defaults.string(forKey: "companion.agent-id") ?? ""
        shortcutMode = defaults.string(forKey: "companion.shortcut-mode").flatMap(DesktopPointerShortcutMode.init(rawValue:)) ?? .optionSpace
        optionKeyCode = defaults.object(forKey: "companion.option-key") as? Int ?? 61
        rightCommandEnabled = defaults.object(forKey: "companion.right-command") as? Bool ?? true
        magicPointerEnabled = defaults.object(forKey: "companion.magic-pointer") as? Bool ?? true
        voiceRepliesEnabled = defaults.object(forKey: "companion.voice-replies") as? Bool ?? true
        voiceLocaleIdentifier = defaults.string(forKey: "companion.voice-locale") ?? "ru-RU"
        deviceID = defaults.string(forKey: "companion.device-id") ?? UUID().uuidString
        defaults.set(deviceID, forKey: "companion.device-id")
    }

    var orbActivity: DesktopOrbView.Activity {
        if magicPointer?.state == .listening { return .listening }
        if isRecording { return .listening }
        if error != nil || pendingInput != nil || pendingApproval != nil { return .attention }
        if isWorking || isSending || isTranscribing { return .working }
        return .idle
    }

    var canStop: Bool { isWorking || isSending || pendingInput != nil || pendingApproval != nil || magicPointer?.isBusy == true }

    var responseText: String? {
        let latest = messages.last { $0.role != .system && !$0.textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if isSending, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return draft }
        if canStop {
            return lastSubmittedPrompt ?? messages.last(where: { $0.role == .user && !$0.textContent.isEmpty })?.textContent ?? latest?.textContent
        }
        return latest?.textContent ?? lastSubmittedPrompt
    }

    var showsResponsePanel: Bool {
        responseText != nil || canStop || pendingInput != nil || pendingApproval != nil || image != nil || error != nil || shortcutError != nil
            || (showHistory && !messages.isEmpty)
    }

    var panelLayout: DesktopCompanionLayout {
        .init(expanded: expanded, showsResponse: showsResponsePanel,
              composerHeight: composerPanelHeight, responseHeight: responsePanelHeight)
    }

    func didSubmitPrompt(_ prompt: String) {
        lastSubmittedPrompt = prompt
        draft = ""
        image = nil
        isWorking = true
        status = "Agent is working"
        onMessageSubmitted?()
    }

    var composerAction: DesktopComposerAction {
        if isRecording { return .finishRecording }
        if isTranscribing { return .transcribing }
        return draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .record : .send
    }

    var canPerformComposerAction: Bool {
        if magicPointer?.isBusy == true { return false }
        return switch composerAction {
        case .record: !isSending && !isStopping && !isWorking
        case .finishRecording: true
        case .transcribing: false
        case .send: isConnected && !isSending && !isStopping && !isWorking
        }
    }

    func performComposerAction() async {
        guard canPerformComposerAction else { return }
        switch composerAction {
        case .record: await startRecording()
        case .finishRecording: await finishRecording()
        case .transcribing: break
        case .send: await send()
        }
    }

    func saveShortcutPreferences() {
        defaults.set(shortcutMode.rawValue, forKey: "companion.shortcut-mode")
        defaults.set(optionKeyCode, forKey: "companion.option-key")
        defaults.set(rightCommandEnabled, forKey: "companion.right-command")
    }

    var sessionURL: URL? {
        guard let sessionID else { return nil }
        return DeepLink.session(agentId: connectedAgentID, sessionId: sessionID).url
    }

    func connect() async {
        guard !isConnecting, !canStop, !isStopping else { return }
        isConnecting = true
        defer { isConnecting = false }
        error = nil
        status = "Connecting to Sloppy desktop…"
        let generation = UUID()
        configurationID = generation
        lastSubmittedPrompt = nil
        await computer?.disconnect()
        refreshTask?.cancel()
        isConnected = false
        do {
            let configuration = try DesktopLocalSloppyConfiguration.load()
            let url = configuration.baseURL
            coreAddress = url.absoluteString
            // A fresh store reloads a sign-in made in the desktop app since the last attempt.
            // Both transports share this store so token refresh is coordinated within Companion.
            let authStore = AuthSessionStore()
            let client = SloppyAPIClient(baseURL: url, tlsFingerprint: configuration.tlsFingerprint,
                                        authSessionStore: authStore)
            let agents = try await client.fetchAgents()
            guard !agents.isEmpty else { throw CompanionError.noAgents }
            self.agents = agents
            if !agents.contains(where: { $0.id == selectedAgentID }) {
                selectedAgentID = agents.first(where: { $0.id == configuration.defaultAgentID })?.id
                    ?? agents.first(where: { $0.isSystem != true })?.id ?? agents[0].id
            }
            defaults.set(selectedAgentID, forKey: "companion.agent-id")
            saveShortcutPreferences()
            self.client = client
            connectedAgentID = selectedAgentID
            let auth = await authStore.session(for: url)
            let account = auth?.user?.id ?? auth.map {
                SHA256.hash(data: Data($0.accessToken.utf8)).map { String(format: "%02x", $0) }.joined()
            } ?? "local"
            let key = "companion.session." + url.absoluteString + "." + account + "." + selectedAgentID
            if let stored = defaults.string(forKey: key) {
                do {
                    let detail = try await client.fetchAgentSession(agentId: selectedAgentID, sessionId: stored)
                    sessionID = stored
                    apply(detail)
                } catch let apiError as APIError where apiError.statusCode == 404 {
                    sessionID = nil
                }
            } else { sessionID = nil }
            if sessionID == nil {
                let session = try await client.createAgentSession(agentId: selectedAgentID, title: "Desktop Companion")
                sessionID = session.id
                defaults.set(session.id, forKey: key)
                messages = []
            }
            guard configurationID == generation else { return }
            let computer = DesktopComputerConnection(baseURL: url, capture: capture,
                                                       tlsFingerprint: configuration.tlsFingerprint,
                                                       authSessionStore: authStore)
            computer.onError = { [weak self] message in self?.error = message }
            computer.onAction = { [weak self] in
                self?.status = "Agent is controlling your computer"
                self?.onYieldInputFocus?()
            }
            self.computer = computer
            try await bindComputer()
            isConnected = true
            status = "Ready"
            refreshTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh()
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
            }
        } catch {
            if let apiError = error as? APIError, apiError.statusCode == 401 {
                self.error = CompanionError.desktopSignInRequired.localizedDescription
            } else { self.error = error.localizedDescription }
            status = "Disconnected"
        }
    }

    @discardableResult
    func openDesktop(preferSession: Bool = false,
                     openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }) -> Bool {
        guard let url = (preferSession ? sessionURL : nil) ?? DeepLink.open.url, openURL(url) else {
            error = "Open the Sloppy desktop app and sign in, then reconnect here."
            return false
        }
        onDesktopOpened?()
        return true
    }

    #if DEBUG
    func saveConnectionReport(to url: URL) throws {
        let report: [String: Any] = ["coreAddress": coreAddress, "isConnected": isConnected,
                                     "agentCount": agents.count, "status": status,
                                     "hasError": error != nil, "sessionURL": sessionURL?.absoluteString ?? ""]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
    #endif

    private func bindComputer() async throws {
        guard let computer, let sessionID else { throw CompanionError.disconnected }
        if computer.binding == nil {
            try await computer.connect(.init(connectionId: UUID().uuidString, deviceId: deviceID,
                                             agentId: connectedAgentID, sessionId: sessionID))
        }
        if let context { computer.screenPoint = context.pointer }
    }

    func beginInvocation(context: DesktopPointerContext) {
        captureID = UUID()
        self.context = context
        image = nil
        computer?.screenPoint = context.pointer
    }

    func cancelContextCapture() { captureID = UUID() }

    func prepare(_ action: DesktopPointerAction) async {
        expanded = true
        error = nil
        onPanelChanged?()
        if action == .chat { return }
        let generation = captureID
        do {
            if action == .write || action == .voice {
                if let context {
                    let next = try await capture.capturePoint(context)
                    guard captureID == generation else { return }
                    image = next
                }
            } else if action == .window, let context {
                let next = try await capture.captureWindow(at: context.pointer)
                guard captureID == generation else { return }
                image = next
            }
            if action == .voice { await startRecording() }
        } catch {
            guard captureID == generation else { return }
            self.error = error.localizedDescription
        }
    }

    func setRegion(_ frame: CGRect, voice: Bool) async {
        expanded = true
        error = nil
        onPanelChanged?()
        let generation = captureID
        do {
            let next = try await capture.captureRegion(appKitFrame: frame)
            guard generation == captureID else { return }
            image = next
            if voice { await startRecording() }
        } catch {
            guard generation == captureID else { return }
            self.error = error.localizedDescription
        }
    }

    func send() async {
        guard !isSending, !isStopping, !isWorking, !isRecording, !isTranscribing else { return }
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        guard let client, let sessionID, isConnected else { error = CompanionError.disconnected.localizedDescription; return }
        isSending = true
        let workID = self.workID
        defer { isSending = false }
        error = nil
        do {
            try await bindComputer()
            guard self.workID == workID else { return }
            var attachments = image.map { [$0.attachment] } ?? []
            if let context {
                let metadata = DesktopContextMetadata(context: context, image: image, deviceID: deviceID)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(metadata)
                attachments.append(.init(name: "Desktop context.json", mimeType: "application/json", sizeBytes: data.count,
                                         contentBase64: data.base64EncodedString()))
            }
            _ = try await client.postSessionMessage(agentId: connectedAgentID, sessionId: sessionID,
                                                    content: prompt, attachments: attachments)
            guard self.workID == workID else {
                try await client.interruptAgentSession(agentId: connectedAgentID, sessionId: sessionID,
                                                       requestedBy: "desktop-companion", reason: "Submission cancelled by Stop")
                return
            }
            didSubmitPrompt(prompt)
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    func stop() async {
        magicPointer?.cancel()
        guard !isStopping else { return }
        isStopping = true
        workID = UUID()
        defer { isStopping = false }
        let computer = computer
        let oldBinding = computer?.binding
        computer?.stopLocally()
        do {
            if let client, let sessionID {
                try await client.interruptAgentSession(agentId: connectedAgentID, sessionId: sessionID,
                                                       requestedBy: "desktop-companion", reason: "User pressed Stop")
            }
            isWorking = false
            status = "Stopped"
        } catch { self.error = error.localizedDescription }
        if let oldBinding, let url = client?.baseURL {
            try? await BackendHTTPClient(baseURL: url).post("/v1/desktop-computer/disconnect", body: oldBinding)
        }
    }

    func refresh() async {
        guard let client, let sessionID, isConnected else { return }
        let generation = configurationID
        do {
            let detail = try await client.fetchAgentSession(agentId: connectedAgentID, sessionId: sessionID)
            guard configurationID == generation, !Task.isCancelled else { return }
            apply(detail)
            let approvals = try await client.fetchPendingToolApprovals()
            pendingApproval = approvals.first { $0.agentId == connectedAgentID && $0.sessionId == sessionID }
        } catch {
            guard configurationID == generation, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func apply(_ detail: ChatSessionDetail) {
        messages = detail.messages
        pendingInput = detail.pendingInputRequest
        if let run = detail.latestRunStatus {
            isWorking = run.stage.isWorking
            status = switch run.stage {
            case .thinking: "Thinking…"
            case .searching: "Searching…"
            case .responding: "Responding…"
            case .paused: "Waiting for input"
            case .done: "Done"
            case .interrupted: "Stopped"
            }
        }
    }

    func answerInput() async {
        guard let client, let sessionID, let pendingInput else { return }
        do {
            let answers = pendingInput.questions.map {
                ChatPlanInputAnswer(questionId: $0.id, selectedOptionId: selectedInputOptions[$0.id],
                                    customAnswer: inputAnswers[$0.id])
            }
            _ = try await client.answerSessionInputRequest(agentId: connectedAgentID, sessionId: sessionID, requestId: pendingInput.id,
                                                    request: .init(answers: answers))
            inputAnswers = [:]
            selectedInputOptions = [:]
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    func approve(_ approved: Bool) async {
        guard let client, let pendingApproval else { return }
        do { try await client.resolveToolApproval(id: pendingApproval.id, approved: approved); await refresh() }
        catch { self.error = error.localizedDescription }
    }

    func startRecording() async {
        guard !isRecording, !isTranscribing else { return }
        error = nil
        let generation = captureID
        do {
            try await recorder.start()
            guard captureID == generation else { await recorder.cancel(); return }
            isRecording = true
            meterTask = Task { [weak self, recorder] in
                while !Task.isCancelled {
                    let snapshot = await recorder.snapshot()
                    self?.audioLevel = snapshot.level
                    do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    func finishRecording() async {
        guard isRecording else { return }
        isRecording = false
        isTranscribing = true
        let generation = captureID
        meterTask?.cancel()
        defer { isTranscribing = false; audioLevel = 0 }
        do {
            let audio = try await recorder.stop()
            defer { try? FileManager.default.removeItem(at: audio.fileURL) }
            let text: String
            if let client {
                do {
                    let data = try Data(contentsOf: audio.fileURL)
                    text = try await client.transcribeVoice(.init(audioBase64: data.base64EncodedString(), mimeType: audio.mimeType)).text
                } catch { text = try await AppleSpeechTranscriber.transcribe(fileURL: audio.fileURL) }
            } else { text = try await AppleSpeechTranscriber.transcribe(fileURL: audio.fileURL) }
            guard captureID == generation else { return }
            draft += (draft.isEmpty ? "" : " ") + text
        } catch { self.error = error.localizedDescription }
    }

    func cancelRecording() async {
        captureID = UUID()
        meterTask?.cancel()
        await recorder.cancel()
        isRecording = false
        audioLevel = 0
    }

    func shutdown() {
        magicPointer?.cancel()
        workID = UUID()
        configurationID = UUID()
        captureID = UUID()
        refreshTask?.cancel()
        meterTask?.cancel()
        let computer = computer
        computer?.stopLocally()
        Task { [recorder] in await recorder.cancel() }
    }

    func installMagicPointer() -> MagicPointerConversationController {
        if let magicPointer { return magicPointer }
        let controller = MagicPointerConversationController(dependencies: .init(
            prepare: { [weak self] in
                guard let self else { throw CompanionError.disconnected }
                await self.cancelRecording()
                guard self.isConnected, let sessionID = self.sessionID else { throw CompanionError.disconnected }
                guard !self.isWorking, !self.isSending, !self.isStopping, self.pendingInput == nil, self.pendingApproval == nil else {
                    throw CompanionError.agentBusy
                }
                return .init(deviceID: self.deviceID, agentID: self.connectedAgentID, sessionID: sessionID)
            },
            validateTarget: { [weak self] target in
                guard let self, self.isConnected, target.agentID == self.connectedAgentID,
                      target.sessionID == self.sessionID, target.deviceID == self.deviceID else { throw CompanionError.disconnected }
                guard !self.isWorking, !self.isSending, !self.isStopping else { throw CompanionError.agentBusy }
            },
            point: { NSEvent.mouseLocation },
            primaryTop: { [capture] in capture.primaryTop },
            desktopContext: { [capture] point in capture.context(at: point) },
            capture: { [capture] context in try await capture.captureDisplay(at: context.pointer) },
            startRecording: { [magicRecorder] in try await magicRecorder.start() },
            snapshot: { [weak self, magicRecorder] in
                let value = await magicRecorder.snapshot()
                self?.audioLevel = value.level
                return value
            },
            stopRecording: { [weak self, magicRecorder] in
                let value = try await magicRecorder.stop()
                self?.audioLevel = 0
                return value
            },
            cancelRecording: { [weak self, magicRecorder] in await magicRecorder.cancel(); self?.audioLevel = 0 },
            transcribe: { [weak self] audio in
                guard let self else { throw CompanionError.disconnected }
                if let client = self.client {
                    do {
                        let data = try Data(contentsOf: audio.fileURL)
                        return try await client.transcribeVoice(.init(audioBase64: data.base64EncodedString(), mimeType: audio.mimeType)).text
                    } catch { /* Use the existing native Speech fallback. */ }
                }
                return try await AppleSpeechTranscriber.transcribe(fileURL: audio.fileURL, localeIdentifier: self.voiceLocaleIdentifier)
            },
            submit: { [weak self] payload in
                guard let self else { throw CompanionError.disconnected }
                try await self.submitMagicPointer(payload)
            },
            reply: { [weak self] in
                guard let self else { throw CompanionError.disconnected }
                return try await self.magicPointerReply()
            },
            speak: { [weak self] text in
                guard let self, self.voiceRepliesEnabled else { return }
                self.speechPlayer.localeIdentifier = self.voiceLocaleIdentifier
                await self.speechPlayer.speak(text)
            },
            stopSpeaking: { [speechPlayer] in speechPlayer.stop() }
        ))
        magicPointer = controller
        return controller
    }

    func saveMagicPointerPreferences() {
        defaults.set(magicPointerEnabled, forKey: "companion.magic-pointer")
        defaults.set(voiceRepliesEnabled, forKey: "companion.voice-replies")
        defaults.set(voiceLocaleIdentifier, forKey: "companion.voice-locale")
        if !magicPointerEnabled { magicPointer?.cancel() }
    }

    private func submitMagicPointer(_ payload: MagicPointerTurnPayload) async throws {
        guard let client, let sessionID, isConnected, payload.context.sessionID == sessionID,
              payload.context.agentID == connectedAgentID else { throw CompanionError.disconnected }
        isSending = true
        let workID = self.workID
        defer { isSending = false }
        if let context = payload.desktopContext { self.context = context; computer?.screenPoint = context.pointer }
        try await bindComputer()
        let before = try await client.fetchAgentSession(agentId: connectedAgentID, sessionId: sessionID)
        voiceResponseBaseline = Set(before.messages.map(\.id))
        _ = try await client.postSessionMessage(agentId: connectedAgentID, sessionId: sessionID,
                                               content: payload.context.utterance.text, attachments: payload.attachments)
        guard self.workID == workID else {
            try await client.interruptAgentSession(agentId: connectedAgentID, sessionId: sessionID,
                                                   requestedBy: "desktop-magic-pointer", reason: "Submission cancelled by Stop")
            return
        }
        let previousDraft = draft
        didSubmitPrompt(payload.context.utterance.text)
        draft = previousDraft
        await refresh()
    }

    private func magicPointerReply() async throws -> MagicPointerConversationController.Reply {
        guard let client, let sessionID, isConnected else { throw CompanionError.disconnected }
        let detail = try await client.fetchAgentSession(agentId: connectedAgentID, sessionId: sessionID)
        apply(detail)
        let approvals = try await client.fetchPendingToolApprovals()
        pendingApproval = approvals.first { $0.agentId == connectedAgentID && $0.sessionId == sessionID }
        if pendingInput != nil || pendingApproval != nil { return .needsInput }
        guard let run = detail.latestRunStatus else { return .waiting }
        if run.stage == .interrupted { return .interrupted }
        guard run.stage == .done, let response = messages.last(where: {
            $0.role == .assistant && !voiceResponseBaseline.contains($0.id) && !$0.textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else { return .waiting }
        return .complete(response.textContent)
    }
}

private struct DesktopContextMetadata: Encodable {
    var source = "desktop_companion"
    var deviceId: String
    var application: String
    var selectedText: String?
    var elementRole: String?
    var elementTitle: String?
    var pointerX: Double
    var pointerY: Double
    var capturedAt: Date
    var screenshot: DesktopComputerCompletion.Result?
    var contentTrust = "untrusted_screen_content"
    var coordinateSpace = "screen_points_top_left"

    init(context: DesktopPointerContext, image: DesktopImageCapture?, deviceID: String) {
        deviceId = deviceID
        application = context.application
        selectedText = context.selectedText
        elementRole = context.elementRole
        elementTitle = context.elementTitle
        pointerX = context.quartzPointer.x
        pointerY = context.quartzPointer.y
        capturedAt = context.capturedAt
        screenshot = image?.result
    }
}

enum CompanionError: LocalizedError {
    case noAgents, disconnected, desktopSignInRequired, agentBusy
    var errorDescription: String? {
        switch self {
        case .noAgents: "This Core has no agents yet. Create an agent in Sloppy."
        case .disconnected: "Reconnect to your local Sloppy in Companion settings."
        case .desktopSignInRequired: "Sign in to the Sloppy desktop app, then reconnect here."
        case .agentBusy: "Агент уже работает. Дождитесь результата или нажмите Stop."
        }
    }
}
