//
//  SampleBufferBackend.swift
//  VigilRender
//
//  The `AVSampleBufferDisplayLayer` ingest path: a lock-protected bridge from `VigilVideo`'s
//  presenter thread to the layer's video renderer, with the flush discipline that keeps the last
//  displayed picture on screen through every interruption.
//  Implements docs/spec-render.md §13.2 and the no-black-flash rule in docs/API_CONTRACT.md §4.9.
//
//  UNCOMPILED AVFoundation code — see the header of VideoTileView.swift.
//

#if os(macOS)

import AVFoundation
import CoreMedia
import Foundation

/// The sample-buffer display path for one tile.
///
/// Deliberately **not** `@MainActor`: `enqueue(_:generation:)` is called from the decode side and
/// must not hop. Deliberately **not** `Sendable` either — it is reached only through a
/// `nonisolated(unsafe) let` on `VideoTileView`, which keeps the repo-wide `@unchecked Sendable`
/// census at the three types docs/API_CONTRACT.md §2 R-52 enumerates. Every stored property is
/// guarded by one `NSLock` that is never held across anything slower than an `enqueue`.
///
/// `NSLock` rather than `OSAllocatedUnfairLock` for the same reason `LatestFrameBox` uses it
/// (R-52, row 3): the lock is taken on VideoToolbox's thread, and spinning on a thread that may be
/// donating priority to the GPU is not acceptable. Contention is effectively zero — one producer,
/// and the main actor only at flush points.
final class SampleBufferBackend {

    // MARK: - Types

    /// Why a flush happened. Every one of these keeps the displayed picture.
    enum FlushReason: String, Sendable {
        /// The stream restarted or the decoder was recreated.
        case streamReset
        /// The sample format changed; queued samples describe the old one.
        case formatChange
        /// `requiresFlushToResumeDecoding` went true after an interruption.
        case resumeDecoding
    }

    /// What one `enqueue` did. `Sendable` so it can be carried to the main actor for publication
    /// without touching the sample buffer.
    struct Outcome: Sendable {
        /// The sample reached the renderer.
        var accepted: Bool
        /// This was the first sample accepted since the last flush — the "video is live again"
        /// edge a status line wants.
        var isFirstSinceFlush: Bool
        /// A flush was performed immediately before this sample, because of a generation change
        /// or a pending resume-decoding request.
        var flushedFirst: Bool
        /// Total accepted since the view was created.
        var totalEnqueued: UInt64
        /// Total refused because the renderer was not ready. Live video drops, it does not queue.
        var totalDroppedNotReady: UInt64
    }

    // MARK: - Stored properties

    private let lock = NSLock()

    /// AVFoundation, macOS 14.0+: `class AVSampleBufferVideoRenderer: NSObject`, obtained from
    /// `AVSampleBufferDisplayLayer.sampleBufferRenderer`. The layer's own `enqueue(_:)` is
    /// deprecated at macOS 14 and is not used.
    private var renderer: AVSampleBufferVideoRenderer?

    private var needsFlushBeforeNextSample = false
    private var lastGeneration: UInt32?
    private var hasDeliveredSinceFlush = false
    private var enqueuedCount: UInt64 = 0
    private var droppedNotReadyCount: UInt64 = 0

    // MARK: - Lifecycle

    /// Takes the renderer belonging to the view's backing layer. Called once, on the main actor,
    /// as soon as `makeBackingLayer()` has run.
    func adopt(_ renderer: AVSampleBufferVideoRenderer) {
        lock.lock()
        self.renderer = renderer
        needsFlushBeforeNextSample = false
        lastGeneration = nil
        hasDeliveredSinceFlush = false
        lock.unlock()
    }

    // MARK: - Ingest

    /// Whether the renderer can take more data right now.
    ///
    /// Backpressure itself is `VigilVideo`'s concern; this only exposes the flag
    /// (docs/spec-render.md §13.2).
    var isReadyForMoreMediaData: Bool {
        lock.lock()
        defer { lock.unlock() }
        // AVFoundation, `AVQueuedSampleBufferRendering`:
        //   `var isReadyForMoreMediaData: Bool { get }`
        return renderer?.isReadyForMoreMediaData ?? false
    }

    /// Hands one sample to the renderer.
    ///
    /// Allocation-free, `O(1)`, and the lock is held only for the duration of the
    /// `enqueue` call itself. A generation change flushes first, because the queued samples carry
    /// the previous format description.
    ///
    /// When the renderer is not ready the sample is **dropped and counted**, not buffered: live
    /// surveillance wants newest-frame-wins, and a growing queue is latency the customer sees.
    ///
    /// - Parameters:
    ///   - sampleBuffer: a ready sample, complete with format description and timing.
    ///   - generation: `VigilVideo`'s format generation counter.
    /// - Returns: what happened, for the caller to publish if it is worth publishing.
    func enqueue(_ sampleBuffer: CMSampleBuffer, generation: UInt32) -> Outcome {
        lock.lock()
        defer { lock.unlock() }

        guard let renderer = self.renderer else {
            return Outcome(accepted: false, isFirstSinceFlush: false, flushedFirst: false,
                           totalEnqueued: enqueuedCount,
                           totalDroppedNotReady: droppedNotReadyCount)
        }

        if lastGeneration != generation {
            lastGeneration = generation
            needsFlushBeforeNextSample = true
        }

        var flushedFirst = false
        if needsFlushBeforeNextSample {
            // AVFoundation, `AVQueuedSampleBufferRendering`: `func flush()`.
            //
            // NEVER `flush(removingDisplayedImage: true, completionHandler:)`. That call blanks the
            // layer, and a blank layer during a reconnect is the black flash the contract forbids
            // (docs/API_CONTRACT.md §4.9). `flush()` discards only the *pending* samples; the
            // picture already on screen stays until a newer one replaces it. No call site in
            // VigilRender removes the displayed image.
            renderer.flush()
            needsFlushBeforeNextSample = false
            hasDeliveredSinceFlush = false
            flushedFirst = true
        }

        guard renderer.isReadyForMoreMediaData else {
            droppedNotReadyCount &+= 1
            return Outcome(accepted: false, isFirstSinceFlush: false, flushedFirst: flushedFirst,
                           totalEnqueued: enqueuedCount,
                           totalDroppedNotReady: droppedNotReadyCount)
        }

        // AVFoundation, `AVQueuedSampleBufferRendering`: `func enqueue(_ sampleBuffer: CMSampleBuffer)`.
        renderer.enqueue(sampleBuffer)
        enqueuedCount &+= 1
        let isFirst = !hasDeliveredSinceFlush
        hasDeliveredSinceFlush = true
        return Outcome(accepted: true, isFirstSinceFlush: isFirst, flushedFirst: flushedFirst,
                       totalEnqueued: enqueuedCount,
                       totalDroppedNotReady: droppedNotReadyCount)
    }

    // MARK: - Flush

    /// Discards everything queued and keeps the displayed picture.
    ///
    /// This is the only flush in the module. It is safe from any thread and is called both from the
    /// main actor (on a `requiresFlushToResumeDecoding` change) and from the ingest side (on a
    /// stream reset).
    ///
    /// - Parameter reason: recorded for the caller's log line; it does not change the behaviour,
    ///   because every reason resolves to the same, picture-preserving, flush.
    func flushKeepingLastImage(reason: FlushReason) {
        lock.lock()
        defer { lock.unlock() }
        hasDeliveredSinceFlush = false
        guard let renderer = self.renderer else {
            // No renderer yet: remember that the next sample must be preceded by a flush, so a
            // reset that arrives before the layer exists is not lost.
            needsFlushBeforeNextSample = true
            return
        }
        renderer.flush()
        needsFlushBeforeNextSample = false
    }
}

#endif
