import Foundation
import AppKit
import MetalKit

private final class MagicPointerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class PointerTrailMetalView: MTKView {
    override var isOpaque: Bool { false }
}

@MainActor
final class MagicPointerCapsuleView: NSView {
    var title = "Listening" { didSet { needsDisplay = true } }
    var symbol = "mic" { didSet { needsDisplay = true } }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 22, yRadius: 22)
        NSColor(calibratedRed: 0.067, green: 0.078, blue: 0.094, alpha: 0.97).setFill(); path.fill()
        let blue = NSColor(calibratedRed: 0.48, green: 0.73, blue: 1, alpha: 1)
        blue.setStroke(); path.lineWidth = 1.5; path.stroke()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: blue]
        let text = title as NSString
        let size = text.size(withAttributes: attributes)
        let iconRect = CGRect(x: 13, y: (bounds.height - 19) / 2, width: 19, height: 19)
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            image.withSymbolConfiguration(.init(paletteColors: [blue]))?.draw(in: iconRect)
        }
        text.draw(at: CGPoint(x: 41, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}

@MainActor
final class MagicPointerOverlay {
    private struct Surface {
        var panel: NSPanel
        var view: MTKView
        var renderer: PointerTrailRenderer
    }
    private let capture: DesktopContextCapture
    private var surfaces: [String: Surface] = [:]
    private var capsule: NSPanel?
    private let capsuleView = MagicPointerCapsuleView(frame: CGRect(x: 0, y: 0, width: 240, height: 44))
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var motionObserver: NSObjectProtocol?
    private var history = PointerTrailHistory()
    private(set) var isVisible = false
    var isListening = false
    var onSample: ((CGPoint, String, CGRect, UInt64, TimeInterval) -> Void)?
    var onError: ((String) -> Void)?
    var onDisplaysChanged: (() -> Void)?
    var title = "Connecting…" { didSet { updateCapsule() } }
    var symbol = "mic" { didSet { updateCapsule() } }

    init(capture: DesktopContextCapture) { self.capture = capture }

    func show() {
        guard !isVisible else { return }
        isVisible = true
        history.clear()
        do { try rebuildSurfaces() } catch { hide(); onError?(error.localizedDescription); return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                          .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.samplePointer(); return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in self?.samplePointer() }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.history.breakSegment()
                self.onDisplaysChanged?()
                do { try self.rebuildSurfaces(); self.samplePointer() }
                catch { self.hide(); self.onError?(error.localizedDescription) }
            }
        }
        motionObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.samplePointer() }
        }
        samplePointer()
    }

    func hide() {
        isVisible = false
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil; globalMonitor = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let motionObserver { NSWorkspace.shared.notificationCenter.removeObserver(motionObserver) }
        screenObserver = nil; motionObserver = nil
        removeSurfaces()
        if let capsule { capture.excludedWindowIDs.remove(CGWindowID(capsule.windowNumber)); capsule.orderOut(nil) }
        capsule = nil
        history.clear()
    }

    func updateListening(_ value: Bool) {
        isListening = value
        if !value { history.clear() }
        if isVisible { samplePointer() }
    }

    private func rebuildSurfaces() throws {
        removeSurfaces()
        for screen in NSScreen.screens {
            let id = Self.displayID(screen)
            let renderer = try PointerTrailRenderer(screenFrame: screen.frame, displayID: id)
            let view = PointerTrailMetalView(frame: CGRect(origin: .zero, size: screen.frame.size), device: renderer.device)
            view.colorPixelFormat = .bgra8Unorm
            view.clearColor = MTLClearColorMake(0, 0, 0, 0)
            view.wantsLayer = true
            view.layer?.isOpaque = false
            view.layer?.backgroundColor = NSColor.clear.cgColor
            view.preferredFramesPerSecond = min(120, max(60, screen.maximumFramesPerSecond))
            view.delegate = renderer
            let panel = makePanel(frame: screen.frame)
            panel.contentView = view
            surfaces[id] = Surface(panel: panel, view: view, renderer: renderer)
            capture.excludedWindowIDs.insert(CGWindowID(panel.windowNumber))
            panel.orderFrontRegardless()
        }
        if capsule == nil {
            let panel = makePanel(frame: capsuleView.frame)
            panel.contentView = capsuleView
            capsule = panel
            capture.excludedWindowIDs.insert(CGWindowID(panel.windowNumber))
        }
        updateCapsule()
    }

    private func removeSurfaces() {
        for surface in surfaces.values {
            surface.view.isPaused = true
            surface.view.delegate = nil
            capture.excludedWindowIDs.remove(CGWindowID(surface.panel.windowNumber))
            surface.panel.orderOut(nil)
        }
        surfaces = [:]
    }

    private func samplePointer() {
        guard isVisible, let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) else { return }
        let point = NSEvent.mouseLocation, now = ProcessInfo.processInfo.systemUptime, id = Self.displayID(screen)
        if isListening {
            history.append(point: point, displayID: id, at: now)
            onSample?(point, id, screen.frame, UInt64(NSEvent.pressedMouseButtons), now)
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for (surfaceID, surface) in surfaces {
            surface.renderer.points = history.points
            surface.renderer.pointer = surfaceID == id ? point : nil
            surface.renderer.showsTrail = isListening
            surface.renderer.reduceMotion = reduceMotion
            surface.view.isPaused = reduceMotion || !isListening
            surface.view.draw()
        }
        positionCapsule(at: point, screen: screen)
    }

    private func updateCapsule() {
        capsuleView.title = title
        capsuleView.symbol = symbol
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .medium)]
        let width = min(320, max(150, (title as NSString).size(withAttributes: attributes).width + 58))
        capsule?.setContentSize(CGSize(width: width, height: 44))
        if isVisible, let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
            positionCapsule(at: NSEvent.mouseLocation, screen: screen)
        }
    }

    private func positionCapsule(at point: CGPoint, screen: NSScreen) {
        guard let capsule else { return }
        let size = capsule.frame.size, visible = screen.visibleFrame
        let x = min(max(point.x + 24, visible.minX + 8), max(visible.minX + 8, visible.maxX - size.width - 8))
        let y = point.y - size.height - 22 >= visible.minY + 8 ? point.y - size.height - 22 : min(visible.maxY - size.height - 8, point.y + 24)
        capsule.setFrameOrigin(CGPoint(x: x, y: y))
        capsule.orderFrontRegardless()
    }

    private func makePanel(frame: CGRect) -> NSPanel {
        let panel = MagicPointerPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.setAccessibilityElement(false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        return panel
    }

    static func displayID(_ screen: NSScreen) -> String {
        String((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID())
    }

    #if DEBUG
    var verification: [String: Bool] {
        ["visible": isVisible,
         "clickThrough": surfaces.values.allSatisfy { $0.panel.ignoresMouseEvents },
         "nonActivating": surfaces.values.allSatisfy { !$0.panel.canBecomeKey && !$0.panel.canBecomeMain },
         "excludedFromCapture": surfaces.values.allSatisfy { capture.excludedWindowIDs.contains(CGWindowID($0.panel.windowNumber)) },
         "metalRendered": surfaces.values.contains { $0.renderer.renderedFrames > 0 }]
    }
    #endif
}
