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

    /// Dedupe/coalesce key. §10.3
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
    public func upsert(_ event: EventRecord)                       // coalescing (§10.3)
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
