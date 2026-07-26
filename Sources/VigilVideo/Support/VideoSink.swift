//
//  VideoSink.swift
//  VigilVideo
//
//  The protocol video leaves this module through, and the small enums its callbacks carry.
//  Implements docs/API_CONTRACT.md §4.9 and docs/spec-video-pipeline.md §2.4, reduced to the
//  "first light" slice: the `AVSampleBufferDisplayLayer` path only.
//
//  SLICE DEVIATION (deliberate, see .vigil/SLICE.md): the contract's second requirement
//  `enqueue(_ frame: VideoFrame)` and the `VideoFrame` type itself are **not** declared here.
//  They belong to Strategy B (`VTDecompressionSession` + Metal), which the slice does not build,
//  and declaring a requirement no one can satisfy yet would force `VigilRender` to write a
//  pixel-buffer path it has no decoder for. `Support/VideoFrame.swift` lands with Strategy B.
//

#if os(macOS)

import CoreMedia
import VigilProtocols

// MARK: - Reasons

/// Why a stream stopped producing frames. Purely informational: the sink shows a state, it never
/// decides anything from this.
public enum StreamEndReason: String, Sendable, Hashable, Codable {
    /// `stop()` was called, or the tile was closed.
    case stopped
    /// The transport or the decoder gave up. The error itself went to the pipeline's error handler.
    case failed
    /// The camera's codec/profile cannot be decoded on this machine.
    case formatUnsupported
    /// `DecodeBudget` reclaimed the grant for a higher-priority tile.
    case budgetReleased
    /// The camera closed the RTSP session.
    case peerClosed
}

/// Why frames were dropped. Drives the HUD counters and nothing else.
public enum FrameDropReason: String, Sendable, Hashable, Codable {
    /// The presenter queue was full.
    case queueFull
    /// Decoding cannot resume until an IDR/IRAP arrives.
    case awaitingKeyframe
    /// The access unit was corrupt, truncated or rejected by CoreMedia.
    case badData
    /// The decoder itself discarded the frame.
    case decoderDropped
    /// Dropped during a format change, between `willChangeFormat` and the first new-generation frame.
    case formatChange
    /// No parameter sets have arrived yet, so no format description exists.
    case noFormat
    /// Deliberately not decoded — tile paused, occluded, or below the budget's admission bar.
    case policy
}

/// Whether samples are shown the moment they decode, or paced against a timebase.
///
/// - `live` sets `kCMSampleAttachmentKey_DisplayImmediately` on every sample and creates no
///   timebase. This is the low-latency switch and the only mode the slice uses.
/// - `paced` omits the attachment so a render synchronizer or control timebase governs
///   presentation. Setting `DisplayImmediately` in this mode breaks rate control, seek and reverse
///   (spec-video-pipeline.md §5.3).
public enum PacingMode: String, Sendable, Hashable {
    case live
    case paced
}

// MARK: - VideoSink

/// The one sink protocol (API_CONTRACT §2 R-51). `VigilRender`'s tile view is the only implementer.
///
/// Every member is `nonisolated` on purpose: the tile view is `@MainActor`, and a `@MainActor`
/// member cannot satisfy an isolated requirement called synchronously from the pipeline actor.
/// The calls are synchronous and cross no isolation boundary, so no box is needed for the
/// non-`Sendable` `CMSampleBuffer`.
///
/// Only `enqueue` has no default: a minimal sink is one method.
public protocol VideoSink: AnyObject, Sendable {

    /// Hands over one decoded-ready access unit.
    ///
    /// Must return in under 2 ms and must never block: it is called from the pipeline actor, and
    /// blocking here stalls every stream that actor drives.
    ///
    /// - Parameters:
    ///   - sampleBuffer: One access unit, ready, with its timing and attachments already set.
    ///   - format: The format the sample was built against. Derived from our own SPS parse when
    ///     that succeeded, and from CoreMedia's dimensions when it did not — never `nil`, because a
    ///     parameter set we cannot parse must still decode (API_CONTRACT §2 R-53).
    ///   - generation: Bumps on every parameter-set change. A sink that renders asynchronously
    ///     discards buffers from a stale generation.
    nonisolated func enqueue(_ sampleBuffer: CMSampleBuffer, format: VideoFormatInfo,
                             generation: UInt32)

    /// The format is about to change. **The sink must keep showing its current image**: no black
    /// frame, no `flush(removingDisplayedImage:)`, no resize of the hosting view.
    nonisolated func willChangeFormat(from old: VideoFormatInfo?, to new: VideoFormatInfo,
                                      generation: UInt32)

    /// The new format description is in place and the next `enqueue` carries `generation`.
    nonisolated func didChangeFormat(to new: VideoFormatInfo, generation: UInt32)

    /// The pipeline was reset: everything the sink holds is stale.
    nonisolated func streamDidReset()

    /// No more frames are coming.
    nonisolated func streamDidEnd(reason: StreamEndReason)

    /// `count` frames were dropped for `reason`. Called once per drop decision, not once per frame.
    nonisolated func didDropFrames(_ count: Int, reason: FrameDropReason)

    /// No frame has been enqueued since `since`.
    nonisolated func didStall(since: MediaInstant)

    /// Frames are flowing again after a stall.
    nonisolated func didRecover()
}

// MARK: - Defaults

public extension VideoSink {

    // No-op defaults for every observability member, so a minimal sink implements `enqueue` alone.

    nonisolated func willChangeFormat(from old: VideoFormatInfo?, to new: VideoFormatInfo,
                                      generation: UInt32) {}

    nonisolated func didChangeFormat(to new: VideoFormatInfo, generation: UInt32) {}

    nonisolated func streamDidReset() {}

    nonisolated func streamDidEnd(reason: StreamEndReason) {}

    nonisolated func didDropFrames(_ count: Int, reason: FrameDropReason) {}

    nonisolated func didStall(since: MediaInstant) {}

    nonisolated func didRecover() {}
}

#endif
