//
//  H264SPS.swift
//  VigilBitstream
//
//  The parsed H.264 sequence parameter set and the geometry derived from it: coded size, cropped
//  display size, SAR, frame rate, profile and level names.
//  See docs/spec-bitstream.md §8.6, §8.7, §10 and docs/API_CONTRACT.md §4.2.
//

// MARK: - CropOffsets

/// The four cropping offsets of a parameter set: H.264 `frame_crop_*_offset`, H.265
/// `conf_win_*_offset` and `def_disp_win_*_offset`.
///
/// Units are as in the respective standard — macroblock-derived crop units for H.264, chroma sample
/// units for H.265 — so this type never converts anything; the owning SPS does.
///
/// A named struct rather than a tuple because the conformances are load-bearing: `VideoFormatInfo`
/// is persisted in the camera database and diffed for format-change detection, and a tuple can
/// conform to neither `Hashable` nor `Codable`.
public struct CropOffsets: Sendable, Hashable, Codable {

    /// Samples cropped from the left edge, in crop units.
    public var left: Int

    /// Samples cropped from the right edge, in crop units.
    public var right: Int

    /// Samples cropped from the top edge, in crop units.
    public var top: Int

    /// Samples cropped from the bottom edge, in crop units. The 1088 → 1080 case is `bottom = 4`
    /// with a crop unit of 2.
    public var bottom: Int

    /// Builds a set of offsets. Values are stored verbatim; the parser validates them against the
    /// coded size before the SPS is returned.
    public init(left: Int = 0, right: Int = 0, top: Int = 0, bottom: Int = 0) {
        self.left = left
        self.right = right
        self.top = top
        self.bottom = bottom
    }

    /// No cropping — what a stream without `frame_cropping_flag` gets.
    public static let zero = CropOffsets()

    /// True when nothing is cropped, so the display size equals the coded size.
    @inlinable public var isZero: Bool { left == 0 && right == 0 && top == 0 && bottom == 0 }
}

// MARK: - H264SPS

/// A parsed H.264 sequence parameter set.
///
/// Fields are grouped as raw syntax first, then VUI, then the derived geometry as computed
/// properties. **Report `displayWidth`/`displayHeight`; allocate from `codedWidth`/`codedHeight`.**
/// A 1080p Hikvision stream is coded 1920×1088 and displayed 1920×1080; reporting 1088 puts eight
/// rows of garbage at the bottom of every frame.
///
/// A `vuiParseFailed` value is still a usable SPS. The mandatory prefix is parsed strictly, but a
/// VUI failure only means the fields after the failure point kept their defaults — several
/// Hikvision firmware revisions emit an HRD block that does not match H.264 §E.1.2.
public struct H264SPS: Sendable, Hashable, Codable {

    // MARK: - Raw syntax

    /// `profile_idc`. 66 Baseline, 77 Main, 100 High are the values a camera emits.
    public var profileIDC: UInt8 = 0

    /// The six `constraint_setN_flag` bits plus two reserved bits, i.e. **exactly byte 2 of the SPS
    /// NAL**, which is also exactly `avcC.profile_compatibility`.
    ///
    /// Stored as the byte and never as six `Bool`s, which removes any chance of a bit-order mistake
    /// when the record is built.
    public var constraintFlags: UInt8 = 0

    /// `level_idc`, ten times the level number: 40 is level 4.0.
    public var levelIDC: UInt8 = 0

    /// `seq_parameter_set_id`, 0…31. The key a PPS references and the store keys on.
    public var seqParameterSetID: UInt32 = 0

    /// `chroma_format_idc`: 0 monochrome, 1 = 4:2:0, 2 = 4:2:2, 3 = 4:4:4. Defaults to 1 for the
    /// profiles that omit the chroma block.
    public var chromaFormatIDC: UInt8 = 1

    /// `separate_colour_plane_flag`. When set, `chromaArrayType` becomes 0 and the crop units change.
    public var separateColourPlaneFlag = false

    /// `bit_depth_luma_minus8 + 8`.
    public var bitDepthLuma = 8

    /// `bit_depth_chroma_minus8 + 8`.
    public var bitDepthChroma = 8

    /// `seq_scaling_matrix_present_flag`. The lists themselves are skipped, not stored —
    /// VideoToolbox re-parses the SPS — but the skip must consume exactly the right bits.
    public var seqScalingMatrixPresent = false

    /// `log2_max_frame_num_minus4 + 4`.
    public var log2MaxFrameNum = 4

    /// `pic_order_cnt_type`, 0…2.
    public var picOrderCntType: UInt8 = 0

    /// `log2_max_pic_order_cnt_lsb_minus4 + 4`; `nil` unless `picOrderCntType == 0`.
    public var log2MaxPicOrderCntLsb: Int?

    /// `delta_pic_order_always_zero_flag`; POC type 1 only.
    public var deltaPicOrderAlwaysZeroFlag = false

    /// `offset_for_non_ref_pic`; POC type 1 only.
    public var offsetForNonRefPic: Int32 = 0

    /// `offset_for_top_to_bottom_field`; POC type 1 only.
    public var offsetForTopToBottomField: Int32 = 0

    /// `offset_for_ref_frame[]`; POC type 1 only, at most `Limits.maxRefFramesInPOCCycle` entries.
    ///
    /// We do not use the values, but the array must be consumed or every later field is garbage.
    public var offsetForRefFrame: [Int32] = []

    /// `max_num_ref_frames`, clamped to `Limits.maxNumRefFrames` rather than rejected: over-reporting
    /// it is harmless to us because Vigil runs no DPB of its own.
    public var maxNumRefFrames = 1

    /// `gaps_in_frame_num_value_allowed_flag`.
    public var gapsInFrameNumValueAllowed = false

    /// `pic_width_in_mbs_minus1 + 1`.
    public var picWidthInMbs = 0

    /// `pic_height_in_map_units_minus1 + 1`. For an interlaced stream a map unit is a field pair,
    /// which is why `codedHeight` doubles it.
    public var picHeightInMapUnits = 0

    /// `frame_mbs_only_flag`. False means interlaced or MBAFF, which doubles both the height
    /// derivation and `cropUnitY`.
    public var frameMbsOnlyFlag = true

    /// `mb_adaptive_frame_field_flag`; present only when `frameMbsOnlyFlag` is false.
    public var mbAdaptiveFrameFieldFlag = false

    /// `direct_8x8_inference_flag`.
    public var direct8x8InferenceFlag = false

    /// `frame_crop_*_offset`, in crop units. Multiply by `cropUnitX`/`cropUnitY` for luma samples.
    public var frameCropping: CropOffsets = .zero

    // MARK: - VUI

    /// `vui_parameters_present_flag`.
    public var vuiPresent = false

    /// True when the VUI was present but did not parse. The SPS is still valid: everything before
    /// the failure point was read correctly, everything after it kept its default.
    public var vuiParseFailed = false

    /// `aspect_ratio_idc` as the stream stated it; `nil` when `aspect_ratio_info_present_flag` is 0.
    /// 255 is Extended_SAR, whose components were read from the bitstream.
    public var aspectRatioIDC: UInt8?

    /// Sample aspect ratio numerator. 1 unless the VUI said otherwise.
    public var sarWidth = 1

    /// Sample aspect ratio denominator.
    public var sarHeight = 1

    /// VUI `video_format`.
    public var videoFormat: UInt8?

    /// VUI `video_full_range_flag`. False is the 16–235 studio swing every camera emits.
    public var videoFullRangeFlag = false

    /// VUI `colour_primaries`.
    public var colourPrimaries: UInt8?

    /// VUI `transfer_characteristics`.
    public var transferCharacteristics: UInt8?

    /// VUI `matrix_coefficients`.
    public var matrixCoefficients: UInt8?

    /// VUI `num_units_in_tick`; `nil` when `timing_info_present_flag` is 0.
    public var numUnitsInTick: UInt32?

    /// VUI `time_scale`; `nil` when `timing_info_present_flag` is 0.
    public var timeScale: UInt32?

    /// VUI `fixed_frame_rate_flag`. A 0 here does not invalidate `frameRate`; it only means the
    /// encoder does not guarantee constant spacing.
    public var fixedFrameRateFlag = false

    /// True when either HRD block was present, so `pic_timing` SEI carries CPB/DPB delays.
    public var cpbDpbDelaysPresentFlag = false

    /// `cpb_removal_delay_length_minus1 + 1`, needed to parse `pic_timing` SEI. 24 is the default
    /// the standard specifies when no HRD is present.
    public var cpbRemovalDelayLength = 24

    /// `dpb_output_delay_length_minus1 + 1`, needed to parse `pic_timing` SEI.
    public var dpbOutputDelayLength = 24

    /// VUI `low_delay_hrd_flag`.
    public var lowDelayHRDFlag = false

    /// VUI `pic_struct_present_flag`. `pic_timing` SEI carries `pic_struct` only when this is set.
    public var picStructPresentFlag = false

    /// VUI `max_num_reorder_frames`. Zero is the "no reordering, decode with zero latency" signal
    /// `VigilVideo`'s low-latency path keys on.
    public var maxNumReorderFrames = 0

    /// VUI `max_dec_frame_buffering`.
    public var maxDecFrameBuffering = 0

    // MARK: - Parse diagnostics

    /// RBSP bits the parse consumed. Compared against `debugBitsAvailable` in the test suite: the
    /// two must agree to within the 1…8 bits of `rbsp_trailing_bits()`, which is what proves every
    /// skip loop — scaling lists, the POC type 1 cycle, the VUI's HRD — landed on the correct bit.
    public var debugBitsConsumed = 0

    /// Total bits in the unescaped RBSP.
    public var debugBitsAvailable = 0

    // MARK: - Initialisation

    /// Builds an all-defaults SPS. The parser fills it field by field; a hand-built value is useful
    /// only in tests, where the defaults are the ones H.264 specifies for an absent field.
    public init() {}

    // MARK: - Derived geometry

    /// `ChromaArrayType`: 0 when the colour planes are coded separately, else `chromaFormatIDC`.
    /// Decides both crop units.
    @inlinable public var chromaArrayType: UInt8 {
        separateColourPlaneFlag ? 0 : chromaFormatIDC
    }

    /// `SubWidthC` and `SubHeightC` from H.264 Table 6-1. Both are 1 for separately coded planes and
    /// for monochrome, where the standard leaves them undefined and nothing uses them.
    @inlinable public var chromaSubsampling: (subWidthC: Int, subHeightC: Int) {
        if separateColourPlaneFlag { return (1, 1) }
        switch chromaFormatIDC {
        case 1: return (2, 2)
        case 2: return (2, 1)
        case 3: return (1, 1)
        default: return (1, 1)
        }
    }

    /// `PicWidthInSamplesL` — the allocation width, in luma samples.
    @inlinable public var codedWidth: Int { picWidthInMbs * 16 }

    /// `FrameHeightInSamplesL` — the allocation height, in luma samples.
    ///
    /// An interlaced stream stores a field pair per map unit, so the map unit count doubles:
    /// 34 map units × 2 × 16 is the same 1088 rows as 68 progressive map units.
    @inlinable public var codedHeight: Int {
        (frameMbsOnlyFlag ? 1 : 2) * picHeightInMapUnits * 16
    }

    /// `CropUnitX`: 1 for `chromaArrayType == 0`, else `SubWidthC`.
    @inlinable public var cropUnitX: Int {
        chromaArrayType == 0 ? 1 : chromaSubsampling.subWidthC
    }

    /// `CropUnitY`: `(2 − frame_mbs_only_flag)` for `chromaArrayType == 0`, else that times
    /// `SubHeightC`.
    ///
    /// This is the value that decides whether a 4:2:0 interlaced stream crops 2 rows per offset or
    /// 4. Getting it wrong yields a plausible 1084 instead of 1080.
    @inlinable public var cropUnitY: Int {
        let fieldFactor = frameMbsOnlyFlag ? 1 : 2
        return chromaArrayType == 0 ? fieldFactor : chromaSubsampling.subHeightC * fieldFactor
    }

    /// Displayed width in luma samples, before SAR correction. **This is what the UI, the renderer
    /// and the recorder report.**
    @inlinable public var displayWidth: Int {
        codedWidth - cropUnitX * (frameCropping.left + frameCropping.right)
    }

    /// Displayed height in luma samples — 1080 for the 1088-coded Hikvision 1080p stream.
    @inlinable public var displayHeight: Int {
        codedHeight - cropUnitY * (frameCropping.top + frameCropping.bottom)
    }

    /// Frames per second from the VUI, or `nil` when there is no usable timing info.
    ///
    /// `fps = time_scale / (2 · num_units_in_tick)`. **The factor of two is H.264-specific** —
    /// `time_scale` counts field ticks — and H.265 does *not* have it. Values outside 1…240 fps are
    /// rejected as nonsense, which sends the caller down the fallback chain (measured RTP rate,
    /// then ISAPI, then 25.0).
    ///
    /// **Metadata only.** RTP timestamps drive the presentation clock; nothing in Vigil assumes a
    /// frame rate to advance a PTS.
    @inlinable public var frameRate: Double? {
        guard let units = numUnitsInTick, let scale = timeScale, units > 0 else { return nil }
        let fps = Double(scale) / (2.0 * Double(units))
        guard fps >= 1.0, fps <= 240.0 else { return nil }
        return fps
    }

    /// True when the stream is not interlaced. Every Hikvision live profile is progressive.
    @inlinable public var isProgressive: Bool { frameMbsOnlyFlag }

    // MARK: - Naming

    /// Human profile name for the inspector, never for control flow.
    ///
    /// The Baseline distinction is the one that bites: "Constrained Baseline" requires
    /// `constraint_set1_flag` (mask `0x40`), so a stream whose only constraint bit is
    /// `constraint_set0_flag` (`0x80`) is plain **Baseline**.
    public var profileName: String {
        H264SPS.profileName(profileIDC: profileIDC, constraintFlags: constraintFlags)
    }

    /// `profileName` for a raw `(profile_idc, constraint byte)` pair, so a record parser that never
    /// saw an SPS can name a profile too.
    public static func profileName(profileIDC: UInt8, constraintFlags: UInt8) -> String {
        let constrained = constraintFlags & 0b0100_0000 != 0        // constraint_set1_flag
        switch profileIDC {
        case 66: return constrained ? "Constrained Baseline" : "Baseline"
        case 77: return "Main"
        case 88: return "Extended"
        case 100: return "High"
        case 110: return "High 10"
        case 122: return "High 4:2:2"
        case 244: return "High 4:4:4 Predictive"
        case 44: return "CAVLC 4:4:4 Intra"
        default: return "Unknown (\(profileIDC))"
        }
    }

    /// Human level name: "4.0", "5.1", or "1b".
    public var levelName: String {
        H264SPS.levelName(levelIDC: levelIDC, constraintFlags: constraintFlags)
    }

    /// `levelName` for a raw `(level_idc, constraint byte)` pair.
    ///
    /// Level 1b is the special case: it is `level_idc == 9` for the profiles that carry the chroma
    /// extension, and `level_idc == 11` with `constraint_set3_flag` (mask `0x10`) for
    /// Baseline/Main/Extended.
    public static func levelName(levelIDC: UInt8, constraintFlags: UInt8) -> String {
        if levelIDC == 9 { return "1b" }
        if levelIDC == 11, constraintFlags & 0b0001_0000 != 0 { return "1b" }
        let whole = levelIDC / 10
        let fraction = levelIDC % 10
        guard whole >= 1 else { return "Unknown (\(levelIDC))" }
        return "\(whole).\(fraction)"
    }
}
