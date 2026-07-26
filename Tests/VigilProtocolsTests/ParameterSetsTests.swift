//
//  ParameterSetsTests.swift
//  VigilProtocolsTests
//
//  Canonical storage form, CoreMedia ordering, completeness, equality and the FNV-1a fingerprint.
//  Covers docs/API_CONTRACT.md §3.5.
//
//  The byte strings below are hand-built NAL units with correct headers and plausible payloads; they
//  are fixtures, not captures from a camera. Only the NAL header bytes carry meaning here.
//

import Foundation
import Testing
import VigilProtocols

@Suite struct ParameterSetsTests {

    /// H.264 SPS: `nal_ref_idc = 3`, `nal_unit_type = 7` -> 0x67.
    private static let h264SPS = Data([0x67, 0x64, 0x00, 0x28, 0xAC, 0xD9, 0x40, 0x78])

    /// H.264 PPS: `nal_ref_idc = 3`, `nal_unit_type = 8` -> 0x68.
    private static let h264PPS = Data([0x68, 0xEE, 0x3C, 0xB0])

    /// H.265 VPS: two-byte header, `nal_unit_type = 32` -> 0x40 0x01.
    private static let h265VPS = Data([0x40, 0x01, 0x0C, 0x01, 0xFF, 0xFF])

    /// H.265 SPS: `nal_unit_type = 33` -> 0x42 0x01.
    private static let h265SPS = Data([0x42, 0x01, 0x01, 0x01, 0x60, 0x00])

    /// H.265 PPS: `nal_unit_type = 34` -> 0x44 0x01.
    private static let h265PPS = Data([0x44, 0x01, 0xC1, 0x72, 0xB4, 0x62, 0x40])

    // MARK: - Construction and completeness

    @Test func parameterSetsDefaultsToEmptyArrays() {
        let sets = ParameterSets(codec: .h264)
        #expect(sets.vps.isEmpty)
        #expect(sets.sps.isEmpty)
        #expect(sets.pps.isEmpty)
        #expect(!sets.isComplete)
    }

    @Test func parameterSetsWithEmptySPSIsRepresentable() {
        // An SDP may legitimately omit `sprop-parameter-sets`; the sets then arrive in band before
        // the first IDR, and until they do this value must be constructible and simply incomplete.
        let sets = ParameterSets(codec: .h264, sps: [], pps: [Self.h264PPS])
        #expect(sets.sps.isEmpty)
        #expect(!sets.isComplete)
        #expect(sets.orderedForCoreMedia == [Self.h264PPS])
        #expect(sets == ParameterSets(codec: .h264, sps: [], pps: [Self.h264PPS]))
    }

    @Test func parameterSetsWithASingleEmptyDataElementIsNotTheSameAsNoElement() {
        let empty = ParameterSets(codec: .h264, sps: [Data()], pps: [Self.h264PPS])
        let absent = ParameterSets(codec: .h264, sps: [], pps: [Self.h264PPS])
        #expect(empty != absent)
        #expect(empty.isComplete, "isComplete counts elements, not bytes")
    }

    @Test func parameterSetsIsCompleteNeedsBothSPSAndPPS() {
        #expect(!ParameterSets(codec: .h264, sps: [Self.h264SPS]).isComplete)
        #expect(!ParameterSets(codec: .h264, pps: [Self.h264PPS]).isComplete)
        #expect(ParameterSets(codec: .h264, sps: [Self.h264SPS], pps: [Self.h264PPS]).isComplete)
        // VPS is not required by `isComplete`, even for H.265.
        #expect(ParameterSets(codec: .h265, sps: [Self.h265SPS], pps: [Self.h265PPS]).isComplete)
    }

    // MARK: - CoreMedia ordering

    @Test func parameterSetsOrderForH264IsSPSThenPPS() {
        let sets = ParameterSets(codec: .h264, vps: [], sps: [Self.h264SPS], pps: [Self.h264PPS])
        #expect(sets.orderedForCoreMedia == [Self.h264SPS, Self.h264PPS])
    }

    @Test func parameterSetsOrderForH265IsVPSThenSPSThenPPS() {
        let sets = ParameterSets(codec: .h265, vps: [Self.h265VPS],
                                 sps: [Self.h265SPS], pps: [Self.h265PPS])
        #expect(sets.orderedForCoreMedia == [Self.h265VPS, Self.h265SPS, Self.h265PPS])
    }

    @Test func parameterSetsOrderIgnoresVPSForH264EvenIfPresent() {
        // A camera that sends a VPS on an H.264 track is malformed; we must not feed it to CoreMedia.
        let sets = ParameterSets(codec: .h264, vps: [Self.h265VPS],
                                 sps: [Self.h264SPS], pps: [Self.h264PPS])
        #expect(sets.orderedForCoreMedia == [Self.h264SPS, Self.h264PPS])
    }

    @Test func parameterSetsPreservesMultipleSetsInGivenOrder() {
        let secondPPS = Data([0x68, 0xEE, 0x3C, 0xB1])
        let sets = ParameterSets(codec: .h264, sps: [Self.h264SPS], pps: [Self.h264PPS, secondPPS])
        #expect(sets.orderedForCoreMedia == [Self.h264SPS, Self.h264PPS, secondPPS])
    }

    // MARK: - Equality and hashing

    @Test func parameterSetsEqualityComparesEveryFieldByteForByte() {
        let base = ParameterSets(codec: .h264, sps: [Self.h264SPS], pps: [Self.h264PPS])
        #expect(base == ParameterSets(codec: .h264, sps: [Self.h264SPS], pps: [Self.h264PPS]))
        #expect(base != ParameterSets(codec: .h265, sps: [Self.h264SPS], pps: [Self.h264PPS]))
        #expect(base != ParameterSets(codec: .h264, sps: [Self.h264PPS], pps: [Self.h264SPS]))
        var oneBitOff = Self.h264SPS
        oneBitOff[oneBitOff.count - 1] ^= 0x01
        #expect(base != ParameterSets(codec: .h264, sps: [oneBitOff], pps: [Self.h264PPS]))
    }

    @Test func parameterSetsEqualValuesHashEqually() {
        let a = ParameterSets(codec: .h265, vps: [Self.h265VPS], sps: [Self.h265SPS],
                              pps: [Self.h265PPS])
        let b = ParameterSets(codec: .h265, vps: [Self.h265VPS], sps: [Self.h265SPS],
                              pps: [Self.h265PPS])
        #expect(a.hashValue == b.hashValue)
        #expect(Set([a, b]).count == 1)
    }

    @Test func parameterSetsRoundTripsThroughCodable() throws {
        let original = ParameterSets(codec: .h265, vps: [Self.h265VPS], sps: [Self.h265SPS],
                                     pps: [Self.h265PPS])
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ParameterSets.self, from: encoded)
        #expect(decoded == original)
        #expect(decoded.fingerprint == original.fingerprint)
    }

    // MARK: - Fingerprint

    @Test func parameterSetsFingerprintOfEmptySetsIsTheFNVOffsetBasis() {
        #expect(ParameterSets(codec: .h264).fingerprint == 0xCBF2_9CE4_8422_2325)
    }

    @Test func parameterSetsFingerprintIsStableForEqualValues() {
        let a = ParameterSets(codec: .h264, sps: [Self.h264SPS], pps: [Self.h264PPS])
        let b = ParameterSets(codec: .h264, sps: [Self.h264SPS], pps: [Self.h264PPS])
        #expect(a.fingerprint == b.fingerprint)
    }

    @Test func parameterSetsFingerprintChangesWhenOneByteChanges() {
        let base = ParameterSets(codec: .h264, sps: [Self.h264SPS], pps: [Self.h264PPS])
        var changed = Self.h264SPS
        changed[3] ^= 0x01                                     // a resolution change in a real SPS
        let other = ParameterSets(codec: .h264, sps: [changed], pps: [Self.h264PPS])
        #expect(base.fingerprint != other.fingerprint)
    }

    @Test func parameterSetsFingerprintMatchesAHandComputedFNV1a() {
        // FNV-1a 64, offset basis 0xcbf29ce484222325, prime 0x100000001b3, over the two NAL units
        // in `orderedForCoreMedia` order. Computed here by the same definition, independently.
        let sets = ParameterSets(codec: .h264, sps: [Self.h264SPS], pps: [Self.h264PPS])
        var expected: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in Array(Self.h264SPS) + Array(Self.h264PPS) {
            expected = (expected ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        #expect(sets.fingerprint == expected)
    }

    @Test func parameterSetsFingerprintTracksTheCoreMediaOrderForH265() {
        let withVPS = ParameterSets(codec: .h265, vps: [Self.h265VPS], sps: [Self.h265SPS],
                                    pps: [Self.h265PPS])
        let withoutVPS = ParameterSets(codec: .h265, sps: [Self.h265SPS], pps: [Self.h265PPS])
        #expect(withVPS.fingerprint != withoutVPS.fingerprint)
    }
}
