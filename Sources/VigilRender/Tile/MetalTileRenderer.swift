//
//  MetalTileRenderer.swift
//  VigilRender
//
//  Zero-copy Metal rendering for BGRA camera frames with crop, colour and zone overlays.
//

#if os(macOS)

import CoreVideo
import Metal
import QuartzCore

/// Color corrections performed by the tile fragment shader.
public struct TileColorAdjustments: Sendable, Equatable {
    public var brightness: Float
    public var contrast: Float
    public var saturation: Float

    public init(brightness: Float = 0, contrast: Float = 1, saturation: Float = 1) {
        self.brightness = brightness.clamped(to: -1 ... 1)
        self.contrast = contrast.clamped(to: 0 ... 2)
        self.saturation = saturation.clamped(to: 0 ... 2)
    }
}

/// A normalized rectangle. The initializer clamps malformed values to the source image.
public struct NormalizedVideoRect: Sendable, Equatable {
    public let x: Float
    public let y: Float
    public let width: Float
    public let height: Float

    public init(x: Float, y: Float, width: Float, height: Float) {
        self.x = x.clamped(to: 0 ... 1)
        self.y = y.clamped(to: 0 ... 1)
        self.width = width.clamped(to: 0 ... 1 - self.x)
        self.height = height.clamped(to: 0 ... 1 - self.y)
    }
}

/// Produces the source crop used for cursor-centred digital zoom.
public enum DigitalZoomGeometry {
    public static func crop(scale: Float, anchorX: Float, anchorY: Float) -> NormalizedVideoRect {
        let zoom = scale.clamped(to: 1 ... 16)
        let width = 1 / zoom
        let height = 1 / zoom
        let anchorX = anchorX.clamped(to: 0 ... 1)
        let anchorY = anchorY.clamped(to: 0 ... 1)
        return NormalizedVideoRect(
            x: (anchorX - width * anchorX).clamped(to: 0 ... 1 - width),
            y: (anchorY - height * anchorY).clamped(to: 0 ... 1 - height),
            width: width,
            height: height
        )
    }
}

/// GPU renderer for BGRA `CVPixelBuffer`s. It owns no frame queue: callers submit only their latest
/// decoded frame, keeping decoder backpressure independent from Core Animation.
public final class MetalTileRenderer: @unchecked Sendable {
    public enum RendererError: Error {
        case metalUnavailable
        case shaderCompilation(String)
        case unsupportedPixelFormat(OSType)
        case textureCreationFailed
    }

    public var crop = NormalizedVideoRect(x: 0, y: 0, width: 1, height: 1)
    public var adjustments = TileColorAdjustments()
    public var motionZones: [NormalizedVideoRect] = []

    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let pipeline: any MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache

    public init(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()) throws {
        guard let device, let queue = device.makeCommandQueue() else {
            throw RendererError.metalUnavailable
        }
        let library: any MTLLibrary
        do {
            library = try device.makeLibrary(source: ShaderSource.VideoTile, options: nil)
        } catch {
            throw RendererError.shaderCompilation(String(describing: error))
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "videoTileVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "videoTileFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        self.device = device
        self.queue = queue
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard let cache else { throw RendererError.metalUnavailable }
        self.textureCache = cache
    }

    /// Draws a BGRA frame into a drawable without copying its pixel plane to CPU memory.
    public func render(_ pixelBuffer: CVPixelBuffer, to drawable: any CAMetalDrawable) throws {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard format == kCVPixelFormatType_32BGRA else {
            throw RendererError.unsupportedPixelFormat(format)
        }
        var wrapped: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixelBuffer, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), 0, &wrapped
        )
        guard result == kCVReturnSuccess, let wrapped, let texture = CVMetalTextureGetTexture(wrapped)
        else { throw RendererError.textureCreationFailed }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let command = queue.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = TileShaderUniforms(crop: crop, adjustments: adjustments,
                                          overlayCount: min(motionZones.count, 16))
        var zones = motionZones.prefix(16).map { SIMD4($0.x, $0.y, $0.width, $0.height) }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<TileShaderUniforms>.stride, index: 0)
        zones.withUnsafeBytes { bytes in
            if let baseAddress = bytes.baseAddress, !bytes.isEmpty {
                encoder.setFragmentBytes(baseAddress, length: bytes.count, index: 1)
            }
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
    }
}

private struct TileShaderUniforms {
    var crop: SIMD4<Float>
    var color: SIMD4<Float>
    var overlayColor = SIMD4<Float>(1, 0.2, 0.1, 0.9)
    var overlayCount: UInt32

    init(crop: NormalizedVideoRect, adjustments: TileColorAdjustments, overlayCount: Int) {
        self.crop = SIMD4(crop.x, crop.y, crop.width, crop.height)
        self.color = SIMD4(adjustments.brightness, adjustments.contrast, adjustments.saturation, 0)
        self.overlayCount = UInt32(overlayCount)
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float { min(max(self, range.lowerBound), range.upperBound) }
}

#endif
