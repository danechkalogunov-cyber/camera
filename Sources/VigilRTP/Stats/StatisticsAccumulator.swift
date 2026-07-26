//
//  StatisticsAccumulator.swift
//  VigilRTP
//
//  The update algebra behind `StreamStatistics`: the fixed EWMA constants, the 500 ms bitrate
//  window, the 2 s loss window and the four-term latency estimate.
//  Implements docs/spec-rtp.md §13, docs/API_CONTRACT.md §3.8 and §2 R-19.
//

import Foundation
import VigilProtocols

/// Maintains one track's `StreamStatistics`.
///
/// `StreamStatistics` lives in `VigilProtocols` because half a dozen modules read it; the algebra
/// lives here because `VigilRTP` is the only writer (API_CONTRACT §2 R-19). The smoothing constants
/// are the ones the shape declares — fps α 0.10, bitrate α 0.25 over a 500 ms window, keyframe
/// interval α 0.20 — and are applied through `StreamStatistics`'s own helpers so there is exactly
/// one implementation of the EWMA step.
///
/// **Jitter and loss fraction are never smoothed here.** RFC 3550 already smooths jitter with its
/// own recurrence, and the loss fraction is defined over a window; smoothing either a second time
/// would hide exactly the bursts an operator is looking for.
public struct StatisticsAccumulator: Sendable {

    // MARK: - Constants

    /// The bitrate integration window.
    public static let bitrateWindow: Duration = .milliseconds(500)

    /// The loss-fraction window, as `StreamStatistics.lossFraction` documents.
    public static let lossWindow: Duration = .seconds(2)

    /// Slowest frame interval that produces a frame-rate sample, in seconds. A gap longer than this
    /// is a stall, and folding `1/10` into the average would show 0.1 fps for ten seconds after a
    /// reconnect.
    public static let maximumFrameInterval = 2.0

    /// Fastest frame interval that produces a sample. Two frames sharing a timestamp would otherwise
    /// read as 10 000 fps.
    public static let minimumFrameInterval = 1.0 / 240.0

    // MARK: - Stored Properties

    /// The statistics as they stand. Read-only to everyone but this type.
    public private(set) var statistics = StreamStatistics()

    /// When the receiver started, for `uptimeSeconds`.
    private let startTime: MediaInstant

    /// Start of the bitrate window in progress.
    private var bitrateWindowStart: MediaInstant

    /// Wire bytes accumulated in the bitrate window in progress.
    private var bitrateWindowBytes = 0

    /// Start of the loss window in progress.
    private var lossWindowStart: MediaInstant

    /// Packets received in the loss window in progress.
    private var lossWindowReceived: UInt64 = 0

    /// Packets declared lost in the loss window in progress.
    private var lossWindowLost: UInt64 = 0

    /// Arrival instant of the previous emitted frame, for the frame-rate sample.
    private var lastFrameInstant: MediaInstant?

    /// Arrival instant of the previous key frame, for the key-frame interval sample.
    private var lastKeyframeInstant: MediaInstant?

    /// Display refresh contribution to the latency estimate, in milliseconds. 60 Hz until
    /// `VigilRender` says otherwise.
    private var displayLatencyMilliseconds = 16.7

    // MARK: - Initialisation

    /// Creates an accumulator whose windows and uptime start at `startTime`.
    public init(startTime: MediaInstant) {
        self.startTime = startTime
        self.bitrateWindowStart = startTime
        self.lossWindowStart = startTime
    }

    // MARK: - Ingest

    /// Counts one successfully parsed RTP packet and its wire bytes.
    ///
    /// Wire bytes, not payload bytes: the operator comparing Vigil's readout against the camera's
    /// configured bitrate needs the number the switch sees.
    public mutating func notePacket(wireBytes: Int) {
        statistics.packetsReceived &+= 1
        bitrateWindowBytes += Swift.max(0, wireBytes)
        lossWindowReceived &+= 1
    }

    /// Folds in one reorder-buffer output's disorder counters.
    public mutating func noteReorder(late: Int, duplicates: Int, reordered: Int) {
        statistics.packetsOutOfOrder &+= UInt64(Swift.max(0, reordered))
        statistics.packetsDuplicated &+= UInt64(Swift.max(0, duplicates))
        // A late packet is one whose slot was already released: it is out of order by definition.
        statistics.packetsOutOfOrder &+= UInt64(Swift.max(0, late))
    }

    /// Counts a declared gap: `packets` sequence numbers across `ranges` distinct runs.
    public mutating func noteLoss(packets: Int, ranges: Int) {
        guard packets > 0 else { return }
        statistics.packetsLost &+= UInt64(packets)
        statistics.gapCount &+= UInt32(Swift.max(0, ranges))
        lossWindowLost &+= UInt64(packets)
    }

    /// Counts one emitted frame and folds its spacing into the frame rate.
    ///
    /// Audio frames do not update the frame rate: `framesPerSecond` is a video figure, and a
    /// 43 frames-per-second AAC track would make it meaningless.
    public mutating func noteFrame(isKeyframe: Bool, isVideo: Bool, at now: MediaInstant) {
        statistics.framesDecoded &+= 1
        if isVideo, let previous = lastFrameInstant {
            let interval = now.seconds(since: previous)
            if interval >= Self.minimumFrameInterval, interval <= Self.maximumFrameInterval {
                statistics.updateFramesPerSecond(sample: 1 / interval)
            }
        }
        if isVideo { lastFrameInstant = now }
        guard isKeyframe else { return }
        if let previous = lastKeyframeInstant {
            let interval = now.seconds(since: previous)
            if interval > 0 { statistics.updateKeyframeInterval(sample: interval) }
        }
        lastKeyframeInstant = now
    }

    /// Counts frames the depacketizer assembled but did not emit.
    public mutating func noteDroppedFrames(_ count: Int) {
        guard count > 0 else { return }
        statistics.framesDroppedPreDecode &+= UInt64(count)
    }

    /// Publishes the exact RFC 3550 jitter estimate. Never smoothed again.
    public mutating func noteJitter(milliseconds: Double) {
        guard milliseconds.isFinite else { return }
        statistics.jitterMilliseconds = milliseconds
    }

    /// Publishes the reorder buffer's current occupancy.
    public mutating func noteBufferDepth(packets: Int, milliseconds: Double) {
        statistics.jitterBufferDepthPackets = packets
        statistics.jitterBufferDepthMilliseconds = milliseconds.isFinite ? milliseconds : 0
    }

    /// Records a reconnect, which the health ring shows as a discontinuity.
    public mutating func noteReconnect() {
        statistics.reconnectCount &+= 1
    }

    /// Records the diagnostic code of the last failure, e.g. `VG-RTSP-0401`. Never a message.
    public mutating func noteErrorCode(_ code: String?) {
        statistics.lastErrorCode = code
    }

    // MARK: - Decode fields, written by VigilVideo

    /// Sets the decode queue depth. The pure layer cannot know it (API_CONTRACT §2 R-19).
    public mutating func setDecodeQueueDepth(_ depth: Int) {
        statistics.decodeQueueDepth = Swift.max(0, depth)
    }

    /// Sets the measured decode timings and whether the decode really is hardware-accelerated.
    public mutating func setDecodeTimings(p50: Double, p99: Double, isHardware: Bool) {
        statistics.decodeMillisecondsP50 = p50.isFinite ? p50 : 0
        statistics.decodeMillisecondsP99 = p99.isFinite ? p99 : 0
        statistics.isHardwareAccelerated = isHardware
    }

    /// Adds to the count of frames dropped after decode but before display.
    public mutating func addDroppedPreDisplay(_ count: UInt64) {
        statistics.framesDroppedPreDisplay &+= count
    }

    /// Sets the display refresh contribution to the latency estimate: 16.7 ms at 60 Hz, 8.3 at 120.
    public mutating func setDisplayLatency(milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        displayLatencyMilliseconds = milliseconds
    }

    // MARK: - Windows

    /// Closes any window that has elapsed and refreshes uptime. Call from `tick`.
    public mutating func tick(_ now: MediaInstant) {
        statistics.uptimeSeconds = Swift.max(0, now.seconds(since: startTime))

        if now >= bitrateWindowStart + Self.bitrateWindow {
            let seconds = now.seconds(since: bitrateWindowStart)
            if seconds > 0 {
                statistics.updateBitsPerSecond(sample: Double(bitrateWindowBytes) * 8 / seconds)
            }
            bitrateWindowBytes = 0
            bitrateWindowStart = now
        }

        if now >= lossWindowStart + Self.lossWindow {
            statistics.updateLossFraction(received: lossWindowReceived, lost: lossWindowLost)
            lossWindowReceived = 0
            lossWindowLost = 0
            lossWindowStart = now
        }
    }

    /// When `tick` next has window work to do.
    public var nextDeadline: MediaInstant {
        Swift.min(bitrateWindowStart + Self.bitrateWindow, lossWindowStart + Self.lossWindow)
    }

    /// Recomputes `estimatedLatencyMilliseconds` from its four terms.
    ///
    /// `buffer + decode queue + capture-to-arrival + display`. The HUD shows the total and, on
    /// hover, the terms — that is how a user tells "the camera's encoder is slow" from "our queue is
    /// deep". `captureToArrivalMilliseconds` comes from `PresentationClock` once it is locked, and
    /// from the min-filtered raw offset before that.
    public mutating func updateLatencyEstimate(captureToArrivalMilliseconds: Double) {
        let queueMilliseconds = statistics.framesPerSecond > 0
            ? Double(statistics.decodeQueueDepth) * 1000 / statistics.framesPerSecond
            : 0
        let capture = captureToArrivalMilliseconds.isFinite
            ? Swift.max(0, captureToArrivalMilliseconds)
            : 0
        statistics.estimatedLatencyMilliseconds =
            statistics.jitterBufferDepthMilliseconds + queueMilliseconds + capture
            + displayLatencyMilliseconds
    }

    /// Clears everything a reconnect invalidates, keeping the monotone counters and the reconnect
    /// count so the session's history is not rewritten.
    public mutating func resetWindows(at now: MediaInstant) {
        bitrateWindowStart = now
        bitrateWindowBytes = 0
        lossWindowStart = now
        lossWindowReceived = 0
        lossWindowLost = 0
        lastFrameInstant = nil
        lastKeyframeInstant = nil
    }
}
