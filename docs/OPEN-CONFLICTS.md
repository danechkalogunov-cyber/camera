# Open conflicts between specifications — for the API contract author to rule on

Twelve specifications were authored in parallel, deliberately, for speed. That guarantees some
disagreement at the seams. These are the contradictions found by reading the finished documents
against each other. **The contract author must rule on every row and record the ruling in
`docs/API_CONTRACT.md`.** Do not let an implementer discover these.

Severity: **H** breaks the build or the visual result; **M** produces inconsistency a reviewer will
file as a bug; **L** cosmetic but should still be settled once.

## C1 — Structural dimensions disagree (M)

| Dimension | `DESIGN.md` §5.1 | `UX.md` §2.2 | Note |
|---|---|---|---|
| Sidebar width | 248 default, min 200, max 360 | 264 default, min 208, max 380 | — |
| Inspector width | 300 default, min 260, max 420 | 320 default, min 288, max 440 | — |

Both are internally consistent, so either set works; they simply must not both exist. Recommended
ruling: **take `UX.md`'s numbers**, because they were derived from the actual row and field content
that has to fit (44 pt camera rows with thumbnail + sparkline; inspector key/value rows with a 92 pt
reserved timecode column), whereas `DESIGN.md`'s are round numbers from the grid. Then amend
`DESIGN.md` §5.1 so the design system remains the single source for tokens.

## C2 — Tile gutter and stage padding disagree (M)

`DESIGN.md` §5.1 specifies a **2 pt** tile gutter and an 8 pt stage inset, and §3.6 justifies 2 pt
precisely: at that width the `#0B0C0F` canvas reads as a seam between frames without needing a
stroke, and the 3.3 L\* step is deliberately too small to read as a border.

`UX.md` §5.1 specifies **6 pt** gap and **10 pt** padding on the 12×12 unit layout grid.

These are not reconcilable by averaging — the 2 pt figure carries an argument, the 6 pt figure comes
from grid arithmetic. Recommended ruling: **2 pt gutter, 8 pt stage inset** per `DESIGN.md`, and
`UX.md`'s 12×12 unit grid keeps its integer cell maths with the gap value substituted. Whoever
implements `LayoutCell → CGRect` must take the gutter from `VTheme`, never a literal.

## C3 — Chrome over video: gradient bars vs. scrim inside the chip only (H — visual)

This is the important one, because the two documents prescribe *visually different* tiles.

- `UX.md` §5.3 describes a **28 pt top chrome bar** and a 32 pt bottom bar, each filled with a
  gradient scrim (black 55 % → transparent).
- `DESIGN.md` P1 (§1.1) lists "persistent gradients/scrims over video" as an explicit anti-pattern,
  and §2.3 rules that hover chrome uses `scrim.base` (black α 0.62) **inside the chip or toolbar
  shape only — never a full-tile gradient**. The single permitted full-tile scrim is the
  offline/degraded state at α 0.82.

Recommended ruling: **`DESIGN.md` wins.** It is the design authority, its rule is argued from the
product thesis ("the frame is sacred"), and it is the better result — a gradient band across the top
of every tile is exactly the "cheap NVR software" look the product is trying to avoid. `UX.md` §5.3
should be amended to describe chip-local scrims. The mockup in `design/mockups/01-main-window.html`
already follows the `DESIGN.md` rule so the intended result is visible.

## C4 — Which module owns the RTSP path table (M)

Three specs each claim it:

- `spec-discovery.md` §12 lists "RTSP path table per vendor (Hikvision `/Streaming/Channels/<n>01`)"
  among the things that are "reusable and not to be re-implemented elsewhere".
- `spec-isapi.md` §2 declares `HikvisionURL` in `VigilISAPI` "the single RTSP path builder".
- `spec-rtsp.md` §9 contains the authoritative per-firmware URL table.

Recommended ruling: **`VigilISAPI.HikvisionURL` is the single builder** (it already owns the
`ChannelID` / `StreamingChannelID` distinction that the path depends on); `spec-rtsp.md`'s table is
documentation of the formats, not a second implementation; `VigilDiscovery` keeps only the coarse
vendor→first-guess-path map it needs for fingerprinting, and must not be used to build a real stream
URL. Also note `REQUIREMENTS-CUSTOMER.md` R1.2 requires a *probe ladder over several candidates*, so
whoever owns the builder must expose "give me candidate N", not just one path.

## C5 — Hash primitives: how many, and where (L, but decide now)

- `spec-rtsp.md` §1 requires `MD5` in `VigilProtocols`.
- `spec-isapi.md` §1 requires `MD5` in `VigilProtocols` (shared, explicitly).
- `FEATURES.md` requires **MD5, SHA-1 and SHA-256**, pure Swift, in `VigilProtocols`, because ONVIF
  WS-UsernameToken needs SHA-1 and the encrypted config export needs SHA-256.

No contradiction, but three specs each partially specify one file. Ruling needed so it is written
once, by one agent: `Sources/VigilProtocols/Crypto/` gets `MD5.swift`, `SHA1.swift`, `SHA256.swift`
plus `Base64+Lenient.swift` (padding-tolerant, per `spec-rtsp.md` §1 — Foundation's decoder rejects
Hikvision's unpadded `sprop-*` values). All four are Linux-testable against published RFC vectors and
must be in the first implementation wave, because RTSP, ISAPI and ONVIF all block on them.

## C6 — `EncodedFrame` / `MediaTimestamp` are declared by four documents (H if unresolved)

`ARCHITECTURE.md` §2.4 asserts a type-ownership registry giving them to `VigilProtocols`;
`spec-rtp.md` §2 calls itself "their authoritative definition"; `spec-video-pipeline.md` §2 restates
them; `spec-bitstream.md` needs `BitReader` from the same module.

There is no disagreement on *where* they live, only on which document is normative for their exact
shape. Ruling: **`API_CONTRACT.md` declares them verbatim and is the only normative source**; the
four specs become explanatory. Any field mismatch between the four (e.g. whether `dts` is optional,
whether `parameterSets` is inline or referenced) must be resolved in the contract, not left to the
implementer to guess.

## C7 — Who sends the keyframe request (L)

`spec-rtp.md` §7 says `VigilISAPI` must expose `requestKeyFrame(channelID:)` and that it is the
primary response to a detected gap. `spec-video-pipeline.md` §12 says `VigilCore` owns "the
keyframe-request wire call" and `VigilVideo` only asks via an injected closure.

These compose rather than conflict — `VigilISAPI` provides it, `VigilCore` calls it, `VigilRTP` and
`VigilVideo` merely emit `.keyframeNeeded`. Ruling should state that chain explicitly so nobody wires
a shortcut from `VigilRTP` to `VigilISAPI`, which would create a forbidden dependency edge.

## C8 — Camera-row height vs. the 4 pt grid (L)

`UX.md` §4.2 sets the camera row at 44 pt with a 30 pt thumbnail; `DESIGN.md` §5.5 enumerates five
control heights (20/24/28/32/40) and says "five heights, no others". A 44 pt row is not a control, so
this is probably fine — but the contract should say so, or a reviewer will flag every sidebar row.

---

# Found during implementation (append-only)

These were discovered by agents writing code against the contract, not by reading it. Each is
recorded so the fix is not silently reverted by a later agent "restoring" the contract's wording.

## I1 — `public static let a: CGFloat = 1, b = 2` annotates only the first binding (H)

API_CONTRACT §4.11 declares the control heights, spacing ladder, radii, borders and icon sizes in
that comma-separated form. Swift applies the type annotation to the **first** binding only, so
every subsequent constant infers `Int` rather than `CGFloat`. The result is not a clear error at the
declaration but a pile of confusing type mismatches at every call site that mixes them.

Fixed in `Sources/VigilUI/Theme/VTheme+Space.swift` by declaring one constant per line with an
explicit `: CGFloat` on each. The same pattern must not be reintroduced.

## I2 — the monotonic clock's first reading was negative (H)

`SystemMonotonicClock` cached its epoch in a lazily-initialised `static`, and the epoch was read
*after* the first `SuspendingClock.now`, so the first `MediaInstant` came out at −26 µs. Every
elapsed-time calculation seeded from it would have been wrong, and the reconnect backoff and the
latency estimate both seed from it. Caught by a test asserting the first reading is non-negative.

## I3 — four contract declarations could not compile as written (M)

`SystemRandomSource.next()` called a `mutating` method on a temporary; `MediaTimestamp.converted(to:)`
trapped on a negative target timescale reachable from SDP data; `FrameGeometry.pixelAspectRatio`
trapped on `sar_height == 0`, which a VUI can legitimately express; and `VideoFormatInfo` had only
`public var`s and therefore an *internal* memberwise initialiser, so `VigilBitstream` could not
construct one. All four are fixed in the implementation; the contract text is now behind the code.

## I4 — `Duration.wholeNanoseconds` wrapped instead of saturating (M)

It used `&+` for the final addition, so at exactly the `Int64.max`-nanosecond boundary it wrapped to
a large negative value while its doc comment promised saturation. Replaced with
`addingReportingOverflow` and a saturating clamp, with a test at the boundary.

## I5 — `VTheme.Health` and `VLevel` are unowned (M — open)

DESIGN.md §12.1 places them in `VTheme` and §9.20 gives their thresholds, the contract's `VTheme`
sketch references them, and **no manifest row and no agent brief covers them**. They are literals and
belong in `VTheme`. Assign them before the UI wave, or the health colouring will be reinvented inline
in a view, which is exactly what the "literals only in VTheme" rule exists to prevent.

## I6 — three types are unassigned and unwritten (M — open)

Reported by `impl:types-b` after finishing its own rows:

- **`Identity/DeviceQuirks.swift`** — `DeviceQuirk` is the single sanctioned channel for firmware
  workarounds: a protocol module detects a quirk, `VigilCore` persists it on the camera record, and
  it is injected back on the next connect. `spec-isapi.md` §2 and `spec-core.md` both depend on it,
  and no manifest row creates it.
- **`Identity/EventKind.swift`** — the event taxonomy the ISAPI alert stream decodes into and the
  UI filters on. Same situation.
- **`RateLimitedLogger`** — deliberately **not** written, and the reason is a real design problem
  rather than an omission: it cannot be a `Sendable` struct with a non-`mutating` `log()`, because
  rate limiting requires mutable state behind the call. It needs to be an actor, or hold an
  `OSAllocatedUnfairLock` — which is macOS-only and therefore cannot live in the pure layer. Decide
  before any module starts logging in a loop, because the first thing that needs it is the RTP
  receiver, which can otherwise emit a log line per packet.

`Identity/Identifiers.swift` was written by `impl:types-b` out of necessity — `StreamKey` needs
`CameraID` — and is not a gap.

## I7 — `F-DEC-06`'s decode-unit quantum contradicts its own worked examples (M — open)

`docs/FEATURES.md` F-DEC-06 acceptance 1 defines the cost of decoding a stream as
`(width × height × fps) / (1920 × 1080 × 30)`, "**rounded up to 0.25 DU**", and then gives three
worked examples in the same sentence:

| Stream | Raw ratio | Stated cost | A 0.25 quantum would give |
|---|---|---|---|
| 4K30 | 4.0 | 4.0 DU | 4.0 DU ✓ |
| 1080p25 | 0.8333… | **0.85 DU** | 1.0 DU ✗ |
| 704 × 576 @ 25 | 0.1629… | **0.2 DU** | 0.25 DU ✗ |

Two of the three examples are not multiples of 0.25, and both are exactly what the formula yields
when rounded up to **0.05**. So the prose and the examples cannot both be followed.

Implemented as **0.05**, because the examples are the half of the specification that can be checked
against arithmetic rather than against intent, and because the finer quantum is the one that
discriminates: at 0.25 DU every sub-stream Vigil is likely to meet — 704 × 576, 640 × 360, D1 —
costs the same 0.25, and a budget cannot tell four of them from four 1080p streams. That defeats the
purpose of costing streams at all.

The constant is `DecodeCost.quantum` in `Sources/VigilProtocols/Streams/DecodeBudget.swift`, and it
is the only line that changes if the ruling goes the other way. `DecodeBudgetTests` asserts all three
worked examples, so a ruling for 0.25 will be caught by the suite rather than by a reviewer.

