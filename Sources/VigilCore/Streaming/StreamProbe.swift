//
//  StreamProbe.swift
//  VigilCore
//
//  The R1.2 path ladder: probe the known Hikvision RTSP paths, three at a time, and keep the
//  winner. The user is never asked for a stream URL.
//  Implements docs/REQUIREMENTS-CUSTOMER.md §R1.2 and docs/API_CONTRACT.md §4.8 (`StreamProbe`).
//
//  Three rules decide everything in this file:
//
//  * `200` with a parseable SDP carrying a video codec Vigil can decode **wins**.
//  * `404`/`451`/`455`/`460` **advance** to the next candidate.
//  * `401` does **not** advance. The path is right and the credentials need applying — and, because
//    two credentialed 401s per device are terminal (API_CONTRACT §2 R-25), a 401 stops the entire
//    ladder rather than repeating itself against four more paths. Walking the ladder after a
//    rejected password is how an app locks its user out of their own camera.
//

#if os(macOS)

import Foundation
import VigilProtocols
import VigilRTSP

// MARK: - Outcome

/// What the ladder concluded.
public enum StreamProbeOutcome: Sendable {

    /// A candidate answered with a usable SDP. Persist `candidate` on the camera record.
    case resolved(RTSPPathCandidate, videoCodec: VideoCodec?)

    /// A candidate answered `401`. The path is right; the credentials are missing or wrong. The
    /// ladder stopped here on purpose — no further candidate was tried.
    case authenticationRequired(RTSPPathCandidate, StreamError)

    /// Every candidate was tried and none answered. Carries the most diagnostic failure seen.
    case exhausted(StreamError)
}

// MARK: - StreamProbe

/// Finds the RTSP path a device actually answers on.
///
/// One instance can serve many cameras; it holds no per-camera state. Candidates run **three in
/// flight** so first-frame latency is not the sum of the failures, and within a window the
/// lowest-numbered rung that succeeds wins regardless of which answered first — the ladder's order
/// encodes which form is most likely to be canonical for the firmware.
public actor StreamProbe {

    // MARK: Configuration

    /// Candidates in flight at once. Three, from R1.2.
    public static let maxInFlight = 3

    private let makeTransport: RTSPTransportFactory
    private let clock: any MonotonicClock
    private let random: any RandomSource
    private let logger: any LoggerProtocol
    private let candidateTimeout: Duration

    /// Builds a probe.
    ///
    /// - Parameters:
    ///   - makeTransport: how to obtain a socket for one candidate URL.
    ///   - clock: drives the per-candidate deadline.
    ///   - random: the Digest `cnonce` source, seeded in tests.
    ///   - logger: structured log sink.
    ///   - candidateTimeout: how long one candidate may take from connect to SDP. Four seconds:
    ///     long enough for a busy NVR on Wi-Fi, short enough that five rungs cannot exceed the
    ///     ten-second first-frame budget of R1.7 when they run three at a time.
    public init(makeTransport: @escaping RTSPTransportFactory,
                clock: any MonotonicClock,
                random: any RandomSource = SystemRandomSource(),
                logger: any LoggerProtocol = NullLogger(),
                candidateTimeout: Duration = .seconds(4)) {
        self.makeTransport = makeTransport
        self.clock = clock
        self.random = random
        self.logger = logger
        self.candidateTimeout = candidateTimeout
    }

    // MARK: API

    /// The contract's entry point: the winning candidate, or `nil` when the ladder found nothing.
    ///
    /// Prefer `probe(camera:credential:quality:)`, which distinguishes "no path answered" from
    /// "the path is right and the password is wrong" — a distinction the UI must make, because one
    /// leads to Stream Doctor and the other to a password field.
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
            logger.info(.core, "path override in force; ladder skipped",
                        ["path": Redact.path(candidate.path)])
            return .resolved(candidate, videoCodec: camera.capabilities?.videoCodec)
        }

        let candidates = RTSPPathCandidate.ladder(channel: camera.channel,
                                                  quality: quality,
                                                  preferring: camera.capabilities?
                                                      .rtspPathTemplate)
        guard !candidates.isEmpty else {
            return .exhausted(StreamError(code: .rtspPathNotFound))
        }

        var lastFailure = StreamError(code: .rtspPathNotFound)
        var window = 0
        while window * Self.maxInFlight < candidates.count {
            let start = window * Self.maxInFlight
            let end = min(start + Self.maxInFlight, candidates.count)
            let batch = Array(candidates[start..<end])
            let results = await run(batch, camera: camera, credential: credential)

            // Lowest rung first, so a device that answers on two forms is remembered by the one
            // the ladder trusts more.
            for (candidate, result) in results.sorted(by: { $0.0.order < $1.0.order }) {
                switch result {
                case let .success(codec):
                    logger.info(.core, "rtsp path resolved",
                                ["path": Redact.path(candidate.path),
                                 "codec": codec?.rawValue ?? "unknown"])
                    return .resolved(candidate, videoCodec: codec)
                case let .authenticationRequired(error):
                    logger.notice(.core, "rtsp path answered 401; ladder stopped",
                                  ["path": Redact.path(candidate.path)])
                    return .authenticationRequired(candidate, error)
                case let .advance(error):
                    lastFailure = error
                case let .abort(error):
                    // A refused port or an unreachable host fails identically for every candidate;
                    // spending four more connects on it only delays the real diagnosis.
                    logger.notice(.core, "ladder aborted; the failure is not path-shaped",
                                  ["code": error.code.rawValue])
                    return .exhausted(error)
                }
            }
            window += 1
        }
        return .exhausted(lastFailure)
    }

    // MARK: Batch execution

    /// Runs one window of candidates concurrently and collects every result.
    private func run(_ batch: [RTSPPathCandidate],
                     camera: Camera,
                     credential: Credential?) async
        -> [(RTSPPathCandidate, ProbeResult)] {
        let makeTransport = makeTransport
        let clock = clock
        let random = random
        let logger = logger
        let timeout = candidateTimeout

        return await withTaskGroup(of: (RTSPPathCandidate, ProbeResult).self) { group in
            for candidate in batch {
                group.addTask {
                    let url = camera.rtspURL(path: candidate.path)
                    let session = ProbeSession(url: url,
                                               credential: credential,
                                               transport: makeTransport(url),
                                               clock: clock,
                                               random: random,
                                               logger: logger)
                    let result = await withDeadline(timeout, clock: clock) {
                        await session.run()
                    }
                    await session.close()
                    return (candidate, result ?? .advance(StreamError(code: .describeTimeout)))
                }
            }
            var out: [(RTSPPathCandidate, ProbeResult)] = []
            for await result in group { out.append(result) }
            return out
        }
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

// MARK: - ProbeSession

/// Drives one `DESCRIBE`-only session against one candidate URL.
///
/// A deliberately reduced driver: it executes `.send`, watches for tracks, and classifies the
/// terminal action. It ignores `.setTimer`, because the caller's deadline already bounds the whole
/// candidate and a probe has no keepalive, no media and no session to expire.
actor ProbeSession {

    private let url: RTSPURL
    private let credential: Credential?
    private let transport: any RTSPTransport
    private let clock: any MonotonicClock
    private let random: any RandomSource
    private let logger: any LoggerProtocol

    private var machine: RTSPSessionMachine?
    private var readTask: Task<Void, Never>?
    private let signal = SessionSignal<ProbeResult>()
    private var videoCodec: VideoCodec?
    private var sawVideoTrack = false
    private var isClosed = false

    init(url: RTSPURL,
         credential: Credential?,
         transport: any RTSPTransport,
         clock: any MonotonicClock,
         random: any RandomSource,
         logger: any LoggerProtocol) {
        self.url = url
        self.credential = credential
        self.transport = transport
        self.clock = clock
        self.random = random
        self.logger = logger
    }

    /// Connects, sends `DESCRIBE`, and reports what came back.
    func run() async -> ProbeResult {
        do {
            try await transport.connect()
        } catch {
            return .abort(Self.mapTransportFailure(error))
        }

        var config = RTSPSessionConfig(url: url)
        config.setupAudio = false
        config.setupMetadataTrack = false
        let isTLS = await transport.isTLS
        var built = RTSPSessionMachine(config: config, credential: credential,
                                       random: random, now: clock.now())

        // `transportReady` only resets nonce state and returns **no actions**: nothing reaches the
        // wire until a command is handled. A driver that connects and then waits stalls forever
        // with no error at all (.vigil/STEP3.md §3.1, finding 1).
        var actions = built.transportReady(isTLS: isTLS, now: clock.now())
        actions += built.handle(.describeOnly, now: clock.now())
        machine = built

        startReading()
        await execute(actions)

        return await signal.wait { ProbeResult.advance(StreamError(code: .describeTimeout)) }
    }

    /// Closes the socket and stops the read pump. Idempotent.
    func close() async {
        guard !isClosed else { return }
        isClosed = true
        readTask?.cancel()
        readTask = nil
        await transport.close()
    }

    // MARK: Pumping

    private func startReading() {
        let transport = transport
        readTask = Task { [weak self] in
            let stream = await transport.bytes()
            do {
                for try await chunk in stream {
                    await self?.ingest(chunk)
                }
                await self?.transportEnded(error: nil)
            } catch {
                await self?.transportEnded(error: error)
            }
        }
    }

    private func ingest(_ bytes: Data) async {
        guard var machine else { return }
        let actions = machine.ingest(bytes, now: clock.now())
        self.machine = machine
        await execute(actions)
    }

    private func transportEnded(error: (any Error)?) async {
        guard var machine else {
            await signal.send(.advance(StreamError(code: .connectionClosed)))
            return
        }
        let actions = machine.connectionClosed(error: error?.localizedDescription,
                                               now: clock.now())
        self.machine = machine
        await execute(actions)
        // A close with no terminal action — a peer that hung up mid-DESCRIBE — still has to end
        // the probe, or the caller waits out its whole deadline for nothing.
        await signal.send(.advance(StreamError(code: .connectionClosed)))
    }

    // MARK: Actions

    private func execute(_ actions: [RTSPAction]) async {
        for action in actions {
            switch action {
            case let .send(data):
                do {
                    try await transport.write(data)
                } catch {
                    await signal.send(.abort(Self.mapTransportFailure(error)))
                }

            case let .emitTrack(track):
                if track.kind == .video, let codec = track.codec?.video {
                    sawVideoTrack = true
                    videoCodec = codec
                }

            case let .closeTransport(reason):
                switch reason {
                case .normal:
                    await signal.send(sawVideoTrack
                        ? .success(videoCodec)
                        : .advance(StreamError(code: .unsupportedMedia)))
                case .ladderAdvance:
                    await signal.send(.advance(StreamError(code: .rtspPathNotFound,
                                                           rtspStatus: 404)))
                case .redirect:
                    // Following a redirect inside the probe would need a second connection for a
                    // path we are only testing; treat it as "this rung did not answer".
                    await signal.send(.advance(StreamError(code: .rtspPathNotFound)))
                case .error:
                    break
                }

            case let .fail(error):
                await signal.send(Self.classify(error))

            case let .log(event):
                logger.debug(.rtsp, "probe \(event)")

            case .setTimer, .cancelTimer, .emitTiming, .emitMedia, .ready, .stateChanged,
                 .setReadBackpressure, .sendInterleaved, .reconnect:
                continue
            }
        }
    }

    // MARK: Classification

    /// Maps the machine's terminal error onto a ladder decision.
    ///
    /// The `401` family is the one that must not advance: `.authRejected` and `.unauthorized` mean
    /// the device answered our credentials with another challenge, and `.credentialsMissing` means
    /// it challenged us and we had nothing to answer with. Both say the path is right.
    static func classify(_ error: RTSPError) -> ProbeResult {
        switch error {
        case .authRejected, .unauthorized, .credentialsMissing:
            .authenticationRequired(StreamError.from(error))
        case .pathNotFound, .noSuitableTrack, .sdpParse:
            .advance(StreamError.from(error))
        case .timeout:
            .advance(StreamError(code: .describeTimeout))
        case .accessForbidden:
            // 403 is about the account, not the path. Trying four more paths would spend nothing
            // but time and would tell the user nothing new.
            .abort(StreamError.from(error))
        default:
            .advance(StreamError.from(error))
        }
    }

    /// Maps a thrown transport failure. The protocol's `throws` is untyped so that a test double
    /// can throw anything; a `TransportError` keeps its meaning and everything else becomes a
    /// generic transport failure rather than being swallowed.
    static func mapTransportFailure(_ error: any Error) -> StreamError {
        if let transport = error as? TransportError {
            return StreamError.from(transport)
        }
        if error is CancellationError {
            return StreamError(code: .connectTimeout)
        }
        return StreamError(code: .transportError,
                           underlyingDescription: String(describing: type(of: error)))
    }
}

#endif
