//
//  RTPTrackFormatAdapterTests.swift
//  VigilRTPTests
//
//  The SDP-fields → `RTPTrackFormat` mapping: encoding-name case folding, the clock-rate
//  fallbacks, `a=fmtp` key normalisation, the Base64 `sprop-*` parameter sets (padded, unpadded and
//  hostile), and the typed errors.
//  Covers docs/API_CONTRACT.md §4.7 (`RTPTrackFormatAdapter`) and docs/spec-rtsp.md §8.6.
//

import Foundation
import Testing

import VigilProtocols
@testable import VigilRTP

@Suite struct RTPTrackFormatAdapterBehaviour {

    // MARK: - Vectors

    /// RFC 6184 §8.2.1's worked example, verbatim:
    ///
    ///     a=fmtp:98 profile-level-id=42A01E; packetization-mode=1;
    ///               sprop-parameter-sets=Z0IACpZTBYmI,aMljiA==
    ///
    /// The first element decodes to `67 42 00 0A 96 53 05 89 88` (NAL type 7, SPS) and the second
    /// to `68 C9 63 88` (NAL type 8, PPS).
    static let rfc6184SpropParameterSets = "Z0IACpZTBYmI,aMljiA=="

    /// The same value with the `=` padding stripped, which is the form Hikvision firmware writes
    /// and the form `Data(base64Encoded:)` rejects outright.
    static let rfc6184SpropUnpadded = "Z0IACpZTBYmI,aMljiA"

    static let expectedSPS = Data([0x67, 0x42, 0x00, 0x0A, 0x96, 0x53, 0x05, 0x89, 0x88])
    static let expectedPPS = Data([0x68, 0xC9, 0x63, 0x88])

    /// Synthesised H.265 parameter sets — **not** from a camera. Only the two-byte NAL header
    /// matters to the adapter, and these carry types 32 (VPS), 33 (SPS) and 34 (PPS) with plausible
    /// but meaningless payloads. `VigilBitstream`'s own tests use real parameter sets; this file is
    /// about which field a NAL is filed under, not about parsing it.
    static let syntheticVPS = Data([0x40, 0x01, 0x0C, 0x01, 0xFF, 0xFF])
    static let syntheticSPS = Data([0x42, 0x01, 0x01, 0x01, 0x60, 0x00])
    static let syntheticPPS = Data([0x44, 0x01, 0xC1, 0x73, 0xD1, 0x89])

    static func base64(_ data: Data) -> String { Base64.encode(data) }

    // MARK: - Encoding names

    @Test func rtpTrackFormatAdapterMatchesEncodingNamesCaseInsensitively() throws {
        // Both spellings occur across Hikvision firmware builds.
        for name in ["H264", "h264", "H265", "h265", "HEVC", "hevc"] {
            let format = try RTPTrackFormatAdapter.make(payloadType: 96, encodingName: name,
                                                        clockRate: 90_000)
            #expect(format.isVideo)
            #expect(format.encodingName == name, "the wire spelling must survive for the log line")
        }
        for name in ["MPEG4-GENERIC", "mpeg4-generic"] {
            let format = try RTPTrackFormatAdapter.make(payloadType: 104, encodingName: name,
                                                        clockRate: 16_000, channels: 1)
            #expect(format.codec == .audio(.aac))
            #expect(format.channels == 1)
        }
    }

    @Test func rtpTrackFormatAdapterTrimsWhitespaceAroundTheEncodingName() throws {
        let format = try RTPTrackFormatAdapter.make(payloadType: 96, encodingName: "  H264\t",
                                                    clockRate: 90_000)
        #expect(format.codec == .video(.h264))
        #expect(format.encodingName == "H264")
    }

    @Test func rtpTrackFormatAdapterRejectsAnUnsupportedEncoding() {
        // MP4V-ES is a real Hikvision option on old firmware and Vigil cannot depacketize it. The
        // error must name it, or the user is told "unsupported" with nothing to act on.
        #expect(throws: RTPError.unsupportedEncoding("MP4V-ES")) {
            try RTPTrackFormatAdapter.make(payloadType: 96, encodingName: "MP4V-ES",
                                           clockRate: 90_000)
        }
    }

    @Test func rtpTrackFormatAdapterRejectsADynamicPayloadTypeWithNoRtpmap() {
        // Payload type 96 is dynamic: with no `a=rtpmap` there is nothing to guess from, and
        // guessing H.264 would produce a receiver that emits garbage rather than nothing.
        #expect(throws: RTPError.unsupportedEncoding("payload type 96 with no a=rtpmap")) {
            try RTPTrackFormatAdapter.make(payloadType: 96, encodingName: "", clockRate: 90_000)
        }
    }

    @Test func rtpTrackFormatAdapterUsesTheStaticBindingWhenRtpmapIsAbsent() throws {
        // RFC 3551 payload type 8 is PCMA at 8 kHz, mono. Hikvision audio substreams omit the
        // `a=rtpmap` for it.
        let format = try RTPTrackFormatAdapter.make(payloadType: 8, encodingName: "", clockRate: 0)
        #expect(format.codec == .audio(.g711A))
        #expect(format.clockRate == 8_000)
        #expect(format.channels == 1)
    }

    // MARK: - Clock rate

    @Test func rtpTrackFormatAdapterAppliesTheFixedVideoClockRateWhenTheSDPOmitsIt() throws {
        // `a=rtpmap:96 H264` with no `/90000`. Every RFC defining an H.264 or H.265 payload format
        // fixes the rate at 90 kHz, so an absent rate is knowable, not a failure.
        let format = try RTPTrackFormatAdapter.make(payloadType: 96, encodingName: "H264",
                                                    clockRate: 0)
        #expect(format.clockRate == 90_000)
        #expect(!format.hasUnexpectedVideoClockRate)
    }

    @Test func rtpTrackFormatAdapterAppliesTheCodecSampleRateWhenAudioOmitsIt() throws {
        let format = try RTPTrackFormatAdapter.make(payloadType: 104,
                                                    encodingName: "mpeg4-generic", clockRate: 0)
        #expect(format.clockRate == AudioCodec.aac.defaultSampleRate)
    }

    @Test func rtpTrackFormatAdapterKeepsAStatedClockRateThatDisagreesWithTheRFC() throws {
        // A stated rate is data, not an omission: it is reported as the camera bug it is rather
        // than silently corrected, or the diagnosis would be impossible to make later.
        let format = try RTPTrackFormatAdapter.make(payloadType: 96, encodingName: "H264",
                                                    clockRate: 8_000)
        #expect(format.clockRate == 8_000)
        #expect(format.hasUnexpectedVideoClockRate)
    }

    @Test func rtpTrackFormatAdapterRejectsANegativeClockRate() {
        #expect(throws: RTPError.invalidClockRate(-1)) {
            try RTPTrackFormatAdapter.make(payloadType: 96, encodingName: "H264", clockRate: -1)
        }
    }

    // MARK: - fmtp keys

    @Test func rtpTrackFormatAdapterLowerCasesFmtpKeysAndLeavesValuesAlone() throws {
        let fmtp = ["Packetization-Mode": "1",
                    "SPROP-MAX-DON-DIFF": "2",
                    "profile-level-id": "42A01E"]
        let format = try RTPTrackFormatAdapter.make(payloadType: 96, encodingName: "H264",
                                                    clockRate: 90_000, fmtp: fmtp)
        #expect(format.fmtp["packetization-mode"] == "1")
        #expect(format.fmtp["sprop-max-don-diff"] == "2")
        // Values are case-sensitive: `profile-level-id` is hex and Base64 values are worse.
        #expect(format.fmtp["profile-level-id"] == "42A01E")
        #expect(format.fmtp["Packetization-Mode"] == nil)
    }

    @Test func rtpTrackFormatAdapterNormalisationIsStableForAlreadyLowerCasedKeys() {
        let fmtp = ["packetization-mode": "1", "profile-level-id": "42A01E"]
        #expect(RTPTrackFormatAdapter.normalisedFmtp(fmtp) == fmtp)
    }

    @Test func rtpTrackFormatAdapterResolvesCaseCollidingFmtpKeysDeterministically() {
        // Two keys that differ only in case cannot both survive. Which one wins matters less than
        // that the answer is the same on every run: dictionary iteration order is not stable.
        let fmtp = ["MODE": "a", "mode": "b", "Mode": "c"]
        let first = RTPTrackFormatAdapter.normalisedFmtp(fmtp)
        for _ in 0..<32 {
            #expect(RTPTrackFormatAdapter.normalisedFmtp(fmtp) == first)
        }
        #expect(first.count == 1)
        #expect(first["mode"] == "b")
    }

    // MARK: - H.264 parameter sets

    @Test func rtpTrackFormatAdapterDecodesTheRFC6184SpropParameterSets() throws {
        let fmtp = ["packetization-mode": "1",
                    "sprop-parameter-sets": Self.rfc6184SpropParameterSets]
        let format = try RTPTrackFormatAdapter.make(payloadType: 98, encodingName: "H264",
                                                    clockRate: 90_000, fmtp: fmtp)
        let sets = try #require(format.parameterSets)
        #expect(sets.codec == .h264)
        #expect(sets.sps == [Self.expectedSPS])
        #expect(sets.pps == [Self.expectedPPS])
        #expect(sets.vps.isEmpty)
        #expect(sets.isComplete)
    }

    @Test func rtpTrackFormatAdapterDecodesUnpaddedBase64FromHikvision() throws {
        // The whole reason `VigilProtocols.Base64` exists: Foundation's decoder rejects this value
        // and a rejected SPS is a black stream.
        #expect(Data(base64Encoded: "aMljiA") == nil)
        let fmtp = ["sprop-parameter-sets": Self.rfc6184SpropUnpadded]
        let format = try RTPTrackFormatAdapter.make(payloadType: 98, encodingName: "H264",
                                                    clockRate: 90_000, fmtp: fmtp)
        let sets = try #require(format.parameterSets)
        #expect(sets.sps == [Self.expectedSPS])
        #expect(sets.pps == [Self.expectedPPS])
    }

    @Test func rtpTrackFormatAdapterFilesH264NALsByTheirOwnHeader() throws {
        // The order in the SDP is not authoritative: PPS first, then SPS, then an SEI that must be
        // dropped rather than filed under either.
        let sei = Data([0x06, 0x05, 0x01, 0x00])
        let value = [Self.base64(Self.expectedPPS),
                     Self.base64(Self.expectedSPS),
                     Self.base64(sei)].joined(separator: ",")
        let format = try RTPTrackFormatAdapter.make(payloadType: 98, encodingName: "H264",
                                                    clockRate: 90_000,
                                                    fmtp: ["sprop-parameter-sets": value])
        let sets = try #require(format.parameterSets)
        #expect(sets.sps == [Self.expectedSPS])
        #expect(sets.pps == [Self.expectedPPS])
    }

    @Test func rtpTrackFormatAdapterYieldsEmptyParameterSetsWhenTheSDPCarriesNone() throws {
        // Empty is not nil. Hikvision repeats SPS/PPS in band before every IDR, so a stream with no
        // `sprop-parameter-sets` starts fine — but the codec still *has* parameter sets, and the
        // caller must be able to tell the two apart.
        let format = try RTPTrackFormatAdapter.make(payloadType: 96, encodingName: "H264",
                                                    clockRate: 90_000)
        let sets = try #require(format.parameterSets)
        #expect(sets.sps.isEmpty)
        #expect(sets.pps.isEmpty)
        #expect(!sets.isComplete)
    }

    @Test func rtpTrackFormatAdapterPrefersParameterSetsTheCallerAlreadyDecoded() throws {
        // `VigilRTSP`'s parser decodes `sprop-*` on the way past; re-decoding is wasted work and
        // the caller's value is the one that must win.
        let given = ParameterSets(codec: .h264, sps: [Self.expectedSPS], pps: [Self.expectedPPS])
        let format = try RTPTrackFormatAdapter.make(
            payloadType: 98, encodingName: "H264", clockRate: 90_000,
            fmtp: ["sprop-parameter-sets": Self.base64(Data([0x67, 0xAA]))],
            parameterSets: given)
        #expect(format.parameterSets == given)
    }

    // MARK: - H.265 parameter sets

    @Test func rtpTrackFormatAdapterDecodesTheThreeH265SpropFields() throws {
        let fmtp = ["sprop-vps": Self.base64(Self.syntheticVPS),
                    "sprop-sps": Self.base64(Self.syntheticSPS),
                    "sprop-pps": Self.base64(Self.syntheticPPS),
                    "sprop-max-don-diff": "0"]
        let format = try RTPTrackFormatAdapter.make(payloadType: 96, encodingName: "H265",
                                                    clockRate: 90_000, fmtp: fmtp)
        let sets = try #require(format.parameterSets)
        #expect(sets.codec == .h265)
        #expect(sets.vps == [Self.syntheticVPS])
        #expect(sets.sps == [Self.syntheticSPS])
        #expect(sets.pps == [Self.syntheticPPS])
    }

    @Test func rtpTrackFormatAdapterDropsAnH265NALFiledUnderTheWrongSpropField() throws {
        // A camera that puts an SPS in `sprop-pps` has told us nothing trustworthy about it, and a
        // PPS slot holding an SPS produces a format description CoreMedia refuses.
        let fmtp = ["sprop-vps": Self.base64(Self.syntheticVPS),
                    "sprop-sps": Self.base64(Self.syntheticSPS),
                    "sprop-pps": Self.base64(Self.syntheticSPS)]
        let format = try RTPTrackFormatAdapter.make(payloadType: 96, encodingName: "H265",
                                                    clockRate: 90_000, fmtp: fmtp)
        let sets = try #require(format.parameterSets)
        #expect(sets.sps == [Self.syntheticSPS])
        #expect(sets.pps.isEmpty)
    }

    @Test func rtpTrackFormatAdapterReadsH265SpropFieldsUnderUpperCasedKeys() throws {
        let fmtp = ["SPROP-VPS": Self.base64(Self.syntheticVPS),
                    "Sprop-Sps": Self.base64(Self.syntheticSPS),
                    "sprop-PPS": Self.base64(Self.syntheticPPS)]
        let format = try RTPTrackFormatAdapter.make(payloadType: 96, encodingName: "h265",
                                                    clockRate: 90_000, fmtp: fmtp)
        let sets = try #require(format.parameterSets)
        #expect(sets.vps == [Self.syntheticVPS])
        #expect(sets.sps == [Self.syntheticSPS])
        #expect(sets.pps == [Self.syntheticPPS])
    }

    // MARK: - Malformed and hostile input

    @Test func rtpTrackFormatAdapterSkipsSpropElementsThatDoNotDecode() throws {
        // One good element among rubbish must still reach the depacketizer; the rest are dropped
        // and the stream starts from the in-band sets.
        let value = "!!!!," + Self.base64(Self.expectedSPS) + ",,Z"
        let format = try RTPTrackFormatAdapter.make(payloadType: 98, encodingName: "H264",
                                                    clockRate: 90_000,
                                                    fmtp: ["sprop-parameter-sets": value])
        let sets = try #require(format.parameterSets)
        #expect(sets.sps == [Self.expectedSPS])
        #expect(sets.pps.isEmpty)
    }

    @Test func rtpTrackFormatAdapterSurvivesDegenerateSpropValues() throws {
        for value in ["", ",", ",,,", "   ", "=", "===="] {
            let format = try RTPTrackFormatAdapter.make(payloadType: 98, encodingName: "H264",
                                                        clockRate: 90_000,
                                                        fmtp: ["sprop-parameter-sets": value])
            let sets = try #require(format.parameterSets)
            #expect(sets.sps.isEmpty, "value \(value) must not produce an SPS")
            #expect(sets.pps.isEmpty, "value \(value) must not produce a PPS")
        }
    }

    @Test func rtpTrackFormatAdapterKeepsAOneByteH265NALThatCarriesAValidType() throws {
        // The type field lives in the first header byte, so a NAL truncated to one byte is still
        // classifiable. Refusing it here would be stricter than the bitstream layer, which is the
        // component that owns that judgement.
        let truncated = Data([0x42])
        let format = try RTPTrackFormatAdapter.make(payloadType: 96, encodingName: "H265",
                                                    clockRate: 90_000,
                                                    fmtp: ["sprop-sps": Self.base64(truncated)])
        let sets = try #require(format.parameterSets)
        #expect(sets.sps == [truncated])
    }

    @Test func rtpTrackFormatAdapterReturnsNoParameterSetsForAudio() throws {
        let format = try RTPTrackFormatAdapter.make(
            payloadType: 104, encodingName: "mpeg4-generic", clockRate: 16_000, channels: 1,
            fmtp: ["config": "1408", "sprop-parameter-sets": Self.rfc6184SpropParameterSets])
        #expect(format.parameterSets == nil)
    }

    // MARK: - The seam this closes

    @Test func rtpTrackFormatAdapterProducesADepacketizerCarryingTheSDPParameterSets() throws {
        // The failure this whole file exists to prevent: the app parses the camera's SDP and then
        // cannot build a depacketizer.
        let fmtp = ["packetization-mode": "1",
                    "sprop-parameter-sets": Self.rfc6184SpropParameterSets]
        let format = try RTPTrackFormatAdapter.make(payloadType: 98, encodingName: "h264",
                                                    clockRate: 90_000, fmtp: fmtp)
        let depacketizer = try DepacketizerFactory.make(for: format)
        #expect(depacketizer.codec == .video(.h264))
        #expect(depacketizer.clockRate == 90_000)
        guard case .h264(let h264) = depacketizer else {
            Issue.record("expected the H.264 depacketizer")
            return
        }
        #expect(h264.parameterSets.sps == [Self.expectedSPS])
        #expect(h264.parameterSets.pps == [Self.expectedPPS])
    }

    @Test func rtpTrackFormatAdapterSwitchesTheH265DepacketizerToDONLWhenAsked() throws {
        // `sprop-max-don-diff` changes the layout of every FU and AP, and it arrives under whatever
        // case the camera wrote. Losing it to a case-sensitive lookup scrambles the video.
        let format = try RTPTrackFormatAdapter.make(payloadType: 96, encodingName: "H265",
                                                    clockRate: 90_000,
                                                    fmtp: ["SPROP-MAX-DON-DIFF": "1"])
        #expect(format.fmtpValue("sprop-max-don-diff") == "1")
        let depacketizer = try DepacketizerFactory.make(for: format)
        guard case .h265(let h265) = depacketizer else {
            Issue.record("expected the H.265 depacketizer")
            return
        }
        #expect(h265.usesDONL)
    }
}
