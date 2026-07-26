//
//  ExpGolombTests.swift
//  VigilBitstreamTests
//
//  Table T-EG-1 of docs/spec-bitstream.md §7.1 verbatim, the leading-zero rejection, and the
//  `more_rbsp_data()` / `rbsp_trailing_bits()` behaviour of `RBSPBitReader`.
//

import Testing

import VigilBitstream
import VigilProtocols

@Suite("Exp-Golomb and RBSPBitReader")
struct ExpGolombTests {

    // MARK: - Helpers

    /// Packs a `"0101"` bit string into bytes, zero-padding the final byte.
    ///
    /// Zero padding is safe for every row of T-EG-1: each string encodes one complete code, so the
    /// padding is only ever read as `rbsp_trailing_bits`.
    private func rbsp(bits: String) -> [UInt8] {
        var bytes = [UInt8]()
        var current: UInt8 = 0
        var count = 0
        for character in bits where character == "0" || character == "1" {
            current = (current << 1) | (character == "1" ? 1 : 0)
            count += 1
            if count % 8 == 0 {
                bytes.append(current)
                current = 0
            }
        }
        if count % 8 != 0 {
            bytes.append(current << (8 - (count % 8)))
        }
        return bytes.isEmpty ? [0] : bytes
    }

    // MARK: - T-EG-1

    /// docs/spec-bitstream.md §7.1 table T-EG-1, `ue(v)` column, verbatim.
    @Test("ue(v) matches every row of T-EG-1", arguments: [
        ("1", UInt32(0)), ("010", 1), ("011", 2), ("00100", 3), ("00101", 4),
        ("00110", 5), ("00111", 6), ("0001000", 7), ("0001111", 14),
    ])
    func expGolombUnsignedMatchesSpecTable(bits: String, expected: UInt32) throws {
        var reader = try RBSPBitReader(rbsp: rbsp(bits: bits))
        let value = try reader.ue()
        #expect(value == expected)
    }

    /// docs/spec-bitstream.md §7.1 table T-EG-1, `se(v)` column, verbatim.
    @Test("se(v) matches every row of T-EG-1", arguments: [
        ("1", Int32(0)), ("010", 1), ("011", -1), ("00100", 2), ("00101", -2),
        ("00110", 3), ("00111", -3), ("0001000", 4), ("0001111", -7),
    ])
    func expGolombSignedMatchesSpecTable(bits: String, expected: Int32) throws {
        var reader = try RBSPBitReader(rbsp: rbsp(bits: bits))
        let value = try reader.se()
        #expect(value == expected)
    }

    /// The last row of T-EG-1: 32 zeros, a `1`, then 32 ones. The code is syntactically legal but
    /// its value exceeds `UInt32.max`, which is how a hostile NAL makes a naive parser overflow.
    @Test func expGolombRejectsValueAboveUInt32Max() throws {
        let bytes: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0x80]
        var reader = try RBSPBitReader(rbsp: bytes)
        #expect(throws: BitstreamError.malformedExpGolomb(leadingZeros: 32)) {
            _ = try reader.ue()
        }
    }

    /// 33 leading zeros is refused before the suffix is even read — the shape that makes an
    /// unbounded parser loop.
    @Test func expGolombRejectsThirtyThreeLeadingZeros() throws {
        let bytes: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x40]
        var reader = try RBSPBitReader(rbsp: bytes)
        #expect(throws: BitstreamError.malformedExpGolomb(leadingZeros: 33)) {
            _ = try reader.ue()
        }
    }

    /// A code whose leading zeros run off the end of the buffer must throw, not spin.
    @Test func expGolombRejectsCodeRunningPastEndOfBuffer() throws {
        var reader = try RBSPBitReader(rbsp: [0x00])
        #expect(throws: BitstreamError.unexpectedEndOfData(atBit: 8)) {
            _ = try reader.ue()
        }
    }

    /// The range-checking convenience names the field in the error so a log line is diagnosable.
    @Test func expGolombRangeCheckedReadReportsFieldName() throws {
        var reader = try RBSPBitReader(rbsp: rbsp(bits: "0001111"))
        #expect(throws: BitstreamError.valueOutOfRange(field: "test_field", value: 14)) {
            _ = try reader.ue("test_field", max: 13)
        }
    }

    // MARK: - Construction and bounds

    @Test func rbspBitReaderRejectsEmptyBuffer() {
        #expect(throws: BitstreamError.emptyNALUnit) {
            _ = try RBSPBitReader(rbsp: [])
        }
    }

    @Test func rbspBitReaderTracksOffsetAndRemaining() throws {
        var reader = try RBSPBitReader(rbsp: [0b1011_0010, 0x00])
        #expect(reader.bitCount == 16)
        let first = try reader.u(3)
        #expect(first == 0b101)
        #expect(reader.bitOffset == 3)
        #expect(reader.bitsRemaining == 13)
        #expect(reader.isByteAligned == false)
        let peeked = try reader.peek(2)
        #expect(peeked == 0b10)
        #expect(reader.bitOffset == 3)
        reader.alignToByte()
        #expect(reader.bitOffset == 8)
        #expect(reader.isByteAligned)
    }

    @Test func rbspBitReaderReadsWideFieldsWithU64() throws {
        // The 48-bit shape of H.265 `general_constraint_indicator_flags`.
        let bytes: [UInt8] = [0xB0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80]
        var reader = try RBSPBitReader(rbsp: bytes)
        let flags = try reader.u64(48)
        #expect(flags == 0xB000_0000_0000)
    }

    // MARK: - more_rbsp_data()

    /// P1 of docs/spec-bitstream.md §9.3: RBSP `EE 3C 80`, stop bit at index 16, so a reader sitting
    /// at bit 16 sees no more data.
    @Test func rbspBitReaderMoreDataIsFalseAtTheStopBit() throws {
        var reader = try RBSPBitReader(rbsp: [0xEE, 0x3C, 0x80])
        #expect(reader.moreRBSPData())
        try reader.skip(16)
        #expect(reader.moreRBSPData() == false)
    }

    /// P2 of docs/spec-bitstream.md §9.3: RBSP `EE 3C B0`, last set bit at index 19, so three bits
    /// of real syntax remain at bit 16.
    @Test func rbspBitReaderMoreDataIsTrueBeforeTheStopBit() throws {
        var reader = try RBSPBitReader(rbsp: [0xEE, 0x3C, 0xB0])
        try reader.skip(16)
        #expect(reader.moreRBSPData())
    }

    /// An all-zero buffer has no `rbsp_stop_one_bit` at all. Claiming "there is more syntax here"
    /// would be a lie that sends a parser off the end.
    @Test func rbspBitReaderMoreDataIsFalseWithoutAStopBit() throws {
        let reader = try RBSPBitReader(rbsp: [0x00, 0x00, 0x00])
        #expect(reader.moreRBSPData() == false)
    }

    @Test func rbspBitReaderValidatesTrailingBits() throws {
        var good = try RBSPBitReader(rbsp: [0b1010_1000])
        try good.skip(4)
        let goodTrailing = good.checkRBSPTrailingBits()
        #expect(goodTrailing)

        var bad = try RBSPBitReader(rbsp: [0b1010_0100])
        try bad.skip(4)
        let badTrailing = bad.checkRBSPTrailingBits()
        #expect(badTrailing == false)
    }
}
