//
//  RTSPConnection+Egress.swift
//  VigilTransport
//
//  Getting a socket open: resolving the endpoint, then connecting through it.
//  macOS-only. Split from RTSPConnection.swift, which docs/API_CONTRACT.md §7.2 caps at 600 lines.
//

#if os(macOS)

import Dispatch
import Foundation
import Network
import VigilProtocols
import VigilRTSP

// MARK: - Egress

/// ⚠️ Members here are `internal`, not `private`: Swift scopes `private` to one file, so anything
/// the rest of the actor calls would become invisible. `Scripts/lint.py`'s `split-access` rule
/// fails the build if one is left behind.
extension RTSPConnection {

    // MARK: - Egress, stage one: resolving before connecting

    /// Resolves the configured name and returns the address literal to connect to (R-71).
    ///
    /// Fails closed in every direction: a name that resolves anywhere outside the local network is
    /// `.egressBlocked` before a socket exists, a name that does not resolve is `.hostUnreachable`,
    /// and a resolver that does not answer inside the connect budget is `.connectTimeout`.
    func resolvePermittedAddress() async throws(VigilError) -> String {
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
    func finishResolve(with outcome: ResolveOutcome) {
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
    static func endpointHostText(_ host: String) -> String {
        guard host.contains(":") else { return host }
        return host.replacingOccurrences(of: "%25", with: "%")
    }

    /// Converts the URL's port into an `NWEndpoint.Port`.
    func endpointPort() throws(VigilError) -> NWEndpoint.Port {
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
    func waitForReady(_ socket: NWConnection) async -> VigilError? {
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
    func finishConnect(with failure: VigilError?) {
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
    func openSession() {
        let now = clock.now()
        let ready = machine.transportReady(isTLS: isTLS, now: now)
        execute(ready)
        let started = machine.handle(.start, now: now)
        execute(started)
        let stepped = machine.step(now: now)
        execute(stepped)
    }
}

#endif
