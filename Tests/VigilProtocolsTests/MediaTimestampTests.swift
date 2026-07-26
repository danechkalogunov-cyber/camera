//
//  MediaTimestampTests.swift
//  VigilProtocolsTests
//
//  Rational media time: exact rescaling between timescales, rounding at the boundaries, the 128-bit
//  comparison, saturation, and the 32-bit RTP wraparound the depacketizer must absorb before a
//  timestamp is ever built. Covers docs/API_CONTRACT.md §3.3.
//
//  Expected values here are computed from the definition `value / timescale` by hand and shown in
//  the comment beside each case; none of them is claimed to come from real hardware.
//

import Foundation
import Testing
import VigilProtocols

@Suite struct MediaTimestampTests {

    // MARK: - Construction

    @Test func mediaTimestampClampsNonPositiveTimescaleInsteadOfTrapping() {
        // API_CONTRACT §2 R-05: `a=rtpmap:96 H264/0` is network data and must not crash the app.
        #expect(MediaTimestamp(value: 7, timescale: 0).timescale == 1)
        #expect(MediaTimestamp(value: 7, timescale: -90_000).timescale == 1)
        #expect(MediaTimestamp(value: 7, timescale: 0).value == 7)
    }

    @Test func mediaTimestampValidatingInitialiserRejectsNonPositiveTimescale() {
        #expect(MediaTimestamp(validating: 7, timescale: 0) == nil)
        #expect(MediaTimestamp(validating: 7, timescale: -1) == nil)
        #expect(MediaTimestamp(validating: 7, timescale: 90_000)?.timescale == 90_000)
    }

    @Test func mediaTimestampInvalidIsDistinctFromZero() {
        #expect(MediaTimestamp.invalid != MediaTimestamp.zero)
        #expect(!MediaTimestamp.invalid.isValid)
        #expect(MediaTimestamp.zero.isValid)
        #expect(MediaTimestamp(value: 0, timescale: 90_000).isValid)
    }

    @Test func mediaTimestampSecondsDividesValueByTimescale() {
        #expect(MediaTimestamp(value: 90_000, timescale: 90_000).seconds == 1.0)
        #expect(MediaTimestamp(value: 45_000, timescale: 90_000).seconds == 0.5)
        #expect(MediaTimestamp(value: -90_000, timescale: 90_000).seconds == -1.0)
    }

    // MARK: - Conversion between timescales

    @Test func mediaTimestampConvertsAcrossTimescales() {
        // 1 s expressed on the 90 kHz video clock, the 8 kHz G.711 clock and the 600 MP4 clock.
        let oneSecond = MediaTimestamp(value: 90_000, timescale: 90_000)
        #expect(oneSecond.converted(to: 8_000) == MediaTimestamp(value: 8_000, timescale: 8_000))
        #expect(oneSecond.converted(to: 600) == MediaTimestamp(value: 600, timescale: 600))
        #expect(oneSecond.converted(to: 1) == MediaTimestamp(value: 1, timescale: 1))
    }

    @Test func mediaTimestampConvertsOneFrameOfThirtyFPSFromVideoClockToMP4Clock() {
        // 3000 ticks at 90 kHz is exactly 1/30 s, which is 20 ticks on the 600 clock.
        let frame = MediaTimestamp(value: 3_000, timescale: 90_000)
        #expect(frame.converted(to: 600) == MediaTimestamp(value: 20, timescale: 600))
        #expect(frame.converted(to: 90_000) == frame)
    }

    @Test func mediaTimestampConversionToSameTimescaleIsIdentity() {
        let value = MediaTimestamp(value: 123_456, timescale: 90_000)
        #expect(value.converted(to: 90_000) == value)
    }

    @Test func mediaTimestampInvalidConvertsToInvalid() {
        #expect(MediaTimestamp.invalid.converted(to: 90_000) == .invalid)
        #expect(!MediaTimestamp.invalid.converted(to: 600).isValid)
    }

    @Test func mediaTimestampConversionClampsNonPositiveTargetTimescale() {
        // Must not trap: `UInt64(negativeInt32)` would, which is why the target is clamped first.
        let converted = MediaTimestamp(value: 90_000, timescale: 90_000).converted(to: 0)
        #expect(converted == MediaTimestamp(value: 1, timescale: 1))
        #expect(MediaTimestamp(value: 90_000, timescale: 90_000).converted(to: -8_000).timescale == 1)
    }

    // MARK: - Rounding at the boundaries

    @Test func mediaTimestampConversionRoundsHalfAwayFromZero() {
        // 1/2 s on a 1 Hz clock is exactly half a tick: away from zero in both directions.
        #expect(MediaTimestamp(value: 1, timescale: 2).converted(to: 1).value == 1)
        #expect(MediaTimestamp(value: -1, timescale: 2).converted(to: 1).value == -1)
        #expect(MediaTimestamp(value: 3, timescale: 2).converted(to: 1).value == 2)   // 1.5 -> 2
        #expect(MediaTimestamp(value: -3, timescale: 2).converted(to: 1).value == -2)  // -1.5 -> -2
    }

    @Test func mediaTimestampConversionRoundsBelowAndAboveHalfCorrectly() {
        #expect(MediaTimestamp(value: 1, timescale: 3).converted(to: 1).value == 0)   // 0.333 -> 0
        #expect(MediaTimestamp(value: 2, timescale: 3).converted(to: 1).value == 1)   // 0.667 -> 1
        #expect(MediaTimestamp(value: -1, timescale: 3).converted(to: 1).value == 0)
        #expect(MediaTimestamp(value: -2, timescale: 3).converted(to: 1).value == -1)
    }

    @Test func mediaTimestampConversionIsExactAboveTwoToTheFiftyThree() {
        // The whole reason `converted(to:)` is 128-bit: a Double would round this to ...496.
        let big = MediaTimestamp(value: 9_007_199_254_740_993, timescale: 2)   // 2^53 + 1
        #expect(big.converted(to: 1).value == 4_503_599_627_370_497)
    }

    @Test func mediaTimestampConversionSaturatesInsteadOfOverflowing() {
        let saturated = MediaTimestamp(value: .max, timescale: 1).converted(to: 90_000)
        #expect(saturated.value == .max)
        #expect(saturated.timescale == 90_000)
        let negative = MediaTimestamp(value: .min + 1, timescale: 1).converted(to: 90_000)
        #expect(negative.value == .min + 1)
        #expect(negative.isValid, "a saturated negative must stay distinguishable from .invalid")
    }

    // MARK: - Arithmetic

    @Test func mediaTimestampAddingSamplesStaysInReceiverTimescale() {
        let base = MediaTimestamp(value: 3_000, timescale: 90_000)
        #expect(base.adding(samples: 3_000) == MediaTimestamp(value: 6_000, timescale: 90_000))
        #expect(base.adding(samples: -3_000) == MediaTimestamp(value: 0, timescale: 90_000))
    }

    @Test func mediaTimestampSumConvertsRightHandSideIntoLeftTimescale() {
        let video = MediaTimestamp(value: 90_000, timescale: 90_000)      // 1 s
        let audio = MediaTimestamp(value: 8_000, timescale: 8_000)        // 1 s
        let sum = video + audio
        #expect(sum.timescale == 90_000)
        #expect(sum.value == 180_000)
        #expect((audio + video).timescale == 8_000)
        #expect((audio + video).value == 16_000)
    }

    @Test func mediaTimestampDifferenceConvertsRightHandSideIntoLeftTimescale() {
        let later = MediaTimestamp(value: 180_000, timescale: 90_000)
        let earlier = MediaTimestamp(value: 600, timescale: 600)          // 1 s
        #expect(later - earlier == MediaTimestamp(value: 90_000, timescale: 90_000))
    }

    @Test func mediaTimestampArithmeticTreatsInvalidAsAbsorbing() {
        let real = MediaTimestamp(value: 90_000, timescale: 90_000)
        #expect(real + .invalid == .invalid)
        #expect(MediaTimestamp.invalid + real == .invalid)
        #expect(real - .invalid == .invalid)
        #expect(MediaTimestamp.invalid - real == .invalid)
    }

    @Test func mediaTimestampArithmeticSaturatesOnOverflow() {
        let big = MediaTimestamp(value: .max, timescale: 90_000)
        #expect((big + big).value == .max)
        let small = MediaTimestamp(value: .min + 1, timescale: 90_000)
        #expect((small - big).value == .min + 1)
        #expect((small - big).isValid)
    }

    // MARK: - Comparison

    @Test func mediaTimestampComparesAcrossTimescalesWithoutOverflow() {
        let halfSecondVideo = MediaTimestamp(value: 45_000, timescale: 90_000)
        let oneSecondAudio = MediaTimestamp(value: 8_000, timescale: 8_000)
        #expect(halfSecondVideo < oneSecondAudio)
        #expect(!(oneSecondAudio < halfSecondVideo))
    }

    @Test func mediaTimestampComparisonOfEqualInstantsInDifferentTimescalesIsNeitherLess() {
        let a = MediaTimestamp(value: 90_000, timescale: 90_000)
        let b = MediaTimestamp(value: 600, timescale: 600)
        #expect(!(a < b))
        #expect(!(b < a))
        #expect(a != b, "equality is on the raw pair, like CMTime")
    }

    @Test func mediaTimestampComparisonSurvivesExtremeCrossMultiplication() {
        // 9.2e18 x 90 000 does not fit in 64 bits; the 128-bit compare must still be correct.
        let hugeOnFastClock = MediaTimestamp(value: .max, timescale: 90_000)
        let hugeOnSlowClock = MediaTimestamp(value: .max, timescale: 1)
        #expect(hugeOnFastClock < hugeOnSlowClock)
        #expect(MediaTimestamp(value: .min, timescale: 90_000) < hugeOnFastClock)
        // -2^63 ticks at 90 kHz is ~ -1.0e14 s; -2^63+1 ticks at 1 Hz is ~ -9.2e18 s, far earlier.
        #expect(MediaTimestamp(value: .min + 1, timescale: 1)
                    < MediaTimestamp(value: .min, timescale: 90_000))
    }

    @Test func mediaTimestampInvalidSortsBeforeEveryRealInstant() {
        let sorted = [MediaTimestamp(value: 1, timescale: 1), .invalid, .zero].sorted()
        #expect(sorted.first == .invalid)
    }

    // MARK: - Codable and description

    @Test func mediaTimestampRoundTripsThroughCodableAndClampsOnDecode() throws {
        let original = MediaTimestamp(value: 12_345, timescale: 90_000)
        let encoded = try JSONEncoder().encode(original)
        let roundTripped = try JSONDecoder().decode(MediaTimestamp.self, from: encoded)
        #expect(roundTripped == original)

        let hostile = Data(#"{"value":5,"timescale":0}"#.utf8)
        let decoded = try JSONDecoder().decode(MediaTimestamp.self, from: hostile)
        #expect(decoded.timescale == 1, "the invariant must survive a hostile document")
    }

    @Test func mediaTimestampDescriptionShowsRawPairAndSeconds() {
        #expect(MediaTimestamp(value: 90_000, timescale: 90_000).description == "90000/90000 (1.0s)")
    }

    // MARK: - 128-bit division helper

    @Test func mediaTimestampDivideWithOverflowGuardDividesSmallValues() {
        let result = UInt64.divideWithOverflowGuard(hi: 0, lo: 100, by: 7, addend: 3)
        #expect(result.quotient == 14)      // (100 + 3) / 7
        #expect(!result.didSaturate)
    }

    @Test func mediaTimestampDivideWithOverflowGuardSaturatesOnZeroDivisor() {
        let result = UInt64.divideWithOverflowGuard(hi: 0, lo: 100, by: 0, addend: 0)
        #expect(result.quotient == .max)
        #expect(result.didSaturate)
    }

    @Test func mediaTimestampDivideWithOverflowGuardSaturatesWhenQuotientExceedsSixtyFourBits() {
        // hi >= divisor is exactly the case `dividingFullWidth` would trap on.
        let result = UInt64.divideWithOverflowGuard(hi: 5, lo: 0, by: 5, addend: 0)
        #expect(result.quotient == .max)
        #expect(result.didSaturate)
    }

    @Test func mediaTimestampDivideWithOverflowGuardCarriesTheAddendIntoTheHighWord() {
        let result = UInt64.divideWithOverflowGuard(hi: 0, lo: .max, by: 2, addend: 1)
        #expect(result.quotient == 1 << 63)  // 2^64 / 2
        #expect(!result.didSaturate)
    }

    @Test func mediaTimestampDivideWithOverflowGuardSaturatesWhenTheCarryOverflows() {
        let result = UInt64.divideWithOverflowGuard(hi: .max, lo: .max, by: 1, addend: 1)
        #expect(result.quotient == .max)
        #expect(result.didSaturate)
    }
}
