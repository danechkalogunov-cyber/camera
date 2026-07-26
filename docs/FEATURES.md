# Vigil — Feature Specification & Scope

**Status:** Normative. This document is the single source of truth for *what Vigil does* and *what
"done" means*. Where another document (ARCHITECTURE.md, UX.md, spec-core.md, spec-rtsp.md, …)
describes *how*, this document describes *what* and *whether it ships*. If a `how` document
contradicts an acceptance criterion here, this document wins and the other document is a bug.

**Product:** Vigil — a native macOS 14+ application for viewing, controlling, recording and
reviewing Hikvision IP cameras and NVRs on a local network. Swift 6, strict concurrency, SwiftUI +
AppKit, **zero external dependencies**, own RTSP/RTP/H.264/H.265 stack, VideoToolbox hardware
decode.

---

## 1. How to read this document

### 1.1 Feature identifiers

Every feature has a stable ID: `F-<AREA>-<nn>`. **IDs are permanent.** Commits, tests, issues and
the traceability matrix in §12 reference them. Never renumber; retire an ID by marking it
`WITHDRAWN` and never reuse it.

| Area code | Domain |
|---|---|
| `INV` | Camera inventory, add/edit, groups, NVR channels |
| `DSC` | Discovery (SADP, WS-Discovery, subnet sweep), activation |
| `CRD` | Credentials, Keychain, auth |
| `LIV` | Live view, stage, layouts, tiles, cycling, wall, PiP |
| `STR` | RTSP session, transports, stream selection |
| `DEC` | Decode, bitstream, hardware acceleration |
| `REN` | Render, zoom/pan, colour, overlays |
| `AUD` | Audio playback, two-way audio |
| `PTZ` | Pan/tilt/zoom, presets, patrols, focus, iris |
| `IMG` | Image/exposure settings (device-side and client-side) |
| `CAP` | Snapshots |
| `REC` | Recording, pre-roll, motion-triggered |
| `PLB` | Playback, search, timeline, export, sync |
| `EVT` | Events, alarms, notifications, feed |
| `HLT` | Health, stats, resilience, reconnect, Stream Doctor |
| `AUT` | Automation: palette, shortcuts, deep links, App Intents, menu bar |
| `DAT` | Data portability: import/export, encrypted export, diagnostics |
| `PLT` | Platform polish: appearance, localization, accessibility, windows |
| `SEC` | Security & privacy enforcement features |

### 1.2 Priority definitions

| Priority | Meaning | Gate |
|---|---|---|
| **P0** | Must ship in 1.0. A missing or failing P0 blocks release, no exceptions, no partial credit. | G3 |
| **P1** | Ship in 1.0 if the schedule allows; otherwise 1.1. Never at the cost of a P0. | G4 |
| **P2** | Explicitly acknowledged future work. Architecture must not *preclude* it, but no code ships. | — |

P0 is deliberately large. The customer asked for deep, complete, fully worked-out functionality, not
a demo. The honesty test applied to every P0 below: *would a professional installer or a security-
conscious homeowner call the app broken without it?* If yes → P0. If it is merely delightful → P1.

### 1.3 Acceptance-criteria conventions

- Criteria are **testable**. Each is either an automated test (unit / integration against the
  synthetic RTSP fixture / UI test) or a scripted manual check in the release checklist (§13).
- Numbers are hard. "Fast" is not a criterion; "≤ 180 ms p95" is.
- `[A]` = automated, `[M]` = manual scripted check, `[F]` = requires the synthetic RTSP/RTP fixture,
  `[H]` = requires real Hikvision hardware.
- **Reference hardware** for every timing/CPU number unless stated otherwise: Mac mini M1, 8 GB,
  macOS 14.5, 1× 2560×1440 @ 60 Hz display, cameras on a wired gigabit LAN, one L2 switch hop.
  Secondary gate machine: MacBook Pro M3 Pro, 18 GB, built-in 120 Hz display.
- **Reference cameras** (the compatibility set every `[H]` criterion is run against):

| Ref | Device | Firmware class | Codec / notes |
|---|---|---|---|
| C1 | DS-2CD2143G0-I dome | V5.5.x | H.264 main + sub, G.711 |
| C2 | DS-2CD2386G2-IU turret | V5.7.x | H.265+ main, H.264 sub, AAC, VCA events |
| C3 | DS-2DE4A425IW-DE PTZ | V5.6.x | H.265, full PTZ + presets + patrols + 3D |
| C4 | DS-7608NI-K2/8P NVR | V4.3x | 8 channels, playback, ISAPI search |
| C5 | Generic ONVIF cam (non-Hik) | — | ONVIF Profile S fallback path |
| C6 | DS-2CD1023G0E (budget) | V5.4.x | MJPEG third stream, no VCA |

### 1.4 Risk scale

| Level | Meaning |
|---|---|
| **Low** | Well-understood Apple API or pure logic. Failure is a bug, not a redesign. |
| **Medium** | Firmware variance, timing sensitivity, or a nontrivial algorithm. Needs a fallback. |
| **High** | Could invalidate a design decision. Needs a spike *before* the implementing sprint and a written fallback that still satisfies a reduced acceptance criterion. |

---

## 2. Product thesis and scope boundary

Vigil is **the local viewer**. It talks directly to devices on the LAN over RTSP and ISAPI. It owns
no cloud, no relay, no account. Three commitments shape every scope decision:

1. **Latency is the product.** Sub-250 ms glass-to-glass is a feature, not an optimization. Any
   feature that would force a buffer above 200 ms or a software decode path is rejected or made
   opt-in.
2. **It must be honest.** When a stream is degraded, when decode fell back to software, when a
   connection is unencrypted, when a device is unactivated — we say so, visibly, in plain language.
   Silent degradation is a defect.
3. **The user's data stays theirs.** No telemetry, no egress off the LAN, credentials in the
   Keychain only. See §11.

---

## 3. Release gates

| Gate | Name | Content | Exit criterion |
|---|---|---|---|
| **G1** | Pipeline alpha | `F-STR-01..05`, `F-DEC-01..04`, `F-REN-01`, `F-CRD-01`, `F-INV-01` | One camera, one tile, TCP, H.264, 60-minute soak with zero crashes and zero unbounded memory growth |
| **G2** | Usable beta | All P0 in areas INV, DSC, CRD, LIV, STR, DEC, REN, AUD, PTZ, CAP, HLT | 16 cameras live for 8 hours inside the §10 budget; Stream Doctor correctly diagnoses all 6 seeded fault modes |
| **G3** | **1.0** | **All P0** | §13 checklist green on both reference machines; all six reference devices pass; localization complete; accessibility audit clean |
| **G4** | 1.1 | All P1 | — |

---

## 4. P0 — Camera inventory and discovery

### F-INV-01 · Camera library `P0`
**Modules:** VigilCore (ConfigStore, Camera) · VigilUI
**What:** A persistent library of camera records — name, host, HTTP/RTSP ports, TLS flag, channel,
stream profile, transport, credential reference, group, order, colour tag, enabled flag, capability
snapshot, `createdAt`, `lastSeenAt`.
**Acceptance:**
1. `[A]` Adding, renaming, reordering, duplicating, disabling and deleting a camera persists across
   relaunch. Round-trip of a 200-camera library is byte-stable (`encode(decode(x)) == x`).
2. `[A]` `library.json` lives at `~/Library/Application Support/Vigil/library.json`, is written
   atomically (temp file + `FileManager.replaceItemAt`), saves debounced/coalesced over 500 ms, and
   keeps one `.bak` generation.
3. `[A]` A truncated, empty, or syntactically invalid `library.json` is recovered from `.bak`; if
   both are bad the app launches with an empty library and surfaces a non-modal "Library could not
   be read" notice with a "Reveal in Finder" action. It never crashes and never silently deletes.
4. `[A]` The document carries `schemaVersion`; a version below current runs the migration chain; a
   version *above* current refuses to load and warns instead of corrupting.
5. `[A]` No credential material appears anywhere in the serialized document (asserted by a test that
   searches the encoded bytes for the test password, its UTF-16 form, and its Base64 form).
**Risk:** *Low.*

### F-INV-02 · Camera groups `P0`
**Modules:** VigilCore · VigilUI
**What:** Named, ordered, colour-tagged groups of cameras (e.g. "Perimeter", "Interior"); a camera
belongs to at most one group.
**Acceptance:**
1. `[A]` Create/rename/delete/reorder groups; drag a camera between groups in the sidebar; deleting
   a group leaves its cameras ungrouped rather than deleting them.
2. `[A]` A group is a first-class target: "open group in stage" fills the current layout with the
   group's cameras in order, "snapshot group", "mute group".
3. `[A]` Groups round-trip through export/import (`F-DAT-01`).
**Risk:** *Low.*

### F-INV-03 · Manual camera add `P0`
**Modules:** VigilUI · VigilISAPI · VigilCore
**What:** A form to add a device by host with an immediate credential + capability test.
**Acceptance:**
1. `[A]` Fields: name, host (IPv4/IPv6/hostname), HTTP port (default 80, 443 when TLS), RTSP port
   (default 554), TLS toggle, username, password, channel (default 1), transport (Auto/TCP/UDP).
2. `[H]` "Test" completes in ≤ 3 s and reports exactly one of six distinct outcomes with distinct
   copy: **OK** (shows model, firmware, channel count) · **Wrong username or password** (HTTP 401
   after a valid Digest challenge) · **Account locked** (Hikvision returns
   `<statusCode>4</statusCode><subStatusCode>userLocked</subStatusCode>`, HTTP 401/403) ·
   **Unreachable** (TCP connect timeout/refused) · **Not a Hikvision device** (no `/ISAPI/System/
   deviceInfo`, but something answers → offer the ONVIF path, `F-DSC-05`) · **Device not activated**
   (`F-DSC-04`).
3. `[A]` The test never blocks the UI; cancelling it cancels the underlying task within 100 ms.
4. `[A]` Duplicate detection: adding an existing host+port+channel warns and offers "edit existing".
**Risk:** *Medium* — Hikvision error-code semantics vary across firmware. *Mitigation:* map on
`(httpStatus, statusCode, subStatusCode)` triples with a table of known values plus a generic
fallback; the table is data, not code, and is unit-tested from captured fixtures.

### F-DSC-01 · SADP automatic discovery `P0`
**Modules:** VigilDiscovery (codec, pure) · VigilTransport (sockets) · VigilUI
**What:** Find Hikvision devices on the local link with Hikvision's SADP protocol.
**Acceptance:**
1. `[A]` Encode/decode of the SADP probe and inquiry-response XML is pure, Linux-testable, and
   covered by at least 12 captured real-device fixtures including malformed and truncated ones.
2. `[H]` Devices are sent a multicast probe to `239.255.255.250:37020` from a socket bound to
   `0.0.0.0:37020` with `SO_REUSEADDR`/`SO_REUSEPORT`, repeated at 0 s, 1 s, 3 s, 7 s; responses
   arrive on the same port. Discovery on a LAN with C1–C4 present finds all four within 3 s.
2b. `[H]` The probe is sent **per interface** (enumerated via `NWInterface`/`getifaddrs`, skipping
   loopback and down interfaces) so multi-homed Macs and Thunderbolt/USB Ethernet dongles work.
3. `[A]` Parsed fields: MAC, IPv4/IPv6, device model, serial, firmware version + build date, HTTP
   port, device description, DHCP flag, subnet mask, gateway, **activation state**, encryption
   support flag.
4. `[A]` Results are deduplicated by MAC (not IP), merged with the existing library so already-added
   devices show as "Added", and sorted by IP.
5. `[A]` Discovery is cancellable and leaks no socket: after 100 start/stop cycles the process FD
   count returns to baseline ±2.
**Risk:** *Medium* — SADP is undocumented and the payload layout differs between generations.
*Mitigation:* lenient parsing (unknown fields ignored, missing fields optional), and WS-Discovery
(`F-DSC-02`) plus subnet sweep (`F-DSC-03`) as independent discovery paths so no single protocol is
load-bearing.

### F-DSC-02 · ONVIF WS-Discovery `P0`
**Modules:** VigilDiscovery · VigilTransport · VigilUI
**What:** Standards-based discovery of any ONVIF device, Hikvision or not.
**Acceptance:**
1. `[A]` SOAP `Probe` for `dn:NetworkVideoTransmitter` **and** `tds:Device` is sent to
   `239.255.255.250:3702` (IPv6 `[ff02::c]:3702`) with a fresh `urn:uuid:` MessageID; `ProbeMatch`
   responses are parsed for `XAddrs`, `Types`, `Scopes` (name, hardware, location).
2. `[A]` The XML builder/parser is pure and Linux-tested against 10 captured `ProbeMatch` bodies
   from at least three vendors, including one with `soap:Envelope` prefixed differently and one with
   a UTF-8 BOM.
3. `[H]` Discovery merges SADP and WS-Discovery results into one list, correlating by IP and MAC;
   a Hikvision device found by both appears once.
**Risk:** *Low.*

### F-DSC-03 · Manual subnet sweep `P0`
**Modules:** VigilDiscovery (CIDR math, pure) · VigilTransport · VigilUI
**What:** When multicast is blocked (very common on managed switches and across VLANs), sweep a CIDR
range for open camera ports.
**Acceptance:**
1. `[A]` CIDR parsing and host enumeration are pure and correct for `/16`…`/32`, IPv4 and IPv6,
   reject `/8` with a clear message, and exclude network and broadcast addresses.
2. `[A]` The default suggested range is derived from the Mac's active interface address and mask.
3. `[H]` A `/24` sweep probing TCP 80, 443, 554 and 8000 completes in ≤ 12 s with ≤ 64 concurrent
   connection attempts and a 600 ms per-host connect timeout; each responder is then fingerprinted
   with `GET /ISAPI/System/deviceInfo`.
4. `[A]` Progress is reported continuously (hosts scanned / total, found count) and the sweep is
   cancellable within 300 ms.
5. `[A]` **First-run consent:** the sweep is active probing of the user's network, so the first time
   it is invoked a one-time sheet explains what packets are sent and to which range, and requires
   explicit confirmation. The choice is remembered; the range is always shown before scanning.
**Risk:** *Medium* — an aggressive sweep can trip IDS or exhaust cheap-router state tables.
*Mitigation:* hard concurrency cap of 64, 600 ms timeout, no retries, and the consent sheet.

### F-DSC-04 · Unactivated-device detection and warning `P0`
**Modules:** VigilDiscovery · VigilISAPI · VigilUI
**What:** Hikvision devices ship *unactivated* — no admin password set — and refuse ISAPI and RTSP
until activated. Detect this and explain it instead of showing an auth error.
**Acceptance:**
1. `[A]` A SADP response with the activation field false, **or** an ISAPI reply carrying
   `<statusCode>7</statusCode>` / `deviceNotActivated`, **or** HTTP 401 from a device whose SADP
   record says unactivated, all classify the device as `.notActivated`.
2. `[M]` In the discovery list such a device shows an amber "Not activated" chip, is not selectable
   for a normal add, and its detail panel reads:
   > **This camera hasn't been set up yet.**
   > It has no password, so it can't stream video. Activate it with a strong password using
   > Hikvision SADP or the camera's web page, then scan again.
   with a "Copy IP address" button and an "Open camera web page" button (`http://<ip>/`).
3. `[A]` Attempting to add an unactivated device by hand (`F-INV-03`) produces the same explanation,
   never "wrong password".
4. `[A]` Password-strength guidance shown in that panel matches Hikvision's real requirement:
   8–16 characters, at least two of {lowercase, uppercase, digit, symbol}.
**Risk:** *Low* (detect + warn only). In-app activation is `F-DSC-08` (P1) precisely because writing
an admin password over the wire has real firmware variance and real consequences.

### F-DSC-05 · NVR / DVR channel enumeration `P0`
**Modules:** VigilISAPI · VigilCore · VigilUI
**What:** Discover every channel behind an NVR or DVR and add them as individual cameras in one step.
**Acceptance:**
1. `[H]` For C4, `GET /ISAPI/ContentMgmt/InputProxy/channels` (IP channels) and
   `GET /ISAPI/System/Video/inputs/channels` (analog inputs) are merged with
   `GET /ISAPI/ContentMgmt/InputProxy/channels/status` to produce a list of channels with: channel
   number, name, online state, source IP, resolution and codec of main and sub streams.
2. `[A]` Empty and offline channels are shown but pre-unchecked; online channels are pre-checked.
3. `[A]` RTSP channel-ID arithmetic is centralized in one pure function and unit-tested:
   `rtspChannelID(channel: Int, stream: StreamKind) -> Int` = `channel * 100 + stream.rawValue`
   with `main = 1, sub = 2, third = 3`, producing the path `/Streaming/Channels/{id}`
   (e.g. channel 7 sub → `/Streaming/Channels/702`).
4. `[A]` Bulk add creates N camera records sharing **one** Keychain credential entry, named
   `<NVR name> · <channel name>` (falling back to `Camera 07`), placed in a group named after the
   NVR, with `orderIndex` following channel order.
5. `[H]` Re-running enumeration on an NVR whose channels changed updates names and online state
   without duplicating or orphaning existing records (match key: NVR camera id + channel number).
**Risk:** *Medium* — analog/hybrid DVRs expose channels differently and `InputProxy` is absent on
some. *Mitigation:* three independent enumeration sources, plus a fallback that probes
`/Streaming/Channels/{n}01` for n in 1…64 via RTSP `DESCRIBE` and keeps what answers 200.

### F-DSC-06 · Capability probe `P0`
**Modules:** VigilISAPI · VigilCore
**What:** On add and on every successful connect, snapshot what the device can do so the UI never
offers a control the device lacks.
**Acceptance:**
1. `[H]` Probe reads `/ISAPI/System/deviceInfo` (model, serial, firmware, MAC, device type),
   `/ISAPI/System/capabilities`, `/ISAPI/Streaming/channels/{id}` (codec, resolution, fps, bitrate,
   GOP), `/ISAPI/PTZCtrl/channels/{ch}/capabilities`, `/ISAPI/Image/channels/{ch}/capabilities`,
   `/ISAPI/System/TwoWayAudio/channels`, `/ISAPI/Event/triggers`.
2. `[A]` Produces a `DeviceCapabilities` value: `hasPTZ`, `hasPresets(count)`, `hasPatrols(count)`,
   `has3DPositioning`, `hasFocus`, `hasIris`, `hasTwoWayAudio(codec)`, `hasMJPEG`, `streamCount`,
   `supportedCodecs`, `hasVCA(types)`, `hasStorage`, `supportsISAPISearch`, `supportsSmartCodec`.
3. `[A]` Every probe is individually failure-tolerant: a 403 or 404 on one endpoint yields
   `capability = false` and never fails the whole probe. Total probe budget 4 s; partial results are
   kept and marked partial.
4. `[M]` UI controls bind to capabilities: no PTZ tab on a fixed dome, no two-way-audio button
   without `hasTwoWayAudio`, no MJPEG option on C2.
5. `[A]` The snapshot is persisted with a timestamp and re-probed on connect if older than 24 h or
   after a firmware-version change.
**Risk:** *Medium* — `/ISAPI/System/capabilities` returns wildly different trees. *Mitigation:*
capability detection is per-endpoint probing, not a single schema parse; the XML parser is lenient
(unknown elements ignored, missing = absent) and never throws on unexpected structure.

### F-DSC-07 · ONVIF fallback for non-Hikvision devices `P0`
**Modules:** VigilISAPI (ONVIF SOAP builders/parsers) · VigilRTSP · VigilCore · VigilUI
**What:** When ISAPI is absent, obtain stream URLs and basic control over ONVIF Profile S so the app
is useful with other vendors rather than refusing them.
**Acceptance:**
1. `[A]` SOAP request builders and lenient response parsers for: `GetSystemDateAndTime` (no auth,
   used for the WS-UsernameToken time skew), `GetCapabilities`, `GetDeviceInformation`,
   `GetProfiles`, `GetStreamUri` (RTP-Unicast/RTSP), `GetSnapshotUri`, `GetVideoEncoderConfiguration`,
   and PTZ `ContinuousMove`, `Stop`, `GotoPreset`, `GetPresets`. All pure and Linux-tested.
2. `[A]` WS-Security UsernameToken with `PasswordDigest = Base64(SHA1(nonce || created || password))`
   is built correctly, verified against the ONVIF specification's published example vector; `created`
   uses the device's clock corrected by the skew measured in step 1.
3. `[H]` C5 (non-Hikvision ONVIF camera) can be discovered, added, streamed live, snapshotted, and —
   if it advertises PTZ — panned, tilted and zoomed, and sent to presets.
4. `[M]` The camera's inspector shows an "ONVIF" badge and a note that Hikvision-specific features
   (patrols, 3D positioning, ISAPI event stream, ISAPI recording search) are unavailable; those
   controls are hidden, not disabled-with-no-explanation.
5. `[A]` A device that answers both ISAPI and ONVIF prefers ISAPI.
**Risk:** *High* — ONVIF interoperability is notoriously uneven and this is a second protocol stack.
*Mitigation:* scope is strictly Profile S discovery + stream URI + snapshot URI + basic PTZ. Nothing
else. Fallback if a vendor still fails: the user can add the camera manually with a raw RTSP path
(`F-STR-09`), which always works and is itself a P0.

---

## 5. P0 — Credentials and authentication

### F-CRD-01 · Keychain credential storage `P0`
**Modules:** VigilCore (CredentialStore) · Security framework
**What:** All camera usernames and passwords live in the macOS Keychain. Nowhere else, ever.
**Acceptance:**
1. `[A]` Items are `kSecClassInternetPassword` with `kSecAttrServer` = host, `kSecAttrPort` = HTTP
   port, `kSecAttrAccount` = username, `kSecAttrPath` = `/vigil/<credentialRef-uuid>`,
   `kSecAttrProtocol` = `kSecAttrProtocolHTTP`/`HTTPS`, `kSecAttrAccessible` =
   `kSecAttrAccessibleWhenUnlocked`, `kSecAttrLabel` = `Vigil — <camera name>`.
3. `[A]` `errSecDuplicateItem` triggers `SecItemUpdate`; `errSecItemNotFound` surfaces as a typed
   `CredentialError.notFound`; `errSecUserCanceled` and `errSecInteractionNotAllowed` produce
   distinct user-facing messages. Every `OSStatus` path is mapped, none is `fatalError`.
4. `[A]` Deleting a camera deletes its Keychain item unless another camera (e.g. another NVR
   channel) still references the same `credentialRef`; reference counting is unit-tested.
5. `[A]` An in-memory cache avoids repeated `SecItemCopyMatching` on the hot reconnect path; the
   cache is cleared on screen lock (`com.apple.screenIsLocked` distributed notification) and holds
   passwords in a `Credential` value type that overwrites its backing storage on deinit.
6. `[A]` A test asserts a password never appears in: `library.json`, any export produced by
   `F-DAT-01`, any OSLog message, or the diagnostics bundle (`F-DAT-04`).
**Risk:** *Low.*

### F-CRD-02 · RTSP and HTTP authentication `P0`
**Modules:** VigilProtocols (hashes) · VigilRTSP (Digest/Basic) · VigilISAPI
**What:** Digest (RFC 7616 / RFC 2617) and Basic authentication for both RTSP and ISAPI HTTP, in
pure Swift so it is Linux-testable.
**Acceptance:**
1. `[A]` **VigilProtocols ships pure-Swift `MD5`, `SHA1` and `SHA256`** implementations verified
   against the RFC 1321, FIPS 180-1 and FIPS 180-4 test vectors plus a 1 MB streaming test. This is
   mandatory: CryptoKit and CommonCrypto do not exist on Linux, and the auth code must compile and
   be tested in Linux CI. No other module may implement a hash.
2. `[A]` Digest supports `algorithm` = absent/`MD5`/`MD5-sess`/`SHA-256`/`SHA-256-sess`,
   `qop` = absent/`auth`, `nc` counting, client `cnonce` from a CSPRNG, `opaque` echo, and stale
   nonce re-challenge. Verified against the RFC 7616 §3.9.1 worked example byte-for-byte.
3. `[A]` The `A2` term uses the RTSP method and the **request-URI exactly as sent**, including the
   full `rtsp://host:port/path` form, because Hikvision computes it that way.
4. `[A]` A 401 with a new nonce causes exactly one retry per request; a second 401 fails as
   `.authenticationFailed` and does not loop.
5. `[A]` Credentials are **never** placed in an RTSP or HTTP URL. `rtsp://user:pass@host/...` is
   never constructed, so it can never be logged or displayed.
6. `[M]` Basic auth over plain HTTP is refused by default; it requires a per-camera opt-in with the
   warning "This camera only supports Basic authentication, which sends your password in a form that
   anyone on your network can read." Digest is always preferred when offered.
**Risk:** *Medium* — Hikvision Digest quirks (URI form, `qop` handling). *Mitigation:* fixture-driven
tests captured from all six reference devices; the RTSP layer logs the exact challenge at debug level
with the response elided.

### F-CRD-03 · Lockout and credential-change handling `P0`
**Modules:** VigilISAPI · VigilCore · VigilUI
**What:** Hikvision locks an account after ~5 failed attempts for ~30 minutes. Never cause that, and
explain it when it happens.
**Acceptance:**
1. `[A]` After an authentication failure a camera enters `.authFailed` and **stops retrying**. It
   does not participate in the reconnect backoff loop. Only an explicit user action (edit
   credentials, or "Retry now") resumes it.
2. `[M]` The tile shows "Sign-in failed" with an "Update password…" button that opens the credential
   editor pre-filled with the username.
3. `[A]` A detected lockout shows the remaining time if the device reports it, otherwise "Try again
   in about 30 minutes", and schedules no automatic retries.
4. `[A]` Changing a password updates the Keychain item and immediately reconnects every camera
   sharing that `credentialRef`.
**Risk:** *Low.* This criterion exists because the naive design — retry with backoff on 401 — locks
the user out of their own NVR. It is a release blocker.

---

## 6. P0 — Live view, layouts and the stage

### F-LIV-01 · Multi-camera live stage `P0`
**Modules:** VigilUI · VigilCore (StreamCoordinator) · VigilRender
**What:** The stage shows 1–16 live tiles in the selected layout, each tile an independent video
surface with its own state.
**Acceptance:**
1. `[A]` 16 tiles can be live simultaneously within the §10 budget.
2. `[A]` Each tile independently renders one of: connecting skeleton with progress narration, live
   video, degraded video with a loss banner, offline with the last frame dimmed 60 % plus a retry
   countdown, auth-failed, or empty "assign a camera".
3. `[M]` Tiles maintain aspect ratio with a per-tile Fit/Fill toggle; letterbox bars use the design
   system's `surface.sunken` colour, never pure black, and are pixel-exact with no 1 px seams at any
   backing scale factor.
4. `[A]` Adding, removing or reassigning a tile does not interrupt any other tile: a test asserts
   zero dropped frames on tiles 1–15 while tile 16 is reassigned 20 times.
5. `[A]` Frame time p99 ≤ 7.0 ms at 120 Hz with 16 tiles live (§10).
**Risk:** *Medium* — 16 concurrent `AVSampleBufferDisplayLayer` instances in a SwiftUI hierarchy can
cause layer-tree thrash. *Mitigation:* tiles are `NSViewRepresentable` with a stable identity keyed
by camera UUID, views are recycled rather than rebuilt on layout change, and the layout container is
an `NSView` doing manual frame math rather than nested SwiftUI stacks.

### F-LIV-02 · Layout modes `P0`
**Modules:** VigilUI · VigilCore (Layout)
**What:** Fixed and custom layouts covering the standard NVR-client vocabulary.
**Acceptance:**
1. `[A]` Modes: `1`, `1+2`, `2×2`, `1+5`, `3×3`, `1+7`, `2+8`, `4×4`. Each is a pure function from
   mode → array of normalized `CGRect` cells, unit-tested for: cells sum to the full unit square, no
   overlaps, deterministic ordering, and stability across resizes.
2. `[A]` A **custom mosaic** mode allows drag-resizing cell boundaries on a 12×12 snap grid and
   merging adjacent cells; custom layouts persist and are exportable.
3. `[A]` Switching layouts preserves camera assignments where cell counts allow: cameras keep their
   index; surplus cameras move to an overflow list and return when the layout grows again. Switching
   `3×3 → 2×2 → 3×3` is lossless.
4. `[M]` Layout switch is animated with a spring (response 0.35, damping 0.86), completes in
   ≤ 600 ms with cached sessions, and never shows a black frame — the previous frame is held.
5. `[A]` `⌘1`…`⌘8` select modes; the View menu mirrors them with the same shortcuts.
**Risk:** *Low.*

### F-LIV-03 · Named layout presets `P0`
**Modules:** VigilCore · VigilUI
**What:** Save the current layout mode plus its exact cell→camera mapping as a named preset.
**Acceptance:**
1. `[A]` Save, rename, delete, reorder, duplicate presets; a preset stores mode, custom geometry,
   cell→camera-UUID map, per-tile stream-quality overrides and per-tile mute state.
2. `[A]` Recalling a preset restores all of the above; a preset referencing a deleted camera shows
   that cell as "Camera unavailable" and does not fail the recall.
3. `[A]` `⌥⌘1`…`⌥⌘9` recall the first nine presets; presets appear in the command palette, the View
   menu, the menu-bar extra, and as an App Intent parameter.
4. `[A]` Presets survive export/import and are included in the encrypted export.
**Risk:** *Low.*

### F-LIV-04 · Tile chrome and per-tile actions `P0`
**Modules:** VigilUI · VigilCore
**What:** Hover/focus chrome giving every per-camera action without leaving the stage.
**Acceptance:**
1. `[M]` On hover or keyboard focus, chrome fades in over 120 ms: camera name, status dot, live
   stats pill (codec · resolution · fps · kbps), and buttons for mute, snapshot, record, PTZ,
   fullscreen, main/sub toggle, fit/fill, close.
2. `[A]` Chrome is fully keyboard reachable: `⌥←/→/↑/↓` moves tile focus, `Tab` cycles the focused
   tile's controls, `Return` activates. Chrome is always in the accessibility tree even when
   visually hidden.
3. `[M]` Chrome respects Reduce Motion (instant, no fade) and Reduce Transparency (opaque backing).
4. `[A]` Double-click toggles single-camera fullscreen for that tile; `Esc` returns.
**Risk:** *Low.*

### F-LIV-05 · Digital zoom and pan `P0`
**Modules:** VigilRender (Metal) · VigilUI
**What:** Client-side zoom into the decoded frame with pan, independent of optical PTZ.
**Acceptance:**
1. `[A]` Zoom range 1.0×–8.0×, applied as a source-rect transform in the Metal renderer with no
   re-decode and no extra frame copy. Zoom does not change CPU cost by more than 0.3 % per stream.
2. `[M]` Scroll wheel / trackpad pinch zooms around the pointer; drag pans; the pan is clamped so
   the frame edge never leaves the tile; double-click resets to 1.0× with a spring.
3. `[M]` A zoom indicator (`2.4×`) and a picture-in-picture locator rectangle appear while zoomed and
   fade after 1.5 s of inactivity.
4. `[A]` Zoom state is per-tile, survives layout changes and reconnects, and is *not* persisted
   across app launches (deliberate: a stale 8× zoom on relaunch reads as a broken camera).
5. `[A]` Sampling uses bilinear filtering below 2× and Lanczos-style 3-tap sharpening above 4× to
   avoid mush; verified by an image-diff test against reference renders (SSIM ≥ 0.98).
**Risk:** *Low.*

### F-LIV-06 · Camera cycling (patrol view) `P0`
**Modules:** VigilCore (StreamCoordinator) · VigilUI
**What:** Rotate a set of cameras through the current layout on a timer, like an NVR's auto-switch.
**Acceptance:**
1. `[A]` Dwell time configurable 3–300 s (default 10 s); source is "all cameras", a group, or a
   manual selection; order follows `orderIndex` or is shuffled.
2. `[A]` Offline cameras are skipped after one failed attempt and retried on the next full cycle;
   if every camera is offline the cycle pauses with an explanation rather than flashing.
3. `[M]` The next page is pre-warmed: its streams start 1.5 s before the switch so the transition
   shows video, not skeletons. Transition is a 250 ms crossfade (instant under Reduce Motion).
4. `[A]` Cycling pauses on any user interaction with the stage (pointer, key, PTZ) and resumes after
   15 s of idle; a persistent "Cycling · resumes in 12 s" pill shows state with a pause button.
5. `[A]` Cycling respects the decode budget: pre-warm never exceeds the global limit (`F-DEC-06`).
**Risk:** *Medium* — pre-warming doubles peak stream count at the switch boundary. *Mitigation:* the
coordinator reserves budget for pre-warm and drops pre-warm to zero (accepting a skeleton) when the
budget is tight.

### F-LIV-07 · Second-display video wall `P0`
**Modules:** VigilUI · VigilCore · VigilRender · AppKit
**What:** A dedicated borderless full-screen wall window on a second display with its own layout,
independent of the main window.
**Acceptance:**
1. `[M]` "Open Video Wall on <display>" targets any connected `NSScreen`; the window is borderless,
   covers the screen, hides all chrome, and disables the screen saver and display sleep for that
   display via `NSProcessInfo.beginActivity(options: .idleDisplaySleepDisabled)`.
2. `[A]` The wall has its own layout, preset and camera assignment, persisted separately.
3. `[A]` Disconnecting the wall's display migrates the wall to the main display as a normal window
   within 1 s and never leaves an orphaned off-screen window
   (`CGDisplayRegisterReconfigurationCallback` is handled).
4. `[A]` Wall streams count against the same global decode budget; opening a 16-tile wall while the
   main window shows 16 tiles applies the priority policy (`F-DEC-06`) rather than exceeding budget.
5. `[M]` `⌘⌃F` toggles the wall; `Esc` closes it; a small always-visible corner affordance explains
   how to exit (a wall with no exit hint is a support call).
**Risk:** *Medium* — multi-display and display-reconfiguration edge cases. *Mitigation:* explicit
reconfiguration callback handling plus a manual matrix of plug/unplug, sleep, resolution change and
mirroring changes in the release checklist.

### F-LIV-08 · Picture-in-picture `P0`
**Modules:** VigilRender · VigilUI · AVKit
**What:** Float one camera in the system PiP window so it stays visible over other apps.
**Acceptance:**
1. `[A]` Implemented with `AVPictureInPictureController` initialized from
   `AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:playbackDelegate:)`,
   the same `AVSampleBufferDisplayLayer` the tile uses, with an
   `AVPictureInPictureSampleBufferPlaybackDelegate` reporting a live (indefinite) time range.
2. `[M]` PiP survives closing the main window; closing PiP returns the camera to its tile; only one
   PiP at a time and switching cameras retargets the existing PiP window.
3. `[A]` A stream in PiP is pinned at `main` or `sub` per the PiP window's pixel size using the same
   policy table as tiles (`F-STR-06`), and is exempt from occlusion pausing.
4. `[M]` PiP controls: play/pause is hidden (live), skip controls are hidden, and the camera name is
   the title.
**Risk:** *Medium* — the sample-buffer PiP API is sparsely documented for live sources.
*Mitigation:* spike in G2. Fallback that still satisfies a reduced criterion: a custom always-on-top
`NSPanel` at `.floating` level with our own resize/drag, which we control completely.

---

## 7. P0 — RTSP session and transports

### F-STR-01 · RTSP client `P0`
**Modules:** VigilRTSP (pure) · VigilTransport (sockets)
**What:** A complete RTSP 1.0 (RFC 2326) client: `OPTIONS`, `DESCRIBE`, `SETUP`, `PLAY`, `PAUSE`,
`TEARDOWN`, `GET_PARAMETER`, plus `SET_PARAMETER` where used.
**Acceptance:**
1. `[A]` Message serialization and parsing are pure, byte-exact, and handle: CRLF and bare-LF line
   endings, header folding, duplicate headers, case-insensitive header names, absent `Content-Length`
   on bodyless replies, and interleaved binary data arriving mid-header.
2. `[A]` The session state machine is transport-agnostic — driven only by injected bytes plus an
   injected clock — and is tested end-to-end against the synthetic RTSP server fixture with no
   sockets involved.
3. `[A]` `CSeq` monotonicity, `Session` id + timeout parsing (`Session: 12345678;timeout=60`),
   `Require`/`Unsupported` handling, and `RTP-Info` (`url=…;seq=…;rtptime=…`) parsing for the
   initial timestamp mapping.
4. `[A]` Keepalive: `GET_PARAMETER` (or `OPTIONS` if `GET_PARAMETER` is not in the device's `Public`
   header) at `timeout / 2`, minimum every 25 s, never later than 5 s before expiry.
5. `[A]` Every state has a timeout: connect 4 s, `OPTIONS` 3 s, `DESCRIBE` 5 s, `SETUP` 4 s,
   `PLAY` 4 s, first RTP packet 4 s, first keyframe 6 s. Each timeout maps to a distinct typed error
   consumed by Stream Doctor (`F-HLT-06`).
6. `[A]` `TEARDOWN` is best-effort with a 1 s budget on stop; the socket is closed regardless and no
   task is left running (asserted by a task-leak test).
**Risk:** *Medium* — real devices deviate from RFC 2326 in small ways. *Mitigation:* lenient parsing,
a fixture corpus of real captured sessions from all six reference devices, and a documented
"quirks" table keyed by `Server:` header.

### F-STR-02 · SDP parsing `P0`
**Modules:** VigilRTSP (pure)
**What:** Parse the `DESCRIBE` response body to learn tracks, codecs and parameters.
**Acceptance:**
1. `[A]` Parses `v= o= s= i= c= t= a= m=` lines; per-media `a=rtpmap`, `a=fmtp`, `a=control`,
   `a=range`, `a=framerate`, `a=x-dimensions`, `a=recvonly/sendonly`, `a=ts-refclk`.
2. `[A]` Extracts for H.264: `packetization-mode`, `profile-level-id`, and Base64
   `sprop-parameter-sets` split into SPS and PPS. For H.265: `sprop-vps`, `sprop-sps`, `sprop-pps`.
   For AAC: `streamtype`, `profile-level-id`, `mode=AAC-hbr`, `config` hex (AudioSpecificConfig),
   `sizeLength`, `indexLength`, `indexDeltaLength`.
3. `[A]` Resolves relative vs absolute `a=control` values against the `Content-Base`, `Content-
   Location` and request URI in that precedence order — the single most common source of `SETUP` 454
   failures.
4. `[A]` Unknown media types and unknown attributes are ignored, not fatal; a stream with a video
   track and an unparseable audio track still plays video.
5. `[A]` Fuzz: 100 000 mutated SDP bodies produce errors or valid results, never a crash, hang or
   allocation above 4 MB.
**Risk:** *Low.*

### F-STR-03 · RTSP over TCP (interleaved) `P0`
**Modules:** VigilTransport · VigilRTP
**What:** `SETUP` with `Transport: RTP/AVP/TCP;unicast;interleaved=0-1`, RTP and RTCP framed inside
the RTSP TCP connection.
**Acceptance:**
1. `[A]` The interleaved framing (`$`, channel byte, 16-bit big-endian length) is de-framed correctly
   across arbitrary TCP segment boundaries, including a frame header split across two reads and a
   `$` byte appearing inside payload data.
2. `[A]` Interleaved data and RTSP replies can be interleaved arbitrarily; the parser handles a
   reply arriving between two data frames.
3. `[H]` All six reference devices stream over TCP. TCP is the **default transport**, because it
   traverses switches and VLANs reliably and never loses packets silently.
4. `[A]` `TCP_NODELAY` is set; the receive path uses `NWConnection.receive(minimumIncompleteLength:
   1, maximumLength: 65535)` and never copies the payload more than once before depacketization.
5. `[A]` Glass-to-glass p95 ≤ 250 ms over TCP (§10).
**Risk:** *Low.*

### F-STR-04 · RTSP over UDP (unicast) `P0`
**Modules:** VigilTransport · VigilRTP
**What:** `SETUP` with `Transport: RTP/AVP;unicast;client_port=N-N+1`, RTP on an even port, RTCP on
the next odd port.
**Acceptance:**
1. `[A]` A consecutive even/odd port pair is allocated in 50000–60000; on collision it retries up to
   8 times with a different base; the pair is released on teardown.
2. `[A]` `server_port` and `source` from the `SETUP` reply are honoured; packets from an unexpected
   source are dropped and counted (a metric, not a log spam).
3. `[A]` NAT/firewall hole punching: two 4-byte empty RTP and one RTCP RR packet are sent to the
   server ports immediately after `SETUP`.
4. `[A]` Socket receive buffer is raised to 4 MB (`SO_RCVBUF`) and the actual granted size is logged;
   if the OS grants < 1 MB a warning is recorded because loss becomes likely.
5. `[H]` Glass-to-glass p95 ≤ 180 ms over UDP; UDP is measurably lower latency than TCP on the same
   camera in the release checklist.
6. `[A]` Packet loss is measured (`F-HLT-01`) and, above 2 % sustained for 10 s, the session
   automatically falls back to TCP once per hour, telling the user: "Switched to TCP because 4 % of
   packets were being lost."
**Risk:** *Medium* — loss and reordering behaviour is network-specific. *Mitigation:* the jitter
buffer (`F-STR-05`) plus automatic TCP fallback, and TCP as the shipping default.

### F-STR-05 · Jitter / reorder buffer `P0`
**Modules:** VigilRTP (pure)
**What:** Restore RTP sequence order, absorb jitter, and detect loss without adding avoidable delay.
**Acceptance:**
1. `[A]` Reorder window is time-bounded, not just count-bounded: default 60 ms target depth,
   configurable via the latency preset (Low 30 ms / Balanced 60 ms / Quality 150 ms), hard cap
   400 ms. Buffer depth is a reported metric.
2. `[A]` 16-bit sequence wraparound, duplicate packets, and a 3-packet reorder are all handled
   correctly; a unit test replays a captured trace with injected loss/reorder/duplication and
   asserts the exact output frame sequence.
3. `[A]` A gap that does not resolve within the window is declared lost: the affected access unit is
   dropped **whole** (never fed a partial frame to the decoder), a `frameDropped(reason: .loss)`
   event is emitted, and a keyframe is requested (`F-DEC-05`).
4. `[A]` RFC 3550 interarrival jitter `J` is computed exactly per §6.4.1 and exposed in stats.
5. `[A]` Memory is bounded: the buffer never holds more than 512 packets or 4 MB per stream,
   whichever comes first; overflow drops oldest and counts it.
**Risk:** *Medium* — depth is a direct latency/robustness trade. *Mitigation:* adaptive depth
(grow on measured jitter, shrink slowly after 30 s of stability) with the preset as the ceiling, and
the depth surfaced in the UI so behaviour is explainable.

### F-STR-06 · Automatic main/sub stream selection by tile size `P0`
**Modules:** VigilCore (StreamCoordinator) · VigilUI
**What:** Pick the stream whose resolution matches the tile's real pixel size, automatically. This is
the single biggest lever on CPU and bandwidth and it must be automatic, not a user chore.
**Acceptance:**
1. `[A]` The decision input is the tile's **short edge in physical pixels** =
   `min(width, height) × window.backingScaleFactor`, recomputed on resize, layout change, display
   change and scale-factor change.
2. `[A]` The canonical policy table (this table is normative; `spec-core.md` must implement exactly
   it):

   | Tile short edge (physical px) | Source | Notes |
   |---|---|---|
   | Tile hidden / occluded / window minimized | **Paused** | session kept alive with `PAUSE`, or torn down after 60 s |
   | 1 – 95 | **ISAPI JPEG poll @ 1 Hz** | sidebar micro-thumbnails; no decoder session at all |
   | 96 – 479 | **Sub stream** | typical 4×4 tile |
   | 480 – 1079 | **Sub stream**, promoted to main if the sub stream's height < 0.75 × tile short edge and budget allows | avoids visible softness on 3×3 |
   | ≥ 1080 | **Main stream** | 1-up, fullscreen, PiP, wall |

3. `[A]` **Hysteresis:** a switch requires the new bucket to hold for ≥ 750 ms and the size to move
   ≥ 15 % past the threshold. A continuous window drag from 4×4 to 1-up produces **at most one**
   stream switch, asserted by a test that replays a 60-frame resize animation.
4. `[M]` Switching is seamless: the old stream keeps rendering until the new stream's first keyframe
   is decoded, then a 150 ms crossfade. No black frame, ever.
5. `[A]` The user can override per tile (`Auto` / `Main` / `Sub` / `Third`); an override disables
   automatic switching for that tile and is shown in the stats pill as `Main (locked)`.
6. `[A]` A camera with only one stream, or whose sub stream fails `DESCRIBE`, silently uses what
   exists and records a capability note.
**Risk:** *Medium* — switch thrash and visible flicker are the failure modes. *Mitigation:* the
hysteresis rule and the keyframe-gated crossfade are both acceptance criteria, not implementation
details.

### F-STR-07 · Transport selection and negotiation `P0`
**Modules:** VigilCore · VigilTransport
**What:** Per-camera transport choice with a working `Auto` mode.
**Acceptance:**
1. `[A]` Setting is per-camera with a global default (default **TCP**): `Auto`, `TCP`, `UDP`.
2. `[A]` `Auto` = try TCP; if `SETUP` fails with 461 (Unsupported Transport) try UDP; if UDP yields
   no RTP within 4 s fall back to TCP and remember the working transport in the camera record.
3. `[A]` The chosen transport and the reason are visible in the inspector ("UDP — chosen
   automatically, 40 ms lower latency than TCP").
**Risk:** *Low.*

### F-STR-08 · Multicast reception `P0`
**Modules:** VigilTransport · VigilCore
**What:** Join a device's multicast stream when configured, which is how a single NVR feeds many
clients without duplicating unicast bandwidth.
**Acceptance:**
1. `[A]` `SETUP` with `Transport: RTP/AVP;multicast` is issued when the camera is set to multicast;
   the group address, port and TTL are taken from the `SETUP` reply.
2. `[A]` The group is joined with `NWConnectionGroup` + `NWMulticastGroup` on the correct interface,
   and left cleanly on teardown; a leak test asserts group membership count returns to zero.
3. `[A]` The `com.apple.developer.networking.multicast` entitlement is present and its absence is
   detected at runtime, producing "Multicast isn't permitted for this build" rather than a silent
   no-data hang.
4. `[A]` No RTP within 5 s of joining yields `.multicastBlocked`, which Stream Doctor maps to the
   actionable fix "Your switch is filtering multicast (IGMP snooping without a querier). Use TCP or
   UDP unicast instead." and offers a one-click switch.
**Risk:** *High* — multicast requires the entitlement, correct interface selection, and network
support that frequently is absent. *Mitigation:* multicast is opt-in per camera and never the
default; the acceptance criteria centre on *failing clearly*, and the `.multicastBlocked` diagnosis
plus one-click fallback is the real shipped value.

### F-STR-09 · Custom RTSP path override `P0`
**Modules:** VigilCore · VigilRTSP · VigilUI
**What:** An escape hatch: let the user type the exact RTSP path (or full URL) for a device we can't
model.
**Acceptance:**
1. `[A]` A per-camera optional `rtspPathOverride` (e.g. `/cam/realmonitor?channel=1&subtype=0`) and
   an optional full-URL override are honoured for main, sub and third independently.
2. `[A]` Credentials are still taken from the Keychain even if the user pastes a URL containing
   userinfo; the userinfo is stripped and discarded, never stored.
3. `[M]` The inspector shows the effective URL with the password masked
   (`rtsp://admin:••••••@192.168.1.64:554/Streaming/Channels/101`) and a "Copy URL (without
   password)" button.
4. `[A]` A path-suggestion list for common vendors (Hikvision, Dahua, Axis, Reolink, generic ONVIF)
   is offered when `DESCRIBE` returns 404.
**Risk:** *Low.* This is the reason a "device we've never seen" is never a dead end.

---

## 8. P0 — Decode, bitstream and render

### F-DEC-01 · H.264 support `P0`
**Modules:** VigilRTP (RFC 6184) · VigilBitstream · VigilVideo
**What:** Full H.264 receive path: depacketize, assemble access units, build the format description,
hardware decode.
**Acceptance:**
1. `[A]` Depacketizer handles single-NAL packets, `STAP-A` (type 24), `FU-A` (type 28) including
   fragments split across packet loss, and rejects `STAP-B`/`MTAP`/`FU-B` with a clear
   unsupported-mode error. Tested against a corpus of 200 000 real packets.
2. `[A]` Access-unit boundaries are detected from the RTP marker bit **and** validated by
   `first_mb_in_slice == 0` in the slice header, because some firmware sets the marker unreliably.
3. `[A]` SPS/PPS parsing yields width, height (including `frame_crop_*` and
   `chroma_format_idc`-aware cropping), profile, level, and fps from
   `time_scale / (2 × num_units_in_tick)` when `timing_info_present_flag` is set. Verified against
   40 real SPS blobs with known dimensions, including 1920×1080 with cropping, 2688×1520, 3840×2160.
4. `[A]` `avcC` records are built correctly (configurationVersion, profile, compat, level,
   `lengthSizeMinusOne = 3`, SPS/PPS arrays) and accepted by
   `CMVideoFormatDescriptionCreateFromH264ParameterSets`.
5. `[H]` All H.264 reference cameras decode in hardware with `kVTDecodeInfo_FrameDropped` never set
   during a 30-minute steady-state run.
**Risk:** *Low* for the common path, *Medium* for firmware quirks. *Mitigation:* the marker-bit
validation criterion and a bitstream corpus in the repo.

### F-DEC-02 · H.265 / HEVC support `P0`
**Modules:** VigilRTP (RFC 7798) · VigilBitstream · VigilVideo
**What:** Full HEVC receive path including Hikvision's "H.265+" smart codec output.
**Acceptance:**
1. `[A]` Depacketizer handles single NAL, Aggregation Packets (type 48) and Fragmentation Units
   (type 49) with the correct 2-byte NAL header handling and `DONL` support when `sprop-max-don-diff
   > 0`.
2. `[A]` VPS/SPS/PPS parsing yields width/height with conformance-window cropping, profile/tier/
   level, chroma format, bit depth, and fps from VUI. Verified against 25 real HEVC parameter sets
   including 4K and 5 MP Hikvision streams.
3. `[A]` `hvcC` records are built correctly and accepted by
   `CMVideoFormatDescriptionCreateFromHEVCParameterSets`. `general_profile_space`, `constraint
   indicator flags` and `numTemporalLayers` are populated, not zeroed.
4. `[H]` C2 and C3 (H.265+) decode in hardware. A long-GOP H.265+ stream with a 100-frame GOP
   reaches first frame within 6 s worst case and immediately when `F-DEC-05` forces a keyframe.
5. `[A]` A device advertising HEVC on a Mac without HEVC hardware decode (`VTIsHardwareDecode
   Supported(kCMVideoCodecType_HEVC) == false`) is detected before `SETUP` and the sub stream (H.264)
   is used instead, with an explanatory note. We never silently software-decode 4K HEVC.
**Risk:** *Medium* — HEVC parameter-set parsing is intricate and `hvcC` errors produce a silent
"no frames" failure. *Mitigation:* golden-file tests comparing our `hvcC` bytes against records
extracted from `ffprobe`-verified reference MP4s checked into the repo as fixtures.

### F-DEC-03 · MJPEG support `P0`
**Modules:** VigilRTP (RFC 2435) · VigilVideo · VigilISAPI
**What:** MJPEG both over RTP and over HTTP, needed for budget cameras and as a universal fallback.
**Acceptance:**
1. `[A]` RFC 2435 JPEG/RTP: main header (type-specific, fragment offset, type, Q, width, height),
   restart-marker header for types 64–127, and quantization-table header for `Q ≥ 128`. A complete
   JFIF frame is reconstructed by synthesizing the SOI/DQT/SOF0/DHT/SOS headers from RFC 2435
   Appendix A/B tables. Verified by decoding reconstructed frames and comparing to reference JPEGs
   (SSIM ≥ 0.999).
2. `[A]` HTTP MJPEG (`multipart/x-mixed-replace`) from `/ISAPI/Streaming/channels/{id}/httpPreview`
   is parsed incrementally with boundary detection tolerant of missing `Content-Length`.
3. `[A]` Decode path: `VTDecompressionSession` with `kCMVideoCodecType_JPEG` when
   `VTIsHardwareDecodeSupported` reports availability; otherwise `CGImageSourceCreateWithData` +
   `CGImageSourceCreateImageAtIndex` on a background actor, uploaded to a Metal texture. The chosen
   path is reported in the hardware-decode indicator (`F-DEC-04`).
4. `[A]` MJPEG at 1 Hz for a micro-thumbnail costs ≤ 0.15 % CPU per camera and allocates no decoder
   session in the JPEG-poll mode of `F-STR-06`.
5. `[H]` C6's MJPEG third stream renders live.
**Risk:** *Medium* — JPEG-over-RTP header synthesis is fiddly and rarely exercised. *Mitigation:*
the SSIM golden test, plus HTTP MJPEG as an independent second path.

### F-DEC-04 · Hardware decode with a visible indicator `P0`
**Modules:** VigilVideo · VigilUI
**What:** Hardware decode via VideoToolbox, with honest, per-stream UI reporting of what is actually
happening.
**Acceptance:**
1. `[A]` Sessions are created with
   `kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder = true` and
   `kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder = true` by default; after
   creation, `VTSessionCopyProperty(kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder)`
   is read and stored as ground truth. We report what the API says, not what we asked for.
2. `[A]` If `Require` fails, we retry once with `Require = false`, and if that yields software decode
   the stream is marked `softwareDecode` and a one-time per-camera notice appears: "Hardware decode
   isn't available for this stream (H.265 4K on this Mac). Using software decode — expect higher CPU."
3. `[M]` The tile stats pill and the inspector show a chip: `HW` (green) / `SW` (amber) with a
   tooltip naming the codec and resolution. It is not a global setting readout — it is the measured
   state of *that* session.
4. `[A]` Output is `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` (or `…10BiPlanar` for 10-bit)
   with `kCVPixelBufferMetalCompatibilityKey = true` and an `IOSurface`-backed pool, so the render
   path is zero-copy. A test asserts no `CVPixelBufferLockBaseAddress` call occurs on the display
   path.
5. `[A]` Decode errors are classified: recoverable (`kVTVideoDecoderBadDataErr`,
   `kVTVideoDecoderReferenceMissingErr` → drop until next keyframe, request one) vs fatal
   (`kVTInvalidSessionErr` → rebuild session; `kVTVideoDecoderMalfunctionErr` → rebuild once, then
   fail the stream). Session rebuild completes in ≤ 300 ms and preserves the tile's last frame.
6. `[A]` Sessions are invalidated on stop; a test cycles 200 start/stops and asserts the
   VideoToolbox session count and IOSurface count return to baseline.
**Risk:** *Medium* — `VTDecompressionSession` behaviour under session invalidation (sleep/wake,
GPU reset) is a classic source of hangs. *Mitigation:* every decode call has a watchdog; two
consecutive watchdog expiries force a full session rebuild; the rebuild path is fuzz-tested by a
fault-injecting fake.

### F-DEC-05 · Instant-start keyframe request `P0`
**Modules:** VigilISAPI · VigilRTSP · VigilCore
**What:** Don't wait for the next natural keyframe — ask for one. This is worth up to 4 s on
long-GOP H.265+ streams and is the difference between "instant" and "broken".
**Acceptance:**
1. `[H]` On stream start and after an unrecoverable decode gap, an I-frame is requested via
   `PUT /ISAPI/Streaming/channels/{id}/requestKeyFrame` (and the legacy
   `/ISAPI/Streaming/channels/{id}/keyFrame` form on older firmware).
2. `[A]` If ISAPI is unavailable, `SET_PARAMETER` with `Frame-Rate`/vendor keyframe hints is tried;
   if nothing works we wait for the natural keyframe and this is reported in Stream Doctor as a
   slow-start cause with the fix "Reduce the camera's I-frame interval to 1× the frame rate".
3. `[A]` Requests are rate-limited to at most one per 2 s per channel.
4. `[M]` Median time-to-first-frame on C2 (H.265+, 100-frame GOP, 25 fps) improves from > 3 s to
   < 700 ms with the request enabled. Both numbers are recorded in the release checklist.
**Risk:** *Low.*

### F-DEC-06 · Decode budget, admission and priority `P0`
**Modules:** VigilCore (StreamCoordinator) · VigilVideo
**What:** A global admission-control policy so 40 configured cameras never melt the machine or drop
frames on the camera the user is actually looking at.
**Acceptance:**
1. `[A]` Cost is expressed in **decode units (DU)**, where 1 DU = 1080p30. Cost =
   `(width × height × fps) / (1920 × 1080 × 30)`, rounded up to 0.25 DU. Examples: 4K30 = 4.0 DU,
   1080p25 = 0.85 DU, 704×576@25 = 0.2 DU.
2. `[A]` Total budget: **24 DU** on Apple silicon, **10 DU** on Intel, detected at launch via
   `sysctlbyname("hw.optional.arm64")` plus core count; user-overridable in Settings ➝ Streams ➝
   "Maximum concurrent decodes".
3. `[A]` Priority order for admission: (1) focused tile, (2) tiles visible in the main window,
   (3) video-wall tiles, (4) PiP, (5) recording-only streams (always admitted — a recording must
   never be sacrificed for a preview), (6) offscreen/prewarm, (7) sidebar thumbnails (JPEG poll,
   0 DU). Within a class, lower `orderIndex` wins.
4. `[A]` Over budget, the lowest-priority streams are demoted main → sub → JPEG-poll → paused, in
   that order, before anything is dropped. A demotion always produces a visible tile badge and an
   inspector note explaining why.
5. `[A]` Recording streams are exempt from demotion and from occlusion pausing; a test asserts a
   recording continues for 60 s while its tile is closed.
6. `[A]` Admission decisions are deterministic and unit-testable: given a set of (camera, tile size,
   visibility, priority) inputs the resulting plan is a pure function.
**Risk:** *Medium* — a policy that fights the user (constantly demoting) is worse than no policy.
*Mitigation:* demotions require the same 750 ms dwell as `F-STR-06`, are always explained, and are
counted in the health stats so we can see thrash in the field.

### F-REN-01 · Video rendering `P0`
**Modules:** VigilRender · VigilVideo
**What:** Zero-copy display of decoded frames with correct colour and no tearing.
**Acceptance:**
1. `[A]` Default path is `AVSampleBufferDisplayLayer` fed `CMSampleBuffer`s with correct
   presentation timestamps; the Metal path (`F-REN-02`) is used when zoom, colour adjustment,
   overlays or cropping are active. Switching paths does not drop a frame.
2. `[A]` Colour: `kCVImageBufferYCbCrMatrixKey`, `TransferFunctionKey` and `ColorPrimariesKey` are
   attached from the SPS/VUI when present, defaulting to BT.709 for HD and BT.601 for SD. A test
   renders a known colour-bar bitstream and asserts per-patch ΔE < 2.0 against reference values.
3. `[A]` Frame pacing: frames are enqueued against a display-linked timebase driven by
   `CADisplayLink` (macOS 14) so a 25 fps camera on a 120 Hz display shows no judder pattern worse
   than ±1 refresh interval; measured over 3000 frames.
4. `[A]` No tearing, no partial frames, no black flashes on resize; verified by a UI test that
   screenshots during a 2 s resize animation and asserts no fully-black or half-drawn frame.
5. `[A]` `layer.controlTimebase` is set and, on stream stall, the last frame is held rather than
   cleared. `flushAndRemoveImage()` is only called on explicit stop or camera change.
**Risk:** *Medium* — `AVSampleBufferDisplayLayer` stalls if timestamps regress. *Mitigation:*
timestamps are rebased to a monotonic per-session timeline in one place, with an invariant assertion
in debug builds that PTS never regresses.

### F-REN-02 · Metal renderer: zoom, colour, overlays, crop `P0`
**Modules:** VigilRender (Metal, MetalKit)
**What:** A single fragment-shader pipeline doing YCbCr→RGB, digital zoom/pan, client-side colour
adjustment, cropping and overlay compositing in one pass.
**Acceptance:**
1. `[A]` Sampling of the biplanar `CVPixelBuffer` uses `CVMetalTextureCache` — no CPU copy, no
   `vImage` conversion on the display path.
2. `[A]` One pass performs: matrix conversion (BT.601/709/2020 selected by uniform), source-rect
   zoom/pan, brightness/contrast/saturation/gamma, and overlay blend. GPU cost ≤ 1.1 % per 1080p
   stream on M1 (§10).
3. `[M]` Overlays: camera name, timestamp (device time and/or Mac time), recording dot, motion
   boxes, digital-zoom locator, and a "no signal" state — all toggleable, all crisp at any backing
   scale factor (rendered from a signed-distance-field glyph atlas, not a scaled bitmap).
4. `[A]` Client-side colour adjustments are per-camera, persisted, and reset to neutral with one
   action. They are clearly labelled as affecting only what this Mac shows, not the camera.
5. `[A]` Renderer handles resolution changes mid-stream (camera reconfigured) by rebuilding textures
   without a visible glitch beyond one frame.
**Risk:** *Low.*

---

## 9. P0 — Audio

### F-AUD-01 · Audio playback with per-camera mute `P0`
**Modules:** VigilRTP (RFC 3640, G.711) · VigilVideo (AudioToolbox) · VigilUI
**What:** Decode and play the camera's audio track, muted by default, with per-camera and global
control.
**Acceptance:**
1. `[A]` Codecs: **G.711 µ-law (PT 0)** and **A-law (PT 8)** decoded in pure Swift via 256-entry
   lookup tables (unit-tested against the ITU-T G.711 reference tables, all 256 values); **AAC-LC**
   depacketized per RFC 3640 `AAC-hbr` (AU-headers-length prefix, `sizeLength=13, indexLength=3,
   indexDeltaLength=3`) and decoded with `AVAudioConverter` configured from the
   `AudioSpecificConfig` in the SDP `config=` parameter.
2. `[A]` Playback through `AVAudioEngine` → `AVAudioPlayerNode` with a scheduled-buffer queue holding
   80 ms target / 250 ms max; underrun inserts silence and is counted, never clicks or repeats a
   buffer.
3. `[A]` **Audio is muted by default on every camera** (16 tiles unmuting themselves is unusable).
   Per-camera mute persists; a global "Mute all" (`⇧⌘M`) and a "solo this camera" behaviour (unmute
   one, mute the rest) exist.
4. `[A]` At most **one** camera is unmuted by default when the user unmutes; the previous camera is
   muted with a 60 ms fade to avoid a pop. Simultaneous multi-camera audio is possible but requires
   an explicit "Allow multiple audio sources" setting.
5. `[A]` A/V sync: audio is presented against the same rebased timeline as video; measured skew
   |audio − video| ≤ 80 ms over a 10-minute run (measured with a clapper-board test on C2).
6. `[A]` Audio never blocks video: a failing or absent audio track leaves video untouched, and the
   audio decoder running at 100 % failure produces no video frame drops.
7. `[M]` A per-tile audio level meter (2 px bar) shows activity even when muted, so the user can see
   which camera has sound.
**Risk:** *Medium* — A/V sync with an independent audio clock is genuinely hard. *Mitigation:* video
is the master clock; audio is resampled by up to ±0.5 % via `AVAudioConverter` rate adjustment to
track it, and if drift exceeds 200 ms audio is re-anchored with a silent gap rather than allowed to
slide.

### F-AUD-02 · Two-way audio (push-to-talk) `P0`
**Modules:** VigilISAPI · VigilVideo (capture) · VigilUI
**What:** Hold a key or button to talk to the camera's speaker.
**Acceptance:**
1. `[H]` Session: `GET /ISAPI/System/TwoWayAudio/channels` to learn the channel id and codec, then
   `PUT /ISAPI/System/TwoWayAudio/channels/{id}/open`, then a long-lived chunked
   `PUT /ISAPI/System/TwoWayAudio/channels/{id}/audioData` with `Content-Type:
   application/octet-stream`, then `PUT …/close`. Half-duplex.
2. `[A]` Capture via `AVAudioEngine.inputNode` → `AVAudioConverter` to the device's declared format
   (typically **G.711 µ-law, 8 kHz, mono**), encoded in pure Swift, sent in 320-byte (40 ms) chunks
   at a steady cadence. Encoder is unit-tested round-trip against the decoder.
3. `[A]` Microphone permission (`NSMicrophoneUsageDescription`) is requested lazily on first use;
   denial produces "Vigil needs microphone access to talk to your cameras" with a button that opens
   System Settings ➝ Privacy & Security ➝ Microphone.
4. `[M]` Push-to-talk is hold-to-talk on the `T` key and on the tile's talk button, with an optional
   latching mode. While talking: a red "Talking" pill, a live input level meter, and the camera's own
   audio is ducked to 20 % to prevent feedback.
5. `[A]` Releasing always closes the session, even on error, cancellation, window close, sleep, or
   app quit (verified by a test that cancels mid-transmission and asserts `close` was sent).
6. `[A]` A camera without `hasTwoWayAudio` shows no talk affordance at all.
7. `[A]` Total talk latency (key press → audible at the camera) ≤ 400 ms measured on C2.
**Risk:** *High* — the two-way-audio ISAPI surface varies a lot; some devices need a specific sample
rate or reject chunked encoding. *Mitigation:* the codec/rate come from the device's own capability
response rather than being assumed; a spike against C1/C2/C3 in G2; a documented fallback of
one-shot fixed-length PUTs of 1 s buffers if chunked transfer is rejected. If a device cannot be made
to work, the affordance is hidden — never broken.

---

## 10. P0 — PTZ and image control

### F-PTZ-01 · Continuous PTZ `P0`
**Modules:** VigilISAPI · VigilUI · VigilCore
**What:** Pan, tilt and zoom with speed control, from a pad, from arrow keys, and by dragging.
**Acceptance:**
1. `[H]` `PUT /ISAPI/PTZCtrl/channels/{ch}/continuous` with
   `<PTZData><pan>N</pan><tilt>N</tilt><zoom>N</zoom></PTZData>`, values −100…100. Stop is the same
   request with all three at 0, and stop is **always** sent on key-up, button-up, window
   deactivation, view disappearance and app termination.
2. `[A]` A watchdog guarantees stop: if no new continuous command is sent within 700 ms the client
   sends stop automatically. A camera can never be left panning because a key-up event was missed.
   This is tested by injecting a dropped key-up.
3. `[A]` Commands are coalesced to at most 10 per second per channel; identical consecutive vectors
   are not resent.
4. `[M]` Speed: a 1–8 slider mapped to the −100…100 magnitude non-linearly (`round(12.5 × s)`),
   plus modifier shortcuts — `⇧` = ×2 speed (fast), `⌥` = ÷4 speed (fine). Arrow keys drive PTZ when
   the stage has focus; diagonals work by combining two arrows.
5. `[M]` Optimistic UI: the pad shows the pressed direction immediately (< 16 ms), before the HTTP
   round trip; a failed command reverts the indicator and shows a transient error.
6. `[A]` Response time press → camera motion ≤ 180 ms on C3.
**Risk:** *Medium* — a stuck-panning camera is the worst possible bug. *Mitigation:* the 700 ms
watchdog plus stop-on-every-lifecycle-event, both as acceptance criteria.

### F-PTZ-02 · Presets `P0`
**Modules:** VigilISAPI · VigilCore · VigilUI
**What:** Go to, set, rename and clear PTZ presets, with visual thumbnails.
**Acceptance:**
1. `[H]` `GET /ISAPI/PTZCtrl/channels/{ch}/presets` lists presets; `PUT …/presets/{id}/goto` recalls;
   `PUT …/presets/{id}` with `<PTZPreset><id>N</id><presetName>…</presetName></PTZPreset>` sets;
   `DELETE …/presets/{id}` clears. Preset 1–255 supported; the reserved Hikvision specials (33 auto-
   scan, 34 back to home, 35 patrol 1, 36 patrol 2, 37 patrol 3, 39 IR-cut day, 40 IR-cut night,
   99 start pan) are labelled as such and not overwritable by accident.
2. `[M]` The presets grid shows a thumbnail per preset, captured automatically 1.5 s after a
   successful `goto` (the camera has settled) and stored at
   `~/Library/Application Support/Vigil/Thumbnails/<cameraID>/preset-<n>.jpg` at 320×180, JPEG q0.7.
3. `[A]` "Go to home" uses preset 34 if the device declares it, else preset 1.
4. `[A]` Presets 1–9 are recallable with `⌃1`…`⌃9` when a PTZ camera has focus, and from the command
   palette by name ("Front gate → Driveway").
5. `[A]` Setting a preset asks for confirmation when overwriting a named preset.
**Risk:** *Low.*

### F-PTZ-03 · Patrols / tours `P0`
**Modules:** VigilISAPI · VigilUI
**What:** Start, stop and inspect the camera's stored patrol sequences.
**Acceptance:**
1. `[H]` `GET /ISAPI/PTZCtrl/channels/{ch}/patrols` lists patrols with their preset sequence, dwell
   and speed; `PUT …/patrols/{id}/start` and `…/stop` control them.
2. `[M]` The PTZ tab lists patrols with their preset chain rendered as `Gate → Yard → Door (5 s each)`
   and a play/stop button; the active patrol is highlighted and shows which step is running when the
   device reports it.
3. `[A]` Manual PTZ input while a patrol runs stops the patrol first (cameras otherwise fight the
   user), and the UI says so once: "Patrol stopped because you moved the camera."
4. `[A]` Editing patrol contents (adding/removing steps) is `F-PTZ-06` (P1); P0 is start/stop/inspect.
**Risk:** *Medium* — patrol XML shape varies by device family. *Mitigation:* lenient parsing; if the
list cannot be parsed we still expose "Patrol 1/2/3" start/stop via presets 35/36/37.

### F-PTZ-04 · 3D positioning (drag-to-zoom) `P0`
**Modules:** VigilISAPI · VigilRender · VigilUI
**What:** Drag a rectangle on the video and the camera centres and zooms to it; click to centre.
**Acceptance:**
1. `[H]` `PUT /ISAPI/PTZCtrl/channels/{ch}/position3D` with
   `<Position3D><StartPoint><positionX>x</positionX><positionY>y</positionY></StartPoint>
   <EndPoint><positionX>x</positionX><positionY>y</positionY></EndPoint></Position3D>`, coordinates
   normalized to **0…255 in each axis with the origin at the bottom-left**. The conversion from the
   tile's top-left AppKit coordinates — including the effects of Fit letterboxing and any active
   digital zoom — is a single pure, unit-tested function.
2. `[M]` Drag draws a live selection rectangle with a 2 px accent border and a 12 % accent fill; a
   drag smaller than 8 pt is treated as a click-to-centre (a zero-area `Position3D`).
3. `[A]` Dragging up-left vs down-right is normalized so direction never matters; a rectangle partly
   outside the frame is clamped.
4. `[A]` The feature is only offered when `has3DPositioning` is true.
5. `[M]` On C3 a drag around a target visibly centres and zooms to approximately that region
   (within 10 % of frame width) within 1.5 s.
**Risk:** *Medium* — coordinate-space and origin errors are easy and produce a camera that swings the
wrong way. *Mitigation:* the pure conversion function with a test table of 12 known
(tile rect, fit mode, zoom, drag) → expected `Position3D` cases derived from real device behaviour.

### F-PTZ-05 · Focus, iris and auxiliary control `P0`
**Modules:** VigilISAPI · VigilUI
**What:** Manual focus, iris, and one-touch focus for cameras that support them.
**Acceptance:**
1. `[H]` `PUT /ISAPI/PTZCtrl/channels/{ch}/continuous` with `<focus>` and `<iris>` members for
   continuous near/far and open/close; `PUT …/focus` one-push autofocus where declared. Same 700 ms
   stop watchdog as `F-PTZ-01`.
2. `[A]` Controls appear only when `hasFocus` / `hasIris` is true.
3. `[M]` Auxiliary toggles present when declared: IR light (auto/on/off), wiper, defog, and lens
   initialization — each a single labelled control with immediate optimistic feedback.
**Risk:** *Low.*

### F-IMG-01 · Device-side image settings `P0`
**Modules:** VigilISAPI · VigilUI
**What:** Adjust the camera's own image processing, persisted on the camera.
**Acceptance:**
1. `[H]` Read and write: brightness, contrast, saturation, sharpness (0–100) via
   `GET/PUT /ISAPI/Image/channels/{ch}/color`; sharpness via `…/sharpness` where separate; WDR via
   `…/WDR` (mode off/on/auto + level); day/night via `…/ircutFilter` (auto/day/night/schedule with
   the switch time and sensitivity); IR light via `…/supplementLight`; noise reduction via
   `…/noiseReduce`; mirror/rotate via `…/imageFlip` and `…/ImageRotation`; exposure via
   `…/exposure`; white balance via `…/whiteBalance`.
2. `[A]` Each control is only shown when the corresponding `/ISAPI/Image/channels/{ch}/capabilities`
   node exists, with the min/max/step taken from the capability response, not hardcoded.
3. `[M]` Sliders are optimistic and debounced at 250 ms; a `PUT` failure reverts the slider with a
   shake animation and an inline reason. A "Reset to camera defaults" action re-reads and re-applies
   the capability defaults.
4. `[A]` Changes are never applied to the wrong channel: the channel is taken from the camera record
   and asserted against the response's echoed channel id.
5. `[M]` A before/after peek (hold `\`) shows the pre-edit values so the user can judge the change.
**Risk:** `Medium` — image endpoints differ per model and a bad `PUT` can return 400 with an opaque
body. *Mitigation:* read-modify-write of the full XML document rather than sending partial documents
(the single most common cause of ISAPI 400s), preserving unknown elements verbatim.

### F-IMG-02 · Client-side image adjustment `P0`
**Modules:** VigilRender · VigilCore
**What:** Local brightness/contrast/saturation/gamma that changes what this Mac displays without
touching the camera — essential for reviewing a dark stream without altering the recording.
**Acceptance:**
1. `[A]` Applied in the Metal fragment shader (`F-REN-02`) at zero measurable CPU cost and ≤ 0.1 %
   extra GPU per stream.
2. `[A]` Per-camera, persisted, with a neutral-reset action and a clear "Display only" label.
3. `[A]` Snapshots and recordings are **unaffected** by client-side adjustment unless the user picks
   "Snapshot as displayed" (`F-CAP-01`). A test asserts a recorded file is bit-identical whether the
   adjustment is on or off.
**Risk:** *Low.*

---

## 11. P0 — Snapshots

### F-CAP-01 · Single-camera snapshot `P0`
**Modules:** VigilCore · VigilRender · VigilISAPI · UniformTypeIdentifiers
**What:** Capture a still from one camera, in a chosen format, to a chosen destination.
**Acceptance:**
1. `[A]` Two sources, user-selectable per invocation and defaultable in Settings:
   **"As displayed"** — the exact rendered frame including overlays, zoom and client-side colour,
   read back from the Metal texture or `CVPixelBuffer`; and **"Full resolution"** — the current
   decoded frame at native resolution without overlays, or an ISAPI JPEG from
   `GET /ISAPI/Streaming/channels/{id}/picture` when the tile is on a sub stream but the main stream
   is higher resolution.
2. `[A]` Formats: **PNG** (lossless), **JPEG** (quality slider 0.5–1.0, default 0.9), **HEIC**
   (quality slider, default 0.8), written with `CGImageDestination` and the UTType from
   UniformTypeIdentifiers. HEIC is offered only when `CGImageDestinationCopyTypeIdentifiers()`
   includes `public.heic`.
3. `[A]` EXIF/TIFF metadata stamped: `DateTimeOriginal` (frame capture time, not write time, in the
   camera's timezone), `Make = Hikvision` (or the reported vendor), `Model`, `Software = Vigil
   <version>`, `ImageDescription = <camera name>`, `PixelXDimension/PixelYDimension`, and a
   `UserComment` carrying the camera UUID and stream (main/sub). Verified by reading the file back.
4. `[A]` Optional burn-in overlay (camera name + timestamp, bottom-left, 4 % of image height, white
   on a 45 % black scrim) rendered into the pixels for evidentiary use.
5. `[A]` Destinations: a configured folder (default `~/Pictures/Vigil/`), **clipboard**
   (`NSPasteboard` with both `.tiff` and the chosen file type so it pastes everywhere), Quick Look
   preview, and "Reveal in Finder". Multiple destinations may be selected simultaneously.
6. `[A]` Filename template with tokens `{camera} {date} {time} {seq} {resolution} {group}`; default
   `{camera}-{date}-{time}.{ext}` → `Front Door-2026-07-26-14-31-07.jpg`. Illegal path characters
   (`/`, `:`, NUL) are sanitized; collisions get ` (2)`.
7. `[A]` `⇧⌘S` snapshots the focused camera; end-to-end keypress → file on disk ≤ 150 ms; the UI
   shows a shutter flash (Reduce Motion: a brief label instead) and a toast with "Show in Finder"
   and "Copy" actions.
8. `[A]` A snapshot of an offline camera produces "No video to capture" rather than a 0-byte file.
**Risk:** *Low.*

### F-CAP-02 · Snapshot all cameras `P0`
**Modules:** VigilCore · VigilUI
**What:** One action capturing every camera (or every camera in a group / on the stage) at the same
moment.
**Acceptance:**
1. `[A]` `⌥⇧⌘S` captures all **enabled** cameras. Cameras that are paused or JPEG-polled are captured
   via ISAPI JPEG so the set is complete, not just the visible tiles.
2. `[A]` All captures are triggered from one timestamp; the maximum spread between the earliest and
   latest frame time across 16 cameras is ≤ 250 ms and is recorded in a `manifest.json` alongside
   the files.
3. `[A]` Output goes to a timestamped subfolder `Snapshot Set 2026-07-26 14-31-07/` containing one
   file per camera plus `manifest.json` (camera name, UUID, frame time, resolution, codec, source).
4. `[A]" Failures are partial-tolerant: a set with 14 successes and 2 failures writes 14 files and a
   manifest listing the 2 failures with reasons; the toast reads "14 of 16 cameras captured".
5. `[A]` Progress is shown for sets larger than 4 cameras and the operation is cancellable.
**Risk:** *Low.*

---

## 12. P0 — Recording

### F-REC-01 · Manual recording to MP4 with passthrough muxing `P0`
**Modules:** VigilCore (ClipRecorder) · VigilVideo · AVFoundation
**What:** Record the live compressed stream to a file with **no re-encode**, so CPU cost is
negligible and quality is bit-exact.
**Acceptance:**
1. `[A]` `AVAssetWriter` with `AVAssetWriterInput(mediaType: .video, outputSettings: nil,
   sourceFormatHint: formatDescription)` — `outputSettings: nil` is what selects passthrough. Audio
   likewise with the AAC or G.711 format description. Container **MP4** (default) or **MOV**
   (selectable; MOV required if the camera's audio is G.711, which MP4 cannot legally carry — in that
   case we either switch to MOV automatically with a note, or drop audio, per the user's setting).
2. `[A]` CPU cost of recording one 1080p stream ≤ 1.0 % (it is a file write, not an encode), and
   recording adds ≤ 4 MB RSS per active recording.
3. `[A]` The file's first video sample is a **keyframe**. Samples before the first IDR are discarded;
   if no keyframe arrives within 5 s, an I-frame is requested (`F-DEC-05`) and the user sees
   "Waiting for a keyframe…".
4. `[A]` Timestamps are rebased so the file starts at `CMTime.zero`, monotonically increasing, with
   gaps preserved as real durations (not collapsed) so a 10-minute recording with a 4 s dropout is
   10 minutes long. Verified with `AVAsset` duration and `AVAssetReader` sample-time assertions.
5. `[A]` `movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)` so a killed process
   leaves a playable file. Writing goes to `<name>.mp4.partial` and is renamed on successful
   `finishWriting`; a `.partial` file found at launch is repaired-by-rename and listed as "Recovered".
6. `[A]` Disk space is checked before starting (refuse below 2 GB free) and monitored during
   (stop cleanly with a notification at 500 MB free); the estimated remaining time at the current
   bitrate is shown.
7. `[A]` Graceful finish on quit: `applicationShouldTerminate` returns `.terminateLater`, all
   recorders finish (budget 3 s each), then termination proceeds. A test asserts a file recorded up
   to a simulated quit is playable and has correct duration.
8. `[M]` `⌘R` toggles recording on the focused camera; the tile shows a pulsing red dot and elapsed
   time; the menu bar extra shows a global recording count.
9. `[A]` Naming template with the same tokens as `F-CAP-01` plus `{duration}`; default folder
   `~/Movies/Vigil/`, held as a security-scoped bookmark so sandboxed access survives relaunch.
10. `[A]` Files play in QuickTime Player, Finder Quick Look and VLC. Verified for H.264 and H.265 in
    both MP4 and MOV.
**Risk:** *Medium* — passthrough MP4 muxing of HEVC with `sourceFormatHint` has sharp edges, and
`AVAssetWriter` errors are often generic `-11800`. *Mitigation:* the writer's `error` is always
surfaced with its underlying `NSUnderlyingError` and `OSStatus`; a fixture test records 30 s from the
synthetic RTP generator for each codec/container combination and validates with `AVAssetReader`.

### F-REC-02 · Pre-roll buffer `P0`
**Modules:** VigilCore · VigilRTP
**What:** Recording includes the seconds *before* the user pressed record — the whole point of a
security app, since interesting things are noticed after they start.
**Acceptance:**
1. `[A]` A ring buffer per camera holds the last **N seconds** of compressed access units, N
   configurable 0–30 s, default **10 s**, aligned to GOP boundaries so the flushed buffer always
   begins with a keyframe.
2. `[A]` Memory is bounded by bytes as well as time: `min(N seconds, 24 MB)` per camera; the ceiling
   is reported if it truncates the pre-roll ("Pre-roll: 6 s of 10 s — the stream's bitrate is high").
3. `[A]` The buffer is only maintained for cameras where pre-roll could be used: recording-eligible
   and either visible or motion-armed. A test asserts total pre-roll memory across 16 cameras
   ≤ 200 MB at 10 s and 4 Mbps.
4. `[A]` On record start the buffer is flushed into the writer before live samples, timestamps
   rebased continuously; the resulting file has no discontinuity at the join (asserted by decoding
   the file and checking PTS continuity and no decode error).
5. `[A]` Pre-roll works identically for motion-triggered recording (`F-REC-03`), which is where it
   matters most.
**Risk:** *Medium* — memory growth is the failure mode. *Mitigation:* the hard byte cap and the
16-camera memory test are acceptance criteria.

### F-REC-03 · Motion-triggered local recording `P0`
**Modules:** VigilCore (EventCenter, ClipRecorder) · VigilISAPI
**What:** Automatically record to this Mac when the camera reports motion or another VCA event.
**Acceptance:**
1. `[A]` Trigger source is the **device-side** event stream (`F-EVT-01`) — the camera's own detector,
   which is tuned, free, and does not require decoding. Client-side pixel analysis is explicitly
   *not* used (see §16).
2. `[A]` Per-camera arming with a selectable trigger set (motion, line crossing, intrusion, tamper,
   video loss) plus an optional schedule (weekday/time ranges, 15-minute granularity).
3. `[A]` Clip shape: `preRoll` (default 10 s, from `F-REC-02`) + event duration + `postRoll`
   (default 15 s, configurable 0–120 s). A new trigger during post-roll **extends** the current clip
   rather than starting a second one.
4. `[A]` Cooldown: after a clip ends, the same (camera, eventType) cannot start a new clip for
   `cooldown` seconds (default 20 s, configurable 0–300 s), so a 3-hour windy afternoon does not
   produce 4000 files.
5. `[A]` Retention: an optional cap by age (default 14 days) and/or total size (default 50 GB) with
   oldest-first deletion, running at most once per hour, never deleting a file that is currently
   being written or was manually recorded (manual clips are exempt unless the user opts in).
6. `[A]` Every auto-clip produces a `RecordingClip` record (camera, start, end, trigger, event id,
   file URL, byte size, resolution, codec) visible in the Recordings sidebar section, and a thumbnail
   from 1 s after the trigger.
7. `[A]` Auto-recording works while the camera's tile is not visible: the coordinator keeps a
   recording-priority stream alive (`F-DEC-06` rule 5). Verified with a test that closes all tiles
   and asserts a motion event still yields a clip.
8. `[M]` A visible global state: the menu-bar extra badge and the sidebar show "3 cameras armed",
   and each armed camera has a distinct icon. Silent background recording with no indicator is not
   acceptable.
**Risk:** *Medium* — the interaction of arming, budget, retention and cooldown is the most stateful
part of the app. *Mitigation:* the whole policy is a pure function of (events, clock, config) →
actions, unit-tested with a scripted 24-hour event timeline; the file system side is a thin executor.

---

## 13. P0 — Playback and timeline

### F-PLB-01 · Recorded-video search `P0`
**Modules:** VigilISAPI · VigilCore · VigilUI
**What:** Find what a camera or NVR has recorded, by time and by type.
**Acceptance:**
1. `[H]` `POST /ISAPI/ContentMgmt/search` with a `CMSearchDescription` carrying a fresh `searchID`
   GUID, `trackIDList` (track = `channel × 100 + 1` for the main-stream track), a `timeSpanList`
   with ISO-8601 `startTime`/`endTime` in the **device's** timezone, `maxResults` = 40 and
   `searchResultPosition` for paging.
2. `[A]` `CMSearchResult` parsing yields `matchList` entries with `trackID`, `startTime`, `endTime`,
   `playbackURI`, `contentType`, `codecType` and metadata; `responseStatusStrg == "MORE"` drives
   paging until `NO MATCHES` or the requested window is covered. Pure and Linux-tested against 8
   captured responses including an empty result and a 2000-segment result.
3. `[A]` Timezone correctness: the device's UTC offset is read from `GET /ISAPI/System/time` and all
   conversions go through one pure `DeviceClock` type; a test covers a device set to UTC+3 while the
   Mac is UTC−7, across a DST boundary.
4. `[A]` Filter by record type where the device reports it (continuous / motion / alarm / manual) and
   by channel; search across multiple cameras at once for the sync view (`F-PLB-05`).
5. `[A]` A device without ISAPI search (or an ONVIF-only device) reports "This camera can't be
   searched from Vigil — it has no on-device recordings index" and offers local clips instead.
**Risk:** *Medium* — search semantics and time handling vary; NVRs return huge lists. *Mitigation:*
paging, a 5000-segment client cap with a "narrow your search" prompt, and the single `DeviceClock`
conversion point.

### F-PLB-02 · Playback transport and speed control `P0`
**Modules:** VigilRTSP · VigilVideo · VigilUI
**What:** Play back recorded video from the device with real transport controls.
**Acceptance:**
1. `[H]` Playback URL `rtsp://<host>:554/Streaming/tracks/{channel}01?starttime=20260726T103000Z&
   endtime=20260726T104500Z`; seek by re-`PLAY` with `Range: clock=20260726T103515Z-`; speed with the
   RTSP `Scale:` header at 0.25, 0.5, 1, 2, 4, 8 and reverse −1, −2, −4, −8; pause with `PAUSE`.
2. `[A]` Frame stepping forward uses `Scale: 0` plus a single-frame `PLAY`; where unsupported, we
   step by decoding forward from the nearest keyframe and holding — the UI behaviour is identical
   either way. Backward stepping seeks to `t − 1/fps` and decodes forward from the preceding keyframe.
3. `[A]` `−10 s` / `+10 s` (and `−1 min` / `+1 min`) jump correctly across segment boundaries,
   automatically issuing a new `PLAY` for the next segment with no user-visible gap beyond 400 ms.
4. `[A]` At speeds > 2× the decoder drops non-reference frames rather than falling behind; playback
   at 8× sustains ≥ 20 displayed fps on a 1080p25 recording at ≤ 15 % CPU.
5. `[A]` Reverse playback is keyframe-anchored: decode a GOP into a bounded cache (≤ 48 frames,
   ≤ 96 MB) and present in reverse. Where the device supports negative `Scale` we use it instead.
6. `[M]` Transport controls: play/pause (`Space`), ±10 s (`←`/`→`), frame step (`,`/`.`), speed
   (`J`/`K`/`L` and a segmented control), jump to time, and a live "playing at 4×" indicator.
7. `[A]` End of the recorded range stops cleanly with "End of recording" rather than hanging.
**Risk:** *High* — device playback RTSP is the least standard part of the whole surface: `Scale`
support, reverse, and frame step all vary. *Mitigation:* a capability probe per device (try `Scale: 2`
once at session start and observe), a client-side implementation of every trick mode so the UI
contract holds regardless, and an explicit fallback matrix in the release checklist. Reduced
acceptance if a device supports nothing: 1× forward play + seek + client-side speed by frame
selection, which is always achievable.

### F-PLB-03 · Timeline with density heatmap `P0`
**Modules:** VigilUI · VigilCore
**What:** A 24-hour horizontal timeline per camera showing where recordings exist and why, zoomable
from a full day to a single minute.
**Acceptance:**
1. `[M]` Segments are drawn as coloured bands: **continuous = blue**, **motion = amber**,
   **alarm = red**, **manual/local = purple**, gaps = the sunken surface colour. A legend is present.
2. `[A]` Zoom levels 24 h / 6 h / 1 h / 15 min / 1 min via pinch, `⌘+`/`⌘−`, or scroll with `⌥`;
   zoom is anchored at the pointer; the visible range and the playhead are always consistent.
3. `[A]` Rendering is O(visible segments), not O(all segments): a day with 4000 segments draws in
   ≤ 4 ms by bucketing to pixel columns. Asserted by a performance test.
4. `[M]` Drag to scrub with a live preview: a floating thumbnail follows the pointer, fetched from
   the device (ISAPI JPEG at that timestamp where supported) or by a fast keyframe-only decode,
   debounced at 120 ms, arriving in ≤ 120 ms p50.
5. `[A]` Event markers from `F-EVT-01` are pinned on the timeline as small ticks; clicking one seeks
   to it minus 3 s.
6. `[A]` A date picker plus "Yesterday / Today / Last hour" quick ranges; keyboard `←`/`→` moves one
   day at the day level.
7. `[M]` The timeline reads correctly at 1× and 2× backing scale and in both appearances; contrast of
   every band against the track ≥ 3:1.
**Risk:** *Medium* — a custom high-density interactive canvas is a performance and accessibility
risk. *Mitigation:* it is a single `NSView` with `draw(_:)` over pixel-bucketed data, not thousands of
SwiftUI shapes; an accessible alternative (a segment list with times, `F-PLT-06`) is a P0 criterion.

### F-PLB-04 · Clip export `P0`
**Modules:** VigilCore · VigilRTSP · VigilVideo
**What:** Select in/out points and export that range as an MP4, without re-encoding.
**Acceptance:**
1. `[M]` `I` and `O` set in/out points; the selected range is highlighted on the timeline with
   draggable handles and a duration readout; `⌘E` exports.
2. `[A]` Export streams the device's playback RTSP for the selected range and passthrough-muxes it
   with `AVAssetWriter` (`F-REC-01` machinery). No transcode; exported video is bit-identical to the
   device's stored frames from the first keyframe at or before the in point.
3. `[A]` Frame-accurate trimming at the in point is achieved by starting the file at the preceding
   keyframe and setting the track's edit list / `CMTimeRange` so players start at the requested
   frame; the exported duration matches the selection within one frame interval.
4. `[A]` Export shows progress, is cancellable (cancel deletes the partial file), and runs in the
   background so the user can keep watching live cameras. Export rate ≥ 8× realtime on a wired LAN.
5. `[A]` Exporting a range spanning multiple device segments produces one continuous file with real
   gap durations preserved.
6. `[A]` A sidecar `<name>.json` records camera, device serial (masked per §11), requested and actual
   time range, codec, resolution, and Vigil version — useful when a clip is handed to someone else.
**Risk:** *Medium* — edit-list trimming is subtle. *Mitigation:* if the edit list proves unreliable
across players, fall back to starting the file at the preceding keyframe and documenting the actual
start time in the sidecar and the UI, which still satisfies criteria 2, 4 and 5.

### F-PLB-05 · Synchronized multi-camera playback `P0`
**Modules:** VigilCore · VigilRTSP · VigilUI
**What:** Scrub one timeline and watch up to 4 cameras move together — how incidents are actually
reviewed.
**Acceptance:**
1. `[A]` A single virtual playhead in **absolute UTC** drives up to 4 playback sessions; each session
   seeks to the playhead's UTC through its own `DeviceClock`.
2. `[A]` Steady-state skew between any two cameras ≤ 250 ms; a camera drifting beyond 500 ms is
   re-seeked automatically. Measured with a synchronized-clock scene recorded on C2 and C4.
3. `[A]` Play/pause/speed/seek apply to all sessions atomically; a camera with no recording at the
   playhead shows "No recording at this time" and rejoins automatically when coverage resumes.
4. `[A]` Cameras whose recordings have different frame rates stay aligned (the playhead is time-based,
   never frame-count-based).
5. `[A]` 4 synchronized 1080p playback streams at 1× fit within 60 % of the 16-stream live CPU budget.
6. `[M]` A shared timeline shows all four cameras' coverage as stacked lanes with one playhead.
**Risk:** *High* — synchronizing independent device-side playback sessions with independent clocks is
the hardest feature in the app. *Mitigation:* time-based (not frame-based) design; a 4-camera cap;
per-camera drift correction; and a documented reduced acceptance of ≤ 500 ms skew with 2 cameras if
4-camera sync cannot hold, which still delivers the core review workflow.

### F-PLB-06 · Local clip library `P0`
**Modules:** VigilCore · VigilUI · AVFoundation
**What:** Browse, play, reveal, rename, tag and delete the clips Vigil recorded to this Mac.
**Acceptance:**
1. `[A]` The Recordings sidebar section lists clips grouped by day and camera with thumbnail,
   duration, size, trigger and codec; sortable and filterable; searchable by camera name and tag.
2. `[A]` Playback of local clips uses `AVPlayer` (they are ordinary MP4/MOV files) with the same
   transport shortcuts as `F-PLB-02`.
3. `[A]` Deleting moves to the Trash (`NSFileManager.trashItem`), never unlinks; multi-select delete
   is confirmed with a count.
4. `[A]` A clip whose file was moved or deleted externally is shown as "Missing" with a "Locate…"
   action, and the index self-heals on next scan rather than accumulating ghosts.
5. `[A]` Bookmarks: a named, timestamped marker on a clip or on a device recording, with a note;
   bookmarks persist, appear in the sidebar and on the timeline, and are exportable.
**Risk:** *Low.*

---

## 14. P0 — Events, health and resilience

### F-EVT-01 · Device event / alarm stream `P0`
**Modules:** VigilISAPI · VigilCore (EventCenter)
**What:** Consume the camera's real-time alarm stream so the app knows about motion and faults the
instant the device does.
**Acceptance:**
1. `[H]` `GET /ISAPI/Event/notification/alertStream` is held open per **device** (not per channel —
   one connection serves all NVR channels) and parsed as `multipart/mixed`; each part is an
   `EventNotificationAlert` XML document.
2. `[A]` Parsed fields: `ipAddress`, `portNo`, `channelID` **or** `dynChannelID`, `dateTime`,
   `activePostCount`, `eventType`, `eventState` (`active`/`inactive`), `eventDescription`, and
   `DetectionRegionList` region coordinates when present. Pure, Linux-tested against 20 captured
   multipart bodies including one with `\n` instead of `\r\n` line endings and one with a trailing
   boundary and no final newline.
3. `[A]` Recognized event types mapped to a typed enum with localized names: `VMD` (motion),
   `linedetection`, `fielddetection` (intrusion), `regionEntrance`, `regionExiting`,
   `shelteralarm`/`tamperdetection`, `videoloss`, `diskfull`, `diskerror`, `ipconflict`,
   `illegalaccess`, `badvideo`, `facedetection`, `scenechangedetection`, `storageDetection`,
   `PIR`, `unattendedBaggage`, `attendedBaggage`. Unknown types are surfaced verbatim rather than
   dropped.
4. `[A]` **Heartbeat filtering:** Hikvision emits periodic `videoloss` parts with
   `eventState = inactive` roughly every 5 s as a keepalive. These are used to prove liveness and are
   **never** shown as events. A test asserts a 10-minute heartbeat-only stream produces zero events
   and keeps the connection marked healthy.
5. `[A]` Dedupe/coalesce: identical `(eventType, channel)` within **3 s** collapses into one event
   with an incrementing `count`; `activePostCount` is used to detect a continuing event rather than a
   new one.
6. `[A]` The connection auto-reconnects with the same backoff policy as streams; 12 hours of
   continuous operation shows no memory growth above 3 MB and no missed events across a forced
   mid-stream disconnect.
7. `[A]` Devices without an alert stream (or ONVIF-only) fall back to ISAPI polling of
   `/ISAPI/Event/triggers/…/status` at 2 s, clearly marked as polled with a note about added latency.
**Risk:** *Medium* — multipart parsing of a never-ending response with vendor-specific framing.
*Mitigation:* an incremental, allocation-bounded parser with fixture tests and a fuzz corpus; a
polling fallback so events are never entirely unavailable.

### F-EVT-02 · Event feed `P0`
**Modules:** VigilUI · VigilCore
**What:** A unified, filterable, clickable feed of everything that happened.
**Acceptance:**
1. `[A]` The last **5000** events persist across launches, ring-buffered; each row shows a thumbnail,
   camera name, event type, time (relative under 1 h, absolute above), and duration for events with
   an end.
2. `[A]` Thumbnails are captured within 500 ms of the event from the live stream (or ISAPI JPEG if
   the stream is paused) at 320×180 and stored under
   `~/Library/Application Support/Vigil/Thumbnails/events/`, capped at 500 MB with oldest-first
   eviction.
3. `[A]` Filters: camera, group, event type, time range, "has clip"; a persistent unread count; mark
   all read.
4. `[A]` Clicking a row: jumps to the event's moment in Playback (`F-PLB-03`) if the device has a
   recording there, else opens the local auto-clip, else shows the live camera with the event
   thumbnail alongside. Never a dead click.
5. `[A]` Motion boxes from `DetectionRegionList` are drawn on the event thumbnail and, optionally,
   live on the tile for 3 s after the event.
**Risk:** *Low.*

### F-EVT-03 · Local notifications and watch mode `P0`
**Modules:** VigilCore · UserNotifications · VigilUI
**What:** Tell the user about events when they aren't looking at the app — and get out of the way
when they are.
**Acceptance:**
1. `[A]` `UNUserNotificationCenter` local notifications with the camera name as title, the event type
   as body, the event thumbnail as a `UNNotificationAttachment`, and actions "View live" and
   "Play back". Notification authorization is requested only when the user enables notifications, not
   at launch.
2. `[A]` Per-camera and per-event-type opt-in, plus a global schedule (e.g. only 22:00–07:00), plus a
   per-camera rate limit (default at most 1 notification per 60 s) and a global limit (at most 10 per
   minute) so a windy night cannot produce 400 banners.
3. `[A]` Notifications are suppressed for a camera that is currently visible on the stage and the app
   is frontmost — the user can already see it. This suppression is a setting, default on.
4. `[M]` **Watch mode:** an in-app alternative that raises a corner toast with a 4-second live
   preview of the triggering camera, or (optionally) briefly promotes that camera to the largest cell
   of the layout and returns after 10 s. Both respect Reduce Motion.
5. `[A]` Clicking a notification activates the app and performs the action; the app being closed at
   the time is handled (launch, restore, then act).
**Risk:** *Low.*

### F-HLT-01 · Per-stream health metrics `P0`
**Modules:** VigilRTP (pure math) · VigilCore (HealthMonitor) · VigilUI
**What:** Continuously measure what each stream is actually doing, and show it.
**Acceptance:**
1. `[A]` Metrics sampled at **1 Hz**: displayed fps, decoded fps, received bitrate (kbps), packet
   loss % (from RTP sequence gaps), RFC 3550 interarrival jitter (ms), reorder count, jitter-buffer
   depth (ms), decode queue depth, dropped frames (by reason: loss, budget, decode error, late),
   estimated end-to-end latency (ms), keyframe interval (s), session uptime, reconnect count,
   bytes received, and hardware/software decode state.
2. `[A]` Latency estimate = `(now − frameCaptureWallClock) ` where `frameCaptureWallClock` maps the
   RTP timestamp through the RTCP Sender Report NTP/RTP pair; when no SR has been received, the
   estimate is `jitterBufferDepth + decodeQueueDelay + presentationDelay` and is labelled
   "estimated (no RTCP)". The reported value tracks the physical rig measurement (§10) within ±25 ms.
3. `[A]` All metric math is pure and Linux-tested, including loss calculation across sequence
   wraparound and jitter against the RFC's worked example.
4. `[M]` The inspector's Stream tab shows live sparklines for fps, bitrate, loss and latency; the
   tile pill shows a compact `H.265 · 1920×1080 · 25 fps · 3.1 Mbps · HW`.
5. `[A]` Metric collection costs ≤ 0.05 % CPU per stream and allocates nothing per sample (fixed-size
   ring, in-place update).
**Risk:** *Low.*

### F-HLT-02 · Health history and graphs `P0`
**Modules:** VigilCore · VigilUI
**What:** Not just now — the last ten minutes, so a stutter that already happened can be diagnosed.
**Acceptance:**
1. `[A]` A fixed-size ring of **600 samples** (10 min at 1 Hz) per camera, allocated once, 0
   allocations per sample; memory ≤ 40 KB per camera (≤ 640 KB at 16 cameras).
2. `[A]` A longer-term rollup: 1-minute averages for 24 h (1440 samples) persisted to
   `~/Library/Application Support/Vigil/health/<cameraID>.bin` so an overnight problem is visible in
   the morning; ≤ 200 KB per camera per day with 7-day rotation.
3. `[M]` Graphs render fps, bitrate, loss and latency over 10 min / 1 h / 24 h with the y-axis fixed
   per metric (not auto-scaled to noise), event and reconnect markers overlaid, and a hover readout.
4. `[A]` A "Copy health summary" action puts a plain-text report on the clipboard for support
   threads, redacted per §11.
**Risk:** *Low.*

### F-HLT-03 · Stream-loss detection and alerting `P0`
**Modules:** VigilCore · VigilUI · UserNotifications
**What:** A camera going dark is the most important event a security app can report.
**Acceptance:**
1. `[A]` Loss is declared when **no decodable frame arrives for `max(3 × keyframeInterval, 6 s)`**,
   capped at 20 s — a rule that does not false-positive on a 10 s-GOP camera and does not take a
   minute to notice a dead one.
2. `[A]` Distinguished states with distinct UI and distinct alert text: `degraded` (frames arriving
   but loss > 2 % or fps < 60 % of expected), `stalled` (no frames, session alive), `offline`
   (transport failed), `authFailed`, `unreachable`.
3. `[A]` Alerting is per-camera opt-in with a **grace period** (default 30 s, 0–600 s) so a 5-second
   blip does not page anyone; a recovery notification is sent when it returns, including the outage
   duration ("Front Door was offline for 4 minutes").
4. `[A]` An "All cameras offline" condition (e.g. the switch died) coalesces into **one**
   notification, not sixteen.
5. `[A]` Outages are logged as `EventRecord`s of type `videoLoss` with start and end, so the event
   feed shows uptime history, and a per-camera uptime percentage over 24 h / 7 d is shown in the
   inspector.
**Risk:** *Low.*

### F-HLT-04 · Auto-reconnect with backoff `P0`
**Modules:** VigilCore (StreamController) · VigilTransport
**What:** Recover from every transient failure automatically, without hammering the device.
**Acceptance:**
1. `[A]` Backoff schedule **0.5, 1, 2, 4, 8, 15, 30 s then 30 s capped**, each with **±20 % jitter**;
   the attempt counter resets after **60 s** of healthy streaming. Exactly this schedule; it is
   shared with the event stream and the ISAPI clients.
2. `[A]` `authFailed` and `notActivated` are **terminal** — no automatic retries (see `F-CRD-03`).
   `unsupportedCodec` is terminal until the configuration changes.
3. `[A]` The reconnect is a full session rebuild (fresh socket, fresh `DESCRIBE`) because a
   half-dead RTSP session is the usual cause; parameter sets are re-read in case the camera was
   reconfigured, and a resolution change is handled without a renderer glitch.
4. `[M]` The tile shows "Reconnecting… next try in 4 s" with a live countdown and a "Retry now"
   button; the last good frame stays visible at 40 % opacity so the user retains context.
5. `[A]` 16 cameras all failing simultaneously produce reconnect attempts spread by jitter such that
   no more than 4 connection attempts occur in any 250 ms window.
6. `[A]` No unbounded resource growth: 500 reconnect cycles on one camera leave FD count, task count,
   VideoToolbox session count and RSS within 2 % of baseline.
**Risk:** *Low* in design, *Medium* in leak discipline. *Mitigation:* the 500-cycle leak test is an
acceptance criterion, run in CI against the synthetic fixture with fault injection.

### F-HLT-05 · Network-change, sleep/wake and reboot resilience `P0`
**Modules:** VigilCore · VigilTransport · AppKit
**What:** Survive the real world: Wi-Fi to Ethernet, sleep, VPN, IP change, and cameras rebooting.
**Acceptance:**
1. `[A]` `NWPathMonitor` drives a coordinator reaction: on path loss all streams go to
   `reconnecting` without burning retries; on path restoration every camera retries **immediately**
   (ignoring the backoff timer) with jitter spread over 500 ms.
2. `[A]` On `NSWorkspace.willSleepNotification` all sessions are torn down cleanly and recordings are
   finalized (sockets do not survive sleep, and pretending otherwise causes multi-minute stalls). On
   `didWakeNotification` all previously-live cameras reconnect; **first frame back within 2.5 s** of
   wake on a healthy LAN.
3. `[A]` Interface change (Wi-Fi → Ethernet) is detected and sessions rebound to the new interface;
   UDP sockets and multicast groups are re-established on the correct interface.
4. `[A]` A camera whose DHCP address changed is re-found: on `unreachable`, if the camera has a known
   MAC, a SADP probe is issued and the record's host is updated automatically with a note in the
   event feed ("Front Door's address changed to 192.168.1.71").
5. `[A]` **Camera reboot loop test:** power-cycle (or ISAPI-reboot) one camera **20 times** in a
   loop; every cycle must reconnect and resume video; zero crashes; RSS growth over the 20 cycles
   ≤ 2 MB; VideoToolbox session count returns to baseline. This is an explicit release gate.
6. `[A]` A camera that comes back with a **different resolution or codec** is handled by rebuilding
   the format description and decoder without a crash and without a stuck black tile.
7. `[A]` Display sleep pauses rendering (not decoding of recording streams) and resumes without a
   glitch; `NSApplication.didChangeOcclusionState` pauses offscreen decode per `F-DEC-06`.
**Risk:** *Medium* — the number of lifecycle paths is large and each has a leak or hang failure mode.
*Mitigation:* one `LifecycleCoordinator` funnels every OS notification into a single state reducer, so
there is one place to test rather than twelve scattered observers.

### F-HLT-06 · Stream Doctor `P0`
**Modules:** VigilCore · VigilTransport · VigilRTSP · VigilISAPI · VigilUI
**What:** An in-app diagnostic that answers "why won't this camera connect?" with a specific cause
and a specific fix. This is a headline feature, not a debug tool.
**Acceptance:**
1. `[A]` The sequence runs in order, reporting each step live with a pass/fail/skip state, and stops
   at the first hard failure:

   | # | Probe | Timeout | On failure → cause |
   |---|---|---|---|
   | 1 | DNS / address resolution | 2 s | `hostNotFound` |
   | 2 | TCP connect to RTSP port (554) | 3 s | `rtspPortClosed` |
   | 3 | TCP connect to HTTP port (80/443) | 3 s | `httpPortClosed` |
   | 4 | RTSP `OPTIONS` | 3 s | `notAnRTSPServer` |
   | 5 | ISAPI `GET /ISAPI/System/deviceInfo` | 4 s | `notHikvision` / `notActivated` |
   | 6 | RTSP `DESCRIBE` without auth | 3 s | (expect 401 — informational) |
   | 7 | RTSP `DESCRIBE` with credentials | 4 s | `authFailed` / `accountLocked` |
   | 8 | SDP codec check | — | `unsupportedCodec` / `wrongRTSPPath` (404) |
   | 9 | `SETUP` + `PLAY`, first RTP packet | 4 s | `noMediaData` / `multicastBlocked` / `udpBlocked` |
   | 10 | First decodable keyframe | 8 s | `noKeyframe` |
   | 11 | 5-second quality sample | 5 s | `highLoss` / `highJitter` / `lowBitrate` |

2. `[A]` Every cause maps to user-facing copy with a concrete fix and, where possible, a one-click
   action. The mapping table is normative:

   | Cause | Message | Fix action |
   |---|---|---|
   | `hostNotFound` | "We can't find that address on your network." | Scan subnet (`F-DSC-03`) |
   | `rtspPortClosed` | "Port 554 is closed. The camera may use a different RTSP port, or RTSP is disabled in its settings." | Try 8554 / 10554; open camera web page |
   | `httpPortClosed` | "Port 80 is closed, so we can't read the camera's settings. Video may still work." | Continue anyway; try 443 |
   | `notAnRTSPServer` | "Something is answering on port 554, but it isn't an RTSP camera." | — |
   | `notHikvision` | "This doesn't look like a Hikvision device. We can try the standard ONVIF protocol instead." | Switch to ONVIF (`F-DSC-07`) |
   | `notActivated` | "This camera hasn't been activated yet." | Open camera web page (`F-DSC-04`) |
   | `authFailed` | "The username or password was rejected." | Open credential editor |
   | `accountLocked` | "The camera has locked this account after too many failed sign-ins. Wait about 30 minutes." | — (explicitly no retry) |
   | `unsupportedCodec` | "This stream uses <codec>, which this Mac can't decode in hardware." | Switch to the sub stream; open camera stream settings |
   | `wrongRTSPPath` | "The camera rejected the stream path <path>." | Try the alternate path list; set a custom path (`F-STR-09`) |
   | `udpBlocked` | "Video data isn't arriving over UDP — something on your network is blocking it." | Switch to TCP (one click) |
   | `multicastBlocked` | "Multicast video isn't reaching this Mac. Your switch is probably filtering it." | Switch to unicast TCP (one click) |
   | `noMediaData` | "The camera accepted the request but sent no video." | Request keyframe; switch transport |
   | `noKeyframe` | "Video is arriving but we haven't received a full frame yet. The camera's I-frame interval may be very long." | Request keyframe; show how to lower the GOP |
   | `highLoss` | "<n>% of video packets are being lost." | Switch to TCP; use the sub stream |
   | `highJitter` | "Network timing is unstable (jitter <n> ms)." | Raise the latency preset to Quality |
   | `lowBitrate` | "The camera is sending far less data than configured." | Open camera stream settings |

3. `[A]` The full run completes in ≤ 25 s worst case and is cancellable. Results are copyable as
   plain text (redacted) and attachable to the diagnostics bundle.
4. `[A]` **Six seeded fault modes** are correctly diagnosed by the synthetic fixture in CI: closed
   port, 401 loop, SDP with an unknown codec, `DESCRIBE` 404, `SETUP` succeeds but no RTP, and RTP
   with 40 % loss. Each must produce exactly the expected cause. This is the G2 exit criterion.
5. `[M]` Stream Doctor is offered automatically — a "Diagnose" button on any tile in an error state —
   and is reachable from the command palette and the Camera menu for any camera at any time.
**Risk:** *Medium* — the value is entirely in the accuracy of the cause mapping. *Mitigation:* the
mapping is table-driven and fixture-tested; every cause has a reproducible fixture in CI.

---

## 15. P0 — Automation, integration, data and platform

### F-AUT-01 · Command palette `P0`
**Modules:** VigilUI · VigilCore
**What:** `⌘K` — one keystroke to any camera, layout, preset or action.
**Acceptance:**
1. `[A]` Sources: cameras (jump / fullscreen / snapshot / record / mute / diagnose), groups, layouts,
   layout presets, PTZ presets (per camera), recent events, recordings, settings panes, and global
   actions (snapshot all, mute all, start cycling, open wall, export diagnostics).
2. `[A]` Ranking is deterministic and unit-tested: `score = 1000×exactPrefix + 600×wordPrefix +
   300×subsequenceQuality + 200×recencyDecay + 120×frequency + typeWeight`, where
   `subsequenceQuality` rewards contiguous and word-boundary matches (a Sublime-style fuzzy match)
   and `recencyDecay = exp(−age/7days)`. Ties break by name. A fixture of 40 (query → expected top
   result) pairs must pass, including "fd" → "Front Door" and "3x3" → the 3×3 layout.
3. `[A]` Opens in ≤ 33 ms with 200 cameras loaded; keystroke-to-updated-results ≤ 16 ms; results are
   computed off the main actor when the candidate set exceeds 500.
4. `[M]` Row anatomy: icon or live thumbnail, primary label with matched characters emphasized,
   secondary context (group / camera name), a right-aligned action verb, and the keyboard shortcut
   when one exists. `↑`/`↓` navigate, `Return` runs, `⌘Return` runs in a new window where meaningful,
   `Esc` dismisses.
5. `[A]` Fully VoiceOver-operable: the field announces the result count and the selected row.
**Risk:** *Low.*

### F-AUT-02 · Keyboard shortcuts and menu bar `P0`
**Modules:** VigilUI
**What:** Every action reachable from the keyboard, and every shortcut discoverable in the menus.
**Acceptance:**
1. `[A]` The complete shortcut table is implemented (UX.md holds the authoritative full list; this
   document requires the set below to exist and to be mirrored in menus):
   `⌘1`–`⌘8` layouts · `⌥⌘1`–`⌥⌘9` layout presets · `⌘F` fullscreen tile · `⌘⌃F` video wall ·
   `Space` play/pause (playback) · `⌘R` record · `⇧⌘S` snapshot · `⌥⇧⌘S` snapshot all · `⌘K` palette ·
   `⌘L` sidebar · `⌥⌘I` inspector · arrows PTZ · `⌥`+arrows tile navigation · `⌃1`–`⌃9` PTZ presets ·
   `⌘,` settings · `⌘E` export · `/` search · `Esc` exit/cancel · `⇧⌘M` mute all · `T` push-to-talk ·
   `⌘D` diagnose · `I`/`O` in/out points · `,`/`.` frame step · `J`/`K`/`L` speed.
2. `[A]` Menu structure App / File / Edit / View / Camera / Playback / Window / Help mirrors **every**
   shortcut; a test enumerates all `KeyboardShortcut` values and asserts each appears in exactly one
   menu item and that no shortcut is duplicated.
3. `[A]` Shortcuts are rebindable (Settings ➝ Shortcuts) with conflict detection; the binding store
   persists and a reset-to-defaults exists.
4. `[A]` No shortcut conflicts with a macOS system shortcut; validated against a checked-in list.
**Risk:** *Low.*

### F-AUT-03 · Deep links (`vigil://`) `P0`
**Modules:** Vigil (executable) · VigilCore
**What:** A URL scheme so anything on the Mac can drive Vigil.
**Acceptance:**
1. `[A]` Registered via `CFBundleURLTypes` with scheme `vigil`. The grammar is normative:

   ```
   vigil://camera/<uuid|slug>[?action=live|fullscreen|snapshot|record|stop|diagnose][&stream=main|sub]
   vigil://group/<uuid|slug>
   vigil://layout/<mode|presetName>
   vigil://preset/<cameraRef>/<presetNumber>
   vigil://playback/<cameraRef>?t=<ISO8601>[&speed=<0.25..8>]
   vigil://event/<eventID>
   vigil://snapshot-all
   vigil://palette[?q=<query>]
   vigil://settings/<pane>
   ```
2. `[A]` Parsing is pure and total: an unknown host or malformed parameter produces a typed error and
   a user-visible "That Vigil link isn't valid" message — never a crash, never a silent no-op.
   Percent-encoding, slugs with spaces, and unknown query parameters are all handled.
3. `[A]` A `<slug>` is a case-insensitive, whitespace-collapsed camera or group name; ambiguity opens
   the palette pre-filtered rather than guessing.
4. `[A]` **Destructive or privacy-relevant actions require confirmation when the app is not
   frontmost:** `record` and `snapshot` triggered by a link from another app show a confirmation
   unless the user has enabled "Allow links to record and capture without asking". A link can never
   silently start recording or push audio.
5. `[A]` A link received while the app is not running launches it, restores state, then performs the
   action.
**Risk:** *Low* — with the confirmation rule, which exists because a URL scheme is an unauthenticated
input surface.

### F-AUT-04 · App Intents / Shortcuts `P0`
**Modules:** Vigil · VigilCore · AppIntents
**What:** First-class Shortcuts and Spotlight support so Vigil composes with the rest of the system.
**Acceptance:**
1. `[A]` Intents shipped: `OpenCameraIntent`, `SetLayoutIntent`, `RecallLayoutPresetIntent`,
   `TakeSnapshotIntent` (returns an `IntentFile` so Shortcuts can save or send it),
   `SnapshotAllCamerasIntent`, `StartRecordingIntent`, `StopRecordingIntent`,
   `GoToPTZPresetIntent`, `SetMuteIntent`, `GetCameraStatusIntent` (returns fps, bitrate, state,
   uptime), `ListCamerasIntent`, `StartCyclingIntent`, `DiagnoseCameraIntent`.
2. `[A]` `CameraEntity: AppEntity` with a `EntityQuery` supporting suggested entities and string
   search, so Shortcuts shows the user's real camera names in pickers.
3. `[A]` `AppShortcutsProvider` supplies phrases including "Snapshot all cameras with
   ${applicationName}" and "Show ${camera} in ${applicationName}".
4. `[A]` Intents work with the app not running (launch, act, return) and return typed results and
   localized errors, not generic failures. Intents that capture or record honour the same
   confirmation rule as `F-AUT-03` via `requestConfirmation()`.
5. `[A]` A Shortcut chaining `ListCameras → TakeSnapshot → Save to Files` works end-to-end in the
   release checklist.
**Risk:** *Medium* — App Intents on macOS 14 has rough edges around entity queries and file results.
*Mitigation:* keep every intent's parameter set small and primitive; the file-returning intent is
tested explicitly in the checklist.

### F-AUT-05 · Menu-bar extra with live badge `P0`
**Modules:** Vigil · VigilUI
**What:** Vigil present and useful without its window open.
**Acceptance:**
1. `[A]` A `MenuBarExtra` scene (`.menuBarExtraStyle(.window)`) with: a 2×N grid of live micro-
   thumbnails (JPEG-poll at 1 Hz, ≤ 0.15 % CPU each, capped at 8 tiles), per-camera status dots, and
   actions Snapshot all / Mute all / Start–stop recording / Open Vigil / Open Video Wall / Quit.
2. `[A]` The badge is a composed state, in priority order: **red dot with a count** = cameras
   offline; **amber** = degraded; **red circle** = recording in progress (with count); **blue** =
   unread events; plain icon = all well. The badge is drawn as a template image so it works in both
   menu-bar appearances and with Reduce Transparency.
3. `[A]` The extra can be hidden entirely (Settings ➝ General) and the app can optionally run as a
   menu-bar-only app (`LSUIElement` toggled at runtime by relaunching with a flag, with the main
   window reachable from the extra).
4. `[A]` With the main window closed, total app CPU with 8 menu-bar thumbnails ≤ 2.5 % and energy
   impact ≤ 6.
**Risk:** *Low.*

### F-DAT-01 · CSV and JSON import/export of camera configuration `P0`
**Modules:** VigilCore · VigilUI · UniformTypeIdentifiers
**What:** Get cameras in and out without retyping — the difference between a 4-camera toy and a
40-camera install.
**Acceptance:**
1. `[A]` **CSV export** header is exactly:
   `name,host,http_port,rtsp_port,use_tls,channel,transport,stream,group,username,color_tag,enabled,rtsp_path_override,notes`
   RFC 4180 quoting, UTF-8 with no BOM, CRLF line endings, `\r\n` inside quoted fields preserved.
   **`password` is never a column.**
2. `[A]` **CSV import** accepts that header in any column order, tolerates extra unknown columns,
   accepts semicolon or comma delimiters (detected), accepts a BOM, and reports per-row errors with
   line numbers in a preview table before committing. Import is all-or-nothing per confirmation, with
   a "skip bad rows" option.
3. `[A]` Import asks once for a password per distinct `(host, username)` pair and stores it in the
   Keychain; rows may share credentials. Import never writes a password to disk.
4. `[A]` **JSON export** is the full library document (cameras, groups, layouts, presets, settings,
   bookmarks) minus secrets, minus TLS pin material by default, with `schemaVersion`, pretty-printed
   with sorted keys so it diffs cleanly in git.
5. `[A]` JSON import supports **merge** (match on host+port+channel, update in place) or **replace**
   (with an automatic pre-import backup written next to `library.json`), previewed as "12 new,
   3 updated, 1 unchanged".
6. `[A]` Round-trip fidelity test: export → wipe → import restores an identical library (excluding
   credentials, which are re-entered) for a 200-camera fixture.
7. `[A]` Exported types are declared UTTypes (`com.vigil.library-json`, plus `public.comma-
   separated-values-text`) so Finder and the Open dialog behave correctly.
**Risk:** *Low.*

### F-DAT-02 · Encrypted configuration export `P0`
**Modules:** VigilCore · Security / CommonCrypto
**What:** A single portable file that *does* include credentials, protected by a passphrase — how a
setup moves to a new Mac.
**Acceptance:**
1. `[A]` Container `.vigilbackup`, a small binary format with a versioned header:

   | Offset | Size | Field |
   |---|---|---|
   | 0 | 8 | magic `VIGILBK1` |
   | 8 | 2 | format version (BE) = 1 |
   | 10 | 1 | KDF id = 1 (PBKDF2-HMAC-SHA256) |
   | 11 | 4 | KDF iterations (BE) = 600 000 |
   | 15 | 16 | salt (CSPRNG) |
   | 31 | 1 | cipher id = 1 (AES-256-GCM) |
   | 32 | 12 | nonce (CSPRNG) |
   | 44 | 4 | ciphertext length (BE) |
   | 48 | n | ciphertext (gzip-free JSON payload) |
   | 48+n | 16 | GCM tag |

   The header bytes 0…43 are the GCM **AAD**, so a tampered header fails authentication.
2. `[A]` Crypto uses **CommonCrypto** (`CCKeyDerivationPBKDF` with `kCCPRFHmacAlgSHA256`, and
   `CCCryptorCreateWithMode` with `kCCModeGCM`, AES-256). CommonCrypto is part of libSystem, not a
   package, so the zero-dependency rule holds; it is macOS-only, so this code lives in **VigilCore**
   and never in a Linux-testable target. Salt and nonce come from `SecRandomCopyBytes`.
   *(Constraint for other agents: no pure-layer module may reference CommonCrypto.)*
3. `[A]` Passphrase requirements enforced with a strength meter: ≥ 12 characters; the export is
   refused below that with an explanation, not silently weakened.
4. `[A]` Import verifies the tag before touching anything; a wrong passphrase says "That passphrase
   didn't work" and a corrupted file says "This backup file is damaged" — two distinct messages,
   because they need different user actions. Neither leaks whether the passphrase was close.
5. `[A]` Round-trip test: export with credentials → wipe library and Keychain → import → every camera
   connects with no re-entry.
6. `[A]` The decrypted plaintext exists only in memory, is zeroed after use, and is never written to a
   temporary file.
**Risk:** *Medium* — hand-rolled container formats are where crypto mistakes live. *Mitigation:* the
format is deliberately minimal, uses only authenticated encryption with the header as AAD, has
KDF/cipher ids for future migration, and is covered by test vectors checked into the repo plus a
tamper test that flips each header byte and asserts failure.

### F-DAT-03 · Diagnostics bundle export `P0`
**Modules:** VigilCore · VigilUI
**What:** One action producing everything needed to debug a problem — with nothing in it the user
wouldn't want to send.
**Acceptance:**
1. `[A]` Contents of `Vigil-Diagnostics-<yyyyMMdd-HHmmss>.zip`:

   | File | Content |
   |---|---|
   | `summary.txt` | App version + build, macOS version, hardware model, CPU/GPU, memory, display config, locale, appearance |
   | `library-redacted.json` | Full config with credentials absent, hostnames pseudonymized (opt-in to include real ones), serials masked |
   | `logs/vigil-<date>.log` | Last 24 h from OSLog via `OSLogStore(scope:.currentProcessIdentifier)`, redacted per §11 |
   | `streams/<camera>/sdp.txt` | Last SDP per camera |
   | `streams/<camera>/rtsp-transcript.txt` | Last full RTSP exchange with `Authorization` elided |
   | `streams/<camera>/stats.csv` | 24 h of 1-minute health rollups |
   | `streams/<camera>/doctor.txt` | Last Stream Doctor result |
   | `capabilities/<camera>.xml` | Cached ISAPI capability responses, redacted |
   | `events.csv` | Last 5000 events (no thumbnails) |
   | `crash-context.json` | Last-run state, unclean-shutdown flag, last 200 in-app breadcrumbs |
   | `manifest.json` | File list with SHA-256 of each entry, redaction settings used |

2. `[A]` The ZIP is produced by a small **STORE-only** (no compression) ZIP writer in VigilCore with
   a pure-Swift CRC-32 — valid per the PKZIP APPNOTE, no new framework, ~90 lines. Bundle size is
   ≤ 40 MB; the writer is tested by extracting with `/usr/bin/unzip` in CI and by Archive Utility in
   the checklist.
3. `[M]` A preview sheet lists every file with its size and lets the user open any of them **before**
   saving or sharing, plus toggles for "include hostnames" (default off) and "include full logs"
   (default on). Nothing leaves the machine automatically — the bundle is only ever written to a
   user-chosen location.
4. `[A]` Generation completes in ≤ 6 s for a 16-camera library and is cancellable.
5. `[A]` An automated test asserts the bundle contains no password, no `Authorization` header value,
   no full serial number and no full session id, using a seeded library with known secrets.
**Risk:** *Low.*

### F-PLT-01 · Windows, scenes and state restoration `P0`
**Modules:** Vigil · VigilUI
**What:** Windows behave the way Mac users expect.
**Acceptance:**
1. `[A]` Scenes: main `WindowGroup` (single instance), `Window` for Playback, `Window` for Video
   Wall, `Window` for Discovery, `Settings`, plus `MenuBarExtra` and a custom About window.
2. `[A]` Frame, sidebar/inspector visibility and widths, layout, camera assignment and selection are
   restored on relaunch; window frames are validated against current screens so a window never opens
   off-screen after a display change.
3. `[A]` Minimum main-window size 960×640; the layout degrades gracefully (inspector auto-collapses
   below 1100 pt, sidebar below 820 pt) with no clipped or overlapping content at any size.
4. `[A]` Closing the main window keeps the app running (streams pause, menu-bar extra remains);
   `⌘N`/Dock click reopens it and resumes within 1.5 s.
5. `[A]` Full-screen and Stage Manager are supported; entering full screen does not restart streams.
**Risk:** *Low.*

### F-PLT-02 · Appearance: light, dark, auto `P0`
**Modules:** VigilUI
**What:** Both appearances, first-class.
**Acceptance:**
1. `[A]` Setting: Light / Dark / Match System (default), applied via
   `NSApp.appearance` and honoured immediately with no relaunch.
2. `[M]` Every screen is visually audited in both appearances at 100 % and 200 % scale. Video tiles
   keep a neutral surround in both (letterbox never becomes light grey in Light mode).
3. `[A]` Contrast: all text and all meaningful UI meets **4.5:1** (3:1 for ≥ 18 pt or bold), verified
   by a scripted check over the design system's token pairs, in both appearances and with Increase
   Contrast enabled.
4. `[A]` Materials (`.regularMaterial`, `.thinMaterial`) are used for chrome and are replaced with
   opaque tokens when Reduce Transparency is on.
**Risk:** *Low.*

### F-PLT-03 · Localization scaffolding, English + Russian `P0`
**Modules:** VigilUI · VigilCore · all user-facing strings
**What:** Fully localized in English and Russian, with the Russian strings actually written — not a
placeholder file.
**Acceptance:**
1. `[A]` Resources: `Sources/VigilUI/Resources/en.lproj/Localizable.strings` +
   `Localizable.stringsdict`, and `ru.lproj/` equivalents, declared as SwiftPM `.process` resources
   and accessed through **one** wrapper so no view calls `NSLocalizedString` directly:
   ```swift
   public enum Str {
       public static func t(_ key: String, _ args: CVarArg...) -> String
       public static func plural(_ key: String, count: Int) -> String
   }
   ```
   `.strings`/`.stringsdict` (not `.xcstrings`) are used so `swift build` works without Xcode.
2. `[A]` Keys are hierarchical and stable: `live.empty.title`, `error.auth.failed.body`,
   `doctor.cause.multicastBlocked.fix`. A CI check fails the build on: a literal user-facing string in
   a view (a lint rule over `Text("` with a non-`Str.` argument), a key present in `en` but missing in
   `ru`, an unused key, or a format-specifier mismatch between locales.
3. `[A]` **Russian is complete** — every key, translated by a Russian speaker, not machine output —
   and uses the correct plural categories `one` / `few` / `many` / `other` in `.stringsdict`
   (`1 камера`, `2 камеры`, `5 камер`). At least 12 plural-bearing strings exist and are correct.
4. `[A]` Formatting is locale-correct everywhere: dates and times via `Date.FormatStyle`, numbers and
   bitrates via `FormatStyle`/`Measurement`, byte sizes via `ByteCountFormatStyle`, durations via
   `Duration.UnitsFormatStyle`. No hand-built `"\(x) Mbps"` strings — a lint rule enforces this.
5. `[M]` Russian layout audit: Russian text averages 15–30 % longer, so no label has a fixed width; a
   `--pseudo-loc` launch flag expands every string by 40 % and brackets it, and the whole app is
   audited under it with zero truncation or clipping.
6. `[A]` Right-to-left is not required for these two locales, but no layout uses hardcoded
   `.leading`-as-left geometry that would break it (uses `.leading`/`.trailing`, never `.left`).
**Risk:** *Medium* — string drift and untranslated leakage. *Mitigation:* the CI key-parity and
literal-string lints are acceptance criteria, so drift breaks the build.

### F-PLT-04 · Full keyboard accessibility `P0`
**Modules:** VigilUI
**What:** The entire app operable without a pointer.
**Acceptance:**
1. `[A]` Every interactive element is focusable and activatable; `Tab`/`⇧Tab` order is logical
   top-to-bottom, left-to-right within each region; `⌃Tab` moves between sidebar, stage and
   inspector.
2. `[M]` The focus ring is always visible, uses the system accent, has ≥ 3:1 contrast against every
   background it appears on, and is never clipped by a tile's edge.
3. `[A]` Full Keyboard Access (System Settings ➝ Accessibility) navigates and activates every control
   including the tile chrome, the PTZ pad, the timeline and the palette.
4. `[A]` No action is pointer-only: PTZ, digital zoom/pan, 3D positioning (via a keyboard-driven
   selection rectangle), timeline scrubbing, in/out points and mosaic resizing all have keyboard
   equivalents documented in Help.
5. `[A]` Modal sheets trap focus, restore it on dismissal, and respond to `Esc` and `Return`.
**Risk:** *Low.*

### F-PLT-05 · VoiceOver and assistive support `P0`
**Modules:** VigilUI
**What:** Usable with VoiceOver, including the parts that are inherently visual.
**Acceptance:**
1. `[A]` Every control has a label, and a hint where the action isn't obvious. A CI check asserts no
   `Button` ships without an accessibility label.
2. `[A]` A video tile is a single accessibility element whose label reads
   *"Front Door, live, 1920 by 1080, H.265, hardware decode, 25 frames per second"* and whose value
   updates on state change; the raw video surface is not exposed as an unlabelled image.
3. `[A]` State changes are announced without stealing focus, via
   `NSAccessibility.post(element:notification:.announcementRequested)` with
   `.priority = .medium`: camera went offline, reconnected, recording started/stopped, motion
   detected, snapshot saved. Announcements are rate-limited to at most one per 2 s.
4. `[A]` The timeline exposes an accessible alternative: a navigable list of recording segments with
   start time, duration and type, plus an adjustable value (`←`/`→` moves the playhead by the current
   zoom step) with a spoken time readout.
5. `[A]` Health sparklines expose a text summary ("frame rate 25, steady; packet loss 0.1 percent");
   the event feed is a proper list with headings.
6. `[M]` A full VoiceOver pass — add a camera, view it, PTZ it, snapshot it, record it, find the clip,
   play it back, export it — is completed with the screen off. This is a release gate, not a nice-to-
   have.
7. `[A]` Reduce Motion replaces every spring and crossfade with an instant change or a ≤ 100 ms
   opacity fade; Increase Contrast strengthens borders and disables translucency; Differentiate
   Without Color adds icons or text to every colour-coded status (status dots, timeline bands,
   HW/SW chips).
**Risk:** *Medium* — a live-video app has genuinely hard accessibility surfaces. *Mitigation:* the
timeline's accessible alternative and the tile's composed label are explicit criteria, designed in
rather than retrofitted.

### F-SEC-01 · Parser hardening against hostile device input `P0`
**Modules:** VigilProtocols · VigilRTSP · VigilRTP · VigilBitstream · VigilISAPI · VigilDiscovery
**What:** Every byte we parse comes from a device we don't control. Treat it as hostile.
**Acceptance:**
1. `[A]` All parsing goes through the shared bounds-checked `ByteReader` / `BitReader` in
   VigilProtocols. No parser indexes a buffer directly; a lint check forbids raw subscripting of
   `Data`/`[UInt8]` in parser files.
2. `[A]` No `!`, no `try!`, no `as!`, no `unsafelyUnwrapped`, no `assumingMemoryBound` in any
   non-test target. Enforced by a CI grep.
3. `[A]` Every length field from the wire is validated against the remaining buffer before use.
   Allocation driven by a wire length is capped: RTSP message 256 KB, RTSP body 1 MB, SDP 256 KB,
   RTP packet 65 535 B, access unit 8 MB, ISAPI response 8 MB, discovery packet 8 KB, multipart part
   4 MB. Exceeding a cap is a typed error, never an allocation.
4. `[A]` **Fuzz campaign in CI**: ≥ 1 000 000 mutated inputs per parser (RTSP message, SDP, RTP
   H.264/H.265/AAC/JPEG, SPS/PPS/VPS, ISAPI XML, SADP, WS-Discovery) using a seeded corpus plus a
   structure-aware mutator, run on Linux where the whole pure layer builds. Zero crashes, zero hangs
   (500 ms per-input budget), zero allocations above the caps. A nightly 24-hour soak also runs.
5. `[A]` Recursion depth in the XML parser is capped at 64; entity expansion is disabled (no XXE, no
   billion-laughs); external DTDs are refused.
6. `[A]` Integer arithmetic on wire values uses explicitly checked or `&`-wrapping operators with a
   documented reason — never accidental overflow.
**Risk:** *Medium* — this is the app's real attack surface. *Mitigation:* the fuzz campaign is a CI
gate, and the pure-layer/Linux design exists partly to make it cheap to run.

### F-SEC-02 · LAN-only egress enforcement `P0`
**Modules:** VigilProtocols (policy, pure) · VigilTransport · VigilISAPI
**What:** Vigil connects to the user's cameras and to nothing else. Enforced in code, not just by
intent. Full rationale in §11.
**Acceptance:**
1. `[A]` A pure `HostPolicy.classify(_ host: String) -> HostClass` returns `.privateLAN`,
   `.linkLocal`, `.loopback`, `.mDNSLocal` or `.public`, correct for: `10/8`, `172.16/12`,
   `192.168/16`, `169.254/16`, `127/8`, `100.64/10` (CGNAT, treated as public), `fc00::/7`,
   `fe80::/10`, `::1`, `*.local`, and IPv4-mapped IPv6. Unit-tested with 60 cases.
2. `[A]` Every outbound connection in VigilTransport and VigilISAPI calls the policy first. A
   `.public` destination is refused unless the user has enabled "Allow cameras outside my local
   network" (default off, for VPN and port-forward users), and enabling it shows a plain explanation
   of the risk.
3. `[A]` A test asserts there is exactly one code path that can open a socket or an
   `URLSessionTask`, and that it is policy-gated; a second test asserts the app makes **zero**
   network connections in a run with no cameras configured.
4. `[M]` Release-checklist verification with `lsof -i -P -n -p <pid>` and a packet capture during a
   10-minute session: every destination is a configured camera. No analytics host, no update host, no
   CDN.
**Risk:** *Low.*

---

## 16. P1 — ship if time allows

| ID | Feature | Why P1, not P0 | Modules | Risk |
|---|---|---|---|---|
| `F-DSC-08` | **In-app device activation** — set the initial admin password on an unactivated camera via `PUT /ISAPI/System/activate` with `<ActivateInfo version="2.0"><password>…</password></ActivateInfo>` (RSA-wrapped where the firmware requires it), then auto-add. | `F-DSC-04`'s warning already unblocks the user; writing an admin password has real firmware variance and real consequences. | VigilISAPI, VigilUI | High |
| `F-DSC-09` | Bonjour/mDNS discovery via `NWBrowser` for `_rtsp._tcp` and `_http._tcp`. | Hikvision rarely advertises; SADP + WS-Discovery + sweep already cover it. | VigilDiscovery, VigilTransport | Low |
| `F-LIV-09` | Cinema mode: hide all chrome, dim the desktop, one camera at maximum size. | Fullscreen (`F-LIV-04`) already covers the need. | VigilUI | Low |
| `F-LIV-10` | Per-tile aspect-ratio and rotation correction (90°/180°/270°) for ceiling-mounted cameras. | A workaround exists device-side (`F-IMG-01` image flip). | VigilRender | Low |
| `F-PTZ-06` | Patrol editing — create and reorder patrol steps, set dwell and speed. | Start/stop (`F-PTZ-03`) covers daily use; editing is rare and firmware-variable. | VigilISAPI, VigilUI | Medium |
| `F-PTZ-07` | PTZ tracks: record a manual pan/tilt sequence and replay it. | Genuinely nice, not expected. | VigilISAPI, VigilCore | Medium |
| `F-REC-04` | Continuous scheduled local recording with ring-buffer retention (a mini-NVR on the Mac). | Motion-triggered (`F-REC-03`) plus manual covers the security need; continuous is a storage-management product of its own. | VigilCore | Medium |
| `F-REC-05` | Recording to an external or network volume with reconnect handling and a "volume disappeared" recovery. | Local disk is the 1.0 target. | VigilCore | Medium |
| `F-PLB-07` | Playback download via `POST /ISAPI/ContentMgmt/download` as an alternative to RTSP export, for firmware where playback RTSP misbehaves. | `F-PLB-04` covers export; this is a robustness alternative. | VigilISAPI, VigilCore | Medium |
| `F-PLB-08` | Smart-search within a recording (motion in a drawn region) via ISAPI VCA search. | Timeline + events already get the user there. | VigilISAPI, VigilUI | Medium |
| `F-AUD-03` | Audio recording alongside snapshots as short "listen clips". | Marginal. | VigilCore | Low |
| `F-AUT-06` | AppleScript support via a hand-written `.sdef` and `NSScriptCommand` (`snapshot`, `record`, `cameras`, `set layout`). | App Intents (`F-AUT-04`) already covers Shortcuts, Siri and Spotlight; `.sdef` serves a legacy audience. | Vigil | Medium |
| `F-AUT-07` | System-wide global hotkeys (`RegisterEventHotKey`) for "Snapshot all" and "Show Vigil", opt-in. | In-app shortcuts cover the main need; this is the only Carbon API we'd use. | Vigil | Low |
| `F-AUT-08` | Focus-filter and Stage-Manager awareness: auto-mute and suppress notifications in a Focus mode. | Polish. | Vigil | Low |
| `F-HLT-07` | Bandwidth budget: a total-Mbps ceiling that demotes streams like the decode budget does. | The decode budget is the binding constraint on the target hardware. | VigilCore | Medium |
| `F-HLT-08` | Wake-on-LAN / ISAPI reboot of a camera from the app, with confirmation. | Destructive; the camera's web page does it. | VigilISAPI, VigilUI | Low |
| `F-DAT-04` | Time-synchronization helper: detect camera clock skew > 60 s and offer to set the camera's time from the Mac (`PUT /ISAPI/System/time`). | Skew is *detected* and surfaced in P0 (`F-PLB-01`); fixing it is a write. | VigilISAPI | Low |
| `F-DAT-05` | Migration import from other clients (iVMS-4200 device lists, Blue Iris, Synology Surveillance Station CSV). | CSV import (`F-DAT-01`) covers most of it. | VigilCore | Low |
| `F-PLT-06` | Additional localizations (German, Spanish, French, Polish, Ukrainian). | The scaffolding and the ru proof ship in P0. | VigilUI | Low |
| `F-PLT-07` | Manual, user-initiated update check (a single HTTPS GET, no background pings, off by default). | Conflicts with the LAN-only default; must be explicitly opt-in and is not needed to ship. | Vigil | Low |
| `F-PLT-08` | Onboarding tour and an interactive Help book. | Good first-run copy (P0) carries 1.0. | VigilUI | Low |
| `F-SEC-03` | Per-camera TLS certificate management UI: view, re-pin, export the pinned certificate. | P0 handles pinning and mismatch correctly (§11); the management UI is convenience. | VigilCore, VigilUI | Low |

---

## 17. P2 — future, explicitly out of 1.0 and 1.1

| ID | Feature | Note |
|---|---|---|
| `F-P2-01` | Client-side motion detection by frame differencing (for cameras with no VCA), with a drawn mask and sensitivity. Would run on already-decoded frames in Metal, so it is architecturally reachable — deliberately deferred because device-side detection is better tuned and free. |
| `F-P2-02` | On-device object classification (person / vehicle) using a Core ML model on decoded frames, entirely local. Requires CoreML, which is outside the agreed framework list, and a model-distribution story. |
| `F-P2-03` | Multi-Mac federation: view another Mac's cameras over the LAN. |
| `F-P2-04` | An iPad/iPhone companion built on the same pure protocol targets (the layering already permits it). |
| `F-P2-05` | Audio analytics: glass-break and shouting detection. |
| `F-P2-06` | Fisheye dewarping and 360° projection in the Metal renderer. |
| `F-P2-07` | Map/floorplan view with camera pins and click-to-view. |
| `F-P2-08` | Number-plate and text search across recordings. |
| `F-P2-09` | Scriptable rule engine ("if motion on Gate between 22:00 and 06:00 then record, notify and run this shortcut"). |
| `F-P2-10` | RTSP/WebRTC re-serving of a stream to a browser on the LAN. |
| `F-P2-11` | Full Dahua and Axis native protocol support (beyond the ONVIF fallback). |
| `F-P2-12` | Sound-triggered recording from the camera's audio-detection alarm. |
| `F-P2-13` | Storage management of the device itself: format an NVR disk, configure device-side recording schedules. |

---

## 18. Non-goals

These are not "later". They are **decisions**, and the architecture is allowed to make them harder.

### 18.1 No cloud, no account, no server component
There is no Vigil backend, no login, no sync service. Every byte stays on the user's LAN and their
Mac. *Why:* it is the product's central promise and its main differentiator against the vendor apps.
A cloud component would add an account system, a privacy policy, a data-retention obligation, an
attack surface, an operating cost and a dependency on our uptime for a tool whose entire job is to
work when the internet doesn't. *Consequence:* remote access is the user's VPN's job, and we support
that only via the explicit `F-SEC-02` opt-in.

### 18.2 No P2P / Hik-Connect / vendor relay
We will not implement Hik-Connect, EZVIZ, or any vendor P2P tunnel. *Why:* the protocol is
proprietary, undocumented, and reverse-engineered implementations break with every firmware release —
we would be shipping a feature we cannot maintain or test. It routes video through a third-party
cloud, which directly contradicts §18.1 and §11. It typically requires a vendor account and a device
verification code, moving the trust boundary off the LAN. And it cannot be built without either a
dependency or a large undocumented crypto stack, violating the zero-dependency rule. *What we do
instead:* be excellent on the LAN and honest that remote viewing needs a VPN.

### 18.3 No iOS / iPadOS / Apple TV app in this project
*Why:* the entire UI layer is AppKit-interop SwiftUI tuned for a pointer, a keyboard and large
windows; a mobile app is a different product with different interaction, different power constraints
and different background-execution rules. Splitting focus would make both mediocre. *Mitigation of
the cost:* the pure protocol targets (VigilProtocols, VigilRTSP, VigilRTP, VigilBitstream,
VigilISAPI, VigilDiscovery) are platform-independent by design, so ~60 % of the hard work is already
portable when someone does build `F-P2-04`.

### 18.4 No transcoding, no re-encoding, no media server
Vigil never re-encodes video. Recording and export are passthrough muxing only. *Why:* transcoding
requires either FFmpeg (a hard violation of the zero-dependency rule) or a VideoToolbox encode path
that would burn the CPU and GPU headroom the 16-stream target depends on. It also degrades evidence:
a re-encoded clip is no longer what the camera saw. *Consequence:* we cannot serve a browser, cannot
change a clip's resolution on export, and cannot play a codec the Mac has no decoder for — we say so
clearly instead (`F-DEC-02` criterion 5, `F-HLT-06` `unsupportedCodec`).

### 18.5 No face recognition or biometric identification
*Why, in order of weight:* (1) **legal** — biometric identifiers are separately regulated under GDPR
Art. 9, Illinois BIPA, Texas CUBI and others, with per-subject consent duties we cannot discharge in
a local viewer; (2) **accuracy and harm** — a false match in a security context can put an innocent
person in front of the police, and demographic error-rate disparities are well documented;
(3) **technical** — it needs a shipped ML model and CoreML, both outside the agreed dependency and
framework rules. Generic, non-identifying *object* classification is `F-P2-02` and would remain
fully on-device; identifying *who* someone is stays out of scope permanently.

### 18.6 Also explicitly not in scope
- **Configuring the camera beyond image, PTZ and time.** No network, user, storage, schedule or
  firmware writes. A bad write can brick a camera or lock out the owner; the camera's own web page is
  a better place. `F-DSC-08` (activation) and `F-DAT-04` (clock) are the two narrowly-justified
  exceptions, both P1, both confirmed.
- **Firmware updates.** Highest-consequence write there is, and it needs vendor image
  authentication.
- **A generic RTSP player.** Vigil is a camera client. Files, HLS, DASH, YouTube and desktop capture
  are out.
- **Client-side motion detection in 1.0.** See `F-P2-01`.
- **Windows or Linux GUI.** The pure targets *build and test* on Linux; that is a testing and
  correctness strategy, not a shipping target.

---

## 19. Performance budget

Every number is a **release gate**. A regression above threshold blocks the build. All figures are on
the reference hardware and reference network of §1.3 unless noted, measured after a 60 s warm-up over
a 120 s window, best of 3 runs discarded high and low.

### 19.1 Latency and responsiveness

| # | Metric | Target | Stretch | How measured |
|---|---|---|---|---|
| L1 | Cold launch → main window visible | p50 ≤ 320 ms, p95 ≤ 500 ms | 250 ms | `os_signpost` interval `launch` from `Vigil.init` to the first `viewDidMoveToWindow`; `xcrun xctrace record --template 'App Launch'`; 10 runs after `purge` |
| L2 | Cold launch → first video frame on screen (1 cached camera, TCP, keyframe requested) | **p50 ≤ 900 ms, p95 ≤ 1400 ms** | 700 ms | signpost `launchToFirstFrame` ending at the first `enqueue(_:)` on the focused tile's display layer; `XCTOSSignpostMetric` in a UI test |
| L3 | Add camera → first frame | ≤ 1.2 s p95 | 900 ms | signpost `addToFirstFrame` |
| L4 | **Glass-to-glass, UDP, Low preset (30 ms buffer)** | **p50 ≤ 95 ms, p95 ≤ 140 ms** | 80 ms | physical rig, §19.5 |
| L5 | **Glass-to-glass, UDP, Balanced (60 ms)** | **p50 ≤ 120 ms, p95 ≤ 180 ms** | 100 ms | physical rig |
| L6 | **Glass-to-glass, TCP interleaved, Balanced** | **p50 ≤ 160 ms, p95 ≤ 250 ms** | 140 ms | physical rig |
| L7 | Glass-to-glass, Quality preset (150 ms) | p95 ≤ 340 ms | — | physical rig |
| L8 | In-app latency estimate vs rig | within ±25 ms | ±15 ms | rig, both values recorded simultaneously |
| L9 | Layout switch → all tiles rendering (warm sessions) | ≤ 600 ms | 400 ms | UI test with signposts per tile |
| L10 | Main↔sub stream switch, no black frame | ≤ 800 ms to new keyframe | 500 ms | fixture test; frame-buffer sampling asserts no black frame |
| L11 | PTZ key press → camera motion visible | ≤ 180 ms | 120 ms | 240 fps capture of the key press and the monitor |
| L12 | Snapshot keypress → file closed on disk | ≤ 150 ms | 100 ms | signpost, 20 runs |
| L13 | Record start → first byte written | ≤ 250 ms | 150 ms | signpost |
| L14 | Command palette open → interactive | ≤ 33 ms | 16 ms | signpost, 200-camera library |
| L15 | Palette keystroke → results updated | ≤ 16 ms | 8 ms | signpost |
| L16 | Timeline scrub → preview thumbnail | ≤ 120 ms p50 | 80 ms | signpost |
| L17 | Wake from sleep → first frame back | ≤ 2.5 s | 1.5 s | scripted `pmset sleepnow`, 10 cycles |
| L18 | Reconnect after camera reboot → first frame | ≤ 4 s after the camera answers | 2.5 s | reboot-loop test (`F-HLT-05`) |

### 19.2 CPU, GPU, memory, energy

| # | Scenario | CPU (% of total machine) | GPU | Memory (phys_footprint) | Energy Impact |
|---|---|---|---|---|---|
| R1 | App running, no cameras | ≤ 0.5 % | ≈ 0 % | ≤ **180 MB** | ≤ 1.0 |
| R2 | 1 × 1080p25 H.264 sub, 1 tile | ≤ **2.2 %** | ≤ 1.1 % | ≤ 210 MB (+28 MB) | ≤ 6 |
| R3 | 1 × 1080p25 H.265 sub, 1 tile | ≤ 2.4 % | ≤ 1.1 % | ≤ 212 MB | ≤ 6 |
| R4 | 1 × 4K30 H.265 main, fullscreen | ≤ **6.0 %** | ≤ 4.5 % | ≤ 275 MB (+95 MB) | ≤ 14 |
| R5 | **16 × 1080p25 sub streams, 4×4 layout** | ≤ **35 %** | ≤ **18 %** | ≤ **900 MB** | ≤ 45 |
| R6 | 16 streams + 4 recording | ≤ 39 % | ≤ 18 % | ≤ 1.0 GB | ≤ 50 |
| R7 | 16 streams, window occluded (all paused) | ≤ 1.5 % | ≤ 0.5 % | ≤ 700 MB | ≤ 3 |
| R8 | 8 menu-bar thumbnails, main window closed | ≤ 2.5 % | ≤ 0.5 % | ≤ 320 MB | ≤ 6 |
| R9 | 4-camera synchronized playback at 1× | ≤ 21 % | ≤ 8 % | ≤ 700 MB | ≤ 30 |
| R10 | Playback at 8× | ≤ 15 % | ≤ 6 % | ≤ 500 MB | ≤ 25 |
| R11 | Clip export (passthrough), 8× realtime | ≤ 8 % | ≈ 0 % | ≤ 400 MB | ≤ 18 |
| R12 | 24-hour soak, 16 streams | — | — | RSS growth ≤ **10 MB** over 24 h | — |
| R13 | Hard memory ceiling, any scenario | — | — | **1.5 GB**; above 1.2 GB the coordinator sheds offscreen decoders and logs it | — |

Per-stream derived limits: ≤ 28 MB per 1080p stream, ≤ 95 MB per 4K stream (decoder pool + jitter
buffer + pre-roll); pre-roll is additionally capped by `F-REC-02`. Thread count ≤ 24 at 16 streams;
file descriptors ≤ 3 per stream (TCP) or 5 (UDP+RTCP).

### 19.3 UI smoothness

| # | Metric | Target | How measured |
|---|---|---|---|
| U1 | Frame time p99, 16 tiles live, 120 Hz | ≤ **7.0 ms** (budget 8.33) | `os_signpost` around each render pass + Instruments Metal System Trace; histogram over 60 s |
| U2 | Frame time p99, 16 tiles live, 60 Hz | ≤ 12.0 ms (budget 16.67) | as above |
| U3 | Dropped/hitched frames during a layout-switch animation | **0** hitches > 16 ms over 10 switches | Instruments "Animation Hitches"; `CADisplayLink` timestamp deltas |
| U4 | Scroll of a 200-camera sidebar | 0 hitches, p99 ≤ 7 ms | as above |
| U5 | Timeline redraw, 4000 segments | ≤ 4 ms per draw | `XCTClockMetric` on `draw(_:)` |
| U6 | Main-thread blocking work | **no main-actor operation > 8 ms** | debug-build watchdog asserting on any main-actor hop exceeding 8 ms; CI fails on any occurrence in the UI test suite |

### 19.4 Network and stream correctness

| # | Metric | Target |
|---|---|---|
| N1 | Packet loss on wired LAN, UDP, 1 h | ≤ 0.01 % |
| N2 | Frames dropped for non-network reasons, 1 h, 16 streams | ≤ 0.05 % of decoded frames |
| N3 | Recording bitrate overhead vs camera bitrate | ≤ 2 % (MP4 container overhead only) |
| N4 | Bandwidth, 16 × 1080p sub @ 1 Mbps | ≤ 18 Mbps total including RTCP and RTSP keepalives |
| N5 | Reconnect attempts per hour per healthy camera | 0 |
| N6 | A/V sync error | ≤ 80 ms |

### 19.5 Measurement apparatus (normative)

1. **Physical glass-to-glass rig.** A helper app (`Scripts/mstimer`) displays a monospaced
   millisecond counter, updated every display refresh, on the reference monitor. Camera C2 is aimed
   at the monitor; Vigil shows that camera's tile on the **same** monitor beside the counter. An
   iPhone records both at 240 fps. Latency = `counter_live − counter_in_tile`, ±4.2 ms quantization.
   **30 samples per configuration**, reported as p50/p95. Every value in §19.1 rows L4–L8 comes from
   this rig, and the rig procedure lives in the release checklist with the sample photos attached.
2. **Signposts.** `OSSignposter` intervals with fixed names (`launch`, `launchToFirstFrame`,
   `describe`, `setup`, `firstRTP`, `firstKeyframe`, `decode`, `render`, `snapshot`, `recordStart`,
   `paletteOpen`, `timelineDraw`) are permanent API, not debug scaffolding. `XCTOSSignpostMetric`
   asserts them in CI on macOS runners.
3. **CPU / GPU / energy.** `sudo powermetrics --samplers cpu_power,gpu_power,tasks -i 1000 -n 120`
   parsed by `Scripts/perfreport.swift`; Activity Monitor's Energy Impact recorded manually for the
   §19.2 column. Numbers are % of the whole machine, not % of one core.
4. **Memory.** `footprint -a Vigil` and `XCTMemoryMetric`; the 24-hour soak (R12) uses a sampled
   `phys_footprint` series and fails on a positive linear regression slope above 0.4 MB/h.
5. **Frame time.** Metal System Trace plus the signpost histogram; the debug watchdog for U6.
6. **CI enforcement.** Linux CI runs the pure-layer unit tests and the fuzz campaign. macOS CI runs
   the full suite plus `XCTOSSignpostMetric`/`XCTCPUMetric`/`XCTMemoryMetric` baselines with a **10 %
   regression tolerance**; exceeding it fails the job. The 24-hour soak and the rig measurements are
   nightly/pre-release, not per-commit.
7. **Load generation without cameras.** The synthetic RTSP server + RTP generator fixture
   (ARCHITECTURE.md) can serve 32 simultaneous synthetic 1080p H.264/H.265 streams from a second Mac
   or from localhost, so §19.2 R5/R6/R12 are reproducible in CI without a camera wall. Real-hardware
   confirmation on the six reference devices is still required for release.

---

## 20. Security and privacy

### 20.1 Principles
1. Credentials live in the Keychain. Nowhere else, in no form, at no time.
2. Vigil talks to the user's cameras and to nothing else.
3. We collect nothing. There is no telemetry to opt out of because there is none to begin with.
4. Device input is untrusted input.
5. Logs are safe to share. Redaction is a library function, not a habit.

### 20.2 Credentials
- Storage per `F-CRD-01`: `kSecClassInternetPassword`, `kSecAttrAccessibleWhenUnlocked`, one item per
  distinct credential, referenced from the config by an opaque `credentialRef` UUID.
- `library.json` contains **no** password, and no field that could hold one. The `Camera` type has no
  `password` property to accidentally encode — this is enforced by the type, not by discipline.
- Passwords are never placed in a URL (`F-CRD-02` criterion 5), never in a command line, never in an
  environment variable, never in a pasteboard, never in a crash-context breadcrumb.
- In memory, a password lives in a `Credential` value type whose backing bytes are overwritten on
  deinit; the cache is purged on screen lock.
- A CI test seeds a known password and asserts its absence from: `library.json`, `.bak`, JSON export,
  CSV export, the diagnostics bundle, all OSLog output captured during a full-session UI test, and
  any file Vigil created under `~/Library`.
- Only `F-DAT-02`'s encrypted `.vigilbackup` may contain credentials, and only under AES-256-GCM with
  a ≥ 12-character passphrase and 600 000 PBKDF2 iterations.

### 20.3 No telemetry
- No analytics SDK, no crash reporter, no usage ping, no "anonymous statistics" checkbox, no
  A/B framework, no remote config, no font or asset CDN, no automatic update check in 1.0.
- Enforcement: `F-SEC-02`'s single policy-gated egress path, plus a test asserting **zero** network
  connections with no cameras configured, plus a release-checklist packet capture.
- Crash handling is local only: an unclean-shutdown flag and the last 200 in-app breadcrumbs are
  written to `crash-context.json` for the *user* to send us deliberately via `F-DAT-03`. Nothing is
  uploaded.
- `F-PLT-07` (a manual update check) is P1, off by default, and a single user-initiated HTTPS GET
  that sends no identifiers — not a background ping.

### 20.4 LAN-only outbound traffic
- `HostPolicy` (`F-SEC-02`) classifies every destination before any socket opens. `.public`
  destinations are refused unless the user turns on "Allow cameras outside my local network".
- That setting exists for VPN and port-forward users. Enabling it shows: *"Vigil will be able to
  connect to cameras outside your local network. Only do this if you're using a VPN — exposing a
  camera directly to the internet is how cameras get taken over."* The setting is per-app, and each
  non-local camera additionally shows a badge.
- `NSLocalNetworkUsageDescription` explains local-network access in the system prompt:
  *"Vigil needs to find and connect to cameras on your local network."*
- We never proxy, never relay, never tunnel.

### 20.5 Plain HTTP and self-signed TLS
Cameras are shipped with self-signed certificates and are frequently reachable only over plain HTTP.
Refusing to work would just push users to a worse client; pretending it's secure would be dishonest.
So:

| Situation | Behaviour |
|---|---|
| ISAPI over plain HTTP to a private address | **Allowed.** `NSAppTransportSecurity` uses `NSAllowsLocalNetworking = true` (not `NSAllowsArbitraryLoads`), so plain HTTP is permitted to local names and private addresses only, and ATS still applies to everything else. |
| Plain HTTP to a public address | **Refused**, even with the non-local override on. TLS is required off-LAN. |
| Basic auth over plain HTTP | Refused by default; per-camera opt-in with an explicit warning (`F-CRD-02` criterion 6). Digest is always preferred. |
| HTTPS with a self-signed or unknown-CA certificate | **Trust on first use.** The leaf's SubjectPublicKeyInfo SHA-256 is shown to the user as a grouped fingerprint with the subject, issuer and validity dates; on acceptance the pin is stored in `library.json` as `tlsPinSPKI`. Implemented with `SecTrustEvaluateWithError` plus manual SPKI comparison in the `URLSession` challenge handler, and `sec_protocol_options_set_verify_block` for Network.framework. |
| Pinned certificate changes | **Hard fail.** "This camera's security certificate changed. If you just updated its firmware this is expected — otherwise something may be intercepting the connection." Options: view both fingerprints side by side, re-pin, or cancel. Never auto-accept. |
| Expired self-signed certificate | Accepted **if** the SPKI pin matches (cameras' clocks are famously wrong), with a note. Reported in the inspector. |
| Certificate from a real CA | Validated normally; no pin needed. |
| TLS version | TLS 1.2 minimum (`tls_protocol_version_t.TLSv12`); TLS 1.0/1.1 refused with a clear message naming the camera's firmware as the problem. |
| RTSPS (RTSP over TLS) | Supported on port 322/554-TLS with the same pinning rules. |

Every camera row and the inspector show a connection-security chip: **HTTPS pinned** (green lock),
**HTTPS unverified** (amber), **HTTP** (grey open lock, tooltip "Anyone on your network could read
this camera's login"). Silence about an unencrypted connection is a defect.

### 20.6 What we log, and what we redact

All logging goes through `LoggerProtocol` (injected into pure targets, OSLog-backed on macOS) and
every value passes through `Redact` in **VigilProtocols** — one pure, Linux-tested implementation, no
per-site judgement calls.

| Data | Treatment | Example in a log |
|---|---|---|
| Password | **Never logged in any form**, not even a length or a hash | — |
| `Authorization` / `WWW-Authenticate` response value | Value elided; the scheme and realm are kept | `Authorization: Digest <elided>` |
| Digest `nonce`, `cnonce`, `opaque`, `response` | Elided | `nonce=<elided>` |
| RTSP `Session` id | Replaced by a stable 4-hex FNV-1a tag | `Session: sess#7f3a (timeout=60)` |
| Camera serial number | Last 4 characters only | `serial=••••••••4C21` |
| Device MAC | Last 2 octets only | `mac=••:••:••:••:1a:7f` |
| Hostname / IP | **Kept** in local logs (they are LAN addresses and are needed to diagnose); **pseudonymized** in the diagnostics bundle unless the user opts in | local: `192.168.1.64`; bundle: `cam-3f9c` |
| URL userinfo | Stripped before the URL is stored, logged or displayed | `rtsp://192.168.1.64:554/Streaming/Channels/101` |
| Camera name | Kept (user-chosen, and the whole point of a readable log) | `[Front Door]` |
| ISAPI request/response bodies | `debug` level only; `<password>`, `<macAddress>`, `<serialNumber>`, `<challenge>`, `<salt>`, `<iv>`, `<securityVer*>`, `<sessionID>` element contents replaced with `<redacted/>`; unknown elements kept | — |
| SDP | Kept in full (no secrets, and essential for diagnosis) | — |
| RTP payload / decoded frames / audio | **Never logged.** Headers only, and only at `debug` | `RTP seq=41822 ts=3204195840 m=1 pt=96 len=1412` |
| Snapshot and clip file paths | Kept locally; the home directory is replaced by `~` in the bundle | `~/Movies/Vigil/Front Door-….mp4` |
| Keychain item data | Never; only the `OSStatus` and the item's non-secret attributes | `SecItemCopyMatching → errSecItemNotFound` |
| Passphrases (`F-DAT-02`) | Never, and never their length | — |

Additional rules:
- OSLog categories are fixed (`app`, `discovery`, `rtsp`, `rtp`, `bitstream`, `decode`, `render`,
  `isapi`, `events`, `record`, `playback`, `health`, `store`, `security`) and every message uses a
  static format string with typed interpolation, so nothing leaks through `%@` of an arbitrary
  object. Dynamic values that could contain user content are marked `privacy: .private` (and
  `.public` only where the value is provably non-sensitive, e.g. an enum case or a numeric metric).
- Levels: `error` = user-visible failure; `default`/`notice` = state transitions; `info` = per-request
  detail; `debug` = wire-level, off by default, self-disabling after 30 minutes so a user who turns
  on verbose logging to debug something doesn't leave it on for a year.
- A `Redact` fuzz test generates strings containing seeded secrets in a variety of encodings and
  asserts none survives any log-formatting path.

### 20.7 Sandboxing, entitlements and permissions
- The app runs in the **App Sandbox** with `com.apple.security.network.client`,
  `com.apple.developer.networking.multicast` (for `F-STR-08`), `com.apple.security.device.audio-input`
  (for `F-AUD-02`), and `com.apple.security.files.user-selected.read-write` with security-scoped
  bookmarks for the recording and snapshot folders. No `network.server`, no
  `files.downloads.read-write`, no Apple Events, no unsigned-executable-memory, no JIT.
  ARCHITECTURE.md justifies the sandbox decision in detail; this document requires that the shipping
  build is sandboxed and hardened-runtime signed with a notarized, stapled DMG.
- Permission prompts are **lazy and explained**: local network on first scan or connect, microphone
  on first push-to-talk, notifications on first enabling of alerts, folder access on first
  recording/snapshot to a custom location. No prompt at launch. Every denial produces a specific
  recovery message with a deep link to the right System Settings pane.

### 20.8 Threat model (brief)
- **In scope:** a malicious or compromised camera on the LAN sending hostile RTSP, SDP, RTP, XML or
  discovery data. Mitigated by `F-SEC-01` (bounds-checked parsers, allocation caps, fuzzing, no XXE)
  and by the sandbox. A camera must not be able to crash Vigil, let alone execute code.
- **In scope:** a passive observer on the LAN. Mitigated by TLS where the camera supports it, by
  Digest over Basic, and by telling the user plainly when the connection is unencrypted.
- **In scope:** malicious `vigil://` links from a browser or another app. Mitigated by total parsing
  and by the confirmation requirement on capture/record actions (`F-AUT-03` criterion 4).
- **Out of scope:** an attacker with local user-account access or root on the Mac (the Keychain and
  FileVault are the boundary there); an active MITM with a valid CA certificate for a camera's name;
  the security of the cameras' own firmware.

---

## 21. Feature → module traceability

| Module | Owns / is exercised by |
|---|---|
| **VigilProtocols** | `F-CRD-02` (MD5/SHA1/SHA256), `F-SEC-01` (ByteReader/BitReader, caps), `F-SEC-02` (HostPolicy), §20.6 (`Redact`), LoggerProtocol for every area |
| **VigilRTSP** | `F-STR-01`, `F-STR-02`, `F-CRD-02`, `F-PLB-02`, `F-PLB-04`, `F-HLT-06` steps 4/6/7/8 |
| **VigilRTP** | `F-STR-05`, `F-DEC-01`, `F-DEC-02`, `F-DEC-03`, `F-AUD-01`, `F-HLT-01`, `F-REC-02` |
| **VigilBitstream** | `F-DEC-01`, `F-DEC-02`, `F-DEC-03`, `F-REC-01` (format descriptions), `F-PLB-02` (trick modes) |
| **VigilISAPI** | `F-INV-03`, `F-DSC-05`, `F-DSC-06`, `F-DSC-07`, `F-CRD-03`, `F-DEC-05`, `F-AUD-02`, all `F-PTZ-*`, `F-IMG-01`, `F-CAP-01`, `F-PLB-01`, `F-EVT-01`, `F-HLT-06` |
| **VigilDiscovery** | `F-DSC-01`, `F-DSC-02`, `F-DSC-03`, `F-DSC-04`, `F-HLT-05` (MAC re-find) |
| **VigilTransport** | `F-STR-03`, `F-STR-04`, `F-STR-08`, `F-DSC-01/02/03` sockets, `F-HLT-05`, `F-SEC-02`, §20.5 TLS pinning |
| **VigilVideo** | `F-DEC-01/02/03/04`, `F-AUD-01`, `F-AUD-02` (capture), `F-REC-01`, `F-PLB-02`, `F-CAP-01` |
| **VigilRender** | `F-REN-01`, `F-REN-02`, `F-LIV-05`, `F-LIV-08`, `F-IMG-02`, `F-CAP-01` ("as displayed"), `F-PTZ-04` (coordinate mapping) |
| **VigilCore** | `F-INV-01/02`, `F-CRD-01/03`, `F-STR-06/07`, `F-DEC-06`, `F-REC-01/02/03`, `F-CAP-01/02`, `F-PLB-01/05/06`, `F-EVT-01/02/03`, `F-HLT-01..06`, `F-DAT-01/02/03`, `F-AUT-03/04` |
| **VigilUI** | every `F-LIV-*`, `F-AUT-01/02`, `F-PLT-01..05`, all inspector/settings/feed/timeline surfaces |
| **Vigil (exe)** | `F-AUT-03`, `F-AUT-04`, `F-AUT-05`, `F-PLT-01`, lifecycle notifications for `F-HLT-05` |

---

## 22. Release checklist (G3 / 1.0)

**Automated (must be green in CI):**
1. All unit tests pass on macOS **and** the pure-target subset passes on Linux Swift 6.1.
2. Fuzz campaign (`F-SEC-01`) green: 1 M inputs per parser, zero crashes/hangs.
3. Leak tests green: 500 reconnect cycles, 200 decoder start/stops, 100 discovery cycles — all
   return to baseline FD / task / VT-session / RSS counts.
4. Performance baselines within 10 % (§19.5 item 6).
5. Secret-absence test (§20.2) and zero-egress test (§20.3) green.
6. Localization parity, no-literal-strings, and accessibility-label lints green.
7. No `!`, `try!`, `as!` outside tests; 110-column limit; every public API documented.

**Manual (scripted, both reference machines):**
8. Six reference devices (C1–C6): add, live, snapshot, record, playback, PTZ where applicable.
9. Physical glass-to-glass rig measurements for L4–L8, photos attached.
10. 16-stream 8-hour soak inside the §19.2 R5 budget; 24-hour soak for R12.
11. Camera reboot loop ×20 (`F-HLT-05` criterion 5); sleep/wake ×10; Wi-Fi↔Ethernet switch ×5;
    display plug/unplug ×5 with the video wall open.
12. Stream Doctor against all six seeded faults plus one real misconfigured camera.
13. Full VoiceOver pass with the screen off (`F-PLT-05` criterion 6).
14. Full pass in Russian and under `--pseudo-loc`; full pass in Light and Dark with Increase
    Contrast, Reduce Transparency, Reduce Motion and Differentiate Without Color each enabled.
15. Packet capture confirming LAN-only egress (§20.3).
16. Diagnostics bundle inspected by hand for leaked secrets; encrypted-backup round trip on a clean
    Mac.
17. Recorded and exported files verified in QuickTime Player, Quick Look and VLC for H.264 and H.265,
    MP4 and MOV.
18. Sandboxed, hardened, notarized, stapled build launches on a clean macOS 14.0 machine with no
    developer tools installed.

