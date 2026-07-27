//
//  VTimelineChrome.swift
//  VigilUI
//
//  Everything that sits around the archive scrubber's lanes: the ruler, the legend, the zoom
//  stepper, the playhead with its timecode bubble, the hover preview card, and the pure hover-to-
//  time resolution the pointer gestures run through.
//  macOS-only. Implements docs/DESIGN.md §9.14 and §7.4 #20 (scrub magnetism), and docs/UX.md §7.3.
//
//  Everything here that computes anything is a `static func` on a namespace enum, so the parts a
//  test can actually check — magnetism, the zoom ladder's bounds, the span readout — are reachable
//  without rendering a view. The views themselves are thin.
//

#if os(macOS)

import SwiftUI

// MARK: - VTimelineHover

/// Turning a pointer position on the bar into an instant.
///
/// A namespace rather than a method on a view, because this is the arithmetic a scrub is *made* of
/// and it has to be assertable without a window. It adds nothing to ``TimelineGeometry`` beyond
/// assembling the three magnetism candidate sets DESIGN.md §7.4 #20 names — segment boundaries,
/// event markers and whole minutes — and handing them to
/// ``TimelineGeometry/snappedInstant(atX:candidates:tolerance:)``, which does the snapping.
package enum VTimelineHover {

    /// The snap radius in points. DESIGN.md §7.4 #20: 6 pt, in **pixel** space so it means the same
    /// thing at the 1 min zoom and the 24 h zoom.
    package static let snapTolerance: Double = 6

    /// The instant `x` points across the bar means.
    ///
    /// - Parameters:
    ///   - x: the pointer's position in points from the bar's leading edge. Clamped to the bar, so
    ///     a drag released past either end yields that end's instant rather than a time outside the
    ///     window.
    ///   - geometry: the pixel mapping.
    ///   - index: the day's footage, for the segment-boundary candidates.
    ///   - markers: the lane's markers, for the event candidates.
    ///   - day: the day, for the whole-minute candidates.
    ///   - magnetism: `false` while ⌥ is held, which defeats snapping entirely (UX.md §7.3).
    /// - Returns: the snapped instant, or the unsnapped one when nothing is within
    ///   ``snapTolerance``.
    package static func instant(atX x: Double,
                                in geometry: TimelineGeometry,
                                index: TimelineSegmentIndex,
                                markers: [TimelineMarker],
                                day: TimelineDay,
                                magnetism: Bool) -> Date {
        guard magnetism else { return geometry.clampedInstant(atX: x) }
        var candidates = index.edges(in: geometry.window)
        candidates.append(contentsOf: TimelineMarkerLayout.magnetismCandidates(
            in: geometry.window, markers: markers))
        candidates.append(contentsOf: TimelineRuler.wholeMinutes(in: geometry.window, day: day))
        return geometry.snappedInstant(atX: x, candidates: candidates, tolerance: snapTolerance)
    }
}

// MARK: - VTimelineZoomStepper

/// The zoom control's arithmetic: what the two buttons may do, where the slider's knob sits, and
/// what the span readout says.
///
/// Every one of these is a pure function of ``TimelineZoom`` and ``TimelineWindow``, so the control
/// itself holds no state and the bounds can be asserted directly.
package enum VTimelineZoomStepper {

    /// Whether ⊕ is available. False at the tightest stop, where ``TimelineZoom/tighter`` would
    /// return the same stop and the button would do nothing while still looking live.
    package static func canZoomIn(_ zoom: TimelineZoom) -> Bool {
        zoom != TimelineZoom.tightest
    }

    /// Whether ⊖ is available. False at the widest stop.
    package static func canZoomOut(_ zoom: TimelineZoom) -> Bool {
        zoom != TimelineZoom.widest
    }

    /// One stop tighter, saturating at ``TimelineZoom/tightest``.
    package static func zoomedIn(_ zoom: TimelineZoom) -> TimelineZoom { zoom.tighter }

    /// One stop wider, saturating at ``TimelineZoom/widest``.
    package static func zoomedOut(_ zoom: TimelineZoom) -> TimelineZoom { zoom.wider }

    /// The knob's position on a 0…1 slider: 0 at the widest stop, 1 at the tightest.
    ///
    /// Positional rather than proportional to the span, for the reason
    /// ``TimelinePlaybackRate/sliderPosition`` gives about its own ladder: the nine stops are
    /// geometric, so a slider proportional to the span would give the six tightest stops the last
    /// 4 % of its travel.
    package static func sliderPosition(_ zoom: TimelineZoom) -> Double {
        let stops = TimelineZoom.allCases.count
        guard stops > 1 else { return 0 }
        return Double(zoom.rawValue) / Double(stops - 1)
    }

    /// The stop nearest `position` on a 0…1 slider. Exactly inverts ``sliderPosition(_:)``.
    package static func zoom(atSliderPosition position: Double) -> TimelineZoom {
        let stops = TimelineZoom.allCases.count
        guard position.isFinite, stops > 1 else { return TimelineZoom.widest }
        let clamped = min(1, max(0, position))
        let raw = Int((clamped * Double(stops - 1)).rounded())
        return TimelineZoom(rawValue: min(stops - 1, max(0, raw))) ?? TimelineZoom.widest
    }

    /// The readout beside the slider — `"1h"`, `"30m"`, `"23h"` on a spring-forward day.
    ///
    /// It reports the **window**, not the stop, whenever the two disagree. They disagree in two real
    /// cases: a pinch is mid-flight between stops, and the `.day` stop on a 23- or 25-hour day,
    /// where ``TimelineWindow/fitting(_:zoom:focus:)`` resolves the nominal 24 h to the day's true
    /// length. Printing `"24h"` over a 23-hour bar would be the same class of lie as drawing the
    /// segments an hour out.
    ///
    /// - Parameter locale: injected, never read from the environment here — the caller passes
    ///   ``TimelineClock/locale``, which already has the 12/24-hour preference applied.
    package static func spanLabel(window: TimelineWindow,
                                  zoom: TimelineZoom,
                                  locale: Locale) -> String {
        if abs(window.spanSeconds - zoom.spanSeconds) < 1 {
            return zoom.label(locale: locale)
        }
        let units: Set<Duration.UnitsFormatStyle.Unit> =
            window.spanSeconds < 3_600 ? [.minutes] : [.hours]
        var style = Duration.UnitsFormatStyle(allowedUnits: units, width: .narrow)
        style.locale = locale
        return Duration.seconds(window.spanSeconds).formatted(style)
    }
}

// MARK: - VTimelineZoomControl

/// `⊖ ──●── ⊕  1h` — the zoom stepper of the approved mockup.
@MainActor
package struct VTimelineZoomControl: View {

    /// The slider's travel. Narrow on purpose: it is a coarse jump between nine stops, and the ⊖/⊕
    /// buttons and `⌘-`/`⌘=` are the precise path (UX.md §7.3).
    package static let sliderWidth: CGFloat = 74

    /// The current stop.
    package let zoom: TimelineZoom

    /// The visible window, which is what the readout reports.
    package let window: TimelineWindow

    /// The clock, for the locale the readout is formatted in.
    package let clock: TimelineClock

    /// Called with the requested stop. The caller re-anchors and clamps the window — this control
    /// deliberately knows nothing about the day.
    package let onZoom: (TimelineZoom) -> Void

    /// Creates the control.
    package init(zoom: TimelineZoom,
                 window: TimelineWindow,
                 clock: TimelineClock,
                 onZoom: @escaping (TimelineZoom) -> Void) {
        self.zoom = zoom
        self.window = window
        self.clock = clock
        self.onZoom = onZoom
    }

    package var body: some View {
        HStack(spacing: VTheme.Space.xs) {
            VButton(symbol: VTheme.Symbol.zoomOut,
                    style: VButton.Style.icon,
                    size: VButton.Size.xs,
                    accessibilityLabel: "Zoom out") {
                onZoom(VTimelineZoomStepper.zoomedOut(zoom))
            }
            .disabled(!VTimelineZoomStepper.canZoomOut(zoom))

            Slider(value: sliderBinding, in: 0...1)
                .controlSize(.mini)
                .frame(width: Self.sliderWidth)
                .accessibilityLabel(Text("Timeline zoom", bundle: .vigilUI))

            VButton(symbol: VTheme.Symbol.zoomIn,
                    style: VButton.Style.icon,
                    size: VButton.Size.xs,
                    accessibilityLabel: "Zoom in") {
                onZoom(VTimelineZoomStepper.zoomedIn(zoom))
            }
            .disabled(!VTimelineZoomStepper.canZoomIn(zoom))

            Text(verbatim: VTimelineZoomStepper.spanLabel(window: window, zoom: zoom,
                                                          locale: clock.locale))
                .vType(VTheme.Typography.monoSmall.numeric)
                .foregroundStyle(VTheme.Color.Text.secondary)
                .padding(.horizontal, VTheme.Space.xs)
                .padding(.vertical, VTheme.Space.hair)
                .overlay {
                    VTheme.Radius.shape(VTheme.Radius.sm)
                        .strokeBorder(VTheme.Color.Stroke.default,
                                      lineWidth: VTheme.Border.thin)
                }
                .accessibilityHidden(true)
        }
    }

    /// A computed binding rather than stored state: the stop is owned by whatever drives this
    /// screen, so the knob can never drift out of agreement with the bar it controls.
    private var sliderBinding: Binding<Double> {
        Binding(get: { VTimelineZoomStepper.sliderPosition(zoom) },
                set: { onZoom(VTimelineZoomStepper.zoom(atSliderPosition: $0)) })
    }
}

// MARK: - VTimelineLegend

/// The five-key legend: `continuous / motion / alarm / no recording / local clip`.
@MainActor
package struct VTimelineLegend: View {

    /// Creates the legend.
    package init() {}

    package var body: some View {
        HStack(spacing: VTheme.Space.md) {
            ForEach(VTimelineSegmentKind.legendOrder, id: \.self) { kind in
                HStack(spacing: VTheme.Space.xxs) {
                    Self.swatch(kind)
                    Self.label(kind)
                        .vType(VTheme.Typography.caption2)
                        // DESIGN.md §4.2 files legend keys under `Caption2`, whose step carries
                        // `.uppercase`. The approved mockup renders them in sentence case, and
                        // "NO RECORDING" reads as an alarm eyebrow rather than as the phrase it is,
                        // so the case — and only the case — is overridden here.
                        .textCase(nil)
                        .foregroundStyle(VTheme.Color.Text.tertiary)
                }
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
    }

    /// The 9 pt colour chip beside a key.
    @ViewBuilder
    static func swatch(_ kind: VTimelineSegmentKind) -> some View {
        let shape = VTheme.Radius.shape(VTheme.Space.hair)
        if kind == VTimelineSegmentKind.noRecording {
            // The absence has no colour of its own, so its swatch is the raised layer inside a
            // hairline — which is exactly what an unrecorded stretch looks like on the bar.
            shape
                .fill(kind.colour)
                .overlay { shape.strokeBorder(VTheme.Color.Stroke.default,
                                              lineWidth: VTheme.Border.thin) }
                .frame(width: VTimelineMetrics.legendSwatch,
                       height: VTimelineMetrics.legendSwatch)
        } else {
            shape
                .fill(kind.colour)
                .frame(width: VTimelineMetrics.legendSwatch,
                       height: VTimelineMetrics.legendSwatch)
        }
    }

    /// The localised key for a kind. The one place these five strings are named.
    static func label(_ kind: VTimelineSegmentKind) -> Text {
        switch kind {
        case .continuous: Text("continuous", bundle: .vigilUI)
        case .motion: Text("motion", bundle: .vigilUI)
        case .alarm: Text("alarm", bundle: .vigilUI)
        case .noRecording: Text("no recording", bundle: .vigilUI)
        case .localClip: Text("local clip", bundle: .vigilUI)
        }
    }
}

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
        return ZStack(alignment: .topLeading) {
            Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: false) {
                context, size in
                draw(ticks: ticks, in: &context, size: size)
            }
            ForEach(ticks.filter(\.isMajor)) { tick in
                Text(verbatim: tick.label ?? "")
                    .vType(VTheme.Typography.monoSmall.numeric)
                    .foregroundStyle(VTheme.Color.Text.tertiary)
                    .fixedSize()
                    .position(x: tick.x,
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
    private func draw(ticks: [TimelineTick], in context: inout GraphicsContext, size: CGSize) {
        for tick in ticks {
            let length = tick.isMajor ? VTimelineMetrics.majorTick : VTimelineMetrics.minorTick
            var line = Path()
            line.move(to: CGPoint(x: tick.x, y: size.height - length))
            line.addLine(to: CGPoint(x: tick.x, y: size.height))
            context.stroke(line,
                           with: .color(tick.isMajor ? VTheme.Color.Stroke.strong
                                                     : VTheme.Color.Stroke.default),
                           lineWidth: VTheme.Border.thin)
        }
    }
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
    package let instant: Date

    /// The pixel mapping.
    package let geometry: TimelineGeometry

    /// The clock the bubble's timecode is formatted with.
    package let clock: TimelineClock

    /// The height of the lane stack the line runs through, bubble included.
    package let height: CGFloat

    /// Whether a scrub is in flight, which pops the bubble (DESIGN.md §9.14, pressed row).
    package let isScrubbing: Bool

    @Environment(\.vMotionEnabled) private var motionEnabled

    /// Creates a playhead.
    package init(instant: Date,
                 geometry: TimelineGeometry,
                 clock: TimelineClock,
                 height: CGFloat,
                 isScrubbing: Bool = false) {
        self.instant = instant
        self.geometry = geometry
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

// MARK: - VTimelinePreview

/// What the scrub preview card shows at one instant.
///
/// The image is injected. Decoding a keyframe is a background-actor job belonging to the playback
/// session (UX.md §7.3), and a view that fetched its own would put a decode on the main actor at
/// pointer-move rate.
package struct VTimelinePreview {

    /// The instant the card describes.
    package let instant: Date

    /// What the archive holds there, for the caption's `· motion` suffix, or `nil` in a gap.
    package let kind: VTimelineSegmentKind?

    /// The decoded keyframe, or `nil` until it arrives — in which case the card shows a shimmer and
    /// the exact timestamp, so it never appears empty and never changes size (UX.md §7.3).
    package let image: Image?

    /// Creates a preview.
    package init(instant: Date, kind: VTimelineSegmentKind?, image: Image? = nil) {
        self.instant = instant
        self.kind = kind
        self.image = image
    }
}

// MARK: - VTimelinePreviewCard

/// The 176 pt card that floats above the pointer while hovering or scrubbing.
@MainActor
package struct VTimelinePreviewCard: View {

    /// What to show.
    package let preview: VTimelinePreview

    /// The clock the caption's timestamp is formatted with.
    package let clock: TimelineClock

    /// Creates a card.
    package init(preview: VTimelinePreview, clock: TimelineClock) {
        self.preview = preview
        self.clock = clock
    }

    package var body: some View {
        VStack(spacing: VTheme.Space.xxs) {
            thumbnail
            caption
        }
        .padding(VTheme.Space.xs)
        .frame(width: VTimelineMetrics.previewWidth)
        .vElevation(VTheme.Elevation.e2,
                    radius: VTheme.Radius.lg,
                    over: VTheme.Backdrop.chrome)
        .allowsHitTesting(false)
        // The playhead's own value already speaks this instant; a second announcement of it while
        // the pointer moves would be noise.
        .accessibilityHidden(true)
    }

    /// A true-black well whatever is in it — every thumbnail surface in Vigil is `#000000`
    /// (DESIGN.md §3.6).
    @ViewBuilder
    private var thumbnail: some View {
        let shape = VTheme.Radius.shape(VTheme.Radius.sm)
        Group {
            if let image = preview.image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                VSkeleton(radius: VTheme.Radius.sm, base: VTheme.Color.Layer.videoWell)
            }
        }
        .frame(height: VTimelineMetrics.previewThumbnailHeight)
        .frame(maxWidth: .infinity)
        .background(VTheme.Color.Layer.videoWell, in: shape)
        .clipShape(shape)
    }

    /// `10:14:38 · motion`, or just the time when the instant lies in a gap.
    private var caption: some View {
        HStack(spacing: VTheme.Space.xxs) {
            Text(verbatim: clock.hourMinuteSecond(preview.instant))
                .vType(VTheme.Typography.monoSmall.numeric)
                .foregroundStyle(VTheme.Color.Text.secondary)
            if let kind = preview.kind {
                Text(verbatim: "·")
                    .vType(VTheme.Typography.monoSmall)
                    .foregroundStyle(VTheme.Color.Text.tertiary)
                VTimelineLegend.label(kind)
                    .vType(VTheme.Typography.caption2)
                    .textCase(nil)
                    .foregroundStyle(VTheme.Color.Text.tertiary)
            }
        }
        .lineLimit(1)
    }
}

#endif  // os(macOS)
