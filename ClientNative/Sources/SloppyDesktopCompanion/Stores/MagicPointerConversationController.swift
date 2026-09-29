import Foundation
import Observation
import SloppyClientCore

@MainActor
@Observable
final class MagicPointerConversationController {
    enum State: String, Sendable {
        case idle, preparing, listening, finalizingTurn, agentWorking, waitingForInput, speaking, failed

        var title: String {
            switch self {
            case .idle: "Voice mode closed"
            case .preparing: "Preparing voice mode…"
            case .listening: "Listening"
            case .finalizingTurn: "Sending your turn…"
            case .agentWorking: "Agent is working…"
            case .waitingForInput: "Your confirmation is needed"
            case .speaking: "Agent is speaking"
            case .failed: "Unable to continue"
            }
        }
    }

    enum Reply: Sendable, Equatable { case waiting, needsInput, complete(String), interrupted }

    struct Dependencies {
        var prepare: () async throws -> MagicPointerTarget
        var validateTarget: (MagicPointerTarget) throws -> Void
        var point: () -> CGPoint
        var primaryTop: () -> CGFloat
        var desktopContext: (CGPoint) -> DesktopPointerContext
        var capture: (DesktopPointerContext) async throws -> DesktopImageCapture
        var startRecording: () async throws -> Void
        var snapshot: () async -> DictationRecorderSnapshot
        var stopRecording: () async throws -> DictationCapture
        var cancelRecording: () async -> Void
        var transcribe: (DictationCapture) async throws -> String
        var submit: (MagicPointerTurnPayload) async throws -> Void
        var reply: () async throws -> Reply
        var speak: (String) async -> Void
        var stopSpeaking: () -> Void
        var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        var sleep: (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    }

    private(set) var state: State = .idle
    private(set) var isActive = false
    private(set) var audioLevel = 0.0
    private(set) var error: String?
    private(set) var pendingPayload: MagicPointerTurnPayload?
    private(set) var submissionUncertain = false
    var onStateChanged: (() -> Void)?
    var onError: ((String) -> Void)?
    var onNeedsInput: (() -> Void)?
    var isBusy: Bool { state != .idle && state != .failed }
    var hasPendingTurn: Bool { retainedTurn != nil }
    var canRetry: Bool { state == .failed && retainedTurn != nil && !submissionUncertain }

    @ObservationIgnored private let dependencies: Dependencies
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var captureTask: Task<Void, Never>?
    @ObservationIgnored private var cleanup: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var builder: PointerTurnContextBuilder?
    @ObservationIgnored private var closeRequested = false
    @ObservationIgnored private var boundaryRequested = false
    @ObservationIgnored private var captureFailure: Error?
    @ObservationIgnored private var retainedTurn: RecordedTurn?

    private struct RecordedTurn {
        var audio: DictationCapture
        var builder: PointerTurnContextBuilder
        var speechStart: TimeInterval?
        var end: TimeInterval
        var truncated: Bool
    }

    init(dependencies: Dependencies) { self.dependencies = dependencies }

    func toggle() {
        if isActive { end() }
        else if !isBusy, retainedTurn == nil { start() }
    }

    func start() {
        guard !isBusy, retainedTurn == nil else { return }
        generation = UUID()
        let id = generation
        isActive = true; closeRequested = false; boundaryRequested = false; error = nil
        changeState(.preparing)
        let previous = operation, cleanup = self.cleanup
        operation = Task { [weak self] in
            await previous?.value
            await cleanup?.value
            guard let self, self.current(id), self.isActive else { return }
            await self.run(id)
        }
    }

    /// Close capture immediately. The nonempty last turn may finish uploading; accepted work continues.
    func end() {
        guard isActive else { return }
        isActive = false; closeRequested = true
        captureTask?.cancel(); dependencies.stopSpeaking()
        onStateChanged?()
    }

    func finishUtterance() {
        guard state == .listening else { return }
        boundaryRequested = true
    }

    func cancel() {
        generation = UUID()
        isActive = false; closeRequested = true; audioLevel = 0
        captureTask?.cancel(); captureTask = nil
        operation?.cancel()
        dependencies.stopSpeaking()
        builder = nil
        discardRetainedTurn()
        let previous = operation, oldCleanup = cleanup
        cleanup = Task { [dependencies] in
            await oldCleanup?.value
            await dependencies.cancelRecording()
            await previous?.value
            // A permission callback may have completed startRecording after cancellation.
            await dependencies.cancelRecording()
        }
        error = nil
        changeState(.idle)
    }

    func retry() {
        guard canRetry else { return }
        generation = UUID()
        let id = generation
        error = nil; isActive = false; closeRequested = true
        changeState(.finalizingTurn)
        let previous = operation, cleanup = cleanup
        operation = Task { [weak self] in
            await previous?.value; await cleanup?.value
            guard let self, self.current(id) else { return }
            do { try await self.processRetainedTurn(id); if self.current(id) { self.changeState(.idle) } }
            catch { await self.fail(error, generation: id) }
        }
    }

    func ingest(point: CGPoint, displayID: String, displayBounds: CGRect, buttons: UInt64, at time: TimeInterval) {
        guard isActive, state == .listening else { return }
        builder?.sample(point: point, displayID: displayID, displayBounds: displayBounds, buttons: buttons, at: time)
    }

    func displaysChanged() { builder?.geometryChanged(primaryTop: dependencies.primaryTop()) }

    private func run(_ id: UUID) async {
        defer {
            if current(id), !isActive, state != .failed {
                builder = nil
                changeState(.idle)
            }
        }
        do {
            let target = try await dependencies.prepare()
            guard current(id), isActive else { return }
            let conversationID = UUID().uuidString, start = dependencies.now()
            while current(id), isActive {
                boundaryRequested = false; captureFailure = nil
                changeState(.preparing)
                let next = PointerTurnContextBuilder(target: target, conversationID: conversationID, conversationStart: start,
                                                     captureStart: dependencies.now(), primaryTop: dependencies.primaryTop())
                builder = next
                try await captureFrame(into: next, generation: id)
                guard current(id), isActive else { return }
                try await dependencies.startRecording()
                guard current(id), isActive else { await dependencies.cancelRecording(); return }
                let initialSnapshot = await dependencies.snapshot()
                guard current(id), isActive else { await dependencies.cancelRecording(); return }
                let audioStart = dependencies.now() - max(0, initialSnapshot.elapsed)
                next.recordingStarted(at: audioStart)
                changeState(.listening)
                var activity = MagicPointerVoiceActivity()
                captureTask = Task { [weak self] in await self?.captureLoop(into: next, generation: id) }
                var boundary: MagicPointerVoiceActivity.Boundary = .recording
                while current(id), !closeRequested, !boundaryRequested, captureFailure == nil {
                    let snapshot = await dependencies.snapshot()
                    guard current(id) else { return }
                    audioLevel = snapshot.level
                    boundary = activity.update(elapsed: snapshot.elapsed, level: snapshot.level, powerDBFS: snapshot.powerDBFS)
                    if boundary != .recording { break }
                    try await dependencies.sleep(0.06)
                }
                captureTask?.cancel(); captureTask = nil
                guard current(id) else { return }
                let end = dependencies.now()
                let audio = try await dependencies.stopRecording()
                guard current(id) else { try? FileManager.default.removeItem(at: audio.fileURL); return }
                audioLevel = 0
                retainedTurn = RecordedTurn(audio: audio, builder: next,
                                            speechStart: activity.firstSpeechAt.map { audioStart + $0 }, end: end,
                                            truncated: audio.duration >= activity.maximumDuration)
                builder = nil
                if let captureFailure { throw captureFailure }
                if activity.firstSpeechAt == nil {
                    // No inferred transcription from silence. Empty bounded recordings start a fresh turn.
                    discardRetainedTurn()
                    if !isActive { break }
                    continue
                }
                try await processRetainedTurn(id)
            }
            if current(id) { changeState(.idle) }
        } catch { await fail(error, generation: id) }
    }

    private func processRetainedTurn(_ id: UUID) async throws {
        guard let retainedTurn else { return }
        changeState(.finalizingTurn)
        if pendingPayload == nil {
            let text = try await dependencies.transcribe(retainedTurn.audio).trimmingCharacters(in: .whitespacesAndNewlines)
            guard current(id) else { return }
            guard !text.isEmpty else { discardRetainedTurn(); return }
            pendingPayload = try retainedTurn.builder.makePayload(text: text, speechStart: retainedTurn.speechStart,
                                                                 endedAt: retainedTurn.end, truncated: retainedTurn.truncated)
        }
        guard current(id), let payload = pendingPayload else { return }
        try dependencies.validateTarget(.init(deviceID: payload.context.deviceID, agentID: payload.context.agentID, sessionID: payload.context.sessionID))
        // Existing messages endpoint has no idempotency contract: never auto-replay an uncertain submission.
        submissionUncertain = true
        try await dependencies.submit(payload)
        guard current(id) else { return }
        discardRetainedTurn()
        guard isActive else { return }
        changeState(.agentWorking)
        let deadline = dependencies.now() + 300
        while current(id), isActive {
            guard dependencies.now() < deadline else { throw MagicPointerError.responseTimeout }
            let reply = try await dependencies.reply()
            guard current(id), isActive else { return }
            switch reply {
            case .waiting:
                changeState(.agentWorking)
            case .needsInput:
                if state != .waitingForInput { changeState(.waitingForInput); onNeedsInput?() }
            case .interrupted:
                throw MagicPointerError.interrupted
            case .complete(let text):
                changeState(.speaking)
                await dependencies.speak(text)
                return
            }
            try await dependencies.sleep(0.3)
        }
    }

    private func captureFrame(into builder: PointerTurnContextBuilder, generation id: UUID) async throws {
        guard current(id), isActive else { return }
        let point = dependencies.point(), start = dependencies.now(), revision = builder.geometryRevision
        let context = dependencies.desktopContext(point)
        let image = try await dependencies.capture(context)
        guard current(id), isActive else { return }
        guard revision == builder.geometryRevision else { builder.omittedCapture(); return }
        builder.addCapture(image, context: context, startedAt: start, finishedAt: dependencies.now())
    }

    private func captureLoop(into builder: PointerTurnContextBuilder, generation id: UUID) async {
        do {
            while current(id), isActive, state == .listening {
                try await captureFrame(into: builder, generation: id)
                try await dependencies.sleep(0.5)
            }
        } catch {
            if current(id), isActive, !Task.isCancelled { captureFailure = error }
        }
    }

    private func fail(_ failure: Error, generation id: UUID) async {
        guard current(id) else { return }
        isActive = false; audioLevel = 0
        captureTask?.cancel(); captureTask = nil
        dependencies.stopSpeaking()
        await dependencies.cancelRecording()
        guard current(id) else { return }
        error = submissionUncertain ? "Turn delivery could not be confirmed. Check the chat before sending it again." : failure.localizedDescription
        changeState(.failed)
        if let error { onError?(error) }
    }

    private func discardRetainedTurn() {
        if let file = retainedTurn?.audio.fileURL { try? FileManager.default.removeItem(at: file) }
        retainedTurn = nil; pendingPayload = nil; submissionUncertain = false
    }

    private func current(_ id: UUID) -> Bool { generation == id && !Task.isCancelled }
    private func changeState(_ state: State) {
        guard self.state != state else { return }
        self.state = state
        onStateChanged?()
    }
}

private enum MagicPointerError: LocalizedError {
    case responseTimeout, interrupted
    var errorDescription: String? {
        switch self {
        case .responseTimeout: "The agent is still working. You can continue in the Desktop Companion chat."
        case .interrupted: "The agent was stopped."
        }
    }
}
