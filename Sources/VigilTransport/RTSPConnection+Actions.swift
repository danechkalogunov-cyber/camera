//
//  RTSPConnection+Actions.swift
//  VigilTransport
//
//  Executing what the session machine decided, closing down, and turning an `NWError` into a sentence.
//  macOS-only. Split from RTSPConnection.swift, which docs/API_CONTRACT.md §7.2 caps at 600 lines.
//

#if os(macOS)

import Dispatch
import Foundation
import Network
import VigilProtocols
import VigilRTSP

// MARK: - Actions, failure and close

/// ⚠️ Members here are `internal`, not `private`: Swift scopes `private` to one file, so anything
/// the rest of the actor calls would become invisible. `Scripts/lint.py`'s `split-access` rule
/// fails the build if one is left behind.
extension RTSPConnection {

    // MARK: - Action execution

    /// Executes one batch of actions, in order, without ever suspending.
    ///
    /// Not suspending is the whole design. `RTSPSessionMachine` guarantees the order of what it
    /// returns (docs/spec-rtsp.md §14.6) — `.stateChanged` before what the state causes, every
    /// `.emitTrack` before its `.emitTiming` before its `.emitMedia`, `.fail` last — and an `await`
    /// anywhere in this loop would let a timer or a command interleave and break that.
    func execute(_ actions: [RTSPAction]) {
        for action in actions {
            switch action {
            case .send(let data):
                enqueueWrite(data)

            case .sendInterleaved(let channel, let payload):
                // Finding 2 of .vigil/STEP3.md §3.1: outbound RTCP is framed as `$` on the RTCP
                // channel and written on the same socket as the RTSP control traffic.
                let framed = InterleavedFraming.frame(channel: channel, payload: payload)
                if framed.truncated > 0 {
                    logger.warning(.rtp, "RTCP packet truncated to fit the interleaved length field",
                                   ["dropped": String(framed.truncated)])
                }
                enqueueWrite(framed.bytes)

            case .prepareUDP:
                // The concrete remote ports arrive in the SETUP response. `emitTrack` below opens
                // both connected datagram flows before the machine advances to PLAY.
                break

            case let .joinMulticast(trackID, endpoint):
                guard prepareMulticast(trackID: trackID, endpoint: endpoint) else { return }

            case let .sendUDP(localPort, payload):
                sendUDP(payload, from: localPort)

            case .setTimer(let id, let deadline):
                arm(id, deadline: deadline)

            case .cancelTimer(let id):
                disarm(id)

            case .emitTrack(let track):
                if config.transport == .udpUnicast, !prepareUDP(for: track) { return }
                emit(.track(track))

            case .emitTiming(let timing):
                emit(.timing(timing))

            case .emitMedia(let channel, let payload):
                emit(.media(channel: channel, payload: payload))

            case .ready(let description):
                logger.info(.rtsp, "session playing",
                            ["tracks": String(description.tracks.count),
                             "session": Redact.sessionID(description.sessionID)])
                emit(.ready(description))

            case .stateChanged(let state):
                emit(.state(state))

            case .log(let event):
                record(event)

            case .setReadBackpressure(let isPaused):
                if isPaused {
                    pauseReads()
                } else {
                    resumeReads()
                }

            case .fail(let error):
                // `.fail` is the last action the machine will ever produce, so the socket has no
                // further use. `deliverFailure` closes it.
                deliverFailure(.rtsp(error))

            case .closeTransport(let reason):
                logger.info(.rtsp, "closing transport", ["reason": reason.rawValue])
                emit(.closed(reason))
                // `beginClose` only schedules the teardown; it does not suspend, so a `.reconnect`
                // emitted immediately after this still reaches the consumer.
                beginClose()

            case .reconnect(let url, let resetAuthState):
                emit(.reconnect(url: url, resetAuthState: resetAuthState))
            }
        }
    }

    private func emit(_ event: RTSPConnectionEvent) {
        // `AsyncStream.Continuation.yield` is documented as safe to call from any context and never
        // blocks, which is what lets `execute(_:)` stay synchronous. It also *returns* what it did
        // with the element, which is how a drop gets counted instead of vanishing.
        guard let sink = eventSink else { return }
        switch sink.yield(event) {
        case .enqueued:
            break

        case .dropped(let lost):
            // Under `.bufferingOldest` the refused element is the one just offered, so `lost` is
            // `event` — matched anyway rather than assumed, because the policy is a one-word edit
            // away from meaning something else.
            if lost.isMedia {
                drops.media += 1
                // One line per power-of-two, not one per packet: a stalled consumer would
                // otherwise turn a dropped-frame log into its own performance problem.
                if drops.media & (drops.media - 1) == 0 {
                    logger.notice(.rtp, "event stream full; media dropped",
                                  ["dropped": String(drops.media)])
                }
            } else {
                drops.control += 1
                logger.error(.transport, "event stream full; a CONTROL event was dropped",
                             ["dropped": String(drops.control),
                              "mediaDropped": String(drops.media)])
            }

        case .terminated:
            break

        @unknown default:
            break
        }
    }

    // MARK: - Failure and close

    /// Reports a terminal failure once, then closes.
    ///
    /// Latched: the read loop, the write drain and the state handler can all reach the same failure
    /// from different directions, and the owner must see one.
    func deliverFailure(_ error: VigilError) {
        guard !hasReportedFailure else { return }
        hasReportedFailure = true
        logger.failure(.transport, error)
        emit(.failed(error))
        beginClose()
    }

    /// Closes the connection and waits for the teardown to finish. Idempotent.
    public func close() async {
        beginClose()
        if let closeTask {
            await closeTask.value
        }
    }

    /// Starts the teardown. Never suspends, so it is safe to call from `execute(_:)`.
    ///
    /// `.idle` is included: closing a connection that was built and never connected must still end
    /// the event stream, or an owner that took one and then gave up waits forever.
    func beginClose() {
        guard lifecycle == .idle || lifecycle == .connecting || lifecycle == .running else {
            return
        }
        lifecycle = .closing
        isWriteClosed = true
        disarmAllTimers()
        wakeWriteDrain()
        wakeReadLoop()
        finishConnect(with: .cancelled)
        // A close during the pre-connect lookup must not wait for the system resolver's own
        // timeout, which is neither ours nor short.
        finishResolve(with: .cancelled)
        closeTask = Task { await self.finishClose() }
    }

    /// Flushes what is already queued, then tears everything down.
    private func finishClose() async {
        // Bounded flush. A queued `TEARDOWN` that never leaves costs the camera a session slot for
        // its whole timeout, so it is worth a moment; a socket that has stopped draining must not
        // hold this open, so the watchdog abandons the queue and cancels, which makes the
        // outstanding send complete with `ECANCELED` and lets the drain loop finish.
        let watchdog = Task { [clock] in
            do {
                try await clock.sleep(for: Self.closeFlushBudget)
            } catch {
                return
            }
            self.abandonQueuedWrites()   // already on the actor; see `waitForReady`'s watchdog
        }

        if let writeTask {
            await writeTask.value
        }
        watchdog.cancel()

        readTask?.cancel()
        socket?.cancel()
        socket = nil
        for udpSocket in udpSockets.values { udpSocket.cancel() }
        udpSockets.removeAll()
        for group in multicastGroups.values { group.cancel() }
        multicastGroups.removeAll()
        multicastDestinations.removeAll()
        lifecycle = .closed

        eventSink?.finish()
        eventSink = nil
        logger.info(.transport, "connection closed")
    }

    /// Drops whatever is still queued and cancels the socket, so the drain loop can end.
    ///
    /// **The cancel is unconditional, and that is the whole point of the watchdog.** The situation
    /// this exists for is a `send` that is already in flight and never completes — a socket whose
    /// window has closed because the camera stopped reading. In that situation `runWriteDrain` has
    /// already taken the frame off the queue, so `writeQueue` is *empty*, and it is parked in
    /// `sendAtomically` rather than `waitForWrite`, so `writeWaiter` is *nil*. An early return on
    /// "nothing queued" therefore skipped the cancel in exactly the case the budget was written
    /// for, and `finishClose`'s `await writeTask.value` waited for a send that would never
    /// complete: `close()` never returned and the event stream was never finished.
    private func abandonQueuedWrites() {
        if !writeQueue.isEmpty {
            logger.warning(.transport, "abandoning queued writes at close",
                           ["frames": String(writeQueue.count)])
            writeQueue.removeAll()
            writeQueueBytes = 0
        }
        socket?.cancel()
        wakeWriteDrain()
    }

    // MARK: - Logging

    /// Maps one `RTSPLogEvent` onto the injected logger.
    ///
    /// The message is the event's reflected form, deliberately: these are structured records whose
    /// payloads are already named, and re-writing twenty-one of them by hand is twenty-one chances
    /// to drop the field a bug report needs. It still goes through `Redact.secrets` — a request URI
    /// is credential-free by construction, but this path must not be the one place that assumes so.
    private func record(_ event: RTSPLogEvent) {
        if case let .transcript(text) = event {
            diagnostics.append(text, streamID: shortID)
            return
        }
        let level: LogLevel
        switch event {
        case .transcript:
            return
        case .requestSent, .sdpParsed, .trackControlResolved,
             .keepaliveSent, .sessionEstablished, .serverRequest:
            level = .debug
        // ⬆️ Promoted from `.debug`, and it is the one line in this switch worth arguing about.
        //
        // `.responseReceived` carries `rttMilliseconds`, which is the only per-request timing this
        // app produces. At debug it was absent from every field log anyone actually captures, so a
        // real report of "playback takes a second and a half to start" arrived with a 1.3 s gap in
        // it and no way to say which of OPTIONS, DESCRIBE, SETUP or PLAY spent it. The difference
        // matters: a slow PLAY on a `?starttime=` URL is the camera seeking its own disk and no
        // client change touches it, while a slow OPTIONS is a round trip we can simply stop making.
        //
        // The cost is one line per response. In a running session that is a keepalive every ~30 s,
        // which is a rate a camera app should be able to afford — and which is itself useful when
        // the complaint is that video stopped.
        case .responseReceived:
            level = .info
        case .authChallenged, .authRetried, .assumedInterleavedChannels, .trackSkipped,
             .noticeReceived, .redirected:
            level = .info
        case .framingResync, .midHeaderInterleavedFrame, .malformedHeaderIgnored,
             .malformedParameterSet, .unsolicitedResponse, .preplayMediaDropped:
            level = .notice
        case .transportRejected, .statusRejected:
            level = .warning
        }
        guard logger.isEnabled(level, .rtsp) else { return }
        logger.log(LogEvent(level: level, category: .rtsp,
                            message: Redact.secrets(in: String(describing: event))))
    }

    // MARK: - NWError mapping

    /// Turns an `NWError` into the outcome the read loop wants.
    ///
    /// A locally cancelled socket is `.torndown`, not a failure: it is what `close()` does.
    static func outcome(for error: NWError) -> ReceiveOutcome {
        if case .posix(let code) = error, code == .ECANCELED {
            return .torndown
        }
        return .failed(mapped(error))
    }

    /// Turns an `NWError` into a `VigilError`. **No `NWError` ever leaves this module.**
    ///
    /// `NWError`:
    ///   `case posix(POSIXErrorCode)`
    ///   `case dns(DNSServiceErrorType)`
    ///   `case tls(OSStatus)`
    ///   `case wifiAware(...)`  — added in the macOS 26 SDK; see the `default` arm on why it is not
    ///                            named explicitly.
    ///
    /// Anything unmapped becomes `.network(_:)` carrying the description, so a log line still
    /// diagnoses it — an error reduced to "something went wrong" is a support case nobody can close.
    static func mapped(_ error: NWError) -> VigilError {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED:
                return .transport(.connectRefused)
            case .ETIMEDOUT:
                return .transport(.connectTimeout)
            case .EHOSTUNREACH, .ENETUNREACH, .EHOSTDOWN, .ENETDOWN:
                return .transport(.hostUnreachable)
            case .ECONNRESET, .EPIPE, .ENOTCONN, .ECONNABORTED:
                return .transport(.peerClosed)
            case .ECANCELED:
                return .cancelled
            default:
                return .transport(.network("POSIX \(code.rawValue)"))
            }

        case .dns:
            // A name that does not resolve is not reachable, and `.hostUnreachable` is what says so
            // in the vocabulary the user sees: `VigilCore` maps it to `.hostResolutionFailed` and
            // the connect screen to "not on this network", which is the specific diagnosis
            // docs/REQUIREMENTS-CUSTOMER.md §R1.5 asks for. Reducing it to `.network(_:)` instead
            // would land in the undiagnosed bucket and say only that something went wrong. The
            // `DNSServiceErrorType` itself is not lost: every call site logs `describe(_:)`, which
            // carries the whole `NWError` including the code.
            return .transport(.hostUnreachable)

        case .tls(let status):
            // Unreachable in this slice — there is no TLS — but a silent default here would be the
            // one place a TLS failure could vanish.
            return .transport(.tlsFailed("OSStatus \(status)"))

        default:
            // `default`, deliberately, and NOT `@unknown default`.
            //
            // `NWError` is a resilient Apple enum that keeps gaining cases. `@unknown default` only
            // matches cases the compiler did *not* know about, so as soon as an SDK ships a new one
            // — SDK 26 added `.wifiAware` — every build warns "switch must be exhaustive" for a
            // branch that is a catch-all by design. Naming the case instead would break compilation
            // on any older SDK, and this repo has to build on both.
            //
            // Nothing is lost by bucketing: `describe(_:)` carries the whole `NWError`, so the log
            // line still names the actual failure. The cases that get a *specific* diagnosis are
            // handled above with intent; `.wifiAware` is a peer-to-peer transport a LAN camera never
            // uses, so it belongs here on merit rather than by omission.
            //
            // The cost, stated plainly: a future case that deserves its own diagnosis will land here
            // silently instead of raising a warning. It will still be legible in a support log, which
            // is the property that actually matters.
            return .transport(.network(describe(error)))
        }
    }

    /// A short, log-safe description of an `NWError`.
    static func describe(_ error: NWError) -> String {
        Redact.secrets(in: String(describing: error))
    }
}

#endif
