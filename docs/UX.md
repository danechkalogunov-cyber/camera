# Vigil — UX, Information Architecture & Interaction Specification

Status: **normative**. Owner: `spec:ux`. Consumers: `VigilUI`, `Vigil` (executable), and every
module that surfaces state to a human.

## 0. How to read this document

| This document owns | This document defers to |
|---|---|
| Scene graph, window identities, sizing, restoration | `docs/DESIGN.md` for every colour, font, radius, shadow and spring value (`VTheme.*`) |
| Navigation model, selection & focus semantics | `docs/DESIGN.md` for component visual specs (`VButton`, `VTile`, `VTimeline`, …) |
| Layout mode geometry, tile chrome inventory, gestures at the UI level | `docs/spec-render.md` for on-video gesture *implementation* (Metal transforms, hit-testing, cursors) |
| Sidebar / Inspector / Playback / Discovery / Events / Palette information architecture | `docs/spec-core.md` for `Camera`, `EventRecord`, `StreamEvent`, `ConfigStore`, `HealthMonitor`, backoff policy |
| Keyboard map, menu bar, command palette ranking | `docs/FEATURES.md` for scope priority (P0/P1/P2) |
| Every user-visible string, its key, and its tone | `docs/spec-isapi.md` for the device fields the Inspector shows |
| Latency-perception choreography and optimistic-UI rules | `docs/spec-video.md` for what a "first frame" event actually is |

Hard rules that apply to this whole document:

1. **The video is the hero.** Chrome is transient. No control may permanently cover video except
   the 1px tile border and the name chip (which is dismissible via View ▸ Tile Overlays).
2. **Nothing in the UI ever blocks on the network.** Every affordance renders from local state
   within one frame (8.3 ms at 120 Hz) and reconciles asynchronously (§16).
3. **No layout reflow after content arrives.** Sizes are committed before the first byte
   (§16.1). A tile that becomes live must not move, resize, or re-letterbox.
4. **Keyboard-first.** Every action in §12 is reachable without the mouse and appears in the menu
   bar. Anything reachable only by hover is a bug.
5. **Strings are keys.** No literal user-facing string in Swift source; all strings come from
   `Localizable.xcstrings` with the key structure of §15.

---

## 1. Information architecture

### 1.1 Object model as the user sees it

```
Library (one per user, ~/Library/Application Support/Vigil/library.json)
├── Camera*            the atomic unit; belongs to 0..1 Group
│   ├── Stream         main / sub / third   (a property, never a separate object in the UI)
│   ├── Event*         motion, line-crossing, intrusion, tamper, video-loss, disk-error
│   ├── Recording*     clips on the device (searched) + local clips (produced by us)
│   └── Preset*        PTZ presets, patrols  (device-owned, cached)
├── Group*             user-made folder; a Group can be opened into the Stage as a set
├── Layout*            a mode + cell→camera map; savable as a named preset
└── Bookmark*          (cameraID, instant, title, colour) — a pin on the playback timeline
```

Rules:

- A camera exists in exactly one place in the data model and is *referenced* everywhere else.
  Deleting a camera from **Cameras** deletes it everywhere (destructive confirm, §15 key
  `confirm.deleteCamera.*`). Removing it from **Live** only clears a Stage cell.
- **Live** is not a container of cameras; it is a view of the *current Layout*. Dragging a camera
  to Live assigns it to the first empty cell (or replaces the focused cell if none is empty).
- Groups are flat (no nesting) in P0. A camera dragged onto a Group row joins that group and keeps
  its `orderIndex` within it.

### 1.2 Surfaces

| Surface | Scene id | Multiplicity | Purpose |
|---|---|---|---|
| Main window | `main` | 1 (singleton) | Live viewing: Sidebar + Stage + Inspector |
| Playback | `playback` | N (one per camera set) | Timeline review & export |
| Discovery | `discovery` | 1 | Find / add cameras |
| Video Wall | `wall` | 1 | Full-bleed grid on a secondary display |
| Settings | `Settings` scene | 1 | Preferences, 7 panes |
| About | `about` | 1 | Version, credits, licences |
| Menu-bar extra | `MenuBarExtra` | 1 | Status glance + 6 quick actions |
| Command palette | overlay inside `main`/`playback` | 1 per window | Everything, by typing |

**Decision — the palette is an in-window overlay, not a window.** It is a `ZStack` layer inside the
hosting window so that (a) it inherits the window's camera/selection context, (b) it can never be
orphaned behind another app, (c) `Esc` and click-outside dismissal are trivial, (d) the backdrop
blur can sample the actual window content. A floating `NSPanel` was rejected: it steals key window
status and breaks `@FocusedValue` menu enablement.

### 1.3 Navigation state (single source of truth)

```swift
// VigilUI/State/AppModel.swift
@MainActor @Observable
public final class AppModel {
    // Sidebar
    public var sidebarSelection: SidebarSelection = .live
    public var sidebarVisibility: NavigationSplitViewVisibility = .all
    public var sidebarIsRail: Bool = false          // icon-only 68pt rail
    public var searchText: String = ""
    public var sidebarFilter: SidebarFilter = .all  // all / live / offline / recording / motion24h

    // Stage
    public var layout: LayoutState                  // mode + cells + custom mosaic geometry
    public var focusedCell: Int? = 0                // index into layout.cells; drives menus & PTZ
    public var fullscreenCell: Int? = nil           // in-window "solo", not macOS full screen
    public var cinema: Bool = false                 // window is in macOS full screen, chrome hidden
    public var patrol: PatrolState = .off           // cycle mode

    // Inspector
    public var inspectorIsPresented: Bool = true
    public var inspectorTab: InspectorTab = .info

    // Transient UI
    public var palette: PaletteState = .closed
    public var toasts: ToastQueue = .init()
    public var watchMode: WatchMode = .toast        // off / toast / overlay
}

public enum SidebarSelection: Hashable, Codable, Sendable {
    case live
    case group(CameraGroup.ID)
    case camera(Camera.ID)
    case recordings
    case events
    case bookmarks
}

public enum InspectorTab: String, CaseIterable, Codable, Sendable {
    case info, stream, ptz, image, events, recording
}
```

`AppModel` is a **@MainActor @Observable class injected via `.environment(appModel)`** — not
`@EnvironmentObject`, not a global singleton. `VigilCore` types (`StreamCoordinator`,
`EventCenter`, `ConfigStore`) are injected the same way. Views never construct actors.

### 1.4 Where each piece of state lives

| State | Home | Survives quit | Notes |
|---|---|---|---|
| Camera library, groups, layout presets, bookmarks | `ConfigStore` (`library.json`) | ✅ | debounced 500 ms |
| Credentials | Keychain | ✅ | never in JSON, never in logs |
| Current layout mode + cell map | `ConfigStore` (`library.lastLayout`) | ✅ | restored on launch |
| Sidebar visibility / rail / width, inspector visibility + tab | `@SceneStorage` per window | ✅ | per-window, not global |
| Window frames | AppKit autosave (`NSWindow.setFrameAutosaveName`) via scene id | ✅ | see §2.4 |
| Search text, filter, palette query, toasts, focus | in-memory `AppModel` | ❌ | intentionally volatile |
| Preferences (§14) | `UserDefaults` (`@AppStorage`, suite `com.vigil.app`) | ✅ | exported by diagnostics, redacted |
| Shortcut overrides | `UserDefaults` key `shortcuts.overrides` (JSON) | ✅ | §12.4 |
| Playback window scrub position | `@SceneStorage` per playback window | ✅ | restores to the same instant |

---

## 2. Scenes, windows, sizing, restoration

### 2.1 The scene graph

```swift
// Vigil/VigilApp.swift
@main
struct VigilApp: App {
    @State private var env = AppEnvironment.bootstrap()   // ConfigStore, Coordinator, EventCenter
    @State private var app = AppModel.restored()

    var body: some Scene {
        // ── 1. Main window: singleton, hidden title bar, unified toolbar ──────────
        Window("Vigil", id: SceneID.main) {
            MainWindowView()
                .environment(app)
                .environment(env)
                .frame(minWidth: 960, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1440, height: 900)
        .defaultPosition(.center)
        .windowResizability(.contentMinSize)
        .commands { VigilCommands(app: app, env: env) }   // §12.3

        // ── 2. Playback: value-driven WindowGroup, one window per request ─────────
        WindowGroup(id: SceneID.playback, for: PlaybackRequest.self) { $request in
            PlaybackWindowView(request: request ?? .empty)
                .environment(app).environment(env)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1280, height: 760)
        .windowResizability(.contentMinSize)
        .defaultPosition(.topTrailing)

        // ── 3. Discovery: singleton utility window ───────────────────────────────
        Window("Add Cameras", id: SceneID.discovery) {
            DiscoveryRootView(presentation: .window)
                .environment(app).environment(env)
                .frame(minWidth: 720, minHeight: 520)
        }
        .defaultSize(width: 780, height: 600)
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)

        // ── 4. Video wall: singleton, borderless-feeling, targets a chosen screen ─
        Window("Video Wall", id: SceneID.wall) {
            VideoWallView()
                .environment(app).environment(env)
                .ignoresSafeArea()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1920, height: 1080)

        // ── 5. About: content-sized, non-resizable ───────────────────────────────
        Window("About Vigil", id: SceneID.about) {
            AboutView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        // ── 6. Settings: standard macOS preferences scene ────────────────────────
        Settings {
            SettingsView().environment(app).environment(env)
        }

        // ── 7. Menu-bar extra ────────────────────────────────────────────────────
        MenuBarExtra("Vigil", systemImage: "video.badge.waveform") {
            MenuBarExtraContent().environment(app).environment(env)
        }
        .menuBarExtraStyle(.window)                     // rich content, not an NSMenu
    }
}

public enum SceneID {
    public static let main = "main"
    public static let playback = "playback"
    public static let discovery = "discovery"
    public static let wall = "wall"
    public static let about = "about"
}

/// Payload for the playback WindowGroup. Codable+Hashable is required by `WindowGroup(for:)`.
public struct PlaybackRequest: Codable, Hashable, Sendable {
    public var cameraIDs: [Camera.ID]      // 1 = single, 2..4 = synchronized multi-cam
    public var focus: Date?                // "go to this moment" from an event
    public var day: Date                   // the calendar day being reviewed (local)
    public static let empty = PlaybackRequest(cameraIDs: [], focus: nil, day: .now)
}
```

Opening windows from anywhere:

```swift
@Environment(\.openWindow) private var openWindow
openWindow(id: SceneID.discovery)
openWindow(id: SceneID.playback, value: PlaybackRequest(cameraIDs: [cam.id], focus: event.timestamp, day: event.timestamp))
```

### 2.2 Main window structure — `NavigationSplitView` + `.inspector`

**Decision.** Two-column `NavigationSplitView` (sidebar + detail) with the Inspector supplied by the
macOS 14 `.inspector(isPresented:)` modifier on the detail column. A three-column
`NavigationSplitView` was rejected: its middle column carries list semantics, its collapse
behaviour at narrow widths hides the *stage* (unacceptable — the video must never be the thing that
disappears), and `.inspector` gives us the free system-standard drag-resize handle, trailing
toolbar alignment, and the ⌥⌘I-style show/hide animation.

```swift
struct MainWindowView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        NavigationSplitView(columnVisibility: Binding(
            get: { app.sidebarVisibility }, set: { app.sidebarVisibility = $0 })
        ) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 208, ideal: 264, max: 380)
        } detail: {
            StageView()
                .inspector(isPresented: Binding(
                    get: { app.inspectorIsPresented && !app.cinema },
                    set: { app.inspectorIsPresented = $0 })
                ) {
                    InspectorView()
                        .inspectorColumnWidth(min: 288, ideal: 320, max: 440)
                }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(id: "main") { MainToolbar() }          // customizable toolbar
        .overlay { CommandPaletteOverlay() }            // §11
        .overlay(alignment: .bottomTrailing) { ToastStack() }
        .background(WindowAccessor { configure($0) })   // traffic-light inset, tabbing off
    }
}
```

`configure(_ window: NSWindow)` (called once, in `viewDidMoveToWindow`):

```swift
window.tabbingMode = .disallowed          // camera windows must never become tabs
window.titlebarAppearsTransparent = true
window.isMovableByWindowBackground = false // dragging on video must pan, not move the window
window.setFrameAutosaveName("VigilMain")
window.collectionBehavior.insert(.fullScreenPrimary)
window.animationBehavior = .documentWindow
```

### 2.3 Rail mode (icon-only sidebar)

Three sidebar states, cycled by ⌘L (show/hide) and ⌥⌘L (rail):

| State | Width | Content | Trigger |
|---|---|---|---|
| `.all` full | 208–380 pt (ideal 264) | Sections, rows with thumbnail + badges | default |
| `.all` rail | 68 pt fixed | 28pt section glyphs; camera rows collapse to a 44×26 thumbnail with a status dot; name on hover in a trailing popover after 450 ms | ⌥⌘L |
| `.detailOnly` | 0 | hidden; a 12pt hot-edge on the left reveals a temporary overlay sidebar on hover-dwell 300 ms (auto-hides 600 ms after pointer exit) | ⌘L |

Rail is implemented as the same `SidebarView` with `app.sidebarIsRail == true`; rows switch to a
compact layout via a single `if` — **not** a second view hierarchy, so `matchedGeometryEffect` can
morph the thumbnail between the two widths (`VTheme.Motion.standard`).

### 2.4 Sizing & restoration matrix

| Window | Default | Min | Max | Resizability | Restored |
|---|---|---|---|---|---|
| Main | 1440×900, centred | 960×600 | — | `.contentMinSize` | frame + sidebar/inspector state + layout |
| Playback | 1280×760, top-trailing cascade +24pt | 900×560 | — | `.contentMinSize` | frame + day + scrub instant + zoom level |
| Discovery | 780×600 | 720×520 | 1100×900 | `.contentMinSize` | frame only; the flow always restarts at step 1 |
| Video Wall | fills target screen | 640×360 | — | free | target screen id + layout preset |
| Settings | content-sized per pane (see §14) | — | — | `.contentSize` | last pane (`@AppStorage("settings.lastPane")`) |
| About | 420×320 | = | = | `.contentSize` | — |

Restoration policy:

- Frames come from AppKit's autosave (SwiftUI `Window`/`WindowGroup` scenes autosave by scene id
  when `NSQuitAlwaysKeepsWindows` is true — the default). We do **not** write frames to
  `library.json`.
- If a restored frame lands off-screen (display disconnected), `NSWindow.constrainFrameRect`
  handles it; the Video Wall additionally re-resolves its target screen by
  `NSScreen.screens.first { $0.vigilID == savedID } ?? .main` and, if the saved screen is gone,
  shows the toast `wall.screenMissing.body` and reopens on the main display.
- Reopening the app with no windows (all closed, app still running) → ⌘0-free rule: clicking the
  Dock icon or `applicationShouldHandleReopen` reopens `main`.
- **Launch is never blocked by restoration**: the window renders its full chrome from
  `library.json` (already read synchronously, < 8 ms for ≤ 512 cameras) and every tile enters the
  connecting state (§16) in the same frame.

### 2.5 Cinema mode vs. tile fullscreen

Two distinct, non-overlapping concepts:

| | Tile fullscreen (⌘F) | Cinema mode (⌃⌘F) |
|---|---|---|
| Scope | one tile fills the Stage | the whole window enters macOS full screen |
| Sidebar / Inspector | unchanged | hidden (state remembered, restored on exit) |
| Toolbar / title bar | unchanged | auto-hidden; revealed by pointer within 3 pt of the top edge, or ⌥ tap |
| Transition | `matchedGeometryEffect(id: cell, in: stageNS)` + `VTheme.Motion.expressive` | native `toggleFullScreen(_:)`, chrome cross-fades over 220 ms |
| Exit | `Esc`, ⌘F, double-click | `Esc`, ⌃⌘F |
| Combines? | Yes — tile fullscreen inside cinema mode = one camera, zero chrome (the "wall of one") |

⌃⌘F is deliberately bound to the *system* Enter Full Screen action; Vigil brands that state
"Cinema". There is no separate binding, so no conflict with macOS conventions.

---

## 3. Main window anatomy

### 3.1 Wireframe

```
┌───────────────────────────────────────────────────────────────────────────────────────────────────────┐
│ ●●●   ⌕ Search cameras  (/)      [ ▣ ][ ⊞ ][ ⊟ ][ ⊠ ] Layout ▾   ⟳ Cycle  ⌘K  ⋯      [ ⇥ Inspector ] │  40pt unified toolbar
├──────────────────────┬──────────────────────────────────────────────────────────┬───────────────────┤
│ LIVE                 │ ┌────────────────────────┐┌───────────┐┌───────────┐     │ Front Door        │
│  ◉ Current Layout    │ │                        ││ ▓▓▓▓▓▓▓▓▓ ││ ░ Lobby   │     │ ● Live · H.265    │
│                      │ │                        ││ Garage    ││ connecting│     │───────────────────│
│ GROUPS            ＋ │ │   Front Door           ││ ● 25 fps  ││ ▁▂▃ 62%   │     │ Info  Stream  PTZ │
│  ▸ 🅐 Perimeter   4  │ │                        │└───────────┘└───────────┘     │ Image  Events  Rec│
│  ▸ 🅑 Indoors     3  │ │   ● REC  00:04:12      │┌───────────┐┌───────────┐     │───────────────────│
│  ▸ 🅒 Gate        2  │ │                        ││ Back Yard ││ Side Gate │     │ Codec    H.265    │
│                      │ │  [🔇][◎][●][⤢][⬍][✕]  ││ ● 20 fps  ││ ⚠ 3.1% loss│     │ Resolution 1920×  │
│ CAMERAS          ＋ │ └────────────────────────┘└───────────┘└───────────┘     │            1080   │
│  ▪ ▣ Front Door      │ ┌───────────┐┌───────────┐┌───────────┐┌───────────┐     │ Bitrate  ▁▃▅▂▁▃   │
│    ● H.265 1080p ▁▃▅ │ │ Driveway  ││ Hallway   ││ + Add     ││ + Add     │     │          4.1 Mb/s │
│  ▪ ▣ Garage          │ │ ● 25 fps  ││ ○ offline ││   camera  ││   camera  │     │ FPS      25.0     │
│    ● H.264 720p  ▁▁▂ │ └───────────┘└───────────┘└───────────┘└───────────┘     │ Loss     0.02 %   │
│  ▪ ▣ Lobby           │                                                          │ Jitter   6 ms     │
│    ◐ connecting  ▁▁▁ │  ┌────────────────────────────────────────────────────┐  │ Queue    2 frames │
│  ▪ ▣ Back Yard       │  │ ⚠ Side Gate: 3.1% packet loss — switching to TCP   │  │ Latency  186 ms   │
│    ● H.265 1080p ▃▅▇ │  └────────────────────────────────────────────────────┘  │ Decode   ⚡ HW     │
│                      │                                                          │───────────────────│
│ RECORDINGS           │                                                          │ Uptime   6d 04h   │
│ EVENTS            12 │                                                          │ Storage  ▓▓▓░ 74% │
│ BOOKMARKS            │                                                          │                   │
│                      │                                                          │                   │
│ ─────────────────    │                                                          │                   │
│ ⚙  16 live · 2.1 Gb/s│                                                          │                   │
└──────────────────────┴──────────────────────────────────────────────────────────┴───────────────────┘
  264pt sidebar          flexible stage (min 480pt)                                 320pt inspector
```

### 3.2 Toolbar inventory (`ToolbarItem` ids — user-customizable via ⌃-click ▸ Customize Toolbar…)

| id | Placement | Control | Action |
|---|---|---|---|
| `sidebar` | `.navigation` | icon `sidebar.leading` | ⌘L |
| `search` | `.navigation` | `VSearchField`, 200 pt, expands to 320 pt on focus | focus search (`/`) |
| `layoutPicker` | `.principal` | `VSegmentedControl` of 4 pinned modes + `Layout ▾` menu of all 8 + presets | §5.1 |
| `patrol` | `.primaryAction` | toggle `arrow.triangle.2.circlepath` with a dwell-time menu | §5.5 |
| `snapshotAll` | `.primaryAction` (overflow default) | `camera.on.rectangle` | ⌥⇧⌘S |
| `recordAll` | `.primaryAction` (overflow default) | `record.circle` | ⌥⌘R |
| `palette` | `.primaryAction` | `command` + "⌘K" keycap | open palette |
| `more` | `.primaryAction` | `ellipsis.circle` menu: Video Wall, PiP, Discovery, Stream Doctor, Settings | — |
| `inspector` | `.primaryAction` (trailing-most) | `sidebar.trailing` | ⌥⌘I |

Toolbar uses `.toolbar(id:)` + `ToolbarItem(id:placement:showsByDefault:)` so customization
persists automatically. In cinema mode the toolbar is present but auto-hidden (§2.5).

### 3.3 Status footer (sidebar bottom, 32 pt, always visible)

`⚙` opens Settings. Text is `"{n} live · {rate}"` with `monospacedDigit()`; `rate` is aggregate
ingest in Mb/s or Gb/s, updated at 1 Hz from `HealthMonitor`. When any camera is degraded the
footer text turns `VTheme.Color.warn` and reads `"{n} live · {m} degraded"`; ⌘-click reveals a
popover listing the degraded cameras with a "Run Stream Doctor" button.

---

## 4. Sidebar

### 4.1 Sections

`List(selection:)` in `.sidebar` style, with `Section` headers using `DisclosureGroup` for Groups.
Order is fixed; sections with no content collapse to a single muted row (never disappear — the IA
must be stable and learnable).

| # | Section | Row content | Count badge | Empty behaviour |
|---|---|---|---|---|
| 1 | **LIVE** | one row: "Current Layout" + the layout glyph; selecting it clears camera selection and focuses the Stage | — | never empty |
| 2 | **GROUPS** | disclosure rows; header has a `＋` to create a group (inline text field, default name "New Group") | member count | row "No groups — drag cameras together to make one" |
| 3 | **CAMERAS** | camera rows (§4.2), sorted by `orderIndex`; header `＋` opens the add menu (Discover…, Add Manually…, Import CSV…) | live/total | `VEmptyState` (§13.2) |
| 4 | **RECORDINGS** | one row → opens Playback for the focused camera (or the multi-select) | local clip count | "No recordings yet" |
| 5 | **EVENTS** | one row → Events feed in the Stage | unread count, accent pill, clears on view | "No events" |
| 6 | **BOOKMARKS** | expands to bookmark rows (camera colour dot + title + time) | count | "No bookmarks — press B while reviewing" |

Selecting **Recordings**, **Events** or **Bookmarks** replaces the Stage content with that
feed **inside the main window** (the Stage is a router, see §5.9); it does not open a new window.
Live video keeps running behind the feed at 0.5× thumbnail rate so returning is instant.

### 4.2 Camera row anatomy (`VSidebarRow`, 44 pt tall, 6 pt inner radius)

```
 ┌──────────────────────────────────────────────────┐
 │ ▏ ┌────────┐  Front Door                    ▁▃▅▂ │   44pt
 │ ▏ │ thumb  │  ● H.265 · 1080p                    │
 │ ▏ └────────┘                                     │
 └──────────────────────────────────────────────────┘
   │     │        │        │                     └── motion spark (40×12)
   │     │        │        └── status dot + codec/res badge (Caption2, tertiary)
   │     │        └── name (Body, primary; 1 line, truncates tail)
   │     └── live micro-thumbnail 64×36, radius 4, true black bg
   └── 3pt colour-tag bar (camera `colorTag`), full row height, radius 1.5
```

| Element | Spec |
|---|---|
| Micro-thumbnail | 64×36 pt (16:9). Source per `StreamCoordinator` policy: tiles < 160 px on the long edge use **ISAPI JPEG polling** — 1.0 Hz when the window is active, 0.25 Hz when inactive, 0 Hz when the window is occluded or the row is scrolled out of view (`onAppear`/`onDisappear` + `NSWindow.occlusionState`). If the camera is already decoding for a Stage tile, the thumbnail reuses that pipeline's latest frame instead (free). Placeholder: `VSkeleton` shimmer; offline: last-known frame at 30% opacity + 2 pt blur. |
| Status dot | 7 pt circle, 1 pt inner dark ring for contrast on vibrancy. `connecting` = amber, breathing 2 s (`.easeInOut`, opacity 0.45→1.0); `live` = green, static; `degraded` = amber, static, plus a 1 pt warn stroke on the badge; `offline` = grey, static; `authFailed` = red with a `!` glyph inside; `disabled` = hollow grey ring. `differentiateWithoutColor` adds a glyph to every state (▲ connecting, ● live, ⚠ degraded, ○ offline, ✕ auth). |
| Codec/res badge | `"H.265 · 1080p"`. Resolution is bucketed: ≤480p, 720p, 1080p, 1440p, 4K, else `"{w}×{h}"`. While connecting: `"—"`. Uses the actual negotiated stream (sub-stream shows `1080p` if that is what is playing; a `ᔆ` superscript marks sub-stream). |
| Motion spark | 40×12 pt bar sparkline, 20 buckets × 15 s = last 5 minutes of `EventCenter` motion intensity (0–1). Bars use `VTheme.Color.motion` at 0.35 + full opacity for buckets containing a confirmed event. Zero-motion rows draw a 1 pt baseline, never an empty gap. Redraws at 0.2 Hz max. |
| Recording overlay | when the camera is recording locally, a 10 pt red dot pulses at the thumbnail's top-left inset 3 pt, and the row's colour bar becomes `live` red. |
| Rail variant | 44×26 thumbnail centred, 7 pt status dot overlapping bottom-trailing, no text; name in a trailing popover after 450 ms hover. |

### 4.3 Interactions

| Gesture | Result |
|---|---|
| Click | select camera → Inspector binds to it; the Stage focuses its tile if present (no layout change) |
| Double-click | assign to the focused Stage cell (or first empty), then focus that tile |
| ⌘-click / ⇧-click | multi-select (for group ops, bulk delete, multi-cam playback) |
| Drag row → row | reorder (`orderIndex` rewrite, 250 ms debounce before persist) |
| Drag row → Group row | join group; the group row highlights with an accent 1.5 pt inset stroke and expands after 500 ms hover |
| Drag row → Stage cell | assign to that cell (drop target shows an accent inset stroke + 4% accent fill) |
| Drag row → outside window | no-op (never a file promise; use File ▸ Export Configuration) |
| Drag 2+ selected rows onto Group header `＋` | create a new group containing them, inline-rename active |
| ↩ on a selected row | begin inline rename (a `VTextField` replaces the name in place; ↩ commits, `Esc` reverts, empty name reverts, duplicate names are allowed but a "(2)" suffix is suggested) |
| ⌫ | delete with confirm (§15 `confirm.deleteCamera.*`) |
| Space | toggle enable/disable (a disabled camera is never connected; row dims to 45%) |
| `/` or ⌘F-free focus | move focus to the search field |
| ↑/↓ | move selection; ←/→ collapse/expand a Group row |
| Two-finger swipe left on a row | reveals a 64 pt "Remove from layout" action (P1) |

**Context menu** (right-click, and ⌃-click, and the `⋯` that appears on hover at the row's trailing
edge — all three produce the identical menu, built once in `CameraContextMenu`):

```
Open in Stage                    ⏎
Open in New Playback Window      ⌥⌘P
Fullscreen                       ⌘F
──────────────────────────────────
Snapshot                         ⇧⌘S
Start Recording                  ⌘R
Two-Way Audio                    ⌥T
──────────────────────────────────
Quality ▸  Auto · Main · Sub · Third
Transport ▸  Auto · TCP · UDP
Audio ▸  Mute (⌥⌘M) · Volume…
──────────────────────────────────
Rename…                          ⏎
Edit Camera…                     ⌘I
Duplicate for Another Channel…
Move to Group ▸  (groups) · New Group…  · None
Colour Tag ▸  (6 swatches + None)
──────────────────────────────────
Reconnect Now                    ⌥⌘R
Run Stream Doctor…               ⌥⌘D
Copy RTSP URL          (password redacted as ●●●)
Copy Diagnostics
──────────────────────────────────
Disable Camera                   Space
Delete Camera…                   ⌫
```

### 4.4 Search & filter

- Search matches, in priority order: name (fuzzy, §11.3 scorer), group name, host/IP (prefix),
  model, serial (exact suffix ≥ 4 chars). Results keep the section structure but hide non-matching
  rows; matched substrings highlight with `VTheme.Color.accent` at semibold.
- The field is a `VSearchField` with a leading `magnifyingglass`, a trailing filter chip
  (`line.3.horizontal.decrease.circle`) opening a menu: **All · Live only · Offline only ·
  Recording · Motion in last 24 h · Group ▸**. Active filters render as removable `VChip`s beneath
  the field (28 pt row, animates in with `VTheme.Motion.micro`).
- `Esc` in the field clears text; a second `Esc` returns focus to the Stage.
- Zero results → `VEmptyState` "No cameras match “{query}”." with buttons *Clear filters* and
  *Add camera*.
- Search is **case- and diacritic-insensitive** (`.folding(options: [.caseInsensitive,
  .diacriticInsensitive], locale: .current)`) so Cyrillic input works: `"вход"` matches `"Вход"`.

---

## 5. Stage

The Stage is the detail column. It is a **router** (§5.9) whose primary route is the live mosaic.

### 5.1 Layout modes

Eight modes, all expressed as rectangles on a **12 × 12 unit grid** so that every mode — including
the custom mosaic — uses one geometry engine and one persistence format.

```swift
public enum LayoutMode: String, Codable, CaseIterable, Sendable {
    case single, grid2x2, hero1p5, grid3x3, grid4x4, hero1p7, dual2p8, custom
}

/// A cell in unit space on the 12x12 grid. Integers → no float drift, exact snapping.
public struct LayoutCell: Codable, Hashable, Sendable {
    public var x: Int, y: Int, w: Int, h: Int      // 0..12
    public var cameraID: Camera.ID?
}

public struct LayoutState: Codable, Sendable {
    public var mode: LayoutMode
    public var cells: [LayoutCell]                 // ordered; index == cell number == ⌥-nav order
    public var presetName: String?
}
```

| Mode | ⌘ | Cells | Unit rects `(x,y,w,h)` |
|---|---|---|---|
| `single` | ⌘1 | 1 | `(0,0,12,12)` |
| `grid2x2` | ⌘2 | 4 | `(0,0,6,6) (6,0,6,6) (0,6,6,6) (6,6,6,6)` |
| `hero1p5` | ⌘3 | 6 | hero `(0,0,8,8)`; `(8,0,4,4) (8,4,4,4)`; `(0,8,4,4) (4,8,4,4) (8,8,4,4)` |
| `grid3x3` | ⌘4 | 9 | 3×3 of 4×4 units |
| `grid4x4` | ⌘5 | 16 | 4×4 of 3×3 units |
| `hero1p7` | ⌘6 | 8 | hero `(0,0,9,9)`; `(9,0,3,3) (9,3,3,3) (9,6,3,3)`; `(0,9,3,3) (3,9,3,3) (6,9,3,3) (9,9,3,3)` |
| `dual2p8` | ⌘7 | 10 | heroes `(0,0,6,6) (6,0,6,6)`; bottom 2 rows × 4 cols of `(3,3)` |
| `custom` | ⌘8 | 1–24 | user rects, snapped to units, min 2×2 units, no overlap |
| Saved preset | ⌘9 | — | applies `Layout` preset #1; ⌘9 held opens the preset menu |

Pixel geometry (identical in Stage and Video Wall):

```
padding  p = 10pt (Stage) / 0pt (Video Wall, full bleed)
gap      g = 6pt  (Stage) / 2pt (Video Wall)
usableW = stageW - 2p - 11g          // 11 internal gutters on a 12-unit axis
unitW   = usableW / 12
cellRect.x = p + x*(unitW+g)
cellRect.w = w*unitW + (w-1)*g       // spans absorb the gutters they cross
```

Cells are laid out with a single `Canvas`-free `ZStack` + `.frame`/`.offset` per tile (no
`LazyVGrid`): explicit frames guarantee that a layout change animates every tile along a straight
path with `matchedGeometryEffect(id: cell.id, in: stage)` and never re-creates the video layer.
**Rule: a layout change must never tear down a decode session** — `StreamController`s are keyed by
camera, not by cell, and only quality (main/sub) is re-negotiated when the tile's pixel size crosses
a policy threshold (see `spec-core.md` admission table).

Overflow: if the new mode has fewer cells than the old, surplus cameras are kept in
`layout.overflow: [Camera.ID]` (persisted) and restored when a larger mode is chosen; a `+3` chip
appears at the Stage's bottom-trailing corner and opens a popover listing them.

### 5.2 Custom mosaic (⌘8)

- Enter edit mode with ⌘8 twice, or View ▸ Layout ▸ Edit Mosaic (⌥⌘8). Edit mode dims video to 70%
  and draws the 12×12 grid at 8% white.
- Every tile gains 8 drag handles (corners 14×14 pt, edges 6 pt) plus a whole-tile move grab area.
- Dragging snaps to unit boundaries; the snap is magnetic within 0.4 unit and produces a 1 pt accent
  guide line. Illegal drops (overlap, < 2×2 units, off-grid) render the tile stroke in
  `VTheme.Color.danger` and revert with `VTheme.Motion.micro` on release.
- ⌥-drag a tile edge resizes symmetrically; ⇧-drag preserves 16:9 (rounds to the nearest legal unit
  pair: 4×3? → 4×2 or 4×3 per closest ratio).
- `+` on empty grid area creates a tile in the largest free rectangle at the click point.
- Toolbar in edit mode: **Done (⏎) · Reset · Distribute Evenly · Save as Preset…**.
- Presets: `Layout` objects with a name, saved in `library.json`; the Layout menu lists them with
  ⌘9 bound to the first and drag-to-reorder inside the menu's "Manage Presets…" sheet.

### 5.3 Tile anatomy and hover chrome (`VTile`)

```
┌───────────────────────────────────────────────┐  ← 1pt stroke: rest = stroke/subtle,
│ ▎Front Door        H.265 1080p 25fps ⚡  ● REC │    hover = stroke/default, focused = 2pt accent
│                                               │  ← top chrome bar, 28pt, gradient scrim
│                                               │    (black 55% → 0%), never over faces: it is
│                  [ video ]                    │    inset 8pt from the top edge
│                                               │
│                                               │
│ 00:04:12                [🔇][◎][●][⌖][⤢][⬍][✕]│  ← bottom chrome bar, 32pt, same scrim inverted
└───────────────────────────────────────────────┘
```

| Zone | Element | Always visible? | Notes |
|---|---|---|---|
| Top-leading | 3 pt colour-tag bar + camera name chip | yes (dimmable) | name truncates head-first so the meaningful tail survives ("…Front Door") |
| Top-trailing | codec · resolution · fps · `⚡` HW-decode bolt | on hover, or always if View ▸ Tile Overlays ▸ Stats is on | `monospacedDigit`; fps updates at 1 Hz, not per frame |
| Top-trailing | `● REC` + elapsed | while recording, always | red dot pulses 1 s |
| Bottom-leading | recording elapsed / digital-zoom factor (`2.4×`) / patrol countdown | contextual | at most one at a time, priority: REC > zoom > patrol |
| Bottom-trailing | 7 action buttons, 24×24 pt hit target 28 pt, 4 pt spacing | on hover / on focus | order fixed left→right: Mute, Snapshot, Record, PTZ, Quality, Fit/Fill, Close |
| Centre | connecting narration / error card / retry countdown | state-driven (§13) | |
| Overlay | motion boxes, privacy-mask preview, PTZ direction glyph | event-driven | drawn by `VigilRender`, see `spec-render.md` |

Hover-chrome timing: fade in over 90 ms on pointer enter (`VTheme.Motion.micro`); auto-hide after
**2400 ms** without pointer movement inside the tile; any movement re-reveals. In cinema mode the
dwell is 1200 ms and the cursor hides with the chrome (`NSCursor.setHiddenUntilMouseMoves(true)`).
Chrome is **never** shown on a tile that is not under the pointer, except the focused tile's focus
ring. Keyboard users get chrome via ⌥⌘H (Show Tile Controls) which pins it for the focused tile.

Button behaviours:

| Button | Symbol | Click | ⌥-Click | Menu (press-and-hold 400 ms / right-click) |
|---|---|---|---|---|
| Mute | `speaker.slash` / `speaker.wave.2` | toggle this camera's audio | solo audio (mute all others) | volume slider, "Two-Way Audio" |
| Snapshot | `camera` | save per Settings ▸ Recording | copy to clipboard | Save As…, Copy, Quick Look, Reveal in Finder |
| Record | `record.circle` | start/stop; fills red while active | start recording **all** | duration presets (10 s / 30 s / 1 min / until stopped), "Include pre-roll" |
| PTZ | `dpad` | toggle the on-video PTZ pad overlay | open Inspector ▸ PTZ | preset list 1–9, Home |
| Quality | `arrow.up.left.and.arrow.down.right` w/ badge `S`/`M` | toggle sub ↔ main | force Third stream | Auto (default) / Main / Sub / Third, Transport ▸ TCP/UDP |
| Fit/Fill | `rectangle.arrowtriangle.2.inward` / `.outward` | toggle aspect fit ↔ fill (per camera, persisted) | reset digital zoom | Fit, Fill, Stretch (with a "not recommended" note), Actual Size |
| Close | `xmark` | clear the cell (camera keeps running only if it is elsewhere) | remove and shrink the mosaic (custom mode) | — |

### 5.4 Empty cell

Dashed 1 pt `stroke/subtle` rounded rect, centred `plus.viewfinder` 22 pt at 40% + label
`stage.emptyCell.title` ("Add camera"). Click (or ⏎ when focused) opens a **camera picker popover**:
a 280 pt-wide fuzzy list of unassigned cameras (same scorer as §11.3), ↑↓ + ⏎ to choose, ⌘⏎ to
choose and advance to the next empty cell. Drop target for sidebar drags and for tile drags.

### 5.5 Cycle / patrol mode (⌘Y)

```swift
public enum PatrolState: Equatable, Sendable {
    case off
    case running(source: PatrolSource, dwell: Duration, pageIndex: Int, endsAt: ContinuousClock.Instant)
    case pausedByUser(source: PatrolSource, dwell: Duration, pageIndex: Int)
    case pausedByInteraction(resumeAt: ContinuousClock.Instant)   // 8 s after last interaction
}
public enum PatrolSource: Equatable, Sendable { case allEnabled, group(CameraGroup.ID), overflow }
```

- Dwell options: **5 s · 10 s · 15 s (default) · 30 s · 60 s**, plus "Custom…" (3–600 s).
- Patrol *pages*: the camera set is chunked by the current mode's cell count; page N fills the
  cells in cell order. A 4×4 layout with 37 cameras patrols 3 pages (16/16/5, last page's spare
  cells stay black, not "Add camera").
- Transition: 320 ms cross-fade per tile with an 18 ms stagger in reading order
  (`VTheme.Motion.standard`); the outgoing decode session is kept alive for 1.5 s so a fast
  back-and-forth is instant.
- Pre-warm: the next page's `StreamController`s start connecting 2.5 s before the switch (budget
  permitting), so pages appear already-live.
- The toolbar toggle draws a 2 pt circular progress ring around the glyph, advancing once per
  second (not per frame). Countdown text also appears bottom-leading on the tile whose camera is
  about to change, in the last 3 s.
- Any interaction with the Stage (hover for > 600 ms, click, PTZ, scroll) pauses for **8 s** and
  shows a `⏸` pip on the toolbar toggle. `Esc` or ⌘Y stops entirely.
- Patrol never runs in the Video Wall unless explicitly enabled there (it has its own state).

### 5.6 Tile fullscreen, digital zoom, PiP

| Interaction | Binding | Behaviour |
|---|---|---|
| Solo / tile fullscreen | double-click, ⌘F, tile `⤢` | the tile expands to the full Stage via `matchedGeometryEffect` (`VTheme.Motion.expressive`, 380 ms); the other tiles keep decoding at sub-quality unless Settings ▸ Streams ▸ "Pause hidden tiles" is on (default **on** ⇒ they pause after 2 s, resume on exit with the last frame already cached) |
| Exit solo | `Esc`, ⌘F, double-click | reverse transition; scroll position and digital zoom of the tile are preserved |
| Digital zoom | scroll / pinch on the tile | 1.0×→8.0×, exponential (`factor *= exp(delta * 0.0025)`), anchored at the cursor; ⌘= / ⌘- step ±1.25×; ⌘0 resets with a 220 ms spring. Zoom > 1.0 shows a 56×32 pt navigator inset at the bottom-trailing with a draggable viewport rect |
| Pan | two-finger drag / click-drag with space held / middle-drag | inertial, clamped to content; rubber-band 24 pt with a spring back |
| PiP | ⌃⌘P, or tile menu ▸ Picture in Picture | `AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: layer, playbackDelegate: self))`. One at a time (system limit). The source tile shows a "Playing in Picture in Picture" placeholder with a *Bring Back* button. `AVPictureInPictureSampleBufferPlaybackDelegate` reports `isPlaybackPaused == false` and an indefinite time range (live), which hides the scrubber |
| Second display wall | ⌃⌘W | §5.8 |

### 5.7 Keyboard navigation between tiles

- **⌥←/→/↑/↓** move `focusedCell` geometrically: candidates are cells whose centre lies in the
  half-plane of the direction; the winner minimises `primaryAxisDistance + 0.35 *
  perpendicularOffset`. Wrapping is off (a bump plays the 120 ms `VTheme.Motion.micro` nudge, 3 pt).
- **⇥ / ⇧⇥** cycle cells in index order (and reach the sidebar and inspector at the ends,
  respecting `NSApp.isFullKeyboardAccessEnabled`).
- The focused tile draws a 2 pt inset accent ring with a 3 pt outer glow at 24% (animated in over
  120 ms). Focus is *always* visible — there is no "no focus" state on the Stage.
- ⏎ on a focused empty cell opens the picker (§5.4); ⏎ on a filled cell selects that camera in the
  sidebar and binds the Inspector.
- Plain digits **1–9** with a focused tile recall PTZ presets 1–9 (VMS convention). ⇧1–9 *stores*
  the current position to that preset after a confirm.
- Arrow keys **without** ⌥ drive PTZ on the focused tile (§6.3). This is why tile navigation uses ⌥.

### 5.8 Video Wall (second display)

- ⌃⌘W opens the `wall` window. If more than one external display exists, a 240 pt picker popover
  appears on the main window first (screen thumbnails with resolution labels, ↑↓ + ⏎).
- Placement: `window.setFrame(targetScreen.frame, display: true)` then
  `window.toggleFullScreen(nil)` on that screen; `collectionBehavior` includes
  `.fullScreenPrimary`. `NSApp.presentationOptions` gains `.autoHideMenuBar` only while the wall is
  the key window on the same screen as the menu bar.
- Wall chrome: none, except optional 1 pt name chips (⌥N toggles) and a 2 s-fading toast for state
  changes. Cursor hides after 3 s idle.
- Wall has its **own** `LayoutState` (`library.wallLayout`) and its own patrol state, so the
  operator can run a 4×4 patrol on the wall and work in a 1+5 on the laptop.
- Wall respects the global decode budget; if admission fails, the *wall* wins and main-window
  offscreen tiles are demoted first (priority: wall visible > main focused > main visible >
  sidebar thumbnails).
- ⌘W or `Esc` closes the wall and restores the main window's presentation options.

### 5.9 Stage routes

```swift
enum StageRoute: Equatable { case live, events, recordings, bookmarks, cameraDetail(Camera.ID) }
```

`sidebarSelection` maps to a route; the Stage cross-fades between routes over 180 ms
(`.opacity` + 6 pt vertical offset, `VTheme.Motion.standard`). Live decoding continues behind
non-live routes at sub-stream/thumbnail rate, so returning to Live shows frames within one frame.
`cameraDetail` is only reachable from the sidebar's ⌘I ("Edit Camera") and renders a settings form,
not video.

---

## 6. Inspector

Right panel, 288–440 pt (ideal 320). Header: camera name (Title3, editable on double-click), colour
tag dot, status line `"● Live · H.265 · 6 d 4 h"`. Six tabs as a `VSegmentedControl` of icons with
a text label for the selected one (⌃1…⌃6 select tabs; ⌥⌘I toggles the whole panel).

When **no camera** is selected the Inspector shows an aggregate "System" view: total live/degraded/
offline counts, aggregate bitrate sparkline, decode-budget gauge (`used/limit`), and the 5 most
recent events. It is never blank.

Every tab is a `ScrollView` of `VInspectorSection`s (collapsible, state per section persisted in
`@SceneStorage("inspector.collapsed")`). Values that change use `monospacedDigit()` and never
re-layout: numeric fields reserve width for their maximum (`"1920×1080"`, `"999.9 Mb/s"`).

### 6.1 Info

| Row | Source (`spec-isapi.md`) | Empty/loading |
|---|---|---|
| Model, Device name | `/ISAPI/System/deviceInfo` → `model`, `deviceName` | skeleton bar 80 pt |
| Firmware | `firmwareVersion` + `firmwareReleasedDate` (formatted `.dateTime.year().month().day()`) | `—` |
| Serial | `serialNumber`, masked as `DS-2CD…4821` with a "Copy" affordance; full value only on hover+⌥ | `—` |
| MAC | `macAddress` | `—` |
| Channel | `channel` of `Camera` + total channels detected | — |
| Uptime | `/ISAPI/System/status` → `deviceUpTime` seconds, rendered `"6 d 4 h 12 m"`, 1 Hz | `—` |
| Host | `host:rtspPort` (+ `httpPort` if different), TLS lock glyph if `useTLS` | — |
| Storage | `/ISAPI/ContentMgmt/Storage` → per-HDD capacity/free/status as a 6 pt bar + `"1.8 TB free of 7.3 TB"`; red bar + warn glyph when `status != "ok"` | `—` |
| Capabilities | chips: `PTZ`, `Audio`, `Two-Way`, `H.265`, `Third stream`, `Motion`, `Line crossing`, `Intrusion` — greyed when absent | skeleton chips |
| Actions | `Edit Camera…` `Reboot Device…` (destructive confirm) `Open Web UI` (opens `http(s)://host:port` in the default browser) `Run Stream Doctor…` | — |

ISAPI fetches are lazy per tab, cached 60 s, and never block: the tab renders instantly with
skeletons and fills in as responses land. A failed fetch shows an inline `VBadge` "Unavailable"
with a retry glyph — never an alert.

### 6.2 Stream

Live telemetry from `HealthMonitor` (1 Hz, 600-sample ring = 10 min).

| Row | Rendering |
|---|---|
| Codec / profile / level | `"H.265 Main · L4.1"` |
| Resolution | `"1920×1080"` + `"(SAR 1:1)"` when non-square |
| Stream in use | `Auto → Sub` badge; tap cycles Auto/Main/Sub/Third |
| Transport | `TCP (interleaved)` / `UDP` / `UDP multicast` + a swap button |
| FPS | big number (Title2, monospaced) + 60 s `VSparkline`, target fps as a dashed guide line |
| Bitrate | `"4.12 Mb/s"` + 10 min area sparkline, y-axis auto-scaled to p95, label at peak |
| Packet loss | `"0.02 %"`, sparkline; colours: < 0.5 % ok, 0.5–2 % warn, > 2 % danger |
| Jitter | `"6 ms"` + sparkline (RFC 3550 interarrival jitter, ms) |
| Decode queue | `"2 frames"` + a 5-segment pip meter; > 8 frames = warn (we are behind) |
| Latency estimate | `"186 ms"` glass-to-glass estimate, with a `ⓘ` popover explaining the derivation (RTP arrival → decode → display presentation delta) |
| Hardware decode | `⚡ VideoToolbox (hardware)` in `ok` colour, or `CPU (software)` in warn with a `ⓘ` naming the reason (unsupported profile, budget exhausted, 10-bit on Intel) |
| Keyframe interval | `"2.0 s (GOP 50)"` measured, not reported |
| Session | RTSP session id (masked `…a91c`), uptime, reconnect count today, last error (one line, tap → Console-style detail popover) |
| Actions | `Request Keyframe` `Reconnect` `Copy Diagnostics` `Export 10 min CSV` |

Sparklines are drawn in a `Canvas` with a single `Path`, throttled to 4 Hz (not 60 Hz) — the numbers
update at 1 Hz. This is a hard performance rule: the Inspector must cost < 0.4 ms per frame.

### 6.3 PTZ

```
┌─────────────────────────────┐
│        ┌───────────┐        │   VPTZPad: 148pt circle, 8 sectors + centre Home.
│        │  ↖  ↑  ↗  │        │   Press-and-hold = continuous move; drag from centre
│        │  ←  ⌂  →  │        │   = analog vector (angle → pan/tilt ratio, radius → speed).
│        │  ↙  ↓  ↘  │        │   Keyboard: arrows (focused tile or focused pad).
│        └───────────┘        │
│  Speed  ○──────●───  5 / 7  │   Discrete 1..7 (Hikvision range), ⇧-arrow = speed 7 burst,
│                             │   ⌥-arrow = speed 1 fine step.
│  Zoom   [ − ]     [ + ]     │   Hold to run; tap = 300 ms pulse. Keys: - / =
│  Focus  [ ◐ ]     [ ◑ ]     │   Keys: [ / ]   · "Auto" toggle when supported
│  Iris   [ ⊖ ]     [ ⊕ ]     │   Keys: ; / '
│                             │
│  PRESETS                 ＋ │   3-column grid of 64×36 thumbnails, number badge 1..255,
│  ┌────┐┌────┐┌────┐         │   name below (Caption2, 1 line). Click = go (optimistic,
│  │ 1  ││ 2  ││ 3  │         │   §16.3). ⇧-click = overwrite (confirm). Right-click menu:
│  └────┘└────┘└────┘         │   Go · Rename… · Update Thumbnail · Set to Current · Delete
│  ┌────┐┌────┐┌ ＋ ┐         │   Thumbnails are captured on save and cached at
│  │ 4  ││ 5  ││    │         │   ~/Library/Caches/Vigil/presets/<cam>/<n>.jpg
│  └────┘└────┘└────┘         │
│  PATROLS                    │   Rows: name, ▶/⏸, dwell summary; "Edit…" opens a sheet
│  ▶ Night Sweep  8 stops     │   (ordered stop list, per-stop dwell + speed, drag to reorder)
│  ▶ Perimeter    4 stops     │
│  ─────────────────────────  │
│  ⌂ Home  · Set Home · Park  │   Park = auto-return to Home after N s idle (0 = off)
└─────────────────────────────┘
```

- **3D positioning**: drag a rectangle on the video (`VigilRender` owns the gesture) → the Inspector
  shows a transient "Centering…" pip; on ISAPI failure the rectangle flashes danger and a toast
  explains. Click-to-centre is a zero-size drag.
- If `DeviceCapabilities.ptz == false` the whole tab shows a `VEmptyState`:
  `inspector.ptz.unsupported.title` = "This camera has no PTZ." with body naming the model. The tab
  icon dims but remains selectable (predictable IA beats disappearing tabs).
- Every control is optimistic (§16.3) with a 1.2 s failure window.

### 6.4 Image

All controls write through ISAPI with a 250 ms trailing debounce and apply **instantly** to the
local Metal render path so the user sees the change in the same frame (§16.4).

| Control | Type | Range | ISAPI |
|---|---|---|---|
| Brightness, Contrast, Saturation, Sharpness | `VSlider` with value bubble, ⌥-drag = fine (0.25 step) | 0–100 | `/ISAPI/Image/channels/{n}/color` |
| Local preview only | toggle "Apply on device" vs "Adjust my view only" | — | when off, changes stay in the Metal shader and never touch the camera (essential for shared cameras) |
| WDR | segmented Off / On / Auto + level slider | 0–100 | `/ISAPI/Image/channels/{n}/WDR` |
| Day/Night | segmented Auto / Day / Night / Schedule (+ time pickers) | — | `/ISAPI/Image/channels/{n}/ISPMode` |
| IR light | segmented Off / Auto / On + brightness | 0–100 | `/ISAPI/Image/channels/{n}/supplementLight` |
| Image flip / mirror | segmented Off / Centre / Horizontal / Vertical | — | `/ISAPI/Image/channels/{n}/ImageFlip` |
| Backlight (BLC) | segmented Off / Up / Down / Left / Right / Centre | — | `/ISAPI/Image/channels/{n}/BLC` |
| Noise reduction | segmented Off / Normal / Expert + level | 0–100 | `/ISAPI/Image/channels/{n}/noiseReduce` |
| Deinterlace (analog NVR channels only) | segmented Off / Bob / Blend | — | local only |
| Night boost (local tone curve) | toggle + strength | 0–100 | local only |
| Footer | `Reset to Defaults` (confirm) · `Copy Settings` · `Paste to…` (multi-camera picker) | — | — |

### 6.5 Events

- Reverse-chronological list of the last 200 events for this camera: 64×36 thumbnail, event-type
  glyph + label, relative time (`"4 min ago"`, refreshed at 15 s; absolute on hover), duration if
  known, and a `▶` that jumps to Playback at `timestamp − 5 s`.
- Grouped by day with sticky headers. Type filter chips at the top. `Clear` (this camera) and
  `Export CSV`.
- Empty: `inspector.events.empty.title` = "No events yet." + body "Motion detection is
  {enabled|disabled} on this camera." with an inline `Enable in Settings` link when disabled.

### 6.6 Recording

| Section | Content |
|---|---|
| Local recording | Big `Start/Stop` (⌘R) with elapsed; current file name; pre-roll indicator `"5 s pre-roll armed"`; `Reveal in Finder`; today's clip list (name, duration, size) |
| Auto-record | toggle "Record on motion", pre-buffer (0–15 s, default 5), post-buffer (5–120 s, default 15), cooldown (default 20 s), max clip length (default 5 min) |
| Schedule | 7×24 grid; drag to paint; three brushes: Off, Continuous (blue), Motion (amber); ⌥-drag erases; `Copy day ▸` menu; presets "Always", "Nights & weekends", "Work hours" |
| Destination | folder path (`NSOpenPanel` picker, sandbox-free app so a plain path is fine), format MP4/MOV, filename template with live preview (§14.3) |
| Storage | this camera's local usage, retention policy (keep N days / cap N GB / never delete), and `"Oldest clip: 12 Jul"`; a 6 pt bar with the disk's free space and a warn threshold marker |
| Device storage | NVR/SD status (read-only mirror of Info ▸ Storage) with `Search Recordings…` → Playback |

---

## 7. Playback

### 7.1 Wireframe

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────────┐
│ ●●●  ‹ 26 Jul 2026 ›  📅   Cameras: [Front Door ▾] [+]        Sync ⇧⌘Y  Export ⌘E   ⌘K   [ ⋯ ]      │
├──────────────────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                                      │
│                                    ┌──────────────────────────┐                                      │
│                                    │                          │                                      │
│                  [ video canvas — 1 camera, or 2x2 when synchronized ]                               │
│                                    │      Front Door          │                                      │
│                                    │  26 Jul 2026 10:14:38.20 │  ← burned-in OSD (toggle ⌥T)         │
│                                    └──────────────────────────┘                                      │
│                                                                                                      │
├──────────────────────────────────────────────────────────────────────────────────────────────────────┤
│  ⏮  ◀◀  ⏸  ▶▶  ⏭    −10s  +10s   ⟨ ⟩ frame    Speed ─●──── 1×    🔊 ──●──    ⤢   [I]—[O]  ⌘E        │
├──────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ Front Door                                                             ⊖ ──────●── ⊕   1 h ▾         │
│ 09:00      09:15      09:30      09:45      10:00      10:15      10:30      10:45      11:00        │
│ ├──────────┼──────────┼──────────┼──────────┼──────────┼──────────┼──────────┼──────────┤            │
│ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▒▒▒▒▒▒▒▒▓▓▓▓▓▓▓▓▓▓░░░░░░░▓▓▓▓▓▓█▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▒▒▒▒▒▒▒▒▒▒▒▒▓▓▓▓▓▓▓▓▓            │
│ ▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁            │
│                                    ▲ 10:14:38            ◆ bookmark      ● event marker              │
│ Back Yard  (synchronized)                                                                            │
│ ▓▓▓▓▓▓░░░░░░░░░░▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░░░░░░░░▓▓▓▓▓▓            │
└──────────────────────────────────────────────────────────────────────────────────────────────────────┘
   ▓ continuous (blue)   ▒ motion (amber)   █ alarm (red)   ░ no recording   ▁ local clips (accent)
```

### 7.2 Structure

| Region | Height | Content |
|---|---|---|
| Toolbar | 40 pt | day stepper `‹ date ›` + calendar popover (⌘G), camera chips with `+` (max 4), Sync toggle, Export, `⋯` (Download from device, Show local clips only, Burn-in OSD, Timeline density) |
| Canvas | flexible, min 320 pt | 1 camera fills; 2 = side-by-side; 3–4 = 2×2. Each pane has the same `VTile` chrome minus quality/close |
| Transport bar | 44 pt | §7.5 |
| Timeline stack | 96 pt for 1 camera, +44 pt per extra camera, max 268 pt then scrolls | §7.3 |

### 7.3 Timeline

- One **lane** per camera. A lane is: label row (12 pt), heatmap band (**28 pt**), local-clip lane
  (**6 pt**), marker row (12 pt). Extra cameras get a compact 44 pt lane (label overlaid, 20 pt
  band, 6 pt clips).
- Ruler above the first lane: ticks + labels chosen by zoom level (table below). Labels use
  `monospacedDigit` and `Caption2`; the current-hour label is `primary`, others `tertiary`.
- **Heatmap encoding** — one colour per pixel column, by priority `alarm > motion > continuous`;
  opacity `0.55 + 0.45 × coverage` where `coverage` is the fraction of that column's time span that
  is recorded. Sub-pixel gaps are preserved by max-combining, so a 3 s clip is never invisible: the
  minimum drawn width is **2 pt** with a 1 pt outer glow.
- **Colours**: continuous `#3B82F6`-class blue, motion `#F5A524`-class amber, alarm `#EF4444`-class
  red, local clips accent — exact tokens `VTheme.Color.timelineContinuous / timelineMotion /
  timelineAlarm / accent` from `DESIGN.md`. `differentiateWithoutColor` adds a hatch pattern
  (motion = 45° lines, alarm = cross-hatch).
- **Playhead**: 2 pt accent line, full stack height, with a 22 pt rounded label above showing
  `HH:mm:ss.SS`. Always drawn on top; never clipped.
- **Markers**: events as 6 pt diamonds on the marker row (colour by type), bookmarks as accent
  pennants. Overlapping markers within 8 pt collapse into a numbered cluster (`3`) that expands on
  click into a popover list.
- **Gaps** (no recording) are `canvas` with a 1 pt dotted baseline, so absence is visibly different
  from "not loaded" (which is a shimmer).

Zoom levels (9 stops; the visible span at a 1200 pt-wide timeline):

| Stop | Visible span | px/s @1200 pt | Major tick | Minor tick | Label format |
|---|---|---|---|---|---|
| 0 | 24 h | 0.0139 | 1 h | 15 min | `HH` |
| 1 | 12 h | 0.0278 | 1 h | 15 min | `HH:mm` |
| 2 | 6 h | 0.0556 | 30 min | 10 min | `HH:mm` |
| 3 | 3 h | 0.1111 | 15 min | 5 min | `HH:mm` |
| 4 | 1 h | 0.3333 | 10 min | 1 min | `HH:mm` |
| 5 | 30 min | 0.6667 | 5 min | 1 min | `HH:mm` |
| 6 | 10 min | 2.0 | 1 min | 15 s | `HH:mm` |
| 7 | 5 min | 4.0 | 30 s | 10 s | `HH:mm:ss` |
| 8 | 1 min | 20.0 | 10 s | 1 s | `mm:ss` |

- Pinch (`NSMagnificationGestureRecognizer`) zooms **continuously** between stops, anchored at the
  gesture centroid; on release it snaps to the nearest stop if within 12 % (spring
  `VTheme.Motion.micro`).
- Scroll wheel: vertical scroll = zoom anchored at the cursor (mouse users); horizontal
  two-finger scroll = pan; ⇧+scroll = pan; ⌘+scroll = zoom (fine, 0.5× rate).
- ⊖/⊕ buttons and the `1 h ▾` menu jump between stops (⌘= / ⌘-). ⌘0 fits the day (stop 0).
- Panning is clamped to `[dayStart − 1 h, dayEnd + 1 h]` with a 40 pt rubber band.
- **Scrub**: click positions the playhead and seeks; drag scrubs. While dragging, a **preview
  card** (176 pt wide: 160×90 thumbnail + timestamp) floats 12 pt above the cursor, clamped to the
  window. Thumbnails come from a dedicated keyframe-only playback session (see `spec-video.md`)
  throttled to 5 requests/s with an LRU cache of 128 images; before an image arrives the card shows
  a shimmer plus the exact timestamp — the card never appears empty and never jumps in size.
- **Magnetism**: while scrubbing, the playhead snaps to a nearby marker or recording-segment edge
  within 6 pt (release-time snap, with a 60 ms `micro` settle and a haptic-free 1 pt tick glyph).
  ⌥ held disables magnetism.
- Keyboard on the timeline: ←/→ = ±10 s, ⇧←/⇧→ = ±1 min, ⌥←/⌥→ = frame step, ⌘←/⌘→ = previous/next
  segment edge, `,`/`.` = previous/next event marker, Home/End = day start/end.

### 7.4 Data loading

- On open: `POST /ISAPI/ContentMgmt/search` for the visible day (chunked 4 h at a time, first chunk
  = the hour around `focus`, then outward) merged with local clips from `ConfigStore`.
- Not-yet-loaded ranges render as a 1.2 s-period shimmer band, never as "no recording".
- A failed search shows an inline retry strip above the lane:
  `playback.searchFailed.body` + `Retry`, and the rest of the UI stays usable.
- The day stepper pre-fetches ±1 day at low priority. Changing the day keeps the wall-clock
  time-of-day position (10:14 on the 26th → 10:14 on the 25th), which is what reviewers expect.

### 7.5 Transport controls

| Control | Binding | Behaviour |
|---|---|---|
| Play / Pause | `Space`, `K` | optimistic: the button flips instantly, the RTSP `PLAY`/`PAUSE` follows; if the device rejects, revert + toast |
| −10 s / +10 s | `←` / `→` | seek relative; coalesces rapid presses into one seek per 120 ms |
| Frame step back/forward | `⌥←` / `⌥→` | pauses first; backward step uses the decoded-GOP cache (up to 90 frames) so it is instant; if the cache misses, we re-seek to the previous keyframe and decode forward (spinner never shown, a 1 pt progress hairline appears under the transport bar) |
| Reverse / Forward shuttle | `J` / `L` (repeat presses) | speed ladder −8, −4, −2, −1, then 1, 2, 4, 8; `K` returns to 1× pause |
| Speed | slider + menu | 0.25, 0.5, 1, 2, 4, 8 (and negatives for reverse). ⇧`.` faster, ⇧`,` slower. Above 2× audio mutes automatically (indicator shows `🔇 fast`) |
| Prev/Next segment | `⌘←` / `⌘→` | jumps recording-segment edges |
| Prev/Next event | `,` / `.` | jumps event markers |
| Bookmark | `B` | adds a bookmark at the playhead, inline title field in a 220 pt popover, ⏎ commits |
| Set In / Out | `I` / `O` | see §7.7 |
| Export | `⌘E` | export sheet |
| Volume | slider + `⌥⌘M` mute | per-window, not per-camera |
| Fullscreen canvas | `⌘F` | hides transport + timeline; they return on pointer-near-bottom or any key |
| OSD burn-in toggle | `⌥T` | affects exported clips too (a warning appears in the export sheet) |

Reverse playback uses server-side reverse where the device supports it, otherwise
keyframe-stepping backwards (spelled out in `spec-video.md`); the UI reports the difference
honestly: at negative speeds the speed chip reads `−4× (keyframes)` when frame-accurate reverse is
unavailable.

### 7.6 Synchronized multi-camera playback

- Add cameras with `+` (max 4). All lanes share **one** master clock (`PlaybackClock`, `spec-core`).
- `Sync` on (default): one playhead, one transport, one export range. Seeks are issued to all
  sessions with `Range: clock=YYYYMMDDTHHMMSSZ-`; a camera that lands more than **±40 ms** off is
  nudged by rate (0.98×/1.02×) rather than re-seeking, to avoid visible jumps.
- A camera with no recording at the current instant shows a black pane with `"No recording at
  10:14"` and its lane is dimmed — it does not stall the others.
- `Sync` off: each pane gets its own playhead and transport (the transport bar controls the
  focused pane, indicated by an accent ring).
- The slowest camera governs start: the group stays paused until all panes have a decoded frame or
  1.5 s elapses, whichever is first (then stragglers join late). This avoids a staggered start that
  looks broken.

### 7.7 In/out selection and export

- `I` sets in, `O` sets out; either can precede the other (they auto-swap). The selection renders as
  an accent-tinted region with two 12 pt draggable handles and a floating duration chip
  (`"00:02:14"`). ⌥-drag a handle for frame-accurate adjustment at zoom stop ≥ 7.
- Constraints: min 1 s, max 4 h; a selection spanning a recording gap is allowed and the export
  writes a single file with the gap removed, with a note in the sheet.
- ⌘E opens the **Export sheet** (480 pt wide):

```
Export Clip
  Range      10:12:24 → 10:14:38   (2 m 14 s)          [ Adjust ]
  Cameras    ☑ Front Door   ☑ Back Yard                (separate files)
  Format     ( MP4 ) ( MOV )        ☑ Include audio
  Video      Copy without re-encoding (H.265, 1920×1080, 25 fps)
  Overlay    ☐ Burn in timestamp and camera name
  Save to    ~/Movies/Vigil/                          [ Choose… ]
  Name       FrontDoor_20260726_101224.mp4            [ Template… ]
  Estimated  68.4 MB
                                        [ Cancel ]  [ Export ]
```

- Export is **passthrough muxing** (no re-encode) unless "Burn in overlay" is checked, in which
  case the sheet warns: `export.reencodeWarning.body`. Progress appears as a determinate bar in the
  sheet, then the sheet closes and a toast offers `Reveal` / `Share`. Cancelling deletes the
  `.partial` file.
- Export never blocks playback; it runs on a background `Task` with `.utility` priority.

---
