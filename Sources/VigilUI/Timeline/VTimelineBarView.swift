//
//  VTimelineBarView.swift
//  VigilUI
//
//  One camera's lane on the archive scrubber: the recording band, the local-clip strip and the
//  event-marker row.
//  macOS-only. Implements docs/DESIGN.md §9.14 (lane anatomy) and docs/UX.md §7.3.
//
//  ⛔ NO TIME ARITHMETIC LIVES IN THIS FILE. Every position comes from `TimelineGeometry`, every
//  box from `TimelineBarLayout`, and every marker cluster from `TimelineMarkerLayout`. Those three
//  are tested to a standard a view cannot be, and re-deriving any of them here would produce a bar
//  whose paint disagrees with the click arithmetic — the "lands a second off" bug (see the header
//  of TimelineGeometry.swift).
//
//  WHY THE BAND IS A `Canvas` AND NOT A `ForEach` OF RECTANGLES. A two-hour window at motion
//  granularity is routinely a few hundred runs, and a busy 24 h day is a few thousand
//  (`RecordSearchQuery.hardSegmentCap` is 2 000 per track). One SwiftUI view per run would put
//  thousands of nodes through layout and diffing on every pan frame, against the 4 ms redraw budget
//  of docs/FEATURES.md §13. A `Canvas` is one view whose renderer walks an array — no identity, no
//  diffing, no layout. DESIGN.md §7.9 names the timeline heatmap as one of exactly two places
//  `.drawingGroup()` is permitted, and it is applied here. Markers stay real views, because after
//  clustering there are at most ~150 of them and each one has to be clickable and reachable by
//  VoiceOver.
//

#if os(macOS)

import Foundation
import SwiftUI

import VigilISAPI

// MARK: - VTimelineBarView

/// One camera's lane: header, density band, local-clip strip and marker row.
///
/// The lane draws no playhead and no ruler — both span every lane and are owned by
/// ``VTimelineView``, which composes this view once per camera.
@MainActor
package struct VTimelineBarView: View {

    // MARK: - Stored Properties

    /// The camera's footage, markers and clips.
    package let track: VTimelineTrack

    /// The pixel mapping for this lane. Every lane in a stack shares one, which is what keeps
    /// synchronised cameras aligned to the pixel.
    package let geometry: TimelineGeometry

    /// Whether this is the first camera, which gets the tall band, a header row and the marker row.
    /// Later cameras get the compact lane of UX.md §7.3.
    package let isPrimary: Bool

    /// Whether the day's search is still running. A not-yet-loaded range shimmers; it is never
    /// drawn as "no recording" (UX.md §7.4).
    package let isLoading: Bool

    /// Called when a marker or a *lone*-marker cluster is activated by click or by `Return`.
    ///
    /// ⚠️ Not called when a collapsed cluster's badge is clicked — that opens the list instead, and
    /// the callback then arrives once the user picks a row from it. A badge reading `40` that seeks
    /// straight to the first of the forty makes the other thirty-nine unreachable at that zoom.
    package let onActivateMarker: (TimelineMarkerCluster) -> Void

    /// The zone and hour cycle the expanded cluster's times are shown in.
    package let clock: TimelineClock

    /// The cluster whose list is open, by its identity.
    @State private var expanded: UUID?

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate

    // MARK: - Initialisation

    /// Creates a lane.
    package init(track: VTimelineTrack,
                 geometry: TimelineGeometry,
                 clock: TimelineClock,
                 isPrimary: Bool = true,
                 isLoading: Bool = false,
                 onActivateMarker: @escaping (TimelineMarkerCluster) -> Void = { _ in }) {
        self.track = track
        self.geometry = geometry
        self.clock = clock
        self.isPrimary = isPrimary
        self.isLoading = isLoading
        self.onActivateMarker = onActivateMarker
    }

    // MARK: - Geometry

    /// The total height of a lane, so ``VTimelineView`` can size the stack without measuring it.
    package static func height(isPrimary: Bool) -> CGFloat {
        guard isPrimary else { return VTheme.Metrics.timelineLaneHeight }
        return VTimelineMetrics.laneLabel + VTheme.Space.hair
            + VTimelineMetrics.band + VTheme.Space.hair
            + VTimelineMetrics.clipLane + VTheme.Space.hair
            + VTimelineMetrics.markerRow
    }

    /// The height of this lane's density band.
    package var bandHeight: CGFloat {
        isPrimary ? VTimelineMetrics.band : VTimelineMetrics.compactBand
    }

    /// The height of the band and the clip strip together — the `Canvas`'s box.
    package var stripHeight: CGFloat {
        bandHeight + VTheme.Space.hair + VTimelineMetrics.clipLane
    }

    // MARK: - View

    package var body: some View {
        VStack(alignment: .leading, spacing: VTheme.Space.hair) {
            if isPrimary {
                laneLabel
            }
            bandStrip
            if isPrimary {
                markerRow
            }
        }
        .frame(height: Self.height(isPrimary: isPrimary), alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Recording timeline for \(track.name)", bundle: .vigilUI))
    }

    // MARK: - Lane header

    /// The primary lane's header: identity mark and camera name.
    private var laneLabel: some View {
        HStack(spacing: VTheme.Space.xxs) {
            VIdentityMark(colour: VTheme.Color.Ident.colour(at: track.identityIndex),
                          initial: track.name.first)
            Text(verbatim: track.name)
                .vType(VTheme.Typography.callout)
                .foregroundStyle(VTheme.Color.Text.primary)
                .lineLimit(1)
        }
        .frame(height: VTimelineMetrics.laneLabel)
        .accessibilityHidden(true)
    }

    // MARK: - Band and clip strip

    /// The density band with the local-clip strip beneath it, and the compact lane's overlaid name.
    @ViewBuilder
    private var bandStrip: some View {
        Group {
            if isLoading {
                VSkeleton(radius: VTheme.Radius.xs, base: VTheme.Color.Layer.inset)
            } else if isPrimary, track.index.isEmpty {
                emptyBand
            } else {
                canvas
            }
        }
        .frame(height: stripHeight)
        .overlay(alignment: .topLeading) { compactLabel }
    }

    /// The compact lane's name, drawn over its band because UX.md §7.3 gives it no header row.
    @ViewBuilder
    private var compactLabel: some View {
        if !isPrimary {
            HStack(spacing: VTheme.Space.xxs) {
                VIdentityMark(colour: VTheme.Color.Ident.colour(at: track.identityIndex),
                              initial: track.name.first)
                Text(verbatim: track.name)
                    .vType(VTheme.Typography.caption1)
                    .foregroundStyle(VTheme.Color.Text.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, VTheme.Space.xxs)
            .padding(.top, VTheme.Space.hair)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// DESIGN.md §9.14's disabled state: a 4 pt bar and a centred reason, never an empty band that
    /// could be mistaken for one still loading.
    private var emptyBand: some View {
        ZStack {
            VTheme.Radius.shape(VTheme.Radius.xs)
                .fill(VTheme.Color.Stroke.subtle)
                .frame(height: VTimelineMetrics.emptyBar)
            Text("No recordings on this day", bundle: .vigilUI)
                .vType(VTheme.Typography.caption1)
                .foregroundStyle(VTheme.Color.Text.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    /// The band and clip strip in one `Canvas`. See the file header for why this is not a `ForEach`
    /// and why the renderer takes a pre-resolved paint.
    ///
    ///     init(opaque: Bool = false, colorMode: ColorRenderingMode = .nonLinear,
    ///          rendersAsynchronously: Bool = false,
    ///          renderer: @escaping (inout GraphicsContext, CGSize) -> Void)
    private var canvas: some View {
        let paint = bandPaint
        return Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: false) {
            context, _ in
            VTimelineBandRenderer.draw(paint, in: &context)
        }
        // DESIGN.md §7.9 permits `.drawingGroup()` on exactly two surfaces, and the timeline
        // heatmap is one of them: the band is a few thousand fills that never change between pans.
        .drawingGroup()
        .accessibilityHidden(true)
    }

    // MARK: - Paint

    /// Resolves the layout and every token into the value the renderer draws.
    private var bandPaint: VTimelineBandPaint {
        let layout = TimelineBarLayout.lay(out: track.index, in: geometry)
        let width = CGFloat(geometry.width)
        let band = CGRect(x: 0, y: 0, width: width, height: bandHeight)
        let clipTop = band.maxY + VTheme.Space.hair
        let clipWell = CGRect(x: 0, y: clipTop, width: width, height: VTimelineMetrics.clipLane)

        var boxes: [VTimelineBandPaint.Box] = []
        boxes.reserveCapacity(layout.runs.count)
        for run in layout.runs where run.width > 0 {
            let kind = VTimelineSegmentKind(run.recordType)
            let base = kind.colour
            boxes.append(VTimelineBandPaint.Box(
                rect: CGRect(x: CGFloat(run.x), y: band.minY,
                             width: CGFloat(run.width), height: band.height),
                fill: base.opacity(kind.fillOpacity),
                glow: run.isCompressed ? base : nil,
                hatch: kind.hatch))
        }

        let clipKind = VTimelineSegmentKind.localClip
        var clipBoxes: [CGRect] = []
        for clip in track.localClips
        where geometry.window.intersects(from: clip.start, to: clip.end) {
            let x = CGFloat(geometry.clampedX(at: clip.start))
            let maxX = CGFloat(geometry.clampedX(at: clip.end))
            // The same visibility floor the segment layout applies, so a two-second clip is not a
            // sub-pixel sliver at the 24 h zoom.
            let boxWidth = max(CGFloat(TimelineBarLayout.defaultMinimumWidth), maxX - x)
            clipBoxes.append(CGRect(x: x, y: clipWell.minY,
                                    width: boxWidth, height: clipWell.height))
        }

        return VTimelineBandPaint(
            well: band,
            wellRadius: VTheme.Radius.xs,
            wellFill: VTheme.Color.Layer.inset,
            boxes: boxes,
            gapSpans: layout.gapRuns.map { CGFloat($0.x)...CGFloat($0.maxX) },
            baselineY: band.maxY - VTheme.Border.thin,
            gapInk: VTheme.Color.Stroke.strong,
            gapDash: [VTheme.Space.hair, VTheme.Space.xxs],
            clipWell: clipWell,
            clipRadius: VTheme.Radius.full(VTimelineMetrics.clipLane),
            clipWellFill: VTheme.Color.Stroke.subtle,
            clipBoxes: clipBoxes,
            clipFill: clipKind.colour.opacity(clipKind.fillOpacity),
            hairline: VTheme.Border.thin,
            hatchInk: differentiate ? VTheme.Color.Text.inverse.opacity(0.45) : nil)
    }

    // MARK: - Markers

    /// The event and bookmark row, clustered by ``TimelineMarkerLayout`` so a busy afternoon stays
    /// countable and clickable.
    private var markerRow: some View {
        let clusters = TimelineMarkerLayout.lay(out: track.markers, in: geometry)
        return ZStack(alignment: .topLeading) {
            // A transparent filler so the row keeps its height with no markers on it at all.
            SwiftUI.Color.clear
            ForEach(clusters) { cluster in
                VTimelineMarkerGlyph(cluster: cluster) { activate(cluster) }
                    .popover(isPresented: isExpanded(cluster), arrowEdge: .bottom) {
                        VTimelineClusterList(cluster: cluster, clock: clock) { marker in
                            expanded = nil
                            // Rewrapped as a cluster of one so the callback's contract does not
                            // change: every caller of `onActivateMarker` seeks to `markers.first`,
                            // and handing it the chosen marker alone is what makes the row the user
                            // clicked the row they land on.
                            onActivateMarker(TimelineMarkerCluster(markers: [marker], x: cluster.x))
                        }
                    }
                    .position(x: CGFloat(cluster.x), y: VTimelineMetrics.markerRow / 2)
            }
        }
        .frame(height: VTimelineMetrics.markerRow)
    }

    /// A lone marker seeks; a collapsed cluster expands.
    private func activate(_ cluster: TimelineMarkerCluster) {
        if cluster.isCluster { expanded = cluster.id } else { onActivateMarker(cluster) }
    }

    /// A per-cluster presentation binding over the single `expanded` identity.
    ///
    /// One piece of state rather than one flag per cluster: the clusters are rebuilt on every zoom
    /// and pan, so anything stored per cluster would be discarded on the next redraw — and only one
    /// popover can be open at a time regardless.
    private func isExpanded(_ cluster: TimelineMarkerCluster) -> Binding<Bool> {
        Binding(get: { expanded == cluster.id },
                set: { isOpen in
                    if isOpen { expanded = cluster.id } else if expanded == cluster.id {
                        expanded = nil
                    }
                })
    }
}

// MARK: - VTimelineMarkerGlyph

/// One drawn item on the marker row: a diamond, a bookmark pennant, or a counted cluster badge.
///
/// A `Button` rather than a tappable shape so it is in the keyboard's path for free — an action a
/// mouse can reach must have a keyboard path (DESIGN.md P6).
@MainActor
package struct VTimelineMarkerGlyph: View {

    /// The cluster this glyph stands for.
    package let cluster: TimelineMarkerCluster

    /// Performed on click and on `Return`.
    package let action: () -> Void

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate

    /// Creates a glyph.
    package init(cluster: TimelineMarkerCluster, action: @escaping () -> Void) {
        self.cluster = cluster
        self.action = action
    }

    package var body: some View {
        Button(action: action) {
            glyph
                .frame(width: VTimelineMetrics.markerGrab, height: VTimelineMetrics.markerRow)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .focusEffectDisabled()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(Text(verbatim: String(cluster.count)))
    }

    /// The colour of the most severe member — the one the reviewer is looking for.
    private var tint: SwiftUI.Color {
        switch cluster.dominantKind {
        case .bookmark: VTheme.Color.Semantic.accent
        case .alarm: VTheme.Color.Semantic.live
        case .videoLoss: VTheme.Color.Semantic.danger
        case .tamper, .intrusion, .lineCrossing: VTheme.Color.Semantic.warn
        case .motion: VTheme.Color.Semantic.motion
        }
    }

    @ViewBuilder
    private var glyph: some View {
        if cluster.isCluster {
            clusterBadge
        } else if cluster.dominantKind.isPennant {
            VTimelinePennant(staffWidth: VTheme.Border.selected)
                .fill(tint)
                .frame(width: VTimelineMetrics.markerGlyph + VTheme.Space.hair,
                       height: VTimelineMetrics.markerRow - VTheme.Space.hair)
        } else {
            // A rotated near-square rather than a `Path`: the diamond is 6 pt, and a 1 pt corner
            // radius keeps it from reading as a spike at that size.
            VTheme.Radius.shape(VTheme.Border.thin)
                .fill(tint)
                .frame(width: VTimelineMetrics.markerGlyph, height: VTimelineMetrics.markerGlyph)
                .rotationEffect(.degrees(45))
        }
    }

    /// The counted badge a collapsed cluster shows (UX.md §7.3).
    private var clusterBadge: some View {
        Text(verbatim: String(cluster.count))
            .vType(VTheme.Typography.monoSmall.numeric)
            .foregroundStyle(VTheme.Color.Text.inverse)
            .padding(.horizontal, VTheme.Space.xxs)
            .frame(height: VTimelineMetrics.markerRow - VTheme.Space.hair)
            .background(tint, in: Capsule(style: .continuous))
            .overlay {
                if differentiate {
                    Capsule(style: .continuous)
                        .strokeBorder(VTheme.Color.Text.primary, lineWidth: VTheme.Border.thin)
                }
            }
    }

    /// Bookmarks name themselves; events speak the label the caller supplied.
    private var accessibilityLabel: Text {
        if cluster.isCluster {
            return Text("Events", bundle: .vigilUI)
        }
        if cluster.dominantKind.isPennant {
            return Text("Bookmark", bundle: .vigilUI)
        }
        return Text(verbatim: cluster.markers[0].label)
    }
}

// MARK: - VTimelinePennant

/// The bookmark's pennant: a vertical staff with a triangular flag at the top.
///
/// A shape rather than an SF Symbol because UX.md §7.3 asks for a silhouette distinguishable from a
/// diamond *by outline* — which is what makes bookmarks legible under `differentiateWithoutColor`
/// without a second layout.
///
/// `path(in:)` is `nonisolated` so the type can carry the module's mandatory `@MainActor` (R-40)
/// and still witness `Shape`'s non-isolated requirement, exactly as ``VStatusTriangle`` does. That
/// is also why the staff's width is stored rather than read from `VTheme` inside the path.
@MainActor
package struct VTimelinePennant: Shape {

    /// The width of the vertical staff, in points. Supplied by the call site because `VTheme` is
    /// `@MainActor` and ``path(in:)`` is not.
    package let staffWidth: CGFloat

    /// Creates a pennant.
    package init(staffWidth: CGFloat) {
        self.staffWidth = staffWidth
    }

    /// Draws the pennant inside `rect`. A degenerate rect yields an empty path rather than a
    /// negative-width flag.
    nonisolated package func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 0, rect.height > 0 else { return path }
        let staff = min(max(staffWidth, 0), rect.width)
        path.addRect(CGRect(x: rect.minX, y: rect.minY, width: staff, height: rect.height))
        path.move(to: CGPoint(x: rect.minX + staff, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height / 4))
        path.addLine(to: CGPoint(x: rect.minX + staff, y: rect.minY + rect.height / 2))
        path.closeSubpath()
        return path
    }
}

#endif  // os(macOS)
