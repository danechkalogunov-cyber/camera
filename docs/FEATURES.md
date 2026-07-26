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

<!-- PART2 -->
