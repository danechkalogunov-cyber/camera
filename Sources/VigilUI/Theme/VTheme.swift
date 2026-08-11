//
//  VTheme.swift
//  VigilUI
//
//  The design-token namespace. Every colour, type step, dimension, elevation and animation used
//  anywhere in VigilUI resolves through VTheme, and no view is permitted a literal of its own.
//  macOS-only. See docs/DESIGN.md §12 and docs/API_CONTRACT.md §4.11.
//

#if os(macOS)

import SwiftUI

// MARK: - VTheme

/// The single source of design values for `VigilUI`.
///
/// `VTheme` is a pure namespace: it has no cases, no storage and no instances. Every sub-namespace
/// is declared empty here and populated by one sibling file, so that a reviewer can hold the whole
/// token surface in view at once:
///
/// | Namespace | File | Spec |
/// |---|---|---|
/// | `Color` | `VTheme+Color.swift` | DESIGN.md §3, §2.4 |
/// | `Typography` | `VTheme+Typography.swift` | DESIGN.md §4 |
/// | `Space`, `Radius`, `Border`, `Metrics` | `VTheme+Space.swift` | DESIGN.md §5 |
/// | `Elevation` | `VTheme+Elevation.swift` | DESIGN.md §6 |
/// | `Motion` | `VTheme+Motion.swift` | DESIGN.md §7 |
/// | `Icon`, `Symbol` | `VTheme+Icon.swift` | DESIGN.md §8 |
/// | `Health`, `VLevel` | `VTheme+Health.swift` | DESIGN.md §9.20 |
///
/// **The one rule this type exists to enforce:** a hex colour, a point size, a radius, a duration,
/// a spring, a shadow or an inset that appears anywhere other than these files is a defect, not a
/// style preference (DESIGN.md §12.4). If a view needs a value that is not here, it is added here
/// first, with the measurement that justifies it.
///
/// Everything is `@MainActor` because `VigilUI` is a `@MainActor` module (R-40) and because a
/// `SwiftUI.Color` built from `NSColor(name:dynamicProvider:)` is only ever read while laying out
/// a view.
@MainActor
public enum VTheme {

    // MARK: Colour

    /// Colour tokens, in both appearances and both contrast settings (DESIGN.md §3).
    ///
    /// The nested namespaces mirror the tables in the specification exactly: `Layer` is the six-step
    /// depth ladder, `Text` the four-step ink ramp plus its inverse, `Stroke` the alpha hairlines,
    /// `Semantic` the reserved status vocabulary, `Ident` the six categorical camera colours and
    /// `Scrim` the solid black ladder that is the **only** legal chrome backdrop over video.
    @MainActor
    public enum Color {

        /// The six-layer depth ladder plus the solid fallbacks for the four materials (§2.2, §2.4).
        @MainActor public enum Layer {}

        /// The text ramp (§3.2). `tertiary` is deliberately ≥ 4.5:1 on all four layers.
        @MainActor public enum Text {}

        /// Hairline strokes, expressed as alpha over whatever is beneath them (§3.3).
        @MainActor public enum Stroke {}

        /// The reserved status vocabulary and the Iris accent (§3.1, §3.2).
        @MainActor public enum Semantic {}

        /// The six categorical camera-identity colours (§3.4).
        @MainActor public enum Ident {}

        /// The solid black scrim ladder used for chrome over video (§2.3).
        @MainActor public enum Scrim {}
    }

    // MARK: Typography

    /// The nine-step display scale plus the Mono track (§4).
    @MainActor public enum Typography {}

    // MARK: Geometry

    /// The 4 pt spacing ladder (§5.1).
    @MainActor public enum Space {}

    /// The radius scale. Every rounded rectangle in Vigil is `.continuous` (§5.2).
    @MainActor public enum Radius {}

    /// Border widths, including the display-scale hairline (§5.4).
    @MainActor public enum Border {}

    /// Control heights, row heights and the fixed structural dimensions (§5.1, §5.5; R-34, R-37).
    @MainActor public enum Metrics {}

    /// Icon point sizes, weights and label gaps (§8.1).
    @MainActor public enum Icon {}

    // MARK: Elevation

    /// The four elevation levels, each a quadruple of fill, stroke, inner highlight and shadow (§6).
    @MainActor public enum Elevation {}

    // MARK: Motion

    /// Six springs, four curves, three repeaters and the timing constants (§7.1, §7.2).
    @MainActor public enum Motion {}

    // MARK: Backdrop

    /// What a piece of chrome is drawn on top of.
    ///
    /// This is the type that makes DESIGN.md's hardest rule structural rather than advisory:
    ///
    /// > ⛔ **Never a material over video.** `NSVisualEffectView` blurs what is behind it *inside the
    /// > window's backing store*, and `AVSampleBufferDisplayLayer`/Metal composite **above** that
    /// > sampling region — so a material over a tile frosts the empty canvas behind the video and
    /// > reads as a flat grey smear over a bright picture (§2.3, R-36).
    ///
    /// Every elevation and background modifier in `VigilUI` takes a `Backdrop` **without a default**,
    /// so a call site cannot forget to answer the question. `.video` resolves to the solid scrim
    /// ladder (`Color.Scrim`), a `Color.Stroke.onVideo` hairline and **no shadow** (§6.3); it never
    /// resolves to a material, whatever the caller asks for.
    ///
    /// The value normally comes from `\.vOnVideo` (§12.3), which `VTile` sets for its subtree.
    public enum Backdrop {

        /// Ordinary window chrome: sidebar, inspector, toolbar, popovers, sheets. Materials allowed.
        case chrome

        /// A video well, or anything overlapping one. Materials and shadows are forbidden here.
        case video
    }
}

#endif  // os(macOS)
