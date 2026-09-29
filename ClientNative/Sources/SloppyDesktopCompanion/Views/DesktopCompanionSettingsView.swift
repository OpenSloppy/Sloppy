import SwiftUI

struct DesktopCompanionSettingsView: View {
    @Bindable var model: DesktopCompanionModel
    var requestAccessibility: () -> Void
    var applyShortcut: () -> Void

    var body: some View {
        Form {
            Section("Local Sloppy") {
                LabeledContent("Instance") { Text(model.coreAddress).textSelection(.enabled) }
                    .accessibilityIdentifier("companion.core-address")
                if !model.agents.isEmpty {
                    Picker("Agent", selection: $model.selectedAgentID) {
                        ForEach(model.agents) { agent in Text(agent.displayName).tag(agent.id) }
                    }
                    .disabled(model.isConnecting || model.canStop || model.isStopping)
                }
                Button(model.isConnecting ? "Connecting…" : "Reconnect") {
                    Task { await model.connect(); applyShortcut() }
                }.disabled(model.isConnecting || model.canStop || model.isStopping)
                    .accessibilityIdentifier("companion.connect")
                Button("Open Sloppy") { model.openDesktop() }
                Text("Uses Sloppy desktop's local instance and saved sign-in. Desktop Companion appears in Sloppy's chat list.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Shortcut") {
                Toggle("Magic Pointer · Right Option ×2", isOn: $model.magicPointerEnabled)
                    .onChange(of: model.magicPointerEnabled) { _, _ in model.saveMagicPointerPreferences(); applyShortcut() }
                    .accessibilityIdentifier("companion.magic-pointer-enabled")
                Text("Двойной Right Option включает голос и след курсора поверх всех приложений. Повторите, чтобы закончить разговор; Escape отменяет текущую реплику.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("⌥ Space opens the action ring. Click an action; press Escape to close.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Additional shortcuts", selection: $model.shortcutMode) {
                    ForEach(DesktopPointerShortcutMode.allCases) { mode in Text(mode.title).tag(mode) }
                }.onChange(of: model.shortcutMode) { _, _ in applyShortcut() }
                .accessibilityIdentifier("companion.shortcut-mode")
                if model.shortcutMode == .modifier {
                    Picker("Key", selection: $model.optionKeyCode) {
                        Text("Right Option").tag(61)
                        Text("Left Option").tag(58)
                    }.onChange(of: model.optionKeyCode) { _, _ in applyShortcut() }
                    Toggle("Also use Right Command (⌘)", isOn: $model.rightCommandEnabled)
                        .onChange(of: model.rightCommandEnabled) { _, _ in applyShortcut() }
                    Text(model.magicPointerEnabled ? "Right Option is reserved for Magic Pointer. Other enabled modifiers: tap to write, double-tap to hide, hold for the wheel." : "Tap to write. Double-tap to hide. Hold for the action wheel. Other Option and Command shortcuts work as usual.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Either Option key works. The ring is also available from the Actions button below the orb.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Enable Accessibility", action: requestAccessibility)
                Text("Accessibility enables modifier key gestures and app control. Screen recording and microphone access are requested when first used.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Голосовой разговор") {
                Toggle("Озвучивать ответы агента", isOn: $model.voiceRepliesEnabled)
                    .onChange(of: model.voiceRepliesEnabled) { _, _ in model.saveMagicPointerPreferences() }
                Picker("Язык голоса", selection: $model.voiceLocaleIdentifier) {
                    Text("Русский").tag("ru-RU")
                    Text("English").tag("en-US")
                    Text("日本語").tag("ja-JP")
                }.onChange(of: model.voiceLocaleIdentifier) { _, _ in model.saveMagicPointerPreferences() }
                if let pointer = model.magicPointer {
                    Text(pointer.state.title).foregroundStyle(.secondary)
                    if pointer.canRetry { Button("Повторить неотправленную реплику") { pointer.retry() } }
                    if pointer.state == .failed { Button("Отменить реплику") { pointer.cancel(); model.error = nil } }
                }
            }
            if let error = model.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if let error = model.shortcutError { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            Text(model.status).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 720)
    }
}
