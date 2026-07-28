//
//  DatagramChannels.swift
//  VigilTransport
//
//  The two UDP endpoints discovery sends from, over `Network.NWConnectionGroup`.
//  macOS-only. Backs `VigilDiscovery.DatagramChannel`; see docs/spec-discovery.md §4.1 and §9.
//
//  Multicast and unicast are one file because they are one mechanism with one flag between them:
//  `NWConnectionGroup` carries both, and splitting them would duplicate the inbound plumbing —
//  which is the part with the subtleties.
//

#if os(macOS)

import Foundation
import Network
import os

import VigilDiscovery
import VigilProtocols

// MARK: - MulticastDatagramChannel

/// A channel joined to a multicast group on one interface.
///
/// ⛔ **`disableUnicast` must stay false.** Hikvision answers a SADP inquiry two ways depending on
/// firmware: some multicast the ProbeMatch back to the group, others unicast it straight to the
/// source port. Disabling unicast on this socket silently loses the second kind — the run finds
/// half the cameras and reports success, which is worse than finding none.
public actor MulticastDatagramChannel: DatagramChannel {

    /// The port actually bound. Compare against the spec's preferred port to learn whether the
    /// ephemeral fallback was taken (§4.1).
    public nonisolated let localPort: UInt16

    /// The interface this channel is pinned to.
    public nonisolated let interfaceName: String?

    private let group: NWConnectionGroup
    private let inbound: DatagramInbox
    private let clock: any WallClock
    private var isOpen = true

    /// Joins `spec`'s group on `spec`'s interface.
    ///
    /// - Throws: `.channelBindFailed(port:_:)` when the group cannot be described — a malformed
    ///   address or a port of zero where one was required. A *bind* failure surfaces later, from
    ///   the group's own state, because `NWConnectionGroup` does not bind until it is started.
    public init(spec: MulticastGroupSpec, clock: any WallClock) throws(DiscoveryError) {
        guard let address = Network.IPv4Address(spec.group.description),
              let groupPort = NWEndpoint.Port(rawValue: spec.port) else {
            throw DiscoveryError.channelBindFailed(port: spec.port, "malformed group address")
        }
        let endpoint = NWEndpoint.hostPort(host: .ipv4(address), port: groupPort)
        guard let descriptor = try? NWMulticastGroup(for: [endpoint],
                                                     disableUnicast: false) else {
            throw DiscoveryError.channelBindFailed(port: spec.port, "the group was refused")
        }

        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        // Pinned to one link. Without this macOS joins on the primary route only, and cameras on
        // the other interface of a dual-homed Mac are simply never heard (§11.1).
        parameters.requiredInterface = NWInterfaceIndex.named(spec.interfaceName)
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
            // One hop: SADP and WS-Discovery are on-link protocols, and letting them route would
            // put a customer's discovery traffic onto their uplink.
            ip.hopLimit = UInt8(clamping: spec.hopLimit)
        }
        if spec.preferredLocalPort != 0,
           let local = NWEndpoint.Port(rawValue: spec.preferredLocalPort) {
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: .ipv4(Network.IPv4Address(spec.localAddress.description) ?? .any),
                port: local)
        }

        self.localPort = spec.preferredLocalPort
        self.interfaceName = spec.interfaceName
        self.clock = clock
        self.group = NWConnectionGroup(with: descriptor, using: parameters)
        self.inbound = DatagramInbox(interfaceName: spec.interfaceName, clock: clock)
        Self.start(group, inbox: inbound)
    }

    /// Sends one datagram to a specific host.
    public func send(_ payload: Data, to host: VigilProtocols.IPv4Address,
                     port: UInt16) async throws(DiscoveryError) {
        try await Self.send(payload, to: host, port: port, over: group)
    }

    /// The inbound datagrams.
    public nonisolated func inboundDatagrams() -> AsyncStream<InboundDatagram> {
        inbound.stream()
    }

    /// Closes the socket and finishes the stream. Idempotent.
    public func close() async {
        guard isOpen else { return }
        isOpen = false
        group.cancel()
        inbound.finish()
    }

    // MARK: - Shared plumbing

    /// Wires the group's receive handler and starts it.
    ///
    /// `nonisolated static` so it can be called from `init` before `self` is fully formed, which is
    /// what an actor's initialiser requires.
    fileprivate static func start(_ group: NWConnectionGroup, inbox: DatagramInbox) {
        group.setReceiveHandler(maximumMessageSize: 65_535, rejectOversizedMessages: false) {
            message, content, _ in
            guard let content, !content.isEmpty else { return }
            inbox.deliver(content, from: message.remoteEndpoint)
        }
        // ⛔ A malformed datagram on a shared group is normal — anything on the LAN may be talking
        // to 239.255.255.250 — so nothing here ends the stream. Only `close()` does.
        group.stateUpdateHandler = { _ in }
        group.start(queue: DatagramInbox.queue)
    }

    /// One send over a group, as a `DiscoveryError`-typed async call.
    fileprivate static func send(_ payload: Data, to host: VigilProtocols.IPv4Address,
                                 port: UInt16,
                                 over group: NWConnectionGroup) async throws(DiscoveryError) {
        guard let address = Network.IPv4Address(host.description),
              let destinationPort = NWEndpoint.Port(rawValue: port) else {
            throw DiscoveryError.probeSendFailed
        }
        let endpoint = NWEndpoint.hostPort(host: .ipv4(address), port: destinationPort)
        let error: NWError? = await withCheckedContinuation { continuation in
            let box = SendOnce()
            group.send(content: payload, to: endpoint) { error in
                box.finish(continuation, with: error)
            }
        }
        guard let error else { return }
        // ⛔ EPERM/EACCES is how a missing multicast entitlement is found: empirically, from a real
        // send, not by reading the OS version (§9.3). The caller falls back to a unicast sweep on
        // this and only this distinction, so collapsing it into `.probeSendFailed` would turn a
        // recoverable configuration problem into a discovery run that reports nothing and explains
        // nothing.
        if case let .posix(code) = error, code == .EPERM || code == .EACCES {
            throw DiscoveryError.multicastUnavailable(.entitlementMissing)
        }
        throw DiscoveryError.probeSendFailed
    }
}

// MARK: - UnicastDatagramChannel

/// A connectionless UDP endpoint for directed probes.
///
/// The same `NWConnectionGroup` machinery without a multicast descriptor: SADP and WS-Discovery are
/// also sent host by host during a unicast sweep, and the replies must land on the same socket that
/// sent them or the source port in the datagram will not match what the device answers to.
public actor UnicastDatagramChannel: DatagramChannel {

    public nonisolated let localPort: UInt16
    public nonisolated let interfaceName: String?

    private let group: NWConnectionGroup
    private let inbound: DatagramInbox
    private var isOpen = true

    /// Binds a connectionless endpoint on one interface.
    ///
    /// - Parameters:
    ///   - localAddress: the interface's own address, which the bind is pinned to.
    ///   - localPort: the port to bind, or zero for an ephemeral one.
    ///   - interfaceName: the BSD name to pin to.
    ///   - clock: supplies each datagram's arrival time, so a replayed script is reproducible.
    public init(localAddress: VigilProtocols.IPv4Address, localPort: UInt16,
                interfaceName: String, clock: any WallClock) throws(DiscoveryError) {
        guard let address = Network.IPv4Address(localAddress.description) else {
            throw DiscoveryError.channelBindFailed(port: localPort, "malformed local address")
        }
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredInterface = NWInterfaceIndex.named(interfaceName)
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let port = NWEndpoint.Port(rawValue: localPort) ?? .any
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(address), port: port)

        // A group with no descriptor is the connectionless case: it can send anywhere and receives
        // whatever arrives at the bound port.
        guard let descriptor = try? NWMulticastGroup(for: [], disableUnicast: false) else {
            throw DiscoveryError.channelBindFailed(port: localPort, "the endpoint was refused")
        }
        self.localPort = localPort
        self.interfaceName = interfaceName
        self.group = NWConnectionGroup(with: descriptor, using: parameters)
        self.inbound = DatagramInbox(interfaceName: interfaceName, clock: clock)
        MulticastDatagramChannel.start(group, inbox: inbound)
    }

    public func send(_ payload: Data, to host: VigilProtocols.IPv4Address,
                     port: UInt16) async throws(DiscoveryError) {
        try await MulticastDatagramChannel.send(payload, to: host, port: port, over: group)
    }

    public nonisolated func inboundDatagrams() -> AsyncStream<InboundDatagram> {
        inbound.stream()
    }

    public func close() async {
        guard isOpen else { return }
        isOpen = false
        group.cancel()
        inbound.finish()
    }
}

// MARK: - DatagramInbox

/// Turns `NWConnectionGroup`'s callback into one `AsyncStream`.
///
/// A `final class` over a lock rather than an actor: the receive handler runs on a dispatch queue
/// and cannot `await`, and every datagram would otherwise cost a hop onto an actor before it could
/// be yielded.
///
/// The stream buffers rather than drops. A discovery run is bounded in time and in hosts, so the
/// backlog cannot grow without limit, and a dropped ProbeMatch is a camera the user does not see.
final class DatagramInbox: Sendable {

    /// One queue for every discovery datagram in the process. The handler does no work beyond
    /// yielding, so serialising them costs nothing and keeps arrival order stable per channel.
    static let queue = DispatchQueue(label: "vigil.discovery.udp")

    /// Everything the lock owns, as one value.
    private struct State: Sendable {
        var continuation: AsyncStream<InboundDatagram>.Continuation?
        var pending: [InboundDatagram] = []
        var isFinished = false
    }

    private let interfaceName: String?
    private let clock: any WallClock
    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    init(interfaceName: String?, clock: any WallClock) {
        self.interfaceName = interfaceName
        self.clock = clock
    }

    /// The inbound stream. Calling twice returns a stream that yields nothing new, as the protocol
    /// permits — the second caller would otherwise silently steal the first one's datagrams.
    func stream() -> AsyncStream<InboundDatagram> {
        AsyncStream { continuation in
            let (alreadyTaken, backlog, finished) = state.withLock { state
                -> (Bool, [InboundDatagram], Bool) in
                let taken = state.continuation != nil
                let backlog = state.pending
                state.pending = []
                if !taken { state.continuation = continuation }
                return (taken, backlog, state.isFinished)
            }
            guard !alreadyTaken else { return continuation.finish() }
            // ⚠️ Datagrams that arrived between `start()` and this call are replayed. The group is
            // started in `init` so the socket is listening before the caller asks for the stream,
            // and a ProbeMatch from a fast camera really does beat the first `for await`.
            for datagram in backlog { continuation.yield(datagram) }
            if finished { continuation.finish() }
        }
    }

    /// Yields one datagram, or holds it until the stream is taken.
    func deliver(_ payload: Data, from endpoint: NWEndpoint?) {
        guard let (source, port) = Self.address(of: endpoint) else { return }
        let datagram = InboundDatagram(payload: payload,
                                       source: source,
                                       sourcePort: port,
                                       interfaceName: interfaceName,
                                       receivedAt: clock.now)
        let sink = state.withLock { state -> AsyncStream<InboundDatagram>.Continuation? in
            if state.continuation == nil, !state.isFinished { state.pending.append(datagram) }
            return state.continuation
        }
        sink?.yield(datagram)
    }

    /// Ends the stream. Idempotent.
    func finish() {
        let sink = state.withLock { state -> AsyncStream<InboundDatagram>.Continuation? in
            let sink = state.continuation
            state.continuation = nil
            state.isFinished = true
            state.pending = []
            return sink
        }
        sink?.finish()
    }

    /// The IPv4 address and port behind an `NWEndpoint`, or `nil` when it is not one.
    private static func address(of endpoint: NWEndpoint?)
        -> (VigilProtocols.IPv4Address, UInt16)? {
        guard case let .hostPort(host, port) = endpoint else { return nil }
        guard case let .ipv4(address) = host else { return nil }
        // Through the string form on purpose: `Network.IPv4Address.rawValue` is network byte order
        // and this project's is host order, and getting that backwards mirrors every source address
        // into a different subnet — which looks like a working scan of the wrong network.
        guard let parsed = VigilProtocols.IPv4Address(String(describing: address)) else {
            return nil
        }
        return (parsed, port.rawValue)
    }
}

// MARK: - SendOnce

/// Resumes a send's continuation once. See `TCPConnectProber.OnceBox` for why this is not optional.
private struct SendOnce: Sendable {

    private let isDone = OSAllocatedUnfairLock<Bool>(initialState: false)

    func finish(_ continuation: CheckedContinuation<NWError?, Never>, with error: NWError?) {
        let shouldResume = isDone.withLock { done -> Bool in
            defer { done = true }
            return !done
        }
        guard shouldResume else { return }
        continuation.resume(returning: error)
    }
}

#endif  // os(macOS)
