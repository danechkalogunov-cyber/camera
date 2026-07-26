# Integration work list — the seams six parallel agents left behind

Every item here was reported by the agent that hit it, rather than papered over with a stub. That is
the intended behaviour: a stub that compiles hides a mismatch, and this layer has no compiler to
catch one.

Ordered by whether it blocks "first light" — the app launching, taking a host and a password, and
showing moving video.

---

## Status, checked against the tree rather than against reports

Re-verified by grep on 2026-07-26, because an item marked done in a report and an item actually
present in `Sources/` are different things and this list is only worth keeping if it tracks the second.

| # | Item | State | Evidence |
|---|---|---|---|
| 1 | `RTPTrackFormatAdapter` missing | **closed** | `Sources/VigilRTP/Track/RTPTrackFormatAdapter.swift`, plus `VigilCore/Streaming/RTPTrackFormatAdapter+RTSP.swift` and a call site in `StreamController+Session.swift`. Landed in the real module, not promoted from the harness. |
| 2 | `VideoTileView` not a `VideoSink` | **closed** | `VigilRender/Tile/VideoTileView+VideoSink.swift:58`. |
| 3 | `EgressGuard` refuses internal DNS names | **closed, and better than asked** | Rather than relaxing the classifier, `RTSPConnection.connect()` now resolves the name itself, classifies **every** returned address, fails closed on any non-LAN answer, and connects to the address literal. `nvr.example.internal` works; a name resolving to a public address is refused. 20/20 executed checks. |
| 4 | Who creates the display layer | **ruled** | spec-render wins; the view creates it in `makeBackingLayer()`. §4.9 amended. |
| 5 | Is `.waiting(error)` terminal | **ruled and implemented** | Terminal **only before `.ready`** (`hasBecomeReady`). A powered-off camera still gets the specific §R1.5 diagnosis; a Wi-Fi roam mid-stream no longer costs a reconnect. Neither source said this — both were half right. |
| 6 | `RTSPConnectionEvent` unconsumed | **closed** | `StreamController` consumes it. Buffering policy changed to `.bufferingOldest(512)` with per-kind drop counters so a `.track` event cannot be evicted by the media it describes. |
| 7 | Nothing calls `reset()`/`stop()` | **closed** | `stop(reason:)` from `stopSession()`; `reset()` from the new `.connectAttemptStarted` arm in `AppSessionModel.apply(_:)` — chosen because it is the only hook that is provably a gap, so the reset cannot race the detached decode task. |
| 8 | `.noFormat` is a silent black tile | **closed, all three links** | `VigilRender` witnesses `didDropFrames`; `TileVideoSink` forwards it (`DecodePipeline` holds the sink, not the tile, so without that forward the report died on the protocol default); `RootView` passes `onFramesDropped` and `onDecodeFailure`, which were defaulting to `nil`, and the **logger**, which was defaulting to `NullLogger`. Fifty `noFormat` drops now force a keyframe, which is what makes Hikvision re-send the parameter sets. |
| 9 | Two contract deviations | **recorded** | `requestKeyframe` stays sync. `streamDidReset`/`streamDidEnd` keep defaults; `didDropFrames` no longer does, which was the one that made 8 silent. |

Items 1–3 blocked first light and none of them do now. What remains below is kept as the record of why
each was decided the way it was.

## Blocks first light

### 1. `RTPTrackFormatAdapter` does not exist

Manifest row §5.9. There is no path from a parsed `SDPMediaDescription` to a configured
`RTPTrackFormat`, outside the private copy inside `PipelineHarness`. Without it the app parses the
camera's SDP and then cannot build a depacketizer.

It fell exactly between the RTP agents' brief and the transport agent's. Write it in `VigilTransport`
per the manifest, or promote the harness's copy.

### 2. `VideoTileView` does not declare `VideoSink` conformance

`impl:render` could not declare it because `VigilVideo` had not landed the protocol; `impl:video`
then landed it, and the two independently chose **identical member spellings**
(`enqueue(_:format:generation:)`, `streamDidReset()`).

So this is genuinely one line — `extension VideoTileView: VideoSink {}` in `VigilRender` — but
nobody owns it, and without it the decode pipeline has nothing to hand frames to.

### 3. `EgressGuard` refuses ordinary internal DNS names

`VigilProtocols/Net/HostPolicy.swift` (ruling R-71) was never written, so `EgressGuard` grew its own
classifier. That classifier refuses any multi-label DNS name other than `*.local`, so a camera at
`nvr.example.internal` **cannot connect at all**.

Either write `HostPolicy` and forward to it, or relax the classifier. Leaving it is a real defect for
anyone whose network has an internal domain — which is most sites with an NVR.

## Decisions, not defects

### 4. Who creates the `AVSampleBufferDisplayLayer`

`API_CONTRACT.md` §4.9 says `VigilVideo` exclusively creates every display layer and hands one over.
`spec-render.md` §5.2 has the view create it in `makeBackingLayer()`. The implementation follows
spec-render.

Ruling needed. If §4.9 wins, `VideoTileView` needs an `adopt(_ layer:)` path.

### 5. Is `NWConnection.State.waiting(error)` terminal?

`impl:transport` treats it as non-terminal, ended only by the five-second connect watchdog.
`spec-discovery.md` §5.9 says it is terminal.

This reaches a customer requirement rather than being internal: a powered-off camera currently
reports `.connectTimeout` instead of `.connectRefused` or `.hostUnreachable`, so Stream Doctor gives
the vaguer of two diagnoses where `REQUIREMENTS-CUSTOMER.md` §R1.5 promises a specific one.

**Recommended ruling: follow the spec.** A specific diagnosis is the whole point of R1.5, and five
seconds of waiting to say "timed out" is worse than saying "nothing is listening" immediately.

### 6. `RTSPConnectionEvent`'s shape is unconsumed

`impl:transport` invented it; nobody consumes it yet. `VigilCore.StreamController` is its first
customer and may need it changed.

## Missing types other agents assumed

Reported as absent from `Sources/` despite being named in the contract: `RTSPEndpoint`,
`DeviceQuirks`, `ServerTrustEvaluating`, `HostPolicy`, `EventKind`, `RateLimitedLogger`. None block
the slice, but each was worked around locally, and the workarounds should be replaced rather than
allowed to become the real thing.

`RateLimitedLogger` in particular needs a design ruling, not just an author: it cannot be a
`Sendable` struct with a non-`mutating` `log()`, and the two escapes are an actor (which makes
logging async and reorders lines) or a lock (macOS-only, so not available in the pure layer).

---

## Found by the step-4 review

### 7. Nothing calls `DecodePipeline.reset()` or `stop()`

`review:video` grepped the app and found only `submit`. On a reconnect the sink therefore never
receives `streamDidReset()`, so `VideoTileView` never flushes its pending queue. It is latent rather
than active only because the RTP layer waits for a keyframe on start — remove that and it becomes
visible corruption. Wire the lifecycle properly.

### 8. `.noFormat` is the last "no video, no error" shape

If parameter sets never arrive, the pipeline drops every frame and reports
`didDropFrames(_:reason: .noFormat)` — and `TileVideoSink` takes the protocol's **no-op default** for
that callback. The result is a black tile with nothing in the log, which is precisely the failure
mode this project has spent its whole design budget trying to eliminate.

Surface the counter somewhere before the first hardware test. A tile that says "waiting for the
camera to send its format" is worth more than a black rectangle.

### 9. Two contract deviations to record rather than fix

`requestKeyframe` is `() -> Void` in the implementation against `() async -> Void` in the contract;
and `VideoSink`'s extension adds no-op defaults for `streamDidReset`/`streamDidEnd` that
API_CONTRACT §4.9 does not, which is what allows finding 8 to be silent. Consider making
`streamDidReset` a requirement without a default.

---

## Found by the discovery wave

### 10. Discovery has no coordinator, so nothing runs a discovery

Both discovery agents finished their halves and both reported the same gap: **`DiscoveryCoordinator`
and `Transport/Protocols.swift` were in neither brief.** What exists is every part a run needs and no
run: SADP and WS-Discovery codecs (byte-exact, hostile-input tested), the sweep planner with its
subnet guard, the Van der Corput host order, the ARP decoder, the vendor classifier, the union-find
merge engine and the progress estimator — 6 179 lines, 293 tests.

What is missing is the actor that sequences the phases, enforces the time budget, emits progress at
20 Hz, handles cancellation, and the seven injected socket protocols it would talk through. So
`spec-discovery.md` tests 78–100 cannot be written yet, and the feature is unreachable from the UI.

This is a clean seam rather than a defect — everything the coordinator needs is in place and typed
(`ProgressEstimator.shouldEmit`, `DiscoveryDeadline`, `MergeEngine`, `DiscoveryPlan`) — but it is the
single largest remaining item in this module and it must not be mistaken for "discovery is done".

### 11. Two fixtures are synthesised from a spec, not captured from a Mac

Both are honestly labelled in their files, and both are the same class of risk as the whole macOS
layer: verified against the documented layout, not against reality.

* **`arp-routedump`** — built to §14.5's description of `rt_msghdr` (92 bytes, `sockaddr_dl` at
  `roundup(16)`). No `sysctl(PF_ROUTE)` exists in this container. If the real struct differs, the ARP
  decoder is wrong in a way no test here can see.
* **SADP/ONVIF wire bytes** — no socket has been touched. Whether firmware accepts these exact probes,
  whether the 37020 multicast bind needs the port-reuse fallback, and whether the entitlement is
  right are all first-contact-on-a-Mac questions.

### 12. Spec error found by implementing, corrected at source

`spec-discovery.md` claimed the SADP probe is **121 bytes** in four places. It is **129**. Verified by
encoding §4.2's prose XML and decoding §14.1's hex dump independently and comparing: byte-identical,
129 long. The dump was right the whole time; the count was never recomputed after the UUID was chosen.
Corrected in all four places, and the byte-exactness test asserts 129 so the code cannot be "fixed"
toward the prose. This is the sixth spec vector the act of implementing has falsified.
