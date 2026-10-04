#if os(macOS)
import AppKit
import SloppyClientUI
import SloppyClientCore
import SwiftUI
import SpriteKit
import Testing
import SloppyUITestSupport
import ImageIO
import UniformTypeIdentifiers
@testable import SloppyClient

@Suite(.serialized, .appKitUI)
@MainActor
struct AgentBotArtworkTests {
    @Test func renderBotCatalogAndNotchHero() async throws {
        let state = SloppyDesktopOverlayState()
        state.errorMessage = "Task interrupted · Sloppy"
        state.activeTasks = (0..<25).map {
            .init(id: "project/\($0)", projectID: "project", taskID: "\($0)", title: "Task \($0)",
                  projectName: "Sloppy", status: .inProgress, rawStatus: "in_progress", agentID: "sloppy")
        }
        let host = NSHostingView(rootView: BotArtworkPreview(state: state))
        let window = NSWindow(contentRect: NSRect(x: 150, y: 150, width: 640, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        for x in [142, 261, 379, 497] {
            let color = try #require(bitmap.colorAt(x: Int(CGFloat(x) * scale), y: Int(120 * scale))?.usingColorSpace(.sRGB))
            #expect(max(color.redComponent, color.greenComponent, color.blueComponent) > 0.3)
        }
        // cacheDisplay omits SpriteKit's Metal layer. Capture its actual scene
        // through SKView and place it at the same frame in the native snapshot.
        let image = NSImage(size: host.bounds.size)
        image.lockFocus()
        bitmap.draw(in: host.bounds)
        let pet = try #require(descendants(host).compactMap { $0 as? SloppyNotchPetSpriteView }.first)
        for tick in 0...12 { pet.advanceFrame(to: 10 + Double(tick) / 30) }
        let scene = try #require(pet.scene)
        let texture = try #require(pet.texture(from: scene, crop: scene.frame))
        let frame = pet.convert(pet.bounds, to: host)
        let drawingFrame = host.isFlipped
            ? NSRect(x: frame.minX, y: host.bounds.height - frame.maxY, width: frame.width, height: frame.height)
            : frame
        NSGraphicsContext.current?.cgContext.draw(texture.cgImage(), in: drawingFrame)
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let result = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(result.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/sloppy-bot-native-preview.png"))
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    @Test func bundledBotsHaveTransparentCornersAndVisibleBodies() throws {
        for id in ["a", "b", "c", "d"] {
            let image = try #require(AgentBotAvatar.image(for: id))
            let data = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: data))
            #expect(bitmap.hasAlpha)
            #expect(bitmap.colorAt(x: 0, y: 0)?.alphaComponent == 0)
            #expect((bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.alphaComponent ?? 0) > 0.95)
        }
    }

    @Test func notchUsesTheSameAgentTextureAndSwitchesIdentity() throws {
        let view = SloppyNotchPetSpriteView(agentID: "a", presentationScale: 1, state: .idle, onClick: nil)
        let character = try #require(view.scene?.children.first(where: { $0.zPosition == 2 }))
        let sprite = try #require(character.children.first as? SKSpriteNode)
        let circle = try #require(sprite.texture)
        view.setAgentID("b")
        #expect(sprite.texture !== circle)
        #expect(character.children.count == 3)
        #expect(sprite.texture?.filteringMode == .linear)
        view.setCommunicationState(.error)
        for tick in 0...12 { view.advanceFrame(to: Double(tick) / 30) }
        let bubble = try #require(view.scene?.children.first(where: { $0.zPosition == 6 }))
        #expect(bubble.alpha > 0.9)
        #expect((bubble.children.first as? SKLabelNode)?.text == "!")
        view.setCommunicationState(.needsInput)
        view.advanceFrame(to: 0.5)
        #expect((bubble.children.first as? SKLabelNode)?.text == "?")
    }

    @Test func eyesFollowThePointerBlinkAndReactToPokes() throws {
        let view = SloppyNotchPetSpriteView(agentID: "a", paletteID: "mint", presentationScale: 1, state: .idle, onClick: nil)
        let left = try #require(view.scene?.childNode(withName: "//left-eye") as? SKShapeNode)
        for tick in 0...30 { view.advanceFrame(to: Double(tick) / 30, pointer: CGPoint(x: -100, y: 12)) }
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { #expect(left.position.x < -2.6) }
        for tick in 31...60 { view.advanceFrame(to: Double(tick) / 30, pointer: CGPoint(x: 100, y: 12)) }
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { #expect(left.position.x > -2.3) }
        view.advanceFrame(to: 3.9, pointer: CGPoint(x: 100, y: 12))
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { #expect(left.yScale < 0.1) }
        view.reactToPoke(at: .zero, time: 4.1)
        view.advanceFrame(to: 4.1)
        #expect(left.xScale == 1.25)
        view.reactToPoke(at: .zero, time: 4.2)
        view.advanceFrame(to: 4.2)
        #expect(left.fillColor.alphaComponent == 0)
        #expect(left.strokeColor.alphaComponent > 0.9)
        view.reactToPoke(at: .zero, time: 4.3)
        view.advanceFrame(to: 4.3)
        #expect(left.zRotation < -0.3)
    }

    @Test func paletteTintKeepsTransparencyAndIsCached() throws {
        let mint = try #require(AgentBotAvatar.coloredImage(for: "a", paletteID: "mint"))
        let rose = try #require(AgentBotAvatar.coloredImage(for: "a", paletteID: "rose"))
        #expect(mint === AgentBotAvatar.coloredImage(for: "a", paletteID: "mint"))
        let mintData = try #require(mint.tiffRepresentation)
        let roseData = try #require(rose.tiffRepresentation)
        let m = try #require(NSBitmapImageRep(data: mintData))
        let r = try #require(NSBitmapImageRep(data: roseData))
        let mc = try #require(m.colorAt(x: m.pixelsWide / 2, y: m.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        let rc = try #require(r.colorAt(x: r.pixelsWide / 2, y: r.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        #expect(mc.greenComponent > mc.redComponent)
        #expect(rc.redComponent > rc.greenComponent)
        #expect(m.colorAt(x: 0, y: 0)?.alphaComponent == 0)
    }

    @Test func renderAnimatedEyeAndEmotionPreview() throws {
        let view = SloppyNotchPetSpriteView(agentID: "a", paletteID: "mint", presentationScale: 5, state: .idle, onClick: nil)
        view.frame = NSRect(x: 0, y: 0, width: 140, height: 140)
        let scene = try #require(view.scene)
        scene.size = CGSize(width: 140, height: 140)
        let url = URL(fileURLWithPath: "/tmp/sloppy-bot-eyes.gif")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 160, nil))
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]] as CFDictionary)
        for frame in 0..<160 {
            let time = Double(frame) / 10
            if [45, 50, 55].contains(frame) { view.reactToPoke(at: .zero, time: time) }
            if frame == 80 { view.setCommunicationState(.error) }
            if frame == 100 { view.setCommunicationState(.thinking) }
            if frame == 120 { view.setCommunicationState(.needsInput) }
            if frame == 140 { view.setCommunicationState(.idle) }
            view.advanceFrame(to: time, pointer: CGPoint(x: 70 + sin(time * 1.5) * 120, y: 70 + cos(time) * 40))
            let texture = try #require(view.texture(from: scene, crop: scene.frame))
            let rendered = texture.cgImage()
            let bounds = CGRect(x: 0, y: 0, width: rendered.width, height: rendered.height)
            let canvas = try #require(CGContext(data: nil, width: rendered.width, height: rendered.height,
                                               bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            canvas.setFillColor(CGColor(gray: 0, alpha: 1))
            canvas.fill(bounds)
            canvas.draw(rendered, in: bounds)
            let frameImage = try #require(canvas.makeImage())
            CGImageDestinationAddImage(destination, frameImage,
                [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: 0.1]] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func notchUsesTheAgentOfTheRelatedTaskAndRun() {
        let state = SloppyDesktopOverlayState()
        state.activeTasks = [.init(id: "p/t", projectID: "p", taskID: "t", title: "Fix", projectName: "Project",
                                   status: .inProgress, rawStatus: "blocked", agentID: "b")]
        #expect(state.mascotAgentID == "b")
        #expect(state.mascotState == .error)
        state.activeAgentRuns = [.init(id: "a/s", agentID: "a", sessionID: "s", sessionTitle: "Work",
                                      agentName: "Agent", stage: .thinking, statusLabel: "Thinking",
                                      statusDetails: nil, needsInput: false, inputPrompt: nil, updatedAt: Date())]
        #expect(state.mascotAgentID == "a")
    }
}

private struct BotArtworkPreview: View {
    let state: SloppyDesktopOverlayState
    @Namespace private var petNamespace

    var body: some View {
        VStack(spacing: 24) {
            HStack(spacing: 28) {
                ForEach(Array(["a", "b", "c", "d"].enumerated()), id: \.element) { index, id in
                    AgentBotAvatar(agentID: id, size: 90, paletteID: ["mint", "violet", "coral", "amber"][index])
                }
            }
            SloppyDesktopNotchHeroView(state: state, showsMascot: true, petNamespace: petNamespace)
        }
        .padding(24)
        .frame(width: 640, height: 300)
        .background(.black)
        .preferredColorScheme(.dark)
    }
}
#endif
