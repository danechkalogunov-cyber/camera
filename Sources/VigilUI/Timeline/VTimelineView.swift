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

import AppKit
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
                                     clock: clock,
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
        // Hoisted: the guide closure escapes, and every `VTheme`-derived value is `@MainActor`.
        let gap = VTimelineMetrics.previewGap
        if let preview, let hoverX, width > 0 {
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
                                      magnetism: magnetismEnabled && !Self.isOptionHeld)
    }

    /// Whether ⌥ is down right now, which defeats snapping (UX.md §7.3).
    ///
    /// Read from AppKit at the instant the drag event is delivered, exactly as ``VSidebarClick``
    /// does and for the same reason: a `DragGesture`'s value carries no modifier flags on macOS 14,
    /// and `modifierKeyAlternate(_:_:)` arrived in macOS 15.
    ///
    /// ⚠️ Deliberately *not* a `@State` flag fed by a key-down monitor. Magnetism is a release-time
    /// snap, so the only moment its answer matters is the moment the pointer comes up — and a
    /// mirrored flag can be stale at exactly that moment, if ⌥ went down while the pointer was over
    /// another window or the key-up was swallowed by a menu.
    @MainActor
    private static var isOptionHeld: Bool {
        NSEvent.modifierFlags.contains(.option)
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
        guard let target = TimelineMarkerLayout.stepping(from: playhead, in: markers,
                                                         forward: next) else { return }
        onScrub(VTimelineScrubPhase.ended, day.clamp(target.seekInstant))
    }
}

#endif  // os(macOS)
