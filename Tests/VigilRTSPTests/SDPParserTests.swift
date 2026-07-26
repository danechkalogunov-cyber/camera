//
//  SDPParserTests.swift
//  VigilRTSPTests
//
//  The SDP parser against the two real Hikvision session descriptions in docs/spec-rtsp.md §8.8
//  and §8.9, plus the malformed and vendor-specific shapes that must not fail a parse.
//

import Foundation
import Testing
import VigilProtocols
@testable import VigilRTSP

/// Fixture bodies. The two full descriptions are copied byte for byte from docs/spec-rtsp.md §8.8
/// (DS-2CD2043G2-I camera, H.264 + AAC) and §8.9 (DS-7608NI-K2 NVR, H.265 + G.711); the decoded
/// parameter-set hex in the assertions is the spec's own table.
enum SDPWireFixture {

    static let cameraH264AAC = """
        v=0
        o=- 1109162014219182 1109162014219182 IN IP4 192.168.1.64
        s=Media Presentation
        e=NONE
        b=AS:5100
        t=0 0
        a=control:rtsp://192.168.1.64:554/Streaming/Channels/101/
        a=range:npt=now-
        a=appversion:1.0
        m=video 0 RTP/AVP 96
        c=IN IP4 0.0.0.0
        b=AS:5000
        a=recvonly
        a=x-dimensions:1920,1080
        a=control:rtsp://192.168.1.64:554/Streaming/Channels/101/trackID=1
        a=rtpmap:96 H264/90000
        a=fmtp:96 profile-level-id=640028; packetization-mode=1; \
        sprop-parameter-sets=Z2QAKKzZQHgCJ+WEAAADAAQAAAMAwjxgySA=,aO48sA==
        a=Media_header:MEDIAINFO=494D4B480102000004000001000000000000000000000000000000000000\
        0000000000000000;
        a=appversion:1.0
        m=audio 0 RTP/AVP 104
        c=IN IP4 0.0.0.0
        b=AS:50
        a=recvonly
        a=control:rtsp://192.168.1.64:554/Streaming/Channels/101/trackID=2
        a=rtpmap:104 mpeg4-generic/16000/1
        a=fmtp:104 streamtype=5;profile-level-id=1;mode=AAC-hbr;sizelength=13;indexlength=3;\
        indexdeltalength=3;config=1408
        a=appversion:1.0
        """

    static let nvrH265PCMA = """
        v=0
        o=- 1109162014219182 1109162014219182 IN IP4 192.168.1.200
        s=Media Presentation
        e=NONE
        b=AS:5100
        t=0 0
        a=control:*
        a=range:npt=now-
        m=video 0 RTP/AVP 98
        c=IN IP4 0.0.0.0
        b=AS:5000
        a=recvonly
        a=x-dimensions:1920,1080
        a=control:trackID=1
        a=rtpmap:98 H265/90000
        a=fmtp:98 profile-space=0;profile-id=1;tier-flag=0;level-id=120;\
        interop-constraints=000000000000;sprop-vps=QAEMAf//AWAAAAMAsAAAAwAAAwBdlZgJ;\
        sprop-sps=QgEBAWAAAAMAsAAAAwAAAwBdoAKAgC0WWVmkkyuAQEAAAAMAQAAAB4I=;\
        sprop-pps=RAHBcrRiQA==
        a=Media_header:MEDIAINFO=494D4B480102000004000001000000000000000000000000000000000000\
        0000000000000000;
        a=appversion:1.0
        m=audio 0 RTP/AVP 8
        c=IN IP4 0.0.0.0
        b=AS:64
        a=recvonly
        a=control:trackID=2
        a=rtpmap:8 PCMA/8000
        a=Media_header:MEDIAINFO=494D4B480202000000000000000000000000000000000000000000000000\
        0000000000000000;
        a=appversion:1.0
        """

    /// CRLF, as it arrives on the wire.
    static func wire(_ text: String) -> Data {
        Data(text.split(separator: "\n", omittingEmptySubsequences: false)
            .joined(separator: "\r\n").utf8)
    }

    static func hex(_ bytes: Data) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }
}

@Suite struct SDPParserSuite {

    // MARK: - The two real descriptions

    @Test func sdpParserReadsHikvisionCameraDescription() throws {
        let document = try SDPParser.parse(SDPWireFixture.wire(SDPWireFixture.cameraH264AAC))

        #expect(document.version == 0)
        #expect(document.sessionName == "Media Presentation")
        #expect(document.bandwidthKbps == 5100)
        #expect(document.rangeText == "npt=now-")
        #expect(document.sessionControl == "rtsp://192.168.1.64:554/Streaming/Channels/101/")
        #expect(document.media.count == 2)

        let video = try #require(document.media.first)
        #expect(video.kind == .video)
        #expect(video.payloadType == 96)
        #expect(video.encodingName == "H264")
        #expect(video.clockRate == 90_000)
        #expect(video.codec == .video(.h264))
        #expect(video.packetizationMode == 1)
        #expect(video.fmtp["profile-level-id"] == "640028")
        #expect(video.control == "rtsp://192.168.1.64:554/Streaming/Channels/101/trackID=1")
        #expect(video.hintedDimensions == Resolution(width: 1920, height: 1080))
        #expect(video.direction == .recvonly)
        #expect(video.bandwidthKbps == 5000)

        // docs/spec-rtsp.md §8.8: SPS 26 bytes, PPS 4 bytes, with these exact hex values.
        let sets = try #require(video.parameterSets)
        #expect(sets.codec == .h264)
        #expect(sets.sps.count == 1)
        #expect(sets.pps.count == 1)
        #expect(SDPWireFixture.hex(sets.sps[0])
            == "67640028ACD940780227E584000003000400000300C23C60C920")
        #expect(SDPWireFixture.hex(sets.pps[0]) == "68EE3CB0")
        #expect(sets.sps[0].count == 26)
        #expect(sets.pps[0].count == 4)

        let audio = try #require(document.media.last)
        #expect(audio.kind == .audio)
        #expect(audio.payloadType == 104)
        #expect(audio.encodingName == "mpeg4-generic")
        #expect(audio.clockRate == 16_000)
        #expect(audio.channels == 1)
        #expect(audio.codec == .audio(.aac))
        #expect(audio.fmtp["mode"] == "AAC-hbr")
        #expect(audio.aacConfig == [0x14, 0x08])
        #expect(audio.parameterSets == nil)
    }

    @Test func sdpParserReadsHikvisionNVRDescription() throws {
        let document = try SDPParser.parse(SDPWireFixture.wire(SDPWireFixture.nvrH265PCMA))

        #expect(document.sessionControl == "*")
        #expect(document.media.count == 2)

        let video = try #require(document.media.first)
        #expect(video.payloadType == 98)
        #expect(video.encodingName == "H265")
        #expect(video.clockRate == 90_000)
        #expect(video.codec == .video(.h265))
        #expect(video.control == "trackID=1")
        #expect(video.fmtp["level-id"] == "120")

        // docs/spec-rtsp.md §8.9: VPS 24 bytes, SPS 41 bytes, PPS 7 bytes.
        let sets = try #require(video.parameterSets)
        #expect(sets.codec == .h265)
        #expect(SDPWireFixture.hex(sets.vps[0])
            == "40010C01FFFF016000000300B0000003000003005D959809")
        #expect(SDPWireFixture.hex(sets.sps[0]) == "420101016000000300B0000003000003005DA00280802D"
            + "165959A4932B804040000003004000000782")
        #expect(SDPWireFixture.hex(sets.pps[0]) == "4401C172B46240")
        #expect(sets.vps[0].count == 24)
        #expect(sets.sps[0].count == 41)
        #expect(sets.pps[0].count == 7)

        // Static payload type 8 with an rtpmap that omits the channel count.
        let audio = try #require(document.media.last)
        #expect(audio.payloadType == 8)
        #expect(audio.encodingName == "PCMA")
        #expect(audio.clockRate == 8_000)
        #expect(audio.codec == .audio(.g711A))
        #expect(audio.control == "trackID=2")
    }

    // MARK: - Parameter-set edge cases

    @Test func sdpParserDecodesUnpaddedSpropIdenticallyToPadded() throws {
        // `aO48sA==` unpadded is `aO48sA`; the H.264 SPS's single `=` is dropped the same way.
        let padded = try SDPParser.parse(SDPWireFixture.wire(SDPWireFixture.cameraH264AAC))
        let unpaddedText = SDPWireFixture.cameraH264AAC
            .replacingOccurrences(of: "Z2QAKKzZQHgCJ+WEAAADAAQAAAMAwjxgySA=,aO48sA==",
                                  with: "Z2QAKKzZQHgCJ+WEAAADAAQAAAMAwjxgySA,aO48sA")
        let unpadded = try SDPParser.parse(SDPWireFixture.wire(unpaddedText))

        let a = try #require(padded.media.first?.parameterSets)
        let b = try #require(unpadded.media.first?.parameterSets)
        #expect(a == b)
        #expect(b.sps.first?.count == 26)
        #expect(b.pps.first?.count == 4)
    }

    @Test func sdpParserAcceptsVideoWithNoSpropAtAll() throws {
        let text = """
            v=0
            s=Media Presentation
            m=video 0 RTP/AVP 96
            a=control:trackID=1
            a=rtpmap:96 H264/90000
            a=fmtp:96 profile-level-id=4D001E;packetization-mode=1
            """
        let document = try SDPParser.parse(SDPWireFixture.wire(text))
        let video = try #require(document.media.first)
        let sets = try #require(video.parameterSets)   // present, and empty — not an error.
        #expect(sets.sps.isEmpty)
        #expect(sets.pps.isEmpty)
        #expect(sets.vps.isEmpty)
        #expect(sets.isComplete == false)
        #expect(video.codec == .video(.h264))
    }

    @Test func sdpParserSkipsUndecodableSpropWithoutFailing() throws {
        let text = """
            v=0
            m=video 0 RTP/AVP 96
            a=rtpmap:96 H264/90000
            a=fmtp:96 sprop-parameter-sets=!!!not-base64!!!,aO48sA==
            """
        let document = try SDPParser.parse(SDPWireFixture.wire(text))
        let sets = try #require(document.media.first?.parameterSets)
        #expect(sets.sps.isEmpty)
        #expect(sets.pps.count == 1)          // The decodable half still arrives.
    }

    // MARK: - Vendor extras and malformed input

    @Test func sdpParserIgnoresHikvisionPrivateAttributes() throws {
        let document = try SDPParser.parse(SDPWireFixture.wire(SDPWireFixture.cameraH264AAC))
        let video = try #require(document.media.first)
        // a=Media_header and a=appversion are retained for logging but never fail the parse and
        // never become a track property.
        #expect(video.attributes.contains { $0.name == "media_header" })
        #expect(video.attributes.contains { $0.name == "appversion" })
        #expect(document.unknownLines.isEmpty)
    }

    @Test func sdpParserStripsTrailingNulCountedInContentLength() throws {
        var body = SDPWireFixture.wire(SDPWireFixture.cameraH264AAC)
        body.append(contentsOf: [0x00])       // Hikvision 5.4.x, counted in Content-Length.
        let document = try SDPParser.parse(body)
        #expect(document.media.count == 2)
        #expect(document.unknownLines.isEmpty)
    }

    @Test func sdpParserAcceptsBareLFLineEndings() throws {
        let document = try SDPParser.parse(Data(SDPWireFixture.cameraH264AAC.utf8))
        #expect(document.media.count == 2)
        #expect(document.media.first?.encodingName == "H264")
    }

    @Test func sdpParserSurvivesNonUTF8SessionName() throws {
        var body = Data("v=0\r\ns=".utf8)
        body.append(contentsOf: [0xC0, 0xC1])  // Never valid UTF-8.
        body.append(contentsOf: Data("\r\nm=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\n".utf8))
        let document = try SDPParser.parse(body)
        #expect(document.media.count == 1)
        #expect(document.sessionName?.isEmpty == false)
    }

    @Test func sdpParserUsesStaticPayloadTypeWhenRtpmapIsAbsent() throws {
        let text = """
            v=0
            m=audio 0 RTP/AVP 8
            a=control:trackID=2
            """
        let document = try SDPParser.parse(SDPWireFixture.wire(text))
        let audio = try #require(document.media.first)
        #expect(audio.encodingName == "PCMA")
        #expect(audio.clockRate == 8_000)
        #expect(audio.channels == 1)
        #expect(audio.codec == .audio(.g711A))
    }

    @Test func sdpParserPicksTheFirstSupportedPayloadTypeOffered() throws {
        let text = """
            v=0
            m=video 0 RTP/AVP 100 96
            a=rtpmap:100 MP4V-ES/90000
            a=rtpmap:96 H264/90000
            a=fmtp:96 packetization-mode=1
            """
        let document = try SDPParser.parse(SDPWireFixture.wire(text))
        let video = try #require(document.media.first)
        #expect(video.formats == [100, 96])
        #expect(video.payloadType == 96)      // MP4V-ES is offered first but cannot be decoded.
        #expect(video.codec == .video(.h264))
    }

    @Test func sdpParserKeepsTheLastDuplicateControlAttribute() throws {
        let text = """
            v=0
            m=video 0 RTP/AVP 96
            a=control:trackID=9
            a=rtpmap:96 H264/90000
            a=control:trackID=1
            """
        let document = try SDPParser.parse(SDPWireFixture.wire(text))
        #expect(document.media.first?.control == "trackID=1")
    }

    @Test func sdpParserRejectsBodyWithNoMediaSection() {
        let text = "v=0\r\no=- 1 1 IN IP4 1.2.3.4\r\ns=Media Presentation\r\n"
        #expect(throws: RTSPError.sdpParse("no m= media section")) {
            try SDPParser.parse(Data(text.utf8))
        }
    }

    @Test func sdpParserRejectsEmptyBody() {
        #expect(throws: RTSPError.sdpParse("empty SDP body")) {
            try SDPParser.parse(Data())
        }
    }

    @Test func sdpParserKeepsLinesWithoutAnEqualsSignAsUnknown() throws {
        let text = """
            v=0
            this line has no equals sign
            m=video 0 RTP/AVP 96
            a=rtpmap:96 H264/90000
            """
        let document = try SDPParser.parse(SDPWireFixture.wire(text))
        #expect(document.unknownLines == ["this line has no equals sign"])
        #expect(document.media.count == 1)
    }

    @Test func sdpParserLowercasesFmtpKeysAndPreservesValueCase() throws {
        let text = """
            v=0
            m=video 0 RTP/AVP 96
            a=rtpmap:96 H264/90000
            a=fmtp:96 Packetization-Mode=1;SPROP-PARAMETER-SETS=aO48sA==
            """
        let document = try SDPParser.parse(SDPWireFixture.wire(text))
        let video = try #require(document.media.first)
        #expect(video.fmtp["packetization-mode"] == "1")
        #expect(video.fmtp["sprop-parameter-sets"] == "aO48sA==")   // Base64 is case-sensitive.
    }
}
