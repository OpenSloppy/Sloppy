import Foundation
import CoreGraphics
import Testing
@testable import SloppyDesktopCompanion

@Suite("Desktop pointer interaction")
struct DesktopPointerInteractionTests {
    @Test @MainActor func quickDoubleTapHidesForEitherHotkey() {
        for (key, flags) in [(UInt16(61), UInt64(0x80040)), (54, 0x100010)] {
            let shortcut = DesktopPointerShortcut(mode: .modifier)
            var hidden = 0
            var releases: [DesktopPointerShortcutState.Release] = []
            shortcut.onDoubleTap = { hidden += 1 }
            shortcut.onReleased = { releases.append($0) }
            shortcut.handleModifiers(keyCode: key, rawFlags: flags, at: 10)
            shortcut.handleModifiers(keyCode: key, rawFlags: 0, at: 10.02)
            shortcut.handleModifiers(keyCode: key, rawFlags: flags, at: 10.1)
            shortcut.handleModifiers(keyCode: key, rawFlags: 0, at: 10.12)
            #expect(hidden == 1)
            #expect(releases == [.tap])
            shortcut.stop()
        }
    }

    @Test func slowTapsAndDifferentModifiersDoNotHide() {
        var taps = DesktopPointerTapSequence()
        let first = taps.registerTap(keyCode: 61, at: 10)
        let otherKey = taps.registerTap(keyCode: 54, at: 10.1)
        let slow = taps.registerTap(keyCode: 54, at: 11)
        let second = taps.registerTap(keyCode: 54, at: 11.2)
        let third = taps.registerTap(keyCode: 54, at: 11.3)
        #expect(!first && !otherKey && !slow)
        #expect(second && !third)
    }

    @Test @MainActor func commandCombinationBreaksDoubleTapSequence() {
        let shortcut = DesktopPointerShortcut(mode: .modifier)
        defer { shortcut.stop() }
        var hidden = 0
        shortcut.onDoubleTap = { hidden += 1 }
        shortcut.handleModifiers(keyCode: 54, rawFlags: 0x100010, at: 10)
        shortcut.handleModifiers(keyCode: 54, rawFlags: 0, at: 10.02)
        shortcut.handleModifiers(keyCode: 54, rawFlags: 0x100010, at: 10.1)
        shortcut.cancelForOtherInput()
        shortcut.handleModifiers(keyCode: 54, rawFlags: 0, at: 10.12)
        shortcut.handleModifiers(keyCode: 54, rawFlags: 0x100010, at: 10.15)
        shortcut.handleModifiers(keyCode: 54, rawFlags: 0, at: 10.2)
        #expect(hidden == 0)
    }

    @Test func movedPanelPositionSurvivesLayoutUpdate() {
        let screen = CGRect(x: -1920, y: -300, width: 1920, height: 1080)
        for expanded in [true, false] {
            let layout = DesktopCompanionLayout(expanded: expanded, showsResponse: true, composerHeight: 44, responseHeight: 120)
            let movedFrame = CGRect(origin: CGPoint(x: -1500, y: -100), size: layout.size)
            let anchor = DesktopPointerGeometry.anchor(for: movedFrame, orbOffset: layout.orbOffset)
            let frame = DesktopPointerGeometry.panelFrame(anchor: anchor, size: movedFrame.size,
                                                         visibleFrame: screen, orbOffset: layout.orbOffset)
            #expect(frame == movedFrame)
        }
    }

    @Test @MainActor func rightCommandTapInvokesComposerButLeftCommandDoesNot() {
        let shortcut = DesktopPointerShortcut(mode: .modifier)
        defer { shortcut.stop() }
        var presses = 0
        var releases: [DesktopPointerShortcutState.Release] = []
        shortcut.onPressed = { presses += 1 }
        shortcut.onReleased = { releases.append($0) }
        shortcut.handleModifiers(keyCode: 55, rawFlags: 0x100008)
        shortcut.handleModifiers(keyCode: 55, rawFlags: 0)
        #expect(presses == 0)
        shortcut.handleModifiers(keyCode: 54, rawFlags: 0x100010)
        shortcut.handleModifiers(keyCode: 54, rawFlags: 0)
        #expect(presses == 1)
        #expect(releases == [.tap])
    }

    @Test @MainActor func commandShortcutCancelsInvocationWithoutReopeningOnRelease() {
        let shortcut = DesktopPointerShortcut(mode: .modifier)
        defer { shortcut.stop() }
        var cancelled = 0
        var releases: [DesktopPointerShortcutState.Release] = []
        shortcut.onCancelled = { cancelled += 1 }
        shortcut.onReleased = { releases.append($0) }
        shortcut.handleModifiers(keyCode: 54, rawFlags: 0x100010)
        shortcut.cancelForOtherInput() // The keyDown for Cmd+C remains unconsumed.
        shortcut.handleModifiers(keyCode: 54, rawFlags: 0)
        #expect(cancelled == 1)
        #expect(releases.isEmpty)
        shortcut.handleModifiers(keyCode: 61, rawFlags: 0x80040)
        shortcut.handleModifiers(keyCode: 61, rawFlags: 0)
        #expect(releases == [.tap])
    }

    @Test func modifierMustBePressedAlone() {
        #expect(DesktopPointerModifier.rightCommand.isStandalone(rawFlags: 0x100010))
        #expect(!DesktopPointerModifier.rightCommand.isStandalone(rawFlags: 0x100018)) // Both Cmd keys.
        #expect(!DesktopPointerModifier.rightCommand.isStandalone(rawFlags: 0x120014)) // Cmd+Shift.
        #expect(!DesktopPointerModifier.rightCommand.isStandalone(rawFlags: 0x180050)) // Cmd+Option.
        #expect(!DesktopPointerModifier.rightOption.isStandalone(rawFlags: 0x180050))
        #expect(DesktopPointerModifier.leftOption.isStandalone(rawFlags: 0x80020))
    }

    @Test func shortPressOpensComposer() {
        var shortcut = DesktopPointerShortcutState()
        shortcut.press(at: 10)
        let earlyWheel = shortcut.presentWheel(at: 10.1)
        let released = shortcut.release()
        let repeated = shortcut.release()
        #expect(!earlyWheel)
        #expect(released == .tap)
        #expect(repeated == nil)
    }

    @Test func holdingOpensWheelOnce() {
        var shortcut = DesktopPointerShortcutState()
        shortcut.press(at: 10)
        let wheel = shortcut.presentWheel(at: 10.3)
        let repeated = shortcut.presentWheel(at: 10.4)
        let released = shortcut.release()
        #expect(wheel)
        #expect(!repeated)
        #expect(released == .wheel)
    }

    @Test func ordinaryOptionCombinationDoesNotInvokePointer() {
        var shortcut = DesktopPointerShortcutState()
        shortcut.press(at: 10)
        shortcut.cancel()
        let wheel = shortcut.presentWheel(at: 11)
        let released = shortcut.release()
        #expect(!wheel)
        #expect(released == nil)
    }

    @Test func wheelHasDeadZoneAndStableDirections() {
        #expect(DesktopPointerAction.at(offset: CGPoint(x: 12, y: 12)) == nil)
        #expect(DesktopPointerAction.at(offset: CGPoint(x: 0, y: 100)) == .write)
        #expect(DesktopPointerAction.at(offset: CGPoint(x: 87, y: 50)) == .region)
        #expect(DesktopPointerAction.at(offset: CGPoint(x: 87, y: -50)) == .regionVoice)
        #expect(DesktopPointerAction.at(offset: CGPoint(x: 0, y: -100)) == .voice)
        #expect(DesktopPointerAction.at(offset: CGPoint(x: -87, y: -50)) == .window)
        #expect(DesktopPointerAction.at(offset: CGPoint(x: -87, y: 50)) == .chat)
    }

    @Test func keepsPanelOnDisplaysWithNegativeOrigins() {
        let screen = CGRect(x: -1920, y: -300, width: 1920, height: 1080)
        for point in [CGPoint(x: -1920, y: -300), CGPoint(x: -1, y: 779)] {
            for expanded in [true, false] {
                let layout = DesktopCompanionLayout(expanded: expanded, showsResponse: true, composerHeight: 100, responseHeight: 240)
                let frame = DesktopPointerGeometry.panelFrame(anchor: point, size: layout.size, visibleFrame: screen, orbOffset: layout.orbOffset)
                #expect(screen.contains(frame))
            }
        }
    }

    @Test func wheelSelectionUsesVisibleCenterWhenClampedAtScreenEdge() {
        let invocation = CGPoint(x: 100, y: 100)
        let center = CGPoint(x: 100, y: 0)
        #expect(DesktopPointerAction.at(pointer: invocation, wheelCenter: center, invocationPoint: invocation) == nil)
        #expect(DesktopPointerAction.at(pointer: CGPoint(x: 187, y: 50), wheelCenter: center, invocationPoint: invocation) == .region)
        #expect(DesktopPointerAction.at(pointer: CGPoint(x: 132, y: 100), wheelCenter: center, invocationPoint: invocation) == .write)
        #expect(DesktopPointerAction.at(pointer: center, wheelCenter: center, invocationPoint: invocation) == nil)
    }

    @Test func convertsRegionWithoutApplyingRetinaScaleToScreenCoordinates() {
        let region = CGRect(x: -1200, y: 400, width: 200, height: 100)
        #expect(DesktopPointerGeometry.quartzRect(region, primaryScreenTop: 900) == CGRect(x: -1200, y: 400, width: 200, height: 100))
    }

    @Test @MainActor func stopRevokesRemainingTypedCharacters() async throws {
        var posted = 0
        let input = DesktopComputerInput(post: { _ in posted += 1 })
        await #expect(throws: CancellationError.self) {
            try await input.type("hello") { posted < 2 }
        }
        #expect(posted == 2)
    }

    @Test @MainActor func emojiUsesOneCompleteUnicodeEventPair() async throws {
        var events: [CGEvent] = []
        let input = DesktopComputerInput(post: { events.append($0) })
        try await input.type("🙂") { true }
        #expect(events.count == 2)
        var count = 0
        var units = [UniChar](repeating: 0, count: 8)
        events[0].keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &count, unicodeString: &units)
        #expect(String(utf16CodeUnits: units, count: count) == "🙂")
    }
}
