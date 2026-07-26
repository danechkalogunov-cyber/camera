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

---
<!-- APPEND-HERE -->
