//
//  RTSPMessageLayerSupport.swift
//  VigilRTSPTests
//
//  Shared doubles and fixtures for the message-layer suites (headers, scanner, URL, serializer,
//  wire decoder, challenge, digest). Everything here is named `MessageLayer…` so it cannot collide
//  with the SDP / framing / session-machine suites that share this test module.
//

import Foundation

import VigilProtocols

@testable import VigilRTSP

// MARK: - Randomness

/// A `RandomSource` that replays a fixed list of 64-bit words, then repeats the last one.
///
/// Used to pin `cnonce` to a published value. `RandomSource.randomBytes` takes bytes
/// least-significant-first, so the word `0xf5d723be094a8f1c` yields the bytes
/// `1c 8f 4a 09 be 23 d7 f5` and therefore the cnonce `1c8f4a09be23d7f5` of spec-rtsp §6.5(c).
struct MessageLayerFixedRandom: RandomSource {
    private var words: [UInt64]
    private var index = 0

    init(_ words: [UInt64]) { self.words = words.isEmpty ? [0] : words }

    mutating func next() -> UInt64 {
        let word = words[Swift.min(index, words.count - 1)]
        index += 1
        return word
    }
}

// MARK: - Fixtures

/// Byte-stream builders for the decoder suites.
enum MessageLayerFixtures {

    /// UTF-8 bytes of `text`, for readable inline wire fixtures.
    static func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    /// One `$` frame: magic, channel, big-endian length, payload.
    static func interleaved(channel: UInt8, payload: [UInt8]) -> [UInt8] {
        [0x24, channel, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)] + payload
    }

    /// A plausible RTP packet: version 2, payload type 96, `length` bytes in total.
    static func rtpPacket(length: Int, sequence: UInt16 = 1) -> [UInt8] {
        var packet: [UInt8] = [0x80, 0x60, UInt8(sequence >> 8), UInt8(sequence & 0xFF)]
        while packet.count < length { packet.append(UInt8(packet.count & 0xFF)) }
        return Array(packet.prefix(length))
    }

    /// A complete response with CRLF terminators.
    static func response(status: String, headers: [(String, String)], body: String = "") -> [UInt8] {
        var text = "RTSP/1.0 \(status)\r\n"
        for header in headers { text += "\(header.0): \(header.1)\r\n" }
        text += "\r\n"
        return bytes(text) + bytes(body)
    }

    /// Feeds `stream` to a decoder in fixed-size chunks and returns every event, in order.
    static func decode(_ stream: [UInt8], chunk: Int, channels: Set<UInt8> = [],
                       limits: RTSPWireDecoder.Limits = .init()) -> [RTSPIncoming] {
        var decoder = RTSPWireDecoder(limits: limits)
        decoder.registerInterleavedChannels(channels)
        var events: [RTSPIncoming] = []
        var index = 0
        while index < stream.count {
            let end = Swift.min(index + chunk, stream.count)
            events += decoder.ingest(stream[index ..< end])
            index = end
        }
        return events
    }

    /// The camera credential of docs/spec-rtsp.md §6.5(b).
    static var cameraCredential: Credential { Credential(account: "admin", secret: "Hik12345") }

    /// The NVR credential of docs/spec-rtsp.md §6.5(c).
    static var nvrCredential: Credential { Credential(account: "admin", secret: "Nvr#2024") }

    /// The camera's no-`qop` challenge, exactly as §6.1 shows it on the wire.
    static var cameraChallenge: [RTSPChallenge] {
        RTSPChallenge.parseAll("Digest realm=\"IP Camera(52491)\", "
            + "nonce=\"3a2f5c8e1b7d4906f2e5a8c1d4b70e93\", stale=\"FALSE\"")
    }

    /// The NVR's `qop=auth` challenge of §6.5(c).
    static var nvrChallenge: [RTSPChallenge] {
        RTSPChallenge.parseAll("Digest realm=\"DS-7608NI-K2(24680)\", "
            + "nonce=\"b7c41e0a9d3f625814ae7c0b6d29f4e1\", qop=\"auth\"")
    }

    /// The camera base URL of §11.1, with its explicit `:554` — the request line, and therefore the
    /// digest URI, keeps the port the operator wrote.
    static let cameraBase = "rtsp://192.168.1.64:554/Streaming/Channels/101"

    /// The NVR base URL of §11.2.
    static let nvrBase = "rtsp://192.168.1.200:554/Streaming/Channels/301"
}
