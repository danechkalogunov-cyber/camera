//
//  H264NALType.swift
//  VigilBitstream
//
//  ITU-T H.264 Table 7-1 `nal_unit_type`, with the class predicates the depacketizer and the
//  access-unit gate key on. See docs/spec-bitstream.md §3.1 and docs/API_CONTRACT.md §4.2.
//

// MARK: - H264NALType

/// An H.264 `nal_unit_type`, the low five bits of the one-byte NAL header.
///
/// Only the values Vigil names have a case; `init(rawValue:)` returns `nil` for the rest (17, 18,
/// 22, 23 and the reserved band), which is the correct handling — an unnamed type is dropped, not
/// guessed at. Use `H264NALType(rawValue:)` for classification and the raw `UInt8` everywhere the
/// exact wire value matters.
///
/// Types 24…31 never reach this module: they are the RTP packetization modes (STAP-A/B, MTAP,
/// FU-A/B) and `VigilRTP` unwraps them before a NAL is handed on.
public enum H264NALType: UInt8, Sendable, Hashable, CaseIterable {

    /// Unspecified. Dropped.
    case unspecified = 0

    /// Coded slice of a non-IDR picture. May be I, P or B — an I-slice here is **not** a keyframe.
    case codedSliceNonIDR = 1

    /// Coded slice data partition A. Dropped: Vigil does not support data partitioning.
    case dataPartitionA = 2

    /// Coded slice data partition B. Dropped.
    case dataPartitionB = 3

    /// Coded slice data partition C. Dropped.
    case dataPartitionC = 4

    /// Coded slice of an IDR picture. **This, and only this, is an H.264 keyframe.**
    case codedSliceIDR = 5

    /// Supplemental enhancement information. Parsed for `recovery_point` and `pic_timing`.
    case sei = 6

    /// Sequence parameter set. Stored and parsed.
    case sps = 7

    /// Picture parameter set. Stored and parsed.
    case pps = 8

    /// Access unit delimiter. Dropped rather than forwarded to the decoder.
    case accessUnitDelimiter = 9

    /// End of sequence. Flushes the decoder.
    case endOfSequence = 10

    /// End of stream. Flushes and tears down.
    case endOfStream = 11

    /// Filler data. Dropped.
    case fillerData = 12

    /// Sequence parameter set extension. Stored in the `avcC` `spsExt` array, never parsed.
    case spsExtension = 13

    /// Prefix NAL unit (SVC/MVC). Dropped.
    case prefixNALUnit = 14

    /// Subset sequence parameter set (SVC/MVC). Dropped.
    case subsetSPS = 15

    /// Depth parameter set (3D-AVC). Dropped.
    case depthParameterSet = 16

    /// Auxiliary coded picture slice. VCL, but dropped.
    case auxiliaryCodedSlice = 19

    /// Coded slice extension (SVC/MVC). VCL, but dropped.
    case sliceExtension = 20

    /// Coded slice extension for a depth view. VCL, but dropped.
    case sliceExtensionForDepth = 21

    // MARK: - Class predicates

    /// True for `nal_unit_type` 1…5, the video coding layer proper.
    ///
    /// Deliberately excludes 19…21: the standard classes them as VCL, but Vigil drops them, and
    /// every call site of `isVCL` means "does this NAL carry a slice of the picture we display".
    @inlinable public var isVCL: Bool { (1...5).contains(rawValue) }

    /// True only for type 5. An IDR is the only H.264 access unit that resets the decoder, so this
    /// is what `EncodedFrame.isKeyframe` and the sync-sample flag in a recording mean.
    @inlinable public var isIDR: Bool { self == .codedSliceIDR }

    /// True for SPS and PPS — the sets that go into `ParameterSets` and `avcC`.
    ///
    /// `spsExtension` (13) is **not** included: it is stored and forwarded, but it configures
    /// nothing we parse.
    @inlinable public var isParameterSet: Bool { self == .sps || self == .pps }

    /// True for the two types Vigil forwards to the decoder as picture data.
    @inlinable public var isForwardedToDecoder: Bool { self == .codedSliceNonIDR || isIDR }

    /// True for a NAL that carries no picture data.
    @inlinable public var isNonVCL: Bool { !isVCL }

    // MARK: - Raw-value predicates

    /// `isVCL` for a raw type code, without requiring the code to be a named case.
    ///
    /// The classification path reads a type code straight out of a NAL header, where an unnamed or
    /// reserved value is normal input rather than an error, so it must not go through
    /// `init(rawValue:)`.
    @inlinable public static func isVCL(rawValue: UInt8) -> Bool { (1...5).contains(rawValue) }

    /// `isIDR` for a raw type code.
    @inlinable public static func isIDR(rawValue: UInt8) -> Bool { rawValue == 5 }

    /// `isParameterSet` for a raw type code.
    @inlinable public static func isParameterSet(rawValue: UInt8) -> Bool { rawValue == 7 || rawValue == 8 }

    /// True for the RTP-only aggregation and fragmentation types 24…31, which `VigilRTP` unwraps
    /// and which must therefore never be seen by a parser in this module.
    @inlinable public static func isRTPPacketization(rawValue: UInt8) -> Bool { (24...31).contains(rawValue) }
}
