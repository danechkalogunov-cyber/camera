//
//  SyntheticParameterSets.swift
//  VigilTestKit
//
//  Builds genuine H.264 SPS/PPS and H.265 VPS/SPS/PPS NAL units at a chosen resolution and frame
//  rate, bit by bit, so `VigilBitstream` parses them and derives exactly the geometry the fixture
//  claims in its ground truth. Syntax follows ITU-T H.264 §7.3.2 and ITU-T H.265 §7.3.2.
//  Implements docs/ARCHITECTURE.md §10.2 (`SyntheticSPSBuilder`).
//

import Foundation
import VigilProtocols

// MARK: - Geometry

/// Coded size, cropping offsets and the display size they imply.
///
/// H.264 codes whole 16×16 macroblocks and H.265 whole 8×8 coding blocks, so a 1080-line picture is
/// coded as 1088 lines and cropped. Getting this right in the fixture is the point: the pipeline
/// tests assert the parsed display size, and a fixture that quietly rounded would hide a real bug.
public struct SyntheticGeometry: Sendable, Hashable {

    public let displayWidth: Int
    public let displayHeight: Int
    public let codedWidth: Int
    public let codedHeight: Int

    /// Crop offsets in *chroma* units, which is how both specs code them for 4:2:0.
    public let cropRightUnits: Int
    public let cropBottomUnits: Int

    /// Rounds `width`/`height` up to a multiple of `alignment` and derives the crop offsets.
    /// A non-positive dimension is clamped to `alignment`, so a malformed profile still produces a
    /// parseable parameter set rather than an unrepresentable one.
    public init(width: Int, height: Int, alignment: Int) {
        let unit = Swift.max(alignment, 1)
        let safeWidth = Swift.max(width, unit)
        let safeHeight = Swift.max(height, unit)
        displayWidth = safeWidth
        displayHeight = safeHeight
        codedWidth = ((safeWidth + unit - 1) / unit) * unit
        codedHeight = ((safeHeight + unit - 1) / unit) * unit
        // SubWidthC == SubHeightC == 2 for the 4:2:0 chroma format both codecs use here.
        cropRightUnits = (codedWidth - safeWidth) / 2
        cropBottomUnits = (codedHeight - safeHeight) / 2
    }

    /// `true` when any cropping is in force.
    public var isCropped: Bool { cropRightUnits > 0 || cropBottomUnits > 0 }
}

// MARK: - Builder

/// Assembles the parameter-set NAL units for one profile.
public struct SyntheticParameterSetBuilder: Sendable {

    /// Display geometry to encode.
    public let width: Int
    public let height: Int

    /// Frames per second, encoded into the VUI timing info as `time_scale / (2 · num_units_in_tick)`
    /// for H.264 and `vui_time_scale / vui_num_units_in_tick` for H.265.
    public let frameRate: Double

    public let codec: VideoCodec

    /// `num_units_in_tick`, fixed at 1000 so any frame rate expressible to three decimals is exact.
    private static let unitsInTick: UInt32 = 1_000

    public init(width: Int, height: Int, frameRate: Double, codec: VideoCodec) {
        self.width = Swift.max(width, 16)
        self.height = Swift.max(height, 16)
        self.frameRate = frameRate > 0 ? frameRate : 25
        self.codec = codec
    }

    /// Geometry for this codec: 16-sample macroblocks for H.264, 8-sample coding blocks for H.265.
    public var geometry: SyntheticGeometry {
        SyntheticGeometry(width: width, height: height, alignment: codec == .h264 ? 16 : 8)
    }

    /// The parameter-set NAL units for this profile, in the order a camera puts them in band:
    /// VPS (H.265 only), then SPS, then PPS. Each element is a complete NAL including its header
    /// and with emulation prevention already applied.
    public func parameterSetNALs() -> [[UInt8]] {
        switch codec {
        case .h264: [h264SPS(), h264PPS()]
        case .h265: [h265VPS(), h265SPS(), h265PPS()]
        case .mjpeg: []
        }
    }

    /// The same sets as the shared `ParameterSets` value the rest of the pipeline speaks.
    public func parameterSets() -> ParameterSets {
        switch codec {
        case .h264:
            ParameterSets(codec: .h264, sps: [Data(h264SPS())], pps: [Data(h264PPS())])
        case .h265:
            ParameterSets(codec: .h265, vps: [Data(h265VPS())], sps: [Data(h265SPS())],
                          pps: [Data(h265PPS())])
        case .mjpeg:
            ParameterSets(codec: .mjpeg)
        }
    }

    // MARK: H.264

    /// `seq_parameter_set_rbsp()`, ITU-T H.264 §7.3.2.1, Main profile (`profile_idc` 77) so the
    /// high-profile chroma block is legitimately absent.
    public func h264SPS() -> [UInt8] {
        let box = geometry
        var writer = SyntheticBitWriter()
        writer.write(77, bits: 8)                       // profile_idc: Main
        writer.write(0x40, bits: 8)                     // constraint_set1_flag, reserved zero
        writer.write(31, bits: 8)                       // level_idc: 3.1
        writer.writeUE(0)                               // seq_parameter_set_id
        writer.writeUE(4)                               // log2_max_frame_num_minus4 → 8-bit frame_num
        writer.writeUE(0)                               // pic_order_cnt_type
        writer.writeUE(4)                               // log2_max_pic_order_cnt_lsb_minus4 → 8 bits
        writer.writeUE(1)                               // max_num_ref_frames
        writer.writeFlag(false)                         // gaps_in_frame_num_value_allowed_flag
        writer.writeUE(UInt32(box.codedWidth / 16 - 1)) // pic_width_in_mbs_minus1
        writer.writeUE(UInt32(box.codedHeight / 16 - 1))// pic_height_in_map_units_minus1
        writer.writeFlag(true)                          // frame_mbs_only_flag
        writer.writeFlag(true)                          // direct_8x8_inference_flag
        writer.writeFlag(box.isCropped)                 // frame_cropping_flag
        if box.isCropped {
            writer.writeUE(0)                                       // frame_crop_left_offset
            writer.writeUE(UInt32(box.cropRightUnits))              // frame_crop_right_offset
            writer.writeUE(0)                                       // frame_crop_top_offset
            writer.writeUE(UInt32(box.cropBottomUnits))             // frame_crop_bottom_offset
        }
        writer.writeFlag(true)                          // vui_parameters_present_flag
        appendH264VUI(&writer)
        writer.writeTrailingBits()
        // nal_ref_idc 3, nal_unit_type 7.
        return nal(header: [0x67], rbsp: writer.rbsp)
    }

    /// `vui_parameters()`, ITU-T H.264 Annex E.1.1, with square pixels and fixed frame timing.
    private func appendH264VUI(_ writer: inout SyntheticBitWriter) {
        writer.writeFlag(true)                          // aspect_ratio_info_present_flag
        writer.write(1, bits: 8)                        // aspect_ratio_idc: 1:1 square
        writer.writeFlag(false)                         // overscan_info_present_flag
        writer.writeFlag(false)                         // video_signal_type_present_flag
        writer.writeFlag(false)                         // chroma_loc_info_present_flag
        writer.writeFlag(true)                          // timing_info_present_flag
        writer.write(UInt64(Self.unitsInTick), bits: 32)                    // num_units_in_tick
        writer.write(UInt64(h264TimeScale), bits: 32)                       // time_scale
        writer.writeFlag(true)                          // fixed_frame_rate_flag
        writer.writeFlag(false)                         // nal_hrd_parameters_present_flag
        writer.writeFlag(false)                         // vcl_hrd_parameters_present_flag
        writer.writeFlag(false)                         // pic_struct_present_flag
        writer.writeFlag(false)                         // bitstream_restriction_flag
    }

    /// `time_scale` such that `frameRate == time_scale / (2 · num_units_in_tick)`.
    private var h264TimeScale: UInt32 {
        UInt32(Swift.max(2.0, (frameRate * 2.0 * Double(Self.unitsInTick)).rounded()))
    }

    /// `pic_parameter_set_rbsp()`, ITU-T H.264 §7.3.2.2, CABAC, one slice group.
    public func h264PPS() -> [UInt8] {
        var writer = SyntheticBitWriter()
        writer.writeUE(0)                               // pic_parameter_set_id
        writer.writeUE(0)                               // seq_parameter_set_id
        writer.writeFlag(true)                          // entropy_coding_mode_flag: CABAC
        writer.writeFlag(false)                         // bottom_field_pic_order_in_frame_present
        writer.writeUE(0)                               // num_slice_groups_minus1
        writer.writeUE(0)                               // num_ref_idx_l0_default_active_minus1
        writer.writeUE(0)                               // num_ref_idx_l1_default_active_minus1
        writer.writeFlag(false)                         // weighted_pred_flag
        writer.write(0, bits: 2)                        // weighted_bipred_idc
        writer.writeSE(0)                               // pic_init_qp_minus26
        writer.writeSE(0)                               // pic_init_qs_minus26
        writer.writeSE(0)                               // chroma_qp_index_offset
        writer.writeFlag(false)                         // deblocking_filter_control_present_flag
        writer.writeFlag(false)                         // constrained_intra_pred_flag
        writer.writeFlag(false)                         // redundant_pic_cnt_present_flag
        writer.writeTrailingBits()
        // nal_ref_idc 3, nal_unit_type 8.
        return nal(header: [0x68], rbsp: writer.rbsp)
    }

    // MARK: H.265

    /// `video_parameter_set_rbsp()`, ITU-T H.265 §7.3.2.1, one layer, one temporal sub-layer.
    public func h265VPS() -> [UInt8] {
        var writer = SyntheticBitWriter()
        writer.write(0, bits: 4)                        // vps_video_parameter_set_id
        writer.writeFlag(true)                          // vps_base_layer_internal_flag
        writer.writeFlag(true)                          // vps_base_layer_available_flag
        writer.write(0, bits: 6)                        // vps_max_layers_minus1
        writer.write(0, bits: 3)                        // vps_max_sub_layers_minus1
        writer.writeFlag(true)                          // vps_temporal_id_nesting_flag
        writer.write(0xFFFF, bits: 16)                  // vps_reserved_0xffff_16bits
        appendProfileTierLevel(&writer)
        writer.writeFlag(true)                          // vps_sub_layer_ordering_info_present_flag
        writer.writeUE(1)                               // vps_max_dec_pic_buffering_minus1[0]
        writer.writeUE(0)                               // vps_max_num_reorder_pics[0]
        writer.writeUE(0)                               // vps_max_latency_increase_plus1[0]
        writer.write(0, bits: 6)                        // vps_max_layer_id
        writer.writeUE(0)                               // vps_num_layer_sets_minus1
        writer.writeFlag(false)                         // vps_timing_info_present_flag
        writer.writeFlag(false)                         // vps_extension_flag
        writer.writeTrailingBits()
        return nal(header: hevcHeader(type: 32), rbsp: writer.rbsp)
    }

    /// `profile_tier_level(1, 0)`, ITU-T H.265 §7.3.3: Main profile, tier 0, level 4.0.
    private func appendProfileTierLevel(_ writer: inout SyntheticBitWriter) {
        writer.write(0, bits: 2)                        // general_profile_space
        writer.writeFlag(false)                         // general_tier_flag
        writer.write(1, bits: 5)                        // general_profile_idc: Main
        // general_profile_compatibility_flag[32]: only bit 1 (Main) is set.
        for index in 0..<32 { writer.writeFlag(index == 1) }
        writer.writeFlag(true)                          // general_progressive_source_flag
        writer.writeFlag(false)                         // general_interlaced_source_flag
        writer.writeFlag(false)                         // general_non_packed_constraint_flag
        writer.writeFlag(true)                          // general_frame_only_constraint_flag
        writer.write(0, bits: 43)                       // general_reserved_zero_43bits
        writer.writeFlag(false)                         // general_inbld_flag / reserved zero bit
        writer.write(120, bits: 8)                      // general_level_idc: level 4.0
    }

    /// `seq_parameter_set_rbsp()`, ITU-T H.265 §7.3.2.2.
    public func h265SPS() -> [UInt8] {
        let box = geometry
        var writer = SyntheticBitWriter()
        writer.write(0, bits: 4)                        // sps_video_parameter_set_id
        writer.write(0, bits: 3)                        // sps_max_sub_layers_minus1
        writer.writeFlag(true)                          // sps_temporal_id_nesting_flag
        appendProfileTierLevel(&writer)
        writer.writeUE(0)                               // sps_seq_parameter_set_id
        writer.writeUE(1)                               // chroma_format_idc: 4:2:0
        writer.writeUE(UInt32(box.codedWidth))          // pic_width_in_luma_samples
        writer.writeUE(UInt32(box.codedHeight))         // pic_height_in_luma_samples
        writer.writeFlag(box.isCropped)                 // conformance_window_flag
        if box.isCropped {
            writer.writeUE(0)                                       // conf_win_left_offset
            writer.writeUE(UInt32(box.cropRightUnits))              // conf_win_right_offset
            writer.writeUE(0)                                       // conf_win_top_offset
            writer.writeUE(UInt32(box.cropBottomUnits))             // conf_win_bottom_offset
        }
        writer.writeUE(0)                               // bit_depth_luma_minus8
        writer.writeUE(0)                               // bit_depth_chroma_minus8
        writer.writeUE(4)                               // log2_max_pic_order_cnt_lsb_minus4 → 8 bits
        writer.writeFlag(true)                          // sps_sub_layer_ordering_info_present_flag
        writer.writeUE(1)                               // sps_max_dec_pic_buffering_minus1[0]
        writer.writeUE(0)                               // sps_max_num_reorder_pics[0]
        writer.writeUE(0)                               // sps_max_latency_increase_plus1[0]
        writer.writeUE(0)                               // log2_min_luma_coding_block_size_minus3 → 8
        writer.writeUE(3)                               // log2_diff_max_min_luma_coding_block_size
        writer.writeUE(0)                               // log2_min_luma_transform_block_size_minus2
        writer.writeUE(3)                               // log2_diff_max_min_luma_transform_block_size
        writer.writeUE(0)                               // max_transform_hierarchy_depth_inter
        writer.writeUE(0)                               // max_transform_hierarchy_depth_intra
        writer.writeFlag(false)                         // scaling_list_enabled_flag
        writer.writeFlag(true)                          // amp_enabled_flag
        writer.writeFlag(true)                          // sample_adaptive_offset_enabled_flag
        writer.writeFlag(false)                         // pcm_enabled_flag
        writer.writeUE(0)                               // num_short_term_ref_pic_sets
        writer.writeFlag(false)                         // long_term_ref_pics_present_flag
        writer.writeFlag(true)                          // sps_temporal_mvp_enabled_flag
        writer.writeFlag(true)                          // strong_intra_smoothing_enabled_flag
        writer.writeFlag(true)                          // vui_parameters_present_flag
        appendH265VUI(&writer)
        writer.writeFlag(false)                         // sps_extension_present_flag
        writer.writeTrailingBits()
        return nal(header: hevcHeader(type: 33), rbsp: writer.rbsp)
    }

    /// `vui_parameters()`, ITU-T H.265 Annex E.2.1, square pixels and explicit timing.
    private func appendH265VUI(_ writer: inout SyntheticBitWriter) {
        writer.writeFlag(true)                          // aspect_ratio_info_present_flag
        writer.write(1, bits: 8)                        // aspect_ratio_idc: 1:1 square
        writer.writeFlag(false)                         // overscan_info_present_flag
        writer.writeFlag(false)                         // video_signal_type_present_flag
        writer.writeFlag(false)                         // chroma_loc_info_present_flag
        writer.writeFlag(false)                         // neutral_chroma_indication_flag
        writer.writeFlag(false)                         // field_seq_flag
        writer.writeFlag(false)                         // frame_field_info_present_flag
        writer.writeFlag(false)                         // default_display_window_flag
        writer.writeFlag(true)                          // vui_timing_info_present_flag
        writer.write(UInt64(Self.unitsInTick), bits: 32)                    // vui_num_units_in_tick
        writer.write(UInt64(h265TimeScale), bits: 32)                       // vui_time_scale
        writer.writeFlag(false)                         // vui_poc_proportional_to_timing_flag
        writer.writeFlag(false)                         // vui_hrd_parameters_present_flag
        writer.writeFlag(false)                         // bitstream_restriction_flag
    }

    /// `vui_time_scale` such that `frameRate == vui_time_scale / vui_num_units_in_tick`.
    private var h265TimeScale: UInt32 {
        UInt32(Swift.max(1.0, (frameRate * Double(Self.unitsInTick)).rounded()))
    }

    /// `pic_parameter_set_rbsp()`, ITU-T H.265 §7.3.2.3.
    public func h265PPS() -> [UInt8] {
        var writer = SyntheticBitWriter()
        writer.writeUE(0)                               // pps_pic_parameter_set_id
        writer.writeUE(0)                               // pps_seq_parameter_set_id
        writer.writeFlag(false)                         // dependent_slice_segments_enabled_flag
        writer.writeFlag(false)                         // output_flag_present_flag
        writer.write(0, bits: 3)                        // num_extra_slice_header_bits
        writer.writeFlag(false)                         // sign_data_hiding_enabled_flag
        writer.writeFlag(false)                         // cabac_init_present_flag
        writer.writeUE(0)                               // num_ref_idx_l0_default_active_minus1
        writer.writeUE(0)                               // num_ref_idx_l1_default_active_minus1
        writer.writeSE(0)                               // init_qp_minus26
        writer.writeFlag(false)                         // constrained_intra_pred_flag
        writer.writeFlag(false)                         // transform_skip_enabled_flag
        writer.writeFlag(false)                         // cu_qp_delta_enabled_flag
        writer.writeSE(0)                               // pps_cb_qp_offset
        writer.writeSE(0)                               // pps_cr_qp_offset
        writer.writeFlag(false)                         // pps_slice_chroma_qp_offsets_present_flag
        writer.writeFlag(false)                         // weighted_pred_flag
        writer.writeFlag(false)                         // weighted_bipred_flag
        writer.writeFlag(false)                         // transquant_bypass_enabled_flag
        writer.writeFlag(false)                         // tiles_enabled_flag
        writer.writeFlag(false)                         // entropy_coding_sync_enabled_flag
        writer.writeFlag(true)                          // pps_loop_filter_across_slices_enabled_flag
        writer.writeFlag(false)                         // deblocking_filter_control_present_flag
        writer.writeFlag(false)                         // pps_scaling_list_data_present_flag
        writer.writeFlag(false)                         // lists_modification_present_flag
        writer.writeUE(0)                               // log2_parallel_merge_level_minus2
        writer.writeFlag(false)                         // slice_segment_header_extension_present
        writer.writeFlag(false)                         // pps_extension_present_flag
        writer.writeTrailingBits()
        return nal(header: hevcHeader(type: 34), rbsp: writer.rbsp)
    }

    // MARK: Helpers

    /// The two-byte HEVC NAL header for `type`, layer 0, temporal id 0 (`nuh_temporal_id_plus1` 1).
    public func hevcHeader(type: UInt8) -> [UInt8] {
        [(type & 0x3F) << 1, 0x01]
    }

    /// Concatenates a NAL header with its emulation-prevention-escaped RBSP payload.
    private func nal(header: [UInt8], rbsp: [UInt8]) -> [UInt8] {
        header + SyntheticRBSP.escape(rbsp)
    }
}
