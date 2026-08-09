//
//  MetalTileRenderer.swift
//  VigilRender
//
//  Zero-copy Metal rendering for BGRA camera frames with crop, colour and zone overlays.
//

#if os(macOS)

import CoreGraphics
import CoreVideo
import Metal
import QuartzCore

/// Color corrections performed by the tile fragment shader.
public struct TileColorAdjustments: Sendable, Equatable {
    public var brightness: Float
    public var contrast: Float
    public var saturation: Float
    public var gamma: Float

    public init(brightness: Float = 0, contrast: Float = 1, saturation: Float = 1,
                gamma: Float = 1) {
        self.brightness = brightness.clamped(to: -1 ... 1)
        self.contrast = contrast.clamped(to: 0 ... 2)
        self.saturation = saturation.clamped(to: 0 ... 2)
        self.gamma = gamma.clamped(to: 0.5 ... 2)
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

    /// How the frame is fitted to the tile.
    ///
    /// ⛔ WITHOUT THIS THE PICTURE IS STRETCHED, and nothing says so. The shader draws one quad over
    /// the whole drawable, so a 16:9 frame in a tile of any other shape is distorted — the first
    /// live camera in this app came up visibly squeezed. `AVSampleBufferDisplayLayer` applies
    /// `videoGravity` itself, which is why the other backend never needed this and why the option
    /// existed for a year without ever reaching the Metal path.
    ///
    /// Both non-stretch modes are handled on the CPU side, so the generated shader is untouched:
    /// `.fit` centres a viewport and leaves the cleared black around it, `.fill` trims the sampled
    /// rectangle to the tile's aspect.
    public var gravity: VideoGravity = .fit

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
        let fitted = Self.fit(gravity: gravity, crop: crop,
                              source: CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                                             height: CVPixelBufferGetHeight(pixelBuffer)),
                              target: CGSize(width: drawable.texture.width,
                                             height: drawable.texture.height))
        if let viewport = fitted.viewport { encoder.setViewport(viewport) }
        var uniforms = TileShaderUniforms(crop: fitted.crop, adjustments: adjustments,
                                          overlayCount: min(motionZones.count, 16))
        // `let`: `withUnsafeBytes` on an array only reads, unlike the `&uniforms` above, which
        // hands the encoder an inout pointer.
        let zones = motionZones.prefix(16).map { SIMD4($0.x, $0.y, $0.width, $0.height) }
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

    /// Where to draw, and what to sample, so that a frame is not distorted.
    ///
    /// Pure arithmetic over four numbers, `internal` and `static` so it can be tested without a GPU
    /// — which matters here, because every other line of this file needs a Metal device and none of
    /// it runs in CI.
    ///
    /// - Returns: the crop to sample, and a viewport when the frame must be inset. `nil` means the
    ///   whole drawable, which is what `.stretch` and an exactly-matching aspect both want.
    static func fit(gravity: VideoGravity,
                    crop: NormalizedVideoRect,
                    source: CGSize,
                    target: CGSize) -> (crop: NormalizedVideoRect, viewport: MTLViewport?) {
        let sourceWidth = Double(source.width) * Double(crop.width)
        let sourceHeight = Double(source.height) * Double(crop.height)
        let targetWidth = Double(target.width)
        let targetHeight = Double(target.height)
        guard gravity != .stretch,
              sourceWidth > 0, sourceHeight > 0, targetWidth > 0, targetHeight > 0 else {
            return (crop, nil)
        }
        let sourceAspect = sourceWidth / sourceHeight
        let targetAspect = targetWidth / targetHeight
        // A pixel of slack: a 1920×1080 frame in a 16:9 tile is not exactly 16:9 after rounding to
        // backing pixels, and insetting by a third of a pixel is worse than not insetting at all.
        guard abs(sourceAspect - targetAspect) > 0.001 else { return (crop, nil) }

        switch gravity {
        case .fit:
            // Letterbox. The bars are the pass's clear colour, which is black by contract
            // (DESIGN.md §3.6): the tile is never transparent behind the picture.
            let scale = min(targetWidth / sourceWidth, targetHeight / sourceHeight)
            let width = sourceWidth * scale
            let height = sourceHeight * scale
            return (crop, MTLViewport(originX: (targetWidth - width) / 2,
                                      originY: (targetHeight - height) / 2,
                                      width: width, height: height, znear: 0, zfar: 1))
        case .fill:
            // Trim the sampled rectangle instead of the viewport, so the drawable stays fully
            // covered and no pixel of it is left showing the clear colour.
            if sourceAspect > targetAspect {
                let kept = Float(targetAspect / sourceAspect)
                let width = crop.width * kept
                return (NormalizedVideoRect(x: crop.x + (crop.width - width) / 2, y: crop.y,
                                            width: width, height: crop.height), nil)
            }
            let kept = Float(sourceAspect / targetAspect)
            let height = crop.height * kept
            return (NormalizedVideoRect(x: crop.x, y: crop.y + (crop.height - height) / 2,
                                        width: crop.width, height: height), nil)
        case .stretch:
            return (crop, nil)
        }
    }
}

private struct TileShaderUniforms {
    var crop: SIMD4<Float>
    var color: SIMD4<Float>
    var overlayColor = SIMD4<Float>(1, 0.2, 0.1, 0.9)
    var overlayCount: UInt32

    init(crop: NormalizedVideoRect, adjustments: TileColorAdjustments, overlayCount: Int) {
        self.crop = SIMD4(crop.x, crop.y, crop.width, crop.height)
        self.color = SIMD4(adjustments.brightness, adjustments.contrast,
                           adjustments.saturation, adjustments.gamma)
        self.overlayCount = UInt32(overlayCount)
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float { min(max(self, range.lowerBound), range.upperBound) }
}

#endif
