//
//  ByteReaderTests.swift
//  VigilProtocolsTests
//
//  Behaviour of the bounds-checked byte cursor, with the emphasis on hostile input: truncation at
//  every width, one-byte-past-the-end reads, zero-length reads, negative lengths and delimiters that
//  are only partially present. Covers Sources/VigilProtocols/Bytes/ByteReader.swift.
//
//  All fixtures here are synthesised by hand for the boundary they exercise; none is a capture from
//  real hardware.
//

import Foundation
import Testing

@testable import VigilProtocols

// MARK: - Helpers

/// Runs `body` and returns the `ByteReaderError` it threw, or `nil` if it did not throw.
///
/// Written as a plain helper rather than `#expect(throws:)` so the exact associated values can be
/// compared and the reader's state can be inspected afterwards.
private func caughtReaderError<T>(_ body: () throws -> T) -> ByteReaderError? {
    do {
        _ = try body()
        return nil
    } catch let error as ByteReaderError {
        return error
    } catch {
        return nil
    }
}

private let crlf: [UInt8] = [0x0D, 0x0A]

// MARK: - Big-endian integers

@Test func readsSuccessiveBytesInOrder() throws {
    var reader = ByteReader(Data([0x00, 0x7F, 0x80, 0xFF]))
    #expect(try reader.u8() == 0x00)
    #expect(try reader.u8() == 0x7F)
    #expect(try reader.u8() == 0x80)
    #expect(try reader.u8() == 0xFF)
    #expect(reader.isAtEnd)
}

@Test func bigEndianWidthsReadMaximumValues() throws {
    var reader = ByteReader([UInt8](repeating: 0xFF, count: 18))
    #expect(try reader.u8() == UInt8.max)
    #expect(try reader.u16BE() == UInt16.max)
    #expect(try reader.u24BE() == 0x00FF_FFFF)      // zero-extended, NOT 0xFFFF_FFFF
    #expect(try reader.u32BE() == UInt32.max)
    #expect(try reader.u64BE() == UInt64.max)
    #expect(reader.offset == 18)
    #expect(reader.remaining == 0)
}

@Test func bigEndianWidthsDoNotSignExtendAHighBit() throws {
    // Every value here has bit 7 of its first byte set: the classic place a reader built on Int8 or
    // on `<<` over a too-narrow type gets sign extension wrong.
    var reader = ByteReader(Data([0x80, 0x01, 0x80, 0x00, 0x01, 0x80, 0x00, 0x00, 0x01]))
    #expect(try reader.u16BE() == 0x8001)
    #expect(try reader.u24BE() == 0x0080_0001)
    #expect(try reader.u32BE() == 0x8000_0001)
    #expect(reader.isAtEnd)

    var wide = ByteReader(Data([0x80] + [UInt8](repeating: 0x00, count: 6) + [0x01]))
    #expect(try wide.u64BE() == 0x8000_0000_0000_0001)
}

@Test func bigEndianWidthsPlaceTheFirstByteHighest() throws {
    var reader = ByteReader(Data([0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0]))
    #expect(try reader.u16BE() == 0x1234)
    reader = ByteReader(Data([0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0]))
    #expect(try reader.u24BE() == 0x0012_3456)
    reader = ByteReader(Data([0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0]))
    #expect(try reader.u32BE() == 0x1234_5678)
    reader = ByteReader(Data([0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0]))
    #expect(try reader.u64BE() == 0x1234_5678_9ABC_DEF0)
}

// MARK: - Little-endian integers

@Test func littleEndianWidthsPlaceTheFirstByteLowest() throws {
    var reader = ByteReader(Data([0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0]))
    #expect(try reader.u16LE() == 0x3412)
    reader = ByteReader(Data([0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0]))
    #expect(try reader.u24LE() == 0x0056_3412)
    reader = ByteReader(Data([0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0]))
    #expect(try reader.u32LE() == 0x7856_3412)
    reader = ByteReader(Data([0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0]))
    #expect(try reader.u64LE() == 0xF0DE_BC9A_7856_3412)
}

@Test func littleEndianWidthsReadMaximumValues() throws {
    var reader = ByteReader([UInt8](repeating: 0xFF, count: 17))
    #expect(try reader.u16LE() == UInt16.max)
    #expect(try reader.u24LE() == 0x00FF_FFFF)
    #expect(try reader.u32LE() == UInt32.max)
    #expect(try reader.u64LE() == UInt64.max)
    #expect(reader.offset == 17)
}

@Test func theTwoEndiannessesAreByteReversalsOfEachOther() throws {
    let bytes: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04]
    var big = ByteReader(bytes)
    var little = ByteReader(bytes.reversed().map { $0 })
    #expect(try big.u64BE() == (try little.u64LE()))
}

// MARK: - Truncation

@Test func readingOneByteBeyondTheEndThrowsAtEveryWidth() {
    // One byte short for each width; the error must name the shortfall, and the cursor must not move.
    func check(_ available: Int, _ needed: Int, _ read: (inout ByteReader<[UInt8]>) throws -> Void) {
        var reader = ByteReader([UInt8](repeating: 0xAA, count: available))
        let error = caughtReaderError { try read(&reader) }
        #expect(error == .outOfBounds(needed: needed, remaining: available, offset: 0))
        #expect(reader.offset == 0, "a failed read must not consume anything")
    }
    check(0, 1) { _ = try $0.u8() }
    check(1, 2) { _ = try $0.u16BE() }
    check(2, 3) { _ = try $0.u24BE() }
    check(3, 4) { _ = try $0.u32BE() }
    check(7, 8) { _ = try $0.u64BE() }
    check(1, 2) { _ = try $0.u16LE() }
    check(2, 3) { _ = try $0.u24LE() }
    check(3, 4) { _ = try $0.u32LE() }
    check(7, 8) { _ = try $0.u64LE() }
    check(4, 5) { _ = try $0.read(5) }
}

@Test func readsThatRunExactlyToTheEndSucceed() throws {
    var reader = ByteReader(Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]))
    #expect(try reader.u32BE() == 0x0102_0304)
    #expect(try reader.u24BE() == 0x0005_0607)
    #expect(reader.isAtEnd)
    #expect(reader.remaining == 0)
    // And the very next byte is not there.
    #expect(caughtReaderError { try reader.u8() } == .outOfBounds(needed: 1, remaining: 0, offset: 7))
}

@Test func truncationPartwayThroughAStreamReportsTheRunningOffset() {
    var reader = ByteReader([0x01, 0x02, 0x03, 0x04, 0x05])
    #expect(caughtReaderError { try reader.u32BE() } == nil)
    #expect(reader.offset == 4)
    #expect(caughtReaderError { try reader.u32BE() } == .outOfBounds(needed: 4, remaining: 1, offset: 4))
    #expect(reader.offset == 4)
}

// MARK: - Degenerate lengths and buffers

@Test func zeroLengthReadsSucceedAndDoNotMoveTheCursor() throws {
    var reader = ByteReader(Data([0xFF, 0xFE]))
    #expect(try reader.read(0).isEmpty)
    #expect(try reader.peek(0).isEmpty)
    try reader.skip(0)
    #expect(reader.offset == 0)
    #expect(reader.remaining == 2)
}

@Test func zeroLengthReadsSucceedOnAnEmptyBuffer() throws {
    var reader = ByteReader(Data())
    #expect(reader.count == 0)
    #expect(reader.remaining == 0)
    #expect(reader.isAtEnd)
    #expect(try reader.read(0).isEmpty)
    #expect(try reader.peek(0).isEmpty)
    try reader.skip(0)
    #expect(reader.readRemaining().isEmpty)
    #expect(caughtReaderError { try reader.u8() } == .outOfBounds(needed: 1, remaining: 0, offset: 0))
}

@Test func skipBeyondTheEndThrowsAndDoesNotMoveTheCursor() {
    var reader = ByteReader([0x01, 0x02, 0x03])
    #expect(caughtReaderError { try reader.skip(4) } == .outOfBounds(needed: 4, remaining: 3, offset: 0))
    #expect(reader.offset == 0)
    #expect(caughtReaderError { try reader.skip(3) } == nil)
    #expect(reader.isAtEnd)
    #expect(caughtReaderError { try reader.skip(1) } == .outOfBounds(needed: 1, remaining: 0, offset: 3))
}

@Test func negativeLengthsThrowRatherThanTrapping() {
    var reader = ByteReader([0x01, 0x02, 0x03])
    #expect(caughtReaderError { try reader.skip(-1) } == .negativeLength(-1))
    #expect(caughtReaderError { try reader.read(-4) } == .negativeLength(-4))
    #expect(caughtReaderError { try reader.peek(-1) } == .negativeLength(-1))
    #expect(caughtReaderError { try reader.peekU8(-2) } == .negativeLength(-2))
    #expect(reader.offset == 0)
}

// MARK: - Lookahead

@Test func peekDoesNotAdvanceTheCursor() throws {
    var reader = ByteReader(Data([0x24, 0x00, 0x05, 0xAA]))
    #expect(Array(try reader.peek(3)) == [0x24, 0x00, 0x05])
    #expect(reader.offset == 0)
    #expect(try reader.peekU8() == 0x24)
    #expect(try reader.peekU8(3) == 0xAA)
    #expect(reader.offset == 0)
    // The value-type copy idiom for wider lookahead leaves the original untouched too.
    var probe = reader
    #expect(try probe.u32BE() == 0x2400_05AA)
    #expect(reader.offset == 0)
    #expect(try reader.u8() == 0x24)
}

@Test func peekPastTheEndThrows() {
    let reader = ByteReader([0x01, 0x02])
    #expect(caughtReaderError { try reader.peek(3) } == .outOfBounds(needed: 3, remaining: 2, offset: 0))
    #expect(caughtReaderError { try reader.peekU8(2) } == .outOfBounds(needed: 3, remaining: 2, offset: 0))
    #expect(caughtReaderError { try reader.peekU8(1) } == nil)
    #expect(reader.offset == 0)
}

@Test func readRemainingConsumesTheRestExactlyOnce() {
    var reader = ByteReader(Data([0x01, 0x02, 0x03]))
    #expect(caughtReaderError { try reader.skip(1) } == nil)
    #expect(Array(reader.readRemaining()) == [0x02, 0x03])
    #expect(reader.isAtEnd)
    #expect(reader.readRemaining().isEmpty)
}

// MARK: - Delimiter search

@Test func singleByteDelimiterIsFoundAtTheStartAtTheEndAndNotAtAll() {
    let atStart = ByteReader<[UInt8]>([0x0A, 0x41, 0x42])
    #expect(atStart.firstOffset(of: 0x0A) == 0)

    let atEnd = ByteReader<[UInt8]>([0x41, 0x42, 0x0A])
    #expect(atEnd.firstOffset(of: 0x0A) == 2)

    let absent = ByteReader<[UInt8]>([0x41, 0x42, 0x43])
    #expect(absent.firstOffset(of: 0x0A) == nil)

    let empty = ByteReader<[UInt8]>([])
    #expect(empty.firstOffset(of: 0x0A) == nil)
}

@Test func singleByteDelimiterSearchIsRelativeToTheCursor() throws {
    var reader = ByteReader<[UInt8]>([0x0A, 0x41, 0x0A, 0x42])
    #expect(reader.firstOffset(of: 0x0A) == 0)
    try reader.skip(1)
    #expect(reader.firstOffset(of: 0x0A) == 1)
    try reader.skip(2)
    #expect(reader.firstOffset(of: 0x0A) == nil)
}

@Test func multiByteDelimiterIsFoundAtTheStartAtTheEndAndNotAtAll() {
    let atStart = ByteReader<[UInt8]>([0x0D, 0x0A, 0x41])
    #expect(atStart.firstOffset(of: crlf) == 0)

    let atEnd = ByteReader<[UInt8]>([0x41, 0x42, 0x0D, 0x0A])
    #expect(atEnd.firstOffset(of: crlf) == 2)

    let absent = ByteReader<[UInt8]>([0x41, 0x0A, 0x0D, 0x42])   // LF CR, wrong order
    #expect(absent.firstOffset(of: crlf) == nil)

    let tooShort = ByteReader<[UInt8]>([0x0D])
    #expect(tooShort.firstOffset(of: crlf) == nil)
}

@Test func aDelimiterOnlyPartiallyPresentAtTheEndIsNotAMatch() {
    // The incremental decoder case: "...abc\r" with the LF still in flight. Reporting a match here
    // would frame a line that has not arrived, and reporting the CR as data would corrupt it.
    let partial = ByteReader<[UInt8]>([0x61, 0x62, 0x63, 0x0D])
    #expect(partial.firstOffset(of: crlf) == nil)

    // A longer boundary, matched to its last byte but one.
    let boundary: [UInt8] = Array("--vigil-boundary".utf8)
    let cut = ByteReader<[UInt8]>(Array("body--vigil-boundar".utf8))
    #expect(cut.firstOffset(of: boundary) == nil)
    let whole = ByteReader<[UInt8]>(Array("body--vigil-boundary".utf8))
    #expect(whole.firstOffset(of: boundary) == 4)
}

@Test func emptyPatternMatchesAtTheCursor() {
    let reader = ByteReader<[UInt8]>([0x41, 0x42])
    #expect(reader.firstOffset(of: [UInt8]()) == 0)
}

@Test func repeatedPrefixDoesNotConfuseTheScan() {
    // "aab" searched for "ab": a naive scan that fails to restart correctly returns nil here.
    let reader = ByteReader<[UInt8]>(Array("aaab".utf8))
    #expect(reader.firstOffset(of: Array("ab".utf8)) == 2)
}

// MARK: - read(until:)

@Test func readUntilConsumesTheDelimiterByDefault() throws {
    var reader = ByteReader<[UInt8]>(Array("OPTIONS * RTSP/1.0\r\nCSeq: 1\r\n\r\n".utf8))
    let startLine = try reader.read(until: crlf)
    #expect(String(decoding: startLine, as: UTF8.self) == "OPTIONS * RTSP/1.0")
    let header = try reader.read(until: crlf)
    #expect(String(decoding: header, as: UTF8.self) == "CSeq: 1")
    let terminator = try reader.read(until: crlf)
    #expect(terminator.isEmpty, "the blank line that ends the header block")
    #expect(reader.isAtEnd)
}

@Test func readUntilCanLeaveTheDelimiterInPlace() throws {
    var reader = ByteReader<[UInt8]>(Array("name: value\r\n".utf8))
    let line = try reader.read(until: crlf, consumingDelimiter: false)
    #expect(String(decoding: line, as: UTF8.self) == "name: value")
    #expect(reader.remaining == 2)
    #expect(Array(try reader.peek(2)) == crlf)

    var single = ByteReader<[UInt8]>([0x41, 0x0A, 0x42])
    #expect(Array(try single.read(until: 0x0A, consumingDelimiter: false)) == [0x41])
    #expect(try single.u8() == 0x0A)
}

@Test func readUntilAMissingDelimiterThrowsAndLeavesTheCursorUntouched() throws {
    var reader = ByteReader<[UInt8]>(Array("partial line".utf8))
    try reader.skip(3)
    #expect(caughtReaderError { try reader.read(until: crlf) } == .delimiterNotFound(offset: 3))
    #expect(caughtReaderError { try reader.read(until: 0x0A) } == .delimiterNotFound(offset: 3))
    #expect(reader.offset == 3, "the caller must be able to wait for more bytes and retry")
}

@Test func readUntilAnImmediateDelimiterYieldsAnEmptySlice() throws {
    var reader = ByteReader<[UInt8]>([0x0D, 0x0A, 0x41])
    #expect(try reader.read(until: crlf).isEmpty)
    #expect(reader.offset == 2)
    #expect(try reader.u8() == 0x41)
}

// MARK: - Buffer kinds and index spaces

@Test func worksOverADataSliceWhoseStartIndexIsNotZero() throws {
    // Data slices keep the parent's index space (`sub.startIndex == 5`). A reader that confuses that
    // with 0 reads the wrong bytes or traps; offsets it reports must still start at 0.
    let parent = Data(0..<20)
    let slice = parent[5..<12]
    #expect(slice.startIndex == 5)
    var reader = ByteReader(slice)
    #expect(reader.count == 7)
    #expect(try reader.u8() == 5)
    #expect(try reader.u16BE() == 0x0607)
    #expect(reader.offset == 3)
    #expect(Array(try reader.read(4)) == [8, 9, 10, 11])
    #expect(reader.isAtEnd)
    #expect(caughtReaderError { try reader.u8() } == .outOfBounds(needed: 1, remaining: 0, offset: 7))
}

@Test func worksOverAnArraySliceWhoseStartIndexIsNotZero() throws {
    let parent: [UInt8] = [0, 1, 2, 3, 4, 5, 6, 7]
    var reader = ByteReader(parent[3...])
    #expect(reader.count == 5)
    #expect(try reader.u8() == 3)
    #expect(reader.firstOffset(of: 7) == 3)
    #expect(Array(try reader.read(4)) == [4, 5, 6, 7])
}

@Test func worksOverARawBufferPointer() throws {
    let bytes: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
    try bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) throws in
        var reader = ByteReader(raw)
        let first = try reader.u16BE()
        let rest = Array(try reader.read(2))
        #expect(first == 0xDEAD)
        #expect(rest == [0xBE, 0xEF])
        #expect(reader.isAtEnd)
    }
}

// MARK: - Bookkeeping and conformances

@Test func offsetAndRemainingTrackAMixedSequenceOfReads() throws {
    var reader = ByteReader(Data(repeating: 0x5A, count: 32))
    #expect(reader.count == 32)
    _ = try reader.u8()
    #expect(reader.offset == 1)
    _ = try reader.u24BE()
    #expect(reader.offset == 4)
    try reader.skip(6)
    #expect(reader.offset == 10)
    _ = try reader.read(5)
    #expect(reader.offset == 15)
    _ = try reader.peek(4)
    #expect(reader.offset == 15, "peek must not count")
    _ = try reader.u64LE()
    #expect(reader.offset == 23)
    #expect(reader.remaining == 9)
    #expect(!reader.isAtEnd)
    _ = reader.readRemaining()
    #expect(reader.offset == 32)
    #expect(reader.isAtEnd)
}

@Test func readerIsSendableForTheOrdinaryBufferTypes() {
    // Compile-time proof: these coercions do not type-check unless the conformance exists.
    let fromData: any Sendable = ByteReader(Data([0x01]))
    let fromArray: any Sendable = ByteReader([UInt8]([0x01]))
    let fromSlice: any Sendable = ByteReader([UInt8]([0x01, 0x02])[1...])
    #expect(fromData is ByteReader<Data>)
    #expect(fromArray is ByteReader<[UInt8]>)
    #expect(fromSlice is ByteReader<ArraySlice<UInt8>>)
}

@Test func errorDescriptionsCarryDiagnosableContext() {
    #expect(ByteReaderError.outOfBounds(needed: 4, remaining: 1, offset: 12).description
        == "ByteReader out of bounds: needed 4 B, 1 B remaining at offset 12")
    #expect(ByteReaderError.negativeLength(-3).description == "ByteReader negative length -3")
    #expect(ByteReaderError.delimiterNotFound(offset: 7).description
        == "ByteReader delimiter not found from offset 7")
}
