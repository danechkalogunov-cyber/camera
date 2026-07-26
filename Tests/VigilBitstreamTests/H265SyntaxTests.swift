//
//  H265SyntaxTests.swift
//  VigilBitstreamTests
//
//  The H.265 VPS/SPS/PPS regression corpus from docs/spec-bitstream.md §23.4 and §23.5, plus the
//  hostile-input cases. Every expected value below is quoted from that specification; the vectors
//  themselves are the byte-exact fixtures it publishes.
//

import Foundation
import Testing
import VigilProtocols
@testable import VigilBitstream

// MARK: - Fixtures

/// The published H.265 vectors. Base64 exactly as printed in docs/spec-bitstream.md §23.4/§23.5.
private enum HEVCVector {
    static let vps = "QAEMAf//AWAAAAMAsAAAAwAAAwB7lwJA"
    static let w1 = "QgEBAWAAAAMAsAAAAwAAAwB7oAPAgBDlll5JG2S7wFqAgICCAAADAAIAAAMAMlcIBBA="
    static let w2 = "QgEBAWAAAAMAsAAAAwAAAwB7oAPIgBEHEy5ZeSRtm+t14CAgAAADACAAAAMDJRcIBBA="
    static let w3 = "QgEDAWAAAAMAsAAAAwAAAwCWwAABYAAAAwCwAAADAAADAJagAVAgBfFlly8kjbJd4CAgAAADACAAAAMChXCAQQ=="
    static let w4 = "QgEBAiQAAAMAsAAAAwAAAwB7oAPAgBDk2WXkkbZLvAQEAAADAAQAAAMAZK4QCCA="
    static let q1 = "RAHh88DMkA=="
    static let q2 = "RAHh88JLzJA="
    static let q3 = "RAHh88HMkA=="

    /// W1 with `num_short_term_ref_pic_sets` rewritten as `ue(65)`, one past the §4 cap of 64.
    /// **Synthesised for this test** by mutating the RBSP at bit 188 — not a camera capture.
    static let rpsCountTooLarge = "QgEBAWAAAAMAsAAAAwAAAwB7oAPAgBDlll5JG2AhQA=="

    static func bytes(_ base64: String) -> [UInt8] {
        [UInt8](Data(base64Encoded: base64) ?? Data())
    }
}

private func parseHEVCSPS(_ base64: String) throws -> H265SPS {
    try HEVCVector.bytes(base64).withUnsafeBytes { try H265Parser.parseSPS($0) }
}

private func parseHEVCPPS(_ base64: String) throws -> H265PPS {
    try HEVCVector.bytes(base64).withUnsafeBytes { try H265Parser.parsePPS($0) }
}

// MARK: - VPS

@Suite struct H265VPSTests {

    @Test func h265VPSParsesTheReferenceVector() throws {
        let vps = try HEVCVector.bytes(HEVCVector.vps).withUnsafeBytes {
            try H265Parser.parseVPS($0)
        }
        #expect(vps.vpsID == 0)
        #expect(vps.maxLayersMinus1 == 0)
        #expect(vps.maxSubLayersMinus1 == 0)
        #expect(vps.temporalIDNestingFlag)
        #expect(vps.isSingleLayer)
        #expect(vps.numTemporalLayers == 1)
    }

    @Test func h265VPSRejectsAWrongNALType() throws {
        // The SPS vector, handed to the VPS parser.
        #expect(throws: BitstreamError.wrongNALType(expected: 32, found: 33)) {
            try HEVCVector.bytes(HEVCVector.w1).withUnsafeBytes { try H265Parser.parseVPS($0) }
        }
    }

    @Test func h265VPSThrowsOnTruncation() throws {
        // Six bytes: header, the ids, and half of the 0xFFFF canary.
        let truncated = Array(HEVCVector.bytes(HEVCVector.vps).prefix(6))
        #expect(throws: (any Error).self) {
            try truncated.withUnsafeBytes { try H265Parser.parseVPS($0) }
        }
    }

    @Test func h265VPSRejectsACorruptedReservedCanary() throws {
        var bytes = HEVCVector.bytes(HEVCVector.vps)
        bytes[4] = 0xFE                     // vps_reserved_0xffff_16bits, high byte
        #expect(throws: (any Error).self) {
            try bytes.withUnsafeBytes { try H265Parser.parseVPS($0) }
        }
    }
}

// MARK: - SPS

@Suite struct H265SPSParserTests {

    @Test func h265SPSParsesVectorW1() throws {
        let sps = try parseHEVCSPS(HEVCVector.w1)
        #expect(sps.vpsID == 0)
        #expect(sps.maxSubLayersMinus1 == 0)
        #expect(sps.temporalIDNestingFlag)
        #expect(sps.ptl.generalProfileSpace == 0)
        #expect(sps.ptl.generalTierFlag == 0)
        #expect(sps.ptl.generalProfileIDC == 1)
        #expect(sps.ptl.profileName == "Main")
        #expect(sps.ptl.generalProfileCompatibilityFlags == 0x6000_0000)
        #expect(sps.ptl.generalConstraintIndicatorFlags == 0xB000_0000_0000)
        #expect(sps.ptl.generalLevelIDC == 123)
        #expect(sps.ptl.levelName == "4.1")
        #expect(sps.ptl.subLayerLevelIDC.isEmpty)
        #expect(sps.ptl.progressiveSourceFlag)
        #expect(!sps.ptl.interlacedSourceFlag)
        #expect(sps.ptl.nonPackedConstraintFlag)
        #expect(sps.ptl.frameOnlyConstraintFlag)
        #expect(sps.chromaFormatIDC == 1)
        #expect(sps.bitDepthLuma == 8)
        #expect(sps.bitDepthChroma == 8)
        #expect(sps.log2MaxPicOrderCntLsb == 8)
        #expect(sps.codedWidth == 1920)
        #expect(sps.codedHeight == 1080)
        #expect(sps.conformanceWindow.isZero)
        #expect(sps.displayWidth == 1920)
        #expect(sps.displayHeight == 1080)
        #expect(sps.minCbLog2SizeY == 3)
        #expect(sps.ctbLog2SizeY == 6)
        #expect(sps.ctbSizeY == 64)
        #expect(sps.numShortTermRefPicSets == 1)
        #expect(sps.numDeltaPocs == [1])
        #expect(!sps.longTermRefPicsPresent)
        #expect(sps.temporalMVPEnabled)
        #expect(sps.strongIntraSmoothingEnabled)
        #expect(sps.vuiPresent)
        #expect(!sps.vuiParseFailed)
        #expect(sps.numUnitsInTick == 1)
        #expect(sps.timeScale == 25)
        #expect(sps.frameRate == 25.0)
        #expect(sps.sarWidth == 1)
        #expect(sps.sarHeight == 1)
        #expect(sps.minSpatialSegmentationIDC == 0)
        #expect(sps.colourPrimaries == 1)
        #expect(sps.transferCharacteristics == 1)
        #expect(sps.matrixCoefficients == 1)
        #expect(sps.numTemporalLayers == 1)
        // §23.4's strongest single assertion: the parse consumed exactly the right bits, so every
        // skip loop landed on the correct one. The slack is `rbsp_trailing_bits()`.
        #expect(sps.debugBitsConsumed == 339)
        #expect(sps.debugBitsAvailable == 344)
    }

    @Test func h265SPSAppliesTheConformanceWindowInChromaUnits() throws {
        // W2: 1936 − SubWidthC(2) × 8 = 1920, 1088 − SubHeightC(2) × 4 = 1080. The multiply is what
        // separates H.265's conformance window from H.264's already-scaled crop units.
        let sps = try parseHEVCSPS(HEVCVector.w2)
        #expect(sps.codedWidth == 1936)
        #expect(sps.codedHeight == 1088)
        #expect(sps.conformanceWindow == CropOffsets(left: 0, right: 8, top: 0, bottom: 4))
        #expect(sps.subWidthC == 2)
        #expect(sps.subHeightC == 2)
        #expect(sps.displayWidth == 1920)
        #expect(sps.displayHeight == 1080)
        #expect(sps.cropLeft == 0)
        #expect(sps.cropTop == 0)
    }

    @Test func h265SPSConsumesAnInterPredictedShortTermRefPicSet() throws {
        // W2 has two RPSs, the second inter-predicted from the first. NumDeltaPocs[0] == 2, so
        // st_ref_pic_set(1) reads NumDeltaPocs[0] + 1 == 3 flag groups — the inclusive bound —
        // and derives NumDeltaPocs[1] == 3. Treating `0...N` as `0..<N`, or returning
        // NumDeltaPocs[RefRpsIdx] unchanged, mis-parses the VUI and reports the wrong fps.
        let sps = try parseHEVCSPS(HEVCVector.w2)
        #expect(sps.numShortTermRefPicSets == 2)
        #expect(sps.numDeltaPocs == [2, 3])
        #expect(sps.frameRate == 25.0)
        #expect(sps.minSpatialSegmentationIDC == 4)
        #expect(sps.debugBitsConsumed == 339)
        #expect(sps.debugBitsAvailable == 344)
    }

    @Test func h265SPSHandlesTheSubLayerLoopInProfileTierLevel() throws {
        // W3 has sps_max_sub_layers_minus1 == 1: one present-flag pair, then 2 × (8 − 1) = 14 bits
        // of reserved_zero_2bits, then an 88-bit sub-layer profile block and a sub-layer level.
        // Omitting the reserved-bits loop shifts everything and yields a nonsense picture width.
        let sps = try parseHEVCSPS(HEVCVector.w3)
        #expect(sps.maxSubLayersMinus1 == 1)
        #expect(sps.numTemporalLayers == 2)
        #expect(sps.ptl.generalLevelIDC == 150)
        #expect(sps.ptl.levelName == "5.0")
        #expect(sps.ptl.subLayerLevelIDC == [150])
        #expect(sps.codedWidth == 2688)
        #expect(sps.codedHeight == 1520)
        #expect(sps.displayWidth == 2688)
        #expect(sps.displayHeight == 1520)
        #expect(sps.numDeltaPocs == [1])
        #expect(sps.frameRate == 20.0)
        #expect(sps.debugBitsConsumed == 431)
        #expect(sps.debugBitsAvailable == 432)
    }

    @Test func h265SPSParsesMain10() throws {
        let sps = try parseHEVCSPS(HEVCVector.w4)
        #expect(sps.ptl.generalProfileIDC == 2)
        #expect(sps.ptl.profileName == "Main 10")
        #expect(sps.ptl.generalProfileCompatibilityFlags == 0x2400_0000)
        #expect(sps.ptl.generalConstraintIndicatorFlags == 0xB000_0000_0000)
        #expect(sps.bitDepthLuma == 10)
        #expect(sps.bitDepthChroma == 10)
        #expect(sps.codedWidth == 1920)
        #expect(sps.codedHeight == 1080)
        #expect(sps.frameRate == 25.0)
        #expect(sps.debugBitsConsumed == 314)
        #expect(sps.debugBitsAvailable == 320)
    }

    @Test func h265SPSConstraintBytesMatchTheRecordLayout() throws {
        let sps = try parseHEVCSPS(HEVCVector.w1)
        #expect(sps.ptl.constraintIndicatorBytes == [0xB0, 0x00, 0x00, 0x00, 0x00, 0x00])
    }

    @Test func h265SPSRejectsAWrongNALType() throws {
        #expect(throws: BitstreamError.wrongNALType(expected: 33, found: 32)) {
            try HEVCVector.bytes(HEVCVector.vps).withUnsafeBytes { try H265Parser.parseSPS($0) }
        }
    }

    @Test func h265SPSRejectsAnRPSCountBeyondTheLimit() throws {
        #expect(throws: BitstreamError.valueOutOfRange(field: "num_short_term_ref_pic_sets",
                                                       value: 65)) {
            try parseHEVCSPS(HEVCVector.rpsCountTooLarge)
        }
    }

    @Test func h265SPSThrowsOnEveryTruncation() throws {
        // Every proper prefix must throw or return, never crash and never hang.
        let full = HEVCVector.bytes(HEVCVector.w1)
        for length in 0 ..< full.count {
            let prefix = Array(full.prefix(length))
            _ = try? prefix.withUnsafeBytes { try H265Parser.parseSPS($0) }
        }
        #expect(throws: (any Error).self) {
            try Array(full.prefix(12)).withUnsafeBytes { try H265Parser.parseSPS($0) }
        }
    }

    @Test func h265SPSSurvivesSingleBitFlips() throws {
        // A parameter set is reachable from any device on the LAN: every mutation must either
        // parse or throw. Deterministic — every bit of the first 24 bytes, no RNG.
        let full = HEVCVector.bytes(HEVCVector.w1)
        for byteIndex in 0 ..< min(24, full.count) {
            for bit in 0 ..< 8 {
                var mutated = full
                mutated[byteIndex] ^= UInt8(1 << bit)
                _ = try? mutated.withUnsafeBytes { try H265Parser.parseSPS($0) }
            }
        }
    }

    @Test func h265SPSParsesFromBase64() throws {
        let sps = try H265Parser.parseSPS(base64: HEVCVector.w1)
        #expect(sps.codedWidth == 1920)
        #expect(throws: BitstreamError.invalidBase64) {
            try H265Parser.parseSPS(base64: "not base64 !!!")
        }
    }
}

// MARK: - PPS

@Suite struct H265PPSParserTests {

    @Test func h265PPSDerivesParallelismTypeFromTheVectors() throws {
        let q1 = try parseHEVCPPS(HEVCVector.q1)
        #expect(q1.ppsID == 0)
        #expect(q1.spsID == 0)
        #expect(!q1.tilesEnabled)
        #expect(!q1.entropyCodingSyncEnabled)
        #expect(q1.parallelismType == 1)            // slice-based

        let q2 = try parseHEVCPPS(HEVCVector.q2)
        #expect(q2.tilesEnabled)
        #expect(!q2.entropyCodingSyncEnabled)
        #expect(q2.parallelismType == 2)            // tile-based

        let q3 = try parseHEVCPPS(HEVCVector.q3)
        #expect(!q3.tilesEnabled)
        #expect(q3.entropyCodingSyncEnabled)
        #expect(q3.parallelismType == 3)            // wavefront
    }

    @Test func h265PPSReportsUnknownForMixedTilesAndWavefronts() {
        #expect(H265PPS.parallelismType(tilesEnabled: true, entropyCodingSync: true) == 0)
    }

    @Test func h265PPSRejectsAWrongNALType() throws {
        #expect(throws: BitstreamError.wrongNALType(expected: 34, found: 33)) {
            try HEVCVector.bytes(HEVCVector.w1).withUnsafeBytes { try H265Parser.parsePPS($0) }
        }
    }
}

// MARK: - VideoFormatInfo

@Suite struct H265VideoFormatTests {

    @Test func h265FormatReportsCroppedDisplayAndCodedAllocation() throws {
        let sps = try parseHEVCSPS(HEVCVector.w2)
        let pps = try parseHEVCPPS(HEVCVector.q1)
        let format = VideoFormatInfo(sps, vps: nil, pps: pps)
        #expect(format.codec == .h265)
        #expect(format.codedWidth == 1936)
        #expect(format.codedHeight == 1088)
        #expect(format.displayWidth == 1920)
        #expect(format.displayHeight == 1080)
        #expect(format.sarWidth == 1)
        #expect(format.sarHeight == 1)
        #expect(format.frameRate == 25.0)
        #expect(format.profileIDC == 1)
        #expect(format.levelIDC == 123)
        #expect(format.tier == 0)
        #expect(format.profileName == "Main")
        #expect(format.levelName == "4.1")
        #expect(format.chromaFormatIDC == 1)
        #expect(format.bitDepthLuma == 8)
        #expect(format.isProgressive)
        #expect(format.minSpatialSegmentationIDC == 4)
        #expect(format.numTemporalLayers == 1)
        #expect(format.temporalIDNested)
    }

    @Test func h265FormatCarriesMain10BitDepth() throws {
        let sps = try parseHEVCSPS(HEVCVector.w4)
        let format = VideoFormatInfo(sps, vps: nil, pps: nil)
        #expect(format.bitDepthLuma == 10)
        #expect(format.profileName == "Main 10")
        // 10-bit is a decode-session-level difference: the output pixel format changes.
        let eightBit = VideoFormatInfo(try parseHEVCSPS(HEVCVector.w1), vps: nil, pps: nil)
        #expect(!format.isDecoderCompatible(with: eightBit))
    }

    @Test func h265FormatTreatsTwoSubLayersAsTwoTemporalLayers() throws {
        let format = VideoFormatInfo(try parseHEVCSPS(HEVCVector.w3), vps: nil, pps: nil)
        #expect(format.numTemporalLayers == 2)
        #expect(format.levelName == "5.0")
        #expect(format.frameRate == 20.0)
    }
}
