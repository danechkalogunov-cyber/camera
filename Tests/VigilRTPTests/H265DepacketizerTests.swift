//
//  H265DepacketizerTests.swift
//  VigilRTPTests
//
//  RFC 7798 framing: the two-byte PayloadHdr, AP aggregation, FU fragmentation with and without
//  DONL, and hostile input. Packet vectors are the ones in docs/spec-rtp.md §15.4.
//

import Foundation
import Testing

import VigilProtocols
@testable import VigilRTP

@Suite struct H265DepacketizerTests {

    // MARK: - Fragmentation

    /// docs/spec-rtp.md §15.4. The reconstructed NAL header is `26 01`: `0x81` keeps the forbidden
    /// bit and the top bit of `nuh_layer_id`, and the FU type supplies the six type bits.
    @Test func h265FragmentUnitsReassembleByteIdenticallyToTheOriginalNAL() throws {
        var depacketizer = H265Depacketizer()
        let payloads: [[UInt8]] = [[0x62, 0x01, 0x93, 0xAA, 0xBB],
                                   [0x62, 0x01, 0x13, 0xCC, 0xDD],
                                   [0x62, 0x01, 0x53, 0xEE, 0xFF]]
        var frames: [EncodedFrame] = []
        for (index, payload) in payloads.enumerated() {
            let packet = DepacketizerFixture.packet(payload, sequence: UInt16(200 + index),
                                                    timestamp: 679_056)
            frames += depacketizer.push(packet, at: DepacketizerFixture.instant(index)).frames
        }
        frames += depacketizer.flush(at: DepacketizerFixture.instant(40))

        let frame = try #require(frames.first)
        #expect(frames.count == 1)
        #expect(frame.isKeyframe)                        // IDR_W_RADL is an IRAP
        #expect([UInt8](frame.data) == [0x00, 0x00, 0x00, 0x08,
                                        0x26, 0x01, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
    }

    /// The same fragment run with `sprop-max-don-diff > 0`: a DONL sits between the PayloadHdr and
    /// the FU header of the **start** fragment only, and every continuation is unshifted.
    @Test func h265FragmentUnitsWithDONLReassembleIdentically() throws {
        var depacketizer = H265Depacketizer(usesDONL: true)
        let payloads: [[UInt8]] = [[0x62, 0x01, 0x00, 0x2A, 0x93, 0xAA, 0xBB],
                                   [0x62, 0x01, 0x13, 0xCC, 0xDD],
                                   [0x62, 0x01, 0x53, 0xEE, 0xFF]]
        var frames: [EncodedFrame] = []
        for (index, payload) in payloads.enumerated() {
            let packet = DepacketizerFixture.packet(payload, sequence: UInt16(300 + index),
                                                    timestamp: 679_056)
            frames += depacketizer.push(packet, at: DepacketizerFixture.instant(index)).frames
        }
        frames += depacketizer.flush(at: DepacketizerFixture.instant(40))

        #expect(frames.count == 1)
        #expect([UInt8](try #require(frames.first).data) == [0x00, 0x00, 0x00, 0x08,
                                                             0x26, 0x01, 0xAA, 0xBB, 0xCC, 0xDD,
                                                             0xEE, 0xFF])
    }

    /// A many-fragment picture, built by the fixture splitter, round-trips byte for byte both with
    /// and without DONL.
    @Test func h265LongFragmentRunRoundTripsWithAndWithoutDONL() throws {
        for donl: UInt16? in [nil, 0x1234] {
            var depacketizer = H265Depacketizer(usesDONL: donl != nil)
            let nal = DepacketizerFixture.h265Slice(type: 19, firstSlice: true,
                                                    body: Array(0..<32).map { UInt8($0) })
            var frames: [EncodedFrame] = []
            var sequence: UInt16 = 900
            for fragment in DepacketizerFixture.h265FragmentUnits(nal, chunk: 5, donl: donl) {
                frames += depacketizer.push(DepacketizerFixture.packet(fragment, sequence: sequence,
                                                                       timestamp: 1000),
                                            at: DepacketizerFixture.instant(0)).frames
                sequence &+= 1
            }
            frames += depacketizer.flush(at: DepacketizerFixture.instant(40))
            let nals = try #require(DepacketizerFixture.splitLengthPrefixed(try #require(frames.first).data))
            #expect(nals == [nal])
        }
    }

    /// A lost middle fragment discards the run and counts the loss; nothing truncated escapes.
    @Test func h265LostMiddleFragmentDiscardsTheRun() {
        var depacketizer = H265Depacketizer()
        var events: [DepacketizerEvent] = []
        var frames: [EncodedFrame] = []
        for (payload, sequence) in [([0x62, 0x01, 0x93, 0xAA, 0xBB], UInt16(10)),
                                    ([0x62, 0x01, 0x53, 0xEE, 0xFF], UInt16(12))] {
            let out = depacketizer.push(DepacketizerFixture.packet(payload, sequence: sequence,
                                                                   timestamp: 900),
                                        at: DepacketizerFixture.instant(0))
            frames += out.frames
            events += out.events
        }
        frames += depacketizer.flush(at: DepacketizerFixture.instant(40))
        #expect(frames.isEmpty)
        #expect(DepacketizerFixture.malformedReasons(events).contains(.fragmentGap))
    }

    /// A FU cannot fragment an AP, another FU or a PACI. Claiming one of those is rejected.
    @Test func h265FragmentUnitClaimingAnUnfragmentableTypeIsRejected() {
        for claimed: UInt8 in [48, 49, 50] {
            var depacketizer = H265Depacketizer()
            let out = depacketizer.push(DepacketizerFixture.packet([0x62, 0x01, 0x80 | claimed,
                                                                    0xAA],
                                                                   sequence: 1, timestamp: 900),
                                        at: DepacketizerFixture.instant(0))
            #expect(DepacketizerFixture.malformedReasons(out.events) == [.nestedPacketization])
            #expect(out.frames.isEmpty)
        }
    }

    // MARK: - Aggregation

    /// docs/spec-rtp.md §15.4. An AP carrying VPS, SPS and PPS unpacks all three in order, and the
    /// `00 00 03` inside the SPS body is left exactly as it arrived.
    @Test func h265AggregationPacketUnpacksSeveralNALUnitsInOrder() throws {
        var depacketizer = H265Depacketizer()
        let ap: [UInt8] = [0x60, 0x01,
                           0x00, 0x06, 0x40, 0x01, 0x0C, 0x01, 0xFF, 0xFF,
                           0x00, 0x08, 0x42, 0x01, 0x01, 0x01, 0x60, 0x00, 0x00, 0x03,
                           0x00, 0x04, 0x44, 0x01, 0xC1, 0x72]
        #expect(ap.count == 26)
        let slice = DepacketizerFixture.h265Slice(type: 19, firstSlice: true, body: [0x07])

        var events: [DepacketizerEvent] = []
        events += depacketizer.push(DepacketizerFixture.packet(ap, sequence: 1, timestamp: 900),
                                    at: DepacketizerFixture.instant(0)).events
        _ = depacketizer.push(DepacketizerFixture.packet(slice, sequence: 2, timestamp: 900),
                              at: DepacketizerFixture.instant(1))
        let frames = depacketizer.flush(at: DepacketizerFixture.instant(40))

        let nals = try #require(DepacketizerFixture.splitLengthPrefixed(try #require(frames.first).data))
        #expect(nals == [DepacketizerFixture.h265VPS, DepacketizerFixture.h265SPS,
                         DepacketizerFixture.h265PPS, slice])
        let sets = try #require(DepacketizerFixture.parameterSetChanges(events).last)
        #expect(sets.vps == [Data(DepacketizerFixture.h265VPS)])
        #expect(sets.sps == [Data(DepacketizerFixture.h265SPS)])
        #expect(sets.pps == [Data(DepacketizerFixture.h265PPS)])
        #expect(sets.codec == .h265)
    }

    /// docs/spec-rtp.md §15.4, the DONL variant: a 16-bit DONL before the first unit and an 8-bit
    /// DOND before each one after it. Missing that shift corrupts every packet silently.
    @Test func h265AggregationPacketWithDONLUnpacksIdentically() throws {
        var depacketizer = H265Depacketizer(usesDONL: true)
        let ap: [UInt8] = [0x60, 0x01, 0x00, 0x2A,
                           0x00, 0x06, 0x40, 0x01, 0x0C, 0x01, 0xFF, 0xFF,
                           0x07, 0x00, 0x08, 0x42, 0x01, 0x01, 0x01, 0x60, 0x00, 0x00, 0x03,
                           0x05, 0x00, 0x04, 0x44, 0x01, 0xC1, 0x72]
        #expect(ap.count == 30)

        let events = depacketizer.push(DepacketizerFixture.packet(ap, sequence: 1, timestamp: 900),
                                       at: DepacketizerFixture.instant(0)).events
        _ = depacketizer.push(DepacketizerFixture.packet(DepacketizerFixture.h265Slice(type: 19,
                                                                                        firstSlice: true),
                                                         sequence: 2, timestamp: 4500),
                              at: DepacketizerFixture.instant(40))
        let sets = try #require(DepacketizerFixture.parameterSetChanges(events).last)
        #expect(sets.vps == [Data(DepacketizerFixture.h265VPS)])
        #expect(sets.sps == [Data(DepacketizerFixture.h265SPS)])
        #expect(sets.pps == [Data(DepacketizerFixture.h265PPS)])
    }

    /// An aggregation unit whose declared size overruns the payload is rejected, and the units that
    /// were already extracted are kept.
    @Test func h265AggregationPacketWithAnOversizedSubLengthIsRejectedSafely() {
        var depacketizer = H265Depacketizer()
        let ap: [UInt8] = [0x60, 0x01, 0x00, 0x04, 0x44, 0x01, 0xC1, 0x72, 0x00, 0x40, 0x42, 0x01]
        let out = depacketizer.push(DepacketizerFixture.packet(ap, sequence: 1, timestamp: 900),
                                    at: DepacketizerFixture.instant(0))
        #expect(DepacketizerFixture.malformedReasons(out.events).contains(.truncatedAggregate))
        #expect(out.frames.isEmpty)
    }

    /// An aggregation unit shorter than the two-byte NAL header cannot be a NAL unit.
    @Test func h265AggregationPacketWithAOneByteUnitIsRejected() {
        var depacketizer = H265Depacketizer()
        let ap: [UInt8] = [0x60, 0x01, 0x00, 0x01, 0x44]
        let out = depacketizer.push(DepacketizerFixture.packet(ap, sequence: 1, timestamp: 900),
                                    at: DepacketizerFixture.instant(0))
        #expect(DepacketizerFixture.malformedReasons(out.events).contains(.zeroLengthAggregate))
    }

    // MARK: - Hostile and degenerate input

    /// A DONL that runs past the end of the payload is rejected rather than read out of bounds.
    @Test func h265DONLRunningPastTheEndIsRejected() {
        var fragment = H265Depacketizer(usesDONL: true)
        let fragmentOut = fragment.push(DepacketizerFixture.packet([0x62, 0x01, 0x00, 0x2A],
                                                                   sequence: 1, timestamp: 900),
                                        at: DepacketizerFixture.instant(0))
        #expect(DepacketizerFixture.malformedReasons(fragmentOut.events) == [.truncatedFragment])
        #expect(fragmentOut.frames.isEmpty)

        var aggregate = H265Depacketizer(usesDONL: true)
        let aggregateOut = aggregate.push(DepacketizerFixture.packet([0x60, 0x01, 0x00],
                                                                     sequence: 1, timestamp: 900),
                                          at: DepacketizerFixture.instant(0))
        #expect(DepacketizerFixture.malformedReasons(aggregateOut.events) == [.truncatedAggregate])
    }

    /// A payload shorter than the two-byte PayloadHdr, and an empty one, are both dropped.
    @Test func h265ShortPayloadIsReportedAndDropped() {
        for payload in [[UInt8](), [0x62]] {
            var depacketizer = H265Depacketizer()
            let out = depacketizer.push(DepacketizerFixture.packet(payload, sequence: 1,
                                                                   timestamp: 900),
                                        at: DepacketizerFixture.instant(0))
            #expect(DepacketizerFixture.malformedReasons(out.events) == [.emptyPayload])
            #expect(out.frames.isEmpty)
        }
    }

    /// PACI and the reserved packet types are reported once and dropped, never half-parsed.
    @Test func h265PACIAndReservedTypesAreReportedAsUnsupported() {
        for type: UInt8 in [50, 51, 63] {
            var depacketizer = H265Depacketizer()
            let out = depacketizer.push(DepacketizerFixture.packet([(type << 1) & 0x7E, 0x01, 0x00],
                                                                   sequence: 1, timestamp: 900),
                                        at: DepacketizerFixture.instant(0))
            #expect(DepacketizerFixture.unsupportedFeatures(out.events) == [.packetizationType(type)])
            #expect(out.frames.isEmpty)
        }
    }

    /// A NAL with a non-zero `nuh_layer_id` is a scalable or multiview layer. It is dropped, because
    /// handing it to VideoToolbox risks a decoder malfunction.
    @Test func h265NonBaseLayerNALIsDropped() {
        var depacketizer = H265Depacketizer()
        // layerID 1 lives in the low bit of byte 0 and the top five bits of byte 1.
        let out = depacketizer.push(DepacketizerFixture.packet([0x26, 0x09, 0xAF, 0x11],
                                                               sequence: 1, timestamp: 900),
                                    at: DepacketizerFixture.instant(0))
        #expect(DepacketizerFixture.unsupportedFeatures(out.events) == [.nonBaseLayer(1)])
        #expect(out.frames.isEmpty)
    }

    /// Types 32, 33 and 34 are VPS, SPS and PPS; 16 through 23 are IRAP and therefore keyframes.
    @Test func h265TypeClassificationMatchesTheStandard() throws {
        for type: UInt8 in 16...23 {
            var depacketizer = H265Depacketizer()
            let nal = DepacketizerFixture.h265Slice(type: type, firstSlice: true, body: [0x01])
            _ = depacketizer.push(DepacketizerFixture.packet(nal, sequence: 1, timestamp: 900),
                                  at: DepacketizerFixture.instant(0))
            let frames = depacketizer.flush(at: DepacketizerFixture.instant(40))
            #expect(try #require(frames.first).isKeyframe, "type \(type) must be an IRAP")
        }
    }

    /// RASL pictures that follow the CRA a stream started on reference pictures that do not exist,
    /// so they are dropped until a non-RASL picture arrives.
    @Test func h265RASLAfterCRAIsDropped() throws {
        var depacketizer = H265Depacketizer()
        let cra = DepacketizerFixture.h265Slice(type: 21, firstSlice: true, body: [0x01])
        let rasl = DepacketizerFixture.h265Slice(type: 8, firstSlice: true, body: [0x02])
        let trail = DepacketizerFixture.h265Slice(type: 1, firstSlice: true, body: [0x03])

        var frames: [EncodedFrame] = []
        var events: [DepacketizerEvent] = []
        for (index, nal) in [cra, rasl, trail].enumerated() {
            let out = depacketizer.push(DepacketizerFixture.packet(nal, sequence: UInt16(index),
                                                                   timestamp: UInt32(index) * 3600),
                                        at: DepacketizerFixture.instant(index * 40))
            frames += out.frames
            events += out.events
        }
        frames += depacketizer.flush(at: DepacketizerFixture.instant(200))

        #expect(frames.count == 2)                        // the CRA and the trailing picture
        #expect(try #require(frames.first).isKeyframe)
        let dropped = events.contains { event in
            if case .accessUnitDropped(let reason) = event { reason == .raslAfterCRA } else { false }
        }
        #expect(dropped)
    }

    /// Ten thousand pseudo-random payloads must not crash or produce a malformed frame buffer.
    @Test func h265RandomPayloadsNeverCrashOrEmitCorruptFrames() {
        for usesDONL in [false, true] {
            var depacketizer = H265Depacketizer(configuration: DepacketizerFixture.ungatedLive,
                                                usesDONL: usesDONL)
            var seed: UInt64 = 0x2025_0726_ABCD_EF01
            func next() -> UInt64 {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return seed >> 16
            }
            for index in 0..<5_000 {
                let length = Int(next() % 40)
                var payload = [UInt8]()
                payload.reserveCapacity(length)
                for _ in 0..<length { payload.append(UInt8(truncatingIfNeeded: next())) }
                let out = depacketizer.push(
                    DepacketizerFixture.packet(payload,
                                               sequence: UInt16(truncatingIfNeeded: index),
                                               timestamp: UInt32(index)),
                    at: DepacketizerFixture.instant(index))
                for frame in out.frames {
                    #expect(DepacketizerFixture.splitLengthPrefixed(frame.data) != nil)
                }
            }
        }
    }

    /// `sprop-max-don-diff` only turns DONL on when it parses as a positive integer.
    @Test func h265DONLDetectionReadsSpropMaxDonDiff() {
        #expect(!H265Depacketizer.usesDONL(fmtp: [:]))
        #expect(!H265Depacketizer.usesDONL(fmtp: ["sprop-max-don-diff": "0"]))
        #expect(!H265Depacketizer.usesDONL(fmtp: ["sprop-max-don-diff": "notanumber"]))
        #expect(H265Depacketizer.usesDONL(fmtp: ["sprop-max-don-diff": "1"]))
        #expect(H265Depacketizer.usesDONL(fmtp: ["sprop-max-don-diff": " 3 "]))
    }
}
