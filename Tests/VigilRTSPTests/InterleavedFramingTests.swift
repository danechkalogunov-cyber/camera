//
//  InterleavedFramingTests.swift
//  VigilRTSPTests
//
//  The `$` framing codec: frames split across arbitrary chunk boundaries, frames that share a TCP
//  segment with an RTSP response, resynchronisation after corruption, and the case that catches
//  every naive implementation — a `$` byte inside a response body.
//  Covers docs/spec-rtsp.md §5.2, §5.4 and §5.5.
//

import Foundation
import Testing
import VigilProtocols
@testable import VigilRTSP

/// Byte builders shared by the framing and session-machine suites.
enum RTSPWireBytes {

    /// One interleaved frame: `$`, channel, 16-bit big-endian length, payload.
    static func frame(channel: UInt8, payload: [UInt8]) -> [UInt8] {
        [0x24, channel, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)] + payload
    }

    /// A payload that passes the RTP plausibility gate: version 2 in the top two bits.
    static func rtpPayload(byteCount: Int, marker: UInt8 = 0x60) -> [UInt8] {
        var out: [UInt8] = [0x80, marker]
        while out.count < byteCount { out.append(UInt8(out.count & 0xFF)) }
        return Array(out.prefix(max(byteCount, 2)))
    }

    /// An RTSP response with CRLF line endings and an automatic `Content-Length`.
    static func response(status: Int = 200,
                         reason: String = "OK",
                         headers: [(String, String)] = [],
                         body: String = "") -> [UInt8] {
        var text = "RTSP/1.0 \(status) \(reason)\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        if !body.isEmpty { text += "Content-Length: \(body.utf8.count)\r\n" }
        text += "\r\n" + body
        return Array(text.utf8)
    }
}

@Suite struct InterleavedFramingSuite {

    private func makeDecoder(channels: Set<UInt8> = [0, 1]) -> RTSPWireDecoder {
        var decoder = RTSPWireDecoder()
        decoder.registerInterleavedChannels(channels)
        return decoder
    }

    // MARK: - Split invariance

    @Test func framingReassemblesAFrameSplitAcrossThreeChunks() {
        var decoder = makeDecoder()
        let payload = RTSPWireBytes.rtpPayload(byteCount: 64)
        let bytes = RTSPWireBytes.frame(channel: 0, payload: payload)

        #expect(decoder.ingest(bytes[0..<2]).isEmpty)        // `$` and the channel only
        #expect(decoder.ingest(bytes[2..<20]).isEmpty)       // length plus part of the payload
        let events = decoder.ingest(bytes[20...])
        #expect(events == [.interleaved(channel: 0, payload: Data(payload))])
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test func framingHandlesALengthFieldStraddlingTheChunkBoundary() {
        var decoder = makeDecoder()
        let payload = RTSPWireBytes.rtpPayload(byteCount: 300)      // length 0x012C
        let bytes = RTSPWireBytes.frame(channel: 0, payload: payload)
        #expect(bytes[2] == 0x01 && bytes[3] == 0x2C)

        #expect(decoder.ingest(bytes[0..<3]).isEmpty)               // high length byte only
        let events = decoder.ingest(bytes[3...])
        #expect(events == [.interleaved(channel: 0, payload: Data(payload))])
    }

    @Test func framingIsInvariantUnderEveryChunkSize() {
        let stream = RTSPWireBytes.frame(channel: 0, payload: RTSPWireBytes.rtpPayload(byteCount: 40))
            + RTSPWireBytes.response(headers: [("CSeq", "1"), ("Session", "12345")])
            + RTSPWireBytes.frame(channel: 1, payload: RTSPWireBytes.rtpPayload(byteCount: 52,
                                                                                marker: 0xC8))
        var reference = makeDecoder()
        let expected = reference.ingest(stream)
        #expect(expected.count == 3)

        for size in [1, 2, 3, 5, 7, 13, 64, 1_024] {
            var chunked = makeDecoder()
            var produced: [RTSPIncoming] = []
            var index = 0
            while index < stream.count {
                let end = min(index + size, stream.count)
                produced += chunked.ingest(stream[index..<end])
                index = end
            }
            #expect(produced == expected, "chunk size \(size) changed the event sequence")
        }
    }

    // MARK: - Demultiplexing from RTSP messages

    @Test func framingIgnoresADollarByteInsideAResponseBody() {
        var decoder = makeDecoder()
        // A body that begins exactly like a frame header. A decoder that scanned bodies for `$`
        // would swallow the next 1 285 bytes and desynchronise permanently.
        let body = "$\u{0000}\u{0005}\u{0001}v=0\r\nm=video 0 RTP/AVP 96\r\n"
        let stream = RTSPWireBytes.response(headers: [("CSeq", "2"),
                                                      ("Content-Type", "application/sdp")],
                                            body: body)
            + RTSPWireBytes.frame(channel: 0, payload: RTSPWireBytes.rtpPayload(byteCount: 32))

        let events = decoder.ingest(stream)
        #expect(events.count == 2)
        guard case let .response(response) = events.first else {
            Issue.record("expected a response first, got \(String(describing: events.first))")
            return
        }
        #expect(response.body == Data(body.utf8))
        #expect(response.cseq == 2)
        #expect(events.last == .interleaved(channel: 0,
                                            payload: Data(RTSPWireBytes.rtpPayload(byteCount: 32))))
        #expect(decoder.statistics.resyncEvents == 0)
    }

    @Test func framingAcceptsAFrameInTheSameSegmentAsThePlayResponse() {
        var decoder = makeDecoder()
        let payload = RTSPWireBytes.rtpPayload(byteCount: 1_440)
        let stream = RTSPWireBytes.response(headers: [("CSeq", "6"), ("Session", "1885573958")])
            + RTSPWireBytes.frame(channel: 0, payload: payload)
        let events = decoder.ingest(stream)
        #expect(events.count == 2)
        #expect(events.last == .interleaved(channel: 0, payload: Data(payload)))
    }

    @Test func framingDecodesTwoFramesInOneChunk() {
        var decoder = makeDecoder()
        let first = RTSPWireBytes.rtpPayload(byteCount: 20)
        let second = RTSPWireBytes.rtpPayload(byteCount: 30, marker: 0xC8)
        let events = decoder.ingest(RTSPWireBytes.frame(channel: 0, payload: first)
            + RTSPWireBytes.frame(channel: 1, payload: second))
        #expect(events == [.interleaved(channel: 0, payload: Data(first)),
                           .interleaved(channel: 1, payload: Data(second))])
        #expect(decoder.statistics.interleavedFramesDecoded == 2)
    }

    // MARK: - Resynchronisation

    @Test func framingResynchronisesAfterGarbagePrecedingAValidFrame() {
        var decoder = makeDecoder()
        // A frame on a channel no SETUP negotiated starts the resynchronisation, then 24 bytes of
        // rubbish, then two good frames — the chain the scanner needs before it will commit.
        var stream = RTSPWireBytes.frame(channel: 9, payload: [UInt8](repeating: 0xAB, count: 6))
        stream += [UInt8](repeating: 0xAB, count: 24)
        let good = RTSPWireBytes.rtpPayload(byteCount: 16)
        stream += RTSPWireBytes.frame(channel: 0, payload: good)
        stream += RTSPWireBytes.frame(channel: 0, payload: good)

        let events = decoder.ingest(stream)
        let frames = events.compactMap { event -> Data? in
            guard case let .interleaved(_, payload) = event else { return nil }
            return payload
        }
        #expect(frames == [Data(good), Data(good)])
        #expect(decoder.statistics.resyncEvents == 1)
        #expect(decoder.statistics.bytesDiscardedByResync > 0)
        #expect(decoder.failure == nil)             // Recoverable: the connection survives.
    }

    @Test func framingResynchronisesOntoAStatusLine() {
        var decoder = makeDecoder()
        var stream = RTSPWireBytes.frame(channel: 7, payload: [UInt8](repeating: 0x00, count: 4))
        stream += [UInt8](repeating: 0xFE, count: 16)
        stream += RTSPWireBytes.response(headers: [("CSeq", "4")])

        let events = decoder.ingest(stream)
        let responses = events.compactMap { event -> RTSPResponse? in
            guard case let .response(response) = event else { return nil }
            return response
        }
        #expect(responses.count == 1)
        #expect(responses.first?.cseq == 4)
        #expect(decoder.statistics.resyncEvents == 1)
    }

    @Test func framingSurvivesGarbageThatContainsAFalseDollarByte() {
        var decoder = makeDecoder()
        // 0x24 followed by a registered channel but an implausible payload: length 0 is below the
        // 4-byte floor, so the chain test rejects it and the scan continues.
        var stream = RTSPWireBytes.frame(channel: 5, payload: [0x00, 0x00, 0x00, 0x00])
        stream += [0x24, 0x00, 0x00, 0x00, 0x11, 0x22]
        let good = RTSPWireBytes.rtpPayload(byteCount: 24)
        stream += RTSPWireBytes.frame(channel: 0, payload: good)
        stream += RTSPWireBytes.frame(channel: 0, payload: good)

        let events = decoder.ingest(stream)
        let frames = events.compactMap { event -> Data? in
            guard case let .interleaved(_, payload) = event else { return nil }
            return payload
        }
        #expect(frames == [Data(good), Data(good)])
    }

    @Test func framingReportsAnUnknownChannelAsRecoverable() {
        var decoder = makeDecoder()
        let events = decoder.ingest(RTSPWireBytes.frame(channel: 9, payload: [0x80, 0x60, 0, 0]))
        let faults = events.compactMap { event -> RTSPFramingFault? in
            guard case let .malformed(fault) = event else { return nil }
            return fault
        }
        #expect(faults.count == 1)
        #expect(faults.first?.isRecoverable == true)
        #expect(faults.first?.rtspError == .interleaveDesync(recovered: true))
    }

    // MARK: - Degenerate frames

    @Test func framingDropsAZeroLengthFrameAndKeepsGoing() {
        var decoder = makeDecoder()
        let good = RTSPWireBytes.rtpPayload(byteCount: 12)
        let events = decoder.ingest([0x24, 0x00, 0x00, 0x00]
            + RTSPWireBytes.frame(channel: 0, payload: good))
        #expect(events == [.interleaved(channel: 0, payload: Data(good))])
        #expect(decoder.statistics.emptyInterleavedFrames == 1)
    }

    @Test func framingAcceptsTheMaximumPayloadLength() {
        var decoder = makeDecoder()
        let payload = RTSPWireBytes.rtpPayload(byteCount: 65_535)
        let events = decoder.ingest(RTSPWireBytes.frame(channel: 0, payload: payload))
        #expect(events == [.interleaved(channel: 0, payload: Data(payload))])
        #expect(decoder.statistics.interleavedBytes == 65_535)
    }

    @Test func framingEmitsNothingForAnEmptyIngest() {
        var decoder = makeDecoder()
        #expect(decoder.ingest([UInt8]()).isEmpty)
        #expect(decoder.bufferedByteCount == 0)
    }
}
