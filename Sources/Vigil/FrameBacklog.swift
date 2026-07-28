//
//  FrameBacklog.swift
//  Vigil
//
//  Counts the encoded frames sitting between the network and the decoder, so the inspector's
//  "decode queue" is a measurement instead of a zero.
//  macOS-only. See docs/API_CONTRACT.md §2 R-19.
//

#if os(macOS)

import os

// MARK: - FrameBacklog

/// How many assembled access units have arrived but not yet reached the decoder.
///
/// **Why this exists.** `StatisticsAccumulator.setDecodeQueueDepth(_:)` carries the comment "written
/// by `VigilVideo`… the pure layer cannot know it", and nothing ever called it — so the field
/// travelled to the panel as a hard `0`, which `InspectorHealth` grades as a perfectly healthy
/// reading. A fabricated zero is worse than a dash, because it looks like an answer.
///
/// **What the number means.** `DecodePipeline.submit(_:)` has no queue of its own; it hands a sample
/// buffer straight to the sink. The real backlog is the `AsyncStream` between `frameSink` and the
/// detached decode loop — bounded at 64 by `.bufferingNewest`. This counts arrivals against
/// departures, so the value is exactly the number of frames waiting in that stream.
///
/// A depth that sits at zero now means the decoder is keeping up. A depth that climbs means it is
/// not, and the number reaching 64 means frames are being dropped — which is the reading the Stream
/// tab exists to surface.
///
/// `Sendable` and lock-guarded because both ends run off the main actor: `frameSink` is called from
/// the controller's actor and the loop is `Task.detached`. Each end costs one uncontended lock and
/// one integer operation, which is what the per-frame path can afford.
final class FrameBacklog: Sendable {

    private let depthValue = OSAllocatedUnfairLock<Int>(initialState: 0)

    /// Creates an empty backlog.
    init() {}

    /// Records a frame entering the stream.
    func arrived() {
        depthValue.withLock { $0 &+= 1 }
    }

    /// Records a frame handed to the decoder.
    ///
    /// Clamped at zero rather than allowed to go negative: the stream drops its oldest frames when
    /// full, so departures can legitimately be fewer than arrivals and the difference must not
    /// underflow into a huge unsigned-looking depth.
    func departed() {
        depthValue.withLock { $0 = Swift.max(0, $0 &- 1) }
    }

    /// The current depth in frames.
    func depth() -> Int {
        depthValue.withLock { $0 }
    }

    /// Forgets the count, for a reconnect.
    func reset() {
        depthValue.withLock { $0 = 0 }
    }
}

#endif  // os(macOS)
