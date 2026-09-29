import SwiftUI
import AppKit
import SloppyClientCore
@preconcurrency import ApplicationServices

@MainActor
final class DesktopCompanionDelegate: NSObject, NSApplicationDelegate {
    let model = DesktopCompanionModel()
    private(set) var panels: DesktopPointerPanels?
    private var settingsWindow: NSWindow?
    #if DEBUG
    private var pointerPreview: MagicPointerPreview?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let panels = DesktopPointerPanels(model: model)
        panels.openSettings = { [weak self] in self?.showSettings() }
        self.panels = panels
        panels.start()
        if ProcessInfo.processInfo.arguments.contains("--preview") {
            model.draft = ""
            model.status = "Interface preview"
            panels.showBubble(expanded: true)
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--preview-pointer") {
                panels.hideBubble()
                do {
                    let preview = try MagicPointerPreview()
                    pointerPreview = preview
                    preview.show()
                    if let index = arguments.firstIndex(of: "--pointer-snapshot-path"), index + 1 < arguments.count {
                        let url = URL(fileURLWithPath: arguments[index + 1])
                        Task {
                            try? await Task.sleep(for: .seconds(1))
                            let overlayReport = await panels.verifyMagicPointer()
                            try? await Task.sleep(for: .milliseconds(100))
                            do { try preview.save(to: url, overlayReport: overlayReport) }
                            catch { model.error = error.localizedDescription }
                        }
                    }
                } catch { model.error = error.localizedDescription }
            }
            if arguments.contains("--preview-connected") { model.isConnected = true }
            if arguments.contains("--preview-working") {
                model.didSubmitPrompt("Привет")
                model.status = "Thinking…"
            }
            if arguments.contains("--preview-response") {
                model.messages = [.init(role: .assistant, segments: [.init(kind: .text, text: "Готово. Можно продолжить в основном приложении.")])]
                panels.showBubble(expanded: false)
            }
            if arguments.contains("--preview-wheel") { panels.showWheelPreview() }
            if let index = arguments.firstIndex(of: "--interaction-report-path"), index + 1 < arguments.count {
                let url = URL(fileURLWithPath: arguments[index + 1])
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    let report = panels.verifyInteractions()
                    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                        try? data.write(to: url, options: .atomic)
                    }
                }
            }
            if let index = arguments.firstIndex(of: "--snapshot-path"), index + 1 < arguments.count {
                let url = URL(fileURLWithPath: arguments[index + 1])
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    do { try panels.savePreview(to: url) }
                    catch { model.error = error.localizedDescription }
                }
            }
            #endif
        } else {
            Task {
                await model.connect()
                #if DEBUG
                let arguments = ProcessInfo.processInfo.arguments
                if let index = arguments.firstIndex(of: "--connection-report-path"), index + 1 < arguments.count {
                    try? model.saveConnectionReport(to: URL(fileURLWithPath: arguments[index + 1]))
                }
                #endif
            }
            if !AXIsProcessTrusted() { showSettings() }
        }
    }

    func showSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 460, height: 720),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Sloppy Desktop Companion"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: DesktopCompanionSettingsView(
            model: model,
            requestAccessibility: {
                _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            },
            applyShortcut: { [weak self] in self?.panels?.restartShortcut() }
        ))
        window.center()
        settingsWindow = window
        model.capture.excludedWindowIDs.insert(CGWindowID(window.windowNumber))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        #if DEBUG
        pointerPreview?.stop()
        #endif
        panels?.shutdown()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct SloppyDesktopCompanionApp: App {
    @NSApplicationDelegateAdaptor(DesktopCompanionDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Sloppy Pointer", systemImage: "sparkles") {
            Button(delegate.model.magicPointer?.isActive == true ? "Завершить голосовой режим" : "Magic Pointer (Right Option ×2)") {
                delegate.panels?.toggleMagicPointer()
            }.disabled(!delegate.model.magicPointerEnabled)
            Button("Завершить реплику") { delegate.model.magicPointer?.finishUtterance() }
                .disabled(delegate.model.magicPointer?.state != .listening)
            Divider()
            Button("Action Ring (⌥ Space)", systemImage: "circle.grid.2x2") { delegate.panels?.openActionRing() }
            Button("Show Chat") { delegate.panels?.showBubble(expanded: true) }
            Button("Hide") { delegate.panels?.hideBubble() }
            Button("Stop Agent") { Task { await delegate.model.stop() } }
                .disabled(!delegate.model.canStop || delegate.model.isStopping)
            Divider()
            Button("Settings…") { delegate.showSettings() }
            Button("Quit Companion") { NSApp.terminate(nil) }
        }
    }
}
