import SwiftUI
import SloppyClientCore
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public struct AgentBotAvatar: View {
    public let agentID: String
    public var paletteID: String?
    public var emotion: AgentBotEmotion
    public var size: CGFloat
    public var isAnimated: Bool
    public var isHovered: Bool

    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var animationStart = Date()
    @State private var hoverStart = Date()

    public init(agentID: String, size: CGFloat = 46, paletteID: String? = nil,
                emotion: AgentBotEmotion = .idle, isAnimated: Bool = false, isHovered: Bool = false) {
        self.agentID = agentID
        self.size = size
        self.paletteID = paletteID
        self.emotion = emotion
        self.isAnimated = isAnimated
        self.isHovered = isHovered
    }

    public var body: some View {
        Group {
            // The notch lives in a separate NSPanel; its hosting view can have
            // an inactive scene phase even while the pointer is over it.
            if !reducedMotion && (isHovered || (isAnimated && scenePhase == .active)) {
                TimelineView(.animation(minimumInterval: 1.0 / 24)) { context in
                    character(elapsed: context.date.timeIntervalSince(animationStart),
                              hoverElapsed: context.date.timeIntervalSince(hoverStart))
                }
            } else {
                character(elapsed: 0, hoverElapsed: 0)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .onChange(of: isHovered) { _, hovered in
            if hovered { hoverStart = Date() }
        }
    }

    private func character(elapsed: Double, hoverElapsed: Double) -> some View {
        let reaction = AgentBotHoverReaction.resolve(
            baseEmotion: emotion, isHovered: isHovered, elapsed: hoverElapsed, reducedMotion: reducedMotion
        )
        let pose = AgentBotMotionPose.resolve(emotion: emotion, elapsed: elapsed, reducedMotion: reducedMotion)
        return artwork
            .overlay {
                AgentBotEyes(agentID: agentID, paletteID: paletteID, emotion: reaction.emotion,
                             elapsed: elapsed, reducedMotion: reducedMotion)
            }
            .frame(width: size, height: size)
            .scaleEffect(x: pose.scaleX * reaction.motion.scaleX, y: pose.scaleY * reaction.motion.scaleY)
            .rotationEffect(.degrees(pose.rotation + reaction.motion.rotation))
            .offset(y: (pose.offsetY + reaction.motion.offsetY) * size)
    }

    @ViewBuilder private var artwork: some View {
        #if os(macOS)
        if let image = Self.coloredImage(for: agentID, paletteID: paletteID) {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
        }
        #elseif canImport(UIKit)
        if let image = Self.coloredImage(for: agentID, paletteID: paletteID) {
            Image(uiImage: image).resizable().interpolation(.high).scaledToFit()
        }
        #endif
    }

    private static func tint(_ source: CGImage, palette: AgentBotPalette) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: 512, height: 512)
        context.interpolationQuality = .high
        context.draw(source, in: bounds)
        context.setBlendMode(.multiply)
        context.setFillColor(CGColor(red: CGFloat((palette.body >> 16) & 255) / 255,
                                     green: CGFloat((palette.body >> 8) & 255) / 255,
                                     blue: CGFloat(palette.body & 255) / 255, alpha: 1))
        context.fill(bounds)
        context.setBlendMode(.destinationIn)
        context.draw(source, in: bounds)
        return context.makeImage()
    }

    #if os(macOS)
    @MainActor private static let images: [String: NSImage] = Dictionary(uniqueKeysWithValues:
        AgentBotIdentity.shapes.compactMap { shape in
            guard let url = Bundle.module.url(forResource: "bot-\(shape)", withExtension: "png"),
                  let image = NSImage(contentsOf: url) else { return nil }
            return (shape, image)
        }
    )

    @MainActor private static var coloredImages: [String: NSImage] = [:]

    @MainActor public static func coloredImage(for agentID: String, paletteID: String? = nil) -> NSImage? {
        let palette = AgentBotIdentity.palette(for: agentID, paletteID: paletteID)
        let key = AgentBotIdentity.shape(for: agentID) + "/" + palette.id
        if let image = coloredImages[key] { return image }
        guard let source = image(for: agentID)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let tinted = tint(source, palette: palette) else { return nil }
        let image = NSImage(cgImage: tinted, size: CGSize(width: 512, height: 512))
        coloredImages[key] = image
        return image
    }

    @MainActor
    public static func image(for agentID: String) -> NSImage? {
        images[AgentBotIdentity.shape(for: agentID)]
    }
    #elseif canImport(UIKit)
    @MainActor private static let images: [String: UIImage] = Dictionary(uniqueKeysWithValues:
        AgentBotIdentity.shapes.compactMap { shape in
            guard let url = Bundle.module.url(forResource: "bot-\(shape)", withExtension: "png"),
                  let image = UIImage(contentsOfFile: url.path) else { return nil }
            return (shape, image)
        }
    )
    @MainActor private static var coloredImages: [String: UIImage] = [:]

    @MainActor private static func coloredImage(for agentID: String, paletteID: String?) -> UIImage? {
        let palette = AgentBotIdentity.palette(for: agentID, paletteID: paletteID)
        let key = AgentBotIdentity.shape(for: agentID) + "/" + palette.id
        if let image = coloredImages[key] { return image }
        guard let source = images[AgentBotIdentity.shape(for: agentID)]?.cgImage,
              let tinted = tint(source, palette: palette) else { return nil }
        let image = UIImage(cgImage: tinted)
        coloredImages[key] = image
        return image
    }
    #endif
}
