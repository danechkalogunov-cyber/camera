//
//  VTimelineBarView.swift
//  VigilUI
//
//  One camera's lane on the archive scrubber: the recording band, the local-clip strip and the
//  event-marker row, plus the lane geometry every other timeline file measures itself against.
//  macOS-only. Implements docs/DESIGN.md §9.14 (lane anatomy and heatmap encoding), §10.5 (the
//  hatch that carries recording type without colour) and docs/UX.md §7.3.
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
//  diffing, no layout. Markers stay real views, because there are at most ~150 of them after
//  clustering and each one has to be clickable and reachable by VoiceOver.
//

#if os(macOS)

import SwiftUI

import VigilISAPI

// MARK: - VTimelineSegmentKind

/// What a painted box on the bar stands for, and therefore what colour it takes.
///
/// A view-layer enum rather than `RecordType` itself, for three reasons: the bar has two kinds that
/// are not record types at all (``noRecording`` and ``localClip``), the five legend keys of the
/// approved mockup are exactly these five cases, and the mapping from the six wire record types down
/// to three drawn colours is a presentation decision that belongs here rather than in `VigilISAPI`.
package enum VTimelineSegmentKind: Int, Sendable, Hashable, CaseIterable {

    /// Scheduled or operator-initiated recording. `continuous` blue.
    case continuous

    /// A motion recording. `motion` amber.
    case motion

    /// An alarm recording. `live` red.
    case alarm

    /// A clip Vigil itself recorded to disk, drawn on its own 6 pt strip in `accent`.
    case localClip

    /// A stretch with no footage. Not a colour so much as the absence of one — the track's own E0
    /// fill with a dotted baseline, so "nothing was recorded" is visibly different from "not yet
    /// loaded", which shimmers (docs/UX.md §7.3).
    case noRecording

    /// The kind a device record type is drawn as.
    ///
    /// `timing`, `manual`, `command` and `other` all collapse onto ``continuous``. That is
    /// deliberate: DESIGN.md §9.14 names exactly three band colours, and inventing two more for
    /// "the operator pressed record" and "a CGI call started it" would spend the reserved status
    /// vocabulary (§3.1) on a distinction no reviewer is looking for. `other` — an unrecognised
    /// wire value — is drawn as ordinary footage rather than as a fourth colour, because the one
    /// thing it certainly is, is footage.
    package init(_ recordType: RecordType) {
        switch recordType {
        case .alarm: self = .alarm
        case .motion: self = .motion
        case .timing, .manual, .command, .other: self = .continuous
        }
    }

    /// The order the legend prints, which is the mockup's order: the three band colours, then the
    /// absence, then the local strip.
    package static let legendOrder: [VTimelineSegmentKind] =
        [.continuous, .motion, .alarm, .noRecording, .localClip]

    /// The base token. Alpha is applied separately — see ``fillOpacity``.
    ///
    /// `@MainActor` because `VTheme` is; the enum itself stays a plain `Sendable` value so the
    /// mapping above can be asserted by a test without an actor hop.
    @MainActor
    package var colour: SwiftUI.Color {
        switch self {
        case .continuous: VTheme.Color.Semantic.continuous
        case .motion: VTheme.Color.Semantic.motion
        case .alarm: VTheme.Color.Semantic.live
        case .localClip: VTheme.Color.Semantic.accent
        case .noRecording: VTheme.Color.Layer.surfaceRaised
        }
    }

    /// The alpha DESIGN.md §9.14 gives this kind in the density band.
    ///
    /// The specification writes the band's opacity as `0.55 + 0.45 × coverage`, where coverage is
    /// the recorded fraction of one pixel column. `TimelineBarLayout` deliberately does not expose a
    /// per-column coverage — it emits exact runs and guarantees a 2 pt minimum instead, which is the
    /// stronger property — so the drawn alpha is the per-kind constant from the same table
    /// (continuous 0.55, motion 0.75, alarm 0.90). Severity therefore still reads off the bar at a
    /// glance, which is what the ramp was for.
    package var fillOpacity: Double {
        switch self {
        case .continuous: 0.55
        case .motion: 0.75
        case .alarm: 0.90
        case .localClip: 0.90
        case .noRecording: 1.00
        }
    }

    /// The pattern added under `accessibilityDifferentiateWithoutColor` (DESIGN.md §10.5).
    package var hatch: VTimelineHatch {
        switch self {
        case .motion: .diagonal
        case .alarm: .cross
        case .continuous, .localClip, .noRecording: .none
        }
    }
}

// MARK: - VTimelineHatch

/// The non-colour partner for a band colour (DESIGN.md §10.5).
///
/// Motion is a 45° hatch at a 4 pt pitch and alarm a cross-hatch at 3 pt; continuous is the
/// unhatched baseline, so the three are told apart by geometry alone.
package enum VTimelineHatch: Sendable, Hashable {

    /// No pattern — the continuous baseline.
    case none

    /// 45° lines.
    case diagonal

    /// 45° lines in both directions.
    case cross

    /// The distance between lines, in points. Zero for ``none``, which is what stops the renderer
    /// from looping.
    package var pitch: CGFloat {
        switch self {
        case .none: 0
        case .diagonal: 4
        case .cross: 3
        }
    }
}

// MARK: - VTimelineMetrics

/// The archive timeline's own geometry.
///
/// `VTheme` publishes the two numbers DESIGN.md §5.1 gives the component as a whole
/// (``VTheme/Metrics/timelineHeight`` and ``VTheme/Metrics/timelineLaneHeight``) but not the band
/// heights inside a lane, which live in §9.14 and UX.md §7.3. This namespace is where those live,
/// exactly once, each derived from a spacing token where one is an exact match and each carrying the
/// clause it comes from where it is not — the same arrangement `VChip.height`, `VIdentityMark.dotSize`
/// and `VSkeleton.travel` already use for their own component's dimensions.
@MainActor
package enum VTimelineMetrics {

    /// The ruler band: one `MonoSmall` line box for the labels above a 6 pt major tick.
    ///
    /// DESIGN.md §9.14 says 16 pt. 16 does not fit a 13 pt line box and a 6 pt tick without the
    /// label sitting on top of the tick, so the band is the sum of the two it actually contains.
    package static let ruler: CGFloat = VTheme.Typography.monoSmall.lineHeight + VTheme.Space.xs

    /// The lane's own label row (UX.md §7.3: 12 pt).
    package static let laneLabel: CGFloat = VTheme.Space.md

    /// The density band of the first camera's lane (UX.md §7.3: 28 pt).
    package static let band: CGFloat = VTheme.Metrics.md

    /// The density band of every camera after the first (UX.md §7.3: 20 pt).
    package static let compactBand: CGFloat = VTheme.Metrics.xs

    /// The local-clip strip (UX.md §7.3: 6 pt).
    package static let clipLane: CGFloat = VTheme.Space.xs

    /// The event-marker row (UX.md §7.3: 12 pt).
    package static let markerRow: CGFloat = VTheme.Space.md

    /// A labelled tick: 1 × 6 pt (DESIGN.md §9.14).
    package static let majorTick: CGFloat = VTheme.Space.xs

    /// An unlabelled tick: 1 × 3 pt (DESIGN.md §9.14).
    package static let minorTick: CGFloat = VTheme.Space.hair + VTheme.Border.thin

    /// A marker diamond's side (UX.md §7.3: 6 pt), matching the identity dot so a lane's marks and
    /// its header dot are the same size.
    package static let markerGlyph: CGFloat = VIdentityMark.dotSize

    /// The grab width of a marker: 12 pt, per DESIGN.md §10.6's "timeline handles 4 pt visual,
    /// 12 pt grab area". Wider would make two adjacent clusters fight for the same pointer.
    package static let markerGrab: CGFloat = VTheme.Space.md

    /// The playhead's drawn width (UX.md §7.3: 2 pt).
    package static let playhead: CGFloat = VTheme.Border.selected

    /// The playhead's grab width (DESIGN.md §10.6: 16 pt).
    package static let playheadGrab: CGFloat = VTheme.Space.lg

    /// The timecode bubble above the playhead (UX.md §7.3: a 22 pt rounded label; the 20 pt `xs`
    /// control height is the token that carries a `MonoLarge` line box and is used instead).
    package static let bubble: CGFloat = VTheme.Metrics.xs

    /// The scrub preview card (UX.md §7.3: 176 pt wide, a 160 × 90 thumbnail inside it).
    package static let previewWidth: CGFloat = 176

    /// See ``previewWidth``.
    package static let previewThumbnailHeight: CGFloat = 90

    /// How far above the pointer the preview card floats (UX.md §7.3: 12 pt).
    package static let previewGap: CGFloat = VTheme.Space.md

    /// The legend swatch, matching ``VIdentityMark/glyphBox`` so the legend and a lane header line
    /// up on the same 9 pt optical row.
    package static let legendSwatch: CGFloat = VIdentityMark.glyphBox

    /// The bar the disabled state shows in place of the band (DESIGN.md §9.14: 4 pt).
    package static let emptyBar: CGFloat = VTheme.Space.xxs
}

// MARK: - VTimelineLocalClip

/// A clip Vigil recorded to local disk, drawn on the lane's own 6 pt strip.
///
/// A view-layer value rather than a `VigilCore` model: the strip needs a span, an identity and a
/// name for VoiceOver and nothing else, and keeping it to those three means the timeline can be
/// previewed and tested without the clip store.
package struct VTimelineLocalClip: Identifiable, Sendable, Hashable {

    /// The clip's own identity.
    package let id: UUID

    /// When recording started.
    package let start: Date

    /// When it stopped. Clamped to be no earlier than ``start``.
    package let end: Date

    /// The file's display name, for VoiceOver.
    package let title: String

    /// Creates a clip. An `end` before `start` is clamped up, so no negative-width box can reach
    /// the renderer.
    package init(id: UUID, start: Date, end: Date, title: String) {
        self.id = id
        self.start = start
        self.end = max(start, end)
        self.title = title
    }
}

// MARK: - VTimelineTrack

/// Everything one camera contributes to the scrubber.
///
/// Not `Equatable`: it carries a ``TimelineSegmentIndex``, which holds the day's segments and is
/// deliberately only `Sendable` — comparing a few thousand segments on every body evaluation would
/// cost more than the redraw it was meant to avoid.
package struct VTimelineTrack: Identifiable, Sendable {

    /// The camera's id, which is also the lane's `ForEach` identity.
    package let id: UUID

    /// The camera's name, shown in the lane header and spoken before the timeline's value.
    package let name: String

    /// The camera's identity-colour index (DESIGN.md §3.4), resolved through
    /// ``VTheme/Color/Ident/colour(at:)``. Stored as an index so this value needs no main actor.
    package let identityIndex: Int

    /// The day's footage, already clipped to the day and gapped.
    package let index: TimelineSegmentIndex

    /// The event and bookmark markers for this camera, in any order.
    package let markers: [TimelineMarker]

    /// Vigil's own clips for this camera, in any order.
    package let localClips: [VTimelineLocalClip]

    /// Creates a track.
    package init(id: UUID,
                 name: String,
                 identityIndex: Int,
                 index: TimelineSegmentIndex,
                 markers: [TimelineMarker] = [],
                 localClips: [VTimelineLocalClip] = []) {
        self.id = id
        self.name = name
        self.identityIndex = identityIndex
        self.index = index
        self.markers = markers
        self.localClips = localClips
    }
}

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

    /// Called when a marker or cluster is activated by click or by `Return`.
    package let onActivateMarker: (TimelineMarkerCluster) -> Void

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate

    // MARK: - Initialisation

    /// Creates a lane.
    package init(track: VTimelineTrack,
                 geometry: TimelineGeometry,
                 isPrimary: Bool = true,
                 isLoading: Bool = false,
                 onActivateMarker: @escaping (TimelineMarkerCluster) -> Void = { _ in }) {
        self.track = track
        self.geometry = geometry
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
        let stripHeight = bandHeight + VTheme.Space.hair + VTimelineMetrics.clipLane
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

    /// The band and clip strip in one `Canvas`. See the file header for why this is not a `ForEach`.
    ///
    ///     init(opaque: Bool = false, colorMode: ColorRenderingMode = .nonLinear,
    ///          rendersAsynchronously: Bool = false,
    ///          renderer: @escaping (inout GraphicsContext, CGSize) -> Void)
    private var canvas: some View {
        let layout = TimelineBarLayout.lay(out: track.index, in: geometry)
        return Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: false) {
            context, size in
            draw(layout: layout, in: &context, size: size)
        }
        .drawingGroup()
        .accessibilityHidden(true)
    }

    // MARK: - Drawing

    /// Paints the band, then the clip strip. Ordered back to front: track well, gaps, runs, hatch.
    private func draw(layout: TimelineBarLayout, in context: inout GraphicsContext, size: CGSize) {
        let band = CGRect(x: 0, y: 0, width: size.width, height: min(bandHeight, size.height))
        drawBand(layout: layout, in: &context, band: band)
        let clipTop = band.maxY + VTheme.Space.hair
        guard size.height - clipTop > 0 else { return }
        let strip = CGRect(x: 0, y: clipTop, width: size.width, height: size.height - clipTop)
        drawClips(in: &context, strip: strip)
    }

    /// The density band.
    ///
    ///     func fill(_ path: Path, with shading: GraphicsContext.Shading, style: FillStyle)
    ///     static func color(_ color: Color) -> GraphicsContext.Shading
    private func drawBand(layout: TimelineBarLayout,
                          in context: inout GraphicsContext,
                          band: CGRect) {
        let well = Path(roundedRect: band, cornerRadius: VTheme.Radius.xs, style: .continuous)
        context.fill(well, with: .color(VTheme.Color.Layer.inset))

        // Gaps first: their dotted baseline sits under any run that widened into them, which is the
        // visual counterpart of TimelineBarLayout's promise that a drawn gap keeps uncovered width.
        for gap in layout.gapRuns {
            var line = Path()
            let y = band.maxY - VTheme.Border.thin
            line.move(to: CGPoint(x: gap.x, y: y))
            line.addLine(to: CGPoint(x: gap.maxX, y: y))
            context.stroke(line,
                           with: .color(VTheme.Color.Stroke.strong),
                           style: StrokeStyle(lineWidth: VTheme.Border.thin,
                                              dash: [VTheme.Space.hair, VTheme.Space.xxs]))
        }

        for run in layout.runs {
            let kind = VTimelineSegmentKind(run.recordType)
            let rect = CGRect(x: run.x, y: band.minY, width: run.width, height: band.height)
            let path = Path(rect)
            context.fill(path, with: .color(kind.colour.opacity(kind.fillOpacity)))
            if run.isCompressed {
                // UX.md §7.3: a run that could not reach the minimum width bleeds a 1 pt outer glow
                // rather than being moved, so it is visible without lying about where it starts.
                let glow = Path(rect.insetBy(dx: -VTheme.Border.thin, dy: 0))
                context.stroke(glow, with: .color(kind.colour), lineWidth: VTheme.Border.thin)
            }
            if differentiate {
                drawHatch(kind.hatch, in: &context, rect: rect)
            }
        }
    }

    /// The 45° hatch that carries recording type without colour (DESIGN.md §10.5).
    ///
    ///     func drawLayer(content: (inout GraphicsContext) throws -> Void) rethrows
    ///     mutating func clip(to path: Path, style: FillStyle, options: GraphicsContext.ClipOptions)
    private func drawHatch(_ hatch: VTimelineHatch,
                           in context: inout GraphicsContext,
                           rect: CGRect) {
        let pitch = hatch.pitch
        guard pitch > 0, rect.width > 0, rect.height > 0 else { return }
        context.drawLayer { layer in
            layer.clip(to: Path(rect))
            var lines = Path()
            var offset = -rect.height
            // Bounded independently of the arithmetic: a run as wide as the bar at a 3 pt pitch is
            // ~400 lines, and the cap stops a degenerate pitch from stalling the renderer.
            var drawn = 0
            let limit = 512
            while offset < rect.width, drawn < limit {
                lines.move(to: CGPoint(x: rect.minX + offset, y: rect.maxY))
                lines.addLine(to: CGPoint(x: rect.minX + offset + rect.height, y: rect.minY))
                if hatch == .cross {
                    lines.move(to: CGPoint(x: rect.minX + offset, y: rect.minY))
                    lines.addLine(to: CGPoint(x: rect.minX + offset + rect.height, y: rect.maxY))
                }
                offset += pitch
                drawn += 1
            }
            layer.stroke(lines,
                         with: .color(VTheme.Color.Text.inverse.opacity(0.45)),
                         lineWidth: VTheme.Border.thin)
        }
    }

    /// The local-clip strip: Vigil's own recordings, in `accent` (UX.md §7.3's `▁ local clips`).
    private func drawClips(in context: inout GraphicsContext, strip: CGRect) {
        let radius = VTheme.Radius.full(strip.height)
        let well = Path(roundedRect: strip, cornerRadius: radius, style: .continuous)
        context.fill(well, with: .color(VTheme.Color.Stroke.subtle))
        let kind = VTimelineSegmentKind.localClip
        for clip in track.localClips
        where geometry.window.intersects(from: clip.start, to: clip.end) {
            let x = geometry.clampedX(at: clip.start)
            let maxX = geometry.clampedX(at: clip.end)
            // The same visibility floor the segment layout applies, so a two-second clip is not a
            // sub-pixel sliver at the 24 h zoom.
            let width = max(TimelineBarLayout.defaultMinimumWidth, maxX - x)
            let box = CGRect(x: x, y: strip.minY, width: width, height: strip.height)
            context.fill(Path(roundedRect: box, cornerRadius: radius, style: .continuous),
                         with: .color(kind.colour.opacity(kind.fillOpacity)))
        }
    }

    // MARK: - Markers

    /// The event and bookmark row, clustered by ``TimelineMarkerLayout`` so a busy afternoon stays
    /// countable and clickable.
    private var markerRow: some View {
        let clusters = TimelineMarkerLayout.lay(out: track.markers, in: geometry)
        return ZStack(alignment: .topLeading) {
            // A transparent spacer so the row keeps its height when there are no markers at all.
            SwiftUI.Color.clear
            ForEach(clusters) { cluster in
                VTimelineMarkerGlyph(cluster: cluster, action: { onActivateMarker(cluster) })
                    .position(x: cluster.x, y: VTimelineMetrics.markerRow / 2)
            }
        }
        .frame(height: VTimelineMetrics.markerRow)
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
                .frame(width: VTimelineMetrics.markerGrab,
                       height: VTimelineMetrics.markerRow)
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
            VTimelinePennant()
                .fill(tint)
                .frame(width: VTimelineMetrics.markerGlyph + VTheme.Space.hair,
                       height: VTimelineMetrics.markerRow - VTheme.Space.hair)
        } else {
            // A rotated near-square rather than a `Path`: the diamond is 6 pt and a 1 pt corner
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
                        .strokeBorder(VTheme.Color.Text.primary,
                                      lineWidth: VTheme.Border.thin)
                }
            }
    }

    /// Bookmarks name themselves; events speak their own label, which the caller supplies.
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
/// A shape rather than an SF Symbol because UX.md §7.3 asks for a silhouette that is distinguishable
/// from a diamond *by outline* — that is what makes bookmarks legible under
/// `differentiateWithoutColor` without a second layout.
package struct VTimelinePennant: Shape {

    /// Draws the pennant inside `rect`. Degenerate rects yield an empty path rather than a
    /// negative-width flag.
    package func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 0, rect.height > 0 else { return path }
        let staff = max(VTheme.Border.thin, rect.width / 4)
        path.addRect(CGRect(x: rect.minX, y: rect.minY, width: staff, height: rect.height))
        path.move(to: CGPoint(x: rect.minX + staff, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height / 4))
        path.addLine(to: CGPoint(x: rect.minX + staff, y: rect.minY + rect.height / 2))
        path.closeSubpath()
        return path
    }
}

#endif  // os(macOS)
