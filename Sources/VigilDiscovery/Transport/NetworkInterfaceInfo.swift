//
//  NetworkInterfaceInfo.swift
//  VigilDiscovery
//
//  The pure value types the macOS transport layer hands back: an interface, an ARP-cache entry, the
//  outcome of a single TCP connect probe, and the collected result of probing one host.
//  Implements docs/spec-discovery.md §6.1, §6.3 and §6.5. Nothing here touches a socket.
//

import VigilProtocols

// MARK: - Interfaces

/// One IPv4-capable network interface, as `getifaddrs(3)` described it.
///
/// The type is pure so that every exclusion rule in §6.1 — loopback, AWDL, tunnels, link-local — can
/// be decided and unit-tested on Linux, far away from the platform call that produced it.
public struct NetworkInterfaceInfo: Sendable, Hashable, Codable {

    /// BSD interface name, e.g. `en0`.
    public let name: String
    /// The interface's own IPv4 address.
    public let address: IPv4Address
    /// Its netmask, as reported. May be non-contiguous on hostile input, which `subnet` rejects.
    public let netmask: IPv4Address
    /// `IFF_POINTOPOINT`: a tunnel, a VPN, or a point-to-point link.
    public let isPointToPoint: Bool
    /// True for Wi-Fi. Recorded for diagnostics; it does not change the plan.
    public let isWireless: Bool
    /// Link MTU. Recorded only.
    public let mtu: Int

    public init(name: String, address: IPv4Address, netmask: IPv4Address,
                isPointToPoint: Bool = false, isWireless: Bool = false, mtu: Int = 1_500) {
        self.name = name
        self.address = address
        self.netmask = netmask
        self.isPointToPoint = isPointToPoint
        self.isWireless = isWireless
        self.mtu = mtu
    }

    /// The subnet this interface sits on, or `nil` when the netmask is not a valid contiguous mask.
    public var subnet: IPv4Subnet? { IPv4Subnet(address: address, mask: netmask) }

    /// The conventional gateway guess for this interface: the first usable host of its subnet.
    ///
    /// A guess, not a fact — we cannot read the routing table from the pure layer. It is used only
    /// to prime the host order (a router answering early makes the scan feel alive) and as the
    /// silent-gateway signal in the permission heuristic, so being wrong costs nothing.
    public var likelyGateway: IPv4Address? {
        guard let subnet, subnet.prefixLength <= 30 else { return nil }
        return subnet.firstUsableHost
    }
}

// MARK: - ARP

/// One row of the system ARP cache: an IPv4 address the kernel has resolved to a link-layer address.
///
/// Free identity. An ARP entry costs no packet and yields a MAC, which is the strongest rung of the
/// identity ladder — but only for addresses inside a subnet we planned, never for a neighbour of the
/// router on some other network (§6.3).
public struct ARPEntry: Sendable, Hashable, Codable {

    public let address: IPv4Address
    public let mac: MACAddress
    /// `sdl_index`: which interface the entry belongs to.
    public let interfaceIndex: Int32
    /// True when the kernel has an entry but no resolved MAC (`sdl_alen == 0`). Such a row proves
    /// the address was probed, never that the MAC is `mac`, so it must not seed identity.
    public let isIncomplete: Bool

    public init(address: IPv4Address, mac: MACAddress, interfaceIndex: Int32 = 0,
                isIncomplete: Bool = false) {
        self.address = address
        self.mac = mac
        self.interfaceIndex = interfaceIndex
        self.isIncomplete = isIncomplete
    }

    /// True when this entry may be used as a `DeviceIdentity`: complete, and a real unicast MAC.
    public var isUsableIdentity: Bool { !isIncomplete && mac.isUsableIdentity }
}

// MARK: - Probe outcomes

/// A POSIX `errno` value, carried across the pure boundary without importing `Darwin`.
public struct POSIXCode: Sendable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }
    public var description: String { "errno \(rawValue)" }
}

/// What a single TCP connect probe learned.
///
/// `refused` is not a failure: an RST proves the host exists, which is what separates "an empty
/// network" from "a network macOS is refusing to let us talk to" (§9.4).
public enum TCPProbeOutcome: Sendable, Hashable, Codable {
    /// The handshake completed.
    case open
    /// RST: the host is alive and that port is closed.
    case refused
    /// Nothing came back inside the budget.
    case timedOut
    /// ICMP unreachable, or a routing failure.
    case unreachable(POSIXCode)
    /// Local-network permission denied, or the sandbox refused the connection.
    case blockedByPolicy

    /// True when this outcome proves a host exists at that address.
    public var provesHostAlive: Bool { self == .open || self == .refused }
}

// MARK: - Host probe results

/// Everything one host yielded during the sweep: which ports answered and what the fingerprints
/// said. This is the value the transport hands back and the merge engine turns into observations.
public struct HostProbeResult: Sendable, Hashable {

    /// The address probed.
    public let address: IPv4Address
    /// Outcome per port attempted. One entry per (host, port) per run: there are no retries (§6.10).
    public var portOutcomes: [UInt16: TCPProbeOutcome]
    /// The RTSP `OPTIONS` fingerprint, when port 554 or 8554 was open.
    public var rtsp: RTSPFingerprint?
    /// The `/ISAPI/System/deviceInfo` (or `/`) fingerprint, when an HTTP port was open.
    public var http: HTTPFingerprint?

    public init(address: IPv4Address, portOutcomes: [UInt16: TCPProbeOutcome] = [:],
                rtsp: RTSPFingerprint? = nil, http: HTTPFingerprint? = nil) {
        self.address = address
        self.portOutcomes = portOutcomes
        self.rtsp = rtsp
        self.http = http
    }

    /// Ports that completed a handshake.
    public var openPorts: Set<UInt16> {
        Set(portOutcomes.compactMap { $0.value == .open ? $0.key : nil })
    }

    /// True when any port proved the host exists, whether or not anything was open.
    public var isAlive: Bool { portOutcomes.values.contains { $0.provesHostAlive } }

    /// True when every attempted port timed out or was blocked — the shape that, repeated across a
    /// whole subnet, means macOS is blocking us rather than the network being empty.
    public var isSilent: Bool { !portOutcomes.isEmpty && !isAlive }

    /// True when at least one probe was refused by local policy rather than by the network.
    public var wasBlockedByPolicy: Bool { portOutcomes.values.contains(.blockedByPolicy) }
}
