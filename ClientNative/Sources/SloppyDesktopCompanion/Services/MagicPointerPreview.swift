#if DEBUG
import Foundation
import AppKit
import MetalKit

@MainActor
final class MagicPointerPreview {
    private let window: NSWindow
    private let backdrop: PointerPreviewBackdrop
    private let view: MTKView
    private let renderer: PointerTrailRenderer
    private let capsule = MagicPointerCapsuleView(frame: CGRect(x: 0, y: 0, width: 242, height: 44))
    private var timer: Timer?
    private var start = ProcessInfo.processInfo.systemUptime

    init() throws {
        let size = CGSize(width: 820, height: 450)
        renderer = try PointerTrailRenderer(screenFrame: CGRect(origin: .zero, size: size), displayID: "preview")
        backdrop = PointerPreviewBackdrop(frame: CGRect(origin: .zero, size: size))
        view = MTKView(frame: backdrop.bounds, device: renderer.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.wantsLayer = true; view.layer?.isOpaque = false
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.preferredFramesPerSecond = 60
        view.delegate = renderer
        window = NSWindow(contentRect: backdrop.bounds, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Magic Pointer · предпросмотр"
        window.isReleasedWhenClosed = false
        window.contentView = backdrop
        backdrop.addSubview(view)
        capsule.title = "Объедини вот эти два"
        backdrop.addSubview(capsule)
        window.center()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        drawReference()
        timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.drawReference() } }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func drawReference() {
        let now = ProcessInfo.processInfo.systemUptime, width = backdrop.bounds.width, height = backdrop.bounds.height
        // A stable reference pose with a real age gradient, rendered by the production GPU pipeline.
        renderer.points = (0...90).map { index in
            let u = Double(index) / 90
            return .init(point: CGPoint(x: width * (0.16 + 0.58 * u), y: height * (0.34 + 0.19 * sin(u * .pi * 2) + 0.10 * u)),
                         time: now - (1 - u) * 0.8, displayID: "preview", segmentID: 0)
        }
        renderer.pointer = renderer.points.last?.point
        view.isPaused = false
        if let point = renderer.pointer {
            capsule.setFrameOrigin(CGPoint(x: min(point.x + 20, width - capsule.frame.width - 14), y: point.y - 67))
        }
    }

    func save(to url: URL, overlayReport: [String: Bool]) throws {
        guard let bitmap = backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds),
              let cg = NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext else { throw DesktopCaptureError.encodeFailed }
        backdrop.cacheDisplay(in: backdrop.bounds, to: bitmap)
        let image = try renderer.previewImage(at: ProcessInfo.processInfo.systemUptime, scale: CGFloat(bitmap.pixelsWide) / backdrop.bounds.width)
        cg.draw(image, in: backdrop.bounds)
        // Preserve the capsule above Metal in the own-window snapshot.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
        cg.saveGState(); cg.translateBy(x: capsule.frame.minX, y: capsule.frame.minY)
        capsule.draw(capsule.bounds)
        cg.restoreGState(); NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw DesktopCaptureError.encodeFailed }
        try png.write(to: url, options: .atomic)
        let report: [String: Any] = ["renderer": "Metal", "device": renderer.device.name, "framesRendered": renderer.renderedFrames,
                                     "windowVisible": window.isVisible, "microphoneCaptured": false, "screenCaptured": false,
                                     "elapsed": ProcessInfo.processInfo.systemUptime - start, "overlay": overlayReport]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: url.deletingPathExtension().appendingPathExtension("json"), options: .atomic)
    }

    func stop() { timer?.invalidate(); timer = nil; view.isPaused = true; window.close() }
}

private final class PointerPreviewBackdrop: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.067, green: 0.078, blue: 0.094, alpha: 1).setFill(); bounds.fill()
        NSColor(calibratedWhite: 0.23, alpha: 1).setFill()
        for x in stride(from: 18.0, to: bounds.width, by: 28) {
            for y in stride(from: 18.0, to: bounds.height, by: 28) { NSBezierPath(ovalIn: CGRect(x: x, y: y, width: 2, height: 2)).fill() }
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(calibratedWhite: 0.65, alpha: 1)]
        ("Magic Pointer · нативный Metal" as NSString).draw(at: CGPoint(x: 22, y: bounds.height - 35), withAttributes: attributes)
        ("Предпросмотр. Микрофон и захват экрана выключены." as NSString).draw(at: CGPoint(x: 22, y: 19), withAttributes: attributes)
    }
}
#endif
