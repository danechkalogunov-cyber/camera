//
//  RTSPSessionMachine+Requests.swift
//  VigilRTSP
//
//  Turning a decision into an RTSP request line, with its headers and its authorisation.
//  Split from RTSPSessionMachine.swift, which docs/API_CONTRACT.md §7.2 caps at 600 lines.
//

import Foundation
import VigilProtocols

// MARK: - Request emission

/// ⚠️ Members are `internal`, not `private`: Swift scopes `private` to one file.
/// `Scripts/lint.py`'s `split-access` rule fails the build on any left behind.
extension RTSPSessionMachine {

    // MARK: - Request emission

    /// Builds, records and emits one request in the canonical header order of §3.2:
    /// `CSeq`, `Session`, `Authorization`, `User-Agent`, method-specific headers, then the body
    /// headers. A retry after `401` always takes a **new** `CSeq`; reusing one breaks Hikvision's
    /// pipeline bookkeeping.
    private mutating func request(_ method: RTSPMethod,
                                  uri: String,
                                  extra: [(String, String)] = [],
                                  body: Data = Data(),
                                  trackIndex: Int? = nil,
                                  now: MediaInstant) -> [RTSPAction] {
        let cseq = nextCSeq
        nextCSeq &+= 1
        var headers = RTSPHeaders()
        headers.set("CSeq", String(cseq))
        if let sessionIdentifier, method.requiresSession {
            headers.set("Session", sessionIdentifier)
        }
        var carriedAuthorization = false
        if let authorization = authenticator.authorization(for: method, uri: uri) {
            headers.set("Authorization", authorization)
            carriedAuthorization = true
        }
        headers.set("User-Agent", config.userAgent)
        for (name, value) in extra {
            headers.set(name, value)
        }
        if !body.isEmpty {
            headers.set("Content-Length", String(body.count))
        }
        let message = RTSPRequest(method: method, uri: uri, headers: headers, body: body, cseq: cseq)
        pending = PendingRequest(method: method, cseq: cseq, uri: uri, extra: extra, body: body,
                                 sentAt: now, carriedAuthorization: carriedAuthorization,
                                 trackIndex: trackIndex)
        counters.requestsSent += 1
        let timeout = method == .teardown ? config.teardownTimeout : config.requestTimeout
        return [.log(.requestSent(method: method, cseq: cseq, uri: uri)),
                .send(message.serialized()),
                .setTimer(.requestTimeout(cseq: cseq), deadline: now + timeout)]
    }

    private mutating func describeRequest(now: MediaInstant) -> [RTSPAction] {
        request(.describe, uri: config.url.requestLineForm,
                extra: [("Accept", "application/sdp")], now: now)
    }

    private mutating func sendPlay(now: MediaInstant) -> [RTSPAction] {
        var extra: [(String, String)] = [("Range", requestedRangeText ?? "npt=0.000-")]
        if let scale = requestedScale, scale != 1.0 {
            extra.append(("Scale", RTSPScale.serialized(scale)))
        }
        if requestedDisableRateControl {
            extra.append(("Rate-Control", "no"))
        }
        return transition(to: .awaitingPlay)
            + request(.play, uri: aggregateURI, extra: extra, now: now)
    }

    private mutating func sendKeepalive(now: MediaInstant) -> [RTSPAction] {
        counters.keepalivesSent += 1
        var actions: [RTSPAction] = [.log(.keepaliveSent(method: keepaliveMethod))]
        if keepaliveMethod == .setParameter {
            actions += request(.setParameter, uri: aggregateURI,
                               extra: [("Content-Type", "text/parameters")],
                               body: Data("ping: yes\r\n".utf8), now: now)
        } else {
            actions += request(keepaliveMethod, uri: aggregateURI, now: now)
        }
        return actions
    }

    var keepaliveInterval: Duration {
        config.keepaliveInterval(sessionTimeout: sessionTimeout)
    }
}
