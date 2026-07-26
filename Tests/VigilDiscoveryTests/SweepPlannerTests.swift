//
//  SweepPlannerTests.swift
//  VigilDiscoveryTests
//
//  The sweep guard and the plan it produces: a /8 refused outright, a /20 narrowed to the ARP-backed
//  /24s, tunnels excluded, duplicate subnets swept once, and the host order that makes a scan feel
//  alive.
//  Covers docs/spec-discovery.md §6.1, §6.2 and §8.3; tests 40–46 of §13.4.
//

import Foundation
import Testing

import VigilProtocols
@testable import VigilDiscovery

@Suite struct SweepPlannerBehaviour {

    // MARK: - Helpers

    /// An interface with a /24 netmask unless told otherwise.
    static func interface(_ name: String, _ address: IPv4Address,
                          mask: IPv4Address = IPv4Address(255, 255, 255, 0),
                          pointToPoint: Bool = false) -> NetworkInterfaceInfo {
        NetworkInterfaceInfo(name: name, address: address, netmask: mask,
                             isPointToPoint: pointToPoint)
    }

    static func arp(_ address: IPv4Address, _ mac: String) -> ARPEntry? {
        MACAddress(mac).map { ARPEntry(address: address, mac: $0, interfaceIndex: 4) }
    }

    static func plan(_ interfaces: [NetworkInterfaceInfo], arp: [ARPEntry] = [],
                     configuration: DiscoveryConfiguration = .default) throws -> DiscoveryPlan {
        let result = SweepPlanner.plan(interfaces: interfaces, arp: arp,
                                       configuration: configuration)
        switch result {
        case let .success(plan): return plan
        case let .failure(error): throw error
        }
    }

    // MARK: - The guard

    /// Test 40, widened to the /8 the brief calls out: sixteen million connect attempts is refused
    /// outright, with the refusal visible so the UI can explain it.
    @Test func sweepPlannerRefusesSlashEight() throws {
        let plan = try Self.plan([Self.interface("en0", IPv4Address(10, 0, 0, 5),
                                                mask: IPv4Address(255, 0, 0, 0))])
        #expect(plan.hostOrder.isEmpty)
        #expect(plan.hostsPlanned == 0)
        #expect(plan.refusedSubnets == [IPv4Subnet(network: IPv4Address(10, 0, 0, 0),
                                                   prefixLength: 8)])
        #expect(plan.subnets.isEmpty)
        let refusal = plan.diagnostics.first { diagnostic in
            if case .subnetTooWide = diagnostic { return true }
            return false
        }
        #expect(refusal != nil)
        #expect(refusal?.severity == .warning)
        #expect(refusal?.userFacingMessage?.contains("16777214") == true)
    }

    /// A /15 is refused for the same reason, and the interface itself is still kept for multicast:
    /// the cameras on a big network are findable even when sweeping it is not allowed.
    @Test func sweepPlannerRefusesSlashFifteenButKeepsMulticast() throws {
        let plan = try Self.plan([Self.interface("en0", IPv4Address(172, 20, 0, 9),
                                                mask: IPv4Address(255, 254, 0, 0))])
        #expect(plan.refusedSubnets.count == 1)
        #expect(plan.refusedSubnets.first?.prefixLength == 15)
        #expect(plan.multicastInterfaces == ["en0"])
        #expect(plan.hostOrder.isEmpty)
    }

    /// `allowLargeSweep` opts into a wide sweep but cannot lift the /16 floor. This is the one that
    /// must never regress: the flag exists for a corporate /16, not for a /8.
    @Test func sweepPlannerAllowLargeSweepStillRefusesWiderThanSixteen() throws {
        var configuration = DiscoveryConfiguration.default
        configuration.allowLargeSweep = true
        let plan = try Self.plan([Self.interface("en0", IPv4Address(10, 1, 2, 3),
                                                mask: IPv4Address(255, 0, 0, 0))],
                                 configuration: configuration)
        #expect(plan.hostOrder.isEmpty)
        #expect(plan.refusedSubnets.first?.prefixLength == 8)
    }

    /// A machine with nothing but loopback and link-local has no plan to make.
    @Test func sweepPlannerFailsWithoutEligibleInterfaces() {
        let result = SweepPlanner.plan(
            interfaces: [Self.interface("lo0", IPv4Address(127, 0, 0, 1),
                                        mask: IPv4Address(255, 0, 0, 0)),
                         Self.interface("en5", IPv4Address(169, 254, 3, 9))],
            arp: [], configuration: .default)
        #expect(result == .failure(DiscoveryError.noEligibleInterfaces))
    }

    // MARK: - Narrowing

    /// The brief's case: a /20 narrows to the ARP-backed /24s plus our own.
    @Test func sweepPlannerNarrowsSlashTwentyToARPBackedTwentyFours() throws {
        let entries = [Self.arp(IPv4Address(10, 0, 20, 14), "c4:2f:90:ab:cd:ef"),
                       Self.arp(IPv4Address(10, 0, 23, 200), "bc:ad:28:11:22:33")].compactMap { $0 }
        let plan = try Self.plan([Self.interface("en0", IPv4Address(10, 0, 16, 5),
                                                mask: IPv4Address(255, 255, 240, 0))],
                                 arp: entries)
        #expect(plan.subnets == [IPv4Subnet(network: IPv4Address(10, 0, 16, 0), prefixLength: 24),
                                 IPv4Subnet(network: IPv4Address(10, 0, 20, 0), prefixLength: 24),
                                 IPv4Subnet(network: IPv4Address(10, 0, 23, 0), prefixLength: 24)])
        #expect(plan.hostsPlanned == 3 * 254)
        #expect(plan.narrowedFrom == [IPv4Subnet(network: IPv4Address(10, 0, 16, 0),
                                                 prefixLength: 20)])
        let narrowed = plan.diagnostics.compactMap { diagnostic -> [IPv4Subnet]? in
            if case let .subnetNarrowed(_, to) = diagnostic { return to }
            return nil
        }
        #expect(narrowed.count == 1)
        #expect(narrowed.first?.count == 3)
    }

    /// Test 41: a /16 narrows without an opt-in, and the diagnostic says so in plain words.
    @Test func sweepPlannerNarrowsSlashSixteenWithoutOptIn() throws {
        let entries = [Self.arp(IPv4Address(10, 0, 5, 60), "c4:2f:90:00:00:01"),
                       Self.arp(IPv4Address(10, 0, 9, 70), "c4:2f:90:00:00:02")].compactMap { $0 }
        let plan = try Self.plan([Self.interface("en0", IPv4Address(10, 0, 1, 20),
                                                mask: IPv4Address(255, 255, 0, 0))],
                                 arp: entries)
        #expect(plan.subnets.contains(IPv4Subnet(network: IPv4Address(10, 0, 1, 0),
                                                 prefixLength: 24)))
        #expect(plan.subnets.contains(IPv4Subnet(network: IPv4Address(10, 0, 5, 0),
                                                 prefixLength: 24)))
        #expect(plan.subnets.contains(IPv4Subnet(network: IPv4Address(10, 0, 9, 0),
                                                 prefixLength: 24)))
        // Our own /24, the gateway's /24 (the same one) and the two ARP /24s.
        #expect(plan.subnets.count == 4)
        let message = plan.diagnostics.compactMap(\.userFacingMessage).first { $0.contains("10.0") }
        #expect(message?.contains("4 likely ranges") == true)
    }

    /// Test 42: with the opt-in, a /16 is swept whole — all 65 534 addresses.
    @Test func sweepPlannerSweepsSlashSixteenWithOptIn() throws {
        var configuration = DiscoveryConfiguration.default
        configuration.allowLargeSweep = true
        let plan = try Self.plan([Self.interface("en0", IPv4Address(10, 0, 1, 20),
                                                mask: IPv4Address(255, 255, 0, 0))],
                                 configuration: configuration)
        #expect(plan.hostsPlanned == 65_534)
        #expect(plan.narrowedFrom.isEmpty)
        #expect(plan.estimatedDuration == .seconds(76))     // 12 s + 8 s × 8 doublings
    }

    /// A /22 and narrower is swept in full with no narrowing and no diagnostic.
    @Test func sweepPlannerSweepsSlashTwentyTwoInFull() throws {
        let plan = try Self.plan([Self.interface("en0", IPv4Address(192, 168, 8, 3),
                                                mask: IPv4Address(255, 255, 252, 0))])
        #expect(plan.hostsPlanned == 1_022)
        #expect(plan.narrowedFrom.isEmpty)
        #expect(plan.diagnostics.isEmpty)
    }

    // MARK: - Interface exclusion

    /// Test 43: a VPN tunnel is not swept, and says so; `includeTunnels` puts it back.
    @Test func sweepPlannerSkipsTunnelInterfaces() throws {
        let interfaces = [Self.interface("en0", IPv4Address(192, 168, 1, 10)),
                          Self.interface("utun3", IPv4Address(10, 8, 0, 2))]
        let plan = try Self.plan(interfaces)
        #expect(plan.multicastInterfaces == ["en0"])
        #expect(plan.diagnostics.contains(.tunnelInterfaceSkipped(name: "utun3")))

        var configuration = DiscoveryConfiguration.default
        configuration.includeTunnels = true
        let widened = try Self.plan(interfaces, configuration: configuration)
        #expect(widened.multicastInterfaces == ["en0", "utun3"])
        #expect(widened.subnets.count == 2)
    }

    /// `IFF_POINTOPOINT` is enough on its own — a VPN does not have to be called `utun`.
    @Test func sweepPlannerSkipsPointToPointInterfaces() throws {
        let plan = try Self.plan([Self.interface("en0", IPv4Address(192, 168, 1, 10)),
                                  Self.interface("ppp0", IPv4Address(10, 9, 0, 2),
                                                 pointToPoint: true)])
        #expect(plan.interfaces.map(\.name) == ["en0"])
    }

    /// AWDL and link-local carry no cameras and are dropped without comment.
    @Test func sweepPlannerDropsAWDLAndLinkLocal() throws {
        let plan = try Self.plan([Self.interface("awdl0", IPv4Address(169, 254, 1, 1)),
                                  Self.interface("llw0", IPv4Address(169, 254, 2, 2)),
                                  Self.interface("en0", IPv4Address(192, 168, 1, 10))])
        #expect(plan.interfaces.map(\.name) == ["en0"])
        #expect(plan.diagnostics.isEmpty)
    }

    /// A netmask that is not a contiguous run of bits describes no subnet, so the interface is
    /// unusable — and must not crash the planner.
    @Test func sweepPlannerRejectsNonContiguousNetmask() throws {
        let plan = try Self.plan([Self.interface("en0", IPv4Address(192, 168, 1, 10),
                                                mask: IPv4Address(255, 0, 255, 0)),
                                  Self.interface("en1", IPv4Address(192, 168, 2, 10))])
        #expect(plan.interfaces.map(\.name) == ["en1"])
    }

    /// Test 44: two links onto one LAN sweep once but keep both multicast channels.
    @Test func sweepPlannerDeduplicatesSubnetsButNotMulticast() throws {
        let plan = try Self.plan([Self.interface("en0", IPv4Address(192, 168, 1, 10)),
                                  Self.interface("en1", IPv4Address(192, 168, 1, 11))])
        #expect(plan.subnets.count == 1)
        #expect(plan.hostsPlanned == 254)
        #expect(plan.multicastInterfaces == ["en0", "en1"])
    }

    // MARK: - Modes

    /// `.single` probes exactly one address and skips planning entirely — the post-activation
    /// re-check must not sweep the network again.
    @Test func sweepPlannerSingleModeProbesOneAddress() throws {
        let plan = try Self.plan([], configuration: .single(address: IPv4Address(192, 168, 1, 64)))
        #expect(plan.hostOrder == [IPv4Address(192, 168, 1, 64)])
        #expect(plan.multicastInterfaces.isEmpty)
        #expect(plan.tierAPorts == [554, 80, 8_000, 443, 8_080])
        #expect(plan.estimatedDuration == .seconds(12))
    }

    /// `.multicastOnly` plans no hosts at all: "Refresh" sends no SYNs.
    @Test func sweepPlannerMulticastOnlyPlansNoHosts() throws {
        var configuration = DiscoveryConfiguration.default
        configuration.mode = .multicastOnly
        let plan = try Self.plan([Self.interface("en0", IPv4Address(192, 168, 1, 10))],
                                 configuration: configuration)
        #expect(plan.hostOrder.isEmpty)
        #expect(plan.multicastInterfaces == ["en0"])
        #expect(plan.subnets.count == 1)        // still known, so off-subnet devices are recognised
    }

    /// A user-entered range replaces the interface-derived subnets but is still guarded.
    @Test func sweepPlannerSubnetsModeUsesRequestedRangesUnderTheGuard() throws {
        var configuration = DiscoveryConfiguration.default
        configuration.mode = .subnets([IPv4Subnet(network: IPv4Address(192, 168, 50, 0),
                                                  prefixLength: 24),
                                       IPv4Subnet(network: IPv4Address(172, 16, 0, 0),
                                                  prefixLength: 12)])
        let plan = try Self.plan([Self.interface("en0", IPv4Address(192, 168, 1, 10))],
                                 configuration: configuration)
        #expect(plan.subnets == [IPv4Subnet(network: IPv4Address(192, 168, 50, 0),
                                            prefixLength: 24)])
        #expect(plan.refusedSubnets.first?.prefixLength == 12)
    }

    /// `additionalPorts` extends tier A without duplicating a port already there.
    @Test func sweepPlannerAppendsAdditionalPortsToTierA() throws {
        var configuration = DiscoveryConfiguration.default
        configuration.additionalPorts = [8_899, 80]
        let plan = try Self.plan([Self.interface("en0", IPv4Address(192, 168, 1, 10))],
                                 configuration: configuration)
        #expect(plan.tierAPorts == [554, 80, 8_899])
        #expect(plan.tierAPortProbes == 254 * 3)
    }

    /// The plan knows which addresses belong to it, which is how an off-subnet device is spotted.
    @Test func sweepPlannerPlanContainsOnlyItsOwnSubnets() throws {
        let plan = try Self.plan([Self.interface("en0", IPv4Address(10, 0, 20, 5))])
        #expect(plan.contains(IPv4Address(10, 0, 20, 64)))
        #expect(!plan.contains(IPv4Address(192, 168, 1, 64)))
    }

    // MARK: - Deadlines

    /// §8.3's table, including the cap and the degenerate zero-host case.
    @Test func sweepPlannerDeadlineGrowsPerDoublingAndCaps() {
        #expect(DiscoveryDeadline.overall(hostsPlanned: 0) == .seconds(12))
        #expect(DiscoveryDeadline.overall(hostsPlanned: 1) == .seconds(12))
        #expect(DiscoveryDeadline.overall(hostsPlanned: 254) == .seconds(12))
        #expect(DiscoveryDeadline.overall(hostsPlanned: 508) == .seconds(20))
        #expect(DiscoveryDeadline.overall(hostsPlanned: 1_016) == .seconds(28))
        #expect(DiscoveryDeadline.overall(hostsPlanned: 65_534) == .seconds(76))
        #expect(DiscoveryDeadline.overall(hostsPlanned: 1_000_000_000) == .seconds(180))
        #expect(DiscoveryDeadline.overall(hostsPlanned: -5) == .seconds(12))
    }

    /// Degraded mode gets 40 % longer, still under the ceiling.
    @Test func sweepPlannerDegradedDeadlineIsFortyPercentLonger() {
        #expect(DiscoveryDeadline.degraded(hostsPlanned: 254) == .seconds(12 * 1.4))
        #expect(DiscoveryDeadline.degraded(hostsPlanned: 1_000_000_000) == .seconds(180))
    }
}

// MARK: - Host order

@Suite struct IPv4HostOrderBehaviour {

    /// Test 46: the bit-reversal permutation is a bijection, which is what lets it enumerate a
    /// subnet exactly once.
    @Test func ipv4HostOrderVanDerCorputIsAPermutation() {
        for bits in [1, 4, 8, 10] {
            let span = 1 << bits
            let values = (0..<span).map { IPv4HostOrder.vanDerCorput(index: $0, bits: bits) }
            #expect(Set(values).count == span)
            #expect(values.allSatisfy { $0 >= 0 && $0 < span })
        }
    }

    /// The classic sequence for 8 bits: 0, 128, 64, 192 — maximally spread, not sequential.
    @Test func ipv4HostOrderVanDerCorputSpreadsAcrossTheRange() {
        #expect(IPv4HostOrder.vanDerCorput(index: 0, bits: 8) == 0)
        #expect(IPv4HostOrder.vanDerCorput(index: 1, bits: 8) == 128)
        #expect(IPv4HostOrder.vanDerCorput(index: 2, bits: 8) == 64)
        #expect(IPv4HostOrder.vanDerCorput(index: 3, bits: 8) == 192)
    }

    /// Out-of-range arguments are clamped, never trapped: this runs inside a loop over a subnet.
    @Test func ipv4HostOrderVanDerCorputClampsHostileArguments() {
        #expect(IPv4HostOrder.vanDerCorput(index: -1, bits: 8) == 0)
        #expect(IPv4HostOrder.vanDerCorput(index: 5, bits: 0) == 0)
        #expect(IPv4HostOrder.vanDerCorput(index: 1, bits: 99) >= 0)
    }

    /// Test 45: ARP entries first, then the gateway, then `.64`, then `.65`…`.79`, then `.2`…
    @Test func ipv4HostOrderPutsARPAndSixtyFourFirst() {
        let subnet = IPv4Subnet(network: IPv4Address(192, 168, 1, 0), prefixLength: 24)
        let order = IPv4HostOrder.order(subnet: subnet, hints: [IPv4Address(192, 168, 1, 200)],
                                        gateway: IPv4Address(192, 168, 1, 1))
        #expect(order[0] == IPv4Address(192, 168, 1, 200))
        #expect(order[1] == IPv4Address(192, 168, 1, 1))
        #expect(order[2] == IPv4Address(192, 168, 1, 64))
        #expect(order[3] == IPv4Address(192, 168, 1, 65))
        #expect(order[17] == IPv4Address(192, 168, 1, 79))
        #expect(order[18] == IPv4Address(192, 168, 1, 2))
        #expect(order[19] == IPv4Address(192, 168, 1, 3))
    }

    /// Every usable address appears exactly once, and neither the network nor the broadcast address
    /// is ever probed.
    @Test func ipv4HostOrderIsAPermutationOfUsableHosts() {
        let subnet = IPv4Subnet(network: IPv4Address(192, 168, 1, 0), prefixLength: 24)
        let order = IPv4HostOrder.order(subnet: subnet)
        #expect(order.count == 254)
        #expect(Set(order).count == 254)
        #expect(!order.contains(IPv4Address(192, 168, 1, 0)))
        #expect(!order.contains(IPv4Address(192, 168, 1, 255)))
    }

    /// A hint outside the subnet is ignored: an ARP entry for the router's other-side neighbour must
    /// never be swept.
    @Test func ipv4HostOrderIgnoresHintsOutsideTheSubnet() {
        let subnet = IPv4Subnet(network: IPv4Address(192, 168, 1, 0), prefixLength: 24)
        let order = IPv4HostOrder.order(subnet: subnet, hints: [IPv4Address(172, 16, 4, 4)])
        #expect(order.count == 254)
        #expect(!order.contains(IPv4Address(172, 16, 4, 4)))
    }

    /// The degenerate prefixes: a /31 has both addresses and a /32 has its one.
    @Test func ipv4HostOrderHandlesSlashThirtyOneAndThirtyTwo() {
        let thirtyOne = IPv4Subnet(network: IPv4Address(10, 0, 0, 4), prefixLength: 31)
        #expect(IPv4HostOrder.order(subnet: thirtyOne).count == 2)
        let thirtyTwo = IPv4Subnet(network: IPv4Address(10, 0, 0, 9), prefixLength: 32)
        #expect(IPv4HostOrder.order(subnet: thirtyTwo) == [IPv4Address(10, 0, 0, 9)])
    }

    /// Several subnets concatenate in order and de-duplicate across the seam.
    @Test func ipv4HostOrderDeduplicatesAcrossSubnets() {
        let first = IPv4Subnet(network: IPv4Address(192, 168, 1, 0), prefixLength: 24)
        let order = IPv4HostOrder.order(subnets: [first, first])
        #expect(order.count == 254)
    }
}
