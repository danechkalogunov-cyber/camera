//
//  DiscoveredDevice.swift
//  VigilDiscovery
//
//  The record a discovery run produces, the identity ladder that decides when two sightings are one
//  device, and the observation/field vocabulary every mechanism folds into a record.
//  Implements docs/spec-discovery.md §3, §7.1 and §7.
//

import Foundation
import VigilProtocols

// MARK: - Identity

/// How a device is identified, strongest first.
///
/// The ladder exists because the cheap key (`ip:port`) is the one that lies: DHCP moves a camera and
/// a replacement device inherits its address. A MAC or a serial survives both. `endpoint` is only
/// ever provisional and is replaced the moment anything stronger arrives (§7.1).
public enum DeviceIdentity: Sendable, Hashable, Codable, CustomStringConvertible {
    /// A hardware MAC that passed `isUsableIdentity` and was **not** a hint. Strength 4.
    case mac(MACAddress)
    /// A normalised device serial (`IdentityNormalizer.serialKey`). Strength 3.
    case serial(String)
    /// A normalised ONVIF `EndpointReference` UUID (`IdentityNormalizer.onvifKey`). Strength 2.
    case onvifUUID(String)
    /// `ip:httpPort`. Strength 1, provisional only.
    case endpoint(IPv4Address, UInt16)

    /// Ladder rank: 4 (MAC) down to 1 (endpoint). Merges keep the record with the highest rank.
    public var strength: Int {
        switch self {
        case .mac: 4
        case .serial: 3
        case .onvifUUID: 2
        case .endpoint: 1
        }
    }

    /// True for `endpoint`, the only identity that may be replaced rather than merged.
    public var isProvisional: Bool { strength == 1 }

    /// The union-find key for this identity. The namespace is flat and prefixed per §7.2 so that a
    /// serial can never collide with a UUID that happens to have the same text.
    public var key: String {
        switch self {
        case let .mac(mac): "mac:" + mac.description.replacingOccurrences(of: ":", with: "")
        case let .serial(serial): "sn:" + serial
        case let .onvifUUID(uuid): "onvif:" + uuid
        case let .endpoint(address, port): "ep:\(address):\(port)"
        }
    }

    /// Rebuilds an identity from a `key` produced by `key`. Returns `nil` for an unknown prefix or a
    /// malformed payload, so a corrupted persisted key can never resurrect as a bogus identity.
    public init?(key: String) {
        if let value = key.dropPrefixIfPresent("mac:") {
            guard let mac = MACAddress(Self.colonising(value)) else { return nil }
            self = .mac(mac)
        } else if let value = key.dropPrefixIfPresent("sn:"), !value.isEmpty {
            self = .serial(value)
        } else if let value = key.dropPrefixIfPresent("onvif:"), !value.isEmpty {
            self = .onvifUUID(value)
        } else if let value = key.dropPrefixIfPresent("ep:") {
            let parts = value.split(separator: ":")
            guard parts.count == 2, let address = IPv4Address(String(parts[0])),
                  let port = UInt16(parts[1]) else { return nil }
            self = .endpoint(address, port)
        } else {
            return nil
        }
    }

    /// Inserts colons into 12 bare hex digits so `MACAddress(_:)` accepts them.
    private static func colonising(_ hex: String) -> String {
        guard hex.count == 12 else { return hex }
        var out = ""
        for (offset, character) in hex.enumerated() {
            if offset > 0, offset % 2 == 0 { out.append(":") }
            out.append(character)
        }
        return out
    }

    public var description: String {
        switch self {
        case let .mac(mac): "mac \(mac)"
        case let .serial(serial): "serial \(serial)"
        case let .onvifUUID(uuid): "onvif \(uuid)"
        case let .endpoint(address, port): "endpoint \(address):\(port)"
        }
    }
}

private extension String {
    /// Returns the remainder after `prefix`, or `nil` when the string does not start with it.
    func dropPrefixIfPresent(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}

// MARK: - Fields and provenance

/// Every field of a `DiscoveredDevice` that can be independently observed, so the merge engine can
/// stamp each one with the source that supplied it and report exactly what changed.
public enum DeviceFieldKey: String, Sendable, Hashable, Codable, CaseIterable {
    case address, httpPort, httpsPort, rtspPort, commandPort, mac, serialNumber, model, displayName
    case vendor, deviceClass, firmwareVersion, dspVersion, bootTime, activation
    case subnetMask, gateway, ipv6Address, dhcpEnabled, analogChannelCount, digitalChannelCount
    case onvifServiceURLs, onvifScopes, bonjourName, openPorts, rtspRealm, httpServerHeader
    case passwordResetAbility, supportsHCPlatform, reachability
}

/// Where a single field's current value came from, and when.
public struct FieldStamp: Sendable, Hashable, Codable {
    public let source: DiscoverySource
    public let observedAt: Date

    public init(source: DiscoverySource, observedAt: Date) {
        self.source = source
        self.observedAt = observedAt
    }
}

/// The closed set of value shapes a field can carry. Keeping this closed is what makes the merge
/// table total: there is no field whose folding rule is "whatever the caller meant".
public enum FieldValue: Sendable, Hashable, Codable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case port(UInt16)
    case ipv4(IPv4Address)
    case date(Date)
    case ports(Set<UInt16>)
    case strings([String])
    case scopes(ONVIFScopes)
    case vendor(DeviceVendor)
    case deviceClass(DeviceClass)
    case activation(ActivationState)
    case reachability(Reachability)
    case mac(MACAddress)
}

// MARK: - Observation

/// One mechanism's sighting of one address: the raw material the merge engine folds into records.
///
/// `address` is always known because it is either a datagram's source or a host we swept.
/// Everything else is optional, and `fields` carries **only** what this source actually observed —
/// an absent key means "no opinion", never "cleared".
public struct DeviceObservation: Sendable, Hashable {

    /// Which mechanism saw this.
    public let source: DiscoverySource
    /// When, on the injected clock. The pure layer never reads the wall clock itself.
    public let observedAt: Date
    /// The address the sighting came from or was aimed at.
    public let address: IPv4Address
    /// A MAC, if this source saw one.
    public var mac: MACAddress?
    /// True when `mac` was *derived* (from an ONVIF UUID's tail, or a Bonjour TXT record) rather
    /// than read from a device or the ARP table. A hint may corroborate and may seed the vendor, but
    /// it never forms a `DeviceIdentity` — the cost of merging two distinct cameras is far higher
    /// than the benefit (§5.6).
    public var macIsHintOnly: Bool
    /// A device serial, unnormalised; `IdentityNormalizer.serialKey` decides whether it is usable.
    public var serialNumber: String?
    /// An ONVIF `EndpointReference` address, unnormalised.
    public var onvifUUID: String?
    /// The fields this source observed.
    public var fields: [DeviceFieldKey: FieldValue]
    /// A vendor verdict with its confidence delta, when this source ran the classifier (§6.8). When
    /// `nil` the merge engine derives a delta from `source` instead.
    public var verdict: ClassificationVerdict?
    /// True when this came from a SADP ProbeMatch that did not correlate to our own probe UUID —
    /// another discovery client's traffic. Still useful, but scored down (§7.6).
    public var isForeignProbeMatch: Bool

    /// Creates an observation. Every field beyond `source`, `observedAt` and `address` defaults to
    /// "not observed", so a mechanism spells out only what it actually learned.
    public init(source: DiscoverySource, observedAt: Date, address: IPv4Address,
                mac: MACAddress? = nil, macIsHintOnly: Bool = false, serialNumber: String? = nil,
                onvifUUID: String? = nil, fields: [DeviceFieldKey: FieldValue] = [:],
                verdict: ClassificationVerdict? = nil, isForeignProbeMatch: Bool = false) {
        self.source = source
        self.observedAt = observedAt
        self.address = address
        self.mac = mac
        self.macIsHintOnly = macIsHintOnly
        self.serialNumber = serialNumber
        self.onvifUUID = onvifUUID
        self.fields = fields
        self.verdict = verdict
        self.isForeignProbeMatch = isForeignProbeMatch
    }

    /// The HTTP port this observation implies, used to build the provisional `endpoint` identity.
    /// Defaults to 80 when the source said nothing, which is what a bare sweep hit means.
    public var impliedHTTPPort: UInt16 {
        if case let .port(port) = fields[.httpPort] { return port }
        return 80
    }

    /// The identity keys derivable from this observation, strongest first. Hint-only MACs are
    /// excluded by construction (§7.1), which is the rule that keeps two cameras from colliding on a
    /// MAC that was guessed from a UUID.
    public var identities: [DeviceIdentity] {
        var result: [DeviceIdentity] = []
        if let mac, !macIsHintOnly, mac.isUsableIdentity { result.append(.mac(mac)) }
        if let serialNumber, let key = IdentityNormalizer.serialKey(serialNumber) {
            result.append(.serial(key))
        }
        if let onvifUUID, let key = IdentityNormalizer.onvifKey(onvifUUID) {
            result.append(.onvifUUID(key))
        }
        result.append(.endpoint(address, impliedHTTPPort))
        return result
    }
}

// MARK: - The record

/// One device, as discovery currently understands it.
///
/// `Hashable` and `Equatable` consider **only** `id`: merging mutates every other field in place and
/// these records live in identity-keyed UI collections. Change detection is
/// `DiscoveryEvent.deviceUpdated(_:changes:)`, never `==`.
public struct DiscoveredDevice: Sendable, Hashable, Codable, Identifiable {

    // MARK: Identity

    /// The strongest identity known right now. Promoted in place as better keys arrive.
    public var id: DeviceIdentity
    /// Every other identity that has ever been bound to this record.
    public var alternateIdentities: Set<DeviceIdentity>

    // MARK: Network

    public var address: IPv4Address
    public var httpPort: UInt16
    public var httpsPort: UInt16?
    public var rtspPort: UInt16
    /// The Hikvision SDK port, normally 8000.
    public var commandPort: UInt16?
    public var subnetMask: IPv4Address?
    public var gateway: IPv4Address?
    /// Display only: v1 never connects over IPv6.
    public var ipv6Address: String?
    public var dhcpEnabled: Bool?
    public var openPorts: Set<UInt16>

    // MARK: Hardware

    public var mac: MACAddress?
    /// True when `mac` is a hint (UUID- or TXT-derived) and therefore not an identity.
    public var macIsHintOnly: Bool
    public var serialNumber: String?
    public var model: String?
    public var displayName: String?
    public var vendor: DeviceVendor
    public var deviceClass: DeviceClass
    public var firmwareVersion: String?
    public var dspVersion: String?
    public var bootTime: Date?
    public var analogChannelCount: Int?
    public var digitalChannelCount: Int?

    // MARK: State

    public var activation: ActivationState
    public var passwordResetAbility: Bool?
    public var supportsHCPlatform: Bool?
    public var reachability: Reachability

    // MARK: Protocol surfaces

    public var onvifServiceURLs: [String]
    public var onvifScopes: ONVIFScopes?
    public var bonjourName: String?
    /// The realm from an RTSP 401, e.g. `IP Camera(52799)`.
    public var rtspRealm: String?
    /// The HTTP `Server` header, e.g. `App-webs/`.
    public var httpServerHeader: String?

    // MARK: Provenance

    public var sources: Set<DiscoverySource>
    public var provenance: [DeviceFieldKey: FieldStamp]
    public var firstSeen: Date
    public var lastSeen: Date
    /// 0…100, recomputed from scratch after every fold (§7.6).
    public var confidence: Int

    /// Creates a record. Only `id`, `address` and the two timestamps are required; everything else
    /// defaults to "not known yet", which is the state a bare TCP hit produces.
    public init(id: DeviceIdentity, address: IPv4Address, firstSeen: Date, lastSeen: Date,
                alternateIdentities: Set<DeviceIdentity> = [], httpPort: UInt16 = 80,
                rtspPort: UInt16 = 554, openPorts: Set<UInt16> = [],
                vendor: DeviceVendor = .unknown, deviceClass: DeviceClass = .unknown,
                activation: ActivationState = .unknown, reachability: Reachability = .unknown,
                sources: Set<DiscoverySource> = [], confidence: Int = 0) {
        self.id = id
        self.alternateIdentities = alternateIdentities
        self.address = address
        self.httpPort = httpPort
        self.rtspPort = rtspPort
        self.openPorts = openPorts
        self.macIsHintOnly = false
        self.vendor = vendor
        self.deviceClass = deviceClass
        self.activation = activation
        self.reachability = reachability
        self.onvifServiceURLs = []
        self.sources = sources
        self.provenance = [:]
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.confidence = confidence
    }

    // MARK: Derived

    /// The best human label available, never empty.
    public var resolvedName: String {
        displayName ?? model ?? onvifScopes?.name ?? bonjourName ?? "Camera at \(address)"
    }

    /// Base URL for `VigilISAPI`. HTTPS is preferred **only** when 443 answered and 80 did not, so a
    /// camera with a broken self-signed stack is not chosen over a working plaintext port.
    public var isapiBaseURL: URL? {
        let preferHTTPS = openPorts.contains(443) && !openPorts.contains(httpPort)
        let scheme = preferHTTPS ? "https" : "http"
        let port = preferHTTPS ? (httpsPort ?? 443) : httpPort
        let defaultPort: UInt16 = preferHTTPS ? 443 : 80
        let authority = port == defaultPort ? "\(address)" : "\(address):\(port)"
        return URL(string: "\(scheme)://\(authority)")
    }

    /// The main-stream RTSP path for this vendor family, or `nil` when the vendor is unknown and the
    /// UI must ask. Discovery records the vendor; it never opens an RTSP session.
    public var suggestedRTSPPath: String? { vendor.defaultRTSPPaths?.main }

    /// True when the device has no password yet and must be activated before anything will connect.
    public var needsActivation: Bool { activation == .notActivated }

    /// True when the "Add" button may be enabled: an off-subnet device is not addable however
    /// confident we are that it is a camera.
    public var isAddable: Bool { reachability == .reachable || reachability == .addressableNoPorts }

    // MARK: Hashable

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Known devices

/// A camera `VigilCore` already has saved, projected into the shape discovery needs to recognise it.
///
/// This is what makes the difference between "your camera moved" and "a stranger answered at your
/// camera's address" — see §7.4. Discovery never writes to persistence; it emits the events and
/// `VigilCore` decides.
public struct KnownDeviceSnapshot: Sendable, Hashable, Codable {

    /// Whatever identity was stored, `.mac` preferred.
    public let identity: DeviceIdentity
    public let mac: MACAddress?
    public let serialNumber: String?
    public let lastKnownAddress: IPv4Address
    public let lastKnownHTTPPort: UInt16
    /// The user's own name for the camera, which outranks anything a device calls itself.
    public let displayName: String?

    public init(identity: DeviceIdentity, mac: MACAddress? = nil, serialNumber: String? = nil,
                lastKnownAddress: IPv4Address, lastKnownHTTPPort: UInt16 = 80,
                displayName: String? = nil) {
        self.identity = identity
        self.mac = mac
        self.serialNumber = serialNumber
        self.lastKnownAddress = lastKnownAddress
        self.lastKnownHTTPPort = lastKnownHTTPPort
        self.displayName = displayName
    }

    /// The normalised serial key, or `nil` when the stored serial is unusable as an identity.
    public var serialKey: String? { serialNumber.flatMap(IdentityNormalizer.serialKey) }
}
