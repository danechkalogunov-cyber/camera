//
//  VTheme+Elevation.swift
//  VigilUI
//
//  The four elevation levels as (fill, stroke, inner highlight, shadow), the glass recipe and the
//  NSVisualEffectView wrapper, expressed as view modifiers that refuse a material over video.
//  macOS-only. See docs/DESIGN.md §2.3, §2.4, §6 and docs/API_CONTRACT.md §4.11.
//

#if os(macOS)

import AppKit
import SwiftUI

// MARK: - Shadow

extension VTheme.Elevation {

    /// One `.shadow(color:radius:x:y:)` application.
    ///
    /// SwiftUI's shadow radius is roughly **half** a CSS or Figma Gaussian blur; the values here
    /// are SwiftUI's (§6.1).
    @MainActor
    public struct Shadow {

        /// The shadow colour, already carrying its alpha.
        public let color: SwiftUI.Color

        /// SwiftUI blur radius.
        public let radius: CGFloat

        /// Horizontal offset. Always 0 in this system.
        public let x: CGFloat

        /// Vertical offset.
        public let y: CGFloat

        init(alpha: CGFloat, radius: CGFloat, y: CGFloat) {
            self.color = SwiftUI.Color(light: 0x000000, dark: 0x000000, alpha: alpha)
            self.radius = radius
            self.x = 0
            self.y = y
        }
    }
}

// MARK: - Level

extension VTheme.Elevation {

    /// One of the four elevation levels: a **quadruple** of fill, stroke, inner highlight and
    /// shadow (§6.1).
    ///
    /// ⛔ Never mix and match. An element is at E0, E1, E2 or E3 and takes all four properties of
    /// that level. Apply it with ``SwiftUI/View/vElevation(_:radius:over:)``, which is the only
    /// place the four are combined.
    @MainActor
    public struct Level {

        // MARK: - Stored Properties

        /// The solid fill, or `nil` when the level is glass (E2 and E3).
        public let fill: SwiftUI.Color?

        /// The 1 pt border.
        public let stroke: SwiftUI.Color

        /// Border width.
        public let strokeWidth: CGFloat

        /// Alpha of the 1 pt top inner highlight; 0 for none.
        public let highlight: Double

        /// The fraction of the height at which the highlight has faded to clear.
        public let highlightFade: Double

        /// Alpha of the 1 pt top inner **shadow** — E0's inverted highlight, which is what makes a
        /// text field read as recessed rather than raised. 0 for every other level.
        public let innerShadow: Double

        /// The level's own radius. A component may override it with its own token.
        public let radius: CGFloat

        /// Whether the level's background is the `.hudWindow` glass recipe rather than a fill.
        public let usesGlass: Bool

        /// `NSVisualEffectView.isEmphasized`, true for E3 only.
        public let emphasized: Bool

        /// Dark-appearance shadows, tight first and ambient second.
        let darkShadows: [Shadow]

        /// Light-appearance shadows. macOS light shadows are subtle; these are softer and cooler.
        let lightShadows: [Shadow]

        // MARK: - Public API

        /// The shadow stack for an appearance, tight first.
        ///
        /// ⛔ Two shadows means two stacked `.shadow()` modifiers in this order. One large shadow
        /// is not an approximation of them — the double shadow is what makes E2/E3 read as glass
        /// rather than as a drop-shadowed rectangle (§6.1).
        public func shadows(_ scheme: ColorScheme) -> [Shadow] {
            scheme == .dark ? darkShadows : lightShadows
        }

        /// The shadow at `index`, or `nil` when the level has fewer.
        ///
        /// Exists so a modifier can apply a fixed two-shadow chain without an `AnyView` or a
        /// `ForEach`: an absent shadow becomes a clear, zero-radius no-op.
        public func shadow(_ index: Int, _ scheme: ColorScheme) -> Shadow? {
            let list = shadows(scheme)
            return index >= 0 && index < list.count ? list[index] : nil
        }
    }
}

// MARK: - The four levels

extension VTheme.Elevation {

    /// **E0 — Inset.** Recessed into its parent: text fields, sliders, wells, code blocks, the
    /// timeline track, the sparkline background. No shadow; the highlight is inverted into a 1 pt
    /// top inner shadow at black α 0.24.
    public static let e0 = Level(
        fill: VTheme.Color.Layer.inset,
        stroke: VTheme.Color.Stroke.default,
        strokeWidth: VTheme.Border.thin,
        highlight: 0,
        highlightFade: 0,
        innerShadow: 0.24,
        radius: VTheme.Radius.md,
        usesGlass: false,
        emphasized: false,
        darkShadows: [],
        lightShadows: [])

    /// **E1 — Raised.** Sits on its parent: cards, selected and hovered rows, the segmented track,
    /// stat pills, inspector sections.
    ///
    /// §6.1 does not give E1 a fade stop for its highlight, only "1 pt top inner highlight, white
    /// α 0.06". A fade of 1.0 is used, i.e. the gradient runs the full height — the least
    /// surprising reading, and the one that keeps §6.4's "not a solid line" rule.
    public static let e1 = Level(
        fill: VTheme.Color.Layer.surfaceRaised,
        stroke: VTheme.Color.Stroke.default,
        strokeWidth: VTheme.Border.thin,
        highlight: 0.06,
        highlightFade: 1.0,
        innerShadow: 0,
        radius: VTheme.Radius.lg,
        usesGlass: false,
        emphasized: false,
        darkShadows: [Shadow(alpha: 0.35, radius: 4, y: 2)],
        lightShadows: [Shadow(alpha: 0.10, radius: 3, y: 1)])

    /// **E2 — Floating.** Detached, above the window: popovers, menus, the floating tile toolbar,
    /// the PTZ pad, toasts, tooltips, the PiP window.
    public static let e2 = Level(
        fill: nil,
        stroke: VTheme.Color.Stroke.default,
        strokeWidth: VTheme.Border.thin,
        highlight: 0.08,
        highlightFade: 0.35,
        innerShadow: 0,
        radius: VTheme.Radius.xl,
        usesGlass: true,
        emphasized: false,
        darkShadows: [Shadow(alpha: 0.44, radius: 6, y: 3),
                      Shadow(alpha: 0.20, radius: 12, y: 6)],
        lightShadows: [Shadow(alpha: 0.14, radius: 5, y: 2),
                       Shadow(alpha: 0.06, radius: 12, y: 6)])

    /// **E3 — Modal.** Above everything, with a scrim: the command palette, sheets, alerts, the
    /// Discovery modal. The scrim itself is ``VTheme/Color/Scrim/modal`` (§6.2).
    public static let e3 = Level(
        fill: nil,
        stroke: SwiftUI.Color(lightHex: 0x000000, lightAlpha: 0.10,
                              darkHex: 0xFFFFFF, darkAlpha: 0.12),
        strokeWidth: VTheme.Border.thin,
        highlight: 0.10,
        highlightFade: 0.30,
        innerShadow: 0,
        radius: VTheme.Radius.xxl,
        usesGlass: true,
        emphasized: true,
        darkShadows: [Shadow(alpha: 0.50, radius: 10, y: 6),
                      Shadow(alpha: 0.28, radius: 24, y: 14)],
        lightShadows: [Shadow(alpha: 0.18, radius: 9, y: 5),
                       Shadow(alpha: 0.10, radius: 24, y: 14)])

    /// The four levels in order, for the token gallery.
    public static let all: [Level] = [e0, e1, e2, e3]
}

// MARK: - VInnerHighlight

/// The 1 pt top inner highlight (§6.4).
///
/// A vertically-clipped **gradient** stroke, not a solid line: a solid 1 pt white line around a
/// 14 pt continuous corner looks like a bevel. `.plusLighter` is used in the dark appearance so the
/// highlight adds light rather than painting grey; the light appearance uses `.normal` at a higher
/// alpha, where it reads as a specular edge on the material.
@MainActor
package struct VInnerHighlight: View {

    /// The corner radius of the shape being edged.
    package let radius: CGFloat

    /// Peak alpha in the dark appearance: 0.06 at E1, 0.08 at E2, 0.10 at E3. Pass 0 to disable
    /// the highlight entirely, which is what `reduceTransparency` does (§2.4).
    package let opacity: Double

    /// The fraction of the height at which the gradient reaches clear: 0.35 at E2, 0.30 at E3.
    package let fadeStop: Double

    /// When true the edge is a black inner **shadow** instead — E0's inverted highlight.
    package let inverted: Bool

    @Environment(\.colorScheme) private var scheme

    package init(radius: CGFloat, opacity: Double, fadeStop: Double, inverted: Bool = false) {
        self.radius = radius
        self.opacity = opacity
        self.fadeStop = fadeStop
        self.inverted = inverted
    }

    package var body: some View {
        VTheme.Radius.shape(radius)
            .strokeBorder(
                LinearGradient(
                    stops: [
                        Gradient.Stop(color: edge, location: 0),
                        Gradient.Stop(color: edge.opacity(0.35), location: stop * 0.5),
                        Gradient.Stop(color: .clear, location: stop),
                    ],
                    startPoint: .top,
                    endPoint: .bottom),
                lineWidth: VTheme.Border.thin)
            .blendMode(blend)
            .allowsHitTesting(false)
    }

    /// The gradient's top colour.
    ///
    /// §6.4 says the light appearance should "drop the highlight to α 0.60 white". Read literally —
    /// and that is how it is implemented — the higher alpha compensates for losing `.plusLighter`.
    private var edge: SwiftUI.Color {
        if opacity <= 0 {
            return .clear
        }
        if inverted {
            return SwiftUI.Color(light: 0x000000, dark: 0x000000, alpha: opacity)
        }
        return SwiftUI.Color(light: 0xFFFFFF, dark: 0xFFFFFF,
                             alpha: scheme == .dark ? opacity : 0.60)
    }

    /// A fade stop of 0 would collapse the gradient onto a single location, so it is treated as
    /// "no fade" and the gradient runs the full height.
    private var stop: Double {
        fadeStop > 0 ? fadeStop : 1.0
    }

    private var blend: BlendMode {
        (scheme == .dark && !inverted) ? .plusLighter : .normal
    }
}

// MARK: - VVisualEffect

/// An `NSVisualEffectView`, configured exactly.
///
/// ⛔ **Never place this over a video well.** `NSVisualEffectView` blurs what is behind it *inside
/// the window's backing store*, and `AVSampleBufferDisplayLayer`/Metal composite **above** that
/// sampling region — so a material over a tile frosts the empty canvas behind the video and reads
/// as a flat grey smear over a bright picture (§2.3, R-36). The type is `package` and the only
/// public route to it is ``SwiftUI/View/vElevation(_:radius:over:)``, which substitutes the solid
/// scrim ladder when the backdrop is `.video`.
///
/// The legal placements are exactly: sidebar and inspector (`.sidebar`, `.behindWindow`,
/// `.followsWindowActiveState`), the unified toolbar (`.headerView`, `.withinWindow`, `.active`),
/// detached overlays (`.hudWindow`, `.withinWindow`, `.active`) and the empty window background
/// (`.underWindowBackground`, `.behindWindow`, `.followsWindowActiveState`).
@MainActor
package struct VVisualEffect: NSViewRepresentable {

    /// The AppKit material.
    package let material: NSVisualEffectView.Material

    /// `.behindWindow` for window-attached chrome, `.withinWindow` for overlays.
    package let blending: NSVisualEffectView.BlendingMode

    /// `.active` for E2/E3 — a popover that greys out when the window loses focus looks broken.
    /// Sidebar and inspector do follow window state (§6.5).
    package let state: NSVisualEffectView.State

    /// `NSVisualEffectView.isEmphasized`; true for E3.
    package let emphasized: Bool

    package init(material: NSVisualEffectView.Material,
                 blending: NSVisualEffectView.BlendingMode,
                 state: NSVisualEffectView.State,
                 emphasized: Bool = false) {
        self.material = material
        self.blending = blending
        self.state = state
        self.emphasized = emphasized
    }

    package func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = state
        view.isEmphasized = emphasized
        view.autoresizingMask = [.width, .height]
        return view
    }

    package func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
        view.state = state
        view.isEmphasized = emphasized
    }
}

// MARK: - VGlass

/// The glass recipe used by every E2 and E3 surface (§6.5).
///
/// Four layers, in order: the `.hudWindow` material (or its solid fallback), a tint, the inner
/// highlight and the hairline edge — then `.compositingGroup()` so the caller's two shadows are
/// cast by the composited shape rather than by each sublayer.
///
/// **The tint is not optional.** A bare `.hudWindow` over a bright video frame or a white document
/// goes almost white and the 8 % highlight vanishes; the overlay tint pins the glass to a known
/// luminance band so `text.primary` stays ≥ 11:1 in the worst case.
///
/// ⛔ Not for use over video — see ``VVisualEffect``.
@MainActor
package struct VGlass: View {

    /// The corner radius of the surface.
    package let radius: CGFloat

    /// True for E3.
    package let emphasized: Bool

    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme

    package init(radius: CGFloat, emphasized: Bool = false) {
        self.radius = radius
        self.emphasized = emphasized
    }

    package var body: some View {
        ZStack {
            if isSolid {
                VTheme.Color.Layer.overlay
            } else {
                VVisualEffect(material: .hudWindow,
                              blending: .withinWindow,
                              state: .active,
                              emphasized: emphasized)
                VTheme.Color.Layer.overlay.opacity(scheme == .dark ? 0.28 : 0.12)
            }
            VInnerHighlight(radius: radius,
                            opacity: isSolid ? 0 : highlightAlpha,
                            fadeStop: emphasized ? 0.30 : 0.35)
            VTheme.Radius.shape(radius)
                .strokeBorder(VTheme.Color.Stroke.default,
                              lineWidth: VTheme.Border.hairline(displayScale))
        }
        .clipShape(VTheme.Radius.shape(radius))
        .compositingGroup()
        .allowsHitTesting(false)
    }

    /// Vibrancy is a contrast hazard, so `increaseContrast` also resolves to the solid fallback
    /// (§10.4), as does `reduceTransparency` (§2.4).
    private var isSolid: Bool {
        reduceTransparency || contrast == .increased
    }

    private var highlightAlpha: Double {
        emphasized ? 0.10 : 0.08
    }
}

// MARK: - View modifiers

extension View {

    /// Applies a complete elevation level — fill, stroke, inner highlight and shadows — resolving
    /// the backdrop rule on the caller's behalf.
    ///
    /// Over ``VTheme/Backdrop/chrome`` this is §6.1 exactly. Over ``VTheme/Backdrop/video`` it is
    /// §2.3 and §6.3 instead, **whatever level was asked for**: a solid `Scrim.base` fill inside
    /// the shape only, a 1 pt `Stroke.onVideo` hairline, no material, no inner highlight and **no
    /// shadow** — a shadow over live imagery is visible as a dirty smear and costs an offscreen
    /// pass. That substitution is the reason `backdrop` has no default value: the question has to
    /// be answered at every call site, normally by forwarding `\.vOnVideo`.
    ///
    /// - Parameters:
    ///   - level: one of `VTheme.Elevation.e0…e3`.
    ///   - radius: the component's own radius; pass `level.radius` to take the level's.
    ///   - backdrop: what this surface sits on.
    @MainActor
    package func vElevation(_ level: VTheme.Elevation.Level,
                            radius: CGFloat,
                            over backdrop: VTheme.Backdrop) -> some View {
        modifier(VElevation(level: level, radius: radius, backdrop: backdrop))
    }

    /// The scrim treatment for a chip, badge or toolbar that sits on a video well (§2.3).
    ///
    /// ⛔ Applied **inside the component's own shape only** — never as a full-tile gradient band
    /// (R-36). The only legal full-tile scrim is `Scrim.strong`, for the offline state.
    @MainActor
    package func vScrim(_ scrim: SwiftUI.Color = VTheme.Color.Scrim.base,
                        radius: CGFloat) -> some View {
        self.background(scrim, in: VTheme.Radius.shape(radius))
            .overlay {
                VTheme.Radius.shape(radius)
                    .strokeBorder(VTheme.Color.Stroke.onVideo, lineWidth: VTheme.Border.thin)
                    .allowsHitTesting(false)
            }
    }

    // The focus ring (§9.28) is deliberately **not** here: the manifest gives
    // `Components/FocusRing.swift` ownership of `vFocusRing(_:radius:outset:)`, and it draws with
    // `VTheme.Color.Semantic.focusRing`, `VTheme.Border.focus` / `.focusIncreased` and
    // `VTheme.Motion.micro`, all of which this token layer already publishes.
}

// MARK: - VElevation

/// The modifier behind ``SwiftUI/View/vElevation(_:radius:over:)``.
@MainActor
package struct VElevation: ViewModifier {

    package let level: VTheme.Elevation.Level
    package let radius: CGFloat
    package let backdrop: VTheme.Backdrop

    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    package func body(content: Content) -> some View {
        let tight = resolvedShadow(0)
        let ambient = resolvedShadow(1)
        return content
            .background { backgroundLayer }
            .overlay { highlightLayer }
            .overlay { borderLayer }
            .compositingGroup()
            .shadow(color: tight.color, radius: tight.radius, x: tight.x, y: tight.y)
            .shadow(color: ambient.color, radius: ambient.radius, x: ambient.x, y: ambient.y)
    }

    // MARK: - Private Helpers

    @ViewBuilder
    private var backgroundLayer: some View {
        switch backdrop {
        case .video:
            // §2.3: solid scrim, never a material, whatever level the caller asked for.
            VTheme.Radius.shape(radius).fill(VTheme.Color.Scrim.base)
        case .chrome:
            if level.usesGlass {
                VGlass(radius: radius, emphasized: level.emphasized)
            } else {
                VTheme.Radius.shape(radius).fill(level.fill ?? VTheme.Color.Layer.surface)
            }
        }
    }

    @ViewBuilder
    private var highlightLayer: some View {
        // Chrome only: an inner highlight over video is one more thing drawn on the frame (P1).
        if backdrop == .chrome, !level.usesGlass, level.highlight > 0 || level.innerShadow > 0 {
            VInnerHighlight(radius: radius,
                            opacity: level.innerShadow > 0 ? level.innerShadow : level.highlight,
                            fadeStop: level.highlightFade,
                            inverted: level.innerShadow > 0)
        }
    }

    @ViewBuilder
    private var borderLayer: some View {
        // VGlass already draws its own hairline edge, so a chrome glass level does not double it.
        if backdrop == .video {
            VTheme.Radius.shape(radius)
                .strokeBorder(VTheme.Color.Stroke.onVideo, lineWidth: VTheme.Border.thin)
                .allowsHitTesting(false)
        } else if !level.usesGlass {
            VTheme.Radius.shape(radius)
                .strokeBorder(level.stroke, lineWidth: level.strokeWidth)
                .allowsHitTesting(false)
        }
    }

    /// The shadow at `index`, or a transparent zero-radius no-op.
    ///
    /// Returns the no-op over video (§6.3) and under `increaseContrast`, where shadows are removed
    /// and replaced by the thicker 1 pt borders the token set already produces (§10.4).
    private func resolvedShadow(_ index: Int) -> VTheme.Elevation.Shadow {
        let none = VTheme.Elevation.Shadow(alpha: 0, radius: 0, y: 0)
        guard backdrop == .chrome, contrast != .increased else { return none }
        return level.shadow(index, scheme) ?? none
    }
}

#endif  // os(macOS)
