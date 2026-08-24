//
//  StreamStatisticsCollector+Rollup.swift
//  Vigil
//
//  The counting half of `StreamStatisticsCollector`: the rolling windows, the bounded history the
//  Stream tab's sparkline reads, and the fold from one `StreamEvent` into all of it.
//  macOS-only. See docs/UX.md §6.2 and docs/API_CONTRACT.md §3.8 / §2 R-19.
//
//  A plain struct with no clock, no `Task` and no isolation of its own — every entry point names the
//  instant it happened at, so the whole thing replays from a literal timeline in a test. The lock
//  that makes it safe to touch from the media path lives on the collector, not here.
//

#if os(macOS)

import Foundation

import VigilCore
import VigilProtocols
import VigilUI

// MARK: - StreamStatisticsRollup

/// One stream's rolling measurements.
///
/// Everything is bounded: the history by age *and* by slot count, the throughput and loss windows by
/// their own intervals. Nothing in this type allocates on the per-frame path —
/// ``noteFrame(byteCount:isKeyframe:at:)`` performs two integer additions and a comparison.
package struct StreamStatisticsRollup: Sendable {

    // MARK: Constants

    /// The most samples the history holds, whatever the cadence.
    ///
    /// Sixty, because the sparkline's header says `LAST 60 S` and the controller emits
    /// `StreamEvent.statistics` at 1 Hz. It is a hard cap as well as a window: a controller that
    /// emitted faster than once a second must not be able to grow this array without bound.
    package static let historyCapacity = 60

    /// One slot per completed minute for exactly 24 hours.
    package static let minuteHistoryCapacity = 24 * 60

    /// Longest gap between two frames that still counts as a running stream, in seconds.
    ///
    /// Restated rather than imported: this value is `StatisticsAccumulator.maximumFrameInterval`,
    /// and the two must agree, but the app target does not depend on `VigilRTP` and must not start.
    /// Past this the frame rate is reported as unmeasured rather than frozen at its last average —
    /// a stalled stream that keeps printing `25 fps` is exactly the lie the panel exists to avoid.
    package static let stallSeconds = 2.0

    /// A throughput window shorter than this is not closed.
    ///
    /// Two closes in quick succession — a `tick` immediately followed by a `.statistics` event —
    /// would otherwise divide a handful of bytes by a few milliseconds and publish a rate two orders
    /// of magnitude out.
    private static let minimumWindowSeconds = 0.2

    /// How long after the first frame the tile's frame-rate readout stops printing an em dash.
    ///
    /// `VTileStats.framesPerSecond` documents this: "`nil` until a second of samples exists — the
    /// readout shows `—` rather than a wrong number" (UX.md §15.2 step 5).
    private static let framesPerSecondWarmUpSeconds = 1.0

    // MARK: Configuration

    /// How far back the history reaches.
    private let historyWindow: Duration

    /// The interval packet loss is averaged over.
    private let lossWindow: Duration

    // MARK: History

    /// Reconciled samples inside the window, oldest first.
    private var history: [StreamStatistics] = []

    /// When each entry of ``history`` was recorded. Same order, same count, always.
    private var historyInstants: [MediaInstant] = []

    /// Long-lived support history. Unlike the 60-second UI history, reconnects do not clear it.
    private var minuteHistory: [StreamMinuteStatistics] = []
    private var minuteStart: MediaInstant?
    private var minuteAccumulator = MinuteStatisticsAccumulator()

    /// The newest sample exactly as the controller sent it, before this type's overlays.
    private var latestRaw = StreamStatistics()

    // MARK: Throughput window

    /// Start of the throughput window in progress, or `nil` before the first frame or event.
    private var throughputWindowStart: MediaInstant?

    /// Access-unit bytes accumulated in the window in progress. Saturates rather than traps.
    private var throughputWindowBytes = 0

    /// The rate the last closed window produced, or `nil` while nothing has been measured.
    private var measuredBitsPerSecond: Double?

    /// Whether a single byte has ever been counted.
    ///
    /// The gate that keeps a confident zero out of the footer: with no frame sink wired, every
    /// window closes on zero bytes, and publishing `0 bit/s` from that would be a measurement claim
    /// the app cannot support.
    private var hasCountedBytes = false

    // MARK: Loss window

    /// Start of the loss window in progress.
    private var lossWindowStart: MediaInstant?

    /// Packets received inside the loss window in progress.
    private var lossWindowReceived: UInt64 = 0

    /// Packets declared lost inside the loss window in progress.
    private var lossWindowLost: UInt64 = 0

    /// `packetsReceived` at the previous sample, for the delta. `nil` until the first sample.
    private var previousPacketsReceived: UInt64?

    /// `packetsLost` at the previous sample, for the delta.
    private var previousPacketsLost: UInt64?

    /// The fraction the last closed loss window produced, or `nil` while none has closed.
    private var measuredLossFraction: Double?

    // MARK: Frames

    /// `framesDecoded` at the previous sample, so frame arrival is visible from events alone.
    private var previousFramesDecoded: UInt64 = 0

    /// When the first frame of this connection arrived.
    private var firstFrameAt: MediaInstant?

    /// When the most recent frame arrived, for the stall rule.
    private var lastFrameAt: MediaInstant?

    /// When the most recent key frame arrived, for the fallback GOP measurement.
    private var lastKeyframeAt: MediaInstant?

    /// Key-frame spacing measured here, used only when the sample carries none.
    private var measuredKeyframeIntervalSeconds: Double?

    // MARK: Session identity

    /// Frames waiting to be decoded, or `nil` because nothing has reported one.
    package var decodeQueueDepth: Int?

    /// Whether the decode is measurably on the hardware path.
    package var isHardwareDecode = false

    /// The codec as the tile prints it — `H.265`. `nil` until the format resolves.
    private var codecLabel: String?

    /// The picture size, from the SDP or the decoder, whichever spoke last with a real size.
    private var dimensions: FrameDimensions?

    /// How many connect attempts have started. One more than the reconnect count.
    private var attemptCount = 0

    /// The taxonomy raw value of the last failure, e.g. `authenticationFailed`.
    private var lastErrorCode: String?

    // MARK: Initialisation

    /// Creates an empty rollup.
    ///
    /// - Parameters:
    ///   - historyWindow: how far back ``StreamTelemetrySnapshot/recentStatistics`` reaches.
    ///   - lossWindow: the interval loss is averaged over.
    package init(historyWindow: Duration, lossWindow: Duration) {
        self.historyWindow = historyWindow
        self.lossWindow = lossWindow
        // Reserved once, so the 1 Hz append never reallocates for the life of the connection.
        history.reserveCapacity(Self.historyCapacity)
        historyInstants.reserveCapacity(Self.historyCapacity)
        minuteHistory.reserveCapacity(Self.minuteHistoryCapacity)
    }
}

// MARK: - Ingest

extension StreamStatisticsRollup {

    /// Folds one controller event in.
    ///
    /// Six of `StreamEvent`'s thirteen cases carry a measurement; the rest are ignored through the
    /// `default` arm, which is also what keeps a case added later from breaking this file.
    package mutating func ingest(_ event: StreamEvent, at now: MediaInstant) {
        switch event {
        case .connectAttemptStarted:
            beginAttempt(at: now)

        case let .formatResolved(format):
            adopt(format)

        case .firstFrameAssembled:
            if firstFrameAt == nil { firstFrameAt = now }
            lastFrameAt = now

        case let .statistics(sample):
            absorb(sample, at: now)

        case let .stateChanged(_, to, _):
            note(state: to, at: now)

        case let .error(error, _):
            // The taxonomy's raw value, never the message: `StreamError` exposes no `diagnosticCode`
            // of its own, and a sentence in a telemetry field is a sentence in a diagnostics bundle.
            lastErrorCode = error.code.rawValue

        case .ended:
            // Handled exactly like leaving the active states: the rates stop being a claim the app
            // can make, but the codec and the picture size stay, because `restart()` emits `.ended`
            // and a badge that blinked out on every reconnect would read as a fault.
            note(state: .stopped, at: now)

        default:
            break
        }
    }

    /// Counts one assembled access unit. The per-frame path.
    package mutating func noteFrame(byteCount: Int, isKeyframe: Bool, at now: MediaInstant) {
        let bytes = Swift.max(0, byteCount)
        if throughputWindowStart == nil { throughputWindowStart = now }
        // Saturating rather than trapping: this sums a length that came off the network, and an
        // overflow here would take the app down rather than mis-report a rate for one window.
        let (sum, overflowed) = throughputWindowBytes.addingReportingOverflow(bytes)
        throughputWindowBytes = overflowed ? Int.max : sum
        if bytes > 0 { hasCountedBytes = true }
        if firstFrameAt == nil { firstFrameAt = now }
        lastFrameAt = now

        guard isKeyframe else { return }
        if let previous = lastKeyframeAt {
            let interval = now.seconds(since: previous)
            if interval > 0 { measuredKeyframeIntervalSeconds = interval }
        }
        lastKeyframeAt = now
    }

    /// Adopts a codec and a picture size from whichever layer learned them.
    ///
    /// A zero or negative dimension leaves the previous size alone: a Hikvision SDP often carries no
    /// `a=x-dimensions`, and replacing a real size with `0×0` would blank a working readout.
    package mutating func adopt(codec: VideoCodec, width: Int, height: Int) {
        codecLabel = Self.label(for: codec)
        guard width > 0, height > 0 else { return }
        dimensions = FrameDimensions(width: width, height: height)
    }

    /// Adopts the negotiated stream shape.
    mutating func adopt(_ format: StreamFormat) {
        adopt(codec: format.videoCodec,
              width: format.resolution?.width ?? 0,
              height: format.resolution?.height ?? 0)
    }

    /// Starts a new connect attempt, which invalidates every window.
    ///
    /// A reconnect rebuilds the RTP receivers, so the packet counters restart at zero and a rate
    /// averaged across the gap would be a stream and a silence mixed together. The sparkline starts
    /// again with them, which is what `LAST 60 S` of *this* connection means.
    private mutating func beginAttempt(at now: MediaInstant) {
        attemptCount += 1
        resetWindows(at: now)
        history.removeAll(keepingCapacity: true)
        historyInstants.removeAll(keepingCapacity: true)
    }

    /// Reacts to a state change. Only leaving the active states matters here.
    private mutating func note(state: StreamState, at now: MediaInstant) {
        guard !state.isActive else { return }
        // Media has stopped. A rate measured a moment ago is no longer a claim the app can make, so
        // the footer returns to an em dash instead of freezing on the last good number.
        measuredBitsPerSecond = nil
        throughputWindowBytes = 0
        throughputWindowStart = now
        lastFrameAt = nil
    }

    /// Folds one 1 Hz telemetry sample in and appends the reconciled result to the history.
    private mutating func absorb(_ sample: StreamStatistics, at now: MediaInstant) {
        if sample.framesDecoded > previousFramesDecoded {
            // Frames are arriving even when the frame sink is not wired to this collector, so the
            // stall rule and the warm-up both work from events alone.
            if firstFrameAt == nil { firstFrameAt = now }
            lastFrameAt = now
        }
        previousFramesDecoded = sample.framesDecoded

        accumulateLoss(from: sample)
        closeElapsedWindows(at: now)

        latestRaw = sample
        let resolved = reconciled(sample, at: now)
        append(resolved, at: now)
        // ⛔ THE MINUTE ROLLUP AVERAGES THE RAW FRAME-RATE GAUGE, not the live-readout reconciliation.
        // `reconciled` withholds fps for the first second so the on-screen number does not jump while
        // a stream is opening — a display concern that has no place in a 24-hour historical average.
        // Folding that suppressed `0` into the minute dragged a real minute of throughput down: a
        // stream running at 25 fps that happened to start on a minute boundary averaged closer to
        // 12. Bits are already carried through raw here, so fps was the one gauge reading
        // inconsistently low. The counters and the other reconciled fields still come from `resolved`.
        var forHistory = resolved
        forHistory.framesPerSecond = positive(sample.framesPerSecond) ?? 0
        appendMinute(forHistory, at: now)
    }
}

// MARK: - Windows

extension StreamStatisticsRollup {

    /// Closes the throughput and loss windows if their intervals have elapsed.
    package mutating func closeElapsedWindows(at now: MediaInstant) {
        closeThroughputWindow(at: now)
        closeLossWindow(at: now)
    }

    /// Divides the window's bytes by its measured length and starts the next one.
    private mutating func closeThroughputWindow(at now: MediaInstant) {
        guard let start = throughputWindowStart else {
            throughputWindowStart = now
            return
        }
        let seconds = now.seconds(since: start)
        guard seconds >= Self.minimumWindowSeconds else { return }
        if hasCountedBytes {
            // ×8 exactly once, here. `VThroughput.bytesPerSecond(_:)` is the *other* converter and
            // must not also be applied — doubling the conversion is why that factory documents it.
            measuredBitsPerSecond = Double(throughputWindowBytes) * 8 / seconds
        }
        throughputWindowBytes = 0
        throughputWindowStart = now
    }

    /// Publishes the window's loss fraction through the shape's own algebra and starts the next one.
    private mutating func closeLossWindow(at now: MediaInstant) {
        guard let start = lossWindowStart else {
            lossWindowStart = now
            return
        }
        guard now >= start + lossWindow else { return }
        if lossWindowReceived > 0 || lossWindowLost > 0 {
            // `StreamStatistics.updateLossFraction(received:lost:)` is the published implementation
            // (VigilProtocols); it clamps to 0...1 and refuses to divide by an empty window. Reusing
            // it means a fraction measured here means exactly what one measured in `VigilRTP` does.
            var scratch = StreamStatistics()
            scratch.updateLossFraction(received: lossWindowReceived, lost: lossWindowLost)
            measuredLossFraction = scratch.lossFraction
        }
        lossWindowReceived = 0
        lossWindowLost = 0
        lossWindowStart = now
    }

    /// Adds one sample's packet-counter deltas to the loss window in progress.
    private mutating func accumulateLoss(from sample: StreamStatistics) {
        guard let received = previousPacketsReceived,
              let lost = previousPacketsLost,
              sample.packetsReceived >= received,
              sample.packetsLost >= lost
        else {
            // The first sample, or counters that restarted with a new receiver. Re-baseline rather
            // than book a negative delta, which as `UInt64` arithmetic would be an enormous loss.
            previousPacketsReceived = sample.packetsReceived
            previousPacketsLost = sample.packetsLost
            return
        }
        lossWindowReceived &+= sample.packetsReceived - received
        lossWindowLost &+= sample.packetsLost - lost
        previousPacketsReceived = sample.packetsReceived
        previousPacketsLost = sample.packetsLost
    }

    /// Appends one reconciled sample and evicts what has fallen out of the window.
    ///
    /// Age first, because the window is what the header promises; then the slot cap, which is the
    /// allocation guard. Removing from the front of a sixty-element array once a second is cheaper
    /// than the index arithmetic a ring buffer would need on every read — and the read happens at
    /// the same 1 Hz, so a ring would win nothing.
    private mutating func append(_ sample: StreamStatistics, at now: MediaInstant) {
        history.append(sample)
        historyInstants.append(now)

        let cutoff = now - historyWindow
        var stale = 0
        while stale < historyInstants.count, historyInstants[stale] < cutoff { stale += 1 }
        if stale > 0 {
            history.removeFirst(stale)
            historyInstants.removeFirst(stale)
        }
        if history.count > Self.historyCapacity {
            let excess = history.count - Self.historyCapacity
            history.removeFirst(excess)
            historyInstants.removeFirst(excess)
        }
    }

    /// Folds 1 Hz readings into a completed minute and keeps the last 1,440 minutes.
    private mutating func appendMinute(_ sample: StreamStatistics, at now: MediaInstant) {
        guard let start = minuteStart else {
            minuteStart = now
            minuteAccumulator.add(sample)
            return
        }
        if now.seconds(since: start) >= 60 {
            if let aggregate = minuteAccumulator.aggregate {
                minuteHistory.append(StreamMinuteStatistics(endedAt: now, statistics: aggregate))
                if minuteHistory.count > Self.minuteHistoryCapacity {
                    minuteHistory.removeFirst(minuteHistory.count - Self.minuteHistoryCapacity)
                }
            }
            minuteStart = now
            minuteAccumulator = MinuteStatisticsAccumulator()
        }
        minuteAccumulator.add(sample)
    }

    /// Clears every window and every derived figure, keeping the session's identity and counters.
    private mutating func resetWindows(at now: MediaInstant) {
        throughputWindowStart = now
        throughputWindowBytes = 0
        measuredBitsPerSecond = nil
        hasCountedBytes = false

        lossWindowStart = now
        lossWindowReceived = 0
        lossWindowLost = 0
        previousPacketsReceived = nil
        previousPacketsLost = nil
        measuredLossFraction = nil

        previousFramesDecoded = 0
        firstFrameAt = nil
        lastFrameAt = nil
        lastKeyframeAt = nil
        measuredKeyframeIntervalSeconds = nil

        latestRaw = StreamStatistics()
    }

    /// Forgets everything, including the codec, the picture size and the reconnect count.
    package mutating func resetSession(at now: MediaInstant) {
        resetWindows(at: now)
        history.removeAll(keepingCapacity: true)
        historyInstants.removeAll(keepingCapacity: true)
        minuteHistory.removeAll(keepingCapacity: true)
        minuteStart = nil
        minuteAccumulator = MinuteStatisticsAccumulator()
        decodeQueueDepth = nil
        isHardwareDecode = false
        codecLabel = nil
        dimensions = nil
        attemptCount = 0
        lastErrorCode = nil
    }
}

// MARK: - Reading

extension StreamStatisticsRollup {

    /// The current reading. Non-mutating: the stall rule is applied against `now` on the way out.
    package func telemetry(at now: MediaInstant) -> StreamTelemetrySnapshot {
        let bits = positive(resolvedBitsPerSecond(latestRaw))
        let fps = resolvedFramesPerSecond(latestRaw, at: now)
        return StreamTelemetrySnapshot(
            statistics: reconciled(latestRaw, at: now),
            recentStatistics: history,
            minuteStatistics: minuteHistory,
            tile: tileStats(framesPerSecond: fps),
            throughput: VThroughput(bitsPerSecond: bits ?? 0),
            bitsPerSecond: bits,
            framesPerSecond: fps,
            lossFraction: resolvedLossFraction(latestRaw),
            jitterMilliseconds: resolvedJitterMilliseconds(latestRaw),
            latencyMilliseconds: positive(latestRaw.estimatedLatencyMilliseconds),
            decodeQueueDepth: decodeQueueDepth,
            keyframeIntervalSeconds: resolvedKeyframeInterval(latestRaw),
            resolution: dimensions,
            reconnectCount: reconnectCount)
    }

    /// How many times this stream has reconnected: every connect attempt after the first.
    ///
    /// Counted here rather than taken from `StreamStatistics.reconnectCount`, which the controller
    /// fills with its **backoff ladder position** — a number that returns to zero after a minute of
    /// healthy playback and therefore under-reports a stream that keeps dropping.
    package var reconnectCount: UInt32 {
        UInt32(clamping: Swift.max(0, attemptCount - 1))
    }

    /// The sample with this type's own measurements overlaid.
    ///
    /// Fields nothing has measured keep their zero, which every inspector formatter already renders
    /// as an em dash — `InspectorStat.bitrate(bitsPerSecond:)`, `.latency(milliseconds:)` and
    /// `.keyframeInterval(seconds:framesPerSecond:)` all test for a positive value first.
    private func reconciled(_ sample: StreamStatistics, at now: MediaInstant) -> StreamStatistics {
        var out = sample
        out.bitsPerSecond = resolvedBitsPerSecond(sample) ?? 0
        out.lossFraction = resolvedLossFraction(sample) ?? 0
        out.framesPerSecond = resolvedFramesPerSecond(sample, at: now) ?? 0
        out.keyframeIntervalSeconds = resolvedKeyframeInterval(sample) ?? 0
        out.decodeQueueDepth = decodeQueueDepth ?? 0
        out.isHardwareAccelerated = isHardwareDecode
        out.reconnectCount = reconnectCount
        if let lastErrorCode { out.lastErrorCode = lastErrorCode }
        return out
    }

    /// The tile's badge, or `nil` before the codec is known.
    private func tileStats(framesPerSecond: Double?) -> VTileStats? {
        guard let codecLabel else { return nil }
        return VTileStats(codec: codecLabel,
                          dimensions: dimensions,
                          framesPerSecond: framesPerSecond,
                          isHardwareDecode: isHardwareDecode)
    }

    /// The RTP layer's throughput when it has one, otherwise the window measured here.
    private func resolvedBitsPerSecond(_ sample: StreamStatistics) -> Double? {
        if sample.bitsPerSecond.isFinite, sample.bitsPerSecond > 0 { return sample.bitsPerSecond }
        return measuredBitsPerSecond
    }

    /// The RTP layer's loss fraction when it has one, otherwise the window measured here.
    private func resolvedLossFraction(_ sample: StreamStatistics) -> Double? {
        if sample.lossFraction.isFinite, sample.lossFraction > 0 { return sample.lossFraction }
        return measuredLossFraction
    }

    /// The RTP layer's key-frame spacing when it has one, otherwise the spacing measured here.
    private func resolvedKeyframeInterval(_ sample: StreamStatistics) -> Double? {
        let reported = sample.keyframeIntervalSeconds
        if reported.isFinite, reported > 0 { return reported }
        return measuredKeyframeIntervalSeconds
    }

    /// The measured frame rate, or `nil` during the warm-up and during a stall.
    private func resolvedFramesPerSecond(_ sample: StreamStatistics,
                                         at now: MediaInstant) -> Double? {
        guard let firstFrameAt,
              now.seconds(since: firstFrameAt) >= Self.framesPerSecondWarmUpSeconds
        else { return nil }
        guard let lastFrameAt, now.seconds(since: lastFrameAt) <= Self.stallSeconds else {
            return nil
        }
        return positive(sample.framesPerSecond)
    }

    /// Interarrival jitter, or `nil` before a packet has arrived.
    ///
    /// Gated on the packet counter rather than on the value, because a genuinely perfect link
    /// reports exactly zero and that is a reading, not an absence.
    private func resolvedJitterMilliseconds(_ sample: StreamStatistics) -> Double? {
        guard sample.packetsReceived > 0, sample.jitterMilliseconds.isFinite else { return nil }
        return Swift.max(0, sample.jitterMilliseconds)
    }

    /// `value` when it is a finite positive number, otherwise `nil`.
    ///
    /// The one place "not measured" is decided for a bare `Double`. A measured zero and an absent
    /// reading are collapsed deliberately: every consumer prints an em dash for both, and the
    /// alternative is a footer that reads `0.0 Mb/s` on a stream that is merely idle.
    private func positive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    /// The codec name the tile prints. Matches `StreamFormat.summary`'s spelling exactly.
    private static func label(for codec: VideoCodec) -> String {
        switch codec {
        case .h264: return "H.264"
        case .h265: return "H.265"
        case .mjpeg: return "MJPEG"
        }
    }
}

#endif  // os(macOS)
