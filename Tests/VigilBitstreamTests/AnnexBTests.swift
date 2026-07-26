//
//  AnnexBTests.swift
//  VigilBitstreamTests
//
//  Start-code scanning, both conversions, emulation-prevention handling and the hostile
//  length-prefix cases: T-EP-1…3, T-AB-1…4 and T-LP-1 of docs/spec-bitstream.md §23.7.
//

import Foundation
import Testing

import VigilBitstream
import VigilProtocols

@Suite("Annex-B, RBSP and length-prefixed conversion")
struct AnnexBTests {

    // MARK: - Fixtures

    /// The 47-byte Annex-B stream of docs/spec-bitstream.md §5.4, byte for byte.
    ///
    /// 4-byte start code + SPS (22 B, vector V1) + 4-byte start code + PPS (4 B, vector P1) +
    /// **3-byte** start code + IDR slice (10 B). The IDR carries `00 00 03 01`, an
    /// emulation-prevention sequence the scanner must not mistake for a start code.
    static let specWorkedExampleAnnexB: [UInt8] = [
        0x00, 0x00, 0x00, 0x01, 0x67, 0x4D, 0x00, 0x28, 0xF4, 0x03, 0xC0, 0x11,
        0x3F, 0x2E, 0x02, 0x20, 0x00, 0x00, 0x03, 0x00, 0x20, 0x00, 0x00, 0x06,
        0x50, 0x80, 0x00, 0x00, 0x00, 0x01, 0x68, 0xEE, 0x3C, 0x80, 0x00, 0x00,
        0x01, 0x65, 0x88, 0x84, 0x04, 0xBF, 0x00, 0x00, 0x03, 0x01, 0xAA,
    ]

    /// The 48-byte length-prefixed form of the same stream, from docs/spec-bitstream.md §5.4.
    static let specWorkedExampleLengthPrefixed: [UInt8] = [
        0x00, 0x00, 0x00, 0x16, 0x67, 0x4D, 0x00, 0x28, 0xF4, 0x03, 0xC0, 0x11,
        0x3F, 0x2E, 0x02, 0x20, 0x00, 0x00, 0x03, 0x00, 0x20, 0x00, 0x00, 0x06,
        0x50, 0x80, 0x00, 0x00, 0x00, 0x04, 0x68, 0xEE, 0x3C, 0x80, 0x00, 0x00,
        0x00, 0x0A, 0x65, 0x88, 0x84, 0x04, 0xBF, 0x00, 0x00, 0x03, 0x01, 0xAA,
    ]

    private func ranges(_ bytes: [UInt8]) -> [[UInt8]] {
        AnnexB.nalRanges(bytes).map { Array(bytes[$0]) }
    }

    private func unescape(_ bytes: [UInt8], header: Int = 0) throws -> [UInt8] {
        try bytes.withUnsafeBytes { try RBSP.unescape($0, skippingHeaderBytes: header) }
    }

    private func escapeCount(_ bytes: [UInt8], header: Int) -> Int {
        bytes.withUnsafeBytes { RBSP.escapeByteCount($0, skippingHeaderBytes: header) }
    }

    private func validate(_ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBytes { LengthPrefixed.validate($0) }
    }

    // MARK: - T-AB-1: the scanner

    @Test func annexBFindsAThreeByteStartCode() {
        let bytes: [UInt8] = [0x00, 0x00, 0x01, 0x65, 0xAA]
        bytes.withUnsafeBytes { raw in
            let found = AnnexB.findStartCode(in: raw, from: 0)
            #expect(found?.index == 0)
            #expect(found?.length == 3)
        }
    }

    @Test func annexBFindsAFourByteStartCode() {
        let bytes: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x65, 0xAA]
        bytes.withUnsafeBytes { raw in
            let found = AnnexB.findStartCode(in: raw, from: 0)
            #expect(found?.index == 0)
            #expect(found?.length == 4)
        }
    }

    @Test func annexBReturnsNilWithoutAStartCode() {
        let bytes: [UInt8] = [0x65, 0x88, 0x00, 0x00, 0x03, 0x01, 0xAA]
        bytes.withUnsafeBytes { raw in
            #expect(AnnexB.findStartCode(in: raw, from: 0) == nil)
        }
        // Too short to hold a prefix at all.
        let tooShort: [UInt8] = [0x00, 0x00]
        tooShort.withUnsafeBytes { raw in
            #expect(AnnexB.findStartCode(in: raw, from: 0) == nil)
        }
    }

    /// A capture joined mid-NAL: the leading garbage is skipped and the first real NAL is found.
    @Test func annexBSkipsLeadingBytesWhenTheStreamStartsMidNAL() {
        let bytes: [UInt8] = [0xAA, 0xBB, 0xCC, 0x00, 0x00, 0x01, 0x65, 0x11]
        bytes.withUnsafeBytes { raw in
            let found = AnnexB.findStartCode(in: raw, from: 0)
            #expect(found?.index == 3)
            #expect(found?.length == 3)
        }
        #expect(ranges(bytes) == [[0x65, 0x11]])
    }

    // MARK: - T-AB-2: trailing zeros

    /// docs/spec-bitstream.md §23.7 T-AB-2 verbatim. H.264 §7.4.1 forbids a NAL ending in `0x00`,
    /// so every trailing zero can be trimmed unconditionally.
    @Test func annexBTrimsTrailingZeroBytes() {
        let bytes: [UInt8] = [0x00, 0x00, 0x01, 0x65, 0xAA, 0x00,
                              0x00, 0x00, 0x00, 0x01, 0x41, 0xBB]
        #expect(ranges(bytes) == [[0x65, 0xAA], [0x41, 0xBB]])
    }

    /// Two adjacent start codes bracket a zero-length NAL, which is reported as no NAL at all.
    @Test func annexBSkipsAnEmptyNALBetweenAdjacentStartCodes() {
        let bytes: [UInt8] = [0x00, 0x00, 0x01, 0x00, 0x00, 0x01, 0x41, 0xBB]
        #expect(ranges(bytes) == [[0x41, 0xBB]])
    }

    @Test func annexBEnumeratesTheSpecWorkedExample() {
        let found = ranges(AnnexBTests.specWorkedExampleAnnexB)
        #expect(found.count == 3)
        #expect(found[0].count == 22)                       // SPS, vector V1
        #expect(found[1] == [0x68, 0xEE, 0x3C, 0x80])       // PPS, vector P1
        #expect(found[2] == [0x65, 0x88, 0x84, 0x04, 0xBF, 0x00, 0x00, 0x03, 0x01, 0xAA])
    }

    // MARK: - T-AB-3: conversion and round trip

    @Test func annexBConvertsTheSpecWorkedExampleToLengthPrefixed() {
        let converted = AnnexB.toLengthPrefixed(AnnexBTests.specWorkedExampleAnnexB)
        #expect(Array(converted) == AnnexBTests.specWorkedExampleLengthPrefixed)
    }

    /// The emulation-prevention sequences inside the SPS and the IDR survive both conversions: they
    /// are payload, not framing, and the scanner must never treat `00 00 03` as `00 00 01`.
    @Test func annexBRoundTripsThroughLengthPrefixedAndBack() throws {
        let prefixed = AnnexB.toLengthPrefixed(AnnexBTests.specWorkedExampleAnnexB)
        let back = try AnnexB.fromLengthPrefixed(prefixed, startCodeLength: 4)

        // Not byte-identical to the input: its third start code was three bytes long and this one
        // is four. The NAL payloads, and therefore the length-prefixed form, are identical.
        #expect(back.count == AnnexBTests.specWorkedExampleAnnexB.count + 1)
        #expect(ranges(back) == ranges(AnnexBTests.specWorkedExampleAnnexB))
        #expect(Array(AnnexB.toLengthPrefixed(back)) == AnnexBTests.specWorkedExampleLengthPrefixed)
    }

    @Test func annexBEmitsThreeByteStartCodesOnRequest() throws {
        let annexB = try AnnexB.fromLengthPrefixed(
            Data(AnnexBTests.specWorkedExampleLengthPrefixed), startCodeLength: 3)
        #expect(Array(annexB.prefix(3)) == [0x00, 0x00, 0x01])
        #expect(ranges(annexB) == ranges(AnnexBTests.specWorkedExampleAnnexB))
    }

    @Test func annexBRejectsAnUnsupportedStartCodeLength() {
        let data = Data(AnnexBTests.specWorkedExampleLengthPrefixed)
        #expect(throws: BitstreamError.unsupportedSyntax("start code length 2, expected 3 or 4")) {
            _ = try AnnexB.fromLengthPrefixed(data, startCodeLength: 2)
        }
    }

    // MARK: - T-AB-4: the in-place conversion

    /// The §5.4 stream mixes 3- and 4-byte start codes, so an in-place rewrite is impossible and the
    /// buffer must come back untouched.
    @Test func annexBInPlaceConversionRefusesMixedStartCodeLengths() {
        var buffer = AnnexBTests.specWorkedExampleAnnexB
        #expect(AnnexB.toLengthPrefixedInPlace(&buffer) == false)
        #expect(buffer == AnnexBTests.specWorkedExampleAnnexB)
    }

    @Test func annexBInPlaceConversionRewritesAnAllFourByteStream() {
        var buffer: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x67, 0xAA, 0xBB,
                               0x00, 0x00, 0x00, 0x01, 0x68, 0xCC]
        #expect(AnnexB.toLengthPrefixedInPlace(&buffer))
        #expect(buffer == [0x00, 0x00, 0x00, 0x03, 0x67, 0xAA, 0xBB,
                           0x00, 0x00, 0x00, 0x02, 0x68, 0xCC])
    }

    /// A trailing zero would have to be trimmed, which changes the byte count, so the in-place path
    /// must decline rather than produce a length that disagrees with the payload.
    @Test func annexBInPlaceConversionRefusesWhenTrailingZerosNeedTrimming() {
        let original: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x67, 0xAA, 0x00]
        var buffer = original
        #expect(AnnexB.toLengthPrefixedInPlace(&buffer) == false)
        #expect(buffer == original)
    }

    @Test func annexBInPlaceConversionRefusesAnEmptyBuffer() {
        var buffer = [UInt8]()
        #expect(AnnexB.toLengthPrefixedInPlace(&buffer) == false)
        #expect(buffer.isEmpty)
    }

    // MARK: - T-LP-1: hostile length prefixes

    /// A NAL length field larger than the buffer must throw at the offset of the offending prefix,
    /// never read past the end.
    @Test func lengthPrefixedRejectsALengthLargerThanTheBuffer() {
        let bytes: [UInt8] = [0x00, 0x00, 0x10, 0x00, 0x65, 0xAA]
        #expect(throws: BitstreamError.truncatedLengthPrefix(atOffset: 0)) {
            _ = try AnnexB.fromLengthPrefixed(Data(bytes))
        }
        #expect(validate(bytes) == false)
    }

    @Test func lengthPrefixedRejectsAZeroLengthNAL() {
        let bytes: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x65, 0xAA]
        #expect(throws: BitstreamError.truncatedLengthPrefix(atOffset: 0)) {
            _ = try AnnexB.fromLengthPrefixed(Data(bytes))
        }
        var buffer = bytes
        #expect(throws: BitstreamError.truncatedLengthPrefix(atOffset: 0)) {
            try AnnexB.fromLengthPrefixedInPlace(&buffer)
        }
    }

    @Test func lengthPrefixedRejectsAnIncompleteFinalPrefix() {
        let bytes: [UInt8] = [0x00, 0x00, 0x00, 0x02, 0x65, 0xAA, 0x00, 0x00]
        #expect(throws: BitstreamError.truncatedLengthPrefix(atOffset: 6)) {
            _ = try AnnexB.fromLengthPrefixed(Data(bytes))
        }
    }

    @Test func lengthPrefixedInPlaceRewritesEveryPrefixAsAStartCode() throws {
        var buffer = AnnexBTests.specWorkedExampleLengthPrefixed
        try AnnexB.fromLengthPrefixedInPlace(&buffer)
        #expect(buffer.count == AnnexBTests.specWorkedExampleLengthPrefixed.count)
        #expect(ranges(buffer) == ranges(AnnexBTests.specWorkedExampleAnnexB))
    }

    @Test func lengthPrefixedValidatesAWellFormedStream() {
        #expect(validate(AnnexBTests.specWorkedExampleLengthPrefixed))
        #expect(validate([]))                           // no NAL units is degenerate, not corrupt
    }

    @Test func lengthPrefixedEnumerateReportsRangesAndTypeCodes() throws {
        var seen = [(Range<Int>, UInt8)]()
        try AnnexBTests.specWorkedExampleLengthPrefixed.withUnsafeBytes { raw in
            try LengthPrefixed.enumerate(raw, codec: .h264) { range, typeCode in
                seen.append((range, typeCode))
            }
        }
        #expect(seen.map(\.1) == [7, 8, 5])
        #expect(seen.map { $0.0.count } == [22, 4, 10])
    }

    @Test func lengthPrefixedAppendWritesAFourByteBigEndianLength() {
        var writer = ByteWriter()
        let nal: [UInt8] = [0x67, 0xAA, 0xBB]
        nal.withUnsafeBytes { raw in
            LengthPrefixed.append(nal: raw, to: &writer)
        }
        #expect(writer.bytes == [0x00, 0x00, 0x00, 0x03, 0x67, 0xAA, 0xBB])
    }

    // MARK: - T-EP-1: escape / unescape round trips

    /// Every row of the escape table in docs/spec-bitstream.md §6, both directions.
    @Test("escape/unescape round-trips the spec §6 table", arguments: [
        ([UInt8]([0x00, 0x00, 0x00, 0x01]), [UInt8]([0x00, 0x00, 0x03, 0x00, 0x01])),
        ([0x00, 0x00, 0x00], [0x00, 0x00, 0x03, 0x00]),
        ([0x00, 0x00, 0x00, 0x00, 0x00], [0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00]),
        ([0x67, 0x64, 0x00, 0x28, 0x00, 0x00, 0x01],
         [0x67, 0x64, 0x00, 0x28, 0x00, 0x00, 0x03, 0x01]),
        ([0x00, 0x03], [0x00, 0x03]),
        ([0x00, 0x00, 0x03], [0x00, 0x00, 0x03, 0x03]),
        ([0x00, 0x00, 0x03, 0x00], [0x00, 0x00, 0x03, 0x03, 0x00]),
    ])
    func rbspEscapeMatchesSpecTable(raw: [UInt8], onWire: [UInt8]) throws {
        #expect(RBSP.escape(raw) == onWire)
        let recovered = try unescape(onWire)
        #expect(recovered == raw)
    }

    /// The unescape-only rows of docs/spec-bitstream.md §6.
    @Test("unescape matches the spec §6 one-way table", arguments: [
        ([UInt8]([0x00, 0x00, 0x03, 0x00]), [UInt8]([0x00, 0x00, 0x00])),
        ([0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x03, 0x00],
         [0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
        ([0x65, 0x88, 0x84, 0x04, 0xBF, 0x00, 0x00, 0x03, 0x01],
         [0x65, 0x88, 0x84, 0x04, 0xBF, 0x00, 0x00, 0x01]),
    ])
    func rbspUnescapeMatchesSpecTable(onWire: [UInt8], raw: [UInt8]) throws {
        let recovered = try unescape(onWire)
        #expect(recovered == raw)
    }

    /// T-EP-2: a NAL whose payload ends in `00 00 03`. The encoder must append that `0x03` because
    /// a NAL may not end in `0x00`, so unescaping drops it even with no byte following.
    @Test func rbspUnescapeDropsATrailingEmulationByte() throws {
        let nal: [UInt8] = [0x65, 0x88, 0x00, 0x00, 0x03]
        let rbsp = try unescape(nal, header: 1)
        #expect(rbsp == [0x88, 0x00, 0x00])
    }

    /// T-EP-3: the strict form refuses to drop a `0x03` followed by a byte above `0x03`. A
    /// conforming encoder cannot produce that sequence, so dropping it would corrupt data from
    /// non-conforming firmware rather than repair it.
    @Test func rbspUnescapeKeepsAnEmulationByteFollowedByAHighByte() throws {
        let nal: [UInt8] = [0x65, 0x00, 0x00, 0x03, 0x04]
        let rbsp = try unescape(nal, header: 1)
        #expect(rbsp == [0x00, 0x00, 0x03, 0x04])
    }

    /// The escape sequence straddles the boundary between two NAL units: `00 00 03 01` ends the
    /// first NAL and the next four bytes are a real start code. Neither may be confused with the
    /// other, and the trailing-zero trim must not reach back into the escape.
    @Test func rbspHandlesAnEmulationSequenceAgainstANALBoundary() throws {
        let stream: [UInt8] = [
            0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x00, 0x00, 0x03, 0x01,
            0x00, 0x00, 0x00, 0x01, 0x41, 0xBB,
        ]
        let found = ranges(stream)
        #expect(found == [[0x65, 0x88, 0x00, 0x00, 0x03, 0x01], [0x41, 0xBB]])
        let rbsp = try unescape(found[0], header: 1)
        #expect(rbsp == [0x88, 0x00, 0x00, 0x01])
    }

    @Test func rbspCountsEmulationBytesWithoutAllocating() {
        let nal: [UInt8] = [0x67, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x03, 0x01]
        #expect(escapeCount(nal, header: 1) == 2)
        #expect(escapeCount(nal, header: 99) == 0)
    }

    // MARK: - Hostile NAL sizes

    @Test func rbspUnescapeRejectsAZeroLengthNAL() {
        #expect(throws: BitstreamError.emptyNALUnit) { _ = try unescape([]) }
        // A NAL that is nothing but its own header has no RBSP either.
        #expect(throws: BitstreamError.emptyNALUnit) { _ = try unescape([0x67], header: 1) }
    }

    @Test func rbspUnescapeRefusesANALAboveTheSizeCap() {
        let huge = [UInt8](repeating: 0xAA, count: Limits.maxUnescapeBytes + 1)
        #expect(throws: BitstreamError.tooLarge(bytes: Limits.maxUnescapeBytes + 1)) {
            _ = try unescape(huge, header: 1)
        }
    }
}
