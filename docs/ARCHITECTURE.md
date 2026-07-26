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
            // `type:` is REQUIRED here, not cosmetic. A library product with no explicit type is an
            // "automatic" product, and SwiftPM refuses `swift build --product <automatic library>`:
            //   warning: '--product' cannot be used with the automatic product 'VigilPure';
            //            building the default target instead
            // That silently turns the Linux purity gate into a full-package build, which defeats it.
            // Verified on Swift 6.1.2 / Linux — see docs/BUILD-VERIFICATION.md.
            type: .static,
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

## 6. End-to-end data flow

### 6.1 The pipeline, with the exact type at every boundary

| # | Stage | Runs in | Input type | Output type | Owner module |
|---|---|---|---|---|---|
| 1 | Multicast/unicast probe | `MulticastResponder` actor | `SADPProbe` / `WSDiscoveryProbe` → `Data` | `Data` → `DiscoveredDevice` | Discovery + Transport |
| 2 | Subnet sweep | `SweepEngine` actor | `IPv4CIDR` | `[DiscoveredDevice]` | Discovery + Transport |
| 3 | Fingerprint | `ISAPIHTTPClient` actor | `DiscoveredDevice` | `DeviceInfo` | ISAPI |
| 4 | Persist | `ConfigStore` actor | `Camera` | `Camera` (in `library.json`) | Core |
| 5 | Resolve credentials | `CredentialStore` actor | `CredentialRef` | `Credential` | Core |
| 6 | Connect | `RTSPConnection` actor | `NWEndpoint` | `Data` chunks | Transport |
| 7 | Parse RTSP | `RTSPSessionMachine` (struct, in `RTSPConnection`) | `Data` → `ingest(_:)` | `[RTSPEvent]`, `[RTSPAction]` | RTSP |
| 8 | Describe | same | `RTSPResponse` (SDP body) | `SDPDescription` → `[TrackDescription]` | RTSP |
| 9 | Demux interleaved | `StreamController` actor | `InterleavedFrame(channel:payload:)` | `RTPPacket` / `RTCPPacket` | RTSP → RTP |
| 10 | Reorder | `JitterBuffer` (struct) | `RTPPacket` | `RTPPacket` in sequence, `GapEvent` | RTP |
| 11 | Depacketize | `H264Depacketizer` / `H265Depacketizer` (struct) | `RTPPacket` | **`EncodedFrame`** | RTP |
| 12 | Parameter sets | `SPSParser` (struct) | `Data` (SPS/PPS/VPS) | `ParameterSets`, `VideoGeometry` | Bitstream |
| 13 | Format description | `DecodePipeline` actor | `ParameterSets` | `CMVideoFormatDescription` | Video |
| 14 | Sample buffer | `DecodePipeline` actor | `EncodedFrame` + format desc | `CMSampleBuffer` | Video |
| 15 | Decode | `VTDecompressionSession` (VT queue) | `CMSampleBuffer` | `CVPixelBuffer` | Video |
| 16 | Deliver | `DecodeSinkBox` | `CVPixelBuffer` | **`DecodedFrame`** in `AsyncStream` | Video |
| 17 | Texture | `MetalVideoRenderer` `@MainActor` | `DecodedFrame` | 2× `MTLTexture` via `CVMetalTextureCache` | Render |
| 18 | Draw | `MetalVideoRenderer` | `MTLTexture` | `CAMetalDrawable` → `CAMetalLayer` | Render |
| 18′ | Fast path | `VideoTileView` `@MainActor` | `CMSampleBuffer` | `AVSampleBufferDisplayLayer.enqueue` | Render |
| 19 | Screen | WindowServer | — | photons | — |

Stage 18′ is the default for a plain tile with no pixel-level features enabled; stage 17–18 is used
whenever digital zoom, colour adjust, motion overlay, deinterlace, snapshot-of-displayed-frame or
video-wall atlas compositing is active. `spec-video-pipeline.md` §"Two display strategies" owns the
switch, and it MUST be switchable at runtime without dropping the RTSP session.

### 6.2 The boundary signatures, verbatim

These signatures are part of the cross-module contract. Module specs may add members; they may not
change these.

```swift
// ── VigilProtocols ────────────────────────────────────────────────────────────────────────────

/// Codec-independent presentation timestamp. Never a CMTime in the pure layer.
public struct MediaTimestamp: Hashable, Sendable, Codable {
    public var value: Int64
    public var timescale: Int32          // 90_000 for RTP video, sample rate for audio
    public init(value: Int64, timescale: Int32)
    public var seconds: Double { Double(value) / Double(timescale) }
    public func converted(to newTimescale: Int32) -> MediaTimestamp
}

/// One compressed access unit, ready for a decoder. NALs are 4-byte big-endian length-prefixed.
public struct EncodedFrame: Sendable {
    public var data: Data                    // 4-byte-length-prefixed NAL units, no start codes
    public var pts: MediaTimestamp
    public var dts: MediaTimestamp?          // nil ⇒ dts == pts (live H.264 baseline/main w/o B)
    public var duration: MediaTimestamp?
    public var isKeyframe: Bool              // IDR (H.264) or IRAP 16…23 (H.265)
    public var codec: VideoCodec
    public var parameterSets: ParameterSets? // non-nil when they changed at/ before this frame
    public var sequenceNumber: UInt64        // monotonic per stream, for logging and drop accounting
    public var receivedAtNanos: UInt64       // MonotonicClock stamp of the LAST packet of the AU
}

public struct ParameterSets: Hashable, Sendable {
    public var codec: VideoCodec
    public var vps: [Data]      // H.265 only
    public var sps: [Data]
    public var pps: [Data]
}

public enum VideoCodec: String, Sendable, Codable, CaseIterable { case h264, h265, mjpeg }
public enum AudioCodec: String, Sendable, Codable, CaseIterable { case aac, pcmA, pcmU, g726 }

// ── VigilRTSP ─────────────────────────────────────────────────────────────────────────────────

/// One `$`-framed chunk demultiplexed off the RTSP TCP socket.
public struct InterleavedFrame: Sendable {
    public var channel: UInt8      // even = RTP, odd = RTCP, as negotiated in SETUP
    public var payload: Data
}

/// The transport-agnostic core. No sockets, no clock reads, no Task.
public struct RTSPSessionMachine: ~Copyable {
    public init(configuration: RTSPConfiguration, credential: Credential?)
    /// Feed raw socket bytes. Returns everything that became knowable.
    public mutating func ingest(_ bytes: Data) -> [RTSPEvent]
    /// Advance time. Returns what the caller must now do.
    public mutating func step(nowNanos: UInt64) -> [RTSPAction]
    public var state: RTSPSessionState { get }
}

public enum RTSPAction: Sendable {
    case send(Data)
    case setTimer(id: RTSPTimerID, deadlineNanos: UInt64)
    case cancelTimer(id: RTSPTimerID)
    case emitTrack(TrackDescription)
    case media(InterleavedFrame)
    case sessionEstablished(sessionID: String, timeoutSeconds: Int)
    case fail(RTSPError)
    case closed
}

// ── VigilRTP ──────────────────────────────────────────────────────────────────────────────────

public protocol Depacketizer: ~Copyable {
    /// Push one in-order RTP packet. Returns zero or more completed access units.
    mutating func push(_ packet: RTPPacket) -> [EncodedFrame]
    /// Called on a detected sequence gap; the depacketizer discards its partial AU.
    mutating func reset(reason: DepacketizerResetReason)
    var statistics: StreamStatistics { get }
}

// ── VigilVideo ────────────────────────────────────────────────────────────────────────────────

/// A decoded frame on its way to the screen. See ARCHITECTURE §5.9 for the Sendable justification.
public struct DecodedFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let pts: MediaTimestamp
    public let decodedAtNanos: UInt64
    public let geometry: VideoGeometry      // display w/h, SAR, crop rect, colour primaries
    public let isKeyframe: Bool
}

@MainActor public protocol VideoSink: AnyObject {
    func present(_ frame: DecodedFrame)
    func presentCompressed(_ sample: CMSampleBuffer)     // 18′ fast path
    func flush(reason: FlushReason)
    var preferredDeliveryMode: DeliveryMode { get }       // .pixelBuffer | .compressed
}

/// Snapshot of the exact pixels on screen. Implemented by VigilRender, called by VigilCore.
public protocol SnapshotSource: Sendable {
    func captureDisplayedFrame() async throws -> DecodedFrame
}
```

### 6.3 Threading of the frame path (the latency-critical answer)

```
NWConnection queue (com.vigil.net.<id>)
      │  Data
      ▼
RTSPConnection actor ── InterleavedFrame ──► StreamController actor
                                                    │  (JitterBuffer + Depacketizer are
                                                    │   plain structs, same actor, no hop)
                                                    │  EncodedFrame
                                                    ▼
                                             DecodePipeline actor ── CMSampleBuffer ──► VT
                                                                                         │
                        DecodedFrame  ◄── DecodeSinkBox ◄── VT private queue ◄───────────┘
                              │
                              ├─ preferredDeliveryMode == .compressed ─► @MainActor enqueue()
                              └─ .pixelBuffer ─► renderer task ─► MTLCommandQueue.commit()
```

Actor hops on the frame path: **2** (into `StreamController`, into `DecodePipeline`), plus **1** to the
main actor only on the `.compressed` path. Budget: each hop is < 20 µs on Apple silicon; total actor
overhead is < 100 µs per frame, i.e. < 0.4 % of a 33 ms frame at 30 fps, and negligible against the
250 ms glass-to-glass budget (which is dominated by the camera's own encoder GOP structure and the
jitter buffer depth).

**Rule:** no `await` on the frame path may target an actor that also performs I/O or file writes.
`ClipRecorder` and `ConfigStore` are therefore separate actors, and recording receives frames by
`AsyncStream` fan-out, never by an inline `await`.

---

## 7. Error taxonomy

### 7.1 Shape

One root enum in `VigilProtocols`, one nested domain enum per module. Every error carries enough to
(a) log, (b) show a human a sentence, (c) decide whether to retry.

```swift
public enum VigilError: Error, Sendable, Hashable {
    case transport(TransportError)
    case rtsp(RTSPError)
    case rtp(RTPError)
    case bitstream(BitstreamError)
    case isapi(ISAPIError)
    case discovery(DiscoveryError)
    case decode(DecodeError)
    case render(RenderError)
    case storage(StorageError)
    case credential(CredentialError)
    case recording(RecordingError)
    case cancelled
    case internalInvariant(String, file: StaticString, line: UInt)
}

public enum ErrorSeverity: Int, Sendable, Comparable { case degraded, recoverable, fatal }

public enum RetryDisposition: Sendable, Hashable {
    case retryWithBackoff          // transient: network blip, timeout, camera reboot
    case retryImmediatelyOnce      // stale Digest nonce, 401 with a new nonce, kVTInvalidSessionErr
    case retryAfterUserAction      // wrong password, camera not activated, unsupported codec
    case noRetry                   // programmer error, unsupported OS feature
}

public protocol VigilErrorDescribing: Error, Sendable {
    /// Stable machine code for logs, diagnostics bundles and support: e.g. "VG-RTSP-0401".
    var diagnosticCode: String { get }
    var severity: ErrorSeverity { get }
    var disposition: RetryDisposition { get }
    /// One sentence, sentence case, no jargon, no error numbers. Localised. See UX.md copy rules.
    var userMessage: String { get }
    /// One imperative sentence telling the user what to do, or nil if there is nothing to do.
    var userRemedy: String? { get }
    /// Extra key/values for the log line. MUST NOT contain secrets. See §8.6.
    var logMetadata: [String: String] { get }
}
```

`VigilError` and every domain enum conform to `VigilErrorDescribing`. `LocalizedError` conformance is
added in `VigilCore` (an extension) so the pure layer stays Foundation-minimal but AppKit alerts still
work.

### 7.2 Domain enums and dispositions

| Domain | Cases (abridged — module specs are normative for the full list) | Severity | Disposition |
|---|---|---|---|
| `TransportError` | `.connectTimeout`, `.connectRefused`, `.hostUnreachable`, `.peerClosed`, `.readIdleTimeout`, `.tlsFailed(reason)`, `.tlsUntrusted(fingerprint)`, `.multicastBlocked`, `.localNetworkDenied`, `.network(NWError)` | recoverable; `.localNetworkDenied` fatal | backoff; `.localNetworkDenied` → user action |
| `RTSPError` | `.malformedResponse`, `.headerTooLarge(bytes)`, `.unexpectedStatus(code)`, `.unauthorized`, `.authRejected`, `.methodNotSupported`, `.noSuitableTrack`, `.sdpParse(detail)`, `.transportRejected`, `.sessionNotFound`, `.interleaveDesync(recovered:)`, `.timeout(RTSPTimerID)` | `.authRejected` fatal; `.interleaveDesync(recovered: true)` degraded; rest recoverable | `.unauthorized` → immediate once; `.authRejected` → user action; rest → backoff |
| `RTPError` | `.shortPacket(len)`, `.unknownPayloadType(pt)`, `.badFragment`, `.aggregationOverflow`, `.jitterBufferOverflow(dropped)`, `.gap(count)` | degraded | none (counted in stats, never fails the session) |
| `BitstreamError` | `.truncated(atBit)`, `.unsupportedProfile(idc)`, `.unsupportedChromaFormat(idc)`, `.scalingListOverrun`, `.noParameterSets`, `.exponentialGolombOverflow` | recoverable | `.noParameterSets` → wait for next IRAP; rest → backoff |
| `ISAPIError` | `.http(status)`, `.digestChallengeMissing`, `.responseStatus(code:sub:)`, `.xmlUnexpected(path)`, `.notSupported(endpoint)`, `.deviceBusy`, `.accountLocked(retryAfter)` | `.accountLocked` fatal | `.deviceBusy` → backoff; `.notSupported` → no retry (capability cached as false) |
| `DiscoveryError` | `.multicastEntitlementMissing`, `.noUsableInterface`, `.prefixTooWide(bits)`, `.probeSendFailed`, `.cancelled` | recoverable | `.multicastEntitlementMissing` → fall back to sweep, surface a one-time notice |
| `DecodeError` | `.vt(OSStatus)`, `.badData`, `.invalidSession`, `.malfunction`, `.formatChangeUnsupported`, `.noHardwareDecoder`, `.budgetDenied(cost)` | `.noHardwareDecoder` degraded | `.invalidSession`/`.malfunction` → immediate once (recreate + wait for IDR); `.badData` → drop to next keyframe, no session restart |
| `RenderError` | `.metalUnavailable`, `.textureCacheFailed(CVReturn)`, `.pipelineCompileFailed(String)`, `.drawableUnavailable` | `.metalUnavailable` degraded (fall back to AVSBDL) | no retry |
| `StorageError` | `.notWritable(URL)`, `.corruptDocument(reason)`, `.schemaTooNew(found:supported:)`, `.diskFull(needBytes)`, `.atomicReplaceFailed` | fatal for `.schemaTooNew` | user action |
| `CredentialError` | `.keychainStatus(OSStatus)`, `.notFound`, `.duplicate`, `.userCancelledUnlock` | recoverable | user action |
| `RecordingError` | `.firstSampleNotKeyframe`, `.writerFailed(NSError)`, `.destinationUnwritable`, `.spaceBelowReserve` | recoverable | user action |

### 7.3 Diagnostic code format

`VG-<DOMAIN>-<4 digits>` — e.g. `VG-RTSP-0401` (unauthorized), `VG-RTSP-0453` (transport rejected),
`VG-DEC-0011` (`kVTVideoDecoderBadDataErr`), `VG-STOR-0002` (corrupt document). Codes are **stable
forever**; they appear in logs, in the diagnostics bundle, and in the Stream Doctor UI's "copy details"
text. Each module spec MUST publish its own code table. Never reuse a retired code.

### 7.4 Invariant failures

`case internalInvariant(String, file:line:)` is thrown by a helper:

```swift
@inline(__always)
public func vigilRequire(
    _ condition: Bool, _ message: @autoclosure () -> String,
    file: StaticString = #fileID, line: UInt = #line
) throws {
    guard !condition else { return }
    throw VigilError.internalInvariant(message(), file: file, line: line)
}
```

We **throw**, not `fatalError`, everywhere a surveillance app could otherwise take the whole window
down because one camera sent something odd. `fatalError`/`precondition` is permitted only in
`VigilRender` and `VigilVideo` setup paths where continuing would corrupt GPU state, and only with a
`// RATIONALE:` comment. A malformed packet from one camera MUST NEVER be able to crash the app — this
is a security property, not just robustness: these bytes come from the network.

### 7.5 The reconnect state machine

Owned by `StreamController` (see `spec-core.md` for the full state table, which MUST match this).
States and the transitions that matter for retry:

```
                     ┌──────────────────────────────────────────────────────────┐
                     │                                                          │
                     ▼                                                          │
 ┌──────┐  start   ┌────────────┐  addr ok   ┌────────────┐  TCP up  ┌──────────────┐
 │ idle │─────────►│ resolving  │───────────►│ connecting │─────────►│authenticating│
 └──────┘          └─────┬──────┘            └─────┬──────┘          └──────┬───────┘
     ▲                   │ DNS/host fail           │ refused/timeout        │ 401 w/ new nonce
     │                   ▼                         ▼                        │ (retry once)
     │            ┌──────────────┐          ┌──────────────┐                ▼
     │            │ reconnecting │◄─────────┤ reconnecting │        ┌───────────────┐
     │            └──────┬───────┘          └──────────────┘        │  describing   │
     │                   │ backoff elapsed                          └───────┬───────┘
     │                   └──────────────────────────► connecting            │ SDP ok
     │                                                                      ▼
     │                                                              ┌───────────────┐
     │                                                              │  settingUp    │
     │  stop()                                                      └───────┬───────┘
     │                                                                      │ all tracks SETUP
     │                                                                      ▼
 ┌────────┐   stop()   ┌─────────┐   loss > 5% for 3 s   ┌──────────┐  PLAY 200 ┌──────────┐
 │stopped │◄───────────│ playing │──────────────────────►│ degraded │◄──────────│  playing │
 └────────┘            └────┬────┘◄──────────────────────└──────────┘            └──────────┘
                            │  read-idle 8 s / peer close / RTCP BYE / decode malfunction
                            ▼
                     ┌──────────────┐  attempts exhausted / authRejected  ┌────────┐
                     │ reconnecting │────────────────────────────────────►│ failed │
                     └──────────────┘                                     └────────┘
                                                                              │ user retry
                                                                              └──► resolving
```

#### Timings — normative

| Parameter | Value | Notes |
|---|---|---|
| DNS/`NWEndpoint` resolve timeout | 2 s | IPs skip this state |
| TCP connect timeout | 3 s | `NWConnection` `.waiting` for > 3 s counts as timeout |
| RTSP `OPTIONS` timeout | 3 s | skipped if the camera is known-good from cache |
| `DESCRIBE` timeout | 5 s | includes the 401 round trip |
| `SETUP` timeout (per track) | 5 s | |
| `PLAY` timeout | 5 s | |
| First RTP packet after `PLAY` | 4 s | failure ⇒ `RTSPError.timeout(.firstPacket)`; strongly suggests UDP blocked → auto-switch to TCP once |
| First keyframe after first packet | 6 s | failure ⇒ send keyframe request, then 6 s more, then reconnect |
| Read-idle while playing | 8 s | no bytes at all on the RTSP socket |
| Keepalive interval | `min(sessionTimeout / 2, 25 s)`, floor 5 s | `GET_PARAMETER`, or `OPTIONS` if the camera rejects it |
| Backoff schedule | **0.5, 1, 2, 4, 8, 15, 30 s**, then 30 s forever | index advances per consecutive failure |
| Jitter | **± 20 %** uniform, from injected `RandomSource` | prevents 16 cameras reconnecting in lockstep and DoS-ing a small NVR |
| Backoff reset | after **60 s** continuously in `playing` | index → 0 |
| Network-restored override | on `NWPath.status == .satisfied` transition, cancel the pending delay and retry **immediately** (one free attempt, index unchanged) | |
| Wake-from-sleep override | same as network-restored, after a 1.5 s settle delay | Wi-Fi needs time to associate |
| Max consecutive auth attempts | **2** | then `.failed(.rtsp(.authRejected))` |

The delay is computed as:

```swift
func delay(forAttempt n: Int, using rng: inout some RandomSource) -> Duration {
    let table: [Double] = [0.5, 1, 2, 4, 8, 15, 30]
    let base = table[min(n, table.count - 1)]
    let jitter = 1.0 + (Double(rng.next() % 40_001) / 100_000.0 - 0.20)   // 0.80 … 1.20
    return .milliseconds(Int(base * jitter * 1000))
}
```

#### The auth-lockout rule — cross-cutting and important

Hikvision firmware **locks an account for 30 minutes after 5 consecutive failed logins** (default
`illegalLoginLock`). A naive reconnect loop with wrong credentials will therefore lock the user out of
their own camera, including its web UI. Therefore:

* A `401` whose `WWW-Authenticate` nonce differs from the one we used, or carries `stale=true`, is
  **not** a failed login: retry immediately, once, and it does not count as an attempt.
* A `401` in response to a request that already carried a correct-looking `Authorization` header
  counts as attempt 1. A second such `401` ⇒ `authRejected`, stop, **do not retry on any schedule**,
  set the camera's UI state to "Password rejected", and require explicit user action.
* `StreamController` and `ISAPIHTTPClient` share one per-device auth-failure counter, held by
  `StreamCoordinator`, so RTSP and ISAPI cannot each burn attempts independently.
* Before any reconnect on a camera whose credentials were just edited, `GET /ISAPI/Security/userCheck`
  is used as the cheap probe (`spec-isapi.md`), because it reports lockout state and remaining
  attempts.

### 7.6 Degraded mode (not an error state)

`degraded` means "showing video, but worse than it should be". Entry conditions (any):
packet loss > 5 % over 3 s; jitter > 80 ms; decoder dropping > 10 % of frames; sustained bitrate
< 40 % of the negotiated value; more than 2 gaps per second. Exit: all clear for 10 s. Degraded MUST
NOT tear down the session, MUST show the UX.md packet-loss banner, and MUST be recorded in the health
ring so the inspector graph explains what happened.

---

## 8. Observability

### 8.1 OSLog subsystem and categories

Subsystem: **`com.vigil.app`** (one subsystem, always). Categories are a fixed enum; do not invent
strings at call sites.

| Category | Used for | Default level |
|---|---|---|
| `app` | launch, scenes, windows, quit, migration | info |
| `discovery` | SADP/WS-Discovery/sweep progress, merge decisions | info |
| `rtsp` | method/status lines, session IDs (masked), state transitions | info; debug for full headers |
| `rtp` | gaps, resets, jitter-buffer overflow (rate-limited) | error only, debug for per-packet |
| `bitstream` | parameter-set changes, geometry changes, unsupported syntax | info |
| `isapi` | endpoint, status, ResponseStatus codes | info |
| `transport` | connect/disconnect, TLS, path changes, multicast | info |
| `video` | decode session lifecycle, format changes, VT errors, budget decisions | info |
| `render` | Metal init, pipeline compile, display changes, fallbacks | info |
| `core` | controller state machine, coordinator policy, recording, events | info |
| `storage` | config load/save, migrations, corruption recovery | info |
| `ui` | user-visible errors, command-palette actions | info |
| `perf` | signpost companions, budget breaches, frame-time p99 | info |

```swift
// VigilProtocols
public enum LogCategory: String, Sendable, CaseIterable {
    case app, discovery, rtsp, rtp, bitstream, isapi, transport, video, render, core, storage, ui, perf
}
public enum LogLevel: Int, Sendable, Comparable { case debug, info, notice, warning, error, fault }
```

### 8.2 The pure layer logs through an injected protocol

The pure layer cannot `import OSLog`. It logs through:

```swift
// VigilProtocols
public struct LogEvent: Sendable {
    public var level: LogLevel
    public var category: LogCategory
    public var message: String
    public var metadata: [String: String]     // MUST be pre-redacted by the caller
    public var file: StaticString
    public var line: UInt
}

public protocol LoggerProtocol: Sendable {
    /// Cheap gate so callers can skip building strings for disabled levels.
    func isEnabled(_ level: LogLevel, _ category: LogCategory) -> Bool
    func log(_ event: LogEvent)
}

public extension LoggerProtocol {
    @inline(__always)
    func debug(_ category: LogCategory, _ message: @autoclosure () -> String,
               _ metadata: @autoclosure () -> [String: String] = [:],
               file: StaticString = #fileID, line: UInt = #line) {
        guard isEnabled(.debug, category) else { return }        // no string built when disabled
        log(LogEvent(level: .debug, category: category, message: message(),
                     metadata: metadata(), file: file, line: line))
    }
    // …info, notice, warning, error, fault…
}

/// Default for tests and for code paths with no logger wired yet.
public struct NullLogger: LoggerProtocol {
    public init() {}
    public func isEnabled(_: LogLevel, _: LogCategory) -> Bool { false }
    public func log(_: LogEvent) {}
}

/// Test double: records everything so tests can assert on log content.
/// (Lives in VigilTestKit, not here.)
```

Every pure type takes `logger: any LoggerProtocol = NullLogger()` in its initialiser. Never a global.

The macOS adapter lives in `VigilCore`:

```swift
#if os(macOS)
import OSLog

public struct OSLogLogger: LoggerProtocol {
    private static let loggers: [LogCategory: Logger] = Dictionary(
        uniqueKeysWithValues: LogCategory.allCases.map {
            ($0, Logger(subsystem: "com.vigil.app", category: $0.rawValue))
        })
    public var minimumLevel: LogLevel

    public func isEnabled(_ level: LogLevel, _ category: LogCategory) -> Bool { level >= minimumLevel }

    public func log(_ event: LogEvent) {
        let logger = Self.loggers[event.category]!   // exhaustive by construction
        let line = event.metadata.isEmpty
            ? event.message
            : "\(event.message) \(event.metadata.sorted(by: { $0.key < $1.key }).map { "\($0)=\($1)" }.joined(separator: " "))"
        switch event.level {
        case .debug:   logger.debug("\(line, privacy: .public)")
        case .info:    logger.info("\(line, privacy: .public)")
        case .notice:  logger.notice("\(line, privacy: .public)")
        case .warning: logger.warning("\(line, privacy: .public)")
        case .error:   logger.error("\(line, privacy: .public)")
        case .fault:   logger.fault("\(line, privacy: .public)")
        }
    }
}
#endif
```

`privacy: .public` is correct **only because** §8.6 guarantees the string is already redacted. That is
the trade: we redact at the source so diagnostics bundles are useful, instead of relying on
`.private` and getting `<private>` in every support log.

### 8.3 Signposts

`OSSignposter` with the same subsystem, category `perf`. Intervals and events:

| Name | Kind | Begin → End | Metadata |
|---|---|---|---|
| `stream.connect` | interval | `start()` → first RTP packet | camera short ID, transport |
| `stream.firstFrame` | interval | `start()` → first frame on screen | codec, resolution |
| `rtsp.exchange` | interval | request written → response parsed | method, status |
| `frame.decode` | interval | `VTDecompressionSessionDecodeFrame` → output handler | pts, size, isKeyframe |
| `frame.present` | interval | `present(_:)` → drawable presented | pts |
| `layout.change` | interval | layout mutation → all tiles first-frame | mode, tile count |
| `discovery.scan` | interval | scan start → complete | method, found count |
| `frame.dropped` | event | — | stage (`preDecode`/`preDisplay`), reason |
| `budget.denied` | event | — | cost, camera |
| `reconnect` | event | — | attempt, delay, cause code |

`stream.firstFrame` is the app's headline metric; `Scripts/bench.sh` extracts it with
`xcrun xctrace` / `log stream --signpost` and asserts the FEATURES.md budget.

### 8.4 Per-stream statistics

Shape is fixed here; the update algebra (EWMA constants, jitter formula) is owned by `spec-rtp.md`.

```swift
public struct StreamStatistics: Sendable, Hashable, Codable {
    // Throughput
    public var framesDecoded: UInt64
    public var framesPerSecond: Double              // EWMA
    public var bitsPerSecond: Double                // EWMA
    public var keyframeIntervalSeconds: Double
    // Loss and order
    public var packetsReceived: UInt64
    public var packetsLost: UInt64
    public var packetsOutOfOrder: UInt64
    public var packetsDuplicated: UInt64
    public var lossFraction: Double                 // over the last 2 s window
    public var gapCount: UInt32
    // Timing
    public var jitterMilliseconds: Double           // RFC 3550 A.8, converted from timescale units
    public var jitterBufferDepthPackets: Int
    public var jitterBufferDepthMilliseconds: Double
    public var estimatedLatencyMilliseconds: Double // capture→display estimate, RTCP-anchored
    // Decode
    public var decodeQueueDepth: Int
    public var framesDroppedPreDecode: UInt64
    public var framesDroppedPreDisplay: UInt64
    public var decodeMillisecondsP50: Double
    public var decodeMillisecondsP99: Double
    public var isHardwareAccelerated: Bool
    // Session
    public var uptimeSeconds: Double
    public var reconnectCount: UInt32
    public var lastErrorCode: String?               // diagnosticCode, never a message
}
```

Sampled at 1 Hz by `HealthMonitor` into a fixed 600-slot ring (10 minutes) per camera. The ring is a
`struct` of a preallocated array — no allocation per sample, because 16 cameras × 1 Hz × 10 min must be
free.

### 8.5 Log volume control

* Per-packet logging is compiled out of release builds: `#if DEBUG` around `.debug`-level calls on the
  `rtp` and `rtsp` categories that fire per packet.
* Rate limiting: `RateLimitedLogger` decorator in `VigilProtocols` — at most N events per key per
  window (default 5 per 10 s per `(category, callsite)`), with a `"… suppressed \(k) similar"` summary.
  Every repeated-error path (jitter overflow, bad data, gap) MUST be wrapped in it.
* Log level is user-settable in Settings → Advanced (`debug`/`info`/`error`), persisted, and applied by
  swapping `OSLogLogger.minimumLevel` at the injection site.

### 8.6 Redaction — hard rules

Never log, in any form, at any level, in release or debug:

| Item | Rule |
|---|---|
| Passwords | never, not even lengths. `Credential` has `var description: String { "Credential(user: \(user), password: <redacted>)" }` and `CustomDebugStringConvertible` doing the same. |
| `Authorization` / `WWW-Authenticate` header values | log only the scheme and the realm; `response=` and `cnonce=` are elided. |
| RTSP `Session:` IDs | last 4 characters only: `…A31F`. |
| Camera serial numbers | first 2 + last 2: `DS…9K`. |
| URLs | strip userinfo; keep scheme/host/port/path. `URL.redactedForLogging`. |
| MAC addresses | last octet only in `info`; full only at `debug`. |
| Keychain data | never; log `OSStatus` codes only. |
| Snapshot/recording file paths | log the filename, not the user's directory tree. |

`VigilProtocols` provides `String.redactingSecrets()` (regex-driven, covers `password=`, `pwd=`,
`response=`, `Basic <b64>`) and the diagnostics bundle runs it over collected logs a **second** time as
defence in depth.

---

## 9. Persistence

### 9.1 Locations

| What | Path | Format |
|---|---|---|
| Library (cameras, groups, layouts, bookmarks) | `~/Library/Application Support/Vigil/library.json` | JSON, `schemaVersion` |
| Previous good copy | `~/Library/Application Support/Vigil/library.bak.json` | JSON |
| Quarantined corrupt copy | `…/Vigil/Corrupt/library-<ISO8601>.json` | JSON |
| Events (last 5000) | `…/Vigil/events.json` | JSON, separate file so a big event log never risks the library |
| Thumbnail cache | `~/Library/Caches/com.vigil.app/thumbnails/<uuid>.heic` | evictable, never backed up |
| Logs export | user-chosen, via save panel | `.zip` |
| Snapshots | user-chosen folder, default `~/Pictures/Vigil` | PNG/JPEG/HEIC |
| Recordings | user-chosen folder, default `~/Movies/Vigil` | MP4/MOV |
| Secrets | Keychain, `kSecClassInternetPassword` | — |
| UI-only preferences (window frames, sidebar width, last layout, appearance) | `UserDefaults` suite `com.vigil.app` | — |

**Sandbox note:** because the app is sandboxed (§13.4), the Snapshots and Recordings folders are
reached through **security-scoped bookmarks**. The bookmark `Data` (base64) is stored in
`library.json` under `folderBookmarks`, resolved at launch with
`URL(resolvingBookmarkData:options:.withSecurityScope,…)`, and wrapped in
`startAccessingSecurityScopedResource()` / `stopAccessing…` pairs. Storing a bare path string is
forbidden — it will silently fail to write. This is a cross-cutting rule for `spec-core.md`.

### 9.2 Atomic write

```swift
// actor ConfigStore
private func writeAtomically(_ document: LibraryDocument) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]   // stable diffs; the file is git-able
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(document)

    let dir = Self.supportDirectory
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    // 1. Rotate current -> .bak (best effort; a missing current is fine on first run).
    if FileManager.default.fileExists(atPath: url.path) {
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.copyItem(at: url, to: backupURL)
    }

    // 2. Write to a sibling temp file in the SAME volume, then atomically swap.
    let temp = dir.appendingPathComponent("library-\(UUID().uuidString).tmp")
    try data.write(to: temp, options: [.atomic])
    _ = try FileManager.default.replaceItemAt(url, withItemAt: temp,
                                             backupItemName: nil,
                                             options: [.usingNewMetadataOnly])
    // replaceItemAt removes `temp` on success. On throw, clean up.
}
```

Saves are **debounced 500 ms** and coalesced: `ConfigStore.markDirty()` restarts a 500 ms timer task;
at most one write is in flight. `ConfigStore.flush()` is awaited on quit, on
`applicationWillTerminate`, and before any export. A write is never skipped because of debounce — the
final state always lands.

### 9.3 Schema versioning and migration

```swift
public struct LibraryDocument: Codable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var cameras: [Camera]
    public var groups: [CameraGroup]
    public var layouts: [Layout]
    public var bookmarks: [Bookmark]
    public var folderBookmarks: [String: Data]
    public var settings: PersistedSettings
    public var updatedAt: Date
}

protocol Migration: Sendable {
    var from: Int { get }
    var to: Int { get }
    /// Operates on a loosely-typed JSON tree so old shapes need no retained Swift types.
    func migrate(_ json: inout [String: Any]) throws
}
```

Load algorithm:

1. Read bytes. Decode `{"schemaVersion": Int}` only (a tiny `VersionProbe: Decodable`).
2. `version > currentSchemaVersion` → throw `StorageError.schemaTooNew`. **Do not** write anything;
   show "This library was created by a newer version of Vigil." and open read-only. Silently
   downgrading destroys user data.
3. `version < current` → decode to `[String: Any]` via `JSONSerialization`, apply the migration chain
   in ascending order (`1→2`, `2→3`, …) — never a jump table, always the chain, so every path is
   exercised — re-serialise, decode into `LibraryDocument`, write immediately, log at `notice`.
4. `version == current` → decode directly.
5. Any decode failure → try `library.bak.json` (same algorithm). Success ⇒ log `warning`, notify the
   user once ("Recovered your camera list from a backup.").
6. Both fail ⇒ move both to `Corrupt/`, start empty, show a non-modal recovery banner offering
   "Reveal corrupted file in Finder". **Never silently start empty without telling the user.**

Migration tests are mandatory: `Tests/VigilCoreTests/Fixtures/library-v1.json`, `-v2.json`, … each with
a test that migrates it to current and asserts the resulting `LibraryDocument`. Every schema bump adds
a fixture in the same commit.

### 9.4 Why JSON and not SwiftData/CoreData

| Reason | Detail |
|---|---|
| Diffable and inspectable | users and support can read and hand-edit the file; it survives in git |
| No store-migration risk | CoreData lightweight migration failing in the field leaves users with no cameras; our chain is plain code with fixtures |
| Trivially exportable | the export/import feature (FEATURES.md) is `cp` plus redaction |
| Correct scale | a big deployment is ~200 cameras; the document is < 200 KB and loads in < 5 ms |
| No dependency on a framework's threading model | `ConfigStore` is one actor; no `NSManagedObjectContext` confinement rules |

**When we would change:** past ~10 000 records, or when events need range queries, we move *events*
(not the library) to SQLite via the built-in `libsqlite3` C API — still zero SPM dependencies. The
library document itself stays JSON.

---

## 10. Testing strategy

### 10.1 What runs where

| Target | Linux CI | macOS CI | Notes |
|---|---|---|---|
| `VigilProtocolsTests` | ✅ | ✅ | MD5 RFC 1321 vectors, bit/byte readers, `MediaTimestamp` algebra, redaction |
| `VigilBitstreamTests` | ✅ | ✅ | real base64 SPS/PPS from Hikvision cameras → expected geometry; avcC/hvcC byte-exact |
| `VigilRTSPTests` | ✅ | ✅ | message parse/serialise, Digest vectors, SDP corpus, interleaved desync recovery, state machine transcripts |
| `VigilRTPTests` | ✅ | ✅ | FU-A/FU reassembly, STAP-A/AP, AU boundaries, seq wrap, jitter buffer, RFC 3550 jitter |
| `VigilISAPITests` | ✅ | ✅ | XML corpus per firmware; `HTTPTransporting` fake — **no sockets** |
| `VigilDiscoveryTests` | ✅ | ✅ | recorded SADP/WS-Discovery bytes, CIDR maths, merge/dedupe |
| `VigilPipelineTests` | ✅ | ✅ | **the end-to-end pure pipeline against `SyntheticCamera`** |
| `VigilTransportTests` | ⬜ | ✅ | `NWListener` on `127.0.0.1` hosting `SyntheticRTSPServer`; TLS; path changes |
| `VigilVideoTests` | ⬜ | ✅ | real `VTDecompressionSession` on golden clips; format change; budget policy |
| `VigilRenderTests` | ⬜ | ✅ | Metal pipeline compile, YUV→RGB reference-image comparison, SAR/crop geometry |
| `VigilCoreTests` | ⬜ | ✅ | controller state machine with fakes, migrations, Keychain (a dedicated test keychain), recorder |
| `VigilUITests` | ⬜ | ✅ | snapshot tests of components in both appearances; token contrast assertions |

Coverage floors, enforced by `Scripts/coverage.sh`: **90 %** lines for every pure target, **70 %** for
macOS targets. A pure target below 90 % fails CI.

### 10.2 `VigilTestKit` — the synthetic camera

This is the most important test asset in the repository. It makes the entire pure pipeline testable
with **no camera, no sockets, no Mac, and no wall clock**, and it is what lets us assert behaviour on
the failure modes real Hikvision firmware exhibits.

Design principle: the synthetic server is a **pure byte function**, not a network service.

```swift
// Sources/VigilTestKit/SyntheticCamera.swift

/// Everything about the camera we are pretending to be.
public struct SyntheticCameraProfile: Sendable {
    public enum Model: Sendable {
        case ipCamera(model: String)      // e.g. "DS-2CD2143G2-I": 1 video track, optional audio
        case nvr(channels: Int)           // e.g. DS-7608: /Streaming/Channels/{ch}01
        case analogEncoder                // interlaced, 704x576
    }
    public var model: Model
    public var firmware: String                      // affects header casing and SDP extras
    public var videoCodec: VideoCodec                // .h264 | .h265 | .mjpeg
    public var audioCodec: AudioCodec?               // nil = video only
    public var width: Int, height: Int
    public var frameRate: Double                     // 25, 30, 12.5, 20…
    public var gopLength: Int                        // frames between IRAPs
    public var bitrateKbps: Int
    public var authMode: AuthMode                    // .none | .basic | .digestQopAuth | .digestNoQop
    public var username: String, password: String
    public var sessionTimeoutSeconds: Int            // advertised in SETUP
    public var supportsGetParameter: Bool
    public var quirks: Set<Quirk>
    public var seed: UInt64                          // drives ALL randomness; print it on failure

    public static func ds2cd2143g2(seed: UInt64 = 0x5649_4749_4C00) -> Self
    public static func ds7608nvr(channels: Int = 8, seed: UInt64 = 0x5649_4749_4C00) -> Self
    public static func hevcCamera(seed: UInt64 = 0x5649_4749_4C00) -> Self
    public static func mjpegCamera(seed: UInt64 = 0x5649_4749_4C00) -> Self
}
```

#### Quirks — the fault-injection vocabulary

Each quirk reproduces something a real Hikvision device or network actually does. Tests name the
quirk, so a failure report reads like a bug report.

```swift
public enum Quirk: Hashable, Sendable {
    // ── RTSP / transport shape ──────────────────────────────────────────────
    case slowDrip(bytesPerRead: Int)          // TCP delivers 7 bytes at a time; parser must accumulate
    case splitInterleavedHeader               // the 4-byte $ header straddles two reads
    case responseAndMediaInSameRead           // an RTSP 200 and an RTP frame in one TCP segment
    case jumboHeader(bytes: Int)              // 64 KB of headers; must hit headerTooLarge, not OOM
    case missingContentLength                 // body must be read to connection close
    case crOnlyLineEndings                    // firmware that emits \r instead of \r\n
    case lowercaseHeaderNames                 // "cseq:" instead of "CSeq:"
    case extraSDPAttributes                   // a=Media_header, a=appversion, unknown a= lines
    case truncatedSDP
    case absoluteControlURL                   // a=control: rtsp://<other-host>/track1
    case noContentBase                        // control URL must resolve against the request URI
    case tcpHalfClose(afterBytes: Int)
    case garbageBeforeResponse(bytes: Int)    // forces interleave resynchronisation
    // ── Auth ────────────────────────────────────────────────────────────────
    case digestStaleNonce(afterRequests: Int) // 401 stale=TRUE mid-session
    case rotateNonceEveryRequest
    case wrongPasswordAlways                  // asserts we stop at 2 attempts, never 5
    case accountLocked(retryAfterSeconds: Int)
    // ── RTP ─────────────────────────────────────────────────────────────────
    case unreliableMarkerBit                  // marker set on random packets, cleared on real AU ends
    case packetLoss(rate: Double)             // 0.0…1.0, deterministic from seed
    case reorder(windowPackets: Int)
    case duplicate(rate: Double)
    case sequenceWrapSoon                     // start seq at 65_500
    case timestampWrapSoon                    // start RTP ts at 0xFFFF_F000
    case startMidGOP                          // first packets are non-IRAP slices; must drop to IRAP
    case parameterSetsOnlyInBand              // no sprop-parameter-sets in SDP
    case parameterSetsOnlyInSDP               // never repeated in band
    case midStreamResolutionChange(atFrame: Int, newWidth: Int, newHeight: Int)
    case aggregationPackets                   // STAP-A (H.264) / AP (H.265) heavy
    case donlPresent(maxDonDiff: Int)         // H.265 DONL field present
    case rtcpByeAfter(seconds: Double)
    case noRTCP
    case audioInterleavedOutOfOrder
}
```

#### The server API

```swift
/// A Hikvision camera that exists only as a function from client bytes to server bytes.
///
/// No sockets. No threads. No clock. Drive it from a test loop; every run is byte-identical for a
/// given `profile.seed`.
public struct SyntheticRTSPServer: Sendable {

    public init(profile: SyntheticCameraProfile)

    /// Feed bytes the client wrote. Returns bytes the server writes back **immediately**
    /// (responses only; media comes from `tick`). May return empty.
    public mutating func ingest(_ bytes: Data) -> Data

    /// Advance the virtual clock to `nowNanos`. Returns interleaved media/RTCP bytes that the
    /// camera would have sent by now, honouring `frameRate`, `gopLength` and every quirk.
    /// Idempotent for a non-advancing `now`.
    public mutating func tick(nowNanos: UInt64) -> Data

    /// Inspection for assertions.
    public var receivedRequests: [RTSPRequest] { get }
    public var state: SyntheticSessionState { get }   // .init, .described, .setUp, .playing, .torndown
    public var sentFrameCount: Int { get }
    public var advertisedSDP: String { get }
    public var groundTruth: GroundTruth { get }
}

/// What the server *intended* to send — the oracle every pipeline test compares against.
public struct GroundTruth: Sendable {
    public var frames: [ExpectedFrame]
    public var parameterSets: ParameterSets
    public var geometry: (width: Int, height: Int, sarNum: Int, sarDen: Int, fps: Double)
    public var injectedPacketLosses: [UInt16]          // RTP sequence numbers actually dropped
    public var expectedRecoverableFrameLosses: Int     // frames the client is allowed to miss
}

public struct ExpectedFrame: Sendable, Hashable {
    public var index: Int
    public var pts: MediaTimestamp
    public var isKeyframe: Bool
    public var nalTypes: [UInt8]
    public var byteCount: Int
    public var payloadChecksum: UInt32     // CRC-32 of the length-prefixed AU we generated
}
```

#### The RTP generator

```swift
/// Produces RFC 6184 / RFC 7798 / RFC 3640 / G.711 packet streams from synthetic access units.
public struct RTPStreamGenerator: Sendable {
    public init(profile: SyntheticCameraProfile, ssrc: UInt32, startSequence: UInt16,
                startTimestamp: UInt32)

    /// One access unit, already fragmented/aggregated per the profile's MTU and quirks.
    public mutating func nextAccessUnit(nowNanos: UInt64) -> [RTPPacketBytes]

    public mutating func receiverReportDue(nowNanos: UInt64) -> Data?
    public mutating func senderReport(nowNanos: UInt64) -> Data      // with NTP for clock mapping
    public var mtu: Int { get set }                                  // default 1400
}

/// Two tiers of payload realism. Pick per test; the API is identical.
public enum PayloadRealism: Sendable {
    /// Syntactically valid NALs (real SPS/PPS/VPS built with BitWriter; slices with valid headers
    /// and filler payload). Parses correctly; will NOT decode to an image. Linux-safe, fast,
    /// and sufficient for every pure test.
    case syntactic
    /// Real captured GOPs from `Tests/Fixtures/Clips/*.vgclip`. Decodes on a Mac. Used by
    /// VigilVideoTests and VigilRenderTests.
    case recorded(clip: String)
}
```

The `syntactic` tier is what makes this work on Linux: `SyntheticEncoder` builds a **real, spec-valid**
H.264 SPS/PPS (and H.265 VPS/SPS/PPS) with `BitWriter` from the profile's width/height/fps, so
`VigilBitstream` parses it and derives exactly the geometry in `GroundTruth`. Slice NALs carry a valid
`first_mb_in_slice`/`slice_type`/`pic_parameter_set_id` prefix followed by pseudorandom filler sized to
hit `bitrateKbps`. Nothing in the pure pipeline needs the residual data to be decodable — and the AU
boundary tests specifically need `first_mb_in_slice == 0` to be *real*, which it is.

#### The harness

```swift
/// Wires SyntheticRTSPServer ↔ RTSPSessionMachine ↔ demux ↔ JitterBuffer ↔ Depacketizer
/// and runs the whole thing on a virtual clock, with an in-memory "wire".
public struct PipelineHarness: Sendable {

    public init(profile: SyntheticCameraProfile,
                clientConfiguration: RTSPConfiguration = .default,
                realism: PayloadRealism = .syntactic,
                logger: any LoggerProtocol = RecordingLogger())

    /// Run until `frames` access units have been delivered, or `virtualTimeout` elapses.
    /// Advances the virtual clock in `stepNanos` increments (default 1 ms).
    public mutating func run(untilFrames frames: Int,
                             virtualTimeout: Duration = .seconds(30),
                             stepNanos: UInt64 = 1_000_000) throws -> HarnessReport

    /// Run for a fixed span of virtual time (for loss/degradation tests).
    public mutating func run(forVirtualTime span: Duration) throws -> HarnessReport

    /// Deliberately partition the wire, to test read-idle and reconnect.
    public mutating func partitionWire(forVirtualTime span: Duration)
    public mutating func closeWire()
}

public struct HarnessReport: Sendable {
    public var frames: [EncodedFrame]
    public var statistics: StreamStatistics
    public var groundTruth: GroundTruth
    public var rtspRequests: [RTSPRequest]
    public var rtspResponses: [RTSPResponse]
    public var events: [RTSPEvent]
    public var logEvents: [LogEvent]
    public var peakBufferedBytes: Int          // asserts we never buffer unboundedly
    public var virtualElapsed: Duration
    public var clientErrors: [VigilError]

    // Convenience assertions used by tests.
    public func assertFramesMatchGroundTruth(allowingLoss: Bool) throws
    public func assertMonotonicPTS() throws
    public func assertFirstFrameIsKeyframe() throws
    public func assertNoUnboundedGrowth(limitBytes: Int) throws
}
```

#### The mandatory test matrix

`VigilPipelineTests` MUST contain at least one test per row. Each is parameterised over
`[.h264, .h265]` and over `[.digestQopAuth, .digestNoQop, .basic]` where relevant.

| # | Scenario | Assertion |
|---|---|---|
| 1 | Happy path, IP camera, TCP interleaved, 100 frames | frames == ground truth, checksums match, first frame is keyframe, PTS monotonic, loss 0 |
| 2 | Happy path, H.265 with VPS | `ParameterSets.vps.count == 1`, geometry matches conformance-window maths |
| 3 | NVR channel 3 substream | request URI is `/Streaming/Channels/302`, session established |
| 4 | `slowDrip(bytesPerRead: 7)` | identical result to #1 |
| 5 | `splitInterleavedHeader` + `responseAndMediaInSameRead` | identical to #1 |
| 6 | `jumboHeader(bytes: 65_536)` | throws `RTSPError.headerTooLarge`; `peakBufferedBytes < 128 KB` |
| 7 | `garbageBeforeResponse(bytes: 999)` | resynchronises; ≤ 1 frame lost; logs one `interleaveDesync(recovered: true)` |
| 8 | `digestStaleNonce(afterRequests: 3)` | re-authenticates, session continues, auth attempt counter stays 0 |
| 9 | `wrongPasswordAlways` | exactly **2** authenticated requests are sent, then `authRejected`; **never 5** |
| 10 | `accountLocked` | surfaces `ISAPIError.accountLocked`, no retry |
| 11 | `packetLoss(rate: 0.02)` | frames == ground truth minus `expectedRecoverableFrameLosses`; `lossFraction` within ±0.5 % of 2 %; recovery to a keyframe within one GOP |
| 12 | `reorder(windowPackets: 8)` | zero frame loss (jitter buffer reorders); `packetsOutOfOrder > 0` |
| 13 | `duplicate(rate: 0.05)` | zero duplicate frames emitted; `packetsDuplicated > 0` |
| 14 | `unreliableMarkerBit` | frame count exactly matches ground truth — proves slice-header AU detection |
| 15 | `sequenceWrapSoon` running past 65 535 | no loss, no reset |
| 16 | `timestampWrapSoon` running past 2³² | PTS remains monotonic after unwrapping |
| 17 | `startMidGOP` | all frames before the first IRAP are dropped; first delivered frame is a keyframe |
| 18 | `parameterSetsOnlyInBand` | geometry derived from in-band SPS; first frame still a keyframe |
| 19 | `parameterSetsOnlyInSDP` | decoding config comes from `sprop-parameter-sets` |
| 20 | `midStreamResolutionChange(atFrame: 50, …)` | a second `ParameterSets` is attached at the boundary frame; no frames lost around it |
| 21 | `aggregationPackets` | STAP-A/AP correctly split into separate NALs |
| 22 | `donlPresent(maxDonDiff: 1)` | H.265 FU DONL parsed, frames intact |
| 23 | AAC audio alongside video | audio AUs have correct timescale; ADTS/ASC derived from `config=1210` |
| 24 | G.711 PCMA audio | 160-sample packets at 8 kHz, PTS spacing 20 ms |
| 25 | `rtcpByeAfter(seconds: 5)` | client observes `closed`, transitions to `reconnecting` |
| 26 | `noRTCP` | latency estimate falls back to arrival-time heuristic; no error |
| 27 | `tcpHalfClose(afterBytes: 50_000)` | `TransportError.peerClosed`, backoff attempt 0 = 0.5 s ±20 % |
| 28 | `partitionWire(forVirtualTime: .seconds(10))` | read-idle fires at 8 s ±100 ms |
| 29 | `crOnlyLineEndings`, `lowercaseHeaderNames`, `extraSDPAttributes` | identical to #1 |
| 30 | `absoluteControlURL`, `noContentBase` | control URL resolution matches `spec-rtsp.md` precedence |
| 31 | 30-minute virtual soak at 30 fps (54 000 frames) | `peakBufferedBytes` bounded; no growth in retained frames; runs in < 20 s wall clock |
| 32 | Fuzz: 2 000 iterations of random byte mutation of a valid transcript, seeded | never throws anything but a `VigilError`; never hangs; never allocates > 4 MB |

Test #31 and #32 are the reason the harness must be a pure function of virtual time: they are
impossible to run in CI otherwise.

#### macOS bridge

For `VigilTransportTests`, the same `SyntheticRTSPServer` is wrapped in a real socket:

```swift
#if os(macOS)
/// Hosts a SyntheticRTSPServer on 127.0.0.1 with an OS-assigned port, so the real
/// NWConnection-based RTSPConnection can be tested against the same fixture and quirks.
public actor LoopbackRTSPListener {
    public init(profile: SyntheticCameraProfile) throws
    public var port: UInt16 { get }
    public func start() throws
    public func stop()
    public var groundTruth: GroundTruth { get }
}
#endif
```

Note the payoff: a quirk written once is exercised by both the pure harness and the real socket path.

### 10.3 Golden fixture formats

| Extension | Contents | Used by |
|---|---|---|
| `.rtsptranscript` | UTF-8 text; lines prefixed `C> ` / `S> ` for direction, `\r\n` escaped as `\\r\\n`, `#` comments | `VigilRTSPTests` |
| `.sdp` | raw SDP as captured | `VigilRTSPTests` |
| `.vrtp` | binary: `"VRTP"` magic, `u8` version, then records of `u64` monotonic-ns + `u16` length + payload | `VigilRTPTests` |
| `.vgclip` | binary: `"VGCL"` magic, `u8` version, `u8` codec, `u16`×2 dimensions, `u32` fps×1000, parameter-set block, then `u32` length + `u64` pts records of length-prefixed AUs | `VigilVideoTests`, `VigilRenderTests` |
| `.xml` | ISAPI responses, one file per endpoint per firmware, named `deviceInfo-5.5.82.xml` | `VigilISAPITests` |
| `.sadp` / `.wsd` | raw UDP payload bytes | `VigilDiscoveryTests` |

`VigilTestKit` provides readers and writers for all of these, plus `Fixtures.url(named:in:)` which
resolves through `Bundle.module` and works identically on Linux and macOS.

### 10.4 Test style

* Swift Testing: `@Test`, `#expect`, `#require`, `@Test(arguments:)` for parameterisation,
  `@Suite(.serialized)` only where an actual shared resource forces it (the test keychain).
* Every test that involves randomness prints the seed in the failure message:
  `#expect(x == y, "seed=\(profile.seed)")`.
* `.timeLimit(.minutes(1))` on every test; the soak test gets `.minutes(3)`.
* No test may touch the network, the user's keychain, `~/Library/Application Support/Vigil`, or sleep
  on a real clock. `Scripts/lint.sh` greps test sources for `Thread.sleep`, `URLSession.shared`, and
  the real support-directory path.
* macOS Keychain tests use a dedicated file-based keychain created in a temp directory and deleted in
  a `deinit`/teardown; they never write to the login keychain.

---

## 11. Repository layout

```
/
├── Package.swift
├── Package.resolved                 # committed; will contain no dependencies (proof of C1)
├── README.md
├── LICENSE
├── .gitignore
├── .swift-format                    # config for `swift format` (ships with the toolchain)
├── project.yml                      # XcodeGen input (§12.4)
├── Info.plist                       # app bundle Info.plist (§13.1)
├── Vigil.entitlements               # sandboxed, shipping (§13.3)
├── Vigil-Dev.entitlements           # unsandboxed developer build (§13.4)
│
├── .github/workflows/
│   ├── linux.yml                    # swift:6.1-noble — pure build + full test run
│   ├── macos.yml                    # macos-14 — full build, full tests, app assembly
│   └── lint.yml                     # swift format lint + Scripts/lint.sh
│
├── Scripts/
│   ├── build-app.sh                 # THE contract (§12)
│   ├── test-linux.sh
│   ├── test-macos.sh
│   ├── lint.sh                      # format lint + import allow-list + banned patterns
│   ├── coverage.sh
│   ├── bench.sh                     # signpost-driven latency/CPU benchmark
│   ├── gen-xcode.sh                 # xcodegen generate (optional, documented as such)
│   └── make-icon.sh                 # iconutil from Sources/VigilUI/Resources/AppIcon.iconset
│
├── Sources/
│   ├── VigilProtocols/
│   │   ├── Bytes/                   ByteReader.swift ByteWriter.swift BitReader.swift BitWriter.swift
│   │   ├── Time/                    MediaTimestamp.swift Clocks.swift RandomSource.swift
│   │   ├── Media/                   EncodedFrame.swift ParameterSets.swift Codecs.swift
│   │   ├── Errors/                  VigilError.swift DomainErrors.swift DiagnosticCodes.swift
│   │   ├── Logging/                 LoggerProtocol.swift RateLimitedLogger.swift Redaction.swift
│   │   ├── Crypto/                  MD5.swift Base64.swift CRC32.swift
│   │   ├── Net/                     HTTPTransporting.swift Credential.swift
│   │   └── Stats/                   StreamStatistics.swift RingBuffer.swift
│   ├── VigilBitstream/              NAL/ H264/ H265/ Records/ Convert/
│   ├── VigilRTSP/                   Message/ Auth/ SDP/ Machine/ URLs/
│   ├── VigilRTP/                    Packet/ Depacketize/ Jitter/ RTCP/ Stats/
│   ├── VigilISAPI/                  Client/ XML/ Endpoints/ Models/ Events/
│   ├── VigilDiscovery/              SADP/ WSDiscovery/ Sweep/ Merge/
│   ├── VigilTestKit/                Synthetic/ Generators/ Harness/ Fixtures/ Doubles/
│   ├── VigilTransport/              RTSPConnection.swift UDPMediaSocketPair.swift TLS/ Multicast/
│   ├── VigilVideo/                  Decode/ Format/ Budget/ Audio/ Snapshot/
│   ├── VigilRender/
│   │   ├── Shaders/                 VideoPass.metal Overlay.metal (compiled to default.metallib)
│   │   ├── Metal/                   MetalContext.swift VideoRenderer.swift TextureCache.swift
│   │   ├── Views/                   VideoTileView.swift VideoTileRepresentable.swift
│   │   └── Interaction/             ZoomPanController.swift PTZDragController.swift
│   ├── VigilCore/
│   │   ├── Model/                   Camera.swift CameraGroup.swift Layout.swift Events.swift
│   │   ├── Persistence/             ConfigStore.swift LibraryDocument.swift Migrations/
│   │   ├── Security/                CredentialStore.swift
│   │   ├── Streaming/               StreamController.swift StreamCoordinator.swift RetryPolicy.swift
│   │   ├── Recording/               ClipRecorder.swift PreRollBuffer.swift
│   │   ├── Diagnostics/             HealthMonitor.swift StreamDoctor.swift DiagnosticsBundle.swift
│   │   ├── Intents/                 AppIntents + URL scheme
│   │   └── Logging/                 OSLogLogger.swift
│   ├── VigilUI/
│   │   ├── Theme/                   VTheme.swift Colors.swift Typography.swift Motion.swift
│   │   ├── Components/              V*.swift
│   │   ├── Screens/                 MainWindow/ Playback/ Discovery/ Settings/ VideoWall/
│   │   ├── Resources/               Assets.xcassets, AppIcon.iconset
│   │   └── Localizations/           en.lproj/ ru.lproj/
│   └── Vigil/                       main.swift VigilApp.swift Menus.swift WindowManagement.swift
│
├── Tests/
│   ├── VigilProtocolsTests/ … VigilPipelineTests/ (each with Fixtures/)
│   └── Fixtures/Clips/              shared .vgclip golden clips (git-lfs NOT used; keep < 2 MB each)
│
└── docs/                            ARCHITECTURE.md DESIGN.md UX.md FEATURES.md spec-*.md
```

Directory rules: one type per file, filename == type name; grouping directories are for humans and do
not affect module boundaries; no file exceeds **600 lines** (split by `MARK` boundaries into
`Type+Feature.swift` extensions instead).

---

## 12. Build

### 12.1 `Scripts/build-app.sh` — the contract

`Scripts/build-app.sh` is the only supported way to produce a runnable `Vigil.app`. Its behaviour is
part of the architecture, not an implementation detail.

**Invocation**

```
Scripts/build-app.sh [--configuration debug|release] [--arch arm64|x86_64|universal]
                     [--sign IDENTITY|-] [--entitlements PATH] [--sandbox on|off]
                     [--version X.Y.Z] [--build N] [--dmg] [--notarize] [--output DIR]
```

**Defaults:** `--configuration release --arch universal --sign - --sandbox on --output dist`.
Version defaults to the value in `Info.plist`; build number defaults to
`$(git rev-list --count HEAD)`.

**Behaviour, in order (each step must be idempotent and must fail the script on error via `set -euo pipefail`):**

| Step | Action | Failure |
|---|---|---|
| 1 | Verify toolchain: `swift --version` ≥ 6.0, `xcrun --sdk macosx --show-sdk-version` ≥ 14 | exit 2 |
| 2 | Verify no SPM dependencies: `Package.resolved` has an empty pin list | exit 3 |
| 3 | `swift build -c $CONFIG --arch arm64 --arch x86_64 --product Vigil` (one command produces the universal binary; a single `--arch` for non-universal) | exit 4 |
| 4 | Create `$OUTPUT/Vigil.app/Contents/{MacOS,Resources,Frameworks,Resources/*.lproj}` | exit 5 |
| 5 | Copy the executable to `Contents/MacOS/Vigil`; `chmod 755` | exit 5 |
| 6 | Copy `Info.plist` to `Contents/Info.plist`; substitute `$(VIGIL_VERSION)`, `$(VIGIL_BUILD)` with `/usr/libexec/PlistBuddy` | exit 6 |
| 7 | Write `Contents/PkgInfo` containing exactly `APPL????` | exit 6 |
| 8 | Copy SwiftPM resource bundles (`.build/**/Vigil_VigilUI.bundle`, `Vigil_VigilRender.bundle`) into `Contents/Resources/` — **these carry `Assets.car`, `default.metallib` and the `.lproj` folders; forgetting them yields an app with no icons and no shaders** | exit 7 |
| 9 | `actool` is **not** invoked directly — SwiftPM already compiled the catalog into the bundle. The app icon is additionally emitted as `Contents/Resources/AppIcon.icns` via `Scripts/make-icon.sh` because `CFBundleIconFile` needs a real `.icns` for the Dock on first launch before the catalog is registered | exit 7 |
| 10 | Choose entitlements: `--entitlements` if given, else `Vigil.entitlements` when `--sandbox on`, else `Vigil-Dev.entitlements` | exit 8 |
| 11 | `codesign --force --sign "$IDENTITY" --options runtime --timestamp --entitlements "$ENT" --generate-entitlement-der "$APP"` (nested bundles signed inside-out first) | exit 9 |
| 12 | `codesign --verify --deep --strict --verbose=2 "$APP"` and `spctl --assess --type execute` (non-fatal warning for ad-hoc `-`) | exit 9 |
| 13 | If `--dmg`: `hdiutil create -volname Vigil -srcfolder "$APP" -ov -format UDZO "$OUTPUT/Vigil-$VERSION.dmg"` | exit 10 |
| 14 | If `--notarize`: `xcrun notarytool submit --wait --keychain-profile VigilNotary`, then `xcrun stapler staple` | exit 11 |
| 15 | Print a summary: path, size, arch list from `lipo -info`, signing identity, entitlements digest, and the `codesign -d --entitlements -` dump | — |

**Guarantees the script must provide:**

* Running it twice in a row produces a byte-identical bundle apart from the signature and timestamp.
* It never requires network access unless `--notarize` is passed.
* With `--sign -` (the default) the produced app **launches on the build machine** — ad-hoc signing plus
  hardened runtime is sufficient for local use; it just will not pass Gatekeeper elsewhere.
* It emits a machine-readable `$OUTPUT/build-manifest.json` (version, build, commit, arch, entitlements
  file, signing identity, timestamps) for the release process.

### 12.2 CI commands

```yaml
# .github/workflows/linux.yml (container: swift:6.1-noble)
- run: swift build --product VigilPure -Xswiftc -warnings-as-errors
- run: swift build --product VigilTestKit -Xswiftc -warnings-as-errors
- run: swift build -Xswiftc -warnings-as-errors          # proves the #if guards compile everywhere
- run: swift test --parallel                              # macOS-only targets contribute 0 tests
- run: Scripts/test-linux.sh                              # asserts non-zero test counts per pure target
```

```yaml
# .github/workflows/macos.yml (runs-on: macos-14)
- run: swift build -c debug -Xswiftc -warnings-as-errors
- run: swift test --parallel --enable-code-coverage
- run: Scripts/coverage.sh                                # 90% pure / 70% macOS floors
- run: Scripts/lint.sh
- run: Scripts/build-app.sh --configuration release --arch universal
- run: Scripts/bench.sh --smoke                           # synthetic-camera latency smoke test
```

### 12.3 `Info.plist` keys

| Key | Value | Why |
|---|---|---|
| `CFBundleIdentifier` | `com.vigil.app` | matches the OSLog subsystem and the `UserDefaults` suite |
| `CFBundleName` | `Vigil` | |
| `CFBundleDisplayName` | `Vigil` | |
| `CFBundleExecutable` | `Vigil` | |
| `CFBundlePackageType` | `APPL` | |
| `CFBundleShortVersionString` | `$(VIGIL_VERSION)` | e.g. `1.0.0` |
| `CFBundleVersion` | `$(VIGIL_BUILD)` | git commit count |
| `CFBundleIconFile` | `AppIcon` | `.icns` in Resources (§12.1 step 9) |
| `CFBundleIconName` | `AppIcon` | asset-catalog name |
| `LSMinimumSystemVersion` | `14.0` | must match `platforms: [.macOS(.v14)]` |
| `LSApplicationCategoryType` | `public.app-category.video` | |
| `NSHumanReadableCopyright` | `© 2026 Vigil` | |
| `NSPrincipalClass` | `NSApplication` | |
| `NSHighResolutionCapable` | `true` | Retina; without it Metal layers render at 1× |
| `NSSupportsAutomaticTermination` | `false` | we hold live network sessions |
| `NSSupportsSuddenTermination` | `false` | recordings must be finalised on quit |
| **`NSLocalNetworkUsageDescription`** | `Vigil finds and connects to cameras on your local network. It never sends video anywhere else.` | macOS 15+ prompts for local network access; without this string the prompt shows a generic message and discovery silently fails on first run if denied |
| **`NSAppTransportSecurity`** | dict, below | Hikvision ISAPI is plain HTTP on port 80 by default and TLS certs are self-signed |
| `NSMicrophoneUsageDescription` | `Vigil uses your microphone for two-way audio with cameras that support it.` | required by the two-way-audio feature |
| `NSCameraUsageDescription` | *omitted* | we never open a local camera |
| `CFBundleURLTypes` | one entry, scheme `vigil` | deep links (`vigil://camera/<uuid>`) |
| `CFBundleDocumentTypes` | see below | `.vigilconfig` import/export, plus read-only viewing of `.mp4`/`.mov` clips |
| `UTExportedTypeDeclarations` | `com.vigil.config` conforming to `public.json`, extension `vigilconfig` | our export format |
| `NSUserActivityTypes` | `com.vigil.app.viewCamera` | Handoff-less, but used by App Intents/Spotlight |
| `ITSAppUsesNonExemptEncryption` | `false` | we use MD5 for Digest auth and TLS from the OS only; no custom crypto exported |

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <!-- Cameras are LAN devices. ATS's public-CA requirements cannot apply to a 192.168.x.y box. -->
    <key>NSAllowsLocalNetworking</key>
    <true/>
    <!-- We do NOT set NSAllowsArbitraryLoads. Non-local plain HTTP stays blocked, which is a real
         safety property: a mistyped public host cannot silently exfiltrate credentials in the clear. -->
</dict>
```

```xml
<key>CFBundleDocumentTypes</key>
<array>
    <dict>
        <key>CFBundleTypeName</key><string>Vigil Configuration</string>
        <key>CFBundleTypeRole</key><string>Editor</string>
        <key>LSHandlerRank</key><string>Owner</string>
        <key>LSItemContentTypes</key><array><string>com.vigil.config</string></array>
    </dict>
    <dict>
        <key>CFBundleTypeName</key><string>Video Clip</string>
        <key>CFBundleTypeRole</key><string>Viewer</string>
        <key>LSHandlerRank</key><string>Alternate</string>
        <key>LSItemContentTypes</key>
        <array><string>public.mpeg-4</string><string>com.apple.quicktime-movie</string></array>
    </dict>
</array>
```

**RTSP is not registered as a URL scheme handler.** Claiming `rtsp://` system-wide would hijack other
apps' links; users add cameras inside Vigil.

### 12.4 `project.yml` (XcodeGen)

The primary Xcode workflow is "open `Package.swift`" — that already works and needs no project. A
`project.yml` exists only for engineers who want a `.xcodeproj` with schemes, a run destination and a
signing team configured in the UI. It defines **one** target, the app, which links the local SwiftPM
package; it does **not** duplicate the source file lists.

```yaml
name: Vigil
options:
  bundleIdPrefix: com.vigil
  deploymentTarget: { macOS: "14.0" }
  createIntermediateGroups: true
  generateEmptyDirectories: false
packages:
  Vigil: { path: . }
targets:
  Vigil:
    type: application
    platform: macOS
    sources:
      - path: Sources/Vigil
    dependencies:
      - package: Vigil
        product: VigilApp
    info:
      path: Info.plist
    entitlements:
      path: Vigil.entitlements
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.vigil.app
        SWIFT_VERSION: "6.0"
        SWIFT_STRICT_CONCURRENCY: complete
        ENABLE_HARDENED_RUNTIME: YES
        ENABLE_APP_SANDBOX: YES
        SWIFT_TREAT_WARNINGS_AS_ERRORS: YES
        CODE_SIGN_ENTITLEMENTS: Vigil.entitlements
schemes:
  Vigil:
    build: { targets: { Vigil: all } }
    run: { config: Debug }
    test: { config: Debug, gatherCoverageData: true }
```

`.xcodeproj` is git-ignored (§11). Regenerate with `Scripts/gen-xcode.sh`. **No hand-written
`.pbxproj` may ever be committed.**

---

## 13. Sandbox, entitlements and hardened runtime

### 13.1 The sandbox decision — explicit justification

**Decision: the shipping app is sandboxed (`com.apple.security.app-sandbox = true`).**

Reasoning, weighed honestly:

*For sandboxing*
1. Vigil connects to untrusted-by-construction devices and parses **attacker-controllable byte streams**
   (RTSP headers, SDP, RTP payloads, SPS/PPS bitstreams, ISAPI XML) with code we wrote ourselves. A
   parsing bug in `VigilBitstream` is the app's most likely serious vulnerability. The sandbox is the
   single highest-leverage mitigation available: it turns "arbitrary code execution reads your
   documents and phones home" into "arbitrary code execution inside a container with network-client
   access and no file access beyond user-selected folders".
2. Distribution optionality: sandboxing is mandatory for the Mac App Store. Choosing it now costs
   little; retrofitting it later is expensive because file access patterns leak everywhere.
3. It forces the security-scoped-bookmark discipline for recording/snapshot folders (§9.1), which is
   also the correct UX (an explicit folder grant) rather than writing wherever we like.

*Against sandboxing (and how each objection is answered)*
1. **Multicast.** `com.apple.developer.networking.multicast` is a *managed* entitlement requiring a
   provisioning profile. An ad-hoc-signed local build cannot use it. → We ship two entitlement files
   (§13.3, §13.4): the sandboxed shipping one, and `Vigil-Dev.entitlements` for local builds. And,
   critically, **discovery degrades gracefully**: without multicast, SADP and WS-Discovery are skipped
   and the targeted subnet sweep plus Bonjour browse still find cameras (`spec-discovery.md`). The user
   sees an informational row — "Fast discovery unavailable; scanning your subnet instead (this takes
   about 20 seconds)" — not an error.
2. **Arbitrary local file access.** We do not need it. Snapshots and recordings go to user-selected
   folders held as security-scoped bookmarks; imports/exports go through `NSOpenPanel`/`NSSavePanel`.
3. **UDP listening for RTP.** Covered by `com.apple.security.network.server`, which is compatible with
   the sandbox.
4. **Second-display video wall, PiP, menu-bar extra.** No sandbox interaction.

*Rejected alternative:* unsandboxed + hardened runtime + notarisation. It would remove the multicast
provisioning-profile friction, but it gives up the only meaningful containment we have around
network-fed parsers. That trade is wrong for this app. The friction is handled with a second
entitlements file instead.

### 13.2 Local-network permission flow (macOS 15+)

Even sandboxed with `network.client`, macOS 15 gates *local* network access behind a user prompt tied
to `NSLocalNetworkUsageDescription`. Cross-cutting requirements:

* The prompt appears on the **first outbound local connection**, not at launch. We therefore trigger it
  deliberately at a moment the user understands: when they press "Scan for cameras" in onboarding, not
  during a background health check.
* If denied, every connection fails with an `NWError` that we map to
  `TransportError.localNetworkDenied` → severity fatal, disposition `retryAfterUserAction`, remedy
  "Open System Settings → Privacy & Security → Local Network and enable Vigil." Do **not** retry on a
  backoff schedule; it produces a permanent failing loop with no explanation.
* `StreamDoctor` probes this explicitly and reports it as its own distinct cause.

### 13.3 `Vigil.entitlements` (shipping, sandboxed)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Containment. -->
    <key>com.apple.security.app-sandbox</key>
    <true/>

    <!-- Outbound TCP/UDP to cameras: RTSP 554, ISAPI 80/443, SADP/ONVIF, sweeps. -->
    <key>com.apple.security.network.client</key>
    <true/>

    <!-- Inbound: UDP RTP/RTCP port pairs when transport is UDP, and the WS-Discovery/SADP
         response socket (replies arrive from arbitrary source ports to our bound port). -->
    <key>com.apple.security.network.server</key>
    <true/>

    <!-- Multicast/broadcast for SADP (239.255.255.250:37020) and ONVIF WS-Discovery (:3702).
         MANAGED ENTITLEMENT: requires an Apple-issued provisioning profile. If the profile is
         absent the app still runs; discovery falls back to the subnet sweep (§13.1). -->
    <key>com.apple.developer.networking.multicast</key>
    <true/>

    <!-- Recording/snapshot folders and config import/export, via NSOpenPanel + security-scoped
         bookmarks. This is the ONLY file-system entitlement we take. -->
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>

    <!-- Two-way audio push-to-talk. -->
    <key>com.apple.security.device.audio-input</key>
    <true/>

    <!-- Deliberately NOT taken, and why:
         files.downloads.read-write         — no reason to touch Downloads
         files.all                          — defeats the sandbox
         network.server on a fixed port     — n/a, ports are OS-assigned
         cs.allow-jit / cs.disable-library-validation / cs.allow-unsigned-executable-memory
                                            — we run no JIT and load no third-party code
         cs.debugger                        — never in a shipping build
         automation.apple-events            — we EXPOSE AppleScript, we do not send events
         print, camera, location, contacts, calendars, photos, bluetooth, usb — unused
    -->
</dict>
</plist>
```

### 13.4 `Vigil-Dev.entitlements` (local development only)

Used by `Scripts/build-app.sh --sandbox off`. Never shipped; `Scripts/build-app.sh` prints a loud
warning and stamps `VigilDevBuild=true` into `Info.plist` so the About window shows it.

```xml
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.network.server</key>
    <true/>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <key>com.apple.security.get-task-allow</key>
    <true/>   <!-- debugger attach; MUST be absent from any distributed build -->
</dict>
```

Note: unsandboxed **does not** grant multicast on macOS 15 either — the local-network prompt still
applies — but it removes the provisioning-profile requirement for the managed entitlement, which is
what unblocks day-to-day SADP work on a laptop.

### 13.5 Hardened runtime

* Always on: `codesign --options runtime`.
* Required exceptions: **none**. We use no JIT, load no plug-ins, allocate no unsigned executable
  memory, and read no DYLD environment variables. If a future change needs a hardened-runtime
  exception, that is a design smell and must be justified in this document first.
* `--timestamp` is always passed (required for notarisation).
* `--generate-entitlement-der` is passed for macOS 12+ compatibility of the DER entitlement blob.
* Library validation stays enabled; SwiftPM resource bundles are data, not code, so they do not need
  signing exceptions — but they **are** inside the bundle and therefore must be present *before*
  `codesign` runs (§12.1 orders steps 8 and 11 accordingly).
* Notarisation is required for distribution outside the machine that built it. Ad-hoc `-` signing is
  the default for local builds and is expected to be blocked by Gatekeeper elsewhere.

---

## 14. Swift style rules (repo-wide, mandatory)

Enforced by `swift format lint --strict` (config `.swift-format`), plus greps in `Scripts/lint.sh`.
Review rejects violations; there is no "style is subjective" discussion in this repo.

### 14.1 File header

Every file, exactly this shape, no more, no less:

```swift
//
//  RTSPSessionMachine.swift
//  VigilRTSP
//
//  Transport-agnostic RTSP 1.0 client state machine. Pure: no sockets, no clock reads, no Task.
//  See docs/spec-rtsp.md §6 for the state table.
//
```

Line 4+ is a one-to-three-line purpose statement and, where one exists, a `docs/` reference. No author
names, no dates, no copyright block (the licence lives in `LICENSE`), no Xcode template junk.
macOS-only files add the guard note from §4.3.

### 14.2 Formatting

| Rule | Value |
|---|---|
| Indentation | 4 spaces, never tabs |
| Line length | **110 columns**, hard limit; the formatter wraps, and lint fails on over-length lines it cannot wrap (long string literals must be split with `+` or moved to a constant) |
| Trailing whitespace | forbidden |
| File length | ≤ 600 lines |
| Function length | ≤ 60 lines; parsers may reach 120 with a `// RATIONALE:` note (bitstream syntax follows the spec's structure and splitting it hurts reviewability against the ITU document) |
| Braces | K&R, opening brace on the same line |
| One statement per line; no `;` | |
| Import order | `Foundation` first, then other system frameworks alphabetically, then Vigil modules alphabetically, one blank line between groups |
| Blank lines | one between members, two before a `// MARK: -` |
| Trailing commas in multi-line literals | required |
| Trailing closure | used only for the last closure argument and only when the label adds nothing |

### 14.3 `MARK` structure

Types longer than 40 lines use this order, and only these headings:

```swift
// MARK: - Nested Types
// MARK: - Stored Properties
// MARK: - Computed Properties
// MARK: - Initialisation
// MARK: - Public API          (or `Package API` / `Internal API`)
// MARK: - Private Helpers
// MARK: - Conformances        (one `// MARK: - <Protocol>` per extension)
```

Protocol conformances go in extensions, one per protocol, with a `MARK`. `Codable` conformance with
custom keys always shows `CodingKeys` explicitly — never rely on synthesised key names for anything
persisted (§9.3 depends on stable keys).

### 14.4 Access control

| Level | When |
|---|---|
| `private` | default for everything; start here |
| `fileprivate` | only when two types in one file genuinely share state |
| `internal` (implicit) | module-internal API; never write the keyword |
| `package` | **use this** for API that other Vigil targets need but that is not part of a documented module contract. It keeps the public surface small while allowing cross-target use. |
| `public` | only for the types and members listed in a module spec's "public API" section |
| `open` | forbidden. We subclass nothing across module boundaries |

`final` on every class unless it is deliberately subclassed within the module. `struct` over `class`
unless identity or reference semantics are required. `enum` with no cases for pure namespaces
(`enum VTheme { enum Color { … } }`), never a `struct` with a private `init`.

### 14.5 Naming

* Types `UpperCamelCase`; members `lowerCamelCase`; no `_` prefixes; no Hungarian notation.
* No abbreviations except this closed list, used in canonical casing:
  `RTSP RTP RTCP SDP NAL SPS PPS VPS SEI IDR IRAP AU PTS DTS FPS SAR GOP MTU PTZ ISAPI SADP ONVIF
  URL URI ID UUID JSON XML HTTP HTTPS TCP UDP TLS DNS IP MAC CIDR MD5 CRC AAC PCM YUV RGB HDR EDR
  UI OSD NVR DVR`.
  Acronyms at the **start** of a member name are lowercased whole: `rtspPort`, `urlComponents`,
  `sdpDescription`. Elsewhere they stay uppercase: `parseRTSPResponse`, `makeSDPParser`.
* Booleans read as assertions: `isKeyframe`, `hasParameterSets`, `shouldReconnect`, `canPan`.
  Never `flag`, `enabled` (use `isEnabled`), or negatives (`isNotReady` is forbidden).
* Functions that can fail return `throws`, not `Bool`. Functions returning a value name the value, not
  the act: `var displaySize` not `getDisplaySize()`.
* Factory statics are `make…`: `RTSPRequest.makeDescribe(url:cseq:)`.
* Units are in the name when not obvious: `timeoutSeconds`, `bitrateKbps`, `jitterMilliseconds`,
  `deadlineNanos`. A bare `timeout: Duration` is fine because `Duration` carries the unit.
* Test names describe behaviour: `func markerBitUnreliable_stillSplitsAccessUnitsCorrectly()`.

### 14.6 Force-unwrap, force-try, force-cast

**Forbidden in `Sources/`:** `!` postfix unwrap, `try!`, `as!`, `unsafeBitCast`,
`fatalError` (except §7.4's narrow case), `preconditionFailure`, `array[i]` where `i` is not provably
in range, `String(cString:)` on non-null-terminated bytes.

**Allowed in `Tests/` and `Sources/VigilTestKit/`.** Tests are meant to crash loudly.

The one exception in `Sources/`: a `!` on a statically exhaustive dictionary built in the same file from
a `CaseIterable` enum (as in `OSLogLogger.loggers`, §8.2), which must carry a
`// swift-format-ignore` plus a comment naming the invariant.

Replacements to use instead:

```swift
// Instead of `array[i]`
guard let byte = bytes.dropFirst(offset).first else { throw BitstreamError.truncated(atBit: offset * 8) }

// Instead of `dict[key]!`
guard let track = tracks[trackID] else { throw RTSPError.sessionNotFound }

// Instead of `Int(string)!`
guard let cseq = Int(value), cseq >= 0 else { throw RTSPError.malformedResponse }
```

### 14.7 Error handling style

* **Typed throws in the pure layer.** Where the error set is closed, use Swift 6 typed throws so
  callers cannot forget a case:
  ```swift
  public mutating func parse(_ data: Data) throws(BitstreamError) -> H264SPS
  ```
  At module boundaries and in `VigilCore`, widen to `throws(VigilError)`. Only `VigilUI` and `Vigil`
  use untyped `throws`.
* `try?` is allowed **only** where the failure is genuinely uninteresting *and* a comment says so:
  `try? FileManager.default.removeItem(at: staleTemp)  // best effort cleanup`.
  Swallowing an error silently anywhere else is a review rejection.
* Never `catch {}`. Never `catch { print(error) }`. Every catch either handles, logs at ≥ `warning`
  with the `diagnosticCode`, or rethrows.
* `Result` is not used as a return type. Use `throws`. `Result` appears only inside
  `AsyncThrowingStream` element types where the API demands it.
* Errors are values: no `NSError` construction, no `NSException`, no `assertionFailure` as
  error handling.
* Integer overflow: arithmetic that is *expected* to wrap (RTP sequence numbers, 32-bit timestamps)
  uses `&+`/`&-` **with a comment naming the wrap width**. Everywhere else, plain `+` so a trap
  surfaces the bug. Never `Int(exactly:)!`; use `guard let`.

### 14.8 Documentation comments

* Every `public` and `package` declaration has a `///` comment. Lint fails otherwise.
* Shape: one summary sentence ending in a period, a blank `///` line, then detail; then
  `- Parameters:` (only for 2+ parameters), `- Returns:`, `- Throws:` (naming the concrete error type),
  and `- Complexity:` for anything worse than O(n).
* Cite the specification: `/// - Note: ITU-T H.264 (08/2021) §7.3.2.1.1.` Every bitstream and protocol
  parser function names its clause. This is how a reviewer checks correctness without guessing.
* `- Warning:` on anything with a concurrency or lifetime precondition ("Must be called from the
  owning actor", "The returned buffer is valid until the next `push`").
* No commented-out code. Ever. Git has history.
* `// TODO:` is **forbidden in `Sources/`**. Unfinished work is a tracked issue, not a comment; a
  shipped `TODO` is a lie about the state of the code. `Scripts/lint.sh` fails on it.

### 14.9 Cryptography and hashing

`CryptoKit` is **not available on Linux**, so the pure layer cannot use it, and we need MD5 for HTTP/RTSP
Digest authentication on both platforms. Decision: **implement MD5 in `VigilProtocols`** (~120 lines,
RFC 1321), unit-tested against the RFC 1321 test suite plus the RFC 2617 Digest example vectors.
Also in `VigilProtocols`: `CRC32` (for fixture checksums) and a small `Base64` wrapper over
Foundation's.

MD5 is used **only** where a protocol mandates it (Digest auth). It is never used for anything
security-bearing of our own choosing. `SHA-256`, when needed for TLS certificate fingerprint display,
comes from `CryptoKit` in a **macOS-only** target. `Scripts/lint.sh` fails on `import CryptoKit`
outside `VigilTransport` and `VigilCore`.

### 14.10 Miscellaneous hard rules

| Rule | Reason |
|---|---|
| No `print`, `debugPrint`, `dump` in `Sources/` | use the logger; lint fails |
| No `NSLog` | ditto |
| No global mutable state; no `static var` that is not `let` | Swift 6 rejects most of it anyway; the rest is a race |
| No `nonisolated(unsafe)` | if you need it, you have modelled ownership wrong |
| No `@preconcurrency import` | if a framework needs it, wrap it in a small isolated adapter instead |
| No `DispatchSemaphore`, `NSLock`, `pthread_mutex`, `objc_sync_enter` | use actors or `OSAllocatedUnfairLock` (§5.7) |
| No `Thread.sleep`, `usleep`, `RunLoop.current.run(until:)` | use `clock.sleep(for:)` |
| No `unsafeDowncast`, no `Unmanaged` outside the two documented CF bridges | |
| `withUnsafeBytes` blocks may not escape the pointer; every use has a `// SAFETY:` comment naming the lifetime | |
| No string-keyed magic: RTSP header names, ISAPI paths, plist keys, `UserDefaults` keys and log metadata keys are `static let` constants in one place per module | typos are otherwise silent |
| No `Date()` in the pure layer | §5.10 |
| Localised strings via `String(localized:)`/`LocalizedStringResource` with explicit keys; **never** a bare English literal in a view | Russian localisation is a P0 requirement |
| Every `AsyncStream` has a documented buffering policy at the creation site | unbounded default is a memory leak |
| `Data` slices: never store a `Data` slice long-term without `Data(slice)` — slices retain the parent buffer | a 1 MB read retained by a 12-byte header slice is a real leak |

---

## Appendix A — CI workflow skeletons

```yaml
# .github/workflows/linux.yml
name: linux
on: [push, pull_request]
jobs:
  pure:
    runs-on: ubuntu-latest
    container: swift:6.1-noble
    steps:
      - uses: actions/checkout@v4
      - name: Prove zero dependencies
        run: test "$(grep -c '\.package(' Package.swift)" -eq 0
      - name: Build pure product
        run: swift build --product VigilPure -Xswiftc -warnings-as-errors
      - name: Build test fixtures
        run: swift build --product VigilTestKit -Xswiftc -warnings-as-errors
      - name: Build everything (proves #if os(macOS) guards)
        run: swift build -Xswiftc -warnings-as-errors
      - name: Test
        run: swift test --parallel
      - name: Assert pure targets actually ran tests
        run: Scripts/test-linux.sh
```

```yaml
# .github/workflows/macos.yml
name: macos
on: [push, pull_request]
jobs:
  full:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - run: swift build -c debug -Xswiftc -warnings-as-errors
      - run: swift test --parallel --enable-code-coverage
      - run: Scripts/coverage.sh
      - run: Scripts/lint.sh
      - run: Scripts/build-app.sh --configuration release --arch universal
      - uses: actions/upload-artifact@v4
        with: { name: Vigil.app, path: dist/Vigil.app }
```

## Appendix B — Performance budget allocated per module

FEATURES.md owns the headline numbers; this table allocates them so each module has a target it can
test against in isolation.

| Budget | Total | Allocation |
|---|---|---|
| Glass-to-glass latency, TCP, LAN | ≤ 250 ms | camera encode + network 60 ms · jitter buffer 120 ms (low-latency preset) · depacketize ≤ 2 ms · decode ≤ 12 ms · present ≤ 8 ms · display refresh ≤ 17 ms · slack 31 ms |
| Cold launch → first frame (1 camera, cached credentials) | ≤ 1200 ms | process + SwiftUI 250 ms · config load 5 ms · Keychain 2 ms · TCP+RTSP handshake 4 RTT ≈ 120 ms · first keyframe wait (GOP-bound) ≤ 700 ms · decode+present 25 ms |
| 16 × 1080p substream CPU | ≤ 35 % of an M-series package | RTP+depacketize ≤ 6 % · VideoToolbox HW ≤ 12 % · Metal composite ≤ 8 % · SwiftUI/AppKit ≤ 5 % · everything else ≤ 4 % |
| Memory, 16 streams | ≤ 900 MB RSS | pixel-buffer pools 16 × 3 × 3.1 MB ≈ 150 MB · encoded queues 16 × 8 × 120 KB ≈ 15 MB · textures ≈ 100 MB · app+UI ≤ 300 MB · slack |
| UI frame time p99 | ≤ 8 ms (120 Hz) | overlays and chrome only; video layers are never re-laid-out during animation (DESIGN.md) |
| Per-camera task count | 9 | §5.4 |
| Allocations per decoded frame | **0** steady-state | pixel buffers from a `CVPixelBufferPool`, stats in preallocated rings, `EncodedFrame.data` reusing capacity |

## Appendix C — Implementer checklist (per module)

Before a module is considered done:

- [ ] Public API matches its `docs/spec-*.md` exactly; any deviation updated the spec in the same commit.
- [ ] Imports match the §4.5 allow-list; the target still appears in `VigilPure` (if pure) and builds on Linux.
- [ ] Every file has the §14.1 header; macOS-only files have the §4.3 guard.
- [ ] No `!`, `try!`, `as!`, `print`, `TODO`, `Thread.sleep`, `DispatchSemaphore`.
- [ ] Typed throws where the error set is closed; every error case has a `diagnosticCode`, `userMessage`, `disposition`.
- [ ] Logging goes through the injected `LoggerProtocol`; nothing in §8.6 can reach a log.
- [ ] Pure types take an injected clock and `RandomSource`; no `Date()` or system RNG.
- [ ] Actors only where §5.2 lists them; new actors were added to §5.2 by the same commit.
- [ ] Every queue and buffer has a documented bound and a drop counter in `StreamStatistics`.
- [ ] ≥ 90 % line coverage (pure) / 70 % (macOS); the relevant rows of the §10.2 matrix pass.
- [ ] `swift format lint --strict` and `Scripts/lint.sh` are clean; `swift build -Xswiftc -warnings-as-errors` is clean on both platforms.

## Appendix D — Glossary

| Term | Meaning here |
|---|---|
| AU | Access unit — one coded picture's worth of NALs; what an `EncodedFrame` holds |
| IRAP | Intra random access point — H.265 NAL types 16…23; the H.265 analogue of an IDR |
| Pure layer | The Foundation-only, Linux-testable targets: `VigilProtocols`, `VigilBitstream`, `VigilRTSP`, `VigilRTP`, `VigilISAPI`, `VigilDiscovery`, `VigilTestKit` |
| Quirk | A named, reproducible misbehaviour of a real camera or network, injectable by `VigilTestKit` |
| Substream | Hikvision's lower-resolution second stream (`/Streaming/Channels/x02`), used for grid tiles |
| Glass-to-glass | Photon at the camera sensor → photon on the user's display |
| Ground truth | What `SyntheticRTSPServer` intended to send; the oracle for pipeline assertions |
