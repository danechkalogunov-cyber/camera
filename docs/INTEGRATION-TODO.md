# Integration work list — the seams six parallel agents left behind

Every item here was reported by the agent that hit it, rather than papered over with a stub. That is
the intended behaviour: a stub that compiles hides a mismatch, and this layer has no compiler to
catch one.

Ordered by whether it blocks "first light" — the app launching, taking a host and a password, and
showing moving video.

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
