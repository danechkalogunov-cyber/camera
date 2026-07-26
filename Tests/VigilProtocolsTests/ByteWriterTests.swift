//
//  ByteWriterTests.swift
//  VigilProtocolsTests
//
//  Byte order of every fixed-width append, round-trips of every type back through `ByteReader`, and
//  the degenerate cases (empty writer, zero-capacity reserve, over-wide value into a 24-bit field).
//  Covers Sources/VigilProtocols/Bytes/ByteWriter.swift.
//
//  Fixtures are synthesised; the RTSP request at the end is written from the grammar in
//  docs/spec-rtsp.md §3, not captured from a device.
//

import Foundation
import Testing

@testable import VigilProtocols

// MARK: - Byte order

@Test func bigEndianAppendsPutTheMostSignificantByteFirst() {
    var writer = ByteWriter()
    writer.appendU16BE(0x1234)
    writer.appendU24BE(0x0056_789A)
    writer.appendU32BE(0xBCDE_F001)
    writer.appendU64BE(0x0203_0405_0607_0809)
    #expect(writer.bytes == [
        0x12, 0x34,
        0x56, 0x78, 0x9A,
        0xBC, 0xDE, 0xF0, 0x01,
        0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09,
    ])
    #expect(writer.count == 17)
}

@Test func littleEndianAppendsPutTheLeastSignificantByteFirst() {
    var writer = ByteWriter()
    writer.appendU16LE(0x1234)
    writer.appendU24LE(0x0056_789A)
    writer.appendU32LE(0xBCDE_F001)
    writer.appendU64LE(0x0203_0405_0607_0809)
    #expect(writer.bytes == [
        0x34, 0x12,
        0x9A, 0x78, 0x56,
        0x01, 0xF0, 0xDE, 0xBC,
        0x09, 0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02,
    ])
}

@Test func twentyFourBitAppendsWriteOnlyTheLowThreeBytes() {
    var writer = ByteWriter()
    writer.appendU24BE(0xAABB_CCDD)
    writer.appendU24LE(0xAABB_CCDD)
    #expect(writer.bytes == [0xBB, 0xCC, 0xDD, 0xDD, 0xCC, 0xBB])
}

@Test func maximumValuesAppendAllOnes() {
    var writer = ByteWriter()
    writer.append(UInt8.max)
    writer.appendU16BE(UInt16.max)
    writer.appendU24BE(0x00FF_FFFF)
    writer.appendU32BE(UInt32.max)
    writer.appendU64BE(UInt64.max)
    #expect(writer.count == 18)
    #expect(writer.bytes.allSatisfy { $0 == 0xFF })
}

// MARK: - Round-trips through ByteReader

@Test func roundTripsEveryBigEndianWidthThroughByteReader() throws {
    var writer = ByteWriter(capacity: 32)
    writer.append(0x81)
    writer.appendU16BE(0x8001)
    writer.appendU24BE(0x00FF_FFFF)
    writer.appendU32BE(0x8000_0001)
    writer.appendU64BE(0xFFFF_FFFF_FFFF_FFFF)

    var reader = ByteReader(writer.bytes)
    #expect(try reader.u8() == 0x81)
    #expect(try reader.u16BE() == 0x8001)
    #expect(try reader.u24BE() == 0x00FF_FFFF)
    #expect(try reader.u32BE() == 0x8000_0001)
    #expect(try reader.u64BE() == UInt64.max)
    #expect(reader.isAtEnd)
}

@Test func roundTripsEveryLittleEndianWidthThroughByteReader() throws {
    var writer = ByteWriter()
    writer.appendU16LE(0x8001)
    writer.appendU24LE(0x0080_0001)
    writer.appendU32LE(0x8000_0001)
    writer.appendU64LE(0x8000_0000_0000_0001)

    var reader = ByteReader(writer.data)
    #expect(try reader.u16LE() == 0x8001)
    #expect(try reader.u24LE() == 0x0080_0001)
    #expect(try reader.u32LE() == 0x8000_0001)
    #expect(try reader.u64LE() == 0x8000_0000_0000_0001)
    #expect(reader.isAtEnd)
}

@Test func roundTripsBytesAndSlicesThroughByteReader() throws {
    let payload: [UInt8] = [0x00, 0x7F, 0x80, 0xFF, 0x0D, 0x0A]
    var writer = ByteWriter()
    writer.appendU16BE(UInt16(payload.count))
    writer.append(contentsOf: payload)
    writer.append(contentsOf: Data([0xC0, 0xDE]))

    var reader = ByteReader(writer.bytes)
    let length = Int(try reader.u16BE())
    #expect(length == 6)
    #expect(Array(try reader.read(length)) == payload)
    #expect(Array(reader.readRemaining()) == [0xC0, 0xDE])
}

@Test func roundTripsUTF8IncludingNonASCII() throws {
    // Cyrillic and an accented Latin letter: the ISAPI XML and User-Agent cases.
    let text = "Камера é 1"
    var writer = ByteWriter()
    writer.appendUTF8(text)
    #expect(writer.count == text.utf8.count)
    #expect(writer.count > text.count, "non-ASCII must occupy more than one byte per character")

    var reader = ByteReader(writer.bytes)
    let decoded = String(decoding: reader.readRemaining(), as: UTF8.self)
    #expect(decoded == text)
}

@Test func appendsASCIIByteForByte() {
    var writer = ByteWriter()
    writer.appendUTF8("OPTIONS")
    #expect(writer.bytes == [0x4F, 0x50, 0x54, 0x49, 0x4F, 0x4E, 0x53])
}

@Test func appendCRLFWritesExactlyTwoBytes() {
    var writer = ByteWriter()
    writer.appendCRLF()
    #expect(writer.bytes == [0x0D, 0x0A])
}

// MARK: - State

@Test func aFreshWriterIsEmpty() {
    let writer = ByteWriter()
    #expect(writer.isEmpty)
    #expect(writer.count == 0)
    #expect(writer.bytes.isEmpty)
    #expect(writer.data.isEmpty)
}

@Test func reserveCapacityDoesNotChangeTheContent() {
    var writer = ByteWriter(capacity: 0)          // zero and negative hints are ignored, not fatal
    writer.appendU16BE(0xBEEF)
    writer.reserveCapacity(4096)
    writer.reserveCapacity(-1)
    #expect(writer.bytes == [0xBE, 0xEF])
    var negative = ByteWriter(capacity: -8)
    negative.append(0x01)
    #expect(negative.bytes == [0x01])
}

@Test func removeAllDiscardsTheContentAndTheWriterIsReusable() {
    var writer = ByteWriter(capacity: 64)
    writer.appendU32BE(0xDEAD_BEEF)
    writer.removeAll()
    #expect(writer.isEmpty)
    #expect(writer.data.isEmpty)
    writer.appendU16BE(0x0102)
    #expect(writer.bytes == [0x01, 0x02])
}

@Test func dataAndBytesAgree() {
    var writer = ByteWriter()
    writer.appendU64BE(0x0011_2233_4455_6677)
    #expect(writer.data == Data(writer.bytes))
    #expect(writer.data.count == writer.count)
}

@Test func writerIsSendable() {
    let sendable: any Sendable = ByteWriter()
    #expect(sendable is ByteWriter)
}

// MARK: - Realistic uses

@Test func buildsAnRTSPRequestThatReadsBackLineByLine() throws {
    // docs/spec-rtsp.md §3: request line, CRLF-terminated headers, blank line, no body.
    var writer = ByteWriter(capacity: 256)
    writer.appendUTF8("DESCRIBE rtsp://192.0.2.10:554/Streaming/Channels/101 RTSP/1.0")
    writer.appendCRLF()
    writer.appendUTF8("CSeq: 2")
    writer.appendCRLF()
    writer.appendUTF8("Accept: application/sdp")
    writer.appendCRLF()
    writer.appendCRLF()

    let crlf: [UInt8] = [0x0D, 0x0A]
    var reader = ByteReader(writer.data)
    #expect(String(decoding: try reader.read(until: crlf), as: UTF8.self)
        == "DESCRIBE rtsp://192.0.2.10:554/Streaming/Channels/101 RTSP/1.0")
    #expect(String(decoding: try reader.read(until: crlf), as: UTF8.self) == "CSeq: 2")
    #expect(String(decoding: try reader.read(until: crlf), as: UTF8.self) == "Accept: application/sdp")
    #expect(try reader.read(until: crlf).isEmpty, "the blank line terminating the header block")
    #expect(reader.isAtEnd)
}

@Test func buildsAnInterleavedFrameHeaderThatReadsBack() throws {
    // docs/spec-rtsp.md §5: '$', 8-bit channel, 16-bit big-endian payload length.
    let payload = [UInt8](repeating: 0x5A, count: 1400)
    var writer = ByteWriter(capacity: 4 + payload.count)
    writer.append(0x24)
    writer.append(0x00)
    writer.appendU16BE(UInt16(payload.count))
    writer.append(contentsOf: payload)

    var reader = ByteReader(writer.bytes)
    #expect(try reader.u8() == 0x24)
    #expect(try reader.u8() == 0x00)
    let length = Int(try reader.u16BE())
    #expect(length == 1400)
    #expect(Array(try reader.read(length)) == payload)
    #expect(reader.isAtEnd)
}
