//
//  VSkeleton.swift
//  VigilUI
//
//  The loading placeholder and its shimmer sweep: a soft wide gradient travelling left to right,
//  which becomes a static block when motion is reduced.
//  macOS-only. Implements docs/DESIGN.md §7.6, §9.19, §7.10 rule 3.
//

#if os(macOS)

import SwiftUI

// MARK: - VSkeleton

/// A placeholder for content that has not arrived yet.
///
/// Sizes are always the **real** content's box, never a generic bar: a name skeleton is 90 × 11, a
/// subtitle 60 × 9, a thumbnail 40 × 22 (§9.19). That is what stops the layout from moving when the
/// content lands, which is the whole reason a skeleton beats a spinner.
///
/// Under reduced motion the sweep stops entirely and the base block remains — still saying "not
/// yet", with no movement (§7.10 rule 3).
///
/// **Driver count.** This view animates its own sweep, which is correct for the one or two
/// skeletons a single-camera screen shows. At grid scale §7.8 requires *one* driver for the whole
/// window, published as `\.vShimmerOffset`; the window root takes that over when the grid lands and
/// this view reads the environment value instead.
@MainActor
package struct VSkeleton: View {

    // MARK: - Geometry

    /// The sweep's travel in points, from §7.6. Wider than most skeletons on purpose: the gradient
    /// is soft and a short travel reads as a flicker rather than a sweep.
    package static let travel: CGFloat = 220

    /// The gradient's peak alpha, white α 0.075 at the centre of the band (§7.6).
    package static let peak: Double = 0.075

    /// The shoulders either side of the peak, α 0.055 (§7.6).
    package static let shoulder: Double = 0.055

    // MARK: - Stored Properties

    /// The corner radius of the block. 3 pt for text bars, the component's own radius for boxes.
    package let radius: CGFloat

    /// What sits under the sweep. `surfaceRaised` for a block placeholder; pass `.clear` to use
    /// the sweep alone, which is how the connecting tile draws its hairline along the well's
    /// bottom edge without putting a grey band over a true-black well (§7.6, §3.6).
    package let base: SwiftUI.Color

    @Environment(\.vMotionEnabled) private var motionEnabled
    @State private var offset: CGFloat = -1

    // MARK: - Initialisation

    /// Creates a skeleton block.
    ///
    /// - Parameters:
    ///   - radius: the corner radius of the block being stood in for.
    ///   - base: the fill beneath the sweep; `.clear` for a sweep-only hairline.
    package init(radius: CGFloat = VTheme.Radius.sm,
                 base: SwiftUI.Color = VTheme.Color.Layer.surfaceRaised) {
        self.radius = radius
        self.base = base
    }

    // MARK: - View

    package var body: some View {
        Rectangle()
            .fill(base)
            .overlay { sweep }
            .clipShape(VTheme.Radius.shape(radius))
            .onAppear {
                guard motionEnabled else { return }
                withAnimation(VTheme.Motion.shimmer) { offset = 1 }
            }
            .accessibilityLabel(Text("Loading", bundle: .vigilUI))
    }

    // MARK: - Private Helpers

    @ViewBuilder
    private var sweep: some View {
        if motionEnabled {
            LinearGradient(
                stops: [
                    Gradient.Stop(color: .clear, location: 0.00),
                    Gradient.Stop(color: .white.opacity(Self.shoulder), location: 0.45),
                    Gradient.Stop(color: .white.opacity(Self.peak), location: 0.50),
                    Gradient.Stop(color: .white.opacity(Self.shoulder), location: 0.55),
                    Gradient.Stop(color: .clear, location: 1.00),
                ],
                startPoint: .leading,
                endPoint: .trailing)
                // A wide, soft band: scaled about the leading edge so the travel below carries it
                // fully across even a narrow block.
                .scaleEffect(x: 2.2, anchor: .leading)
                .offset(x: offset * Self.travel)
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Previews

#if DEBUG && !VIGIL_NO_PREVIEWS
#Preview("VSkeleton") {
    VStack(alignment: .leading, spacing: VTheme.Space.xs) {
        VSkeleton(radius: VTheme.Radius.xs).frame(width: 90, height: 11)
        VSkeleton(radius: VTheme.Radius.xs).frame(width: 60, height: 9)
        VSkeleton(base: .clear).frame(height: 1)
    }
    .padding(VTheme.Space.xl)
    .background(VTheme.Color.Layer.canvas)
}
#endif

#endif  // os(macOS)
