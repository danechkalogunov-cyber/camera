//
//  SyntheticBitWriter.swift
//  VigilTestKit
//
//  MSB-first bit writer with Exp-Golomb coding, RBSP trailing/alignment bits and emulation-prevention
//  escaping. This is what makes the synthetic camera emit *real* H.264/H.265 syntax rather than
//  plausible-looking filler, so `VigilBitstream` parses it and derives the ground-truth geometry.
//  Implements docs/ARCHITECTURE.md §10.2 (the `syntactic` payload-realism tier).
//
//  No `import Foundation`: everything here is `[UInt8]` and integer work.
//

// MARK: - Bit writer

/// An MSB-first bit writer over a growable byte buffer.
///
/// Bits are packed into the current byte from the most significant end, which is the order every
/// video bitstream syntax element uses. The buffer is flushed to whole bytes only by `rbsp`,
/// `alignToByte()` or `writeTrailingBits()`; reading `rbsp` while a partial byte is outstanding
/// zero-fills it, which is what `byte_alignment()` would do anyway.
public struct SyntheticBitWriter: Sendable {

    /// Whole bytes emitted so far.
    private var bytes: [UInt8] = []

    /// The byte being filled, left-aligned: bit 7 is written first.
    private var partial: UInt8 = 0

    /// How many bits of `partial` are occupied, always in `0..<8`.
    private var bitsUsed: Int = 0

    /// An empty writer positioned at bit zero.
    public init() {}

    /// The bits written so far, zero-padded to a byte boundary.
    public var rbsp: [UInt8] {
        bitsUsed == 0 ? bytes : bytes + [partial]
    }

    /// Total bits written, including the partial byte.
    public var bitCount: Int { bytes.count * 8 + bitsUsed }

    /// `true` when no partial byte is outstanding.
    ///
    /// Callers need this for `cabac_alignment_one_bit`, which pads with `1` bits rather than the
    /// `1`-then-zeros shape of `byte_alignment()`.
    public var isByteAligned: Bool { bitsUsed == 0 }

    // MARK: Primitives

    /// Appends one bit.
    public mutating func writeBit(_ bit: Bool) {
        if bit { partial |= UInt8(0x80) >> UInt8(bitsUsed) }
        bitsUsed += 1
        if bitsUsed == 8 {
            bytes.append(partial)
            partial = 0
            bitsUsed = 0
        }
    }

    /// Appends the low `bits` bits of `value`, most significant first.
    ///
    /// `bits` outside `0...64` is a programmer error in fixture code and traps with a message; it
    /// can never originate from network data because nothing here parses input.
    public mutating func write(_ value: UInt64, bits: Int) {
        precondition(bits >= 0 && bits <= 64, "SyntheticBitWriter.write: bit count out of range")
        guard bits > 0 else { return }
        var index = bits - 1
        while index >= 0 {
            writeBit((value >> UInt64(index)) & 1 == 1)
            index -= 1
        }
    }

    /// Appends a flag as a single bit. A readability alias for `writeBit`.
    public mutating func writeFlag(_ flag: Bool) { writeBit(flag) }

    // MARK: Exp-Golomb

    /// Appends `value` as an unsigned Exp-Golomb code, `ue(v)`.
    ///
    /// `ue(0)` is the single bit `1`. That matters: `first_mb_in_slice` / `first_slice_segment_in_pic`
    /// are `ue(v)` / `u(1)`, and the depacketizer's access-unit boundary predicate reads exactly
    /// those bits, so they have to be genuinely coded rather than stubbed.
    public mutating func writeUE(_ value: UInt32) {
        let shifted = UInt64(value) + 1
        // `leadingZeroBitCount` gives the code length directly: a value needing n significant bits
        // is written as (n-1) zeros, then the n bits themselves.
        let significant = 64 - shifted.leadingZeroBitCount
        write(0, bits: significant - 1)
        write(shifted, bits: significant)
    }

    /// Appends `value` as a signed Exp-Golomb code, `se(v)`, using the ITU-T H.264 §9.1.1 mapping.
    public mutating func writeSE(_ value: Int32) {
        let mapped: UInt32 = value <= 0
            ? UInt32(clamping: -2 * Int64(value))
            : UInt32(clamping: 2 * Int64(value) - 1)
        writeUE(mapped)
    }

    // MARK: Alignment

    /// Writes `byte_alignment()`: a `1` bit, then `0` bits to the next byte boundary.
    public mutating func alignToByte() {
        writeBit(true)
        while bitsUsed != 0 { writeBit(false) }
    }

    /// Writes `rbsp_trailing_bits()`: the stop bit followed by zero padding.
    ///
    /// Identical to `alignToByte()` in effect; kept separate because the two spell different
    /// syntax structures and a reader of the parameter-set builders should see which one is meant.
    public mutating func writeTrailingBits() {
        alignToByte()
    }
}

// MARK: - Emulation prevention

/// RBSP ↔ NAL escaping, the same transform a real encoder applies before putting a NAL on the wire.
public enum SyntheticRBSP: Sendable {

    /// Inserts an emulation-prevention byte (`0x03`) before any third byte that would complete a
    /// `00 00 00`, `00 00 01`, `00 00 02` or `00 00 03` sequence.
    ///
    /// The synthetic slice payload is pseudorandom, so without this a filler run could forge a
    /// start code and change how a conforming parser splits the stream. Escaping here is not
    /// cosmetic: it is what makes the generated bytes legal NAL units.
    public static func escape(_ rbsp: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(rbsp.count + rbsp.count / 64 + 4)
        var zeroRun = 0
        for byte in rbsp {
            if zeroRun >= 2 && byte <= 0x03 {
                out.append(0x03)
                zeroRun = 0
            }
            out.append(byte)
            zeroRun = byte == 0x00 ? zeroRun + 1 : 0
        }
        return out
    }
}
