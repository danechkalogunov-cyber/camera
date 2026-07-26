//
//  H265SPSParser.swift
//  VigilBitstream
//
//  The full H.265 sequence-parameter-set parse: profile_tier_level, the scaling-list and
//  short-term-reference-picture-set skips that must be bit-exact, the conformance window, and the
//  lenient VUI. Every skip loop here is a place where being one bit wrong yields a plausible but
//  wrong resolution, so each one carries the reason it is shaped the way it is.
//  Implements docs/spec-bitstream.md §13.
//

import VigilProtocols

// MARK: - H265Parser

/// Entry points for the three H.265 parameter sets. A namespace, never instantiated.
///
/// Every parser takes a NAL unit **including** its two-byte header, in on-wire (escaped) form, and
/// unescapes into a throwaway buffer. Nothing here mutates its input or retains a pointer.
public enum H265Parser {

    // MARK: - Bounds

    /// Security bounds from docs/spec-bitstream.md §4. They exist so that a hostile or corrupt
    /// parameter set throws instead of driving a loop or an allocation from an attacker's number.
    private enum Bound {
        static let maxSubLayersMinus1: UInt32 = 6
        static let spsID: UInt32 = 15
        static let chromaFormatIDC: UInt32 = 3
        static let bitDepthMinus8: UInt32 = 8
        static let log2MaxPicOrderCntLsbMinus4: UInt32 = 12
        static let log2MinCbSizeMinus3: UInt32 = 3
        static let shortTermRefPicSets: UInt32 = 64
        static let longTermRefPicsSPS: UInt32 = 32
        static let decPicBuffering: UInt32 = 32
        static let refPicsPerSet: UInt32 = 16
        static let minPictureDimension = 8
        static let maxPictureDimension = 16_888
    }

    // MARK: - SPS

    /// Parses an H.265 SPS NAL unit (type 33) in full.
    ///
    /// The mandatory prefix — everything up to `vui_parameters_present_flag` — is parsed strictly:
    /// a failure there means the picture size is unknown and is a real error. The VUI is parsed
    /// leniently (§13.6): whatever was decoded before a failure is kept, `vuiParseFailed` is set,
    /// and the SPS parse still succeeds, because several Hikvision firmware revisions emit an HRD
    /// section that does not match H.265 §E.2.2 while their timing and colour fields are correct.
    ///
    /// - Parameter nal: the NAL unit including its two-byte header, escaped, no start code.
    /// - Returns: the parsed SPS, with `debugBitsConsumed` set to the exact bit the parse stopped at.
    /// - Throws: `.wrongNALType` when the NAL is not type 33; `.valueOutOfRange` for any syntax
    ///   element outside the §4 bounds table; `.invalidCropping` when the conformance window would
    ///   consume the whole picture; `.unexpectedEndOfData` for a truncated NAL.
    public static func parseSPS(_ nal: UnsafeRawBufferPointer) throws(BitstreamError) -> H265SPS {
        guard nal.count >= 2 else { throw BitstreamError.emptyNALUnit }
        let type = (nal[0] >> 1) & 0x3F
        guard type == 33 else { throw BitstreamError.wrongNALType(expected: 33, found: type) }
        var reader = try RBSPBitReader(nalUnit: nal, codec: .h265)
        return try parseSPS(&reader)
    }

    /// Convenience for an SDP `sprop-sps` value, which is a single base64-encoded NAL unit.
    ///
    /// - Throws: `.invalidBase64` when the text is not base64, then whatever `parseSPS` throws.
    public static func parseSPS(base64: String) throws(BitstreamError) -> H265SPS {
        let bytes: [UInt8]
        do {
            bytes = try Base64.decode(base64)
        } catch {
            throw BitstreamError.invalidBase64
        }
        return try withNALPointer(bytes) { (raw) throws(BitstreamError) -> H265SPS in
            try parseSPS(raw)
        }
    }

    // MARK: - SPS body

    /// The syntax of H.265 §7.3.2.2.1, in order, over an already-positioned reader.
    private static func parseSPS(_ r: inout RBSPBitReader) throws(BitstreamError) -> H265SPS {
        var sps = H265SPS()
        let totalBits = r.bitOffset + r.bitsRemaining

        sps.vpsID = UInt8(truncatingIfNeeded: try r.u(4))
        let maxSub = Int(try r.u(3))
        guard maxSub <= Int(Bound.maxSubLayersMinus1) else {
            throw BitstreamError.valueOutOfRange(field: "sps_max_sub_layers_minus1",
                                                 value: UInt64(maxSub))
        }
        sps.maxSubLayersMinus1 = UInt8(maxSub)
        sps.temporalIDNestingFlag = try r.flag()
        sps.ptl = try ProfileTierLevel.parse(&r, maxNumSubLayersMinus1: maxSub)

        sps.spsID = try r.ue("sps_seq_parameter_set_id", max: Bound.spsID)
        sps.chromaFormatIDC = UInt8(truncatingIfNeeded:
            try r.ue("chroma_format_idc", max: Bound.chromaFormatIDC))
        if sps.chromaFormatIDC == 3 { sps.separateColourPlaneFlag = try r.flag() }

        sps.picWidthInLumaSamples = Int(try r.ue())
        sps.picHeightInLumaSamples = Int(try r.ue())
        try validateDimensions(sps.picWidthInLumaSamples, field: "pic_width_in_luma_samples")
        try validateDimensions(sps.picHeightInLumaSamples, field: "pic_height_in_luma_samples")

        if try r.flag() {                                   // conformance_window_flag
            sps.conformanceWindow = CropOffsets(left: Int(try r.ue()), right: Int(try r.ue()),
                                                top: Int(try r.ue()), bottom: Int(try r.ue()))
            try validateConformanceWindow(sps)
        }

        sps.bitDepthLuma = Int(try r.ue("bit_depth_luma_minus8", max: Bound.bitDepthMinus8)) + 8
        sps.bitDepthChroma = Int(try r.ue("bit_depth_chroma_minus8", max: Bound.bitDepthMinus8)) + 8
        sps.log2MaxPicOrderCntLsb = Int(try r.ue("log2_max_pic_order_cnt_lsb_minus4",
                                                 max: Bound.log2MaxPicOrderCntLsbMinus4)) + 4

        // sps_sub_layer_ordering_info_present_flag: when 0 only the top sub-layer's triple is
        // coded and applies to all of them, so the loop starts at `maxSub` instead of 0.
        let orderingInfoPresent = try r.flag()
        for i in (orderingInfoPresent ? 0 : maxSub) ... maxSub {
            let buffering = try r.ue("sps_max_dec_pic_buffering_minus1", max: Bound.decPicBuffering)
            let reorder = try r.ue("sps_max_num_reorder_pics", max: Bound.decPicBuffering)
            _ = try r.ue()                                  // sps_max_latency_increase_plus1
            if i == maxSub {
                sps.maxDecPicBuffering = Int(buffering) + 1
                sps.maxNumReorderPics = Int(reorder)
            }
        }

        sps.minCbLog2SizeY = Int(try r.ue("log2_min_luma_coding_block_size_minus3",
                                          max: Bound.log2MinCbSizeMinus3)) + 3
        let diffMaxMin = Int(try r.ue("log2_diff_max_min_luma_coding_block_size", max: 4))
        sps.ctbLog2SizeY = sps.minCbLog2SizeY + diffMaxMin
        guard sps.ctbLog2SizeY >= 4, sps.ctbLog2SizeY <= 6 else {
            throw BitstreamError.valueOutOfRange(field: "CtbLog2SizeY",
                                                 value: UInt64(sps.ctbLog2SizeY))
        }
        _ = try r.ue("log2_min_luma_transform_block_size_minus2", max: 4)
        _ = try r.ue("log2_diff_max_min_luma_transform_block_size", max: 4)
        sps.maxTransformHierarchyDepthInter = Int(try r.ue("max_transform_hierarchy_depth_inter",
                                                           max: 8))
        sps.maxTransformHierarchyDepthIntra = Int(try r.ue("max_transform_hierarchy_depth_intra",
                                                           max: 8))

        if try r.flag() {                                   // scaling_list_enabled_flag
            if try r.flag() { try skipScalingListData(&r) } // sps_scaling_list_data_present_flag
        }
        sps.ampEnabled = try r.flag()
        sps.saoEnabled = try r.flag()
        sps.pcmEnabled = try r.flag()
        if sps.pcmEnabled {
            try r.skip(4)                                   // pcm_sample_bit_depth_luma_minus1
            try r.skip(4)                                   // pcm_sample_bit_depth_chroma_minus1
            _ = try r.ue("log2_min_pcm_luma_coding_block_size_minus3", max: 3)
            _ = try r.ue("log2_diff_max_min_pcm_luma_coding_block_size", max: 3)
            try r.skip(1)                                   // pcm_loop_filter_disabled_flag
        }

        let setCount = Int(try r.ue("num_short_term_ref_pic_sets", max: Bound.shortTermRefPicSets))
        sps.numShortTermRefPicSets = setCount
        var numDeltaPocs = [Int]()
        numDeltaPocs.reserveCapacity(setCount)
        for i in 0 ..< setCount {
            numDeltaPocs.append(try skipShortTermRefPicSet(&r, stRpsIdx: i,
                                                           numShortTermRefPicSets: setCount,
                                                           numDeltaPocs: numDeltaPocs))
        }
        sps.numDeltaPocs = numDeltaPocs

        sps.longTermRefPicsPresent = try r.flag()
        if sps.longTermRefPicsPresent {
            let count = try r.ue("num_long_term_ref_pics_sps", max: Bound.longTermRefPicsSPS)
            for _ in 0 ..< count {
                // The POC LSB field is `log2MaxPicOrderCntLsb` bits wide — 4…16, not a fixed 8 or
                // 16. Using a constant here is a real bug seen in third-party code: it shifts the
                // VUI and silently produces the wrong frame rate.
                try r.skip(sps.log2MaxPicOrderCntLsb)       // lt_ref_pic_poc_lsb_sps[i]
                try r.skip(1)                               // used_by_curr_pic_lt_sps_flag[i]
            }
        }

        sps.temporalMVPEnabled = try r.flag()
        sps.strongIntraSmoothingEnabled = try r.flag()

        sps.vuiPresent = try r.flag()
        if sps.vuiPresent {
            do {
                try parseVUI(&r, into: &sps, maxSubLayersMinus1: maxSub)
            } catch {
                // Lenient by design (§13.6): keep the partial VUI, never fail the SPS.
                sps.vuiParseFailed = true
            }
        }
        if !sps.vuiParseFailed {
            // `sps_extension_present_flag`, read for the bit count and then discarded — everything
            // past it is an extension Vigil does not parse. A NAL truncated at exactly this bit is
            // nonconformant but harmless, so the failure is swallowed rather than discarding a
            // picture size we have already recovered in full. Skipped after a VUI failure, where
            // the reader is at an unknown position and the bit would be meaningless.
            _ = try? r.flag()
        }

        sps.debugBitsConsumed = r.bitOffset
        sps.debugBitsAvailable = totalBits
        return sps
    }

    // MARK: - Validation

    private static func validateDimensions(_ value: Int, field: String) throws(BitstreamError) {
        guard value >= Bound.minPictureDimension, value <= Bound.maxPictureDimension else {
            throw BitstreamError.valueOutOfRange(field: field, value: UInt64(max(value, 0)))
        }
    }

    /// A conformance window may not remove the whole picture. Checked before the offsets are used,
    /// so a hostile SPS cannot produce a zero or negative display size downstream.
    private static func validateConformanceWindow(_ sps: H265SPS) throws(BitstreamError) {
        let window = sps.conformanceWindow
        guard window.left >= 0, window.right >= 0, window.top >= 0, window.bottom >= 0 else {
            throw BitstreamError.invalidCropping
        }
        let horizontal = sps.subWidthC * (window.left + window.right)
        let vertical = sps.subHeightC * (window.top + window.bottom)
        guard horizontal < sps.picWidthInLumaSamples, vertical < sps.picHeightInLumaSamples else {
            throw BitstreamError.invalidCropping
        }
    }

    // MARK: - scaling_list_data()

    /// Consumes `scaling_list_data()` (H.265 §7.3.4) without reconstructing the matrices.
    ///
    /// The `step = 3` for `sizeId == 3` is mandatory and is the trap: the 32×32 size has only two
    /// matrices, intra and inter, so `matrixId` takes the values 0 and 3 rather than 0…5. Looping
    /// six times there over-reads 4 × 65 `se(v)` codes and desynchronises everything after.
    private static func skipScalingListData(_ r: inout RBSPBitReader) throws(BitstreamError) {
        for sizeID in 0 ..< 4 {
            var matrixID = 0
            let step = (sizeID == 3) ? 3 : 1
            while matrixID < 6 {
                if try !r.flag() {                          // scaling_list_pred_mode_flag == 0
                    _ = try r.ue("scaling_list_pred_matrix_id_delta", max: 6)
                } else {
                    let coefCount = min(64, 1 << (4 + (sizeID << 1)))   // 16, 64, 64, 64
                    if sizeID > 1 { _ = try r.se() }        // scaling_list_dc_coef_minus8
                    for _ in 0 ..< coefCount { _ = try r.se() }         // scaling_list_delta_coef
                }
                matrixID += step
            }
        }
    }

    // MARK: - st_ref_pic_set()

    /// Consumes one `st_ref_pic_set(stRpsIdx)` (H.265 §7.3.7) and returns `NumDeltaPocs[stRpsIdx]`.
    ///
    /// Two details are the whole difficulty, and both are silent when wrong:
    ///
    /// * `inter_ref_pic_set_prediction_flag` is **absent** when `stRpsIdx == 0`, inferred as 0.
    /// * On the inter-predicted path the loop bound is `0 ... NumDeltaPocs[RefRpsIdx]` —
    ///   **inclusive**, i.e. one more iteration than the reference set has delta-POCs, because the
    ///   index also ranges over the reference picture itself (H.265 equations 7-59…7-61).
    ///
    /// The returned count is *not* `NumDeltaPocs[RefRpsIdx]`: it is the number of indices for which
    /// `used_by_curr_pic_flag` or `use_delta_flag` was set, since each such index contributes
    /// exactly one entry to the negative or positive delta-POC list.
    ///
    /// - Parameter numDeltaPocs: the values already derived for indices `0 ..< stRpsIdx`.
    private static func skipShortTermRefPicSet(
        _ r: inout RBSPBitReader,
        stRpsIdx: Int,
        numShortTermRefPicSets: Int,
        numDeltaPocs: [Int]
    ) throws(BitstreamError) -> Int {
        var interPrediction = false
        if stRpsIdx != 0 { interPrediction = try r.flag() }

        guard interPrediction else {
            let negative = try r.ue("num_negative_pics", max: Bound.refPicsPerSet)
            let positive = try r.ue("num_positive_pics", max: Bound.refPicsPerSet)
            for _ in 0 ..< negative {
                _ = try r.ue()                              // delta_poc_s0_minus1[i]
                try r.skip(1)                               // used_by_curr_pic_s0_flag[i]
            }
            for _ in 0 ..< positive {
                _ = try r.ue()                              // delta_poc_s1_minus1[i]
                try r.skip(1)                               // used_by_curr_pic_s1_flag[i]
            }
            return Int(negative) + Int(positive)
        }

        // `delta_idx_minus1` exists only in the slice-header form of the syntax, where
        // stRpsIdx == num_short_term_ref_pic_sets. In the SPS it is absent and inferred as 0.
        var deltaIdxMinus1: UInt32 = 0
        if stRpsIdx == numShortTermRefPicSets {
            deltaIdxMinus1 = try r.ue("delta_idx_minus1", max: UInt32(max(stRpsIdx, 0)))
        }
        try r.skip(1)                                       // delta_rps_sign
        _ = try r.ue()                                      // abs_delta_rps_minus1
        let refRpsIdx = stRpsIdx - (Int(deltaIdxMinus1) + 1)
        guard refRpsIdx >= 0, refRpsIdx < numDeltaPocs.count else {
            throw BitstreamError.unsupportedSyntax(
                "st_ref_pic_set RefRpsIdx \(refRpsIdx) outside 0..<\(numDeltaPocs.count)")
        }
        var count = 0
        for _ in 0 ... numDeltaPocs[refRpsIdx] {            // inclusive — see the note above
            let usedByCurrPic = try r.flag()                // used_by_curr_pic_flag[j]
            var useDelta = true
            if !usedByCurrPic { useDelta = try r.flag() }   // use_delta_flag[j]
            if usedByCurrPic || useDelta { count += 1 }
        }
        return count
    }

    // MARK: - vui_parameters()

    /// Parses the H.265 VUI (H.265 §E.2.1) into `sps`.
    ///
    /// The field order differs from H.264 in two ways that matter: three extra flags
    /// (`neutral_chroma_indication_flag`, `field_seq_flag`, `frame_field_info_present_flag`) and the
    /// `default_display_window` sit between the chroma-location block and the timing block, and the
    /// timing block has no `fixed_frame_rate_flag`. Writing this against the H.264 layout shifts the
    /// timing fields and produces a wrong frame rate that still looks plausible.
    ///
    /// Throwing from here is expected and handled by the caller: everything already written into
    /// `sps` is retained.
    private static func parseVUI(
        _ r: inout RBSPBitReader, into sps: inout H265SPS, maxSubLayersMinus1: Int
    ) throws(BitstreamError) {
        if try r.flag() {                                   // aspect_ratio_info_present_flag
            let idc = UInt8(truncatingIfNeeded: try r.u(8))
            if idc == 255 {                                 // Extended_SAR
                let width = Int(try r.u(16))
                let height = Int(try r.u(16))
                if width > 0, height > 0 { sps.sarWidth = width; sps.sarHeight = height }
            } else if let entry = SampleAspectRatio.table[idc] {
                sps.sarWidth = entry.0
                sps.sarHeight = entry.1
            }                                               // reserved idc: leave 1:1
        }
        if try r.flag() { try r.skip(1) }                   // overscan_appropriate_flag
        if try r.flag() {                                   // video_signal_type_present_flag
            try r.skip(3)                                   // video_format
            sps.videoFullRangeFlag = try r.flag()
            if try r.flag() {                               // colour_description_present_flag
                sps.colourPrimaries = UInt8(truncatingIfNeeded: try r.u(8))
                sps.transferCharacteristics = UInt8(truncatingIfNeeded: try r.u(8))
                sps.matrixCoefficients = UInt8(truncatingIfNeeded: try r.u(8))
            }
        }
        if try r.flag() {                                   // chroma_loc_info_present_flag
            _ = try r.ue("chroma_sample_loc_type_top_field", max: 5)
            _ = try r.ue("chroma_sample_loc_type_bottom_field", max: 5)
        }
        try r.skip(1)                                       // neutral_chroma_indication_flag
        sps.fieldSeqFlag = try r.flag()
        sps.frameFieldInfoPresent = try r.flag()
        if try r.flag() {                                   // default_display_window_flag
            sps.defaultDisplayWindow = CropOffsets(left: Int(try r.ue()), right: Int(try r.ue()),
                                                   top: Int(try r.ue()), bottom: Int(try r.ue()))
        }
        if try r.flag() {                                   // vui_timing_info_present_flag
            sps.numUnitsInTick = try r.u(32)
            sps.timeScale = try r.u(32)
            if try r.flag() {                               // vui_poc_proportional_to_timing_flag
                _ = try r.ue()                              // vui_num_ticks_poc_diff_one_minus1
            }
            if try r.flag() {                               // vui_hrd_parameters_present_flag
                try skipHRDParameters(&r, commonInfPresent: true,
                                      maxNumSubLayersMinus1: maxSubLayersMinus1)
            }
        }
        if try r.flag() {                                   // bitstream_restriction_flag
            try r.skip(1)                                   // tiles_fixed_structure_flag
            try r.skip(1)                                   // motion_vectors_over_pic_boundaries_flag
            try r.skip(1)                                   // restricted_ref_pic_lists_flag
            sps.minSpatialSegmentationIDC =
                Int(try r.ue("min_spatial_segmentation_idc", max: 4095))
            _ = try r.ue()                                  // max_bytes_per_pic_denom
            _ = try r.ue()                                  // max_bits_per_min_cu_denom
            _ = try r.ue()                                  // log2_max_mv_length_horizontal
            _ = try r.ue()                                  // log2_max_mv_length_vertical
        }
    }

    // MARK: - hrd_parameters()

    /// Consumes `hrd_parameters()` (H.265 §E.2.2). Parsed only so that the bitstream-restriction
    /// block that follows it — and therefore `min_spatial_segmentation_idc` — can be reached.
    ///
    /// `fixed_pic_rate_within_cvs_flag` is **inferred** equal to `fixed_pic_rate_general_flag` when
    /// the latter is 1 and is not coded; reading it unconditionally shifts the rest of the loop.
    private static func skipHRDParameters(
        _ r: inout RBSPBitReader, commonInfPresent: Bool, maxNumSubLayersMinus1: Int
    ) throws(BitstreamError) {
        var nalHRD = false
        var vclHRD = false
        var subPicParams = false
        if commonInfPresent {
            nalHRD = try r.flag()                           // nal_hrd_parameters_present_flag
            vclHRD = try r.flag()                           // vcl_hrd_parameters_present_flag
            if nalHRD || vclHRD {
                subPicParams = try r.flag()                 // sub_pic_hrd_params_present_flag
                if subPicParams {
                    try r.skip(8)                           // tick_divisor_minus2
                    try r.skip(5)                           // du_cpb_removal_delay_increment_length
                    try r.skip(1)                           // sub_pic_cpb_params_in_pic_timing_sei
                    try r.skip(5)                           // dpb_output_delay_du_length_minus1
                }
                try r.skip(4)                               // bit_rate_scale
                try r.skip(4)                               // cpb_size_scale
                if subPicParams { try r.skip(4) }           // cpb_size_du_scale
                try r.skip(5)                               // initial_cpb_removal_delay_length
                try r.skip(5)                               // au_cpb_removal_delay_length_minus1
                try r.skip(5)                               // dpb_output_delay_length_minus1
            }
        }
        for _ in 0 ... maxNumSubLayersMinus1 {
            let fixedPicRateGeneral = try r.flag()
            var fixedPicRateWithinCVS = true
            if !fixedPicRateGeneral { fixedPicRateWithinCVS = try r.flag() }
            var lowDelay = false
            if fixedPicRateWithinCVS {
                _ = try r.ue("elemental_duration_in_tc_minus1", max: 2047)
            } else {
                lowDelay = try r.flag()                     // low_delay_hrd_flag
            }
            var cpbCount = 1
            if !lowDelay { cpbCount = Int(try r.ue("cpb_cnt_minus1", max: 31)) + 1 }
            if nalHRD { try skipSubLayerHRD(&r, cpbCount: cpbCount, subPicParams: subPicParams) }
            if vclHRD { try skipSubLayerHRD(&r, cpbCount: cpbCount, subPicParams: subPicParams) }
        }
    }

    /// Consumes one `sub_layer_hrd_parameters()` (H.265 §E.2.3).
    private static func skipSubLayerHRD(
        _ r: inout RBSPBitReader, cpbCount: Int, subPicParams: Bool
    ) throws(BitstreamError) {
        for _ in 0 ..< cpbCount {
            _ = try r.ue()                                  // bit_rate_value_minus1
            _ = try r.ue()                                  // cpb_size_value_minus1
            if subPicParams {
                _ = try r.ue()                              // cpb_size_du_value_minus1
                _ = try r.ue()                              // bit_rate_du_value_minus1
            }
            try r.skip(1)                                   // cbr_flag
        }
    }
}

// MARK: - Typed-throws pointer bridge

/// Runs `body` over `bytes` as a raw buffer while preserving typed throws.
///
/// `withUnsafeBytes` is `rethrows`, which erases a `BitstreamError` to `any Error` and would force
/// every caller into a catch-all. The `Result` capture keeps the error type intact.
private func withNALPointer<T>(
    _ bytes: [UInt8],
    _ body: (UnsafeRawBufferPointer) throws(BitstreamError) -> T
) throws(BitstreamError) -> T {
    var outcome: Result<T, BitstreamError>?
    bytes.withUnsafeBytes { raw in
        do {
            outcome = .success(try body(raw))
        } catch let error as BitstreamError {
            outcome = .failure(error)
        } catch {
            // Unreachable: `body` is typed `throws(BitstreamError)`. The clause exists only because
            // `withUnsafeBytes` is `rethrows`, which erases the closure's thrown type to `any Error`.
            outcome = .failure(.unsupportedSyntax("unexpected error from a typed-throws closure"))
        }
    }
    switch outcome {
    case .success(let value): return value
    case .failure(let error): throw error
    case nil: throw BitstreamError.emptyNALUnit   // unreachable: the closure always runs
    }
}
