//
//  DecoderConfigurationRecordTests.swift
//  VigilBitstreamTests
//
//  `avcC` and `hvcC`: build, serialize, parse back and compare, against the hex-annotated worked
//  examples in docs/spec-bitstream.md §16.3, §16.4 and §17.1. On Linux this round trip is the only
//  executable regression test of parameter-set handling that exists, so it is exhaustive.
//

import Foundation
import Testing
import VigilProtocols
@testable import VigilBitstream

// MARK: - Fixtures

private enum RecordVector {
    // H.264 §23.2/§23.3
    static let v1 = "Z00AKPQDwBE/LgIgAAADACAAAAZQgA=="
    static let v2 = "Z2QAKawsrAeAIn5cBagICAoAAAMAAgAAAwB5Ht8="
    static let p1 = "aO48gA=="
    static let p2 = "aO48sA=="
    // H.265 §23.4/§23.5
    static let vps = "QAEMAf//AWAAAAMAsAAAAwAAAwB7lwJA"
    static let w1 = "QgEBAWAAAAMAsAAAAwAAAwB7oAPAgBDlll5JG2S7wFqAgICCAAADAAIAAAMAMlcIBBA="
    static let q1 = "RAHh88DMkA=="

    /// §16.3, worked example A — Main profile, no trailing extension, 37 bytes.
    static let r1 = "AU0AKP/hABZnTQAo9APAET8uAiAAAAMAIAAABlCAAQAEaO48gA=="
    /// §16.4, worked example B — High profile with the trailing extension, 48 bytes.
    static let r2 = "AWQAKf/hAB1nZAAprCysB4AiflwFqAgICgAAAwACAAADAHke3wEABGjuPLD9+PgA"
    /// §17.1, the worked `hvcC`, 119 bytes.
    static let r3 = """
        AQFgAAAAsAAAAAAAe/AA/f34+BkATwOgAAEAGEABDAH//wFgAAADALAAAAMAAAMAe5cCQKEAAQAyQgEBAWAAAAMAsA\
        AAAwAAAwB7oAPAgBDlll5JG2S7wFqAgICCAAADAAIAAAMAMlcIBBCiAAEAB0QB4fPAzJA=
        """

    static func data(_ base64: String) -> Data { Data(base64Encoded: base64) ?? Data() }
}

// MARK: - avcC

@Suite struct AVCDecoderConfigurationRecordTests {

    @Test func avcCMatchesWorkedExampleAForMainProfile() throws {
        let record = try AVCDecoderConfigurationRecord(sps: [RecordVector.data(RecordVector.v1)],
                                                       pps: [RecordVector.data(RecordVector.p1)])
        let expected = RecordVector.data(RecordVector.r1)
        #expect(expected.count == 37)
        #expect(record.serialized() == expected)
        // Bytes 1–3 are the SPS's own bytes 1–3, not recomputed from the parsed model.
        #expect(record.avcProfileIndication == 77)
        #expect(record.profileCompatibility == 0x00)
        #expect(record.avcLevelIndication == 40)
        // Profile 77 is outside {100, 110, 122, 144}: no trailing extension.
        #expect(record.chromaFormat == nil)
    }

    @Test func avcCMatchesWorkedExampleBForHighProfileWithExtension() throws {
        let record = try AVCDecoderConfigurationRecord(sps: [RecordVector.data(RecordVector.v2)],
                                                       pps: [RecordVector.data(RecordVector.p2)])
        let expected = RecordVector.data(RecordVector.r2)
        #expect(expected.count == 48)
        #expect(record.serialized() == expected)
        #expect(record.avcProfileIndication == 100)
        #expect(record.avcLevelIndication == 41)
        #expect(record.chromaFormat == 1)
        #expect(record.bitDepthLumaMinus8 == 0)
        #expect(record.bitDepthChromaMinus8 == 0)
        #expect(record.sequenceParameterSetExt.isEmpty)
    }

    @Test func avcCRoundTripsThroughParseAndSerialize() throws {
        for base64 in [RecordVector.r1, RecordVector.r2] {
            let expected = RecordVector.data(base64)
            let parsed = try AVCDecoderConfigurationRecord(parsing: expected)
            #expect(parsed.serialized() == expected)
        }
    }

    @Test func avcCParseRecoversTheExactParameterSetBytes() throws {
        let parsed = try AVCDecoderConfigurationRecord(parsing: RecordVector.data(RecordVector.r1))
        #expect(parsed.sequenceParameterSets == [RecordVector.data(RecordVector.v1)])
        #expect(parsed.pictureParameterSets == [RecordVector.data(RecordVector.p1)])
        let sets = parsed.parameterSets
        #expect(sets.codec == .h264)
        #expect(sets.vps.isEmpty)
        #expect(sets.isComplete)
    }

    @Test func avcCRejectsAnUnknownVersionAndALengthSizeOtherThanThree() throws {
        var wrongVersion = [UInt8](RecordVector.data(RecordVector.r1))
        wrongVersion[0] = 2
        #expect(throws: BitstreamError.unsupportedRecordVersion(2)) {
            try AVCDecoderConfigurationRecord(parsing: Data(wrongVersion))
        }
        var wrongLengthSize = [UInt8](RecordVector.data(RecordVector.r1))
        wrongLengthSize[4] = 0xFD                   // lengthSizeMinusOne = 1
        #expect(throws: BitstreamError.unsupportedLengthSize(1)) {
            try AVCDecoderConfigurationRecord(parsing: Data(wrongLengthSize))
        }
    }

    @Test func avcCRejectsAnEmptyOrStubSPSList() throws {
        #expect(throws: BitstreamError.emptyNALUnit) {
            try AVCDecoderConfigurationRecord(sps: [], pps: [])
        }
        #expect(throws: BitstreamError.emptyNALUnit) {
            try AVCDecoderConfigurationRecord(sps: [Data([0x67, 0x4D])], pps: [])
        }
    }

    @Test func avcCTruncationKeepsWhateverWasFullyRead() throws {
        // Cut the record off in the middle of the PPS array. The SPS we already recovered is the
        // part a decoder needs, so parsing must keep it rather than throw everything away.
        let full = [UInt8](RecordVector.data(RecordVector.r1))
        let parsed = try AVCDecoderConfigurationRecord(parsing: Data(full.prefix(full.count - 2)))
        #expect(parsed.sequenceParameterSets.count == 1)
        #expect(parsed.pictureParameterSets.isEmpty)
    }

    @Test func avcCSurvivesEveryTruncationOfAKnownGoodRecord() {
        let full = [UInt8](RecordVector.data(RecordVector.r2))
        for length in 0 ... full.count {
            _ = try? AVCDecoderConfigurationRecord(parsing: Data(full.prefix(length)))
        }
    }
}

// MARK: - hvcC

@Suite struct HEVCDecoderConfigurationRecordTests {

    private func buildReferenceRecord() throws -> HEVCDecoderConfigurationRecord {
        let spsBytes = [UInt8](RecordVector.data(RecordVector.w1))
        let ppsBytes = [UInt8](RecordVector.data(RecordVector.q1))
        let parsedSPS = try spsBytes.withUnsafeBytes { try H265Parser.parseSPS($0) }
        let parsedPPS = try ppsBytes.withUnsafeBytes { try H265Parser.parsePPS($0) }
        return try HEVCDecoderConfigurationRecord(vps: [RecordVector.data(RecordVector.vps)],
                                                  sps: [RecordVector.data(RecordVector.w1)],
                                                  pps: [RecordVector.data(RecordVector.q1)],
                                                  parsedSPS: parsedSPS, parsedPPS: parsedPPS)
    }

    @Test func hvcCMatchesTheWorkedExampleByteForByte() throws {
        let record = try buildReferenceRecord()
        let expected = RecordVector.data(RecordVector.r3)
        #expect(expected.count == 119)
        #expect(record.serialized() == expected)
    }

    @Test func hvcCFixedHeaderFieldsComeFromTheSPS() throws {
        let record = try buildReferenceRecord()
        #expect(record.ptl.generalProfileIDC == 1)
        #expect(record.ptl.generalProfileCompatibilityFlags == 0x6000_0000)
        #expect(record.ptl.generalConstraintIndicatorFlags == 0xB000_0000_0000)
        #expect(record.ptl.generalLevelIDC == 123)
        #expect(record.minSpatialSegmentationIDC == 0)
        #expect(record.parallelismType == 1)
        #expect(record.chromaFormat == 1)
        #expect(record.bitDepthLumaMinus8 == 0)
        #expect(record.bitDepthChromaMinus8 == 0)
        // frames per 256 seconds: 25 × 256 = 6400 = 0x1900. A factor of 256 out makes QuickTime
        // report a 0.1 fps movie.
        #expect(record.avgFrameRate == 6400)
        #expect(record.constantFrameRate == 1)
        #expect(record.numTemporalLayers == 1)
        #expect(record.temporalIDNested)
        #expect(record.lengthSizeMinusOne == 3)
        #expect(record.arrays.map(\.nalUnitType) == [32, 33, 34])
        let everyArrayComplete = record.arrays.allSatisfy { $0.arrayCompleteness }
        #expect(everyArrayComplete)
    }

    @Test func hvcCStoresEscapedNALBytesWhileTheHeaderHoldsParsedValues() throws {
        let record = try buildReferenceRecord()
        let serialized = [UInt8](record.serialized())
        // Record offsets 6…11: the unescaped 48-bit constraint region.
        #expect(Array(serialized[6 ..< 12]) == [0xB0, 0x00, 0x00, 0x00, 0x00, 0x00])
        // The SPS NAL unit inside the array is still on-wire escaped, so the same field appears
        // there as B0 00 00 03 00 00 03 00. Confusing the two is the second classic hvcC bug.
        let sps = [UInt8](record.nalUnits(ofType: 33).first ?? Data())
        #expect(Array(sps[9 ..< 17]) == [0xB0, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00])
    }

    @Test func hvcCRoundTripsThroughParseAndSerialize() throws {
        let expected = RecordVector.data(RecordVector.r3)
        let parsed = try HEVCDecoderConfigurationRecord(parsing: expected)
        #expect(parsed.serialized() == expected)
        #expect(parsed.nalUnits(ofType: 32) == [RecordVector.data(RecordVector.vps)])
        #expect(parsed.nalUnits(ofType: 33) == [RecordVector.data(RecordVector.w1)])
        #expect(parsed.nalUnits(ofType: 34) == [RecordVector.data(RecordVector.q1)])
        let sets = parsed.parameterSets
        #expect(sets.codec == .h265)
        #expect(sets.vps.count == 1)
        #expect(sets.sps.count == 1)
        #expect(sets.pps.count == 1)
    }

    @Test func hvcCTolerateALyingArrayCount() throws {
        // numOfArrays claims five arrays; only three are present. The parse must yield the three
        // that really exist, without throwing and without allocating from the stated count.
        var bytes = [UInt8](RecordVector.data(RecordVector.r3))
        bytes[22] = 5
        let parsed = try HEVCDecoderConfigurationRecord(parsing: Data(bytes))
        #expect(parsed.arrays.count == 3)
        #expect(parsed.nalUnits(ofType: 33) == [RecordVector.data(RecordVector.w1)])
    }

    @Test func hvcCTolerateALyingNALUnitCount() throws {
        // The VPS array claims 0x0101 NAL units; there is one.
        var bytes = [UInt8](RecordVector.data(RecordVector.r3))
        bytes[24] = 0x01
        bytes[25] = 0x01
        let parsed = try HEVCDecoderConfigurationRecord(parsing: Data(bytes))
        #expect(parsed.arrays.first?.nalUnits.count == 1)
    }

    @Test func hvcCRejectsAnUnknownVersionAndALengthSizeOtherThanThree() throws {
        var wrongVersion = [UInt8](RecordVector.data(RecordVector.r3))
        wrongVersion[0] = 0
        #expect(throws: BitstreamError.unsupportedRecordVersion(0)) {
            try HEVCDecoderConfigurationRecord(parsing: Data(wrongVersion))
        }
        var wrongLengthSize = [UInt8](RecordVector.data(RecordVector.r3))
        wrongLengthSize[21] = 0x4D                  // lengthSizeMinusOne = 1
        #expect(throws: BitstreamError.unsupportedLengthSize(1)) {
            try HEVCDecoderConfigurationRecord(parsing: Data(wrongLengthSize))
        }
    }

    @Test func hvcCRejectsARecordShorterThanItsFixedHeader() {
        let short = Data([UInt8](repeating: 0x01, count: 22))
        #expect(throws: BitstreamError.emptyNALUnit) {
            try HEVCDecoderConfigurationRecord(parsing: short)
        }
    }

    @Test func hvcCSurvivesEveryTruncationOfAKnownGoodRecord() {
        let full = [UInt8](RecordVector.data(RecordVector.r3))
        for length in 0 ... full.count {
            _ = try? HEVCDecoderConfigurationRecord(parsing: Data(full.prefix(length)))
        }
    }

    @Test func hvcCMarksTheSEIArrayIncompleteAndOrdersArraysAscending() throws {
        let spsBytes = [UInt8](RecordVector.data(RecordVector.w1))
        let parsedSPS = try spsBytes.withUnsafeBytes { try H265Parser.parseSPS($0) }
        let record = try HEVCDecoderConfigurationRecord(
            vps: [RecordVector.data(RecordVector.vps)],
            sps: [RecordVector.data(RecordVector.w1)],
            pps: [RecordVector.data(RecordVector.q1)],
            sei: [Data([0x4E, 0x01, 0x06, 0x01, 0xD0, 0x80])],
            parsedSPS: parsedSPS, parsedPPS: nil)
        #expect(record.arrays.map(\.nalUnitType) == [32, 33, 34, 39])
        #expect(record.arrays.last?.arrayCompleteness == false)
        // No PPS was parsed, so parallelismType is the "unknown" 0 every decoder tolerates.
        #expect(record.parallelismType == 0)
        let reparsed = try HEVCDecoderConfigurationRecord(parsing: record.serialized())
        #expect(reparsed.serialized() == record.serialized())
    }
}
