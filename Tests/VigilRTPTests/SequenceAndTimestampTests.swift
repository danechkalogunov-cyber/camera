//
//  SequenceAndTimestampTests.swift
//  VigilRTPTests
//
//  Modulo-2^16 sequence arithmetic and 32-bit RTP timestamp unwrapping — the two places where a
//  plain `<` produces a stall that only appears after twenty minutes or thirteen hours of uptime.
//  Covers docs/spec-rtp.md §10.1 and §11.2.
//

import Testing

@testable import VigilRTP

@Suite struct SequenceArithmetic {

    @Test func seqLessMatchesTheSpecificationTable() {
        // docs/spec-rtp.md §10.1, the table in full.
        #expect(seqLess(0, 1))
        #expect(seqLess(65535, 0))
        #expect(seqLess(0, 65535) == false)
        #expect(seqLess(5, 5) == false)
        #expect(seqLess(0, 0x8000))                 // ambiguous half-space, documented as true
        #expect(seqDiff(0, 1) == -1)
        #expect(seqDiff(65535, 0) == -1)
        #expect(seqDiff(0, 65535) == 1)
        #expect(seqDiff(5, 5) == 0)
    }

    @Test func seqLessIsConsistentAcrossAWindowStraddlingTheWrap() {
        // Every ordered pair in a 64-wide window centred on the wrap must compare forwards.
        for offset in 0..<64 {
            let a = UInt16(truncatingIfNeeded: 65_500 + offset)
            for step in 1..<32 {
                let b = a &+ UInt16(step)
                #expect(seqLess(a, b), "\(a) should precede \(b)")
                #expect(seqGreater(b, a))
                #expect(seqDiff(b, a) == Int32(step))
                #expect(seqLessOrEqual(a, a))
            }
        }
    }

    @Test func seqGapRangesSplitsARunThatStraddlesTheWrap() {
        // 65534 and 65535 and 0 are missing; one ClosedRange cannot express that, so it is two.
        let ranges = seqGapRanges(from: 65534, to: 1)
        #expect(ranges.count == 2)
        #expect(ranges.first == 65534...65535)
        #expect(ranges.last == 0...0)
        #expect(ranges.reduce(0) { $0 + Int($1.upperBound - $1.lowerBound) + 1 } == 3)
    }

    @Test func seqGapRangesIsEmptyWhenNothingIsMissing() {
        #expect(seqGapRanges(from: 100, to: 100).isEmpty)
        #expect(seqGapRanges(from: 100, to: 99).isEmpty)
        #expect(seqGapRanges(from: 100, to: 103) == [100...102])
    }

    @Test func sequenceUnwrapperStaysMonotoneAcrossTheWrap() {
        var unwrapper = SequenceUnwrapper()
        var previous = unwrapper.extend(65_530)
        for step in 1...20 {
            let extended = unwrapper.extend(65_530 &+ UInt16(step))
            #expect(extended == previous + 1, "step \(step)")
            previous = extended
        }
        // 65530 + 20 = 65550, which is 14 past the wrap: cycle 1, sequence 14.
        #expect(previous == 65_550)
        #expect(unwrapper.extendedHighest == 65_550)
    }

    @Test func sequenceUnwrapperDoesNotRewindOnAReorderedPacket() {
        var unwrapper = SequenceUnwrapper()
        _ = unwrapper.extend(65_534)
        _ = unwrapper.extend(65_535)
        #expect(unwrapper.extend(1) == 65_537)          // crossed the wrap
        #expect(unwrapper.extend(0) == 65_536)          // late packet, correctly placed
        #expect(unwrapper.extendedHighest == 65_537)    // and the high water mark did not move
        #expect(unwrapper.extend(2) == 65_538)
    }
}

@Suite struct TimestampUnwrapping {

    @Test func timestampUnwrapperRebasesOnTheFirstValue() {
        var unwrapper = TimestampUnwrapper()
        #expect(unwrapper.extend(1_000_000) == 0)
        #expect(unwrapper.extend(1_003_600) == 3_600)
    }

    @Test func timestampUnwrapperProducesMonotoneOutputAcrossTwoToTheThirtySecond() {
        // 90 kHz wraps every ~13 h 15 m; start three frames short of the boundary and step through.
        var unwrapper = TimestampUnwrapper()
        let start: UInt32 = 0xFFFF_FFFF - 3600 * 2
        var timestamp = start
        var previous = unwrapper.extend(timestamp)
        #expect(previous == 0)
        for step in 1...10 {
            timestamp = timestamp &+ 3600
            let extended = unwrapper.extend(timestamp)
            #expect(extended > previous, "step \(step) went backwards")
            #expect(extended == Int64(step) * 3600)
            previous = extended
        }
        // The raw timestamp really did wrap: it is now far below where it started.
        #expect(timestamp < start)
    }

    @Test func timestampUnwrapperPlacesAReorderedPacketThatStraddlesTheWrap() {
        var unwrapper = TimestampUnwrapper()
        _ = unwrapper.extend(0xFFFF_F000)                   // origin
        let afterWrap = unwrapper.extend(0x0000_0FFF)       // +8191 across the wrap
        #expect(afterWrap == 8_191)
        // A late packet from before the wrap must not un-wrap the cycle counter.
        let late = unwrapper.extend(0xFFFF_F800)
        #expect(late == 2_048)
        #expect(unwrapper.extend(0x0000_1FFF) == 12_287)
    }

    @Test func timestampUnwrapperSeparatesAWrapFromADiscontinuity() {
        var unwrapper = TimestampUnwrapper()
        _ = unwrapper.extend(1_000_000)
        // Ten seconds at 90 kHz is 900 000 ticks: the threshold the receiver uses.
        #expect(unwrapper.isDiscontinuity(1_000_000 + 3_600, thresholdTicks: 900_000) == false)
        #expect(unwrapper.isDiscontinuity(1_000_000 + 900_001, thresholdTicks: 900_000))
        #expect(unwrapper.isDiscontinuity(1_000_000 - 900_001, thresholdTicks: 900_000))
    }

    @Test func timestampUnwrapperHonoursAnExplicitRTPInfoOrigin() {
        // RTP-Info said the first timestamp would be 500_000, so that is media time zero even if
        // the first packet to arrive is later.
        var unwrapper = TimestampUnwrapper(origin: 500_000)
        #expect(unwrapper.hasOrigin)
        #expect(unwrapper.extend(500_000 + 7_200) == 7_200)
    }
}
