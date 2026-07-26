//
//  DiscoveryEnums.swift
//  VigilDiscovery
//
//  The closed vocabularies every discovery mechanism speaks: where a fact came from and how much
//  that source is trusted, which vendor and device class we believe we are looking at, whether the
//  device still needs activation, and whether we can actually reach it.
//  Implements docs/spec-discovery.md §3 (shared value types), §6.8 (vendor table) and §7.3 (trust).
//

// MARK: - Provenance

/// Which mechanism produced a fact.
///
/// `trust` is the whole point of this enum: two sources routinely disagree about the same device
/// (ARP says one MAC, SADP another; ONVIF says `HIKVISION DS-2CD2143G0-I`, SADP says
/// `DS-2CD2143G0-I`) and the merge engine resolves that by source weight before it resolves it by
/// time. See `MergeEngine.shouldOverwrite(existing:incoming:)`.
public enum DiscoverySource: String, Sendable, Hashable, Codable, CaseIterable {

    /// A SADP ProbeMatch that came back from the 239.255.255.250:37020 multicast probe.
    case sadpMulticast
    /// A SADP ProbeMatch from a unicast probe, used when multicast is unavailable (§9.5).
    case sadpUnicast
    /// An ONVIF WS-Discovery ProbeMatch.
    case wsDiscovery
    /// A TCP connect probe: proof a host exists and which ports answered. No content.
    case tcpSweep
    /// An RTSP `OPTIONS` fingerprint (realm, `Public:` methods, `Server`).
    case rtspFingerprint
    /// An HTTP fingerprint of `/ISAPI/System/deviceInfo` or `/`.
    case isapiFingerprint
    /// A Bonjour browse result. Contributes a name and, on some vendors, a MAC hint.
    case bonjour
    /// The system ARP cache: an IP-to-MAC binding we did not have to send a packet for.
    case arpCache
    /// The user typed the address. Outranks everything, including SADP.
    case manual
    /// Seeded from `VigilCore`'s saved cameras so a known device is recognised, not rediscovered.
    case persisted

    /// Trust weight used by the field-precedence resolver (§7.3). Higher wins; ties fall through to
    /// the observation timestamp.
    ///
    /// The ordering encodes what each source actually knows. SADP reads the device's own
    /// configuration block, so it beats an ISAPI header sniff; a TCP connect knows nothing but
    /// "something answered", so it beats only ARP and whatever we previously persisted.
    public var trust: Int {
        switch self {
        case .manual: 100
        case .sadpMulticast, .sadpUnicast: 90
        case .isapiFingerprint: 70
        case .wsDiscovery: 60
        case .rtspFingerprint: 50
        case .tcpSweep: 30
        case .bonjour: 25
        case .arpCache: 20
        case .persisted: 10
        }
    }

    /// True for the two sources that only prove existence and never describe a device. A record
    /// whose sources are all weak is scored down by the confidence rule in §7.6.
    public var isExistenceOnly: Bool { self == .arpCache || self == .bonjour }
}

// MARK: - Vendor and class

/// The manufacturer we believe answered, to the precision the evidence supports.
///
/// The distinction that matters to a user is not marketing: it is whether Vigil's ISAPI control
/// plane will work. `hikvisionOEM` covers the rebadges (HiLook, LTS, Annke, Safire, Nelly's,
/// TruVision) that keep the `/ISAPI/` surface, and `supportsISAPI` is true for both.
public enum DeviceVendor: String, Sendable, Hashable, Codable, CaseIterable {
    case hikvision
    case hikvisionOEM
    case dahua
    case dahuaOEM
    case axis
    case reolink
    case unifi
    case genericONVIF
    case genericRTSP
    case unknown

    /// True when the ISAPI control plane (`VigilISAPI`) is expected to work.
    public var supportsISAPI: Bool { self == .hikvision || self == .hikvisionOEM }

    /// True when we know a real manufacturer, as opposed to "some ONVIF box" or nothing at all.
    /// The classifier never replaces a named vendor with an unnamed one (§6.8).
    public var isSpecific: Bool {
        switch self {
        case .genericONVIF, .genericRTSP, .unknown: false
        default: true
        }
    }

    /// Human label for a UI row. Deliberately says "not Hikvision" plainly rather than hiding a
    /// Dahua behind a generic word: a user who is told the truth here does not waste a minute on a
    /// connection that cannot work.
    public var displayName: String {
        switch self {
        case .hikvision: "Hikvision"
        case .hikvisionOEM: "Hikvision-compatible (OEM)"
        case .dahua: "Dahua"
        case .dahuaOEM: "Dahua-compatible (OEM)"
        case .axis: "Axis"
        case .reolink: "Reolink"
        case .unifi: "Ubiquiti UniFi"
        case .genericONVIF: "ONVIF device"
        case .genericRTSP: "RTSP device"
        case .unknown: "Unknown device"
        }
    }

    /// Main- and sub-stream RTSP paths for this vendor family (§6.8), or `nil` when we do not know
    /// a path and the UI must ask. Discovery only records the vendor; `VigilCore` builds the URL.
    public var defaultRTSPPaths: (main: String, sub: String)? {
        switch self {
        case .hikvision, .hikvisionOEM:
            ("/Streaming/Channels/101", "/Streaming/Channels/102")
        case .dahua, .dahuaOEM:
            ("/cam/realmonitor?channel=1&subtype=0", "/cam/realmonitor?channel=1&subtype=1")
        case .axis:
            ("/axis-media/media.amp", "/axis-media/media.amp?resolution=640x360")
        case .reolink:
            ("/h264Preview_01_main", "/h264Preview_01_sub")
        case .unifi, .genericONVIF, .genericRTSP, .unknown:
            nil
        }
    }
}

/// What kind of box it is. Used for the row glyph and for channel expectations: an NVR has many
/// channels, a camera has one.
public enum DeviceClass: String, Sendable, Hashable, Codable, CaseIterable {
    case camera, ptzCamera, nvr, dvr, encoder, decoder, doorbell, accessControl, unknown

    /// Ranking used when two sources disagree: a class is never replaced by a weaker one, and
    /// `.ptzCamera` beats `.camera` because knowing a device can pan is strictly more information
    /// (§7.3).
    public var specificity: Int {
        switch self {
        case .unknown: 0
        case .camera: 1
        case .ptzCamera, .nvr, .dvr, .encoder, .decoder, .doorbell, .accessControl: 2
        }
    }
}

// MARK: - Device state

/// Whether the device has ever been given a password.
///
/// `notActivated` is the single most important thing discovery can tell a user: nothing will
/// connect until the device is activated, and no amount of correct credentials will help.
public enum ActivationState: String, Sendable, Hashable, Codable {
    /// SADP reported `<Activated>true</Activated>`, or we never learned otherwise.
    case activated
    /// SADP reported `<Activated>false</Activated>`: the device has no password yet and must be
    /// activated before any RTSP or ISAPI call will work. Must be surfaced in the UI (§4.6).
    case notActivated
    /// Never observed. The default for sources that cannot see activation at all.
    case unknown
}

/// Whether we could actually connect to the address we found.
public enum Reachability: String, Sendable, Hashable, Codable {
    /// Inside one of our interface subnets and at least one TCP port answered.
    case reachable
    /// Inside our subnets but no TCP port answered — firewalled, or local-network permission was
    /// refused.
    case addressableNoPorts
    /// Seen over multicast but not inside any subnet we hold: the classic factory-default
    /// 192.168.1.64 on a 10.0.0.0/24 LAN. Not connectable without changing its address first (§4.7).
    case offSubnet
    /// Not yet determined.
    case unknown
}
