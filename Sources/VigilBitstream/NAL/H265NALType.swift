//
//  H265NALType.swift
//  VigilBitstream
//
//  ITU-T H.265 Table 7-1 `nal_unit_type`, with the IRAP/RASL/RADL predicates the access-unit gate
//  and the RASL drop rule need. See docs/spec-bitstream.md §3.2 and docs/API_CONTRACT.md §4.2.
//

// MARK: - H265NALType

/// An H.265 `nal_unit_type`, the six bits `(byte0 >> 1) & 0x3F` of the two-byte NAL header.
///
/// The reserved bands (10…15, 22…31, 41…47) and the RTP-only band (48…63) have no cases, so
/// `init(rawValue:)` returns `nil` for them; an unnamed type is dropped rather than guessed at. Use
/// the `static` raw-value predicates when classifying a code read straight from a header, where an
/// unnamed value is normal input rather than an error.
///
/// Hikvision H.265 encoders emit `idrWRADL` for the periodic keyframe and `trailR` for everything
/// else. `craNUT` appears on NVR playback streams, which is the one case where the RASL drop rule
/// matters.
public enum H265NALType: UInt8, Sendable, Hashable, CaseIterable {

    /// Trailing picture, sub-layer non-reference.
    case trailN = 0

    /// Trailing picture, sub-layer reference. The ordinary inter-coded picture.
    case trailR = 1

    /// Temporal sub-layer access, non-reference.
    case tsaN = 2

    /// Temporal sub-layer access, reference.
    case tsaR = 3

    /// Step-wise temporal sub-layer access, non-reference.
    case stsaN = 4

    /// Step-wise temporal sub-layer access, reference.
    case stsaR = 5

    /// Random-access decodable leading picture, non-reference. Decodable after a CRA start.
    case radlN = 6

    /// Random-access decodable leading picture, reference.
    case radlR = 7

    /// Random-access skipped leading picture, non-reference.
    /// **Dropped while `NoRaslOutputFlag == 1`** — it references pictures before the CRA.
    case raslN = 8

    /// Random-access skipped leading picture, reference. Dropped under the same rule.
    case raslR = 9

    /// Broken-link access with leading pictures. IRAP; sets `NoRaslOutputFlag`.
    case blaWLP = 16

    /// Broken-link access with RADL pictures. IRAP; sets `NoRaslOutputFlag`.
    case blaWRADL = 17

    /// Broken-link access with no leading pictures. IRAP; sets `NoRaslOutputFlag`.
    case blaNLP = 18

    /// IDR that may be followed by RADL pictures. IRAP, keyframe. The Hikvision keyframe.
    case idrWRADL = 19

    /// IDR with no leading pictures. IRAP, keyframe.
    case idrNLP = 20

    /// Clean random access. IRAP, keyframe; when it is the first picture, `NoRaslOutputFlag = 1`.
    case craNUT = 21

    /// Video parameter set. Stored and parsed.
    case vps = 32

    /// Sequence parameter set. Stored and parsed.
    case sps = 33

    /// Picture parameter set. Stored and parsed.
    case pps = 34

    /// Access unit delimiter. Dropped rather than forwarded to the decoder.
    case aud = 35

    /// End of sequence. Flushes the decoder.
    case endOfSequence = 36

    /// End of bitstream. Flushes and tears down.
    case endOfBitstream = 37

    /// Filler data. Dropped.
    case fillerData = 38

    /// Prefix SEI. Parsed for `recovery_point` and `pic_timing`.
    case prefixSEI = 39

    /// Suffix SEI. Parsed, rarely useful.
    case suffixSEI = 40

    // MARK: - Class predicates

    /// True for `nal_unit_type` ≤ 31: the video coding layer, reserved VCL bands included.
    @inlinable public var isVCL: Bool { rawValue <= 31 }

    /// True for 16…23, an intra random access point. Every IRAP is a keyframe for our purposes.
    @inlinable public var isIRAP: Bool { (16...23).contains(rawValue) }

    /// True for 19 and 20, the two IDR types.
    @inlinable public var isIDR: Bool { rawValue == 19 || rawValue == 20 }

    /// True for 21, clean random access.
    @inlinable public var isCRA: Bool { rawValue == 21 }

    /// True for 16…18, the broken-link access types.
    @inlinable public var isBLA: Bool { (16...18).contains(rawValue) }

    /// True for 8 and 9 — the pictures that must be dropped after a CRA start.
    @inlinable public var isRASL: Bool { rawValue == 8 || rawValue == 9 }

    /// True for 6 and 7, which are decodable after a CRA start and are therefore kept.
    @inlinable public var isRADL: Bool { rawValue == 6 || rawValue == 7 }

    /// True for 6…9, every leading picture.
    @inlinable public var isLeading: Bool { (6...9).contains(rawValue) }

    /// True when no other picture in the same sub-layer uses this one for reference, i.e. when it
    /// can be dropped for temporal scaling. H.265 §3: even type ≤ 14.
    @inlinable public var isSubLayerNonReference: Bool { rawValue <= 14 && rawValue.isMultiple(of: 2) }

    /// True for VPS, SPS and PPS — the sets that go into `ParameterSets` and `hvcC`.
    @inlinable public var isParameterSet: Bool { (32...34).contains(rawValue) }

    /// True for either SEI type.
    @inlinable public var isSEI: Bool { self == .prefixSEI || self == .suffixSEI }

    /// True for a NAL that carries no picture data.
    @inlinable public var isNonVCL: Bool { !isVCL }

    // MARK: - Raw-value predicates

    /// `isVCL` for a raw type code, without requiring the code to be a named case.
    @inlinable public static func isVCL(rawValue: UInt8) -> Bool { rawValue <= 31 }

    /// `isIRAP` for a raw type code. Includes the reserved IRAP types 22 and 23, which are treated
    /// as keyframes and forwarded.
    @inlinable public static func isIRAP(rawValue: UInt8) -> Bool { (16...23).contains(rawValue) }

    /// `isIDR` for a raw type code.
    @inlinable public static func isIDR(rawValue: UInt8) -> Bool { rawValue == 19 || rawValue == 20 }

    /// `isCRA` for a raw type code.
    @inlinable public static func isCRA(rawValue: UInt8) -> Bool { rawValue == 21 }

    /// `isBLA` for a raw type code.
    @inlinable public static func isBLA(rawValue: UInt8) -> Bool { (16...18).contains(rawValue) }

    /// `isRASL` for a raw type code.
    @inlinable public static func isRASL(rawValue: UInt8) -> Bool { rawValue == 8 || rawValue == 9 }

    /// `isRADL` for a raw type code.
    @inlinable public static func isRADL(rawValue: UInt8) -> Bool { rawValue == 6 || rawValue == 7 }

    /// `isParameterSet` for a raw type code.
    @inlinable public static func isParameterSet(rawValue: UInt8) -> Bool { (32...34).contains(rawValue) }

    /// True for the RTP-only band 48…63 (48 = AP, 49 = FU, 50 = PACI), which `VigilRTP` unwraps and
    /// which must therefore never be seen by a parser in this module.
    @inlinable public static func isRTPPacketization(rawValue: UInt8) -> Bool { rawValue >= 48 }
}
