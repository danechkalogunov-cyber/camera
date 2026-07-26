//
//  IdentityNormalizer.swift
//  VigilDiscovery
//
//  Normalisation of the two text identity keys — device serial and ONVIF endpoint UUID — so that
//  the same device seen twice yields the same key, and a useless value yields none at all.
//  Implements docs/spec-discovery.md §7.1.
//

/// Turns raw serials and UUIDs into comparison keys.
///
/// Both functions return `nil` rather than a bad key. That asymmetry is deliberate: a missing key
/// costs a duplicate row, which the user can see and ignore, while a wrong key merges two cameras
/// into one and can hand the second device the first one's stored credentials.
public enum IdentityNormalizer {

    /// Normalises a device serial for comparison.
    ///
    /// Uppercases, removes all whitespace and NUL bytes, then strips a trailing four-letter lot code
    /// (`…123456789WCVU`) — for comparison only; the display value is never rewritten. Returns `nil`
    /// when the result is shorter than 8 characters or is a single character repeated, both of which
    /// are firmware placeholders rather than serials (`00000000`, `--------`).
    public static func serialKey(_ raw: String) -> String? {
        var cleaned = ""
        cleaned.reserveCapacity(raw.count)
        for character in raw.uppercased()
        where !character.isWhitespace && character != "\0" && !character.isNewline {
            cleaned.append(character)
        }
        let stripped = strippingLotSuffix(cleaned)
        guard stripped.count >= 8 else { return nil }
        guard let first = stripped.first, !stripped.allSatisfy({ $0 == first }) else { return nil }
        return stripped
    }

    /// Removes a trailing lot code: exactly four A–Z letters preceded by a digit, as in
    /// `DS-7616NI-K2/16P1620201105AAWR123456789WCVU`. Anything else is returned unchanged, because
    /// a serial that merely ends in letters is a serial.
    static func strippingLotSuffix(_ serial: String) -> String {
        guard serial.count >= 13 else { return serial }
        let suffix = serial.suffix(4)
        guard suffix.allSatisfy({ $0.isLetter && $0.isUppercase }) else { return serial }
        let head = serial.dropLast(4)
        guard let last = head.last, last.isNumber else { return serial }
        return String(head)
    }

    /// Normalises an ONVIF `EndpointReference` address for comparison.
    ///
    /// Lowercases, trims whitespace, strips a `urn:uuid:` or `uuid:` prefix, and rejects the
    /// all-zero UUID and anything with no hex content — several firmware families ship the nil UUID,
    /// and treating it as an identity would merge every one of them into a single phantom device.
    public static func onvifKey(_ raw: String) -> String? {
        var text = raw.lowercased().trimmedASCII()
        for prefix in ["urn:uuid:", "uuid:", "urn:"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
            break
        }
        guard text.count >= 8 else { return nil }
        // Reject the nil UUID and any value whose hex digits are all zero.
        let significant = text.filter { $0.isHexDigit }
        guard !significant.isEmpty, significant.contains(where: { $0 != "0" }) else { return nil }
        return text
    }

    /// The trailing 12 hex digits of an ONVIF endpoint UUID, as a MAC.
    ///
    /// Hikvision and Dahua both embed the MAC there (`urn:uuid:2419d68a-2dd2-21b2-a205-c42f90abcdef`
    /// → `c4:2f:90:ab:cd:ef`). Extracted **only** when the value has the 8-4-4-4-12 shape, the tail
    /// parses as a usable MAC, and the OUI is one we recognise — and even then it is a hint that may
    /// corroborate a real MAC, never an identity of its own (§5.6).
    public static func macHint(fromONVIFUUID raw: String) -> MACAddress? {
        guard let key = onvifKey(raw) else { return nil }
        let groups = key.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.count == 5,
              groups.map(\.count) == [8, 4, 4, 4, 12],
              groups.allSatisfy({ $0.allSatisfy(\.isHexDigit) }) else { return nil }
        var text = ""
        for (offset, character) in groups[4].enumerated() {
            if offset > 0, offset % 2 == 0 { text.append(":") }
            text.append(character)
        }
        guard let mac = MACAddress(text), mac.isUsableIdentity,
              VendorClassifier.vendorForOUI(mac) != nil else { return nil }
        return mac
    }
}
