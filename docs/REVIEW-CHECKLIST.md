# Review checklist — what the authors themselves are unsure about

Agents implementing this project are required to end with a list of what they could not verify.
That is more useful than confident silence, and this file is where those lists accumulate. Every
item here is a place a second reader should look, or a place where the first real camera will tell
us something.

Nothing in this file is a known defect. It is known *uncertainty*, which is different and more
actionable.

---

## VigilBitstream — H.265 (`impl:bitstream-b`)

The H.265 SPS parser is the highest-risk file in the pure layer: a mistake desynchronises the bit
reader and yields a plausible but wrong resolution rather than an error.

| Item | Risk if wrong | Status |
|---|---|---|
| **Inter-predicted short-term RPS chain** — three sets where set 1 predicts from set 0 and set 2 from set 1. The loop bound is `0...numDeltaPocs[refRpsIdx]`, **inclusive**, and the return is the count of contributing indices, not `NumDeltaPocs[RefRpsIdx]`. | Bit-reader desync → wrong resolution | Covered only by a **synthetic** vector the author wrote, validated against their own independent Python reference. No hardware capture exercises it. **Most worth a second reader.** |
| `delta_idx_minus1` when `stRpsIdx == num_short_term_ref_pic_sets` | none in practice | Unreachable from an SPS — it occurs only in the slice-header form. Implemented for correctness, dead, untested. |
| Sub-picture HRD (`sub_pic_hrd_params_present_flag`) | `minSpatialSegmentationIDC` falls back to 0 → one wrong byte in `hvcC`, **not** a black screen | Written from the spec, exercised by nothing. |
| 4:4:4 with `separate_colour_plane_flag`, and monochrome | wrong height derivation | Untested chroma paths. |
| `profile_tier_level` with more than two sub-layers | bit-reader desync | Only the single-sub-layer case is covered. |
| `default_display_window` parsed but deliberately **not applied** | a camera reporting the wrong display size | The decision is the specification's, not the implementer's. First place to look if display size is ever wrong. |

## Toolchain

- **swift-frontend 6.1.2 crashed (signal 4)** type-checking `Tests/VigilRTPTests/H264DepacketizerTests.swift`, blocking the shared test compile for about twenty minutes before clearing on the third attempt. Not our bug, but worth knowing: a compiler crash here looks exactly like a broken test file, and the response is to retry before rewriting anything.

## Cleanup owed

- Three files in `VigilBitstream` each carry an identical 15-line `fileprivate withNALPointer`
  bridge, because `withUnsafeBytes` is `rethrows` and erases a typed `BitstreamError` to
  `any Error`. The duplication was deliberate — the author would otherwise have had to claim a name
  in a module a sibling was writing concurrently — and should now be consolidated into one internal
  helper.

---

## How to use this file

Before the macOS layer is reviewed in step 4, every row here gets either a second reader or an
explicit "accepted, will find out on hardware". Items that survive to the first real camera test
become the first things checked when something looks wrong.

---

## Specification vectors that turned out to be wrong (`impl:rtp-a`, `impl:rtp-b`)

Found by implementing against them. In every case the implementation follows the RFC or the CCITT
reference and the test records why it disagrees with the document.

| Where | The document says | Reality |
|---|---|---|
| `spec-rtp.md` §15.1 | header extension `12 AB 00 00` is "id 1, value AB, then padding" | RFC 8285 — and the spec's own `dataLength = len + 1` rule — make `0x12` id 1 with a **three-byte** value |
| `spec-rtp.md` §15.7 | NTP MSW `0xE9A43B21` is unix `1 710 671 009.5` | `1 710 865 569.5`. The test asserts the arithmetic identity rather than the printed decimal |
| `spec-rtp.md` §15.5 | the ADTS vector is 291 bytes | it encodes 293 |
| `spec-rtp.md` §15.5 | `config=1210` is mono | it is stereo |
| `spec-rtp.md` §15.6 | a G.711 A-law column, and µ-law `0x2A`/`0xD5` | contradicts the CCITT reference; the implementation follows CCITT |

## Unverified for want of reference vectors

- **G.726 byte-exactness.** `spec-rtp.md` §15.6 has no ITU vectors for it, so the codec is
  implemented from the standard's prose and its output is **not** checked against a known-good
  encoder. It is out of the slice, but if two-way audio ever sounds wrong, start here.

---

# The macOS layer — nothing below has been compiled

Everything in this section was written against framework documentation and never seen by a compiler.
The Linux build proves only that the `#if os(macOS)` guards are correct.

## VigilRender (`impl:render`)

**Might not compile**

1. Six `NSView` overrides live in an `extension`. Swift permits overriding `@objc`-inherited members
   from an extension and rejects non-`@objc` ones; all six are ObjC `NSView` methods. If the
   compiler disagrees they move into the class body unchanged.
2. `AVSampleBufferDisplayLayer.failedToDecodeNotificationErrorKey` — the exact Swift spelling is
   uncertain.
3. `preventsDisplaySleepDuringVideoPlayback` — believed macOS 11+.
   `preventsAutomaticBackgroundingDuringVideoPlayback` was deliberately omitted because its
   existence on macOS could not be confirmed.
4. `required init?(coder:)` returning nil before `super.init`, and `deinit` removing an observer
   from a `@MainActor` class — both believed legal under Swift 6, neither compiled.

**Might compile and still be wrong — these are the expensive ones**

5. `sampleBufferRenderer` is used off the main thread from the decode thread under one `NSLock`.
   `AVQueuedSampleBufferRendering` documents *serialized* access, not main-thread access — but that
   reading is unverified.
6. **Highest-value item to check on real hardware.** The code observes the *layer's*
   `requiresFlushToResumeDecodingDidChangeNotification` and `failedToDecodeNotification` rather than
   the macOS 14 `AVSampleBufferVideoRenderer` equivalents. If the layer stops posting these once
   samples go through the renderer, resume-decoding recovery never fires and **the picture freezes
   on a held frame** — which looks like a network stall, not a render bug.
7. Whether `contentsScale` on an `AVSampleBufferDisplayLayer` affects video sharpness at all, or
   only layer-drawn content.
8. `layerContentsRedrawPolicy = .duringViewResize` comes from the Metal path of the spec. With an
   empty `updateLayer()` it should be inert; if a stale-content stretch appears while resizing,
   `.never` is the alternative.
9. The main-actor state-publication hop fires per refused sample when the renderer is not ready, so
   sustained backpressure produces a burst of tasks. Not measured.

**Contract conflicts found while implementing**

10. `VigilProtocols.RenderError` has **no case** for an `AVSampleBufferDisplayLayer` decode failure —
    every case is Metal or atlas related. Needs `sampleBufferDecodeFailed(String)`.
11. **A real integration decision, unresolved:** API_CONTRACT §4.9 says `VigilVideo` exclusively
    creates every display layer and hands one over; `spec-render.md` §5.2 has the view create it in
    `makeBackingLayer()`. The implementation follows spec-render. If §4.9 wins, the view needs an
    `adopt(_ layer:)` path.
12. API_CONTRACT §4.10 declares `FrameStreamHandle: @unchecked Sendable`, but ruling R-52 fixes the
    census at exactly three such types and this is not one. Resolved as `@MainActor`.
13. `spec-render.md` §5.1's `override public var canDrawConcurrently: Bool { false }` **cannot
    compile** — the property is read-write, so a get-only override is an error. Assigned in `init`.

**Open seam**

14. `VideoSink` conformance is not declared, because `VigilVideo` had not landed `VideoSink`,
    `VideoFrame`, `StreamEndReason` or `FrameDropReason` when this was written. The two members that
    exist already use the contract's exact spellings, so landing the conformance is a one-line
    extension — but it is an integration task, not a finished one.

## VigilTransport (`impl:transport`)

The agent's own framing of what the Linux build proves is the correct one and worth repeating:
**Swift parses inactive `#if` branches, so the syntax is valid; no body was ever semantically
checked, so every type error in these files is still present — framework-related or not.**

**Would not compile if the assumption is wrong**

1. **Is `NWConnection` `Sendable` in the macOS 14/15 SDK?** It is captured in two `@Sendable`
   cancellation closures and in `stateUpdateHandler`. If it is not, this does not build — and the
   fix must **not** be an `@unchecked Sendable` box, because ruling R-52 caps the census at three
   and forbids generic wrappers. Route the cancellation through the actor instead.
2. Framework spellings taken on faith: `NWEndpoint.Host(_:)` being non-failable,
   `NWParameters(tls:tcp:)` with a nil TLS options, `NWProtocolTCP.Options.noDelay`, the `receive`
   completion arity and the position of `isComplete` in it, `SendCompletion.contentProcessed`, four
   `POSIXErrorCode` case spellings, whether `NWError` and `NWConnection.State` are frozen, and
   `AsyncStream.makeStream(bufferingPolicy:)` on a macOS 14 floor.
3. Assigning actor state inside a `withCheckedContinuation` body relies on that body running
   synchronously in the caller's isolation.

**Decisions the supervisor must make, not merely note**

4. **`.waiting(error)` is treated as non-terminal** — logged, with only the five-second connect
   watchdog ending it. `spec-discovery.md` §5.9 says `.waiting` *is* terminal. The consequence is
   user-visible and touches a customer requirement: a powered-off camera reports
   `.connectTimeout` rather than `.connectRefused` or `.hostUnreachable`, so Stream Doctor gives
   the vaguer of two diagnoses where `REQUIREMENTS-CUSTOMER.md` §R1.5 promises a specific one.
5. **`EgressGuard` carries its own host classifier because `VigilProtocols/Net/HostPolicy.swift`
   (ruling R-71) was never written.** Its classifier refuses any multi-label DNS name that is not
   `*.local`, so a camera at `nvr.example.internal` **cannot connect at all**. Either write
   `HostPolicy` and forward to it, or relax the classifier — leaving it is a real bug for anyone
   with an internal DNS domain.
6. **`RTPTrackFormatAdapter` (manifest row §5.9) is unwritten**, so `VigilCore` has no
   `SDPMediaDescription` → `RTPTrackFormat` path outside `PipelineHarness`'s private copy. Without
   it the slice cannot get from a parsed SDP to a configured depacketizer. This blocks first light.

**Invented constants, none measured**

7. 64 KiB read chunk; a 64-frame / 1 MiB write queue whose overflow is deliberately **terminal**
   rather than a silent drop; a 250 ms close-flush budget; a 256-consecutive zero-byte-receive
   governor; `.bufferingNewest(512)` for events.
8. `cancel()` is assumed to fire outstanding receive and send completions. If it does not, closing
   could block on the write task, and the 250 ms watchdog is the only mitigation.
9. Ruling R-27 requires every drop to be counted, but `AsyncStream` does not report drops, so
   event-stream drops are **not** counted. Acknowledged rather than papered over.

## VigilVideo (`impl:video`)

This agent reduced its own unverified surface rather than only reporting it: it mirrored every
pure-layer construct its code uses into a scratch package — with a fake standing in for
`CMSampleBuffer` — and type-checked that on Linux under Swift 6 with `ExistentialAny`. That retired
the structural worries, which were the ones most likely to be wrong:

- The recursive parameter-set pin is legal Swift. The specification's version used a recursive local
  function with `defer`-popped `inout` arrays — exactly the pattern that trips "declaration closing
  over non-escaping parameter may allow it to escape". Same algorithm, accumulators passed by value.
- `throws(DecodeError)` propagation, and `catch` inferring the typed error (SE-0413).
- An actor handing a non-`Sendable` class synchronously to a `nonisolated` member of an
  `AnyObject, Sendable` protocol — including with a `@MainActor` conformer, which is what the tile
  view is.

**Remaining uncertainty, highest first**

1. Argument labels on the CoreMedia constructors — `CMBlockBufferCreateWithMemoryBlock`'s first
   label is `structureAllocator` in C and assumed to import as `allocator:`; same doubt for
   `CMBlockBufferReplaceDataBytes`. A wrong label is a loud compile error, not silent wrongness.
2. `nalUnitHeaderLength:` — the C parameter is `NALUnitHeaderLength` and the importer is assumed to
   lowercase the acronym.
3. `kCFBooleanTrue` assumed to import as `CFBoolean!`.
4. `unsafeBitCast` of a `CFArrayGetValueAtIndex` result — the standard idiom, but the exact
   optionality of the return type in the current SDK is unconfirmed.
5. Two `OSStatus` values written as numeric literals (`-12704`, `-12731`) because the symbol
   spellings were not worth betting on. Both are on paths the callers already exclude, so a wrong
   number makes a log line misleading and nothing else.
6. `CMVideoFormatDescription` assumed to be a typealias of `CMFormatDescription`. If they are
   distinct in Swift, three call sites need a cast.

**Design decisions worth keeping**

- The block buffer **copies** rather than retaining the `Data` through a custom block source. That is
  what makes a dangling block buffer — the failure that shows as garbled frames rather than a crash —
  structurally impossible instead of merely avoided.
- `generation` is counted locally and monotonically rather than taken from `ParameterSetStore`,
  whose counter returns to zero on reset. A repeating generation number is worse than none to a sink
  whose only use for it is telling stale buffers apart.
- `PartialSync` for H.265 CRA/BLA and `IsDependedOnByOthers` are deliberately absent rather than
  guessed at.
