# Vigil — API Contract

**Status: NORMATIVE. This document outranks every other document in `docs/` except
`docs/REQUIREMENTS-CUSTOMER.md`.**

Twelve specifications were authored in parallel and therefore disagree at their seams. This file is
the arbitration. Where a spec and this contract differ, **this contract is right and the spec must be
amended**; §2 lists every amendment owed. Where this contract is silent, the owning module spec
governs.

## 0. How to use this document

| You are | Read |
|---|---|
| Any implementation agent | §0, §1, §2 (skim, then your rows), §3 (verbatim), §6 §7 §8 in full |
| A `VigilProtocols` implementer (W1) | §3 verbatim — you paste it. Then §5 rows tagged W1 |
| A pure-module implementer (W2) | §3, your module's §4 subsection, your §5 rows, §7 |
| A macOS-module implementer (W3–W6) | same, plus §7.9 (the `#if os(macOS)` template) |
| A reviewer | §2 (the rulings you must enforce), §7 (the style you must reject on) |

### 0.1 Precedence order (binding)

1. `docs/REQUIREMENTS-CUSTOMER.md` — customer requirements. R1 (launch → live video in 10 s with the
   password as the only input) is a P0 acceptance gate and shapes the API surface: a DESCRIBE probe
   ladder, automatic channel enumeration and transport self-healing are all **required API**, not
   optional polish.
2. **This document** (`docs/API_CONTRACT.md`) — type shapes, module surfaces, file manifest,
   `Package.swift`, cross-cutting rules.
3. `docs/BUILD-VERIFICATION.md` — anything actually compiled beats anything merely written.
4. `.vigil/IMPL_RULES.md` — binding style/concurrency/testing rules for implementation agents. §7
   here **extends** it and never contradicts it. If you think it does, IMPL_RULES wins and §7 is a
   defect — report it.
5. `docs/ARCHITECTURE.md` — structural backbone (module graph, concurrency model, error taxonomy,
   observability, persistence, entitlements).
6. The nine domain specs — normative for everything inside their module that this contract does not
   pin down.
7. `docs/OPEN-CONFLICTS.md` — a worklist, now fully discharged by §2. It is historical.

### 0.2 What is already real in the repository

Verified on Swift 6.1.2 / x86_64-unknown-linux-gnu (`docs/BUILD-VERIFICATION.md`):

* `Package.swift` at the repo root is **authoritative and green**. §6 reproduces it. The copy in
  `ARCHITECTURE.md` §3 is stale where they differ.
* All 25 target directories exist, each with a `Placeholder.swift`.
* All 12 declared resource directories exist, each with a `.placeholder` file:
  `Sources/VigilRender/Shaders`, `Sources/VigilUI/Resources`, `Sources/VigilUI/Localizations`, and
  `Fixtures/` in the nine test targets that declare `.copy("Fixtures")`.
* `swift build --product VigilPure` and `swift build` are both green.
* `.gitattributes` marks `*.rtsp`, `*.sdp`, `*.rtsp.txt` as `-text` so CRLF survives checkout.

**Three build defects were found by compiling and are now load-bearing invariants. Do not undo them:**

| Invariant | Why |
|---|---|
| The `VigilPure` product declares `type: .static` | Without it SwiftPM treats it as an *automatic* product, refuses `--product VigilPure`, and silently builds the whole package instead — turning the Linux purity gate into a gate that cannot fail |
| Every directory named in a `resources:` clause exists, with a `.placeholder` inside | A `.copy()`/`.process()` at a missing path is a **hard build error** that blocks every other agent, not a warning |
| Every target directory contains at least one `.swift` file | SwiftPM errors on a target with no sources. `Placeholder.swift` satisfies this until real sources land; **do not delete it yourself** — the supervisor removes it |

---

## 1. The shape of the system, in one page

```
                        ┌───────────────────────── PURE (Foundation only, Linux CI) ──┐
  VigilProtocols ──┬──▶ VigilBitstream ──▶ VigilRTP                                   │
                   ├──▶ VigilRTSP                                                     │
                   ├──▶ VigilISAPI      (+ FoundationNetworking / FoundationXML)       │
                   ├──▶ VigilDiscovery                                                │
                   └──▶ VigilTestKit    (tests only; never linked by the app)          │
                        └───────────────────────────────────────────────────────────────┘
                        ┌───────────────────────── macOS ONLY (#if os(macOS)) ────────┐
  VigilTransport  ← VigilProtocols, VigilRTSP, VigilDiscovery                          │
  VigilVideo      ← VigilProtocols, VigilBitstream                                     │
  VigilRender     ← VigilProtocols, VigilVideo                                         │
  VigilCore       ← Protocols, RTSP, RTP, Bitstream, ISAPI, Discovery, Transport, Video │
  VigilUI         ← VigilProtocols, VigilCore, VigilRender                              │
  Vigil (exe)     ← VigilUI, VigilCore                                                 │
                        └───────────────────────────────────────────────────────────────┘
```

Forbidden edges, restated because they are the rules most likely to be broken:
`VigilRTSP ↛ VigilRTP`, `VigilRTP ↛ VigilRTSP`, `VigilCore ↛ VigilRender`, `VigilCore ↛ VigilUI`,
`VigilVideo ↛ VigilRTP`, `VigilRender ↛ VigilCore`, `VigilUI ↛ VigilTransport/RTSP/RTP`,
`VigilDiscovery ↛ VigilRTSP`, any pure target ↛ any Apple framework, anything ↛ `VigilTestKit`
outside `Tests/`.

The frame path, with the exact type at every boundary:

```
NWConnection(Data) →[VigilTransport]→ RTSPSessionMachine.ingest → RTSPAction.emitMedia(channel:payload:)
  → RTPTrackReceiver.ingestRTP → EncodedFrame (4-byte BE length-prefixed NALs, MediaTimestamp pts)
  → EncodedFrameQueue (8 frames / 1500 ms, drop-to-keyframe)
  → VigilVideo: FormatDescriptionFactory → CMSampleBuffer → AVSampleBufferDisplayLayer
                                                      or → VTDecompressionSession → VideoFrame
  → VigilRender: VideoSink.enqueue(_:) → CAMetalLayer / ASBDL   (zero main-actor hops on the Metal path)
```

---

## 2. Rulings

Every row of `docs/OPEN-CONFLICTS.md` plus every contradiction found while writing this contract.
Format: **what each spec said → the ruling → why → which documents must be amended.**

A ruling marked **[BUILD]** breaks compilation or linking if ignored. **[SEMANTIC]** produces code
that compiles but misbehaves. **[COSMETIC]** is a consistency matter that must still be settled once.

### 2.1 Type ownership and shape

#### R-01 — `VigilRTP` **does** depend on `VigilBitstream` **[BUILD]**

*Said:* `ARCHITECTURE.md` §2.2 and `spec-bitstream.md` §1.1 assert the edge exists and is mandatory.
`spec-rtp.md` §1.1 asserts it does not, and proposes a "40-line local peeker"
(`Sources/VigilRTP/SliceHeaderPeek.swift`) built directly on `BitReader`.

*Ruling:* **the edge exists.** `Package.swift` already declares
`.target(name: "VigilRTP", dependencies: ["VigilProtocols", "VigilBitstream"])` and that manifest is
compiled and green. `VigilRTP` **must** use `VigilBitstream` for: `H264NALType`/`H265NALType`,
`NALHeader.decodeH264`/`decodeHEVC`/`typeCode`, `LengthPrefixed.append(nal:to:)`, and
`SliceHeader.isFirstSliceOfPicture(nalUnit:codec:)`. `Sources/VigilRTP/SliceHeaderPeek.swift` is
**deleted from the manifest** — a duplicate slice-header parser is a review-blocking defect, because
the two copies will disagree on exactly the malformed input that matters.

*Why:* a second implementation of `first_mb_in_slice` / `first_slice_segment_in_pic_flag` is the
single highest-risk duplication in the repo — access-unit splitting is already not allowed to trust
the marker bit, so this predicate *is* the AU boundary. One implementation, one set of fuzz tests.
The claimed benefit (parallel implementation of RTP and Bitstream) is bought back by the wave plan:
`VigilBitstream` and `VigilRTP` are both W2, and `VigilRTP` depends only on the four surfaces listed
above, which are declared in §4.3 and can be stubbed for an afternoon if genuinely necessary.

*Amend:* `spec-rtp.md` §1.1 (dependency claim) and §1.2 (drop `SliceHeaderPeek.swift`); §7.3 becomes
a reference to `VigilBitstream.SliceHeader`.

#### R-02 — `EncodedFrame`, `MediaTimestamp` and friends are declared **here**, verbatim **[BUILD]**

*Said:* `ARCHITECTURE.md` §2.4 gives them to `VigilProtocols`; `spec-rtp.md` §2 calls itself "their
authoritative definition"; `spec-video-pipeline.md` §2 restates them; `spec-bitstream.md` §2 restates
them differently. The four versions disagree on: `data` type (`Data` vs `[UInt8]`), `codec` type
(`Codec` vs `VideoCodec`), `dts` optionality, the arrival-time field (`receivedAt: MonotonicTime` vs
`receivedHostTime: UInt64`), and whether `ParameterSets` carries `codec`.

*Ruling:* §3 of this document is the **only** normative declaration. All four specs become
explanatory. The field-level rulings are R-03 … R-08.

*Why:* four partial declarations of a boundary struct is the canonical way to get code that does not
link. §3 is written to be pasted, not paraphrased.

*Amend:* `spec-rtp.md` §2, `spec-video-pipeline.md` §2, `spec-bitstream.md` §2 — each replaces its
declaration with a pointer to `API_CONTRACT.md` §3 and keeps only its *semantics* prose.

#### R-03 — `Data`, not `[UInt8]`, at every boundary **[BUILD]**

*Said:* `spec-rtp.md` uses `Data` for `EncodedFrame.data` and `[Data]` for parameter sets;
`spec-bitstream.md` uses `[UInt8]` and `[[UInt8]]` throughout, including in
`AVCDecoderConfigurationRecord.init(sps:pps:spsExt:)`.

*Ruling:* **`Data` for anything stored in a type that crosses a module or isolation boundary.**
`[UInt8]` is permitted only as a *local scratch buffer* inside one function or as the return of an
unescape/serialize helper. Concretely:

| Where | Type |
|---|---|
| `EncodedFrame.data` | `Data` |
| `ParameterSets.vps/.sps/.pps` | `[Data]` |
| `AVCDecoderConfigurationRecord` / `HEVCDecoderConfigurationRecord` stored arrays and `init` params | `[Data]`, `serialized() -> Data` |
| `RBSP.unescape(...)` return, `AnnexB.toLengthPrefixed(...)` | `[UInt8]` (scratch) |
| `BitReader` backing storage | `[UInt8]`, with a convenience `init(_ data: Data)` |
| Parser entry points | `UnsafeRawBufferPointer` (call through `Data.withUnsafeBytes`) |

*Why:* `Data` is `Sendable`, is what `Foundation`/`URLSession`/`NWConnection` hand us, is what
`AVAssetWriter` and `CMBlockBufferCreateWithMemoryBlock` want, and avoids one full copy per frame at
the transport boundary. `[UInt8]` inside a `Sendable` boundary struct means a copy in and a copy out.
The one real hazard of `Data` — a slice retaining a megabyte parent — is handled by the existing rule
in §7.6 (`never store a slice long-term without `Data(slice)``).

*Amend:* `spec-bitstream.md` §16, §17, §21, §22 (`[[UInt8]]` → `[Data]`, `[UInt8]` → `Data` on stored
and returned values); `spec-rtp.md` §2.4 note that `data` is `Data`.

#### R-04 — one flat `MediaCodec` on `EncodedFrame`; `VideoCodec` and `AudioCodec` both exist **[BUILD]**

*Said:* `ARCHITECTURE.md` §2.4 → `VideoCodec` (`h264, h265, mjpeg`) and `AudioCodec`.
`spec-bitstream.md` → `VideoCodec` (`h264, h265` only, with `nalHeaderLength`).
`spec-rtp.md` → a single `Codec` (`h264, h265, aac, pcmS16LE`) used by `EncodedFrame`.
`spec-isapi.md` Appendix B lists both `VideoCodec` and `AudioCodec`.

*Ruling:* three enums, each with one job, all in `VigilProtocols` (§3.4):

* `VideoCodec` — `h264, h265, mjpeg`. Carries `nalHeaderLength` (1 / 2 / 0) and `isNALBased`.
  Used by `ParameterSets`, `VideoFormatInfo`, ISAPI stream config, format-change detection.
* `AudioCodec` — `aac, g711A, g711U, g726, pcmS16LE`. Used by ISAPI stream config and audio format.
* `MediaCodec` — the flat union carried by `EncodedFrame.codec`, with `var video: VideoCodec?` and
  `var audio: AudioCodec?` bridges so a video-path `switch` stays one line.

*Why:* `EncodedFrame` genuinely carries both video and audio, so it needs a union. `ParameterSets`
and `VideoFormatInfo` genuinely cannot be audio, so making them take the union would push
unrepresentable states into every parser. `mjpeg` must be in `VideoCodec` because F-DEC-05 (MJPEG)
and the class-D JPEG-poll tile mode both reference it.

*Amend:* `spec-rtp.md` §2.3 (`Codec` → `MediaCodec`, add the two narrow enums);
`spec-bitstream.md` §2 (`VideoCodec` gains `mjpeg`; guard `nalHeaderLength` on `isNALBased`).

#### R-05 — `MediaTimestamp.init` clamps; it does **not** `precondition` **[SEMANTIC, security]**

*Said:* `spec-rtp.md` §2.1 declares
`precondition(timescale > 0 || value == Int64.min, "timescale must be positive")`.

*Ruling:* the initialiser **clamps a non-positive timescale to 1** and documents it. Validation of a
timescale that came off the wire happens exactly once, at `RTPTrackFormat` construction, which throws
`RTPTrackError.invalidClockRate(_:)`.

*Why:* `timescale` is derived from the SDP `a=rtpmap` clock rate — **network data**. A camera (or an
attacker on the LAN) that advertises `a=rtpmap:96 H264/0` would take the whole app down through a
`precondition`. `IMPL_RULES.md` permits `precondition` only for "programmer error that cannot come
from network data"; this is the opposite. `ARCHITECTURE.md` §7.4 is explicit: a malformed packet from
one camera must never crash the app, and that is a security property.

*Amend:* `spec-rtp.md` §2.1.

#### R-06 — `dts` is optional; `duration` is optional **[SEMANTIC]**

*Said:* `spec-rtp.md` `dts: MediaTimestamp?`; `spec-bitstream.md` `dts: MediaTimestamp`;
`spec-video-pipeline.md` "RTP supplies `dts` only when the stream reorders".

*Ruling:* `var dts: MediaTimestamp?`, `nil` when the stream does not reorder — which is every
Hikvision live profile and all audio. `VigilVideo` treats `nil` as "dts == pts" and must **not**
synthesise a decode order. When non-`nil`, `dts <= pts` is guaranteed by the producer.

*Amend:* `spec-bitstream.md` §2.2.

#### R-07 — one monotonic instant type: `MediaInstant`. `RTSPInstant`, `RTSPDuration`, `MonotonicTime` are deleted **[BUILD]**

*Said:* `ARCHITECTURE.md` §5.10 → `protocol MonotonicClock { var nowNanoseconds: UInt64 }`.
`spec-rtp.md` §2.2 → `struct MonotonicTime { nanoseconds: Int64 }` + `protocol MonotonicClock { func now() -> MonotonicTime }`.
`spec-rtsp.md` §2.4 → `struct RTSPInstant` + `struct RTSPDuration`.
`spec-isapi.md` §1 → `protocol VigilClock { var now: Date; func sleep(for:) }`.

*Ruling:* `VigilProtocols` declares exactly one instant type, `MediaInstant` (`nanoseconds: Int64`,
arbitrary epoch, never wall clock), and uses the **standard library `Duration`** for every duration.
`protocol MonotonicClock` has `now()`, `sleep(for:)` and `sleep(until:)`. `protocol WallClock` has
`now: Date`, used only for display, RTCP NTP mapping and parsed playback ranges.
`RTSPInstant`, `RTSPDuration`, `MonotonicTime` and `VigilClock` do not exist.

*Why:* four spellings of "nanoseconds since boot" means four conversion helpers, and the RTSP machine
and the RTP receiver must timestamp against the *same* origin or the glass-to-glass latency estimate
(FEATURES L8, ±25 ms) is meaningless. `Duration` is in the stdlib, works on Linux, carries its unit
in the type (satisfying §7.5's units-in-the-name rule without a name), and already appears in
`MonotonicClock.sleep(for:)`.

*Amend:* `spec-rtsp.md` §2.4 and every `RTSPInstant`/`RTSPDuration` use (a mechanical rename;
`.seconds(5)` and `.milliseconds(400)` are `Duration` factories with the same spelling);
`spec-rtp.md` §2.2; `spec-isapi.md` §1 and §4 (`VigilClock` → `MonotonicClock` + `WallClock`);
`ARCHITECTURE.md` §5.10.

#### R-08 — `EncodedFrame.receivedAt: MediaInstant` **[BUILD]**

*Said:* `spec-rtp.md` → `receivedAt: MonotonicTime`; `spec-bitstream.md` → `receivedHostTime: UInt64`
("mach_absolute_time domain").

*Ruling:* `var receivedAt: MediaInstant` — arrival of the **last** packet of the frame, which is the
anchor for the glass-to-glass estimate. `mach_absolute_time` raw ticks never appear in a pure type;
`SystemMonotonicClock` converts once.

*Amend:* `spec-bitstream.md` §2.2.

#### R-09 — one randomness protocol: `RandomSource`. `RTSPRandomSource` is deleted **[BUILD]**

*Said:* `ARCHITECTURE.md` §5.10 → `protocol RandomSource { mutating func next() -> UInt64 }`;
`spec-rtsp.md` §2.5 → `protocol RTSPRandomSource { func randomBytes(_:) -> [UInt8] }` (non-mutating).

*Ruling:* one protocol, `RandomSource`, `mutating func next() -> UInt64`, with a
**protocol extension** providing `mutating func randomBytes(_ count: Int) -> [UInt8]` and
`mutating func hexString(bytes:)`. `RTSPDeterministicRandom` / `RTSPSystemRandom` become
`SplitMix64RandomSource` (seeded, in `VigilProtocols` so both tests and fixtures use it) and
`SystemRandomSource`.

*Why:* `mutating` is required for a seeded generator to advance reproducibly, which is the entire
point (`ARCHITECTURE.md` §5.10: "a failing CI run prints a seed"). A non-mutating `randomBytes`
forces either a class with a lock or a non-reproducible source. Digest `cnonce` generation then reads
`rng.randomBytes(8)` and is deterministic under test.

*Amend:* `spec-rtsp.md` §2.5, §6.4.

#### R-10 — **all** domain error enums live in `VigilProtocols` **[BUILD]**

*Said:* `ARCHITECTURE.md` §7.1 declares `enum VigilError` in `VigilProtocols` wrapping
`RTSPError`, `RTPError`, `BitstreamError`, `ISAPIError`, `DiscoveryError`, … and §2.4's registry says
"`VigilError` + all domain error enums | `VigilProtocols`". But `spec-rtsp.md` §15 declares
`RTSPError` inside `VigilRTSP`, `spec-bitstream.md` §22 declares `BitstreamError` inside
`VigilBitstream`, `spec-isapi.md` §9 declares `ISAPIError` inside `VigilISAPI`, and `spec-rtp.md`
§14.3 declares three error enums inside `VigilRTP`.

*Ruling:* **every error enum named by `VigilError` is declared in `VigilProtocols`**, in
`Sources/VigilProtocols/Errors/DomainErrors.swift`. Module-local errors that `VigilError` does *not*
wrap may stay in their module (there are none in the current design).

*Why:* this one is not a style preference, it is a cycle. If `VigilError` (in `VigilProtocols`) has a
case `.rtsp(RTSPError)` and `RTSPError` lives in `VigilRTSP`, then `VigilProtocols` must import
`VigilRTSP`, which imports `VigilProtocols`. SwiftPM rejects the cycle and nothing builds. The
alternatives were considered and rejected: (a) `VigilError.wrapped(any VigilFailure)` destroys
`Equatable`/`Hashable`/`Codable` conformance and makes `switch` on a cause impossible, and every
retry decision in `StreamController` switches on the cause; (b) no root enum at all means every
`throws(VigilError)` boundary becomes untyped, contradicting §7.7.

Consequence for the wave plan: the error taxonomy is **W1 work, done once, by the `VigilProtocols`
agent**, from the case lists in `ARCHITECTURE.md` §7.2 plus each module spec's error section. It is
the single largest W1 file after the crypto set. §3.11 fixes the shape and the complete case list.

*Amend:* `spec-rtsp.md` §15, `spec-rtp.md` §14.3, `spec-bitstream.md` §22, `spec-isapi.md` §9,
`spec-discovery.md` §12, `spec-core.md`, `spec-video-pipeline.md`, `spec-render.md` — each keeps its
case list as documentation and states that the declaration is in `VigilProtocols`.

#### R-11 — the describing protocol is named `VigilFailure` **[COSMETIC]**

*Said:* `ARCHITECTURE.md` §7.1 → `protocol VigilErrorDescribing`; `spec-rtsp.md` §19 → "the
`VigilFailure` protocol".

*Ruling:* `VigilFailure`. Same members as `VigilErrorDescribing` (`diagnosticCode`, `severity`,
`disposition`, `userMessage`, `userRemedy`, `logMetadata`). `VigilError` and every domain enum
conform. `LocalizedError` conformance is added by an extension in `VigilCore` so the pure layer stays
Foundation-minimal while AppKit alerts still work.

*Amend:* `ARCHITECTURE.md` §7.1.

#### R-12 — `FrameGeometry`, `ColorInfo`, `FieldOrder` live in `VigilProtocols` **[BUILD]**

*Said:* `spec-render.md` §2 → `VigilProtocols` (pure, no CoreVideo; `VigilBitstream` computes them
from SPS/VPS VUI, so they are Linux-testable). `spec-video-pipeline.md` implies `VigilVideo` by
placing all geometry work next to `CVPixelBuffer`.

*Ruling:* **`VigilProtocols`**, per `spec-render.md`. They are pure arithmetic over integers and
ratios (coded size, clean aperture, SAR, primaries/transfer/matrix codes) and are produced by
`VigilBitstream` from the VUI, which runs on Linux. `VigilVideo` and `VigilRender` consume them;
`VigilRender` additionally derives its layer transforms from them but declares no geometry type.

*Why:* if geometry lived in `VigilVideo` it could not be unit-tested on Linux, and the aspect-ratio /
clean-aperture maths is exactly the kind of thing that needs a hundred table-driven test cases. It is
also required by the recorder and by the "report cropped display size, allocate from coded size"
rule, both of which have non-macOS-specific logic.

*Amend:* `spec-video-pipeline.md` §2 and §4 (consume, do not declare).

#### R-13 — three identifier types, in `VigilProtocols`; `StreamIndex` becomes `StreamQuality` **[BUILD]**

*Said:* `spec-isapi.md` §11.3 declares `ChannelID`, `StreamIndex`, `StreamingChannelID` and `TrackID`
in `VigilISAPI`. `spec-core.md` and the UI both need `StreamQuality`. `ARCHITECTURE.md` §2.4 does not
list any of them.

*Ruling:* all four move to `VigilProtocols`, and `StreamIndex` is renamed **`StreamQuality`**
(`main = 1, sub = 2, third = 3`). The three-way distinction is preserved and is load-bearing:

| Type | Space | Used by |
|---|---|---|
| `ChannelID` | 1-based video **input** channel | `/Image/channels/{ch}`, `/PTZCtrl/channels/{ch}`, `/System/Video/inputs/channels/{ch}`, motion config, `EventNotificationAlert.channelID` |
| `StreamingChannelID` | `ch * 100 + quality.rawValue` | `/Streaming/channels/{id}`, `/Streaming/channels/{id}/picture`, the RTSP path |
| `TrackID` | same numeric space, different concept | `/ContentMgmt/record/tracks`, `CMSearchDescription.trackIDList`, `/Streaming/tracks/{id}` |

They are **not** interchangeable and none is `ExpressibleByIntegerLiteral` except `ChannelID`.

*Why:* `VigilCore` persists them on `Camera` (so they must be `Codable` and visible without importing
`VigilISAPI` from a Codable model), `VigilUI` displays them, `VigilRTSP` receives a built path, and
`VigilDiscovery` reports channel counts. A type that four modules need is a `VigilProtocols` type by
the standing rule in `ARCHITECTURE.md` §2.4. The rename removes the third spelling of the same
concept (`StreamIndex` / `StreamQuality` / "stream index").

*Amend:* `spec-isapi.md` §11.3 and Appendix B; `spec-core.md` §4.

#### R-14 — one `Credential`; `ISAPICredential` is deleted; `Camera` has no password **[BUILD]**

*Said:* `ARCHITECTURE.md` §2.4 → `Credential` in `VigilProtocols`, value type only.
`spec-isapi.md` §3 → `ISAPICredential` in `VigilISAPI`, deliberately not `Codable`.
`spec-core.md` §6 → `Credential` (not `Codable`, Keychain-only), plus `CredentialRef` and
`CredentialDescriptor`. `FEATURES.md` §20.2 → Keychain only, `Camera` has no `password` property.

*Ruling:* `VigilProtocols` declares `Credential` (username + password, **not** `Codable`, redacting
`description` *and* `debugDescription`) and `CredentialRef` (an opaque `UUID`, `Codable`, safe to
persist). `ISAPICredential` is deleted. `CredentialDescriptor` (the Keychain query shape) stays in
`VigilCore` because it names Keychain attributes. `Camera` stores `credentialRef: CredentialRef?` and
has no password-shaped property — enforced by the type, and by a test that reflects over
`Camera`'s `CodingKeys`.

*Amend:* `spec-isapi.md` §3, §4, §18 and Appendix B (`ISAPICredential` → `Credential`).

#### R-15 — one logging protocol: `LoggerProtocol`, 13 categories, and one `Redact` **[BUILD]**

*Said:* `ARCHITECTURE.md` §8.1/§8.2 → `LoggerProtocol`, `LogLevel`, `LogCategory`, `LogEvent`, with
**13** categories (`app, discovery, rtsp, rtp, bitstream, isapi, transport, video, render, core,
storage, ui, perf`) and `String.redactingSecrets()` plus a `Redaction.swift`. `spec-isapi.md` §1 →
`VigilLogger` + `Redaction.mask(_:)`. `spec-core.md` §15 → `LogRedaction`. `FEATURES.md` §20.6 → one
pure `Redact` in `VigilProtocols`, and a **different, 14-entry** category list (`app, discovery, rtsp,
rtp, bitstream, decode, render, isapi, events, record, playback, health, store, security`).

*Ruling:* `LoggerProtocol` / `LogLevel` / `LogCategory` / `LogEvent` exactly as
`ARCHITECTURE.md` §8.2, with `ARCHITECTURE.md`'s **13 categories**. Redaction is one type,
`enum Redact`, in `Sources/VigilProtocols/Logging/Redact.swift`. `VigilLogger`, `LogRedaction`,
`Redaction` and `String.redactingSecrets()` do not exist.

`FEATURES.md`'s extra categories map onto the 13: `decode → video`, `events → core`,
`record → core`, `playback → core`, `health → perf`, `store → storage`, `security → core`.

*Why:* the 13-category list is the one with working code beside it (`OSLogLogger`, §8.2) and it is the
list the diagnostics bundle and the log-level Settings pane index. Two lists means log filters that
silently match nothing. `Redact` (the `FEATURES.md` name) wins over `Redaction`/`LogRedaction` because
`FEATURES.md` §20.6 makes redaction a *shipping requirement* with a fuzz test, and names it.

*Amend:* `FEATURES.md` §20.6 (category list); `spec-isapi.md` §1; `spec-core.md` §15;
`ARCHITECTURE.md` §8.6 (`String.redactingSecrets()` → `Redact`).

#### R-16 — pure SHA-1 and SHA-256 in `VigilProtocols`; `CryptoKit` is banned everywhere **[BUILD]**

*Said:* `ARCHITECTURE.md` §14.9 → MD5 + CRC32 + a thin Base64 wrapper in `VigilProtocols`, and
"`SHA-256`, when needed for TLS certificate fingerprint display, comes from `CryptoKit` in a
macOS-only target". `FEATURES.md` → **MD5, SHA-1 and SHA-256**, pure Swift, in `VigilProtocols`, and
"no other module may implement a hash". `spec-rtsp.md` §1 → MD5 plus a **padding-tolerant** Base64
because Foundation's decoder rejects Hikvision's unpadded `sprop-*`. `spec-isapi.md` → MD5.
`OPEN-CONFLICTS.md` C5 → all four files in `VigilProtocols/Crypto/`, first wave.

*Ruling:* `Sources/VigilProtocols/Crypto/` ships `MD5.swift`, `SHA1.swift`, `SHA256.swift`,
`Base64.swift` (padding-tolerant, whitespace-tolerant, URL-safe-tolerant) and `CRC32.swift`, all pure
Swift, all streaming-capable, all tested against published RFC vectors on Linux. **`import CryptoKit`
is forbidden in every target**, including macOS ones. TLS fingerprint display uses
`VigilProtocols.SHA256`.

*Why:* SHA-1 is needed for ONVIF WS-UsernameToken, which is parsed in `VigilDiscovery` — a pure,
Linux-tested target. SHA-256 is needed for the encrypted config export *and* for the TOFU SPKI pin
that `spec-isapi.md` §6 and `spec-rtsp.md` share via `Camera.tlsPinSPKI256`; the pin must be
computable in a Linux test to be testable at all. Allowing `CryptoKit` for one of the three would
mean two SHA-256 implementations and a lint rule with an exception, which is how the third one appears.

*Amend:* `ARCHITECTURE.md` §14.9 (drop the CryptoKit sentence; `Scripts/lint.sh` bans `CryptoKit`
repo-wide with no exceptions).

#### R-17 — `HTTPTransporting` and its request/response types live in `VigilProtocols` **[BUILD]**

*Said:* `ARCHITECTURE.md` §2.4 → `HTTPTransporting` in `VigilProtocols` ("injection seam so
`VigilISAPI` tests never touch the network"). `spec-isapi.md` §4.1 → `ISAPIHTTPTransporting`,
`ISAPIRawRequest`, `ISAPIResponse`, `HTTPHeaders`, `ISAPIUploadHandle`, and puts the lane enum inside
`ISAPIClient` (`ISAPIClient.Lane`), which `ISAPIRawRequest` then references.

*Ruling:* `VigilProtocols` declares `HTTPHeaders`, `HTTPRequest`, `HTTPResponse`, `HTTPLane` and
`protocol HTTPTransporting`. `ISAPIClient.Lane` becomes `typealias Lane = HTTPLane` for readability at
call sites. `URLSessionHTTPTransport` (the production conformance) lives in `VigilISAPI`;
`FixtureHTTPTransport` lives in `VigilTestKit` (not in the test target — `VigilCoreTests` and
`VigilPipelineTests` need it too).

*Why:* `ISAPIRawRequest` referencing `ISAPIClient.Lane` while `ISAPIClient` holds an
`any ISAPIHTTPTransporting` is a nested-type cycle that compiles but reads terribly, and the
transport seam is also wanted by `VigilDiscovery`'s ONVIF `GetStreamUri` fallback (R1.2 candidate 6),
which must not import `VigilISAPI`. `HTTPHeaders`, `ISAPIChunkedUpload` and `ISAPIUploadHandle` are
named in `spec-isapi.md` Appendix B but **never declared anywhere** in it; §3.14 and §4.5 declare
them here.

*Amend:* `spec-isapi.md` §4.1, §4.2 and Appendix B.

#### R-18 — `IPv4Address`, `MACAddress`, `IPv4Subnet` live in `VigilProtocols`; `IPv4CIDR` is renamed **[BUILD]**

*Said:* `spec-discovery.md` §3 → `IPv4Address` (UInt32-backed) and `MACAddress` (UInt64-backed) in
`VigilProtocols`, with the instruction to write `VigilProtocols.IPv4Address` in files that also import
`Network`. `ARCHITECTURE.md` §2.4 → `IPv4CIDR` in `VigilDiscovery`.

*Ruling:* `IPv4Address`, `MACAddress` and `IPv4Subnet` (the new name for `IPv4CIDR`) are all declared
in `VigilProtocols`. In any file that imports `Network`, spell the type
`VigilProtocols.IPv4Address` — `Network.IPv4Address` exists and the ambiguity is a compile error at
best and a silent wrong-type at worst.

*Why:* `Camera.lastKnownAddress`, `HostPolicy.classify`, the sweep planner, the ARP reader, the
"address reused" guard and `VigilCore`'s reachability checks all need them, spanning four modules.
`IPv4Subnet` reads as what it is; `IPv4CIDR` names a notation, not a value.

*Amend:* `ARCHITECTURE.md` §2.4; `spec-discovery.md` §3 and §6 (`IPv4CIDR` → `IPv4Subnet`).

#### R-19 — `StreamStatistics` shape is `ARCHITECTURE.md` §8.4; `VigilRTP` owns the algebra **[SEMANTIC]**

*Said:* `ARCHITECTURE.md` §8.4 fixes the shape (31 fields, `Codable`); `spec-rtp.md` §13 owns the
update algebra and also declares it; `spec-rtp.md` §14.2 has `RTPTrackReceiver.statistics:
StreamStatistics`, and `VigilVideo` pushes `decodeQueueDepth` in.

*Ruling:* shape per `ARCHITECTURE.md` §8.4, reproduced verbatim in §3.10, declared in
`VigilProtocols`. `VigilRTP` owns every update rule: fps EWMA α = 0.10, kbps EWMA α = 0.25 over a
500 ms window, keyframe-interval EWMA α = 0.20, loss fraction over a 2 s window, jitter per RFC 3550
A.8 converted from timescale units to milliseconds. `VigilVideo` writes `decodeQueueDepth`,
`framesDroppedPreDisplay`, `decodeMillisecondsP50/P99` and `isHardwareAccelerated` through
`RTPTrackReceiver.updateDecodeQueueDepth(_:)` and the sibling setters in §4.9.
`isHardwareAccelerated` is the **measured** value from
`kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder`, never the requested one —
`FEATURES.md` makes honesty a shipping requirement.

#### R-20 — `library.json` is schema **3**, with a separate `events.json` ring **[SEMANTIC]**

*Said:* `ARCHITECTURE.md` §9.3 → `LibraryDocument.currentSchemaVersion = 1`. `spec-core.md` §5 →
schema 3, with a separate `events.json` ring, read-only if the on-disk schema is newer.

*Ruling:* **schema 3.** `spec-core.md` is the persistence owner and was completed last; it defines
the v1→v2→v3 migration chain and the fixtures. The other rules stand unchanged and are restated
because they are easy to lose: `.bak` rotation before every write; write to a sibling temp file then
`FileManager.replaceItemAt`; 500 ms debounce with a guaranteed final write and an awaited `flush()` on
quit; `schemaVersion > current` → `StorageError.schemaTooNew`, **open read-only and write nothing**;
both files unreadable → quarantine to `Corrupt/library-<ISO8601>.json`, start empty, and *tell the
user*. Events live in `events.json` (last 5000, ring) so a large event log can never endanger the
camera list. Recording/snapshot folders are reached through **security-scoped bookmarks** stored in
`folderBookmarks` — a bare path string silently fails to write under the sandbox.

*Amend:* `ARCHITECTURE.md` §9.3.

### 2.2 The tile-size policy — one table, one unit

#### R-21 — one policy table, keyed on **tile short edge in backing pixels** **[SEMANTIC]**

*Said:* three different tables **and three different units**.

* `FEATURES.md` F-STR-06: **short edge in physical px** = `min(width, height) × backingScaleFactor`.
  Buckets `1–95` JPEG poll @ 1 Hz, `96–479` sub, `480–1079` sub-with-promotion, `≥1080` main; plus
  hidden/occluded → paused. 750 ms dwell + 15 % dead-band; switch gated on the new stream's first
  keyframe with a 150 ms crossfade, never a black frame.
* `spec-video-pipeline.md` §12.5: **backing *width***, buckets `≥1600` main/full, `960–1599`
  main-if-≤4-tiles-else-sub, `640–959` sub, `384–639` sub fps-capped 15, `224–383` sub
  keyframes-only, `<224` JPEG poll 2 s; sidebar 5 s, offscreen 15 s, occluded paused.
* `spec-core.md` §8.5: **total backing pixels**, classes **A–F**: `≥1_500_000` main,
  `350_000–1_499_999` sub-or-main, `60_000–349_999` sub fps-capped 15, `12_000–59_999`
  keyframe-only, `<12_000` JPEG poll 2 s, hidden → paused. 15 % + 750 ms hysteresis.

*Ruling — the unit:* **the tile's short edge in backing (device) pixels**, i.e.
`min(pixelSize.width, pixelSize.height)` where `pixelSize = bounds × backingScaleFactor` rounded to
integers. `spec-render.md` already declares `TileRenderState.pixelSize` the authoritative input,
published through `tile(_:didChangePixelSize:isVisible:)`, and it carries **both** dimensions, so
every candidate unit is derivable from it — this is a naming problem, not a measurement problem.

Short edge beats backing *width* because a 1-up tile on a portrait display and a `1+5` hero cell are
both wider than they are tall, and it is the *shorter* dimension that decides whether a 720-line
sub-stream has enough lines to look sharp. Short edge beats *total pixels* — despite
`spec-core.md`'s argument that non-square cells break width — because total pixels conflates a
1920×135 letterbox strip (259 k px) with a 480×540 cell (259 k px), and those two need opposite
decisions. `spec-core.md`'s own §17.6 test 2 contradicts its own §8.5 table by one class in **both**
directions (it calls 960×540 class C where the table's own example calls it class B, and 480×270
class D where the table's own example calls it class C), which is evidence those boundaries were not
settled. Class letters are kept, because `StreamCoordinator`'s plan is a pure function and
`classB_promotesWhenSubIsSofterThanTile` is a far better test name than `p480to1079_...`.

Then the two axes are separated, which is what the three tables were really conflating:

**Axis 1 — tile size decides which stream to pull.** One table, `FEATURES.md`'s thresholds, with
`spec-core.md`'s class letters attached so the code and the specs can name the buckets:

| Class | Tile short edge (backing px) | Source | Notes |
|---|---|---|---|
| **A** | ≥ 1080 | **Main** stream | 1-up, fullscreen, PiP, video wall |
| **B** | 480 – 1079 | **Sub**, promoted to main if the sub stream's coded height < 0.75 × tile short edge **and** the decode budget admits it | avoids visible softness at 3×3 |
| **C** | 96 – 479 | **Sub** | the 4×4 case |
| **D** | 1 – 95 | **ISAPI JPEG poll**, no decode session at all | micro-thumbnails |
| **E** | hidden / occluded / window minimized | **Paused** — RTSP `PAUSE`, session kept alive, torn down after 60 s | recording-priority streams are exempt (F-DEC-06 rule 5) |

JPEG-poll cadence for class D and for non-tile surfaces, from `spec-video-pipeline.md`:

| Surface | Interval |
|---|---|
| Stage tile in class D | 1 s |
| Sidebar row thumbnail | 5 s |
| Offscreen / menu-bar thumbnail | 15 s |

**Axis 2 — decode-budget pressure decides how hard to run the stream you already have.** This is
where `spec-video-pipeline.md`'s finer rungs live, and they are *not* a function of tile size:

`normal → trim → fpsCap(15) → keyframesOnly → skipToKeyframe → demoteToSub → jpegPoll → paused`

Entry/exit for the first four rungs is the queue-depth/latency ladder in
`spec-video-pipeline.md` §12 (depth EWMA 3.0 / 5.0, latency 220 / 400 ms, 5 s recovery hysteresis);
the last three are `StreamCoordinator` demotions under `F-DEC-06`. Every rung below `normal` must be
**visible** (tile badge) and **explained** (inspector note) — silent degradation is a defect.

**Hysteresis, both axes:** a change requires the new bucket to hold for ≥ **750 ms** and the driving
value to move ≥ **15 %** past the threshold. A continuous window drag from 4×4 to 1-up must produce
**at most one** stream switch; the test that replays a 60-frame resize animation and asserts this is
mandatory. A switch renders the old stream until the new stream's first keyframe decodes, then
crossfades over 150 ms. There is no black frame, ever.

*Why:* `FEATURES.md` owns the release gates and the acceptance criteria, its table is the
customer-visible behaviour, and its four buckets map one-to-one onto the four stream sources that
actually exist on a Hikvision device (main / sub / third-or-JPEG / none). `spec-video-pipeline.md`'s
extra rungs are genuinely valuable — an fps cap and a keyframes-only mode are the right responses to
*budget* pressure on a 16-tile wall — but expressing them as size buckets made a 384 px tile behave
differently from a 384 px tile, depending on which document you read. Separating the axes keeps every
mechanism all three authors wanted and removes the contradiction. `spec-core.md`'s class letters are
kept because `StreamCoordinator`'s plan is a pure function whose test names read much better as
"classB_promotesWhenSubIsSofterThanTile" than as "480to1079_...".

There is **no class F**: `spec-core.md`'s six-way split collapses to five because its "fps-capped 15"
and "keyframe-only" rungs move to Axis 2, where they belong.

*Amend:* `spec-video-pipeline.md` §12.5 (replace the size table with Axis 2 and a pointer here);
`spec-core.md` §8.5 (classes A–F on total pixels → A–E on short edge) and §17.6 test 2 (fix the two
shifted class letters); `FEATURES.md` F-STR-06 (add the class letters, the JPEG-cadence sub-table,
and a pointer to Axis 2).

#### R-22 — decode budget: **24 DU** Apple silicon, **10 DU** Intel; `DecodeBudget` is in `VigilVideo` **[SEMANTIC]**

*Said:* `spec-video-pipeline.md` §12 → "seed **20 DU** / 24 sessions on base M1, runtime-calibrated",
`DecodeBudget` is a `@globalActor` in `VigilVideo` and the single admission authority.
`FEATURES.md` F-DEC-06 → "Total budget: **24 DU** on Apple silicon, **10 DU** on Intel, detected at
launch via `sysctlbyname("hw.optional.arm64")` plus core count; user-overridable in Settings".

*Ruling:* the numbers are **24 DU on Apple silicon / 10 DU on Intel**, user-overridable, with a hard
concurrent-session cap of **24** `VTDecompressionSession`s regardless of DU. Runtime calibration may
*lower* the seed after measuring, never raise it above the seed. 1 DU = 1080p30;
`cost = ceil((width × height × fps) / (1920 × 1080 × 30) × 4) / 4` (0.25 DU granularity). Ownership
is unchanged: `DecodeBudget` is a `@globalActor actor` in `VigilVideo`, the single admission
authority; `StreamCoordinator` supplies priority, consumes demotions, and keeps **no** budget of its
own. `VigilCore` reaches it only through `protocol DecodeAdmitting` (§4.9), which is what makes
`StreamCoordinator` testable without VideoToolbox.

*Why:* `FEATURES.md` numbers are release gates with an Intel path and a Settings control behind them;
`spec-video-pipeline.md`'s 20 was a hand-tuned seed for one machine. Keeping the session cap at 24
preserves the real constraint `spec-video-pipeline.md` was protecting (VideoToolbox stops creating
sessions long before the DU budget is exhausted on small streams).

Priority order, exactly as `FEATURES.md` F-DEC-06 (ties broken by ascending `orderIndex`):
`focused > visible-in-main-window > wall > PiP > recording (never demoted, never occlusion-paused) >
offscreen/prewarm > sidebar thumbnail (JPEG poll, 0 DU)`.

*Amend:* `spec-video-pipeline.md` §12.

### 2.3 Ownership of behaviour

#### R-23 — `VigilISAPI.HikvisionURL` is the single RTSP path builder, and it must expose a **ladder** **[SEMANTIC]**

*Said:* `spec-discovery.md` §12 claims the vendor path table as reusable; `spec-isapi.md` §12.4
declares `HikvisionURL` "the single RTSP path builder"; `spec-rtsp.md` §10 contains the authoritative
per-firmware URL table.

*Ruling:* `HikvisionURL` in `VigilISAPI` is the **only** implementation. `spec-rtsp.md` §10's table is
documentation of the wire formats, not a second implementation. `VigilDiscovery` keeps only the coarse
vendor → first-guess-path map it needs for *fingerprinting* and must never be used to build a stream
URL — enforced by the missing `VigilDiscovery → VigilISAPI` edge.

Because R1.2 requires a **probe ladder**, `HikvisionURL` must expose candidates, not one path:

```swift
public static func candidates(channel: ChannelID, quality: StreamQuality) -> [RTSPPathCandidate]
```

in exactly the R1.2 order (`/Streaming/Channels/{ch}0{q}`, `/Streaming/Channels/{ch}`,
`/Streaming/tracks/{ch}01`, `/h264/ch{ch}/{main|sub}/av_stream`, `/mpeg4/ch{ch}/sub/av_stream`,
then the ONVIF `GetStreamUri` marker). `HikvisionURL` returns **path strings**;
`VigilCore` composes them into an `RTSPURL`, because `VigilRTSP` has no edge to `VigilISAPI` and must
not gain one. The winning template is persisted on the `Camera` record so the ladder runs at most
once per device, ever.

*Amend:* `spec-discovery.md` §12; `spec-rtsp.md` §10 (mark the table informative);
`spec-isapi.md` §12.4 (add `candidates`).

#### R-24 — the keyframe-request chain is fixed, and has no shortcut **[BUILD]**

*Said:* `spec-rtp.md` §7 → `VigilISAPI` must expose `requestKeyFrame(channelID:)`, and it is the
primary response to a detected gap. `spec-video-pipeline.md` §12 → `VigilCore` owns the wire call and
`VigilVideo` only asks via an injected closure.

*Ruling:* they compose; the chain is normative and has exactly these links:

```
VigilRTP  emits DepacketizerEvent.keyframeNeeded(reason:)      ─┐
VigilVideo emits DecodeEvent.keyframeNeeded(reason:)           ─┤
                                                                ├─▶ StreamController (VigilCore)
                                                                │      ├─▶ ISAPIDeviceSession.requestKeyFrame(channel:)   [primary]
                                                                │      └─▶ RTSPCommand.setParameter("keyFrameRequest")     [fallback]
VigilRender never participates.                                ─┘
```

`VigilRTP → VigilISAPI` and `VigilVideo → VigilISAPI` are **forbidden edges**; wiring one is a
review-blocking defect even though it would compile through `VigilCore`'s dependency list. Rate limit:
at most one keyframe request per camera per **2 s**, and at most 5 in any 30 s, then stop asking and
escalate to a reconnect — a keyframe-request storm is how you make an NVR unresponsive.

*Amend:* `spec-video-pipeline.md` §12 (name the chain); `spec-rtp.md` §7 (state that `VigilRTP` only
*emits*).

#### R-25 — auth lockout: **2** credentialed 401s per device is terminal, on one shared counter **[SEMANTIC, safety]**

*Said:* `ARCHITECTURE.md` §7.5 → max **2** authenticated attempts, one shared per-device counter
across RTSP and ISAPI. `spec-rtsp.md` §14.2 → `RTSPSessionConfig.maxAuthAttemptsPerRequest = 4`.
`spec-isapi.md` §4.7 → hard-block after **2** consecutive failures per (host, username), absolute
across all lanes. `spec-core.md` → terminal after two fresh-nonce 401s, with at most **3** credential
probes per host+account per 10 minutes.

*Ruling:*

1. A `401` whose `WWW-Authenticate` nonce differs from the one we used, or which carries
   `stale=true`, is **not** a failed login. Retry immediately, once. It does not count.
2. A `401` answering a request that already carried a plausible `Authorization` header counts as one
   attempt. The **second** such `401` ⇒ terminal `authRejected` / `authenticationFailed`. No retry on
   any schedule, ever, until the user supplies a new credential.
3. `maxAuthAttemptsPerRequest` is **2**, not 4.
4. **One counter per device**, held by `StreamCoordinator`, shared by `StreamController` and every
   `ISAPIDeviceSession` lane, so RTSP and ISAPI cannot each burn attempts independently.
5. `GET /ISAPI/Security/userCheck` is the cheap pre-flight probe before any reconnect on a camera
   whose credentials were just edited, because it reports lockout state and remaining attempts. It is
   rate-limited to **3 probes per (host, account) per 10 minutes**.
6. Auth failure **never** auto-retries and always prompts. `RetryDisposition.retryAfterUserAction`.

*Why:* Hikvision firmware locks an account for 30 minutes after ~5 consecutive failed logins
(`illegalLoginLock`), including the camera's own web UI. A 4-attempt budget on two independent
counters is 8 attempts, which locks the user out of their own camera. That is the single worst
possible failure of this app, and it is a two-line fix.

*Amend:* `spec-rtsp.md` §14.2 and §6.7 (4 → 2).

#### R-26 — `VigilRTSP` emits `RTSPTrackTiming`; `VigilRTP` owns all timestamp maths **[SEMANTIC]**

*Said:* `spec-rtsp.md` §9/§19 → `VigilRTSP` never builds a `MediaTimestamp`; it emits
`RTSPTrackTiming` (raw `seq`, `rtptime`, `clockRate`, `absoluteStart`, `scale`,
`isRateControlDisabled`, `playResponseInstant`). `spec-rtp.md` §11 → owns the unwrapper, presentation
clock and PLL.

*Ruling:* adopted as stated. `VigilRTSP` performs **no** modular arithmetic on RTP timestamps and
never compares `rtptime` across tracks. `VigilRTP` pre-unwraps the 32-bit wraparound before building
any `MediaTimestamp`, so `VigilVideo` never sees a wrap. The presentation clock (min-filter + PLL) is
**not** used to pace live output — live pacing is `AVSampleBufferDisplayLayer` +
`DisplayImmediately` with no timebase. It is used for the latency estimate, for A/V offset reporting,
and for recorded playback.

`RTSPTrackTiming.playResponseInstant` is a `MediaInstant` per R-07.

#### R-27 — every `AsyncStream` is a factory over one bounded broadcaster **[BUILD]**

*Said:* `spec-core.md` → every `AsyncStream` accessor is a factory over a shared bounded broadcaster,
never `.unbounded`. `spec-video-pipeline.md` → `AsyncStream.Continuation` is the only sanctioned
bridge out of C callbacks. `ARCHITECTURE.md` §14.10 → every `AsyncStream` documents its buffering
policy at the creation site.

*Ruling:* all three, combined and made mechanical:

* A property of the form `var events: AsyncStream<E>` is **forbidden** — a stored stream has exactly
  one consumer and the second caller silently gets nothing. Declare
  `func eventStream() -> AsyncStream<E>` (or `makeEventStream()`), which registers a new consumer on
  an internal bounded broadcaster and returns a fresh stream. `onTermination` deregisters.
* `.bufferingPolicy` is **always** explicit. `.unbounded` is forbidden in `Sources/`.
  Standing capacities: RTP packets 512 (evict oldest, mark gap); `EncodedFrameQueue` 8 frames **or**
  1500 ms of PTS span, drop-to-keyframe; decoded frames `.bufferingNewest(3)`; ISAPI alert-stream
  events `.bufferingNewest(256)`; ISAPI byte streams `.bufferingNewest(64)`; recorded-playback frames
  32 with **real** backpressure (the one place we apply it, because a file can be read at the
  consumer's pace).
* Every drop is counted into `StreamStatistics` and surfaced. A drop that no counter records is a bug.

#### R-27a — `DeviceQuirks` is the only firmware-workaround channel **[SEMANTIC]**

*Said:* `spec-isapi.md` §19 → `DeviceQuirks`, a `Codable` value persisted on the camera record,
consulted in exactly four places. `spec-core.md` → `DeviceQuirk` is the single sanctioned
firmware-workaround channel.

*Ruling:* one type, plural name: **`DeviceQuirks`** (`spec-isapi.md` §19's struct of `Bool`/`Int?`
flags, `schemaVersion` included). There is no `DeviceQuirk` singular. It is declared in
`VigilProtocols` — not `VigilISAPI` — because `Camera` (a `Codable` model in `VigilCore`) stores it
and `VigilUI` displays it. It is consulted in exactly **four** places and nowhere else:
the path builder, the body builder, the parser configuration, and the request gate. A firmware
workaround that lives anywhere else — an `if firmware.hasPrefix("V5.4")` in a decoder, a special case
in a view — is a review-blocking defect.

*Amend:* `spec-isapi.md` §19 (declaration moves to `VigilProtocols`); `spec-core.md` (`DeviceQuirk` →
`DeviceQuirks`).

#### R-28 — one `AlertStreamMonitor` per device, never per channel **[SEMANTIC]**

*Ruling:* adopted from `spec-isapi.md` §14 without change, and restated because it is easy to get
wrong when the UI is per-channel: exactly one `AlertStreamMonitor` per device, owned and memoized by
`ISAPIDeviceSession`, referenced (not created) by `VigilCore.EventCenter`. Heartbeat parts are
suppressed at the parser. A `403` on `/ISAPI/Event/notification/alertStream` maps to
`.unsupported` with **no synthetic polling fallback** — a fake event stream is worse than none. A
second `401` ⇒ `.authFailed`, stop permanently, notify `VigilCore`; `VigilCore` calls `start()` again
only on network return or a credential change.

#### R-29 — playback timeline comes only from `POST /ISAPI/ContentMgmt/search` **[SEMANTIC]**

*Ruling:* adopted from `spec-isapi.md` §15. One `searchID` across all pages; the real
`searchResultPostion` misspelling on the wire; paginate while
`responseStatusStrip == "MORE"`. No other endpoint may paint the timeline.
`PlaybackLocator` rewrites scheme/host/port and keeps **path + query verbatim** — Hikvision playback
URIs contain query forms that no URL library round-trips safely, which is also why `RTSPURL` is
hand-written rather than `URLComponents`-based.

#### R-30 — configuration PUTs are read-modify-write, then re-GET **[SEMANTIC]**

*Ruling:* adopted from `spec-isapi.md` §4/§12/§17. Every configuration `PUT` sends the **full**
element, built from a fresh `GET` of that element, echoing the device's `version` and `xmlns`
verbatim; then re-`GET`s and publishes the device's **clamped** values. The UI shows what the device
accepted, never what we asked for. Wire units, restated because every one of them has been got wrong
in the field: `maxFrameRate` = fps × 100; `keyFrameInterval` = **milliseconds**; `GovLength` =
**frames**; storage capacity = **decimal MB**.

#### R-31 — discovery never sends credentials **[SEMANTIC, safety]**

*Ruling:* adopted from `spec-discovery.md` §1 as an absolute rule, not behind a flag, not behind a
preference. Hikvision locks accounts after ~5 failed logins, and a subnet sweep touches every host.
Enforced mechanically: the injected transport protocols have no credential parameter anywhere in
their signatures, and `VigilDiscoveryTests` contains a mock whose `send` fails the suite if the
payload contains a credential-shaped field. `VigilDiscovery` has **no** edge to `VigilRTSP` and
carries its own lenient `StartLineHeaderScanner` for the HTTP-banner fingerprint.

#### R-32 — the pure layer is isolation-free and time-free **[BUILD]**

*Ruling:* restating `ARCHITECTURE.md` §5.1 and `IMPL_RULES.md` because it is the rule most likely to
be broken under deadline. In `VigilProtocols`, `VigilBitstream`, `VigilRTSP`, `VigilRTP`,
`VigilISAPI`, `VigilDiscovery` and `VigilTestKit`:

* **no `actor`**, **no `@MainActor`**, **no `Task`**, **no `async` function** except where a protocol
  the module *declares* is inherently asynchronous (`HTTPTransporting`, `MonotonicClock.sleep`), and
  the module never *calls* it — actors in `VigilTransport`/`VigilCore` do.
* **Exception, granted explicitly:** `VigilISAPI` declares `actor ISAPIClient`, `actor DigestStore`,
  `actor RequestGate`, `actor ISAPIDeviceSession`, `actor PTZController`, `actor AlertStreamMonitor`
  and `actor TwoWayAudioSession`. This is deliberate and is the one pure module that is also a
  *client*: `URLSession` is available in Linux Foundation, so ISAPI is genuinely asynchronous and
  genuinely Linux-testable, and pushing its concurrency into `VigilCore` would mean re-implementing
  the whole client there. These actors hold only `Sendable` state and never touch a platform
  framework. No other pure module may declare an actor.
* **no `Date()`, `Date.now`, `ContinuousClock.now`, `DispatchTime.now()`, `Thread.sleep`,
  `Task.sleep`, `SystemRandomNumberGenerator`.** Time and randomness are parameters. Every pure state
  machine takes `now: MediaInstant` as an argument to `step`/`ingest`/`tick`, so a failing CI run
  prints a seed and re-running with that seed reproduces the failure byte for byte.
* Parsers and state machines are `struct`s with `mutating` methods, owned by an actor elsewhere. They
  are `Sendable` but must never be *shared*.

#### R-33 — exactly two `@unchecked Sendable` types repo-wide **[BUILD]**

*Ruling:* `DecodeSinkBox` (`VigilVideo`, the VideoToolbox callback bridge) and `VideoFrame`
(`VigilVideo`, wraps a `CVPixelBuffer`). Both carry the justification comment shape in §7.4. A third
requires an amendment to this section in the same commit, with a written justification.
`spec-isapi.md` §4.6's `final class URLSessionTransport: … @unchecked Sendable` is **not** a third:
rewrite it as an `actor` holding the delegate state, or as a `final class` whose mutable state lives
behind a single `OSAllocatedUnfairLock`-guarded struct — and on Linux, where `OSAllocatedUnfairLock`
does not exist, behind `NSLock` in a `#if canImport(Darwin)` pair. `spec-rtp.md` §2.2's
`ManualClock` as `final class … @unchecked Sendable` is allowed because it lives in `VigilTestKit`,
which ships to no product the app links; §7.4's cap counts `Sources/` outside `VigilTestKit`.

### 2.4 Design, UX and platform

#### R-34 — structural dimensions: `UX.md`'s numbers win **[COSMETIC]** (`OPEN-CONFLICTS.md` C1)

*Ruling:* sidebar **264** default / min **208** / max **380**; inspector **320** default / min **288**
/ max **440**, per `UX.md` §2.2, because they were derived from the content that has to fit (44 pt
camera rows with thumbnail and sparkline; inspector key/value rows with a 92 pt reserved timecode
column) rather than from grid arithmetic. `DESIGN.md` §5.1 is amended so `VTheme` remains the single
source of tokens. **No view may contain either literal** — both come from `VTheme.Metrics`.

*Amend:* `DESIGN.md` §5.1.

#### R-35 — tile gutter **2 pt**, stage inset **8 pt**: `DESIGN.md` wins **[COSMETIC]** (C2)

*Ruling:* `DESIGN.md` §5.1/§3.6. The 2 pt figure carries an argument — at that width the `#0B0C0F`
canvas reads as a seam between frames without a stroke, and the 3.3 L\* step is deliberately too
small to read as a border. `UX.md`'s 12×12 integer unit grid keeps its cell arithmetic with the gap
value substituted. `LayoutCell → CGRect` takes the gutter from `VTheme`, never a literal.

*Amend:* `UX.md` §5.1.

#### R-36 — no gradient scrim over video: `DESIGN.md` wins **[SEMANTIC, visual]** (C3)

*Ruling:* `DESIGN.md` P1/§2.3. Hover chrome uses `scrim.base` (black α 0.62) **inside the chip or
toolbar shape only** — never a full-tile gradient band. The single permitted full-tile scrim is the
offline/degraded state at α 0.82. There is **no `NSVisualEffectView` over video**, ever: the scrim
ladder is solid α 0.45 / 0.62 / 0.82, and materials are for the sidebar, inspector, toolbar and
detached overlays only. Every video well is true black (`#000000`), and tiles are separated by the
2 pt canvas gutter rather than a border.

*Why:* it is the design authority, the rule is argued from the product thesis ("the frame is
sacred"), and it is the better result — a gradient band across the top of every tile is precisely the
cheap-NVR look the product exists to avoid. `design/mockups/01-main-window.html` already follows this
rule, so the intended result is visible.

*Amend:* `UX.md` §5.3 (28 pt top / 32 pt bottom gradient bars → chip-local scrims).

#### R-37 — 44 pt sidebar rows are legal: control heights and row heights are different tokens **[COSMETIC]** (C8)

*Ruling:* `DESIGN.md` §5.5's "five control heights, no others" (20/24/28/32/40, default 28) governs
**controls** — buttons, fields, pickers, segmented controls. List and table **rows** are a separate
token group, `VTheme.Metrics.Row`, with `camera = 44`, `event = 36`, `channel = 32`, `settings = 28`.
A 44 pt camera row with a 30 pt thumbnail is correct and a reviewer must not flag it. Both groups
remain multiples of 4.

*Amend:* `DESIGN.md` §5.5 (add the row group).

#### R-38 — SwiftPM cannot compile `.metal`; the shipping path is runtime compilation **[BUILD]**

*Said:* `Package.swift` declares `resources: [.process("Shaders")]` for `VigilRender`;
`ARCHITECTURE.md` §12.1 step 8 says the resource bundles "carry `Assets.car`, `default.metallib` and
the `.lproj` folders"; `spec-render.md` §4 says SwiftPM has no `.metal` support so shaders compile at
runtime from an embedded Swift string with an `MTLBinaryArchive` cache.

*Ruling:* `spec-render.md` is right and `ARCHITECTURE.md` §12.1 step 8 is wrong: SwiftPM does not
invoke `metal`/`metallib`, so **no `default.metallib` is ever produced by `swift build`**, and an app
that expects one in its bundle fails to render. The shipping path is:

1. `Sources/VigilRender/Shaders/*.metal` are the reviewable **source of truth**, declared as
   `.process("Shaders")` resources so they land in the bundle for inspection and for the optional
   offline compile.
2. `Sources/VigilRender/Metal/ShaderSource.swift` holds the same text as a `static let` Swift string
   constant. `MetalContext` compiles it at first use with
   `device.makeLibrary(source:options:)`, and caches the result in an `MTLBinaryArchive` under
   `~/Library/Caches/com.vigil.app/shaders/<sha256-of-source>.metallib`.
3. `Scripts/gen-shader-source.swift` regenerates `ShaderSource.swift` from the `.metal` files, and
   `VigilRenderTests` asserts the two are byte-identical. Editing one without the other fails CI.
4. If the source fails to compile, `RenderError.pipelineCompileFailed(_:)` is fatal for the Metal
   path and the tile falls back to `AVSampleBufferDisplayLayer` (§4.10), visibly and with a log at
   `error`. It never shows black.

*Amend:* `ARCHITECTURE.md` §12.1 step 8 (drop `default.metallib`); `Scripts/build-app.sh` step 8
copies `Vigil_VigilUI.bundle` and `Vigil_VigilRender.bundle` for `Assets.car`, the `.lproj` folders
and the `.metal` sources only.

#### R-39 — `Info.plist` needs the two drag-and-drop UTIs and `NSBonjourServices` **[BUILD]**

*Said:* `spec-render.md` §19 → "the architecture doc must add `UTExportedTypeDeclarations` for
`com.vigil.tile-assignment` and `com.vigil.camera-ref`, or drag-and-drop silently fails".
`spec-discovery.md` §9 → `NSLocalNetworkUsageDescription`, `NSBonjourServices`,
`NSAllowsLocalNetworking`, plus the `com.apple.security.network.server` and
`com.apple.developer.networking.multicast` entitlements.

*Ruling:* all adopted. `UTExportedTypeDeclarations` gains two entries beyond `com.vigil.config`:

| Identifier | Conforms to | Used for |
|---|---|---|
| `com.vigil.tile-assignment` | `public.data` | dragging a camera onto a layout cell |
| `com.vigil.camera-ref` | `public.data` | dragging a camera between sidebar, stage and wall |

`NSBonjourServices` = `["_http._tcp", "_rtsp._tcp", "_onvif._tcp"]`. `NSAllowsLocalNetworking` and
`NSLocalNetworkUsageDescription` are already specified in `ARCHITECTURE.md` §12.3 and stay.
`com.apple.security.network.server` is already in `Vigil.entitlements` (needed to bind UDP 37020 /
3702 in the sandbox) and stays. `com.apple.developer.networking.multicast` is a **managed**
entitlement requiring an Apple-issued provisioning profile; the app must run without it and degrade
to a unicast sweep, detected at runtime. There is **one binary** and **no compile-time multicast
flag**.

*Amend:* `ARCHITECTURE.md` §12.3 (`UTExportedTypeDeclarations`, `NSBonjourServices`).

#### R-40 — `VigilUI` uses explicit `@MainActor`, not `.defaultIsolation` **[BUILD]**

*Said:* `ARCHITECTURE.md` §5.3 proposes
`swiftSettings: apple + [.defaultIsolation(MainActor.self)]` on the `VigilUI` target, with explicit
`@MainActor` as a fallback "if the toolchain does not yet accept it".

*Ruling:* the fallback is the plan. `SwiftSetting.defaultIsolation` does not exist in Swift 6.1.2, and
the real, green `Package.swift` does not use it. **Every top-level type in `VigilUI` carries an
explicit `@MainActor`**, and `Scripts/lint.sh` fails on any un-annotated top-level type in
`Sources/VigilUI/`. Do not rely on isolation inference from a `View` conformance — it does not cover
the view model, the coordinator or the `@Observable` class beside it.

*Amend:* `ARCHITECTURE.md` §5.3.

#### R-41 — `Vigil` has no `@main`; `main.swift` calls `.main()` **[BUILD]**

*Ruling:* adopted from `ARCHITECTURE.md` §4.2 Rule 3, restated because it is the one file whose shape
is not negotiable. `Sources/Vigil/main.swift` is a top-level-code file; `VigilApp` is a `struct App`
**without** `@main`. On Linux, `main.swift` writes a message to stderr and exits `EXIT_FAILURE`, which
is what keeps a full `swift build` green on Linux.

#### R-42 — `package` is the default cross-module access level **[COSMETIC]**

*Ruling:* adopted from `ARCHITECTURE.md` §14.4 and `IMPL_RULES.md`, sharpened: §4's declarations are
written `public` where they are part of a module's documented contract (which is what §4 *is*) and
`package` where they exist only so another Vigil target can reach them. When in doubt inside a module,
start at `private`. `open` is forbidden. The `VigilProtocols` types in §3 are all `public`, because
`VigilTestKit`, the app target and the test targets all touch them.

#### R-43 — `ExistentialAny` is on: write `any P` everywhere **[BUILD]**

*Ruling:* `Package.swift` enables the `ExistentialAny` upcoming feature package-wide. Every
existential must be spelled `any P` — `logger: any LoggerProtocol`, `clock: any MonotonicClock`,
`[any VigilFailure]`, `(any Error)?`. A bare protocol name in type position is a **compile error**,
not a warning. This is deliberate: existential boxing must be visible at call sites on the frame path.

#### R-44 — where MJPEG lives **[SEMANTIC]**

*Ruling:* MJPEG appears in three unrelated forms and they must not be conflated.
(a) **ISAPI JPEG poll** (class D, sidebar, offscreen): `GET /ISAPI/Streaming/channels/{id}/picture`,
decoded with `CGImageSourceCreateWithData` in `VigilVideo`, no RTSP session, 0 DU.
(b) **MJPEG over RTP** (`F-DEC-05`, budget cameras): explicitly a **non-goal** for `VigilRTP`
(`spec-rtp.md` §17 lists RTP-JPEG as excluded). A camera advertising only `JPEG/90000` in its SDP
resolves to `StreamDoctor` diagnosis "Codec unsupported", which names the codec and offers to switch
the camera's encoding over ISAPI — exactly the R1.5 behaviour. Do not implement RFC 2435.
(c) **MJPEG over HTTP** (`multipart/x-mixed-replace`): reuses `AlertStreamMonitor`'s multipart parser
in `VigilISAPI` and feeds `VigilVideo`'s JPEG decoder. This is the universal fallback.

*Amend:* `FEATURES.md` F-DEC-05 (split the three forms; drop RTP-JPEG to a non-goal).

#### R-45 — glass-to-glass and launch numbers: `FEATURES.md` §19 is the gate **[COSMETIC]**

*Said:* `BRIEF.md` says "under 250 ms glass-to-glass on LAN" and "16 × 1080p under about 35 % CPU";
`FEATURES.md` §19 gives a per-configuration table (L4 UDP-Low p50 ≤ 95 / p95 ≤ 140; L5 UDP-Balanced
p50 ≤ 120 / p95 ≤ 180; L6 TCP-Balanced p50 ≤ 160 / p95 ≤ 250; L2 launch → first frame p50 ≤ 900 ms /
p95 ≤ 1400 ms; R5 16 × 1080p ≤ 35 % CPU / ≤ 18 % GPU / ≤ 900 MB; U1 UI p99 ≤ 7 ms at 120 Hz; U6 no
main-actor operation > 8 ms; R13 hard ceiling 1.5 GB).

*Ruling:* `FEATURES.md` §19 is the release gate and is consistent with the brief (TCP-Balanced p95 =
250 ms is the brief's number). The brief's figures are the headline; §19's are the contract.
`Scripts/bench.sh` asserts them from the fixed signpost names, which are **permanent API, not debug
scaffolding**: `launch`, `launchToFirstFrame`, `describe`, `setup`, `firstRTP`, `firstKeyframe`,
`decode`, `render`, `snapshot`, `recordStart`, `paletteOpen`, `timelineDraw`.

#### R-46 — `EventNotification` vs `EventNotificationAlert` **[BUILD]**

*Said:* `spec-isapi.md` §14.3 and `ARCHITECTURE.md` §2.4 say `EventNotificationAlert`; the same
document's Appendix B says `EventNotification`.

*Ruling:* **`EventNotificationAlert`** — it matches the wire element name
`<EventNotificationAlert>`, which is the whole value of naming it after the protocol.

*Amend:* `spec-isapi.md` Appendix B.

#### R-47 — R1 is an API requirement, not a UI flourish **[SEMANTIC]**

*Ruling:* `REQUIREMENTS-CUSTOMER.md` R1 forces four things into the API surface, and each is named
here so nobody treats it as optional:

1. **Probe ladder** — `HikvisionURL.candidates(channel:quality:)` (R-23) plus
   `RTSPCommand.describeOnly` (already in `spec-rtsp.md` §14.4) plus a `StreamProbe` in `VigilCore`
   that runs candidates **concurrently, bounded to 3 in flight**, treats `200` + parseable SDP with a
   supported video codec as a win, `404`/`455` as "next", and **`401` as "this path is correct, apply
   credentials"** — never as "advance the candidate". The winner is persisted on `Camera`.
2. **Channel enumeration** — `ISAPIDeviceSession.channels()` over
   `/ISAPI/ContentMgmt/InputProxy/channels` and `/ISAPI/System/Video/inputs/channels`, every populated
   channel offered pre-checked; if ISAPI is unavailable, probe channels 1…16 with a short-timeout
   `DESCRIBE`.
3. **Transport self-healing** — default TCP interleaved; if UDP is selected and no RTP arrives within
   **5 s**, fall back to TCP automatically and persist that per device. The user is never asked about
   transport. (`spec-rtsp.md` §14.2's `udpFirstPacketTimeout` is 3 s for the *machine's* timer; the
   5 s figure is the `StreamController` watchdog that triggers the *fallback*. Both exist; they are
   not the same timer.)
4. **Nine named diagnoses** — `StreamDoctor` must resolve every failure to one of R1.5's nine
   diagnoses, each with a cause sentence and a concrete action. A raw error code or an empty tile is a
   defect. `VigilError.diagnosticCode` is for the log and the "copy details" button, never for the
   user-facing sentence.

#### R-48 — no transcoding, no cloud, LAN-only egress, zero telemetry **[SEMANTIC]**

*Ruling:* adopted from `FEATURES.md` §18/§20 as decisions, not aspirations.
Recording and export are **passthrough muxing only** — `AVAssetWriter` with
`AVAssetWriterInput(mediaType:outputSettings: nil)` and `append(_ sampleBuffer:)`; there is no
encoder in the app and no code path that could add one. All egress passes one **pure**
`HostPolicy.classify(_:) -> HostClass` gate in `VigilProtocols`; `.publicInternet` is refused before a
socket is opened, and the refusal is testable on Linux. There is no analytics SDK, no crash reporter,
no usage ping, no remote config, no font or asset CDN, and no automatic update check in 1.0.

### 2.5 Conflicts found while writing this contract

These were not in `OPEN-CONFLICTS.md`. Each would have cost an implementation agent an hour or
produced code that does not link.

#### R-49 — decode admission: `DecodeAdmitting` (protocol, `VigilProtocols`) + `DecodeBudget` (actor, `VigilVideo`) **[BUILD]**

*Said:* `spec-core.md` §8.4 declares `protocol DecodeAdmitting { currentBudget(); maxConcurrentSessions();
acquire(cost: Double, priority: StreamPriority) async throws -> DecodeLease }` with cost
`megapixels × fps × codecWeight` and a base-M1 budget of **900 units / 20 sessions**.
`spec-video-pipeline.md` §12.4 declares `@globalActor public actor DecodeBudget` with
`admit(Request) -> AdmissionResult`, `update`, `release`, `reserveTransient`, a `TilePriority` enum
and DU costs normalised to 1080p30, base-M1 **20 DU / 24 sessions**. Two authorities, two cost
units, two priority enums, two budget numbers, incompatible method names.

*Ruling:*

* **`protocol DecodeAdmitting`, `DecodeLease`, `DecodeCost`, `StreamPriority` and `TilePolicy` are
  declared in `VigilProtocols`** — pure, Foundation-only, Linux-testable. This is what lets
  `StreamCoordinator.makePlan` and the class A–E table be unit-tested without VideoToolbox, which
  both specs asked for and neither could deliver from its own module.
* **`DecodeBudget` is the single implementation**, a `@globalActor actor` in `VigilVideo` conforming
  to `DecodeAdmitting`. It is the only authority that may admit a session. `StreamCoordinator`
  computes priority, holds leases, and keeps **no** budget of its own.
* **The unit is the decode unit (DU)**, per R-22. `megapixels × fps × codecWeight` is deleted; it
  produced numbers like "829 units" that no human can sanity-check.
* `TilePriority` is deleted in favour of `StreamPriority` (`spec-core.md` §7.1's enum). Note that
  `TilePriority` as written **does not compile** — `visibleLarge` and `recording` both have raw
  value `4`.
* `DecodeBudget.admit` may return `.grantedDegraded(lease, DecodeMode)`; `StreamCoordinator` must
  handle it and surface the demotion.

*Amend:* `spec-core.md` §8.4 (cost unit, declaration site); `spec-video-pipeline.md` §12
(`TilePriority` → `StreamPriority`, conform to `DecodeAdmitting`, fix the raw-value collision).

#### R-50 — one format type: `VideoFormatInfo`. `VideoFormat` is deleted **[BUILD]**

*Said:* `spec-bitstream.md` §22 declares `VideoFormatInfo` (27 fields, flat) in `VigilBitstream`.
`spec-video-pipeline.md` §2.2 declares `VideoFormat` (16 fields, flat, `Int32`-typed) in
`VigilVideo`. `spec-render.md` §3.1 declares `FrameGeometry` + `ColorInfo` + `FieldOrder` in
`VigilProtocols`. All three describe the same coded/display/SAR/colour facts, with different field
names and types.

*Ruling:* **one type, `VideoFormatInfo`, in `VigilProtocols`**, composed of `FrameGeometry` and
`ColorInfo` rather than restating their fields. `VigilBitstream` computes it from SPS/VPS VUI;
`VigilVideo` consumes it and converts once in `FormatDescriptionFactory`; `VigilRender` reads
`geometry` for its coordinate pipeline. `VigilVideo.VideoFormat` is deleted.
`VideoFormatInfo` keeps `displayWidth`/`displayHeight`/`sarWidth`/`sarHeight`/`codedWidth`/
`codedHeight` as **computed passthroughs** to `geometry`, so every line of `spec-bitstream.md` still
reads correctly.

*Amend:* `spec-bitstream.md` §22 (declaration site + composition); `spec-video-pipeline.md` §2.2
(delete `VideoFormat`).

#### R-51 — one decoded-frame type: `VideoFrame`; one `VideoSink` **[BUILD]**

*Said:* `ARCHITECTURE.md` §2.4 → `DecodedFrame` in `VigilVideo`. `spec-video-pipeline.md` §2.2 →
`DecodedVideoFrame` with a `Payload` enum, and `protocol VideoSink { present(_:); willChangeFormat;
didChangeFormat; didDropFrames; didStall; didRecover }`. `spec-render.md` §3.1 → `VideoFrame`, and
`protocol VideoSink { enqueue(_:); streamDidReset(); streamDidEnd(reason:) }` plus "must also offer a
`CMSampleBuffer` overload". Three names for the frame, two incompatible protocols with **no member in
common**.

*Ruling:* **`VideoFrame`** (the consumer's name wins; `VigilRender` is the only implementer).
`DecodedFrame` and `DecodedVideoFrame` are deleted. One `VideoSink` in `VigilVideo`, the union of
both member sets, with `enqueue` as the frame-delivery verb (not `present`), and default no-op
extensions on the six observability members so a minimal sink is three lines. Exact declaration in
§4.9. The `Payload` enum is dropped: pixel-buffer delivery and sample-buffer delivery are two
`enqueue` overloads, which removes a `switch` from every frame.

`CMSampleBuffer` crossing `VigilVideo → VigilRender` through
`nonisolated func enqueue(_:format:generation:)` is legal and needs no box: both sides are
`nonisolated`, the call is synchronous, and no isolation boundary is crossed, so `Sendable` is not
required. Do not wrap it. Do not store it.

*Amend:* `ARCHITECTURE.md` §2.4; `spec-video-pipeline.md` §2.2/§2.4; `spec-render.md` §3.1.

#### R-52 — exactly **three** `@unchecked Sendable` types, enumerated **[BUILD]**

*Said:* `ARCHITECTURE.md` §5.9 → exactly two (`DecodeSinkBox`, `DecodedFrame`).
`spec-render.md` §1.3 → `LatestFrameBox` plus a generic `struct UncheckedSendable<T>: @unchecked Sendable`.
`spec-video-pipeline.md` §2.3 → `FormatBox` plus a generic `struct Unsafe<T>: @unchecked Sendable`.
`spec-discovery.md` §11 → `final class MulticastDatagramChannel: @unchecked Sendable`.
`spec-isapi.md` §4.6 → `final class URLSessionTransport: @unchecked Sendable`.

*Ruling:* the count is **three**, and this is the complete list. `ARCHITECTURE.md`'s two was written
before the render spec existed and did not foresee the latest-frame slot.

| # | Type | Module | Justification that must appear as a comment |
|---|---|---|---|
| 1 | `DecodeSinkBox` | `VigilVideo` | Only mutable state is an `AsyncStream.Continuation` (documented thread-safe for `yield`/`finish`) and an `OSAllocatedUnfairLock`-protected counter struct. Nothing else stored. |
| 2 | `VideoFrame` | `VigilVideo` | Wraps a `CVPixelBuffer` produced by VideoToolbox, never mutated after delivery; consumers only lock the base address for reading or wrap it via `CVMetalTextureCache`. Never handed to two writers. |
| 3 | `LatestFrameBox` | `VigilRender` | A single `VideoFrame` slot plus a ≤3-deep pending array, both guarded by one `NSLock` held for < 200 ns. `NSLock`, not `OSAllocatedUnfairLock`, because `put` is called from VideoToolbox's thread and the lock must be re-entrant-safe across the C boundary; `Mutex` needs macOS 15 and the floor is 14. |

**Forbidden:** the generic escape hatches `Unsafe<T>` and `UncheckedSendable<T>`. A generic
`@unchecked Sendable` box is not a justification, it is a way to stop writing one, and it makes the
lint rule that counts these unenforceable. `FormatBox` is unnecessary — `CMFormatDescription` is
confined to the `DecodePipeline` actor and never crosses. `MulticastDatagramChannel` becomes an
`actor` (it owns one `NWConnectionGroup` and a continuation; there is nothing an actor cannot hold).
`URLSessionTransport` becomes an `actor` holding the delegate state, with the `URLSession` delegate
methods hopping in via `Task`.

`VigilTestKit.ManualClock` does not count: the cap is on `Sources/` excluding `VigilTestKit`, which
ships to no product the app links.

*Amend:* `ARCHITECTURE.md` §5.9; `spec-render.md` §1.3; `spec-video-pipeline.md` §2.3;
`spec-discovery.md` §11; `spec-isapi.md` §4.6.

#### R-53 — `parameterSets` are attached **only when they change** **[SEMANTIC]**

*Said:* `spec-rtp.md` §2.4 → "Non-nil **only on the first frame after the set changed** (including
the very first frame)". `spec-video-pipeline.md` §2.1 → "present on the first frame of every GOP",
and its `ParameterSetStore` is built to dedupe "byte-identical resends (every GOP, which is normal)".

*Ruling:* **only when changed.** `VigilRTP` holds the current sets, compares bytes, and attaches only
on a real change. `VigilVideo.ParameterSetStore` still dedupes (belt and braces, and it also sees
sets that arrive via SDP `sprop-*`), but the wire contract is changed-only: at 16 cameras with a 1 s
GOP, per-GOP attachment is 16 needless `[Data]` allocations per second on the frame path.
`VigilVideo` **must** retain the last non-`nil` sets for the lifetime of the stream — a decoder reset
does not entitle it to ask for them again; it emits `.keyframeNeeded(.decoderReset)` and rebuilds
from what it holds.

*Amend:* `spec-video-pipeline.md` §2.1.

#### R-54 — AAC `AudioSpecificConfig` lives in `AudioFormatInfo.magicCookie`, never in `ParameterSets.sps[0]` **[SEMANTIC]**

*Said:* `spec-rtp.md` §2.3 → "For AAC this carries the AudioSpecificConfig in `sps[0]`".

*Ruling:* deleted. `ParameterSets` is a **video** type (it carries `codec: VideoCodec`); smuggling an
audio cookie through a field named `sps` is exactly the kind of thing that produces a decoder that
works until someone adds a `precondition` on H.264 NAL types. `EncodedFrame.audioFormat:
AudioFormatInfo?` carries `magicCookie: Data?`, which is what `AudioConverterRef` wants under
`kAudioConverterDecompressionMagicCookie`.

*Amend:* `spec-rtp.md` §2.3, §8.6.

#### R-55 — `StreamQuality` replaces `StreamProfile.Kind` and `StreamIndex`; "auto" is `nil` **[BUILD]**

*Said:* `spec-core.md` declares both `StreamQuality { main, sub, third, auto }` and
`StreamProfile.Kind { main, sub, third }`, and uses `qualityOverride: StreamQuality?` where `nil`
already means auto. `spec-isapi.md` declares `StreamIndex { main = 1, sub = 2, third = 3 }`.

*Ruling:* one type, `StreamQuality`, in `VigilProtocols`, cases `main = 1, sub = 2, third = 3`,
`Codable` as its lowercase string. **There is no `.auto` case** — "auto" is the absence of an
override, expressed as `StreamQuality?` (which `CellAssignment.qualityOverride` already does).
`StreamProfile.Kind` and `StreamIndex` are deleted; `StreamProfile.id` becomes `StreamQuality`.

*Why:* an `.auto` case in an enum that is also used to *name a concrete stream* means every switch
has an unreachable branch and every `streamingChannelID(for:)` needs a precondition. Optionality
expresses "unset" without inventing a value.

*Amend:* `spec-core.md` §3, §4.2, §4.5; `spec-isapi.md` §11.3.

#### R-56 — layout geometry is the 12×12 integer grid; the persisted model is `LayoutMode` + `[CellAssignment]` **[BUILD]**

*Said:* `UX.md` §5.1 → all 8 layouts are integer rectangles on a **12 × 12 unit grid**, cells are
`LayoutCell { x, y, w, h, cameraID }`, mode enum
`{ single, grid2x2, hero1p5, grid3x3, grid4x4, hero1p7, dual2p8, custom }`.
`spec-core.md` §4.5 → `LayoutMode { single, grid(columns:rows:), onePlusFive, onePlusSeven,
twoPlusEight, custom(frames: [MosaicFrame]) }`, assignments are
`CellAssignment { cellIndex, cameraID, qualityOverride, aspectMode, isAudioSolo }`, geometry is
`frames() -> [MosaicFrame]` in the **unit square with `Double` coordinates**.

*Ruling:* take both, layered — they are solving different problems and each is right about its own.

* **Geometry** is `UX.md`'s **12 × 12 integer grid**. `LayoutMode.cells() -> [GridCell]` returns
  `GridCell { x, y, w, h }` with all fields `Int` in `0...12`. `MosaicFrame` and its `Double`
  unit-square coordinates are deleted. Integers because a custom mosaic must snap exactly, because
  `0.333333` cell widths accumulate a visible seam error at 4 K, and because layout equality has to
  be exact for `@Observable` diffing.
* **Persistence and identity** are `spec-core.md`'s: `LayoutMode` is the parameterised enum
  (`grid(columns:rows:)` covers 2×2, 3×3, 4×4, 5×5, 1×N and N×1 in one case — `UX.md`'s five
  separate `gridNxN` cases do not), and assignments are `[CellAssignment]` keyed by `cellIndex`,
  sparse, sorted.
* Pixel geometry is computed **once**, in `VigilUI/Stage/LayoutEngine.swift`, from
  `cells()` + `VTheme.Metrics.tileGutter` + `VTheme.Metrics.stageInset`. No view computes a cell
  rect; `StreamCoordinator` derives tile `Resolution` from the same function so the admission table
  and the screen never disagree.
* `matchedGeometryEffect` is keyed **by camera** (`DESIGN.md` §7.7), not by cell (`UX.md` §5.1).
  A layout change must never tear down a decode session, and the tile has to fly from its old cell to
  its new one — which is only expressible if the identity travelling through the transition is the
  camera.

*Amend:* `UX.md` §5.1 (`LayoutCell` → `GridCell` + `CellAssignment`; adopt the parameterised
`LayoutMode`; key the namespace by camera); `spec-core.md` §4.5 (`MosaicFrame` → `GridCell`,
`frames()` → `cells()`, integer units).

#### R-57 — `Resolution` is the one size type; `PixelSize` is deleted **[BUILD]**

*Said:* `spec-core.md` §3 declares `Resolution { width, height: Int }` and §8.1 separately declares
`PixelSize { width, height: Int }` for tile backing size.

*Ruling:* one type, `Resolution`, in `VigilProtocols`, used for stream dimensions, display
dimensions and tile backing size alike. `PixelSize` is deleted. `Viewport.Tile.pixelSize:
Resolution` keeps the field name, because the name carries the unit (backing pixels) and the doc
comment says so.

#### R-58 — `VideoCodec.decodeWeight` = 1.00 / 1.35 / 0.45, and the DU cost formula is fixed **[SEMANTIC]**

*Said:* `spec-core.md` → H.264 1.00, H.265 1.35, MJPEG 0.45, unknown 1.35.
`spec-video-pipeline.md` §12.2 → H.264 1.00, H.265 8-bit 1.35, H.265 Main10 1.70, MJPEG 0.40.

*Ruling:* `decodeWeight` is `h264 1.00`, `h265 1.35`, `mjpeg 0.45`. The Main10 surcharge is real but
belongs to the *bit depth*, not the codec: `DecodeCost` multiplies by an extra **1.26** when
`geometry.bitDepth > 8`, which yields 1.70 for H.265 Main10 and also covers H.264 High10.

```
cost(DU) = ceil( (codedWidth × codedHeight × fps) / (1920 × 1080 × 30)
                 × codec.decodeWeight × (bitDepth > 8 ? 1.26 : 1.0)
                 × mode.weight × 4 ) / 4
```

`mode.weight`: `full 1.00`, `fpsCapped(15) 0.55`, `keyframesOnly 0.12`, `jpegPoll 0`, `paused 0`;
`+0.05` additive when downscale-on-decode is active; `×6.0` for reverse playback. Rounded up to
0.25 DU. Note `codedWidth × codedHeight`, not display size: the decoder allocates coded (1088), and
that is what costs memory bandwidth.

*Amend:* `spec-video-pipeline.md` §12.2; `spec-core.md` §8.4.

#### R-59 — machine budget table **[SEMANTIC]**

*Ruling:* `FEATURES.md`'s two named classes are exact; `spec-video-pipeline.md`'s finer classes fill
in the rest. Detected once at launch, persisted to
`~/Library/Application Support/Vigil/decode-budget.json`, user-overridable in
Settings → Streams → "Maximum concurrent decodes".

| Detection | Class | Budget DU | Max sessions |
|---|---|---|---|
| Apple silicon, two media engines (`Mac14,13`/`Mac14,14`/Ultra) | Max / Ultra | 48 | 32 |
| Apple silicon, `hw.perflevel0.physicalcpu >= 6` | Pro | 32 | 28 |
| Apple silicon, base M-series | **base** | **24** | 24 |
| Intel, HEVC hardware probe succeeds (T2 / Kaby Lake+) | Intel + Quick Sync | **10** | 16 |
| Intel, H.264 hardware only | Intel legacy | 6 | 8 |
| Both probes fail (VM, stripped GPU) | software only | 3 | 4 |

Runtime calibration may only **lower** the seed (`×0.90` on any `decodeLateRatio > 2 %` or
`kVTCouldNotCreateInstanceErr`, floor 2 DU / 2 sessions) and may raise back to at most the seed.
Thermal and power multipliers are applied on top, never persisted: `.fair ×0.85`, `.serious ×0.60`,
`.critical ×0.35`, Low Power Mode `×0.60`, battery with `pauseOnBattery` `×0.75`.

#### R-60 — log categories: 13, from `ARCHITECTURE.md`; the other two lists map onto them **[BUILD]**

*Said:* a **third** list appeared — `spec-core.md` §15 declares `LogCategory { config, credentials,
controller, coordinator, recording, snapshot, events, health, doctor, automation, persistence }`
(11 cases), disjoint from both `ARCHITECTURE.md`'s 13 and `FEATURES.md`'s 14.

*Ruling:* R-15 stands — `ARCHITECTURE.md`'s 13. Mapping for the other two lists:

| From `spec-core.md` / `FEATURES.md` | Canonical |
|---|---|
| `config`, `persistence`, `store` | `storage` |
| `credentials`, `security` | `core` |
| `controller`, `coordinator`, `recording`, `snapshot`, `events`, `doctor`, `automation`, `playback` | `core` |
| `health` | `perf` |
| `decode` | `video` |

If `core` proves too coarse in practice, the fix is a `subsystem` field on `LogEvent`, **not** a
fourth category list.

*Amend:* `spec-core.md` §15.

#### R-61 — `EventKind` is the one event taxonomy; `VigilEventType` is deleted **[BUILD]**

*Said:* `spec-core.md` §4.7 declares `EventKind` (19 cases, with
`init(isapiEventType: String)`); `spec-isapi.md` Appendix B declares `VigilEventType`.

*Ruling:* `EventKind` in `VigilProtocols`, with the lenient `init(isapiEventType:)` — `VigilISAPI`
parses the wire string and constructs it, `VigilCore` stores it, `VigilUI` localises it via
`displayNameKey`. `VigilEventType` is deleted. The wire string is preserved verbatim in
`EventRecord.rawEventType` so an unrecognised event is still diagnosable.

*Amend:* `spec-isapi.md` Appendix B and §14.

#### R-62 — `EventNotificationAlert` vs the alert-stream owner (see also R-46) **[COSMETIC]**

*Ruling:* `VigilISAPI.EventNotificationAlert` is the **wire** type (one parsed
`<EventNotificationAlert>` part). `VigilCore.EventRecord` is the **domain** type (deduped,
coalesced, persisted, with a thumbnail and a clip link). They are not the same type and neither
replaces the other. `AlertStreamMonitor` emits the former; `EventCenter` produces the latter.

#### R-63 — `StreamKey` replaces `StreamIdentifier` **[BUILD]**

*Said:* `spec-video-pipeline.md` uses `StreamIdentifier` throughout and never declares it.

*Ruling:* `struct StreamKey: Hashable, Sendable, Codable { var camera: CameraID; var quality: StreamQuality }`
in `VigilProtocols`. It is what a decode pipeline, an audio route and a budget grant are actually
keyed by — a camera alone is wrong the moment a main and a sub stream are both live during a
quality switch, which is the exact 150 ms window R-21 mandates.

#### R-64 — one `EncodedFrame` carries audio too; `EncodedAudioFrame` does not exist **[BUILD]**

*Said:* `spec-video-pipeline.md` §13/§18 takes `EncodedAudioFrame` in `submitAudio(_:)` and never
declares it. `spec-rtp.md` has a single `EncodedFrame` with `audioFormat` and audio codec cases.

*Ruling:* one `EncodedFrame`. `submitAudio(_ frame: EncodedFrame)` takes the same type;
`frame.codec.audio != nil` is the discriminator, and `DecodePipeline` asserts it in debug.

*Amend:* `spec-video-pipeline.md` §13, §18.1, §18.2.

#### R-65 — `AsyncStream` **properties** in the specs are all wrong; they must be factories **[BUILD]**

*Said:* `spec-video-pipeline.md` (`var events: AsyncStream<PipelineEvent>`, `var changes`,
`var sampleTap`, `var levels`), `spec-discovery.md` (`var inbound: AsyncStream<InboundDatagram>`,
`var paths`, `var events`, `var responses`), `spec-core.md` §2 (`var paths`, `var events`,
`var responses`) all declare stored/computed `AsyncStream` **properties**.

*Ruling:* R-27 applies without exception. Every one becomes a factory
(`func events() -> AsyncStream<E>`) over a shared bounded `Broadcaster`. The single permitted
exception is a stream with a **structurally single consumer created by the same call that made it**
— `DiscoveryCoordinator.start() -> AsyncStream<DiscoveryEvent>` and
`StreamDoctor.diagnose(camera:) -> AsyncStream<DoctorProgress>` qualify, because each call starts a
new run. A *property* never qualifies.

`spec-core.md` §6.9's `Broadcaster<Element>` actor is adopted verbatim as the shared implementation
and moves to `VigilProtocols` so `VigilISAPI` and `VigilDiscovery` can use it too. Standing
buffering policies: `ConfigStore.changes()` `.bufferingNewest(1)` + replay;
`EventLog.changes()` `.bufferingNewest(256)`; `StreamController.events()` `.bufferingNewest(64)` +
replay; `StreamCoordinator.plans()` `.bufferingNewest(1)` + replay;
`HealthMonitor.samples()` `.bufferingNewest(16)`; decoded frames `.bufferingNewest(3)`;
alert-stream events `.bufferingNewest(256)`; ISAPI byte streams `.bufferingNewest(64)`;
discovery datagrams `.bufferingNewest(512)`.

#### R-66 — types referenced by the specs but never declared **[BUILD]**

The specs collectively reference **41** types they never declare. Every one is declared here (§3 or
§4) or explicitly deleted. Implementation agents: if you meet a name not in this contract, it does
not exist — do not invent it, raise it.

| Referenced in | Name | Disposition |
|---|---|---|
| isapi | `HTTPHeaders`, `ISAPIChunkedUpload`, `ISAPIUploadHandle` | declared, §3.14 / §4.5 |
| isapi | `InvalidationReason`, `PathSegment`, `DataTaskState`, `StreamTaskState` | module-internal; implementer's choice |
| core | `PowerEventObserving`, `PasteboardWriting`, `WindowID`, `FileAttributes` | declared, §3.17 / §4.8 |
| core | `ISAPIEndpoint`, `RTSPEndpoint` | declared, §3.13 |
| core | `BudgetPressure`, `PowerConditions`, `CameraRef`, `LayoutRef`, `SettingsPane`, `DeepLinkError`, `NotificationSound`, `NotificationResponse`, `SnapshotRequest`, `RecordingEvent`, `AuthScheme`, `SuppressionReason` | declared, §4.8 |
| core | `CodableRect`, `CodableColor` | deleted — use `GridCell` and `ColorTag`; no view type is persisted |
| core / video | `DecodeSinkOptions`, `RTSPTransport`, `FrameTap`, `DecodeLease` | declared, §4.8 / §4.9 |
| video | `StreamIdentifier` | → `StreamKey` (R-63) |
| video | `EncodedAudioFrame` | deleted (R-64) |
| video | `VTConfig`, `DecodeOutput`, `PendingAU`, `DropOutcome`, `FormatOverrides`, `ParameterSetChange`, `SnapshotError`, `AudioError`, `TalkbackError`, `AudioStatistics`, `PlaybackEvent`, `DenialReason`, `PauseReason`, `ModeChangeReason`, `BudgetChange`, `BudgetSnapshot`, `FrameDropReason`, `StreamEndReason`, `PacingMode`, `ColorSpaceTag` | declared, §4.9; `ColorSpaceTag` → `ColorInfo` (R-50) |
| render | `TileRenderer`, `PrivacyMaskSet.disabled`, `StreamEndReason`, `PacingMode` | declared, §4.10 |
| discovery | `BudgetKind`, `ClassificationEvidence`, `ClassificationVerdict`, `POSIXCode`, `HostProbeResult`, `DiscoveryDiagnostic.Severity` | declared, §4.6 |
| discovery | `MulticastGroupSpec.localAddress` | added to the struct, §4.6 |

#### R-67 — defects in the source specs, corrected here **[BUILD]**

These do not compile or are internally contradictory as written. The corrected form is in §3/§4.

| Where | Defect | Correction |
|---|---|---|
| `spec-video-pipeline.md` §12.4 | `TilePriority` has two cases with raw value `4` | type deleted (R-49) |
| `spec-video-pipeline.md` §4.5 | `mutating func ingest` on a `final class ParameterSetStore` | `ParameterSetStore` is a `struct` (as `spec-bitstream.md` §21 already says) |
| `spec-video-pipeline.md` §18.4 | `VideoPipelineError` carries `underlying: Error?` yet claims `Sendable` | carries `underlyingDescription: String` |
| `spec-video-pipeline.md` §18.3 | `DecodeStatistics: Codable` over non-`Codable` members | every member made `Codable` in §3/§4 |
| `spec-video-pipeline.md` §18.1 | `public struct DecodePipelineConfiguration` uses its internal memberwise init from another module | explicit `public init` with defaults |
| `spec-video-pipeline.md` §6.2 | `public struct StrategyInputs` with internal members | all members `public` |
| `spec-video-pipeline.md` §10.4 | `enum LatencyLevel` not `Sendable` yet crosses boundaries | `: Int, Sendable, Codable, Comparable` |
| `spec-video-pipeline.md` §15.3 | `options.format == .png` on a payload-carrying enum | `SnapshotFormat` is a plain `String`-raw enum; quality moves to `SnapshotOptions` |
| `spec-discovery.md` §6.2 | `IPv4Subnet.addressCount` — both ternary branches identical | `1 << (32 - prefixLength)`, with `prefixLength == 0` handled |
| `spec-discovery.md` §5.5 vs §10.5 | `WSDiscoveryCodec.decodeProbeMatches` declared twice with different signatures | §10.5's superset wins |
| `spec-discovery.md` §11 | `MulticastGroupSpec.localAddress` used, not declared | added |
| `spec-discovery.md` §11 vs §6.3 | `ARPTableReader.swift` vs `SystemARPTableReader.swift` | `SystemARPTableReader.swift` |
| `spec-discovery.md` §12 | `SweepPlanError.noEligibleInterfaces` duplicates `DiscoveryError.noEligibleInterfaces` | one case, on `DiscoveryError` |
| `spec-render.md` §14 | `PTZDirection.isaptiltPan` | `isapiPanTilt` |
| `spec-render.md` §3.2 | `RenderStats.droppedFrames` vs `droppedByReplacement` | `droppedByReplacement` |
| `spec-core.md` §17.6 test 2 | class letters contradict §8.5's own examples | see R-21 |
| `spec-core.md` §4 | `Library.schemaVersion` cross-referenced to §5.5, declared in §5.2 | §5.2 |
| `spec-isapi.md` Appendix B | `EventNotification` vs `EventNotificationAlert` | `EventNotificationAlert` (R-46) |

#### R-68 — UI structure, naming and remaining `DESIGN.md` / `UX.md` splits **[COSMETIC]**

| Question | Ruling | Loser amends |
|---|---|---|
| Sidebar / inspector widths | `UX.md`: 208 / **264** / 380 and 288 / **320** / 440 (R-34) | `DESIGN.md` §5.1 + `VTheme.Metrics` |
| Sidebar rail width | **`UX.md`: 68 pt** — 52 cannot fit a 28 pt glyph beside a 44×26 thumbnail | `DESIGN.md` (`sidebarRail = 68`) |
| Tile gutter (stage) / stage inset | `DESIGN.md`: **2 pt / 8 pt** (R-35) | `UX.md` §5.1 |
| Tile gutter (video wall) | **`DESIGN.md`: 0 pt**, edge-to-edge — "full bleed" is the point of the wall | `UX.md` §5.1 |
| Unified toolbar height | **`DESIGN.md`: 52 pt** (it is a token) | `UX.md` §3 |
| Main window default / min / scene type | **`UX.md`: 1440 × 900, min 960 × 600, `Window(id:)`, `.contentMinSize`** — `UX.md` §0 explicitly owns the scene graph and sizing | `DESIGN.md` §11.2 |
| Command palette geometry | **`DESIGN.md`: 640 wide, top inset 132, max height 520** — and it is the one that fits `UX.md`'s own row math (56 input + 9 × 44 rows + 28 footer = 480) | `UX.md` §10.1 |
| `V*` component location | **all `V`-prefixed types in `Sources/VigilUI/Components/`**; `Shared/` holds only non-prefixed helpers | `UX.md` §17 |
| Naming rule | **`V` prefix ⇔ reusable design-system type in `Components/` or `Theme/`.** Screens, screen-local subviews and state types take no prefix. So: `VTile`, `VTimeline`, `VSidebarRow`, `VCommandPalette`, `VTheme`; but `MainWindowView`, `StageView`, `PlaybackWindowView`, `AppModel`. `VMainWindowView` is renamed `MainWindowView` | `DESIGN.md` §12.3 |
| `\.vNamespaces` setter | `MainWindowView` | — |
| Camera row height | 44 pt, legal (R-37) | `DESIGN.md` §5.5 gains `VTheme.Metrics.Row` |

#### R-69 — `HikvisionURL` returns paths; `VigilCore` builds the URL **[BUILD]**

Restating the mechanical consequence of R-23, because it is the one place a plausible-looking
`import` would be rejected at review: `VigilRTSP` has **no** dependency on `VigilISAPI` and must not
gain one. `HikvisionURL` (in `VigilISAPI`) returns `String` paths and `RTSPPathCandidate` values.
`VigilCore.StreamProbe` combines a candidate with `Camera.host`/`rtspPort`/`transport` to make an
`RTSPURL` (a `VigilRTSP` type) and drives `RTSPSessionMachine` with `RTSPCommand.describeOnly`.
`VigilDiscovery` may not call `HikvisionURL` either — it has no edge — and keeps only
`DiscoveredDevice.suggestedRTSPPath` for display and fingerprinting.

#### R-70 — `Placeholder.swift` and the scaffolding invariants **[BUILD]**

*Ruling:* every target keeps its `Placeholder.swift` until it has at least one real source file, at
which point the **supervisor** deletes it — not the implementing agent, because an agent that
deletes it and then fails to land its own file breaks the build for everyone. Likewise the 12
`.placeholder` files in resource directories are **never** deleted, even after real resources land:
they cost nothing and they are what stops a `git clean` from re-creating defect #2 of
`docs/BUILD-VERIFICATION.md`.

#### R-71 — where `HostPolicy` lives and what it gates **[BUILD]**

*Ruling:* `enum HostPolicy` in `VigilProtocols` (`Net/HostPolicy.swift`), pure, Linux-tested:

```swift
public static func classify(_ host: String) -> HostClass
```

returning `.loopback`, `.privateLAN`, `.linkLocal`, `.multicast`, `.publicInternet`, `.invalid`.
**Every** outbound socket, `URLSession` task and multicast join in `VigilTransport`, `VigilISAPI` and
`VigilDiscovery` passes its destination through it first and refuses `.publicInternet` **before the
socket is created**, throwing `TransportError.egressBlocked(host:)`. This is what makes
`FEATURES.md` §20.3's "zero egress with no cameras configured" test a code property rather than a
packet-capture ritual, and it is testable on Linux.

#### R-72 — one shared `Broadcaster`, one shared `ConcurrencyLimiter`, one shared `RingBuffer` **[COSMETIC]**

Three utilities are independently specified in three modules. Each is declared once, in
`VigilProtocols`: `Broadcaster<Element>` (R-65), `ConcurrencyLimiter` (FIFO, priority-aware,
cancellation-safe, `spec-core.md` §8.8), and `RingBuffer<Element>` (fixed capacity, preallocated,
O(1) append — used by `HealthRing`, the RTP reorder buffer, `FrameQueue` and the statistics
reservoirs). `DispatchSemaphore` is forbidden everywhere: it blocks a cooperative thread and
deadlocks the pool under Swift 6.

## 3. Canonical shared value types — `VigilProtocols`

**This section is normative and is meant to be pasted.** Every declaration below lives in
`Sources/VigilProtocols/`, is `public`, and is `Sendable`. Where a body is given, use it. Where a
body is elided with `{ … }` or a `{ get }`, the doc comment is the specification and the
implementation is the W1 agent's, subject to §7.

No type in this section may import anything but `Foundation`, and several import nothing at all.

### 3.1 File map

| File | Declares |
|---|---|
| `Time/MediaInstant.swift` | `MediaInstant` |
| `Time/Clocks.swift` | `MonotonicClock`, `WallClock`, `SystemMonotonicClock`, `SystemWallClock` |
| `Time/MediaTimestamp.swift` | `MediaTimestamp`, `UInt64.divideWithOverflowGuard` |
| `Time/RandomSource.swift` | `RandomSource`, `SystemRandomSource`, `SplitMix64RandomSource` |
| `Media/Codecs.swift` | `VideoCodec`, `AudioCodec`, `MediaCodec` |
| `Media/ParameterSets.swift` | `ParameterSets` |
| `Media/EncodedFrame.swift` | `EncodedFrame`, `FrameDropClass`, `AudioFormatInfo` |
| `Media/FrameGeometry.swift` | `FrameGeometry`, `ColorInfo`, `FieldOrder`, `Resolution` |
| `Media/VideoFormatInfo.swift` | `VideoFormatInfo` |
| `Streams/StreamQuality.swift` | `StreamQuality`, `StreamKey`, `RTSPTransportKind`, `LatencyPreset` |
| `Streams/DecodePolicy.swift` | `DecodeMode`, `StreamPriority`, `DecodeCost`, `DecodeAdmitting`, `DecodeLease`, `DenialReason`, `BudgetPressure` |
| `Streams/TilePolicy.swift` | `TileClass`, `TilePolicy`, `TileContext`, `StreamChoice` |
| `Stats/StreamStatistics.swift` | `StreamStatistics` |
| `Stats/RingBuffer.swift` | `RingBuffer` |
| `Errors/VigilError.swift` | `VigilFailure`, `ErrorSeverity`, `RetryDisposition`, `VigilError`, `vigilRequire` |
| `Errors/DomainErrors.swift` | all eleven domain error enums (R-10) |
| `Errors/DiagnosticCodes.swift` | the `VG-<DOMAIN>-NNNN` tables |
| `Logging/LoggerProtocol.swift` | `LogLevel`, `LogCategory`, `LogEvent`, `LoggerProtocol`, `NullLogger` |
| `Logging/RateLimitedLogger.swift` | `RateLimitedLogger` |
| `Logging/Redact.swift` | `Redact` |
| `Bytes/ByteReader.swift` | `ByteReader` |
| `Bytes/ByteWriter.swift` | `ByteWriter` |
| `Bytes/BitReader.swift` | `BitReader` |
| `Bytes/BitWriter.swift` | `BitWriter` |
| `Crypto/MD5.swift` `SHA1.swift` `SHA256.swift` | `MD5`, `SHA1`, `SHA256` |
| `Crypto/Base64.swift` | `Base64` |
| `Crypto/CRC32.swift` | `CRC32` |
| `Net/IPv4Address.swift` `MACAddress.swift` `IPv4Subnet.swift` | as named |
| `Net/HostPolicy.swift` | `HostPolicy`, `HostClass` |
| `Net/Endpoints.swift` | `ISAPIEndpoint`, `RTSPEndpoint` |
| `Net/HTTP.swift` | `HTTPHeaders`, `HTTPRequest`, `HTTPResponse`, `HTTPLane`, `HTTPTransporting` |
| `Net/Credential.swift` | `Credential`, `CredentialRef` |
| `Identity/Identifiers.swift` | `CameraID`, `GroupID`, `LayoutID`, `EventID`, `ClipID`, `BookmarkID`, `WindowID` |
| `Identity/DeviceIdentifiers.swift` | `ChannelID`, `StreamingChannelID`, `TrackID`, `DeviceQuirks` |
| `Identity/EventKind.swift` | `EventKind`, `EventSeverity` |
| `Concurrency/Broadcaster.swift` | `Broadcaster` |
| `Concurrency/ConcurrencyLimiter.swift` | `ConcurrencyLimiter` |

### 3.2 Time

```swift
/// A monotonic instant: nanoseconds since an arbitrary, process-stable epoch.
///
/// Never wall-clock time. Never decreases. Never wraps within any plausible uptime
/// (`Int64.max` nanoseconds is 292 years). This is the *only* monotonic instant type in Vigil:
/// `RTSPInstant`, `RTSPDuration` and `MonotonicTime` do not exist (API_CONTRACT §2 R-07).
///
/// Durations are always `Swift.Duration`, which carries its unit in the type.
public struct MediaInstant: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {

    public var nanoseconds: Int64

    public init(nanoseconds: Int64) { self.nanoseconds = nanoseconds }

    /// The zero instant. Useful as a test origin; meaningless as a real time.
    public static let zero = MediaInstant(nanoseconds: 0)

    @inlinable public var seconds: Double { Double(nanoseconds) / 1e9 }

    @inlinable public static func < (a: Self, b: Self) -> Bool { a.nanoseconds < b.nanoseconds }

    /// Seconds elapsed from `earlier` to the receiver. Negative if the receiver is earlier.
    @inlinable public func seconds(since earlier: MediaInstant) -> Double {
        Double(nanoseconds - earlier.nanoseconds) / 1e9
    }

    /// Milliseconds elapsed from `earlier`. The unit every log line and statistic uses.
    @inlinable public func milliseconds(since earlier: MediaInstant) -> Double {
        Double(nanoseconds - earlier.nanoseconds) / 1e6
    }

    @inlinable public static func + (lhs: MediaInstant, rhs: Duration) -> MediaInstant {
        MediaInstant(nanoseconds: lhs.nanoseconds + rhs.wholeNanoseconds)
    }

    @inlinable public static func - (lhs: MediaInstant, rhs: Duration) -> MediaInstant {
        MediaInstant(nanoseconds: lhs.nanoseconds - rhs.wholeNanoseconds)
    }

    /// The interval between two instants.
    @inlinable public static func - (lhs: MediaInstant, rhs: MediaInstant) -> Duration {
        .nanoseconds(lhs.nanoseconds - rhs.nanoseconds)
    }

    public var description: String { "\(seconds)s" }
}

public extension Duration {
    /// Total nanoseconds, saturating rather than trapping. Attoseconds below 1 ns are truncated.
    @inlinable var wholeNanoseconds: Int64 {
        let (s, a) = components
        let fromSeconds = s.multipliedReportingOverflow(by: 1_000_000_000)
        guard !fromSeconds.overflow else { return s > 0 ? .max : .min }
        return fromSeconds.partialValue &+ a / 1_000_000_000
    }
    @inlinable var milliseconds: Double { Double(wholeNanoseconds) / 1e6 }
    @inlinable var seconds: Double { Double(wholeNanoseconds) / 1e9 }
}
```

```swift
/// Monotonic time source. The pure layer never calls this: it takes `now: MediaInstant` as a
/// parameter. Actors in `VigilTransport` / `VigilCore` / `VigilVideo` own a clock and pass its
/// readings down, which is what makes every pure state machine reproducible from a seed.
public protocol MonotonicClock: Sendable {
    func now() -> MediaInstant
    /// Cancellable sleep. Implementations MUST throw `CancellationError` on task cancellation
    /// and MUST NOT block a cooperative thread.
    func sleep(for duration: Duration) async throws
    /// Cancellable sleep until an absolute instant. Returns immediately if already past.
    func sleep(until deadline: MediaInstant) async throws
}

public extension MonotonicClock {
    func sleep(until deadline: MediaInstant) async throws {
        let remaining = deadline - now()
        guard remaining > .zero else { return }
        try await sleep(for: remaining)
    }
}

/// Wall-clock time. Used ONLY for display, for RTCP NTP mapping, and for parsed playback ranges.
/// Never for control flow, never for timeouts, never for elapsed-time measurement.
public protocol WallClock: Sendable {
    var now: Date { get }
}

/// Production clock. Uses `CLOCK_UPTIME_RAW` on Darwin and `CLOCK_MONOTONIC` on Linux, so it does
/// not advance across sleep on Darwin — which is what we want, because a camera that was
/// unreachable while the lid was shut has not been "timing out" for eight hours.
public struct SystemMonotonicClock: MonotonicClock {
    public init() {}
    public func now() -> MediaInstant { … }
    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

public struct SystemWallClock: WallClock {
    public init() {}
    public var now: Date { Date() }
}
```

```swift
/// Deterministic randomness. Used for Digest `cnonce`, WS-Discovery probe UUIDs, reconnect jitter
/// and JPEG-poll jitter. `mutating` so a seeded generator advances reproducibly — that is the whole
/// point: a failing CI run prints its seed and re-running with that seed reproduces it byte for byte.
///
/// `RTSPRandomSource` does not exist (API_CONTRACT §2 R-09).
public protocol RandomSource: Sendable {
    mutating func next() -> UInt64
}

public extension RandomSource {
    /// Exactly `count` bytes.
    mutating func randomBytes(_ count: Int) -> [UInt8] { … }
    /// `count` lowercase hex characters. `count` must be even; odd values are rounded up.
    mutating func hexString(count: Int) -> String { … }
    /// Uniform in `0..<upperBound`. `upperBound` must be > 0.
    mutating func next(upperBound: UInt64) -> UInt64 { … }
    /// A multiplier in `1 - fraction ... 1 + fraction`, for backoff jitter.
    mutating func jitterFactor(_ fraction: Double) -> Double { … }
}

public struct SystemRandomSource: RandomSource {
    public init() {}
    public mutating func next() -> UInt64 { SystemRandomNumberGenerator().next() }
}

/// Seeded, reproducible, 64-bit. The generator every test and every fixture uses.
/// - Note: SplitMix64, as published by Vigna. Not cryptographic; never used for a secret.
public struct SplitMix64RandomSource: RandomSource {
    private var state: UInt64
    public init(seed: UInt64 = 0x2545_F491_4F6C_DD1D) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
```

### 3.3 `MediaTimestamp`

```swift
/// A rational media time: `value / timescale` seconds. Deliberately mirrors `CMTime`'s semantics
/// without importing CoreMedia, so the pure layer stays Linux-buildable.
///
/// - Important: the initialiser **clamps** a non-positive timescale to 1 rather than trapping.
///   `timescale` derives from the SDP `a=rtpmap` clock rate, which is network data; a camera (or an
///   attacker on the LAN) advertising `H264/0` must not be able to take the app down. Clock-rate
///   validation happens once, at `RTPTrackFormat` construction, which throws
///   `RTPError.invalidClockRate`. See API_CONTRACT §2 R-05.
public struct MediaTimestamp: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {

    /// Numerator, in units of `1 / timescale` seconds.
    public var value: Int64
    /// Denominator. Always > 0 after initialisation. 90 000 for RTP video; the sample rate for
    /// audio; 1 000 000 for host-time conversions; 600 for recorded MP4 tracks.
    public private(set) var timescale: Int32

    /// The sentinel for "no time". Distinguished from `.zero`, which is a real instant.
    public static let invalid = MediaTimestamp(value: .min, timescale: 1)
    public static let zero = MediaTimestamp(value: 0, timescale: 1)

    public init(value: Int64, timescale: Int32) {
        self.value = value
        self.timescale = timescale > 0 ? timescale : 1
    }

    /// Fails rather than clamps. Use at every boundary where a bad timescale is a protocol error
    /// you want to report instead of absorb.
    public init?(validating value: Int64, timescale: Int32) {
        guard timescale > 0 else { return nil }
        self.init(value: value, timescale: timescale)
    }

    @inlinable public var seconds: Double { Double(value) / Double(timescale) }
    @inlinable public var isValid: Bool { self != .invalid }

    /// Exact rescale using 128-bit intermediate arithmetic; rounds half away from zero and
    /// saturates rather than overflowing.
    ///
    /// - Warning: never rescale through `Double`. At a 1/1_000_000 timescale, recorded playback
    ///   exceeds 2^53 within 285 years but loses sub-microsecond precision far sooner, and seek
    ///   accuracy is a user-visible feature.
    public func converted(to newTimescale: Int32) -> MediaTimestamp { … }

    /// Adds `samples` in the receiver's own timescale.
    @inlinable public func adding(samples: Int64) -> MediaTimestamp {
        MediaTimestamp(value: value &+ samples, timescale: timescale)
    }

    /// Sum in the *receiver's* timescale. `.invalid` is absorbing.
    public static func + (a: Self, b: Self) -> Self { … }
    public static func - (a: Self, b: Self) -> Self { … }

    /// Cross-multiplied 128-bit comparison. Explicit `(high, low)` lexicographic compare —
    /// do not rely on tuple `<`, which compares element-wise on signed halves and is wrong here.
    public static func < (a: Self, b: Self) -> Bool { … }

    public var description: String { "\(value)/\(timescale) (\(seconds)s)" }
}

public extension UInt64 {
    /// 128-by-64 division with saturation on overflow. `addend` is added to the 128-bit dividend
    /// before dividing (used to implement round-half-away-from-zero).
    /// - Returns: `(quotient, didSaturate)`. On saturation the quotient is `UInt64.max`.
    static func divideWithOverflowGuard(hi: UInt64, lo: UInt64, by divisor: UInt64,
                                        addend: UInt64) -> (quotient: UInt64, didSaturate: Bool) { … }
}
```

### 3.4 Codecs

```swift
/// A video codec Vigil can carry. `mjpeg` is present because F-DEC-05 and the class-D
/// JPEG-poll tile mode both name it; it is not NAL-based and has no parameter sets.
public enum VideoCodec: String, Sendable, Hashable, Codable, CaseIterable {
    case h264, h265, mjpeg

    /// Bytes of NAL header preceding the RBSP: 1 for H.264, 2 for H.265, 0 for MJPEG.
    @inlinable public var nalHeaderLength: Int {
        switch self { case .h264: 1; case .h265: 2; case .mjpeg: 0 }
    }
    @inlinable public var isNALBased: Bool { self != .mjpeg }

    /// Relative hardware-decode cost per pixel per second, normalised to H.264 = 1.0.
    /// The bit-depth surcharge is applied separately by `DecodeCost` (API_CONTRACT §2 R-58).
    @inlinable public var decodeWeight: Double {
        switch self { case .h264: 1.00; case .h265: 1.35; case .mjpeg: 0.45 }
    }
}

public enum AudioCodec: String, Sendable, Hashable, Codable, CaseIterable {
    case aac, g711A, g711U, g726, pcmS16LE

    /// True when the codec can be muxed into MP4 without re-encoding. Only AAC can.
    /// G.711 in a `.mov` is legal; in an `.mp4` it is not, which is why `ClipRecorder` picks the
    /// container from the audio codec unless the user forced one.
    @inlinable public var isMP4Muxable: Bool { self == .aac }
    /// True when `VigilRTP` decodes it to `.pcmS16LE` in the pure layer.
    @inlinable public var isDecodedInPureLayer: Bool { self == .g711A || self == .g711U || self == .g726 }
    @inlinable public var defaultSampleRate: Int32 {
        switch self { case .aac: 16_000; case .g726: 8_000; default: 8_000 }
    }
}

/// The flat union carried by `EncodedFrame`. Two narrow enums plus one union beats one wide enum,
/// because `ParameterSets` and `VideoFormatInfo` genuinely cannot be audio (API_CONTRACT §2 R-04).
public enum MediaCodec: Sendable, Hashable, Codable, CustomStringConvertible {
    case video(VideoCodec)
    case audio(AudioCodec)

    @inlinable public var video: VideoCodec? { if case .video(let c) = self { c } else { nil } }
    @inlinable public var audio: AudioCodec? { if case .audio(let c) = self { c } else { nil } }
    @inlinable public var isVideo: Bool { video != nil }
    public var description: String { video?.rawValue ?? audio?.rawValue ?? "unknown" }
}
```

### 3.5 The media boundary: `ParameterSets`, `AudioFormatInfo`, `EncodedFrame`

```swift
/// Codec configuration NAL units for one video stream.
///
/// **Canonical storage form — binding, no exceptions.** Every `Data` element is:
/// 1. **With** its NAL header (1 byte H.264, 2 bytes H.265).
/// 2. **Without** any Annex-B start code and **without** any length prefix.
/// 3. In **escaped, on-wire form** — emulation-prevention `0x03` bytes are still present.
/// 4. Byte-identical to what the camera sent, or to what base64-decoding `sprop-parameter-sets`
///    / `sprop-vps` / `sprop-sps` / `sprop-pps` produced.
///
/// This is exactly the form `avcC`, `hvcC` and
/// `CMVideoFormatDescriptionCreateFrom{H264,HEVC}ParameterSets` require. Parsing always unescapes
/// into a throwaway buffer; we never store unescaped RBSP.
///
/// Ordering within each array is ascending parameter-set id. A re-sent set with an id we already
/// hold **replaces** it in place — Hikvision re-sends SPS/PPS before every IDR, usually identical,
/// occasionally changed after a resolution change.
public struct ParameterSets: Sendable, Hashable, Codable {
    public var codec: VideoCodec
    /// H.265 only; always empty for H.264 and MJPEG.
    public var vps: [Data]
    public var sps: [Data]
    public var pps: [Data]

    public init(codec: VideoCodec, vps: [Data] = [], sps: [Data] = [], pps: [Data] = [])

    /// True when there are enough bytes to build a format description. VPS is optional for H.264
    /// and required in practice (though not by CoreMedia) for H.265.
    /// - Note: `isComplete` is about *bytes*, not parsability. A parameter set we cannot parse is
    ///   still stored and still forwarded; `VideoFormatInfo == nil` must never block decoding.
    @inlinable public var isComplete: Bool { !sps.isEmpty && !pps.isEmpty }

    /// In the order CoreMedia wants: `[SPS, PPS]` for H.264, `[VPS, SPS, PPS]` for H.265.
    @inlinable public var orderedForCoreMedia: [Data] {
        codec == .h265 ? vps + sps + pps : sps + pps
    }

    /// FNV-1a over every byte, in `orderedForCoreMedia` order. The cheap change detector.
    public var fingerprint: UInt64 { … }
}
```

```swift
/// Everything a decoder needs about an audio stream that is not in the samples themselves.
public struct AudioFormatInfo: Sendable, Hashable, Codable {
    public var codec: AudioCodec
    public var sampleRate: Int32
    public var channels: Int32
    /// 1024 for AAC-LC, 960 for AAC-LC/960, 1 for PCM and G.711.
    public var framesPerPacket: Int32
    /// AAC `AudioSpecificConfig`, verbatim, for `kAudioConverterDecompressionMagicCookie`.
    /// **Never** smuggled through `ParameterSets.sps[0]` (API_CONTRACT §2 R-54).
    public var magicCookie: Data?

    public init(codec: AudioCodec, sampleRate: Int32, channels: Int32,
                framesPerPacket: Int32, magicCookie: Data? = nil)
}

/// How droppable a frame is under queue pressure. Derived by `VigilRTP` while depacketizing,
/// because that is the only place the NAL headers are already in hand.
public enum FrameDropClass: UInt8, Sendable, Hashable, Codable, Comparable {
    /// Referenced by later frames. Dropping it corrupts everything until the next IRAP.
    case required = 0
    /// H.264: every VCL NAL of the AU had `nal_ref_idc == 0`.
    case droppableNonReference = 1
    /// H.265: `nuh_temporal_id > 0` with `sps_temporal_id_nesting_flag == 1`.
    case droppableTemporal = 2
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}
```

```swift
/// One access unit (video) or one audio buffer.
///
/// **This is the only media type that crosses from the pure layer into `VigilVideo`.**
/// Foundation-only by construction. `spec-rtp.md`, `spec-bitstream.md` and
/// `spec-video-pipeline.md` all restate it; this declaration is the normative one
/// (API_CONTRACT §2 R-02).
public struct EncodedFrame: Sendable, Equatable {

    // MARK: - Payload

    /// Video: concatenated NAL units, each preceded by a **4-byte big-endian length**
    /// (AVCC/HVCC style, `nalUnitHeaderLength == 4`). **Never Annex-B.** Start codes never appear.
    /// There is no configuration knob and no conversion step on the live path: the depacketizers
    /// write the 4-byte length directly as they reassemble, and `VigilVideo` hands `data`
    /// straight to `CMBlockBufferCreateWithMemoryBlock`.
    ///
    /// Audio, `.aac`: one raw AAC access unit — no ADTS header, no length prefix.
    /// Audio, `.pcmS16LE`: interleaved signed 16-bit little-endian samples.
    /// Video, `.mjpeg`: one complete JPEG, SOI to EOI, no length prefix.
    public var data: Data

    public var codec: MediaCodec

    // MARK: - Time

    public var pts: MediaTimestamp
    /// `nil` when the stream does not reorder — which is every Hikvision live profile and all
    /// audio. Populated only for recorded content with B-frames, where `dts <= pts` is guaranteed.
    /// `VigilVideo` treats `nil` as "dts == pts" and must never synthesise a decode order
    /// (API_CONTRACT §2 R-06).
    public var dts: MediaTimestamp?
    /// Always present for audio; present for video only when the frame rate is known.
    public var duration: MediaTimestamp?
    /// Arrival of the **last** packet of this access unit. The anchor for the glass-to-glass
    /// latency estimate.
    public var receivedAt: MediaInstant

    // MARK: - Classification

    /// IDR (H.264 NAL type 5) or IRAP (H.265 types 16–23). **Not** "an I-slice"
    /// — that distinction drives sync samples in recordings and the `NotSync` attachment.
    public var isKeyframe: Bool
    public var dropClass: FrameDropClass
    /// True when at least one NAL was lost or truncated. `VigilVideo` drops these unless
    /// `AppSettings.decodeCorruptFrames` is on (default off).
    public var isCorrupt: Bool

    // MARK: - Format

    /// Non-`nil` **only on the first frame after the sets changed**, including the very first
    /// frame. `VigilVideo` must retain the last non-`nil` value for the lifetime of the stream
    /// and must not expect a resend after a decoder reset (API_CONTRACT §2 R-53).
    public var parameterSets: ParameterSets?
    /// Non-`nil` on the first audio frame and whenever the audio configuration changes.
    public var audioFormat: AudioFormatInfo?

    // MARK: - Accounting

    /// Extended (unwrapped) RTP sequence numbers of the first and last packet that fed this frame.
    /// `nil` for frames produced from a file rather than from RTP.
    public var sequenceRange: ClosedRange<UInt32>?
    /// Monotonic access-unit counter for this stream, starting at 0 and never reset except by
    /// `Depacketizer.reset()`. Gap accounting compares consecutive values.
    public var accessUnitIndex: UInt64
    /// Number of NAL units in `data`, so `VigilVideo` can size scratch arrays without rescanning.
    public var nalCount: Int

    @inlinable public var byteCount: Int { data.count }
    @inlinable public var videoCodec: VideoCodec? { codec.video }

    public init(data: Data, codec: MediaCodec, pts: MediaTimestamp,
                dts: MediaTimestamp? = nil, duration: MediaTimestamp? = nil,
                receivedAt: MediaInstant, isKeyframe: Bool,
                dropClass: FrameDropClass = .required, isCorrupt: Bool = false,
                parameterSets: ParameterSets? = nil, audioFormat: AudioFormatInfo? = nil,
                sequenceRange: ClosedRange<UInt32>? = nil, accessUnitIndex: UInt64 = 0,
                nalCount: Int = 0)
}
```

### 3.6 Geometry, colour and format

```swift
/// Integer pixel dimensions. The one size type in Vigil: used for stream resolution, display
/// resolution and tile backing size alike. `PixelSize` does not exist (API_CONTRACT §2 R-57).
public struct Resolution: Sendable, Hashable, Codable, Comparable, CustomStringConvertible {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int)

    @inlinable public var pixels: Int { width * height }
    @inlinable public var megapixels: Double { Double(pixels) / 1_000_000 }
    @inlinable public var aspect: Double { height == 0 ? 0 : Double(width) / Double(height) }
    /// `min(width, height)`. The input to the tile-class table (API_CONTRACT §2 R-21).
    @inlinable public var shortEdge: Int { Swift.min(width, height) }

    public static let uhd4K  = Resolution(width: 3840, height: 2160)
    public static let hd1080 = Resolution(width: 1920, height: 1080)
    public static let hd720  = Resolution(width: 1280, height: 720)
    public static let d1     = Resolution(width: 704, height: 576)
    public static let cif    = Resolution(width: 352, height: 288)

    /// Nearest human label: "4K", "5MP", "1080p", "720p", "D1", "CIF", else "W×H".
    public var shortLabel: String { … }
    public var description: String { "\(width)×\(height)" }
    /// Ordered by pixel count, then width.
    public static func < (a: Self, b: Self) -> Bool { … }
}

public enum FieldOrder: UInt8, Sendable, Hashable, Codable {
    case progressive, topFieldFirst, bottomFieldFirst
}

/// Colour description carried from the SPS/VPS VUI to the renderer. Pure integers and enums, so
/// `VigilBitstream` computes it on Linux and `VigilRenderTests` can assert on it without a GPU.
public struct ColorInfo: Sendable, Hashable, Codable {
    public enum Matrix: UInt8, Sendable, Hashable, Codable { case bt601, bt709, bt2020ncl, unspecified }
    public enum Range: UInt8, Sendable, Hashable, Codable { case video, full }
    public enum Transfer: UInt8, Sendable, Hashable, Codable {
        case bt709, smpte170m, srgb, pq, hlg, unspecified
    }
    public enum Primaries: UInt8, Sendable, Hashable, Codable {
        case bt709, bt2020, smpte170m, unspecified
    }
    public enum ChromaSiting: UInt8, Sendable, Hashable, Codable { case left, center, topLeft }

    public var matrix: Matrix
    public var range: Range
    public var transfer: Transfer
    public var primaries: Primaries
    public var chromaSiting: ChromaSiting

    /// The default when the VUI is absent, which is most Hikvision firmware:
    /// BT.709, video range, left siting. BT.601 is substituted when `codedHeight < 576`.
    public static let bt709Video = ColorInfo(matrix: .bt709, range: .video, transfer: .bt709,
                                             primaries: .bt709, chromaSiting: .left)
    public static let bt601Video = ColorInfo(matrix: .bt601, range: .video, transfer: .smpte170m,
                                             primaries: .smpte170m, chromaSiting: .left)
    /// True only for PQ or HLG. EDR is enabled only for these, and only on a screen whose
    /// `maximumExtendedDynamicRangeColorComponentValue > 1.0`.
    @inlinable public var isHDR: Bool { transfer == .pq || transfer == .hlg }
    public init(matrix: Matrix, range: Range, transfer: Transfer,
                primaries: Primaries, chromaSiting: ChromaSiting)
}

/// Coded geometry, clean aperture and sample aspect ratio for one video stream.
///
/// **Report cropped display size; allocate from coded size.** 1080p H.264 is coded 1920×1088 and
/// displayed 1920×1080. `VigilRender`, `VigilUI` and `ClipRecorder` read `displaySize`, never the
/// pixel buffer's extent.
public struct FrameGeometry: Sendable, Hashable, Codable {
    /// Allocation size, in luma samples. Always a multiple of the codec's macroblock/CTB size.
    public var codedWidth: Int
    public var codedHeight: Int
    /// Clean aperture inside the coded frame, origin top-left, in luma samples.
    public var cropLeft: Int
    public var cropTop: Int
    public var cropWidth: Int
    public var cropHeight: Int
    /// Sample (pixel) aspect ratio. `1:1` when the VUI is absent or says square.
    public var sarWidth: Int
    public var sarHeight: Int
    /// 8 or 10. Values outside `8...12` are a parse error.
    public var bitDepth: Int
    public var fieldOrder: FieldOrder
    public var color: ColorInfo

    public init(codedWidth: Int, codedHeight: Int,
                cropLeft: Int = 0, cropTop: Int = 0, cropWidth: Int, cropHeight: Int,
                sarWidth: Int = 1, sarHeight: Int = 1, bitDepth: Int = 8,
                fieldOrder: FieldOrder = .progressive, color: ColorInfo = .bt709Video)

    @inlinable public var codedSize: Resolution { Resolution(width: codedWidth, height: codedHeight) }
    /// The cropped picture, before SAR correction.
    @inlinable public var croppedSize: Resolution { Resolution(width: cropWidth, height: cropHeight) }
    @inlinable public var pixelAspectRatio: Double { Double(sarWidth) / Double(sarHeight) }
    /// The size the picture should occupy on a square-pixel display. **This is what the tile,
    /// the window and the recorder use.**
    @inlinable public var displaySize: Resolution {
        Resolution(width: Int((Double(cropWidth) * pixelAspectRatio).rounded()), height: cropHeight)
    }
    @inlinable public var displayAspect: Double {
        cropHeight == 0 ? 0 : Double(cropWidth) * pixelAspectRatio / Double(cropHeight)
    }
    @inlinable public var isProgressive: Bool { fieldOrder == .progressive }
}
```

```swift
/// The neutral, platform-independent description of a decoded video format.
///
/// `VigilBitstream` produces it from SPS/VPS/PPS; `VigilVideo` converts it to a
/// `CMVideoFormatDescription` in exactly one file; `VigilRender` reads `geometry`.
/// `VigilVideo.VideoFormat` does not exist (API_CONTRACT §2 R-50).
public struct VideoFormatInfo: Sendable, Hashable, Codable {
    public var codec: VideoCodec
    public var geometry: FrameGeometry
    /// Parsed from the VUI. **Metadata only** — RTP timestamps drive the live clock and the
    /// container drives recorded playback. The fallback chain is VUI → RTP-measured → ISAPI → 25.0.
    /// H.264 divides by `2 × num_units_in_tick`; H.265 does not divide by 2.
    public var frameRate: Double?

    public var profileIDC: UInt8
    /// H.264 only: the eight `constraint_setN_flag` bits.
    public var constraintFlags: UInt8
    public var levelIDC: UInt8
    /// H.265 only. 0 = Main tier, 1 = High tier.
    public var tier: UInt8
    /// 0 monochrome, 1 = 4:2:0, 2 = 4:2:2, 3 = 4:4:4. Vigil decodes 1 and (H.265) 2.
    public var chromaFormatIDC: UInt8
    public var maxNumReorderFrames: Int
    public var maxDecFrameBuffering: Int
    public var minSpatialSegmentationIDC: Int
    public var numTemporalLayers: Int
    public var temporalIDNested: Bool
    /// "High", "Main 10", "Baseline"… For the inspector, never for control flow.
    public var profileName: String
    /// "4.1", "5.1"… For the inspector.
    public var levelName: String

    // Passthroughs so `spec-bitstream.md`'s prose still reads correctly.
    @inlinable public var codedWidth: Int { geometry.codedWidth }
    @inlinable public var codedHeight: Int { geometry.codedHeight }
    @inlinable public var displayWidth: Int { geometry.displaySize.width }
    @inlinable public var displayHeight: Int { geometry.displaySize.height }
    @inlinable public var sarWidth: Int { geometry.sarWidth }
    @inlinable public var sarHeight: Int { geometry.sarHeight }
    @inlinable public var bitDepthLuma: Int { geometry.bitDepth }
    @inlinable public var isProgressive: Bool { geometry.isProgressive }
    @inlinable public var pixelAspectRatio: Double { geometry.pixelAspectRatio }
    @inlinable public var displayAspectRatio: Double { geometry.displayAspect }
    @inlinable public var codedPixels: Int { geometry.codedWidth * geometry.codedHeight }

    /// **A format change is exactly this and nothing else:** codec, coded width, coded height,
    /// chroma format, or luma bit depth. Anything else (crop, SAR, colour, frame rate, level)
    /// bumps the `generation` counter — rebuild the format description, keep the decode session.
    @inlinable public func isDecoderCompatible(with other: VideoFormatInfo) -> Bool {
        codec == other.codec
            && geometry.codedWidth == other.geometry.codedWidth
            && geometry.codedHeight == other.geometry.codedHeight
            && chromaFormatIDC == other.chromaFormatIDC
            && geometry.bitDepth == other.geometry.bitDepth
    }
}
```

### 3.7 Stream identity, quality and decode policy

```swift
/// Which of a device's encoders a stream comes from.
///
/// There is **no `.auto` case**: "automatic" is the absence of an override, spelled
/// `StreamQuality?` (API_CONTRACT §2 R-55). `StreamProfile.Kind` and `StreamIndex` do not exist.
public enum StreamQuality: Int, Sendable, Hashable, Codable, CaseIterable, Comparable {
    case main = 1, sub = 2, third = 3
    public var stringValue: String { switch self { case .main: "main"; case .sub: "sub"; case .third: "third" } }
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    // Codable as the lowercase string, not the integer.
    public init(from decoder: any Decoder) throws { … }
    public func encode(to encoder: any Encoder) throws { … }
}

/// What a decode pipeline, an audio route and a budget grant are keyed by. A camera alone is not
/// enough: during the 150 ms keyframe-gated crossfade of a quality switch, main and sub are both
/// live (API_CONTRACT §2 R-63). `StreamIdentifier` does not exist.
public struct StreamKey: Sendable, Hashable, Codable, CustomStringConvertible {
    public var camera: CameraID
    public var quality: StreamQuality
    public init(camera: CameraID, quality: StreamQuality)
    public var description: String { "\(camera.short)/\(quality.stringValue)" }
}

public enum RTSPTransportKind: String, Sendable, Hashable, Codable, CaseIterable {
    /// `Transport: RTP/AVP/TCP;unicast;interleaved=0-1`. **The default** — it traverses every LAN
    /// and needs no inbound ports.
    case tcpInterleaved
    case udpUnicast
    case udpMulticast
    /// `rtsps`, port 322, trust-on-first-use leaf pinning shared with ISAPI.
    case tcpTLS
    @inlinable public var isUDP: Bool { self == .udpUnicast || self == .udpMulticast }
    @inlinable public var defaultPort: Int { self == .tcpTLS ? 322 : 554 }
}

/// Jitter-buffer depth / decode-queue trade-off, chosen per camera.
public enum LatencyPreset: String, Sendable, Hashable, Codable, CaseIterable {
    /// 40 ms / 8 packets, decode queue 2, aggressive drop-to-keyframe.
    case low
    /// 120 ms / 24 packets, decode queue 3. **The default.**
    case balanced
    /// 350 ms / 64 packets, decode queue 5, never drop unless the queue is full.
    case quality
    @inlinable public var jitterBufferDepth: Duration { … }
    @inlinable public var jitterBufferPackets: Int { … }
    @inlinable public var decodeQueueDepth: Int { … }
}
```

```swift
/// How hard a stream is being run, independent of which stream it is.
/// Axis 2 of the tile policy (API_CONTRACT §2 R-21).
public enum DecodeMode: Int, Sendable, Hashable, Codable, Comparable, CaseIterable {
    case paused = 0
    case jpegPoll = 1
    case keyframesOnly = 2
    /// 15 fps ceiling on a 25/30 fps stream. `ReducedFrameDelivery = 0.5`.
    case fpsCapped = 3
    /// Drop droppable frames under transient pressure; not a steady state.
    case trim = 4
    case full = 5
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    /// Multiplier on the DU cost. `paused` and `jpegPoll` cost zero hardware-decode budget.
    @inlinable public var costWeight: Double {
        switch self {
        case .paused, .jpegPoll: 0
        case .keyframesOnly: 0.12
        case .fpsCapped: 0.55
        case .trim: 0.80
        case .full: 1.00
        }
    }
}

/// Which stream a tile wants, or none.
public enum StreamChoice: Sendable, Hashable, Codable {
    case stream(StreamQuality)
    /// ISAPI JPEG poll at the given interval. No RTSP session, no decode session, 0 DU.
    case jpegPoll(interval: Duration)
    case none
}

/// Admission priority. Ties break on `orderIndex` ascending. One enum, not two
/// (`TilePriority` does not exist — API_CONTRACT §2 R-49).
public enum StreamPriority: Int, Sendable, Hashable, Codable, Comparable, CaseIterable {
    /// Fullscreen, or the single focused tile, or the audio-solo camera.
    case focused = 400
    /// On-screen tile with a short edge ≥ 480 backing px.
    case visibleLarge = 300
    /// On-screen tile with a short edge < 480 backing px.
    case visibleSmall = 200
    /// Video-wall tile on a secondary display.
    case wall = 175
    case pictureInPicture = 150
    /// **Never demoted, never occlusion-paused.** A recording must not be sacrificed for a preview.
    case recording = 350
    /// In the layout but scrolled off, occluded, or pre-warming.
    case offscreen = 100
    case sidebarThumbnail = 50
    /// `Camera.isPinnedLive` and nothing else.
    case background = 10
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Hardware-decode cost in **decode units**. 1 DU = one 1080p30 H.264 stream.
public struct DecodeCost: Sendable, Hashable, Codable, Comparable, CustomStringConvertible {
    /// Always a non-negative multiple of 0.25.
    public let units: Double
    public init(units: Double)

    /// `ceil( codedPixels × fps / (1920×1080×30) × codecWeight × depthWeight × modeWeight × 4 ) / 4`
    /// where `depthWeight` is 1.26 above 8-bit and 1.0 otherwise, plus 0.05 additive when
    /// downscale-on-decode is active (API_CONTRACT §2 R-58). Uses **coded** pixels, not display
    /// pixels: the decoder allocates 1088 lines and that is what costs bandwidth.
    public static func estimate(geometry: FrameGeometry, codec: VideoCodec, fps: Double,
                                mode: DecodeMode, isDownscaling: Bool = false) -> DecodeCost { … }

    public static let zero = DecodeCost(units: 0)
    public static func + (a: Self, b: Self) -> Self { DecodeCost(units: a.units + b.units) }
    public static func < (a: Self, b: Self) -> Bool { a.units < b.units }
    public var description: String { String(format: "%.2f DU", units) }
}

/// A granted reservation. Releasing is idempotent and MUST happen in a `defer` or an actor
/// `deinit`-equivalent path; a leaked lease starves every other camera.
public struct DecodeLease: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let key: StreamKey
    public private(set) var cost: DecodeCost
    public private(set) var mode: DecodeMode
}

public enum DenialReason: String, Sendable, Hashable, Codable {
    case insufficientBudget, sessionLimitReached, thermalCritical, hardwareUnavailable
}

public enum BudgetPressure: String, Sendable, Hashable, Codable, Comparable, CaseIterable {
    /// < 70 % of budget committed.
    case none
    /// 70–95 %.
    case moderate
    /// > 95 %, or any stream currently demoted by admission.
    case severe
    public static func < (a: Self, b: Self) -> Bool { … }
}

/// The admission authority, declared here so `StreamCoordinator`'s planner is Linux-testable.
/// The single implementation is `VigilVideo.DecodeBudget`, a `@globalActor actor`
/// (API_CONTRACT §2 R-49).
public protocol DecodeAdmitting: Sendable {
    /// Total DU available right now, after thermal and low-power multipliers.
    func currentBudget() async -> DecodeCost
    /// Hard ceiling on simultaneous `VTDecompressionSession`s / `AVSampleBufferDisplayLayer`s,
    /// which VideoToolbox exhausts long before the DU budget does on small streams.
    func maxConcurrentSessions() async -> Int
    /// Reserves capacity, possibly at a cheaper mode than requested.
    func admit(key: StreamKey, cost: DecodeCost, mode: DecodeMode,
               priority: StreamPriority, isPreemptible: Bool) async -> AdmissionResult
    /// Re-prices an existing lease after a tile resize or a format change.
    func update(_ lease: DecodeLease, cost: DecodeCost, mode: DecodeMode,
                priority: StreamPriority) async -> AdmissionResult
    func release(_ lease: DecodeLease) async
    /// Reserves headroom for a transient (strategy switch, one-shot snapshot session).
    func reserveTransient(_ cost: DecodeCost, for duration: Duration) async -> Bool
    /// Demotion orders pushed to pipelines. A factory, not a property (API_CONTRACT §2 R-65).
    func budgetChanges() -> AsyncStream<BudgetChange>
    func snapshot() async -> BudgetSnapshot
}

public enum AdmissionResult: Sendable, Hashable {
    case granted(DecodeLease)
    /// Admitted, but at a cheaper mode than asked for. The caller MUST surface a visible badge
    /// and an inspector note: silent degradation is a defect (FEATURES.md honesty requirement).
    case grantedDegraded(DecodeLease, DecodeMode)
    case denied(DenialReason)
}

public enum BudgetChange: Sendable, Hashable {
    case demote(StreamKey, to: DecodeMode, reason: DenialReason)
    case promote(StreamKey, to: DecodeMode)
    case pressureChanged(BudgetPressure)
    case budgetChanged(DecodeCost, reason: String)
}

public struct BudgetSnapshot: Sendable, Hashable, Codable {
    public var budget: DecodeCost
    public var committed: DecodeCost
    public var sessionCount: Int
    public var maxSessions: Int
    public var pressure: BudgetPressure
    public var modes: [StreamKey: DecodeMode]
}
```

```swift
/// Tile size class. Axis 1 of the tile policy (API_CONTRACT §2 R-21).
/// The input is the tile's **short edge in backing pixels**.
public enum TileClass: String, Sendable, Hashable, Codable, CaseIterable, Comparable {
    /// ≥ 1080 px. 1-up, fullscreen, PiP, video wall.
    case a
    /// 480–1079 px. Sub, promoted to main when the sub is visibly soft and budget allows.
    case b
    /// 96–479 px. Sub. The 4×4 case.
    case c
    /// 1–95 px. ISAPI JPEG poll, no decode session at all.
    case d
    /// Hidden, occluded, or the window is minimised.
    case e
    public static func < (a: Self, b: Self) -> Bool { … }
}

public struct TileContext: Sendable, Hashable {
    /// Backing pixels, i.e. points × `backingScaleFactor`, rounded to integers. Supplied by
    /// `TileRenderState.pixelSize`; never points.
    public var pixelSize: Resolution
    public var isVisible: Bool
    public var isOccluded: Bool
    public var isFocused: Bool
    public var isSidebarThumbnail: Bool
    public var isOffscreenScroll: Bool
    public var isRecording: Bool
    /// Coded height of the device's sub stream, for the class-B promotion test. `nil` when unknown.
    public var subStreamHeight: Int?
    /// Some analog NVR channels have no sub stream.
    public var deviceSupportsSubStream: Bool
    /// The user's per-tile lock. When non-`nil`, automatic switching is disabled for this tile
    /// and the UI shows "Main (locked)".
    public var qualityOverride: StreamQuality?
    public var jpegPollIntervalOverride: Duration?

    public init(pixelSize: Resolution, isVisible: Bool = true, isOccluded: Bool = false,
                isFocused: Bool = false, isSidebarThumbnail: Bool = false,
                isOffscreenScroll: Bool = false, isRecording: Bool = false,
                subStreamHeight: Int? = nil, deviceSupportsSubStream: Bool = true,
                qualityOverride: StreamQuality? = nil, jpegPollIntervalOverride: Duration? = nil)
}

/// The class A–E table, as a pure function. Deterministic, allocation-free, unit-tested on Linux.
public enum TilePolicy {

    public static let dwell: Duration = .milliseconds(750)
    public static let deadBand: Double = 0.15
    /// Class boundaries in backing pixels of the tile's short edge.
    public static let classAFloor = 1080
    public static let classBFloor = 480
    public static let classCFloor = 96
    /// Class-B promotion fires when the sub stream's coded height is below this fraction of the
    /// tile's short edge — i.e. the sub is visibly soft.
    public static let promotionSoftnessRatio = 0.75

    public static func tileClass(for context: TileContext) -> TileClass
    /// Which stream to pull. Does not consider the decode budget — that is Axis 2.
    public static func choice(for context: TileContext) -> StreamChoice
    /// True when a change from `current` to `proposed` clears the 15 % dead band.
    public static func clearsDeadBand(current: TileClass, proposed: TileClass,
                                      shortEdge: Int) -> Bool
    /// JPEG cadence for class D and for non-tile surfaces.
    /// Stage tile 1 s, sidebar row 5 s, offscreen / menu-bar 15 s, scaled by the number of
    /// simultaneously polling surfaces so a device never sees more than 1 request per second.
    public static func jpegInterval(for context: TileContext, pollingSurfaces: Int) -> Duration
}
```

### 3.8 `StreamStatistics`

```swift
/// Per-stream telemetry. **Shape is fixed here; `VigilRTP` owns the update algebra**
/// (fps EWMA α 0.10, kbps EWMA α 0.25 over a 500 ms window, keyframe-interval EWMA α 0.20, loss
/// fraction over 2 s, jitter per RFC 3550 A.8 converted from timescale units to milliseconds).
/// `VigilVideo` writes the four decode fields through `RTPTrackReceiver`'s setters.
///
/// Sampled at 1 Hz by `HealthMonitor` into a fixed 600-slot ring per camera.
public struct StreamStatistics: Sendable, Hashable, Codable {
    // Throughput
    public var framesDecoded: UInt64 = 0
    public var framesPerSecond: Double = 0
    public var bitsPerSecond: Double = 0
    public var keyframeIntervalSeconds: Double = 0
    // Loss and order
    public var packetsReceived: UInt64 = 0
    public var packetsLost: UInt64 = 0
    public var packetsOutOfOrder: UInt64 = 0
    public var packetsDuplicated: UInt64 = 0
    /// Over the last 2 s window, 0...1.
    public var lossFraction: Double = 0
    public var gapCount: UInt32 = 0
    // Timing
    public var jitterMilliseconds: Double = 0
    public var jitterBufferDepthPackets: Int = 0
    public var jitterBufferDepthMilliseconds: Double = 0
    /// Capture→display estimate, RTCP-anchored. Must land within ±25 ms of the physical rig.
    public var estimatedLatencyMilliseconds: Double = 0
    // Decode — written by VigilVideo
    public var decodeQueueDepth: Int = 0
    public var framesDroppedPreDecode: UInt64 = 0
    public var framesDroppedPreDisplay: UInt64 = 0
    public var decodeMillisecondsP50: Double = 0
    public var decodeMillisecondsP99: Double = 0
    /// **Measured**, from `kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder` —
    /// never the requested value. Honesty is a shipping requirement.
    public var isHardwareAccelerated: Bool = false
    // Session
    public var uptimeSeconds: Double = 0
    public var reconnectCount: UInt32 = 0
    /// A `diagnosticCode` such as `VG-RTSP-0401`, never a message.
    public var lastErrorCode: String?

    public init()
}
```

### 3.9 Errors

```swift
/// Everything an error must be able to tell us: how to log it, what to show a human, and whether
/// to retry. `VigilErrorDescribing` does not exist (API_CONTRACT §2 R-11).
public protocol VigilFailure: Error, Sendable {
    /// Stable machine code, `VG-<DOMAIN>-NNNN`. Appears in logs, the diagnostics bundle and the
    /// Stream Doctor's "copy details". **Stable forever; never reuse a retired code.**
    var diagnosticCode: String { get }
    var severity: ErrorSeverity { get }
    var disposition: RetryDisposition { get }
    /// One sentence, sentence case, no jargon, no error numbers. Localised.
    var userMessage: String { get }
    /// One imperative sentence telling the user what to do, or `nil` if there is nothing to do.
    var userRemedy: String? { get }
    /// Extra key/values for the log line. MUST already be redacted.
    var logMetadata: [String: String] { get }
}

public enum ErrorSeverity: Int, Sendable, Hashable, Codable, Comparable {
    case degraded, recoverable, fatal
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public enum RetryDisposition: Sendable, Hashable, Codable {
    /// Transient: network blip, timeout, camera reboot. Uses the 0.5/1/2/4/8/15/30 s ladder.
    case retryWithBackoff
    /// Stale Digest nonce, 401 with a new nonce, `kVTInvalidSessionErr`. One free retry.
    case retryImmediatelyOnce
    /// Wrong password, camera not activated, unsupported codec. **Never auto-retry.**
    case retryAfterUserAction
    /// Programmer error, unsupported OS feature.
    case noRetry
}

/// The root error. Every domain enum it wraps is declared in `VigilProtocols` too — otherwise
/// `VigilProtocols` would have to import `VigilRTSP`, which imports `VigilProtocols`, and nothing
/// would build (API_CONTRACT §2 R-10).
public enum VigilError: Error, Sendable, Hashable, VigilFailure {
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

/// Throws instead of trapping. We never take the whole window down because one camera sent
/// something odd; these bytes come from the network, so a crash is a security bug.
@inline(__always)
public func vigilRequire(_ condition: Bool, _ message: @autoclosure () -> String,
                         file: StaticString = #fileID, line: UInt = #line) throws(VigilError) {
    guard !condition else { return }
    throw VigilError.internalInvariant(message(), file: file, line: line)
}
```

The eleven domain enums live in `Errors/DomainErrors.swift`. Each is
`public enum …: Error, Sendable, Hashable, VigilFailure`. Case lists are normative; a module spec
may document a case's meaning but may not add or rename one without amending this table.

| Enum | Cases | Severity | Disposition |
|---|---|---|---|
| `TransportError` | `.connectTimeout`, `.connectRefused`, `.hostUnreachable`, `.peerClosed`, `.readIdleTimeout`, `.tlsFailed(String)`, `.tlsUntrusted(fingerprint: String)`, `.tlsPinMismatch(host: String)`, `.multicastBlocked`, `.localNetworkDenied`, `.egressBlocked(host: String)`, `.network(String)` | recoverable; `.localNetworkDenied`, `.egressBlocked`, `.tlsPinMismatch` fatal | backoff; the three fatals → user action |
| `RTSPError` | `.malformedResponse`, `.headerTooLarge(bytes: Int)`, `.unexpectedStatus(code: Int)`, `.unauthorized`, `.authRejected`, `.accessForbidden`, `.credentialsMissing`, `.methodNotSupported`, `.noSuitableTrack`, `.sdpParse(String)`, `.transportRejected`, `.sessionNotFound`, `.pathNotFound`, `.interleaveDesync(recovered: Bool)`, `.commandQueueOverflow`, `.tooManyRedirects`, `.timeout(RTSPTimerID)` | `.authRejected`, `.accessForbidden`, `.credentialsMissing` fatal; `.interleaveDesync(recovered: true)` degraded; rest recoverable | `.unauthorized` → immediately once; the three fatals → user action; rest → backoff |
| `RTPError` | `.shortPacket(length: Int)`, `.badVersion(UInt8)`, `.truncatedCSRC`, `.truncatedExtension`, `.badPaddingLength(UInt8)`, `.unknownPayloadType(UInt8)`, `.badFragment`, `.aggregationOverflow`, `.jitterBufferOverflow(dropped: Int)`, `.gap(count: Int)`, `.unsupportedEncoding(String)`, `.missingRequiredFmtp(String)`, `.unsupportedAACMode(String)`, `.malformedAudioConfig(String)`, `.invalidClockRate(Int32)` | degraded; the last five recoverable | none (counted in stats, never fails a session); the last five → user action |
| `BitstreamError` | `.emptyNALUnit`, `.tooLarge(bytes: Int)`, `.unexpectedEndOfData(atBit: Int)`, `.malformedExpGolomb(leadingZeros: Int)`, `.valueOutOfRange(field: String, value: UInt64)`, `.wrongNALType(expected: UInt8, found: UInt8)`, `.forbiddenBitSet`, `.invalidTemporalID`, `.negativeSkip`, `.invalidCropping`, `.unsupportedSyntax(String)`, `.unsupportedProfile(idc: UInt8)`, `.unsupportedChromaFormat(idc: UInt8)`, `.truncatedSEI`, `.truncatedLengthPrefix(atOffset: Int)`, `.unsupportedRecordVersion(UInt8)`, `.unsupportedLengthSize(UInt8)`, `.invalidBase64`, `.noParameterSets` | recoverable | `.noParameterSets` → wait for the next IRAP; rest → backoff |
| `ISAPIError` | `.notConnected(String)`, `.timedOut(resource: String, seconds: Double)`, `.cancelled`, `.responseTooLarge(bytes: Int)`, `.authenticationFailed(username: String)`, `.accountLocked(retryAfter: Double?)`, `.authBlockedLocally(failures: Int)`, `.unsupportedAuthentication(String)`, `.insufficientPermission(resource: String)`, `.deviceNotActivated`, `.http(status: Int, resource: String)`, `.device(statusCode: Int, sub: String?)`, `.notSupported(resource: String)`, `.notFound(resource: String)`, `.deviceBusy`, `.rebootRequired`, `.malformedResponse(String)`, `.unexpectedContentType(expected: String, got: String?)`, `.multipartProtocolError(String)`, `.streamEnded(afterBytes: Int)`, `.partTooLarge(bytes: Int, limit: Int)`, `.tlsUnavailableOnThisPlatform` | `.accountLocked`, `.authenticationFailed`, `.authBlockedLocally`, `.deviceNotActivated`, `.insufficientPermission` fatal | `.deviceBusy` → backoff; `.notSupported`/`.notFound` → no retry, cache the negative for 24 h |
| `DiscoveryError` | `.interfaceEnumerationFailed(errno: Int32)`, `.noEligibleInterfaces`, `.arpReadFailed(errno: Int32)`, `.multicastUnavailable(MulticastUnavailableReason)`, `.channelBindFailed(port: UInt16, String)`, `.prefixTooWide(bits: UInt8, hostCount: Int)`, `.probeSendFailed`, `.budgetExhausted(BudgetKind)`, `.cancelled` | recoverable | `.multicastUnavailable` → fall back to a unicast sweep, surface a one-time notice |
| `DecodeError` | `.vt(status: Int32)`, `.badData`, `.invalidSession`, `.malfunction`, `.formatChangeUnsupported`, `.noHardwareDecoder`, `.budgetDenied(DenialReason)`, `.missingParameterSets`, `.emptyParameterSet(index: Int)`, `.tooManyParameterSets(count: Int)`, `.formatDescriptionFailed(status: Int32)`, `.blockBufferFailed(status: Int32)`, `.sampleBufferFailed(status: Int32)`, `.pixelBufferPoolFailed(status: Int32)`, `.unsupportedFormat(codec: VideoCodec, detail: String)` | `.noHardwareDecoder` degraded | `.invalidSession`/`.malfunction` → immediately once (recreate, wait for IDR); `.badData` → drop to the next keyframe, **no** session restart |
| `RenderError` | `.metalUnavailable`, `.shaderCompilationFailed(String)`, `.pipelineCompileFailed(String)`, `.textureCacheFailed(status: Int32)`, `.textureCreationFailed`, `.drawableUnavailable`, `.commandBufferFailed(code: Int, detail: String)`, `.deviceRemoved`, `.unsupportedPixelFormat(UInt32)`, `.captureFailed(String)`, `.atlasTooLarge(requested: Resolution, max: Int)` | `.metalUnavailable` degraded (fall back to ASBDL) | no retry |
| `StorageError` | `.notWritable(path: String)`, `.corruptDocument(String)`, `.schemaTooNew(found: Int, supported: Int)`, `.missingMigration(from: Int)`, `.notAnObject`, `.diskFull(needBytes: Int64)`, `.atomicReplaceFailed`, `.documentTooLarge(bytes: Int)` | `.schemaTooNew` fatal | user action |
| `CredentialError` | `.keychainStatus(Int32, operation: String)`, `.notFound`, `.duplicate`, `.userCancelledUnlock`, `.keychainLocked`, `.missingEntitlement`, `.decodeFailed` | recoverable | user action |
| `RecordingError` | `.firstSampleNotKeyframe`, `.writerFailed(String)`, `.destinationUnwritable(path: String)`, `.spaceBelowReserve(freeBytes: Int64)`, `.folderUnavailable`, `.formatChangedMidClip` | recoverable | user action |

`LocalizedError` conformance for all of the above is added by an extension in `VigilCore` so the
pure layer stays Foundation-minimal while AppKit alerts still work.

### 3.10 Logging and redaction

```swift
public enum LogLevel: Int, Sendable, Hashable, Codable, Comparable, CaseIterable {
    case debug, info, notice, warning, error, fault
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// The complete, fixed set. Thirteen, from `ARCHITECTURE.md` §8.1. Do not invent strings at call
/// sites and do not add a fourteenth (API_CONTRACT §2 R-15, R-60).
public enum LogCategory: String, Sendable, Hashable, Codable, CaseIterable {
    case app, discovery, rtsp, rtp, bitstream, isapi, transport
    case video, render, core, storage, ui, perf
}

public struct LogEvent: Sendable {
    public var level: LogLevel
    public var category: LogCategory
    public var message: String
    /// MUST be pre-redacted by the caller. `OSLogLogger` interpolates it as `.public`, which is
    /// only correct because of that guarantee.
    public var metadata: [String: String]
    public var file: StaticString
    public var line: UInt
    public init(level: LogLevel, category: LogCategory, message: String,
                metadata: [String: String] = [:], file: StaticString = #fileID, line: UInt = #line)
}

/// The pure layer cannot `import OSLog`, so it logs through this. Every pure type takes
/// `logger: any LoggerProtocol = NullLogger()` in its initialiser. Never a global.
public protocol LoggerProtocol: Sendable {
    /// Cheap gate so callers skip building strings for disabled levels.
    func isEnabled(_ level: LogLevel, _ category: LogCategory) -> Bool
    func log(_ event: LogEvent)
}

public extension LoggerProtocol {
    @inline(__always)
    func debug(_ category: LogCategory, _ message: @autoclosure () -> String,
               _ metadata: @autoclosure () -> [String: String] = [:],
               file: StaticString = #fileID, line: UInt = #line) {
        guard isEnabled(.debug, category) else { return }
        log(LogEvent(level: .debug, category: category, message: message(),
                     metadata: metadata(), file: file, line: line))
    }
    // info, notice, warning, error, fault — identical shape.
}

public struct NullLogger: LoggerProtocol {
    public init() {}
    public func isEnabled(_: LogLevel, _: LogCategory) -> Bool { false }
    public func log(_: LogEvent) {}
}

/// Decorator: at most `limit` events per key per `window`, then a
/// "… suppressed N similar" summary when the window closes. Every repeated-error path
/// (jitter overflow, bad data, gap, malformed packet) MUST be wrapped in it.
public struct RateLimitedLogger: LoggerProtocol {
    public init(wrapping base: any LoggerProtocol, limit: Int = 5,
                window: Duration = .seconds(10), clock: any MonotonicClock)
}
```

```swift
/// The one redaction implementation. `Redaction`, `LogRedaction` and
/// `String.redactingSecrets()` do not exist (API_CONTRACT §2 R-15).
///
/// Every rule below is a hard requirement from `FEATURES.md` §20.6 and `ARCHITECTURE.md` §8.6, and
/// is covered by a fuzz test that seeds secrets in several encodings and asserts none survives any
/// log-formatting path. Redaction is **idempotent** and never lengthens a string past 2×.
public enum Redact {
    /// Passwords, `Authorization` / `WWW-Authenticate` values, Digest `nonce`/`cnonce`/`opaque`/
    /// `response`, `Basic <b64>`, `password=`, `pwd=`, and the ISAPI XML elements
    /// `<password>`, `<macAddress>`, `<serialNumber>`, `<challenge>`, `<salt>`, `<iv>`,
    /// `<securityVer*>`, `<sessionID>`. Elements keep their tags; contents become `<redacted/>`.
    public static func secrets(in text: String) -> String

    /// An RTSP `Session:` id → a stable 4-hex FNV-1a tag: `sess#7f3a`.
    public static func sessionID(_ raw: String) -> String
    /// A serial number → last 4 characters: `••••••••4C21`.
    public static func serial(_ raw: String) -> String
    /// A MAC → last 2 octets at `info` and above; full only at `debug`.
    public static func mac(_ raw: String, level: LogLevel) -> String
    /// Strips userinfo; keeps scheme, host, port and path. Query values for keys matching the
    /// secret patterns are elided.
    public static func url(_ raw: String) -> String
    /// Replaces the user's home directory with `~`. Used in the diagnostics bundle.
    public static func path(_ raw: String) -> String
    /// Stable pseudonym for the diagnostics bundle: `192.168.1.64` → `cam-3f9c`.
    /// Local logs keep real addresses — they are LAN addresses and are needed to diagnose.
    public static func host(_ raw: String, salt: UInt64) -> String
    /// Convenience: `secrets` over the message and every metadata value.
    public static func event(_ event: LogEvent) -> LogEvent
}
```

### 3.11 Bytes and bits

```swift
/// Bounds-checked, big-endian-by-default sequential reader over a byte buffer.
/// Never traps: every accessor throws or returns `nil`. This code parses bytes from the network.
public struct ByteReader: Sendable {
    public private(set) var offset: Int
    public var count: Int { get }
    public var remaining: Int { get }
    public var isAtEnd: Bool { get }

    public init(_ data: Data)
    public init(_ bytes: [UInt8])

    public mutating func u8() throws(BitstreamError) -> UInt8
    public mutating func u16BE() throws(BitstreamError) -> UInt16
    public mutating func u24BE() throws(BitstreamError) -> UInt32
    public mutating func u32BE() throws(BitstreamError) -> UInt32
    public mutating func u64BE() throws(BitstreamError) -> UInt64
    public mutating func u16LE() throws(BitstreamError) -> UInt16
    public mutating func u32LE() throws(BitstreamError) -> UInt32
    /// Returns a **copy**, never a slice: a slice retains the whole parent buffer, and a 12-byte
    /// header slice holding a 1 MB read alive is a real leak.
    public mutating func bytes(_ n: Int) throws(BitstreamError) -> Data
    public mutating func skip(_ n: Int) throws(BitstreamError)
    public mutating func seek(to offset: Int) throws(BitstreamError)
    /// Peeks without advancing. Returns `nil` past the end rather than throwing, because callers
    /// use it for lookahead.
    public func peek(_ n: Int) -> Data?
    public func peekU8(at relativeOffset: Int) -> UInt8?
    /// The remaining bytes, as a copy.
    public mutating func rest() -> Data
    /// Scans forward for a byte pattern. Returns the absolute offset, or `nil`.
    public func firstIndex(of pattern: [UInt8], from: Int) -> Int?
    /// Reads a CRLF- or LF-terminated line as ASCII, up to `limit` bytes. The terminator is
    /// consumed and not returned. Throws `.tooLarge` past `limit`.
    public mutating func line(limit: Int) throws(BitstreamError) -> String
}

/// Growable big-endian-by-default writer. Used by record builders, the SADP/WS-Discovery encoders,
/// the RTCP report builder and `VigilTestKit`'s synthetic generators.
public struct ByteWriter: Sendable {
    public private(set) var data: Data
    public var count: Int { data.count }
    public init(capacity: Int = 0)
    public mutating func u8(_ v: UInt8)
    public mutating func u16BE(_ v: UInt16)
    public mutating func u24BE(_ v: UInt32)
    public mutating func u32BE(_ v: UInt32)
    public mutating func u64BE(_ v: UInt64)
    public mutating func u16LE(_ v: UInt16)
    public mutating func u32LE(_ v: UInt32)
    public mutating func bytes(_ v: some Sequence<UInt8>)
    public mutating func ascii(_ s: String)
    /// Reserves 4 bytes, runs `body`, then back-patches the big-endian length of what `body` wrote.
    /// The only sanctioned way to write a length-prefixed NAL.
    public mutating func lengthPrefixed32(_ body: (inout ByteWriter) -> Void)
    public mutating func align(to multiple: Int, pad: UInt8 = 0)
}
```

```swift
/// MSB-first bit reader. API fixed by `spec-bitstream.md` §7 and reproduced verbatim; the sole
/// consumer is `VigilBitstream.RBSPBitReader`, plus the RTP slice-header probe.
///
/// Exp-Golomb and emulation-prevention removal live in `VigilBitstream`, **not** here.
public struct BitReader: Sendable {
    public let bytes: [UInt8]
    public private(set) var bitOffset: Int
    private let totalBits: Int

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
        self.bitOffset = 0
        self.totalBits = bytes.count * 8
    }

    /// Convenience for callers holding `Data`. Copies once.
    public init(_ data: Data) { self.init([UInt8](data)) }

    @inlinable public var bitsRemaining: Int { totalBits - bitOffset }
    @inlinable public var isByteAligned: Bool { bitOffset & 7 == 0 }
    @inlinable public var bytePosition: Int { bitOffset >> 3 }

    /// Reads `n` in `0...32` bits, MSB first.
    /// - Throws: `BitstreamError.unexpectedEndOfData` past the end.
    /// - Note: `n` outside `0...32` is programmer error against a constant table and is the one
    ///   sanctioned `precondition` in this type; it cannot come from network data.
    public mutating func u(_ n: Int) throws(BitstreamError) -> UInt32 {
        precondition(n >= 0 && n <= 32, "BitReader.u supports 0...32 bits")
        if n == 0 { return 0 }
        guard bitOffset + n <= totalBits else {
            throw BitstreamError.unexpectedEndOfData(atBit: bitOffset)
        }
        var result: UInt32 = 0
        var remaining = n
        while remaining > 0 {
            let byteIndex = bitOffset >> 3
            let bitInByte = bitOffset & 7
            let available = 8 - bitInByte
            let take = min(available, remaining)
            let byte = UInt32(bytes[byteIndex])
            let shifted = byte >> UInt32(available - take)
            let mask: UInt32 = (1 << UInt32(take)) - 1        // take <= 8, no overflow
            result = (result << UInt32(take)) | (shifted & mask)
            bitOffset += take
            remaining -= take
        }
        return result
    }

    /// Reads `n` in `0...64` bits. Required for `general_constraint_indicator_flags` (48 bits).
    public mutating func u64(_ n: Int) throws(BitstreamError) -> UInt64 {
        precondition(n >= 0 && n <= 64)
        if n <= 32 { return UInt64(try u(n)) }
        let high = try u(n - 32)
        let low = try u(32)
        return (UInt64(high) << 32) | UInt64(low)
    }

    @inlinable public mutating func flag() throws(BitstreamError) -> Bool { try u(1) == 1 }

    public mutating func skip(_ n: Int) throws(BitstreamError) {
        guard n >= 0 else { throw BitstreamError.negativeSkip }
        guard bitOffset + n <= totalBits else {
            throw BitstreamError.unexpectedEndOfData(atBit: bitOffset)
        }
        bitOffset += n
    }

    /// Discards bits up to the next byte boundary. Does not validate their value.
    public mutating func alignToByte() { bitOffset = (bitOffset + 7) & ~7 }

    /// Peeks without advancing.
    public func peek(_ n: Int) throws(BitstreamError) -> UInt32 { var c = self; return try c.u(n) }
}

/// MSB-first bit writer. Exists for `VigilTestKit`'s synthetic SPS generator and for record
/// building; it is never on the frame path.
public struct BitWriter: Sendable {
    public private(set) var bytes: [UInt8]
    public var bitCount: Int { get }
    public init(capacity: Int = 0)
    public mutating func u(_ value: UInt32, _ n: Int)
    public mutating func flag(_ value: Bool)
    public mutating func ue(_ value: UInt32)
    public mutating func se(_ value: Int32)
    /// Appends `rbsp_stop_one_bit` then zeros to the byte boundary.
    public mutating func rbspTrailingBits()
    /// Finished bytes, zero-padded to the byte boundary.
    public func finish() -> [UInt8]
}
```

### 3.12 Crypto

All five are pure Swift, streaming, allocation-light, and tested on Linux against published
vectors. **`import CryptoKit` is forbidden in every target** (API_CONTRACT §2 R-16).

```swift
/// RFC 1321. Used **only** where a protocol mandates it: HTTP/RTSP Digest authentication.
/// Never for anything security-bearing of our own choosing.
public struct MD5: Sendable {
    public init()
    public mutating func update(_ bytes: some Sequence<UInt8>)
    public mutating func update(_ data: Data)
    public mutating func update(_ string: String)          // UTF-8
    public mutating func finalize() -> [UInt8]             // 16 bytes
    public static func digest(_ data: Data) -> [UInt8]
    public static func hex(_ data: Data) -> String         // 32 lowercase hex chars
    public static func hex(_ string: String) -> String
}

/// FIPS 180-4. Needed by ONVIF WS-UsernameToken, which is parsed in `VigilDiscovery` — a pure,
/// Linux-tested target.
public struct SHA1: Sendable { /* same shape; 20 bytes */ }

/// FIPS 180-4. Needed by the encrypted config export and by the TOFU SPKI pin shared between
/// `VigilRTSP` and `VigilISAPI` (`Camera.tlsPinSPKI256`), which must be computable in a Linux test.
public struct SHA256: Sendable { /* same shape; 32 bytes */ }

/// Padding-tolerant Base64. Foundation's decoder **rejects** Hikvision's unpadded `sprop-*`
/// values, which is why this exists.
public enum Base64 {
    /// Tolerates: missing `=` padding, embedded whitespace and newlines, and the URL-safe
    /// alphabet (`-`/`_`). Rejects any other non-alphabet byte, and rejects `length % 4 == 1`.
    public static func decode(_ string: String) -> Data?
    /// Splits an SDP `sprop-parameter-sets` value on `,` and decodes each part leniently.
    /// An empty part yields an empty `Data`, which is legal.
    public static func decodeList(_ string: String) -> [Data]?
    public static func encode(_ data: Data, padded: Bool = true) -> String
}

/// IEEE 802.3 CRC-32, for fixture checksums and the diagnostics manifest. Not a hash.
public enum CRC32 {
    public static func compute(_ data: Data) -> UInt32
}
```

### 3.13 Network primitives

```swift
/// Host-order IPv4 address. Deliberately **not** `Network.IPv4Address`, which does not exist on
/// Linux. In any file that also imports `Network`, spell it `VigilProtocols.IPv4Address` — the
/// ambiguity is a compile error at best and a silent wrong type at worst.
public struct IPv4Address: Hashable, Sendable, Codable, Comparable,
                           CustomStringConvertible, LosslessStringConvertible {
    /// Host byte order: `192.168.1.64 == 0xC0A80140`.
    public let rawValue: UInt32
    public init(rawValue: UInt32)
    public init(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8)
    /// Strict dotted-quad parse. Rejects leading zeros (`192.168.01.1`), more than 3 digits per
    /// octet, octets > 255, anything but exactly 4 octets, surrounding whitespace, and non-digits.
    public init?(_ description: String)
    public var octets: (UInt8, UInt8, UInt8, UInt8) { get }
    public var description: String { get }
    @inlinable public var isLoopback: Bool { rawValue >> 24 == 127 }
    @inlinable public var isLinkLocal: Bool { rawValue >> 16 == 0xA9FE }
    @inlinable public var isMulticast: Bool { rawValue >> 28 == 0xE }
    @inlinable public var isUnspecified: Bool { rawValue == 0 }
    @inlinable public var isPrivate: Bool { … }   // 10/8, 172.16/12, 192.168/16
    public static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }
}

/// 48-bit MAC packed into the low 48 bits of a `UInt64`. Canonical form is lowercase,
/// colon-separated.
public struct MACAddress: Hashable, Sendable, Codable,
                          CustomStringConvertible, LosslessStringConvertible {
    public let rawValue: UInt64
    /// `nil` if any bit above 47 is set.
    public init?(rawValue: UInt64)
    /// - Precondition: `bytes.count == 6`.
    public init?(bytes: [UInt8])
    /// Accepts every separator Hikvision, Dahua and Axis firmware emits, case-insensitively:
    /// `c4:2f:90:ab:cd:ef`, `C4-2F-90-AB-CD-EF`, `c42f90abcdef`, `c42f.90ab.cdef`.
    /// Rejects anything that does not reduce to exactly 12 hex nibbles.
    public init?(_ description: String)
    public var bytes: [UInt8] { get }
    public var description: String { get }
    public var oui: UInt32 { get }
    @inlinable public var isLocallyAdministered: Bool { bytes[0] & 0x02 != 0 }
    @inlinable public var isMulticast: Bool { bytes[0] & 0x01 != 0 }
    /// All-zero, broadcast and multicast MACs are never valid identities.
    public var isUsableIdentity: Bool { get }
}

/// An IPv4 network. `IPv4CIDR` does not exist (API_CONTRACT §2 R-18).
public struct IPv4Subnet: Hashable, Sendable, Codable, CustomStringConvertible {
    /// Already masked.
    public let network: IPv4Address
    public let prefixLength: UInt8      // 0...32
    public init(network: IPv4Address, prefixLength: UInt8)
    /// `nil` when `mask` is not a contiguous netmask (e.g. `255.0.255.0`).
    public init?(address: IPv4Address, mask: IPv4Address)
    /// Strict CIDR parse: `192.168.1.0/24`.
    public init?(cidr: String)
    public var mask: IPv4Address { get }
    public var broadcast: IPv4Address { get }
    /// `1 << (32 - prefixLength)`, saturating at `Int.max` for `/0`.
    public var addressCount: Int { get }
    /// Excludes network and broadcast for `prefixLength <= 30`; for `/31` and `/32`, all addresses.
    public var usableHostCount: Int { get }
    @inlinable public func contains(_ a: IPv4Address) -> Bool {
        a.rawValue & mask.rawValue == network.rawValue
    }
    /// Lazy, allocation-free ascending sequence over usable hosts.
    public var hosts: IPv4HostSequence { get }
    public var description: String { "\(network)/\(prefixLength)" }
}

public struct IPv4HostSequence: Sequence, Sendable {
    public func makeIterator() -> AnyIterator<IPv4Address>
}
```

```swift
public enum HostClass: String, Sendable, Hashable, Codable {
    case loopback, privateLAN, linkLocal, multicast, publicInternet, invalid
    /// The only classes Vigil may open a socket to.
    @inlinable public var isEgressPermitted: Bool { self != .publicInternet && self != .invalid }
}

/// The single LAN-only egress gate. Pure, Linux-tested, and consulted **before** any socket is
/// created — in `VigilTransport`, `VigilISAPI` and `VigilDiscovery` alike (API_CONTRACT §2 R-71).
///
/// This is what makes "zero egress with no cameras configured" a code property rather than a
/// packet-capture ritual, and it is why there is no telemetry to opt out of.
public enum HostPolicy {
    /// Accepts an IPv4 literal, a bracketed or bare IPv6 literal, or a DNS name.
    /// A DNS name that is not `*.local` and not an mDNS/Bonjour name classifies as
    /// `.publicInternet` **until resolved**; the caller re-checks the resolved address.
    public static func classify(_ host: String) -> HostClass
    public static func classify(_ address: IPv4Address) -> HostClass
    /// Throws `TransportError.egressBlocked` for a disallowed destination.
    public static func requirePermitted(_ host: String) throws(TransportError)
}
```

```swift
/// Where a device's ISAPI control plane lives.
public struct ISAPIEndpoint: Sendable, Hashable, Codable {
    /// IPv4 literal, IPv6 literal **without** brackets, or a DNS name.
    public var host: String
    public var port: Int                 // 80 http, 443 https
    public var useTLS: Bool
    /// Almost always `/ISAPI`. Devices behind a reverse proxy may need `/cam1/ISAPI`; the field
    /// exists so nothing string-concatenates blindly.
    public var pathPrefix: String
    public init(host: String, port: Int = 80, useTLS: Bool = false, pathPrefix: String = "/ISAPI")
    /// `resource` is written **without** the prefix, e.g. `/System/deviceInfo`. Query items are
    /// percent-encoded per RFC 3986 with `+` encoded as `%2B` — Hikvision does not decode `+` as
    /// a space. IPv6 hosts are bracketed exactly once here; `host` stays unbracketed.
    public func url(_ resource: String, query: [URLQueryItem] = []) throws(ISAPIError) -> URL
}

/// Where a stream lives. Credentials are **never** part of an RTSP URL.
public struct RTSPEndpoint: Sendable, Hashable, Codable {
    public var host: String
    public var port: Int                 // 554, or 322 for tcpTLS
    public var path: String              // absolute, e.g. "/Streaming/Channels/101"
    public var transport: RTSPTransportKind
    public init(host: String, port: Int = 554, path: String,
                transport: RTSPTransportKind = .tcpInterleaved)
}
```

```swift
/// Case-insensitive ordered HTTP header container.
public struct HTTPHeaders: Sendable, Hashable, Codable, Sequence {
    public init()
    public init(_ pairs: [(String, String)])
    public subscript(_ name: String) -> String? { get set }   // first value, case-insensitive
    public func all(_ name: String) -> [String]
    public mutating func append(_ name: String, _ value: String)
    public mutating func remove(_ name: String)
    public func makeIterator() -> IndexingIterator<[(name: String, value: String)]>
}

/// Per-device request lane. Hikvision devices run a small HTTP worker pool; more than a handful of
/// concurrent requests reliably produces 503 `deviceBusy` and, on 5.4.x firmware, can stall the
/// RTSP service for seconds. Separate lanes stop a snapshot burst from starving PTZ.
public enum HTTPLane: String, Sendable, Hashable, Codable, CaseIterable {
    case control, snapshot, stream, audio
}

public struct HTTPRequest: Sendable {
    public var url: URL
    public var method: String
    public var headers: HTTPHeaders
    public var body: Data?
    public var timeout: Duration
    public var lane: HTTPLane
    public init(url: URL, method: String = "GET", headers: HTTPHeaders = .init(),
                body: Data? = nil, timeout: Duration = .seconds(8), lane: HTTPLane = .control)
}

public struct HTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: HTTPHeaders
    public let body: Data
    public var contentType: String? { headers["Content-Type"] }
}

/// The injection seam that keeps `VigilISAPI` tests off the network, and lets `VigilDiscovery`'s
/// ONVIF `GetStreamUri` fallback work without importing `VigilISAPI`.
/// `ISAPIHTTPTransporting` does not exist (API_CONTRACT §2 R-17).
public protocol HTTPTransporting: Sendable {
    func perform(_ request: HTTPRequest) async throws(ISAPIError) -> HTTPResponse
    /// Long-lived byte stream (`alertStream`, two-way audio download). Back-pressured:
    /// `.bufferingNewest(64)`, and `.terminated`/`.dropped` cancels the underlying task.
    func stream(_ request: HTTPRequest) async throws(ISAPIError)
        -> (status: Int, headers: HTTPHeaders, bytes: AsyncThrowingStream<Data, any Error>)
    /// Chunked upload with a caller-driven body (two-way audio push).
    func upload(_ request: HTTPRequest) async throws(ISAPIError) -> any HTTPUploadHandle
}

public protocol HTTPUploadHandle: Sendable {
    func send(_ chunk: Data) async throws(ISAPIError)
    func finish() async
    var isOpen: Bool { get async }
}
```

```swift
/// A username and a password, in memory only.
///
/// **Not `Codable`. Deliberately.** `Camera` has no password property to accidentally encode —
/// enforced by the type, not by discipline, and asserted by a test that reflects over
/// `Camera.CodingKeys`. `ISAPICredential` does not exist (API_CONTRACT §2 R-14).
public struct Credential: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    public let ref: CredentialRef
    public let account: String
    public let secret: String
    public init(ref: CredentialRef = .init(), account: String, secret: String)
    public var description: String { "Credential(account: \(account), secret: ****)" }
    public var debugDescription: String { description }
}

/// Opaque, stable handle to a Keychain item. This is what appears in `library.json`; it reveals
/// nothing, not even the username.
public struct CredentialRef: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID())
    public var description: String { rawValue.uuidString }
    /// The `kSecAttrPath` value that locates the item independently of host, port and account,
    /// so a camera can move without orphaning its password.
    public var keychainPath: String { "/vigil/credential/\(rawValue.uuidString)" }
}
```

### 3.14 Identifiers

```swift
/// Every Vigil identifier encodes as a **bare JSON string**, never as `{"rawValue": …}`.
/// `CameraID`, `GroupID`, `LayoutID`, `EventID`, `ClipID` and `BookmarkID` are all this shape.
public struct CameraID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID())
    public var description: String { rawValue.uuidString }
    /// First 8 characters. The form that appears in log lines and queue names.
    public var short: String { String(description.prefix(8)) }
    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer(); try c.encode(rawValue)
    }
}

/// `NSWindow.windowNumber`, wrapped so `VigilCore` can reason about occlusion without AppKit.
public struct WindowID: Hashable, Sendable, Codable { public let rawValue: Int }
```

```swift
/// 1-based **video input** channel. Cameras are always 1; an NVR has one per input.
/// Used by `/Image/channels/{ch}`, `/PTZCtrl/channels/{ch}`,
/// `/System/Video/inputs/channels/{ch}`, motion configuration and `EventNotificationAlert`.
public struct ChannelID: Sendable, Hashable, Codable, ExpressibleByIntegerLiteral,
                         CustomStringConvertible, Comparable {
    public let value: Int
    public init(_ value: Int)
    public init(integerLiteral value: Int)
    public var description: String { String(value) }
    public static func < (a: Self, b: Self) -> Bool { a.value < b.value }
}

/// `channel * 100 + quality.rawValue`. Used by `/Streaming/channels/{id}`,
/// `/Streaming/channels/{id}/picture` and the RTSP path. **Not interchangeable with `ChannelID`.**
public struct StreamingChannelID: Sendable, Hashable, Codable, CustomStringConvertible, Comparable {
    public let value: Int
    public init(channel: ChannelID, quality: StreamQuality) {
        value = channel.value * 100 + quality.rawValue
    }
    /// Rejects values below 101 and quality digits outside `1...3`.
    public init?(rawValue: Int)
    public var channel: ChannelID { ChannelID(value / 100) }
    public var quality: StreamQuality { StreamQuality(rawValue: value % 100) ?? .main }
    public var description: String { String(value) }
    public static func < (a: Self, b: Self) -> Bool { a.value < b.value }
}

/// The same numeric space as `StreamingChannelID`, but a **distinct type**: tracks are a recording
/// concept and the two are not interchangeable across firmware. Used by
/// `/ContentMgmt/record/tracks`, `CMSearchDescription.trackIDList` and `/Streaming/tracks/{id}`.
public struct TrackID: Sendable, Hashable, Codable, CustomStringConvertible, Comparable {
    public let value: Int
    public init(_ value: Int)
    public var description: String { String(value) }
    public static func < (a: Self, b: Self) -> Bool { a.value < b.value }
}
```

```swift
/// The **only** sanctioned firmware-workaround channel (API_CONTRACT §2 R-27a).
///
/// Detected by the protocol modules, persisted by `VigilCore` on the camera record, and consulted
/// in **exactly four places**: the path builder, the body builder, the parser configuration, and
/// the request gate. A firmware `if` anywhere else — in a decoder, in a view — is a
/// review-blocking defect.
public struct DeviceQuirks: Sendable, Hashable, Codable {
    public var schemaVersion: Int = 1

    // Protocol shape
    public var digestNoQOP: Bool = false
    public var requiresBasicAuth: Bool = false
    public var closesOnGetParameter: Bool = false
    public var interleavedOnly: Bool = false
    public var noMulticast: Bool = false
    public var unreliableMarkerBit: Bool = false
    public var sdpMissingParameterSets: Bool = false
    public var rtspPathLegacyH264: Bool = false
    public var streamingChannelIDIsSingleDigit: Bool = false

    // ISAPI shape
    public var requiresXMLDeclarationInBody: Bool = true
    public var sharpnessElementIsCapitalized: Bool = true
    public var snapshotIgnoresResolutionQuery: Bool = false
    public var jpegSnapshotNeedsChannelSuffix: Bool = false
    public var channelListPagedAt64: Bool = false
    public var inputProxyStatusListUnsupported: Bool = false
    public var recordTypeFilterUnsupported: Bool = false
    public var playbackTimesAreDeviceLocal: Bool = false
    public var dailyDistributionPath: String? = nil
    public var eventSchedulePath: String? = nil
    public var alertStreamBoundaryFromSniff: Bool = false
    public var alertStreamNoTerminalBoundary: Bool = false
    public var alertStreamDropsWithoutTraffic: Bool = false

    // Behaviour
    public var momentaryUnsupported: Bool = false
    public var ptzContinuousNeedsStopCommand: Bool = false
    /// `nil` until §13.5 calibration determines it.
    public var ptz3DOriginIsTopLeft: Bool? = nil
    public var motionRegionYAxisInverted: Bool = false
    public var reportsWrongFPSInISAPI: Bool = false
    /// Overrides `maxConcurrentControlRequests`; 1 for firmware that rejects concurrent ISAPI.
    public var maxConcurrentRequestsOverride: Int? = nil

    public init()
    /// Quirks are **sticky**: never auto-cleared. Reset only by Inspector → Info → "Re-probe device".
    public mutating func merge(_ observed: DeviceQuirks)
}
```

```swift
public enum EventKind: String, Sendable, Hashable, Codable, CaseIterable {
    case motion, lineCrossing, intrusion, regionEntrance, regionExiting, faceDetection
    case tamper, io, videoLoss, diskFull, diskError, sceneChange, audioException
    case unattendedBaggage, attendedBaggage, peopleCounting
    /// Synthesised by Vigil, not by a device.
    case streamLost, authFailure, eventStorm
    case unknown

    /// Lenient mapping from the wire `eventType` string. Case-insensitive; never throws.
    public init(isapiEventType: String)
    /// Localisation key, e.g. `event.kind.motion`.
    public var displayNameKey: String { "event.kind.\(rawValue)" }
    public var defaultSeverity: EventSeverity { … }
}

public enum EventSeverity: Int, Sendable, Hashable, Codable, Comparable {
    case info = 0, notice = 1, warning = 2, alarm = 3
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}
```

### 3.15 Shared concurrency and buffer utilities

```swift
/// Multi-consumer fan-out over one bounded source. **Every** `AsyncStream` accessor in Vigil is a
/// factory over one of these; a stored `AsyncStream` property has exactly one consumer and the
/// second caller silently gets nothing (API_CONTRACT §2 R-27, R-65).
public actor Broadcaster<Element: Sendable> {
    public init(replaysLatest: Bool = false,
                bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy = .bufferingNewest(64))
    /// A fresh stream, registered as a new consumer. `onTermination` deregisters.
    public nonisolated func stream() -> AsyncStream<Element>
    public func yield(_ element: Element)
    public func finish()
    public var consumerCount: Int { get }
}

/// FIFO, priority-aware, cancellation-safe permit gate. Never `DispatchSemaphore`, which blocks a
/// cooperative thread and deadlocks the pool under Swift 6.
public actor ConcurrencyLimiter {
    public init(limit: Int, name: String)
    public func withPermit<T: Sendable>(priority: StreamPriority = .visibleSmall,
                                        _ body: @Sendable () async throws -> T) async rethrows -> T
    public func setLimit(_ limit: Int)
    public var inFlight: Int { get }
    public var queueDepth: Int { get }
}

/// Fixed-capacity ring. Preallocated at construction; O(1) append; **zero allocation** afterwards.
/// Used by `HealthRing`, the RTP reorder buffer, `FrameQueue` and the statistics reservoirs.
public struct RingBuffer<Element>: Sendable where Element: Sendable {
    public let capacity: Int
    public private(set) var count: Int
    public init(capacity: Int, repeating: Element)
    /// Overwrites the oldest element when full. Returns the evicted element, if any.
    @discardableResult public mutating func append(_ element: Element) -> Element?
    public mutating func removeFirst() -> Element?
    public func ordered() -> [Element]                     // oldest → newest
    public func suffix(_ n: Int) -> [Element]
    public subscript(_ i: Int) -> Element { get }          // 0 == oldest
    public mutating func removeAll()
}
```

## 4. Per-module public API surface

Declarations without bodies, for all twelve targets plus `VigilTestKit`. **This is the contract:
nothing may be added later without a note in this section and a line in the commit message.**
A type not named here does not exist — do not invent one, raise it.

Everything in §3 is available to every module. Nothing in §4 may be redeclared in another module.

### 4.1 `VigilProtocols`

Exactly §3, nothing more. It has no logic beyond the crypto, the readers/writers, `TilePolicy`,
`HostPolicy`, `Redact`, `Broadcaster`, `ConcurrencyLimiter` and `RingBuffer`.

### 4.2 `VigilBitstream` — H.264/H.265 syntax

Depends on `VigilProtocols`. Zero classes, zero actors, zero shared state, 100 % value types.

```swift
// NAL tables and headers
public enum H264NALType: UInt8, Sendable, Hashable, CaseIterable { … }   // 1 slice … 5 IDR … 7 SPS, 8 PPS
public enum H265NALType: UInt8, Sendable, Hashable, CaseIterable { … }   // 16–23 IRAP, 32 VPS, 33 SPS, 34 PPS
public struct NALUnitRef: Sendable, Hashable {
    public let range: Range<Int>      // into the source buffer, NAL header included
    public let typeCode: UInt8
    public let layerID: UInt8         // H.265; 0 for H.264
    public let temporalID: UInt8      // H.265; 0 for H.264
}
public enum NALHeader {
    public static func decodeH264(_ b0: UInt8) throws(BitstreamError) -> (type: UInt8, refIdc: UInt8)
    public static func decodeHEVC(_ b0: UInt8, _ b1: UInt8)
        throws(BitstreamError) -> (type: UInt8, layerID: UInt8, temporalID: UInt8)
    public static func encodeHEVC(type: UInt8, layerID: UInt8, temporalID: UInt8) -> (UInt8, UInt8)
    @inlinable public static func typeCode(_ nal: UnsafeRawBufferPointer,
                                           codec: VideoCodec) throws(BitstreamError) -> UInt8
}

// Annex-B ↔ length-prefixed. Annex-B appears at exactly two edges: reading a raw .h264/.h265
// fixture, and writing a debug dump. NEVER on the live path.
public enum AnnexB {
    public static func findStartCode(in buffer: UnsafeRawBufferPointer,
                                     from: Int) -> (index: Int, length: Int)?
    public static func enumerateNALUnits(in buffer: UnsafeRawBufferPointer,
                                         _ body: (Range<Int>) throws -> Void) rethrows
    public static func nalRanges(_ bytes: [UInt8]) -> [Range<Int>]
    public static func toLengthPrefixed(_ annexB: [UInt8]) -> Data
    public static func fromLengthPrefixed(_ prefixed: Data,
                                          startCodeLength: Int = 4) throws(BitstreamError) -> [UInt8]
}
public enum LengthPrefixed {
    public static func enumerate(_ bytes: UnsafeRawBufferPointer, codec: VideoCodec,
                                 _ body: (Range<Int>, UInt8) throws -> Void) throws(BitstreamError)
    public static func validate(_ bytes: UnsafeRawBufferPointer) -> Bool
    /// Writes `nal` prefixed by its 4-byte big-endian length. **The one function `VigilRTP` uses.**
    @inlinable public static func append(nal: UnsafeRawBufferPointer, to out: inout ByteWriter)
}

// RBSP
public enum RBSP {
    public static func unescape(_ nal: UnsafeRawBufferPointer,
                                skippingHeaderBytes: Int) throws(BitstreamError) -> [UInt8]
    public static func escape(_ rbsp: [UInt8]) -> [UInt8]
    public static func escapeByteCount(_ nal: UnsafeRawBufferPointer, skippingHeaderBytes: Int) -> Int
}
/// Adds emulation-prevention removal, Exp-Golomb (`ue`, `se`) and `moreRBSPData()` over
/// `VigilProtocols.BitReader`. Exp-Golomb lives HERE, not in `VigilProtocols`.
public struct RBSPBitReader: Sendable { … }

// Parsers
public enum H264Parser {
    public static func parseSPS(_ nal: UnsafeRawBufferPointer) throws(BitstreamError) -> H264SPS
    public static func parsePPS(_ nal: UnsafeRawBufferPointer) throws(BitstreamError) -> H264PPS
    public static func parseSPS(base64: String) throws(BitstreamError) -> H264SPS
    /// Splits an SDP `sprop-parameter-sets` value (`<b64>,<b64>`) into NAL units, leniently.
    public static func parseSpropParameterSets(_ value: String) throws(BitstreamError) -> [Data]
}
public enum H265Parser {
    public static func parseVPS(_ nal: UnsafeRawBufferPointer) throws(BitstreamError) -> H265VPS
    public static func parseSPS(_ nal: UnsafeRawBufferPointer) throws(BitstreamError) -> H265SPS
    public static func parsePPS(_ nal: UnsafeRawBufferPointer) throws(BitstreamError) -> H265PPS
    public static func parseSPS(base64: String) throws(BitstreamError) -> H265SPS
}
public struct ProfileTierLevel: Sendable, Hashable, Codable { … }
public struct H264SPS: Sendable, Hashable, Codable { … }
public struct H264PPS: Sendable, Hashable, Codable { … }
public struct H265VPS: Sendable, Hashable, Codable { … }
public struct H265SPS: Sendable, Hashable, Codable { … }
public struct H265PPS: Sendable, Hashable, Codable { … }

/// The bridge to §3.6. `VigilBitstream` publishes `VideoFormatInfo`, NEVER a
/// `CMVideoFormatDescription`. Report cropped display size, allocate from coded size.
public extension VideoFormatInfo {
    init(_ sps: H264SPS)
    init(_ sps: H265SPS, vps: H265VPS?, pps: H265PPS?)
}

// Records. `lengthSizeMinusOne` is ALWAYS 3.
public struct AVCDecoderConfigurationRecord: Sendable, Hashable {
    public var avcProfileIndication: UInt8
    public var profileCompatibility: UInt8
    public var avcLevelIndication: UInt8
    public var lengthSizeMinusOne: UInt8            // always 3
    public var sequenceParameterSets: [Data]
    public var pictureParameterSets: [Data]
    public var chromaFormat: UInt8?
    public var bitDepthLumaMinus8: UInt8?
    public var bitDepthChromaMinus8: UInt8?
    public var sequenceParameterSetExt: [Data]
    public init(sps: [Data], pps: [Data], spsExt: [Data] = []) throws(BitstreamError)
    public init(parsing data: Data) throws(BitstreamError)
    public func serialized() -> Data
    public var parameterSets: ParameterSets { get }
}
public struct HEVCDecoderConfigurationRecord: Sendable, Hashable {
    public struct NALArray: Sendable, Hashable {
        public var arrayCompleteness: Bool
        public var nalUnitType: UInt8
        public var nalUnits: [Data]
    }
    public var ptl: ProfileTierLevel
    public var minSpatialSegmentationIDC: UInt16
    public var parallelismType: UInt8
    public var chromaFormat: UInt8
    public var bitDepthLumaMinus8: UInt8
    public var bitDepthChromaMinus8: UInt8
    public var avgFrameRate: UInt16                 // fps × 256
    public var constantFrameRate: UInt8
    public var numTemporalLayers: UInt8
    public var temporalIDNested: Bool
    public var lengthSizeMinusOne: UInt8            // always 3
    /// Ascending `nalUnitType`: 32 VPS, 33 SPS, 34 PPS, optionally 39 SEI.
    public var arrays: [NALArray]
    public init(vps: [Data], sps: [Data], pps: [Data], sei: [Data] = [],
                parsedSPS: H265SPS, parsedPPS: H265PPS?) throws(BitstreamError)
    public init(parsing data: Data) throws(BitstreamError)
    public func serialized() -> Data
    public var parameterSets: ParameterSets { get }
}

// SEI
public enum SEI {
    public static func enumerate(nalUnit: UnsafeRawBufferPointer, codec: VideoCodec,
                                 _ body: (Int, ArraySlice<UInt8>) throws -> Void) throws(BitstreamError)
    public static func parseRecoveryPoint(_ payload: ArraySlice<UInt8>,
                                          codec: VideoCodec) throws(BitstreamError) -> RecoveryPoint
    public static func parsePictureTiming(_ payload: ArraySlice<UInt8>,
                                          sps: H264SPS) throws(BitstreamError) -> PictureTiming
}
public struct RecoveryPoint: Sendable, Hashable { … }
public struct PictureTiming: Sendable, Hashable { public var picStruct: UInt8 }

// Classification and gating — the surfaces VigilRTP depends on (R-01).
public enum SliceHeader {
    /// H.264 `first_mb_in_slice == 0`, H.265 `first_slice_segment_in_pic_flag`.
    /// **The authoritative access-unit boundary predicate.** Never duplicate it.
    @inlinable public static func isFirstSliceOfPicture(nalUnit: UnsafeRawBufferPointer,
                                                        codec: VideoCodec) -> Bool
    /// H.264 `slice_type`, when cheaply available. Advisory only.
    public static func sliceType(nalUnit: UnsafeRawBufferPointer, codec: VideoCodec) -> UInt8?
}
public struct AccessUnitSummary: Sendable { … }
/// Starts **closed** on every PLAY, reconnect and decoder reset. `VigilCore` acts on
/// `shouldRequestKeyframe`; `VigilUI` renders "Connecting", never black, while it is closed.
/// For H.265, RASL pictures after a CRA start are dropped.
public struct IRAPGate: Sendable {
    public private(set) var isOpen: Bool
    public private(set) var shouldRequestKeyframe: Bool
    public mutating func reset()
    public mutating func admit(_ summary: AccessUnitSummary) -> Bool
}
/// Merge-not-replace parameter-set store with format-change detection. A `struct`, owned by
/// whichever actor drives the stream (API_CONTRACT §2 R-67).
public struct ParameterSetStore: Sendable {
    public private(set) var sets: ParameterSets?
    public private(set) var format: VideoFormatInfo?
    public private(set) var generation: UInt32
    public mutating func ingest(_ incoming: ParameterSets) -> ParameterSetChange
    public mutating func reset()
}
public enum ParameterSetChange: Sendable, Hashable {
    case unchanged
    case firstSet
    /// Same decoder can be reused; rebuild only the format description and bump `generation`.
    case compatible(previous: VideoFormatInfo?)
    /// Codec, coded size, chroma format or luma bit depth changed. Drain and recreate.
    case incompatible(previous: VideoFormatInfo?)
}
public enum SampleAspectRatio { public static let table: [UInt8: (Int, Int)] }
```

### 4.3 `VigilRTSP` — messages, auth, SDP, session machine

Depends on `VigilProtocols`. Pure `struct`s; no sockets, no timers, no `Task`.
**Never builds a `MediaTimestamp`** and never depends on `VigilRTP`.

```swift
public enum RTSPMethod: String, Sendable, Hashable, CaseIterable { … }      // 11 methods
public struct RTSPStatus: RawRepresentable, Hashable, Sendable { … }        // 30 named codes
public struct RTSPHeaders: Sendable, Equatable, Sequence { … }              // ordered, ASCII-folded
public struct RTSPRequest: Sendable, Equatable { … }
public struct RTSPResponse: Sendable, Equatable { … }
public enum RTSPIncoming: Sendable, Equatable {
    case response(RTSPResponse), request(RTSPRequest)
    case interleaved(channel: UInt8, payload: Data)
}

/// Hand-written, because `URLComponents` mangles `trackID=1` path segments and rejects some
/// Hikvision query forms. Credentials NEVER appear in `requestLineForm` or `description`.
public struct RTSPURL: Sendable, Hashable, CustomStringConvertible {
    public var scheme: String            // "rtsp" | "rtsps"
    public var host: String
    public var port: Int                 // 554, or 322 for rtsps
    public var path: String
    public var query: String?
    public init?(string: String)
    public init(endpoint: RTSPEndpoint)
    public var requestLineForm: String { get }
    public var description: String { get }
    public func appendingControl(_ control: String) -> RTSPURL
}

public struct RTSPWireDecoder: Sendable {
    public struct Limits: Sendable, Hashable {
        public var maxStartLine = 4_096
        public var maxHeaderLine = 8_192
        public var maxHeaderBlock = 32_768
        public var maxHeaderFields = 128
        public var maxBody = 262_144
        public var receiveHighWater = 2 << 20
        public var maxResyncScan = 131_072
        public var maxResyncsPerMinute = 3
    }
    public init(limits: Limits = .init())
    /// Incremental. Never throws; framing failures surface as `.malformed` events the caller maps.
    public mutating func ingest(_ bytes: some Collection<UInt8>) -> [RTSPIncoming]
    public private(set) var statistics: DecoderStatistics
}
public struct DecoderStatistics: Sendable, Equatable { … }

public struct RTSPChallenge: Sendable, Hashable {
    public var scheme: String            // "Digest" | "Basic"
    public var realm: String
    public var nonce: String?
    public var opaque: String?
    public var qop: [String]             // empty ⇒ RFC 2069 no-qop, the primary Hikvision path
    public var algorithm: String         // "MD5" | "MD5-sess"
    public var stale: Bool
    /// Tolerates unquoted values, a comma inside a quoted `realm`, and two challenges in one header.
    public static func parseAll(_ headerValue: String) -> [RTSPChallenge]
}

/// Basic + Digest state. `nc` is 8 lowercase hex from `00000001`, per (realm, nonce), never reused;
/// a nonce change resets it. `cnonce` is 16 hex chars from the injected `RandomSource`.
/// **The Digest URI must equal the request-line URI byte for byte.**
public struct RTSPAuthenticator: Sendable {
    public init(credential: Credential?, random: any RandomSource)
    public mutating func absorb(_ challenges: [RTSPChallenge])
    public mutating func authorization(for method: RTSPMethod,
                                       uri: String) -> String?
    /// Consecutive credentialed 401s. **Two is terminal** (API_CONTRACT §2 R-25).
    public private(set) var failureCount: Int
    public mutating func reset()
}

// SDP
public struct SDPDocument: Sendable, Equatable { … }
public struct SDPMediaDescription: Sendable, Equatable {
    public enum Kind: String, Sendable { case video, audio, application }
    public var kind: Kind
    public var payloadType: UInt8
    public var encodingName: String
    public var clockRate: Int32
    public var channels: Int32?
    /// **Keys are lower-cased**, values verbatim. Contract for `VigilRTP` (R-01 companion).
    public var fmtp: [String: String]
    public var control: String?
    public var parameterSets: ParameterSets?     // base64-decoded sprop-*; may legitimately be empty
    public var bandwidthKbps: Int?
}
public struct SDPParser: Sendable {
    /// Lenient: unknown attributes are ignored, bare LF is accepted, a trailing NUL is stripped,
    /// non-UTF-8 `s=` is replaced. Never throws on an unknown line.
    public static func parse(_ body: Data) throws(RTSPError) -> SDPDocument
}
/// Precedence: `Content-Base` → `Content-Location` → request URI, then **append-with-slash merge**
/// (not RFC 3986 merge), carrying the base query onto track URIs.
public enum ControlURLResolver {
    public static func resolve(control: String?, contentBase: String?,
                               contentLocation: String?, requestURI: RTSPURL) -> String
}

// Headers
public struct TransportHeader: Sendable, Equatable { … }
public struct SessionHeader: Sendable, Equatable { public var id: String; public var timeout: Duration }
public struct RTPInfoHeader: Sendable, Equatable { … }
public struct RTSPRange: Sendable, Equatable { … }       // npt / clock / smpte

// Session machine — the complete surface.
public struct RTSPSessionConfig: Sendable { … }          // §2 R-25: maxAuthAttemptsPerRequest = 2
public enum RTSPTimerID: Hashable, Sendable {
    case keepalive, requestTimeout(cseq: UInt32), firstMediaTimeout, dataIdle
    case sessionExpiry, teardownGrace
}
public enum RTSPCloseReason: Sendable, Equatable { case normal, error, redirect, ladderAdvance }
public struct RTSPTrack: Sendable, Equatable, Identifiable { … }
/// Raw seed values only. `VigilRTSP` performs **no** modular arithmetic on RTP timestamps and
/// never compares `rtptime` across tracks (API_CONTRACT §2 R-26).
public struct RTSPTrackTiming: Sendable, Equatable {
    public var trackID: Int
    public var clockRate: UInt32
    public var initialSequence: UInt16?
    public var initialRTPTimestamp: UInt32?
    /// Absolute media time of `initialRTPTimestamp`; recorded playback only.
    public var absoluteStart: Date?
    public var scale: Double
    public var isRateControlDisabled: Bool
    public var playResponseInstant: MediaInstant
}
public struct RTSPSessionDescription: Sendable, Equatable { … }
public enum RTSPSessionState: Sendable, Equatable { … }   // 13 states
public enum RTSPCommand: Sendable, Equatable { … }        // incl. `.describeOnly` for the R1.2 ladder
public enum RTSPLogEvent: Sendable, Equatable { … }       // 22 cases
public enum RTSPAction: Sendable, Equatable {
    case send(Data)                                       // ONE atomic write
    case sendInterleaved(channel: UInt8, payload: Data)   // ONE atomic write
    case setTimer(RTSPTimerID, deadline: MediaInstant)
    case cancelTimer(RTSPTimerID)
    case emitTrack(RTSPTrack)
    case emitTiming(RTSPTrackTiming)
    case emitMedia(channel: UInt8, payload: Data)
    case ready(RTSPSessionDescription)
    case stateChanged(RTSPSessionState)
    case log(RTSPLogEvent)
    case setReadBackpressure(Bool)
    case fail(RTSPError)
    case closeTransport(reason: RTSPCloseReason)
    case reconnect(to: RTSPURL, resetAuthState: Bool)
}

public struct RTSPSessionMachine: Sendable {
    public init(config: RTSPSessionConfig, credential: Credential?,
                random: any RandomSource, now: MediaInstant)
    public mutating func ingest(_ bytes: some Collection<UInt8>, now: MediaInstant) -> [RTSPAction]
    public mutating func step(now: MediaInstant) -> [RTSPAction]
    public mutating func timerFired(_ id: RTSPTimerID, now: MediaInstant) -> [RTSPAction]
    public mutating func handle(_ command: RTSPCommand, now: MediaInstant) -> [RTSPAction]
    public mutating func transportReady(isTLS: Bool, now: MediaInstant) -> [RTSPAction]
    public mutating func connectionClosed(error: String?, now: MediaInstant) -> [RTSPAction]
    public var state: RTSPSessionState { get }
    public var tracks: [RTSPTrack] { get }
    public var sessionID: String? { get }
    public var negotiatedTransport: RTSPTransportKind { get }
    public var statistics: RTSPSessionStatistics { get }
    public var interleavedChannels: Set<UInt8> { get }
}
public struct RTSPSessionStatistics: Sendable, Equatable { … }
```

**Ordering guarantees the driver may rely on** (normative):
`.stateChanged` precedes anything caused by the new state · every `.emitTrack` precedes that
track's `.emitTiming`, which precedes any `.emitMedia` on its channels (media arriving before the
PLAY response is buffered, bounded to **64 frames**, then oldest dropped with a log) · `.ready`
fires exactly once per successful PLAY, after all track/timing actions · `.fail` is the **last**
action ever produced; every later call returns `[]` except one `handle(.teardown)` · `.setTimer`
replaces any timer with the same id · concatenated `.send` payloads are exactly the client byte
stream · `.emitMedia` payloads are in arrival order with no coalescing and no cross-channel
reordering.

**Constants** (normative): default port 554 / rtsps **322** · interleave magic `0x24` · first
`CSeq` 1 · `nc` starts `00000001` · `cnonce` 16 hex chars · **max auth attempts 2** · session
timeout default 60 s clamped 10…600 · keepalive `clamp(timeout/3, 5 s, 20 s)` via `GET_PARAMETER`
(`OPTIONS` when `closesOnGetParameter`) · request timeout 5 s, `TEARDOWN` 2 s · first-media 5 s ·
data-idle 8 s · UDP first-packet 3 s · UDP client ports 51000–51998, even · max redirects 3 ·
command queue 8 · pre-PLAY media buffer 64 · playback prefetch 120/60 · `Scale` serialised to 3
decimals · supported scales ±1, ±2, ±4, ±8, 16, 0.5, 0.25.

### 4.4 `VigilRTP` — depacketization, jitter, RTCP, statistics

Depends on `VigilProtocols` **and `VigilBitstream`** (R-01). Never depends on `VigilRTSP`.

```swift
public struct RTPPacket: Sendable, Equatable {
    public var version: UInt8, hasPadding: Bool, hasExtension: Bool, csrcCount: UInt8
    public var marker: Bool, payloadType: UInt8
    public var sequenceNumber: UInt16, timestamp: UInt32, ssrc: UInt32
    public var csrc: [UInt32]
    public var extensionProfile: UInt16?, extensionData: Data?
    public var payload: Data
    public static func parse(_ bytes: Data) throws(RTPError) -> RTPPacket
}

/// `VigilRTP`'s own input struct. The 6-line adapter from `SDPMediaDescription` lives in
/// `VigilTransport` (macOS) and in the fixture (Linux) — never here, because `VigilRTP` must be
/// usable for UDP, file replay and unit fixtures with no session at all.
public struct RTPTrackFormat: Sendable, Hashable {
    public var payloadType: UInt8
    public var encodingName: String
    public var clockRate: Int32
    public var channels: Int32?
    public var fmtp: [String: String]            // lower-cased keys
    public var parameterSets: ParameterSets?
    public init(payloadType: UInt8, encodingName: String, clockRate: Int32,
                channels: Int32?, fmtp: [String: String],
                parameterSets: ParameterSets?) throws(RTPError)
    public var codec: MediaCodec { get }
}

public protocol Depacketizer: Sendable {
    var codec: MediaCodec { get }
    var clockRate: Int32 { get }
    /// Never throws: malformed input is counted and reported through `output.events`, because one
    /// bad packet must never tear down a stream.
    mutating func push(_ packet: RTPPacket, at now: MediaInstant) -> DepacketizerOutput
    mutating func flush(at now: MediaInstant) -> [EncodedFrame]
    /// Full reset: SSRC change, seek, reconnect. Keeps the initial parameter sets.
    mutating func reset()
}
public struct DepacketizerOutput: Sendable {
    public var frames: [EncodedFrame]
    public var events: [DepacketizerEvent]
    public var isEmpty: Bool { get }
    /// A `static let`, so the ~97 % of packets that are mid-frame fragments allocate nothing.
    public static let none = DepacketizerOutput()
}

public enum DepacketizerEvent: Sendable, Equatable {
    case packetLoss(range: ClosedRange<UInt16>, count: Int)
    case keyframeNeeded(reason: KeyframeReason)
    case awaitingKeyframe(droppedAccessUnits: Int)
    case accessUnitDropped(reason: DropReason)
    case parameterSetsChanged(ParameterSets)
    case audioConfigChanged(AudioFormatInfo)
    case ssrcChanged(old: UInt32, new: UInt32)
    case timestampDiscontinuity(seconds: Double)
    case senderReport(SenderReport)
    case bye(reason: String?)
    case endOfStream
    case boundaryPolicyChanged(slice: SliceProfile, marker: MarkerTrust)
    case jitterPolicyEscalated(ReorderBuffer.Mode)
    case malformed(MalformedReason)
    case unsupported(UnsupportedFeature)
}
public enum KeyframeReason: String, Sendable, Equatable, Codable {
    case streamStart, packetLoss, corruptAccessUnit, decoderReset, formatChange
    case recordingStart, snapshotRequest, qualitySwitch, userRequest
}
public enum DropReason: Sendable, Equatable { … }
public enum MalformedReason: Sendable, Equatable { … }
public enum UnsupportedFeature: Sendable, Equatable { … }
public enum SliceProfile: Sendable, Equatable { … }
public enum MarkerTrust: Sendable, Equatable { case untrusted, learnedReliable, learnedUnreliable }

public struct ReorderBuffer: Sendable {
    public enum Mode: Sendable, Equatable { case passthrough, adaptive }
    /// TCP interleaved uses `.passthrough` — the transport already ordered it.
    /// UDP starts at 128 packets / 60 ms adaptive and escalates to 512 / 200 ms above 1 % loss.
    public init(mode: Mode, capacity: Int, maxHold: Duration)
}

/// The whole surface `VigilTransport` drives: bytes in, frames + events + outbound RTCP out,
/// plus a deadline to coalesce timers on.
public struct RTPTrackReceiver: Sendable {
    public init(format: RTPTrackFormat, reorderMode: ReorderBuffer.Mode,
                latency: LatencyPreset, cname: String,
                startTime: MediaInstant) throws(RTPError)
    public private(set) var statistics: StreamStatistics
    public private(set) var presentationClock: PresentationClock
    public var format: RTPTrackFormat { get }
    public mutating func ingestRTP(_ bytes: Data, at now: MediaInstant) -> RTPIngestResult
    public mutating func ingestRTCP(_ bytes: Data, at now: MediaInstant) -> RTPIngestResult
    /// Timer-driven work: buffer drain, AU timeout, RTCP RR generation, statistics windows.
    public mutating func tick(_ now: MediaInstant) -> RTPIngestResult
    public var nextDeadline: MediaInstant? { get }
    public mutating func flush(at now: MediaInstant) -> RTPIngestResult
    public mutating func reset(at now: MediaInstant)
    /// Seeds RTP-Info from the PLAY response so the first PTS is right.
    public mutating func seed(_ timing: RTSPTrackTimingSeed)
    // Written by VigilVideo (API_CONTRACT §2 R-19).
    public mutating func updateDecodeQueueDepth(_ depth: Int)
    public mutating func updateDecodeTimings(p50: Double, p99: Double, isHardware: Bool)
    public mutating func countDroppedPreDisplay(_ n: UInt64)
}
/// The shape `VigilTransport` copies `RTSPTrackTiming` into, so `VigilRTP` needs no RTSP import.
public struct RTSPTrackTimingSeed: Sendable, Hashable {
    public var clockRate: UInt32
    public var initialSequence: UInt16?
    public var initialRTPTimestamp: UInt32?
    public var absoluteStart: Date?
    public var scale: Double
    public var isRateControlDisabled: Bool
    public var playResponseInstant: MediaInstant
}
public struct RTPIngestResult: Sendable {
    public var frames: [EncodedFrame]
    public var events: [DepacketizerEvent]
    /// Payloads only; the transport adds framing.
    public var outboundRTCP: [Data]
    public var isEmpty: Bool { get }
}

// RTCP
public struct SenderReport: Sendable, Equatable { … }
public enum RTCPParser { public static func parseCompound(_ bytes: Data) -> [RTCPPacket] }
public enum RTCPPacket: Sendable, Equatable { … }
public struct RTCPReportBuilder: Sendable { … }

/// Min-filter + PLL. **Not** used for live pacing — live is `AVSampleBufferDisplayLayer` +
/// `DisplayImmediately` with no timebase. Used for the latency estimate, A/V offset reporting and
/// recorded playback (API_CONTRACT §2 R-26).
public struct PresentationClock: Sendable { … }

// Audio helpers, all pure and Linux-tested.
public enum G711 {
    public enum Law: Sendable { case aLaw, muLaw }
    public static func decode(_ bytes: Data, law: Law) -> Data      // → pcmS16LE
    public static func encode(_ pcm: Data, law: Law) -> Data        // talkback
}
public enum G726 { public static func decode32k(_ bytes: Data) -> Data }
public enum AudioSpecificConfig {
    public static func parse(_ config: Data) throws(RTPError) -> AudioFormatInfo
    /// From an SDP `config=` hex string.
    public static func parse(hex: String) throws(RTPError) -> AudioFormatInfo
}
```

**Normative behaviours:** access-unit splitting **never trusts the marker bit** — the rule is an RTP
timestamp change **plus** `SliceHeader.isFirstSliceOfPicture`; marker reliability is *learned* and
reported as `.boundaryPolicyChanged`. AAC stays compressed (raw AU + cookie); G.711 and G.726 are
decoded here to `.pcmS16LE`. There is **no RTP packetizer** — talk-back is an ISAPI HTTP PUT.
`VigilRTSP` owns `$` framing; interleaved channel 1 is RTCP; **RTCP is not a keepalive**. Each
`MalformedReason` and `UnsupportedFeature` is emitted at most once per 5 s per receiver (counters
keep incrementing). On a new SSRC: emit `.ssrcChanged`, reset the depacketizer, the reorder buffer,
the source state, the presentation clock, the unwrapper and the IRAP gate. Non-goals: no SRTP, RED,
FEC, RTX, MTAP, PACI, RTP-JPEG or MP4V-ES.

### 4.5 `VigilISAPI` — Hikvision control plane

Depends on `VigilProtocols`. May import `Foundation`, `FoundationNetworking` (Linux) and
`FoundationXML` (Linux) and **nothing else** — never `Security`, `AppKit`, `SwiftUI`, `CoreMedia`,
`Network` or `OSLog`. This is the one pure module permitted to declare actors (R-32).

```swift
// XML
public struct XMLNode: Sendable, Hashable { … }        // name, key (lowercased), attributes, text, children
public struct ISAPIDocument: Sendable {
    /// Hard caps: 8 MiB input, 64 levels deep. `shouldResolveExternalEntities = false` and
    /// `externalEntityResolvingPolicy = .never` are **mandatory** — XXE defence.
    public init(parsing data: Data) throws(ISAPIError)
    public let root: XMLNode
    public subscript(_ path: String) -> XMLValue { get }
    public func node(_ path: String) -> XMLNode?
    public func nodes(_ path: String) -> [XMLNode]
}
/// Path grammar: `a/b` child chain (case-insensitive) · `a|b|c` first alternative ·
/// `*` one level · `**` zero-or-more, breadth-first · `[n]` index · `[]` all siblings ·
/// `@attr` attribute · `.` self · `||` whole-path alternation. Paths are relative to the root's
/// **children**; the root element name is not part of a path. Compiled once and memoised.
public struct XMLValue: Sendable { … }                 // string/int/double/bool/date/hexData/base64Data
public struct XMLBuilder: Sendable { … }
public enum ISAPITime {
    public static func iso8601UTC(_ date: Date) -> String        // CMSearchDescription bodies
    public static func compactUTC(_ date: Date) -> String        // RTSP playback query strings
    /// Hikvision's POSIX-inverted zone string: `CST-8:00:00` ⇒ +28800 s.
    public static func parseTimeZone(_ raw: String) -> Int?
}

// Status
public struct ResponseStatus: Sendable, Hashable {
    public let requestURL: String?
    public let statusCode: Int          // 1 == OK
    public let statusString: String?
    public let subStatusCode: String?   // lower-cased on read
    public let errorCode: Int?
    public let errorMsg: String?
    public var isOK: Bool { statusCode == 1 }
    /// Tolerates `<ResponseStatus>`, `<userCheck>` and a bare `<statusCode>` root.
    public init?(document: ISAPIDocument)
}

// Auth and trust
public struct DigestChallenge: Sendable, Hashable { … }
public actor DigestStore {
    public func header(for method: String, uri: String, credential: Credential) -> String?
    public func absorb(_ challenge: DigestChallenge)
    public func invalidate(reason: String)
}
/// Injected because `Security` is macOS-only. `VigilCore` implements it; Linux ships only the
/// plain-HTTP conformance used by tests.
public protocol ServerTrustEvaluating: Sendable {
    /// `chainDER` is leaf-first. Called once per TLS handshake.
    func evaluate(host: String, port: Int, chainDER: [Data]) -> ServerTrustDecision
}
public enum ServerTrustDecision: Sendable, Equatable { case trust, reject(String) }

// Client
public actor ISAPIClient {
    public struct Configuration: Sendable {
        public var maxConcurrentControlRequests = 3
        public var maxConcurrentSnapshotRequests = 2
        public var connectTimeout: Duration = .seconds(4)
        public var controlTimeout: Duration = .seconds(8)
        public var searchTimeout: Duration = .seconds(15)
        public var snapshotTimeout: Duration = .seconds(6)
        public var streamIdleTimeout: Duration = .seconds(30)
        public var userAgent = "Vigil/1.0 (macOS)"
        public var maxTransientRetries = 2
        public var allowBasicFallbackOverTLS = true
        public var maxUnaryBodyBytes = 8 << 20
        public init()
    }
    public typealias Lane = HTTPLane
    public init(endpoint: ISAPIEndpoint, credential: Credential,
                configuration: Configuration = .init(), quirks: DeviceQuirks = .init(),
                transport: any HTTPTransporting, trustEvaluator: any ServerTrustEvaluating,
                clock: any MonotonicClock, logger: any LoggerProtocol)
    public func get(_ resource: String, query: [URLQueryItem] = [],
                    lane: Lane = .control) async throws(ISAPIError) -> HTTPResponse
    public func put(_ resource: String, query: [URLQueryItem] = [], body: Data?,
                    contentType: String = "application/xml",
                    lane: Lane = .control) async throws(ISAPIError) -> HTTPResponse
    public func post(_ resource: String, query: [URLQueryItem] = [], body: Data?,
                     contentType: String = "application/xml",
                     lane: Lane = .control) async throws(ISAPIError) -> HTTPResponse
    public func delete(_ resource: String, query: [URLQueryItem] = [],
                       lane: Lane = .control) async throws(ISAPIError) -> HTTPResponse
    public func getXML(_ resource: String, query: [URLQueryItem] = [],
                       lane: Lane = .control) async throws(ISAPIError) -> ISAPIDocument
    public func putXML(_ resource: String, body: XMLBuilder,
                       query: [URLQueryItem] = []) async throws(ISAPIError) -> ResponseStatus
    public func postXML(_ resource: String, body: XMLBuilder, query: [URLQueryItem] = [],
                        lane: Lane = .control) async throws(ISAPIError) -> ISAPIDocument
    public func byteStream(_ resource: String, method: String = "GET",
                           query: [URLQueryItem] = [], headers: HTTPHeaders = .init())
        async throws(ISAPIError) -> (headers: HTTPHeaders, bytes: AsyncThrowingStream<Data, any Error>)
    public func chunkedUpload(_ resource: String,
                              contentType: String) async throws(ISAPIError) -> any HTTPUploadHandle
    /// Consecutive credentialed 401s, shared across every lane. **Two is terminal** and the client
    /// refuses all requests until `VigilCore` supplies a new credential (API_CONTRACT §2 R-25).
    public var authFailureCount: Int { get }
    public func setCredential(_ credential: Credential)
}
public struct URLSessionHTTPTransport: HTTPTransporting, Sendable {
    /// Four `URLSessionConfiguration.ephemeral` sessions, one per lane. Delegate state lives in an
    /// actor (API_CONTRACT §2 R-52) — not behind `@unchecked Sendable`.
    public init(logger: any LoggerProtocol)
}

// The single RTSP path builder (API_CONTRACT §2 R-23, R-69). Returns PATHS, never URLs.
public enum HikvisionURL {
    public static func livePath(_ id: StreamingChannelID) -> String
    public static func playbackPath(_ track: TrackID) -> String
    /// The R1.2 probe ladder, in order. `VigilCore` composes these into an `RTSPURL`.
    public static func candidates(channel: ChannelID, quality: StreamQuality) -> [RTSPPathCandidate]
    public static func snapshotPath(_ id: StreamingChannelID) -> String
}
public struct RTSPPathCandidate: Sendable, Hashable, Codable {
    public enum Family: String, Sendable, Codable {
        case channelsCompact      // /Streaming/Channels/101      current firmware, cameras + NVRs
        case channelsBare         // /Streaming/Channels/1        some 5.x firmware
        case tracks               // /Streaming/tracks/101        NVR playback-capable paths
        case legacyH264           // /h264/ch1/main/av_stream     legacy 4.x
        case legacyMPEG4          // /mpeg4/ch1/sub/av_stream     legacy 4.x
        case onvifGetStreamURI    // ask ONVIF; non-Hikvision or unknown firmware
    }
    public var family: Family
    public var path: String
    public var order: Int
}

// Device session — one per device, memoizing caches and the alert stream.
public actor ISAPIDeviceSession {
    public init(endpoint: ISAPIEndpoint, credential: Credential,
                configuration: ISAPIClient.Configuration = .init(), quirks: DeviceQuirks = .init(),
                transport: any HTTPTransporting, trustEvaluator: any ServerTrustEvaluating,
                clock: any MonotonicClock, logger: any LoggerProtocol)
    // Identity and inventory
    public func deviceInfo(force: Bool = false) async throws(ISAPIError) -> DeviceInfo
    public func status() async throws(ISAPIError) -> DeviceStatus
    public func time(force: Bool = false) async throws(ISAPIError) -> DeviceTime
    public func capabilities(force: Bool = false) async throws(ISAPIError) -> DeviceCapabilitiesWire
    public func networkInterfaces() async throws(ISAPIError) -> [NetworkInterfaceWire]
    public func checkCredentials() async throws(ISAPIError) -> UserCheckResult
    /// R1.3: `/ContentMgmt/InputProxy/channels` + `/System/Video/inputs/channels`, every populated
    /// channel returned pre-checked.
    public func channels(force: Bool = false) async throws(ISAPIError) -> [DeviceChannel]
    public func users() async throws(ISAPIError) -> [DeviceUser]
    // Streaming
    public func streamingChannels(force: Bool = false) async throws(ISAPIError) -> [StreamingChannelConfig]
    public func streamingChannel(_ id: StreamingChannelID) async throws(ISAPIError) -> StreamingChannelConfig
    /// **Read-modify-write on the full element, then re-GET to confirm** (API_CONTRACT §2 R-30).
    /// Returns the device's clamped values, not the requested ones.
    public func updateStream(_ id: StreamingChannelID,
                             _ patch: StreamingChannelPatch) async throws(ISAPIError) -> StreamingChannelConfig
    public func snapshot(_ request: SnapshotWireRequest) async throws(ISAPIError) -> Data
    /// The primary response to a detected gap. `VigilCore` calls it; `VigilRTP`/`VigilVideo`
    /// only *emit* `.keyframeNeeded` (API_CONTRACT §2 R-24).
    public func requestKeyFrame(channel: ChannelID) async throws(ISAPIError)
    // PTZ
    public func ptzCapabilities(channel: ChannelID) async throws(ISAPIError) -> PTZCapabilitiesWire
    public func ptzController(channel: ChannelID) async throws(ISAPIError) -> PTZController
    // Events — exactly one monitor per device, never per channel (API_CONTRACT §2 R-28)
    public func alertStream() -> AlertStreamMonitor
    public func eventTriggers(force: Bool = false) async throws(ISAPIError) -> [EventTrigger]
    public func motionDetection(channel: ChannelID) async throws(ISAPIError) -> MotionDetectionConfig
    public func setMotionDetection(channel: ChannelID, enabled: Bool?, sensitivity: Int?,
                                   grid: MotionGrid?) async throws(ISAPIError)
    // Playback — only `POST /ISAPI/ContentMgmt/search` may paint a timeline (R-29)
    public func recordTracks(force: Bool = false) async throws(ISAPIError) -> [RecordTrack]
    public func searchRecordings(_ q: RecordSearchQuery) async throws(ISAPIError) -> [RecordSegment]
    public func dayIndex(track: TrackID, dayStartUTC: Date,
                         force: Bool = false) async throws(ISAPIError) -> RecordDayIndex
    public func monthCalendar(track: TrackID, year: Int,
                              month: Int) async throws(ISAPIError) -> MonthRecordCalendar
    public func storage(force: Bool = false) async throws(ISAPIError) -> StorageInfo
    // Audio
    public func twoWayAudioChannels() async throws(ISAPIError) -> [TwoWayAudioChannel]
    public func openTwoWayAudio(channel: Int) async throws(ISAPIError) -> TwoWayAudioSession
    // Image
    public func imageSettings(channel: ChannelID) async throws(ISAPIError) -> ImageSettings
    public func setImageColor(channel: ChannelID, brightness: Int?, contrast: Int?,
                              saturation: Int?, hue: Int?) async throws(ISAPIError)
    public func setSharpness(channel: ChannelID, _ level: Int) async throws(ISAPIError)
    public func setWDR(channel: ChannelID, _ setting: WDRSetting) async throws(ISAPIError)
    public func setIRCut(channel: ChannelID, _ setting: IRCutSetting) async throws(ISAPIError)
    public func resetImageDefaults(channel: ChannelID) async throws(ISAPIError)
    // Lifecycle
    public func reboot() async throws(ISAPIError)
    public func invalidateCaches()
    public func shutdown() async
    /// Quirks observed during this session. `VigilCore` persists them on the camera record.
    public var observedQuirks: DeviceQuirks { get }
}

public actor PTZController {
    /// Continuous motion needs a **400 ms keep-alive** re-send and a **triple zero-stop** on
    /// cancel or quit; a runaway camera is unacceptable.
    public func continuous(pan: Int, tilt: Int, zoom: Int) async throws(ISAPIError)
    public func stop() async throws(ISAPIError)
    public func momentary(pan: Int, tilt: Int, zoom: Int, duration: Duration) async throws(ISAPIError)
    public func absolute(_ position: PTZAbsolutePosition) async throws(ISAPIError)
    public func relative(_ move: PTZRelativeMove) async throws(ISAPIError)
    /// 0–255 space, **lower-left origin** unless `DeviceQuirks.ptz3DOriginIsTopLeft`.
    public func position3D(_ box: PTZ3D) async throws(ISAPIError)
    /// Presets **33–105 are reserved device commands** and are blocked for writes.
    public func gotoPreset(_ n: Int) async throws(ISAPIError)
    public func setPreset(_ n: Int, name: String) async throws(ISAPIError)
    public func presets() async throws(ISAPIError) -> [PTZPreset]
    public func status() async throws(ISAPIError) -> PTZStatus
}

public actor AlertStreamMonitor {
    public func start() async
    public func stop() async
    /// Heartbeat parts are suppressed at the parser. A factory, not a property (R-65).
    public func notifications() -> AsyncStream<EventNotificationAlert>
    public func stateChanges() -> AsyncStream<AlertStreamState>
    public var state: AlertStreamState { get }
}
public enum AlertStreamState: Sendable, Hashable {
    case notSupported, idle, connecting, streaming(since: Date)
    case polling(interval: Duration), authFailed
    case failed(reason: String, retryAt: Date)
}
public struct EventNotificationAlert: Sendable, Hashable { … }
public struct MultipartStreamParser: Sendable { … }
public actor TwoWayAudioSession { … }

// Wire models (all `Sendable, Hashable, Codable` value types)
public struct DeviceInfo: Sendable, Hashable, Codable { … }
public struct DeviceStatus: Sendable, Hashable, Codable { … }
public struct DeviceTime: Sendable, Hashable, Codable { … }
public struct DeviceCapabilitiesWire: Sendable, Hashable, Codable { … }
public struct DeviceChannel: Sendable, Hashable, Codable { … }
public struct DeviceUser: Sendable, Hashable, Codable { … }
public struct UserCheckResult: Sendable, Hashable, Codable { … }
public struct NetworkInterfaceWire: Sendable, Hashable, Codable { … }
public struct StreamingChannelConfig: Sendable, Hashable, Codable { … }
public struct StreamingChannelPatch: Sendable, Hashable { … }
public struct SnapshotWireRequest: Sendable, Hashable { … }
public struct PTZCapabilitiesWire: Sendable, Hashable, Codable { … }
public struct PTZVelocity: Sendable, Hashable { … }
public struct PTZAbsolutePosition: Sendable, Hashable, Codable { … }
public struct PTZRelativeMove: Sendable, Hashable { … }
public struct PTZ3D: Sendable, Hashable { … }
public struct PTZPreset: Sendable, Hashable, Codable { … }
public struct PTZPatrol: Sendable, Hashable, Codable { … }
public struct PTZStatus: Sendable, Hashable, Codable { … }
public struct EventTrigger: Sendable, Hashable, Codable { … }
public struct MotionDetectionConfig: Sendable, Hashable, Codable { … }
public struct MotionGrid: Sendable, Hashable, Codable { … }
public struct RecordTrack: Sendable, Hashable, Codable { … }
public struct RecordSearchQuery: Sendable, Hashable { … }
public struct RecordSegment: Sendable, Hashable, Codable { … }
public struct RecordDayIndex: Sendable, Hashable, Codable { … }
public struct MonthRecordCalendar: Sendable, Hashable, Codable { … }
public struct StorageInfo: Sendable, Hashable, Codable { … }
/// Rewrites scheme/host/port and keeps **path + query verbatim** (API_CONTRACT §2 R-29).
public struct PlaybackLocator: Sendable, Hashable, Codable { … }
public struct TwoWayAudioChannel: Sendable, Hashable, Codable { … }
public struct ImageSettings: Sendable, Hashable, Codable { … }
public enum WDRSetting: Sendable, Hashable, Codable { … }
public enum IRCutSetting: Sendable, Hashable, Codable { … }
```

**Wire units, restated because every one has been got wrong in the field:** `maxFrameRate` = fps ×
100 · `keyFrameInterval` = **milliseconds** · `GovLength` = **frames** · storage capacity =
**decimal MB** · region coordinates 0–1000 (some smart cameras use 0–10000; detect by magnitude).
**Concurrency:** 3 control requests per device (1 when `maxConcurrentRequestsOverride == 1`), plus
separate snapshot / stream / audio lanes; app-wide snapshot cap **6**, excess **dropped, not
queued**. PTZ, and only PTZ, may over-subscribe the control gate by exactly one slot.
**Negative capability cache:** any `403 notSupport`, `404 notFound` or `405 methodNotAllowed` on a
capability-bearing resource is cached by resource template for 24 h or until reboot, and later calls
throw `.notSupported` with **no network round trip**.

### 4.6 `VigilDiscovery` — SADP, WS-Discovery, subnet sweep

Depends on `VigilProtocols` **only** — deliberately **no** edge to `VigilRTSP`; it carries its own
~70-line lenient `StartLineHeaderScanner`. Every socket lives in `VigilTransport/Discovery/`.

```swift
// Injected capabilities — the seven Sendable transport protocols. NONE has a credential parameter,
// anywhere, which is how "discovery never sends credentials" is enforced mechanically (R-31).
public protocol DatagramChannel: Sendable {
    var localPort: UInt16 { get }
    var interfaceName: String? { get }
    func send(_ payload: Data, to host: IPv4Address, port: UInt16) async throws(DiscoveryError)
    func inboundDatagrams() -> AsyncStream<InboundDatagram>
    func close() async
}
public protocol TCPProbing: Sendable {
    func probe(_ host: IPv4Address, port: UInt16, timeout: Duration,
               interfaceName: String?) async -> TCPProbeOutcome
}
public protocol ByteExchanging: Sendable {
    func exchange(host: IPv4Address, port: UInt16, useTLS: Bool, request: Data,
                  readLimit: Int, timeout: Duration,
                  interfaceName: String?) async throws(DiscoveryError) -> Data
}
public protocol InterfaceEnumerating: Sendable {
    func interfaces() throws(DiscoveryError) -> [NetworkInterfaceInfo]
}
public protocol ARPTableProviding: Sendable {
    func snapshot() throws(DiscoveryError) -> [ARPEntry]
}
public protocol ServiceBrowsing: Sendable {
    func browse(types: [String]) -> AsyncStream<BonjourService>
}
/// Discovery gets its own clock protocol because it needs `uptime` for elapsed maths and a
/// virtual implementation turns a 12 s run into 2 ms.
public protocol DiscoveryClock: Sendable {
    var wallNow: Date { get }
    func now() -> MediaInstant
    func sleep(for duration: Duration) async throws
}

public struct DiscoveryEnvironment: Sendable { … }      // the eleven injected values
public struct MulticastGroupSpec: Sendable, Hashable {
    public var group: IPv4Address       // 239.255.255.250
    public var port: UInt16             // 37020 (SADP) | 3702 (WS-Discovery)
    public var preferredLocalPort: UInt16
    public var localAddress: IPv4Address        // added; §11 used it without declaring it (R-67)
    public var interfaceName: String
    public var hopLimit: Int            // 1 — keep SADP/WSD on-link
}
public struct InboundDatagram: Sendable, Hashable { … }
public struct NetworkInterfaceInfo: Sendable, Hashable, Codable { … }
public struct ARPEntry: Sendable, Hashable, Codable { … }
public struct BonjourService: Sendable, Hashable { … }
public enum TCPProbeOutcome: Sendable, Hashable {
    case open
    /// RST — the host is alive and the port is closed. Valuable.
    case refused
    case timedOut
    case unreachable(POSIXCode)
    /// Local-network permission denied, or the sandbox refused. Feeds the §9.4 heuristic.
    case blockedByPolicy
}
public struct POSIXCode: Sendable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: Int32
}

// Model
public enum DiscoverySource: String, Sendable, Hashable, Codable, CaseIterable { … }  // + `trust`
public enum DeviceVendor: String, Sendable, Hashable, Codable { … }                   // + `supportsISAPI`
public enum DeviceClass: String, Sendable, Hashable, Codable { … }
public enum ActivationState: String, Sendable, Hashable, Codable { case activated, notActivated, unknown }
public enum Reachability: String, Sendable, Hashable, Codable {
    case reachable, addressableNoPorts, offSubnet, unknown
}
public enum DeviceIdentity: Sendable, Hashable, Codable { … }     // mac > serial > onvifUUID > endpoint
public enum DeviceFieldKey: String, Sendable, Hashable, Codable, CaseIterable { … }
public struct FieldStamp: Sendable, Hashable, Codable { … }
public struct ONVIFScopes: Sendable, Hashable, Codable { … }
public struct DiscoveredDevice: Sendable, Hashable, Codable, Identifiable { … }
public struct DeviceObservation: Sendable { … }
public enum FieldValue: Sendable, Hashable, Codable { … }
public struct KnownDeviceSnapshot: Sendable, Hashable, Codable { … }

// Coordination
public struct DiscoveryConfiguration: Sendable { … }
public struct DiscoveryPlan: Sendable, Hashable { … }
public enum SweepPlanner {
    public static func plan(interfaces: [NetworkInterfaceInfo], arp: [ARPEntry],
                            configuration: DiscoveryConfiguration)
        -> Result<DiscoveryPlan, DiscoveryError>
}
public enum SweepPolicy {
    /// **Hard floor. Not user-overridable.** Wider than /16 is 65 536+ hosts and is refused.
    public static let minimumPrefixLength: UInt8 = 16
    /// /16–/21 is narrowed to our own /24 plus every /24 with at least one ARP entry.
    public static let confirmationPrefixLength: UInt8 = 22
}
public actor DiscoveryCoordinator {
    public init(environment: DiscoveryEnvironment, configuration: DiscoveryConfiguration = .default)
    /// One run per instance. The returned stream is the run's only consumer, which is the single
    /// sanctioned exception to R-65.
    public func start() -> AsyncStream<DiscoveryEvent>
    public func cancel()
    public var snapshot: [DiscoveredDevice] { get }
    public var progress: DiscoveryProgress { get }
    public var diagnostics: [DiscoveryDiagnostic] { get }
}
public enum DiscoveryEvent: Sendable {
    case started(DiscoveryPlan)
    case progress(DiscoveryProgress)
    /// **Exactly one per record, ever.** Later changes are `.deviceUpdated` / `.deviceMerged`.
    case deviceFound(DiscoveredDevice)
    case deviceUpdated(DiscoveredDevice, changes: Set<DeviceFieldKey>)
    case deviceMerged(absorbed: [DeviceIdentity], into: DeviceIdentity)
    case addressChanged(DeviceIdentity, from: IPv4Address, to: IPv4Address)
    /// A **new MAC at an old IP**. Must never re-point a saved camera.
    case addressReused(IPv4Address, previous: DeviceIdentity, now: DeviceIdentity)
    case phaseCompleted(DiscoveryPhase, PhaseSummary)
    case diagnostic(DiscoveryDiagnostic)
    case finished(DiscoverySummary)
}
public enum DiscoveryPhase: String, Sendable, Hashable, Codable, CaseIterable { … }
public struct DiscoveryProgress: Sendable, Hashable, Codable { … }
public struct PhaseSummary: Sendable, Hashable { … }
public struct DiscoverySummary: Sendable, Hashable { … }
public enum DiscoveryDiagnostic: Sendable, Hashable, Codable {
    // 15 cases; each has `userFacingMessage: String?` and `severity: Severity`.
    public enum Severity: String, Sendable, Hashable, Codable { case info, warning, actionRequired }
}
public enum MulticastUnavailableReason: String, Sendable, Hashable, Codable { … }
public enum BudgetKind: String, Sendable, Hashable, Codable {
    case datagrams, tcpConnects, httpRequests, fileDescriptors
}

// Codecs — pure, total, never throwing on garbage
public enum SADPCodec {
    public static func encodeProbe(uuid: UUID) -> Data           // the 121-byte probe
    public static func decode(_ payload: Data, from source: IPv4Address,
                              expectedUUID: UUID?, receivedAt: Date) -> SADPDecodeResult
    public static func observation(from match: SADPProbeMatch,
                                   source: DiscoverySource) -> DeviceObservation
    /// `DS-2CD2143G0-I20200114AAWRD12345678` → (`DS-2CD2143G0-I`, `20200114AAWRD12345678`).
    public static func splitSerial(_ sn: String) -> (model: String?, remainder: String)
}
public enum SADPDecodeResult: Sendable, Equatable { … }
public struct SADPProbeMatch: Sendable, Hashable, Codable { … }
public struct SADPOpaquePayload: Sendable, Hashable, Codable { … }
public enum WSDiscoveryCodec {
    public static func encodeProbe(messageID: UUID, types: WSDProbeTypes) -> Data
    public static func decodeProbeMatches(_ payload: Data, from source: IPv4Address,
                                          expectedMessageIDs: Set<String>,
                                          receivedAt: Date) -> WSDDecodeOutcome
    public static func parseScopes(_ raw: String) -> ONVIFScopes
    public static func observation(from match: WSDProbeMatch) -> DeviceObservation
}
public enum WSDProbeTypes: Sendable, Equatable { … }
public enum WSDDecodeOutcome: Sendable, Equatable { … }
public struct WSDProbeMatch: Sendable, Hashable, Codable { … }
public enum FingerprintCodec {
    public static func rtspOptionsRequest(host: IPv4Address, port: UInt16) -> Data
    public static func isapiDeviceInfoRequest(host: IPv4Address) -> Data
    public static func rootRequest(host: IPv4Address) -> Data
    public static func classifyRTSP(_ response: Data) -> RTSPFingerprint
    public static func classifyHTTP(_ response: Data) -> HTTPFingerprint
}
public struct RTSPFingerprint: Sendable, Hashable { … }
public struct HTTPFingerprint: Sendable, Hashable { … }
public enum VendorClassifier {
    public static func classify(_ e: ClassificationEvidence) -> ClassificationVerdict
}
public struct ClassificationEvidence: Sendable, Hashable { … }
public struct ClassificationVerdict: Sendable, Hashable {
    public var vendor: DeviceVendor
    public var deviceClass: DeviceClass
    public var confidenceDelta: Int
}
public struct HostProbeResult: Sendable, Hashable { … }
/// Deliberately duplicated here rather than importing `VigilRTSP` (~70 lines). Never throws,
/// never crashes: tolerates bare LF, a missing reason phrase, no body, non-UTF-8 bytes
/// (decoded as ISO-8859-1) and colonless header lines (skipped).
public struct StartLineHeaderScanner: Sendable { … }
public enum ARPTableDecoder {
    public static func decodeRouteDump(_ raw: UnsafeRawBufferPointer, byteCount: Int) -> [ARPEntry]
    public static func decodeARPText(_ text: String) -> [ARPEntry]
}
public enum IdentityNormalizer {
    public static func serialKey(_ raw: String) -> String?
    public static func onvifKey(_ raw: String) -> String?
}
```

**Normative numbers:** SADP group `239.255.255.250:37020`, WS-Discovery `239.255.255.250:3702`,
hop limit 1, max datagram 8 192 B, `SO_REUSEADDR`+`SO_REUSEPORT`, `disableUnicast: false` (ProbeMatches
arrive as unicast from arbitrary source ports). Port tiers **A** `[554, 80]` → every planned host;
**B** `[8000, 443, 8080]` → hosts where A found anything, plus ARP hosts, plus hosts named by
SADP/WSD/Bonjour; **C** `[37777, 2020, 8554]` → only when A/B answered and vendor is still unknown.
TCP connect timeout **350 ms**, fingerprint 600 ms, per-host fingerprint budget 1 200 ms, read cap
4 096 B. In flight **128** (192 degraded), clamped by
`min(configured, max(16, (rlim_cur - 96) / 2))`. Probe schedules `[0, 500, 1000] ms`, listen tail
2 500 ms, settle 750 ms, overall deadline `min(180, 12 + 8 × log2(hosts/254))` s. Per host: ≤ 3
HTTP/RTSP requests, ≤ 8 TCP connects, one connect per (host, port) per run, **no retries**.
Identity ladder MAC(4) > serial(3) > ONVIF UUID(2) > `ip:httpPort`(1), resolved by union-find;
UUID- and TXT-derived MACs are **hints only** and never form an identity.

### 4.7 `VigilTransport` — sockets, TLS, timers (macOS)

Depends on `VigilProtocols`, `VigilRTSP`, `VigilDiscovery`. Every file wrapped in `#if os(macOS)`.

```swift
/// Owns one `NWConnection`, the `RTSPSessionMachine`, and its timers. Writes each `.send` /
/// `.sendInterleaved` as **one atomic write**, and supports `pauseReads()`/`resumeReads()`
/// independently of writes (Rate-Control has no flow control).
public actor RTSPConnection {
    public init(endpoint: RTSPEndpoint, quirks: DeviceQuirks, trust: any ServerTrustEvaluating,
                clock: any MonotonicClock, logger: any LoggerProtocol)
    public func connect() async throws(TransportError)
    public func write(_ data: Data) async throws(TransportError)
    public func bytes() -> AsyncThrowingStream<Data, any Error>
    public func pauseReads()
    public func resumeReads()
    public func close() async
    public var isTLS: Bool { get }
    /// SPKI SHA-256 of the leaf, for trust-on-first-use pinning shared with ISAPI.
    public var leafSPKI256: Data? { get }
}
/// Even/odd port pairs allocated from **51000–51998**.
public actor UDPMediaSocketPair { … }
public actor MulticastResponder { … }
/// The 6-line adapter that keeps `VigilRTP` free of any RTSP import.
public enum RTPTrackFormatAdapter {
    public static func make(from media: SDPMediaDescription) throws(RTPError) -> RTPTrackFormat
    public static func seed(from timing: RTSPTrackTiming) -> RTSPTrackTimingSeed
}
public struct SystemServerTrustEvaluator: ServerTrustEvaluating, Sendable { … }
/// `Discovery/` — the seven conformances, one per protocol, plus the live environment.
public actor MulticastDatagramChannel: DatagramChannel { … }
public actor UnicastDatagramChannel: DatagramChannel { … }
public struct TCPConnectProber: TCPProbing, Sendable { … }
public struct NWByteExchanger: ByteExchanging, Sendable { … }
public struct SystemInterfaceEnumerator: InterfaceEnumerating, Sendable { … }
public struct SystemARPTableReader: ARPTableProviding, Sendable { … }
public struct BonjourBrowser: ServiceBrowsing, Sendable { … }
public enum EntitlementInspector {
    public static func multicastEntitlementPresent() -> Bool
    public static func localNetworkPermission() -> LocalNetworkPermission
}
public enum LiveDiscoveryEnvironment { public static func make(logger: any LoggerProtocol) -> DiscoveryEnvironment }
/// Raises `RLIMIT_NOFILE` to `min(4096, rlim_max)` when `rlim_cur < 4096`. Called once at launch.
public enum FileDescriptorBudget { public static func raiseLimit() }
```

Every destination passes `HostPolicy.requirePermitted(_:)` **before** the socket is created (R-71).
Each `RTSPConnection` creates one serial `.userInitiated` `DispatchQueue` named
`com.vigil.net.<cameraShortID>` and bridges to `async` immediately; `withTaskCancellationHandler`
wraps every receive so cancelling the task calls `connection.cancel()`.

### 4.8 `VigilCore` — domain, persistence, orchestration (macOS)

Depends on everything except `VigilRender` and `VigilUI`. See §5 for the file list; the surface:

```swift
public struct CoreDependencies: Sendable { … }          // §2 of spec-core.md, with §3 protocol names
public protocol FileSystemProtocol: Sendable { … }      // writeDurably MUST F_FULLFSYNC
public protocol KeychainProtocol: Sendable { … }
public protocol DiskSpaceProbing: Sendable { … }
public protocol NetworkPathMonitoring: Sendable { func paths() -> AsyncStream<NetworkPathState>; var current: NetworkPathState { get async } }
public protocol OcclusionObserving: Sendable { func occlusionEvents() -> AsyncStream<OcclusionEvent> }
public protocol PowerEventObserving: Sendable { func powerEvents() -> AsyncStream<PowerEvent>; var conditions: PowerConditions { get async } }
public protocol NotificationScheduling: Sendable { … }
public protocol PasteboardWriting: Sendable { func write(_ data: Data, type: String); func writeString(_ s: String) }
public protocol FrameTap: Sendable { func captureCurrentFrame() async -> VideoFrame? }
public struct NetworkPathState: Sendable, Hashable { … }
public struct PowerConditions: Sendable, Hashable { … }  // isOnBattery, isLowPower, thermalState
public enum OcclusionEvent: Sendable, Hashable { … }
public enum PowerEvent: Sendable, Hashable { … }
public struct FileAttributes: Sendable, Hashable { public var size: Int64; public var modified: Date }

// Domain model — all `Sendable, Codable, Hashable`, all with explicit `CodingKeys`.
public struct Camera: Identifiable, Sendable, Codable, Hashable { … }   // no password property, ever
public struct StreamProfile: Identifiable, Sendable, Codable, Hashable { … }  // `id: StreamQuality`
public struct DeviceCapabilities: Sendable, Codable, Hashable { … }     // includes `quirks: DeviceQuirks`
public struct CameraGroup: Identifiable, Sendable, Codable, Hashable { … }
public struct Layout: Identifiable, Sendable, Codable, Hashable { … }
public enum LayoutMode: Sendable, Codable, Hashable {
    case single, grid(columns: Int, rows: Int), onePlusFive, onePlusSeven, twoPlusEight
    case custom([GridCell])
    public var cellCount: Int { get }
    /// **Integer rectangles on the 12 × 12 unit grid** (API_CONTRACT §2 R-56). One geometry source.
    public func cells() -> [GridCell]
}
public struct GridCell: Sendable, Codable, Hashable { public var x, y, w, h: Int }   // 0...12
public struct CellAssignment: Sendable, Codable, Hashable { … }
public struct CycleSettings: Sendable, Codable, Hashable { … }
public struct DisplayBinding: Sendable, Codable, Hashable { … }
public struct Bookmark: Identifiable, Sendable, Codable, Hashable { … }
public struct EventRecord: Identifiable, Sendable, Codable, Hashable { … }
public struct NormalizedRect: Sendable, Codable, Hashable { … }
public struct RecordingClip: Identifiable, Sendable, Codable, Hashable { … }
public enum ClipContainer: String, Sendable, Codable { case mp4, mov }
public enum RecordingTrigger: String, Sendable, Codable, CaseIterable { … }
public struct AppSettings: Sendable, Codable, Hashable { … }
public struct Library: Sendable, Codable, Hashable { public static let currentSchemaVersion = 3 }
public enum OrderIndex { public static let step = 1024 }

// Persistence
public actor ConfigStore { … }                 // load / snapshot / mutate / flush / changes() / export / import
public actor EventLog { … }                    // separate events.json ring, capacity 5000
public protocol SchemaMigration: Sendable { … }
public enum SchemaMigrator { … }               // 1→2→3, chain never a jump table
public actor CredentialStore { … }             // the ONLY user of Security.framework

// Streaming
public actor StreamController: Identifiable { … }         // §7 of spec-core.md; 58-row table
public enum StreamState: String, Sendable, Codable, CaseIterable { … }   // 11 states
public enum StreamEvent: Sendable { … }
public struct StateDetail: Sendable, Hashable { … }
public struct StreamFormat: Sendable, Hashable { … }
public struct ReconnectPolicy: Sendable, Equatable { … }  // 0.5/1/2/4/8/15/30 ±20 %, reset after 60 s
public struct StreamError: Error, Sendable, Hashable { … }
public actor StreamCoordinator { … }
public struct Viewport: Sendable, Hashable { … }          // `Tile.pixelSize: Resolution`, backing px
public struct LivePlan: Sendable, Hashable { … }
public enum DeliveryMode: Sendable, Hashable { … }
/// R1.2: candidates concurrently, **bounded to 3 in flight**; `200` + parseable SDP with a
/// supported video codec wins; `404`/`455` advance; **`401` does NOT advance** — the path is right
/// and the credentials need applying. The winner is persisted on `Camera`.
public actor StreamProbe {
    public func findWorkingPath(camera: Camera, credential: Credential?,
                                quality: StreamQuality) async -> RTSPPathCandidate?
}
@MainActor @Observable public final class LiveViewState { … }
public struct TileState: Sendable, Hashable { … }
public enum GlobalBanner: Sendable, Hashable { … }

// Capture, events, health, diagnostics, automation
public actor ClipRecorder { … }                // passthrough muxing ONLY; outputSettings: nil
public struct PreRollBuffer: Sendable { … }    // whole GOPs, 96 MiB / 240 GOPs per camera
public enum RecordingNaming { … }
public actor SnapshotService { … }
public struct SnapshotOptions: Sendable, Hashable { … }
public struct SnapshotResult: Sendable, Hashable { … }
public actor EventCenter { … }
public actor HealthMonitor { … }
public struct HealthSample: Sendable, Codable, Hashable { … }    // exactly 24 bytes
public struct HealthSummary: Sendable, Hashable { … }
public enum HealthGrade: String, Sendable, Codable { case good, fair, poor, offline }
public actor StreamDoctor { … }                // 13 steps, 25 s budget, nine R1.5 diagnoses
public enum DoctorStep: String, Sendable, Codable, CaseIterable { … }
public enum DoctorCause: String, Sendable, Codable, CaseIterable { … }
public struct DoctorReport: Sendable, Hashable { … }
public enum DoctorAction: Sendable, Hashable { … }
public actor DiagnosticsBundleBuilder { … }
public enum DiagnosticsRedactor { … }
public enum DeepLink: Sendable, Hashable {
    /// Total function: never throws, never traps.
    public static func parse(_ url: URL) -> Result<DeepLink, DeepLinkError>
    public var isWriteAction: Bool { get }
}
public enum DeepLinkError: Sendable, Hashable, Error { … }
public struct OSLogLogger: LoggerProtocol, Sendable { … }
```

`VigilCore` also provides the `LocalizedError` extensions for every §3.9 error enum, and the
`DeviceQuirks` merge point: protocol modules **detect**, `VigilCore` **persists**, `VigilCore`
**injects** on the next connect.

### 4.9 `VigilVideo` — VideoToolbox, CoreMedia, audio (macOS)

Depends on `VigilProtocols`, `VigilBitstream`. **Exclusively creates** every
`CMFormatDescription`, `CMSampleBuffer`, `CVPixelBuffer`, `VTDecompressionSession` and
`AVSampleBufferDisplayLayer` in the app.

```swift
/// One decoded picture. `DecodedFrame` and `DecodedVideoFrame` do not exist (R-51).
/// `@unchecked Sendable` #2 of 3 (R-52).
public struct VideoFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer      // 420v / 420f / x420 / xf20, IOSurface-backed
    public let format: VideoFormatInfo
    public let pts: MediaTimestamp
    public let duration: MediaTimestamp?
    public let capturedAt: MediaInstant?       // RTCP-derived sender time, for glass-to-glass
    public let decodedAt: MediaInstant
    public let sequence: UInt64                // monotonic per stream, for drop accounting
    public let isKeyframe: Bool
    /// Bumps on every format change; renderers discard stale generations.
    public let generation: UInt32
}

/// The one sink protocol (R-51). `VigilRender.VideoTileView` is the only implementer.
public protocol VideoSink: AnyObject, Sendable {
    /// Must return in < 2 ms and must not block. Called from the pipeline's presenter task.
    nonisolated func enqueue(_ frame: VideoFrame)
    /// The `AVSampleBufferDisplayLayer` fast path. No box needed: both sides are `nonisolated`
    /// and the call is synchronous, so no isolation boundary is crossed.
    nonisolated func enqueue(_ sampleBuffer: CMSampleBuffer, format: VideoFormatInfo,
                             generation: UInt32)
    /// The renderer MUST pin its last texture between these two and show no black frame.
    nonisolated func willChangeFormat(from old: VideoFormatInfo?, to new: VideoFormatInfo,
                                      generation: UInt32)
    nonisolated func didChangeFormat(to new: VideoFormatInfo, generation: UInt32)
    nonisolated func streamDidReset()
    nonisolated func streamDidEnd(reason: StreamEndReason)
    nonisolated func didDropFrames(_ count: Int, reason: FrameDropReason)
    nonisolated func didStall(since: MediaInstant)
    nonisolated func didRecover()
}
public extension VideoSink {
    // No-op defaults for the six observability members, so a minimal sink is three lines.
    nonisolated func willChangeFormat(from: VideoFormatInfo?, to: VideoFormatInfo, generation: UInt32) {}
    nonisolated func didChangeFormat(to: VideoFormatInfo, generation: UInt32) {}
    nonisolated func didDropFrames(_: Int, reason: FrameDropReason) {}
    nonisolated func didStall(since: MediaInstant) {}
    nonisolated func didRecover() {}
}
public enum StreamEndReason: String, Sendable, Hashable, Codable {
    case stopped, failed, formatUnsupported, budgetReleased, peerClosed
}
public enum FrameDropReason: String, Sendable, Hashable, Codable {
    case queueFull, awaitingKeyframe, badData, decoderDropped, formatChange, noFormat, policy
}
public enum PacingMode: String, Sendable, Hashable { case live, paced }

/// **The single conversion site** from `ParameterSets` to CoreMedia. Order `[SPS, PPS]` /
/// `[VPS, SPS, PPS]`, `nalUnitHeaderLength: 4`, parameter-set count hard-capped at 8.
public enum FormatDescriptionFactory {
    public static func make(codec: VideoCodec, parameterSets: ParameterSets,
                            info: VideoFormatInfo?) throws(DecodeError) -> CMVideoFormatDescription
}
public enum SampleBufferBuilder {
    public static func make(_ frame: EncodedFrame,
                            format: CMVideoFormatDescription) throws(DecodeError) -> CMSampleBuffer
}

public enum DisplayStrategy: String, Sendable, Hashable, Codable {
    /// Default live path: `AVSampleBufferDisplayLayer` + `DisplayImmediately`, **no timebase**.
    case sampleBufferLayer
    /// Explicit `VTDecompressionSession` + Metal. Only when pixels are actually needed.
    case pixelBufferMetal
}
public struct StrategyInputs: Sendable, Hashable {
    public var needsPixelAccess: Bool          // zoom ≠ 1, adjustments, deinterlace, privacy mask, atlas
    public var isRecordedPlayback: Bool
    public var rate: Double
    public var tileCount: Int
    public var metalAvailable: Bool
    public var isInterlaced: Bool
    public var isHDR: Bool
    public init(…)                              // explicit public init (R-67)
}
public func selectStrategy(_ i: StrategyInputs) -> DisplayStrategy

public actor DecodePipeline {
    public init(key: StreamKey, configuration: DecodePipelineConfiguration, sink: any VideoSink,
                budget: any DecodeAdmitting, requestKeyframe: @escaping @Sendable () async -> Void,
                jpegProvider: (@Sendable (Resolution) async throws -> Data)? = nil,
                clock: any MonotonicClock, logger: any LoggerProtocol)
    public func start() async throws(DecodeError)
    public func stop() async
    public func events() -> AsyncStream<PipelineEvent>          // factory (R-65)
    /// Never throws, never suspends on I/O, never blocks the caller. Applies the drop policy.
    public func submit(_ frame: EncodedFrame)
    public func submitAudio(_ frame: EncodedFrame)              // same type (R-64)
    public func setStrategy(_ strategy: DisplayStrategy) async throws(DecodeError)
    public func setMode(_ mode: DecodeMode) async
    public func setTileContext(_ context: TileContext) async
    public func setPaused(_ paused: Bool, reason: PauseReason) async
    public func flushAndRequestKeyframe() async
    public func setAudioEnabled(_ enabled: Bool) async
    public func statistics() -> DecodeStatistics
    public func currentFormat() -> VideoFormatInfo?
    public func snapshot(_ source: SnapshotSource) async throws(DecodeError) -> VideoFrame
    /// The layer for `VigilRender` to host. Never added to a view hierarchy here.
    public func displayLayer() async -> AVSampleBufferDisplayLayer?
}
public struct DecodePipelineConfiguration: Sendable {
    public var isLive = true
    public var queueCapacity = 6                // recorded 12, reverse 72
    public var targetQueueDepth = 2
    public var requireHardwareDecode = false
    public var allowDownscaleOnDecode = true
    public var initialStrategy: DisplayStrategy = .sampleBufferLayer
    public var audioEnabled = false
    public var maximumKeyframeRequestsPerMinute = 10
    public init()                                // explicit (R-67)
    public static let live = DecodePipelineConfiguration()
    public static let thumbnail: DecodePipelineConfiguration
}
public enum PipelineEvent: Sendable { … }        // 18 cases, incl. `.idleTeardownAdvised`, `.strategySwitchFailed`
public enum PauseReason: String, Sendable, Hashable { case occluded, offscreen, budget, user, thermal }
public enum ModeChangeReason: String, Sendable, Hashable { case tileSize, budget, thermal, user, latency }
public enum SnapshotSource: String, Sendable, Hashable { case displayed, freshDecode, deviceJPEG }
public enum LatencyLevel: Int, Sendable, Hashable, Codable, Comparable {
    case normal = 0, trim = 1, skipToKeyframe = 2, degrade = 3
}
public struct DecodeStatistics: Sendable, Codable, Hashable { … }

/// **The single admission authority.** Conforms to `VigilProtocols.DecodeAdmitting` (R-49).
@globalActor public actor DecodeBudget: DecodeAdmitting {
    public static let shared = DecodeBudget()
    public func calibrate(_ observation: CalibrationObservation) async
}
public struct CalibrationObservation: Sendable, Hashable { … }
public enum MachineClass: String, Sendable, Hashable, Codable, CaseIterable { … }   // the R-59 table

public actor PlaybackPipeline { … }
public protocol PlaybackTransportControl: Sendable { … }
public enum PlaybackRate: Double, Sendable, CaseIterable { case r0_25 = 0.25, r0_5 = 0.5, r1 = 1, r2 = 2, r4 = 4, r8 = 8 }
public enum PlaybackDirection: Sendable { case forward, reverse }
public enum PlaybackState: Sendable, Equatable { … }
public enum PlaybackEvent: Sendable { … }

public actor AudioPlaybackEngine { … }
public actor AudioRouter {
    /// D8: only the focused camera is audible by default; **at most 4** unmuted at once; the 5th
    /// unmute mutes the least-recently-unmuted with a toast.
    public func setFocused(_ key: StreamKey?) async
    public func setUserMuted(_ key: StreamKey, _ muted: Bool) async
    public func setSolo(_ key: StreamKey?) async
    public func setVolume(_ key: StreamKey, _ gain: Float) async
    public func setFollowFocus(_ enabled: Bool) async
    public var audible: Set<StreamKey> { get async }
}
public struct AudioStatistics: Sendable, Codable, Hashable { … }
public enum AudioError: String, Sendable, Hashable, Error, Codable { … }
public actor TalkbackController { … }
public enum TalkbackError: String, Sendable, Hashable, Error, Codable { … }
public enum SnapshotEncoder {
    public static func encode(_ frame: VideoFrame, format: SnapshotFormat, quality: Double,
                              metadata: SnapshotMetadata) throws(DecodeError) -> Data
    public static func decodeJPEG(_ data: Data) throws(DecodeError) -> VideoFrame
}
public enum SnapshotFormat: String, Sendable, Hashable, Codable, CaseIterable { case png, jpeg, heic }
public struct SnapshotMetadata: Sendable, Hashable { … }
/// `@unchecked Sendable` #1 of 3 (R-52). The only sanctioned bridge out of the VT callback.
final class DecodeSinkBox: @unchecked Sendable { … }
```

**Live has no A/V-sync buffering.** Queue capacity 6, target depth 2, adaptive ladder
`normal → trim → skipToKeyframe → degrade` at depth EWMA **3.0 / 5.0** and latency **220 / 400 ms**,
with **5 s** recovery hysteresis and a one-level-per-5-s step down. The app's own contribution to
glass-to-glass must stay **under 55 ms at p99**. Format changes and occlusion resumes use
`flush()` only — **never** `flush(removingDisplayedImage: true)`; that is the "no black flash" rule.
`AsyncStream.Continuation` is the only sanctioned bridge out of a C callback.

### 4.10 `VigilRender` — Metal, layers, interaction (macOS)

Depends on `VigilProtocols`, `VigilVideo`. **Never** imports `VigilCore`, `VigilUI`, `VigilISAPI`,
`VigilRTSP` or `VigilRTP`. Everything is `@MainActor` except the value types and `LatestFrameBox`;
the only `nonisolated` entry points are the two `enqueue` overloads.

```swift
public struct TileGeometry: Sendable, Equatable { … }        // codedSize, cropRect, PAR, displaySize
public struct TileTransform: Sendable, Equatable { … }       // zoom 1…8, NDC translation, flipVertical
public struct TileCoordinateMap: Sendable { … }              // content ↔ view, visibleContentRect
public enum VideoGravity: String, Sendable, Codable, CaseIterable { case fit, fill, stretch }
public enum NormalizedOrigin: String, Sendable, Codable { case topLeft, bottomLeft }
/// Camera 0…1000 rect → content-normalized. **Rect flip is `y' = 1 − (y + h)`, never `1 − y`.**
/// Polygon flip is per-vertex `y' = 1 − y` then `reversed()`, to preserve winding.
public func contentRect(cameraRect: CGRect, origin: NormalizedOrigin) -> CGRect
public func contentPolygon(cameraPolygon: [CGPoint], origin: NormalizedOrigin) -> [CGPoint]

public struct ImageAdjustments: Sendable, Codable, Equatable { … }
public enum DeinterlaceMode: UInt8, Sendable, Codable, CaseIterable { case auto, none, bob, blend }
public struct TileRenderOptions: Sendable, Equatable { … }
public enum TileBackend: String, Sendable, Equatable { case metal, sampleBufferLayer }
public enum TileInteractionMode: Sendable, Equatable {
    case normal, position3D, privacyEdit, clickToCenter, inert
}
public struct MotionBox: Sendable, Equatable, Identifiable { … }
public struct PrivacyRegion: Sendable, Equatable, Codable, Identifiable { … }
public struct PrivacyMaskSet: Sendable, Equatable, Codable {
    public var regions: [PrivacyRegion]
    public var origin: NormalizedOrigin
    public var isEnabled: Bool
    public static let disabled: PrivacyMaskSet          // was referenced, never declared (R-66)
}

@MainActor public final class RenderContext {
    public static let shared: RenderContext?
    public let device: any MTLDevice
    public let commandQueue: any MTLCommandQueue
    public let capabilities: RenderCapabilities
    public static func makeForTesting(device: any MTLDevice) -> RenderContext?
    public func flushCaches()
    public func purgePipelineCache()
}
public struct RenderCapabilities: Sendable, Equatable { … }

@MainActor public final class VideoTileView: NSView, VideoSink { … }
@MainActor @Observable public final class TileRenderState {
    /// `bounds × backingScaleFactor`, integer. **The authoritative input to the class A–E table**
    /// (API_CONTRACT §2 R-21). Published after the presented frame's uniforms are built and before
    /// `present()`, coalesced to at most one per display refresh.
    public private(set) var pixelSize: Resolution
    public private(set) var geometry: TileGeometry
    public private(set) var transform: TileTransform
    public private(set) var coordinateMap: TileCoordinateMap
    public private(set) var backend: TileBackend
    public private(set) var isReceivingFrames: Bool
    public private(set) var stats: RenderStats
    public var suppressesEventOverlays: Bool
}
public struct RenderStats: Sendable, Equatable { … }
/// One `TileRenderer` per cell in atlas mode; the wall's per-slot handle (R-66).
@MainActor public final class TileRenderer { … }
@MainActor public final class WallCompositorView: NSView { … }
public struct WallCell: Sendable, Identifiable, Equatable { … }
public struct VideoTile: NSViewRepresentable { … }
public struct VideoWall: NSViewRepresentable { … }
/// Lets `VigilCore` attach a stream's frames to whichever view SwiftUI creates, without
/// `VigilRender` importing `VigilCore`.
public final class FrameStreamHandle: @unchecked Sendable { … }
@MainActor public protocol TileInteractionDelegate: AnyObject { … }   // 14 members
public enum PTZDirection: Sendable, Equatable, CaseIterable {
    case up, down, left, right, upLeft, upRight, downLeft, downRight, zoomIn, zoomOut
    /// −1/0/+1 pair for the ISAPI continuous command. (Was `isaptiltPan` — R-67.)
    public var isapiPanTilt: (pan: Int, tilt: Int) { get }
}
public struct Position3DGesture: Sendable, Equatable { … }
public enum TileDrop: Sendable, Equatable { case cameraRef(CameraRefTransfer), tileAssignment(TileAssignmentTransfer) }
public struct TileAssignmentTransfer: Codable, Transferable, Sendable { … }
public struct CameraRefTransfer: Codable, Transferable, Sendable { … }
public extension UTType {
    static let vigilTileAssignment = UTType(exportedAs: "com.vigil.tile-assignment")
    static let vigilCameraRef = UTType(exportedAs: "com.vigil.camera-ref")
}
/// `@unchecked Sendable` #3 of 3 (R-52).
final class LatestFrameBox: @unchecked Sendable { … }
```

**Layout size forces the decode strategy:** ≤ **6** tiles get one `CAMetalLayer` each and may use
`AVSampleBufferDisplayLayer`; ≥ **7** tiles use a single-layer atlas, which requires pixel access and
therefore forces `VTDecompressionSession` for **every** tile in that layout. Hysteresis: promote at
`N ≥ 7`, demote at `N ≤ 5`; 6→7→6→7 produces exactly **2** changes, not 4. ASBDL is allowed only
when `zoom == 1 && adjustments.isIdentity && no privacy mask && progressive && SDR`. Backend
oscillation guard: more than 4 switches in 10 s locks Metal (the superset) for 5 s.

**Overlay ownership:** `VigilUI` draws timestamp, name chip, recording dot, status, focus ring,
hover chrome, stats HUD, PTZ indicator, the 3D drag rect and **≤ 32** motion boxes;
`VigilRender` draws privacy masks, **> 32** motion boxes and every wall-mode overlay (cap 48 boxes
per tile, keep the 48 largest, `+N` chip beyond). All overlay coordinates are **content-normalized
`[0,1]²` top-left against the cropped, SAR-corrected picture** — never the coded buffer — and always
come from `TileRenderState.coordinateMap`, never recomputed.

**SwiftUI must not wrap video in an offscreen pass:** no `.drawingGroup()`, `.opacity(<1)`,
`.shadow`, `.blur`, `.mask`, `.clipShape` or `.rotationEffect` on `VideoTile`/`VideoWall`. Corner
radius is an in-shader SDF via `TileRenderOptions.cornerRadii`; shadows go on sibling views.

### 4.11 `VigilUI` — design system and screens (macOS)

Depends on `VigilProtocols`, `VigilCore`, `VigilRender`. **Every top-level type carries an explicit
`@MainActor`** (R-40).

```swift
public enum VTheme {
    public enum Color { … }          // Layer, Text, Stroke, Semantic, Ident, Scrim
    public enum Typography { … }     // 9 steps + Mono track + Reserved widths
    public enum Space  { public static let hair: CGFloat = 2, xxs = 4, xs = 6, sm = 8,
                                          md = 12, lg = 16, xl = 20, xxl = 24, huge = 32, jumbo = 48 }
    public enum Radius { public static let xs: CGFloat = 4, sm = 6, md = 8, lg = 10, xl = 14, xxl = 20 }
    public enum Border { public static let thin: CGFloat = 1, focus = 2, selected = 2, recording = 3 }
    /// Control heights and the structural dimensions settled by R-34, R-35, R-68.
    public enum Metrics {
        public static let xs: CGFloat = 20, sm = 24, md = 28, lg = 32, xl = 40   // five, no others
        public static let sidebarWidth: CGFloat = 264, sidebarMin = 208, sidebarMax = 380
        public static let sidebarRail: CGFloat = 68
        public static let inspectorWidth: CGFloat = 320, inspectorMin = 288, inspectorMax = 440
        public static let toolbarHeight: CGFloat = 52
        public static let tileGutter: CGFloat = 2, wallGutter: CGFloat = 0, stageInset: CGFloat = 8
        public static let minHitTarget: CGFloat = 24
        /// Row heights are a SEPARATE group from control heights (R-37).
        public enum Row { public static let camera: CGFloat = 44, event = 36, channel = 32, settings = 28 }
    }
    public enum Icon { public static let xs: CGFloat = 11, sm = 12, md = 13, lg = 15, xl = 17, hero = 32 }
    public enum Elevation { … }      // e0…e3
    public enum Motion {
        public static let micro      = Animation.spring(response: 0.22, dampingFraction: 0.86, blendDuration: 0)
        public static let standard   = Animation.spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0)
        public static let expressive = Animation.spring(response: 0.50, dampingFraction: 0.70, blendDuration: 0)
        public static let snap       = Animation.spring(response: 0.16, dampingFraction: 1.00, blendDuration: 0)
        public static let glide      = Animation.spring(response: 0.42, dampingFraction: 0.95, blendDuration: 0.10)
        public static let rubber     = Animation.spring(response: 0.30, dampingFraction: 0.62, blendDuration: 0)
        public static let fadeIn     = Animation.timingCurve(0.00, 0.00, 0.20, 1.00, duration: 0.18)
        public static let fadeOut    = Animation.timingCurve(0.40, 0.00, 1.00, 1.00, duration: 0.12)
        public static let crossfade  = Animation.easeInOut(duration: 0.24)
        public static let emphasized = Animation.timingCurve(0.32, 0.72, 0.00, 1.00, duration: 0.28)
        public static let breathe    = Animation.easeInOut(duration: 1.0).repeatForever(autoreverses: true)
        public static let shimmer    = Animation.linear(duration: 1.15).repeatForever(autoreverses: false)
        public static let spin       = Animation.linear(duration: 0.90).repeatForever(autoreverses: false)
        public enum Delay { … }
        public static func resolved(_ a: Animation, reduced: Bool,
                                    fallback: Animation? = .easeInOut(duration: 0.12)) -> Animation?
        public static func stagger(_ index: Int) -> Double     // min(index, 12) × 0.018
    }
    public enum Health { … }
}
```

**`VTheme` is the only place literals exist.** Dynamic colours come from
`NSColor(name:dynamicProvider:)` because SwiftUI's `Color` has no light/dark initialiser.
Accent is Iris `#7B61FF` dark / `#5B44E0` light; the system accent is deliberately ignored.
Six layers: well `#000000`, canvas `#0B0C0F`, surface `#16181D`, raised `#1D2026`, overlay
`#252932`. Scrim ladder α 0.45 / 0.62 / 0.82, **inside the chip shape only**, never a full-tile
gradient (R-36). Radii are always `.continuous`. Every changing number is `monospacedDigit()` with
a reserved width. Three `matchedGeometryEffect` namespaces declared once in `MainWindowView` and
passed via `\.vNamespaces`; the stage namespace is keyed **by camera** (R-56).

```swift
@MainActor @Observable public final class AppModel { … }
public enum SidebarSelection: Hashable, Codable, Sendable { … }
public enum InspectorTab: String, CaseIterable, Codable, Sendable { … }
@MainActor @Observable public final class ShortcutStore { … }
public struct ShortcutSpec: Codable, Hashable, Sendable { … }
public enum ShortcutAction: String, Codable, CaseIterable, Sendable { … }
/// Normative ranking: matched char 12, adjacency (run−1)×18, word-start 25, first-char +40,
/// gap −min(60, gaps×2), tail −0.5×(len−last), title prefix +400, exact title +1000, acronym +350,
/// subtitle-only ×0.55, unavailable ×0.35, live camera +30, category weight
/// (camera 1.05, action 1.00, layout 0.95, preset 0.95, event 0.90, setting 0.85, help 0.75),
/// frecency min(120, 40·log2(1+count)) + 80·exp(−age/(7·86400)); **cutoff ≥ 30**; ≤ 32 backtracks;
/// order score ↓, title length ↑, localized title ↑, id ↑; cap 50 results;
/// **2 000 items in < 2 ms**, asserted by `PaletteRankingTests.testScoreThroughput`.
public enum FuzzyMatcher {
    public static func score(query: [UInt8], item: PaletteItem, now: Date,
                             usage: UsageStats) -> MatchResult?
}
public struct PaletteItem: Identifiable, Sendable { … }
public struct MatchResult: Sendable { public let score: Int; public let ranges: [Range<Int>] }
/// Degrades animation in four tiers when any stream drops below 60 fps or UI p99 exceeds 8 ms
/// at 120 Hz; recovers one tier per 3 s of clean frames. Publishes `\.vMotionTier`.
@MainActor @Observable public final class VMotionGovernor { … }
public enum VMotionTier: Int, Sendable, Comparable { case t0, t1, t2, t3 }
/// **All tile geometry transitions go through this** — still `CGImage` proxy, layer hidden, bounds
/// set once. Never per-frame layer-bounds mutation.
@MainActor public struct VTileTransitionProxy: ViewModifier { … }
```

The 28 `V*` components (`VButton` … `VProgressRing`) are enumerated in §5.

### 4.12 `Vigil` — the executable (macOS)

```swift
// Sources/Vigil/main.swift — top-level code, NOT @main (ARCHITECTURE §4.2 Rule 3, R-41)
#if os(macOS)
VigilApp.main()
#else
import Foundation
FileHandle.standardError.write(Data("Vigil requires macOS 14.0 or later.\n".utf8))
exit(EXIT_FAILURE)
#endif
```

```swift
struct VigilApp: App { … }              // no @main; scenes per UX.md §2
public enum SceneID {
    public static let main = "main", playback = "playback", discovery = "discovery"
    public static let wall = "wall", about = "about"
}
public struct PlaybackRequest: Codable, Hashable, Sendable { … }
struct VigilCommands: Commands { … }
enum AppEnvironment { static func bootstrap() -> CoreDependencies }
struct MenuBarExtraContent: View { … }
enum URLSchemeHandler { static func handle(_ url: URL, model: AppModel, deps: CoreDependencies) }
final class AppDelegate: NSObject, NSApplicationDelegate { … }
```

### 4.13 `VigilTestKit` — fixtures and doubles (pure, test-only)

Depends on `VigilProtocols`, `VigilRTSP`, `VigilRTP`, `VigilBitstream`. **Never linked by the app**;
`Scripts/lint.sh` asserts it appears only in test-target dependency lists.

```swift
public struct VirtualClock: MonotonicClock, DiscoveryClock, Sendable { … }   // explicit advance(by:)
public final class ManualClock: MonotonicClock, @unchecked Sendable { … }    // exempt from R-52
public struct RecordingLogger: LoggerProtocol, Sendable { … }                // records for assertions
public struct FixtureHTTPTransport: HTTPTransporting, Sendable {
    /// **Fails the test suite if any request carries an `Authorization` header or a
    /// `user:pass@host` form.** This is how R-31 is enforced mechanically.
    public var recordedRequests: [HTTPRequest] { get }
}
public struct MockDatagramChannel: DatagramChannel, Sendable { … }
public struct MockTCPProber: TCPProbing, Sendable { … }
public struct MockExchanger: ByteExchanging, Sendable { … }   // same credential assertion
public actor ScriptedRTSPPeer { … }        // fixture transcript + configurable chunking
public struct SyntheticCamera: Sendable { … }
public struct SyntheticRTPGenerator: Sendable { … }   // targets RTPTrackReceiver exactly
public struct SyntheticSPSBuilder: Sendable { … }     // BitWriter-based, for geometry tests
public enum Fixture {
    public static func data(_ name: String, in bundle: Bundle) throws -> Data
    public static func hex(_ name: String, in bundle: Bundle) throws -> Data
}
public enum GoldenVectors { … }            // RFC 1321 / 3174 / 6234 / 2617 tables
```

## 5. The complete file manifest

**233 rows.** Paths are exact. `LoC` is a budget, not a target — a row that lands at half its budget
is fine; a row that doubles it must be split at a `// MARK:` boundary into `Type+Feature.swift`.
**No file exceeds 600 lines** (§7.2).

**Waves.** W1 unblocks everything (RTSP, ISAPI and ONVIF all block on the crypto). W2 is the pure
protocol layer and is where the Linux test suite lives. W3–W6 are macOS and cannot be compiled in
the development container at all, so their rows are written against §3/§4 and type-checked on a Mac.

| Wave | Contents | Gate to leave the wave |
|---|---|---|
| **W1** | `VigilProtocols` + crypto | `swift build --product VigilPure` green; `VigilProtocolsTests` ≥ 120 tests green on Linux |
| **W2** | `VigilBitstream`, `VigilRTSP`, `VigilRTP`, `VigilISAPI`, `VigilDiscovery`, `VigilTestKit` + their tests | `swift test` green on Linux; `VigilPipelineTests` end-to-end green |
| **W3** | `VigilTransport`, `VigilVideo`, `VigilRender` | `swift build` green on macOS; `swift build` still green on Linux (empty modules) |
| **W4** | `VigilCore` | `VigilCoreTests` green on macOS |
| **W5** | `VigilUI` | `VigilUITests` green; token gallery renders |
| **W6** | `Vigil`, `Scripts/`, CI, entitlements, `Info.plist` | `Scripts/build-app.sh` produces a launching `Vigil.app`; R1 acceptance run |

Rows are ordered so an agent can take a contiguous block. `Deps` lists the *other rows in this
manifest* a row needs, not the module dependency (which §1 fixes).

### 5.1 Repository root — W1 (scaffolding) and W6 (build)

| Path | Responsibility | LoC | Deps | Wave |
|---|---|---|---|---|
| `Package.swift` | **Exists and is green. §6 reproduces it. Do not modify** without amending §6 in the same commit | 265 | — | W1 ✅ |
| `.gitattributes` | **Exists.** `*.rtsp`/`*.sdp`/`*.rtsp.txt` marked `-text` so CRLF survives checkout | 4 | — | W1 ✅ |
| `.gitignore` | **Exists.** `.build*`, `dist/`, `*.xcodeproj` | 12 | — | W1 ✅ |
| `.swift-format` | Formatter config: 110 columns, 4-space indent, no tabs | 40 | — | W1 |
| `Package.resolved` | Committed, empty pin list — the machine-checkable proof of "zero dependencies" | 6 | — | W6 |
| `README.md` | What Vigil is, how to build, the two build worlds | 120 | — | W6 |
| `LICENSE` | — | 20 | — | W6 |
| `Info.plist` | §2 R-39: bundle keys, `NSLocalNetworkUsageDescription`, `NSBonjourServices` `["_rtsp._tcp", "_http._tcp", "_axis-video._tcp"]`, `NSAppTransportSecurity/NSAllowsLocalNetworking`, `CFBundleURLTypes` (`vigil`), 3 `UTExportedTypeDeclarations` | 150 | — | W6 |
| `Vigil.entitlements` | Sandboxed shipping: app-sandbox, network.client, **network.server**, developer.networking.multicast, files.user-selected.read-write, device.audio-input | 40 | — | W6 |
| `Vigil-Dev.entitlements` | Unsandboxed dev build; adds `get-task-allow`. Never distributed | 20 | — | W6 |
| `Vigil-nomulticast.entitlements` | Fallback when no multicast provisioning profile is available | 30 | — | W6 |
| `project.yml` | XcodeGen input; **one** target that links the local package. No `.pbxproj` is ever committed | 45 | — | W6 |
| `Scripts/build-app.sh` | The 15-step bundle contract. `set -euo pipefail`. Emits `build-manifest.json` | 320 | — | W6 |
| `Scripts/lint.sh` | Import allow-list per target; banned patterns (`!`, `try!`, `as!`, `print`, `TODO`, `CryptoKit`, `DispatchSemaphore`, `nonisolated(unsafe)`, `@preconcurrency`); `@MainActor` check for `VigilUI`; `@unchecked Sendable` count ≤ 3 | 260 | — | W6 |
| `Scripts/test-linux.sh` | Runs the pure suite; **fails if a pure target reports zero tests** | 70 | — | W2 |
| `Scripts/test-macos.sh` | Full suite + coverage | 60 | — | W6 |
| `Scripts/coverage.sh` | Floors: 90 % pure, 70 % macOS | 70 | — | W6 |
| `Scripts/bench.sh` | Signpost-driven latency/CPU benchmark; asserts the §19 gates | 180 | — | W6 |
| `Scripts/gen-shader-source.swift` | Regenerates `ShaderSource.swift` from the `.metal` files (R-38) | 90 | — | W3 |
| `Scripts/gen-xcode.sh` | `xcodegen generate` | 25 | — | W6 |
| `Scripts/make-icon.sh` | `iconutil` from `AppIcon.iconset` | 30 | — | W6 |
| `.github/workflows/linux.yml` | `swift:6.1-noble`: `--product VigilPure`, `--product VigilTestKit`, full build, `swift test --parallel`, `test-linux.sh` | 45 | — | W6 |
| `.github/workflows/macos.yml` | `macos-14`: build, test+coverage, lint, `build-app.sh`, `bench.sh --smoke` | 50 | — | W6 |
| `.github/workflows/lint.yml` | `swift format lint --strict` + `Scripts/lint.sh` | 30 | — | W6 |
| `docs/ACCEPTANCE.md` | The R1 checklist: launch → visible moving picture in ≤ 10 s, password only | 180 | — | W6 |

### 5.2 `Sources/VigilProtocols` — W1 (40 files, ~4 400 LoC)

Everything here is §3. This is the wave that unblocks the whole project; it should be done by **two
agents in parallel** (crypto + everything else) and merged before W2 starts.

| Path | Responsibility | LoC | Deps | Wave |
|---|---|---|---|---|
| `Time/MediaInstant.swift` | `MediaInstant`, `Duration` helpers | 110 | — | W1 |
| `Time/Clocks.swift` | `MonotonicClock`, `WallClock`, `SystemMonotonicClock`, `SystemWallClock` | 120 | MediaInstant | W1 |
| `Time/MediaTimestamp.swift` | `MediaTimestamp` + 128-bit rescale and compare | 230 | — | W1 |
| `Time/RandomSource.swift` | `RandomSource` + extension, `SystemRandomSource`, `SplitMix64RandomSource` | 130 | — | W1 |
| `Media/Codecs.swift` | `VideoCodec`, `AudioCodec`, `MediaCodec` | 140 | — | W1 |
| `Media/ParameterSets.swift` | `ParameterSets` + `fingerprint` | 110 | Codecs | W1 |
| `Media/EncodedFrame.swift` | `EncodedFrame`, `FrameDropClass`, `AudioFormatInfo` | 190 | ParameterSets, MediaTimestamp | W1 |
| `Media/FrameGeometry.swift` | `FrameGeometry`, `ColorInfo`, `FieldOrder`, `Resolution` | 260 | — | W1 |
| `Media/VideoFormatInfo.swift` | `VideoFormatInfo` + passthroughs + `isDecoderCompatible` | 190 | FrameGeometry, Codecs | W1 |
| `Streams/StreamQuality.swift` | `StreamQuality`, `StreamKey`, `RTSPTransportKind`, `LatencyPreset` | 170 | Identifiers | W1 |
| `Streams/DecodePolicy.swift` | `DecodeMode`, `StreamPriority`, `DecodeCost`, `DecodeAdmitting`, `DecodeLease`, `AdmissionResult`, `BudgetChange`, `BudgetSnapshot`, `DenialReason`, `BudgetPressure` | 300 | StreamQuality, FrameGeometry | W1 |
| `Streams/TilePolicy.swift` | `TileClass`, `TileContext`, `TilePolicy`, `StreamChoice` — the class A–E table, pure | 220 | StreamQuality, Resolution | W1 |
| `Stats/StreamStatistics.swift` | `StreamStatistics` (31 fields) | 140 | — | W1 |
| `Stats/RingBuffer.swift` | `RingBuffer<Element>` | 120 | — | W1 |
| `Errors/VigilError.swift` | `VigilFailure`, `ErrorSeverity`, `RetryDisposition`, `VigilError`, `vigilRequire` | 200 | DomainErrors | W1 |
| `Errors/DomainErrors.swift` | **All eleven domain enums** (R-10). The largest W1 file; split into `DomainErrors+Protocol.swift` / `+Media.swift` / `+App.swift` if it exceeds 600 | 560 | — | W1 |
| `Errors/DiagnosticCodes.swift` | The `VG-<DOMAIN>-NNNN` tables and the `diagnosticCode`/`userMessage`/`userRemedy` mappings | 420 | DomainErrors | W1 |
| `Logging/LoggerProtocol.swift` | `LogLevel`, `LogCategory`, `LogEvent`, `LoggerProtocol` + level extensions, `NullLogger` | 170 | — | W1 |
| `Logging/RateLimitedLogger.swift` | Decorator: N per key per window + suppression summary | 130 | LoggerProtocol, Clocks | W1 |
| `Logging/Redact.swift` | `Redact` — the one redaction implementation | 260 | — | W1 |
| `Bytes/ByteReader.swift` | `ByteReader` | 230 | DomainErrors | W1 |
| `Bytes/ByteWriter.swift` | `ByteWriter` incl. `lengthPrefixed32` | 170 | — | W1 |
| `Bytes/BitReader.swift` | `BitReader` — verbatim from §3.11 | 130 | DomainErrors | W1 |
| `Bytes/BitWriter.swift` | `BitWriter` incl. `ue`/`se`/`rbspTrailingBits` | 130 | — | W1 |
| `Crypto/MD5.swift` | RFC 1321, streaming, hex helper | 170 | — | W1 |
| `Crypto/SHA1.swift` | FIPS 180-4, streaming | 150 | — | W1 |
| `Crypto/SHA256.swift` | FIPS 180-4, streaming | 180 | — | W1 |
| `Crypto/Base64.swift` | Padding-, whitespace- and URL-safe-tolerant decode; `decodeList` for `sprop-*` | 180 | — | W1 |
| `Crypto/CRC32.swift` | IEEE 802.3, table-driven | 70 | — | W1 |
| `Net/IPv4Address.swift` | `IPv4Address` | 160 | — | W1 |
| `Net/MACAddress.swift` | `MACAddress` with four separator forms | 150 | — | W1 |
| `Net/IPv4Subnet.swift` | `IPv4Subnet`, `IPv4HostSequence` | 180 | IPv4Address | W1 |
| `Net/HostPolicy.swift` | `HostPolicy`, `HostClass` — the LAN-only egress gate | 150 | IPv4Address, DomainErrors | W1 |
| `Net/Endpoints.swift` | `ISAPIEndpoint`, `RTSPEndpoint` | 140 | DomainErrors | W1 |
| `Net/HTTP.swift` | `HTTPHeaders`, `HTTPRequest`, `HTTPResponse`, `HTTPLane`, `HTTPTransporting`, `HTTPUploadHandle` | 220 | Endpoints | W1 |
| `Net/Credential.swift` | `Credential`, `CredentialRef` | 90 | — | W1 |
| `Identity/Identifiers.swift` | `CameraID`, `GroupID`, `LayoutID`, `EventID`, `ClipID`, `BookmarkID`, `WindowID` | 190 | — | W1 |
| `Identity/DeviceIdentifiers.swift` | `ChannelID`, `StreamingChannelID`, `TrackID` | 160 | StreamQuality | W1 |
| `Identity/DeviceQuirks.swift` | `DeviceQuirks` — 28 flags + `merge` | 190 | — | W1 |
| `Identity/EventKind.swift` | `EventKind` + `init(isapiEventType:)`, `EventSeverity` | 200 | — | W1 |
| `Concurrency/Broadcaster.swift` | `Broadcaster<Element>` | 130 | — | W1 |
| `Concurrency/ConcurrencyLimiter.swift` | `ConcurrencyLimiter` FIFO permit gate | 150 | StreamPriority | W1 |

### 5.3 `Sources/VigilBitstream` — W2 (22 files, ~4 100 LoC)

| Path | Responsibility | LoC | Deps | Wave |
|---|---|---|---|---|
| `NAL/H264NALType.swift` | Type table 0–31 + `isVCL`, `isIDR`, `isParameterSet` | 130 | — | W2 |
| `NAL/H265NALType.swift` | Type table 0–63 + IRAP 16–23, RASL, RADL | 150 | — | W2 |
| `NAL/NALHeader.swift` | `NALHeader`, `NALUnitRef` | 140 | — | W2 |
| `NAL/Limits.swift` | Security bounds: max NAL 4 MiB, max sets 8, max scaling-list entries | 60 | — | W2 |
| `Convert/AnnexB.swift` | Start-code scan, `enumerateNALUnits`, `toLengthPrefixed`, `fromLengthPrefixed` | 260 | Limits | W2 |
| `Convert/LengthPrefixed.swift` | `enumerate`, `validate`, `append(nal:to:)` — the one function `VigilRTP` uses | 140 | ByteWriter | W2 |
| `Convert/RBSP.swift` | `unescape`, `escape`, `escapeByteCount` | 160 | — | W2 |
| `Convert/RBSPBitReader.swift` | Exp-Golomb `ue`/`se`, `moreRBSPData`, trailing-bit check | 230 | BitReader, RBSP | W2 |
| `H264/H264SPS.swift` | The parsed model | 170 | — | W2 |
| `H264/H264SPSParser.swift` | ITU-T H.264 §7.3.2.1, full, incl. scaling lists, VUI, cropping | 420 | RBSPBitReader, H264SPS | W2 |
| `H264/H264PPS.swift` | Model + minimal parse (§7.3.2.2) | 150 | RBSPBitReader | W2 |
| `H265/ProfileTierLevel.swift` | §7.3.3, incl. the 48-bit constraint flags | 190 | RBSPBitReader | W2 |
| `H265/H265VPS.swift` | Model + parse (§7.3.2.1) | 160 | ProfileTierLevel | W2 |
| `H265/H265SPS.swift` | Model | 190 | — | W2 |
| `H265/H265SPSParser.swift` | §7.3.2.2.1, full, incl. short-term RPS, VUI, conformance window | 460 | ProfileTierLevel, H265SPS | W2 |
| `H265/H265PPS.swift` | Model + minimal parse for `parallelismType` | 130 | RBSPBitReader | W2 |
| `Format/VideoFormatInfo+Parse.swift` | `VideoFormatInfo.init(_ sps:)` for both codecs, incl. the fps rules and SAR table | 300 | H264SPS, H265SPS | W2 |
| `Format/SampleAspectRatio.swift` | The `aspect_ratio_idc` → `(w, h)` table | 70 | — | W2 |
| `Records/AVCDecoderConfigurationRecord.swift` | Build + parse + serialize | 250 | H264SPS | W2 |
| `Records/HEVCDecoderConfigurationRecord.swift` | Build + parse + serialize, `NALArray` | 300 | H265SPS, ProfileTierLevel | W2 |
| `SEI/SEI.swift` | `enumerate`, `parseRecoveryPoint`, `parsePictureTiming` | 220 | RBSPBitReader | W2 |
| `Gate/SliceHeader.swift` | `isFirstSliceOfPicture`, `sliceType` — **the AU-boundary predicate** | 170 | NALHeader, RBSPBitReader | W2 |
| `Gate/AccessUnitSummary.swift` | `AccessUnitSummary`, `IRAPGate`, RASL-after-CRA drop | 210 | SliceHeader | W2 |
| `Gate/ParameterSetStore.swift` | Merge-not-replace, `ParameterSetChange`, format-change detection | 210 | VideoFormatInfo+Parse | W2 |

### 5.4 `Sources/VigilRTSP` — W2 (21 files, ~4 300 LoC)

| Path | Responsibility | LoC | Deps | Wave |
|---|---|---|---|---|
| `Model/RTSPMethod.swift` | `RTSPMethod`, `RTSPStatus` (30 named codes) | 190 | — | W2 |
| `Model/RTSPHeaders.swift` | Ordered case-insensitive container, ASCII-only folding (`İ` ≠ `i`) | 210 | — | W2 |
| `Model/RTSPMessage.swift` | `RTSPRequest`, `RTSPResponse`, `RTSPIncoming`, byte-exact serializer | 280 | RTSPHeaders | W2 |
| `Model/RTSPURL.swift` | Hand-written URL value type; `requestLineForm`, credential-free `description` | 230 | Endpoints | W2 |
| `Wire/RTSPHeaderScanner.swift` | Token / quoted-string / parameter-list primitives | 190 | — | W2 |
| `Wire/RTSPWireDecoder.swift` | Incremental parse + `$` demux + resync; every limit enforced | 480 | RTSPHeaderScanner | W2 |
| `Wire/RTSPRequestBuilder.swift` | Canonical request emission, header order, `Content-Length` rules | 210 | RTSPMessage | W2 |
| `Auth/RTSPChallenge.swift` | `WWW-Authenticate` parsing; two challenges in one header; comma in `realm` | 200 | RTSPHeaderScanner | W2 |
| `Auth/RTSPAuthenticator.swift` | Basic + Digest; `nc`/`cnonce`/`opaque`/`stale`; RFC 2069 no-qop first-class; **2-attempt cap** | 300 | MD5, RTSPChallenge | W2 |
| `SDP/SDPDocument.swift` | Line model | 150 | — | W2 |
| `SDP/SDPParser.swift` | Lenient parser: bare LF, trailing NUL, unknown attributes, non-UTF-8 `s=` | 340 | SDPDocument, Base64 | W2 |
| `SDP/SDPMediaDescription.swift` | `rtpmap`/`fmtp`(lower-cased keys)/`control`, `sprop-*` decode | 260 | Base64 | W2 |
| `SDP/ControlURLResolver.swift` | `Content-Base` → `Content-Location` → request URI, append-with-slash merge | 190 | RTSPURL | W2 |
| `Headers/TransportHeader.swift` | Parse + build; interleaved, unicast, multicast, `mode`, `ssrc` | 230 | RTSPHeaderScanner | W2 |
| `Headers/SessionHeader.swift` | Opaque id + `timeout` | 90 | — | W2 |
| `Headers/RTPInfoHeader.swift` | `url`/`seq`/`rtptime`; absolute, relative and quoted forms | 170 | RTSPURL | W2 |
| `Headers/RangeHeader.swift` | `npt`/`clock`/`smpte`, `Scale`, `Rate-Control` | 260 | — | W2 |
| `Machine/RTSPSessionConfig.swift` | Config + `RTSPTimerID` + `RTSPCloseReason` | 150 | — | W2 |
| `Machine/RTSPAction.swift` | `RTSPAction`, `RTSPLogEvent`, `RTSPTrack`, `RTSPTrackTiming`, `RTSPSessionDescription` | 280 | — | W2 |
| `Machine/RTSPCommand.swift` | `RTSPCommand`, `RTSPSessionState` | 130 | — | W2 |
| `Machine/RTSPSessionMachine.swift` | The state machine + transport ladder + probe support | 580 | everything above | W2 |
| `Machine/RTSPSessionMachine+Playback.swift` | Seek, scale, frame-step, `ANNOUNCE`/`Notice`, backpressure | 320 | RTSPSessionMachine | W2 |

### 5.5 `Sources/VigilRTP` — W2 (24 files, ~4 400 LoC)

`SliceHeaderPeek.swift` is **deleted** by R-01; use `VigilBitstream.SliceHeader`.

| Path | Responsibility | LoC | Deps | Wave |
|---|---|---|---|---|
| `Packet/RTPPacket.swift` | RFC 3550 §5.1 header parse, padding, CSRC, extension | 230 | ByteReader | W2 |
| `Packet/RTPHeaderExtension.swift` | One-byte and two-byte header extensions | 120 | RTPPacket | W2 |
| `Packet/SequenceNumber.swift` | 16-bit modular compare, extended (unwrapped) sequence | 130 | — | W2 |
| `Packet/TimestampUnwrapper.swift` | 32-bit RTP timestamp → monotonic `Int64` before any `MediaTimestamp` | 150 | — | W2 |
| `Track/RTPTrackFormat.swift` | Format struct + payload-type binding + factory | 240 | Codecs | W2 |
| `Track/RTPTrackReceiver.swift` | The surface `VigilTransport` drives | 420 | everything below | W2 |
| `Track/Depacketizer.swift` | Protocol, `DepacketizerOutput`, `AnyDepacketizer` enum for the hot path | 180 | — | W2 |
| `Track/AccessUnitBuilder.swift` | AU assembly, 4-byte length prefixing, corruption marking | 260 | LengthPrefixed | W2 |
| `Track/BoundaryPolicy.swift` | **Never trust the marker bit**; learned marker reliability | 210 | SliceHeader | W2 |
| `H264/H264Depacketizer.swift` | RFC 6184: single NAL, STAP-A, FU-A. No MTAP | 340 | AccessUnitBuilder | W2 |
| `H265/H265Depacketizer.swift` | RFC 7798: single NAL, AP, FU. No PACI, no interleaved mode | 360 | AccessUnitBuilder | W2 |
| `Audio/AACDepacketizer.swift` | RFC 3640 `mode=AAC-hbr`; AU-headers-length, sizeLength/indexLength | 280 | AudioSpecificConfig | W2 |
| `Audio/AudioSpecificConfig.swift` | ASC parse from bytes and from SDP `config=` hex | 200 | BitReader | W2 |
| `Audio/ADTS.swift` | ADTS header build, for debug dumps and fixtures only | 110 | — | W2 |
| `Audio/G711.swift` | µ-law and A-law tables, decode and encode, decoded in the pure layer | 190 | — | W2 |
| `Audio/G726.swift` | 32 kbit/s (4-bit) only | 210 | — | W2 |
| `Jitter/ReorderBuffer.swift` | `.passthrough` for TCP; UDP 128/60 ms adaptive → 512/200 ms above 1 % loss | 280 | SequenceNumber, RingBuffer | W2 |
| `Jitter/GapPolicy.swift` | Gap detection, keyframe-request throttling, drop-to-keyframe | 170 | — | W2 |
| `RTCP/RTCPPacket.swift` | SR, RR, SDES, BYE, APP models | 190 | — | W2 |
| `RTCP/RTCPParser.swift` | Compound-packet parse, strict length validation | 220 | RTCPPacket | W2 |
| `RTCP/RTCPReportBuilder.swift` | RR generation on the RFC 3550 interval rules | 210 | RTPSourceState | W2 |
| `RTCP/RTPSourceState.swift` | Per-SSRC loss, jitter (A.8), sequence-cycle state | 230 | SequenceNumber | W2 |
| `Clock/PresentationClock.swift` | Min-filter + PLL. **Not** used for live pacing | 240 | TimestampUnwrapper | W2 |
| `Stats/StatisticsAccumulator.swift` | The fixed EWMA constants; writes `StreamStatistics` | 230 | StreamStatistics | W2 |

### 5.6 `Sources/VigilISAPI` — W2 (30 files, ~6 200 LoC)

| Path | Responsibility | LoC | Deps | Wave |
|---|---|---|---|---|
| `XML/XMLNode.swift` | `XMLNode`, path compilation and memoisation | 300 | — | W2 |
| `XML/ISAPIDocument.swift` | Parser: 8 MiB / 64-level caps, **XXE off**, explicit stack, truncation-tolerant | 320 | XMLNode | W2 |
| `XML/XMLValue.swift` | Lenient accessors, the bool vocabulary, clamped ints, required variants | 280 | — | W2 |
| `XML/XMLBuilder.swift` | Escapes `& < > " '` only; no pretty-printing; element order preserved | 170 | — | W2 |
| `XML/ISAPITime.swift` | Hand-rolled ASCII date scanner (no `DateFormatter`), POSIX-inverted zones | 240 | — | W2 |
| `Client/ISAPIClient.swift` | The actor: verbs, XML convenience, lanes, coalescing, retry table | 470 | HTTPTransporting | W2 |
| `Client/RequestGate.swift` | FIFO permit actor; PTZ may over-subscribe by exactly one | 140 | — | W2 |
| `Client/DigestStore.swift` | Nonce cache, `nc` per (realm, nonce), pre-emptive auth | 230 | MD5 | W2 |
| `Client/DigestChallenge.swift` | Parse; RFC 2069 no-qop first-class | 160 | — | W2 |
| `Client/ServerTrust.swift` | `ServerTrustEvaluating`, `ServerTrustDecision`, the TOFU SPKI rule | 90 | — | W2 |
| `Client/URLSessionHTTPTransport.swift` | Four ephemeral sessions, one per lane; delegate state in an actor | 420 | HTTP | W2 |
| `Client/ResponseValidation.swift` | The four-step `validate`; `ResponseStatus` extraction; §9.3 mapping | 300 | ResponseStatus | W2 |
| `Model/ResponseStatus.swift` | `ResponseStatus`, the 7 status codes, sub-status vocabulary | 150 | — | W2 |
| `Endpoints/HikvisionURL.swift` | The **single** RTSP path builder + `RTSPPathCandidate` ladder | 200 | DeviceIdentifiers | W2 |
| `Endpoints/DeviceIdentity.swift` | `deviceInfo`, `status`, `time`, `capabilities`, `userCheck`, `networkInterfaces` | 420 | XML | W2 |
| `Endpoints/ChannelInventory.swift` | `InputProxy/channels` + `Video/inputs/channels`, paging at 64 | 320 | XML | W2 |
| `Endpoints/StreamingChannels.swift` | Config read + **read-modify-write** PUT + re-GET; wire units | 400 | XMLBuilder | W2 |
| `Endpoints/Snapshots.swift` | `/picture`, SOI sniffing, size query, per-device rate cap | 180 | — | W2 |
| `Endpoints/PTZController.swift` | Continuous + 400 ms keep-alive + triple zero-stop; presets 33–105 blocked | 460 | XMLBuilder | W2 |
| `Endpoints/ImageSettings.swift` | Colour, sharpness, WDR, IR-cut, defaults | 300 | XMLBuilder | W2 |
| `Endpoints/RecordSearch.swift` | `POST /ContentMgmt/search`, one `searchID`, `searchResultPostion`, `MORE` paging | 380 | XMLBuilder | W2 |
| `Endpoints/StorageInfo.swift` | Volumes, capacity in decimal MB, health | 160 | XML | W2 |
| `Endpoints/PlaybackLocator.swift` | Rewrites scheme/host/port, keeps path+query **verbatim** | 130 | — | W2 |
| `Endpoints/TwoWayAudio.swift` | Channel list, open/close, chunked upload session | 300 | HTTPUploadHandle | W2 |
| `Events/MultipartStreamParser.swift` | Boundary sniffing, bare-LF tolerance, fixed memory budget | 330 | — | W2 |
| `Events/AlertStreamMonitor.swift` | **One per device**; heartbeat suppression; 403 ⇒ `.unsupported`; terminal `.authFailed` | 340 | MultipartStreamParser | W2 |
| `Events/EventNotificationAlert.swift` | The wire model + region magnitude sniffing | 280 | EventKind | W2 |
| `Events/MotionDetection.swift` | Grid read/write, `gridMap` origin | 240 | XMLBuilder | W2 |
| `Session/ISAPIDeviceSession.swift` | The device actor: cache TTLs, negative-capability cache, memoised alert stream | 500 | all endpoints | W2 |
| `Session/QuirkResolver.swift` | The firmware matrix; the **four** consultation points | 260 | DeviceQuirks | W2 |

### 5.7 `Sources/VigilDiscovery` — W2 (22 files, ~4 300 LoC)

| Path | Responsibility | LoC | Deps | Wave |
|---|---|---|---|---|
| `Model/DiscoveredDevice.swift` | `DiscoveredDevice`, `DeviceIdentity`, `DeviceFieldKey`, `FieldStamp`, derived properties | 380 | IPv4Address, MACAddress | W2 |
| `Model/DiscoveryEnums.swift` | `DiscoverySource` (+`trust`), `DeviceVendor`, `DeviceClass`, `ActivationState`, `Reachability` | 240 | — | W2 |
| `Model/ONVIFScopes.swift` | Scope URI model + percent decoding | 130 | — | W2 |
| `Model/DiscoveryConfiguration.swift` | Config, port tiers, timeouts, budgets | 230 | — | W2 |
| `Model/DiscoveryEvents.swift` | `DiscoveryEvent`, `DiscoveryPhase`, `DiscoveryProgress`, `PhaseSummary`, `DiscoverySummary` | 300 | — | W2 |
| `Model/DiscoveryDiagnostic.swift` | 15 cases + `userFacingMessage` + `Severity` | 240 | — | W2 |
| `Transport/Protocols.swift` | The seven injected protocols + `DiscoveryEnvironment` + `MulticastGroupSpec` + `InboundDatagram` | 280 | — | W2 |
| `Transport/NetworkInterfaceInfo.swift` | `NetworkInterfaceInfo`, `ARPEntry`, `TCPProbeOutcome`, `POSIXCode` | 160 | IPv4Subnet | W2 |
| `SADP/SADPCodec.swift` | Probe encode, decode, `SADPDecodeResult`, opaque-payload entropy | 380 | XML-lite | W2 |
| `SADP/SADPProbeMatch.swift` | The wire model + `splitSerial` | 260 | — | W2 |
| `SADP/SADPXMLReader.swift` | Tiny lenient XML reader (SADP only; not the ISAPI one) | 220 | — | W2 |
| `WSDiscovery/WSDiscoveryCodec.swift` | SOAP probe build, ProbeMatches/Hello/Bye decode, correlation | 420 | — | W2 |
| `WSDiscovery/WSDProbeMatch.swift` | Model + scope parsing + XAddrs | 200 | ONVIFScopes | W2 |
| `Sweep/IPv4HostOrder.swift` | Van der Corput ordering, gateway/`.64` priming | 150 | IPv4Subnet | W2 |
| `Sweep/SweepPlanner.swift` | Interface filtering, the **/16 hard guard**, /16–/21 narrowing | 320 | IPv4HostOrder | W2 |
| `Sweep/ARPTableDecoder.swift` | `rt_msghdr` walk with bounds checks; `arp -an` text fallback | 260 | ARPEntry | W2 |
| `Fingerprint/StartLineHeaderScanner.swift` | ~70-line lenient scanner; **deliberately not `VigilRTSP`** | 180 | — | W2 |
| `Fingerprint/FingerprintCodec.swift` | RTSP `OPTIONS`, ISAPI `deviceInfo`, `/` requests + classification | 340 | StartLineHeaderScanner | W2 |
| `Fingerprint/VendorClassifier.swift` | The confidence-delta table, OUI seed lookup | 260 | — | W2 |
| `Merge/IdentityNormalizer.swift` | Serial and ONVIF-UUID normalisation rules | 170 | — | W2 |
| `Merge/MergeEngine.swift` | Union-find over the identity ladder; field precedence; confidence | 420 | IdentityNormalizer | W2 |
| `Coordinator/DiscoveryCoordinator.swift` | Phase orchestration, budgets, deadline, cancellation | 480 | everything above | W2 |
| `Resources/oui-seed.json` | `{"c42f90": "hikvision", …}` — declared as `.copy("Resources")` if used; **if added, the directory must exist from the same commit** | — | — | W2 |

### 5.8 `Sources/VigilTestKit` — W2 (13 files, ~2 400 LoC)

| Path | Responsibility | LoC | Deps | Wave |
|---|---|---|---|---|
| `Doubles/VirtualClock.swift` | `MonotonicClock` + `DiscoveryClock`, explicit `advance(by:)` | 160 | Clocks | W2 |
| `Doubles/ManualClock.swift` | Lock-based class clock for concurrent tests; exempt from R-52 | 90 | Clocks | W2 |
| `Doubles/RecordingLogger.swift` | Records every `LogEvent` for assertions | 110 | LoggerProtocol | W2 |
| `Doubles/FixtureHTTPTransport.swift` | Route table + recorded requests; **fails on any credential** | 260 | HTTPTransporting | W2 |
| `Doubles/MockDatagramChannel.swift` | Scripted `(delay, datagram)` replay + send log | 180 | DatagramChannel | W2 |
| `Doubles/MockTCPProber.swift` | `[IPv4Address: [UInt16: TCPProbeOutcome]]` with artificial latency | 110 | TCPProbing | W2 |
| `Doubles/MockExchanger.swift` | Table-driven; **fails on any credential** | 130 | ByteExchanging | W2 |
| `Synthetic/ScriptedRTSPPeer.swift` | Fixture transcript, digest recomputation, configurable chunking | 340 | VigilRTSP | W2 |
| `Synthetic/SyntheticCamera.swift` | Full RTSP + RTP script generator, per-firmware quirk profiles | 420 | ScriptedRTSPPeer | W2 |
| `Synthetic/SyntheticRTPGenerator.swift` | Targets `RTPTrackReceiver` exactly: H.264/H.265/AAC/G.711 | 380 | VigilRTP | W2 |
| `Synthetic/SyntheticSPSBuilder.swift` | `BitWriter`-built SPS/PPS/VPS with chosen geometry and VUI | 260 | BitWriter | W2 |
| `Harness/Fixture.swift` | `data(_:)`, `hex(_:)`, comment-stripping hex parser | 90 | — | W2 |
| `Harness/GoldenVectors.swift` | RFC 1321 / 3174 / 6234 / 2617 tables + the Exp-Golomb table | 220 | — | W2 |

### 5.9 `Sources/VigilTransport` — W3 (18 files, ~3 400 LoC)

| Path | Responsibility | LoC | Deps | Wave |
|---|---|---|---|---|
| `RTSPConnection.swift` | The actor: connect, atomic write, `pauseReads`/`resumeReads`, timers | 460 | RTSPSessionMachine | W3 |
| `RTSPConnection+Timers.swift` | `RTSPTimerID` → cancellable `Task`; one timer per id | 160 | RTSPConnection | W3 |
| `UDPMediaSocketPair.swift` | Even/odd ports 51000–51998, RTP + RTCP | 300 | — | W3 |
| `MulticastResponder.swift` | `NWListener` on 37020 / 3702 | 220 | — | W3 |
| `RTPTrackFormatAdapter.swift` | `SDPMediaDescription` → `RTPTrackFormat`, `RTSPTrackTiming` → seed | 90 | VigilRTP | W3 |
| `TLS/ServerTrustEvaluator.swift` | TOFU SPKI-256 leaf pinning shared by RTSP and ISAPI | 280 | SHA256 | W3 |
| `TLS/CertificateSummary.swift` | Chain summary for the UI; `SecTrustEvaluateWithError` diagnostics only | 160 | — | W3 |
| `FileDescriptorBudget.swift` | `setrlimit` to `min(4096, rlim_max)` at launch | 70 | — | W3 |
| `EgressGuard.swift` | Wraps every socket creation in `HostPolicy.requirePermitted` | 110 | HostPolicy | W3 |
| `Discovery/MulticastDatagramChannel.swift` | `NWConnectionGroup`, `disableUnicast: false`, hop limit 1, port reuse | 340 | Protocols | W3 |
| `Discovery/UnicastDatagramChannel.swift` | Ephemeral-port unicast fallback | 200 | Protocols | W3 |
| `Discovery/TCPConnectProber.swift` | `NWConnection` probe; `.waiting` is terminal; POSIX classification | 230 | Protocols | W3 |
| `Discovery/NWByteExchanger.swift` | One request/response; TLS verify-block accepts anything (fingerprint only) | 250 | Protocols | W3 |
| `Discovery/SystemInterfaceEnumerator.swift` | `getifaddrs` + `SCNetworkInterface` wireless detection | 200 | Protocols | W3 |
| `Discovery/SystemARPTableReader.swift` | `sysctl` route dump → `ARPTableDecoder` | 140 | ARPTableDecoder | W3 |
| `Discovery/BonjourBrowser.swift` | `NWBrowser` over the three service types | 190 | Protocols | W3 |
| `Discovery/EntitlementInspector.swift` | `SecCode` entitlement read; local-network permission heuristic | 180 | — | W3 |
| `Discovery/LiveDiscoveryEnvironment.swift` | Assembles the eleven injected values | 90 | all of `Discovery/` | W3 |

### 5.10 `Sources/VigilVideo` — W3 (36 files, ~6 800 LoC)

| Path | Responsibility | LoC | Deps | Wave |
|---|---|---|---|---|
| `Support/VideoFrame.swift` | `VideoFrame` (`@unchecked Sendable` #2) | 130 | VideoFormatInfo | W3 |
| `Support/VideoSink.swift` | The protocol + no-op defaults, `StreamEndReason`, `FrameDropReason`, `PacingMode` | 170 | VideoFrame | W3 |
| `Support/DecodeSinkBox.swift` | The VT-callback → `AsyncStream` bridge (`@unchecked Sendable` #1) | 140 | — | W3 |
| `Format/FormatDescriptionFactory.swift` | **The single CoreMedia conversion site**; `withParameterSetPointers` | 320 | ParameterSets | W3 |
| `Format/FormatOverrides.swift` | `avcC`/`hvcC` atom rebuild for colour and aperture overrides | 240 | Records | W3 |
| `Format/FormatChangeCoordinator.swift` | Compatible vs incompatible; `generation`; the **no black flash** rule | 280 | ParameterSetStore | W3 |
| `Sample/SampleBufferBuilder.swift` | `CMBlockBuffer` + `CMSampleBuffer` + attachments | 300 | FormatDescriptionFactory | W3 |
| `Sample/SampleAttachments.swift` | `DisplayImmediately`, `NotSync`, `DoNotDisplay` | 130 | — | W3 |
| `Sample/TimestampConversion.swift` | `MediaTimestamp` ↔ `CMTime`; duration estimation chain | 150 | MediaTimestamp | W3 |
| `Decode/DecodePipeline.swift` | The actor: submit, modes, strategy, statistics | 520 | everything below | W3 |
| `Decode/DecodePipeline+Audio.swift` | Audio submission, routing, decoder lifetime | 260 | AudioPlaybackEngine | W3 |
| `Decode/LayerDecodeSession.swift` | Strategy A: `AVSampleBufferDisplayLayer` + `sampleBufferRenderer` | 380 | SampleBufferBuilder | W3 |
| `Decode/SampleBufferRendering.swift` | The renderer protocol + `requestMediaDataWhenReady` pump | 190 | — | W3 |
| `Decode/VTDecodeSession.swift` | Strategy B: session create/configure/decode/invalidate | 420 | FormatDescriptionFactory | W3 |
| `Decode/VTConfig.swift` | Every property key we set, and why | 200 | — | W3 |
| `Decode/StrategySelection.swift` | `DisplayStrategy`, `StrategyInputs`, `selectStrategy`, switch choreography | 260 | — | W3 |
| `Decode/PixelBufferPool.swift` | IOSurface + Metal-compatible, depth ≥ 6, threshold handling | 230 | — | W3 |
| `Decode/FrameQueue.swift` | Capacity 6/12/72, drop order by `dropClass`, `flushToKeyframe` | 240 | RingBuffer | W3 |
| `Decode/LatencyController.swift` | The four-level ladder, EWMAs, dwell times | 300 | — | W3 |
| `Decode/VTErrorRecovery.swift` | The `OSStatus` → action table, backoff, hardware-requirement drop | 260 | — | W3 |
| `Budget/DecodeBudget.swift` | The `@globalActor`; conforms to `DecodeAdmitting` | 420 | DecodePolicy | W3 |
| `Budget/MachineClass.swift` | `sysctl` detection + the R-59 seed table + persistence | 220 | — | W3 |
| `Budget/ThermalGovernor.swift` | Thermal and low-power multipliers, announced via `budgetChanges()` | 190 | DecodeBudget | W3 |
| `Budget/OcclusionMonitor.swift` | The 0 s / 1 s / 30 s / 5 min occlusion ladder | 210 | — | W3 |
| `Budget/JPEGPoller.swift` | Class-D polling with jitter and per-device rate limiting | 230 | — | W3 |
| `Budget/MJPEGDecoder.swift` | `CGImageSource` decode; separate CPU budget; 10 fps cap | 190 | — | W3 |
| `Playback/PlaybackPipeline.swift` | Timebase, rate, seek, step | 460 | DecodePipeline | W3 |
| `Playback/ReorderHeap.swift` | PTS min-heap for B-frame content | 140 | — | W3 |
| `Playback/RateController.swift` | Server `Scale` vs client-side rate; auto-mute outside 0.5…2.0 | 240 | — | W3 |
| `Playback/ReverseGOPDecoder.swift` | Whole-GOP burst decode, 320 MB ring, one tile at a time | 320 | — | W3 |
| `Audio/AudioPlaybackEngine.swift` | `AVAudioEngine` graph, source node, lifecycle | 380 | AudioRingBuffer | W3 |
| `Audio/AACDecoder.swift` | `AudioConverterRef`, magic cookie, ASBD constants | 280 | AudioFormatInfo | W3 |
| `Audio/AudioRingBuffer.swift` | Lock-free SPSC, 400 ms, fade-out on underrun | 200 | — | W3 |
| `Audio/Resampler.swift` | 8 k → 48 k, 31-tap linear-phase FIR via `vDSP` | 180 | — | W3 |
| `Audio/AudioRouter.swift` | D8: focused-only by default, max 4 unmuted, equal-power fades | 280 | — | W3 |
| `Audio/TalkbackController.swift` | Capture → 8 k mono → G.711 → 320-byte chunks at 25 Hz; AEC; PTT | 400 | G711 | W3 |
| `Snapshot/SnapshotEncoder.swift` | PNG/JPEG/HEIC via ImageIO, EXIF/TIFF/IPTC, clean-aperture crop | 320 | — | W3 |
| `Diagnostics/DecodeStatistics.swift` | Reservoirs, percentiles, `< 20 µs` accessor | 220 | — | W3 |
| `Diagnostics/VideoSignposts.swift` | The permanent signpost names | 130 | — | W3 |
| `Diagnostics/HardwareProbe.swift` | **Measured** hardware-decode flag, read 200 ms after the first decode | 110 | — | W3 |

### 5.11 `Sources/VigilRender` — W3 (33 files, ~6 400 LoC)

| Path | Responsibility | LoC | Deps | Wave |
|---|---|---|---|---|
| `RenderContext.swift` | Shared device, queue, library, caches, capabilities | 320 | — | W3 |
| `RenderCapabilities.swift` | The capability struct + probes | 150 | — | W3 |
| `Shaders/VigilTileShaders.metal` | The reviewable shader source of truth (resource, not compiled by SwiftPM) | 420 | — | W3 |
| `Shaders/ShaderSource.swift` | Byte-identical embedded copy, generated by `Scripts/gen-shader-source.swift` | 430 | the `.metal` | W3 |
| `Shaders/TileUniforms.swift` | Swift mirror + a layout self-check test hook | 190 | — | W3 |
| `Shaders/PipelineCache.swift` | `PipelineKey`, `MTLBinaryArchive` persistence keyed by source SHA-256 | 250 | SHA256 | W3 |
| `Geometry/TileGeometry.swift` | Crop + SAR + display size | 140 | FrameGeometry | W3 |
| `Geometry/TileTransform.swift` | Zoom 1…8, NDC pan, anchored zoom, clamp | 200 | — | W3 |
| `Geometry/FitRect.swift` | `fit`/`fill`/`stretch`, the normative table | 130 | — | W3 |
| `Geometry/TileCoordinateMap.swift` | content ↔ view, `visibleContentRect`, `picturePixel` | 250 | TileTransform | W3 |
| `Geometry/NormalizedRegions.swift` | 0…1000 and 0…255 conversions, both origins, rect and polygon flips | 190 | — | W3 |
| `Color/ColorConversion.swift` | BT.601/709/2020 matrices, ranges, siting, sample scale | 260 | ColorInfo | W3 |
| `Color/EDRPolicy.swift` | PQ/HLG only, and only where headroom > 1.0 | 150 | — | W3 |
| `Frames/LatestFrameBox.swift` | The lock-protected slot (`@unchecked Sendable` #3) | 170 | VideoFrame | W3 |
| `Frames/FramePacer.swift` | `NSView.displayLink`, frame-rate ranges, field doubling | 240 | — | W3 |
| `Frames/FrameStreamHandle.swift` | Attach/detach without importing `VigilCore` | 110 | VideoSink | W3 |
| `Tile/VideoTileView.swift` | The `NSView`, options, state, `VideoSink` conformance | 480 | RenderContext | W3 |
| `Tile/VideoTileView+Layer.swift` | Backing layer, contents scale, resize, live-resize | 260 | VideoTileView | W3 |
| `Tile/VideoTileView+Render.swift` | Encode and present for the Metal backend | 420 | Shaders | W3 |
| `Tile/VideoTileView+Input.swift` | Events, gestures, cursors, PTZ keys, click-to-centre | 460 | TileCoordinateMap | W3 |
| `Tile/VideoTileView+DragDrop.swift` | Drag sessions, drop routing, the two UTIs | 260 | TransferTypes | W3 |
| `Tile/SampleBufferBackend.swift` | The ASBDL path, `flush()` never `flushAndRemoveImage()` | 300 | — | W3 |
| `Tile/BackendSwitcher.swift` | Still-layer crossfade, 400 ms wait, 80 ms fade, oscillation guard | 240 | — | W3 |
| `Tile/TileRenderState.swift` | `@Observable`, publishes `pixelSize` and `coordinateMap` | 200 | — | W3 |
| `Effects/DownsampleChain.swift` | Box halvings then bilinear/bicubic by scale factor | 220 | — | W3 |
| `Effects/PrivacyMaskPass.swift` | Solid / mosaic / blur, pixel-exact under zoom | 260 | — | W3 |
| `Effects/OverlayRectPass.swift` | Instanced boxes for the > 32 case and for wall mode | 200 | — | W3 |
| `Wall/WallCompositorView.swift` | Single-layer atlas, hit testing, per-cell renderers | 420 | AtlasTarget | W3 |
| `Wall/AtlasTarget.swift` | Atlas allocation, `maxTextureDimension` gate | 240 | — | W3 |
| `Wall/DirtySlotTracker.swift` | Per-drawable dirty union | 150 | — | W3 |
| `Interop/VideoTile.swift` | `NSViewRepresentable` | 200 | VideoTileView | W3 |
| `Interop/VideoWall.swift` | `NSViewRepresentable` for the wall | 160 | WallCompositorView | W3 |
| `Interop/TileInteractionDelegate.swift` | The 14-member delegate + `PTZDirection` + `Position3DGesture` | 220 | — | W3 |
| `Interop/TransferTypes.swift` | `UTType` exports, `TileAssignmentTransfer`, `CameraRefTransfer` | 160 | — | W3 |
| `Snapshot/TileSnapshotter.swift` | Offscreen render, overlay composite, `CGImage` | 240 | — | W3 |
| `Diagnostics/RenderStats.swift` | Stats, signposts, debug-HUD model | 240 | — | W3 |

### 5.12 `Sources/VigilCore` — W4 (58 files, ~11 500 LoC)

The largest target. Split across ~6 agents by directory.

| Path | Responsibility | LoC | Deps | Wave |
|---|---|---|---|---|
| `Platform/CoreDependencies.swift` | The struct + `.live` + every injected protocol | 320 | — | W4 |
| `Platform/FileSystem+Real.swift` | `writeDurably` with `F_FULLFSYNC`; `replaceItem` | 220 | — | W4 |
| `Platform/Paths.swift` | **The only place a filesystem URL is constructed**; security-scoped bookmarks | 220 | — | W4 |
| `Platform/Occlusion+AppKit.swift` | One of only three AppKit files in the module | 180 | — | W4 |
| `Platform/Pasteboard+AppKit.swift` | ditto | 90 | — | W4 |
| `Platform/QuickLook+AppKit.swift` | ditto | 90 | — | W4 |
| `Platform/PowerObserver.swift` | Sleep/wake, screensaver, low-power, thermal | 220 | — | W4 |
| `Platform/NetworkPathObserver.swift` | `NWPathMonitor` → `NetworkPathState` with interface fingerprint | 180 | — | W4 |
| `Model/Camera.swift` | `Camera` + validation + `slug` + endpoint helpers | 380 | — | W4 |
| `Model/StreamProfile.swift` | `StreamProfile`, `Origin`, `mergeProfiles` precedence | 300 | — | W4 |
| `Model/DeviceCapabilities.swift` | Capabilities, `ChannelDescriptor`, `PTZCapabilities`, `StorageVolumeInfo`, `RTSPPathTemplate` | 420 | DeviceQuirks | W4 |
| `Model/CameraGroup.swift` | Group + membership invariants | 140 | — | W4 |
| `Model/Layout.swift` | `Layout`, `LayoutMode` (+ the flat-`type` Codable), `GridCell`, `CellAssignment` | 420 | — | W4 |
| `Model/LayoutGeometry.swift` | `cells()` for all modes on the 12 × 12 grid | 260 | Layout | W4 |
| `Model/Bookmark.swift` | — | 110 | — | W4 |
| `Model/EventRecord.swift` | `EventRecord`, `NormalizedRect`, `CoalesceKey` | 240 | EventKind | W4 |
| `Model/RecordingClip.swift` | Clip record, container, trigger | 220 | — | W4 |
| `Model/AppSettings.swift` | Every persisted preference, all defaulted | 360 | — | W4 |
| `Model/Library.swift` | The document + `normalize()` + lookups + `OrderIndex` | 340 | all models | W4 |
| `Persistence/AtomicJSONFile.swift` | The durable-write engine: rotate, temp, `replaceItemAt`, debounce | 300 | FileSystem | W4 |
| `Persistence/LibraryCoding.swift` | Encoder/decoder config, the three date forms | 180 | — | W4 |
| `Persistence/ConfigStore.swift` | The actor: load ladder, `mutate`, `flush`, `changes()` | 480 | AtomicJSONFile | W4 |
| `Persistence/RecoveryLadder.swift` | `.bak` → `.bak2` → quarantine → empty-with-banner | 220 | — | W4 |
| `Persistence/SchemaMigrator.swift` | Chain runner, never a jump table | 200 | — | W4 |
| `Persistence/Migration1to2.swift` | `port` split, UNIX dates → ISO-8601 | 160 | — | W4 |
| `Persistence/Migration2to3.swift` | `credentialRef` rekey, `cells` → `assignments` | 200 | — | W4 |
| `Persistence/EventLog.swift` | The separate `events.json` ring, capacity 5000, query | 340 | AtomicJSONFile | W4 |
| `Persistence/ImportExport.swift` | CSV + JSON + the encrypted `.vigilbackup` (PBKDF2 600 000, AES-GCM-256) | 420 | SHA256 | W4 |
| `Security/CredentialStore.swift` | **The only user of `Security.framework`** | 420 | Credential | W4 |
| `Security/LockoutGovernor.swift` | ≤ 3 probes per (host, account) per 10 min; the shared 2-failure counter | 180 | — | W4 |
| `Security/ServerTrustBridge.swift` | Implements `ServerTrustEvaluating` over `Camera.tlsPinSPKI256` | 200 | SHA256 | W4 |
| `Streaming/StreamController.swift` | The actor + public API + the 9-task structured group | 520 | everything | W4 |
| `Streaming/StreamController+Machine.swift` | **The 58-row transition table**, one function per group of rows | 580 | StreamController | W4 |
| `Streaming/StreamController+Timers.swift` | The 20 named timeouts | 260 | — | W4 |
| `Streaming/StreamController+Capture.swift` | Snapshot and recording entry points, pre-roll drain | 300 | ClipRecorder | W4 |
| `Streaming/StreamState.swift` | States, `StateDetail`, narration strings | 190 | — | W4 |
| `Streaming/StreamEvent.swift` | The event enum | 260 | — | W4 |
| `Streaming/StreamError.swift` | `StreamError` + `Code` + the `DoctorCause` bridge | 320 | DomainErrors | W4 |
| `Streaming/ReconnectPolicy.swift` | The ladder, jitter, reset, cold retry | 160 | RandomSource | W4 |
| `Streaming/StreamProbe.swift` | **R1.2**: 3-in-flight candidate ladder, `401` does not advance | 300 | HikvisionURL | W4 |
| `Streaming/ChannelEnumerator.swift` | **R1.3**: ISAPI channels, else `DESCRIBE` probe 1…16 | 240 | ISAPIDeviceSession | W4 |
| `Streaming/StreamCoordinator.swift` | The actor: viewport, priority, admission, shutdown | 520 | DecodeAdmitting | W4 |
| `Streaming/LivePlan.swift` | `makePlan` — a **pure function**, unit-tested exhaustively | 340 | TilePolicy | W4 |
| `Streaming/QualityPolicy.swift` | The class A–E application + hysteresis state per tile | 260 | TilePolicy | W4 |
| `Streaming/LiveViewState.swift` | `@MainActor @Observable`; the cadence rules; **no pixels ever** | 340 | — | W4 |
| `Recording/ClipRecorder.swift` | `AVAssetWriter` passthrough; `.partial` → rename; fragmented every 2 s | 480 | — | W4 |
| `Recording/PreRollBuffer.swift` | Whole GOPs only; 96 MiB / 240 GOPs; never a partial GOP | 220 | — | W4 |
| `Recording/RecordingNaming.swift` | Template rendering, 200-byte path components, collision suffixes | 200 | — | W4 |
| `Recording/RecordingRecovery.swift` | Crash scan for `.partial`, ≤ 5 000 files / 10 s | 190 | — | W4 |
| `Recording/RetentionSweeper.swift` | Days + gigabytes, launch and 6-hourly | 200 | — | W4 |
| `Snapshots/SnapshotService.swift` | Source selection, bounded concurrency, destinations | 340 | SnapshotEncoder | W4 |
| `Snapshots/BurnInOverlay.swift` | CoreGraphics composite for the snapshot path only | 220 | — | W4 |
| `Events/EventCenter.swift` | Subscription reconciliation, dedupe, notification, auto-record | 480 | AlertStreamMonitor | W4 |
| `Events/Coalescer.swift` | Pure 3 s window logic | 180 | — | W4 |
| `Events/AutoRecordArbiter.swift` | Pure policy: cooldown, caps, disk, quiet hours | 220 | — | W4 |
| `Events/NotificationScheduler.swift` | `UNUserNotificationCenter` adapter, categories, throttles | 300 | — | W4 |
| `Health/HealthMonitor.swift` | One 1 Hz timer for the whole app | 280 | HealthRing | W4 |
| `Health/HealthSample.swift` | Exactly 24 bytes; `Flags` option set | 190 | — | W4 |
| `Health/HealthRing.swift` | 600 slots, preallocated | 130 | RingBuffer | W4 |
| `Diagnostics/StreamDoctor.swift` | The 13 steps, 25 s budget, the nine R1.5 diagnoses | 520 | — | W4 |
| `Diagnostics/DoctorCause.swift` | Cause → message → fix → action table | 340 | — | W4 |
| `Diagnostics/DiagnosticsBundleBuilder.swift` | The tree, the caps, the manifest | 380 | TarWriter | W4 |
| `Diagnostics/DiagnosticsRedactor.swift` | Pure second-pass redaction over collected logs | 220 | Redact | W4 |
| `Diagnostics/TarWriter.swift` | POSIX `ustar`, uncompressed | 200 | — | W4 |
| `Diagnostics/LogExporter.swift` | `OSLogStore`, 50 000 entries / 20 MB / 24 h caps | 190 | — | W4 |
| `Automation/DeepLink.swift` | The grammar, total `parse`, write-action gating, 10-per-10 s limit | 420 | — | W4 |
| `Automation/Entities.swift` | `CameraEntity`, `CameraGroupEntity`, `LayoutEntity`, `PTZPresetEntity`, `RecordingClipEntity`, `EventEntity` + queries | 480 | — | W4 |
| `Automation/Intents.swift` | The 16 intents + `VigilShortcuts` (split at 600 lines) | 580 | Entities | W4 |
| `Logging/OSLogLogger.swift` | The 13-category adapter; applies `Redact` before emitting | 190 | Redact | W4 |
| `Logging/Signposts.swift` | The permanent signpost names | 140 | — | W4 |
| `Errors/LocalizedError+Vigil.swift` | `LocalizedError` for every §3.9 enum | 200 | DomainErrors | W4 |

### 5.13 `Sources/VigilUI` — W5 (78 files, ~14 000 LoC)

Every top-level type carries an explicit `@MainActor`. Split across ~6 agents by directory.

| Path | Responsibility | LoC | Wave |
|---|---|---|---|
| `Theme/VTheme.swift` | The namespace + `Space`/`Radius`/`Border`/`Metrics`/`Icon` | 260 | W5 |
| `Theme/Colors.swift` | Every token, via `NSColor(name:dynamicProvider:)`; the 26-row table + idents | 420 | W5 |
| `Theme/Typography.swift` | Nine steps + Mono track + reserved telemetry widths + `vType` | 280 | W5 |
| `Theme/Motion.swift` | Six springs, four curves, three repeaters, `Delay`, `resolved`, `stagger` | 220 | W5 |
| `Theme/Elevation.swift` | `e0`…`e3`, `VGlass`, `VInnerHighlight`, `VVisualEffect` | 300 | W5 |
| `Theme/Environment.swift` | `\.vPulsePhase`, `\.vShimmerOffset`, `\.vMotionEnabled`, `\.vMotionTier`, `\.vTextScale`, `\.vNamespaces`, `\.vOnVideo` | 200 | W5 |
| `Theme/TokenGallery.swift` | The debug window that renders every token in 4 appearances. **Build first** | 380 | W5 |
| `Components/VButton.swift` … `VProgressRing.swift` | **28 files**, one per component (`VButton`, `VSegmentedControl`, `VToggle`, `VSlider`, `VTextField`, `VSearchField`, `VSelect`, `VBadge`, `VChip`, `VCard`, `VToolbar`, `VSidebarRow`, `VTile`, `VTimeline`, `VPTZPad`, `VCommandPalette`, `VToast`, `VEmptyState`, `VSkeleton`, `VStatPill`, `VSparkline`, `VContextMenu`, `VPopover`, `VSheet`, `VInspectorSection`, `VKeyCap`, `VDivider`, `VProgressRing`), each with a `#Preview` covering **every state in its table** | 28 × ~200 = 5 600 | W5 |
| `Components/VTileTransitionProxy.swift` | **All** tile geometry transitions go through this | 220 | W5 |
| `Components/VLiveDot.swift` | Pulse driven by `\.vPulsePhase`, never its own timer | 110 | W5 |
| `Components/VLayoutGlyph.swift` | The layout-picker icons, drawn from `LayoutMode.cells()` | 160 | W5 |
| `Components/FocusRing.swift` | `vFocusRing(_:radius:outset:)` | 90 | W5 |
| `Motion/VMotionGovernor.swift` | Four tiers, one-per-3-s recovery, publishes `\.vMotionTier` | 260 | W5 |
| `State/AppModel.swift` | The injected `@Observable` façade | 300 | W5 |
| `State/LayoutState.swift` | Mode + assignments + overflow, bridged to `ConfigStore` | 240 | W5 |
| `State/SidebarSelection.swift` `InspectorTab.swift` | Selection enums | 120 | W5 |
| `State/PaletteState.swift` | Open/closed, query, mode prefix | 160 | W5 |
| `State/ToastQueue.swift` | Bounded queue, 320 pt cards | 150 | W5 |
| `State/ShortcutStore.swift` | Defaults ⊕ overrides, conflict detection, `UserDefaults` persistence | 300 | W5 |
| `State/FocusedValues.swift` | Focused-camera plumbing for menu commands | 120 | W5 |
| `Window/MainWindowView.swift` | `NavigationSplitView` + `.inspector`; declares the three namespaces | 320 | W5 |
| `Window/MainToolbar.swift` | Customisable 52 pt toolbar | 260 | W5 |
| `Window/WindowAccessor.swift` | Traffic-light inset (20, 26), tabbing off, autosave | 160 | W5 |
| `Window/CinemaChrome.swift` | Full-screen chrome auto-hide | 180 | W5 |
| `Sidebar/SidebarView.swift` + 6 files | Rows, groups, filter bar, footer, context menu, inline rename | 900 | W5 |
| `Stage/StageView.swift` + 9 files | Router, `LayoutEngine`, tile container, chrome, state overlay, empty cell, mosaic editor, patrol, drop delegate | 1 500 | W5 |
| `Inspector/InspectorView.swift` + 10 files | Six tabs, PTZ pad, preset grid, schedule grid, system overview | 1 700 | W5 |
| `Playback/PlaybackWindowView.swift` + 9 files | Model, timeline ruler/heatmap/lane, scrub preview, transport, export, date popover | 1 700 | W5 |
| `Discovery/DiscoveryRootView.swift` + 8 files | Scan, results, credentials, channels, manual add, CSV import, activation | 1 400 | W5 |
| `Events/EventsFeedView.swift` + 4 files | Feed, row, card, filter bar, watch-mode overlay | 700 | W5 |
| `Palette/CommandPaletteOverlay.swift` + 4 files | In-window overlay, index, `FuzzyMatcher`, row, actions | 900 | W5 |
| `Wall/VideoWallView.swift` `ScreenPicker.swift` | Second-display wall | 340 | W5 |
| `Settings/SettingsView.swift` + 7 panes | General, Streams, Recording, Notifications, Shortcuts, Advanced, About | 1 400 | W5 |
| `Shared/StreamDoctorSheet.swift` | The live 13-step sheet with per-step outcomes and one-tap fixes | 340 | W5 |
| `Shared/CheatSheetOverlay.swift` | Renders live from `ShortcutStore`; printable | 220 | W5 |
| `Shared/Formatters.swift` | Bitrate, duration, bytes, timecode — all `monospacedDigit` | 200 | W5 |
| `Shared/Strings.swift` | Generated key accessors over `Localizable.xcstrings` | 260 | W5 |
| `Resources/Assets.xcassets` | App icon, custom SF Symbols. **Directory exists** | — | W5 |
| `Resources/AppIcon.iconset` | Source for `make-icon.sh` | — | W5 |
| `Localizations/Localizable.xcstrings` | EN + RU, `surface.subject.variant.part` keys, plural variations for RU | — | W5 |

### 5.14 `Sources/Vigil` — W6 (7 files, ~1 100 LoC)

| Path | Responsibility | LoC | Wave |
|---|---|---|---|
| `main.swift` | Top-level code; `VigilApp.main()` on macOS, stderr + `EXIT_FAILURE` elsewhere. **No `@main`** | 20 | W6 |
| `VigilApp.swift` | The seven scenes (`Window` ×4, `WindowGroup(for: PlaybackRequest.self)`, `Settings`, `MenuBarExtra`) | 280 | W6 |
| `VigilCommands.swift` | The menu bar; every command routed through `AppModel` | 340 | W6 |
| `AppEnvironment.swift` | Bootstraps `CoreDependencies.live` and the actors | 200 | W6 |
| `MenuBarExtraContent.swift` | Status glance + six quick actions; JPEG thumbnails at 15 s | 220 | W6 |
| `URLSchemeHandler.swift` | `vigil://` → `DeepLink.parse` → consent gate → action | 180 | W6 |
| `AppDelegate.swift` | Sleep/wake, reopen, dock badge, `applicationWillTerminate` 2 s budget | 200 | W6 |

### 5.15 Tests (45 files, ~11 000 LoC)

All test targets exist with a `Placeholder.swift`. The nine with `.copy("Fixtures")` **already have
the directory and its `.placeholder`** — never delete them (R-70).

| Path | Responsibility | LoC | Wave |
|---|---|---|---|
| `Tests/VigilProtocolsTests/CryptoTests.swift` | RFC 1321 (7 vectors) + RFC 3174 + RFC 6234 + RFC 2617 Digest; streaming chunk sizes 1/3/7/13/25/26; 1 MiB input | 340 | W1 |
| `Tests/VigilProtocolsTests/Base64Tests.swift` | Padded, unpadded, whitespace-laden, URL-safe, illegal char, `len % 4 == 1` | 180 | W1 |
| `Tests/VigilProtocolsTests/MediaTimestampTests.swift` | Rescale exactness at 90 kHz and 1 MHz, saturation, cross-timescale compare, clamped init | 260 | W1 |
| `Tests/VigilProtocolsTests/BitReaderTests.swift` | Every boundary, `u(0)`, `u(32)`, `u64(48)`, truncation, `peek` non-mutation | 220 | W1 |
| `Tests/VigilProtocolsTests/ByteReaderWriterTests.swift` | Round-trip, `lengthPrefixed32`, `line(limit:)` overflow | 200 | W1 |
| `Tests/VigilProtocolsTests/NetTypesTests.swift` | `IPv4Address` strictness, four MAC forms, subnet maths, `/31` and `/32` | 300 | W1 |
| `Tests/VigilProtocolsTests/HostPolicyTests.swift` | Every class; the `.publicInternet` refusal | 160 | W1 |
| `Tests/VigilProtocolsTests/RedactTests.swift` | Fuzz: seeded secrets in several encodings; idempotence; ≤ 2× growth | 280 | W1 |
| `Tests/VigilProtocolsTests/TilePolicyTests.swift` | Every class boundary, both scale factors, dead band, dwell, class-B promotion | 300 | W1 |
| `Tests/VigilProtocolsTests/DecodeCostTests.swift` | The worked examples; 0.25 rounding; bit-depth surcharge | 180 | W1 |
| `Tests/VigilProtocolsTests/ErrorTaxonomyTests.swift` | Every code unique, stable, and mapped to a message and a remedy | 200 | W1 |
| `Tests/VigilBitstreamTests/ExpGolombTests.swift` | Table T-EG-1 verbatim + the 32-zero overflow | 160 | W2 |
| `Tests/VigilBitstreamTests/H264SPSTests.swift` | Real SPS vectors; 1088-vs-1080 cropping; VUI fps `÷ 2 × num_units_in_tick` | 320 | W2 |
| `Tests/VigilBitstreamTests/H265SPSTests.swift` | Main and Main10; conformance window; fps **not** halved | 320 | W2 |
| `Tests/VigilBitstreamTests/RecordTests.swift` | `avcC`/`hvcC` build → parse → serialize byte-identical | 260 | W2 |
| `Tests/VigilBitstreamTests/AnnexBTests.swift` | Conversion both ways; 3- and 4-byte start codes; emulation bytes | 240 | W2 |
| `Tests/VigilBitstreamTests/SliceHeaderTests.swift` | `isFirstSliceOfPicture` on both codecs, incl. hostile input | 200 | W2 |
| `Tests/VigilBitstreamTests/FuzzTests.swift` | 1 M random inputs per parser; zero crashes, zero hangs | 200 | W2 |
| `Tests/VigilRTSPTests/HeadersTests.swift` | Case-insensitive lookup, duplicates, order, ASCII-only folding | 200 | W2 |
| `Tests/VigilRTSPTests/WireDecoderTests.swift` | Split invariance over 200 chunkings; every limit; bare LF; mid-header `$` | 420 | W2 |
| `Tests/VigilRTSPTests/ResyncTests.swift` | 1/3/4095 B garbage; false `0x24`; scan-limit; rate policy | 220 | W2 |
| `Tests/VigilRTSPTests/DigestTests.swift` | Every §6.5 row; `nc` across 6 requests; no-`qop` property test ×100 | 300 | W2 |
| `Tests/VigilRTSPTests/SDPTests.swift` | All fixtures; missing/duplicate `a=control`; trailing NUL; static PT 8 | 320 | W2 |
| `Tests/VigilRTSPTests/ControlURLTests.swift` | All six precedence rows plus the query-carrying cases | 200 | W2 |
| `Tests/VigilRTSPTests/SessionMachineTests.swift` | Exact action arrays from fixtures; determinism ×100 chunkings; `.fail` terminal | 480 | W2 |
| `Tests/VigilRTSPTests/HikvisionURLTests.swift` | Every path row; ladder order; credentials never in `description` | 180 | W2 |
| `Tests/VigilRTPTests/PacketTests.swift` | Header parse, padding, CSRC, extension, hostile lengths | 240 | W2 |
| `Tests/VigilRTPTests/H264DepacketizerTests.swift` | STAP-A, FU-A, loss, **marker-bit-unreliable** AU splitting | 340 | W2 |
| `Tests/VigilRTPTests/H265DepacketizerTests.swift` | AP, FU, IRAP gating, RASL drop | 320 | W2 |
| `Tests/VigilRTPTests/AudioTests.swift` | AAC-hbr, ASC parse, G.711 both laws over all 65 536 inputs, G.726 | 300 | W2 |
| `Tests/VigilRTPTests/ReorderTests.swift` | Passthrough vs adaptive; escalation above 1 % loss; wraparound | 280 | W2 |
| `Tests/VigilRTPTests/RTCPTests.swift` | Compound parse, RR generation intervals, SR NTP mapping | 240 | W2 |
| `Tests/VigilRTPTests/StatisticsTests.swift` | The exact EWMA algebra against hand-computed series | 220 | W2 |
| `Tests/VigilISAPITests/XMLTests.swift` | 24 reader cases + 6 builder cases; **XXE refusal**; depth and size caps | 400 | W2 |
| `Tests/VigilISAPITests/DigestTests.swift` | 14 cases incl. RFC 2069 and `nextnonce` | 220 | W2 |
| `Tests/VigilISAPITests/ClientTests.swift` | Lanes, gate, coalescing, retry table, **2-failure hard block** | 300 | W2 |
| `Tests/VigilISAPITests/EndpointTests.swift` | 30 decode cases across 4 device families | 480 | W2 |
| `Tests/VigilISAPITests/AlertStreamTests.swift` | 18 multipart cases + 12 monitor cases; heartbeat suppression | 380 | W2 |
| `Tests/VigilISAPITests/SearchTests.swift` | Paging with the real misspelling; `MORE`; timeline assembly | 240 | W2 |
| `Tests/VigilDiscoveryTests/SADPTests.swift` | 20 cases incl. the XOR-obfuscated and random payloads | 340 | W2 |
| `Tests/VigilDiscoveryTests/WSDiscoveryTests.swift` | 15 cases incl. Hello, Bye, no-prefix | 300 | W2 |
| `Tests/VigilDiscoveryTests/SweepPlannerTests.swift` | 15 cases; the **/16 refusal**; /16–/21 narrowing; host order | 300 | W2 |
| `Tests/VigilDiscoveryTests/FingerprintTests.swift` | 14 cases across four vendors | 280 | W2 |
| `Tests/VigilDiscoveryTests/MergeEngineTests.swift` | 13 cases; `.addressReused` never re-points a saved camera | 320 | W2 |
| `Tests/VigilDiscoveryTests/CoordinatorTests.swift` | 13 orchestration + 10 degraded-mode cases; **the credential-refusal mock** | 380 | W2 |
| `Tests/VigilPipelineTests/EndToEndTests.swift` | **The highest-value test in the repo**: synthetic camera → RTSP → RTP → `EncodedFrame`, no sockets, no Mac | 480 | W2 |
| `Tests/VigilPipelineTests/DeterminismTests.swift` | Same seed ⇒ byte-identical action arrays and frame sequences | 240 | W2 |
| `Tests/VigilTransportTests/` | Adapter tests + `NWListener` stub server (macOS only) | 400 | W3 |
| `Tests/VigilVideoTests/` | Format description, sample buffer, budget, tile policy application, audio | 900 | W3 |
| `Tests/VigilRenderTests/` | Geometry (fitRect table verbatim), colour, effects, atlas, backend, snapshot | 900 | W3 |
| `Tests/VigilCoreTests/` | 173 numbered cases: model, `ConfigStore`, credentials, the **58 transition rows**, coordinator, recorder, snapshots, events, health, diagnostics, automation | 2 400 | W4 |
| `Tests/VigilUITests/` | Palette ranking + throughput, layout geometry, shortcut conflicts, localisation parity | 600 | W5 |

---
<!-- APPEND-HERE -->
