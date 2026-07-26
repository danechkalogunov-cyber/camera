//
//  RTSPTransport.swift
//  VigilCore
//
//  The byte-level seam between `StreamController` and a socket. Bytes in, bytes out, and nothing
//  else: every RTSP decision is the pure `RTSPSessionMachine`'s.
//  Declared here per docs/API_CONTRACT.md §2 R-66 ("`RTSPTransport` — declared, §4.8") and used by
//  docs/spec-core.md §7.9's composition diagram.
//

#if os(macOS)

import Foundation
import VigilProtocols
import VigilRTSP

// MARK: - RTSPTransport

/// One connection's worth of bytes.
///
/// Deliberately narrow. `VigilTransport.RTSPConnection` (API_CONTRACT §4.7) is the production
/// implementation and owns the `NWConnection`, its queue and its cancellation; a test double is
/// four methods over an `AsyncStream`, which is what makes the controller's connect sequence
/// testable without a socket.
///
/// **Ordering contract.** Every `write` is one atomic write and writes complete in call order —
/// `StreamController` serialises them through one drain task, because an RTSP request split across
/// two TCP segments interleaved with another request is a session-ending framing error.
///
/// **Read contract.** `bytes()` yields whatever arrived, in arrival order, with no framing applied.
/// A zero-length delivery is legal and must be forwarded rather than treated as end of stream. The
/// stream finishes on a clean FIN and throws on anything else, so the driver can tell a `TEARDOWN`
/// that completed from a camera that rebooted.
public protocol RTSPTransport: Sendable {

    /// Opens the connection. Returns once the peer is ready to accept a request.
    ///
    /// - Throws: `TransportError`, which the controller maps onto `StreamError` — a refused port
    ///   and a timed-out connect lead to opposite decisions, so the distinction must survive.
    func connect() async throws

    /// Writes one frame of bytes as a single atomic write.
    func write(_ data: Data) async throws

    /// The inbound byte stream. Called once per connection; a second call may return an empty
    /// stream, so the driver must keep the first.
    func bytes() async -> AsyncThrowingStream<Data, any Error>

    /// Stops reading from the socket, letting TCP back-pressure build. Used only by
    /// `Rate-Control: no` playback, which has no flow control of its own.
    func pauseReads() async

    /// Resumes reading after `pauseReads()`.
    func resumeReads() async

    /// Closes the connection. Idempotent, never throws, and safe to call from a cancelled task —
    /// teardown must not depend on the happy path.
    func close() async

    /// Whether this connection is TLS. Feeds `RTSPSessionMachine.transportReady(isTLS:now:)`,
    /// which uses it to decide whether Basic authentication is acceptable.
    var isTLS: Bool { get async }
}

// MARK: - Factory

/// How a controller obtains a transport for one URL.
///
/// A closure rather than a protocol so the app target can hand over
/// `{ url in LiveRTSPTransport(url: url, …) }` without `VigilCore` gaining a compile-time
/// dependency on the shape of `RTSPConnection`'s initialiser — the one thing in this module that
/// cannot be checked by a compiler in this container.
public typealias RTSPTransportFactory = @Sendable (RTSPURL) -> any RTSPTransport

#endif
