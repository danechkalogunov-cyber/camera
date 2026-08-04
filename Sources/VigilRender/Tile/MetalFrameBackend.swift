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

    /// Why a frame did not reach the screen, or `nil` when it did.
    ///
    /// ⛔ It used to return `Void` and swallow all three. A pixel buffer arriving at a tile with no
    /// Metal renderer is the black-picture bug in its purest form — the stream is up, the decoder
    /// is producing, and the frame evaporates in a `guard` with nothing logged and nothing counted.
    enum Refusal: String {
        /// No Metal renderer: this tile is not rendering through Metal, and something upstream
        /// decided it was. The frame cannot be shown by this backend at all.
        case noMetalRenderer
        /// The layer is gone, or Core Animation had no drawable free this instant.
        case noDrawable
        /// The renderer rejected the frame — wrong pixel format, or no texture available.
        case renderFailed
    }

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

    /// Draws one decoded frame, and says so when it cannot.
    ///
    /// - Returns: `nil` when the frame was drawn, otherwise why it was not.
    func enqueue(_ pixelBuffer: CVPixelBuffer) -> Refusal? {
        lock.withLock {
            guard let renderer else { return .noMetalRenderer }
            guard let drawable = layer?.nextDrawable() else { return .noDrawable }
            do {
                try renderer.render(pixelBuffer, to: drawable)
                return nil
            } catch {
                return .renderFailed
            }
        }
    }
}

#endif
