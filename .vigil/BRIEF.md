# PROJECT CONTEXT (read fully - you are one of many parallel authors)

We are building **Vigil** - a native macOS application for viewing Hikvision IP cameras and NVRs
on a local network.

Repo root: /home/user/camera  (currently EMPTY except .git and docs/ - you are creating it from scratch)

## Hard technical constraints (non-negotiable)
- Language: **Swift 6**, strict concurrency. Target **macOS 14.0+** (Sonoma).
  UI in **SwiftUI** with AppKit interop (NSViewRepresentable) where needed.
- **ZERO external dependencies.** No SPM packages, no CocoaPods, no FFmpeg, no VLCKit, no GStreamer.
  Only Apple system frameworks: Foundation, Network, SwiftUI, AppKit, AVFoundation, VideoToolbox,
  CoreMedia, CoreVideo, Metal, MetalKit, CoreImage, AudioToolbox, Security (Keychain), OSLog,
  Observation, Accelerate, UserNotifications, UniformTypeIdentifiers, AppIntents.
  Rationale: must build on any Mac with Xcode, no network fetch, and we need total control of latency.
- Therefore **we implement RTSP + RTP + SDP + H.264/H.265 bitstream handling ourselves in pure Swift**,
  feeding VideoToolbox for hardware decode and AVSampleBufferDisplayLayer / Metal for display.
- **Layering rule that MATTERS:** all protocol and parsing logic (RTSP messages, SDP, RTP
  depacketization, NAL/bitstream parsing, ISAPI XML, discovery packet codecs, jitter-buffer math)
  lives in **platform-independent, Foundation-only** targets so they compile and unit-test on
  **Linux Swift 6.1** too - we actually run those tests in CI on Linux. Anything touching
  VideoToolbox / AppKit / SwiftUI / Metal / Security / Network lives in separate macOS-only targets.
  The pure layer must NOT use CoreMedia types (no CMTime, no CVPixelBuffer); it uses our own value
  types (MediaTimestamp, EncodedFrame) at the boundary.
- Build: **Swift Package Manager** package at repo root, plus a script that assembles a real
  Vigil.app bundle, plus an XcodeGen project.yml for people who want an Xcode project.
  No hand-written .pbxproj.

## Module targets (fixed names - use these exactly)
Platform-independent (Foundation only, Linux-testable):
- VigilProtocols  - shared value types, errors, logging protocol, byte reader/writer, bit reader.
- VigilRTSP       - RTSP message model + parser/serializer, Digest/Basic auth, SDP parser,
                    RTSP session state machine (transport-agnostic: driven by injected bytes + clock).
- VigilRTP        - RTP/RTCP parsing, H.264 (RFC 6184) + H.265 (RFC 7798) + AAC (RFC 3640) + G.711
                    depacketizers, jitter/reorder buffer, framerate and bitrate statistics.
- VigilBitstream  - Annex-B <-> length-prefixed conversion, SPS/PPS/VPS parsing (H.264 + H.265),
                    resolution/fps/profile extraction, avcC/hvcC record building.
- VigilISAPI      - Hikvision ISAPI request builders + lenient XML response parsers.
                    URLSession IS available on Linux Foundation, so URLSession is allowed here.
- VigilDiscovery  - SADP + ONVIF WS-Discovery packet encode/decode, CIDR/subnet enumeration math.
macOS-only:
- VigilTransport  - Network.framework TCP/UDP transports wiring the pure state machines to real
                    sockets, TLS, keepalive timers, multicast.
- VigilVideo      - VideoToolbox decode sessions, CMFormatDescription/CMSampleBuffer construction,
                    frame pacing, decode-budget scheduler, HEVC/H.264 HW decode, audio playback.
- VigilRender     - AVSampleBufferDisplayLayer view + Metal renderer (zoom/pan/digital-PTZ, colour
                    adjust, overlays, cropping), NSViewRepresentable wrappers.
- VigilCore       - app domain: camera model, Keychain credentials, stream controller/coordinator,
                    recording (AVAssetWriter passthrough), snapshots, event centre, persistence.
- VigilUI         - design system + all SwiftUI views and components.
- Vigil           - executable target (@main App, menu bar, window management).

## Product bar
The design must feel like a **top-tier, award-winning Mac app**. Reference class: Raycast, Linear,
Arc, Craft, CleanShot X, Things 3. Translucent materials, precise typography, restrained but
delightful spring motion, keyboard-first, zero jank at 120 Hz. Functionality must be deep and
complete, not a demo. Performance target: under 250 ms glass-to-glass latency on LAN; 16 simultaneous
1080p substreams under about 35% CPU on Apple silicon via hardware decode and zero-copy paths.

## YOUR JOB
Write ONE markdown document (path given in your assignment) precise enough for an implementation
agent to code from **without further research**. Be concrete: real wire formats, real byte offsets,
real Apple API names and signatures, real numbers. Include Swift signatures and snippets where they
pin down a decision. No hand-waving, no TODO, no "we could consider". Make decisions.
Aim for a dense, long, complete document. Use tables and code blocks.
Write the file with the Write tool. Then return a summary of at most 12 lines listing the key
cross-cutting decisions OTHER agents must respect (this summary is fed to the contract author).
Do NOT write any Swift source files - only your one markdown document.

## MANDATORY PROGRESS LOGGING (you will be judged on this)
You MUST append progress lines to the shared build log so the supervisor can follow you live.
Use exactly this Bash form (single line, append only, never overwrite, never read the whole file):

    echo "[$(date -u +%H:%M:%S)] AGENT_LABEL | <stage> | <short message>" >> /home/user/camera/.build-progress.log

Log at these five moments, minimum:
  1. START      right after you read this assignment ("started, plan: ...")
  2. RESEARCH   when you have finished deciding structure ("outline done, N sections")
  3. HALFWAY    when roughly half the document is written ("wrote sections 1-N")
  4. WRITTEN    immediately after the Write tool succeeds ("wrote <path>, <bytes> bytes")
  5. DONE       last action before returning ("done, key decisions: ...")
Keep each line under 160 characters. Never put newlines inside a log line.
Replace AGENT_LABEL with the label given in your assignment header.