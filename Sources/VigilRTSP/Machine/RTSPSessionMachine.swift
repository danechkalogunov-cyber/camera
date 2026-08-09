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
    struct PendingRequest: Sendable {
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

    var config: RTSPSessionConfig
    var authenticator: RTSPAuthenticator
    var decoder: RTSPWireDecoder

    var machineState: RTSPSessionState = .idle
    var nextCSeq: UInt32 = 1
    var pending: PendingRequest?
    var commandQueue: [RTSPCommand] = []
    var isTerminated = false
    private var didAnswerTeardownAfterFailure = false

    var document: SDPDocument?
    var negotiatedTracks: [RTSPTrack] = []
    var setupOrder: [Int] = []
    var setupCursor = 0
    var aggregateURI: String
    var sessionIdentifier: String?
    var sessionTimeout: Duration
    var didAdoptSessionTimeout = false
    var serverPublicMethods: Set<RTSPMethod> = []
    var keepaliveMethod: RTSPMethod = .options
    var isProbe = false

    var preplayBuffer: [(channel: UInt8, payload: Data)] = []
    var hasPlayed = false
    var lastMediaAt: MediaInstant?
    var playScale: Double = 1.0
    var playRateControlDisabled = false
    var playRangeText: String?
    var requestedRangeText: String?
    var requestedScale: Double?
    var requestedDisableRateControl = false

    var redirectCount = 0
    var resyncInstants: [MediaInstant] = []
    var counters = RTSPSessionStatistics()

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
                                               isTLS: config.isTLS,
                                               credentialedAttemptAllowance:
                                                   config.credentialedAttemptAllowance)
        self.decoder = RTSPWireDecoder(limits: config.decoderLimits)
        self.aggregateURI = config.url.requestLineForm
        self.sessionTimeout = config.defaultSessionTimeout
        // Seeded, not defaulted: `sendPlay` reads these, and the handshake's own PLAY is the only
        // one some firmware honours (see `RTSPSessionConfig.initialScale`). A later
        // `.play(scale:)` still overrides them, so nothing here closes that door.
        self.requestedScale = config.initialScale
        self.requestedDisableRateControl = config.initialDisableRateControl
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
            if config.transport.isUDP,
               let position = negotiatedTracks.indices.first(where: {
                   UInt8(truncatingIfNeeded: $0 * 2 + 1) == channel
               }), let port = negotiatedTracks[position].clientPorts?.rtcp {
                return [.sendUDP(localPort: port, payload: payload)]
            }
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

    /// Supplies one datagram received on a reserved UDP port. The output uses the same logical
    /// even/odd channel numbering as interleaved TCP, keeping the RTP consumer transport-neutral.
    public mutating func ingestUDP(_ payload: Data, localPort: UInt16,
                                   now: MediaInstant) -> [RTSPAction] {
        guard !isTerminated, config.transport.isUDP,
              let position = negotiatedTracks.firstIndex(where: {
                  $0.clientPorts?.rtp == localPort || $0.clientPorts?.rtcp == localPort
              }), let ports = negotiatedTracks[position].clientPorts else { return [] }
        let channel = UInt8(truncatingIfNeeded: position * 2 + (localPort == ports.rtcp ? 1 : 0))
        return handleMedia(channel: channel, payload: payload, now: now)
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
            if config.transport == .udpMulticast { return terminate(.multicastBlocked) }
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

    // MARK: - Response dispatch

    mutating func handle(response: RTSPResponse, now: MediaInstant) -> [RTSPAction] {
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
        // Anything other than a `401` answering a request that carried credentials is proof the
        // device accepted them, whatever the status says about the *resource*. That is what returns
        // the per-connection credentialed-send budget, and it is why a healthy session — DESCRIBE,
        // two SETUPs and a PLAY, each carrying `Authorization` — is not stopped by the cap
        // (docs/RULING-LOCKOUT.md §2.5, "clear on success").
        if request.carriedAuthorization {
            authenticator.noteCredentialsAccepted()
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

    /// Parses an RTP/RTCP UDP port pair such as `server_port=6970-6971`.
    static func udpPortPair(_ value: String, parameter name: String) -> RTSPUDPPortPair? {
        guard let raw = parameter(name, in: value) else { return nil }
        let bounds = raw.split(separator: "-", omittingEmptySubsequences: true)
        guard bounds.count == 2,
              let rtp = UInt16(SDPText.trimmedOWS(bounds[0])),
              let rtcp = UInt16(SDPText.trimmedOWS(bounds[1])) else { return nil }
        return RTSPUDPPortPair(rtp: rtp, rtcp: rtcp)
    }

    /// Parses the mandatory destination/port and optional TTL from a multicast SETUP response.
    static func multicastEndpoint(_ value: String) -> RTSPMulticastEndpoint? {
        guard let destination = parameter("destination", in: value),
              let ports = udpPortPair(value, parameter: "port") else { return nil }
        let ttl: UInt8
        if let rawTTL = parameter("ttl", in: value) {
            guard let parsed = UInt8(unquoted(rawTTL)), parsed > 0 else { return nil }
            ttl = parsed
        } else {
            ttl = 1
        }
        return RTSPMulticastEndpoint(destination: unquoted(destination), ports: ports,
                                     timeToLive: ttl)
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
