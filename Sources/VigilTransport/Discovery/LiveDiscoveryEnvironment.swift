//
//  LiveDiscoveryEnvironment.swift
//  VigilTransport
//
//  The seam between the pure discovery engine and the eleven real things it needs.
//  macOS-only. Assembles `VigilDiscovery.DiscoveryEnvironment`; see docs/spec-discovery.md §1.2.
//
//  ⛔ THIS FILE IS THE ONLY REASON `VigilDiscovery` CAN STAY PURE. The planner, the three codecs,
//  the merge engine and the coordinator name no socket, no `getifaddrs`, no `Date()` and no UUID
//  generator — they name eleven protocol members, and this is where each one is finally a real
//  socket. Anything that reaches for the network from inside `VigilDiscovery` breaks the property
//  that its whole state machine runs on Linux with no network at all, which is what makes 2 700
//  tests possible.
//
//  Every member is supplied. `DiscoveryEnvironment.init` has no defaults on purpose: a default
//  would silently disable one mechanism, and a run that quietly skipped a mechanism is the hardest
//  kind of bug to see from the outside — the scan simply finds less and says nothing.
//

#if os(macOS)

import Foundation

import VigilDiscovery
import VigilProtocols

// MARK: - LiveDiscoveryEnvironment

/// Builds the environment a real discovery run uses.
public enum LiveDiscoveryEnvironment {

    /// Assembles the eleven injected values.
    ///
    /// - Parameters:
    ///   - logger: where `VigilDiscovery` logs. It never imports `os` and has no other way out.
    ///   - clock: supplies each datagram's arrival time and every deadline. Defaults to the system
    ///     one; a caller with its own wall clock passes it so the two agree.
    /// - Returns: an environment whose entitlement status has been read from this build's own
    ///   signature — not assumed, and not inferred from the OS version (§9.3).
    public static func make(logger: any LoggerProtocol,
                            clock: any WallClock = SystemWallClock()) -> DiscoveryEnvironment {
        let interfaces = SystemInterfaceEnumerator()
        return DiscoveryEnvironment(
            makeMulticastChannel: { spec throws(DiscoveryError) in
                try MulticastDatagramChannel(spec: spec, clock: clock)
            },
            makeUnicastChannel: { name throws(DiscoveryError) in
                try unicastChannel(interfaceName: name, interfaces: interfaces, clock: clock)
            },
            tcpProbe: TCPConnectProber(),
            exchange: ByteExchanger(),
            interfaces: interfaces,
            arp: SystemARPTableReader(),
            bonjour: BonjourBrowser(),
            clock: SystemDiscoveryClock(),
            logger: logger,
            entitlements: EntitlementInspector.status(),
            uuidGenerator: { UUID() })
    }

    // MARK: - Private

    /// Opens an unbound unicast channel, resolving the interface name to the address it must bind.
    ///
    /// ⚠️ `makeUnicastChannel` takes a *name* and `UnicastDatagramChannel` needs an *address*, so
    /// the gap is closed here rather than by widening the protocol. The protocol's shape is right:
    /// the planner works in interface names because that is what a user recognises and what the
    /// sweep plan is written in, and an address is an implementation detail of binding.
    ///
    /// A `nil` name means "no preference", which is the degraded path — unicast UDP needs no
    /// multicast entitlement (§4.9, §9.5) — and takes the first interface with a usable address.
    /// Port zero throughout: a unicast probe is answered to its source port, so nothing needs a
    /// well-known one, and binding one would collide with the multicast channels.
    private static func unicastChannel(interfaceName: String?,
                                       interfaces: SystemInterfaceEnumerator,
                                       clock: any WallClock)
        throws(DiscoveryError) -> any DatagramChannel {
        let available = try interfaces.interfaces()
        let chosen: NetworkInterfaceInfo?
        if let interfaceName {
            chosen = available.first { $0.name == interfaceName }
        } else {
            chosen = available.first
        }
        guard let chosen else {
            // Not `channelBindFailed`: nothing was bound and nothing failed to bind. The machine
            // has no interface to send from, which is a different sentence to a user staring at an
            // empty scan.
            throw DiscoveryError.noEligibleInterfaces
        }
        return try UnicastDatagramChannel(localAddress: chosen.address,
                                          localPort: 0,
                                          interfaceName: chosen.name,
                                          clock: clock)
    }
}

#endif  // os(macOS)
