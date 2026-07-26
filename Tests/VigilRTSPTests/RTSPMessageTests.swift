//
//  RTSPMessageTests.swift
//  VigilRTSPTests
//
//  Byte-exact serialization, the canonical header order, the `Content-Length` rules, and the
//  serializer/decoder round trip. The expected bytes are the wire dumps of docs/spec-rtsp.md §11.1.
//  Covers docs/spec-rtsp.md §2.1, §2.3, §3.2–3.4 and the RTSPSerializerTests row of §18.2.
//

import Foundation
import Testing

import VigilProtocols

@testable import VigilRTSP

@Suite struct RTSPMessageTests {

    // MARK: - Methods and status

    @Test func rtspMethodKnowsWhichMethodsCarryASession() {
        #expect(RTSPMethod.play.requiresSession)
        #expect(RTSPMethod.teardown.requiresSession)
        #expect(RTSPMethod.getParameter.requiresSession)
        #expect(!RTSPMethod.options.requiresSession)
        #expect(!RTSPMethod.describe.requiresSession)
        #expect(!RTSPMethod.setup.requiresSession)
        #expect(RTSPMethod.allCases.count == 11)
    }

    @Test func rtspMethodAllowsBodiesOnlyWhereTheGrammarDoes() {
        #expect(RTSPMethod.setParameter.allowsRequestBody)
        #expect(RTSPMethod.announce.allowsRequestBody)
        #expect(!RTSPMethod.play.allowsRequestBody)
        #expect(!RTSPMethod.getParameter.allowsRequestBody)
    }

    @Test func rtspStatusClassifiesTheRangesAndNamesTheCodes() {
        #expect(RTSPStatus.ok.isSuccess)
        #expect(RTSPStatus.lowOnStorage.isSuccess)          // 250 is a success, not a warning
        #expect(RTSPStatus.movedTemporarily.isRedirect)
        #expect(RTSPStatus.unauthorized.isClientError)
        #expect(RTSPStatus.unauthorized.isAuthenticationChallenge)
        #expect(RTSPStatus.proxyAuthRequired.isAuthenticationChallenge)
        #expect(RTSPStatus.serviceUnavailable.isServerError)
        #expect(RTSPStatus.unsupportedTransport.rawValue == 461)
        #expect(RTSPStatus.optionNotSupported.canonicalReason == "Option Not Supported")
        #expect(RTSPStatus(rawValue: 466).canonicalReason == "Unknown")
        #expect(RTSPStatus.unauthorized.description == "401 Unauthorized")
    }

    // MARK: - Serialization

    @Test func requestSerializationMatchesTheOptionsWireDump() {
        let builder = RTSPRequestBuilder()
        let request = builder.build(method: .options, uri: MessageLayerFixtures.cameraBase, cseq: 1)
        let expected = "OPTIONS rtsp://192.168.1.64:554/Streaming/Channels/101 RTSP/1.0\r\n"
            + "CSeq: 1\r\nUser-Agent: Vigil/1.0\r\n\r\n"
        #expect(request.serialized() == Data(expected.utf8))
    }

    /// Step (5) of docs/spec-rtsp.md §11.1, produced by the builder and the authenticator together.
    @Test func requestSerializationMatchesTheAuthenticatedDescribeWireDump() throws {
        var authenticator = RTSPAuthenticator(credential: MessageLayerFixtures.cameraCredential,
                                              random: SplitMix64RandomSource(seed: 4))
        authenticator.absorb(MessageLayerFixtures.cameraChallenge)
        let authorization = try #require(
            authenticator.authorization(for: .describe, uri: MessageLayerFixtures.cameraBase))

        let builder = RTSPRequestBuilder()
        let request = builder.build(method: .describe, uri: MessageLayerFixtures.cameraBase, cseq: 3,
                                    options: .init(authorization: authorization,
                                                   accept: "application/sdp"))
        let expected = "DESCRIBE rtsp://192.168.1.64:554/Streaming/Channels/101 RTSP/1.0\r\n"
            + "CSeq: 3\r\n"
            + "Authorization: Digest username=\"admin\", realm=\"IP Camera(52491)\", "
            + "nonce=\"3a2f5c8e1b7d4906f2e5a8c1d4b70e93\", "
            + "uri=\"rtsp://192.168.1.64:554/Streaming/Channels/101\", "
            + "response=\"33439787cead5b387dab032b929cd5aa\"\r\n"
            + "User-Agent: Vigil/1.0\r\n"
            + "Accept: application/sdp\r\n\r\n"
        #expect(request.serialized() == Data(expected.utf8))
    }

    /// Step (9): `Session` precedes `Authorization`, which precedes `User-Agent`, which precedes
    /// `Transport`. The order is fixed so fixtures stay byte-stable.
    @Test func requestSerializationUsesTheCanonicalHeaderOrder() {
        let builder = RTSPRequestBuilder()
        let request = builder.build(
            method: .setup, uri: MessageLayerFixtures.cameraBase + "/trackID=2", cseq: 5,
            options: .init(session: "1885573958", authorization: "Digest x",
                           transport: "RTP/AVP/TCP;unicast;interleaved=2-3"))
        #expect(request.headers.fields.map(\.name)
            == ["CSeq", "Session", "Authorization", "User-Agent", "Transport"])
    }

    @Test func requestSerializationOmitsContentLengthWhenThereIsNoBody() {
        let builder = RTSPRequestBuilder()
        let request = builder.build(method: .getParameter, uri: MessageLayerFixtures.cameraBase,
                                    cseq: 7, options: .init(session: "1885573958"))
        #expect(!request.headers.has("Content-Length"))
        #expect(!request.headers.has("Content-Type"))
        let text = String(decoding: request.serialized(), as: UTF8.self)
        #expect(text.hasSuffix("User-Agent: Vigil/1.0\r\n\r\n"))
    }

    @Test func requestSerializationEmitsContentLengthAndTypeForABody() {
        let body = Data("packets_received: \r\n".utf8)
        let builder = RTSPRequestBuilder()
        let request = builder.build(method: .setParameter, uri: MessageLayerFixtures.cameraBase,
                                    cseq: 8,
                                    options: .init(contentType: "text/parameters", body: body))
        #expect(request.headers.first("Content-Length") == String(body.count))
        #expect(request.headers.fields.map(\.name).suffix(2) == ["Content-Type", "Content-Length"])
        #expect(request.serialized().suffix(body.count) == body)
    }

    @Test func requestSerializationInsertsAMissingCSeqAtTheFront() {
        let request = RTSPRequest(method: .options, uri: "rtsp://h/x",
                                  headers: RTSPHeaders([("User-Agent", "Vigil/1.0")]), cseq: 12)
        let text = String(decoding: request.serialized(), as: UTF8.self)
        #expect(text.contains("\r\nCSeq: 12\r\nUser-Agent: Vigil/1.0\r\n\r\n"))
    }

    @Test func requestBuilderRefusesAnEmptyUserAgent() {
        #expect(RTSPRequestBuilder(userAgent: "").userAgent == "Vigil")
        #expect(RTSPRequestBuilder().userAgent == "Vigil/1.0")
    }

    @Test func responseSerializationFillsInACanonicalReasonPhrase() {
        let response = RTSPResponse(status: .ok, headers: RTSPHeaders([("CSeq", "41")]))
        #expect(response.serialized() == Data("RTSP/1.0 200 OK\r\nCSeq: 41\r\n\r\n".utf8))
    }

    @Test func requestBuilderAcknowledgementEchoesCSeqAndSession() {
        let announce = RTSPRequest(method: .announce, uri: "rtsp://h/x",
                                   headers: RTSPHeaders([("CSeq", "41"), ("Session", "12345678")]),
                                   cseq: 41)
        let response = RTSPRequestBuilder().acknowledgement(for: announce)
        #expect(response.status == .ok)
        #expect(response.cseq == 41)
        #expect(response.headers.first("Session") == "12345678")
    }

    /// A header value that is not ASCII (a Chinese-firmware realm can reach `Authorization`) is
    /// written as the same UTF-8 bytes Digest hashed, not escaped and not dropped.
    @Test func requestSerializationPassesNonASCIIHeaderValuesThroughAsUTF8() {
        let request = RTSPRequest(method: .options, uri: "rtsp://h/x",
                                  headers: RTSPHeaders([("X-Realm", "摄像机(52491)")]), cseq: 1)
        let bytes = request.serialized()
        #expect(bytes.range(of: Data("摄像机(52491)".utf8)) != nil)
    }

    // MARK: - Round trip

    /// Property 5 of docs/spec-rtsp.md §18.3: anything the builder emits, the decoder reads back.
    @Test func requestRoundTripsThroughTheWireDecoder() throws {
        let builder = RTSPRequestBuilder()
        let body = Data("v=0\r\n".utf8)
        let cases: [(RTSPMethod, RTSPRequestBuilder.Options)] = [
            (.options, .init()),
            (.describe, .init(authorization: "Digest x", accept: "application/sdp")),
            (.setup, .init(session: "1885573958",
                           transport: "RTP/AVP/TCP;unicast;interleaved=0-1")),
            (.play, .init(session: "1885573958", range: "npt=0.000-", scale: "2.000")),
            (.announce, .init(contentType: "application/sdp", body: body)),
        ]
        for (index, testCase) in cases.enumerated() {
            let request = builder.build(method: testCase.0, uri: MessageLayerFixtures.cameraBase,
                                        cseq: UInt32(index + 1), options: testCase.1)
            var decoder = RTSPWireDecoder()
            let events = decoder.ingest(request.serialized())
            guard case .request(let decoded) = try #require(events.first) else {
                Issue.record("expected a request for \(testCase.0.rawValue)")
                continue
            }
            #expect(decoded == request)
        }
    }

    @Test func responseRoundTripsThroughTheWireDecoder() throws {
        let body = Data("v=0\r\ns=Vigil\r\n".utf8)
        let response = RTSPResponse(
            status: .ok, reasonPhrase: "OK",
            headers: RTSPHeaders([("CSeq", "3"), ("Content-Type", "application/sdp"),
                                  ("Content-Length", String(body.count))]),
            body: body, cseq: 3)
        var decoder = RTSPWireDecoder()
        let events = decoder.ingest(response.serialized())
        guard case .response(let decoded) = try #require(events.first) else {
            Issue.record("expected a response")
            return
        }
        #expect(decoded == response)
    }

    // MARK: - Redaction

    @Test func requestDescriptionAndTranscriptHideCredentials() {
        let builder = RTSPRequestBuilder()
        let request = builder.build(
            method: .describe, uri: "rtsp://admin:Hik12345@192.168.1.64/Streaming/Channels/101",
            cseq: 3,
            options: .init(authorization: "Digest username=\"admin\", "
                + "response=\"33439787cead5b387dab032b929cd5aa\""))
        for text in [request.description, request.redactedTranscript] {
            #expect(!text.contains("Hik12345"))
            #expect(!text.contains("33439787cead5b387dab032b929cd5aa"))
        }
        #expect(request.description.contains("DESCRIBE"))
    }

    @Test func responseDescriptionSummarisesWithoutTheBody() {
        let response = RTSPResponse(status: .unauthorized, reasonPhrase: "Unauthorized",
                                    headers: RTSPHeaders([("WWW-Authenticate",
                                                           "Digest nonce=\"3a2f5c8e\"")]),
                                    body: Data(), cseq: 2)
        #expect(response.description == "401 Unauthorized CSeq 2 body 0 B")
        #expect(!response.redactedTranscript.contains("3a2f5c8e"))
    }
}
