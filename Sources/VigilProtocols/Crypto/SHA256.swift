//
//  SHA256.swift
//  VigilProtocols
//
//  FIPS 180-4 SHA-256 with a streaming API. Callers: the SPKI / leaf-certificate fingerprints used by
//  trust-on-first-use pinning (docs/spec-isapi.md §7, docs/spec-rtsp.md §10) and the encrypted
//  configuration export (docs/FEATURES.md). This is the digest to reach for by default — ``MD5`` and
//  ``SHA1`` exist only for protocol compatibility.
//
//  The 64-byte buffering below deliberately mirrors ``MD5`` and ``SHA1`` line for line rather than
//  being factored into a shared generic core: each file stays a self-contained, auditable
//  transcription of one specification, which is worth more in a primitive than the removed duplication.
//

import Foundation

// MARK: - SHA256

/// FIPS 180-4 SHA-256, usable one-shot or incrementally.
///
/// Incremental use: `var sha = SHA256()`, any number of `update(_:)` calls with arbitrary chunk
/// sizes, then a single `finalize()`. `update(_:)` never allocates — the 64-byte block is held inline
/// in the value.
///
/// `finalize()` is `consuming`: the value must not be used afterwards.
public struct SHA256: Sendable {

    /// Length of a SHA-256 digest in bytes.
    public static let digestByteCount = 32

    /// SHA-256 processes the message in 64-byte blocks.
    private static let blockByteCount = 64

    /// Initial hash value H(0), FIPS 180-4 §5.3.3 — the first 32 bits of the fractional parts of the
    /// square roots of the first eight primes.
    private var h: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32) = (
        0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a,
        0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19
    )

    /// The partial input block, stored inline as eight 64-bit words (64 bytes) so that buffering a
    /// chunk boundary costs no heap allocation.
    private var block: (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64)
        = (0, 0, 0, 0, 0, 0, 0, 0)

    /// Number of bytes currently buffered in `block`; always in `0 ..< 64`.
    private var pending = 0

    /// Total number of message bytes absorbed, used for the length field of the padding. Wraps at
    /// 2^64 bytes, matching the 64-bit length field of FIPS 180-4 §5.1.1.
    private var messageByteCount: UInt64 = 0

    /// Creates a SHA-256 context over the empty message.
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

    /// Applies the FIPS 180-4 §5.1.1 padding and returns the 32-byte digest.
    ///
    /// Consuming: the context is spent and must not be updated or finalized again.
    public consuming func finalize() -> [UInt8] {
        var context = self
        context.absorbPadding()
        return context.digestBytes()
    }

    // MARK: One-shot convenience

    /// The SHA-256 digest of `bytes`.
    public static func digest(_ bytes: UnsafeRawBufferPointer) -> [UInt8] {
        var sha = SHA256()
        sha.update(bytes)
        return sha.finalize()
    }

    /// The SHA-256 digest of `data`.
    public static func digest(_ data: Data) -> [UInt8] {
        var sha = SHA256()
        sha.update(data)
        return sha.finalize()
    }

    /// The SHA-256 digest of `bytes`.
    public static func digest(_ bytes: [UInt8]) -> [UInt8] {
        var sha = SHA256()
        sha.update(bytes)
        return sha.finalize()
    }

    /// The SHA-256 digest of any collection of bytes.
    public static func digest<Bytes: Collection<UInt8>>(_ bytes: Bytes) -> [UInt8] {
        var sha = SHA256()
        sha.update(bytes)
        return sha.finalize()
    }

    /// The SHA-256 digest of the UTF-8 bytes of `string`.
    public static func digest(_ string: String) -> [UInt8] {
        var sha = SHA256()
        sha.update(string)
        return sha.finalize()
    }

    /// Lowercase 64-character hex of the SHA-256 of the UTF-8 bytes of `string`.
    public static func hexDigest(_ string: String) -> String {
        Hex.lowercase(digest(string))
    }

    /// Lowercase 64-character hex of the SHA-256 of `bytes`.
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
        var state = h
        withUnsafeBytes(of: block) { state = Self.transform(state, $0) }
        h = state
    }

    /// Compresses one 64-byte block read directly from a caller-supplied buffer.
    private mutating func compress(_ rawBlock: UnsafeRawBufferPointer) {
        h = Self.transform(h, rawBlock)
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

    /// The hash value serialised big-endian, FIPS 180-4 §6.2.2.
    private func digestBytes() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: Self.digestByteCount)
        Self.writeBigEndian(h.0, into: &out, at: 0)
        Self.writeBigEndian(h.1, into: &out, at: 4)
        Self.writeBigEndian(h.2, into: &out, at: 8)
        Self.writeBigEndian(h.3, into: &out, at: 12)
        Self.writeBigEndian(h.4, into: &out, at: 16)
        Self.writeBigEndian(h.5, into: &out, at: 20)
        Self.writeBigEndian(h.6, into: &out, at: 24)
        Self.writeBigEndian(h.7, into: &out, at: 28)
        return out
    }

    private static func writeBigEndian(_ value: UInt32, into out: inout [UInt8], at index: Int) {
        out[index] = UInt8(truncatingIfNeeded: value >> 24)
        out[index + 1] = UInt8(truncatingIfNeeded: value >> 16)
        out[index + 2] = UInt8(truncatingIfNeeded: value >> 8)
        out[index + 3] = UInt8(truncatingIfNeeded: value)
    }

    // MARK: - Compression function

    /// The 64-round SHA-256 block function of FIPS 180-4 §6.2.2.
    ///
    /// - Parameters:
    ///   - state: The hash value `(H0 … H7)` on entry.
    ///   - rawBlock: Exactly 64 bytes of message, interpreted as 16 big-endian 32-bit words. Loaded
    ///     with `loadUnaligned` because whole blocks are compressed straight out of caller buffers,
    ///     which carry no alignment guarantee.
    /// - Returns: The hash value after the block.
    private static func transform(
        _ state: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32),
        _ rawBlock: UnsafeRawBufferPointer
    ) -> (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32) {
        precondition(rawBlock.count == blockByteCount, "SHA-256 block must be exactly 64 bytes")
        var a = state.0
        var b = state.1
        var c = state.2
        var d = state.3
        var e = state.4
        var f = state.5
        var g = state.6
        var hh = state.7
        // The 64-word message schedule lives on the stack: a heap array here would allocate once per
        // 64 bytes of input.
        withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 64) { w in
            for t in 0 ..< 16 {
                w[t] = UInt32(bigEndian: rawBlock.loadUnaligned(fromByteOffset: t * 4, as: UInt32.self))
            }
            for t in 16 ..< 64 {
                let s0 = rotateRight(w[t - 15], by: 7) ^ rotateRight(w[t - 15], by: 18) ^ (w[t - 15] >> 3)
                let s1 = rotateRight(w[t - 2], by: 17) ^ rotateRight(w[t - 2], by: 19) ^ (w[t - 2] >> 10)
                w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
            }
            for t in 0 ..< 64 {
                let sigma1 = rotateRight(e, by: 6) ^ rotateRight(e, by: 11) ^ rotateRight(e, by: 25)
                let choose = (e & f) ^ (~e & g)
                let temp1 = hh &+ sigma1 &+ choose &+ roundConstants[t] &+ w[t]
                let sigma0 = rotateRight(a, by: 2) ^ rotateRight(a, by: 13) ^ rotateRight(a, by: 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = sigma0 &+ majority
                hh = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }
        }
        return (
            state.0 &+ a, state.1 &+ b, state.2 &+ c, state.3 &+ d,
            state.4 &+ e, state.5 &+ f, state.6 &+ g, state.7 &+ hh
        )
    }

    /// Rotate `value` right by `distance` bits (`distance` is always in `1 ..< 32` here).
    private static func rotateRight(_ value: UInt32, by distance: UInt32) -> UInt32 {
        (value >> distance) | (value << (32 - distance))
    }

    /// K(0…63), FIPS 180-4 §4.2.2 — the first 32 bits of the fractional parts of the cube roots of
    /// the first 64 primes, hard-coded so the pure layer needs no floating-point maths at runtime.
    private static let roundConstants: [UInt32] = [
        0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5,
        0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
        0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3,
        0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
        0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc,
        0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
        0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7,
        0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
        0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13,
        0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
        0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3,
        0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
        0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5,
        0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
        0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208,
        0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
    ]
}
