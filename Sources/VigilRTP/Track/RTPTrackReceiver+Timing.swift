//
//  RTPTrackReceiver+Timing.swift
//  VigilRTP
//
//  Timer-driven work, session seeding, the fields VigilVideo writes, and SSRC tracking.
//  Split from RTPTrackReceiver.swift, which docs/API_CONTRACT.md §7.2 caps at 600 lines.
//

import Foundation
import VigilProtocols

// MARK: - Timers, seeding and SSRC

/// ⚠️ Members are `internal`, not `private`: Swift scopes `private` to one file.
/// `Scripts/lint.py`'s `split-access` rule fails the build on any left behind.
extension RTPTrackReceiver {

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
