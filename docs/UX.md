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
   within one frame (8.3 ms at 120 Hz) and reconciles asynchronously (§15).
3. **No layout reflow after content arrives.** Sizes are committed before the first byte
   (§15.1). A tile that becomes live must not move, resize, or re-letterbox.
4. **Keyboard-first.** Every action in §11 is reachable without the mouse and appears in the menu
   bar. Anything reachable only by hover is a bug.
5. **Strings are keys.** No literal user-facing string in Swift source; all strings come from
   `Localizable.xcstrings` with the key structure of §14.

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
  Deleting a camera from **Cameras** deletes it everywhere (destructive confirm, §14 key
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
| Preferences (§13) | `UserDefaults` (`@AppStorage`, suite `com.vigil.app`) | ✅ | exported by diagnostics, redacted |
| Shortcut overrides | `UserDefaults` key `shortcuts.overrides` (JSON) | ✅ | §11.4 |
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
        .commands { VigilCommands(app: app, env: env) }   // §11.2

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
        .overlay { CommandPaletteOverlay() }            // §10
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
| Settings | content-sized per pane (see §13) | — | — | `.contentSize` | last pane (`@AppStorage("settings.lastPane")`) |
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
  connecting state (§15) in the same frame.

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
| 3 | **CAMERAS** | camera rows (§4.2), sorted by `orderIndex`; header `＋` opens the add menu (Discover…, Add Manually…, Import CSV…) | live/total | `VEmptyState` (§12.2) |
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
| ⌫ | delete with confirm (§14 `confirm.deleteCamera.*`) |
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
Two-Way Audio                    ⌃⌘T
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
Reconnect Now                    ⌃⌘R
Run Stream Doctor…               ⌥⌘D
Copy RTSP URL          (password redacted as ●●●)
Copy Diagnostics
──────────────────────────────────
Disable Camera                   Space
Delete Camera…                   ⌫
```

### 4.4 Search & filter

- Search matches, in priority order: name (fuzzy, §10.3 scorer), group name, host/IP (prefix),
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
| Centre | connecting narration / error card / retry countdown | state-driven (§12) | |
| Overlay | motion boxes, privacy-mask preview, PTZ direction glyph | event-driven | drawn by `VigilRender`, see `spec-render.md` |

Hover-chrome timing: fade in over 90 ms on pointer enter (`VTheme.Motion.micro`); auto-hide after
**2400 ms** without pointer movement inside the tile; any movement re-reveals. In cinema mode the
dwell is 1200 ms and the cursor hides with the chrome (`NSCursor.setHiddenUntilMouseMoves(true)`).
Chrome is **never** shown on a tile that is not under the pointer, except the focused tile's focus
ring. Keyboard users get chrome via ⌃⌘H (Show Tile Controls) which pins it for the focused tile.

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
a 280 pt-wide fuzzy list of unassigned cameras (same scorer as §10.3), ↑↓ + ⏎ to choose, ⌘⏎ to
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
│  │ 1  ││ 2  ││ 3  │         │   §15.3). ⇧-click = overwrite (confirm). Right-click menu:
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
- Every control is optimistic (§15.3) with a 1.2 s failure window.

### 6.4 Image

All controls write through ISAPI with a 250 ms trailing debounce and apply **instantly** to the
local Metal render path so the user sees the change in the same frame (§15.4).

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
| Destination | folder path (`NSOpenPanel` picker, sandbox-free app so a plain path is fine), format MP4/MOV, filename template with live preview (§13.3) |
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

## 8. Discovery & add camera

### 8.1 Wireframe (the discovery sheet / window body)

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  Add Cameras                                                            ✕    │
│  ●━━━━━━━━●━━━━━━━━○━━━━━━━━○   Scan · Select · Sign in · Channels           │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   ⟳ Scanning 192.168.1.0/24 …  found 7 devices          [ Stop ]  [ Manual ] │
│   ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░  198 / 254 hosts · SADP ✓ · ONVIF ✓        │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │ ☑  DS-2CD2143G2-I      192.168.1.64    Hikvision   4 ch   V5.7.3  ✓    │  │
│  │      Front hallway dome · MAC c4:2f:90:… · activated                   │  │
│  ├────────────────────────────────────────────────────────────────────────┤  │
│  │ ☑  DS-7608NI-K2/8P     192.168.1.10    NVR         8 ch   V4.30.0 ✓    │  │
│  │      NVR · 6 channels online, 2 empty                                  │  │
│  ├────────────────────────────────────────────────────────────────────────┤  │
│  │ ☐  DS-2CD2043G0-I      192.168.1.71    Hikvision   1 ch   V5.5.8  ⚠    │  │
│  │      Not activated — set a password before use            [ Activate ] │  │
│  ├────────────────────────────────────────────────────────────────────────┤  │
│  │ ☐  IPC-HFW2431         192.168.1.88    ONVIF only  1 ch   —       ⓘ    │  │
│  │      Not a Hikvision device — will use the ONVIF fallback              │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
│  ☑ Select all reachable            7 found · 2 selected                      │
├──────────────────────────────────────────────────────────────────────────────┤
│  Credentials for the selected devices                                        │
│  User [ admin              ]  Password [ ••••••••••  ]  ☑ Remember in Keychain│
│  ○ Use the same for all      ● Ask per device                                │
│  Transport [ Auto ▾ ]   RTSP port [ 554 ]   HTTP port [ 80 ]   ☐ Use TLS     │
│                                            ⓘ Tested 192.168.1.64 — signed in │
├──────────────────────────────────────────────────────────────────────────────┤
│  [ Import CSV… ]                                  [ Back ]  [ Test ]  [ Add ]│
└──────────────────────────────────────────────────────────────────────────────┘
```

### 8.2 Flow

`DiscoveryRootView(presentation: .window | .sheet)` — the same view is a `Window` (⇧⌘N, File ▸
Discover Cameras…) and a `.sheet` presented over the first-run empty state. Four steps in a
`PhaseAnimator`-driven horizontal pager; steps are non-linear (you may jump back), and the progress
dots at the top are clickable for completed steps.

**Step 0 — Local network permission pre-explain (first run only).** macOS 14 prompts for local
network access on our first multicast send. We show a 380 pt card *before* triggering it:
`discovery.permission.title` / `.body` / primary `Continue` / secondary `Add manually instead`. If
the user has previously denied it, the scan step shows an inline strip with a
`Open System Settings` button (`x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork`)
and the manual-add path remains fully functional.

**Step 1 — Scan.** Three probes run concurrently (`VigilDiscovery`):

| Probe | Wire | Progress contribution |
|---|---|---|
| SADP | UDP multicast `239.255.255.255:37020` broadcast + listen `37020` | instant hits, 0–2 s |
| ONVIF WS-Discovery | UDP multicast `239.255.255.250:3702` `Probe` | instant hits, 0–3 s |
| Subnet sweep | TCP connect to `:554`, `:80`, `:8000` across the interface CIDR (≤ /22), 64-way concurrency | the determinate bar (`n / total hosts`) |

Scan animation: a 2 pt accent sweep line traverses the results panel once per 1.6 s while scanning
(`PhaseAnimator`, `reduceMotion` → a static indeterminate bar). Each new device row springs in
(scale 0.96→1, opacity, `VTheme.Motion.standard`) at the top and the list re-sorts by IP after a
600 ms settle so rows do not jump under the cursor. Rows already added to the library appear dimmed
with an `Added` badge and are unselectable.

Narration under the progress bar, updated live: `"SADP ✓ · ONVIF ✓ · sweeping 198/254"`. Scanning
never blocks the Add button — a manually typed device can be added while the sweep runs.

**Step 2 — Select.** Row anatomy: checkbox · model (Headline) · IP (Mono, Caption1) · kind chip
(`Hikvision` / `NVR` / `ONVIF only`) · channel count · firmware · status glyph. Second line:
device name / channel summary / warning with an inline action. Multi-select via checkboxes, ⇧-click
ranges, ⌘A select all reachable.

**Step 3 — Sign in.** Shared credentials by default, `Ask per device` for mixed passwords. `Test`
runs the credential probe against every selected device concurrently (max 8) and annotates each row
with a result glyph + one-line reason (§8.4). `Add` is enabled as soon as ≥ 1 device tests
successfully; devices that failed stay in the list with their reason so the user can fix them.

**Step 4 — Channels (NVR/DVR only).** For each selected NVR we enumerate channels
(`/ISAPI/ContentMgmt/InputProxy/channels` + `/ISAPI/Streaming/channels`) and show a checkbox list:

```
DS-7608NI-K2/8P · 192.168.1.10                    ☑ Select all online (6)
  ☑ 1  Front Door      1920×1080  H.265  online
  ☑ 2  Back Yard       1920×1080  H.265  online
  ☐ 3  —               —          —      no signal
  ☑ 4  Side Gate       1280×720   H.264  online
  Name imported cameras as  [ {device} · {channelName} ▾ ]
```

Naming templates: `{channelName}`, `{device} · {channelName}`, `{device} CH{channel}`, `Custom…`.
Channels with no signal are unchecked by default but still addable (they will show "offline").

**Bulk add** commits atomically: one `ConfigStore` transaction, one Keychain write per distinct
credential, then the Discovery window closes and the main window shows a toast
`discovery.added.body` with an `Undo` action (5 s window, backed by `UndoManager`). New cameras are
appended to the sidebar with a 3-frame accent flash and the first 4 are auto-assigned to empty
Stage cells.

### 8.3 Manual add form

Reachable from `＋` ▸ Add Manually…, ⌘N, or Discovery ▸ `Manual`. A 420 pt form; **Test** is always
enabled, **Add** is enabled when host + credentials are non-empty (we never require a successful
test — some cameras only answer once recording, and blocking the user is worse than a bad row).

| Field | Type | Default | Validation |
|---|---|---|---|
| Name | text | auto-filled from the device after a successful test, else `"Camera {n}"` | non-empty after trim |
| Host | text | — | IPv4 / IPv6 / hostname; live-validated; paste of `rtsp://user:pass@host:554/Streaming/Channels/101` **auto-parses into every field** (a genuinely delightful touch, and the fastest path for advanced users) |
| RTSP port | number stepper | 554 | 1–65535 |
| HTTP port | number stepper | 80 (443 when TLS on) | 1–65535 |
| Use TLS | toggle | off | on ⇒ HTTP port defaults to 443 |
| Username | text | `admin` | non-empty |
| Password | secure field with a reveal eye | — | ≥ 1 char; strength not judged (it's the camera's) |
| Channel | number stepper | 1 | 1–64; helper text shows the resolved RTSP path |
| Stream | segmented Main / Sub / Third / Auto | Auto | — |
| Transport | segmented Auto / TCP / UDP | Auto | Auto = TCP first, UDP on failure |
| Group | picker + New Group… | None | — |
| Colour tag | 6 swatches + None | None | — |
| Advanced ▸ | disclosure: custom RTSP path override, ONVIF-only mode, keepalive interval, "Ignore certificate errors (this device)" | — | the path override shows the computed default as placeholder: `/Streaming/Channels/101` |

Helper text under Channel, always live: `rtsp://192.168.1.64:554/Streaming/Channels/101` with the
password never shown.

### 8.4 Credential test — distinct failure reasons

`Test` runs the `Stream Doctor` prefix sequence (`spec-core.md`): TCP 80/554 → RTSP `OPTIONS` →
ISAPI `GET /ISAPI/System/deviceInfo` with Digest → RTSP `DESCRIBE` with Digest → SDP codec check.
The UI must never say "failed" without a cause and a next step.

| Detected condition | Signal | Row glyph | Message key | Primary fix offered |
|---|---|---|---|---|
| Signed in | 200 + deviceInfo | ✓ green | `test.ok.body` | — |
| Wrong password | HTTP 401 with `<subStatusCode>badAuthentication` / RTSP 401 after a fresh nonce | ✕ red | `error.auth.wrongPassword.*` | focus the password field, offer `Show password` |
| Wrong user name | 401 + `userNotExist` | ✕ red | `error.auth.unknownUser.*` | focus user field |
| Locked out | 401 + `userLocked` / `Device Locked` | ⏱ red | `error.auth.locked.*` (includes the remaining minutes when reported) | `Try again in {n} min`, `Unlock via web UI` |
| Not activated | 401 + `notActivated`, or SADP flag `activated=false` | ⚠ amber | `error.notActivated.*` | `Activate…` (sets the first password via `/ISAPI/System/activate`) |
| Unreachable | TCP connect timeout (3 s) / `ECONNREFUSED` / no route | ○ grey | `error.unreachable.*` | `Check the address`, `Rescan` |
| Reachable but no ISAPI | 404/405 on deviceInfo, or non-XML body | ⓘ blue | `error.notHikvision.*` | `Use ONVIF fallback` toggle |
| TLS not trusted | `NWError` TLS `errSSLXCertChainInvalid` / self-signed | 🔒 amber | `error.tlsUntrusted.*` | `Trust this device` (pins the SPKI hash for this camera only) |
| RTSP port closed but HTTP open | 554 refused, 80 ok | ⚠ amber | `error.rtspBlocked.*` | `Try port 8554`, `Use TCP`, `Check the device's RTSP setting` |
| Unsupported codec | SDP has neither H.264/H.265/MJPEG | ⚠ amber | `error.codecUnsupported.*` | `Switch this channel to H.264 in the web UI` |
| Wrong channel | DESCRIBE 404 on the path | ⚠ amber | `error.channelMissing.*` | `Detect channels` |
| Too many streams on device | RTSP 453 / `Not Enough Bandwidth` | ⚠ amber | `error.deviceBusy.*` | `Use the sub-stream`, `Retry` |

Every reason renders as a single sentence in the row plus a `Details` disclosure with the raw
status line (redacted) for support. Failure never produces a modal alert during discovery.

### 8.5 CSV import

- File ▸ Import Cameras from CSV… (⇧⌘I) or the `Import CSV…` button. `NSOpenPanel` limited to
  `UTType.commaSeparatedText`, `UTType.tabSeparatedText`, `UTType.plainText`.
- Header row required (case-insensitive, order-free). Recognised columns:
  `name, host, rtsp_port, http_port, tls, username, password, channel, stream, transport, group,
  color`. Unknown columns are ignored (listed in the preview). Missing optional columns take the
  manual-form defaults.
- Delimiter auto-detected (`,` `;` `\t`), encoding sniffed (UTF-8, UTF-16 BOM, CP1251 for Russian
  exports from other VMS tools).
- A **dry-run preview table** appears before anything is written: one row per line with a status
  chip — `New`, `Duplicate (host+channel exists)`, `Invalid: {reason}` — and editable cells for
  quick fixes. Footer: `"18 new · 3 duplicates · 1 invalid"`, checkbox `Skip duplicates` (default
  on), `Import 18`.
- Passwords in CSV go straight to the Keychain and the source file is never copied. A note in the
  sheet says exactly that (`import.csv.passwordNote.body`).
- Export (File ▸ Export Configuration…, ⌥⌘E) writes the same schema **without passwords** by
  default, with a checkbox "Include passwords (encrypted with a password you choose)" producing an
  encrypted `.vigilconfig` bundle instead of CSV.

---

## 9. Events

### 9.1 Feed (Stage route `events`)

```
Events                     [ All ▾ ] [ Cameras ▾ ] [ Today ▾ ]   ⊞ / ☰   Clear   Export CSV
──────────────────────────────────────────────────────────────────────────────────────────
Today
 ┌──────┐  Motion · Front Door                                   10:14:38   ▶  ⤢  ⌫
 │ thumb│  3 s · 2 boxes                                          just now
 └──────┘
 ┌──────┐  Line crossing · Side Gate                             09:52:07   ▶  ⤢  ⌫
 │ thumb│  Rule "Driveway A→B"                                    22 min ago
 └──────┘
 ┌──────┐  Video loss · Hallway                                   09:31:00   ▶      ⌫
 │ thumb│  Recovered after 41 s                                    43 min ago
 └──────┘
Yesterday …
```

- Two presentations: **list** (☰, 56 pt rows, 96×54 thumbnails) and **grid** (⊞, 200 pt cards with
  a 16:9 thumbnail, type chip, camera name, time). Toggle persisted per window.
- Filters: type (multi-select chips with counts: Motion, Line crossing, Intrusion, Tamper, Video
  loss, Disk error), cameras (multi-select popover), time range (Today / Last 24 h / Last 7 days /
  Custom…). Filters compose and appear as removable chips. The sidebar Events badge counts *unread*
  events (events newer than `lastEventsViewedAt`), and clearing happens on view, not on click.
- Row actions: `▶` opens Playback at `timestamp − 5 s` (`⌘⏎` opens in a new window), `⤢` opens the
  full-size snapshot in Quick Look, `⌫` deletes the record (local only — never touches the device).
- Selection + ⌘C copies a text summary; ⌘⏎ = play; Space = Quick Look; ↑↓ navigate; type-ahead
  jumps by camera name.
- Live insertion: new events slide in at the top (`VTheme.Motion.standard`, 220 ms) **only when the
  list is scrolled to the top**; otherwise a floating pill `"3 new events ↑"` appears at the top
  centre and taps scroll-to-top (the classic "don't move content under the reader" rule).
- Empty: `empty.events.title` "No events yet." / body with a link to enable motion detection.

### 9.2 Notifications

- `UNUserNotificationCenter` local notifications (permission asked on first *enable*, never at
  launch — with a pre-explain card in Settings ▸ Notifications).
- Content: title `"Motion · Front Door"`, body `"10:14:38"`, `UNNotificationAttachment` with the
  JPEG thumbnail, category `VIGIL_EVENT` with actions **View** (opens Playback at the moment) and
  **Snooze camera 30 min**. `threadIdentifier = camera.id.uuidString` so the system groups per
  camera. `interruptionLevel = .active` (`.timeSensitive` for tamper/video-loss/disk-error).
- Rate limiting: at most 1 notification per camera per 60 s (configurable 15–600 s), plus a global
  cap of 20/hour; suppressed events still land in the feed. A suppressed burst produces one summary
  notification `"12 motion events · Front Door"`.
- Per-camera and per-type toggles live in Settings ▸ Notifications; a Do-Not-Disturb-respecting
  "Quiet hours" range is available.

### 9.3 Watch mode

`AppModel.watchMode ∈ { off, toast, overlay }` — set in the toolbar `⋯` menu and Settings.

| Mode | Behaviour on a motion event |
|---|---|
| `off` | feed + badge only |
| `toast` (default) | a 320 pt `VToast` slides in bottom-trailing: 64×36 thumbnail, `"Motion · Front Door"`, relative time, buttons `Show` / `Dismiss`. Dwell 4 s, hover pauses the dwell, max 3 stacked (older ones collapse into `"+4 more"`). Clicking `Show` focuses that camera's tile (assigning it to a cell if absent). |
| `overlay` | the event camera is promoted: in `single`/hero modes it takes the hero cell for 20 s (with a 2 pt `motion`-coloured tile ring and a countdown pip), then returns. In grid modes only the ring + a corner chip appears. Promotion is suppressed while the user is interacting (8 s window) and while a tile is fullscreen. |

Motion boxes (ISAPI region data mapped from the 0–1000 space, `spec-render.md`) draw for 1.5 s per
event with a 0.3 s fade, `motion` colour at 70 %, 1.5 pt stroke, no fill.

---

## 10. Command palette (⌘K)

### 10.1 Anatomy

```
                    ┌────────────────────────────────────────────────────┐
                    │ ⌘  front do|                                   ⎋   │  56pt input row
                    ├────────────────────────────────────────────────────┤
                    │ CAMERAS                                            │  22pt section header
                    │ ┌──┐ Front Door                       [thumb]  ⏎   │  44pt row (selected)
                    │ │▣ │ 192.168.1.64 · Live · H.265 · Perimeter       │
                    │ └──┘                                               │
                    │  ▣  Front Gate                        [thumb]      │
                    │     192.168.1.71 · Offline                         │
                    │ ACTIONS                                            │
                    │  ◎  Snapshot “Front Door”                    ⇧⌘S   │
                    │  ●  Start Recording “Front Door”              ⌘R   │
                    │  ⌖  PTZ Preset ▸ “Front Door”                      │
                    │ LAYOUTS                                            │
                    │  ⊞  Switch to 3×3                             ⌘4   │
                    ├────────────────────────────────────────────────────┤
                    │ ⏎ Run   ⌘⏎ New window   ⇥ Filter   ⌥⏎ Reveal       │  28pt footer hint row
                    └────────────────────────────────────────────────────┘
                     640pt wide, top offset 88pt, max height 420pt
```

- Container: `VTheme.Elevation.4` glass (material + 1 px top inner highlight + hairline stroke),
  radius 14, shadow `0 24 60 rgba(0,0,0,0.45)`. Backdrop: window content dimmed to 55 % with a
  6 pt blur, click-outside dismisses.
- Open: scale 0.97→1.0 + opacity + blur-in over 180 ms (`VTheme.Motion.standard`); close: 120 ms
  ease-out, no scale. `reduceMotion` → opacity only.
- Input row: `command` glyph, 17 pt text field, live scope chip when a mode prefix is active,
  trailing `⎋` keycap. Placeholder: `palette.placeholder` = "Search cameras, actions, layouts…".
- Rows: 44 pt; 20 pt leading icon in a 28 pt rounded container tinted by category; title (Body,
  matched ranges in accent semibold); subtitle (Caption1, tertiary, 1 line, ellipsis middle for
  paths); trailing zone = live 40×22 thumbnail (cameras) **or** `VKeyCap` shortcut **or** `▸` for
  submenus. Selected row: accent fill 12 %, 1 pt accent inner stroke, and the icon container fills
  with accent.
- Max 9 rows visible, scrolls with ↑↓ (selection scrolls into view, never wraps past the ends);
  section headers are sticky.
- Footer hints change with the selected row's capabilities.

### 10.2 Modes (prefix filters, also reachable with ⇥ on the empty field)

| Prefix | Scope | Example |
|---|---|---|
| *(none)* | everything, ranked | `front` |
| `>` | actions only | `>rec` |
| `@` | cameras only | `@gate` |
| `#` | layouts & presets | `#3x3` |
| `:` | PTZ presets of the focused camera | `:gate` |
| `/` | events (last 500) | `/motion` |
| `?` | help & shortcuts | `?export` |
| `=` | settings panes & individual settings | `=latency` |

Empty query shows: **Recent** (last 5 invoked items) then **Suggested** (context-aware: if a camera
is focused → its snapshot/record/PTZ actions; if degraded cameras exist → "Run Stream Doctor";
always → "Add Camera", "Switch Layout"). Never an empty palette.

### 10.3 Ranking algorithm (normative)

Items are pre-indexed once and re-indexed on library change. Each item exposes an ASCII-folded,
lowercased `haystack` (`title + "\u{1}" + subtitle + "\u{1}" + keywords`) plus per-character
metadata (`isWordStart`).

```swift
public struct PaletteItem: Identifiable, Sendable {
    public let id: String                 // stable: "camera:<uuid>", "action:snapshot", …
    public let category: PaletteCategory  // camera, action, layout, preset, event, setting, help
    public let title: String
    public let subtitle: String
    public let keywords: [String]         // synonyms incl. Russian: ["снимок","screenshot","photo"]
    public let shortcut: KeyboardShortcutSpec?
    public let isAvailable: Bool          // false ⇒ dimmed + reason
    public let unavailableReason: String?
    let folded: [UInt8]                   // precomputed
    let wordStarts: Set<Int>
}

public struct MatchResult { public let score: Int; public let ranges: [Range<Int>] }

/// Greedy forward scan with limited backtracking (≤ 32 restarts). O(n·m) worst case, O(n) typical.
func score(query q: [UInt8], item: PaletteItem, now: Date, usage: UsageStats) -> MatchResult? {
    guard !q.isEmpty else { return MatchResult(score: baseline(item, usage, now), ranges: []) }
    guard let m = bestMatch(q, item.folded, item.wordStarts) else { return nil }

    var s = 0
    s += m.matched * 12                       // every matched character
    s += m.consecutiveRuns.reduce(0) { $0 + max(0, ($1 - 1)) * 18 }   // adjacency bonus
    s += m.wordStartHits * 25                 // matched at a word boundary
    if m.first == 0 { s += 40 }               // matched the very first character
    s -= min(60, m.gaps * 2)                  // skipped characters
    s -= Int(Double(item.folded.count - m.last) * 0.5)   // unmatched tail
    if item.folded.starts(with: q) { s += 400 }          // prefix of the title
    if titleEquals(item, q) { s += 1000 }                // exact title
    if isAcronym(q, item) { s += 350 }                   // "fd" → "Front Door"
    if m.inSubtitleOnly { s = Int(Double(s) * 0.55) }    // subtitle matches rank below title
    s = Int(Double(s) * item.category.weight)            // camera 1.05, action 1.00, layout 0.95,
                                                         // preset 0.95, event 0.90, setting 0.85, help 0.75
    s += min(120, Int(40 * log2(1 + Double(usage.count(item.id)))))   // frecency: frequency
    s += Int(80 * exp(-usage.age(item.id) / (7 * 86_400)))            // frecency: recency
    if item.category == .camera, item.isLive { s += 30 }              // live cameras first
    if !item.isAvailable { s = Int(Double(s) * 0.35) }
    return s >= 30 ? MatchResult(score: s, ranges: m.ranges) : nil
}
```

Ordering: `score` desc → title length asc → `title` localized asc → `id` asc (fully deterministic;
no visual instability while typing). Results are capped at 50 and grouped by category, with
categories ordered by their best member's score.

Performance contract: 2 000 items scored in **< 2 ms** on an M1 (measured in
`PaletteRankingTests.testScoreThroughput`). Scoring is synchronous on the main actor — the palette
must feel like a text field, and a `Task` hop would cost a frame. Above 5 000 items, scoring moves
to a detached task with a 1-frame debounce (documented as the only exception).

### 10.4 Actions inventory (P0)

| Category | Items |
|---|---|
| Cameras | every camera (jump / assign / focus). ⌘⏎ = open Playback, ⌥⏎ = reveal in sidebar |
| Actions | Snapshot, Snapshot All, Start/Stop Recording, Record All, Mute/Unmute, Mute All, Two-Way Audio, Reconnect, Request Keyframe, Quality ▸ Auto/Main/Sub/Third, Transport ▸ TCP/UDP, Toggle Sidebar, Toggle Inspector, Cinema Mode, Picture in Picture, Video Wall, Cycle Cameras, Add Camera, Discover Cameras, Import CSV, Export Configuration, Export Diagnostics, Run Stream Doctor, Open Recordings Folder, Open Settings, Check for Updates, Quit |
| Layouts | the 8 modes + every saved preset + "Edit Mosaic", "Save Layout as Preset…" |
| Presets | PTZ presets 1–255 of the focused camera, patrols, Home, Set Home |
| Events | the last 500 events (`"Motion · Front Door · 10:14"`) → jump to playback |
| Settings | every settings pane + high-value individual settings (latency preset, hardware decode, substream in grid, launch at login) |
| Help | every shortcut (executes it), Vigil Help, Release Notes, Report an Issue |

Submenu items (`▸`) push a second level inside the palette (breadcrumb chip in the input row,
`⌫` on an empty field pops back).

---

## 11. Keyboard shortcuts & menu bar

### 11.1 Complete shortcut table

Scope: **G** = global to the app, **M** = main window, **P** = playback window, **T** = a focused
tile, **S** = sidebar focused, **L** = timeline focused, **K** = palette open.

| Shortcut | Scope | Action |
|---|---|---|
| ⌘K | G | Open command palette |
| ⌘, | G | Settings |
| ⌘Q | G | Quit (confirms if recording, §14 `confirm.quitWhileRecording.*`) |
| ⌘H / ⌥⌘H | G | Hide / Hide others |
| ⌘W | G | Close window |
| ⌥⌘W | G | Close all windows |
| ⌘M | G | Minimize |
| ⌘N | G | Add camera… |
| ⇧⌘N | G | Discover cameras… |
| ⇧⌘I | G | Import cameras from CSV… |
| ⌥⌘E | G | Export configuration… |
| ⇧⌘O | G | Open recordings folder |
| ⌥⌘D | G | Run Stream Doctor… |
| ⌘? | G | Vigil Help |
| ⌘/ | G | Keyboard shortcuts cheat sheet |
| ⌘1 … ⌘8 | M | Layout: single, 2×2, 1+5, 3×3, 4×4, 1+7, 2+8, custom mosaic |
| ⌘9 | M | Apply layout preset 1 (hold to open the preset menu) |
| ⌥⌘8 | M | Edit mosaic |
| ⌘Y | M | Cycle cameras (patrol) on/off |
| ⌥⌘Y | M | Cycle dwell menu |
| ⌘F | M/T | Fullscreen the focused tile (solo) |
| ⌃⌘F | M | Cinema mode (macOS full screen, chrome hidden) |
| ⌃⌘P | M | Picture in Picture for the focused camera |
| ⌃⌘W | M | Video wall on second display |
| ⌘L | M | Show/hide sidebar |
| ⌥⌘L | M | Sidebar as icon rail |
| ⌥⌘I | M | Show/hide inspector |
| ⌃1 … ⌃6 | M | Inspector tab: Info, Stream, PTZ, Image, Events, Recording |
| ⌘= / ⌘- | M/T | Digital zoom in / out (focused tile) |
| ⌘0 | M/T | Reset digital zoom / actual size |
| ⌥← ⌥→ ⌥↑ ⌥↓ | M | Move tile focus |
| ⇥ / ⇧⇥ | M | Next / previous tile (then sidebar, inspector) |
| ⏎ | M/T | Filled cell: select camera. Empty cell: open the camera picker |
| ⌫ | M/T | Clear the focused cell |
| / | M | Focus the search field |
| ⌥⌘F | M | Open the sidebar filter menu |
| ⌥N / ⌥S / ⌥T / ⌥B | M | Toggle overlays: name chip, stats, timestamp, motion boxes |
| ⌃⌘H | M | Pin tile controls for the focused tile |
| ⇧⌘S | T | Snapshot the focused camera |
| ⌥⇧⌘S | M | Snapshot all live cameras |
| ⌘R | T | Start/stop recording the focused camera |
| ⌥⌘R | M | Start/stop recording all live cameras |
| ⌃⌘R | T | Reconnect now |
| ⌥⌘M | T | Mute/unmute the focused camera |
| ⇧⌥⌘M | M | Mute all |
| T (hold) | T | Push-to-talk (two-way audio) |
| ⌃⌘T | T | Toggle two-way audio latched |
| ⌥1 / ⌥2 / ⌥3 / ⌥0 | T | Quality: main / sub / third / auto |
| ⌃⌘1 / ⌃⌘2 | T | Transport: TCP / UDP |
| ← → ↑ ↓ | T | PTZ pan/tilt (hold = continuous) |
| ⇧ + arrows | T | PTZ at max speed |
| ⌥ + arrows | T | PTZ fine step *(⌥+arrows moves tile focus when the tile has no PTZ)* |
| - / = | T | PTZ zoom out / in |
| [ / ] | T | Focus near / far |
| ; / ' | T | Iris close / open |
| H | T | PTZ home |
| 1 … 9 | T | Recall PTZ preset 1–9 |
| ⇧1 … ⇧9 | T | Store PTZ preset 1–9 (confirm) |
| ⌥⌘P | G | Open playback for the selection |
| Space | P | Play / pause |
| K | P | Pause / normal speed |
| J / L | P | Shuttle reverse / forward (repeat to accelerate) |
| ← / → | P/L | Back / forward 10 s |
| ⇧← / ⇧→ | P/L | Back / forward 1 min |
| ⌥← / ⌥→ | P/L | Frame step |
| ⌘← / ⌘→ | P/L | Previous / next recording segment |
| , / . | P/L | Previous / next event marker |
| ⇧, / ⇧. | P | Slower / faster |
| Home / End | L | Day start / day end |
| ⌘G | P | Go to date/time… |
| ⇧⌘G | P | Go to now (live edge) |
| B | P | Add bookmark at the playhead |
| I / O | P | Set in / out point |
| ⌃⌘X | P | Clear in/out selection |
| ⌘E | P | Export clip… |
| ⇧⌘Y | P | Toggle synchronized cameras |
| ⌘= / ⌘- | L | Timeline zoom in / out |
| ⌘0 | L | Fit the day |
| ↑ ↓ | S/K | Move selection |
| ⏎ | S | Rename inline (sidebar) / run (palette) |
| ⌘⏎ | K | Run in a new window |
| ⌥⏎ | K | Reveal / secondary action |
| ⇥ | K | Enter the selected scope filter |
| Esc | G | See the precedence chain below |

**Esc precedence** (first applicable wins): dismiss palette → cancel an in-progress drag →
close the topmost popover/sheet → exit tile fullscreen → exit cinema mode → clear the in/out
selection → clear search text → blur the focused text field → clear multi-selection → nothing
(never closes the window).

### 11.2 Menu bar structure

Every shortcut above appears in exactly one menu item. Items disabled by context show the reason
in their tooltip.

```
Vigil        About Vigil · Check for Updates… · ─ · Settings… ⌘, · ─ · Services ▸ · ─ ·
             Hide Vigil ⌘H · Hide Others ⌥⌘H · Show All · ─ · Quit Vigil ⌘Q

File         Add Camera… ⌘N · Discover Cameras… ⇧⌘N · Import Cameras from CSV… ⇧⌘I ·
             Export Configuration… ⌥⌘E · ─ · Open Playback ⌥⌘P · Open Recordings Folder ⇧⌘O · ─ ·
             Save Snapshot ⇧⌘S · Save Snapshot of All Cameras ⌥⇧⌘S · ─ ·
             Close Window ⌘W · Close All Windows ⌥⌘W

Edit         Undo ⌘Z · Redo ⇧⌘Z · ─ · Cut ⌘X · Copy ⌘C · Paste ⌘V · Delete ⌫ · Select All ⌘A · ─ ·
             Rename ⏎ · ─ · Find ▸ (Search Cameras /, Filter… ⌥⌘F) · ─ · Emoji & Symbols

View         Command Palette ⌘K · ─ ·
             Layout ▸ (Single ⌘1, 2×2 ⌘2, 1+5 ⌘3, 3×3 ⌘4, 4×4 ⌘5, 1+7 ⌘6, 2+8 ⌘7,
                       Custom Mosaic ⌘8, Edit Mosaic ⌥⌘8, ─, Presets ▸ …, Save as Preset…,
                       Manage Presets…) ·
             Cycle Cameras ⌘Y · Cycle Dwell ▸ (5/10/15/30/60 s, Custom…) · ─ ·
             Fullscreen Tile ⌘F · Cinema Mode ⌃⌘F · Picture in Picture ⌃⌘P ·
             Video Wall ▸ (On Display 2 ⌃⌘W, Choose Display…, Wall Layout ▸) · ─ ·
             Zoom In ⌘= · Zoom Out ⌘- · Actual Size ⌘0 · ─ ·
             Show Sidebar ⌘L · Sidebar as Icons ⌥⌘L · Show Inspector ⌥⌘I ·
             Inspector Tab ▸ (Info ⌃1 … Recording ⌃6) · ─ ·
             Tile Overlays ▸ (Camera Name ⌥N, Stats ⌥S, Timestamp ⌥T, Motion Boxes ⌥B,
                              Pin Tile Controls ⌃⌘H) · ─ ·
             Appearance ▸ (System, Light, Dark) · Customize Toolbar…

Camera       Connect · Disconnect · Reconnect Now ⌃⌘R · ─ ·
             Snapshot ⇧⌘S · Start Recording ⌘R · Record All ⌥⌘R · ─ ·
             Audio ▸ (Mute ⌥⌘M, Mute All ⇧⌥⌘M, Volume ▸, Two-Way Audio ⌃⌘T) · ─ ·
             Quality ▸ (Auto ⌥0, Main ⌥1, Sub ⌥2, Third ⌥3) ·
             Transport ▸ (TCP ⌃⌘1, UDP ⌃⌘2) · Request Keyframe · ─ ·
             PTZ ▸ (Up ↑, Down ↓, Left ←, Right →, Zoom In =, Zoom Out -, Focus Near [,
                    Focus Far ], Iris Open ', Iris Close ;, Home H, ─, Presets ▸ 1–9,
                    Store Preset ▸, Patrols ▸) · ─ ·
             Image Settings… ⌃4 · Edit Camera… ⌘I · ─ ·
             Run Stream Doctor… ⌥⌘D · Copy Diagnostics · ─ ·
             Disable Camera · Delete Camera… ⌫

Playback     Open Playback ⌥⌘P · Go to Date… ⌘G · Go to Now ⇧⌘G · ─ ·
             Play/Pause Space · Normal Speed K · Reverse J · Forward L · ─ ·
             Back 10 Seconds ← · Forward 10 Seconds → · Back 1 Minute ⇧← · Forward 1 Minute ⇧→ ·
             Step Backward ⌥← · Step Forward ⌥→ · ─ ·
             Previous Segment ⌘← · Next Segment ⌘→ · Previous Event , · Next Event . · ─ ·
             Slower ⇧, · Faster ⇧. · Speed ▸ (0.25× … 8×) · ─ ·
             Set In Point I · Set Out Point O · Clear Selection ⌃⌘X · Export Clip… ⌘E · ─ ·
             Add Bookmark B · Synchronize Cameras ⇧⌘Y

Window       Minimize ⌘M · Zoom · ─ · Vigil · Video Wall ⌃⌘W · Discovery ⇧⌘N · Playback ▸ (open
             playback windows) · ─ · Bring All to Front

Help         Vigil Help ⌘? · Keyboard Shortcuts ⌘/ · ─ · Run Stream Doctor… ⌥⌘D ·
             Export Diagnostics… · ─ · Release Notes · Report an Issue…
```

`SwiftUI` implementation: `CommandMenu("Camera")`, `CommandMenu("Playback")`, plus
`CommandGroup(replacing: .newItem)`, `.textEditing`, `.sidebar`, `.toolbar`, `.windowList`,
`.help`, `.appInfo`, `.appSettings`. Enablement is driven by `@FocusedValue`:

```swift
struct ActiveCameraKey: FocusedValueKey { typealias Value = CameraContext }
extension FocusedValues { var activeCamera: CameraContext? { get { self[ActiveCameraKey.self] } set { … } } }

// StageView:
.focusedSceneValue(\.activeCamera, CameraContext(camera: focusedCamera, controller: controller))
// VigilCommands:
@FocusedValue(\.activeCamera) private var active
Button("Snapshot") { active?.snapshot() }.disabled(active == nil).keyboardShortcut("s", modifiers: [.shift, .command])
```

### 11.3 Cheat sheet (⌘/)

An in-window overlay (same glass recipe as the palette, 720 pt wide, up to 560 pt tall) with a
3-column grid of `VKeyCap` + label grouped by scope, a search field, and a `Customize…` button that
opens Settings ▸ Shortcuts. It renders **live from the shortcut registry**, so a rebound key is
always shown correctly. Printable via ⌘P.

### 11.4 Rebindable shortcuts

```swift
public struct ShortcutSpec: Codable, Hashable, Sendable {
    public var key: String                       // "s", "1", "left", "space"
    public var modifiers: EventModifiers         // stored as a raw bitmask
}
public enum ShortcutAction: String, Codable, CaseIterable, Sendable { case snapshot, record, palette, … }

@MainActor @Observable public final class ShortcutStore {
    public private(set) var bindings: [ShortcutAction: ShortcutSpec]   // defaults ⊕ overrides
    public func rebind(_ action: ShortcutAction, to spec: ShortcutSpec) -> RebindResult
    public func reset(_ action: ShortcutAction); public func resetAll()
}
public enum RebindResult { case ok, conflict(with: ShortcutAction), reserved(String) }
```

- Menu items read `shortcuts.bindings[action]` so a rebind updates the menu immediately (the
  `Commands` builder observes `ShortcutStore`).
- Reserved and rejected: ⌘Q, ⌘W, ⌘H, ⌘M, ⌘,, ⌘⇥, ⌘Space, and anything without a modifier **except**
  the documented tile/playback single keys.
- Conflicts are shown inline in Settings ▸ Shortcuts: the conflicting row highlights amber with
  `"Also used by {action}"` and a `Swap` / `Replace` choice; the store never allows a duplicate.
- **Implementation note (important):** unmodified single-key shortcuts (`/ B I O J K L H T`,
  digits, arrows) are **not** registered as menu `keyboardShortcut`s — they would steal keystrokes
  from text fields. They are handled with the macOS 14 `onKeyPress(_:phases:action:)` modifier on
  the focused surface (`StageView`, `TimelineView`, `SidebarView`), which respects text-field focus
  automatically. The menu item still *displays* the key via a trailing `Text` in its label.

---

## 12. States

Every state below is a *designed* state with exact copy, timing and recovery. The rule: **the UI
always tells the user what is happening, what it means, and what to do next.**

### 12.1 First run (no library file)

1. The main window opens at 1440×900 with the full chrome already in place: sidebar (empty
   sections), an empty `single` Stage, Inspector showing the System view. No modal.
2. The Stage shows the primary empty state (§12.2) with a subtle 24 s-loop ambient gradient
   (`reduceMotion` → static).
3. A one-time 320 pt **welcome card** slides up from the bottom-trailing after 400 ms:
   `firstRun.welcome.title` / `.body`, buttons `Find Cameras` (primary, opens Discovery) and
   `Add Manually`. `Esc` dismisses it permanently (recorded in `UserDefaults`).
4. Choosing `Find Cameras` shows the local-network permission pre-explain (§8.2 step 0) before any
   multicast is sent.
5. After the first camera is added, the card never appears again and a 2-step coach overlay runs
   once: a pointer-following callout on the layout picker ("Change layout — ⌘1 to ⌘8") and on the
   search field ("Press / to find any camera"). Both dismiss on any click, `Esc`, or after 6 s.

### 12.2 Empty states (`VEmptyState` catalogue)

| Where | Glyph | Title key | Body | Actions |
|---|---|---|---|---|
| Stage, no cameras | `video.slash` 44 pt | `empty.cameras.title` | `empty.cameras.body` | `Find Cameras` (primary), `Add Manually` |
| Sidebar Cameras section | — | `empty.cameras.sidebar` | — | inline `＋` |
| Sidebar Groups | `folder.badge.plus` 22 pt | `empty.groups.title` | drag hint | — |
| Events feed | `bell.slash` 44 pt | `empty.events.title` | `empty.events.body` | `Notification Settings` |
| Recordings | `film.stack` 44 pt | `empty.recordings.title` | `empty.recordings.body` | `Open Recordings Folder` |
| Playback, day with no recordings | `calendar.badge.exclamationmark` 36 pt | `empty.playbackDay.title` | `empty.playbackDay.body` (names the nearest day that has footage) | `Go to {date}` |
| Bookmarks | `bookmark.slash` 44 pt | `empty.bookmarks.title` | `"Press B while reviewing footage."` | — |
| Search with no match | `magnifyingglass` 36 pt | `empty.search.title` | — | `Clear Filters` |
| Discovery, nothing found | `wifi.exclamationmark` 44 pt | `empty.discovery.title` | `empty.discovery.body` (lists the 3 usual causes) | `Scan Again`, `Add Manually` |
| Palette, no match | — | `empty.palette.title` | — | — |

Empty states are centred in their region, max 320 pt wide, and never scroll. Titles are Headline,
bodies Callout/secondary, max 2 lines.

### 12.3 Scanning

Determinate where possible (`n/total` hosts), plus per-probe ticks (§8.2). Never a bare spinner.
Cancel is always available and takes effect within 200 ms (sockets are cancelled, not awaited).

### 12.4 Connecting

Tile shows: true-black background, name chip, amber breathing dot, a `VSkeleton` shimmer at 6 %
white sweeping every 1.6 s, and — when we have one — the **cached last frame at 22 % opacity with a
4 pt blur** behind the shimmer. Centre narration text (Caption1, secondary, `monospacedDigit`
elapsed after 700 ms) follows `StreamEvent`:

| `StreamController` state | Narration key | Shown from |
|---|---|---|
| `resolving` | `connecting.resolving` "Looking up {host}…" | 250 ms |
| `connecting` | `connecting.connecting` "Connecting…" | 250 ms |
| `authenticating` | `connecting.auth` "Signing in…" | immediately on entry |
| `describing` | `connecting.negotiating` "Negotiating stream…" | immediately |
| `settingUp` | `connecting.opening` "Opening video channel…" | immediately |
| waiting for first RTP | `connecting.waitingData` "Waiting for video…" | immediately |
| waiting for keyframe | `connecting.waitingKeyframe` "Waiting for a keyframe…" | immediately |
| > 3.5 s in any state | `connecting.slow` "This is taking longer than usual." + `Run Stream Doctor` link | 3500 ms |
| > 8 s | transition to the failure card (§12.7) with the doctor's finding preloaded | 8000 ms |

Timing details are normative — see §15.1.

### 12.5 Degraded

Trigger (from `HealthMonitor`, evaluated on a 3 s sliding window): packet loss > 1.5 %, **or**
jitter > 80 ms, **or** decode queue > 8 frames, **or** fps < 60 % of the negotiated rate for 3 s.

- Tile: 1 pt `warn` stroke, amber static dot, and a **32 pt bottom banner** inside the tile with the
  measured cause: `degraded.packetLoss.body` "3.1 % packet loss — video may stutter." plus an
  action chip when we can act: `Switch to TCP` / `Use sub-stream` / `Dismiss`.
- Automatic remediation (Settings ▸ Streams ▸ "Recover automatically", default on): after 6 s of
  degradation on UDP we switch to TCP once and the banner becomes
  `degraded.switchedToTCP.body` "Switched to TCP for stability." (informational, 4 s, then fades).
  We never oscillate: at most one automatic transport change per 10 min per camera.
- Sidebar row: amber dot + amber-stroked badge. Footer aggregate turns amber.
- The banner is suppressed in the Video Wall (a 4 pt amber corner triangle is used instead) so the
  wall stays clean.

### 12.6 Offline / reconnecting

```
┌───────────────────────────────────────┐
│ ▎Front Door                       ○   │
│         [ last frame, 30% opacity,    │
│           4pt blur, grayscale 60% ]   │
│                                       │
│            ⚠  Connection lost         │  Headline
│      Reconnecting in 4 s (attempt 3)  │  Caption1 secondary, monospacedDigit
│         [ Retry now ]  [ Diagnose ]   │  ghost buttons, 24pt
│            Last seen 10:14:38         │  Caption2 tertiary
└───────────────────────────────────────┘
```

- The countdown is driven by `StreamController`'s backoff (0.5, 1, 2, 4, 8, 15, 30 s ±20 % jitter,
  `spec-core.md`) and displays whole seconds, updating at 1 Hz — never a spinner.
- `Retry now` cancels the wait and retries immediately. `Diagnose` runs Stream Doctor in a 420 pt
  sheet with the step-by-step result list.
- After 5 consecutive failures the copy changes to `offline.persistent.body` "Still can't reach
  this camera." and the retry interval pins at 30 s; the tile stays in this state indefinitely
  (never blank, never removed).
- Network came back (`NWPathMonitor`): all offline cameras retry immediately, countdowns collapse,
  and a single toast reads `network.restored.body` "Network back — reconnecting 6 cameras."

### 12.7 Authentication failure

Distinct from offline: red dot with `!`, red 1 pt tile stroke, and **no automatic retry** (retrying
a wrong password is how devices lock out — this is a deliberate, important behaviour).
Copy: `error.auth.wrongPassword.title` + body, actions `Update Password…` (a 320 pt inline sheet
with just the password field and `Save & Reconnect`) and `Diagnose`. When the device reports a lock
(`userLocked`), copy switches to `error.auth.locked.*` with the remaining time and retry is
disabled until it elapses (a live countdown).

### 12.8 Storage

| Condition | UI |
|---|---|
| Free space < 10 GB | Persistent 28 pt window banner above the Stage: `storage.low.body` "Only 8.2 GB left on Macintosh HD." + `Manage Recordings…` (opens Settings ▸ Recording). Amber. |
| Free space < 2 GB or write error | Recording stops on all cameras. Red banner `storage.full.title` / `.body`, actions `Reveal Folder`, `Change Folder…`, `Delete Oldest 20 Clips…`. A notification is posted even if the app is inactive. |
| Retention deleted files | Silent, but Settings ▸ Recording shows "Last cleanup: today, 12 clips (4.1 GB)". |
| Device (NVR) disk error event | Event feed + notification `event.diskError.*`; the camera's Info ▸ Storage row turns red. |

### 12.9 Decode budget exhausted

When `StreamCoordinator` cannot admit a stream: the tile renders its cached frame (or black) with a
centred chip `budget.paused.title` "Paused to save power" + Caption2 "Too many streams for
hardware decode." and actions `Use sub-stream` / `Settings…`. The tile is *not* an error state
(grey, not amber). Focusing a paused tile promotes it immediately (the lowest-priority tile is
demoted) — the user's attention always wins.

### 12.10 Inactive, occluded, background

| Situation | Detection | Behaviour |
|---|---|---|
| Window inactive (another app in front) | `NSApplication.didBecomeActive/ WillResignActive` | sidebar thumbnails 1 Hz → 0.25 Hz; sparkline redraws 4 Hz → 1 Hz; video keeps running (an operator watching while typing elsewhere is a core use case) |
| Window occluded / minimised | `NSWindow.occlusionState` lacks `.visible` | all decode paused after 2 s (RTSP sessions stay alive with keepalives); the last frame is retained for instant resume; recording and event handling **continue** |
| Window closed, app running | scene teardown | streams stop; recordings continue to completion; menu-bar extra shows a live badge |
| Full screen on another Space | occlusion | same as occluded |
| Low Power Mode | `ProcessInfo.isLowPowerModeEnabled` | sub-stream everywhere, patrol dwell ×2, thumbnails 0.5 Hz, a one-time toast `power.lowPowerMode.body` |
| Resume | occlusion regains `.visible` | decode restarts with the cached frame visible; narration is skipped if the first new frame arrives within 400 ms (§15.2) |

### 12.11 Sleep / wake, display and network changes

| Event | Response |
|---|---|
| `NSWorkspace.willSleepNotification` | stop all decode, finish `.partial` recordings cleanly, keep the library saved, tear down sockets (do not wait for graceful `TEARDOWN` beyond 300 ms) |
| `didWakeNotification` | wait 800 ms for the network stack, then reconnect all enabled cameras in priority order with a 120 ms stagger; a single toast `system.wake.body` "Welcome back — reconnecting." |
| `NWPathMonitor` path change (Wi-Fi → Ethernet, VPN up) | immediate retry for offline cameras; live cameras are left alone unless their socket errors |
| Interface lost entirely | window banner `network.offline.body` "No network connection." with a live "Retrying…" pip; tiles enter offline state without countdown spam (one countdown in the banner) |
| Display added / removed | Stage re-layouts; `contentsScale` updated per `spec-render.md`; the Video Wall re-resolves its screen (§2.4) |
| Screen locked | treated as occluded |

### 12.12 Tile state → visual matrix (normative)

| State | Dot | Stroke | Content | Chrome | Auto-retry |
|---|---|---|---|---|---|
| `disabled` | hollow grey | subtle | black + `"Disabled"` chip | Enable button | no |
| `connecting` | amber breathing | subtle | ghost frame + shimmer + narration | none until live | n/a |
| `live` | green | subtle (hover: default) | video | on hover | n/a |
| `degraded` | amber | warn 1 pt | video + banner | on hover + banner | auto TCP once |
| `reconnecting` | grey | subtle | dimmed last frame + countdown | Retry / Diagnose | yes (backoff) |
| `authFailed` | red `!` | danger 1 pt | dimmed last frame + card | Update Password / Diagnose | **no** |
| `unsupported codec` | amber | warn | black + card naming the codec | Open Web UI / Diagnose | no |
| `budgetPaused` | grey | subtle | last frame + chip | Use sub-stream | n/a |
| `deviceBusy` | amber | warn | black + card | Use sub-stream / Retry | yes (30 s) |

---

## 13. Settings

`Settings { SettingsView() }` → a `TabView` with 7 panes, `.frame(width: 620)`, each pane a
`Form(.grouped)` sized to its content (heights 380–620 pt). ⌘, opens the last used pane
(`@AppStorage("settings.lastPane")`). Every control writes to `UserDefaults` immediately (no OK/
Apply); destructive actions confirm.

### 13.1 General

| Setting | Control | Default | Notes |
|---|---|---|---|
| Launch at login | toggle | off | `SMAppService.mainApp.register()`; shows the system error inline on failure |
| Open at login as | segmented Window / Menu bar only | Window | menu-bar-only hides the Dock icon (`NSApp.setActivationPolicy(.accessory)`) |
| Appearance | segmented System / Light / Dark | System | applies `NSApp.appearance` |
| Accent | 6 swatches + "Match system" | Vigil accent | affects focus rings and selection only |
| Sidebar thumbnails | toggle + rate picker (1 Hz / 0.5 Hz / off) | on, 1 Hz | off saves ~3 % CPU with 64 cameras |
| Time format | segmented System / 24-hour / 12-hour | System | all timestamps, timeline ruler, exports |
| Show seconds in overlays | toggle | on | |
| Units | segmented Auto / Metric / Imperial | Auto | only affects bitrate/size prefixes (Mb/s vs Mbps) and temperature if a device reports it |
| Language | picker: System / English / Русский | System | requires relaunch; shows `general.language.relaunch` note |
| Confirm before deleting cameras | toggle | on | |
| Menu-bar extra | toggle + "Show live count badge" | on / on | |
| Dock badge | picker None / Event count / Live count | Event count | |

### 13.2 Streams

| Setting | Control | Default | Notes |
|---|---|---|---|
| Default transport | segmented Auto / TCP / UDP | Auto | Auto = TCP, fall back to UDP on setup failure |
| Latency preset | segmented **Low / Balanced / Quality** | Balanced | drives the jitter-buffer target: Low = 60 ms, Balanced = 150 ms, Quality = 350 ms (exact values owned by `spec-rtp.md`); the pane shows the resulting target in ms live |
| Sub-stream in grids | toggle + threshold slider (tile long edge, 240–960 px) | on, 480 px | tiles smaller than the threshold use the sub-stream |
| Hardware decode | toggle | on | off shows a warning that CPU use will rise sharply |
| Max concurrent decodes | stepper 1–64 + "Automatic" | Automatic | Automatic = `min(32, cores × 2)` clamped by measured decode headroom |
| Pause hidden tiles | toggle | on | tiles hidden by solo/fullscreen pause after 2 s |
| Pause when window is occluded | toggle | on | |
| Audio | toggle "Play audio from the focused camera only" | on | prevents a wall of noise |
| Two-way audio input | device picker | System default | |
| Keepalive interval | stepper 5–120 s | 30 s | RTSP `GET_PARAMETER` / `OPTIONS` |
| Connect timeout | stepper 2–30 s | 8 s | matches §12.4 |
| Reconnect | toggle + max backoff picker (15/30/60 s) | on, 30 s | |
| Multicast | toggle "Prefer multicast when offered" | off | |
| TLS | toggle "Allow self-signed certificates for pinned devices" | on | pinning is per camera, set during the credential test |
| Stream quality override per camera | link → the camera list | — | |

### 13.3 Recording

| Setting | Control | Default |
|---|---|---|
| Recordings folder | path row + `Choose…` + `Reveal` | `~/Movies/Vigil` |
| Snapshots folder | path row | `~/Pictures/Vigil` |
| Container | segmented MP4 / MOV | MP4 |
| Filename template | text field + token menu + live preview | `{camera}_{yyyy}{MM}{dd}_{HH}{mm}{ss}` |
| Snapshot format | segmented PNG / JPEG / HEIC + quality slider | JPEG 0.9 |
| Snapshot destination | segmented File / Clipboard / Both | File |
| Burn in overlay on snapshots | toggle | off |
| Pre-roll buffer | slider 0–15 s | 5 s (memory cost shown live: `"≈ 46 MB for 16 cameras"`) |
| Post-roll | slider 5–120 s | 15 s |
| Auto-record on motion | toggle + per-camera override link | off |
| Motion cooldown | stepper 5–300 s | 20 s |
| Max clip length | picker 1/5/15/60 min | 5 min |
| Split long recordings | toggle | on (at max clip length, seamless) |
| Retention | segmented Never delete / Keep N days / Cap N GB + value | Never delete |
| Cleanup time | time picker | 03:00 |
| Fragmented MP4 for crash resilience | toggle | on |
| Free-space guard | stepper 2–100 GB | 10 GB warn / 2 GB stop |

Token menu for the template: `{camera}` `{group}` `{yyyy}` `{MM}` `{dd}` `{HH}` `{mm}` `{ss}`
`{host}` `{channel}` `{event}` `{n}`. Invalid characters are replaced with `-`; the preview shows
the resolved name and turns red on collision with an existing file (we then append `_2`).

### 13.4 Notifications

- Master toggle (asks for permission on first enable, with a pre-explain card).
- Per-type matrix: Motion, Line crossing, Intrusion, Tamper, Video loss, Disk error, Camera offline,
  Storage full — each with `Notify` / `Sound` / `Thumbnail` checkboxes.
- Per-camera exceptions list (add/remove; `Snooze until` per camera with a live countdown).
- Rate limit: per-camera minimum interval (15–600 s, default 60) and hourly cap (default 20).
- Quiet hours: from/to time pickers + weekday checkboxes; "Still notify for tamper and disk errors".
- Watch mode: segmented Off / Toast / Overlay + overlay duration (10/20/30 s).
- `Open System Notification Settings` button and a live status row showing the current authorization.

### 13.5 Shortcuts

- Searchable table: Action · Shortcut (`VKeyCap`) · Scope · Reset. Click a row → "Press the new
  shortcut" recording state (`onKeyPress` capture, `Esc` cancels, ⌫ clears).
- Conflicts and reserved keys per §11.4; a footer shows `"3 customised"` and `Reset All…`.
- Export/Import shortcut sets as JSON (useful for a team of operators).

### 13.6 Advanced

| Setting | Control | Default |
|---|---|---|
| Log level | picker Error / Warning / Info / Debug / Trace | Info (Debug and Trace warn about volume) |
| Log to file | toggle + `Reveal` (`~/Library/Logs/Vigil/`) | on, 7-day rotation, 64 MB cap |
| Redact in logs | read-only list: passwords, session ids, serials (masked), tokens | — |
| Export diagnostics… | button → saves `Vigil-Diagnostics-{date}.zip` and reveals it | — |
| Stream Doctor… | button | — |
| Show developer overlay | toggle (fps, dropped frames, decode ms, GPU ms per tile) | off |
| Metal renderer | picker Automatic / Metal / AVSampleBufferDisplayLayer | Automatic |
| ONVIF fallback | toggle "Try ONVIF for non-Hikvision devices" | on |
| ISAPI request timeout | stepper 2–30 s | 6 s |
| Discovery subnet limit | picker /24 /23 /22 | /24 |
| Reset layout | button (confirm) | — |
| Reset all settings… | button (confirm, keeps cameras) | — |
| Delete all data… | destructive button (double confirm, types "delete") | — |

### 13.7 About & updates

Icon, name, version + build, "Copyright", `Release Notes`, `Acknowledgements` (Apple frameworks
only — we say so proudly: `about.noDependencies.body` "Vigil uses no third-party code."),
`Check for Updates` (manual only; no telemetry, no auto-download without consent — state this in the
pane), and a `Report an Issue…` button that pre-fills a diagnostics-attached mail draft.

---

## 14. Copy & tone

### 14.1 Rules

1. **Say what happened, then what to do.** Title = the fact (≤ 6 words). Body = the cause and the
   next step (≤ 2 sentences, ≤ 140 chars).
2. **Second person, active voice, present tense.** "Vigil can't reach this camera." not "The camera
   could not be reached."
3. **No jargon unless it is the actual fix.** "RTSP port 554 is closed" is fine (it is actionable);
   "DESCRIBE returned 451" is not — put that in `Details`.
4. **Numbers are specific.** "3.1 % packet loss", "8.2 GB left", "attempt 3". Never "some", "a lot".
5. **No blame, no apology, no exclamation marks.** Never "Oops", "Sorry", "Something went wrong".
6. **Buttons are verbs** naming the outcome: `Update Password`, `Switch to TCP`, `Delete 12 Clips`.
   Never `OK` where a verb exists; `Cancel` is always `Cancel`.
7. **Destructive confirmations name the object and the count** and use a destructive-styled verb.
8. **Sentence case everywhere** except product names (Vigil, Hikvision, ONVIF, ISAPI, Keychain).
9. **Units**: `Mb/s` for bitrate, `MB`/`GB` for size, `ms` for latency, `%` with a space in Russian
   (`3,1 %`) and without in English (`3.1%`) — handled by `NumberFormatter`, never hard-coded.
10. **Never a dead end.** Every error names at least one action, even if it is `Diagnose`.
11. **Never interrupt live video with a modal.** Errors are inline (tile, banner, toast). Modals are
    reserved for destructive confirmation and credential entry.
12. **Time**: relative under 1 hour (`"4 min ago"`), absolute after (`"10:14"`, `"26 Jul 10:14"`),
    always formatted with `Date.FormatStyle` + the user's locale and 12/24-h preference.

### 14.2 Key structure (localization-ready)

`Localizable.xcstrings` (String Catalog), one file per module, keys in the form:

```
<surface>.<subject>.<variant>.<part>
      │        │         │        └── title | body | action | actionSecondary | hint | note
      │        │         └────────── optional qualifier (wrongPassword, locked, low, full)
      │        └──────────────────── subject noun (camera, storage, auth, event, layout)
      └───────────────────────────── surface (error, empty, confirm, toast, state, settings,
                                     discovery, playback, palette, menu, a11y, unit)
```

Rules that exist **because Russian is required**:

- **Never concatenate.** Every sentence is one key with positional arguments (`%1$@`, `%2$lld`) so
  translators can reorder freely.
- **Every count uses a plural variation** (`.xcstrings` "Vary by plural" with `one / few / many /
  other` — Russian needs all four; English fills `one / other`).
  Example `toast.snapshotAll.body`: EN `"Saved %lld snapshots"` → RU `one` "Сохранён %lld снимок",
  `few` "Сохранено %lld снимка", `many` "Сохранено %lld снимков".
- **Camera names are inserted only in nominative-safe positions**, always quoted with locale-correct
  quotes: EN `“Front Door”`, RU `«Вход»`. Never "Snapshot of {name}'s stream" (possessives don't
  translate).
- **No embedded markup other than markdown links** in `AttributedString(localized:)`; link targets
  live in the key (`error.notHikvision.body` contains `[ONVIF](vigil://help/onvif)`).
- **Layout budget: Russian strings run 20–35 % longer.** Every label, button and empty state is
  laid out to survive +35 % (verified by the pseudo-localization run, §16.4). Fixed-width numeric
  columns are exempt because numbers don't translate.
- Units, dates and numbers never appear inside a translatable string as literals — they are
  arguments formatted by `Measurement`/`Date.FormatStyle`/`Duration.UnitsFormatStyle`.
- Accessibility labels are separate keys under `a11y.*` and are translated too.

### 14.3 The 20 most important strings

| # | Key | English |
|---|---|---|
| 1 | `empty.cameras.title` / `.body` / `.action` / `.actionSecondary` | **“No cameras yet.”** / “Vigil finds Hikvision cameras and NVRs on your network. It takes about ten seconds.” / “Find Cameras” / “Add Manually” |
| 2 | `firstRun.welcome.title` / `.body` | **“Welcome to Vigil.”** / “Watch your Hikvision cameras with almost no delay. Nothing leaves your network.” |
| 3 | `discovery.permission.title` / `.body` / `.action` | **“Vigil needs to see your local network.”** / “macOS will ask for permission so Vigil can find cameras on this network. Vigil never sends anything to the internet.” / “Continue” |
| 4 | `error.auth.wrongPassword.title` / `.body` / `.action` | **“Wrong password.”** / “%1$@ rejected the password for “%2$@”. Check it and try again — too many attempts will lock the device.” / “Update Password” |
| 5 | `error.auth.locked.title` / `.body` / `.hint` | **“Device is locked.”** / “%1$@ locked out this account after too many failed sign-ins. It usually unlocks in about %2$lld minutes.” / “Unlock it now from the camera's web page.” |
| 6 | `error.unreachable.title` / `.body` / `.action` | **“Can't reach this camera.”** / “No response from %1$@. Check that it's powered on and on the same network as this Mac.” / “Diagnose” |
| 7 | `error.notHikvision.title` / `.body` / `.action` | **“Not a Hikvision device.”** / “%1$@ answered, but it doesn't speak ISAPI. Vigil can still try [ONVIF](vigil://help/onvif), with fewer features.” / “Use ONVIF” |
| 8 | `error.notActivated.title` / `.body` / `.action` | **“Camera isn't activated.”** / “%1$@ is brand new and has no password yet. Set one now to start using it.” / “Set Password” |
| 9 | `error.codecUnsupported.title` / `.body` / `.hint` | **“Unsupported video format.”** / “This channel streams %1$@. Vigil plays H.265, H.264 and MJPEG.” / “Change the encoding in the camera's web page.” |
| 10 | `error.rtspBlocked.title` / `.body` / `.action` | **“Video port is closed.”** / “Vigil reached %1$@ on port %2$lld, but RTSP port %3$lld refused the connection.” / “Try Port 8554” |
| 11 | `state.connecting.narration` (see §12.4 for the full ladder) | “Connecting…”, “Signing in…”, “Negotiating stream…”, “Waiting for a keyframe…” |
| 12 | `state.degraded.packetLoss.body` / `.action` | **“%1$@ packet loss — video may stutter.”** / “Switch to TCP” |
| 13 | `state.offline.title` / `.body` / `.action` / `.hint` | **“Connection lost.”** / “Reconnecting in %1$lld s (attempt %2$lld).” / “Retry Now” / “Last seen %1$@” |
| 14 | `storage.full.title` / `.body` / `.action` | **“Recording stopped — disk is full.”** / “Less than %1$@ is free on %2$@. Vigil stopped recording to protect your other files.” / “Manage Recordings” |
| 15 | `storage.low.body` / `.action` | “Only %1$@ left on %2$@.” / “Manage Recordings” |
| 16 | `confirm.deleteCamera.title` / `.body` / `.action` | **“Delete “%1$@”?”** / “Its saved clips and snapshots stay on your Mac. The camera itself isn't changed.” / “Delete Camera” |
| 17 | `confirm.quitWhileRecording.title` / `.body` / `.action` / `.actionSecondary` | **“Still recording %1$lld cameras.”** / “Quitting will finish and save the clips first.” / “Finish and Quit” / “Keep Recording” |
| 18 | `toast.snapshotSaved.body` / `.action` | “Snapshot saved to %1$@.” / “Reveal” |
| 19 | `toast.recordingSaved.body` / `.action` | “Saved %1$@ · %2$@.” (duration · size) / “Reveal” |
| 20 | `empty.playbackDay.title` / `.body` / `.action` | **“Nothing recorded on %1$@.”** / “The closest footage is on %2$@.” / “Go to %1$@” |

### 14.4 Additional strings referenced by this document

| Key | English |
|---|---|
| `palette.placeholder` | “Search cameras, actions, layouts…” |
| `stage.emptyCell.title` | “Add camera” |
| `empty.events.title` / `.body` | “No events yet.” / “Motion detection is %1$@ on this camera.” |
| `empty.recordings.title` / `.body` | “No recordings yet.” / “Press ⌘R on any camera to start one.” |
| `empty.discovery.title` / `.body` | “No cameras found.” / “Cameras must be on the same network, powered on, and not blocked by a firewall.” |
| `empty.search.title` | “No cameras match “%1$@”.” |
| `empty.palette.title` | “No results.” |
| `inspector.ptz.unsupported.title` / `.body` | “No PTZ on this camera.” / “%1$@ is a fixed camera. You can still zoom digitally.” |
| `playback.searchFailed.body` / `.action` | “Couldn't load the recording list from this camera.” / “Retry” |
| `export.reencodeWarning.body` | “Burning in the overlay re-encodes the video, which takes longer and slightly reduces quality.” |
| `import.csv.passwordNote.body` | “Passwords go straight to your Keychain. Vigil never copies the file.” |
| `discovery.added.body` / `.action` | “Added %1$lld cameras.” / “Undo” |
| `test.ok.body` | “Signed in — %1$@, %2$lld channel(s).” *(plural-varied)* |
| `network.restored.body` | “Network back — reconnecting %1$lld cameras.” |
| `network.offline.body` | “No network connection.” |
| `system.wake.body` | “Welcome back — reconnecting.” |
| `power.lowPowerMode.body` | “Low Power Mode is on — Vigil switched to sub-streams.” |
| `budget.paused.title` / `.body` / `.action` | “Paused to save power.” / “Too many streams for hardware decode.” / “Use Sub-Stream” |
| `wall.screenMissing.body` | “That display is gone — the wall opened on this Mac instead.” |
| `about.noDependencies.body` | “Vigil uses no third-party code.” |
| `general.language.relaunch.note` | “Vigil will use this language after you quit and reopen it.” |

### 14.5 Glossary (fixed translations — do not vary)

| English | Русский | Note |
|---|---|---|
| Camera | Камера | |
| NVR | Регистратор (NVR) | keep the acronym in parentheses on first use |
| Live | Прямой эфир | not «Живое» |
| Snapshot | Снимок | |
| Recording (noun) | Запись | |
| Clip | Фрагмент | |
| Playback | Просмотр архива | not «Воспроизведение» in navigation |
| Timeline | Шкала времени | |
| Layout | Раскладка | |
| Group | Группа | |
| Event | Событие | |
| Motion | Движение | |
| Preset (PTZ) | Предустановка | |
| Patrol | Патрулирование | |
| Sub-stream | Дополнительный поток | |
| Main stream | Основной поток | |
| Packet loss | Потеря пакетов | |
| Hardware decode | Аппаратное декодирование | |
| Video wall | Видеостена | |
| Cinema mode | Кинорежим | |

---

## 15. Latency perception & optimistic UI

The app must feel instant even when the network is not. These rules are testable and normative.

### 15.1 Connection choreography

| Elapsed | What the user sees | Why |
|---|---|---|
| **0–16 ms** (same frame as the click) | The tile exists at its final size, with the camera name chip, colour tag, amber dot, and true-black background. Layout is committed. | Perceived responsiveness is dominated by whether *something* changed in the first frame. |
| **16–100 ms** | Cached last frame (JPEG, ≤ 480×270, from `~/Library/Caches/Vigil/lastframe/<uuid>.jpg`) fades in at 22 % opacity with a 4 pt blur; skeleton shimmer starts. **No spinner, no text.** | On a LAN, ~40 % of connections produce a first frame before 250 ms. Text that appears and vanishes reads as jank. |
| **100–250 ms** | Still no narration. Shimmer only. | Anything shown for < 150 ms is noise. |
| **250–700 ms** | Narration line appears (`Connecting…` → `Signing in…` → …), Caption1, secondary, cross-fading 120 ms between phrases. | The user now knows work is happening and *what* work. |
| **700–3500 ms** | Narration plus a `monospacedDigit` elapsed counter (`1.4 s`), and a 2 pt indeterminate progress hairline at the tile's bottom edge. | Duration feedback prevents the "is it stuck?" question. |
| **3500 ms** | Adds `connecting.slow` + a `Run Stream Doctor` ghost button. Narration keeps updating. | We admit the truth before the user concludes we are broken. |
| **8000 ms** | Becomes the failure card (§12.6/§12.7) with the doctor's finding already computed in the background. | The first error message the user reads should already contain the cause. |

First-frame handoff (§15.2) must not move anything: the video layer is created at the same frame
rect as the ghost frame, so the transition is purely a cross-fade.

### 15.2 First-frame handoff

1. `StreamEvent.firstFrame(dimensions:)` arrives on the main actor.
2. The video layer is inserted **below** the ghost/skeleton layer and given one frame to present.
3. Ghost + shimmer cross-fade out over **120 ms** (`.easeOut`); the video layer's opacity goes
   0 → 1 over the same 120 ms. `reduceMotion` → 0 ms (hard cut).
4. The status dot animates amber → green with a single 300 ms pulse (scale 1 → 1.35 → 1).
5. The stats chip populates with a 90 ms fade. `fps` shows `—` until 1 s of samples exist; it never
   shows a wrong number.
6. If the first frame arrives **within 400 ms** of the connection starting, steps 3–5 collapse into
   a single 90 ms fade and **no narration is ever shown** — the fast path must look like "it was
   already on".

Resolution-change and stream-switch (sub → main) handoffs use the identical choreography with a
60 ms cross-fade, and the tile frame never changes (aspect handling is inside the layer).

### 15.3 Optimistic PTZ

```
keyDown / press
  ├─ 0 ms   direction glyph appears on the video (48 pt, 70 % white, 90 ms fade-in);
  │         the pad sector lights; a 1 pt accent arc shows the speed
  ├─ 0 ms   ISAPI PUT /ISAPI/PTZCtrl/channels/{n}/continuous  (fire-and-forget, no await in the UI)
  ├─ 400 ms watchdog re-sends the same continuous command (devices drop commands)
  ├─ ≤1200 ms if the response is an error → glyph turns amber, 220 ms shake (3 pt),
  │         toast `error.ptz.refused.body` with the device's reason
  └─ keyUp  0 ms glyph fades (120 ms); PUT continuous with pan=0,tilt=0,zoom=0; hard stop after 8 s
            of continuous movement regardless (safety, prevents a runaway camera)
```

- **Never** await the HTTP round trip before showing feedback; a Hikvision PTZ PUT is 30–150 ms and
  the user's finger is faster.
- Preset recall: the preset thumbnail scales 1 → 0.96 → 1 (`micro`) and its number badge fills with
  accent immediately; a 1.2 s "moving" pip appears over the tile. On failure the badge returns and a
  toast explains. We do **not** wait for the camera to physically arrive (there is no such event).
- Two-way audio: the mic level meter appears the instant the key is pressed, before the audio
  session is confirmed; if the session fails, the meter turns amber with `error.audio.pushFailed`.

### 15.4 Optimistic settings

| Change | Local effect | Remote | Failure handling |
|---|---|---|---|
| Image sliders (brightness…sharpness, night boost) | applied in the Metal shader **this frame** | debounced 250 ms trailing PUT, one in flight per camera, latest-wins with a monotonically increasing `revision` | slider springs back over 200 ms, toast names the reason, the local value is kept if "Adjust my view only" is on |
| Day/Night, WDR, IR, BLC | control flips instantly, a 1.2 s "applying" pip on the control | immediate PUT | revert control + toast |
| Quality (main/sub/third) | badge changes instantly, tile keeps showing the old stream until the new one has a frame (no black gap) | re-`SETUP` | badge reverts, banner `stream.switchFailed.body` |
| Transport TCP/UDP | badge changes instantly | reconnect | reverts, banner |
| Mute / volume | instant (local audio graph) | none | n/a |
| Camera rename, colour tag, group move | instant everywhere (single source of truth) | `ConfigStore` debounced 500 ms | write failure → toast `error.saveFailed.*` + retry; UI keeps the value in memory |
| Layout change | instant | none (persisted) | n/a |
| Recording start | button flips to "recording" and the elapsed timer starts at 0.0 s within one frame | `AVAssetWriter` starts; the first sample may lag by up to one GOP | if the writer fails within 1.5 s: revert, toast with the reason (disk, permission, no keyframe) |

**Anti-patterns (banned):** progress spinners on buttons that complete in < 400 ms; disabling a
control while a request is in flight (use the optimistic value plus rollback); modal alerts for
recoverable stream errors; layout shifts when data arrives; any UI that waits on ISAPI before
rendering.

---

## 16. Accessibility & localization mechanics

### 16.1 VoiceOver

| Element | Label | Value | Traits / actions |
|---|---|---|---|
| Video tile | `a11y.tile.label` = “%1$@, camera %2$lld of %3$lld” | `a11y.tile.value` = “Live, H.265, 1920 by 1080, 25 frames per second” / “Connecting” / “Offline, retrying in 4 seconds” | `.isButton`; custom actions: Snapshot, Record, Fullscreen, PTZ, Close |
| Status dot | — | included in the tile value | `.updatesFrequently` **not** set (we post `.announcement` only on transitions to offline/authFailed) |
| Sidebar row | camera name | “Live · Perimeter · recording” | `.isSelected`; actions: Rename, Delete, Open Playback |
| PTZ pad | `a11y.ptz.pad` = “Pan and tilt control” | “Centred” / “Moving up-left at speed 5” | 8 custom actions (Up, Down, …) + Home; arrow keys work with VO on via a “Pan” rotor |
| Timeline | `a11y.timeline.label` = “Recording timeline for %1$@” | “10:14:38. Motion recording. 4 hours 12 minutes of footage today.” | `.adjustable` (increment = 10 s at the current zoom); custom actions: Next Event, Previous Event, Set In, Set Out |
| Sparkline | metric name | “Bitrate 4.1 megabits per second, average 3.8, peak 6.2” | `.isStaticText`, hidden children |
| Command palette | “Command palette” | “%1$lld results. %2$@ selected.” | announces the selected row on ↑↓ via `.accessibilityFocused` |
| Toast | title + body | — | `.announcement` at `.high` priority for danger, `.default` otherwise |

Rules: video content itself is never described (we don't invent vision); decorative gradients and
shimmer are `.accessibilityHidden(true)`; every icon-only button has a label and, where the meaning
is not obvious, an `accessibilityHint`.

### 16.2 Keyboard & focus

Full keyboard access with no traps: `⇥` order is Sidebar → Stage tiles (index order) → Inspector →
toolbar; `⌃⇥`/`⌃⇧⇥` jumps between regions directly. Focus is always visible (2 pt accent ring,
never removed on mouse use). `Esc` never traps (§11.1). Every menu action works with no window
focused where it makes sense (opening Discovery, Settings, Preferences).

### 16.3 Reduce Motion / Increase Contrast / Differentiate Without Color

- `reduceMotion`: springs → 0.12 s `.easeOut` opacity; `matchedGeometryEffect` transitions → cross
  fade; shimmer → a static 8 % bar; patrol cross-fade → hard cut; scan sweep → static bar; the live
  dot stops breathing (stays at full opacity).
- `increaseContrast`: strokes go from `subtle` to `strong`, tile focus ring to 3 pt, text drops
  `tertiary` in favour of `secondary`, scrims darken from 55 % to 75 %.
- `differentiateWithoutColor`: status dots gain glyphs (§4.2), the timeline heatmap gains hatch
  patterns (§7.3), degraded/offline gain leading warning glyphs in banners.
- `reduceTransparency`: sidebar and palette materials become solid `surface` fills.
- Minimum hit targets 28×28 pt (tile chrome buttons are 24 pt glyphs in 28 pt targets); 44 pt for
  anything in a first-run flow.

### 16.4 Localization mechanics

- `Localizable.xcstrings` per module; `String(localized:table:bundle:comment:)` everywhere, with a
  `comment:` that states the surface and constraints (`"Tile banner, max 40 chars"`).
- Both English and Russian ship complete (`FEATURES.md` P0). A missing Russian value falls back to
  English with a build-time warning; CI fails on any untranslated key in a release build.
- Pseudo-localization run (`-VigilPseudoLoc 1`) wraps every string with `⟦…⟧` and inflates it 35 %;
  the UI must show no truncation or clipping in the 12 screenshot scenarios listed in §18.
- Numbers, dates, durations, byte counts: `Date.FormatStyle`, `Duration.UnitsFormatStyle`,
  `Measurement<UnitInformationStorage>.formatted()`, `.formatted(.number.precision(.fractionLength(1)))`.
  Bitrate is `Measurement<UnitInformationStorage>` per second, rendered `"4.1 Mb/s"` / `"4,1 Мбит/с"`.
- Keyboard shortcuts are **not** localized (⌘S stays ⌘S), but their menu titles are.
- The timeline ruler switches to 24-hour ticks in locales without AM/PM automatically.

---

## 17. VigilUI / Vigil file manifest (for the contract author)

```
Sources/VigilUI/
  State/            AppModel.swift  LayoutState.swift  SidebarSelection.swift  InspectorTab.swift
                    PaletteState.swift  ToastQueue.swift  ShortcutStore.swift  FocusedValues.swift
  Window/           MainWindowView.swift  MainToolbar.swift  WindowAccessor.swift  CinemaChrome.swift
  Sidebar/          SidebarView.swift  CameraRow.swift  GroupRow.swift  SidebarFilterBar.swift
                    SidebarFooter.swift  CameraContextMenu.swift  InlineRenameField.swift
  Stage/            StageView.swift  StageRouter.swift  LayoutEngine.swift  TileContainer.swift
                    TileChrome.swift  TileStateOverlay.swift  EmptyCellView.swift
                    MosaicEditor.swift  PatrolController.swift  TileDropDelegate.swift
  Inspector/        InspectorView.swift  InfoTab.swift  StreamTab.swift  PTZTab.swift  ImageTab.swift
                    EventsTab.swift  RecordingTab.swift  SystemOverview.swift  PTZPad.swift
                    PresetGrid.swift  ScheduleGrid.swift
  Playback/         PlaybackWindowView.swift  PlaybackModel.swift  TimelineView.swift
                    TimelineRuler.swift  TimelineHeatmap.swift  TimelineLane.swift
                    ScrubPreviewCard.swift  TransportBar.swift  ExportSheet.swift  DatePickerPopover.swift
  Discovery/        DiscoveryRootView.swift  DiscoveryModel.swift  ScanStepView.swift
                    ResultsListView.swift  CredentialsStepView.swift  ChannelStepView.swift
                    ManualAddForm.swift  CSVImportSheet.swift  ActivateDeviceSheet.swift
  Events/           EventsFeedView.swift  EventRow.swift  EventCard.swift  EventFilterBar.swift
                    WatchModeOverlay.swift
  Palette/          CommandPaletteOverlay.swift  PaletteIndex.swift  FuzzyMatcher.swift
                    PaletteRow.swift  PaletteActions.swift
  Wall/             VideoWallView.swift  ScreenPicker.swift
  Settings/         SettingsView.swift  GeneralPane.swift  StreamsPane.swift  RecordingPane.swift
                    NotificationsPane.swift  ShortcutsPane.swift  AdvancedPane.swift  AboutPane.swift
  Shared/           VEmptyState.swift  VToast.swift  VSkeleton.swift  VKeyCap.swift  VSparkline.swift
                    VStatPill.swift  StreamDoctorSheet.swift  CheatSheetOverlay.swift
                    Formatters.swift  Strings.swift (generated key accessors)
  Resources/        Localizable.xcstrings  (EN + RU)
Sources/Vigil/
  VigilApp.swift  VigilCommands.swift  AppEnvironment.swift  MenuBarExtraContent.swift
  URLSchemeHandler.swift  AppDelegate.swift (sleep/wake, reopen, dock badge)
```

Deep links (grammar owned by `spec-core.md`) map to UI as follows:

| URL | Effect |
|---|---|
| `vigil://camera/<uuid>` | main window, focus that camera's tile (assign if absent) |
| `vigil://camera/<uuid>?action=snapshot` | snapshot without changing the layout, toast confirms |
| `vigil://camera/<uuid>/playback?t=2026-07-26T10:14:38Z` | opens a playback window at that instant |
| `vigil://layout/<name>` | applies a layout preset |
| `vigil://events` | main window, Events route |
| `vigil://wall?screen=2` | opens the video wall on screen 2 |
| `vigil://settings/streams` | opens Settings at the Streams pane |

---

## 18. Acceptance checklist (UX)

1. Cold launch to fully drawn chrome ≤ 400 ms; every tile is in the connecting state in the first
   frame; no layout shift occurs when frames arrive.
2. A connection that produces a first frame within 400 ms shows **no** narration text at any point.
3. Switching layout (⌘1…⌘8) never tears down a decode session for a camera that remains on screen;
   measured by a decode-session counter in the developer overlay.
4. Every action in §11.1 is reachable from the menu bar, and the menu shows the same shortcut the
   registry holds after a rebind.
5. `Esc` follows the §11.1 precedence chain exactly and never closes the main window.
6. The palette returns ranked results within 2 ms for 2 000 items and is fully keyboard operable.
7. Every failure surface names a cause **and** an action; no modal alert appears for any stream
   error (verified by a UI test that faults each of the 12 conditions in §8.4).
8. Offline tiles show a live 1 Hz countdown matching the backoff table and a dimmed last-known frame.
9. Auth failure never auto-retries.
10. Sidebar thumbnails stop entirely when the window is occluded (verified by an instrument trace
    showing zero JPEG requests).
11. Timeline zoom spans exactly the 9 stops of §7.3; pinch anchors at the gesture centroid within
    1 pt; scrub preview cards never change size.
12. Multi-camera sync keeps panes within ±40 ms and does not re-seek to correct drift.
13. Pseudo-localization at +35 % shows no truncation in: main window, sidebar row, tile chrome,
    inspector Stream tab, playback transport, discovery step 3, export sheet, all 7 settings panes,
    palette row, toast, empty states, cheat sheet.
14. VoiceOver can add a camera, assign it to a cell, take a snapshot, start recording, and export a
    clip without a mouse.
15. `reduceMotion` removes every spring listed in `DESIGN.md` §Motion; no animation drops video
    below 60 fps (developer overlay frame-time p99 < 8.3 ms with 16 tiles).
16. Window frames, sidebar/inspector state, layout, and playback scrub position all restore after
    quit and relaunch.
17. Every user-visible string resolves through `Localizable.xcstrings`; a debug assertion fires on
    any literal string passed to a `Text` in `VigilUI`.
18. Sleep → wake with the network changed reconnects every camera within 3 s of wake, with exactly
    one toast.
