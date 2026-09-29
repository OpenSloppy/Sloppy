import Foundation
import AppKit
import SwiftUI

private final class DesktopPointerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class DesktopPointerPanels {
    let model: DesktopCompanionModel
    let shortcut = DesktopPointerShortcut()
    let magicOverlay: MagicPointerOverlay
    let magicPointer: MagicPointerConversationController
    var openSettings: (() -> Void)?
    private var bubble: NSPanel?
    private var wheel: NSPanel?
    private var selection: NSPanel?
    private var wheelMonitor: Any?
    private var wheelLocalMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var bubbleMoveObserver: NSObjectProtocol?
    private var isUpdatingBubbleFrame = false
    private var preparationTask: Task<Void, Never>?
    private var anchor = CGPoint.zero
    private var wheelOrigin = CGPoint.zero
    private var invocationPoint = CGPoint.zero
    private var invocationContext: DesktopPointerContext?
    private var bubbleWasVisible = false

    init(model: DesktopCompanionModel) {
        self.model = model
        magicOverlay = MagicPointerOverlay(capture: model.capture)
        magicPointer = model.installMagicPointer()
        model.onPanelChanged = { [weak self] in self?.showBubble(expanded: true) }
        model.onWillSubmit = { [weak self] in self?.bubble?.makeFirstResponder(nil) }
        model.onDesktopOpened = { [weak self] in self?.hideBubble() }
        model.onMessageSubmitted = { [weak self] in
            guard let self, !self.magicPointer.isActive else { return }
            self.showBubble(expanded: false)
        }
        shortcut.onError = { [weak model] message in model?.shortcutError = message }
        shortcut.onActionRing = { [weak self] in self?.toggleActionRing() }
        shortcut.onMagicPointer = { [weak self] in self?.toggleMagicPointer() }
        shortcut.onEscape = { [weak self] in
            guard let self, self.magicPointer.state != .idle else { return }
            self.magicPointer.cancel()
        }
        magicOverlay.onSample = { [weak magicPointer] point, id, bounds, buttons, time in
            magicPointer?.ingest(point: point, displayID: id, displayBounds: bounds, buttons: buttons, at: time)
        }
        magicOverlay.onDisplaysChanged = { [weak magicPointer] in magicPointer?.displaysChanged() }
        magicOverlay.onError = { [weak self] error in self?.magicPointer.cancel(); self?.model.error = error; self?.showBubble(expanded: true) }
        magicPointer.onStateChanged = { [weak self] in
            guard let self else { return }
            self.magicOverlay.title = self.magicPointer.state.title
            self.magicOverlay.symbol = self.magicPointer.state == .speaking ? "speaker.wave.2" : "mic"
            self.magicOverlay.updateListening(self.magicPointer.state == .listening)
            if self.magicPointer.isActive { self.magicOverlay.show() } else { self.magicOverlay.hide() }
        }
        magicPointer.onError = { [weak self] error in self?.model.error = error; self?.showBubble(expanded: true) }
        magicPointer.onNeedsInput = { [weak self] in self?.showBubble(expanded: true) }
        model.onActionRingRequested = { [weak self] in self?.openActionRing() }
        model.onLayoutChanged = { [weak self] in Task { @MainActor in self?.updateBubbleFrame() } }
        model.onYieldInputFocus = { [weak self] in
            guard let self else { return }
            self.bubble?.resignKey()
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
               let pid = self.model.context?.applicationPID {
                NSRunningApplication(processIdentifier: pid)?.activate()
            }
        }
        shortcut.onPressed = { [weak self] in
            guard let self else { return }
            self.invocationPoint = NSEvent.mouseLocation
            self.invocationContext = self.model.capture.context(at: self.invocationPoint)
        }
        shortcut.onWheel = { [weak self] in self?.showWheel() }
        shortcut.onCancelled = { [weak self] in self?.hideWheel(restoreBubble: true) }
        shortcut.onDoubleTap = { [weak self] in
            self?.hideWheel()
            self?.closeSelection()
            self?.hideBubble()
        }
        shortcut.onReleased = { [weak self] release in
            guard let self else { return }
            if release == .wheel { self.updateWheelSelection() }
            let action = release == .tap ? DesktopPointerAction.write : self.model.selectedAction
            self.hideWheel(restoreBubble: action == nil)
            if let action { self.choose(action) }
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.closeSelection(); self?.updateBubbleFrame() }
        }
    }

    func start() {
        restartShortcut()
        anchor = NSEvent.mouseLocation
        showBubble(expanded: false)
    }

    func restartShortcut() {
        model.shortcutError = nil
        shortcut.start(mode: model.shortcutMode, keyCode: UInt16(model.optionKeyCode),
                       rightCommandEnabled: model.rightCommandEnabled, magicPointerEnabled: model.magicPointerEnabled)
        model.saveShortcutPreferences()
    }

    func showBubble(expanded: Bool) {
        if bubble?.isVisible != true { model.responsePresentationID = UUID() }
        if expanded && (!model.expanded || bubble?.isVisible != true) {
            model.chatPresentationID = UUID()
        }
        model.expanded = expanded
        model.panelVisible = true
        if bubble == nil {
            let panel = makePanel(size: model.panelLayout.size)
            host(DesktopBubbleView(model: model, toggle: { [weak self] in self?.toggleBubble() },
                                   hide: { [weak self] in self?.hideBubble() },
                                   settings: { [weak self] in self?.openSettings?() },
                                   captureRegion: { [weak self] in self?.choose(.region) }), in: panel)
            bubble = panel
            bubbleMoveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
                                                                         object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.bubbleDidMove() }
            }
            model.capture.excludedWindowIDs.insert(CGWindowID(panel.windowNumber))
        }
        updateBubbleFrame()
        if expanded {
            bubble?.makeKeyAndOrderFront(nil)
        } else {
            bubble?.orderFrontRegardless()
        }
    }

    func toggleBubble() { showBubble(expanded: !model.expanded) }

    func toggleMagicPointer() {
        guard model.magicPointerEnabled else { return }
        if magicPointer.isActive { magicPointer.end(); return }
        guard !magicPointer.isBusy else { return }
        if magicPointer.hasPendingTurn { showBubble(expanded: true); return }
        hideWheel()
        closeSelection()
        hideBubble()
        magicPointer.toggle()
    }

    func hideBubble() {
        preparationTask?.cancel()
        preparationTask = nil
        model.cancelContextCapture()
        model.panelVisible = false
        bubble?.orderOut(nil)
        if model.isRecording { Task { await model.cancelRecording() } }
    }

    private func bubbleDidMove() {
        guard !isUpdatingBubbleFrame, let bubble else { return }
        anchor = DesktopPointerGeometry.anchor(for: bubble.frame, orbOffset: model.panelLayout.orbOffset)
    }

    private func updateBubbleFrame() {
        guard let bubble, !isUpdatingBubbleFrame else { return }
        isUpdatingBubbleFrame = true
        defer { isUpdatingBubbleFrame = false }
        let screen = screen(at: anchor)
        let layout = model.panelLayout
        bubble.setFrame(DesktopPointerGeometry.panelFrame(anchor: anchor, size: layout.size,
                                                          visibleFrame: screen.visibleFrame, orbOffset: layout.orbOffset), display: true)
    }

    func openActionRing() {
        invocationPoint = anchor == .zero ? NSEvent.mouseLocation : anchor
        invocationContext = nil
        if wheel != nil { hideWheel(restoreBubble: true); return }
        showWheel(interactive: true)
    }

    private func toggleActionRing() {
        if wheel != nil { hideWheel(restoreBubble: true) }
        else { showWheel(interactive: true) }
    }

    private func showWheel(interactive: Bool = false) {
        guard wheel == nil else { return }
        closeSelection()
        bubbleWasVisible = bubble?.isVisible == true
        bubble?.orderOut(nil)
        model.panelVisible = false
        if invocationContext == nil { invocationContext = model.capture.context(at: invocationPoint) }
        wheelOrigin = invocationPoint
        model.selectedAction = nil
        let panel = makePanel(size: CGSize(width: 300, height: 300))
        panel.ignoresMouseEvents = !interactive
        panel.acceptsMouseMovedEvents = interactive
        let visible = screen(at: wheelOrigin).visibleFrame
        panel.setFrame(CGRect(x: min(max(wheelOrigin.x - 150, visible.minX), visible.maxX - 300),
                              y: min(max(wheelOrigin.y - 150, visible.minY), visible.maxY - 300), width: 300, height: 300), display: false)
        host(DesktopWheelHost(model: model,
                              choose: { [weak self] action in self?.hideWheel(); self?.choose(action) },
                              cancel: { [weak self] in self?.hideWheel(restoreBubble: true) }), in: panel)
        wheel = panel
        model.capture.excludedWindowIDs.insert(CGWindowID(panel.windowNumber))
        if interactive { panel.makeKeyAndOrderFront(nil) }
        else { panel.orderFrontRegardless() }
        wheelMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.updateWheelSelection()
        }
        wheelLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.updateWheelSelection()
            return event
        }
    }

    private func updateWheelSelection() {
        guard let wheel else { return }
        let point = NSEvent.mouseLocation
        model.selectedAction = DesktopPointerAction.at(pointer: point,
                                                       wheelCenter: CGPoint(x: wheel.frame.midX, y: wheel.frame.midY),
                                                       invocationPoint: wheelOrigin)
    }

    private func hideWheel(restoreBubble: Bool = false) {
        let wasVisible = wheel != nil
        if let wheel { model.capture.excludedWindowIDs.remove(CGWindowID(wheel.windowNumber)); wheel.orderOut(nil) }
        wheel = nil
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        if let wheelLocalMonitor { NSEvent.removeMonitor(wheelLocalMonitor) }
        wheelMonitor = nil
        wheelLocalMonitor = nil
        if wasVisible, restoreBubble, bubbleWasVisible { model.panelVisible = true; bubble?.orderFrontRegardless() }
    }

    func choose(_ action: DesktopPointerAction) {
        if magicPointer.isActive || magicPointer.isBusy { magicPointer.cancel() }
        if action != .chat, let invocationContext { model.beginInvocation(context: invocationContext) }
        anchor = invocationPoint == .zero ? NSEvent.mouseLocation : invocationPoint
        if action == .region || action == .regionVoice {
            selectRegion(voice: action == .regionVoice)
        } else {
            showBubble(expanded: true)
            preparationTask?.cancel()
            preparationTask = Task { [weak self] in
                guard !Task.isCancelled else { return }
                await self?.model.prepare(action)
            }
        }
    }

    private func selectRegion(voice: Bool) {
        closeSelection()
        bubble?.orderOut(nil)
        let screen = screen(at: anchor)
        let panel = makePanel(size: screen.frame.size)
        panel.level = .screenSaver
        panel.setFrame(screen.frame, display: false)
        host(DesktopRegionSelectionView(screenFrame: screen.frame, onSelected: { [weak self] frame in
            guard let self else { return }
            self.closeSelection()
            let point = CGPoint(x: frame.midX, y: frame.midY)
            self.model.beginInvocation(context: self.model.capture.context(at: point))
            self.showBubble(expanded: true)
            self.preparationTask?.cancel()
            self.preparationTask = Task { [weak self] in
                guard !Task.isCancelled else { return }
                await self?.model.setRegion(frame, voice: voice)
            }
        }, onCancel: { [weak self] in self?.closeSelection(); self?.showBubble(expanded: true) }), in: panel)
        selection = panel
        model.capture.excludedWindowIDs.insert(CGWindowID(panel.windowNumber))
        panel.makeKeyAndOrderFront(nil)
    }

    private func closeSelection() {
        if let selection { model.capture.excludedWindowIDs.remove(CGWindowID(selection.windowNumber)); selection.orderOut(nil) }
        selection = nil
    }

    private func makePanel(size: CGSize) -> NSPanel {
        let panel = DesktopPointerPanel(contentRect: CGRect(origin: .zero, size: size),
                                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func host<Content: View>(_ view: Content, in panel: NSPanel) {
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        panel.contentView = hosting
    }

    private func screen(at point: CGPoint) -> NSScreen {
        NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    func shutdown() {
        magicPointer.cancel()
        magicOverlay.hide()
        preparationTask?.cancel()
        model.panelVisible = false
        shortcut.stop()
        hideWheel()
        closeSelection()
        bubble?.orderOut(nil)
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let bubbleMoveObserver { NotificationCenter.default.removeObserver(bubbleMoveObserver) }
        model.shutdown()
    }

    #if DEBUG
    func verifyMagicPointer() async -> [String: Bool] {
        let probe = DesktopPointerShortcut(mode: shortcut.mode, magicPointerEnabled: true)
        defer { probe.stop() }
        var invocations = 0
        probe.onMagicPointer = { invocations += 1 }
        let now = ProcessInfo.processInfo.systemUptime
        probe.handleModifiers(keyCode: 58, rawFlags: 0x80020, at: now)
        probe.handleModifiers(keyCode: 58, rawFlags: 0, at: now + 0.03)
        probe.handleModifiers(keyCode: 58, rawFlags: 0x80020, at: now + 0.12)
        probe.handleModifiers(keyCode: 58, rawFlags: 0, at: now + 0.15)
        magicOverlay.title = "Preview"
        magicOverlay.show()
        try? await Task.sleep(for: .milliseconds(200))
        magicOverlay.updateListening(false)
        var report = magicOverlay.verification
        report["leftOptionDoubleTapRouted"] = invocations == 1
        magicOverlay.hide()
        report["hiddenAfterExit"] = !magicOverlay.isVisible
        return report
    }

    func verifyInteractions() -> [String: Bool] {
        let originalPressed = shortcut.onPressed
        let originalReleased = shortcut.onReleased
        let originalRing = shortcut.onActionRing
        let originalMagicPointer = shortcut.onMagicPointer
        var magicPointerCalls = 0
        shortcut.onMagicPointer = { magicPointerCalls += 1 }
        shortcut.onPressed = nil // Exercise our UI without reading another application's context.
        shortcut.onReleased = { [weak self] release in
            if release == .tap { self?.showBubble(expanded: true) }
        }
        shortcut.onActionRing = { [weak self] in self?.openActionRing() }
        var report: [String: Bool] = [:]
        if shortcut.mode == .optionSpace {
            hideBubble()
            shortcut.handleModifiers(keyCode: 61, rawFlags: 0x80040)
            shortcut.handleModifiers(keyCode: 61, rawFlags: 0)
            report["modifierAloneDoesNotOpen"] = !model.panelVisible
            shortcut.handleOptionSpace(pressed: true)
            shortcut.handleOptionSpace(pressed: false)
            report["optionSpaceOpensRing"] = wheel?.isVisible == true && wheel?.ignoresMouseEvents == false
            hideWheel(restoreBubble: true)
        } else {
            let now = ProcessInfo.processInfo.systemUptime
            let key = shortcut.keyCode
            let flags: UInt64 = key == 58 ? 0x80020 : 0x80040
            shortcut.handleModifiers(keyCode: key, rawFlags: flags, at: now)
            shortcut.handleModifiers(keyCode: key, rawFlags: 0, at: now + 0.02)
            shortcut.handleModifiers(keyCode: key, rawFlags: flags, at: now + 0.1)
            shortcut.handleModifiers(keyCode: key, rawFlags: 0, at: now + 0.12)
            if shortcut.magicPointerEnabled && shortcut.keyCode == MagicPointerTapGesture.modifier.rawValue { report["doubleTapMagicPointerRouted"] = magicPointerCalls == 1 }
            else { report["doubleTapHidden"] = !model.panelVisible && bubble?.isVisible != true }
        }
        shortcut.onPressed = originalPressed
        shortcut.onReleased = originalReleased
        shortcut.onActionRing = originalRing
        shortcut.onMagicPointer = originalMagicPointer
        report["optionSpaceRegistered"] = shortcut.hotKeyRegistrationStatus == noErr
        showBubble(expanded: true)
        guard let bubble else { report["movedPositionPreserved"] = false; return report }
        let visible = screen(at: anchor).visibleFrame
        bubble.setFrameOrigin(CGPoint(x: visible.midX - bubble.frame.width / 2,
                                      y: visible.midY - bubble.frame.height / 2))
        let movedFrame = bubble.frame
        updateBubbleFrame()
        let movedPositionPreserved = bubble.frame == movedFrame
        let draft = model.draft
        let isWorking = model.isWorking
        model.isWorking = true
        model.openDesktop(preferSession: true, openURL: { _ in true })
        let desktopHandoffHidden = !model.panelVisible && !bubble.isVisible
        let workPreserved = model.isWorking && model.draft == draft
        model.isWorking = isWorking
        showBubble(expanded: true)
        report["movedPositionPreserved"] = movedPositionPreserved
        report["desktopHandoffHidden"] = desktopHandoffHidden
        report["handoffPreservesWork"] = workPreserved
        return report
    }

    func showWheelPreview() {
        invocationPoint = NSEvent.mouseLocation
        showWheel()
    }

    func savePreview(to url: URL) throws {
        guard let view = (wheel ?? bubble)?.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw DesktopCaptureError.encodeFailed }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        // AppKit's cacheDisplay omits the CAMetalLayer's GPU contents.
        // Composite an own-orb render from the same native pipeline into the preview.
        if let context = NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext {
            // Keep cached controls above the Metal surface in wheel previews.
            context.setBlendMode(.destinationOver)
            let scaleX = CGFloat(bitmap.pixelsWide) / view.bounds.width
            // NSGraphicsContext already maps panel points to Retina bitmap pixels.
            for orb in metalOrbs(in: view) {
                guard let renderer = orb.renderer else { continue }
                var rect = orb.convert(orb.bounds, to: view)
                if view.isFlipped { rect.origin.y = view.bounds.height - rect.maxY }
                let image = try renderer.previewImage(size: max(1, Int(rect.width * scaleX)))
                context.draw(image, in: rect)
            }
        }
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw DesktopCaptureError.encodeFailed }
        try png.write(to: url, options: .atomic)
        let renderers = metalOrbs(in: view).compactMap { orb -> [String: Any]? in
            guard let renderer = orb.renderer else { return nil }
            return ["device": renderer.device.name, "framesRendered": renderer.renderedFrames,
                    "isPaused": orb.isPaused, "reduceMotion": renderer.reduceMotion]
        }
        let report = try JSONSerialization.data(withJSONObject: ["renderer": "Metal", "orbs": renderers], options: [.prettyPrinted, .sortedKeys])
        try report.write(to: url.deletingPathExtension().appendingPathExtension("json"), options: .atomic)
    }

    private func metalOrbs(in view: NSView) -> [DesktopOrbMetalView] {
        if let orb = view as? DesktopOrbMetalView { return [orb] }
        return view.subviews.flatMap { metalOrbs(in: $0) }
    }
    #endif
}

private struct DesktopWheelHost: View {
    @Bindable var model: DesktopCompanionModel
    var choose: (DesktopPointerAction) -> Void
    var cancel: () -> Void
    var body: some View { DesktopActionWheelView(selected: model.selectedAction, choose: choose, cancel: cancel) }
}
