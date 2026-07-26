//
//  H264PPS.swift
//  VigilBitstream
//
//  The parsed H.264 picture parameter set and the minimal §7.3.2.2 parse that produces it.
//  See docs/spec-bitstream.md §9 and docs/API_CONTRACT.md §4.2.
//

import VigilProtocols

// MARK: - H264PPS

/// A parsed H.264 picture parameter set.
///
/// **We parse a PPS for metadata and store keying, never for decode.** The decoder always receives
/// the original PPS bytes, and a PPS whose parse throws is still stored and still forwarded. That is
/// what makes the deliberately partial parse of docs/spec-bitstream.md §9 legitimate rather than
/// lazy: everything past `transform_8x8_mode_flag` — the scaling matrices and
/// `second_chroma_qp_index_offset` — is skipped because nothing in Vigil consumes it.
public struct H264PPS: Sendable, Hashable, Codable {

    /// `pic_parameter_set_id`. The key the store uses and a slice header references.
    public var picParameterSetID: UInt32 = 0

    /// `seq_parameter_set_id`. Binds this PPS to an SPS; a mismatch means we hold an orphan PPS and
    /// must wait for the SPS it names.
    public var seqParameterSetID: UInt32 = 0

    /// `entropy_coding_mode_flag`. True is CABAC, false CAVLC. Diagnostics and a decode-cost input.
    public var entropyCodingModeFlag = false

    /// `bottom_field_pic_order_in_frame_present_flag`. Required to parse a slice header past
    /// `pic_order_cnt_lsb`, which is why it is kept even though the live path never does.
    public var bottomFieldPicOrderInFramePresentFlag = false

    /// True when `num_slice_groups_minus1 > 0`, i.e. the PPS uses FMO/ASO.
    ///
    /// The parse stops there and every field below keeps its default. No Hikvision or Dahua encoder
    /// has ever been observed to emit slice groups, and H.264 High and Main forbid them; decode
    /// still works because the decoder parses the PPS itself from the bytes we forward.
    public var usesSliceGroups = false

    /// `num_ref_idx_l0_default_active_minus1 + 1`.
    public var numRefIdxL0DefaultActive = 1

    /// `num_ref_idx_l1_default_active_minus1 + 1`.
    public var numRefIdxL1DefaultActive = 1

    /// `weighted_pred_flag`.
    public var weightedPredFlag = false

    /// `weighted_bipred_idc`, 0…3.
    public var weightedBipredIDC: UInt8 = 0

    /// `pic_init_qp_minus26 + 26`, the initial quantiser. Shown in the diagnostics overlay.
    public var picInitQP = 26

    /// `deblocking_filter_control_present_flag`.
    public var deblockingFilterControlPresentFlag = false

    /// `constrained_intra_pred_flag`.
    public var constrainedIntraPredFlag = false

    /// `redundant_pic_cnt_present_flag`.
    public var redundantPicCntPresentFlag = false

    /// `transform_8x8_mode_flag`, present only when `more_rbsp_data()` is true at the decision
    /// point. The High-profile marker.
    public var transform8x8ModeFlag = false

    /// RBSP bits the parse consumed; see `H264SPS.debugBitsConsumed`.
    public var debugBitsConsumed = 0

    /// Total bits in the unescaped RBSP.
    public var debugBitsAvailable = 0

    /// Builds an all-defaults PPS.
    public init() {}
}

// MARK: - Parsing

public extension H264Parser {

    /// Parses a picture parameter set, as far as docs/spec-bitstream.md §9.1 specifies.
    ///
    /// - Parameter nal: The PPS NAL unit **including** its one-byte header and **excluding** any
    ///   start code or length prefix.
    /// - Throws: `.emptyNALUnit`, `.tooLarge` past `Limits.maxParameterSetBytes`, `.wrongNALType`
    ///   when the type is not 8, `.forbiddenBitSet` for a corrupt header, `.unexpectedEndOfData` for
    ///   a truncated PPS, and `.valueOutOfRange` for an out-of-range id.
    /// - Note: A PPS that declares slice groups is **not** an error. It returns with
    ///   `usesSliceGroups == true` and the remaining fields at their defaults.
    static func parsePPS(_ nal: UnsafeRawBufferPointer) throws(BitstreamError) -> H264PPS {
        guard nal.count >= 1 else { throw BitstreamError.emptyNALUnit }
        guard nal.count <= Limits.maxParameterSetBytes else {
            throw BitstreamError.tooLarge(bytes: nal.count)
        }
        let header = try NALHeader.decodeH264(nal[0])
        guard header.type == H264NALType.pps.rawValue else {
            throw BitstreamError.wrongNALType(expected: H264NALType.pps.rawValue, found: header.type)
        }
        let rbsp = try RBSP.unescape(nal, skippingHeaderBytes: 1)
        var reader = try RBSPBitReader(rbsp: rbsp)
        var pps = H264PPS()
        pps.debugBitsAvailable = rbsp.count * 8

        pps.picParameterSetID = try reader.ue("pic_parameter_set_id", max: Limits.maxH264PPSID)
        pps.seqParameterSetID = try reader.ue("seq_parameter_set_id", max: Limits.maxH264SPSID)
        pps.entropyCodingModeFlag = try reader.flag()
        pps.bottomFieldPicOrderInFramePresentFlag = try reader.flag()

        let sliceGroupsMinus1 = try reader.ue()
        if sliceGroupsMinus1 > 0 {
            // FMO/ASO. Abandon the parse, keep the bytes: the decoder handles what we do not.
            pps.usesSliceGroups = true
            pps.debugBitsConsumed = reader.bitOffset
            return pps
        }

        pps.numRefIdxL0DefaultActive = Int(try reader.ue("num_ref_idx_l0_default_active_minus1",
                                                         max: 31)) + 1
        pps.numRefIdxL1DefaultActive = Int(try reader.ue("num_ref_idx_l1_default_active_minus1",
                                                         max: 31)) + 1
        pps.weightedPredFlag = try reader.flag()
        pps.weightedBipredIDC = UInt8(truncatingIfNeeded: try reader.u(2))
        pps.picInitQP = 26 + Int(try reader.se("pic_init_qp_minus26", min: -62, max: 51))
        _ = try reader.se()                                     // pic_init_qs_minus26
        _ = try reader.se()                                     // chroma_qp_index_offset
        pps.deblockingFilterControlPresentFlag = try reader.flag()
        pps.constrainedIntraPredFlag = try reader.flag()
        pps.redundantPicCntPresentFlag = try reader.flag()

        // The `more_rbsp_data()` decision point. P1 and P2 of docs/spec-bitstream.md §9.3 differ in
        // exactly this bit and are the canonical regression pair for it.
        if reader.moreRBSPData() {
            pps.transform8x8ModeFlag = try reader.flag()
        }
        pps.debugBitsConsumed = reader.bitOffset
        return pps
    }
}
