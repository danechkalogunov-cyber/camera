//
//  Protocols.swift
//  VigilDiscovery
//
//  The injected socket seams a discovery run talks through: multicast and unicast datagrams, TCP
//  connect probes, one-shot request/response fingerprints, interface enumeration, the ARP table,
//  Bonjour browsing and the clock. Protocols only — every implementation lives in
//  `VigilTransport/Discovery/` behind `#if os(macOS)`, which is what keeps this module Linux-pure
//  and the whole orchestration unit-testable with no network at all.
//  Implements docs/spec-discovery.md §10.1 and §11, and docs/API_CONTRACT.md §4.6.
//

import Foundation
import VigilProtocols

// MARK: - Datagrams

/// One datagram as it arrived.
///
/// The source *address* is part of the value because SADP's XML does not carry one reliably and
/// because an unparseable payload still yields a device record built from the address alone (§4.8).
/// The source *port* is recorded but must never be used to filter: WS-Discovery answers come back
/// from arbitrary ports and filtering on 3702 loses most real cameras (§5.1).
public struct InboundDatagram: Sendable, Hashable {

    /// The payload bytes, exactly as received, with no framing removed.
    public let payload: Data
    /// UDP source address.
    public let source: IPv4Address
    /// UDP source port. Diagnostic only — never a filter.
    public let sourcePort: UInt16
    /// Which interface it arrived on, when the transport could tell us. Used to attribute a
    /// diagnostic to a link rather than to "the network".
    public let interfaceName: String?
    /// Arrival time, taken from the injected clock so a replayed script is reproducible.
    public let receivedAt: Date

    public init(payload: Data, source: IPv4Address, sourcePort: UInt16,
                interfaceName: String? = nil, receivedAt: Date) {
        self.payload = payload
        self.source = source
        self.sourcePort = sourcePort
        self.interfaceName = interfaceName
        self.receivedAt = receivedAt
    }
}

/// What a multicast channel should join, and where it should bind.
///
/// `preferredLocalPort` is load-bearing rather than cosmetic: most Hikvision firmware answers an
/// inquiry by multicasting its ProbeMatch back to `239.255.255.250:37020`, so a run bound to an
/// ephemeral port never hears those devices. When the preferred port cannot be bound the coordinator
/// retries with ``ephemeralFallback`` and reports the degradation (§4.1).
public struct MulticastGroupSpec: Sendable, Hashable {

    /// The group to join, always `239.255.255.250` in this app.
    public var group: IPv4Address
    /// The group port: 37020 for SADP, 3702 for WS-Discovery.
    public var port: UInt16
    /// The local port to bind, with address and port reuse. Zero means "any ephemeral port".
    public var preferredLocalPort: UInt16
    /// The interface's own address, which the bind is pinned to so one channel exists per link.
    public var localAddress: IPv4Address
    /// BSD interface name, e.g. `en0`. Mandatory: without pinning the interface, macOS picks the
    /// primary route and cameras on the other link vanish (§11.1).
    public var interfaceName: String
    /// IP hop limit. One, so SADP and WS-Discovery stay on-link.
    public var hopLimit: Int

    public init(group: IPv4Address, port: UInt16, preferredLocalPort: UInt16,
                localAddress: IPv4Address, interfaceName: String, hopLimit: Int = 1) {
        self.group = group
        self.port = port
        self.preferredLocalPort = preferredLocalPort
        self.localAddress = localAddress
        self.interfaceName = interfaceName
        self.hopLimit = hopLimit
    }

    /// The same spec with no fixed local port, for the retry after a bind failure. Results are then
    /// partial rather than empty: firmware that unicasts its reply is still heard (§4.1).
    public var ephemeralFallback: MulticastGroupSpec {
        var spec = self
        spec.preferredLocalPort = 0
        return spec
    }
}

/// A bound UDP endpoint that can send to a destination and yields the datagrams it receives.
///
/// Backed on macOS by `Network.NWConnectionGroup` over an `NWMulticastGroup` for the multicast case
/// and by a connectionless `NWConnectionGroup` for the unicast case
/// (`VigilTransport/Discovery/MulticastDatagramChannel.swift`,
/// `UnicastDatagramChannel.swift`). The multicast group **must** be built with
/// `disableUnicast: false`, because ProbeMatches arrive as unicast on this very socket.
///
/// An actor conforming to this protocol must declare `localPort` and `interfaceName` `nonisolated`;
/// they are fixed at construction and reading them must not suspend.
public protocol DatagramChannel: Sendable {

    /// The port actually bound. Compare it against `MulticastGroupSpec.preferredLocalPort` to learn
    /// whether the fallback was taken.
    var localPort: UInt16 { get }

    /// The interface this channel is pinned to, if any.
    var interfaceName: String? { get }

    /// Sends one datagram. Throws `.probeSendFailed` for an ordinary send error and
    /// `.multicastUnavailable(_:)` when the failure was `EPERM`/`EACCES`, which is how a missing
    /// multicast entitlement is detected empirically rather than from the OS version (§9.3).
    func send(_ payload: Data, to host: IPv4Address, port: UInt16) async throws(DiscoveryError)

    /// The inbound datagrams. Terminates when the channel is closed or cancelled and never throws
    /// mid-stream: a malformed datagram on a shared group is normal and must not end a run.
    /// Called once per channel; a second call may return an already-finished stream.
    func inboundDatagrams() -> AsyncStream<InboundDatagram>

    /// Closes the socket and finishes `inboundDatagrams()`. Idempotent.
    func close() async
}

// MARK: - TCP

/// One TCP connect attempt per call, with no retry and no data sent.
///
/// Backed by `Network.NWConnection` with `NWParameters.tcp`, cancelled the moment the state reaches
/// `.ready` (`VigilTransport/Discovery/TCPConnectProber.swift`). Never throws: every outcome,
/// including a refusal, is information (§6.5).
public protocol TCPProbing: Sendable {

    /// Probes one port. `timeout` is the caller's budget, not the framework's — a connect left to
    /// macOS's own timeout would stall a whole sweep behind one silent host.
    func probe(_ host: IPv4Address, port: UInt16, timeout: Duration,
               interfaceName: String?) async -> TCPProbeOutcome
}

/// One request/response exchange over a fresh TCP or TLS connection.
///
/// Backed by `Network.NWConnection`, with `NWProtocolTLS.Options` whose verify block accepts any
/// certificate — permissible **only** because no credential ever crosses this connection; `VigilISAPI`
/// applies real trust policy to credentialed traffic (§6.7, §11.2).
///
/// There is deliberately no credential parameter anywhere in this protocol. That is how "discovery
/// never authenticates" is enforced by the type system rather than by review: a caller cannot express
/// an `Authorization` header without hand-writing one into `request`, which the test doubles scan for
/// and fail on (§6.10).
public protocol ByteExchanging: Sendable {

    /// Sends `request` and returns at most `readLimit` bytes of the answer.
    ///
    /// Throws `.probeSendFailed` when the exchange failed outright; a truncated or empty answer is
    /// returned as data, because the fingerprint classifiers are total over any bytes.
    func exchange(host: IPv4Address, port: UInt16, useTLS: Bool, request: Data,
                  readLimit: Int, timeout: Duration,
                  interfaceName: String?) async throws(DiscoveryError) -> Data
}

// MARK: - Host facts

/// The machine's own IPv4 interfaces.
///
/// Backed by `getifaddrs(3)` in `VigilTransport/Discovery/SystemInterfaceEnumerator.swift`. The
/// exclusion rules (loopback, AWDL, tunnels, link-local) are **not** applied here: they belong to
/// `SweepPlanner`, so that every one of them is testable on Linux (§6.1).
public protocol InterfaceEnumerating: Sendable {

    /// Every IPv4 interface the OS reported, unfiltered. Throws
    /// `.interfaceEnumerationFailed(errno:)` when the platform call failed.
    func interfaces() throws(DiscoveryError) -> [NetworkInterfaceInfo]
}

/// The system ARP cache.
///
/// Backed by `sysctl(PF_ROUTE, NET_RT_FLAGS, RTF_LLINFO)` and, as a fallback, by parsing `arp -an`
/// (`VigilTransport/Discovery/SystemARPTableReader.swift`). Free identity: an ARP row yields a MAC
/// for no packet at all, which is the strongest rung of the identity ladder (§6.3).
public protocol ARPTableProviding: Sendable {

    /// The current cache. Throws `.arpReadFailed(errno:)` when the platform call failed; a run
    /// continues without MACs rather than failing.
    func snapshot() throws(DiscoveryError) -> [ARPEntry]
}

/// One Bonjour service instance.
public struct BonjourService: Sendable, Hashable {

    /// The instance name, which is often the friendliest label a device ever gives us.
    public let name: String
    /// The service type, e.g. `_rtsp._tcp`.
    public let type: String
    /// The browse domain, normally `local`.
    public let domain: String
    /// The resolved IPv4 address, when resolution succeeded. Without it the record can contribute
    /// nothing, because discovery keys everything on an address.
    public let address: IPv4Address?
    /// The resolved port.
    public let port: UInt16?
    /// TXT record keys and values, lowercased keys.
    public let txt: [String: String]

    public init(name: String, type: String, domain: String = "local",
                address: IPv4Address? = nil, port: UInt16? = nil, txt: [String: String] = [:]) {
        self.name = name
        self.type = type
        self.domain = domain
        self.address = address
        self.port = port
        self.txt = txt
    }
}

/// A Bonjour browse.
///
/// Backed by `Network.NWBrowser` (`VigilTransport/Discovery/BonjourBrowser.swift`). Every type
/// browsed must also be declared in `Info.plist`'s `NSBonjourServices`, or the browse returns
/// nothing at all with no error (§9.2). mDNS goes through the system daemon rather than our own
/// socket, so a browse still works when the multicast entitlement is missing (§9.5).
public protocol ServiceBrowsing: Sendable {

    /// Browses `types` until the returned stream is cancelled. Never throws: a browse that cannot
    /// start is indistinguishable from a network with no Bonjour on it, and neither is fatal.
    func browse(types: [String]) -> AsyncStream<BonjourService>
}

// MARK: - Time

/// The clock a run measures itself with.
///
/// Separate from `MonotonicClock` because discovery needs a wall-clock reading as well: a
/// `DiscoveredDevice` records `firstSeen`/`lastSeen` as `Date`, while every elapsed and deadline
/// calculation uses the monotonic reading, which no clock change can move. Backed on macOS by
/// `ContinuousClock` plus `Date()`; a test supplies a virtual implementation and a twelve-second run
/// completes in microseconds.
public protocol DiscoveryClock: Sendable {

    /// The wall clock, for the timestamps that appear in records and in the UI.
    var wallNow: Date { get }

    /// The monotonic reading, for elapsed time, deadlines and the ETA.
    func now() -> MediaInstant

    /// Cancellable sleep. Implementations must throw `CancellationError` on task cancellation, which
    /// is what makes `cancel()` close every socket inside 50 ms (§8.4).
    func sleep(for duration: Duration) async throws
}

// MARK: - Environment

/// Everything a `DiscoveryCoordinator` needs from the outside world, in one injectable value.
///
/// The eleven members are the whole reason this module is pure: no socket, timer, `getifaddrs`,
/// `Date()` or UUID generator appears anywhere else in `VigilDiscovery`, so the planner, the three
/// codecs, the merge engine and the orchestration itself are all exercised on Linux with no network
/// (§1.2). `VigilTransport.LiveDiscoveryEnvironment.make(logger:)` assembles the real one.
public struct DiscoveryEnvironment: Sendable {

    /// Opens a channel joined to a multicast group on one interface. Throws
    /// `.channelBindFailed(port:_:)` when the preferred local port could not be bound — the
    /// coordinator then retries with `MulticastGroupSpec.ephemeralFallback` — and
    /// `.multicastUnavailable(_:)` when multicast is refused outright.
    public var makeMulticastChannel: @Sendable (MulticastGroupSpec) async throws(DiscoveryError)
        -> any DatagramChannel

    /// Opens an unbound unicast UDP channel, optionally pinned to an interface. The backbone of the
    /// degraded mode: unicast UDP needs no multicast entitlement (§4.9, §9.5).
    public var makeUnicastChannel: @Sendable (String?) async throws(DiscoveryError)
        -> any DatagramChannel

    /// TCP connect probes for the sweep.
    public var tcpProbe: any TCPProbing

    /// One-shot exchanges for the RTSP and HTTP fingerprints.
    public var exchange: any ByteExchanging

    /// Interface enumeration, for planning.
    public var interfaces: any InterfaceEnumerating

    /// The ARP cache, read before and after tier A.
    public var arp: any ARPTableProviding

    /// Bonjour browsing.
    public var bonjour: any ServiceBrowsing

    /// The clock. Injected, so no test ever waits and no run depends on the wall clock.
    public var clock: any DiscoveryClock

    /// The logger. `VigilDiscovery` never imports `os`; it logs through this (§12).
    public var logger: any LoggerProtocol

    /// What we know about our own multicast and local-network permissions (§9.3). The coordinator
    /// treats a false `multicastEntitlementPresent` as "skip multicast, degrade and say so".
    public var entitlements: EntitlementStatus

    /// The run's UUID source. Injected so a test can pin the SADP `Uuid` and the three
    /// WS-Discovery `MessageID`s and assert byte-exact probes.
    public var uuidGenerator: @Sendable () -> UUID

    /// Creates an environment. Every member is required: a default would silently disable a
    /// mechanism, and a discovery run that quietly skipped a mechanism is the hardest kind of bug to
    /// see from the outside.
    public init(makeMulticastChannel: @escaping @Sendable (MulticastGroupSpec)
                    async throws(DiscoveryError) -> any DatagramChannel,
                makeUnicastChannel: @escaping @Sendable (String?)
                    async throws(DiscoveryError) -> any DatagramChannel,
                tcpProbe: any TCPProbing,
                exchange: any ByteExchanging,
                interfaces: any InterfaceEnumerating,
                arp: any ARPTableProviding,
                bonjour: any ServiceBrowsing,
                clock: any DiscoveryClock,
                logger: any LoggerProtocol,
                entitlements: EntitlementStatus,
                uuidGenerator: @escaping @Sendable () -> UUID) {
        self.makeMulticastChannel = makeMulticastChannel
        self.makeUnicastChannel = makeUnicastChannel
        self.tcpProbe = tcpProbe
        self.exchange = exchange
        self.interfaces = interfaces
        self.arp = arp
        self.bonjour = bonjour
        self.clock = clock
        self.logger = logger
        self.entitlements = entitlements
        self.uuidGenerator = uuidGenerator
    }
}
