//
//  IPv4Subnet.swift
//  VigilProtocols
//
//  CIDR arithmetic as pure integer maths — masks, ranges, a lazy host sequence — plus the sweep
//  guard that refuses to enumerate a subnet wide enough to look like an attack.
//  Implements docs/spec-discovery.md §6.2. No sockets are involved anywhere in this file.
//

// MARK: - IPv4Subnet

/// An IPv4 subnet: a network address plus a prefix length.
///
/// `network` is always already masked, so two subnets that denote the same range are `==` however
/// they were spelled (`192.168.1.0/24` and `192.168.1.64/24` construct the same value). Everything
/// here is integer arithmetic on `IPv4Address.rawValue`; nothing touches the network stack, which is
/// what lets the whole sweep planner be unit-tested on Linux.
public struct IPv4Subnet: Hashable, Sendable, Codable, CustomStringConvertible {

    /// The network address, already masked to `prefixLength`.
    public let network: IPv4Address

    /// The prefix length in bits, always `0...32`.
    public let prefixLength: UInt8

    // MARK: Construction

    /// Masks `network` down to `prefixLength` and stores both.
    ///
    /// A `prefixLength` above 32 cannot describe an IPv4 subnet. Rather than trap — the pure layer
    /// never traps — it is clamped to 32 and this initializer stays total, so callers with a
    /// compile-time-known prefix need no `guard`. Prefixes that arrive as *data* (from text, or from
    /// the OS's netmask) must instead go through `init?(cidr:)`, `init?(address:mask:)` or
    /// `init?(validating:prefixLength:)`, all of which reject an out-of-range value outright.
    public init(network: IPv4Address, prefixLength: UInt8) {
        let clamped = min(prefixLength, 32)
        self.prefixLength = clamped
        self.network = IPv4Address(rawValue: network.rawValue & Self.maskBits(for: clamped))
    }

    /// Validating form of `init(network:prefixLength:)`: `nil` when `prefixLength` is above 32.
    /// Use this whenever the prefix length was parsed or received rather than written in source.
    public init?(validating network: IPv4Address, prefixLength: UInt8) {
        guard prefixLength <= 32 else { return nil }
        self.init(network: network, prefixLength: prefixLength)
    }

    /// Builds a subnet from an address and a dotted-quad netmask — the shape macOS hands us for each
    /// interface (§6.1), where the mask is authoritative and the prefix length must be derived.
    ///
    /// Returns `nil` when `mask` is not a valid netmask, i.e. when its set bits are not a single
    /// contiguous run from the top (`255.0.255.0` → `nil`). Both `0.0.0.0` (`/0`) and
    /// `255.255.255.255` (`/32`) are valid.
    public init?(address: IPv4Address, mask: IPv4Address) {
        let bits = mask.rawValue
        // A contiguous high run m satisfies: ~m + 1 is a power of two, i.e. (~m + 1) & ~m == 0.
        // Wrapping add so ~m == 0xFFFF_FFFF (mask 0.0.0.0) does not overflow.
        let complement = ~bits
        guard (complement &+ 1) & complement == 0 else { return nil }
        self.init(network: address, prefixLength: UInt8(bits.nonzeroBitCount))
    }

    /// Strict CIDR parse of exactly `<dotted-quad>/<prefix>`, e.g. `"192.168.1.0/24"`.
    ///
    /// The address part is parsed by `IPv4Address.init?(_:)` and inherits all of its strictness. The
    /// prefix part must be one or two decimal digits with no leading zero and no sign, and must be
    /// `0...32`. Returns `nil` for a missing or repeated `/`, an empty prefix, `"/33"`, `"/024"`,
    /// surrounding whitespace, or a bare address with no prefix at all.
    public init?(cidr: String) {
        var addressText = ""
        var prefixText = ""
        var sawSlash = false
        for character in cidr {
            if character == "/" {
                guard !sawSlash else { return nil }
                sawSlash = true
            } else if sawSlash {
                prefixText.append(character)
            } else {
                addressText.append(character)
            }
        }
        guard sawSlash, let address = IPv4Address(addressText) else { return nil }

        // Prefix: 1-2 digits, no leading zero unless the whole prefix is "0".
        var prefix = 0
        var digitCount = 0
        for byte in prefixText.utf8 {
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
            guard digitCount < 2, !(digitCount == 1 && prefix == 0) else { return nil }
            prefix = prefix * 10 + Int(byte - UInt8(ascii: "0"))
            digitCount += 1
        }
        guard digitCount > 0, prefix <= 32 else { return nil }
        self.init(network: address, prefixLength: UInt8(prefix))
    }

    // MARK: Derived addresses

    /// Netmask bits for a prefix length; the argument must be `0...32`.
    private static func maskBits(for prefixLength: UInt8) -> UInt32 {
        // Swift's `<<` is a smart shift: an over-shift yields 0, so /0 needs no special case.
        prefixLength == 0 ? 0 : ~UInt32(0) << (32 - UInt32(prefixLength))
    }

    /// The netmask, e.g. `255.255.255.0` for a `/24`. `/0` is `0.0.0.0`; `/32` is `255.255.255.255`.
    public var mask: IPv4Address { IPv4Address(rawValue: Self.maskBits(for: prefixLength)) }

    /// The inverse of `mask` (a "wildcard" or hostmask), e.g. `0.0.0.255` for a `/24`. This is the
    /// host part of the address, which is what the sweep iterates over.
    public var wildcard: IPv4Address { IPv4Address(rawValue: ~Self.maskBits(for: prefixLength)) }

    /// The all-ones address of the range, e.g. `192.168.1.255` for `192.168.1.0/24`.
    ///
    /// For `/31` this is the second of the two addresses and for `/32` it equals `network`; neither
    /// has a broadcast address in the routing sense (RFC 3021), so treat it as "last address" there.
    public var broadcast: IPv4Address {
        IPv4Address(rawValue: network.rawValue | ~Self.maskBits(for: prefixLength))
    }

    // MARK: Counts and ranges

    /// Every address in the range, including network and broadcast: `2^(32 - prefixLength)`.
    /// `/32` is 1, `/24` is 256, `/0` is 4 294 967 296.
    public var addressCount: Int {
        Int(clamping: UInt64(1) << (32 - UInt64(prefixLength)))
    }

    /// Addresses a sweep may actually connect to.
    ///
    /// Network and broadcast are excluded for `prefixLength <= 30`, so a `/24` has 254. A `/31` has
    /// both of its addresses (RFC 3021 point-to-point) and a `/32` its single address, because
    /// excluding them would leave nothing to scan.
    public var usableHostCount: Int {
        prefixLength >= 31 ? addressCount : addressCount - 2
    }

    /// The lowest address a sweep may connect to: `network + 1` for `/0...30`, `network` for `/31`
    /// and `/32`.
    public var firstUsableHost: IPv4Address {
        prefixLength >= 31 ? network : IPv4Address(rawValue: network.rawValue &+ 1)
    }

    /// The highest address a sweep may connect to: `broadcast - 1` for `/0...30`, `broadcast` for
    /// `/31` and `/32`.
    public var lastUsableHost: IPv4Address {
        prefixLength >= 31 ? broadcast : IPv4Address(rawValue: broadcast.rawValue &- 1)
    }

    /// The inclusive range of connectable addresses. Never empty: for `/32` it is the single address.
    public var usableHostRange: ClosedRange<IPv4Address> { firstUsableHost...lastUsableHost }

    /// True when `address` falls inside this subnet, network and broadcast included.
    public func contains(_ address: IPv4Address) -> Bool {
        address.rawValue & Self.maskBits(for: prefixLength) == network.rawValue
    }

    /// The connectable addresses in ascending order, lazily.
    ///
    /// Nothing is materialised: the sequence is two integers and its iterator is a `struct`, so a
    /// `/24` sweep — or even a `/16` behind an explicit opt-in — costs no allocation and no array.
    public var hosts: IPv4HostSequence {
        IPv4HostSequence(first: firstUsableHost.rawValue, count: usableHostCount)
    }

    // MARK: Description and Codable

    /// Canonical CIDR text, e.g. `"192.168.1.0/24"`. Round-trips through `init?(cidr:)`.
    public var description: String { "\(network)/\(prefixLength)" }

    /// Decodes canonical CIDR text. Anything `init?(cidr:)` rejects fails with
    /// `DecodingError.dataCorrupted` naming the offending value.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let parsed = IPv4Subnet(cidr: text) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "'\(text)' is not an IPv4 CIDR subnet")
        }
        self = parsed
    }

    /// Encodes as canonical CIDR text.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

// MARK: - Lazy host enumeration

/// A lazy, allocation-free `Sequence` of the connectable addresses of an `IPv4Subnet`, ascending.
///
/// Obtained from `IPv4Subnet.hosts`. Multi-pass and side-effect-free: iterating twice yields the same
/// addresses, since the sequence stores only a start and a count.
public struct IPv4HostSequence: Sequence, Sendable {

    /// Host-order value of the first address yielded.
    private let first: UInt32

    /// Number of addresses yielded. Exactly `IPv4Subnet.usableHostCount`.
    public let count: Int

    init(first: UInt32, count: Int) {
        self.first = first
        self.count = count
    }

    /// Exact, not an estimate — enough for a caller to size a progress bar without iterating.
    public var underestimatedCount: Int { count }

    public func makeIterator() -> IPv4HostIterator {
        IPv4HostIterator(next: first, remaining: count)
    }
}

/// Iterator over `IPv4HostSequence`. A `struct` rather than an `AnyIterator` box so that stepping a
/// 65 534-address range allocates nothing at all.
public struct IPv4HostIterator: IteratorProtocol, Sendable {

    /// Host-order value of the address the next call to `next()` will yield.
    private var nextValue: UInt32

    /// Addresses still to be produced. This, not `nextValue`, decides when iteration ends.
    private var remaining: Int

    init(next: UInt32, remaining: Int) {
        self.nextValue = next
        self.remaining = remaining
    }

    /// Yields the next address, or `nil` once `remaining` addresses have been produced.
    ///
    /// The increment wraps deliberately: a subnet ending at `255.255.255.255` would otherwise
    /// overflow `UInt32` on the step past its last address. `remaining` is the authority on when to
    /// stop, so the wrapped value is never observed.
    public mutating func next() -> IPv4Address? {
        guard remaining > 0 else { return nil }
        remaining -= 1
        let value = nextValue
        nextValue = nextValue &+ 1
        return IPv4Address(rawValue: value)
    }
}

// MARK: - The sweep guard

/// Hard limits on what a subnet sweep is allowed to enumerate (§6.2). Not user-overridable.
public enum SweepPolicy: Sendable {

    /// Prefixes shorter than this are refused outright by `IPv4Subnet.sweepScope(hints:)`.
    ///
    /// A `/15` is 131 070 hosts and a `/8` is 16 777 214: at any polite rate that is hours of SYNs
    /// aimed at a network the user may not own, and it is indistinguishable from a port scan to any
    /// IDS watching. There is no flag that lifts this.
    public static let minimumPrefixLength: UInt8 = 16

    /// At this prefix length and longer a subnet is swept in full (a `/22` is 1 022 hosts). Between
    /// `minimumPrefixLength` and here, a sweep is narrowed to likely `/24`s instead.
    public static let confirmationPrefixLength: UInt8 = 22

    /// The prefix length a wide subnet is narrowed to. `/24` is the unit users think in and the unit
    /// cameras are actually deployed on.
    public static let narrowedPrefixLength: UInt8 = 24
}

/// Why a subnet may not be swept.
public enum SweepGuardError: Error, Sendable, Equatable, CustomStringConvertible {

    /// The subnet is wider than `SweepPolicy.minimumPrefixLength`. Carries the offending subnet and
    /// its host count so the refusal can be explained in a log line and in the UI without recomputing
    /// anything. Callers drop the subnet from the plan and emit `subnetTooWide`; they never retry.
    case prefixTooWide(subnet: IPv4Subnet, hostCount: Int, minimumPrefixLength: UInt8)

    public var description: String {
        switch self {
        case let .prefixTooWide(subnet, hostCount, minimum):
            "subnet \(subnet) has \(hostCount) hosts; sweeping requires /\(minimum) or narrower"
        }
    }
}

/// What a sweep of a given subnet is permitted to cover.
public enum SweepScope: Sendable, Equatable, CustomStringConvertible {

    /// Sweep the subnet as-is; it is small enough.
    case full(IPv4Subnet)

    /// The subnet is legal but large: sweep only these narrower subnets. `to` is never empty, is
    /// deduplicated, and is in ascending network order.
    case narrowed(from: IPv4Subnet, to: [IPv4Subnet])

    /// The subnets a sweep should actually enumerate, whichever case this is.
    public var subnets: [IPv4Subnet] {
        switch self {
        case let .full(subnet): [subnet]
        case let .narrowed(_, subnets): subnets
        }
    }

    /// Total connectable addresses across `subnets` — the number to plan a budget against.
    public var plannedHostCount: Int {
        subnets.reduce(0) { $0 + $1.usableHostCount }
    }

    public var description: String {
        switch self {
        case let .full(subnet):
            "full \(subnet)"
        case let .narrowed(from, subnets):
            "narrowed \(from) to [\(subnets.map(\.description).joined(separator: ", "))]"
        }
    }
}

extension IPv4Subnet {

    /// Decides what a sweep of this subnet may cover, refusing anything dangerously wide (§6.2).
    ///
    /// The guard lives here, on the type, and not in the caller: a sweep of a `/8` is 16 777 214
    /// connect attempts on the user's own network, and "the caller will remember to check" is not a
    /// safety property. Every enumeration path goes through this method.
    ///
    /// * `prefixLength < SweepPolicy.minimumPrefixLength` (wider than `/16`) — throws
    ///   `.prefixTooWide`. Hard refusal, not user-overridable.
    /// * `/16` through `/21` — returns `.narrowed`, listing the `/24`s worth sweeping instead of the
    ///   whole range: every `/24` that contains one of `hints`, deduplicated and ascending. Hints
    ///   outside this subnet are ignored. Pass the interface's own address, its gateway and every
    ///   ARP-cache entry: those are the ranges where a camera has actually been seen. With no hint
    ///   inside the subnet, the single `/24` at the start of the range is returned so the caller still
    ///   has something to sweep rather than nothing.
    /// * `/22` and narrower — returns `.full`.
    ///
    /// Sweeping a wide subnet in full is a deliberate, separate decision (`allowLargeSweep`) that a
    /// caller expresses by sweeping the `/24`s it chooses, never by bypassing this method.
    public func sweepScope(hints: some Sequence<IPv4Address>) throws(SweepGuardError) -> SweepScope {
        guard prefixLength >= SweepPolicy.minimumPrefixLength else {
            throw SweepGuardError.prefixTooWide(
                subnet: self,
                hostCount: usableHostCount,
                minimumPrefixLength: SweepPolicy.minimumPrefixLength)
        }
        guard prefixLength < SweepPolicy.confirmationPrefixLength else {
            return .full(self)
        }

        var seen: Set<UInt32> = []
        var narrowed: [IPv4Subnet] = []
        for hint in hints where contains(hint) {
            let candidate = IPv4Subnet(network: hint, prefixLength: SweepPolicy.narrowedPrefixLength)
            if seen.insert(candidate.network.rawValue).inserted {
                narrowed.append(candidate)
            }
        }
        if narrowed.isEmpty {
            narrowed = [IPv4Subnet(network: network, prefixLength: SweepPolicy.narrowedPrefixLength)]
        } else {
            narrowed.sort { $0.network < $1.network }
        }
        return .narrowed(from: self, to: narrowed)
    }

    /// `sweepScope(hints:)` with no hints: a `/16`...`/21` narrows to the first `/24` of the range.
    public func sweepScope() throws(SweepGuardError) -> SweepScope {
        try sweepScope(hints: EmptyCollection<IPv4Address>())
    }
}
