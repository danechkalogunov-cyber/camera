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

    /// What one frame did.
    ///
    /// `isFirstSinceFlush` is the fact the status line waits on: `TileRenderState.isReceivingFrames`
    /// is what turns "Waiting for a keyframe…" off, and on the sample-buffer path it is set from
    /// the equivalent flag. This path had no equivalent, so the very first live camera came up with
    /// a correct picture underneath a spinner counting to nineteen seconds and a CONNECTING badge.
    struct Outcome {
        let refusal: Refusal?
        let isFirstSinceFlush: Bool
    }

    private let lock = NSLock()
    private let renderer: MetalTileRenderer?
    private weak var layer: CAMetalLayer?
    private var hasDrawnSinceFlush = false

    init(enabled: Bool) { renderer = enabled ? try? MetalTileRenderer() : nil }
    var isAvailable: Bool { renderer != nil }

    func adopt(_ layer: CAMetalLayer) { lock.withLock { self.layer = layer } }

    /// Nothing has been drawn since: the stream restarted or the decoder was rebuilt.
    func markFlushed() { lock.withLock { hasDrawnSinceFlush = false } }

    func configure(crop: NormalizedVideoRect, adjustments: TileColorAdjustments,
                   motionZones: [NormalizedVideoRect], gravity: VideoGravity) {
        lock.withLock {
            renderer?.crop = crop
            renderer?.adjustments = adjustments
            renderer?.motionZones = motionZones
            renderer?.gravity = gravity
        }
    }

    /// Draws one decoded frame, and says both what happened and whether it was the first.
    func enqueue(_ pixelBuffer: CVPixelBuffer) -> Outcome {
        lock.withLock {
            guard let renderer else { return Outcome(refusal: .noMetalRenderer,
                                                     isFirstSinceFlush: false) }
            guard let drawable = layer?.nextDrawable() else { return Outcome(refusal: .noDrawable,
                                                                             isFirstSinceFlush: false) }
            do {
                try renderer.render(pixelBuffer, to: drawable)
            } catch {
                return Outcome(refusal: .renderFailed, isFirstSinceFlush: false)
            }
            let isFirst = !hasDrawnSinceFlush
            hasDrawnSinceFlush = true
            return Outcome(refusal: nil, isFirstSinceFlush: isFirst)
        }
    }
}

#endif
