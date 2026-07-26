# Customer requirements — verbatim, and what they bind us to

These are direct requirements from the customer. They **override** any conflicting
suggestion in the other spec documents. Every implementation agent must read this file.

---

## R1 — "It must just work with a Hikvision camera, immediately"

> Requirement: the app must start up and show live video from a Hikvision camera on the
> local network **right away**, with no manual URL construction, no protocol knowledge,
> and no per-firmware fiddling by the user.

This is a **zero-configuration** requirement, and it is a P0 acceptance gate. It binds us to:

### R1.1 First-run flow: at most three user actions
The whole path from launch to live video must be:

1. Launch → the app **immediately** starts discovery (SADP + WS-Discovery + subnet sweep in
   parallel, no button press required). Devices appear as they are found, progressively.
2. The user picks a device (or, if exactly one Hikvision device is found, it is
   **preselected and focused**, so this collapses to zero actions).
3. The user types the camera password (username prefilled with `admin`, the Hikvision
   default) and presses Return.

That is the maximum. There must be **no** step where the user is asked for an RTSP URL, a
channel number, a stream index, a transport, or a codec.

### R1.2 The RTSP path must be auto-detected, never asked for
Hikvision RTSP paths differ across firmware generations and between cameras and NVRs.
The app must probe the known candidates itself, in this order, and cache the winner per
device:

| Order | Path template | Applies to |
|---|---|---|
| 1 | `/Streaming/Channels/{ch}01` (main) and `/Streaming/Channels/{ch}02` (sub) | current firmware, cameras + NVRs |
| 2 | `/Streaming/Channels/{ch}` | some 5.x firmware |
| 3 | `/Streaming/tracks/{ch}01` | NVR playback-capable paths |
| 4 | `/h264/ch{ch}/main/av_stream`, `/h264/ch{ch}/sub/av_stream` | legacy 4.x |
| 5 | `/mpeg4/ch{ch}/sub/av_stream` | legacy 4.x MPEG-4 |
| 6 | ONVIF `GetStreamUri` | non-Hikvision or unknown firmware |

Probing rule: issue RTSP `DESCRIBE` against a candidate; a `200` with a parseable SDP that
contains a supported video codec wins. `404`/`455` means try the next. `401` means the path
is fine and the credentials need to be applied — do not advance the candidate on `401`.
Probe candidates **concurrently** (bounded to 3 in flight) so the first-frame latency is
not the sum of the failures. Persist the winning template on the `Camera` record so the
probe happens exactly once per device, ever.

### R1.3 Channels must be enumerated automatically
If the device is an NVR/DVR, query `/ISAPI/ContentMgmt/InputProxy/channels` and
`/ISAPI/System/Video/inputs/channels` and offer every populated channel, pre-checked. The
user must never have to guess how many channels exist or what their IDs are. If ISAPI is
unavailable, fall back to probing channels 1..16 with a short-timeout `DESCRIBE`.

### R1.4 Credentials must be entered once
`admin` is prefilled. On success the credential goes to the Keychain and is reused for
ISAPI, RTSP and snapshots. If the same password works for other discovered devices, offer
"use this password for the other N cameras" as a single checkbox.

### R1.5 Failures must be self-diagnosing, never a dead end
Every connection failure must resolve to a named cause and a concrete next action, produced
by the Stream Doctor sequence — never a raw error code or an empty tile. The required
distinct diagnoses are:

| Diagnosis | Trigger | What we tell the user |
|---|---|---|
| Not on this network | no TCP route to 554 and 80 | check the camera is powered and on the same subnet |
| Camera not activated | SADP reports `Activated=false` | the camera needs a password set first; offer to open the activation flow |
| Wrong password | RTSP `401` persists after Digest retry with a fresh nonce | re-enter the password |
| Account locked | ISAPI `userCheck` reports lock-out | wait N minutes or reboot the camera |
| RTSP port closed / blocked | 80 answers, 554 refuses | RTSP is disabled in the camera's config, or a firewall blocks it; show where to enable it |
| Not a Hikvision device | fingerprint says Dahua/Axis/other | say so plainly, offer the ONVIF path |
| Codec unsupported | SDP advertises only an unsupported codec | name the codec and offer to switch the camera's encoding via ISAPI |
| Stream starts but no picture | RTSP plays, no RTP within 5 s | UDP blocked — offer to switch that camera to TCP interleaved (and do it automatically on the retry) |
| Picture stalls | RTP flows, no keyframe within 5 s | request an IDR; if still nothing, lower the GOP via ISAPI |

### R1.6 Transport must self-heal
Default to TCP interleaved, because it traverses every LAN and needs no inbound ports.
If UDP is selected and no RTP arrives within 5 s, fall back to TCP automatically and
remember that per device. Never make the user think about transport.

### R1.7 Acceptance test for R1
On a network with one factory-default-IP Hikvision camera whose password is known:
launch the app, and reach a **visible moving picture** within **10 seconds** of launch,
having typed only the password. This is a manual test on real hardware; write it up as a
checklist in `docs/ACCEPTANCE.md` and keep it green.

---

## R2 — "Send screenshots of the interface as you create it"

> Requirement: the customer wants to see what the UI actually looks like, as images,
> during development.

We cannot build a SwiftUI binary in the development container (Linux, no Xcode), so
"screenshot of the running app" is not available until the customer builds on a Mac.
Instead this is binding:

- Every screen defined in `docs/UX.md` gets a **pixel-accurate HTML/CSS mockup** under
  `design/mockups/`, using the exact token values from `docs/DESIGN.md` — the same hex
  colours, the same type scale, the same radii, spacing, shadows and material recipes.
- The mockups are rendered to PNG at `deviceScaleFactor: 2` with Chromium and delivered to
  the customer as images.
- The mockups are **not** throwaway: they are the visual contract. When the SwiftUI
  implementation of a screen lands, it must match its mockup, and any deliberate deviation
  gets written into `docs/DESIGN.md`.
- Motion is shown too: an interactive prototype under `design/prototype/` reproduces the
  spring timings from `docs/DESIGN.md` in CSS/JS so the customer can judge the feel, not
  just the stills.

---

## R3 — Quality bar (restated, because it is easy to lose)

- The design must stand next to Raycast, Linear, Arc and CleanShot X without looking
  cheaper. Restrained, dark-first, video-is-the-hero, heavily animated but never janky.
- The functionality must be deep and finished, not a demo shell.
- The app must feel instant: no spinner where a skeleton will do, no blank frame where the
  last known frame can be held, optimistic UI for PTZ and settings.
- Latency is a feature: under 250 ms glass-to-glass on LAN.
