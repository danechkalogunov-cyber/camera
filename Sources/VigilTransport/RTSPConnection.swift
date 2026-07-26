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
    private enum ResolveOutcome: Sendable {
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
    private enum ReceiveOutcome: Sendable {
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
    private static let readChunkSize = 64 * 1024

    /// Outbound frames that may be queued before the queue is declared broken.
    private static let maxQueuedWrites = 64

    /// Outbound bytes that may be queued before the queue is declared broken.
    private static let maxQueuedWriteBytes = 1 << 20

    /// Consecutive zero-byte receives tolerated before the connection is declared broken. A
    /// zero-byte delivery is legal and must not be treated as EOF, but an endless run of them would
    /// spin this loop at full speed for the whole data-idle window.
    private static let maxConsecutiveEmptyReceives = 256

    /// How long `close()` lets already-queued bytes reach the socket. A `TEARDOWN` that never
    /// leaves costs the camera a session slot for its full timeout, so the flush is worth waiting
    /// for; a wedged socket must not hold the close open, so it is bounded.
    private static let closeFlushBudget = Duration.milliseconds(250)

    /// Events the consumer may fall behind by. R-27's standing capacity for RTP packets.
    private static let eventBufferCapacity = 512

    // MARK: - Injected

    private let config: RTSPSessionConfig
    private let connectTimeout: Duration

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

    private var socket: NWConnection?
    private var lifecycle: Lifecycle = .idle
    private var connectContinuation: CheckedContinuation<VigilError?, Never>?
    private var resolveContinuation: CheckedContinuation<ResolveOutcome, Never>?

    /// Whether the socket ever reached `.ready`. Decides whether `.waiting` is terminal.
    private var hasBecomeReady = false

    // MARK: - Reading

    private var readTask: Task<Void, Never>?
    private var isReadPaused = false
    private var readResumeWaiter: CheckedContinuation<Void, Never>?

    // MARK: - Writing

    private var writeTask: Task<Void, Never>?
    private var writeQueue: [Data] = []
    private var writeQueueBytes = 0
    private var writeWaiter: CheckedContinuation<Void, Never>?
    private var isWriteClosed = false

    // MARK: - Timers

    // Stored here rather than in RTSPConnection+Timers.swift because Swift has no stored properties
    // in extensions. The behaviour lives in that file.
    var timers: [RTSPTimerID: TimerSlot] = [:]
    var nextTimerGeneration: UInt64 = 0

    // MARK: - Output

    private var eventSink: AsyncStream<RTSPConnectionEvent>.Continuation?
    private var hasReportedFailure = false
    private var closeTask: Task<Void, Never>?
    private var drops = RTSPConnectionEventDrops()

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
    private func abortConnect(_ failure: VigilError) -> VigilError {
        lifecycle = .closed
        // public func cancel()
        socket?.cancel()
        socket = nil
        logger.failure(.transport, failure)
        eventSink?.finish()
        eventSink = nil
        return failure
    }

    // MARK: - Egress, stage one: resolving before connecting

    /// Resolves the configured name and returns the address literal to connect to (R-71).
    ///
    /// Fails closed in every direction: a name that resolves anywhere outside the local network is
    /// `.egressBlocked` before a socket exists, a name that does not resolve is `.hostUnreachable`,
    /// and a resolver that does not answer inside the connect budget is `.connectTimeout`.
    private func resolvePermittedAddress() async throws(VigilError) -> String {
        logger.debug(.transport, "resolving", ["host": config.url.host])
        switch await resolveWithinBudget(config.url.host) {
        case .permitted(let literal):
            logger.debug(.transport, "resolved to a local address", ["host": config.url.host])
            return literal
        case .blocked:
            logger.warning(.transport, "destination resolves outside the local network",
                           ["host": config.url.host])
            throw abortConnect(.transport(.egressBlocked(host: config.url.host)))
        case .unresolvable:
            throw abortConnect(.transport(.hostUnreachable))
        case .timedOut:
            throw abortConnect(.transport(.connectTimeout))
        case .cancelled:
            throw abortConnect(.cancelled)
        }
    }

    /// Runs the system resolver off the actor, giving up on it after the connect budget.
    ///
    /// `getaddrinfo` blocks its thread until the system resolver answers and cannot be cancelled,
    /// so two things follow. It must not run on a cooperative thread — hence the hop onto the
    /// connection's own dispatch queue, which is idle at this point because no socket exists yet —
    /// and a timeout can only *abandon* the lookup, not stop it. `finishResolve` latches for that
    /// reason: whichever of the two arrives first wins, and the loser resumes nothing.
    private func resolveWithinBudget(_ host: String) async -> ResolveOutcome {
        let watchdog = Task { [clock, connectTimeout] in
            do {
                try await clock.sleep(for: connectTimeout)
            } catch {
                return                                   // cancelled: the resolver answered first
            }
            self.finishResolve(with: .timedOut)          // already on the actor; see `waitForReady`
        }

        let outcome: ResolveOutcome = await withCheckedContinuation { continuation in
            resolveContinuation = continuation
            // actor → GCD, and one of this file's sanctioned uses of it. Nothing from
            // Network.framework is named in here, so the closure is `Sendable` whatever the SDK
            // turns out to say about `NWConnection`.
            queue.async { [weak self] in
                let outcome = RTSPConnection.resolveSynchronously(host)
                // GCD → actor.
                Task { await self?.finishResolve(with: outcome) }
            }
        }

        watchdog.cancel()
        return outcome
    }

    /// Resumes the resolve continuation exactly once.
    private func finishResolve(with outcome: ResolveOutcome) {
        guard let continuation = resolveContinuation else { return }
        resolveContinuation = nil
        continuation.resume(returning: outcome)
    }

    /// The blocking half: one `getaddrinfo`, every answer classified.
    ///
    /// POSIX rather than Network.framework, deliberately. Network has no resolver this code can
    /// call and verify — the only address it offers is `currentPath?.remoteEndpoint` *after* a
    /// connection exists, which is both too late to fail closed and a shape this file cannot
    /// check. `getaddrinfo`/`getnameinfo` are POSIX, need no dependency, and are spelled
    /// identically on Darwin and Glibc, so every line here is type-checked by the Linux shadow
    /// build. (`ai_socktype` and `ai_protocol` are deliberately left at zero: `SOCK_STREAM` is
    /// `Int32` on Darwin but `__socket_type` on Glibc, and `IPPROTO_TCP` is `Int32` against `Int`.
    /// Setting them would put the only two unverifiable lines in this function. The cost is a few
    /// duplicate entries per address, which classification does not care about.)
    ///
    /// **Fail closed**: one address outside the LAN blocks the whole destination, rather than the
    /// connection quietly using whichever answer happens to be local. A name that resolves to both
    /// a private and a public address is not a camera we should be talking to.
    ///
    /// - Note: `nonisolated`, and touches no actor state, because it runs on the dispatch queue.
    private nonisolated static func resolveSynchronously(_ host: String) -> ResolveOutcome {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC

        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let head = list else {
            return .unresolvable
        }
        defer { freeaddrinfo(head) }

        var first: String?
        var cursor: UnsafeMutablePointer<addrinfo>? = head
        while let entry = cursor {
            cursor = entry.pointee.ai_next
            guard let literal = numericHost(of: entry.pointee) else { continue }
            // The literal is classified by the very same code that classifies a hand-typed one,
            // so there is one definition of "local" in this module rather than two.
            guard EgressGuard.classify(literal) == .permitted else { return .blocked }
            if first == nil { first = literal }
        }
        guard let first else { return .unresolvable }
        return .permitted(literal: first)
    }

    /// One `addrinfo` rendered as a numeric address, in the spelling `NWEndpoint.Host` reads.
    ///
    /// `getnameinfo` with `NI_NUMERICHOST` never consults the resolver, so this cannot turn into a
    /// reverse lookup. An IPv6 scope comes back as `fe80::1%en0` — the kernel's spelling, which is
    /// what `NWEndpoint.Host` wants and what `EgressGuard` strips before classifying.
    private nonisolated static func numericHost(of entry: addrinfo) -> String? {
        guard let address = entry.ai_addr else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, entry.ai_addrlen, &buffer, socklen_t(buffer.count),
                          nil, 0, NI_NUMERICHOST) == 0 else {
            return nil
        }
        let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                          as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    /// The text `NWEndpoint.Host` is given for a destination taken straight from the URL.
    ///
    /// `RTSPURL.host` stores the authority as written, so an IPv6 zone id arrives in the URI form
    /// of RFC 6874 — `fe80::1%25en0`, in which `%25` *is* the escape for `%`. `NWEndpoint.Host`
    /// wants the zone as the kernel spells it, `fe80::1%en0`; handed the escaped form it reads the
    /// whole string as a DNS name, and the connect fails with a resolution error that names
    /// nothing useful. The stored form is deliberately left alone — it is what the request line
    /// and the Digest `uri=` have to reproduce byte for byte — so the decoding happens here, at
    /// the one point where the string stops being a URI component and becomes an address.
    ///
    /// Guarded on `:` so an ordinary DNS name is never touched. `%` is not legal in a host label,
    /// so there is nothing else this can affect.
    private static func endpointHostText(_ host: String) -> String {
        guard host.contains(":") else { return host }
        return host.replacingOccurrences(of: "%25", with: "%")
    }

    /// Converts the URL's port into an `NWEndpoint.Port`.
    private func endpointPort() throws(VigilError) -> NWEndpoint.Port {
        // NWEndpoint.Port:
        //   public init?(rawValue: UInt16)
        guard let raw = UInt16(exactly: config.url.port), raw != 0,
              let port = NWEndpoint.Port(rawValue: raw) else {
            throw VigilError.transport(.network("port \(config.url.port) is outside 1...65535"))
        }
        return port
    }

    /// Suspends until the connection is ready, fails, or the connect budget runs out.
    ///
    /// Returns `nil` on success and the mapped failure otherwise. Exactly one of the three outcomes
    /// resumes the continuation, because `finishConnect` clears it before resuming.
    private func waitForReady(_ socket: NWConnection) async -> VigilError? {
        let watchdog = Task { [clock, connectTimeout] in
            do {
                try await clock.sleep(for: connectTimeout)
            } catch {
                return                                   // cancelled: the connection settled first
            }
            // No `await`: `Task { }` created in an actor-isolated context inherits that isolation,
            // so this call is already on the actor and marking it produced
            // "no 'async' operations occur within 'await' expression". If that inheritance ever
            // changes the compiler will demand the `await` back, so this cannot rot silently.
            self.connectTimedOut()
        }

        let failure: VigilError? = await withCheckedContinuation { continuation in
            connectContinuation = continuation

            // GCD → actor. `stateUpdateHandler` is called on `queue`, not on this actor, so the
            // only thing it may do is hop. Ordering between two hops is not guaranteed, which is
            // why `socketStateChanged` is written to be order-insensitive: the first terminal state
            // wins and the rest are ignored.
            socket.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                Task { await self.socketStateChanged(state) }
            }

            // public func start(queue: DispatchQueue)
            socket.start(queue: queue)
        }

        watchdog.cancel()
        return failure
    }

    /// The connect budget expired with the socket still not ready.
    private func connectTimedOut() {
        guard connectContinuation != nil else { return }
        finishConnect(with: .transport(.connectTimeout))
    }

    /// Resumes the connect continuation exactly once.
    private func finishConnect(with failure: VigilError?) {
        guard let continuation = connectContinuation else { return }
        connectContinuation = nil
        continuation.resume(returning: failure)
    }

    /// One `NWConnection.State`, already hopped onto this actor.
    ///
    /// `NWConnection.State`:
    ///   `case setup`, `case waiting(NWError)`, `case preparing`, `case ready`,
    ///   `case failed(NWError)`, `case cancelled`
    private func socketStateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            // R-71's belt-and-braces check. The guarantee no longer rests here — `connect()`
            // resolves the name itself and connects to a classified address literal — so this is
            // an assertion that the platform went where it was told, not the enforcement point.
            if let failure = enforceResolvedEgress() {
                terminate(with: failure, reason: "egress blocked after resolution")
                return
            }
            hasBecomeReady = true
            finishConnect(with: nil)

        case .waiting(let error):
            // **`.waiting` is terminal only before `.ready`.**
            //
            // Before: Network.framework reports connection refusal and `EHOSTUNREACH` as
            // `.waiting(POSIXError)` and would retry behind it forever, so deferring to the connect
            // watchdog turns "nothing is listening" into "timed out" five seconds later — the
            // vaguer of the two diagnoses, where docs/REQUIREMENTS-CUSTOMER.md §R1.5 promises the
            // specific one. That is what docs/spec-discovery.md §5.9 and the ruling on
            // docs/INTEGRATION-TODO.md item 5 are about, and it still holds.
            //
            // After: a *playing* session is a different case and the same rule gives a worse
            // answer. A Wi-Fi roam or a brief route change puts a healthy connection into
            // `.waiting` for a moment, and Network.framework recovers from it by itself; killing
            // the stream there trades a hiccup for a full reconnect. Post-`.ready` it is a
            // transient degradation, and the session's own data-idle and keepalive timers decide
            // whether the stream is really gone. (Supervisor ruling, review of finding 7.)
            guard !hasBecomeReady else {
                logger.notice(.transport, "path temporarily unsatisfied; not terminal while playing",
                              ["reason": Self.describe(error)])
                return
            }
            terminate(with: Self.mapped(error), reason: Self.describe(error))

        case .failed(let error):
            terminate(with: Self.mapped(error), reason: Self.describe(error))

        case .cancelled:
            if connectContinuation != nil {
                finishConnect(with: .cancelled)
            }

        case .setup, .preparing:
            break

        @unknown default:
            // A state added after macOS 14. Logged rather than guessed at.
            logger.notice(.transport, "unrecognised NWConnection state")
        }
    }

    /// Ends the connection on a socket-layer failure, from whichever state it is in.
    ///
    /// Before the socket is ready the failure is the answer to `connect()`; afterwards it is the
    /// session's cause of death, and the machine is told so it can produce its last actions.
    /// `deliverFailure` latches, so the first cause wins and a later, vaguer one — the machine's own
    /// timeout, typically — cannot overwrite it.
    ///
    /// - Parameters:
    ///   - failure: what the owner is told.
    ///   - reason: the platform's own words, already redacted, for the log line and for the
    ///     machine's `connectionClosed`. Kept separate from `failure` because the mapped error
    ///     deliberately loses detail — `.hostUnreachable` does not say which `NWError` produced it.
    private func terminate(with failure: VigilError, reason: String) {
        // Only while the connection is still meant to be alive. `close()` cancels the socket, and
        // a genuine `ECONNRESET` racing that cancel would otherwise arrive here during `.closing`
        // and emit a `.failed` the owner never asked for — which `VigilCore` reads as a reason to
        // reconnect a session the user had just stopped. `.cancelled` is handled separately in
        // `socketStateChanged`, so the ordinary teardown never reaches this function at all.
        guard lifecycle == .connecting || lifecycle == .running else {
            logger.debug(.transport, "socket-layer failure after close, ignored",
                         ["reason": reason])
            return
        }
        logger.notice(.transport, "connection ended by the socket layer", ["reason": reason])
        if connectContinuation != nil {
            finishConnect(with: failure)
        } else {
            // Reported before the machine is told, for the reason given in `runReadLoop`'s
            // `.failed` case: `RTSPError` has no `transportClosed` member, so the machine answers a
            // dead socket with the closest retryable timeout — accurate about the policy, useless
            // about the cause.
            deliverFailure(failure)
            feedConnectionClosed(reason: reason)
        }
    }

    // MARK: - Egress, stage two

    /// Checks the address the connection actually reached against the LAN rule (R-71).
    ///
    /// **This is belt and braces, not the guarantee.** It used to be the enforcement point for
    /// every DNS name, and that was wrong in a way worth recording: it runs after the handshake, so
    /// it cannot fail closed, and it depends on `NWConnection.currentPath?.remoteEndpoint`
    /// reporting a *resolved* address rather than echoing back the name it was given — which is
    /// not something this code can verify. When the endpoint came back as `.name`, the check
    /// skipped itself and the LAN-only property silently reduced to nothing at all for exactly the
    /// hosts that needed it most. `connect()` now resolves and classifies before a socket exists
    /// and connects to a literal, so by the time this runs the destination has already been
    /// approved.
    ///
    /// It is kept because it is nearly free and it catches the one thing the pre-check cannot: the
    /// platform connecting somewhere other than where it was told. Nothing has been written when it
    /// runs — `connect()` starts the write drain only after `.ready` resumes it — so a refusal here
    /// still costs no RTSP byte.
    ///
    /// - Returns: the failure to end the connection with, or `nil` when the destination is
    ///   permitted or when the platform did not give an address to check.
    private func enforceResolvedEgress() -> VigilError? {
        guard let socket else { return nil }
        guard let address = Self.resolvedAddress(of: socket) else {
            // Not fatal, and deliberately so: refusing here would break every camera reached by
            // name the moment the platform stopped reporting a resolved endpoint, which is a
            // worse failure than the one being guarded against. The pre-connect classification
            // still applied, and this is logged so the gap is visible in a bug report.
            logger.notice(.transport, "no resolved address reported; egress re-check skipped",
                          ["host": config.url.host])
            return nil
        }
        guard EgressGuard.isPermitted(resolvedAddress: address) else {
            logger.warning(.transport, "destination resolved outside the local network",
                           ["host": config.url.host])
            return .transport(.egressBlocked(host: config.url.host))
        }
        return nil
    }

    /// The remote address this connection actually reached, in the platform's raw form: four bytes
    /// for IPv4, sixteen for IPv6, network byte order.
    ///
    /// `NWConnection.endpoint` is the endpoint we *asked* for and still holds the name; the path's
    /// `remoteEndpoint` is the one the connection settled on.
    ///
    /// `Network`:
    ///   `extension NWConnection { public var currentPath: NWPath? { get } }`
    ///   `public struct NWPath { public var remoteEndpoint: NWEndpoint? { get } }`
    ///   `public enum NWEndpoint {`
    ///   `    case hostPort(host: NWEndpoint.Host, port: NWEndpoint.Port)`
    ///   `    case service(name: String, type: String, domain: String, interface: NWInterface?)`
    ///   `    case unix(path: String)`
    ///   `    case url(URL)`
    ///   `}`
    ///   `public enum NWEndpoint.Host { case name(String, NWInterface?)`
    ///   `                              case ipv4(IPv4Address)`
    ///   `                              case ipv6(IPv6Address) }`
    ///   `public protocol IPAddress { var rawValue: Data { get } … }`
    ///
    /// `Network.IPv4Address` and `VigilProtocols.IPv4Address` are different types with the same
    /// name, and both modules are imported here. Neither name is written below — the addresses are
    /// bound by pattern and reduced immediately to `rawValue` — so nothing in this file has to be
    /// qualified.
    private static func resolvedAddress(of socket: NWConnection) -> Data? {
        guard let endpoint = socket.currentPath?.remoteEndpoint else { return nil }
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let address):
            return address.rawValue
        case .ipv6(let address):
            return address.rawValue
        case .name:
            // The path still names the host: nothing was resolved that this can classify.
            return nil
        @unknown default:
            return nil
        }
    }

    /// Puts the first request on the wire.
    ///
    /// **`transportReady(isTLS:now:)` returns an empty action list.** It resets per-connection nonce
    /// state and nothing else; nothing reaches the wire until `.start` is handled. A driver that
    /// connects the socket, calls `transportReady` and then waits for the machine to say something
    /// stalls forever with no error at all — the synthetic-camera harness's first run produced zero
    /// requests in exactly that way (.vigil/STEP3.md §3.1, finding 1; the contract's §4.3 does not
    /// mention it). Issuing `.start` is this actor's job and there is nowhere else it can happen.
    private func openSession() {
        let now = clock.now()
        let ready = machine.transportReady(isTLS: isTLS, now: now)
        execute(ready)
        let started = machine.handle(.start, now: now)
        execute(started)
        let stepped = machine.step(now: now)
        execute(stepped)
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

    // MARK: - Read backpressure

    /// Stops issuing new receives.
    ///
    /// One receive may already be outstanding and will still complete — this is not a guarantee that
    /// no more bytes arrive, it is a guarantee that no more are asked for. That is what makes the
    /// camera feel the TCP window close, which is the only flow control `Rate-Control: no` playback
    /// has (API_CONTRACT §4.7).
    public func pauseReads() {
        guard !isReadPaused else { return }
        isReadPaused = true
        logger.debug(.transport, "reads paused")
    }

    /// Resumes issuing receives.
    public func resumeReads() {
        guard isReadPaused else { return }
        isReadPaused = false
        logger.debug(.transport, "reads resumed")
        wakeReadLoop()
    }

    // MARK: - Reading

    private func startReadLoop() {
        readTask = Task { await self.runReadLoop() }
    }

    /// Feeds every received byte into the machine, in arrival order.
    ///
    /// Order is guaranteed by construction: exactly one `receive` is outstanding at a time, because
    /// the next one is only issued after the previous chunk has been ingested. Issuing several and
    /// hopping each onto the actor separately would deliver them in whatever order the actor
    /// scheduled, which for a byte stream is corruption.
    private func runReadLoop() async {
        var consecutiveEmpty = 0

        while lifecycle == .running {
            while lifecycle == .running, isReadPaused {
                await waitForReadResume()
            }
            guard lifecycle == .running, let socket else { return }

            let outcome = await receiveOnce(socket)

            // The socket may have been torn down while this loop was suspended. A completion
            // handler that fires after cancellation must not restart a session that is over.
            guard lifecycle == .running else { return }

            switch outcome {
            case .bytes(let chunk):
                if chunk.isEmpty {
                    // `receive(minimumIncompleteLength:maximumLength:)` can call back with zero
                    // bytes and `isComplete == false`. Treating that as EOF closes healthy
                    // connections, so it is not an ending — it is another receive. The counter is
                    // only a governor against spinning at full speed if it never stops.
                    consecutiveEmpty += 1
                    guard consecutiveEmpty <= Self.maxConsecutiveEmptyReceives else {
                        deliverFailure(.transport(.network(
                            "receive delivered no bytes \(consecutiveEmpty) times in a row")))
                        return
                    }
                    continue
                }
                consecutiveEmpty = 0
                let actions = machine.ingest(chunk, now: clock.now())
                execute(actions)

            case .endOfStream:
                // The machine is told first here, deliberately, and it is the one case where that
                // is right: a FIN that arrives while `TEARDOWN` is outstanding is a **normal**
                // close, and only the machine knows that. It answers a FIN in any other state with
                // a failure of its own.
                logger.info(.transport, "peer closed the connection")
                feedConnectionClosed(reason: nil)
                // Unconditional, and not redundant: a machine that has already terminated returns
                // no actions at all, and the socket would otherwise stay open with nobody reading.
                beginClose()
                return

            case .failed(let error):
                // The socket's own error is reported first, and `deliverFailure` latches, so the
                // machine's consequent `.fail` does not overwrite it. `RTSPError` has no
                // `transportClosed` member, so the machine answers a dead socket with the closest
                // retryable timeout — accurate about the policy, useless about the cause. The
                // cause is `ECONNRESET`, and that is what the user's bug report needs.
                deliverFailure(error)
                // `describe(_:)` takes an `NWError`; by this point the platform error has already
                // been mapped, so the machine is told the diagnostic code — which is the stable,
                // greppable form and is what a bug report quotes. (This line read
                // `Self.describe(error)` and did not compile: the read loop's `.failed` carries a
                // `VigilError`, not an `NWError`. Found by shadow-compiling this file on Linux
                // against a stub of Network.framework, which is the only compiler it gets here.)
                feedConnectionClosed(reason: error.diagnosticCode)
                return

            case .torndown:
                return
            }
        }
    }

    /// One `receive`, reduced to a `ReceiveOutcome`.
    ///
    /// `NWConnection`:
    ///   `public func receive(minimumIncompleteLength: Int, maximumLength: Int,`
    ///   `                    completion: @escaping (Data?, NWConnection.ContentContext?, Bool,`
    ///   `                                          NWError?) -> Void)`
    /// The completion is called exactly once per call, on the connection's queue.
    private func receiveOnce(_ socket: NWConnection) async -> ReceiveOutcome {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ReceiveOutcome, Never>) in
                socket.receive(minimumIncompleteLength: 1,
                               maximumLength: Self.readChunkSize) { content, _, isComplete, error in
                    // GCD → actor. Resuming a continuation is safe from any thread; nothing else in
                    // this closure touches actor state, which is why there is no hop here.
                    if let error {
                        continuation.resume(returning: RTSPConnection.outcome(for: error))
                        return
                    }
                    if let content, !content.isEmpty {
                        continuation.resume(returning: .bytes(content))
                        return
                    }
                    // No error and no bytes. Only `isComplete` means end of stream; the other case
                    // is an empty delivery and the loop simply asks again.
                    continuation.resume(returning: isComplete ? .endOfStream : .bytes(Data()))
                }
            }
        } onCancel: {
            // Task cancellation has to reach the socket, or the receive above never completes and
            // this task leaks (API_CONTRACT §4.7). `cancel()` makes the completion fire with
            // `POSIXErrorCode.ECANCELED`.
            //
            // Routed through the actor rather than calling `socket.cancel()` here. `onCancel` is
            // `@Sendable`, so naming the socket in it captures an `NWConnection` across an
            // isolation boundary, and whether `NWConnection` is `Sendable` in the macOS 14/15 SDK
            // is the one thing this file could not check — shadow-compiling against a
            // non-`Sendable` stub gives "capture of 'socket' with non-sendable type 'NWConnection'
            // in a '@Sendable' closure" on exactly this line and on the same line in
            // `sendAtomically`, and nowhere else. Capturing the actor instead is correct either
            // way and needs no `@unchecked Sendable` box, which ruling R-52 forbids. The hop costs
            // one actor turn on a path that is already tearing down.
            Task { await self.cancelSocket() }
        }
    }

    /// Cancels the socket from the actor's own isolation.
    ///
    /// Exists only so the two `@Sendable` cancellation handlers never have to name an
    /// `NWConnection`. Reads `self.socket` rather than taking one: by the time a cancellation hop
    /// lands, `finishClose` may already have cancelled and cleared it, and a second cancel of a
    /// dead connection is a no-op.
    private func cancelSocket() {
        socket?.cancel()
    }

    /// Suspends the read loop while reads are paused.
    ///
    /// Safe against a missed wakeup: this runs on the actor and `withCheckedContinuation` installs
    /// the waiter before suspending, so `resumeReads()` cannot slip in between the check and the
    /// installation.
    private func waitForReadResume() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            readResumeWaiter?.resume()
            readResumeWaiter = continuation
        }
    }

    private func wakeReadLoop() {
        guard let waiter = readResumeWaiter else { return }
        readResumeWaiter = nil
        waiter.resume()
    }

    /// Tells the machine the connection went away, and executes what it decides.
    private func feedConnectionClosed(reason: String?) {
        let actions = machine.connectionClosed(error: reason, now: clock.now())
        execute(actions)
    }

    // MARK: - Writing

    private func startWriteDrain() {
        writeTask = Task { await self.runWriteDrain() }
    }

    /// Writes queued frames one at a time, in the order `execute(_:)` queued them.
    ///
    /// One `send` at a time, awaited: that is what makes each `.send` action a single atomic write
    /// and keeps two action batches from interleaving their bytes.
    private func runWriteDrain() async {
        while true {
            if writeQueue.isEmpty {
                if isWriteClosed || lifecycle == .closed { return }
                await waitForWrite()
                continue
            }
            guard let socket else { return }

            let data = writeQueue.removeFirst()
            writeQueueBytes -= data.count

            if let failure = await sendAtomically(data, on: socket) {
                // A send that failed after the socket was torn down locally is expected and is not
                // the session's cause of death.
                guard lifecycle == .running else { return }
                deliverFailure(failure)
                return
            }
        }
    }

    /// Queues one frame for writing. Never suspends, so a whole action batch is queued atomically.
    ///
    /// Overflow is terminal rather than silent. Dropping one request desynchronises `CSeq` for the
    /// rest of the session, and the failure would surface minutes later as an unanswered request
    /// pointing at the camera. A full queue means the socket has stopped draining, which the
    /// machine's own timers would find shortly anyway.
    private func enqueueWrite(_ data: Data) {
        guard lifecycle == .connecting || lifecycle == .running, !isWriteClosed else { return }
        guard writeQueue.count < Self.maxQueuedWrites,
              writeQueueBytes + data.count <= Self.maxQueuedWriteBytes else {
            deliverFailure(.transport(.network(
                "outbound queue full at \(writeQueue.count) frames / \(writeQueueBytes) bytes")))
            return
        }
        writeQueue.append(data)
        writeQueueBytes += data.count
        wakeWriteDrain()
    }

    private func waitForWrite() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writeWaiter?.resume()
            writeWaiter = continuation
        }
    }

    private func wakeWriteDrain() {
        guard let waiter = writeWaiter else { return }
        writeWaiter = nil
        waiter.resume()
    }

    /// One frame, one write. Returns `nil` on success.
    ///
    /// `NWConnection`:
    ///   `public func send(content: Data?, contentContext: NWConnection.ContentContext = .defaultMessage,`
    ///   `                 isComplete: Bool = true, completion: NWConnection.SendCompletion)`
    /// `NWConnection.SendCompletion`:
    ///   `case idempotent`
    ///   `case contentProcessed(_ handler: @escaping (_ error: NWError?) -> Void)`
    ///
    /// `.contentProcessed`, not `.idempotent`: we need to know the write failed, and we need the
    /// completion as the signal to start the next one.
    private func sendAtomically(_ data: Data, on socket: NWConnection) async -> VigilError? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<VigilError?, Never>) in
                socket.send(content: data,
                            contentContext: .defaultMessage,
                            isComplete: true,
                            completion: .contentProcessed { error in
                    // GCD → actor. Only the continuation is touched, so no hop is needed.
                    guard let error else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: RTSPConnection.mapped(error))
                })
            }
        } onCancel: {
            // Through the actor, for the reason spelled out in `receiveOnce`.
            Task { await self.cancelSocket() }
        }
    }

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

            case .setTimer(let id, let deadline):
                arm(id, deadline: deadline)

            case .cancelTimer(let id):
                disarm(id)

            case .emitTrack(let track):
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
    private func deliverFailure(_ error: VigilError) {
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
    private func beginClose() {
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
        let level: LogLevel
        switch event {
        case .requestSent, .responseReceived, .sdpParsed, .trackControlResolved,
             .keepaliveSent, .sessionEstablished, .serverRequest:
            level = .debug
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
    private static func outcome(for error: NWError) -> ReceiveOutcome {
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
    ///
    /// Anything unmapped becomes `.network(_:)` carrying the description, so a log line still
    /// diagnoses it — an error reduced to "something went wrong" is a support case nobody can close.
    private static func mapped(_ error: NWError) -> VigilError {
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

        @unknown default:
            return .transport(.network(describe(error)))
        }
    }

    /// A short, log-safe description of an `NWError`.
    private static func describe(_ error: NWError) -> String {
        Redact.secrets(in: String(describing: error))
    }
}

#endif
