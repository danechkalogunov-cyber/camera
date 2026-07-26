//
//  SyntheticServerTests.swift
//  VigilPipelineTests
//
//  Tests of the RTSP half of the synthetic camera: the request/response conversation, the 401
//  Digest challenge and its verification, and the SDP — read back with the real `SDPParser` so a
//  fixture that emits an SDP only it can understand cannot pass.
//

import Foundation
import Testing
import VigilBitstream
import VigilProtocols
import VigilRTSP
import VigilTestKit

// MARK: - Helpers

private enum ServerFixture {

    /// Sends `text` as one write and returns the response as a string.
    static func exchange(_ server: inout SyntheticRTSPServer, _ text: String) -> String {
        String(decoding: server.ingest(Data(text.utf8)), as: UTF8.self)
    }

    /// A minimal request block with CRLF line endings.
    static func request(_ method: String, _ uri: String, cseq: Int,
                        headers: [String: String] = [:]) -> String {
        var text = "\(method) \(uri) RTSP/1.0\r\nCSeq: \(cseq)\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            text += "\(name): \(value)\r\n"
        }
        return text + "\r\n"
    }

    /// The status code on the first line of a response block.
    static func status(_ response: String) -> Int? {
        let line = response.split(separator: "\r\n", maxSplits: 1).first ?? ""
        let parts = line.split(separator: " ")
        return parts.count >= 2 ? Int(parts[1]) : nil
    }

    /// The value of `name` in a response block.
    static func header(_ response: String, _ name: String) -> String? {
        for line in response.split(separator: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[line.startIndex..<colon].lowercased() == name.lowercased() {
                return String(line[line.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// The body after the blank line.
    static func body(_ response: String) -> String {
        guard let range = response.range(of: "\r\n\r\n") else { return "" }
        return String(response[range.upperBound...])
    }
}

// MARK: - Conversation

@Suite struct SyntheticServerConversationSuite {

    @Test func serverAnswersOptionsWithThePublicHeader() {
        var server = SyntheticRTSPServer(profile: .hevcCamera())
        let response = ServerFixture.exchange(&server, ServerFixture.request(
            "OPTIONS", "rtsp://192.0.2.10/Streaming/Channels/101", cseq: 1))
        #expect(ServerFixture.status(response) == 200)
        #expect(ServerFixture.header(response, "CSeq") == "1")
        #expect(ServerFixture.header(response, "Public")?.contains("DESCRIBE") == true)
        #expect(server.receivedRequests.count == 1)
    }

    @Test func serverChallengesDescribeBeforeAuthenticating() {
        var server = SyntheticRTSPServer(profile: .hevcCamera())
        let response = ServerFixture.exchange(&server, ServerFixture.request(
            "DESCRIBE", "rtsp://192.0.2.10/Streaming/Channels/101", cseq: 2))
        #expect(ServerFixture.status(response) == 401)
        let challenge = ServerFixture.header(response, "WWW-Authenticate") ?? ""
        #expect(challenge.hasPrefix("Digest"))
        #expect(challenge.contains("qop=\"auth\""))
        #expect(server.challengeCount == 1)
    }

    @Test func serverOffersNoQopChallengeForRFC2069Firmware() {
        var server = SyntheticRTSPServer(profile: .ds2cd2143g2())
        let response = ServerFixture.exchange(&server, ServerFixture.request(
            "DESCRIBE", "rtsp://192.0.2.10/Streaming/Channels/101", cseq: 2))
        let challenge = ServerFixture.header(response, "WWW-Authenticate") ?? ""
        #expect(challenge.hasPrefix("Digest"))
        #expect(!challenge.contains("qop"))
    }

    /// A request written one byte at a time must produce exactly one response.
    @Test func serverAccumulatesARequestDeliveredOneByteAtATime() {
        var server = SyntheticRTSPServer(profile: .hevcCamera())
        let text = ServerFixture.request("OPTIONS", "rtsp://192.0.2.10/x", cseq: 1)
        var responses = Data()
        for byte in Array(text.utf8) {
            responses.append(server.ingest(Data([byte])))
        }
        #expect(server.receivedRequests.count == 1)
        #expect(ServerFixture.status(String(decoding: responses, as: UTF8.self)) == 200)
    }

    /// Two requests in one write produce two responses, in order.
    @Test func serverHandlesTwoRequestsInOneWrite() {
        var server = SyntheticRTSPServer(profile: .hevcCamera())
        let text = ServerFixture.request("OPTIONS", "rtsp://192.0.2.10/x", cseq: 1)
            + ServerFixture.request("OPTIONS", "rtsp://192.0.2.10/x", cseq: 2)
        _ = server.ingest(Data(text.utf8))
        #expect(server.receivedRequests.count == 2)
        #expect(server.receivedRequests.map(\.cseq) == ["1", "2"])
    }

    @Test func serverAnswersGetParameterOrRefusesItPerProfile() {
        var supported = SyntheticRTSPServer(profile: .hevcCamera())
        var unsupported = SyntheticRTSPServer(
            profile: {
                var profile = SyntheticCameraProfile.hevcCamera()
                profile.supportsGetParameter = false
                profile.authMode = .none
                return profile
            }()
        )
        var open = SyntheticCameraProfile.hevcCamera()
        open.authMode = .none
        supported = SyntheticRTSPServer(profile: open)
        let ok = ServerFixture.exchange(&supported,
                                        ServerFixture.request("GET_PARAMETER", "rtsp://h/x", cseq: 9))
        #expect(ServerFixture.status(ok) == 200)
        let refused = ServerFixture.exchange(
            &unsupported, ServerFixture.request("GET_PARAMETER", "rtsp://h/x", cseq: 9))
        #expect(ServerFixture.status(refused) == 501)
    }

    @Test func serverReachesPlayingThroughTheFullHandshake() {
        var profile = SyntheticCameraProfile.hevcCamera()
        profile.authMode = .none
        var server = SyntheticRTSPServer(profile: profile)
        _ = ServerFixture.exchange(&server, ServerFixture.request("OPTIONS", "rtsp://h/x", cseq: 1))
        _ = ServerFixture.exchange(&server, ServerFixture.request("DESCRIBE", "rtsp://h/x", cseq: 2))
        #expect(server.state == .described)
        let setup = ServerFixture.exchange(&server, ServerFixture.request(
            "SETUP", "rtsp://h/x/trackID=1", cseq: 3,
            headers: ["Transport": "RTP/AVP/TCP;unicast;interleaved=0-1"]))
        #expect(server.state == .setUp)
        #expect(ServerFixture.header(setup, "Transport")?.contains("interleaved=0-1") == true)
        #expect(ServerFixture.header(setup, "Session")?.contains("timeout=60") == true)
        let play = ServerFixture.exchange(&server, ServerFixture.request("PLAY", "rtsp://h/x", cseq: 4))
        #expect(server.state == .playing)
        let info = ServerFixture.header(play, "RTP-Info") ?? ""
        #expect(info.contains("seq=\(server.firstSequenceNumber)"))
        #expect(info.contains("rtptime=\(server.firstRTPTimestamp)"))
        _ = ServerFixture.exchange(&server, ServerFixture.request("TEARDOWN", "rtsp://h/x", cseq: 5))
        #expect(server.state == .tornDown)
    }

    @Test func serverEmitsInterleavedMediaOnlyWhilePlaying() {
        var profile = SyntheticCameraProfile.hevcCamera()
        profile.authMode = .none
        var server = SyntheticRTSPServer(profile: profile)
        #expect(server.tick(nowNanos: 1_000_000_000).isEmpty)
        _ = ServerFixture.exchange(&server, ServerFixture.request("DESCRIBE", "rtsp://h/x", cseq: 1))
        _ = ServerFixture.exchange(&server, ServerFixture.request(
            "SETUP", "rtsp://h/x", cseq: 2,
            headers: ["Transport": "RTP/AVP/TCP;unicast;interleaved=0-1"]))
        _ = ServerFixture.exchange(&server, ServerFixture.request("PLAY", "rtsp://h/x", cseq: 3))
        let media = server.tick(nowNanos: 2_000_000_000)
        #expect(!media.isEmpty)
        #expect(media.first == 0x24, "media must be framed with the interleave magic")
        #expect(server.sentAccessUnitCount > 0)
    }

    /// Same seed, same bytes — otherwise a failing run is not replayable.
    @Test func serverIsByteIdenticalForAGivenSeed() {
        func transcript(seed: UInt64) -> Data {
            var profile = SyntheticCameraProfile.hevcCamera(seed: seed)
            profile.authMode = .none
            var server = SyntheticRTSPServer(profile: profile)
            var out = Data()
            out.append(server.ingest(Data(ServerFixture.request("DESCRIBE", "rtsp://h/x",
                                                               cseq: 1).utf8)))
            out.append(server.ingest(Data(ServerFixture.request("SETUP", "rtsp://h/x", cseq: 2)
                .utf8)))
            out.append(server.ingest(Data(ServerFixture.request("PLAY", "rtsp://h/x", cseq: 3).utf8)))
            out.append(server.tick(nowNanos: 500_000_000))
            return out
        }
        #expect(transcript(seed: 7) == transcript(seed: 7))
        #expect(transcript(seed: 7) != transcript(seed: 8))
    }
}

// MARK: - Digest

@Suite struct SyntheticServerDigestSuite {

    /// RFC 2617 §3.5 worked example: the published vector, computed by the fixture's own helper.
    /// Cited rather than synthesised so a change in the MD5 implementation is caught here.
    @Test func serverDigestMatchesRFC2617Section35() {
        let response = SyntheticDigest.responseQopAuth(
            username: "Mufasa", realm: "testrealm@host.com", password: "Circle Of Life",
            method: "GET", uri: "/dir/index.html", nonce: "dcd98b7102dd2f0e8b11d0f600bfb0c093",
            nonceCount: "00000001", cnonce: "0a4f113b"
        )
        #expect(response == "6629fae49393a05397450978507c4ef1")
    }

    /// RFC 2069 §2.4 worked example, the no-qop form Hikvision uses by default.
    @Test func serverDigestMatchesRFC2069Section24() {
        let response = SyntheticDigest.responseNoQop(
            username: "Mufasa", realm: "testrealm@host.com", password: "CircleOfLife",
            method: "GET", uri: "/dir/index.html", nonce: "dcd98b7102dd2f0e8b11d0f600bfb0c093"
        )
        #expect(response == "1949323746fe6a43ef61f9606e7febea")
    }

    @Test func serverDigestParametersToleratesACommaInsideAQuotedRealm() {
        let parsed = SyntheticDigest.parseParameters(
            "username=\"admin\", realm=\"IP Camera(C1234), main\", nc=00000001, qop=auth")
        #expect(parsed["realm"] == "IP Camera(C1234), main")
        #expect(parsed["nc"] == "00000001")
        #expect(parsed["qop"] == "auth")
        #expect(parsed["username"] == "admin")
    }

    @Test func serverAcceptsACorrectNoQopDigest() {
        let profile = SyntheticCameraProfile.ds2cd2143g2()
        var server = SyntheticRTSPServer(profile: profile)
        let challenge = ServerFixture.exchange(&server, ServerFixture.request(
            "DESCRIBE", "rtsp://192.0.2.10/s", cseq: 1))
        let parameters = SyntheticDigest.parseParameters(
            ServerFixture.header(challenge, "WWW-Authenticate")?.dropFirst("Digest".count)
                .description ?? "")
        let nonce = parameters["nonce"] ?? ""
        let uri = "rtsp://192.0.2.10/s"
        let response = SyntheticDigest.responseNoQop(
            username: profile.username, realm: profile.realm, password: profile.password,
            method: "DESCRIBE", uri: uri, nonce: nonce)
        let authorization = "Digest username=\"\(profile.username)\", realm=\"\(profile.realm)\", "
            + "nonce=\"\(nonce)\", uri=\"\(uri)\", response=\"\(response)\""
        let ok = ServerFixture.exchange(&server, ServerFixture.request(
            "DESCRIBE", uri, cseq: 2, headers: ["Authorization": authorization]))
        #expect(ServerFixture.status(ok) == 200)
        #expect(server.authenticatedRequestCount == 1)
        #expect(server.rejections.isEmpty)
    }

    @Test func serverRejectsAWrongDigestResponse() {
        let profile = SyntheticCameraProfile.ds2cd2143g2()
        var server = SyntheticRTSPServer(profile: profile)
        _ = ServerFixture.exchange(&server, ServerFixture.request("DESCRIBE", "rtsp://h/s", cseq: 1))
        let authorization = "Digest username=\"admin\", realm=\"\(profile.realm)\", "
            + "nonce=\"wrong\", uri=\"rtsp://h/s\", response=\"00000000000000000000000000000000\""
        let denied = ServerFixture.exchange(&server, ServerFixture.request(
            "DESCRIBE", "rtsp://h/s", cseq: 2, headers: ["Authorization": authorization]))
        #expect(ServerFixture.status(denied) == 401)
        #expect(server.authenticatedRequestCount == 0)
        #expect(server.rejections.count == 1)
    }

    @Test func serverAcceptsBasicForLegacyFirmware() {
        let profile = SyntheticCameraProfile.legacyPathCamera()
        var server = SyntheticRTSPServer(profile: profile)
        let challenge = ServerFixture.exchange(&server, ServerFixture.request(
            "DESCRIBE", "rtsp://h/s", cseq: 1))
        #expect(ServerFixture.header(challenge, "WWW-Authenticate")?.hasPrefix("Basic") == true)
        let token = Base64.encode(Array("\(profile.username):\(profile.password)".utf8))
        let ok = ServerFixture.exchange(&server, ServerFixture.request(
            "DESCRIBE", "rtsp://h/s", cseq: 2, headers: ["Authorization": "Basic \(token)"]))
        #expect(ServerFixture.status(ok) == 200)
    }

    @Test func serverAlwaysChallengesUnderWrongPasswordAlways() {
        let profile = SyntheticCameraProfile.ds2cd2143g2().adding(.wrongPasswordAlways)
        var server = SyntheticRTSPServer(profile: profile)
        for cseq in 1...4 {
            let response = ServerFixture.exchange(&server, ServerFixture.request(
                "DESCRIBE", "rtsp://h/s", cseq: cseq,
                headers: ["Authorization": "Digest username=\"admin\", response=\"x\""]))
            #expect(ServerFixture.status(response) == 401)
        }
        #expect(server.authenticatedRequestCount == 0)
    }
}

// MARK: - SDP

@Suite struct SyntheticServerSDPSuite {

    private func describeBody(_ profile: SyntheticCameraProfile) -> Data {
        Data(SyntheticRTSPServer(profile: profile).advertisedSDP.utf8)
    }

    @Test func serverSDPParsesWithTheRealParserForEveryPreset() throws {
        for profile in SyntheticCameraProfile.allPresets() {
            let document = try SDPParser.parse(describeBody(profile))
            let video = try #require(document.media.first { $0.kind == .video },
                                     "\(profile.label) has no video media")
            #expect(video.payloadType == profile.payloadType)
            #expect(video.encodingName.uppercased() == profile.encodingName)
            #expect(video.clockRate == 90_000)
            #expect(video.control != nil)
        }
    }

    @Test func serverSDPCarriesParameterSetsTheBitstreamParserAccepts() throws {
        let document = try SDPParser.parse(describeBody(.hevcCamera()))
        let video = try #require(document.media.first { $0.kind == .video })
        let sets = try #require(video.parameterSets)
        #expect(sets.codec == .h265)
        #expect(sets.vps.count == 1)
        #expect(sets.sps.count == 1)
        #expect(sets.pps.count == 1)
        let sps = try Array(sets.sps[0]).withUnsafeBytes { try H265Parser.parseSPS($0) }
        #expect(sps.displayWidth == 1920)
        #expect(sps.displayHeight == 1080)
    }

    @Test func serverSDPCarriesH264ParameterSetsAndProfileLevelID() throws {
        let document = try SDPParser.parse(describeBody(.ds2cd2143g2()))
        let video = try #require(document.media.first { $0.kind == .video })
        #expect(video.fmtp["profile-level-id"] == "4D401F")
        #expect(video.packetizationMode == 1)
        let sets = try #require(video.parameterSets)
        let sps = try Array(sets.sps[0]).withUnsafeBytes { try H264Parser.parseSPS($0) }
        #expect(sps.displayWidth == 1280)
        #expect(sps.displayHeight == 720)
    }

    /// Unpadded base64 must still decode: this is a real Hikvision behaviour, not a hypothetical.
    @Test func serverSDPUnpaddedSpropStillDecodesToTheSameSets() throws {
        let padded = try SDPParser.parse(describeBody(.hevcCamera()))
        let unpadded = try SDPParser.parse(
            describeBody(.hevcCamera().adding(.unpaddedSpropBase64)))
        let a = try #require(padded.media.first { $0.kind == .video }?.parameterSets)
        let b = try #require(unpadded.media.first { $0.kind == .video }?.parameterSets)
        #expect(a == b)
        let text = SyntheticRTSPServer(profile: .hevcCamera().adding(.unpaddedSpropBase64))
            .advertisedSDP
        #expect(!text.contains("="), "no base64 padding should survive the quirk")
    }

    @Test func serverSDPOmitsSpropUnderParameterSetsOnlyInBand() throws {
        let text = SyntheticRTSPServer(profile: .hevcCamera().adding(.parameterSetsOnlyInBand))
            .advertisedSDP
        #expect(!text.contains("sprop-"))
        let document = try SDPParser.parse(Data(text.utf8))
        let video = try #require(document.media.first { $0.kind == .video })
        #expect(video.parameterSets?.isComplete != true)
    }

    @Test func serverSDPSurvivesProprietaryAttributes() throws {
        let text = SyntheticRTSPServer(profile: .hevcCamera().adding(.extraSDPAttributes))
            .advertisedSDP
        #expect(text.contains("a=Media_header"))
        let document = try SDPParser.parse(Data(text.utf8))
        #expect(document.media.count == 1)
    }

    @Test func serverSDPCanCarryADollarByteInTheBody() throws {
        let text = SyntheticRTSPServer(profile: .hevcCamera().adding(.dollarInResponseBody))
            .advertisedSDP
        #expect(text.contains("$"))
        let document = try SDPParser.parse(Data(text.utf8))
        #expect(document.sessionName?.contains("$") == true)
    }

    @Test func serverSDPUsesAnAbsoluteControlURLWhenAsked() throws {
        let text = SyntheticRTSPServer(profile: .hevcCamera().adding(.absoluteControlURL))
            .advertisedSDP
        let document = try SDPParser.parse(Data(text.utf8))
        let video = try #require(document.media.first { $0.kind == .video })
        #expect(video.control?.hasPrefix("rtsp://") == true)
    }

    @Test func serverOmitsContentBaseWhenAsked() {
        var profile = SyntheticCameraProfile.hevcCamera().adding(.noContentBase)
        profile.authMode = .none
        var server = SyntheticRTSPServer(profile: profile)
        let response = ServerFixture.exchange(&server, ServerFixture.request(
            "DESCRIBE", "rtsp://h/s", cseq: 1))
        #expect(ServerFixture.header(response, "Content-Base") == nil)
        #expect(ServerFixture.body(response).contains("m=video"))
    }

    @Test func serverNVRPresetAddressesTheRequestedChannel() {
        let profile = SyntheticCameraProfile.ds7608nvr(channels: 8, channel: 3)
        #expect(profile.streamPath == "/Streaming/Channels/302")
        #expect(SyntheticRTSPServer(profile: profile).contentBase
            .hasSuffix("/Streaming/Channels/302/"))
    }

    @Test func serverLegacyPresetUsesTheLegacyPath() {
        let profile = SyntheticCameraProfile.legacyPathCamera()
        #expect(profile.streamPath == "/h264/ch1/main/av_stream")
        #expect(profile.authMode == .basic)
    }
}
