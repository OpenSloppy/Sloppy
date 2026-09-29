import Foundation
import MetalKit
import Testing
@testable import SloppyDesktopCompanion

@Suite("Magic Pointer Metal trail")
@MainActor
struct PointerTrailRendererTests {
    @Test func missingMetalFailsWithoutCreatingAnOverlay() {
        #expect(throws: (any Error).self) {
            _ = try PointerTrailRenderer(screenFrame: CGRect(x: 0, y: 0, width: 640, height: 300), displayID: "preview", device: nil)
        }
    }

    @Test func nativeShaderProducesBlueBodySoftHaloAndExpiredTransparency() throws {
        let renderer = try PointerTrailRenderer(screenFrame: CGRect(x: 0, y: 0, width: 640, height: 300), displayID: "preview")
        renderer.points = [
            .init(point: CGPoint(x: 80, y: 150), time: 9.4, displayID: "preview", segmentID: 0),
            .init(point: CGPoint(x: 250, y: 150), time: 9.7, displayID: "preview", segmentID: 0),
            .init(point: CGPoint(x: 420, y: 150), time: 10, displayID: "preview", segmentID: 0),
        ]
        let image = try renderer.previewImage(at: 10)
        let data = try #require(image.dataProvider?.data) as Data
        let body = 4 * (150 * image.width + 410), halo = 4 * (174 * image.width + 410)
        #expect(data[body + 3] > 100)
        #expect(data[body] > data[body + 2]) // BGRA: blue is stronger than red.
        #expect(data[halo + 3] > 0 && data[halo + 3] < data[body + 3])
        let expired = try renderer.previewImage(at: 11)
        let expiredData = try #require(expired.dataProvider?.data) as Data
        #expect(expiredData.allSatisfy { $0 == 0 })
    }

    @Test func reduceMotionKeepsHaloButRemovesAnimatedTrail() throws {
        let renderer = try PointerTrailRenderer(screenFrame: CGRect(x: 0, y: 0, width: 640, height: 300), displayID: "preview")
        renderer.points = [.init(point: CGPoint(x: 80, y: 150), time: 10, displayID: "preview", segmentID: 0),
                           .init(point: CGPoint(x: 420, y: 150), time: 10, displayID: "preview", segmentID: 0)]
        renderer.pointer = CGPoint(x: 420, y: 150)
        renderer.reduceMotion = true
        let image = try renderer.previewImage(at: 10)
        let data = try #require(image.dataProvider?.data) as Data
        #expect(data[4 * (150 * image.width + 420) + 3] > 0)
        #expect(data[4 * (150 * image.width + 200) + 3] == 0)
    }

    @Test func curvedRibbonHasContinuousBloomAtItsJoins() throws {
        let renderer = try PointerTrailRenderer(screenFrame: CGRect(x: 0, y: 0, width: 820, height: 450), displayID: "preview")
        renderer.points = (0...90).map { index in
            let u = Double(index) / 90
            return .init(point: CGPoint(x: 820 * (0.16 + 0.58 * u), y: 450 * (0.34 + 0.19 * sin(u * .pi * 2) + 0.10 * u)),
                         time: 10 - (1 - u) * 0.8, displayID: "preview", segmentID: 0)
        }
        let image = try renderer.previewImage(at: 10, scale: 2)
        let data = try #require(image.dataProvider?.data) as Data
        for index in 36..<86 {
            let u = Double(index) / 90
            let x = 820 * (0.16 + 0.58 * u), y = 450 * (0.34 + 0.19 * sin(u * .pi * 2) + 0.10 * u)
            let dy = 450 * (0.19 * 2 * .pi * cos(u * 2 * .pi) + 0.10), dx = 820 * 0.58
            let length = hypot(dx, dy)
            for side in [-1.0, 1.0] {
                let pixelX = Int((x - dy / length * 18 * side) * 2)
                let pixelY = Int((450 - y - dx / length * 18 * side) * 2)
                let alpha = data[4 * (pixelY * image.width + pixelX) + 3]
                #expect(alpha > 0, "Bloom must remain continuous through curved joins")
            }
        }
    }
}
