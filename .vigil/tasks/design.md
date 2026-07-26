# ASSIGNMENT: design

AGENT_LABEL for your log lines is: spec:design
Write the file: /home/user/camera/docs/DESIGN.md

Author the **design system** for Vigil. This is the most important document for how the app
feels - the top requirement from the customer is a stunning, modern, top-tier Mac design with
rich animation. Act as a world-class product designer and be extremely specific.
Cover:
- **Design thesis** in five sentences: what Vigil looks and feels like (a calm, dark,
  cinema-grade surveillance cockpit where the video is the hero and the chrome dissolves away),
  and the six principles that follow from it.
- **Colour**: a complete token set in both dark (primary) and light appearance. Give exact sRGB
  hex values AND the SwiftUI Color initialiser expression for each. Layers: canvas, sidebar
  (vibrancy), surface, surface-raised, overlay; strokes subtle / default / strong; text primary /
  secondary / tertiary / inverse. Semantic: accent (choose a distinctive non-default accent and
  argue for it), accent-pressed, live (recording red), ok, warn, danger, motion (event
  highlight). Plus a six-colour categorical palette for camera identity chips that is
  colour-blind safe. Specify when to use NSVisualEffectView materials (sidebar, headerView,
  hudWindow, underWindowBackground) versus solid fills, and the rule that video tiles are always
  true black.
- **Typography**: SF Pro Text / SF Pro Display / SF Mono usage; a nine-step scale with size,
  weight, line height and tracking for each step (Display, Title1-3, Headline, Body, Callout,
  Caption1-2, Mono); the rule that every changing number uses monospacedDigit; and the exact
  SwiftUI Font expressions.
- **Space and shape**: a 4pt base grid with named steps, a radius scale (4/6/8/10/14/20/full) and
  the rule for nesting radii, border widths, and the standard control heights (20/24/28/32/40).
- **Elevation and materials**: four elevation levels each defined as a quadruple of fill, stroke,
  inner highlight and shadow, with exact shadow specs; and the "glass" recipe (material plus a
  1px top inner highlight at 8% white plus a hairline stroke) used for floating toolbars and the
  command palette.
- **Motion** - this is critical. Define a motion vocabulary with exact SwiftUI values, for example
  micro = spring(response 0.22, dampingFraction 0.86), standard = spring(0.34, 0.82),
  expressive = spring(0.5, 0.7), plus entrance and exit curves and easing for non-spring cases.
  Then specify per interaction exactly what animates: sidebar reveal; grid layout change using
  matchedGeometryEffect between a grid cell and fullscreen; tile appearance (scale 0.96 to 1 plus
  opacity with an 18 ms stagger); connection state (skeleton shimmer into a first-frame crossfade);
  the live-dot pulse (2 s ease-in-out breathing); PTZ press feedback; command-palette open
  (scale 0.97 to 1 with material blur-in over 180 ms); toast slide-in; timeline scrub magnetism;
  hover elevation lift; focus-ring animation; and the loading choreography for a 16-tile grid.
  Include PhaseAnimator, KeyframeAnimator and transaction usage notes, reduceMotion fallbacks for
  EVERY animation, and the hard rule that we never animate anything that would drop the video
  below 60 fps - overlays animate on the compositor, never by re-laying-out video layers.
- **Iconography**: a table of every action in the app mapped to an SF Symbol name plus variant and
  weight, rules for symbol rendering modes, and the two custom symbols we need.
- **Component inventory** with visual specs and all states (rest, hover, pressed, focused,
  disabled, loading) for: VButton (primary, secondary, ghost, destructive, icon),
  VSegmentedControl, VToggle, VSlider, VTextField with inline validation, VSearchField, VSelect,
  VBadge, VChip, VCard, VToolbar (floating glass), VSidebarRow (with live thumbnail and status
  dot), VTile (the video cell: chrome on hover, corner radius, focus ring, name chip, stats HUD),
  VTimeline (recording scrubber with heatmap), VPTZPad (joystick), VCommandPalette, VToast,
  VEmptyState, VSkeleton, VStatPill, VSparkline, VContextMenu, VPopover, VSheet,
  VInspectorSection, VKeyCap.
- **Accessibility**: the contrast ratios met (state the numbers), full keyboard operability,
  VoiceOver labels for video tiles and PTZ, increaseContrast and differentiateWithoutColor
  handling, and minimum hit-target sizes.
- **App icon and window chrome**: describe the icon concept concretely, the title-bar treatment
  (hiddenTitleBar window style, unified toolbar, traffic-light inset), and the fullscreen
  "cinema mode" chrome.
Deliver a spec an implementer can build pixel-accurately, and sketch the structure of the SwiftUI
token file (an enum VTheme with nested namespaces).

Create parent directories if needed. Be exhaustive and concrete.
