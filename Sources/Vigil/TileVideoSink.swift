//
//  TileVideoSink.swift
//  Vigil
//
//  The adapter between `VigilVideo`'s decode pipeline and whichever `VigilRender` tile SwiftUI
//  currently has on screen. The app owns it because it is the only module that sees both.
//  macOS-only. See docs/API_CONTRACT.md §4.9, §4.10 and §4.12.
//

#if os(macOS)

import CoreMedia
import Foundation
import os

import VigilProtocols
import VigilRender
import VigilVideo

// MARK: - TileVideoSink

/// Delivers decoded samples to the tile that is currently attached to a `FrameStreamHandle`.
///
/// **Why this exists.** `DecodePipeline` takes one `any VideoSink` for its lifetime, while SwiftUI
/// creates and destroys `VideoTileView`s as the hierarchy is rebuilt. `FrameStreamHandle` is
/// `VigilRender`'s answer to that — but it is `@MainActor`, and `VideoSink.enqueue` is
/// `nonisolated` and must return in under two milliseconds without hopping. This object bridges the
/// two: the handle pushes the current view in on the main actor, and the frame path reads it under
/// a lock held for the duration of a pointer copy.
///
/// **Why not just hand the tile to the pipeline.** `VigilRender` does now declare the conformance
/// (`Tile/VideoTileView+VideoSink.swift`, landed after this file was written), so `VideoTileView`
/// *is* a `VideoSink`. That still does not solve the lifetime problem above: `DecodePipeline` binds
/// one sink for its whole life, and the view it would bind to is replaced whenever SwiftUI rebuilds
/// the hierarchy. This object is the indirection that survives that.
///
/// **Isolation.** `OSAllocatedUnfairLock` is `Sendable` and owns its state, so this type needs
/// neither `@unchecked Sendable` — the repo's census of those is closed at three (R-52) — nor
/// `nonisolated(unsafe)`. `VideoTileView` is a `@MainActor` class and therefore `Sendable`, so
/// storing a reference across the boundary is legal; only its `nonisolated` members may be touched
/// from here, which is exactly what `enqueue` and `streamDidReset` are.
final class TileVideoSink: VideoSink {

    // MARK: - Stored Properties

    /// The view currently on screen, or `nil` between one being torn down and the next attaching.
    ///
    /// Written on the main actor by the handle's `onSinkChange`, read on the decode path. Held
    /// strongly for the fraction of a microsecond the lock is held; the handle itself holds the
    /// view weakly, so nothing here keeps a discarded view alive.
    private let attached = OSAllocatedUnfairLock<VideoTileView?>(initialState: nil)

    // MARK: - Initialisation

    /// Creates an unattached sink.
    init() {}

    // MARK: - Public API

    /// Follows `handle`, so that whichever tile SwiftUI mounts receives the frames.
    ///
    /// Call once, on the main actor, before the pipeline starts. Reads the handle's current sink
    /// first so that a view attached before this call is not missed.
    @MainActor
    func follow(_ handle: FrameStreamHandle) {
        let slot = attached
        handle.onSinkChange = { view in
            slot.withLock { $0 = view }
        }
        slot.withLock { $0 = handle.sink }
    }

    /// Stops delivering. The tile keeps its last picture, which is the correct thing to leave on
    /// screen (docs/API_CONTRACT.md §4.9 — never `flush(removingDisplayedImage:)`).
    func release() {
        attached.withLock { $0 = nil }
    }

    // MARK: - VideoSink

    nonisolated func enqueue(_ sampleBuffer: CMSampleBuffer, format: VideoFormatInfo,
                             generation: UInt32) {
        // The sample buffer is neither boxed nor stored: both sides are `nonisolated` and the call
        // is synchronous, so no isolation boundary is crossed (R-51).
        let view = attached.withLock { $0 }
        view?.enqueue(sampleBuffer, format: format, generation: generation)
    }

    nonisolated func streamDidReset() {
        let view = attached.withLock { $0 }
        view?.streamDidReset()
    }

    // Every other `VideoSink` member takes the protocol's no-op default: the slice's display path
    // has nothing to do on a format change or a dropped-frame report, and the tile discovers a
    // stall from its own layer.
}

#endif  // os(macOS)
