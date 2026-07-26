//
//  VTheme+Color.swift
//  VigilUI
//
//  Every colour token, in both appearances and both contrast settings, bridged through
//  NSColor(name:dynamicProvider:) because SwiftUI.Color has no light/dark initialiser.
//  macOS-only. See docs/DESIGN.md §2.4, §3 and §12.2, and docs/API_CONTRACT.md §4.11.
//

#if os(macOS)

import Foundation

import AppKit
import SwiftUI

// MARK: - The dynamic-colour bridge

/// Classifies an `NSAppearance` into the two axes the tokens vary on.
///
/// `NSAppearance.bestMatch(from:)` is the documented way to ask an arbitrary appearance which of a
/// set of known appearances it behaves like, and the *high-contrast* appearance names are part of
/// that set — when System Settings ▸ Accessibility ▸ Display ▸ Increase contrast is on, the
/// effective appearance is `accessibilityHighContrast…`. Resolving contrast from the appearance
/// rather than from `NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast` matters,
/// because the dynamic provider is re-invoked on appearance change and a global read would not be.
///
///     func bestMatch(from appearances: [NSAppearance.Name]) -> NSAppearance.Name?
///
/// Returns dark, normal contrast when the appearance matches nothing: dark is the designed-first
/// appearance (DESIGN.md §0) and a wrong guess there is the least visually damaging.
private func vResolveAppearance(_ appearance: NSAppearance) -> (isDark: Bool, isHighContrast: Bool) {
    let candidates: [NSAppearance.Name] = [
        .aqua,
        .darkAqua,
        .vibrantLight,
        .vibrantDark,
        .accessibilityHighContrastAqua,
        .accessibilityHighContrastDarkAqua,
        .accessibilityHighContrastVibrantLight,
        .accessibilityHighContrastVibrantDark,
    ]
    guard let name = appearance.bestMatch(from: candidates) else {
        return (isDark: true, isHighContrast: false)
    }
    switch name {
    case .darkAqua, .vibrantDark:
        return (isDark: true, isHighContrast: false)
    case .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark:
        return (isDark: true, isHighContrast: true)
    case .accessibilityHighContrastAqua, .accessibilityHighContrastVibrantLight:
        return (isDark: false, isHighContrast: true)
    default:
        return (isDark: false, isHighContrast: false)
    }
}

extension NSColor {

    /// Builds an sRGB colour from a `0xRRGGBB` literal.
    ///
    /// `fileprivate` on purpose: hex literals are legal in this file and nowhere else in the module.
    ///
    ///     convenience init(srgbRed: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)
    fileprivate convenience init(srgbHex hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

extension SwiftUI.Color {

    /// An opaque appearance- and contrast-aware token.
    ///
    /// - Parameters:
    ///   - light: the value in the Aqua appearance, as `0xRRGGBB` in sRGB.
    ///   - dark: the value in the Dark Aqua appearance, as `0xRRGGBB` in sRGB.
    ///   - lightHC: the light value under `increaseContrast`; defaults to `light`.
    ///   - darkHC: the dark value under `increaseContrast`; defaults to `dark`.
    ///   - alpha: a constant alpha applied in every appearance.
    ///
    /// The `NSColor` bridge is what makes appearance switching work everywhere — including inside
    /// AppKit views such as the window background and `NSVisualEffectView` subviews, which is why
    /// the tokens are not written as `Color(.sRGB, red:green:blue:)` (DESIGN.md §12.2).
    ///
    ///     convenience init(name: NSColor.Name?, dynamicProvider: @escaping (NSAppearance) -> NSColor)
    init(light: UInt32, dark: UInt32,
         lightHC: UInt32? = nil, darkHC: UInt32? = nil,
         alpha: CGFloat = 1) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let match = vResolveAppearance(appearance)
            let hex: UInt32 = match.isDark
                ? (match.isHighContrast ? (darkHC ?? dark) : dark)
                : (match.isHighContrast ? (lightHC ?? light) : light)
            return NSColor(srgbHex: hex, alpha: alpha)
        })
    }

    /// An appearance-aware token whose **alpha** is the thing that changes.
    ///
    /// Strokes, accent tints and the scrim ladder are all specified as an alpha over whatever is
    /// beneath them, and `increaseContrast` raises the alpha rather than swapping the hue
    /// (DESIGN.md §3.3, §3.5, §10.4). A single-alpha token cannot express that, so this is the
    /// second, and last, bridge.
    init(lightHex: UInt32, lightAlpha: CGFloat,
         darkHex: UInt32, darkAlpha: CGFloat,
         lightHCAlpha: CGFloat? = nil, darkHCAlpha: CGFloat? = nil) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let match = vResolveAppearance(appearance)
            if match.isDark {
                let a = match.isHighContrast ? (darkHCAlpha ?? darkAlpha) : darkAlpha
                return NSColor(srgbHex: darkHex, alpha: a)
            }
            let a = match.isHighContrast ? (lightHCAlpha ?? lightAlpha) : lightAlpha
            return NSColor(srgbHex: lightHex, alpha: a)
        })
    }
}

// MARK: - Layer

extension VTheme.Color.Layer {

    /// L1. The stage background behind and between tiles, and the window background. Solid.
    public static let canvas = SwiftUI.Color(light: 0xF3F4F7, dark: 0x0B0C0F)

    /// L3. Inline containers: cards, list rows, fields, inspector sections. Solid.
    public static let surface = SwiftUI.Color(light: 0xFFFFFF, dark: 0x16181D)

    /// L4. Selected and hovered rows, segmented thumbs, stat pills, inset wells inside a surface.
    public static let surfaceRaised = SwiftUI.Color(light: 0xFFFFFF, dark: 0x1D2026)

    /// L5. Popovers, menus, toasts, floating toolbars, the palette, sheets. Also the solid fallback
    /// for the `.hudWindow` material under `reduceTransparency` (§2.4).
    public static let overlay = SwiftUI.Color(light: 0xFFFFFF, dark: 0x252932)

    /// L0. The video itself and its letterbox area. `#000000` in **both** appearances, always: video
    /// wells do not participate in appearance and take no tint, material, gradient or opacity (§3.6).
    public static let videoWell = SwiftUI.Color(light: 0x000000, dark: 0x000000)

    /// Pure black, the base of the scrim ladder and of the modal scrim. Use `VTheme.Color.Scrim`
    /// rather than composing an opacity onto this by hand.
    public static let scrim = SwiftUI.Color(light: 0x000000, dark: 0x000000)

    /// E0's fill: recessed into its parent — text fields, sliders, wells, the timeline track (§6.1).
    public static let inset = SwiftUI.Color(light: 0xE9EAEE, dark: 0x0B0C0F)

    /// Solid fallback for the `.sidebar` material under `reduceTransparency` (§2.4).
    public static let sidebarFallback = SwiftUI.Color(light: 0xEBECF0, dark: 0x101116)

    /// Solid fallback for the `.headerView` material under `reduceTransparency` (§2.4).
    public static let headerFallback = SwiftUI.Color(light: 0xF0F1F4, dark: 0x131519)

    /// Solid fallback for `.underWindowBackground` under `reduceTransparency` (§2.4). Identical to
    /// `canvas` by construction — the empty state should not shift when transparency is reduced.
    public static let underWindowFallback = SwiftUI.Color(light: 0xF3F4F7, dark: 0x0B0C0F)
}

// MARK: - Text

extension VTheme.Color.Text {

    /// 17.76:1 on canvas, 13.23:1 on overlay glass, 19.07:1 over a video well. AAA everywhere.
    public static let primary = SwiftUI.Color(light: 0x14161A, dark: 0xF2F4F8)

    /// 8.78:1 on canvas, 6.54:1 on overlay glass.
    public static let secondary = SwiftUI.Color(light: 0x4E5765, dark: 0xA7AEBC)

    /// 6.08:1 on canvas, 4.52:1 on overlay glass — the tightest text pair in the app, deliberately
    /// still ≥ AA on all four layers. Under `increaseContrast` it becomes `secondary` (§10.4).
    public static let tertiary = SwiftUI.Color(light: 0x626B79, dark: 0x88909D,
                                               lightHC: 0x4E5765, darkHC: 0xA7AEBC)

    /// 2.61:1 — intentionally sub-AA, which WCAG exempts for disabled controls. A disabled control
    /// must **always** carry a second, non-colour cue: it loses its stroke, and a disabled *action*
    /// carries a `Caption1` reason string ("Camera offline"). Raised to 4.05:1 under
    /// `increaseContrast` (§10.1, §10.4).
    public static let disabled = SwiftUI.Color(light: 0xA9B0BB, dark: 0x4E5563, darkHC: 0x6E7583)

    /// Ink on a warm or green fill. Warm and green fills always take ink text, never white:
    /// `text.inverse` on `warn`/`motion`/`ok` measures 13.69 / 9.51 / 10.21.
    public static let inverse = SwiftUI.Color(light: 0xFFFFFF, dark: 0x0B0C0F)
}

// MARK: - Stroke

extension VTheme.Color.Stroke {

    /// Dividers inside a surface, table rules, disabled borders. White α 0.06 dark / black α 0.06
    /// light, rising to α 0.14 under `increaseContrast`.
    public static let subtle = SwiftUI.Color(lightHex: 0x000000, lightAlpha: 0.06,
                                             darkHex: 0xFFFFFF, darkAlpha: 0.06,
                                             lightHCAlpha: 0.14, darkHCAlpha: 0.14)

    /// The standard hairline: card, field, popover and toolbar borders. White α 0.10 dark /
    /// black α 0.12 light, rising to α 0.28 under `increaseContrast`.
    public static let `default` = SwiftUI.Color(lightHex: 0x000000, lightAlpha: 0.12,
                                                darkHex: 0xFFFFFF, darkAlpha: 0.10,
                                                lightHCAlpha: 0.28, darkHCAlpha: 0.28)

    /// Hovered controls, segmented track, selected chip. Rises to α 0.40 under `increaseContrast`.
    public static let strong = SwiftUI.Color(lightHex: 0x000000, lightAlpha: 0.22,
                                             darkHex: 0xFFFFFF, darkAlpha: 0.18,
                                             lightHCAlpha: 0.40, darkHCAlpha: 0.40)

    /// Reserved for `increaseContrast` mode, where a stroke has to survive on its own (§10.4).
    public static let contrast = SwiftUI.Color(lightHex: 0x000000, lightAlpha: 0.34,
                                               darkHex: 0xFFFFFF, darkAlpha: 0.28)

    /// On a video well the backdrop is `#000000` in both appearances, so α 0.10 disappears and the
    /// hairline flips to white α 0.14 (§3.3). This is the stroke that goes with `Scrim.base`.
    public static let onVideo = SwiftUI.Color(lightHex: 0xFFFFFF, lightAlpha: 0.14,
                                              darkHex: 0xFFFFFF, darkAlpha: 0.14)

    /// The hovered form of `onVideo` (§9.1, icon button on video).
    public static let onVideoStrong = SwiftUI.Color(lightHex: 0xFFFFFF, lightAlpha: 0.22,
                                                    darkHex: 0xFFFFFF, darkAlpha: 0.22)

    /// A group separator inside a toolbar that sits on video: 1 × 16 pt at white α 0.14 (§9.11).
    public static let onVideoSeparator = onVideo
}

// MARK: - Semantic

extension VTheme.Color.Semantic {

    /// Iris, hue ≈ 253°. Glyphs and strokes; 4.65:1 on canvas, 3.46:1 on overlay glass.
    ///
    /// The system accent (`NSColor.controlAccentColor`) is deliberately **not** used anywhere in
    /// Vigil: a red or orange system accent would collide with the status vocabulary below. This is
    /// a documented, intentional deviation from the HIG (§3.1).
    public static let accent = SwiftUI.Color(light: 0x5B44E0, dark: 0x7B61FF)

    /// Hover state of an accented control.
    public static let accentHover = SwiftUI.Color(light: 0x6A52E8, dark: 0x8B74FF)

    /// Pressed state of an accented control.
    public static let accentPressed = SwiftUI.Color(light: 0x4A34C9, dark: 0x6A4CF7)

    /// Button fills that carry white text: white on `accentFill` is 5.86:1.
    public static let accentFill = SwiftUI.Color(light: 0x5B44E0, dark: 0x6247E8)

    /// A lightened Iris that clears 3:1 against **every** layer including L5 overlay glass (4.76:1)
    /// and a video well (6.86:1), as a focus indicator must (§9.28, §10.1).
    public static let focusRing = SwiftUI.Color(light: 0x5B44E0, dark: 0x9581FF)

    /// Recording and live. 5.63:1 as a dot on `#000000`.
    public static let live = SwiftUI.Color(light: 0xC40E20, dark: 0xFF2E43)

    /// Fill behind white text: white on `liveFill` is 4.97:1.
    public static let liveFill = SwiftUI.Color(light: 0xC40E20, dark: 0xDE1327)

    /// Healthy. Note the light appearance is shade-shifted, not merely reused: `#32D74B` on white
    /// is 1.9:1 and unusable (§3.2).
    public static let ok = SwiftUI.Color(light: 0x157A2B, dark: 0x32D74B)

    /// Fill behind white text: white on `okFill` is 5.12:1.
    public static let okFill = SwiftUI.Color(light: 0x157A2B, dark: 0x157F28)

    /// Degraded. Always takes `text.inverse`, never white (13.69:1).
    public static let warn = SwiftUI.Color(light: 0x7D5800, dark: 0xFFD426)

    /// A motion event on a camera. Always takes `text.inverse` on a fill (9.51:1).
    public static let motion = SwiftUI.Color(light: 0x9A5300, dark: 0xFF9F0A)

    /// Errors and destructive actions.
    public static let danger = SwiftUI.Color(light: 0xC42B1C, dark: 0xFF5F52)

    /// Fill behind white text: white on `dangerFill` is 5.12:1.
    public static let dangerFill = SwiftUI.Color(light: 0xC42B1C, dark: 0xCE3223)

    /// Continuous recording on the playback timeline.
    public static let continuous = SwiftUI.Color(light: 0x0B5FB8, dark: 0x3B9CFF)

    /// An arbitrary accent tint. Prefer the named steps in ``Tint``, which carry the per-appearance
    /// alphas from §3.5; this exists for the cases the table does not cover.
    public static func accentTint(_ alpha: Double) -> SwiftUI.Color {
        accent.opacity(alpha)
    }

    /// The four accent tints, derived rather than separate tokens (§3.5).
    ///
    /// Dark uses α 0.10 / 0.16 / 0.24 / 0.32; light uses α 0.10 / 0.14 / 0.20 / 0.26, because a
    /// tint over `#F3F4F7` reaches the same perceived strength at a lower alpha.
    @MainActor
    public enum Tint {

        /// Selected row at rest.
        public static let selected = SwiftUI.Color(lightHex: 0x5B44E0, lightAlpha: 0.10,
                                                   darkHex: 0x7B61FF, darkAlpha: 0.10)

        /// Selected row, hovered. Also the palette's selected-row fill (§9.16 uses α 0.18 dark).
        public static let selectedHover = SwiftUI.Color(lightHex: 0x5B44E0, lightAlpha: 0.14,
                                                        darkHex: 0x7B61FF, darkAlpha: 0.16)

        /// Pressed.
        public static let pressed = SwiftUI.Color(lightHex: 0x5B44E0, lightAlpha: 0.20,
                                                  darkHex: 0x7B61FF, darkAlpha: 0.24)

        /// Drop target.
        public static let dropTarget = SwiftUI.Color(lightHex: 0x5B44E0, lightAlpha: 0.26,
                                                     darkHex: 0x7B61FF, darkAlpha: 0.32)
    }
}

// MARK: - Ident

extension VTheme.Color.Ident {

    /// Cyan. L\* 70.0 dark.
    public static let cyan = SwiftUI.Color(light: 0x0C6E92, dark: 0x2FB8E8)

    /// Jade. L\* 76.9 dark.
    public static let jade = SwiftUI.Color(light: 0x0B7A5A, dark: 0x37D6A0)

    /// Citron. L\* 87.7 dark.
    public static let citron = SwiftUI.Color(light: 0x7A6A10, dark: 0xF0DE5C)

    /// Coral. L\* 61.3 dark.
    public static let coral = SwiftUI.Color(light: 0xC0492B, dark: 0xF5674A)

    /// Orchid. L\* 56.7 dark.
    public static let orchid = SwiftUI.Color(light: 0x7A46B8, dark: 0xA867F5)

    /// Steel. L\* 57.4 dark.
    public static let steel = SwiftUI.Color(light: 0x46586F, dark: 0x7A8BA4)

    /// The six identity colours in assignment order. Minimum pairwise CIELAB ΔE is 29.8 normal,
    /// 21.9 protanopia, 26.2 deuteranopia, 15.8 tritanopia (§3.4).
    ///
    /// ⛔ Identity colours are never used for state. A Coral camera that is recording still shows
    /// the `live` red dot; the Coral appears only in the rail and the initial.
    public static let all: [SwiftUI.Color] = [cyan, jade, citron, coral, orchid, steel]

    /// The identity index for a camera, when no explicit assignment has been persisted.
    ///
    /// `VigilCore` assigns identity colours round-robin at camera creation and stores the choice;
    /// this is the deterministic fallback used before that record exists (and by previews). It sums
    /// the sixteen bytes of the UUID so the result is stable across launches — `Hashable.hashValue`
    /// is seeded per process and would not be.
    public static func index(for id: UUID) -> Int {
        var sum = 0
        withUnsafeBytes(of: id.uuid) { raw in
            for byte in raw {
                sum &+= Int(byte)
            }
        }
        return sum % all.count
    }

    /// The identity colour for a camera. See ``index(for:)`` for the derivation.
    public static func colour(for id: UUID) -> SwiftUI.Color {
        colour(at: index(for: id))
    }

    /// The identity colour at an index, wrapping. Negative indices wrap forwards, so a caller that
    /// subtracts its way off the front of the list still gets a colour rather than a trap.
    public static func colour(at index: Int) -> SwiftUI.Color {
        let count = all.count
        let wrapped = ((index % count) + count) % count
        return all[wrapped]
    }

    /// The chip fill for an identity colour: `C` at α 0.18 (§3.4).
    public static func fill(_ colour: SwiftUI.Color) -> SwiftUI.Color {
        colour.opacity(0.18)
    }

    /// The chip stroke for an identity colour: `C` at α 0.40 (§3.4).
    public static func stroke(_ colour: SwiftUI.Color) -> SwiftUI.Color {
        colour.opacity(0.40)
    }

    /// The sidebar leading rail: the identity colour at α 0.90 (§9.12).
    public static func rail(_ colour: SwiftUI.Color) -> SwiftUI.Color {
        colour.opacity(0.90)
    }
}

// MARK: - Scrim

extension VTheme.Color.Scrim {

    /// Black α 0.45. Composites to `#8C8C8C` over a worst-case all-white frame — 3.05:1 against
    /// `text.primary`, so it is for gradient tails only and **never** goes behind text (§2.3).
    public static let light = SwiftUI.Color(lightHex: 0x000000, lightAlpha: 0.45,
                                            darkHex: 0x000000, darkAlpha: 0.45)

    /// Black α 0.62 — 5.20:1 against `text.primary` over an all-white frame. The tile name chip,
    /// the stats HUD and the hover toolbar. Rises to α 0.78 under `increaseContrast` (§10.4).
    ///
    /// ⛔ Applied **inside the chip or toolbar shape only**, never as a full-tile gradient band
    /// (R-36). The one legal full-tile scrim is ``strong``, for the offline state.
    public static let base = SwiftUI.Color(lightHex: 0x000000, lightAlpha: 0.62,
                                           darkHex: 0x000000, darkAlpha: 0.62,
                                           lightHCAlpha: 0.78, darkHCAlpha: 0.78)

    /// Black α 0.82 — 12.33:1. The offline / auth-failure overlay over the dimmed last-known frame,
    /// and the cinema control bar's fallback when the Metal backdrop is unavailable.
    public static let strong = SwiftUI.Color(lightHex: 0x000000, lightAlpha: 0.82,
                                             darkHex: 0x000000, darkAlpha: 0.82)

    /// The E3 modal scrim over the whole window: α 0.44 dark, α 0.22 light (§6.2). Not applied over
    /// video wells in cinema mode, where the palette already floats over black.
    public static let modal = SwiftUI.Color(lightHex: 0x000000, lightAlpha: 0.22,
                                            darkHex: 0x000000, darkAlpha: 0.44)
}

#endif  // os(macOS)
