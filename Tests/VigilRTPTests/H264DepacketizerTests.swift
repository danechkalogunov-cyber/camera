//
//  H264DepacketizerTests.swift
//  VigilRTPTests
//
//  RFC 6184 framing: single NAL packets, STAP-A, FU-A, the loss cases, and hostile input. The
//  packet vectors are the ones in docs/spec-rtp.md §15.2 and §15.3.
//

import Foundation
import Testing

import VigilProtocols
@testable import VigilRTP

@Suite struct H264DepacketizerTests {

    // MARK: - Fragmentation

    /// docs/spec-rtp.md §15.3. Three FU-A packets reassemble to `65 AA BB CC DD EE FF`: the
    /// original NAL header takes F and NRI from the FU indicator (`0x7C & 0xE0`) and its type from
    /// the FU header (`0x85 & 0x1F`).
    @Test func h264FragmentUnitsReassembleByteIdenticallyToTheOriginalNAL() throws {
        var depacketizer = H264Depacketizer()
        let payloads: [[UInt8]] = [[0x7C, 0x85, 0xAA, 0xBB],
                                   [0x7C, 0x05, 0xCC, 0xDD],
                                   [0x7C, 0x45, 0xEE, 0xFF]]
        var frames: [EncodedFrame] = []
        for (index, payload) in payloads.enumerated() {
            let packet = DepacketizerFixture.packet(payload, sequence: UInt16(100 + index),
                                                    timestamp: 679_056)
            frames += depacketizer.push(packet, at: DepacketizerFixture.instant(index)).frames
        }
        frames += depacketizer.flush(at: DepacketizerFixture.instant(40))

        let frame = try #require(frames.first)
        #expect(frames.count == 1)
        #expect(frame.isKeyframe)
        #expect(frame.nalCount == 1)
        #expect(frame.dropClass == .required)
        // 4-byte big-endian length prefix, never a start code.
        #expect([UInt8](frame.data) == [0x00, 0x00, 0x00, 0x07,
                                        0x65, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
    }

    /// A one-packet fragment run (`S` and `E` both set) is legal and appears on some NVR streams.
    @Test func h264SingleFragmentUnitIsAccepted() throws {
        var depacketizer = H264Depacketizer()
        let out = depacketizer.push(DepacketizerFixture.packet([0x7C, 0xC5, 0xAA, 0xBB],
                                                               sequence: 1, timestamp: 900),
                                    at: DepacketizerFixture.instant(0))
        #expect(out.frames.isEmpty)
        let frames = depacketizer.flush(at: DepacketizerFixture.instant(40))
        #expect(frames.count == 1)
        #expect([UInt8](try #require(frames.first).data) == [0, 0, 0, 3, 0x65, 0xAA, 0xBB])
    }

    /// A lost **first** fragment must discard the whole run: emitting the remainder would hand the
    /// decoder a slice with no NAL header.
    @Test func h264LostFirstFragmentDiscardsTheRunAndEmitsNothing() {
        var depacketizer = H264Depacketizer()
        var events: [DepacketizerEvent] = []
        var frames: [EncodedFrame] = []
        for (index, payload) in [[0x7C, 0x05, 0xCC, 0xDD], [0x7C, 0x45, 0xEE, 0xFF]].enumerated() {
            let out = depacketizer.push(DepacketizerFixture.packet(payload,
                                                                   sequence: UInt16(101 + index),
                                                                   timestamp: 679_056),
                                        at: DepacketizerFixture.instant(index))
            frames += out.frames
            events += out.events
        }
        frames += depacketizer.flush(at: DepacketizerFixture.instant(40))

        #expect(frames.isEmpty)
        #expect(DepacketizerFixture.malformedReasons(events).contains(.lostFirstFragment))
    }

    /// A lost **middle** fragment: the run is discarded, the loss is counted, and no truncated NAL
    /// reaches the decoder.
    @Test func h264LostMiddleFragmentDiscardsTheRunAndCountsTheLoss() {
        var depacketizer = H264Depacketizer()
        var events: [DepacketizerEvent] = []
        var frames: [EncodedFrame] = []
        // Sequence 101 never arrives, so the E fragment's sequence number does not follow the S.
        for (payload, sequence) in [([0x7C, 0x85, 0xAA, 0xBB], UInt16(100)),
                                    ([0x7C, 0x45, 0xEE, 0xFF], UInt16(102))] {
            let out = depacketizer.push(DepacketizerFixture.packet(payload, sequence: sequence,
                                                                   timestamp: 679_056),
                                        at: DepacketizerFixture.instant(0))
            frames += out.frames
            events += out.events
        }
        frames += depacketizer.flush(at: DepacketizerFixture.instant(40))

        #expect(frames.isEmpty)
        #expect(DepacketizerFixture.malformedReasons(events).contains(.fragmentGap))
        let wantsKeyframe = events.contains { if case .keyframeNeeded = $0 { true } else { false } }
        #expect(wantsKeyframe)
    }

    /// A lost **last** fragment leaves the run open; the next timestamp closes the access unit and
    /// the incomplete NAL is dropped rather than emitted short.
    @Test func h264LostLastFragmentDropsTheAccessUnit() {
        var depacketizer = H264Depacketizer()
        var events: [DepacketizerEvent] = []
        var frames: [EncodedFrame] = []
        for (index, payload) in [[0x7C, 0x85, 0xAA, 0xBB], [0x7C, 0x05, 0xCC, 0xDD]].enumerated() {
            let out = depacketizer.push(DepacketizerFixture.packet(payload,
                                                                   sequence: UInt16(100 + index),
                                                                   timestamp: 679_056),
                                        at: DepacketizerFixture.instant(index))
            frames += out.frames
            events += out.events
        }
        let next = depacketizer.push(DepacketizerFixture.packet([0x7C, 0x85, 0x11, 0x22],
                                                                sequence: 102, timestamp: 682_656),
                                     at: DepacketizerFixture.instant(40))
        frames += next.frames
        events += next.events

        #expect(frames.isEmpty)
        #expect(DepacketizerFixture.malformedReasons(events).contains(.incompleteFragmentAtAUEnd))
    }

    /// An FU header claiming a packet type that cannot itself be fragmented is rejected outright.
    @Test func h264FragmentUnitClaimingAnUnfragmentableTypeIsRejected() {
        var depacketizer = H264Depacketizer()
        var reasons: [MalformedReason] = []
        for claimed: UInt8 in [24, 28, 29, 0, 31] {
            var fresh = H264Depacketizer()
            let out = fresh.push(DepacketizerFixture.packet([0x7C, 0x80 | claimed, 0xAA],
                                                            sequence: 1, timestamp: 900),
                                 at: DepacketizerFixture.instant(0))
            reasons += DepacketizerFixture.malformedReasons(out.events)
            #expect(out.frames.isEmpty)
        }
        _ = depacketizer
        #expect(reasons.allSatisfy { $0 == .nestedPacketization })
        #expect(reasons.count == 5)
    }

    // MARK: - Aggregation

    /// docs/spec-rtp.md §15.2. A STAP-A carrying SPS and PPS unpacks both in order, and they are
    /// surfaced as parameter sets rather than being buried in the next frame's bytes.
    @Test func h264STAPAUnpacksSeveralNALUnitsInOrder() throws {
        var depacketizer = H264Depacketizer()
        let stap: [UInt8] = [0x78, 0x00, 0x0A,
                             0x67, 0x4D, 0x00, 0x29, 0x95, 0xA8, 0x1E, 0x00, 0x89, 0xF9,
                             0x00, 0x04, 0x68, 0xEE, 0x3C, 0xB0]
        let slice = DepacketizerFixture.h264Slice(type: 5, firstMacroblock: true, body: [0x77])

        var events: [DepacketizerEvent] = []
        events += depacketizer.push(DepacketizerFixture.packet(stap, sequence: 1, timestamp: 900),
                                    at: DepacketizerFixture.instant(0)).events
        events += depacketizer.push(DepacketizerFixture.packet(slice, sequence: 2, timestamp: 900),
                                    at: DepacketizerFixture.instant(1)).events
        // The next timestamp closes the access unit, which is where its events surface.
        let closing = depacketizer.push(DepacketizerFixture.packet(slice, sequence: 3,
                                                                   timestamp: 4500),
                                        at: DepacketizerFixture.instant(40))
        events += closing.events

        let frame = try #require(closing.frames.first)
        #expect(frame.nalCount == 3)
        let nals = try #require(DepacketizerFixture.splitLengthPrefixed(frame.data))
        #expect(nals == [DepacketizerFixture.h264SPS, DepacketizerFixture.h264PPS, slice])
        #expect([UInt8](frame.data.prefix(14)) == [0x00, 0x00, 0x00, 0x0A] +
                DepacketizerFixture.h264SPS)

        let sets = try #require(DepacketizerFixture.parameterSetChanges(events).last)
        #expect(sets.sps == [Data(DepacketizerFixture.h264SPS)])
        #expect(sets.pps == [Data(DepacketizerFixture.h264PPS)])
        #expect(sets.codec == .h264)
    }

    /// Parameter sets that arrive in band as an access unit of their own are surfaced through the
    /// event stream and the next frame's `parameterSets`, and produce no frame of their own.
    @Test func h264InBandParameterSetsAreSurfacedWithoutAFrameOfTheirOwn() throws {
        var depacketizer = H264Depacketizer()
        let stap = DepacketizerFixture.h264STAPA([DepacketizerFixture.h264SPS,
                                                  DepacketizerFixture.h264PPS])
        let slice = DepacketizerFixture.h264Slice(type: 5, firstMacroblock: true, body: [0x55])

        let first = depacketizer.push(DepacketizerFixture.packet(stap, sequence: 1, timestamp: 900),
                                      at: DepacketizerFixture.instant(0))
        #expect(first.frames.isEmpty)

        let second = depacketizer.push(DepacketizerFixture.packet(slice, sequence: 2,
                                                                  timestamp: 4500),
                                       at: DepacketizerFixture.instant(40))
        // Closing the parameter-set-only unit surfaces the sets and emits no frame for them.
        #expect(second.frames.isEmpty)
        #expect(DepacketizerFixture.parameterSetChanges(second.events).count == 1)

        let frames = depacketizer.flush(at: DepacketizerFixture.instant(80))
        let frame = try #require(frames.first)
        let attached = try #require(frame.parameterSets)
        #expect(attached.sps == [Data(DepacketizerFixture.h264SPS)])
        let nals = try #require(DepacketizerFixture.splitLengthPrefixed(frame.data))
        #expect(nals == [slice])                          // the sets were not mixed into the frame
    }

    /// An aggregate whose declared sub-length runs past the end of the payload keeps what it has
    /// already extracted, discards the remainder and reports the truncation.
    @Test func h264STAPAWithAnOversizedSubLengthIsRejectedSafely() {
        var depacketizer = H264Depacketizer()
        let stap: [UInt8] = [0x78, 0x00, 0x04, 0x68, 0xEE, 0x3C, 0xB0, 0x00, 0x40, 0x67, 0x4D]
        let out = depacketizer.push(DepacketizerFixture.packet(stap, sequence: 1, timestamp: 900),
                                    at: DepacketizerFixture.instant(0))
        #expect(DepacketizerFixture.malformedReasons(out.events).contains(.truncatedAggregate))
        #expect(out.frames.isEmpty)
    }

    /// A zero-length aggregation unit is malformed; the loop must stop rather than spin.
    @Test func h264STAPAWithAZeroLengthUnitIsRejected() {
        var depacketizer = H264Depacketizer()
        let stap: [UInt8] = [0x78, 0x00, 0x00, 0x67, 0x4D]
        let out = depacketizer.push(DepacketizerFixture.packet(stap, sequence: 1, timestamp: 900),
                                    at: DepacketizerFixture.instant(0))
        #expect(DepacketizerFixture.malformedReasons(out.events).contains(.zeroLengthAggregate))
        #expect(out.frames.isEmpty)
    }

    /// MTAP16 and MTAP24 only make sense in interleaved mode, which Hikvision never offers. They
    /// are reported once and dropped, never half-parsed.
    @Test func h264MTAPPacketsAreReportedAsUnsupported() {
        for type: UInt8 in [26, 27] {
            var depacketizer = H264Depacketizer()
            let out = depacketizer.push(DepacketizerFixture.packet([0x60 | type, 0x00, 0x02, 0x67,
                                                                    0x4D],
                                                                   sequence: 1, timestamp: 900),
                                        at: DepacketizerFixture.instant(0))
            #expect(DepacketizerFixture.unsupportedFeatures(out.events) == [.aggregationType(type)])
            #expect(out.frames.isEmpty)
        }
    }

    /// STAP-B carries a DON before the first size field. It is parsed for alignment, discarded, and
    /// the interleaved mode is reported once.
    @Test func h264STAPBSkipsItsDecodingOrderNumber() throws {
        var depacketizer = H264Depacketizer()
        var payload: [UInt8] = [0x79, 0x00, 0x2A]
        payload += [0x00, UInt8(DepacketizerFixture.h264PPS.count)] + DepacketizerFixture.h264PPS
        let slice = DepacketizerFixture.h264Slice(type: 5, firstMacroblock: true, body: [0x09])

        let out = depacketizer.push(DepacketizerFixture.packet(payload, sequence: 1, timestamp: 900),
                                    at: DepacketizerFixture.instant(0))
        #expect(DepacketizerFixture.unsupportedFeatures(out.events) == [.interleavedMode])
        _ = depacketizer.push(DepacketizerFixture.packet(slice, sequence: 2, timestamp: 900),
                              at: DepacketizerFixture.instant(1))
        let frames = depacketizer.flush(at: DepacketizerFixture.instant(40))
        let nals = try #require(DepacketizerFixture.splitLengthPrefixed(try #require(frames.first).data))
        #expect(nals == [DepacketizerFixture.h264PPS, slice])
    }

    // MARK: - Hostile and degenerate input

    /// A zero-length payload is reported and dropped, never indexed into.
    @Test func h264ZeroLengthPayloadIsReportedAndDropped() {
        var depacketizer = H264Depacketizer()
        let out = depacketizer.push(DepacketizerFixture.packet([], sequence: 1, timestamp: 900),
                                    at: DepacketizerFixture.instant(0))
        #expect(DepacketizerFixture.malformedReasons(out.events) == [.emptyPayload])
        #expect(out.frames.isEmpty)
    }

    /// The forbidden zero bit must never be set. A NAL that sets it is dropped.
    @Test func h264ForbiddenBitSetIsDropped() {
        var depacketizer = H264Depacketizer()
        let out = depacketizer.push(DepacketizerFixture.packet([0x85, 0x88, 0x11], sequence: 1,
                                                               timestamp: 900),
                                    at: DepacketizerFixture.instant(0))
        #expect(DepacketizerFixture.malformedReasons(out.events) == [.forbiddenBitSet])
        #expect(out.frames.isEmpty)
    }

    /// A fragment payload with nothing after the FU header carries no bytes and is dropped.
    @Test func h264TruncatedFragmentHeaderIsDropped() {
        var depacketizer = H264Depacketizer()
        for payload in [[0x7C], [0x7C, 0x85]] {
            var fresh = H264Depacketizer()
            let out = fresh.push(DepacketizerFixture.packet(payload, sequence: 1, timestamp: 900),
                                 at: DepacketizerFixture.instant(0))
            #expect(DepacketizerFixture.malformedReasons(out.events) == [.truncatedFragment])
            #expect(out.frames.isEmpty)
        }
        _ = depacketizer
    }

    /// Filler data is discarded rather than forwarded: it costs decode bandwidth and carries
    /// nothing a decoder needs.
    @Test func h264FillerDataIsDiscarded() throws {
        var depacketizer = H264Depacketizer()
        let slice = DepacketizerFixture.h264Slice(type: 5, firstMacroblock: true, body: [0x01])
        _ = depacketizer.push(DepacketizerFixture.packet(slice, sequence: 1, timestamp: 900),
                              at: DepacketizerFixture.instant(0))
        _ = depacketizer.push(DepacketizerFixture.packet([0x0C, 0xFF, 0xFF], sequence: 2,
                                                         timestamp: 900),
                              at: DepacketizerFixture.instant(1))
        let frames = depacketizer.flush(at: DepacketizerFixture.instant(40))
        let nals = try #require(DepacketizerFixture.splitLengthPrefixed(try #require(frames.first).data))
        #expect(nals == [slice])
    }

    /// Ten thousand pseudo-random payloads must not crash, hang or emit a malformed frame. The
    /// generator is a fixed-seed LCG so any failure reproduces exactly.
    @Test func h264RandomPayloadsNeverCrashOrEmitCorruptFrames() {
        var depacketizer = H264Depacketizer(configuration: DepacketizerFixture.ungatedLive)
        var seed: UInt64 = 0x5DEE_CE66_D1CE_2025
        func next() -> UInt64 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return seed >> 16
        }
        for index in 0..<10_000 {
            let length = Int(next() % 40)
            var payload = [UInt8]()
            payload.reserveCapacity(length)
            for _ in 0..<length { payload.append(UInt8(truncatingIfNeeded: next())) }
            let sequence = UInt16(truncatingIfNeeded: index)
            let out = depacketizer.push(DepacketizerFixture.packet(payload, sequence: sequence,
                                                                   timestamp: UInt32(index)),
                                        at: DepacketizerFixture.instant(index))
            for frame in out.frames {
                #expect(DepacketizerFixture.splitLengthPrefixed(frame.data) != nil)
            }
        }
    }

    /// `reset` clears the fragment run, the learned policy and the in-band parameter sets, but
    /// keeps the sets that came from the SDP.
    @Test func h264ResetKeepsSDPParameterSetsAndForgetsInBandOnes() {
        let sdpSets = ParameterSets(codec: .h264, sps: [Data([0x67, 0x01])], pps: [Data([0x68, 0x02])])
        var depacketizer = H264Depacketizer(initialParameterSets: sdpSets)
        let stap = DepacketizerFixture.h264STAPA([DepacketizerFixture.h264SPS,
                                                  DepacketizerFixture.h264PPS])
        _ = depacketizer.push(DepacketizerFixture.packet(stap, sequence: 1, timestamp: 900),
                              at: DepacketizerFixture.instant(0))
        _ = depacketizer.push(DepacketizerFixture.packet(stap, sequence: 2, timestamp: 4500),
                              at: DepacketizerFixture.instant(40))
        #expect(depacketizer.parameterSets.sps == [Data(DepacketizerFixture.h264SPS)])

        depacketizer.reset()
        #expect(depacketizer.parameterSets == sdpSets)
        #expect(depacketizer.boundaryPolicy.markerTrust == .untrusted)
        #expect(depacketizer.accessUnitDeadline == nil)
    }

    /// A picture whose every slice is non-reference is droppable under queue pressure; one that
    /// contains a referenced slice is not.
    @Test func h264DropClassFollowsNalRefIdc() throws {
        var depacketizer = H264Depacketizer(configuration: DepacketizerFixture.ungatedLive)
        let disposable = DepacketizerFixture.h264Slice(type: 1, nri: 0, firstMacroblock: true,
                                                       body: [0x01])
        let referenced = DepacketizerFixture.h264Slice(type: 1, nri: 2, firstMacroblock: true,
                                                       body: [0x02])
        _ = depacketizer.push(DepacketizerFixture.packet(disposable, sequence: 1, timestamp: 900),
                              at: DepacketizerFixture.instant(0))
        let second = depacketizer.push(DepacketizerFixture.packet(referenced, sequence: 2,
                                                                  timestamp: 4500),
                                       at: DepacketizerFixture.instant(40))
        #expect(try #require(second.frames.first).dropClass == .droppableNonReference)
        let frames = depacketizer.flush(at: DepacketizerFixture.instant(80))
        #expect(try #require(frames.first).dropClass == .required)
    }
}
