import Foundation
import AppKit
import Testing
import SloppyClientCore
@testable import SloppyDesktopCompanion

@Suite("Magic Pointer voice lifecycle")
@MainActor
struct MagicPointerConversationTests {
    @Test func turnReachesAgentWithFramesThenReturnsToListening() async throws {
        let harness = try Harness()
        let controller = harness.controller()
        controller.onStateChanged = {
            if controller.state == .listening {
                controller.ingest(point: CGPoint(x: 80, y: 50), displayID: "display", displayBounds: CGRect(x: 0, y: 0, width: 160, height: 100), buttons: 0, at: harness.clock)
            }
        }
        harness.onSubmit = { _ in harness.responses = [.complete("Готово")] }
        harness.onSpeak = { _ in harness.allowSnapshots = false }
        controller.start()
        await wait { harness.spoken == ["Готово"] && harness.starts == 2 && controller.state == .listening }
        #expect(harness.payloads.count == 1)
        let payload = try #require(harness.payloads.first)
        #expect(payload.context.utterance.text == "Объедини эти два")
        #expect(payload.context.frames.count >= 1)
        #expect(!payload.context.samples.isEmpty)
        #expect(payload.attachments.contains { $0.mimeType == "application/json" })
        #expect(payload.attachments.filter { $0.mimeType == "image/png" }.count >= 2)
        #expect(harness.microphoneWhileSpeaking == false)
        #expect(controller.state == .listening)
        controller.cancel()
        await wait { !harness.recording }
    }

    @Test func closingSendsFinalVoicedTurnAndDoesNotRestartMicrophone() async throws {
        let harness = try Harness()
        let controller = harness.controller()
        harness.onSnapshot = { elapsed in if elapsed >= 0.3 { controller.end() } }
        controller.start()
        await wait { controller.state == .idle && !harness.payloads.isEmpty }
        #expect(harness.starts == 1)
        #expect(harness.payloads.count == 1)
        #expect(harness.spoken.isEmpty)
        #expect(!controller.isActive && !harness.recording)
    }

    @Test func emptyActivationDoesNotCallTranscriptionOrSubmit() async throws {
        let harness = try Harness()
        harness.level = 0.04
        let controller = harness.controller()
        harness.onSnapshot = { elapsed in if elapsed >= 0.3 { controller.end() } }
        controller.start()
        await wait { controller.state == .idle && harness.stops > 0 }
        #expect(harness.transcriptions == 0)
        #expect(harness.payloads.isEmpty)
        #expect(!harness.recording)
    }

    @Test func cancellationDuringPermissionPreparationIgnoresLateCompletion() async throws {
        let harness = try Harness()
        var pending: CheckedContinuation<Void, Never>?
        var dependencies = harness.dependencies()
        dependencies.startRecording = {
            harness.starts += 1
            await withCheckedContinuation { pending = $0 }
            harness.recording = true
        }
        let controller = MagicPointerConversationController(dependencies: dependencies)
        controller.start()
        await wait { pending != nil }
        controller.cancel()
        pending?.resume(); pending = nil
        await wait { !harness.recording && harness.cancels >= 2 }
        #expect(controller.state == .idle)
        #expect(harness.payloads.isEmpty)
        #expect(harness.spoken.isEmpty)
    }

    @Test func uncertainSubmissionIsRetainedAndNeverAutomaticallyReplayed() async throws {
        let harness = try Harness()
        harness.submitError = TestFailure.network
        let controller = harness.controller()
        controller.start()
        await wait { controller.state == .failed }
        #expect(controller.pendingPayload?.context.utterance.text == "Объедини эти два")
        #expect(controller.submissionUncertain)
        #expect(!controller.canRetry)
        controller.retry(); controller.toggle()
        await Task.yield()
        #expect(harness.submitAttempts == 1)
        #expect(harness.starts == 1)
        controller.cancel()
        #expect(controller.pendingPayload == nil)
    }

    @Test func transcriptionFailureCanBeRetriedWithoutRecordingAgain() async throws {
        let harness = try Harness()
        harness.transcriptionError = TestFailure.transcription
        let controller = harness.controller()
        controller.start()
        await wait { controller.state == .failed }
        #expect(controller.canRetry)
        #expect(FileManager.default.fileExists(atPath: harness.audioURL.path))
        harness.transcriptionError = nil
        controller.retry()
        await wait { controller.state == .idle && harness.submitAttempts == 1 }
        #expect(harness.starts == 1)
        #expect(harness.transcriptions == 2)
        #expect(!FileManager.default.fileExists(atPath: harness.audioURL.path))
    }

    @Test func captureFailureStopsBeforeMicrophoneStarts() async throws {
        let harness = try Harness()
        var dependencies = harness.dependencies()
        dependencies.capture = { _ in throw TestFailure.capture }
        let controller = MagicPointerConversationController(dependencies: dependencies)
        controller.start()
        await wait { controller.state == .failed }
        #expect(harness.starts == 0)
        #expect(harness.payloads.isEmpty)
        #expect(!controller.isActive)
    }

    @Test func lateAgentReplyCannotStartSpeechAfterCancellation() async throws {
        let harness = try Harness()
        var pending: CheckedContinuation<MagicPointerConversationController.Reply, Never>?
        var dependencies = harness.dependencies()
        dependencies.reply = { await withCheckedContinuation { pending = $0 } }
        let controller = MagicPointerConversationController(dependencies: dependencies)
        controller.start()
        await wait { pending != nil }
        controller.cancel()
        pending?.resume(returning: .complete("Поздний ответ")); pending = nil
        await Task.yield(); await Task.yield()
        #expect(harness.spoken.isEmpty)
        #expect(controller.state == .idle)
    }

    @Test func closingDuringPreparationReturnsToIdleAfterPermissionCompletes() async throws {
        let harness = try Harness()
        var pending: CheckedContinuation<Void, Never>?
        var dependencies = harness.dependencies()
        dependencies.startRecording = {
            await withCheckedContinuation { pending = $0 }
            harness.recording = true
        }
        let controller = MagicPointerConversationController(dependencies: dependencies)
        controller.start()
        await wait { pending != nil }
        controller.end()
        pending?.resume(); pending = nil
        await wait { controller.state == .idle && !harness.recording }
        #expect(harness.payloads.isEmpty)
        #expect(!controller.isBusy)
    }

    private func wait(_ predicate: () -> Bool) async {
        for _ in 0..<2_000 {
            if predicate() { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for a deterministic voice lifecycle transition")
    }

    private enum TestFailure: Error { case network, transcription, capture }

    @MainActor
    private final class Harness {
        var clock = 100.0
        var elapsed = 0.0
        var starts = 0, stops = 0, cancels = 0, transcriptions = 0, submitAttempts = 0
        var recording = false
        var level = 0.2
        var allowSnapshots = true
        var payloads: [MagicPointerTurnPayload] = []
        var responses: [MagicPointerConversationController.Reply] = [.waiting]
        var spoken: [String] = []
        var microphoneWhileSpeaking = false
        var submitError: Error?
        var transcriptionError: Error?
        var onSubmit: ((MagicPointerTurnPayload) -> Void)?
        var onSpeak: ((String) -> Void)?
        var onSnapshot: ((Double) -> Void)?
        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("magic-pointer-test-\(UUID().uuidString).m4a")
        let image: Data

        init() throws {
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 160, pixelsHigh: 100,
                                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let bytes = try #require(bitmap.bitmapData)
            for i in 0..<bitmap.bytesPerRow * bitmap.pixelsHigh { bytes[i] = i % 4 == 3 ? 255 : 90 }
            image = try #require(bitmap.representation(using: .png, properties: [:]))
        }

        func controller() -> MagicPointerConversationController { .init(dependencies: dependencies()) }

        func dependencies() -> MagicPointerConversationController.Dependencies {
            .init(
                prepare: { .init(deviceID: "device", agentID: "agent", sessionID: "session") },
                validateTarget: { target in #expect(target.sessionID == "session") },
                point: { CGPoint(x: 80, y: 50) }, primaryTop: { 100 },
                desktopContext: { point in .init(application: "Preview", applicationPID: nil, pointer: point,
                                                quartzPointer: CGPoint(x: point.x, y: 100 - point.y), capturedAt: Date()) },
                capture: { _ in .init(png: self.image, frame: CGRect(x: 0, y: 0, width: 160, height: 100), displayId: "display", width: 160, height: 100) },
                startRecording: {
                    self.starts += 1; self.recording = true; self.elapsed = 0
                    try Data([0, 1, 2]).write(to: self.audioURL)
                },
                snapshot: {
                    if !self.allowSnapshots { await Task.yield(); return .init(elapsed: self.elapsed, level: 0.04) }
                    self.elapsed += 0.06; self.clock += 0.06
                    self.onSnapshot?(self.elapsed)
                    return .init(elapsed: self.elapsed, level: self.elapsed < 0.5 ? self.level : 0.04)
                },
                stopRecording: {
                    self.stops += 1; self.recording = false
                    return .init(fileURL: self.audioURL, mimeType: "audio/m4a", duration: self.elapsed)
                },
                cancelRecording: {
                    self.cancels += 1; self.recording = false
                },
                transcribe: { _ in
                    self.transcriptions += 1
                    if let error = self.transcriptionError { throw error }
                    return "Объедини эти два"
                },
                submit: { payload in
                    self.submitAttempts += 1
                    if let error = self.submitError { throw error }
                    self.payloads.append(payload); self.onSubmit?(payload)
                },
                reply: { self.responses.isEmpty ? .waiting : self.responses.removeFirst() },
                speak: { text in self.microphoneWhileSpeaking = self.recording; self.spoken.append(text); self.onSpeak?(text) },
                stopSpeaking: {}, now: { self.clock },
                sleep: { duration in
                    if Task.isCancelled { throw CancellationError() }
                    self.clock += duration
                    await Task.yield()
                }
            )
        }
    }
}
