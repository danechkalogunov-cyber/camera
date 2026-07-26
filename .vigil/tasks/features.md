# ASSIGNMENT: features

AGENT_LABEL for your log lines is: spec:features
Write the file: /home/user/camera/docs/FEATURES.md

Author the complete, prioritized feature specification for Vigil - the definitive scope document.
Structure it as P0 (must ship), P1 (ship if time) and P2 (future). Be generous but honest about
P0, because the customer explicitly asked for deep, complete, fully worked-out functionality.
For every feature give: a one-line description, testable acceptance criteria, the modules it
touches, and the risk.
Cover at minimum: multi-camera live view with all layout modes; automatic and manual camera
discovery with an activation warning; secure credential storage; H.264, H.265 and MJPEG support;
TCP and UDP RTSP transports; main/sub stream switching driven automatically by tile size;
hardware-accelerated decode with a visible indicator; audio playback with per-camera mute plus
two-way audio push-to-talk; digital zoom and pan; full PTZ (continuous, presets, patrols,
3D-positioning drag, focus, iris, speed control); snapshots (single and all cameras) with
configurable format and destination plus copy-to-clipboard; manual recording to MP4 with
passthrough muxing and a configurable pre-roll buffer; motion-triggered local recording;
NVR/DVR channel enumeration; recorded-video search and timeline playback with speed control and
clip export; synchronized multi-camera playback; the event/alarm stream with notifications and an
event feed; image settings control; camera health monitoring (fps, bitrate, loss, jitter, latency,
uptime) with history graphs and alerting on stream loss; auto-reconnect with backoff;
network-change and sleep/wake resilience; layouts saved as named presets; camera groups; a camera
cycling view; a second-display video wall; picture-in-picture; a menu-bar extra with quick access
and a live badge; the command palette; global keyboard shortcuts; deep links using a vigil URL
scheme; AppleScript and Shortcuts automation via App Intents; CSV and JSON import/export of camera
configuration; encrypted config export; a diagnostics-bundle export; localization scaffolding for
English and Russian with the Russian strings actually written; light/dark/auto appearance; full
accessibility (keyboard and VoiceOver); crash-free reconnect after a camera reboot; an ONVIF
fallback for non-Hikvision devices; and an in-app "Stream Doctor" that diagnoses why a camera will
not connect (port closed, auth failure, unsupported codec, wrong RTSP path, multicast blocked)
with actionable fixes.
Add a **Non-goals** section (cloud, P2P / Hik-Connect, mobile, transcoding server, face
recognition) and say why.
Add a **Performance budget** section with hard numbers (cold launch to first frame, glass-to-glass
latency by transport, CPU/GPU/memory per stream and for 16 streams, UI frame time p99, memory
ceiling, energy impact) and exactly how each is measured.
Add a **Security and privacy** section: credentials in Keychain only and never in the config JSON;
no telemetry; LAN-only outbound traffic; how we handle plain http and self-signed TLS; and what we
log versus redact (mask passwords, session ids and camera serials in logs).

Create parent directories if needed. Be exhaustive and concrete.
