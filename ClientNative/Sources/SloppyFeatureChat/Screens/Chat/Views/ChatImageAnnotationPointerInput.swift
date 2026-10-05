#if os(macOS)
import AppKit
import SwiftUI

/// SwiftUI owns the annotations; this view only tracks a pointer in canvas coordinates.
struct ChatImageAnnotationPointerInput: NSViewRepresentable {
    let changed: @MainActor (CGPoint, CGPoint) -> Void
    let ended: @MainActor (CGPoint, CGPoint) -> Void

    func makeNSView(context: Context) -> AnnotationPointerView {
        let view = AnnotationPointerView()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
        view.setAccessibilityLabel("Screenshot annotation canvas")
        view.setAccessibilityIdentifier("chat.image.annotations.canvas")
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: AnnotationPointerView, context: Context) {
        view.changed = changed
        view.ended = ended
    }

    final class AnnotationPointerView: NSView {
        var changed: (@MainActor (CGPoint, CGPoint) -> Void)?
        var ended: (@MainActor (CGPoint, CGPoint) -> Void)?
        private var start: CGPoint?

        override var isFlipped: Bool { true }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            start = point
            changed?(point, point)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            changed?(start, convert(event.locationInWindow, from: nil))
        }

        override func mouseUp(with event: NSEvent) {
            guard let start else { return }
            self.start = nil
            ended?(start, convert(event.locationInWindow, from: nil))
        }
    }
}
#endif
