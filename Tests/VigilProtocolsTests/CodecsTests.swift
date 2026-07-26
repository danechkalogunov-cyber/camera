//
//  CodecsTests.swift
//  VigilProtocolsTests
//
//  The three codec enums: NAL header widths, the decode-weight table fixed by API_CONTRACT §2 R-58,
//  the audio muxing and pure-decode predicates, and the flat union's accessors.
//  Covers docs/API_CONTRACT.md §3.4.
//

import Foundation
import Testing
import VigilProtocols

@Suite struct VideoCodecTests {

    @Test func videoCodecNALHeaderLengthMatchesTheCodec() {
        // H.264 has a 1-byte NAL header (ITU-T H.264 §7.3.1); H.265 has 2 (H.265 §7.3.1.2).
        #expect(VideoCodec.h264.nalHeaderLength == 1)
        #expect(VideoCodec.h265.nalHeaderLength == 2)
        #expect(VideoCodec.mjpeg.nalHeaderLength == 0)
    }

    @Test func videoCodecIsNALBasedExcludesMJPEG() {
        #expect(VideoCodec.h264.isNALBased)
        #expect(VideoCodec.h265.isNALBased)
        #expect(!VideoCodec.mjpeg.isNALBased)
    }

    @Test func videoCodecDecodeWeightMatchesTheRuling() {
        // API_CONTRACT §2 R-58 fixes these three numbers; the Main10 surcharge is DecodeCost's.
        #expect(VideoCodec.h264.decodeWeight == 1.00)
        #expect(VideoCodec.h265.decodeWeight == 1.35)
        #expect(VideoCodec.mjpeg.decodeWeight == 0.45)
    }

    @Test func videoCodecHasExactlyThreeCasesAndNoUnknown() {
        #expect(VideoCodec.allCases.count == 3)
        #expect(VideoCodec(rawValue: "unknown") == nil)
        #expect(VideoCodec(rawValue: "h265") == .h265)
    }

    @Test func videoCodecEncodesAsItsLowercaseRawValue() throws {
        let encoded = try JSONEncoder().encode(VideoCodec.h265)
        #expect(String(decoding: encoded, as: UTF8.self) == "\"h265\"")
    }
}

@Suite struct AudioCodecTests {

    @Test func audioCodecOnlyAACIsMP4Muxable() {
        #expect(AudioCodec.aac.isMP4Muxable)
        for codec in AudioCodec.allCases where codec != .aac {
            #expect(!codec.isMP4Muxable, "\(codec) must force a .mov container")
        }
    }

    @Test func audioCodecDecodedInPureLayerCoversG711AndG726Only() {
        #expect(AudioCodec.g711A.isDecodedInPureLayer)
        #expect(AudioCodec.g711U.isDecodedInPureLayer)
        #expect(AudioCodec.g726.isDecodedInPureLayer)
        #expect(!AudioCodec.aac.isDecodedInPureLayer)
        #expect(!AudioCodec.pcmS16LE.isDecodedInPureLayer, "PCM is the output, not an input")
    }

    @Test func audioCodecDefaultSampleRates() {
        #expect(AudioCodec.aac.defaultSampleRate == 16_000)
        #expect(AudioCodec.g726.defaultSampleRate == 8_000)
        #expect(AudioCodec.g711A.defaultSampleRate == 8_000)
        #expect(AudioCodec.g711U.defaultSampleRate == 8_000)
        #expect(AudioCodec.pcmS16LE.defaultSampleRate == 8_000)
    }

    @Test func audioCodecHasFiveCases() {
        #expect(AudioCodec.allCases.count == 5)
        #expect(AudioCodec(rawValue: "g711A") == .g711A)
    }
}

@Suite struct MediaCodecTests {

    @Test func mediaCodecAccessorsSelectTheRightSide() {
        let video = MediaCodec.video(.h265)
        let audio = MediaCodec.audio(.aac)
        #expect(video.video == .h265)
        #expect(video.audio == nil)
        #expect(video.isVideo)
        #expect(audio.audio == .aac)
        #expect(audio.video == nil)
        #expect(!audio.isVideo)
    }

    @Test func mediaCodecMJPEGIsStillVideo() {
        #expect(MediaCodec.video(.mjpeg).isVideo)
        #expect(MediaCodec.video(.mjpeg).video?.isNALBased == false)
    }

    @Test func mediaCodecDescriptionIsTheUnderlyingRawValue() {
        #expect(MediaCodec.video(.h264).description == "h264")
        #expect(MediaCodec.audio(.pcmS16LE).description == "pcmS16LE")
    }

    @Test func mediaCodecRoundTripsThroughCodable() throws {
        for codec in [MediaCodec.video(.h265), .audio(.g711A)] {
            let encoded = try JSONEncoder().encode(codec)
            #expect(try JSONDecoder().decode(MediaCodec.self, from: encoded) == codec)
        }
    }

    @Test func mediaCodecDistinguishesVideoFromAudioWithTheSameName() {
        #expect(MediaCodec.video(.h264) != MediaCodec.video(.h265))
        #expect(MediaCodec.video(.h264).hashValue == MediaCodec.video(.h264).hashValue)
    }
}
