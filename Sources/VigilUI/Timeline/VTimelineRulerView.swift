//
//  VTimelineRulerView.swift
//  VigilUI
//
//  The three pieces of chrome that span every lane rather than belonging to one: the hour ruler,
//  the playhead with its timecode bubble, and the scrub preview card.
//  macOS-only. Implements docs/DESIGN.md §9.14 and docs/UX.md §7.3.
//

#if os(macOS)

import Foundation
import SwiftUI

// MARK: - VTimelineRulerView

/// The tick marks and labels above the first lane.
///
/// Ticks are drawn in a `Canvas` — there are up to a few hundred and none of them is interactive —
/// while the labels stay real `Text` views so they honour `monospacedDigit`, the interface text
/// scale and VoiceOver. Only the labelled ticks get a view, which is at most a couple of dozen.
@MainActor
package struct VTimelineRulerView: View {

    /// The pixel mapping.
    package let geometry: TimelineGeometry

    /// The day every tick is stepped from — never the window's edge, or the labels would be
    /// meaningless numbers (see the header of TimelineRuler.swift).
    package let day: TimelineDay

    /// The stop, which chooses the two intervals and the label format.
    package let zoom: TimelineZoom

    /// The calendar the labels are rendered in.
    package let clock: TimelineClock

    /// Whether the pointer is over the timeline, which lifts the labels from α 0.7 to 1
    /// (DESIGN.md §9.14, hover row).
    package let isHovering: Bool

    /// Creates a ruler.
    package init(geometry: TimelineGeometry,
                 day: TimelineDay,
                 zoom: TimelineZoom,
                 clock: TimelineClock,
                 isHovering: Bool = false) {
        self.geometry = geometry
        self.day = day
        self.zoom = zoom
        self.clock = clock
        self.isHovering = isHovering
    }

    package var body: some View {
        let ticks = TimelineRuler.ticks(in: geometry, day: day, zoom: zoom, clock: clock)
        let marks = tickMarks(ticks)
        return ZStack(alignment: .topLeading) {
            // The renderer carries no isolation, so it draws pre-resolved rectangles and never
            // reads a `@MainActor` token — the same arrangement `VTimelineBandRenderer` uses.
            Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: false) {
                context, _ in
                for mark in marks {
                    context.fill(Path(mark.rect), with: .color(mark.ink))
                }
            }
            ForEach(ticks.filter(\.isMajor)) { tick in
                Text(verbatim: tick.label ?? "")
                    .vType(VTheme.Typography.monoSmall.numeric)
                    .foregroundStyle(VTheme.Color.Text.tertiary)
                    .fixedSize()
                    .position(x: CGFloat(tick.x),
                              y: VTheme.Typography.monoSmall.lineHeight / 2)
            }
        }
        .frame(height: VTimelineMetrics.ruler)
        .opacity(isHovering ? 1 : 0.7)
        .clipped()
        .accessibilityHidden(true)
    }

    /// Major ticks are 1 × 6 pt at `stroke.strong`, minors 1 × 3 pt at `stroke.default`, both
    /// hanging from the band's bottom edge (DESIGN.md §9.14).
    ///
    /// Drawn as filled 1 pt rectangles rather than as strokes so no half-point straddles a device
    /// pixel and turns a hairline into a two-pixel smudge.
    private func tickMarks(_ ticks: [TimelineTick]) -> [VTimelineTickMark] {
        let height = VTimelineMetrics.ruler
        return ticks.map { tick in
            let length = tick.isMajor ? VTimelineMetrics.majorTick : VTimelineMetrics.minorTick
            return VTimelineTickMark(
                rect: CGRect(x: CGFloat(tick.x), y: height - length,
                             width: VTheme.Border.thin, height: length),
                ink: tick.isMajor ? VTheme.Color.Stroke.strong : VTheme.Color.Stroke.default)
        }
    }
}

// MARK: - VTimelineTickMark

/// One ruler tick, resolved to a rectangle and an ink before the `Canvas` runs.
struct VTimelineTickMark {
    let rect: CGRect
    let ink: SwiftUI.Color
}

// MARK: - VTimelinePlayheadView

/// The playhead: a 2 pt line through every lane with the timecode bubble above it.
///
/// ⚠️ **Accent, not `text.primary`.** DESIGN.md §9.14 specifies a `text.primary` line with a
/// circular cap; UX.md §7.3 and the approved mockup both specify a 2 pt `accent` line with a
/// rounded `HH:mm:ss.SS` label above. UX.md is the authoritative side for structural decisions
/// (R-34) and the mockup agrees with it, so the accent form is drawn — with DESIGN's 1 pt dark
/// outline kept, because that is what makes the line survive over an amber or red band.
@MainActor
package struct VTimelinePlayheadView: View {

    /// Where the playhead is. Exactly what the user asked for, even in a gap — see the ruling at
    /// the top of TimelineSeek.swift.
    ///
    /// The view draws no `x` of its own: the owner positions it, because the same
    /// ``TimelineGeometry`` has to place the playhead, the hover cursor and every lane, and two
    /// call sites resolving it separately is how they drift apart.
    package let instant: Date

    /// The clock the bubble's timecode is formatted with.
    package let clock: TimelineClock

    /// The height of the lane stack the line runs through, bubble included.
    package let height: CGFloat

    /// Whether a scrub is in flight, which pops the bubble (DESIGN.md §9.14, pressed row).
    package let isScrubbing: Bool

    @Environment(\.vMotionEnabled) private var motionEnabled

    /// Creates a playhead.
    package init(instant: Date,
                 clock: TimelineClock,
                 height: CGFloat,
                 isScrubbing: Bool = false) {
        self.instant = instant
        self.clock = clock
        self.height = height
        self.isScrubbing = isScrubbing
    }

    package var body: some View {
        VStack(spacing: 0) {
            bubble
            line
        }
        .frame(height: height, alignment: .top)
        .fixedSize(horizontal: true, vertical: false)
        .allowsHitTesting(false)
    }

    /// The line, with the dark outline DESIGN.md §9.14 asks for drawn as a slightly wider rectangle
    /// behind it rather than as a stroke, which on a 2 pt bar would consume the whole width.
    private var line: some View {
        ZStack {
            Rectangle()
                .fill(VTheme.Color.Scrim.base)
                .frame(width: VTimelineMetrics.playhead + VTheme.Border.thin * 2)
            Rectangle()
                .fill(VTheme.Color.Semantic.accent)
                .frame(width: VTimelineMetrics.playhead)
        }
        .frame(maxHeight: .infinity)
    }

    /// `10:14:38.20`, in the reserved timecode width so the bubble cannot change size as the
    /// centiseconds run (DESIGN.md §4.4).
    private var bubble: some View {
        Text(verbatim: clock.timecode(instant))
            .vType(VTheme.Typography.monoSmall.numeric)
            // DESIGN.md §3.2: white on `accentFill` measures 5.86:1. The token set has no
            // pure-white ink — `text.inverse` flips with the appearance — so the one colour the
            // specification names for this fill is written out here.
            .foregroundStyle(SwiftUI.Color.white)
            .lineLimit(1)
            .padding(.horizontal, VTheme.Space.xs)
            .frame(height: VTimelineMetrics.bubble)
            .background(VTheme.Color.Semantic.accentFill,
                        in: VTheme.Radius.shape(VTheme.Radius.full(VTimelineMetrics.bubble)))
            .scaleEffect(isScrubbing ? 1.08 : 1.0)
            .animation(VTheme.Motion.resolved(VTheme.Motion.snap, reduced: !motionEnabled),
                       value: isScrubbing)
            .accessibilityHidden(true)
    }
}

#endif  // os(macOS)
