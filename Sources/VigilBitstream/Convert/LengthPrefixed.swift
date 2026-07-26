//
//  LengthPrefixed.swift
//  VigilBitstream
//
//  The 4-byte big-endian length-prefixed NAL format Vigil uses everywhere on the live path:
//  walking it, validating it, and the one append `VigilRTP` calls per reassembled NAL.
//  See docs/spec-bitstream.md §5.3 and docs/API_CONTRACT.md §4.2.
//

import VigilProtocols

// MARK: - LengthPrefixed

/// Reading and writing 4-byte big-endian length-prefixed NAL unit streams.
///
/// `lengthSizeMinusOne` is **always** 3 in Vigil — in `avcC`, in `hvcC`, in the
/// `nalUnitHeaderLength` argument to the CoreMedia constructors, and in every buffer handed to
/// `CMBlockBufferCreateWithMemoryBlock`. There is no configuration knob, which is what removes all
/// Annex-B conversion from the decode path (docs/spec-bitstream.md §2.2).
public enum LengthPrefixed {

    // MARK: - Reading

    /// Walks a length-prefixed buffer, calling `body` with each NAL's byte range and its raw type
    /// code. Allocates nothing; this is the hot-path walk.
    ///
    /// The range **includes** the NAL header and **excludes** the length prefix, so it is exactly
    /// the canonical parameter-set form and can be passed straight to a parser.
    ///
    /// - Parameters:
    ///   - bytes: The length-prefixed buffer.
    ///   - codec: Decides the NAL header width and therefore how the type code is extracted.
    ///   - body: Receives `(range, typeCode)` per NAL. May throw to abort the walk.
    /// - Throws: `BitstreamError.truncatedLengthPrefix(atOffset:)` for an incomplete prefix, a
    ///   zero-length NAL or a length that runs past the end; `.emptyNALUnit` for a NAL too short to
    ///   hold its own header; `.forbiddenBitSet` or `.invalidTemporalID` from the header decode; or
    ///   whatever `body` throws.
    /// - Note: The contract writes this as `throws(BitstreamError)`, which cannot be combined with a
    ///   throwing `body` — a typed-throws function cannot propagate a caller-chosen error type. The
    ///   throw is therefore untyped; every error this function itself raises is a `BitstreamError`.
    public static func enumerate(
        _ bytes: UnsafeRawBufferPointer, codec: VideoCodec,
        _ body: (Range<Int>, UInt8) throws -> Void
    ) throws {
        var i = 0
        let count = bytes.count
        let headerLength = codec.nalHeaderLength
        while i < count {
            guard i + 4 <= count else { throw BitstreamError.truncatedLengthPrefix(atOffset: i) }
            let n = (Int(bytes[i]) << 24) | (Int(bytes[i + 1]) << 16)
                | (Int(bytes[i + 2]) << 8) | Int(bytes[i + 3])
            guard n > 0, i + 4 + n <= count else {
                throw BitstreamError.truncatedLengthPrefix(atOffset: i)
            }
            guard n >= headerLength, headerLength > 0 else { throw BitstreamError.emptyNALUnit }
            let start = i + 4
            let typeCode: UInt8
            switch codec {
            case .h264:
                typeCode = try NALHeader.decodeH264(bytes[start]).type
            case .h265:
                typeCode = try NALHeader.decodeHEVC(bytes[start], bytes[start + 1]).type
            case .mjpeg:
                throw BitstreamError.unsupportedSyntax("MJPEG has no NAL units")
            }
            try body(start ..< (start + n), typeCode)
            i = start + n
        }
    }

    /// True when `bytes` is a well-formed length-prefixed stream: every prefix complete, every
    /// length positive, and the last NAL ending exactly at the end of the buffer.
    ///
    /// An empty buffer is well-formed — a frame with no NAL units is degenerate but not corrupt.
    /// This never throws and never reads out of bounds; it is the cheap guard before a walk.
    public static func validate(_ bytes: UnsafeRawBufferPointer) -> Bool {
        var i = 0
        let count = bytes.count
        while i < count {
            guard i + 4 <= count else { return false }
            let n = (Int(bytes[i]) << 24) | (Int(bytes[i + 1]) << 16)
                | (Int(bytes[i + 2]) << 8) | Int(bytes[i + 3])
            guard n > 0, i + 4 + n <= count else { return false }
            i += 4 + n
        }
        return true
    }

    // MARK: - Writing

    /// Appends `n` as a 4-byte big-endian length. Values above `UInt32.max` are impossible here:
    /// `Limits.maxNALUnitBytes` bounds every NAL long before this is reached.
    @inlinable public static func appendLength(_ n: Int, to out: inout ByteWriter) {
        out.appendU32BE(UInt32(truncatingIfNeeded: n))
    }

    /// Writes `nal` prefixed by its 4-byte big-endian length. **The one function `VigilRTP` uses**,
    /// called once per reassembled NAL unit, which is why it allocates nothing beyond the writer's
    /// own growth and takes a raw buffer rather than an array.
    @inlinable public static func append(nal: UnsafeRawBufferPointer, to out: inout ByteWriter) {
        out.appendU32BE(UInt32(truncatingIfNeeded: nal.count))
        out.append(contentsOf: nal)
    }
}
