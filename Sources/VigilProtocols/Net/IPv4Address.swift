//
//  IPv4Address.swift
//  VigilProtocols
//
//  Host-order IPv4 address as a UInt32-backed value type: strict dotted-quad parsing, canonical
//  rendering, and the address classification helpers camera discovery needs.
//  Implements docs/spec-discovery.md §1.3.
//

/// A host-order IPv4 address.
///
/// Deliberately **not** `Network.IPv4Address`: that type does not exist on Linux and the pure layer
/// may not import `Network`. In `VigilTransport` files that import both modules the two names
/// collide, so spell ours out there — `VigilProtocols.IPv4Address` vs `Network.IPv4Address`.
///
/// `rawValue` is host byte order, so `192.168.1.64` is `0xC0A8_0140`. Numeric order is therefore
/// address order and `Comparable` compares `rawValue` directly, which is what subnet arithmetic and
/// the stable sort of discovery results rely on.
public struct IPv4Address: Hashable, Sendable, Codable, CustomStringConvertible,
                           LosslessStringConvertible, Comparable {

    /// The address as a host-order 32-bit integer: `192.168.1.64 == 0xC0A8_0140`.
    public let rawValue: UInt32

    // MARK: - Construction

    /// Wraps a host-order integer. Every `UInt32` denotes some IPv4 address, so this cannot fail.
    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Builds an address from its four octets, most significant first: `IPv4Address(192, 168, 1, 64)`.
    public init(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) {
        self.rawValue = UInt32(a) << 24 | UInt32(b) << 16 | UInt32(c) << 8 | UInt32(d)
    }

    /// Strict dotted-quad parse; `nil` for anything that is not exactly four canonical decimal octets.
    ///
    /// Rejected, in every case by returning `nil` rather than guessing:
    ///
    /// * the empty string, and any string with leading or trailing whitespace (`" 1.2.3.4"`);
    /// * fewer or more than four components (`"1.2.3"`, `"1.2.3.4.5"`), and an empty component;
    /// * a component with more than three digits, or a value above 255 (`"256.1.1.1"`);
    /// * a component with a leading zero (`"01.2.3.4"`, `"1.2.3.00"`) — some resolvers read those as
    ///   octal, so accepting them would let two spellings denote different addresses;
    /// * any character that is not a digit or a dot, including a sign (`"1.2.3.-1"`), hex digits and
    ///   an embedded NUL.
    ///
    /// Nothing here allocates: the parse walks the UTF-8 view a byte at a time.
    public init?(_ description: String) {
        var value: UInt32 = 0
        var octetCount = 0          // dots consumed so far
        var digitCount = 0          // digits in the component being read
        var component: UInt32 = 0
        var componentStartsWithZero = false

        for byte in description.utf8 {
            switch byte {
            case UInt8(ascii: "."):
                // A dot must follow a digit, and only three of them may appear.
                guard digitCount > 0, octetCount < 3 else { return nil }
                value = value << 8 | component
                octetCount += 1
                digitCount = 0
                component = 0
                componentStartsWithZero = false

            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                guard !componentStartsWithZero, digitCount < 3 else { return nil }
                component = component * 10 + UInt32(byte - UInt8(ascii: "0"))
                digitCount += 1
                guard component <= 255 else { return nil }
                componentStartsWithZero = (component == 0 && digitCount == 1)

            default:
                return nil
            }
        }

        guard octetCount == 3, digitCount > 0 else { return nil }
        self.rawValue = value << 8 | component
    }

    // MARK: - Rendering

    /// The four octets, most significant first.
    public var octets: (UInt8, UInt8, UInt8, UInt8) {
        (UInt8(truncatingIfNeeded: rawValue >> 24),
         UInt8(truncatingIfNeeded: rawValue >> 16),
         UInt8(truncatingIfNeeded: rawValue >> 8),
         UInt8(truncatingIfNeeded: rawValue))
    }

    /// Canonical dotted quad with no leading zeros, e.g. `"192.168.1.64"`. Round-trips through
    /// `init?(_:)` for every possible value.
    public var description: String {
        let octets = self.octets
        return "\(octets.0).\(octets.1).\(octets.2).\(octets.3)"
    }

    // MARK: - Classification

    /// True for the RFC 1918 private blocks `10/8`, `172.16/12` and `192.168/16` — the only ranges a
    /// camera on a home or small-office LAN is normally reachable on.
    public var isPrivate: Bool {
        rawValue >> 24 == 10 || rawValue >> 20 == 0xAC1 || rawValue >> 16 == 0xC0A8
    }

    /// True for `127/8`. A camera never lives here; discovery skips loopback interfaces.
    public var isLoopback: Bool { rawValue >> 24 == 127 }

    /// True for `169.254/16` (RFC 3927). A camera with this address failed DHCP and self-assigned,
    /// which the UI reports as a network fault rather than a camera fault.
    public var isLinkLocal: Bool { rawValue >> 16 == 0xA9FE }

    /// True for `224/4` (RFC 5771), which includes the SADP group `239.255.255.250` and the
    /// WS-Discovery group `239.255.255.250`. Never a unicast destination.
    public var isMulticast: Bool { rawValue >> 28 == 0xE }

    /// True only for the limited broadcast address `255.255.255.255`. Per-subnet broadcast addresses
    /// are not detectable from an address alone — ask `IPv4Subnet.broadcast`.
    public var isBroadcast: Bool { rawValue == 0xFFFF_FFFF }

    /// True only for `0.0.0.0`, which SADP and ISAPI both emit for "no address configured".
    public var isUnspecified: Bool { rawValue == 0 }

    // MARK: - Well-known addresses

    /// `0.0.0.0` — the unspecified address, and the wildcard bind address.
    public static let unspecified = IPv4Address(rawValue: 0)

    /// `127.0.0.1`.
    public static let loopback = IPv4Address(127, 0, 0, 1)

    /// `255.255.255.255` — limited broadcast.
    public static let broadcast = IPv4Address(rawValue: 0xFFFF_FFFF)

    /// `239.255.255.250` — the group both SADP (§4.1) and WS-Discovery (§5.1) probe on.
    public static let discoveryMulticastGroup = IPv4Address(239, 255, 255, 250)

    /// `192.168.1.64` — the Hikvision factory-default address.
    ///
    /// An unactivated camera out of the box answers here, on a `192.168.1.0/24` of its own making.
    /// First run references it twice: the off-subnet explanation in §4.7 (a factory camera seen by
    /// multicast on a `10.x` LAN is *not* connectable), and the sweep host order in §6.2, which tries
    /// `x.x.x.64` before the rest of a subnet.
    public static let hikvisionFactoryDefault = IPv4Address(192, 168, 1, 64)

    // MARK: - Comparable

    /// Numeric order on `rawValue`, which is ascending address order.
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    // MARK: - Codable

    /// Decodes the dotted-quad *string* form, so persisted libraries and diagnostics stay readable.
    /// A value that is not a strict dotted quad — including a JSON number — fails with
    /// `DecodingError.dataCorrupted` naming the offending text.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let parsed = IPv4Address(text) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "'\(text)' is not a dotted-quad IPv4 address")
        }
        self = parsed
    }

    /// Encodes as the canonical dotted quad, e.g. `"192.168.1.64"`.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
