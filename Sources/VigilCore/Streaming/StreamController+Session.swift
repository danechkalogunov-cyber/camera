//
//  StreamController+Session.swift
//  VigilCore
//
//  One connect attempt, start to finish: credential, path, session, RTP receivers, frames, and the
//  classification of however it ended.
//  Implements docs/spec-core.md §7.5 (the transition table) and §7.9 (composition and cancellation).
//
//  Finding 2 of .vigil/STEP3.md §3.1 lives here and is load-bearing: a TCP-interleaved client must
//  send its RTCP receiver reports back to the camera, or the session dies about forty seconds in
//  with a failure that looks exactly like a wrong password. `RTPTrackReceiver` produces those
//  reports; this file is what puts them on the wire, on the odd channel of the track's interleaved
//  pair. (Finding 1 — `transportReady` sends nothing, `.start` is what does — belongs to
//  `RTSPConnection`, which owns the session machine and issues it.)
//

#if os(macOS)

import Foundation
import VigilProtocols
import VigilRTP
import VigilRTSP
import VigilTransport

// MARK: - One attempt

extension StreamController {

    /// Runs one connect attempt and reports how it ended.
    func runAttempt() async -> AttemptOutcome {
        attemptStart = clock.now()
        pendingOutcome = nil
        sawFirstPacket = false
        sawFirstFrame = false
        didAuthenticate = false
        pathInvalidated = false
        firstFrameNudges = 0
        keyframeRequests.removeAll()
        transition(to: .resolving, detail: .plain(.resolving, attempt: attempt))

        // 1 — the credential, fetched per attempt and never captured.
        let credential: Credential?
        do {
            credential = try await credentialProvider()
        } catch let error as CredentialError {
            return .failed(StreamError.from(error))
        } catch {
            return .failed(StreamError(code: .keychainUnavailable,
                                       underlyingDescription: String(describing: error)))
        }
        guard let credential else {
            return .failed(StreamError(code: .credentialsMissing))
        }
        currentAccount = credential.account

        // 2 — the lockout gate, **before** a session exists. This is the check that stops a
        // reconnect loop from walking a wrong password into a thirty-minute account lock.
        if await governor.isBlocked(host: camera.host, account: credential.account) {
            return .failed(StreamError(
                code: .authenticationFailed,
                context: ["blocked": "locally, after "
                    + "\(LockoutGovernor.maxCredentialedFailures) rejected sign-ins"]))
        }

        // 3 — the path. R1.2: probed, never asked for, and remembered.
        let url: RTSPURL
        if let redirect = pendingRedirect {
            pendingRedirect = nil
            url = redirect
        } else {
            switch await resolvePath(credential: credential) {
            case let .ok(candidate): url = camera.rtspURL(path: candidate.path)
            case let .give(outcome): return outcome
            }
        }

        // 4 — the session. The event stream is taken **before** `connect()`, so nothing the
        // connection emits between the socket coming up and this loop starting can be missed.
        var config = RTSPSessionConfig(url: url)
        config.transport = .tcpInterleaved
        config.setupAudio = false
        config.setupMetadataTrack = false
        let newSession = dependencies.makeRTSPSession(config, credential, id.short)
        session = newSession
        let stream = await newSession.events()

        transition(to: .connecting, detail: .plain(.connecting, attempt: attempt))
        emit(.connectAttemptStarted(attempt: attempt,
                                    endpoint: "\(url.host):\(url.port)\(url.path)"))

        let connectOutcome = await withDeadline(Self.connectDeadline, clock: clock) {
            () -> StreamError? in
            do {
                try await newSession.connect()
                return nil
            } catch {
                return StreamError.from(anyError: error)
            }
        }
        guard let connectResult = connectOutcome else {
            return .retry(StreamError(code: .connectTimeout))
        }
        if let failure = connectResult {
            return failure.isUserFixable ? .failed(failure) : .retry(failure)
        }

        // 5 — drive the session from its own event stream. A handler or a timer that decides the
        // attempt is over sets `pendingOutcome` and closes the session, which finishes this stream.
        transition(to: .authenticating, detail: .plain(.authenticating, attempt: attempt))
        armControllerTimer(.connectWatchdog, after: Self.overallWatchdog)
        for await event in stream {
            await handle(event)
            if let outcome = pendingOutcome { return outcome }
        }
        if let outcome = pendingOutcome { return outcome }
        return isStopping ? .stopped : .retry(StreamError(code: .connectionClosed))
    }

    /// What `resolvePath` decided.
    enum PathResolution {
        /// Use this candidate.
        case ok(RTSPPathCandidate)
        /// Do not connect; the attempt is over.
        case give(AttemptOutcome)
    }

    /// Finds the path to stream, running the R1.2 ladder only when nothing is known yet.
    ///
    /// A learned path is used verbatim, so the ladder runs at most once per device in its lifetime.
    /// When the ladder does run and ends on a credentialed `401`, the path is kept — a `401` means
    /// the path is right — and the attempt fails, because the ladder has already spent this
    /// account's two attempts (API_CONTRACT §2 R-25) and connecting anyway would spend more.
    func resolvePath(credential: Credential) async -> PathResolution {
        if let known = resolvedCandidate { return .ok(known) }
        if let override = camera.rtspPathOverride, !override.isEmpty {
            let candidate = RTSPPathCandidate.override(override)
            resolvedCandidate = candidate
            return .ok(candidate)
        }

        switch await probe.probe(camera: camera, credential: credential, quality: quality) {
        case let .resolved(candidate, codec):
            let capabilities = candidate.capabilities(videoCodec: codec, probedAt: Date())
            camera.capabilities = capabilities
            resolvedCandidate = candidate
            emit(.pathResolved(candidate, capabilities: capabilities))
            return .ok(candidate)

        case let .authenticationRequired(candidate, error):
            resolvedCandidate = candidate
            if error.code == .credentialsMissing {
                // The device challenged a request we had nothing to sign, so no login was
                // attempted and no attempt was spent: connecting with the credential is the
                // correct next step, not a failure.
                return .ok(candidate)
            }
            await governor.block(host: camera.host, account: credential.account,
                                 reason: "401 while probing the path ladder")
            return .give(.failed(error))

        case let .exhausted(error):
            return .give(error.isUserFixable ? .failed(error) : .retry(error))
        }
    }
}

// MARK: - Session events

extension StreamController {

    /// Folds one connection event into the controller's state.
    func handle(_ event: RTSPConnectionEvent) async {
        switch event {
        case let .state(sessionState):
            mapSessionState(sessionState)
        case let .track(track):
            await adopt(track)
        case let .timing(timing):
            seed(timing)
        case let .media(channel, payload):
            await handleMedia(channel: channel, payload: payload)
        case let .ready(description):
            await handleReady(description)
        case let .closed(reason):
            await handleClose(reason)
        case let .reconnect(url, _):
            await finish(outcome: .redirect(url))
        case let .failed(error):
            await finish(with: StreamError.from(vigil: error))
        }
    }

    /// Maps the RTSP session's own state onto the app-facing one. The connect sequence is the only
    /// part that matters here; `.ready` and `.failed` drive the rest.
    func mapSessionState(_ sessionState: RTSPSessionState) {
        switch sessionState {
        case .awaitingOptions:
            transition(to: .authenticating, detail: .plain(.authenticating, attempt: attempt))
        case .authenticating:
            didAuthenticate = true
            transition(to: .authenticating, detail: .plain(.authenticating, attempt: attempt))
        case .awaitingDescribe:
            transition(to: .describing, detail: .plain(.describing, attempt: attempt))
        case .settingUp, .awaitingPlay:
            transition(to: .settingUp, detail: .plain(.settingUp, attempt: attempt))
        case .idle, .playing, .awaitingPause, .paused, .seeking, .tearingDown, .closed, .failed:
            break
        }
    }

    /// `PLAY` succeeded. Everything from here is media.
    func handleReady(_ description: RTSPSessionDescription) async {
        cancelControllerTimer(.connectWatchdog)
        guard let videoTrack = description.tracks.first(where: { $0.kind == .video }) else {
            await finish(with: StreamError(code: .unsupportedMedia))
            return
        }
        if didAuthenticate {
            // Basic is refused on a plaintext connection and the slice never enables TLS, so a
            // sign-in that succeeded here was Digest. The session does not report the scheme, and
            // naming anything else would be a lie in the diagnostics bundle.
            emit(.authenticated(scheme: .digest))
        }
        let path = resolvedCandidate?.path ?? camera.rtspPath(for: quality)
        if let format = StreamFormat(track: videoTrack,
                                     quality: quality,
                                     transport: description.transport,
                                     path: path) {
            resolvedFormat = format
            emit(.formatResolved(format))
        }
        transition(to: .playing, detail: .plain(.playing, attempt: attempt))
        armControllerTimer(.firstRTP, after: Self.firstRTPTimeout)
        armControllerTimer(.firstFrame, after: Self.firstKeyframeNudge)
        armControllerTimer(.statistics, after: .seconds(1))
    }

    /// The session asked for the connection to close.
    func handleClose(_ reason: RTSPCloseReason) async {
        switch reason {
        case .normal:
            await finish(outcome: isStopping
                ? .stopped
                : .retry(StreamError(code: .connectionClosed)))
        case .ladderAdvance:
            // A path that used to work has stopped working — a firmware update renumbers channels,
            // or the record was copied from another device. Forget the learned path so the next
            // attempt re-probes, and treat it as transient rather than as "no stream exists".
            logger.notice(.core, "learned rtsp path no longer answers; will re-probe",
                          ["camera": id.short])
            resolvedCandidate = nil
            camera.capabilities?.rtspPathTemplate = nil
            camera.capabilities?.resolvedRTSPPath = nil
            pathInvalidated = true
        case .redirect, .error:
            // `.redirect` is followed by `.reconnect`, and `.error` by `.failed`; both carry the
            // information this attempt ends on, so there is nothing to decide here.
            break
        }
    }
}

// MARK: - Media

extension StreamController {

    /// Adopts a negotiated track.
    ///
    /// Only the first video track is taken: a device that offers two gets a warning and the first,
    /// because switching mid-session on a hunch is worse than a documented choice. Audio is never
    /// set up in this slice, so an audio track here means the SDP offered one anyway.
    func adopt(_ track: RTSPTrack) async {
        guard track.kind == .video else {
            if track.kind == .audio {
                emit(.warning(.audioTrackIgnored(encodingName: track.encodingName)))
            }
            return
        }
        guard receivers.isEmpty else {
            emit(.warning(.secondTrackIgnored))
            return
        }
        guard let channels = track.interleavedChannels else {
            logger.warning(.core, "video track has no interleaved channels", ["camera": id.short])
            return
        }
        do {
            let format = try RTPTrackFormat(payloadType: track.payloadType,
                                            encodingName: track.encodingName,
                                            clockRate: Int32(clamping: track.clockRate),
                                            channels: track.channelCount.map { Int32(clamping: $0) },
                                            fmtp: track.fmtpParameters,
                                            parameterSets: track.parameterSets)
            let receiver = try RTPTrackReceiver(format: format,
                                                reorderMode: .passthrough,
                                                latency: camera.latencyPreset,
                                                cname: "vigil-\(id.short)",
                                                startTime: clock.now(),
                                                randomSource: random)
            receivers[track.id] = receiver
            trackForRTPChannel[channels.lowerBound] = track.id
            rtcpChannelForTrack[track.id] = channels.upperBound
            if track.parameterSets == nil {
                emit(.warning(.parameterSetsMissingFromSDP))
            }
        } catch {
            await finish(with: StreamError(code: .unsupportedMedia,
                                           underlyingDescription: error.diagnosticCode))
        }
    }

    /// Seeds a receiver's presentation clock from `RTP-Info`.
    func seed(_ timing: RTSPTrackTiming) {
        guard var receiver = receivers[timing.trackID] else { return }
        receiver.seed(RTSPTrackTimingSeed(clockRate: timing.clockRate,
                                          initialSequence: timing.initialSequence,
                                          initialRTPTimestamp: timing.initialRTPTimestamp,
                                          absoluteStart: timing.absoluteStart,
                                          scale: timing.scale,
                                          isRateControlDisabled: timing.isRateControlDisabled,
                                          playResponseInstant: timing.playResponseInstant))
        receivers[timing.trackID] = receiver
    }

    /// Routes one interleaved payload to its receiver: the even channel of a pair carries RTP, the
    /// odd one RTCP.
    func handleMedia(channel: UInt8, payload: Data) async {
        let now = clock.now()
        if let trackID = trackForRTPChannel[channel] {
            guard var receiver = receivers[trackID] else { return }
            let result = receiver.ingestRTP(payload, at: now)
            receivers[trackID] = receiver
            await handle(result, trackID: trackID, now: now)
            return
        }
        for (trackID, rtcpChannel) in rtcpChannelForTrack where rtcpChannel == channel {
            guard var receiver = receivers[trackID] else { return }
            let result = receiver.ingestRTCP(payload, at: now)
            receivers[trackID] = receiver
            await handle(result, trackID: trackID, now: now)
            return
        }
        logger.debug(.rtp, "media on an unregistered channel \(channel)", ["camera": id.short])
    }

    /// Publishes whatever one ingest produced: frames to the sink, receiver reports back to the
    /// camera, diagnostics to the observers.
    func handle(_ result: RTPIngestResult, trackID: Int, now: MediaInstant) async {
        if !sawFirstPacket {
            sawFirstPacket = true
            cancelControllerTimer(.firstRTP)
            emit(.firstPacketReceived(afterConnect: now - attemptStart))
        }

        for frame in result.frames {
            if !sawFirstFrame {
                sawFirstFrame = true
                cancelControllerTimer(.firstFrame)
                // The attempt counter returns to zero only after a minute of healthy playback, so
                // a camera that connects and dies after three seconds cannot reset its own backoff
                // (spec-core §7.6 rule 2).
                armControllerTimer(.healthyReset, after: policy.healthyResetInterval)
                camera.lastSeenAt = Date()
                emit(.firstFrameAssembled(afterStart: now - (startedAt ?? attemptStart)))
                transition(to: .playing, detail: .plain(.playing, attempt: attempt))
            }
            if frame.isKeyframe { emit(.keyframe(frame.pts)) }
            if !isPaused { frameSink?(frame) }
        }

        // Finding 2: the receiver reports have to go back, framed as `$` on the RTCP channel, or
        // the camera drops the session about forty seconds in.
        if let rtcpChannel = rtcpChannelForTrack[trackID], let session {
            for payload in result.outboundRTCP {
                await session.sendRTCP(payload, channel: rtcpChannel)
            }
        }

        for event in result.events {
            await handleDepacketizerEvent(event, now: now)
        }
        if let receiver = receivers[trackID] {
            latestStatistics = receiver.statistics
        }
    }

    /// Reacts to the depacketizer's diagnostics.
    func handleDepacketizerEvent(_ event: DepacketizerEvent, now: MediaInstant) async {
        switch event {
        case .keyframeNeeded:
            await requestKeyframe(now: now)
        case let .packetLoss(_, count):
            emit(.warning(.packetLoss(count: count)))
        case let .timestampDiscontinuity(seconds):
            emit(.warning(.timestampDiscontinuity(seconds: seconds)))
        default:
            logger.debug(.rtp, "depacketizer event \(event)", ["camera": id.short])
        }
    }

    /// Asks the camera for an IDR, within the rate limit the contract fixes.
    ///
    /// At most one request every two seconds and five in any thirty; past that the controller stops
    /// asking and ends the attempt, because a keyframe-request storm is how an NVR is made
    /// unresponsive (API_CONTRACT §2 R-24).
    ///
    /// The slice has no ISAPI client, so only the fallback rung of R-24's chain is available:
    /// `SET_PARAMETER`. The primary rung — `ISAPIDeviceSession.requestKeyFrame(channel:)` — is
    /// wired in when `VigilISAPI` lands.
    func requestKeyframe(now: MediaInstant) async {
        keyframeRequests.removeAll { now - $0 > .seconds(30) }
        if let last = keyframeRequests.last, now - last < .seconds(2) { return }
        guard keyframeRequests.count < 5 else {
            await finish(with: StreamError(code: .noKeyframe,
                                           context: ["reason": "keyframe requests exhausted"]))
            return
        }
        keyframeRequests.append(now)
        await session?.perform(.setParameter(name: "keyFrameRequest", value: "1"))
    }
}

// MARK: - Ending an attempt

extension StreamController {

    /// Ends the attempt on a failure.
    ///
    /// The one decision that matters: an authentication failure blocks the account **before** the
    /// run loop can schedule anything, so no ladder, no cold retry and no network-return
    /// short-circuit can send another password to this device.
    func finish(with error: StreamError) async {
        var resolved = error
        if error.code == .rtspPathNotFound, pathInvalidated {
            resolved = StreamError(code: .connectionClosed,
                                   underlyingDescription: "learned path stopped answering",
                                   rtspStatus: error.rtspStatus,
                                   context: error.context)
        }
        if resolved.code == .authenticationFailed, let account = currentAccount {
            await governor.block(host: camera.host, account: account,
                                 reason: "RTSP 401 after credentials were applied")
        }
        await finish(outcome: resolved.isUserFixable ? .failed(resolved) : .retry(resolved))
    }

    /// Records the attempt's outcome and closes the session, which finishes the event stream the
    /// attempt is iterating. The first outcome wins: a socket error arriving after a `TEARDOWN`
    /// completed cannot rewrite history.
    func finish(outcome: AttemptOutcome) async {
        if pendingOutcome == nil { pendingOutcome = outcome }
        await session?.close()
    }

    /// Tears the attempt down: timers, `TEARDOWN`, socket, receivers.
    ///
    /// Always safe to call, including twice and including from a cancelled task. `TEARDOWN` is
    /// queued before `close()` because the connection flushes what is already queued on a bounded
    /// budget — a session left open costs the camera a session slot for its whole timeout.
    func teardown() async {
        cancelAllTimers()
        if let session {
            if currentState.isActive || currentState == .settingUp || currentState == .describing {
                await session.perform(.teardown)
            }
            await session.close()
        }
        session = nil
        receivers.removeAll()
        trackForRTPChannel.removeAll()
        rtcpChannelForTrack.removeAll()
    }
}

#endif
