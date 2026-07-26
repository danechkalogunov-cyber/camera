# Vigil — VigilCore Specification (Application Domain Layer)

> Module: **VigilCore** (macOS-only target). Layer between the pure protocol modules
> (`VigilProtocols`, `VigilRTSP`, `VigilRTP`, `VigilBitstream`, `VigilISAPI`, `VigilDiscovery`)
> and the presentation modules (`VigilRender`, `VigilUI`, `Vigil`).
>
> Status: **normative**. Every signature below is the API implementers must produce. Where a
> number appears it is the shipping default, not a suggestion. Nothing here is optional.

---

## 0. How to read this document

| Convention | Meaning |
|---|---|
| `public` on a declaration | Part of the module's API surface; other targets depend on it. Everything else is `internal`. |
| **MUST / MUST NOT** | Non-negotiable. A violation is a bug, not a style choice. |
| "budget" | A hard numeric ceiling enforced in code, with a test proving the ceiling. |
| `⟨T⟩` in a table | The Swift type crossing that boundary. |

Swift style follows `ARCHITECTURE.md` (110-column lines, no force-unwrap outside tests,
`MARK:` sections, doc comments on every `public` declaration).

---

## 1. Responsibility boundary

### 1.1 What VigilCore owns

1. **The domain model** — the vocabulary the whole app speaks (`Camera`, `CameraGroup`, `Layout`,
   `StreamProfile`, `DeviceCapabilities`, `EventRecord`, `RecordingClip`, `Bookmark`).
2. **Persistence** — `ConfigStore` (one JSON document) and `EventLog` (a second, ring-shaped JSON
   document). No other module reads or writes user data files.
3. **Secrets** — `CredentialStore` over the Keychain. No other module touches `Security.framework`.
4. **Per-camera lifecycle** — `StreamController`: the actor that owns one camera's RTSP session,
   depacketizer, decode sink, recorder and statistics.
5. **App-wide arbitration** — `StreamCoordinator`: what is live, at what quality, in what order,
   under a decode budget, reacting to layout, occlusion, sleep/wake and network changes.
6. **Capture features** — `ClipRecorder` (passthrough muxing), `SnapshotService`.
7. **Signals** — `EventCenter` (ISAPI alerts → notifications → auto-record),
   `HealthMonitor` (1 Hz sampling), `StreamDoctor`, `DiagnosticsBundleBuilder`.
8. **Automation surface** — App Intents entities/intents, the `vigil://` URL grammar, AppleScript
   command implementations.

### 1.2 What VigilCore MUST NOT do

- **No SwiftUI, no AppKit views.** `import SwiftUI` is forbidden in VigilCore. `import AppKit` is
  permitted **only** in `Occlusion+AppKit.swift`, `Pasteboard+AppKit.swift` and
  `QuickLook+AppKit.swift`, which are thin adapters behind protocols. Everything else uses
  Foundation / AVFoundation / CoreMedia / Security / Network / OSLog / UserNotifications /
  AppIntents / UniformTypeIdentifiers / ImageIO / CoreGraphics.
- **No wire-format parsing.** If you find yourself scanning bytes, the code belongs in
  `VigilRTSP` / `VigilRTP` / `VigilBitstream` / `VigilISAPI` / `VigilDiscovery`.
- **No hardware decode calls.** `VTDecompressionSession` and `AVSampleBufferDisplayLayer` belong to
  `VigilVideo` / `VigilRender`. VigilCore holds an `any DecodeSink` and does not know which is behind it.
- **No global mutable singletons** other than the explicitly-documented `CoreDependencies.live`.

### 1.3 Inbound contracts (types VigilCore consumes, owned elsewhere)

VigilCore does **not** redeclare these. If a name below is missing when the module is implemented,
that is a bug in the owning module, not licence to define a second copy.

| Type / protocol | Owner | Used by VigilCore for |
|---|---|---|
| `LoggerProtocol`, `LogLevel`, `LogRedaction` | VigilProtocols | all logging; VigilCore adapts it to OSLog in `OSLogLogger` |
| `MonotonicClock` (`now: Instant`, `sleep(until:)`, `timer(after:)`) | VigilProtocols | every timeout and backoff in this document |
| `MediaTimestamp` (`Int64 value`, `Int32 timescale`) | VigilProtocols | all presentation times; the only time type crossing the pure boundary |
| `EncodedFrame` (4-byte-length-prefixed NALs, `pts`, `dts`, `isKeyframe`, `codec`, `parameterSets`) | VigilRTP | the unit of media flowing into decode **and** into the recorder |
| `StreamStatistics` | VigilRTP | health sampling; VigilCore never recomputes fps/kbps itself |
| `RTSPSessionMachine` (`ingest(_:) -> [Event]`, `step(now:) -> [Action]`) | VigilRTSP | the pure state machine `StreamController` drives |
| `SDPDescription`, `SDPMediaTrack`, `RTSPCredentials` | VigilRTSP | track selection, codec resolution |
| `Depacketizer` protocol | VigilRTP | frame assembly |
| `ParameterSets`, `VideoDimensions`, `avcCRecord/hvcCRecord` builders | VigilBitstream | format description construction, snapshot sizing |
| `ISAPIClient` + response models (`DeviceInfo`, `SystemCapabilities`, `StreamingChannel`, `AlertStreamSession`, `CMSearchResult`) | VigilISAPI | capability probe, JPEG snapshots, alert stream, playback search |
| `DiscoveredDevice` | VigilDiscovery | `Camera` construction during onboarding |
| `DecodeSink`, `DecodePipeline`, `DecodeLease`, `DecodeScheduler`, `SampleBufferFactory` | VigilVideo | decode admission and CMSampleBuffer construction |
| `FrameTap` (`captureCurrentFrame() async -> CVPixelBuffer?`) | VigilRender | exact-displayed-frame snapshots |

### 1.4 Outbound contracts (what other modules may rely on)

`VigilUI` and `Vigil` talk to **`StreamCoordinator`** and read **`LiveViewState`**. They MUST NOT
hold a `StreamController` reference, MUST NOT call `ConfigStore.mutate` for anything a coordinator
method already covers, and MUST NOT construct a `Credential`.

---

## 2. Dependency injection

Everything time-, disk-, network- or Keychain-shaped is injected. This is what makes §17's test
list possible.

```swift
public struct CoreDependencies: Sendable {
    public var clock: any MonotonicClock
    public var logger: any LoggerProtocol
    public var fileSystem: any FileSystemProtocol
    public var keychain: any KeychainProtocol
    public var diskSpace: any DiskSpaceProbing
    public var pathMonitor: any NetworkPathMonitoring
    public var occlusion: any OcclusionObserving
    public var power: any PowerEventObserving
    public var notifications: any NotificationScheduling
    public var pasteboard: any PasteboardWriting

    /// Builds a control-plane client for one device. Credentials are passed per call and never
    /// captured in the closure.
    public var makeISAPIClient: @Sendable (ISAPIEndpoint, Credential) -> any ISAPIClient

    /// Builds a byte transport for one RTSP endpoint. Owned by VigilTransport in `.live`.
    public var makeRTSPTransport: @Sendable (RTSPEndpoint) -> any RTSPTransport

    /// Builds a decode sink for a resolved format. Owned by VigilVideo in `.live`.
    public var makeDecodeSink: @Sendable (StreamFormat, DecodeSinkOptions) async throws -> any DecodeSink

    /// Global decode admission authority. Owned by VigilVideo.
    public var decodeScheduler: any DecodeAdmitting

    public static let live: CoreDependencies
}
```

```swift
public protocol FileSystemProtocol: Sendable {
    func fileExists(at url: URL) -> Bool
    func read(_ url: URL) throws -> Data
    /// MUST fsync (F_FULLFSYNC) before returning.
    func writeDurably(_ data: Data, to url: URL) throws
    func replaceItem(at destination: URL, with source: URL, backupItemName: String?) throws
    func moveItem(at: URL, to: URL) throws
    func removeItem(at: URL) throws
    func createDirectory(at url: URL) throws
    func contentsOfDirectory(at url: URL) throws -> [URL]
    func attributes(of url: URL) throws -> FileAttributes   // size, mtime
}

public protocol KeychainProtocol: Sendable {
    func add(_ attributes: [String: Any]) -> OSStatus
    func copyMatching(_ query: [String: Any], _ result: inout CFTypeRef?) -> OSStatus
    func update(_ query: [String: Any], _ attributesToUpdate: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

public protocol DiskSpaceProbing: Sendable {
    /// `volumeAvailableCapacityForImportantUsage`, in bytes.
    func availableCapacityForImportantUsage(at url: URL) throws -> Int64
}

public protocol NetworkPathMonitoring: Sendable {
    var paths: AsyncStream<NetworkPathState> { get }
    var current: NetworkPathState { get async }
}

public struct NetworkPathState: Sendable, Hashable {
    public var isSatisfied: Bool
    public var isExpensive: Bool
    public var isConstrained: Bool
    /// Stable identity of the active interface set; a change here means "different network".
    public var interfaceFingerprint: String
}

public protocol OcclusionObserving: Sendable {
    var events: AsyncStream<OcclusionEvent> { get }
}

public enum OcclusionEvent: Sendable, Hashable {
    case windowVisible(WindowID), windowOccluded(WindowID)
    case windowMiniaturized(WindowID), windowDeminiaturized(WindowID)
    case appHidden, appUnhidden
    case screensSlept, screensWoke
}

public enum PowerEvent: Sendable, Hashable {
    case willSleep, didWake, screensaverStarted, screensaverStopped
    case lowPowerModeChanged(Bool), thermalStateChanged(ProcessInfo.ThermalState)
}
```

**Decision:** `ProcessInfo.processInfo.isLowPowerModeEnabled` and `.thermalState` are polled through
`PowerEventObserving`, not read directly, so thermal throttling is testable (§8.6).

---

## 3. Shared primitives

```swift
public struct CameraID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString }
    // Codable as a bare UUID string, not as { "rawValue": ... }.
    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer(); try c.encode(rawValue)
    }
}
```

The same single-value-container pattern is used for `GroupID`, `LayoutID`, `EventID`, `ClipID`,
`BookmarkID`, `CredentialRef`. **Rule:** every ID encodes as a bare JSON string. This keeps
`library.json` readable and diffable, which is the entire point of §5.

```swift
public struct Resolution: Sendable, Codable, Hashable, CustomStringConvertible {
    public var width: Int
    public var height: Int
    public var pixels: Int { width * height }
    public var megapixels: Double { Double(pixels) / 1_000_000 }
    public var aspect: Double { height == 0 ? 0 : Double(width) / Double(height) }
    public var description: String { "\(width)×\(height)" }
    public static let hd1080 = Resolution(width: 1920, height: 1080)
    public static let hd720  = Resolution(width: 1280, height: 720)
    public static let d1     = Resolution(width: 704,  height: 576)
    /// Nearest human label: "4K", "5MP", "1080p", "720p", "D1", "CIF", else "W×H".
    public var shortLabel: String { get }
}

public enum VideoCodec: String, Sendable, Codable, CaseIterable {
    case h264, h265, mjpeg, unknown
    /// Relative hardware decode cost per pixel per second. Used by §8.4 budget math.
    public var decodeWeight: Double {
        switch self { case .h264: 1.00; case .h265: 1.35; case .mjpeg: 0.45; case .unknown: 1.35 }
    }
}

public enum AudioCodec: String, Sendable, Codable, CaseIterable {
    case aac, pcmAlaw, pcmUlaw, g726, g722, unknown
    /// True when the codec can be muxed into MP4 without re-encoding.
    public var isMP4Muxable: Bool { self == .aac }
}

public enum RTSPTransportKind: String, Sendable, Codable, CaseIterable {
    case tcpInterleaved   // default; Transport: RTP/AVP/TCP;unicast;interleaved=0-1
    case udpUnicast
    case udpMulticast
    case tcpTLS           // rtsps, port 322
    case auto             // try tcpInterleaved, fall back per §6.7
}

public enum LatencyPreset: String, Sendable, Codable, CaseIterable {
    case low        // jitter depth 40 ms / 8 pkts, decode queue 2, drop-to-keyframe aggressive
    case balanced   // 120 ms / 24 pkts, queue 3
    case quality    // 350 ms / 64 pkts, queue 5, never drop unless queue full
}

public enum ColorTag: String, Sendable, Codable, CaseIterable {
    case none, red, orange, yellow, green, teal, blue, purple, pink, graphite
}

public enum AspectMode: String, Sendable, Codable, CaseIterable { case fit, fill, stretch }

public enum DeviceKind: String, Sendable, Codable, CaseIterable {
    case camera, nvr, dvr, encoder, doorbell, thermal, unknown
}

public enum StreamQuality: String, Sendable, Codable, CaseIterable {
    case main, sub, third, auto
}
```

### 3.1 Device quirks — the shared vocabulary

**Cross-cutting decision.** Firmware bugs are *detected* by the protocol modules, *persisted* by
VigilCore inside `DeviceCapabilities.quirks`, and *injected back* into the protocol modules on the
next connect. This is the only sanctioned channel for firmware workarounds; no module may keep its
own private quirk cache.

```swift
public enum DeviceQuirk: String, Sendable, Codable, CaseIterable {
    case unreliableMarkerBit          // VigilRTP: split AUs on slice header, not marker bit
    case sdpMissingParameterSets      // VigilRTSP/VigilVideo: wait for in-band SPS/PPS
    case digestNoQop                  // VigilRTSP: RFC 2069 response construction
    case requiresBasicAuth            // VigilRTSP/VigilISAPI: skip Digest entirely
    case closesOnGetParameter         // VigilRTSP: keepalive via OPTIONS instead
    case interleavedOnly              // VigilRTSP: never offer UDP
    case noMulticast
    case jpegSnapshotNeedsChannelSuffix   // VigilISAPI: /picture path variant
    case jpegSnapshotIgnoresSizeParams
    case alertStreamNoTerminalBoundary    // VigilISAPI: multipart parser leniency
    case alertStreamDropsWithoutTraffic   // EventCenter: 30 s poll alongside stream
    case motionRegionYAxisInverted        // VigilRender: flip normalized Y
    case channelListPagedAt64             // VigilISAPI: paged InputProxy enumeration
    case rtspPathLegacyH264               // /h264/ch1/main/av_stream family
    case reportsWrongFPSInISAPI           // trust SDP/measured fps over ISAPI
    case ptzContinuousNeedsStopCommand
    case rejectsConcurrentISAPI           // per-device ISAPI concurrency limit = 1
}
```

Detection is reported upward as `StreamEvent.quirkDetected(DeviceQuirk)` / the ISAPI client's
`quirksObserved` set; `StreamCoordinator` folds them into the camera record and schedules a save.
Quirks are **sticky**: once observed they are never auto-cleared, only reset by the user via
Inspector → Info → "Re-probe device".

---

## 4. Domain model

All model types are `public struct`, `Sendable`, `Codable`, `Hashable`, and where they have an `id`,
`Identifiable`. **Every** type declares an explicit `CodingKeys` enum with short, stable, snake-free
lowerCamelCase string keys. Renaming a Swift property MUST NOT change the JSON key; the coding key
is the contract.

**Decision — one `schemaVersion`, at the document root.** Per-type versions were considered and
rejected: they multiply migration paths combinatorially and make a partial migration
representable. `Library.schemaVersion` is the single version number (§5.5).

**Decision — decoding is forgiving, encoding is exact.** Every optional-with-default property is
decoded with `decodeIfPresent(_:forKey:) ?? default`, so a `library.json` written by an older build
loads without a migration step for purely additive fields. Migrations are reserved for *semantic*
changes. A shared helper enforces this:

```swift
extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, default fallback: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback
    }
}
```

### 4.1 `Camera`

```swift
public struct Camera: Identifiable, Sendable, Codable, Hashable {
    // MARK: Identity
    public var id: CameraID
    public var name: String                    // user-facing, non-unique, 1...64 chars
    public var host: String                    // IPv4, IPv6 (no brackets), or DNS name
    public var httpPort: Int                   // ISAPI control plane. Default 80 (443 if useTLS)
    public var rtspPort: Int                   // Default 554 (322 when transport == .tcpTLS)
    public var useTLS: Bool                    // https for ISAPI. Independent of RTSP transport.
    public var channel: Int                    // 1-based device channel. Cameras: 1. NVRs: 1...n
    public var streamProfile: StreamProfile.Kind   // preferred profile when quality == .main/.sub
    public var transport: RTSPTransportKind
    public var credentialRef: CredentialRef    // opaque Keychain handle. NEVER a username/password.
    public var groupID: GroupID?
    public var orderIndex: Int                 // sparse, step 1024, see §4.9
    public var capabilities: DeviceCapabilities?   // nil until first successful probe
    public var createdAt: Date
    public var lastSeenAt: Date?               // last successful PLAY or ISAPI 200
    public var colorTag: ColorTag
    public var isEnabled: Bool                 // false = never auto-connect, greyed in sidebar

    // MARK: Additive (all defaulted; safe to add more the same way)
    public var macAddress: String?             // uppercase, colon-separated; discovery identity
    public var serialHint: String?             // REDACTED in all logs and diagnostics
    public var notes: String                   // free text, max 4096
    public var audioEnabled: Bool              // default false
    public var autoRecordOnMotion: Bool        // default false
    public var preferredCodec: VideoCodec?     // nil = accept whatever SDP offers
    public var rtspPathOverride: String?       // absolute path, e.g. "/Streaming/Channels/201"
    public var latencyPreset: LatencyPreset    // default .balanced
    public var timeZoneIdentifier: String?     // device clock TZ for playback/timeline math
    public var isONVIFFallback: Bool           // true = non-Hikvision; ISAPI features disabled
    public var jpegPollIntervalOverride: Double?   // seconds; nil = policy table §8.5
    public var isPinnedLive: Bool              // keep streaming even when not in layout

    enum CodingKeys: String, CodingKey {
        case id, name, host, httpPort, rtspPort, useTLS, channel, streamProfile, transport
        case credentialRef, groupID, orderIndex, capabilities, createdAt, lastSeenAt, colorTag
        case isEnabled, macAddress, serialHint, notes, audioEnabled, autoRecordOnMotion
        case preferredCodec, rtspPathOverride, latencyPreset, timeZoneIdentifier, isONVIFFallback
        case jpegPollIntervalOverride, isPinnedLive
    }
}
```

Derived accessors (computed, never stored, never encoded):

```swift
public extension Camera {
    /// ISAPI streaming channel id: channel * 100 + stream index. Ch 2 sub-stream → 202.
    func streamingChannelID(for kind: StreamProfile.Kind) -> Int {
        channel * 100 + kind.streamIndex        // main=1, sub=2, third=3
    }
    /// Effective RTSP path: override → capability template → default Hikvision form.
    func rtspPath(for kind: StreamProfile.Kind) -> String {
        if let rtspPathOverride { return rtspPathOverride }
        if let t = capabilities?.rtspPathTemplate { return t.path(channel: channel, stream: kind) }
        return "/Streaming/Channels/\(streamingChannelID(for: kind))"
    }
    var isapiEndpoint: ISAPIEndpoint {
        ISAPIEndpoint(host: host, port: httpPort, useTLS: useTLS)
    }
    func rtspEndpoint(for kind: StreamProfile.Kind) -> RTSPEndpoint {
        RTSPEndpoint(host: host, port: rtspPort, path: rtspPath(for: kind),
                     transport: transport, useTLS: transport == .tcpTLS)
    }
    /// Filesystem-safe slug used for folders, diagnostics and file names. §9.5
    var slug: String { get }
}
```

**Validation** (`Camera.validate() throws -> Camera`, returns a normalized copy):

| Field | Rule | On violation |
|---|---|---|
| `name` | trimmed, 1...64 chars, no `\n` | empty → `"Camera \(host)"`; too long → truncate |
| `host` | non-empty, no scheme, no path, no `@`; IPv6 stripped of `[]` | throw `.invalidHost` |
| `httpPort`, `rtspPort` | 1...65535 | throw `.invalidPort` |
| `channel` | 1...256 | clamp |
| `notes` | ≤ 4096 | truncate |
| `orderIndex` | any Int | renumbered by §4.9 |

### 4.2 `StreamProfile`

```swift
public struct StreamProfile: Identifiable, Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable, CaseIterable, Comparable {
        case main, sub, third
        public var streamIndex: Int { switch self { case .main: 1; case .sub: 2; case .third: 3 } }
        public static func < (a: Kind, b: Kind) -> Bool { a.streamIndex < b.streamIndex }
    }
    /// Where the numbers came from. Governs trust when sources disagree (§4.2.1).
    public enum Origin: String, Sendable, Codable {
        case isapi          // GET /ISAPI/Streaming/channels/{id}
        case sdp            // parsed from DESCRIBE
        case measured       // observed on the wire by VigilRTP
        case assumed        // hard-coded fallback
    }

    public var id: Kind { kind }
    public var kind: Kind
    public var channelID: Int              // 101, 102, 201...
    public var codec: VideoCodec
    public var resolution: Resolution
    public var fps: Double                 // declared frame rate
    public var bitrateKbps: Int
    public var bitrateMode: BitrateMode    // .cbr / .vbr
    public var gopSeconds: Double          // GOP length in seconds (frameInterval / fps)
    public var audioCodec: AudioCodec?     // nil = no audio track on this profile
    public var rtspPath: String
    public var isAvailable: Bool           // false = device reports the profile disabled
    public var origin: Origin
    public var resolvedAt: Date?

    /// Cost units for the decode budget (§8.4).
    public var decodeCost: Double {
        resolution.megapixels * max(fps, 1) * codec.decodeWeight
    }
    public static func assumedDefaults(channel: Int) -> [StreamProfile]  // 1080p25/H.264 main, D1 sub
}

public enum BitrateMode: String, Sendable, Codable { case cbr, vbr, unknown }
```

#### 4.2.1 Conflict resolution when sources disagree

Precedence, highest first: **`.measured` > `.sdp` > `.isapi` > `.assumed`** — with two exceptions.

| Field | Winner | Rationale |
|---|---|---|
| `resolution` | `.sdp`/`.measured` (from SPS) | ISAPI reports the *configured* value; SPS reports what is actually being sent, including the 1088-vs-1080 crop. |
| `fps` | `.measured` after 10 s, else `.isapi` | Many firmwares (`reportsWrongFPSInISAPI`) lie in both directions; SDP `a=framerate` is frequently absent. |
| `codec` | `.sdp` | Authoritative — it is the payload actually offered. |
| `bitrateKbps` | `.isapi` for the *configured cap*, `.measured` for display | The UI shows measured; the budget uses configured as an upper bound. |
| `gopSeconds` | `.measured` (keyframe interval) | Used to predict pre-roll and "time until keyframe". |
| `audioCodec` | `.sdp` | ISAPI audio config does not always reflect the RTSP offer. |

Merging is a pure function and is unit-tested on its own (§17.2):

```swift
public func mergeProfiles(existing: [StreamProfile],
                          incoming: [StreamProfile],
                          now: Date) -> [StreamProfile]
```

### 4.3 `DeviceCapabilities`

A **snapshot**, not a live query. Written once per successful probe, cached in `library.json`,
re-probed when: the device firmware string changes, the user asks, a capability-dependent action
fails with `notSupport`, or `probedAt` is older than 7 days.

```swift
public struct DeviceCapabilities: Sendable, Codable, Hashable {
    public var probedAt: Date
    public var probeDurationMs: Int
    public var deviceKind: DeviceKind
    public var model: String?                 // "DS-2CD2143G0-I"
    public var firmwareVersion: String?       // "V5.6.3 build 190923"
    public var hardwareVersion: String?
    public var serialNumber: String?          // REDACTED everywhere except Keychain-free UI
    public var macAddress: String?
    public var channelCount: Int              // 1 for a camera; n for an NVR
    public var channels: [ChannelDescriptor]  // NVR IP-channel inventory
    public var streamProfiles: [StreamProfile]

    public var supportsH265: Bool
    public var supportsMJPEG: Bool
    public var supportsMulticast: Bool
    public var supportsJPEGSnapshot: Bool
    public var maxJPEGSnapshotSize: Resolution?
    public var supportsRequestKeyFrame: Bool
    public var supportsPTZ: Bool
    public var ptz: PTZCapabilities?
    public var supportsTwoWayAudio: Bool
    public var twoWayAudioCodecs: [AudioCodec]
    public var supportsAlertStream: Bool
    public var supportedEventKinds: Set<EventKind>
    public var supportsRecordSearch: Bool
    public var supportsImageSettings: Bool
    public var supportsPrivacyMask: Bool
    public var storage: [StorageVolumeInfo]
    public var rtspPathTemplate: RTSPPathTemplate
    public var quirks: Set<DeviceQuirk>
    /// Endpoints that returned 403/notSupport, so we stop asking. Path → first failure date.
    public var deniedEndpoints: [String: Date]

    public var isStale: Bool { Date().timeIntervalSince(probedAt) > 7 * 86_400 }
}

public struct ChannelDescriptor: Sendable, Codable, Hashable, Identifiable {
    public var id: Int                  // ISAPI channel id
    public var name: String
    public var isOnline: Bool
    public var sourceAddress: String?   // InputProxy: the underlying camera IP
    public var sourceModel: String?
    public var isPTZCapable: Bool
    public var profiles: [StreamProfile]
}

public struct PTZCapabilities: Sendable, Codable, Hashable {
    public var continuous: Bool, momentary: Bool, absolute: Bool, relative: Bool
    public var position3D: Bool          // drives drag-to-zoom on video
    public var presetCount: Int
    public var patrolCount: Int
    public var homePosition: Bool
    public var zoom: Bool, focus: Bool, iris: Bool
    public var panRange: ClosedRange<Double>?     // degrees
    public var tiltRange: ClosedRange<Double>?
    public var maxSpeed: Int                      // 1...100
}

public struct StorageVolumeInfo: Sendable, Codable, Hashable, Identifiable {
    public var id: Int
    public var name: String
    public var kind: String            // "HDD", "SD", "NAS"
    public var status: String          // "ok", "unformatted", "error", "sleeping"
    public var capacityMB: Int64
    public var freeMB: Int64
    public var isHealthy: Bool { status.lowercased() == "ok" }
}

public struct RTSPPathTemplate: Sendable, Codable, Hashable {
    public enum Family: String, Sendable, Codable {
        case channelsCompact   // /Streaming/Channels/101
        case channelsPadded    // /Streaming/Channels/1/streams/1  (rare firmware)
        case tracks            // /Streaming/tracks/101            (playback)
        case legacyH264        // /h264/ch1/main/av_stream
        case custom
    }
    public var family: Family
    public var customFormat: String?   // "%{channel}", "%{stream}", "%{channelID}" tokens
    public func path(channel: Int, stream: StreamProfile.Kind) -> String
    public static let `default` = RTSPPathTemplate(family: .channelsCompact, customFormat: nil)
}
```

### 4.4 `CameraGroup`

```swift
public struct CameraGroup: Identifiable, Sendable, Codable, Hashable {
    public var id: GroupID
    public var name: String                 // 1...64
    public var colorTag: ColorTag
    public var symbolName: String            // SF Symbol, e.g. "building.2"
    public var orderIndex: Int
    public var cameraIDs: [CameraID]         // ordered; authoritative for in-group order
    public var isCollapsed: Bool
    public var createdAt: Date
}
```

**Invariant.** `Camera.groupID` and `CameraGroup.cameraIDs` are two views of one relationship.
`Library.normalize()` (§5.7) is the sole reconciler: `cameraIDs` wins on conflict, dangling IDs are
dropped, and a camera present in two groups is kept in the lowest `orderIndex` group only.

### 4.5 `Layout`

```swift
public struct Layout: Identifiable, Sendable, Codable, Hashable {
    public var id: LayoutID
    public var name: String
    public var mode: LayoutMode
    /// Sorted by `cellIndex`, one entry per assigned cell. Unassigned cells are simply absent.
    public var assignments: [CellAssignment]
    public var cycle: CycleSettings?
    public var displayBinding: DisplayBinding?    // video wall / second display
    public var isBuiltIn: Bool                    // built-ins are not user-deletable
    public var createdAt: Date
    public var modifiedAt: Date

    public func cameraID(atCell index: Int) -> CameraID?
    public var assignedCameraIDs: [CameraID] { get }   // in cell order, deduplicated
}

public struct CellAssignment: Sendable, Codable, Hashable {
    public var cellIndex: Int
    public var cameraID: CameraID?
    public var qualityOverride: StreamQuality?    // nil = coordinator decides (§7.5)
    public var aspectMode: AspectMode
    public var isAudioSolo: Bool
}
```

**Decision — `assignments` is an array, not `[Int: CameraID]`.** A JSON object with integer-derived
string keys sorts as text (`"10"` before `"2"`), producing noisy diffs and non-deterministic output;
`Codable` for `[Int: T]` also emits an unkeyed alternating array in some encoders. A sorted array of
records is deterministic, diffable, and lets a cell carry per-cell settings.

```swift
public enum LayoutMode: Sendable, Codable, Hashable {
    case single
    case grid(columns: Int, rows: Int)     // 2x2, 3x3, 4x4, 5x5, 1xN, Nx1
    case onePlusFive                       // 1 hero + 5 side/bottom
    case onePlusSeven
    case twoPlusEight
    case custom(frames: [MosaicFrame])     // free mosaic, unit rect coordinates

    public var cellCount: Int {
        switch self {
        case .single: 1
        case .grid(let c, let r): c * r
        case .onePlusFive: 6
        case .onePlusSeven: 8
        case .twoPlusEight: 10
        case .custom(let f): f.count
        }
    }
    /// Unit-square frame of each cell, origin top-left. Deterministic; used by the coordinator to
    /// compute tile pixel sizes without asking the UI. VigilUI MUST use these same rects.
    public func frames() -> [MosaicFrame]
}

public struct MosaicFrame: Sendable, Codable, Hashable {
    public var x: Double, y: Double, width: Double, height: Double   // 0...1
}
```

`LayoutMode` needs a hand-written `Codable` because of the associated values. **Exact form** —
a `type` discriminator plus a flat payload, never nested single-key objects:

```json
{ "type": "grid", "columns": 3, "rows": 3 }
{ "type": "single" }
{ "type": "custom", "frames": [ { "x": 0, "y": 0, "width": 0.5, "height": 1 } ] }
```

```swift
extension LayoutMode {
    private enum CodingKeys: String, CodingKey { case type, columns, rows, frames }
    private enum Tag: String, Codable {
        case single, grid, onePlusFive, onePlusSeven, twoPlusEight, custom
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Tag.self, forKey: .type) {
        case .single: self = .single
        case .grid:
            self = .grid(columns: try c.decode(Int.self, forKey: .columns),
                         rows: try c.decode(Int.self, forKey: .rows))
        case .onePlusFive:  self = .onePlusFive
        case .onePlusSeven: self = .onePlusSeven
        case .twoPlusEight: self = .twoPlusEight
        case .custom: self = .custom(frames: try c.decode([MosaicFrame].self, forKey: .frames))
        }
    }
    public func encode(to encoder: any Encoder) throws { /* mirror image */ }
}
```

Unknown `type` values decode to `.grid(columns: 2, rows: 2)` and set
`Library.hadUnknownContent = true`, which the UI surfaces as "This library was created by a newer
version of Vigil; some layouts were simplified." **Decoding MUST NOT throw on unknown enum cases
anywhere in the model.** Every string-raw enum used in the model gets a `.unknown`-style fallback
via `init(rawValue:) ?? .unknown` at the decode site.

```swift
public struct CycleSettings: Sendable, Codable, Hashable {
    public var isEnabled: Bool
    public var dwellSeconds: Double        // 3...300, default 10
    public var cameraIDs: [CameraID]       // empty = all enabled cameras
    public var pauseOnInteraction: Bool    // default true; resumes after 30 s idle
    public var skipOfflineCameras: Bool    // default true
}

public struct DisplayBinding: Sendable, Codable, Hashable {
    /// Stable across reboots; `CGDisplayCreateUUIDFromDisplayID` string form.
    public var displayUUID: String
    public var isFullscreen: Bool
    public var preferredFrame: CodableRect?
}
```

### 4.6 `Bookmark`

```swift
public struct Bookmark: Identifiable, Sendable, Codable, Hashable {
    public var id: BookmarkID
    public var cameraID: CameraID
    public var deviceTime: Date          // instant in the *device* timeline (recorded footage)
    public var durationHint: Double?     // seconds; nil = point marker
    public var label: String             // 1...120
    public var note: String              // free text
    public var colorTag: ColorTag
    public var createdAt: Date
    public var eventID: EventID?         // set when created from an event
    public var thumbnailPath: String?    // relative to the thumbnail cache root
}
```

### 4.7 `EventRecord`

```swift
public enum EventKind: String, Sendable, Codable, CaseIterable {
    case motion            // VMD
    case lineCrossing      // linedetection
    case intrusion         // fielddetection
    case regionEntrance, regionExiting
    case faceDetection
    case tamper            // tamperdetection / shelteralarm
    case io                // alarm input
    case videoLoss
    case diskFull, diskError
    case sceneChange
    case audioException
    case unattendedBaggage, attendedBaggage
    case peopleCounting
    case streamLost        // synthesized by Vigil, not the device
    case authFailure       // synthesized
    case unknown

    /// Hikvision `eventType` strings → kind. Case-insensitive, tolerant of unknown values.
    public init(isapiEventType: String)
    public var displayNameKey: String      // localization key, e.g. "event.kind.motion"
    public var defaultSeverity: EventSeverity
}

public enum EventSeverity: Int, Sendable, Codable, Comparable {
    case info = 0, notice = 1, warning = 2, alarm = 3
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public struct EventRecord: Identifiable, Sendable, Codable, Hashable {
    public var id: EventID
    public var cameraID: CameraID
    public var channel: Int
    public var kind: EventKind
    public var rawEventType: String        // preserved verbatim for diagnostics
    public var severity: EventSeverity
    public var firstAt: Date               // device time, converted to absolute
    public var lastAt: Date                // extended by coalescing (§10.3)
    public var count: Int                  // number of coalesced notifications
    public var isActive: Bool              // eventState == "active"
    public var regions: [NormalizedRect]   // 0...1 space, already Y-corrected
    public var thumbnailPath: String?      // relative to Caches/Vigil/EventThumbnails
    public var clipID: ClipID?             // set when auto-record produced a clip
    public var isRead: Bool
    public var deviceTimeRaw: String       // "2026-07-26T14:25:30+03:00" as sent

    /// Dedupe/coalesce key. §11.3
    public var coalesceKey: CoalesceKey { CoalesceKey(cameraID, channel, kind) }
}

public struct NormalizedRect: Sendable, Codable, Hashable {
    public var x: Double, y: Double, width: Double, height: Double   // 0...1, origin top-left
    /// Hikvision sends 0...1000 with per-firmware Y orientation.
    public static func fromHikvision(x: Int, y: Int, w: Int, h: Int, yInverted: Bool) -> Self
}
```

### 4.8 `RecordingClip`

```swift
public struct RecordingClip: Identifiable, Sendable, Codable, Hashable {
    public var id: ClipID
    public var cameraID: CameraID
    public var cameraNameAtCapture: String   // denormalized; cameras get renamed
    /// Path RELATIVE to the recordings root, POSIX separators. Absolute paths are never stored,
    /// so the whole library survives moving the recordings folder.
    public var relativePath: String
    public var startedAt: Date               // wall-clock of the first written sample
    public var endedAt: Date?                // nil while recording or after a crash
    public var duration: Double              // seconds; 0 while in progress
    public var byteCount: Int64
    public var container: ClipContainer      // .mp4 / .mov
    public var videoCodec: VideoCodec
    public var resolution: Resolution
    public var fps: Double
    public var hasAudio: Bool
    public var audioCodec: AudioCodec?
    public var trigger: RecordingTrigger
    public var eventID: EventID?
    public var isPartial: Bool               // true = .partial file, crash or still running
    public var thumbnailPath: String?
    public var preRollSeconds: Double        // how much pre-roll actually made it in
    public var notes: String
}

public enum ClipContainer: String, Sendable, Codable {
    case mp4, mov
    public var fileExtension: String { rawValue }
    public var avFileType: AVFileType { self == .mp4 ? .mp4 : .mov }
}

public enum RecordingTrigger: String, Sendable, Codable, CaseIterable {
    case manual, motion, event, schedule, intent, deepLink, doctor
}
```

### 4.9 Ordering

`orderIndex` on `Camera` and `CameraGroup` uses **sparse integers with a 1024 step**. Inserting
between two neighbours takes the midpoint; when the gap reaches 1, the whole sequence is renumbered
from 0 in steps of 1024 (`Library.renumberOrder()`). This makes a sidebar drag a single-field edit
instead of an N-record rewrite, which keeps `library.json` diffs small.

```swift
public enum OrderIndex {
    public static let step = 1024
    public static func between(_ lower: Int?, _ upper: Int?) -> Int
    /// Returns true when a renumber is required (any gap < 2).
    public static func needsRenumber(_ sorted: [Int]) -> Bool
}
```

### 4.10 `AppSettings`

Persisted inside `library.json` (not `UserDefaults`) so that export/import and the diagnostics
bundle carry the full app state. `UserDefaults` holds **only** window frames, sidebar width,
"has seen onboarding", and the last-opened-window set — things that are per-machine, not per-library.

```swift
public struct AppSettings: Sendable, Codable, Hashable {
    // General
    public var appearance: Appearance = .auto           // .light/.dark/.auto
    public var launchAtLogin: Bool = false
    public var showMenuBarExtra: Bool = true
    public var use24HourClock: Bool? = nil              // nil = follow locale
    public var temperatureUnit: TemperatureUnit = .celsius
    public var preferredLanguage: String? = nil         // nil = system; "en", "ru"

    // Streams
    public var defaultTransport: RTSPTransportKind = .tcpInterleaved
    public var latencyPreset: LatencyPreset = .balanced
    public var useSubstreamInGrid: Bool = true
    public var allowHardwareDecode: Bool = true
    public var maxConcurrentDecodes: Int = 0            // 0 = auto from §8.4 chip table
    public var maxConcurrentConnects: Int = 4
    public var jpegFallbackEnabled: Bool = true
    public var audioFollowsFocus: Bool = true
    public var startStreamsOnLaunch: Bool = true
    public var pauseWhenOccluded: Bool = true
    public var pauseOnBattery: Bool = false

    // Recording
    public var recordingsFolderIsDefault: Bool = true   // ~/Movies/Vigil
    public var clipContainer: ClipContainer = .mp4
    public var neverReencodeAudio: Bool = false         // true forces .mov for G.711 (§9.6)
    public var preRollSeconds: Double = 5               // 0...30
    public var postRollSeconds: Double = 15             // 0...120
    public var maxClipMinutes: Int = 30                 // auto-split
    public var autoRecordOnMotionGlobal: Bool = false
    public var autoRecordCooldownSeconds: Double = 60
    public var retentionDays: Int = 0                   // 0 = keep forever
    public var retentionMaxGigabytes: Int = 0           // 0 = unlimited
    public var fileNameTemplate: String = RecordingNaming.defaultTemplate
    public var minimumFreeGigabytes: Int = 2

    // Snapshots
    public var snapshotFormat: SnapshotFormat = .png
    public var snapshotJPEGQuality: Double = 0.9
    public var snapshotBurnInOverlay: Bool = false
    public var snapshotFolderIsDefault: Bool = true     // ~/Pictures/Vigil
    public var snapshotNameTemplate: String = SnapshotNaming.defaultTemplate
    public var snapshotAlsoCopyToClipboard: Bool = false
    public var snapshotSource: SnapshotSourcePreference = .automatic

    // Notifications
    public var notificationsEnabled: Bool = true
    public var notifyKinds: Set<EventKind> = [.motion, .lineCrossing, .intrusion, .tamper,
                                              .videoLoss, .streamLost, .diskError]
    public var notificationThumbnails: Bool = true
    public var notificationQuietHours: QuietHours? = nil
    public var notifyOnStreamLossAfterSeconds: Double = 30

    // Advanced
    public var logLevel: LogLevel = .info
    public var allowURLSchemeWriteActions: Bool = false // §14.3 gate
    public var allowSelfSignedTLS: Bool = true          // LAN reality
    public var eventRetentionCount: Int = 5000
    public var healthHistoryMinutes: Int = 10

    public static let `default` = AppSettings()
}

public enum Appearance: String, Sendable, Codable { case light, dark, auto }
public enum TemperatureUnit: String, Sendable, Codable { case celsius, fahrenheit }
public enum SnapshotFormat: String, Sendable, Codable, CaseIterable { case png, jpeg, heic }
public enum SnapshotSourcePreference: String, Sendable, Codable {
    case automatic      // rendered frame when a decode session exists, else ISAPI JPEG
    case renderedFrame  // exact displayed pixels; fails if not live
    case deviceJPEG     // always ISAPI
}
public struct QuietHours: Sendable, Codable, Hashable {
    public var startMinuteOfDay: Int, endMinuteOfDay: Int   // 0...1439, may wrap midnight
    public var weekdays: Set<Int>                           // 1 = Sunday, Calendar convention
}
```

Adding a settings field is **always** additive: give it a default and decode with
`container.value(.key, default:)`. Adding a field never requires a schema migration.

---

## 5. Persistence — `ConfigStore`

### 5.1 On-disk layout

Resolved through `FileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, …)`, so
the same code is correct whether or not the app is sandboxed.

```
<AppSupport>/Vigil/
    library.json                  ← the document (§5.2)
    library.json.bak              ← previous good generation
    library.json.bak2             ← generation before that
    library.json.corrupt-20260726T142530Z   ← quarantined, never auto-deleted before 30 days
    events.json                   ← event ring (§5.9)
    events.json.bak
<Caches>/Vigil/
    Thumbnails/<cameraID>.jpg                 ← sidebar micro-thumbnails, LRU
    EventThumbnails/<eventID>.jpg             ← ≤ 5000 files / ≤ 512 MB, LRU
    ClipThumbnails/<clipID>.jpg
~/Movies/Vigil/<camera-slug>/<yyyy-MM-dd>/…mp4      ← default recordings root
~/Pictures/Vigil/…                                   ← default snapshots root
<AppSupport>/Vigil/Diagnostics/                      ← staging for §13.4 bundles
```

If the app is sandboxed and the user picks a recordings folder outside the container, the
`URL.bookmarkData(options: .withSecurityScope)` blob is stored in
`Library.recordingsFolderBookmark` and resolved at launch with
`URL(resolvingBookmarkData:options:.withSecurityScope,…)`, calling
`startAccessingSecurityScopedResource()` for the process lifetime. A stale bookmark surfaces as a
non-blocking banner: *"Vigil can no longer reach your recordings folder."* and recording is disabled
until re-picked. **Recording MUST NOT silently fall back to the container.**

### 5.2 The document

```swift
public struct Library: Sendable, Codable, Hashable {
    public static let currentSchemaVersion = 3

    public var schemaVersion: Int = Library.currentSchemaVersion
    public var generatedBy: String                 // "Vigil 1.0 (412)"
    public var updatedAt: Date
    public var cameras: [Camera] = []
    public var groups: [CameraGroup] = []
    public var layouts: [Layout] = []
    public var activeLayoutID: LayoutID?
    public var bookmarks: [Bookmark] = []
    public var clips: [RecordingClip] = []
    public var settings: AppSettings = .default
    public var recordingsFolderBookmark: Data?
    public var snapshotFolderBookmark: Data?

    // Runtime-only flags. `Codable` skips them; see CodingKeys.
    public var hadUnknownContent: Bool = false
    public var recoveredFromCorruption: RecoverySource? = nil
    public var isReadOnly: Bool = false            // set when schemaVersion > current

    enum CodingKeys: String, CodingKey {
        case schemaVersion, generatedBy, updatedAt, cameras, groups, layouts, activeLayoutID
        case bookmarks, clips, settings, recordingsFolderBookmark, snapshotFolderBookmark
    }
}

public enum RecoverySource: String, Sendable, Codable { case backup, backup2, freshStart }
```

Lookup helpers are O(1) via lazily-built indexes rebuilt on mutation:

```swift
public extension Library {
    func camera(_ id: CameraID) -> Camera?
    func group(_ id: GroupID) -> CameraGroup?
    func layout(_ id: LayoutID) -> Layout?
    var activeLayout: Layout? { activeLayoutID.flatMap(layout) }
    var enabledCameras: [Camera] { cameras.filter(\.isEnabled).sorted { $0.orderIndex < $1.orderIndex } }
}
```

Sample `library.json` (abbreviated; note there is **no credential material anywhere**):

```json
{
  "activeLayoutID" : "9D1F8C2A-2B41-4E6B-9C7B-1A2B3C4D5E6F",
  "cameras" : [
    {
      "audioEnabled" : false,
      "autoRecordOnMotion" : true,
      "capabilities" : {
        "channelCount" : 1,
        "deviceKind" : "camera",
        "firmwareVersion" : "V5.6.3 build 190923",
        "model" : "DS-2CD2143G0-I",
        "probedAt" : "2026-07-26T09:11:02Z",
        "quirks" : ["unreliableMarkerBit"],
        "rtspPathTemplate" : { "family" : "channelsCompact" },
        "supportsH265" : true,
        "supportsPTZ" : false
      },
      "channel" : 1,
      "colorTag" : "blue",
      "createdAt" : "2026-06-01T10:00:00Z",
      "credentialRef" : "5C6E8A10-77F1-4E20-8E4C-9A0B1C2D3E4F",
      "host" : "192.168.1.64",
      "httpPort" : 80,
      "id" : "E1A2B3C4-D5E6-4F70-8A9B-0C1D2E3F4A5B",
      "isEnabled" : true,
      "latencyPreset" : "balanced",
      "name" : "Front Door",
      "orderIndex" : 1024,
      "rtspPort" : 554,
      "streamProfile" : "main",
      "transport" : "tcpInterleaved",
      "useTLS" : false
    }
  ],
  "generatedBy" : "Vigil 1.0 (412)",
  "layouts" : [
    { "assignments" : [ { "aspectMode" : "fit", "cameraID" : "E1A2B3C4-D5E6-4F70-8A9B-0C1D2E3F4A5B",
                          "cellIndex" : 0, "isAudioSolo" : false } ],
      "createdAt" : "2026-06-01T10:00:00Z", "id" : "9D1F8C2A-2B41-4E6B-9C7B-1A2B3C4D5E6F",
      "isBuiltIn" : true, "mode" : { "columns" : 2, "rows" : 2, "type" : "grid" },
      "modifiedAt" : "2026-07-20T18:02:11Z", "name" : "2×2" }
  ],
  "schemaVersion" : 3,
  "updatedAt" : "2026-07-26T14:25:30Z"
}
```

### 5.3 Encoder / decoder configuration

Byte-for-byte determinism matters: identical state MUST produce an identical file, or the debounced
writer will churn the disk and git diffs become useless.

```swift
enum LibraryCoding {
    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(ISO8601DateFormatter.vigilUTC.string(from: date))
        }
        e.dataEncodingStrategy = .base64
        e.nonConformingFloatEncodingStrategy = .throw
        return e
    }
    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let d0 = ISO8601DateFormatter.vigilUTC.date(from: s) { return d0 }
            if let d1 = ISO8601DateFormatter.vigilFractional.date(from: s) { return d1 }
            if let secs = Double(s) { return Date(timeIntervalSince1970: secs) } // schema 1 legacy
            throw DecodingError.dataCorruptedError(in: try dec.singleValueContainer(),
                                                   debugDescription: "bad date \(s)")
        }
        return d
    }
}
```

`ISO8601DateFormatter.vigilUTC`: `formatOptions = [.withInternetDateTime]`, `timeZone = .gmt` —
so every timestamp is `2026-07-26T14:25:30Z`. Fractional seconds are accepted on read, never written.

**Why `.prettyPrinted` for a machine file:** it is a user-inspectable, git-committable,
support-diagnosable document. A 500-camera library is ~380 KB pretty-printed. That is free.

### 5.4 The actor

```swift
public actor ConfigStore {
    public struct Options: Sendable {
        public var debounce: Duration = .milliseconds(500)
        public var maxCoalesceLatency: Duration = .seconds(2)
        public var backupGenerations: Int = 2
        public var corruptFileRetentionDays: Int = 30
        public var maxCorruptFilesKept: Int = 5
        public var maxDocumentBytes: Int = 32 * 1024 * 1024   // sanity guard on read
    }

    public init(directory: URL, options: Options = .init(), dependencies: CoreDependencies)

    /// Loads (or recovers, or creates) the document. MUST be called exactly once before any
    /// mutate/read. Idempotent: subsequent calls return the cached value.
    public func load() async -> LoadOutcome

    /// Current snapshot. Cheap — the value is already in memory.
    public func snapshot() -> Library

    /// The only write path. Returns whatever the body returns. Schedules a debounced save if the
    /// document actually changed (Hashable comparison), otherwise does nothing.
    @discardableResult
    public func mutate<T: Sendable>(_ body: @Sendable (inout Library) throws -> T) rethrows -> T

    /// Writes now, awaiting durability. Called on quit, before sleep, before export, and by tests.
    public func flush() async throws

    /// Broadcast of committed snapshots (post-normalization). One stream per consumer (§6.9).
    public nonisolated func changes() -> AsyncStream<Library>

    /// Export / import (§14.5 CSV+JSON, encrypted variant).
    public func exportDocument() throws -> Data
    public func importDocument(_ data: Data, strategy: ImportStrategy) async throws -> ImportReport
}

public enum LoadOutcome: Sendable {
    case loaded(Library)
    case created(Library)                              // no file present: first run
    case recovered(Library, from: RecoverySource, error: any Error)
    case readOnly(Library, futureVersion: Int)         // schemaVersion > current
}
```

`mutate` runs **synchronously inside the actor**. It MUST NOT be async and MUST NOT perform I/O:
callers get a transactional, uninterrupted view. Every mutation ends with `Library.normalize()`
(§5.7) and `updatedAt = clock.wallNow`.

### 5.5 Atomic write algorithm

Exact sequence in `commit(_ library: Library)`:

1. `var doc = library; doc.updatedAt = now; doc.generatedBy = Bundle.versionString`
2. `let data = try encoder.encode(doc)`
3. **Skip if unchanged:** compare `data` against the last-written bytes held in memory. Equal →
   return without touching the disk. (This is why §5.3 determinism matters.)
4. `let tmp = dir.appendingPathComponent("library.json.tmp-\(UUID().uuidString)")`
5. `try fs.writeDurably(data, to: tmp)` — which is:
   ```swift
   try data.write(to: url, options: [.atomic])
   let fd = open(url.path, O_RDONLY)
   defer { close(fd) }
   if fd >= 0 { _ = fcntl(fd, F_FULLFSYNC) }   // ordinary fsync does not flush the drive cache
   ```
6. **Rotate backups** (oldest first, so a crash mid-rotation never destroys both):
   `bak2 ← bak` (`replaceItem`/`moveItem`, ignore `ENOENT`).
7. **Swap in:**
   ```swift
   if fs.fileExists(at: current) {
       try fs.replaceItem(at: current, with: tmp, backupItemName: "library.json.bak")
   } else {
       try fs.moveItem(at: tmp, to: current)
   }
   ```
   `FileManager.replaceItemAt(_:withItemAt:backupItemName:options:)` is used with
   `[.usingNewMetadataOnly]`; it performs the directory-level rename that makes the swap atomic and
   leaves the old contents as `library.json.bak`.
8. `fsync` the **directory** file descriptor so the rename itself is durable.
9. Cache `data` as the last-written bytes; clear the dirty flag; prune corrupt files per policy.
10. On any thrown error: keep the dirty flag set, delete `tmp` best-effort, emit
    `ConfigStoreError.writeFailed`, and retry with backoff `1 s, 2 s, 5 s, 15 s, 60 s` (then hourly).
    After the second consecutive failure, surface a persistent UI banner: *"Vigil can't save your
    settings."* with the underlying `errno` description and a Reveal-in-Finder action. **Never drop
    the pending state.**

### 5.6 Debounced saves

```
mutate() ─► dirty = true
            ├── if no timer:      schedule flush at now + 500 ms
            │                     and record firstDirtyAt = now
            └── if timer exists:  reschedule to now + 500 ms,
                                  but NEVER later than firstDirtyAt + 2 s
```

- A burst of edits (dragging a slider, reordering the sidebar) collapses into one write.
- The 2 s ceiling bounds worst-case data loss during continuous editing.
- **Immediate, awaited flush** on: `NSApplication.willTerminateNotification`,
  `NSWorkspace.willSleepNotification`, `NSWorkspace.willPowerOffNotification`, before a diagnostics
  bundle, before an export, when the recordings folder changes, and on explicit `flush()`.
- The debounce timer comes from `clock.timer(after:)`, so `TestClock.advance(by:)` drives it
  deterministically — no `Task.sleep` in tests.

### 5.7 Normalization invariants

`Library.normalize()` is pure, idempotent (`normalize(normalize(x)) == normalize(x)` is a test), and
runs after every mutation and after every load:

| # | Invariant | Repair |
|---|---|---|
| 1 | `cameras` sorted by `orderIndex`, then `createdAt`, then `id` | re-sort |
| 2 | `orderIndex` gaps ≥ 2 | `renumberOrder()` |
| 3 | No duplicate `Camera.id` | keep the one with the newer `lastSeenAt`, else the first |
| 4 | `Camera.groupID` ⟷ `CameraGroup.cameraIDs` agree | `cameraIDs` wins; dangling entries dropped |
| 5 | A camera appears in at most one group | keep lowest-`orderIndex` group |
| 6 | `Layout.assignments` sorted by `cellIndex`, unique, `0 ..< mode.cellCount` | drop out-of-range |
| 7 | Assignments referencing missing cameras | set `cameraID = nil` (keep the cell settings) |
| 8 | `activeLayoutID` exists | fall back to the first built-in |
| 9 | At least one built-in layout of each mode exists | re-seed built-ins |
| 10 | `bookmarks` / `clips` referencing missing cameras | keep the record, flag `isOrphaned` in the UI (never destroy user data) |
| 11 | `clips` sorted by `startedAt` descending, capped at 20 000 | oldest dropped from the *index* only; files untouched |
| 12 | `settings` numeric fields within range | clamp |
| 13 | Camera name empty | `"Camera \(host)"` |

Invariant 10 is deliberate: deleting a camera MUST NOT delete its recordings or bookmarks.
`ConfigStore.deleteCamera(_:deletingFiles:)` makes file deletion an explicit, separate choice.

### 5.8 Schema migration chain

Migrations operate on **untyped JSON**, never on old Swift models. This is the decision that keeps
the codebase from accumulating `CameraV1`, `CameraV2`, … forever.

```swift
public protocol SchemaMigration: Sendable {
    static var from: Int { get }
    static var to: Int { get }     // always from + 1
    static func migrate(_ root: inout [String: Any]) throws
}

enum SchemaMigrator {
    /// Registered in ascending order. A gap or duplicate is a fatal programmer error caught by a
    /// unit test, not at runtime.
    static let all: [any SchemaMigration.Type] = [Migration1to2.self, Migration2to3.self]

    static func migrate(_ data: Data, logger: any LoggerProtocol) throws -> (Data, applied: [String]) {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigStoreError.notAnObject
        }
        var version = (root["schemaVersion"] as? Int) ?? 1
        guard version <= Library.currentSchemaVersion else {
            throw ConfigStoreError.schemaTooNew(found: version)
        }
        var applied: [String] = []
        while version < Library.currentSchemaVersion {
            guard let step = all.first(where: { $0.from == version }) else {
                throw ConfigStoreError.missingMigration(from: version)
            }
            try step.migrate(&root)
            version = step.to
            root["schemaVersion"] = version
            applied.append("\(step.from)→\(step.to)")
        }
        return (try JSONSerialization.data(withJSONObject: root,
                                           options: [.sortedKeys, .prettyPrinted]), applied)
    }
}
```

| From → To | Shipped in | Change | Transform |
|---|---|---|---|
| 1 → 2 | 0.4 beta | `port` split into `httpPort` + `rtspPort`; dates were UNIX doubles | `httpPort = port ?? 80`, `rtspPort = rtspPort ?? 554`; each numeric date → ISO-8601 UTC string |
| 2 → 3 | 0.9 beta | `credentialRef` was `"host:port:user"` (leaked the username into the JSON) and layouts used `cells: {"0":"UUID"}` | mint a fresh `UUID` per camera, emit a `KeychainRekeyRequest` list so `CredentialStore` re-tags the existing item (§6.4); convert `cells` object → sorted `assignments` array |
| 3 → 4 | reserved | — | — |

Migration mechanics:

- Before the first migration, the pre-migration file is copied to
  `library.json.premigration-v<n>-<timestamp>` and kept indefinitely (it is small, and it is the
  only way back).
- The migrated document is validated by a full `Library` decode **before** being written. If the
  decode fails, the migration is abandoned, the original file is left untouched, and the store enters
  recovery (§5.9) — the app never half-migrates.
- `applied` is logged at `.notice` and included in the diagnostics bundle manifest.
- **Forward guard:** `schemaTooNew` puts the store into `.readOnly`. The app runs, streams work,
  nothing is ever written, and a banner says *"This library was created by a newer version of Vigil.
  Update Vigil to make changes."* Silently downgrading a user's library is unacceptable.

Migration bodies are free functions over `[String: Any]` in files that import **only** Foundation,
so `ARCHITECTURE.md` may optionally include them in a Linux CI test target. The canonical position
is: VigilCore's own test target is macOS-only.

### 5.9 Corruption recovery ladder

```
read library.json
  ├─ file missing ─────────────────► .created(seeded default library)   [first run]
  ├─ size 0 or > maxDocumentBytes ─► quarantine → try .bak
  ├─ JSONSerialization fails ──────► quarantine → try .bak
  ├─ schemaVersion > current ──────► .readOnly (do NOT quarantine, do NOT write)
  ├─ migration throws ─────────────► quarantine → try .bak
  ├─ Library decode throws ────────► quarantine → try .bak
  └─ success ──────────────────────► .loaded

try .bak   → same ladder, no further quarantine → success ⇒ .recovered(from: .backup)
try .bak2  → same ladder                        → success ⇒ .recovered(from: .backup2)
all fail   → .recovered(seeded default, from: .freshStart, error: firstError)
```

- "Quarantine" = `moveItem` to `library.json.corrupt-<ISO8601-compact>`; **never** delete.
- Recovery does not immediately rewrite the file. The first user mutation does. This preserves the
  evidence if the user quits to fetch help.
- Any recovery raises a **modal-once** alert (not a transient toast): the source used, how many
  cameras were recovered vs. present in the corrupt file (counted by a lenient key scan), and
  **Reveal Files in Finder** / **Quit Without Saving**.
- Pruning: corrupt files older than 30 days **and** beyond the newest 5 are deleted on launch.

### 5.10 Why not SwiftData or Core Data

| Criterion | JSON document | Core Data / SwiftData |
|---|---|---|
| Human-inspectable during support | Yes — a user can paste `library.json` into an email | No — opaque SQLite + WAL |
| Diffable / git-committable | Yes, deterministic key order (§5.3) | No |
| Export/import & config sharing | The file *is* the export format | Requires a bespoke serializer anyway |
| Migration risk | Pure JSON functions, testable, reversible, backed up | `NSMappingModel`, versioned `.xcdatamodeld`, lightweight-migration failures that brick the store at launch |
| Concurrency with Swift 6 | One `actor`, `Sendable` value types, zero managed-object thread rules | `NSManagedObject` is not `Sendable`; context confinement fights strict concurrency |
| Atomicity | One rename, one `F_FULLFSYNC` | WAL + `-shm`/`-wal` sidecars that complicate backup and copying |
| Whole-document snapshot for the UI | Free — it is a value type | Requires fetches, faults and change notifications |
| Cost | Whole document re-encoded per save | Row-level writes |

Measured envelope for the JSON design: 500 cameras + 30 layouts + 20 000 clip records encodes in
**~11 ms** and produces **~4.1 MB**; the debounce means at most one such write every 500 ms, and in
practice a few per minute. Well inside budget.

**What changes past ~10 000 records.** The trigger is any of: `library.json` > 2 MB, > 2 000
cameras, > 20 000 clip records, or a p99 `commit` > 40 ms. The response, in order:

1. **Split the document.** `clips.json` and `events.json` move out (events already have — §5.11), so
   the hot, small document (`cameras`, `groups`, `layouts`, `settings`) stays under 200 KB and keeps
   its 500 ms debounce. Cold documents get a 5 s debounce.
2. **Append-only journal for clips.** New clips append one JSON line to `clips.ndjson`; a compaction
   pass rewrites it when tombstones exceed 25%. Keeps writes O(1) per clip.
3. **SQLite via the system `sqlite3` C API** for `clips` and `events` only — still zero external
   dependencies, since `libsqlite3.tbd` ships with macOS. `cameras`/`layouts` stay JSON forever
   because their diffability is a product feature.
4. Never SwiftData: the strict-concurrency friction and the store-migration failure mode are the
   exact risks this design exists to avoid.

### 5.11 `EventLog` — the second document

Events are high-churn and high-volume; putting 5 000 of them in `library.json` would make every
motion event rewrite the camera list. They therefore live in their own store.

```swift
public actor EventLog {
    public init(fileURL: URL, capacity: Int = 5000, dependencies: CoreDependencies)
    public func load() async -> [EventRecord]
    public func snapshot() -> [EventRecord]                        // newest first
    public func append(_ event: EventRecord)                       // evicts oldest past capacity
    public func upsert(_ event: EventRecord)                       // coalescing (§11.3)
    public func markRead(_ ids: Set<EventID>)
    public func delete(_ ids: Set<EventID>)
    public func clear(olderThan: Date?)
    public func query(_ q: EventQuery) -> [EventRecord]
    public func flush() async throws
    public nonisolated func changes() -> AsyncStream<EventLogChange>
}

public struct EventQuery: Sendable {
    public var cameraIDs: Set<CameraID>? = nil
    public var kinds: Set<EventKind>? = nil
    public var minimumSeverity: EventSeverity? = nil
    public var dateRange: ClosedRange<Date>? = nil
    public var unreadOnly: Bool = false
    public var searchText: String? = nil
    public var limit: Int = 500
}

public enum EventLogChange: Sendable {
    case appended(EventRecord)
    case updated(EventRecord)          // coalesced
    case removed(Set<EventID>)
    case reloaded
}
```

Same atomic-write + `.bak` + debounce machinery as `ConfigStore` (the mechanics live in a shared
internal `AtomicJSONFile<Value: Codable & Sendable>` used by both), but with a **2 s** debounce
because events are less precious than configuration and arrive in bursts. In-memory representation
is a `Deque`-shaped ring over an `Array` with head/tail indices; eviction is O(1). On eviction the
corresponding thumbnail file is queued for deletion.

Corruption of `events.json` is **non-fatal by design**: the ladder ends at "start with an empty
event list", with a `.notice` log and no modal alert. Losing history is annoying; losing cameras is not.

---

## 6. Credentials — `CredentialStore`

### 6.1 The hard rule

**Credentials exist in exactly two places: the macOS Keychain, and process memory for as long as a
connection needs them.** Concretely, and enforced by the tests in §17.4:

1. `Credential` MUST NOT be `Codable`. It is `Sendable` and `Hashable` but has no `Encodable`
   conformance, so it *cannot* be written to `library.json` even by accident.
2. `Credential` MUST NOT be `CustomStringConvertible`-transparent: its `description` and
   `debugDescription` return `"Credential(account: admin, secret: ****)"`. The password is never
   interpolated.
3. No log line, at any level, may contain a password, an `Authorization:` header value, a Digest
   `response=` value, an RTSP `Session:` id in full, or a device serial. Redaction is centralized in
   `LogRedaction` (VigilProtocols) and applied by `OSLogLogger` before emission — never left to the
   call site's discipline. All password-shaped OSLog interpolations use `\(value, privacy: .private)`
   as a second line of defence.
4. RTSP/HTTP URLs are **never** built with embedded credentials. `rtsp://user:pass@host/...` is
   forbidden in code; auth always goes in headers. A unit test greps the module for `"://\(` patterns
   adjacent to credential variables.
5. Export (§14.5) writes camera records **without** secrets. The encrypted export variant is the only
   way to move credentials between machines, and it re-derives a key from a user-supplied passphrase.

### 6.2 Types

```swift
/// Opaque, stable handle to a Keychain item. The rawValue appears in library.json; it reveals
/// nothing — not even the username.
public struct CredentialRef: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString }
    /// The kSecAttrPath value that uniquely locates the item, independent of host/port/account.
    var keychainPath: String { "/vigil/credential/\(rawValue.uuidString)" }
}

/// NOT Codable. Deliberately.
public struct Credential: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    public let ref: CredentialRef
    public let account: String        // Hikvision username, e.g. "admin"
    public let secret: String         // password
    public var description: String { "Credential(account: \(account), secret: ****)" }
    public var debugDescription: String { description }
    public init(ref: CredentialRef = .init(), account: String, secret: String)
}

/// Everything needed to write a well-labelled Keychain item.
public struct CredentialDescriptor: Sendable, Hashable {
    public var ref: CredentialRef
    public var host: String
    public var port: Int
    public var useTLS: Bool
    public var account: String
    public var label: String          // "Vigil — Front Door (192.168.1.64)"
    public var comment: String        // "Managed by Vigil. Deleting this item breaks the camera."
}
```

### 6.3 Keychain item shape

Class **`kSecClassInternetPassword`** (not generic password): it is semantically correct for a
network service, and it makes the item legible and editable in Keychain Access.app, which matters for
user trust and for support.

| Attribute | Value | Why |
|---|---|---|
| `kSecClass` | `kSecClassInternetPassword` | network credential |
| `kSecAttrServer` | `camera.host` | shown in Keychain Access; updated when the IP changes |
| `kSecAttrPort` | `NSNumber(value: camera.httpPort)` | part of the primary key |
| `kSecAttrProtocol` | `kSecAttrProtocolHTTPS` when `useTLS` else `kSecAttrProtocolHTTP` | primary key |
| `kSecAttrAccount` | username | primary key |
| `kSecAttrPath` | `ref.keychainPath` → `/vigil/credential/<uuid>` | **the stable lookup key** |
| `kSecAttrAuthenticationType` | `kSecAttrAuthenticationTypeHTTPDigest` | matches how we authenticate |
| `kSecAttrLabel` | `"Vigil — <camera name> (<host>)"` | human legibility |
| `kSecAttrComment` | fixed warning string | so users don't delete it blindly |
| `kSecAttrDescription` | `"Vigil camera credential"` | ditto |
| `kSecAttrAccessible` | `kSecAttrAccessibleWhenUnlocked` | see below |
| `kSecAttrSynchronizable` | `kCFBooleanFalse` | LAN camera passwords MUST NOT go to iCloud Keychain |
| `kSecValueData` | `secret.data(using: .utf8)` | the password |

**Why `kSecAttrAccessibleWhenUnlocked` and not `…AfterFirstUnlock`:** the app has no background
duties while the user is logged out; requiring an unlocked keychain is the tighter choice and
matches the app's foreground-only lifecycle. **Why not `…WhenPasscodeSetThisDeviceOnly`:** it would
break Migration Assistant transfers, and these are LAN device passwords, not secrets warranting
device binding.

**Primary-key note.** For `kSecClassInternetPassword` the uniqueness tuple is
(`kSecAttrAccount`, `kSecAttrSecurityDomain`, `kSecAttrServer`, `kSecAttrProtocol`,
`kSecAttrAuthenticationType`, `kSecAttrPort`, `kSecAttrPath`). Because `kSecAttrPath` carries a
UUID, two cameras on the same host with the same username never collide, and a lookup constrained
**only** by class + path is exact. That is why `CredentialRef` is UUID-based rather than
`"host:port:user"` — which was schema 2's mistake (§5.8) and leaked the username into the JSON.

### 6.4 API

```swift
public actor CredentialStore {
    public init(keychain: any KeychainProtocol, logger: any LoggerProtocol,
                accessGroup: String? = nil)

    /// Creates or replaces the item for `descriptor.ref`.
    public func save(_ credential: Credential, descriptor: CredentialDescriptor) throws

    /// Cache-first read. Returns nil when no item exists (a normal state, not an error).
    public func credential(for ref: CredentialRef) throws -> Credential?

    /// Convenience used by every connect path.
    public func credential(for camera: Camera) throws -> Credential?

    /// Changes only the password, keeping the ref and account.
    public func updateSecret(_ secret: String, for ref: CredentialRef) throws

    /// Follows a camera's host/port/username changes so Keychain Access stays truthful.
    public func updateAttributes(_ descriptor: CredentialDescriptor) throws

    public func delete(_ ref: CredentialRef) throws

    /// Re-tags an item that exists under legacy attributes with a new UUID path. Used by the 2→3
    /// migration, which cannot read the old password's location any other way.
    public func rekey(legacyServer: String, legacyPort: Int, legacyAccount: String,
                      to ref: CredentialRef, descriptor: CredentialDescriptor) throws -> Bool

    /// All Vigil-owned refs on this machine. Used by "orphaned credential" cleanup in Settings →
    /// Advanced. Never returns secrets.
    public func enumerateRefs() throws -> [CredentialRef]

    /// Drops the in-memory cache. Called on Keychain-lock notifications and on user logout.
    public func purgeCache()
}
```

### 6.5 Exact implementation

```swift
private func baseQuery(_ ref: CredentialRef) -> [String: Any] {
    var q: [String: Any] = [
        kSecClass as String: kSecClassInternetPassword,
        kSecAttrPath as String: ref.keychainPath,
    ]
    if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
    return q
}

private func attributes(_ credential: Credential,
                        _ d: CredentialDescriptor) -> [String: Any] {
    var a: [String: Any] = [
        kSecClass as String: kSecClassInternetPassword,
        kSecAttrServer as String: d.host,
        kSecAttrPort as String: NSNumber(value: d.port),
        kSecAttrProtocol as String: d.useTLS ? kSecAttrProtocolHTTPS : kSecAttrProtocolHTTP,
        kSecAttrAuthenticationType as String: kSecAttrAuthenticationTypeHTTPDigest,
        kSecAttrAccount as String: d.account,
        kSecAttrPath as String: d.ref.keychainPath,
        kSecAttrLabel as String: d.label,
        kSecAttrComment as String: d.comment,
        kSecAttrDescription as String: "Vigil camera credential",
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        kSecAttrSynchronizable as String: kCFBooleanFalse!,
        kSecValueData as String: Data(credential.secret.utf8),
    ]
    if let accessGroup { a[kSecAttrAccessGroup as String] = accessGroup }
    return a
}

public func save(_ credential: Credential, descriptor d: CredentialDescriptor) throws {
    precondition(credential.ref == d.ref, "descriptor must describe the credential's own ref")
    let attrs = attributes(credential, d)
    var status = keychain.add(attrs)

    if status == errSecDuplicateItem {
        // Update value + mutable attributes in place. The query MUST NOT contain kSecValueData
        // or kSecClass-conflicting keys; the update dictionary MUST NOT contain kSecClass.
        var update = attrs
        update.removeValue(forKey: kSecClass as String)
        update.removeValue(forKey: kSecAttrAccessGroup as String)
        status = keychain.update(baseQuery(d.ref), update)
    }
    guard status == errSecSuccess else {
        throw CredentialError(status: status, operation: .save)
    }
    cache[d.ref] = credential
    logger.info("credential saved", metadata: ["ref": "\(d.ref)", "account": .redacted])
}

public func credential(for ref: CredentialRef) throws -> Credential? {
    if let hit = cache[ref] { return hit }

    var query = baseQuery(ref)
    query[kSecReturnData as String] = kCFBooleanTrue!
    query[kSecReturnAttributes as String] = kCFBooleanTrue!
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = keychain.copyMatching(query, &item)
    switch status {
    case errSecSuccess:
        guard let dict = item as? [String: Any],
              let data = dict[kSecValueData as String] as? Data,
              let secret = String(data: data, encoding: .utf8),
              let account = dict[kSecAttrAccount as String] as? String
        else { throw CredentialError(status: errSecDecode, operation: .read) }
        let credential = Credential(ref: ref, account: account, secret: secret)
        cache[ref] = credential
        return credential
    case errSecItemNotFound:
        return nil
    default:
        throw CredentialError(status: status, operation: .read)
    }
}

public func updateSecret(_ secret: String, for ref: CredentialRef) throws {
    let status = keychain.update(baseQuery(ref),
                                 [kSecValueData as String: Data(secret.utf8)])
    switch status {
    case errSecSuccess:
        if let old = cache[ref] {
            cache[ref] = Credential(ref: ref, account: old.account, secret: secret)
        } else {
            cache.removeValue(forKey: ref)
        }
    case errSecItemNotFound:
        throw CredentialError(status: status, operation: .update)
    default:
        throw CredentialError(status: status, operation: .update)
    }
}

public func updateAttributes(_ d: CredentialDescriptor) throws {
    let update: [String: Any] = [
        kSecAttrServer as String: d.host,
        kSecAttrPort as String: NSNumber(value: d.port),
        kSecAttrProtocol as String: d.useTLS ? kSecAttrProtocolHTTPS : kSecAttrProtocolHTTP,
        kSecAttrAccount as String: d.account,
        kSecAttrLabel as String: d.label,
    ]
    let status = keychain.update(baseQuery(d.ref), update)
    if status == errSecItemNotFound { return }   // nothing to relabel; not an error
    guard status == errSecSuccess else { throw CredentialError(status: status, operation: .update) }
    if let old = cache[d.ref], old.account != d.account { cache.removeValue(forKey: d.ref) }
}

public func delete(_ ref: CredentialRef) throws {
    let status = keychain.delete(baseQuery(ref))
    cache.removeValue(forKey: ref)
    guard status == errSecSuccess || status == errSecItemNotFound else {
        throw CredentialError(status: status, operation: .delete)
    }
}
```

**Two hard-won details.** (a) The dictionary passed to `SecItemUpdate` MUST NOT contain
`kSecClass` — it returns `errSecParam` if it does. (b) `SecItemAdd` with `kSecValueData` plus
`kSecReturnData` also returns `errSecParam`; never mix return keys into an add.

### 6.6 `OSStatus` mapping

```swift
public struct CredentialError: Error, Sendable, LocalizedError, Equatable {
    public enum Operation: String, Sendable { case save, read, update, delete, enumerate }
    public let status: OSStatus
    public let operation: Operation
    public var kind: Kind
    public var errorDescription: String? { kind.userFacingMessage }
    public var recoverySuggestion: String? { kind.userFacingFix }

    public enum Kind: Sendable, Equatable {
        case notFound, duplicate, authFailed, userCancelled, keychainLocked
        case missingEntitlement, badParameters, decodeFailed, unavailable, unknown(OSStatus)
    }
}
```

| `OSStatus` | Numeric | `Kind` | User-facing message | Fix shown |
|---|---|---|---|---|
| `errSecSuccess` | 0 | — | — | — |
| `errSecItemNotFound` | −25300 | `.notFound` | "No saved password for this camera." | "Enter the camera's password again." |
| `errSecDuplicateItem` | −25299 | `.duplicate` | (handled internally by falling through to update) | — |
| `errSecAuthFailed` | −25293 | `.authFailed` | "macOS wouldn't unlock the keychain." | "Unlock your login keychain in Keychain Access and try again." |
| `errSecUserCanceled` | −128 | `.userCancelled` | "Keychain access was cancelled." | "Try again and choose Always Allow." |
| `errSecInteractionNotAllowed` | −25308 | `.keychainLocked` | "Your keychain is locked." | "Unlock your Mac's login keychain, then reconnect." |
| `errSecMissingEntitlement` | −34018 | `.missingEntitlement` | "Vigil isn't allowed to use the keychain." | "This build isn't signed correctly — reinstall Vigil." |
| `errSecParam` | −50 | `.badParameters` | "Internal keychain error." | "Please report this with a diagnostics bundle." |
| `errSecDecode` | −26275 | `.decodeFailed` | "The saved password is unreadable." | "Re-enter the password to repair it." |
| `errSecNotAvailable` | −25291 | `.unavailable` | "The keychain isn't available." | "Restart your Mac if this continues." |
| `errSecInvalidKeychain` | −25295 | `.unknown` | "Keychain error \(status)." | "Please report this with a diagnostics bundle." |
| anything else | — | `.unknown` | "Keychain error \(status)." | ditto |

`errSecMissingEntitlement` (−34018) is the single most common **development-time** failure: it
appears when the binary is unsigned or signed without a keychain-capable identity. `ARCHITECTURE.md`
must ensure `Scripts/build-app.sh` ad-hoc signs the bundle (`codesign -s -`) with the entitlements
file; `swift run` from a bare SwiftPM build will otherwise fail every Keychain call. **On
`.missingEntitlement`, the app MUST NOT fall back to storing passwords anywhere else.** It surfaces
the error and refuses to save. There is no in-memory-only "convenience" mode.

### 6.7 In-memory cache

```swift
private var cache: [CredentialRef: Credential] = [:]
```

- Populated on read and write; consulted before every Keychain call. A 16-camera grid reconnecting
  after wake performs **1** Keychain read per camera, not one per RTSP round trip.
- Cleared by `purgeCache()` on: `NSApplication.willResignActiveNotification` **no** — that would be
  hostile to reconnects. Actually cleared on: screen lock
  (`com.apple.screenIsLocked` distributed notification), `NSWorkspace.sessionDidResignActive`,
  keychain lock, and app termination.
- The cache is inside an `actor`, so there is no lock and no data race. `Credential` values are
  immutable.
- **The cache is never written to disk, never included in a diagnostics bundle, and never appears in
  a crash report** — `Credential.secret` is a `String` on the heap; we accept that (zeroing Swift
  `String` storage is not reliably possible) and compensate by keeping the cache small and by
  disabling core dumps in the hardened-runtime entitlements.

### 6.8 Credential validation, and the lockout rule

Credentials are validated with the **cheap** ISAPI probe, never by hammering RTSP:

```swift
public enum CredentialCheckResult: Sendable, Equatable {
    case valid(DeviceInfo)
    case wrongPassword(attemptsRemaining: Int?, lockoutSeconds: Int?)
    case accountLocked(unlockAfterSeconds: Int?)
    case notHikvision(detectedVendor: String?)
    case unreachable(underlying: String)
    case tlsRejected
    case needsActivation            // SADP said Activated=false
}

public func validate(_ credential: Credential, against camera: Camera) async -> CredentialCheckResult
```

Implementation: `GET /ISAPI/Security/userCheck` with Digest. Its response carries `statusValue`,
`statusString`, and on some firmwares `lockStatus`, `retryLoginTime`, `unlockTime` — the ISAPI spec
document owns the exact shapes.

**Hard rule, cross-cutting.** Hikvision devices lock an account after ~5–7 consecutive failed
authentications for 30 minutes. Therefore:

1. A `401` twice in a row **with a fresh nonce** is a terminal `authenticationFailed`. The
   `StreamController` transitions to `.failed` and the reconnect loop **stops**. No exponential
   retry, ever, on auth failure.
2. `CredentialStore` enforces a global **failed-attempt governor**: at most **3** validation attempts
   per (host, account) per 10 minutes, tracked in memory. The 4th is refused locally with
   `.wrongPassword(attemptsRemaining: 0, …)` and a UI message: *"Vigil stopped trying to protect your
   camera account from being locked."*
3. Discovery and bulk-add MUST validate with a **single** probe per device, sequentially per host,
   with a 250 ms spacing.
4. When the user edits a password, all governor counters for that (host, account) reset and every
   `.failed(authenticationFailed)` controller is retried **immediately** (§7.8 event
   `credentialsUpdated`).

### 6.9 Multi-consumer `AsyncStream` — the shared broadcaster

`AsyncStream` is single-consumer: two `for await` loops over the same stream split the elements. The
UI needs several independent observers of the same event source (a tile, the inspector, the health
monitor, the recorder). **Decision:** every `changes()` / `events` accessor in VigilCore is a
*factory* that returns a **fresh** stream, fanned out by a shared internal broadcaster.

```swift
/// Internal, reused by ConfigStore, EventLog, StreamController, StreamCoordinator, HealthMonitor.
final actor Broadcaster<Element: Sendable> {
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    private var latest: Element?          // replayed to new subscribers when `replaysLatest`
    private let replaysLatest: Bool
    private let bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy

    init(replaysLatest: Bool = false,
         bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy = .bufferingNewest(64))

    nonisolated func stream() -> AsyncStream<Element> {
        AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
            let id = UUID()
            Task { await self.register(id: id, continuation) }
            continuation.onTermination = { _ in Task { await self.unregister(id) } }
        }
    }
    func yield(_ element: Element)   // stores latest, forwards to all continuations
    func finish()
}
```

Buffering policies, chosen per stream so a slow consumer can never stall a hot path:

| Stream | Policy | Rationale |
|---|---|---|
| `ConfigStore.changes()` | `.bufferingNewest(1)`, replays latest | only the newest snapshot matters |
| `EventLog.changes()` | `.bufferingNewest(256)` | bursts must not be lost |
| `StreamController.events` | `.bufferingNewest(64)`, replays latest state | dropping stale stats is correct |
| `StreamCoordinator.plans()` | `.bufferingNewest(1)`, replays latest | idempotent full plan |
| `HealthMonitor.samples()` | `.bufferingNewest(16)` | 1 Hz; UI is the only consumer |

**Never `.unbounded`.** An unbounded continuation plus a suspended consumer is an unbounded memory
leak, and these streams carry per-frame-adjacent data.

---

## 7. `StreamController` — one actor per active camera

### 7.1 Responsibility

`StreamController` is the **only** owner of a camera's live media path. It composes, but does not
reimplement: `RTSPSessionMachine` (VigilRTSP) for protocol logic, `RTSPTransport` (VigilTransport)
for bytes, `Depacketizer` (VigilRTP) for frames, `DecodeSink` (VigilVideo) for pictures,
`ClipRecorder` (§9) for files. It adds lifecycle, timeouts, reconnection, quality selection and
statistics — the things that need a single serialized owner.

One controller per **camera**, not per profile: switching main↔sub is an internal re-SETUP, not a new
controller. This preserves the recorder, the statistics history and the event stream identity across
quality changes.

```swift
public actor StreamController: Identifiable {
    public nonisolated let id: CameraID
    public nonisolated let cameraName: String        // snapshot at init, for logging only

    public init(camera: Camera,
               credentialProvider: @Sendable @escaping () async throws -> Credential?,
               initialQuality: StreamQuality,
               initialPriority: StreamPriority,
               dependencies: CoreDependencies,
               recorderFactory: @Sendable @escaping (RecordingOptions, StreamFormat) throws -> ClipRecorder)

    // MARK: Lifecycle
    /// Idempotent. From `.idle`/`.stopped`/`.failed` begins a connect attempt; otherwise no-op.
    public func start() async
    /// Graceful: sends TEARDOWN (1.5 s budget), finalizes any recording, releases the decode lease.
    /// Idempotent and always safe to await, including from a task that is being cancelled.
    public func stop(reason: EndReason = .userRequested) async
    /// Keeps the RTSP session alive but stops decoding and drops frames. Used by occlusion (§8.6).
    public func setPaused(_ paused: Bool) async
    /// Full teardown + immediate reconnect. Used by "Reconnect" in the UI and by Stream Doctor.
    public func restart() async

    // MARK: Control
    public func setQuality(_ quality: StreamQuality) async
    public func setPriority(_ priority: StreamPriority) async
    public func setCamera(_ camera: Camera) async      // config edits; may force a restart (§7.8)
    public func setAudioEnabled(_ enabled: Bool) async
    /// Best-effort IDR request. Returns how it was satisfied so the UI can narrate the wait.
    @discardableResult
    public func requestKeyframe(reason: KeyframeReason) async -> KeyframeRequestOutcome

    // MARK: Capture
    public func snapshot(_ options: SnapshotOptions) async throws -> SnapshotResult
    public func startRecording(_ options: RecordingOptions) async throws -> RecordingHandle
    public func stopRecording() async throws -> RecordingClip?
    public var isRecording: Bool { get }

    // MARK: Observation
    public nonisolated func events() -> AsyncStream<StreamEvent>
    public func state() -> StreamState
    public func statistics() -> StreamStatistics
    public func format() -> StreamFormat?
    public func healthSnapshot() -> HealthSample
    /// Last successfully decoded frame, retained for the "offline, dimmed last frame" state (§8.6).
    public func lastFrameThumbnail() -> Data?          // JPEG, ≤ 640 px long edge
}
```

```swift
public enum StreamPriority: Int, Sendable, Comparable, CaseIterable {
    case focused = 400          // fullscreen, or the single focused tile
    case visibleLarge = 300     // on-screen tile ≥ 0.35 Mpx
    case visibleSmall = 200     // on-screen tile < 0.35 Mpx
    case offscreen = 100        // in the layout but scrolled/occluded
    case thumbnail = 50         // sidebar micro-preview
    case background = 10        // pinned live but not shown anywhere
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public enum KeyframeReason: String, Sendable {
    case packetLossGap, decodeError, recordingStart, snapshotRequest, qualitySwitch, userRequest
}

public enum KeyframeRequestOutcome: Sendable, Equatable {
    case isapiRequestKeyFrame                   // device honoured PUT .../requestKeyFrame
    case rtspPauseResume                        // last resort, causes a visible ~200 ms hitch
    case waitingForNaturalGOP(estimatedSeconds: Double)
    case unavailable(reason: String)
}

public struct StreamFormat: Sendable, Hashable {
    public var videoCodec: VideoCodec
    public var resolution: Resolution
    public var declaredFPS: Double
    public var parameterSets: ParameterSets           // VigilBitstream
    public var audioCodec: AudioCodec?
    public var audioSampleRate: Double?
    public var audioChannels: Int?
    public var profileKind: StreamProfile.Kind
    public var isInterlaced: Bool
    public var pixelAspectRatio: Double               // SAR; 1.0 for square pixels
}
```

### 7.2 `StreamEvent`

```swift
public enum StreamEvent: Sendable {
    // Lifecycle
    case stateChanged(from: StreamState, to: StreamState, detail: StateDetail?)
    case connectAttemptStarted(attempt: Int, endpoint: String)   // endpoint is host:port/path
    case authenticated(scheme: AuthScheme)                       // .basic / .digest
    case formatResolved(StreamFormat)
    case firstPacketReceived(afterConnect: Duration)
    case firstFrameDecoded(afterStart: Duration)                 // the glass-to-glass milestone
    case ended(reason: EndReason)

    // Steady state
    case statistics(StreamStatistics)                // 1 Hz
    case health(HealthSample)                        // 1 Hz, from HealthMonitor's perspective
    case keyframe(MediaTimestamp)
    case degraded(DegradationReason)
    case recovered(after: Duration)
    case qualityChanged(from: StreamProfile.Kind, to: StreamProfile.Kind, cause: QualityChangeCause)
    case formatChangedMidStream(from: StreamFormat, to: StreamFormat)

    // Capture
    case recordingStarted(clipID: ClipID, url: URL, preRollSeconds: Double)
    case recordingProgress(clipID: ClipID, duration: Duration, bytes: Int64)
    case recordingFinished(RecordingClip)
    case recordingFailed(clipID: ClipID, error: StreamError)
    case snapshotTaken(SnapshotResult)

    // Trouble
    case warning(StreamWarning)                      // non-fatal, shown as a transient chip
    case error(StreamError, isFatal: Bool)
    case reconnectScheduled(attempt: Int, delay: Duration, cause: StreamError)
    case quirkDetected(DeviceQuirk)
    case capabilitiesUpdated(DeviceCapabilities)
    case profilesResolved([StreamProfile])
}

public enum EndReason: String, Sendable, Codable {
    case userRequested, coordinatorEvicted, appTerminating, cameraDisabled, cameraDeleted
    case unrecoverableError, authenticationFailed, budgetExhausted
}

public enum QualityChangeCause: String, Sendable {
    case tileResized, userRequested, budgetPressure, thermalPressure, lowPowerMode
    case packetLoss, decodeFailure, networkConstrained
}

public enum DegradationReason: String, Sendable, Codable, CaseIterable {
    case packetLoss, highJitter, lowFrameRate, decodeErrors, decodeQueueOverflow
    case stalledMedia, bitrateCollapse, keyframeStarvation
}

public enum StreamWarning: Sendable {
    case udpFellBackToTCP, multicastUnavailable, audioCodecUnsupported(AudioCodec)
    case parameterSetsMissingFromSDP, secondTrackIgnored, timestampDiscontinuity(Duration)
    case deviceClockSkew(Duration), jpegFallbackEngaged
}
```

### 7.3 States

```swift
public enum StreamState: String, Sendable, Codable, CaseIterable {
    case idle             // constructed, never started
    case resolving        // loading credentials, cached capabilities, DNS
    case connecting       // TCP (or TLS) connect to rtspPort
    case authenticating   // handling 401 → Digest → re-send
    case describing       // DESCRIBE sent, awaiting SDP
    case settingUp        // SETUP per track, then PLAY
    case playing          // media flowing, health nominal
    case degraded         // media flowing, health below threshold
    case reconnecting     // waiting out backoff, or waiting for the network
    case failed           // needs user action (auth, unsupported codec, bad path)
    case stopped          // terminal, user- or coordinator-initiated

    public var isActive: Bool { self == .playing || self == .degraded }
    public var isTransient: Bool {
        [.resolving, .connecting, .authenticating, .describing, .settingUp].contains(self)
    }
    public var holdsDecodeLease: Bool { self == .playing || self == .degraded }
}

public struct StateDetail: Sendable, Hashable {
    public var narration: String          // localized, shown under the connecting skeleton
    public var progress: Double?          // 0...1 for the connect sequence
    public var attempt: Int
    public var nextRetryAt: Date?         // drives the "Retrying in 4s" countdown
    public var underlying: StreamError?
}
```

Narration strings, shown by the UI during `isTransient` (see UX.md for final copy):
`resolving` → "Looking up camera…", `connecting` → "Connecting…", `authenticating` → "Signing in…",
`describing` → "Negotiating stream…", `settingUp` → "Starting video…",
plus `playing` before first frame → "Waiting for the first keyframe…".

### 7.4 Per-state timeouts

Every timer is created from `dependencies.clock`, so `TestClock` drives all of this deterministically.
Timeouts are **per attempt** and do not accumulate; the whole connect sequence is additionally bounded
by a **20 s** overall watchdog which, if it fires, is treated exactly like the current state's timeout.

| State | Timer | Default | Configurable by | On expiry |
|---|---|---|---|---|
| `resolving` | `resolve` | 3.0 s total (2 tries × 1.5 s) | — | → `reconnecting(.hostResolutionFailed)` |
| `resolving` | `credentialLoad` | 2.0 s | — | → `failed(.keychainUnavailable)` |
| `connecting` | `tcpConnect` | 4.0 s | `.low`: 3.0 s | → transport fallback (§7.8) else `reconnecting(.connectTimeout)` |
| `connecting` | `tlsHandshake` | +3.0 s | — | → `failed(.tlsHandshakeFailed)` |
| `authenticating` | `authRoundTrip` | 5.0 s, max **2** challenges | — | → `reconnecting(.authTimeout)` |
| `describing` | `describe` | 6.0 s | — | → `reconnecting(.describeTimeout)` |
| `settingUp` | `setupPerTrack` | 3.0 s each | — | drop that track; if it was video → `reconnecting` |
| `settingUp` | `setupTotal` | 8.0 s | — | → `reconnecting(.setupTimeout)` |
| `settingUp` | `play` | 4.0 s | — | → `reconnecting(.playTimeout)` |
| `playing` (pre-warm) | `firstRTP` | 4.0 s | `.quality`: 6.0 s | one transport fallback, then `reconnecting(.noMediaReceived)` |
| `playing` (pre-warm) | `firstKeyframe` | 6.0 s | — | at 6 s: `requestKeyframe(.packetLossGap)`; at 10 s: `reconnecting(.noKeyframe)` |
| `playing` | `mediaStallWarn` | 5.0 s without a complete frame | `.quality`: 8.0 s | → `degraded(.stalledMedia)` |
| `playing`/`degraded` | `mediaStallFail` | 12.0 s without a complete frame | — | → `reconnecting(.mediaStalled)` |
| `playing`/`degraded` | `keepalive` | `min(sessionTimeout / 2, 25 s)` | — | send `GET_PARAMETER` (or `OPTIONS` if `closesOnGetParameter`) |
| `playing`/`degraded` | `keepaliveResponse` | 5.0 s | — | → `reconnecting(.keepaliveTimeout)` |
| `degraded` | `recovery` | 2.0 s of nominal health | — | → `playing`, emit `.recovered` |
| `degraded` | `degradedGiveUp` | 45 s continuously degraded | — | → `reconnecting(.persistentDegradation)` **once**; if it degrades again within 5 min, stay degraded and stop cycling |
| `reconnecting` | `backoff` | §7.6 table | — | → `resolving` |
| `failed` | `coldRetry` | 5 min | — | → `resolving`, **only** for non-auth causes |
| any | `teardown` | 1.5 s | — | force-close the transport |
| all connect states | `overallWatchdog` | 20 s | — | treat as the current state's timeout |

`degradedGiveUp` deserves a note: reconnecting a persistently-lossy stream usually does not help and
costs the user 2–3 s of black. We try exactly once, then accept the degraded state and let the UI show
the packet-loss banner. This is the anti-flapping rule.

### 7.5 Full transition table

Events arrive from three sources: the public API (`start`, `stop`, …), the `RTSPSessionMachine`'s
emitted events after `ingest`, and timers. Anything not listed is a **no-op with a `.debug` log** —
the controller never traps on an unexpected event.

| # | From | Event | To | Actions / guards |
|---|---|---|---|---|
| 1 | `idle` | `start` | `resolving` | load credential; load cached `DeviceCapabilities`; select profile per §8.5; start `resolve` + `overallWatchdog` |
| 2 | `idle` | `stop` | `stopped` | — |
| 3 | `resolving` | `credentialMissing` | `failed(.credentialsMissing)` | emit `.error(isFatal: true)`; UI shows "Enter password" |
| 4 | `resolving` | `keychainError` | `failed(.keychainUnavailable)` | surface `CredentialError` verbatim |
| 5 | `resolving` | `resolved(endpoint)` | `connecting` | create `RTSPTransport`; `connect()`; start `tcpConnect` |
| 6 | `resolving` | `resolveFailed` \| `resolve` timeout | `reconnecting` | cause `.hostResolutionFailed` |
| 7 | `connecting` | `connected` | `authenticating` | build `RTSPSessionMachine`; send `OPTIONS`; start `authRoundTrip` |
| 8 | `connecting` | `connectFailed(err)` \| `tcpConnect` timeout | `reconnecting` \| `failed` | `ECONNREFUSED` → `failed(.portClosed)` (a closed port will not open by retrying blindly — cold-retry only); `EHOSTUNREACH`/timeout → `reconnecting` |
| 9 | `connecting` | `tlsFailed` | `failed(.tlsHandshakeFailed)` | if `allowSelfSignedTLS` was false, offer "Trust this camera" |
| 10 | `authenticating` | `challenge401(digest)` (1st) | `authenticating` | compute Digest; re-send; restart `authRoundTrip`; `challengeCount = 1` |
| 11 | `authenticating` | `challenge401` (2nd, fresh nonce) | `failed(.authenticationFailed)` | **no retry** (§6.8); notify `EventCenter` → `.authFailure` event |
| 12 | `authenticating` | `challenge401(stale: true)` | `authenticating` | recompute with the new nonce; does **not** consume `challengeCount` |
| 13 | `authenticating` | `response403` | `failed(.accessForbidden)` | user lacks the RTSP privilege |
| 14 | `authenticating` | `response200(OPTIONS)` | `describing` | record `Public:` methods; send `DESCRIBE`; start `describe` |
| 15 | `authenticating` | `authRoundTrip` timeout | `reconnecting(.authTimeout)` | — |
| 16 | `describing` | `sdpReceived(desc)` | `settingUp` | resolve tracks + `a=control` URLs; publish `.formatResolved`; `.profilesResolved`; send first `SETUP` |
| 17 | `describing` | `response404` \| `response455` | `failed(.rtspPathNotFound)` | trigger the **path probe** (§7.9) before failing |
| 18 | `describing` | `response401` | `authenticating` | some firmware re-challenges on DESCRIBE; allowed once |
| 19 | `describing` | `sdpUnparseable` \| no video track | `failed(.unsupportedMedia)` | attach the SDP to the error for the diagnostics bundle |
| 20 | `describing` | `describe` timeout | `reconnecting(.describeTimeout)` | — |
| 21 | `settingUp` | `setupOK(track)` | `settingUp` | more tracks → next `SETUP`; else send `PLAY` |
| 22 | `settingUp` | `setupFailed(video)` | `settingUp` \| `reconnecting` | if UDP and fallback available → switch to `tcpInterleaved`, restart from `connecting`, emit `.udpFellBackToTCP`; else `reconnecting` |
| 23 | `settingUp` | `setupFailed(audio)` | `settingUp` | drop the audio track, emit `.audioCodecUnsupported`, continue |
| 24 | `settingUp` | `response461` (unsupported transport) | `settingUp` | force `tcpInterleaved`; if already TCP → `failed(.transportUnsupported)` |
| 25 | `settingUp` | `playOK(rtpInfo)` | `playing` (pre-warm) | seed presentation clock from `RTP-Info`; acquire `DecodeLease`; create `DecodeSink`; start `firstRTP`, `firstKeyframe`, `keepalive` |
| 26 | `settingUp` | `playFailed` \| `play` timeout | `reconnecting(.playFailed)` | — |
| 27 | `playing` (pre-warm) | `firstRTPReceived` | `playing` | cancel `firstRTP`; emit `.firstPacketReceived` |
| 28 | `playing` (pre-warm) | `firstRTP` timeout, transport == UDP | `connecting` | switch to `tcpInterleaved` (a NAT/firewall blocked the UDP path); emit `.udpFellBackToTCP`; **does not consume a reconnect attempt** |
| 29 | `playing` (pre-warm) | `firstRTP` timeout, transport == TCP | `reconnecting(.noMediaReceived)` | — |
| 30 | `playing` (pre-warm) | `firstKeyframe` timeout (6 s) | `playing` (pre-warm) | `requestKeyframe(.packetLossGap)`; arm a 4 s follow-up |
| 31 | `playing` (pre-warm) | follow-up expiry (10 s total) | `reconnecting(.noKeyframe)` | — |
| 32 | `playing` (pre-warm) | `firstFrameDecoded` | `playing` | emit `.firstFrameDecoded(afterStart:)`; mark `lastSeenAt`; reset the backoff **healthy timer** |
| 33 | `playing` | `healthBelowThreshold(reason)` | `degraded` | emit `.degraded(reason)`; start `recovery` + `degradedGiveUp` |
| 34 | `playing` | `mediaStallWarn` | `degraded(.stalledMedia)` | keep the session; the UI dims and shows the last frame |
| 35 | `degraded` | `recovery` elapsed with nominal health | `playing` | emit `.recovered(after:)` |
| 36 | `degraded` | `degradedGiveUp` (first time in 5 min) | `reconnecting(.persistentDegradation)` | — |
| 37 | `playing`/`degraded` | `mediaStallFail` (12 s) | `reconnecting(.mediaStalled)` | — |
| 38 | `playing`/`degraded` | `keepaliveTimeout` | `reconnecting(.keepaliveTimeout)` | — |
| 39 | `playing`/`degraded` | `socketClosed` | `reconnecting(.connectionClosed)` | a camera reboot lands here; **the recorder is finalized first** (§9.8) |
| 40 | `playing`/`degraded` | `rtspError(response)` on keepalive | `reconnecting(.sessionLost)` | `454 Session Not Found` after a device reboot |
| 41 | `playing`/`degraded` | `formatChanged(new SPS)` | `playing`/`degraded` | drain the depacketizer, ask `DecodeSink` to reconfigure, emit `.formatChangedMidStream`; **split the recording** into a new file (§9.7) |
| 42 | `playing`/`degraded` | `setQuality(k)` where `k` resolves to a different profile | `settingUp` | graceful `PAUSE`+`TEARDOWN`, re-`SETUP` on the new control URL, keep the same transport and the same event stream; emit `.qualityChanged` |
| 43 | `playing`/`degraded` | `decodeError(kVTVideoDecoderBadDataErr)` | same | count it; `requestKeyframe(.decodeError)`; 4 errors in 5 s → `degraded(.decodeErrors)` |
| 44 | `playing`/`degraded` | `decodeError(kVTInvalidSessionErr)` \| `MalfunctionErr` | same | recreate the sink via `DecodeSink.reset()`, then wait for an IDR |
| 45 | `playing`/`degraded` | `setPaused(true)` | same | release the `DecodeLease`, stop feeding the sink, keep RTSP + keepalive, keep recording if active |
| 46 | `playing`/`degraded` | `setPaused(false)` | same | re-acquire the lease; `requestKeyframe(.qualitySwitch)` |
| 47 | any | `networkLost` | `reconnecting(.networkUnavailable)` | cancel the transport; **freeze the attempt counter**; no timer armed |
| 48 | `reconnecting(.networkUnavailable)` | `networkAvailable` | `resolving` | after a `100 ms × staggerIndex` delay (§8.7) |
| 49 | `reconnecting` | `backoff` elapsed | `resolving` | `attempt += 1` |
| 50 | `reconnecting` | `networkAvailable` (different `interfaceFingerprint`) | `resolving` | cancel the backoff, reset `attempt = 0` |
| 51 | `reconnecting` | attempt > 20 with the same terminal cause | `failed(cause)` | switch to the 5-min `coldRetry` |
| 52 | `failed` | `credentialsUpdated` | `resolving` | **immediate**; reset `attempt`; clear the §6.8 governor |
| 53 | `failed` | `setCamera` changing host/port/path/transport/channel | `resolving` | immediate; reset `attempt` |
| 54 | `failed(non-auth)` | `coldRetry` elapsed | `resolving` | auth failures never cold-retry |
| 55 | `failed` | `restart` (user action) | `resolving` | reset `attempt` |
| 56 | any active | `stop` | `stopped` | finalize recording; `TEARDOWN` (1.5 s); release lease; `Broadcaster.finish()` |
| 57 | any | `cameraDeleted` \| `cameraDisabled` | `stopped` | as above, with the matching `EndReason` |
| 58 | `stopped` | `start` | `resolving` | full restart; a stopped controller is reusable |

### 7.6 Reconnect policy

```swift
public struct ReconnectPolicy: Sendable, Equatable {
    public var delays: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2), .seconds(4),
                                     .seconds(8), .seconds(15), .seconds(30)]
    public var jitterFraction: Double = 0.20        // ±20%, uniform
    public var healthyResetInterval: Duration = .seconds(60)
    public var maxAttemptsBeforeCold: Int = 20
    public var coldRetryInterval: Duration = .seconds(300)

    /// attempt is 0-based. Beyond the table, the last value repeats forever.
    public func delay(forAttempt attempt: Int, random: inout some RandomNumberGenerator) -> Duration {
        let base = delays[min(attempt, delays.count - 1)]
        let ns = Double(base.components.seconds) * 1e9 + Double(base.components.attoseconds) / 1e9
        let factor = Double.random(in: (1 - jitterFraction)...(1 + jitterFraction), using: &random)
        return .nanoseconds(Int64(ns * factor))
    }
    public static let `default` = ReconnectPolicy()
}
```

| Attempt | Base delay | Actual range with ±20% jitter |
|---|---|---|
| 0 | 0.5 s | 0.40 – 0.60 s |
| 1 | 1 s | 0.80 – 1.20 s |
| 2 | 2 s | 1.6 – 2.4 s |
| 3 | 4 s | 3.2 – 4.8 s |
| 4 | 8 s | 6.4 – 9.6 s |
| 5 | 15 s | 12.0 – 18.0 s |
| 6 and beyond | 30 s | 24.0 – 36.0 s |
| after 20 attempts | 300 s (`coldRetry`) | fixed, no jitter |

Rules that make this behave well in the real world:

1. **Jitter is mandatory, not decorative.** After a switch reboot, 16 cameras would otherwise
   reconnect in lockstep and re-collide on every attempt. The ±20% spread decorrelates them.
2. **Reset after health, not after connect.** `attempt` returns to 0 only after
   `healthyResetInterval` (60 s) of continuous `.playing` with nominal health. A camera that connects
   and dies after 3 s must not reset its backoff, or it becomes an infinite 0.5 s reconnect loop.
   Implementation: on entering `.playing`, arm a 60 s timer; on leaving `.playing`/`.degraded`, cancel
   it; if it fires, `attempt = 0`.
3. **Network return short-circuits everything.** `networkAvailable` cancels the pending backoff and
   reconnects after `100 ms × staggerIndex` (the coordinator assigns `staggerIndex` in priority order,
   §8.7). A user who reconnects Wi-Fi sees video in well under a second, not after a 30 s wait.
4. **`networkLost` does not consume attempts.** Otherwise a 5-minute network outage exhausts the
   ladder and every camera ends up in the 5-minute cold-retry state, so video returns minutes late.
5. **Auth failures never enter the ladder** (§6.8). Neither does `.portClosed`, `.unsupportedMedia`,
   `.rtspPathNotFound` or `.credentialsMissing` — these are user-fixable configuration errors, and
   retrying them looks like a hang. They go straight to `.failed` with a specific fix in the UI and a
   Stream Doctor entry point.
6. **The countdown is public.** `StateDetail.nextRetryAt` lets the UI render "Retrying in 4 s" with a
   **Retry Now** button that calls `restart()`.

### 7.7 Health thresholds and degradation

Evaluated once per second by `HealthMonitor` (§12) from the `StreamStatistics` that VigilRTP already
computes; the controller does not recompute rates.

| Reason | Enter `degraded` when | Return to `playing` when |
|---|---|---|
| `packetLoss` | loss > **2.0 %** over a 5 s window | < **0.5 %** for 2 s |
| `highJitter` | jitter > **80 ms** (EWMA) | < **40 ms** for 2 s |
| `lowFrameRate` | measured fps < **60 %** of declared for 3 s | ≥ 85 % for 2 s |
| `decodeErrors` | ≥ **4** decode errors in 5 s | 0 errors for 5 s |
| `decodeQueueOverflow` | queue at capacity with drops in 3 of the last 5 samples | no drops for 3 s |
| `stalledMedia` | no complete frame for **5 s** | a frame arrives |
| `bitrateCollapse` | measured kbps < **25 %** of configured for 5 s (and fps is also low) | ≥ 60 % for 3 s |
| `keyframeStarvation` | no keyframe for **max(4 × GOP, 12 s)** | a keyframe arrives |

`bitrateCollapse` intentionally requires low fps too: a camera legitimately drops bitrate on a static
night scene, and flagging that as degraded would be a false alarm.

### 7.8 Quality switching, transport fallback, and configuration edits

**Quality resolution.** `setQuality(.auto)` delegates to the coordinator's policy (§8.5); `.main` /
`.sub` / `.third` pin the profile until changed. If the requested profile has `isAvailable == false`
or is missing from `capabilities`, the controller falls back in the order
`requested → sub → main → third` and emits `.warning`.

**Switch mechanics** (transition 42), budgeted at **≤ 400 ms** to first frame on the new profile:

```
PAUSE (fire-and-forget, 300 ms budget)
TEARDOWN old session          ─ skipped if the device supports SETUP on a live session
SETUP  new control URL, same transport, same interleaved channels
PLAY
requestKeyframe(.qualitySwitch)
```

The `DecodeSink` is **kept alive** across the switch when the codec is unchanged, and reconfigured on
the new SPS via transition 41 — this is what avoids a black flash. The recorder, if active, splits
into a new file (§9.7) because the resolution changed.

**Hysteresis (mandatory).** Automatic quality changes require **both**: the tile size must cross the
threshold by more than **15 %**, and it must stay across for **750 ms**. Without this, a live window
resize produces a storm of SETUP/PLAY cycles. Manual (user) switches are immediate and exempt.

**Transport fallback ladder.** Attempted at most once per connect attempt, and never consuming a
reconnect attempt:

| From | Trigger | To |
|---|---|---|
| `udpMulticast` | SETUP 461, or no RTP in 4 s | `udpUnicast` |
| `udpUnicast` | SETUP 461, or no RTP in 4 s | `tcpInterleaved` |
| `tcpInterleaved` | connect refused on 554 while 8000/80 answer | probe alternative RTSP ports 554 → 8554 → 10554, then `failed` |
| `tcpTLS` | handshake failure | **no automatic downgrade to plain TCP** — silently dropping TLS is a security regression; require explicit user consent |

**Path probe** (transition 17). On DESCRIBE 404/455 the controller tries, in order, with a 2 s budget
each, at most 4 candidates: the capability template's path, `/Streaming/Channels/{ch}01`,
`/Streaming/Channels/{ch}0{stream}`, `/h264/ch{ch}/{main|sub}/av_stream`, `/Streaming/tracks/{ch}01`.
The first that returns a parseable SDP is written back into `capabilities.rtspPathTemplate` and
persisted, so the probe happens once per device in its lifetime.

**Configuration edits.** `setCamera(_:)` diffs the incoming record:

| Changed field(s) | Response |
|---|---|
| `host`, `rtspPort`, `useTLS`, `transport`, `channel`, `rtspPathOverride` | full restart from `resolving` |
| `credentialRef` | full restart; reset the §6.8 governor |
| `streamProfile`, `latencyPreset` | in-place quality switch (transition 42) |
| `audioEnabled` | attach/detach the audio track without touching video |
| `name`, `colorTag`, `notes`, `groupID`, `orderIndex` | metadata only; no stream disturbance |
| `isEnabled → false` | `stop(reason: .cameraDisabled)` |
| `httpPort` | no stream effect; the ISAPI client is rebuilt lazily |

### 7.9 Internal composition, task tree, and cancellation

```
StreamController (actor)
├── transport: any RTSPTransport                     (VigilTransport; owns the NWConnection)
├── machine: RTSPSessionMachine                      (VigilRTSP; pure, synchronous)
├── videoDepacketizer: any Depacketizer              (VigilRTP)
├── audioDepacketizer: any Depacketizer?
├── jitterBuffer: ReorderBuffer                      (VigilRTP)
├── sink: any DecodeSink?                            (VigilVideo; nil while paused)
├── lease: DecodeLease?                              (VigilVideo)
├── recorder: ClipRecorder?                          (§9)
├── preRoll: PreRollBuffer                           (§9.3; always running when armed)
├── stats: StreamStatistics                          (VigilRTP updates it)
├── events: Broadcaster<StreamEvent>
└── timers: [TimerKey: TimerToken]
```

Task tree, created in `start()` inside a single `TaskGroup` owned by the controller, so cancelling the
controller's root task tears down everything with no orphans:

```swift
private func runLoop() async {
    await withTaskGroup(of: Void.self) { group in
        group.addTask { await self.pumpTransport() }   // bytes → machine.ingest → events
        group.addTask { await self.pumpClock() }        // clock ticks → machine.step(now:) → actions
        group.addTask { await self.pumpStatistics() }   // 1 Hz → .statistics / .health
        await group.waitForAll()
    }
}
```

- **One serialized owner.** All state transitions happen on the controller's actor executor. The
  transport delivers `Data` via an `AsyncStream`; there is no callback re-entrancy and no lock.
- **Bounded frame queue.** Frames go to the sink through a **3-slot** ring (`.low`: 2, `.quality`: 5).
  When full, the oldest **non-keyframe** is dropped and `stats.droppedFrames += 1`. If the queue is
  full of keyframes, the newest wins. Backpressure never propagates to the socket read — a stalled
  decoder must not stall the RTSP control channel or the keepalive.
- **Cancellation.** `stop()` is cooperative and idempotent: set `isStopping`, cancel the group,
  `await` the recorder's finalize (bounded at 3 s), then `TEARDOWN` with a 1.5 s budget, then
  `transport.close()`. `stop()` never throws and is safe to call from a cancelled task, so
  `Task.isCancelled` short-circuits are not needed at call sites.
- **No GCD.** The only hop off the cooperative pool is VideoToolbox's own callback, which VigilVideo
  bridges back with a continuation before anything reaches VigilCore.

### 7.10 `StreamError`

```swift
public struct StreamError: Error, Sendable, Hashable, LocalizedError {
    public var code: Code
    public var underlyingDescription: String?
    public var rtspStatus: Int?
    public var context: [String: String]     // pre-redacted; safe for logs and diagnostics
    public var isUserFixable: Bool { code.isUserFixable }
    public var errorDescription: String? { code.message }
    public var recoverySuggestion: String? { code.fix }
    public var doctorEntryPoint: Bool { code.isUserFixable }

    public enum Code: String, Sendable, Codable, CaseIterable {
        // Fatal / user-fixable → .failed, no automatic retry
        case credentialsMissing, authenticationFailed, accessForbidden, accountLocked
        case portClosed, rtspPathNotFound, unsupportedMedia, transportUnsupported
        case tlsHandshakeFailed, keychainUnavailable, deviceNotActivated, notHikvision
        case decodeUnsupported, budgetExhausted
        // Transient → reconnect ladder
        case hostResolutionFailed, connectTimeout, authTimeout, describeTimeout, setupTimeout
        case playTimeout, playFailed, noMediaReceived, noKeyframe, mediaStalled
        case keepaliveTimeout, connectionClosed, sessionLost, networkUnavailable
        case persistentDegradation, transportError, protocolViolation
        // Capture
        case recordingDiskFull, recordingWriteFailed, recordingNoKeyframe, snapshotUnavailable
        case recordingFolderUnavailable

        public var isUserFixable: Bool { get }
        public var message: String { get }   // localized, from Localizable.strings
        public var fix: String { get }
    }
}
```

Every `Code` maps to one row of the Stream Doctor table (§13.2). Adding a `Code` without adding that
row fails a unit test (§17.9) — the taxonomy and the user-facing help are kept in lockstep by force.

---

## 8. `StreamCoordinator` — app-wide arbitration

### 8.1 Role and API

Exactly one instance, owned by the `Vigil` app target. It is the **only** thing that creates,
starts, stops and destroys `StreamController`s. It answers one question continuously: *given the
current layout, window state, decode budget, thermal state and network, which cameras should be
live, at which quality, in which order?*

```swift
public actor StreamCoordinator {
    public init(configStore: ConfigStore,
                credentialStore: CredentialStore,
                eventCenter: EventCenter,
                healthMonitor: HealthMonitor,
                dependencies: CoreDependencies)

    /// Starts observing config, network, occlusion and power. Call once at launch.
    public func activate() async

    // MARK: Inputs from the UI (all idempotent; call as often as you like)
    /// The authoritative description of what is on screen. VigilUI calls this on layout change,
    /// window resize (debounced 100 ms by the caller), scroll, tab change and display change.
    public func setViewport(_ viewport: Viewport) async
    public func setFocusedCamera(_ id: CameraID?) async
    public func setFullscreenCamera(_ id: CameraID?) async
    public func setSidebarVisibleCameras(_ ids: [CameraID]) async
    public func setAudioSoloCamera(_ id: CameraID?) async

    // MARK: Direct actions (proxied to the right controller)
    public func controller(for id: CameraID) -> StreamController?
    public func start(_ id: CameraID) async
    public func stop(_ id: CameraID) async
    public func restart(_ id: CameraID) async
    public func setQuality(_ q: StreamQuality, for id: CameraID) async
    public func snapshot(_ id: CameraID, options: SnapshotOptions) async throws -> SnapshotResult
    public func snapshotAll(options: SnapshotOptions) async -> [CameraID: Result<SnapshotResult, any Error>]
    public func startRecording(_ id: CameraID, options: RecordingOptions) async throws -> RecordingHandle
    public func stopRecording(_ id: CameraID) async throws -> RecordingClip?
    public func stopAllRecordings() async -> [RecordingClip]

    // MARK: Observation
    public nonisolated func plans() -> AsyncStream<LivePlan>
    public func plan() -> LivePlan
    public func states() -> [CameraID: StreamState]

    // MARK: Shutdown
    /// Awaited on app termination: finalize recordings, flush stores, TEARDOWN all sessions.
    /// Hard budget 4.0 s; anything unfinished is abandoned with `.partial` files intact.
    public func shutdown() async
}
```

```swift
public struct Viewport: Sendable, Hashable {
    public struct Tile: Sendable, Hashable {
        public var cameraID: CameraID
        public var cellIndex: Int
        /// Size in **backing pixels** = points × backingScaleFactor. The coordinator must never
        /// reason in points, because a 480-point tile is 960 px on Retina and that changes the
        /// quality decision by two rows of §8.5.
        public var pixelSize: PixelSize
        public var isVisible: Bool           // false when scrolled out or in a hidden tab
        public var qualityOverride: StreamQuality?
        public var windowID: WindowID
    }
    public var tiles: [Tile]
    public var focusedCameraID: CameraID?
    public var fullscreenCameraID: CameraID?
    public var sidebarCameraIDs: [CameraID]      // rows currently on screen only
    public var occludedWindowIDs: Set<WindowID>
    public var isAppActive: Bool
    public var screensAreAsleep: Bool
}

public struct PixelSize: Sendable, Hashable {
    public var width: Int, height: Int
    public var pixels: Int { width * height }
}

public struct LivePlan: Sendable, Hashable {
    public struct Entry: Sendable, Hashable {
        public var cameraID: CameraID
        public var mode: DeliveryMode
        public var priority: StreamPriority
        public var reason: String                 // human-readable, shown in Advanced diagnostics
        public var cost: Double                   // decode units (§8.4)
    }
    public var entries: [Entry]                   // sorted by priority descending
    public var totalCost: Double
    public var budget: Double
    public var admittedCount: Int
    public var jpegFallbackCount: Int
    public var pausedCount: Int
    public var generatedAt: Date
    public var pressure: BudgetPressure           // .none / .moderate / .severe
}

public enum DeliveryMode: Sendable, Hashable {
    case decode(StreamProfile.Kind)       // full decode of this profile
    case keyframeOnly(StreamProfile.Kind) // decode IDR frames only
    case jpegPoll(interval: Double)       // ISAPI JPEG, no RTSP session at all
    case paused                           // session alive, decode released
    case stopped                          // no session
}
```

### 8.2 Computing the live set

`recomputePlan()` runs when any input changes, coalesced over **150 ms** (a window resize fires
dozens of viewport updates per second; the plan must not be recomputed per frame). It is a **pure
function** of its inputs, which is what makes §17.6 possible:

```swift
func makePlan(library: Library, viewport: Viewport, network: NetworkPathState,
              power: PowerConditions, budget: Double, now: Date) -> LivePlan
```

Steps, in order:

1. **Candidate set** = every `Camera` where `isEnabled` and (appears in `viewport.tiles`) or
   (`isPinnedLive`) or (appears in `viewport.sidebarCameraIDs`) or (is recording) or (has
   `autoRecordOnMotion` and `EventCenter` is armed for it) or (is the audio-solo camera).
2. **Hard stops** — these produce `.stopped` regardless of everything else:
   `!isEnabled`; `state == .failed` with `code.isUserFixable`; `viewport.screensAreAsleep` and not
   recording; `!network.isSatisfied` (controllers stay alive but in `reconnecting`).
3. **Assign priority** (§8.3).
4. **Assign a desired `DeliveryMode`** from the tile-size policy table (§8.5), then apply overrides:
   `Tile.qualityOverride` → `CellAssignment.qualityOverride` → `Camera.streamProfile` when the camera
   is focused/fullscreen.
5. **Occlusion override** — any tile whose `windowID ∈ occludedWindowIDs`, or `isVisible == false`,
   or `!viewport.isAppActive` while `settings.pauseWhenOccluded`, becomes `.paused` **unless** it is
   recording or is the audio-solo camera.
6. **Admission** (§8.4): walk entries in priority order accumulating cost; when the budget is
   exceeded, degrade the *lowest*-priority entries in this order —
   `decode(main) → decode(sub) → keyframeOnly(sub) → jpegPoll → paused` — recomputing the total after
   each step, until it fits.
7. **Diff against the running set** and emit the minimum action list: create / start / stop /
   `setQuality` / `setPaused` / `setPriority`. A camera whose mode is unchanged is **not** touched;
   this is what prevents a layout change from restarting every stream.
8. Emit `LivePlan` on `plans()` and mirror it into `LiveViewState` (§8.9).

**Anti-thrash rules.** A mode may change at most **once per 750 ms** per camera; a demotion caused by
budget pressure sticks for at least **3 s** before a promotion is considered; and the hysteresis in
§7.8 applies to every automatic quality decision.

### 8.3 Priority ordering

Priority is a computed score, evaluated in this exact order (first match wins):

| Order | Condition | Priority |
|---|---|---|
| 1 | `cameraID == viewport.fullscreenCameraID` | `.focused` (400) |
| 2 | `cameraID == viewport.focusedCameraID` and the tile is visible | `.focused` (400) |
| 3 | `cameraID == audioSoloCameraID` | `.focused` (400) |
| 4 | actively recording (manual or motion) | **`max(computed, .visibleLarge)`** — a recording stream is never demoted below full decode |
| 5 | visible tile, `pixelSize.pixels ≥ 350_000` | `.visibleLarge` (300) |
| 6 | visible tile, `pixelSize.pixels < 350_000` | `.visibleSmall` (200) |
| 7 | tile in the layout but not visible / occluded | `.offscreen` (100) |
| 8 | only present in `sidebarCameraIDs` | `.thumbnail` (50) |
| 9 | `isPinnedLive` only | `.background` (10) |

Ties break by: recording first, then lower `Layout` `cellIndex`, then lower `Camera.orderIndex`,
then `CameraID` UUID order (so the plan is fully deterministic and testable).

**Rule 4 is load-bearing.** A user recording an incident must never lose frames because they opened a
16-up grid. Recording streams are admitted *before* the budget walk and their cost is subtracted from
the budget up front.

### 8.4 Decode budget and admission

macOS has a finite number of concurrent hardware decode sessions and a finite decode throughput.
`VigilVideo` owns the authority (`DecodeAdmitting`); VigilCore owns the *policy* — which streams get
to ask.

```swift
public protocol DecodeAdmitting: Sendable {
    /// Total cost units available now. Reflects chip class, thermal state and low-power mode.
    func currentBudget() async -> Double
    /// Hard ceiling on simultaneous VTDecompressionSessions / AVSampleBufferDisplayLayers.
    func maxConcurrentSessions() async -> Int
    /// Reserves capacity. Throws `.budgetExhausted` if it cannot be satisfied.
    func acquire(cost: Double, priority: StreamPriority) async throws -> DecodeLease
}
```

**Cost model.** `cost = megapixels × fps × codecWeight`, with `codecWeight` from §3
(H.264 1.00, H.265 1.35, MJPEG 0.45). Worked examples:

| Stream | Cost |
|---|---|
| 1080p25 H.264 (main) | 2.07 × 25 × 1.00 = **51.8** |
| 1080p25 H.265 | 2.07 × 25 × 1.35 = **69.9** |
| 4 MP 20 fps H.265 (main) | 4.00 × 20 × 1.35 = **108.0** |
| D1 (704×576) 12 fps H.264 (sub) | 0.41 × 12 × 1.00 = **4.9** |
| 640×360 15 fps H.264 (sub) | 0.23 × 15 × 1.00 = **3.5** |
| keyframe-only sub (GOP 2 s → ~0.5 fps) | 0.23 × 0.5 × 1.00 = **0.12** |
| JPEG poll | **0** (no decode session; ImageIO on a utility queue) |

**Default budgets** (VigilVideo owns the table; reproduced here because the policy depends on it, and
`AppSettings.maxConcurrentDecodes == 0` means "use this"):

| Chip class | Budget (cost units) | Max sessions | Comfortable 1080p25 H.264 streams |
|---|---|---|---|
| Intel, integrated graphics only | 260 | 8 | 5 |
| Intel + discrete / T2 | 420 | 12 | 8 |
| Apple M1 / M2 / M3 (base) | 900 | 20 | 17 |
| M-series Pro | 1500 | 32 | 28 |
| M-series Max / Ultra | 2200 | 48 | 42 |

Multipliers applied by `DecodeAdmitting`, which VigilCore reacts to rather than duplicates:
`.thermalState == .fair` × 0.85, `.serious` × 0.6, `.critical` × 0.35;
`isLowPowerModeEnabled` × 0.6; on battery with `pauseOnBattery` × 0.75.

**The 16-up grid must fit.** 16 × 640×360 15 fps H.264 sub-streams = 16 × 3.5 = **56 cost units**,
comfortably inside every budget above — which is precisely why §8.5 forces sub-streams in grids. The
same grid at main stream would be 16 × 51.8 = **829 units**, over the M1's budget, and the admission
walk would demote 6–8 tiles. That is the failure the policy exists to prevent.

`BudgetPressure` is reported so the UI can explain itself:
`.none` (< 70 % of budget), `.moderate` (70–95 %), `.severe` (> 95 % or any tile demoted). Under
`.severe` the UI shows a one-line, dismissible notice: *"Vigil reduced quality on 3 cameras to keep
playback smooth."* with a link to Settings → Streams.

### 8.5 Tile pixel size → delivery mode (the policy table)

The input is the tile's size in **backing pixels**. Thresholds are on **total pixels**, not width,
because a 1+5 layout produces very non-square cells.

| Class | Tile pixels (backing) | Typical case | Video source | Decode | Effective refresh |
|---|---|---|---|---|---|
| **A — Hero** | ≥ 1 500 000 (e.g. ≥ 1632×920) | fullscreen, 1-up, hero cell of 1+5 | **main** | full | native fps |
| **B — Large** | 350 000 – 1 499 999 (e.g. 960×540) | 2×2 on a 27″, hero of 3×3 | **sub** if sub height ≥ 0.7 × tile height, else **main** | full | native fps |
| **C — Medium** | 60 000 – 349 999 (e.g. 640×360, 480×270) | 3×3, 4×4 on a large display | **sub** | full, fps capped at 15 by dropping non-reference frames | ≤ 15 fps |
| **D — Small** | 12 000 – 59 999 (e.g. 240×135, 160×90) | 5×5, dense video wall | **sub** | **keyframe-only** | 1 / GOP (≈ 0.5 fps) |
| **E — Thumbnail** | < 12 000 (e.g. 110×62 sidebar row) | sidebar micro-preview, PiP dot | **ISAPI JPEG poll** | none | 2 s |
| **F — Hidden** | any, `isVisible == false` or occluded | scrolled away, other tab, occluded window | none | **paused** | last frame held 30 s, then released |

Class-A promotion additionally requires that the main stream's cost fits the *remaining* budget after
all higher-priority entries; otherwise the tile stays on sub and the reason string reads
`"main stream withheld: budget"`.

**JPEG poll intervals** (class E), chosen so a 64-camera sidebar does not melt the control plane:

| Visible thumbnails | Interval | Effective ISAPI request rate |
|---|---|---|
| 1 – 8 | 2.0 s | ≤ 4 req/s |
| 9 – 24 | 4.0 s | ≤ 6 req/s |
| 25 – 48 | 8.0 s | ≤ 6 req/s |
| 49+ | 15.0 s | ≤ 4 req/s |
| window not active | 30.0 s | — |
| `Camera.jpegPollIntervalOverride` set | that value, clamped to 1...60 s | — |

JPEG polling requests `?videoResolutionWidth=352&videoResolutionHeight=198` (or the device's nearest
supported size) so the payload is ~12 KB rather than ~350 KB, and is issued through the per-device
ISAPI concurrency limiter (§8.8). If a device sets `jpegSnapshotIgnoresSizeParams`, the full-size
image is fetched and downscaled locally, and the interval doubles.

**Fallback when JPEG is unavailable** (`supportsJPEGSnapshot == false`, or 3 consecutive failures):
class E degrades to `keyframeOnly(.sub)` if the budget allows, else to a static generated placeholder
(camera name on a neutral tile). It never silently shows nothing.

**Hysteresis at every boundary:** a class change requires crossing the threshold by > 15 % of the
threshold value **and** holding for 750 ms. Downward changes (toward cheaper) may apply after 250 ms
when `pressure == .severe`, because relieving overload is more urgent than avoiding a flicker.

### 8.6 Occlusion, sleep/wake, thermal and power

**Occlusion.** `OcclusionObserving` translates AppKit notifications into `OcclusionEvent`s. The
AppKit adapter observes: `NSWindow.didChangeOcclusionStateNotification` (checking
`window.occlusionState.contains(.visible)`), `NSWindow.didMiniaturizeNotification` /
`didDeminiaturizeNotification`, `NSApplication.didHideNotification` / `didUnhideNotification`,
`NSApplication.didBecomeActiveNotification` / `didResignActiveNotification`, and
`NSWorkspace.screensDidSleepNotification` / `screensDidWakeNotification`.

| Condition | Effect | Exceptions |
|---|---|---|
| Window fully occluded (another window covers it) | all its tiles → `.paused` | recording, audio-solo |
| Window miniaturized | all its tiles → `.paused` | recording, audio-solo |
| App hidden (⌘H) | every tile → `.paused` | recording, audio-solo, `isPinnedLive` |
| App inactive but visible | no change; sidebar JPEG interval → 30 s | — |
| Screens asleep | every controller → `.paused`; JPEG polling stops entirely | recording continues; motion-armed cameras keep their RTSP session for the pre-roll |
| Display sleep > 10 min with nothing recording | full `stop()`, releasing sockets | `isPinnedLive` cameras keep the session |

Pausing releases the `DecodeLease` and stops feeding the sink but **keeps the RTSP session and the
keepalive**, so resuming costs one keyframe wait (~GOP/2, typically 1 s) instead of a full
connect (~600 ms–2 s). Un-pausing always issues `requestKeyframe(.qualitySwitch)`.

**Sleep and wake.** On `willSleep`: `await configStore.flush()`, `await eventLog.flush()`, finalize
every recording (they will be split, not lost), then `setPaused(true)` on all controllers — no
`TEARDOWN`, because the sockets are about to die anyway and TEARDOWN would just block the sleep.

On `didWake` the sockets are dead but the app does not know it yet, and waiting for the 12 s stall
timer would be a terrible experience. Therefore, on `didWake`:

1. Mark every controller's transport as invalid and force `reconnecting`, **without** consuming a
   reconnect attempt.
2. Wait for `NetworkPathMonitoring` to report `isSatisfied`, with a 10 s ceiling (Wi-Fi typically
   reassociates in 1–3 s).
3. Reconnect in priority order with a **250 ms** stagger, so 16 cameras spread over 4 s rather than
   hammering the switch simultaneously.
4. Re-probe capabilities only for devices whose `probedAt` is stale (§4.3) — not on every wake.
5. Restart JPEG polling after the visible decoded tiles have their first frame.

**Thermal and low power.** On `thermalStateChanged` or `lowPowerModeChanged`, the coordinator does
*not* independently throttle; it re-reads `DecodeAdmitting.currentBudget()` and lets the normal
admission walk (§8.4) demote tiles. This keeps one code path for all pressure sources. At
`.critical` the coordinator additionally: caps every tile at class C or lower, stops all JPEG
polling, and emits a UI notice — *"Your Mac is very warm. Vigil lowered video quality."*

### 8.7 Network changes

```
NWPathMonitor (VigilTransport) → NetworkPathMonitoring → coordinator
```

| Transition | Action |
|---|---|
| satisfied → unsatisfied | Every controller receives `networkLost` (transition 47): transports cancelled, attempt counters **frozen**, no timers armed. UI shows "No network connection" once, globally — **not** 16 per-camera errors. |
| unsatisfied → satisfied | Every controller receives `networkAvailable`; reconnect in priority order with a 100 ms stagger; attempt counters reset. |
| `interfaceFingerprint` changed while satisfied (Wi-Fi → Ethernet, VPN up/down, new SSID) | Treated as a full network change: `restart()` all controllers, because the local address changed and any UDP path is now wrong. Cached DNS is dropped. |
| `isConstrained` becomes true (Low Data Mode) | Cap all tiles at class C, stop JPEG polling, emit `.networkConstrained`. Do **not** stop streams — this is a LAN app and the user may be on a constrained interface unrelated to the cameras. |
| `isExpensive` becomes true | No automatic action; log at `.info`. Cameras are LAN devices; treating tethering as a reason to stop would be wrong. |

**Global, not per-camera, messaging.** When `!network.isSatisfied`, per-camera error UI is suppressed
entirely and replaced by one app-level banner. This single rule removes the most common "16 red
error toasts" complaint pattern.

### 8.8 Global concurrency limiters

Four separate limiters, because they protect different scarce resources:

```swift
/// FIFO, priority-aware, cancellation-safe. No unfair wake-ups, no thundering herd.
public actor ConcurrencyLimiter {
    public init(limit: Int, name: String)
    public func withPermit<T: Sendable>(priority: StreamPriority = .visibleSmall,
                                        _ body: @Sendable () async throws -> T) async rethrows -> T
    public func setLimit(_ limit: Int) async
    public var inFlight: Int { get }
    public var queueDepth: Int { get }
}
```

| Limiter | Default limit | Protects | Notes |
|---|---|---|---|
| `connectLimiter` | **4** (`AppSettings.maxConcurrentConnects`) | switch/AP CPU and ARP tables during mass reconnect | held from `connecting` through `playOK`, then released |
| `isapiGlobalLimiter` | **8** | the app's own URLSession and the control plane generally | — |
| `isapiPerDeviceLimiter` | **2** (**1** when `rejectsConcurrentISAPI`) | cheap Hikvision HTTP servers, which drop or 503 under parallel load | keyed by `host:port`, created lazily |
| `snapshotLimiter` | **3** | ImageIO/CoreGraphics encode bursts during "Snapshot All" | JPEG-poll fetches also pass through here |

`withPermit` acquires in **priority order**, so the focused camera's reconnect jumps the queue ahead
of 15 thumbnails. Permits are released on cancellation via `defer`, and a permit is never held across
a user-interaction wait.

### 8.9 `LiveViewState` — the UI mirror

The UI must not `await` an actor to draw a frame. `StreamCoordinator` therefore maintains a
`@MainActor` observable mirror, and VigilUI reads **only** this.

```swift
@MainActor
@Observable
public final class LiveViewState {
    public private(set) var tiles: [CameraID: TileState] = [:]
    public private(set) var plan: LivePlan?
    public private(set) var globalBanner: GlobalBanner?
    public private(set) var networkIsSatisfied: Bool = true
    public private(set) var activeRecordings: Set<CameraID> = []
    public private(set) var unreadEventCount: Int = 0
    public private(set) var budgetPressure: BudgetPressure = .none
}

public struct TileState: Sendable, Hashable {
    public var cameraID: CameraID
    public var name: String
    public var state: StreamState
    public var detail: StateDetail?
    public var mode: DeliveryMode
    public var format: StreamFormat?
    public var isHardwareDecoded: Bool
    public var isRecording: Bool
    public var isMuted: Bool
    public var stats: StreamStatistics?
    public var lastKeyframeAt: Date?
    public var degradation: DegradationReason?
    public var lastThumbnailJPEG: Data?
    public var motionRegions: [NormalizedRect]
    public var motionExpiresAt: Date?
}

public enum GlobalBanner: Sendable, Hashable {
    case noNetwork
    case budgetReduced(count: Int)
    case thermalThrottled
    case diskAlmostFull(freeGB: Int)
    case recordingsFolderUnavailable
    case configSaveFailing(String)
    case libraryRecovered(RecoverySource)
    case libraryReadOnly(futureVersion: Int)
}
```

**Update cadence — a hard rule.** `TileState` is refreshed at:

| Field group | Cadence | Why |
|---|---|---|
| `state`, `detail`, `mode`, `isRecording`, `degradation` | immediately on change, coalesced over 100 ms | these drive visible chrome |
| `stats` | **1 Hz** | 60 Hz statistics updates would re-render the whole grid every frame and blow the 120 Hz budget |
| `lastThumbnailJPEG` | on keyframe, at most every 2 s | sidebar previews |
| `motionRegions` | on event, auto-cleared 3 s after `motionExpiresAt` | overlay lifetime |

Video pixels **never** pass through `LiveViewState`. Frames go
`StreamController → DecodeSink → VigilRender` layer-side, entirely off the SwiftUI update path. This
is the single most important performance rule in the app: SwiftUI observes *status*, never *frames*.

---

## 9. Recording — `ClipRecorder`

### 9.1 Principle: passthrough, never re-encode

The camera already produced a hardware-encoded H.264/H.265 elementary stream. Re-encoding it would
cost CPU, add latency, and lose quality for nothing. `ClipRecorder` therefore **muxes** the existing
compressed samples into MP4/MOV using `AVAssetWriter` with an input created with **`outputSettings:
nil`** and a `sourceFormatHint` — the documented Apple contract for passthrough.

Consequences that shape the whole design:

- Recording works **without a decode session**. `ClipRecorder` consumes `EncodedFrame` (VigilRTP),
  not `CVPixelBuffer`, so an occluded or class-F tile can record at full main-stream quality while
  decoding nothing. This is why §8.3 rule 4 exists and why §8.6 keeps paused streams' RTSP alive.
- CPU cost is ~**0.4 % of one core** per 1080p stream — essentially `memcpy` plus atom bookkeeping.
- The recorder cannot change resolution mid-file (a format change forces a split, §9.7).
- The first sample **must** be a keyframe, or the file will not decode from the start (§9.4).

```swift
public actor ClipRecorder {
    public init(options: RecordingOptions,
                format: StreamFormat,
                camera: Camera,
                dependencies: CoreDependencies)

    /// Opens the writer, writes the pre-roll, and starts accepting frames.
    /// Throws before creating any file if disk or folder checks fail (§9.6).
    public func begin(preRoll: [EncodedFrame], audioPreRoll: [EncodedFrame]) async throws -> RecordingHandle

    /// Non-blocking. Frames are appended if the input is ready, else counted as dropped.
    public func append(video frame: EncodedFrame) async
    public func append(audio frame: EncodedFrame) async

    /// Finalizes: marks inputs finished, awaits `finishWriting`, renames .partial → final,
    /// writes the thumbnail, returns the clip record. Idempotent.
    public func finish(reason: RecordingEndReason) async -> RecordingClip

    /// Emergency path used on crash-adjacent teardown. Does NOT await finishWriting.
    /// Leaves the fragmented .partial file, which is playable (§9.9).
    public func abandon() async -> RecordingClip

    public func progress() -> RecordingProgress
    public nonisolated func events() -> AsyncStream<RecordingEvent>
}

public struct RecordingOptions: Sendable, Hashable {
    public var trigger: RecordingTrigger
    public var container: ClipContainer = .mp4
    public var preRollSeconds: Double = 5           // 0...30
    public var maxDurationSeconds: Double = 1800    // auto-split at 30 min
    public var includeAudio: Bool = true
    public var neverReencodeAudio: Bool = false
    public var fileNameTemplate: String = RecordingNaming.defaultTemplate
    public var destinationRoot: URL
    public var eventID: EventID? = nil
    public var minimumFreeBytes: Int64 = 2 << 30    // 2 GiB
    public var fragmentIntervalSeconds: Double = 2  // 0 disables fragmentation
    public var burnInTimestamp: Bool = false        // §9.10 — deliberately restricted
}

public struct RecordingHandle: Sendable, Hashable {
    public var clipID: ClipID
    public var cameraID: CameraID
    public var partialURL: URL      // …/name.mp4.partial while writing
    public var finalURL: URL
    public var startedAt: Date
    public var preRollSecondsIncluded: Double
}

public struct RecordingProgress: Sendable, Hashable {
    public var duration: Double, byteCount: Int64
    public var framesWritten: Int, framesDropped: Int
    public var audioFramesWritten: Int
    public var estimatedFinalBytes: Int64
    public var freeBytesRemaining: Int64
}

public enum RecordingEndReason: String, Sendable, Codable {
    case userStopped, durationLimit, diskFull, formatChanged, streamLost, appQuitting
    case motionEnded, writeError, cameraDeleted
}
```

### 9.2 Writer construction — exact code

```swift
private func makeWriter(format: StreamFormat, url: URL) throws -> (AVAssetWriter,
                                                                   AVAssetWriterInput,
                                                                   AVAssetWriterInput?) {
    let writer = try AVAssetWriter(outputURL: url, fileType: options.container.avFileType)

    // Crash resilience: emit a moof/mdat fragment every 2 s so a killed process still leaves a
    // playable file. MUST be set before startWriting(); it is ignored afterwards.
    if options.fragmentIntervalSeconds > 0 {
        writer.movieFragmentInterval = CMTime(seconds: options.fragmentIntervalSeconds,
                                              preferredTimescale: 1)
    }
    // Mutually exclusive with fragmentation in practice: faststart rewrites the moov at the end,
    // which is exactly what we cannot rely on happening.
    writer.shouldOptimizeForNetworkUse = false

    // Passthrough video: nil settings + a format hint built from the parameter sets.
    let videoFormat = try SampleBufferFactory.makeVideoFormatDescription(
        codec: format.videoCodec,
        parameterSets: format.parameterSets,
        nalUnitHeaderLength: 4)               // we always feed 4-byte length-prefixed NALs
    let videoInput = AVAssetWriterInput(mediaType: .video,
                                        outputSettings: nil,
                                        sourceFormatHint: videoFormat)
    videoInput.expectsMediaDataInRealTime = true
    // Non-square pixels and the 1088→1080 crop are carried by the format description itself
    // (CleanAperture + PixelAspectRatio extensions built by VigilBitstream), so no transform here.
    videoInput.transform = .identity
    guard writer.canAdd(videoInput) else { throw StreamError(code: .recordingWriteFailed) }
    writer.add(videoInput)

    var audioInput: AVAssetWriterInput?
    if options.includeAudio, let audioFormat = try makeAudioFormatDescription(format) {
        let input = AVAssetWriterInput(mediaType: .audio,
                                       outputSettings: nil,
                                       sourceFormatHint: audioFormat)
        input.expectsMediaDataInRealTime = true
        if writer.canAdd(input) { writer.add(input); audioInput = input }
    }
    guard writer.startWriting() else {
        throw StreamError(code: .recordingWriteFailed,
                          underlyingDescription: writer.error?.localizedDescription)
    }
    return (writer, videoInput, audioInput)
}
```

Appending a frame:

```swift
private func write(_ frame: EncodedFrame, to input: AVAssetWriterInput,
                   formatDescription: CMFormatDescription) throws {
    guard input.isReadyForMoreMediaData else { droppedFrames += 1; return }

    let pts = rebase(frame.pts)                 // §9.5
    let duration = frame.duration ?? nominalFrameDuration
    var timing = CMSampleTimingInfo(duration: duration,
                                    presentationTimeStamp: pts,
                                    decodeTimeStamp: frame.dts.map(rebase) ?? .invalid)

    let sample = try SampleBufferFactory.makeSampleBuffer(
        data: frame.data,                       // 4-byte length-prefixed NALs, as required
        formatDescription: formatDescription,
        timing: timing,
        isKeyframe: frame.isKeyframe)

    guard input.append(sample) else {
        throw StreamError(code: .recordingWriteFailed,
                          underlyingDescription: writer.error?.localizedDescription)
    }
}
```

`SampleBufferFactory` (VigilVideo) sets `kCMSampleAttachmentKey_NotSync = true` on non-keyframes and
`kCMSampleAttachmentKey_DependsOnOthers` appropriately; the writer relies on those attachments to
build a correct `stss` sync-sample table. Getting this wrong produces a file that seeks incorrectly —
which is why the sample-buffer construction lives in exactly one place, shared with the decode path.

### 9.3 Pre-roll ring buffer

The pre-roll is the feature that makes motion recording useful: without it, every clip starts *after*
the interesting moment.

```swift
/// Holds whole GOPs of compressed frames so a recording can start in the past.
/// Lives inside StreamController and runs whenever pre-roll is armed, independent of recording.
struct PreRollBuffer: Sendable {
    private(set) var gops: [GOP] = []          // oldest first; each starts with a keyframe
    var targetSeconds: Double                  // 0...30
    var maxBytes: Int = 96 << 20               // 96 MiB hard ceiling
    var maxGOPs: Int = 240

    struct GOP: Sendable {
        var frames: [EncodedFrame]             // frames[0].isKeyframe == true, always
        var startPTS: MediaTimestamp
        var endPTS: MediaTimestamp
        var byteCount: Int
        var duration: Double
    }

    /// Appends. A keyframe opens a new GOP; non-keyframes before the first keyframe are discarded.
    /// Then evicts whole GOPs from the front while any budget is exceeded — never partial GOPs.
    mutating func append(_ frame: EncodedFrame)

    /// Frames from the newest keyframe at or before (now - seconds). Always keyframe-first.
    func drain(seconds: Double) -> [EncodedFrame]

    var bufferedSeconds: Double { get }
    var byteCount: Int { get }
    mutating func reset()
}
```

**Why whole GOPs.** Truncating mid-GOP yields P/B frames whose references are missing: the first
second of every clip would be visual garbage. Evicting whole GOPs guarantees `drain` always begins
with a keyframe.

**Arming policy** (the buffer costs memory, so it is not always on):

| Condition | Pre-roll armed? | Seconds |
|---|---|---|
| `Camera.autoRecordOnMotion` or the global setting is on | yes | `AppSettings.preRollSeconds` |
| A schedule window is within 60 s | yes | as configured |
| Camera is focused or fullscreen | yes | `min(configured, 5)` — so ⌘R captures the moment just seen |
| Otherwise | **no** | 0 |

**Memory envelope.** 5 s of 1080p at 4 Mbps ≈ **2.5 MB** per camera. 16 armed cameras ≈ **40 MB**.
30 s at 8 Mbps ≈ 30 MB, hence the 96 MiB per-camera ceiling and a coordinator-level global ceiling of
**512 MiB** across all pre-roll buffers; when exceeded, buffers are trimmed starting from the
lowest-priority camera and the UI reports the effective pre-roll it actually achieved
(`RecordingHandle.preRollSecondsIncluded`), never a fictional number.

Audio pre-roll is a parallel ring keyed by the same timeline, drained from the video keyframe's PTS
minus 100 ms so audio never starts after video.

### 9.4 The first-sample-must-be-a-keyframe rule

```
startRecording()
├── pre-roll armed and non-empty
│     └── drain(seconds:) → begins with a keyframe → write immediately.  Latency: 0 ms.
└── pre-roll empty or disarmed
      ├── the last live frame was a keyframe < 200 ms ago → start from it
      ├── requestKeyframe(.recordingStart)
      │     ├── ISAPI requestKeyFrame honoured → keyframe in ~50–200 ms
      │     └── unsupported → wait for the natural GOP
      └── while waiting: state = .waitingForKeyframe, UI shows a pulsing REC dot and
          "Starting in ~1.4 s" computed from gopSeconds; frames are buffered, not written.
          Timeout: max(3 × gopSeconds, 6 s) → fail with .recordingNoKeyframe.
```

**Non-keyframes received before the first keyframe are discarded, never written.** The writer would
accept them and produce a file whose first samples reference nothing.

The pending-start window also buffers audio, which is then trimmed to the video start PTS so the two
tracks begin aligned.

### 9.5 Timestamp rebasing and file naming

**Rebasing.** RTP timestamps start at an arbitrary 32-bit value and the presentation clock is
camera-relative. A file must start at zero, so:

```swift
private var epoch: CMTime?            // PTS of the first written sample

private func rebase(_ ts: MediaTimestamp) -> CMTime {
    let t = CMTime(value: ts.value, timescale: ts.timescale)   // 90 kHz for video
    if let epoch { return CMTimeSubtract(t, epoch) }
    epoch = t
    return .zero
}
```

- `writer.startSession(atSourceTime: .zero)` is called immediately after `startWriting()`.
- **Wraparound and discontinuity.** VigilRTP hands over already-unwrapped `MediaTimestamp`s
  (it tracks the 2^32 rollover), so the recorder never sees a backwards jump from wrapping. If it
  nevertheless sees `pts < lastPTS` or a forward gap > **10 s**, it treats it as a discontinuity:
  emit `.timestampDiscontinuity`, and *shift the epoch* by the gap rather than writing a file with a
  10-second frozen frame. A discontinuity greater than **60 s** forces a split (§9.7).
- **Audio/video alignment** uses one shared `epoch`, taken from whichever track writes first
  (always video, by construction).
- `RecordingClip.startedAt` is the **wall-clock** time corresponding to the epoch, derived from the
  RTCP SR NTP mapping when available (VigilRTP supplies it) and from `clock.wallNow` otherwise. This
  is what makes "jump to this moment" work across a clip and the device timeline.

**Naming.**

```swift
public enum RecordingNaming {
    public static let defaultTemplate =
        "{camera}/{yyyy}-{MM}-{dd}/{camera}_{yyyy}{MM}{dd}_{HHmmss}_{trigger}"
    public static func render(_ template: String, camera: Camera, date: Date,
                             trigger: RecordingTrigger, format: StreamFormat,
                             sequence: Int) -> String
}
```

| Token | Expands to | Example |
|---|---|---|
| `{camera}` | `Camera.slug` | `front-door` |
| `{cameraName}` | sanitized display name | `Front Door` |
| `{group}` | group slug, or `ungrouped` | `driveway` |
| `{host}` | host with `.`/`:` → `-` | `192-168-1-64` |
| `{channel}` | channel number | `1` |
| `{yyyy}` `{MM}` `{dd}` `{HH}` `{mm}` `{ss}` | local-time components | `2026` `07` `26` |
| `{HHmmss}` | compact time | `142530` |
| `{epoch}` | UNIX seconds | `1784125530` |
| `{trigger}` | `RecordingTrigger.rawValue` | `motion` |
| `{codec}` | `h264` / `h265` | `h265` |
| `{res}` | `WxH` | `1920x1080` |
| `{seq}` | 3-digit split index, only for splits | `002` |

Sanitization: NFC-normalize; replace `/ \ : * ? " < > |` and every control character with `-`;
collapse runs of `-`; strip leading/trailing `.` and whitespace; reject the reserved names `.`/`..`;
truncate each path component to **200 bytes UTF-8** (leaving room for `.mp4.partial`); if the result
is empty, use the camera UUID. **Collision handling:** if the final URL exists, append ` (2)`,
` (3)`, … before the extension, up to 999, then fall back to `-<uuid-prefix>`.

`Camera.slug` = lowercased display name, non-alphanumerics → `-`, collapsed, trimmed, ≤ 48 chars;
empty result → `camera-<first 8 of UUID>`. Slugs are **not** guaranteed unique; the date folder and
the timestamp disambiguate.

### 9.6 Pre-flight checks and disk space

Checked in `begin()`, **before** any file is created, so a failure costs nothing:

| # | Check | Failure |
|---|---|---|
| 1 | Destination root exists, or can be created | `.recordingFolderUnavailable` |
| 2 | Security-scoped bookmark resolved and access started (sandbox) | `.recordingFolderUnavailable` with a "Choose Folder…" action |
| 3 | Root is writable (`FileManager.isWritableFile`) | `.recordingFolderUnavailable` |
| 4 | `availableCapacityForImportantUsage ≥ max(minimumFreeBytes, estimate × 1.5)` | `.recordingDiskFull` |
| 5 | The volume is not read-only and not a network mount flagged unreliable (warn only) | warning |
| 6 | `StreamFormat` has usable parameter sets | `.recordingWriteFailed` |

`estimate = (videoBitrateKbps + audioBitrateKbps) / 8 × expectedDurationSeconds`, using
`maxDurationSeconds` when the recording is open-ended.

**During recording**, free space is re-checked every **10 s** (and every 64 MB written):

| Free space | Action |
|---|---|
| < `minimumFreeBytes` (2 GiB default) | finish cleanly with `.diskFull`; notify; set the `diskAlmostFull` banner |
| < 512 MiB | finish immediately, and disable all recording until space is freed |
| < 5 GiB | warn once per session |

Retention (`AppSettings.retentionDays` / `retentionMaxGigabytes`) is enforced by a **separate**
maintenance pass at launch and every 6 hours, never by the recorder mid-write. It deletes oldest-first,
skips clips referenced by an unread event or a bookmark, moves files to the Trash rather than
unlinking (`FileManager.trashItem`) so a misconfiguration is recoverable, and never touches files it
has no clip record for.

### 9.7 Splitting

A single recording becomes multiple files when any of these occur. Splits are seamless in the sense
that no frames are lost: the new file's first sample is the keyframe that triggered or immediately
follows the split.

| Trigger | Behaviour |
|---|---|
| `maxDurationSeconds` reached (default 30 min) | at the next keyframe: finish, open `{seq}+1` |
| Mid-stream format change (transition 41) | finish immediately, open a new file with the new format hint |
| Quality switch main↔sub | same as a format change |
| Timestamp discontinuity > 60 s | finish, open new |
| File approaching 4 GiB | split at the next keyframe (MP4 `stco` vs `co64` interoperability caution) |
| Disk pressure | finish, do not reopen |

Each part is its own `RecordingClip`, linked by a shared `sessionID` in `RecordingClip.notes`
(`"session:<uuid> part:2"`) so the UI can present them as one incident and export can concatenate.

### 9.8 Graceful finish

```swift
public func finish(reason: RecordingEndReason) async -> RecordingClip {
    guard !isFinishing else { return await finishedClip }
    isFinishing = true
    videoInput.markAsFinished()
    audioInput?.markAsFinished()
    if writer.status == .writing {
        writer.endSession(atSourceTime: lastWrittenPTS)
        await writer.finishWriting()            // async overload; no semaphores
    }
    if writer.status == .completed {
        try? fs.moveItem(at: partialURL, to: finalURL)   // atomic rename within the volume
    } else {
        // .failed — keep the .partial file; a fragmented MP4 is still playable (§9.9)
        clip.isPartial = true
        logger.error("recording failed", metadata: ["error": "\(writer.error?.localizedDescription ?? "")"])
    }
    await writeThumbnail()
    return clip
}
```

Ordering rules:

- **The `.partial` suffix is the crash marker.** A file is named `name.mp4.partial` while writing and
  renamed only after `finishWriting()` reports `.completed`. Any `.partial` file found at launch was
  interrupted.
- `finish()` is called **before** `TEARDOWN` in `StreamController.stop()` (transition 56) and before
  the transport is closed on `socketClosed` (transition 39), so the last fragment is always flushed.
- `shutdown()` (§8.1) budgets **4.0 s** total for all recorders. Recorders that do not finish in time
  get `abandon()`, which skips `finishWriting()` and leaves a playable fragmented file.
- On `willSleep`, all recordings are finished (not paused). Resuming a muxer across a sleep is not
  reliable, and a split file is strictly better than a corrupt one.

### 9.9 Crash recovery

At launch, `RecordingRecovery.scan()` walks the recordings root for `*.partial`:

1. `AVURLAsset` load with `.isPlayable` / `duration` checked. Because the file was written with
   `movieFragmentInterval = 2 s`, everything up to the last completed fragment is present and
   playable — this is the entire reason fragmentation is enabled.
2. Playable and duration ≥ 1 s → rename to the final name, insert/update a `RecordingClip` with
   `isPartial = true`, and surface it in the UI as "Recovered".
3. Playable but < 1 s, or unplayable → move to the Trash and log at `.notice`. Sub-second garbage is
   not worth a UI row.
4. A matching clip record already exists (the app crashed after recording it) → reconcile duration,
   `byteCount` and `endedAt` from the file.
5. Orphaned `.partial` files with no clip record → recovered with a synthesized record whose
   `cameraID` is parsed from the path; if that fails, the file is left alone and reported once.

The scan is bounded: at most 5 000 files examined, 10 s wall clock, run off the main actor.

### 9.10 Two deliberate restrictions

- **Burn-in timestamp on recordings is not supported in passthrough mode.** Drawing pixels requires
  decode + re-encode, which the whole design refuses. `RecordingOptions.burnInTimestamp` therefore
  applies only to **snapshots** (§10.5); attempting it on a clip returns
  `.recordingWriteFailed` with the message *"Timestamps can't be burned into recordings without
  re-encoding. Use the camera's own OSD instead."* Hikvision cameras can render an OSD server-side,
  and the Inspector links to that setting — which is the correct fix.
- **Audio: G.711 in MP4.** `alaw`/`ulaw` are not valid MP4 audio codecs. Resolution:

| `neverReencodeAudio` | Audio codec | Result |
|---|---|---|
| `false` (default) | AAC | passthrough into MP4 |
| `false` | G.711 / G.726 | **transcode to AAC-LC** 64 kbps mono via `AVAudioConverter` (VigilVideo). Cost: < 0.1 % CPU. Video is still passthrough. |
| `true` | AAC | passthrough into MP4 |
| `true` | G.711 | container switches to **`.mov`**, `alaw`/`ulaw` passthrough; the UI states the reason |
| any | unsupported/unknown | audio dropped, `.audioCodecUnsupported` warning, video recorded |

---

## 10. Snapshots — `SnapshotService`

### 10.1 Two sources, one API

```swift
public actor SnapshotService {
    public init(dependencies: CoreDependencies, isapiLimiter: ConcurrencyLimiter,
                snapshotLimiter: ConcurrencyLimiter)

    public func capture(camera: Camera,
                        credential: Credential?,
                        frameTap: (any FrameTap)?,      // nil when nothing is decoding
                        options: SnapshotOptions) async throws -> SnapshotResult

    /// "Snapshot All" — bounded concurrency, per-camera failures isolated.
    public func captureAll(_ requests: [SnapshotRequest],
                           options: SnapshotOptions) async -> [CameraID: Result<SnapshotResult, any Error>]
}

public struct SnapshotOptions: Sendable, Hashable {
    public var source: SnapshotSourcePreference = .automatic
    public var format: SnapshotFormat = .png
    public var jpegQuality: Double = 0.9            // also used for HEIC
    public var destinations: Set<SnapshotDestination> = [.file]
    public var destinationRoot: URL?                // nil = ~/Pictures/Vigil
    public var nameTemplate: String = SnapshotNaming.defaultTemplate
    public var burnInOverlay: BurnInOverlay? = nil
    public var maxLongEdge: Int? = nil              // nil = native; used for thumbnails
    public var includeEXIF: Bool = true
    public var deviceJPEGSize: Resolution? = nil    // ISAPI resize hint
}

public enum SnapshotDestination: String, Sendable, Hashable, CaseIterable {
    case file, clipboard, quickLook, shareSheet, dataOnly
}

public struct SnapshotResult: Sendable, Hashable {
    public var cameraID: CameraID
    public var url: URL?                  // nil when no .file destination
    public var data: Data                 // the encoded bytes, always present
    public var format: SnapshotFormat
    public var pixelSize: PixelSize
    public var capturedAt: Date
    public var source: Source
    public var byteCount: Int
    public enum Source: String, Sendable, Codable { case renderedFrame, deviceJPEG, cachedThumbnail }
}
```

| Source | Latency | Pixels | Cost | Chosen when |
|---|---|---|---|---|
| `renderedFrame` | 8–30 ms | **exactly what the user sees**, including digital zoom, colour adjustments and deinterlacing | one `CVPixelBuffer` copy + one encode | a decode session exists and the tile is not paused |
| `deviceJPEG` | 60–400 ms (LAN) | the camera's own encode at full sensor resolution, no client effects | one HTTP GET | nothing is decoding, or `source == .deviceJPEG`, or the user wants full resolution from a sub-stream tile |
| `cachedThumbnail` | < 1 ms | last keyframe thumbnail, ≤ 640 px | none | last-resort fallback so ⌘⇧S never simply fails |

`.automatic` resolution order: `renderedFrame` → `deviceJPEG` → `cachedThumbnail`. Each fallback emits
a `.warning` so the UI can note *"Saved from the camera's own snapshot (full resolution)."*

### 10.2 Rendered-frame path

```swift
guard let pixelBuffer = await frameTap.captureCurrentFrame() else { throw … }
// Prefer VideoToolbox's converter: it handles biplanar 8- and 10-bit and the correct YCbCr matrix.
var cgImage: CGImage?
let status = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
if status != noErr || cgImage == nil {
    // Fallback: CIContext, which also lets us apply the render pipeline's colour adjustments.
    let ci = CIImage(cvPixelBuffer: pixelBuffer)
    cgImage = ciContext.createCGImage(ci, from: ci.extent,
                                      format: .RGBA8,
                                      colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
}
```

- The `CIContext` is created **once** (`CIContext(mtlDevice:options:[.cacheIntermediates: false])`)
  and shared, using the app-wide `MTLDevice` from VigilRender. Creating one per snapshot costs ~40 ms.
- 10-bit HEVC (`420YpCbCr10BiPlanarVideoRange`) goes through the `CIContext` path with a
  `displayP3` working space, and defaults to **HEIC** output to preserve the extra depth. Choosing PNG
  for 10-bit content emits a warning that the image was reduced to 8-bit.
- Non-square pixels (SAR ≠ 1) and the 1088→1080 clean aperture are corrected **before** encoding, so a
  saved image matches the on-screen aspect ratio. This is a scale of the `CGImage` to the display
  aspect, using `CGContext` with `interpolationQuality = .high`.
- `maxLongEdge` downscaling happens here, in one pass, before encoding.

### 10.3 Device-JPEG path

`GET /ISAPI/Streaming/channels/{channelID}/picture?videoResolutionWidth=W&videoResolutionHeight=H`
through `ISAPIClient`, wrapped in `isapiPerDeviceLimiter`, with a **5 s** timeout.

- If the camera sets `jpegSnapshotIgnoresSizeParams`, the parameters are omitted and any downscale is
  done locally.
- If `jpegSnapshotNeedsChannelSuffix`, the alternate path form is used (the ISAPI spec owns it).
- Format conversion: when `options.format != .jpeg`, the returned JPEG is decoded with
  `CGImageSourceCreateWithData` and re-encoded. When `.jpeg` and there is no overlay and no resize,
  **the original bytes are written verbatim** — no decode/re-encode round trip, so the file is exactly
  what the camera produced.
- HTTP 503 / `deviceBusy` retries twice with 300 ms spacing; three consecutive failures set
  `supportsJPEGSnapshot = false` for 10 minutes (soft-disable, not persisted).

### 10.4 Encoding, EXIF and metadata

One code path for all three formats, via ImageIO:

```swift
private func encode(_ image: CGImage, format: SnapshotFormat, quality: Double,
                    metadata: SnapshotMetadata) throws -> Data {
    let type: CFString = switch format {
        case .png:  UTType.png.identifier as CFString
        case .jpeg: UTType.jpeg.identifier as CFString
        case .heic: UTType.heic.identifier as CFString
    }
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, type, 1, nil) else {
        throw SnapshotError.encoderUnavailable(format)
    }
    var props: [CFString: Any] = [:]
    if format != .png { props[kCGImageDestinationLossyCompressionQuality] = quality }
    props[kCGImagePropertyExifDictionary] = [
        kCGImagePropertyExifDateTimeOriginal: Self.exifDate(metadata.capturedAt),
        kCGImagePropertyExifSubsecTimeOriginal: Self.exifSubsec(metadata.capturedAt),
        kCGImagePropertyExifOffsetTime: Self.exifOffset(metadata.timeZone),
        kCGImagePropertyExifUserComment: metadata.userComment,
        kCGImagePropertyExifPixelXDimension: image.width,
        kCGImagePropertyExifPixelYDimension: image.height,
    ]
    props[kCGImagePropertyTIFFDictionary] = [
        kCGImagePropertyTIFFMake: metadata.make,                 // "Hikvision" or "Unknown"
        kCGImagePropertyTIFFModel: metadata.model,                // "DS-2CD2143G0-I"
        kCGImagePropertyTIFFSoftware: metadata.software,          // "Vigil 1.0 (412)"
        kCGImagePropertyTIFFDateTime: Self.exifDate(metadata.capturedAt),
        kCGImagePropertyTIFFImageDescription: metadata.cameraName,
        kCGImagePropertyTIFFArtist: metadata.cameraName,
    ]
    props[kCGImagePropertyIPTCDictionary] = [
        kCGImagePropertyIPTCObjectName: metadata.cameraName,
        kCGImagePropertyIPTCCaptionAbstract: metadata.userComment,
        kCGImagePropertyIPTCKeywords: metadata.keywords,          // ["Vigil", camera, group, trigger]
        kCGImagePropertyIPTCDateCreated: Self.iptcDate(metadata.capturedAt),
        kCGImagePropertyIPTCTimeCreated: Self.iptcTime(metadata.capturedAt),
    ]
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw SnapshotError.encodeFailed }
    return out as Data
}
```

- EXIF date format is **`"yyyy:MM:dd HH:mm:ss"`** (colons in the date — the classic mistake), in the
  camera's local time, with `OffsetTimeOriginal` carrying the zone so the instant is unambiguous.
- `userComment` = `"Front Door — 2026-07-26 14:25:30 +03:00 — 1920×1080 H.265 — Vigil 1.0"`.
- **No GPS is ever written.** Camera locations are sensitive and we do not have them.
- **`serialNumber` is never written into metadata.** Same redaction rule as logs (§6.1).
- PNG additionally gets `kCGImagePropertyPNGDictionary` with `Description`, `Software` and
  `CreationTime`, because many PNG viewers ignore EXIF.
- HEIC availability is checked once via `CGImageDestinationCopyTypeIdentifiers()`; if HEIC is
  unavailable the service falls back to JPEG and tells the user once.

### 10.5 Burn-in overlay

Optional, snapshot-only (§9.10), drawn into a `CGContext` after the image is composed and before
encoding.

```swift
public struct BurnInOverlay: Sendable, Hashable {
    public enum Corner: String, Sendable, Codable { case topLeft, topRight, bottomLeft, bottomRight }
    public var corner: Corner = .bottomLeft
    public var showCameraName: Bool = true
    public var showTimestamp: Bool = true
    public var showResolution: Bool = false
    public var dateFormat: String = "yyyy-MM-dd HH:mm:ss"
    /// Point size at 1080p; scaled linearly with image height, clamped to 9...48.
    public var baseFontSize: Double = 16
    public var textColor: CodableColor = .white
    public var backgroundOpacity: Double = 0.55       // rounded plate behind the text
}
```

Drawing rules: `CTFramesetter` with the system font at
`clamp(baseFontSize × imageHeight / 1080, 9, 48)`; a 6 pt inset rounded plate at
`backgroundOpacity` black; 12 pt margin from the chosen corner, respecting the image's own scale; text
is rendered in the user's locale. The overlay is drawn **once**, at full resolution, before any
downscale, so text stays crisp.

### 10.6 Destinations

| Destination | Implementation | Notes |
|---|---|---|
| `.file` | `writeDurably` to `root/rendered-name.ext`, collision-suffixed like §9.5 | `SnapshotNaming.defaultTemplate = "{camera}_{yyyy}{MM}{dd}_{HHmmss}"`, root `~/Pictures/Vigil` |
| `.clipboard` | `NSPasteboard.general.clearContents()`, then `setData(_:forType:)` with `.png` / `.tiff` **and** a `.fileURL` when a file was also written, so paste works in both Mail and Finder | AppKit adapter behind `PasteboardWriting` |
| `.quickLook` | write to `<Caches>/Vigil/QuickLook/`, then hand the URL to the app layer which drives `QLPreviewPanel` | VigilCore never touches `QLPreviewPanel` itself |
| `.shareSheet` | returns the URL; the app layer presents `NSSharingServicePicker` | — |
| `.dataOnly` | returns `SnapshotResult.data` with no side effects | used by App Intents (§14.1) and event thumbnails |

"Snapshot All" (⌘⇧S with no focus, or the intent) runs through `snapshotLimiter` (limit 3), writes
into a single dated folder `~/Pictures/Vigil/All Cameras/{yyyy-MM-dd HH.mm.ss}/`, reports progress as
`n of m`, and returns per-camera `Result`s so one offline camera does not abort the batch. A summary
notification lists successes and failures.

---

## 11. Events — `EventCenter`

### 11.1 Role

`EventCenter` turns per-device ISAPI alert streams into a coherent, deduplicated, persisted,
user-visible event history — and into automatic recordings.

```swift
public actor EventCenter {
    public init(configStore: ConfigStore, credentialStore: CredentialStore,
                eventLog: EventLog, dependencies: CoreDependencies)

    /// Starts/stops per-device subscriptions to match the library. Idempotent; call on any change.
    public func reconcileSubscriptions() async

    public func setCoordinator(_ coordinator: StreamCoordinator) async   // for auto-record
    public func markRead(_ ids: Set<EventID>) async
    public func markAllRead() async
    public func delete(_ ids: Set<EventID>) async
    public func recent(_ query: EventQuery) async -> [EventRecord]
    public func unreadCount() async -> Int
    /// Synthesized events raised by Vigil itself, not by a device.
    public func recordSynthetic(_ kind: EventKind, camera: CameraID, detail: String) async
    public nonisolated func events() -> AsyncStream<EventCenterEvent>
    public func subscriptionStates() async -> [CameraID: AlertSubscriptionState]
}

public enum AlertSubscriptionState: Sendable, Hashable {
    case notSupported, idle, connecting, streaming(since: Date)
    case polling(interval: Double)          // fallback when the stream is unavailable
    case failed(reason: String, retryAt: Date)
}

public enum EventCenterEvent: Sendable {
    case received(EventRecord)
    case coalesced(EventRecord)               // an existing record was extended
    case cleared(EventID)                    // eventState went inactive
    case subscriptionChanged(CameraID, AlertSubscriptionState)
    case autoRecordStarted(CameraID, EventID, ClipID)
    case autoRecordSuppressed(CameraID, reason: SuppressionReason)
}
```

### 11.2 Subscriptions

One long-lived subscription **per device**, not per channel: an NVR's single alert stream carries
every channel, and opening 32 streams to one NVR would be abusive. Devices are keyed by
`host:httpPort`; cameras sharing a host share a subscription and are demultiplexed by `channelID`.

- Started for a device when **any** of its cameras is enabled and (`notificationsEnabled` for a kind
  the device supports, or `autoRecordOnMotion`, or the Events feed is open).
- `GET /ISAPI/Event/notification/alertStream` with Digest, `Accept: multipart/mixed`, no timeout on
  the body. `ISAPIClient` owns the streaming multipart parser (bounded buffers, per the ISAPI spec);
  `EventCenter` consumes an `AsyncStream<AlertStreamPart>`.
- **Reconnect policy** (independent of the RTSP ladder, because the failure modes differ):
  `1, 2, 5, 10, 20, 30 s`, capped at 30 s, ±20 % jitter; reset after 120 s of a healthy stream.
  Auth failure is terminal and disables the subscription with a UI reason (no lockout risk, §6.8).
- **Heartbeat.** Many firmwares send nothing at all when idle. If no bytes (not even a boundary)
  arrive for **120 s**, the stream is presumed dead and reconnected. Devices flagged
  `alertStreamDropsWithoutTraffic` additionally get a cheap `GET /ISAPI/System/status` probe every
  30 s to keep the TCP path warm.
- **Fallback to polling.** When `supportsAlertStream == false` or 5 consecutive stream failures occur,
  `EventCenter` polls `/ISAPI/Event/triggers` status every **10 s** and synthesizes events from
  transitions. State becomes `.polling(interval:)` and the UI says *"Events are being checked every
  10 seconds (this camera doesn't support live alerts)."*
- Subscriptions pass through `isapiPerDeviceLimiter` on **connect only**; the streaming body does not
  hold a permit, or one alert stream would starve every other ISAPI call.

### 11.3 Dedupe and coalescing

Cameras re-announce an active event every 1–2 s for its entire duration (`activePostCount` climbs).
Writing each as a row would produce hundreds of identical entries per minute.

```swift
public struct CoalesceKey: Hashable, Sendable {
    public let cameraID: CameraID
    public let channel: Int
    public let kind: EventKind
}
```

**The rule.** An incoming alert with the same `CoalesceKey` as a record whose `lastAt` is within
**3.0 s** *extends* that record instead of creating a new one:

```
lastAt   = max(lastAt, incoming.dateTime)
count   += 1
isActive = incoming.isActive
regions  = incoming.regions.isEmpty ? regions : incoming.regions   // keep the last known polygon
severity = max(severity, incoming.severity)
thumbnail: kept from the first alert; replaced only if the first had none
```

- A gap **> 3.0 s** starts a new record. So continuous motion for 5 minutes yields one record with
  `count ≈ 200` and a 5-minute span — exactly one row in the feed, with a duration.
- `eventState == "inactive"` sets `isActive = false`, emits `.cleared`, and closes the window
  immediately (the next alert starts a new record regardless of the 3 s rule).
- **Exact duplicates** — same key, same `dateTimeRaw`, same `activePostCount` — are dropped entirely
  (some firmwares send each alert twice).
- Rate limiting: a hard ceiling of **10 new records per camera per minute** and **60 app-wide per
  minute**. Beyond it, alerts still coalesce into existing records but no new records are created, one
  `.notice` is logged, and a synthetic `EventKind.unknown` record named "Event storm" is written once
  per hour with the suppressed count. This is the defence against a misconfigured camera with
  sensitivity at maximum pointed at a tree.
- Clock skew: if a device's `dateTime` differs from `clock.wallNow` by more than **60 s**, the record
  stores the device time in `deviceTimeRaw` but uses **local receipt time** for `firstAt`/`lastAt`, and
  a one-time `.deviceClockSkew` warning is raised (a wrong device clock otherwise scatters events
  across the timeline). The Inspector offers "Sync camera clock to this Mac" via ISAPI.

Coalescing state lives in memory (`[CoalesceKey: EventID]` plus `lastAt`) and is rebuilt from the last
200 records of `EventLog` at launch, so a restart mid-motion does not duplicate the record.

### 11.4 Thumbnails

The `image/jpeg` part of the multipart alert is the cheapest possible thumbnail and is used when
present. Otherwise, and only for kinds in `notifyKinds`, a snapshot is fetched via
`SnapshotService.capture(..., options: .eventThumbnail)` — `maxLongEdge: 640`, `.jpeg`, quality 0.7,
`.dataOnly` — preferring the rendered frame when the camera is already live (free) and the device JPEG
otherwise.

Storage: `<Caches>/Vigil/EventThumbnails/<eventID>.jpg`, `EventRecord.thumbnailPath` holding the
relative name. Cache limits: **5 000 files** and **512 MB**, LRU-pruned at launch and every 6 hours;
pruning updates `thumbnailPath` to `nil`. Thumbnails are in Caches, not Application Support, because
they are regenerable and must not be backed up.

Thumbnail fetch is fire-and-forget with a 3 s budget and never blocks the event record from being
written — the event row appears instantly, the image fills in.

### 11.5 Notifications

```swift
public protocol NotificationScheduling: Sendable {
    func requestAuthorizationIfNeeded() async -> Bool
    func registerCategories() async
    func post(_ request: LocalNotification) async throws
    func removeDelivered(matching: Set<String>) async
    var responses: AsyncStream<NotificationResponse> { get }
}

public struct LocalNotification: Sendable {
    public var identifier: String          // "event.<eventID>" — stable, so updates replace
    public var categoryIdentifier: String  // "vigil.event.motion", "vigil.stream.lost"
    public var threadIdentifier: String    // "camera.<cameraID>" — groups by camera in Notification Centre
    public var title: String               // camera name
    public var subtitle: String            // event kind, localized
    public var body: String                // "Motion detected · 14:25:30"
    public var attachmentURL: URL?         // the JPEG thumbnail
    public var interruptionLevel: UNNotificationInterruptionLevel
    public var relevanceScore: Double      // severity / 3.0
    public var userInfo: [String: String]  // ["cameraID", "eventID", "clipID", "deepLink"]
    public var sound: NotificationSound
}
```

Live implementation notes:

- `UNUserNotificationCenter.current().add(_:)` with a `nil` trigger (immediate).
- Attachment: `UNNotificationAttachment(identifier: eventID, url: fileURL, options: nil)`. **The file
  is copied into a temporary directory first** — `UNNotificationAttachment` *moves* the file into its
  own store, which would delete our cached thumbnail.
- Categories registered once at launch: `vigil.event.motion` etc. with actions
  **View Live** (`vigil.action.viewLive`, foreground), **Open Clip**
  (`vigil.action.openClip`, foreground, shown only when `clipID != nil`), **Snapshot**
  (`vigil.action.snapshot`, background), **Mute 1 Hour** (`vigil.action.mute1h`, destructive).
- `interruptionLevel`: `.timeSensitive` for `.alarm` severity, `.active` for `.warning`,
  `.passive` for `.info`/`.notice`.
- **Throttle** (independent of §11.3's record coalescing, because a user's tolerance differs from a
  database's): at most **1** notification per camera per **60 s** per kind, and **6** app-wide per
  minute. Suppressed notifications increment a counter that is folded into the next one:
  *"Motion detected · 4 more times"*.
- Quiet hours suppress delivery entirely for `.info`/`.notice`/`.warning`; `.alarm` still posts.
- `notifyOnStreamLossAfterSeconds` (default 30 s) produces a `.streamLost` synthetic event and a
  notification, throttled to once per camera per 10 minutes, and is **cancelled** if the stream
  recovers before the timer fires. On recovery a delivered stream-loss notification is removed via
  `removeDelivered`.
- Authorization is requested **lazily** — the first time the user enables notifications or a
  notifiable event occurs — never at launch. A denied authorization disables the toggle with a link to
  System Settings.
- Notification responses arrive as `NotificationResponse` and are routed through exactly the same
  handler as `vigil://` deep links (§14.3), so there is one action-dispatch path in the app.

### 11.6 Motion → auto-record

```swift
public enum SuppressionReason: String, Sendable {
    case cooldown, alreadyRecording, diskFull, cameraDisabled, folderUnavailable
    case globalLimit, budgetExhausted, quietHoursNoRecord
}
```

Trigger conditions, all required:

1. `EventKind` is in the auto-record set: `.motion`, `.lineCrossing`, `.intrusion`, `.regionEntrance`,
   `.tamper` (configurable per camera).
2. `Camera.autoRecordOnMotion || AppSettings.autoRecordOnMotionGlobal`.
3. The event is `isActive` and newly created (a coalesced extension does **not** start a second clip;
   it extends the running one).
4. Cooldown elapsed: `autoRecordCooldownSeconds` (default **60 s**) since the *end* of the previous
   auto-recording for that camera.
5. Not already recording that camera (a manual recording always wins; the event is annotated onto it).
6. Disk and folder pre-flight (§9.6) pass.
7. Global cap: at most **8** concurrent auto-recordings; beyond that, suppress with `.globalLimit`
   ordered by camera priority.

Recording shape:

```
motion starts ──► clip begins at (event time − preRollSeconds)   [pre-roll ring, §9.3]
                  ├── while further alerts coalesce: extend the planned end
motion inactive ─► planned end = lastAt + postRollSeconds (default 15 s)
                  ├── new motion before the planned end: extend, do not split
                  └── hard cap: maxDurationSeconds (30 min) → split (§9.7)
```

On completion, `RecordingClip.eventID` and `EventRecord.clipID` are cross-linked in one
`ConfigStore.mutate` + `EventLog.upsert` pair, so the Events feed gets a working "Play clip" button
and the clip list shows why it exists.

**The pre-roll requirement is the whole point.** A camera reports motion 200–800 ms after it starts,
and an RTSP-only recording would additionally wait up to a full GOP for a keyframe — so a naive
implementation misses the first 1–3 seconds, which is usually the only part that matters. The ring
buffer (armed whenever `autoRecordOnMotion` is set, §9.3) makes the clip start *before* the event.

---

## 12. `HealthMonitor` — 1 Hz sampling and history

### 12.1 API

```swift
public actor HealthMonitor {
    public init(historyMinutes: Int = 10, dependencies: CoreDependencies)

    public func register(_ controller: StreamController) async
    public func unregister(_ id: CameraID) async

    /// Starts the 1 Hz tick. One timer for the whole app, not one per camera.
    public func activate() async
    public func deactivate() async

    public func history(for id: CameraID) -> [HealthSample]        // oldest → newest
    public func latest(for id: CameraID) -> HealthSample?
    public func summary(for id: CameraID, window: Duration) -> HealthSummary
    public func allLatest() -> [CameraID: HealthSample]
    public nonisolated func samples() -> AsyncStream<(CameraID, HealthSample)>

    /// CSV for the diagnostics bundle (§13.4).
    public func exportCSV(for id: CameraID) -> String
}

public struct HealthSummary: Sendable, Hashable {
    public var meanFPS: Double, minFPS: Double
    public var meanKbps: Double, peakKbps: Double
    public var meanLossPercent: Double, peakLossPercent: Double
    public var meanJitterMs: Double, peakJitterMs: Double
    public var meanLatencyMs: Double
    public var uptimeFraction: Double        // time in .playing/.degraded ÷ window
    public var reconnectCount: Int
    public var droppedFrames: Int
    public var keyframeIntervalSeconds: Double
    public var grade: HealthGrade            // .good / .fair / .poor / .offline
}

public enum HealthGrade: String, Sendable, Codable { case good, fair, poor, offline }
```

`HealthGrade` thresholds, used for the sidebar status dot colour:

| Grade | Condition |
|---|---|
| `.good` | state `.playing`, loss < 0.5 %, jitter < 40 ms, fps ≥ 85 % of declared |
| `.fair` | state `.playing`/`.degraded`, loss < 2 %, jitter < 80 ms, fps ≥ 60 % |
| `.poor` | state `.degraded`, or any threshold worse than `.fair` |
| `.offline` | state `.failed`/`.stopped`/`.reconnecting` |

### 12.2 The ring

```swift
/// 24 bytes, no padding, no reference types. Fixed capacity, O(1) insert, zero allocation
/// after construction.
public struct HealthSample: Sendable, Codable, Hashable {
    public var tSeconds: UInt32       // seconds since the monitor's epoch
    public var fps: Float             // 4
    public var kbps: Float            // 4
    public var lossPermille: UInt16   // 0...1000 = 0...100.0 %
    public var jitterMs: UInt16
    public var latencyMs: UInt16      // end-to-end estimate from VigilRTP
    public var droppedFrames: UInt16  // delta since the previous sample
    public var decodeQueueDepth: UInt8
    public var state: UInt8           // StreamState index
    public var flags: Flags           // UInt8

    public struct Flags: OptionSet, Sendable, Codable, Hashable {
        public let rawValue: UInt8
        public static let hardwareDecode = Flags(rawValue: 1 << 0)
        public static let recording      = Flags(rawValue: 1 << 1)
        public static let audioActive    = Flags(rawValue: 1 << 2)
        public static let keyframeInWindow = Flags(rawValue: 1 << 3)
        public static let mainStream     = Flags(rawValue: 1 << 4)
        public static let jpegFallback   = Flags(rawValue: 1 << 5)
        public static let paused         = Flags(rawValue: 1 << 6)
        public static let degraded       = Flags(rawValue: 1 << 7)
    }
}

struct HealthRing: Sendable {
    private var storage: [HealthSample]     // count == capacity, pre-filled
    private var head: Int = 0               // next write index
    private var filled: Int = 0
    let capacity: Int                       // 600 for 10 minutes at 1 Hz
    mutating func append(_ s: HealthSample)          // O(1), overwrites the oldest
    func ordered() -> [HealthSample]                  // oldest → newest
    func suffix(_ n: Int) -> ArraySlice<HealthSample>
}
```

**Memory budget.** 24 B × 600 = **14.4 KB** per camera. 16 cameras = **230 KB**; 64 cameras = **922 KB**.
A `[Date: Double]`-style design would be ~40× larger and would allocate on every sample; that is why
this is a packed struct in a pre-allocated array.

### 12.3 Sampling

- **One** repeating timer at 1 Hz for the whole app (`clock.timer(after: .seconds(1))`,
  re-armed), not one per camera. It walks the registered controllers and calls
  `healthSnapshot()` on each — a cheap actor hop that reads already-computed values.
- Sampling continues while a stream is `.paused`, `.reconnecting` or `.failed`, recording zeros with
  the correct `state` byte. This is what lets the sparkline show *gaps and outages* rather than
  silently compressing time, which is the whole diagnostic value.
- Latency estimate comes from VigilRTP (RTCP SR NTP mapping plus queue depth); `HealthMonitor` never
  computes it.
- `reconnectCount` is accumulated from `StreamEvent.reconnectScheduled`, not derived from samples.
- **History is not persisted.** It is a 10-minute diagnostic window, and writing it would add 1 Hz disk
  traffic for no user benefit. The diagnostics bundle captures it as CSV at export time (§13.4).
- On `deactivate()` (screens asleep with nothing recording) sampling stops and the ring is left
  intact, so waking shows the gap explicitly.

### 12.4 UI contract for sparklines

`VigilUI` reads `history(for:)` at most **once per second** and renders from the `[HealthSample]`
array directly — no re-mapping into a chart model, no `Date` objects, and no `@Observable` per sample.
The inspector's four sparklines (fps, kbps, loss, jitter) share one array read. A `Canvas`-based
renderer draws 600 points in under 0.4 ms, which is what keeps the inspector inside the 120 Hz budget.

---

## 13. Diagnostics — `StreamDoctor` and the bundle

### 13.1 Stream Doctor sequence

Stream Doctor answers "why won't this camera connect?" with a specific cause and a specific fix. It is
reachable from any `.failed` tile, from the Inspector, from the command palette, and from the
discovery flow's credential test.

```swift
public actor StreamDoctor {
    public init(dependencies: CoreDependencies, credentialStore: CredentialStore)

    /// Runs the full sequence, emitting each step as it completes so the UI fills in live.
    public func diagnose(camera: Camera) -> AsyncStream<DoctorProgress>
    /// Convenience that awaits the whole run.
    public func report(for camera: Camera) async -> DoctorReport
}

public struct DoctorProgress: Sendable {
    public var step: DoctorStep
    public var index: Int, total: Int
    public var outcome: DoctorOutcome
    public var elapsed: Duration
}

public enum DoctorStep: String, Sendable, Codable, CaseIterable {
    case networkPath          // 0. is there a network at all?
    case hostReachable       // 1. resolve + ICMP-free reachability via TCP
    case rtspPortOpen        // 2. TCP connect to rtspPort (554)
    case httpPortOpen        // 3. TCP connect to httpPort (80/443)
    case rtspOptions         // 4. RTSP OPTIONS, unauthenticated
    case credentialCheck     // 5. ISAPI /Security/userCheck with Digest
    case deviceIdentity      // 6. ISAPI /System/deviceInfo → model, firmware, vendor
    case rtspDescribe        // 7. DESCRIBE with Digest → SDP
    case sdpCodecCheck       // 8. is there a video track we can decode?
    case rtspSetupPlay       // 9. SETUP + PLAY
    case firstRTPPacket      // 10. first RTP within 4 s
    case firstKeyframe       // 11. first decodable keyframe within 6 s
    case decodeProbe         // 12. VideoToolbox accepts the format and decodes one frame
}

public enum DoctorOutcome: Sendable, Hashable {
    case pass(detail: String)
    case warn(detail: String, cause: DoctorCause)
    case fail(detail: String, cause: DoctorCause)
    case skipped(reason: String)
}

public struct DoctorReport: Sendable, Hashable {
    public var cameraID: CameraID
    public var startedAt: Date
    public var duration: Duration
    public var steps: [DoctorProgress]
    public var verdict: Verdict
    public var primaryCause: DoctorCause?
    public var sdpDump: String?              // captured for the bundle
    public var rtspTranscript: [String]      // request/response lines, Authorization redacted
    public var suggestedFixes: [DoctorFix]
    public enum Verdict: String, Sendable, Codable { case healthy, degraded, broken }
}

public struct DoctorFix: Sendable, Hashable {
    public var title: String                 // "Enter the camera's password"
    public var detail: String
    public var action: DoctorAction?          // deep-linked, one-tap where possible
}

public enum DoctorAction: Sendable, Hashable {
    case openCredentialSheet(CameraID)
    case setTransport(CameraID, RTSPTransportKind)
    case setRTSPPath(CameraID, String)
    case setChannel(CameraID, Int)
    case setPort(CameraID, rtsp: Int?, http: Int?)
    case enableSubstream(CameraID)
    case openSystemSettings(URL)             // Local Network privacy pane
    case openDeviceWebUI(URL)
    case reprobeCapabilities(CameraID)
    case exportDiagnostics
}
```

Execution rules: steps run **in order**, each with its own budget; a `fail` stops the sequence *unless*
the step is marked continuable (`httpPortOpen`, `credentialCheck`, `deviceIdentity` continue, because
RTSP can work without ISAPI). Total budget **25 s**. The whole run uses a *separate* transport and
does **not** disturb the live `StreamController` — Doctor never steals the session. Step budgets:
`networkPath` 0.2 s, port probes 2.0 s each, `rtspOptions` 3 s, `credentialCheck` 4 s,
`deviceIdentity` 4 s, `rtspDescribe` 5 s, `sdpCodecCheck` instant, `rtspSetupPlay` 5 s,
`firstRTPPacket` 4 s, `firstKeyframe` 6 s, `decodeProbe` 3 s.

### 13.2 Failure → cause → fix mapping

```swift
public enum DoctorCause: String, Sendable, Codable, CaseIterable {
    case noNetwork, localNetworkPermissionDenied, hostUnreachable, dnsFailure
    case rtspPortClosed, rtspPortFiltered, httpPortClosed, wrongPortGuess
    case notAnRTSPServer, rtspVersionUnsupported
    case wrongPassword, accountLocked, insufficientPrivilege, deviceNotActivated
    case notHikvision, wrongChannel, rtspPathWrong, describeRejected
    case noVideoTrack, unsupportedCodec, mjpegOnly, parameterSetsMissing
    case transportBlocked, multicastBlocked, udpBlocked
    case noMediaFlowing, noKeyframe, decodeUnsupported, decodeBudgetExhausted
    case deviceOverloaded, cameraRebooting, clockSkew
}
```

| Step that failed | Signal observed | `DoctorCause` | User-facing cause | Fix offered |
|---|---|---|---|---|
| `networkPath` | path unsatisfied | `noNetwork` | "Your Mac isn't on a network." | "Connect to Wi-Fi or Ethernet, then try again." |
| `hostReachable` | all TCP probes time out, but other hosts on the subnet answer | `hostUnreachable` | "The camera isn't answering at 192.168.1.64." | "Check that the camera has power and the same IP. Run Discovery to find its current address." → `reprobeCapabilities` |
| `hostReachable` | every probe fails immediately on first launch | `localNetworkPermissionDenied` | "macOS is blocking Vigil from reaching devices on your network." | "Allow Vigil in System Settings → Privacy & Security → Local Network." → `openSystemSettings` |
| `hostReachable` | DNS returns nothing | `dnsFailure` | "That hostname couldn't be found." | "Use the camera's IP address instead." |
| `rtspPortOpen` | `ECONNREFUSED` on 554, HTTP port open | `rtspPortClosed` | "The camera answers on port 80 but refuses port 554." | "RTSP may be disabled or on another port. Try 8554, or enable RTSP in the camera's web page." → `setPort`, `openDeviceWebUI` |
| `rtspPortOpen` | timeout on 554, HTTP open | `rtspPortFiltered` | "Something is blocking port 554." | "Check your firewall or VLAN rules between this Mac and the camera." |
| `httpPortOpen` | refused, RTSP open | `httpPortClosed` | "Streaming works, but the camera's control port is closed." | "PTZ, events and snapshots need port 80. Video will still work." (warn, continue) |
| `rtspOptions` | garbage / HTTP response on 554 | `notAnRTSPServer` | "Whatever is on port 554 isn't an RTSP camera." | "Double-check the address and port." |
| `rtspOptions` | `RTSP/2.0` or 505 | `rtspVersionUnsupported` | "This device speaks a version of RTSP Vigil doesn't." | "Please export diagnostics and send them to us." → `exportDiagnostics` |
| `credentialCheck` | 401 with a fresh nonce, twice | `wrongPassword` | "That username or password isn't right." | "Enter the camera's password again." → `openCredentialSheet` |
| `credentialCheck` | `lockStatus`/retry fields present | `accountLocked` | "The camera locked this account after too many failed sign-ins." | "Wait 30 minutes, or reboot the camera, then try again." |
| `credentialCheck` | 403 with valid credentials | `insufficientPrivilege` | "This account can't view live video." | "Use an account with Live View and Playback permissions." → `openDeviceWebUI` |
| `credentialCheck` | SADP said `Activated=false` | `deviceNotActivated` | "This camera hasn't been set up yet." | "Set an admin password to activate it." |
| `deviceIdentity` | non-Hikvision vendor, or ISAPI 404 | `notHikvision` | "This looks like a <vendor> device, not a Hikvision one." | "Vigil will use generic RTSP/ONVIF. PTZ and events may not work." (warn, continue) |
| `rtspDescribe` | 404 / 455 on every candidate path | `rtspPathWrong` | "The camera doesn't recognise this stream address." | "Try channel 1 or a different stream path." → `setRTSPPath`, `setChannel` |
| `rtspDescribe` | 404 only for this channel, channel 1 works | `wrongChannel` | "Channel 3 doesn't exist on this device." | "This device has 2 channels. Pick one of those." → `setChannel` |
| `rtspDescribe` | 5xx | `describeRejected` | "The camera refused to describe the stream." | "It may be busy or restarting. Try again in a moment." |
| `sdpCodecCheck` | no `m=video` | `noVideoTrack` | "The camera offered no video." | "Check that this channel has a video source." |
| `sdpCodecCheck` | codec not H.264/H.265/MJPEG | `unsupportedCodec` | "This stream uses <codec>, which Vigil can't decode." | "Set the camera's video codec to H.264 or H.265." → `openDeviceWebUI` |
| `sdpCodecCheck` | MJPEG only | `mjpegOnly` | "Only MJPEG is available." | "Vigil will show it, but H.264 uses far less network and power." (warn) |
| `sdpCodecCheck` | no `sprop-parameter-sets` | `parameterSetsMissing` | "The camera didn't send stream headers up front." | "Vigil will wait for them in the video. Playback may take a second longer." (warn, sets `sdpMissingParameterSets`) |
| `rtspSetupPlay` | 461 on every transport | `transportBlocked` | "The camera rejected every connection type." | "Switch to TCP." → `setTransport(.tcpInterleaved)` |
| `firstRTPPacket` | UDP: nothing; TCP: works | `udpBlocked` | "Video packets aren't getting through over UDP." | "Use TCP for this camera." → `setTransport(.tcpInterleaved)` |
| `firstRTPPacket` | multicast: nothing | `multicastBlocked` | "Multicast video is being blocked." | "Your network or macOS is blocking multicast. Use unicast." → `setTransport(.udpUnicast)` |
| `firstRTPPacket` | TCP, PLAY succeeded, no data | `noMediaFlowing` | "The camera accepted the request but sent no video." | "It may be at its connection limit. Close other viewers, or use the sub-stream." → `enableSubstream` |
| `firstKeyframe` | RTP flowing, no IDR in 6 s | `noKeyframe` | "Video is arriving but the first full frame is late." | "Lower the camera's I-frame interval (GOP) to 1–2 seconds." → `openDeviceWebUI` |
| `decodeProbe` | VideoToolbox rejects the format | `decodeUnsupported` | "This Mac can't hardware-decode this stream." | "Try H.264 instead of H.265, or a lower resolution." |
| `decodeProbe` | `budgetExhausted` | `decodeBudgetExhausted` | "Too many cameras are decoding at once." | "Close some tiles, or lower Max Concurrent Decodes." → `exportDiagnostics` |
| any | 503 / `deviceBusy` repeatedly | `deviceOverloaded` | "The camera is too busy to answer." | "Reduce the number of viewers, or use the sub-stream." |
| any | connection resets in a loop, uptime < 60 s | `cameraRebooting` | "The camera keeps restarting." | "Check its power supply — PoE undervoltage causes this." |
| `deviceIdentity` | device time off by > 60 s | `clockSkew` | "The camera's clock is 4 minutes off." | "Sync the camera's clock so events and recordings line up." |

Every `StreamError.Code` maps onto a row here; §17.9 enforces that.

### 13.3 Report presentation

The UI renders the step list as a checklist that fills in live (pass / warn / fail with the elapsed
time), then a single prominent **cause** sentence, then up to three **fixes** as buttons wired to
`DoctorAction`. The full transcript sits behind a "Show technical details" disclosure and is
copyable. Every report can be saved with **Export Diagnostics…**, which produces §13.4's bundle with
this report already inside.

### 13.4 Diagnostics bundle

**Packaging decision.** Foundation has no public zip API, `Compression` is outside our allowed
framework list, and shelling out to `/usr/bin/ditto` is unavailable under the App Sandbox. So the
builder produces **two** things and no third-party code:

1. a staging **folder** at the user's chosen location, revealed in Finder (Finder's own
   *Compress* is one right-click away, and most users will just drag the folder into an email); and
2. a single-file `Vigil-Diagnostics-<stamp>.vigildiag` archive written by our own ~180-line
   `TarWriter` — POSIX `ustar`, no compression, pure Foundation, `Data`-streamed so memory stays flat.

`TarWriter` is unit-tested by round-tripping against `/usr/bin/tar -tvf` in a macOS-only test. The
uncompressed archive is ~1.3× the folder size, which is irrelevant at the 25 MB budget below.

```swift
public actor DiagnosticsBundleBuilder {
    public init(configStore: ConfigStore, eventLog: EventLog, healthMonitor: HealthMonitor,
                coordinator: StreamCoordinator, dependencies: CoreDependencies)
    public func build(destination: URL,
                      includeCameras: Set<CameraID>? = nil,
                      doctorReports: [DoctorReport] = []) async throws -> URL
}
```

Contents:

```
Vigil-Diagnostics-20260726-142530/
├── README.txt                       what this is, what was redacted, how to send it
├── manifest.json                    bundle version, app version/build, generatedAt, file list + sizes
├── system.txt                       macOS version, hardware model, chip, core count, RAM,
│                                    thermal state, low-power mode, locale, display list with
│                                    scale factors and refresh rates, free disk space
├── app.txt                          Vigil version/build, uptime, sandboxed?, entitlements present,
│                                    launch arguments, decode budget + max sessions, plan summary
├── library.redacted.json            full library.json with the redaction rules of §13.5 applied
├── settings.json                    AppSettings verbatim (contains no secrets by construction)
├── events.redacted.json             last 500 events, `deviceTimeRaw` kept, thumbnails excluded
├── logs/
│   ├── vigil-20260726.log           OSLogStore export, last 24 h, this process only, redacted
│   └── log-export.txt               how many entries, which subsystem/categories, any truncation
├── streams/<camera-slug>/
│   ├── camera.json                  the camera record, redacted
│   ├── capabilities.json            DeviceCapabilities incl. quirks and deniedEndpoints
│   ├── sdp.txt                      the last SDP received, verbatim
│   ├── rtsp-transcript.txt          request/response headers only; Authorization redacted;
│   │                                interleaved media bytes replaced by "[N bytes RTP ch0]"
│   ├── stats.csv                    HealthMonitor CSV (§13.6)
│   ├── doctor.json                  the DoctorReport, if one was run
│   └── isapi/
│       ├── deviceInfo.xml           redacted serial
│       ├── capabilities.xml         redacted
│       └── streaming-channels.xml
└── plan.json                        the current LivePlan with per-entry reasons
```

`OSLogStore` export:

```swift
let store = try OSLogStore(scope: .currentProcessIdentifier)   // .system needs an entitlement we lack
let since = store.position(date: Date().addingTimeInterval(-86_400))
let predicate = NSPredicate(format: "subsystem == %@", "com.vigil.app")
for entry in try store.getEntries(with: [], at: since, matching: predicate) {
    guard let log = entry as? OSLogEntryLog else { continue }
    out.append("\(fmt(log.date)) [\(log.level.name)] \(log.category): \(redact(log.composedMessage))")
}
```

The export is capped at **50 000 entries** and **20 MB**; truncation is recorded in
`log-export.txt`. Because `\(…, privacy: .private)` interpolations are redacted by the system in the
store, private values appear as `<private>` — belt and braces alongside §13.5.

Total bundle size budget: **< 25 MB** for a 16-camera setup. No video, no images, no thumbnails, no
recordings are ever included, and the builder refuses to include any file over 5 MB.

### 13.5 Redaction rules

Applied by `DiagnosticsRedactor`, a pure function, unit-tested with a corpus of realistic inputs
(§17.10).

| Item | Treatment | Example |
|---|---|---|
| Passwords, `kSecValueData` | never present anywhere by construction | — |
| `Authorization:` header value | `Digest username="admin", realm="…", response=<redacted>` | keeps the scheme and realm, which are diagnostically useful |
| `WWW-Authenticate` nonce | kept — it is public and useful | — |
| RTSP `Session:` | first 4 chars + `…` | `Session: 1A2B…` |
| Device serial (`serialNumber`, `DeviceSN`) | SHA-256, first 8 hex chars, prefixed | `serial:9f3a1c04` (stable across a bundle so records correlate) |
| MAC addresses | last 3 octets masked | `28:57:BE:xx:xx:xx` |
| Private IPv4 (RFC 1918), IPv6 ULA | **kept in full** — a LAN topology is the diagnostic content, and it is not sensitive | `192.168.1.64` |
| Public IP addresses | masked to `/24` | `203.0.113.xxx` |
| Hostnames outside `.local`/`.lan` | first label kept, rest masked | `cam1.****` |
| Camera names, group names, notes | **kept** — the user chose them and they aid support | — |
| File paths under the user's home | `~/` substituted for the home prefix | `~/Movies/Vigil/front-door/…` |
| Username in paths | replaced by `<user>` when it appears outside `~` | — |
| Keychain refs (`CredentialRef` UUIDs) | kept — they reveal nothing | — |
| Anything matching `(?i)(pass|pwd|secret|token|key)\s*[:=]\s*\S+` | value → `<redacted>` | catch-all safety net |

`README.txt` lists exactly what was redacted, so a user can decide whether to send the bundle. A
**Preview Contents** step in the UI shows the file tree and lets the user exclude any camera before
the bundle is written.

### 13.6 Stats CSV

```
t,state,fps,kbps,loss_permille,jitter_ms,latency_ms,dropped,queue,hwdecode,recording,keyframe
0,playing,25.0,4102.5,0,12,148,0,1,1,0,1
1,playing,25.1,4088.0,0,11,151,0,1,1,0,0
2,degraded,18.4,3011.2,34,96,412,3,3,1,0,0
```

One file per camera, one row per second, RFC 4180, `.` as the decimal separator regardless of locale
(`Locale(identifier: "en_US_POSIX")`). This format is directly plottable in Numbers, Excel and
`gnuplot`, which is the point.

---

## 14. Automation surface

### 14.1 App Intents

All intents live in VigilCore (they are domain operations, not views) and are surfaced by the `Vigil`
target's `AppShortcutsProvider`. Every intent is `@available(macOS 14.0, *)`, resolves against
`StreamCoordinator`, and is annotated for both Shortcuts and Spotlight.

```swift
public struct CameraEntity: AppEntity, Sendable, Identifiable {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation = "Camera"
    public static var defaultQuery = CameraEntityQuery()

    public var id: CameraID
    @Property(title: "Name")        public var name: String
    @Property(title: "Group")       public var groupName: String?
    @Property(title: "Status")      public var status: String
    @Property(title: "Host")        public var host: String
    @Property(title: "Resolution")  public var resolution: String?
    @Property(title: "Recording")   public var isRecording: Bool

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)",
                              subtitle: "\(groupName ?? host) · \(status)",
                              image: thumbnailData.map { .init(data: $0) })
    }
}

public struct CameraEntityQuery: EntityStringQuery, EnumerableEntityQuery {
    public func entities(for ids: [CameraID]) async throws -> [CameraEntity]
    /// Substring match on name, group and host, ranked name-prefix first.
    public func entities(matching string: String) async throws -> [CameraEntity]
    public func allEntities() async throws -> [CameraEntity]
    public func suggestedEntities() async throws -> [CameraEntity]   // enabled, by orderIndex, max 12
}
```

Peer entities: `CameraGroupEntity`, `LayoutEntity` (built-ins plus saved presets),
`PTZPresetEntity` (dependent on a `CameraEntity`, so Shortcuts offers only that camera's presets),
`RecordingClipEntity`, `EventEntity`.

| Intent | Title | Parameters | Returns | Notes |
|---|---|---|---|---|
| `ViewCameraIntent` | "View Camera" | `camera`, `fullscreen: Bool = false` | none | `openAppWhenRun = true`; brings the window forward and focuses the tile |
| `SetLayoutIntent` | "Set Layout" | `layout: LayoutEntity` | none | `openAppWhenRun = true` |
| `TakeSnapshotIntent` | "Take Snapshot" | `camera`, `format: SnapshotFormatAppEnum = .png`, `saveToFile: Bool = true`, `copyToClipboard: Bool = false` | `IntentFile` | works **without** opening the app: device-JPEG path when nothing is live |
| `SnapshotAllCamerasIntent` | "Snapshot All Cameras" | `format`, `group: CameraGroupEntity?` | `[IntentFile]` | bounded by `snapshotLimiter` |
| `StartRecordingIntent` | "Start Recording" | `camera`, `duration: Measurement<UnitDuration>?` | `RecordingClipEntity?` | a `duration` schedules an automatic stop; without it, records until stopped |
| `StopRecordingIntent` | "Stop Recording" | `camera: CameraEntity?` (nil = all) | `[RecordingClipEntity]` | — |
| `GoToPTZPresetIntent` | "Go to PTZ Preset" | `camera`, `preset: PTZPresetEntity` | none | fails clearly when the camera has no PTZ |
| `MovePTZIntent` | "Move Camera" | `camera`, `direction: PTZDirectionAppEnum`, `duration: Measurement<UnitDuration> = 0.5 s` | none | momentary move; safer than continuous for automation |
| `SetAudioIntent` | "Set Camera Audio" | `camera`, `state: EnableDisableAppEnum` | none | — |
| `GetCameraStatusIntent` | "Get Camera Status" | `camera` | `CameraStatusResult` (state, fps, kbps, loss, uptime, grade, isRecording) | read-only; runs in the background |
| `ListCamerasIntent` | "Find Cameras" | `group?`, `onlyOffline: Bool = false` | `[CameraEntity]` | the Shortcuts "Find" verb |
| `GetRecentEventsIntent` | "Get Recent Events" | `camera?`, `kind?`, `limit: Int = 10` | `[EventEntity]` | — |
| `ExportClipIntent` | "Export Clip" | `camera`, `start: Date`, `end: Date` | `IntentFile` | ISAPI search + RTSP playback passthrough export |
| `StartCycleModeIntent` | "Start Camera Cycling" | `group?`, `dwell: Measurement<UnitDuration> = 10 s` | none | `openAppWhenRun = true` |
| `SetRecordOnMotionIntent` | "Set Motion Recording" | `camera`, `state` | none | writes through `ConfigStore` |
| `RunStreamDoctorIntent` | "Diagnose Camera" | `camera` | `DoctorReportResult` (verdict, cause, fixes as strings) | genuinely useful in a "notify me if a camera breaks" automation |

```swift
public struct VigilShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ViewCameraIntent(), phrases: [
            "Show \(\.$camera) in \(.applicationName)",
            "Open \(\.$camera) in \(.applicationName)",
        ], shortTitle: "View Camera", systemImageName: "video")
        AppShortcut(intent: TakeSnapshotIntent(), phrases: [
            "Take a snapshot of \(\.$camera) with \(.applicationName)",
        ], shortTitle: "Snapshot", systemImageName: "camera")
        AppShortcut(intent: StartRecordingIntent(), phrases: [
            "Start recording \(\.$camera) in \(.applicationName)",
        ], shortTitle: "Record", systemImageName: "record.circle")
        AppShortcut(intent: SetLayoutIntent(), phrases: [
            "Set \(.applicationName) layout to \(\.$layout)",
        ], shortTitle: "Set Layout", systemImageName: "square.grid.2x2")
    }
}
```

Rules for every intent:

- **Background-capable where possible.** Only intents that must show something set
  `openAppWhenRun = true`. `TakeSnapshotIntent` and `GetCameraStatusIntent` work with the app closed,
  using the ISAPI paths — which is what makes them useful in automations.
- Errors are thrown as `IntentError` with a `localizedStringResource` message drawn from the same
  strings table as the UI, so Shortcuts shows the same wording the app does.
- Write actions (`StartRecording`, `MovePTZ`, `SetRecordOnMotion`, `GoToPTZPreset`) are gated by
  `AppSettings.allowURLSchemeWriteActions`? **No** — Shortcuts is an explicit user action with its own
  permission model, so intents are always allowed. That gate applies only to URL scheme (§14.3).
- `IntentDescription` includes `resultValueName` and a `searchKeywords` list for Spotlight.
- Intent donation: `ViewCameraIntent` is donated on each camera focus so Spotlight learns the user's
  habits.

### 14.2 Menu-bar and Focus integration

`GetCameraStatusIntent` doubles as the data source for a `WidgetKit`-free menu-bar summary. The
`vigil.menubar.badge` count comes from `LiveViewState.unreadEventCount`; no separate plumbing.

### 14.3 URL scheme

Registered as `vigil` (`CFBundleURLTypes` in Info.plist, owned by `ARCHITECTURE.md`).

**Grammar** (ABNF-ish; all components percent-decoded, all matching case-insensitive except UUIDs):

```
url        = "vigil://" action [ "/" path ] [ "?" query ]
action     = "camera" / "layout" / "playback" / "event" / "clip" / "snapshot"
           / "record" / "ptz" / "audio" / "cycle" / "palette" / "settings"
           / "discover" / "import" / "doctor" / "wall"
cam-ref    = uuid / slug / name          ; resolution order below
```

| URL | Effect | Write action? |
|---|---|---|
| `vigil://camera/<cam-ref>` | focus that camera in the current layout, bringing the window forward | no |
| `vigil://camera/<cam-ref>?fullscreen=1` | open it fullscreen | no |
| `vigil://camera/<cam-ref>?quality=main\|sub\|auto` | pin the quality | **yes** |
| `vigil://layout/<name>` or `vigil://layout/2x2` | switch layout; accepts built-in mode names `1`, `2x2`, `3x3`, `4x4`, `1+5`, `1+7`, `2+8` | no |
| `vigil://playback/<cam-ref>?t=<ISO8601>&span=<sec>` | open Playback at that instant | no |
| `vigil://event/<uuid>` | select that event in the feed and jump to its moment | no |
| `vigil://clip/<uuid>` | open that clip | no |
| `vigil://snapshot?camera=<cam-ref>&format=png\|jpeg\|heic&dest=file\|clipboard\|quicklook` | take a snapshot | **yes** |
| `vigil://record/start?camera=<cam-ref>&duration=<sec>` | start recording | **yes** |
| `vigil://record/stop?camera=<cam-ref>` (`camera=all`) | stop recording | **yes** |
| `vigil://ptz/<cam-ref>/preset/<n>` | go to preset *n* (1…255) | **yes** |
| `vigil://ptz/<cam-ref>/move?dir=up\|down\|left\|right\|in\|out&ms=<50…5000>` | momentary move | **yes** |
| `vigil://audio/<cam-ref>?state=on\|off\|toggle` | audio control | **yes** |
| `vigil://cycle?group=<name>&dwell=<sec>&state=start\|stop` | camera cycling | no |
| `vigil://palette?q=<text>` | open the command palette, pre-filled | no |
| `vigil://settings/<pane>` — `general\|streams\|recording\|notifications\|shortcuts\|advanced\|about` | open Settings | no |
| `vigil://discover` | open the Discovery sheet and start a scan | no |
| `vigil://doctor/<cam-ref>` | run Stream Doctor | no |
| `vigil://wall?display=<uuid>&layout=<name>` | open the video wall on a display | no |
| `vigil://import?url=<percent-encoded file URL>` | open the CSV/JSON import sheet pre-loaded | no (always confirmed) |

**Security model.** This is the one place an outside party (a web page, a Mail link) can drive the app,
so:

1. Read/navigate actions always run.
2. **Write actions require `AppSettings.allowURLSchemeWriteActions` (default `false`).** When
   disabled, the app shows a one-time sheet naming the exact action and offering
   *Allow Once* / *Always Allow* / *Deny*. This is the difference between a convenience and a
   remote-control vulnerability.
3. `vigil://import` **always** confirms, regardless of the setting, and never auto-applies.
4. Rate limit: **10** URLs per 10 seconds; the excess is dropped with a `.notice` log.
5. Unknown actions, malformed UUIDs and out-of-range parameters produce a single toast
   *"Vigil didn't understand that link."* and a `.debug` log — never a crash, never a partial action.
6. No URL can read data out (there is no callback/return-URL mechanism) or change credentials.

**Camera reference resolution**, in order, first unique match wins:
(1) exact `CameraID` UUID; (2) exact case-insensitive `name`; (3) exact `slug`; (4) unique
case-insensitive prefix of `name`; (5) exact `host`. Ambiguity opens a small disambiguation picker
rather than guessing. No match → the "didn't understand" toast naming the reference.

```swift
public enum DeepLink: Sendable, Hashable {
    case focusCamera(CameraRef, fullscreen: Bool, quality: StreamQuality?)
    case setLayout(LayoutRef)
    case playback(CameraRef, at: Date, span: Double?)
    case showEvent(EventID)
    case showClip(ClipID)
    case snapshot(CameraRef, SnapshotFormat, Set<SnapshotDestination>)
    case startRecording(CameraRef, duration: Double?)
    case stopRecording(CameraRef?)
    case ptzPreset(CameraRef, Int)
    case ptzMove(CameraRef, PTZDirection, milliseconds: Int)
    case audio(CameraRef, AudioAction)
    case cycle(group: String?, dwell: Double?, start: Bool)
    case palette(query: String?)
    case settings(SettingsPane)
    case discover
    case doctor(CameraRef)
    case videoWall(displayUUID: String?, LayoutRef?)
    case importConfiguration(URL)

    public var isWriteAction: Bool { get }
    /// The single parse entry point. Total function: never throws, never traps.
    public static func parse(_ url: URL) -> Result<DeepLink, DeepLinkError>
}
```

`DeepLink.parse` is pure and is the subject of a large table-driven test (§17.11) including hostile
inputs: `vigil://record/start?camera=../../etc/passwd`, 4 KB names, non-UTF-8 percent escapes,
`camera=all` where it is not allowed, negative and NaN numbers, nested URL encoding.

### 14.4 AppleScript

App Intents already deliver Shortcuts and `shortcuts run` from the command line, so AppleScript is a
**thin, deliberately small** surface for users with existing AppleScript workflows — not a second full
API.

`Vigil.sdef` (in the `Vigil` target's resources; `NSAppleScriptEnabled = true` and
`OSAScriptingDefinition = Vigil.sdef` in Info.plist) defines one suite:

| Element / command | AppleScript | Maps to |
|---|---|---|
| `cameras` element of `application` | `cameras`, `camera "Front Door"`, `camera id "…"` | `Library.cameras` |
| camera properties | `name`, `id`, `host`, `enabled`, `status`, `recording`, `group` | read-only except `enabled` |
| `layouts` element | `layouts`, `current layout` | `Library.layouts` |
| `snapshot` | `snapshot camera "Front Door" saving to file "…" as «constant ****png »` | `SnapshotService` |
| `start recording` | `start recording camera "Front Door" for 60` | `StreamCoordinator.startRecording` |
| `stop recording` | `stop recording camera "Front Door"` | — |
| `set layout` | `set layout to layout "2x2"` | — |
| `goto preset` | `goto preset 3 of camera "Gate"` | PTZ |
| `diagnose` | `diagnose camera "Gate"` → verdict text | `StreamDoctor` |

Implementation: `NSScriptCommand` subclasses in the `Vigil` target whose `performDefaultImplementation`
hops to `@MainActor`, calls the coordinator, and — for commands that must return a value — uses
`suspendExecution()` / `resumeExecution(withResult:)` so a slow ISAPI snapshot does not block the
Apple Event timeout. VigilCore itself contains no AppleScript code; it exposes the async operations the
commands call. `cameras` and `layouts` are exposed via `NSApplication`'s scripting container using
`valueForKey`-style accessors backed by `LiveViewState`.

Priority: P1. If it slips, the intents plus URL scheme cover every automation story.

### 14.5 Configuration import and export

```swift
public enum ImportStrategy: Sendable, Hashable {
    case merge          // match on (host, channel) then on name; update matches, add the rest
    case addOnly        // never modify existing records
    case replace        // dangerous; requires an extra typed confirmation in the UI
}

public struct ImportReport: Sendable, Hashable {
    public var added: [CameraID], updated: [CameraID], skipped: [String]
    public var errors: [ImportError]                 // row number + reason, all rows reported
    public var credentialsNeeded: [CameraID]         // imported without a password
    public var groupsCreated: [GroupID]
}
```

| Format | Direction | Contents |
|---|---|---|
| **JSON** (`.vigilcameras`) | both | `{ "schemaVersion": 3, "cameras": [...], "groups": [...], "layouts": [...] }` — a subset of `library.json`, **never** credentials |
| **CSV** | both | header `name,host,httpPort,rtspPort,useTLS,channel,transport,streamProfile,group,colorTag,enabled,username,notes` — `username` is exported but **`password` is never exported**; on import a `password` column *is* accepted (many users build these from a spreadsheet) and each value is moved straight into the Keychain and never retained in memory beyond the import |
| **Encrypted** (`.vigilbackup`) | both | the full JSON **plus** credentials, encrypted with `CryptoKit.AES.GCM` (256-bit) under a key derived from the user's passphrase by PBKDF2-HMAC-SHA256, 600 000 iterations, 16-byte random salt, 12-byte nonce. CryptoKit has no PBKDF2, so it is implemented in ~25 lines over `CryptoKit.HMAC<SHA256>` and unit-tested against RFC 6070 vectors — no `CommonCrypto`, no external dependency. Header: `VIGILBK1` \| salt \| iterations (UInt32 BE) \| nonce \| ciphertext \| tag |

CSV parsing is strict about the header and lenient about the rows: quoted fields with embedded commas
and newlines, BOM tolerated, CRLF or LF, `TRUE/true/1/yes` all parse as true, unknown columns ignored
with a warning, and **every** bad row reported by number rather than aborting the file. Export writes
CRLF with a UTF-8 BOM so Excel opens it correctly without an import wizard.

Import is transactional: the whole `Library` mutation is applied in one `ConfigStore.mutate`, so a
failure part-way leaves nothing changed. Credentials are written to the Keychain **after** the library
mutation commits, and any Keychain failure is reported per camera in
`ImportReport.credentialsNeeded` rather than rolling back the cameras — a camera without a password is
recoverable; a lost import is annoying.
