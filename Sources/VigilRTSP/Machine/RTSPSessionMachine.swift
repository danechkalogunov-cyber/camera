//
//  RTSPSessionMachine.swift
//  VigilRTSP
//
//  The transport-agnostic RTSP session state machine: bytes and a monotonic instant go in, ordered
//  actions come out. No sockets, no timers, no tasks, no clock reads — which is exactly why the
//  whole connection sequence is unit-testable on Linux with no camera present.
//  Implements docs/spec-rtsp.md §12, §14, §15, §16 and docs/API_CONTRACT.md §4.3.
//

import Foundation
import VigilProtocols

// MARK: - RTSPSessionMachine

/// One RTSP session, as a value.
///
/// The machine is a `struct` mutated by exactly one owner (an actor in `VigilCore`). Given the same
/// configuration, credential, random seed, byte stream, clock readings and command order it
/// produces the same action array, byte for byte — determinism is what makes the golden tests
/// meaningful and what makes a field failure reproducible from a log.
///
/// **Ordering guarantees the driver may rely on** (docs/spec-rtsp.md §14.6):
/// `.stateChanged` precedes anything the new state causes · each `.emitTrack` precedes that
/// track's `.emitTiming`, which precedes any `.emitMedia` on its channels · media that arrives
/// before the `PLAY` response is buffered, bounded, and never emitted early · `.ready` is emitted
/// exactly once per successful `PLAY` · `.fail` is the last action ever produced.
public struct RTSPSessionMachine: Sendable {

    // MARK: - Pending request

    /// The single outstanding request. RTSP pipelining is unreliable across Hikvision firmware, so
    /// there is never more than one.
    private struct PendingRequest: Sendable {
        var method: RTSPMethod
        var cseq: UInt32
        var uri: String
        var extra: [(String, String)]
        var body: Data
        var sentAt: MediaInstant
        var carriedAuthorization: Bool
        var trackIndex: Int?
    }

    // MARK: - Stored Properties

    private var config: RTSPSessionConfig
    private var authenticator: RTSPAuthenticator
    private var decoder: RTSPWireDecoder

    private var machineState: RTSPSessionState = .idle
    private var nextCSeq: UInt32 = 1
    private var pending: PendingRequest?
    private var commandQueue: [RTSPCommand] = []
    private var isTerminated = false
    private var didAnswerTeardownAfterFailure = false

    private var document: SDPDocument?
    private var negotiatedTracks: [RTSPTrack] = []
    private var setupOrder: [Int] = []
    private var setupCursor = 0
    private var aggregateURI: String
    private var sessionIdentifier: String?
    private var sessionTimeout: Duration
    private var didAdoptSessionTimeout = false
    private var serverPublicMethods: Set<RTSPMethod> = []
    private var keepaliveMethod: RTSPMethod = .options
    private var isProbe = false

    private var preplayBuffer: [(channel: UInt8, payload: Data)] = []
    private var hasPlayed = false
    private var lastMediaAt: MediaInstant?
    private var playScale: Double = 1.0
    private var playRateControlDisabled = false
    private var playRangeText: String?
    private var requestedRangeText: String?
    private var requestedScale: Double?
    private var requestedDisableRateControl = false

    private var redirectCount = 0
    private var resyncInstants: [MediaInstant] = []
    private var counters = RTSPSessionStatistics()

    // MARK: - Initialisation

    /// Builds a session machine.
    ///
    /// - Parameters:
    ///   - config: the target and every timeout and cap.
    ///   - credential: the account to authenticate with, or `nil` when none is stored — a device
    ///     that then challenges us fails with `.credentialsMissing` rather than guessing.
    ///   - random: injected randomness for the Digest `cnonce`. Seeded in tests so a failing run
    ///     reproduces exactly.
    ///   - now: the monotonic instant of construction. The machine never reads a clock; every
    ///     later entry point takes the current instant as an argument.
    public init(config: RTSPSessionConfig,
                credential: Credential?,
                random: any RandomSource,
                now: MediaInstant) {
        self.config = config
        self.authenticator = RTSPAuthenticator(credential: credential, random: random,
                                               allowBasicOverPlaintext:
                                                   config.allowBasicOverPlaintext,
                                               isTLS: config.isTLS)
        self.decoder = RTSPWireDecoder(limits: config.decoderLimits)
        self.aggregateURI = config.url.requestLineForm
        self.sessionTimeout = config.defaultSessionTimeout
        _ = now
    }

    // MARK: - Observation

    /// The current state.
    public var state: RTSPSessionState { machineState }

    /// Every track negotiated so far, in SDP order.
    public var tracks: [RTSPTrack] { negotiatedTracks }

    /// The opaque `Session` id, once one exists.
    public var sessionID: String? { sessionIdentifier }

    /// The transport in force.
    public var negotiatedTransport: RTSPTransportKind { config.transport }

    /// Counters, including the framing decoder's.
    public var statistics: RTSPSessionStatistics {
        var out = counters
        out.decoder = decoder.statistics
        return out
    }

    /// Interleaved channels registered with the framing decoder.
    public var interleavedChannels: Set<UInt8> { decoder.registeredChannels }

    // MARK: - Inputs

    /// The transport connected. Nonce state is per-connection, so it is reset here.
    public mutating func transportReady(isTLS: Bool, now: MediaInstant) -> [RTSPAction] {
        guard !isTerminated else { return [] }
        config.isTLS = isTLS
        authenticator.reset()
        return []
    }

    /// A control instruction from the driver.
    ///
    /// A command arriving while a request is outstanding is queued; overflowing the queue is a
    /// terminal `.commandQueueOverflow`, because it means the device has stopped answering and
    /// piling on more requests would only make that worse.
    public mutating func handle(_ command: RTSPCommand, now: MediaInstant) -> [RTSPAction] {
        guard !isTerminated else {
            guard case .teardown = command, !didAnswerTeardownAfterFailure else { return [] }
            didAnswerTeardownAfterFailure = true
            return [.closeTransport(reason: .error)]
        }
        switch command {
        case let .sendRTCP(channel, payload):
            return [.sendInterleaved(channel: channel, payload: payload)]
        case let .setReadBackpressure(isPaused):
            return [.setReadBackpressure(isPaused)]
        default:
            break
        }
        guard pending == nil else {
            guard commandQueue.count < config.maxCommandQueueDepth else {
                return terminate(.commandQueueOverflow)
            }
            commandQueue.append(command)
            return []
        }
        return execute(command, now: now)
    }

    /// Time-driven progress: starts the next queued command when the connection is idle.
    /// Idempotent when nothing is due.
    public mutating func step(now: MediaInstant) -> [RTSPAction] {
        var actions: [RTSPAction] = []
        while !isTerminated, pending == nil, !commandQueue.isEmpty {
            actions += execute(commandQueue.removeFirst(), now: now)
        }
        return actions
    }

    /// Bytes from the connection.
    ///
    /// Never throws: a framing violation the decoder cannot recover from becomes `.fail`.
    public mutating func ingest(_ bytes: some Collection<UInt8>, now: MediaInstant) -> [RTSPAction] {
        guard !isTerminated else { return [] }
        var actions: [RTSPAction] = []
        let units = decoder.ingest(bytes)
        actions += noteResyncs(now: now)

        for unit in units where !isTerminated {
            switch unit {
            case let .response(response):
                actions += handle(response: response, now: now)
            case let .request(request):
                actions += handle(serverRequest: request, now: now)
            case let .interleaved(channel, payload):
                actions += handleMedia(channel: channel, payload: payload, now: now)
            case let .malformed(fault):
                // A recoverable fault means the decoder resynchronised and will keep producing
                // units; only a terminal one ends the session.
                actions.append(.log(.malformedHeaderIgnored(fault.description)))
                if !fault.isRecoverable { actions += terminate(fault.rtspError) }
            }
        }
        if let failure = decoder.failure, !isTerminated {
            actions += terminate(failure.rtspError)
        }
        actions += step(now: now)
        return actions
    }

    /// A timer armed by `.setTimer` fired.
    public mutating func timerFired(_ id: RTSPTimerID, now: MediaInstant) -> [RTSPAction] {
        guard !isTerminated else { return [] }
        switch id {
        case let .requestTimeout(cseq):
            guard let request = pending, request.cseq == cseq else { return [] }
            pending = nil
            guard request.method != .teardown else { return closeNormally() }
            return terminate(.timeout(.requestTimeout(cseq: cseq)))

        case .keepalive:
            let rearm = RTSPAction.setTimer(.keepalive, deadline: now + keepaliveInterval)
            guard sessionIdentifier != nil, pending == nil, !isProbe else { return [rearm] }
            return sendKeepalive(now: now) + [rearm]

        case .firstMediaTimeout:
            guard hasPlayed, lastMediaAt == nil else { return [] }
            return terminate(.timeout(.firstMediaTimeout))

        case .dataIdle:
            guard let last = lastMediaAt else { return [] }
            guard now - last >= config.dataIdleTimeout else {
                // Re-arm lazily rather than on every packet: one action per frame would swamp the
                // stream the driver has to execute, for a timer that only ever matters when idle.
                return [.setTimer(.dataIdle, deadline: last + config.dataIdleTimeout)]
            }
            return terminate(.timeout(.dataIdle))

        case .sessionExpiry:
            return terminate(.timeout(.sessionExpiry))

        case .teardownGrace:
            return closeNormally()
        }
    }

    /// The connection went away. `error` is `nil` for a clean FIN.
    ///
    /// A close while tearing down or already closed completes normally; anything else is a
    /// failure. `VigilProtocols.RTSPError` has no `transportClosed` member, so the closest
    /// retryable one is used — the driver already knows the socket closed, and the error only has
    /// to classify the failure for the reconnect policy.
    public mutating func connectionClosed(error: String?, now: MediaInstant) -> [RTSPAction] {
        guard !isTerminated else { return [] }
        switch machineState {
        case .tearingDown, .closed:
            return transition(to: .closed)
        default:
            return terminate(.timeout(.dataIdle))
        }
    }

    // MARK: - Command execution

    private mutating func execute(_ command: RTSPCommand, now: MediaInstant) -> [RTSPAction] {
        switch command {
        case .start:
            isProbe = false
            return transition(to: .awaitingOptions)
                + request(.options, uri: config.url.requestLineForm, now: now)

        case .describeOnly:
            isProbe = true
            return transition(to: .awaitingDescribe) + describeRequest(now: now)

        case let .play(rangeText, scale, disableRateControl):
            requestedRangeText = rangeText ?? requestedRangeText
            requestedScale = scale ?? requestedScale
            requestedDisableRateControl = disableRateControl ?? requestedDisableRateControl
            return sendPlay(now: now)

        case .pause:
            return transition(to: .awaitingPause) + request(.pause, uri: aggregateURI, now: now)

        case .keepaliveNow:
            return sendKeepalive(now: now)

        case let .getParameter(names):
            let body = names.isEmpty ? Data() : Data(names.map { $0 + "\r\n" }.joined().utf8)
            let extra: [(String, String)] = body.isEmpty
                ? []
                : [("Content-Type", "text/parameters")]
            return request(.getParameter, uri: aggregateURI, extra: extra, body: body, now: now)

        case let .setParameter(name, value):
            let body = Data("\(name): \(value)\r\n".utf8)
            return request(.setParameter, uri: aggregateURI,
                           extra: [("Content-Type", "text/parameters")], body: body, now: now)

        case .teardown:
            var actions = transition(to: .tearingDown)
            actions += request(.teardown, uri: aggregateURI, now: now)
            actions.append(.setTimer(.teardownGrace, deadline: now + .milliseconds(500)))
            return actions

        case .sendRTCP, .setReadBackpressure:
            return []                       // Handled before queueing; unreachable in practice.
        }
    }

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

    private var keepaliveInterval: Duration {
        config.keepaliveInterval(sessionTimeout: sessionTimeout)
    }

    // MARK: - Response dispatch

    private mutating func handle(response: RTSPResponse, now: MediaInstant) -> [RTSPAction] {
        counters.responsesReceived += 1
        guard let request = pending, response.cseq == nil || response.cseq == request.cseq else {
            return [.log(.unsolicitedResponse(cseq: response.cseq))]
        }
        pending = nil
        let roundTrip = Int64((now - request.sentAt).milliseconds)
        counters.lastRoundTripMilliseconds = roundTrip
        var actions: [RTSPAction] = [
            .cancelTimer(.requestTimeout(cseq: request.cseq)),
            .log(.responseReceived(status: response.status.rawValue, cseq: response.cseq,
                                   rttMilliseconds: roundTrip)),
        ]
        if sessionIdentifier != nil {
            // Any completed request refreshes the session, not just a keepalive.
            actions.append(.setTimer(.sessionExpiry, deadline: now + sessionTimeout))
        }

        let code = response.status.rawValue
        if code == 401 {
            return actions + handleUnauthorized(response, request: request, now: now)
        }
        if code == 403 {
            return actions + terminate(.accessForbidden)
        }
        if response.status.isRedirect {
            return actions + handleRedirect(response, now: now)
        }
        if response.status.isSuccess {
            return actions + handleSuccess(response, request: request, now: now)
        }
        return actions + handleFailureStatus(response, request: request, now: now)
    }

    private mutating func handleSuccess(_ response: RTSPResponse,
                                        request: PendingRequest,
                                        now: MediaInstant) -> [RTSPAction] {
        switch request.method {
        case .options:
            return onOptions(response, now: now)
        case .describe:
            return onDescribe(response, now: now)
        case .setup:
            return onSetup(response, request: request, now: now)
        case .play:
            return onPlay(response, now: now)
        case .pause:
            return transition(to: .paused)
        case .teardown:
            return closeNormally()
        default:
            return []
        }
    }

    // MARK: - OPTIONS

    private mutating func onOptions(_ response: RTSPResponse, now: MediaInstant) -> [RTSPAction] {
        if let publicValue = response.headers.first("Public") {
            serverPublicMethods = RTSPResponseFields.methods(publicValue)
        }
        keepaliveMethod = chooseKeepaliveMethod()
        guard !isProbe else { return closeNormally() }
        return transition(to: .awaitingDescribe) + describeRequest(now: now)
    }

    /// `GET_PARAMETER` when the device advertises it — the least intrusive keepalive and what every
    /// current Hikvision build wants — then `SET_PARAMETER`, then `OPTIONS`, which RFC 2326 §10.1
    /// permits with a `Session` header and every build accepts.
    private func chooseKeepaliveMethod() -> RTSPMethod {
        if serverPublicMethods.contains(.getParameter), !config.closesOnGetParameter {
            return .getParameter
        }
        if serverPublicMethods.contains(.setParameter) { return .setParameter }
        return .options
    }

    // MARK: - DESCRIBE

    private mutating func onDescribe(_ response: RTSPResponse, now: MediaInstant) -> [RTSPAction] {
        let parsed: SDPDocument
        do {
            parsed = try SDPParser.parse(response.body)
        } catch {
            return advanceLadderOrFail(error)
        }
        document = parsed

        let contentBase = response.headers.first("Content-Base")
        let contentLocation = response.headers.first("Content-Location")
        aggregateURI = ControlURLResolver.resolve(control: parsed.sessionControl,
                                                  contentBase: contentBase,
                                                  contentLocation: contentLocation,
                                                  requestURI: config.url)
        var actions = buildTracks(from: parsed, contentBase: contentBase,
                                  contentLocation: contentLocation)
        actions.append(.log(.sdpParsed(trackCount: negotiatedTracks.count,
                                       codecs: negotiatedTracks.map(\.encodingName))))

        let hasVideo = negotiatedTracks.contains { $0.kind == .video && $0.codec?.isVideo == true }
        guard hasVideo else {
            return actions + advanceLadderOrFail(.noSuitableTrack)
        }

        if isProbe {
            // The probe ladder wants the tracks, not a session: report and close cleanly so the
            // driver can cache the winning path and start a real session against it.
            actions += negotiatedTracks.map { RTSPAction.emitTrack($0) }
            return actions + closeNormally()
        }

        setupOrder = Array(negotiatedTracks.indices)
        setupCursor = 0
        return actions + startNextSetup(now: now)
    }

    /// Turns the SDP into tracks, resolving each `a=control` and dropping the ones we cannot use.
    /// A dropped track is a log line, never a failure: an unusable audio track must not cost the
    /// user their video.
    private mutating func buildTracks(from parsed: SDPDocument,
                                      contentBase: String?,
                                      contentLocation: String?) -> [RTSPAction] {
        var actions: [RTSPAction] = []
        var built: [RTSPTrack] = []

        for media in parsed.media {
            guard built.count < config.maxTracks else { break }
            let wanted: Bool = switch media.kind {
            case .video: true
            case .audio: config.setupAudio
            case .application: config.setupMetadataTrack
            }
            guard wanted else {
                actions.append(.log(.trackSkipped(index: media.index, reason: "not requested")))
                continue
            }
            guard media.clockRate > 0 else {
                actions.append(.log(.trackSkipped(index: media.index, reason: "no clock rate")))
                continue
            }
            let codec = media.codec
            if media.kind == .video, codec == nil {
                actions.append(.log(.trackSkipped(index: media.index,
                                                  reason: "unsupported encoding "
                                                      + media.encodingName)))
                continue
            }
            if media.kind == .video, media.packetizationMode == 2 {
                actions.append(.log(.trackSkipped(index: media.index,
                                                  reason: "interleaved packetization mode")))
                continue
            }

            let control: String
            if let raw = media.control, raw != "*" {
                control = ControlURLResolver.resolve(control: raw, contentBase: contentBase,
                                                     contentLocation: contentLocation,
                                                     requestURI: config.url)
            } else {
                control = aggregateURI
            }
            actions.append(.log(.trackControlResolved(index: media.index, uri: control,
                                                      viaBase: contentBase ?? "request-uri")))

            built.append(RTSPTrack(
                id: media.index,
                kind: media.kind,
                codec: codec,
                encodingName: media.encodingName,
                payloadType: media.payloadType,
                clockRate: UInt32(max(media.clockRate, 0)),
                channelCount: media.channels.map(Int.init),
                controlURI: control,
                parameterSets: media.parameterSets,
                fmtpParameters: media.fmtp,
                packetizationMode: media.packetizationMode,
                spropMaxDONDiff: media.spropMaxDONDiff,
                aacConfig: media.aacConfig,
                aacSizeLength: media.fmtp["sizelength"].flatMap(Int.init),
                aacIndexLength: media.fmtp["indexlength"].flatMap(Int.init),
                aacIndexDeltaLength: media.fmtp["indexdeltalength"].flatMap(Int.init),
                hintedDimensions: media.hintedDimensions,
                hintedFramerate: media.framerate,
                bandwidthKbps: media.bandwidthKbps))
        }
        negotiatedTracks = built
        return actions
    }

    // MARK: - SETUP

    private mutating func startNextSetup(now: MediaInstant) -> [RTSPAction] {
        guard setupCursor < setupOrder.count else { return sendPlay(now: now) }
        let index = setupOrder[setupCursor]
        let rtpChannel = UInt8(truncatingIfNeeded: 2 * setupCursor)
        let rtcpChannel = rtpChannel &+ 1
        // Register **before** sending: the first frames on a channel can race the SETUP response,
        // and an unregistered channel would trigger a resynchronisation instead of a frame.
        decoder.registerInterleavedChannels([rtpChannel, rtcpChannel])
        let transport = "RTP/AVP/TCP;unicast;interleaved=\(rtpChannel)-\(rtcpChannel)"
        var actions = transition(to: .settingUp(trackIndex: setupCursor, of: setupOrder.count))
        actions += request(.setup, uri: negotiatedTracks[index].controlURI,
                           extra: [("Transport", transport)], trackIndex: index, now: now)
        return actions
    }

    private mutating func onSetup(_ response: RTSPResponse,
                                  request: PendingRequest,
                                  now: MediaInstant) -> [RTSPAction] {
        var actions: [RTSPAction] = []
        if let value = response.headers.first("Session") {
            let parsed = RTSPResponseFields.session(value)
            sessionIdentifier = parsed.id
            if let seconds = parsed.timeoutSeconds, !didAdoptSessionTimeout {
                // The timeout usually appears only on the first SETUP response: cache it and never
                // let a later omission reset it.
                sessionTimeout = config.clampedSessionTimeout(seconds: seconds)
                didAdoptSessionTimeout = true
            }
            actions.append(.log(.sessionEstablished(id: parsed.id,
                                                    timeoutSeconds: Int(sessionTimeout.seconds))))
        }

        guard let index = request.trackIndex, negotiatedTracks.indices.contains(index) else {
            return actions + terminate(.malformedResponse)
        }
        let requested = requestedChannels(forSetupAt: setupCursor)
        if let transport = response.headers.first("Transport") {
            if let channels = RTSPResponseFields.interleavedChannels(transport) {
                decoder.registerInterleavedChannels([channels.lowerBound, channels.upperBound])
                negotiatedTracks[index].interleavedChannels = channels
            } else {
                negotiatedTracks[index].interleavedChannels = requested
                actions.append(.log(.assumedInterleavedChannels(requested)))
            }
            negotiatedTracks[index].ssrc = RTSPResponseFields.ssrc(transport)
        } else {
            negotiatedTracks[index].interleavedChannels = requested
            actions.append(.log(.assumedInterleavedChannels(requested)))
        }

        actions.append(.emitTrack(negotiatedTracks[index]))
        setupCursor += 1
        return actions + startNextSetup(now: now)
    }

    private func requestedChannels(forSetupAt cursor: Int) -> ClosedRange<UInt8> {
        let rtp = UInt8(truncatingIfNeeded: 2 * cursor)
        return rtp...(rtp &+ 1)
    }

    // MARK: - PLAY

    private mutating func onPlay(_ response: RTSPResponse, now: MediaInstant) -> [RTSPAction] {
        playRangeText = response.headers.first("Range") ?? requestedRangeText
        playScale = response.headers.first("Scale").flatMap(Double.init) ?? requestedScale ?? 1.0
        playRateControlDisabled = SDPText.lowercasedASCII(
            response.headers.first("Rate-Control") ?? "") == "no"
        let entries = RTSPResponseFields.rtpInfo(response.headers.first("RTP-Info"))

        var actions = transition(to: .playing)
        hasPlayed = true

        for (position, track) in negotiatedTracks.enumerated() {
            let entry = matchRTPInfo(entries, track: track, position: position)
            actions.append(.emitTiming(RTSPTrackTiming(
                trackID: track.id,
                clockRate: track.clockRate,
                initialSequence: entry?.seq,
                initialRTPTimestamp: entry?.rtptime,
                absoluteStart: nil,
                scale: playScale,
                isRateControlDisabled: playRateControlDisabled,
                playResponseInstant: now)))
        }

        // Media buffered while PLAY was in flight is released only now, after every timing seed.
        for frame in preplayBuffer {
            actions.append(.emitMedia(channel: frame.channel, payload: frame.payload))
        }
        if !preplayBuffer.isEmpty {
            lastMediaAt = now
            preplayBuffer.removeAll()
        }

        actions.append(.ready(RTSPSessionDescription(
            tracks: negotiatedTracks,
            sessionID: sessionIdentifier ?? "",
            sessionTimeout: sessionTimeout,
            transport: config.transport,
            rangeText: playRangeText,
            scale: playScale,
            isRateControlDisabled: playRateControlDisabled,
            serverPublicMethods: serverPublicMethods,
            sdp: document ?? SDPDocument())))

        if lastMediaAt == nil {
            actions.append(.setTimer(.firstMediaTimeout, deadline: now + config.firstMediaTimeout))
        } else {
            actions.append(.setTimer(.dataIdle, deadline: now + config.dataIdleTimeout))
        }
        actions.append(.setTimer(.keepalive, deadline: now + keepaliveInterval))
        return actions
    }

    /// Matches an `RTP-Info` entry to a track: exact control URI first, then the last path segment
    /// (Hikvision NVRs answer with a **relative** `url=trackID=1`), then positional order when the
    /// entry count matches the track count.
    private func matchRTPInfo(_ entries: [RTSPResponseFields.RTPInfoEntry],
                              track: RTSPTrack,
                              position: Int) -> RTSPResponseFields.RTPInfoEntry? {
        if let exact = entries.first(where: { $0.url == track.controlURI }) { return exact }
        let wanted = RTSPResponseFields.lastPathSegment(track.controlURI)
        if !wanted.isEmpty,
           let loose = entries.first(where: {
               RTSPResponseFields.lastPathSegment($0.url) == wanted
           }) {
            return loose
        }
        guard entries.count == negotiatedTracks.count, entries.indices.contains(position) else {
            return nil
        }
        return entries[position]
    }

    // MARK: - Media

    private mutating func handleMedia(channel: UInt8,
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
    private mutating func noteResyncs(now: MediaInstant) -> [RTSPAction] {
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

    private mutating func handleUnauthorized(_ response: RTSPResponse,
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
        guard authenticator.failureCount < config.maxAuthAttemptsPerRequest else {
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

    private mutating func handleRedirect(_ response: RTSPResponse,
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

    private mutating func handleFailureStatus(_ response: RTSPResponse,
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
    private mutating func advanceLadderOrFail(_ error: RTSPError) -> [RTSPAction] {
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

    private mutating func handle(serverRequest: RTSPRequest, now: MediaInstant) -> [RTSPAction] {
        counters.serverRequestsReceived += 1
        let notice = serverRequest.headers.first("Notice")
        var actions: [RTSPAction] = [.log(.serverRequest(method: serverRequest.method,
                                                         notice: notice))]
        switch serverRequest.method {
        case .announce, .options, .redirect:
            actions.append(.send(acknowledgement(cseq: serverRequest.cseq,
                                                 includePublic: serverRequest.method == .options)))
        default:
            actions.append(.send(notImplemented(cseq: serverRequest.cseq)))
        }
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

    private mutating func transition(to newState: RTSPSessionState) -> [RTSPAction] {
        guard machineState != newState else { return [] }
        machineState = newState
        return [.stateChanged(newState)]
    }

    private mutating func closeNormally() -> [RTSPAction] {
        pending = nil
        commandQueue.removeAll()
        return transition(to: .closed) + [.closeTransport(reason: .normal)]
    }

    /// Ends the session. `.fail` is the **last** action ever produced; every later entry point
    /// returns `[]`, except one `handle(.teardown)`.
    private mutating func terminate(_ error: RTSPError) -> [RTSPAction] {
        guard !isTerminated else { return [] }
        isTerminated = true
        pending = nil
        commandQueue.removeAll()
        machineState = .failed(error)
        return [.stateChanged(.failed(error)), .fail(error)]
    }
}

// MARK: - Scale serialisation

/// `Scale` must carry exactly three decimals: one DS-96xx build rejects `Scale: 1` and another
/// rejects `Scale: 1.0`, while every build tested accepts `1.000`. Formatted by hand because
/// `String(format:)` is not available to the pure layer's hot paths.
enum RTSPScale {

    /// Serialises a scale factor with three decimal places, e.g. `-2.000`, `0.500`, `16.000`.
    static func serialized(_ scale: Double) -> String {
        let milli = Int64((scale * 1000).rounded())
        let sign = milli < 0 ? "-" : ""
        let magnitude = milli.magnitude
        var fraction = String(magnitude % 1000)
        while fraction.count < 3 { fraction = "0" + fraction }
        return "\(sign)\(magnitude / 1000).\(fraction)"
    }
}

// MARK: - Response header extraction

/// The narrow slice of header parsing the session machine performs for itself.
///
/// The full `Transport` / `Session` / `RTP-Info` / `Range` models are the header layer's
/// (`Sources/VigilRTSP/Headers/`); these extractors read only the handful of parameters the state
/// machine acts on, so that the machine's behaviour is testable independently of that layer.
enum RTSPResponseFields {

    /// One `RTP-Info` entry.
    struct RTPInfoEntry: Sendable, Hashable {
        var url: String
        var seq: UInt16?
        var rtptime: UInt32?
        var ssrc: UInt32?
    }

    /// `Session: 1885573958;timeout=60` → the opaque id and the timeout in seconds.
    /// The id is **never** parsed as a number: cameras send large decimals, NVRs short ones, and
    /// at least one build sends hex.
    static func session(_ value: String) -> (id: String, timeoutSeconds: Int?) {
        var identifier = ""
        var timeout: Int?
        for (offset, part) in value.split(separator: ";").enumerated() {
            let piece = SDPText.trimmedOWS(part)
            if offset == 0 {
                identifier = piece
                continue
            }
            if let (name, argument) = SDPText.splitOnce(piece, separator: "="),
               SDPText.lowercasedASCII(SDPText.trimmedOWS(name)) == "timeout" {
                timeout = Int(SDPText.trimmedOWS(argument))
            }
        }
        return (identifier, timeout)
    }

    /// `RTP/AVP/TCP;unicast;interleaved=0-1;ssrc=48A9C1B2` → `0...1`.
    static func interleavedChannels(_ value: String) -> ClosedRange<UInt8>? {
        guard let raw = parameter("interleaved", in: value) else { return nil }
        let bounds = raw.split(separator: "-", omittingEmptySubsequences: true)
        guard let first = bounds.first, let low = UInt8(SDPText.trimmedOWS(first)) else {
            return nil
        }
        guard bounds.count > 1, let high = UInt8(SDPText.trimmedOWS(bounds[1])), high >= low else {
            return low...low
        }
        return low...high
    }

    /// `ssrc=48A9C1B2` in either case, with no `0x`.
    static func ssrc(_ value: String) -> UInt32? {
        guard let raw = parameter("ssrc", in: value) else { return nil }
        return UInt32(unquoted(raw), radix: 16)
    }

    /// `Public: OPTIONS, DESCRIBE, PLAY` → the methods we model, ignoring the rest.
    static func methods(_ value: String) -> Set<RTSPMethod> {
        var out: Set<RTSPMethod> = []
        for piece in value.split(separator: ",") {
            if let method = RTSPMethod(rawValue: SDPText.trimmedOWS(piece)) { out.insert(method) }
        }
        return out
    }

    /// `url=…;seq=…;rtptime=…[;ssrc=…][, url=…]`.
    ///
    /// `seq` above 65535 and `rtptime` above 2³² have both been seen; the sequence number is
    /// dropped and the timestamp truncated, which is the correct recovery for each.
    static func rtpInfo(_ value: String?) -> [RTPInfoEntry] {
        guard let value else { return [] }
        var out: [RTPInfoEntry] = []
        for chunk in value.split(separator: ",", omittingEmptySubsequences: true) {
            var entry = RTPInfoEntry(url: "")
            for part in chunk.split(separator: ";", omittingEmptySubsequences: true) {
                guard let (name, argument) = SDPText.splitOnce(SDPText.trimmedOWS(part),
                                                               separator: "=") else { continue }
                let key = SDPText.lowercasedASCII(SDPText.trimmedOWS(name))
                let raw = unquoted(SDPText.trimmedOWS(argument))
                switch key {
                case "url": entry.url = raw
                case "seq": entry.seq = UInt16(raw)
                case "rtptime": entry.rtptime = UInt64(raw).map { UInt32(truncatingIfNeeded: $0) }
                case "ssrc": entry.ssrc = UInt32(raw, radix: 16)
                default: break
                }
            }
            if !entry.url.isEmpty { out.append(entry) }
        }
        return out
    }

    /// `Notice: 2101 End-of-Stream Reached; event-date=…` → the code and its text.
    static func notice(_ value: String) -> (code: Int, text: String)? {
        let head = value.split(separator: ";", maxSplits: 1).first.map(String.init) ?? value
        guard let (number, text) = SDPText.splitOnce(SDPText.trimmedOWS(head), separator: " "),
              let code = Int(SDPText.trimmedOWS(number)) else { return nil }
        return (code, SDPText.trimmedOWS(text))
    }

    /// The last path segment of a URI, query removed. `rtsp://h/a/b/trackID=1?x=1` → `trackID=1`.
    static func lastPathSegment(_ uri: String) -> String {
        let withoutQuery = uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? uri
        guard let slash = withoutQuery.lastIndex(of: "/") else { return withoutQuery }
        return String(withoutQuery[withoutQuery.index(after: slash)...])
    }

    /// One `;`-separated parameter's value, case-insensitively.
    private static func parameter(_ name: String, in value: String) -> String? {
        for part in value.split(separator: ";", omittingEmptySubsequences: true) {
            guard let (key, argument) = SDPText.splitOnce(SDPText.trimmedOWS(part),
                                                          separator: "=") else { continue }
            if SDPText.lowercasedASCII(SDPText.trimmedOWS(key)) == name {
                return SDPText.trimmedOWS(argument)
            }
        }
        return nil
    }

    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        return String(value.dropFirst().dropLast())
    }
}
