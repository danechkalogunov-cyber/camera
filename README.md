# Vigil

A native macOS viewer for Hikvision IP cameras and NVRs. No browser plugin, no bundled ffmpeg, no
Electron — one Swift application that speaks RTSP, RTP and Hikvision's ISAPI directly, decodes with
VideoToolbox and draws with Metal.

The product goal is stated as a test: **launch the app, type a password, and see live moving video
from a camera on your LAN within ten seconds** — with no URL to construct, no channel number to
guess and no transport to choose.

---

## Status — read this before you build

This repository is under active construction and **the macOS half of it has never been compiled**.

Development happens in a Linux container with Swift 6.1.2 and no Xcode, which splits the codebase
cleanly in two:

| Half | Modules | State |
|---|---|---|
| **Portable** — `Foundation` only, no Apple frameworks | `VigilProtocols`, `VigilBitstream`, `VigilRTSP`, `VigilRTP`, `VigilISAPI`, `VigilDiscovery`, `VigilTestKit` | genuinely compiled and unit-tested on every change |
| **macOS** — AppKit, SwiftUI, AVFoundation, VideoToolbox, CoreMedia, Metal, Network, Security | `VigilTransport`, `VigilVideo`, `VigilRender`, `VigilCore`, `VigilUI`, `Vigil` | **never type-checked**; every file meets a compiler for the first time on your Mac |

What that means concretely, today:

- `swift build --product VigilPure` is green on Linux, and the pure test suite passes. That covers
  the byte/bit readers, MD5/SHA-1/SHA-256, Base64, percent-encoding, the IPv4 and subnet types, and
  the shared media value types.
- Every macOS-only file is wrapped in `#if os(macOS)`, so a full `swift build` also succeeds on
  Linux — by compiling those targets to **empty modules**. A green Linux build says nothing about
  whether the macOS code is correct.
- The app target is a stub. `Scripts/build-app.sh` will assemble a bundle, but there is not yet an
  app inside it that shows video.
- `Scripts/build-app.sh`, `Scripts/run.sh` and `project.yml` were written on Linux and have been
  **syntax-checked only**. No `codesign`, `xcodebuild`, `iconutil`, `hdiutil` or `xcodegen` has ever
  run against them.

`docs/BUILD-VERIFICATION.md` is the running record of what has actually been executed, and the four
build defects that record has already caught. It is appended to, never rewritten. If this README and
that document ever disagree, believe that document.

The plan for the first runnable slice — TCP-interleaved RTSP, Digest auth, H.264 and H.265, one
window, no discovery — is in `.vigil/SLICE.md`.

---

## Requirements

**To build the app**

- macOS 14.0 (Sonoma) or newer, on Apple silicon or Intel.
- Xcode 16 or newer, for Swift 6.0+ and the macOS 14 SDK.
  The command line tools alone are enough for `Scripts/build-app.sh`:
  ```
  xcode-select --install
  ```
- Nothing else. Vigil has **zero external dependencies** by design — `Package.swift` has an empty
  `dependencies:` array, and the build script fails if `Package.resolved` ever gains a pin.

**To work on the portable half only** (Linux, CI, or a Mac without Xcode)

- Swift 6.1 or newer. That is all.

**Optional**

- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) if you want a real
  `.xcodeproj` rather than opening `Package.swift`.

---

## Build

```
git clone <this repository>
cd camera
Scripts/build-app.sh
```

That produces `dist/Vigil.app`. The script prints the path on its last line.

It builds release, universal (arm64 + x86_64), assembles the bundle, copies the SwiftPM resource
bundles that carry the asset catalog and the shader sources, and code-signs. With no signing
identity configured it **ad-hoc signs**, which is enough for the app to launch on the machine that
built it. Useful flags:

```
Scripts/build-app.sh --configuration debug --arch arm64     # fast local build
Scripts/build-app.sh --sandbox off                          # unsandboxed dev build, debugger-attachable
Scripts/build-app.sh --dmg                                  # also produce dist/Vigil-<version>.dmg
CODESIGN_IDENTITY="Developer ID Application: …" Scripts/build-app.sh --notarize
```

Run `Scripts/build-app.sh --help` for the full list. The script works from any directory, checks its
own prerequisites, and exits with a distinct code per failing step (2 toolchain, 3 dependencies,
4 compile, 5 layout, 6 Info.plist, 7 resources, 8 entitlements, 9 signing, 10 dmg, 11 notarisation).

### In Xcode

Either open the package directly, which needs no generated project:

```
open Package.swift
```

or generate one:

```
brew install xcodegen
xcodegen generate
open Vigil.xcodeproj
```

`Vigil.xcodeproj` is git-ignored. **Never commit a hand-written `.pbxproj`** — regenerate it from
`project.yml` instead.

### Building on a Mac without Xcode

The Command Line Tools ship the compiler and the macOS SDK, so everything in this package compiles
under them — with one exception. `#Preview` is an *external macro*, and the plugin that expands it
(`PreviewsMacros`) lives in Xcode's toolchain, not in the CLT:

```
error: external macro implementation type 'PreviewsMacros.SwiftUIView' could not be found
       for macro 'Preview(_:body:)'; plugin for module 'PreviewsMacros' not found
```

`xcode-select -p` printing `/Library/Developer/CommandLineTools` is the tell. Two ways out:

```
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer   # if Xcode is installed
swift build -Xswiftc -DVIGIL_NO_PREVIEWS                          # if it is not
swift test  -Xswiftc -DVIGIL_NO_PREVIEWS
```

Every `#Preview` in `VigilUI` sits inside `#if DEBUG && !VIGIL_NO_PREVIEWS`, so that flag compiles
the app and its tests without them. It is an escape hatch, not a mode: previews are how the design
gets checked against `design/mockups/`, and they are on by default in Xcode and in CI.
`Scripts/lint.py` (`preview-guard`) keeps new preview files on the same guard, since one file with a
bare `#if DEBUG` puts the whole module back out of reach.

### Building on Linux

```
swift build --product VigilPure     # the portable modules — this is the purity gate
swift build                         # whole package; macOS targets become empty modules
swift test                          # the pure test suite
```

`--product VigilPure` is the mechanism that keeps the portable layer portable: if someone adds
`import CoreMedia` to `VigilRTP`, that command stops building. It has to name the product explicitly
and the product has to be `type: .static`, or SwiftPM silently builds the whole package instead and
the gate stops being a gate (`docs/BUILD-VERIFICATION.md`, defect 1).

---

## Run

```
Scripts/run.sh
```

This builds, launches the app, and streams its log into your terminal so you can watch a connection
succeed or fail without opening Console.app:

```
Scripts/run.sh --category rtsp,transport    # only the RTSP and transport categories
Scripts/run.sh --level info                 # quieter
Scripts/run.sh --no-build                   # launch what is already in dist/
Scripts/run.sh --logs-only                  # attach to an app that is already running
```

Vigil logs on OSLog subsystem `com.vigil.app` with a fixed set of categories — `app`, `discovery`,
`rtsp`, `rtp`, `bitstream`, `isapi`, `transport`, `video`, `render`, `core`, `storage`, `ui`,
`perf`. The equivalent by hand is:

```
log stream --style compact --level debug --predicate 'subsystem == "com.vigil.app"'
```

Arguments logged as `%@` appear as `<private>`. That is OSLog's default, not a bug in the script;
credentials, session IDs and URLs containing them are redacted deliberately
(`docs/ARCHITECTURE.md` §8.6).

---

## Point it at a camera

The intended first-run flow is at most three actions, and the app is supposed to do the rest itself
(`docs/REQUIREMENTS-CUSTOMER.md` §R1):

1. **Launch.** Discovery starts on its own — SADP, WS-Discovery and a subnet sweep in parallel. No
   button to press. Devices appear as they are found.
2. **Pick the camera.** If exactly one Hikvision device is found it is preselected, so this step
   usually disappears.
3. **Type the password** and press Return. The username is prefilled with `admin`, the Hikvision
   factory default.

You are never asked for an RTSP URL, a channel number, a stream index, a transport or a codec. Vigil
probes the six known Hikvision RTSP path families itself, remembers which one worked for that device,
enumerates NVR channels over ISAPI, and defaults to TCP-interleaved transport because that traverses
every LAN without inbound ports. The password goes to the Keychain.

The first time Vigil touches the network, **macOS 15 and later show a Local Network permission
prompt**. Allow it. If you deny it, local traffic is dropped *silently* — connections do not fail,
they simply time out forever with no message. Re-enable it in System Settings → Privacy & Security →
Local Network.

---

## When it does not connect

Every connection failure is supposed to resolve to a named cause and a concrete next action, from
the Stream Doctor sequence. It should never show you a raw error code or an empty tile. The nine
required diagnoses are specified in **`docs/REQUIREMENTS-CUSTOMER.md` §R1.5**:

| What you see | What it means | What to do |
|---|---|---|
| Not on this network | no TCP route to port 554 or 80 | check the camera is powered on and on the same subnet |
| Camera not activated | SADP reports `Activated=false` | the camera needs its password set first; Vigil offers the activation flow |
| Wrong password | RTSP 401 persists after a Digest retry with a fresh nonce | re-enter the password |
| Account locked | ISAPI `userCheck` reports lock-out | wait, or reboot the camera |
| RTSP port closed or blocked | port 80 answers, 554 refuses | RTSP is disabled in the camera's config, or a firewall blocks it |
| Not a Hikvision device | the fingerprint says Dahua, Axis or other | Vigil says so plainly and offers the ONVIF path |
| Codec unsupported | the SDP advertises only a codec we cannot decode | Vigil names the codec and offers to change the camera's encoding over ISAPI |
| Stream starts but no picture | RTSP plays, no RTP arrives within 5 s | UDP is blocked; Vigil switches that camera to TCP interleaved and retries |
| Picture stalls | RTP flows, no keyframe within 5 s | Vigil requests an IDR, then lowers the GOP over ISAPI |

Two failure modes that are **not** the camera's fault and are worth knowing about:

- **"Vigil can't see your local network."** The Local Network permission was denied. Nothing will
  ever connect until it is granted. See above.
- **Discovery finds nothing on a different subnet.** A factory-fresh camera still on `192.168.1.64`
  while your Mac is on another network is only reachable via link-local multicast, and multicast
  needs an Apple-granted entitlement (below). Without it, Vigil sweeps addresses one at a time and
  cannot see off-subnet devices. It says so in the discovery sheet rather than showing an empty
  list.

For anything else, `Scripts/run.sh` puts the app's own reasoning in your terminal.

---

## About the multicast entitlement

`com.apple.developer.networking.multicast` is a *managed* entitlement: Apple grants it per developer
team on request, and using it requires a provisioning profile embedded in the app. If you build from
source without that grant — which is everyone, at first — `codesign` rejects it.

`Scripts/build-app.sh` handles this rather than failing: it catches the rejection, prints a loud
warning explaining exactly what is lost, and re-signs with `Resources/Vigil-nomulticast.entitlements`.
The app still builds and runs. Discovery falls back to a unicast sweep: slower (about 4–6 s on a /24
instead of ~1.5 s), and blind to other subnets. Everything else is unaffected.

There is **one binary** and no compile-time multicast flag. The app reads its own code signature at
launch and also verifies empirically, because entitlement enforcement differs between macOS 14 and
macOS 15.

Once you have the grant:

```
PROVISIONING_PROFILE=/path/to/Vigil.provisionprofile \
CODESIGN_IDENTITY="Developer ID Application: …" Scripts/build-app.sh
```

---

## Tests

```
Scripts/check.sh        # the full local gate: lint, both build worlds, the pure test suite
```

That is what to run before claiming anything works. Individually:

```
python3 Scripts/lint.py                        # the rules a compiler cannot enforce
swift build --product VigilPure                # portability gate
swift build                                    # whole package
swift test                                     # all pure tests
swift test --filter VigilRTSPTests             # one target
```

Tests use **swift-testing** (`import Testing`, `@Test`, `#expect`), not XCTest, because it works on
Linux. Two rules bite in practice and both are enforced by `Scripts/lint.py`:

- **Every test function name must be unique across its whole test target**, so prefix each one with
  the type under test (`base64DecodeRejectsOddLength`, not `decodeRejectsOddLength`). `@Test`
  attaches to free functions, which share one namespace per module; two files choosing the same
  obvious name stops the entire target compiling. This has already happened once
  (`docs/BUILD-VERIFICATION.md`, defect 4).
- **The portable modules may import `Foundation` and nothing else.** No `CoreMedia`, `OSLog`,
  `Security`, `CryptoKit`, `Network` — the crypto is hand-written pure Swift precisely so it can be
  tested against RFC vectors on Linux.

When several people (or agents) build at once, give each build its own scratch directory, because
SwiftPM takes an exclusive lock on `.build`:

```
swift build --product VigilPure --scratch-path .build-yourname
```

---

## Repository layout

```
Package.swift               module graph and both build worlds; zero dependencies, deliberately
project.yml                 XcodeGen input — one target that links the local package
README.md                   this file

Resources/
  Info.plist                bundle keys; the local-network, Bonjour, ATS and UTI keys matter
  Vigil.entitlements        shipping: sandboxed, network client + server, multicast
  Vigil-nomulticast.entitlements   fallback when Apple has not granted multicast
  Vigil-Dev.entitlements    unsandboxed local build, debugger-attachable; never distributed

Scripts/
  build-app.sh              swift build output -> a signed, runnable Vigil.app
  run.sh                    build, launch, and tail the app's log
  check.sh                  the full local gate
  lint.py                   purity, banned constructs, line width, duplicate test names

Sources/
  VigilProtocols/           shared value types, byte/bit readers, MD5/SHA, IPv4, clocks
  VigilBitstream/           H.264 and H.265 NAL parsing, SPS/PPS, avcC/hvcC
  VigilRTSP/                RTSP messages, Digest auth, SDP, the client state machine
  VigilRTP/                 RTP packets, depacketization, jitter buffer, RTCP
  VigilISAPI/               Hikvision ISAPI client, XML decoding, endpoints
  VigilDiscovery/           SADP, WS-Discovery, subnet sweep, result merging
  VigilTestKit/             synthetic camera, generators, fault injection  (never linked by the app)
  VigilTransport/           sockets, TLS, multicast                        ┐
  VigilVideo/               VideoToolbox decode, format descriptions       │ macOS only,
  VigilRender/              Metal renderer, video tiles, zoom and pan      │ never compiled
  VigilCore/                model, persistence, Keychain, stream control   │ on Linux
  VigilUI/                  SwiftUI screens, theme, components             │
  Vigil/                    the app target: main.swift, scenes, menus      ┘

Tests/                      one target per module; Fixtures/ holds wire dumps and golden vectors
docs/                       the specifications — see below
design/                     pixel-accurate HTML mockups and their rendered PNGs
```

`.build*`, `dist/` and `*.xcodeproj` are git-ignored.

---

## Documentation

The specifications are long on purpose: this code parses hostile bytes from devices we do not
control, and the details are the product.

| Document | What it settles |
|---|---|
| `docs/REQUIREMENTS-CUSTOMER.md` | the customer's own words. **Overrides everything else.** |
| `docs/API_CONTRACT.md` | normative: every type, every module's API, the 233-file manifest, and 73 rulings on cross-spec conflicts |
| `docs/ARCHITECTURE.md` | module graph, concurrency model, error taxonomy, the build and entitlement contracts |
| `docs/BUILD-VERIFICATION.md` | what has actually been executed, and the defects that caught |
| `docs/DESIGN.md`, `docs/UX.md` | the visual system and the screens |
| `docs/FEATURES.md` | the feature inventory with priorities |
| `docs/spec-rtsp.md`, `spec-rtp.md`, `spec-bitstream.md`, `spec-isapi.md`, `spec-discovery.md`, `spec-video-pipeline.md`, `spec-render.md`, `spec-core.md` | one per protocol or subsystem |
| `docs/OPEN-CONFLICTS.md` | contradictions found between the parallel specs, all now ruled on in the API contract |
| `.vigil/IMPL_RULES.md` | binding rules for anyone writing code here |
| `.vigil/SLICE.md` | the first vertical slice, and what is deliberately out of it |

Where a specification prescribes a command, it is not trusted until it has been run. That standing
rule is why `docs/BUILD-VERIFICATION.md` exists.

---

## What is not implemented yet

Honest list, matching `docs/BUILD-VERIFICATION.md` and the wave plan in `docs/API_CONTRACT.md` §5:

- **Live video.** The decode, render and stream-control layers are specified in full and not yet
  written. Nothing displays a picture today.
- **Discovery, ISAPI, RTSP, RTP, bitstream parsing.** Specified; the shared primitives they build on
  exist and are tested; the protocol modules themselves are still stubs.
- **The user interface.** The screens exist as pixel-accurate HTML mockups under `design/mockups/`
  and rendered PNGs under `design/shots/`, which are the visual contract the SwiftUI implementation
  has to match. No SwiftUI has been written.
- **Everything beyond the first slice** — grid layouts, PTZ, archive and timeline, events,
  recording, snapshots, the command palette, the inspector, localization, digital zoom, audio, UDP
  and multicast transport, and the video wall — is in the manifest and lands in later waves.
- **Anything that needs a Mac.** Code signing, the hardened runtime, entitlements, real hardware
  decode, latency and CPU numbers, and the ten-second acceptance run against a real camera on a real
  LAN. None of it has been observed. `Scripts/build-app.sh` and `Scripts/run.sh` are written to be
  correct by construction and have been syntax-checked; they have not been executed.

The performance targets — under 250 ms glass-to-glass on a LAN, 16 × 1080p under 35 % CPU — are
budgets from the specification, not measurements. Treat every number in this repository as a target
until `docs/BUILD-VERIFICATION.md` records it as observed.
