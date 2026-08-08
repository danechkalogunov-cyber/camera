//
//  StreamStatisticsCollectorTests.swift
//  VigilAppTests
//
//  Every number the window prints about a stream, and — more importantly — every number it refuses
//  to print.
//
//  ⛔ THE RULE THIS FILE EXISTS FOR IS "UNMEASURED IS NOT ZERO". `StreamStatistics` is a fixed shape
//  of non-optional `Double`s, so it cannot say "nobody has measured this"; the collector carries the
//  distinction in optionals beside it, and every one of those optionals is a place where a
//  fabricated zero would render as a perfectly healthy reading. A footer showing `0.0 Mb/s` on a
//  stream nobody has measured, or `InspectorHealth` grading an invented empty decode queue as green,
//  is the "no data, no error" failure this project refuses — and it is invisible, because a zero
//  looks like a measurement.
//
//  ⚠️ 855 lines of arithmetic with no tests at all until now, and it is the arithmetic behind the
//  inspector, the tile badge and the status footer.
//

#if os(macOS)

import Foundation
import Testing

@testable import Vigil
import VigilCore
import VigilProtocols
import VigilUI

@Suite("Stream statistics collector")
struct StreamStatisticsCollectorTests {

    // MARK: - Fixtures

    private func at(_ seconds: Double) -> MediaInstant {
        MediaInstant(nanoseconds: Int64(seconds * 1_000_000_000))
    }

    /// A negotiated format. `StreamFormat` has four arguments with no defaults, so the fixture
    /// carries them and each test names only the codec and the size it cares about.
    private func format(_ codec: VideoCodec, width: Int = 0, height: Int = 0) -> StreamFormat {
        StreamFormat(
            videoCodec: codec,
            resolution: width > 0 ? Resolution(width: width, height: height) : nil,
            quality: .main,
            transport: .tcpInterleaved,
            path: "/Streaming/Channels/101",
            clockRate: 90_000)
    }

    /// A 1 Hz sample from the RTP layer, with only the fields a test names filled in.
    private func sample(
        framesDecoded: UInt64 = 0,
        framesPerSecond: Double = 0,
        bitsPerSecond: Double = 0,
        packetsReceived: UInt64 = 0,
        packetsLost: UInt64 = 0,
        lossFraction: Double = 0,
        jitterMilliseconds: Double = 0
    ) -> StreamStatistics {
        var stats = StreamStatistics()
        stats.framesDecoded = framesDecoded
        stats.framesPerSecond = framesPerSecond
        stats.bitsPerSecond = bitsPerSecond
        stats.packetsReceived = packetsReceived
        stats.packetsLost = packetsLost
        stats.lossFraction = lossFraction
        stats.jitterMilliseconds = jitterMilliseconds
        return stats
    }

    // MARK: - Nothing measured

    /// ⛔ A fresh collector reports absence, not zero, on every optional. This is the whole contract
    /// in one test: an em dash everywhere, and no tile badge at all.
    @Test func aFreshCollectorMeasuresNothing() {
        let collector = StreamStatisticsCollector()

        let reading = collector.telemetry(at: at(0))

        #expect(reading.bitsPerSecond == nil)
        #expect(reading.framesPerSecond == nil)
        #expect(reading.lossFraction == nil)
        #expect(reading.jitterMilliseconds == nil)
        #expect(reading.latencyMilliseconds == nil)
        #expect(reading.decodeQueueDepth == nil)
        #expect(reading.keyframeIntervalSeconds == nil)
        #expect(reading.resolution == nil)
        #expect(reading.tile == nil, "no codec yet, so the tile draws no readout at all")
        #expect(reading.recentStatistics.isEmpty)
    }

    /// ⚠️ An unreported decode queue is unknown, not empty. Nothing calls `noteDecodeQueueDepth`
    /// yet, and a fabricated `0` would be graded by `InspectorHealth` as a perfectly healthy queue.
    @Test func anUnreportedQueueIsUnknownRatherThanEmpty() {
        let collector = StreamStatisticsCollector()
        #expect(collector.telemetry(at: at(0)).decodeQueueDepth == nil)

        collector.noteDecodeQueueDepth(0)

        #expect(collector.telemetry(at: at(0)).decodeQueueDepth == 0, "now it is a measured zero")
    }

    /// A negative depth is not a reading. Clamped rather than trusted.
    @Test func aNegativeQueueDepthIsClamped() {
        let collector = StreamStatisticsCollector()

        collector.noteDecodeQueueDepth(-4)

        #expect(collector.telemetry(at: at(0)).decodeQueueDepth == 0)
    }

    // MARK: - Throughput

    /// Bytes become bits exactly once, here — `VThroughput.bytesPerSecond(_:)` is the other
    /// converter and applying both is a rate that reads eight times too high.
    @Test func throughputIsBytesTimesEightOverTheWindow() {
        let collector = StreamStatisticsCollector()

        collector.noteFrame(byteCount: 125_000, isKeyframe: true, at: at(0))
        collector.noteFrame(byteCount: 125_000, isKeyframe: false, at: at(0.5))
        collector.tick(at: at(1))

        let bits = collector.telemetry(at: at(1)).bitsPerSecond
        #expect(bits == 2_000_000, "250 000 bytes in one second is 2 Mb/s")
    }

    /// ⚠️ A window shorter than the minimum is not closed, because dividing a handful of bytes by a
    /// few milliseconds produces a spike the user would see as a fault.
    @Test func aTooShortWindowIsNotPublished() {
        let collector = StreamStatisticsCollector()

        collector.noteFrame(byteCount: 100_000, isKeyframe: true, at: at(0))
        collector.tick(at: at(0.05))

        #expect(collector.telemetry(at: at(0.05)).bitsPerSecond == nil)
    }

    /// ⛔ When the stream stops, the footer returns to an em dash rather than freezing on the last
    /// good number. A rate measured a moment ago is not a claim the app can still make.
    @Test func stoppingClearsTheRateRatherThanFreezingIt() {
        let collector = StreamStatisticsCollector()
        collector.noteFrame(byteCount: 125_000, isKeyframe: true, at: at(0))
        collector.tick(at: at(1))
        #expect(collector.telemetry(at: at(1)).bitsPerSecond != nil)

        collector.ingest(
            .stateChanged(from: .playing, to: .reconnecting, detail: StateDetail(narration: "")),
            at: at(1))

        #expect(collector.telemetry(at: at(1)).bitsPerSecond == nil)
    }

    /// The RTP layer's own figure wins whenever it has one: this type never recomputes a number
    /// `VigilRTP` already owns.
    @Test func theRTPLayersOwnRateWins() {
        let collector = StreamStatisticsCollector()
        collector.noteFrame(byteCount: 125_000, isKeyframe: true, at: at(0))
        collector.tick(at: at(1))

        collector.ingest(.statistics(sample(bitsPerSecond: 9_000_000)), at: at(1))

        #expect(collector.telemetry(at: at(1)).bitsPerSecond == 9_000_000)
    }

    // MARK: - Loss

    /// Loss is accumulated from the counters' deltas and published when the window closes.
    @Test func lossIsMeasuredOverItsOwnWindow() {
        let collector = StreamStatisticsCollector(lossWindow: .seconds(2))

        collector.ingest(.statistics(sample(packetsReceived: 1_000, packetsLost: 0)), at: at(0))
        collector.ingest(.statistics(sample(packetsReceived: 1_900, packetsLost: 100)), at: at(1))
        collector.ingest(.statistics(sample(packetsReceived: 2_800, packetsLost: 200)), at: at(3))

        let loss = collector.telemetry(at: at(3)).lossFraction
        #expect(loss != nil)
        #expect((loss ?? 0) > 0.09 && (loss ?? 0) < 0.11, "200 lost against 1 800 received")
    }

    /// ⛔ A reconnect rebuilds the RTP receivers, so the counters restart at zero. Booking that as a
    /// delta would be `UInt64` subtraction going backwards — an astronomically large "loss" and a
    /// stream reported as totally broken the moment it recovered.
    @Test func countersThatRestartAreRebaselinedNotSubtracted() {
        let collector = StreamStatisticsCollector(lossWindow: .seconds(1))
        collector.ingest(.statistics(sample(packetsReceived: 10_000, packetsLost: 5)), at: at(0))

        // The new receiver starts from nothing.
        collector.ingest(.statistics(sample(packetsReceived: 10, packetsLost: 0)), at: at(1))
        collector.ingest(.statistics(sample(packetsReceived: 1_010, packetsLost: 0)), at: at(3))

        // The un-rebaselined bug measured a whole stream lost here.
        #expect(collector.telemetry(at: at(3)).lossFraction == 0)
    }

    // MARK: - Frame rate, and the stall rule

    /// ⚠️ The frame rate is withheld for the first second. A rate averaged over a fraction of a
    /// second is noise, and the readout it produces jumps about while a stream is still opening.
    @Test func theFrameRateIsWithheldDuringTheWarmUp() {
        let collector = StreamStatisticsCollector()
        collector.ingest(.firstFrameAssembled(afterStart: .seconds(1)), at: at(0))
        collector.ingest(.statistics(sample(framesDecoded: 10, framesPerSecond: 25)), at: at(0.5))

        #expect(collector.telemetry(at: at(0.5)).framesPerSecond == nil, "half a second in")
        #expect(collector.telemetry(at: at(1.5)).framesPerSecond == 25)
    }

    /// ⛔ And withheld again when frames stop arriving. A frozen picture that goes on reporting
    /// "25 fps" is the readout actively lying about the thing the user is looking at.
    @Test func theFrameRateIsWithheldDuringAStall() {
        let collector = StreamStatisticsCollector()
        collector.ingest(.firstFrameAssembled(afterStart: .seconds(1)), at: at(0))
        collector.ingest(.statistics(sample(framesDecoded: 10, framesPerSecond: 25)), at: at(2))
        #expect(collector.telemetry(at: at(2)).framesPerSecond == 25)

        let afterTheStall = collector.telemetry(at: at(2 + StreamStatisticsRollup.stallSeconds + 1))
        #expect(afterTheStall.framesPerSecond == nil)
    }

    // MARK: - Keyframes

    /// Keyframe spacing is measured from the frames themselves when the RTP layer does not report
    /// one, which on this firmware it usually does not.
    @Test func keyframeSpacingIsMeasuredFromTheFrames() {
        let collector = StreamStatisticsCollector()

        collector.noteFrame(byteCount: 40_000, isKeyframe: true, at: at(0))
        collector.noteFrame(byteCount: 4_000, isKeyframe: false, at: at(1))
        collector.noteFrame(byteCount: 40_000, isKeyframe: true, at: at(4))

        #expect(collector.telemetry(at: at(4)).keyframeIntervalSeconds == 4)
    }

    /// One keyframe is not a spacing. Nothing is claimed until there are two.
    @Test func oneKeyframeIsNotAnInterval() {
        let collector = StreamStatisticsCollector()

        collector.noteFrame(byteCount: 40_000, isKeyframe: true, at: at(0))

        #expect(collector.telemetry(at: at(0)).keyframeIntervalSeconds == nil)
    }

    // MARK: - Jitter

    /// ⚠️ Gated on the packet counter, not on the value: a genuinely perfect link reports exactly
    /// zero jitter, and that is a reading rather than an absence.
    @Test func zeroJitterOnALiveLinkIsAReading() {
        let collector = StreamStatisticsCollector()

        collector.ingest(.statistics(sample(packetsReceived: 500, jitterMilliseconds: 0)), at: at(1))

        #expect(collector.telemetry(at: at(1)).jitterMilliseconds == 0)
    }

    /// Before any packet has arrived there is nothing to report.
    @Test func jitterIsAbsentBeforeTheFirstPacket() {
        let collector = StreamStatisticsCollector()

        collector.ingest(.statistics(sample(jitterMilliseconds: 3)), at: at(1))

        #expect(collector.telemetry(at: at(1)).jitterMilliseconds == nil)
    }

    // MARK: - The tile badge

    /// The badge appears once the codec is known, and carries the picture size with it.
    @Test func theTileBadgeNeedsACodec() {
        let collector = StreamStatisticsCollector()
        #expect(collector.telemetry(at: at(0)).tile == nil)

        collector.ingest(.formatResolved(format(.h265, width: 2560, height: 1440)), at: at(0))

        let reading = collector.telemetry(at: at(0))
        #expect(reading.tile?.codec == "H.265")
        #expect(reading.resolution?.width == 2560)
    }

    /// ⚠️ A zero-sized picture never replaces a real one. A Hikvision SDP often carries no
    /// `a=x-dimensions`, and blanking a working readout because the next message said nothing is a
    /// regression the user sees.
    @Test func azeroSizedFormatDoesNotBlankTheReadout() {
        let collector = StreamStatisticsCollector()
        collector.ingest(.formatResolved(format(.h264, width: 1920, height: 1080)), at: at(0))

        collector.ingest(.formatResolved(format(.h264)), at: at(1))

        #expect(collector.telemetry(at: at(1)).resolution?.width == 1920)
    }

    // MARK: - History

    /// The sparkline's window is bounded by **age**, which is what its `LAST 60 S` header claims.
    @Test func theHistoryIsBoundedByAge() {
        let collector = StreamStatisticsCollector(historyWindow: .seconds(3))

        for second in 0..<6 {
            collector.ingest(
                .statistics(sample(framesDecoded: UInt64(second))), at: at(Double(second)))
        }

        let history = collector.telemetry(at: at(5)).recentStatistics
        #expect(history.count == 4, "seconds 2 through 5 are inside a three-second window")
    }

    /// And by slot count, which is the allocation guard: the array can never grow however fast the
    /// samples arrive.
    @Test func theHistoryIsBoundedBySlots() {
        let collector = StreamStatisticsCollector(historyWindow: .seconds(3_600))

        for index in 0..<(StreamStatisticsRollup.historyCapacity + 25) {
            collector.ingest(
                .statistics(sample(framesDecoded: UInt64(index))), at: at(Double(index)))
        }

        let kept = collector.telemetry(at: at(100)).recentStatistics.count
        #expect(kept == StreamStatisticsRollup.historyCapacity)
    }

    // MARK: - Reconnects

    /// ⛔ A reconnect invalidates every window: the receivers are rebuilt, the counters restart, and
    /// a rate averaged across the gap would be a stream and a silence mixed together. The codec and
    /// the picture size stay, because a badge that blinked out on every reconnect reads as a fault.
    @Test func aReconnectClearsTheWindowsButKeepsTheBadge() {
        let collector = StreamStatisticsCollector()
        collector.ingest(.formatResolved(format(.h264, width: 1920, height: 1080)), at: at(0))
        collector.noteFrame(byteCount: 125_000, isKeyframe: true, at: at(0))
        collector.tick(at: at(1))
        collector.ingest(.statistics(sample(framesDecoded: 25)), at: at(1))

        collector.ingest(.connectAttemptStarted(attempt: 2, endpoint: "cam:554/x"), at: at(2))

        let reading = collector.telemetry(at: at(2))
        #expect(reading.bitsPerSecond == nil)
        #expect(reading.recentStatistics.isEmpty)
        #expect(reading.tile?.codec == "H.264", "the badge survives a reconnect")
        #expect(reading.resolution?.width == 1920)
    }

    /// The reconnect count is attempts *after* the first, counted here rather than taken from the
    /// controller's backoff ladder position — which returns to zero after a healthy minute and
    /// therefore under-reports a stream that keeps dropping.
    @Test func theReconnectCountIsAttemptsAfterTheFirst() {
        let collector = StreamStatisticsCollector()
        #expect(collector.telemetry(at: at(0)).reconnectCount == 0)

        collector.ingest(.connectAttemptStarted(attempt: 1, endpoint: "a"), at: at(0))
        #expect(collector.telemetry(at: at(0)).reconnectCount == 0, "the first attempt is not a reconnect")

        collector.ingest(.connectAttemptStarted(attempt: 2, endpoint: "a"), at: at(1))
        collector.ingest(.connectAttemptStarted(attempt: 3, endpoint: "a"), at: at(2))
        #expect(collector.telemetry(at: at(2)).reconnectCount == 2)
    }

    // MARK: - Reset

    /// Resetting forgets everything, badge included — which is what a different camera means.
    @Test func resettingForgetsEvenTheBadge() {
        let collector = StreamStatisticsCollector()
        collector.ingest(.formatResolved(format(.h264)), at: at(0))
        collector.noteDecodeQueueDepth(4)
        collector.ingest(.connectAttemptStarted(attempt: 2, endpoint: "a"), at: at(0))

        collector.reset(at: at(5))

        let reading = collector.telemetry(at: at(5))
        #expect(reading.tile == nil)
        #expect(reading.decodeQueueDepth == nil)
        #expect(reading.reconnectCount == 0)
    }
}

#endif  // os(macOS)
