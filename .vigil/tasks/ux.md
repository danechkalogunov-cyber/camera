# ASSIGNMENT: ux

AGENT_LABEL for your log lines is: spec:ux
Write the file: /home/user/camera/docs/UX.md

Author the UX, information-architecture and interaction specification for Vigil.
Cover:
- **App structure**: a single main window with three regions (sidebar / stage / inspector), plus
  auxiliary windows (Settings, Discovery, Playback, Video Wall on a second display, About).
  Specify the SwiftUI WindowGroup / Window / Settings scenes, window sizing and restoration, and
  the NavigationSplitView configuration.
- **Sidebar**: sections (Live, Groups, Cameras, Recordings, Events, Bookmarks); each camera row
  shows a live micro-thumbnail, name, a status dot (connecting / live / degraded / offline), a
  codec and resolution badge, and a motion-activity spark; drag to reorder and to group; a
  context menu; inline rename; search and filter; and collapse to an icon-only rail.
- **Stage**: layout modes 1, 2x2, 1+5, 3x3, 4x4, 1+7, 2+8 and a custom drag-resizable mosaic;
  per-cell camera assignment by drag and drop; a cycle/patrol mode that rotates cameras on a
  timer; fullscreen single camera; picture-in-picture; a second-display video wall; per-tile hover
  chrome (mute, snapshot, record, PTZ, fullscreen, substream/mainstream toggle, aspect fit or
  fill, close); double-click to zoom; scroll to digital-zoom; and keyboard navigation between
  tiles.
- **Inspector** (right panel) tabs: Info (device, firmware, serial, uptime, storage); Stream
  (codec, resolution, fps, bitrate live sparklines, packet loss, jitter, decode queue, latency
  estimate, hardware-decode indicator); PTZ (pad, zoom/focus/iris, a presets grid with thumbnails,
  patrols, home); Image (brightness, contrast, saturation, sharpness, WDR, day/night, IR);
  Events (recent motion list with thumbnails); Recording (schedule and storage).
- **Playback**: a dedicated timeline experience - a date picker plus a 24-hour horizontal timeline
  per camera with a recording-density heatmap (motion amber, continuous blue, alarm red);
  pinch or scroll to zoom the timeline from 24 hours down to one minute; drag to scrub with live
  preview thumbnails; transport controls (play/pause, minus and plus 10 s, frame step, speed
  0.25x to 8x, reverse); multi-camera synchronized playback; in and out point selection with clip
  export as MP4 passthrough; and an instant "go to this moment" jump from an event.
- **Discovery / add camera**: the onboarding flow - a scan animation with devices appearing, a
  manual-add form (host, ports, credentials, channel, transport), a credential test with clear
  distinct failure reasons (wrong password vs locked out vs unreachable vs not-Hikvision), an
  auto-detected channel list for NVRs with checkboxes, bulk add, and CSV import.
- **Events**: a unified event feed (motion, line crossing, intrusion, tamper, video loss, disk
  error) with thumbnails, filters and click-to-playback; local notifications; and a watch mode
  that raises a toast or overlay on motion.
- **Command palette (Cmd-K)**: fuzzy actions - jump to camera, switch layout, start/stop
  recording, snapshot all, PTZ preset, open settings, toggle audio. Specify the ranking algorithm
  and the anatomy of a result row.
- **Keyboard shortcuts**: a COMPLETE table (Cmd-1..9 layouts, Cmd-F fullscreen, Space play/pause,
  Cmd-R record, Cmd-Shift-S snapshot, Cmd-K palette, Cmd-L sidebar, Cmd-Opt-I inspector, arrows
  PTZ, Opt-arrows tile navigation, Cmd-comma settings, Cmd-E export, slash search, Esc exit,
  Cmd-Ctrl-F cinema) plus the menu-bar structure (App, File, View, Camera, Playback, Window,
  Help) mirroring every one of them.
- **States**: first run, no cameras, scanning, connecting (skeleton plus progress narration),
  degraded (packet-loss banner), offline (retry countdown with the last-known frame dimmed), auth
  failure, storage full, app in background, and sleep/wake plus network-change recovery.
- **Settings**: General (launch at login, appearance, units, time format); Streams (default
  transport TCP or UDP, substream in grid, latency preset low/balanced/quality, hardware decode
  toggle, max concurrent decodes); Recording (folder, format, pre and post buffer, auto-record on
  motion, retention); Notifications; Shortcuts (rebindable); Advanced (log level, export
  diagnostics, reset); About and updates.
- **Copy and tone**: the writing rules, plus the exact strings for the 20 most important messages
  (errors, empty states, confirmations) - concise, human, no jargon dumps. Give them in English,
  and note that a Russian localization is required so keys must be structured for it.
- **Latency-perception rules**: exactly what we show in the first 100 ms, 300 ms and 1000 ms of a
  connection so it always feels instant; and optimistic UI for PTZ and settings changes.
Include ASCII wireframes for the main window, the playback view and the discovery sheet.

Create parent directories if needed. Be exhaustive and concrete.
