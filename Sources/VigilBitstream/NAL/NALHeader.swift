//
//  NALHeader.swift
//  VigilBitstream
//
//  The one-byte H.264 and two-byte H.265 NAL headers, encoded and decoded, plus `NALUnitRef`.
//  See docs/spec-bitstream.md §3 and docs/API_CONTRACT.md §4.2.
//

import VigilProtocols

// MARK: - NALUnitRef

/// A NAL unit located inside a larger buffer, without copying it.
///
/// `range` includes the NAL header and excludes any start code or length prefix, matching the
/// canonical storage form of a parameter set (docs/spec-bitstream.md §2.1). `layerID` and
/// `temporalID` are always 0 for H.264, which has neither field.
public struct NALUnitRef: Sendable, Hashable {

    /// Byte range into the source buffer, NAL header included.
    public let range: Range<Int>

    /// `nal_unit_type`: five bits for H.264, six for H.265.
    public let typeCode: UInt8

    /// H.265 `nuh_layer_id`. Always 0 for H.264, and 0 for every stream Vigil decodes.
    public let layerID: UInt8

    /// H.265 `nuh_temporal_id_plus1 - 1`. Always 0 for H.264.
    public let temporalID: UInt8

    /// Builds a reference. Nothing is validated: the caller has already decoded the header, and a
    /// range that does not fit its buffer is a programmer error in this module rather than an input.
    public init(range: Range<Int>, typeCode: UInt8, layerID: UInt8 = 0, temporalID: UInt8 = 0) {
        self.range = range
        self.typeCode = typeCode
        self.layerID = layerID
        self.temporalID = temporalID
    }

    /// Byte count of the NAL unit, header included.
    @inlinable public var count: Int { range.count }
}

// MARK: - NALHeader

/// Decoding and encoding of the NAL unit header of both codecs.
///
/// Every function here rejects `forbidden_zero_bit == 1`, because a set forbidden bit means the
/// byte stream is corrupt by definition — it is the cheapest possible check that a resync landed on
/// a real NAL rather than in the middle of slice data.
public enum NALHeader {

    // MARK: - H.264

    /// Splits the one-byte H.264 header into `nal_unit_type` and `nal_ref_idc`.
    ///
    /// Layout is `F | NRI(2) | type(5)`, most significant bit first.
    /// - Throws: `BitstreamError.forbiddenBitSet` when bit 7 is set.
    public static func decodeH264(_ b0: UInt8) throws(BitstreamError) -> (type: UInt8, refIdc: UInt8) {
        guard b0 & 0x80 == 0 else { throw BitstreamError.forbiddenBitSet }
        return (b0 & 0x1F, (b0 >> 5) & 0x03)
    }

    /// Builds a one-byte H.264 header. Both arguments are masked to their field widths, so a caller
    /// cannot accidentally set the forbidden bit.
    public static func encodeH264(type: UInt8, refIdc: UInt8) -> UInt8 {
        ((refIdc & 0x03) << 5) | (type & 0x1F)
    }

    // MARK: - H.265

    /// Splits the two-byte H.265 header into `nal_unit_type`, `nuh_layer_id` and `nuh_temporal_id`.
    ///
    /// Layout is `F | type(6) | layerID(6) | temporalID+1(3)` across the two bytes, so `layerID`
    /// straddles the byte boundary.
    /// - Throws: `BitstreamError.forbiddenBitSet` when bit 7 of `b0` is set, and
    ///   `BitstreamError.invalidTemporalID` when `nuh_temporal_id_plus1` is 0, which the standard
    ///   forbids and which would otherwise underflow.
    public static func decodeHEVC(
        _ b0: UInt8, _ b1: UInt8
    ) throws(BitstreamError) -> (type: UInt8, layerID: UInt8, temporalID: UInt8) {
        guard b0 & 0x80 == 0 else { throw BitstreamError.forbiddenBitSet }
        let type = (b0 >> 1) & 0x3F
        let layerID = ((b0 & 0x01) << 5) | ((b1 >> 3) & 0x1F)
        let tidPlus1 = b1 & 0x07
        guard tidPlus1 != 0 else { throw BitstreamError.invalidTemporalID }
        return (type, layerID, tidPlus1 - 1)
    }

    /// Builds a two-byte H.265 header.
    ///
    /// Every argument is masked to its field width and `temporalID` is stored as `+1`, so the pair
    /// always round-trips through `decodeHEVC` for `type` 0…63, `layerID` 0…63 and `temporalID`
    /// 0…6. A `temporalID` of 7 or more is masked to 6 rather than producing an illegal zero.
    public static func encodeHEVC(type: UInt8, layerID: UInt8, temporalID: UInt8) -> (UInt8, UInt8) {
        let tid = Swift.min(temporalID, 6)
        let b0 = ((type & 0x3F) << 1) | ((layerID >> 5) & 0x01)
        let b1 = ((layerID & 0x1F) << 3) | ((tid + 1) & 0x07)
        return (b0, b1)
    }

    // MARK: - Codec-neutral

    /// Reads `nal_unit_type` from a NAL unit of either codec.
    ///
    /// - Parameters:
    ///   - nal: The NAL unit **including** its header and **excluding** any start code or length
    ///     prefix.
    ///   - codec: Decides the header width — one byte for H.264, two for H.265.
    /// - Throws: `BitstreamError.emptyNALUnit` when the buffer is shorter than the header,
    ///   `.forbiddenBitSet` or `.invalidTemporalID` from the header decode, and
    ///   `.unsupportedSyntax` for MJPEG, which has no NAL units at all.
    @inlinable
    public static func typeCode(
        _ nal: UnsafeRawBufferPointer, codec: VideoCodec
    ) throws(BitstreamError) -> UInt8 {
        switch codec {
        case .h264:
            guard nal.count >= 1 else { throw BitstreamError.emptyNALUnit }
            return try decodeH264(nal[0]).type
        case .h265:
            guard nal.count >= 2 else { throw BitstreamError.emptyNALUnit }
            return try decodeHEVC(nal[0], nal[1]).type
        case .mjpeg:
            throw BitstreamError.unsupportedSyntax("MJPEG has no NAL units")
        }
    }
}
