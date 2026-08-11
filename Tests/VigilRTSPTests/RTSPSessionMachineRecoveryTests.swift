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

extension RTSPSessionMachineSuite {
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
        var harness = playingHarness()
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
        var harness = playingHarness()
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
        var harness = playingHarness()
        #expect(kinds(harness.send(.teardown))
            == ["stateChanged(tearingDown)", "send", "setTimer(request:5)",
                "setTimer(teardownGrace)"])
        #expect(kinds(harness.feed(Server.status(200, reason: "OK", cseq: 5)))
            == ["cancelTimer(request:5)", "setTimer(sessionExpiry)", "stateChanged(closed)",
                "closeTransport(normal)"])
        #expect(harness.machine.state == .closed)
    }

    @Test func sessionMachineAnswersAServerAnnounceAndActsOnEndOfStream() throws {
        var harness = playingHarness()
        let announce = Array("""
            ANNOUNCE rtsp://192.168.1.64:554/Streaming/Channels/101 RTSP/1.0\r
            CSeq: 1\r
            Session: 1885573958\r
            Notice: 2101 End-of-Stream Reached; event-date=20240115T093000Z\r
            \r\n
            """.utf8)
        let produced = harness.feed(announce)
        let actions = kinds(produced)
        #expect(actions == ["send", "stateChanged(paused)"])
        #expect(produced.contains { action in
            guard case .log(.transcript(let text)) = action else { return false }
            return text.contains(">>> RESPONSE") && text.contains("RTSP/1.0 200 OK")
        })
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
        var harness = playingHarness()
        harness.advance(.seconds(5))
        #expect(kinds(harness.fire(.firstMediaTimeout))
            == ["stateChanged(failed)", "fail(timeout(firstMedia))"])
    }

    @Test func sessionMachineTimesOutWhenAPlayingStreamGoesIdle() throws {
        var harness = playingHarness()
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
        var harness = playingHarness()
        harness.advance(.seconds(60))
        #expect(kinds(harness.fire(.sessionExpiry))
            == ["stateChanged(failed)", "fail(timeout(sessionExpiry))"])
    }

    @Test func sessionMachineClosesRatherThanFailingWhenTeardownTimesOut() throws {
        var harness = playingHarness()
        harness.send(.teardown)
        harness.advance(.seconds(2))
        // We are closing anyway: a missing TEARDOWN response is not a failure worth reporting.
        #expect(kinds(harness.fire(.requestTimeout(cseq: 5)))
            == ["stateChanged(closed)", "closeTransport(normal)"])
        #expect(harness.machine.state == .closed)
    }

    @Test func sessionMachineTreatsAnUnexpectedConnectionCloseAsAFailure() throws {
        var harness = playingHarness()
        let actions = kinds(harness.machine.connectionClosed(error: "reset by peer",
                                                             now: harness.now))
        #expect(actions.first == "stateChanged(failed)")
        #expect(actions.last?.hasPrefix("fail(") == true)
    }

    @Test func sessionMachineTreatsACloseWhileTearingDownAsNormal() throws {
        var harness = playingHarness()
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
        var harness = playingHarness()
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
}
