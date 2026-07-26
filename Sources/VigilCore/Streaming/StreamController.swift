//
//  StreamController.swift
//  VigilCore
//
//  One actor per camera: it owns the credential, the path, the socket, the RTSP session machine and
//  the RTP receivers for exactly one live stream, and it is the only thing that decides when to try
//  again.
//  Implements docs/spec-core.md §7 and docs/API_CONTRACT.md §4.8 / §5.12
//  (`Streaming/StreamController*.swift`).
//
//  The safety property this file exists to hold:
//
//      **Authentication failure is terminal, and the counter survives the reconnect.**
//
//  `RTSPAuthenticator` counts credentialed 401s inside one connection and stops at two. A new
//  connection builds a new authenticator, so a controller that reconnected on a 401 would spend two
//  more attempts per reconnect, forever, and Hikvision firmware locks an account for thirty minutes
//  after roughly five. The counter therefore lives in `LockoutGovernor`, outside the connection,
//  and is consulted **before** a socket is opened; only a new password clears it.
//

#if os(macOS)

import Foundation
import VigilProtocols
import VigilRTP
import VigilRTSP

// MARK: - StreamController

/// The live path for one camera.
///
/// Composition, not reimplementation (spec-core §7.1): `RTSPSessionMachine` decides protocol,
/// `RTSPTransport` moves bytes, `RTPTrackReceiver` assembles access units. This actor adds
/// lifecycle, timeouts, the R1.2 path ladder, reconnection and the decision of when to stop trying.
///
/// Everything crossing out of it is `Sendable`: state changes and telemetry on a bounded
/// broadcaster, and assembled frames through the injected sink — frames do **not** travel through
/// the broadcaster, because a slow observer must never be able to hold up the media path
/// (API_CONTRACT §2 R-27).
public actor StreamController: Identifiable {

    // MARK: Identity

    /// The camera this controller serves. Stable for its whole life.
    public nonisolated let id: CameraID

    /// The camera's name at construction, for log lines only. The live value is on `camera`.
    public nonisolated let cameraName: String

    // MARK: Injected collaborators

    nonisolated let clock: any MonotonicClock
    nonisolated let logger: any LoggerProtocol
    nonisolated let makeTransport: RTSPTransportFactory
    nonisolated let credentialProvider: @Sendable () async throws -> Credential?
    nonisolated let frameSink: @Sendable (EncodedFrame) -> Void
    nonisolated let broadcaster: Broadcaster<StreamEvent>
    nonisolated let governor: LockoutGovernor
    nonisolated let probe: StreamProbe

    // MARK: Configuration

    let policy: ReconnectPolicy
    var random: any RandomSource
    var camera: Camera
    var quality: StreamQuality

    // MARK: Lifecycle state

    var currentState: StreamState = .idle
    var currentDetail: StateDetail = .plain(.idle)
    var attempt = 0
    var isStopping = false
    var isPaused = false
    var runTask: Task<Void, Never>?
    var startedAt: MediaInstant?
    var resolvedFormat: StreamFormat?
    var latestStatistics = StreamStatistics()
    var resolvedCandidate: RTSPPathCandidate?
    var pendingRedirect: RTSPURL?

    // MARK: Per-attempt session state

    var machine: RTSPSessionMachine?
    var transport: (any RTSPTransport)?
    var readTask: Task<Void, Never>?
    var signal: SessionSignal<AttemptOutcome>?
    var pendingWrites: [Data] = []
    var isDraining = false
    var receivers: [Int: RTPTrackReceiver] = [:]
    var trackForRTPChannel: [UInt8: Int] = [:]
    var rtcpChannelForTrack: [Int: UInt8] = [:]
    var machineTimers: [RTSPTimerID: Task<Void, Never>] = [:]
    var controllerTimers: [ControllerTimer: Task<Void, Never>] = [:]
    var attemptStart: MediaInstant = .zero
    var sawFirstPacket = false
    var sawFirstFrame = false
    var keyframeRequests: [MediaInstant] = []

    // MARK: Initialisation

    /// Builds a controller. Nothing happens until `start()`.
    ///
    /// - Parameters:
    ///   - camera: the record to stream. Its `capabilities` are read for a learned path and
    ///     written back when the ladder resolves one — read `cameraRecord()` after
    ///     `StreamEvent.pathResolved` and persist it.
    ///   - credentialProvider: how to obtain the password. A closure rather than a `CredentialStore`
    ///     reference so the credential is fetched per attempt, never captured, and so a test can
    ///     supply one without a Keychain. Returning `nil` is terminal `.credentialsMissing`.
    ///   - quality: which encoder to ask for. `nil` takes the camera's preference, then `.main`.
    ///   - makeTransport: how to obtain a socket for a URL.
    ///   - frameSink: where assembled access units go — `VigilVideo`'s decode pipeline in the app.
    ///     Called from the controller's executor; it must return immediately and must not block.
    ///   - governor: the per-device authentication counter. **Share one instance across every lane
    ///     that touches a device** (API_CONTRACT §2 R-25 rule 4); the default builds a private one,
    ///     which is correct only while this controller is the device's only lane.
    ///   - policy: the backoff ladder.
    ///   - random: injected randomness for jitter and for the Digest `cnonce`. Seed it in tests.
    public init(camera: Camera,
                credentialProvider: @escaping @Sendable () async throws -> Credential?,
                quality: StreamQuality? = nil,
                makeTransport: @escaping RTSPTransportFactory,
                frameSink: @escaping @Sendable (EncodedFrame) -> Void,
                clock: any MonotonicClock,
                governor: LockoutGovernor? = nil,
                policy: ReconnectPolicy = .default,
                random: any RandomSource = SystemRandomSource(),
                logger: any LoggerProtocol = NullLogger()) {
        self.id = camera.id
        self.cameraName = camera.displayName
        self.camera = camera
        self.credentialProvider = credentialProvider
        self.quality = quality ?? camera.preferredQuality ?? .main
        self.makeTransport = makeTransport
        self.frameSink = frameSink
        self.clock = clock
        self.governor = governor ?? LockoutGovernor(clock: clock, logger: logger)
        self.policy = policy
        self.random = random
        self.logger = logger
        self.resolvedCandidate = camera.capabilities.flatMap { capabilities in
            capabilities.resolvedRTSPPath.map { path in
                RTSPPathCandidate(template: capabilities.rtspPathTemplate, path: path, order: 0)
            }
        }
        self.broadcaster = Broadcaster<StreamEvent>(replaysLatest: false,
                                                    bufferingPolicy: .bufferingNewest(64))
        self.probe = StreamProbe(makeTransport: makeTransport,
                                 clock: clock,
                                 random: random,
                                 logger: logger)
    }

    // MARK: Observation

    /// A fresh event stream. A factory, never a stored property: a stored `AsyncStream` has exactly
    /// one consumer and the second caller silently gets nothing (API_CONTRACT §2 R-27).
    ///
    /// Buffering is `.bufferingNewest(64)`: a stalled observer drops its own oldest events and
    /// never stalls the stream. `onTermination` deregisters it.
    public nonisolated func events() -> AsyncStream<StreamEvent> { broadcaster.stream() }

    /// The current state.
    public func state() -> StreamState { currentState }

    /// The current state's detail — narration, attempt number, next retry time, last failure.
    public func stateDetail() -> StateDetail { currentDetail }

    /// The most recent telemetry sample.
    public func statistics() -> StreamStatistics { latestStatistics }

    /// The negotiated format, once `PLAY` has succeeded.
    public func format() -> StreamFormat? { resolvedFormat }

    /// The camera record, including any capabilities the path ladder learned.
    ///
    /// Persist this after `StreamEvent.pathResolved`: it is what makes R1.2's "the probe happens
    /// exactly once per device, ever" true across launches.
    public func cameraRecord() -> Camera { camera }

    // MARK: Lifecycle

    /// Starts, or does nothing if a run loop is already going.
    ///
    /// Idempotent by contract (spec-core §7.1), including from `.stopped` and `.failed`: a stopped
    /// controller is reusable.
    public func start() {
        guard runTask == nil else { return }
        isStopping = false
        attempt = 0
        startedAt = clock.now()
        runTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// Stops, gracefully.
    ///
    /// Cancels the run loop, sends `TEARDOWN` with a 1.5 s budget, and closes the socket. Never
    /// throws and is safe to call from a task that is being cancelled, so call sites need no
    /// `Task.isCancelled` dance.
    public func stop(reason: EndReason = .userRequested) async {
        isStopping = true
        runTask?.cancel()
        runTask = nil
        await signal?.send(.stopped)
        await teardown()
        transition(to: .stopped, detail: .plain(.stopped, attempt: attempt))
        emit(.ended(reason: reason))
    }

    /// Full teardown and immediate reconnect, with the attempt counter reset. What the UI's
    /// "Reconnect" button and Stream Doctor call.
    public func restart() async {
        await stop(reason: .userRequested)
        isStopping = false
        attempt = 0
        start()
    }

    /// Stops decoding without dropping the session: the RTSP session and its keepalives stay up,
    /// and assembled frames are discarded instead of being handed to the sink.
    ///
    /// Used by occlusion (spec-core §8.6). Frames are dropped rather than buffered because a
    /// paused tile has no use for a two-minute backlog when it comes back.
    public func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        logger.info(.core, "stream \(paused ? "paused" : "resumed")", ["camera": id.short])
    }

    /// Applies an edited camera record.
    ///
    /// A change to the endpoint, the transport, the channel, the path or the credential handle
    /// forces a restart; everything else is metadata and must not disturb the stream.
    public func setCamera(_ updated: Camera) async {
        let needsRestart = updated.host != camera.host
            || updated.rtspPort != camera.rtspPort
            || updated.transport != camera.transport
            || updated.channel != camera.channel
            || updated.rtspPathOverride != camera.rtspPathOverride
            || updated.credentialRef != camera.credentialRef
        let credentialChanged = updated.credentialRef != camera.credentialRef

        camera = updated
        if let preferred = updated.preferredQuality { quality = preferred }
        if credentialChanged { resolvedCandidate = nil }

        guard needsRestart else { return }
        if currentState == .stopped || currentState == .idle { return }
        await restart()
    }

    /// The user supplied a new password.
    ///
    /// Clears the authentication counters for this device — **the only thing that may** — and
    /// reconnects immediately, from `.failed` as well as from anywhere else.
    public func credentialsUpdated(account: String) async {
        await governor.clear(host: camera.host, account: account)
        attempt = 0
        if currentState == .failed || currentState == .stopped || runTask == nil {
            isStopping = false
            start()
        } else {
            await restart()
        }
    }

    // MARK: The run loop

    /// One attempt after another, with the ladder in between, until something terminal happens or
    /// the controller is stopped.
    func runLoop() async {
        while !isStopping, !Task.isCancelled {
            let outcome = await runAttempt()
            await teardown()
            if isStopping || Task.isCancelled { break }

            switch outcome {
            case .stopped:
                break

            case let .redirect(url):
                // A redirect and a ladder advance are not failures: reconnect at once, and do not
                // spend an attempt on them (spec-core §7.6).
                pendingRedirect = url
                continue

            case let .failed(error):
                emit(.error(error, isFatal: true))
                transition(to: .failed,
                           detail: .failure(error, state: .failed, attempt: attempt))
                if error.code.forbidsColdRetry {
                    logger.error(.core, "stream failed terminally",
                                 ["camera": id.short, "code": error.code.rawValue])
                    runTask = nil
                    return
                }
                // Non-auth failures get one slow retry every five minutes: a camera that was
                // unplugged should come back on its own without the user finding a button.
                let coldRetryAt = Date().addingTimeInterval(policy.coldRetryInterval.seconds)
                transition(to: .failed,
                           detail: .failure(error, state: .failed, attempt: attempt,
                                            nextRetryAt: coldRetryAt))
                try? await clock.sleep(for: policy.coldRetryInterval)
                attempt = 0

            case let .retry(error):
                emit(.error(error, isFatal: false))
                if policy.hasExhaustedLadder(attempt: attempt) {
                    let coldRetryAt = Date().addingTimeInterval(policy.coldRetryInterval.seconds)
                    transition(to: .failed,
                               detail: .failure(error, state: .failed, attempt: attempt,
                                                nextRetryAt: coldRetryAt))
                    try? await clock.sleep(for: policy.coldRetryInterval)
                    attempt = 0
                    continue
                }
                let delay = policy.delay(forAttempt: attempt, random: &random)
                attempt += 1
                let retryAt = Date().addingTimeInterval(delay.seconds)
                emit(.reconnectScheduled(attempt: attempt, delay: delay, cause: error))
                transition(to: .reconnecting,
                           detail: .failure(error, state: .reconnecting, attempt: attempt,
                                            nextRetryAt: retryAt))
                try? await clock.sleep(for: delay)
            }
        }
        runTask = nil
    }

    // MARK: State plumbing

    /// Moves to `state` and publishes the change. A transition to the state we are already in with
    /// the same detail is dropped, so the UI is not woken for nothing.
    func transition(to state: StreamState, detail: StateDetail) {
        guard state != currentState || detail != currentDetail else { return }
        let previous = currentState
        currentState = state
        currentDetail = detail
        logger.debug(.core, "stream state \(previous.rawValue) -> \(state.rawValue)",
                     ["camera": id.short])
        emit(.stateChanged(from: previous, to: state, detail: detail))
    }

    /// Publishes an event to every observer.
    ///
    /// Fire-and-forget: the broadcaster is an actor and its buffering policy is bounded, so this
    /// cannot apply back-pressure to the media path.
    func emit(_ event: StreamEvent) {
        let broadcaster = broadcaster
        Task { await broadcaster.yield(event) }
    }
}

// MARK: - AttemptOutcome

/// How one connect attempt ended.
enum AttemptOutcome: Sendable {
    /// The user or the coordinator stopped us.
    case stopped
    /// Terminal: nothing will be retried until the user acts (or, for non-auth causes, until the
    /// five-minute cold retry).
    case failed(StreamError)
    /// Transient: the backoff ladder applies.
    case retry(StreamError)
    /// The device sent us elsewhere. Reconnect at once, without spending an attempt.
    case redirect(RTSPURL)
}

#endif
