//
//  RTSPSessionDriving.swift
//  VigilCore
//
//  The seam between `StreamController` and one RTSP session on one socket.
//  Declared here per docs/API_CONTRACT.md §2 R-66 ("`RTSPTransport` — declared, §4.8"), and named
//  for what the landed transport actually is.
//
//  **Ownership deviation, recorded deliberately.** API_CONTRACT §4.7's `RTSPConnection` exposes
//  `bytes() -> AsyncThrowingStream<Data, any Error>` — a byte pipe with `RTSPSessionMachine` driven
//  from `VigilCore`, which is also what spec-core §7.9's composition diagram shows. The landed
//  `VigilTransport.RTSPConnection` instead owns the machine and its timers (its own §5.9 brief
//  gives it `Deps: RTSPSessionMachine`, and .vigil/STEP3.md §3.1 requires it to issue `.start`
//  itself), so what crosses this boundary is the machine's **output**, already parsed. Driving a
//  second machine here over a byte pipe would put the framing decision in two places.
//
//  This protocol therefore mirrors `RTSPConnection`'s surface. `VigilCore` keeps what it can only
//  do here — the credential, the R1.2 path ladder, the lockout gate, reconnection, RTP receivers
//  and the frame path — and delegates protocol mechanics downwards.
//

#if os(macOS)

import Foundation
import VigilProtocols
import VigilRTSP
import VigilTransport

// MARK: - RTSPSessionDriving

/// One RTSP session, driven to `PLAY` and reported through an event stream.
///
/// `VigilTransport.RTSPConnection` is the production conformer (see
/// `Platform/CoreDependencies.swift`); a test double is an actor that yields a scripted event
/// sequence, which is what makes the controller's connect, authentication and reconnect behaviour
/// testable without a socket.
///
/// **Event ordering is normative** (docs/spec-rtsp.md §14.6) and conformers must preserve it:
/// `.state` precedes what the new state causes, each `.track` precedes that track's `.timing`,
/// which precedes any `.media` on its channels, `.ready` is emitted once per successful `PLAY`,
/// and `.failed` is last.
public protocol RTSPSessionDriving: Sendable {

    /// Opens the socket and starts the session. Returns once `OPTIONS` is on its way out; every
    /// later step arrives on `events()`.
    func connect() async throws

    /// A fresh event stream. Call **once** per session: the landed implementation is
    /// single-consumer and a second call finishes the first stream.
    func events() async -> AsyncStream<RTSPConnectionEvent>

    /// Hands one control instruction to the session. Ignored once the session is closing.
    func perform(_ command: RTSPCommand) async

    /// Sends one RTCP compound packet back to the camera, framed as `$` on `channel`.
    ///
    /// Not optional politeness: a TCP-interleaved client that never sends receiver reports is
    /// dropped by the camera about forty seconds in, with a failure that looks exactly like a wrong
    /// password (.vigil/STEP3.md §3.1, finding 2). `channel` is the odd half of the track's
    /// interleaved pair.
    func sendRTCP(_ payload: Data, channel: UInt8) async

    /// Stops asking the socket for more bytes, so TCP back-pressure builds.
    func pauseReads() async

    /// Resumes reading.
    func resumeReads() async

    /// Closes the session and ends the event stream. Idempotent, never throws, safe from a
    /// cancelled task.
    func close() async

    /// Whether this session is TLS. Always `false` in the first-light slice.
    var isTLS: Bool { get async }
}

// MARK: - Factory

/// How a controller obtains a session for one configured target.
///
/// A closure rather than a protocol so the app target supplies the one line that knows
/// `RTSPConnection`'s initialiser, and `VigilCore` never has to be edited when that initialiser
/// changes. The credential is passed per session and never captured by the factory.
public typealias RTSPSessionFactory =
    @Sendable (RTSPSessionConfig, Credential?, String) -> any RTSPSessionDriving

#endif
