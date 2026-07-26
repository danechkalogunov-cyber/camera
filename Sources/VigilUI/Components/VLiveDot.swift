//
//  VLiveDot.swift
//  VigilUI
//
//  The "is this alive" indicator, and the single clock that keeps every one of them in unison.
//  macOS-only. Implements docs/DESIGN.md §7.5, §7.4 #10, §10.5, and UX.md §12.12.
//

#if os(macOS)

import SwiftUI

// MARK: - VPulseClock

/// The **one** driver behind every pulsing indicator in a window.
///
/// ⛔ Unison is not decoration: sixteen dots breathing on sixteen independent `PhaseAnimator`s is a
/// Christmas tree rather than a cockpit, and it also spends sixteen of the four animation drivers
/// the frame budget allows (DESIGN.md §7.5, §7.9). Every ``VLiveDot`` therefore reads
/// `\.vPulsePhase` and none of them owns a timer.
///
/// The phase is derived from the absolute clock rather than from an elapsed timer, so two clocks in
/// two windows — or a clock that is re-created by a redraw — still agree with each other.
///
/// Wrap the **chrome** in this, never a container that also owns a video layer: the schedule
/// re-evaluates the body once a second, and a video layer's container must not be re-laid-out on a
/// timer (§7.9 rule 1).
@MainActor
package struct VPulseClock<Content: View>: View {

    /// The half-period: the phase flips every 1.0 s, giving the designed 2 s breathe cycle.
    package static var interval: TimeInterval { 1.0 }

    private let content: () -> Content

    /// Wraps `content` in the pulse clock and publishes `\.vPulsePhase` to it.
    package init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    package var body: some View {
        TimelineView(.periodic(from: .now, by: Self.interval)) { context in
            content()
                .environment(\.vPulsePhase, Self.phase(at: context.date))
        }
    }

    /// `true` on odd whole seconds of the reference clock.
    ///
    /// Deriving it from `timeIntervalSinceReferenceDate` rather than from a counter is what makes
    /// two independently-created clocks agree, and what makes the phase survive a view rebuild.
    package static func phase(at date: Date) -> Bool {
        let seconds = date.timeIntervalSinceReferenceDate / interval
        return Int(seconds.rounded(.down)) % 2 != 0
    }
}

// MARK: - VLiveDot

/// The 6 pt status dot, in a 14 pt box.
///
/// Every "is this alive" indicator in the app is this component. It never announces itself to
/// VoiceOver — the row or tile that contains it says the state in words, and two announcements for
/// one fact is worse than none (§7.5, §10.3).
///
/// Under `differentiateWithoutColor` each state also changes **shape**, because a colour-blind or
/// monochrome-display operator must be able to read the state from geometry alone (§10.5).
@MainActor
package struct VLiveDot: View {

    // MARK: - Status

    /// The states a dot can show. A reduction of `StreamState`'s eleven cases to the five that have
    /// distinct dots (UX.md §12.12).
    package enum Status: Sendable, Hashable {

        /// Working towards a first frame. A spinning ring, not a pulse — motion is the cue, and it
        /// stays the cue under `differentiateWithoutColor` (§10.5).
        case connecting

        /// Media flowing, health nominal. A green filled circle, breathing in unison.
        case live

        /// Media flowing, health below threshold. Amber, and **static** — a degraded stream that
        /// also pulsed would read as healthier than a live one.
        case degraded

        /// No media: reconnecting, or waiting out a backoff. A hollow ring, never a filled dot.
        case offline

        /// The camera rejected our credentials. Red, and never retried automatically (§12.7).
        case authFailed

        /// The dot's colour, from the reserved status vocabulary (§3.2).
        ///
        /// `@MainActor` on the member rather than on `Status`: a nested type does not inherit its
        /// enclosing type's global actor, so this would otherwise be nonisolated and unable to read
        /// `VTheme.Color`. `Status` itself stays nonisolated, which is what lets the non-isolated
        /// ``LiveConnectionState/dot`` return one.
        @MainActor
        package var colour: SwiftUI.Color {
            switch self {
            case .connecting: return VTheme.Color.Semantic.warn
            case .live: return VTheme.Color.Semantic.ok
            case .degraded: return VTheme.Color.Semantic.warn
            case .offline: return VTheme.Color.Text.tertiary
            case .authFailed: return VTheme.Color.Semantic.danger
            }
        }

        /// Whether this state breathes with the pulse clock. Only ``live`` does.
        package var pulses: Bool {
            self == .live
        }
    }

    // MARK: - Geometry

    /// The dot itself: 6 pt (§5.3).
    package static let dotSize: CGFloat = 6

    /// The box the dot is centred in, so that dots align with 11–13 pt labels beside them (§7.5).
    package static let boxSize: CGFloat = 14

    /// The halo's peak scale and its starting alpha (§7.4 #10).
    package static let haloScale: CGFloat = 2.2

    /// See ``haloScale``.
    package static let haloAlpha: Double = 0.35

    // MARK: - Stored Properties

    /// The state to show.
    package let status: Status

    @Environment(\.vPulsePhase) private var phase
    @Environment(\.vMotionEnabled) private var motionEnabled
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate

    // MARK: - Initialisation

    /// Creates a status dot.
    package init(_ status: Status) {
        self.status = status
    }

    // MARK: - View

    package var body: some View {
        ZStack {
            if status == .connecting {
                VProgressRing(progress: nil, size: .small, tint: status.colour, onVideo: false)
                    .frame(width: Self.boxSize, height: Self.boxSize)
            } else {
                halo
                core
            }
        }
        .frame(width: Self.boxSize, height: Self.boxSize)
        .accessibilityHidden(true)
    }

    // MARK: - Private Helpers

    /// The expanding ring behind a live dot. Live only, and motion only — there is no static form,
    /// because the dot beneath it already carries the state (§7.10 rule 1).
    @ViewBuilder
    private var halo: some View {
        if status.pulses, motionEnabled {
            Circle()
                .fill(status.colour)
                .frame(width: Self.dotSize, height: Self.dotSize)
                .scaleEffect(phase ? Self.haloScale : 1.0)
                .opacity(phase ? 0 : Self.haloAlpha)
                .animation(VTheme.Motion.breathe, value: phase)
        }
    }

    @ViewBuilder
    private var core: some View {
        switch resolvedShape {
        case .circle:
            Circle()
                .fill(status.colour)
                .frame(width: Self.dotSize, height: Self.dotSize)
                .modifier(VDotBreath(active: status.pulses && motionEnabled, phase: phase))
        case .triangle:
            VStatusTriangle()
                .fill(status.colour)
                .frame(width: Self.dotSize, height: Self.dotSize)
        case .square:
            VTheme.Radius.shape(VTheme.Radius.xs / 2)
                .strokeBorder(status.colour, lineWidth: VTheme.Border.thin)
                .frame(width: Self.dotSize, height: Self.dotSize)
        case .hollowCircle:
            Circle()
                .strokeBorder(status.colour, lineWidth: VTheme.Border.thin)
                .frame(width: Self.dotSize, height: Self.dotSize)
        case .slashedCircle:
            Circle()
                .fill(status.colour)
                .frame(width: Self.dotSize, height: Self.dotSize)
                .overlay {
                    // Literal white, and correctly so: §10.5 specifies "a 1.5 pt white slash", and
                    // it must read against `danger` in **both** appearances, which no ink token
                    // does — `Text.inverse` is near-black in dark.
                    Capsule()
                        .fill(SwiftUI.Color.white)
                        .frame(width: Self.dotSize + 1, height: VTheme.Border.ring)
                        .rotationEffect(.degrees(-45))
                }
        }
    }

    /// The five geometries of §10.5's status-dot rows.
    private enum DotShape {
        case circle, triangle, square, hollowCircle, slashedCircle
    }

    private var resolvedShape: DotShape {
        switch status {
        case .connecting, .live:
            return .circle
        case .degraded:
            return differentiate ? .triangle : .circle
        case .offline:
            return differentiate ? .square : .hollowCircle
        case .authFailed:
            return differentiate ? .slashedCircle : .circle
        }
    }
}

// MARK: - VDotBreath

/// The dot's own breath: scale 1.0 ↔ 1.18 and opacity 1.0 ↔ 0.55, on the shared phase (§7.4 #10).
///
/// A modifier rather than two inline modifiers so that the "static when motion is reduced" rule is
/// expressed once: under reduced motion the dot sits at full scale and full opacity — it never
/// disappears, because a pulse becomes a static dot and never nothing (§7.10 rule 1).
@MainActor
package struct VDotBreath: ViewModifier {

    /// Whether the pulse is running.
    package let active: Bool

    /// The shared pulse phase.
    package let phase: Bool

    package func body(content: Content) -> some View {
        content
            .scaleEffect(active && phase ? 1.18 : 1.0)
            .opacity(active && phase ? 0.55 : 1.0)
            .animation(active ? VTheme.Motion.breathe : nil, value: phase)
    }
}

// MARK: - VStatusTriangle

/// A 6 pt apex-up triangle: the `differentiateWithoutColor` form of the degraded dot (§10.5).
///
/// `path(in:)` is `nonisolated` so the type can carry the module's mandatory `@MainActor` (R-40)
/// and still witness `Shape`'s non-isolated requirement.
@MainActor
package struct VStatusTriangle: Shape {

    package init() {}

    nonisolated package func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Previews

#if DEBUG
#Preview("VLiveDot") {
    VPulseClock {
        HStack(spacing: VTheme.Space.md) {
            VLiveDot(.connecting)
            VLiveDot(.live)
            VLiveDot(.degraded)
            VLiveDot(.offline)
            VLiveDot(.authFailed)
        }
    }
    .padding(VTheme.Space.xl)
    .background(VTheme.Color.Layer.canvas)
}
#endif

#endif  // os(macOS)
