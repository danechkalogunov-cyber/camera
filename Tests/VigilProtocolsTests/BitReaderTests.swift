//
//  BitReaderTests.swift
//  VigilProtocolsTests
//
//  Behaviour of the MSB-first bit reader from docs/spec-bitstream.md §7: bit order, reads that cross
//  byte boundaries at every start offset, 32- and 64-bit reads spanning five and nine bytes,
//  alignment, and every way a truncated or malformed buffer can end a read.
//  Covers Sources/VigilProtocols/Bytes/BitReader.swift.
//
//  Fixtures are synthesised for the boundary under test. The 12-byte pattern below is shaped like the
//  first bytes of an H.264 SPS so the exhaustive cross-check runs over realistic bit density, but it
//  is hand-written, not a capture from a camera.
//

import Testing

@testable import VigilProtocols

// MARK: - Helpers

/// Runs `body` and returns the `BitReaderError` it threw, or `nil` if it did not throw.
private func caughtBitError<T>(_ body: () throws -> T) -> BitReaderError? {
    do {
        _ = try body()
        return nil
    } catch let error as BitReaderError {
        return error
    } catch {
        return nil
    }
}

/// Deliberately slow, obviously correct reference reader: one bit at a time, most significant first.
/// The exhaustive test compares `BitReader` against this rather than against hand-computed constants.
private func referenceRead(_ bytes: [UInt8], atBit start: Int, width: Int) -> UInt64 {
    var value: UInt64 = 0
    for i in 0..<width {
        let bit = start + i
        let byte = bytes[bit >> 3]
        let shift = UInt8(7 - (bit & 7))
        value = (value << 1) | UInt64((byte >> shift) & 1)
    }
    return value
}

/// Synthesised, SPS-shaped: 0x67 is an H.264 SPS NAL header, 0x64 the High profile IDC.
private let pattern: [UInt8] = [0x67, 0x64, 0x00, 0x28, 0xAC, 0xD9, 0x40, 0x78, 0x02, 0x27, 0xE5, 0x84]

// MARK: - Bit order

@Test func readsMostSignificantBitOfByteZeroFirst() throws {
    var reader = BitReader([0b1010_0000])
    #expect(try reader.u(3) == 0b101)
    #expect(reader.bitOffset == 3)
    #expect(try reader.u(5) == 0)
    #expect(reader.isAtEnd)
}

@Test func flagReadsSingleBitsInOrder() throws {
    var reader = BitReader([0b1011_0010])
    var read: [Bool] = []
    for _ in 0..<8 { read.append(try reader.flag()) }
    #expect(read == [true, false, true, true, false, false, true, false])
    #expect(reader.bitsRemaining == 0)
}

@Test func fullWidthReadsYieldMaximumValues() throws {
    var thirtyTwo = BitReader([UInt8](repeating: 0xFF, count: 4))
    #expect(try thirtyTwo.u(32) == UInt32.max)
    var sixtyFour = BitReader([UInt8](repeating: 0xFF, count: 8))
    #expect(try sixtyFour.u64(64) == UInt64.max)
    var high = BitReader([0x80, 0x00, 0x00, 0x01])
    #expect(try high.u(32) == 0x8000_0001)
}

// MARK: - Byte-boundary crossing

@Test func crossesAByteBoundaryAtEveryStartOffsetZeroToSeven() throws {
    // An 8-bit read starting at each bit position inside the first byte spans two bytes for offsets
    // 1...7. Compared against the reference reader, so the expectations cannot drift.
    for start in 0...7 {
        var reader = BitReader(pattern)
        try reader.skip(start)
        let value = try reader.u(8)
        #expect(UInt64(value) == referenceRead(pattern, atBit: start, width: 8),
                "8-bit read starting at bit \(start)")
        #expect(reader.bitOffset == start + 8)
    }
}

@Test func everyWidthAtEveryOffsetMatchesTheReferenceReader() throws {
    // Exhaustive over widths 0...32 and start offsets 0...23: 792 reads, every one of which crosses
    // a byte boundary in a different phase.
    let totalBits = pattern.count * 8
    for start in 0...23 {
        for width in 0...32 where start + width <= totalBits {
            var reader = BitReader(pattern)
            try reader.skip(start)
            let value = try reader.u(width)
            let expected = width == 0 ? 0 : referenceRead(pattern, atBit: start, width: width)
            #expect(UInt64(value) == expected, "u(\(width)) at bit \(start)")
            #expect(reader.bitOffset == start + width)
        }
    }
}

@Test func aThirtyTwoBitReadSpansFiveBytes() throws {
    // Starting mid-byte, 32 bits touch bytes 0...4.
    var reader = BitReader(pattern)
    try reader.skip(4)
    #expect(reader.bytePosition == 0)
    let value = try reader.u(32)
    #expect(UInt64(value) == referenceRead(pattern, atBit: 4, width: 32))
    #expect(value == 0x7640_028A)             // 0x67 0x64 0x00 0x28 0xAC shifted left by 4 bits
    #expect(reader.bitOffset == 36)
    #expect(reader.bytePosition == 4, "the cursor sits inside the fifth byte")
    #expect(!reader.isByteAligned)
}

@Test func aSixtyFourBitReadSpansNineBytes() throws {
    var reader = BitReader(pattern)
    try reader.skip(4)
    let value = try reader.u64(64)
    #expect(value == referenceRead(pattern, atBit: 4, width: 64))
    #expect(value == 0x7640_028A_CD94_0780)   // bytes 0...8 of `pattern`, shifted left by 4 bits
    #expect(reader.bitOffset == 68)
    #expect(reader.bytePosition == 8)
}

@Test func u64ReadsTheFortyEightBitConstraintFlagsField() throws {
    // H.265 general_constraint_indicator_flags is 48 bits, the reason `u64` exists at all
    // (docs/spec-bitstream.md §7, §11).
    var reader = BitReader([0x0F, 0xF0, 0x00, 0x00, 0x00, 0x00, 0xAA])
    #expect(try reader.u64(48) == 0x0FF0_0000_0000)
    #expect(reader.bitOffset == 48)
    #expect(try reader.u(8) == 0xAA)
}

@Test func u64BelowThirtyThreeBitsAgreesWithU() throws {
    var viaU64 = BitReader(pattern)
    var viaU = BitReader(pattern)
    try viaU64.skip(3)
    try viaU.skip(3)
    #expect(try viaU64.u64(32) == UInt64(try viaU.u(32)))
    #expect(viaU64.bitOffset == viaU.bitOffset)
}

// MARK: - Alignment

@Test func alignToByteIsANoOpWhenAlreadyAligned() throws {
    var reader = BitReader(pattern)
    reader.alignToByte()
    #expect(reader.bitOffset == 0)
    try reader.skip(16)
    #expect(reader.isByteAligned)
    reader.alignToByte()
    #expect(reader.bitOffset == 16, "aligning an aligned reader must not skip a whole byte")
}

@Test func alignToByteDiscardsTheRestOfAPartialByte() throws {
    for start in 1...7 {
        var reader = BitReader(pattern)
        try reader.skip(start)
        #expect(!reader.isByteAligned)
        reader.alignToByte()
        #expect(reader.bitOffset == 8, "from bit \(start)")
        #expect(reader.isByteAligned)
        #expect(try reader.u(8) == UInt32(pattern[1]))
    }
}

@Test func alignToByteAtTheEndOfTheBufferCannotOverrun() throws {
    var reader = BitReader([0xFF])
    try reader.skip(3)
    reader.alignToByte()
    #expect(reader.bitOffset == 8)
    #expect(reader.isAtEnd)
    reader.alignToByte()
    #expect(reader.bitOffset == 8)
    #expect(reader.bitsRemaining == 0)
}

// MARK: - Position accounting

@Test func bitPositionIsExactAfterAMixedSequenceOfReads() throws {
    var reader = BitReader(pattern)             // 96 bits
    #expect(reader.bitsRemaining == 96)
    #expect(reader.bitOffset == 0)
    #expect(reader.isByteAligned)

    _ = try reader.flag()                       // 1
    #expect(reader.bitOffset == 1)
    _ = try reader.u(5)                         // 6
    #expect(reader.bitOffset == 6)
    try reader.skip(3)                          // 9
    #expect(reader.bitOffset == 9)
    #expect(reader.bytePosition == 1)
    reader.alignToByte()                        // 16
    #expect(reader.bitOffset == 16)
    _ = try reader.u(17)                        // 33
    #expect(reader.bitOffset == 33)
    _ = try reader.peek(20)                     // unchanged
    #expect(reader.bitOffset == 33)
    _ = try reader.u64(40)                      // 73
    #expect(reader.bitOffset == 73)
    #expect(reader.bytePosition == 9)
    #expect(reader.bitsRemaining == 23)
    #expect(!reader.isAtEnd)
    try reader.skip(23)                         // 96
    #expect(reader.isAtEnd)
    #expect(reader.bitsRemaining == 0)
    #expect(reader.bytePosition == pattern.count)
}

// MARK: - Truncation and malformed widths

@Test func readingPastTheEndThrowsAndLeavesThePositionUnchanged() throws {
    var reader = BitReader([0xFF, 0xFF])        // 16 bits
    try reader.skip(12)
    #expect(caughtBitError { try reader.u(5) } == .unexpectedEndOfData(atBit: 12))
    #expect(reader.bitOffset == 12, "a failed read must not consume anything")
    #expect(caughtBitError { try reader.u(4) } == nil)
    #expect(reader.isAtEnd)
    #expect(caughtBitError { try reader.u(1) } == .unexpectedEndOfData(atBit: 16))
    #expect(caughtBitError { try reader.flag() } == .unexpectedEndOfData(atBit: 16))
}

@Test func aU64ReadThatRunsOffTheEndDoesNotConsumeItsLeadingBits() {
    // 40 bits available, 64 requested. The naive "read high, then read low" implementation consumes
    // the high half before failing; the position must be untouched so the error names the real start.
    var reader = BitReader([UInt8](repeating: 0xFF, count: 5))
    #expect(caughtBitError { try reader.u64(64) } == .unexpectedEndOfData(atBit: 0))
    #expect(reader.bitOffset == 0)
    #expect(caughtBitError { try reader.skip(4) } == nil)
    #expect(caughtBitError { try reader.u64(40) } == .unexpectedEndOfData(atBit: 4))
    #expect(reader.bitOffset == 4)
}

@Test func zeroWidthReadsReturnZeroWithoutAdvancing() throws {
    var reader = BitReader([0xFF])
    #expect(try reader.u(0) == 0)
    #expect(try reader.u64(0) == 0)
    #expect(try reader.peek(0) == 0)
    #expect(reader.bitOffset == 0)
    // Legal even with nothing left, which is what a syntax loop with a computed width needs.
    try reader.skip(8)
    #expect(try reader.u(0) == 0)
    #expect(try reader.u64(0) == 0)
}

@Test func widthsOutsideTheSupportedRangeThrowRatherThanTrapping() {
    var reader = BitReader([UInt8](repeating: 0xFF, count: 16))
    #expect(caughtBitError { try reader.u(33) } == .unsupportedWidth(33))
    #expect(caughtBitError { try reader.u(-1) } == .unsupportedWidth(-1))
    #expect(caughtBitError { try reader.u64(65) } == .unsupportedWidth(65))
    #expect(caughtBitError { try reader.u64(-8) } == .unsupportedWidth(-8))
    #expect(caughtBitError { try reader.peek(33) } == .unsupportedWidth(33))
    #expect(reader.bitOffset == 0)
}

@Test func negativeSkipThrows() {
    var reader = BitReader([0xFF, 0xFF])
    #expect(caughtBitError { try reader.skip(-1) } == .negativeSkip(-1))
    #expect(reader.bitOffset == 0)
}

@Test func skipToTheExactEndSucceedsAndOneBitFurtherThrows() throws {
    var reader = BitReader([0xAB, 0xCD])
    try reader.skip(16)
    #expect(reader.isAtEnd)
    #expect(reader.bitOffset == 16)
    #expect(caughtBitError { try reader.skip(1) } == .unexpectedEndOfData(atBit: 16))
    #expect(reader.bitOffset == 16)
}

@Test func anEmptyBufferIsReadableButYieldsNothing() {
    var reader = BitReader([])
    #expect(reader.bitsRemaining == 0)
    #expect(reader.bitOffset == 0)
    #expect(reader.bytePosition == 0)
    #expect(reader.isByteAligned)
    #expect(reader.isAtEnd)
    #expect(caughtBitError { try reader.u(1) } == .unexpectedEndOfData(atBit: 0))
    #expect(caughtBitError { try reader.u64(64) } == .unexpectedEndOfData(atBit: 0))
    #expect(caughtBitError { try reader.peek(1) } == .unexpectedEndOfData(atBit: 0))
    #expect(caughtBitError { try reader.skip(1) } == .unexpectedEndOfData(atBit: 0))
    reader.alignToByte()
    #expect(reader.bitOffset == 0)
}

// MARK: - Lookahead

@Test func peekDoesNotAdvanceAndAgreesWithTheFollowingRead() throws {
    var reader = BitReader(pattern)
    try reader.skip(5)
    let peeked = try reader.peek(19)
    #expect(reader.bitOffset == 5)
    #expect(try reader.peek(19) == peeked, "peek is idempotent")
    #expect(try reader.u(19) == peeked)
    #expect(reader.bitOffset == 24)
}

@Test func peekPastTheEndThrowsWithoutMovingTheCursor() throws {
    var reader = BitReader([0x0F])
    try reader.skip(6)
    #expect(caughtBitError { try reader.peek(3) } == .unexpectedEndOfData(atBit: 6))
    #expect(reader.bitOffset == 6)
    #expect(try reader.peek(2) == 0b11)
    #expect(reader.bitOffset == 6)
}

// MARK: - Conformances

@Test func bitReaderIsSendable() {
    let sendable: any Sendable = BitReader([0x01])
    #expect(sendable is BitReader)
}

@Test func bitErrorDescriptionsCarryDiagnosableContext() {
    #expect(BitReaderError.unexpectedEndOfData(atBit: 41).description
        == "BitReader ran past the end of the buffer at bit 41")
    #expect(BitReaderError.negativeSkip(-2).description == "BitReader negative skip -2")
    #expect(BitReaderError.unsupportedWidth(33).description == "BitReader unsupported width 33")
}
