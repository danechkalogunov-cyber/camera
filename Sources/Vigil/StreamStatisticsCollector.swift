//
//  StreamStatisticsCollector.swift
//  Vigil
//
//  Measures what the window's numeric readouts print: the 1 Hz telemetry sample and its 60-second
//  history for the inspector's Stream tab, the stats badge on the video tile, and the ingest rate
//  the status bar and the sidebar footer report.
//  macOS-only. See docs/UX.md §6.2 (Stream tab), §5.3 (tile readout) and §3.3 (status footer).
//
//  ⛔ NOTHING HERE RECOMPUTES A NUMBER `VigilRTP` ALREADY COMPUTES. `RTPTrackReceiver` owns the
//  smoothing algebra (docs/API_CONTRACT.md §2 R-19) and `StreamController` republishes its
//  `StreamStatistics` once a second as `StreamEvent.statistics`. This file collects those samples
//  into the shapes the panels take. The two figures it does measure itself are the two that arrive
//  structurally zero in the current wiring — see `StreamStatisticsCollector`'s "What is measured
//  here, and why" note. Both defer to the RTP layer's own value the moment that value is non-zero.
//

#if os(macOS)

import Foundation
import os

import VigilCore
import VigilProtocols
import VigilUI

// MARK: - StreamTelemetrySnapshot

/// One published reading: every number the window prints, as a single `Sendable` value.
///
/// A snapshot rather than a live observation, for the same reason `VTileStats` and `VChromeStatus`
/// are snapshots — the readouts update at 1 Hz and a view that subscribed to the media path would
/// put a SwiftUI invalidation on the frame path (UX.md §5.3, §6.2).
///
/// ## Why both a `StreamStatistics` and a bag of optionals
///
/// `StreamStatistics` is a fixed shape of non-optional `Double`s, so it cannot say "not measured";
/// its readers treat zero as absent, which is what `InspectorStat.bitrate(bitsPerSecond:)` and
/// `InspectorStat.latency(milliseconds:)` already do by printing an em dash for a non-positive
/// value. The optionals beside it carry the distinction *honestly*, for the call sites that take an
/// `Optional` — `VTileStats.framesPerSecond`, `VSidebarView(aggregateBitsPerSecond:)` — so a value
/// nobody has measured is never rendered as a healthy zero.
package struct StreamTelemetrySnapshot: Sendable, Hashable {

    // MARK: Inspector

    /// The most recent 1 Hz sample, for `VInspectorState.statistics`.
    ///
    /// Fields the app cannot measure keep their zero default, which the inspector's formatters
    /// already render as `—`.
    package var statistics: StreamStatistics

    /// The samples inside the rolling window, oldest first, for `VInspectorState.recentStatistics`.
    ///
    /// Bounded by both age and slot count, so the sparkline reads a fixed window and this array can
    /// never grow: see ``StreamStatisticsRollup/historyCapacity``.
    package var recentStatistics: [StreamStatistics]

    /// Completed one-minute aggregates, oldest first, bounded to the most recent 24 hours.
    package var minuteStatistics: [StreamMinuteStatistics]

    // MARK: Tile

    /// The tile's top-trailing badge, or `nil` before the stream's format is known — which is what
    /// `VStageCamera(stats:)` takes to mean "draw no readout at all".
    package var tile: VTileStats?

    // MARK: Chrome

    /// The ingest rate for `VStatusBarView`. ``VThroughput/unmeasured`` prints an em dash.
    package var throughput: VThroughput

    /// The same rate unformatted, for `VSidebarView(aggregateBitsPerSecond:)`, which takes a
    /// `Double?` and prints an em dash for `nil`.
    package var bitsPerSecond: Double?

    // MARK: The honest optionals

    /// Presented frame rate, or `nil` before a second of samples exists or during a stall.
    package var framesPerSecond: Double?

    /// Packet loss over the loss window as a fraction `0...1`, or `nil` before a window closed.
    package var lossFraction: Double?

    /// RFC 3550 interarrival jitter in milliseconds, or `nil` before the first packet.
    package var jitterMilliseconds: Double?

    /// Glass-to-glass estimate in milliseconds, or `nil` before the presentation clock has one.
    package var latencyMilliseconds: Double?

    /// Frames waiting to be decoded, or `nil` because nothing has reported one — see
    /// ``StreamStatisticsCollector/noteDecodeQueueDepth(_:)``.
    package var decodeQueueDepth: Int?

    /// Measured GOP length in seconds, or `nil` before two keyframes have been seen.
    package var keyframeIntervalSeconds: Double?

    /// The picture size, or `nil` before the SDP or the decoder reported one.
    package var resolution: FrameDimensions?

    /// How many times the stream has reconnected since the collector was created.
    package var reconnectCount: UInt32

    // MARK: Initialisation

    /// Creates a snapshot. Every field defaults to "nothing measured", which is what a collector
    /// that has seen no events reports.
    package init(statistics: StreamStatistics = StreamStatistics(),
                 recentStatistics: [StreamStatistics] = [],
                 minuteStatistics: [StreamMinuteStatistics] = [],
                 tile: VTileStats? = nil,
                 throughput: VThroughput = .unmeasured,
                 bitsPerSecond: Double? = nil,
                 framesPerSecond: Double? = nil,
                 lossFraction: Double? = nil,
                 jitterMilliseconds: Double? = nil,
                 latencyMilliseconds: Double? = nil,
                 decodeQueueDepth: Int? = nil,
                 keyframeIntervalSeconds: Double? = nil,
                 resolution: FrameDimensions? = nil,
                 reconnectCount: UInt32 = 0) {
        self.statistics = statistics
        self.recentStatistics = recentStatistics
        self.minuteStatistics = minuteStatistics
        self.tile = tile
        self.throughput = throughput
        self.bitsPerSecond = bitsPerSecond
        self.framesPerSecond = framesPerSecond
        self.lossFraction = lossFraction
        self.jitterMilliseconds = jitterMilliseconds
        self.latencyMilliseconds = latencyMilliseconds
        self.decodeQueueDepth = decodeQueueDepth
        self.keyframeIntervalSeconds = keyframeIntervalSeconds
        self.resolution = resolution
        self.reconnectCount = reconnectCount
    }

    /// The reading of a collector that has been told nothing: every readout an em dash.
    package static let unmeasured = StreamTelemetrySnapshot()

    /// Whether anything at all has been measured, for a caller deciding whether to draw the panel.
    package var hasAnyMeasurement: Bool {
        bitsPerSecond != nil || framesPerSecond != nil || jitterMilliseconds != nil
            || !recentStatistics.isEmpty
    }
}

/// One completed minute in the 24-hour diagnostics history.
package struct StreamMinuteStatistics: Sendable, Hashable {
    package var endedAt: MediaInstant
    package var statistics: StreamStatistics
}

// MARK: - StreamStatisticsCollector

/// Turns one stream's events into the numbers the window prints.
///
/// ## Isolation
///
/// A `Sendable` final class over one `OSAllocatedUnfairLock`, exactly as ``TileVideoSink`` is:
/// **the counting happens off the main actor**, on whichever executor delivered the event or the
/// frame, and the main actor reads a `Sendable` value out of it during body evaluation. An actor
/// would have been wrong here — the frame path calls ``noteFrame(byteCount:isKeyframe:at:)``
/// synchronously from `StreamController`'s executor, and `Task { await … }` per frame is one
/// allocation and one unordered hop per access unit.
///
/// Nothing in this type suspends, allocates per packet, or reads a clock: every entry point takes
/// the instant it happened at, so a test drives the whole thing from a literal timeline.
///
/// ## What is measured here, and why
///
/// Two `StreamStatistics` fields arrive **structurally zero** through `StreamEvent.statistics`,
/// because `StatisticsAccumulator` only writes them from `RTPTrackReceiver.tick(_:)` and nothing in
/// `VigilCore` or the app calls `tick`:
///
///  * `bitsPerSecond` — measured here over a rolling window from the access-unit byte counts the
///    frame sink already sees. This is **access-unit** bytes, not RTP wire bytes, so it reads a
///    little low (no RTP header, no interleave framing, no FU-A headers — order 2–4 % at 1400-byte
///    packets). It is published only once a byte has actually been counted.
///  * `lossFraction` — measured here from the deltas of `packetsReceived` / `packetsLost`, which
///    the RTP layer *does* maintain per packet, over the same 2 s window
///    `StatisticsAccumulator.lossWindow` uses. The arithmetic is
///    `StreamStatistics.updateLossFraction(received:lost:)` — the published algebra, not a copy.
///
/// Both defer to the sample's own value the instant it becomes non-zero, so wiring `tick` later
/// silently takes precedence and nothing here has to be removed.
///
/// Three fields cannot be measured from anything the app currently holds and stay `nil` until the
/// decode path reports them: `decodeQueueDepth`, `isHardwareAccelerated` and the decode
/// percentiles. ``noteDecodeQueueDepth(_:)`` and ``noteDecodedFormat(_:isHardwareAccelerated:)``
/// are the doors for them.
///
/// ## Wiring
///
/// ```swift
/// let collector = StreamStatisticsCollector()
///
/// // 1 — events, in AppSessionModel.apply(_:), which already runs per event:
/// collector.ingest(event, at: dependencies.clock.now())
///
/// // 2 — bytes, in the controller's frame sink (AppSessionModel.stream(camera:ref:)):
/// frameSink: { frame in
///     collector.noteFrame(byteCount: frame.data.count,
///                         isKeyframe: frame.isKeyframe,
///                         at: frame.receivedAt)
///     continuation.yield(frame)
/// }
///
/// // 3 — the read, on the main actor at 1 Hz:
/// telemetry = collector.telemetry(at: dependencies.clock.now())
/// ```
///
/// `EncodedFrame.receivedAt` and `CoreDependencies.clock.now()` are the same monotonic timeline —
/// `SystemMonotonicClock` measures from one process-wide epoch — so the two entry points may be
/// mixed freely. Feeding instants from two different clocks would make every window meaningless,
/// which is why every method names the instant rather than reading one.
package final class StreamStatisticsCollector: Sendable {

    // MARK: Stored Properties

    /// The whole mutable state, behind one uncontended lock.
    ///
    /// Held for the duration of a handful of integer additions on the frame path, and for one
    /// array copy on the 1 Hz read path. `OSAllocatedUnfairLock` is `Sendable` and owns its state,
    /// so this type needs neither `@unchecked Sendable` nor `nonisolated(unsafe)`.
    private let state: OSAllocatedUnfairLock<StreamStatisticsRollup>

    // MARK: Initialisation

    /// Creates a collector.
    ///
    /// - Parameters:
    ///   - historyWindow: how far back ``StreamTelemetrySnapshot/recentStatistics`` reaches. The
    ///     default is 60 s, which is what the Stream tab's sparkline header (`LAST 60 S`) claims.
    ///   - lossWindow: the interval loss is averaged over. The default mirrors
    ///     `StatisticsAccumulator.lossWindow`, so a loss figure measured here means the same thing
    ///     as one measured in `VigilRTP`.
    package init(historyWindow: Duration = .seconds(60),
                 lossWindow: Duration = .seconds(2)) {
        state = OSAllocatedUnfairLock(
            initialState: StreamStatisticsRollup(historyWindow: historyWindow,
                                                 lossWindow: lossWindow))
    }

    // MARK: Ingest

    /// Folds one controller event in.
    ///
    /// Safe from any isolation and from the media path. Unknown cases are ignored rather than
    /// asserted on, so a case added to `StreamEvent` later cannot stop this file compiling.
    ///
    /// - Parameters:
    ///   - event: the observation, exactly as `StreamController.events()` produced it.
    ///   - now: when it was received, on the controller's monotonic clock.
    package func ingest(_ event: StreamEvent, at now: MediaInstant) {
        state.withLock { $0.ingest(event, at: now) }
    }

    /// Counts one assembled access unit.
    ///
    /// **This is the per-frame path.** It performs two integer additions and one comparison under
    /// an uncontended lock, and allocates nothing.
    ///
    /// - Parameters:
    ///   - byteCount: `EncodedFrame.data.count` — the access unit's bytes. Negative values are
    ///     ignored rather than trusted.
    ///   - isKeyframe: whether this access unit is an IDR/IRAP, for the keyframe spacing.
    ///   - now: `EncodedFrame.receivedAt`, the arrival of the unit's last packet.
    package func noteFrame(byteCount: Int, isKeyframe: Bool, at now: MediaInstant) {
        state.withLock { $0.noteFrame(byteCount: byteCount, isKeyframe: isKeyframe, at: now) }
    }

    /// Publishes the decode queue's depth in frames.
    ///
    /// Nothing calls this yet, which is exactly why ``StreamTelemetrySnapshot/decodeQueueDepth`` is
    /// an `Optional`: an unreported queue is unknown, not empty, and `InspectorHealth` would grade
    /// a fabricated `0` as a perfectly healthy reading.
    package func noteDecodeQueueDepth(_ depth: Int) {
        state.withLock { $0.decodeQueueDepth = Swift.max(0, depth) }
    }

    /// Adopts the decoder's view of the picture: its real size, and whether the decode is on the
    /// hardware path.
    ///
    /// - Parameters:
    ///   - format: the format the decoder configured itself from. `geometry.displaySize` is used,
    ///     because that is the size after cropping and the pixel aspect ratio — the size a viewer
    ///     sees, and the one the mockup's `1920×1080` refers to.
    ///   - isHardwareAccelerated: the **measured** value from
    ///     `kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder`, never the requested
    ///     one (`StreamStatistics.isHardwareAccelerated` says so, and honesty is a shipping rule).
    package func noteDecodedFormat(_ format: VideoFormatInfo, isHardwareAccelerated: Bool) {
        let size = format.geometry.displaySize
        state.withLock { rollup in
            rollup.adopt(codec: format.codec, width: size.width, height: size.height)
            rollup.isHardwareDecode = isHardwareAccelerated
        }
    }

    /// Closes any window whose interval has elapsed, without an event to hang it on.
    ///
    /// Optional: `StreamEvent.statistics` arrives once a second while the stream is active and does
    /// the same work. Call this from the same 1 Hz timer that reads ``telemetry(at:)`` when the
    /// ingest rate should keep decaying while the controller is silent.
    package func tick(at now: MediaInstant) {
        state.withLock { $0.closeElapsedWindows(at: now) }
    }

    /// Forgets every measurement, as if the collector had just been created. Keeps nothing.
    package func reset(at now: MediaInstant) {
        state.withLock { $0.resetSession(at: now) }
    }

    // MARK: Read

    /// The current reading.
    ///
    /// Non-mutating: it applies the stall rule against `now` and copies the window out. Call it on
    /// the main actor at the same 1 Hz cadence the inspector samples at (UX.md §6.2 makes the
    /// cadence the app's decision, and puts a hard 0.4 ms-per-frame budget on the panel).
    ///
    /// - Parameter now: the instant the reading is for, on the controller's monotonic clock.
    package func telemetry(at now: MediaInstant) -> StreamTelemetrySnapshot {
        state.withLock { $0.telemetry(at: now) }
    }
}

#endif  // os(macOS)
