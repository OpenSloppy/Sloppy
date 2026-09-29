import MetalKit
import Testing
@testable import SloppyDesktopCompanion

#if DEBUG
@Suite("Desktop orb Metal rendering")
@MainActor
struct DesktopOrbRendererTests {
    @Test func rendersGlowIntoTransparentTexture() throws {
        let renderer = try DesktopOrbRenderer(device: MTLCreateSystemDefaultDevice())
        let pixels = try renderer.renderPixels(size: 96, time: 8, level: 0)
        let center = (48 * 96 + 48) * 4
        #expect(pixels[3] < 5)
        #expect(pixels[center + 3] > 200)
        #expect(pixels[center] > pixels[center + 2]) // Blue exceeds red in the luminous core.
    }

    @Test func flowsWithoutAudioAndRespondsToVoiceLevel() throws {
        let renderer = try DesktopOrbRenderer(device: MTLCreateSystemDefaultDevice())
        let idle = try renderer.renderPixels(size: 96, time: 8, level: 0)
        let flowing = try renderer.renderPixels(size: 96, time: 12, level: 0)
        let speaking = try renderer.renderPixels(size: 96, time: 8, level: 0.8)
        #expect(idle != flowing)
        let idleAlpha = stride(from: 3, to: idle.count, by: 4).reduce(0) { $0 + Int(idle[$1]) }
        let speakingAlpha = stride(from: 3, to: speaking.count, by: 4).reduce(0) { $0 + Int(speaking[$1]) }
        #expect(speakingAlpha > idleAlpha)
    }

    @Test func expandedOrbFadesBeforeAllCanvasEdges() throws {
        let renderer = try DesktopOrbRenderer(device: MTLCreateSystemDefaultDevice())
        let size = 160
        let pixels = try renderer.renderPixels(size: size, time: 8, level: 0.8)
        for coordinate in 0..<size {
            for index in [coordinate, (size - 1) * size + coordinate,
                          coordinate * size, coordinate * size + size - 1] {
                #expect(pixels[index * 4 + 3] < 2)
            }
        }
        let nearEdgeAlpha = pixels[(size / 2 * size + 3) * 4 + 3]
        let innerAlpha = pixels[(size / 2 * size + 20) * 4 + 3]
        #expect(innerAlpha > nearEdgeAlpha)
    }
}
#endif
