//
//  BitReader.swift
//  VigilProtocols
//
//  MSB-first bit reader for the fixed-width syntax elements of H.264/H.265 parameter sets, SEI
//  payloads and slice headers. Implements docs/spec-bitstream.md §7, which fixes this API verbatim
//  (`u`, `u64`, `flag`, `skip`, `alignToByte`, `peek`) because `VigilBitstream` is its principal
//  consumer, and docs/ARCHITECTURE.md §2.4 (type-ownership registry: `BitReader` is declared here).
//
//  Division of labour, per docs/spec-bitstream.md §7 and its checklist item 12: raw bit reading is
//  here; emulation-prevention removal (`RBSP.unescape`), Exp-Golomb (`ue`/`se`) and
//  `more_rbsp_data()` belong to `VigilBitstream.RBSPBitReader`, which wraps this type. Nothing in
//  this file knows what a NAL unit is.
//
//  No `import`: bit arithmetic over `[UInt8]` needs nothing from Foundation.
//

// MARK: - Errors

/// Why a `BitReader` read failed.
///
/// `VigilBitstream` maps these onto its own `BitstreamError` cases as they cross the module
/// boundary, so a log line names the syntax element as well as the bit position.
public enum BitReaderError: Error, Equatable, Sendable, CustomStringConvertible {

    /// A read ran past the end of the buffer. `atBit` is the position the read started from, which
    /// is where a truncated parameter set should be reported as ending.
    ///
    /// Always caused by the data, never by the caller: a truncated or corrupt NAL unit is normal
    /// input for a surveillance app and must never crash it.
    case unexpectedEndOfData(atBit: Int)

    /// `skip` was called with a negative count. Always a caller bug.
    case negativeSkip(Int)

    /// `u`, `u64` or `peek` was asked for a width outside its supported range — more than 32 bits
    /// for `u`/`peek`, more than 64 for `u64`, or negative.
    ///
    /// This throws rather than trapping even though it is a caller bug, because the width can be
    /// derived from parsed data (an Exp-Golomb suffix length, a `bit_depth` field) and a value that
    /// came from the network must never reach a `precondition`.
    case unsupportedWidth(Int)

    public var description: String {
        switch self {
        case let .unexpectedEndOfData(atBit):
            return "BitReader ran past the end of the buffer at bit \(atBit)"
        case let .negativeSkip(n):
            return "BitReader negative skip \(n)"
        case let .unsupportedWidth(n):
            return "BitReader unsupported width \(n)"
        }
    }
}

// MARK: - BitReader

/// A forward-only, most-significant-bit-first cursor over a byte buffer's bits.
///
/// Bit 0 is the high bit of byte 0, matching the bit order of every ITU-T video syntax table, so
/// `u(3)` on `0b101_00000` reads `5`. Every read is bounds-checked and throws `BitReaderError`;
/// nothing here traps, and a failed read leaves `bitOffset` unchanged so a caller can report the
/// exact position at which the data ran out.
///
/// The reader is a value type over a copy-on-write array: constructing one and copying one are both
/// free of allocation, and `peek` is implemented as exactly that copy.
public struct BitReader: Sendable {

    /// The buffer being read.
    public let bytes: [UInt8]

    /// Position of the next bit to read, counted from the high bit of `bytes[0]`.
    public private(set) var bitOffset: Int

    /// `bytes.count * 8`, cached because it is compared against on every read.
    ///
    /// `@usableFromInline` rather than `private` so the inlinable accessors below can see it.
    @usableFromInline let totalBits: Int

    /// Creates a reader positioned at the first bit of `bytes`. An empty buffer is legal; every read
    /// on it throws `.unexpectedEndOfData(atBit: 0)`.
    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
        self.bitOffset = 0
        self.totalBits = bytes.count * 8
    }

    // MARK: - Position

    /// Bits not yet read. Never negative.
    @inlinable public var bitsRemaining: Int { totalBits - bitOffset }

    /// True when the cursor sits on a byte boundary. True at offset 0 and at the end of the buffer.
    @inlinable public var isByteAligned: Bool { bitOffset & 7 == 0 }

    /// Index of the byte the cursor is in, i.e. `bitOffset / 8`. Equals `bytes.count` exactly when
    /// every bit has been consumed.
    @inlinable public var bytePosition: Int { bitOffset >> 3 }

    /// True when every bit has been consumed. True for an empty buffer.
    @inlinable public var isAtEnd: Bool { bitOffset >= totalBits }

    // MARK: - Reading

    /// Reads `n` bits (0...32), most significant first, zero-extended into a `UInt32`.
    ///
    /// `n == 0` returns 0 and does not move the cursor — the degenerate case appears naturally in
    /// syntax loops with a computed width. Throws `.unsupportedWidth` if `n` is outside 0...32 and
    /// `.unexpectedEndOfData` if fewer than `n` bits remain; in both cases the cursor does not move.
    public mutating func u(_ n: Int) throws(BitReaderError) -> UInt32 {
        guard n >= 0, n <= 32 else { throw BitReaderError.unsupportedWidth(n) }
        if n == 0 { return 0 }
        guard bitOffset + n <= totalBits else {
            throw BitReaderError.unexpectedEndOfData(atBit: bitOffset)
        }
        var result: UInt32 = 0
        var remaining = n
        while remaining > 0 {
            let byteIndex = bitOffset >> 3
            let bitInByte = bitOffset & 7
            let available = 8 - bitInByte
            let take = min(available, remaining)
            let byte = UInt32(bytes[byteIndex])
            let shifted = byte >> UInt32(available - take)
            let mask: UInt32 = (1 << UInt32(take)) - 1        // take <= 8, cannot overflow
            result = (result << UInt32(take)) | (shifted & mask)
            bitOffset += take
            remaining -= take
        }
        return result
    }

    /// Reads `n` bits (0...64), most significant first, zero-extended into a `UInt64`.
    ///
    /// Required for H.265 `general_constraint_indicator_flags`, which is 48 bits wide
    /// (docs/spec-bitstream.md §11). Bounds are checked once up front, so a read that runs off the
    /// end throws without having consumed the leading bits.
    public mutating func u64(_ n: Int) throws(BitReaderError) -> UInt64 {
        guard n >= 0, n <= 64 else { throw BitReaderError.unsupportedWidth(n) }
        guard bitOffset + n <= totalBits else {
            throw BitReaderError.unexpectedEndOfData(atBit: bitOffset)
        }
        if n <= 32 { return UInt64(try u(n)) }
        let high = try u(n - 32)
        let low = try u(32)
        return (UInt64(high) << 32) | UInt64(low)
    }

    /// Reads one bit as a Boolean: the `u(1)` of every `*_flag` syntax element.
    @inlinable public mutating func flag() throws(BitReaderError) -> Bool {
        try u(1) == 1
    }

    /// Advances the cursor by `n` bits without interpreting them.
    ///
    /// Throws `.negativeSkip` for `n < 0` and `.unexpectedEndOfData` if fewer than `n` bits remain;
    /// in both cases the cursor does not move.
    public mutating func skip(_ n: Int) throws(BitReaderError) {
        guard n >= 0 else { throw BitReaderError.negativeSkip(n) }
        guard bitOffset + n <= totalBits else {
            throw BitReaderError.unexpectedEndOfData(atBit: bitOffset)
        }
        bitOffset += n
    }

    /// Discards bits up to the next byte boundary, and does nothing when already aligned.
    ///
    /// Does not validate the discarded bits' value — checking `rbsp_trailing_bits` is
    /// `RBSPBitReader`'s job. Cannot run off the end: `totalBits` is a multiple of 8, so rounding
    /// `bitOffset` up to a multiple of 8 can never exceed it.
    public mutating func alignToByte() {
        bitOffset = (bitOffset + 7) & ~7
    }

    /// Reads `n` bits (0...32) without moving the cursor.
    ///
    /// Throws exactly what `u(n)` would throw. Implemented as a copy of the reader, which is free —
    /// for wider or multi-element lookahead, copy the reader yourself: `var probe = reader`.
    public func peek(_ n: Int) throws(BitReaderError) -> UInt32 {
        var copy = self
        return try copy.u(n)
    }
}
