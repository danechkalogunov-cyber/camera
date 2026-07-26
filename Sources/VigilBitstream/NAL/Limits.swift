//
//  Limits.swift
//  VigilBitstream
//
//  The security-relevant bounds every parser in this module enforces before it allocates or loops
//  on an attacker-chosen count. See docs/spec-bitstream.md §4 and docs/API_CONTRACT.md §4.2.
//

// MARK: - Limits

/// Sanity bounds for syntax elements that arrive from the network.
///
/// Every value here comes from the table in docs/spec-bitstream.md §4. The parsers throw a
/// `BitstreamError` rather than clamping, except where the table says "clamp", because a camera on
/// a hostile LAN — or firmware with a byte-swap bug — will hand us a NAL that claims 4 GiB, a
/// scaling list with an absurd entry count, or a 65535×65535 picture, and none of those may reach
/// an allocation.
///
/// The one rule behind all of it: **no parser allocates a buffer whose size derives from a parsed
/// count**. The only count-driven allocations in the module are `offset_for_ref_frame`
/// (≤ `maxRefFramesInPOCCycle` `Int32`s) and the H.265 RPS bookkeeping array, both bounded here.
public enum Limits {

    // MARK: - Buffer sizes

    /// Largest NAL unit of any kind Vigil will look at, 4 MiB.
    ///
    /// A length-prefixed NAL longer than this is refused before it is copied. Real 4K keyframes are
    /// a few hundred kilobytes, so this is two orders of magnitude of headroom.
    public static let maxNALUnitBytes = 4 * 1024 * 1024

    /// Largest parameter-set NAL (SPS/PPS/VPS) we will parse, 4096 bytes.
    ///
    /// Anything larger is `BitstreamError.tooLarge`. The biggest parameter set observed in the wild
    /// is an H.265 SPS with full scaling lists, well under 1 KiB.
    public static let maxParameterSetBytes = 4096

    /// Largest SEI NAL we will parse, 64 KiB. Larger is `BitstreamError.tooLarge`.
    public static let maxSEIBytes = 65_536

    /// Largest NAL `RBSP.unescape` will copy, 64 KiB. Bounds the one allocation the parse path makes.
    public static let maxUnescapeBytes = 65_536

    /// Most parameter sets of one kind (VPS, SPS or PPS) a store will hold. Both codecs allow more
    /// ids than this; no camera uses them, and an unbounded store is a memory-growth bug.
    public static let maxParameterSetsPerType = 8

    /// Most NAL units one access unit may contain. Beyond this the access unit is truncated.
    public static let maxNALUnitsPerAccessUnit = 512

    // MARK: - Common syntax bounds

    /// Largest number of leading zeros an Exp-Golomb code may have before it is malformed.
    public static let maxExpGolombLeadingZeros = 32

    /// `chroma_format_idc`: 0 monochrome, 1 = 4:2:0, 2 = 4:2:2, 3 = 4:4:4.
    public static let maxChromaFormatIDC: UInt32 = 3

    /// `bit_depth_luma_minus8` / `bit_depth_chroma_minus8`, giving depths 8…16.
    public static let maxBitDepthMinus8: UInt32 = 8

    // MARK: - H.264 bounds

    /// `seq_parameter_set_id`.
    public static let maxH264SPSID: UInt32 = 31

    /// `pic_parameter_set_id`.
    public static let maxH264PPSID: UInt32 = 255

    /// `log2_max_frame_num_minus4` and `log2_max_pic_order_cnt_lsb_minus4`.
    public static let maxLog2Minus4: UInt32 = 12

    /// `pic_order_cnt_type`.
    public static let maxPicOrderCntType: UInt32 = 2

    /// `num_ref_frames_in_pic_order_cnt_cycle`; bounds the only H.264 count-driven allocation.
    public static let maxRefFramesInPOCCycle: UInt32 = 255

    /// `max_num_ref_frames`. The table says clamp, not throw: firmware over-reporting this is
    /// harmless to us because we do not run a DPB.
    public static let maxNumRefFrames = 16

    /// `cpb_cnt_minus1` in `hrd_parameters()`; bounds that skip loop.
    public static let maxCPBCountMinus1: UInt32 = 31

    /// `max_num_reorder_frames` and `max_dec_frame_buffering` in the VUI bitstream restriction.
    public static let maxReorderFrames: UInt32 = 32

    /// Largest single cropping or conformance-window offset, in that standard's crop units.
    ///
    /// One offset can never legitimately exceed the coded dimension it is measured against, and
    /// `maxCodedDimension` is the ceiling on that. The parser additionally checks the *sum* of each
    /// axis against the actual coded size; this bound exists so a 4-billion offset is refused before
    /// the arithmetic rather than after it.
    public static let maxCropOffset: UInt32 = 16_384

    /// Smallest coded luma width or height an H.264 stream may declare: one macroblock.
    public static let minH264CodedDimension = 16

    /// Smallest coded luma width or height an H.265 stream may declare: one minimum coding block.
    public static let minH265CodedDimension = 8

    /// Largest coded luma width or height Vigil will accept, in samples.
    ///
    /// 16384 is H.264's own ceiling and comfortably above H.265's 16888 practical limit for the
    /// profiles a camera emits. A picture larger than this would allocate gigabytes.
    public static let maxCodedDimension = 16_384

    /// `pic_width_in_mbs_minus1` and `pic_height_in_map_units_minus1`: 1024 macroblocks of 16
    /// samples each is exactly `maxCodedDimension`.
    public static let maxMacroblockDimensionMinus1: UInt32 = 1023

    // MARK: - H.265 bounds

    /// `sps_max_sub_layers_minus1` / `vps_max_sub_layers_minus1`.
    public static let maxSubLayersMinus1: UInt32 = 6

    /// `num_short_term_ref_pic_sets`; bounds the RPS bookkeeping array.
    public static let maxShortTermRefPicSets: UInt32 = 64

    /// `num_long_term_ref_pics_sps`.
    public static let maxLongTermRefPics: UInt32 = 32

    /// `log2_min_luma_coding_block_size_minus3`.
    public static let maxLog2MinLumaCBSizeMinus3: UInt32 = 3

    /// Accepted range of the derived `CtbLog2SizeY`, i.e. CTB sizes 16, 32 and 64.
    public static let ctbLog2SizeRange = 4...6
}
