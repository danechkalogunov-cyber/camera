//
//  AnnexB.swift
//  VigilBitstream
//
//  Start-code scanning and the Annex-B ↔ 4-byte-length-prefixed conversions, for the two edges
//  where Annex-B exists: reading a raw fixture, and writing a debug dump.
//  See docs/spec-bitstream.md §5 and docs/API_CONTRACT.md §4.2.
//

import Foundation

import VigilProtocols

// MARK: - AnnexB

/// Annex-B byte-stream scanning and conversion.
///
/// **Annex-B never appears on Vigil's live path.** `EncodedFrame.data` is always 4-byte big-endian
/// length-prefixed and `lengthSizeMinusOne` is always 3, so the depacketizers write lengths
/// directly as they reassemble (docs/spec-bitstream.md §2.2). This type exists for exactly two
/// edges: reading a raw `.h264`/`.h265` file as a test fixture, and writing a debug bitstream dump.
///
/// A start-code prefix is `00 00 01`, optionally preceded by a `zero_byte` giving `00 00 00 01`;
/// both forms occur in the same stream. Trailing `00` bytes after a NAL are `trailing_zero_8bits`
/// and are trimmed unconditionally, which is correct because H.264 §7.4.1 forbids a NAL unit from
/// ending in `0x00`.
public enum AnnexB {

    // MARK: - Scanning

    /// Index of the first byte of the next start-code prefix at or after `from`, with its length —
    /// 3, or 4 when a `zero_byte` precedes it. `nil` when there is no further start code.
    ///
    /// The loop steps three bytes at a time. If `bytes[i] > 1` then `i` is not the `01` of a start
    /// code; `i + 1` cannot be either, because that would need `bytes[i] == 0`; nor can `i + 2`, for
    /// the same reason. So all three are excluded and the scan may jump. Only `bytes[i] == 0` forces
    /// a single-byte step. On real payload the mean step is about 2.9 bytes.
    ///
    /// - Parameter from: The earliest byte index a returned start code may begin at. Passing an
    ///   index inside a NAL is normal: this is how the scanner walks a buffer that begins mid-NAL.
    public static func findStartCode(
        in bytes: UnsafeRawBufferPointer, from: Int
    ) -> (index: Int, length: Int)? {
        let n = bytes.count
        guard n >= 3 else { return nil }
        var i = Swift.max(from + 2, 2)
        while i < n {
            let c = bytes[i]
            if c > 1 {
                i += 3
            } else if c == 0 {
                i += 1
            } else {                                        // c == 1
                if bytes[i - 1] == 0, bytes[i - 2] == 0 {
                    if i >= 3, bytes[i - 3] == 0 { return (i - 3, 4) }
                    return (i - 2, 3)
                }
                i += 3
            }
        }
        return nil
    }

    /// Enumerates NAL unit payload ranges: start code stripped, trailing zero bytes trimmed.
    ///
    /// Allocates nothing. Bytes before the first start code — the case of a stream joined mid-NAL —
    /// are skipped, and an empty NAL between two adjacent start codes is not reported at all.
    /// `body` may throw to abort the walk.
    public static func enumerateNALUnits(
        in bytes: UnsafeRawBufferPointer, _ body: (Range<Int>) throws -> Void
    ) rethrows {
        guard var sc = findStartCode(in: bytes, from: 0) else { return }
        while true {
            let payloadStart = sc.index + sc.length
            let next = findStartCode(in: bytes, from: payloadStart)
            var end = next?.index ?? bytes.count
            while end > payloadStart, bytes[end - 1] == 0 { end -= 1 }   // trailing_zero_8bits
            if end > payloadStart { try body(payloadStart ..< end) }
            guard let following = next else { return }
            sc = following
        }
    }

    /// Every NAL unit payload range in `bytes`, as an array. The allocating convenience over
    /// `enumerateNALUnits`, for tests and for the fixture loader.
    public static func nalRanges(_ bytes: [UInt8]) -> [Range<Int>] {
        var ranges = [Range<Int>]()
        bytes.withUnsafeBytes { raw in
            enumerateNALUnits(in: raw) { ranges.append($0) }
        }
        return ranges
    }

    // MARK: - Annex-B to length-prefixed

    /// Converts an Annex-B byte stream into 4-byte big-endian length-prefixed form, copying.
    ///
    /// Always correct, whatever mixture of 3- and 4-byte start codes and trailing zeros the input
    /// holds. The result is exactly what `EncodedFrame.data` and `CMBlockBuffer` want.
    public static func toLengthPrefixed(_ annexB: [UInt8]) -> Data {
        var out = ByteWriter(capacity: annexB.count + 8)
        annexB.withUnsafeBytes { raw in
            enumerateNALUnits(in: raw) { range in
                // A NAL of 4 GiB cannot occur: `annexB` is an in-memory array of a fixture file.
                out.appendU32BE(UInt32(truncatingIfNeeded: range.count))
                out.append(contentsOf: raw[range])
            }
        }
        return out.data
    }

    /// Rewrites `buffer` from Annex-B to length-prefixed **in place**, or reports that it cannot.
    ///
    /// A 3-byte start code carries three bytes of overhead where a length prefix needs four, so an
    /// in-place rewrite of such a stream would have to shift every following byte up by one — O(n·k)
    /// for k short start codes, which defeats the point. This therefore runs two passes: the first
    /// verifies that the buffer begins with a start code, that every start code is 4 bytes, and that
    /// no NAL needed trailing-zero trimming; only then does the second overwrite each start code
    /// with the NAL's big-endian length.
    ///
    /// - Returns: `true` when the rewrite happened. `false` leaves `buffer` **untouched**, and the
    ///   caller falls back to `toLengthPrefixed`. An empty buffer, or one with no start code at all,
    ///   returns `false`: nothing was converted.
    public static func toLengthPrefixedInPlace(_ buffer: inout [UInt8]) -> Bool {
        var plan = [(prefixIndex: Int, nalLength: Int)]()
        var convertible = true
        buffer.withUnsafeBytes { raw in
            guard var sc = findStartCode(in: raw, from: 0), sc.index == 0, sc.length == 4 else {
                convertible = false
                return
            }
            while true {
                let payloadStart = sc.index + sc.length
                let next = findStartCode(in: raw, from: payloadStart)
                let end = next?.index ?? raw.count
                var trimmed = end
                while trimmed > payloadStart, raw[trimmed - 1] == 0 { trimmed -= 1 }
                guard trimmed == end, trimmed > payloadStart, end - payloadStart <= Limits.maxNALUnitBytes
                else {
                    convertible = false                     // trimming needed, empty NAL, or absurd size
                    return
                }
                plan.append((sc.index, end - payloadStart))
                guard let following = next else { return }
                guard following.length == 4 else {
                    convertible = false
                    return
                }
                sc = following
            }
        }
        guard convertible, !plan.isEmpty else { return false }
        for entry in plan {
            let n = UInt32(truncatingIfNeeded: entry.nalLength)
            buffer[entry.prefixIndex] = UInt8(truncatingIfNeeded: n >> 24)
            buffer[entry.prefixIndex + 1] = UInt8(truncatingIfNeeded: n >> 16)
            buffer[entry.prefixIndex + 2] = UInt8(truncatingIfNeeded: n >> 8)
            buffer[entry.prefixIndex + 3] = UInt8(truncatingIfNeeded: n)
        }
        return true
    }

    // MARK: - Length-prefixed to Annex-B

    /// Converts a 4-byte length-prefixed buffer into an Annex-B byte stream, copying.
    ///
    /// - Parameters:
    ///   - prefixed: Length-prefixed NAL units, `lengthSizeMinusOne == 3` as everywhere in Vigil.
    ///   - startCodeLength: 3 or 4. Four is the usual choice for a file a decoder will read back.
    /// - Throws: `BitstreamError.truncatedLengthPrefix` at the offset of a prefix that runs past the
    ///   end of the buffer or that declares a zero-length NAL, and `.unsupportedSyntax` for a start
    ///   code length other than 3 or 4.
    public static func fromLengthPrefixed(
        _ prefixed: Data, startCodeLength: Int = 4
    ) throws(BitstreamError) -> [UInt8] {
        guard startCodeLength == 3 || startCodeLength == 4 else {
            throw BitstreamError.unsupportedSyntax("start code length \(startCodeLength), expected 3 or 4")
        }
        let source = [UInt8](prefixed)
        var out = [UInt8]()
        out.reserveCapacity(source.count + 8)
        var i = 0
        while i < source.count {
            guard i + 4 <= source.count else { throw BitstreamError.truncatedLengthPrefix(atOffset: i) }
            let n = (Int(source[i]) << 24) | (Int(source[i + 1]) << 16)
                | (Int(source[i + 2]) << 8) | Int(source[i + 3])
            guard n > 0, i + 4 + n <= source.count else {
                throw BitstreamError.truncatedLengthPrefix(atOffset: i)
            }
            if startCodeLength == 4 { out.append(0x00) }
            out.append(contentsOf: [0x00, 0x00, 0x01])
            out.append(contentsOf: source[(i + 4) ..< (i + 4 + n)])
            i += 4 + n
        }
        return out
    }

    /// Overwrites each 4-byte big-endian length in `buffer` with a 4-byte start code, in place.
    ///
    /// Always exact: with `lengthSizeMinusOne == 3` a prefix and a 4-byte start code are both four
    /// bytes, so the conversion preserves the byte count and needs no allocation.
    ///
    /// - Throws: `BitstreamError.truncatedLengthPrefix(atOffset:)` when a prefix is incomplete, when
    ///   it declares a zero-length NAL, or when it runs past the end. `buffer` may have been
    ///   partially rewritten when this throws — the caller is expected to discard it.
    public static func fromLengthPrefixedInPlace(_ buffer: inout [UInt8]) throws(BitstreamError) {
        var i = 0
        while i < buffer.count {
            guard i + 4 <= buffer.count else { throw BitstreamError.truncatedLengthPrefix(atOffset: i) }
            let n = (Int(buffer[i]) << 24) | (Int(buffer[i + 1]) << 16)
                | (Int(buffer[i + 2]) << 8) | Int(buffer[i + 3])
            guard n > 0, i + 4 + n <= buffer.count else {
                throw BitstreamError.truncatedLengthPrefix(atOffset: i)
            }
            buffer[i] = 0x00
            buffer[i + 1] = 0x00
            buffer[i + 2] = 0x00
            buffer[i + 3] = 0x01
            i += 4 + n
        }
    }
}
