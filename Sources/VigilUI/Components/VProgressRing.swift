//
//  VProgressRing.swift
//  VigilUI
//
//  The only progress indicator in Vigil: a trimmed ring, determinate when we know the fraction and
//  spinning when we do not. Replaces `ProgressView()`, which is never used.
//  macOS-only. Implements docs/DESIGN.md §9.27, §7.1 (`motion.spin`), §7.10 rule 3.
//

#if os(macOS)

import SwiftUI

// MARK: - VProgressRing

/// A circular progress indicator in three sizes.
///
/// Determinate whenever a fraction is available — a reconnect countdown, an export — and
/// indeterminate only when there is genuinely nothing to count. ⛔ `ProgressView()` is never used
/// (DESIGN.md §12.4): its metrics, colour and animation are not ours.
///
/// Under reduced motion an indeterminate ring stops rotating and becomes a static quarter arc; the
/// caller is then obliged to keep a text narration beside it, because a stopped ring alone cannot
/// say "still working" (§7.10 rule 3).
@MainActor
package struct VProgressRing: View {

    // MARK: - Size

    /// The three ring sizes from §9.27, each with the line width designed for it.
    package enum Size {

        /// 13 pt, 1.5 pt line. Inside a button, a text field's trailing edge, a table cell.
        case small

        /// 22 pt, 2 pt line. Inline beside a `Body` label.
        case medium

        /// 32 pt, 2.5 pt line. The connecting ring at the centre of a tile.
        case large

        /// The ring's diameter in points.
        ///
        /// `@MainActor` on the member, not on `Size`: a nested type does not inherit its enclosing
        /// type's global actor, so this accessor would otherwise be nonisolated and could not read
        /// `VTheme.Icon`.
        @MainActor
        package var diameter: CGFloat {
            switch self {
            case .small: return VTheme.Icon.md
            case .medium: return 22
            case .large: return VTheme.Icon.hero
            }
        }

        /// The stroke width designed for this diameter. See ``diameter`` for the `@MainActor`.
        @MainActor
        package var lineWidth: CGFloat {
            switch self {
            case .small: return VTheme.Border.ring
            case .medium: return VTheme.Border.focus
            case .large: return 2.5
            }
        }
    }

    // MARK: - Stored Properties

    /// `0…1` for a determinate ring, `nil` for an indeterminate one.
    package let progress: Double?

    /// One of the three sizes in §9.27.
    package let size: Size

    /// The arc's colour. Defaults to `accent`; pass the semantic colour of the operation when the
    /// ring reports something with a status meaning of its own.
    package let tint: SwiftUI.Color

    /// The unfilled track. `Stroke.default` on chrome, `Stroke.onVideo` over a video well, where
    /// α 0.10 on `#000000` is invisible (§3.3).
    package let track: SwiftUI.Color

    @Environment(\.vMotionEnabled) private var motionEnabled
    @State private var isSpinning = false

    // MARK: - Initialisation

    /// Creates a ring.
    ///
    /// - Parameters:
    ///   - progress: the fraction complete, clamped to `0…1`. Pass `nil` when the duration is
    ///     genuinely unknown — a determinate ring is always preferred (UX.md §12.3).
    ///   - size: one of the three sizes in §9.27.
    ///   - tint: the arc colour; `accent` by default.
    ///   - onVideo: whether the ring sits on a video well, which selects the track colour.
    package init(progress: Double? = nil,
                 size: Size = .medium,
                 tint: SwiftUI.Color = VTheme.Color.Semantic.accent,
                 onVideo: Bool = false) {
        self.progress = progress.map { Swift.min(Swift.max($0, 0), 1) }
        self.size = size
        self.tint = tint
        self.track = onVideo ? VTheme.Color.Stroke.onVideo : VTheme.Color.Stroke.default
    }

    // MARK: - View

    package var body: some View {
        ZStack {
            Circle()
                .strokeBorder(track, lineWidth: size.lineWidth)
            Circle()
                .inset(by: size.lineWidth / 2)
                .trim(from: 0, to: arcLength)
                .stroke(tint, style: StrokeStyle(lineWidth: size.lineWidth, lineCap: .round))
                .rotationEffect(.degrees(rotation))
        }
        .frame(width: size.diameter, height: size.diameter)
        .onAppear {
            guard isIndeterminate, motionEnabled else { return }
            withAnimation(VTheme.Motion.spin) { isSpinning = true }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Private Helpers

    private var isIndeterminate: Bool {
        progress == nil
    }

    /// A determinate ring shows its fraction. An indeterminate one shows a quarter arc, which is
    /// also exactly what §7.10 rule 3 asks it to freeze at when motion is reduced.
    private var arcLength: Double {
        progress ?? 0.25
    }

    /// −90° puts the start of the arc at twelve o'clock; the spin adds a full turn on top.
    private var rotation: Double {
        let start = -90.0
        guard isIndeterminate, motionEnabled else { return start }
        return start + (isSpinning ? 360 : 0)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("VProgressRing") {
    HStack(spacing: VTheme.Space.lg) {
        VProgressRing(size: .small)
        VProgressRing(size: .medium)
        VProgressRing(progress: 0.35, size: .large)
        VProgressRing(progress: 0.7, size: .medium, tint: VTheme.Color.Semantic.warn)
    }
    .padding(VTheme.Space.xl)
    .background(VTheme.Color.Layer.canvas)
}
#endif

#endif  // os(macOS)
