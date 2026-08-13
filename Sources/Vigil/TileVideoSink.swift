//
//  TileVideoSink.swift
//  Vigil
//
//  The adapter between `VigilVideo`'s decode pipeline and whichever `VigilRender` tile SwiftUI
//  currently has on screen. The app owns it because it is the only module that sees both.
//  macOS-only. See docs/API_CONTRACT.md §4.9, §4.10 and §4.12.
//

#if os(macOS)

import CoreGraphics
import CoreMedia
import CoreVideo
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

    /// Holds the last drawn frame in place without tearing down the RTSP session. The timeline's
    /// pause control must not turn a presentation toggle into a reconnect.
    private let presentationPaused = OSAllocatedUnfairLock(initialState: false)

    // MARK: - Initialisation

    /// Creates an unattached sink.
    init() {}

    // MARK: - Public API

    /// Follows `handle`, so that whichever tile SwiftUI mounts receives the frames.
    ///
    /// Call once, on the main actor, before the pipeline starts. Reads the handle's current sink
    /// first so that a view attached before this call is not missed.
    ///
    /// - Parameters:
    ///   - handle: the attach point every `VideoTile` for this window registers with.
    ///   - onRenderState: the mounted tile's ``VigilRender/TileRenderState``, or `nil` when none is
    ///     mounted. `FrameStreamHandle.onSinkChange` is a **single** closure slot, so this method
    ///     owns it and fans out rather than letting a second consumer overwrite it. The frame path
    ///     does not use the render state; the status line does, which is why it is handed out here
    ///     instead of being read through `attached` (that lock is on the ingest path and must stay
    ///     a pointer copy).
    @MainActor
    func follow(_ handle: FrameStreamHandle,
                onRenderState: @escaping @Sendable (TileRenderState?) -> Void = { _ in }) {
        let slot = attached
        // This closure is checked as `nonisolated`, because `onSinkChange`'s type is not isolated —
        // so it may touch only `Sendable` things. `slot` is a lock and `view?.state` is an immutable
        // `let` of `Sendable` type on a `@MainActor` class, which SE-0434 makes readable from here;
        // publishing it onto the main actor is `onRenderState`'s job, not this closure's.
        handle.onSinkChange = { view in
            slot.withLock { $0 = view }
            onRenderState(view?.state)
        }
        // ⛔ `handle.sink` is read HERE and not inside the `withLock` closure below.
        //
        // `OSAllocatedUnfairLock.withLock` takes a `@Sendable` closure, so its body is checked as
        // nonisolated — and `sink` is a `@MainActor` property, which nonisolated code may not read:
        //   error: main actor-isolated property 'sink' can not be referenced from a Sendable closure
        // This method is `@MainActor`, so the read is legal one line earlier. Hoisting it is the whole
        // fix; the value that crosses into the closure is a `VideoTileView?`, and a `@MainActor` class
        // is implicitly `Sendable`, so nothing unsafe is captured.
        //
        // Read once into a local rather than twice, so the reference stored under the lock and the
        // render state published to the caller cannot describe two different views if the handle
        // changes between the two statements.
        let current = handle.sink
        slot.withLock { $0 = current }
        onRenderState(current?.state)
    }

    /// Stops or resumes delivery to the renderer while leaving decoding and the network session
    /// alive. The next frame after resume replaces the held picture in the usual way.
    @MainActor
    func setPresentationPaused(_ paused: Bool) {
        presentationPaused.withLock { $0 = paused }
    }

    /// Stops delivering. The tile keeps its last picture, which is the correct thing to leave on
    /// screen (docs/API_CONTRACT.md §4.9 — never `flush(removingDisplayedImage:)`).
    func release() {
        attached.withLock { $0 = nil }
    }

    // MARK: - VideoSink

    /// ⛔ THIS WAS THE BLACK PICTURE, AND IT WAS THREE MISSING FORWARDS.
    ///
    /// `VideoSink` has two ingest paths — compressed samples for `AVSampleBufferDisplayLayer`, and
    /// decoded pixel buffers for the Metal tile — and `DecodePipeline` picks one **in `init`**, from
    /// `prefersDecodedPixelBuffers`, then builds a `PixelBufferDecoder` or not. This adapter
    /// forwarded `enqueue` and `streamDidReset` and took the protocol's defaults for the rest, so it
    /// answered `false` on behalf of a tile that renders through Metal. The pipeline therefore sent
    /// compressed samples to a tile whose backing layer is a `CAMetalLayer` and whose sample-buffer
    /// renderer is nil forever, and a completely healthy stream — RTSP up, auth accepted, first
    /// frame assembled in 0.6 s — produced a black rectangle and one `dropped 100 frame(s), reason:
    /// noRenderer` line every few seconds.
    ///
    /// A proxy has to forward *everything* it stands in front of. The three members below are the
    /// rest of the protocol, and the default answer when no tile is mounted is the one the tile is
    /// going to give when it mounts.
    nonisolated var prefersDecodedPixelBuffers: Bool {
        if let view = attached.withLock({ $0 }) { return view.prefersDecodedPixelBuffers }
        // No tile yet — which is the normal case, since the pipeline is built before SwiftUI mounts
        // one. `resolvedDefault` builds the same renderer `makeBackingLayer()` will, so the answer
        // is this machine's, not a guess.
        return TileRenderBackend.resolvedDefault == .metal
    }

    nonisolated func enqueue(_ sampleBuffer: CMSampleBuffer, format: VideoFormatInfo,
                             generation: UInt32) {
        guard !presentationPaused.withLock({ $0 }) else { return }
        // The sample buffer is neither boxed nor stored: both sides are `nonisolated` and the call
        // is synchronous, so no isolation boundary is crossed (R-51).
        let view = attached.withLock { $0 }
        view?.enqueue(sampleBuffer, format: format, generation: generation)
    }

    nonisolated func enqueuePixelBuffer(_ pixelBuffer: CVPixelBuffer, generation: UInt32) {
        guard !presentationPaused.withLock({ $0 }) else { return }
        let view = attached.withLock { $0 }
        view?.enqueuePixelBuffer(pixelBuffer, generation: generation)
    }

    nonisolated func enqueueJPEG(_ image: CGImage) {
        guard !presentationPaused.withLock({ $0 }) else { return }
        let view = attached.withLock { $0 }
        view?.enqueueJPEG(image)
    }

    nonisolated func streamDidReset() {
        let view = attached.withLock { $0 }
        view?.streamDidReset()
    }

    /// Forwards an **upstream** drop — one the decode pipeline made, before the tile ever saw the
    /// frame — to the tile, which counts it and republishes its render state.
    ///
    /// This forward is the difference between a diagnosable failure and a black rectangle. The
    /// pipeline's `.noFormat` reason means parameter sets never arrived, so every frame is being
    /// dropped; `VigilRender` witnesses `didDropFrames` properly, but `DecodePipeline` holds *this*
    /// object as its `any VideoSink`, not the tile. Without these three lines the report stops here
    /// on the protocol's no-op default and the user is shown nothing, told nothing, and finds
    /// nothing in the log — the exact failure mode docs/INTEGRATION-TODO.md item 8 exists to kill.
    nonisolated func didDropFrames(_ count: Int, reason: FrameDropReason) {
        let view = attached.withLock { $0 }
        view?.didDropFrames(count, reason: reason)
    }

    // `willChangeFormat`, `didChangeFormat`, `streamDidEnd`, `didStall` and `didRecover` are the
    // only members left on the default, and each is a default this adapter *means*: the tile learns
    // about a format change from the generation stamped on the next frame, it learns about a stall
    // from its own layer, and holding the last picture after the stream ends is the required
    // behaviour rather than something to react to. Every member that carries a frame, or decides
    // which kind of frame arrives, is forwarded above — that is the lesson of the missing three.
}

#endif  // os(macOS)
