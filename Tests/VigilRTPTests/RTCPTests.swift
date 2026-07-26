//
//  RTCPTests.swift
//  VigilRTPTests
//
//  RTCP parsing against the documented vectors, the RFC 3550 A.8 jitter recurrence against
//  hand-computed values, and a Receiver Report round trip.
//  Covers docs/spec-rtp.md §12 and §15.7.
//

import Foundation
import Testing

import VigilProtocols
@testable import VigilRTP

@Suite struct RTCPParsing {

    static func hex(_ string: String) -> Data {
        RTPPacketParsing.hex(string)
    }

    static func at(_ milliseconds: Int) -> MediaInstant {
        MediaInstant(nanoseconds: Int64(milliseconds) * 1_000_000)
    }

    // MARK: - Sender Report

    @Test func rtcpParsesTheSpecificationSenderReportVector() throws {
        // docs/spec-rtp.md §15.7, inbound SR from a camera.
        let bytes = Self.hex("""
            80 C8 00 06 12 34 56 78 E9 A4 3B 21 80 00 00 00 \
            00 0A 5C 90 00 00 27 10 00 12 34 56
            """)
        #expect(bytes.count == 28)
        let packets = RTCPParser.parseCompound(bytes)
        #expect(packets.count == 1)
        guard case .senderReport(let report) = try #require(packets.first) else {
            Issue.record("expected a sender report")
            return
        }
        #expect(report.ssrc == 0x1234_5678)
        #expect(report.ntpMostSignificantWord == 0xE9A4_3B21)
        #expect(report.ntpLeastSignificantWord == 0x8000_0000)
        #expect(report.rtpTimestamp == 0x000A_5C90)
        #expect(report.packetCount == 10_000)
        #expect(report.octetCount == 0x0012_3456)
        #expect(report.reports.isEmpty)
        #expect(report.compactNTP == 0x3B21_8000)
        // The spec prints a decimal for `unixSeconds` that does not follow from its own hex; the
        // identity below is the definition, and it is what this asserts.
        let expected = Double(0xE9A4_3B21 as UInt32) - 2_208_988_800 + 0.5
        #expect(abs(report.unixSeconds - expected) < 1e-6)
        #expect(report.isPlausibleWallClock)
    }

    @Test func rtcpMarksAnUnsetCameraClockAsImplausible() {
        // A Hikvision device with NTP disabled reports a time near its own boot instant.
        let report = SenderReport(ssrc: 1, ntpMostSignificantWord: 2_208_988_800 + 60,
                                  ntpLeastSignificantWord: 0, rtpTimestamp: 0,
                                  packetCount: 0, octetCount: 0)
        #expect(report.unixSeconds == 60)
        #expect(report.isPlausibleWallClock == false)
    }

    // MARK: - Compound handling

    @Test func rtcpParsesACompoundOfSenderReportSDESAndBye() throws {
        let sr = Self.hex("""
            80 C8 00 06 12 34 56 78 E9 A4 3B 21 80 00 00 00 \
            00 0A 5C 90 00 00 27 10 00 12 34 56
            """)
        // SDES: one chunk, CNAME "cam" and TOOL "Hikvision".
        let sdes = Self.hex("""
            81 CA 00 06 12 34 56 78 01 03 63 61 6D 06 09 48 \
            69 6B 76 69 73 69 6F 6E 00 00 00 00
            """)
        // BYE: one source, reason "eof".
        let bye = Self.hex("81 CB 00 02 12 34 56 78 03 65 6F 66")
        let packets = RTCPParser.parseCompound(sr + sdes + bye)
        #expect(packets.count == 3)

        guard case .sourceDescription(let description) = packets[1] else {
            Issue.record("expected SDES")
            return
        }
        #expect(description.chunks.count == 1)
        #expect(description.chunks.first?.ssrc == 0x1234_5678)
        #expect(description.chunks.first?.cname == "cam")
        #expect(description.chunks.first?.items.last?.type == .tool)
        #expect(description.chunks.first?.items.last?.text == "Hikvision")

        guard case .goodbye(let goodbye) = packets[2] else {
            Issue.record("expected BYE")
            return
        }
        #expect(goodbye.sources == [0x1234_5678])
        #expect(goodbye.reason == "eof")
    }

    @Test func rtcpSkipsAnUnknownPacketTypeByItsLength() throws {
        // PT 207 (XR) is not modelled; it must be stepped over, not fail the compound.
        let unknown = Self.hex("80 CF 00 02 DE AD BE EF 00 00 00 00")
        let receiverReport = Self.hex("80 C9 00 01 CA FE BA BE")
        let packets = RTCPParser.parseCompound(unknown + receiverReport)
        #expect(packets.count == 2)
        #expect(packets.first?.payloadType == 207)
        guard case .receiverReport(let report) = packets[1] else {
            Issue.record("expected RR")
            return
        }
        #expect(report.ssrc == 0xCAFE_BABE)
        #expect(report.reports.isEmpty)
    }

    @Test func rtcpStopsAtASubPacketWhoseLengthOverrunsTheBuffer() {
        // Declared length is 6 words = 28 bytes; only 12 are present.
        let truncated = Self.hex("80 C8 00 06 12 34 56 78 E9 A4 3B 21")
        let result = RTCPParser.parse(truncated)
        #expect(result.packets.isEmpty)
        #expect(result.isTruncated)
    }

    @Test func rtcpFlagsAMisalignedBufferAndParsesWhatFits() {
        let sr = Self.hex("""
            80 C8 00 06 12 34 56 78 E9 A4 3B 21 80 00 00 00 \
            00 0A 5C 90 00 00 27 10 00 12 34 56
            """)
        let result = RTCPParser.parse(sr + Data([0x00, 0x01]))
        #expect(result.isMisaligned)
        #expect(result.packets.count == 1)
    }

    @Test func rtcpRejectsAVersionOtherThanTwoWithoutTrapping() {
        let result = RTCPParser.parse(Self.hex("40 C8 00 06 12 34 56 78"))
        #expect(result.packets.isEmpty)
        #expect(result.isTruncated == false)
    }

    @Test func rtcpSignExtendsANegativeCumulativeLost() throws {
        // Duplicates make cumulative lost negative; the field is 24-bit signed, so 0xFFFFFB is -5.
        let rr = Self.hex("""
            81 C9 00 07 CA FE BA BE 12 34 56 78 00 FF FF FB \
            00 00 12 40 00 00 00 21 3B 21 80 00 00 00 1F 40
            """)
        let packets = RTCPParser.parseCompound(rr)
        guard case .receiverReport(let report) = try #require(packets.first) else {
            Issue.record("expected RR")
            return
        }
        #expect(report.reports.first?.cumulativeLost == -5)
    }

    @Test func rtcpSurvivesPseudoRandomBuffers() {
        var generator = SplitMix64RandomSource(seed: 0xC0FF_EE00_1234_5678)
        for _ in 0..<5_000 {
            let length = Int(generator.next(upperBound: 64))
            let result = RTCPParser.parse(Data(generator.randomBytes(length)))
            #expect(result.packets.count <= length)
        }
    }
}

// MARK: - Source state

@Suite struct RTPSourceStateBehaviour {

    static func at(_ milliseconds: Int) -> MediaInstant {
        MediaInstant(nanoseconds: Int64(milliseconds) * 1_000_000)
    }

    @Test func rtpSourceStateReproducesTheHandComputedA8JitterSequence() {
        // RFC 3550 §6.4.1 / A.8:
        //   D(i-1,i) = (Rj - Sj) - (Ri - Si);  J(i) = J(i-1) + (|D| - J(i-1)) / 16
        // held scaled by 16, so the step is `J += |D| - ((J + 8) >> 4)`.
        //
        // Hand-computed from the arrival table below (S = RTP timestamp, R = arrival in RTP units):
        //   P1  S=0      R=1000   transit 1000, seeded, J = 0
        //   P2  S=3000   R=4200   transit 1200, |D| = 200, J = 0   + 200 - (8   >> 4 = 0)  = 200
        //   P3  S=6000   R=7000   transit 1000, |D| = 200, J = 200 + 200 - (208 >> 4 = 13) = 387
        //   P4  S=9000   R=10000  transit 1000, |D| = 0,   J = 387 + 0   - (395 >> 4 = 24) = 363
        //   P5  S=12000  R=13600  transit 1600, |D| = 600, J = 363 + 600 - (371 >> 4 = 23) = 940
        var state = RTPSourceState(ssrc: 1, clockRate: 90_000)
        let table: [(timestamp: UInt32, arrival: UInt32)] = [
            (0, 1_000), (3_000, 4_200), (6_000, 7_000), (9_000, 10_000), (12_000, 13_600),
        ]
        var observed: [UInt32] = []
        for entry in table {
            state.updateJitter(rtpTimestamp: entry.timestamp, arrivalRTP: entry.arrival)
            observed.append(state.jitter)
        }
        #expect(observed == [0, 200, 387, 363, 940])
        // The wire field is the unscaled estimate, and the scaling is applied exactly once.
        #expect(state.jitter >> 4 == 58)
        #expect(abs(state.jitterMilliseconds - 58.0 * 1000 / 90_000) < 1e-9)
    }

    @Test func rtpSourceStateJitterIsZeroForAPerfectlyPacedStream() {
        var state = RTPSourceState(ssrc: 1, clockRate: 90_000)
        for step in 0..<50 {
            let ticks = UInt32(step) * 3_600
            state.updateJitter(rtpTimestamp: ticks, arrivalRTP: ticks &+ 5_000)
        }
        #expect(state.jitter == 0)
        #expect(state.jitterMilliseconds == 0)
    }

    @Test func rtpSourceStateArrivalConversionUsesIntegerMath() {
        // One second of host time is exactly `clockRate` ticks, with no floating-point quantisation
        // even at a day of uptime.
        let state = RTPSourceState(ssrc: 1, clockRate: 90_000)
        let day = MediaInstant(nanoseconds: 86_400 * 1_000_000_000)
        let dayPlusOne = MediaInstant(nanoseconds: 86_401 * 1_000_000_000)
        let difference = state.arrivalInRTPUnits(dayPlusOne) &- state.arrivalInRTPUnits(day)
        #expect(difference == 90_000)
    }

    @Test func rtpSourceStateValidatesASourceOnItsSecondPacket() {
        var state = RTPSourceState(clockRate: 90_000)
        state.restart(ssrc: 0x1234, sequence: 1000)
        #expect(state.isInProbation)
        #expect(state.update(sequence: 1000) == false)     // first packet: still on probation
        #expect(state.update(sequence: 1001))              // second consecutive packet validates it
        #expect(state.isInProbation == false)
        #expect(state.received == 1)
        #expect(state.extendedHighestSequence == 1001)
        #expect(state.expected == 1)
        #expect(state.cumulativeLost == 0)
    }

    @Test func rtpSourceStateCountsLossAcrossASequenceWrap() {
        var state = RTPSourceState(clockRate: 90_000)
        state.restart(ssrc: 0x1234, sequence: 65_530)
        for step in 0...5 {                                 // 65530…65535, in order
            _ = state.update(sequence: UInt16(truncatingIfNeeded: 65_530 + step))
        }
        #expect(state.cycles == 0)
        _ = state.update(sequence: 0)                       // the wrap
        #expect(state.cycles == RTPSourceState.sequenceModulus)
        _ = state.update(sequence: 1)
        // Three packets lost across the wrap, then the stream resumes.
        _ = state.update(sequence: 5)
        #expect(state.extendedHighestSequence == 65_536 + 5)
        // Base is 65531 (the second packet, which validated the source); expected counts from there.
        #expect(state.expected == 65_541 - 65_531 + 1)
        #expect(state.cumulativeLost == 3)
    }

    @Test func rtpSourceStateRestartsAfterTwoPacketsAtAWildlyDifferentSequence() {
        // Hikvision NVRs restart the sequence when a shared session switches channel.
        var state = RTPSourceState(clockRate: 90_000)
        state.restart(ssrc: 0x1234, sequence: 1000)
        _ = state.update(sequence: 1000)
        _ = state.update(sequence: 1001)
        // A jump far outside the dropout window is not believed on its first packet.
        #expect(state.update(sequence: 40_000) == false)
        #expect(state.extendedHighestSequence == 1001)
        // The confirming packet restarts the counting run.
        #expect(state.update(sequence: 40_001))
        #expect(state.extendedHighestSequence == 40_001)
        #expect(state.expected == 1)
    }

    @Test func rtpSourceStateReportBlockSaturatesFractionLost() {
        var state = RTPSourceState(clockRate: 90_000)
        state.restart(ssrc: 0xABCD, sequence: 0)
        _ = state.update(sequence: 0)
        _ = state.update(sequence: 1)
        _ = state.update(sequence: 2)
        // Everything from 3…1000 is missing.
        _ = state.update(sequence: 1_000)
        let block = state.makeReportBlock(at: Self.at(0))
        #expect(block.ssrc == 0xABCD)
        #expect(block.extendedHighestSequence == 1_000)
        #expect(block.cumulativeLost == 997)
        #expect(block.fractionLost > 250, "nearly everything in the interval was lost")
        #expect(block.fractionLost <= 255)
        // The interval resets, so a clean interval reports zero loss.
        _ = state.update(sequence: 1_001)
        let next = state.makeReportBlock(at: Self.at(1000))
        #expect(next.fractionLost == 0)
    }

    @Test func rtpSourceStateFillsLastSenderReportAndDelayFields() {
        var state = RTPSourceState(clockRate: 90_000)
        state.restart(ssrc: 0xABCD, sequence: 0)
        _ = state.update(sequence: 0)
        _ = state.update(sequence: 1)
        let report = SenderReport(ssrc: 0xABCD, ntpMostSignificantWord: 0xE9A4_3B21,
                                  ntpLeastSignificantWord: 0x8000_0000, rtpTimestamp: 0,
                                  packetCount: 1, octetCount: 1)
        state.noteSenderReport(report, at: Self.at(0))
        let block = state.makeReportBlock(at: Self.at(122))       // 0.122 s later
        #expect(block.lastSenderReportTimestamp == 0x3B21_8000)
        // DLSR is in units of 1/65536 s: 0.122 × 65536 = 7995.4 → 7995.
        #expect(block.delaySinceLastSenderReport == 7_995)
    }
}

// MARK: - Report generation

@Suite struct RTCPReportGeneration {

    static func at(_ milliseconds: Int) -> MediaInstant {
        MediaInstant(nanoseconds: Int64(milliseconds) * 1_000_000)
    }

    @Test func rtcpReportBuilderProducesTheDocumentedSDESBytes() {
        // docs/spec-rtp.md §15.7, outbound compound: ourSSRC 0xCAFEBABE, CNAME
        // "vigil@192.168.1.42" (18 bytes), no TOOL item.
        var state = RTPSourceState(clockRate: 90_000)
        state.restart(ssrc: 0x1234_5678, sequence: 0)
        _ = state.update(sequence: 0)
        _ = state.update(sequence: 1)
        var builder = RTCPReportBuilder(ourSSRC: 0xCAFE_BABE, cname: "vigil@192.168.1.42",
                                        tool: nil)
        let compound = builder.makeCompoundReport(source: &state, at: Self.at(0))
        #expect(compound.count == 64, "RR of 32 bytes plus SDES of 32 bytes")

        let rrHeader = Array(compound.prefix(8))
        #expect(rrHeader == [0x81, 0xC9, 0x00, 0x07, 0xCA, 0xFE, 0xBA, 0xBE])

        let sdes = Array(compound.suffix(32))
        #expect(sdes == [0x81, 0xCA, 0x00, 0x07, 0xCA, 0xFE, 0xBA, 0xBE,
                         0x01, 0x12, 0x76, 0x69, 0x67, 0x69, 0x6C, 0x40,
                         0x31, 0x39, 0x32, 0x2E, 0x31, 0x36, 0x38, 0x2E,
                         0x31, 0x2E, 0x34, 0x32, 0x00, 0x00, 0x00, 0x00])
    }

    @Test func rtcpReceiverReportRoundTripsEveryField() throws {
        var state = RTPSourceState(clockRate: 90_000)
        state.restart(ssrc: 0x1234_5678, sequence: 4_000)
        for step in 0...9 { _ = state.update(sequence: UInt16(4_000 + step)) }
        _ = state.update(sequence: 4_020)                      // ten packets lost
        for entry in [(UInt32(0), UInt32(900)), (3_600, 4_800), (7_200, 8_000)] {
            state.updateJitter(rtpTimestamp: entry.0, arrivalRTP: entry.1)
        }
        let senderReport = SenderReport(ssrc: 0x1234_5678, ntpMostSignificantWord: 0xE9A4_3B21,
                                        ntpLeastSignificantWord: 0x8000_0000, rtpTimestamp: 0,
                                        packetCount: 10, octetCount: 100)
        state.noteSenderReport(senderReport, at: Self.at(0))

        var reference = state
        let expected = reference.makeReportBlock(at: Self.at(500))

        var builder = RTCPReportBuilder(ourSSRC: 0xCAFE_BABE, cname: "vigil@test")
        let bytes = builder.makeCompoundReport(source: &state, at: Self.at(500))

        let packets = RTCPParser.parseCompound(bytes)
        #expect(packets.count == 2)
        guard case .receiverReport(let report) = try #require(packets.first) else {
            Issue.record("a compound report must begin with SR or RR")
            return
        }
        #expect(report.ssrc == 0xCAFE_BABE)
        let block = try #require(report.reports.first)
        #expect(block.ssrc == expected.ssrc)
        #expect(block.fractionLost == expected.fractionLost)
        #expect(block.cumulativeLost == expected.cumulativeLost)
        #expect(block.extendedHighestSequence == expected.extendedHighestSequence)
        #expect(block.jitter == expected.jitter)
        #expect(block.lastSenderReportTimestamp == 0x3B21_8000)
        #expect(block.delaySinceLastSenderReport == expected.delaySinceLastSenderReport)
        #expect(block.cumulativeLost == 10)

        guard case .sourceDescription(let description) = packets[1] else {
            Issue.record("RFC 3550 §6.1 requires an SDES CNAME in every compound packet")
            return
        }
        #expect(description.chunks.first?.cname == "vigil@test")
        #expect(description.chunks.first?.items.count == 2, "CNAME and TOOL")
    }

    @Test func rtcpReportBuilderRoundTripsANegativeCumulativeLost() throws {
        // More packets received than expected, because the camera duplicated some.
        let block = ReceptionReportBlock(ssrc: 7, fractionLost: 0, cumulativeLost: -12,
                                         extendedHighestSequence: 500, jitter: 33,
                                         lastSenderReportTimestamp: 0, delaySinceLastSenderReport: 0)
        var state = RTPSourceState(clockRate: 90_000)
        state.restart(ssrc: 7, sequence: 0)
        _ = state.update(sequence: 0)
        _ = state.update(sequence: 1)
        for _ in 0..<12 { _ = state.update(sequence: 1) }      // duplicates, counted but not expected
        var builder = RTCPReportBuilder(ourSSRC: 1, cname: "c")
        let bytes = builder.makeCompoundReport(source: &state, at: Self.at(0))
        let packets = RTCPParser.parseCompound(bytes)
        guard case .receiverReport(let report) = try #require(packets.first) else {
            Issue.record("expected RR")
            return
        }
        #expect(report.reports.first?.cumulativeLost == -12)
        #expect(report.reports.first?.fractionLost == 0, "duplicates never produce a negative byte")
        #expect(block.cumulativeLost == -12)
    }

    @Test func rtcpByeCarriesOurSSRCAndAPaddedReason() {
        let builder = RTCPReportBuilder(ourSSRC: 0xCAFE_BABE, cname: "c")
        let bytes = builder.makeBye(reason: "eof")
        #expect(bytes.count % 4 == 0)
        let packets = RTCPParser.parseCompound(bytes)
        guard case .goodbye(let goodbye) = packets.first else {
            Issue.record("expected BYE")
            return
        }
        #expect(goodbye.sources == [0xCAFE_BABE])
        #expect(goodbye.reason == "eof")
    }

    @Test func rtcpFullIntraRequestIncrementsItsSequenceNumber() {
        var builder = RTCPReportBuilder(ourSSRC: 0xCAFE_BABE, cname: "c")
        let first = Array(builder.makeFullIntraRequest(target: 0x1234_5678))
        let second = Array(builder.makeFullIntraRequest(target: 0x1234_5678))
        #expect(first.count == 20)
        #expect(first[0] == 0x84, "version 2, FMT 4")
        #expect(first[1] == 206)
        #expect(first[16] == 1)
        #expect(second[16] == 2)
    }

    @Test func rtcpScheduleHalvesTheFirstIntervalAndRandomisesTheRest() {
        var generator: any RandomSource = SplitMix64RandomSource(seed: 42)
        var schedule = RTCPSchedule()
        #expect(schedule.isDue(at: Self.at(0)), "nothing scheduled yet means send now")
        schedule.schedule(after: Self.at(0), random: &generator)
        let firstMilliseconds = (schedule.nextDeadline?.nanoseconds ?? 0) / 1_000_000
        // Half of 5 s, floored at 1.5 s, times a 0.5…1.5 factor: 1250…3750 ms.
        #expect(firstMilliseconds >= 1_250)
        #expect(firstMilliseconds <= 3_750)

        schedule.schedule(after: Self.at(10_000), random: &generator)
        let second = schedule.nextDeadline?.nanoseconds ?? 0
        let interval = second / 1_000_000 - 10_000
        #expect(interval >= 2_500)
        #expect(interval <= 7_500)
        #expect(schedule.isDue(at: Self.at(0)) == false)
        schedule.expedite()
        #expect(schedule.isDue(at: Self.at(0)))
    }
}
