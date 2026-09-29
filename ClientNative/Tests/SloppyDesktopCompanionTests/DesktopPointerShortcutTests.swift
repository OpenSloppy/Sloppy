import Foundation
import Testing
@testable import SloppyDesktopCompanion

@Suite("Desktop pointer shortcut defaults")
@MainActor
struct DesktopPointerShortcutTests {
    @Test func optionSpaceIsDefaultEvenWithSavedLegacyKeys() throws {
        let name = "DesktopPointerShortcutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(58, forKey: "companion.option-key")
        defaults.set(true, forKey: "companion.right-command")
        let model = DesktopCompanionModel(defaults: defaults)
        #expect(model.shortcutMode == .optionSpace)
        #expect(DesktopPointerShortcut().mode == .optionSpace)
        model.shortcutMode = .modifier
        model.saveShortcutPreferences()
        let restored = DesktopCompanionModel(defaults: defaults)
        #expect(restored.shortcutMode == .modifier)
        #expect(restored.optionKeyCode == 58)
        #expect(restored.rightCommandEnabled)
    }

    @Test func invalidSavedModeFallsBackToOptionSpace() throws {
        let name = "DesktopPointerShortcutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("unknown", forKey: "companion.shortcut-mode")
        #expect(DesktopCompanionModel(defaults: defaults).shortcutMode == .optionSpace)
    }

    @Test func optionSpaceOpensImmediatelyAndIgnoresRepeatsUntilRelease() {
        let shortcut = DesktopPointerShortcut()
        defer { shortcut.stop() }
        var presses = 0
        var rings = 0
        var releases = 0
        shortcut.onPressed = { presses += 1 }
        shortcut.onActionRing = { rings += 1 }
        shortcut.onReleased = { _ in releases += 1 }
        shortcut.handleOptionSpace(pressed: true)
        #expect(presses == 1 && rings == 1 && releases == 0)
        shortcut.handleOptionSpace(pressed: true)
        #expect(presses == 1)
        shortcut.handleOptionSpace(pressed: false)
        shortcut.handleOptionSpace(pressed: true)
        #expect(presses == 2 && rings == 2 && releases == 0)
    }

    @Test func defaultShortcutIgnoresStandaloneModifiers() {
        let shortcut = DesktopPointerShortcut()
        defer { shortcut.stop() }
        var presses = 0
        var releases = 0
        shortcut.onPressed = { presses += 1 }
        shortcut.onReleased = { _ in releases += 1 }
        for (key, flags) in [(UInt16(58), UInt64(0x80020)), (61, 0x80040), (54, 0x100010)] {
            shortcut.handleModifiers(keyCode: key, rawFlags: flags)
            shortcut.handleModifiers(keyCode: key, rawFlags: 0)
        }
        #expect(presses == 0 && releases == 0)
    }

    @Test func modifierModeAlsoOpensRingWithOptionSpace() {
        let shortcut = DesktopPointerShortcut(mode: .modifier)
        defer { shortcut.stop() }
        var presses = 0
        var rings = 0
        shortcut.onPressed = { presses += 1 }
        shortcut.onActionRing = { rings += 1 }
        shortcut.handleOptionSpace(pressed: true)
        shortcut.handleOptionSpace(pressed: false)
        #expect(presses == 1 && rings == 1)
        shortcut.handleModifiers(keyCode: 61, rawFlags: 0x80040)
        #expect(presses == 2)
    }

    @Test func chordCancelsPendingModifierGestureWithoutDismissingRing() {
        let shortcut = DesktopPointerShortcut(mode: .modifier)
        defer { shortcut.stop() }
        var cancelled = 0
        var released = 0
        var rings = 0
        shortcut.onCancelled = { cancelled += 1 }
        shortcut.onReleased = { _ in released += 1 }
        shortcut.onActionRing = { rings += 1 }
        shortcut.handleModifiers(keyCode: 61, rawFlags: 0x80040)
        shortcut.handleOptionSpace(pressed: true)
        shortcut.handleOptionSpace(pressed: false)
        shortcut.handleModifiers(keyCode: 61, rawFlags: 0)
        #expect(rings == 1)
        #expect(cancelled == 0 && released == 0)
    }

    @Test func shortcutErrorsRemainVisibleSeparatelyFromConnectionErrors() throws {
        let defaults = try #require(UserDefaults(suiteName: "ShortcutErrorTests.\(UUID().uuidString)"))
        let model = DesktopCompanionModel(defaults: defaults)
        model.shortcutError = "Registration failed"
        model.error = nil
        #expect(model.showsResponsePanel)
        #expect(model.shortcutError != nil)
    }

    @Test func stoppingClearsHeldChord() {
        let shortcut = DesktopPointerShortcut()
        var presses = 0
        shortcut.onPressed = { presses += 1 }
        shortcut.handleOptionSpace(pressed: true)
        shortcut.stop()
        shortcut.handleOptionSpace(pressed: true)
        #expect(presses == 2)
        shortcut.stop()
    }
}
