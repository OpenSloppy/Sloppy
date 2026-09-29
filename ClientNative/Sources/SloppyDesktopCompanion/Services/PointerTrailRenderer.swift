import Foundation
import MetalKit

struct PointerTrailVertex {
    var position: SIMD2<Float>
    var uv: SIMD2<Float>
    var opacity: Float
    var core: Float
    var kind: Float
    var padding: Float = 0
}

@MainActor
final class PointerTrailRenderer: NSObject, MTKViewDelegate {
    let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let pipeline: any MTLRenderPipelineState
    var screenFrame: CGRect
    var displayID: String
    var points: [PointerTrailPoint] = []
    var pointer: CGPoint?
    var showsTrail = true
    var reduceMotion = false
    private(set) var renderedFrames = 0

    init(screenFrame: CGRect, displayID: String, device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()) throws {
        guard let device, let queue = device.makeCommandQueue() else { throw DesktopOrbRenderError.unavailable }
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "PointerTrail", withExtension: "metal", subdirectory: "Resources") else {
            throw DesktopOrbRenderError.missingShader
        }
        let library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
        guard let vertex = library.makeFunction(name: "pointerTrailVertex"),
              let fragment = library.makeFunction(name: "pointerTrailFragment") else { throw DesktopOrbRenderError.missingFunction }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        guard let color = descriptor.colorAttachments[0] else { throw DesktopOrbRenderError.commandFailed }
        color.pixelFormat = .bgra8Unorm
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.sourceAlphaBlendFactor = .one
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        self.device = device; self.queue = queue
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        self.screenFrame = screenFrame; self.displayID = displayID
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer() else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let vertices = vertices(at: now)
        guard encode(vertices, size: view.bounds.size, pass: pass, command: command) else { return }
        command.present(drawable)
        command.commit()
        renderedFrames += 1
        if reduceMotion || !showsTrail || !points.contains(where: { now - $0.time < PointerTrailHistory.lifetime }) {
            view.isPaused = true
        }
    }

    func vertices(at time: TimeInterval) -> [PointerTrailVertex] {
        var output: [PointerTrailVertex] = []
        if let pointer, screenFrame.contains(pointer) {
            appendDisk(at: local(pointer), radius: 42, opacity: 0.38, core: 0, kind: 1, to: &output)
        }
        guard showsTrail, !reduceMotion else { return output }
        let visible = points.filter { $0.displayID == displayID && time - $0.time < PointerTrailHistory.lifetime }
        var start = 0
        while start < visible.count {
            var end = start + 1
            while end < visible.count, visible[end].segmentID == visible[start].segmentID { end += 1 }
            let curve = smoothed(Array(visible[start..<end]))
            // Share each cross-section between adjacent triangles. Independent segment quads
            // leave thin gaps in the wide bloom on bends, visible as a comb around the curve.
            var left: [PointerTrailVertex] = []
            var right: [PointerTrailVertex] = []
            for index in curve.indices {
                let point = curve[index]
                let before = curve[max(0, index - 1)].point
                let after = curve[min(curve.count - 1, index + 1)].point
                let tangent = after - before
                let length = simd_length(tangent)
                let normal = length > 0.1 ? SIMD2(-tangent.y, tangent.x) / length * 32 : SIMD2<Float>(0, 32)
                let opacity = Float(PointerTrailHistory.opacity(age: time - point.time))
                let core = Float(PointerTrailHistory.width(age: time - point.time) / 2)
                left.append(.init(position: point.point - normal, uv: [-1, 0], opacity: opacity, core: core, kind: 0))
                right.append(.init(position: point.point + normal, uv: [1, 0], opacity: opacity, core: core, kind: 0))
            }
            for index in 1..<curve.count {
                let a = curve[index - 1], b = curve[index]
                let delta = b.point - a.point
                let distance = simd_length(delta)
                guard distance > 0.1 else { continue }
                output += [left[index - 1], right[index - 1], left[index], left[index], right[index - 1], right[index]]
            }
            for index in start == end - 1 ? [start] : [start, end - 1] {
                let point = visible[index]
                appendDisk(at: local(point.point), radius: 32,
                           opacity: Float(PointerTrailHistory.opacity(age: time - point.time)),
                           core: Float(PointerTrailHistory.width(age: time - point.time) / 2), kind: 2, to: &output)
            }
            start = end
        }
        return output
    }

    private func local(_ point: CGPoint) -> SIMD2<Float> {
        SIMD2(Float(point.x - screenFrame.minX), Float(screenFrame.maxY - point.y))
    }

    private func smoothed(_ points: [PointerTrailPoint]) -> [(point: SIMD2<Float>, time: TimeInterval)] {
        guard points.count > 2 else { return points.map { (local($0.point), $0.time) } }
        var result: [(point: SIMD2<Float>, time: TimeInterval)] = [(local(points[0].point), points[0].time)]
        for index in 1..<points.count {
            let a = local(points[index - 1].point)
            let b = local(points[index].point)
            let from = index > 1 ? (local(points[index - 2].point) + a) / 2 : a
            let to = index < points.count - 1 ? (a + b) / 2 : b
            let steps = max(1, min(24, Int(simd_length(to - from) / 3)))
            for step in 1...steps {
                let t = Float(step) / Float(steps)
                let point = (1 - t) * (1 - t) * from + 2 * (1 - t) * t * a + t * t * to
                let timestamp = points[index - 1].time + Double(t) * (points[index].time - points[index - 1].time)
                result.append((point, timestamp))
            }
        }
        return result
    }

    private func appendDisk(at point: SIMD2<Float>, radius: Float, opacity: Float, core: Float,
                            kind: Float, to output: inout [PointerTrailVertex]) {
        let corners: [SIMD2<Float>] = [[-1, -1], [1, -1], [-1, 1], [-1, 1], [1, -1], [1, 1]]
        output += corners.map { PointerTrailVertex(position: point + $0 * radius, uv: $0, opacity: opacity, core: core, kind: kind) }
    }

    private func encode(_ vertices: [PointerTrailVertex], size: CGSize, pass: MTLRenderPassDescriptor,
                        command: any MTLCommandBuffer) -> Bool {
        guard size.width > 0, size.height > 0, let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.setRenderPipelineState(pipeline)
        if !vertices.isEmpty {
            let buffer = vertices.withUnsafeBytes { bytes in
                bytes.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: bytes.count, options: .storageModeShared) }
            }
            guard let buffer else { encoder.endEncoding(); return false }
            var resolution = SIMD2(Float(size.width), Float(size.height))
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&resolution, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        }
        encoder.endEncoding()
        return true
    }

    #if DEBUG
    func previewImage(at time: TimeInterval, scale: CGFloat = 1) throws -> CGImage {
        let width = max(1, Int(screenFrame.width * scale)), height = max(1, Int(screenFrame.height * scale))
        guard width <= 4096, height <= 4096 else { throw DesktopOrbRenderError.commandFailed }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .renderTarget; descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor), let command = queue.makeCommandBuffer() else { throw DesktopOrbRenderError.commandFailed }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard encode(vertices(at: time), size: screenFrame.size, pass: pass, command: command) else { throw DesktopOrbRenderError.commandFailed }
        command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else { throw command.error ?? DesktopOrbRenderError.commandFailed }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)],
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw DesktopOrbRenderError.commandFailed }
        return image
    }
    #endif
}
