//
//  SliceHeader.swift
//  VigilBitstream
//
//  The access-unit boundary predicate. `VigilRTP` calls `isFirstSliceOfPicture` once per NAL on the
//  hot path because the RTP marker bit is not trustworthy on Hikvision firmware; that dependency is
//  the documented reason `VigilRTP → VigilBitstream` exists at all (API_CONTRACT §2 R-01).
//  Implements docs/spec-bitstream.md §20.1.
//

import VigilProtocols

// MARK: - SliceHeader

/// Cheap reads of the first fields of a slice header. A namespace, never instantiated.
///
/// Nothing here parses a slice header in full. Vigil never needs to: the decoder does that, and
/// the two questions the pipeline asks — "does this NAL start a new picture" and, advisorily,
/// "what slice type is it" — are answerable from the first few bits.
public enum SliceHeader {

    // MARK: - Access-unit boundary

    /// True when this VCL NAL unit is the first slice (segment) of a picture.
    ///
    /// **This is the authoritative access-unit boundary predicate; never duplicate it.**
    ///
    /// H.264 codes `first_mb_in_slice` as the first `ue(v)` of the slice header, and `ue(v) == 0`
    /// is exactly a leading `1` bit. H.265 codes `first_slice_segment_in_pic_flag` as literally the
    /// first RBSP bit. Either way the answer is the most significant bit of the first byte after
    /// the NAL header.
    ///
    /// **Why no unescaping is needed — preserve this if you refactor.** An emulation-prevention
    /// `0x03` can only follow two consecutive `0x00` bytes. The byte at index `nalHeaderLength` is
    /// preceded only by header bytes, and for a VCL NAL those are never zero: in H.264 the header
    /// byte holds `nal_unit_type ∈ 1…5` in its low five bits, and in H.265 the second header byte
    /// is `((layerID & 0x1F) << 3) | (temporalID + 1)` where `temporalID + 1 ≥ 1`. The first
    /// payload byte therefore can never be an escape byte, and reading it raw is exact.
    ///
    /// Cost: one bounds check and one load, no allocation, per NAL — which is what makes sixteen
    /// simultaneous streams affordable (§24 budgets this at 2 ns).
    ///
    /// - Returns: `false` for a NAL with no payload byte and for `.mjpeg`, which has no NAL header
    ///   and no slices. Callers must already have established that this is a VCL NAL; the
    ///   predicate is meaningless for a parameter set or an SEI.
    @inlinable
    public static func isFirstSliceOfPicture(nalUnit: UnsafeRawBufferPointer,
                                             codec: VideoCodec) -> Bool {
        let header = codec.nalHeaderLength
        guard header > 0, nalUnit.count > header else { return false }
        return nalUnit[header] & 0x80 != 0
    }

    // MARK: - Slice type

    /// The H.264 `slice_type`, when it can be read cheaply. **Advisory only.**
    ///
    /// `slice_type` is the second `ue(v)` of an H.264 slice header, so it is reachable without any
    /// context. Values 0…4 are P, B, I, SP, SI; values 5…9 are the same types with the additional
    /// promise that every slice in the picture has that type. Vigil uses it for the diagnostics HUD
    /// and never for control flow — an I-slice is **not** a keyframe (§20.5), and the gate keys on
    /// NAL type, not on this.
    ///
    /// Returns `nil` for H.265, where the slice type sits behind `dependent_slice_segment_flag`,
    /// the PPS id and a variable number of extra slice-header bits, and therefore cannot be read
    /// without the active PPS; and `nil` for a truncated or malformed header.
    ///
    /// Not on the hot path: it unescapes a short prefix of the NAL, which allocates.
    public static func sliceType(nalUnit: UnsafeRawBufferPointer, codec: VideoCodec) -> UInt8? {
        guard codec == .h264, nalUnit.count > 1 else { return nil }
        // Ten payload bytes are far more than the two Exp-Golomb codes can occupy: `first_mb_in_slice`
        // is at most 4 bytes for any real picture size and `slice_type` is at most 2 bits.
        let prefixEnd = min(nalUnit.count, 1 + 10)
        var prefix = [UInt8]()
        prefix.reserveCapacity(prefixEnd)
        for index in 0 ..< prefixEnd { prefix.append(nalUnit[index]) }

        let value: UInt32? = prefix.withUnsafeBytes { raw in
            guard var reader = try? RBSPBitReader(nalUnit: raw, codec: .h264) else { return nil }
            guard (try? reader.ue()) != nil else { return nil }      // first_mb_in_slice
            return try? reader.ue()
        }
        guard let value, value <= 9 else { return nil }
        return UInt8(truncatingIfNeeded: value)
    }

    /// True when an H.264 `slice_type` denotes an I or SI slice (2, 4, 7 or 9).
    ///
    /// An I-slice is not a keyframe: without an IDR the decoded picture buffer is not reset, so a
    /// decoder cannot start there. This exists for the HUD and for the `recovery_point` heuristic.
    @inlinable public static func isIntraSliceType(_ sliceType: UInt8) -> Bool {
        sliceType == 2 || sliceType == 4 || sliceType == 7 || sliceType == 9
    }
}
