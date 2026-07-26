//
//  IPv4HostOrder.swift
//  VigilDiscovery
//
//  The order a sweep visits addresses in. Not an optimisation: the order is what makes a scan feel
//  alive, and what keeps it from hammering one switch port group.
//  Implements docs/spec-discovery.md §6.2 (host ordering).
//

import VigilProtocols

/// Builds the address order for a sweep.
///
/// Five bands, in this order (§6.2):
///
/// 1. every ARP-cache address inside the subnet — those hosts are provably alive;
/// 2. the interface's gateway;
/// 3. `x.x.x.64` (the Hikvision factory default), then `.65`…`.79` (typical static blocks);
/// 4. `.2`…`.99` ascending — where home and small-office kit actually lives;
/// 5. everything else in bit-reversal (Van der Corput) order, so the scan spreads across the range
///    instead of walking it, and the "found" count climbs steadily rather than in bursts.
///
/// Bands 3 and 4 are stated for a `/24` in the spec and generalise here by last octet, so a `/22`
/// visits all four of its `.64` addresses before it visits any `.100`.
public enum IPv4HostOrder {

    // MARK: - Van der Corput

    /// Bit-reversal permutation of `0..<2^bits`.
    ///
    /// Reverses the low `bits` bits of `index`, which walks a range in maximally-spread order: 0,
    /// 128, 64, 192, … for `bits == 8`. A bijection for every `bits` in `0...31`, which is what lets
    /// it be used to enumerate a subnet exactly once.
    ///
    /// Out-of-range arguments are clamped rather than trapped — this is called in a loop and a trap
    /// in the pure layer is never acceptable. A negative `index` is treated as 0, `bits` above 31 as
    /// 31, and only the low `bits` bits of `index` participate.
    public static func vanDerCorput(index: Int, bits: Int) -> Int {
        let width = min(max(bits, 0), 31)
        guard width > 0 else { return 0 }
        let value = UInt32(truncatingIfNeeded: max(index, 0)) & ((1 << UInt32(width)) - 1)
        var reversed: UInt32 = 0
        for bit in 0..<UInt32(width) where value & (1 << bit) != 0 {
            reversed |= 1 << (UInt32(width) - 1 - bit)
        }
        return Int(reversed)
    }

    // MARK: - Ordering

    /// Materialises the sweep order for one subnet.
    ///
    /// `hints` are addresses known to be alive (ARP entries, typically) and go first; `gateway` goes
    /// straight after them. Hints and gateways outside `subnet` are ignored, so an ARP entry for the
    /// router's neighbour on another network cannot smuggle a foreign address into the plan.
    /// Every returned address is inside `subnet` and usable (network and broadcast excluded for
    /// `/30` and wider), and no address appears twice.
    public static func order(subnet: IPv4Subnet, hints: [IPv4Address] = [],
                             gateway: IPv4Address? = nil) -> [IPv4Address] {
        let hostCount = subnet.usableHostCount
        guard hostCount > 0 else { return [] }

        var emitted = Set<UInt32>(minimumCapacity: hostCount)
        var order: [IPv4Address] = []
        order.reserveCapacity(hostCount)

        let first = subnet.firstUsableHost.rawValue
        let last = subnet.lastUsableHost.rawValue

        func append(_ raw: UInt32) {
            guard raw >= first, raw <= last, emitted.insert(raw).inserted else { return }
            order.append(IPv4Address(rawValue: raw))
        }

        // Band 1: provably alive.
        for hint in hints where subnet.contains(hint) { append(hint.rawValue) }
        // Band 2: the gateway.
        if let gateway, subnet.contains(gateway) { append(gateway.rawValue) }

        // Bands 3 and 4 are cheap to express as last-octet predicates over the whole range, but that
        // is a full pass per band; for a /16 in full-sweep mode that is three extra passes over
        // 65 534 addresses, which is still trivially fast and keeps the code obvious.
        appendMatchingLastOctet(in: 64...64, first: first, last: last, append: append)
        appendMatchingLastOctet(in: 65...79, first: first, last: last, append: append)
        appendMatchingLastOctet(in: 2...99, first: first, last: last, append: append)

        // Band 5: the rest, bit-reversed over the host part.
        let bits = Int(32 - subnet.prefixLength)
        let span = subnet.addressCount
        var index = 0
        while index < span, order.count < hostCount {
            let offset = vanDerCorput(index: index, bits: bits)
            append(subnet.network.rawValue &+ UInt32(truncatingIfNeeded: offset))
            index += 1
        }
        return order
    }

    /// Appends every usable address in `first...last` whose final octet falls in `octets`, ascending.
    private static func appendMatchingLastOctet(in octets: ClosedRange<UInt32>, first: UInt32,
                                                last: UInt32, append: (UInt32) -> Void) {
        guard first <= last else { return }
        // Walk /24 blocks so a wide subnet does not iterate every address once per band.
        var blockBase = first & 0xFFFF_FF00
        while blockBase <= last {
            for octet in octets {
                let candidate = blockBase | octet
                if candidate >= first, candidate <= last { append(candidate) }
            }
            // Stop before wrapping past 255.255.255.0.
            guard blockBase <= 0xFFFF_FF00 &- 256 else { return }
            blockBase &+= 256
        }
    }

    /// The order for several subnets, concatenated in the order given and de-duplicated across them.
    /// Overlapping subnets are legal input (two interfaces on one LAN) and each address is swept
    /// once — one connect per (host, port) per run is a politeness rule, not an optimisation (§6.10).
    public static func order(subnets: [IPv4Subnet], hints: [IPv4Address] = [],
                             gateways: [IPv4Address] = []) -> [IPv4Address] {
        var seen: Set<UInt32> = []
        var result: [IPv4Address] = []
        for subnet in subnets {
            let gateway = gateways.first { subnet.contains($0) }
            for address in order(subnet: subnet, hints: hints, gateway: gateway)
            where seen.insert(address.rawValue).inserted {
                result.append(address)
            }
        }
        return result
    }
}
