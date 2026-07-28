//
//  VChip.swift
//  VigilUI
//
//  The 20 pt chip: the camera name on a tile, the status cluster's pills, and the filter chips.
//  macOS-only. Implements docs/DESIGN.md §9.9, §3.4 (identity recipe), §2.3 (the scrim rule).
//

#if os(macOS)

import SwiftUI

// MARK: - VChip

/// A 20 pt capsule-adjacent pill: `Caption1` content, 6 pt horizontal padding, `radius.sm` 6.
///
/// ⛔ Over a video well a chip is filled with the **solid** `Scrim.base` inside its own shape and
/// edged with `Stroke.onVideo` — never a material, and never a full-tile gradient band underneath
/// it. `NSVisualEffectView` samples the window's backing store, which the video layer composites
/// *above*, so a material over a tile frosts the empty canvas behind the picture and reads as a
/// grey smear (DESIGN.md §2.3, R-36).
///
/// The chip carries no shadow on video either: a shadow over live imagery is a visible dirty smear
/// and costs an offscreen pass (§6.3).
@MainActor
package struct VChip<Content: View>: View {

    // MARK: - Style

    /// The three chip families of §9.9, plus the on-video treatment they share (§2.3).
    package enum Style: Sendable, Hashable {

        /// The tile's name chip and status pills: solid `Scrim.base`, `Stroke.onVideo` hairline,
        /// `text.primary`.
        case onVideo

        /// A chip on ordinary chrome, at rest: `white α 0.08`, no stroke.
        case neutral

        /// A selected filter chip: `accent α 0.18` fill, `accent α 0.40` stroke, `accent` text.
        case selected
    }

    // MARK: - Geometry

    /// 20 pt tall — the `xs` control height (§5.5, §9.9).
    package static var height: CGFloat { VTheme.Metrics.xs }

    // MARK: - Stored Properties

    /// Which family this chip belongs to.
    package let style: Style

    /// Rest opacity. The tile's name chip sits at 0.70 until the tile is hovered (§9.13); every
    /// other chip is 1.
    package let restOpacity: Double

    private let content: () -> Content

    // MARK: - Initialisation

    /// Creates a chip.
    ///
    /// - Parameters:
    ///   - style: the family. `.onVideo` for anything drawn on a video well.
    ///   - restOpacity: the chip's opacity; pass 0.70 for a tile name chip at rest (§9.13).
    ///   - content: the chip's contents, laid out in an `HStack` at the 4 pt inner gap. Text is
    ///     styled `Caption1` by the chip, so a call site does not restate it.
    package init(_ style: Style,
                 restOpacity: Double = 1,
                 @ViewBuilder content: @escaping () -> Content) {
        self.style = style
        self.restOpacity = restOpacity
        self.content = content
    }

    // MARK: - View

    package var body: some View {
        HStack(spacing: VTheme.Space.xxs) {
            content()
        }
        .vType(VTheme.Typography.caption1)
        .foregroundStyle(foreground)
        .padding(.horizontal, VTheme.Space.xs)
        .frame(height: Self.height)
        .background(fill, in: VTheme.Radius.shape(VTheme.Radius.sm))
        .overlay { border }
        .opacity(restOpacity)
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: - Private Helpers

    private var fill: SwiftUI.Color {
        switch style {
        case .onVideo: return VTheme.Color.Scrim.base
        case .neutral: return SwiftUI.Color.white.opacity(0.08)
        case .selected: return VTheme.Color.Semantic.accent.opacity(0.18)
        }
    }

    private var foreground: SwiftUI.Color {
        switch style {
        case .onVideo: return VTheme.Color.Text.onVideo
        case .neutral: return VTheme.Color.Text.secondary
        case .selected: return VTheme.Color.Semantic.accent
        }
    }

    @ViewBuilder
    private var border: some View {
        switch style {
        case .onVideo:
            VTheme.Radius.shape(VTheme.Radius.sm)
                .strokeBorder(VTheme.Color.Stroke.onVideo, lineWidth: VTheme.Border.thin)
                .allowsHitTesting(false)
        case .neutral:
            EmptyView()
        case .selected:
            VTheme.Radius.shape(VTheme.Radius.sm)
                .strokeBorder(VTheme.Color.Semantic.accent.opacity(0.40),
                              lineWidth: VTheme.Border.thin)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - VIdentityMark

/// The camera's identity mark: a 6 pt dot in its assigned colour, which becomes the camera's
/// initial when `differentiateWithoutColor` is on.
///
/// ⛔ Identity colour is never a state: a Coral camera that is recording still shows the `live` red
/// dot in the status cluster, and the Coral appears only here and on the sidebar rail (§3.4). The
/// initial makes the colour redundant encoding rather than the sole carrier of identity, which is
/// what satisfies `differentiateWithoutColor` without a second layout.
@MainActor
package struct VIdentityMark: View {

    /// The dot's diameter, matching ``VLiveDot/dotSize`` so a chip's leading marks line up (§9.9).
    package static let dotSize: CGFloat = 6

    /// The box the initial is drawn in when colour cannot be relied on (§9.9).
    package static let glyphBox: CGFloat = 9

    /// The camera's assigned identity colour.
    package let colour: SwiftUI.Color

    /// The camera's first letter, used as the non-colour partner.
    package let initial: Character?

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate

    /// Creates an identity mark.
    package init(colour: SwiftUI.Color, initial: Character?) {
        self.colour = colour
        self.initial = initial
    }

    package var body: some View {
        Group {
            if differentiate, let initial {
                Text(String(initial))
                    .vType(VTheme.Typography.caption2)
                    .foregroundStyle(colour)
                    .frame(width: Self.glyphBox, height: Self.glyphBox)
            } else {
                Circle()
                    .fill(colour)
                    .frame(width: Self.dotSize, height: Self.dotSize)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("VChip") {
    VStack(alignment: .leading, spacing: VTheme.Space.sm) {
        VChip(.onVideo) {
            VIdentityMark(colour: VTheme.Color.Ident.cyan, initial: "F")
            Text(verbatim: "Front Door")
        }
        VChip(.onVideo, restOpacity: 0.70) {
            VLiveDot(.live)
            Text("Live", bundle: .vigilUI)
        }
        VChip(.neutral) { Text(verbatim: "H.265") }
        VChip(.selected) { Text(verbatim: "Offline") }
    }
    .padding(VTheme.Space.xl)
    .background(VTheme.Color.Layer.videoWell)
}
#endif

#endif  // os(macOS)
