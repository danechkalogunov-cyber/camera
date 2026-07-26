//
//  IPv4SubnetTests.swift
//  VigilProtocolsTests
//
//  CIDR arithmetic, the lazy host sequence, and the sweep guard.
//  Covers docs/spec-discovery.md §6.2, including its test table rows 36-39 (§13.4). Expected values
//  are computed by hand from the CIDR definition; nothing here comes from a live network.
//

import Foundation
import Testing
import VigilProtocols

@Suite struct IPv4SubnetTests {

    /// The address every prefix in the table below is masked from.
    static let base = IPv4Address(192, 168, 1, 64)

    /// One row of the prefix table: everything derivable from `192.168.1.64/<prefixLength>`.
    /// Values are computed by hand from the CIDR definition, not from any tool.
    struct PrefixExpectation: Sendable, CustomStringConvertible {
        let prefixLength: UInt8
        let mask: String
        let network: String
        let broadcast: String
        let wildcard: String
        let addressCount: Int
        let usableHostCount: Int
        let firstHost: String
        let lastHost: String

        var description: String { "/\(prefixLength)" }

        /// Prefixes 0, 1, 8, 16, 24, 30, 31 and 32 — the ends of the range, the classful boundaries, and
        /// the RFC 3021 cases where host-range arithmetic usually breaks.
        static let table: [PrefixExpectation] = [
            .init(prefixLength: 0, mask: "0.0.0.0", network: "0.0.0.0",
                  broadcast: "255.255.255.255", wildcard: "255.255.255.255",
                  addressCount: 4_294_967_296, usableHostCount: 4_294_967_294,
                  firstHost: "0.0.0.1", lastHost: "255.255.255.254"),
            .init(prefixLength: 1, mask: "128.0.0.0", network: "128.0.0.0",
                  broadcast: "255.255.255.255", wildcard: "127.255.255.255",
                  addressCount: 2_147_483_648, usableHostCount: 2_147_483_646,
                  firstHost: "128.0.0.1", lastHost: "255.255.255.254"),
            .init(prefixLength: 8, mask: "255.0.0.0", network: "192.0.0.0",
                  broadcast: "192.255.255.255", wildcard: "0.255.255.255",
                  addressCount: 16_777_216, usableHostCount: 16_777_214,
                  firstHost: "192.0.0.1", lastHost: "192.255.255.254"),
            .init(prefixLength: 16, mask: "255.255.0.0", network: "192.168.0.0",
                  broadcast: "192.168.255.255", wildcard: "0.0.255.255",
                  addressCount: 65_536, usableHostCount: 65_534,
                  firstHost: "192.168.0.1", lastHost: "192.168.255.254"),
            .init(prefixLength: 24, mask: "255.255.255.0", network: "192.168.1.0",
                  broadcast: "192.168.1.255", wildcard: "0.0.0.255",
                  addressCount: 256, usableHostCount: 254,
                  firstHost: "192.168.1.1", lastHost: "192.168.1.254"),
            .init(prefixLength: 30, mask: "255.255.255.252", network: "192.168.1.64",
                  broadcast: "192.168.1.67", wildcard: "0.0.0.3",
                  addressCount: 4, usableHostCount: 2,
                  firstHost: "192.168.1.65", lastHost: "192.168.1.66"),
            // RFC 3021: a /31 has no network or broadcast address, so both addresses are usable.
            .init(prefixLength: 31, mask: "255.255.255.254", network: "192.168.1.64",
                  broadcast: "192.168.1.65", wildcard: "0.0.0.1",
                  addressCount: 2, usableHostCount: 2,
                  firstHost: "192.168.1.64", lastHost: "192.168.1.65"),
            .init(prefixLength: 32, mask: "255.255.255.255", network: "192.168.1.64",
                  broadcast: "192.168.1.64", wildcard: "0.0.0.0",
                  addressCount: 1, usableHostCount: 1,
                  firstHost: "192.168.1.64", lastHost: "192.168.1.64"),
        ]
    }

    // MARK: - Mask and network derivation across the interesting prefixes

    @Test(arguments: PrefixExpectation.table)
    func derivesMaskNetworkBroadcastAndWildcard(_ expected: PrefixExpectation) {
        let subnet = IPv4Subnet(network: Self.base, prefixLength: expected.prefixLength)
        #expect(subnet.prefixLength == expected.prefixLength)
        #expect(subnet.mask.description == expected.mask, "\(expected) mask")
        #expect(subnet.network.description == expected.network, "\(expected) network")
        #expect(subnet.broadcast.description == expected.broadcast, "\(expected) broadcast")
        #expect(subnet.wildcard.description == expected.wildcard, "\(expected) wildcard")
        #expect(subnet.description == "\(expected.network)/\(expected.prefixLength)")
    }

    @Test(arguments: PrefixExpectation.table)
    func countsAndUsableRangePerPrefix(_ expected: PrefixExpectation) {
        let subnet = IPv4Subnet(network: Self.base, prefixLength: expected.prefixLength)
        #expect(subnet.addressCount == expected.addressCount, "\(expected) addressCount")
        #expect(subnet.usableHostCount == expected.usableHostCount, "\(expected) usableHostCount")
        #expect(subnet.firstUsableHost.description == expected.firstHost, "\(expected) first host")
        #expect(subnet.lastUsableHost.description == expected.lastHost, "\(expected) last host")
        #expect(subnet.usableHostRange.lowerBound == subnet.firstUsableHost)
        #expect(subnet.usableHostRange.upperBound == subnet.lastUsableHost)
        #expect(subnet.hosts.count == expected.usableHostCount)
    }

    @Test func slashThirtyOneAndSlashThirtyTwoExcludeNothing() {
        // §13.4 row 38.
        let thirtyOne = IPv4Subnet(network: IPv4Address(10, 0, 0, 8), prefixLength: 31)
        #expect(thirtyOne.addressCount == 2)
        #expect(thirtyOne.usableHostCount == 2)
        #expect(Array(thirtyOne.hosts).map(\.description) == ["10.0.0.8", "10.0.0.9"])

        let thirtyTwo = IPv4Subnet(network: IPv4Address(10, 0, 0, 9), prefixLength: 32)
        #expect(thirtyTwo.addressCount == 1)
        #expect(thirtyTwo.usableHostCount == 1)
        #expect(Array(thirtyTwo.hosts).map(\.description) == ["10.0.0.9"])
        #expect(thirtyTwo.usableHostRange == thirtyTwo.network...thirtyTwo.network)
    }

    @Test func initializerMasksTheGivenAddress() {
        #expect(IPv4Subnet(network: Self.base, prefixLength: 24).description == "192.168.1.0/24")
        // Two spellings of the same range are the same value, which merge and dedupe rely on.
        #expect(IPv4Subnet(network: Self.base, prefixLength: 24)
                    == IPv4Subnet(network: IPv4Address(192, 168, 1, 0), prefixLength: 24))
    }

    @Test func validatingInitializerRejectsAPrefixAboveThirtyTwo() {
        #expect(IPv4Subnet(validating: Self.base, prefixLength: 32) != nil)
        #expect(IPv4Subnet(validating: Self.base, prefixLength: 33) == nil)
        #expect(IPv4Subnet(validating: Self.base, prefixLength: 255) == nil)
    }

    // MARK: - contains

    @Test func containsIsInclusiveAtBothEdges() {
        let subnet = IPv4Subnet(network: IPv4Address(192, 168, 1, 0), prefixLength: 24)
        #expect(subnet.contains(IPv4Address(192, 168, 1, 0)))       // network address
        #expect(subnet.contains(IPv4Address(192, 168, 1, 255)))     // broadcast address
        #expect(subnet.contains(IPv4Address.hikvisionFactoryDefault))
        #expect(!subnet.contains(IPv4Address(192, 168, 0, 255)))    // one below
        #expect(!subnet.contains(IPv4Address(192, 168, 2, 0)))      // one above
    }

    @Test func slashZeroContainsEverythingAndSlashThirtyTwoOnlyItself() {
        let all = IPv4Subnet(network: IPv4Address(rawValue: 0), prefixLength: 0)
        #expect(all.contains(IPv4Address(rawValue: 0)))
        #expect(all.contains(IPv4Address(rawValue: 0xFFFF_FFFF)))
        #expect(all.contains(IPv4Address(8, 8, 8, 8)))

        let single = IPv4Subnet(network: Self.base, prefixLength: 32)
        #expect(single.contains(Self.base))
        #expect(!single.contains(IPv4Address(192, 168, 1, 65)))
        #expect(!single.contains(IPv4Address(192, 168, 1, 63)))
    }

    // MARK: - CIDR text

    @Test func parsesCanonicalCIDR() throws {
        let subnet = try #require(IPv4Subnet(cidr: "192.168.1.0/24"))
        #expect(subnet.network.description == "192.168.1.0")
        #expect(subnet.prefixLength == 24)
        #expect(subnet.description == "192.168.1.0/24")

        // A host address with a prefix is masked, not rejected.
        #expect(IPv4Subnet(cidr: "192.168.1.64/24")?.description == "192.168.1.0/24")
        #expect(IPv4Subnet(cidr: "0.0.0.0/0")?.description == "0.0.0.0/0")
        #expect(IPv4Subnet(cidr: "10.0.20.5/32")?.description == "10.0.20.5/32")
    }

    @Test(arguments: [
        "192.168.1.0/33",       // prefix above 32
        "192.168.1.0/024",      // leading zero in the prefix
        "192.168.1.0/",         // empty prefix
        "192.168.1.0",          // no prefix at all
        "/24",                  // no address
        "192.168.1.0/24/24",    // repeated slash
        "192.168.1.0/-1",       // signed prefix
        "192.168.1.0/2 4",      // embedded whitespace
        " 192.168.1.0/24",      // leading whitespace
        "192.168.1.0/24 ",      // trailing whitespace
        "192.168.1/24",         // malformed address
        "192.168.01.0/24",      // leading zero in the address
        "192.168.1.256/24",     // octet above 255
        "",                     // empty
        "/",                    // just a slash
        "192.168.1.0/999",      // three-digit prefix
    ]) func rejectsMalformedCIDR(_ text: String) {
        #expect(IPv4Subnet(cidr: text) == nil, "'\(text)' must not parse")
    }

    @Test func cidrTextRoundTripsForEveryPrefixLength() throws {
        for prefixLength in UInt8(0)...32 {
            let subnet = IPv4Subnet(network: Self.base, prefixLength: prefixLength)
            #expect(IPv4Subnet(cidr: subnet.description) == subnet, "/\(prefixLength)")
        }
    }

    // MARK: - Address plus netmask, the form the OS gives us

    @Test func buildsFromAddressAndNetmask() throws {
        // §13.4 row 36.
        let subnet = try #require(IPv4Subnet(address: IPv4Address.hikvisionFactoryDefault,
                                            mask: IPv4Address(255, 255, 255, 0)))
        #expect(subnet.description == "192.168.1.0/24")
        #expect(subnet.usableHostCount == 254)
    }

    @Test func acceptsTheExtremeNetmasks() throws {
        let all = try #require(IPv4Subnet(address: Self.base, mask: IPv4Address(0, 0, 0, 0)))
        #expect(all.description == "0.0.0.0/0")
        let single = try #require(IPv4Subnet(address: Self.base,
                                            mask: IPv4Address(255, 255, 255, 255)))
        #expect(single.description == "192.168.1.64/32")
    }

    @Test(arguments: [
        "255.0.255.0",          // §13.4 row 37: holes in the middle
        "0.255.255.255",        // run does not start at the top
        "255.255.255.253",      // 11111101 in the last octet
        "255.255.0.255",
        "128.0.0.1",
        "255.254.255.0",
        "0.0.0.1",
    ]) func rejectsNonContiguousNetmask(_ maskText: String) throws {
        let mask = try #require(IPv4Address(maskText))
        #expect(IPv4Subnet(address: Self.base, mask: mask) == nil, "\(maskText) is not a netmask")
    }

    @Test func everyContiguousNetmaskYieldsItsPrefixLength() throws {
        for prefixLength in UInt8(0)...32 {
            let mask = IPv4Subnet(network: Self.base, prefixLength: prefixLength).mask
            let derived = try #require(IPv4Subnet(address: Self.base, mask: mask))
            #expect(derived.prefixLength == prefixLength, "\(mask) should be /\(prefixLength)")
        }
    }

    // MARK: - The lazy host sequence

    @Test func slashTwentyFourHostsExcludeNetworkAndBroadcast() {
        // §13.4 row 39.
        let subnet = IPv4Subnet(network: IPv4Address(192, 168, 1, 0), prefixLength: 24)
        var count = 0
        var first: IPv4Address?
        var last: IPv4Address?
        for host in subnet.hosts {
            if first == nil { first = host }
            last = host
            count += 1
        }
        #expect(count == 254)
        #expect(first?.description == "192.168.1.1")
        #expect(last?.description == "192.168.1.254")
        #expect(subnet.hosts.underestimatedCount == 254)
    }

    @Test func hostSequenceIsAscendingContiguousAndInsideTheSubnet() {
        let subnet = IPv4Subnet(network: IPv4Address(10, 0, 20, 0), prefixLength: 28)
        var previous: IPv4Address?
        for host in subnet.hosts {
            #expect(subnet.contains(host))
            #expect(host != subnet.network)
            #expect(host != subnet.broadcast)
            if let previous {
                #expect(host.rawValue == previous.rawValue + 1)
            }
            previous = host
        }
        #expect(Array(subnet.hosts).count == 14)
    }

    @Test func hostSequenceIsMultiPass() {
        let subnet = IPv4Subnet(network: IPv4Address(10, 0, 0, 0), prefixLength: 29)
        let sequence = subnet.hosts
        #expect(Array(sequence) == Array(sequence))
        #expect(Array(sequence).count == 6)
    }

    @Test func hostSequenceDoesNotOverflowAtTheTopOfTheAddressSpace() {
        // The step past 255.255.255.255 must not trap; `remaining` is what stops the iterator.
        let top = IPv4Subnet(network: IPv4Address(255, 255, 255, 254), prefixLength: 31)
        #expect(Array(top.hosts).map(\.description) == ["255.255.255.254", "255.255.255.255"])

        let last = IPv4Subnet(network: IPv4Address(255, 255, 255, 255), prefixLength: 32)
        #expect(Array(last.hosts).map(\.description) == ["255.255.255.255"])

        let block = IPv4Subnet(network: IPv4Address(255, 255, 255, 248), prefixLength: 29)
        #expect(Array(block.hosts).last?.description == "255.255.255.254")
    }

    // MARK: - The sweep guard (§6.2)

    @Test func policyMatchesTheSpecifiedThresholds() {
        #expect(SweepPolicy.minimumPrefixLength == 16)
        #expect(SweepPolicy.confirmationPrefixLength == 22)
        #expect(SweepPolicy.narrowedPrefixLength == 24)
    }

    @Test func refusesASlashEightOutright() throws {
        // 16 777 214 connect attempts. §13.4 row 40 makes the same demand of a /15.
        let subnet = IPv4Subnet(network: IPv4Address(10, 0, 0, 0), prefixLength: 8)
        do {
            let scope = try subnet.sweepScope(hints: [IPv4Address(10, 0, 5, 7)])
            Issue.record("a /8 must not be sweepable, got \(scope)")
        } catch {
            #expect(error == .prefixTooWide(subnet: subnet,
                                            hostCount: 16_777_214,
                                            minimumPrefixLength: 16))
            #expect(error.description
                        == "subnet 10.0.0.0/8 has 16777214 hosts; sweeping requires /16 or narrower")
        }
    }

    @Test(arguments: [UInt8(0), 1, 8, 12, 15]) func refusesEveryPrefixWiderThanSixteen(
        _ prefixLength: UInt8
    ) {
        let subnet = IPv4Subnet(network: IPv4Address(10, 0, 0, 0), prefixLength: prefixLength)
        #expect(throws: SweepGuardError.self) {
            try subnet.sweepScope()
        }
    }

    @Test func narrowsASlashTwentyToTheSlashTwentyFoursWithHints() throws {
        // 10.0.0.0/20 spans 10.0.0.0 - 10.0.15.255. Hints stand in for the interface address and the
        // ARP cache; only the /24s they fall in are worth 254 connects each.
        let subnet = IPv4Subnet(network: IPv4Address(10, 0, 0, 0), prefixLength: 20)
        let hints = [
            IPv4Address(10, 0, 9, 200),      // out of order on purpose
            IPv4Address(10, 0, 5, 7),
            IPv4Address(10, 0, 5, 99),       // same /24 as the previous hint: must dedupe
            IPv4Address(10, 0, 0, 1),        // the gateway
            IPv4Address(172, 16, 4, 4),      // outside the subnet: ignored
            IPv4Address(10, 0, 16, 1),       // just outside the /20: ignored
        ]
        let scope = try subnet.sweepScope(hints: hints)
        #expect(scope == .narrowed(from: subnet, to: [
            IPv4Subnet(network: IPv4Address(10, 0, 0, 0), prefixLength: 24),
            IPv4Subnet(network: IPv4Address(10, 0, 5, 0), prefixLength: 24),
            IPv4Subnet(network: IPv4Address(10, 0, 9, 0), prefixLength: 24),
        ]))
        #expect(scope.subnets.map(\.description) == ["10.0.0.0/24", "10.0.5.0/24", "10.0.9.0/24"])
        #expect(scope.plannedHostCount == 3 * 254)
    }

    @Test func narrowsASlashSixteenAndFallsBackToTheFirstSlashTwentyFourWithoutHints() throws {
        let subnet = IPv4Subnet(network: IPv4Address(10, 1, 0, 0), prefixLength: 16)
        let scope = try subnet.sweepScope()
        #expect(scope == .narrowed(from: subnet, to: [
            IPv4Subnet(network: IPv4Address(10, 1, 0, 0), prefixLength: 24),
        ]))
        #expect(scope.plannedHostCount == 254)
        // Hints that all fall outside the subnet are the same as no hints at all.
        let outside = try subnet.sweepScope(hints: [IPv4Address(192, 168, 1, 64)])
        #expect(outside == scope)
    }

    @Test(arguments: [UInt8(16), 17, 20, 21]) func narrowsEveryPrefixBetweenSixteenAndTwentyOne(
        _ prefixLength: UInt8
    ) throws {
        let subnet = IPv4Subnet(network: IPv4Address(10, 0, 0, 0), prefixLength: prefixLength)
        let scope = try subnet.sweepScope(hints: [IPv4Address(10, 0, 0, 42)])
        #expect(scope == .narrowed(from: subnet, to: [
            IPv4Subnet(network: IPv4Address(10, 0, 0, 0), prefixLength: 24),
        ]))
    }

    @Test(arguments: [UInt8(22), 23, 24, 28, 30, 31, 32]) func sweepsNarrowSubnetsInFull(
        _ prefixLength: UInt8
    ) throws {
        let subnet = IPv4Subnet(network: IPv4Address(192, 168, 1, 0), prefixLength: prefixLength)
        let scope = try subnet.sweepScope(hints: [IPv4Address(192, 168, 1, 64)])
        #expect(scope == .full(subnet))
        #expect(scope.subnets == [subnet])
        #expect(scope.plannedHostCount == subnet.usableHostCount)
    }

    @Test func fullSweepOfASlashTwentyFourPlansTwoHundredFiftyFourHosts() throws {
        let subnet = IPv4Subnet(network: IPv4Address(192, 168, 1, 0), prefixLength: 24)
        let scope = try subnet.sweepScope()
        #expect(scope.plannedHostCount == 254)
        #expect(scope.description == "full 192.168.1.0/24")
    }

    // MARK: - Hashable and Codable

    @Test func equalRangesHashEqually() {
        let a = IPv4Subnet(network: IPv4Address(192, 168, 1, 64), prefixLength: 24)
        let b = IPv4Subnet(network: IPv4Address(192, 168, 1, 200), prefixLength: 24)
        let c = IPv4Subnet(network: IPv4Address(192, 168, 1, 0), prefixLength: 25)
        #expect(Set([a, b, c]).count == 2)
    }

    @Test func codableUsesCanonicalCIDRText() throws {
        let subnet = IPv4Subnet(network: Self.base, prefixLength: 24)
        let json = try JSONEncoder().encode([subnet])
        // Not an exact string match: whether an encoder escapes "/" is its business, not ours.
        #expect(String(decoding: json, as: UTF8.self).contains("192.168.1.0"))
        #expect(try JSONDecoder().decode([IPv4Subnet].self, from: json) == [subnet])
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode([IPv4Subnet].self, from: Data("[\"192.168.1.0/33\"]".utf8))
        }
    }
}
