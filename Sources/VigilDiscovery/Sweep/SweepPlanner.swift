//
//  SweepPlanner.swift
//  VigilDiscovery
//
//  Turns the machine's interface list and ARP cache into a plan: which subnets may be swept, in
//  what order, and what was refused or narrowed on the way. This is where the /16 guard is enforced.
//  Implements docs/spec-discovery.md §6.1, §6.2 and §10.2. Pure: it opens nothing and sends nothing.
//

import VigilProtocols

// MARK: - DiscoveryPlan

/// What a run intends to do, decided before a single packet is sent.
///
/// The plan is emitted as the first event so the UI can state up front what will and will not be
/// scanned. `refusedSubnets` and `narrowedFrom` are part of that promise: a scan that quietly
/// covered less than the user assumed is worse than one that says so.
public struct DiscoveryPlan: Sendable, Hashable {

    /// Interfaces that survived the §6.1 exclusion rules.
    public let interfaces: [NetworkInterfaceInfo]
    /// The subnets that will actually be swept, after narrowing.
    public let subnets: [IPv4Subnet]
    /// Every address to probe, in the order of §6.2.
    public let hostOrder: [IPv4Address]
    /// Ports probed on every planned host.
    public let tierAPorts: [UInt16]
    /// Interface names to open multicast channels on — including duplicates by subnet, because a
    /// device may only answer on one of two links to the same LAN.
    public let multicastInterfaces: [String]
    /// `hostOrder.count`, kept explicitly so a caller never has to trust the array's length.
    public let hostsPlanned: Int
    /// The deadline this plan is sized for (§8.3).
    public let estimatedDuration: Duration
    /// Subnets that were too large to sweep whole and were narrowed to `/24`s.
    public let narrowedFrom: [IPv4Subnet]
    /// Subnets refused outright by the guard: wider than `/16`.
    public let refusedSubnets: [IPv4Subnet]
    /// Findings from planning, to be emitted as `.diagnostic` events by the caller. The planner is
    /// pure and has no event stream of its own, so it returns them instead.
    public let diagnostics: [DiscoveryDiagnostic]

    public init(interfaces: [NetworkInterfaceInfo], subnets: [IPv4Subnet],
                hostOrder: [IPv4Address], tierAPorts: [UInt16], multicastInterfaces: [String],
                estimatedDuration: Duration, narrowedFrom: [IPv4Subnet] = [],
                refusedSubnets: [IPv4Subnet] = [], diagnostics: [DiscoveryDiagnostic] = []) {
        self.interfaces = interfaces
        self.subnets = subnets
        self.hostOrder = hostOrder
        self.tierAPorts = tierAPorts
        self.multicastInterfaces = multicastInterfaces
        self.hostsPlanned = hostOrder.count
        self.estimatedDuration = estimatedDuration
        self.narrowedFrom = narrowedFrom
        self.refusedSubnets = refusedSubnets
        self.diagnostics = diagnostics
    }

    /// True when `address` lies inside a subnet this run holds. The off-subnet test in §4.7: a
    /// device that answers from outside every planned subnet is visible but not connectable.
    public func contains(_ address: IPv4Address) -> Bool {
        subnets.contains { $0.contains(address) }
    }

    /// Total port probes the tier A pass will perform — the initial denominator for progress.
    public var tierAPortProbes: Int { hostsPlanned * tierAPorts.count }
}

// MARK: - SweepPlanner

/// Decides what may be swept.
///
/// Two rules do the safety work, and both live here rather than in the caller:
///
/// * anything wider than `/16` is **refused**. A `/8` is 16 777 214 connect attempts and is
///   indistinguishable from an attack on the user's own network. There is no flag that lifts it.
/// * `/16` through `/21` is **narrowed** to the `/24`s where a host has actually been seen, unless
///   the user explicitly opted into a large sweep.
///
/// The guard itself is `IPv4Subnet.sweepScope(hints:)` in `VigilProtocols`; this type applies it to
/// every candidate subnet and records what happened.
public enum SweepPlanner {

    /// Builds the plan, or fails when nothing may be swept.
    ///
    /// - Parameters:
    ///   - interfaces: every IPv4 interface the OS reported, unfiltered.
    ///   - arp: the ARP snapshot, used both as a liveness hint for ordering and as the evidence that
    ///     decides which `/24`s of a large subnet are worth sweeping.
    ///   - configuration: mode, port tiers and the `allowLargeSweep` / `includeTunnels` opt-ins.
    /// - Returns: `.failure(.noEligibleInterfaces)` when every interface was excluded or every
    ///   subnet refused; otherwise a plan, whose `diagnostics` explain every exclusion.
    public static func plan(interfaces: [NetworkInterfaceInfo],
                            arp: [ARPEntry],
                            configuration: DiscoveryConfiguration)
        -> Result<DiscoveryPlan, DiscoveryError> {

        let tierAPorts = configuration.effectiveTierAPorts

        // `.single` bypasses interface selection entirely: the user named an address, and refusing
        // to probe it because it is not on a subnet we recognise would be obtuse.
        if case let .single(address, ports) = configuration.mode {
            let subnet = IPv4Subnet(network: address, prefixLength: 32)
            let plan = DiscoveryPlan(
                interfaces: interfaces, subnets: [subnet], hostOrder: [address],
                tierAPorts: ports.isEmpty ? tierAPorts : ports,
                multicastInterfaces: [], estimatedDuration: DiscoveryDeadline.overall(hostsPlanned: 1))
            return .success(plan)
        }

        var diagnostics: [DiscoveryDiagnostic] = []
        let kept = eligibleInterfaces(interfaces, configuration: configuration,
                                      diagnostics: &diagnostics)
        guard !kept.isEmpty else { return .failure(.noEligibleInterfaces) }

        // De-duplicate by subnet for sweeping; multicast still runs on every kept interface, because
        // two links to one LAN can reach different devices.
        var seenSubnets: Set<IPv4Subnet> = []
        var candidateSubnets: [IPv4Subnet] = []
        for interface in kept {
            guard let subnet = interface.subnet else { continue }
            if seenSubnets.insert(subnet).inserted { candidateSubnets.append(subnet) }
        }
        if case let .subnets(requested) = configuration.mode {
            seenSubnets = []
            candidateSubnets = requested.filter { seenSubnets.insert($0).inserted }
        }

        let hints = arp.map(\.address) + kept.map(\.address) + kept.compactMap(\.likelyGateway)
        var sweepSubnets: [IPv4Subnet] = []
        var narrowedFrom: [IPv4Subnet] = []
        var refused: [IPv4Subnet] = []

        for subnet in candidateSubnets {
            // `allowLargeSweep` opts out of narrowing only — never out of the /16 floor.
            if configuration.allowLargeSweep,
               subnet.prefixLength >= SweepPolicy.minimumPrefixLength {
                sweepSubnets.append(subnet)
                continue
            }
            do {
                switch try subnet.sweepScope(hints: hints) {
                case let .full(full):
                    sweepSubnets.append(full)
                case let .narrowed(from, to):
                    narrowedFrom.append(from)
                    sweepSubnets.append(contentsOf: to)
                    diagnostics.append(.subnetNarrowed(from: from, to: to))
                }
            } catch {
                switch error {
                case let .prefixTooWide(offending, hostCount, _):
                    refused.append(offending)
                    diagnostics.append(.subnetTooWide(subnet: offending, hostCount: hostCount))
                }
            }
        }

        let sweeps = configuration.mode.includesSweep
        guard !sweepSubnets.isEmpty || !sweeps else {
            return .failure(.noEligibleInterfaces)
        }

        let hostOrder: [IPv4Address] = sweeps
            ? IPv4HostOrder.order(subnets: sweepSubnets, hints: arp.map(\.address),
                                  gateways: kept.compactMap(\.likelyGateway))
            : []

        let plan = DiscoveryPlan(
            interfaces: kept,
            subnets: sweepSubnets,
            hostOrder: hostOrder,
            tierAPorts: tierAPorts,
            multicastInterfaces: kept.map(\.name),
            estimatedDuration: configuration.overallDeadlineOverride
                ?? DiscoveryDeadline.overall(hostsPlanned: hostOrder.count),
            narrowedFrom: narrowedFrom,
            refusedSubnets: refused,
            diagnostics: diagnostics)
        return .success(plan)
    }

    // MARK: Interface exclusion

    /// Applies the §6.1 exclusion table. Kept pure and separate so every rule is directly testable.
    ///
    /// Dropped: loopback, Apple Wireless Direct Link (`awdl*`, `llw*`), link-local `169.254/16`,
    /// interfaces whose netmask is not a valid contiguous mask, and — unless `includeTunnels` —
    /// every point-to-point or `utun`/`ipsec`/`ppp` interface, because sweeping a corporate VPN is
    /// hostile. Kept: everything else, notably `en*`, `bridge*` and `anpi*`.
    static func eligibleInterfaces(_ interfaces: [NetworkInterfaceInfo],
                                   configuration: DiscoveryConfiguration,
                                   diagnostics: inout [DiscoveryDiagnostic])
        -> [NetworkInterfaceInfo] {

        var kept: [NetworkInterfaceInfo] = []
        for interface in interfaces {
            let name = interface.name
            if interface.address.isLoopback || name.hasPrefix("lo") { continue }
            if name.hasPrefix("awdl") || name.hasPrefix("llw") { continue }
            if interface.address.isLinkLocal || interface.address.isUnspecified { continue }
            if isTunnel(interface) {
                if !configuration.includeTunnels {
                    diagnostics.append(.tunnelInterfaceSkipped(name: name))
                    continue
                }
            }
            guard interface.subnet != nil else { continue }
            kept.append(interface)
        }
        return kept
    }

    /// True for VPN-shaped interfaces: the `IFF_POINTOPOINT` flag, or a `utun`/`ipsec`/`ppp` name
    /// with a numeric suffix.
    static func isTunnel(_ interface: NetworkInterfaceInfo) -> Bool {
        if interface.isPointToPoint { return true }
        for prefix in ["utun", "ipsec", "ppp"] where interface.name.hasPrefix(prefix) {
            let suffix = interface.name.dropFirst(prefix.count)
            if !suffix.isEmpty, suffix.allSatisfy(\.isNumber) { return true }
        }
        return false
    }
}
