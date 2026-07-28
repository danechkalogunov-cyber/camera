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

    /// Current depth and the highest it has reached since the last read.
    private let state = OSAllocatedUnfairLock<(depth: Int, peak: Int)>(initialState: (0, 0))

    /// Creates an empty backlog.
    init() {}

    /// Records a frame entering the stream, and updates the peak.
    func arrived() {
        state.withLock {
            $0.depth &+= 1
            $0.peak = Swift.max($0.peak, $0.depth)
        }
    }

    /// Records a frame handed to the decoder.
    ///
    /// Clamped at zero rather than allowed to go negative: the stream drops its oldest frames when
    /// full, so departures can legitimately be fewer than arrivals and the difference must not
    /// underflow into a huge unsigned-looking depth.
    func departed() {
        state.withLock { $0.depth = Swift.max(0, $0.depth &- 1) }
    }

    /// The current depth in frames.
    func depth() -> Int {
        state.withLock { $0.depth }
    }

    /// The deepest the backlog got since this was last called, and resets the peak.
    ///
    /// **Why the peak and not the instantaneous depth.** At 25 fps a frame arrives every 40 ms and
    /// the loop drains it in far less, so the queue is empty almost all of the time and a 1 Hz
    /// sample of it is a coin flip that lands on zero. The peak answers the question the panel is
    /// actually asking — did the decoder fall behind at any point in the last second — and it reads
    /// zero only when the answer is genuinely no.
    func takePeak() -> Int {
        state.withLock {
            let peak = $0.peak
            $0.peak = $0.depth
            return peak
        }
    }

    /// Forgets the count, for a reconnect.
    func reset() {
        state.withLock { $0 = (0, 0) }
    }
}

#endif  // os(macOS)
