//
//  H265PPS.swift
//  VigilBitstream
//
//  The H.265 picture parameter set, parsed as far as `entropy_coding_sync_enabled_flag` because
//  that flag and `tiles_enabled_flag` together define `hvcC.parallelismType`.
//  Implements docs/spec-bitstream.md §14.
//

import VigilProtocols

// MARK: - H265PPS

/// The fields Vigil keeps from an H.265 picture parameter set (ITU-T H.265 §7.3.2.3.1).
///
/// The parse stops after `entropy_coding_sync_enabled_flag`. Everything beyond it governs
/// deblocking, tile geometry and scaling lists, all of which the decoder parses for itself; we
/// parse a PPS for store keying and for the one `hvcC` field that is defined in terms of it.
///
/// A PPS whose parse throws is still stored and still forwarded to the decoder (§21.1); the only
/// consequence is `parallelismType == 0`, which every decoder accepts as "unknown".
public struct H265PPS: Sendable, Hashable, Codable {

    // MARK: - Stored Properties

    /// `pps_pic_parameter_set_id`, 0…63. The store key; a slice segment header references it.
    public var ppsID: UInt32

    /// `pps_seq_parameter_set_id`, 0…15. Binds this PPS to an SPS.
    public var spsID: UInt32

    /// `dependent_slice_segments_enabled_flag`. Retained because a future slice-header parse
    /// (recorded-playback POC reordering) cannot proceed without it.
    public var dependentSliceSegmentsEnabled: Bool

    /// `output_flag_present_flag`. Same reason.
    public var outputFlagPresent: Bool

    /// `num_extra_slice_header_bits`, 0…7. Same reason.
    public var numExtraSliceHeaderBits: UInt8

    /// `init_qp_minus26 + 26`. Shown in the diagnostics HUD.
    public var initQP: Int

    /// `tiles_enabled_flag`.
    public var tilesEnabled: Bool

    /// `entropy_coding_sync_enabled_flag` — wavefront parallel processing.
    public var entropyCodingSyncEnabled: Bool

    // MARK: - Initialisation

    /// Builds a value directly, for tests and for a caller that has no PPS bytes.
    public init(ppsID: UInt32 = 0, spsID: UInt32 = 0, dependentSliceSegmentsEnabled: Bool = false,
                outputFlagPresent: Bool = false, numExtraSliceHeaderBits: UInt8 = 0,
                initQP: Int = 26, tilesEnabled: Bool = false,
                entropyCodingSyncEnabled: Bool = false) {
        self.ppsID = ppsID
        self.spsID = spsID
        self.dependentSliceSegmentsEnabled = dependentSliceSegmentsEnabled
        self.outputFlagPresent = outputFlagPresent
        self.numExtraSliceHeaderBits = numExtraSliceHeaderBits
        self.initQP = initQP
        self.tilesEnabled = tilesEnabled
        self.entropyCodingSyncEnabled = entropyCodingSyncEnabled
    }

    // MARK: - Computed Properties

    /// `hvcC.parallelismType` per ISO/IEC 14496-15 §8.3.3.1.2.
    ///
    /// 0 unknown (tiles *and* wavefronts, which the field cannot express), 1 slice-based,
    /// 2 tile-based, 3 entropy-coding-sync based. Informational: every decoder tolerates 0.
    @inlinable public var parallelismType: UInt8 {
        H265PPS.parallelismType(tilesEnabled: tilesEnabled,
                                entropyCodingSync: entropyCodingSyncEnabled)
    }

    /// The `parallelismType` mapping, exposed for callers that hold the two flags but no PPS.
    public static func parallelismType(tilesEnabled: Bool, entropyCodingSync: Bool) -> UInt8 {
        switch (tilesEnabled, entropyCodingSync) {
        case (true, true): 0        // mixed tiles + WPP: not expressible, report "unknown"
        case (true, false): 2
        case (false, true): 3
        case (false, false): 1
        }
    }
}

// MARK: - Parsing

extension H265Parser {

    /// Parses an H.265 PPS NAL unit (type 34) as far as `entropy_coding_sync_enabled_flag`.
    ///
    /// `nal` includes the two-byte NAL header, escaped, with no start code.
    ///
    /// - Throws: `.wrongNALType` when the NAL is not type 34, `.valueOutOfRange` for an out-of-range
    ///   parameter-set id, `.unexpectedEndOfData` for a truncated NAL.
    public static func parsePPS(_ nal: UnsafeRawBufferPointer) throws(BitstreamError) -> H265PPS {
        guard nal.count >= 2 else { throw BitstreamError.emptyNALUnit }
        let type = (nal[0] >> 1) & 0x3F
        guard type == 34 else { throw BitstreamError.wrongNALType(expected: 34, found: type) }
        var r = try RBSPBitReader(nalUnit: nal, codec: .h265)

        var pps = H265PPS()
        pps.ppsID = try r.ue("pps_pic_parameter_set_id", max: 63)
        pps.spsID = try r.ue("pps_seq_parameter_set_id", max: 15)
        pps.dependentSliceSegmentsEnabled = try r.flag()
        pps.outputFlagPresent = try r.flag()
        pps.numExtraSliceHeaderBits = UInt8(truncatingIfNeeded: try r.u(3))
        try r.skip(1)                                       // sign_data_hiding_enabled_flag
        try r.skip(1)                                       // cabac_init_present_flag
        _ = try r.ue("num_ref_idx_l0_default_active_minus1", max: 14)
        _ = try r.ue("num_ref_idx_l1_default_active_minus1", max: 14)
        pps.initQP = Int(try r.se()) + 26
        try r.skip(1)                                       // constrained_intra_pred_flag
        try r.skip(1)                                       // transform_skip_enabled_flag
        if try r.flag() {                                   // cu_qp_delta_enabled_flag
            _ = try r.ue("diff_cu_qp_delta_depth", max: 3)
        }
        _ = try r.se()                                      // pps_cb_qp_offset
        _ = try r.se()                                      // pps_cr_qp_offset
        try r.skip(1)                                       // pps_slice_chroma_qp_offsets_present
        try r.skip(1)                                       // weighted_pred_flag
        try r.skip(1)                                       // weighted_bipred_flag
        try r.skip(1)                                       // transquant_bypass_enabled_flag
        pps.tilesEnabled = try r.flag()
        pps.entropyCodingSyncEnabled = try r.flag()
        return pps
    }
}
