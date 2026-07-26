# ASSIGNMENT: core

AGENT_LABEL for your log lines is: spec:core
Write the file: /home/user/camera/docs/spec-core.md

Author the application-domain specification (module VigilCore) - the layer between the protocol
modules and the UI. Give complete public Swift API signatures for every type.
Cover:
- **Domain model**: Camera (id UUID, name, host, httpPort, rtspPort, useTLS, channel,
  streamProfile, transport, credentialRef, groupID, orderIndex, capabilities snapshot, createdAt,
  lastSeenAt, colorTag, isEnabled), CameraGroup, Layout (mode plus a cell-to-camera map),
  Bookmark, EventRecord, RecordingClip, DeviceCapabilities, StreamProfile (main/sub/third with
  resolved codec, resolution, fps, bitrate). All Sendable and Codable with stable coding keys and
  a schemaVersion.
- **Persistence**: ConfigStore - a single JSON document at
  ~/Library/Application Support/Vigil/library.json, atomic write via a temp file and
  FileManager.replaceItemAt, debounced saves coalescing over 500 ms, .bak rotation, a schema
  migration chain, and corruption recovery. Justify why not SwiftData or CoreData (predictable,
  diffable, exportable, no store-migration risk) and state what we would change past 10k records.
- **Credentials**: CredentialStore on the Keychain - kSecClassInternetPassword with server, port,
  account and path attributes, kSecAttrAccessibleWhenUnlocked, exact SecItemAdd / SecItemCopyMatching
  / SecItemUpdate / SecItemDelete code with OSStatus error mapping, an in-memory cache, a Sendable
  Credential value type, and the hard rule that credentials never enter logs or the JSON.
- **StreamController** (one per active camera): an actor owning the RTSP session, depacketizer and
  decode pipeline. Public API: start, stop, setQuality(main/sub/auto), requestKeyframe,
  snapshot() async throws, startRecording, and an AsyncStream of StreamEvent. Give the internal
  state machine (idle, resolving, connecting, authenticating, describing, settingUp, playing,
  degraded, reconnecting, failed, stopped) with the FULL transition table, per-state timeouts, and
  the reconnect policy (backoff 0.5, 1, 2, 4, 8, 15, 30 s capped, plus or minus 20% jitter, reset
  after 60 s of health, immediate retry when the network comes back).
- **StreamCoordinator**: app-wide orchestration - which cameras are live given the current layout,
  the decode-budget admission policy, priority ordering (focused, then visible, then offscreen,
  then sidebar thumbnail), pause-on-occlusion, resume-on-wake, an NWPathMonitor reaction, and a
  global concurrency limiter. Give the exact policy table mapping tile pixel size to
  main / sub / JPEG-poll / paused.
- **Recording**: ClipRecorder using AVAssetWriter with an AVAssetWriterInput created with nil
  output settings and a sourceFormatHint, for **passthrough** muxing of already-compressed samples
  into MP4 or MOV with no re-encode. Handle the first-sample-must-be-a-keyframe rule, a pre-roll
  ring buffer holding the last N seconds of compressed GOPs, timestamp rebasing so the file starts
  at zero, audio track inclusion, a file-naming template, disk-space checks, graceful finish on
  quit or crash (write to .partial then rename), and MP4 fragmentation for crash resilience.
- **Snapshots**: from the render pipeline (the exact displayed frame) or via ISAPI JPEG (cheap);
  PNG, JPEG and HEIC; EXIF metadata stamping with camera name and timestamp; an optional burn-in
  overlay; and destinations including the clipboard and Quick Look.
- **Events**: EventCenter consuming the ISAPI alertStream per device, dedupe and coalesce (same
  eventType plus channel within 3 s), persistence of the last 5000 events, UNUserNotificationCenter
  local notifications with a thumbnail attachment, and the motion-to-auto-record trigger with a
  cooldown.
- **Health and diagnostics**: HealthMonitor sampling each StreamController at 1 Hz into a
  fixed-size 10-minute ring for the UI sparklines; the **Stream Doctor** diagnostic sequence
  (TCP probe of 554 and 80, then RTSP OPTIONS, then DESCRIBE with auth, then an SDP codec check,
  then a first-RTP-packet timeout, then a first-keyframe timeout) with the mapping from each
  failure point to a user-facing cause and fix; and the diagnostics bundle contents (redacted
  logs, config without secrets, SDP dumps, a stats CSV).
- **App Intents, deep links and AppleScript**: the intent surface and the URL-scheme grammar.
- The list of unit tests, with fakes for RTSP and ISAPI, that must accompany all of the above.

Create parent directories if needed. Be exhaustive and concrete.
