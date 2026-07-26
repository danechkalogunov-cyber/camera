//
//  StreamProbe.swift
//  VigilCore
//
//  The R1.2 path ladder: probe the known Hikvision RTSP paths and keep the winner. The user is
//  never asked for a stream URL.
//  Implements docs/REQUIREMENTS-CUSTOMER.md §R1.2, docs/API_CONTRACT.md §4.8 (`StreamProbe`) and
//  docs/RULING-LOCKOUT.md §2.6.
//
//  Four rules decide everything in this file:
//
//  * `200` with a parseable SDP carrying a video codec Vigil can decode **wins**.
//  * `404`/`451`/`455`/`460` **advance** to the next candidate.
//  * `401` does **not** advance. The path is right and the credentials need applying — and, because
//    two credentialed 401s per device are terminal (API_CONTRACT §2 R-25), a `401` stops the entire
//    ladder rather than repeating itself against four more paths. Walking the ladder after a
//    rejected password is how an app locks its user out of their own camera.
//  * **The whole five-rung sequence spends at most one credentialed sign-in.** This is the rule the
//    other three used to be undermined by: nothing between the rungs consulted the lockout counter,
//    each rung built a fresh session machine with a fresh authenticator, and three separate code
//    paths turned a credentialed `401` into "wrong path" — a five-second request timeout, the device
//    closing the control socket, and this file's own eight-second per-candidate deadline. So the
//    ladder walked all five rungs spending two credentialed rejections each, crossed the device's
//    own threshold about twenty seconds in, and then ran again on every rung of the reconnect
//    ladder. Rung 1 is now the only rung that may ever send credentials, and rungs 2…5 are given an
//    allowance of zero unless rung 1's credentialed request was answered with something other than
//    a `401`.
//

#if os(macOS)

import Foundation
import VigilProtocols
import VigilRTSP
import VigilTransport

// MARK: - Outcome

/// What the ladder concluded.
public enum StreamProbeOutcome: Sendable {

    /// A candidate answered with a usable SDP. Persist `candidate` on the camera record.
    case resolved(RTSPPathCandidate, videoCodec: VideoCodec?)

    /// A candidate answered `401`. The path is right; the credentials are missing or wrong. The
    /// ladder stopped there on purpose — no further candidate was tried.
    case authenticationRequired(RTSPPathCandidate, StreamError)

    /// Every candidate was tried and none answered. Carries the most diagnostic failure seen.
    case exhausted(StreamError)
}

// MARK: - StreamProbe

/// Finds the RTSP path a device actually answers on.
///
/// One instance can serve many cameras; it holds no per-camera state.
public actor StreamProbe {

    /// Candidates in flight at once, once authentication is known good. Three, from R1.2.
    public static let maxInFlight = 3

    private let dependencies: CoreDependencies
    private let candidateTimeout: Duration

    /// Builds a probe.
    ///
    /// - Parameters:
    ///   - dependencies: clock, logger, randomness, the session factory and the shared
    ///     `LockoutGovernor`. The governor arrives for free because this type already stores the
    ///     whole dependency set, which matters: this is where the credentials are actually spent.
    ///   - candidateTimeout: how long one candidate may take, end to end. Eight seconds, because it
    ///     has to cover the session's own four-second connect budget **and** the round trips after
    ///     it; a shorter deadline here would fire while the socket was still legitimately
    ///     connecting, and — since `connect()` awaits a continuation that cancellation does not
    ///     resume — would not even save the time it appeared to.
    public init(dependencies: CoreDependencies, candidateTimeout: Duration = .seconds(8)) {
        self.dependencies = dependencies
        self.candidateTimeout = candidateTimeout
    }

    // MARK: API

    /// The contract's entry point: the winning candidate, or `nil` when the ladder found nothing.
    ///
    /// Prefer `probe(camera:credential:quality:credentialedAllowance:)`, which distinguishes "no path
    /// answered" from "the path is right and the password is wrong" — a distinction the UI must make,
    /// because one leads to Stream Doctor and the other to a password field.
    public func findWorkingPath(camera: Camera,
                                credential: Credential?,
                                quality: StreamQuality,
                                credentialedAllowance: Int) async -> RTSPPathCandidate? {
        switch await probe(camera: camera, credential: credential, quality: quality,
                           credentialedAllowance: credentialedAllowance) {
        case let .resolved(candidate, _): candidate
        case let .authenticationRequired(candidate, _): candidate
        case .exhausted: nil
        }
    }

    /// Walks the ladder for one camera.
    ///
    /// An explicit `rtspPathOverride` short-circuits the whole thing: a path the user typed is
    /// honoured, not tested against alternatives.
    ///
    /// - Parameter credentialedAllowance: credentialed sign-in attempts the **whole sequence** may
    ///   spend, as granted by `LockoutGovernor.reserve`. Normally one (docs/RULING-LOCKOUT.md §2.6).
    ///
    /// This method also settles the sequence with the governor, because it is the only thing that
    /// knows whether a credential reached the wire: `recordSuccess` on proof, `refund` when no rung
    /// wrote an `Authorization` header at all, and neither in any other case.
    public func probe(camera: Camera,
                      credential: Credential?,
                      quality: StreamQuality,
                      credentialedAllowance: Int) async -> StreamProbeOutcome {
        if let override = camera.rtspPathOverride, !override.isEmpty {
            let candidate = RTSPPathCandidate.override(override)
            dependencies.logger.info(.core, "path override in force; ladder skipped",
                                     ["path": Redact.path(candidate.path)])
            return .resolved(candidate, videoCodec: camera.capabilities?.videoCodec)
        }

        let candidates = RTSPPathCandidate.ladder(
            channel: camera.channel,
            quality: quality,
            preferring: camera.capabilities?.rtspPathTemplate)
        var lastFailure = StreamError(code: .rtspPathNotFound)
        guard let first = candidates.first else { return .exhausted(lastFailure) }

        // Phase 1 — the first rung runs **alone**, and it is the only rung that may spend a strike.
        //
        // Hikvision firmware authenticates before it decides whether a path exists, so telling `404`
        // from `401` requires sending credentials. Three concurrent candidates would therefore be
        // three concurrent logins, and a wrong password would spend up to six failed sign-ins in one
        // burst against a device that locks an account at about five. Rung 1 is also the right answer
        // for almost every current camera, so the common case is one round trip either way.
        var inFlight = 1
        var ledger = LadderAccounting(spent: max(0, min(credentialedAllowance, 1)))
        var outcome: StreamProbeOutcome?

        let firstWindow = await evaluate([first], camera: camera, credential: credential,
                                         allowance: ledger.spent)
        ledger.absorb(firstWindow)
        switch firstWindow.verdict {
        case let .decided(decided):
            outcome = decided
        case let .keepGoing(failure):
            lastFailure = failure
            // Phase 2's width **and** its allowance are licensed by the same single fact: rung 1's
            // credentialed request was answered with something other than a `401`. Nothing else
            // counts. Proof used to be inferred from the *shape* of an answer, which is unsound — a
            // `3xx` and a `404` answering the **uncredentialed** `OPTIONS` both arrive here as
            // `.rtspPathNotFound` with no credential involved anywhere (§2.6).
            if firstWindow.provesAuthentication {
                inFlight = Self.maxInFlight
                ledger.provenAllowance = RTSPAuthenticator.maxCredentialedFailures
            }
        }

        // Phase 2 — the rest of the ladder. Three in flight only once the device has answered a
        // question about the path rather than about the password, so first-frame latency is not the
        // sum of the failures. A rung that meets a `401` with an allowance of zero returns
        // `.authenticationRequired` **without sending anything**, which is the honest answer and
        // stops the ladder.
        var index = 1
        while outcome == nil, index < candidates.count {
            let end = min(index + inFlight, candidates.count)
            let window = await evaluate(Array(candidates[index..<end]),
                                        camera: camera,
                                        credential: credential,
                                        allowance: ledger.provenAllowance)
            ledger.absorb(window)
            switch window.verdict {
            case let .decided(decided):
                outcome = decided
            case let .keepGoing(failure):
                lastFailure = failure
                if window.provesAuthentication {
                    inFlight = Self.maxInFlight
                    ledger.provenAllowance = RTSPAuthenticator.maxCredentialedFailures
                }
            }
            index = end
        }

        let resolved = outcome ?? .exhausted(lastFailure)
        await settle(ledger, host: camera.host, account: credential?.account, outcome: resolved)
        return resolved
    }

    // MARK: Accounting

    /// What the ladder owes the governor when it finishes.
    private struct LadderAccounting {

        /// Strikes `resolvePath` debited for this sequence, `0` or `1`.
        var spent: Int

        /// The allowance rungs 2…5 may use. Zero until a rung proves the password.
        var provenAllowance = 0

        /// True once any rung has written an `Authorization` header.
        var sentCredentials = false

        /// True once a rung's credentialed request has been answered with something other than 401.
        var proved = false

        mutating func absorb(_ window: WindowOutcome) {
            sentCredentials = sentCredentials || window.sentCredentials
            proved = proved || window.provesAuthentication
        }
    }

    /// Settles the sequence with the governor. Two cases, and no others.
    ///
    /// **Proof** — a rung's credentialed request was answered with something other than a `401` —
    /// clears the whole key, because the device has just given better evidence than any fingerprint
    /// could. **Nothing sent** — no rung wrote an `Authorization` header — returns the strike, because
    /// the device's own tally cannot have moved.
    ///
    /// Everything else keeps the strike, including a timeout, a dropped socket and a malformed answer.
    /// That is the point of debiting up front: a device that rejected our credential and then closed
    /// the connection saw it perfectly well, and refunding because "the answer looked like a timeout"
    /// is precisely the mistake that made the shipped ladder unbounded.
    private func settle(_ accounting: LadderAccounting,
                        host: String,
                        account: String?,
                        outcome: StreamProbeOutcome) async {
        guard let account else { return }
        if case .authenticationRequired = outcome { return }
        if accounting.proved {
            await dependencies.governor.recordSuccess(host: host, account: account)
            return
        }
        guard !accounting.sentCredentials, accounting.spent > 0 else { return }
        await dependencies.governor.refund(host: host, account: account, count: accounting.spent)
    }

    // MARK: Windows

    /// What one window of candidates concluded.
    private enum WindowVerdict {
        /// The ladder is over, for better or worse.
        case decided(StreamProbeOutcome)
        /// Nothing in this window answered; carry on with the most diagnostic failure seen.
        case keepGoing(StreamError)
    }

    /// One window's verdict plus the two facts the governor needs.
    private struct WindowOutcome {

        var verdict: WindowVerdict

        /// True when at least one candidate's **credentialed** request was answered with something
        /// other than a `401`. It is what licenses the next window to run wide and to sign requests.
        var provesAuthentication: Bool

        /// True when at least one candidate wrote an `Authorization` header.
        var sentCredentials: Bool
    }

    /// Runs one window concurrently and folds its results into a verdict.
    ///
    /// - Parameter allowance: `RTSPSessionConfig.credentialedAttemptAllowance` for every session in
    ///   this window. Zero means "answer about the path, never about the password".
    private func evaluate(_ batch: [RTSPPathCandidate],
                          camera: Camera,
                          credential: Credential?,
                          allowance: Int) async -> WindowOutcome {
        let dependencies = dependencies
        let timeout = candidateTimeout

        let results = await withTaskGroup(of: (RTSPPathCandidate, ProbeReport).self) { group in
            for candidate in batch {
                group.addTask {
                    let url = camera.rtspURL(path: candidate.path)
                    var config = RTSPSessionConfig(url: url)
                    config.transport = .tcpInterleaved
                    config.setupAudio = false
                    config.setupMetadataTrack = false
                    config.credentialedAttemptAllowance = allowance
                    let session = dependencies.makeRTSPSession(config, credential,
                                                               "\(camera.id.short)-probe")
                    let probeRun = ProbeRun(session: session, logger: dependencies.logger)
                    let result = await withDeadline(timeout, clock: dependencies.clock) {
                        await probeRun.run()
                    }
                    // Read as statements, not folded into `||` / `&&`: those operators take
                    // autoclosures, which are neither `async` nor able to touch actor state, so the
                    // short-circuiting spelling does not compile.
                    let observedSend = await probeRun.didSendCredentials
                    let observedProof = await probeRun.didProveAuthentication
                    // A run the deadline killed is credited as having sent credentials whether or not
                    // it had got that far: the wire is no longer observable, and over-counting refuses
                    // a sign-in while under-counting locks an account.
                    let sent = result == nil ? true : observedSend
                    let proved = result == nil ? false : observedProof
                    let outcome = result ?? .advance(StreamError(code: .describeTimeout))
                    // The winning rung drove a real session all the way to `PLAY`, and `close()`
                    // only flushes what is already queued — it does not tear the session down. So
                    // without this the camera holds that session slot for its whole timeout while
                    // `StreamController` is already opening the next one for the same channel.
                    // `StreamController.teardown()` does exactly this, for exactly this reason.
                    if case .success = outcome { await session.perform(.teardown) }
                    await session.close()
                    return (candidate, ProbeReport(result: outcome,
                                                   sentCredentials: sent,
                                                   provesAuthentication: proved))
                }
            }
            var out: [(RTSPPathCandidate, ProbeReport)] = []
            for await result in group {
                out.append(result)
                // §2.6, last line. The moment one child reports a credentialed rejection the others
                // must not be allowed to write theirs. Draining all three before reading any verdict
                // is how the shipped code put six credentialed `401`s on the wire in one burst.
                if case .authenticationRequired = result.1.result { group.cancelAll() }
            }
            return out
        }

        let sentCredentials = results.contains { $0.1.sentCredentials }
        let proved = results.contains { $0.1.provesAuthentication }
        var lastFailure = StreamError(code: .rtspPathNotFound)
        // Lowest rung first, so a device that answers on two forms is remembered by the one the
        // ladder trusts more — not by whichever socket happened to be quicker.
        for (candidate, report) in results.sorted(by: { $0.0.order < $1.0.order }) {
            switch report.result {
            case let .success(codec):
                dependencies.logger.info(.core, "rtsp path resolved",
                                         ["path": Redact.path(candidate.path),
                                          "codec": codec?.rawValue ?? "unknown"])
                return WindowOutcome(verdict: .decided(.resolved(candidate, videoCodec: codec)),
                                     provesAuthentication: proved,
                                     sentCredentials: sentCredentials)
            case let .authenticationRequired(error):
                dependencies.logger.notice(.core, "rtsp path answered 401; ladder stopped",
                                           ["path": Redact.path(candidate.path)])
                return WindowOutcome(verdict: .decided(.authenticationRequired(candidate, error)),
                                     provesAuthentication: proved,
                                     sentCredentials: sentCredentials)
            case let .advance(error):
                lastFailure = error
            case let .abort(error):
                // A refused port or an unreachable host fails identically for every candidate;
                // spending four more connects on it only delays the real diagnosis.
                dependencies.logger.notice(.core, "ladder aborted; failure is not path-shaped",
                                           ["code": error.code.rawValue])
                return WindowOutcome(verdict: .decided(.exhausted(error)),
                                     provesAuthentication: proved,
                                     sentCredentials: sentCredentials)
            }
        }
        return WindowOutcome(verdict: .keepGoing(lastFailure),
                             provesAuthentication: proved,
                             sentCredentials: sentCredentials)
    }
}

// MARK: - ProbeResult

/// What one candidate's `DESCRIBE` produced.
enum ProbeResult: Sendable {
    /// A parseable SDP with a video codec Vigil can decode.
    case success(VideoCodec?)
    /// This path is wrong; try the next rung.
    case advance(StreamError)
    /// The path is right and the credentials are not. Stops the ladder.
    case authenticationRequired(StreamError)
    /// Nothing about the path is at fault — the socket, the host or the network is. Stops the
    /// ladder, because every other candidate would fail the same way.
    case abort(StreamError)
}

// MARK: - ProbeReport

/// One candidate's result together with what its session did with the credential.
///
/// The second and third fields are the whole of §2.6's correction to `provesAuthentication`. That
/// property used to be derived from the *shape* of the answer — `404` and a redirect were read as
/// proof of a successful sign-in — and it was unsound in both directions: `ProbeRun` manufactures
/// `.rtspPathNotFound` from a `3xx`, and the session machine produces the same code in answer to the
/// **uncredentialed** `OPTIONS`. Proof is now a fact one session observed, not an inference.
struct ProbeReport: Sendable {

    /// The ladder decision.
    var result: ProbeResult

    /// Whether an `Authorization` header was written on this session.
    var sentCredentials: Bool

    /// Whether a credentialed request was answered with something other than a `401`.
    var provesAuthentication: Bool
}

// MARK: - ProbeRun

/// One session against one candidate URL, run only as far as it takes to know whether the path is
/// the right one.
///
/// **Deviation, and the reason for it.** `RTSPSessionMachine` has a probe primitive —
/// `RTSPCommand.describeOnly`, which sends `DESCRIBE` alone and closes as soon as the SDP parses —
/// and this is what it exists for. The landed `VigilTransport.RTSPConnection` issues `.start`
/// itself the moment the socket is ready (it must: `transportReady` sends nothing, .vigil/STEP3.md
/// §3.1 finding 1), so by the time this actor could ask for `describeOnly` the machine is already
/// running the full `OPTIONS → DESCRIBE → SETUP → PLAY` sequence and the command would only add a
/// second `DESCRIBE`. This run therefore listens rather than commands, and treats `.ready` — an
/// actual successful `PLAY` — as proof the path works.
///
/// The cost is one extra session on the **winning** candidate only: every losing rung is refused at
/// `DESCRIBE`, before `SETUP`. If a probe mode reaches `RTSPConnection`, this becomes
/// `perform(.describeOnly)` and the `.ready` case goes away.
actor ProbeRun {

    private let session: any RTSPSessionDriving
    private let logger: any LoggerProtocol

    /// Whether this session has written an `Authorization` header.
    ///
    /// Read from the session's own state stream: `RTSPSessionState.authenticating(retryOf:)` is
    /// entered by `RTSPSessionMachine` exactly when it re-sends a request carrying credentials, so
    /// observing it is equivalent to observing the header on the wire — and it is the only signal
    /// available without a new `RTSPConnectionEvent` case, which lives in a module this change does
    /// not own (see the report's list of what a supervisor still owes).
    private(set) var didSendCredentials = false

    /// Whether a credentialed request has been answered with something other than a `401`.
    ///
    /// Set by any progress the device could only have made **after** accepting the credential: a
    /// later state in the connect sequence, a negotiated track, a successful `PLAY`, or a close whose
    /// reason means the device answered a `DESCRIBE` (`.ladderAdvance` is a `404` family answer,
    /// `.redirect` a `3xx`, `.normal` a parsed SDP). A timeout, a dropped socket and a `401` all
    /// leave it false, because none of them is an answer.
    private(set) var didProveAuthentication = false

    init(session: any RTSPSessionDriving, logger: any LoggerProtocol) {
        self.session = session
        self.logger = logger
    }

    /// Connects and reports what the device said about this path.
    func run() async -> ProbeResult {
        let stream = await session.events()
        do {
            try await session.connect()
        } catch {
            return .abort(StreamError.from(anyError: error))
        }

        var videoCodec: VideoCodec?
        var sawVideoTrack = false

        for await event in stream {
            switch event {
            case let .state(sessionState):
                note(sessionState)
            case let .track(track):
                noteAnswer()
                if track.kind == .video, let codec = track.codec?.video {
                    sawVideoTrack = true
                    videoCodec = codec
                }
            case let .ready(description):
                // `PLAY` succeeded: the strongest possible answer to "is this the path?".
                noteAnswer()
                let codec = description.tracks
                    .first { $0.kind == .video }?
                    .codec?
                    .video
                return .success(codec ?? videoCodec)
            case let .closed(reason):
                switch reason {
                case .normal:
                    noteAnswer()
                    return sawVideoTrack
                        ? .success(videoCodec)
                        : .advance(StreamError(code: .unsupportedMedia))
                case .ladderAdvance:
                    // A `404`-family answer to `DESCRIBE`. The device answered, so if we had signed
                    // the request it accepted the credential.
                    noteAnswer()
                    return .advance(StreamError(code: .rtspPathNotFound, rtspStatus: 404))
                case .redirect:
                    // Following a redirect would need a second connection for a path we are only
                    // testing; treat it as "this rung did not answer" — but the `3xx` itself is an
                    // answer, so it still proves the credential if we sent one.
                    noteAnswer()
                    return .advance(StreamError(code: .rtspPathNotFound))
                case .error:
                    continue
                }
            case let .failed(error):
                return Self.classify(error)
            case .timing:
                noteAnswer()
            case .media, .reconnect:
                continue
            }
        }
        return .advance(StreamError(code: .connectionClosed))
    }

    /// Folds one session state into the two credential facts.
    private func note(_ sessionState: RTSPSessionState) {
        switch sessionState {
        case .authenticating:
            didSendCredentials = true
        case .awaitingDescribe, .settingUp, .awaitingPlay, .playing, .awaitingPause, .paused,
             .seeking, .tearingDown:
            // Reached only by a response the device actually sent. `.awaitingDescribe` in particular
            // is entered on a successful `OPTIONS`, which is the first thing a credentialed retry
            // gets right.
            noteAnswer()
        case .awaitingOptions, .idle, .closed, .failed:
            // `.awaitingOptions` is entered by `.start` before a byte is written, so it is not an
            // answer to anything; `.failed` is the one state that is explicitly *not* proof.
            break
        }
    }

    /// Records that the device answered something. Only meaningful once credentials went out.
    private func noteAnswer() {
        guard didSendCredentials else { return }
        didProveAuthentication = true
    }

    /// Maps a terminal failure onto a ladder decision.
    ///
    /// The `401` family is the one that must not advance: `.authRejected` and `.unauthorized` mean
    /// the device answered our credentials with another challenge — or that this rung had no
    /// allowance left and refused to sign anything, which is the same verdict for the ladder's
    /// purposes — and `.credentialsMissing` means it challenged us and we had nothing to answer
    /// with. All of them say the path is right.
    static func classify(_ error: VigilError) -> ProbeResult {
        guard case let .rtsp(rtsp) = error else {
            return .abort(StreamError.from(vigil: error))
        }
        switch rtsp {
        case .authRejected, .unauthorized, .credentialsMissing:
            return .authenticationRequired(StreamError.from(rtsp))
        case .pathNotFound, .noSuitableTrack, .sdpParse:
            return .advance(StreamError.from(rtsp))
        case .timeout:
            return .advance(StreamError(code: .describeTimeout))
        case .accessForbidden:
            // 403 is about the account, not the path. Four more paths would spend time and tell
            // the user nothing new.
            return .abort(StreamError.from(rtsp))
        default:
            return .advance(StreamError.from(rtsp))
        }
    }
}

#endif
