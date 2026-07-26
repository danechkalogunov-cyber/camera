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

    // MARK: - Injected

    private let config: RTSPSessionConfig
    private let clock: any MonotonicClock
    private let logger: any LoggerProtocol
    private let connectTimeout: Duration

    /// The one queue Network.framework calls back on. Serial and `.userInitiated`, per
    /// API_CONTRACT §4.7.
    ///
    /// **This is one of the few sanctioned uses of GCD in Vigil.** `NWConnection` has no async
    /// interface: it delivers state changes and I/O completions to a `DispatchQueue`, so the hop
    /// from that queue into this actor has to be written by hand. Every such hop in this file is
    /// marked with a comment saying which direction it crosses.
    private let queue: DispatchQueue

    // MARK: - Session

    private var machine: RTSPSessionMachine

    // MARK: - Socket

    private var socket: NWConnection?
    private var lifecycle: Lifecycle = .idle
    private var connectContinuation: CheckedContinuation<VigilError?, Never>?

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
    /// Buffering is `.bufferingNewest(512)`, matching R-27's standing capacity for RTP packets. A
    /// consumer that cannot keep up loses its oldest events; the fix for a consumer that cannot
    /// keep up is `pauseReads()`, which stops the camera at the TCP window instead.
    public func events() -> AsyncStream<RTSPConnectionEvent> {
        eventSink?.finish()
        let made = AsyncStream<RTSPConnectionEvent>.makeStream(bufferingPolicy: .bufferingNewest(512))
        eventSink = made.continuation
        return made.stream
    }

    // MARK: - Connecting

    /// Opens the TCP connection and starts the session.
    ///
    /// Returns once the socket is ready and `OPTIONS` has been queued for writing; everything after
    /// that arrives on ``events()``. Throws `.transport(.egressBlocked)` for a destination outside
    /// the LAN, `.transport(.connectTimeout)` when the handshake does not complete in time, and
    /// whatever `NWError` mapped to when the connection failed outright.
    ///
    /// - Note: API_CONTRACT §4.7 declares `throws(TransportError)`. The brief for this file requires
    ///   failures to surface as `VigilError`, which is the wider type `VigilCore` switches on, so
    ///   every throw here is `VigilError.transport(...)` or `.cancelled`.
    public func connect() async throws(VigilError) {
        try vigilRequire(lifecycle == .idle, "RTSPConnection.connect() called twice")

        // R-71: the destination is classified before a socket exists, not after.
        guard EgressGuard.isPermitted(config.url.host) else {
            throw VigilError.transport(.egressBlocked(host: config.url.host))
        }
        let port = try endpointPort()

        lifecycle = .connecting

        // NWEndpoint.Host:
        //   public init(_ string: String)
        // Reads an IPv4 literal, an IPv6 literal (with an optional %zone) or a DNS name.
        let host = NWEndpoint.Host(config.url.host)

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
            lifecycle = .closed
            // public func cancel()
            created.cancel()
            socket = nil
            logger.failure(.transport, failure)
            throw failure
        }

        lifecycle = .running
        logger.info(.transport, "connected", ["url": config.url.description])
        startWriteDrain()
        startReadLoop()
        openSession()
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
            await self.connectTimedOut()
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
            finishConnect(with: nil)

        case .waiting(let error):
            // `.waiting` is **not** terminal — Network.framework keeps retrying behind it, which is
            // right for a laptop whose Wi-Fi is coming back and wrong for a camera that is not
            // there. We do not act on it; the connect watchdog decides, and after `.ready` the
            // session's own timers do.
            logger.notice(.transport, "connection waiting", ["reason": Self.describe(error)])

        case .failed(let error):
            let mapped = Self.mapped(error)
            if connectContinuation != nil {
                finishConnect(with: mapped)
            } else {
                // `.failed` can arrive after `.ready`, and when it does the session is over. The
                // reconnect decision belongs to `VigilCore` (.vigil/STEP3.md §3.1), so it is
                // surfaced and never retried here. The machine is told first, so its own
                // `.stateChanged` / `.fail` ordering is preserved.
                feedConnectionClosed(reason: Self.describe(error))
                deliverFailure(mapped)
            }

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
                logger.info(.transport, "peer closed the connection")
                feedConnectionClosed(reason: nil)
                return

            case .failed(let error):
                feedConnectionClosed(reason: Self.describe(error))
                deliverFailure(error)
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
            socket.cancel()
        }
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
            socket.cancel()
        }
    }

    // MARK: - Action execution

    /// Executes one batch of actions, in order, without ever suspending.
    ///
    /// Not suspending is the whole design. `RTSPSessionMachine` guarantees the order of what it
    /// returns (docs/spec-rtsp.md §14.6) — `.stateChanged` before what the state causes, every
    /// `.emitTrack` before its `.emitTiming` before its `.emitMedia`, `.fail` last — and an `await`
    /// anywhere in this loop would let a timer or a command interleave and break that.
    private func execute(_ actions: [RTSPAction]) {
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
        // blocks, which is what lets `execute(_:)` stay synchronous.
        eventSink?.yield(event)
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
    private func beginClose() {
        guard lifecycle == .connecting || lifecycle == .running else { return }
        lifecycle = .closing
        isWriteClosed = true
        disarmAllTimers()
        wakeWriteDrain()
        wakeReadLoop()
        finishConnect(with: .cancelled)
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
            await self.abandonQueuedWrites()
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
    private func abandonQueuedWrites() {
        guard !writeQueue.isEmpty || writeWaiter != nil else { return }
        logger.warning(.transport, "abandoning queued writes at close",
                       ["frames": String(writeQueue.count)])
        writeQueue.removeAll()
        writeQueueBytes = 0
        socket?.cancel()
        wakeWriteDrain()
    }

    // MARK: - Logging

    /// Maps one `RTSPLogEvent` onto the injected logger.
    ///
    /// The message is the event's reflected form, deliberately: these are structured records whose
    /// payloads are already named, and re-writing twenty-two of them by hand is twenty-two chances
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

        case .dns(let code):
            // A name that does not resolve is not reachable, which is the same thing to the caller.
            return .transport(.network("DNS resolution failed (\(code))"))

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
