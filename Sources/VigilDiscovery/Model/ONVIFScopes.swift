//
//  ONVIFScopes.swift
//  VigilDiscovery
//
//  The ONVIF scope-URI model: the handful of `onvif://…` strings a WS-Discovery ProbeMatch carries,
//  percent-decoded and sorted into name, hardware, location, profiles and types.
//  Implements docs/spec-discovery.md §3 and §5.6.
//

import VigilProtocols

// MARK: - ONVIFScopes

/// The interpreted contents of an ONVIF `Scopes` list.
///
/// Every scope is a URI such as `onvif://www.onvif.org/name/HIKVISION%20DS-2CD2143G0-I`. Values are
/// percent-decoded before interpretation, and every scope — recognised or not — is preserved in
/// `raw` so a future ONVIF module loses nothing.
public struct ONVIFScopes: Sendable, Hashable, Codable {

    /// `/name/<v>` — used as `displayName` when no stronger source supplied one.
    public var name: String?
    /// `/hardware/<v>` — used as `model` when no stronger source supplied one.
    public var hardware: String?
    /// `/location/<v>` or `/location/country/<v>` — the deepest segment, verbatim.
    public var location: String?
    /// `/Profile/<v>` values in the order seen, e.g. `["Streaming", "G", "T"]`.
    public var profiles: [String]
    /// `/type/<v>` values in the order seen, e.g. `["Network_Video_Transmitter", "video_encoder"]`.
    public var types: [String]
    /// A MAC from the non-standard `/MAC/<v>` scope. A **hint only**: it never forms an identity.
    public var macHint: MACAddress?
    /// Every percent-decoded scope URI, order preserved, nothing discarded.
    public var raw: [String]

    /// Memberwise initializer with empty defaults, so a caller that only learned one scope does not
    /// have to spell out the rest.
    public init(name: String? = nil, hardware: String? = nil, location: String? = nil,
                profiles: [String] = [], types: [String] = [], macHint: MACAddress? = nil,
                raw: [String] = []) {
        self.name = name
        self.hardware = hardware
        self.location = location
        self.profiles = profiles
        self.types = types
        self.macHint = macHint
        self.raw = raw
    }

    /// True when the scopes claim pan/tilt/zoom: `type/ptz`, or ONVIF Profile S together with a
    /// hardware string that names a dome. Promotes `deviceClass` to `.ptzCamera` (§5.6).
    public var indicatesPTZ: Bool {
        if types.contains(where: { $0.lowercased().contains("ptz") }) { return true }
        guard profiles.contains(where: { $0.uppercased() == "S" }), let hardware else { return false }
        let upper = hardware.uppercased()
        return upper.contains("PTZ") || upper.contains("DOME") || upper.contains("SPEED")
    }

    /// Merges `other` into this value without losing anything: scalar fields fill only when empty,
    /// list fields union while preserving first-seen order. Used when two ProbeMatches from one
    /// device carry different scope subsets.
    public mutating func formUnion(_ other: ONVIFScopes) {
        name = name ?? other.name
        hardware = hardware ?? other.hardware
        location = location ?? other.location
        macHint = macHint ?? other.macHint
        profiles = Self.appendingUnique(profiles, other.profiles)
        types = Self.appendingUnique(types, other.types)
        raw = Self.appendingUnique(raw, other.raw)
    }

    private static func appendingUnique(_ base: [String], _ extra: [String]) -> [String] {
        var seen = Set(base)
        var result = base
        for value in extra where seen.insert(value).inserted { result.append(value) }
        return result
    }
}

// MARK: - Parsing

extension ONVIFScopes {

    /// Parses a whitespace-separated ONVIF `Scopes` element into an `ONVIFScopes`.
    ///
    /// Each scope is percent-decoded first, then matched case-insensitively on its path — the host
    /// part is ignored, because firmware in the field publishes scopes under hosts other than
    /// `www.onvif.org` and refusing those would silently discard the vendor name we came for.
    /// Anything unrecognised still lands in `raw`. Never throws: garbage in yields empty fields.
    public static func parse(_ rawList: String) -> ONVIFScopes {
        var scopes = ONVIFScopes()
        for token in rawList.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n"
                                                    || $0 == "\r" }) {
            let decoded = percentDecoded(String(token))
            scopes.raw.append(decoded)
            guard let (key, value) = splitScope(decoded), !value.isEmpty else { continue }
            switch key {
            case "name": scopes.name = scopes.name ?? value
            case "hardware": scopes.hardware = scopes.hardware ?? value
            case "location": scopes.location = value
            case "profile": scopes.profiles.append(value)
            case "type": scopes.types.append(value)
            case "mac": scopes.macHint = scopes.macHint ?? MACAddress(value)
            default: break
            }
        }
        return scopes
    }

    /// Splits `onvif://host/<key>/<value…>` into a lowercased key and its remaining path.
    ///
    /// For `location` the *deepest* segment is returned (`/location/country/china` → `china`), which
    /// is what the spec's table asks for; for everything else the tail after the key is joined back
    /// with `/` so a value containing a slash survives.
    private static func splitScope(_ scope: String) -> (key: String, value: String)? {
        // Strip the scheme and authority: everything up to the third '/' after "onvif:".
        guard let schemeEnd = scope.range(of: "://") else { return nil }
        let afterScheme = scope[schemeEnd.upperBound...]
        guard let hostEnd = afterScheme.firstIndex(of: "/") else { return nil }
        let path = afterScheme[afterScheme.index(after: hostEnd)...]
        let segments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let first = segments.first else { return nil }
        let key = first.lowercased()
        let tail = Array(segments.dropFirst())
        guard !tail.isEmpty else { return nil }
        let value = key == "location" ? (tail.last ?? "") : tail.joined(separator: "/")
        return (key, value.trimmedForScope())
    }

    /// Percent-decodes a scope. Invalid escapes are left verbatim rather than dropped — a scope with
    /// a stray `%` is still worth showing to the user, and losing it would lose the vendor name.
    public static func percentDecoded(_ text: String) -> String {
        guard text.contains("%") else { return text }
        let source = Array(text.utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(source.count)
        var index = 0
        while index < source.count {
            let byte = source[index]
            if byte == UInt8(ascii: "%"), index + 2 < source.count,
               let high = hexValue(source[index + 1]), let low = hexValue(source[index + 2]) {
                bytes.append(high << 4 | low)
                index += 3
            } else {
                bytes.append(byte)
                index += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}

private extension String {
    /// Trims ASCII whitespace from both ends without pulling in `CharacterSet`.
    func trimmedForScope() -> String {
        var view = Substring(self)
        while let first = view.first, first == " " || first == "\t" || first == "\r"
                || first == "\n" {
            view = view.dropFirst()
        }
        while let last = view.last, last == " " || last == "\t" || last == "\r" || last == "\n" {
            view = view.dropLast()
        }
        return String(view)
    }
}
