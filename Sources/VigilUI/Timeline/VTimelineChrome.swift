//
//  VTimelineChrome.swift
//  VigilUI
//
//  The archive scrubber's controls: the pure hover-to-time resolution the pointer gestures run
//  through, the zoom stepper's arithmetic and its control, and the five-key legend.
//  macOS-only. Implements docs/DESIGN.md §7.4 #20 (scrub magnetism) and §9.14, and docs/UX.md §7.3.
//
//  Everything here that computes anything is a `static func` on a namespace enum, so the parts a
//  test can actually check — magnetism, the zoom ladder's bounds, the span readout — are reachable
//  without rendering a view. The views themselves are thin.
//

#if os(macOS)

import Foundation
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

    /// The zoom read-out's fixed width: enough for the widest stop (`15 min`) at the mono size,
    /// plus the horizontal padding it used to add.
    package static let spanLabelWidth: CGFloat = 62

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
                .padding(.vertical, VTheme.Space.hair)
                // ⛔ A FIXED BOX, because this label is the width of its text — `15 min`, `3 h`,
                // `24 h` — and it sits at the trailing end of a row. Every zoom step changed its
                // width, which moved the two zoom buttons, the speed control and the legend that
                // share the row: the user aimed at zoom-in, the control it re-flowed under their
                // pointer. Widest string plus its padding, once, and the row stops moving.
                .frame(width: Self.spanLabelWidth)
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

#endif  // os(macOS)
