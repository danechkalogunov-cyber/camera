# Integration work list — the seams six parallel agents left behind

Every item here was reported by the agent that hit it, rather than papered over with a stub. That is
the intended behaviour: a stub that compiles hides a mismatch, and this layer has no compiler to
catch one.

Ordered by whether it blocks "first light" — the app launching, taking a host and a password, and
showing moving video.

---

## Status, checked against the tree rather than against reports

Re-verified by grep on 2026-07-26, 2026-08-02 and 2026-08-11, because an item marked done in a report
and an item actually present in `Sources/` are different things and this list is only worth keeping
if it tracks the second.

The 2026-08-11 pass also replaced the last HostPolicy workaround and left item 11 open on purpose —
see the note under each.

| # | Item | State | Evidence |
|---|---|---|---|
| 1 | `RTPTrackFormatAdapter` missing | **closed** | `Sources/VigilRTP/Track/RTPTrackFormatAdapter.swift`, plus `VigilCore/Streaming/RTPTrackFormatAdapter+RTSP.swift` and a call site in `StreamController+Session.swift`. Landed in the real module, not promoted from the harness. |
| 2 | `VideoTileView` not a `VideoSink` | **closed** | `VigilRender/Tile/VideoTileView+VideoSink.swift:58`. |
| 3 | `EgressGuard` refuses internal DNS names | **closed, and better than asked** | `VigilProtocols.HostPolicy` is now the single classifier. RTSP and ISAPI resolve ordinary DNS themselves, classify **every** answer and fail closed on any non-LAN result before creating the connection/task. `nvr.example.internal` works; public and mixed answers are refused. |
| 4 | Who creates the display layer | **ruled** | spec-render wins; the view creates it in `makeBackingLayer()`. §4.9 amended. |
| 5 | Is `.waiting(error)` terminal | **ruled and implemented** | Terminal **only before `.ready`** (`hasBecomeReady`). A powered-off camera still gets the specific §R1.5 diagnosis; a Wi-Fi roam mid-stream no longer costs a reconnect. Neither source said this — both were half right. |
| 6 | `RTSPConnectionEvent` unconsumed | **closed** | `StreamController` consumes it. Buffering policy changed to `.bufferingOldest(512)` with per-kind drop counters so a `.track` event cannot be evicted by the media it describes. |
| 7 | Nothing calls `reset()`/`stop()` | **closed** | `stop(reason:)` from `stopSession()`; `reset()` from the new `.connectAttemptStarted` arm in `AppSessionModel.apply(_:)` — chosen because it is the only hook that is provably a gap, so the reset cannot race the detached decode task. |
| 8 | `.noFormat` is a silent black tile | **closed, all three links** | `VigilRender` witnesses `didDropFrames`; `TileVideoSink` forwards it (`DecodePipeline` holds the sink, not the tile, so without that forward the report died on the protocol default); `RootView` passes `onFramesDropped` and `onDecodeFailure`, which were defaulting to `nil`, and the **logger**, which was defaulting to `NullLogger`. Fifty `noFormat` drops now force a keyframe, which is what makes Hikvision re-send the parameter sets. |
| 9 | Two contract deviations | **recorded** | `requestKeyframe` stays sync. `streamDidReset`/`streamDidEnd` keep defaults; `didDropFrames` no longer does, which was the one that made 8 silent. |
| 10 | Discovery has no coordinator | **closed** | `VigilDiscovery/Coordinator/DiscoveryCoordinator.swift` plus `+Multicast`/`+Probes`, and `Transport/Protocols.swift`'s eleven members. `VigilTransport/Discovery/LiveDiscoveryEnvironment.make(logger:)` supplies the real sockets; tests 78–100 exist and run on Linux. Reachable from the UI two ways — `Find Cameras…`, and a silent scan at launch when there is no address, which is what R1 needs. |
| 11 | Two fixtures synthesised, not captured | **open, and now testable** | Unchanged in the tree and unchanged in risk: no `sysctl(PF_ROUTE)` and no socket exists in the container. What changed is that both are now reachable on a Mac, so `docs/ACCEPTANCE.md` §3 is where they get answered rather than argued about. |
| 12 | Spec error corrected at source | **recorded** | Kept below as the record. |

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

**Closed.** `VigilProtocols/Net/HostPolicy.swift` implements ruling R-71 and is Linux-tested.
`EgressGuard` forwards literal and resolved-address classification to it. Both RTSP and ISAPI use a
two-stage policy for ordinary DNS, so `nvr.example.internal` works only when every resolved address
is local. ISAPI also rejects cross-host automatic redirects and disables system HTTP proxies, which
prevents either URLSession feature from bypassing the checked destination.

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

The reported missing types now exist: `RTSPEndpoint`, `DeviceQuirk`, `ServerTrustEvaluating`,
`HostPolicy` and `EventKind`. Their local workarounds have been removed.

`RateLimitedLogger` is also implemented. Its synchronous checked-`Sendable` storage selects
`OSAllocatedUnfairLock` for the macOS-14 product and `Synchronization.Mutex` for Linux CI, so it
needs neither an actor nor a new `@unchecked Sendable` exception.

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

**Closed.** The actor exists and so does everything it needed: `DiscoveryCoordinator` sequences the
phases, enforces the time budget, emits progress at 20 Hz and handles cancellation;
`Transport/Protocols.swift` declares the eleven injected members;
`VigilTransport/Discovery/LiveDiscoveryEnvironment.make(logger:)` supplies the real sockets behind
them. Tests 78–100 are written and run on Linux against fakes.

It is reachable from the UI by two paths, deliberately different: `Find Cameras…` opens a sheet and
lets a person choose, and a **silent** scan runs at launch when there is no address to start from,
filling in the first confident answer. The second is what R1 rests on — "launch it, type the
password, see a picture" has no room in it for choosing from a list.

⚠️ What closing this item does *not* mean: that discovery works. Every test above drives fake
sockets, which by construction answer what they were told to. Three defects in this path were found
only by running the suite on a real runner — `.finished` published before the sockets closed, a
channel that finished opening after a run ended and was never closed, and a scan that kept opening
sockets after cancellation. All three are fixed; none of them was visible to a compiler, and the
first real camera is still ahead. That is item 11 and `docs/ACCEPTANCE.md`.

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
