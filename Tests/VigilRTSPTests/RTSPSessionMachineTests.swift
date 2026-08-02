//
//  RTSPSessionMachineTests.swift
//  VigilRTSPTests
//
//  The session machine driven entirely by canned bytes and a fake clock: the full
//  OPTIONS → DESCRIBE → SETUP → PLAY sequence with its exact action order, the 401 paths, the
//  ordering contract around media that arrives before PLAY completes, and a timeout in each state.
//  Covers docs/spec-rtsp.md §12, §14, §15 and docs/API_CONTRACT.md §4.3, §2 R-25, §2 R-26.
//

import Foundation
import Testing
import VigilProtocols
@testable import VigilRTSP

/// A deterministic driver: it holds the machine, a monotonic instant it advances by hand, and a
/// running list of every action produced, so a test can assert on the whole session.
private struct Harness {

    var machine: RTSPSessionMachine
    var now = MediaInstant.zero
    private(set) var actions: [RTSPAction] = []

    init(setupAudio: Bool = false, credential: Credential? = nil,
         initialScale: Double? = nil, initialDisableRateControl: Bool = false) {
        var config = RTSPSessionConfig(url: Harness.cameraURL)
        config.setupAudio = setupAudio
        config.initialScale = initialScale
        config.initialDisableRateControl = initialDisableRateControl
        machine = RTSPSessionMachine(config: config,
                                     credential: credential,
                                     random: SplitMix64RandomSource(seed: 0xC0FFEE),
                                     now: .zero)
    }

    static var cameraURL: RTSPURL {
        RTSPURL(string: "rtsp://192.168.1.64:554/Streaming/Channels/101")
            ?? RTSPURL(scheme: "rtsp", host: "192.168.1.64", port: 554,
                       path: "/Streaming/Channels/101")
    }

    static let credential = Credential(account: "admin", secret: "Hik12345")

    mutating func advance(_ duration: Duration) { now = now + duration }

    @discardableResult
    mutating func send(_ command: RTSPCommand) -> [RTSPAction] {
        let produced = machine.handle(command, now: now)
        actions += produced
        return produced
    }

    @discardableResult
    mutating func feed(_ bytes: [UInt8]) -> [RTSPAction] {
        let produced = machine.ingest(bytes, now: now)
        actions += produced
        return produced
    }

    @discardableResult
    mutating func fire(_ timer: RTSPTimerID) -> [RTSPAction] {
        let produced = machine.timerFired(timer, now: now)
        actions += produced
        return produced
    }

    /// Every `.send` payload, concatenated: exactly the client's byte stream (§14.6 item 6).
    var clientStream: String {
        var out = Data()
        for action in actions {
            if case let .send(data) = action { out.append(data) }
        }
        return String(decoding: out, as: UTF8.self)
    }

    var requestLines: [String] {
        clientStream.components(separatedBy: "\r\n").filter { $0.hasSuffix(" RTSP/1.0") }
    }
}

/// A one-word summary of an action, so a test can assert an exact *sequence* without pinning every
/// payload byte. Payloads are asserted separately where they matter.
private func kind(_ action: RTSPAction) -> String {
    switch action {
    case .send: "send"
    case .sendInterleaved: "sendInterleaved"
    case let .setTimer(id, _): "setTimer(\(timerName(id)))"
    case let .cancelTimer(id): "cancelTimer(\(timerName(id)))"
    case .emitTrack: "emitTrack"
    case .emitTiming: "emitTiming"
    case .emitMedia: "emitMedia"
    case .ready: "ready"
    case let .stateChanged(state): "stateChanged(\(stateName(state)))"
    case .log: "log"
    case .setReadBackpressure: "setReadBackpressure"
    case let .fail(error): "fail(\(errorName(error)))"
    case let .closeTransport(reason): "closeTransport(\(reason.rawValue))"
    case .reconnect: "reconnect"
    }
}

private func timerName(_ id: RTSPTimerID) -> String {
    switch id {
    case .keepalive: "keepalive"
    case let .requestTimeout(cseq): "request:\(cseq)"
    case .firstMediaTimeout: "firstMedia"
    case .dataIdle: "dataIdle"
    case .sessionExpiry: "sessionExpiry"
    case .teardownGrace: "teardownGrace"
    }
}

/// A stable short name for an error, so an assertion does not depend on how Swift happens to print
/// a nested enum from another module.
private func errorName(_ error: RTSPError) -> String {
    switch error {
    case let .timeout(id): "timeout(\(timerName(id)))"
    case let .sdpParse(detail): "sdpParse(\(detail))"
    case let .unexpectedStatus(code): "unexpectedStatus(\(code))"
    case let .headerTooLarge(bytes): "headerTooLarge(\(bytes))"
    case let .interleaveDesync(recovered): "interleaveDesync(\(recovered))"
    default: "\(error)"
    }
}

private func stateName(_ state: RTSPSessionState) -> String {
    switch state {
    case .idle: "idle"
    case .awaitingOptions: "awaitingOptions"
    case .awaitingDescribe: "awaitingDescribe"
    case let .authenticating(method): "authenticating(\(method.rawValue))"
    case let .settingUp(index, total): "settingUp(\(index)/\(total))"
    case .awaitingPlay: "awaitingPlay"
    case .playing: "playing"
    case .awaitingPause: "awaitingPause"
    case .paused: "paused"
    case .seeking: "seeking"
    case .tearingDown: "tearingDown"
    case .closed: "closed"
    case .failed: "failed"
    }
}

/// Ignores `.log` actions, which are observability and not part of the ordering contract.
private func kinds(_ actions: [RTSPAction]) -> [String] {
    actions.map(kind).filter { $0 != "log" }
}

// MARK: - Canned server bytes

private enum Server {

    static func options(cseq: Int) -> [UInt8] {
        RTSPWireBytes.response(headers: [
            ("CSeq", String(cseq)),
            ("Public", "OPTIONS, DESCRIBE, PLAY, PAUSE, SETUP, TEARDOWN, SET_PARAMETER, "
                + "GET_PARAMETER"),
        ])
    }

    static func describe(cseq: Int, sdp: String = SDPWireFixture.cameraH264AAC) -> [UInt8] {
        let body = String(decoding: SDPWireFixture.wire(sdp), as: UTF8.self)
        return RTSPWireBytes.response(headers: [
            ("CSeq", String(cseq)),
            ("Content-Type", "application/sdp"),
            ("Content-Base", "rtsp://192.168.1.64:554/Streaming/Channels/101/"),
        ], body: body)
    }

    static func unauthorized(cseq: Int, nonce: String = "3a2f5c8e1b7d4906f2e5a8c1d4b70e93")
        -> [UInt8] {
        RTSPWireBytes.response(status: 401, reason: "Unauthorized", headers: [
            ("CSeq", String(cseq)),
            ("WWW-Authenticate",
             "Digest realm=\"IP Camera(52491)\", nonce=\"\(nonce)\", stale=\"FALSE\""),
        ])
    }

    static func setup(cseq: Int, channels: String = "0-1", session: String = "1885573958")
        -> [UInt8] {
        RTSPWireBytes.response(headers: [
            ("CSeq", String(cseq)),
            ("Session", "\(session);timeout=60"),
            ("Transport",
             "RTP/AVP/TCP;unicast;interleaved=\(channels);ssrc=48A9C1B2;mode=\"play\""),
        ])
    }

    static func play(cseq: Int, session: String = "1885573958") -> [UInt8] {
        RTSPWireBytes.response(headers: [
            ("CSeq", String(cseq)),
            ("Session", session),
            ("RTP-Info", "url=rtsp://192.168.1.64:554/Streaming/Channels/101/trackID=1;"
                + "seq=52937;rtptime=2599730432"),
            ("Range", "npt=0.000-"),
        ])
    }

    static func status(_ code: Int, reason: String, cseq: Int) -> [UInt8] {
        RTSPWireBytes.response(status: code, reason: reason, headers: [("CSeq", String(cseq))])
    }
}

@Suite struct RTSPSessionMachineSuite {

    // MARK: - The happy path

    @Test func sessionMachineRunsTheFullConnectSequenceInExactOrder() throws {
        var harness = Harness()

        #expect(kinds(harness.send(.start))
            == ["stateChanged(awaitingOptions)", "send", "setTimer(request:1)"])

        harness.advance(.milliseconds(4))
        #expect(kinds(harness.feed(Server.options(cseq: 1)))
            == ["cancelTimer(request:1)", "stateChanged(awaitingDescribe)", "send",
                "setTimer(request:2)"])

        harness.advance(.milliseconds(9))
        #expect(kinds(harness.feed(Server.describe(cseq: 2)))
            == ["cancelTimer(request:2)", "stateChanged(settingUp(0/1))", "send",
                "setTimer(request:3)"])

        harness.advance(.milliseconds(6))
        #expect(kinds(harness.feed(Server.setup(cseq: 3)))
            == ["cancelTimer(request:3)", "emitTrack", "stateChanged(awaitingPlay)", "send",
                "setTimer(request:4)"])

        harness.advance(.milliseconds(7))
        // The timing seed precedes `.ready`, and both precede any media (§14.6 items 2 and 3).
        #expect(kinds(harness.feed(Server.play(cseq: 4)))
            == ["cancelTimer(request:4)", "setTimer(sessionExpiry)", "stateChanged(playing)",
                "emitTiming", "ready", "setTimer(firstMedia)", "setTimer(keepalive)"])

        #expect(harness.machine.state == .playing)
        #expect(harness.machine.sessionID == "1885573958")
        #expect(harness.machine.interleavedChannels == [0, 1])
        #expect(harness.machine.negotiatedTransport == .tcpInterleaved)

        // The client byte stream, in order, is exactly the four requests of docs/spec-rtsp.md §11.1.
        #expect(harness.requestLines == [
            "OPTIONS rtsp://192.168.1.64:554/Streaming/Channels/101 RTSP/1.0",
            "DESCRIBE rtsp://192.168.1.64:554/Streaming/Channels/101 RTSP/1.0",
            "SETUP rtsp://192.168.1.64:554/Streaming/Channels/101/trackID=1 RTSP/1.0",
            "PLAY rtsp://192.168.1.64:554/Streaming/Channels/101 RTSP/1.0",
        ])
        #expect(harness.clientStream.contains("Transport: RTP/AVP/TCP;unicast;interleaved=0-1"))
        #expect(harness.clientStream.contains("Accept: application/sdp"))
        #expect(harness.clientStream.contains("Range: npt=0.000-"))
        #expect(harness.clientStream.contains("Session: 1885573958"))
        // Normal speed sends neither header. `Scale: 1.0` is legal and redundant, and firmware that
        // treats its presence as "this is a trick-play session" exists.
        #expect(!harness.clientStream.contains("Scale:"))
        #expect(!harness.clientStream.contains("Rate-Control:"))
    }

    /// The handshake's own `PLAY` carries the speed, because on some firmware it is the only `PLAY`
    /// that will be honoured.
    ///
    /// A second `PLAY` on an established session is the textbook way to change speed and this
    /// machine can send one — but a DS-I256 on V5.5.6 refuses a second `PLAY` outright, which
    /// docs/PLAYBACK-LATENCY.md records after in-session seeking was tried on hardware and
    /// reverted. So a speed change is a reconnect that seeds the scale into the handshake, and this
    /// is the test that the seeding reaches the wire.
    @Test func sessionMachineCarriesTheConfiguredScaleOnTheHandshakePlay() throws {
        var harness = Harness(initialScale: 8, initialDisableRateControl: true)

        harness.send(.start)
        harness.feed(Server.options(cseq: 1))
        harness.feed(Server.describe(cseq: 2))
        harness.feed(Server.setup(cseq: 3))

        #expect(harness.clientStream.contains("Scale: 8"))
        // Above 2x this is the difference between fast-forward and eight seconds of video per
        // eight seconds: without it the camera keeps pacing at wall-clock speed.
        #expect(harness.clientStream.contains("Rate-Control: no"))
        #expect(harness.machine.state == .awaitingPlay)
    }

    /// Reverse playback is a negative scale, and nothing else changes.
    @Test func sessionMachineSerialisesAReverseScale() throws {
        var harness = Harness(initialScale: -2)

        harness.send(.start)
        harness.feed(Server.options(cseq: 1))
        harness.feed(Server.describe(cseq: 2))
        harness.feed(Server.setup(cseq: 3))

        #expect(harness.clientStream.contains("Scale: -2"))
        // Not requested, so not sent: reverse at 2x is still paced playback.
        #expect(!harness.clientStream.contains("Rate-Control:"))
    }

    @Test func sessionMachineEmitsTrackTimingAndDescriptionFromTheSDP() throws {
        var harness = Harness()
        harness.send(.start)
        harness.feed(Server.options(cseq: 1))
        harness.feed(Server.describe(cseq: 2))
        harness.feed(Server.setup(cseq: 3))
        harness.advance(.milliseconds(11))
        harness.feed(Server.play(cseq: 4))

        let track = try #require(harness.actions.compactMap { action -> RTSPTrack? in
            guard case let .emitTrack(track) = action else { return nil }
            return track
        }.first)
        #expect(track.id == 0)
        #expect(track.kind == .video)
        #expect(track.codec == .video(.h264))
        #expect(track.clockRate == 90_000)
        #expect(track.payloadType == 96)
        #expect(track.controlURI == "rtsp://192.168.1.64:554/Streaming/Channels/101/trackID=1")
        #expect(track.interleavedChannels == 0...1)
        #expect(track.ssrc == 0x48A9_C1B2)
        #expect(track.parameterSets?.sps.count == 1)
        #expect(track.packetizationMode == 1)

        let timing = try #require(harness.actions.compactMap { action -> RTSPTrackTiming? in
            guard case let .emitTiming(timing) = action else { return nil }
            return timing
        }.first)
        // Raw seeds only: VigilRTSP performs no timestamp arithmetic (API_CONTRACT §2 R-26).
        #expect(timing.trackID == 0)
        #expect(timing.clockRate == 90_000)
        #expect(timing.initialSequence == 52_937)
        #expect(timing.initialRTPTimestamp == 2_599_730_432)
        #expect(timing.scale == 1.0)
        #expect(timing.isRateControlDisabled == false)
        #expect(timing.playResponseInstant == harness.now)

        let description = try #require(harness.actions.compactMap { action
            -> RTSPSessionDescription? in
            guard case let .ready(description) = action else { return nil }
            return description
        }.first)
        #expect(description.sessionID == "1885573958")
        #expect(description.sessionTimeout == .seconds(60))
        #expect(description.tracks.count == 1)
        #expect(description.rangeText == "npt=0.000-")
        #expect(description.serverPublicMethods.contains(.getParameter))
        #expect(description.sdp.media.count == 2)      // The SDP keeps the audio it did not set up.
    }

    @Test func sessionMachineSetsUpBothTracksWhenAudioIsRequested() throws {
        var harness = Harness(setupAudio: true)
        harness.send(.start)
        harness.feed(Server.options(cseq: 1))
        harness.feed(Server.describe(cseq: 2))
        // No session-expiry re-arm on the first SETUP: there is no session id until it answers.
        #expect(kinds(harness.feed(Server.setup(cseq: 3)))
            == ["cancelTimer(request:3)", "emitTrack", "stateChanged(settingUp(1/2))", "send",
                "setTimer(request:4)"])
        #expect(kinds(harness.feed(Server.setup(cseq: 4, channels: "2-3")))
            == ["cancelTimer(request:4)", "setTimer(sessionExpiry)", "emitTrack",
                "stateChanged(awaitingPlay)", "send", "setTimer(request:5)"])
        #expect(harness.machine.interleavedChannels == [0, 1, 2, 3])
        #expect(harness.machine.tracks.count == 2)
        #expect(harness.requestLines.contains(
            "SETUP rtsp://192.168.1.64:554/Streaming/Channels/101/trackID=2 RTSP/1.0"))
        #expect(harness.clientStream.contains("interleaved=2-3"))
    }

    // MARK: - Media ordering

    @Test func sessionMachineBuffersMediaArrivingBeforeThePlayResponse() throws {
        var harness = Harness()
        harness.send(.start)
        harness.feed(Server.options(cseq: 1))
        harness.feed(Server.describe(cseq: 2))
        harness.feed(Server.setup(cseq: 3))

        // The first RTP frames beat the PLAY response out of the device. They must not be emitted
        // before the timing seed, or VigilRTP would have no origin for them.
        let early = RTSPWireBytes.rtpPayload(byteCount: 24)
        #expect(kinds(harness.feed(RTSPWireBytes.frame(channel: 0, payload: early))).isEmpty)

        let afterPlay = kinds(harness.feed(Server.play(cseq: 4)))
        #expect(afterPlay == ["cancelTimer(request:4)", "setTimer(sessionExpiry)",
                              "stateChanged(playing)", "emitTiming", "emitMedia", "ready",
                              "setTimer(dataIdle)", "setTimer(keepalive)"])

        let media = harness.actions.compactMap { action -> Data? in
            guard case let .emitMedia(_, payload) = action else { return nil }
            return payload
        }
        #expect(media == [Data(early)])
    }

    @Test func sessionMachineDropsTheOldestPreplayFrameWhenTheBufferFills() throws {
        var harness = Harness()
        harness.send(.start)
        harness.feed(Server.options(cseq: 1))
        harness.feed(Server.describe(cseq: 2))
        harness.feed(Server.setup(cseq: 3))

        for index in 0..<70 {
            var payload = RTSPWireBytes.rtpPayload(byteCount: 8)
            payload[7] = UInt8(index)
            harness.feed(RTSPWireBytes.frame(channel: 0, payload: payload))
        }
        harness.feed(Server.play(cseq: 4))

        let media = harness.actions.compactMap { action -> Data? in
            guard case let .emitMedia(_, payload) = action else { return nil }
            return payload
        }
        #expect(media.count == 64)                  // config.maxPreplayMediaFrames
        #expect(media.first?.last == 6)             // Frames 0...5 were dropped, oldest first.
        #expect(media.last?.last == 69)
        #expect(harness.machine.statistics.preplayFramesDropped == 6)
    }

    @Test func sessionMachineEmitsMediaAndArmsTheIdleTimerWhilePlaying() throws {
        var harness = playing()
        let payload = RTSPWireBytes.rtpPayload(byteCount: 40)
        harness.advance(.milliseconds(30))
        #expect(kinds(harness.feed(RTSPWireBytes.frame(channel: 0, payload: payload)))
            == ["cancelTimer(firstMedia)", "setTimer(dataIdle)", "emitMedia"])
        // A second frame does not re-arm the timer: one action per packet would swamp the driver.
        #expect(kinds(harness.feed(RTSPWireBytes.frame(channel: 0, payload: payload)))
            == ["emitMedia"])
        #expect(harness.machine.statistics.interleavedFrames == 2)
        #expect(harness.machine.statistics.mediaBytesByChannel[0] == 80)
    }

    @Test func sessionMachineForwardsRTCPWithoutTouchingTheSessionState() throws {
        var harness = playing()
        let report: [UInt8] = [0x81, 0xC9, 0x00, 0x07]
        #expect(harness.send(.sendRTCP(channel: 1, payload: Data(report)))
            == [.sendInterleaved(channel: 1, payload: Data(report))])
        #expect(harness.machine.state == .playing)
    }

    // MARK: - Authentication

    @Test func sessionMachineRetriesDescribeAfterA401AndSucceeds() throws {
        var harness = Harness(credential: Harness.credential)
        harness.send(.start)
        harness.feed(Server.options(cseq: 1))

        let retry = kinds(harness.feed(Server.unauthorized(cseq: 2)))
        #expect(retry == ["cancelTimer(request:2)", "stateChanged(authenticating(DESCRIBE))",
                          "send", "setTimer(request:3)"])

        // A retry always takes a NEW CSeq: reusing one breaks Hikvision's pipeline bookkeeping.
        #expect(harness.clientStream.contains("CSeq: 3"))
        #expect(harness.clientStream.contains("Authorization: Digest username=\"admin\""))
        #expect(harness.clientStream.contains("realm=\"IP Camera(52491)\""))
        #expect(harness.clientStream.contains(
            "uri=\"rtsp://192.168.1.64:554/Streaming/Channels/101\""))

        #expect(kinds(harness.feed(Server.describe(cseq: 3)))
            == ["cancelTimer(request:3)", "stateChanged(settingUp(0/1))", "send",
                "setTimer(request:4)"])
        #expect(harness.machine.statistics.authChallenges == 1)
        #expect(harness.machine.statistics.authRetries == 1)
    }

    @Test func sessionMachineTreatsARepeated401AsTerminalAndStopsSending() throws {
        var harness = Harness(credential: Harness.credential)
        harness.send(.start)
        harness.feed(Server.options(cseq: 1))
        harness.feed(Server.unauthorized(cseq: 2))      // First challenge: retry with credentials.
        harness.feed(Server.unauthorized(cseq: 3))      // Same nonce: one compatibility retry.

        let final = kinds(harness.feed(Server.unauthorized(cseq: 4)))
        #expect(final == ["cancelTimer(request:4)", "stateChanged(failed)", "fail(authRejected)"])
        #expect(harness.machine.state == .failed(.authRejected))

        // Exactly two credentialed attempts were made — API_CONTRACT §2 R-25. Hikvision locks an
        // account after about five failures, so a third try is a product bug, not a retry.
        let sent = harness.requestLines.count
        #expect(sent == 4)                              // OPTIONS + three DESCRIBEs
        let authorized = harness.clientStream.components(separatedBy: "Authorization:").count - 1
        #expect(authorized == 2)

        // Terminal really is terminal: nothing further is produced, in any direction.
        harness.advance(.seconds(1))
        #expect(harness.feed(Server.describe(cseq: 5)).isEmpty)
        #expect(harness.send(.play()).isEmpty)
        #expect(harness.fire(.keepalive).isEmpty)
        // …except one teardown acknowledgement, so the driver can close the socket.
        #expect(harness.send(.teardown) == [.closeTransport(reason: .error)])
        #expect(harness.send(.teardown).isEmpty)
    }

    @Test func sessionMachineFailsWithoutACredentialWhenChallenged() throws {
        var harness = Harness()                          // No credential stored.
        harness.send(.start)
        let actions = kinds(harness.feed(Server.unauthorized(cseq: 1)))
        #expect(actions == ["cancelTimer(request:1)", "stateChanged(failed)",
                            "fail(credentialsMissing)"])
    }

    @Test func sessionMachineFailsTerminallyOn403() throws {
        var harness = Harness(credential: Harness.credential)
        harness.send(.start)
        let actions = kinds(harness.feed(Server.status(403, reason: "Forbidden", cseq: 1)))
        #expect(actions == ["cancelTimer(request:1)", "stateChanged(failed)",
                            "fail(accessForbidden)"])
    }

    // MARK: - The R1.2 probe ladder

    @Test func sessionMachineDescribeOnlyReportsTracksAndClosesCleanly() throws {
        var harness = Harness()
        #expect(kinds(harness.send(.describeOnly))
            == ["stateChanged(awaitingDescribe)", "send", "setTimer(request:1)"])
        #expect(harness.requestLines
            == ["DESCRIBE rtsp://192.168.1.64:554/Streaming/Channels/101 RTSP/1.0"])

        #expect(kinds(harness.feed(Server.describe(cseq: 1)))
            == ["cancelTimer(request:1)", "emitTrack", "stateChanged(closed)",
                "closeTransport(normal)"])
        #expect(harness.machine.tracks.first?.codec == .video(.h264))
    }

    @Test func sessionMachineDescribeOnlyAdvancesTheLadderOn404() throws {
        var harness = Harness()
        harness.send(.describeOnly)
        let actions = kinds(harness.feed(Server.status(404, reason: "Not Found", cseq: 1)))
        // closeTransport comes first: `.fail` is always the last action ever produced.
        #expect(actions == ["cancelTimer(request:1)", "closeTransport(ladderAdvance)",
                            "stateChanged(failed)", "fail(pathNotFound)"])
    }

    @Test func sessionMachineAdvancesTheLadderWhenTheSDPHasNoPlayableVideo() throws {
        let audioOnly = """
            v=0
            s=Media Presentation
            a=control:*
            m=audio 0 RTP/AVP 8
            a=control:trackID=2
            a=rtpmap:8 PCMA/8000
            """
        var harness = Harness()
        harness.send(.describeOnly)
        let actions = kinds(harness.feed(Server.describe(cseq: 1, sdp: audioOnly)))
        #expect(actions == ["cancelTimer(request:1)", "closeTransport(ladderAdvance)",
                            "stateChanged(failed)", "fail(noSuitableTrack)"])
    }

    @Test func sessionMachineFailsOnAnUnparseableSDP() throws {
        var harness = Harness()
        harness.send(.describeOnly)
        let body = "this is not an SDP at all"
        let bytes = RTSPWireBytes.response(headers: [("CSeq", "1"),
                                                     ("Content-Type", "application/sdp")],
                                           body: body)
        let actions = kinds(harness.feed(bytes))
        #expect(actions.last == "fail(sdpParse(no m= media section))")
    }

    // MARK: - Keepalive, teardown and server-initiated messages

    @Test func sessionMachineSendsGetParameterKeepaliveOnTheAdvertisedCadence() throws {
        var harness = playing()
        harness.advance(.seconds(20))
        let actions = kinds(harness.fire(.keepalive))
        #expect(actions == ["send", "setTimer(request:5)", "setTimer(keepalive)"])
        #expect(harness.requestLines.last
            == "GET_PARAMETER rtsp://192.168.1.64:554/Streaming/Channels/101 RTSP/1.0")
        #expect(harness.machine.statistics.keepalivesSent == 1)

        // timeout 60 s ⇒ clamp(20, 5, 20) = 20 s.
        guard case let .setTimer(.keepalive, deadline) = harness.actions.last else {
            Issue.record("expected a keepalive re-arm")
            return
        }
        #expect(deadline == harness.now + .seconds(20))
    }

    @Test func sessionMachineSwitchesKeepaliveMethodAfter405() throws {
        var harness = playing()
        harness.advance(.seconds(20))
        harness.fire(.keepalive)
        // A device that refuses GET_PARAMETER is not broken; it wants a different keepalive.
        #expect(kinds(harness.feed(Server.status(405, reason: "Method Not Allowed", cseq: 5)))
            == ["cancelTimer(request:5)", "setTimer(sessionExpiry)"])
        #expect(harness.machine.state == .playing)

        harness.advance(.seconds(20))
        harness.fire(.keepalive)
        // The camera's `Public` lists SET_PARAMETER, which is the next rung of §12.2's table.
        #expect(harness.requestLines.last
            == "SET_PARAMETER rtsp://192.168.1.64:554/Streaming/Channels/101 RTSP/1.0")
    }

    @Test func sessionMachineTearsDownAndCloses() throws {
        var harness = playing()
        #expect(kinds(harness.send(.teardown))
            == ["stateChanged(tearingDown)", "send", "setTimer(request:5)",
                "setTimer(teardownGrace)"])
        #expect(kinds(harness.feed(Server.status(200, reason: "OK", cseq: 5)))
            == ["cancelTimer(request:5)", "setTimer(sessionExpiry)", "stateChanged(closed)",
                "closeTransport(normal)"])
        #expect(harness.machine.state == .closed)
    }

    @Test func sessionMachineAnswersAServerAnnounceAndActsOnEndOfStream() throws {
        var harness = playing()
        let announce = Array("""
            ANNOUNCE rtsp://192.168.1.64:554/Streaming/Channels/101 RTSP/1.0\r
            CSeq: 1\r
            Session: 1885573958\r
            Notice: 2101 End-of-Stream Reached; event-date=20240115T093000Z\r
            \r\n
            """.utf8)
        let actions = kinds(harness.feed(announce))
        #expect(actions == ["send", "stateChanged(paused)"])
        #expect(harness.clientStream.hasSuffix("RTSP/1.0 200 OK\r\nCSeq: 1\r\n"
            + "Session: 1885573958\r\n\r\n"))
        #expect(harness.machine.statistics.serverRequestsReceived == 1)
    }

    @Test func sessionMachineQueuesCommandsBehindAnOutstandingRequest() throws {
        var harness = Harness()
        harness.send(.start)
        #expect(harness.send(.pause).isEmpty)            // Queued behind OPTIONS.
        harness.feed(Server.options(cseq: 1))
        harness.feed(Server.describe(cseq: 2))
        harness.feed(Server.setup(cseq: 3))
        // The queued PAUSE runs as soon as the connection goes idle, which is the moment the PLAY
        // response is consumed — so it appears at the tail of that same action array.
        let afterPlay = kinds(harness.feed(Server.play(cseq: 4)))
        #expect(afterPlay.suffix(3)
            == ["stateChanged(awaitingPause)", "send", "setTimer(request:5)"])
        #expect(harness.machine.step(now: harness.now).isEmpty)
    }

    @Test func sessionMachineFailsWhenTheCommandQueueOverflows() throws {
        var harness = Harness()
        harness.send(.start)
        for _ in 0..<8 { #expect(harness.send(.keepaliveNow).isEmpty) }
        #expect(kinds(harness.send(.keepaliveNow))
            == ["stateChanged(failed)", "fail(commandQueueOverflow)"])
    }

    // MARK: - Timeouts, one per state

    @Test func sessionMachineTimesOutWaitingForOptions() throws {
        var harness = Harness()
        harness.send(.start)
        harness.advance(.seconds(5))
        #expect(kinds(harness.fire(.requestTimeout(cseq: 1)))
            == ["stateChanged(failed)", "fail(timeout(request:1))"])
    }

    @Test func sessionMachineTimesOutWaitingForDescribe() throws {
        var harness = Harness()
        harness.send(.start)
        harness.feed(Server.options(cseq: 1))
        harness.advance(.seconds(5))
        #expect(kinds(harness.fire(.requestTimeout(cseq: 2)))
            == ["stateChanged(failed)", "fail(timeout(request:2))"])
    }

    @Test func sessionMachineTimesOutWaitingForSetup() throws {
        var harness = Harness()
        harness.send(.start)
        harness.feed(Server.options(cseq: 1))
        harness.feed(Server.describe(cseq: 2))
        harness.advance(.seconds(5))
        #expect(kinds(harness.fire(.requestTimeout(cseq: 3)))
            == ["stateChanged(failed)", "fail(timeout(request:3))"])
    }

    @Test func sessionMachineTimesOutWaitingForPlay() throws {
        var harness = Harness()
        harness.send(.start)
        harness.feed(Server.options(cseq: 1))
        harness.feed(Server.describe(cseq: 2))
        harness.feed(Server.setup(cseq: 3))
        harness.advance(.seconds(5))
        #expect(kinds(harness.fire(.requestTimeout(cseq: 4)))
            == ["stateChanged(failed)", "fail(timeout(request:4))"])
    }

    @Test func sessionMachineTimesOutWhenPlaySucceedsButNoMediaArrives() throws {
        var harness = playing()
        harness.advance(.seconds(5))
        #expect(kinds(harness.fire(.firstMediaTimeout))
            == ["stateChanged(failed)", "fail(timeout(firstMedia))"])
    }

    @Test func sessionMachineTimesOutWhenAPlayingStreamGoesIdle() throws {
        var harness = playing()
        harness.advance(.milliseconds(100))
        harness.feed(RTSPWireBytes.frame(channel: 0,
                                         payload: RTSPWireBytes.rtpPayload(byteCount: 16)))
        // Media two seconds ago: not idle yet, so the timer is re-armed rather than fired.
        harness.advance(.seconds(2))
        #expect(kinds(harness.fire(.dataIdle)) == ["setTimer(dataIdle)"])
        harness.advance(.seconds(8))
        #expect(kinds(harness.fire(.dataIdle))
            == ["stateChanged(failed)", "fail(timeout(dataIdle))"])
    }

    @Test func sessionMachineTimesOutOnSessionExpiry() throws {
        var harness = playing()
        harness.advance(.seconds(60))
        #expect(kinds(harness.fire(.sessionExpiry))
            == ["stateChanged(failed)", "fail(timeout(sessionExpiry))"])
    }

    @Test func sessionMachineClosesRatherThanFailingWhenTeardownTimesOut() throws {
        var harness = playing()
        harness.send(.teardown)
        harness.advance(.seconds(2))
        // We are closing anyway: a missing TEARDOWN response is not a failure worth reporting.
        #expect(kinds(harness.fire(.requestTimeout(cseq: 5)))
            == ["stateChanged(closed)", "closeTransport(normal)"])
        #expect(harness.machine.state == .closed)
    }

    @Test func sessionMachineTreatsAnUnexpectedConnectionCloseAsAFailure() throws {
        var harness = playing()
        let actions = kinds(harness.machine.connectionClosed(error: "reset by peer",
                                                             now: harness.now))
        #expect(actions.first == "stateChanged(failed)")
        #expect(actions.last?.hasPrefix("fail(") == true)
    }

    @Test func sessionMachineTreatsACloseWhileTearingDownAsNormal() throws {
        var harness = playing()
        harness.send(.teardown)
        #expect(kinds(harness.machine.connectionClosed(error: nil, now: harness.now))
            == ["stateChanged(closed)"])
    }

    // MARK: - Status handling

    @Test func sessionMachineReportsATransportRefusalOn461() throws {
        var harness = Harness()
        harness.send(.start)
        harness.feed(Server.options(cseq: 1))
        harness.feed(Server.describe(cseq: 2))
        #expect(kinds(harness.feed(Server.status(461, reason: "Unsupported Transport", cseq: 3)))
            == ["cancelTimer(request:3)", "stateChanged(failed)", "fail(transportRejected)"])
    }

    @Test func sessionMachineReportsASessionLossOn454() throws {
        var harness = playing()
        harness.advance(.seconds(20))
        harness.fire(.keepalive)
        #expect(kinds(harness.feed(Server.status(454, reason: "Session Not Found", cseq: 5)))
            == ["cancelTimer(request:5)", "setTimer(sessionExpiry)", "stateChanged(failed)",
                "fail(sessionNotFound)"])
    }

    @Test func sessionMachineFollowsA302Redirect() throws {
        var harness = Harness()
        harness.send(.start)
        let moved = RTSPWireBytes.response(status: 302, reason: "Moved Temporarily", headers: [
            ("CSeq", "1"),
            ("Location", "rtsp://192.168.1.99:554/Streaming/Channels/101"),
        ])
        let actions = kinds(harness.feed(moved))
        #expect(actions == ["cancelTimer(request:1)", "closeTransport(redirect)", "reconnect"])
        #expect(harness.machine.statistics.redirectsFollowed == 1)
    }

    @Test func sessionMachineIgnoresAResponseThatMatchesNoRequest() throws {
        var harness = Harness()
        harness.send(.start)
        harness.feed(Server.options(cseq: 1))
        // CSeq 99 answers nothing we sent.
        #expect(kinds(harness.feed(Server.status(200, reason: "OK", cseq: 99))).isEmpty)
        #expect(harness.machine.state == .awaitingDescribe)
    }

    // MARK: - Helpers

    /// Drives a machine to `.playing` with one video track on channels 0/1.
    private func playing() -> Harness {
        var harness = Harness()
        harness.send(.start)
        harness.feed(Server.options(cseq: 1))
        harness.feed(Server.describe(cseq: 2))
        harness.feed(Server.setup(cseq: 3))
        harness.feed(Server.play(cseq: 4))
        return harness
    }
}
