import Foundation
import Testing
import SloppyClientCore
@testable import SloppyDesktopCompanion

@Suite("Magic Pointer gestures and evidence")
struct MagicPointerInteractionTests {
    @Test @MainActor func leftOptionIsIndependentOfLegacyShortcutMode() {
        for mode in [DesktopPointerShortcutMode.optionSpace, .modifier] {
            let shortcut = DesktopPointerShortcut(mode: mode, magicPointerEnabled: true)
            defer { shortcut.stop() }
            var voices = 0, legacy = 0
            shortcut.onMagicPointer = { voices += 1 }
            shortcut.onDoubleTap = { legacy += 1 }
            shortcut.onPressed = { legacy += 1 }
            shortcut.onReleased = { _ in legacy += 1 }
            for (time, flags) in [(10.0, UInt64(0x80020)), (10.04, 0), (10.15, 0x80020), (10.19, 0)] {
                shortcut.handleModifiers(keyCode: 58, rawFlags: flags, at: time)
            }
            #expect(voices == 1)
            #expect(legacy == 0)
        }
    }

    @Test func doubleTapRequiresTwoShortCompletePresses() {
        var gesture = MagicPointerTapGesture()
        let results = [gesture.handle(keyCode: 58, rawFlags: 0x80020, at: 10),
                       gesture.handle(keyCode: 58, rawFlags: 0x80020, at: 10.01), // Repeat while held.
                       gesture.handle(keyCode: 58, rawFlags: 0, at: 10.03),
                       gesture.handle(keyCode: 58, rawFlags: 0, at: 10.04), // Extra release.
                       gesture.handle(keyCode: 58, rawFlags: 0x80020, at: 10.15),
                       gesture.handle(keyCode: 58, rawFlags: 0, at: 10.18)]
        #expect(results == [false, false, false, false, false, true])
    }

    @Test @MainActor func rightOptionDoesNotStartMagicPointerAndKeepsLegacyGestures() {
        let shortcut = DesktopPointerShortcut(mode: .modifier, magicPointerEnabled: true)
        defer { shortcut.stop() }
        var voices = 0, hidden = 0, releases = 0
        shortcut.onMagicPointer = { voices += 1 }
        shortcut.onDoubleTap = { hidden += 1 }
        shortcut.onReleased = { _ in releases += 1 }
        for (time, flags) in [(10.0, UInt64(0x80040)), (10.03, 0), (10.12, 0x80040), (10.15, 0)] {
            shortcut.handleModifiers(keyCode: 61, rawFlags: flags, at: time)
        }
        #expect(voices == 0)
        #expect(hidden == 1 && releases == 1)
    }

    @Test func holdsChordsOtherKeysAndSlowTapsDoNotActivate() {
        for reason in [0, 1, 2, 3, 4] {
            var gesture = MagicPointerTapGesture()
            _ = gesture.handle(keyCode: 58, rawFlags: 0x80020, at: 10)
            _ = gesture.handle(keyCode: 58, rawFlags: 0, at: 10.02)
            switch reason {
            case 0: gesture.cancel() // A mouse/regular key event.
            case 1: _ = gesture.handle(keyCode: 61, rawFlags: 0x80040, at: 10.05)
            case 2: _ = gesture.handle(keyCode: 58, rawFlags: 0xA0024, at: 10.05)
            case 3: _ = gesture.handle(keyCode: 58, rawFlags: 0x80020, at: 10.05); _ = gesture.handle(keyCode: 58, rawFlags: 0, at: 10.4)
            default: break
            }
            let start = reason == 4 ? 11.0 : (reason == 3 ? 10.5 : 10.15)
            _ = gesture.handle(keyCode: 58, rawFlags: 0x80020, at: start)
            let triggered = gesture.handle(keyCode: 58, rawFlags: 0, at: start + 0.02)
            #expect(!triggered)
        }
    }

    @Test @MainActor func commandGestureAndOptionSpaceRemainAvailable() {
        let shortcut = DesktopPointerShortcut(mode: .modifier, magicPointerEnabled: true)
        defer { shortcut.stop() }
        var releases = 0, rings = 0, voices = 0
        shortcut.onReleased = { _ in releases += 1 }
        shortcut.onActionRing = { rings += 1 }
        shortcut.onMagicPointer = { voices += 1 }
        shortcut.handleModifiers(keyCode: 54, rawFlags: 0x100010, at: 10)
        shortcut.handleModifiers(keyCode: 54, rawFlags: 0, at: 10.05)
        shortcut.handleOptionSpace(pressed: true)
        shortcut.handleOptionSpace(pressed: false)
        #expect(releases == 1 && rings == 1 && voices == 0)
    }

    @Test func voiceActivityRejectsClicksAndWaitsForSpeechThenSilence() {
        var activity = MagicPointerVoiceActivity()
        let click = activity.update(elapsed: 0, level: 0.2)
        let afterClick = activity.update(elapsed: 0.05, level: 0.04)
        #expect(click == .recording && afterClick == .recording)
        #expect(activity.firstSpeechAt == nil)
        for time in [1.0, 1.06, 1.13, 1.2] {
            let boundary = activity.update(elapsed: time, level: 0.2)
            #expect(boundary == .recording)
        }
        #expect(activity.firstSpeechAt == 1.0)
        let shortPause = activity.update(elapsed: 1.8, level: 0.04)
        let completed = activity.update(elapsed: 2.05, level: 0.04)
        #expect(shortPause == .recording && completed == .speechEnded)
        var empty = MagicPointerVoiceActivity()
        let emptyLimit = empty.update(elapsed: 60, level: 0.04)
        #expect(emptyLimit == .emptyLimit)
    }

    @Test @MainActor func fadingTailDoesNotRemoveTurnEvidence() {
        var trail = PointerTrailHistory()
        let target = MagicPointerTarget(deviceID: "device", agentID: "agent", sessionID: "session")
        let builder = PointerTurnContextBuilder(target: target, conversationID: "conversation", conversationStart: 10, captureStart: 10, primaryTop: 900)
        let display = CGRect(x: -1_920, y: -300, width: 1_920, height: 1_080)
        for index in 0..<20 {
            let point = CGPoint(x: -1_000 + index * 4, y: 400), time = 10 + Double(index) * 0.03
            trail.append(point: point, displayID: "left", at: time)
            builder.sample(point: point, displayID: "left", displayBounds: display, buttons: 0, at: time)
        }
        trail.expire(at: 12)
        #expect(trail.points.isEmpty)
        #expect(builder.context.samples.count == 20)
        #expect(builder.context.samples.first?.x == -1_000)
        #expect(builder.context.samples.first?.y == 500)
        #expect(builder.context.displays.first?.bounds.cgRect == CGRect(x: -1_920, y: 120, width: 1_920, height: 1_080))
    }

    @Test func displayChangesAndWarpsBreakTrailSegments() throws {
        var trail = PointerTrailHistory()
        trail.append(point: CGPoint(x: 0, y: 0), displayID: "one", at: 10)
        trail.append(point: CGPoint(x: 50, y: 0), displayID: "two", at: 10.1)
        trail.append(point: CGPoint(x: 900, y: 0), displayID: "two", at: 10.2)
        #expect(trail.points.map(\.segmentID) == [0, 1, 2])
        #expect(PointerTrailHistory.opacity(age: 1) == 0)
        #expect(PointerTrailHistory.width(age: 0) == 18)
    }

    @Test func croppedRetinaFrameUsesScreenPointsAndItsOwnScale() {
        let frame = PointerTurnContext.Frame(id: "f", captureStartMs: 100, captureEndMs: 120, attachmentName: "f.png", annotatedAttachmentName: "a.png",
                                            displayID: "left", screenRect: CGRect(x: -1_200, y: 300, width: 400, height: 200), pixelWidth: 800, pixelHeight: 400)
        let point = PointerTurnContext.Sample(tMs: 110, point: CGPoint(x: -1_000, y: 350), displayID: "left", segmentID: 0)
        #expect(frame.pixelPoint(for: point) == CGPoint(x: 400, y: 100))
        var other = point; other.displayID = "main"
        #expect(frame.pixelPoint(for: other) == nil)
    }

    @Test func jsonBudgetPreservesEndpointsAndReportsTruncation() throws {
        var context = PointerTurnContext(conversationID: "c", deviceID: "d", agentID: "a", sessionID: "s", captureStartMs: 0)
        context.samples = (0..<3_600).map { .init(tMs: $0 * 17, point: CGPoint(x: $0, y: $0), displayID: "display", segmentID: 0) }
        let data = try context.encoded(maxBytes: 4_096)
        let roundTrip = try JSONDecoder().decode(PointerTurnContext.self, from: data)
        #expect(data.count <= 4_096)
        #expect(roundTrip.samples.first?.tMs == 0)
        #expect(roundTrip.samples.last?.tMs == 3_599 * 17)
        #expect(roundTrip.coverage.droppedSamples == 3_600 - roundTrip.samples.count)
        #expect(roundTrip.coverage.truncated)
        #expect(roundTrip.contentTrust == "untrusted_screen_content")
        #expect(roundTrip.utterance.wordAlignment == "unavailable")
    }

    @Test @MainActor func reservedOptionCancelsPendingCommandChordWithoutOpeningComposer() {
        let shortcut = DesktopPointerShortcut(mode: .modifier, magicPointerEnabled: true)
        defer { shortcut.stop() }
        var releases = 0, cancelled = 0, voice = 0
        shortcut.onReleased = { _ in releases += 1 }
        shortcut.onCancelled = { cancelled += 1 }
        shortcut.onMagicPointer = { voice += 1 }
        shortcut.handleModifiers(keyCode: 54, rawFlags: 0x100010, at: 10)
        shortcut.handleModifiers(keyCode: 58, rawFlags: 0x180030, at: 10.1)
        shortcut.handleModifiers(keyCode: 54, rawFlags: 0x80020, at: 10.2)
        shortcut.handleModifiers(keyCode: 58, rawFlags: 0, at: 10.25)
        #expect(cancelled == 1 && releases == 0 && voice == 0)
    }

    @Test @MainActor func displayReconfigurationDoesNotApplyOldPointsToNewFrames() {
        let builder = PointerTurnContextBuilder(target: .init(deviceID: "d", agentID: "a", sessionID: "s"),
                                               conversationID: "c", conversationStart: 10, captureStart: 10, primaryTop: 900)
        let bounds = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        builder.sample(point: CGPoint(x: 200, y: 400), displayID: "main", displayBounds: bounds, buttons: 0, at: 10)
        builder.geometryChanged(primaryTop: 1_000)
        builder.sample(point: CGPoint(x: 200, y: 400), displayID: "main", displayBounds: CGRect(x: 0, y: 0, width: 1_440, height: 1_000), buttons: 0, at: 10.2)
        let frame = PointerTurnContext.Frame(id: "f", captureStartMs: 200, captureEndMs: 210,
                                            attachmentName: "f.png", annotatedAttachmentName: "a.png", displayID: "main",
                                            screenRect: CGRect(x: 0, y: 0, width: 1_440, height: 1_000), pixelWidth: 2_880, pixelHeight: 2_000, geometryRevision: 1)
        #expect(builder.context.samples.map(\.geometryRevision) == [0, 1])
        #expect(builder.context.samples.map(\.y) == [500, 600])
        #expect(builder.context.samples.map(\.segmentID) == [0, 1])
        #expect(frame.pixelPoint(for: builder.context.samples[0]) == nil)
        #expect(frame.pixelPoint(for: builder.context.samples[1]) == CGPoint(x: 400, y: 1_200))
    }

    @Test func quietSpeechUsesRawPowerInsteadOfTheOrbsDisplayFloor() {
        var activity = MagicPointerVoiceActivity()
        for time in [0.0, 0.06, 0.13, 0.2] {
            let state = activity.update(elapsed: time, level: 0.04, powerDBFS: -38)
            #expect(state == .recording)
        }
        let boundary = activity.update(elapsed: 1.05, level: 0.04, powerDBFS: -70)
        #expect(activity.firstSpeechAt == 0)
        #expect(boundary == .speechEnded)
    }

    @Test @MainActor func permissionPreparationDoesNotShiftAudioCaptureStartToAnEarlierFrame() {
        let builder = PointerTurnContextBuilder(target: .init(deviceID: "d", agentID: "a", sessionID: "s"),
                                               conversationID: "c", conversationStart: 10, captureStart: 10, primaryTop: 900)
        builder.recordingStarted(at: 25)
        #expect(builder.context.utterance.captureStartMs == 15_000)
        #expect(builder.context.utterance.startMs == 15_000)
    }
}
