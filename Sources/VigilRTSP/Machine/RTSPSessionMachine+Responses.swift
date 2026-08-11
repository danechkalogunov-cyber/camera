//
//  RTSPSessionMachine+Responses.swift
//  VigilRTSP
//
//  What arrives back: media, authentication challenges, redirects, and the server's own requests.
//  Split from RTSPSessionMachine.swift, which docs/API_CONTRACT.md §7.2 caps at 600 lines.
//

import Foundation
import VigilProtocols

// MARK: - Responses and server-initiated messages

/// ⚠️ Members are `internal`, not `private`: Swift scopes `private` to one file.
/// `Scripts/lint.py`'s `split-access` rule fails the build on any left behind.
extension RTSPSessionMachine {

    // MARK: - Media

    mutating func handleMedia(channel: UInt8,
                                      payload: Data,
                                      now: MediaInstant) -> [RTSPAction] {
        counters.interleavedFrames += 1
        counters.interleavedBytes += UInt64(payload.count)
        counters.mediaBytesByChannel[channel, default: 0] += UInt64(payload.count)

        guard hasPlayed else {
            var actions: [RTSPAction] = []
            preplayBuffer.append((channel: channel, payload: payload))
            if preplayBuffer.count > config.maxPreplayMediaFrames {
                preplayBuffer.removeFirst()
                counters.preplayFramesDropped += 1
                actions.append(.log(.preplayMediaDropped(count: counters.preplayFramesDropped)))
            }
            return actions
        }

        var actions: [RTSPAction] = []
        if lastMediaAt == nil {
            actions.append(.cancelTimer(.firstMediaTimeout))
            actions.append(.setTimer(.dataIdle, deadline: now + config.dataIdleTimeout))
        }
        lastMediaAt = now
        actions.append(.emitMedia(channel: channel, payload: payload))
        return actions
    }

    /// Folds the framing decoder's resync counter into ours and enforces the rate policy: more
    /// than `maxResyncsPerMinute` in a 60 s window means the link is broken, and one reconnect is
    /// better than endless silent resyncing.
    mutating func noteResyncs(now: MediaInstant) -> [RTSPAction] {
        let observed = decoder.statistics.resyncEvents
        guard observed > counters.framingResyncs else { return [] }
        let added = observed - counters.framingResyncs
        counters.framingResyncs = observed
        for _ in 0..<added { resyncInstants.append(now) }
        resyncInstants.removeAll { now - $0 > .seconds(60) }
        var actions: [RTSPAction] = [
            .log(.framingResync(discarded: Int(decoder.statistics.bytesDiscardedByResync),
                                reason: "lost the unit boundary")),
        ]
        if resyncInstants.count > config.maxResyncsPerMinute {
            actions += terminate(.interleaveDesync(recovered: false))
        }
        return actions
    }

    // MARK: - Authentication

    mutating func handleUnauthorized(_ response: RTSPResponse,
                                             request: PendingRequest,
                                             now: MediaInstant) -> [RTSPAction] {
        counters.authChallenges += 1
        let challenges = response.headers.all("WWW-Authenticate").flatMap(RTSPChallenge.parseAll)
        guard let challenge = challenges.first else { return terminate(.malformedResponse) }

        var actions: [RTSPAction] = [.log(.authChallenged(realm: challenge.realm,
                                                          qop: challenge.qop.first,
                                                          stale: challenge.stale))]
        // The two-strike policy of API_CONTRACT §2 R-25 lives in the authenticator, which knows
        // whether the nonce changed, whether `stale=true` was set, and how many credentialed 401s
        // this credential has already collected. The machine only obeys the verdict: retrying a
        // rejected password locks the user out of their own camera after a handful of tries.
        authenticator.absorb(challenges)
        switch authenticator.lastOutcome {
        case .failed(let error):
            return actions + terminate(error)
        case .retry, .retryWithURIFallback:
            break
        case nil:
            return actions + terminate(.authRejected)
        }
        // Two guards, not one. `failureCount` is the Digest-protocol counter and a rotated nonce
        // never moves it, which is why the comparison it used to be alone in was against a number
        // that could stay at zero forever. `hasCredentialedSendBudget` is the one that actually
        // bounds what reaches the device (docs/RULING-LOCKOUT.md §2.5).
        guard authenticator.failureCount < config.maxAuthAttemptsPerRequest,
              authenticator.hasCredentialedSendBudget else {
            return actions + terminate(.authRejected)
        }

        counters.authRetries += 1
        actions.append(.log(.authRetried(attempt: authenticator.failureCount + 1)))
        actions += transition(to: .authenticating(retryOf: request.method))
        actions += self.request(request.method, uri: request.uri, extra: request.extra,
                                body: request.body, trackIndex: request.trackIndex, now: now)
        return actions
    }

    // MARK: - Redirects and failure statuses

    mutating func handleRedirect(_ response: RTSPResponse,
                                         now: MediaInstant) -> [RTSPAction] {
        guard let location = response.headers.first("Location"),
              let url = RTSPURL(string: location) else {
            return terminate(.malformedResponse)
        }
        redirectCount += 1
        guard redirectCount <= config.maxRedirects else { return terminate(.tooManyRedirects) }
        counters.redirectsFollowed += 1
        return [.log(.redirected(to: url.requestLineForm)),
                .closeTransport(reason: .redirect),
                .reconnect(to: url, resetAuthState: true)]
    }

    mutating func handleFailureStatus(_ response: RTSPResponse,
                                              request: PendingRequest,
                                              now: MediaInstant) -> [RTSPAction] {
        let code = response.status.rawValue
        let reason = response.reasonPhrase
        let log = RTSPAction.log(.statusRejected(status: code, method: request.method,
                                                 reason: reason))
        // A device that refuses GET_PARAMETER is not broken; it just wants a different keepalive.
        if code == 405, request.method == .getParameter {
            config.closesOnGetParameter = true
            keepaliveMethod = chooseKeepaliveMethod()
            return [log]
        }
        switch code {
        case 404, 451, 455, 460:
            return [log] + advanceLadderOrFail(.pathNotFound)
        case 406, 415:
            return [log] + advanceLadderOrFail(.noSuitableTrack)
        case 454:
            return [log] + terminate(.sessionNotFound)
        case 461, 462:
            return [log] + terminate(.transportRejected)
        case 405, 501:
            return [log] + terminate(.methodNotSupported)
        default:
            return [log] + terminate(.unexpectedStatus(code: code))
        }
    }

    /// A path-shaped failure during `DESCRIBE` closes with `.ladderAdvance`, which is how the R1.2
    /// probe ladder learns to try the next candidate without the user ever seeing a URL.
    mutating func advanceLadderOrFail(_ error: RTSPError) -> [RTSPAction] {
        var actions: [RTSPAction] = []
        switch machineState {
        case .awaitingDescribe, .authenticating(.describe):
            actions.append(.closeTransport(reason: .ladderAdvance))
        default:
            break
        }
        return actions + terminate(error)
    }

    // MARK: - Server-initiated messages

    mutating func handle(serverRequest: RTSPRequest, now: MediaInstant) -> [RTSPAction] {
        counters.serverRequestsReceived += 1
        let notice = serverRequest.headers.first("Notice")
        var actions: [RTSPAction] = [.log(.serverRequest(method: serverRequest.method,
                                                         notice: notice))]
        let response: Data
        switch serverRequest.method {
        case .announce, .options, .redirect:
            response = acknowledgement(cseq: serverRequest.cseq,
                                       includePublic: serverRequest.method == .options)
        default:
            response = notImplemented(cseq: serverRequest.cseq)
        }
        actions.append(.log(.transcript(
            ">>> RESPONSE\n" + Redact.secrets(in: String(decoding: response, as: UTF8.self)))))
        actions.append(.send(response))
        if serverRequest.method == .redirect,
           let location = serverRequest.headers.first("Location"),
           let url = RTSPURL(string: location) {
            redirectCount += 1
            guard redirectCount <= config.maxRedirects else {
                return actions + terminate(.tooManyRedirects)
            }
            counters.redirectsFollowed += 1
            actions.append(.closeTransport(reason: .redirect))
            actions.append(.reconnect(to: url, resetAuthState: true))
            return actions
        }
        if let notice, let parsed = RTSPResponseFields.notice(notice) {
            actions.append(.log(.noticeReceived(code: parsed.code, text: parsed.text)))
            actions += handleNotice(code: parsed.code)
        }
        return actions
    }

    /// Notice codes of docs/spec-rtsp.md §16. Everything unknown is logged and ignored.
    private mutating func handleNotice(code: Int) -> [RTSPAction] {
        switch code {
        case 1103, 2101:
            return transition(to: .paused)          // End of the requested playback range.
        case 2103:
            return [.closeTransport(reason: .normal)] + terminate(.timeout(.sessionExpiry))
        case 2104:
            return terminate(.sessionNotFound)
        case 2306:
            return terminate(.timeout(.dataIdle))
        default:
            return []
        }
    }

    /// `RTSP/1.0 200 OK` for a server-initiated request. The peer's `CSeq` is echoed verbatim —
    /// the only place we do not allocate our own — and no `Authorization` is ever attached.
    private func acknowledgement(cseq: UInt32, includePublic: Bool) -> Data {
        var text = "RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\n"
        if let sessionIdentifier { text += "Session: \(sessionIdentifier)\r\n" }
        if includePublic { text += "Public: OPTIONS, ANNOUNCE, REDIRECT\r\n" }
        text += "\r\n"
        return Data(text.utf8)
    }

    private func notImplemented(cseq: UInt32) -> Data {
        Data("RTSP/1.0 501 Not Implemented\r\nCSeq: \(cseq)\r\n\r\n".utf8)
    }

    // MARK: - State plumbing

    mutating func transition(to newState: RTSPSessionState) -> [RTSPAction] {
        guard machineState != newState else { return [] }
        machineState = newState
        return [.stateChanged(newState)]
    }

    mutating func closeNormally() -> [RTSPAction] {
        pending = nil
        commandQueue.removeAll()
        return transition(to: .closed) + [.closeTransport(reason: .normal)]
    }

    /// Ends the session. `.fail` is the **last** action ever produced; every later entry point
    /// returns `[]`, except one `handle(.teardown)`.
    mutating func terminate(_ error: RTSPError) -> [RTSPAction] {
        guard !isTerminated else { return [] }
        isTerminated = true
        pending = nil
        commandQueue.removeAll()
        machineState = .failed(error)
        return [.stateChanged(.failed(error)), .fail(error)]
    }
}
