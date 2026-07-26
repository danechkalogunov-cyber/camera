//
//  SHA1.swift
//  VigilProtocols
//
//  RFC 3174 / FIPS 180-4 SHA-1 with a streaming API. Its only intended caller is the ONVIF
//  WS-Security UsernameToken, whose `PasswordDigest` is `Base64(SHA1(nonce || created || password))`
//  (docs/FEATURES.md §ONVIF). SHA-1 is collision-broken: do not use it for signatures, integrity or
//  certificate pinning — use ``SHA256`` there.
//
//  The 64-byte buffering below deliberately mirrors ``MD5`` and ``SHA256`` line for line rather than
//  being factored into a shared generic core: each file stays a self-contained, auditable
//  transcription of one specification, which is worth more in a primitive than the removed duplication.
//

import Foundation

// MARK: - SHA1

/// FIPS 180-4 SHA-1, usable one-shot or incrementally.
///
/// Incremental use: `var sha = SHA1()`, any number of `update(_:)` calls with arbitrary chunk sizes,
/// then a single `finalize()`. `update(_:)` never allocates — the 64-byte block is held inline in the
/// value.
///
/// `finalize()` is `consuming`: the value must not be used afterwards.
public struct SHA1: Sendable {

    /// Length of a SHA-1 digest in bytes.
    public static let digestByteCount = 20

    /// SHA-1 processes the message in 64-byte blocks.
    private static let blockByteCount = 64

    // Initial hash value H(0), FIPS 180-4 §5.3.1.
    private var h0: UInt32 = 0x6745_2301
    private var h1: UInt32 = 0xefcd_ab89
    private var h2: UInt32 = 0x98ba_dcfe
    private var h3: UInt32 = 0x1032_5476
    private var h4: UInt32 = 0xc3d2_e1f0

    /// The partial input block, stored inline as eight 64-bit words (64 bytes) so that buffering a
    /// chunk boundary costs no heap allocation.
    private var block: (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64)
        = (0, 0, 0, 0, 0, 0, 0, 0)

    /// Number of bytes currently buffered in `block`; always in `0 ..< 64`.
    private var pending = 0

    /// Total number of message bytes absorbed, used for the length field of the padding. Wraps at
    /// 2^64 bytes, matching the 64-bit length field of FIPS 180-4 §5.1.1.
    private var messageByteCount: UInt64 = 0

    /// Creates a SHA-1 context over the empty message.
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

    /// Applies the FIPS 180-4 §5.1.1 padding and returns the 20-byte digest.
    ///
    /// Consuming: the context is spent and must not be updated or finalized again.
    public consuming func finalize() -> [UInt8] {
        var context = self
        context.absorbPadding()
        return context.digestBytes()
    }

    // MARK: One-shot convenience

    /// The SHA-1 digest of `bytes`.
    public static func digest(_ bytes: UnsafeRawBufferPointer) -> [UInt8] {
        var sha = SHA1()
        sha.update(bytes)
        return sha.finalize()
    }

    /// The SHA-1 digest of `data`.
    public static func digest(_ data: Data) -> [UInt8] {
        var sha = SHA1()
        sha.update(data)
        return sha.finalize()
    }

    /// The SHA-1 digest of `bytes`.
    public static func digest(_ bytes: [UInt8]) -> [UInt8] {
        var sha = SHA1()
        sha.update(bytes)
        return sha.finalize()
    }

    /// The SHA-1 digest of any collection of bytes.
    public static func digest<Bytes: Collection<UInt8>>(_ bytes: Bytes) -> [UInt8] {
        var sha = SHA1()
        sha.update(bytes)
        return sha.finalize()
    }

    /// The SHA-1 digest of the UTF-8 bytes of `string`.
    public static func digest(_ string: String) -> [UInt8] {
        var sha = SHA1()
        sha.update(string)
        return sha.finalize()
    }

    /// Lowercase 40-character hex of the SHA-1 of the UTF-8 bytes of `string`.
    public static func hexDigest(_ string: String) -> String {
        Hex.lowercase(digest(string))
    }

    /// Lowercase 40-character hex of the SHA-1 of `bytes`.
    public static func hexDigest<Bytes: Collection<UInt8>>(_ bytes: Bytes) -> String {
        Hex.lowercase(digest(bytes))
    }

    /// Lowercase hex of an arbitrary byte array; a spelling of ``Hex/lowercase(_:)``.
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
        withUnsafeMutableBytes(of: &block) { raw in
            UnsafeMutableRawBufferPointer(rebasing: raw[blockOffset ..< blockOffset + count])
                .copyMemory(from: UnsafeRawBufferPointer(rebasing: source[sourceOffset ..< sourceOffset + count]))
        }
    }

    /// Compresses the 64 bytes currently held in the inline block.
    private mutating func compressPendingBlock() {
        var state = (h0, h1, h2, h3, h4)
        withUnsafeBytes(of: block) { state = Self.transform(state, $0) }
        (h0, h1, h2, h3, h4) = state
    }

    /// Compresses one 64-byte block read directly from a caller-supplied buffer.
    private mutating func compress(_ rawBlock: UnsafeRawBufferPointer) {
        (h0, h1, h2, h3, h4) = Self.transform((h0, h1, h2, h3, h4), rawBlock)
    }

    /// Appends `0x80`, zero padding to 56 mod 64, and the 64-bit big-endian bit length.
    private mutating func absorbPadding() {
        let bitCount = messageByteCount &* 8
        // Worst case: 1 marker + 63 zeros + 8 length bytes.
        var padding = [UInt8](repeating: 0, count: 72)
        padding[0] = 0x80
        let zeros = pending < 56 ? 55 - pending : 119 - pending
        var count = 1 + zeros
        for i in 0 ..< 8 {
            padding[count + i] = UInt8(truncatingIfNeeded: bitCount >> (8 * (7 - i)))
        }
        count += 8
        padding.withUnsafeBytes { self.update(UnsafeRawBufferPointer(rebasing: $0[0 ..< count])) }
    }

    /// The hash value serialised big-endian, FIPS 180-4 §6.1.2.
    private func digestBytes() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: Self.digestByteCount)
        Self.writeBigEndian(h0, into: &out, at: 0)
        Self.writeBigEndian(h1, into: &out, at: 4)
        Self.writeBigEndian(h2, into: &out, at: 8)
        Self.writeBigEndian(h3, into: &out, at: 12)
        Self.writeBigEndian(h4, into: &out, at: 16)
        return out
    }

    private static func writeBigEndian(_ value: UInt32, into out: inout [UInt8], at index: Int) {
        out[index] = UInt8(truncatingIfNeeded: value >> 24)
        out[index + 1] = UInt8(truncatingIfNeeded: value >> 16)
        out[index + 2] = UInt8(truncatingIfNeeded: value >> 8)
        out[index + 3] = UInt8(truncatingIfNeeded: value)
    }

    // MARK: - Compression function

    /// The 80-round SHA-1 block cipher of RFC 3174 §6.1 / FIPS 180-4 §6.1.2.
    ///
    /// - Parameters:
    ///   - state: The hash value `(H0 … H4)` on entry.
    ///   - rawBlock: Exactly 64 bytes of message, interpreted as 16 big-endian 32-bit words. Loaded
    ///     with `loadUnaligned` because whole blocks are compressed straight out of caller buffers,
    ///     which carry no alignment guarantee.
    /// - Returns: The hash value after the block.
    private static func transform(
        _ state: (UInt32, UInt32, UInt32, UInt32, UInt32),
        _ rawBlock: UnsafeRawBufferPointer
    ) -> (UInt32, UInt32, UInt32, UInt32, UInt32) {
        precondition(rawBlock.count == blockByteCount, "SHA-1 block must be exactly 64 bytes")
        var (a, b, c, d, e) = state
        // The 80-word message schedule lives on the stack: a heap array here would allocate once per
        // 64 bytes of input.
        withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 80) { w in
            for t in 0 ..< 16 {
                w[t] = UInt32(bigEndian: rawBlock.loadUnaligned(fromByteOffset: t * 4, as: UInt32.self))
            }
            for t in 16 ..< 80 {
                w[t] = rotateLeft(w[t - 3] ^ w[t - 8] ^ w[t - 14] ^ w[t - 16], by: 1)
            }
            for t in 0 ..< 80 {
                let f: UInt32
                let k: UInt32
                switch t {
                case 0 ..< 20:
                    f = (b & c) | (~b & d)
                    k = 0x5a82_7999
                case 20 ..< 40:
                    f = b ^ c ^ d
                    k = 0x6ed9_eba1
                case 40 ..< 60:
                    f = (b & c) | (b & d) | (c & d)
                    k = 0x8f1b_bcdc
                default:
                    f = b ^ c ^ d
                    k = 0xca62_c1d6
                }
                let temp = rotateLeft(a, by: 5) &+ f &+ e &+ k &+ w[t]
                e = d
                d = c
                c = rotateLeft(b, by: 30)
                b = a
                a = temp
            }
        }
        return (state.0 &+ a, state.1 &+ b, state.2 &+ c, state.3 &+ d, state.4 &+ e)
    }

    /// Rotate `value` left by `distance` bits (`distance` is always in `1 ..< 32` here).
    private static func rotateLeft(_ value: UInt32, by distance: UInt32) -> UInt32 {
        (value << distance) | (value >> (32 - distance))
    }
}
