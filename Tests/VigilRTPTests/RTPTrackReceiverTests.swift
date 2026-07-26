//
//  RTPTrackReceiverTests.swift
//  VigilRTPTests
//
//  The unit `VigilTransport` drives, exercised end to end with an injected clock and an injected
//  random source: hostile bytes, payload-type binding, SSRC changes, RTCP in and out.
//  Covers docs/spec-rtp.md §14.2 and docs/API_CONTRACT.md §4.4.
//

import Foundation
import Testing

import VigilProtocols
@testable import VigilRTP

@Suite struct RTPTrackReceiverBehaviour {

    static func at(_ milliseconds: Int) -> MediaInstant {
        MediaInstant(nanoseconds: Int64(milliseconds) * 1_000_000)
    }

    /// The H.264 format every case here uses: dynamic payload type 96 at 90 kHz.
    static func videoFormat() throws -> RTPTrackFormat {
        try RTPTrackFormat(payloadType: 96, encodingName: "H264", clockRate: 90_000,
                           channels: nil, fmtp: [:], parameterSets: nil)
    }

    /// A receiver with a seeded random source, so the SSRC and every RTCP interval reproduce.
    static func makeReceiver(reorderMode: ReorderBuffer.Mode = .passthrough) throws
        -> RTPTrackReceiver {
        try RTPTrackReceiver(format: videoFormat(),
                             reorderMode: reorderMode,
                             latency: .balanced,
                             cname: "vigil@test",
                             startTime: at(0),
                             randomSource: SplitMix64RandomSource(seed: 99))
    }

    /// One RTP packet on the wire. The payload is opaque: these cases pin the framing, not a codec.
    static func wirePacket(sequence: UInt16,
                           timestamp: UInt32,
                           ssrc: UInt32 = 0x1234_5678,
                           payloadType: UInt8 = 96,
                           marker: Bool = false,
                           payload: [UInt8] = [0x41, 0x9A, 0x00]) -> Data {
        var bytes: [UInt8] = [0x80, (marker ? 0x80 : 0) | payloadType]
        bytes += [UInt8(sequence >> 8), UInt8(sequence & 0xFF)]
        bytes += [UInt8(timestamp >> 24), UInt8((timestamp >> 16) & 0xFF),
                  UInt8((timestamp >> 8) & 0xFF), UInt8(timestamp & 0xFF)]
        bytes += [UInt8(ssrc >> 24), UInt8((ssrc >> 16) & 0xFF),
                  UInt8((ssrc >> 8) & 0xFF), UInt8(ssrc & 0xFF)]
        return Data(bytes + payload)
    }

    // MARK: - Construction

    @Test func rtpTrackReceiverRefusesAFormatItCannotDepacketize() {
        // G.711 resolves to a codec but has no depacketizer in this build, and the receiver says so
        // rather than accepting the track and emitting nothing.
        #expect(throws: RTPError.self) {
            let format = try RTPTrackFormat(payloadType: 8, encodingName: "PCMA", clockRate: 8_000,
                                            channels: 1, fmtp: [:], parameterSets: nil)
            _ = try RTPTrackReceiver(format: format, reorderMode: .passthrough, latency: .balanced,
                                     cname: "c", startTime: Self.at(0))
        }
    }

    @Test func rtpTrackFormatRejectsANonPositiveClockRate() {
        #expect(throws: RTPError.invalidClockRate(0)) {
            _ = try RTPTrackFormat(payloadType: 96, encodingName: "H264", clockRate: 0,
                                   channels: nil, fmtp: [:], parameterSets: nil)
        }
        #expect(throws: RTPError.unsupportedEncoding("MP4V-ES")) {
            _ = try RTPTrackFormat(payloadType: 96, encodingName: "MP4V-ES", clockRate: 90_000,
                                   channels: nil, fmtp: [:], parameterSets: nil)
        }
    }

    @Test func rtpTrackFormatResolvesTheHikvisionEncodingNames() throws {
        #expect(RTPTrackFormat.resolveCodec("H265") == .video(.h265))
        #expect(RTPTrackFormat.resolveCodec("hevc") == .video(.h265))
        #expect(RTPTrackFormat.resolveCodec("MPEG4-GENERIC") == .audio(.aac))
        #expect(RTPTrackFormat.resolveCodec("mpeg4-generic") == .audio(.aac))
        #expect(RTPTrackFormat.resolveCodec("AAL2-G726-32") == .audio(.g726))
        #expect(RTPTrackFormat.resolveCodec("JPEG") == nil)
        #expect(RTPTrackFormat.staticBinding(for: 0)?.codec == .audio(.g711U))
        #expect(RTPTrackFormat.staticBinding(for: 8)?.codec == .audio(.g711A))
        #expect(RTPTrackFormat.staticBinding(for: 26) == nil, "RTP/JPEG is out of scope")
        let format = try Self.videoFormat()
        #expect(format.codec == .video(.h264))
        #expect(format.hasUnexpectedVideoClockRate == false)
    }

    // MARK: - Hostile input

    @Test func rtpTrackReceiverCountsEachHeaderFailureSeparately() throws {
        var receiver = try Self.makeReceiver()
        let cases: [(bytes: Data, error: RTPError)] = [
            (Data([0x80, 0x60]), .shortPacket(length: 2)),
            (Data([0x00] + [UInt8](repeating: 0, count: 11)), .badVersion(0)),
            (Data([0x8F, 0x60] + [UInt8](repeating: 0, count: 10)), .truncatedCSRC),
            (RTPPacketParsing.hex("90 60 00 01 00 00 00 00 00 00 00 01 BE DE 00 04 01 02"),
             .truncatedExtension),
            (RTPPacketParsing.hex("A0 60 00 01 00 00 00 00 00 00 00 01 41 C8"),
             .badPaddingLength(200)),
        ]
        for (index, entry) in cases.enumerated() {
            let result = receiver.ingestRTP(entry.bytes, at: Self.at(index))
            #expect(result.parseFailures == [entry.error])
            #expect(result.frames.isEmpty)
        }
        #expect(receiver.parseFailures.shortPacket == 1)
        #expect(receiver.parseFailures.badVersion == 1)
        #expect(receiver.parseFailures.truncatedCSRC == 1)
        #expect(receiver.parseFailures.truncatedExtension == 1)
        #expect(receiver.parseFailures.badPadding == 1)
        #expect(receiver.parseFailures.total == 5)
        #expect(receiver.statistics.packetsReceived == 0, "a refused packet never counts as received")
    }

    @Test func rtpTrackReceiverDropsAPayloadTypeItDidNotNegotiate() throws {
        var receiver = try Self.makeReceiver()
        let result = receiver.ingestRTP(Self.wirePacket(sequence: 1, timestamp: 0, payloadType: 97),
                                        at: Self.at(0))
        #expect(result.parseFailures == [.unknownPayloadType(97)])
        #expect(result.events.contains(.malformed(.unexpectedPayloadType)))
        #expect(receiver.parseFailures.unexpectedPayloadType == 1)
        #expect(receiver.statistics.packetsReceived == 0)
    }

    @Test func rtpTrackReceiverDropsAZeroLengthPayload() throws {
        var receiver = try Self.makeReceiver()
        let result = receiver.ingestRTP(Self.wirePacket(sequence: 1, timestamp: 0, payload: []),
                                        at: Self.at(0))
        #expect(result.events.contains(.malformed(.emptyPayload)))
        #expect(receiver.parseFailures.emptyPayload == 1)
        // It still arrived, so RTCP and the bitrate must count it.
        #expect(receiver.statistics.packetsReceived == 1)
    }

    @Test func rtpTrackReceiverRateLimitsRepeatedMalformedEvents() throws {
        var receiver = try Self.makeReceiver()
        var emitted = 0
        for index in 0..<50 {
            let result = receiver.ingestRTP(
                Self.wirePacket(sequence: UInt16(index), timestamp: 0, payload: []),
                at: Self.at(index * 10))
            emitted += result.events.filter { $0 == .malformed(.emptyPayload) }.count
        }
        #expect(emitted == 1, "one event per reason per five seconds")
        #expect(receiver.parseFailures.emptyPayload == 50, "counters keep counting regardless")
        // Past the five-second window, the reason is reported again.
        let later = receiver.ingestRTP(Self.wirePacket(sequence: 100, timestamp: 0, payload: []),
                                       at: Self.at(6_000))
        #expect(later.events.contains(.malformed(.emptyPayload)))
    }

    @Test func rtpTrackReceiverSurvivesPseudoRandomBytes() throws {
        var receiver = try Self.makeReceiver()
        var generator = SplitMix64RandomSource(seed: 0xFACE_0FF1_CE00_1234)
        for index in 0..<5_000 {
            let length = Int(generator.next(upperBound: 48))
            _ = receiver.ingestRTP(Data(generator.randomBytes(length)), at: Self.at(index))
        }
        // The only assertion that matters is that nothing trapped; the counters prove work happened.
        #expect(receiver.parseFailures.total > 0)
    }

    // MARK: - Stream identity and loss

    @Test func rtpTrackReceiverReportsAnSSRCChangeAndResetsEverything() throws {
        var receiver = try Self.makeReceiver()
        for index in 0..<5 {
            _ = receiver.ingestRTP(
                Self.wirePacket(sequence: UInt16(100 + index), timestamp: UInt32(index) * 3_600),
                at: Self.at(index * 40))
        }
        #expect(receiver.currentSSRC == 0x1234_5678)
        let result = receiver.ingestRTP(
            Self.wirePacket(sequence: 9_000, timestamp: 0, ssrc: 0xABCD_EF01), at: Self.at(200))
        #expect(result.events.contains(.ssrcChanged(old: 0x1234_5678, new: 0xABCD_EF01)))
        #expect(receiver.currentSSRC == 0xABCD_EF01)
        // The huge sequence jump must not be reported as loss: it belongs to a different source.
        #expect(result.events.allSatisfy {
            if case .packetLoss = $0 { return false } else { return true }
        })
        #expect(receiver.statistics.packetsLost == 0)
    }

    @Test func rtpTrackReceiverReportsLossAndAsksForAKeyframeOnce() throws {
        var receiver = try Self.makeReceiver()
        _ = receiver.ingestRTP(Self.wirePacket(sequence: 10, timestamp: 0), at: Self.at(0))
        let gapped = receiver.ingestRTP(Self.wirePacket(sequence: 15, timestamp: 3_600),
                                        at: Self.at(40))
        #expect(gapped.events.contains(.packetLoss(range: 11...14, count: 4)))
        #expect(gapped.events.contains(.keyframeNeeded(reason: .packetLoss)))
        #expect(receiver.statistics.packetsLost == 4)
        #expect(receiver.statistics.gapCount == 1)

        // A second gap inside the throttle window reports the loss but not another request.
        let again = receiver.ingestRTP(Self.wirePacket(sequence: 20, timestamp: 7_200),
                                       at: Self.at(80))
        #expect(again.events.contains(.packetLoss(range: 16...19, count: 4)))
        #expect(again.events.contains(.keyframeNeeded(reason: .packetLoss)) == false)
        #expect(receiver.statistics.packetsLost == 8)
    }

    @Test func rtpTrackReceiverCountsWireBytesForTheBitrate() throws {
        var receiver = try Self.makeReceiver()
        // 25 packets of 15 wire bytes each in one 500 ms window.
        for index in 0..<25 {
            _ = receiver.ingestRTP(
                Self.wirePacket(sequence: UInt16(index), timestamp: UInt32(index) * 3_600),
                at: Self.at(index * 20))
        }
        _ = receiver.tick(Self.at(500))
        #expect(receiver.statistics.packetsReceived == 25)
        #expect(abs(receiver.statistics.bitsPerSecond - 25.0 * 15 * 8 / 0.5) < 1)
    }

    // MARK: - RTCP

    @Test func rtpTrackReceiverEmitsACompoundReportOnTheFirstTick() throws {
        var receiver = try Self.makeReceiver()
        for index in 0..<3 {
            _ = receiver.ingestRTP(
                Self.wirePacket(sequence: UInt16(index), timestamp: UInt32(index) * 3_600),
                at: Self.at(index * 40))
        }
        let first = receiver.tick(Self.at(100))
        #expect(first.outboundRTCP.count == 1, "nothing scheduled yet means report now")
        let packets = RTCPParser.parseCompound(try #require(first.outboundRTCP.first))
        #expect(packets.count == 2)
        #expect(packets.first?.payloadType == 201)
        #expect(packets.last?.payloadType == 202)
        guard case .receiverReport(let report) = try #require(packets.first) else {
            Issue.record("a compound packet must begin with RR")
            return
        }
        #expect(report.ssrc == receiver.ourSSRC)
        #expect(report.reports.first?.ssrc == 0x1234_5678)

        // The next report is not due for at least 1.25 s.
        let soon = receiver.tick(Self.at(200))
        #expect(soon.outboundRTCP.isEmpty)
    }

    @Test func rtpTrackReceiverAbsorbsASenderReportAndPublishesTheWallClock() throws {
        var receiver = try Self.makeReceiver()
        _ = receiver.ingestRTP(Self.wirePacket(sequence: 1, timestamp: 90_000), at: Self.at(0))
        let sr = RTPPacketParsing.hex("""
            80 C8 00 06 12 34 56 78 E9 A4 3B 21 80 00 00 00 \
            00 01 5F 90 00 00 27 10 00 12 34 56
            """)
        let result = receiver.ingestRTCP(sr, at: Self.at(10))
        #expect(result.events.count == 1)
        guard case .senderReport(let report) = try #require(result.events.first) else {
            Issue.record("expected a sender report event")
            return
        }
        #expect(report.ssrc == 0x1234_5678)
        let mapping = try #require(receiver.wallClockMapping)
        #expect(mapping.referenceRTPTimestamp == 0x0001_5F90)
        #expect(mapping.isPlausible)
        // One second of media later is one second of wall clock later.
        let later = mapping.unixSeconds(forRTP: 0x0001_5F90 &+ 90_000)
        #expect(abs(later - mapping.referenceUnixSeconds - 1.0) < 1e-6)
    }

    @Test func rtpTrackReceiverReportsAByeForOurSource() throws {
        var receiver = try Self.makeReceiver()
        _ = receiver.ingestRTP(Self.wirePacket(sequence: 1, timestamp: 0), at: Self.at(0))
        let bye = RTPPacketParsing.hex("81 CB 00 02 12 34 56 78 03 65 6F 66")
        let result = receiver.ingestRTCP(bye, at: Self.at(10))
        #expect(result.events.contains(.bye(reason: "eof")))
    }

    @Test func rtpTrackReceiverIgnoresAByeForADifferentSource() throws {
        var receiver = try Self.makeReceiver()
        _ = receiver.ingestRTP(Self.wirePacket(sequence: 1, timestamp: 0), at: Self.at(0))
        let bye = RTPPacketParsing.hex("81 CB 00 02 AA AA AA AA 03 65 6F 66")
        let result = receiver.ingestRTCP(bye, at: Self.at(10))
        #expect(result.events.isEmpty)
    }

    @Test func rtpTrackReceiverCountsAMisalignedRTCPBuffer() throws {
        var receiver = try Self.makeReceiver()
        let result = receiver.ingestRTCP(Data([0x80, 0xC9, 0x00]), at: Self.at(0))
        #expect(result.events.contains(.malformed(.rtcpMisaligned)))
    }

    @Test func rtpTrackReceiverCapturesTheCameraSDESStrings() throws {
        var receiver = try Self.makeReceiver()
        let sdes = RTPPacketParsing.hex("""
            81 CA 00 06 12 34 56 78 01 03 63 61 6D 06 09 48 \
            69 6B 76 69 73 69 6F 6E 00 00 00 00
            """)
        _ = receiver.ingestRTCP(sdes, at: Self.at(0))
        #expect(receiver.remoteCNAME == "cam")
        #expect(receiver.remoteTool == "Hikvision")
    }

    // MARK: - Deadlines and reset

    @Test func rtpTrackReceiverOffersACoalescableDeadline() throws {
        var receiver = try Self.makeReceiver(reorderMode: .adaptive)
        _ = receiver.ingestRTP(Self.wirePacket(sequence: 1, timestamp: 0), at: Self.at(0))
        // The bitrate window is the nearest thing due at 500 ms; nothing is later than that yet.
        let deadline = try #require(receiver.nextDeadline)
        #expect(deadline <= Self.at(500))
        #expect(deadline > Self.at(0))
    }

    @Test func rtpTrackReceiverResetKeepsMonotoneCountersAndClearsState() throws {
        var receiver = try Self.makeReceiver()
        for index in 0..<5 {
            _ = receiver.ingestRTP(
                Self.wirePacket(sequence: UInt16(index), timestamp: UInt32(index) * 3_600),
                at: Self.at(index * 40))
        }
        #expect(receiver.statistics.packetsReceived == 5)
        receiver.reset(at: Self.at(1_000))
        #expect(receiver.currentSSRC == nil)
        #expect(receiver.wallClockMapping == nil)
        #expect(receiver.statistics.packetsReceived == 5, "session history is not rewritten")
        #expect(receiver.statistics.reconnectCount == 1)
        // A completely different sequence after the reset is not loss.
        let result = receiver.ingestRTP(Self.wirePacket(sequence: 40_000, timestamp: 0),
                                        at: Self.at(1_040))
        #expect(result.events.allSatisfy {
            if case .packetLoss = $0 { return false } else { return true }
        })
    }

    @Test func rtpTrackReceiverAcceptsAnRTPInfoSeed() throws {
        var receiver = try Self.makeReceiver()
        receiver.seed(RTSPTrackTimingSeed(clockRate: 90_000,
                                          initialSequence: 1_000,
                                          initialRTPTimestamp: 450_000,
                                          scale: 1.0,
                                          playResponseInstant: Self.at(0)))
        let result = receiver.ingestRTP(Self.wirePacket(sequence: 1_000, timestamp: 450_000),
                                        at: Self.at(0))
        #expect(result.parseFailures.isEmpty)
        #expect(receiver.statistics.packetsReceived == 1)
    }
}
