//
//  VTimelineViewTests.swift
//  VigilUITests
//
//  The pure helpers the archive timeline view adds on top of the (already tested) Timeline logic
//  layer: the record-type-to-band-colour mapping, the legend's completeness, hover-to-time
//  resolution with magnetism, the zoom stepper's bounds, and the lane geometry.
//  macOS-only. Covers Sources/VigilUI/Timeline/VTimelineBarView.swift, VTimelineChrome.swift and
//  VTimelineView.swift.
//
//  ⛔ Nothing here renders a view. SwiftUI offers no supported way to evaluate a `body` in a unit
//  test, and a test that "checked the bar" by re-implementing `TimelineBarLayout` would assert its
//  own copy of the arithmetic rather than the shipped one. What is tested is exactly the part the
//  view *adds*: mappings, bounds, and the assembly of the three magnetism candidate sets. The
//  arithmetic itself is covered by TimelineGeometryTests and TimelineSeekTests.
//
//  Every test function here is prefixed `timelineView`. swift-testing attaches `@Test` to free
//  functions, which share one namespace per module, so an unprefixed obvious name breaks the whole
//  target — see docs/BUILD-VERIFICATION.md defect 4.
//

#if os(macOS)

import Foundation
import SwiftUI
import Testing

import VigilISAPI
import VigilProtocols

@testable import VigilUI

// MARK: - Fixtures

/// The mockup's day at the 1 h zoom over a 1 200 pt bar, which makes one point exactly three
/// seconds and every expected x below an integer.
///
/// The segments come from `TimelineFixture.mockupDay(_:)`, so these tests and the layout tests are
/// looking at the same shape.
private func timelineViewHourFixture() -> (index: TimelineSegmentIndex,
                                           geometry: TimelineGeometry,
                                           day: TimelineDay) {
    let clock = TimelineFixture.utcClock()
    let index = TimelineFixture.mockupIndex(clock: clock)
    let geometry = TimelineFixture.hourGeometry(index, hour: 9, width: 1_200)
    return (index, geometry, index.day)
}

/// A marker at `offset` seconds into `day`.
private func timelineViewMarker(_ day: TimelineDay, offset: Double,
                                kind: TimelineMarkerKind = .motion) -> TimelineMarker {
    TimelineMarker(id: UUID(),
                   instant: day.instant(atOffset: offset),
                   kind: kind,
                   label: "Motion")
}

// MARK: - Segment kind and legend

@Test func timelineViewSegmentKindMapsEveryRecordTypeToABandColour() {
    #expect(VTimelineSegmentKind(RecordType.alarm) == VTimelineSegmentKind.alarm)
    #expect(VTimelineSegmentKind(RecordType.motion) == VTimelineSegmentKind.motion)

    // DESIGN.md §9.14 names exactly three band colours, so the four remaining wire types all draw
    // as ordinary footage. `other` — an unrecognised value — is footage too, which is the one thing
    // about it that is certain.
    for type in [RecordType.timing, RecordType.manual, RecordType.command, RecordType.other] {
        #expect(VTimelineSegmentKind(type) == VTimelineSegmentKind.continuous,
                "\(type) must draw as continuous footage")
    }

    // No wire record type may ever land on a kind that is not a band colour: "no recording" is the
    // absence of a segment and "local clip" is not a device recording at all.
    for type in RecordType.allCases {
        let kind = VTimelineSegmentKind(type)
        #expect(kind != VTimelineSegmentKind.noRecording,
                "\(type) mapped to the absence of a recording")
        #expect(kind != VTimelineSegmentKind.localClip,
                "\(type) mapped to a locally recorded clip")
    }
}

@Test func timelineViewLegendListsEverySegmentKindExactlyOnce() {
    let order = VTimelineSegmentKind.legendOrder
    #expect(order.count == VTimelineSegmentKind.allCases.count,
            "the legend prints \(order.count) of \(VTimelineSegmentKind.allCases.count) kinds")
    for kind in VTimelineSegmentKind.allCases {
        #expect(order.filter { $0 == kind }.count == 1,
                "\(kind) must appear in the legend exactly once")
    }
    // The mockup's order: the three band colours, then the absence, then the local strip.
    #expect(order.first == VTimelineSegmentKind.continuous)
    #expect(order.last == VTimelineSegmentKind.localClip)
}

@Test func timelineViewSegmentKindOpacityRisesWithSeverity() {
    // DESIGN.md §9.14: continuous α 0.55, motion α 0.75, alarm α 0.90 — so severity reads off the
    // bar at a glance even where two runs abut.
    #expect(VTimelineSegmentKind.continuous.fillOpacity < VTimelineSegmentKind.motion.fillOpacity)
    #expect(VTimelineSegmentKind.motion.fillOpacity < VTimelineSegmentKind.alarm.fillOpacity)
    for kind in VTimelineSegmentKind.allCases {
        #expect(kind.fillOpacity > 0, "\(kind) would be invisible")
        #expect(kind.fillOpacity <= 1, "\(kind) has an out-of-range alpha")
    }
}

@Test func timelineViewHatchSeparatesMotionFromAlarmWithoutColour() {
    // DESIGN.md §10.5: continuous is the unhatched baseline, motion 45° at 4 pt, alarm cross-hatch
    // at 3 pt. The three must differ by geometry alone.
    #expect(VTimelineSegmentKind.continuous.hatch == VTimelineHatch.none)
    #expect(VTimelineSegmentKind.motion.hatch == VTimelineHatch.diagonal)
    #expect(VTimelineSegmentKind.alarm.hatch == VTimelineHatch.cross)
    #expect(VTimelineSegmentKind.motion.hatch != VTimelineSegmentKind.alarm.hatch)
    // A zero pitch is what stops the renderer looping on the unhatched baseline.
    #expect(VTimelineHatch.none.pitch == 0)
    #expect(VTimelineHatch.cross.pitch < VTimelineHatch.diagonal.pitch,
            "the denser pattern belongs to the more severe kind")
}

// MARK: - Hover to time

@Test func timelineViewHoverSnapsToASegmentBoundaryInsideTheTolerance() {
    let fixture = timelineViewHourFixture()
    // The 20-second alarm clip ends at 09:34:20, which is 2 060 s into the 09:00 window and
    // therefore x = 686.667 at three seconds per point. A pointer at x = 688 is 1.3 pt away — and
    // 8 pt from the 09:34 whole-minute candidate, which is outside the 6 pt radius.
    let result = VTimelineHover.instant(atX: 688,
                                        in: fixture.geometry,
                                        index: fixture.index,
                                        markers: [],
                                        day: fixture.day,
                                        magnetism: true)
    let expected = fixture.day.instant(atOffset: TimelineFixture.at(9, 34, 20))
    #expect(result == expected,
            "expected the alarm clip's end, got \(fixture.day.offset(of: result)) s into the day")
}

@Test func timelineViewHoverSnapsToAWholeMinuteWhenNoEdgeIsNearer() {
    let fixture = timelineViewHourFixture()
    // 09:41 is deep inside the 09:35–09:48 run, so the nearest segment edges are 100+ pt away and
    // the whole-minute candidate at x = 820 is the only one in range of x = 822.
    let result = VTimelineHover.instant(atX: 822,
                                        in: fixture.geometry,
                                        index: fixture.index,
                                        markers: [],
                                        day: fixture.day,
                                        magnetism: true)
    #expect(result == fixture.day.instant(atOffset: TimelineFixture.at(9, 41)))
}

@Test func timelineViewHoverPrefersAnEventMarkerOverASurroundingMinute() {
    let fixture = timelineViewHourFixture()
    // A marker at 09:41:30 sits at x = 830, exactly halfway between the 09:41 and 09:42 minute
    // ticks — both 10 pt away and therefore out of range at x = 832.
    let marker = timelineViewMarker(fixture.day, offset: TimelineFixture.at(9, 41, 30))
    let result = VTimelineHover.instant(atX: 832,
                                        in: fixture.geometry,
                                        index: fixture.index,
                                        markers: [marker],
                                        day: fixture.day,
                                        magnetism: true)
    #expect(result == marker.instant)
}

@Test func timelineViewHoverHonoursTheRawPositionWhenMagnetismIsDefeated() {
    let fixture = timelineViewHourFixture()
    // ⌥ held. The same x that snapped above must now resolve to exactly what the geometry says,
    // because a reviewer establishing that nothing was recorded needs to park where they clicked.
    let raw = VTimelineHover.instant(atX: 688,
                                     in: fixture.geometry,
                                     index: fixture.index,
                                     markers: [],
                                     day: fixture.day,
                                     magnetism: false)
    #expect(raw == fixture.geometry.clampedInstant(atX: 688))
    #expect(raw != fixture.day.instant(atOffset: TimelineFixture.at(9, 34, 20)))
    // DESIGN.md §7.4 #20 fixes the radius at 6 pt, in pixel space.
    #expect(VTimelineHover.snapTolerance == 6)
}

@Test func timelineViewHoverClampsAPointerDraggedPastEitherEdge() {
    let fixture = timelineViewHourFixture()
    let past = VTimelineHover.instant(atX: 5_000,
                                      in: fixture.geometry,
                                      index: fixture.index,
                                      markers: [],
                                      day: fixture.day,
                                      magnetism: true)
    #expect(past == fixture.geometry.window.end)

    let before = VTimelineHover.instant(atX: -400,
                                        in: fixture.geometry,
                                        index: fixture.index,
                                        markers: [],
                                        day: fixture.day,
                                        magnetism: true)
    #expect(before == fixture.geometry.window.start)
}

// MARK: - Zoom stepper

@Test func timelineViewZoomStepperSaturatesAtBothEndsOfTheLadder() {
    #expect(!VTimelineZoomStepper.canZoomOut(TimelineZoom.widest))
    #expect(VTimelineZoomStepper.zoomedOut(TimelineZoom.widest) == TimelineZoom.widest)
    #expect(VTimelineZoomStepper.canZoomIn(TimelineZoom.widest))

    #expect(!VTimelineZoomStepper.canZoomIn(TimelineZoom.tightest))
    #expect(VTimelineZoomStepper.zoomedIn(TimelineZoom.tightest) == TimelineZoom.tightest)
    #expect(VTimelineZoomStepper.canZoomOut(TimelineZoom.tightest))

    // In the middle both directions move, and they move opposite ways along the span.
    #expect(VTimelineZoomStepper.zoomedIn(TimelineZoom.hour).spanSeconds
            < TimelineZoom.hour.spanSeconds)
    #expect(VTimelineZoomStepper.zoomedOut(TimelineZoom.hour).spanSeconds
            > TimelineZoom.hour.spanSeconds)
}

@Test func timelineViewZoomSliderRoundTripsEveryStopAndClampsNonsense() {
    for stop in TimelineZoom.allCases {
        let position = VTimelineZoomStepper.sliderPosition(stop)
        #expect(position >= 0 && position <= 1, "\(stop) sits at \(position) on a 0…1 slider")
        #expect(VTimelineZoomStepper.zoom(atSliderPosition: position) == stop,
                "the knob must return to where it was put for \(stop)")
    }
    // Widest at the ⊖ end, tightest at the ⊕ end, matching the mockup's control.
    #expect(VTimelineZoomStepper.sliderPosition(TimelineZoom.widest) == 0)
    #expect(VTimelineZoomStepper.sliderPosition(TimelineZoom.tightest) == 1)

    #expect(VTimelineZoomStepper.zoom(atSliderPosition: -5) == TimelineZoom.widest)
    #expect(VTimelineZoomStepper.zoom(atSliderPosition: 12) == TimelineZoom.tightest)
    #expect(VTimelineZoomStepper.zoom(atSliderPosition: Double.nan) == TimelineZoom.widest)
    #expect(VTimelineZoomStepper.zoom(atSliderPosition: Double.infinity) == TimelineZoom.widest)
}

@Test func timelineViewZoomSpanLabelEchoesTheStopWhenTheWindowAgrees() {
    let clock = TimelineFixture.utcClock()
    let window = TimelineWindow(start: clock.today.start, zoom: .hour)
    #expect(VTimelineZoomStepper.spanLabel(window: window, zoom: .hour, locale: clock.locale)
            == TimelineZoom.hour.label(locale: clock.locale))
}

@Test func timelineViewZoomSpanLabelReportsAShortDayRatherThanTheNominalStop() throws {
    // The `.day` stop is a nominal 24 h; `TimelineWindow.fitting` resolves it to the day's true
    // length. A 23-hour bar labelled "24h" would be the same class of lie as drawing the segments
    // an hour out, so the readout follows the window.
    let zone = try #require(TimelineTZ.newYork,
                            "America/New_York must resolve for this test to mean anything")
    let clock = TimelineFixture.clock(zone: zone, year: 2026, month: 3, day: 8)
    let day = clock.today
    #expect(day.spanSeconds == 82_800, "the fixture must land on the 23-hour spring-forward day")

    let window = TimelineWindow.fitting(day, zoom: .day)
    #expect(window.spanSeconds == 82_800)
    let label = VTimelineZoomStepper.spanLabel(window: window, zoom: .day, locale: clock.locale)
    #expect(!label.isEmpty)
    #expect(label != TimelineZoom.day.label(locale: clock.locale),
            "a 23-hour bar must not read as the nominal 24 h stop")
}

// MARK: - Lane geometry

@Test @MainActor func timelineViewCompactLaneUsesTheLaneHeightToken() {
    #expect(VTimelineBarView.height(isPrimary: false) == VTheme.Metrics.timelineLaneHeight,
            "UX.md §7.3 gives every camera after the first a 44 pt lane")
    #expect(VTimelineBarView.height(isPrimary: true) > VTheme.Metrics.timelineLaneHeight,
            "the primary lane carries a header row and a marker row the compact lane does not")
    // The band, clip strip and marker row must all fit inside the lane they are drawn in.
    #expect(VTimelineMetrics.band + VTimelineMetrics.clipLane + VTimelineMetrics.markerRow
            < VTimelineBarView.height(isPrimary: true))
    #expect(VTimelineMetrics.compactBand < VTimelineMetrics.band)
}

@Test @MainActor func timelineViewStackHeightGrowsByOneLanePerExtraCamera() {
    let clock = TimelineFixture.utcClock()
    let day = clock.today
    let window = TimelineWindow(start: day.start, zoom: .hour).clamped(to: day)
    let index = TimelineFixture.mockupIndex(clock: clock)

    func track(_ number: Int) -> VTimelineTrack {
        VTimelineTrack(id: UUID(), name: "Camera \(number)", identityIndex: number, index: index)
    }
    func view(_ tracks: [VTimelineTrack]) -> VTimelineView {
        VTimelineView(tracks: tracks, day: day, window: window, zoom: .hour,
                      clock: clock, playhead: day.start)
    }

    let one = view([track(0)])
    let two = view([track(0), track(1)])
    let three = view([track(0), track(1), track(2)])

    #expect(one.stackHeight > VTimelineMetrics.ruler, "the ruler alone is not a timeline")
    let step = VTheme.Space.hair + VTheme.Metrics.timelineLaneHeight
    #expect(two.stackHeight - one.stackHeight == step)
    #expect(three.stackHeight - two.stackHeight == step)
    #expect(view([]).stackHeight == VTimelineMetrics.ruler,
            "with no cameras the control is the ruler and nothing else")
}

@Test @MainActor func timelineViewPennantStaysInsideItsRect() {
    let pennant = VTimelinePennant(staffWidth: VTheme.Border.selected)
    // A degenerate box yields an empty path rather than a negative-width flag.
    #expect(pennant.path(in: CGRect(x: 0, y: 0, width: 0, height: 10)).isEmpty)
    #expect(pennant.path(in: CGRect(x: 0, y: 0, width: 8, height: 0)).isEmpty)

    let drawn = pennant.path(in: CGRect(x: 0, y: 0, width: 8, height: 12))
    #expect(!drawn.isEmpty)
    let bounds = drawn.boundingRect
    #expect(bounds.minX >= -0.001 && bounds.maxX <= 8.001, "the flag escaped its box: \(bounds)")
    #expect(bounds.minY >= -0.001 && bounds.maxY <= 12.001, "the staff escaped its box: \(bounds)")

    // A staff wider than the box collapses to the box rather than inverting the flag.
    let squashed = pennant.path(in: CGRect(x: 0, y: 0, width: 1, height: 12))
    #expect(squashed.boundingRect.maxX <= 1.001)
}

@Test @MainActor func timelineViewLocalClipClampsAnInvertedSpan() {
    let start = Date(timeIntervalSince1970: 1_785_060_878)
    let clip = VTimelineLocalClip(id: UUID(),
                                  start: start,
                                  end: start.addingTimeInterval(-60),
                                  title: "Vigil clip")
    #expect(clip.end == clip.start, "an inverted span must not reach the renderer as a negative box")
}

#endif  // os(macOS)
