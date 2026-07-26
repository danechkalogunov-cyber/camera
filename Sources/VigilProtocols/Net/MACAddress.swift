//
//  MACAddress.swift
//  VigilProtocols
//
//  48-bit IEEE 802 hardware address packed into a UInt64, tolerant of every textual form camera
//  firmware emits, canonicalised to lowercase colon-separated.
//  Implements docs/spec-discovery.md §1.3 (with the OUI hint of §6.9).
//

/// A 48-bit MAC address held in the low 48 bits of a `UInt64`.
///
/// The MAC is the strongest device identity discovery has (§7.1): it survives DHCP address changes,
/// so the merge step keys on it. It arrives as text from three different sources with three different
/// separators, which is why parsing is deliberately liberal about separators and strict about
/// everything else.
public struct MACAddress: Hashable, Sendable, Codable, CustomStringConvertible,
                          LosslessStringConvertible {

    /// The address in the low 48 bits, first octet most significant: `c4:2f:90:ab:cd:ef` is
    /// `0x0000_C42F_90AB_CDEF`. Bits 48...63 are always zero.
    public let rawValue: UInt64

    // MARK: - Construction

    /// Wraps a packed 48-bit value; `nil` when any bit above bit 47 is set, because such a value did
    /// not come from a MAC address and silently truncating it would invent an identity.
    public init?(rawValue: UInt64) {
        guard rawValue >> 48 == 0 else { return nil }
        self.rawValue = rawValue
    }

    /// Builds an address from its six octets, first on the wire first.
    public init(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8, _ b3: UInt8, _ b4: UInt8, _ b5: UInt8) {
        self.rawValue = UInt64(b0) << 40 | UInt64(b1) << 32 | UInt64(b2) << 24
                      | UInt64(b3) << 16 | UInt64(b4) << 8  | UInt64(b5)
    }

    /// Builds an address from a six-element byte collection — an array, a `Data` slice, a
    /// `ByteReader` window.
    ///
    /// Failable rather than precondition-checked on purpose: these bytes routinely come from a parsed
    /// SADP datagram, and a length mismatch is malformed network input, not a programmer error.
    /// Returns `nil` for any count other than 6.
    public init?(bytes: some Collection<UInt8>) {
        guard bytes.count == 6 else { return nil }
        var value: UInt64 = 0
        for byte in bytes {
            value = value << 8 | UInt64(byte)
        }
        self.rawValue = value
    }

    /// Parses every textual form Hikvision, Dahua and Axis firmware emit, case-insensitively:
    ///
    /// * colon-separated — `"c4:2f:90:ab:cd:ef"` (ISAPI, ONVIF scopes);
    /// * hyphen-separated — `"C4-2F-90-AB-CD-EF"` (SADP `<MAC>`, and Windows tooling);
    /// * dot-separated — `"c42f.90ab.cdef"` (switch and router tables);
    /// * bare — `"c42f90abcdef"` (Axis RTSP realms, Bonjour names).
    ///
    /// Returns `nil` unless the text reduces to exactly twelve hex digits. Specifically rejected: a
    /// non-hex character (including whitespace anywhere, `"0x"` prefixes and Unicode digits), eleven
    /// or thirteen digits, mixed separators, a leading, trailing or doubled separator, and groups of
    /// uneven length or of a length other than two or four.
    public init?(_ description: String) {
        var value: UInt64 = 0
        var digitCount = 0
        var separator: UInt8?
        var groupLength = 0
        var expectedGroupLength: Int?

        for byte in description.utf8 {
            if let nibble = Self.hexNibble(byte) {
                guard digitCount < 12 else { return nil }
                value = value << 4 | UInt64(nibble)
                digitCount += 1
                groupLength += 1
            } else if byte == UInt8(ascii: ":") || byte == UInt8(ascii: "-")
                        || byte == UInt8(ascii: ".") {
                // One separator kind per string, never leading, doubled or trailing, groups even.
                if let separator, separator != byte { return nil }
                separator = byte
                guard groupLength > 0 else { return nil }
                if let expectedGroupLength {
                    guard groupLength == expectedGroupLength else { return nil }
                } else {
                    expectedGroupLength = groupLength
                }
                groupLength = 0
            } else {
                return nil
            }
        }

        guard digitCount == 12 else { return nil }
        if let expectedGroupLength {
            // Separated: the final group must match, and only 6×2 and 3×4 groupings are canonical.
            guard groupLength == expectedGroupLength,
                  expectedGroupLength == 2 || expectedGroupLength == 4 else { return nil }
        }
        self.rawValue = value
    }

    /// Maps one ASCII byte to its hex value, or `nil` when it is not a hex digit.
    private static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }

    /// Lowercase hex digit for a nibble; the argument must already be masked to 0...15.
    private static func hexDigit(_ nibble: UInt8) -> UInt8 {
        nibble < 10 ? UInt8(ascii: "0") + nibble : UInt8(ascii: "a") + (nibble - 10)
    }

    // MARK: - Rendering

    /// The six octets, first on the wire first.
    public var bytes: [UInt8] {
        [UInt8(truncatingIfNeeded: rawValue >> 40),
         UInt8(truncatingIfNeeded: rawValue >> 32),
         UInt8(truncatingIfNeeded: rawValue >> 24),
         UInt8(truncatingIfNeeded: rawValue >> 16),
         UInt8(truncatingIfNeeded: rawValue >> 8),
         UInt8(truncatingIfNeeded: rawValue)]
    }

    /// The canonical form: lowercase, colon-separated, always two digits per octet — for example
    /// `"c4:2f:90:ab:cd:ef"` and `"00:00:00:00:00:01"`. Every accepted input spelling renders to this
    /// one, which is what makes it safe as a dictionary key and a log field.
    public var description: String {
        var utf8: [UInt8] = []
        utf8.reserveCapacity(17)
        for shift in stride(from: 40, through: 0, by: -8) {
            if shift != 40 { utf8.append(UInt8(ascii: ":")) }
            let byte = UInt8(truncatingIfNeeded: rawValue >> UInt64(shift))
            utf8.append(Self.hexDigit(byte >> 4))
            utf8.append(Self.hexDigit(byte & 0x0F))
        }
        return String(decoding: utf8, as: UTF8.self)
    }

    // MARK: - Classification

    /// The first octet, whose low two bits carry the multicast and local-administration flags.
    private var firstOctet: UInt8 { UInt8(truncatingIfNeeded: rawValue >> 40) }

    /// The 24-bit IEEE Organizationally Unique Identifier: `0xC4_2F90` for `c4:2f:90:ab:cd:ef`.
    ///
    /// Discovery uses it as a **hint only** (§6.9, weight +10, consulted solely while the vendor is
    /// still `.unknown`) because OUIs are reassigned and OEMs ship other people's NICs.
    public var oui: UInt32 { UInt32(truncatingIfNeeded: rawValue >> 24) & 0x00FF_FFFF }

    /// The OUI as six lowercase hex digits with no separators, e.g. `"c42f90"` — the exact key shape
    /// used by `Resources/oui-seed.json` (§6.9), so a lookup needs no further normalisation.
    public var ouiHex: String {
        var utf8: [UInt8] = []
        utf8.reserveCapacity(6)
        for shift in stride(from: 40, through: 24, by: -8) {
            let byte = UInt8(truncatingIfNeeded: rawValue >> UInt64(shift))
            utf8.append(Self.hexDigit(byte >> 4))
            utf8.append(Self.hexDigit(byte & 0x0F))
        }
        return String(decoding: utf8, as: UTF8.self)
    }

    /// True only for `ff:ff:ff:ff:ff:ff`, the L2 broadcast address. Also multicast by definition.
    public var isBroadcast: Bool { rawValue == 0xFFFF_FFFF_FFFF }

    /// True when the group bit (bit 0 of the first octet) is set — a group destination, never the
    /// hardware address of a camera.
    public var isMulticast: Bool { firstOctet & 0x01 != 0 }

    /// True when the local bit (bit 1 of the first octet) is set. Such an address is assigned by
    /// software rather than by an IEEE OUI, so `oui` carries no vendor meaning and virtualised or
    /// randomised interfaces set it.
    public var isLocallyAdministered: Bool { firstOctet & 0x02 != 0 }

    /// True when this address may be used as a device identity (§7.1). All-zero, broadcast and any
    /// multicast address are never identities: cameras report `00:00:00:00:00:00` when they do not
    /// know their own MAC, and merging two such devices would fuse unrelated cameras into one record.
    public var isUsableIdentity: Bool { rawValue != 0 && !isBroadcast && !isMulticast }

    // MARK: - Codable

    /// Decodes from any accepted textual form and stores the canonical one. Text that does not reduce
    /// to twelve hex digits fails with `DecodingError.dataCorrupted` naming the offending value.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let parsed = MACAddress(text) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "'\(text)' is not a 48-bit MAC address")
        }
        self = parsed
    }

    /// Encodes as the canonical lowercase colon-separated form.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
