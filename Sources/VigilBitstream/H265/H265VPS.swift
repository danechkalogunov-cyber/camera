//
//  H265VPS.swift
//  VigilBitstream
//
//  The H.265 video parameter set: parsed just far enough to key the store, cross-check the SPS and
//  feed `hvcC.temporalIdNested`. The whole NAL is retained byte-for-byte elsewhere for re-emission.
//  Implements docs/spec-bitstream.md §12.
//

import VigilProtocols

// MARK: - H265VPS

/// The fields Vigil keeps from an H.265 video parameter set (ITU-T H.265 §7.3.2.1).
///
/// Everything after `profile_tier_level()` is deliberately not parsed: the VPS governs layer sets
/// and HRD parameters that a single-layer surveillance stream does not use, and the whole NAL is
/// stored verbatim anyway. **The `hvcC` profile/tier/level fields come from the SPS, never from
/// here** (spec-bitstream §12) — the VPS PTL is parsed only so the reserved canary after it can be
/// checked, and is then discarded.
public struct H265VPS: Sendable, Hashable, Codable {

    // MARK: - Stored Properties

    /// `vps_video_parameter_set_id`, 0…15. The store key.
    public var vpsID: UInt8

    /// `vps_max_layers_minus1`. Anything other than 0 means a multi-layer (SHVC/MV-HEVC) stream,
    /// which Vigil does not decode; the parse still succeeds so the bytes reach the decoder.
    public var maxLayersMinus1: UInt8

    /// `vps_max_sub_layers_minus1`, 0…6. Cross-checked against the SPS; the SPS wins.
    public var maxSubLayersMinus1: UInt8

    /// `vps_temporal_id_nesting_flag`. Feeds `hvcC.temporalIdNested` when no SPS has parsed.
    public var temporalIDNestingFlag: Bool

    // MARK: - Initialisation

    /// Builds a value directly, for tests and for callers reconstructing a VPS from a record.
    public init(vpsID: UInt8 = 0, maxLayersMinus1: UInt8 = 0, maxSubLayersMinus1: UInt8 = 0,
                temporalIDNestingFlag: Bool = false) {
        self.vpsID = vpsID
        self.maxLayersMinus1 = maxLayersMinus1
        self.maxSubLayersMinus1 = maxSubLayersMinus1
        self.temporalIDNestingFlag = temporalIDNestingFlag
    }

    // MARK: - Computed Properties

    /// True when this is a plain single-layer stream, which is every stream Vigil can decode.
    @inlinable public var isSingleLayer: Bool { maxLayersMinus1 == 0 }

    /// `vps_max_sub_layers_minus1 + 1`.
    @inlinable public var numTemporalLayers: Int { Int(maxSubLayersMinus1) + 1 }
}

// MARK: - Parsing

extension H265Parser {

    /// Parses an H.265 VPS NAL unit (type 32).
    ///
    /// `nal` includes the two-byte NAL header and is in on-wire, escaped form. The reserved
    /// `vps_reserved_0xffff_16bits` field is validated as a cheap corruption canary: a byte-swapped
    /// or misframed NAL fails here rather than producing a nonsense parameter set. The
    /// `profile_tier_level()` that follows is consumed and discarded (§12).
    ///
    /// - Throws: `.wrongNALType` when the NAL is not type 32, `.unsupportedSyntax` when the reserved
    ///   canary is wrong, `.valueOutOfRange` for a `vps_max_sub_layers_minus1` above 6, and
    ///   `.unexpectedEndOfData`/`.emptyNALUnit` for a truncated NAL.
    public static func parseVPS(_ nal: UnsafeRawBufferPointer) throws(BitstreamError) -> H265VPS {
        guard nal.count >= 2 else { throw BitstreamError.emptyNALUnit }
        let type = (nal[0] >> 1) & 0x3F
        guard type == 32 else { throw BitstreamError.wrongNALType(expected: 32, found: type) }

        var reader = try RBSPBitReader(nalUnit: nal, codec: .h265)
        var vps = H265VPS()
        vps.vpsID = UInt8(truncatingIfNeeded: try reader.u(4))
        try reader.skip(1)                                  // vps_base_layer_internal_flag
        try reader.skip(1)                                  // vps_base_layer_available_flag
        vps.maxLayersMinus1 = UInt8(truncatingIfNeeded: try reader.u(6))
        let maxSub = Int(try reader.u(3))
        guard maxSub <= 6 else {
            throw BitstreamError.valueOutOfRange(field: "vps_max_sub_layers_minus1",
                                                 value: UInt64(maxSub))
        }
        vps.maxSubLayersMinus1 = UInt8(maxSub)
        vps.temporalIDNestingFlag = try reader.flag()

        let canary = try reader.u(16)
        guard canary == 0xFFFF else {
            throw BitstreamError.unsupportedSyntax(
                "vps_reserved_0xffff_16bits was 0x\(String(canary, radix: 16)); NAL is misframed")
        }
        // Parsed for its side effect of validating the structure, then discarded (§12).
        _ = try ProfileTierLevel.parse(&reader, maxNumSubLayersMinus1: maxSub)
        return vps
    }
}
