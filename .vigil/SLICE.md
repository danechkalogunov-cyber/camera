# "First light" — the vertical slice

Read this together with `.vigil/IMPL_RULES.md` (binding rules) and `docs/API_CONTRACT.md` (the
normative contract: types, per-module API, file manifest).

## The goal, stated as a test

> Launch `Vigil.app` on a Mac. Type a camera address and a password. Within ten seconds, see live
> moving video from a Hikvision camera on the LAN.

Nothing else has to work yet. This is the smallest thing that proves the whole stack — sockets,
RTSP, authentication, depacketization, bitstream parsing, hardware decode, and display — actually
fits together on real hardware.

## Why we are building this before the rest

The development container is Linux with no Xcode. The pure layer (RTSP, RTP, bitstream, ISAPI,
discovery) is genuinely compiled and unit-tested here. **The macOS layer is not, and cannot be.**
Every file that imports VideoToolbox, Metal, AppKit, SwiftUI or Network will meet a compiler for the
first time on the customer's Mac.

So we deliberately write a thin column through *every* layer first. If our understanding of
`VTDecompressionSessionCreate`'s pointer conventions is wrong, it is far better to discover that
across fifteen macOS files than across a hundred and twenty.

## In scope

| Area | Scope for the slice |
|---|---|
| Transport | TCP interleaved only (`RTP/AVP/TCP`). No UDP, no TLS. |
| Auth | Digest (no-qop and qop=auth) and Basic. |
| Video | H.264 **and** H.265 — Hikvision ships H.265 by default on current firmware, so H.264-only would show a black screen on many cameras. |
| Audio | None. Not decoded, not requested. |
| Decode | `AVSampleBufferDisplayLayer` with `DisplayImmediately`. No `VTDecompressionSession`, no Metal. |
| Discovery | None — the user types the host. |
| UI | One window: a connect form, then a single video view with a status line. |
| Persistence | Keychain for the password. No `library.json` yet. |

## Explicitly out of scope for the slice

Grid layouts, PTZ, archive and timeline, events, recording, snapshots, discovery, ISAPI beyond what
is needed to connect, the command palette, the inspector, the sidebar, localization, the menu bar,
digital zoom, audio, UDP, multicast, and the video wall. All of these are in the manifest and land
in waves W2–W6, on top of a slice that already runs.

## The rule that matters most for the macOS files

You cannot compile them. Therefore:

- Quote the exact Apple API signature in a comment above any non-obvious call, so a reviewer can
  check the call against the signature without a compiler.
- Prefer the documented, boring form of an API over a clever one.
- Where a C API takes pointers (`CMVideoFormatDescriptionCreateFromH264ParameterSets`,
  `CMBlockBufferCreateWithMemoryBlock`, `CMSampleBufferCreateReady`), write the pointer plumbing out
  in full rather than compressing it — nested `withUnsafeBufferPointer` closures are where this code
  goes wrong.
- Check every `OSStatus` and map it into `VigilError`; never ignore one.
- Do not invent API. If you are unsure whether a symbol exists on macOS 14, say so in your result
  rather than guessing — a wrong guess costs the customer a compile cycle on their machine.
