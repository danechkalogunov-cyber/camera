//
//  StreamController.swift
//  VigilCore
//
//  One actor per camera: it owns the credential, the path, the RTSP session and the RTP receivers
//  for exactly one live stream, and it is the only thing that decides whether to try again.
//  Implements docs/spec-core.md §7 and docs/API_CONTRACT.md §4.8 / §5.12
//  (`Streaming/StreamController*.swift`).
//
//  The safety property this file exists to hold:
//
//      **Authentication failure is terminal, and the counter survives the reconnect.**
//
//  `RTSPAuthenticator` counts credentialed 401s inside one connection and stops at two. Every
//  reconnect builds a new connection and therefore a new authenticator, so a controller that
//  reconnected after a 401 would spend two fresh attempts per reconnect, forever — and Hikvision
//  firmware locks an account for about thirty minutes after roughly five failures, including from
//  the camera's own web UI. The counter therefore lives in `LockoutGovernor`, outside the
//  connection, and is consulted **before** a session is built. Only a new password clears it.
//

#if os(macOS)

import Foundation
import VigilProtocols
import VigilRTP
import VigilRTSP
import VigilTransport

// MARK: - StreamPriority

/// How much this stream matters when something has to give.
///
/// Declared for the controller's initialiser and carried verbatim; nothing in the first-light slice
/// arbitrates on it, because arbitration is `StreamCoordinator`'s and that is W4 (spec-core §8).
public enum StreamPriority: Int, Sendable, Hashable, Comparable, CaseIterable {
    /// Fullscreen, or the single focused tile.
    case focused = 400
    /// An on-screen tile of at least 0.35 Mpx.
    case visibleLarge = 300
    /// A smaller on-screen tile.
    case visibleSmall = 200
    /// In the layout but scrolled away or occluded.
    case offscreen = 100
    /// A sidebar micro-preview.
    case thumbnail = 50
    /// Pinned live but not shown anywhere.
    case background = 10

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

// MARK: - StreamController

/// The live path for one camera.
///
/// Composition, not reimplementation (spec-core §7.1): `RTSPSessionDriving` owns the socket and the
/// RTSP session machine, `RTPTrackReceiver` assembles access units, and this actor adds the things
/// that need one serialized owner — the credential, the R1.2 path ladder, the lockout gate,
/// timeouts, reconnection and the decision to stop trying.
///
/// Everything crossing out of it is `Sendable`: state changes and telemetry on a bounded
/// broadcaster, assembled frames through the injected sink. Frames deliberately do **not** travel
/// through the broadcaster — a slow observer must never be able to hold up the media path
/// (API_CONTRACT §2 R-27).
public actor StreamController: Identifiable {

    // MARK: Identity

    /// The camera this controller serves. Stable for its whole life.
    public nonisolated let id: CameraID

    /// The camera's name at construction, for log lines only. The live value is on `camera`.
    public nonisolated let cameraName: String

    // MARK: Injected collaborators

    nonisolated let dependencies: CoreDependencies
    nonisolated let clock: any MonotonicClock
    nonisolated let logger: any LoggerProtocol
    nonisolated let credentialProvider: @Sendable () async throws -> Credential?
    nonisolated let broadcaster: Broadcaster<StreamEvent>
    nonisolated let governor: LockoutGovernor
    nonisolated let probe: StreamProbe

    // MARK: Configuration

    let policy: ReconnectPolicy
    var random: any RandomSource
    var camera: Camera
    var quality: StreamQuality
    var priority: StreamPriority

    /// Where assembled access units go. Replaceable after construction, because `VigilUI` is the
    /// only module that can see both this and the render layer, so it attaches the decode pipeline
    /// once the view exists.
    var frameSink: (@Sendable (EncodedFrame) -> Void)?

    // MARK: Lifecycle state

    var currentState: StreamState = .idle
    var currentDetail: StateDetail = .plain(.idle)
    var attempt = 0
    var isStopping = false
    var isPaused = false
    var runTask: Task<Void, Never>?

    /// Which run loop currently owns `runTask` and the per-attempt state. Bumped by every `start()`.
    ///
    /// `stop()` cancels the running loop but cannot make it *resume* promptly: the loop is normally
    /// suspended inside `runAttempt()`'s `for await`, and it only observes the cancellation when the
    /// actor next lets it run. `restart()` therefore routinely calls `start()` before the old loop
    /// has finished unwinding, and without this stamp that stale loop would tear down the **new**
    /// attempt's session and then clear `runTask` — leaving `start()`'s idempotence guard looking at
    /// `nil` while a run loop is live, so the next `start()` spawns a second one. Two concurrent run
    /// loops mean two concurrent probes, and two probes spend four credentialed 401s against a
    /// device that locks an account at about five.
    var runGeneration: UInt64 = 0
    var startedAt: MediaInstant?
    var resolvedFormat: StreamFormat?
    var latestStatistics = StreamStatistics()
    var resolvedCandidate: RTSPPathCandidate?
    var pendingRedirect: RTSPURL?

    // MARK: Per-attempt state

    var session: (any RTSPSessionDriving)?
    var pendingOutcome: AttemptOutcome?
    var receivers: [Int: RTPTrackReceiver] = [:]
    var trackForRTPChannel: [UInt8: Int] = [:]
    var rtcpChannelForTrack: [Int: UInt8] = [:]
    var controllerTimers: [ControllerTimer: Task<Void, Never>] = [:]
    var attemptStart: MediaInstant = .zero
    var sawFirstPacket = false
    var sawFirstFrame = false
    var keyframeRequests: [MediaInstant] = []

    /// The account this attempt is using, so a `401` is booked against the right key. Never logged
    /// next to a realm.
    var currentAccount: String?

    /// True once a request was re-sent carrying credentials, which is what makes a later success an
    /// authenticated one.
    var didAuthenticate = false

    /// True when a **learned** path stopped answering during this attempt. Turns what would be a
    /// terminal `rtspPathNotFound` into a transient failure, so the ladder runs again instead of
    /// the camera going dark until someone presses a button.
    var pathInvalidated = false

    /// How many times this attempt has nudged the camera for a keyframe before giving up.
    var firstFrameNudges = 0

    /// Events waiting to reach the broadcaster, oldest first. Drained by one task at a time, which
    /// is what keeps them in order.
    var eventQueue: [StreamEvent] = []

    /// Whether the event drain is running.
    var isDrainingEvents = false

    // MARK: Initialisation

    /// Builds a controller. Nothing happens until `start()`.
    ///
    /// - Parameters:
    ///   - camera: the record to stream. Its `capabilities` are read for a learned path and written
    ///     back when the ladder resolves one — read `cameraRecord()` after
    ///     `StreamEvent.pathResolved` and persist it, which is what makes R1.2's "the probe happens
    ///     exactly once per device, ever" true across launches.
    ///   - credentialProvider: how to obtain the password. A closure, not a `CredentialStore`
    ///     reference, so the credential is fetched per attempt and never captured — a password
    ///     change takes effect on the next reconnect with nothing to invalidate. Returning `nil` is
    ///     terminal `.credentialsMissing`.
    ///   - initialQuality: which encoder to ask for.
    ///   - initialPriority: carried for the coordinator that lands in W4; unused here.
    ///   - dependencies: clock, logger, randomness and the session factory.
    ///   - frameSink: where assembled access units go. May be attached later with
    ///     `attachFrameSink(_:)`.
    ///   - policy: the backoff ladder.
    ///
    /// **There is deliberately no `governor:` parameter.** The authentication counter comes from
    /// `dependencies.governor`, which the app builds once per process and persists. The parameter
    /// this initialiser used to have was optional with a `nil` default that minted a private counter,
    /// and the one call site in the app omitted it — so the budget lived and died with a controller,
    /// and `AppSessionModel.stopSession()`'s `controller = nil` handed the next attempt two fresh
    /// strikes. A private counter is now unrepresentable, which is a stronger guarantee than a
    /// documented requirement (docs/RULING-LOCKOUT.md §2.4).
    public init(camera: Camera,
                credentialProvider: @escaping @Sendable () async throws -> Credential?,
                initialQuality: StreamQuality? = nil,
                initialPriority: StreamPriority = .focused,
                dependencies: CoreDependencies,
                frameSink: (@Sendable (EncodedFrame) -> Void)? = nil,
                policy: ReconnectPolicy = .default) {
        self.id = camera.id
        self.cameraName = camera.displayName
        self.camera = camera
        self.credentialProvider = credentialProvider
        self.quality = initialQuality ?? camera.preferredQuality ?? .main
        self.priority = initialPriority
        self.dependencies = dependencies
        self.clock = dependencies.clock
        self.logger = dependencies.logger
        self.random = dependencies.random
        self.frameSink = frameSink
        self.governor = dependencies.governor
        self.policy = policy
        self.resolvedCandidate = camera.capabilities.flatMap { capabilities in
            capabilities.resolvedRTSPPath.map { path in
                RTSPPathCandidate(template: capabilities.rtspPathTemplate, path: path, order: 0)
            }
        }
        // `replaysLatest` per spec-core §6.9's table: a tile that subscribes after the connect
        // sequence started still sees where the stream is. It replays the newest *event*, which is
        // not necessarily a state change — a subscriber that needs the state itself reads
        // `state()`, which is why that accessor exists alongside the stream.
        self.broadcaster = Broadcaster<StreamEvent>(replaysLatest: true,
                                                    bufferingPolicy: .bufferingNewest(64))
        self.probe = StreamProbe(dependencies: dependencies)
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
    public func cameraRecord() -> Camera { camera }

    /// Sends assembled access units to `sink` from now on, replacing any previous one.
    ///
    /// The sink is called on the controller's executor and must return immediately: it is the
    /// decode pipeline's `submit`, which applies its own drop policy and never blocks. Blocking
    /// here stalls RTP ingest for this camera.
    public func attachFrameSink(_ sink: @escaping @Sendable (EncodedFrame) -> Void) {
        frameSink = sink
    }

    /// Stops delivering frames. Media keeps flowing and statistics keep updating.
    public func detachFrameSink() {
        frameSink = nil
    }

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
        runGeneration &+= 1
        let generation = runGeneration
        runTask = Task { [weak self] in
            await self?.runLoop(generation: generation)
        }
    }

    /// Stops, gracefully: `TEARDOWN` within a bounded flush, then the socket closes.
    ///
    /// Never throws and is safe to call from a task that is being cancelled, so call sites need no
    /// `Task.isCancelled` dance.
    public func stop(reason: EndReason = .userRequested) async {
        isStopping = true
        runTask?.cancel()
        runTask = nil
        pendingOutcome = .stopped
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

    /// Repositions archive playback inside the session that is already open.
    ///
    /// **Why this exists, in measured numbers.** A seek used to be a whole new RTSP session —
    /// connect, `OPTIONS`, `DESCRIBE`, the 401, `DESCRIBE` again, `SETUP`, `PLAY`. On a DS-I256 that
    /// cost 1.9 s, and `docs/PLAYBACK-LATENCY.md` has the per-request split: the authenticated
    /// `DESCRIBE` alone is ~580 ms, because the camera opens the recording in order to describe it,
    /// and `SETUP` another ~55 ms. Sending `PLAY` with a new `Range:` on the open session skips all
    /// of it and lands near 1.25 s.
    ///
    /// ⚠️ WHAT IT CANNOT SAVE, so nobody expects more of it than it can give: `PLAY` itself is
    /// ~870 ms on that device and the first keyframe another ~350 ms. Those are the camera seeking
    /// and then encoding, they are 64 % of the wait, and no client-side change touches either.
    ///
    /// - Returns: `false` when there is no session to reposition — no session at all, or one that
    ///   is not playing — in which case the caller must fall back to rebuilding it. `true` means
    ///   only that the command was handed over: RTSP answers on `events()`, so a camera that
    ///   ignores `Range:` on a session opened with `?starttime=` shows up as no new frames rather
    ///   than as an error here. The caller owns that timeout, because only the caller knows what it
    ///   was expecting to see.
    public func seekWithinSession(toRange rangeText: String) async -> Bool {
        guard let session, currentState == .playing else { return false }
        logger.info(.core, "seeking inside the open session", ["range": rangeText])
        await session.perform(.play(rangeText: rangeText))
        return true
    }

    /// Stops handing frames to the sink without dropping the session: RTSP and its keepalives stay
    /// up, and frames are discarded rather than queued.
    ///
    /// Used by occlusion (spec-core §8.6). Discarded, not buffered: a tile that comes back has no
    /// use for a two-minute backlog.
    public func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        logger.info(.core, "stream \(paused ? "paused" : "resumed")", ["camera": id.short])
    }

    /// Sets the priority the coordinator will arbitrate on in W4.
    public func setPriority(_ newPriority: StreamPriority) {
        priority = newPriority
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
        guard currentState != .stopped, currentState != .idle else { return }
        await restart()
    }

    /// The user supplied a password. Clears this device's authentication counters if — and only if —
    /// it is a **different** password, then reconnects.
    ///
    /// Three things this method used to get wrong, all fixed here (docs/RULING-LOCKOUT.md §4):
    ///
    /// 1. It took an `account:` argument the caller supplied, which was never reconciled with
    ///    `credentialProvider()`'s `Credential.account` — the name the gate and `block()` key on. A
    ///    mismatch silently cleared nothing. The account is now read from the provider, exactly as
    ///    `runAttempt()` reads it, so the clear and the block cannot key differently.
    /// 2. It cleared unconditionally, with no check that the secret had changed. A user whose
    ///    password genuinely is wrong will retype the same characters, and that is the single most
    ///    likely route to a real thirty-minute lockout. The governor now demands a fingerprint and
    ///    refuses a match.
    /// 3. From `.failed` it called `start()`, whose `runTask == nil` guard returns immediately —
    ///    because the run loop is asleep inside the five-minute cold retry with `runTask` still set.
    ///    Fail-safe for the lockout, wrong for the user, and invisible. It now cancels and joins the
    ///    old loop before starting a new one.
    ///
    /// A refused clear is not an error: the reconnect still happens, and the gate in `runAttempt()`
    /// reports `authenticationFailed` with the remedy that says so.
    public func credentialsUpdated() async {
        // A Keychain that will not answer is not a reason to skip the reconnect: the attempt itself
        // reports `keychainUnavailable` with a remedy, and clearing nothing is the fail-safe outcome.
        var credential: Credential?
        do {
            credential = try await credentialProvider()
        } catch {
            logger.warning(.core, "credential update could not read the credential",
                           ["camera": id.short])
        }
        if let credential {
            let cleared = await governor.clear(host: camera.host,
                                               account: credential.account,
                                               secretFingerprint: SecretFingerprint.of(credential))
            logger.info(.core, "credential update \(cleared ? "cleared" : "did not clear") the "
                + "auth counters", ["camera": id.short])
        }
        attempt = 0
        // Join, do not merely cancel. `start()` is idempotent on `runTask != nil`, and the loop keeps
        // `runTask` set while it sleeps out the five-minute cold retry, so a bare `start()` here
        // would return having done nothing. `teardown()` comes first because it closes the session,
        // which finishes the event stream the attempt is suspended on — without it the join would be
        // waiting on a loop that has no reason to wake.
        isStopping = true
        runTask?.cancel()
        let outgoing = runTask
        runTask = nil
        await teardown()
        await outgoing?.value
        isStopping = false
        start()
    }

    // MARK: The run loop

    /// One attempt after another, with the ladder in between, until something terminal happens or
    /// the controller is stopped.
    func runLoop(generation: UInt64) async {
        while !isStopping, !Task.isCancelled, generation == runGeneration {
            let outcome = await runAttempt(generation: generation)
            // A newer `start()` may have taken ownership while this loop was suspended. From here
            // on a stale loop must touch nothing shared: `teardown()` would close the new attempt's
            // session, and `runTask = nil` would hide the new loop from `start()`'s guard.
            guard generation == runGeneration else { return }
            await teardown()
            if isStopping || Task.isCancelled { break }

            switch outcome {
            case .stopped:
                endRun(generation)
                return

            case let .redirect(url):
                // A redirect is not a failure: reconnect at once, and do not spend an attempt on it
                // (spec-core §7.6).
                pendingRedirect = url

            case let .failed(error):
                emit(.error(error, isFatal: true))
                transition(to: .failed, detail: .failure(error, state: .failed, attempt: attempt))
                if error.code.forbidsColdRetry {
                    logger.error(.core, "stream failed terminally",
                                 ["camera": id.short, "code": error.code.rawValue])
                    endRun(generation)
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
                    let coldDelay = max(policy.coldRetryInterval, Self.pauseDelay(for: error))
                    let coldRetryAt = Date().addingTimeInterval(coldDelay.seconds)
                    transition(to: .failed,
                               detail: .failure(error, state: .failed, attempt: attempt,
                                                nextRetryAt: coldRetryAt))
                    try? await clock.sleep(for: coldDelay)
                    attempt = 0
                    continue
                }
                // `signInPaused` carries its own wait, and it is minutes rather than the ladder's
                // seconds. Sleeping the ladder delay instead would spin at the governor's gate for
                // the whole probe window, emitting an error event every half second
                // (docs/RULING-LOCKOUT.md §3). The same value feeds `nextRetryAt`, which is what the
                // countdown the UI already renders is read from.
                let delay = max(policy.delay(forAttempt: attempt, random: &random),
                                Self.pauseDelay(for: error))
                attempt += 1
                let retryAt = Date().addingTimeInterval(delay.seconds)
                emit(.reconnectScheduled(attempt: attempt, delay: delay, cause: error))
                transition(to: .reconnecting,
                           detail: .failure(error, state: .reconnecting, attempt: attempt,
                                            nextRetryAt: retryAt))
                try? await clock.sleep(for: delay)
            }
        }
        endRun(generation)
    }

    /// How long a `signInPaused` failure says to wait, or zero for anything else.
    ///
    /// Read from `context["retryAfterSeconds"]` rather than from a typed payload because `StreamError`
    /// is a `Hashable` value the whole app compares and a duration in it would have to be one too;
    /// the key is written in exactly one place, `resolvePath`.
    static func pauseDelay(for error: StreamError) -> Duration {
        guard error.code == .signInPaused,
              let raw = error.context["retryAfterSeconds"],
              let seconds = Int(raw), seconds > 0 else { return .zero }
        return .seconds(seconds)
    }

    /// Releases `runTask`, but only when this run loop still owns it.
    ///
    /// A stale loop that cleared it unconditionally would let the next `start()` past its
    /// idempotence guard while a live loop was still running.
    func endRun(_ generation: UInt64) {
        guard generation == runGeneration else { return }
        runTask = nil
    }

    // MARK: State plumbing

    /// Moves to `state` and publishes the change. A transition to the state we are already in, with
    /// the same detail, is dropped so the UI is not woken for nothing.
    func transition(to state: StreamState, detail: StateDetail) {
        guard state != currentState || detail != currentDetail else { return }
        let previous = currentState
        currentState = state
        currentDetail = detail
        logger.debug(.core, "stream state \(previous.rawValue) -> \(state.rawValue)",
                     ["camera": id.short])
        emit(.stateChanged(from: previous, to: state, detail: detail))
    }

    /// Publishes an event to every observer, in order.
    ///
    /// Never suspends, so it can be called from anywhere in the media path without opening a
    /// suspension point where ordering matters. Events queue here and one drain task hands them to
    /// the broadcaster.
    ///
    /// The queue exists because ordering is not optional: `Broadcaster.yield` is actor-isolated, so
    /// the obvious `Task { await broadcaster.yield(event) }` spawns one unordered task per event
    /// and two state changes emitted in the same batch can arrive reversed — which would leave the
    /// UI showing "Connecting…" after the picture appeared. The broadcaster's own buffering policy
    /// is bounded, so this queue cannot apply back-pressure to the media path either.
    func emit(_ event: StreamEvent) {
        eventQueue.append(event)
        guard !isDrainingEvents else { return }
        isDrainingEvents = true
        Task { [weak self] in await self?.drainEvents() }
    }

    /// Hands queued events to the broadcaster, oldest first.
    private func drainEvents() async {
        while !eventQueue.isEmpty {
            let next = eventQueue.removeFirst()
            await broadcaster.yield(next)
        }
        isDrainingEvents = false
    }
}

// MARK: - AttemptOutcome

/// How one connect attempt ended.
enum AttemptOutcome: Sendable {
    /// The user or the coordinator stopped us.
    case stopped
    /// Terminal: nothing is retried until the user acts — or, for non-auth causes, until the
    /// five-minute cold retry.
    case failed(StreamError)
    /// Transient: the backoff ladder applies.
    case retry(StreamError)
    /// The device sent us elsewhere. Reconnect at once, without spending an attempt.
    case redirect(RTSPURL)
}

#endif
