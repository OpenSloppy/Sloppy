import Foundation
import AppKit
import SloppyClientCore

struct MagicPointerTarget: Sendable, Equatable {
    var deviceID: String
    var agentID: String
    var sessionID: String
}

struct MagicPointerTurnPayload: Sendable {
    var context: PointerTurnContext
    var attachments: [ChatAttachmentUpload]
    var desktopContext: DesktopPointerContext?
}

@MainActor
final class PointerTurnContextBuilder {
    private struct Capture {
        var image: DesktopImageCapture
        var context: DesktopPointerContext
        var startMs: Int
        var endMs: Int
        var geometryRevision: Int
    }
    private(set) var context: PointerTurnContext
    private var captures: [Capture] = []
    private var lastSampleTime: TimeInterval?
    private var segmentID = 0
    private let conversationStart: TimeInterval
    private var primaryTop: CGFloat
    private(set) var geometryRevision = 0
    private(set) var lastDesktopContext: DesktopPointerContext?

    init(target: MagicPointerTarget, conversationID: String, conversationStart: TimeInterval,
         captureStart: TimeInterval, primaryTop: CGFloat) {
        self.conversationStart = conversationStart; self.primaryTop = primaryTop
        context = .init(conversationID: conversationID, deviceID: target.deviceID, agentID: target.agentID,
                        sessionID: target.sessionID, captureStartMs: max(0, Int((captureStart - conversationStart) * 1_000)))
        context.geometries = [.init(revision: 0, primaryScreenTop: primaryTop)]
    }

    func timeMs(_ time: TimeInterval) -> Int { max(0, Int((time - conversationStart) * 1_000)) }

    func recordingStarted(at time: TimeInterval) {
        context.utterance.captureStartMs = timeMs(time)
        context.utterance.startMs = context.utterance.captureStartMs
    }

    func sample(point: CGPoint, displayID: String, displayBounds: CGRect, buttons: UInt64, at time: TimeInterval) {
        guard point.x.isFinite, point.y.isFinite, time.isFinite else { return }
        if let lastSampleTime, time - lastSampleTime < 1.0 / 60 { return }
        let quartz = CGPoint(x: point.x, y: primaryTop - point.y)
        if let previous = context.samples.last {
            if previous.displayID != displayID || hypot(quartz.x - previous.x, quartz.y - previous.y) > 700 { segmentID += 1 }
        }
        if !context.displays.contains(where: { $0.id == displayID && $0.geometryRevision == geometryRevision }) {
            context.displays.append(.init(id: displayID, bounds: DesktopPointerGeometry.quartzRect(displayBounds, primaryScreenTop: primaryTop), geometryRevision: geometryRevision))
        }
        context.samples.append(.init(tMs: timeMs(time), point: quartz, displayID: displayID, segmentID: segmentID, buttons: buttons, geometryRevision: geometryRevision))
        context.boundSamples(to: 3_600)
        lastSampleTime = time
    }

    func geometryChanged(primaryTop: CGFloat) {
        self.primaryTop = primaryTop; geometryRevision += 1; segmentID += 1; lastSampleTime = nil
        context.geometries.append(.init(revision: geometryRevision, primaryScreenTop: primaryTop))
    }

    func omittedCapture() { context.coverage.omittedFrames += 1 }

    func addCapture(_ image: DesktopImageCapture, context desktop: DesktopPointerContext,
                    startedAt: TimeInterval, finishedAt: TimeInterval) {
        lastDesktopContext = desktop
        let next = Capture(image: image, context: desktop, startMs: timeMs(startedAt), endMs: timeMs(finishedAt), geometryRevision: geometryRevision)
        // Preserve the beginning and distinct targets. Refresh an existing target's latest frame.
        if let index = captures.indices.dropFirst().last(where: { index in
            let old = captures[index]
            return old.geometryRevision == geometryRevision && old.image.displayId == image.displayId && old.context.applicationPID == desktop.applicationPID
                && old.context.elementFrame == desktop.elementFrame && old.context.elementTitle == desktop.elementTitle
        }) {
            captures[index] = next
            self.context.coverage.omittedFrames += 1
        } else {
            if captures.count == 4 { captures.remove(at: 1); self.context.coverage.omittedFrames += 1 }
            captures.append(next)
        }
    }

    func makePayload(text: String, speechStart: TimeInterval?, endedAt: TimeInterval, truncated: Bool = false) throws -> MagicPointerTurnPayload {
        context.utterance.text = text
        context.utterance.startMs = speechStart.map(timeMs) ?? context.utterance.captureStartMs
        context.utterance.endMs = timeMs(endedAt)
        context.coverage.truncated = context.coverage.truncated || truncated
        context.frames = []; context.elements = []
        var attachments: [ChatAttachmentUpload] = []
        for (index, capture) in captures.enumerated() {
            let id = "frame-\(index + 1)"
            let prefix = "magic-pointer-\(context.turnID)-\(id)"
            let clean = try Self.boundedPNG(capture.image.png, maximumBytes: 900 * 1_024)
            let frame = PointerTurnContext.Frame(id: id, captureStartMs: capture.startMs, captureEndMs: capture.endMs,
                                                attachmentName: prefix + ".png", annotatedAttachmentName: prefix + "-annotated.png",
                                                displayID: capture.image.displayId, screenRect: capture.image.frame,
                                                pixelWidth: clean.width, pixelHeight: clean.height, geometryRevision: capture.geometryRevision)
            context.frames.append(frame)
            context.elements.append(.init(frameID: id, tMs: frame.tMs, application: capture.context.application,
                                          role: capture.context.elementRole, title: capture.context.elementTitle,
                                          selectedText: capture.context.selectedText, bounds: capture.context.elementFrame))
            let annotated = try Self.annotate(clean.data, frame: frame, samples: context.samples, number: index + 1)
            attachments.append(Self.upload(name: frame.attachmentName, data: clean.data))
            attachments.append(Self.upload(name: frame.annotatedAttachmentName, data: annotated))
        }
        let data = try context.encoded()
        attachments.append(.init(name: "magic-pointer-\(context.turnID)-trajectory.json", mimeType: "application/json",
                                 sizeBytes: data.count, contentBase64: data.base64EncodedString()))
        guard attachments.reduce(0, { $0 + $1.sizeBytes }) <= 8 * 1_024 * 1_024 else { throw DesktopCaptureError.encodeFailed }
        return .init(context: context, attachments: attachments, desktopContext: lastDesktopContext)
    }

    private static func upload(name: String, data: Data) -> ChatAttachmentUpload {
        .init(name: name, mimeType: "image/png", sizeBytes: data.count, contentBase64: data.base64EncodedString())
    }

    static func boundedPNG(_ data: Data, maximumBytes: Int) throws -> (data: Data, width: Int, height: Int) {
        guard let original = NSBitmapImageRep(data: data)?.cgImage else { throw DesktopCaptureError.encodeFailed }
        var width = min(1_600, original.width)
        var height = max(1, original.height * width / original.width)
        while width >= min(240, original.width) {
            guard let cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw DesktopCaptureError.encodeFailed }
            cg.interpolationQuality = .high
            cg.draw(original, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let image = cg.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw DesktopCaptureError.encodeFailed }
            if png.count <= maximumBytes { return (png, width, height) }
            width = Int(Double(width) * 0.8); height = max(1, original.height * width / original.width)
        }
        throw DesktopCaptureError.encodeFailed
    }

    private static func annotate(_ data: Data, frame: PointerTurnContext.Frame,
                                 samples: [PointerTurnContext.Sample], number: Int) throws -> Data {
        guard let image = NSBitmapImageRep(data: data)?.cgImage,
              let cg = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                 bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw DesktopCaptureError.encodeFailed }
        cg.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        // Only the path around this frame's capture interval belongs on this visual state.
        let near = samples.filter { $0.tMs >= frame.annotationStartMs && $0.tMs <= frame.annotationEndMs }
        cg.setStrokeColor(NSColor.systemBlue.cgColor); cg.setLineWidth(4); cg.setLineCap(.round); cg.setLineJoin(.round)
        var previous: PointerTurnContext.Sample?
        var lastPoint: CGPoint?
        for sample in near {
            guard let pixel = frame.pixelPoint(for: sample) else { previous = nil; continue }
            let point = CGPoint(x: pixel.x, y: Double(image.height) - pixel.y)
            if let previous, previous.segmentID == sample.segmentID, let old = frame.pixelPoint(for: previous) {
                cg.move(to: CGPoint(x: old.x, y: Double(image.height) - old.y)); cg.addLine(to: point); cg.strokePath()
            }
            previous = sample; lastPoint = point
        }
        if let lastPoint {
            cg.setFillColor(NSColor.systemBlue.cgColor)
            cg.fillEllipse(in: CGRect(x: lastPoint.x - 6, y: lastPoint.y - 6, width: 12, height: 12))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
            let label = "\(number) · \(String(format: "%.2f", Double(frame.tMs) / 1_000)) s" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: NSColor.white]
            let size = label.size(withAttributes: attributes)
            let origin = CGPoint(x: min(max(6, lastPoint.x + 12), max(6, CGFloat(image.width) - size.width - 16)),
                                 y: min(max(6, lastPoint.y + 12), max(6, CGFloat(image.height) - size.height - 16)))
            cg.setFillColor(NSColor(calibratedWhite: 0.08, alpha: 0.95).cgColor)
            cg.fill(CGRect(origin: CGPoint(x: origin.x - 4, y: origin.y - 3), size: CGSize(width: size.width + 8, height: size.height + 6)))
            label.draw(at: origin, withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
        }
        guard let annotated = cg.makeImage(), let png = NSBitmapImageRep(cgImage: annotated).representation(using: .png, properties: [:]),
              png.count <= 1_024 * 1_024 else { throw DesktopCaptureError.encodeFailed }
        return png
    }
}
