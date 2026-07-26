//
//  SyntheticRTSPServer.swift
//  VigilTestKit
//
//  A Hikvision camera that exists only as a function from client bytes to server bytes: OPTIONS,
//  a 401 Digest challenge it actually verifies, DESCRIBE with a real SDP, SETUP, PLAY,
//  GET_PARAMETER keepalives and TEARDOWN, plus interleaved RTP/RTCP produced on a virtual clock.
//  No sockets, no threads, no wall clock — so a ten-minute soak runs in milliseconds.
//  Implements docs/ARCHITECTURE.md §10.2 ("The server API").
//

import Foundation
import VigilProtocols

// MARK: - Request

/// One header field as received, preserving the case the client sent.
public struct SyntheticHeaderField: Sendable, Hashable {
    public var name: String
    public var value: String
}

/// A request the synthetic camera received.
///
/// Deliberately not `VigilRTSP.RTSPRequest`: the fixture must be able to observe a *malformed*
/// request without going through the client's own parser, or a bug in that parser would hide
/// itself from the assertion that is meant to catch it.
public struct SyntheticRTSPRequest: Sendable, Hashable {

    public var method: String
    public var uri: String
    public var version: String
    public var headers: [SyntheticHeaderField]
    public var body: Data

    /// The first header with `name`, matched ASCII-case-insensitively, or `nil`.
    public func header(_ name: String) -> String? {
        let target = name.lowercased()
        return headers.first { $0.name.lowercased() == target }?.value
    }

    /// The `CSeq` value verbatim, or `"0"` when the client omitted it.
    public var cseq: String { header("CSeq") ?? "0" }
}

// MARK: - State

/// Where the synthetic session is.
public enum SyntheticSessionState: String, Sendable, Hashable, CaseIterable {
    case initial, described, setUp, playing, paused, tornDown
}

// MARK: - Server

/// The synthetic camera.
///
/// Drive it from a test loop: hand it the bytes the client wrote with ``ingest(_:)``, advance the
/// virtual clock with ``tick(nowNanos:)``, and compare what came out of the pipeline against
/// ``groundTruth``. Every run is byte-identical for a given `profile.seed`.
public struct SyntheticRTSPServer: Sendable {

    // MARK: Configuration

    private let profile: SyntheticCameraProfile
    private let host: String
    private let sdpBuilder: SyntheticSDPBuilder

    // MARK: Media

    private var encoder: SyntheticEncoder
    private var generator: RTPStreamGenerator
    private let startTimestamp: UInt32

    // MARK: Session

    /// Bytes received but not yet forming a complete request.
    private var inputBuffer: [UInt8] = []

    /// The nonce currently offered. Rotated by ``Quirk/digestStaleNonce(afterRequests:)``.
    private var nonce: String

    /// Nonces already used, so a stale-nonce rotation can be told apart from a replay.
    private var staleChallengeIssued = false

    private var random: SplitMix64RandomSource

    /// Virtual nanoseconds at which PLAY was answered, or `nil` before that.
    private var playStartNanos: UInt64?

    /// Virtual nanoseconds of the last RTCP sender report.
    private var lastReportNanos: UInt64 = 0

    // MARK: Observable

    public private(set) var receivedRequests: [SyntheticRTSPRequest] = []
    public private(set) var state: SyntheticSessionState = .initial

    /// Access units handed to the packetizer so far.
    public private(set) var sentAccessUnitCount: Int = 0

    /// `401` responses the camera issued.
    public private(set) var challengeCount: Int = 0

    /// Requests that carried an `Authorization` header the camera accepted.
    public private(set) var authenticatedRequestCount: Int = 0

    /// Requests that carried an `Authorization` header the camera rejected, with the reason.
    public private(set) var rejections: [String] = []

    /// Interleaved frames the client sent back, which on this session means RTCP receiver reports.
    public private(set) var receivedInterleavedCount: Int = 0

    /// The SDP the camera answers DESCRIBE with. Stable for the life of the server.
    public let advertisedSDP: String

    /// The oracle for pipeline assertions.
    public private(set) var groundTruth = GroundTruth()

    /// The RTSP session identifier the camera issued at SETUP.
    public let sessionID: String

    /// Interleaved channel carrying RTP. RTCP is this plus one, per RFC 2326 §10.12.
    public private(set) var videoChannel: UInt8 = 0

    // MARK: Init

    /// Creates a camera.
    ///
    /// - Parameter host: the address the camera believes it is reachable at. Only ever appears
    ///   inside SDP and `Content-Base`; nothing here opens a socket.
    public init(profile: SyntheticCameraProfile, host: String = "192.0.2.10") {
        self.profile = profile
        self.host = host
        var source = SplitMix64RandomSource(seed: profile.seed)
        let ssrc = UInt32(truncatingIfNeeded: source.next()) | 1
        let sequence = UInt16(truncatingIfNeeded: source.next())
        let timestamp = profile.quirks.contains(.timestampWrapSoon)
            ? UInt32(0xFFFF_F000)
            : UInt32(truncatingIfNeeded: source.next())
        nonce = source.hexString(count: 32)
        sessionID = String(source.next() % 1_000_000_000)
        startTimestamp = timestamp
        encoder = SyntheticEncoder(profile: profile, startTimestamp: timestamp)
        generator = RTPStreamGenerator(profile: profile, ssrc: ssrc, startSequence: sequence)
        sdpBuilder = SyntheticSDPBuilder(profile: profile, host: host,
                                         sessionVersion: source.next() % 9_000_000_000 + 1_000_000_000)
        random = source

        let setBuilder = SyntheticParameterSetBuilder(width: profile.width, height: profile.height,
                                                      frameRate: profile.frameRate,
                                                      codec: profile.videoCodec)
        advertisedSDP = sdpBuilder.body(parameterSetNALs: setBuilder.parameterSetNALs())
        groundTruth.parameterSets = setBuilder.parameterSets()
        groundTruth.geometry = setBuilder.geometry
        groundTruth.frameRate = profile.frameRate
        groundTruth.seed = profile.seed
    }

    // MARK: Inspection

    /// The base URL the camera advertises for track control resolution.
    public var contentBase: String { sdpBuilder.contentBase }

    /// The sequence number of the first RTP packet, as reported in `RTP-Info`.
    public var firstSequenceNumber: UInt16 { generator.startSequence }

    /// The RTP timestamp of the first access unit, as reported in `RTP-Info`.
    public var firstRTPTimestamp: UInt32 { startTimestamp }

    // MARK: Client bytes in, server bytes out

    /// Consumes the bytes a client wrote and returns the bytes the camera writes back immediately.
    ///
    /// Responses only: media comes from ``tick(nowNanos:)``. Partial requests are buffered, so a
    /// client that dribbles a request one byte at a time gets the same answer as one that writes it
    /// whole. Bytes that cannot be parsed as a request line are discarded up to the next CRLF
    /// rather than throwing, because a real camera does not close on one bad line.
    public mutating func ingest(_ bytes: Data) -> Data {
        inputBuffer.append(contentsOf: bytes)
        var out = Data()
        while let request = takeRequest() {
            receivedRequests.append(request)
            out.append(respond(to: request))
        }
        return out
    }

    /// Advances the virtual clock and returns interleaved media the camera would have sent by now.
    ///
    /// Idempotent for a non-advancing `nowNanos`: the frame schedule is derived from the count of
    /// access units already sent, not from the size of the step, so calling twice at the same
    /// instant produces bytes once.
    public mutating func tick(nowNanos: UInt64) -> Data {
        guard state == .playing else { return Data() }
        let start = playStartNanos ?? nowNanos
        if playStartNanos == nil {
            playStartNanos = nowNanos
            lastReportNanos = nowNanos
        }
        guard nowNanos >= start else { return Data() }
        let elapsed = Double(nowNanos - start) / 1_000_000_000

        var out = [UInt8]()
        // Bounded per call so one enormous time step cannot make a single tick unbounded work; the
        // remainder is produced by the next tick, because the schedule is stateful.
        var produced = 0
        while Double(sentAccessUnitCount) * profile.framePeriodSeconds <= elapsed, produced < 512 {
            let unit = encoder.nextAccessUnit()
            let ticks = Int64(unit.index) * Int64(profile.ticksPerFrame)
            groundTruth.record(unit, unwrappedTicks: ticks)
            for packet in generator.packetize(unit) {
                out.append(contentsOf: Self.interleaved(channel: videoChannel, payload: packet.bytes))
            }
            sentAccessUnitCount += 1
            produced += 1
        }

        // One RTCP sender report every five seconds of virtual time, on the odd channel.
        if nowNanos &- lastReportNanos >= 5_000_000_000 {
            lastReportNanos = nowNanos
            let seconds = UInt32(clamping: Int(elapsed) + 2_208_988_800)
            let report = generator.senderReport(ntpSeconds: seconds, ntpFraction: 0,
                                                rtpTimestamp: startTimestamp
                                                    &+ UInt32(clamping: Int(elapsed * 90_000)),
                                                cname: "synthetic@\(host)")
            out.append(contentsOf: Self.interleaved(channel: videoChannel &+ 1, payload: report))
        }

        groundTruth.injectedPacketLosses = generator.droppedSequenceNumbers
        groundTruth.emittedPacketCount = generator.emittedPacketCount
        groundTruth.damagedAccessUnits = generator.damagedAccessUnits
        return Data(out)
    }

    /// Frames a payload for RTP-over-RTSP interleaved transport (RFC 2326 §10.12).
    private static func interleaved(channel: UInt8, payload: [UInt8]) -> [UInt8] {
        let length = UInt16(clamping: payload.count)
        return [0x24, channel, UInt8(truncatingIfNeeded: length >> 8),
                UInt8(truncatingIfNeeded: length)] + payload
    }

    // MARK: Request framing

    /// Pulls one complete request out of `inputBuffer`, or returns `nil` if more bytes are needed.
    ///
    /// A client on a TCP-interleaved session sends RTCP receiver reports back inside `$` frames on
    /// the same connection. Those are consumed here and counted, never parsed as requests — a
    /// server that mistook them for text would desynchronise, which is a bug the fixture must not
    /// have while it is busy testing the client for the same fault.
    private mutating func takeRequest() -> SyntheticRTSPRequest? {
        while let first = inputBuffer.first, first == 0x24 {
            guard inputBuffer.count >= 4 else { return nil }
            let length = Int(inputBuffer[2]) << 8 | Int(inputBuffer[3])
            guard inputBuffer.count >= 4 + length else { return nil }
            receivedInterleavedCount += 1
            inputBuffer.removeFirst(4 + length)
        }
        guard let terminator = Self.findDoubleCRLF(inputBuffer) else { return nil }
        let headerBytes = Array(inputBuffer[0..<terminator])
        let text = String(decoding: headerBytes, as: UTF8.self)
        var lines = text.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else {
            inputBuffer.removeFirst(terminator + 4)
            return nil
        }
        let startLine = lines.removeFirst()
        let parts = startLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3 else {
            // Unparseable start line: drop the whole block and wait for the next one.
            inputBuffer.removeFirst(terminator + 4)
            return nil
        }
        var fields: [SyntheticHeaderField] = []
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon]).trimmingASCIIWhitespace()
            let value = String(line[line.index(after: colon)...]).trimmingASCIIWhitespace()
            fields.append(SyntheticHeaderField(name: name, value: value))
        }
        let lengthField = fields.first { $0.name.lowercased() == "content-length" }?.value
        let bodyLength = Swift.max(0, Int(lengthField ?? "0") ?? 0)
        let bodyStart = terminator + 4
        guard inputBuffer.count >= bodyStart + bodyLength else { return nil }
        let body = Data(inputBuffer[bodyStart..<(bodyStart + bodyLength)])
        inputBuffer.removeFirst(bodyStart + bodyLength)
        return SyntheticRTSPRequest(method: parts[0], uri: parts[1], version: parts[2],
                                    headers: fields, body: body)
    }

    /// Index of the first `\r\n\r\n`, or `nil`.
    private static func findDoubleCRLF(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for index in 0...(bytes.count - 4) where bytes[index] == 0x0D && bytes[index + 1] == 0x0A
            && bytes[index + 2] == 0x0D && bytes[index + 3] == 0x0A {
            return index
        }
        return nil
    }

    // MARK: Responses

    private mutating func respond(to request: SyntheticRTSPRequest) -> Data {
        let method = request.method.uppercased()
        if method == "OPTIONS" {
            return response(status: 200, reason: "OK", cseq: request.cseq, extra: [
                ("Public", "OPTIONS, DESCRIBE, SETUP, TEARDOWN, PLAY, PAUSE, GET_PARAMETER, SET_PARAMETER"),
            ])
        }
        if let challenge = authenticationFailure(for: request) {
            return challenge
        }
        switch method {
        case "DESCRIBE": return describeResponse(request)
        case "SETUP": return setupResponse(request)
        case "PLAY": return playResponse(request)
        case "PAUSE":
            state = .paused
            return response(status: 200, reason: "OK", cseq: request.cseq,
                            extra: [("Session", sessionID)])
        case "GET_PARAMETER":
            guard profile.supportsGetParameter else {
                return response(status: 501, reason: "Not Implemented", cseq: request.cseq)
            }
            return response(status: 200, reason: "OK", cseq: request.cseq,
                            extra: [("Session", sessionID)])
        case "SET_PARAMETER":
            return response(status: 200, reason: "OK", cseq: request.cseq,
                            extra: [("Session", sessionID)])
        case "TEARDOWN":
            state = .tornDown
            return response(status: 200, reason: "OK", cseq: request.cseq,
                            extra: [("Session", sessionID)])
        default:
            return response(status: 501, reason: "Not Implemented", cseq: request.cseq)
        }
    }

    private mutating func describeResponse(_ request: SyntheticRTSPRequest) -> Data {
        state = .described
        var extra: [(String, String)] = [("Content-Type", "application/sdp")]
        if !profile.quirks.contains(.noContentBase) {
            extra.append(("Content-Base", contentBase))
        }
        return response(status: 200, reason: "OK", cseq: request.cseq, extra: extra,
                        body: Data(advertisedSDP.utf8))
    }

    private mutating func setupResponse(_ request: SyntheticRTSPRequest) -> Data {
        // Echo the interleaved channel pair the client asked for; default to 0-1 when it did not
        // say, which is what a camera does with a bare `RTP/AVP/TCP` transport line.
        let transport = request.header("Transport") ?? "RTP/AVP/TCP;unicast;interleaved=0-1"
        if let range = transport.range(of: "interleaved="),
           let first = transport[range.upperBound...].split(separator: "-").first,
           let channel = UInt8(first.trimmingASCIIWhitespace()) {
            videoChannel = channel
        }
        state = .setUp
        let echoed = "RTP/AVP/TCP;unicast;interleaved=\(videoChannel)-\(videoChannel &+ 1)"
        return response(status: 200, reason: "OK", cseq: request.cseq, extra: [
            ("Transport", echoed),
            ("Session", "\(sessionID);timeout=\(profile.sessionTimeoutSeconds)"),
        ])
    }

    private mutating func playResponse(_ request: SyntheticRTSPRequest) -> Data {
        state = .playing
        playStartNanos = nil
        let url = profile.quirks.contains(.absoluteControlURL)
            ? sdpBuilder.trackControl
            : contentBase + "trackID=1"
        let info = "url=\(url);seq=\(firstSequenceNumber);rtptime=\(firstRTPTimestamp)"
        return response(status: 200, reason: "OK", cseq: request.cseq, extra: [
            ("Session", sessionID),
            ("Range", "npt=0.000-"),
            ("RTP-Info", info),
        ])
    }

    /// Builds a response block.
    private func response(status: Int, reason: String, cseq: String,
                          extra: [(String, String)] = [], body: Data = Data()) -> Data {
        var text = "RTSP/1.0 \(status) \(reason)\r\n"
        text += "CSeq: \(cseq)\r\n"
        text += "Server: Hikvision-Webs/\(profile.firmware)\r\n"
        for (name, value) in extra {
            text += "\(name): \(value)\r\n"
        }
        if !body.isEmpty {
            text += "Content-Length: \(body.count)\r\n"
        }
        text += "\r\n"
        var out = Data(text.utf8)
        out.append(body)
        return out
    }

    // MARK: Authentication

    /// Returns a `401` response when the request must be challenged, or `nil` when it may proceed.
    private mutating func authenticationFailure(for request: SyntheticRTSPRequest) -> Data? {
        guard profile.authMode.requiresCredential else { return nil }
        let authorization = request.header("Authorization")

        if profile.quirks.contains(.wrongPasswordAlways) {
            if authorization != nil {
                rejections.append("wrongPasswordAlways: credential rejected by policy")
            }
            return challengeResponse(cseq: request.cseq, stale: false)
        }

        guard let authorization else {
            return challengeResponse(cseq: request.cseq, stale: false)
        }

        // A stale nonce arrives mid-session: the credential is right, the nonce has expired. The
        // client must retry against the new nonce without counting a credential failure.
        if let after = profile.quirks.staleNonceAfterRequests,
           !staleChallengeIssued, authenticatedRequestCount >= after {
            staleChallengeIssued = true
            nonce = random.hexString(count: 32)
            return challengeResponse(cseq: request.cseq, stale: true)
        }

        let verdict: SyntheticDigest.Verdict
        switch profile.authMode {
        case .none:
            verdict = .accepted
        case .basic:
            guard authorization.lowercased().hasPrefix("basic") else {
                return challengeResponse(cseq: request.cseq, stale: false)
            }
            verdict = SyntheticDigest.verifyBasic(authorization, username: profile.username,
                                                  password: profile.password)
        case .digestNoQop, .digestQopAuth:
            guard authorization.lowercased().hasPrefix("digest") else {
                return challengeResponse(cseq: request.cseq, stale: false)
            }
            verdict = SyntheticDigest.verifyDigest(
                authorization, method: request.method.uppercased(), username: profile.username,
                password: profile.password, realm: profile.realm, expectedNonce: nonce,
                requireQop: profile.authMode == .digestQopAuth
            )
        }

        switch verdict {
        case .accepted:
            authenticatedRequestCount += 1
            return nil
        case .missing:
            return challengeResponse(cseq: request.cseq, stale: false)
        case let .rejected(reason):
            rejections.append("\(request.method): \(reason)")
            return challengeResponse(cseq: request.cseq, stale: false)
        }
    }

    /// A `401 Unauthorized` carrying the camera's challenge.
    private mutating func challengeResponse(cseq: String, stale: Bool) -> Data {
        challengeCount += 1
        let value: String
        switch profile.authMode {
        case .basic:
            value = "Basic realm=\"\(profile.realm)\""
        case .digestNoQop:
            value = "Digest realm=\"\(profile.realm)\", nonce=\"\(nonce)\", "
                + "stale=\"\(stale ? "TRUE" : "FALSE")\""
        case .digestQopAuth:
            value = "Digest realm=\"\(profile.realm)\", nonce=\"\(nonce)\", qop=\"auth\", "
                + "stale=\"\(stale ? "TRUE" : "FALSE")\""
        case .none:
            value = "Basic realm=\"\(profile.realm)\""
        }
        return response(status: 401, reason: "Unauthorized", cseq: cseq,
                        extra: [("WWW-Authenticate", value)])
    }
}
