//
//  SyntheticEncoder.swift
//  VigilTestKit
//
//  Produces a stream of access units with real slice headers — `first_mb_in_slice` for H.264 and
//  `first_slice_segment_in_pic_flag` for H.265 are genuinely coded, because the depacketizer's
//  access-unit boundary predicate reads exactly those bits — followed by seeded filler sized to the
//  profile's bitrate. Nothing here needs to decode to an image; everything here must parse.
//  Implements docs/ARCHITECTURE.md §10.2 (`SyntheticEncoder`, the `syntactic` realism tier).
//

import VigilProtocols

// MARK: - Access unit

/// One synthetic access unit, as a list of complete NAL units in decode order.
public struct SyntheticAccessUnit: Sendable {

    /// Zero-based index in the generated stream, counting from the first AU the camera would send.
    public var index: Int

    /// `true` when the AU begins with an IDR (H.264) or IRAP (H.265) slice.
    public var isKeyframe: Bool

    /// NAL units including headers, without start codes and with emulation prevention applied.
    /// Parameter-set NALs, when carried in band, are at the front.
    public var nals: [[UInt8]]

    /// RTP timestamp for this AU at 90 kHz, already wrapped into 32 bits.
    public var rtpTimestamp: UInt32

    /// Parameter sets in force for this AU. Set on every AU so ground truth can follow a
    /// mid-stream resolution change without re-deriving it.
    public var parameterSets: ParameterSets

    /// The coded slice NAL type codes in this AU, excluding parameter sets.
    public var sliceTypeCodes: [UInt8] {
        nals.compactMap { nal in
            guard let first = nal.first else { return nil }
            return isParameterSet(nal) ? nil : typeCode(first, second: nal.count > 1 ? nal[1] : 0)
        }
    }

    /// All NAL type codes in this AU, in order.
    public var nalTypeCodes: [UInt8] {
        nals.compactMap { nal in
            guard let first = nal.first else { return nil }
            return typeCode(first, second: nal.count > 1 ? nal[1] : 0)
        }
    }

    private var isHEVC: Bool { parameterSets.codec == .h265 }

    private func typeCode(_ first: UInt8, second: UInt8) -> UInt8 {
        isHEVC ? (first >> 1) & 0x3F : first & 0x1F
    }

    private func isParameterSet(_ nal: [UInt8]) -> Bool {
        guard let first = nal.first else { return false }
        let code = typeCode(first, second: nal.count > 1 ? nal[1] : 0)
        return isHEVC ? (code >= 32 && code <= 34) : (code == 7 || code == 8)
    }
}

// MARK: - Encoder

/// Generates access units for a profile, on demand, deterministically.
///
/// The encoder owns no clock. `nextAccessUnit()` produces the next AU in decode order and stamps it
/// with the RTP timestamp implied by the profile's frame rate; the caller decides when it goes out.
public struct SyntheticEncoder: Sendable {

    private let profile: SyntheticCameraProfile
    private var builder: SyntheticParameterSetBuilder
    private var random: SplitMix64RandomSource

    /// Index of the next AU to produce.
    public private(set) var nextIndex: Int = 0

    /// The RTP timestamp of the next AU, wrapping at 2³².
    private var timestamp: UInt32

    /// H.264 `frame_num` / H.265 `slice_pic_order_cnt_lsb`, both 8 bits here.
    private var frameNumber: UInt8 = 0

    /// Access units to emit with no IRAP at the start of the stream, for `startMidGOP`.
    private let irapSuppressedCount: Int

    /// Parameter sets currently in force.
    public private(set) var parameterSets: ParameterSets

    /// Geometry currently in force.
    public private(set) var geometry: SyntheticGeometry

    /// Creates an encoder. `startTimestamp` is the RTP timestamp of the first access unit.
    public init(profile: SyntheticCameraProfile, startTimestamp: UInt32) {
        self.profile = profile
        builder = SyntheticParameterSetBuilder(width: profile.width, height: profile.height,
                                               frameRate: profile.frameRate,
                                               codec: profile.videoCodec)
        // A distinct stream from the packet-shaping generator, so toggling a transport quirk does
        // not change the payload bytes and vice versa.
        random = SplitMix64RandomSource(seed: profile.seed &* 0x9E37_79B9_7F4A_7C15 &+ 1)
        timestamp = startTimestamp
        parameterSets = builder.parameterSets()
        geometry = builder.geometry
        if let seconds = profile.quirks.startMidGOPSeconds {
            irapSuppressedCount = Int((seconds / profile.framePeriodSeconds).rounded(.up))
        } else {
            irapSuppressedCount = 0
        }
    }

    /// Produces the next access unit and advances the encoder.
    ///
    /// An AU is a keyframe when its index is a multiple of `gopLength`, except while
    /// ``Quirk/startMidGOP(seconds:)`` is suppressing IRAPs, and always at a mid-stream resolution
    /// change. Parameter sets precede every keyframe in band unless
    /// ``Quirk/parameterSetsOnlyInSDP`` is set.
    public mutating func nextAccessUnit() -> SyntheticAccessUnit {
        let index = nextIndex
        var resolutionChanged = false
        if let change = profile.quirks.resolutionChange, index == change.atFrame {
            builder = SyntheticParameterSetBuilder(width: change.width, height: change.height,
                                                   frameRate: profile.frameRate,
                                                   codec: profile.videoCodec)
            parameterSets = builder.parameterSets()
            geometry = builder.geometry
            resolutionChanged = true
        }

        let periodic = index % profile.gopLength == 0
        let isKeyframe = resolutionChanged || (periodic && index >= irapSuppressedCount)

        var nals: [[UInt8]] = []
        if isKeyframe && !profile.quirks.contains(.parameterSetsOnlyInSDP) {
            nals.append(contentsOf: builder.parameterSetNALs())
        }
        nals.append(sliceNAL(isKeyframe: isKeyframe))

        let unit = SyntheticAccessUnit(index: index, isKeyframe: isKeyframe, nals: nals,
                                       rtpTimestamp: timestamp, parameterSets: parameterSets)
        nextIndex += 1
        timestamp = timestamp &+ profile.ticksPerFrame
        frameNumber = frameNumber &+ 1
        return unit
    }

    // MARK: Slice construction

    /// Target coded size for one slice, before NAL header and emulation prevention.
    private mutating func sliceByteCount(isKeyframe: Bool) -> Int {
        let average = Double(profile.averageFrameBytes)
        let base = isKeyframe ? average * 4.0 : average * 0.65
        // ±20 % variation, drawn from the seeded generator so sizes are stable across runs.
        let jitter = random.jitterFactor(0.2)
        return Swift.max(48, Int(base * jitter))
    }

    private mutating func sliceNAL(isKeyframe: Bool) -> [UInt8] {
        switch profile.videoCodec {
        case .h264: h264Slice(isKeyframe: isKeyframe)
        case .h265: h265Slice(isKeyframe: isKeyframe)
        case .mjpeg: fillerBytes(count: sliceByteCount(isKeyframe: isKeyframe))
        }
    }

    /// `slice_header()` per ITU-T H.264 §7.3.3, followed by `cabac_alignment_one_bit` and filler.
    private mutating func h264Slice(isKeyframe: Bool) -> [UInt8] {
        var writer = SyntheticBitWriter()
        writer.writeUE(0)                                   // first_mb_in_slice — the AU boundary bit
        writer.writeUE(isKeyframe ? 7 : 5)                  // slice_type: I-all / P-all
        writer.writeUE(0)                                   // pic_parameter_set_id
        writer.write(UInt64(frameNumber), bits: 8)          // frame_num
        if isKeyframe {
            writer.writeUE(0)                               // idr_pic_id
        }
        writer.write(UInt64(frameNumber), bits: 8)          // pic_order_cnt_lsb
        if !isKeyframe {
            writer.writeFlag(false)                         // num_ref_idx_active_override_flag
            writer.writeFlag(false)                         // ref_pic_list_modification_flag_l0
        }
        // nal_ref_idc is non-zero for both slice kinds here, so dec_ref_pic_marking() is present.
        if isKeyframe {
            writer.writeFlag(false)                         // no_output_of_prior_pics_flag
            writer.writeFlag(false)                         // long_term_reference_flag
        } else {
            writer.writeFlag(false)                         // adaptive_ref_pic_marking_mode_flag
        }
        if !isKeyframe {
            writer.writeUE(0)                               // cabac_init_idc (CABAC, non-I slice)
        }
        writer.writeSE(0)                                   // slice_qp_delta
        // slice_data() opens with cabac_alignment_one_bit, which pads with 1s, not with zeros.
        while !writer.isByteAligned { writer.writeBit(true) }
        let headerBytes = writer.rbsp
        let target = sliceByteCount(isKeyframe: isKeyframe)
        let filler = fillerBytes(count: Swift.max(16, target - headerBytes.count))
        // nal_ref_idc 3 + type 5 (IDR), or nal_ref_idc 2 + type 1 (non-IDR reference slice).
        let header: UInt8 = isKeyframe ? 0x65 : 0x41
        return [header] + SyntheticRBSP.escape(headerBytes + filler)
    }

    /// `slice_segment_header()` per ITU-T H.265 §7.3.6.1, followed by byte alignment and filler.
    private mutating func h265Slice(isKeyframe: Bool) -> [UInt8] {
        // 19 = IDR_W_RADL, 1 = TRAIL_R.
        let nalType: UInt8 = isKeyframe ? 19 : 1
        var writer = SyntheticBitWriter()
        writer.writeFlag(true)                              // first_slice_segment_in_pic_flag
        if nalType >= 16 && nalType <= 23 {
            writer.writeFlag(false)                         // no_output_of_prior_pics_flag
        }
        writer.writeUE(0)                                   // slice_pic_parameter_set_id
        writer.writeUE(isKeyframe ? 2 : 1)                  // slice_type: I / P
        if !isKeyframe {
            writer.write(UInt64(frameNumber), bits: 8)      // slice_pic_order_cnt_lsb
            writer.writeFlag(false)                         // short_term_ref_pic_set_sps_flag
            // st_ref_pic_set(0): one negative reference, none positive.
            writer.writeUE(1)                               // num_negative_pics
            writer.writeUE(0)                               // num_positive_pics
            writer.writeUE(0)                               // delta_poc_s0_minus1[0]
            writer.writeFlag(true)                          // used_by_curr_pic_s0_flag[0]
            writer.writeFlag(false)                         // slice_temporal_mvp_enabled_flag
        }
        // sample_adaptive_offset_enabled_flag is 1 in the SPS this fixture writes.
        writer.writeFlag(false)                             // slice_sao_luma_flag
        writer.writeFlag(false)                             // slice_sao_chroma_flag
        if !isKeyframe {
            writer.writeFlag(false)                         // num_ref_idx_active_override_flag
            writer.writeUE(0)                               // five_minus_max_num_merge_cand
        }
        writer.writeSE(0)                                   // slice_qp_delta
        writer.writeFlag(true)                              // slice_loop_filter_across_slices_enabled
        writer.alignToByte()                                // byte_alignment()
        let headerBytes = writer.rbsp
        let target = sliceByteCount(isKeyframe: isKeyframe)
        let filler = fillerBytes(count: Swift.max(16, target - headerBytes.count))
        return builder.hevcHeader(type: nalType) + SyntheticRBSP.escape(headerBytes + filler)
    }

    /// Seeded filler standing in for residual data.
    ///
    /// The final byte is forced non-zero: an RBSP ending in `0x00` is ambiguous with
    /// `trailing_zero_8bits`, and real encoders do not emit one.
    private mutating func fillerBytes(count: Int) -> [UInt8] {
        guard count > 0 else { return [] }
        var bytes = random.randomBytes(count)
        if bytes[bytes.count - 1] == 0 { bytes[bytes.count - 1] = 0x80 }
        return bytes
    }
}
