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
<!-- PART2 -->
