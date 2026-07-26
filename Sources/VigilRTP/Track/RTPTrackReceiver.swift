//
//  RTPTrackReceiver.swift
//  VigilRTP
//
//  The whole surface `VigilTransport` drives: bytes in, frames + events + outbound RTCP out, plus a
//  deadline to coalesce timers on. Ties the parser, reorder buffer, source state, presentation clock
//  and statistics together around one depacketizer.
//  Implements docs/spec-rtp.md §14.2 and docs/API_CONTRACT.md §4.4 / §5.5
//  (`Track/RTPTrackReceiver.swift`).
//

import Foundation
import VigilProtocols

// MARK: - RTPIngestResult

/// What one ingest or tick produced.
public struct RTPIngestResult: Sendable {

    /// Completed access units, in emission order.
    public var frames: [EncodedFrame] = []

    /// Diagnostics and state changes.
    public var events: [DepacketizerEvent] = []

    /// RTCP payloads to send. Payloads only — `VigilRTSP` adds the `$` interleave framing, on
    /// channel 1 for the first track, channel 3 for the second, and so on.
    public var outboundRTCP: [Data] = []

    /// Packets rejected by the header parser, with the exact reason each was rejected for.
    ///
    /// A documented addition to the contract's shape: the shared `MalformedReason` vocabulary has no
    /// case for an RTP *header* failure, so reporting these as events would mean either inventing a
    /// case in another agent's file or losing the distinction between a truncated packet and a bad
    /// version. `RTPTrackReceiver.parseFailures` carries the same information cumulatively.
    public var parseFailures: [RTPError] = []

    /// Creates an empty result.
    public init() {}

    /// True when nothing at all happened.
    public var isEmpty: Bool {
        frames.isEmpty && events.isEmpty && outboundRTCP.isEmpty && parseFailures.isEmpty
    }
}

// MARK: - RTPParseFailureCounts

/// Cumulative counts of packets the header parser refused, one counter per reason.
///
/// Every one of these is a packet that came off the network and was dropped without being read out
/// of bounds. They are counters rather than errors because one malformed packet in a stream of
/// thousands must never end a session.
public struct RTPParseFailureCounts: Sendable, Hashable {

    /// Packets shorter than the 12-byte fixed header.
    public var shortPacket: UInt64 = 0
    /// Packets whose version field was not 2.
    public var badVersion: UInt64 = 0
    /// Packets whose CSRC count promised more bytes than they contained.
    public var truncatedCSRC: UInt64 = 0
    /// Packets whose header-extension length ran past the end.
    public var truncatedExtension: UInt64 = 0
    /// Packets whose padding byte claimed zero, or more padding than the packet held.
    public var badPadding: UInt64 = 0
    /// Packets carrying a payload type this track did not negotiate.
    public var unexpectedPayloadType: UInt64 = 0
    /// Packets whose payload was empty once padding was removed. Legal, but undepacketizable.
    public var emptyPayload: UInt64 = 0

    /// Creates a zeroed set of counters.
    public init() {}

    /// Every counter added together.
    public var total: UInt64 {
        shortPacket &+ badVersion &+ truncatedCSRC &+ truncatedExtension &+ badPadding
            &+ unexpectedPayloadType &+ emptyPayload
    }

    /// Folds one parse failure in.
    mutating func count(_ error: RTPError) {
        switch error {
        case .shortPacket: shortPacket &+= 1
        case .badVersion: badVersion &+= 1
        case .truncatedCSRC: truncatedCSRC &+= 1
        case .truncatedExtension: truncatedExtension &+= 1
        case .badPaddingLength: badPadding &+= 1
        case .unknownPayloadType: unexpectedPayloadType &+= 1
        default: break
        }
    }
}

// MARK: - RTSPTrackTimingSeed

/// The shape `VigilTransport` copies `RTSPTrackTiming` into, so `VigilRTP` needs no RTSP import.
public struct RTSPTrackTimingSeed: Sendable, Hashable {

    /// The media clock rate the session agreed on.
    public var clockRate: UInt32
    /// The first sequence number the server will send, from `RTP-Info`.
    public var initialSequence: UInt16?
    /// The RTP timestamp of the first packet, from `RTP-Info`. Anchors the first presentation time.
    public var initialRTPTimestamp: UInt32?
    /// Wall-clock start of the range, for recorded playback.
    public var absoluteStart: Date?
    /// Playback rate from the `Scale:` header. 1.0 for live.
    public var scale: Double
    /// True when `Rate-Control: no` was accepted, i.e. the server sends as fast as it can.
    public var isRateControlDisabled: Bool
    /// When the PLAY response arrived, so the seed and the packet stream share a time base.
    public var playResponseInstant: MediaInstant

    /// Creates a seed.
    public init(clockRate: UInt32,
                initialSequence: UInt16? = nil,
                initialRTPTimestamp: UInt32? = nil,
                absoluteStart: Date? = nil,
                scale: Double = 1.0,
                isRateControlDisabled: Bool = false,
                playResponseInstant: MediaInstant) {
        self.clockRate = clockRate
        self.initialSequence = initialSequence
        self.initialRTPTimestamp = initialRTPTimestamp
        self.absoluteStart = absoluteStart
        self.scale = scale
        self.isRateControlDisabled = isRateControlDisabled
        self.playResponseInstant = playResponseInstant
    }
}

// MARK: - RTPWallClockMapping

/// The NTP ⇄ RTP mapping taken from the most recent Sender Report.
///
/// Used for the OSD wall clock, recording file naming and cross-camera synchronisation in the video
/// wall. **Not** used for live pacing.
public struct RTPWallClockMapping: Sendable, Hashable {

    /// The RTP timestamp the Sender Report anchored.
    public var referenceRTPTimestamp: UInt32
    /// The Unix time of that same instant, from the report's NTP fields.
    public var referenceUnixSeconds: Double
    /// The media clock rate, for converting a timestamp difference into seconds.
    public var clockRate: Int32
    /// False when the camera's NTP clock is obviously unset — a time before 2001-09-09. Hikvision
    /// devices with NTP disabled report a time near 1970 or near their own boot; in that case the
    /// OSD clock must come from ISAPI `/ISAPI/System/time` instead.
    public var isPlausible: Bool

    /// Creates a mapping.
    public init(referenceRTPTimestamp: UInt32, referenceUnixSeconds: Double,
                clockRate: Int32, isPlausible: Bool) {
        self.referenceRTPTimestamp = referenceRTPTimestamp
        self.referenceUnixSeconds = referenceUnixSeconds
        self.clockRate = clockRate
        self.isPlausible = isPlausible
    }

    /// The Unix time of an arbitrary RTP timestamp, correct across the 32-bit wrap.
    public func unixSeconds(forRTP timestamp: UInt32) -> Double {
        guard clockRate > 0 else { return referenceUnixSeconds }
        let delta = Int32(bitPattern: timestamp &- referenceRTPTimestamp)
        return referenceUnixSeconds + Double(delta) / Double(clockRate)
    }
}

// MARK: - RTPTrackReceiver

/// One RTP track, end to end: parse, reorder, depacketize, measure, and answer with RTCP.
///
/// A plain value type driven by an owning actor in `VigilTransport`. It reads no clock and draws no
/// randomness of its own — both arrive as arguments — so a failing session replays exactly from a
/// seed and a packet log.
public struct RTPTrackReceiver: Sendable {

    // MARK: - Stored Properties

    /// The negotiated track format.
    public let format: RTPTrackFormat

    /// Cumulative counts of packets the header parser refused.
    public private(set) var parseFailures = RTPParseFailureCounts()

    /// The drift-correcting media→host clock. Not a pacing mechanism (API_CONTRACT §2 R-26).
    public private(set) var presentationClock: PresentationClock

    /// The NTP ⇄ RTP mapping from the most recent Sender Report, once one has arrived.
    public private(set) var wallClockMapping: RTPWallClockMapping?

    /// The CNAME the camera advertised in SDES, when it sent one.
    public private(set) var remoteCNAME: String?

    /// The `TOOL` string the camera advertised in SDES. Some Hikvision models send `Hikvision`.
    public private(set) var remoteTool: String?

    /// The SSRC currently being received, once the first packet has arrived.
    public private(set) var currentSSRC: UInt32?

    /// The codec half of the pipeline.
    private var depacketizer: AnyDepacketizer?

    /// Reorder discipline: `.passthrough` on TCP, the adaptive ring on UDP.
    private var reorder: ReorderBuffer

    /// RFC 3550 A.1 / A.8 state for the source being received.
    private var source: RTPSourceState

    /// Unwraps the 32-bit RTP timestamp for discontinuity detection.
    private var packetTimestamps = TimestampUnwrapper()

    /// Unwraps emitted frames' presentation times for the clock, so a 13-hour wrap is invisible.
    private var frameTimestamps = TimestampUnwrapper()

    /// Unwraps sequence numbers, for the loss window and for diagnostics.
    private var sequences = SequenceUnwrapper()

    /// The statistics algebra.
    private var accumulator: StatisticsAccumulator

    /// Key-frame throttling and the loss window that escalates the reorder depth.
    private var gaps: GapTracker

    /// Outbound RTCP.
    private var reportBuilder: RTCPReportBuilder

    /// When the next report is due.
    private var schedule = RTCPSchedule()

    /// Suppresses repeats of `malformed` and `unsupported` events.
    private var limiter = EventRateLimiter()

    /// Injected randomness for the SSRC and the RTCP interval.
    private var random: any RandomSource

    /// When this receiver started, for uptime and for the first RTCP interval.
    private let startTime: MediaInstant

    /// Latency preset, which governs the idle access-unit flush and the decode-queue term.
    private let latency: LatencyPreset

    /// Arrival instant of the most recent packet, for the idle flush.
    private var lastPacketInstant: MediaInstant?

    /// True once the idle flush has fired, so it fires once per idle period rather than per tick.
    private var hasFlushedWhileIdle = false

    /// The `RTP-Info` seed from the PLAY response, when the session supplied one.
    private var timingSeed: RTSPTrackTimingSeed?

    /// Ticks that count as a discontinuity rather than a wrap: ten seconds of media.
    private let discontinuityThresholdTicks: Int64

    // MARK: - Initialisation

    /// Creates a receiver for one track.
    ///
    /// - Parameters:
    ///   - format: the negotiated format. One receiver serves exactly one payload type.
    ///   - reorderMode: `.passthrough` for RTSP interleaved over TCP — the transport has already
    ///     ordered the stream, so buffering would spend latency on a solved problem — and
    ///     `.adaptive` for UDP, which starts at 128 packets / 60 ms.
    ///   - latency: governs the idle access-unit flush and the decode-queue term of the latency
    ///     estimate. It deliberately does **not** override the contract-fixed UDP reorder depth.
    ///   - cname: the RTCP canonical name, stable for the whole session.
    ///   - startTime: the instant the session started, for uptime and the first RTCP interval.
    ///   - depacketizer: an explicit depacketizer. When `nil`, one is built from `format`.
    ///   - gapPolicy: key-frame throttling and loss-escalation thresholds.
    ///   - configuration: depacketizer limits and the marker-bit policy.
    ///   - randomSource: injected randomness. Seed it in tests; the production default is the
    ///     system generator.
    ///   - clockTuning: presentation-clock loop constants.
    /// - Throws: `RTPError.unsupportedEncoding` when no depacketizer was supplied and none can be
    ///   built for `format.codec`.
    public init(format: RTPTrackFormat,
                reorderMode: ReorderBuffer.Mode,
                latency: LatencyPreset,
                cname: String,
                startTime: MediaInstant,
                depacketizer: AnyDepacketizer? = nil,
                gapPolicy: GapPolicy = .live,
                configuration: DepacketizerConfiguration = .liveDefault,
                randomSource: any RandomSource = SystemRandomSource(),
                clockTuning: PresentationClock.Tuning = .live) throws(RTPError) {
        self.format = format
        self.latency = latency
        self.startTime = startTime
        self.reorder = reorderMode == .passthrough ? .tcpInterleaved : .udpLive
        self.source = RTPSourceState(clockRate: format.clockRate)
        self.accumulator = StatisticsAccumulator(startTime: startTime)
        self.gaps = GapTracker(policy: gapPolicy, startTime: startTime)
        self.presentationClock = PresentationClock(tuning: clockTuning)
        self.discontinuityThresholdTicks = Int64(format.clockRate) * 10
        var generator = randomSource
        self.reportBuilder = RTCPReportBuilder(cname: cname, random: &generator)
        self.random = generator
        if let depacketizer {
            self.depacketizer = depacketizer
        } else {
            self.depacketizer = try DepacketizerFactory.make(for: format,
                                                             configuration: configuration)
        }
    }

    // MARK: - Computed Properties

    /// This track's telemetry.
    public var statistics: StreamStatistics { accumulator.statistics }

    /// Our own RTCP synchronisation source.
    public var ourSSRC: UInt32 { reportBuilder.ourSSRC }

    /// Packets currently held by the reorder buffer. Always 0 on `.passthrough`.
    public var reorderDepth: Int { reorder.depth }

    /// The earliest instant at which `tick` has something to do, so the transport can arm one
    /// coalesced timer for every track it owns.
    public var nextDeadline: MediaInstant? {
        var earliest = accumulator.nextDeadline
        if let bufferDeadline = reorder.nextDeadline {
            earliest = Swift.min(earliest, bufferDeadline)
        }
        if let rtcpDeadline = schedule.nextDeadline {
            earliest = Swift.min(earliest, rtcpDeadline)
        }
        if let last = lastPacketInstant, !hasFlushedWhileIdle {
            earliest = Swift.min(earliest, last + idleFlushInterval)
        }
        return earliest
    }

    /// How long an access unit may sit idle before it is force-closed.
    private var idleFlushInterval: Duration {
        switch latency {
        case .low: .milliseconds(120)
        case .balanced: .milliseconds(200)
        case .quality: .milliseconds(400)
        }
    }

    // MARK: - RTP ingest

    /// Parses, orders, depacketizes and measures one RTP packet.
    ///
    /// Never throws. A packet that fails to parse is counted in `parseFailures`, reported in the
    /// result's `parseFailures`, and dropped; the stream continues.
    ///
    /// - Parameters:
    ///   - bytes: one complete RTP packet with no interleave framing.
    ///   - now: its arrival instant.
    public mutating func ingestRTP(_ bytes: Data, at now: MediaInstant) -> RTPIngestResult {
        var result = RTPIngestResult()
        let packet: RTPPacket
        do {
            packet = try RTPPacket.parse(bytes)
        } catch {
            parseFailures.count(error)
            result.parseFailures.append(error)
            if case .truncatedExtension = error {
                emitLimited(.malformedExtension, at: now, into: &result)
            }
            return result
        }

        guard packet.payloadType == format.payloadType else {
            let error = RTPError.unknownPayloadType(packet.payloadType)
            parseFailures.count(error)
            result.parseFailures.append(error)
            emitLimited(.unexpectedPayloadType, at: now, into: &result)
            return result
        }

        lastPacketInstant = now
        hasFlushedWhileIdle = false
        adoptSSRC(packet, at: now, into: &result)

        accumulator.notePacket(wireBytes: bytes.count)
        source.update(sequence: packet.sequenceNumber)
        source.updateJitter(rtpTimestamp: packet.timestamp,
                            arrivalRTP: source.arrivalInRTPUnits(now))
        accumulator.noteJitter(milliseconds: source.jitterMilliseconds)
        _ = sequences.extend(packet.sequenceNumber)

        let released = reorder.push(packet, at: now)
        absorb(released, at: now, into: &result)
        publishBufferDepth(at: now)
        return result
    }

    // MARK: - RTCP ingest

    /// Parses one compound RTCP packet and folds it into the receiver's state.
    ///
    /// Handles SR, RR, SDES and BYE; anything else is skipped by its declared length. RTCP is **not**
    /// a keepalive — `GET_PARAMETER` is — so nothing here refreshes a session timer.
    public mutating func ingestRTCP(_ bytes: Data, at now: MediaInstant) -> RTPIngestResult {
        var result = RTPIngestResult()
        let parsed = RTCPParser.parse(bytes)
        if parsed.isMisaligned { emitLimited(.rtcpMisaligned, at: now, into: &result) }

        for packet in parsed.packets {
            switch packet {
            case .senderReport(let report):
                source.noteSenderReport(report, at: now)
                // The newest report wins outright: a camera's NTP clock steps when it syncs, so
                // smoothing across reports would average across a discontinuity.
                wallClockMapping = RTPWallClockMapping(
                    referenceRTPTimestamp: report.rtpTimestamp,
                    referenceUnixSeconds: report.unixSeconds,
                    clockRate: format.clockRate,
                    isPlausible: report.isPlausibleWallClock)
                result.events.append(.senderReport(report))
            case .sourceDescription(let description):
                for chunk in description.chunks {
                    for item in chunk.items {
                        switch item.type {
                        case .cname: remoteCNAME = item.text
                        case .tool: remoteTool = item.text
                        default: break
                        }
                    }
                }
            case .goodbye(let goodbye):
                let isOurs = goodbye.sources.isEmpty || currentSSRC == nil
                    || goodbye.sources.contains { $0 == currentSSRC }
                guard isOurs else { break }
                result.events.append(.bye(reason: goodbye.reason))
                // A BYE is the end of the stream, so anything still held is emitted now rather
                // than waiting for a timer that will never see another packet.
                let flushed = flush(at: now)
                result.frames += flushed.frames
                result.events += flushed.events
            case .receiverReport, .unhandled:
                break
            }
        }
        return result
    }

    // MARK: - Timer-driven work

    /// Buffer drain, idle access-unit flush, statistics windows, depth policy and RTCP generation.
    ///
    /// Call whenever `nextDeadline` has passed. Cheap to call more often; it does nothing that is
    /// not due.
    public mutating func tick(_ now: MediaInstant) -> RTPIngestResult {
        var result = RTPIngestResult()

        let drained = reorder.drain(at: now)
        absorb(drained, at: now, into: &result)

        if let last = lastPacketInstant, !hasFlushedWhileIdle, now >= last + idleFlushInterval {
            hasFlushedWhileIdle = true
            let frames = flushDepacketizer(at: now)
            noteFrames(frames, at: now)
            result.frames += frames
        }

        switch gaps.evaluateDepth(at: now) {
        case .escalate:
            if reorder.escalate() {
                result.events.append(.jitterPolicyEscalated(reorder.mode))
            }
        case .relax:
            if reorder.relax() {
                result.events.append(.jitterPolicyEscalated(reorder.mode))
            }
        case .unchanged:
            break
        }

        accumulator.tick(now)
        publishBufferDepth(at: now)

        if schedule.isDue(at: now) {
            result.outboundRTCP.append(reportBuilder.makeCompoundReport(source: &source, at: now))
            schedule.schedule(after: now, random: &random)
        }
        return result
    }

    /// Releases everything held: the reorder buffer's contents, every hole between them, and any
    /// access unit the depacketizer still has open. Used on PAUSE and TEARDOWN.
    public mutating func flush(at now: MediaInstant) -> RTPIngestResult {
        var result = RTPIngestResult()
        let drained = reorder.drain(at: now, force: true)
        absorb(drained, at: now, into: &result)
        let frames = flushDepacketizer(at: now)
        noteFrames(frames, at: now)
        result.frames += frames
        publishBufferDepth(at: now)
        return result
    }

    /// Full reset for a reconnect or a seek. Monotone statistics counters survive; every piece of
    /// per-stream state does not.
    public mutating func reset(at now: MediaInstant) {
        depacketizer?.reset()
        reorder.reset()
        source = RTPSourceState(clockRate: format.clockRate)
        packetTimestamps.reset()
        frameTimestamps.reset()
        sequences.reset()
        presentationClock.reset()
        gaps.reset(at: now)
        limiter.reset()
        schedule.reset()
        accumulator.resetWindows(at: now)
        accumulator.noteReconnect()
        currentSSRC = nil
        wallClockMapping = nil
        lastPacketInstant = nil
        hasFlushedWhileIdle = false
    }

    // MARK: - Session seeding

    /// Seeds `RTP-Info` from the PLAY response, so the first presentation time is anchored to what
    /// the server promised rather than to whichever packet happened to arrive first.
    ///
    /// Safe to call before or after the first packet: a seed arriving late re-bases the origin
    /// without disturbing the cycle count.
    public mutating func seed(_ timing: RTSPTrackTimingSeed) {
        timingSeed = timing
        guard let initial = timing.initialRTPTimestamp else { return }
        if packetTimestamps.hasOrigin {
            packetTimestamps.rebase(origin: initial)
        } else {
            packetTimestamps = TimestampUnwrapper(origin: initial)
        }
    }

    // MARK: - Fields written by VigilVideo

    /// Sets the decode queue depth measured by `VigilVideo` (API_CONTRACT §2 R-19).
    public mutating func updateDecodeQueueDepth(_ depth: Int) {
        accumulator.setDecodeQueueDepth(depth)
    }

    /// Sets the measured decode timings and whether hardware decode really was used.
    public mutating func updateDecodeTimings(p50: Double, p99: Double, isHardware: Bool) {
        accumulator.setDecodeTimings(p50: p50, p99: p99, isHardware: isHardware)
    }

    /// Adds to the count of frames dropped after decode and before display.
    public mutating func countDroppedPreDisplay(_ n: UInt64) {
        accumulator.addDroppedPreDisplay(n)
    }

    /// Sets the display refresh contribution to the latency estimate: 16.7 ms at 60 Hz, 8.3 at 120.
    public mutating func updateDisplayLatency(milliseconds: Double) {
        accumulator.setDisplayLatency(milliseconds: milliseconds)
    }

    // MARK: - Private: SSRC

    /// Adopts the packet's SSRC, resetting everything stateful when it changed.
    ///
    /// Hikvision NVRs change SSRC when a shared session switches channel and after an internal
    /// encoder restart. Treating that as loss instead of a reset produces a permanently broken
    /// stream, which is why every unwrapper, the gate and the clock all restart here.
    private mutating func adoptSSRC(_ packet: RTPPacket, at now: MediaInstant,
                                    into result: inout RTPIngestResult) {
        if packet.ssrc == reportBuilder.ourSSRC {
            // RFC 3550 §8.2: a source using our SSRC means we must pick another.
            reportBuilder.regenerateSSRC(random: &random)
        }
        guard let current = currentSSRC else {
            currentSSRC = packet.ssrc
            source.restart(ssrc: packet.ssrc, sequence: packet.sequenceNumber)
            return
        }
        guard current != packet.ssrc else { return }
        result.events.append(.ssrcChanged(old: current, new: packet.ssrc))
        depacketizer?.reset()
        reorder.reset()
        packetTimestamps.reset()
        frameTimestamps.reset()
        sequences.reset()
        presentationClock.reset()
        limiter.reset()
        gaps.reset(at: now)
        source.restart(ssrc: packet.ssrc, sequence: packet.sequenceNumber)
        currentSSRC = packet.ssrc
    }

    // MARK: - Private: reorder output

    /// Folds one reorder-buffer output into statistics, events and frames.
    private mutating func absorb(_ output: ReorderBuffer.Output, at now: MediaInstant,
                                 into result: inout RTPIngestResult) {
        accumulator.noteReorder(late: output.late, duplicates: output.duplicates,
                                reordered: output.reordered)
        if !output.gaps.isEmpty {
            let lost = output.lostCount
            accumulator.noteLoss(packets: lost, ranges: output.gaps.count)
            for range in output.gaps {
                let count = Int(range.upperBound - range.lowerBound) + 1
                result.events.append(.packetLoss(range: range, count: count))
            }
            if gaps.shouldRequestKeyframe(at: now) {
                result.events.append(.keyframeNeeded(reason: .packetLoss))
            }
        }
        gaps.note(received: output.packets.count, lost: output.lostCount)

        for packet in output.packets {
            deliver(packet, at: now, into: &result)
        }
    }

    /// Hands one in-order packet to the depacketizer, after the checks that belong to this half.
    private mutating func deliver(_ packet: RTPPacket, at now: MediaInstant,
                                  into result: inout RTPIngestResult) {
        if packetTimestamps.isDiscontinuity(packet.timestamp,
                                            thresholdTicks: discontinuityThresholdTicks) {
            let ticks = Double(packetTimestamps.delta(to: packet.timestamp))
            let seconds = format.clockRate > 0 ? ticks / Double(format.clockRate) : 0
            result.events.append(.timestampDiscontinuity(seconds: seconds))
            presentationClock.reset()
        }
        _ = packetTimestamps.extend(packet.timestamp)

        guard !packet.payload.isEmpty else {
            // Legal on the wire, so it is not a parse failure — but there is nothing to
            // depacketize, and a depacketizer must not be handed a zero-length payload.
            parseFailures.emptyPayload &+= 1
            emitLimited(.emptyPayload, at: now, into: &result)
            return
        }

        let output = pushToDepacketizer(packet, at: now)
        noteFrames(output.frames, at: now)
        result.frames += output.frames
        result.events += output.events
    }

    /// Pushes into the depacketizer without copying it.
    ///
    /// Binding `d` and then clearing `self.depacketizer` leaves `d` uniquely referenced *before*
    /// `push` mutates it, so no copy-on-write allocation happens on the per-packet path.
    private mutating func pushToDepacketizer(_ packet: RTPPacket,
                                             at now: MediaInstant) -> DepacketizerOutput {
        guard var d = depacketizer else { return .none }
        depacketizer = nil
        let output = d.push(packet, at: now)
        depacketizer = d
        return output
    }

    /// Flushes the depacketizer without copying it, for the same reason.
    private mutating func flushDepacketizer(at now: MediaInstant) -> [EncodedFrame] {
        guard var d = depacketizer else { return [] }
        depacketizer = nil
        let frames = d.flush(at: now)
        depacketizer = d
        return frames
    }

    // MARK: - Private: frames

    /// Folds emitted frames into the statistics and the presentation clock.
    private mutating func noteFrames(_ frames: [EncodedFrame], at now: MediaInstant) {
        for frame in frames {
            accumulator.noteFrame(isKeyframe: frame.isKeyframe,
                                  isVideo: frame.codec.isVideo, at: now)
            observeClock(frame, at: now)
        }
    }

    /// Feeds one frame's presentation time to the clock.
    ///
    /// The frame's own `pts` is re-unwrapped here rather than used directly, so a 32-bit media clock
    /// that wraps after ~13 h at 90 kHz produces a monotone input instead of a step the loop would
    /// read as a discontinuity.
    private mutating func observeClock(_ frame: EncodedFrame, at now: MediaInstant) {
        let timescale = frame.pts.timescale > 0 ? frame.pts.timescale : format.clockRate
        guard timescale > 0, frame.pts.isValid else { return }
        let wrapped = UInt32(truncatingIfNeeded: frame.pts.value)
        let extended = frameTimestamps.extend(wrapped)
        let mediaSeconds = Double(extended) / Double(timescale)
        presentationClock.observe(mediaSeconds: mediaSeconds, at: now)
        let capture = presentationClock.latencySeconds(forMedia: mediaSeconds, at: now) * 1000
        accumulator.updateLatencyEstimate(captureToArrivalMilliseconds: capture)
    }

    // MARK: - Private: reporting

    /// Publishes the reorder buffer's occupancy into the statistics.
    private mutating func publishBufferDepth(at now: MediaInstant) {
        accumulator.noteBufferDepth(packets: reorder.depth,
                                    milliseconds: reorder.bufferedMilliseconds(at: now))
    }

    /// Emits a `malformed` event at most once per reason per five seconds.
    private mutating func emitLimited(_ reason: MalformedReason, at now: MediaInstant,
                                      into result: inout RTPIngestResult) {
        guard limiter.admit(reason.limiterKey, at: now) else { return }
        result.events.append(.malformed(reason))
    }
}
