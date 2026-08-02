# Archive seek latency — measured, on a real camera

First numbers this project has from live hardware rather than a fixture. Recorded because "playback
takes a while to load" is a report, and this is the measurement that replaces it.

**Device:** Hikvision DS-I256, firmware V5.5.6, at 192.168.88.50 on a LAN.
**Date:** 2026-08-02. **Build:** `Scripts/build-app.sh`, release.

---

## The numbers

Per-request round-trip times, from `responseReceived(status:cseq:rttMilliseconds:)`. The live column
is the same five requests against `/Streaming/Channels/101`, as a control.

| cseq | request | live | seek → 11:37 | seek → 07:20 |
|---|---|---|---|---|
| 1 | `OPTIONS` | 12 ms | 10 ms | 15 ms |
| 2 | `DESCRIBE` (→ 401) | 17 ms | 10 ms | 7 ms |
| 3 | **`DESCRIBE` + auth** | 20 ms | **553 ms** | **609 ms** |
| 4 | `SETUP` | 22 ms | 52 ms | 55 ms |
| 5 | **`PLAY`** | **297 ms** | **842 ms** | **901 ms** |
| — | → first frame | — | 347 ms | 352 ms |
| — | **total** | ~370 ms | **1 824 ms** | **1 959 ms** |

Vigil's own cost — tearing down the previous session and building the new one — is **1–3 ms**,
from `seek complete: 1.8237 total, 1.8226 of it after the socket opened`. It is not the app.

## What the shape says

Two requests hold the entire delay, and they hold it for different reasons.

**`DESCRIBE` costs ~580 ms on an archive URL and 20 ms on the live one.** The camera is opening the
recording in order to describe it. This is work Vigil asks for and could stop asking for.

**`PLAY` costs ~870 ms on an archive URL and 297 ms on the live one.** The camera is positioning
within the recording. Every approach pays this — there is no way to ask a camera to seek without
waiting for it to seek.

⚠️ Earlier measurements without the per-request split showed a suspiciously constant ~1 330 ms
across three seeks hours apart, which looked like a fixed cost rather than a disk seek. The split
shows why: it is two roughly-constant costs, and `PLAY` does not vary much with distance on this
device. Do not conclude from the constancy that nothing is being sought.

## What can and cannot be removed

Reusing the RTSP session — `PLAY` with `Range: clock=…` instead of a new connection — removes the
TCP connect, `OPTIONS`, both `DESCRIBE`s and `SETUP`:

* **saved: ~650 ms of ~1 900 ms, about 35 %.** A seek would land near 1.25 s.
* **not saved: `PLAY` (~870 ms) and the first-keyframe wait (~350 ms).** Together they are 64 % of
  the total and no client-side change touches either.

So "reduce it to the minimum" has a floor of roughly **1.2 s on this camera**, and the floor is the
device's, not Vigil's.

## Tried on hardware, and reverted

In-session seeking was implemented and tested against the DS-I256 on 2026-08-02. **It does not
work on this firmware.** Seeking produced a connection error, and the wait was no shorter — so the
3 s fallback was being spent and then the session rebuilt anyway, which is strictly worse than not
trying.

Reverted in full (`Revert "Seek inside the open session instead of rebuilding it"`). Recorded here
rather than left as a gap in the history, because the reasoning that led to it is sound and someone
will have it again: `RTSPSessionDriving.perform` takes commands, `.play(rangeText:)` exists,
`PlaybackLocator.clockRange` already formats `clock=…-…`, and the arithmetic says a third off. All
of that is still true. What is also true is that V5.5.6 on a DS-I256 will not reposition a session
opened with `?starttime=`.

⚠️ If this is attempted again, it needs a per-device capability probe — try once, remember the
answer, and never pay the timeout twice — not another unconditional fast path. And it needs a
camera to develop against, because nothing in this repository can tell you whether a firmware
honours the header.

## What is left

Nothing on the client side worth having. With in-session seeking out, the remaining candidates are
`OPTIONS` (~12 ms) and the unauthenticated `DESCRIBE` that collects the 401 (~10 ms) — about 1 % of
the wait between them. The measurement says the time belongs to the camera, and the honest response
is to make the wait legible rather than to keep shaving at it.

## The original reasoning, kept for the record

The change is not small, and its risk lands on a feature that currently works.

`StreamController` has no external "seek within this session" entry point — `playArchive` tears the
session down and builds a new one, which is what its own comment describes as "five round trips
before a frame". Adding in-session seeking means plumbing a `PLAY`-with-range command from the app
layer through `VigilCore` to the state machine, plus a fallback for firmware that ignores `Range:`
on a session opened with `?starttime=` — and detecting *that* means comparing the `Range:` in the
`PLAY` response against what was asked for.

None of it can be verified anywhere in this project: CI has no camera, and the development
container has no Swift compiler. It is exactly the shape of change that this session repeatedly
found to be wrong when made without evidence.

**The measurement above is the evidence needed to decide. The decision is whether 35 % is worth a
regression risk on working playback, and that is the owner's call, not the implementer's.**

## The other thing these logs showed

On the *first* connection after launch, `DESCRIBE`'s 401 arrived 779 ms after the socket opened,
against 7–17 ms on every later connection. In the same window Vigil is running ISAPI device
identification, PTZ capability probing and quirk detection against the same camera, which advertises
`concurrency limit=3`.

That is ~750 ms added to startup, apparently self-inflicted, and it is a separate question from
seeking. Not investigated further here; recorded so it is not rediscovered from scratch.
