# ASSIGNMENT: bitstream

AGENT_LABEL for your log lines is: spec:bitstream
Write the file: /home/user/camera/docs/spec-bitstream.md

Author the video bitstream specification (module VigilBitstream).
Cover:
- A rigorous **RBSP bit reader**: emulation-prevention byte (0x000003) removal, ue(v) and se(v)
  Exp-Golomb, u(n), byte alignment, bounds checking. Give the exact Swift implementation.
- **H.264 SPS parsing** (ITU-T H.264 section 7.3.2.1) end to end: profile_idc, constraint flags,
  level_idc, seq_parameter_set_id, chroma_format_idc with separate_colour_plane_flag, bit depths,
  scaling lists (which must be SKIPPED correctly - give the loop), log2_max_frame_num_minus4,
  pic_order_cnt_type including type 1 cycle arrays, num_ref_frames, pic_width_in_mbs_minus1,
  pic_height_in_map_units_minus1, frame_mbs_only_flag, mb_adaptive_frame_field_flag, frame
  cropping offsets, and VUI (aspect-ratio idc table, timing_info num_units_in_tick and time_scale
  giving fps, bitstream_restriction) - then derive the **exact display width, height, SAR and fps**.
- **H.264 PPS**: the minimal parse we need, and an explicit statement of what we skip and why.
- **H.265 parsing** (ITU-T H.265 section 7.3.2): the 2-byte NAL header, VPS (enough to store and
  re-emit), SPS with the full profile_tier_level parse including sub-layer loops,
  chroma_format_idc, pic_width_in_luma_samples and pic_height_in_luma_samples, conformance-window
  offsets multiplied by SubWidthC/SubHeightC, log2 CTB size fields, and the short-term and
  long-term reference picture sets which must be skipped correctly (give the st_ref_pic_set loop),
  plus VUI timing giving fps.
- **Format-record construction**: the exact byte layout of avcC (AVCDecoderConfigurationRecord,
  including the 3-byte profile/compatibility/level, lengthSizeMinusOne = 3, numOfSPS and numOfPPS,
  and the trailing extension for profiles 100/110/122/144) and of hvcC
  (HEVCDecoderConfigurationRecord: configurationVersion, general_profile_space/tier/idc,
  32-bit compatibility flags, 48-bit constraint indicator flags, level_idc,
  min_spatial_segmentation_idc, parallelismType, chromaFormat, bit depths, avgFrameRate,
  constantFrameRate + numTemporalLayers + temporalIdNested + lengthSizeMinusOne, numOfArrays and
  the VPS/SPS/PPS/SEI arrays). Give hex-annotated worked examples of both.
- Note that on macOS we can build a CMVideoFormatDescription either from these records or via
  CMVideoFormatDescriptionCreateFromH264ParameterSets and
  CMVideoFormatDescriptionCreateFromHEVCParameterSets. Specify which we use and why (prefer the
  ParameterSets APIs at runtime; keep the record builders for MP4 muxing/recording and for tests).
- Annex-B to 4-byte-length-prefixed conversion and back, in place where possible; a fast
  start-code scanner; NAL type tables for both codecs; the SEI messages we care about (recovery
  point, picture timing) and how to detect a stream that starts mid-GOP so we can drop frames
  until the first IRAP.
- The complete public Swift API, plus a list of **unit-test vectors**: real base64 SPS strings from
  Hikvision cameras with the expected parsed values, that implementers must add as tests.

Create parent directories if needed. Be exhaustive and concrete.
