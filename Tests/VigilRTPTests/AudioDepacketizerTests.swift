//
//  AudioDepacketizerTests.swift
//  VigilRTPTests
//
//  RFC 3640 AAC-hbr framing, `AudioSpecificConfig`, the ADTS builder, ITU-T G.711 companding and
//  the G.726 packing. Vectors are from docs/spec-rtp.md §15.5 and §15.6, except where a comment
//  records that the document's own value disagrees with the ITU reference algorithm.
//

import Foundation
import Testing

import VigilProtocols
@testable import VigilRTP

@Suite struct AudioSpecificConfigTests {

    /// docs/spec-rtp.md §15.5.
    ///
    /// **Spec defect.** The document's table gives `config=1210` one channel, and its bit
    /// decomposition `00010 0100 0001 0000` is seventeen bits long for a sixteen-bit config. The
    /// fields are `audioObjectType` (5), `samplingFrequencyIndex` (4), `channelConfiguration` (4),
    /// so `0x1210` is bits `00010 0100 0010 000` — AAC-LC, 44 100 Hz, **stereo**. `0x1208` is the
    /// mono form. The `1190` row, which the document gives two channels, decodes the same way and
    /// agrees, which is what pins the field offsets.
    @Test func audioSpecificConfigParsesTheDocumentedHikvisionConfigs() throws {
        let cases: [(String, Int32, Int32, Int32)] = [
            ("1210", 44_100, 2, 1024),
            ("1208", 44_100, 1, 1024),
            ("1408", 16_000, 1, 1024),
            ("1588", 8_000, 1, 1024),
            ("1190", 48_000, 2, 1024),
            ("121056E500", 44_100, 2, 1024),   // backward-compatible SBR: the core rate is kept
        ]
        for (hex, rate, channels, frames) in cases {
            let format = try AudioSpecificConfig.parse(hex: hex)
            #expect(format.codec == .aac, "\(hex)")
            #expect(format.sampleRate == rate, "\(hex)")
            #expect(format.channels == channels, "\(hex)")
            #expect(format.framesPerPacket == frames, "\(hex)")
            #expect(format.magicCookie?.count == hex.count / 2, "\(hex)")
        }
    }

    /// The cookie must be the bytes verbatim: `AudioConverter` rejects anything else.
    @Test func audioSpecificConfigKeepsTheRawBytesAsTheMagicCookie() throws {
        let format = try AudioSpecificConfig.parse(hex: "1408")
        #expect(format.magicCookie == Data([0x14, 0x08]))
    }

    /// Upper case, lower case and surrounding whitespace all parse; anything else is rejected.
    @Test func audioSpecificConfigHexParsingIsLenientButNotSloppy() throws {
        #expect(try AudioSpecificConfig.parse(hex: "1408").sampleRate == 16_000)
        #expect(try AudioSpecificConfig.parse(hex: " 1408 ").sampleRate == 16_000)
        // Same config in upper and lower case must give the same answer.
        #expect(try AudioSpecificConfig.parse(hex: "121056E500").sampleRate
            == AudioSpecificConfig.parse(hex: "121056e500").sampleRate)
        #expect(throws: RTPError.self) { try AudioSpecificConfig.parse(hex: "140") }
        #expect(throws: RTPError.self) { try AudioSpecificConfig.parse(hex: "14zz") }
        #expect(throws: RTPError.self) { try AudioSpecificConfig.parse(hex: "") }
        #expect(throws: RTPError.self) { try AudioSpecificConfig.parse(Data([0x14])) }
    }

    /// Sampling-frequency indices 13 and 14 are reserved and must not be guessed at; index 15 is an
    /// escape carrying an explicit 24-bit rate.
    @Test func audioSpecificConfigHandlesReservedAndEscapeFrequencyIndices() throws {
        // AOT 2, sfi 13 -> 00010 1101 0001 000...
        #expect(throws: RTPError.self) { try AudioSpecificConfig.parse(Data([0x16, 0x88])) }
        // AOT 2 (00010), sfi 15 (1111) escape, explicit 24-bit rate 44 100
        // (000000001010110001000100), channelConfiguration 1 (0001), frameLengthFlag 0, padding.
        let escape = Data([0x17, 0x80, 0x56, 0x22, 0x08])
        let format = try AudioSpecificConfig.parse(escape)
        #expect(format.sampleRate == 44_100)
        #expect(format.channels == 1)
        #expect(format.framesPerPacket == 1024)
    }

    /// A `channelConfiguration` of zero means a program config element follows, which Vigil does
    /// not parse; mono is the documented fallback.
    @Test func audioSpecificConfigFallsBackToMonoForAProgramConfigElement() throws {
        // AOT 2, sfi 8 (16 kHz), channelConfiguration 0.
        let format = try AudioSpecificConfig.parse(Data([0x14, 0x00]))
        #expect(format.channels == 1)
    }

    /// The frequency-index lookup is the inverse of the table, and returns `nil` off it.
    @Test func audioSpecificConfigFrequencyIndexInvertsTheTable() {
        #expect(AudioSpecificConfig.frequencyIndex(for: 16_000) == 8)
        #expect(AudioSpecificConfig.frequencyIndex(for: 44_100) == 4)
        #expect(AudioSpecificConfig.frequencyIndex(for: 8_000) == 11)
        #expect(AudioSpecificConfig.frequencyIndex(for: 12_345) == nil)
    }
}

@Suite struct ADTSBuilderTests {

    /// docs/spec-rtp.md §15.5 gives `FF F1 60 40 25 9F FC` for `config=1408`.
    ///
    /// **Spec defect.** The document labels that header as covering a 291-byte access unit, but its
    /// own `aac_frame_length` field decodes to 300, which is 293 + 7. The formula in §8.6 is right
    /// and the caption is off by two, so the vector is asserted here at the size it actually
    /// encodes, and the 291-byte case is asserted alongside it.
    @Test func adtsHeaderMatchesTheDocumentedVector() throws {
        let format = try AudioSpecificConfig.parse(hex: "1408")
        #expect(ADTS.header(auByteCount: 293, format: format) == [0xFF, 0xF1, 0x60, 0x40, 0x25,
                                                                  0x9F, 0xFC])
        #expect(ADTS.header(auByteCount: 291, format: format) == [0xFF, 0xF1, 0x60, 0x40, 0x25,
                                                                  0x5F, 0xFC])
    }

    /// The header is always seven bytes, and `aac_frame_length` is the access unit plus seven.
    @Test func adtsHeaderEncodesFrameLengthAcrossItsThreeFields() throws {
        let format = try AudioSpecificConfig.parse(hex: "1210")
        for size in [0, 1, 100, 1024, 8181] {
            let header = ADTS.header(auByteCount: size, format: format)
            #expect(header.count == 7)
            let length = (Int(header[3] & 0x03) << 11) | (Int(header[4]) << 3)
                | (Int(header[5] & 0xE0) >> 5)
            #expect(length == size + 7, "size \(size)")
            #expect(header[0] == 0xFF)
            #expect(header[1] & 0xF6 == 0xF0)
        }
    }

    /// A sample rate outside the ISO table must not produce an out-of-range index field.
    @Test func adtsHeaderClampsAnUnknownSampleRate() {
        let format = AudioFormatInfo(codec: .aac, sampleRate: 12_345, channels: 1,
                                     framesPerPacket: 1024, magicCookie: nil)
        let header = ADTS.header(auByteCount: 10, format: format)
        #expect((header[2] >> 2) & 0x0F == 4)
    }
}

@Suite struct AACDepacketizerTests {

    /// The fmtp Hikvision's DS-2CD2385 actually sends.
    static let hikvisionFmtp = ["streamtype": "5", "profile-level-id": "1", "mode": "AAC-hbr",
                                "sizelength": "13", "indexlength": "3", "indexdeltalength": "3",
                                "config": "1408"]

    /// docs/spec-rtp.md §15.5. `AU-headers-length` 0x0010 is 16 bits; header 0x0918's top 13 bits
    /// are the size 291 and its low 3 bits are AU-Index 0.
    @Test func aacSingleAccessUnitPacketProducesOneFrame() throws {
        var depacketizer = try AACDepacketizer(clockRate: 16_000, fmtp: Self.hikvisionFmtp)
        var payload: [UInt8] = [0x00, 0x10, 0x09, 0x18]
        payload += (0..<291).map { UInt8(truncatingIfNeeded: $0) }

        let out = depacketizer.push(DepacketizerFixture.packet(payload, sequence: 1,
                                                               timestamp: 160_000,
                                                               payloadType: 98),
                                    at: DepacketizerFixture.instant(0))
        let frame = try #require(out.frames.first)
        #expect(out.frames.count == 1)
        #expect(frame.data.count == 291)
        #expect(frame.codec == .audio(.aac))
        #expect(frame.pts.value == 160_000)
        #expect(frame.pts.timescale == 16_000)
        #expect(frame.duration?.value == 1024)
        #expect(frame.isKeyframe)
        #expect(frame.audioFormat?.magicCookie == Data([0x14, 0x08]))
        let announced = out.events.contains { if case .audioConfigChanged = $0 { true } else { false } }
        #expect(announced)
    }

    /// docs/spec-rtp.md §15.5. Two access units of 100 and 120 bytes; the second's AU-Index-delta of
    /// zero puts it one frame later, so its presentation time is `T + 1024`.
    @Test func aacMultipleAccessUnitPacketProducesFramesInOrder() throws {
        var depacketizer = try AACDepacketizer(clockRate: 16_000, fmtp: Self.hikvisionFmtp)
        var payload: [UInt8] = [0x00, 0x20, 0x03, 0x20, 0x03, 0xC0]
        payload += [UInt8](repeating: 0xA1, count: 100)
        payload += [UInt8](repeating: 0xB2, count: 120)

        let out = depacketizer.push(DepacketizerFixture.packet(payload, sequence: 1,
                                                               timestamp: 320_000,
                                                               payloadType: 98),
                                    at: DepacketizerFixture.instant(0))
        #expect(out.frames.count == 2)
        #expect(out.frames[0].data.count == 100)
        #expect(out.frames[1].data.count == 120)
        #expect(out.frames[0].pts.value == 320_000)
        #expect(out.frames[1].pts.value == 320_000 + 1024)
        #expect(out.frames[0].data.allSatisfy { $0 == 0xA1 })
        #expect(out.frames[1].data.allSatisfy { $0 == 0xB2 })
    }

    /// An access unit larger than the MTU repeats its header in every packet; the receiver
    /// concatenates until it has the declared number of bytes.
    @Test func aacFragmentedAccessUnitIsConcatenatedAcrossPackets() throws {
        var depacketizer = try AACDepacketizer(clockRate: 16_000, fmtp: Self.hikvisionFmtp)
        // Size 400 in the top 13 bits: 400 << 3 == 0x0C80.
        let header: [UInt8] = [0x00, 0x10, 0x0C, 0x80]
        let first = header + [UInt8](repeating: 0x01, count: 250)
        let second = header + [UInt8](repeating: 0x02, count: 150)

        let a = depacketizer.push(DepacketizerFixture.packet(first, sequence: 1, timestamp: 1000,
                                                             payloadType: 98),
                                  at: DepacketizerFixture.instant(0))
        #expect(a.frames.isEmpty)
        let b = depacketizer.push(DepacketizerFixture.packet(second, sequence: 2, timestamp: 1000,
                                                             payloadType: 98),
                                  at: DepacketizerFixture.instant(1))
        let frame = try #require(b.frames.first)
        #expect(frame.data.count == 400)
        #expect(frame.data.prefix(250).allSatisfy { $0 == 0x01 })
        #expect(frame.data.suffix(150).allSatisfy { $0 == 0x02 })
    }

    /// Sizes that do not add up to the data section mean the packet was mis-parsed; emitting
    /// anything would hand the decoder sliced-up garbage.
    @Test func aacSizeMismatchEmitsNothingAndIsCounted() throws {
        var depacketizer = try AACDepacketizer(clockRate: 16_000, fmtp: Self.hikvisionFmtp)
        // Declares two access units of 100 and 120 bytes but carries 150.
        var payload: [UInt8] = [0x00, 0x20, 0x03, 0x20, 0x03, 0xC0]
        payload += [UInt8](repeating: 0x00, count: 150)
        let out = depacketizer.push(DepacketizerFixture.packet(payload, sequence: 1, timestamp: 1000,
                                                               payloadType: 98),
                                    at: DepacketizerFixture.instant(0))
        #expect(out.frames.isEmpty)
        #expect(DepacketizerFixture.malformedReasons(out.events).contains(.auSizeMismatch))
    }

    /// `AU-headers-length == 0` is only legal with `constantsize`; without it the packet is
    /// malformed rather than guessed at.
    @Test func aacZeroLengthHeaderSectionNeedsConstantSize() throws {
        var strict = try AACDepacketizer(clockRate: 16_000, fmtp: Self.hikvisionFmtp)
        let payload: [UInt8] = [0x00, 0x00] + [UInt8](repeating: 0x7F, count: 60)
        let out = strict.push(DepacketizerFixture.packet(payload, sequence: 1, timestamp: 1000,
                                                         payloadType: 98),
                              at: DepacketizerFixture.instant(0))
        #expect(out.frames.isEmpty)
        #expect(DepacketizerFixture.malformedReasons(out.events).contains(.auSizeMismatch))

        var constant = try AACDepacketizer(clockRate: 16_000,
                                           fmtp: Self.hikvisionFmtp.merging(["constantsize": "30"]) {
                                               _, new in new
                                           })
        let sized = constant.push(DepacketizerFixture.packet(payload, sequence: 1, timestamp: 1000,
                                                             payloadType: 98),
                                  at: DepacketizerFixture.instant(0))
        #expect(sized.frames.count == 2)
        #expect(sized.frames.allSatisfy { $0.data.count == 30 })
    }

    /// Encoding names and mode values arrive in every case Hikvision firmware feels like using.
    @Test func aacModeComparisonIsCaseInsensitive() throws {
        for mode in ["AAC-hbr", "aac-hbr", "AAC-HBR", " AAC-hbr "] {
            var fmtp = Self.hikvisionFmtp
            fmtp["mode"] = mode
            let depacketizer = try AACDepacketizer(clockRate: 16_000, fmtp: fmtp)
            #expect(depacketizer.codec == .audio(.aac))
        }
        var lowBitRate = Self.hikvisionFmtp
        lowBitRate["mode"] = "AAC-lbr"
        #expect(throws: RTPError.self) { try AACDepacketizer(clockRate: 16_000, fmtp: lowBitRate) }
    }

    /// A missing `config=` cannot be defaulted: the decoder would have no cookie.
    @Test func aacMissingConfigIsRejectedAtConstruction() {
        var fmtp = AACDepacketizerTests.hikvisionFmtp
        fmtp["config"] = nil
        #expect(throws: RTPError.self) { try AACDepacketizer(clockRate: 16_000, fmtp: fmtp) }
        #expect(throws: RTPError.self) {
            try AACDepacketizer(clockRate: 0, fmtp: AACDepacketizerTests.hikvisionFmtp)
        }
    }

    /// A zero-length payload and a header section longer than the packet are both dropped.
    @Test func aacHostilePayloadsAreDroppedSafely() throws {
        var depacketizer = try AACDepacketizer(clockRate: 16_000, fmtp: Self.hikvisionFmtp)
        let payloads: [[UInt8]] = [[], [0x00], [0xFF, 0xF8], [0x00, 0x10]]
        for payload in payloads {
            let out = depacketizer.push(DepacketizerFixture.packet(payload, sequence: 1,
                                                                   timestamp: 1000,
                                                                   payloadType: 98),
                                        at: DepacketizerFixture.instant(0))
            #expect(out.frames.isEmpty, "payload \(payload)")
        }
    }
}

@Suite struct G711Tests {

    /// Values produced by the ITU-T / CCITT reference `ulaw2linear` and `alaw2linear`.
    ///
    /// **Spec defect.** docs/spec-rtp.md §15.6 lists µ-law `0x2A` as −4988 and `0xD5` as 876, and
    /// its whole A-law column disagrees with its own §9.3 encoder, which states that the A-law sign
    /// bit set means *positive*. The reference algorithm is authoritative and is what is asserted
    /// here; the four entries the document gets right (`0x00`, `0x80`, `0xFF`, `0x7F` for µ-law and
    /// `0x00`, `0x80` for A-law) agree exactly.
    @Test func g711DecodeTableMatchesTheReferenceAlgorithm() {
        #expect(G711.muLawToLinear(0xFF) == 0)
        #expect(G711.muLawToLinear(0x7F) == 0)            // the negative-zero encoding
        #expect(G711.muLawToLinear(0x00) == -32_124)
        #expect(G711.muLawToLinear(0x80) == 32_124)
        #expect(G711.muLawToLinear(0x2A) == -5_372)
        #expect(G711.muLawToLinear(0xD5) == 716)

        #expect(G711.aLawToLinear(0x00) == -5_504)
        #expect(G711.aLawToLinear(0x80) == 5_504)
        #expect(G711.aLawToLinear(0xD5) == 8)
        #expect(G711.aLawToLinear(0x2A) == -32_256)
        #expect(G711.aLawToLinear(0xFF) == 848)
        #expect(G711.aLawToLinear(0x7F) == -848)
    }

    /// The lookup tables the decode path uses must equal the closed forms that generated them.
    @Test func g711TablesEqualTheClosedForms() {
        for byte in 0...255 {
            #expect(G711.muLawTable[byte] == G711.muLawToLinear(UInt8(byte)))
            #expect(G711.aLawTable[byte] == G711.aLawToLinear(UInt8(byte)))
        }
        #expect(G711.muLawTable.min() == -32_124)
        #expect(G711.muLawTable.max() == 32_124)
        #expect(G711.aLawTable.min() == -32_256)
        #expect(G711.aLawTable.max() == 32_256)
    }

    /// Round-trip identity holds for all 256 A-law codes and for 255 of the 256 µ-law codes: `0x7F`
    /// is negative zero, decodes to 0, and therefore re-encodes as `0xFF`.
    @Test func g711RoundTripIsIdentityExceptForMuLawNegativeZero() {
        for byte in 0...255 {
            let code = UInt8(byte)
            #expect(G711.linearToALaw(G711.aLawToLinear(code)) == code, "A-law \(code)")
            let reencoded = G711.linearToMuLaw(G711.muLawToLinear(code))
            if code == 0x7F {
                #expect(reencoded == 0xFF)
            } else {
                #expect(reencoded == code, "µ-law \(code)")
            }
        }
    }

    /// A 160-byte packet is 20 ms at 8 kHz and yields 320 bytes of little-endian PCM.
    @Test func g711DepacketizerProducesLittleEndianPCMWithTheRightDuration() throws {
        var depacketizer = try PCMDepacketizer(source: .g711U)
        let payload = [UInt8](repeating: 0xFF, count: 160)
        let out = depacketizer.push(DepacketizerFixture.packet(payload, sequence: 1, timestamp: 8000,
                                                               payloadType: 0),
                                    at: DepacketizerFixture.instant(0))
        let frame = try #require(out.frames.first)
        #expect(frame.codec == .audio(.pcmS16LE))
        #expect(frame.data.count == 320)
        #expect(frame.duration?.value == 160)
        #expect(frame.duration?.timescale == 8000)
        #expect(frame.pts.value == 8000)
        #expect(frame.data.allSatisfy { $0 == 0 })        // 0xFF is µ-law silence
        #expect(depacketizer.wireCodec == .g711U)
    }

    /// Little-endian byte order is not incidental: `AVAudioSourceNode` is handed this buffer with no
    /// further conversion.
    @Test func g711DecodeWritesLittleEndianSampleBytes() {
        let pcm = G711.decode(Data([0x00]), law: .muLaw)      // -32124 == 0x8284 two's complement
        #expect([UInt8](pcm) == [0x84, 0x82])
    }

    /// Encoding round-trips a decoded buffer back to the same payload, for talk-back.
    @Test func g711EncodeInvertsDecodeOverAWholePayload() {
        let payload = Data((0...255).map { UInt8($0) }.filter { $0 != 0x7F })
        let pcm = G711.decode(payload, law: .aLaw)
        #expect(G711.encode(pcm, law: .aLaw) == payload)
    }

    /// An empty payload is reported, and an odd trailing byte on the encode path is ignored.
    @Test func g711HandlesEmptyAndOddLengthBuffers() throws {
        #expect(G711.decode(Data(), law: .aLaw).isEmpty)
        #expect(G711.encode(Data([0x01]), law: .aLaw).isEmpty)
        var depacketizer = try PCMDepacketizer(source: .g711A)
        let out = depacketizer.push(DepacketizerFixture.packet([], sequence: 1, timestamp: 0,
                                                               payloadType: 8),
                                    at: DepacketizerFixture.instant(0))
        #expect(out.frames.isEmpty)
        #expect(DepacketizerFixture.malformedReasons(out.events) == [.emptyPayload])
    }

    /// Encoding names map to laws case-insensitively, and unknown ones map to nothing.
    @Test func g711SourceResolutionMatchesTheEncodingNames() {
        #expect(PCMDepacketizer.source(forEncodingName: "PCMA") == .g711A)
        #expect(PCMDepacketizer.source(forEncodingName: "pcmu") == .g711U)
        #expect(PCMDepacketizer.source(forEncodingName: "G726-32") == .g726_32(packing: .rfc3551))
        #expect(PCMDepacketizer.source(forEncodingName: "AAL2-G726-32") == .g726_32(packing: .aal2))
        #expect(PCMDepacketizer.source(forEncodingName: "opus") == nil)
    }
}

@Suite struct G726Tests {

    /// Two codewords per byte, two bytes per sample: a payload of N bytes decodes to 4N bytes.
    @Test func g726DecodeProducesTwoSamplesPerByte() {
        for count in [0, 1, 20, 80, 160] {
            let payload = Data([UInt8](repeating: 0x5A, count: count))
            #expect(G726.decode32k(payload).count == count * 4)
        }
    }

    /// RFC 3551 puts sample 0 in the high nibble; AAL2 puts it in the low one. Feeding the same
    /// bytes through both must produce the two sample orders, not the same output twice.
    @Test func g726PackingOrderDiffersBetweenRFC3551AndAAL2() {
        let payload = Data([0x1F, 0x2E, 0x3D])
        var standard = G726.DecoderState()
        var aal2 = G726.DecoderState()
        let a = G726.decode32k(payload, state: &standard, packing: .rfc3551)
        let b = G726.decode32k(payload, state: &aal2, packing: .aal2)
        #expect(a.count == b.count)
        #expect(a != b)
    }

    /// The predictor must stay bounded over a long hostile input: every state field is clamped by
    /// the algorithm, so a stream of worst-case codewords cannot make it diverge or trap.
    @Test func g726StateStaysBoundedOverALongInput() {
        var state = G726.DecoderState()
        var seed: UInt64 = 0x0726_2025_1234_5678
        for _ in 0..<200 {
            var payload = [UInt8]()
            for _ in 0..<160 {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                payload.append(UInt8(truncatingIfNeeded: seed >> 24))
            }
            let pcm = G726.decode32k(Data(payload), state: &state, packing: .rfc3551)
            #expect(pcm.count == 640)
        }
        #expect(state.yu >= 544 && state.yu <= 5120)
        #expect(state.ap >= 0 && state.ap <= 512)
        #expect(state.a.allSatisfy { abs($0) <= 32_768 })
        #expect(state.b.allSatisfy { abs($0) <= 32_768 })
    }

    /// A constant codeword stream converges rather than oscillating, which is the cheapest signal
    /// that the adaptation loop is wired the right way round.
    @Test func g726ConstantCodewordStreamConverges() {
        var state = G726.DecoderState()
        let payload = Data([UInt8](repeating: 0x00, count: 400))
        let pcm = G726.decode32k(payload, state: &state, packing: .rfc3551)
        var samples: [Int16] = []
        var index = pcm.startIndex
        while index < pcm.endIndex {
            samples.append(Int16(bitPattern: UInt16(pcm[index]) | UInt16(pcm[index + 1]) << 8))
            index += 2
        }
        #expect(samples.count == 800)
        let head = samples.prefix(100).map { abs(Int($0)) }.reduce(0, +) / 100
        let tail = samples.suffix(100).map { abs(Int($0)) }.reduce(0, +) / 100
        #expect(tail <= head * 4 + 1024)                  // no runaway growth
    }

    /// The depacketizer carries predictor state across packets, so two 80-byte packets do not
    /// decode the same way as two independent buffers would.
    @Test func g726DepacketizerCarriesStateBetweenPackets() throws {
        var depacketizer = try PCMDepacketizer(source: .g726_32(packing: .rfc3551))
        let payload = [UInt8](repeating: 0x39, count: 80)
        let first = depacketizer.push(DepacketizerFixture.packet(payload, sequence: 1,
                                                                 timestamp: 0, payloadType: 96),
                                      at: DepacketizerFixture.instant(0))
        let second = depacketizer.push(DepacketizerFixture.packet(payload, sequence: 2,
                                                                  timestamp: 160, payloadType: 96),
                                       at: DepacketizerFixture.instant(20))
        let a = try #require(first.frames.first)
        let b = try #require(second.frames.first)
        #expect(a.data.count == 320)
        #expect(b.data.count == 320)
        #expect(a.data != b.data)
        #expect(b.pts.value == 160)
        #expect(b.duration?.value == 160)
    }
}
