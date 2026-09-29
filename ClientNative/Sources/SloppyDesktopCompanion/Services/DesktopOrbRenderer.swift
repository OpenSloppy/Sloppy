import Foundation
import MetalKit

struct DesktopOrbUniforms {
    var resolution: SIMD2<Float>
    var time: Float = 8
    var level: Float = 0
    var bass: Float = 0
    var mid: Float = 0
    var treble: Float = 0
    var padding: Float = 0
}

enum DesktopOrbRenderError: LocalizedError {
    case unavailable, missingShader, missingFunction, commandFailed

    var errorDescription: String? {
        switch self {
        case .unavailable: "Metal is unavailable on this Mac."
        case .missingShader: "The DesktopOrb Metal shader is missing."
        case .missingFunction: "The DesktopOrb Metal shader functions are missing."
        case .commandFailed: "Metal could not render the DesktopOrb frame."
        }
    }
}

@MainActor
final class DesktopOrbRenderer: NSObject, MTKViewDelegate {
    let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let pipeline: any MTLRenderPipelineState
    private var lastFrame = CACurrentMediaTime()
    private var time: Float = 8
    private var level: Float = 0
    var audioLevel: Double = 0
    var speed: Float = 1
    var reduceMotion = false
    #if DEBUG
    private(set) var renderedFrames = 0
    #endif

    init(device: (any MTLDevice)?) throws {
        guard let device, let queue = device.makeCommandQueue() else { throw DesktopOrbRenderError.unavailable }
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "DesktopOrb", withExtension: "metal", subdirectory: "Resources") else {
            throw DesktopOrbRenderError.missingShader
        }
        let library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
        guard let vertex = library.makeFunction(name: "desktopOrbVertex"),
              let fragment = library.makeFunction(name: "desktopOrbFragment") else {
            throw DesktopOrbRenderError.missingFunction
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        guard let color = descriptor.colorAttachments[0] else { throw DesktopOrbRenderError.commandFailed }
        color.pixelFormat = .bgra8Unorm
        // The Aura shader outputs premultiplied color into a transparent panel.
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.sourceAlphaBlendFactor = .one
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        self.device = device
        self.queue = queue
        self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        super.init()
    }

    func resetFrameClock() { lastFrame = CACurrentMediaTime() }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer() else { return }
        let now = CACurrentMediaTime()
        let dt = Float(min(max(now - lastFrame, 0), 0.05))
        lastFrame = now
        let target = audioLevel.isFinite ? Float(min(max(audioLevel, 0), 1)) : 0
        level += (target - level) * (1 - exp(-dt * (target > level ? 14 : 5)))
        if !reduceMotion { time += dt * speed * (1 + level * 0.5) }
        var uniforms = DesktopOrbUniforms(resolution: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
                                          time: reduceMotion ? 8 : time, level: reduceMotion ? 0 : level,
                                          bass: reduceMotion ? 0 : level, mid: reduceMotion ? 0 : level,
                                          treble: reduceMotion ? 0 : level)
        guard encode(pass: pass, command: command, uniforms: &uniforms) else { return }
        command.present(drawable)
        command.commit()
        #if DEBUG
        renderedFrames += 1
        #endif
    }

    private func encode(pass: MTLRenderPassDescriptor, command: any MTLCommandBuffer,
                        uniforms: inout DesktopOrbUniforms) -> Bool {
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<DesktopOrbUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }

    #if DEBUG
    // The same shader and pipeline serve GPU checks and own-panel previews.
    func renderPixels(size: Int, time: Float, level: Float) throws -> [UInt8] {
        guard size > 0, size <= 4096 else { throw DesktopOrbRenderError.commandFailed }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor),
              let command = queue.makeCommandBuffer() else { throw DesktopOrbRenderError.commandFailed }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        var uniforms = DesktopOrbUniforms(resolution: SIMD2(repeating: Float(size)), time: time,
                                          level: level, bass: level, mid: level, treble: level)
        guard encode(pass: pass, command: command, uniforms: &uniforms) else { throw DesktopOrbRenderError.commandFailed }
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { throw command.error ?? DesktopOrbRenderError.commandFailed }
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        texture.getBytes(&pixels, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        return pixels
    }

    func previewImage(size: Int) throws -> CGImage {
        let pixels = try renderPixels(size: size, time: reduceMotion ? 8 : time, level: reduceMotion ? 0 : level)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)],
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw DesktopOrbRenderError.commandFailed
        }
        return image
    }
    #endif
}
