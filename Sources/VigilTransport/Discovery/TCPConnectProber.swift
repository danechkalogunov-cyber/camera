//
//  TCPConnectProber.swift
//  VigilTransport
//
//  One TCP connect attempt per call, over `Network.NWConnection`.
//  macOS-only. Backs `VigilDiscovery.TCPProbing`; see docs/spec-discovery.md §6.5.
//
//  ⛔ Nothing is ever sent. The handshake completing is the whole answer, and the connection is
//  cancelled the instant it reaches `.ready` — a probe that wrote so much as a newline would be
//  traffic a customer's IDS is entitled to call a port scan, and Vigil's claim that discovery never
//  authenticates rests on this file sending no bytes at all.
//

#if os(macOS)

import Foundation
import Network
import os

import VigilDiscovery
import VigilProtocols

// MARK: - TCPConnectProber

/// Probes one port at a time.
///
/// **Never throws.** Every outcome is information: a refusal proves a host is there just as firmly
/// as an accept does, and only a timeout is an absence of evidence (§6.5).
public struct TCPConnectProber: TCPProbing {

    /// The queue every probe's state changes are delivered on.
    ///
    /// One shared serial queue rather than one per probe: a sweep runs hundreds of these, and a
    /// queue apiece would make the thread pool the sweep's real concurrency limit instead of the
    /// budget the planner computed.
    private let queue: DispatchQueue

    /// Creates a prober.
    ///
    /// - Parameter queue: where `NWConnection` callbacks land. The default is a serial queue owned
    ///   by this prober; the callbacks do no work beyond resuming a continuation.
    public init(queue: DispatchQueue = DispatchQueue(label: "vigil.discovery.tcp")) {
        self.queue = queue
    }

    /// Probes one port.
    ///
    /// - Parameters:
    ///   - host: the address to try.
    ///   - port: the port to try.
    ///   - timeout: the caller's budget. ⚠️ Enforced here rather than left to `NWConnection`, whose
    ///     own timeout is tens of seconds — one silent host would otherwise stall a whole sweep
    ///     behind it, and the planner's budget would become fiction.
    ///   - interfaceName: pins the attempt to one interface, so a Mac on both Wi-Fi and Ethernet
    ///     probes the segment it was asked about rather than whichever the routing table prefers.
    /// - Returns: what happened. Never throws.
    public func probe(_ host: VigilProtocols.IPv4Address, port: UInt16, timeout: Duration,
                      interfaceName: String?) async -> TCPProbeOutcome {
        guard let endpointPort = NWEndpoint.Port(rawValue: port),
              let address = Network.IPv4Address(host.description) else { return .timedOut }
        let endpoint = NWEndpoint.hostPort(host: .ipv4(address), port: endpointPort)

        let parameters = NWParameters.tcp
        // ⛔ Loopback and peer-to-peer are off: a discovery sweep of the local segment has no
        // business reaching this Mac's own services or standing up an AWDL link to a nearby phone.
        parameters.prohibitedInterfaceTypes = [.loopback]
        parameters.includePeerToPeer = false
        if let interfaceName, let interface = NWInterfaceIndex.named(interfaceName) {
            parameters.requiredInterface = interface
        }
        // IPv4 only. Discovery sweeps an IPv4 prefix; letting the stack pick v6 would probe an
        // address the planner never chose.
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }

        let connection = NWConnection(to: endpoint, using: parameters)
        let outcome = await Self.resolve(connection, queue: queue, timeout: timeout)
        connection.cancel()
        return outcome
    }

    // MARK: - Private Helpers

    /// Runs the connection until it settles or the budget expires.
    ///
    /// The continuation is resumed exactly once, guarded by a lock rather than by reasoning about
    /// ordering: the state handler and the timeout race by construction, and `NWConnection` is
    /// entitled to deliver `.cancelled` after `.failed` for the same attempt. Resuming a
    /// continuation twice is a crash, not a warning.
    private static func resolve(_ connection: NWConnection, queue: DispatchQueue,
                                timeout: Duration) async -> TCPProbeOutcome {
        let box = OnceBox()
        return await withCheckedContinuation { continuation in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.finish(continuation, with: .open)
                case let .waiting(error):
                    // `.waiting` is not a failure to `NWConnection` — it will retry for ever. For a
                    // sweep it is the answer: the path is not viable now, which is what the caller
                    // asked about.
                    box.finish(continuation, with: Self.outcome(for: error))
                case let .failed(error):
                    box.finish(continuation, with: Self.outcome(for: error))
                case .cancelled:
                    box.finish(continuation, with: .timedOut)
                case .setup, .preparing:
                    break
                @unknown default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout.seconds) {
                box.finish(continuation, with: .timedOut)
            }
        }
    }

    /// What an `NWError` means for a sweep.
    ///
    /// `ECONNREFUSED` is deliberately **not** a failure of the probe: a refusal is a host answering,
    /// which is exactly what discovery is looking for, and treating it as an error would make the
    /// sweep blind to every camera with a closed RTSP port.
    private static func outcome(for error: NWError) -> TCPProbeOutcome {
        switch error {
        case let .posix(code):
            switch code {
            case .ECONNREFUSED:
                return .refused
            case .ETIMEDOUT:
                return .timedOut
            case .EPERM, .EACCES:
                // The local-network prompt was declined, or the sandbox has no client entitlement.
                // Distinct from unreachable because the fix is a permission, not a network.
                return .blockedByPolicy
            default:
                return .unreachable(POSIXCode(rawValue: code.rawValue))
            }
        // ⚠️ `default`, not `@unknown default`. `NWError` gains cases between SDKs — `.wifiAware`
        // arrived in the one CI now builds against, and naming it here would stop this file
        // compiling against any older SDK. Everything that is not a POSIX code means the same
        // thing to a sweep anyway, so a total default is the honest spelling as well as the
        // portable one.
        default:
            return .timedOut
        }
    }
}

// MARK: - OnceBox

/// Resumes a continuation at most once, from any thread.
///
/// `OSAllocatedUnfairLock` rather than an actor: this is called from an `NWConnection` callback and
/// from a `DispatchQueue` timer, neither of which can `await`, and the critical section is one
/// boolean flip. It is `Sendable` on its own — no `@unchecked` is spent, which matters because
/// API_CONTRACT R-52 caps those and the budget belongs to cases that genuinely need it.
///
/// ⛔ The guard is not defensive tidiness. The state handler and the timeout race by construction,
/// and `NWConnection` may deliver `.cancelled` after `.failed` for one attempt; resuming a checked
/// continuation twice traps.
private struct OnceBox: Sendable {

    private let isDone = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Resumes `continuation` with `outcome`, unless something already has.
    func finish(_ continuation: CheckedContinuation<TCPProbeOutcome, Never>,
                with outcome: TCPProbeOutcome) {
        let shouldResume = isDone.withLock { done -> Bool in
            defer { done = true }
            return !done
        }
        guard shouldResume else { return }
        continuation.resume(returning: outcome)
    }
}

// MARK: - NWInterfaceIndex

/// Named interfaces, looked up by name.
///
/// ⚠️ `NWInterface` has **no public initialiser**. The only supported way to obtain one is from a
/// path, which is why this exists rather than a one-line conversion at the call site: pinning a
/// probe to an interface is not optional for a Mac on both Wi-Fi and Ethernet — without it the
/// routing table picks, and the sweep probes a segment the planner never asked about.
///
/// The monitor is started once and left running. It is one object for the process and it is how the
/// list stays correct across a cable being plugged in mid-sweep.
/// ⚠️ A `final class` over a lock, not an actor, and that is forced rather than chosen: the
/// datagram channels are **synchronous initialisers** that need an interface before they can build
/// their `NWParameters`, and an initialiser cannot `await`. The first version of this was an actor
/// and could not be called from either of them.
///
/// ⚠️ `@unchecked` is spent here and it is the only one in this directory — everything else got a
/// checked `Sendable` over an `OSAllocatedUnfairLock`. It cannot be avoided: `NWPathMonitor` is not
/// `Sendable` in the SDK, so it can neither be a stored property of a checked-`Sendable` type nor
/// live inside the lock's state. What makes it safe is that the monitor is written once under the
/// lock and only ever *read* afterwards, and `currentPath` is documented as safe to read from any
/// thread.
final class NWInterfaceIndex: @unchecked Sendable {

    /// The shared index.
    static let shared = NWInterfaceIndex()

    private let monitor = NWPathMonitor()
    private let started = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// The interface with this BSD name, or `nil` when the system does not currently have one.
    ///
    /// A `nil` is not an error and must not fail a probe: an interface can disappear between the
    /// planner choosing it and the probe running, and an unpinned probe still reaches most hosts.
    static func named(_ name: String) -> NWInterface? {
        shared.lookUp(name)
    }

    private func lookUp(_ name: String) -> NWInterface? {
        start()
        return monitor.currentPath.availableInterfaces.first { $0.name == name }
    }

    /// Starts the monitor on first use, and leaves it running: it is one object for the process and
    /// it is how the list stays correct across a cable being plugged in mid-sweep.
    private func start() {
        let shouldStart = started.withLock { flag -> Bool in
            defer { flag = true }
            return !flag
        }
        guard shouldStart else { return }
        // A handler is required for the monitor to run; the path is read synchronously above, so
        // there is nothing to do when it changes.
        monitor.pathUpdateHandler = { _ in }
        monitor.start(queue: DispatchQueue(label: "vigil.discovery.path"))
    }
}

#endif  // os(macOS)
