//
//  StreamProbe.swift
//  VigilCore
//
//  The R1.2 path ladder: probe the known Hikvision RTSP paths and keep the winner. The user is
//  never asked for a stream URL.
//  Implements docs/REQUIREMENTS-CUSTOMER.md §R1.2 and docs/API_CONTRACT.md §4.8 (`StreamProbe`).
//
//  Three rules decide everything in this file:
//
//  * `200` with a parseable SDP carrying a video codec Vigil can decode **wins**.
//  * `404`/`451`/`455`/`460` **advance** to the next candidate.
//  * `401` does **not** advance. The path is right and the credentials need applying — and, because
//    two credentialed 401s per device are terminal (API_CONTRACT §2 R-25), a `401` stops the entire
//    ladder rather than repeating itself against four more paths. Walking the ladder after a
//    rejected password is how an app locks its user out of their own camera.
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
    ///   - dependencies: clock, logger, randomness and the session factory.
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
    /// Prefer `probe(camera:credential:quality:)`, which distinguishes "no path answered" from "the
    /// path is right and the password is wrong" — a distinction the UI must make, because one leads
    /// to Stream Doctor and the other to a password field.
    public func findWorkingPath(camera: Camera,
                                credential: Credential?,
                                quality: StreamQuality) async -> RTSPPathCandidate? {
        switch await probe(camera: camera, credential: credential, quality: quality) {
        case let .resolved(candidate, _): candidate
        case let .authenticationRequired(candidate, _): candidate
        case .exhausted: nil
        }
    }

    /// Walks the ladder for one camera.
    ///
    /// An explicit `rtspPathOverride` short-circuits the whole thing: a path the user typed is
    /// honoured, not tested against alternatives.
    public func probe(camera: Camera,
                      credential: Credential?,
                      quality: StreamQuality) async -> StreamProbeOutcome {
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

        // Phase 1 — the first rung runs **alone**, however many run afterwards.
        //
        // This is an authentication-safety rule, not a performance one. Hikvision firmware
        // authenticates before it decides whether a path exists, so telling `404` from `401`
        // requires sending credentials; three concurrent candidates would therefore be three
        // concurrent logins, and a wrong password would spend up to six failed sign-ins in one
        // burst against a device that locks an account at about five (API_CONTRACT §2 R-25). One
        // at a time until the device has answered something other than a `401` keeps the worst
        // case at exactly the two attempts the contract budgets. Rung 1 is also the right answer
        // for almost every current camera, so the common case is one round trip either way.
        // How many candidates may run at once. **One until a rung has proved the credentials.**
        // A rung that answers `404`, redirects, or offers an SDP we cannot use has authenticated
        // first — Hikvision firmware authenticates before it decides whether a path exists — so
        // after one of those the password is known good and R1.2's three-in-flight window is free.
        // A rung that merely *timed out* or dropped the connection proves nothing, and widening on
        // one of those would put three concurrent logins on the wire with a password that may still
        // be wrong: six failed sign-ins in one burst against a device that locks at about five.
        var inFlight = 1

        switch await evaluate([first], camera: camera, credential: credential) {
        case let .decided(outcome): return outcome
        case let .keepGoing(failure, proved):
            lastFailure = failure
            if proved { inFlight = Self.maxInFlight }
        }

        // Phase 2 — the rest of the ladder, three in flight per R1.2 once and only once the device
        // has answered a question about the path rather than about the password, so first-frame
        // latency is not the sum of the failures.
        var index = 1
        while index < candidates.count {
            let end = min(index + inFlight, candidates.count)
            switch await evaluate(Array(candidates[index..<end]),
                                  camera: camera,
                                  credential: credential) {
            case let .decided(outcome): return outcome
            case let .keepGoing(failure, proved):
                lastFailure = failure
                if proved { inFlight = Self.maxInFlight }
            }
            index = end
        }
        return .exhausted(lastFailure)
    }

    // MARK: Windows

    /// What one window of candidates concluded.
    private enum WindowVerdict {
        /// The ladder is over, for better or worse.
        case decided(StreamProbeOutcome)
        /// Nothing in this window answered; carry on with the most diagnostic failure seen.
        ///
        /// `provedAuthentication` is true when at least one candidate's answer could only have come
        /// **after** a successful sign-in. It is what licenses the next window to run wide.
        case keepGoing(StreamError, provedAuthentication: Bool)
    }

    /// Runs one window concurrently and folds its results into a verdict.
    private func evaluate(_ batch: [RTSPPathCandidate],
                          camera: Camera,
                          credential: Credential?) async -> WindowVerdict {
        let dependencies = dependencies
        let timeout = candidateTimeout

        let results = await withTaskGroup(of: (RTSPPathCandidate, ProbeResult).self) { group in
            for candidate in batch {
                group.addTask {
                    let url = camera.rtspURL(path: candidate.path)
                    var config = RTSPSessionConfig(url: url)
                    config.transport = .tcpInterleaved
                    config.setupAudio = false
                    config.setupMetadataTrack = false
                    let session = dependencies.makeRTSPSession(config, credential,
                                                               "\(camera.id.short)-probe")
                    let probeRun = ProbeRun(session: session, logger: dependencies.logger)
                    let result = await withDeadline(timeout, clock: dependencies.clock) {
                        await probeRun.run()
                    }
                    let outcome = result ?? .advance(StreamError(code: .describeTimeout))
                    // The winning rung drove a real session all the way to `PLAY`, and `close()`
                    // only flushes what is already queued — it does not tear the session down. So
                    // without this the camera holds that session slot for its whole timeout while
                    // `StreamController` is already opening the next one for the same channel.
                    // `StreamController.teardown()` does exactly this, for exactly this reason.
                    if case .success = outcome { await session.perform(.teardown) }
                    await session.close()
                    return (candidate, outcome)
                }
            }
            var out: [(RTSPPathCandidate, ProbeResult)] = []
            for await result in group { out.append(result) }
            return out
        }

        var lastFailure = StreamError(code: .rtspPathNotFound)
        // Lowest rung first, so a device that answers on two forms is remembered by the one the
        // ladder trusts more — not by whichever socket happened to be quicker.
        for (candidate, result) in results.sorted(by: { $0.0.order < $1.0.order }) {
            switch result {
            case let .success(codec):
                dependencies.logger.info(.core, "rtsp path resolved",
                                         ["path": Redact.path(candidate.path),
                                          "codec": codec?.rawValue ?? "unknown"])
                return .decided(.resolved(candidate, videoCodec: codec))
            case let .authenticationRequired(error):
                dependencies.logger.notice(.core, "rtsp path answered 401; ladder stopped",
                                           ["path": Redact.path(candidate.path)])
                return .decided(.authenticationRequired(candidate, error))
            case let .advance(error):
                lastFailure = error
            case let .abort(error):
                // A refused port or an unreachable host fails identically for every candidate;
                // spending four more connects on it only delays the real diagnosis.
                dependencies.logger.notice(.core, "ladder aborted; failure is not path-shaped",
                                           ["code": error.code.rawValue])
                return .decided(.exhausted(error))
            }
        }
        return .keepGoing(lastFailure,
                          provedAuthentication: results.contains { $0.1.provesAuthentication })
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

extension ProbeResult {

    /// True when this answer could only have come **after** the device accepted the credential.
    ///
    /// Hikvision firmware authenticates before it decides whether a path exists, so `404`, a
    /// redirect, and an SDP whose tracks Vigil cannot use are all proof that the password is right.
    /// A timeout, a dropped connection or a protocol error prove nothing — and treating them as
    /// proof is what would let the ladder widen to three concurrent logins with a wrong password.
    var provesAuthentication: Bool {
        switch self {
        case .success:
            true
        case let .advance(error):
            error.code == .rtspPathNotFound || error.code == .unsupportedMedia
        case .authenticationRequired, .abort:
            false
        }
    }
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
            case let .track(track):
                if track.kind == .video, let codec = track.codec?.video {
                    sawVideoTrack = true
                    videoCodec = codec
                }
            case let .ready(description):
                // `PLAY` succeeded: the strongest possible answer to "is this the path?".
                let codec = description.tracks
                    .first { $0.kind == .video }?
                    .codec?
                    .video
                return .success(codec ?? videoCodec)
            case let .closed(reason):
                switch reason {
                case .normal:
                    return sawVideoTrack
                        ? .success(videoCodec)
                        : .advance(StreamError(code: .unsupportedMedia))
                case .ladderAdvance:
                    return .advance(StreamError(code: .rtspPathNotFound, rtspStatus: 404))
                case .redirect:
                    // Following a redirect would need a second connection for a path we are only
                    // testing; treat it as "this rung did not answer".
                    return .advance(StreamError(code: .rtspPathNotFound))
                case .error:
                    continue
                }
            case let .failed(error):
                return Self.classify(error)
            case .state, .timing, .media, .reconnect:
                continue
            }
        }
        return .advance(StreamError(code: .connectionClosed))
    }

    /// Maps a terminal failure onto a ladder decision.
    ///
    /// The `401` family is the one that must not advance: `.authRejected` and `.unauthorized` mean
    /// the device answered our credentials with another challenge, and `.credentialsMissing` means
    /// it challenged us and we had nothing to answer with. Both say the path is right.
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
