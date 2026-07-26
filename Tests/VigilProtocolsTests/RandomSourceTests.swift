//
//  RandomSourceTests.swift
//  VigilProtocolsTests
//
//  The injected randomness contract: SplitMix64 reproduces Vigna's published sequence, and every
//  derived helper (bytes, hex, bounded draw, jitter) stays inside its documented range.
//  Covers docs/API_CONTRACT.md §3.2.
//

import Testing
import VigilProtocols

@Suite struct RandomSourceTests {

    // MARK: - SplitMix64 vectors

    @Test func splitMix64ReproducesThePublishedSequenceForSeedZero() {
        // Vigna's reference splitmix64.c, seed 0. These four words are the sequence every
        // xoshiro/xoroshiro seeding routine is checked against.
        var source = SplitMix64RandomSource(seed: 0)
        #expect(source.next() == 0xE220_A839_7B1D_CDAF)
        #expect(source.next() == 0x6E78_9E6A_A1B9_65F4)
        #expect(source.next() == 0x06C4_5D18_8009_454F)
        #expect(source.next() == 0xF88B_B8A8_724C_81EC)
    }

    @Test func splitMix64IsReproducibleFromItsSeed() {
        var first = SplitMix64RandomSource(seed: 0xDEAD_BEEF_CAFE_F00D)
        var second = SplitMix64RandomSource(seed: 0xDEAD_BEEF_CAFE_F00D)
        let a = (0..<32).map { _ in first.next() }
        let b = (0..<32).map { _ in second.next() }
        #expect(a == b, "the same seed must replay byte for byte — that is the whole point")
    }

    @Test func splitMix64DifferentSeedsDiverge() {
        var first = SplitMix64RandomSource(seed: 1)
        var second = SplitMix64RandomSource(seed: 2)
        #expect(first.next() != second.next())
    }

    @Test func splitMix64DefaultSeedIsStable() {
        // The default seed is documented; a change to it would silently invalidate every fixture.
        var source = SplitMix64RandomSource()
        #expect(source.next() == 0xC0E1_6B16_3A85_A4DC)
    }

    // MARK: - randomBytes

    @Test func randomSourceRandomBytesReturnsExactlyTheRequestedCount() {
        var source = SplitMix64RandomSource(seed: 7)
        for count in [1, 2, 7, 8, 9, 16, 17, 64] {
            #expect(source.randomBytes(count).count == count)
        }
    }

    @Test func randomSourceRandomBytesReturnsEmptyForNonPositiveCounts() {
        var source = SplitMix64RandomSource(seed: 7)
        #expect(source.randomBytes(0).isEmpty)
        #expect(source.randomBytes(-5).isEmpty)
    }

    @Test func randomSourceRandomBytesIsSeedReproducible() {
        var first = SplitMix64RandomSource(seed: 99)
        var second = SplitMix64RandomSource(seed: 99)
        #expect(first.randomBytes(40) == second.randomBytes(40))
    }

    @Test func randomSourceRandomBytesTakesLeastSignificantByteFirst() {
        // Endianness must not leak into the byte string, so the order is pinned by construction:
        // the first byte of a draw is its low byte.
        var source = SplitMix64RandomSource(seed: 0)
        let bytes = source.randomBytes(8)
        let word: UInt64 = 0xE220_A839_7B1D_CDAF
        #expect(bytes == (0..<8).map { UInt8(truncatingIfNeeded: word >> (8 * UInt64($0))) })
    }

    // MARK: - hexString

    @Test func randomSourceHexStringHasTheRequestedLengthAndCharacterSet() {
        var source = SplitMix64RandomSource(seed: 3)
        let text = source.hexString(count: 32)
        #expect(text.count == 32)
        #expect(text.allSatisfy { "0123456789abcdef".contains($0) })
    }

    @Test func randomSourceHexStringRoundsOddLengthsUp() {
        var source = SplitMix64RandomSource(seed: 3)
        #expect(source.hexString(count: 31).count == 32)
        #expect(source.hexString(count: 1).count == 2)
        #expect(source.hexString(count: 0).isEmpty)
        #expect(source.hexString(count: -4).isEmpty)
    }

    // MARK: - next(upperBound:)

    @Test func randomSourceBoundedDrawStaysInRange() {
        var source = SplitMix64RandomSource(seed: 11)
        for _ in 0..<2_000 {
            let value = source.next(upperBound: 10)
            #expect(value < 10)
        }
    }

    @Test func randomSourceBoundedDrawHandlesDegenerateBounds() {
        var source = SplitMix64RandomSource(seed: 11)
        #expect(source.next(upperBound: 0) == 0)
        #expect(source.next(upperBound: 1) == 0)
        #expect(source.next(upperBound: .max) < .max)
    }

    @Test func randomSourceBoundedDrawCoversEveryResidue() {
        // A smoke test for gross bias: 4 000 draws over 8 buckets must hit all of them.
        var source = SplitMix64RandomSource(seed: 2_024)
        var seen = Set<UInt64>()
        for _ in 0..<4_000 { seen.insert(source.next(upperBound: 8)) }
        #expect(seen.count == 8)
    }

    // MARK: - jitterFactor

    @Test func randomSourceJitterFactorStaysWithinTheRequestedFraction() {
        var source = SplitMix64RandomSource(seed: 5)
        for _ in 0..<1_000 {
            let factor = source.jitterFactor(0.2)
            #expect(factor >= 0.8)
            #expect(factor <= 1.2)
        }
    }

    @Test func randomSourceJitterFactorOfZeroIsExactlyOneAndDrawsNothing() {
        var source = SplitMix64RandomSource(seed: 5)
        #expect(source.jitterFactor(0) == 1.0)
        #expect(source.jitterFactor(-1) == 1.0)
        // No draw was consumed, so the next word is still the first of the seeded sequence.
        var reference = SplitMix64RandomSource(seed: 5)
        #expect(source.next() == reference.next())
    }

    @Test func randomSourceJitterFactorClampsFractionsAboveOne() {
        var source = SplitMix64RandomSource(seed: 5)
        for _ in 0..<200 {
            let factor = source.jitterFactor(9.0)
            #expect(factor >= 0.0, "a backoff delay must never be multiplied by a negative factor")
            #expect(factor <= 2.0)
        }
    }

    // MARK: - SystemRandomSource

    @Test func systemRandomSourceProducesDifferentWords() {
        var source = SystemRandomSource()
        let draws = Set((0..<16).map { _ in source.next() })
        #expect(draws.count == 16, "16 identical 64-bit draws is a broken generator, not luck")
    }
}
