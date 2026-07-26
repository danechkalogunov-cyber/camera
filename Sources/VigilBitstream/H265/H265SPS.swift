//
//  H265SPS.swift
//  VigilBitstream
//
//  The parsed model of an H.265 sequence parameter set, and the derivations that turn it into a
//  picture size: chroma subsampling, the conformance window, the CTB size and the VUI frame rate.
//  Implements docs/spec-bitstream.md §13.5 and §13.7.
//

// MARK: - H265SPS

/// Everything Vigil keeps from an H.265 sequence parameter set (ITU-T H.265 §7.3.2.2.1).
///
/// The model is deliberately wider than the decoder needs: `numDeltaPocs`, `maxTransformHierarchy*`
/// and the CTB sizes exist because they are the evidence that the parse stayed in step with the
/// bitstream, and a diagnostics HUD that can show them turns "the picture is wrong" into a
/// five-minute diagnosis. Only the geometry and the bit depths reach `VideoFormatInfo`.
///
/// Every field carries the value the bitstream stated. Nothing here is clamped or corrected; the
/// parser throws on an out-of-range value rather than storing a repaired one.
public struct H265SPS: Sendable, Hashable, Codable {

    // MARK: - Identity

    /// `sps_video_parameter_set_id`, 0…15. Binds this SPS to a VPS.
    public var vpsID: UInt8 = 0

    /// `sps_max_sub_layers_minus1`, 0…6. Hikvision emits 0 live and 1 on some NVR transcodes.
    public var maxSubLayersMinus1: UInt8 = 0

    /// `sps_temporal_id_nesting_flag`. The authoritative source of `hvcC.temporalIdNested`.
    public var temporalIDNestingFlag: Bool = false

    /// The `profile_tier_level()` structure. Ten bytes of `hvcC` come from here (§11).
    public var ptl: ProfileTierLevel = ProfileTierLevel()

    /// `sps_seq_parameter_set_id`, 0…15. The store key.
    public var spsID: UInt32 = 0

    // MARK: - Picture format

    /// `chroma_format_idc`: 0 monochrome, 1 = 4:2:0, 2 = 4:2:2, 3 = 4:4:4.
    public var chromaFormatIDC: UInt8 = 1

    /// `separate_colour_plane_flag`; only present when `chroma_format_idc == 3`. When set, the
    /// three planes are coded independently and `SubWidthC`/`SubHeightC` both become 1.
    public var separateColourPlaneFlag: Bool = false

    /// `pic_width_in_luma_samples`. This is the **coded** width; allocate from it.
    public var picWidthInLumaSamples: Int = 0

    /// `pic_height_in_luma_samples`. The coded height.
    public var picHeightInLumaSamples: Int = 0

    /// `conf_win_*_offset`, in **chroma sample units** — multiply by `SubWidthC`/`SubHeightC`
    /// before subtracting. Zero when `conformance_window_flag` was 0.
    public var conformanceWindow: CropOffsets = .zero

    /// `bit_depth_luma_minus8 + 8`. 8 for Main, 10 for Main 10.
    public var bitDepthLuma: Int = 8

    /// `bit_depth_chroma_minus8 + 8`.
    public var bitDepthChroma: Int = 8

    /// `log2_max_pic_order_cnt_lsb_minus4 + 4`, 4…16. The width of every long-term POC LSB field,
    /// which is why a wrong value here shifts the VUI and produces a wrong frame rate.
    public var log2MaxPicOrderCntLsb: Int = 4

    /// `sps_max_dec_pic_buffering_minus1[maxSubLayers] + 1`.
    public var maxDecPicBuffering: Int = 0

    /// `sps_max_num_reorder_pics[maxSubLayers]`. Zero on every live surveillance profile, which is
    /// what lets `EncodedFrame.dts` stay `nil`.
    public var maxNumReorderPics: Int = 0

    // MARK: - Coding tools

    /// `log2_min_luma_coding_block_size_minus3 + 3`, i.e. `MinCbLog2SizeY`, 3…6.
    public var minCbLog2SizeY: Int = 3

    /// `MinCbLog2SizeY + log2_diff_max_min_luma_coding_block_size`, i.e. `CtbLog2SizeY`, 4…6.
    public var ctbLog2SizeY: Int = 4

    /// `max_transform_hierarchy_depth_inter`. Diagnostics only.
    public var maxTransformHierarchyDepthInter: Int = 0

    /// `max_transform_hierarchy_depth_intra`. Diagnostics only.
    public var maxTransformHierarchyDepthIntra: Int = 0

    /// `amp_enabled_flag`.
    public var ampEnabled: Bool = false

    /// `sample_adaptive_offset_enabled_flag`.
    public var saoEnabled: Bool = false

    /// `pcm_enabled_flag`.
    public var pcmEnabled: Bool = false

    /// `num_short_term_ref_pic_sets`, 0…64.
    public var numShortTermRefPicSets: Int = 0

    /// `NumDeltaPocs[i]` for each short-term reference picture set, in bitstream order.
    ///
    /// Retained because it is the only externally visible proof that the `st_ref_pic_set()` loop —
    /// including the inter-predicted path that reads `NumDeltaPocs[RefRpsIdx] + 1` flag groups —
    /// consumed exactly the right number of bits.
    public var numDeltaPocs: [Int] = []

    /// `long_term_ref_pics_present_flag`.
    public var longTermRefPicsPresent: Bool = false

    /// `sps_temporal_mvp_enabled_flag`. Immediately follows the reference-picture-set section, so a
    /// wrong value here is the first visible symptom of a desynchronised RPS loop.
    public var temporalMVPEnabled: Bool = false

    /// `strong_intra_smoothing_enabled_flag`.
    public var strongIntraSmoothingEnabled: Bool = false

    // MARK: - VUI

    /// `vui_parameters_present_flag`.
    public var vuiPresent: Bool = false

    /// True when the VUI was present but its parse threw. Everything decoded before the failure is
    /// kept; everything after it holds its default. Never fails the SPS parse (§13.6).
    public var vuiParseFailed: Bool = false

    /// Sample aspect ratio numerator; 1 when the VUI is absent, says square, or is out of range.
    public var sarWidth: Int = 1

    /// Sample aspect ratio denominator.
    public var sarHeight: Int = 1

    /// `field_seq_flag`. When set the stream codes fields, not frames.
    public var fieldSeqFlag: Bool = false

    /// `frame_field_info_present_flag`.
    public var frameFieldInfoPresent: Bool = false

    /// `default_display_window` offsets, in chroma units. **Parsed but deliberately not applied**
    /// (spec-bitstream §13.5): it is an authoring hint, VideoToolbox ignores it, and applying it
    /// would make our reported size disagree with the decoded pixel buffer. Diagnostics only.
    public var defaultDisplayWindow: CropOffsets?

    /// `vui_num_units_in_tick`. `nil` when the VUI carried no timing information.
    public var numUnitsInTick: UInt32?

    /// `vui_time_scale`. H.265 counts **frame** ticks, so fps is `timeScale / numUnitsInTick` with
    /// no factor of two — the asymmetry with H.264 that causes most reported-fps bugs.
    public var timeScale: UInt32?

    /// `colour_primaries`, when `colour_description_present_flag` was set.
    public var colourPrimaries: UInt8?

    /// `transfer_characteristics`.
    public var transferCharacteristics: UInt8?

    /// `matrix_coeffs`.
    public var matrixCoefficients: UInt8?

    /// `video_full_range_flag`. False (studio swing) on every camera we have met.
    public var videoFullRangeFlag: Bool = false

    /// `min_spatial_segmentation_idc` from the bitstream-restriction block; 0 when absent.
    /// The only reason the H.265 HRD is skipped rather than ignored: it sits after the HRD and
    /// feeds `hvcC` offset 13.
    public var minSpatialSegmentationIDC: Int = 0

    // MARK: - Diagnostics

    /// RBSP bits consumed by the parse, up to and including `sps_extension_present_flag`.
    ///
    /// Compared against `debugBitsAvailable` in the regression suite: the two must agree to within
    /// the 1…8 bits of `rbsp_trailing_bits()`, which proves every skip loop landed on the right bit.
    public var debugBitsConsumed: Int = 0

    /// Total RBSP bits available, i.e. eight times the unescaped payload length.
    public var debugBitsAvailable: Int = 0

    // MARK: - Initialisation

    /// Builds an all-default SPS. The parser fills it in field by field so that a lenient VUI
    /// failure keeps whatever was already decoded.
    public init() {}

    // MARK: - Derivations

    /// `SubWidthC` from H.265 Table 6-1: 2 for 4:2:0 and 4:2:2, otherwise 1.
    @inlinable public var subWidthC: Int {
        if separateColourPlaneFlag { return 1 }
        return (chromaFormatIDC == 1 || chromaFormatIDC == 2) ? 2 : 1
    }

    /// `SubHeightC` from H.265 Table 6-1: 2 for 4:2:0 only.
    @inlinable public var subHeightC: Int {
        if separateColourPlaneFlag { return 1 }
        return chromaFormatIDC == 1 ? 2 : 1
    }

    /// Coded width in luma samples — the size a pixel buffer is allocated at.
    @inlinable public var codedWidth: Int { picWidthInLumaSamples }

    /// Coded height in luma samples.
    @inlinable public var codedHeight: Int { picHeightInLumaSamples }

    /// Luma columns removed from the left by the conformance window.
    @inlinable public var cropLeft: Int { subWidthC * conformanceWindow.left }

    /// Luma rows removed from the top by the conformance window.
    @inlinable public var cropTop: Int { subHeightC * conformanceWindow.top }

    /// Displayed width: the coded width less `SubWidthC × (left + right)` conformance offsets.
    ///
    /// Unlike H.264's cropping the offsets are in chroma samples, so for 4:2:0 each unit removes
    /// **two** luma columns. Clamped at zero so a hostile window cannot produce a negative size.
    @inlinable public var displayWidth: Int {
        max(0, picWidthInLumaSamples - subWidthC * (conformanceWindow.left + conformanceWindow.right))
    }

    /// Displayed height, by the same rule with `SubHeightC`.
    @inlinable public var displayHeight: Int {
        max(0, picHeightInLumaSamples - subHeightC * (conformanceWindow.top + conformanceWindow.bottom))
    }

    /// `CtbSizeY`: 16, 32 or 64.
    @inlinable public var ctbSizeY: Int { 1 << ctbLog2SizeY }

    /// Coding tree blocks across the picture.
    @inlinable public var picWidthInCtbsY: Int {
        ctbSizeY == 0 ? 0 : (picWidthInLumaSamples + ctbSizeY - 1) / ctbSizeY
    }

    /// Coding tree blocks down the picture.
    @inlinable public var picHeightInCtbsY: Int {
        ctbSizeY == 0 ? 0 : (picHeightInLumaSamples + ctbSizeY - 1) / ctbSizeY
    }

    /// `sps_max_sub_layers_minus1 + 1`.
    @inlinable public var numTemporalLayers: Int { Int(maxSubLayersMinus1) + 1 }

    /// Frame rate from the VUI, or `nil` when there is no usable timing information.
    ///
    /// `timeScale / numUnitsInTick` — **no factor of two**, unlike H.264. Rejected, and reported as
    /// `nil`, when the tick is zero or the result falls outside 1…240 fps: a nonsense rate in the
    /// `hvcC` `avgFrameRate` field makes QuickTime misreport the movie, and the value is metadata
    /// only, so refusing it costs nothing.
    @inlinable public var frameRate: Double? {
        guard let tick = numUnitsInTick, let scale = timeScale, tick > 0 else { return nil }
        let fps = Double(scale) / Double(tick)
        guard fps >= 1.0, fps <= 240.0 else { return nil }
        return fps
    }

    /// True unless the VUI says the stream codes fields rather than frames.
    @inlinable public var isProgressive: Bool { !fieldSeqFlag }
}
