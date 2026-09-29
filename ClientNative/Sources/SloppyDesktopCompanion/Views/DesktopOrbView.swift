import SwiftUI
import MetalKit
import OSLog

struct DesktopOrbView: View {
    enum Activity { case idle, listening, working, attention }
    var activity: Activity
    var audioLevel: Double = 0
    var isVisible = true
    var diameter: CGFloat = 68
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rendererAvailable = true

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if rendererAvailable {
                DesktopOrbMetalSurface(activity: activity, audioLevel: audioLevel,
                                       isVisible: isVisible, reduceMotion: reduceMotion,
                                       onFailure: { rendererAvailable = false })
                    .allowsHitTesting(false)
            } else {
                Circle().fill(.blue.gradient).padding(12).blur(radius: 5)
                    .overlay(Image(systemName: "sparkles").foregroundStyle(.white))
            }
            if activity == .attention {
                Circle().fill(.orange).frame(width: 8, height: 8).padding(9)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityLabel("Sloppy Pointer")
    }
}

private struct DesktopOrbMetalSurface: NSViewRepresentable {
    var activity: DesktopOrbView.Activity
    var audioLevel: Double
    var isVisible: Bool
    var reduceMotion: Bool
    var onFailure: () -> Void

    func makeNSView(context: Context) -> DesktopOrbMetalView {
        let view = DesktopOrbMetalView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.layer?.isOpaque = false
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.framebufferOnly = true
        do {
            let renderer = try DesktopOrbRenderer(device: view.device)
            view.renderer = renderer
            view.delegate = renderer
        } catch {
            Logger(subsystem: "team.sloppy.desktop-companion", category: "orb")
                .error("Metal orb unavailable: \(error.localizedDescription, privacy: .public)")
            Task { @MainActor in onFailure() }
        }
        return view
    }

    func updateNSView(_ view: DesktopOrbMetalView, context: Context) {
        view.renderer?.audioLevel = activity == .listening ? audioLevel : 0
        view.renderer?.speed = activity == .working ? 3 : 2
        view.renderer?.reduceMotion = reduceMotion
        view.preferredFramesPerSecond = activity == .idle ? 24 : 30
        view.shouldAnimate = isVisible && !reduceMotion
        view.updateAnimation()
    }

    static func dismantleNSView(_ view: DesktopOrbMetalView, coordinator: ()) {
        view.isPaused = true
        view.delegate = nil
        view.renderer = nil
    }
}

final class DesktopOrbMetalView: MTKView {
    var renderer: DesktopOrbRenderer?
    var shouldAnimate = true

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(updateAnimation),
                                                   name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
        updateAnimation()
    }

    @objc func updateAnimation() {
        let paused = !shouldAnimate || window == nil || window?.isVisible != true
        if isPaused != paused {
            renderer?.resetFrameClock()
            isPaused = paused
        }
        if paused, window?.isVisible == true { draw() }
    }
}
