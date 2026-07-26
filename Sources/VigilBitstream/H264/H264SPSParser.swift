//
//  H264SPSParser.swift
//  VigilBitstream
//
//  ITU-T H.264 §7.3.2.1 in full: the mandatory prefix, the scaling-list skip, the POC type 1 cycle,
//  frame cropping and the leniently parsed VUI.
//  See docs/spec-bitstream.md §8 and docs/API_CONTRACT.md §4.2.
//

import Foundation

import VigilProtocols

// MARK: - H264Parser

/// The H.264 syntax entry points. A namespace: there is no state and nothing to construct.
public enum H264Parser {

    /// `profile_idc` values that carry the chroma / bit-depth / scaling-list block of §7.3.2.1.
    ///
    /// **Do not confuse this with the `avcC` trailing-extension condition, which is the different
    /// and shorter set {100, 110, 122, 144}** (docs/spec-bitstream.md §16.2). Mixing the two up is
    /// the classic `avcC` bug.
    @inlinable
    public static func profileHasChromaExtension(_ profileIDC: UInt8) -> Bool {
        switch profileIDC {
        case 100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135: return true
        default: return false
        }
    }

    // MARK: - Entry points

    /// Parses a sequence parameter set.
    ///
    /// - Parameter nal: The SPS NAL unit **including** its one-byte header and **excluding** any
    ///   start code or length prefix — the canonical storage form.
    /// - Returns: The parsed SPS, with `debugBitsConsumed` recording where the parse stopped.
    /// - Throws: `.emptyNALUnit` for a NAL with no payload, `.tooLarge` past
    ///   `Limits.maxParameterSetBytes`, `.wrongNALType` when the type is not 7, `.forbiddenBitSet`
    ///   for a corrupt header, `.unexpectedEndOfData` for a truncated SPS, `.valueOutOfRange` for a
    ///   syntax element outside the bounds of docs/spec-bitstream.md §4, `.malformedExpGolomb` for a
    ///   code designed to make a parser loop, and `.invalidCropping` when the crop offsets leave no
    ///   picture. A malformed **VUI** never fails the parse; it sets `vuiParseFailed`.
    public static func parseSPS(_ nal: UnsafeRawBufferPointer) throws(BitstreamError) -> H264SPS {
        guard nal.count >= 1 else { throw BitstreamError.emptyNALUnit }
        guard nal.count <= Limits.maxParameterSetBytes else {
            throw BitstreamError.tooLarge(bytes: nal.count)
        }
        let header = try NALHeader.decodeH264(nal[0])
        guard header.type == H264NALType.sps.rawValue else {
            throw BitstreamError.wrongNALType(expected: H264NALType.sps.rawValue, found: header.type)
        }
        let rbsp = try RBSP.unescape(nal, skippingHeaderBytes: 1)
        var reader = try RBSPBitReader(rbsp: rbsp)
        var sps = H264SPS()
        try parsePrefix(&reader, into: &sps)

        // Lenient-VUI rule (docs/spec-bitstream.md §8.4, binding). The parse is strictly sequential,
        // so every field recovered before a failure is still valid and everything after it keeps its
        // default. Several Hikvision firmware revisions emit an HRD block that does not match §E.1.2.
        if sps.vuiPresent {
            do {
                try parseVUI(&reader, into: &sps)
            } catch {
                sps.vuiParseFailed = true
            }
        }
        sps.debugBitsConsumed = reader.bitOffset
        sps.debugBitsAvailable = rbsp.count * 8
        try validateGeometry(sps)
        return sps
    }

    /// Parses an SPS from a base64 string, as `sprop-parameter-sets` delivers it.
    ///
    /// - Throws: `.invalidBase64` when the text does not decode, then whatever `parseSPS` throws.
    public static func parseSPS(base64: String) throws(BitstreamError) -> H264SPS {
        guard let bytes = Base64.decodeOrNil(base64), !bytes.isEmpty else {
            throw BitstreamError.invalidBase64
        }
        return try RBSP.withRawBytes(bytes) { raw throws(BitstreamError) in try parseSPS(raw) }
    }

    /// Splits an SDP `sprop-parameter-sets` value — `"<base64>,<base64>"` — into NAL units.
    ///
    /// Lenient about formatting, because SDP from a camera is: surrounding and interior whitespace
    /// is ignored, empty components (a leading, trailing or doubled comma) are skipped, and missing
    /// base64 padding is accepted. It is **not** lenient about content: a non-empty component that
    /// is not base64 throws, because silently dropping a parameter set would produce a stream that
    /// never decodes and no diagnostic to explain why.
    ///
    /// - Returns: The decoded NAL units in the order they appeared, each in canonical storage form.
    /// - Throws: `.invalidBase64` for a component that does not decode.
    public static func parseSpropParameterSets(_ value: String) throws(BitstreamError) -> [Data] {
        var out = [Data]()
        for component in value.split(separator: ",", omittingEmptySubsequences: false) {
            let trimmed = component.filter { !$0.isWhitespace }
            if trimmed.isEmpty { continue }
            guard let bytes = Base64.decodeOrNil(trimmed), !bytes.isEmpty else {
                throw BitstreamError.invalidBase64
            }
            out.append(Data(bytes))
        }
        return out
    }

    // MARK: - The mandatory prefix

    /// Reads §7.3.2.1 from `profile_idc` through `vui_parameters_present_flag`, strictly.
    ///
    /// RATIONALE for the length: this mirrors one ITU-T syntax table top to bottom, and splitting it
    /// would make it impossible to review against the standard line by line. The order of reads
    /// **is** the specification; nothing here may be reordered.
    private static func parsePrefix(
        _ reader: inout RBSPBitReader, into sps: inout H264SPS
    ) throws(BitstreamError) {
        sps.profileIDC = UInt8(truncatingIfNeeded: try reader.u(8))
        sps.constraintFlags = UInt8(truncatingIfNeeded: try reader.u(8))   // 6 flags + 2 reserved bits
        sps.levelIDC = UInt8(truncatingIfNeeded: try reader.u(8))
        sps.seqParameterSetID = try reader.ue("seq_parameter_set_id", max: Limits.maxH264SPSID)

        if profileHasChromaExtension(sps.profileIDC) {
            let chroma = try reader.ue("chroma_format_idc", max: Limits.maxChromaFormatIDC)
            sps.chromaFormatIDC = UInt8(truncatingIfNeeded: chroma)
            if chroma == 3 {
                sps.separateColourPlaneFlag = try reader.flag()
            }
            let luma = try reader.ue("bit_depth_luma_minus8", max: Limits.maxBitDepthMinus8)
            let chromaDepth = try reader.ue("bit_depth_chroma_minus8", max: Limits.maxBitDepthMinus8)
            sps.bitDepthLuma = Int(luma) + 8
            sps.bitDepthChroma = Int(chromaDepth) + 8
            try reader.skip(1)                                  // qpprime_y_zero_transform_bypass_flag
            sps.seqScalingMatrixPresent = try reader.flag()
            if sps.seqScalingMatrixPresent {
                let listCount = (sps.chromaFormatIDC != 3) ? 8 : 12
                for i in 0 ..< listCount {
                    // seq_scaling_list_present_flag[i] is read once per iteration, present or not.
                    if try reader.flag() {
                        try skipScalingList(&reader, size: i < 6 ? 16 : 64)
                    }
                }
            }
        }

        let log2FrameNum = try reader.ue("log2_max_frame_num_minus4", max: Limits.maxLog2Minus4)
        sps.log2MaxFrameNum = Int(log2FrameNum) + 4
        let pocType = try reader.ue("pic_order_cnt_type", max: Limits.maxPicOrderCntType)
        sps.picOrderCntType = UInt8(truncatingIfNeeded: pocType)
        if pocType == 0 {
            let lsb = try reader.ue("log2_max_pic_order_cnt_lsb_minus4", max: Limits.maxLog2Minus4)
            sps.log2MaxPicOrderCntLsb = Int(lsb) + 4
        } else if pocType == 1 {
            sps.deltaPicOrderAlwaysZeroFlag = try reader.flag()
            sps.offsetForNonRefPic = try reader.se()
            sps.offsetForTopToBottomField = try reader.se()
            let cycleLength = try reader.ue("num_ref_frames_in_pic_order_cnt_cycle",
                                            max: Limits.maxRefFramesInPOCCycle)
            // The only count-driven allocation in this parser, bounded above at 255 entries.
            var offsets = [Int32]()
            offsets.reserveCapacity(Int(cycleLength))
            for _ in 0 ..< Int(cycleLength) {
                offsets.append(try reader.se())
            }
            sps.offsetForRefFrame = offsets
        }

        // The table says clamp, not throw: over-reporting this is harmless because Vigil runs no DPB.
        let refFrames = try reader.ue()
        sps.maxNumRefFrames = Swift.min(Int(refFrames), Limits.maxNumRefFrames)
        sps.gapsInFrameNumValueAllowed = try reader.flag()

        let widthMinus1 = try reader.ue("pic_width_in_mbs_minus1",
                                        max: Limits.maxMacroblockDimensionMinus1)
        sps.picWidthInMbs = Int(widthMinus1) + 1
        let heightMinus1 = try reader.ue("pic_height_in_map_units_minus1",
                                         max: Limits.maxMacroblockDimensionMinus1)
        sps.picHeightInMapUnits = Int(heightMinus1) + 1
        sps.frameMbsOnlyFlag = try reader.flag()
        if !sps.frameMbsOnlyFlag {
            sps.mbAdaptiveFrameFieldFlag = try reader.flag()
        }
        sps.direct8x8InferenceFlag = try reader.flag()

        if try reader.flag() {                                  // frame_cropping_flag
            let left = try reader.ue("frame_crop_left_offset", max: Limits.maxCropOffset)
            let right = try reader.ue("frame_crop_right_offset", max: Limits.maxCropOffset)
            let top = try reader.ue("frame_crop_top_offset", max: Limits.maxCropOffset)
            let bottom = try reader.ue("frame_crop_bottom_offset", max: Limits.maxCropOffset)
            sps.frameCropping = CropOffsets(left: Int(left), right: Int(right),
                                            top: Int(top), bottom: Int(bottom))
        }
        sps.vuiPresent = try reader.flag()
    }

    // MARK: - scaling_list()

    /// Consumes exactly the bits of one `scaling_list(sizeOfScalingList)` — H.264 §7.3.2.1.1.1.
    ///
    /// The coefficients are discarded, because VideoToolbox re-parses the SPS itself, but the bit
    /// consumption must be exact: skipping the wrong number of bits desynchronises everything after
    /// it, and the symptom is a plausible-looking but wrong resolution.
    ///
    /// Two subtleties, each of which has bitten a real implementation:
    /// * once `nextScale` reaches 0 the remaining `delta_scale` values are **not present** and must
    ///   not be read — but the loop still runs to `size`, it does not stop early;
    /// * `useDefaultScalingMatrixFlag` (`j == 0 && nextScale == 0`) changes which matrix a decoder
    ///   uses but consumes no bits, so it does not appear here at all.
    private static func skipScalingList(
        _ reader: inout RBSPBitReader, size: Int
    ) throws(BitstreamError) {
        var lastScale: Int32 = 8
        var nextScale: Int32 = 8
        for _ in 0 ..< size {
            if nextScale != 0 {
                let deltaScale = try reader.se("delta_scale", min: -128, max: 127)
                nextScale = (lastScale + deltaScale + 256) % 256
            }
            lastScale = (nextScale == 0) ? lastScale : nextScale
        }
    }

    // MARK: - hrd_parameters()

    /// Consumes `hrd_parameters()` — H.264 §E.1.2 — keeping the three delay lengths `pic_timing`
    /// SEI parsing needs. Bit-exact; the VUI fields after it depend on landing correctly.
    private static func skipHRDParameters(
        _ reader: inout RBSPBitReader, into sps: inout H264SPS
    ) throws(BitstreamError) {
        let cpbCount = Int(try reader.ue("cpb_cnt_minus1", max: Limits.maxCPBCountMinus1)) + 1
        try reader.skip(4)                                      // bit_rate_scale
        try reader.skip(4)                                      // cpb_size_scale
        for _ in 0 ..< cpbCount {
            _ = try reader.ue()                                 // bit_rate_value_minus1[i]
            _ = try reader.ue()                                 // cpb_size_value_minus1[i]
            try reader.skip(1)                                  // cbr_flag[i]
        }
        _ = try reader.u(5)                                     // initial_cpb_removal_delay_length_minus1
        sps.cpbRemovalDelayLength = Int(try reader.u(5)) + 1
        sps.dpbOutputDelayLength = Int(try reader.u(5)) + 1
        try reader.skip(5)                                      // time_offset_length
    }

    // MARK: - vui_parameters()

    /// Reads `vui_parameters()` — H.264 §E.1.1. Called inside the lenient wrapper, so a throw here
    /// only sets `vuiParseFailed`; every field already assigned stays.
    private static func parseVUI(
        _ reader: inout RBSPBitReader, into sps: inout H264SPS
    ) throws(BitstreamError) {
        if try reader.flag() {                                  // aspect_ratio_info_present_flag
            let idc = UInt8(truncatingIfNeeded: try reader.u(8))
            sps.aspectRatioIDC = idc
            if idc == SampleAspectRatio.extendedSAR {
                let width = Int(try reader.u(16))
                let height = Int(try reader.u(16))
                let sanitised = SampleAspectRatio.sanitised(width: width, height: height)
                sps.sarWidth = sanitised.width
                sps.sarHeight = sanitised.height
            } else if let ratio = SampleAspectRatio.ratio(for: idc) {
                sps.sarWidth = ratio.width
                sps.sarHeight = ratio.height
            }                                                   // reserved idc: stays 1:1
        }
        if try reader.flag() { try reader.skip(1) }             // overscan_appropriate_flag
        if try reader.flag() {                                  // video_signal_type_present_flag
            sps.videoFormat = UInt8(truncatingIfNeeded: try reader.u(3))
            sps.videoFullRangeFlag = try reader.flag()
            if try reader.flag() {                              // colour_description_present_flag
                sps.colourPrimaries = UInt8(truncatingIfNeeded: try reader.u(8))
                sps.transferCharacteristics = UInt8(truncatingIfNeeded: try reader.u(8))
                sps.matrixCoefficients = UInt8(truncatingIfNeeded: try reader.u(8))
            }
        }
        if try reader.flag() {                                  // chroma_loc_info_present_flag
            _ = try reader.ue()                                 // chroma_sample_loc_type_top_field
            _ = try reader.ue()                                 // chroma_sample_loc_type_bottom_field
        }
        if try reader.flag() {                                  // timing_info_present_flag
            let numUnitsInTick = try reader.u(32)
            let timeScale = try reader.u(32)
            sps.fixedFrameRateFlag = try reader.flag()
            sps.numUnitsInTick = numUnitsInTick
            sps.timeScale = timeScale
        }
        let nalHRD = try reader.flag()
        if nalHRD { try skipHRDParameters(&reader, into: &sps) }
        let vclHRD = try reader.flag()
        if vclHRD { try skipHRDParameters(&reader, into: &sps) }
        sps.cpbDpbDelaysPresentFlag = nalHRD || vclHRD
        if nalHRD || vclHRD { sps.lowDelayHRDFlag = try reader.flag() }
        sps.picStructPresentFlag = try reader.flag()
        if try reader.flag() {                                  // bitstream_restriction_flag
            try reader.skip(1)                                  // motion_vectors_over_pic_boundaries
            _ = try reader.ue()                                 // max_bytes_per_pic_denom
            _ = try reader.ue()                                 // max_bits_per_mb_denom
            _ = try reader.ue()                                 // log2_max_mv_length_horizontal
            _ = try reader.ue()                                 // log2_max_mv_length_vertical
            sps.maxNumReorderFrames = Int(try reader.ue("max_num_reorder_frames",
                                                        max: Limits.maxReorderFrames))
            sps.maxDecFrameBuffering = Int(try reader.ue("max_dec_frame_buffering",
                                                         max: Limits.maxReorderFrames))
        }
    }

    // MARK: - Validation

    /// Rejects a picture size or a crop that would allocate absurdly, or that leaves no picture.
    ///
    /// Runs after the parse rather than during it because `cropUnitY` depends on
    /// `frame_mbs_only_flag`, which is read after the dimensions. Every arithmetic here is on `Int`
    /// with operands bounded by the per-field checks in `parsePrefix`, so nothing can overflow.
    private static func validateGeometry(_ sps: H264SPS) throws(BitstreamError) {
        let width = sps.codedWidth
        let height = sps.codedHeight
        guard width >= Limits.minH264CodedDimension, width <= Limits.maxCodedDimension else {
            throw BitstreamError.valueOutOfRange(field: "coded width", value: UInt64(width))
        }
        guard height >= Limits.minH264CodedDimension, height <= Limits.maxCodedDimension else {
            throw BitstreamError.valueOutOfRange(field: "coded height", value: UInt64(height))
        }
        let crop = sps.frameCropping
        let horizontal = sps.cropUnitX * (crop.left + crop.right)
        let vertical = sps.cropUnitY * (crop.top + crop.bottom)
        guard horizontal < width, vertical < height else { throw BitstreamError.invalidCropping }
    }
}
