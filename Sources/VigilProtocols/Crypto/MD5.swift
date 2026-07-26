//
//  MD5.swift
//  VigilProtocols
//
//  RFC 1321 MD5 with a streaming API. Present ONLY to satisfy RFC 2617 / RFC 2069 Digest
//  authentication, which mandates MD5. MD5 is cryptographically broken: never use it for integrity,
//  storage, key derivation or certificate pinning.
//  Implements docs/spec-rtsp.md §6.3 and the `H(x)` of docs/spec-isapi.md §5.2.
//
//  CryptoKit and CommonCrypto are unavailable to the pure layer (and on Linux), and the package has
//  no external dependencies, so the primitive is implemented here. The round constants are hard-coded
//  literals rather than computed from `sin()` so this file needs no Foundation maths.
//

import Foundation

// MARK: - MD5

/// RFC 1321 MD5, usable one-shot or incrementally.
///
/// Incremental use: `var md5 = MD5()`, any number of `update(_:)` calls with arbitrary chunk sizes,
/// then a single `finalize()`. `update(_:)` never allocates — the 64-byte block is held inline in the
/// value — because Digest authentication hashes several short strings per request.
///
/// `finalize()` is `consuming`: the value must not be used afterwards.
public struct MD5: Sendable {

    /// Length of an MD5 digest in bytes.
    public static let digestByteCount = 16

    /// MD5 processes the message in 64-byte blocks.
    private static let blockByteCount = 64

    // Chaining variables, RFC 1321 §3.3 initial values.
    private var a: UInt32 = 0x6745_2301
    private var b: UInt32 = 0xefcd_ab89
    private var c: UInt32 = 0x98ba_dcfe
    private var d: UInt32 = 0x1032_5476

    /// The partial input block, stored inline as eight 64-bit words (64 bytes) so that buffering a
    /// chunk boundary costs no heap allocation.
    private var block: (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64)
        = (0, 0, 0, 0, 0, 0, 0, 0)

    /// Number of bytes currently buffered in `block`; always in `0 ..< 64`.
    private var pending = 0

    /// Total number of message bytes absorbed, used for the length field of the padding. Wraps at
    /// 2^64 bytes exactly as the bit counter of RFC 1321 §3.2 wraps at 2^64 bits.
    private var messageByteCount: UInt64 = 0

    /// Creates an MD5 context over the empty message.
    public init() {}

    // MARK: Streaming input

    /// Absorbs `bytes` into the running digest.
    ///
    /// The buffer is read, never retained. A zero-length buffer is a no-op, so callers may feed
    /// empty chunks freely.
    public mutating func update(_ bytes: UnsafeRawBufferPointer) {
        guard !bytes.isEmpty else { return }
        messageByteCount &+= UInt64(bytes.count)
        var offset = 0

        // Complete a partially filled block first.
        if pending > 0 {
            let take = min(Self.blockByteCount - pending, bytes.count)
            copyIntoBlock(bytes, sourceOffset: 0, count: take, blockOffset: pending)
            pending += take
            offset = take
            guard pending == Self.blockByteCount else { return }
            compressPendingBlock()
            pending = 0
        }

        // Whole blocks are compressed straight out of the caller's buffer — no copy.
        while bytes.count - offset >= Self.blockByteCount {
            compress(UnsafeRawBufferPointer(rebasing: bytes[offset ..< offset + Self.blockByteCount]))
            offset += Self.blockByteCount
        }

        let tail = bytes.count - offset
        if tail > 0 {
            copyIntoBlock(bytes, sourceOffset: offset, count: tail, blockOffset: 0)
            pending = tail
        }
    }

    /// Absorbs the bytes of `data`.
    public mutating func update(_ data: Data) {
        data.withUnsafeBytes { self.update($0) }
    }

    /// Absorbs the bytes of `bytes`.
    public mutating func update(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { self.update($0) }
    }

    /// Absorbs any collection of bytes.
    ///
    /// Contiguous collections are absorbed in place; a non-contiguous one is streamed through a
    /// 64-byte stack buffer, so this path allocates nothing either.
    public mutating func update<Bytes: Collection<UInt8>>(_ bytes: Bytes) {
        let absorbed = bytes.withContiguousStorageIfAvailable { buffer -> Bool in
            self.update(UnsafeRawBufferPointer(buffer))
            return true
        }
        if absorbed == true { return }
        withUnsafeTemporaryAllocation(byteCount: Self.blockByteCount, alignment: 1) { scratch in
            var filled = 0
            for byte in bytes {
                scratch[filled] = byte
                filled += 1
                if filled == Self.blockByteCount {
                    self.update(UnsafeRawBufferPointer(scratch))
                    filled = 0
                }
            }
            if filled > 0 {
                self.update(UnsafeRawBufferPointer(rebasing: scratch[0 ..< filled]))
            }
        }
    }

    /// Absorbs the UTF-8 bytes of `string`. No terminator and no newline are added.
    public mutating func update(_ string: String) {
        var copy = string
        copy.withUTF8 { self.update(UnsafeRawBufferPointer($0)) }
    }

    // MARK: Output

    /// Applies the RFC 1321 §3.1–3.2 padding and returns the 16-byte digest.
    ///
    /// Consuming: the context is spent and must not be updated or finalized again.
    public consuming func finalize() -> [UInt8] {
        // `consuming` hands us ownership of the value; copy it into a local so the padding can be
        // absorbed through the ordinary mutating path.
        var context = self
        context.absorbPadding()
        return context.digestBytes()
    }

    // MARK: One-shot convenience

    /// The MD5 digest of `bytes`.
    public static func digest(_ bytes: UnsafeRawBufferPointer) -> [UInt8] {
        var md5 = MD5()
        md5.update(bytes)
        return md5.finalize()
    }

    /// The MD5 digest of `data`.
    public static func digest(_ data: Data) -> [UInt8] {
        var md5 = MD5()
        md5.update(data)
        return md5.finalize()
    }

    /// The MD5 digest of `bytes`.
    public static func digest(_ bytes: [UInt8]) -> [UInt8] {
        var md5 = MD5()
        md5.update(bytes)
        return md5.finalize()
    }

    /// The MD5 digest of any collection of bytes.
    public static func digest<Bytes: Collection<UInt8>>(_ bytes: Bytes) -> [UInt8] {
        var md5 = MD5()
        md5.update(bytes)
        return md5.finalize()
    }

    /// The MD5 digest of the UTF-8 bytes of `string`.
    public static func digest(_ string: String) -> [UInt8] {
        var md5 = MD5()
        md5.update(string)
        return md5.finalize()
    }

    /// Lowercase 32-character hex of the MD5 of the UTF-8 bytes of `string`.
    ///
    /// This is the `H(x)` of the Digest formulae in docs/spec-rtsp.md §6.4 and
    /// docs/spec-isapi.md §5.2.
    public static func hexDigest(_ string: String) -> String {
        Hex.lowercase(digest(string))
    }

    /// Lowercase 32-character hex of the MD5 of `bytes`.
    public static func hexDigest<Bytes: Collection<UInt8>>(_ bytes: Bytes) -> String {
        Hex.lowercase(digest(bytes))
    }

    /// Lowercase hex of an arbitrary byte array. A spelling of ``Hex/lowercase(_:)`` kept because
    /// docs/spec-rtsp.md §6.3 names it on this type.
    public static func hex(_ bytes: [UInt8]) -> String {
        Hex.lowercase(bytes)
    }

    // MARK: - Block plumbing

    /// Copies `count` bytes from `source` at `sourceOffset` into the inline block at `blockOffset`.
    private mutating func copyIntoBlock(
        _ source: UnsafeRawBufferPointer,
        sourceOffset: Int,
        count: Int,
        blockOffset: Int
    ) {
        let chunk = UnsafeRawBufferPointer(rebasing: source[sourceOffset ..< sourceOffset + count])
        withUnsafeMutableBytes(of: &block) { raw in
            UnsafeMutableRawBufferPointer(rebasing: raw[blockOffset ..< blockOffset + count])
                .copyMemory(from: chunk)
        }
    }

    /// Compresses the 64 bytes currently held in the inline block.
    private mutating func compressPendingBlock() {
        var state = (a, b, c, d)
        withUnsafeBytes(of: block) { state = Self.transform(state, $0) }
        (a, b, c, d) = state
    }

    /// Compresses one 64-byte block read directly from a caller-supplied buffer.
    private mutating func compress(_ rawBlock: UnsafeRawBufferPointer) {
        (a, b, c, d) = Self.transform((a, b, c, d), rawBlock)
    }

    /// Appends `0x80`, zero padding to 56 mod 64, and the 64-bit little-endian bit length.
    private mutating func absorbPadding() {
        let bitCount = messageByteCount &* 8
        // Worst case: 1 marker + 63 zeros + 8 length bytes.
        var padding = [UInt8](repeating: 0, count: 72)
        padding[0] = 0x80
        let zeros = pending < 56 ? 55 - pending : 119 - pending
        var count = 1 + zeros
        for i in 0 ..< 8 {
            padding[count + i] = UInt8(truncatingIfNeeded: bitCount >> (8 * i))
        }
        count += 8
        padding.withUnsafeBytes { self.update(UnsafeRawBufferPointer(rebasing: $0[0 ..< count])) }
    }

    /// The chaining variables serialised little-endian, RFC 1321 §3.5.
    private func digestBytes() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: Self.digestByteCount)
        Self.writeLittleEndian(a, into: &out, at: 0)
        Self.writeLittleEndian(b, into: &out, at: 4)
        Self.writeLittleEndian(c, into: &out, at: 8)
        Self.writeLittleEndian(d, into: &out, at: 12)
        return out
    }

    private static func writeLittleEndian(_ value: UInt32, into out: inout [UInt8], at index: Int) {
        out[index] = UInt8(truncatingIfNeeded: value)
        out[index + 1] = UInt8(truncatingIfNeeded: value >> 8)
        out[index + 2] = UInt8(truncatingIfNeeded: value >> 16)
        out[index + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    // MARK: - Compression function

    /// The four rounds of RFC 1321 §3.4 over one 64-byte block.
    ///
    /// - Parameters:
    ///   - state: The chaining variables `(A, B, C, D)` on entry.
    ///   - block: Exactly 64 bytes of message, interpreted as 16 little-endian 32-bit words. Loaded
    ///     with `loadUnaligned` because whole blocks are compressed straight out of caller buffers,
    ///     which carry no alignment guarantee.
    /// - Returns: The chaining variables after the block.
    private static func transform(
        _ state: (UInt32, UInt32, UInt32, UInt32),
        _ block: UnsafeRawBufferPointer
    ) -> (UInt32, UInt32, UInt32, UInt32) {
        precondition(block.count == blockByteCount, "MD5 block must be exactly 64 bytes")
        var (a, b, c, d) = state
        for i in 0 ..< 64 {
            let mixed: UInt32
            let wordIndex: Int
            switch i {
            case 0 ..< 16:
                mixed = (b & c) | (~b & d)
                wordIndex = i
            case 16 ..< 32:
                mixed = (d & b) | (~d & c)
                wordIndex = (5 * i + 1) % 16
            case 32 ..< 48:
                mixed = b ^ c ^ d
                wordIndex = (3 * i + 5) % 16
            default:
                mixed = c ^ (b | ~d)
                wordIndex = (7 * i) % 16
            }
            let word = UInt32(
                littleEndian: block.loadUnaligned(fromByteOffset: wordIndex * 4, as: UInt32.self)
            )
            let rotated = rotateLeft(mixed &+ a &+ sineConstants[i] &+ word, by: shifts[i])
            a = d
            d = c
            c = b
            b = b &+ rotated
        }
        return (state.0 &+ a, state.1 &+ b, state.2 &+ c, state.3 &+ d)
    }

    /// Rotate `value` left by `distance` bits (`distance` is always in `1 ..< 32` here).
    private static func rotateLeft(_ value: UInt32, by distance: UInt32) -> UInt32 {
        (value << distance) | (value >> (32 - distance))
    }

    /// `K[i] = floor(abs(sin(i + 1)) * 2^32)`, RFC 1321 §3.4, hard-coded so the pure layer needs no
    /// floating-point maths at runtime.
    private static let sineConstants: [UInt32] = [
        0xd76a_a478, 0xe8c7_b756, 0x2420_70db, 0xc1bd_ceee,
        0xf57c_0faf, 0x4787_c62a, 0xa830_4613, 0xfd46_9501,
        0x6980_98d8, 0x8b44_f7af, 0xffff_5bb1, 0x895c_d7be,
        0x6b90_1122, 0xfd98_7193, 0xa679_438e, 0x49b4_0821,
        0xf61e_2562, 0xc040_b340, 0x265e_5a51, 0xe9b6_c7aa,
        0xd62f_105d, 0x0244_1453, 0xd8a1_e681, 0xe7d3_fbc8,
        0x21e1_cde6, 0xc337_07d6, 0xf4d5_0d87, 0x455a_14ed,
        0xa9e3_e905, 0xfcef_a3f8, 0x676f_02d9, 0x8d2a_4c8a,
        0xfffa_3942, 0x8771_f681, 0x6d9d_6122, 0xfde5_380c,
        0xa4be_ea44, 0x4bde_cfa9, 0xf6bb_4b60, 0xbebf_bc70,
        0x289b_7ec6, 0xeaa1_27fa, 0xd4ef_3085, 0x0488_1d05,
        0xd9d4_d039, 0xe6db_99e5, 0x1fa2_7cf8, 0xc4ac_5665,
        0xf429_2244, 0x432a_ff97, 0xab94_23a7, 0xfc93_a039,
        0x655b_59c3, 0x8f0c_cc92, 0xffef_f47d, 0x8584_5dd1,
        0x6fa8_7e4f, 0xfe2c_e6e0, 0xa301_4314, 0x4e08_11a1,
        0xf753_7e82, 0xbd3a_f235, 0x2ad7_d2bb, 0xeb86_d391,
    ]

    /// Per-round left-rotation amounts, RFC 1321 §3.4.
    private static let shifts: [UInt32] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ]
}
