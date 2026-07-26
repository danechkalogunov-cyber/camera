//
//  ProfileTierLevel.swift
//  VigilBitstream
//
//  H.265 `profile_tier_level()`: the parsed model, the 48-bit constraint-flag region that becomes
//  six bytes of `hvcC` verbatim, and the sub-layer loop whose reserved padding is the single most
//  common desynchronisation bug in third-party HEVC parsers.
//  Implements docs/spec-bitstream.md §11.
//
//  `VigilProtocols` only, for `BitstreamError`; the syntax itself is integers and strings.
//

import VigilProtocols

// MARK: - ProfileTierLevel

/// The `profile_tier_level()` syntax structure of an H.265 VPS or SPS (ITU-T H.265 §7.3.3).
///
/// Ten of the first thirteen bytes of an `hvcC` record come from here, which is why the 48-bit
/// `general_constraint_indicator_flags` region is stored as one right-aligned `UInt64` rather than
/// as separate booleans: it is read with a single `u64(48)` and re-emitted big-endian, so there is
/// no bit shuffling anywhere and therefore no opportunity to get the bit order wrong.
///
/// Sub-layer profile blocks are consumed but discarded — nothing downstream reads them. Only
/// `sub_layer_level_idc[i]` is retained, because it is the one sub-layer field that is diagnostic.
public struct ProfileTierLevel: Sendable, Hashable, Codable {

    // MARK: - Stored Properties

    /// `general_profile_space`, 2 bits. Always 0 for every stream Vigil has seen; a non-zero value
    /// means the profile numbering is from a different family and `generalProfileIDC` is not a
    /// profile in the usual sense.
    public var generalProfileSpace: UInt8

    /// `general_tier_flag`, 1 bit. 0 = Main tier, 1 = High tier.
    public var generalTierFlag: UInt8

    /// `general_profile_idc`, 5 bits. 1 = Main, 2 = Main 10, 3 = Main Still Picture, 4 = RExt.
    public var generalProfileIDC: UInt8

    /// `general_profile_compatibility_flag[0…31]` packed MSB-first, so `flag[0]` is bit 31.
    ///
    /// This is exactly the `hvcC` field order: the value is written big-endian with no shuffling.
    /// Main is `0x6000_0000` (flags 1 and 2); Main 10 as Hikvision emits it is `0x2400_0000`.
    public var generalProfileCompatibilityFlags: UInt32

    /// The 48-bit region from `general_progressive_source_flag` through the `inbld`/reserved bit,
    /// right-aligned in a `UInt64`. Byte-for-byte the `hvcC` `general_constraint_indicator_flags`.
    public var generalConstraintIndicatorFlags: UInt64

    /// `general_level_idc`. Thirty times the level number: 123 is level 4.1, 150 is level 5.0.
    public var generalLevelIDC: UInt8

    /// `sub_layer_level_idc[i]` for each sub-layer below the top one, `nil` where
    /// `sub_layer_level_present_flag[i]` was 0. Empty when `sps_max_sub_layers_minus1 == 0`.
    public var subLayerLevelIDC: [UInt8?]

    // MARK: - Initialisation

    /// Builds a value directly. Used by the parser and by `HEVCDecoderConfigurationRecord`, which
    /// reconstructs a `ProfileTierLevel` from the record's fixed byte layout rather than from a
    /// bitstream. Nothing is validated: an out-of-range value survives to be reported.
    public init(generalProfileSpace: UInt8 = 0, generalTierFlag: UInt8 = 0,
                generalProfileIDC: UInt8 = 0, generalProfileCompatibilityFlags: UInt32 = 0,
                generalConstraintIndicatorFlags: UInt64 = 0, generalLevelIDC: UInt8 = 0,
                subLayerLevelIDC: [UInt8?] = []) {
        self.generalProfileSpace = generalProfileSpace
        self.generalTierFlag = generalTierFlag
        self.generalProfileIDC = generalProfileIDC
        self.generalProfileCompatibilityFlags = generalProfileCompatibilityFlags
        self.generalConstraintIndicatorFlags = generalConstraintIndicatorFlags
        self.generalLevelIDC = generalLevelIDC
        self.subLayerLevelIDC = subLayerLevelIDC
    }

    // MARK: - Constraint flags

    /// `general_progressive_source_flag` — bit 47 of the 48-bit region.
    @inlinable public var progressiveSourceFlag: Bool {
        generalConstraintIndicatorFlags & (1 << 47) != 0
    }

    /// `general_interlaced_source_flag` — bit 46.
    @inlinable public var interlacedSourceFlag: Bool {
        generalConstraintIndicatorFlags & (1 << 46) != 0
    }

    /// `general_non_packed_constraint_flag` — bit 45.
    @inlinable public var nonPackedConstraintFlag: Bool {
        generalConstraintIndicatorFlags & (1 << 45) != 0
    }

    /// `general_frame_only_constraint_flag` — bit 44.
    @inlinable public var frameOnlyConstraintFlag: Bool {
        generalConstraintIndicatorFlags & (1 << 44) != 0
    }

    /// The six bytes to place at `hvcC` offset 6, most significant first.
    public var constraintIndicatorBytes: [UInt8] {
        (0 ..< 6).map { UInt8(truncatingIfNeeded: generalConstraintIndicatorFlags >> UInt64(40 - 8 * $0)) }
    }

    // MARK: - Naming

    /// Human-readable profile name for the inspector. Never used for control flow.
    ///
    /// Unknown values render as `"Unknown (n)"` rather than being coerced to Main — a stream whose
    /// profile we do not recognise may still decode, and the HUD should say so honestly.
    public var profileName: String {
        switch generalProfileIDC {
        case 1: "Main"
        case 2: "Main 10"
        case 3: "Main Still Picture"
        case 4: "Format Range Extensions"
        case 5: "High Throughput"
        case 9: "Screen Content Coding"
        default: "Unknown (\(generalProfileIDC))"
        }
    }

    /// Human-readable level, e.g. `"4.1"`, or `"4.1 High tier"` when `general_tier_flag` is set.
    ///
    /// `general_level_idc` is thirty times the level, so the arithmetic is exact in integers:
    /// `123 * 10 / 30 == 41` renders as `"4.1"`. Levels are never reported as a bare integer.
    public var levelName: String {
        let tenths = Int(generalLevelIDC) * 10 / 30
        let base = "\(tenths / 10).\(tenths % 10)"
        return generalTierFlag == 1 ? base + " High tier" : base
    }

    // MARK: - Parsing

    /// Consumes one `profile_tier_level(1, maxNumSubLayersMinus1)` from `reader`.
    ///
    /// The layout is fixed at 96 bits for the general block, then, when there are sub-layers,
    /// `2 × maxNumSubLayersMinus1` present-flag bits **followed by `2 × (8 − maxNumSubLayersMinus1)`
    /// bits of `reserved_zero_2bits`**, and only then the sub-layer bodies. Omitting that padding —
    /// or emitting it when `maxNumSubLayersMinus1 == 0`, where it is absent — shifts every
    /// subsequent field and yields a plausible but wrong picture size.
    ///
    /// - Parameters:
    ///   - reader: positioned at `general_profile_space`; advanced past the whole structure.
    ///   - maxNumSubLayersMinus1: `sps_max_sub_layers_minus1` or `vps_max_sub_layers_minus1`.
    /// - Throws: `.valueOutOfRange` when `maxNumSubLayersMinus1` exceeds 6 (H.265 forbids 7), and
    ///   `.unexpectedEndOfData` when the parameter set is truncated mid-structure.
    static func parse(
        _ reader: inout RBSPBitReader, maxNumSubLayersMinus1: Int
    ) throws(BitstreamError) -> ProfileTierLevel {
        guard maxNumSubLayersMinus1 >= 0, maxNumSubLayersMinus1 <= 6 else {
            throw BitstreamError.valueOutOfRange(field: "max_sub_layers_minus1",
                                                 value: UInt64(max(maxNumSubLayersMinus1, 0)))
        }
        var ptl = ProfileTierLevel(
            generalProfileSpace: UInt8(truncatingIfNeeded: try reader.u(2)),
            generalTierFlag: UInt8(truncatingIfNeeded: try reader.u(1)),
            generalProfileIDC: UInt8(truncatingIfNeeded: try reader.u(5)),
            generalProfileCompatibilityFlags: try reader.u(32),
            generalConstraintIndicatorFlags: try reader.u64(48),
            generalLevelIDC: UInt8(truncatingIfNeeded: try reader.u(8))
        )

        // The two present-flag arrays are read first, for every sub-layer, before any sub-layer body.
        var profilePresent = [Bool]()
        var levelPresent = [Bool]()
        profilePresent.reserveCapacity(maxNumSubLayersMinus1)
        levelPresent.reserveCapacity(maxNumSubLayersMinus1)
        for _ in 0 ..< maxNumSubLayersMinus1 {
            profilePresent.append(try reader.flag())
            levelPresent.append(try reader.flag())
        }

        // `reserved_zero_2bits[i]` for i in maxNumSubLayersMinus1 ..< 8 — present only when there is
        // at least one sub-layer, and exactly `8 - maxNumSubLayersMinus1` pairs of bits.
        if maxNumSubLayersMinus1 > 0 {
            try reader.skip(2 * (8 - maxNumSubLayersMinus1))
        }

        ptl.subLayerLevelIDC.reserveCapacity(maxNumSubLayersMinus1)
        for i in 0 ..< maxNumSubLayersMinus1 {
            // 2 + 1 + 5 + 32 + 48 = 88 bits: the general block without `general_level_idc`.
            if profilePresent[i] { try reader.skip(88) }
            if levelPresent[i] {
                ptl.subLayerLevelIDC.append(UInt8(truncatingIfNeeded: try reader.u(8)))
            } else {
                ptl.subLayerLevelIDC.append(nil)
            }
        }
        return ptl
    }
}
