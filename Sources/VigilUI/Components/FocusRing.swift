//
//  FocusRing.swift
//  VigilUI
//
//  The one focus-ring treatment every control in Vigil uses, as a modifier so that no component
//  reimplements it and no two controls disagree about it.
//  macOS-only. Implements docs/DESIGN.md §9.28, §7.4 #25, §10.4.
//

#if os(macOS)

import SwiftUI

// MARK: - VFocusRing

/// The focus indicator: a 2 pt `focusRing` stroke outside the control's own shape, plus a soft
/// outer glow, appearing with ``VTheme/Motion/micro``.
///
/// `focusRing` `#9581FF` is a lightened Iris chosen so that it clears 3:1 against **every** layer,
/// including L5 overlay glass (4.76:1) and a video well (6.86:1) — which is the actual requirement
/// for a focus indicator, and the reason the ring is not simply `accent` (DESIGN.md §3.1, §10.1).
///
/// Under `increaseContrast` the ring thickens to 3 pt and the glow is dropped: a blurred halo is a
/// contrast hazard, and the thicker hard edge carries the same information (§10.4). Under reduced
/// motion the ring cross-fades in place with no scale (§7.10 rule 2).
@MainActor
package struct VFocusRing: ViewModifier {

    // MARK: - Geometry

    /// The ring's distance outside the control's own shape, for chrome: 3 pt (§9.28).
    ///
    /// Lives here rather than in `VTheme.Space` because it is this component's geometry — the
    /// token layer's `Elevation` file explicitly assigns `Components/FocusRing.swift` ownership of
    /// the ring — and because 3 pt is not a step on the 4 pt spacing ladder (§5.1).
    package static let outsetChrome: CGFloat = 3

    /// The outset on a video tile: 2 pt, and the ring is drawn **inside** the tile's own bounds so
    /// that a neighbouring tile at the 2 pt gutter cannot clip it (§9.28).
    package static let outsetOnVideo: CGFloat = 2

    /// The glow's blur radius, 3 pt, at `focusRing` α 0.30 (§7.4 #25).
    package static let glowRadius: CGFloat = 3

    /// The scale the ring enters from, so it appears to settle onto the control (§7.4 #25).
    package static let entryScale: CGFloat = 1.06

    // MARK: - Stored Properties

    /// Whether the control this is attached to currently has keyboard focus.
    package let isFocused: Bool

    /// The control's own corner radius. The ring is drawn at `radius + outset` so the two curves
    /// stay concentric.
    package let radius: CGFloat

    /// Distance outside the control's shape. Pass ``outsetOnVideo`` over a video well.
    package let outset: CGFloat

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.vMotionEnabled) private var motionEnabled

    // MARK: - ViewModifier

    package func body(content: Content) -> some View {
        content
            .overlay { ring }
            .animation(VTheme.Motion.resolved(VTheme.Motion.micro, reduced: !motionEnabled),
                       value: isFocused)
    }

    // MARK: - Private Helpers

    private var ring: some View {
        // The glow is the one sanctioned `.shadow(` outside the elevation appliers (§12.4): it is
        // an accessibility indicator rather than depth, and §9.28 specifies it as a shadow.
        VTheme.Radius.shape(radius + outset)
            .strokeBorder(VTheme.Color.Semantic.focusRing, lineWidth: lineWidth)
            .padding(-outset)
            .shadow(color: glowColour, radius: isHighContrast ? 0 : Self.glowRadius)
            .opacity(isFocused ? 1 : 0)
            .scaleEffect(scale)
            .allowsHitTesting(false)
    }

    private var isHighContrast: Bool {
        contrast == .increased
    }

    private var lineWidth: CGFloat {
        isHighContrast ? VTheme.Border.focusIncreased : VTheme.Border.focus
    }

    /// Clear under `increaseContrast`, where the glow is dropped entirely (§10.4).
    private var glowColour: SwiftUI.Color {
        isHighContrast ? .clear : VTheme.Color.Semantic.focusRing.opacity(0.30)
    }

    /// The unfocused state sits slightly large so the ring settles inwards as it appears; under
    /// reduced motion it is a pure cross-fade (§7.10 rule 2).
    private var scale: CGFloat {
        guard motionEnabled else { return 1 }
        return isFocused ? 1 : Self.entryScale
    }
}

// MARK: - View modifier

extension View {

    /// Draws Vigil's focus ring around this control.
    ///
    /// ⛔ Pair it with `.focusEffectDisabled()` on the same control so the system ring never
    /// double-draws with ours. Native controls we do not restyle keep the system ring instead
    /// (DESIGN.md §9.28).
    ///
    /// - Parameters:
    ///   - isFocused: normally an `@FocusState` binding's value.
    ///   - radius: the control's own corner radius.
    ///   - outset: distance outside the control's shape; pass ``VFocusRing/outsetOnVideo`` for
    ///     chrome that sits on a video well, where the ring must not be clipped by the gutter.
    @MainActor
    package func vFocusRing(_ isFocused: Bool,
                            radius: CGFloat,
                            outset: CGFloat = VFocusRing.outsetChrome) -> some View {
        modifier(VFocusRing(isFocused: isFocused, radius: radius, outset: outset))
    }
}

#endif  // os(macOS)
