//
//  MetalFrameBackend.swift
//  VigilRender
//
//  Thread-safe bridge that presents decoded pixel buffers through the Metal tile renderer.
//

#if os(macOS)

import CoreVideo
import Foundation
import Metal
import QuartzCore

/// Thread-safe handoff from VideoToolbox's callback to the tile's CAMetalLayer.
final class MetalFrameBackend: @unchecked Sendable {
    private let lock = NSLock()
    private let renderer: MetalTileRenderer?
    private weak var layer: CAMetalLayer?

    init(enabled: Bool) { renderer = enabled ? try? MetalTileRenderer() : nil }
    var isAvailable: Bool { renderer != nil }

    func adopt(_ layer: CAMetalLayer) { lock.withLock { self.layer = layer } }

    func configure(crop: NormalizedVideoRect, adjustments: TileColorAdjustments,
                   motionZones: [NormalizedVideoRect]) {
        lock.withLock {
            renderer?.crop = crop
            renderer?.adjustments = adjustments
            renderer?.motionZones = motionZones
        }
    }

    func enqueue(_ pixelBuffer: CVPixelBuffer) {
        lock.withLock {
            guard let renderer, let drawable = layer?.nextDrawable() else { return }
            try? renderer.render(pixelBuffer, to: drawable)
        }
    }
}

#endif
