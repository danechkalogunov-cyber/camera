//
//  VTimelineView.swift
//  VigilUI
//
//  The archive scrubber: the assembled multi-track timeline at the bottom of the playback screen —
//  header and legend, hour ruler, one lane per camera, the shared playhead, and the pointer
//  gestures that turn a position into an instant.
//  macOS-only. Implements docs/DESIGN.md §9.14, §7.4 #20/#21 and docs/UX.md §7.3, §7.6, §14.5.
//
//  WHAT THIS VIEW IS. A renderer over ten tested files. `TimelineGeometry` decides where everything
//  is, `TimelineRuler` decides which instants get a tick, `TimelineBarLayout` decides the drawn
//  boxes, `TimelineMarkerLayout` decides which markers collapse, and `TimelineClock` decides what a
//  day is. Nothing here recomputes any of it — in particular nothing here divides by 86 400, which
//  is the single most expensive mistake available in a timeline (see the header of
//  TimelineClock.swift).
//
//  WHAT THIS VIEW DOES NOT DO. It fetches nothing, owns no model, spawns no `Task` and reads no
//  singleton. The window, the zoom stop, the playhead and the preview all arrive as values and every
//  gesture leaves through a callback, so the supervisor wires it to `VigilCore` and a preview wires
//  it to a literal.
//

#if os(macOS)

import Foundation
import SwiftUI

import VigilISAPI
import VigilProtocols

// MARK: - VTimelineScrubPhase

/// Where a scrub is in its life.
///
/// Three phases rather than a single "seek here", because the three mean different things to the
/// player: ``began`` pauses and arms the preview session, ``changed`` moves the playhead without
/// issuing a `PLAY` (a `PLAY` per pointer move would flood the device), and ``ended`` is the one
/// that actually seeks — which is also where release-time magnetism has already been applied.
package enum VTimelineScrubPhase: Sendable, Hashable {

    /// The pointer went down on the bar.
    case began

    /// The pointer moved while down.
    case changed

    /// The pointer came up. This is the seek.
    case ended
}

// MARK: - VTimelineView

/// The multi-track archive scrubber.
///
/// One lane per camera, all sharing one ``TimelineGeometry`` — which is what keeps synchronised
/// cameras aligned to the pixel — and one playhead, because synchronised playback is driven from a
/// single absolute-UTC instant (UX.md §7.6).
///
/// The control adds no padding of its own; the playback window insets it, so that the bar's leading
/// edge and the video canvas's leading edge can be made to agree.
@MainActor
package struct VTimelineView: View {

    // MARK: - Stored Properties

    /// The cameras, in stage order. The first gets the tall lane, its own header row and the marker
    /// row; the rest get the compact lane of UX.md §7.3.
    package let tracks: [VTimelineTrack]

    /// The day being reviewed. Its true length — 23, 24 or 25 hours — comes from ``TimelineClock``
    /// and is never assumed here.
    package let day: TimelineDay

    /// The visible slice of the day.
    package let window: TimelineWindow

    /// The zoom stop the window came from, which chooses the ruler's intervals and labels.
    package let zoom: TimelineZoom

    /// The calendar, time zone and locale every label is rendered in.
    package let clock: TimelineClock

    /// Where the playhead is. Exactly the instant the user asked for, even when it lies in a gap —
    /// see the ruling at the top of TimelineSeek.swift.
    package let playhead: Date

    /// Whether a scrub is in flight, which pops the timecode bubble and dims the bands so the
    /// playhead dominates (DESIGN.md §9.14, pressed row).
    package let isScrubbing: Bool

    /// Whether the day's search is still running. Not-yet-loaded ranges shimmer; they are never
    /// drawn as "no recording" (UX.md §7.4).
    package let isLoading: Bool

    /// Whether release-time magnetism applies. `false` while ⌥ is held (UX.md §7.3).
    package let magnetismEnabled: Bool

    /// The hover/scrub preview card, or `nil` to show none.
    package let preview: VTimelinePreview?

    /// Called as a scrub progresses. Only ``VTimelineScrubPhase/ended`` should issue a seek.
    package let onScrub: (VTimelineScrubPhase, Date) -> Void

    /// Called with the instant under the pointer, and with `nil` when the pointer leaves. Drives
    /// the preview card's keyframe request.
    package let onHoverInstant: (Date?) -> Void

    /// Called with a requested zoom stop. The caller re-anchors and clamps the window — this view
    /// never mutates the window it was given.
    package let onZoom: (TimelineZoom) -> Void

    /// Called when a marker or a cluster badge is activated.
    package let onActivateMarker: (TimelineMarkerCluster) -> Void

    @Environment(\.vMotionEnabled) private var motionEnabled

    @State private var hoverX: CGFloat?
    @State private var isDragging = false

    // MARK: - Initialisation

    /// Creates a timeline.
    ///
    /// - Parameters:
    ///   - tracks: one per camera; the first is the primary lane.
    ///   - day: the day being reviewed.
    ///   - window: the visible slice, already clamped into `day` by the caller.
    ///   - zoom: the stop `window` came from.
    ///   - clock: the calendar and locale.
    ///   - playhead: the current instant.
    package init(tracks: [VTimelineTrack],
                 day: TimelineDay,
                 window: TimelineWindow,
                 zoom: TimelineZoom,
                 clock: TimelineClock,
                 playhead: Date,
                 isScrubbing: Bool = false,
                 isLoading: Bool = false,
                 magnetismEnabled: Bool = true,
                 preview: VTimelinePreview? = nil,
                 onScrub: @escaping (VTimelineScrubPhase, Date) -> Void = { _, _ in },
                 onHoverInstant: @escaping (Date?) -> Void = { _ in },
                 onZoom: @escaping (TimelineZoom) -> Void = { _ in },
                 onActivateMarker: @escaping (TimelineMarkerCluster) -> Void = { _ in }) {
        self.tracks = tracks
        self.day = day
        self.window = window
        self.zoom = zoom
        self.clock = clock
        self.playhead = playhead
        self.isScrubbing = isScrubbing
        self.isLoading = isLoading
        self.magnetismEnabled = magnetismEnabled
        self.preview = preview
        self.onScrub = onScrub
        self.onHoverInstant = onHoverInstant
        self.onZoom = onZoom
        self.onActivateMarker = onActivateMarker
    }

    // MARK: - Geometry

    /// The height of the ruler plus every lane, so the control can be laid out without measuring
    /// itself and the `GeometryReader` below only ever has to answer a width.
    package var stackHeight: CGFloat {
        var total = VTimelineMetrics.ruler
        for offset in tracks.indices {
            total += VTheme.Space.hair + VTimelineBarView.height(isPrimary: offset == 0)
        }
        return total
    }

    /// The seek an accessibility increment performs. UX.md §14.5: "increment = 10 s at the current
    /// zoom".
    package static let adjustmentSeconds: Double = 10

    // MARK: - View

    package var body: some View {
        VStack(alignment: .leading, spacing: VTheme.Space.xs) {
            header
            // The one `GeometryReader` in the control. It answers a width, which is the single
            // number `TimelineGeometry` needs; the height is `stackHeight`, which is known, so the
            // reader's fill-the-parent behaviour costs nothing.
            GeometryReader { proxy in
                lanes(width: proxy.size.width)
            }
            .frame(height: stackHeight)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Recording timeline for \(primaryName)", bundle: .vigilUI))
        .accessibilityValue(Text(verbatim: clock.timecode(playhead)))
        // Closure literals, never unapplied method references: a `@MainActor` method used as a
        // value carries its isolation into its type and will not convert to the plain function
        // type these modifiers take.
        .accessibilityAdjustableAction { direction in adjust(direction) }
        .accessibilityAction(named: Text("Next event", bundle: .vigilUI)) {
            jumpToMarker(next: true)
        }
        .accessibilityAction(named: Text("Previous event", bundle: .vigilUI)) {
            jumpToMarker(next: false)
        }
    }

    // MARK: - Header

    /// `Front Door  09:00 – 11:00` on the leading side, legend and zoom stepper trailing.
    private var header: some View {
        HStack(spacing: VTheme.Space.sm) {
            Text(verbatim: primaryName)
                .vType(VTheme.Typography.callout)
                .foregroundStyle(VTheme.Color.Text.primary)
                .lineLimit(1)
            Text(verbatim: rangeLabel)
                .vType(VTheme.Typography.monoSmall.numeric)
                .foregroundStyle(VTheme.Color.Text.tertiary)
                .lineLimit(1)
            Spacer(minLength: VTheme.Space.md)
            VTimelineLegend()
            VTimelineZoomControl(zoom: zoom, window: window, clock: clock, onZoom: onZoom)
        }
        .accessibilityHidden(true)
    }

    /// The first camera's name, or an empty string when the playback window has no camera yet.
    private var primaryName: String {
        tracks.first?.name ?? ""
    }

    /// `09:00 – 11:00`. An en dash with hair spacing either side, not a hyphen: a hyphen between two
    /// monospaced clock times reads as a minus sign.
    private var rangeLabel: String {
        clock.hourMinute(window.start) + " \u{2013} " + clock.hourMinute(window.end)
    }

    // MARK: - Lanes

    /// The ruler, the lanes, the playhead, the hover cursor and the preview card, all in one
    /// coordinate space so a pointer position means the same thing to every one of them.
    private func lanes(width: CGFloat) -> some View {
        let geometry = TimelineGeometry(window: window, width: Double(width))
        return ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: VTheme.Space.hair) {
                VTimelineRulerView(geometry: geometry,
                                   day: day,
                                   zoom: zoom,
                                   clock: clock,
                                   isHovering: hoverX != nil)
                ForEach(tracks) { track in
                    VTimelineBarView(track: track,
                                     geometry: geometry,
                                     isPrimary: track.id == tracks.first?.id,
                                     isLoading: isLoading,
                                     onActivateMarker: onActivateMarker)
                }
            }
            // DESIGN.md §9.14: while scrubbing the bands drop to α 0.8 so the playhead dominates.
            .opacity(isScrubbing ? 0.8 : 1.0)
            .animation(VTheme.Motion.resolved(VTheme.Motion.micro, reduced: !motionEnabled),
                       value: isScrubbing)

            hoverCursor(width: width)
            playheadOverlay(geometry: geometry)
        }
        .contentShape(Rectangle())
        // Lower priority than the marker buttons inside, which is what `gesture` (rather than
        // `highPriorityGesture`) buys: clicking a marker activates it instead of scrubbing to it.
        .gesture(scrub(geometry: geometry))
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                hoverX = point.x
                onHoverInstant(resolve(x: point.x, in: geometry))
            case .ended:
                hoverX = nil
                onHoverInstant(nil)
            }
        }
        .overlay(alignment: .topLeading) { previewCard(width: width) }
    }

    /// The 1 pt cursor line that follows the pointer (DESIGN.md §9.14, hover row). Suppressed
    /// during a drag, where the playhead is already under the pointer.
    @ViewBuilder
    private func hoverCursor(width: CGFloat) -> some View {
        if let hoverX, !isDragging, width > 0 {
            Rectangle()
                .fill(VTheme.Color.Stroke.strong)
                .frame(width: VTheme.Border.thin)
                .frame(maxHeight: .infinity)
                .position(x: hoverX, y: stackHeight / 2)
                .allowsHitTesting(false)
        }
    }

    /// The playhead, drawn only when it is inside the window — a line pinned to an edge would claim
    /// a position the user is not at.
    @ViewBuilder
    private func playheadOverlay(geometry: TimelineGeometry) -> some View {
        if window.contains(playhead) {
            VTimelinePlayheadView(instant: playhead,
                                  clock: clock,
                                  height: stackHeight,
                                  isScrubbing: isScrubbing)
                .position(x: CGFloat(geometry.x(at: playhead)), y: stackHeight / 2)
        }
    }

    /// The preview card, floating `previewGap` above the whole control.
    ///
    /// The card is taller than the timeline strip, so it is placed by an alignment guide rather than
    /// by a fixed offset: setting the child's `.top` guide to its own height plus the gap puts its
    /// bottom edge exactly `previewGap` above the control's top edge, whatever the card measures.
    /// The overlay is deliberately not clipped — the playback window decides how far it may rise.
    @ViewBuilder
    private func previewCard(width: CGFloat) -> some View {
        if let preview, let hoverX, width > 0 {
            // Hoisted: the guide closure escapes, and every `VTheme`-derived value is `@MainActor`.
            let gap = VTimelineMetrics.previewGap
            VTimelinePreviewCard(preview: preview, clock: clock)
                .alignmentGuide(VerticalAlignment.top) { dimensions in
                    dimensions[VerticalAlignment.bottom] + gap
                }
                .offset(x: cardX(hoverX: hoverX, width: width))
        }
    }

    /// The card's leading edge, clamped so it never leaves the bar (UX.md §7.3: "clamped to the
    /// window").
    private func cardX(hoverX: CGFloat, width: CGFloat) -> CGFloat {
        let ideal = hoverX - VTimelineMetrics.previewWidth / 2
        let maximum = max(0, width - VTimelineMetrics.previewWidth)
        return min(max(0, ideal), maximum)
    }

    // MARK: - Gestures

    /// Click-and-drag scrubbing. `minimumDistance: 0` so a plain click is a scrub of length zero,
    /// which is what makes "click positions the playhead and seeks" and "drag scrubs" one gesture
    /// rather than two that can disagree.
    private func scrub(geometry: TimelineGeometry) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                hoverX = value.location.x
                let instant = resolve(x: value.location.x, in: geometry)
                if isDragging {
                    onScrub(VTimelineScrubPhase.changed, instant)
                } else {
                    isDragging = true
                    onScrub(VTimelineScrubPhase.began, instant)
                }
            }
            .onEnded { value in
                isDragging = false
                onScrub(VTimelineScrubPhase.ended, resolve(x: value.location.x, in: geometry))
            }
    }

    /// The instant a pointer position means, after magnetism.
    private func resolve(x: CGFloat, in geometry: TimelineGeometry) -> Date {
        let primary = tracks.first
        return VTimelineHover.instant(atX: Double(x),
                                      in: geometry,
                                      index: primary?.index ?? TimelineSegmentIndex(raw: [],
                                                                                    day: day),
                                      markers: primary?.markers ?? [],
                                      day: day,
                                      magnetism: magnetismEnabled)
    }

    // MARK: - Accessibility actions

    /// `.adjustable`: ±10 s, clamped into the day.
    private func adjust(_ direction: AccessibilityAdjustmentDirection) {
        let delta: Double
        switch direction {
        case .increment: delta = Self.adjustmentSeconds
        case .decrement: delta = -Self.adjustmentSeconds
        @unknown default: delta = 0
        }
        guard delta != 0 else { return }
        onScrub(VTimelineScrubPhase.ended, day.clamp(playhead.addingTimeInterval(delta)))
    }

    /// The `Next Event` / `Previous Event` rotor actions of UX.md §14.5. Seeks to the marker's own
    /// lead-in instant, which is what a click on it would do.
    private func jumpToMarker(next: Bool) {
        let markers = tracks.first?.markers ?? []
        let target = next
            ? TimelineMarkerLayout.next(after: playhead, in: markers)
            : TimelineMarkerLayout.previous(before: playhead, in: markers)
        guard let target else { return }
        onScrub(VTimelineScrubPhase.ended, day.clamp(target.seekInstant))
    }
}

// MARK: - Previews

#if DEBUG

/// Deterministic fixtures for the previews.
///
/// ⚠️ Synthesised, not captured from hardware. The shapes follow docs/spec-isapi.md §15 — a
/// continuous run split into files, a short event clip, files that abut exactly — but no value here
/// came off a device. The frozen "now" is 2026-07-26 10:14:38 UTC, the mockup's instant, so the
/// previews never call `Date()` and never move.
@MainActor
private enum VTimelineSample {

    /// 2026-07-26 10:14:38 UTC.
    static let now = Date(timeIntervalSince1970: 1_785_060_878)

    static let clock = TimelineClock(timeZoneIdentifier: "UTC",
                                     now: now,
                                     locale: Locale(identifier: "en_GB"))

    static var day: TimelineDay { clock.today }

    /// A stable UUID for a fixture, so a preview redraw does not re-identify every marker.
    static func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012ld", number)) ?? UUID()
    }

    static func at(_ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Double {
        Double(hour) * 3_600 + Double(minute) * 60 + Double(second)
    }

    static func segment(_ from: Double, _ to: Double,
                        _ type: RecordType = RecordType.timing) -> RecordSegment {
        let start = day.instant(atOffset: from)
        let end = day.instant(atOffset: to)
        return RecordSegment(track: TrackID(101),
                             start: start,
                             end: end,
                             codec: VideoCodecWire(raw: "H.265"),
                             contentType: "video",
                             recordType: type,
                             locator: PlaybackLocator(track: TrackID(101),
                                                      start: start, end: end))
    }

    /// The mockup's shape: continuous runs broken by motion, two real gaps, and a 20 s alarm clip
    /// that is 0.28 pt wide at the 24 h zoom — the segment the minimum-width rule exists for.
    static var mockupSegments: [RecordSegment] {
        [
            segment(at(9, 0), at(9, 12)),
            segment(at(9, 12), at(9, 14), RecordType.motion),
            segment(at(9, 20), at(9, 22), RecordType.motion),
            segment(at(9, 22), at(9, 34)),
            segment(at(9, 34), at(9, 34, 20), RecordType.alarm),
            segment(at(9, 35), at(9, 48)),
            segment(at(10, 2), at(10, 30)),
            segment(at(10, 30), at(10, 44), RecordType.motion),
            segment(at(10, 44), at(11, 0)),
        ]
    }

    /// A day whose footage stops for hours at a time, so the dotted "no recording" baseline and the
    /// legend's fourth key have something to describe.
    static var gappySegments: [RecordSegment] {
        [
            segment(at(0, 0), at(1, 30)),
            segment(at(6, 15), at(6, 18), RecordType.motion),
            segment(at(9, 0), at(9, 40)),
            segment(at(14, 0), at(14, 0, 25), RecordType.alarm),
            segment(at(18, 30), at(23, 59, 59)),
        ]
    }

    static func markers(_ offsets: [Double],
                        kind: TimelineMarkerKind = TimelineMarkerKind.motion,
                        from: Int = 0) -> [TimelineMarker] {
        offsets.enumerated().map { position, offset in
            TimelineMarker(id: id(from + position),
                           instant: day.instant(atOffset: offset),
                           kind: kind,
                           label: "Motion")
        }
    }

    /// Thirty events inside four minutes. At the 2 h zoom those are well inside the 8 pt collapse
    /// distance, so `TimelineMarkerLayout` folds them into counted clusters.
    static var denseMarkers: [TimelineMarker] {
        let offsets = (0..<30).map { at(10, 12) + Double($0) * 8 }
        return markers(offsets, from: 100)
            + markers([at(10, 5), at(10, 40)], kind: TimelineMarkerKind.alarm, from: 200)
            + markers([at(9, 30)], kind: TimelineMarkerKind.bookmark, from: 300)
    }

    static func track(name: String,
                      identity: Int,
                      segments: [RecordSegment],
                      markers: [TimelineMarker] = [],
                      clipOffsets: [(Double, Double)] = []) -> VTimelineTrack {
        let clips = clipOffsets.enumerated().map { position, span in
            VTimelineLocalClip(id: id(400 + position),
                               start: day.instant(atOffset: span.0),
                               end: day.instant(atOffset: span.1),
                               title: "Vigil clip")
        }
        return VTimelineTrack(id: id(identity),
                              name: name,
                              identityIndex: identity,
                              index: TimelineSegmentIndex(raw: segments, day: day),
                              markers: markers,
                              localClips: clips)
    }

    static var frontDoor: VTimelineTrack {
        track(name: "Front Door",
              identity: 0,
              segments: mockupSegments,
              markers: markers([at(9, 25), at(9, 34), at(10, 14), at(10, 36)])
                  + markers([at(9, 12)], kind: TimelineMarkerKind.bookmark, from: 50),
              clipOffsets: [(at(9, 38), at(9, 44)), (at(10, 20), at(10, 23))])
    }

    static var backYard: VTimelineTrack {
        track(name: "Back Yard",
              identity: 3,
              segments: [segment(at(9, 0), at(9, 30)),
                         segment(at(9, 55), at(10, 25), RecordType.motion),
                         segment(at(10, 25), at(11, 0))],
              clipOffsets: [(at(9, 15), at(9, 18))])
    }

    static func window(_ zoom: TimelineZoom, from offset: Double) -> TimelineWindow {
        TimelineWindow(start: day.instant(atOffset: offset), zoom: zoom).clamped(to: day)
    }
}

#Preview("Timeline — full day") {
    VTimelineView(tracks: [VTimelineSample.frontDoor],
                  day: VTimelineSample.day,
                  window: TimelineWindow.fitting(VTimelineSample.day,
                                                 zoom: TimelineZoom.day),
                  zoom: TimelineZoom.day,
                  clock: VTimelineSample.clock,
                  playhead: VTimelineSample.now)
        .padding(VTheme.Space.md)
        .frame(width: 980)
        .background(VTheme.Color.Layer.canvas)
}

#Preview("Timeline — two-hour window") {
    VTimelineView(tracks: [VTimelineSample.frontDoor, VTimelineSample.backYard],
                  day: VTimelineSample.day,
                  window: TimelineWindow(start: VTimelineSample.day.instant(atOffset: 9 * 3_600),
                                         spanSeconds: 2 * 3_600),
                  zoom: TimelineZoom.threeHours,
                  clock: VTimelineSample.clock,
                  playhead: VTimelineSample.now,
                  preview: VTimelinePreview(instant: VTimelineSample.now,
                                            kind: VTimelineSegmentKind.motion))
        .padding(.top, 140)
        .padding(VTheme.Space.md)
        .frame(width: 1_180)
        .background(VTheme.Color.Layer.canvas)
}

#Preview("Timeline — a day full of gaps") {
    VTimelineView(tracks: [VTimelineSample.track(name: "Loading Bay",
                                                 identity: 5,
                                                 segments: VTimelineSample.gappySegments,
                                                 clipOffsets: [(3_600, 4_200)])],
                  day: VTimelineSample.day,
                  window: TimelineWindow.fitting(VTimelineSample.day,
                                                 zoom: TimelineZoom.day),
                  zoom: TimelineZoom.day,
                  clock: VTimelineSample.clock,
                  playhead: VTimelineSample.day.instant(atOffset: 3 * 3_600))
        .padding(VTheme.Space.md)
        .frame(width: 980)
        .background(VTheme.Color.Layer.canvas)
}

#Preview("Timeline — clustered markers") {
    VTimelineView(tracks: [VTimelineSample.track(name: "Driveway",
                                                 identity: 1,
                                                 segments: VTimelineSample.mockupSegments,
                                                 markers: VTimelineSample.denseMarkers)],
                  day: VTimelineSample.day,
                  window: VTimelineSample.window(TimelineZoom.threeHours, from: 9 * 3_600),
                  zoom: TimelineZoom.threeHours,
                  clock: VTimelineSample.clock,
                  playhead: VTimelineSample.now,
                  isScrubbing: true)
        .padding(VTheme.Space.md)
        .frame(width: 900)
        .background(VTheme.Color.Layer.canvas)
}

#endif

#endif  // os(macOS)
