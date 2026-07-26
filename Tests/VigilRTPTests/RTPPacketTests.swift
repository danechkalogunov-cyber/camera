//
//  RTPPacketTests.swift
//  VigilRTPTests
//
//  RFC 3550 §5.1 header parsing: every legal shape, and every hostile shape that could read out of
//  bounds. Vectors are docs/spec-rtp.md §15.1; the synthesised ones say so.
//  Covers docs/spec-rtp.md §3 and docs/API_CONTRACT.md §4.4.
//

import Foundation
import Testing

import VigilProtocols
@testable import VigilRTP

@Suite struct RTPPacketParsing {

    /// Bytes from a hex string with no separators. Test-local so no production code parses hex.
    static func hex(_ string: String) -> Data {
        var bytes: [UInt8] = []
        var high: UInt8?
        for character in string {
            guard let value = character.hexDigitValue else { continue }
            if let stored = high {
                bytes.append(stored << 4 | UInt8(value))
                high = nil
            } else {
                high = UInt8(value)
            }
        }
        return Data(bytes)
    }

    // MARK: - Legal shapes

    @Test func rtpPacketParsesTheSpecificationHeaderVector() throws {
        // docs/spec-rtp.md §15.1, first vector.
        let packet = try RTPPacket.parse(Self.hex("80 60 12 34 00 0A 5C 90 12 34 56 78 65 88 84 00 12 34"))
        #expect(packet.version == 2)
        #expect(packet.hasPadding == false)
        #expect(packet.hasExtension == false)
        #expect(packet.csrcCount == 0)
        #expect(packet.marker == false)
        #expect(packet.payloadType == 96)
        #expect(packet.sequenceNumber == 0x1234)
        #expect(packet.timestamp == 0x000A_5C90)
        #expect(packet.ssrc == 0x1234_5678)
        #expect(Array(packet.payload) == [0x65, 0x88, 0x84, 0x00, 0x12, 0x34])
        #expect(packet.csrc.isEmpty)
    }

    @Test func rtpPacketStripsPaddingAndKeepsTheWireLength() throws {
        // docs/spec-rtp.md §15.1, padding vector: three padding bytes, payload is `41 9A`.
        let bytes = Self.hex("A0 60 12 35 00 0A 5C 90 12 34 56 78 41 9A 00 00 03")
        let packet = try RTPPacket.parse(bytes)
        #expect(packet.hasPadding)
        #expect(Array(packet.payload) == [0x41, 0x9A])
        #expect(bytes.count == 17)
    }

    @Test func rtpPacketParsesAOneByteHeaderExtension() throws {
        // docs/spec-rtp.md §15.1, extension vector.
        let packet = try RTPPacket.parse(
            Self.hex("90 60 12 36 00 0A 5C 90 12 34 56 78 BE DE 00 01 12 AB 00 00 41 9A"))
        #expect(packet.hasExtension)
        #expect(packet.extensionProfile == 0xBEDE)
        #expect(Array(packet.extensionData ?? Data()) == [0x12, 0xAB, 0x00, 0x00])
        #expect(Array(packet.payload) == [0x41, 0x9A])
        let extensionValue = try #require(packet.headerExtension)
        let decoded = extensionValue.elements()
        #expect(decoded.truncated == false)
        #expect(decoded.elements.count == 1)
        #expect(decoded.elements.first?.id == 1)
        // RFC 8285 one-byte form: the low nibble is `length - 1`, so `0x12` is id 1 with a **three**
        // byte value. docs/spec-rtp.md §3.3 states that rule correctly and then annotates this same
        // vector as "id 1, value AB, then two padding bytes", which contradicts it — a one-byte
        // value would need a `0x10` header byte. The RFC and the spec's own rule win.
        #expect(Array(decoded.elements.first?.value ?? Data()) == [0xAB, 0x00, 0x00])
    }

    @Test func rtpPacketParsesEveryCSRCCountOffsetCorrectly() throws {
        // Synthesised: one CSRC per count, each a recognisable word, followed by a 2-byte payload.
        for count in 0...15 {
            var bytes: [UInt8] = [0x80 | UInt8(count), 0x60, 0x12, 0x34,
                                  0x00, 0x00, 0x00, 0x01, 0xAA, 0xBB, 0xCC, 0xDD]
            for index in 0..<count {
                bytes += [0x10, 0x00, 0x00, UInt8(index)]
            }
            bytes += [0x41, 0x9A]
            let packet = try RTPPacket.parse(Data(bytes))
            #expect(packet.csrcCount == UInt8(count))
            #expect(packet.csrc.count == count)
            for index in 0..<count {
                #expect(packet.csrc[index] == 0x1000_0000 | UInt32(index))
            }
            #expect(Array(packet.payload) == [0x41, 0x9A])
        }
    }

    @Test func rtpPacketAcceptsAZeroWordHeaderExtension() throws {
        // Synthesised: X set, length 0, so the extension body is empty and the payload follows.
        let packet = try RTPPacket.parse(
            Self.hex("90 60 00 01 00 00 00 00 00 00 00 01 AB CD 00 00 41"))
        #expect(packet.extensionProfile == 0xABCD)
        #expect(packet.extensionData?.isEmpty == true)
        #expect(Array(packet.payload) == [0x41])
        // An unknown profile is opaque, never an error, and yields no elements.
        let decoded = try #require(packet.headerExtension).elements()
        #expect(decoded.elements.isEmpty)
        #expect(decoded.truncated == false)
    }

    @Test func rtpPacketAcceptsAnEmptyPayloadAfterPaddingRemoval() throws {
        // RFC 3550 allows it and Hikvision emits one at the end of some GOPs.
        let packet = try RTPPacket.parse(Self.hex("A0 60 00 01 00 00 00 00 00 00 00 01 00 00 00 04"))
        #expect(packet.payload.isEmpty)
    }

    @Test func rtpPacketAcceptsPaddingThatFillsTheWholePayload() throws {
        // Synthesised edge case: padding length exactly equals the bytes after the header.
        let packet = try RTPPacket.parse(Self.hex("A0 60 00 01 00 00 00 00 00 00 00 01 00 02"))
        #expect(packet.payload.isEmpty)
    }

    @Test func rtpPacketParsesFromASliceWithANonZeroStartIndex() throws {
        // The trap this module's `RTPBytes` wrapper exists to prevent: `Data` slices keep the
        // parent's indices, so a parser that subscripts from 0 reads the wrong bytes or traps.
        let padded = Data([0xFF, 0xFF, 0xFF])
            + Self.hex("80 60 12 34 00 0A 5C 90 12 34 56 78 65 88")
        let packet = try RTPPacket.parse(padded[3...])
        #expect(packet.sequenceNumber == 0x1234)
        #expect(Array(packet.payload) == [0x65, 0x88])
    }

    // MARK: - Hostile shapes

    @Test func rtpPacketRejectsAnythingShorterThanTheFixedHeader() {
        for length in 0..<12 {
            let bytes = Data(repeating: 0x80, count: length)
            #expect(throws: RTPError.shortPacket(length: length)) { try RTPPacket.parse(bytes) }
        }
    }

    @Test func rtpPacketRejectsAVersionOtherThanTwo() {
        for version in [UInt8(0), 1, 3] {
            let bytes = Data([version << 6] + [UInt8](repeating: 0, count: 11))
            #expect(throws: RTPError.badVersion(version)) { try RTPPacket.parse(bytes) }
        }
    }

    @Test func rtpPacketRejectsACSRCCountThatExceedsThePacket() {
        // CC = 15 promises 60 bytes of CSRC list; the packet has none.
        let bytes = Data([0x8F, 0x60] + [UInt8](repeating: 0, count: 10))
        #expect(throws: RTPError.truncatedCSRC) { try RTPPacket.parse(bytes) }
    }

    @Test func rtpPacketRejectsAnExtensionLengthThatRunsPastTheEnd() {
        // X set, length 4 words = 16 bytes, but only 4 bytes follow the extension header.
        let bytes = RTPPacketParsing.hex("90 60 00 01 00 00 00 00 00 00 00 01 BE DE 00 04 01 02 03 04")
        #expect(throws: RTPError.truncatedExtension) { try RTPPacket.parse(bytes) }
    }

    @Test func rtpPacketRejectsATruncatedExtensionHeader() {
        // X set but fewer than the four bytes the extension header itself needs.
        let bytes = RTPPacketParsing.hex("90 60 00 01 00 00 00 00 00 00 00 01 BE DE")
        #expect(throws: RTPError.truncatedExtension) { try RTPPacket.parse(bytes) }
    }

    @Test func rtpPacketRejectsAZeroPaddingLength() {
        // The padding count includes itself, so zero is impossible.
        let bytes = RTPPacketParsing.hex("A0 60 00 01 00 00 00 00 00 00 00 01 41 00")
        #expect(throws: RTPError.badPaddingLength(0)) { try RTPPacket.parse(bytes) }
    }

    @Test func rtpPacketRejectsPaddingLargerThanThePacket() {
        // 200 bytes of padding claimed in a 14-byte packet: this is the out-of-bounds read.
        let bytes = RTPPacketParsing.hex("A0 60 00 01 00 00 00 00 00 00 00 01 41 C8")
        #expect(throws: RTPError.badPaddingLength(200)) { try RTPPacket.parse(bytes) }
    }

    @Test func rtpPacketRejectsPaddingThatWouldEatTheHeader() {
        // Exactly one byte more padding than there is payload.
        let bytes = RTPPacketParsing.hex("A0 60 00 01 00 00 00 00 00 00 00 01 41 03")
        #expect(throws: RTPError.badPaddingLength(3)) { try RTPPacket.parse(bytes) }
    }

    @Test func rtpPacketSurvivesTenThousandPseudoRandomBuffers() {
        // Fixed seed, so a failure reproduces exactly. The assertion is the absence of a trap: every
        // buffer either parses or throws, and no parse reads outside its own bytes.
        var generator = SplitMix64RandomSource(seed: 0x5EED_1234_ABCD_0001)
        for _ in 0..<10_000 {
            let length = Int(generator.next(upperBound: 40))
            let bytes = Data(generator.randomBytes(length))
            do {
                let packet = try RTPPacket.parse(bytes)
                #expect(packet.payload.count <= bytes.count)
                #expect(packet.payloadOffset + packet.payload.count <= bytes.count)
            } catch {
                // Only the five header errors are reachable; anything else means a new code path
                // grew without a bounds check.
                switch error {
                case .shortPacket, .badVersion, .truncatedCSRC, .truncatedExtension,
                     .badPaddingLength:
                    break
                default:
                    Issue.record("unexpected parse error \(error)")
                }
            }
        }
    }
}

// MARK: - Header extension elements

@Suite struct RTPHeaderExtensionElements {

    @Test func rtpHeaderExtensionSkipsOneBytePaddingAndStopsAtIDFifteen() {
        // 0x00 padding, then id 2 / len 2, then the 0xF0 stop marker, then junk that must be ignored.
        let extensionValue = RTPHeaderExtension(
            profile: 0xBEDE, data: Data([0x00, 0x21, 0xAA, 0xBB, 0xF0, 0xDE, 0xAD]))
        let decoded = extensionValue.elements()
        #expect(decoded.truncated == false)
        #expect(decoded.elements.count == 1)
        #expect(decoded.elements.first?.id == 2)
        #expect(Array(decoded.elements.first?.value ?? Data()) == [0xAA, 0xBB])
    }

    @Test func rtpHeaderExtensionReportsTruncationWithoutFailingThePacket() {
        // id 1 declares 16 bytes of value; only two are present.
        let extensionValue = RTPHeaderExtension(profile: 0xBEDE, data: Data([0x1F, 0xAA, 0xBB]))
        let decoded = extensionValue.elements()
        #expect(decoded.truncated)
        #expect(decoded.elements.isEmpty)
    }

    @Test func rtpHeaderExtensionParsesTheTwoByteForm() {
        let extensionValue = RTPHeaderExtension(
            profile: 0x1005, data: Data([0x00, 0x2A, 0x03, 0x01, 0x02, 0x03, 0x7F, 0x00]))
        #expect(extensionValue.isTwoByteForm)
        #expect(extensionValue.appBits == 5)
        let decoded = extensionValue.elements()
        #expect(decoded.truncated == false)
        #expect(decoded.elements.count == 2)
        #expect(decoded.elements.first?.id == 0x2A)
        #expect(Array(decoded.elements.first?.value ?? Data()) == [0x01, 0x02, 0x03])
        // A zero-length value is legal in the two-byte form.
        #expect(decoded.elements.last?.id == 0x7F)
        #expect(decoded.elements.last?.value.isEmpty == true)
    }

    @Test func rtpHeaderExtensionTreatsAnUnknownProfileAsOpaque() {
        // The Hikvision 0xABAC BCD wall clock: exposed verbatim, never interpreted, never an error.
        let extensionValue = RTPHeaderExtension(profile: 0xABAC, data: Data([0x20, 0x24, 0x03, 0x16]))
        #expect(extensionValue.isOneByteForm == false)
        #expect(extensionValue.isTwoByteForm == false)
        let decoded = extensionValue.elements()
        #expect(decoded.elements.isEmpty)
        #expect(decoded.truncated == false)
    }
}
