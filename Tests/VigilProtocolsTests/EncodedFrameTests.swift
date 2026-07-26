//
//  EncodedFrameTests.swift
//  VigilProtocolsTests
//
//  The frame boundary type: the 4-byte length-prefixed NAL layout `data` is defined to hold, its
//  round-trip, its rejection of a truncated or lying length, and the defaults of the initialiser.
//  Covers docs/API_CONTRACT.md §3.5 and §2 R-02 / R-06 / R-08.
//
//  The NAL walk below uses the module's own `ByteReader`, which is exactly how `VigilVideo` and
//  `VigilBitstream` will read the buffer: every length is bounds-checked before a byte is consumed.
//  The NAL payloads are synthetic fixtures with real header bytes, not camera captures.
//

import Foundation
import Testing
import VigilProtocols

@Suite struct EncodedFrameTests {

    // MARK: - Fixtures and helpers

    /// H.264 IDR slice NAL: `nal_ref_idc = 3`, `nal_unit_type = 5` -> 0x65.
    private static let idrNAL = Data([0x65, 0x88, 0x84, 0x00, 0x21, 0xFF])

    /// H.264 SEI NAL: `nal_unit_type = 6` -> 0x06.
    private static let seiNAL = Data([0x06, 0x05, 0x02, 0x00, 0x80])

    /// Concatenates NAL units in the canonical AVCC/HVCC layout: a 4-byte big-endian length in
    /// front of each unit, no start codes, the length covering the unit only.
    private static func lengthPrefixed(_ nals: [Data]) -> Data {
        var out = Data()
        for nal in nals {
            let length = UInt32(nal.count)
            out.append(contentsOf: [UInt8(truncatingIfNeeded: length >> 24),
                                    UInt8(truncatingIfNeeded: length >> 16),
                                    UInt8(truncatingIfNeeded: length >> 8),
                                    UInt8(truncatingIfNeeded: length)])
            out.append(nal)
        }
        return out
    }

    /// Walks a length-prefixed buffer, throwing rather than reading out of bounds.
    private static func parseNALUnits(_ data: Data) throws(ByteReaderError) -> [Data] {
        var reader = ByteReader([UInt8](data))
        var units: [Data] = []
        while !reader.isAtEnd {
            let length = Int(try reader.u32BE())
            units.append(Data(try reader.read(length)))
        }
        return units
    }

    // MARK: - Payload round-trip

    @Test func encodedFrameLengthPrefixedPayloadRoundTrips() throws {
        let payload = Self.lengthPrefixed([Self.seiNAL, Self.idrNAL])
        let frame = EncodedFrame(data: payload, codec: .video(.h264),
                                 pts: MediaTimestamp(value: 3_000, timescale: 90_000),
                                 receivedAt: MediaInstant(nanoseconds: 1_000),
                                 isKeyframe: true, nalCount: 2)

        let units = try Self.parseNALUnits(frame.data)
        #expect(units == [Self.seiNAL, Self.idrNAL])
        #expect(units.count == frame.nalCount)
        #expect(frame.byteCount == 4 + Self.seiNAL.count + 4 + Self.idrNAL.count)
    }

    @Test func encodedFramePayloadContainsNoAnnexBStartCode() {
        let payload = Self.lengthPrefixed([Self.idrNAL])
        // The first four bytes are the length (0x00000006), never 0x00000001.
        #expect(Array(payload.prefix(4)) == [0x00, 0x00, 0x00, 0x06])
        #expect(payload.count == 4 + Self.idrNAL.count)
    }

    @Test func encodedFrameSingleNALRoundTripsAndReportsItsLength() throws {
        let units = try Self.parseNALUnits(Self.lengthPrefixed([Self.idrNAL]))
        #expect(units == [Self.idrNAL])
    }

    @Test func encodedFrameEmptyPayloadYieldsNoNALUnits() throws {
        #expect(try Self.parseNALUnits(Data()).isEmpty)
    }

    @Test func encodedFrameZeroLengthNALIsRepresentableAndDoesNotStall() throws {
        // A zero length is legal framing (and useless media); the walk must consume it and move on.
        let payload = Self.lengthPrefixed([Data(), Self.idrNAL])
        let units = try Self.parseNALUnits(payload)
        #expect(units.count == 2)
        #expect(units[0].isEmpty)
        #expect(units[1] == Self.idrNAL)
    }

    // MARK: - Hostile payloads

    @Test func encodedFrameTruncatedNALIsRejectedRatherThanReadOutOfBounds() {
        var payload = Self.lengthPrefixed([Self.idrNAL])
        payload.removeLast(2)                       // the unit is now 2 bytes short of its length
        #expect(throws: ByteReaderError.self) { try Self.parseNALUnits(payload) }
    }

    @Test func encodedFrameLyingLengthFieldIsRejected() {
        // A length of 0xFFFFFFF0 in front of six bytes: the classic hostile-camera framing.
        var payload = Data([0xFF, 0xFF, 0xFF, 0xF0])
        payload.append(Self.idrNAL)
        #expect(throws: ByteReaderError.self) { try Self.parseNALUnits(payload) }
    }

    @Test func encodedFrameTruncatedLengthPrefixIsRejected() {
        // Three bytes of a four-byte length: not "an empty frame", an error.
        #expect(throws: ByteReaderError.self) { try Self.parseNALUnits(Data([0x00, 0x00, 0x06])) }
    }

    @Test func encodedFrameLengthOverrunReportsTheBytesItWanted() throws {
        var payload = Data([0x00, 0x00, 0x00, 0x40])   // claims 64 bytes
        payload.append(Self.idrNAL)                    // supplies 6
        let error = try #require(throws: ByteReaderError.self) { try Self.parseNALUnits(payload) }
        #expect(error == .outOfBounds(needed: 64, remaining: 6, offset: 4))
    }

    // MARK: - Value semantics

    @Test func encodedFrameInitialiserDefaultsDescribeTheLiveCase() {
        let frame = EncodedFrame(data: Data([0x00, 0x00, 0x00, 0x01, 0x65]),
                                 codec: .video(.h265),
                                 pts: MediaTimestamp(value: 0, timescale: 90_000),
                                 receivedAt: .zero, isKeyframe: true)
        #expect(frame.dts == nil, "live Hikvision profiles never reorder (R-06)")
        #expect(frame.duration == nil)
        #expect(frame.dropClass == .required)
        #expect(!frame.isCorrupt)
        #expect(frame.parameterSets == nil)
        #expect(frame.audioFormat == nil)
        #expect(frame.sequenceRange == nil)
        #expect(frame.accessUnitIndex == 0)
        #expect(frame.nalCount == 0)
        #expect(frame.videoCodec == .h265)
    }

    @Test func encodedFrameAudioFrameCarriesFormatAndNoVideoCodec() {
        let format = AudioFormatInfo(codec: .aac, sampleRate: 16_000, channels: 1,
                                     framesPerPacket: 1_024, magicCookie: Data([0x14, 0x08]))
        let frame = EncodedFrame(data: Data([0x21, 0x00]), codec: .audio(.aac),
                                 pts: MediaTimestamp(value: 1_024, timescale: 16_000),
                                 duration: MediaTimestamp(value: 1_024, timescale: 16_000),
                                 receivedAt: .zero, isKeyframe: true, audioFormat: format)
        #expect(frame.videoCodec == nil)
        #expect(frame.codec.audio == .aac)
        #expect(frame.audioFormat?.magicCookie == Data([0x14, 0x08]))
        #expect(frame.duration?.seconds == 0.064)
    }

    @Test func encodedFrameEqualityComparesPayloadAndMetadata() {
        let base = EncodedFrame(data: Self.idrNAL, codec: .video(.h264),
                                pts: MediaTimestamp(value: 0, timescale: 90_000),
                                receivedAt: .zero, isKeyframe: true)
        var other = base
        #expect(base == other)
        other.isKeyframe = false
        #expect(base != other)
        var thirdFrame = base
        thirdFrame.sequenceRange = 100...104
        #expect(base != thirdFrame)
        #expect(thirdFrame.sequenceRange?.count == 5)
    }

    @Test func encodedFrameDropClassOrdersByDroppability() {
        #expect(FrameDropClass.required < .droppableNonReference)
        #expect(FrameDropClass.droppableNonReference < .droppableTemporal)
        #expect([FrameDropClass.droppableTemporal, .required, .droppableNonReference].max()
                    == .droppableTemporal)
        #expect(FrameDropClass.required.rawValue == 0)
    }

    @Test func audioFormatInfoStoresItsFieldsVerbatim() {
        let format = AudioFormatInfo(codec: .g711A, sampleRate: 8_000, channels: 1,
                                     framesPerPacket: 1)
        #expect(format.magicCookie == nil, "only AAC carries an AudioSpecificConfig (R-54)")
        #expect(format.sampleRate == 8_000)
        #expect(format == AudioFormatInfo(codec: .g711A, sampleRate: 8_000, channels: 1,
                                          framesPerPacket: 1))
    }
}
