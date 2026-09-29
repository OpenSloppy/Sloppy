import Foundation
import AppKit
import Carbon

@MainActor
final class DesktopPointerShortcut {
    var onPressed: (() -> Void)?
    var onWheel: (() -> Void)?
    var onActionRing: (() -> Void)?
    var onReleased: ((DesktopPointerShortcutState.Release) -> Void)?
    var onCancelled: (() -> Void)?
    var onDoubleTap: (() -> Void)?
    var onMagicPointer: (() -> Void)?
    var onEscape: (() -> Void)?
    var onError: ((String) -> Void)?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var holdTask: Task<Void, Never>?
    private var state = DesktopPointerShortcutState()
    private var taps = DesktopPointerTapSequence()
    private var magicTaps = MagicPointerTapGesture()
    private(set) var magicPointerEnabled: Bool
    private(set) var keyCode: UInt16 = 61
    private var activeKeyCode: UInt16?
    private var enabledKeys: Set<UInt16> = [61, 54]
    private(set) var mode: DesktopPointerShortcutMode
    private var hotKey: DesktopPointerHotKey?
    private var optionSpacePressed = false
    private(set) var hotKeyRegistrationStatus: OSStatus = noErr

    init(mode: DesktopPointerShortcutMode = .optionSpace, magicPointerEnabled: Bool = false) {
        self.mode = mode
        self.magicPointerEnabled = magicPointerEnabled
    }

    func start(mode: DesktopPointerShortcutMode = .optionSpace, keyCode: UInt16 = 61,
               rightCommandEnabled: Bool = true, magicPointerEnabled: Bool = false) {
        stop()
        self.mode = mode
        self.keyCode = keyCode
        self.magicPointerEnabled = magicPointerEnabled
        let registration = DesktopPointerHotKey { [weak self] pressed in self?.handleOptionSpace(pressed: pressed) }
        hotKeyRegistrationStatus = registration.start()
        if hotKeyRegistrationStatus == noErr { hotKey = registration }
        else { onError?("Could not register Option + Space (macOS error \(hotKeyRegistrationStatus)).") }
        if mode == .optionSpace && !magicPointerEnabled { return }
        enabledKeys = rightCommandEnabled ? [keyCode, 54] : [keyCode]
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
        }
    }

    func stop() {
        magicTaps.cancel()
        hotKey = nil
        optionSpacePressed = false
        holdTask?.cancel()
        state.cancel()
        taps.cancel()
        activeKeyCode = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }

    private func handle(_ event: NSEvent) {
        if event.type == .flagsChanged {
            let rawFlags = event.cgEvent?.flags.rawValue ?? UInt64(event.modifierFlags.rawValue)
            handleModifiers(keyCode: event.keyCode, rawFlags: rawFlags)
        } else {
            if event.type == .keyDown, event.keyCode == 53 { onEscape?() }
            cancelForOtherInput()
        }
    }

    func handleModifiers(keyCode: UInt16, rawFlags: UInt64, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if magicPointerEnabled {
            if keyCode == DesktopPointerModifier.rightOption.rawValue, activeKeyCode != nil {
                cancelForOtherInput()
            }
            if magicTaps.handle(keyCode: keyCode, rawFlags: rawFlags, at: time) { onMagicPointer?() }
            if keyCode == DesktopPointerModifier.rightOption.rawValue { return }
        }
        guard mode == .modifier else { return }
        if let activeKeyCode {
            guard keyCode == activeKeyCode,
                  let modifier = DesktopPointerModifier(rawValue: activeKeyCode) else {
                cancelForOtherInput()
                return
            }
            if rawFlags & modifier.deviceMask == 0 {
                holdTask?.cancel()
                self.activeKeyCode = nil
                if let release = state.release() {
                    if release == .tap, taps.registerTap(keyCode: keyCode, at: time) { onDoubleTap?() }
                    else {
                        if release == .wheel { taps.cancel() }
                        onReleased?(release)
                    }
                }
            } else if !modifier.isStandalone(rawFlags: rawFlags) {
                cancelForOtherInput()
            }
            return
        }
        guard enabledKeys.contains(keyCode), let modifier = DesktopPointerModifier(rawValue: keyCode),
              modifier.isStandalone(rawFlags: rawFlags) else { taps.cancel(); return }
        activeKeyCode = keyCode
        state.press(at: time)
        onPressed?()
        holdTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, self.state.presentWheel(at: ProcessInfo.processInfo.systemUptime) else { return }
            self.taps.cancel()
            self.onWheel?()
        }
    }

    func handleOptionSpace(pressed: Bool) {
        if pressed {
            guard !optionSpacePressed else { return }
            optionSpacePressed = true
            cancelForOtherInput(notify: false)
            onPressed?()
            onActionRing?()
        } else {
            optionSpacePressed = false
        }
    }

    func cancelForOtherInput(notify: Bool = true) {
        magicTaps.cancel()
        taps.cancel()
        guard activeKeyCode != nil else { return }
        holdTask?.cancel()
        activeKeyCode = nil
        state.cancel()
        if notify { onCancelled?() }
    }
}

/// Carbon registers and consumes the global chord; an NSEvent global monitor cannot consume it.
private final class DesktopPointerHotKey {
    private static let signature: OSType = 0x534C5054 // SLPT
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let onEvent: @MainActor (Bool) -> Void

    init(onEvent: @escaping @MainActor (Bool) -> Void) { self.onEvent = onEvent }

    @MainActor
    func start() -> OSStatus {
        var events = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == DesktopPointerHotKey.signature, id.id == 1 else { return OSStatus(eventNotHandledErr) }
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            // Application event handlers run on the main event loop.
            return MainActor.assumeIsolated {
                Unmanaged<DesktopPointerHotKey>.fromOpaque(context).takeUnretainedValue().onEvent(pressed)
                return noErr
            }
        }, events.count, &events, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { return status }
        return RegisterEventHotKey(49, UInt32(optionKey), EventHotKeyID(signature: Self.signature, id: 1),
                                   GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotKey)
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
