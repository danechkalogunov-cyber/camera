# Vigil — Camera Discovery Specification

**Module:** `VigilDiscovery` (platform-independent, Foundation-only, Linux-testable)
**Companion:** `VigilTransport/Discovery/*` (macOS-only, Network.framework + Darwin syscalls)
**Status:** Normative. An implementer must be able to code this without further research.
**Audience:** implementation agents for `VigilDiscovery`, `VigilTransport`, `VigilCore`, `VigilUI`.

---

## 0. Table of contents

| § | Topic |
|---|---|
| 1 | Scope, module boundaries, layering contract |
| 2 | Discovery pipeline: phases, order, timing budget |
| 3 | Shared value types (`DiscoveredDevice` and friends) |
| 4 | Mechanism 1 — Hikvision SADP |
| 5 | Mechanism 2 — ONVIF WS-Discovery |
| 6 | Mechanism 3 — Targeted subnet sweep (+ ARP, Bonjour, fingerprints) |
| 7 | Merge and dedupe model |
| 8 | Progress reporting, ETA, cancellation |
| 9 | Entitlements, Info.plist, permission flows, degraded modes |
| 10 | Public Swift API of `VigilDiscovery` |
| 11 | macOS transport implementations (`VigilTransport`) |
| 12 | Error taxonomy and logging |
| 13 | Unit tests driven by recorded packet bytes |
| 14 | Fixture appendix (literal bytes) |
| 15 | Cross-cutting contract for other modules |

---

## 1. Scope, module boundaries, layering contract

### 1.1 What discovery is responsible for

Discovery turns "a Mac plugged into a LAN" into a list of `DiscoveredDevice` values that the user can
one-click add as a camera. It does **not** authenticate, does **not** open streams, does **not** write
persistence. It emits candidates plus enough metadata that `VigilCore` can construct a `Camera` record
with a working RTSP URL template and an ISAPI base URL.

Explicit non-goals (owned elsewhere):

| Concern | Owner |
|---|---|
| Activating an unactivated camera (`PUT /ISAPI/System/activate`) | `VigilISAPI` |
| Credential validation (`GET /ISAPI/Security/userCheck`) | `VigilISAPI` |
| Channel enumeration on an NVR (`/ISAPI/ContentMgmt/InputProxy/channels`) | `VigilISAPI` |
| Persisting discovered devices, Keychain | `VigilCore` |
| The discovery sheet UI, empty states, permission nags | `VigilUI` |

### 1.2 Dependency rules (hard)

```
VigilProtocols  ←  VigilDiscovery            (pure, Foundation only, compiles on Linux Swift 6.1)
                        ↑
                        │  (protocol injection only — no reverse import)
                        │
VigilTransport/Discovery/*  (macOS only: Network, Darwin, dnssd)
                        ↑
                    VigilCore  →  VigilUI
```

* `VigilDiscovery` imports **only** `Foundation` and `VigilProtocols`. It must not import `Network`,
  `Darwin`, `AppKit`, `Security`, `os`, or `VigilRTSP`.
* **Deliberate, bounded duplication:** discovery needs to read a status line and three headers out of
  RTSP and HTTP responses. It does **not** depend on `VigilRTSP` for this. `VigilDiscovery` carries its
  own ~70-line `StartLineHeaderScanner` (§6.6) that is intentionally lenient and throws nothing. The
  canonical, complete RTSP parser remains in `VigilRTSP`. This keeps the target graph a tree; the
  architecture document must **not** add a `VigilDiscovery → VigilRTSP` edge.
* No socket, file descriptor, timer, or `getifaddrs` call appears in `VigilDiscovery`. Every such
  capability enters through the `DiscoveryEnvironment` (§10.1) as a `Sendable` protocol existential.
  This is what makes the whole orchestration, all three codecs, the CIDR maths, the merge engine and
  the progress/ETA model unit-testable on Linux with zero network.

### 1.3 Canonical primitive types (declared in `VigilProtocols`)

These are used by discovery, ISAPI, RTSP and Core. `VigilProtocols` is their single home.

```swift
/// Host-order IPv4 address. Pure value type — deliberately NOT Network.IPv4Address, which does not
/// exist on Linux. In VigilTransport files that import both modules, always qualify:
/// `VigilProtocols.IPv4Address` vs `Network.IPv4Address`.
public struct IPv4Address: Hashable, Sendable, Codable, CustomStringConvertible,
                           LosslessStringConvertible, Comparable {
    public let rawValue: UInt32                    // host byte order: 192.168.1.64 == 0xC0A80140

    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8)
    /// Strict dotted-quad parse. Rejects leading zeros ("192.168.01.1"), >3 digits, >255 octets,
    /// fewer or more than 4 octets, surrounding whitespace, and any non-digit.
    public init?(_ description: String)
    public var octets: (UInt8, UInt8, UInt8, UInt8) { get }
    public var description: String { get }         // "192.168.1.64"
    public var isLoopback: Bool  { rawValue >> 24 == 127 }
    public var isLinkLocal: Bool { rawValue >> 16 == 0xA9FE }   // 169.254/16
    public var isMulticast: Bool { rawValue >> 28 == 0xE }
    public var isUnspecified: Bool { rawValue == 0 }
    public static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }
}

/// 48-bit MAC packed into the low 48 bits of a UInt64. Canonical form is lowercase colon-separated.
public struct MACAddress: Hashable, Sendable, Codable, CustomStringConvertible,
                          LosslessStringConvertible {
    public let rawValue: UInt64                    // 0x0000_C42F_90AB_CDEF

    public init?(rawValue: UInt64)                 // nil if any bit above 47 is set
    public init(bytes: [UInt8])                    // precondition: count == 6
    /// Accepts every separator Hikvision/Dahua/Axis firmware emits, case-insensitively:
    /// "c4:2f:90:ab:cd:ef", "C4-2F-90-AB-CD-EF", "c42f90abcdef", "c42f.90ab.cdef".
    /// Rejects anything that does not reduce to exactly 12 hex nibbles.
    public init?(_ description: String)
    public var bytes: [UInt8] { get }
    public var description: String { get }         // "c4:2f:90:ab:cd:ef"
    public var oui: UInt32 { get }                 // 0xC42F90
    public var isLocallyAdministered: Bool { bytes[0] & 0x02 != 0 }
    public var isMulticast: Bool { bytes[0] & 0x01 != 0 }
    /// All-zero and broadcast MACs are never valid identities.
    public var isUsableIdentity: Bool { rawValue != 0 && rawValue != 0xFFFF_FFFF_FFFF && !isMulticast }
}
```

`VigilDiscovery` additionally owns `IPv4Subnet`, `NetworkInterfaceInfo`, `ARPEntry` (§6).

---

## 2. Discovery pipeline: phases, order, timing budget

### 2.1 Order of mechanisms — and why

We run the three mechanisms in this order, **overlapping**, not serially:

1. **SADP first.** It is the only mechanism that returns MAC, serial, firmware, *and activation state*
   in one datagram, and it reaches devices that are **not routable from us** (wrong subnet), because it
   is link-local multicast. Highest information density per packet, ~50 ms to first result.
2. **ONVIF WS-Discovery second.** Catches non-Hikvision and Hikvision-OEM devices, and yields the ONVIF
   service URL and human-friendly name/hardware/location scopes.
3. **Targeted subnet sweep last** (but started at t=250 ms so the user sees motion). It is the only
   mechanism that works when multicast is blocked by the switch, by a VLAN, by Wi-Fi client isolation,
   or by a missing multicast entitlement (§9). It is also the noisiest, so it runs behind the other two.

ARP-cache read and Bonjour browse are cheap enrichments that ride along.

### 2.2 Phase table

| Phase | Symbol | Starts | Ends | Blocking? |
|---|---|---|---|---|
| Plan | `.planning` | t=0 | t≈5 ms | yes (produces `DiscoveryPlan`) |
| ARP pre-snapshot | `.arpSnapshot` | t=5 ms | t≈10 ms | no |
| SADP multicast | `.sadp` | t=10 ms | t=3 510 ms | no |
| WS-Discovery | `.onvif` | t=10 ms | t=3 510 ms | no |
| Bonjour browse | `.bonjour` | t=10 ms | end of run | no |
| Sweep tier A (554, 80) | `.sweepA` | t=250 ms | data-dependent | no |
| Sweep tier B (8000, 443, 8080) | `.sweepB` | after A per host | data-dependent | no |
| Fingerprint | `.fingerprint` | rolling, per responder | data-dependent | no |
| ARP post-snapshot | `.arpSnapshot` | after tier A completes | +5 ms | no |
| Merge + settle | `.settling` | continuous | run end | no |

**Timing constants** (all in `DiscoveryConfiguration`, values below are `.default`):

| Constant | Value | Rationale |
|---|---|---|
| `sadpProbeSchedule` | `[0 ms, 500 ms, 1000 ms]` | 3 probes; cheap, covers one lost datagram |
| `sadpListenTail` | `2 500 ms` after last probe | slow NVRs answer 1.5–2 s late |
| `onvifProbeSchedule` | `[0 ms, 500 ms, 1000 ms]` | mandated by §5.3 |
| `onvifListenTail` | `2 500 ms` | ONVIF `AppSequence` bursts |
| `sweepStartDelay` | `250 ms` | let multicast replies land on an idle NIC |
| `tcpConnectTimeout` | `350 ms` | LAN RTT ≤ 3 ms; 350 ms covers a busy NVR's accept queue |
| `maxInFlightConnects` | `128` | see §6.5 for the fd-budget clamp |
| `fingerprintTimeout` | `600 ms` | one round trip + Hikvision's slow 401 generation |
| `perHostFingerprintBudget` | `1 200 ms` | RTSP OPTIONS + one HTTP GET, sequential |
| `overallDeadline` | `12 s` for ≤/24; `+8 s` per doubling | see §8.3 |
| `settleQuietPeriod` | `750 ms` | run may finish early once nothing new arrives |

A run finishes when **either** every planned host has been probed and both multicast windows are closed
and no event has been emitted for `settleQuietPeriod`, **or** `overallDeadline` elapses, **or**
`cancel()` is called. In all three cases the accumulated results are delivered — a deadline is never a
failure and never discards records.

### 2.3 ASCII sequence

```
 t=0      plan interfaces ──► DiscoveryPlan(subnets, hostOrder, tiers)
 t=10ms   ├─ SADP  ch(en0) ═══ probe ─┬── probe ─┬── probe ─────────────► close t=3.51s
          │        ch(en1) ═══        │          │
          ├─ WSD   ch(en0) ═══ probe ─┴── probe ─┴── probe ─────────────► close t=3.51s
          ├─ Bonjour NWBrowser ─────────────────────────────────────────► run end
 t=250ms  └─ sweep ▓▓▓▓▓▓▓▓ 128-wide TCP connect window ────────────────►
                       │ responder ─► ARP lookup ─► RTSP OPTIONS ─► HTTP /ISAPI ─► classify
                       ▼
                  MergeEngine (union-find on identity ladder) ──► AsyncStream<DiscoveryEvent>
```

---

## 3. Shared value types

All of the following live in `VigilDiscovery` and are `Sendable`, `Hashable`, `Codable`.

```swift
public enum DiscoverySource: String, Sendable, Hashable, Codable, CaseIterable {
    case sadpMulticast        // §4.1
    case sadpUnicast          // §4.9 fallback
    case wsDiscovery          // §5
    case tcpSweep             // §6.5
    case rtspFingerprint      // §6.6
    case isapiFingerprint     // §6.7
    case bonjour              // §6.4
    case arpCache             // §6.3
    case manual               // user typed an address
    case persisted            // seeded from VigilCore's saved cameras

    /// Trust weight used by the field-precedence resolver (§7.3). Higher wins.
    public var trust: Int {
        switch self {
        case .manual:          return 100
        case .sadpMulticast,
             .sadpUnicast:     return 90
        case .isapiFingerprint:return 70
        case .wsDiscovery:     return 60
        case .rtspFingerprint: return 50
        case .tcpSweep:        return 30
        case .bonjour:         return 25
        case .arpCache:        return 20
        case .persisted:       return 10
        }
    }
}

public enum DeviceVendor: String, Sendable, Hashable, Codable {
    case hikvision            // genuine Hikvision branding
    case hikvisionOEM         // HiLook, LTS, Annke, Safire, Nelly's, TruVision — ISAPI-compatible
    case dahua
    case dahuaOEM             // Amcrest, Lorex(some), Empire — DH protocol
    case axis
    case reolink
    case unifi
    case genericONVIF
    case genericRTSP
    case unknown

    /// True when the ISAPI control plane (VigilISAPI) is expected to work.
    public var supportsISAPI: Bool { self == .hikvision || self == .hikvisionOEM }
}

public enum DeviceClass: String, Sendable, Hashable, Codable {
    case camera, ptzCamera, nvr, dvr, encoder, decoder, doorbell, accessControl, unknown
}

public enum ActivationState: String, Sendable, Hashable, Codable {
    /// SADP reported <Activated>true</Activated>, or we never learned (default for non-SADP sources).
    case activated
    /// SADP reported <Activated>false</Activated>: the device has NO password yet and must be
    /// activated before any RTSP/ISAPI call will work. MUST be surfaced in the UI (§4.6).
    case notActivated
    case unknown
}

public enum Reachability: String, Sendable, Hashable, Codable {
    /// Address is inside one of our interface subnets AND at least one TCP port answered.
    case reachable
    /// Address is inside our subnets but no TCP port answered (firewalled, or permission denied).
    case addressableNoPorts
    /// Seen via SADP/WSD multicast but the address is not inside any of our subnets — classic
    /// factory-default 192.168.1.64 on a 10.0.0.0/24 LAN. NOT connectable. (§4.7)
    case offSubnet
    case unknown
}

public enum DeviceIdentity: Sendable, Hashable, Codable, CustomStringConvertible {
    case mac(MACAddress)                      // strength 4 — authoritative
    case serial(String)                       // strength 3 — normalized, see §7.1
    case onvifUUID(String)                    // strength 2 — EndpointReference address
    case endpoint(IPv4Address, UInt16)        // strength 1 — ip:httpPort, provisional only

    public var strength: Int { switch self { case .mac: 4; case .serial: 3; case .onvifUUID: 2;
                                             case .endpoint: 1 } }
    public var isProvisional: Bool { strength == 1 }
}

public enum DeviceFieldKey: String, Sendable, Hashable, Codable, CaseIterable {
    case address, httpPort, httpsPort, rtspPort, commandPort, mac, serialNumber, model, displayName
    case vendor, deviceClass, firmwareVersion, dspVersion, bootTime, activation
    case subnetMask, gateway, ipv6Address, dhcpEnabled, analogChannelCount, digitalChannelCount
    case onvifServiceURLs, onvifScopes, bonjourName, openPorts, rtspRealm, httpServerHeader
    case passwordResetAbility, supportsHCPlatform, reachability
}

public struct FieldStamp: Sendable, Hashable, Codable {
    public let source: DiscoverySource
    public let observedAt: Date
}

public struct ONVIFScopes: Sendable, Hashable, Codable {
    public var name: String?          // onvif://www.onvif.org/name/HIKVISION%20DS-2CD2143G0-I
    public var hardware: String?      // onvif://www.onvif.org/hardware/DS-2CD2143G0-I
    public var location: String?      // onvif://www.onvif.org/location/china
    public var profiles: [String]     // ["Streaming", "G", "T"]
    public var types: [String]        // ["Network_Video_Transmitter", "video_encoder"]
    public var macHint: MACAddress?   // non-standard onvif://.../MAC/xx:xx:... when present
    public var raw: [String]          // every percent-decoded scope URI, verbatim, order preserved
}

public struct DiscoveredDevice: Sendable, Hashable, Codable, Identifiable {

    // MARK: Identity
    public var id: DeviceIdentity                  // strongest identity known right now
    public var alternateIdentities: Set<DeviceIdentity>

    // MARK: Network
    public var address: IPv4Address
    public var httpPort: UInt16 = 80
    public var httpsPort: UInt16?
    public var rtspPort: UInt16 = 554
    public var commandPort: UInt16?                // Hikvision SDK port, normally 8000
    public var subnetMask: IPv4Address?
    public var gateway: IPv4Address?
    public var ipv6Address: String?                // display only; we never connect over v6 in v1
    public var dhcpEnabled: Bool?
    public var openPorts: Set<UInt16> = []

    // MARK: Hardware
    public var mac: MACAddress?
    public var serialNumber: String?               // normalized, see §7.1
    public var model: String?                      // "DS-2CD2143G0-I"
    public var displayName: String?                // best human label; see `resolvedName`
    public var vendor: DeviceVendor = .unknown
    public var deviceClass: DeviceClass = .unknown
    public var firmwareVersion: String?            // "V5.5.82 build 190910"
    public var dspVersion: String?                 // "V7.3 build 190430"
    public var bootTime: Date?
    public var analogChannelCount: Int?
    public var digitalChannelCount: Int?

    // MARK: State
    public var activation: ActivationState = .unknown
    public var passwordResetAbility: Bool?
    public var supportsHCPlatform: Bool?
    public var reachability: Reachability = .unknown

    // MARK: Protocol surfaces
    public var onvifServiceURLs: [String] = []
    public var onvifScopes: ONVIFScopes?
    public var bonjourName: String?
    public var rtspRealm: String?                  // WWW-Authenticate realm from RTSP 401
    public var httpServerHeader: String?           // e.g. "App-webs/"

    // MARK: Provenance
    public var sources: Set<DiscoverySource> = []
    public var provenance: [DeviceFieldKey: FieldStamp] = [:]
    public var firstSeen: Date
    public var lastSeen: Date
    public var confidence: Int = 0                 // 0...100, see §7.6

    // MARK: Derived (computed, not stored, not Codable)
    /// displayName ?? model ?? onvifScopes.name ?? bonjourName ?? "Camera at <ip>"
    public var resolvedName: String { get }
    /// http(s)://host:port — base for VigilISAPI. Prefers https only when 443 answered and 80 did not.
    public var isapiBaseURL: URL? { get }
    /// rtsp://host:rtspPort/Streaming/Channels/101 for Hikvision-family; nil otherwise (the UI must
    /// then ask the user for a path, and VigilCore offers the vendor path table in §6.8).
    public var suggestedRTSPPath: String? { get }
    public var needsActivation: Bool { activation == .notActivated }
    public var isAddable: Bool { reachability == .reachable || reachability == .addressableNoPorts }
}
```

`Hashable` on `DiscoveredDevice` hashes **only** `id` — merging mutates every other field and we store
these in `Set`/dictionary-backed UI collections keyed by identity:

```swift
extension DiscoveredDevice {
    public static func == (l: Self, r: Self) -> Bool { l.id == r.id }
    public func hash(into h: inout Hasher) { h.combine(id) }
}
```

For change detection the UI uses `DiscoveryEvent.deviceUpdated(_, changes:)`, never `==`.

---

## 4. Mechanism 1 — Hikvision SADP

SADP ("Search Active Devices Protocol") is Hikvision's proprietary L2-local device announcement
protocol. It is plain XML over UDP multicast and it is the single richest source we have.

### 4.1 Transport parameters (normative)

| Parameter | Value | Notes |
|---|---|---|
| Group address | `239.255.255.250` | IPv4 site-local admin scope (same group as SSDP/WS-Discovery, different port) |
| Group port | `37020` | |
| Local bind port | **`37020` preferred**, else ephemeral | see below — this is load-bearing |
| Local bind address | the specific interface address, per interface | one channel per eligible interface |
| Multicast TTL / hop limit | `1` (configurable up to `4`) | SADP is intended to stay on-link |
| Loopback of own datagrams | enabled (we filter by `Uuid`, §4.5) | simplifies testing |
| Max datagram accepted | `8 192` bytes | real ProbeMatch is 700–1 600 bytes; NVRs with many fields reach ~2 500 |
| Socket reuse | `SO_REUSEADDR` + `SO_REUSEPORT` (`allowLocalEndpointReuse = true`) | must coexist with Hikvision's own SADP tool / iVMS-4200 already holding 37020 |

**Why binding 37020 matters.** Most Hikvision firmware answers an inquiry by **multicasting the
ProbeMatch back to `239.255.255.250:37020`**, not by unicasting to the prober's source port. (This is
why two SADP tools on one LAN see each other's discoveries.) If we bind an ephemeral port we will miss
those devices entirely. Therefore:

1. Try to bind `37020` with address+port reuse.
2. If the bind fails (`EADDRINUSE` despite reuse — happens when another process bound it *without*
   `SO_REUSEPORT`), fall back to an ephemeral port, log `sadpPortUnavailable`, and set
   `DiscoveryDiagnostic.sadpDegradedEphemeralPort`. We still receive from firmware that unicasts
   replies (5.7.x+ does), so results are partial, not empty. The UI shows a subtle inline note only if
   the SADP phase found zero devices.

Because multicast joins are per-interface, we open **one channel per eligible interface** (§6.1) — a Mac
docked with Ethernet *and* Wi-Fi *and* a Thunderbolt bridge needs three, and cameras are commonly on
only one of them.

### 4.2 The Probe payload

Payload is UTF-8 XML with **no** trailing NUL, no length prefix, no framing. Exact bytes we send:

```xml
<?xml version="1.0" encoding="utf-8"?>
<Probe>
<Uuid>1F9B2A6C-4E1D-4F5A-9C3E-7A2B5D8E0C11</Uuid>
<Types>inquiry</Types>
</Probe>
```

Rules:

* `Uuid` — RFC 4122 v4, **uppercase, hyphenated, no braces**. One UUID per *run*, reused across all
  three retries and all interfaces, so we can recognise (a) our own looped-back probe and (b) which
  ProbeMatches answer us versus another SADP client on the LAN.
* `Types` — literally `inquiry`. Lowercase. Do not send `Inquiry`.
* Newlines: `\n` (0x0A) only. Some very old firmware chokes on `\r\n` inside the prolog; `\n` is
  universally accepted.
* Total length: 121 bytes for the form above. Never pad.
* Optional element `<MAC>` carrying the *sender's* MAC is emitted by the official tool; it is **not
  required** and we omit it (it leaks our MAC to every device and no firmware requires it).

`SADPCodec.encodeProbe` is byte-exact and golden-tested (§13.2).

### 4.3 ProbeMatch fields

The device answers with a `<ProbeMatch>` document. Element names vary in **case and presence** by
firmware; the parser is namespace-agnostic and case-insensitive on element names (§4.5).

| Element | Type | Example | Maps to | Notes |
|---|---|---|---|---|
| `Uuid` | UUID string | `1F9B2A6C-…-0C11` | — | echo of our probe; used to filter foreign traffic |
| `Types` | string | `inquiry` | — | always echoes `inquiry` |
| `DeviceType` | integer | `0` | `deviceClass` hint | **opaque across firmware** — see table below, hint only |
| `DeviceDescription` | string | `IPCamera` / `NVR` / `DVR` / `IP Dome` | `deviceClass` | primary class signal |
| `DeviceSN` | string | `DS-2CD2143G0-I20200101AAWRD12345678` | `serialNumber` **and** `model` | model = leading token before the date-ish run (§4.5.3) |
| `CommandPort` | UInt16 | `8000` | `commandPort` | Hikvision SDK/private protocol port |
| `HttpPort` | UInt16 | `80` | `httpPort` | ISAPI base port |
| `HttpsPort` | UInt16 | `443` | `httpsPort` | present on 5.5.x+ |
| `RtspPort` | UInt16 | `554` | `rtspPort` | absent on many models → default 554 |
| `SDKOverTLSPort` | UInt16 | `8443` | ignored | recorded in `raw` only |
| `MAC` | MAC string | `c4-2f-90-ab-cd-ef` | `mac` | hyphen-separated lowercase in most firmware, uppercase in some |
| `IPv4Address` | dotted quad | `192.168.1.64` | `address` | |
| `IPv4SubnetMask` | dotted quad | `255.255.255.0` | `subnetMask` | |
| `IPv4Gateway` | dotted quad | `192.168.1.1` | `gateway` | `0.0.0.0` → nil |
| `IPv6Address` | string | `fe80::c62f:90ff:feab:cdef` | `ipv6Address` | `::` → nil |
| `IPv6Gateway` | string | `::` | ignored | |
| `IPv6MaskLen` | integer | `64` | ignored | |
| `DHCP` | bool | `false` | `dhcpEnabled` | |
| `SoftwareVersion` | string | `V5.5.82build 190910` | `firmwareVersion` | note missing space before `build`; normalize |
| `DSPVersion` | string | `V7.3 build 190430` | `dspVersion` | |
| `BootTime` | `yyyy-MM-dd HH:mm:ss` | `2026-07-19 06:14:02` | `bootTime` | **device-local time, no zone** — see §4.5.4 |
| `Activated` | bool | `true` | `activation` | `false` ⇒ `.notActivated`, must surface (§4.6) |
| `PasswordResetAbility` | bool | `true` | `passwordResetAbility` | whether the device supports SADP password reset |
| `PasswordResetModeSecond` | bool | `true` | ignored | |
| `SupportHCPlatform` | bool | `true` | `supportsHCPlatform` | Hik-Connect capability |
| `HCPlatformEnable` | bool | `false` | ignored | |
| `AnalogChannelNum` | integer | `0` | `analogChannelCount` | >0 ⇒ DVR/hybrid |
| `DigitalChannelNum` | integer | `8` | `digitalChannelCount` | >0 ⇒ NVR |
| `DiskNumber` | integer | `1` | `deviceClass` hint | >0 ⇒ recorder |
| `Salt` | hex string | `9f3c…` | ignored (recorded) | used by SADP-native activation; we activate over ISAPI instead (§4.6) |
| `OEMinfo` | string | `HiLook` | `vendor` = `.hikvisionOEM` | present on rebrands |
| `DeviceLock` | bool | `false` | diagnostic | device is in auth-lockout |
| `SupportSecurityQuestion` | bool | `true` | ignored | |

Boolean parsing accepts `true`/`false`/`TRUE`/`FALSE`/`1`/`0`/`yes`/`no` (case-insensitive).
Unknown elements are preserved verbatim in `SADPProbeMatch.raw: [String: String]` — never dropped,
because firmware variance is the norm and the UI's "device details" inspector shows the raw dictionary.

`DeviceType` observed values — **hint only, never authoritative**:

| Value | Commonly means |
|---|---|
| `0` | IP camera |
| `1` | DVR |
| `2` | NVR |
| `3` | encoder / decoder |
| any other | unknown; ignore |

Classification therefore uses this precedence: `DeviceDescription` string match →
`DigitalChannelNum`/`AnalogChannelNum` > 0 → `DiskNumber` > 0 → `DeviceType` → `.unknown`.

### 4.4 Realistic sample ProbeMatch responses

**4.4.1 Activated 4 MP camera (firmware 5.5.82)** — `192.168.1.64:37020 → 239.255.255.250:37020`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<ProbeMatch>
<Uuid>1F9B2A6C-4E1D-4F5A-9C3E-7A2B5D8E0C11</Uuid>
<Types>inquiry</Types>
<DeviceType>0</DeviceType>
<DeviceDescription>IPCamera</DeviceDescription>
<DeviceSN>DS-2CD2143G0-I20200114AAWRD12345678</DeviceSN>
<CommandPort>8000</CommandPort>
<HttpPort>80</HttpPort>
<HttpsPort>443</HttpsPort>
<RtspPort>554</RtspPort>
<SDKOverTLSPort>8443</SDKOverTLSPort>
<MAC>c4-2f-90-ab-cd-ef</MAC>
<IPv4Address>192.168.1.64</IPv4Address>
<IPv4SubnetMask>255.255.255.0</IPv4SubnetMask>
<IPv4Gateway>192.168.1.1</IPv4Gateway>
<IPv6Address>fe80::c62f:90ff:feab:cdef</IPv6Address>
<IPv6Gateway>::</IPv6Gateway>
<IPv6MaskLen>64</IPv6MaskLen>
<DHCP>false</DHCP>
<AnalogChannelNum>0</AnalogChannelNum>
<DigitalChannelNum>0</DigitalChannelNum>
<SoftwareVersion>V5.5.82build 190910</SoftwareVersion>
<DSPVersion>V7.3 build 190430</DSPVersion>
<BootTime>2026-07-19 06:14:02</BootTime>
<ResetAbility>true</ResetAbility>
<DiskNumber>0</DiskNumber>
<Activated>true</Activated>
<PasswordResetAbility>true</PasswordResetAbility>
<PasswordResetModeSecond>true</PasswordResetModeSecond>
<SupportHCPlatform>true</SupportHCPlatform>
<HCPlatformEnable>false</HCPlatformEnable>
<SupportSecurityQuestion>true</SupportSecurityQuestion>
<DeviceLock>false</DeviceLock>
<Salt>d41d8cd98f00b204e9800998ecf8427e</Salt>
</ProbeMatch>
```

**4.4.2 Factory-fresh, NOT activated (this is the case that must reach the UI)**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<ProbeMatch>
<Uuid>1F9B2A6C-4E1D-4F5A-9C3E-7A2B5D8E0C11</Uuid>
<Types>inquiry</Types>
<DeviceType>0</DeviceType>
<DeviceDescription>IPCamera</DeviceDescription>
<DeviceSN>DS-2CD2347G2-LU20260401AAWRJ98765432</DeviceSN>
<CommandPort>8000</CommandPort>
<HttpPort>80</HttpPort>
<MAC>44-19-b6-11-22-33</MAC>
<IPv4Address>192.168.1.64</IPv4Address>
<IPv4SubnetMask>255.255.255.0</IPv4SubnetMask>
<IPv4Gateway>192.168.1.1</IPv4Gateway>
<IPv6Address>::</IPv6Address>
<DHCP>false</DHCP>
<AnalogChannelNum>0</AnalogChannelNum>
<DigitalChannelNum>0</DigitalChannelNum>
<SoftwareVersion>V5.7.3build 220315</SoftwareVersion>
<DSPVersion>V5.0 build 220301</DSPVersion>
<BootTime>2026-07-26 09:41:55</BootTime>
<DiskNumber>0</DiskNumber>
<Activated>false</Activated>
<PasswordResetAbility>false</PasswordResetAbility>
<SupportHCPlatform>true</SupportHCPlatform>
<Salt>3f8a1c02b7e44d15a9c6ef2b7d5401aa</Salt>
</ProbeMatch>
```

**4.4.3 16-channel NVR**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<ProbeMatch>
<Uuid>1F9B2A6C-4E1D-4F5A-9C3E-7A2B5D8E0C11</Uuid>
<Types>inquiry</Types>
<DeviceType>2</DeviceType>
<DeviceDescription>NVR</DeviceDescription>
<DeviceSN>DS-7616NI-K2/16P1620201105AAWR123456789WCVU</DeviceSN>
<CommandPort>8000</CommandPort>
<HttpPort>80</HttpPort>
<HttpsPort>443</HttpsPort>
<RtspPort>554</RtspPort>
<MAC>bc-ad-28-de-ad-be</MAC>
<IPv4Address>10.0.20.11</IPv4Address>
<IPv4SubnetMask>255.255.255.0</IPv4SubnetMask>
<IPv4Gateway>10.0.20.1</IPv4Gateway>
<DHCP>true</DHCP>
<AnalogChannelNum>0</AnalogChannelNum>
<DigitalChannelNum>16</DigitalChannelNum>
<SoftwareVersion>V4.30.085build 200922</SoftwareVersion>
<DSPVersion>V1.0 build 200901</DSPVersion>
<BootTime>2026-06-02 18:22:41</BootTime>
<DiskNumber>2</DiskNumber>
<Activated>true</Activated>
<PasswordResetAbility>true</PasswordResetAbility>
<SupportHCPlatform>true</SupportHCPlatform>
<OEMinfo></OEMinfo>
</ProbeMatch>
```

### 4.5 Parser design

`SADPCodec.decode` is a pure function over `Data`. It **never throws** — a malformed datagram on a
shared multicast group is normal and must not abort a discovery run.

```swift
public enum SADPDecodeResult: Sendable, Equatable {
    case probeMatch(SADPProbeMatch)
    /// Our own probe, looped back by the local stack (matched by Uuid + Types == "inquiry").
    case ownProbeEcho
    /// A probe from *another* SADP client on the LAN. Ignored, but counted as a diagnostic
    /// ("another discovery tool is active") — useful because it proves multicast RX works.
    case foreignProbe(uuid: String)
    /// A ProbeMatch answering somebody else's Uuid. We still ingest it: it is free information
    /// about a real device on our LAN. Marked `corroborating` (confidence −10).
    case foreignProbeMatch(SADPProbeMatch)
    /// Not XML at all — see §4.8.
    case opaque(SADPOpaquePayload)
    case malformed(reason: String, prefixHex: String)   // prefixHex = first 16 bytes, for logs
}

public struct SADPProbeMatch: Sendable, Hashable, Codable {
    public let uuid: String?
    public let deviceType: Int?
    public let deviceDescription: String?
    public let deviceSN: String?
    public let commandPort: UInt16?
    public let httpPort: UInt16?
    public let httpsPort: UInt16?
    public let rtspPort: UInt16?
    public let mac: MACAddress?
    public let ipv4Address: IPv4Address?
    public let ipv4SubnetMask: IPv4Address?
    public let ipv4Gateway: IPv4Address?
    public let ipv6Address: String?
    public let dhcp: Bool?
    public let softwareVersion: String?
    public let dspVersion: String?
    public let bootTimeLocalString: String?
    public let activated: Bool?
    public let passwordResetAbility: Bool?
    public let supportHCPlatform: Bool?
    public let analogChannelNum: Int?
    public let digitalChannelNum: Int?
    public let diskNumber: Int?
    public let oemInfo: String?
    public let deviceLock: Bool?
    /// Every element we saw, lowercase-keyed, values un-trimmed. Includes unknowns.
    public let raw: [String: String]
    /// UDP source address of the datagram (filled by the caller, not the XML).
    public let observedFrom: IPv4Address
    public let receivedAt: Date
}
```

**4.5.1 XML strategy.** Use `XMLParser` (present in Linux swift-corelibs-foundation) with a flat
`SADPElementCollector` delegate: on `didStartElement` push `elementName.lowercased()`, on
`foundCharacters` append to the current buffer, on `didEndElement` store
`raw[key] = buffer.trimmingCharacters(in: .whitespacesAndNewlines)` (last-wins). Depth is ignored —
SADP documents are two levels deep and namespace prefixes never appear, but stripping any `prefix:`
before the colon costs one line and guards against OEM firmware that adds one. If `XMLParser` reports
an error **and** we collected at least `Uuid` + one of `MAC`/`IPv4Address`, we still return the
`probeMatch` built from what we got (Hikvision firmware ships documents with unescaped `&` in
`DeviceDescription`; strict parsing would throw away a real camera).

Belt and braces: before handing bytes to `XMLParser`, sanitise with a single pass that replaces a bare
`&` not followed by `[A-Za-z#]{1,8};` with `&amp;`. Golden-tested.

**4.5.2 Encoding.** Try UTF-8; if that fails, GB18030 is **not** available on Linux Foundation, so fall
back to ISO-8859-1 (lossless for byte→scalar) and record `diagnostic: nonUTF8SADPPayload`. Chinese
`DeviceDescription` values then display as mojibake rather than failing the whole record; the model and
serial (ASCII) are unaffected, which is what actually matters.

**4.5.3 Serial → model extraction.** Hikvision `DeviceSN` is `<MODEL><YYYYMMDD><LETTERS><DIGITS>[suffix]`.
Algorithm (pure, tested against the fixtures in §14.3):

```swift
/// "DS-2CD2143G0-I20200114AAWRD12345678" -> model "DS-2CD2143G0-I", body "20200114AAWRD12345678"
/// "DS-7616NI-K2/16P1620201105AAWR123456789WCVU" -> model "DS-7616NI-K2/16P16"
public static func splitSerial(_ sn: String) -> (model: String?, remainder: String)
```

Find the **last** occurrence of a regex-free scan for 8 consecutive digits that form a plausible date
(`YYYY` in 2005…2035, `MM` in 01…12, `DD` in 01…31). Everything before it is the model; if no such run
exists, model is nil and the whole string is the serial. Never crash on short/empty serials.
`serialNumber` stores the **full original** `DeviceSN` (that is what the label on the camera says and
what ISAPI returns); `model` stores the extracted prefix.

**4.5.4 `BootTime` has no time zone.** It is the device's local wall clock. We must not pretend it is
UTC. Store the raw string in `SADPProbeMatch.bootTimeLocalString`, and convert to `Date` using
`TimeZone.current` **only** for display, flagging the value as approximate. `DiscoveredDevice.bootTime`
is therefore documented as "device-local, interpreted in the Mac's zone, ±1 day". The uptime shown in
the UI is derived from it and rendered as "about 7 days" — never to the second.

**4.5.5 Rate/flood protection.** Cap ingest at **512 SADP datagrams per run** and **32 per source
address per run**; beyond that, drop and emit `DiscoveryDiagnostic.sadpFlood(from:)`. A misbehaving
device or a discovery-tool storm must not make the app allocate unboundedly.

### 4.6 Activation state — required UI surfacing

`Activated=false` means the device has **no password at all**. Consequences we must encode:

* Every RTSP and ISAPI call will fail (Hikvision returns `401` with
  `<ResponseStatus><statusCode>4</statusCode><subStatusCode>notActivated</subStatusCode>`).
* The device is almost always at the factory address **192.168.1.64/24** (§4.7).
* Discovery emits the record with `activation == .notActivated` and `confidence` unchanged — we are
  *certain* about it, SADP said so.

Contract for `VigilUI` (normative):

1. The row renders with an amber "Needs activation" badge and is **not** greyed out.
2. The primary action changes from "Add" to **"Activate…"**, which opens a sheet requesting a password
   that satisfies Hikvision's rules: 8–16 characters, and at least **two** of {lowercase, uppercase,
   digit, special from `` !"#$%&'()*+,-./:;<=>?@[\]^_`{|}~ ``}. Reject the username as a substring.
3. Activation itself is performed by `VigilISAPI` via
   `PUT http://<ip>/ISAPI/System/activate` with body
   `<?xml version="1.0" encoding="UTF-8"?><ActivateInfo><password>…</password></ActivateInfo>`.
   **Discovery does not implement SADP-native activation** and deliberately ignores the `<Salt>` field:
   the ISAPI path is documented, works over plain HTTP on-subnet, and avoids re-implementing
   Hikvision's undocumented salted password transform. This is a decision, not a deferral.
4. After a successful activation the UI re-runs a **targeted** discovery (`DiscoveryConfiguration
   .single(address:)`) rather than a full sweep, so the row flips to `.activated` within ~1 s.

### 4.7 Off-subnet devices (the 192.168.1.64 problem)

SADP is link-local multicast, so we receive ProbeMatches from devices whose IPv4 address is **not in any
of our subnets** — the classic factory camera at `192.168.1.64` on a `10.0.20.0/24` LAN. These records:

* get `reachability = .offSubnet`;
* are **still emitted** (hiding them is the single most confusing thing a discovery tool can do);
* render with a "Different subnet — not reachable" note listing the device address/mask and our
  interface address/mask, plus the concrete remediation text: *"Change the camera's IP with Hikvision
  SADP or activate it and use Vigil's network settings, or add a temporary address in the camera's
  range to your Mac in System Settings → Network → Details → TCP/IP."*
* have `isAddable == true` only when `reachability != .offSubnet`; the "Add" button is disabled with
  the above explanation in a tooltip.

`SweepPlanner` records each interface subnet in the plan; `Reachability` is computed by testing
`plan.subnets.contains(where: { $0.contains(device.address) })`.

### 4.8 Obfuscated / non-XML SADP variants, and graceful degradation

Newer Hikvision firmware and SADP tool v3.x introduced datagram forms on port 37020 whose payload is
**not plaintext XML** (vendor-side obfuscation; the format is undocumented and varies by firmware).
Our policy is explicit and non-speculative:

1. **Classify, do not guess.** `SADPCodec.decode` first checks the payload prefix. If, after skipping
   leading whitespace/BOM, the bytes do not begin with `<` , the datagram is `opaque`.
2. **Two cheap, bounded recovery attempts** — both are deterministic, both are unit-tested, neither
   loops:
   * **Single-byte XOR recovery.** We know the plaintext must contain `<?xml` or `<ProbeMatch`. For
     each key `k` in `1…255`, XOR the first 16 bytes and test for the ASCII prefix `<?xml` or
     `<Probe`. On a hit, XOR the whole buffer with `k` and re-enter the XML path. Cost: ≤ 255 × 16
     byte comparisons.
   * **Deflate/zlib/gzip.** If the payload starts with `1f 8b` (gzip) or `78 01 / 78 9c / 78 da`
     (zlib), we do **not** inflate: no dependency-free inflate exists in the pure layer and we refuse
     to write one for a speculative case. We record the fact in the diagnostic so a future version can
     act on real captures.
3. **If both fail, degrade — never drop.** Emit a `DiscoveredDevice` built purely from the datagram's
   **UDP source address**:

   ```swift
   DiscoveredDevice(
       id: .endpoint(source, 80), address: source,
       vendor: .hikvision,            // only Hikvision devices talk on 37020 at all
       deviceClass: .unknown,
       sources: [.sadpMulticast],
       confidence: 35                 // "probably a Hikvision device, details unknown"
   )
   ```
   plus `DiscoveryDiagnostic.sadpOpaquePayload(from: source, length: n, prefixHex: "…")`. The subnet
   sweep and the ISAPI fingerprint will then fill in ports, model and realm for that host — this is
   exactly why the sweep runs even when SADP "worked".
4. `SADPOpaquePayload` retains `length`, first 32 bytes as hex, and an entropy estimate (Shannon over
   byte histogram, 0…8 bits/byte) so a bug report tells us whether it is encrypted (≈7.9) or merely
   scrambled (≈4.5).
5. We **never** attempt to write to a device over SADP (no IP-change, no password reset, no
   activation). Vigil's SADP implementation is strictly read-only. This removes the entire class of
   "we bricked the camera's network config" bugs.

```swift
public struct SADPOpaquePayload: Sendable, Hashable, Codable {
    public let source: IPv4Address
    public let length: Int
    public let prefixHex: String        // first 32 bytes, lowercase, no separators
    public let entropyBitsPerByte: Double
    public let looksCompressed: Bool    // gzip/zlib magic
}
```

### 4.9 Unicast SADP — the no-multicast fallback

Hikvision devices answer the **same inquiry payload sent by unicast UDP to `<host>:37020`**. This is
the backbone of our degraded mode (§9.5) because unicast UDP needs no multicast entitlement.

* During sweep tier A, for every host that answered **any** TCP port, and for every host present in
  the ARP cache, we send one unicast SADP probe to `host:37020` from a single ephemeral UDP socket and
  collect replies for `600 ms`.
* When multicast is unavailable, we widen this to **all** planned hosts, but rate-limit to
  `256 datagrams/second` (one 121-byte datagram per host; a /24 costs 254 datagrams ≈ 1 s) and cap
  total unicast probes at `4 096` per run.
* Replies are decoded by the identical `SADPCodec.decode`; `source` becomes `.sadpUnicast` (same trust
  weight as multicast — the payload is identical).

---

## 5. Mechanism 2 — ONVIF WS-Discovery

### 5.1 Transport parameters

| Parameter | Value |
|---|---|
| Group address | `239.255.255.250` |
| Group port | `3702` |
| Local bind | interface address, port `3702` with address+port reuse; ephemeral if bind fails |
| Unicast reception on the same socket | **required** (`NWMulticastGroup(for:disableUnicast: false)`) |
| Hop limit | `1` |
| Max datagram | `8 192` bytes (ONVIF ProbeMatches with many scopes reach ~2 kB) |
| Probes | 3, at `0 / 500 / 1000 ms`, each with a **fresh** `MessageID` |
| Listen window | until `1000 + 2500 = 3 500 ms` |

**Responses arrive from arbitrary source ports.** Per WS-Discovery, a device unicasts its
`ProbeMatches` back to the prober's *source* address/port, using an arbitrary *source* port of its own
(often 3702, often ephemeral). Two consequences, both mandatory:

1. We must send **from the same socket we listen on** — never `send()` on a throwaway socket. With
   `NWConnectionGroup` this is automatic, provided we do not pass `disableUnicast: true`.
2. We must **not** filter incoming datagrams by source port. Filtering is by `RelatesTo`/`MessageID`
   correlation (§5.5), never by port.

Some devices additionally multicast their `ProbeMatches` to the group; joining port 3702 catches those
too, and the `MessageID` dedupe set prevents doubles.

### 5.2 The exact Probe envelope

Probe #1 (`NetworkVideoTransmitter`), byte-exact, `\r\n` line endings (SOAP over UDP tolerates either;
gSOAP-based ONVIF stacks — which is nearly all of them — are happiest with CRLF):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope"
            xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing"
            xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery"
            xmlns:dn="http://www.onvif.org/ver10/network/wsdl">
  <e:Header>
    <w:MessageID>urn:uuid:9a6f2c41-8b3d-4a7e-9f10-2c5b8e7d3a91</w:MessageID>
    <w:To e:mustUnderstand="true">urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>
    <w:Action e:mustUnderstand="true">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action>
  </e:Header>
  <e:Body>
    <d:Probe>
      <d:Types>dn:NetworkVideoTransmitter</d:Types>
    </d:Probe>
  </e:Body>
</e:Envelope>
```

Normative details:

* SOAP **1.2** envelope namespace `http://www.w3.org/2003/05/soap-envelope`. Not SOAP 1.1.
* WS-Addressing namespace is the **2004/08** one; WS-Discovery is the **2005/04** one. These two
  different years are correct and are what ONVIF Core specifies. Getting them wrong is the single most
  common reason a Probe is silently ignored.
* `MessageID` is `urn:uuid:` + lowercase hyphenated v4 UUID (the form ONVIF's own examples use). We
  accept **both** `urn:uuid:x` and `uuid:x` in `RelatesTo` when correlating, because firmware differs.
* `To` is the literal string `urn:schemas-xmlsoap-org:ws:2005:04:discovery`.
* `mustUnderstand="true"` on `To` and `Action`, qualified with the envelope prefix.
* No `ReplyTo` — the default anonymous reply is what we want for UDP.
* No `<d:Scopes>` element: an empty Scopes element with the default matching rule is legal but some
  firmware treats it as "match nothing".

### 5.3 Probe schedule (retry policy, normative)

| # | t | `Types` content | Purpose |
|---|---|---|---|
| 1 | 0 ms | `dn:NetworkVideoTransmitter` | the standard ONVIF camera probe |
| 2 | 500 ms | `dn:NetworkVideoTransmitter tds:Device` (adds `xmlns:tds="http://www.onvif.org/ver10/device/wsdl"`) | catches devices that only advertise the Device service (some NVRs, encoders) |
| 3 | 1 000 ms | `<d:Probe/>` with **no** `Types` child | wildcard: catches NVRs advertising `NetworkVideoStorage`/`Recording`, and firmware with broken type matching |

Each probe carries a **fresh** `MessageID`; all three are recorded in the run's
`expectedMessageIDs: Set<String>`. The 500 ms spacing is the WS-Discovery-typical retransmit interval
and is short enough that the whole ONVIF phase closes inside our 3.5 s window.

### 5.4 Sample ProbeMatches

Received from `192.168.1.64:41276` → our `10.0.20.5:3702` (note the arbitrary source port):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<env:Envelope xmlns:env="http://www.w3.org/2003/05/soap-envelope"
              xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing"
              xmlns:wsdd="http://schemas.xmlsoap.org/ws/2005/04/discovery"
              xmlns:dn="http://www.onvif.org/ver10/network/wsdl"
              xmlns:tds="http://www.onvif.org/ver10/device/wsdl">
  <env:Header>
    <wsa:MessageID>urn:uuid:c1f4b2e0-77aa-4a1c-8f2b-000000000042</wsa:MessageID>
    <wsa:RelatesTo>urn:uuid:9a6f2c41-8b3d-4a7e-9f10-2c5b8e7d3a91</wsa:RelatesTo>
    <wsa:To>http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous</wsa:To>
    <wsa:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/ProbeMatches</wsa:Action>
    <wsdd:AppSequence MessageNumber="7" InstanceId="1751030401"/>
  </env:Header>
  <env:Body>
    <wsdd:ProbeMatches>
      <wsdd:ProbeMatch>
        <wsa:EndpointReference>
          <wsa:Address>urn:uuid:2419d68a-2dd2-21b2-a205-c42f90abcdef</wsa:Address>
        </wsa:EndpointReference>
        <wsdd:Types>dn:NetworkVideoTransmitter tds:Device</wsdd:Types>
        <wsdd:Scopes>onvif://www.onvif.org/type/Network_Video_Transmitter onvif://www.onvif.org/type/video_encoder onvif://www.onvif.org/Profile/Streaming onvif://www.onvif.org/Profile/G onvif://www.onvif.org/Profile/T onvif://www.onvif.org/hardware/DS-2CD2143G0-I onvif://www.onvif.org/name/HIKVISION%20DS-2CD2143G0-I onvif://www.onvif.org/location/china onvif://www.onvif.org/MAC/c4%3A2f%3A90%3Aab%3Acd%3Aef</wsdd:Scopes>
        <wsdd:XAddrs>http://192.168.1.64/onvif/device_service http://[fe80::c62f:90ff:feab:cdef]/onvif/device_service</wsdd:XAddrs>
        <wsdd:MetadataVersion>10</wsdd:MetadataVersion>
      </wsdd:ProbeMatch>
    </wsdd:ProbeMatches>
  </env:Body>
</env:Envelope>
```

A Dahua answer, for the "found, but not Hikvision" path:

```xml
      <wsdd:ProbeMatch>
        <wsa:EndpointReference>
          <wsa:Address>urn:uuid:5b3f2a10-0000-0000-0000-3cef8c112233</wsa:Address>
        </wsa:EndpointReference>
        <wsdd:Types>dn:NetworkVideoTransmitter</wsdd:Types>
        <wsdd:Scopes>onvif://www.onvif.org/type/Network_Video_Transmitter onvif://www.onvif.org/Profile/Streaming onvif://www.onvif.org/name/IPC-HDW4433C-A onvif://www.onvif.org/hardware/IPC-HDW4433C-A onvif://www.onvif.org/location/country/china</wsdd:Scopes>
        <wsdd:XAddrs>http://10.0.20.31/onvif/device_service</wsdd:XAddrs>
        <wsdd:MetadataVersion>1</wsdd:MetadataVersion>
      </wsdd:ProbeMatch>
```

### 5.5 Parsing rules

```swift
public struct WSDProbeMatch: Sendable, Hashable, Codable {
    public let endpointAddress: String?        // "urn:uuid:2419d68a-…-c42f90abcdef"
    public let types: [String]                 // prefix stripped: ["NetworkVideoTransmitter","Device"]
    public let scopes: ONVIFScopes
    public let xAddrs: [String]                // whitespace-split, order preserved
    public let metadataVersion: Int?
    public let relatesTo: String?
    public let messageID: String?
    public let appSequenceInstanceID: String?
    public let observedFrom: IPv4Address
    public let receivedAt: Date
}

public enum WSDiscoveryCodec {
    public static func encodeProbe(messageID: UUID, types: WSDProbeTypes) -> Data
    /// Never throws. Returns [] for anything that is not a ProbeMatches envelope.
    public static func decodeProbeMatches(_ data: Data,
                                         from source: IPv4Address,
                                         receivedAt: Date) -> WSDDecodeOutcome
}

public enum WSDProbeTypes: Sendable, Equatable {
    case networkVideoTransmitter
    case networkVideoTransmitterAndDevice
    case wildcard
}

public enum WSDDecodeOutcome: Sendable, Equatable {
    case probeMatches([WSDProbeMatch])
    case hello([WSDProbeMatch])       // unsolicited Hello — treat identically, source .wsDiscovery
    case bye(endpointAddress: String) // device leaving; UI marks the row stale but keeps it
    case otherAction(String)
    case notSOAP(prefixHex: String)
}
```

* **Namespace-agnostic, local-name matching.** Never compare prefixes. `XMLParser` with
  `shouldProcessNamespaces = true` gives `didStartElement` a `namespaceURI` plus a local
  `elementName`; we match on **local name** and only *validate* the namespace when it is present
  (a handful of cheap firmware emits no namespace declarations at all — accept those).
* **Path-keyed collection.** Maintain a `[String]` element-name stack; the parser recognises the
  paths `Envelope/Header/MessageID`, `…/RelatesTo`, `…/Action`, `…/AppSequence@InstanceId`,
  `Envelope/Body/ProbeMatches/ProbeMatch/{EndpointReference/Address,Types,Scopes,XAddrs,MetadataVersion}`.
  Anything else is ignored.
* **Correlation.** A datagram is *ours* if `RelatesTo` (after normalising `uuid:`↔`urn:uuid:` and
  lowercasing) is in `expectedMessageIDs`. If `RelatesTo` is absent or unknown we still ingest the
  match (`confidence −5`) — plenty of firmware omits it, and `Hello` messages never have one.
* **Dedupe.** Key = lowercased `endpointAddress` if present, else `"xaddr:" + first XAddr`. A run keeps
  a `Set` and drops repeats, but *updates* `lastSeen`.
* **Types.** Split on whitespace, strip everything up to and including `:`. Used for `deviceClass`:
  `NetworkVideoStorage`/`Recording` ⇒ `.nvr`; `NetworkVideoTransmitter` ⇒ `.camera`;
  `NetworkVideoDisplay` ⇒ `.decoder`.
* **Limits.** ≤ 64 `ProbeMatch` elements per datagram, ≤ 32 scopes each, ≤ 8 XAddrs each, ≤ 512
  characters per scope. Excess is truncated with a diagnostic; a hostile datagram must not OOM us.

### 5.6 Scopes extraction

Every scope is a URI. **Percent-decode each scope before interpreting it** (`HIKVISION%20DS-…` →
`HIKVISION DS-…`, `c4%3A2f…` → `c4:2f…`). Then match the path prefix, case-insensitively, on both
`onvif://www.onvif.org/` and the (illegal but seen) `onvif://<other-host>/`:

| Scope path | Field | Post-processing |
|---|---|---|
| `/name/<v>` | `ONVIFScopes.name` | trim; used as `displayName` when SADP gave none |
| `/hardware/<v>` | `.hardware` | trim; used as `model` when SADP gave none |
| `/location/<v>` and `/location/country/<v>` | `.location` | keep the deepest segment tail verbatim |
| `/Profile/<v>` | `.profiles` append | `Streaming`, `G`, `T`, `S`, `A`, `C`, `D`, `M` |
| `/type/<v>` | `.types` append | e.g. `Network_Video_Transmitter`, `video_encoder`, `ptz` |
| `/MAC/<v>` | `.macHint` | non-standard; parsed via `MACAddress(_:)`; **hint only** |
| anything else | `.raw` only | never discarded |

`type/ptz` (and `Profile/S` + hardware containing a dome/PTZ marker) promotes `deviceClass` to
`.ptzCamera`.

**MAC from the EndpointReference UUID.** Hikvision and Dahua both embed the MAC in the last 12 hex
digits of their endpoint UUID (`urn:uuid:2419d68a-2dd2-21b2-a205-c42f90abcdef` → `c4:2f:90:ab:cd:ef`).
We extract it only when **all** of these hold: the UUID matches `8-4-4-4-12` hex; the final 12 hex
digits parse as a MAC with `isUsableIdentity`; and the OUI is in our vendor table (§6.9). Result is
stored as a **hint** (`identityStrength .hint`) — it can *corroborate* a MAC learned from SADP or ARP
and it can seed `vendor`, but it must **never** be used alone as `DeviceIdentity.mac`. Rationale: the
false-positive cost (merging two distinct cameras) is much higher than the benefit.

### 5.7 Vendor inference from ONVIF alone

| Signal | Conclusion |
|---|---|
| `name` or `hardware` contains `HIKVISION`, or `hardware` matches `^DS-[0-9]`, `^iDS-`, `^HWI-`, `^HWN-` | `.hikvision` (`HWI/HWN` ⇒ HiLook ⇒ `.hikvisionOEM`) |
| `name`/`hardware` contains `DAHUA`, or matches `^IPC-`, `^DH-`, `^SD[0-9]`, `^NVR[0-9]` | `.dahua` |
| `name` contains `AXIS` | `.axis` |
| `name` contains `Reolink` | `.reolink` |
| XAddr host answers our ISAPI fingerprint (§6.7) | upgrade to `.hikvision`/`.hikvisionOEM` |
| none of the above | `.genericONVIF` |

We do **not** issue any ONVIF SOAP call beyond the Probe (no `GetDeviceInformation`, no
`GetCapabilities`). Those need WS-UsernameToken auth, would risk lockouts, and everything we want from
a Hikvision device we get from ISAPI. The `XAddrs` are recorded so a future ONVIF module has them.

---

## 6. Mechanism 3 — Targeted subnet sweep

### 6.1 Interface enumeration (macOS side)

`VigilTransport.SystemInterfaceEnumerator` implements `InterfaceEnumerating` using `getifaddrs(3)`.

```swift
public struct NetworkInterfaceInfo: Sendable, Hashable, Codable {
    public let name: String                // "en0"
    public let address: IPv4Address
    public let netmask: IPv4Address
    public let isPointToPoint: Bool        // IFF_POINTOPOINT — utun*, VPNs
    public let isWireless: Bool            // name matches en* AND SCNetworkInterface type is IEEE80211
    public let mtu: Int
    public var subnet: IPv4Subnet? { IPv4Subnet(address: address, mask: netmask) }
}
```

```swift
import Darwin

func enumerate() throws -> [NetworkInterfaceInfo] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else {
        throw DiscoveryError.interfaceEnumerationFailed(errno: errno)
    }
    defer { freeifaddrs(head) }

    var result: [NetworkInterfaceInfo] = []
    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let ifa   = ptr.pointee
        let flags = Int32(bitPattern: ifa.ifa_flags)
        guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
        guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
        guard let nm = ifa.ifa_netmask else { continue }

        let name = String(cString: ifa.ifa_name)
        let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            IPv4Address(rawValue: UInt32(bigEndian: $0.pointee.sin_addr.s_addr))
        }
        let mask = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            IPv4Address(rawValue: UInt32(bigEndian: $0.pointee.sin_addr.s_addr))
        }
        result.append(NetworkInterfaceInfo(name: name, address: addr, netmask: mask,
                                          isPointToPoint: flags & IFF_POINTOPOINT != 0,
                                          isWireless: Self.isWireless(name),
                                          mtu: Int(ifa.ifa_data.map { _ in 1500 } ?? 1500)))
    }
    return result
}
```

**Exclusion rules** (applied in `SweepPlanner`, pure and tested — *not* in the enumerator, so the rules
are Linux-testable):

| Rule | Reason |
|---|---|
| drop `lo0` / `isLoopback` | nothing to find |
| drop `awdl0`, `llw0` | Apple Wireless Direct Link / low-latency WLAN; multicast there is pointless and noisy |
| drop names matching `utun[0-9]+`, `ipsec[0-9]+`, `ppp[0-9]+`, or `isPointToPoint` | VPN tunnels; sweeping a corporate VPN is hostile. Overridable by `policy.includeTunnels` (off by default, exposed in Advanced settings) |
| drop `169.254/16` (`isLinkLocal`) | self-assigned; no cameras |
| drop `subnet.prefixLength < 16` | **hard guard**, §6.2 |
| keep `en*`, `bridge*` (Internet Sharing / Thunderbolt Bridge), `anpi*` | real camera-bearing links |
| de-duplicate identical subnets across interfaces | a Mac with Ethernet + Wi-Fi on the same LAN sweeps once, but multicast still runs per interface |

Multicast channels (§4, §5) are opened for **every** kept interface, including duplicates-by-subnet.

### 6.2 CIDR maths (pure) and the /16 guard

```swift
public struct IPv4Subnet: Hashable, Sendable, Codable, CustomStringConvertible {
    public let network: IPv4Address        // already masked
    public let prefixLength: UInt8         // 0...32

    public init(network: IPv4Address, prefixLength: UInt8)             // masks `network` for you
    /// nil when `mask` is not a valid contiguous netmask (e.g. 255.0.255.0).
    public init?(address: IPv4Address, mask: IPv4Address)
    /// Parses "192.168.1.0/24"; strict.
    public init?(cidr: String)

    public var mask: IPv4Address { get }
    public var broadcast: IPv4Address { get }
    public var addressCount: Int { prefixLength >= 31 ? (1 << (32 - Int(prefixLength)))
                                                      : (1 << (32 - Int(prefixLength))) }
    /// Excludes network and broadcast for prefix ≤ 30; for /31 and /32 returns all addresses.
    public var usableHostCount: Int { get }
    public func contains(_ a: IPv4Address) -> Bool { a.rawValue & mask.rawValue == network.rawValue }
    /// Lazy, allocation-free sequence over usable hosts in ascending order.
    public var hosts: IPv4HostSequence { get }
    public var description: String { "\(network)/\(prefixLength)" }
}

public struct IPv4HostSequence: Sequence, Sendable {
    public func makeIterator() -> AnyIterator<IPv4Address>
}
```

Netmask validity: `let m = mask.rawValue; m == 0 || (~m &+ 1) & ~m == 0` — i.e. `~m + 1` must be a
power of two. `prefixLength = m.nonzeroBitCount` after validity is confirmed.

**The guard.** `SweepPlanner` refuses to enumerate anything wider than a `/16`:

```swift
public enum SweepPlanError: Error, Sendable, Equatable {
    case noEligibleInterfaces
    /// prefixLength < 16 — 65 536+ hosts. Hard refusal; not user-overridable.
    case prefixTooWide(subnet: IPv4Subnet, hostCount: Int)
}

public enum SweepPolicy: Sendable {
    public static let minimumPrefixLength: UInt8 = 16       // hard floor
    public static let confirmationPrefixLength: UInt8 = 22  // 1 022 hosts; wider needs opt-in
}
```

* `prefixLength < 16` → the subnet is **dropped from the plan** and a
  `DiscoveryDiagnostic.subnetTooWide(subnet, hostCount)` is emitted. If that leaves no subnets, the run
  fails with `.noEligibleInterfaces` and the UI offers manual entry plus "sweep a custom range".
* `16 ≤ prefixLength < 22` → included **only** when `configuration.allowLargeSweep == true`. Otherwise
  the plan contains a **narrowed** subnet: the /24 containing our own address, plus every /24 that has
  at least one ARP-cache entry. This is the pragmatic behaviour for a corporate `/16` — it finds the
  cameras you can actually see without emitting 327 000 SYNs. `DiscoveryDiagnostic
  .subnetNarrowed(from:to:)` explains it in the UI ("Your network is large (10.0.0.0/16). Vigil scanned
  3 likely ranges. Scan all 65 534 addresses?").
* `prefixLength ≥ 22` → swept in full.

**Host ordering** (`DiscoveryPlan.hostOrder`) materially changes perceived speed. Order:

1. every ARP-cache address inside the subnet (they are provably alive);
2. the interface's gateway;
3. `x.x.x.64` (Hikvision factory default), then `.65`…`.79` (typical static blocks);
4. `.2`…`.99` ascending;
5. the remaining hosts in **bit-reversal (Van der Corput) order** over the host part, so the scan
   spreads across the range instead of walking a contiguous block. This makes the "found" count climb
   steadily rather than in bursts, and avoids hammering one switch port group.

```swift
/// Bit-reversal permutation of 0..<2^k, used for step 5.
static func vanDerCorput(index: Int, bits: Int) -> Int
```

### 6.3 ARP cache shortcut

Reading the ARP cache is free, needs no packets, and gives us a **MAC per on-link IP** — which is the
strongest identity we have (§7.1). It also seeds host ordering.

* macOS reader: `sysctl` over the routing table.

```swift
// VigilTransport/Discovery/ARPTableReader.swift
import Darwin

public struct SystemARPTableReader: ARPTableProviding {
    public func snapshot() throws -> [ARPEntry] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, 0x400 /* RTF_LLINFO */]
        var needed = 0
        guard sysctl(&mib, 6, nil, &needed, nil, 0) == 0, needed > 0 else {
            throw DiscoveryError.arpReadFailed(errno: errno)
        }
        var buffer = [UInt8](repeating: 0, count: needed)
        guard sysctl(&mib, 6, &buffer, &needed, nil, 0) == 0 else {
            throw DiscoveryError.arpReadFailed(errno: errno)
        }
        return buffer.withUnsafeBytes { ARPTableDecoder.decodeRouteDump($0, byteCount: needed) }
    }
}
```

* The **decoding is pure** and lives in `VigilDiscovery` so it is fuzz- and unit-testable on Linux
  against a recorded `sysctl` blob (§14.5):

```swift
public enum ARPTableDecoder {
    /// Walks rt_msghdr records: for each, the first sockaddr is a sockaddr_in (the IP), the second a
    /// sockaddr_dl (the link-layer address). Each sockaddr is advanced by roundup(sa_len, 4), with
    /// sa_len == 0 treated as 4. Records whose sdl_family != AF_LINK(18) or sdl_alen != 6 are skipped.
    /// Bounds-checked at every step; a truncated or hostile blob yields the entries parsed so far.
    public static func decodeRouteDump(_ raw: UnsafeRawBufferPointer, byteCount: Int) -> [ARPEntry]
    /// Fallback/companion parser for `arp -an`-style text, used in tests and for pasted diagnostics:
    /// "? (192.168.1.64) at c4:2f:90:ab:cd:ef on en0 ifscope [ethernet]"
    public static func decodeARPText(_ text: String) -> [ARPEntry]
}

public struct ARPEntry: Sendable, Hashable, Codable {
    public let address: IPv4Address
    public let mac: MACAddress
    public let interfaceIndex: Int32
    public let isIncomplete: Bool     // sdl_alen == 0 → address probed but unresolved
}
```

`roundup`: `@inline(__always) func roundup(_ n: Int) -> Int { n > 0 ? (1 + ((n - 1) | 3)) : 4 }`.

* **We read ARP twice.** Once at t≈5 ms (pre-snapshot, to seed host ordering and to pre-fill MACs for
  hosts SADP already told us about), and once **after sweep tier A completes** — because our own SYNs
  populate the cache. The post-snapshot is where most MACs actually come from on a LAN we have not
  touched yet. Entries with `isIncomplete` are ignored for identity but count as "host exists".
* We deliberately do **not** shell out to `/usr/sbin/arp`. `sysctl(PF_ROUTE)` is readable inside the
  App Sandbox, requires no entitlement, spawns no process, and cannot be defeated by a hardened-runtime
  or `Process`-related sandbox denial.
* ARP entries are matched into records only when the address is inside one of our planned subnets — an
  ARP entry for the router's other-subnet neighbour must not become a MAC identity for a camera.

### 6.4 Bonjour browse

```swift
// VigilTransport/Discovery/BonjourBrowser.swift
let descriptors: [NWBrowser.Descriptor] = [
    .bonjour(type: "_rtsp._tcp",       domain: nil),
    .bonjour(type: "_http._tcp",       domain: nil),
    .bonjour(type: "_axis-video._tcp", domain: nil),   // Axis; makes "found, not Hikvision" precise
]
```

* One `NWBrowser` per descriptor, `NWParameters.tcp` (browse only, no connection), started on a
  dedicated serial `DispatchQueue(label: "com.vigil.discovery.bonjour")`, results delivered into an
  `AsyncStream<BonjourService>` continuation.
* `browseResultsChangedHandler` gives `Set<NWBrowser.Result>` plus changes. We consume
  `.added`/`.changed` results whose endpoint is `.service(name:type:domain:interface:)`.
* **Resolution.** `NWBrowser` does not give addresses. To resolve, open an `NWConnection` to the
  `.service` endpoint with `NWParameters.tcp`, wait for `.ready`, read
  `connection.currentPath?.remoteEndpoint`, then **cancel immediately**. Cap resolution at 8 concurrent
  and 1 s each. TXT records arrive via `NWBrowser.Result.metadata == .bonjour(NWTXTRecord)`; we harvest
  the keys `path`, `model`, `macaddress`, `productname` when present (Axis publishes `macaddress`).
* Realistically **Hikvision cameras do not advertise Bonjour**. Bonjour is in the pipeline because it
  is nearly free, it catches Axis/Reolink/UniFi (so we can honestly say "found, but not Hikvision"),
  and because macOS may show the local-network permission prompt on the *browse*, which is a friendlier
  first prompt than a burst of SYNs. Bonjour contributes `bonjourName` and, when TXT provides it, a
  `mac` **hint**.
* `NSBonjourServices` must list all three types in `Info.plist` (§9.2) or the browse returns nothing on
  recent macOS.

### 6.5 TCP connect probes

**Port tiers.** Sweeping 5 ports × every host is wasteful; tiering cuts packets by ~55 % with no loss
of recall.

| Tier | Ports | Applied to |
|---|---|---|
| A | `554` (RTSP), `80` (HTTP/ISAPI) | every planned host |
| B | `8000` (Hikvision SDK), `443` (HTTPS), `8080` (alt HTTP) | hosts where tier A found **anything**, plus every ARP-cache host, plus every host named by SADP/WSD/Bonjour |
| C | `37777` (Dahua private), `2020`, `8554` | only when tier A/B answered but classification is still `.unknown` — these are classification aids, not discovery |

`configuration.additionalPorts: [UInt16]` appends to tier A (Advanced settings; e.g. someone who moved
HTTP to 8899).

**Probe semantics.** A "connect probe" is a TCP handshake and nothing more.

```swift
public enum TCPProbeOutcome: Sendable, Hashable {
    case open                       // handshake completed
    case refused                    // RST — host is alive, port closed. Valuable!
    case timedOut                   // no answer within the budget
    case unreachable(POSIXCode)     // EHOSTUNREACH / ENETUNREACH / EHOSTDOWN
    case blockedByPolicy            // local-network permission denied / sandbox — see §9.4
}
```

`case refused` is important: it proves the host exists even if no camera port is open, so it feeds
"host is alive" for host counting and for the permission-denial heuristic (§9.4).

**Timeout.** `350 ms`, enforced by us. `NWProtocolTCP.Options.connectionTimeout` is an `Int` in
**seconds** with a practical minimum of 1, so it cannot express 350 ms. Implementation:

```swift
func probe(_ host: VigilProtocols.IPv4Address, port: UInt16,
           timeout: Duration) async -> TCPProbeOutcome {
    let params = NWParameters.tcp
    (params.defaultProtocolStack.transportProtocol as! NWProtocolTCP.Options).noDelay = true
    (params.defaultProtocolStack.transportProtocol as! NWProtocolTCP.Options).connectionTimeout = 1
    (params.defaultProtocolStack.transportProtocol as! NWProtocolTCP.Options).enableKeepalive = false
    params.prohibitExpensivePaths = false
    params.requiredInterface = self.interface          // never leak probes onto a VPN
    params.serviceClass = .background                  // deprioritise vs. live video

    let endpoint = NWEndpoint.hostPort(host: .ipv4(Network.IPv4Address(host.description)!),
                                       port: .init(rawValue: port)!)
    let conn = NWConnection(to: endpoint, using: params)
    return await withTaskCancellationHandler {
        await withCheckedContinuation { (k: CheckedContinuation<TCPProbeOutcome, Never>) in
            let done = OSAllocatedUnfairLock(initialState: false)     // resume-exactly-once
            func finish(_ o: TCPProbeOutcome) {
                let first = done.withLock { if $0 { return false }; $0 = true; return true }
                if first { conn.cancel(); k.resume(returning: o) }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:                     finish(.open)
                case .waiting(let e), .failed(let e): finish(Self.classify(e))
                case .cancelled:                 finish(.timedOut)
                default: break
                }
            }
            conn.start(queue: self.queue)
            self.queue.asyncAfter(deadline: .now() + timeout.seconds) { finish(.timedOut) }
        }
    } onCancel: { conn.cancel() }
}
```

`.waiting` must be treated as terminal for a probe: Network.framework reports connection refusal and
`EHOSTUNREACH` as `.waiting(POSIXError)` and would retry forever otherwise. `classify` maps
`.posix(.ECONNREFUSED)` → `.refused`, `.posix(.EHOSTUNREACH)`/`.ENETUNREACH`/`.EHOSTDOWN` →
`.unreachable`, `.posix(.EPERM)`/`.EACCES` → `.blockedByPolicy`, anything else → `.timedOut`.

**Bounded concurrency: 128 in flight.** Implemented as a sliding window over a task group in the pure
orchestrator (so the limiter itself is Linux-tested):

```swift
await withTaskGroup(of: HostProbeResult.self) { group in
    var iterator = plan.hostOrder.makeIterator()
    var inFlight = 0
    while inFlight < limit, let host = iterator.next() { group.addTask { await probeHost(host) }
                                                          inFlight += 1 }
    while let result = await group.next() {
        inFlight -= 1
        await ingest(result)                       // merge + progress
        if Task.isCancelled { break }
        if let host = iterator.next() { group.addTask { await probeHost(host) }; inFlight += 1 }
    }
}
```

**File-descriptor budget.** Each in-flight `NWConnection` costs 1–2 descriptors. macOS gives GUI apps a
`RLIMIT_NOFILE` soft limit that is often `256`. At startup `VigilTransport.raiseFileDescriptorLimit()`
calls `getrlimit(RLIMIT_NOFILE)` and, if `rlim_cur < 4096`, `setrlimit` to `min(4096, rlim_max)`. The
effective sweep concurrency is then
`min(configuration.maxInFlightConnects, max(16, (Int(rlim_cur) - 96) / 2))`, and the clamp is reported
as `DiscoveryDiagnostic.concurrencyClamped(to:)`. Never exceed the budget — an `EMFILE` storm mid-sweep
would also break live video streams.

**Interface pinning.** `params.requiredInterface` is set to the `NWInterface` matching the subnet being
swept. Without it, macOS may route probes for `192.168.1.x` over an active VPN default route, producing
zero results and confusing everybody.

### 6.6 Fingerprint 1 — RTSP `OPTIONS`

Runs immediately for any host where `554` (or 8554) is `.open`. Raw bytes over `NWConnection`, no
`URLSession`, no credentials, one round trip:

```
OPTIONS rtsp://192.168.1.64:554/ RTSP/1.0\r\n
CSeq: 1\r\n
User-Agent: Vigil/1.0 (macOS; discovery)\r\n
\r\n
```

Read up to `4 096` bytes or until `\r\n\r\n`, `600 ms` budget, then close. Never send `Authorization`.

Interpretation:

| Response | Meaning |
|---|---|
| `RTSP/1.0 200 OK` + `Public: DESCRIBE, SETUP, …` | RTSP server, no auth on OPTIONS (normal for Hikvision) |
| `RTSP/1.0 401 Unauthorized` + `WWW-Authenticate: Digest realm="…"` | RTSP server, auth required; **realm is the fingerprint** |
| `RTSP/1.0 40x/50x` other | RTSP server, unusable for fingerprinting; still `.genericRTSP` |
| non-`RTSP/` first token | not RTSP; port 554 is something else |

Realm fingerprints (case-insensitive, anchored):

| Realm pattern | Vendor |
|---|---|
| `IP Camera(<5 alnum>)` e.g. `IP Camera(52799)` | `.hikvision` |
| `DS-[0-9A-Z]` … | `.hikvision` |
| `Hikvision` / `HIKVISION` | `.hikvision` |
| `IPC` alone, or `Login to <hex>` | `.dahua` |
| `AXIS_<12 hex>` e.g. `AXIS_ACCC8E123456` | `.axis` (the 12 hex digits **are** the MAC — extract as a hint) |
| `Reolink` | `.reolink` |
| anything else | unchanged |

The header scanner (`VigilDiscovery`, ~70 lines, pure):

```swift
public struct StartLineHeaderScanner {
    public struct Result: Sendable, Equatable {
        public var protocolToken: String      // "RTSP/1.0" | "HTTP/1.1"
        public var statusCode: Int?           // nil if unparseable
        public var reasonPhrase: String
        /// Lowercased header names → last value. Multi-value headers joined with ", ".
        public var headers: [String: String]
        public var bodyPrefix: Data           // ≤ 512 bytes, for <ResponseStatus> sniffing
        public var isTruncated: Bool
    }
    /// Never throws, never crashes. Tolerates bare \n, missing reason phrase, absent body,
    /// non-UTF8 bytes (decoded as ISO-8859-1), and headers with no colon (skipped).
    public static func scan(_ data: Data, headerByteLimit: Int = 8_192) -> Result?
    /// Parses `WWW-Authenticate: Digest realm="x", nonce="y", qop="auth"` into a dictionary,
    /// tolerating unquoted values and stray whitespace. Also handles `Basic realm="x"`.
    public static func authChallenge(_ value: String) -> (scheme: String, params: [String: String])?
}
```

### 6.7 Fingerprint 2 — HTTP `GET /ISAPI/System/deviceInfo`

Runs for any host where `80`, `8080` or `443` is `.open`. This is *the* Hikvision test.

```
GET /ISAPI/System/deviceInfo HTTP/1.1\r\n
Host: 192.168.1.64\r\n
User-Agent: Vigil/1.0 (macOS; discovery)\r\n
Accept: application/xml\r\n
Connection: close\r\n
\r\n
```

`600 ms`, read ≤ `4 096` bytes, **never** send `Authorization` (§6.10). For port 443 use
`NWParameters(tls: tlsOptionsAcceptingSelfSigned, tcp: …)` with a `sec_protocol_verify_block` that
accepts any certificate — cameras ship self-signed certs, and we are only reading a `Server` header, no
secrets cross this connection. (Credentialed ISAPI over TLS is `VigilISAPI`'s problem and applies real
pinning policy there.)

| Status | Body / headers | Conclusion |
|---|---|---|
| `401` + `WWW-Authenticate: Digest realm="…"` | `Server: App-webs/`, `DVRDVS-Webs`, `DNVRS-Webs`, `Hikvision-Webs` | **`.hikvision`** — the ISAPI path exists and is protected. Highest-value signal in the whole spec. |
| `401` with realm but a *foreign* `Server` header, path still present | — | `.hikvisionOEM` (HiLook/LTS/Annke/Safire/TruVision all keep `/ISAPI/`) |
| `200` + body containing `<DeviceInfo>` | parse `<model>`, `<serialNumber>`, `<macAddress>`, `<firmwareVersion>` opportunistically | `.hikvision`, auth disabled — rare, but we take the free metadata |
| `404` / `400` | any | not Hikvision-family; keep classifying via §6.8 |
| `403` + `<ResponseStatus>` with `subStatusCode` `notActivated` | — | `.hikvision`, `activation = .notActivated` |
| TLS/parse failure | — | inconclusive; do not downgrade an existing vendor |

Body sniffing is limited to `bodyPrefix` (512 bytes) and looks only for the literal substrings
`<DeviceInfo`, `<ResponseStatus`, `notActivated`, `<statusCode>`. No XML parser runs on a fingerprint
body — full ISAPI decoding is `VigilISAPI`'s job once credentials exist.

If the primary path is inconclusive we issue **one** more request, `GET /` (same budget), purely to
capture `Server` and any `WWW-Authenticate` realm. Total per host: at most 3 short requests.

### 6.8 Vendor classification matrix

Applied in `VendorClassifier.classify(_ evidence: ClassificationEvidence) -> (DeviceVendor,
DeviceClass, confidenceDelta: Int)`. Pure, table-driven, exhaustively unit-tested.

| Evidence | Vendor | Δconf |
|---|---|---|
| SADP ProbeMatch parsed | `.hikvision` (`.hikvisionOEM` if `OEMinfo` non-empty) | +45 |
| `/ISAPI/System/deviceInfo` → 401 with realm + Hik `Server` | `.hikvision` | +35 |
| `/ISAPI/…` → 401, non-Hik `Server` | `.hikvisionOEM` | +25 |
| RTSP realm matches `IP Camera(...)` / `DS-…` | `.hikvision` | +20 |
| ONVIF `name`/`hardware` contains `HIKVISION` / `^DS-` | `.hikvision` | +20 |
| ONVIF `hardware` `^HWI-`/`^HWN-` | `.hikvisionOEM` | +20 |
| Port `37777` open | `.dahua` | +30 |
| RTSP realm `Login to …`, or `Server: DahuaRtsp` / `Server: Boa/0.94` | `.dahua` | +20 |
| ONVIF name/hardware `^IPC-`, `^DH-`, `^SD`, contains `Dahua` | `.dahua` | +20 |
| RTSP/HTTP realm `AXIS_<hex12>`, or `_axis-video._tcp` Bonjour, or path `/axis-cgi/` | `.axis` | +30 |
| ONVIF ProbeMatch only, nothing above | `.genericONVIF` | +15 |
| RTSP 200/401 only | `.genericRTSP` | +10 |
| TCP open only | `.unknown` | +5 |
| MAC OUI table hit (§6.9) | matching vendor, **only if current vendor is `.unknown`** | +10 |

Conflicts resolve by **highest Δconf wins**; a tie keeps the earlier (more trusted, per
`DiscoverySource.trust`) verdict. A vendor is never downgraded from a specific value to `.unknown`.

**Suggested RTSP paths per vendor** (for `VigilCore`; discovery only records the vendor):

| Vendor | Main / sub stream path |
|---|---|
| `.hikvision`, `.hikvisionOEM` | `/Streaming/Channels/101` and `/Streaming/Channels/102` (NVR channel *n*: `/Streaming/Channels/<n>01`) |
| `.dahua`, `.dahuaOEM` | `/cam/realmonitor?channel=1&subtype=0` / `subtype=1` |
| `.axis` | `/axis-media/media.amp?resolution=1920x1080` |
| `.reolink` | `/h264Preview_01_main` / `_sub` |
| `.genericONVIF`, `.genericRTSP`, `.unknown` | none — the UI asks, offering the above as a picker |

### 6.9 OUI hints

`Resources/oui-seed.json` in `VigilDiscovery` (`resources: [.copy("Resources")]`, read via
`Bundle.module`), shape `{"c42f90": "hikvision", …}`, keys lowercase hex OUI, values
`DeviceVendor.rawValue`. Hint-only, weight `+10`, and **only** consulted when the vendor is still
`.unknown`. Seed contents (widely observed assignments; the file is data, not code, and is trivially
extended without a release):

| OUI | Vendor |
|---|---|
| `44:19:b6`, `c4:2f:90`, `bc:ad:28`, `4c:bd:8f`, `28:57:be`, `54:c4:15`, `a4:14:37` | `hikvision` |
| `3c:ef:8c`, `4c:11:bf`, `90:02:a9`, `e0:50:8b` | `dahua` |
| `00:40:8c`, `ac:cc:8e`, `b8:a4:4f` | `axis` |
| `ec:71:db` | `reolink` |
| `78:8a:20`, `f0:9f:c2`, `74:ac:b9` | `unifi` |

If `Bundle.module` resource loading fails (it must not, but be defensive), the table is empty and every
other signal still works. Never make discovery depend on this file.

### 6.10 Politeness and lockout avoidance (normative, safety-critical)

Hikvision devices lock an account after a small number of failed authentications (typically 5 attempts
→ 30 minutes, reported later via `/ISAPI/Security/userCheck` as `<lockStatus>` / `<retryLoginTime>`).
A discovery pass that guesses credentials would lock users out of their own cameras.

Therefore, **normative for every module**:

1. Discovery **never** sends an `Authorization` header, WS-UsernameToken, or RTSP credentials. Not
   even `admin:12345`. Not behind a flag.
2. Discovery issues **at most 3** HTTP/RTSP requests and **at most 5+3 TCP connects** per host per run.
3. One connect attempt per (host, port) per run; failures are never retried inside a run.
4. Global outbound budget per run: `maxDatagrams = 8 192`, `maxTCPConnects = 4 × plannedHosts + 512`.
   Exceeding either aborts the remaining sweep with `DiscoveryDiagnostic.budgetExhausted` and keeps
   results.
5. Re-running discovery is throttled to once per `3 s` by `VigilCore` (the UI's Rescan button is
   disabled during a run anyway).
6. `serviceClass = .background` on every probe connection so a sweep cannot starve live video.

---

## 7. Merge and dedupe model

Every mechanism produces `DeviceObservation` values. The `MergeEngine` (pure, actor-isolated inside the
coordinator) folds observations into `DiscoveredDevice` records.

```swift
public struct DeviceObservation: Sendable {
    public let source: DiscoverySource
    public let observedAt: Date
    public let address: IPv4Address                  // always known: it is a UDP source or a sweep host
    public var mac: MACAddress?
    public var macIsHintOnly: Bool = false           // §5.6 UUID-derived / TXT-derived MACs
    public var serialNumber: String?
    public var onvifUUID: String?
    public var fields: [DeviceFieldKey: FieldValue]  // only the fields this source actually observed
}

/// Closed set of value shapes a field can carry; keeps the merge table total and Codable.
public enum FieldValue: Sendable, Hashable, Codable {
    case string(String), int(Int), bool(Bool), port(UInt16), ipv4(IPv4Address), date(Date)
    case ports(Set<UInt16>), strings([String]), scopes(ONVIFScopes)
    case vendor(DeviceVendor), deviceClass(DeviceClass)
    case activation(ActivationState), reachability(Reachability), mac(MACAddress)
}
```

### 7.1 Identity ladder and normalisation

Identity is chosen by the **strongest available** key:

| Rank | Key | Normalisation | Trustworthy alone? |
|---|---|---|---|
| 4 | `MAC` | 48-bit integer; must satisfy `isUsableIdentity`; **hint-only MACs excluded** | yes |
| 3 | `DeviceSN` / ISAPI `serialNumber` | uppercase; strip all whitespace and `\0`; strip a trailing `WCVU`/`CCRR`-style 4-char lot suffix **only for comparison**, never for display; reject if < 8 chars or all identical characters | yes |
| 2 | ONVIF `EndpointReference` address | lowercase; strip `urn:uuid:`/`uuid:` prefix; reject the all-zero UUID and the known-bogus `00000000-0000-0000-0000-000000000000` | yes |
| 1 | `ip:httpPort` | as-is | **no** — provisional; replaced as soon as a stronger key appears |

Normalisation is pure and tested:

```swift
public enum IdentityNormalizer {
    public static func serialKey(_ raw: String) -> String?     // nil when unusable
    public static func onvifKey(_ raw: String) -> String?
}
```

### 7.2 Union-find over identity keys

Two observations describe the same device when they share **any** identity key. Because keys arrive
incrementally (sweep sees `ip:80`; ARP then supplies a MAC; SADP then supplies a serial), the merge
engine maintains a disjoint-set forest over a `String` key space:

```
key namespace:  "mac:c42f90abcdef" | "sn:DS-2CD2143G0-I20200114AAWRD12345678"
                "onvif:2419d68a-…" | "ep:192.168.1.64:80"
```

Algorithm per observation:

```
keys = [strongest…weakest keys derivable from this observation]
roots = distinct find(k) for k in keys where k already present
switch roots.count:
  0 → create a new record; union all keys into it
  1 → union all keys into that root; fold fields (§7.3)
  n>1 → CONFLICT-MERGE: the observation proves these provisional records are one device.
        Merge into the record with (a) the strongest identity, tie-broken by (b) earliest firstSeen.
        Emit .deviceMerged(absorbed: [DeviceIdentity], into: DeviceIdentity) so the UI can animate rows
        collapsing instead of blinking.
```

`find`/`union` are path-compressed with union-by-rank; the whole structure is `O(α(n))` and fits in a
`[String: Int]` plus two `[Int]` arrays. Cap the key space at `8 192` entries per run.

**Refusal to merge.** Two records are never merged when they carry **different** non-hint MACs, or
different normalised serials. If an observation would force that (e.g. an ARP entry says `192.168.1.64`
is MAC *A* while SADP said MAC *B* for the same IP), we treat it as address reuse (§7.4), not a merge,
and trust the **SADP/ISAPI** MAC over the ARP one (higher `trust`) while flagging
`DiscoveryDiagnostic.identityConflict`.

### 7.3 Field-level precedence

Each field carries a `FieldStamp(source, observedAt)`. A new value **overwrites** the old one iff:

```swift
func shouldOverwrite(existing: FieldStamp?, incoming: FieldStamp) -> Bool {
    guard let existing else { return true }                                  // 1. empty always fills
    if incoming.source.trust > existing.source.trust { return true }         // 2. stronger source wins
    if incoming.source.trust < existing.source.trust { return false }
    return incoming.observedAt > existing.observedAt                         // 3. same source: newer
}
```

Field-specific overrides on top of the generic rule:

| Field | Rule |
|---|---|
| `openPorts` | **union**, never replace; each port additionally stamped in `portProvenance` |
| `onvifServiceURLs` | append, de-duplicated, order-preserving |
| `onvifScopes.raw` | union |
| `sources` | union (by definition) |
| `activation` | `.notActivated` is **sticky within a run**: only a *newer SADP* observation or a successful ISAPI 200 may clear it. A missing value never clears it. |
| `vendor` | `VendorClassifier` arbitration (§6.8), not the generic rule; never regresses to `.unknown` |
| `deviceClass` | never regresses to `.unknown`; `.ptzCamera` beats `.camera` |
| `address` | see §7.4 — changing it is an event, not a silent write |
| `confidence` | recomputed from scratch after every fold (§7.6), never merged |
| `firstSeen` | `min`; `lastSeen` | `max` |

### 7.4 IP-change and address-reuse detection

`DiscoveryConfiguration.knownDevices` is seeded by `VigilCore` from persistence:

```swift
public struct KnownDeviceSnapshot: Sendable, Hashable, Codable {
    public let identity: DeviceIdentity        // whatever we stored: .mac preferred
    public let mac: MACAddress?
    public let serialNumber: String?
    public let lastKnownAddress: IPv4Address
    public let lastKnownHTTPPort: UInt16
    public let displayName: String?            // the user's own camera name
}
```

Three situations, three distinct events:

| Situation | Detection | Event | UI behaviour |
|---|---|---|---|
| **Same device, new IP** (DHCP lease change) | a discovered record's `mac`/`serial` matches a `KnownDeviceSnapshot`, but `address != lastKnownAddress` | `.addressChanged(identity, from:, to:)` | the row shows the *user's* saved camera name plus "Address changed: 192.168.1.64 → 192.168.1.77", with a one-click **Update** that rewrites the stored camera (`VigilCore.applyAddressChange`) instead of creating a duplicate |
| **New device at an old IP** (address reuse) | a discovered record's `address` equals some `lastKnownAddress` but its `mac`/`serial` **differs** | `.addressReused(address, previous:, now:)` | the new device appears as new; the saved camera is marked "Not found at 192.168.1.64 — a different device answered". Never silently re-point a saved camera. |
| **Known device, same IP** | both match | `.deviceUpdated` with `changes` | the row is badged "Already added" and the primary action becomes "Reveal in sidebar" |

Matching is by MAC first, then normalised serial. Port changes alone (`httpPort` 80 → 8000) do **not**
raise `.addressChanged`; they are ordinary field updates.

### 7.5 Merge pseudocode

```
func ingest(_ obs: DeviceObservation) -> [DiscoveryEvent] {
    events = []
    keys = identityKeys(obs)                        // ordered strongest → weakest
    roots = uniqueRoots(keys)
    record: DiscoveredDevice
    switch roots.count {
      case 0:  record = newRecord(from: obs); events.append(.deviceFound(record))
      case 1:  record = records[roots[0]]
      default: (record, absorbed) = collapse(roots)
               events.append(.deviceMerged(absorbed: absorbed, into: record.id))
    }
    bind(keys, to: record.index)

    changed: Set<DeviceFieldKey> = []
    for (key, value) in obs.fields where shouldOverwrite(record.provenance[key],
                                                         FieldStamp(obs.source, obs.observedAt)) {
        apply(value, to: &record, key: key, rule: fieldRule(key))
        record.provenance[key] = FieldStamp(obs.source, obs.observedAt)
        changed.insert(key)
    }
    record.id = strongestIdentity(of: keys) ?? record.id     // promote provisional → MAC/serial
    record.sources.insert(obs.source)
    record.lastSeen = max(record.lastSeen, obs.observedAt)
    record.reachability = computeReachability(record, plan)
    record.confidence = scoreConfidence(record)

    if !changed.isEmpty, !events.contains(where: { $0.isDeviceFound }) {
        events.append(.deviceUpdated(record, changes: changed))
    }
    events += knownDeviceEvents(for: record)                 // §7.4
    return events
}
```

Emission discipline: at most **one** `.deviceFound` per record ever; every later change is
`.deviceUpdated`. The UI can therefore insert rows with a spring animation and update in place with no
flicker, and a test can assert exact event sequences.

### 7.6 Confidence score

```
score = 0
  + max over all vendor evidence of its Δconf                      (§6.8, 0…45)
  + 15 if mac != nil && !macIsHintOnly
  + 10 if serialNumber != nil
  + 10 if model != nil
  +  5 per distinct source beyond the first, capped at 15
  + 10 if openPorts contains 554
  -  5 if the only source is .arpCache or .bonjour
  - 10 if the record came from a foreign ProbeMatch (§4.5)
clamped to 0…100
```

Thresholds used by the UI: `< 30` → "Possible device" (collapsed into a "Other devices found" section);
`30…69` → "Likely camera"; `≥ 70` → shown as a first-class camera row with a vendor glyph. Records with
`vendor.supportsISAPI` and `confidence ≥ 70` are pre-selected for adding.

---

## 8. Progress, ETA, cancellation

### 8.1 Progress model

```swift
public struct DiscoveryProgress: Sendable, Hashable, Codable {
    public var phase: DiscoveryPhase                 // the *narrowest* active phase, for the label
    public var activePhases: Set<DiscoveryPhase>
    public var devicesFound: Int                     // records with confidence ≥ 30
    public var candidatesFound: Int                  // all records
    public var hostsPlanned: Int
    public var hostsProbed: Int                      // tier A completed for this host
    public var hostsAlive: Int                       // .open or .refused on any port
    public var portProbesCompleted: Int
    public var portProbesPlanned: Int                // grows as tier B is scheduled — see §8.2
    public var multicastWindowRemaining: Duration
    public var elapsed: Duration
    public var estimatedRemaining: Duration?         // nil while indeterminate
    public var throughputHostsPerSecond: Double
    /// 0...1 for a determinate bar. nil for the first 300 ms (indeterminate shimmer).
    public var fraction: Double?
}

public enum DiscoveryPhase: String, Sendable, Hashable, Codable, CaseIterable {
    case planning, arpSnapshot, sadp, onvif, bonjour, sweepA, sweepB, fingerprint, settling, finished
}
```

`DiscoveryEvent.progress` is emitted **coalesced at 20 Hz maximum** (the coordinator holds a
`lastProgressEmit` instant and drops intermediate updates), so a 65 000-host sweep does not push
100 000 events into SwiftUI. Every `.deviceFound`/`.deviceUpdated` event forces an immediate progress
emission regardless of the throttle, so the counter never lags a visible row.

### 8.2 `fraction` and ETA

```
sweepWeight     = 0.75      // dominates for anything ≥ /24
multicastWeight = 0.25

sweepFraction     = portProbesPlanned == 0 ? 1 : Double(portProbesCompleted) / Double(portProbesPlanned)
multicastFraction = 1 - multicastWindowRemaining / totalMulticastWindow
fraction          = sweepWeight * sweepFraction + multicastWeight * multicastFraction
```

`portProbesPlanned` is `hostsPlanned × 2` (tier A) at start and **grows** as tier B/C work is scheduled.
A monotonic guard is mandatory: `fraction = max(fraction, lastReportedFraction)` — a progress bar that
goes backwards is worse than one that stalls. When the denominator grows, we slow the bar rather than
reverse it.

**ETA.** Throughput is an EWMA over host completions, `α = 0.2`, updated once per 100 ms tick:

```
instant = hostsCompletedInTick / tickSeconds
ewma    = 0.2 * instant + 0.8 * ewma          // seeded on the first tick with `instant`
sweepETA      = ewma > 0.5 ? Double(hostsPlanned - hostsProbed) / ewma : nil
estimatedRemaining = max(sweepETA ?? 0, multicastWindowRemaining.seconds)
```

Rules: suppress the ETA for the first `750 ms` and whenever `ewma < 0.5 hosts/s`; round for display to
`< 3 s` → "a moment", `< 60 s` → "about N seconds", else "about N minutes"; never let a displayed ETA
increase by more than 20 % between emissions (clamp upward drift) — jittery ETAs read as broken.

### 8.3 Deadlines

`overallDeadline = 12 s` for `hostsPlanned ≤ 254`, then `+8 s` per doubling of `hostsPlanned`, capped at
`180 s`:

```swift
let doublings = max(0, log2(Double(max(hostsPlanned, 254)) / 254).rounded(.down))
let deadline  = min(180.0, 12.0 + 8.0 * doublings)
```

Hitting the deadline emits `.finished(summary)` with `summary.terminationReason == .deadline`; the UI
shows "Stopped after 45 s — scanned 12 480 of 65 534 addresses" plus a "Keep scanning" button that
starts a fresh run resuming from `plan.hostOrder` index `hostsProbed`
(`DiscoveryConfiguration.resumeFrom`).

### 8.4 Cancellation

* `AsyncStream` + task-group cooperative cancellation throughout. `DiscoveryCoordinator.cancel()` sets a
  flag, cancels the root `Task`, and closes the stream after emitting a final `.finished(summary)` with
  `terminationReason == .cancelled`.
* `AsyncStream.Continuation.onTermination` (fires when the UI's `for await` loop exits, e.g. the sheet
  is dismissed) calls `cancel()`. There is no way to leak a running sweep.
* Every `NWConnection`, `NWConnectionGroup` and `NWBrowser` is created inside
  `withTaskCancellationHandler(operation:onCancel:)` whose `onCancel` calls `.cancel()`. Every
  `withCheckedContinuation` resumes exactly once, guarded by an `OSAllocatedUnfairLock<Bool>`.
* Cancellation is **fast**: the target is that all sockets are closed within `50 ms` of `cancel()`,
  because the user cancels by closing a sheet and macOS will animate it away immediately.
* Partial results survive: `coordinator.snapshot` still returns everything merged so far, and the UI
  keeps showing it.

---

## 9. Entitlements, Info.plist, permission flows, degraded modes

This section is normative for the app-bundle build script and for `VigilUI`. It is the part most likely
to be got wrong, and getting it wrong makes discovery silently return zero devices.

### 9.1 Entitlements (`Vigil.entitlements`)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <!-- Outbound TCP/UDP: RTSP, ISAPI, sweep probes. -->
    <key>com.apple.security.network.client</key>
    <true/>
    <!-- REQUIRED for discovery: we BIND UDP 37020 and 3702 and receive unsolicited inbound
         datagrams (devices multicast their ProbeMatch to the group). Without this the bind
         fails with EPERM inside the sandbox and SADP/WS-Discovery both return nothing. -->
    <key>com.apple.security.network.server</key>
    <true/>
    <!-- Multicast send/receive. Managed capability: requires an Apple-granted entitlement and a
         provisioning profile for distribution builds. See §9.3/§9.5. -->
    <key>com.apple.developer.networking.multicast</key>
    <true/>
    <!-- Snapshot/recording export destinations chosen by the user. -->
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
</dict>
</plist>
```

`com.apple.security.network.server` is the most commonly forgotten line in this file. Note that it is
about *binding a listening port*, not about being a server in any product sense.

### 9.2 `Info.plist` keys

```xml
<!-- Shown verbatim in the macOS Local Network permission alert. Write it for a human. -->
<key>NSLocalNetworkUsageDescription</key>
<string>Vigil searches your local network for Hikvision cameras and NVRs, and connects to them
to show live video.</string>

<!-- Required for NWBrowser Bonjour browsing; a browse for an undeclared type returns nothing. -->
<key>NSBonjourServices</key>
<array>
    <string>_rtsp._tcp</string>
    <string>_http._tcp</string>
    <string>_axis-video._tcp</string>
</array>

<!-- Cameras speak plain HTTP on the LAN and ship self-signed TLS certs. NSAllowsLocalNetworking
     permits cleartext to local hostnames/addresses without disabling ATS globally. -->
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
</dict>

<key>LSMinimumSystemVersion</key>
<string>14.0</string>
```

`NSAppTransportSecurity` matters only for the `URLSession` traffic in `VigilISAPI`; discovery's raw
`NWConnection` probes are outside ATS entirely. Both keys are still required — the discovery
fingerprint's *findings* are consumed by ISAPI calls that do go through `URLSession`.

### 9.3 Detecting whether we actually have the multicast entitlement

Two independent checks; both feed `EntitlementStatus`.

```swift
public struct EntitlementStatus: Sendable, Hashable, Codable {
    public var multicastEntitlementPresent: Bool     // static, from our own code signature
    public var multicastVerifiedWorking: Bool?       // empirical; nil until a channel start resolves
    public var localNetworkPermission: LocalNetworkPermission
}

public enum LocalNetworkPermission: String, Sendable, Hashable, Codable {
    case unknown       // not yet exercised
    case granted       // we received at least one inbound datagram or completed one LAN handshake
    case likelyDenied  // heuristic in §9.4 tripped
}
```

**Static check** — read our own embedded entitlements (macOS-only, `Security.framework`):

```swift
func selfEntitlements() -> [String: Any] {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return [:] }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
          let staticCode else { return [:] }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, .signingInformation, &info) == errSecSuccess,
          let dict = info as? [String: Any] else { return [:] }
    // kSecCodeInfoEntitlementsDict == "entitlements-dict"
    return dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
}
let hasMulticast = selfEntitlements()["com.apple.developer.networking.multicast"] as? Bool == true
```

**Empirical check** — start the multicast `NWConnectionGroup`; if it reaches `.failed` (or stays out of
`.ready`) within `400 ms`, or the send completes with `.posix(.EPERM)` / `.posix(.ENOPROTOOPT)` /
`.posix(.EACCES)`, set `multicastVerifiedWorking = false`. This is authoritative: entitlement
enforcement varies by OS version (`com.apple.developer.networking.multicast` is enforced on
iOS 14+ and on macOS 15 Sequoia and later; on macOS 14 an unentitled build usually still works), and a
locally ad-hoc-signed development build behaves differently from a notarised one. Never branch on OS
version — branch on the observed result, and cache it in `UserDefaults`
(`VigilMulticastCapabilityCache`, invalidated on app version change).

### 9.4 The macOS Local Network permission flow

On macOS 15 (Sequoia) and later, the *first* attempt to talk to a local-network address — a multicast
send, a Bonjour browse, or a plain TCP connect to a LAN IP — triggers the system alert:

> **"Vigil" would like to find and connect to devices on your local network.**
> *(body = `NSLocalNetworkUsageDescription`)* — **Don't Allow** / **Allow**

Critical properties we must design around:

1. The alert is **asynchronous and system-modal**; there is no API to query the state up front and no
   completion callback. `NWConnection`s started before the user answers simply hang in `.preparing`
   until the answer arrives (which is why the sweep's own `350 ms` timeout, and not the framework's,
   governs).
2. If the user chooses **Don't Allow**, local traffic is dropped **silently**. Connects time out; they
   do not fail with a distinguishable error. There is no notification.
3. The choice is remembered per app in System Settings → Privacy & Security → **Local Network**.

**Our sequencing.** The first thing a run does after planning is the Bonjour browse and the multicast
sends — deliberately, because they trigger the prompt while the sheet is showing an indeterminate
"Looking for cameras…" state and *before* we have spent our sweep budget. The 250 ms sweep delay exists
partly for this.

**Denial heuristic** (`LocalNetworkPermission.likelyDenied`) — all of these must hold at the end of the
run:

* zero inbound datagrams received on **any** multicast channel, and
* zero Bonjour results, and
* zero `.open` **and** zero `.refused` outcomes across the entire sweep (a real LAN with a router always
  yields at least one), and
* the interface's **gateway** produced `.timedOut` on both port 80 and 443, and
* `hostsProbed ≥ 20` (so we do not accuse the OS on a tiny or empty range).

When it trips, the coordinator emits
`DiscoveryDiagnostic.localNetworkPermissionLikelyDenied(interface:gateway:)` and `VigilUI` **replaces**
the empty state with a remediation panel — this is the single highest-value error message in the app:

> **Vigil can't see your local network**
> macOS is blocking Vigil from finding devices on this network. Open **Privacy & Security → Local
> Network** and switch **Vigil** on, then scan again.
> [ Open Privacy Settings ] [ Scan Again ]

The button opens
`URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!` via
`NSWorkspace.shared.open(_:)`. On macOS 14, where the pane does not exist, the panel is not shown at all
(the heuristic is only armed when `ProcessInfo.processInfo.isOperatingSystemAtLeast(15.0)`); instead we
show the generic firewall/VLAN empty state.

### 9.5 What happens when the multicast entitlement is absent — degraded mode (normative)

This is a first-class supported configuration (a developer building from source without an Apple
multicast grant will hit it, and so will anyone who declines the local-network prompt for multicast
only).

**Mechanically:**

| Capability | With entitlement | Without |
|---|---|---|
| SADP multicast probe | ✅ 239.255.255.250:37020 | ❌ send fails `EPERM`, or group never becomes `.ready` |
| SADP **unicast** probe to `host:37020` | ✅ | ✅ **unaffected** — plain unicast UDP |
| WS-Discovery multicast probe | ✅ | ❌ |
| WS-Discovery **unicast** probe to `host:3702` | ✅ | ✅ (some firmware answers; we try it) |
| Directed/limited broadcast (`x.x.x.255`, `255.255.255.255`) | ✅ | ❌ Apple's entitlement covers broadcast as well as multicast — **do not** design the fallback around broadcast |
| TCP connect sweep | ✅ | ✅ |
| Bonjour `NWBrowser` | ✅ | ✅ (mDNS via the system daemon, not our socket) |

**The fallback plan** (`DiscoveryConfiguration.multicastUnavailablePolicy = .unicastSweep`, the default):

1. Skip both multicast channels; emit `DiscoveryDiagnostic.multicastUnavailable(reason:)` exactly once.
2. Promote the sweep: start it at `t = 0` instead of `t = 250 ms`, and raise `maxInFlightConnects` from
   128 to `192` (there is no multicast traffic to protect any more).
3. Enable **unicast SADP for every planned host** (§4.9), rate-limited to 256 datagrams/s and capped at
   4 096 datagrams, interleaved with tier A so replies arrive while the bar is moving.
4. Send a **unicast** WS-Discovery Probe to `host:3702` for hosts where tier A found port 80 or 554
   open (cheap, and a real subset of ONVIF firmware answers unicast probes).
5. Extend `overallDeadline` by `+40 %` (a unicast sweep is inherently slower than a multicast round
   trip).

**User-facing consequence — be honest and specific.** `VigilUI` shows a persistent-but-quiet inline
notice in the discovery sheet's footer (never a modal, never blocking):

> **Scanning by address.** Multicast isn't available in this build, so Vigil is checking each address on
> your network individually. This is slower and **won't find cameras on a different subnet** (for
> example a factory-fresh camera still on 192.168.1.64). [Learn more]

The three concrete losses, all of which must be stated in the "Learn more" popover:

1. **Off-subnet devices become invisible.** A factory camera at `192.168.1.64` while the Mac is on
   `10.0.20.0/24` is only findable via link-local multicast. This is the biggest loss and it is exactly
   the unboxing scenario, so it must be spelled out where a new user will read it.
2. **Slower.** A `/24` goes from ~1.5 s (SADP first result at ~50 ms) to ~4–6 s.
3. **Fewer details before adding.** Without a SADP ProbeMatch we may not know serial, firmware, or
   activation state until credentials are supplied, so the row shows "Hikvision device" rather than
   "DS-2CD2143G0-I · firmware V5.5.82 · needs activation".

**Build-script contract.** `Scripts/build-app.sh` embeds `Vigil.entitlements` as written in §9.1 and
does **not** strip the multicast key. If codesigning fails **because** of the multicast entitlement
(no provisioning profile present), the script re-signs with `Vigil-nomulticast.entitlements` (identical
minus that one key), prints a loud warning, and defines nothing at compile time — the app discovers the
situation at runtime via §9.3 and degrades per this section. There is no compile-time flag for
multicast: one binary, runtime-adaptive.

---

## 10. Public Swift API of `VigilDiscovery`

### 10.1 Injected environment

```swift
// MARK: - Capability protocols (all implemented in VigilTransport on macOS, mocked in tests)

/// A bound UDP endpoint that can send to a destination and yields inbound datagrams.
public protocol DatagramChannel: Sendable {
    var localPort: UInt16 { get }
    var interfaceName: String? { get }
    func send(_ payload: Data, to host: IPv4Address, port: UInt16) async throws
    /// Terminates when the channel is closed or cancelled. Never throws mid-stream.
    var inbound: AsyncStream<InboundDatagram> { get }
    func close() async
}

public struct InboundDatagram: Sendable, Hashable {
    public let payload: Data
    public let source: IPv4Address
    public let sourcePort: UInt16
    public let interfaceName: String?
    public let receivedAt: Date
}

public struct MulticastGroupSpec: Sendable, Hashable {
    public let group: IPv4Address          // 239.255.255.250
    public let port: UInt16                // 37020 | 3702
    public let preferredLocalPort: UInt16  // same as `port`; falls back to ephemeral
    public let interfaceName: String
    public let hopLimit: Int               // 1
}

public protocol TCPProbing: Sendable {
    func probe(_ host: IPv4Address, port: UInt16, timeout: Duration,
               interfaceName: String?) async -> TCPProbeOutcome
}

/// One request/response exchange over a fresh TCP (or TLS) connection. Used for the RTSP OPTIONS and
/// HTTP fingerprints. `readLimit` bounds the response we buffer.
public protocol ByteExchanging: Sendable {
    func exchange(host: IPv4Address, port: UInt16, useTLS: Bool, request: Data,
                  readLimit: Int, timeout: Duration,
                  interfaceName: String?) async throws -> Data
}

public protocol InterfaceEnumerating: Sendable {
    func interfaces() throws -> [NetworkInterfaceInfo]
}

public protocol ARPTableProviding: Sendable {
    func snapshot() throws -> [ARPEntry]
}

public struct BonjourService: Sendable, Hashable {
    public let name: String
    public let type: String
    public let domain: String
    public let address: IPv4Address?
    public let port: UInt16?
    public let txt: [String: String]
}

public protocol ServiceBrowsing: Sendable {
    func browse(types: [String]) -> AsyncStream<BonjourService>
}

/// Injected so tests can run a 12-second discovery in microseconds.
public protocol DiscoveryClock: Sendable {
    var now: Date { get }
    var uptime: Duration { get }               // monotonic; used for all elapsed maths
    func sleep(for duration: Duration) async throws
}

public struct DiscoveryEnvironment: Sendable {
    public var makeMulticastChannel: @Sendable (MulticastGroupSpec) async throws -> any DatagramChannel
    public var makeUnicastChannel:   @Sendable (String?) async throws -> any DatagramChannel
    public var tcpProbe: any TCPProbing
    public var exchange: any ByteExchanging
    public var interfaces: any InterfaceEnumerating
    public var arp: any ARPTableProviding
    public var bonjour: any ServiceBrowsing
    public var clock: any DiscoveryClock
    public var logger: any LoggerProtocol          // VigilProtocols; never OSLog directly
    public var entitlements: EntitlementStatus
    public var uuidGenerator: @Sendable () -> UUID  // deterministic in tests
}
```

### 10.2 Configuration and plan

```swift
public struct DiscoveryConfiguration: Sendable {
    public var mode: Mode = .fullScan
    public var tierAPorts: [UInt16] = [554, 80]
    public var tierBPorts: [UInt16] = [8000, 443, 8080]
    public var tierCPorts: [UInt16] = [37777, 8554, 2020]
    public var additionalPorts: [UInt16] = []
    public var tcpConnectTimeout: Duration = .milliseconds(350)
    public var fingerprintTimeout: Duration = .milliseconds(600)
    public var maxInFlightConnects: Int = 128
    public var sadpProbeSchedule: [Duration] = [.zero, .milliseconds(500), .milliseconds(1000)]
    public var onvifProbeSchedule: [Duration] = [.zero, .milliseconds(500), .milliseconds(1000)]
    public var multicastListenTail: Duration = .milliseconds(2500)
    public var sweepStartDelay: Duration = .milliseconds(250)
    public var settleQuietPeriod: Duration = .milliseconds(750)
    public var allowLargeSweep: Bool = false
    public var includeTunnels: Bool = false
    public var multicastUnavailablePolicy: MulticastUnavailablePolicy = .unicastSweep
    public var knownDevices: [KnownDeviceSnapshot] = []
    public var resumeFrom: Int = 0
    public var maxDatagramsPerRun: Int = 8_192
    public var overallDeadlineOverride: Duration?

    public enum Mode: Sendable, Equatable {
        case fullScan                                    // everything, all interfaces
        case multicastOnly                               // "Refresh" — 3.5 s, no sweep
        case subnets([IPv4Subnet])                       // user-entered range
        case single(address: IPv4Address, ports: [UInt16]) // post-activation re-check, manual add
    }
    public enum MulticastUnavailablePolicy: Sendable, Equatable { case unicastSweep, fail }

    public static let `default` = DiscoveryConfiguration()
    public static func single(address: IPv4Address) -> Self
}

public struct DiscoveryPlan: Sendable, Hashable {
    public let interfaces: [NetworkInterfaceInfo]
    public let subnets: [IPv4Subnet]
    public let hostOrder: [IPv4Address]        // materialised, ordered per §6.2
    public let tierAPorts: [UInt16]
    public let multicastInterfaces: [String]
    public let hostsPlanned: Int
    public let estimatedDuration: Duration
    public let narrowedFrom: [IPv4Subnet]      // non-empty when §6.2 narrowing applied
    public let refusedSubnets: [IPv4Subnet]    // prefix < 16
}

public enum SweepPlanner {
    public static func plan(interfaces: [NetworkInterfaceInfo],
                            arp: [ARPEntry],
                            configuration: DiscoveryConfiguration)
        -> Result<DiscoveryPlan, SweepPlanError>
}
```

### 10.3 Coordinator and events

```swift
public actor DiscoveryCoordinator {
    public init(environment: DiscoveryEnvironment,
                configuration: DiscoveryConfiguration = .default)

    /// Starts the run and returns the event stream. Calling twice on one instance is a programmer
    /// error and traps in debug / returns a finished stream in release.
    public func start() -> AsyncStream<DiscoveryEvent>
    public func cancel()
    public var snapshot: [DiscoveredDevice] { get }        // merged results so far, sorted (§10.4)
    public var progress: DiscoveryProgress { get }
    public var diagnostics: [DiscoveryDiagnostic] { get }
}

public enum DiscoveryEvent: Sendable {
    case started(DiscoveryPlan)
    case progress(DiscoveryProgress)
    case deviceFound(DiscoveredDevice)
    case deviceUpdated(DiscoveredDevice, changes: Set<DeviceFieldKey>)
    case deviceMerged(absorbed: [DeviceIdentity], into: DeviceIdentity)
    case addressChanged(DeviceIdentity, from: IPv4Address, to: IPv4Address)
    case addressReused(IPv4Address, previous: DeviceIdentity, now: DeviceIdentity)
    case phaseCompleted(DiscoveryPhase, PhaseSummary)
    case diagnostic(DiscoveryDiagnostic)
    case finished(DiscoverySummary)
}

public struct PhaseSummary: Sendable, Hashable {
    public let phase: DiscoveryPhase
    public let duration: Duration
    public let devicesContributed: Int
    public let datagramsSent: Int
    public let datagramsReceived: Int
    public let connectsAttempted: Int
}

public struct DiscoverySummary: Sendable, Hashable {
    public let terminationReason: TerminationReason      // .completed | .deadline | .cancelled | .failed
    public let devices: [DiscoveredDevice]
    public let elapsed: Duration
    public let hostsProbed: Int
    public let hostsPlanned: Int
    public let phases: [PhaseSummary]
    public let diagnostics: [DiscoveryDiagnostic]
    public let entitlements: EntitlementStatus
    public enum TerminationReason: String, Sendable, Hashable, Codable {
        case completed, deadline, cancelled, failed
    }
}
```

### 10.4 Stable sort order

`snapshot` and `summary.devices` are sorted by, in order: `confidence` descending → `vendor.supportsISAPI`
first → `address.rawValue` ascending → `id` description. Deterministic ordering matters: SwiftUI list
diffing must not reshuffle rows as confidence updates arrive, so the UI sorts once on
`.finished` and otherwise **inserts** new rows at their sorted position using the same comparator.

### 10.5 Codec entry points (usable standalone; this is what the tests hammer)

```swift
public enum SADPCodec {
    public static func encodeProbe(uuid: UUID) -> Data
    public static func decode(_ payload: Data, from source: IPv4Address,
                              expectedUUID: UUID?, receivedAt: Date) -> SADPDecodeResult
    public static func observation(from match: SADPProbeMatch,
                                  source: DiscoverySource) -> DeviceObservation
    public static func splitSerial(_ sn: String) -> (model: String?, remainder: String)
}

public enum WSDiscoveryCodec {
    public static func encodeProbe(messageID: UUID, types: WSDProbeTypes) -> Data
    public static func decodeProbeMatches(_ payload: Data, from source: IPv4Address,
                                          expectedMessageIDs: Set<String>,
                                          receivedAt: Date) -> WSDDecodeOutcome
    public static func parseScopes(_ raw: String) -> ONVIFScopes         // whitespace-split + %-decode
    public static func observation(from match: WSDProbeMatch) -> DeviceObservation
}

public enum FingerprintCodec {
    public static func rtspOptionsRequest(host: IPv4Address, port: UInt16) -> Data
    public static func isapiDeviceInfoRequest(host: IPv4Address) -> Data
    public static func rootRequest(host: IPv4Address) -> Data
    public static func classifyRTSP(_ response: Data) -> RTSPFingerprint
    public static func classifyHTTP(_ response: Data) -> HTTPFingerprint
}

public struct RTSPFingerprint: Sendable, Hashable {
    public let isRTSP: Bool
    public let statusCode: Int?
    public let realm: String?
    public let publicMethods: [String]
    public let serverHeader: String?
    public let macHint: MACAddress?          // from an AXIS_<hex12> realm
    public let vendor: DeviceVendor
}

public struct HTTPFingerprint: Sendable, Hashable {
    public let statusCode: Int?
    public let serverHeader: String?
    public let realm: String?
    public let isapiPathPresent: Bool        // 401/403/200 on /ISAPI/... (404 ⇒ false)
    public let notActivated: Bool
    public let inlineDeviceInfo: InlineDeviceInfo?    // when a 200 body carried <DeviceInfo>
    public let vendor: DeviceVendor
    public struct InlineDeviceInfo: Sendable, Hashable {
        public let model: String?; public let serialNumber: String?
        public let macAddress: MACAddress?; public let firmwareVersion: String?
    }
}

public enum VendorClassifier {
    public static func classify(_ e: ClassificationEvidence) -> ClassificationVerdict
}
```

---

## 11. macOS transport implementations (`VigilTransport/Discovery/`)

| File | Type | Implements |
|---|---|---|
| `MulticastDatagramChannel.swift` | `MulticastDatagramChannel` | `DatagramChannel` over `NWConnectionGroup` |
| `UnicastDatagramChannel.swift` | `UnicastDatagramChannel` | `DatagramChannel` over a connectionless `NWConnectionGroup` / per-destination `NWConnection` |
| `TCPConnectProber.swift` | `TCPConnectProber` | `TCPProbing` (§6.5) |
| `NWByteExchanger.swift` | `NWByteExchanger` | `ByteExchanging` (§6.6/§6.7), incl. self-signed TLS |
| `SystemInterfaceEnumerator.swift` | `SystemInterfaceEnumerator` | `InterfaceEnumerating` (§6.1) |
| `SystemARPTableReader.swift` | `SystemARPTableReader` | `ARPTableProviding` (§6.3) |
| `BonjourBrowser.swift` | `BonjourBrowser` | `ServiceBrowsing` (§6.4) |
| `EntitlementInspector.swift` | `EntitlementInspector` | §9.3 static check |
| `LiveDiscoveryEnvironment.swift` | `DiscoveryEnvironment.live(...)` | wires all of the above |

Every file in this directory is wrapped in `#if os(macOS)` per the architecture document's Linux-CI
mechanism.

### 11.1 `MulticastDatagramChannel`

```swift
import Network

public final class MulticastDatagramChannel: DatagramChannel, @unchecked Sendable {
    private let group: NWConnectionGroup
    private let queue = DispatchQueue(label: "com.vigil.discovery.mcast", qos: .userInitiated)
    private let continuation: AsyncStream<InboundDatagram>.Continuation
    public let inbound: AsyncStream<InboundDatagram>
    public private(set) var localPort: UInt16
    public let interfaceName: String?

    public init(spec: MulticastGroupSpec, interface: NWInterface) throws {
        let host = Network.IPv4Address(spec.group.description)!
        let mgroup = try NWMulticastGroup(
            for: [.hostPort(host: .ipv4(host), port: .init(rawValue: spec.port)!)],
            // MUST be false: ProbeMatches arrive as UNICAST from arbitrary source ports and must be
            // received on this very socket (§5.1).
            disableUnicast: false)

        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true          // SO_REUSEADDR|SO_REUSEPORT — coexist with SADP tool
        params.requiredInterface = interface
        params.prohibitExpensivePaths = false
        params.requiredLocalEndpoint = .hostPort(
            host: .ipv4(Network.IPv4Address(spec.localAddress.description)!),
            port: .init(rawValue: spec.preferredLocalPort)!)
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
            ip.hopLimit = UInt8(spec.hopLimit)         // TTL 1: keep SADP/WSD on-link
        }

        self.group = NWConnectionGroup(with: mgroup, using: params)
        (self.inbound, self.continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(512))
        …
        group.setReceiveHandler(maximumMessageSize: 8_192, rejectOversizedMessages: false) {
            [continuation] message, content, _ in
            guard let content, !content.isEmpty,
                  case let .hostPort(host, port)? = message.remoteEndpoint,
                  case let .ipv4(v4) = host,
                  let src = VigilProtocols.IPv4Address(v4.debugDescription
                                                         .split(separator: "%").first.map(String.init) ?? "")
            else { return }
            continuation.yield(InboundDatagram(payload: content, source: src,
                                              sourcePort: port.rawValue,
                                              interfaceName: interface.name, receivedAt: Date()))
        }
        group.stateUpdateHandler = { … }               // .ready → resume the start continuation
        group.start(queue: queue)
    }

    public func send(_ payload: Data, to host: IPv4Address, port: UInt16) async throws {
        try await withCheckedThrowingContinuation { k in
            group.send(content: payload,
                       to: .hostPort(host: .ipv4(Network.IPv4Address(host.description)!),
                                     port: .init(rawValue: port)!),
                       completion: { error in error.map { k.resume(throwing: $0) }
                                              ?? k.resume() })
        }
    }
}
```

Notes that implementers get wrong:

* **Retry the bind.** If `requiredLocalEndpoint` on port 37020/3702 fails (state `.failed` with
  `.posix(.EADDRINUSE)`), rebuild the group with **no** `requiredLocalEndpoint` (ephemeral) and set
  `DiscoveryDiagnostic.sadpDegradedEphemeralPort` / `onvifDegradedEphemeralPort`.
* **One channel per interface.** `params.requiredInterface` is mandatory; without it, macOS picks the
  primary route and Wi-Fi-attached cameras vanish when Ethernet is also up.
* **Parsing the source address.** Prefer extracting the address bytes from `Network.IPv4Address
  .rawValue` (`Data` of 4 bytes) rather than string round-tripping; the string form of a link-local IPv4
  can carry a `%en0` scope suffix. (Shown above with the defensive split for clarity.)
* Start is awaited with a `400 ms` timeout; failure to reach `.ready` means "no multicast" (§9.3), not a
  crash.

### 11.2 `NWByteExchanger` TLS options

```swift
let tls = NWProtocolTLS.Options()
sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in
    complete(true)                 // fingerprint only; no credentials cross this connection (§6.7)
}, queue)
sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv10)
```

Comment in the source must state, verbatim, that this permissive verifier exists **only** for the
unauthenticated discovery fingerprint and that `VigilISAPI` applies real trust policy for credentialed
traffic. A reviewer must not have to guess.

---

## 12. Error taxonomy and logging

```swift
public enum DiscoveryError: Error, Sendable, Equatable {
    case interfaceEnumerationFailed(errno: Int32)
    case noEligibleInterfaces
    case arpReadFailed(errno: Int32)
    case multicastUnavailable(reason: MulticastUnavailableReason)
    case channelBindFailed(port: UInt16, underlying: String)
    case planFailed(SweepPlanError)
    case cancelled
    case budgetExhausted(kind: BudgetKind)
}

public enum MulticastUnavailableReason: String, Sendable, Equatable, Codable {
    case entitlementMissing        // static check said no
    case permissionDenied          // EPERM/EACCES on send or bind
    case groupNeverReady           // timed out reaching .ready
    case noMulticastCapableInterface
}

public enum DiscoveryDiagnostic: Sendable, Hashable, Codable {
    case sadpDegradedEphemeralPort(interface: String)
    case onvifDegradedEphemeralPort(interface: String)
    case sadpOpaquePayload(from: IPv4Address, length: Int, prefixHex: String, entropy: Double)
    case sadpFlood(from: IPv4Address, dropped: Int)
    case nonUTF8SADPPayload(from: IPv4Address)
    case foreignDiscoveryClientActive(uuid: String)
    case subnetTooWide(subnet: IPv4Subnet, hostCount: Int)
    case subnetNarrowed(from: IPv4Subnet, to: [IPv4Subnet])
    case concurrencyClamped(to: Int, fileDescriptorLimit: Int)
    case multicastUnavailable(reason: MulticastUnavailableReason)
    case localNetworkPermissionLikelyDenied(interface: String, gateway: IPv4Address?)
    case identityConflict(address: IPv4Address, macA: MACAddress, macB: MACAddress)
    case budgetExhausted(kind: BudgetKind, limit: Int)
    case tunnelInterfaceSkipped(name: String)
    case offSubnetDeviceSeen(address: IPv4Address, ourSubnets: [IPv4Subnet])

    /// Localised, user-facing text. Empty for purely technical diagnostics (UI shows them only in the
    /// "Diagnostics" disclosure of the discovery sheet).
    public var userFacingMessage: String? { get }
    public var severity: Severity { get }      // .info | .warning | .actionRequired
}
```

**Logging.** `VigilDiscovery` logs exclusively through the injected `LoggerProtocol` from
`VigilProtocols` — no `import os`. Category strings it uses: `discovery`, `discovery.sadp`,
`discovery.onvif`, `discovery.sweep`, `discovery.merge`. Levels:

| Level | What |
|---|---|
| `.debug` | every datagram (source, length, first 16 bytes hex), every connect outcome |
| `.info` | phase start/end with `PhaseSummary`, each `.deviceFound` with identity + vendor + confidence |
| `.notice` | diagnostics of severity `.warning` |
| `.error` | `DiscoveryError` values that terminate a phase |

**Privacy.** MAC addresses and serial numbers are logged in full at `.debug` only; at `.info` and above
they are redacted to `c4:2f:90:**:**:**` and to the model prefix plus `…` respectively. IP addresses on
a private LAN are logged in full at all levels (they are not personal data and redacting them makes
support impossible). The macOS logger adapter passes user data as `%{private}@`.

---

## 13. Unit tests

All tests below run on **Linux Swift 6.1** with no network, using `swift-testing` (`@Test`) plus
`XCTest` where parameterised fixtures are easier. Fixtures live in
`Tests/VigilDiscoveryTests/Fixtures/` and are declared as
`resources: [.copy("Fixtures")]`, loaded via `Bundle.module`.

```swift
enum Fixture {
    static func data(_ name: String) throws -> Data          // Fixtures/<name>
    static func hex(_ name: String) throws -> Data           // strips whitespace/comments, parses hex
}
```

### 13.1 Test doubles

```swift
/// Replays a scripted list of (delay, datagram) pairs and records everything sent.
final actor MockDatagramChannel: DatagramChannel { … }
/// Table-driven: [IPv4Address: [UInt16: TCPProbeOutcome]] with an artificial per-probe latency.
struct MockTCPProber: TCPProbing { … }
/// Table-driven: [(host, port, requestPrefix) : responseData], asserts no Authorization header ever.
struct MockExchanger: ByteExchanging { … }
/// Virtual clock: `sleep(for:)` returns immediately and advances `uptime`. Makes a 12 s run take ~2 ms.
final actor VirtualClock: DiscoveryClock { … }
```

`MockExchanger` **fails the test** if any request contains `Authorization`, `authorization`, or a
`userinfo@host` form — this is how §6.10 is enforced mechanically rather than by review.

### 13.2 SADP tests

| # | Test | Assertion |
|---|---|---|
| 1 | `probeIsByteExact` | `SADPCodec.encodeProbe(uuid:)` equals `Fixtures/sadp-probe.bin` byte for byte, length 121 |
| 2 | `probeUUIDIsUppercaseHyphenated` | no braces, no lowercase hex, exactly 36 chars |
| 3 | `decodeActivatedCamera` | `sadp-probematch-camera.xml` → all 20+ fields as in §4.4.1; `mac == c4:2f:90:ab:cd:ef`; `rtspPort == 554` |
| 4 | `decodeNotActivated` | `sadp-probematch-inactive.xml` → `activated == false`, observation maps to `activation == .notActivated` |
| 5 | `decodeNVR` | `sadp-probematch-nvr.xml` → `digitalChannelNum == 16`, `deviceClass == .nvr`, `diskNumber == 2` |
| 6 | `macSeparatorVariants` | `c4-2f-90-ab-cd-ef`, `C4:2F:90:AB:CD:EF`, `c42f90abcdef`, `c42f.90ab.cdef` all → same `rawValue` |
| 7 | `unknownElementsPreserved` | a document with `<FutureThing>42</FutureThing>` keeps `raw["futurething"] == "42"` |
| 8 | `caseInsensitiveElementNames` | `<DEVICESN>` / `<devicesn>` both populate `deviceSN` |
| 9 | `unescapedAmpersandRecovered` | `<DeviceDescription>Lobby & Dock</DeviceDescription>` parses; value contains `&` |
| 10 | `truncatedDatagramDoesNotCrash` | every prefix `0..<n` of the camera fixture returns `.malformed` or a partial `.probeMatch`; never traps |
| 11 | `ownProbeEchoDetected` | our own probe bytes with our UUID → `.ownProbeEcho` |
| 12 | `foreignProbeMatchIngested` | ProbeMatch with a different `Uuid` → `.foreignProbeMatch`, confidence −10 |
| 13 | `opaqueXORRecovery` | `sadp-obfuscated-xor5a.bin` (fixture = camera XML XOR 0x5A) → decodes to the same `SADPProbeMatch` |
| 14 | `opaqueUnrecoverableDegrades` | 700 bytes of `/dev/urandom` → `.opaque` with `entropy > 7.0`, and the coordinator still emits a device with `confidence == 35` |
| 15 | `gzipMagicNotInflated` | payload starting `1f 8b` → `.opaque(looksCompressed: true)`, no crash |
| 16 | `serialSplitTable` | 12 parameterised serials → expected model/remainder (§14.3) |
| 17 | `bootTimeIsNotTreatedAsUTC` | `bootTimeLocalString` preserved verbatim; `Date` conversion uses the injected zone |
| 18 | `floodProtection` | 600 datagrams from one source → 512 ingested max, `sadpFlood` diagnostic emitted |
| 19 | `latin1Fallback` | payload with byte `0xB0` in `DeviceDescription` decodes, diagnostic `nonUTF8SADPPayload` |
| 20 | `unicastSADPUsesSameDecoder` | identical bytes via `.sadpUnicast` produce an identical record but `sources == [.sadpUnicast]` |

### 13.3 WS-Discovery tests

| # | Test | Assertion |
|---|---|---|
| 21 | `probeEnvelopeIsByteExact` | matches `Fixtures/wsd-probe-nvt.bin`; contains both `2004/08/addressing` and `2005/04/discovery`; `mustUnderstand="true"` on `To` and `Action` |
| 22 | `probeVariantsDiffer` | the three schedule entries produce NVT / NVT+Device / no-Types bodies and three distinct MessageIDs |
| 23 | `decodeHikvisionProbeMatch` | `wsd-probematch-hik.xml` → 1 match, `xAddrs == ["http://192.168.1.64/onvif/device_service", "http://[fe80::…]/onvif/device_service"]` |
| 24 | `scopesArePercentDecoded` | `name == "HIKVISION DS-2CD2143G0-I"`, `macHint == c4:2f:90:ab:cd:ef` |
| 25 | `scopeHardwareAndLocation` | `hardware == "DS-2CD2143G0-I"`, `location == "china"`; `location/country/china` also → `"china"` |
| 26 | `profilesCollected` | `profiles == ["Streaming","G","T"]` |
| 27 | `namespacePrefixAgnostic` | the same document with prefixes `s:`/`a:`/`t:` parses identically |
| 28 | `noNamespaceDeclarationsStillParses` | prefix-less variant parses |
| 29 | `relatesToCorrelation` | unknown `RelatesTo` still ingests, confidence −5; matching one does not |
| 30 | `uuidVersusUrnUuidNormalised` | `uuid:x` and `urn:uuid:X` correlate to the same expected ID |
| 31 | `dahuaProbeMatchClassified` | `wsd-probematch-dahua.xml` → `vendor == .dahua` |
| 32 | `helloAndByeHandled` | `wsd-hello.xml` → `.hello`; `wsd-bye.xml` → `.bye(endpointAddress:)` |
| 33 | `endpointUUIDMACIsHintOnly` | derived MAC never becomes `DeviceIdentity.mac`; two devices with distinct SADP MACs are not merged by matching UUID tails |
| 34 | `oversizedProbeMatchesTruncated` | 200 `ProbeMatch` elements → 64 parsed + diagnostic |
| 35 | `garbageIsNotSOAP` | random bytes → `.notSOAP`, no throw |

### 13.4 CIDR / planner / ARP tests

| # | Test | Assertion |
|---|---|---|
| 36 | `subnetFromAddressAndMask` | `192.168.1.64` + `255.255.255.0` → `192.168.1.0/24`; `usableHostCount == 254` |
| 37 | `nonContiguousMaskRejected` | `255.0.255.0` → `nil` |
| 38 | `slash31AndSlash32` | `/31` → 2 addresses, `/32` → 1; no network/broadcast exclusion |
| 39 | `hostSequenceExcludesNetworkAndBroadcast` | first `= .1`, last `= .254` for a /24 |
| 40 | `prefixWiderThanSixteenIsRefused` | a `/15` interface → `refusedSubnets` contains it, `hostOrder` empty, diagnostic `subnetTooWide` |
| 41 | `slash16NarrowsWithoutOptIn` | `10.0.0.0/16` + ARP entries in `10.0.5.x`,`10.0.9.x` → plan has `10.0.5.0/24`, `10.0.9.0/24`, and our own /24; `subnetNarrowed` emitted |
| 42 | `slash16FullWithOptIn` | `allowLargeSweep = true` → `hostsPlanned == 65_534` |
| 43 | `tunnelInterfacesSkipped` | `utun3` dropped, diagnostic emitted; kept when `includeTunnels` |
| 44 | `duplicateSubnetsDeduped` | en0 and en1 on `192.168.1.0/24` → one sweep, two multicast interfaces |
| 45 | `hostOrderPutsARPAndSixtyFourFirst` | exact expected prefix of `hostOrder` |
| 46 | `vanDerCorputIsAPermutation` | for `bits = 8`, the output is a bijection over `0..<256` |
| 47 | `arpRouteDumpDecoded` | `Fixtures/arp-routedump-macos14.bin` → 7 entries with expected IP/MAC pairs, 1 incomplete |
| 48 | `arpDumpTruncatedIsSafe` | every prefix of the blob decodes without trapping; returns a prefix of the entries |
| 49 | `arpTextParsed` | `arp -an` sample text → same entries |
| 50 | `arpEntriesOutsidePlanIgnored` | an entry in `172.16.x.x` does not attach a MAC to a `192.168.1.x` record |

### 13.5 Fingerprint tests

| # | Test | Assertion |
|---|---|---|
| 51 | `rtspOptionsRequestBytes` | exact bytes incl. `CSeq: 1` and terminating `\r\n\r\n`; no `Authorization` |
| 52 | `hikvisionRTSPRealm` | `IP Camera(52799)` → `.hikvision` |
| 53 | `axisRealmYieldsMACHint` | `AXIS_ACCC8E123456` → `.axis` + hint `ac:cc:8e:12:34:56` |
| 54 | `dahuaRealm` | `Login to 4a2b1c` → `.dahua` |
| 55 | `rtspTwoHundredWithPublic` | `Public:` list parsed into `publicMethods` |
| 56 | `bareLFHeadersTolerated` | response using `\n` only parses |
| 57 | `isapi401Hikvision` | `Server: App-webs/` + realm → `.hikvision`, `isapiPathPresent == true` |
| 58 | `isapi404NotHikvision` | 404 → `isapiPathPresent == false`, vendor unchanged |
| 59 | `isapi200InlineDeviceInfo` | 200 body with `<DeviceInfo>` → model/serial/mac/firmware extracted |
| 60 | `isapi403NotActivated` | `subStatusCode notActivated` → `notActivated == true` |
| 61 | `oemServerHeaderIsOEM` | ISAPI 401 with `Server: nginx` → `.hikvisionOEM` |
| 62 | `headerScannerBounded` | a 1 MB header block stops at `headerByteLimit`, `isTruncated == true`, no OOM |
| 63 | `classifierConflictResolution` | Dahua port 37777 (+30) beats a generic ONVIF verdict (+15) |
| 64 | `vendorNeverRegressesToUnknown` | applying a `.unknown` verdict after `.hikvision` is a no-op |

### 13.6 Merge / identity tests

| # | Test | Assertion |
|---|---|---|
| 65 | `sweepThenARPThenSADPCollapsesToOne` | 3 observations for one host → 1 record, 1 `.deviceFound`, 2 `.deviceUpdated`, 1 `.deviceMerged` when provisional roots collapse; final `id == .mac(...)` |
| 66 | `identityPromotion` | `.endpoint` → `.serial` → `.mac` as keys arrive |
| 67 | `differentMACsNeverMerge` | two records at the same IP with different MACs stay two records + `identityConflict` |
| 68 | `serialNormalisation` | `"ds-2cd…12345678 "` and `"DS-2CD…12345678"` unify; a 4-char serial is rejected as a key |
| 69 | `openPortsUnion` | tier A + tier B ports accumulate, never replace |
| 70 | `activationIsSticky` | a later ONVIF observation lacking activation does not clear `.notActivated` |
| 71 | `trustOrdering` | SADP model beats ONVIF hardware; manual beats everything |
| 72 | `addressChangedEvent` | known MAC at a new IP → `.addressChanged(from:to:)`, no duplicate record |
| 73 | `addressReusedEvent` | known IP, different MAC → `.addressReused`, saved camera not re-pointed |
| 74 | `offSubnetReachability` | SADP record `192.168.1.64` while plan is `10.0.20.0/24` → `.offSubnet`, `isAddable == false` |
| 75 | `confidenceScoring` | 6 parameterised evidence sets → exact expected scores |
| 76 | `oneDeviceFoundPerRecord` | across a 300-observation script, `.deviceFound` count == distinct devices |
| 77 | `deterministicSortOrder` | shuffled ingest order → identical `snapshot` ordering |

### 13.7 Orchestration / progress / cancellation tests

| # | Test | Assertion |
|---|---|---|
| 78 | `phaseOrderingAndOverlap` | with `VirtualClock`, SADP+ONVIF start at 10 ms, sweep at 250 ms, multicast closes at 3 510 ms |
| 79 | `fractionIsMonotonic` | across a run where tier B grows the denominator, `fraction` never decreases |
| 80 | `progressCoalescedAt20Hz` | 10 000 probe completions in virtual time → ≤ 21 progress events per virtual second, and one immediately after each `.deviceFound` |
| 81 | `etaSuppressedEarly` | `estimatedRemaining == nil` for the first 750 ms and while `ewma < 0.5` |
| 82 | `etaDoesNotJumpUpward` | synthetic throughput collapse → displayed ETA grows ≤ 20 % per emission |
| 83 | `concurrencyNeverExceedsLimit` | `MockTCPProber` records max simultaneous probes == 128 |
| 84 | `deadlineTerminatesWithResults` | a prober that never answers → `.finished(.deadline)` with the devices found so far |
| 85 | `cancelClosesStreamPromptly` | `cancel()` mid-sweep → final event is `.finished(.cancelled)`; mock channels all closed; no probe starts after cancel |
| 86 | `streamTerminationCancelsRun` | breaking out of `for await` → `onTermination` cancels, mocks closed |
| 87 | `budgetExhaustion` | `maxDatagramsPerRun = 10` → `budgetExhausted` diagnostic, results retained |
| 88 | `resumeFromContinuesSweep` | `resumeFrom = 100` → first probed host is `hostOrder[100]` |
| 89 | `singleAddressMode` | `.single(address:)` probes exactly one host, skips planning/multicast, completes < 1.5 s virtual |
| 90 | `noAuthorizationEverSent` | asserted globally by `MockExchanger` across the whole orchestration suite |

### 13.8 Degraded-mode tests

| # | Test | Assertion |
|---|---|---|
| 91 | `multicastMissingPromotesUnicastSweep` | `entitlements.multicastEntitlementPresent == false` → no multicast channel created; unicast SADP sent to every planned host; `multicastUnavailable(.entitlementMissing)` emitted once |
| 92 | `unicastSADPRateLimited` | ≤ 256 datagrams per virtual second, ≤ 4 096 total |
| 93 | `deadlineExtendedInDegradedMode` | deadline is `1.4 ×` the entitled value |
| 94 | `offSubnetDeviceUnfindableInDegradedMode` | documents the loss: the `192.168.1.64` script yields nothing, and the diagnostic set contains `multicastUnavailable` so the UI can explain why |
| 95 | `permissionDeniedHeuristic` | all probes `.timedOut`, gateway silent, ≥ 20 hosts → `localNetworkPermissionLikelyDenied` |
| 96 | `heuristicNotTrippedOnSmallRange` | 8 hosts, all silent → no permission diagnostic |
| 97 | `refusedCountsAsAlive` | one `.refused` anywhere suppresses the permission heuristic |
| 98 | `ephemeralPortFallback` | channel factory throws `EADDRINUSE` once → retry without a fixed local port, diagnostic emitted, run proceeds |
| 99 | `failPolicyStops` | `multicastUnavailablePolicy = .fail` → `.finished(.failed)` with `DiscoveryError.multicastUnavailable` |
| 100 | `endToEndSyntheticLAN` | scripted LAN (2 Hikvision cameras, 1 NVR, 1 Dahua, 1 Axis, 1 printer on port 80) → exactly 6 records with expected vendors, classes, confidences and identities |

Test 100 is the integration gate: it exercises planner → three mechanisms → fingerprints → merge →
events with only mocks, runs in well under a second of virtual time, and is the regression net for
every future change.

---

## 14. Fixture appendix

### 14.1 `Fixtures/sadp-probe.bin` (121 bytes, exact)

```
3c 3f 78 6d 6c 20 76 65 72 73 69 6f 6e 3d 22 31   <?xml version="1
2e 30 22 20 65 6e 63 6f 64 69 6e 67 3d 22 75 74   .0" encoding="ut
66 2d 38 22 3f 3e 0a 3c 50 72 6f 62 65 3e 0a 3c   f-8"?>.<Probe>.<
55 75 69 64 3e 31 46 39 42 32 41 36 43 2d 34 45   Uuid>1F9B2A6C-4E
31 44 2d 34 46 35 41 2d 39 43 33 45 2d 37 41 32   1D-4F5A-9C3E-7A2
42 35 44 38 45 30 43 31 31 3c 2f 55 75 69 64 3e   B5D8E0C11</Uuid>
0a 3c 54 79 70 65 73 3e 69 6e 71 75 69 72 79 3c   .<Types>inquiry<
2f 54 79 70 65 73 3e 0a 3c 2f 50 72 6f 62 65 3e   /Types>.</Probe>
0a                                                .
```

### 14.2 XML/text fixtures

| File | Content |
|---|---|
| `sadp-probematch-camera.xml` | §4.4.1 verbatim |
| `sadp-probematch-inactive.xml` | §4.4.2 verbatim |
| `sadp-probematch-nvr.xml` | §4.4.3 verbatim |
| `sadp-probematch-oem.xml` | §4.4.1 with `<OEMinfo>HiLook</OEMinfo>`, `DeviceSN` `HWI-B140H…`, `MAC` `4c-bd-8f-…` |
| `sadp-probematch-amp.xml` | §4.4.1 with `<DeviceDescription>Lobby & Dock</DeviceDescription>` |
| `sadp-probematch-latin1.bin` | §4.4.1 with byte `0xB0` inside `DeviceDescription` |
| `sadp-obfuscated-xor5a.bin` | `sadp-probematch-camera.xml` XOR `0x5A`, byte-wise |
| `sadp-random-700.bin` | 700 bytes from a fixed seed (`SplitMix64(seed: 0xC0FFEE)`) — deterministic, committed |
| `wsd-probe-nvt.bin` | §5.2 verbatim, CRLF line endings |
| `wsd-probematch-hik.xml` | §5.4 first sample |
| `wsd-probematch-dahua.xml` | §5.4 second sample wrapped in an envelope |
| `wsd-probematch-noprefix.xml` | same content, all namespace declarations removed |
| `wsd-hello.xml`, `wsd-bye.xml` | standard WS-Discovery Hello/Bye with the Hikvision endpoint |
| `rtsp-options-401-hik.txt` | `RTSP/1.0 401 Unauthorized` + `WWW-Authenticate: Digest realm="IP Camera(52799)", nonce="4e4f4e4345", stale="FALSE"` |
| `rtsp-options-200-hik.txt` | `RTSP/1.0 200 OK` + `Public: OPTIONS, DESCRIBE, PLAY, PAUSE, SETUP, TEARDOWN, SET_PARAMETER, GET_PARAMETER` |
| `rtsp-options-401-axis.txt` | realm `AXIS_ACCC8E123456` |
| `rtsp-options-401-dahua.txt` | realm `Login to 4a2b1c` |
| `http-isapi-401-hik.txt` | `HTTP/1.1 401 Unauthorized`, `Server: App-webs/`, `WWW-Authenticate: Digest qop="auth", realm="IP Camera(52799)", nonce="…", stale="FALSE", opaque=""` |
| `http-isapi-403-notactivated.txt` | `HTTP/1.1 403 Forbidden` + `<ResponseStatus><statusCode>4</statusCode><subStatusCode>notActivated</subStatusCode></ResponseStatus>` |
| `http-isapi-200-deviceinfo.txt` | 200 + `<DeviceInfo><deviceName>IPCamera</deviceName><model>DS-2CD2143G0-I</model><serialNumber>…</serialNumber><macAddress>c4:2f:90:ab:cd:ef</macAddress><firmwareVersion>V5.5.82</firmwareVersion></DeviceInfo>` |
| `http-isapi-404-other.txt` | `HTTP/1.1 404 Not Found`, `Server: Boa/0.94.14rc21` |
| `http-root-401-axis.txt` | 401 with `Server: Apache`, realm `AXIS_ACCC8E123456` |
| `arp-routedump-macos14.bin` | recorded `sysctl(PF_ROUTE, NET_RT_FLAGS)` blob, 7 entries incl. one `sdl_alen == 0` |
| `arp-text-macos14.txt` | `? (192.168.1.1) at 3c:37:86:11:22:33 on en0 ifscope [ethernet]` … |

### 14.3 Serial-split expectations (test 16)

| `DeviceSN` | Expected model |
|---|---|
| `DS-2CD2143G0-I20200114AAWRD12345678` | `DS-2CD2143G0-I` |
| `DS-2CD2347G2-LU20260401AAWRJ98765432` | `DS-2CD2347G2-LU` |
| `DS-7616NI-K2/16P1620201105AAWR123456789WCVU` | `DS-7616NI-K2/16P16` |
| `DS-2DE4A425IW-DE20211230AAWR555000111` | `DS-2DE4A425IW-DE` |
| `iDS-2CD7A46G0/P-IZHSY20220630AAWR777` | `iDS-2CD7A46G0/P-IZHSY` |
| `HWI-B140H20230101CCWR123456` | `HWI-B140H` |
| `DS-2CD2043G2-I` (no date) | `nil` (whole string is the serial) |
| `` (empty) | `nil` |
| `1234` | `nil` |
| `DS-XX20990101AAWR1` (invalid year) | `nil` |
| `DS-A20201232AAWR1` (invalid day) | `nil` |
| `DS-B2020010120200102AAWR1` (two dates → last wins) | `DS-B20200101` |

### 14.4 Scripted synthetic LAN for test 100

| Host | Answers | Expected record |
|---|---|---|
| `10.0.20.11` | SADP NVR fixture; TCP 80/554/8000 open; ISAPI 401 Hik | `.hikvision`, `.nvr`, conf 100, `id == .mac(bc:ad:28:de:ad:be)` |
| `10.0.20.31` | WSD Dahua fixture; TCP 80/554/37777 open; ISAPI 404 | `.dahua`, `.camera`, conf ≈ 60 |
| `10.0.20.42` | TCP 80/554 open; RTSP realm `IP Camera(11111)`; ISAPI 401 Hik; ARP MAC | `.hikvision`, `.camera`, conf ≈ 90 |
| `10.0.20.55` | TCP 80 open; RTSP/ISAPI absent; realm `AXIS_ACCC8E123456`; Bonjour `_axis-video._tcp` | `.axis`, conf ≈ 60 |
| `192.168.1.64` | SADP inactive-camera fixture only (off-subnet) | `.hikvision`, `.notActivated`, `.offSubnet`, `isAddable == false` |
| `10.0.20.90` | TCP 80 open; `Server: HP HTTP Server`; ISAPI 404; no RTSP | `.unknown`, conf ≈ 5, sorted into "Other devices" |

### 14.5 ARP blob layout reference (for hand-verifying test 47)

Each record: `rt_msghdr` (`rtm_msglen` at offset 0, `UInt16`, little-endian on all Apple platforms we
support; `rtm_version` at 2; `rtm_type` at 3) immediately followed by
`sockaddr_in` (`sin_len = 16` at offset 0, `sin_family = AF_INET(2)` at 1, `sin_addr` at 4, network
order) then, at `roundup(16) = 16` bytes further, `sockaddr_dl` (`sdl_len` at 0, `sdl_family = AF_LINK
(18)` at 1, `sdl_index` `UInt16` at 2, `sdl_type` at 4, `sdl_nlen` at 5, `sdl_alen` at 6, `sdl_slen` at
7, `sdl_data` at 8 — interface name for `sdl_nlen` bytes, then `sdl_alen` MAC bytes). The decoder must
bounds-check `sdl_nlen + sdl_alen + 8 <= sdl_len` before reading the MAC.

---

## 15. Cross-cutting contract for other modules

Everything in this list is a promise discovery makes or a requirement it imposes.

**`VigilProtocols` must declare** `IPv4Address` (UInt32-backed, §1.3) and `MACAddress` (UInt64-backed,
§1.3) exactly as specified, plus `LoggerProtocol`. Discovery, ISAPI, RTSP and Core all use them.

**Target graph:** `VigilDiscovery → VigilProtocols` **only**. Do not add an edge to `VigilRTSP`;
discovery carries its own 70-line lenient `StartLineHeaderScanner` by design (§1.2). All socket work is
in `VigilTransport/Discovery/*` behind the seven protocols of §10.1.

**`VigilCore` must:**
* supply `DiscoveryConfiguration.knownDevices` from persistence and implement `applyAddressChange`
  (§7.4) so a DHCP move updates the saved camera instead of duplicating it;
* build RTSP URLs from `vendor` using the path table in §6.8 (`/Streaming/Channels/101` for Hikvision,
  channel *n* → `<n>01`);
* build the ISAPI base URL from `httpPort`/`httpsPort` as `DiscoveredDevice.isapiBaseURL` computes it;
* throttle re-runs to one per 3 s.

**`VigilISAPI` owns** activation (`PUT /ISAPI/System/activate`) and credential checking
(`/ISAPI/Security/userCheck`). Discovery never authenticates — see the lockout rule below.

**`VigilUI` must** surface: `activation == .notActivated` as an amber "Needs activation" badge with an
**Activate…** primary action (§4.6); `reachability == .offSubnet` as "Different subnet — not reachable"
with the Add button disabled and a concrete remediation string (§4.7); the degraded-mode footer notice
when `multicastUnavailable` is diagnosed, explicitly stating that off-subnet cameras will not be found
(§9.5); and the Local Network remediation panel with the
`x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork` deep link when
`localNetworkPermissionLikelyDenied` fires (§9.4). Rows are keyed by `DiscoveredDevice.id` (which hashes
identity only) and animated on `.deviceFound` / `.deviceMerged`; never re-sort mid-run.

**Bundle requirements** (build script + architecture doc): entitlements exactly as §9.1 — including
`com.apple.security.network.server`, which is required to bind UDP 37020/3702 inside the sandbox — and
`Info.plist` keys `NSLocalNetworkUsageDescription`, `NSBonjourServices` (all three service types),
`NSAppTransportSecurity/NSAllowsLocalNetworking`, `LSMinimumSystemVersion 14.0` (§9.2). One binary, no
compile-time multicast flag: capability is detected at runtime (§9.3) and the app degrades to a unicast
sweep (§9.5). If signing without a multicast provisioning profile, the script re-signs with
`Vigil-nomulticast.entitlements` and warns loudly.

**Absolute rule — no credentials during discovery.** No `Authorization` header, no WS-UsernameToken, no
RTSP auth, ever, not behind a flag: Hikvision locks accounts after ~5 failed attempts. Budgets: ≤ 3
HTTP/RTSP requests and ≤ 8 TCP connects per host per run; ≤ 8 192 datagrams per run. `MockExchanger`
fails the test suite if any request carries credentials (§6.10, §13.1).

**Reusable pieces other modules should not re-implement:** `IPv4Subnet`/CIDR maths, `ARPTableDecoder`,
`StartLineHeaderScanner`, `VendorClassifier`, and the `/16` sweep guard all live in `VigilDiscovery` and
are public.

