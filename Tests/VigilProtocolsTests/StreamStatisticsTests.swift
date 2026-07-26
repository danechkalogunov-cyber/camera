//
//  StreamStatisticsTests.swift
//  VigilProtocolsTests
//
//  The EWMA algebra and the shape of the 1 Hz telemetry sample.
//  Covers docs/API_CONTRACT.md §3.8 (ruling R-19).
//
//  Every expected value below is computed by hand from `α × sample + (1 − α) × previous`
//  and written out in the test, so a change to the smoothing constants fails here loudly.
//

import Foundation
import Testing
import VigilProtocols

@Suite struct StreamStatisticsTests {

    private let tolerance = 1e-9

    // MARK: - Defaults

    @Test func statisticsStartAtZero() {
        let stats = StreamStatistics()
        #expect(stats.framesDecoded == 0)
        #expect(stats.framesPerSecond == 0)
        #expect(stats.bitsPerSecond == 0)
        #expect(stats.lossFraction == 0)
        #expect(stats.isHardwareAccelerated == false)
        #expect(stats.lastErrorCode == nil)
    }

    @Test func theSmoothingConstantsAreTheOnesTheContractStates() {
        #expect(StreamStatistics.framesPerSecondAlpha == 0.10)
        #expect(StreamStatistics.bitsPerSecondAlpha == 0.25)
        #expect(StreamStatistics.keyframeIntervalAlpha == 0.20)
    }

    // MARK: - EWMA algebra

    @Test func ewmaAdoptsTheFirstSampleWhole() {
        // An unseeded average must not spend ten samples climbing out of zero.
        #expect(StreamStatistics.ewma(previous: 0, sample: 30, alpha: 0.10) == 30)
    }

    @Test func ewmaMatchesTheHandComputedSeries() {
        // α = 0.10: 0.10 × 20 + 0.90 × 30 = 2 + 27 = 29.0
        let first = StreamStatistics.ewma(previous: 30, sample: 20, alpha: 0.10)
        #expect(abs(first - 29.0) < tolerance)
        // 0.10 × 20 + 0.90 × 29 = 2 + 26.1 = 28.1
        let second = StreamStatistics.ewma(previous: first, sample: 20, alpha: 0.10)
        #expect(abs(second - 28.1) < tolerance)
        // 0.10 × 20 + 0.90 × 28.1 = 2 + 25.29 = 27.29
        let third = StreamStatistics.ewma(previous: second, sample: 20, alpha: 0.10)
        #expect(abs(third - 27.29) < tolerance)
    }

    @Test func ewmaWithAlphaOneTakesTheSampleAndWithAlphaZeroKeepsThePrevious() {
        #expect(StreamStatistics.ewma(previous: 30, sample: 20, alpha: 1.0) == 20)
        #expect(StreamStatistics.ewma(previous: 30, sample: 20, alpha: 0.0) == 30)
    }

    @Test func ewmaClampsAnAlphaOutsideZeroToOne() {
        #expect(StreamStatistics.ewma(previous: 30, sample: 20, alpha: 4.0) == 20)
        #expect(StreamStatistics.ewma(previous: 30, sample: 20, alpha: -1.0) == 30)
    }

    @Test func ewmaIgnoresANonFiniteSample() {
        // A window of zero length divides by zero; the average must not become NaN for ever.
        #expect(StreamStatistics.ewma(previous: 30, sample: .nan, alpha: 0.10) == 30)
        #expect(StreamStatistics.ewma(previous: 30, sample: .infinity, alpha: 0.10) == 30)
    }

    @Test func ewmaConvergesTowardsAConstantSample() {
        var value = StreamStatistics.ewma(previous: 0, sample: 5, alpha: 0.25)
        for _ in 0..<200 {
            value = StreamStatistics.ewma(previous: value, sample: 25, alpha: 0.25)
        }
        #expect(abs(value - 25) < 1e-6)
    }

    // MARK: - The fields the algebra maintains

    @Test func framesPerSecondUsesAlphaOneTenth() {
        var stats = StreamStatistics()
        stats.updateFramesPerSecond(sample: 30)
        #expect(stats.framesPerSecond == 30)
        stats.updateFramesPerSecond(sample: 20)
        #expect(abs(stats.framesPerSecond - 29.0) < tolerance)
    }

    @Test func bitsPerSecondUsesAlphaOneQuarter() {
        var stats = StreamStatistics()
        stats.updateBitsPerSecond(sample: 4_000_000)
        #expect(stats.bitsPerSecond == 4_000_000)
        // 0.25 × 2_000_000 + 0.75 × 4_000_000 = 500_000 + 3_000_000 = 3_500_000
        stats.updateBitsPerSecond(sample: 2_000_000)
        #expect(abs(stats.bitsPerSecond - 3_500_000) < 1e-6)
    }

    @Test func keyframeIntervalUsesAlphaOneFifth() {
        var stats = StreamStatistics()
        stats.updateKeyframeInterval(sample: 2.0)
        #expect(stats.keyframeIntervalSeconds == 2.0)
        // 0.20 × 4 + 0.80 × 2 = 0.8 + 1.6 = 2.4
        stats.updateKeyframeInterval(sample: 4.0)
        #expect(abs(stats.keyframeIntervalSeconds - 2.4) < tolerance)
    }

    @Test func aFrameRateSpikeMovesTheAverageOnlyATenthOfTheWay() {
        // The reason α is 0.10: one dropped second must not make the inspector read 0 fps.
        var stats = StreamStatistics()
        stats.updateFramesPerSecond(sample: 25)
        stats.updateFramesPerSecond(sample: 0)
        #expect(abs(stats.framesPerSecond - 22.5) < tolerance)
    }

    // MARK: - Loss fraction

    @Test func lossFractionIsOverTheWholeWindow() {
        var stats = StreamStatistics()
        stats.updateLossFraction(received: 90, lost: 10)
        #expect(abs(stats.lossFraction - 0.10) < tolerance)
        stats.updateLossFraction(received: 1, lost: 3)
        #expect(abs(stats.lossFraction - 0.75) < tolerance)
    }

    @Test func lossFractionOfAnEmptyWindowIsZeroAndNotNaN() {
        var stats = StreamStatistics()
        stats.updateLossFraction(received: 0, lost: 0)
        #expect(stats.lossFraction == 0)
        #expect(!stats.lossFraction.isNaN)
    }

    @Test func lossFractionIsClampedToOne() {
        var stats = StreamStatistics()
        stats.updateLossFraction(received: 0, lost: 500)
        #expect(stats.lossFraction == 1)
    }

    // MARK: - Coding

    @Test func statisticsRoundTripThroughJSON() throws {
        var stats = StreamStatistics()
        stats.framesDecoded = 12_345
        stats.updateFramesPerSecond(sample: 25)
        stats.isHardwareAccelerated = true
        stats.lastErrorCode = "VG-RTSP-0401"
        let data = try JSONEncoder().encode(stats)
        let decoded = try JSONDecoder().decode(StreamStatistics.self, from: data)
        #expect(decoded == stats)
        #expect(decoded.lastErrorCode == "VG-RTSP-0401")
    }
}
