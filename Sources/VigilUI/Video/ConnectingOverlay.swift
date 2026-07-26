//
//  ConnectingOverlay.swift
//  VigilUI
//
//  What a camera looks like before its first frame: true black, a ring, the real connection
//  narration — and, for the first quarter second, deliberately nothing at all.
//  macOS-only. Implements docs/UX.md §12.4 and §15.1, and DESIGN.md §7.6.
//

#if os(macOS)

import Foundation

import SwiftUI

// MARK: - ConnectingChoreography

/// The three thresholds that make a fast connection look like it was never a wait.
///
/// From UX.md §15.1, which is normative:
///
/// | Elapsed | What the user sees |
/// |---|---|
/// | 0–100 ms | The screen exists at its final size, true black, name chip in place. |
/// | 100–250 ms | Shimmer only. **No spinner, no text.** |
/// | 250–700 ms | The narration line appears, cross-fading between phrases. |
/// | 700 ms+ | Plus a `monospacedDigit` elapsed counter. |
/// | 3500 ms | Plus "This is taking longer than usual." and a way to diagnose it. |
///
/// The reason is measurable rather than aesthetic: on a LAN roughly 40 % of connections produce a
/// first frame before 250 ms, and text that appears and vanishes inside 150 ms reads as jank. A
/// connection that beats the first threshold therefore shows **no spinner and no narration at
/// all**, and — because the narration block's height is reserved — nothing moves when it does.
package enum ConnectingChoreography {

    /// Nothing is narrated before this (UX.md §15.1).
    package static let narrationDelay: Double = 0.250

    /// The elapsed counter joins the narration at this point.
    package static let elapsedDelay: Double = 0.700

    /// At this point we admit the truth, before the user concludes we are broken.
    package static let slowDelay: Double = 3.500

    /// Below this the first-frame handoff collapses into a single fast fade and no narration is
    /// ever shown — the fast path must look like "it was already on" (UX.md §15.2 step 6).
    package static let fastPath: Double = 0.400
}

// MARK: - ConnectingOverlay

/// The connecting state's overlay.
///
/// ⛔ Not a grey skeleton block: the well underneath is `#000000` and stays that way, because a
/// video well takes no tint, material or gradient in any state (DESIGN.md §3.6, §7.6). What moves
/// is a 1 pt shimmer along the bottom edge and a ring in the middle.
@MainActor
package struct ConnectingOverlay: View {

    /// The name and address to show.
    package let camera: LiveCameraIdentity

    /// The stage the connection has actually reached.
    package let phase: ConnectingPhase

    /// When this attempt began, for the elapsed counter.
    package let startedAt: Date

    /// True once 250 ms have passed.
    package let showsNarration: Bool

    /// True once 700 ms have passed.
    package let showsElapsed: Bool

    /// True once 3.5 s have passed.
    package let isSlow: Bool

    /// Runs the Stream Doctor from the slow row.
    package let onRunDoctor: () -> Void

    @Environment(\.vMotionEnabled) private var motionEnabled

    /// Creates the overlay.
    package init(camera: LiveCameraIdentity,
                 phase: ConnectingPhase,
                 startedAt: Date,
                 showsNarration: Bool,
                 showsElapsed: Bool,
                 isSlow: Bool,
                 onRunDoctor: @escaping () -> Void) {
        self.camera = camera
        self.phase = phase
        self.startedAt = startedAt
        self.showsNarration = showsNarration
        self.showsElapsed = showsElapsed
        self.isSlow = isSlow
        self.onRunDoctor = onRunDoctor
    }

    // MARK: - View

    package var body: some View {
        ZStack {
            centre
            shimmerEdge
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Connecting to \(camera.name)", bundle: .module))
    }

    // MARK: - Centre

    private var centre: some View {
        VStack(spacing: VTheme.Space.xs) {
            VProgressRing(progress: nil,
                          size: .large,
                          tint: VTheme.Color.Semantic.warn,
                          onVideo: true)
            Text(verbatim: camera.name)
                .vType(VTheme.Typography.title3)
                .foregroundStyle(VTheme.Color.Text.primary)
            narrationBlock
            if isSlow {
                slowRow
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The narration and the elapsed counter, in a box whose height is reserved from the first
    /// frame — so the ring above it does not jump when the first line appears at 250 ms.
    private var narrationBlock: some View {
        VStack(spacing: VTheme.Space.hair) {
            phase.narration(host: camera.host)
                .vType(VTheme.Typography.caption1)
                .foregroundStyle(VTheme.Color.Text.tertiary)
                .lineLimit(1)
                // §7.6: the narration changes phrase with an opacity content transition, so the
                // line reads as one thing being updated rather than as two things swapping.
                .contentTransition(.opacity)
                .opacity(showsNarration ? 1 : 0)
                .animation(VTheme.Motion.resolved(VTheme.Motion.fadeIn, reduced: !motionEnabled),
                           value: showsNarration)
                .animation(VTheme.Motion.resolved(VTheme.Motion.micro, reduced: !motionEnabled),
                           value: phase)
            elapsedLine
                .opacity(showsElapsed ? 1 : 0)
                .animation(VTheme.Motion.resolved(VTheme.Motion.fadeIn, reduced: !motionEnabled),
                           value: showsElapsed)
        }
        .frame(height: reservedNarrationHeight)
    }

    /// Two `Caption1` line boxes plus the 2 pt gap between them.
    private var reservedNarrationHeight: CGFloat {
        VTheme.Typography.caption1.lineHeight * 2 + VTheme.Space.hair
    }

    /// The elapsed counter.
    ///
    /// Driven by its own `TimelineView` so that a 10 Hz readout re-renders **one** `Text` and not
    /// the ring, the name or the well: a video layer's container must never be re-laid-out on a
    /// timer (DESIGN.md §7.9 rule 1).
    private var elapsedLine: some View {
        TimelineView(.periodic(from: startedAt, by: 0.1)) { context in
            elapsedText(at: context.date)
                .vType(VTheme.Typography.caption1Numeric)
                .foregroundStyle(VTheme.Color.Text.tertiary)
                // A reserved width, so 0.9 s → 1.0 s cannot nudge anything (§4.4).
                .vReserved(VTheme.Typography.Reserved.latency, alignment: .center)
        }
    }

    /// `1.4 s`.
    ///
    /// The **number** is formatted by `FormatStyle`, so the decimal separator is the locale's — a
    /// Russian reader sees `1,4` (UX.md §14.1 rule 9). The **unit** is part of the localised key
    /// rather than a `Measurement`, because `Measurement<UnitDuration>`'s `.abbreviated` width
    /// spells seconds `sec` and its `.narrow` width spells them `1.4s` with no space; UX.md §12.6
    /// specifies `1.4 s`, and neither width produces it. A translator moves or replaces the unit by
    /// editing this one key, which is the outcome §14.2 asks for anyway.
    private func elapsedText(at now: Date) -> Text {
        let seconds = Swift.max(0, now.timeIntervalSince(startedAt))
        let value = seconds.formatted(.number.precision(.fractionLength(1)))
        return Text("\(value) s", bundle: .module)
    }

    /// Shown at 3.5 s. This row does add height — deliberately, because at three and a half
    /// seconds a visible change is the point (UX.md §15.1).
    private var slowRow: some View {
        VStack(spacing: VTheme.Space.xxs) {
            Text("This is taking longer than usual.", bundle: .module)
                .vType(VTheme.Typography.caption1)
                .foregroundStyle(VTheme.Color.Text.secondary)
            VButton("Diagnose", style: .ghost, size: .sm) {
                onRunDoctor()
            }
        }
        .padding(.top, VTheme.Space.xs)
        .transition(.opacity)
    }

    // MARK: - Shimmer

    /// The 1 pt sweep along the bottom edge (§7.6). It is the only thing moving before 250 ms, and
    /// it is what makes the wait read as progress rather than as a stall.
    private var shimmerEdge: some View {
        VStack {
            Spacer(minLength: 0)
            VSkeleton(radius: 0, base: .clear)
                .frame(height: VTheme.Border.thin)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("ConnectingOverlay") {
    ConnectingOverlay(camera: LiveCameraIdentity(id: UUID(),
                                                 name: "Front Door",
                                                 host: "192.168.1.64"),
                      phase: .authenticating,
                      startedAt: Date.now,
                      showsNarration: true,
                      showsElapsed: true,
                      isSlow: false,
                      onRunDoctor: {})
        .frame(width: 640, height: 360)
        .background(VTheme.Color.Layer.videoWell)
        .vOnVideo()
}
#endif

#endif  // os(macOS)
