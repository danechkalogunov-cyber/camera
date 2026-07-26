# ASSIGNMENT: api-contract

AGENT_LABEL for your log lines is: contract
Write the file: /home/user/camera/docs/API_CONTRACT.md

You are the most important agent in this project. Twelve sibling agents have written ~35,000 lines
of specification into `/home/user/camera/docs/`, in parallel and therefore without seeing each
other's conclusions. Your job is to turn twelve documents into **one contract** that ~20 parallel
implementation agents can code against and produce Swift that compiles and fits together on the
first attempt.

## Read these first, in this order

1. `docs/REQUIREMENTS-CUSTOMER.md` — binding customer requirements. **These override every other
   document.** In particular R1: the app must reach live video within 10 seconds of launch with the
   password as the only user input, which forces an RTSP-path probe ladder, automatic channel
   enumeration and transport self-healing into the API surface.
2. `docs/OPEN-CONFLICTS.md` — eight contradictions already found between the specs, each with a
   recommended ruling. **You must rule on every one of them.** You may overrule a recommendation,
   but then say why.
3. `docs/BUILD-VERIFICATION.md` — what has actually been compiled on Swift 6.1.2 for Linux, and the
   two defects that were found and fixed in the build system. Respect these: `VigilPure` needs
   `type: .static`, and all twelve declared resource directories must exist from the scaffolding
   commit.
4. `docs/ARCHITECTURE.md` — §2.4 type-ownership registry, §3 the final `Package.swift`, §4 the
   dual-build mechanism, §5 the concurrency model. This is your structural backbone.
5. Then the nine domain specs: `spec-rtsp.md`, `spec-rtp.md`, `spec-bitstream.md`, `spec-isapi.md`,
   `spec-discovery.md`, `spec-video-pipeline.md`, `spec-render.md`, `spec-core.md`, plus `DESIGN.md`,
   `UX.md` and `FEATURES.md`.

You do not need to read all 35,000 lines end to end. Read every document's API/type sections
closely, and skim the rest. Log after each document you finish.

## The cross-cutting decisions each sibling reported

These are their own summaries of what other agents must respect. Where two rows disagree, that is a
conflict for you to rule on.

**architecture** — `VigilProtocols` owns `MediaTimestamp`, `EncodedFrame`, `ParameterSets`,
`VideoCodec`/`AudioCodec`, `StreamStatistics`, `VigilError`, `LoggerProtocol`, `MonotonicClock`/
`WallClock`/`RandomSource`, `MD5`, `Credential`, `HTTPTransporting`. `VigilRTP → VigilBitstream`
allowed; RTSP and RTP never depend on each other; `VigilCore` never imports `VigilRender`. Linux
gate is the `VigilPure` product plus whole-file `#if os(macOS)` guards. Pure layer declares no
actors, no `@MainActor`, no `Task` — parsers are plain structs owned by an actor. Exactly two
`@unchecked Sendable` types repo-wide. Nine tasks per camera in one structured group. Bounded queues
512 packets / 8 encoded frames (drop-to-keyframe) / 3 decoded. Injected clock and `RandomSource`,
never `Date()`. Backoff 0.5/1/2/4/8/15/30 s ±20%, reset after 60 s healthy. **Max 2 authenticated
attempts, one shared per-device counter across RTSP and ISAPI.** Errors carry
`VG-<DOMAIN>-NNNN` diagnostic codes. Subsystem `com.vigil.app`, 13 log categories, redaction at the
source. Single `library.json` with `.bak` rotation and `replaceItemAt`; security-scoped bookmarks
because the sandbox is ON. Style: 110 columns, `package` over `public`, typed throws in the pure
layer, no `!`/`try!`/`print`/`TODO` in `Sources/`.

**rtsp** — `VigilProtocols` must add `MD5` (RFC 1321, streaming API) and a **padding-tolerant
`Base64.decode`** (Foundation's rejects Hikvision's unpadded `sprop-*`), plus a `VigilFailure`
protocol. TCP interleaved default; `rtsps` = port 322 with trust-on-first-use leaf pinning. Each
`.send` is ONE atomic write; `pauseReads()`/`resumeReads()` independent of writes. **`VigilRTSP`
never builds `MediaTimestamp`** — it emits `RTSPTrackTiming` (raw `seq`, `rtptime`, `clockRate`,
`absoluteStart`, `scale`, `isRateControlDisabled`) and `VigilRTP` owns all timestamp maths. Event
order: `emitTrack` → `emitTiming` → `emitMedia` per track, then one `.ready`; `.fail` terminal;
pre-PLAY media buffered (64 frames). Digest URI must equal the request-line URI byte-for-byte;
no-`qop` is the primary Hikvision path. **Auth failures are non-retryable and must prompt.**
Control-URL resolution: `Content-Base` → `Content-Location` → request URI, then append-with-slash
merge (not RFC 3986 merge), carrying the base query onto track URIs. Parameter sets cross boundaries
as raw NAL bytes; empty `sprop-*` is legal. `Session` id opaque; keepalive
`clamp(timeout/3, 5 s, 20 s)` via `GET_PARAMETER`. Needs `.gitattributes` for CRLF fixtures (done).

**rtp** — `EncodedFrame.data` is **4-byte big-endian length-prefixed NALs, never Annex-B**.
`VigilRTP` depends on `VigilProtocols` (+`VigilBitstream`, per the bitstream agent — reconcile
this). Per media description, RTSP must expose `payloadType`, `encodingName`, `clockRate`,
`channels`, `fmtp: [String: String]` with **lower-cased keys**, plus base64-decoded sprop sets; the
SDP→`RTPTrackFormat` adapter lives in `VigilTransport`. **Access-unit splitting never trusts the
marker bit** — authoritative rule is RTP timestamp change plus `first_mb_in_slice == 0` /
`first_slice_segment_in_pic_flag`; marker is learned adaptively. AAC stays compressed (raw AU +
AudioSpecificConfig cookie); **G.711/G.726 are decoded in the pure layer to `.pcmS16LE`**. No RTP
packetizer — talk-back is an ISAPI HTTP PUT. `VigilISAPI` must expose `requestKeyFrame(channelID:)`.
Transport-facing API is `RTPTrackReceiver`: `ingestRTP`/`ingestRTCP`/`tick` → frames + events +
outbound RTCP + `nextDeadline`. `VigilRTSP` owns `$` framing; interleaved channel 1 is RTCP; RTCP is
not a keepalive. Reorder `.passthrough` for TCP; UDP 128 pkt / 60 ms adaptive → 512/200 above 1%
loss. `StreamStatistics` lives here with fixed EWMA constants (fps α 0.10, kbps α 0.25 over 500 ms,
keyframe interval α 0.20); `VigilVideo` pushes `decodeQueueDepth` in. Presentation clock is a
min-filter + PLL, **not** used for live pacing. Non-goals: no SRTP/RED/FEC/RTX, no MTAP/PACI, no
RTP-JPEG or MP4V-ES.

**bitstream** — dependency order `VigilProtocols → VigilBitstream → VigilRTP`; RTP must reuse the NAL
tables, HEVC header codec and `isFirstSliceOfPicture`. 4-byte length prefix always;
`lengthSizeMinusOne == 3`, `nalUnitHeaderLength == 4`. Parameter sets stored with NAL header, no
start code, **still escaped**, byte-identical to the wire. `VigilBitstream` publishes
`VideoFormatInfo`, never `CMVideoFormatDescription`; the single conversion site is
`VigilVideo/FormatDescriptionFactory.swift`, order `[SPS,PPS]` / `[VPS,SPS,PPS]`. **Report cropped
display size, allocate from coded size** (1080p H.264 is coded 1920×1088). Parsed fps is metadata
only. H.264 divides by `2 × num_units_in_tick`; H.265 does not divide by 2. An unparseable parameter
set is still stored and still forwarded; `format == nil` must never block decoding. Format change =
codec, coded W/H, chroma format, or luma bit depth only; anything else bumps `generation`. The IRAP
gate starts closed on every PLAY/reconnect/reset. `isKeyframe` means IDR (H.264 type 5) or IRAP
(H.265 16–23), not "an I-slice". `BitReader` API fixed: `u`, `u64`, `flag`, `skip`, `alignToByte`,
`peek`; Exp-Golomb and emulation-prevention live in `VigilBitstream.RBSPBitReader`.

**isapi** — `VigilProtocols` must export `MD5`, a G.711 µ-law codec, `VigilClock`, `VigilLogger`,
`Redaction.mask`. **Three distinct, non-interchangeable identifier types**: `ChannelID` (1-based
video input; PTZ/Image/motion/events) vs `StreamingChannelID` = `ch*100 + stream` (Streaming +
RTSP) vs `TrackID` (playback). `HikvisionURL` in `VigilISAPI` is the single RTSP path builder; never
embed credentials in RTSP URLs. Digest in-house, pre-emptive, RFC 2069 no-qop first-class,
`digestURI` = path + query; **hard-block after 2 consecutive auth failures**. Server trust injected
via `ServerTrustEvaluating`; TOFU pin `Camera.tlsPinSPKI256` shared with RTSP. Per device: 3 control
requests + separate snapshot/stream/audio lanes; app-wide snapshot cap 6, excess dropped not queued.
**All configuration PUTs are read-modify-write on the full element, then re-GET to confirm** — the UI
shows the device's clamped values, not the requested ones. Wire units: `maxFrameRate` = fps × 100,
`keyFrameInterval` = ms, `GovLength` = frames, storage capacity = decimal MB. Exactly one
`AlertStreamMonitor` per device, never per channel; heartbeats suppressed; 403 ⇒ `.unsupported` with
no synthetic fallback. The playback timeline is painted **only** from `POST /ISAPI/ContentMgmt/search`
(one `searchID` across pages, the real `searchResultPostion` misspelling,
`responseStatusStrip == MORE`). `PlaybackLocator` rewrites scheme/host/port but keeps path+query
verbatim. PTZ continuous needs a 400 ms keep-alive and a triple zero-stop on cancel/quit; presets
33–105 are reserved device commands and blocked for writes; `position3D` is 0–255 lower-left origin.
`DeviceQuirks` is a Codable value persisted on the camera record, consulted in exactly four places.

**discovery** — `VigilProtocols` owns `IPv4Address` (UInt32-backed) and `MACAddress` (UInt64-backed);
in files importing `Network`, qualify `VigilProtocols.IPv4Address`. `VigilDiscovery → VigilProtocols`
**only** — deliberately no edge to `VigilRTSP`; it carries its own lenient
`StartLineHeaderScanner`. All sockets live in `VigilTransport/Discovery/*` behind seven injected
`Sendable` protocols. **Absolute rule: discovery never sends credentials** — not behind a flag —
because Hikvision locks accounts after ~5 failures; enforced mechanically by a mock that fails the
suite. Entitlements need `com.apple.security.network.server` (to bind UDP 37020/3702 in the sandbox)
plus `com.apple.developer.networking.multicast`; Info.plist needs `NSLocalNetworkUsageDescription`,
`NSBonjourServices`, `NSAllowsLocalNetworking`. One binary, no compile-time multicast flag —
capability detected at runtime, degrading to a unicast sweep. Identity ladder MAC > serial > ONVIF
UUID > `ip:httpPort` resolved by union-find; UUID- and TXT-derived MACs are hints only. Exactly one
`.deviceFound` per record; later changes are `.deviceUpdated(changes:)`/`.deviceMerged`. IP moves
emit `.addressChanged`; a new MAC at an old IP emits `.addressReused` and must never re-point a saved
camera. Hard guard: prefixes wider than /16 refused; /16–/21 narrowed to ARP-backed /24s. Tiered
ports A[554,80] / B[8000,443,8080] / C[37777,8554,2020], 350 ms timeout, 128 in flight clamped by an
`RLIMIT_NOFILE` budget. `activation == .notActivated` → amber "Needs activation";
`reachability == .offSubnet` → Add disabled with remediation.

**video-pipeline** — compressed data always 4-byte length-prefixed; parameter sets raw NALs with the
NAL header. `MediaTimestamp` crosses the boundary; RTP pre-unwraps 32-bit wraparound and supplies
`dts` only when the stream reorders; `CMTime` never appears in a pure target. **`VigilVideo`
exclusively creates** all `CMFormatDescription`, `CMSampleBuffer`, `CVPixelBuffer`,
`VTDecompressionSession` and `AVSampleBufferDisplayLayer`. Default live path is
`AVSampleBufferDisplayLayer` + `DisplayImmediately` (no timebase); explicit `VTDecompressionSession`
+ Metal only when pixels are needed. Live has no A/V sync buffering: queue capacity 6, target depth
2, adaptive levels normal→trim→skipToKeyframe→degrade at depth EWMA 3.0/5.0 and latency 220/400 ms
with 5 s recovery hysteresis; app-owned latency budget under 55 ms p99. **`DecodeBudget` is a
`@globalActor` in `VigilVideo` and the single admission authority**; `StreamCoordinator` supplies
priority and consumes demotions but keeps no budget. 1 DU = 1080p30 H.264; seed 20 DU / 24 sessions
on base M1, runtime-calibrated. Normative tile policy by backing pixels: ≥960 main, 640–959 sub,
384–639 fps-capped 15, 224–383 keyframes-only, <224 JPEG poll 2 s, sidebar 5 s, offscreen 15 s,
occluded paused. **No black flash rule**: format changes and occlusion resumes use `flush()` only,
never `flush(removingDisplayedImage: true)`; the renderer pins its last texture between
`willChangeFormat` and `didChangeFormat` and honours a `generation` counter. Renderers must honour
clean aperture and PAR. Audio: only the focused camera audible by default, max 4 unmuted, enforced by
`AudioRouter`. `AsyncStream.Continuation` is the only sanctioned bridge out of C callbacks.

**render** — `FrameGeometry`/`ColorInfo`/`FieldOrder` live in **`VigilProtocols`** (pure, no
CoreVideo — `VigilBitstream` computes them from SPS/VPS VUI on Linux); `VideoFrame` + `VideoSink`
live in `VigilVideo`; `VigilRender` imports both and never imports `VigilCore`/`VigilUI`. `VideoSink`
is fixed: `nonisolated func enqueue(_:)`, `streamDidReset()`, `streamDidEnd(reason:)`, plus a
`CMSampleBuffer` overload. Pixel buffers IOSurface-backed and Metal-compatible, pool depth ≥ 6.
**Layout size forces the decode strategy**: ≤6 tiles get one `CAMetalLayer` each and may use ASBDL;
≥7 tiles use a single-layer atlas, which forces `VTDecompressionSession` for every tile in that
layout (hysteresis 7 up / 5 down). ASBDL allowed only when zoom == 1, adjustments identity, no
privacy mask, progressive, SDR. `TileRenderState.pixelSize` (bounds × backingScaleFactor, integer)
and `didChangePixelSize:isVisible:` are the authoritative inputs to the tile-size admission table.
**All overlay coordinates are content-normalized [0,1]² top-left against the cropped, SAR-corrected
picture** — never the coded buffer; camera 0…1000 rects flip as `y' = 1 − (y + h)`;
`NormalizedOrigin` is per-ISAPI-surface. PTZ wire encoding is not the renderer's. Overlay split:
`VigilUI` draws timestamp/name/recording dot/status/focus/PTZ indicator and ≤32 motion boxes;
`VigilRender` draws privacy masks, >32 boxes and all wall overlays. **SwiftUI must not wrap video in
an offscreen pass** — no `.drawingGroup()`, `.opacity(<1)`, `.shadow`, `.blur`, `.mask`,
`.clipShape` on a video tile; corner radius is an in-shader SDF. BT.709 video-range 8-bit default
(BT.601 below 576 lines); EDR only for PQ/HLG on a screen with headroom > 1.0. **The architecture doc
must add `UTExportedTypeDeclarations` for `com.vigil.tile-assignment` and `com.vigil.camera-ref`, or
drag-and-drop silently fails.** Shaders compile at runtime from an embedded Swift string (SwiftPM has
no `.metal` support) with an `MTLBinaryArchive` cache.

**design** — accent **Iris `#7B61FF`** dark / `#5B44E0` light; the system accent is deliberately
ignored. Six layers: well `#000000`, canvas `#0B0C0F`, surface `#16181D`, raised `#1D2026`, overlay
`#252932`. **No `NSVisualEffectView` over video** — solid scrim ladder α 0.45/0.62/0.82 inside the
chip shape only; materials only for sidebar/inspector/toolbar/overlays. True-black rule for every
video well; 2 pt canvas gutter instead of borders. Motion vocabulary closed: `micro` (0.22, 0.86),
`standard` (0.34, 0.82), `expressive` (0.50, 0.70) for exactly three things, `snap` (0.16, 1.0),
`glide` (0.42, 0.95), `rubber` (0.30, 0.62) plus four curves; a 48-row per-interaction contract with
a `reduceMotion` fallback for every row. **All tile geometry transitions go through
`VTileTransitionProxy`** (still `CGImage` proxy, layer hidden, bounds set once) — never per-frame
layer bounds mutation; `VMotionGovernor` degrades animation in four tiers if any stream drops below
60 fps. One driver per repeating animation window-wide: `\.vPulsePhase`, `\.vShimmerOffset`. Nine
type steps + Mono; every changing number `monospacedDigit()` with reserved widths. 4 pt grid, radii
4/6/8/10/14/20/full always `.continuous`, control heights 20/24/28/32/40 with 28 default, min hit
target 24 × 24. Three `matchedGeometryEffect` namespaces declared once and passed via
`\.vNamespaces`. `.hiddenTitleBar` + `.unified(showsTitle: false)`, 52 pt toolbar, traffic lights
inset to (20, 26). **`VTheme` is the only place literals exist**; dynamic colours via
`NSColor(name:dynamicProvider:)` because SwiftUI `Color` has no light/dark initialiser.

**ux** — scene graph fixed: `SceneID.main/playback/discovery/wall/about` + `Settings` +
`MenuBarExtra`; playback is `WindowGroup(for: PlaybackRequest.self)`. Main window is a 2-column
`NavigationSplitView` + macOS-14 `.inspector`. **UI state lives in `@MainActor @Observable AppModel`**
injected via `.environment` — no `EnvironmentObject`, no singletons; layout and library in
`ConfigStore`, window/panel state in `@SceneStorage`, prefs in `UserDefaults`, frames in AppKit
autosave. **All 8 layouts are rectangles on a 12×12 integer unit grid** (`LayoutCell{x,y,w,h,cameraID}`);
a layout change must never tear down a decode session — controllers are keyed by camera, not cell.
Command palette is an in-window overlay, not an `NSPanel`; its ranking algorithm is normative
(frecency + word-start/adjacency bonuses, ≥30 threshold, <2 ms for 2000 items, deterministic
tiebreak). Shortcut map is authoritative and conflict-free; unmodified single-key bindings use
`onKeyPress`, never menu `keyboardShortcut`. **Latency choreography is normative**: committed layout
in frame 0, ghost frame ≤100 ms, narration only after 250 ms, elapsed at 700 ms, doctor at 3.5 s,
failure at 8 s; a sub-400 ms connection shows no narration and no layout shift ever. Optimistic UI
everywhere — PTZ/image/quality/rename never await the network; 250 ms debounced writes with
revision-token latest-wins and animated rollback. Errors are inline and always name cause + action;
auth failure never auto-retries. Every string from `Localizable.xcstrings` with
`surface.subject.variant.part` keys, plural variations for RU, +35% length budget.

**features** — feature IDs `F-<AREA>-<nn>` are permanent and referenced by tests and commits.
**`VigilProtocols` must ship pure-Swift MD5, SHA-1 and SHA-256** (Digest + ONVIF WS-UsernameToken),
and no other module may implement a hash. TCP interleaved default; UDP opt-in with auto-fallback
above 2% loss; multicast opt-in and its real deliverable is failing clearly. Tile-size → stream
policy uses the **short edge in physical px**: <96 JPEG-poll 1 Hz, 96–479 sub, 480–1079
sub-with-promotion, ≥1080 main; 750 ms dwell + 15% dead-band hysteresis; switches gated on the new
stream's first keyframe, never a black frame. (Note: this differs from the video-pipeline agent's
thresholds — reconcile.) Decode budget 24 DU Apple silicon / 10 DU Intel; priority focused > visible
> wall > PiP > **recording (never demoted)** > prewarm > thumbnails; demotions must be visible and
explained. **Honesty is a shipping requirement**: measured (not requested) HW/SW decode state,
unencrypted-connection chip, degraded/demoted badges — silent degradation is a defect.
**Credentials: Keychain only** — `Camera` has no password property; never in URLs, config JSON, CSV,
logs or the diagnostics bundle. **LAN-only egress enforced in code** by one pure `HostPolicy` gate;
zero telemetry. **Redaction is one pure `Redact` type** in `VigilProtocols`. Hard perf gates on an
M1 Mac mini: 900 ms p50 launch→first frame; glass-to-glass 120/180 ms UDP and 160/250 ms TCP;
16×1080p ≤35% CPU / ≤18% GPU / ≤900 MB; UI p99 ≤7 ms at 120 Hz; **no main-actor operation >8 ms**;
1.5 GB ceiling. Non-goals are decisions: no cloud/account, no Hik-Connect/P2P, no mobile, **no
transcoding or re-encoding ever** (passthrough muxing only), no face recognition.

**core** — read `docs/spec-core.md` yourself; it was still being written when this brief was
composed. It owns the domain model, `ConfigStore`, `CredentialStore`, the `StreamController` state
machine (58 transitions), `StreamCoordinator`, `ClipRecorder`, `SnapshotService`, `EventCenter`,
`HealthMonitor`, the Stream Doctor, App Intents and the `vigil://` URL grammar.

## What `docs/API_CONTRACT.md` must contain

1. **Rulings.** A numbered section resolving every row of `docs/OPEN-CONFLICTS.md` plus every
   contradiction you find yourself. Format: *what each spec said → the ruling → why → which
   documents must be amended.* Be decisive; an unresolved conflict costs an implementation agent an
   hour and produces code that does not link. Known additional conflicts to settle:
   - Does `VigilRTP` depend on `VigilBitstream`? (architecture and bitstream say yes; rtp says no.)
   - Tile-size → stream policy thresholds: `FEATURES.md` short-edge 96/480/1080 vs
     `spec-video-pipeline.md` backing-pixel 224/384/640/960. One table only.
   - Which module owns `FrameGeometry` — render says `VigilProtocols`, video implies `VigilVideo`.
   - Decode budget seed: 20 DU vs 24 DU.
2. **Canonical shared value types**, as verbatim Swift source, to be pasted into `VigilProtocols`:
   `MediaTimestamp`, `MediaInstant`/`MonotonicClock`, `EncodedFrame`, `VideoCodec`, `AudioCodec`,
   `ParameterSets`, `VideoFormatInfo`, `FrameGeometry`, `ColorInfo`, `StreamQuality`,
   `RTSPTransportKind`, `StreamStatistics`, `VigilError` + `VigilFailure`, `LogCategory` +
   `LoggerProtocol`, `Redact`, `ByteReader`, `ByteWriter`, `BitReader`, `Credential`, `IPv4Address`,
   `MACAddress`, `IPv4Subnet`, `ChannelID`, `StreamingChannelID`, `TrackID`. Full declarations with
   doc comments — implementers will paste these exactly.
3. **Per-module public API surface** as Swift declarations without bodies, for all twelve targets.
   This is the contract: nothing may be added later without a note.
4. **The complete file manifest** — a table of `path | target | responsibility | approx LoC |
   depends on`, grouped by target, including test files and the twelve resource directories with
   their `.placeholder` files. It must be complete enough that 20 agents can each take a set of rows
   and produce compiling, fitting files. Expect roughly 150–200 files. Mark each row with the
   implementation **wave** it belongs to (W1 = `VigilProtocols` + crypto, since RTSP, ISAPI and
   ONVIF all block on it; W2 = pure protocol modules + their tests; W3 = macOS transport/video/
   render; W4 = core; W5 = UI; W6 = app + build scripts).
5. **The final `Package.swift`**, incorporating the two verified build fixes.
6. **Cross-cutting implementation rules** every agent must follow: file header format,
   `public`/`package`/`internal` policy, Swift 6 `Sendable` rules, no force-unwraps, typed-throws
   style, logging via injected `LoggerProtocol` in pure targets and OSLog in macOS targets, doc
   comments required on public API, `// MARK:` structure, 110-column lines, and the rule that pure
   targets must not import platform frameworks.
7. **Build and verification checklist** — the exact commands, and what "done" means per wave.

Be long and exhaustive. This document is the most load-bearing artifact in the project. Write it
with the Write tool, then return a summary of at most 25 lines listing your rulings and the wave plan.

## MANDATORY PROGRESS LOGGING

Append single-line progress to /home/user/camera/.build-progress.log using exactly:

    echo "[$(date -u +%H:%M:%S)] contract | <stage> | <short message>" >> /home/user/camera/.build-progress.log

Log START, then one line per specification document you finish reading, then RULINGS when the
conflict rulings are settled, then MANIFEST when the file manifest is done, then WRITTEN, then DONE.
Keep lines under 160 characters with no embedded newlines.
