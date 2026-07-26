//
//  RTSPWireDecoderTests.swift
//  VigilRTSPTests
//
//  The incremental decoder: split invariance, interleaved demux (including inside a header block),
//  every documented leniency, and every documented limit. The limit cases are the security tests —
//  this is the code a hostile or broken device talks to first.
//  Covers docs/spec-rtsp.md §4, §5.2–5.5 and the RTSPWireDecoderTests row of §18.2.
//

import Foundation
import Testing

import VigilProtocols

@testable import VigilRTSP

@Suite struct RTSPWireDecoderTests {

    // MARK: - Happy paths

    @Test func wireDecoderDecodesAStatusLineWithNoBody() throws {
        var decoder = RTSPWireDecoder()
        let events = decoder.ingest(MessageLayerFixtures.response(
            status: "200 OK",
            headers: [("CSeq", "1"), ("Public", "OPTIONS, DESCRIBE, SETUP, PLAY")]))
        #expect(events.count == 1)
        guard case .response(let response) = try #require(events.first) else {
            Issue.record("expected a response")
            return
        }
        #expect(response.status == .ok)
        #expect(response.reasonPhrase == "OK")
        #expect(response.cseq == 1)
        #expect(response.body.isEmpty)
        #expect(response.headers.first("Public") == "OPTIONS, DESCRIBE, SETUP, PLAY")
        #expect(decoder.statistics.messagesDecoded == 1)
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test func wireDecoderDeliversExactlyContentLengthBodyBytes() throws {
        let body = "v=0\r\ns=Vigil test SDP\r\n"
        var decoder = RTSPWireDecoder()
        let events = decoder.ingest(MessageLayerFixtures.response(
            status: "200 OK",
            headers: [("CSeq", "3"), ("Content-Type", "application/sdp"),
                      ("Content-Length", String(body.utf8.count))],
            body: body))
        guard case .response(let response) = try #require(events.first) else {
            Issue.record("expected a response")
            return
        }
        #expect(response.body == Data(body.utf8))
    }

    @Test func wireDecoderDecodesTwoMessagesFromOneChunk() {
        var stream = MessageLayerFixtures.response(status: "200 OK", headers: [("CSeq", "1")])
        stream += MessageLayerFixtures.response(status: "401 Unauthorized", headers: [("CSeq", "2")])
        var decoder = RTSPWireDecoder()
        let events = decoder.ingest(stream)
        #expect(events.count == 2)
        #expect(decoder.statistics.messagesDecoded == 2)
    }

    @Test func wireDecoderDecodesServerInitiatedRequests() throws {
        let body = "v=0\r\n"
        let text = "ANNOUNCE rtsp://192.168.1.200:554/Streaming/tracks/301 RTSP/1.0\r\n"
            + "CSeq: 41\r\nNotice: 2101 \"End of stream reached\" event-date=20240115T093000Z\r\n"
            + "Content-Type: application/sdp\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body
        var decoder = RTSPWireDecoder()
        let events = decoder.ingest(MessageLayerFixtures.bytes(text))
        guard case .request(let request) = try #require(events.first) else {
            Issue.record("expected a server-initiated request")
            return
        }
        #expect(request.method == .announce)
        #expect(request.uri == "rtsp://192.168.1.200:554/Streaming/tracks/301")
        #expect(request.cseq == 41)
        #expect(request.body == Data(body.utf8))
        #expect(request.headers.first("Notice")?.hasPrefix("2101") == true)
    }

    // MARK: - Split invariance

    /// The property the whole design exists for: chunking must not be observable.
    @Test func wireDecoderIsInvariantAcrossEveryChunking() {
        let body = "v=0\r\ns=Vigil\r\nm=video 0 RTP/AVP 96\r\n"
        var stream = MessageLayerFixtures.response(status: "200 OK",
                                                   headers: [("CSeq", "1"), ("Session", "1885573958")])
        stream += MessageLayerFixtures.interleaved(channel: 0,
                                                   payload: MessageLayerFixtures.rtpPacket(length: 1440))
        stream += MessageLayerFixtures.interleaved(channel: 1,
                                                   payload: MessageLayerFixtures.rtpPacket(length: 52))
        stream += MessageLayerFixtures.response(
            status: "200 OK",
            headers: [("CSeq", "2"), ("Content-Type", "application/sdp"),
                      ("Content-Length", String(body.utf8.count))],
            body: body)
        stream += MessageLayerFixtures.interleaved(channel: 0,
                                                   payload: MessageLayerFixtures.rtpPacket(length: 7))

        let reference = MessageLayerFixtures.decode(stream, chunk: stream.count, channels: [0, 1])
        #expect(reference.count == 5)
        for chunk in [1, 3, 17, 4096] {
            let events = MessageLayerFixtures.decode(stream, chunk: chunk, channels: [0, 1])
            #expect(events == reference, "chunk size \(chunk) produced a different event sequence")
        }
    }

    @Test func wireDecoderIsInvariantWhenCRAndLFAreSplitApart() {
        let stream = MessageLayerFixtures.response(status: "200 OK",
                                                   headers: [("CSeq", "7"), ("Session", "1885573958")])
        let whole = MessageLayerFixtures.decode(stream, chunk: stream.count)
        // Chunk size 1 puts every CR in one call and its LF in the next.
        #expect(MessageLayerFixtures.decode(stream, chunk: 1) == whole)
        #expect(MessageLayerFixtures.decode(stream, chunk: 2) == whole)
    }

    // MARK: - Interleaved demux

    @Test func wireDecoderEmitsInterleavedFramesBetweenResponses() throws {
        let payload = MessageLayerFixtures.rtpPacket(length: 20)
        var stream = MessageLayerFixtures.response(status: "200 OK", headers: [("CSeq", "6")])
        stream += MessageLayerFixtures.interleaved(channel: 0, payload: payload)
        stream += MessageLayerFixtures.response(status: "200 OK", headers: [("CSeq", "7")])
        var decoder = RTSPWireDecoder()
        decoder.registerInterleavedChannels([0, 1])
        let events = decoder.ingest(stream)
        #expect(events.count == 3)
        guard case .interleaved(let channel, let data) = events[1] else {
            Issue.record("expected the middle event to be interleaved media")
            return
        }
        #expect(channel == 0)
        #expect(data == Data(payload))
        #expect(decoder.statistics.interleavedFramesDecoded == 1)
        #expect(decoder.statistics.interleavedBytes == 20)
    }

    /// Two Hikvision firmware families emit a `$` frame between the first line of a header block and
    /// the rest of it when a PLAY response races the first RTP packet (docs/spec-rtsp.md §5.4).
    @Test func wireDecoderAcceptsAnInterleavedFrameInsideAHeaderBlock() throws {
        let payload = MessageLayerFixtures.rtpPacket(length: 64)
        var stream = MessageLayerFixtures.bytes("RTSP/1.0 200 OK\r\nCSeq: 6\r\n")
        stream += MessageLayerFixtures.interleaved(channel: 0, payload: payload)
        stream += MessageLayerFixtures.bytes("Session: 1885573958\r\nRange: npt=0.000-\r\n\r\n")
        var decoder = RTSPWireDecoder()
        decoder.registerInterleavedChannels([0, 1])
        let events = decoder.ingest(stream)

        #expect(events.count == 2)
        guard case .interleaved(let channel, let data) = events[0],
              case .response(let response) = events[1] else {
            Issue.record("expected media then the response that surrounded it")
            return
        }
        #expect(channel == 0)
        #expect(data == Data(payload))
        #expect(response.cseq == 6)
        #expect(response.headers.first("Session") == "1885573958")
        #expect(response.headers.first("Range") == "npt=0.000-")
        #expect(decoder.statistics.midHeaderInterleavedFrames == 1)
        // And it must decode identically no matter where the chunk boundaries fell.
        #expect(MessageLayerFixtures.decode(stream, chunk: 1, channels: [0, 1]) == events)
        #expect(MessageLayerFixtures.decode(stream, chunk: 17, channels: [0, 1]) == events)
    }

    @Test func wireDecoderConsumesZeroLengthInterleavedFramesWithoutEmitting() {
        var stream: [UInt8] = [0x24, 0x00, 0x00, 0x00]
        stream += MessageLayerFixtures.response(status: "200 OK", headers: [("CSeq", "1")])
        var decoder = RTSPWireDecoder()
        decoder.registerInterleavedChannels([0])
        let events = decoder.ingest(stream)
        #expect(events.count == 1)
        #expect(decoder.statistics.emptyInterleavedFrames == 1)
        #expect(decoder.statistics.interleavedFramesDecoded == 0)
    }

    @Test func wireDecoderResynchronizesAfterAFrameOnAnUnregisteredChannel() throws {
        var stream = MessageLayerFixtures.interleaved(channel: 9,
                                                      payload: [UInt8](repeating: 0, count: 16))
        stream += MessageLayerFixtures.response(status: "200 OK", headers: [("CSeq", "4")])
        var decoder = RTSPWireDecoder()
        decoder.registerInterleavedChannels([0, 1])
        let events = decoder.ingest(stream)

        #expect(events.count == 2)
        guard case .malformed(let fault) = events[0] else {
            Issue.record("expected a framing fault first")
            return
        }
        #expect(fault == .unknownInterleavedChannel(9))
        #expect(fault.isRecoverable)
        #expect(fault.rtspError == .interleaveDesync(recovered: true))
        guard case .response(let response) = events[1] else {
            Issue.record("expected the following response to survive the resync")
            return
        }
        #expect(response.cseq == 4)
        #expect(decoder.statistics.resyncEvents == 1)
        #expect(decoder.statistics.bytesDiscardedByResync == 20)
        #expect(decoder.failure == nil)
    }

    /// Corruption in the middle of a media run must cost one resynchronization, not the stream: the
    /// frame after the damaged one has to arrive.
    @Test func wireDecoderRecoversFromACorruptFrameHeaderAndDeliversTheNextFrame() throws {
        let good = MessageLayerFixtures.rtpPacket(length: 24, sequence: 1)
        let later = MessageLayerFixtures.rtpPacket(length: 24, sequence: 3)
        var stream = MessageLayerFixtures.interleaved(channel: 0, payload: good)
        // A damaged frame header: the magic survived, the channel byte did not.
        stream += MessageLayerFixtures.interleaved(channel: 7,
                                                   payload: MessageLayerFixtures.rtpPacket(length: 12))
        // Chain depth is 2, so recovery needs two consecutive believable frames.
        stream += MessageLayerFixtures.interleaved(channel: 0, payload: later)
        stream += MessageLayerFixtures.interleaved(channel: 1,
                                                   payload: MessageLayerFixtures.rtpPacket(length: 32))

        var decoder = RTSPWireDecoder()
        decoder.registerInterleavedChannels([0, 1])
        let events = decoder.ingest(stream)

        #expect(events.count == 4)
        guard case .interleaved(_, let first) = events[0],
              case .malformed(let fault) = events[1],
              case .interleaved(let channel, let recovered) = events[2] else {
            Issue.record("expected media, a fault, then recovered media: \(events)")
            return
        }
        #expect(first == Data(good))
        #expect(fault == .unknownInterleavedChannel(7))
        #expect(channel == 0)
        #expect(recovered == Data(later))
        #expect(decoder.statistics.resyncEvents == 1)
        #expect(decoder.failure == nil)
        #expect(MessageLayerFixtures.decode(stream, chunk: 1, channels: [0, 1]) == events)
    }

    /// A `0x24` inside garbage is not a frame boundary. The second link of the chain here satisfies
    /// the channel, length and RTP-version checks and fails only on its magic byte — which is the
    /// regression this test exists for: without the magic check on links 2…n the decoder locks onto
    /// the false candidate and hands the depacketizer garbage that looks like a codec fault.
    @Test func wireDecoderRejectsAFalseFrameChainWhoseSecondLinkLacksTheMagicByte() throws {
        let real = MessageLayerFixtures.rtpPacket(length: 24, sequence: 9)
        var stream = MessageLayerFixtures.interleaved(channel: 9, payload: [0xEE, 0xEE])  // resync

        // A convincing first link: magic, registered channel 0, length 8, RTP version 2.
        let falseCandidate: [UInt8] = [0x24, 0x00, 0x00, 0x08] + [UInt8](repeating: 0x80, count: 8)
        // What follows it is *not* a frame: only its magic byte is wrong. Channel 0 is registered,
        // the length is 16, and the first payload byte has version bits 2.
        let impostor: [UInt8] = [0xAA, 0x00, 0x00, 0x10] + [UInt8](repeating: 0x80, count: 16)
        stream += falseCandidate + impostor

        // The genuine run the decoder must find instead.
        stream += MessageLayerFixtures.interleaved(channel: 0, payload: real)
        stream += MessageLayerFixtures.interleaved(channel: 1,
                                                   payload: MessageLayerFixtures.rtpPacket(length: 16))

        var decoder = RTSPWireDecoder()
        decoder.registerInterleavedChannels([0, 1])
        let events = decoder.ingest(stream)

        guard case .malformed = try #require(events.first) else {
            Issue.record("expected the unknown channel to start a resync")
            return
        }
        let media = events.compactMap { event -> Data? in
            if case .interleaved(_, let payload) = event { return payload }
            return nil
        }
        #expect(media.count == 2, "the false candidate must not be emitted as media")
        #expect(media.first == Data(real))
        #expect(decoder.statistics.bytesDiscardedByResync
            == UInt64(6 + falseCandidate.count + impostor.count))
    }

    // MARK: - Leniencies

    @Test func wireDecoderToleratesBareLineFeeds() throws {
        var decoder = RTSPWireDecoder()
        let events = decoder.ingest(MessageLayerFixtures.bytes("RTSP/1.0 200 OK\nCSeq: 1\n\n"))
        #expect(events.count == 1)
        #expect(decoder.statistics.toleratedBareLF == 3)
    }

    @Test func wireDecoderFoldsContinuationLines() throws {
        let text = "RTSP/1.0 200 OK\r\nCSeq: 1\r\nPublic: OPTIONS,\r\n\tDESCRIBE,\r\n SETUP\r\n\r\n"
        var decoder = RTSPWireDecoder()
        let events = decoder.ingest(MessageLayerFixtures.bytes(text))
        guard case .response(let response) = try #require(events.first) else {
            Issue.record("expected a response")
            return
        }
        #expect(response.headers.first("Public") == "OPTIONS, DESCRIBE, SETUP")
        #expect(decoder.statistics.foldedHeaderLines == 2)
    }

    @Test func wireDecoderAcceptsAMissingReasonPhrase() throws {
        var decoder = RTSPWireDecoder()
        let events = decoder.ingest(MessageLayerFixtures.bytes("RTSP/1.0 401\r\nCSeq: 2\r\n\r\n"))
        guard case .response(let response) = try #require(events.first) else {
            Issue.record("expected a response")
            return
        }
        #expect(response.status == .unauthorized)
        #expect(response.reasonPhrase.isEmpty)
    }

    @Test func wireDecoderAcceptsExtraSpacesAndVersion11() throws {
        var decoder = RTSPWireDecoder()
        let events = decoder.ingest(MessageLayerFixtures.bytes("RTSP/1.1   200   OK now\r\n\r\n"))
        guard case .response(let response) = try #require(events.first) else {
            Issue.record("expected a response")
            return
        }
        #expect(response.status == .ok)
        #expect(response.reasonPhrase == "OK now")
        #expect(response.cseq == nil)
    }

    @Test func wireDecoderSkipsLeadingCRLFPaddingBetweenMessages() {
        var stream = MessageLayerFixtures.bytes("\r\n\r\n")
        stream += MessageLayerFixtures.response(status: "200 OK", headers: [("CSeq", "1")])
        var decoder = RTSPWireDecoder()
        let events = decoder.ingest(stream)
        #expect(events.count == 1)
    }

    @Test func wireDecoderSkipsAHeaderLineWithNoColon() throws {
        let text = "RTSP/1.0 200 OK\r\nCSeq: 1\r\na=Media_header\r\nSession: 42\r\n\r\n"
        var decoder = RTSPWireDecoder()
        let events = decoder.ingest(MessageLayerFixtures.bytes(text))
        guard case .response(let response) = try #require(events.first) else {
            Issue.record("expected a response")
            return
        }
        #expect(response.headers.first("Session") == "42")
        #expect(decoder.statistics.malformedHeaderLines == 1)
    }

    @Test func wireDecoderKeepsDuplicateContentLengthWhenTheyAgree() throws {
        let body = "ab"
        let text = "RTSP/1.0 200 OK\r\nCSeq: 1\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\n" + body
        var decoder = RTSPWireDecoder()
        let events = decoder.ingest(MessageLayerFixtures.bytes(text))
        guard case .response(let response) = try #require(events.first) else {
            Issue.record("expected a response")
            return
        }
        #expect(response.body == Data(body.utf8))
    }

    // MARK: - Limits and diagnosable faults

    /// A peer that never sends CRLF must hit a limit, not exhaust memory.
    @Test func wireDecoderRefusesAnUnboundedHeaderLine() throws {
        var stream = MessageLayerFixtures.bytes("RTSP/1.0 200 OK\r\nX-Pad: ")
        stream += [UInt8](repeating: UInt8(ascii: "A"), count: 9_000)
        var decoder = RTSPWireDecoder()
        let events = decoder.ingest(stream)
        guard case .malformed(let fault) = try #require(events.first) else {
            Issue.record("expected a framing fault")
            return
        }
        guard case .headerLineTooLong(let bytes) = fault else {
            Issue.record("expected headerLineTooLong, got \(fault)")
            return
        }
        #expect(bytes > 8_192)
        #expect(!fault.isRecoverable)
        #expect(fault.rtspError == .headerTooLarge(bytes: bytes))
        // Terminal: the buffer is released and nothing is decoded on this connection again.
        #expect(decoder.bufferedByteCount == 0)
        #expect(decoder.failure == fault)
        let afterFailure = decoder.ingest(MessageLayerFixtures.response(status: "200 OK",
                                                                        headers: [("CSeq", "1")]))
        #expect(afterFailure.isEmpty)
    }

    @Test func wireDecoderRefusesAnOversizedHeaderBlock() throws {
        var text = "RTSP/1.0 200 OK\r\nCSeq: 1\r\n"
        for index in 0 ..< 8 {
            text += "X-Pad-\(index): " + String(repeating: "p", count: 4_900) + "\r\n"
        }
        text += "\r\n"
        var decoder = RTSPWireDecoder()
        let events = decoder.ingest(MessageLayerFixtures.bytes(text))
        guard case .malformed(let fault) = try #require(events.first),
              case .headerBlockTooLarge(let bytes) = fault else {
            Issue.record("expected headerBlockTooLarge")
            return
        }
        #expect(bytes > 32_768)
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test func wireDecoderRefusesTooManyHeaderFields() throws {
        var text = "RTSP/1.0 200 OK\r\n"
        for index in 0 ..< 200 { text += "X-\(index): v\r\n" }
        text += "\r\n"
        var decoder = RTSPWireDecoder()
        let events = decoder.ingest(MessageLayerFixtures.bytes(text))
        guard case .malformed(let fault) = try #require(events.first),
              case .tooManyHeaderFields(let count) = fault else {
            Issue.record("expected tooManyHeaderFields")
            return
        }
        #expect(count == 129)
    }

    @Test func wireDecoderRefusesAStartLineWithNoTerminator() throws {
        var decoder = RTSPWireDecoder()
        let events = decoder.ingest([UInt8](repeating: UInt8(ascii: "R"), count: 5_000))
        guard case .malformed(let fault) = try #require(events.first),
              case .startLineTooLong(let bytes) = fault else {
            Issue.record("expected startLineTooLong")
            return
        }
        #expect(bytes == 5_000)
    }

    @Test func wireDecoderRefusesADeclaredBodyLargerThanTheCap() throws {
        var decoder = RTSPWireDecoder()
        let events = decoder.ingest(MessageLayerFixtures.response(
            status: "200 OK", headers: [("CSeq", "3"), ("Content-Length", "1000000")]))
        guard case .malformed(let fault) = try #require(events.first) else {
            Issue.record("expected a framing fault")
            return
        }
        #expect(fault == .bodyTooLarge(declared: 1_000_000, limit: 262_144))
        #expect(fault.rtspError == .headerTooLarge(bytes: 1_000_000))
    }

    /// A body that never fully arrives is not an error by itself — the decoder waits, holding only
    /// what it was given — but the buffer is bounded, and passing the high-water mark is fatal.
    @Test func wireDecoderWaitsForAnUndeliveredBodyUntilTheBufferOverflows() throws {
        var limits = RTSPWireDecoder.Limits()
        limits.receiveHighWater = 128
        var decoder = RTSPWireDecoder(limits: limits)

        let head = MessageLayerFixtures.bytes(
            "RTSP/1.0 200 OK\r\nCSeq: 3\r\nContent-Length: 4096\r\n\r\n")
        let afterHead = decoder.ingest(head)
        #expect(afterHead.isEmpty)
        let afterPartialBody = decoder.ingest([UInt8](repeating: 0x41, count: 10))
        #expect(afterPartialBody.isEmpty)
        #expect(decoder.bufferedByteCount == 10)
        #expect(decoder.failure == nil)

        let events = decoder.ingest([UInt8](repeating: 0x41, count: 200))
        guard case .malformed(let fault) = try #require(events.first),
              case .receiveBufferOverflow(let bytes) = fault else {
            Issue.record("expected receiveBufferOverflow")
            return
        }
        #expect(bytes == 210)
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test func wireDecoderRefusesANonNumericContentLength() throws {
        var decoder = RTSPWireDecoder()
        let events = decoder.ingest(MessageLayerFixtures.response(
            status: "200 OK", headers: [("CSeq", "3"), ("Content-Length", "abc")]))
        guard case .malformed(let fault) = try #require(events.first) else {
            Issue.record("expected a framing fault")
            return
        }
        #expect(fault == .malformedContentLength("abc"))
        #expect(fault.rtspError == .malformedResponse)
    }

    @Test func wireDecoderRefusesANegativeContentLength() throws {
        var decoder = RTSPWireDecoder()
        let events = decoder.ingest(MessageLayerFixtures.response(
            status: "200 OK", headers: [("CSeq", "3"), ("Content-Length", "-1")]))
        guard case .malformed(let fault) = try #require(events.first) else {
            Issue.record("expected a framing fault")
            return
        }
        #expect(fault == .malformedContentLength("-1"))
    }

    @Test func wireDecoderRefusesDisagreeingContentLengths() throws {
        let text = "RTSP/1.0 200 OK\r\nCSeq: 1\r\nContent-Length: 10\r\nContent-Length: 12\r\n\r\n"
        var decoder = RTSPWireDecoder()
        let events = decoder.ingest(MessageLayerFixtures.bytes(text))
        guard case .malformed(let fault) = try #require(events.first) else {
            Issue.record("expected a framing fault")
            return
        }
        #expect(fault == .conflictingContentLength("10", "12"))
    }

    @Test func wireDecoderRefusesAnSDPResponseWithNoContentLength() throws {
        var decoder = RTSPWireDecoder()
        let events = decoder.ingest(MessageLayerFixtures.response(
            status: "200 OK",
            headers: [("CSeq", "3"), ("Content-Type", "application/sdp; charset=utf-8")]))
        guard case .malformed(let fault) = try #require(events.first) else {
            Issue.record("expected a framing fault")
            return
        }
        #expect(fault == .missingContentLength(cseq: 3))
    }

    /// An HTTP server on port 554 is a common misconfiguration, and "this is not RTSP" is a far
    /// more actionable diagnosis than "malformed".
    @Test func wireDecoderIdentifiesAnHTTPServerOnTheRTSPPort() throws {
        var decoder = RTSPWireDecoder()
        let events = decoder.ingest(MessageLayerFixtures.bytes(
            "HTTP/1.1 200 OK\r\nServer: nginx\r\nContent-Length: 0\r\n\r\n"))
        guard case .malformed(let fault) = try #require(events.first) else {
            Issue.record("expected a framing fault")
            return
        }
        #expect(fault == .notRTSP(startLine: "HTTP/1.1 200 OK"))
        #expect(!fault.isRecoverable)
        #expect(fault.rtspError == .malformedResponse)
        #expect(decoder.failure != nil)
    }

    @Test func wireDecoderReportsAnUnparseableStartLineAndRecovers() throws {
        var stream = MessageLayerFixtures.bytes("<html><body>go away</body></html>\r\n")
        stream += MessageLayerFixtures.response(status: "200 OK", headers: [("CSeq", "1")])
        var decoder = RTSPWireDecoder()
        let events = decoder.ingest(stream)
        guard case .malformed(let fault) = try #require(events.first) else {
            Issue.record("expected a framing fault")
            return
        }
        #expect(fault.isRecoverable)
        #expect(events.count == 2)
        guard case .response = events[1] else {
            Issue.record("expected the following response to be recovered")
            return
        }
    }

    @Test func wireDecoderReportsAnUnknownServerMethod() throws {
        var stream = MessageLayerFixtures.bytes("NOTIFY rtsp://h/x RTSP/1.0\r\nCSeq: 5\r\n\r\n")
        stream += MessageLayerFixtures.response(status: "200 OK", headers: [("CSeq", "6")])
        var decoder = RTSPWireDecoder()
        let events = decoder.ingest(stream)
        guard case .malformed(let fault) = try #require(events.first) else {
            Issue.record("expected a framing fault")
            return
        }
        #expect(fault == .unknownMethod("NOTIFY"))
        #expect(fault.isRecoverable)
        #expect(events.count == 2)
    }

    // MARK: - Hostile input

    /// Random bytes must decode, fault, or wait — never trap and never spin.
    @Test func wireDecoderSurvivesArbitraryGarbage() {
        var generator = SplitMix64RandomSource(seed: 0x51ED_2701_9C4B_A331)
        for length in [1, 2, 3, 4, 5, 9, 64, 1_000, 4_096] {
            let stream = generator.randomBytes(length)
            var decoder = RTSPWireDecoder()
            decoder.registerInterleavedChannels([0, 1])
            let events = decoder.ingest(stream)
            // Terminating at all is the assertion; a decoder that spins or traps on network data is
            // a denial of service. Everything it produces must still be one of the four event kinds,
            // and it must not be holding more than it was handed.
            #expect(events.count <= length + 1)
            #expect(decoder.bufferedByteCount <= length)
            // Feeding the same garbage in single bytes must reach the same conclusion.
            #expect(MessageLayerFixtures.decode(stream, chunk: 1, channels: [0, 1]).count
                == events.count)
        }
    }

    @Test func wireDecoderIngestingNothingIsSafe() {
        var decoder = RTSPWireDecoder()
        let first = decoder.ingest([UInt8]())
        let second = decoder.ingest([UInt8]())
        #expect(first.isEmpty)
        #expect(second.isEmpty)
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test func wireDecoderRegistersChannelsAdditively() {
        var decoder = RTSPWireDecoder()
        decoder.registerInterleavedChannels([0, 1])
        decoder.registerInterleavedChannels([2, 3])
        #expect(decoder.registeredChannels == [0, 1, 2, 3])
        decoder.clearInterleavedChannels()
        #expect(decoder.registeredChannels.isEmpty)
    }
}
