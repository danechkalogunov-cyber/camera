# Vigil — System Architecture

**Status:** Normative. This document is the contract between all Vigil modules.
**Audience:** implementation agents and human engineers writing Swift in this repository.
**Supersedes:** nothing. **Superseded by:** nothing.

## 0. How to read this document

* **MUST / MUST NOT / MUST ALWAYS** — a build-breaking rule. Code review rejects violations.
* **SHOULD** — a strong default; deviating requires a `// RATIONALE:` comment naming this section.
* **MAY** — genuinely optional.

Where this document and a module spec (`docs/spec-*.md`) disagree, **this document wins** for anything
cross-cutting: target names, dependency edges, type ownership, isolation domains, error taxonomy,
logging, persistence layout, build and style rules. Module specs win for anything internal to their own
module: wire formats, byte offsets, parse algorithms, private types.

Sibling documents, all in `docs/`:

| File | Owns |
|---|---|
| `ARCHITECTURE.md` (this) | targets, concurrency, data flow, errors, build, style |
| `FEATURES.md` | scope, priorities, acceptance criteria, performance budget |
| `DESIGN.md` | design system, colour, type, motion tokens |
| `UX.md` | information architecture, screens, shortcuts, copy |
| `spec-rtsp.md` | `VigilRTSP` internals |
| `spec-rtp.md` | `VigilRTP` internals |
| `spec-bitstream.md` | `VigilBitstream` internals |
| `spec-isapi.md` | `VigilISAPI` internals |
| `spec-discovery.md` | `VigilDiscovery` internals |
| `spec-video-pipeline.md` | `VigilVideo` internals |
| `spec-render.md` | `VigilRender` internals |
| `spec-core.md` | `VigilCore` internals |

---

## 1. System overview

Vigil is a single-process, sandboxed macOS 14+ SwiftUI application that speaks RTSP/RTP to Hikvision
IP cameras and NVRs on the local network, decodes H.264/H.265/MJPEG with VideoToolbox, and presents
frames through Metal or `AVSampleBufferDisplayLayer`. There is **no server component, no cloud, no
third-party code**. Every byte on the wire is produced and consumed by Swift we wrote.

The architecture is organised around one idea:

> **Protocol logic is a pure function of bytes and time.**

Everything that parses, decides, or computes lives in Foundation-only targets driven by *injected*
bytes and an *injected* clock. Sockets, decoders, layers and views are thin adapters that move bytes
and pixels between the pure core and the operating system. This is what lets us run the entire RTSP →
RTP → depacketize → `EncodedFrame` pipeline in a Linux CI container against a synthetic camera, in
milliseconds, with deterministic fault injection — and it is why the risky parts of this app are the
parts that are cheapest to test.

```
                     ┌───────────────────────── macOS-only ─────────────────────────┐
                     │                                                              │
 ┌──────────┐        │  ┌───────────────┐   ┌────────────┐   ┌───────────────────┐   │
 │  Camera  │  TCP   │  │ VigilTransport│   │ VigilVideo │   │   VigilRender     │   │
 │   / NVR  │◄──────►│  │  NWConnection │   │VideoToolbox│   │ Metal / AVSBDL    │   │
 └──────────┘  UDP   │  └───────┬───────┘   └─────┬──────┘   └─────────┬─────────┘   │
                     │          │                 │                    │             │
                     │          │  ┌──────────────┴────────┐           │             │
                     │          │  │      VigilCore        │◄──────────┘             │
                     │          │  │ StreamController(s)   │      DecodedFrame        │
                     │          │  │ StreamCoordinator     │                          │
                     │          │  │ ConfigStore/Keychain  │───────► VigilUI ──► Vigil │
                     │          │  └──────────┬────────────┘                          │
                     └──────────┼─────────────┼───────────────────────────────────────┘
                                │             │
      ┌─────────────────────────┼─────────────┼─────────────────────────┐
      │            Foundation-only, Linux-testable                      │
      │  ┌───────────┐  ┌──────────┐  ┌──────────────┐  ┌────────────┐  │
      │  │ VigilRTSP │  │ VigilRTP │  │VigilBitstream│  │ VigilISAPI │  │
      │  └─────┬─────┘  └────┬─────┘  └──────┬───────┘  └─────┬──────┘  │
      │        │             │               │                │         │
      │        │        ┌────┴───────────┐   │                │         │
      │        └────────┤ VigilProtocols ├───┴────────────────┘         │
      │                 └────┬───────────┘                              │
      │                      │            ┌────────────────┐            │
      │                      └────────────┤ VigilDiscovery │            │
      │                                   └────────────────┘            │
      └─────────────────────────────────────────────────────────────────┘
```

### 1.1 Non-negotiable constraints (restated so they are testable)

| # | Constraint | How it is enforced |
|---|---|---|
| C1 | Zero external dependencies | `Package.swift` has an empty `dependencies:` array. `Scripts/lint.sh` greps for `.package(` and fails if found. |
| C2 | Swift 6 language mode, complete concurrency checking | `swiftLanguageModes: [.v6]`; CI builds with `-warnings-as-errors`. |
| C3 | macOS 14.0 deployment target | `platforms: [.macOS(.v14)]`; `LSMinimumSystemVersion = 14.0`. |
| C4 | Pure targets compile on Linux Swift 6.1 | GitHub Actions job `linux` runs `swift build --product VigilPure` in `swift:6.1-noble`. |
| C5 | Pure targets never import CoreMedia/AppKit/etc. | `Scripts/lint.sh` runs an import allow-list check per target (§4.5). |
| C6 | No force-unwrap in shipping code | `swift format lint --strict` plus a lint grep (§14.6). |
| C7 | < 250 ms glass-to-glass on LAN | `Scripts/bench.sh` + `spec-video-pipeline.md` harness. |

---

## 2. The module graph

### 2.1 Targets

Names are **fixed**. Do not invent, rename, split or merge targets.

| Target | Kind | Layer | Frameworks it may import | Linux |
|---|---|---|---|---|
| `VigilProtocols` | library | pure | `Foundation` | ✅ builds & tests |
| `VigilBitstream` | library | pure | `Foundation` | ✅ |
| `VigilRTSP` | library | pure | `Foundation` | ✅ |
| `VigilRTP` | library | pure | `Foundation` | ✅ |
| `VigilISAPI` | library | pure | `Foundation`, `FoundationNetworking` (Linux shim) | ✅ |
| `VigilDiscovery` | library | pure | `Foundation` | ✅ |
| `VigilTestKit` | library | pure | `Foundation` | ✅ |
| `VigilTransport` | library | macOS | `Network`, `Security`, `OSLog`, `Foundation` | ⬜ empty module |
| `VigilVideo` | library | macOS | `VideoToolbox`, `CoreMedia`, `CoreVideo`, `AVFoundation`, `AudioToolbox`, `Accelerate`, `OSLog` | ⬜ |
| `VigilRender` | library | macOS | `Metal`, `MetalKit`, `CoreImage`, `AVFoundation`, `AppKit`, `SwiftUI`, `QuartzCore` | ⬜ |
| `VigilCore` | library | macOS | `Foundation`, `Security`, `AVFoundation`, `Network`, `Observation`, `UserNotifications`, `AppIntents`, `OSLog` | ⬜ |
| `VigilUI` | library | macOS | `SwiftUI`, `AppKit`, `Observation`, `UniformTypeIdentifiers`, `Charts`¹ | ⬜ |
| `Vigil` | executable | macOS | `SwiftUI`, `AppKit`, `AppIntents`, `OSLog` | ⬜ stub `main` |

¹ `Charts` (Swift Charts) is an Apple system framework and is permitted. It is **only** used for
history graphs in the inspector, never on the video hot path.

### 2.2 Dependency edges and why each exists

Read `A → B` as "A depends on B". The graph is a DAG; there are no cycles anywhere.

| Edge | Why it exists | What crosses it |
|---|---|---|
| `VigilBitstream → VigilProtocols` | needs `BitReader`, `ByteReader`, `VigilError`, `LoggerProtocol` | `BitReader`, `ParameterSets`, `VideoCodec` |
| `VigilRTSP → VigilProtocols` | needs `ByteReader`, `MD5` (Digest auth has no CryptoKit on Linux), `MonotonicClock`, errors, logging | `MD5.digest`, `MonotonicClock`, `Credential`, `VigilError` |
| `VigilRTP → VigilProtocols` | needs `ByteReader`, `MediaTimestamp`, `EncodedFrame`, `VideoCodec`, `AudioCodec`, logging | `EncodedFrame`, `MediaTimestamp`, `StreamStatistics` |
| `VigilRTP → VigilBitstream` | AU-boundary detection needs `first_mb_in_slice` / `first_slice_segment_in_pic_flag`; the depacketizer must recognise SPS/PPS/VPS NAL types and IRAP ranges; **the marker bit on Hikvision firmware is unreliable, so slice-header inspection is mandatory** | `NALType`, `H264SliceHeaderProbe`, `H265SliceHeaderProbe`, `ParameterSets` |
| `VigilISAPI → VigilProtocols` | errors, logging, `Credential`, `XMLCursor` host types, `MD5` for HTTP Digest | `Credential`, `VigilError`, `MD5` |
| `VigilDiscovery → VigilProtocols` | errors, logging, `ByteWriter`, deterministic `RandomSource` for UUID probes | `VigilError`, `RandomSource` |
| `VigilTestKit → VigilProtocols, VigilRTSP, VigilRTP, VigilBitstream` | the synthetic server must speak the real message model and emit bytes the real parsers accept | `RTSPRequest/Response`, `RTPPacket`, `ParameterSets` |
| `VigilTransport → VigilProtocols, VigilRTSP, VigilDiscovery` | wires `RTSPSessionMachine` to `NWConnection`; wires SADP/WS-Discovery codecs to real multicast sockets | `Data`, `RTSPAction`, `RTSPEvent`, `DiscoveryProbe` |
| `VigilVideo → VigilProtocols, VigilBitstream` | converts `EncodedFrame` + `ParameterSets` into `CMSampleBuffer`; needs `avcC`/`hvcC` builders and SPS-derived geometry | `EncodedFrame`, `ParameterSets`, `VideoGeometry` |
| `VigilRender → VigilProtocols, VigilVideo` | consumes `DecodedFrame`; implements the `VideoSink` protocol declared in `VigilVideo` | `DecodedFrame`, `VideoSink`, `CVPixelBuffer` |
| `VigilCore → VigilProtocols, VigilRTSP, VigilRTP, VigilBitstream, VigilISAPI, VigilDiscovery, VigilTransport, VigilVideo` | `StreamController` owns one instance of each stage of the pipeline | everything on the data-flow path |
| `VigilUI → VigilProtocols, VigilCore, VigilRender` | views observe `VigilCore` models and embed `VigilRender` views | `@Observable` view models, `VideoTileView` |
| `Vigil → VigilUI, VigilCore` | `App`, scenes, menus, App Intents registration | scenes |

### 2.3 Forbidden edges (anti-dependency rules)

These are as important as the edges that exist. A reviewer MUST reject any of these.

| Forbidden | Reason |
|---|---|
| `VigilRTSP → VigilRTP` | RTSP must be testable without any media handling, and the RTP demux decision (which interleaved channel maps to which track) belongs to the caller. RTSP emits `InterleavedFrame(channel:payload:)`; `VigilCore` routes it. |
| `VigilRTP → VigilRTSP` | the depacketizer must be usable for UDP transport, recorded-file replay and unit fixtures with no session at all. |
| any pure target → `CoreMedia`, `CoreVideo`, `AVFoundation`, `VideoToolbox`, `AppKit`, `SwiftUI`, `Metal`, `Security`, `Network`, `OSLog` | breaks C4/C5. Use `MediaTimestamp` not `CMTime`; `EncodedFrame` not `CMSampleBuffer`; `LoggerProtocol` not `Logger`; `Credential` not `SecItem`. |
| `VigilCore → VigilRender` | domain must not know about views or Metal. Snapshot-of-displayed-frame is obtained through `protocol SnapshotSource` **declared in `VigilVideo`** and implemented by `VigilRender`. |
| `VigilCore → VigilUI` | ditto, inverted. |
| `VigilVideo → VigilRTP` | `EncodedFrame` lives in `VigilProtocols` precisely so the decoder does not depend on the depacketizer. |
| `VigilRender → VigilCore` | render is a leaf presentation module; it receives frames and emits gesture intents via closures/`AsyncStream`, it does not reach into the domain. |
| `VigilUI → VigilTransport`, `VigilUI → VigilRTSP`, `VigilUI → VigilRTP` | UI talks only to `VigilCore`. If the UI needs a protocol fact, `VigilCore` re-exports it as a domain type. |
| anything → `VigilTestKit` outside `Tests/` | test-only code MUST NOT ship. `Scripts/lint.sh` asserts `VigilTestKit` appears only in test-target dependency lists. |

### 2.4 Type ownership registry (conflict arbitration)

Eleven specs are authored in parallel. To prevent duplicate or divergent definitions, the following
table is **authoritative**: the listed target is the *only* place the type is declared. Other specs may
describe the type's semantics in detail, but the declaration lives here and any spec that contradicts
this table is wrong.

| Type | Declared in | Notes |
|---|---|---|
| `MediaTimestamp` | `VigilProtocols` | `struct { var value: Int64; var timescale: Int32 }`. `spec-rtp.md` defines its arithmetic and wraparound rules; the declaration is here. |
| `EncodedFrame` | `VigilProtocols` | 4-byte-length-prefixed NALs. `spec-rtp.md` is normative for how it is populated. |
| `ParameterSets` | `VigilProtocols` | `{ vps: [Data], sps: [Data], pps: [Data], codec: VideoCodec }` |
| `VideoCodec`, `AudioCodec` | `VigilProtocols` | `enum VideoCodec: String, Sendable { case h264, h265, mjpeg }` |
| `StreamStatistics` | `VigilProtocols` | `spec-rtp.md` owns the update algebra (§8.4 here fixes the shape). |
| `VigilError` + all domain error enums | `VigilProtocols` | §7 |
| `LoggerProtocol`, `LogLevel`, `LogCategory`, `LogEvent` | `VigilProtocols` | §8 |
| `MonotonicClock`, `WallClock`, `RandomSource` | `VigilProtocols` | §5.10 |
| `ByteReader`, `ByteWriter`, `BitReader`, `BitWriter` | `VigilProtocols` | `BitWriter` exists for `VigilTestKit` and record building |
| `MD5` | `VigilProtocols` | §14.9; used by `VigilRTSP` and `VigilISAPI` |
| `Credential` | `VigilProtocols` | value type only; storage is `VigilCore.CredentialStore` |
| `HTTPTransporting` | `VigilProtocols` | injection seam so `VigilISAPI` tests never touch the network |
| `RTSPRequest`, `RTSPResponse`, `SDPDescription`, `RTSPSessionMachine`, `InterleavedFrame`, `DigestChallenge` | `VigilRTSP` | |
| `RTPPacket`, `RTCPPacket`, `Depacketizer`, `JitterBuffer` | `VigilRTP` | |
| `NALType`, `H264SPS`, `H265SPS`, `VideoGeometry`, `AVCDecoderConfigurationRecord`, `HEVCDecoderConfigurationRecord` | `VigilBitstream` | |
| `DiscoveredDevice`, `SADPCodec`, `WSDiscoveryCodec`, `IPv4CIDR` | `VigilDiscovery` | |
| `DeviceInfo`, `ISAPIClient`, `XMLCursor`, `PTZData`, `EventNotificationAlert` | `VigilISAPI` | |
| `DecodedFrame`, `VideoSink`, `SnapshotSource`, `DecodePipeline`, `DecodeBudget` | `VigilVideo` | |
| `Camera`, `CameraGroup`, `Layout`, `StreamController`, `StreamCoordinator`, `ConfigStore`, `CredentialStore`, `StreamEvent`, `EventRecord` | `VigilCore` | |
| `VTheme`, all `V*` components | `VigilUI` | |

**Rule:** if you need a type that two modules must both see and it is not in this table, it goes in
`VigilProtocols`, and you add a row to this table in the same commit.

---

## 3. `Package.swift` — complete and final

This is the file. Copy it verbatim into the repository root.

```swift
// swift-tools-version:6.0
//
// Vigil — native macOS viewer for Hikvision IP cameras and NVRs.
//
// ZERO EXTERNAL DEPENDENCIES BY DESIGN. `dependencies:` is empty and must stay empty.
// Adding an SPM package breaks constraint C1 in docs/ARCHITECTURE.md §1.1 and CI will fail.
//
// Two build worlds:
//   macOS  — everything builds. `swift build` / Xcode / Scripts/build-app.sh.
//   Linux  — only the Foundation-only targets are meaningful. `swift build --product VigilPure`
//            builds them; a full `swift build` also succeeds because every file in a macOS-only
//            target is wrapped in `#if os(macOS)` (see docs/ARCHITECTURE.md §4).

import PackageDescription

// MARK: - Build settings

/// Applied to every target in the package.
///
/// * `ExistentialAny` forces the `any P` spelling so existential boxing stays visible at call sites,
///   which matters on the frame path.
/// * `swiftLanguageModes: [.v6]` is set package-wide below and turns on *complete* concurrency
///   checking; we never downgrade a target to `.v5` to silence a data-race diagnostic.
let common: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
]

/// Pure targets additionally get a compile-time marker so shared helpers can assert purity.
let pure: [SwiftSetting] = common + [
    .define("VIGIL_PURE"),
]

/// macOS-only targets. `VIGIL_APPLE` is defined only when actually compiling for an Apple platform,
/// so the `#if os(macOS)` guards and the define always agree.
let apple: [SwiftSetting] = common + [
    .define("VIGIL_APPLE", .when(platforms: [.macOS])),
]

// MARK: - Package

let package = Package(
    name: "Vigil",
    platforms: [
        // Ignored on Linux; constrains the Apple deployment target only.
        .macOS(.v14),
    ],
    products: [
        // The shipping app binary. Assembled into Vigil.app by Scripts/build-app.sh.
        .executable(name: "Vigil", targets: ["Vigil"]),

        // The Linux/CI surface: exactly the Foundation-only targets. `swift build --product VigilPure`
        // is the single command Linux CI runs, and it is the mechanism that keeps the pure layer pure —
        // if someone adds `import CoreMedia` to VigilRTP, this product stops building.
        .library(
            name: "VigilPure",
            targets: [
                "VigilProtocols",
                "VigilBitstream",
                "VigilRTSP",
                "VigilRTP",
                "VigilISAPI",
                "VigilDiscovery",
            ]
        ),

        // Test-only fixtures. Exposed as a product so `swift build --product VigilTestKit` can be
        // sanity-checked on Linux independently of the test runner.
        .library(name: "VigilTestKit", targets: ["VigilTestKit"]),

        // Convenience for embedding the app layer in an Xcode host project (see project.yml).
        .library(name: "VigilApp", targets: ["VigilUI", "VigilCore", "VigilRender"]),
    ],
    dependencies: [
        // INTENTIONALLY EMPTY. See the header comment.
    ],
    targets: [

        // MARK: Pure — Foundation only, Linux-testable

        .target(
            name: "VigilProtocols",
            path: "Sources/VigilProtocols",
            swiftSettings: pure
        ),
        .target(
            name: "VigilBitstream",
            dependencies: ["VigilProtocols"],
            path: "Sources/VigilBitstream",
            swiftSettings: pure
        ),
        .target(
            name: "VigilRTSP",
            dependencies: ["VigilProtocols"],
            path: "Sources/VigilRTSP",
            swiftSettings: pure
        ),
        .target(
            name: "VigilRTP",
            dependencies: ["VigilProtocols", "VigilBitstream"],
            path: "Sources/VigilRTP",
            swiftSettings: pure
        ),
        .target(
            name: "VigilISAPI",
            dependencies: ["VigilProtocols"],
            path: "Sources/VigilISAPI",
            swiftSettings: pure
        ),
        .target(
            name: "VigilDiscovery",
            dependencies: ["VigilProtocols"],
            path: "Sources/VigilDiscovery",
            swiftSettings: pure
        ),

        // MARK: Test fixtures — pure, shipped to no product the app links

        .target(
            name: "VigilTestKit",
            dependencies: ["VigilProtocols", "VigilRTSP", "VigilRTP", "VigilBitstream"],
            path: "Sources/VigilTestKit",
            swiftSettings: pure
        ),

        // MARK: macOS-only

        .target(
            name: "VigilTransport",
            dependencies: ["VigilProtocols", "VigilRTSP", "VigilDiscovery"],
            path: "Sources/VigilTransport",
            swiftSettings: apple
        ),
        .target(
            name: "VigilVideo",
            dependencies: ["VigilProtocols", "VigilBitstream"],
            path: "Sources/VigilVideo",
            swiftSettings: apple
        ),
        .target(
            name: "VigilRender",
            dependencies: ["VigilProtocols", "VigilVideo"],
            path: "Sources/VigilRender",
            resources: [
                // Metal shaders are compiled by SwiftPM into default.metallib inside the bundle.
                .process("Shaders"),
            ],
            swiftSettings: apple
        ),
        .target(
            name: "VigilCore",
            dependencies: [
                "VigilProtocols",
                "VigilRTSP",
                "VigilRTP",
                "VigilBitstream",
                "VigilISAPI",
                "VigilDiscovery",
                "VigilTransport",
                "VigilVideo",
            ],
            path: "Sources/VigilCore",
            swiftSettings: apple
        ),
        .target(
            name: "VigilUI",
            dependencies: ["VigilProtocols", "VigilCore", "VigilRender"],
            path: "Sources/VigilUI",
            resources: [
                .process("Resources"),        // Assets.xcassets, custom SF Symbols
                .process("Localizations"),    // en.lproj / ru.lproj .strings + .stringsdict
            ],
            swiftSettings: apple
        ),
        .executableTarget(
            name: "Vigil",
            dependencies: ["VigilUI", "VigilCore"],
            path: "Sources/Vigil",
            swiftSettings: apple
        ),

        // MARK: Tests — pure (run on Linux AND macOS)

        .testTarget(
            name: "VigilProtocolsTests",
            dependencies: ["VigilProtocols", "VigilTestKit"],
            path: "Tests/VigilProtocolsTests"
        ),
        .testTarget(
            name: "VigilBitstreamTests",
            dependencies: ["VigilBitstream", "VigilTestKit"],
            path: "Tests/VigilBitstreamTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "VigilRTSPTests",
            dependencies: ["VigilRTSP", "VigilTestKit"],
            path: "Tests/VigilRTSPTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "VigilRTPTests",
            dependencies: ["VigilRTP", "VigilTestKit"],
            path: "Tests/VigilRTPTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "VigilISAPITests",
            dependencies: ["VigilISAPI", "VigilTestKit"],
            path: "Tests/VigilISAPITests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "VigilDiscoveryTests",
            dependencies: ["VigilDiscovery", "VigilTestKit"],
            path: "Tests/VigilDiscoveryTests",
            resources: [.copy("Fixtures")]
        ),
        // End-to-end pure pipeline: synthetic camera -> RTSP -> RTP -> EncodedFrame. No sockets,
        // no VideoToolbox, no Mac required. This is the highest-value test target in the repo.
        .testTarget(
            name: "VigilPipelineTests",
            dependencies: ["VigilTestKit", "VigilRTSP", "VigilRTP", "VigilBitstream", "VigilProtocols"],
            path: "Tests/VigilPipelineTests",
            resources: [.copy("Fixtures")]
        ),

        // MARK: Tests — macOS only (bodies wrapped in #if os(macOS); empty modules on Linux)

        .testTarget(
            name: "VigilTransportTests",
            dependencies: ["VigilTransport", "VigilTestKit"],
            path: "Tests/VigilTransportTests"
        ),
        .testTarget(
            name: "VigilVideoTests",
            dependencies: ["VigilVideo", "VigilTestKit"],
            path: "Tests/VigilVideoTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "VigilRenderTests",
            dependencies: ["VigilRender", "VigilTestKit"],
            path: "Tests/VigilRenderTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "VigilCoreTests",
            dependencies: ["VigilCore", "VigilTestKit"],
            path: "Tests/VigilCoreTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "VigilUITests",
            dependencies: ["VigilUI", "VigilTestKit"],
            path: "Tests/VigilUITests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
```

### 3.1 Notes on the manifest

* `swiftLanguageModes: [.v6]` is set **once, package-wide**. No target may override it.
* Test targets deliberately carry **no** `swiftSettings`, so they inherit the package language mode.
  Tests are the one place `!` and `try!` are allowed (§14.6), not the one place data races are.
* `-warnings-as-errors` is **not** in the manifest — putting `unsafeFlags` in a manifest makes the
  package unusable as a dependency and interferes with Xcode. CI passes it on the command line:
  `swift build -Xswiftc -warnings-as-errors`.
* `resources:` uses `.process` for asset catalogs, `.metal` shaders and `.lproj` bundles (SwiftPM
  compiles them) and `.copy("Fixtures")` for test vectors (byte-exact, must not be transformed).
* Swift Testing (`import Testing`) ships **inside** the Swift 6 toolchain on both macOS and Linux and
  requires no package dependency. It is the default test framework. `XCTest` is used only where
  Swift Testing has no equivalent: `measure {}` performance blocks and `XCTExpectFailure`.

---

## 4. The dual-build mechanism (macOS + Linux from one manifest)

### 4.1 The problem

SwiftPM has **no per-platform target exclusion**. `.target(..., condition:)` exists for
*dependencies* and *settings*, not for the existence of a target. A `Package.swift` that lists
`VigilVideo` lists it on Linux too, and `import VideoToolbox` fails there. We need one manifest that
is correct on both hosts without `#if os(Linux)` in the manifest.

### 4.2 The decision — four rules

**Rule 1 — Product-scoped Linux builds.**
The `VigilPure` product enumerates exactly the Foundation-only targets. Linux CI's build step is:

```bash
swift build --product VigilPure -Xswiftc -warnings-as-errors
```

This is the *primary* mechanism. It is declarative, lives in the manifest, is reviewable in a diff,
and it fails loudly the moment a pure target grows an Apple-only import. `swift build --target X`
subsets are **not** used as the CI contract — a product is a named, versioned artifact; a `--target`
list in a shell script rots silently.

**Rule 2 — Every file of every macOS-only target is guarded.**
Each `.swift` file in `VigilTransport`, `VigilVideo`, `VigilRender`, `VigilCore`, `VigilUI`, `Vigil`
and their test targets opens with `#if os(macOS)` and closes with `#endif`. On Linux these targets
compile to **empty modules**, which is legal (SwiftPM only errors when a target directory contains
*no source files*, not when the files are empty after preprocessing). Consequence: a plain
`swift build` and a plain `swift test` both succeed on Linux, which keeps `swift test` usable as one
command (`--filter` does not skip *compilation* of other test targets, so the guards are mandatory,
not merely tidy).

**Rule 3 — The executable links on both platforms.**
`@main` cannot be conditionally compiled away without leaving the executable with no entry point, so
the entry point is a `main.swift` top-level file (which is why the `App` type does *not* carry
`@main`):

```swift
// Sources/Vigil/main.swift
#if os(macOS)
VigilApp.main()   // exactly what @main would synthesise
#else
import Foundation
FileHandle.standardError.write(Data("Vigil requires macOS 14.0 or later.\n".utf8))
exit(EXIT_FAILURE)
#endif
```

```swift
// Sources/Vigil/VigilApp.swift
#if os(macOS)
import SwiftUI

struct VigilApp: App {   // NOTE: no @main — main.swift calls .main() explicitly
    // …scenes…
}
#endif
```

**Rule 4 — Purity is linted, not hoped for.**
`Scripts/lint.sh` enforces a per-target import allow-list (§4.5). This catches the case Rule 1 misses:
an Apple-only import added to a pure target *inside* a `#if canImport(...)` block.

### 4.3 The file-guard template

Every macOS-only file looks exactly like this. The guard is the outermost construct; imports live
inside it.

```swift
//
//  DecodePipeline.swift
//  VigilVideo
//
//  macOS-only. See docs/ARCHITECTURE.md §4.2 Rule 2.
//

#if os(macOS)

import CoreMedia
import Foundation
import VideoToolbox

// … implementation …

#endif  // os(macOS)
```

For the rare file that is *mostly* portable with a small Apple-specific extension, split it into two
files (`Foo.swift` in the pure target, `Foo+Apple.swift` in the macOS target) rather than sprinkling
guards mid-file. Interleaved `#if` inside a type body is **forbidden**; it defeats readability and
makes the Linux build's effective source hard to reason about.

The single sanctioned exception is `VigilISAPI`, which needs Linux's split Foundation:

```swift
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLSession lives here on Linux
#endif
```

### 4.4 What "empty module on Linux" costs us

Nothing at build time; one thing at test time: a macOS-only test target contributes zero tests on
Linux, and Swift Testing reports that as success, not as a skip. To avoid a false sense of coverage,
`Scripts/test-linux.sh` prints the expected test counts per target and fails if a *pure* target
reports zero tests. The macOS-only targets are expected to report zero and are listed explicitly.

### 4.5 Import allow-list lint

`Scripts/lint.sh` contains this table and greps every file of every target for `^\s*(public |package |@_exported )?import\s+(\w+)`:

| Target | Allowed imports |
|---|---|
| `VigilProtocols` | `Foundation` |
| `VigilBitstream` | `Foundation`, `VigilProtocols` |
| `VigilRTSP` | `Foundation`, `VigilProtocols` |
| `VigilRTP` | `Foundation`, `VigilProtocols`, `VigilBitstream` |
| `VigilISAPI` | `Foundation`, `FoundationNetworking`, `VigilProtocols` |
| `VigilDiscovery` | `Foundation`, `VigilProtocols` |
| `VigilTestKit` | `Foundation`, `VigilProtocols`, `VigilRTSP`, `VigilRTP`, `VigilBitstream` |
| macOS targets | anything in the BRIEF framework list plus the module's declared dependencies |

Any import not on the row's list is an error. The word `CryptoKit` is on **no** list — see §14.9.

### 4.6 Alternatives considered and rejected

| Alternative | Why rejected |
|---|---|
| `#if os(Linux)` inside `Package.swift` to conditionally append targets | The manifest is compiled for the *host*, so `swift package dump-package` and the resolved graph differ per machine. Xcode, XcodeGen and any tooling that reads the manifest see a different package than CI. It also hides the failure mode we want (accidental Apple imports) instead of surfacing it. |
| Two manifests (`Package.swift` + `Package@swift-6.0.swift`) | Version-scoped manifests key on *tools version*, not OS. Wrong tool. |
| A separate `PackageLinux.swift` selected by a symlink in CI | Two graphs to keep in sync by hand; guaranteed drift. |
| Putting pure code in a sub-package | Adds a package dependency edge (even local), an extra `Package.swift`, and a second `.build`. All cost, no benefit, since one manifest already works. |
| `--target` subset list in CI | Not declarative, rots silently, and does not fail when a pure target gains an Apple import that happens not to be reached. |

---

## 5. Concurrency model

Swift 6 language mode, complete checking, **zero** `@preconcurrency` imports, **zero**
`nonisolated(unsafe)` globals, and exactly **two** documented `@unchecked Sendable` conformances in
the whole repository (§5.9).

### 5.1 The five rules

1. **Pure layer is isolation-free.** No target in the pure layer declares an `actor`, uses
   `@MainActor`, or creates a `Task`. Pure types are `struct`/`enum` with `mutating` methods, plus
   protocols. They are *confined* by whoever owns them. This is why they are trivially testable and
   why they never deadlock.
2. **One actor per concurrent resource, and nothing else is an actor.** The complete list is in §5.2.
   If you are tempted to add an actor, you probably want a `struct` owned by an existing actor.
3. **All UI is `@MainActor`.** Every type in `VigilUI`, every `NSView`/`NSViewRepresentable` in
   `VigilRender`, and the `AppModel` façade in `VigilCore` are `@MainActor`. Frames reach the screen
   without hopping to the main actor (§5.7).
4. **Everything that crosses an isolation boundary is a `Sendable` value type**, with the two
   documented exceptions.
5. **No GCD**, except the single VideoToolbox callback hop (§5.7) and Apple APIs that hand us a queue
   we do not control (`NWConnection`, `AVAssetWriter`, `NSView.displayLink`). §5.8.

### 5.2 Isolation domain table — the complete inventory

| Type | Module | Isolation | Why |
|---|---|---|---|
| `RTSPSessionMachine` | RTSP | none (`struct`, confined to `RTSPConnection`) | pure state machine |
| `SDPParser`, `RTSPMessageParser`, `DigestAuthenticator` | RTSP | none (`struct`) | pure |
| `H264Depacketizer`, `H265Depacketizer`, `AACDepacketizer`, `G711Depacketizer`, `JitterBuffer`, `StatisticsAccumulator` | RTP | none (`struct`, confined to `StreamController`) | pure |
| `SPSParser`, `AnnexBScanner`, record builders | Bitstream | none (`struct`) | pure |
| `SADPCodec`, `WSDiscoveryCodec`, `IPv4CIDR` | Discovery | none (`struct`) | pure |
| `ISAPIRequestBuilder`, `XMLCursor`, response decoders | ISAPI | none (`struct`) | pure |
| `RTSPConnection` | Transport | **`actor`** | owns one `NWConnection` + the session machine + its timers |
| `UDPMediaSocketPair` | Transport | **`actor`** | owns two `NWConnection`s (RTP/RTCP) |
| `MulticastResponder` | Transport | **`actor`** | owns an `NWListener` bound to 37020/3702 |
| `ISAPIHTTPClient` | ISAPI (proto) / Transport (impl) | **`actor`** | per-device request queue + connection reuse + Digest nonce cache |
| `DecodePipeline` | Video | **`actor`** | owns one `VTDecompressionSession` + format description + pixel-buffer pool |
| `DecodeBudget` | Video | **`@globalActor actor`** | app-wide admission control; there is exactly one |
| `AudioPlaybackEngine` | Video | **`actor`** | owns one `AVAudioEngine` graph node set |
| `ClipRecorder` | Core | **`actor`** | owns one `AVAssetWriter` |
| `StreamController` | Core | **`actor`** | one per camera; the pipeline owner (§5.4) |
| `StreamCoordinator` | Core | **`actor`** | app-wide policy: who is live, priority, budget requests |
| `ConfigStore` | Core | **`actor`** | serialises reads/writes of `library.json` |
| `CredentialStore` | Core | **`actor`** | serialises Keychain access + in-memory cache |
| `EventCenter` | Core | **`actor`** | dedupe window state, per-device alert streams |
| `HealthMonitor` | Core | **`actor`** | 10-minute stats rings |
| `AppModel`, `LibraryViewModel`, `StageViewModel`, `InspectorViewModel` | Core/UI | **`@MainActor @Observable final class`** | drive SwiftUI |
| `VideoTileView`, `MetalVideoRenderer`, all `NSViewRepresentable` | Render | **`@MainActor`** | AppKit/CoreAnimation are main-actor bound |
| `MetalContext` (shared `MTLDevice` + `MTLCommandQueue`) | Render | `final class`, **immutable after init**, `Sendable` via `let`-only stored properties of Sendable-conforming Metal protocol existentials | `MTLDevice`/`MTLCommandQueue` are documented thread-safe; we wrap them and expose only thread-safe operations |
| everything in `VigilUI` | UI | **`@MainActor`** (module-wide `defaultIsolation`, §5.3) | |

### 5.3 Module-wide main-actor isolation for `VigilUI`

`VigilUI` is compiled with default main-actor isolation so that view code does not need `@MainActor`
on every declaration. In Swift 6 this is spelled as a target setting:

```swift
.target(
    name: "VigilUI",
    // …
    swiftSettings: apple + [.defaultIsolation(MainActor.self)]
)
```

If the toolchain in use does not yet accept `.defaultIsolation`, the fallback is mandatory explicit
`@MainActor` on every top-level type in `VigilUI` — and `Scripts/lint.sh` checks for it. Do not leave
UI types un-annotated and rely on inference from `View` conformance.

### 5.4 The per-camera structured task tree

One `StreamController` actor per camera. It owns exactly one root `Task`, and every subordinate task
is a child of that task, in a task group. Nothing detaches. Cancelling the root cancels everything,
deterministically, and `stop()` does not return until the tree is joined.

```swift
public actor StreamController {

    private var root: Task<Void, Never>?

    public func start() {
        guard root == nil else { return }
        root = Task(priority: .userInitiated) { [weak self] in
            await self?.run()
        }
    }

    public func stop() async {
        root?.cancel()
        await root?.value      // structured join: no orphan sockets, no orphan decode sessions
        root = nil
    }

    private func run() async {
        while !Task.isCancelled {
            do {
                try await runOneSession()          // returns only on graceful teardown
                if Task.isCancelled { return }
                await transition(to: .stopped)
                return
            } catch {
                let decision = retryPolicy.classify(error)   // §7.5
                await transition(to: .reconnecting(decision))
                guard let delay = decision.delay else {
                    await transition(to: .failed(error)); return
                }
                try? await clock.sleep(for: delay)           // cancellable
            }
        }
    }

    private func runOneSession() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in

            // 1. Byte ingest: NWConnection -> RTSPSessionMachine -> events.
            group.addTask { try await self.ingestLoop() }

            // 2. Action pump: RTSPAction.send/setTimer/emitTrack -> socket & timers.
            group.addTask { try await self.actionLoop() }

            // 3. Keepalive: GET_PARAMETER at min(sessionTimeout/2, 25 s).
            group.addTask { try await self.keepaliveLoop() }

            // 4. Media: interleaved payloads -> jitter buffer -> depacketizer -> EncodedFrame.
            group.addTask { try await self.mediaLoop() }

            // 5. Decode: EncodedFrame -> DecodePipeline -> VideoSink.
            group.addTask { try await self.decodeLoop() }

            // 6. RTCP: parse SR, emit RR every 1–5 s (RFC 3550 interval rules).
            group.addTask { try await self.rtcpLoop() }

            // 7. Stats: sample StreamStatistics at 1 Hz into the health ring.
            group.addTask { try await self.statsLoop() }

            // 8. Watchdogs: first-packet 4 s, first-keyframe 6 s, read-idle 8 s.
            group.addTask { try await self.watchdogLoop() }

            // The FIRST child to throw cancels the rest — this is exactly the semantics we want:
            // any stage failing means the session is dead and must be rebuilt.
            try await group.next()
            group.cancelAll()
        }
    }
}
```

Task count per live camera: **8 child tasks + 1 root = 9**. At 16 cameras that is 144 tasks, which is
fine — Swift tasks are heap objects on a cooperative pool, not threads. The cooperative pool is sized
to `activeProcessorCount`; none of these loops blocks, so we never starve it. **Blocking a cooperative
thread is forbidden** (§5.8).

### 5.5 Bounded queues and backpressure

Two queues exist per camera. Both are bounded. Neither ever grows without limit, and both count drops.

```
[NWConnection] --Data--> (no queue: parsed inline)
   --InterleavedFrame--> [JitterBuffer: bounded ring, pure] 
   --EncodedFrame--> [EncodedFrameQueue: bounded 8 frames / 1500 ms] 
   --DecodedFrame--> [AsyncStream .bufferingNewest(3)] --> [VideoSink]
```

| Queue | Bound | Overflow policy | Counter |
|---|---|---|---|
| `JitterBuffer` (RTP packets) | `max(packets: 512, duration: latencyPreset)` — 120 ms low / 300 ms balanced / 600 ms quality | evict oldest, mark gap, request IDR via RTSP `SET_PARAMETER`/keyframe hint | `stats.packetsDropped`, `stats.gaps` |
| `EncodedFrameQueue` | 8 frames **or** 1500 ms of PTS span, whichever is hit first | **drop-to-keyframe**: discard everything up to and including the next IRAP; never drop a partial GOP head | `stats.framesDroppedPreDecode` |
| decoded `AsyncStream` | `.bufferingNewest(3)` | oldest decoded frame discarded (it is already stale for live) | `stats.framesDroppedPreDisplay` |

**Why explicit bounds instead of `AsyncStream` backpressure:** `AsyncStream` has no producer-side
backpressure, and we do not want any — a live camera cannot be told to slow down, and blocking the
ingest loop to wait for the decoder would stall RTSP keepalives and RTCP, which gets us dropped by the
camera. The correct behaviour for live video is **drop, count, and report**, and the correct place to
decide *what* to drop is the frame layer that knows about keyframes. So:

```swift
/// Bounded, keyframe-aware encoded-frame queue. Confined to StreamController; not Sendable.
struct EncodedFrameQueue {
    private var frames: [EncodedFrame] = []
    let maxFrames: Int
    let maxSpan: Duration

    /// - Returns: number of frames dropped to make room (0 in the healthy case).
    @discardableResult
    mutating func push(_ frame: EncodedFrame) -> Int {
        frames.append(frame)
        guard frames.count > maxFrames || span > maxSpan else { return 0 }
        // Drop to the newest keyframe; if none, drop the oldest half.
        if let k = frames.lastIndex(where: \.isKeyframe), k > 0 {
            let dropped = k
            frames.removeFirst(k)
            return dropped
        }
        let dropped = frames.count / 2
        frames.removeFirst(dropped)
        return dropped
    }

    mutating func pop() -> EncodedFrame? { frames.isEmpty ? nil : frames.removeFirst() }
    var span: Duration { /* newest.pts - oldest.pts as Duration */ .zero }
}
```

For *recorded playback* the policy inverts: the queue is 32 frames deep, overflow **suspends** the
reader (a real `AsyncStream` with `.bufferingOldest` plus an `await` on a `AsyncSemaphore`-style token
held by the pipeline), because a file can and should be read at the consumer's pace. That is the one
place we apply true backpressure. `spec-video-pipeline.md` owns the details.

### 5.6 Cancellation propagation

| Trigger | Mechanism | Latency budget |
|---|---|---|
| User removes/disables camera | `await controller.stop()` → root `Task.cancel()` | < 50 ms to socket close |
| Tile scrolled offscreen | `StreamCoordinator` calls `controller.setPriority(.offscreen)`; the controller *pauses decode* (keeps RTSP session) — no cancellation | immediate |
| Layout drops the camera entirely | `stop()` | < 50 ms |
| App quit | `applicationWillTerminate` → `await coordinator.shutdown()` with a **2 s** budget, then hard exit | ≤ 2 s |
| Sleep | `NSWorkspace.willSleepNotification` → `coordinator.suspendAll()` → `stop()` all | ≤ 1 s |
| Network path lost | `NWPathMonitor` → `coordinator.networkLost()` → all controllers to `.reconnecting`, sockets cancelled | ≤ 200 ms |
| Any child task throws | task-group `next()` rethrows, `cancelAll()` tears down siblings | one hop |

Every `await` in a loop MUST be cancellation-aware. Concretely: use `try Task.checkCancellation()` at
the top of each loop iteration, use `clock.sleep(for:)` (cancellable) never `Thread.sleep`, and wrap
`NWConnection` receives in `withTaskCancellationHandler` so cancelling the task calls
`connection.cancel()`:

```swift
func receive(max: Int) async throws -> Data {
    try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { cont in
            connection.receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, isComplete, error in
                if let error { cont.resume(throwing: TransportError.network(error)) }
                else if let data, !data.isEmpty { cont.resume(returning: data) }
                else if isComplete { cont.resume(throwing: TransportError.peerClosed) }
                else { cont.resume(returning: Data()) }
            }
        }
    } onCancel: {
        connection.cancel()      // unblocks the continuation via the error path
    }
}
```

`withCheckedThrowingContinuation` around `NWConnection` callbacks is the **only** sanctioned callback
bridge besides the VideoToolbox hop, and every such bridge MUST guarantee exactly-once resumption. Use
a small `final class OneShot: @unchecked Sendable` guard in debug builds if a callback's contract is
unclear.

### 5.7 The VideoToolbox callback hop — the one place GCD appears

`VTDecompressionSession` calls back on its own internal queue. There is no async variant. Two API
shapes exist; we use the **`outputHandler` block form** because it avoids the `void *refcon` and the
unmanaged-pointer lifetime problem entirely:

```swift
// Inside actor DecodePipeline
private func decode(_ sample: CMSampleBuffer, pts: MediaTimestamp) throws {
    var flags = VTDecodeInfoFlags()
    let status = VTDecompressionSessionDecodeFrame(
        session,
        sampleBuffer: sample,
        flags: [._EnableAsynchronousDecompression, ._1xRealTimePlayback],
        infoFlagsOut: &flags,
        outputHandler: { [sink = self.sinkBox] status, _, imageBuffer, presentation, _ in
            // ⚠️ NOT on the actor. Not on the main actor. VT's private queue.
            // The ONLY thing we are allowed to do here is package and hand off.
            guard status == noErr, let imageBuffer else {
                sink.reportDecodeFailure(status); return
            }
            sink.deliver(DecodedFrame(pixelBuffer: imageBuffer,
                                      pts: MediaTimestamp(presentation),
                                      decodedAt: .now))
        }
    )
    guard status == noErr else { throw DecodeError.vt(status) }
}
```

`sinkBox` is the first of our two `@unchecked Sendable` types:

```swift
/// Thread-safe hand-off from VideoToolbox's private queue into the async world.
///
/// `@unchecked Sendable` justification: the only mutable state is an
/// `AsyncStream.Continuation`, which is documented thread-safe for `yield`/`finish`, and an
/// `os_unfair_lock`-protected failure counter. Nothing else is stored. Reviewed 2026-07.
final class DecodeSinkBox: @unchecked Sendable {
    private let continuation: AsyncStream<DecodedFrame>.Continuation
    private let lock = OSAllocatedUnfairLock(initialState: Counters())

    func deliver(_ frame: DecodedFrame) {
        // .bufferingNewest(3): yield never blocks, and drops the stalest frame.
        if case .dropped = continuation.yield(frame) {
            lock.withLock { $0.droppedPreDisplay += 1 }
        }
    }
}
```

**Why this is safe and why it is the right shape:** frames leave VT's queue and enter an
`AsyncStream` whose consumer is the render sink. No actor hop is required to *deliver* a frame, so
the frame path is: VT queue → `AsyncStream` → `@MainActor` sink `enqueue`/Metal draw. That is one hop
to the main actor for `AVSampleBufferDisplayLayer.enqueue` (which is main-actor-bound in practice) and
**zero** hops for the Metal path, where we render on the `MTLCommandQueue` from the stream consumer
task. See `spec-render.md`.

`OSAllocatedUnfairLock` (macOS 13+) is the sanctioned lock primitive. `NSLock`, `pthread_mutex` and
`DispatchSemaphore` are forbidden in new code; `DispatchSemaphore` in particular can block a
cooperative thread and deadlock the pool.

### 5.8 Why we avoid GCD

| Problem with GCD here | Consequence |
|---|---|
| `DispatchQueue.async` is a `Sendable` hole the compiler cannot fully police in mixed code | silent data races survive review |
| No cancellation | a torn-down camera keeps decoding for seconds; on 16 cameras that is a visible CPU spike |
| No structured lifetime | orphan sockets and decode sessions after `stop()`; leaked hardware decode sessions eventually fail `VTDecompressionSessionCreate` |
| Thread explosion | one serial queue per camera per stage = 100+ threads at 16 cameras; each costs 512 KB stack |
| Priority inversion | a `.utility` snapshot write blocking a `.userInitiated` frame path |
| `DispatchSemaphore` blocks cooperative threads | pool starvation → the whole app stops making progress |

Sanctioned GCD/queue usage, exhaustively:

1. The VideoToolbox `outputHandler` block (§5.7) — we do not choose the queue.
2. `NWConnection(queue:)` — Network.framework requires a `DispatchQueue`. Each `RTSPConnection` actor
   creates one **serial, `.userInitiated`** queue and immediately bridges to `async` (§5.6). The queue
   name MUST be `com.vigil.net.<cameraShortID>`.
3. `AVAssetWriterInput.requestMediaDataWhenReady(on:using:)` — API requires a queue; `ClipRecorder`
   owns one serial queue and bridges.
4. `NSView.displayLink(target:selector:)` (macOS 14) delivers on the main run loop — no queue of ours.
5. `DispatchSource` is not used anywhere. Timers are `Task { try await clock.sleep(...) }`.

### 5.9 Sendable boundary table

| Type crossing a boundary | Strategy |
|---|---|
| `EncodedFrame`, `MediaTimestamp`, `ParameterSets`, `RTPPacket`, `InterleavedFrame`, `StreamStatistics`, `Camera`, `Credential`, `DiscoveredDevice`, `StreamEvent`, `EventRecord`, `VigilError` and every nested error | plain `Sendable` structs/enums of `Sendable` members. `Data` is `Sendable`. **No class members, ever.** |
| `RTSPSessionMachine`, depacketizers, jitter buffer | **not** `Sendable` and must not be. They are actor-confined `var`s. Declaring them `Sendable` would invite sharing. |
| `DecodedFrame` (wraps `CVPixelBuffer`) | `struct DecodedFrame: @unchecked Sendable`. **Justification:** the `CVPixelBuffer` is produced by VideoToolbox, never mutated after delivery, and every consumer only locks its base address for reading or wraps it in an `MTLTexture` via `CVMetalTextureCache`. Enforced by convention plus a debug assertion that `CVPixelBufferIsPlanar`/dimensions are stable, and by never handing the same buffer to two writers. This is exception #2 of 2. |
| `CMSampleBuffer` | never crosses a boundary. It is created inside `DecodePipeline` and consumed there (or handed to `AVSampleBufferDisplayLayer` from the same task). If you need to move one, move the `EncodedFrame` instead and rebuild. |
| `MetalContext` | `final class` with only `let` properties holding `any MTLDevice`/`any MTLCommandQueue`; conforms to `Sendable` **without** `@unchecked` by marking the protocol existentials via a `Sendable`-conforming wrapper struct. If the toolchain refuses, the fallback is a third `@unchecked Sendable` with the same style of justification comment — and it must be added to this table. |
| closures crossing into a `Task` | `@Sendable` and capture only `Sendable` values, or `[weak self]` on an actor. Capturing a `@MainActor` view model into a non-main task is forbidden. |
| `NWConnection`, `AVAudioEngine`, `AVAssetWriter`, `VTDecompressionSession` | never cross. Each is owned by exactly one actor and only touched from it. |

### 5.10 Injected clocks and randomness (why the pure layer is deterministic)

The pure layer never calls `Date()`, `DispatchTime.now()`, `ContinuousClock().now` or
`SystemRandomNumberGenerator`. Three protocols in `VigilProtocols` make time and randomness inputs:

```swift
/// Monotonic time source. Nanoseconds since an arbitrary epoch; never decreases.
public protocol MonotonicClock: Sendable {
    var nowNanoseconds: UInt64 { get }
    /// Cancellable sleep. Implementations MUST honour `Task` cancellation by throwing.
    func sleep(for duration: Duration) async throws
}

/// Wall-clock time, used only for display and for RTCP NTP mapping.
public protocol WallClock: Sendable {
    var now: Date { get }
}

/// Deterministic randomness for jitter, probe UUIDs and cnonces.
public protocol RandomSource: Sendable {
    mutating func next() -> UInt64
}

/// Production implementations (macOS targets).
public struct SystemMonotonicClock: MonotonicClock { /* clock_gettime_nsec_np(CLOCK_UPTIME_RAW) */ }
public struct SystemWallClock: WallClock { public var now: Date { Date() } }
public struct SystemRandomSource: RandomSource { /* SystemRandomNumberGenerator */ }

/// Test implementations (VigilTestKit).
public struct VirtualClock: MonotonicClock { /* explicit advance(by:) */ }
public struct SplitMix64: RandomSource { /* seeded, reproducible */ }
```

Every pure state machine takes `now: UInt64` (monotonic nanoseconds) as a **parameter** to `step(now:)`
rather than reading a clock. Every retry delay computes jitter from an injected `RandomSource`. The
consequence: a failing CI run prints a seed, and re-running with that seed reproduces the failure
exactly. This is non-negotiable for a networking app.

---

<!-- PART2 -->
