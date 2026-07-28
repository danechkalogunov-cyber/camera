//
//  RTSPConnection.swift
//  VigilTransport
//
//  One `NWConnection`, one `RTSPSessionMachine`, and the ordering rules that keep the two in step:
//  every received byte goes into `ingest`, every action that comes back is executed in the order it
//  was emitted, and every failure leaves this module as a `VigilError` rather than an `NWError`.
//  Implements docs/API_CONTRACT.md §4.7 and §5.9, and .vigil/STEP3.md §3.1.
//
//  NONE OF THE CODE BELOW HAS BEEN COMPILED. This container is Linux and has no Network.framework,
//  so the whole file is wrapped in `#if os(macOS)` and compiles to nothing here; the build only
//  proves the guard. Every framework declaration this file calls is quoted as a comment above its
//  call site so a reviewer can check the call without a compiler, and everything the author could
//  not verify is listed in the agent's uncertainty list. See .vigil/STEP3.md, "Rules for code no
//  compiler will check".
//

#if os(macOS)

import Dispatch
import Foundation
import Network
import VigilProtocols
import VigilRTSP

// MARK: - RTSPConnectionEvent

/// What one connection reports to its owner.
///
/// This replaces §4.7's `bytes() -> AsyncThrowingStream<Data, any Error>`. That signature describes
/// a byte pipe with the session machine driven from somewhere else; §5.9 gives this file the
/// machine (`Deps: RTSPSessionMachine`) and .vigil/STEP3.md §3.1 requires this actor to issue
/// `.start` itself, so the machine lives here and what crosses the boundary is its output, already
/// parsed. Handing `VigilCore` raw bytes it would only feed straight back would be a second copy of
/// the framing decision in a second place. See the agent's deviation list.
public enum RTSPConnectionEvent: Sendable {

    /// A session state transition, in the order the machine produced it.
    case state(RTSPSessionState)

    /// One negotiated track, after its `SETUP` response.
    case track(RTSPTrack)

    /// A track's presentation-time seed. Always precedes any `.media` for that track.
    case timing(RTSPTrackTiming)

    /// One complete RTP or RTCP packet. `payload` excludes the four-byte `$` framing header; the
    /// even channel of a pair carries RTP and the odd one RTCP (RFC 2326 §10.12).
    case media(channel: UInt8, payload: Data)

    /// `PLAY` succeeded. Emitted exactly once per session.
    case ready(RTSPSessionDescription)

    /// The machine asked for the connection to be closed, and it is being closed. The reason is
    /// what `VigilCore` switches on to decide whether to reconnect — never this actor.
    case closed(RTSPCloseReason)

    /// A redirect or a probe-ladder advance: build a new connection to `url`. This actor never
    /// reconnects itself.
    case reconnect(url: RTSPURL, resetAuthState: Bool)

    /// Terminal failure. Nothing further is emitted except the stream's own completion.
    case failed(VigilError)

    /// Whether this event is droppable media rather than session control.
    ///
    /// The distinction is not cosmetic: losing one RTP packet costs a slice the depacketizer
    /// already knows how to survive, while losing the `.track` that configures it means every
    /// later packet on that channel is discarded with no video and **no error** — the failure
    /// class this project keeps trying to design out. `RTSPConnection.emit(_:)` counts the two
    /// separately for that reason.
    package var isMedia: Bool {
        if case .media = self { return true }
        return false
    }
}

// MARK: - RTSPConnectionEventDrops

/// How many events the connection could not hand to its consumer, by kind (API_CONTRACT §2 R-27).
///
/// `AsyncStream` **does** report drops — `Continuation.yield(_:)` returns `.dropped(_:)` carrying
/// the element that did not make it — so a drop here is counted rather than silent. An earlier note
/// on this file claimed the opposite and stood down R-27 for the event stream; it was wrong.
public struct RTSPConnectionEventDrops: Sendable, Hashable {

    /// Media events dropped because the consumer was too far behind. Recoverable.
    public var media = 0

    /// Control events dropped. **Never expected**: it means more than the whole buffer's worth of
    /// events went unread, and the session's observable state is now a lie. Logged at `.error`.
    public var control = 0

    /// Builds an all-zero count.
    public init() {}
}

// MARK: - InterleavedFraming

/// The `$` framing of RFC 2326 §10.12, on the **write** side.
///
/// The read side is `RTSPWireDecoder`'s, inside `RTSPSessionMachine.ingest`, and the two never meet:
/// the decoder only ever sees bytes that arrived from the camera and this only ever produces bytes
/// that go to it. Keeping the directions apart is not tidiness. A TCP-interleaved client sends RTCP
/// receiver reports back to the camera inside `$` frames on the same socket, and a receive path
/// that mistook those for RTSP traffic killed the harness's session about forty seconds in with an
/// authentication rejection — a failure that looks exactly like a wrong password and is not
/// (.vigil/STEP3.md §3.1, finding 2).
package enum InterleavedFraming {

    /// `$`, the interleaved-frame magic byte.
    package static let magic: UInt8 = 0x24

    /// Bytes of framing in front of each payload.
    package static let headerLength = 4

    /// Largest payload the 16-bit length field can describe.
    package static let maxPayloadLength = Int(UInt16.max)

    /// Frames one packet as `$ | channel | 16-bit big-endian length | payload`.
    ///
    /// A payload longer than 65 535 bytes cannot be described by the length field. It is truncated
    /// to the length actually written rather than refused, so the header and the body always agree
    /// and the peer's parser cannot lose the frame boundary; the caller is expected to have
    /// prevented this, and an RTCP receiver report is two orders of magnitude smaller. The truncated
    /// count is returned so the caller can log it.
    package static func frame(channel: UInt8, payload: Data) -> (bytes: Data, truncated: Int) {
        let written = min(payload.count, maxPayloadLength)
        let truncated = payload.count - written
        let length = UInt16(written)

        var out = Data(capacity: headerLength + written)
        out.append(magic)
        out.append(channel)
        out.append(UInt8(truncatingIfNeeded: length >> 8))
        out.append(UInt8(truncatingIfNeeded: length))
        out.append(payload.prefix(written))
        return (out, truncated)
    }
}

// MARK: - RTSPConnection

/// One RTSP session over one TCP connection.
///
/// Owns the socket, the `RTSPSessionMachine` that decides what to say, and the timers the machine
/// arms. The slice is TCP only: no TLS, no UDP, no multicast (.vigil/STEP3.md §3.1).
///
/// **The ordering contract.** `RTSPSessionMachine` guarantees the order of the actions it returns
/// (docs/spec-rtsp.md §14.6), so this actor must not reorder them. It does not: `execute(_:)` never
/// suspends. It appends outbound bytes to a FIFO, yields events to a stream, and arms timers, all
/// synchronously, which makes one action batch atomic with respect to every other thing this actor
/// does. The writes then leave the FIFO one at a time on a drain task, in order, each as a single
/// `NWConnection.send`.
///
/// **Cancellation.** A completion handler that fires after `close()` may resume a continuation —
/// that is harmless and expected — but it can never restart the session: every loop re-checks
/// `lifecycle` after each suspension, `deliverFailure` is latched, and `beginClose` is idempotent.
public actor RTSPConnection {

    // MARK: - Nested types

    /// Where this connection is. Strictly increasing: nothing ever moves backwards.
    private enum Lifecycle: Sendable, Hashable {
        case idle, connecting, running, closing, closed
    }

    /// One armed timer. The generation makes a late fire from a replaced timer detectable.
    struct TimerSlot: Sendable {
        var generation: UInt64
        var task: Task<Void, Never>
    }

    /// What the pre-connect resolver concluded about a DNS name (R-71, stage one).
    enum ResolveOutcome: Sendable {
        /// The name resolved, and **every** address it returned is on the local network. This is
        /// the literal to connect to — never the name, so that the address which was classified is
        /// the address the socket actually goes to.
        case permitted(literal: String)
        /// At least one address the name resolved to is outside the local network. Fail closed.
        case blocked
        /// The name did not resolve, or produced no address this code can read.
        case unresolvable
        /// The system resolver did not answer inside the connect budget.
        case timedOut
        /// The connection was closed while the resolver was still working.
        case cancelled
    }

    /// The result of one `receive` call, already reduced to the four cases the loop cares about.
    enum ReceiveOutcome: Sendable {
        /// Bytes arrived. **May be empty**, which is not end of stream — see `runReadLoop`.
        case bytes(Data)
        /// The peer closed cleanly (`isComplete` with no error).
        case endOfStream
        /// The connection failed.
        case failed(VigilError)
        /// The socket was torn down locally; there is nothing to report.
        case torndown
    }

    // MARK: - Constants

    /// Largest single `receive` delivery. 64 KiB is four times the largest interleaved frame the
    /// decoder will accept, so a full frame is rarely split across two deliveries, and small enough
    /// that a paused reader is not sitting on much.
    static let readChunkSize = 64 * 1024

    /// Outbound frames that may be queued before the queue is declared broken.
    static let maxQueuedWrites = 64

    /// Outbound bytes that may be queued before the queue is declared broken.
    static let maxQueuedWriteBytes = 1 << 20

    /// Consecutive zero-byte receives tolerated before the connection is declared broken. A
    /// zero-byte delivery is legal and must not be treated as EOF, but an endless run of them would
    /// spin this loop at full speed for the whole data-idle window.
    static let maxConsecutiveEmptyReceives = 256

    /// How long `close()` lets already-queued bytes reach the socket. A `TEARDOWN` that never
    /// leaves costs the camera a session slot for its full timeout, so the flush is worth waiting
    /// for; a wedged socket must not hold the close open, so it is bounded.
    static let closeFlushBudget = Duration.milliseconds(250)

    /// Events the consumer may fall behind by. R-27's standing capacity for RTP packets.
    private static let eventBufferCapacity = 512

    // MARK: - Injected

    let config: RTSPSessionConfig
    let connectTimeout: Duration

    // `clock`, `logger`, `machine`, `execute(_:)` and `isRunning` are `internal` rather than
    // `private` for one reason: `RTSPConnection+Timers.swift` is a second file, and Swift's
    // `private` is file-scoped, so an extension elsewhere cannot see it. Nothing outside this
    // module can, because the type's own members are not `public`.
    let clock: any MonotonicClock
    let logger: any LoggerProtocol

    /// The one queue Network.framework calls back on. Serial and `.userInitiated`, per
    /// API_CONTRACT §4.7.
    ///
    /// **This is one of the few sanctioned uses of GCD in Vigil.** `NWConnection` has no async
    /// interface: it delivers state changes and I/O completions to a `DispatchQueue`, so the hop
    /// from that queue into this actor has to be written by hand. Every such hop in this file is
    /// marked with a comment saying which direction it crosses.
    private let queue: DispatchQueue

    // MARK: - Session

    var machine: RTSPSessionMachine

    // MARK: - Socket

    var socket: NWConnection?
    var lifecycle: Lifecycle = .idle
    var connectContinuation: CheckedContinuation<VigilError?, Never>?
    var resolveContinuation: CheckedContinuation<ResolveOutcome, Never>?

    /// Whether the socket ever reached `.ready`. Decides whether `.waiting` is terminal.
    var hasBecomeReady = false

    // MARK: - Reading

    var readTask: Task<Void, Never>?
    var isReadPaused = false
    var readResumeWaiter: CheckedContinuation<Void, Never>?

    // MARK: - Writing

    var writeTask: Task<Void, Never>?
    var writeQueue: [Data] = []
    var writeQueueBytes = 0
    var writeWaiter: CheckedContinuation<Void, Never>?
    var isWriteClosed = false

    // MARK: - Timers

    // Stored here rather than in RTSPConnection+Timers.swift because Swift has no stored properties
    // in extensions. The behaviour lives in that file.
    var timers: [RTSPTimerID: TimerSlot] = [:]
    var nextTimerGeneration: UInt64 = 0

    // MARK: - Output

    var eventSink: AsyncStream<RTSPConnectionEvent>.Continuation?
    var hasReportedFailure = false
    private var closeTask: Task<Void, Never>?
    var drops = RTSPConnectionEventDrops()

    // MARK: - Initialisation

    /// Builds a connection. Nothing is opened until ``connect()``.
    ///
    /// - Parameters:
    ///   - config: the target URL, the timeouts and the caps. `config.transport` must be
    ///     `.tcpInterleaved`; the slice negotiates nothing else.
    ///   - credential: the account to authenticate with, or `nil` when none is stored. A device
    ///     that then challenges us fails with `.credentialsMissing` rather than guessing.
    ///   - clock: the monotonic source every instant handed to the machine comes from. Injected so
    ///     a failing session reproduces on a virtual clock.
    ///   - random: randomness for the Digest `cnonce`. Defaults to the system source; seed it in a
    ///     test.
    ///   - logger: where the machine's structured log events go, already redacted.
    ///   - shortID: appears in the dispatch queue's label, so a sample of a stalled app names the
    ///     camera. Not used for anything else.
    ///   - connectTimeout: how long the TCP handshake may take before `connect()` throws
    ///     `.transport(.connectTimeout)`.
    ///
    /// - Note: this signature deviates from API_CONTRACT §4.7's
    ///   `init(endpoint:quirks:trust:clock:logger:)`. `RTSPEndpoint`, `DeviceQuirks` and
    ///   `ServerTrustEvaluating` are all specified in §3.13 / §4.5 but none of them exists in
    ///   `Sources/` yet, and `trust` is TLS-only, which the slice excludes. `RTSPSessionConfig`
    ///   carries the same target information and is what the machine takes.
    public init(config: RTSPSessionConfig,
                credential: Credential?,
                clock: any MonotonicClock,
                random: any RandomSource = SystemRandomSource(),
                logger: any LoggerProtocol = NullLogger(),
                shortID: String = "0",
                connectTimeout: Duration = .seconds(5)) {
        self.config = config
        self.clock = clock
        self.logger = logger
        self.connectTimeout = connectTimeout
        self.queue = DispatchQueue(label: "com.vigil.net.\(shortID)", qos: .userInitiated)
        self.machine = RTSPSessionMachine(config: config, credential: credential,
                                          random: random, now: clock.now())
    }

    // MARK: - Observation

    /// Always `false` in this slice: TLS is not part of first light, so nothing here ever negotiates
    /// it. Kept because API_CONTRACT §4.7 declares it and `VigilCore` reads it.
    public nonisolated var isTLS: Bool { false }

    /// Whether the connection is up and the session is being driven. Read by the timer extension.
    var isRunning: Bool { lifecycle == .running }

    /// The session machine's current state.
    public var sessionState: RTSPSessionState { machine.state }

    /// The session machine's counters, including the framing decoder's.
    public var statistics: RTSPSessionStatistics { machine.statistics }

    /// A fresh event stream.
    ///
    /// A factory, not a property, per API_CONTRACT §2 R-27 — but a **single-consumer** one: calling
    /// it twice finishes the first stream rather than fanning out. It is not a `Broadcaster`,
    /// because `Broadcaster.yield` is actor-isolated and awaiting it in the middle of an action
    /// batch would open a suspension point exactly where the machine's ordering guarantee lives.
    /// `Broadcaster`'s own documentation says frames do not travel through it for the same reason.
    ///
    /// Buffering is **`.bufferingOldest(512)`**, and the choice of *oldest* rather than *newest* is
    /// the whole point.
    ///
    /// `.bufferingNewest` evicts the oldest element when the buffer fills, and it does so without
    /// caring what that element is. The events this connection emits first are `.track`,
    /// `.timing` and `.ready` — exactly the ones `VigilCore` needs in order to build a receiver at
    /// all — and the events that arrive in bulk afterwards are media. A consumer that stalls for
    /// half a second at `PLAY` would therefore have had its `.track` pushed out by the very media
    /// that `.track` exists to describe, leaving `handleMedia` with no receiver for the channel:
    /// **no video and no error**, which is the worst shape a failure can take.
    ///
    /// `.bufferingOldest` cannot do that. Nothing that has been enqueued is ever evicted, so a
    /// control event that got in is delivered, full stop. What is refused instead is the *newest*
    /// element — and when that element is media, refusing it is correct: a dropped RTP packet is a
    /// loss the depacketizer already handles, and it is now **counted** (see ``eventDrops``)
    /// rather than silent, which is what R-27 asks for.
    ///
    /// The residual, stated plainly rather than papered over: a control event arriving when 512
    /// unread events are already queued is still dropped. That means the consumer has read nothing
    /// for the whole buffer's depth, so it is logged at `.error` and counted separately. The
    /// designed remedy for a consumer that cannot keep up remains `pauseReads()`, which stops the
    /// camera at the TCP window rather than at this buffer.
    ///
    /// The stream also closes the connection if its consumer goes away: a cancelled `for await`
    /// would otherwise leave this actor reading a socket with nowhere to put what it reads.
    /// Only `.cancelled` triggers that — `.finished` is what `finish()` produces, and `finish()`
    /// is called by this very method and by `finishClose`, neither of which should recurse.
    public func events() -> AsyncStream<RTSPConnectionEvent> {
        eventSink?.finish()
        let made = AsyncStream<RTSPConnectionEvent>
            .makeStream(bufferingPolicy: .bufferingOldest(Self.eventBufferCapacity))
        made.continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else { return }
            Task { await self?.close() }
        }
        eventSink = made.continuation
        return made.stream
    }

    /// Events that never reached the consumer, by kind. Zero on a healthy session.
    public var eventDrops: RTSPConnectionEventDrops { drops }

    // MARK: - Connecting

    /// Opens the TCP connection and starts the session.
    ///
    /// Returns once the socket is ready and `OPTIONS` has been queued for writing; everything after
    /// that arrives on ``events()``.
    ///
    /// Throws `.transport(.egressBlocked)` for a destination outside the LAN — before the socket
    /// exists for an IP literal, and after the resolver has answered for a DNS name (R-71);
    /// `.transport(.connectRefused)` or `.transport(.hostUnreachable)` as soon as the platform says
    /// so, including through `NWConnection.State.waiting`, which is **terminal** here; and
    /// `.transport(.connectTimeout)` only when the handshake genuinely hangs with no state change
    /// at all.
    ///
    /// - Note: API_CONTRACT §4.7 declares `throws(TransportError)`. The brief for this file requires
    ///   failures to surface as `VigilError`, which is the wider type `VigilCore` switches on, so
    ///   every throw here is `VigilError.transport(...)` or `.cancelled`.
    public func connect() async throws(VigilError) {
        try vigilRequire(lifecycle == .idle, "RTSPConnection.connect() called twice")

        // R-71. Every destination is classified **before a socket exists**, and one that is not on
        // the local network never gets one. Three shapes, three answers:
        //
        //   `.refused`         an IP literal outside the LAN. Thrown here, no socket, no DNS query.
        //   `.permitted`       a LAN literal, `localhost`, a single label, or `*.local`. Connected
        //                      to as written — a name in this class cannot resolve off the link,
        //                      and `*.local` in particular wants Network.framework's own mDNS
        //                      resolver rather than ours.
        //   `.unresolvedName`  an ordinary multi-label name such as `nvr.example.internal`. We
        //                      resolve it ourselves, classify every address it returns, and then
        //                      connect to a **literal**. See `resolvePermittedAddress`.
        //
        // The third case is the one that changed. It used to be allowed through to a socket and
        // re-checked from `NWConnection.currentPath?.remoteEndpoint` once ready — which failed
        // *open* if the platform reported the name back instead of an address, and whether it does
        // is not something this code can verify. A stated product property must not rest on an
        // unverifiable framework behaviour, so the check is now ours end to end and fails closed.
        // (Supervisor ruling, review of finding 6.)
        let port = try endpointPort()

        lifecycle = .connecting

        let hostText: String
        switch EgressGuard.classify(config.url.host) {
        case .refused:
            // Through `abortConnect` rather than a bare `throw`, which is also a small fix: the
            // bare version left the event stream open, so a caller that had already taken one and
            // then had its `connect()` refused waited on a `for await` that would never end.
            throw abortConnect(.transport(.egressBlocked(host: config.url.host)))
        case .permitted:
            hostText = Self.endpointHostText(config.url.host)
        case .unresolvedName:
            hostText = try await resolvePermittedAddress()
        }

        // NWEndpoint.Host:
        //   public init(_ string: String)
        // Reads an IPv4 literal, an IPv6 literal (with an optional %zone) or a DNS name.
        let host = NWEndpoint.Host(hostText)

        // NWProtocolTCP.Options:
        //   public init()
        //   public var noDelay: Bool
        // Nagle off: an RTSP request is one small write whose answer we then wait for, which is the
        // exact shape Nagle delays. TCP keepalive is deliberately left alone — the session machine
        // runs its own keepalive on the RTSP layer and two are not better than one.
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true

        // NWParameters:
        //   public convenience init(tls: NWProtocolTLS.Options?, tcp: NWProtocolTCP.Options)
        // `tls: nil` is plain TCP. The slice has no TLS at all.
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)

        // NWConnection:
        //   public init(host: NWEndpoint.Host, port: NWEndpoint.Port, using: NWParameters)
        let created = NWConnection(host: host, port: port, using: parameters)
        socket = created

        logger.info(.transport, "connecting", ["url": config.url.description])

        if let failure = await waitForReady(created) {
            throw abortConnect(failure)
        }

        lifecycle = .running
        logger.info(.transport, "connected", ["url": config.url.description])
        startWriteDrain()
        startReadLoop()
        openSession()
    }

    /// Tears down a connection attempt that never got going, and hands back the failure to throw.
    ///
    /// One place, because there are now two ways to fail before the socket is ready — the resolver
    /// and the handshake — and both owe the caller the same cleanup. A caller that took an event
    /// stream before connecting must see it end, or its `for await` waits for a session that never
    /// started.
    func abortConnect(_ failure: VigilError) -> VigilError {
        lifecycle = .closed
        // public func cancel()
        socket?.cancel()
        socket = nil
        logger.failure(.transport, failure)
        eventSink?.finish()
        eventSink = nil
        return failure
    }

    // MARK: - Commands in

    /// Hands one control instruction to the session machine and executes what comes back.
    ///
    /// Ignored once the connection is closing or closed: a command that arrives after the socket is
    /// gone has nowhere to go, and the machine has already produced its last action.
    public func perform(_ command: RTSPCommand) {
        guard lifecycle == .running else { return }
        let now = clock.now()
        let handled = machine.handle(command, now: now)
        execute(handled)
        let stepped = machine.step(now: now)
        execute(stepped)
    }

    /// Sends one RTCP packet built by `VigilRTP` back to the camera.
    ///
    /// The packet goes **through the session machine** as `.sendRTCP`, which turns it into
    /// `.sendInterleaved` and lands in `execute(_:)`, which frames it as `$` on `channel`. Writing
    /// it straight to the socket would bypass the machine's ordering and put a `$` frame in the
    /// middle of a half-written request.
    ///
    /// - Parameters:
    ///   - payload: a complete RTCP compound packet. Nothing here parses it.
    ///   - channel: the interleaved channel to send on, **1** by default. The machine requests
    ///     `interleaved=0-1` for the first track it sets up, so channel 0 is that track's RTP and
    ///     channel 1 is its RTCP; a caller with more than one track passes the odd channel of the
    ///     pair it is reporting on, which is `RTSPTrack.interleavedChannels.upperBound`.
    public func sendRTCP(_ payload: Data, channel: UInt8 = 1) {
        perform(.sendRTCP(channel: channel, payload: payload))
    }
}

#endif
