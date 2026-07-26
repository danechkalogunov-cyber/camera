//
//  TileRenderState.swift
//  VigilRender
//
//  The observable facts about one tile that SwiftUI is allowed to read: its size in backing
//  pixels, which backend is live, and whether frames are arriving.
//  Implements docs/API_CONTRACT.md §4.10 and docs/spec-render.md §9.4, slice subset.
//

#if os(macOS)

import Observation
import VigilProtocols

// MARK: - Backend

/// Which rendering path a tile is on.
///
/// The slice only ever reports `.sampleBufferLayer`; `.metal` exists so that the value published
/// to `VigilUI` does not change shape when the Metal backend lands.
public enum TileBackend: String, Sendable, Equatable {
    /// `CAMetalLayer` plus the tile shader. Not built in the slice.
    case metal
    /// `AVSampleBufferDisplayLayer`. The cheapest path and the slice's only one.
    case sampleBufferLayer
}

// MARK: - TileRenderState

/// What a tile publishes about itself.
///
/// Read by SwiftUI overlays and by the decode-budget policy in `VigilCore`; written only by the
/// `VideoTileView` that owns it. Every property is `private(set)` for exactly that reason.
///
/// The counters are published on **transitions**, not on every sample: the ingest path must not
/// schedule a main-actor hop per frame, so `totalEnqueued` and `totalDroppedNotReady` advance when
/// the tile starts receiving, when it is flushed, and whenever a sample is refused — not once per
/// picture.
@MainActor
@Observable
public final class TileRenderState {

    // MARK: - Stored properties

    /// The tile's size in **backing pixels** — `bounds` × `backingScaleFactor`, integer.
    ///
    /// This is the number the tile-class table in docs/API_CONTRACT.md §2 R-21 is keyed on. Zero
    /// on both axes means the tile has not been laid out yet, which is different from being small.
    public private(set) var pixelSize: Resolution = Resolution(width: 0, height: 0)

    /// Which backend is currently presenting. Always `.sampleBufferLayer` in the slice.
    public private(set) var backend: TileBackend = .sampleBufferLayer

    /// `true` once a sample has reached the display layer and until the next flush.
    ///
    /// It does **not** go false when frames merely stop arriving — that is a stall, and detecting
    /// it needs a clock the slice does not own. It is the "has anything ever been shown since the
    /// last reset" flag, which is what a connect-screen status line needs.
    public private(set) var isReceivingFrames = false

    /// Samples accepted by the renderer since the view was created.
    public private(set) var totalEnqueued: UInt64 = 0

    /// Samples refused because the renderer was not ready. Live video drops rather than queues, so
    /// a rising number here means the display path is behind, not that data was lost upstream.
    public private(set) var totalDroppedNotReady: UInt64 = 0

    // MARK: - Lifecycle

    /// Creates an empty state. Only `VideoTileView` should need this.
    public init() {}

    // MARK: - Mutation (module-internal)

    /// Records a new backing-pixel size.
    func setPixelSize(_ size: Resolution) {
        pixelSize = size
    }

    /// Records which backend is presenting.
    func setBackend(_ backend: TileBackend) {
        self.backend = backend
    }

    /// Folds one ingest outcome in.
    func absorb(_ outcome: SampleBufferBackend.Outcome) {
        totalEnqueued = outcome.totalEnqueued
        totalDroppedNotReady = outcome.totalDroppedNotReady
        if outcome.isFirstSinceFlush {
            isReceivingFrames = true
        }
    }

    /// The stream was reset or the layer was flushed: nothing has been shown since.
    func markIdle() {
        isReceivingFrames = false
    }
}

#endif
