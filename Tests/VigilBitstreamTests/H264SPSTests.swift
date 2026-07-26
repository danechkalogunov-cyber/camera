//
//  H264SPSTests.swift
//  VigilBitstreamTests
//
//  The H.264 SPS vectors V1–V7 and PPS vectors P1–P2 of docs/spec-bitstream.md §23.2 and §23.3,
//  plus the NAL header table and the hostile-input cases of §23.7 T-BOUND-1.
//

import Foundation
import Testing

import VigilBitstream
import VigilProtocols

@Suite("H.264 SPS and PPS")
struct H264SPSTests {

    // MARK: - Helpers

    private func parseSPS(_ bytes: [UInt8]) throws -> H264SPS {
        try bytes.withUnsafeBytes { try H264Parser.parseSPS($0) }
    }

    private func parsePPS(_ bytes: [UInt8]) throws -> H264PPS {
        try bytes.withUnsafeBytes { try H264Parser.parsePPS($0) }
    }

    // MARK: - Vectors
    //
    // V1–V7 and P1–P2 come from docs/spec-bitstream.md §23.2 / §23.3. Their provenance is stated
    // there and is repeated here so nobody has to go and look: they were produced by a reference
    // encoder written while the specification was being written, and every expected field below was
    // obtained by parsing the given bytes with an independent reference parser. Their parameter
    // values match the configurations Hikvision cameras emit. **They are not captures from a
    // specific camera**, and no test in this file may be described as if they were. Real captures
    // are to be added alongside them, one test per camera model and firmware revision.

    static let v1 = "Z00AKPQDwBE/LgIgAAADACAAAAZQgA=="
    static let v2 = "Z2QAKawsrAeAIn5cBagICAoAAAMAAgAAAwB5Ht8="
    static let v3 = "Z2QAMqzoAoALWwEQAAADABAAAAMCiEA="
    static let v4 = "Z0KAHtoCwEm/8ADAALEAAAMAAQAAAwAeBA=="
    static let v5 = "Z2QAKK3//////////////////////////////////////+UB4AiflwEQAAADABAAAAMDKEA="
    static let v6 = "Z00AKPYDwCJ+8BEAAAMAAQAAAwAyhA=="
    static let v7 = "Z00AH9CyCBIQYCgC3YCIAAADAAgAAAMBlCA="

    static let p1: [UInt8] = [0x68, 0xEE, 0x3C, 0x80]
    static let p2: [UInt8] = [0x68, 0xEE, 0x3C, 0xB0]

    // MARK: - V1: the reference 1080p case

    /// The case the whole module exists to get right: 1088 coded rows cropped to 1080 with
    /// `CropUnitY == 2`. Reporting 1088 puts eight rows of garbage at the bottom of every frame.
    @Test func h264SPSVectorV1IsCoded1088AndDisplayed1080() throws {
        let sps = try H264Parser.parseSPS(base64: H264SPSTests.v1)
        #expect(sps.profileIDC == 77)
        #expect(sps.profileName == "Main")
        #expect(sps.constraintFlags == 0x00)
        #expect(sps.levelIDC == 40)
        #expect(sps.levelName == "4.0")
        #expect(sps.seqParameterSetID == 0)
        #expect(sps.chromaFormatIDC == 1)
        #expect(sps.bitDepthLuma == 8)
        #expect(sps.bitDepthChroma == 8)
        #expect(sps.seqScalingMatrixPresent == false)
        #expect(sps.log2MaxFrameNum == 4)
        #expect(sps.picOrderCntType == 0)
        #expect(sps.log2MaxPicOrderCntLsb == 4)
        #expect(sps.maxNumRefFrames == 1)
        #expect(sps.picWidthInMbs == 120)
        #expect(sps.picHeightInMapUnits == 68)
        #expect(sps.frameMbsOnlyFlag)
        #expect(sps.frameCropping == CropOffsets(left: 0, right: 0, top: 0, bottom: 4))
        #expect(sps.cropUnitX == 2)
        #expect(sps.cropUnitY == 2)
        #expect(sps.codedWidth == 1920)
        #expect(sps.codedHeight == 1088)
        #expect(sps.displayWidth == 1920)
        #expect(sps.displayHeight == 1080)
        #expect(sps.aspectRatioIDC == 1)
        #expect(sps.sarWidth == 1)
        #expect(sps.sarHeight == 1)
        #expect(sps.numUnitsInTick == 1)
        #expect(sps.timeScale == 50)
        #expect(sps.frameRate == 25.0)
        #expect(sps.isProgressive)
        #expect(sps.vuiPresent)
        #expect(sps.vuiParseFailed == false)
        #expect(sps.debugBitsConsumed == 152)
        #expect(sps.debugBitsAvailable == 160)
    }

    // MARK: - The geometry table, all seven vectors

    /// docs/spec-bitstream.md §23.2, the coded/display/fps rows for every vector at once.
    @Test func h264SPSVectorsDeriveDocumentedGeometry() throws {
        let expected: [(String, Int, Int, Int, Int, Double)] = [
            (H264SPSTests.v1, 1920, 1088, 1920, 1080, 25.0),
            (H264SPSTests.v2, 1920, 1088, 1920, 1080, 30.0),
            (H264SPSTests.v3, 2560, 1440, 2560, 1440, 20.0),
            (H264SPSTests.v4, 704, 576, 704, 576, 15.0),
            (H264SPSTests.v5, 1920, 1088, 1920, 1080, 25.0),
            (H264SPSTests.v6, 1920, 1088, 1920, 1080, 25.0),
            (H264SPSTests.v7, 1280, 720, 1280, 720, 25.0),
        ]
        for (base64, codedWidth, codedHeight, displayWidth, displayHeight, fps) in expected {
            let sps = try H264Parser.parseSPS(base64: base64)
            #expect(sps.codedWidth == codedWidth)
            #expect(sps.codedHeight == codedHeight)
            #expect(sps.displayWidth == displayWidth)
            #expect(sps.displayHeight == displayHeight)
            #expect(sps.frameRate == fps)
        }
    }

    /// The strongest single assertion in the suite: the parse consumed exactly the documented number
    /// of bits, so every skip loop — scaling lists in V5, the POC type 1 cycle in V7, the VUI's HRD
    /// in V2 — landed on the correct bit. The slack is `rbsp_trailing_bits()`, always 1…8 bits.
    @Test func h264SPSVectorsConsumeExactBitCounts() throws {
        let expected: [(String, Int, Int)] = [
            (H264SPSTests.v1, 152, 160), (H264SPSTests.v2, 207, 208),
            (H264SPSTests.v3, 153, 160), (H264SPSTests.v4, 173, 176),
            (H264SPSTests.v5, 393, 400), (H264SPSTests.v6, 149, 152),
            (H264SPSTests.v7, 178, 184),
        ]
        for (base64, consumed, available) in expected {
            let sps = try H264Parser.parseSPS(base64: base64)
            #expect(sps.debugBitsConsumed == consumed)
            #expect(sps.debugBitsAvailable == available)
            #expect(available - sps.debugBitsConsumed >= 1)
            #expect(available - sps.debugBitsConsumed <= 8)
            #expect(sps.vuiParseFailed == false)
        }
    }

    // MARK: - V2: bitstream restriction and colour

    @Test func h264SPSVectorV2ReportsZeroReorderingAndColour() throws {
        let sps = try H264Parser.parseSPS(base64: H264SPSTests.v2)
        #expect(sps.profileIDC == 100)
        #expect(sps.profileName == "High")
        #expect(sps.levelName == "4.1")
        #expect(sps.log2MaxFrameNum == 8)
        #expect(sps.log2MaxPicOrderCntLsb == 8)
        #expect(sps.maxNumRefFrames == 2)
        // The "no reordering, decode with zero latency" signal the low-latency path keys on.
        #expect(sps.maxNumReorderFrames == 0)
        #expect(sps.maxDecFrameBuffering == 0)
        #expect(sps.colourPrimaries == 1)
        #expect(sps.transferCharacteristics == 1)
        #expect(sps.matrixCoefficients == 1)
    }

    // MARK: - V4: SAR, POC type 2 and the Baseline naming trap

    /// `constraintFlags == 0x80` is `constraint_set0_flag`, **not** `constraint_set1_flag` (`0x40`).
    /// Constrained Baseline requires the latter, so this must report plain "Baseline".
    @Test func h264SPSVectorV4IsBaselineNotConstrainedBaseline() throws {
        let sps = try H264Parser.parseSPS(base64: H264SPSTests.v4)
        #expect(sps.profileIDC == 66)
        #expect(sps.constraintFlags == 0x80)
        #expect(sps.profileName == "Baseline")
        #expect(sps.levelName == "3.0")
        #expect(sps.picOrderCntType == 2)
        #expect(sps.log2MaxPicOrderCntLsb == nil)
    }

    /// The only vector with a non-square SAR. 704 × (12/11) / 576 is exactly 4:3, which proves the
    /// SAR reaches the *display* aspect rather than being ignored.
    @Test func h264SPSVectorV4AppliesExtendedSARToTheDisplayAspect() throws {
        let sps = try H264Parser.parseSPS(base64: H264SPSTests.v4)
        #expect(sps.aspectRatioIDC == 255)                  // Extended_SAR
        #expect(sps.sarWidth == 12)
        #expect(sps.sarHeight == 11)
        let aspect = Double(sps.displayWidth) * (12.0 / 11.0) / Double(sps.displayHeight)
        #expect(abs(aspect - 4.0 / 3.0) < 1e-12)
    }

    // MARK: - V5: scaling lists

    /// All eight scaling lists present, every `delta_scale` zero — 6 × 16 + 2 × 64 = 224 `se(v)`
    /// reads that must be consumed. A parser that skips a fixed number of bits, or that stops the
    /// loop when `nextScale` reaches 0, lands elsewhere and reports a nonsense resolution.
    @Test func h264SPSVectorV5SkipsScalingListsExactly() throws {
        let sps = try H264Parser.parseSPS(base64: H264SPSTests.v5)
        #expect(sps.seqScalingMatrixPresent)
        #expect(sps.profileIDC == 100)
        #expect(sps.maxNumRefFrames == 4)
        #expect(sps.codedWidth == 1920)
        #expect(sps.codedHeight == 1088)
        #expect(sps.displayHeight == 1080)
        #expect(sps.debugBitsConsumed == 393)
    }

    // MARK: - V6: MBAFF and CropUnitY

    /// `frame_mbs_only_flag == 0` doubles both the height derivation (34 map units × 2 × 16 = 1088)
    /// and `CropUnitY` (2 × 2 = 4), so `frame_crop_bottom_offset = 2` removes eight rows. A wrong
    /// `CropUnitY` yields 1084 — or 1080 by luck — and this is the vector that catches it.
    @Test func h264SPSVectorV6DoublesCropUnitYWhenInterlaced() throws {
        let sps = try H264Parser.parseSPS(base64: H264SPSTests.v6)
        #expect(sps.frameMbsOnlyFlag == false)
        #expect(sps.mbAdaptiveFrameFieldFlag)
        #expect(sps.isProgressive == false)
        #expect(sps.picHeightInMapUnits == 34)
        #expect(sps.cropUnitX == 2)
        #expect(sps.cropUnitY == 4)
        #expect(sps.frameCropping.bottom == 2)
        #expect(sps.codedHeight == 1088)
        #expect(sps.displayHeight == 1080)
    }

    // MARK: - V7: pic_order_cnt_type == 1

    /// A three-entry `offset_for_ref_frame` cycle. We never use the values, but if the loop is
    /// skipped or mis-bounded then `max_num_ref_frames` reads as garbage and the resolution is wrong.
    @Test func h264SPSVectorV7ConsumesThePOCTypeOneCycle() throws {
        let sps = try H264Parser.parseSPS(base64: H264SPSTests.v7)
        #expect(sps.picOrderCntType == 1)
        #expect(sps.offsetForRefFrame == [4, -4, 8])
        #expect(sps.offsetForNonRefPic == -2)
        #expect(sps.log2MaxPicOrderCntLsb == nil)
        #expect(sps.maxNumRefFrames == 2)
        #expect(sps.codedWidth == 1280)
        #expect(sps.codedHeight == 720)
        #expect(sps.debugBitsConsumed == 178)
    }

    // MARK: - PPS vectors

    /// P1 of docs/spec-bitstream.md §23.3: `more_rbsp_data()` is false at the decision point, so
    /// `transform_8x8_mode_flag` is absent.
    @Test func h264PPSVectorP1StopsAtTheStopBit() throws {
        let pps = try parsePPS(H264SPSTests.p1)
        #expect(pps.picParameterSetID == 0)
        #expect(pps.seqParameterSetID == 0)
        #expect(pps.entropyCodingModeFlag)                  // CABAC
        #expect(pps.usesSliceGroups == false)
        #expect(pps.transform8x8ModeFlag == false)
        #expect(pps.picInitQP == 26)
        #expect(pps.deblockingFilterControlPresentFlag)
        #expect(pps.debugBitsConsumed == 16)
        #expect(pps.debugBitsAvailable == 24)
    }

    /// P2 differs from P1 in one byte and is the canonical regression pair for `moreRBSPData()`.
    @Test func h264PPSVectorP2ReadsTransform8x8ModeFlag() throws {
        let pps = try parsePPS(H264SPSTests.p2)
        #expect(pps.entropyCodingModeFlag)
        #expect(pps.transform8x8ModeFlag)
        #expect(pps.debugBitsConsumed == 17)
        #expect(pps.debugBitsAvailable == 24)
    }

    @Test func h264PPSRejectsAnSPSNALType() {
        let spsBytes: [UInt8] = [0x67, 0x4D, 0x00, 0x28]
        #expect(throws: BitstreamError.wrongNALType(expected: 8, found: 7)) {
            _ = try spsBytes.withUnsafeBytes { try H264Parser.parsePPS($0) }
        }
    }

    @Test func h264SPSRejectsAPPSNALType() {
        #expect(throws: BitstreamError.wrongNALType(expected: 7, found: 8)) {
            _ = try H264SPSTests.p1.withUnsafeBytes { try H264Parser.parseSPS($0) }
        }
    }

    // MARK: - sprop-parameter-sets

    @Test func h264ParserSplitsSpropParameterSetsLeniently() throws {
        let value = " \(H264SPSTests.v1) , aO48gA== ,"
        let sets = try H264Parser.parseSpropParameterSets(value)
        #expect(sets.count == 2)
        #expect(sets[0].count == 22)
        #expect(Array(sets[1]) == H264SPSTests.p1)
    }

    @Test func h264ParserRejectsNonBase64SpropValue() {
        #expect(throws: BitstreamError.invalidBase64) {
            _ = try H264Parser.parseSpropParameterSets("Z00AKPQDwBE/LgIgAAADACAAAAZQgA==,!!!!")
        }
    }

    @Test func h264ParserRejectsNonBase64SPS() {
        #expect(throws: BitstreamError.invalidBase64) {
            _ = try H264Parser.parseSPS(base64: "not base64 %%%")
        }
    }

    // MARK: - NAL header and type tables

    @Test func nalHeaderDecodesTheH264Byte() throws {
        let decoded = try NALHeader.decodeH264(0x65)         // nal_ref_idc 3, type 5
        #expect(decoded.type == 5)
        #expect(decoded.refIdc == 3)
        #expect(NALHeader.encodeH264(type: 5, refIdc: 3) == 0x65)
    }

    @Test func nalHeaderRejectsASetForbiddenBit() {
        #expect(throws: BitstreamError.forbiddenBitSet) { _ = try NALHeader.decodeH264(0x85) }
        #expect(throws: BitstreamError.forbiddenBitSet) { _ = try NALHeader.decodeHEVC(0x80, 0x01) }
    }

    @Test func nalHeaderRejectsAZeroTemporalIDPlusOne() {
        #expect(throws: BitstreamError.invalidTemporalID) { _ = try NALHeader.decodeHEVC(0x26, 0x00) }
    }

    /// docs/spec-bitstream.md §23.7 T-NAL-1: encode/decode round trip over every legal combination.
    /// Mismatches are counted rather than expected one by one, so 28 672 combinations cost one
    /// assertion instead of eighty-six thousand.
    @Test func nalHeaderRoundTripsEveryHEVCCombination() throws {
        var mismatches = 0
        for type in UInt8(0)...63 {
            for layerID in UInt8(0)...63 {
                for temporalID in UInt8(0)...6 {
                    let (b0, b1) = NALHeader.encodeHEVC(type: type, layerID: layerID,
                                                        temporalID: temporalID)
                    let decoded = try NALHeader.decodeHEVC(b0, b1)
                    if decoded.type != type || decoded.layerID != layerID
                        || decoded.temporalID != temporalID {
                        mismatches += 1
                    }
                }
            }
        }
        #expect(mismatches == 0)
    }

    @Test func nalHeaderReadsTypeCodesForBothCodecs() throws {
        let h264: [UInt8] = [0x67, 0xAA]
        let h265: [UInt8] = [0x40, 0x01, 0xAA]              // VPS, layer 0, temporal id 0
        let h264Type = try h264.withUnsafeBytes { try NALHeader.typeCode($0, codec: .h264) }
        let h265Type = try h265.withUnsafeBytes { try NALHeader.typeCode($0, codec: .h265) }
        #expect(h264Type == 7)
        #expect(h265Type == 32)
        let empty = [UInt8]()
        empty.withUnsafeBytes { raw in
            #expect(throws: BitstreamError.emptyNALUnit) {
                _ = try NALHeader.typeCode(raw, codec: .h264)
            }
        }
    }

    @Test func nalTypeTablesClassifyCorrectly() {
        #expect(H264NALType.codedSliceIDR.isVCL)
        #expect(H264NALType.codedSliceIDR.isIDR)
        #expect(H264NALType.codedSliceNonIDR.isIDR == false)
        #expect(H264NALType.sps.isParameterSet)
        #expect(H264NALType.sei.isVCL == false)
        #expect(H264NALType.isRTPPacketization(rawValue: 28))

        #expect(H265NALType.idrWRADL.isIRAP)
        #expect(H265NALType.idrWRADL.isIDR)
        #expect(H265NALType.craNUT.isCRA)
        #expect(H265NALType.craNUT.isIRAP)
        #expect(H265NALType.raslR.isRASL)
        #expect(H265NALType.raslR.isLeading)
        #expect(H265NALType.radlN.isRADL)
        #expect(H265NALType.trailN.isSubLayerNonReference)
        #expect(H265NALType.trailR.isSubLayerNonReference == false)
        #expect(H265NALType.vps.isParameterSet)
        #expect(H265NALType.isIRAP(rawValue: 23))           // reserved IRAP, still a keyframe
        #expect(H265NALType.isRTPPacketization(rawValue: 49))
    }

    // MARK: - Hostile input (T-BOUND-1)
    //
    // Every fixture below is **synthetic**: it was produced by a bit writer while writing these
    // tests, specifically to exercise one row of the bounds table in docs/spec-bitstream.md §4. None
    // of them came from a camera.

    /// A truncated SPS must report where the data ran out, not read past the buffer.
    @Test func h264SPSRejectsATruncatedNAL() {
        let truncated: [UInt8] = [0x67, 0x4D, 0x00, 0x28, 0xF4, 0x03]
        #expect(throws: BitstreamError.unexpectedEndOfData(atBit: 39)) {
            _ = try parseSPS(truncated)
        }
        let headerOnly: [UInt8] = [0x67]
        #expect(throws: BitstreamError.emptyNALUnit) { _ = try parseSPS(headerOnly) }
        #expect(throws: BitstreamError.emptyNALUnit) { _ = try parseSPS([]) }
    }

    @Test func h264SPSRejectsANALAboveTheParameterSetCap() {
        var oversize: [UInt8] = [0x67]
        oversize.append(contentsOf: [UInt8](repeating: 0xAA, count: Limits.maxParameterSetBytes))
        #expect(throws: BitstreamError.tooLarge(bytes: Limits.maxParameterSetBytes + 1)) {
            _ = try parseSPS(oversize)
        }
    }

    /// Synthetic: `pic_width_in_mbs_minus1 == 2000`, above `Limits.maxMacroblockDimensionMinus1`.
    /// The field is refused before any arithmetic derives a size from it.
    @Test func h264SPSRejectsAWidthAboveTheMacroblockBound() {
        let hostile: [UInt8] = [0x67, 0x4D, 0x00, 0x28, 0xF4, 0x00, 0x3E, 0x88, 0x11, 0x32]
        #expect(throws: BitstreamError.valueOutOfRange(field: "pic_width_in_mbs_minus1",
                                                       value: 2000)) {
            _ = try parseSPS(hostile)
        }
    }

    /// Synthetic: interlaced with 1024 map units, each field-doubled, giving a coded height of
    /// 32768 — every field is individually in range, and only the derived size is absurd.
    @Test func h264SPSRejectsADerivedHeightAboveTheLimit() {
        let hostile: [UInt8] = [0x67, 0x4D, 0x00, 0x28, 0xF4, 0x03, 0xC0, 0x01, 0x00, 0x09]
        #expect(throws: BitstreamError.valueOutOfRange(field: "coded height", value: 32768)) {
            _ = try parseSPS(hostile)
        }
    }

    /// Synthetic: `frame_crop_right_offset == 1000` with `CropUnitX == 2` on a 1920-wide picture,
    /// which would leave a negative display width.
    @Test func h264SPSRejectsCroppingThatLeavesNoPicture() {
        let hostile: [UInt8] = [0x67, 0x4D, 0x00, 0x28, 0xF4, 0x03, 0xC0, 0x11,
                                0x3C, 0x01, 0xF4, 0xE8]
        #expect(throws: BitstreamError.invalidCropping) { _ = try parseSPS(hostile) }
    }

    /// Synthetic: `pic_order_cnt_type == 3`, outside the 0…2 the standard allows.
    @Test func h264SPSRejectsAnIllegalPicOrderCntType() {
        let hostile: [UInt8] = [0x67, 0x4D, 0x00, 0x28, 0xC8, 0x80, 0x78, 0x02, 0x26, 0x40]
        #expect(throws: BitstreamError.valueOutOfRange(field: "pic_order_cnt_type", value: 3)) {
            _ = try parseSPS(hostile)
        }
    }

    /// Synthetic: `chroma_format_idc == 4` on a High-profile SPS, outside the 0…3 of Table 6-1.
    @Test func h264SPSRejectsAnIllegalChromaFormat() {
        let hostile: [UInt8] = [0x67, 0x64, 0x00, 0x28, 0x97, 0x3A, 0x01, 0xE0, 0x08, 0x99]
        #expect(throws: BitstreamError.valueOutOfRange(field: "chroma_format_idc", value: 4)) {
            _ = try parseSPS(hostile)
        }
    }

    /// Synthetic: a minimal valid 32×32 SPS with no VUI, proving the smallest legal picture parses
    /// and that an absent VUI leaves the frame rate unknown rather than guessed.
    @Test func h264SPSParsesAMinimalStreamWithoutAVUI() throws {
        let minimal: [UInt8] = [0x67, 0x4D, 0x00, 0x28, 0xF4, 0x4B, 0x20]
        let sps = try parseSPS(minimal)
        #expect(sps.codedWidth == 32)
        #expect(sps.codedHeight == 32)
        #expect(sps.displayWidth == 32)
        #expect(sps.displayHeight == 32)
        #expect(sps.vuiPresent == false)
        #expect(sps.frameRate == nil)
        #expect(sps.sarWidth == 1)
        #expect(sps.sarHeight == 1)
    }

    /// Truncating each vector at every byte is the shape a lost RTP packet leaves behind, and it is
    /// reachable from the LAN by any device.
    ///
    /// A truncation is *not* required to throw — cutting after the last field the parser needs
    /// leaves a syntactically complete SPS — but whatever it returns must be a sane picture. The
    /// invariant asserted here is the one the rest of the app relies on: **any SPS this parser
    /// returns has a positive, in-range display and coded size.**
    @Test func h264SPSTruncationsYieldEitherAThrowOrASanePicture() throws {
        for base64 in [H264SPSTests.v1, H264SPSTests.v5, H264SPSTests.v7] {
            let bytes = [UInt8](try H264Parser.parseSpropParameterSets(base64)[0])
            var sane = 0
            for length in 0 ... bytes.count {
                guard let sps = try? parseSPS(Array(bytes[0 ..< length])) else { continue }
                #expect(sps.codedWidth >= Limits.minH264CodedDimension)
                #expect(sps.codedWidth <= Limits.maxCodedDimension)
                #expect(sps.codedHeight >= Limits.minH264CodedDimension)
                #expect(sps.codedHeight <= Limits.maxCodedDimension)
                #expect(sps.displayWidth > 0)
                #expect(sps.displayHeight > 0)
                sane += 1
            }
            #expect(sane >= 1)                              // the untruncated vector, at least
        }
    }

    // MARK: - SAR table

    @Test func sampleAspectRatioTableMatchesTableE1() {
        #expect(SampleAspectRatio.ratio(for: 1).map { [$0.width, $0.height] } == [1, 1])
        #expect(SampleAspectRatio.ratio(for: 2).map { [$0.width, $0.height] } == [12, 11])
        #expect(SampleAspectRatio.ratio(for: 13).map { [$0.width, $0.height] } == [160, 99])
        #expect(SampleAspectRatio.ratio(for: 16).map { [$0.width, $0.height] } == [2, 1])
        #expect(SampleAspectRatio.ratio(for: 0) == nil)      // Unspecified
        #expect(SampleAspectRatio.ratio(for: 17) == nil)     // reserved
        #expect(SampleAspectRatio.ratio(for: 255) == nil)    // Extended_SAR
        // The sanity rule: a zero component can never become a divide by zero downstream.
        #expect(SampleAspectRatio.sanitised(width: 0, height: 11) == (1, 1))
        #expect(SampleAspectRatio.sanitised(width: 12, height: 0) == (1, 1))
        #expect(SampleAspectRatio.sanitised(width: 12, height: 11) == (12, 11))
    }

    // MARK: - Level naming

    @Test func h264LevelNamesCoverTheTableAndTheOneBCase() {
        #expect(H264SPS.levelName(levelIDC: 9, constraintFlags: 0x00) == "1b")
        #expect(H264SPS.levelName(levelIDC: 11, constraintFlags: 0x10) == "1b")
        #expect(H264SPS.levelName(levelIDC: 11, constraintFlags: 0x00) == "1.1")
        #expect(H264SPS.levelName(levelIDC: 30, constraintFlags: 0x00) == "3.0")
        #expect(H264SPS.levelName(levelIDC: 51, constraintFlags: 0x00) == "5.1")
        #expect(H264SPS.levelName(levelIDC: 62, constraintFlags: 0x00) == "6.2")
        #expect(H264SPS.profileName(profileIDC: 66, constraintFlags: 0x40) == "Constrained Baseline")
        #expect(H264SPS.profileName(profileIDC: 110, constraintFlags: 0x00) == "High 10")
    }
}
