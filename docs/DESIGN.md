# Vigil — Design System

**Status:** normative. **Owner:** design. **Consumers:** `VigilUI` (all tokens + components), `Vigil`
(window chrome, menu bar, app icon), `VigilRender` (video-well colour rules, overlay compositing),
`VigilCore` (status enums that map to semantic colours).

This document is the single source of truth for how Vigil looks and moves. Every number here is a
decision, not a suggestion. If an implementation needs a value that is not in this document, add it
here first. Nothing in `VigilUI` may contain a hard-coded colour, font size, radius, duration, spring
value, shadow, or inset — all of them come from `VTheme` (§12).

**Non-negotiables carried from the brief:** macOS 14.0+, SwiftUI + AppKit interop, zero external
dependencies, and the hard performance floor that **UI motion must never cost the video pipeline a
frame** (§7.9).

---

## 0. How to read this document

| Convention | Meaning |
|---|---|
| `pt` | SwiftUI points (logical). All geometry is in pt. Never px, except hairlines (§5.4). |
| Hex values | sRGB, non-linear, no alpha unless stated. Always constructed with an explicit `.sRGB` colour space so the values are display-independent. |
| `α` | Alpha applied to the token, e.g. `stroke.default` = white at α 0.10 in dark. |
| **Dark** | The primary, default, designed-first appearance. Light is a full first-class port, not an afterthought, but every judgement call was made in dark. |
| Spring notation | `spring(r, ζ)` = `Animation.spring(response: r, dampingFraction: ζ, blendDuration: 0)`. |
| ⛔ | A hard rule. Violating it is a bug, not a taste difference. |

Section order matches the order an implementer needs it: thesis → tokens → motion → components →
accessibility → chrome → the token file.

---

## 1. Design thesis

> **Vigil is a calm, dark, cinema-grade surveillance cockpit in which the video is the only hero and
> every piece of chrome dissolves the moment it is not needed.** The window opens on near-black glass
> with sixteen panes of live world in it, and the interface reads as precision instrumentation —
> hairline strokes, monospaced telemetry, a single violet accent — rather than as software with
> buttons on it. Nothing decorative ever sits on top of a frame: controls fade in under the cursor,
> state is told by a 6 pt dot and a two-word label, and the app's own colour vocabulary is
> deliberately cool so that the warm reds and ambers are reserved exclusively for *something is
> happening on a camera*. Motion is the app's manners: springs that settle in a third of a second,
> one continuous shared element when a tile becomes the whole screen, and a shimmer that resolves
> into a first frame so a connection never feels like a wait. It should feel like a Leica body — dense,
> quiet, cold to the touch, and completely obedient at 120 Hz.

### 1.1 The six principles

| # | Principle | What it forces | What it forbids |
|---|---|---|---|
| **P1** | **The frame is sacred.** | Video wells are true black, un-tinted, un-materialised, never overlapped by anything opaque or permanently visible. Chrome is on hover, on focus, or on demand. | Persistent gradients/scrims over video, decorative frames, coloured letterboxing, watermarks, always-on tile toolbars. |
| **P2** | **Chrome dissolves.** | Every panel, toolbar and HUD has a defined disappearance: hover-out, blur, 2.5 s idle (cinema), or `⌘L`/`⌘⌥I`. Default state of the app is maximum video area. | Chrome that cannot be hidden; modal dialogs where a popover works; nested toolbars. |
| **P3** | **Colour carries meaning, not mood.** | Red/amber/green/blue are *reserved* for camera and recording state. The brand accent is violet precisely because it can never be mistaken for an alarm. Decoration uses layer + stroke + type, never hue. | Coloured buttons for ordinary actions, rainbow charts, tinted panels, accent-coloured backgrounds behind text. |
| **P4** | **Numbers never move.** | Every changing digit is `monospacedDigit()`; every telemetry readout is fixed-width and right-aligned; bitrate, fps, latency, timecode and counters have reserved width so nothing reflows at 25 Hz. | Proportional digits in any live value, layout that jitters as numbers change, spinners where a number will do. |
| **P5** | **Motion explains, then gets out of the way.** | Animation exists to make causality legible: where a panel came from, which tile became fullscreen, that a connection is progressing. Everything is under 0.5 s except one deliberate 0.95 s hero transition. | Bounce for its own sake, staggered entrances longer than 220 ms total, easing on things the user is dragging, animation on any live-video layer geometry. |
| **P6** | **Keyboard first, pointer second, mouse-required never.** | Every action has a shortcut and a `⌘K` entry; focus is always visible; the whole app is operable with the mouse unplugged; hit targets are ≥ 24 pt even when the glyph is 13 pt. | Hover-only affordances without a keyboard path, custom controls without a focus ring, drag-only interactions (drag always has a menu equivalent). |

---

## 2. Appearance and the layer model

### 2.1 Appearance resolution

Three user settings: **Dark** (default), **Light**, **Auto (system)**. Stored as
`VAppearancePreference` in `VigilCore` settings; applied by setting `NSApp.appearance` to
`NSAppearance(named: .darkAqua)`, `.aqua`, or `nil` (follow system) at launch and on change. All
tokens are dynamic (§12.2) so the whole UI cross-fades automatically — AppKit animates
`NSVisualEffectView` material changes for free; SwiftUI colour changes are animated by wrapping the
appearance switch in `withAnimation(VTheme.Motion.standard)`.

⛔ Video wells do **not** participate in appearance. They are `#000000` in both appearances, always.

### 2.2 The six layers

Depth in Vigil is built from exactly six layers. There is no layer 7; if a design seems to need one,
it needs a popover instead.

| Layer | Token | Role | Material or fill |
|---|---|---|---|
| **L0 Well** | `layer.videoWell` | The video itself and its letterbox area. | Solid `#000000`. Never a material. |
| **L1 Canvas** | `layer.canvas` | The stage background behind and between tiles; window background. | Solid. |
| **L2 Sidebar** | `layer.sidebar` | Sidebar and inspector columns. | `NSVisualEffectView` `.sidebar`, with solid fallback. |
| **L3 Surface** | `layer.surface` | Inline containers: cards, list rows, fields, inspector sections. | Solid. |
| **L4 Raised** | `layer.surfaceRaised` | Selected/hovered rows, segmented thumbs, stat pills, inset wells inside a surface. | Solid. |
| **L5 Overlay** | `layer.overlay` | Popovers, menus, toasts, floating toolbars, command palette, sheets. | `.hudWindow` material + glass recipe (§6.5), solid fallback. |

**Adjacency rule:** a layer may sit directly on the layer above or below it in the list, or skip one.
L3 on L1 is legal (a card on the canvas). L4 on L1 is not — a raised surface must sit inside a
surface. L5 sits on anything.

### 2.3 When to use `NSVisualEffectView` — and when not to

This is the most-abused API in Mac design and Vigil's rule is strict, for a technical reason:
`NSVisualEffectView` blurs *what is behind it inside the window's backing store*.
`AVSampleBufferDisplayLayer` and the Metal renderer composite **above** the material's sampling
region, so a material placed over a video tile does **not** frost the video — it frosts the empty
canvas behind the video and reads as a flat grey smear over a bright picture. Therefore:

| Surface | Treatment | Exact configuration |
|---|---|---|
| Sidebar column | Material | `material: .sidebar`, `blendingMode: .behindWindow`, `state: .followsWindowActiveState`, `emphasized: false` |
| Inspector column | Material | `material: .sidebar`, `.behindWindow`, `.followsWindowActiveState` |
| Unified toolbar strip | Material | `material: .headerView`, `.withinWindow`, `.active` (SwiftUI `.unified` toolbar gives this; only override when we draw a custom header) |
| Command palette, popovers, menus, toasts, Settings sheets | Material | `material: .hudWindow`, `.withinWindow`, `.active` + glass recipe (§6.5) |
| Window background where no video is present (empty state, Settings, Discovery) | Material | `material: .underWindowBackground`, `.behindWindow`, `.followsWindowActiveState` |
| **Any HUD, chip, toolbar or scrim that sits over a video tile** | ⛔ **Never a material.** Solid scrim. | `Color.black.opacity(0.62)` + `stroke.default`, radius per component |
| Cinema-mode control bar (the single exception) | Metal-blurred video backdrop | `VigilRender.blurredBackdrop(radius: 24, downsample: 4)` — budget 0.4 ms/frame at 1080p; auto-disables to the solid scrim if the renderer reports < 30 % frame-time headroom |

**Scrim ladder over video** (verified against a worst-case all-white frame, text `#F2F4F8`):

| Scrim | Composite over white frame | Contrast to `text.primary` | Use |
|---|---|---|---|
| `scrim.light` — black α 0.45 | `#8C8C8C` | 3.05:1 | Gradient tails only, never behind text |
| `scrim.base` — black α 0.62 | `#616161` | 5.20:1 | Tile name chip, stats HUD, hover toolbar |
| `scrim.strong` — black α 0.82 | `#2E2E2E` | 12.33:1 | Offline/auth-failure overlay, cinema bar fallback |

Hover chrome over a tile uses `scrim.base` **inside the chip/toolbar shape only** — never a
full-tile gradient. The one full-tile scrim allowed is the offline/degraded state, which is a
`scrim.strong` at α 0.82 over the dimmed last-known frame (§9.14).

### 2.4 `reduceTransparency`

When `@Environment(\.accessibilityReduceTransparency)` is `true`, every material resolves to its
solid fallback and the glass inner highlight is dropped:

| Material | Dark fallback | Light fallback |
|---|---|---|
| `.sidebar` | `#101116` | `#EBECF0` |
| `.headerView` | `#131519` | `#F0F1F4` |
| `.hudWindow` | `#252932` | `#FFFFFF` |
| `.underWindowBackground` | `#0B0C0F` | `#F3F4F7` |

---

## 3. Colour

### 3.1 Why the accent is **Iris** `#7B61FF`

Vigil's accent is a violet-leaning indigo we call **Iris**, hue ≈ 253°. It is not macOS system blue,
and that is the point. Five reasons, in priority order:

1. **Semantic exclusivity.** Vigil's status vocabulary already owns red (recording/live), amber
   (motion event), yellow (degraded), green (healthy) and sky blue (continuous recording on the
   timeline). Those five hues mean *something is happening on a camera*. An accent must therefore be
   drawn from the one region of the wheel that carries no operational meaning, or a selected row will
   read as an alarming row. Violet is that region.
2. **Colour-vision safety.** Protanopia and deuteranopia (~8 % of men) collapse the red–green axis but
   leave the blue–yellow axis intact. Measured in CIELAB with a Viénot LMS simulation, Iris keeps
   ΔE ≥ 109 from `live`, ≥ 140 from `ok`, ≥ 171 from `warn` and ≥ 158 from `motion` under both
   protanopia and deuteranopia. No colour-blind operator can confuse "selected" with "alarming".
3. **Separation from the imagery.** Real camera footage is dominated by warm sodium-vapour street
   light, IR-grey monochrome, and skin tones — 20°–60° and desaturated. A 253° accent is close to the
   complement of that entire range, so accented chrome pops off the video instead of sinking into it.
4. **It survives vibrancy.** At 0.72 effective opacity over the `.sidebar` material, Iris retains
   ~86 % of its chroma; a cyan or teal accent greys out badly under the same material because the
   sidebar backdrop desaturates mid-luminance cool hues.
5. **Recognition.** A screenshot of Vigil is identifiable in one glance and cannot be mistaken for a
   default-accent SwiftUI app. We deliberately ignore `NSColor.controlAccentColor`: the user's system
   accent is **not** used anywhere in Vigil, because a red or orange system accent would collide with
   the status vocabulary. This is a documented, intentional deviation from HIG defaults.

Iris ships in four values because contrast requirements differ by role: `accent` for glyphs and
strokes (4.65:1 on canvas), `accentFill` for button fills that carry white text (5.86:1),
`accentHover`/`accentPressed` for interaction, and `focusRing`, a lightened tint that clears 3:1
against **every** layer including L5 overlay (4.76:1).

### 3.2 Layer, text and semantic tokens

All contrast figures are measured (WCAG 2.1 relative luminance) against `layer.canvas` in the same
appearance unless noted.

| Token | Dark hex | Dark SwiftUI | Light hex | Light SwiftUI |
|---|---|---|---|---|
| `layer.canvas` | `#0B0C0F` | `Color(.sRGB, red: 0.043, green: 0.047, blue: 0.059)` | `#F3F4F7` | `Color(.sRGB, red: 0.953, green: 0.957, blue: 0.969)` |
| `layer.sidebarFallback` | `#101116` | `Color(.sRGB, red: 0.063, green: 0.067, blue: 0.086)` | `#EBECF0` | `Color(.sRGB, red: 0.922, green: 0.925, blue: 0.941)` |
| `layer.surface` | `#16181D` | `Color(.sRGB, red: 0.086, green: 0.094, blue: 0.114)` | `#FFFFFF` | `Color(.sRGB, red: 1.000, green: 1.000, blue: 1.000)` |
| `layer.surfaceRaised` | `#1D2026` | `Color(.sRGB, red: 0.114, green: 0.125, blue: 0.149)` | `#FFFFFF` | `Color(.sRGB, red: 1.000, green: 1.000, blue: 1.000)` |
| `layer.overlay` | `#252932` | `Color(.sRGB, red: 0.145, green: 0.161, blue: 0.196)` | `#FFFFFF` | `Color(.sRGB, red: 1.000, green: 1.000, blue: 1.000)` |
| `layer.videoWell` | `#000000` | `Color(.sRGB, red: 0.000, green: 0.000, blue: 0.000)` | `#000000` | same |
| `layer.scrim` | `#000000` | `Color(.sRGB, red: 0.000, green: 0.000, blue: 0.000)` | `#000000` | same |
| `text.primary` | `#F2F4F8` | `Color(.sRGB, red: 0.949, green: 0.957, blue: 0.973)` | `#14161A` | `Color(.sRGB, red: 0.078, green: 0.086, blue: 0.102)` |
| `text.secondary` | `#A7AEBC` | `Color(.sRGB, red: 0.655, green: 0.682, blue: 0.737)` | `#4E5765` | `Color(.sRGB, red: 0.306, green: 0.341, blue: 0.396)` |
| `text.tertiary` | `#88909D` | `Color(.sRGB, red: 0.533, green: 0.565, blue: 0.616)` | `#626B79` | `Color(.sRGB, red: 0.384, green: 0.420, blue: 0.475)` |
| `text.disabled` | `#4E5563` | `Color(.sRGB, red: 0.306, green: 0.333, blue: 0.388)` | `#A9B0BB` | `Color(.sRGB, red: 0.663, green: 0.690, blue: 0.733)` |
| `text.inverse` | `#0B0C0F` | `Color(.sRGB, red: 0.043, green: 0.047, blue: 0.059)` | `#FFFFFF` | `Color(.sRGB, red: 1.000, green: 1.000, blue: 1.000)` |
| `accent` | `#7B61FF` | `Color(.sRGB, red: 0.482, green: 0.380, blue: 1.000)` | `#5B44E0` | `Color(.sRGB, red: 0.357, green: 0.267, blue: 0.878)` |
| `accentHover` | `#8B74FF` | `Color(.sRGB, red: 0.545, green: 0.455, blue: 1.000)` | `#6A52E8` | `Color(.sRGB, red: 0.416, green: 0.322, blue: 0.910)` |
| `accentPressed` | `#6A4CF7` | `Color(.sRGB, red: 0.416, green: 0.298, blue: 0.969)` | `#4A34C9` | `Color(.sRGB, red: 0.290, green: 0.204, blue: 0.788)` |
| `accentFill` | `#6247E8` | `Color(.sRGB, red: 0.384, green: 0.278, blue: 0.910)` | `#5B44E0` | `Color(.sRGB, red: 0.357, green: 0.267, blue: 0.878)` |
| `focusRing` | `#9581FF` | `Color(.sRGB, red: 0.584, green: 0.506, blue: 1.000)` | `#5B44E0` | `Color(.sRGB, red: 0.357, green: 0.267, blue: 0.878)` |
| `live` | `#FF2E43` | `Color(.sRGB, red: 1.000, green: 0.180, blue: 0.263)` | `#C40E20` | `Color(.sRGB, red: 0.769, green: 0.055, blue: 0.125)` |
| `liveFill` | `#DE1327` | `Color(.sRGB, red: 0.871, green: 0.075, blue: 0.153)` | `#C40E20` | `Color(.sRGB, red: 0.769, green: 0.055, blue: 0.125)` |
| `ok` | `#32D74B` | `Color(.sRGB, red: 0.196, green: 0.843, blue: 0.294)` | `#157A2B` | `Color(.sRGB, red: 0.082, green: 0.478, blue: 0.169)` |
| `okFill` | `#157F28` | `Color(.sRGB, red: 0.082, green: 0.498, blue: 0.157)` | `#157A2B` | `Color(.sRGB, red: 0.082, green: 0.478, blue: 0.169)` |
| `warn` | `#FFD426` | `Color(.sRGB, red: 1.000, green: 0.831, blue: 0.149)` | `#7D5800` | `Color(.sRGB, red: 0.490, green: 0.345, blue: 0.000)` |
| `motion` | `#FF9F0A` | `Color(.sRGB, red: 1.000, green: 0.624, blue: 0.039)` | `#9A5300` | `Color(.sRGB, red: 0.604, green: 0.325, blue: 0.000)` |
| `danger` | `#FF5F52` | `Color(.sRGB, red: 1.000, green: 0.373, blue: 0.322)` | `#C42B1C` | `Color(.sRGB, red: 0.769, green: 0.169, blue: 0.110)` |
| `dangerFill` | `#CE3223` | `Color(.sRGB, red: 0.808, green: 0.196, blue: 0.137)` | `#C42B1C` | `Color(.sRGB, red: 0.769, green: 0.169, blue: 0.110)` |
| `continuous` | `#3B9CFF` | `Color(.sRGB, red: 0.231, green: 0.612, blue: 1.000)` | `#0B5FB8` | `Color(.sRGB, red: 0.043, green: 0.373, blue: 0.722)` |

**Measured contrast (dark appearance):**

| Pair | Ratio | Verdict |
|---|---|---|
| `text.primary` on canvas / surface / raised / overlay | 17.76 / 16.13 / 14.82 / 13.23 | AAA everywhere |
| `text.primary` on `#000000` (over video) | 19.07 | AAA |
| `text.secondary` on canvas / raised / overlay | 8.78 / 7.32 / 6.54 | AAA / AAA / AA+ |
| `text.tertiary` on canvas / surface / raised / overlay | 6.08 / 5.52 / 5.07 / 4.52 | AA everywhere (deliberately ≥ 4.5 on *all four*) |
| `text.disabled` on canvas | 2.61 | Intentionally sub-AA; disabled state always carries a second, non-colour cue (§10.4) |
| `accent` on canvas / surface / overlay | 4.65 / 4.22 / 3.46 | AA text on canvas; ≥ 3:1 graphic everywhere |
| white on `accentFill` | 5.86 | AA for 13 pt semibold button labels |
| white on `dangerFill` | 5.12 | AA |
| white on `liveFill` | 4.97 | AA |
| white on `okFill` | 5.12 | AA |
| `text.inverse` on `warn` / `motion` / `ok` | 13.69 / 9.51 / 10.21 | AAA — warm/green fills always take ink text, never white |
| `focusRing` on canvas / surface / raised / overlay / black | 6.39 / 5.80 / 5.33 / 4.76 / 6.86 | ≥ 3:1 on every layer, as required for a focus indicator |
| `live` on `#000000` (the dot on video) | 5.63 | AA |

**Light appearance:** `text.secondary` 6.64:1, `text.tertiary` 4.90:1, `accent` 5.70:1, `live`
5.57:1, `ok` 4.96:1, `warn` 5.84:1, `motion` 5.29:1, `danger` 5.15:1, `continuous` 5.71:1 — all
against `layer.canvas` `#F3F4F7`. Note that in light appearance the semantic hues are *darkened*, not
merely reused: a `#32D74B` green on white is 1.9:1 and unusable, so light mode gets its own
shade-shifted ramp.

### 3.3 Strokes

Strokes are alpha over the layer beneath, never opaque colours, so that they read correctly on
canvas, surface, glass and video alike.

| Token | Dark | Light | Composite (over dark canvas) | Use |
|---|---|---|---|---|
| `stroke.subtle` | white α 0.06 | black α 0.06 | `#1A1B1D` (1.13:1) | Dividers inside a surface, table rules, disabled borders |
| `stroke.default` | white α 0.10 | black α 0.12 | `#232427` (1.26:1) | Card, field, popover and toolbar borders; the standard hairline |
| `stroke.strong` | white α 0.18 | black α 0.22 | `#37383A` (1.67:1) | Hovered controls, segmented track, selected chip |
| `stroke.contrast` | white α 0.28 | black α 0.34 | `#4F5052` (2.42:1) | Only in `increaseContrast` mode (§10.4) |

`Color.white.opacity(0.10)` — expressed as `VTheme.Color.Stroke.default`.
On video wells, strokes flip to `white α 0.14` because the backdrop is `#000000` and 0.10 disappears.

### 3.4 Camera-identity palette (six categorical colours)

Every camera is auto-assigned an identity colour at creation (round-robin over the six, then the
least-used). The colour appears in: the sidebar row's leading rail (2 pt), the tile name chip's
leading dot, the timeline lane header, and the multi-camera playback legend. It is **always**
accompanied by the camera's initial glyph, so the colour is redundant encoding, never the sole
carrier of identity (this satisfies `differentiateWithoutColor` for free).

| Token | Name | Dark hex | Dark SwiftUI | Light hex | L\* (dark) | vs `#000` | vs `surface` |
|---|---|---|---|---|---|---|---|
| `ident.1` | Cyan | `#2FB8E8` | `Color(.sRGB, red: 0.184, green: 0.722, blue: 0.910)` | `#0C6E92` | 70.0 | 9.14 | 7.73 |
| `ident.2` | Jade | `#37D6A0` | `Color(.sRGB, red: 0.216, green: 0.839, blue: 0.627)` | `#0B7A5A` | 76.9 | 11.29 | 9.55 |
| `ident.3` | Citron | `#F0DE5C` | `Color(.sRGB, red: 0.941, green: 0.871, blue: 0.361)` | `#7A6A10` | 87.7 | 15.31 | 12.95 |
| `ident.4` | Coral | `#F5674A` | `Color(.sRGB, red: 0.961, green: 0.404, blue: 0.290)` | `#C0492B` | 61.3 | 6.92 | 5.85 |
| `ident.5` | Orchid | `#A867F5` | `Color(.sRGB, red: 0.659, green: 0.404, blue: 0.961)` | `#7A46B8` | 56.7 | 5.92 | 5.01 |
| `ident.6` | Steel | `#7A8BA4` | `Color(.sRGB, red: 0.478, green: 0.545, blue: 0.643)` | `#46586F` | 57.4 | 6.06 | 5.12 |

**Colour-blind verification** (CIELAB ΔE over all 15 pairs, Viénot LMS simulation):

| Vision | Minimum pairwise ΔE | Threshold | Result |
|---|---|---|---|
| Normal | 29.8 | ≥ 25 | pass |
| Protanopia | 21.9 | ≥ 20 | pass |
| Deuteranopia | 26.2 | ≥ 20 | pass |
| Tritanopia | 15.8 (Cyan↔Jade) | ≥ 12 | pass, and the initial glyph covers the residual |

Also note the L\* ladder: 87.7 / 76.9 / 70.0 / 61.3 / 57.4 / 56.7. The top four are separated by
≥ 8.7 L\*, so even full achromatopsia distinguishes four of the six by lightness alone.

**Chip recipes** (identity colour `C`): fill `C α 0.18`, stroke `C α 0.40`, text/glyph `C` at full
strength on dark, `ident.light` variant on light. Precomputed dark fills over `#000000`:
Cyan `#08212A`, Jade `#0A271D`, Citron `#2B2811`, Coral `#2C130D`, Orchid `#1E132C`, Steel `#16191E`.

⛔ Identity colours are never used for state. A Coral camera that is recording still shows the
`live` red dot; the Coral is only in the rail and the initial.

### 3.5 Accent tints

Derived, not separate tokens: `accent α 0.10` = `#161427` over dark canvas (selected row rest),
`α 0.16` = `#1D1A35` (selected row hover), `α 0.24` = `#262049` (pressed), `α 0.32` = `#2F275C`
(drop-target). In light appearance use `accent α 0.10 / 0.14 / 0.20 / 0.26` over `#F3F4F7`.

### 3.6 The true-black rule (⛔ hard)

1. Every video well — grid tile, fullscreen stage, PiP, video wall, playback viewport, PTZ preset
   thumbnail, sidebar micro-thumbnail, timeline scrub preview — has a `#000000` background.
2. Letterbox/pillarbox bars are `#000000`, never the canvas colour, never blurred-frame fill.
3. No tint, no material, no gradient, no opacity, no colour management transform is applied to the
   well itself. `AVSampleBufferDisplayLayer.backgroundColor = NSColor.black.cgColor` and
   `layer.isOpaque = true`.
4. The canvas *between* tiles is `layer.canvas` `#0B0C0F` (not black) at a 2 pt gutter, so the tile
   edges are legible as separate frames without drawing a stroke. On a mini-LED/HDR display this
   3.3 L\* difference is exactly enough to see the seam and not enough to read as a border.
5. In cinema mode the canvas *becomes* `#000000` so a single 16:9 stream on a 16:10 display shows
   uninterrupted black.
6. ⛔ Never apply `.opacity()` to a live video layer to fade it. Fading is done by cross-fading a
   sibling overlay (§7.9).

---

## 4. Typography

### 4.1 Families

| Family | Access | Where |
|---|---|---|
| **SF Pro Text** | `Font.system(size:weight:)` at sizes < 20 pt | All UI text. The system resolves the Text optical size automatically below 20 pt. |
| **SF Pro Display** | `Font.system(size:weight:)` at sizes ≥ 20 pt | `Display` and `Title1` only. Optical sizing is automatic; do **not** name the font. |
| **SF Mono** | `Font.system(size:weight:design: .monospaced)` | Telemetry, timecode, IP/MAC addresses, RTSP URLs, log lines, hex, byte counts. |
| **SF Pro Rounded** | — | ⛔ Not used. Rounded reads friendly; Vigil reads instrumental. |

⛔ Never construct fonts by name (`Font.custom("SF Pro Text", size:)`). It breaks optical sizing,
tracking defaults and the `monospacedDigit` variant selector.

### 4.2 The scale — nine display steps plus one Mono track

Line height is the total box height; SwiftUI's `.lineSpacing` value to achieve it is given because
`lineSpacing` adds to the font's natural line height rather than setting it.

| Token | Family | Size | Weight | Line height | `lineSpacing` | Tracking | Case | Use |
|---|---|---|---|---|---|---|---|---|
| `Display` | Display | 28 | `.bold` | 34 | 0 | −0.40 | Sentence | Empty-state hero, onboarding headline, About |
| `Title1` | Display | 22 | `.semibold` | 28 | 1 | −0.30 | Sentence | Sheet titles, Settings pane titles, Discovery header |
| `Title2` | Text | 17 | `.semibold` | 22 | 1 | −0.20 | Sentence | Inspector title, card group headers, palette section |
| `Title3` | Text | 15 | `.semibold` | 20 | 2 | −0.10 | Sentence | Card titles, tile name chip, playback camera name |
| `Headline` | Text | 13 | `.semibold` | 18 | 2 | 0 | Sentence | Sidebar row title, button labels, table headers |
| `Body` | Text | 13 | `.regular` | 18 | 2 | 0 | Sentence | Default UI text, field values, menu items, descriptions |
| `Callout` | Text | 12 | `.medium` | 16 | 1 | 0 | Sentence | Secondary labels, tab titles, inspector field labels |
| `Caption1` | Text | 11 | `.medium` | 14 | 1 | +0.10 | Sentence | Badges, HUD labels, sidebar subtitle, timestamps |
| `Caption2` | Text | 10 | `.semibold` | 13 | 1 | +0.50 | **UPPERCASE** | Section eyebrows, `REC`, `LIVE`, `H.265`, legend keys |
| `Mono` | Mono | 11 | `.medium` | 16 | 2 | 0 | — | All telemetry. `MonoLarge` = 13/18 for the playback timecode; `MonoSmall` = 10/13 for the stats HUD |

### 4.3 Exact `Font` expressions

```swift
public extension VTheme {
    enum Typography {
        // Display track (SF Pro Display resolves automatically at >= 20pt)
        public static let display   = Font.system(size: 28, weight: .bold)
        public static let title1    = Font.system(size: 22, weight: .semibold)
        // Text track
        public static let title2    = Font.system(size: 17, weight: .semibold)
        public static let title3    = Font.system(size: 15, weight: .semibold)
        public static let headline  = Font.system(size: 13, weight: .semibold)
        public static let body      = Font.system(size: 13, weight: .regular)
        public static let callout   = Font.system(size: 12, weight: .medium)
        public static let caption1  = Font.system(size: 11, weight: .medium)
        public static let caption2  = Font.system(size: 10, weight: .semibold)
        // Mono track
        public static let mono      = Font.system(size: 11, weight: .medium, design: .monospaced)
        public static let monoSmall = Font.system(size: 10, weight: .medium, design: .monospaced)
        public static let monoLarge = Font.system(size: 13, weight: .semibold, design: .monospaced)
        // Numeric variants of the Text track — used for every live value
        public static let bodyNum     = body.monospacedDigit()
        public static let headlineNum = headline.monospacedDigit()
        public static let caption1Num = caption1.monospacedDigit()
    }
}
```

Tracking is applied at the call site, because `Font` cannot carry it:

```swift
Text("FRONT DOOR")
    .font(VTheme.Typography.caption2)
    .tracking(0.5)
    .textCase(.uppercase)
    .lineSpacing(1)
```

A convenience view modifier bundles font + tracking + lineSpacing so no call site repeats them:

```swift
extension View {
    func vType(_ step: VTheme.Typography.Step) -> some View {
        self.font(step.font)
            .tracking(step.tracking)
            .lineSpacing(step.lineSpacing)
            .textCase(step.textCase)
    }
}
```

### 4.4 The monospaced-digit rule (⛔ hard)

**Every number that can change while on screen uses `monospacedDigit()`.** No exceptions. The list:
fps, bitrate (kbps/Mbps), packet loss %, jitter ms, latency ms, decode-queue depth, dropped frames,
uptime, timecode, clip duration, camera counts, event counts, storage GB, zoom factor, PTZ speed,
preset numbers, timeline hour labels, and any percentage.

Additionally, every telemetry readout has a **reserved width** so that `9 fps` → `10 fps` does not
reflow its neighbours:

| Readout | Format | Reserved width | Example |
|---|---|---|---|
| fps | `%.0f` + ` fps` | 46 pt | `25 fps` |
| bitrate | `%.1f` + ` Mb/s` | 62 pt | `4.2 Mb/s` |
| latency | `%.0f` + ` ms` | 46 pt | `184 ms` |
| loss | `%.2f` + `%` | 46 pt | `0.04%` |
| jitter | `%.1f` + ` ms` | 46 pt | `2.4 ms` |
| timecode | `HH:mm:ss.SS` | 92 pt (`MonoLarge`) | `14:22:07.48` |
| resolution | `%d×%d` | 74 pt | `1920×1080` |

Implement with `.frame(width: w, alignment: .trailing)` on the `Text`, never with padding.
Units are `text.tertiary`; values are `text.primary` (or `text.secondary` in the tile HUD).

### 4.5 User text-size preference

macOS has no app-wide Dynamic Type. Vigil ships its own: Settings → General → **Interface text size**
= Small / Default / Large, mapping to a scale factor **0.92 / 1.00 / 1.15** stored in
`@AppStorage("ui.textScale")` and injected as `\.vTextScale`. `VTheme.Typography` multiplies sizes by
it and rounds to the nearest 0.5 pt. Control heights (§5.5) scale with `ceil(h × scale / 2) * 2`
so they stay on the 2 pt grid. Icon sizes scale identically. Layout minimums (sidebar width, etc.)
multiply by the same factor.

---

## 5. Space and shape

### 5.1 The 4 pt grid

Base unit **4 pt**. All spacing, padding and offsets come from this named ladder. 2 pt exists only as
an optical half-step (icon-to-label gaps, hairline nudges) and is never used for layout rhythm.

| Token | pt | Primary use |
|---|---|---|
| `space.hair` | 2 | Icon↔label gap in dense rows, tile gutter, badge inner padding |
| `space.xxs` | 4 | Chip inner padding, stacked caption gap, focus-ring inset |
| `space.xs` | 6 | Small-control horizontal padding, list row vertical padding |
| `space.sm` | 8 | Default control horizontal padding, gap between sibling controls |
| `space.md` | 12 | Card padding, inspector row spacing, toolbar item gap |
| `space.lg` | 16 | Panel padding, section gap inside a card, sheet content inset |
| `space.xl` | 20 | Sheet/window content margin, gap between inspector sections |
| `space.xxl` | 24 | Empty-state internal gap, Settings pane margin |
| `space.huge` | 32 | Above/below an empty-state hero, palette top inset |
| `space.jumbo` | 48 | Onboarding vertical rhythm only |

**Fixed structural dimensions** (not tokens to be reinvented per view):

| Dimension | Value |
|---|---|
| Sidebar width | 248 pt default, min 200, max 360, icon-rail collapsed 52 |
| Inspector width | 300 pt default, min 260, max 420 |
| Unified toolbar height | 52 pt (`.unified`), 38 pt (`.unifiedCompact`, used in auxiliary windows) |
| Tile gutter | 2 pt (grid) / 0 pt (video wall — edge-to-edge) |
| Stage outer inset | 8 pt on all sides (0 in cinema mode) |
| Sidebar row height | 44 pt (with micro-thumbnail), 28 pt (group/section child), 22 pt (section header) |
| Timeline strip height | 88 pt (single camera), 44 pt per lane (multi-camera) |
| Toast width | 320 pt fixed; stack inset 20 pt from bottom-trailing |
| Command palette | 640 × auto, max height 520, top inset 132 pt from window top |

### 5.2 Radius scale

| Token | pt | Applies to |
|---|---|---|
| `radius.xs` | 4 | Badge, keycap, inline code, colour swatch, checkbox |
| `radius.sm` | 6 | Chip, 20/24 pt controls, segmented thumb, small stat pill |
| `radius.md` | 8 | Default control (28/32 pt), text field, select, slider track ends |
| `radius.lg` | 10 | Card, inspector section, sidebar selected-row, PTZ preset thumbnail |
| `radius.xl` | 14 | Video tile, popover, floating toolbar, sheet, toast, PTZ pad |
| `radius.xxl` | 20 | Command palette, modal sheet, cinema control bar, onboarding card |
| `radius.full` | `h/2` | Pills, status dots, avatar, live badge, slider knob |

⛔ **All** rounded rectangles use `style: .continuous` (`RoundedRectangle(cornerRadius:style:.continuous)`
or `.rect(cornerRadius:style:.continuous)`). Circular arcs are visibly wrong next to macOS's own
squircles.

**Nesting rule:** `innerRadius = outerRadius − padding`, clamped to `[4, outerRadius]`.
Examples: a chip (`radius.sm` 6) inside a tile (`radius.xl` 14) with 8 pt inset → 14 − 8 = 6 ✓.
A field (`radius.md` 8) inside a card (`radius.lg` 10) with 12 pt padding → clamp to 4… which is
*wrong-looking*, so the real rule has a second clause: **if the computed inner radius is smaller than
the component's own token, keep the component's token.** Fields keep 8. The subtraction rule governs
elements that are *flush* with the parent's edge (a header strip inside a popover, an image filling
the top of a card): those must use exactly `outer − insetFromEdge`.

### 5.3 Shape vocabulary

| Shape | Where |
|---|---|
| Continuous rounded rect | Everything by default |
| Capsule | Status pills, `VChip`, `VBadge` with count, slider knob, live badge |
| Circle | Status dot (6 pt), PTZ pad thumb (28 pt), icon-button hit area on video (28 pt) |
| Hairline rect | Dividers (`stroke.subtle`, 1 px) |

### 5.4 Border widths

| Token | Value | Use |
|---|---|---|
| `border.hairline` | `1 / displayScale` (0.5 pt @2x) | Dividers, glass edge, table rules |
| `border.thin` | 1 pt | Standard control and card borders |
| `border.focus` | 2 pt | Focus ring (plus a 1 pt outer glow, §9) |
| `border.selected` | 2 pt | Selected tile border (`accent`) |
| `border.recording` | 3 pt | Recording tile border (`live`, breathing, §7.5) |

Hairlines are drawn with `@Environment(\.displayScale)`:

```swift
@Environment(\.displayScale) private var scale
var hairline: CGFloat { 1 / scale }   // 0.5 on Retina, 1.0 on a 1x display
```

⛔ Never `Divider()` — its colour and inset are not ours. Use
`Rectangle().fill(VTheme.Color.Stroke.subtle).frame(height: hairline)`.

### 5.5 Standard control heights

Five heights, no others. Every interactive component declares one.

| Token | Height | Radius | H-padding | Font | Icon | Min hit target |
|---|---|---|---|---|---|---|
| `size.xs` | 20 | 6 | 6 | `Caption1` 11 | 11 pt | 24 × 24 (expanded via `contentShape`) |
| `size.sm` | 24 | 6 | 8 | `Callout` 12 | 12 pt | 24 × 24 |
| `size.md` | 28 | 8 | 10 | `Body` 13 | 13 pt | 28 × 28 — **the default** |
| `size.lg` | 32 | 8 | 12 | `Body` 13 | 15 pt | 32 × 32 |
| `size.xl` | 40 | 10 | 16 | `Title3` 15 | 17 pt | 40 × 40 |

Where used: `xs` in tile HUD chips and table cells; `sm` in inspector rows and segmented controls;
`md` everywhere by default (toolbar, forms, menus); `lg` for primary sheet actions and the search
field; `xl` only for the empty-state call to action and the onboarding primary button.

Icon-only buttons are square at their height (28 × 28 for `md`), except on video, where they are
28 × 28 with a 32 × 32 `contentShape` to make them forgiving under a moving cursor.

---

## 6. Elevation and materials

Four elevation levels. Each is a **quadruple**: fill, stroke, inner highlight, shadow. Never mix and
match — an element is at E0, E1, E2 or E3 and takes all four properties of that level.

### 6.1 The four levels

| | **E0 — Inset** | **E1 — Raised** | **E2 — Floating** | **E3 — Modal** |
|---|---|---|---|---|
| Concept | Recessed into its parent | Sits on its parent | Detached, above the window | Above everything, with a scrim |
| Used by | Text fields, sliders, wells, code blocks, timeline track, sparkline background | Cards, selected/hovered rows, segmented control track, stat pills, inspector sections | Popovers, menus, floating tile toolbar, PTZ pad, toasts, tooltips, PiP window | Command palette, sheets, alerts, Discovery modal |
| **Fill** | `layer.canvas` (dark) / `#E9EAEE` (light) | `layer.surfaceRaised` | `.hudWindow` material + glass (§6.5) | `.hudWindow` material + glass (§6.5), `emphasized: true` |
| **Stroke** | `stroke.default` 1 pt, inset | `stroke.default` 1 pt | `stroke.default` 1 pt + hairline glass edge | white α 0.12 (dark) / black α 0.10 (light), 1 pt |
| **Inner highlight** | *inverted*: 1 pt top inner **shadow**, black α 0.24 | 1 pt top inner highlight, white α 0.06 | 1 pt top inner highlight, white α 0.08, fading to clear by 35 % height | 1 pt top inner highlight, white α 0.10, fading to clear by 30 % height |
| **Shadow** | none | `black α 0.35, radius 4, y 2` | `black α 0.44, radius 6, y 3` **+** `black α 0.20, radius 12, y 6` | `black α 0.50, radius 10, y 6` **+** `black α 0.28, radius 24, y 14` |
| Radius | component token | `radius.lg` 10 | `radius.xl` 14 | `radius.xxl` 20 |

SwiftUI's `.shadow(radius:)` is roughly **half** a CSS/Figma Gaussian blur. The radii above are
SwiftUI values; the equivalent Figma blurs are E1 8 pt, E2 12 + 24, E3 20 + 48.

Light appearance uses the same geometry with softer, cooler shadows (macOS light shadows are subtle):
E1 `black α 0.10, radius 3, y 1`; E2 `black α 0.14, radius 5, y 2` + `black α 0.06, radius 12, y 6`;
E3 `black α 0.18, radius 9, y 5` + `black α 0.10, radius 24, y 14`.

⛔ Two shadows means two `.shadow()` modifiers stacked in order (tight first, ambient second). Do not
approximate with one large shadow — the double shadow is what makes E2/E3 read as glass rather than
as a drop-shadowed rectangle.

```swift
// E2 exactly
content
    .background(VGlass(radius: 14))                      // material + highlight + hairline
    .shadow(color: .black.opacity(0.44), radius: 6,  x: 0, y: 3)
    .shadow(color: .black.opacity(0.20), radius: 12, x: 0, y: 6)
```

### 6.2 Modal scrim

E3 dims what is behind it: `Color.black.opacity(0.44)` over the whole window (dark) /
`Color.black.opacity(0.22)` (light), fading in over 140 ms `easeOut`, out over 100 ms. The scrim is
**not** applied over video wells in cinema mode — there the palette floats over black already.
The scrim intercepts clicks (dismiss) and is `accessibilityHidden(true)`.

### 6.3 Elevation on video

⛔ Shadows are never cast onto a video well. A shadow over live imagery is visible as a dirty smear
and costs an offscreen pass. Chrome on video uses the **scrim ladder** (§2.3) plus a 1 pt
`white α 0.14` stroke, with **no** shadow. The only exception is the cinema control bar, which gets
E3's shadow because it sits on a black canvas where the shadow is invisible anyway (it is kept for
the light-appearance case and for HDR content).

### 6.4 Inner highlight construction

The "1 pt top inner highlight" is a vertically-clipped gradient stroke, not a solid line — a solid
1 pt white line around a 14 pt corner looks like a bevel:

```swift
struct VInnerHighlight: View {
    let radius: CGFloat
    let opacity: Double      // 0.06 E1, 0.08 E2, 0.10 E3
    let fadeStop: Double     // 0.35 E2, 0.30 E3
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    stops: [.init(color: .white.opacity(opacity), location: 0),
                            .init(color: .white.opacity(opacity * 0.35), location: fadeStop * 0.5),
                            .init(color: .clear, location: fadeStop)],
                    startPoint: .top, endPoint: .bottom),
                lineWidth: 1)
            .blendMode(.plusLighter)     // dark appearance only
    }
}
```

`.plusLighter` is used in dark appearance so the highlight adds light rather than painting grey; in
light appearance use `.normal` and drop the highlight to α 0.60 white (it reads as a specular edge on
the material).

### 6.5 The glass recipe

Used by every E2/E3 surface: floating tile toolbar, command palette, popovers, menus, toasts, PTZ
pad, sheets, the cinema control bar.

```swift
struct VGlass: View {
    let radius: CGFloat
    var emphasized: Bool = false
    @Environment(\.displayScale) private var scale
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            // 1. Base material (or solid fallback)
            if reduceTransparency {
                VTheme.Color.Layer.overlay
            } else {
                VVisualEffect(material: .hudWindow,
                              blending: .withinWindow,
                              state: .active,
                              emphasized: emphasized)
            }
            // 2. A 4% tint so the material never goes lighter than L5 over bright backdrops
            VTheme.Color.Layer.overlay.opacity(scheme == .dark ? 0.28 : 0.12)
            // 3. 1pt top inner highlight, 8% white, fading out by 35% height
            VInnerHighlight(radius: radius, opacity: reduceTransparency ? 0 : 0.08, fadeStop: 0.35)
            // 4. Hairline edge
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(VTheme.Color.Stroke.default, lineWidth: 1 / scale)
        }
        .clipShape(.rect(cornerRadius: radius, style: .continuous))
        .compositingGroup()
    }
}
```

Three details that matter:

1. **Step 2 (the tint) is not optional.** A bare `.hudWindow` over a bright video frame or a white
   document goes almost white and the 8 % highlight vanishes. The 28 % overlay tint pins the glass to
   a known luminance band so text contrast is predictable (`text.primary` ≥ 11:1 in the worst case).
2. `.compositingGroup()` before the shadows so the two shadows are cast by the composited glass shape,
   not by each sublayer.
3. The `NSViewRepresentable` wrapper must set `state: .active`, not `.followsWindowActiveState`, for
   E2/E3 — a popover that greys out when the window loses focus looks broken. Sidebar and inspector
   *do* follow window state.

```swift
struct VVisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blending: NSVisualEffectView.BlendingMode
    let state: NSVisualEffectView.State
    var emphasized: Bool = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material; v.blendingMode = blending; v.state = state
        v.isEmphasized = emphasized
        v.autoresizingMask = [.width, .height]
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material; v.blendingMode = blending; v.state = state
        v.isEmphasized = emphasized
    }
}
```

---

## 7. Motion

Motion is the part of this system that will make or break the customer's "rich animation"
requirement, and it is also the part most likely to cost video frames. Both concerns are addressed
here: a small, strictly-enumerated vocabulary (§7.1), a per-interaction contract (§7.4–7.8), and a
hard performance rule with an enforcement mechanism (§7.9).

### 7.1 The vocabulary — six springs and four curves

| Token | SwiftUI | `.spring(duration:bounce:)` equivalent | Overshoot | ~Settle | Use |
|---|---|---|---|---|---|
| `motion.micro` | `.spring(response: 0.22, dampingFraction: 0.86, blendDuration: 0)` | `.spring(duration: 0.22, bounce: 0.14)` | 0.5 % | 0.30 s | Hover, press, toggle, checkbox, dot state, chip appear, icon swap |
| `motion.standard` | `.spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0)` | `.spring(duration: 0.34, bounce: 0.18)` | 1.1 % | 0.50 s | **Default.** Sidebar/inspector reveal, popover, layout change, tab switch, row insert |
| `motion.expressive` | `.spring(response: 0.50, dampingFraction: 0.70, blendDuration: 0)` | `.spring(duration: 0.50, bounce: 0.30)` | 4.6 % | 0.95 s | Reserved for exactly three things: tile→fullscreen, cinema enter/exit, video-wall handoff |
| `motion.snap` | `.spring(response: 0.16, dampingFraction: 1.00, blendDuration: 0)` | `.spring(duration: 0.16, bounce: 0)` | 0 % | 0.22 s | Segmented thumb, keycap depress, PTZ nudge, stepper, sort-arrow flip |
| `motion.glide` | `.spring(response: 0.42, dampingFraction: 0.95, blendDuration: 0.10)` | `.spring(duration: 0.42, bounce: 0.05)` | 0.007 % | 0.55 s | Anything the user was dragging and let go of: timeline pan/zoom, digital-zoom settle, mosaic divider, scroll-to-item |
| `motion.rubber` | `.spring(response: 0.30, dampingFraction: 0.62, blendDuration: 0)` | `.spring(duration: 0.30, bounce: 0.38)` | 8.4 % | 0.70 s | Rejection/limit feedback only: PTZ at a mechanical limit, timeline at 00:00, invalid drop |

**Non-spring curves** (for opacity, colour, blur, shimmer — things with no physical mass):

| Token | SwiftUI | Duration | Use |
|---|---|---|---|
| `motion.fadeIn` | `.timingCurve(0.0, 0.0, 0.20, 1.0, duration: 0.18)` | 180 ms | Entrance opacity, blur-in, scrim in, chrome reveal |
| `motion.fadeOut` | `.timingCurve(0.40, 0.0, 1.0, 1.0, duration: 0.12)` | 120 ms | Exit opacity, chrome dismiss, scrim out. **Exits are always faster than entrances.** |
| `motion.crossfade` | `.easeInOut(duration: 0.24)` | 240 ms | First-frame reveal, appearance switch, thumbnail replace |
| `motion.emphasized` | `.timingCurve(0.32, 0.72, 0.0, 1.0, duration: 0.28)` | 280 ms | Emphasised decelerate for non-spring position moves (toast slide, banner drop) |

**Repeating curves:**

| Token | SwiftUI | Use |
|---|---|---|
| `motion.breathe` | `.easeInOut(duration: 1.0).repeatForever(autoreverses: true)` | Live-dot pulse (2 s full cycle), recording border |
| `motion.shimmer` | `.linear(duration: 1.15).repeatForever(autoreverses: false)` | Skeleton sweep |
| `motion.spin` | `.linear(duration: 0.9).repeatForever(autoreverses: false)` | Reconnect ring |

⛔ There are no other animation values in the app. A code review that finds
`withAnimation(.easeInOut(duration: 0.3))` rejects the change.

### 7.2 Timing constants

| Constant | Value | Meaning |
|---|---|---|
| `hoverInDelay` | 0 ms | Hover chrome appears immediately… |
| `hoverOutDelay` | 260 ms | …and lingers, so moving between two buttons in a tile toolbar does not flicker |
| `stagger` | 18 ms | Per-item delay in a staggered entrance |
| `staggerCap` | 12 items | After 12 items, remaining items all use the 12th delay (216 ms) — see §7.8 |
| `tooltipDelay` | 500 ms | Hover to tooltip |
| `pressMinDuration` | 80 ms | A press visual is held at least this long even on a fast click, so a click is always *seen* |
| `optimisticTimeout` | 1200 ms | Optimistic UI reverts and shows an error if the device has not confirmed |
| `idleChromeHide` | 2500 ms | Cinema mode chrome auto-hide |
| `skeletonMinDuration` | 220 ms | If the first frame arrives sooner, the skeleton is still shown this long — prevents a flash |

### 7.3 How animation is applied

Three mechanisms, chosen deliberately:

1. **`withAnimation(_:)`** for state changes driven by an event (a click, a shortcut, a delegate
   callback). Always name the token: `withAnimation(VTheme.Motion.standard) { isSidebarVisible.toggle() }`.
2. **`.animation(_, value:)`** for derived visual state that follows a model value (a status dot
   colour following `camera.state`). Value-scoped, never the deprecated implicit form.
3. **`.transaction { }`** to *strip* animation from a subtree — the single most important tool in this
   app (§7.9).

Two SwiftUI 5 (macOS 14) APIs are used heavily and deserve rules:

- **`PhaseAnimator`** for looping, discrete-phase animations that must keep running without state
  churn: live dot, recording border, reconnect ring, shimmer, `wifi` variable-colour. Prefer it over
  `repeatForever` when there is more than one animated property per phase, because each phase can
  carry its own animation curve.
- **`KeyframeAnimator`** for one-shot, multi-track choreography where properties move on different
  timelines: snapshot flash, toast entrance, PTZ limit bump, error shake, palette icon pop.
  ⛔ Never use `KeyframeAnimator` for a looping animation — it re-creates its timeline on every
  `trigger` change and will leak CPU when the trigger is a live value.
- **`.contentTransition(.numericText(countsDown:))`** for every changing number in a heading position
  (event counts, camera counts, big timecode). For dense telemetry it is *off* — 25 numeric-text
  transitions per second per tile is a measurable cost. Rule: `numericText` only for values that
  change at ≤ 2 Hz.
- **`.symbolEffect(...)`** for icon feedback (§8.4).

### 7.4 Per-interaction motion contract

This table is normative. Column *Property* lists exactly what animates; anything not listed does not
animate. `RM` = the `accessibilityReduceMotion` fallback.

| # | Interaction | Property: from → to | Token | Delay / stagger | RM fallback |
|---|---|---|---|---|---|
| 1 | **Sidebar reveal** (`⌘L`) | Width 0 → 248; content `offset(x: −16 → 0)` + `opacity 0 → 1` | `standard` | Content 40 ms after width starts | Width change with `.animation(nil)`; content `opacity` over 120 ms |
| 2 | **Sidebar collapse to rail** | Width 248 → 52; labels `opacity 1 → 0` + `offset(x: 0 → −8)`; icons stay | `standard` | Labels lead by 0 ms, finish at 60 % | Instant width; labels cross-fade 120 ms |
| 3 | **Inspector reveal** (`⌘⌥I`) | Width 0 → 300; content `offset(x: 16 → 0)` + opacity | `standard` | Content 40 ms | As #1 |
| 4 | **Grid layout change** (`⌘1`…`⌘9`) | Each tile's frame, via `matchedGeometryEffect` in a shared namespace keyed by `camera.id` | `standard` | 0 — all tiles move together, **no stagger** (staggered reflow looks broken) | Frames snap; a 100 ms opacity cross-fade over the whole stage |
| 5 | **Tile → fullscreen** (double-click / `⌘F`) | `matchedGeometryEffect` frame + `cornerRadius 14 → 0`; chrome `opacity 1 → 0`; canvas → `#000000` | `expressive` | Chrome fades out over the first 140 ms; the name chip persists and re-anchors | Cross-fade 160 ms between grid and fullscreen; no geometry match |
| 6 | **Fullscreen → grid** | Reverse of #5 | `expressive`, but `response 0.42` | — | As #5 |
| 7 | **Tile appearance** (added to grid) | `scale 0.96 → 1.0`, `opacity 0 → 1` | `standard` for scale, `fadeIn` for opacity | 18 ms × index, capped at 12 | Opacity only, 140 ms, no stagger |
| 8 | **Tile removal** | `scale 1.0 → 0.98`, `opacity 1 → 0` | `fadeOut` (120 ms) | Reverse index × 10 ms | Opacity only, 100 ms |
| 9 | **Connecting → first frame** | Skeleton shimmer (§7.6) `opacity 1 → 0` + `blur 0 → 4`; video layer `opacity 0 → 1` | `crossfade` (240 ms) | Video starts at 0 ms; skeleton out over the full 240 ms | Skeleton `opacity` 120 ms linear, no blur |
| 10 | **Live-dot pulse** | `scale 1.0 → 1.18`, `opacity 1.0 → 0.55`, halo `scale 1 → 2.2` / `opacity 0.35 → 0` | `breathe` (2 s cycle) via `PhaseAnimator` | Phase-locked to a shared clock so every dot in the window pulses in unison | No animation; dot is static at `scale 1.0`, `opacity 1.0` |
| 11 | **Recording tile border** | 3 pt `live` border `opacity 0.55 → 1.0` | `breathe`, 2 s | Unison with #10 | Static at `opacity 0.9` |
| 12 | **PTZ press** | Pad thumb `offset` follows cursor 1:1 (no animation while dragging); on release `offset → .zero` | dragging: none; release: `glide` | — | Release: `offset → .zero` with `.animation(nil)` |
| 13 | **PTZ arrow-key nudge** | Direction arrow `scale 1.0 → 1.12 → 1.0`, `opacity 0.6 → 1 → 0.6` | `snap` in, `fadeOut` out | — | Colour change only |
| 14 | **PTZ at mechanical limit** | Pad ring `offset ±3 pt` in the blocked axis, 2 oscillations | `rubber` | — | 1-shot `warn` tint of the ring, 200 ms |
| 15 | **Command palette open** (`⌘K`) | `scale 0.97 → 1.0`, `opacity 0 → 1`, `blur 6 → 0`, `offset(y: −6 → 0)`; scrim `opacity 0 → 0.44` | `standard` for scale/offset; `fadeIn` 180 ms for opacity+blur | Scrim 0 ms, panel 20 ms | `opacity` 120 ms; no scale, no blur, no offset |
| 16 | **Command palette close** | Reverse; `scale → 0.98` | `fadeOut` 120 ms | — | `opacity` 90 ms |
| 17 | **Palette result-list update** | Rows: `opacity` + `offset(y: 4 → 0)`; selection bar via `matchedGeometryEffect` | `micro` for rows, `snap` for the selection bar | 8 ms × index, cap 8 | Rows instant; selection bar instant |
| 18 | **Toast slide-in** | `offset(y: 24 → 0)`, `scale 0.96 → 1`, `opacity 0 → 1` — via `KeyframeAnimator` (3 tracks) | `emphasized` 280 ms overall | Stack shifts existing toasts with `standard` | `opacity` 140 ms only |
| 19 | **Toast auto-dismiss** | `offset(x: 0 → 12)`, `opacity 1 → 0` | `fadeOut` 120 ms | After 4 s (6 s if it has an action) | `opacity` 100 ms |
| 20 | **Timeline scrub magnetism** | Playhead x snaps to the nearest of: segment boundary, event marker, whole minute — when within 6 pt | `snap` on the snap itself; the drag is 1:1 unanimated | — | Snapping still occurs (it is functional), but `.animation(nil)`; a `Haptic`-equivalent is the 1-frame playhead thickening |
| 21 | **Timeline zoom** (scroll / pinch) | `scale` of the lane content + label cross-fade at each of the 6 zoom tiers | `glide`; labels `crossfade` | — | Instant tier change; labels instant |
| 22 | **Hover elevation lift** | Card/row: `shadow opacity ×1.35`, `shadow y +1`, fill → `surfaceRaised`, `stroke.default → stroke.strong`. **No `scale`, no `offset`** on rows. | `micro` | in 0 ms / out 260 ms | Fill and stroke change only, `micro` |
| 23 | **Hover on a tile** | Chrome group `opacity 0 → 1` + `offset(y: 4 → 0)`; name chip `opacity 0.7 → 1` | `micro` | in 0 ms / out 260 ms | `opacity` only, 120 ms |
| 24 | **Button press** | `scale 1.0 → 0.97` (min 0.985 for `xl`), fill → pressed token | `snap` down, `micro` up | Held ≥ 80 ms | Fill change only |
| 25 | **Focus ring appear** | Ring `opacity 0 → 1`, `lineWidth 0 → 2`, outer glow `blur 0 → 3` and `scale 1.06 → 1.0` | `micro` | — | `opacity` 0 → 1 in 100 ms, no scale |
| 26 | **Focus ring move** (Tab) | The ring is a single `matchedGeometryEffect` element in the `focus` namespace, so it *travels* between controls | `snap` | — | No travel: fade out 60 ms / in 60 ms at the new location |
| 27 | **Segmented control** | Thumb frame via `matchedGeometryEffect`; labels `foregroundStyle` cross-fade | `snap` | — | Thumb instant; label colour instant |
| 28 | **Toggle** | Knob `offset`, track fill, knob `scale 1 → 1.06 → 1` | `micro` (knob), `fadeIn` (track colour) | — | Instant offset + colour |
| 29 | **Popover / menu open** | `scale 0.96 → 1` anchored at the source edge, `opacity`, `offset(y: −4 → 0)` | `standard` | — | `opacity` 100 ms |
| 30 | **Sheet present** | `offset(y: 12 → 0)`, `scale 0.98 → 1`, `opacity`; scrim | `standard`, scrim `fadeIn` | Panel 30 ms after scrim | `opacity` 140 ms |
| 31 | **Inspector tab switch** | Content `opacity` + `offset(x: ±8 → 0)` in the travel direction; selection underline via `matchedGeometryEffect` | `standard` content, `snap` underline | — | `opacity` 120 ms, no offset |
| 32 | **Sparkline update** | New point appended; the path animates via an `Animatable` `path` interpolation over 200 ms; the x-window slides left | `.linear(duration: 0.20)` — linear because the data arrives at a fixed 1 Hz and any easing reads as jitter | — | Path replaced instantly |
| 33 | **Stat pill value change** | `.contentTransition(.numericText(countsDown:))`, digits roll vertically | `micro` | — | `.contentTransition(.identity)` |
| 34 | **Badge count change** | `.symbolEffect(.bounce.up, options: .nonRepeating)` on the bell + numeric text roll | `micro` | — | No bounce; number replaced |
| 35 | **Snapshot flash** | `KeyframeAnimator`: white overlay `opacity 0 → 0.85 → 0` (60 ms up, 180 ms down) + tile `scale 1 → 0.985 → 1` + shutter sound | custom keyframes | — | A 400 ms `motion`-coloured 2 pt border pulse instead of a flash (photosensitivity) |
| 36 | **Drag a camera (reorder / to a tile)** | Ghost `scale 1 → 1.04`, `opacity 1 → 0.9`, E2 shadow; list gap opens with `standard`; drop target `accent α 0.32` fill + 2 pt `accent` dashed stroke, dash phase animating | `micro` for pick-up, `standard` for gaps | — | No scale/shadow; drop target uses a solid 2 pt border |
| 37 | **Invalid drop** | Ghost returns to origin | `rubber` | — | `fadeOut` + instant return |
| 38 | **Reconnect countdown** | Ring `trim(from: 0, to: progress)` driven by a `TimelineView(.animation)` at 30 fps; label counts down | linear, data-driven | — | Ring hidden; text only ("Retrying in 4 s") |
| 39 | **Degraded banner** | `offset(y: −28 → 0)` inside the tile top, `opacity` | `emphasized` | Appears only after 1.5 s of sustained degradation (debounce) | `opacity` 140 ms |
| 40 | **Cinema mode enter** | Window fullscreen (system) + chrome `opacity → 0` + canvas → `#000000` + stage inset 8 → 0 | `expressive` for inset, `fadeOut` for chrome | Chrome out first (120 ms), then inset | Inset instant; chrome `opacity` 120 ms |
| 41 | **Cinema chrome reveal** | Control bar `offset(y: 16 → 0)` + `opacity`; cursor un-hides | `standard` in, `fadeOut` out after 2.5 s idle | — | `opacity` only |
| 42 | **Digital zoom (scroll)** | `scale` and `offset` of the Metal texture transform — applied in the renderer, **not** by SwiftUI | `glide` on release; 1:1 during scroll | — | 1:1 with no settle animation |
| 43 | **Patrol / cycle advance** | Outgoing tile `opacity 1 → 0` + `scale 1 → 1.02`; incoming `opacity 0 → 1` + `scale 0.98 → 1` | `crossfade` 240 ms | — | Hard cut |
| 44 | **Empty state appear** | Icon `scale 0.9 → 1` + `opacity`; title, body, button stagger | `standard` | 40 ms stagger, 3 items | `opacity` 160 ms, no stagger |
| 45 | **Error shake** (auth failure) | `KeyframeAnimator` on `offset(x:)`: 0 → −6 → 5 → −3 → 1.5 → 0 over 380 ms | custom cubic keyframes | — | `danger` border pulse 300 ms, no offset |
| 46 | **Skeleton → content (lists)** | Rows cross-fade; skeleton `blur 0 → 3` | `crossfade` | — | `opacity` 120 ms |
| 47 | **Window appearance switch** | All colours cross-fade | `standard` | — | Instant |
| 48 | **Menu-bar extra live badge** | Dot `opacity 0.6 → 1.0` | `breathe` 2 s (only while recording) | — | Static |

### 7.5 Live-dot pulse — reference implementation

Every "is this alive" indicator in the app is this component, and they all pulse **in unison**
(unison is the difference between a professional cockpit and a Christmas tree). Unison is achieved by
driving the phase from a single `TimelineView(.periodic(from: .now, by: 1.0))` in the window root,
published through `\.vPulsePhase`, rather than by 16 independent `PhaseAnimator`s.

```swift
struct VLiveDot: View {
    let state: VCameraState              // .connecting / .live / .degraded / .offline
    @Environment(\.vPulsePhase) private var phase       // Bool, flips every 1.0s, window-wide
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var noColor

    var body: some View {
        ZStack {
            // Halo — live only
            if state == .live && !reduceMotion {
                Circle()
                    .fill(VTheme.Color.Semantic.live)
                    .frame(width: 6, height: 6)
                    .scaleEffect(phase ? 2.2 : 1.0)
                    .opacity(phase ? 0.0 : 0.35)
                    .animation(VTheme.Motion.breathe, value: phase)
            }
            shape                                  // Circle, or a differentiating shape (§10.5)
                .fill(state.colour)
                .frame(width: 6, height: 6)
                .scaleEffect(reduceMotion ? 1.0 : (phase ? 1.18 : 1.0))
                .opacity(reduceMotion ? 1.0 : (phase ? 0.55 : 1.0))
                .animation(reduceMotion ? nil : VTheme.Motion.breathe, value: phase)
        }
        .frame(width: 14, height: 14)              // 14pt box → hit/label alignment
        .accessibilityHidden(true)                 // the parent row announces state in words
    }
}
```

`.connecting` uses `motion.spin` on a 1.5 pt trimmed ring instead of a pulse; `.degraded` is a static
`warn` dot with a 1 pt ring; `.offline` is a hollow 6 pt circle with a 1 pt `text.tertiary` stroke and
no fill.

### 7.6 Skeleton and shimmer

```swift
struct VSkeleton: View {
    var radius: CGFloat = 6
    @State private var x: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Rectangle()
            .fill(VTheme.Color.Layer.surfaceRaised)
            .overlay {
                if !reduceMotion {
                    LinearGradient(stops: [
                        .init(color: .clear,                location: 0.00),
                        .init(color: .white.opacity(0.055), location: 0.45),
                        .init(color: .white.opacity(0.075), location: 0.50),
                        .init(color: .white.opacity(0.055), location: 0.55),
                        .init(color: .clear,                location: 1.00)
                    ], startPoint: .leading, endPoint: .trailing)
                    .scaleEffect(x: 2.2, anchor: .leading)          // wide, soft sweep
                    .offset(x: x * 220)
                    .blendMode(.plusLighter)
                }
            }
            .clipShape(.rect(cornerRadius: radius, style: .continuous))
            .onAppear { withAnimation(VTheme.Motion.shimmer) { x = 1 } }
            .accessibilityLabel("Loading")
    }
}
```

Sweep period 1.15 s, travel 220 pt, gradient peak α 0.075 white. In `reduceMotion` the skeleton is a
static `surfaceRaised` block — still communicating "not yet", with no movement.

**Tile connecting skeleton** is not a grey block: it is `#000000` (the well) with a centred 32 pt
`VLiveDot(.connecting)` ring, the camera name in `Title3`, a narration line in `Caption1`
`text.tertiary` that advances through the real connection stages ("Resolving…", "Connecting…",
"Authenticating…", "Negotiating stream…", "Waiting for keyframe…"), and a 1 pt shimmer sweep along
the bottom edge of the tile. The narration text changes with `.contentTransition(.opacity)` and
`micro`.

### 7.7 `matchedGeometryEffect` architecture

Three namespaces, declared once in `VMainWindowView` and passed down through the environment — never
created ad-hoc inside a subview (a `@Namespace` recreated on redraw silently disables the effect).

| Namespace | IDs | Governs |
|---|---|---|
| `stage` | `camera.id.uuidString` | Grid cell ↔ fullscreen ↔ PiP ↔ video wall. `isSource` is true for the grid cell. |
| `focus` | `"ring"` (single ID) | The travelling focus ring |
| `selection` | `"segmented.\(groupID)"`, `"tab.\(tabGroupID)"` | Segmented thumbs and tab underlines |

```swift
// Grid cell
VTile(camera: camera)
    .matchedGeometryEffect(id: camera.id.uuidString, in: ns.stage,
                           properties: .frame, anchor: .center,
                           isSource: !isFullscreen)
```

⛔ **The video layer is not what animates.** `matchedGeometryEffect` interpolates the *container's*
frame; during the transition the container shows a **still proxy** (§7.9) and the live layer is
re-attached at the end. This is the single most important implementation note in this section.

### 7.8 Loading choreography for a 16-tile grid

The scenario: user opens a 4×4 layout with 16 cameras. Naïvely this is 16 skeletons, 16 shimmer
animations, 16 spinners and 16 spring entrances arriving at random times over 3 s — visual noise, and
~9 % of a P-core spent on UI.

The choreography:

| t | What happens |
|---|---|
| 0 ms | All 16 tile *frames* are laid out at once, filled `#000000`. No animation on the frames. The grid is instantly, correctly shaped. |
| 0–216 ms | Tiles fade/scale in with an 18 ms stagger in **reading order** (row-major), capped at 12 — items 13–16 share the 216 ms delay. `scale 0.96 → 1`, `opacity 0 → 1`. |
| 60 ms | Name chips appear (`opacity`, `micro`), all at once — not staggered. |
| 120 ms | Connecting rings appear, all phase-locked to the shared pulse clock. Only **one** shimmer instance is created: a single `TimelineView` publishes the sweep offset and all 16 tiles read it, so there is one animation driver, not 16. |
| 120 ms+ | Per-tile narration lines advance independently as the real RTSP state machine progresses. |
| first frame per tile | 240 ms `crossfade` from ring+narration to video, **per tile, as they arrive** — deliberately unsynchronised, because a synchronised reveal would mean waiting for the slowest camera. Minimum skeleton duration 220 ms. |
| all connected | The stage's aggregate progress chip in the toolbar (`4 of 16 live`) counts up with `numericText` and then fades out 800 ms after reaching 16. |

Concurrency guards: at most **12** entrance springs run simultaneously (the cap); exactly **1**
shimmer driver; exactly **1** pulse clock; connecting rings are `trim`-animated by the shared clock,
not by 16 `repeatForever` animations.

### 7.9 ⛔ The video-frame rule

**No UI animation may reduce any video stream below 60 fps, and no UI animation may cause a video
layer's geometry to be mutated more than once per transition.**

Five mechanisms enforce it:

**1. Overlays animate on the compositor, never by re-laying-out video.**
Permitted animated properties on anything that overlaps or contains a video layer: `opacity`,
`scaleEffect`, `offset`, `rotationEffect`, `blur` *on the overlay itself*, `shadow` opacity, colour.
Forbidden: animating a video layer's `frame`, `bounds`, `videoGravity`, `cornerRadius`, `mask`,
`clipShape`, or the layout of any container that owns a video layer, at more than 1 Hz.

**2. The still-proxy transition.** Any transition that changes a tile's frame (layout change,
fullscreen, PiP handoff, mosaic resize, window resize while dragging) uses `VTileTransitionProxy`:

```
begin:  renderer publishes the last decoded frame as a CGImage (already retained for snapshots)
        → proxy Image view fades in over 1 frame (8 ms) and the AVSampleBufferDisplayLayer is
          set isHidden = true (NOT removed — teardown would drop the decode session)
during: SwiftUI animates the proxy Image's frame freely; the decoder keeps running and enqueueing
        (frames are dropped-to-latest by the display layer, so we resume live, not behind)
end:    layer bounds set once to the final rect, isHidden = false, proxy fades out over 8 ms
```

Cost: one `CGImage` per transitioning tile (≈ 8 MB for 16 tiles at 1080p, released immediately).
Benefit: zero `AVSampleBufferDisplayLayer` bounds churn, which otherwise forces a
`CAMetalLayer`/IOSurface re-allocation per frame and visibly stutters.

**3. Transaction stripping at the video boundary.** `VVideoLayerView` (the `NSViewRepresentable`) sets

```swift
.transaction { $0.animation = nil; $0.disablesAnimations = true }
```

so no ambient `withAnimation` from an ancestor can ever animate it. Window resize similarly:
`NSWindow` live-resize is detected (`inLiveResize`) and the stage sets
`Transaction(animation: nil)` for its duration, plus a single re-layout on `windowDidEndLiveResize`.

**4. A motion budget, measured.** `VMotionGovernor` (in `VigilUI`) subscribes to the render pipeline's
frame-time signal from `VigilRender` and holds a degradation ladder. Trigger: two consecutive 250 ms
windows where any stream's presented fps < 60 (or the UI's own frame time p99 > 8.0 ms at 120 Hz).

| Tier | Action |
|---|---|
| **T0** normal | Everything on |
| **T1** | Drop the live-dot halos, drop sparkline path animation (jump to new path), drop hover shadow animation (instant), reduce stagger 18 → 0 ms |
| **T2** | Drop all shimmer, drop `numericText` transitions, drop tile entrance springs (opacity only), reduce sidebar micro-thumbnail refresh 4 → 1 Hz |
| **T3** | Behave exactly as `reduceMotion`: no springs anywhere, 120 ms cross-fades only. A `Caption1` note appears in the Stream Doctor panel: "Reduced interface animation to protect video performance." |

Recovery: one tier per 3 s of clean frames, so it never oscillates.

**5. Hard budget numbers**

| Budget | Limit |
|---|---|
| UI frame time (main thread), p99 | ≤ 8.0 ms at 120 Hz, ≤ 12 ms at 60 Hz |
| Concurrent spring animations, window-wide | ≤ 24 |
| Concurrent spring animations per tile | ≤ 3 |
| Animation drivers (`repeatForever` / `TimelineView`) window-wide | ≤ 4 (pulse clock, shimmer, reconnect ring, timeline playhead) |
| Offscreen render passes caused by chrome | ≤ 2 per frame (glass composite, focus glow) |
| `drawingGroup()` usage | Only on `VSparkline` and the timeline heatmap; nowhere else |
| Blur radius animated per-frame | Never on video; ≤ 6 pt on overlays, and only during a 180 ms entrance |

### 7.10 Global `reduceMotion` policy

`@Environment(\.accessibilityReduceMotion)` is read once at the window root and re-published as
`\.vMotionEnabled` (also false when the motion governor reaches T3). Every animation token has a
reduced form, resolved centrally so no call site has to branch:

```swift
extension VTheme.Motion {
    /// Returns nil (no animation) or a 120ms crossfade when motion is reduced.
    static func resolved(_ token: Animation, reduced: Bool,
                         fallback: Animation? = .easeInOut(duration: 0.12)) -> Animation? {
        reduced ? fallback : token
    }
}

// call site
withAnimation(VTheme.Motion.resolved(.standard, reduced: !motionEnabled)) { ... }
```

Rules for reduced motion, in priority order:
1. **Nothing that conveys state may disappear** — a pulse becomes a static dot, never nothing.
2. **Position and scale changes become cross-fades** at 120 ms.
3. **Continuous/looping motion stops entirely** (shimmer, halo, spin) and is replaced by a static
   indicator plus, where the delay could exceed 3 s, a text narration.
4. **Functional motion is kept**: timeline snapping, drag tracking, digital zoom, scrolling — these
   are the user's own movement, not decoration.
5. **Flashes are never substituted with other flashes.** The snapshot flash becomes a border pulse.

---

## 8. Iconography

### 8.1 Sizes and weights

Symbols are paired to the text they sit beside. Use `Font.system(size:weight:)` on the `Image`, not
`.imageScale`, so the size is exact.

| Icon token | Size | Weight | Paired type | Optical alignment |
|---|---|---|---|---|
| `icon.xs` | 11 | `.semibold` | `Caption1`/`Caption2` | Baseline-align; 2 pt gap to label |
| `icon.sm` | 12 | `.medium` | `Callout` | 4 pt gap |
| `icon.md` | 13 | `.medium` | `Body`/`Headline` | 6 pt gap — **the default** |
| `icon.lg` | 15 | `.medium` | `Title3` | 6 pt gap |
| `icon.xl` | 17 | `.regular` | `Title2`/`Title1` | 8 pt gap |
| `icon.hero` | 32 | `.light` | Empty states, connecting rings | Centred |
| `icon.brand` | 18 | — | Menu-bar extra (template image) | Centred in an 18 × 18 box |

⛔ Icon weight is never heavier than the adjacent text weight, and never `.bold` above 13 pt — heavy
SF Symbols at large sizes look like clip art.

### 8.2 Rendering modes

| Mode | When | Example |
|---|---|---|
| `.monochrome` | **Default for ~90 % of the app.** Tinted by `foregroundStyle` from the text token. | Toolbar buttons, list rows, menus |
| `.hierarchical` | Multi-layer glyphs where depth aids recognition, tinted with one colour. | `externaldrive.badge.exclamationmark`, `video.badge.waveform`, `bolt.fill` in the hardware-decode pill |
| `.palette` | Exactly two-tone status glyphs where the badge must carry a different semantic colour. | `bell.badge` (glyph `text.secondary`, badge `motion`), `record.circle` (ring `text.secondary`, dot `live`) |
| `.multicolor` | ⛔ **Forbidden**, with two exceptions: the Settings window's pane icons, and the About window. Apple's multicolour palettes clash with the dark cockpit and break the P3 colour rule. |

Variable-value symbols are used for magnitude: `Image(systemName: "wifi", variableValue: signal)`
(0…1 from RTCP round-trip + loss), `Image(systemName: "speaker.wave.3", variableValue: volume)`,
`Image(systemName: "internaldrive", variableValue: diskUsedFraction)`.

### 8.3 The action → symbol map

Every action in Vigil. `Variant` column: `—` = base glyph; `.fill` = filled variant; `alt` = the
second glyph used for the opposite/active state.

| Action / concept | SF Symbol | Variant | Weight | Mode | Notes |
|---|---|---|---|---|---|
| **App / navigation** ||||||
| Vigil brand mark | `vigil.aperture` | custom | — | mono | §8.5; menu-bar extra + About |
| Toggle sidebar | `sidebar.leading` | — | `.medium` | mono | `⌘L` |
| Toggle inspector | `sidebar.trailing` | — | `.medium` | mono | `⌘⌥I` |
| Command palette | `command` | — | `.semibold` | mono | Also drawn as a `VKeyCap` |
| Search | `magnifyingglass` | — | `.medium` | mono | `/` |
| Settings | `gearshape` | `.fill` when active | `.medium` | mono | `⌘,` |
| Help | `questionmark.circle` | — | `.medium` | mono | |
| Close / dismiss | `xmark` | — | `.semibold` | mono | 11 pt in chips, 13 pt in sheets |
| Disclosure | `chevron.right` / `chevron.down` | — | `.semibold` | mono | Rotates 90° with `snap`, never swapped |
| Menu indicator | `chevron.up.chevron.down` | — | `.semibold` | mono | `VSelect` |
| **Cameras** ||||||
| Camera (generic) | `video` | `.fill` when live | `.medium` | mono | |
| Camera offline | `video.slash` | `.fill` | `.medium` | hierarchical | `text.tertiary` |
| Add camera | `plus` | — | `.semibold` | mono | In a `VButton(.primary)` |
| Discover / scan | `antenna.radiowaves.left.and.right` | — | `.medium` | mono | `.symbolEffect(.variableColor.iterative)` while scanning |
| NVR / device | `externaldrive.connected.to.line.below` | — | `.medium` | hierarchical | |
| Channel | `rectangle.stack` | — | `.medium` | mono | |
| Group | `folder` | `.fill` when selected | `.medium` | mono | |
| New group | `folder.badge.plus` | — | `.medium` | mono | |
| Rename | `pencil` | — | `.medium` | mono | |
| Delete | `trash` | — | `.medium` | mono | `danger` tint in menus |
| Reorder handle | `line.3.horizontal` | — | `.medium` | mono | `text.tertiary`, appears on row hover |
| Credentials | `key.horizontal` | `.fill` | `.medium` | mono | |
| Locked / secure | `lock` | `.fill` | `.medium` | mono | TLS indicator |
| Insecure (plain HTTP) | `lock.open.trianglebadge.exclamationmark` | — | `.medium` | hierarchical | `warn` |
| **Layout / stage** ||||||
| Single view | `square` | — | `.medium` | mono | `⌘1` |
| 2×2 | `square.grid.2x2` | — | `.medium` | mono | `⌘2` |
| 3×3 | `square.grid.3x3` | — | `.medium` | mono | `⌘4` |
| 4×4 | `square.grid.4x3.fill` | — | `.medium` | mono | `⌘5`; approximate glyph, see note |
| Mosaic layouts (1+5, 1+7, 2+8, custom) | *drawn, not a symbol* | — | — | — | `VLayoutGlyph` draws a live 16×16 `Canvas` miniature of the actual mosaic. Decision: real miniatures beat approximate symbols for layout pickers. |
| Enter fullscreen | `arrow.up.left.and.arrow.down.right` | — | `.medium` | mono | `⌘F` |
| Exit fullscreen | `arrow.down.right.and.arrow.up.left` | — | `.medium` | mono | |
| Cinema mode | `film` | `.fill` when active | `.medium` | mono | `⌘⌃F` |
| Picture in picture | `pip.enter` / `pip.exit` | alt | `.medium` | mono | |
| Video wall / second display | `display.2` | — | `.medium` | hierarchical | |
| Cycle / patrol view | `play.square.stack` | `.fill` when running | `.medium` | mono | |
| Aspect fit | `aspectratio` | — | `.medium` | mono | |
| Aspect fill | `aspectratio.fill` | — | `.medium` | mono | |
| Mainstream (high quality) | `dial.high` | `.fill` when active | `.medium` | mono | |
| Substream (low quality) | `dial.low` | `.fill` when active | `.medium` | mono | |
| **Media actions** ||||||
| Snapshot | `camera` | `.fill` on press | `.medium` | mono | `⌘⇧S` |
| Snapshot all | `camera.on.rectangle` | — | `.medium` | hierarchical | |
| Copy to clipboard | `doc.on.doc` | — | `.medium` | mono | |
| Record (start) | `record.circle` | — | `.medium` | palette (ring `text.secondary`, dot `live`) | `⌘R` |
| Recording (active) | `record.circle.fill` | `.fill` | `.medium` | mono, `live` | `.symbolEffect(.pulse)` at T0 only |
| Stop | `stop.fill` | `.fill` | `.medium` | mono | |
| Mute | `speaker.slash.fill` | `.fill` | `.medium` | mono | |
| Unmuted | `speaker.wave.2.fill` | `.fill` | `.medium` | mono | variableValue = volume |
| Push to talk | `mic` / `mic.fill` | alt | `.medium` | mono | `.fill` + `live` while transmitting |
| Export clip | `square.and.arrow.up` | — | `.medium` | mono | `⌘E` |
| Trim in/out | `scissors` | — | `.medium` | mono | |
| Import CSV/JSON | `square.and.arrow.down` | — | `.medium` | mono | |
| **Playback** ||||||
| Play | `play.fill` | `.fill` | `.medium` | mono | `Space`; swap to pause with `.contentTransition(.symbolEffect(.replace.downUp))` |
| Pause | `pause.fill` | `.fill` | `.medium` | mono | |
| Back 10 s | `gobackward.10` | — | `.medium` | mono | `←` |
| Forward 10 s | `goforward.10` | — | `.medium` | mono | `→` |
| Frame back | `backward.frame.fill` | `.fill` | `.medium` | mono | `⌥←` |
| Frame forward | `forward.frame.fill` | `.fill` | `.medium` | mono | `⌥→` |
| Speed | `speedometer` | — | `.medium` | mono | Opens a `VSelect` of 0.25×…8× |
| Reverse | `backward.fill` | `.fill` | `.medium` | mono | |
| Jump to live | `forward.end.alt.fill` | `.fill` | `.medium` | mono | |
| Date picker | `calendar` | — | `.medium` | mono | |
| Time / uptime | `clock` | — | `.medium` | mono | `clock.arrow.circlepath` for uptime |
| Bookmark | `bookmark` / `bookmark.fill` | alt | `.medium` | mono | |
| Synchronised playback | `link` | — | `.medium` | mono | |
| **PTZ** ||||||
| PTZ pad | `vigil.ptz.joystick` | custom | — | mono | §8.5 |
| Zoom in / out | `plus.magnifyingglass` / `minus.magnifyingglass` | — | `.medium` | mono | |
| Focus near / far | `viewfinder.circle` | — | `.medium` | hierarchical | Paired with `+`/`−` keycaps |
| Iris open / close | `camera.aperture` | — | `.medium` | hierarchical | |
| Preset | `star` / `star.fill` | alt | `.medium` | mono | `.fill` = assigned |
| Set preset | `star.square.on.square` | — | `.medium` | hierarchical | |
| Patrol | `arrow.triangle.capsulepath` | — | `.medium` | mono | |
| Home position | `house` | — | `.medium` | mono | |
| 3D positioning | `viewfinder.rectangular` | — | `.medium` | mono | Drag-a-box on the tile |
| **Image settings** ||||||
| Image panel | `slider.horizontal.3` | — | `.medium` | mono | |
| Brightness | `sun.max` | — | `.medium` | mono | variableValue |
| Contrast | `circle.lefthalf.filled` | — | `.medium` | mono | |
| Saturation | `drop` | `.fill` | `.medium` | mono | |
| Sharpness | `camera.filters` | — | `.medium` | hierarchical | |
| WDR | `sun.haze` | `.fill` | `.medium` | hierarchical | |
| Day / night mode | `moon.stars` | `.fill` when night | `.medium` | hierarchical | |
| IR illuminator | `flashlight.on.fill` | `.fill` | `.medium` | mono | `warn` when forced on |
| Flip / mirror | `arrow.left.and.right.righttriangle.left.righttriangle.right` | — | `.medium` | mono | |
| **Events / alarms** ||||||
| Events feed | `bell` | `.fill` when unread | `.medium` | palette | Badge = `motion` |
| New events | `bell.badge` | — | `.medium` | palette | `.symbolEffect(.bounce.up)` once per arrival |
| Motion detection | `figure.walk` | — | `.medium` | mono | `motion` tint |
| Line crossing | `line.diagonal` | — | `.semibold` | mono | |
| Intrusion | `rectangle.dashed` | — | `.medium` | mono | |
| Tamper | `hand.raised.slash` | `.fill` | `.medium` | mono | `danger` |
| Video loss | `video.slash` | `.fill` | `.medium` | mono | `danger` |
| Disk error | `externaldrive.badge.exclamationmark` | — | `.medium` | hierarchical | `danger` |
| Notification settings | `bell.and.waves.left.and.right` | — | `.medium` | hierarchical | |
| **Diagnostics / telemetry** ||||||
| Stream Doctor | `stethoscope` | — | `.medium` | mono | |
| Health graph | `waveform.path.ecg` | — | `.medium` | mono | |
| Hardware decode | `bolt.fill` | `.fill` | `.semibold` | mono, `ok` | Hollow `bolt` + `text.tertiary` when software |
| CPU | `cpu` | — | `.medium` | hierarchical | |
| Network | `network` | — | `.medium` | hierarchical | |
| Signal / link quality | `wifi` | — | `.medium` | mono | variableValue |
| Packet loss | `chart.line.downtrend.xyaxis` | — | `.medium` | mono | `warn`/`danger` |
| Latency | `timer` | — | `.medium` | mono | |
| Storage | `internaldrive` | — | `.medium` | hierarchical | variableValue = used |
| Reconnecting | `arrow.triangle.2.circlepath` | — | `.medium` | mono | Rotates with `motion.spin` |
| Export diagnostics | `doc.text.magnifyingglass` | — | `.medium` | hierarchical | |
| Log level | `text.alignleft` | — | `.medium` | mono | |
| Reset | `arrow.counterclockwise` | — | `.medium` | mono | |
| **Status / feedback** ||||||
| Success | `checkmark.circle.fill` | `.fill` | `.medium` | mono, `ok` | |
| Warning | `exclamationmark.triangle.fill` | `.fill` | `.medium` | mono, `warn` | |
| Error | `xmark.octagon.fill` | `.fill` | `.medium` | mono, `danger` | |
| Info | `info.circle` | `.fill` in toasts | `.medium` | mono, `accent` | |
| Status dot | `circle.fill` | `.fill` | — | mono | Replaced by `VLiveDot` in practice |
| Keyboard shortcuts | `keyboard` | — | `.medium` | mono | |
| Appearance | `circle.lefthalf.filled` | — | `.medium` | mono | |
| Launch at login | `power` | — | `.medium` | mono | |

Note on `square.grid.4x3.fill`: there is no exact 4×4 SF Symbol. The layout picker uses
`VLayoutGlyph` miniatures for **all** layout modes (including 1, 2×2, 3×3) so the set is internally
consistent; the SF Symbols above are used only in the menu bar, where a drawn glyph is not available.

### 8.4 Symbol effects

| Effect | Where | Guard |
|---|---|---|
| `.symbolEffect(.bounce.up, options: .nonRepeating, value: eventCount)` | Bell on new event | Off in `reduceMotion` and at governor T1 |
| `.symbolEffect(.pulse, options: .repeating)` | `record.circle.fill` while recording | Off in `reduceMotion`; replaced by the static `live` fill |
| `.symbolEffect(.variableColor.iterative.dimInactiveLayers)` | `antenna.radiowaves…` while discovery is scanning | Off in `reduceMotion`; replaced by a `Caption1` "Scanning…" |
| `.contentTransition(.symbolEffect(.replace.downUp))` | play↔pause, mute↔unmute, fit↔fill, mainstream↔substream | `.replace.offUp` is used when the two glyphs differ in size class |
| `.symbolEffect(.appear)` | Checkmarks confirming an optimistic action | Always allowed (100 ms, no loop) |

### 8.5 The two custom symbols

Both are authored as SF Symbols 5 `.svg` templates exported from the Apple template, with all three
weights we use (Regular, Medium, Semibold) and all three scales (S/M/L), and shipped in
`VigilUI/Resources/Symbols.xcassets`. They are referenced with `Image(systemName:)` (custom symbols
resolve through the asset catalogue) and honour `foregroundStyle`, `imageScale` and `symbolRenderingMode`.

**1. `vigil.aperture`** — the brand mark. A six-blade aperture: six identical circular-segment blades
arranged at 60° intervals around a centre, each blade a 2.0-unit-wide stroke path, forming a hexagonal
opening at the centre whose inscribed circle is 34 % of the outer diameter. The gap between blade tips
is 1.5 units. Reads as a lens iris at 18 pt and as a hexagonal ring at 11 pt. Has a `.fill` variant
where the blades are solid and the centre is knocked out. Used: menu-bar extra (as a **template**
image, `isTemplate = true`), About window, empty state hero, the `⌘K` palette's default row icon.

**2. `vigil.ptz.joystick`** — a four-way pad. A rounded-square outline (corner radius 4 units on a
20-unit square, stroke 1.5) containing four small triangular arrowheads inset 2.5 units from each edge
midpoint, plus a 3-unit filled centre dot. Distinguishable at 11 pt (SF Symbols' `dpad` reads as a
game controller, and `arrow.up.and.down.and.arrow.left.and.right` reads as "move window" — neither
communicates *pan/tilt*). Has a `.fill` variant with a solid pad. Used: inspector PTZ tab icon, the
palette's PTZ actions, the tile hover toolbar's PTZ button.

⛔ No other custom symbols. If a concept needs an icon that SF Symbols lacks, it gets a drawn
`Canvas`/`Shape` (like `VLayoutGlyph`), not a new symbol — symbols must stay maintainable across SF
Symbols releases.

---

## 9. Component inventory

Every component lives in `VigilUI/Components/`, is prefixed `V`, takes no colours or fonts as
parameters (only semantic variants), and has a `#Preview` covering **every state in its table**.

States are always these six: **rest, hover, pressed, focused, disabled, loading.** A component that
cannot be in a state says so.

### 9.1 `VButton`

```swift
VButton("Add Camera", icon: "plus", style: .primary, size: .md) { … }

enum VButtonStyle { case primary, secondary, ghost, destructive, icon }
enum VButtonSize  { case xs, sm, md, lg, xl }   // maps to §5.5 heights
```

**Geometry** (from §5.5): height/radius/padding/font per size. Icon + label gap 6 pt (`md`). Icon-only
buttons are square. Label is `Body` for `secondary`/`ghost`, `Headline` (semibold) for
`primary`/`destructive`. Multi-word labels never wrap; they truncate with `.tail` at a 220 pt max.

| State | primary | secondary | ghost | destructive | icon (on chrome) | icon (on video) |
|---|---|---|---|---|---|---|
| **rest** | fill `accentFill`, text/icon white, stroke none, E1 shadow (`black α 0.35 r4 y2`) | fill `surfaceRaised`, stroke `stroke.default`, text `text.primary` | fill clear, stroke none, text `text.secondary` | fill `dangerFill`, text white, E1 | fill clear, icon `text.secondary` | fill `scrim.base` (black α 0.62), icon `text.primary`, stroke `white α 0.14` |
| **hover** | fill `accentHover`, shadow ×1.35 | fill `surfaceRaised` + white α 0.04, stroke `stroke.strong` | fill `white α 0.06`, text `text.primary` | fill `#D93A2B`, shadow ×1.35 | fill `white α 0.06`, icon `text.primary` | fill black α 0.74, icon white, stroke `white α 0.22` |
| **pressed** | fill `accentPressed`, `scale 0.97`, shadow → none | fill `white α 0.10`, `scale 0.97` | fill `white α 0.10`, `scale 0.97` | fill `#B8281A`, `scale 0.97` | fill `white α 0.12`, `scale 0.94` | fill black α 0.86, `scale 0.94` |
| **focused** | rest + focus ring (§9.28) | rest + ring | rest + ring | rest + ring | rest + ring | rest + ring inset 2 pt |
| **disabled** | fill `accentFill α 0.30`, text `white α 0.45` | fill `surface`, stroke `stroke.subtle`, text `text.disabled` | text `text.disabled` | fill `dangerFill α 0.30`, text `white α 0.45` | icon `text.disabled` | n/a — chrome hides instead |
| **loading** | fill unchanged, label `opacity 1 → 0` + a 13 pt trimmed ring (`motion.spin`, 1.5 pt, white) cross-faded in over 120 ms; **width is frozen** at the label width so the button never resizes | same, ring `accent` | same | same, ring white | icon → ring | icon → ring |

Rules: `pressMinDuration` 80 ms (§7.2). Press `scale` anchors `.center`. Only **one**
`primary` button may be visible in any container; a second becomes `secondary`. `destructive` requires
a confirmation (`VPopover` with "Delete" / "Cancel") unless the action is undoable.
`.keyboardShortcut` is declared on the button, not the parent, so the menu bar can mirror it.

### 9.2 `VSegmentedControl`

Track: height per size (`sm` 24 / `md` 28), fill `layer.canvas` (E0), stroke `stroke.default`, radius
`radius.sm` 6, inner padding 2 pt. Thumb: fill `surfaceRaised`, stroke `stroke.strong`, radius 4,
E1 shadow, animated with `matchedGeometryEffect(id: "segmented.\(id)", in: ns.selection)` + `snap`.
Segment min width 44 pt, equal widths by default; `.hugging` mode sizes to content.

| State | Selected segment | Unselected segment |
|---|---|---|
| rest | text `text.primary` (`Headline`), thumb visible | text `text.secondary` (`Body`) |
| hover | — | text `text.primary`, fill `white α 0.04` |
| pressed | thumb `scale 0.98` | fill `white α 0.08` |
| focused | 2 pt ring around the **track**, not the thumb; `←`/`→` move selection | — |
| disabled | thumb fill `surface`, text `text.disabled` | text `text.disabled` |
| loading | n/a | n/a |

Used for: layout family, transport (TCP/UDP), latency preset, aspect mode, appearance,
timeline density, inspector tabs (in `.hugging` mode with an underline instead of a thumb).

### 9.3 `VToggle`

Track 32 × 18 pt, radius `full` (9). Knob 14 pt circle, inset 2 pt, fill white, E1 shadow
(`black α 0.30 r2 y1`). Off track: `layer.canvas` + `stroke.default`. On track: `accentFill`, no
stroke. Knob travel 14 pt.

| State | Off | On |
|---|---|---|
| rest | track `canvas`, stroke `stroke.default`, knob `text.secondary` → actually white α 0.85 | track `accentFill`, knob white |
| hover | stroke `stroke.strong` | track `accentHover` |
| pressed | knob `scale 1.06` (`micro`) | knob `scale 1.06` |
| focused | 2 pt ring, 3 pt outset, radius `full` | same |
| disabled | track `surface`, knob `white α 0.35` | track `accentFill α 0.30`, knob `white α 0.6` |
| loading | Track shows an indeterminate 1 pt `accent` sweep along its top edge while an optimistic device write is pending; reverts with a `rubber` bounce + toast on failure (`optimisticTimeout` 1200 ms) | same |

Label sits leading, `Body`, 8 pt gap; the whole row (label + toggle) is the hit target and is
`.contentShape(Rectangle())`. Row min height 28 pt.

### 9.4 `VSlider`

Track height 4 pt, radius `full`, E0. Inactive fill `white α 0.12`; active (leading) fill `accent`.
Knob 14 pt circle, white, E1 shadow, 1 pt `black α 0.20` stroke. Tick marks (optional) 1 × 4 pt
`white α 0.18` below the track at 8 pt spacing. Value label: `Mono` 11, `text.secondary`,
trailing, reserved width per §4.4.

| State | Spec |
|---|---|
| rest | as above |
| hover | knob `scale 1.14`, track height 4 → 5 pt (`micro`); value label `opacity 0.7 → 1` |
| pressed / dragging | knob `scale 1.20`, active fill `accentHover`, value label promoted to `Headline` and pinned above the knob in a 20 pt `scrim.base` capsule; **no animation on the knob position** (1:1 tracking) |
| focused | 2 pt ring around the knob, `←`/`→` = ±1 step, `⌥←/→` = ±0.1 step, `⇧` = ×10 |
| disabled | track `white α 0.06`, active fill `white α 0.10`, knob `text.disabled` |
| loading | Optimistic: knob moves immediately; a 1 pt `accent` underline pulses beneath the track until the device confirms; on failure the knob returns with `rubber` and a toast |

Bipolar variant (brightness/contrast, −100…+100): the active fill grows from the centre; a 1 pt
`white α 0.28` centre detent is drawn and the knob snaps to 0 within 2 pt (`snap`).

### 9.5 `VTextField`

Height `md` 28 (`lg` 32 for the search field), radius `radius.md` 8, fill `layer.canvas` (E0), stroke
`stroke.default`, inner top shadow `black α 0.24` 1 pt. H-padding 10 pt (10 + 20 when there is a
leading icon). Text `Body` `text.primary`; placeholder `text.tertiary`. Monospaced variant for
host/IP/port/URL fields (`Mono` 11) with `.autocorrectionDisabled()` and
`.textContentType(nil)`.

| State | Spec |
|---|---|
| rest | as above; label above in `Callout` `text.secondary`, 4 pt gap |
| hover | stroke `stroke.strong` |
| focused | stroke `accent` 1 pt **and** a 2 pt `focusRing α 0.35` outer glow at 3 pt outset; caret `accent`; selection `accent α 0.30` |
| disabled | fill `surface`, stroke `stroke.subtle`, text `text.disabled`, no caret |
| invalid | stroke `danger` 1 pt; inline message below (§below) |
| loading / validating | 13 pt trimmed ring (`accent`, 1.5 pt, `motion.spin`) at the trailing edge, replacing any clear button |
| valid (async-confirmed) | `checkmark.circle.fill` `ok` 13 pt at the trailing edge, `.symbolEffect(.appear)`, auto-hides after 2 s |

**Inline validation:** validation runs on (a) `.onSubmit`, (b) focus loss, and (c) debounced 400 ms
after typing stops — never on every keystroke. The message appears **below** the field: 16 pt row,
`Caption1`, `danger`, with an 11 pt `exclamationmark.triangle.fill`, entering with
`offset(y: −4 → 0)` + `opacity` on `micro`. The field's container reserves the 16 pt so nothing below
it moves. Copy is specific and actionable: "Port must be between 1 and 65535", not "Invalid input".

### 9.6 `VSearchField`

`VTextField` at `lg` 32 with radius `radius.md` 8 (not a capsule — capsule search fields read as iOS),
leading `magnifyingglass` 13 pt `text.tertiary` (→ `text.secondary` on focus), trailing
`xmark.circle.fill` 13 pt clear button that appears with `micro` when non-empty. Placeholder
"Search cameras" / "Search events". `/` focuses it from anywhere; `Esc` clears then blurs (two-stage).
A trailing `VKeyCap("/")` at `text.tertiary` shows while unfocused and empty, cross-fading out on
focus. Scoped variant adds a `VSelect` pill at the leading edge ("All", "Live", "Offline").

### 9.7 `VSelect` (pop-up)

Height per size, radius `radius.md` 8, fill `surfaceRaised` (E1), stroke `stroke.default`, trailing
`chevron.up.chevron.down` 11 pt `text.tertiary` with 8 pt leading gap. Menu is a native `Menu` styled
by `VPopover` rules: E2 glass, radius `radius.xl` 14, item height 24, item radius 6, item hover fill
`accent α 0.16`, checkmark leading at 13 pt `accent`, section headers `Caption2` uppercase
`text.tertiary`, dividers `stroke.subtle` hairline with 4 pt insets.

| State | Spec |
|---|---|
| rest / hover / pressed / focused / disabled | as `VButton(.secondary)` |
| loading | Value text → `VSkeleton` 60 × 11 pt; chevron `text.disabled` |

### 9.8 `VBadge`

Height 16 pt (`xs` 14 for inline), radius `radius.xs` 4 (or `full` for counts), H-padding 5 pt,
`Caption2` uppercase, tracking +0.5. Variants:

| Variant | Fill | Text | Use |
|---|---|---|---|
| `.neutral` | `white α 0.10` | `text.secondary` | `H.265`, `1080P`, `SUB` |
| `.accent` | `accent α 0.18` | `accent` | `NEW`, `BETA` |
| `.live` | `liveFill` | white | `REC` — plus a 4 pt pulsing dot leading |
| `.ok` | `okFill α 0.22` | `ok` | `HW` (hardware decode) |
| `.warn` | `warn α 0.20` | `warn` | `DEGRADED` |
| `.danger` | `dangerFill α 0.22` | `danger` | `OFFLINE`, `AUTH` |
| `.count` | `motion` | `text.inverse` | Event counts; radius `full`, min width 16, `numericText` transition |

On video, all variants swap their fill for `scrim.base` + a 1 pt stroke in the variant colour, so the
badge never brightens the frame. States: rest only (badges are not interactive). A badge inside an
interactive row inherits that row's hover/pressed but does not change itself.

### 9.9 `VChip`

Height 20 pt, radius `radius.sm` 6, H-padding 6 pt, `Caption1`, optional 6 pt leading dot or 11 pt
icon, optional trailing 11 pt `xmark` (removable). Two families:

- **Identity chip** (camera name on a tile): fill `scrim.base`, text `text.primary`, leading 6 pt
  dot in the camera's `ident` colour plus, when `differentiateWithoutColor`, the camera's initial in
  `Caption2` inside the dot's place (9 pt box).
- **Filter chip** (events, discovery): rest fill `white α 0.08` / stroke none; selected fill
  `accent α 0.18` / stroke `accent α 0.40` / text `accent`.

| State | Spec |
|---|---|
| rest | per family |
| hover | fill +α 0.04; removable `xmark` `opacity 0 → 1` |
| pressed | `scale 0.97` |
| focused | 2 pt ring at 2 pt outset |
| disabled | text `text.disabled`, fill `white α 0.04` |
| loading | `VSkeleton` at the chip's exact size |

### 9.10 `VCard`

Fill `layer.surface`, stroke `stroke.default` 1 pt, radius `radius.lg` 10, padding `space.md` 12
(`space.lg` 16 for cards with a header), E1 shadow only when the card is interactive or draggable —
static content cards get **no** shadow (flat cards read as structure; shadowed cards read as objects).
Optional header: 28 pt row, `Title3` + trailing accessory, hairline `stroke.subtle` divider beneath,
full-bleed to the card edges (so the divider uses `outer − 0` and the header's top corners follow the
nesting rule: 10 pt).

| State (interactive cards) | Spec |
|---|---|
| rest | as above |
| hover | fill `surfaceRaised`, stroke `stroke.strong`, shadow ×1.35 y+1 (`micro`) |
| pressed | `scale 0.995` (cards are large; 0.97 looks broken), fill `white α 0.03` over `surfaceRaised` |
| focused | 2 pt ring at 3 pt outset, radius 13 |
| disabled | `opacity 0.5`, no hover |
| loading | Content replaced by `VSkeleton` blocks matching the real layout's boxes (never a generic spinner) |

### 9.11 `VToolbar` (floating glass)

The tile hover toolbar and the cinema control bar. Height 32 pt (tile) / 56 pt (cinema). Radius
`radius.xl` 14 (tile) / `radius.xxl` 20 (cinema). Background: **on video → `scrim.base` solid**
(§2.3); **over chrome → E2 glass**. Item spacing 2 pt; group separators = 1 × 16 pt
`white α 0.14` with 6 pt margins. Content inset 6 pt. Items are `VButton(.icon, size: .md)`.

Tile toolbar item order (leading → trailing), all 28 × 28: mute, snapshot, record, PTZ,
substream/mainstream, aspect, PiP, fullscreen, close. Overflow: if the tile's width < 44 × visible
items + 12, items are removed from the **middle** outward in this priority (keep first and last):
PiP → aspect → substream → PTZ → record → snapshot; the removed ones move into an `ellipsis` menu.
Below 120 pt tile width, the toolbar is replaced by a single 28 pt `ellipsis.circle` button.

Placement: tile toolbar is bottom-trailing, 8 pt inset. Appears on hover (§7.4 #23) with
`hoverOutDelay` 260 ms. Never appears while the tile is being dragged or while the mouse is
mid-scroll (digital zoom).

### 9.12 `VSidebarRow`

Height 44 pt. Layout, leading → trailing:

```
[2pt ident rail][8][40×22 thumbnail][8][ name (Headline, 1 line)          ][6][dot][8]
                                        [ H.265 · 1080p · 25 (Caption1)   ]
                                        [ ▁▂▅▃▁ 60×10 motion spark        ]  ← right of subtitle
```

- **Ident rail:** 2 × 28 pt rounded (radius 1) in the camera's `ident` colour, leading edge, `opacity`
  0.9. Hidden for non-camera rows.
- **Thumbnail:** 40 × 22 pt (16:9), radius `radius.xs` 4, `#000000` well, updated at **4 Hz** from the
  decoder's already-decoded frames via a downscale to 80 × 44 px (never a separate decode). While
  connecting it is a `VSkeleton`; offline it is the last frame at `opacity 0.35` with an 11 pt
  `video.slash` centred.
- **Status dot:** `VLiveDot` in a 14 pt box.
- **Motion spark:** 60 × 10 pt `VSparkline` of the last 60 s of motion energy, `motion` colour at
  α 0.7, only drawn when the row is hovered or the camera has had motion in the last 5 min.
- **Subtitle:** `Caption1` `text.tertiary`, `monospacedDigit`, truncates before the name does.

| State | Spec |
|---|---|
| rest | fill clear |
| hover | fill `white α 0.05`, radius `radius.lg` 10, inset 6 pt from the sidebar edges; reorder handle fades in leading (replacing the rail) |
| pressed | fill `white α 0.09` |
| **selected** | fill `accent α 0.16`, 1 pt `accent α 0.30` stroke, name → `text.primary` semibold; when the window is inactive the fill drops to `white α 0.08` and the stroke to `stroke.default` |
| selected + hover | fill `accent α 0.22` |
| focused (keyboard) | selected treatment + 2 pt focus ring |
| disabled | n/a (rows are never disabled; an unreachable camera is *offline*, which is content, not state) |
| loading | Name → 90 × 11 skeleton, subtitle → 60 × 9 skeleton, thumbnail → skeleton |
| drag source | `opacity 0.4`; the drag ghost is the row at `scale 1.04` with E2 shadow |
| drop target (into group) | 2 pt `accent` dashed stroke (dash 4/3, phase animating at 12 pt/s), fill `accent α 0.32` |
| drop target (between rows) | 2 pt `accent` insertion line with 6 pt round caps, inset 12 pt, entering with `snap` |

Icon-rail collapsed mode (52 pt): thumbnail centred at 36 × 20, dot overlaid bottom-trailing at 6 pt,
name hidden, tooltip after `tooltipDelay`.

### 9.13 `VTile` — the video cell

The most important component in the app.

```
┌──────────────────────────────────────────┐  radius 14 (continuous)
│                                          │  well #000000, isOpaque
│              [ live video ]              │  AVSampleBufferDisplayLayer / Metal
│                                          │
│ ●Front Door                    ⌁ REC ▮   │  ← name chip (BL), status cluster (TR)
│                    [◍ ⚙ ⏺ ✥ ⤢ ⋯]        │  ← hover toolbar (BR), 8pt inset
└──────────────────────────────────────────┘
```

| Element | Spec |
|---|---|
| Well | `#000000`, radius `radius.xl` 14, `clipShape(.rect(cornerRadius: 14, style: .continuous))`, no stroke at rest |
| Gutter | 2 pt between tiles; stage inset 8 pt |
| Name chip | `VChip` identity variant, bottom-**leading**, 8 pt inset. At rest `opacity 0.70`; on hover 1.0. Hidden entirely when the tile is < 160 pt wide unless hovered. |
| Status cluster | Top-**trailing**, 8 pt inset, `HStack(spacing: 4)`: hardware-decode `bolt.fill` (`ok`, only when HW), audio state, `REC` badge, `VLiveDot`. Each is a `VBadge`/`VChip` on `scrim.base`. |
| Stats HUD | Toggled per-tile (`I`) or always-on in Settings. Top-**leading**, 8 pt inset, `MonoSmall` 10 pt `text.secondary` on `scrim.base`, radius `radius.sm` 6, padding 4/6, 3 lines: `1920×1080 · 25 fps`, `4.2 Mb/s · 0.02% loss`, `184 ms · q2 · HW`. Reserved widths per §4.4. |
| Hover toolbar | §9.11 |
| Selection | 2 pt `accent` inner stroke (drawn inset by 1 pt so it is not clipped), plus a 1 pt `accent α 0.25` outer glow at radius 15 |
| Focus (keyboard) | 2 pt `focusRing` inner stroke + 3 pt `focusRing α 0.30` outer glow; distinct from selection by the lighter tint and the glow |
| Recording | 3 pt `live` inner stroke, breathing α 0.55 ↔ 1.0 (§7.4 #11) |
| Degraded | Top banner inside the tile: 20 pt, `scrim.strong`, `Caption1` `warn`, "Packet loss 2.4 %", entering after a 1.5 s debounce |
| Offline | Last frame at `opacity 0.30` + `scrim.strong` + centred 32 pt `video.slash` `text.tertiary` + `Title3` "No signal" + `Caption1` reconnect countdown ring (§7.4 #38) + a `VButton(.secondary, .sm)` "Retry now" |
| Auth failure | Same layout, `lock.trianglebadge.exclamationmark`, "Sign-in failed", primary action "Update credentials…" |
| Empty cell | `layer.canvas` fill, 1 pt `stroke.default` **dashed** (dash 4/4), centred 22 pt `plus` `text.tertiary`, `Caption1` "Drop a camera"; hover → stroke `accent`, fill `accent α 0.10` |
| Loading | §7.6 tile skeleton |
| Aspect | `.resizeAspect` default; letterbox bars `#000000`; fill mode crops via the renderer's texture transform, never via `clipped()` on a resized layer |

Interaction: single-click selects (and focuses); double-click → fullscreen (`expressive`,
`matchedGeometryEffect`); scroll → digital zoom 1.0…8.0× (renderer); drag with `⌥` → pan when zoomed;
right-click → `VContextMenu`; `⌥`+arrows → move focus between tiles; drag-and-drop → reassign camera.

⛔ The tile never animates its own `cornerRadius`, `frame` or `clipShape` while video is live —
all such transitions go through `VTileTransitionProxy` (§7.9).

### 9.14 `VTimeline`

Height 88 pt (single) / 44 pt per lane (multi). Structure top → bottom:

| Band | Height | Spec |
|---|---|---|
| Ruler | 16 pt | Hour/minute labels in `MonoSmall` 10 `text.tertiary`; major ticks 1 × 6 pt `white α 0.22`, minor 1 × 3 pt `white α 0.10`. Six zoom tiers: 24 h, 6 h, 1 h, 15 m, 5 m, 1 m — labels change per tier with `crossfade`. |
| Density heatmap | 28 pt | The recording map. Continuous = `continuous` `#3B9CFF` α 0.55; motion = `motion` `#FF9F0A` α 0.75; alarm = `live` `#FF2E43` α 0.90; gap = `white α 0.05`. Drawn in a single `Canvas` with `.drawingGroup()`; segments quantised to 1 px at the current tier. Overlapping types stack: alarm > motion > continuous. |
| Event markers | 10 pt | 6 pt inverted triangles in the event's semantic colour, at `text.primary` α 0.9 stroke on hover; click = jump. |
| Scrub track | 24 pt | E0 track; the playhead is a 2 pt `text.primary` vertical line with a 10 pt `text.primary` circular cap at the top and a 1 pt `black α 0.6` outline so it is visible over every heatmap colour. |
| Selection (in/out) | overlay | `accent α 0.22` fill between handles; handles are 4 × full-height `accent` bars with 8 pt grab areas; a `MonoSmall` duration pill floats above the centre. |

Interaction: drag = scrub with a **live preview thumbnail** (160 × 90, radius `radius.sm` 6, E2, 12 pt
above the cursor, `#000000` well, decoded on a background actor, showing a `VSkeleton` until ready);
scroll = pan; `⌥`scroll / pinch = zoom about the cursor (`glide` on release); magnetism per §7.4 #20
(6 pt to segment boundaries, event markers, whole minutes); `⇧`drag = select a range.

| State | Spec |
|---|---|
| rest | as above |
| hover | Ruler labels `opacity 0.7 → 1`; a 1 pt `white α 0.30` cursor line follows the pointer with a `MonoSmall` time pill at the top |
| pressed / scrubbing | Playhead cap `scale 1.0 → 1.25` (`snap`); heatmap `opacity 1 → 0.8` so the playhead dominates; preview thumbnail visible |
| focused | 2 pt ring around the whole strip; `←/→` = ±1 s, `⇧` = ±10 s, `⌥` = ±1 frame, `⌘←/→` = previous/next event |
| disabled (no recordings) | Heatmap replaced by a 4 pt `white α 0.05` bar and a centred `Caption1` "No recordings on this day" |
| loading | Heatmap is a shimmering `VSkeleton` bar; the ruler is drawn immediately (it is known) so the component does not change size |

### 9.15 `VPTZPad`

152 × 152 pt. Outer ring: 152 pt circle, 1.5 pt `stroke.strong` stroke, fill `layer.canvas` (E0) with
a subtle radial `white α 0.03` centre. Four direction arrows (11 pt `chevron` glyphs) at the ring's
edge midpoints, `text.tertiary`; four diagonal ticks at 45° (1 × 5 pt `white α 0.14`). Thumb: 28 pt
circle, fill `surfaceRaised`, 1 pt `stroke.strong`, E2 shadow, with a 6 pt `accent` centre dot.
Max travel radius 52 pt. Speed = `min(1, |offset| / 52)` mapped through a 1.6 gamma so slow moves are
precise; direction = `atan2`. Continuous-move commands are sent at 10 Hz while displaced and a
`stop` on release.

| State | Spec |
|---|---|
| rest | thumb centred; arrows `text.tertiary` |
| hover | ring stroke → `white α 0.24`; arrows → `text.secondary` |
| dragging | thumb follows the cursor 1:1 (**no animation**); an `accent α 0.25` wedge (60° wide) is drawn from the centre in the active direction; the active arrow → `accent`; a `MonoSmall` "speed 0.42" pill sits below the pad |
| key-nudge | Arrow keys: the corresponding arrow `scale 1.0 → 1.12 → 1.0` (`snap`) and a 200 ms move command; `⇧` = fast, `⌥` = single step |
| at limit | §7.4 #14 `rubber` bump + the blocked arrow tints `warn` for 300 ms |
| focused | 2 pt ring around the whole 152 pt circle |
| disabled (no PTZ) | `opacity 0.4`, arrows `text.disabled`, centred `Caption1` "This camera does not support PTZ" replacing the thumb |
| loading (command in flight) | Centre dot pulses `accent` α 0.5↔1.0 at 3 Hz; if `optimisticTimeout` elapses, a toast "Camera did not respond" |

Below the pad: zoom/focus/iris as three `VSlider`-less rocker pairs (28 pt `VButton(.icon)` −/+ with a
`Mono` value between), then a 3 × 3 presets grid of 72 × 40 thumbnails (radius `radius.lg` 10,
`#000000` well, `Caption1` name overlay on `scrim.base`, `star.fill` when assigned; long-press or
right-click → "Set to current position").

### 9.16 `VCommandPalette`

640 pt wide, max 520 pt tall, top inset 132 pt from the window's top, centred horizontally.
E3 glass, radius `radius.xxl` 20, scrim `black α 0.44`. Entrance per §7.4 #15.

| Band | Spec |
|---|---|
| Input | 52 pt tall, `Title3` 15 pt text, no border, leading 20 pt `magnifyingglass` 15 pt `text.tertiary`, placeholder "Search cameras and actions", trailing `VKeyCap("esc")`. Hairline `stroke.default` divider below, full-bleed. |
| Results | Rows 40 pt (with a 28 × 16 thumbnail for cameras) or 32 pt (actions). Row layout: `[icon 15pt][10][title Headline][6][subtitle Caption1 text.tertiary][flex][badge][8][shortcut VKeyCaps][16]`. Selected row: fill `accent α 0.18`, 1 pt `accent α 0.30` stroke, radius `radius.md` 8, inset 8 pt, moved via `matchedGeometryEffect` + `snap`. Hover = fill `white α 0.06` (and hover **does not** move keyboard selection). |
| Section headers | 24 pt, `Caption2` uppercase `text.tertiary`, 20 pt leading inset. Sections in fixed order: Cameras, Layouts, Actions, Playback, Settings. |
| Footer | 32 pt, hairline divider above, `Caption1` `text.tertiary` hints: `↑↓ navigate` `↵ open` `⌘↵ open in new window`, trailing a result count. |
| Empty | 120 pt, centred 22 pt `magnifyingglass` `text.disabled`, `Body` "No matches for "xyz"", `Caption1` "Try a camera name, a layout, or "record"". |
| Loading | Only when a search hits the network (ISAPI event search): the footer shows a 11 pt spin ring + "Searching device…"; existing local results stay visible. |

Focus is trapped inside the palette; `Esc` closes; clicking the scrim closes; `⌘K` toggles. The list
is `List`-free (a `LazyVStack` in a `ScrollViewReader`) so selection scrolling is exact:
`.scrollTo(id, anchor: .init(x: 0, y: 0.35))`.

### 9.17 `VToast`

320 pt wide, min 44 pt tall, radius `radius.xl` 14, E2 glass, bottom-trailing stack with 20 pt window
inset and 8 pt between toasts, max 3 visible (older ones collapse into a "+2 more" row).
Layout: `[16][icon 15pt][10][VStack: title Headline, message Caption1 text.secondary][flex][action VButton(.ghost,.sm)][8][xmark 11pt][12]`.

| Variant | Icon | Icon colour | Leading edge |
|---|---|---|---|
| `.info` | `info.circle.fill` | `accent` | 3 pt `accent` bar, radius 1.5, full height inset 8 pt |
| `.success` | `checkmark.circle.fill` | `ok` | 3 pt `ok` |
| `.warning` | `exclamationmark.triangle.fill` | `warn` | 3 pt `warn` |
| `.error` | `xmark.octagon.fill` | `danger` | 3 pt `danger` |
| `.motion` | `figure.walk` | `motion` | 3 pt `motion`; includes a 64 × 36 event thumbnail leading, and clicking it jumps to playback |

Dwell: 4 s (`.info`/`.success`), 6 s with an action, **indefinite** for `.error` (must be dismissed).
Hovering pauses the dismiss timer and reveals the `xmark`. Entrance/exit per §7.4 #18–19. Stack
re-flows with `standard`. Toasts are `accessibilityAddTraits(.isStaticText)` and posted to VoiceOver
with `NSAccessibility.post(element:notification:.announcementRequested)` at
`.high` priority for errors, `.medium` otherwise.

### 9.18 `VEmptyState`

Centred, max width 380 pt. Layout: 48 pt `icon.hero` (32 pt glyph in a 48 pt circle of `white α 0.05`
with a 1 pt `stroke.default`) → 20 pt → `Title2` title → 8 pt → `Body` `text.secondary` message
(2 lines max) → 24 pt → `VButton(.primary, .xl)` → 12 pt → optional `VButton(.ghost, .md)` secondary.
Entrance per §7.4 #44.

Instances: no cameras (`vigil.aperture` hero, "No cameras yet", "Vigil can find Hikvision cameras on
your network automatically.", "Scan network" / "Add manually"); no events; no recordings on this day;
empty group; no search results; second display not connected.

### 9.19 `VSkeleton`

§7.6. Sizes are always the **real** content's box, never a generic bar: a name skeleton is 90 × 11, a
subtitle 60 × 9, a thumbnail 40 × 22, a card body three bars of 100 %/92 %/64 % width × 11 pt with
6 pt gaps. Radius: 3 pt for text bars, the component's own radius for boxes.

### 9.20 `VStatPill`

Used throughout the inspector and the tile HUD. Height 24 pt (`sm`), radius `radius.sm` 6, fill
`surfaceRaised` (E1, no shadow), stroke `stroke.default`, padding 6/8.
Layout: `[icon 12pt text.tertiary][6][value Mono 11 text.primary][2][unit Caption1 text.tertiary]`.
Value has a reserved width (§4.4) and `.contentTransition(.numericText())` when it changes at ≤ 2 Hz.

Threshold tinting: the pill's **stroke and icon** (never its fill) take `ok`/`warn`/`danger` based on
`VHealthThresholds`:

| Metric | ok | warn | danger |
|---|---|---|---|
| Loss | < 0.5 % | 0.5–2 % | > 2 % |
| Jitter | < 20 ms | 20–60 ms | > 60 ms |
| Latency | < 250 ms | 250–600 ms | > 600 ms |
| fps deviation from expected | < 10 % | 10–25 % | > 25 % |
| Decode queue | ≤ 2 | 3–5 | > 5 |

States: rest / hover (stroke `stroke.strong`, tooltip with the metric's definition and 60 s history) /
focused (2 pt ring; `↵` opens the metric's graph) / loading (`VSkeleton` 40 × 11 in place of the
value). Not pressable unless it has a graph.

### 9.21 `VSparkline`

Default 60 × 16 pt (inspector 240 × 44). Path: 1.25 pt stroke, round caps and joins, colour per
metric (`accent` for bitrate, `ok` for fps, `warn` for loss, `motion` for motion energy). Fill: a
`LinearGradient` from `colour α 0.22` to `colour α 0.0` top → bottom, only in the 240 pt variant.
Baseline: 1 pt `white α 0.08`. Latest point: 3 pt filled circle in the metric colour with a 1 pt
`layer.surface` ring. Window: 60 samples at 1 Hz. Y range: `[0, max(observedMax × 1.15, floor)]`,
recomputed with a 5 s decay so the line does not jump on a single spike. Drawn in `Canvas` with
`.drawingGroup()`; path updates animate per §7.4 #32 (`.linear(0.20)`).

Threshold shading (loss/jitter only): a `warn α 0.10` band above the warn threshold and a
`danger α 0.12` band above the danger threshold, drawn behind the path.
States: rest / hover (a 1 pt `white α 0.24` cursor line + a `MonoSmall` value pill; the point under the
cursor grows to 4 pt) / loading (`VSkeleton` at the sparkline's box) / empty (a flat baseline plus
`Caption1` "No data yet", no path).

### 9.22 `VContextMenu`

A styled `.contextMenu`. Because AppKit owns menu rendering, our control is limited to structure, so
the rules are structural: max 9 items before a submenu; items grouped by
**act on this / configure this / destructive**, separated by dividers; every item carries its symbol
and its `keyboardShortcut` so the menu doubles as shortcut discovery; destructive items last, with
`.destructive` role (AppKit tints them red); no item without an icon; labels are verbs
("Start Recording", not "Recording").

Right-clicking a tile opens: *Open Fullscreen · Open in New Window · Picture in Picture* | *Snapshot ·
Start Recording · Mute* | *Mainstream/Substream · Aspect Fit/Fill · Show Stats* | *PTZ Presets ▸ ·
Image Settings…* | *Camera Info… · Stream Doctor…* | *Remove from Layout*.

For the cases where a native menu is not enough (the layout picker with live miniatures, the preset
grid), we use a `VPopover` instead — never a fake menu drawn in SwiftUI over a native one.

### 9.23 `VPopover`

E2 glass, radius `radius.xl` 14, padding `space.md` 12, max width 320 pt (420 for the Stream Doctor),
arrow: **none** (macOS 14 `.popover` draws a system arrow; we use
`.presentationCompactAdaptation(.popover)` and a 6 pt offset instead, because our glass edge plus a
system arrow double-draws the border). Attachment: 6 pt gap from the source, edge-aligned to the
source's leading unless it would clip. Header (optional): `Title3` + `xmark` 11 pt.

States: presented/dismissed only (entrance §7.4 #29). Focus moves into the popover and returns to the
source on dismiss. `Esc` dismisses. Click-outside dismisses. A popover never contains another popover;
it may contain a `Menu`.

### 9.24 `VSheet`

Modal, E3. Width by content class: `.compact` 420, `.regular` 560, `.wide` 720 pt. Max height
`min(content, windowHeight − 120)`. Radius `radius.xxl` 20. Structure: 52 pt header
(`Title1` leading, `xmark` trailing, hairline divider) → scrollable content with `space.xl` 20 margins
→ 64 pt footer (hairline divider above, `VButton(.ghost)` "Cancel" then `VButton(.primary)` trailing,
12 pt gap, 20 pt margins). Scrim per §6.2. Entrance §7.4 #30.

`⌘.`/`Esc` cancels; `⌘↵` triggers the primary action. If the content scrolls, the header gains a
hairline divider only once scrolled (`scrollGeometry`-driven, cross-faded 120 ms). Sheets never nest;
a sheet that needs a second step animates its content horizontally (`standard`, `offset(x:)` ±24 with
opacity) inside the same sheet frame, and the frame height animates with `standard`.

### 9.25 `VInspectorSection`

A collapsible group. Header: 28 pt row, `chevron.right` 11 pt `text.tertiary` rotating 90° on expand
(`snap`), `Caption2` uppercase `text.secondary` title, trailing accessory (a `VBadge` or a 20 pt
`VButton(.icon, .xs)`). Body: `space.md` 12 vertical padding, rows of 24 pt.
Row layout: `[label Callout text.secondary, width 96pt, trailing-aligned][12][value/control, flex]`.
Divider between sections: hairline `stroke.subtle`, full-bleed, 12 pt above/below.

Expansion animates the body's height with `standard` **and** its `opacity` with `fadeIn`, using
`.clipped()` on the container so the content does not spill. Collapsed state persists per section in
`@AppStorage("inspector.section.\(id).expanded")`.

States: rest / hover (title → `text.primary`) / pressed (fill `white α 0.05` on the header only) /
focused (2 pt ring on the header; `↵`/`Space` toggles) / disabled (title `text.disabled`, body hidden,
a trailing `Caption1` reason, e.g. "Camera offline") / loading (body rows show `VSkeleton` values).

### 9.26 `VKeyCap`

Min 18 × 18 pt (grows with content), radius `radius.xs` 4, fill `white α 0.08`, stroke
`stroke.default` 1 pt, **plus a 1 pt bottom inner shadow** `black α 0.30` that gives the key its cap
look. Glyph: `Caption2` 10 pt `.semibold` `text.secondary`, or an 11 pt SF Symbol for modifiers
(`command`, `option`, `shift`, `control`, `arrow.up`, `return`, `escape`, `delete.left`).
H-padding 5 pt for multi-character caps ("esc", "⌘K" rendered as two caps with a 3 pt gap).

States: rest / **pressed** (only in the Shortcuts settings pane while recording a chord:
`offset(y: 1)`, inner shadow removed, fill `accent α 0.20`, stroke `accent`, `snap`) / recording (fill
`accent α 0.16`, stroke `accent` dashed, `Caption2` "Press keys…") / conflict (stroke `danger`, with a
`Caption1` "Already used by Snapshot" beneath). Not focusable outside the Shortcuts pane.

### 9.27 Two more that the inventory implies

**`VDivider`** — `Rectangle().fill(stroke.subtle).frame(height: 1/scale)`, with `.inset(12)` and
`.fullBleed` variants. Never `Divider()`.

**`VProgressRing`** — 13/22/32 pt, `lineWidth` 1.5/2/2.5, `trim` driven either by real progress
(reconnect countdown, export) or by `motion.spin` when indeterminate; track `white α 0.10`, arc
`accent` (or the semantic colour of the operation). In `reduceMotion`, indeterminate rings are
replaced by a static 25 % arc plus a text label.

### 9.28 The focus ring (used by every component)

A single, consistent treatment, drawn by a modifier so no component reimplements it:

```swift
extension View {
    func vFocusRing(_ isFocused: Bool, radius: CGFloat, outset: CGFloat = 3) -> some View {
        self.overlay {
            RoundedRectangle(cornerRadius: radius + outset, style: .continuous)
                .strokeBorder(VTheme.Color.Semantic.focusRing, lineWidth: 2)
                .padding(-outset)
                .shadow(color: VTheme.Color.Semantic.focusRing.opacity(0.30), radius: 3)
                .opacity(isFocused ? 1 : 0)
                .scaleEffect(isFocused ? 1.0 : 1.06)
        }
        .animation(VTheme.Motion.micro, value: isFocused)
    }
}
```

Ring colour `focusRing` `#9581FF` clears 3:1 against every layer (§3.2), including over video
(6.86:1). Outset 3 pt (2 pt on video tiles, where the ring is drawn **inside** so it is never
clipped by the neighbouring tile). ⛔ `.focusEffectDisabled()` is applied to every custom control so
the system ring never double-draws with ours; native controls we do not restyle (the Settings window's
`Form` rows) keep the system ring.

Focus travel uses `matchedGeometryEffect` in the `focus` namespace (§7.7) so the ring visibly moves
between controls in the same container; between containers it fades (60 ms out / 60 ms in).

### 9.29 Component QA matrix

Every component ships previews for: dark rest, dark hover, dark pressed, dark focused, dark disabled,
dark loading, light rest, `reduceMotion`, `increaseContrast`, `reduceTransparency`,
`differentiateWithoutColor`, `textScale = 1.15`, and (for text-bearing components) a Russian string
that is ~1.4× the English length.

---

## 10. Accessibility

Vigil targets **WCAG 2.1 AA for all functional UI** and AAA for primary text, plus full macOS
assistive-technology support. This is not a compliance appendix — the tokens in §3 were *chosen* to
make these numbers fall out automatically.

### 10.1 Contrast — the measured numbers

All values computed from the sRGB hex tokens using the WCAG relative-luminance formula.

| Requirement | Threshold | Vigil's worst case | Where |
|---|---|---|---|
| Body text | 4.5:1 | **13.23:1** | `text.primary` on E5 overlay glass (the darkest text context) |
| Secondary text | 4.5:1 | **6.54:1** | `text.secondary` on overlay |
| Tertiary text | 4.5:1 | **4.52:1** | `text.tertiary` on overlay — the tightest text pair in the app, deliberately still ≥ AA |
| Text over video | 4.5:1 | **5.20:1** | `text.primary` on `scrim.base` over an all-white frame |
| Button label on fill | 4.5:1 | **4.97:1** | white on `liveFill` |
| Graphic / UI component | 3:1 | **3.46:1** | `accent` glyph on overlay glass |
| Focus indicator | 3:1 | **4.76:1** | `focusRing` on overlay glass |
| Status colour on video | 3:1 | **5.63:1** | `live` dot on `#000000` |
| Light appearance, all text | 4.5:1 | **4.90:1** | `text.tertiary` `#626B79` on `#F3F4F7` |
| Light appearance, semantics | 4.5:1 | **4.96:1** | `ok` `#157A2B` on canvas |

The only deliberate exception is `text.disabled` (2.61:1). WCAG exempts disabled controls; Vigil
nonetheless never relies on it alone — a disabled control always also loses its stroke, and any
disabled *action* carries a `Caption1` reason string (e.g. "Camera offline", "No PTZ support").

### 10.2 Full keyboard operability

The app is fully operable with no pointer. Requirements on every component:

1. `.focusable()` with an explicit `@FocusState`-backed focus value; `.focusEffectDisabled()` plus our
   own ring (§9.28).
2. `Tab`/`⇧Tab` walk containers in visual order; `⌃Tab` moves between the three main regions (sidebar
   → stage → inspector); arrows move *within* a container (sidebar rows, grid tiles, palette results,
   preset grid, timeline).
3. `Space` activates the focused control; `↵` performs the primary action of the focused object (open a
   camera fullscreen, run a palette row); `Esc` unwinds exactly one level (clear search → blur field →
   close popover → exit fullscreen → exit cinema).
4. Every action is in the menu bar with its shortcut, and every action is in `⌘K`. There is no action
   reachable only by hover, drag or right-click. Drag-to-reorder has "Move Up"/"Move Down"
   (`⌥⌘↑/↓`); drag-to-assign has "Assign to Cell ▸".
5. Grid navigation: `⌥`+arrows move tile focus spatially (not by index) using the tile centres, so a
   1+5 mosaic behaves as it looks.
6. `⌘K` traps focus; sheets and popovers trap focus and restore it on dismiss.
7. Focus is never lost: when a focused camera goes offline or a focused row is deleted, focus moves to
   the nearest sibling, and VoiceOver announces the move.
8. Full Keyboard Access (`⌃F1`) "increase contrast on focus" is honoured automatically because our
   ring is 2 pt at ≥ 4.76:1; when `NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast` is
   on, the ring goes to 3 pt.

### 10.3 VoiceOver

**Video tiles.** A tile is one accessibility element (the video content is not describable, so we
describe its *state*), with custom actions replacing the hover toolbar:

```swift
tile
  .accessibilityElement(children: .ignore)
  .accessibilityLabel(Text(camera.name))
  .accessibilityValue(Text(stateSentence))
  .accessibilityHint(Text("Press Return to view fullscreen."))
  .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  .accessibilityCustomContent("Codec",      "\(codec) \(width) by \(height)")
  .accessibilityCustomContent("Frame rate", "\(fps) frames per second")
  .accessibilityCustomContent("Bit rate",   "\(mbps) megabits per second", importance: .default)
  .accessibilityCustomContent("Latency",    "\(latencyMS) milliseconds")
  .accessibilityCustomContent("Packet loss","\(lossPercent) percent")
  .accessibilityCustomContent("Decoder",    hardwareDecode ? "Hardware" : "Software")
  .accessibilityAction(named: "Take Snapshot")      { … }
  .accessibilityAction(named: "Start Recording")    { … }   // label flips to "Stop Recording"
  .accessibilityAction(named: "Mute Audio")         { … }
  .accessibilityAction(named: "Open Fullscreen")    { … }
  .accessibilityAction(named: "Show Pan Tilt Zoom") { … }
  .accessibilityAction(named: "Remove From Layout") { … }
```

`stateSentence` is composed, never concatenated ad-hoc, by `VAccessibilityCopy`:

| State | Spoken value |
|---|---|
| connecting | "Connecting, authenticating" (the live narration stage, in words) |
| live | "Live, 1080p, 25 frames per second, hardware decode" |
| live + recording | "Live and recording, 4 minutes 12 seconds" |
| degraded | "Live but degraded, 2.4 percent packet loss" |
| offline | "No signal, retrying in 4 seconds" |
| auth failure | "Sign-in failed, credentials need updating" |
| empty cell | "Empty cell, position 3 of 16. Drop a camera here or press Return to choose one." |

Telemetry is in `accessibilityCustomContent` (rotor-accessible with `⌃⌥⇧↓`) rather than in the label,
so a screen-reader user hears "Front Door, live, 1080p…" and can drill into the numbers on demand
instead of hearing a paragraph. Values that change faster than 1 Hz are **not** announced live; the
stats HUD is `accessibilityHidden(true)` and its content is exposed through custom content instead.
State *transitions* are announced once, debounced 1 s, at `.medium` priority ("Front Door is live",
"Front Door lost signal").

**PTZ pad.** The pad is an adjustable element plus named actions:

```swift
ptzPad
  .accessibilityElement(children: .ignore)
  .accessibilityLabel("Pan and tilt control")
  .accessibilityValue("Centred")   // or "Panning right at speed 4 of 10"
  .accessibilityAdjustableAction { direction in     // VO up/down arrows change speed
      speed += (direction == .increment ? 1 : -1)
  }
  .accessibilityAction(named: "Pan Left")  { move(.left) }     // + Right, Up, Down
  .accessibilityAction(named: "Pan Up Left") { move(.upLeft) } // + 3 more diagonals
  .accessibilityAction(named: "Stop") { stop() }
  .accessibilityAction(named: "Go to Home Position") { home() }
  .accessibilityHint("Use the actions to pan and tilt. Adjust the value to change speed.")
```

Zoom/focus/iris rockers are separate adjustable elements with values in words
("Zoom, 3.2 times"). Presets are buttons labelled "Preset 1, Front Gate" with the hint "Press to
recall. Use Set Preset to overwrite."

**Timeline.** One adjustable element per lane: label "Recording timeline for Front Door", value
"2 14 PM, 7 seconds", `accessibilityAdjustableAction` = ±1 s (±10 s with the VO fast rotor), plus
named actions "Next Event", "Previous Event", "Set In Point", "Set Out Point", "Play From Here". The
heatmap is summarised as custom content: "Recordings: continuous from 8 AM to 2 PM, 14 motion events".

**Sidebar, palette, toasts.** Sidebar rows expose name + state + codec as label/value, group rows use
`.isHeader`. Palette rows are buttons with the shortcut in `accessibilityHint`. Toasts announce via
`announcementRequested` (`.high` for errors). The command palette posts
`NSAccessibility.post(element: field, notification: .focusedUIElementChanged)` on open.

### 10.4 `increaseContrast`

Read `@Environment(\.colorSchemeContrast) == .increased` (backed by
`accessibilityDisplayShouldIncreaseContrast`). Changes, applied centrally in `VTheme`:

| Aspect | Normal | Increased |
|---|---|---|
| `stroke.subtle` / `default` / `strong` | α 0.06 / 0.10 / 0.18 | α 0.14 / **0.28** / 0.40 |
| Every fill that had no border | — | gains a 1 pt `stroke.default` border |
| `text.tertiary` | `#88909D` (6.08:1) | → `text.secondary` `#A7AEBC` (8.78:1) |
| `text.disabled` | `#4E5563` (2.61:1) | `#6E7583` (4.05:1) + always paired with the reason string |
| Focus ring | 2 pt + 3 pt glow | **3 pt**, glow removed (glow reduces edge definition), outset 3 pt |
| Materials | `.hudWindow` etc. | Solid fallbacks (§2.4) — vibrancy is a contrast hazard |
| Shadows | E1–E3 as specified | Removed; replaced by the 1 pt borders above |
| Scrim over video | α 0.62 | α 0.78 |
| Selected sidebar row | `accent α 0.16` + α 0.30 stroke | `accent α 0.28` + 1.5 pt `accent` stroke |
| Video tile gutter | 2 pt canvas | 2 pt canvas **plus** a 1 pt `stroke.strong` tile border, so tile edges are unambiguous |
| Skeleton shimmer | α 0.075 peak | shimmer off, block at `white α 0.10` |

### 10.5 `differentiateWithoutColor`

Read `@Environment(\.accessibilityDifferentiateWithoutColor)`. Every place colour carries meaning gains
a shape or text partner. This is designed so the *non*-differentiated mode already has the partner in
most cases (the badges are all lettered), which keeps the two modes visually close.

| Signal | Colour-only form | Differentiated form |
|---|---|---|
| Status dot: connecting | `warn`-ish spinning ring | Spinning ring (unchanged — motion is the cue) |
| Status dot: live | `ok` filled circle | Filled **circle** + `LIVE` `VBadge` becomes visible in the sidebar row |
| Status dot: degraded | `warn` circle | Filled **triangle** (6 pt, apex up) |
| Status dot: offline | hollow circle, `text.tertiary` | Hollow **square** (5.5 pt) with a 1 pt stroke |
| Status dot: auth failure | `danger` circle | Filled circle with a **1.5 pt white slash** (⌀ glyph) |
| Recording tile border | `live` 3 pt breathing | 3 pt border **plus** the `REC` badge is forced visible even on small tiles |
| Timeline heatmap: continuous | `continuous` blue | Solid blue **plus** no hatch (the baseline) |
| Timeline heatmap: motion | `motion` amber | Amber **plus** 45° hatch, 1 pt lines at 4 pt pitch |
| Timeline heatmap: alarm | `live` red | Red **plus** cross-hatch, 1 pt at 3 pt pitch |
| Camera identity chips | `ident.N` colour | Colour **plus** the camera's initial (already always shown, §3.4) |
| Health thresholds on `VStatPill` | `ok`/`warn`/`danger` stroke | Stroke **plus** a leading 9 pt glyph: none / `exclamationmark.triangle.fill` / `xmark.octagon.fill` |
| Sparkline threshold bands | tinted bands | Bands **plus** a 1 pt dashed threshold line and a `MonoSmall` label |
| Multi-camera playback legend | colour swatches | Swatch **plus** initial **plus** a distinct dash pattern on each lane's playhead |
| Drop target | `accent` dashed fill | Dashed fill **plus** a centred 15 pt `arrow.down.to.line` glyph |
| Selected vs focused tile | `accent` vs `focusRing` | Selected = 2 pt solid; focused = 2 pt **dashed** (dash 6/3) — different geometry, not just tint |

### 10.6 Hit targets and pointer

| Rule | Value |
|---|---|
| Minimum interactive hit area | **24 × 24 pt**, achieved with `.contentShape(.rect)` and negative padding, even when the glyph is 11 pt |
| Tile chrome buttons | 28 × 28 visual, **32 × 32** `contentShape` |
| Slider knob | 14 pt visual, 28 pt grab area; track grab area 20 pt tall |
| Timeline handles | 4 pt visual, **12 pt** grab area; playhead 2 pt visual, 16 pt grab |
| Mosaic dividers | 1 pt visual, **8 pt** grab area, with `.pointerStyle(.frameResize(position:))` |
| Sidebar/inspector resize | 1 pt visual, 6 pt grab, `.pointerStyle(.columnResize)` |
| Row targets | Full row width is clickable (`.contentShape(Rectangle())`) |
| Spacing between distinct targets | ≥ 2 pt; ≥ 4 pt when both are destructive-adjacent |
| Cursor | `.pointerStyle(.link)` never used; `.grabIdle`/`.grabActive` on the PTZ pad and timeline; `.zoomIn` on a zoomable tile with `⌥` held |

### 10.7 Other accessibility settings honoured

| Setting | Handling |
|---|---|
| `accessibilityReduceMotion` | §7.10 — a complete per-animation fallback table |
| `accessibilityReduceTransparency` | §2.4 — solid fallbacks for all four materials |
| `accessibilityInvertColors` | Video wells and thumbnails are marked `.accessibilityIgnoresInvertColors(true)` so inverted footage is never shown; chrome inverts normally |
| `accessibilityPrefersCrossFadeTransitions` | Treated as `reduceMotion` for all geometry transitions |
| Full Keyboard Access | §10.2 item 8 |
| Voice Control | Every control has a distinct, speakable `accessibilityLabel`; no two visible controls in a window share a label (icon buttons get "Snapshot", "Record", not "button") |
| Zoom / Hover Text | No text is rendered into an image; everything is real `Text` so Hover Text can magnify it |
| `NSAccessibility` window role | Video wall window is `.window` with a descriptive title, not an unlabelled panel |

---

## 11. App icon and window chrome

### 11.1 App icon concept

**Concept: a machined aperture over a night-time bokeh field.** It says "optics" and "instrument" in
one shape, and it reuses the brand mark (`vigil.aperture`, §8.5) so the icon, the menu-bar extra and
the empty-state hero are visibly the same object.

Layers, back to front, on the 1024 × 1024 canvas (Apple macOS template: the artwork occupies an
824 × 824 continuous-rounded square, corner radius 185.4 pt at 1024, centred, with 100 pt margins;
the system adds no shadow, so ours is baked):

| # | Layer | Spec |
|---|---|---|
| 1 | Body | 824 × 824 continuous rounded square, radius 185.4. Fill: 165° linear gradient `#1B1E27` → `#0A0B0E`. |
| 2 | Bokeh field | Nine soft circles, ⌀ 40–120, at `white α 0.03–0.06`, Gaussian blur 24–48, clustered lower-left to upper-right; two of them tinted `ident.1` Cyan α 0.05 and `accent` α 0.06. Reads as out-of-focus city light at night. |
| 3 | Inner bevel | 2 pt inset stroke, top-to-35 % gradient `white α 0.14` → clear; plus a 1 pt bottom stroke `black α 0.50`. Gives the body a milled-aluminium edge. |
| 4 | Aperture blades | Six blades, 60° apart, forming a hexagonal opening. Outer blade radius 300, hexagon inscribed radius 102 (34 % of 300). Blade stroke width 26, tip gap 20. Fill: 120° linear gradient `#B8A8FF` → `#6247E8` per blade, each blade rotated so the gradient sweeps radially (a 6 % lightness step between adjacent blades sells the metal). Blade edges get a 1.5 pt `white α 0.35` top-left highlight and a 2 pt `black α 0.45` bottom-right shadow. |
| 5 | Aperture well | The hexagonal opening is filled `#000000` with a 3 pt inner shadow `black α 0.8` — a true-black hole, echoing §3.6. |
| 6 | Catchlight | One 22 pt circle at `live` `#FF2E43`, at the lower-right blade join (polar 315°, r 148), with a 40 pt `#FF2E43 α 0.35` bloom. This is the single warm accent: the "we are recording" tell, and the one element that makes the icon scan as *surveillance* rather than *photography*. |
| 7 | Specular sweep | A 30°-rotated soft band across the upper third, `white α 0.06`, blur 60, clipped to the body. |
| 8 | Contact shadow | Baked below the body: `black α 0.28`, blur 40, y +18, clipped to the 1024 canvas. |

**Small-size variants** are drawn, not scaled — the 16 pt and 32 pt renditions drop layers 2, 7 and 8,
thicken the blade stroke to 34 (16 pt) / 30 (32 pt), grow the hexagon to 40 % of the outer radius, and
grow the catchlight to 30 pt so it survives. At 16 × 16 the icon must read as *a violet hexagonal ring
with a red dot* — that is the legibility test, and any change that fails it is rejected.

Deliverables in `Vigil/Resources/Assets.xcassets/AppIcon.appiconset`: 16, 32, 64, 128, 256, 512, 1024
at 1× and 2× (the full macOS set). Also `MenuBarIcon` (18 × 18 @1×/2×/3×, **template**, blades only,
no colour) and `DocumentIcon` for exported `.vigil-layout` files (the aperture over a small grid).

### 11.2 Window chrome — the main window

```swift
WindowGroup(id: "main") { VMainWindowView() }
    .windowStyle(.hiddenTitleBar)
    .windowToolbarStyle(.unified(showsTitle: false))
    .windowResizability(.contentSize)
    .defaultSize(width: 1280, height: 800)
    .commands { VigilCommands() }
```

| Property | Value |
|---|---|
| Style | `.hiddenTitleBar` + `.unified(showsTitle: false)` — the toolbar merges into the title bar; no title string is drawn (the selected camera/layout name is the toolbar's leading item instead) |
| Toolbar height | 52 pt |
| Min window size | 900 × 600 (below this the inspector auto-hides; below 700 wide the sidebar collapses to the rail) |
| Default size | 1280 × 800; restored via `.windowResizability` + `NSWindow` autosave name `"VigilMain"` |
| Background | `layer.canvas`, set on the window (`backgroundColor`) so live-resize never flashes white |
| `titlebarAppearsTransparent` | `true` |
| Toolbar separator | `NSWindow.toolbarStyle = .unified`; we set `window.titlebarSeparatorStyle = .none` and draw our own hairline `stroke.subtle` only when the stage is scrolled — over video there is no separator at all |
| Traffic lights | Inset to a **26 pt** centre-y and a **20 pt** leading centre-x (default is ~13, 20), so they sit optically centred in the 52 pt unified bar and align with the sidebar's 20 pt content inset |
| Tabbing | `window.tabbingMode = .disallowed` — Vigil's multi-window model is Playback/Wall/Settings, and tabs would hide live video |
| Full-size content | `styleMask.insert(.fullSizeContentView)` so the sidebar material runs to the window's top edge and under the traffic lights |

Traffic-light inset (must be re-applied after fullscreen transitions and on
`windowDidBecomeKey`, because AppKit resets it):

```swift
func applyChrome(to window: NSWindow) {
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.styleMask.insert(.fullSizeContentView)
    window.titlebarSeparatorStyle = .none
    window.backgroundColor = NSColor(VTheme.Color.Layer.canvas)
    window.tabbingMode = .disallowed
    guard let close = window.standardWindowButton(.closeButton),
          let container = close.superview else { return }
    // AppKit lays the three buttons out in `container`; shift the container, not the buttons,
    // so their 20pt spacing is preserved.
    let target = CGPoint(x: 20 - 7, y: container.frame.origin.y - 10)  // +13pt x, -10pt y
    container.setFrameOrigin(target)
    container.superview?.needsLayout = true
}
```

Sidebar content therefore starts at `y = 52 + space.sm 8 = 60` from the window top, and the first
section header's cap-height centre lines up with the traffic lights' centre at 26 pt only in the
collapsed rail; in the expanded sidebar the traffic lights sit above the search field, which begins at
y 60.

Auxiliary windows use `.unifiedCompact(showsTitle: true)` at 38 pt with the standard traffic-light
position — the inset treatment is reserved for the main window, where it reads as intentional.

### 11.3 Toolbar contents (main window)

`[traffic lights] [sidebar toggle] [selected camera or layout name] [search]
… flex … [layout switcher (VSegmentedControl + VLayoutGlyphs)] … flex …
[cycle] [⌘K] [overflow "…"] [inspector toggle]`

Items are `VButton(.icon, .md)`. The switcher sits between **two flexible gaps** rather than in a
centred overlay: that is the one arrangement in which it can never end up underneath the group beside
it when the window narrows.

The overflow menu — Video Wall, PiP, Discovery, Stream Doctor, Settings — is a deliberate item and
not AppKit's automatic collapse.

⚠️ **This section was amended on 2026-08-08 to match `design/mockups/01-main-window.html` and
`VToolbarView`, which had always disagreed with it.** The disagreement was five things, not one:
search was specified trailing and is leading; the layout picker was specified leading and is centred;
cycle was specified beside the picker and is in the trailing group; a progress chip "4 of 16 live"
with snapshot-all and record-all was specified in the toolbar and those three actions live in the
overflow menu instead; and the leading title showing the selected camera's name was not specified at
all. Recorded as I8 in `docs/OPEN-CONFLICTS.md`, ruled in favour of the mockup by the repository
owner. No code changed.

### 11.4 Cinema mode

Entered with `⌘⌃F` (distinct from `⌘F` single-tile fullscreen). Effects:

| Aspect | Cinema mode |
|---|---|
| Window | `toggleFullScreen(nil)`; `NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]` |
| Canvas | `layer.canvas` → `#000000` over 240 ms `crossfade` |
| Stage inset | 8 → 0 pt (`expressive`) |
| Sidebar / inspector / toolbar | `opacity → 0` over 120 ms then removed from the hierarchy (so they cost nothing) |
| Tile chrome | Name chips fade to α 0.0; nothing is drawn over video at rest |
| Cursor | `NSCursor.setHiddenUntilMouseMoves(true)`; re-hidden after each idle period |
| Idle | After `idleChromeHide` 2500 ms of no mouse movement and no key press, the control bar hides |
| Reveal | Any mouse movement > 3 pt, or any key press, reveals the bar with `standard`; the timer restarts |
| Control bar | 56 pt tall, max 720 pt wide, centred, 32 pt from the bottom, radius `radius.xxl` 20, E3 elevation, **Metal-blurred video backdrop** at 24 pt (the one exception in §2.3), containing: layout picker, cycle toggle, snapshot all, record all, audio, a live clock in `MonoLarge`, and an exit button |
| Top-right affordance | On reveal, a 32 pt `rectangle.grid.2x2` button appears 20 pt from the top-trailing corner for switching layouts without the bar |
| Exit | `Esc` or `⌘⌃F` or the exit button; reverses with `expressive` |
| Second display | If a video wall is active on another display, cinema mode applies to the main display only and the wall is untouched |

⛔ In cinema mode there is no window chrome of any kind at rest. The screen is video and black.

---

## 12. The token file — `VTheme`

One file per namespace under `VigilUI/Theme/`, all nested in a single `public enum VTheme` so every
call site reads `VTheme.Color.Text.primary`, `VTheme.Motion.standard`, `VTheme.Space.md`.

### 12.1 Structure

```swift
// VigilUI/Theme/VTheme.swift
import SwiftUI
import AppKit

public enum VTheme {

    // MARK: Colour
    public enum Color {
        public enum Layer   { public static let canvas, sidebar, sidebarFallback,
                                                 surface, surfaceRaised, overlay,
                                                 videoWell, scrim: SwiftUI.Color }
        public enum Text    { public static let primary, secondary, tertiary,
                                                 disabled, inverse: SwiftUI.Color }
        public enum Stroke  { public static let subtle, `default`, strong, contrast: SwiftUI.Color
                              public static let onVideo: SwiftUI.Color }          // white α 0.14
        public enum Semantic {
            public static let accent, accentHover, accentPressed, accentFill, focusRing,
                              live, liveFill, ok, okFill, warn, motion,
                              danger, dangerFill, continuous: SwiftUI.Color
            public static func accentTint(_ a: Double) -> SwiftUI.Color
        }
        public enum Ident   { public static let all: [SwiftUI.Color]               // 6, in order
                              public static func colour(for id: UUID) -> SwiftUI.Color
                              public static func fill(_ c: SwiftUI.Color) -> SwiftUI.Color   // α 0.18
                              public static func stroke(_ c: SwiftUI.Color) -> SwiftUI.Color } // α 0.40
        public enum Scrim   { public static let light, base, strong: SwiftUI.Color } // α .45/.62/.82
    }

    // MARK: Typography  (§4)
    public enum Typography {
        public struct Step { let font: Font; let lineSpacing: CGFloat
                             let tracking: CGFloat; let textCase: Text.Case? }
        public static let display, title1, title2, title3, headline, body,
                          callout, caption1, caption2, mono, monoSmall, monoLarge: Step
        public static var textScale: CGFloat { get }        // 0.92 / 1.0 / 1.15
        public static func numeric(_ s: Step) -> Step       // .monospacedDigit()
        public enum Reserved { public static let fps, bitrate, latency, loss,
                                                 jitter, timecode, resolution: CGFloat }
    }

    // MARK: Geometry  (§5)
    public enum Space  { public static let hair: CGFloat = 2, xxs = 4, xs = 6, sm = 8,
                                          md = 12, lg = 16, xl = 20, xxl = 24,
                                          huge = 32, jumbo = 48 }
    public enum Radius { public static let xs: CGFloat = 4, sm = 6, md = 8, lg = 10,
                                          xl = 14, xxl = 20
                         public static func nested(outer: CGFloat, inset: CGFloat,
                                                   own: CGFloat) -> CGFloat }
    public enum Border { public static let thin: CGFloat = 1, focus = 2,
                                          selected = 2, recording = 3
                         public static func hairline(_ scale: CGFloat) -> CGFloat { 1 / scale } }
    public enum Size   { public static let xs: CGFloat = 20, sm = 24, md = 28, lg = 32, xl = 40
                         public static let sidebarWidth: CGFloat = 248, sidebarRail = 52,
                                           inspectorWidth = 300, toolbarHeight = 52,
                                           tileGutter = 2, stageInset = 8,
                                           rowHeight = 44, minHitTarget = 24 }
    public enum Icon   { public static let xs: CGFloat = 11, sm = 12, md = 13,
                                          lg = 15, xl = 17, hero = 32, brand = 18 }

    // MARK: Elevation  (§6)
    public enum Elevation {
        public struct Level { let fill: ShapeStyle?; let stroke: SwiftUI.Color
                              let strokeWidth: CGFloat; let highlight: Double
                              let highlightFade: Double; let shadows: [Shadow] }
        public struct Shadow { let colour: SwiftUI.Color; let radius, x, y: CGFloat }
        public static let e0, e1, e2, e3: Level
    }

    // MARK: Motion  (§7)
    public enum Motion {
        public static let micro      = Animation.spring(response: 0.22, dampingFraction: 0.86, blendDuration: 0)
        public static let standard   = Animation.spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0)
        public static let expressive = Animation.spring(response: 0.50, dampingFraction: 0.70, blendDuration: 0)
        public static let snap       = Animation.spring(response: 0.16, dampingFraction: 1.00, blendDuration: 0)
        public static let glide      = Animation.spring(response: 0.42, dampingFraction: 0.95, blendDuration: 0.10)
        public static let rubber     = Animation.spring(response: 0.30, dampingFraction: 0.62, blendDuration: 0)
        public static let fadeIn     = Animation.timingCurve(0.00, 0.00, 0.20, 1.00, duration: 0.18)
        public static let fadeOut    = Animation.timingCurve(0.40, 0.00, 1.00, 1.00, duration: 0.12)
        public static let crossfade  = Animation.easeInOut(duration: 0.24)
        public static let emphasized = Animation.timingCurve(0.32, 0.72, 0.00, 1.00, duration: 0.28)
        public static let breathe    = Animation.easeInOut(duration: 1.0).repeatForever(autoreverses: true)
        public static let shimmer    = Animation.linear(duration: 1.15).repeatForever(autoreverses: false)
        public static let spin       = Animation.linear(duration: 0.90).repeatForever(autoreverses: false)

        public enum Delay { public static let hoverOut = 0.26, stagger = 0.018,
                                             tooltip = 0.50, pressMin = 0.08,
                                             optimisticTimeout = 1.20,
                                             idleChromeHide = 2.50, skeletonMin = 0.22
                            public static let staggerCap = 12 }

        public static func resolved(_ a: Animation, reduced: Bool,
                                    fallback: Animation? = .easeInOut(duration: 0.12)) -> Animation?
        public static func stagger(_ index: Int) -> Double        // min(index, 12) * 0.018
    }

    // MARK: Health thresholds (§9.20) — shared with VigilCore's health model
    public enum Health { public static func level(loss: Double) -> VLevel
                         public static func level(jitterMS: Double) -> VLevel
                         public static func level(latencyMS: Double) -> VLevel }
}
```

### 12.2 Dynamic colours — the only correct way on macOS

`SwiftUI.Color` has no light/dark initialiser. Bridging through `NSColor`'s dynamic provider is what
makes appearance switching (and `increaseContrast`) work everywhere, including inside AppKit views:

```swift
public extension SwiftUI.Color {
    /// Appearance- and contrast-aware token.
    /// - Parameters are 0xRRGGBB. `lightHC`/`darkHC` default to the normal values.
    init(light: UInt32, dark: UInt32,
         lightHC: UInt32? = nil, darkHC: UInt32? = nil, alpha: CGFloat = 1) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua,
                                                     .accessibilityHighContrastAqua,
                                                     .accessibilityHighContrastDarkAqua])
                          .map { $0 == .darkAqua || $0 == .accessibilityHighContrastDarkAqua }
                          ?? true
            let isHC = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            let hex: UInt32 = isDark ? (isHC ? (darkHC ?? dark) : dark)
                                     : (isHC ? (lightHC ?? light) : light)
            return NSColor(srgbHex: hex, alpha: alpha)
        })
    }
}

extension NSColor {
    convenience init(srgbHex hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green:   CGFloat((hex >>  8) & 0xFF) / 255,
                  blue:    CGFloat( hex        & 0xFF) / 255,
                  alpha:   alpha)
    }
}

// Token definitions read exactly like the tables in §3:
extension VTheme.Color.Layer {
    public static let canvas        = SwiftUI.Color(light: 0xF3F4F7, dark: 0x0B0C0F)
    public static let surface       = SwiftUI.Color(light: 0xFFFFFF, dark: 0x16181D)
    public static let surfaceRaised = SwiftUI.Color(light: 0xFFFFFF, dark: 0x1D2026)
    public static let overlay       = SwiftUI.Color(light: 0xFFFFFF, dark: 0x252932)
    public static let videoWell     = SwiftUI.Color(light: 0x000000, dark: 0x000000)
}
extension VTheme.Color.Semantic {
    public static let accent     = SwiftUI.Color(light: 0x5B44E0, dark: 0x7B61FF)
    public static let accentFill = SwiftUI.Color(light: 0x5B44E0, dark: 0x6247E8)
    public static let focusRing  = SwiftUI.Color(light: 0x5B44E0, dark: 0x9581FF)
    public static let live       = SwiftUI.Color(light: 0xC40E20, dark: 0xFF2E43)
    // …one line per row of §3.2
}
```

⛔ `Color(.sRGB, red:green:blue:)` literals appear only in this file and only inside the `init(light:dark:)`
bridge; no view ever constructs a colour.

### 12.3 Environment keys `VigilUI` publishes

| Key | Type | Set by | Read by |
|---|---|---|---|
| `\.vPulsePhase` | `Bool` | Window root `TimelineView(.periodic(by: 1.0))` | Every `VLiveDot`, recording border, menu-bar badge |
| `\.vShimmerOffset` | `CGFloat` | Window root (single driver) | Every `VSkeleton` |
| `\.vMotionEnabled` | `Bool` | `reduceMotion` ∨ governor tier ≥ T3 | Every animated component |
| `\.vMotionTier` | `VMotionTier` | `VMotionGovernor` | Components with tier-specific degradations |
| `\.vTextScale` | `CGFloat` | Settings | `VTheme.Typography` |
| `\.vNamespaces` | `VNamespaces` | `VMainWindowView` | `matchedGeometryEffect` call sites |
| `\.vOnVideo` | `Bool` | `VTile` | Chrome components, to switch to scrim + `stroke.onVideo` |

`\.vOnVideo` is what lets one `VButton(.icon)` implementation serve both the toolbar and the tile
without a separate variant: the button reads the flag and swaps its rest fill from `clear` to
`scrim.base`.

### 12.4 Lint rules (enforced in review, and by a `swift-syntax`-free grep script in CI)

| Forbidden pattern | Replacement |
|---|---|
| `Color(red:` / `Color(hex:` outside `VTheme` | A token |
| `.font(.system(size:` outside `VTheme.Typography` | A type step |
| `.padding(7)` — any non-grid literal | A `VTheme.Space` step |
| `cornerRadius:` without `style: .continuous` | Add the style |
| `.animation(` with an inline `Animation` literal | A `VTheme.Motion` token |
| `Divider()` | `VDivider` |
| `.shadow(` outside `VTheme.Elevation` appliers | An elevation level |
| `ProgressView()` | `VProgressRing` |
| `.multicolor` symbol rendering outside Settings/About | `.monochrome`/`.hierarchical`/`.palette` |
| `NSVisualEffectView` inside a view that also hosts a video layer | Scrim (§2.3) |
| `withAnimation` in a file that imports `AVFoundation` | Route through `VTileTransitionProxy` |

---

## 13. Build order and definition of done

**Implementation order for `VigilUI`** (each step is independently reviewable):

1. `VTheme` (§12) with the dynamic-colour bridge, plus a "Token Gallery" debug window that renders
   every token, every type step, every elevation and every motion token side by side in dark, light,
   `increaseContrast` and `reduceTransparency`. Build this **first**; it is how the rest is reviewed.
2. Primitives: `VVisualEffect`, `VGlass`, `VInnerHighlight`, `VDivider`, `vFocusRing`, `VSkeleton`,
   `VProgressRing`, `VKeyCap`.
3. Controls: `VButton`, `VToggle`, `VSegmentedControl`, `VSlider`, `VTextField`, `VSearchField`,
   `VSelect`, `VBadge`, `VChip`, `VStatPill`.
4. Containers: `VCard`, `VInspectorSection`, `VPopover`, `VSheet`, `VToast`, `VEmptyState`, `VToolbar`.
5. Domain components: `VSidebarRow`, `VTile` (+ `VTileTransitionProxy`), `VSparkline`, `VTimeline`,
   `VPTZPad`, `VCommandPalette`, `VLayoutGlyph`.
6. `VMotionGovernor` and the environment drivers (§12.3).

**Definition of done for any UI change:**

- [ ] No literal colours, fonts, radii, spacings, shadows or animations (§12.4).
- [ ] All six states previewed, in dark and light (§9.29).
- [ ] `reduceMotion`, `reduceTransparency`, `increaseContrast`, `differentiateWithoutColor` previewed.
- [ ] Every interactive element reachable and operable by keyboard, with a visible focus ring.
- [ ] VoiceOver: label + value + hint on every element; custom actions for every hover-only affordance.
- [ ] Every changing number is `monospacedDigit` with a reserved width.
- [ ] Hit targets ≥ 24 × 24 pt.
- [ ] With 16 streams live: UI frame time p99 ≤ 8 ms at 120 Hz, no stream below 60 fps, verified in
      Instruments (Animation Hitches + Time Profiler) before and after the change.
- [ ] No `AVSampleBufferDisplayLayer` bounds mutation outside a `VTileTransitionProxy` transition.
- [ ] Russian strings at ~1.4× English length do not clip or reflow the layout.

---

*End of DESIGN.md. Numbers in this document are load-bearing: the colour tokens were selected against
computed WCAG contrast ratios and CIELAB colour-blind simulations, and the motion values against a
120 Hz frame budget. Change them here, with the new measurement, or not at all.*
