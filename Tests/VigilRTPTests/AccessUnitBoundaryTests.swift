//
//  AccessUnitBoundaryTests.swift
//  VigilRTPTests
//
//  The regression suite for docs/spec-rtp.md §7: access-unit boundaries come from the RTP timestamp
//  and the slice header, never from the marker bit. Hikvision firmware in the field sets the marker
//  on no packet, on every packet, and one packet early, so each of those is driven here explicitly.
//

import Foundation
import Testing

import VigilProtocols
@testable import VigilRTP

@Suite struct AccessUnitBoundaryTests {

    // MARK: - The marker bit is never trusted

    /// **The single most important test in this target.**
    ///
    /// Some DS-2CD2xxx H.265 builds and several H.264 sub-streams never set the marker bit at all.
    /// A depacketizer that waited for it would never close an access unit: the pipeline would stall
    /// and memory would grow without bound, and the symptom on screen would look like a decode
    /// failure rather than a depacketization one.
    ///
    /// Forty single-slice pictures are pushed with `marker == false` on every packet. Exactly forty
    /// access units must come out, correctly bounded and in order, driven by the timestamp change
    /// and `first_mb_in_slice` alone. Forty is deliberately past the thirty-two access units the
    /// single-slice shortcut needs, so both the pre-learning and post-learning paths are covered.
    @Test func boundaryMarkerNeverSetStillProducesOneAccessUnitPerPicture() throws {
        var depacketizer = H264Depacketizer()
        var frames: [EncodedFrame] = []
        let pictures = 40

        for index in 0..<pictures {
            let nal = DepacketizerFixture.h264Slice(type: index == 0 ? 5 : 1,
                                                    firstMacroblock: true,
                                                    body: [UInt8(index), 0xEE])
            let packet = DepacketizerFixture.packet(nal,
                                                    sequence: UInt16(100 + index),
                                                    timestamp: UInt32(index) * 3600,
                                                    marker: false)
            frames += depacketizer.push(packet, at: DepacketizerFixture.instant(index * 40)).frames
        }
        frames += depacketizer.flush(at: DepacketizerFixture.instant(pictures * 40))

        #expect(frames.count == pictures)
        for (index, frame) in frames.enumerated() {
            #expect(frame.pts.value == Int64(index) * 3600)
            #expect(frame.pts.timescale == 90_000)
            #expect(frame.nalCount == 1)
            #expect(!frame.isCorrupt)
            #expect(frame.accessUnitIndex == UInt64(index))
            let nals = try #require(DepacketizerFixture.splitLengthPrefixed(frame.data))
            #expect(nals.count == 1)
            #expect(nals[0][1] == 0x88)                  // first_mb_in_slice == 0 survived intact
        }
        #expect(frames[0].isKeyframe)
        // Never set means never clean, so the marker is demoted rather than believed.
        #expect(depacketizer.boundaryPolicy.markerTrust == .learnedUnreliable)
    }

    /// The same guarantee when every picture is fragmented, which is the shape a real 1080p stream
    /// takes: the marker is never set and each access unit still closes on the next timestamp.
    @Test func boundaryMarkerNeverSetWithFragmentedSlicesStillBounded() throws {
        var depacketizer = H264Depacketizer()
        var frames: [EncodedFrame] = []
        var sequence: UInt16 = 500
        var expected: [[UInt8]] = []

        for index in 0..<10 {
            let nal = DepacketizerFixture.h264Slice(type: index == 0 ? 5 : 1,
                                                    firstMacroblock: true,
                                                    body: [UInt8(index), 0xA1, 0xB2, 0xC3, 0xD4])
            expected.append(nal)
            for fragment in DepacketizerFixture.h264FragmentUnits(nal, chunk: 2) {
                let packet = DepacketizerFixture.packet(fragment, sequence: sequence,
                                                        timestamp: UInt32(index) * 3600,
                                                        marker: false)
                sequence &+= 1
                frames += depacketizer.push(packet, at: DepacketizerFixture.instant(index * 40)).frames
            }
        }
        frames += depacketizer.flush(at: DepacketizerFixture.instant(1000))

        #expect(frames.count == 10)
        for (index, frame) in frames.enumerated() {
            let nals = try #require(DepacketizerFixture.splitLengthPrefixed(frame.data))
            #expect(nals == [expected[index]])
            #expect(!frame.isCorrupt)
        }
    }

    /// Older DS-2DExxx firmware sets the marker on *every* packet. Believing it would turn every
    /// fragment into its own access unit and flood the decoder with truncated NAL units.
    @Test func boundaryMarkerOnEveryPacketDoesNotSplitPictures() throws {
        var depacketizer = H264Depacketizer()
        let nal = DepacketizerFixture.h264Slice(type: 5, firstMacroblock: true,
                                                body: [0x01, 0x02, 0x03, 0x04, 0x05, 0x06])
        var frames: [EncodedFrame] = []
        var sequence: UInt16 = 10

        for fragment in DepacketizerFixture.h264FragmentUnits(nal, chunk: 2) {
            let packet = DepacketizerFixture.packet(fragment, sequence: sequence, timestamp: 9000,
                                                    marker: true)
            sequence &+= 1
            frames += depacketizer.push(packet, at: DepacketizerFixture.instant(0)).frames
        }
        #expect(frames.isEmpty)                          // nothing closed on a marker alone

        frames += depacketizer.flush(at: DepacketizerFixture.instant(40))
        let frame = try #require(frames.first)
        #expect(frames.count == 1)
        let nals = try #require(DepacketizerFixture.splitLengthPrefixed(frame.data))
        #expect(nals == [nal])
    }

    /// A marker set in the middle of a picture must not split the access unit, and must demote the
    /// marker rather than the picture.
    @Test func boundaryMarkerMidPictureDoesNotSplitAccessUnit() throws {
        var depacketizer = H264Depacketizer()
        let nal = DepacketizerFixture.h264Slice(type: 5, firstMacroblock: true,
                                                body: [0xAA, 0xBB, 0xCC, 0xDD])
        let fragments = DepacketizerFixture.h264FragmentUnits(nal, chunk: 2)
        #expect(fragments.count == 3)

        var frames: [EncodedFrame] = []
        for (index, fragment) in fragments.enumerated() {
            let packet = DepacketizerFixture.packet(fragment, sequence: UInt16(20 + index),
                                                    timestamp: 9000, marker: index == 1)
            frames += depacketizer.push(packet, at: DepacketizerFixture.instant(index)).frames
        }
        #expect(frames.isEmpty)

        frames += depacketizer.flush(at: DepacketizerFixture.instant(40))
        #expect(frames.count == 1)
        let nals = try #require(DepacketizerFixture.splitLengthPrefixed(frames[0].data))
        #expect(nals == [nal])
    }

    /// A multi-slice picture whose firmware marks the end of *each* slice. `first_mb_in_slice != 0`
    /// on the second slice is what keeps the two together.
    @Test func boundaryMultiSlicePictureStaysOneAccessUnit() throws {
        var depacketizer = H264Depacketizer()
        let first = DepacketizerFixture.h264Slice(type: 5, firstMacroblock: true, body: [0x01])
        let second = DepacketizerFixture.h264Slice(type: 5, firstMacroblock: false, body: [0x02])

        var frames: [EncodedFrame] = []
        frames += depacketizer.push(DepacketizerFixture.packet(first, sequence: 1, timestamp: 9000,
                                                               marker: true),
                                    at: DepacketizerFixture.instant(0)).frames
        frames += depacketizer.push(DepacketizerFixture.packet(second, sequence: 2, timestamp: 9000,
                                                               marker: true),
                                    at: DepacketizerFixture.instant(1)).frames
        #expect(frames.isEmpty)

        frames += depacketizer.flush(at: DepacketizerFixture.instant(40))
        let frame = try #require(frames.first)
        #expect(frames.count == 1)
        #expect(frame.nalCount == 2)
        let nals = try #require(DepacketizerFixture.splitLengthPrefixed(frame.data))
        #expect(nals == [first, second])
        #expect(depacketizer.boundaryPolicy.sliceProfile == .multiSlice)
    }

    /// Two pictures that share an RTP timestamp — seen on NVR playback streams that re-mux two
    /// channels — must split on the slice header (open rule O4), not merge into one huge unit.
    @Test func boundaryTwoPicturesSharingATimestampSplitOnSliceHeader() throws {
        var depacketizer = H264Depacketizer(configuration: DepacketizerFixture.ungatedLive)
        let first = DepacketizerFixture.h264Slice(type: 1, firstMacroblock: true, body: [0x01])
        let second = DepacketizerFixture.h264Slice(type: 1, firstMacroblock: true, body: [0x02])

        var frames: [EncodedFrame] = []
        frames += depacketizer.push(DepacketizerFixture.packet(first, sequence: 1, timestamp: 9000),
                                    at: DepacketizerFixture.instant(0)).frames
        frames += depacketizer.push(DepacketizerFixture.packet(second, sequence: 2, timestamp: 9000),
                                    at: DepacketizerFixture.instant(1)).frames
        frames += depacketizer.flush(at: DepacketizerFixture.instant(40))

        #expect(frames.count == 2)
        let firstNALs = try #require(DepacketizerFixture.splitLengthPrefixed(frames[0].data))
        let secondNALs = try #require(DepacketizerFixture.splitLengthPrefixed(frames[1].data))
        #expect(firstNALs == [first])
        #expect(secondNALs == [second])
    }

    /// A parameter set arriving after slices of the same timestamp starts a new access unit
    /// (open rule O3), because a decoder must not see configuration inside a picture it postdates.
    @Test func boundaryPrefixNALAfterSlicesStartsNewAccessUnit() throws {
        var depacketizer = H264Depacketizer()
        let slice = DepacketizerFixture.h264Slice(type: 5, firstMacroblock: true, body: [0x01])

        var frames: [EncodedFrame] = []
        frames += depacketizer.push(DepacketizerFixture.packet(slice, sequence: 1, timestamp: 9000),
                                    at: DepacketizerFixture.instant(0)).frames
        #expect(frames.isEmpty)
        let out = depacketizer.push(DepacketizerFixture.packet(DepacketizerFixture.h264SPS,
                                                               sequence: 2, timestamp: 9000),
                                    at: DepacketizerFixture.instant(1))
        frames += out.frames
        #expect(frames.count == 1)
        let nals = try #require(DepacketizerFixture.splitLengthPrefixed(frames[0].data))
        #expect(nals == [slice])
    }

    // MARK: - Timeout and learning

    /// An access unit that stops receiving packets is force-closed rather than held forever. This
    /// is the backstop that makes "never trust the marker" safe on a stream that simply stops.
    @Test func boundaryIdleAccessUnitIsForceClosedByTheTimeout() throws {
        var depacketizer = H264Depacketizer()
        let slice = DepacketizerFixture.h264Slice(type: 5, firstMacroblock: true, body: [0x01])
        _ = depacketizer.push(DepacketizerFixture.packet(slice, sequence: 1, timestamp: 9000),
                              at: DepacketizerFixture.instant(0))

        #expect(depacketizer.tick(at: DepacketizerFixture.instant(100)).frames.isEmpty)
        let closed = depacketizer.tick(at: DepacketizerFixture.instant(250))
        #expect(closed.frames.count == 1)
        #expect(depacketizer.accessUnitDeadline == nil)
    }

    /// A marker that lands on exactly the last packet of every access unit is eventually promoted,
    /// and the promotion is reported so the diagnostics panel can explain the latency change.
    @Test func boundaryCleanMarkerIsLearnedReliableAndReported() throws {
        var depacketizer = H264Depacketizer()
        var events: [DepacketizerEvent] = []
        var sequence: UInt16 = 0

        for index in 0..<40 {
            let nal = DepacketizerFixture.h264Slice(type: index == 0 ? 5 : 1,
                                                    firstMacroblock: true,
                                                    body: [UInt8(index), 0x11, 0x22])
            let fragments = DepacketizerFixture.h264FragmentUnits(nal, chunk: 2)
            for (offset, fragment) in fragments.enumerated() {
                let packet = DepacketizerFixture.packet(fragment, sequence: sequence,
                                                        timestamp: UInt32(index) * 3600,
                                                        marker: offset == fragments.count - 1)
                sequence &+= 1
                events += depacketizer.push(packet, at: DepacketizerFixture.instant(index * 40)).events
            }
        }

        #expect(depacketizer.boundaryPolicy.markerTrust == .learnedReliable)
        let transitions = events.compactMap { event -> MarkerTrust? in
            if case .boundaryPolicyChanged(_, let marker) = event { marker } else { nil }
        }
        #expect(transitions.contains(.learnedReliable))
    }

    /// `.never` pins the marker untrusted for the life of the stream; `.always` pins it trusted.
    /// Both are debug switches, and neither is what production uses.
    @Test func boundaryConfiguredMarkerTrustPinsThePolicy() {
        var never = BoundaryPolicy(policy: .never)
        #expect(never.markerTrust == .learnedUnreliable)
        _ = never.noteClosedAccessUnit(vclCount: 1, markerWasClean: true)
        #expect(never.markerTrust == .learnedUnreliable)

        var always = BoundaryPolicy(policy: .always)
        #expect(always.markerTrust == .learnedReliable)
        _ = always.noteClosedAccessUnit(vclCount: 1, markerWasClean: false)
        #expect(always.markerTrust == .learnedReliable)
    }

    /// Two disagreements demote the marker permanently, and no run of clean access units shorter
    /// than 128 brings it back.
    @Test func boundaryPolicyDemotesMarkerAfterTwoViolations() {
        var policy = BoundaryPolicy(policy: .adaptive)
        _ = policy.noteClosedAccessUnit(vclCount: 1, markerWasClean: false)
        #expect(policy.markerTrust == .untrusted)
        _ = policy.noteClosedAccessUnit(vclCount: 1, markerWasClean: false)
        #expect(policy.markerTrust == .learnedUnreliable)

        for _ in 0..<100 { _ = policy.noteClosedAccessUnit(vclCount: 1, markerWasClean: true) }
        #expect(policy.markerTrust == .learnedUnreliable)
        for _ in 0..<40 { _ = policy.noteClosedAccessUnit(vclCount: 1, markerWasClean: true) }
        #expect(policy.markerTrust == .learnedReliable)
    }

    /// A `reset` puts every learned belief back to where a fresh stream starts.
    @Test func boundaryPolicyResetForgetsEverythingLearned() {
        var policy = BoundaryPolicy(policy: .adaptive)
        for _ in 0..<64 { _ = policy.noteClosedAccessUnit(vclCount: 1, markerWasClean: true) }
        #expect(policy.sliceProfile == .singleSlicePerPicture)
        #expect(policy.markerTrust == .learnedReliable)

        policy.reset()
        #expect(policy.sliceProfile == .unknown)
        #expect(policy.markerTrust == .untrusted)
        #expect(!policy.allowsMarkerFastPath)
        #expect(!policy.allowsSingleSliceFastPath)
    }

    /// A slice of a picture we already emitted proves the close was wrong. Both shortcuts must be
    /// switched off and a keyframe requested — this is the DS-7616 early-marker self-correction.
    @Test func boundaryPrematureCloseSelfCorrectsAndRequestsAKeyframe() throws {
        var depacketizer = H264Depacketizer(configuration: DepacketizerConfiguration(
            waitForKeyframeOnStart: false, trustMarkerBit: .always))
        let first = DepacketizerFixture.h264Slice(type: 1, firstMacroblock: true, body: [0x01])
        let second = DepacketizerFixture.h264Slice(type: 1, firstMacroblock: false, body: [0x02])

        let emitted = depacketizer.push(DepacketizerFixture.packet(first, sequence: 1,
                                                                   timestamp: 9000, marker: true),
                                        at: DepacketizerFixture.instant(0))
        #expect(emitted.frames.count == 1)

        let late = depacketizer.push(DepacketizerFixture.packet(second, sequence: 2,
                                                                timestamp: 9000),
                                     at: DepacketizerFixture.instant(1))
        #expect(DepacketizerFixture.malformedReasons(late.events).contains(.prematureAccessUnitClose))
        #expect(depacketizer.boundaryPolicy.sliceProfile == .multiSlice)
        let wantsKeyframe = late.events.contains { event in
            if case .keyframeNeeded = event { true } else { false }
        }
        #expect(wantsKeyframe)
    }
}
