//
//  ClockAndStatisticsTests.swift
//  VigilRTPTests
//
//  The min-filter + PLL presentation clock, and the `StreamStatistics` update algebra with its
//  fixed EWMA constants.
//  Covers docs/spec-rtp.md §11.4 and §13, and docs/API_CONTRACT.md §3.8.
//

import Foundation
import Testing

import VigilProtocols
@testable import VigilRTP

@Suite struct PresentationClockBehaviour {

    static func at(_ seconds: Double) -> MediaInstant {
        MediaInstant(nanoseconds: Int64(seconds * 1e9))
    }

    @Test func presentationClockSeedsOnItsFirstObservation() {
        var clock = PresentationClock()
        clock.observe(mediaSeconds: 10, at: Self.at(1_000.2))
        #expect(abs(clock.offsetSeconds - 990.2) < 1e-6)
        #expect(clock.rateRatio == 1.0)
        #expect(clock.isLocked == false)
        #expect(clock.sampleCount == 1)
    }

    @Test func presentationClockConvergesToZeroRateErrorOnAConstantOffset() {
        // Host time is exactly media time plus 0.2 s, forever. The rate must not wander.
        var clock = PresentationClock()
        for frame in 0..<400 {
            let media = Double(frame) * 0.04
            clock.observe(mediaSeconds: media, at: Self.at(1_000 + media + 0.2))
        }
        #expect(clock.isLocked)
        #expect(abs(clock.rateRatio - 1.0) < 20e-6, "a constant offset must not move the rate")
        let predicted = clock.hostTime(forMedia: 16.0).seconds
        #expect(abs(predicted - 1_016.2) < 0.01)
        #expect(abs(clock.mediaSeconds(forHost: Self.at(1_016.2)) - 16.0) < 0.01)
    }

    @Test func presentationClockIgnoresAsymmetricDelaySpikes() {
        // This is the test that justifies the min filter. Arrival jitter is one-sided — queueing
        // only ever delays a packet — so an EWMA of the raw offset climbs and the latency readout
        // inflates. The minimum must stay pinned to the true offset.
        var clock = PresentationClock()
        var generator = SplitMix64RandomSource(seed: 7)
        for frame in 0..<400 {
            let media = Double(frame) * 0.04
            // Every third frame is delayed by up to 150 ms; the rest are on time.
            let spike = frame % 3 == 0 ? Double(generator.next(upperBound: 150)) / 1000 : 0
            clock.observe(mediaSeconds: media, at: Self.at(1_000 + media + 0.2 + spike))
        }
        // Raw offset is 1000.2 plus the one-sided spike, so the true minimum is 1000.2.
        #expect(abs(clock.offsetSeconds - 1_000.2) < 0.05,
                "the offset must track the minimum, not the mean of a right-skewed distribution")
        #expect(clock.minimumObservedOffsetSeconds.map { abs($0 - 1_000.2) < 1e-6 } == true)
    }

    @Test func presentationClockHardResetsOnAOneSecondStep() {
        var clock = PresentationClock()
        for frame in 0..<100 {
            let media = Double(frame) * 0.04
            clock.observe(mediaSeconds: media, at: Self.at(1_000 + media + 0.2))
        }
        #expect(clock.isLocked)
        // A 1 s step: a seek, a PAUSE/PLAY, or an encoder restart. Media time jumps a second
        // ahead of where the host clock says it should be.
        clock.observe(mediaSeconds: 5.0, at: Self.at(1_004.2))
        #expect(clock.isLocked == false, "a step past resetThreshold must re-seed, not be smoothed")
        #expect(clock.sampleCount == 1)
        #expect(abs(clock.offsetSeconds - 999.2) < 1e-6)
    }

    @Test func presentationClockTracksAPositiveRateError() {
        // The camera's oscillator runs 100 ppm fast, so media time advances slightly slower than
        // host time. The loop must move `rateRatio` in the right direction and stay clamped.
        var clock = PresentationClock()
        let ppm = 100e-6
        for frame in 0..<1_500 {
            let media = Double(frame) * 0.04
            clock.observe(mediaSeconds: media, at: Self.at(1_000 + media * (1 + ppm) + 0.2))
        }
        #expect(clock.isLocked)
        #expect(clock.rateRatio <= 1.0 + PresentationClock.Tuning.live.maxRateDeviation)
        #expect(clock.rateRatio >= 1.0 - PresentationClock.Tuning.live.maxRateDeviation)
        // The test that matters: after a minute of drift the clock still predicts arrival times.
        let media = Double(1_499) * 0.04
        let predicted = clock.hostTime(forMedia: media).seconds
        #expect(abs(predicted - (1_000 + media * (1 + ppm) + 0.2)) < 0.05)
    }

    @Test func presentationClockLatencyIsTheAgeOfTheFrame() {
        var clock = PresentationClock()
        for frame in 0..<100 {
            let media = Double(frame) * 0.04
            clock.observe(mediaSeconds: media, at: Self.at(1_000 + media + 0.2))
        }
        // A frame whose media time is 4.0 s should have been here at host 1004.2; asking 100 ms
        // later reports 100 ms of latency on top of the 200 ms baseline already in the offset.
        let latency = clock.latencySeconds(forMedia: 4.0, at: Self.at(1_004.3))
        #expect(abs(latency - 0.1) < 0.01)
    }

    @Test func presentationClockResetForgetsEverything() {
        var clock = PresentationClock()
        clock.observe(mediaSeconds: 1, at: Self.at(100))
        clock.reset()
        #expect(clock.sampleCount == 0)
        #expect(clock.offsetSeconds == 0)
        #expect(clock.rateRatio == 1.0)
        #expect(clock.minimumObservedOffsetSeconds == nil)
    }
}

// MARK: - Statistics

@Suite struct StatisticsAlgebra {

    static func at(_ milliseconds: Int) -> MediaInstant {
        MediaInstant(nanoseconds: Int64(milliseconds) * 1_000_000)
    }

    @Test func statisticsConvergeOnAKnownFrameRate() {
        // 25 fps exactly: the first sample seeds the average, so it is 25 immediately and stays 25.
        var accumulator = StatisticsAccumulator(startTime: Self.at(0))
        for frame in 0..<100 {
            accumulator.noteFrame(isKeyframe: frame % 50 == 0, isVideo: true,
                                  at: Self.at(frame * 40))
        }
        #expect(abs(accumulator.statistics.framesPerSecond - 25) < 0.001)
        #expect(accumulator.statistics.framesDecoded == 100)
        // Two keyframes 50 frames apart is a 2 s interval, seeded on the first measurement.
        #expect(abs(accumulator.statistics.keyframeIntervalSeconds - 2.0) < 0.001)
    }

    @Test func statisticsFrameRateMovesTowardsANewRateAtTheDocumentedAlpha() {
        // α = 0.10, so one 50 fps sample after a seeded 25 fps average gives 25 + 0.1×25 = 27.5.
        var accumulator = StatisticsAccumulator(startTime: Self.at(0))
        accumulator.noteFrame(isKeyframe: false, isVideo: true, at: Self.at(0))
        accumulator.noteFrame(isKeyframe: false, isVideo: true, at: Self.at(40))
        #expect(abs(accumulator.statistics.framesPerSecond - 25) < 0.001)
        accumulator.noteFrame(isKeyframe: false, isVideo: true, at: Self.at(60))
        #expect(abs(accumulator.statistics.framesPerSecond - 27.5) < 0.001)
        #expect(StreamStatistics.framesPerSecondAlpha == 0.10)
    }

    @Test func statisticsClampImplausibleFrameIntervals() {
        var accumulator = StatisticsAccumulator(startTime: Self.at(0))
        accumulator.noteFrame(isKeyframe: false, isVideo: true, at: Self.at(0))
        // Two frames sharing an arrival instant would read as an infinite frame rate.
        accumulator.noteFrame(isKeyframe: false, isVideo: true, at: Self.at(0))
        #expect(accumulator.statistics.framesPerSecond == 0)
        // A ten-second stall would read as 0.1 fps for the next forty frames.
        accumulator.noteFrame(isKeyframe: false, isVideo: true, at: Self.at(10_000))
        #expect(accumulator.statistics.framesPerSecond == 0)
        accumulator.noteFrame(isKeyframe: false, isVideo: true, at: Self.at(10_040))
        #expect(abs(accumulator.statistics.framesPerSecond - 25) < 0.001)
    }

    @Test func statisticsConvergeOnAKnownBitrate() {
        // 25 packets of 1200 wire bytes per 500 ms window = 480 000 bit/s.
        var accumulator = StatisticsAccumulator(startTime: Self.at(0))
        for packet in 0..<25 {
            accumulator.notePacket(wireBytes: 1_200)
            accumulator.tick(Self.at(packet * 20))
        }
        accumulator.tick(Self.at(500))
        #expect(abs(accumulator.statistics.bitsPerSecond - 480_000) < 1)
        #expect(accumulator.statistics.packetsReceived == 25)
        #expect(StreamStatistics.bitsPerSecondAlpha == 0.25)

        // A second identical window leaves the average where it is.
        for packet in 0..<25 {
            accumulator.notePacket(wireBytes: 1_200)
            accumulator.tick(Self.at(500 + packet * 20))
        }
        accumulator.tick(Self.at(1_000))
        #expect(abs(accumulator.statistics.bitsPerSecond - 480_000) < 1)
    }

    @Test func statisticsLossFractionReflectsAGapOverTheWindow() {
        var accumulator = StatisticsAccumulator(startTime: Self.at(0))
        for _ in 0..<90 { accumulator.notePacket(wireBytes: 1_000) }
        accumulator.noteLoss(packets: 10, ranges: 1)
        accumulator.tick(Self.at(2_000))
        #expect(abs(accumulator.statistics.lossFraction - 0.1) < 1e-9)
        #expect(accumulator.statistics.packetsLost == 10)
        #expect(accumulator.statistics.gapCount == 1)

        // The window resets, so a clean window reports no loss.
        for _ in 0..<100 { accumulator.notePacket(wireBytes: 1_000) }
        accumulator.tick(Self.at(4_000))
        #expect(accumulator.statistics.lossFraction == 0)
        #expect(accumulator.statistics.packetsLost == 10, "the cumulative counter is monotone")
    }

    @Test func statisticsJitterIsPublishedWithoutASecondSmoothing() {
        // RFC 3550 already smooths jitter; smoothing it again would hide the bursts it exists for.
        var accumulator = StatisticsAccumulator(startTime: Self.at(0))
        accumulator.noteJitter(milliseconds: 4)
        #expect(accumulator.statistics.jitterMilliseconds == 4)
        accumulator.noteJitter(milliseconds: 40)
        #expect(accumulator.statistics.jitterMilliseconds == 40)
    }

    @Test func statisticsLatencyEstimateSumsItsFourTerms() {
        var accumulator = StatisticsAccumulator(startTime: Self.at(0))
        accumulator.noteFrame(isKeyframe: false, isVideo: true, at: Self.at(0))
        accumulator.noteFrame(isKeyframe: false, isVideo: true, at: Self.at(40))   // 25 fps
        accumulator.noteBufferDepth(packets: 4, milliseconds: 30)
        accumulator.setDecodeQueueDepth(3)
        accumulator.setDisplayLatency(milliseconds: 8.3)
        accumulator.updateLatencyEstimate(captureToArrivalMilliseconds: 50)
        // 30 buffer + 3 frames at 25 fps (120 ms) + 50 capture + 8.3 display.
        #expect(abs(accumulator.statistics.estimatedLatencyMilliseconds - 208.3) < 0.01)
    }

    @Test func statisticsRecordTheDecodeFieldsVigilVideoWrites() {
        var accumulator = StatisticsAccumulator(startTime: Self.at(0))
        accumulator.setDecodeTimings(p50: 3.5, p99: 12.0, isHardware: true)
        accumulator.addDroppedPreDisplay(4)
        accumulator.addDroppedPreDisplay(2)
        accumulator.noteDroppedFrames(3)
        accumulator.noteReconnect()
        accumulator.noteErrorCode("VG-RTSP-0401")
        accumulator.tick(Self.at(1_500))
        #expect(accumulator.statistics.decodeMillisecondsP50 == 3.5)
        #expect(accumulator.statistics.decodeMillisecondsP99 == 12.0)
        #expect(accumulator.statistics.isHardwareAccelerated)
        #expect(accumulator.statistics.framesDroppedPreDisplay == 6)
        #expect(accumulator.statistics.framesDroppedPreDecode == 3)
        #expect(accumulator.statistics.reconnectCount == 1)
        #expect(accumulator.statistics.lastErrorCode == "VG-RTSP-0401")
        #expect(abs(accumulator.statistics.uptimeSeconds - 1.5) < 1e-9)
    }

    @Test func statisticsIgnoreAudioFramesForTheVideoFrameRate() {
        var accumulator = StatisticsAccumulator(startTime: Self.at(0))
        for frame in 0..<50 {
            accumulator.noteFrame(isKeyframe: false, isVideo: false, at: Self.at(frame * 23))
        }
        #expect(accumulator.statistics.framesPerSecond == 0)
        #expect(accumulator.statistics.framesDecoded == 50)
    }
}

// MARK: - Gap policy

@Suite struct GapPolicyBehaviour {

    static func at(_ milliseconds: Int) -> MediaInstant {
        MediaInstant(nanoseconds: Int64(milliseconds) * 1_000_000)
    }

    @Test func gapTrackerThrottlesKeyframeRequests() {
        var tracker = GapTracker(policy: .live, startTime: Self.at(0))
        // Hoisted out of `#expect` because the call is `mutating`.
        let first = tracker.shouldRequestKeyframe(at: Self.at(0))
        let tooSoon = tracker.shouldRequestKeyframe(at: Self.at(500))
        let stillTooSoon = tracker.shouldRequestKeyframe(at: Self.at(1_999))
        let allowed = tracker.shouldRequestKeyframe(at: Self.at(2_000))
        #expect(first)
        #expect(tooSoon == false)
        #expect(stillTooSoon == false)
        #expect(allowed)
    }

    @Test func gapTrackerNeverRequestsKeyframesForPlayback() {
        // A recorded file will not gain the packets back by being asked for an IRAP.
        var tracker = GapTracker(policy: .playback, startTime: Self.at(0))
        let requested = tracker.shouldRequestKeyframe(at: Self.at(0))
        #expect(requested == false)
    }

    @Test func gapTrackerEscalatesAboveOnePercentLossAndRelaxesLater() {
        var tracker = GapTracker(policy: .live, startTime: Self.at(0))
        tracker.note(received: 980, lost: 20)                       // 2 % over the first window
        #expect(tracker.windowLossFraction > 0.01)
        let early = tracker.evaluateDepth(at: Self.at(5_000))
        let closed = tracker.evaluateDepth(at: Self.at(10_000))
        #expect(early == .unchanged, "window not closed yet")
        #expect(closed == .escalate)

        // Sixty seconds of clean windows earn the low-latency depth back.
        var now = 10_000
        var decision = GapTracker.DepthDecision.unchanged
        for _ in 0..<8 {
            tracker.note(received: 1_000, lost: 0)
            now += 10_000
            decision = tracker.evaluateDepth(at: Self.at(now))
            if decision == .relax { break }
        }
        #expect(decision == .relax)
    }
}
