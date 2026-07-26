# Build verification — what has actually been compiled, and the defects it caught

Development happens in a Linux container with **Swift 6.1.2** and no Xcode. That means the
platform-independent half of Vigil can be genuinely compiled and unit-tested here, while the
macOS-only half can only be type-checked on a Mac. This document records what has really been run,
so nobody mistakes a reviewed file for a compiled one.

## Toolchain in use

```
$ swift --version
Swift version 6.1.2 (swift-6.1.2-RELEASE)
Target: x86_64-unknown-linux-gnu
```

`swift-testing` (the `@Test` / `#expect` library) is present and works, so tests are written with it
rather than XCTest.

## What was verified, and when

### 1. Swift 6 language mode, actors and swift-testing work on Linux — verified

A throwaway package with an `actor` holding a bounded queue, a `Sendable` value type, and three
`@Test` cases built and passed under `swiftLanguageMode(.v6)`. This is what licenses the whole
architectural bet in `ARCHITECTURE.md` §4: the pure layer really is testable in CI without a Mac.

### 2. `Package.swift` from `ARCHITECTURE.md` §3 — verified, after two fixes

The manifest was extracted verbatim from the spec, every declared target directory was scaffolded
with a stub file, and both build worlds were run. Two real defects surfaced.

#### Defect 1 — the Linux purity gate did not work (`--product` on an automatic library)

`ARCHITECTURE.md` designates `swift build --product VigilPure` as *the* command Linux CI runs, and
the mechanism that keeps the pure layer pure: if someone adds `import CoreMedia` to `VigilRTP`, that
product must stop building. As originally written, the product had no explicit `type:`, so SwiftPM
treated it as an **automatic** library and refused to target it:

```
warning: '--product' cannot be used with the automatic product 'VigilPure';
         building the default target instead
```

"Building the default target instead" means the command silently builds the *whole package* — so the
gate would have passed on any code, including code that violated the purity rule it exists to
enforce. A gate that cannot fail is worse than no gate, because it is trusted.

**Fix:** declare `type: .static` on the `VigilPure` product. Now:

```
$ swift build --product VigilPure
...
[32/33] Archiving libVigilPure.a
Build of product 'VigilPure' complete! (4.33s)
```

`ARCHITECTURE.md` §3 has been amended with the fix and an explanatory comment.

#### Defect 2 — declared resource directories must exist from the first commit

The manifest declares resources (`Sources/VigilRender/Shaders`, `Sources/VigilUI/Resources`,
`Sources/VigilUI/Localizations`, and a `Fixtures` directory in nine test targets). A `.copy()` or
`.process()` pointing at a directory that does not exist is a **hard build error**, not a warning:

```
error: couldn't build .../Vigil_VigilUI.resources/Resources because of missing inputs:
       .../Sources/VigilUI/Resources
```

This is a trap for parallel implementation: the agent that creates `Package.swift` and the agent that
creates `Sources/VigilUI/Resources/` are different agents, and until the second one lands, *nobody
else can build the package at all* — every implementer would be blocked by an error in someone
else's unwritten directory.

**Fix / rule:** the scaffolding commit must create all twelve resource directories, each containing
a `.placeholder` file, before any other source lands. Recorded as an implementation rule so it is not
rediscovered painfully.

### 3. Both build worlds pass with the fixes — verified

```
$ swift build --product VigilPure        # Linux CI purity gate
Build of product 'VigilPure' complete! (4.33s)

$ swift build                            # full package on Linux
[41/42] Linking Vigil
Build complete! (7.64s)

$ swift test --filter 'VigilProtocolsTests|VigilRTSPTests|VigilRTPTests|\
                       VigilBitstreamTests|VigilISAPITests|VigilDiscoveryTests'
✔ Test run with 6 tests passed after 0.001 seconds.
```

The full-package build succeeding on Linux confirms the `#if os(macOS)` whole-file guard strategy
works: the macOS-only targets compile to empty modules rather than failing, and the `Vigil`
executable still links.

## What has NOT been verified, and cannot be here

Be honest about this list; it is the acceptance work that has to happen on a Mac.

| Area | Why it needs a Mac |
|---|---|
| Anything importing AppKit, SwiftUI, AVFoundation, VideoToolbox, CoreMedia, Metal, Security, Network | Frameworks absent on Linux; the `#if os(macOS)` bodies are never type-checked here |
| The Metal shaders | Need `metal`/`metallib` from Xcode |
| `Vigil.app` bundle assembly, code signing, entitlements, hardened runtime | Needs `codesign` and a Mac |
| Real hardware decode, latency and CPU numbers | Need Apple silicon and real cameras |
| The R1 zero-configuration acceptance gate (launch → live picture in 10 s) | Needs a real Hikvision camera on a real LAN |

Everything in the pure layer — RTSP message parsing, Digest authentication, SDP, RTP
depacketization, jitter buffering, H.264/H.265 bitstream parsing, avcC/hvcC construction, ISAPI XML
decoding, SADP and WS-Discovery packet codecs, CIDR maths, and the synthetic-camera test harness —
**is** verifiable here and must be green before the macOS layer is written.

## Standing rule

No specification claim about the build system is trusted until it has been executed. When a spec
prescribes a command, run it against a scaffold. This document is appended to, never rewritten.
