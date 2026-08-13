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
//  singleton. The window, the zoom stop and the playhead all arrive as values and every
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

    /// Called as a scrub progresses. Only ``VTimelineScrubPhase/ended`` should issue a seek.
    package let onScrub: (VTimelineScrubPhase, Date) -> Void

    /// Called with a requested zoom stop. The caller re-anchors and clamps the window — this view
    /// never mutates the window it was given.
    package let onZoom: (TimelineZoom) -> Void

    /// Called when a marker or a cluster badge is activated.
    package let onActivateMarker: (TimelineMarkerCluster) -> Void

    /// The playback-speed stop currently in force.
    package let rate: TimelinePlaybackRate

    /// Whether a speed can be asked for at all — false on a live stream, which has no speed.
    package let isRateAdjustable: Bool

    /// Called with a requested speed stop. Costly on some firmware: see `VTimelineSpeedControl`.
    package let onRate: (TimelinePlaybackRate) -> Void
    package let isPaused: Bool
    package let onTogglePause: () -> Void
    package let onFrameStep: (Bool) -> Void

    /// The selected export range, highlighted behind every lane.
    package let exportRange: Range<Date>?
    package let onMoveExportBoundary: (Bool, Date) -> Void

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
                 onScrub: @escaping (VTimelineScrubPhase, Date) -> Void = { _, _ in },
                 onZoom: @escaping (TimelineZoom) -> Void = { _ in },
                 onActivateMarker: @escaping (TimelineMarkerCluster) -> Void = { _ in },
                 rate: TimelinePlaybackRate = .normal,
                 isRateAdjustable: Bool = false,
                 isPaused: Bool = false,
                 onTogglePause: @escaping () -> Void = {},
                 onFrameStep: @escaping (Bool) -> Void = { _ in },
                 exportRange: Range<Date>? = nil,
                 onMoveExportBoundary: @escaping (Bool, Date) -> Void = { _, _ in },
                 onRate: @escaping (TimelinePlaybackRate) -> Void = { _ in }) {
        self.tracks = tracks
        self.day = day
        self.window = window
        self.zoom = zoom
        self.clock = clock
        self.playhead = playhead
        self.isScrubbing = isScrubbing
        self.isLoading = isLoading
        self.magnetismEnabled = magnetismEnabled
        self.onScrub = onScrub
        self.onZoom = onZoom
        self.onActivateMarker = onActivateMarker
        self.rate = rate
        self.isRateAdjustable = isRateAdjustable
        self.isPaused = isPaused
        self.onTogglePause = onTogglePause
        self.onFrameStep = onFrameStep
        self.exportRange = exportRange
        self.onMoveExportBoundary = onMoveExportBoundary
        self.onRate = onRate
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
            transport
            VTimelineSpeedControl(rate: rate, isEnabled: isRateAdjustable, onRate: onRate)
            VTimelineZoomControl(zoom: zoom, window: window, clock: clock, onZoom: onZoom)
        }
        .accessibilityHidden(true)
    }

    /// Pause and the two single-frame steps.
    ///
    /// ⛔ ALWAYS DRAWN, NEVER CONDITIONAL. These three used to appear only while an archive was
    /// open, so opening or closing a recording changed how many controls the header held — the row
    /// re-flowed, everything to its left moved, and a control the user was aiming at was somewhere
    /// else by the time they clicked. A toolbar whose shape depends on state is a toolbar nobody
    /// can build a habit with. Disabled is the right way to say "not now": same size, same
    /// position, dimmed — exactly what ``VTimelineSpeedControl`` beside it already does.
    ///
    /// ⚠️ Pause is *not* gated on ``isRateAdjustable``. Speed is meaningless on a live stream —
    /// `Scale: 4` asks for the next four seconds — but stopping one is not: it freezes the picture
    /// on its last frame, which is the whole point of a stop button on a camera.
    private var transport: some View {
        HStack(spacing: VTheme.Space.xxs) {
            VButton(symbol: isPaused ? VTheme.Symbol.play : VTheme.Symbol.pause,
                    style: .ghost,
                    accessibilityLabel: isPaused ? "Resume playback" : "Pause playback",
                    action: onTogglePause)
            VButton(symbol: VTheme.Symbol.frameBack, style: .ghost,
                    accessibilityLabel: "Previous frame") { onFrameStep(false) }
                .disabled(!isRateAdjustable)
                .opacity(isRateAdjustable ? 1 : 0.55)
            VButton(symbol: VTheme.Symbol.frameForward, style: .ghost,
                    accessibilityLabel: "Next frame") { onFrameStep(true) }
                .disabled(!isRateAdjustable)
                .opacity(isRateAdjustable ? 1 : 0.55)
        }
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

    /// The ruler, the lanes, the playhead and the hover cursor, all in one
    /// coordinate space so a pointer position means the same thing to every one of them.
    private func lanes(width: CGFloat) -> some View {
        let geometry = TimelineGeometry(window: window, width: Double(width))
        return ZStack(alignment: .topLeading) {
            exportHighlight(geometry: geometry)
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
            case .ended:
                hoverX = nil
            }
        }
    }

    @ViewBuilder
    private func exportHighlight(geometry: TimelineGeometry) -> some View {
        if let exportRange {
            let start = max(exportRange.lowerBound, window.start)
            let end = min(exportRange.upperBound, window.end)
            if start < end {
                let x1 = CGFloat(geometry.x(at: start))
                let x2 = CGFloat(geometry.x(at: end))
                Rectangle()
                    .fill(VTheme.Color.Semantic.accent.opacity(0.18))
                    .overlay(alignment: .leading) {
                        Rectangle().fill(VTheme.Color.Semantic.accent)
                            .frame(width: VTheme.Border.focus)
                    }
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(VTheme.Color.Semantic.accent)
                            .frame(width: VTheme.Border.focus)
                    }
                    .frame(width: max(1, x2 - x1), height: stackHeight)
                    .position(x: (x1 + x2) / 2, y: stackHeight / 2)
                    .allowsHitTesting(false)
                exportHandle(at: x1, isStart: true, geometry: geometry)
                exportHandle(at: x2, isStart: false, geometry: geometry)
            }
        }
    }

    private func exportHandle(at x: CGFloat, isStart: Bool,
                              geometry: TimelineGeometry) -> some View {
        VStack(spacing: 2) {
            Text(isStart ? "I" : "O")
                .vType(VTheme.Typography.monoSmall.numeric)
                .foregroundStyle(VTheme.Color.Semantic.danger)
            Capsule()
                .fill(VTheme.Color.Semantic.danger)
                .frame(width: 10, height: 28)
        }
            .frame(width: 24, height: 36, alignment: .top)
            .contentShape(Rectangle())
            .position(x: x, y: 18)
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                onMoveExportBoundary(
                    isStart,
                    geometry.clampedInstant(atX: Double(x + value.translation.width)))
            })
            .accessibilityLabel(isStart
                ? Text("Clip in point", bundle: .vigilUI)
                : Text("Clip out point", bundle: .vigilUI))
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
