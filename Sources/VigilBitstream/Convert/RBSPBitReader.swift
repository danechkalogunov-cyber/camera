//
//  RBSPBitReader.swift
//  VigilBitstream
//
//  Exp-Golomb (`ue`/`se`), `more_rbsp_data()` and emulation-prevention removal layered over
//  `VigilProtocols.BitReader`. See docs/spec-bitstream.md §7 and docs/API_CONTRACT.md §4.2.
//

import VigilProtocols

// MARK: - Error bridging

extension BitstreamError {

    /// Maps a raw bit-reader failure onto the module's own taxonomy, so a log line names the
    /// syntax element as well as the bit position.
    ///
    /// `unsupportedWidth` becomes `valueOutOfRange` rather than a trap: the width of an Exp-Golomb
    /// suffix is derived from parsed data, so a hostile NAL can reach it and must not crash us.
    static func from(_ error: BitReaderError) -> BitstreamError {
        switch error {
        case let .unexpectedEndOfData(atBit):
            return .unexpectedEndOfData(atBit: atBit)
        case .negativeSkip:
            return .negativeSkip
        case let .unsupportedWidth(width):
            return .valueOutOfRange(field: "bit width", value: UInt64(UInt32(bitPattern: Int32(clamping: width))))
        }
    }
}

// MARK: - RBSPBitReader

/// A bit cursor over an unescaped RBSP, with the two Exp-Golomb codes and `more_rbsp_data()`.
///
/// Exp-Golomb lives here and not in `VigilProtocols` (docs/spec-bitstream.md §25 item 12): the raw
/// reader knows nothing about NAL units, and `ue`/`se` are H.264/H.265 syntax, not bit arithmetic.
///
/// Every read is bounds-checked and throws `BitstreamError`; nothing here traps, and no method
/// allocates. The type is a value: copying one is free, which is how a parser looks ahead.
public struct RBSPBitReader: Sendable {

    /// The underlying raw cursor.
    private var reader: BitReader

    /// Bit index of the `rbsp_stop_one_bit`, i.e. of the last set bit in the buffer, or −1 when the
    /// buffer is all zeros (which is malformed and makes `moreRBSPData()` permanently false).
    ///
    /// Computed once at init so `moreRBSPData()` is O(1); the H.264 PPS calls it at a decision
    /// point where a linear rescan would be quadratic in a hostile buffer.
    private let stopBitIndex: Int

    // MARK: - Initialisation

    /// Unescapes `nal` and positions the cursor at the first bit of its RBSP.
    ///
    /// - Parameters:
    ///   - nal: The NAL unit including its header, without a start code or length prefix.
    ///   - codec: Decides how many header bytes precede the RBSP.
    /// - Throws: Whatever `RBSP.unescape` throws — `.emptyNALUnit` for a NAL with no payload,
    ///   `.tooLarge` past `Limits.maxUnescapeBytes`, `.unsupportedSyntax` for MJPEG.
    public init(nalUnit nal: UnsafeRawBufferPointer, codec: VideoCodec) throws(BitstreamError) {
        guard codec.isNALBased else { throw BitstreamError.unsupportedSyntax("MJPEG has no NAL units") }
        try self.init(rbsp: RBSP.unescape(nal, skippingHeaderBytes: codec.nalHeaderLength))
    }

    /// Positions the cursor over an already-unescaped payload: an SEI payload, or a test fixture.
    ///
    /// - Throws: `BitstreamError.emptyNALUnit` for an empty buffer.
    public init(rbsp: [UInt8]) throws(BitstreamError) {
        guard !rbsp.isEmpty else { throw BitstreamError.emptyNALUnit }
        self.reader = BitReader(rbsp)
        var idx = rbsp.count * 8 - 1
        var found = -1
        while idx >= 0 {
            let byte = rbsp[idx >> 3]
            if byte != 0 {
                if (byte >> (7 - UInt8(idx & 7))) & 1 == 1 {
                    found = idx
                    break
                }
                idx -= 1
            } else {
                idx -= (idx & 7) + 1                // the whole byte is zero; skip to the one below
            }
        }
        self.stopBitIndex = found
    }

    // MARK: - Position

    /// Bits consumed so far, counted from the first RBSP bit.
    public var bitOffset: Int { reader.bitOffset }

    /// Bits not yet consumed.
    public var bitsRemaining: Int { reader.bitsRemaining }

    /// True when the cursor sits on a byte boundary.
    public var isByteAligned: Bool { reader.isByteAligned }

    /// Total bits in the unescaped RBSP. The denominator of the "consumed exactly this many bits"
    /// assertion that proves every skip loop landed correctly.
    public var bitCount: Int { reader.bitOffset + reader.bitsRemaining }

    // MARK: - Fixed-width reads

    /// Reads `n` bits (0…32), most significant first.
    public mutating func u(_ n: Int) throws(BitstreamError) -> UInt32 {
        do { return try reader.u(n) } catch { throw BitstreamError.from(error) }
    }

    /// Reads `n` bits (0…64). Needed for H.265 `general_constraint_indicator_flags`, 48 bits wide.
    public mutating func u64(_ n: Int) throws(BitstreamError) -> UInt64 {
        do { return try reader.u64(n) } catch { throw BitstreamError.from(error) }
    }

    /// Reads one bit as a Boolean: every `*_flag` syntax element.
    public mutating func flag() throws(BitstreamError) -> Bool {
        do { return try reader.flag() } catch { throw BitstreamError.from(error) }
    }

    /// Advances `n` bits without interpreting them.
    public mutating func skip(_ n: Int) throws(BitstreamError) {
        do { try reader.skip(n) } catch { throw BitstreamError.from(error) }
    }

    /// Discards bits up to the next byte boundary without validating them.
    public mutating func alignToByte() {
        reader.alignToByte()
    }

    /// Reads `n` bits (0…32) without moving the cursor.
    public func peek(_ n: Int) throws(BitstreamError) -> UInt32 {
        do { return try reader.peek(n) } catch { throw BitstreamError.from(error) }
    }

    // MARK: - Exp-Golomb

    /// `ue(v)` — unsigned Exp-Golomb, H.264 §9.1 / H.265 §9.2.
    ///
    /// Reads `leadingZeroBits` zeros, then a `1`, then that many suffix bits;
    /// `codeNum = 2^lz − 1 + suffix`.
    ///
    /// - Throws: `.malformedExpGolomb` past `Limits.maxExpGolombLeadingZeros` leading zeros or when
    ///   the value exceeds `UInt32.max` — both are the shapes a hostile NAL uses to make a parser
    ///   loop or overflow — and `.unexpectedEndOfData` when the code runs off the end.
    public mutating func ue() throws(BitstreamError) -> UInt32 {
        var leadingZeros = 0
        while true {
            guard reader.bitsRemaining > 0 else {
                throw BitstreamError.unexpectedEndOfData(atBit: reader.bitOffset)
            }
            if try u(1) == 1 { break }
            leadingZeros += 1
            if leadingZeros > Limits.maxExpGolombLeadingZeros {
                throw BitstreamError.malformedExpGolomb(leadingZeros: leadingZeros)
            }
        }
        if leadingZeros == 0 { return 0 }
        let suffix = try u64(leadingZeros)
        let value = (UInt64(1) << UInt64(leadingZeros)) - 1 + suffix
        guard value <= UInt64(UInt32.max) else {
            throw BitstreamError.malformedExpGolomb(leadingZeros: leadingZeros)
        }
        return UInt32(value)
    }

    /// `ue(v)` with a range check in one step. `field` names the syntax element in the thrown error,
    /// which is what makes a `valueOutOfRange` log line diagnosable.
    public mutating func ue(_ field: String, max: UInt32) throws(BitstreamError) -> UInt32 {
        let value = try ue()
        guard value <= max else {
            throw BitstreamError.valueOutOfRange(field: field, value: UInt64(value))
        }
        return value
    }

    /// `se(v)` — signed Exp-Golomb, H.264 §9.1.1.
    ///
    /// `k = ue()`, then `value = (−1)^(k+1) · ⌈k / 2⌉`: an odd `k` is positive, an even one negative.
    public mutating func se() throws(BitstreamError) -> Int32 {
        let k = try ue()
        let magnitude = Int64((UInt64(k) + 1) / 2)
        let signed = (k & 1) == 1 ? magnitude : -magnitude
        guard signed >= Int64(Int32.min), signed <= Int64(Int32.max) else {
            throw BitstreamError.valueOutOfRange(field: "se(v)", value: UInt64(k))
        }
        return Int32(signed)
    }

    /// `se(v)` with an inclusive range check. Used for `delta_scale`, whose −128…127 bound is what
    /// keeps a hostile scaling list from desynchronising the rest of the SPS.
    public mutating func se(_ field: String, min: Int32, max: Int32) throws(BitstreamError) -> Int32 {
        let value = try se()
        guard value >= min, value <= max else {
            throw BitstreamError.valueOutOfRange(field: field, value: UInt64(UInt32(bitPattern: value)))
        }
        return value
    }

    // MARK: - RBSP structure

    /// `more_rbsp_data()` — H.264 §7.2. True when at least one bit remains before the
    /// `rbsp_stop_one_bit`.
    ///
    /// O(1): the stop bit was located once at init. False for a buffer with no set bit at all, which
    /// is malformed and where "there is more syntax here" would be a lie.
    public func moreRBSPData() -> Bool {
        guard stopBitIndex >= 0 else { return false }
        return reader.bitOffset < stopBitIndex
    }

    /// Consumes and validates `rbsp_trailing_bits()`: one `1` bit, then zeros to the byte boundary.
    ///
    /// Returns `false` instead of throwing, and callers treat that as a diagnostic rather than a
    /// parse failure: a wrong trailing pattern is the single most common firmware nonconformance
    /// and is harmless, because every field we care about has already been read.
    public mutating func checkRBSPTrailingBits() -> Bool {
        guard (try? reader.u(1)) == 1 else { return false }
        while !reader.isByteAligned {
            guard (try? reader.u(1)) == 0 else { return false }
        }
        return true
    }
}
