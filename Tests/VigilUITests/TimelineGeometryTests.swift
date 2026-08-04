//
//  TimelineGeometryTests.swift
//  VigilUITests
//
//  The pixel-to-time mapping, its invertibility, the zoom ladder, and the bar layout's gap
//  preservation.
//  macOS-only. Covers TimelineGeometry.swift, TimelineWindow.swift, TimelineBarLayout.swift,
//  TimelineRuler.swift, TimelineMarkers.swift and TimelinePlaybackRate.swift.
//

#if os(macOS)

import Foundation
import Testing

import VigilISAPI
import VigilProtocols

@testable import VigilUI

// MARK: - Invertibility

@Test func timelineGeometryMapsBothEndsOfTheBarExactly() throws {
    // The two exactnesses a user can actually see: the day's first and last instant, which are also
    // where a drag is most often released. Both must be bit-for-bit, not merely close.
    let index = TimelineFixture.mockupIndex()
    for width in [1.0, 37.0, 320.0, 1_200.0, 3_840.0] {
        for zoom in TimelineZoom.allCases {
            let window = TimelineWindow.fitting(index.day, zoom: zoom)
            let geometry = TimelineGeometry(window: window, width: width)
            #expect(geometry.instant(atX: 0) == window.start, "left edge at width \(width)")
            #expect(geometry.instant(atX: width) == window.end, "right edge at width \(width)")
            #expect(geometry.x(at: window.start) == 0)
            #expect(geometry.x(at: window.end) == width)
        }
    }
}

@Test func timelineGeometryRoundTripsEveryPixelWellInsideOneDisplayTick() throws {
    // "Exactly invertible" is not a property floating-point division has, so the claim under test is
    // the honest one: the round-trip error is bounded far below anything observable. The playhead
    // displays centiseconds (10 ms); the bound asserted here is 1 µs, four orders of magnitude
    // tighter, and in practice the errors come out near `Date`'s own ~119 ns resolution at 2026.
    let index = TimelineFixture.mockupIndex()
    let tolerance = 1e-6

    for zoom in TimelineZoom.allCases {
        let window = TimelineWindow.fitting(index.day, zoom: zoom)
        let geometry = TimelineGeometry(window: window, width: 1_200)
        var worst = 0.0
        for pixel in 0...1_200 {
            let x = Double(pixel)
            worst = max(worst, geometry.roundTripErrorSeconds(atX: x))
            // And the other direction: time → x → time.
            let instant = geometry.instant(atX: x)
            let back = geometry.x(at: instant)
            #expect(abs(back - x) * geometry.secondsPerPoint < tolerance,
                    "x round trip at \(zoom) pixel \(pixel)")
        }
        #expect(worst < tolerance, "worst round-trip error at \(zoom) was \(worst) s")
    }
}

@Test func timelineGeometryRoundTripsSegmentBoundariesWhichIsWhereItMatters() throws {
    // A segment edge is the value a user lands on with ⌘→ and with magnetism, so its round trip is
    // worth pinning separately from an arbitrary pixel.
    let index = TimelineFixture.mockupIndex()
    let geometry = TimelineFixture.dayGeometry(index)
    for segment in index.segments {
        for edge in [segment.start, segment.end] {
            let x = geometry.x(at: edge)
            let back = geometry.instant(atX: x)
            #expect(abs(back.timeIntervalSince(edge)) < 1e-6)
        }
    }
}

@Test func timelineGeometrySurvivesADegenerateWidthWithoutProducingNaN() throws {
    // SwiftUI really does propose zero during a GeometryReader's first pass and in a collapsed
    // column. A NaN escaping from here reaches a Path and silently blanks the whole timeline, so the
    // boundary traps it rather than forty call sites guarding against it.
    let index = TimelineFixture.mockupIndex()
    let window = TimelineWindow.fitting(index.day, zoom: .hour)
    for bad in [0.0, -50.0, Double.nan, .infinity, -.infinity] {
        let geometry = TimelineGeometry(window: window, width: bad)
        #expect(geometry.width == TimelineGeometry.degenerateWidth)
        #expect(geometry.secondsPerPoint.isFinite)
        #expect(geometry.pointsPerSecond.isFinite)
        let x = geometry.x(at: window.start.addingTimeInterval(600))
        #expect(x.isFinite, "x was \(x) for width \(bad)")
        #expect(geometry.instant(atX: .nan) == window.start)
        #expect(geometry.clampedInstant(atX: .nan) == window.start)
    }
}

// MARK: - Hour view and day view

@Test func timelineGeometryScalesCorrectlyBetweenTheHourAndDayViews() throws {
    let index = TimelineFixture.mockupIndex()
    let width = 1_200.0

    let day = TimelineGeometry(window: TimelineWindow.fitting(index.day, zoom: .day), width: width)
    #expect(day.secondsPerPoint == 72, "24 h across 1 200 pt is 72 s per point")
    #expect(day.window.spanSeconds == 86_400)

    let hour = TimelineFixture.hourGeometry(index, hour: 9, width: width)
    #expect(hour.secondsPerPoint == 3, "1 h across 1 200 pt is 3 s per point")

    // The same instant is 24× further along the bar at the hour zoom than at the day zoom, relative
    // to each window's own start.
    #expect(day.pointsPerSecond * 24 == hour.pointsPerSecond)

    // 09:30 is a quarter of the way into the 09:00 hour window.
    let halfPast = index.day.instant(atOffset: TimelineFixture.at(9, 30))
    #expect(hour.x(at: halfPast) == width / 2)
}

@Test func timelineZoomLadderIsMonotonicAndSteppableToBothEnds() throws {
    let all = TimelineZoom.allCases
    #expect(all.count == 9, "docs/UX.md §7.3 specifies nine stops and its invariant 11 ratifies them")

    // Raw order runs widest to tightest; spans must decrease monotonically along it.
    for (a, b) in zip(all, all.dropFirst()) {
        #expect(a.spanSeconds > b.spanSeconds, "\(a) should be wider than \(b)")
        #expect(b < a, "Comparable orders by span, so the tighter stop is the lesser")
    }
    #expect(all.first == .day)
    #expect(all.last == .minute)
    #expect(TimelineZoom.widest == .day)
    #expect(TimelineZoom.tightest == .minute)

    // Stepping terminates at both ends rather than wrapping or trapping.
    var zoom = TimelineZoom.widest
    for _ in 0..<20 { zoom = zoom.tighter }
    #expect(zoom == .tightest)
    for _ in 0..<20 { zoom = zoom.wider }
    #expect(zoom == .widest)
    #expect(TimelineZoom.day.wider == .day)
    #expect(TimelineZoom.minute.tighter == .minute)

    // Ticks are coarser at wider zooms, and a major is always a whole number of minors.
    for stop in all {
        #expect(stop.majorTickSeconds >= stop.minorTickSeconds, "\(stop)")
        let ratio = stop.majorTickSeconds / stop.minorTickSeconds
        #expect(abs(ratio - ratio.rounded()) < 1e-9,
                "\(stop): a major tick must be a whole number of minors, got \(ratio)")
        #expect(stop.spanSeconds > stop.majorTickSeconds)
    }
}

@Test func timelineZoomNearestSpanChoosesGeometricallyNotLinearly() throws {
    // Exact stops resolve to themselves.
    for stop in TimelineZoom.allCases {
        #expect(TimelineZoom.nearest(toSpanSeconds: stop.spanSeconds) == stop, "\(stop)")
    }
    // A pinch landing between 1 h and 30 min: 2 400 s is 1 200 s from the hour and 600 s from the
    // half hour linearly, but the ladder is geometric — log-nearest is what the eye agrees with.
    #expect(TimelineZoom.nearest(toSpanSeconds: 2_400) == .thirtyMinutes)
    // Nonsense input degrades rather than trapping.
    #expect(TimelineZoom.nearest(toSpanSeconds: 0) == .tightest)
    #expect(TimelineZoom.nearest(toSpanSeconds: -5) == .tightest)
    #expect(TimelineZoom.nearest(toSpanSeconds: 1e12) == .day)
}

@Test func timelineWindowZoomHoldsTheFocusInstantUnderThePointer() throws {
    let index = TimelineFixture.mockupIndex()
    let day = index.day
    // Zoom in about 10:14:38 — the mockup's playhead — from the day view to the minute view, one stop
    // at a time. The focus must stay visible throughout; that is the whole promise of anchored zoom.
    let focus = day.instant(atOffset: TimelineFixture.at(10, 14, 38))
    var window = TimelineWindow.fitting(day, zoom: .day)
    var zoom = TimelineZoom.day
    while zoom != .tightest {
        zoom = zoom.tighter
        window = window.zoomed(to: zoom, holding: focus, in: day)
        #expect(window.contains(focus), "focus left the window at \(zoom)")
        #expect(window.spanSeconds == zoom.spanSeconds)
        #expect(window.start >= day.start)
        #expect(window.end <= day.end)
    }
    // And back out again.
    while zoom != .widest {
        zoom = zoom.wider
        window = window.zoomed(to: zoom, holding: focus, in: day)
        #expect(window.contains(focus) || window.end == day.end, "focus left the window at \(zoom)")
    }
}

@Test func timelineWindowZoomNearAMidnightEdgeStaysInsideTheDay() throws {
    let index = TimelineFixture.mockupIndex()
    let day = index.day
    // Zooming about the very first and very last instants of the day is where a naive
    // "focus − fraction × span" walks outside it.
    for focus in [day.start, day.end, day.start.addingTimeInterval(1),
                  day.end.addingTimeInterval(-1)] {
        for zoom in TimelineZoom.allCases {
            let window = TimelineWindow.fitting(day, zoom: .day)
                .zoomed(to: zoom, holding: focus, in: day)
            #expect(window.start >= day.start, "\(zoom) at \(focus) started before the day")
            #expect(window.end <= day.end, "\(zoom) at \(focus) ended after the day")
        }
    }
}

// MARK: - Bar layout: the minimum width and the gap

@Test func timelineBarLayoutWidensASubPixelSegmentToTheMinimumWhereThereIsRoom() throws {
    let index = TimelineFixture.mockupIndex()
    // At the 6 h zoom one point is 18 s, so the fixture's 20 s alarm clip is 1.1 pt — under the 2 pt
    // floor — and the next segment is 60 s (3.3 pt) away, so there is room to widen it.
    let window = TimelineWindow(start: index.day.instant(atOffset: TimelineFixture.at(6)),
                                zoom: .sixHours).clamped(to: index.day)
    let geometry = TimelineGeometry(window: window, width: 1_200)
    #expect(geometry.secondsPerPoint == 18)
    let layout = TimelineBarLayout.lay(out: index, in: geometry)

    let alarm = try #require(layout.runs.first { $0.recordType == .alarm })
    #expect(alarm.exactWidth < TimelineBarLayout.defaultMinimumWidth,
            "the fixture's alarm should be under the floor at this zoom")
    #expect(alarm.width == TimelineBarLayout.defaultMinimumWidth,
            "a 20 s alarm with room to spare must reach the 2 pt floor; got \(alarm.width) pt")
    #expect(!alarm.isCompressed)
    // Widening never moves the left edge — that is what keeps the paint and the click arithmetic in
    // agreement, and it is the invariant a "lands a second off" bug would violate.
    #expect(alarm.x == geometry.x(at: index.segments[alarm.segmentIndex].start))
    #expect(layout.invariantFailures().isEmpty)
}

@Test func timelineBarLayoutFlagsCompressionRatherThanOverlappingWhenThereIsNoRoom() throws {
    // The honest half of the minimum-width rule. At the 24 h zoom a point is 72 s: the alarm is 0.28 pt
    // and the following segment starts only 60 s (0.83 pt) later, so 2 pt is physically unavailable
    // without painting over a neighbour. The run takes every point it can, stays put, and reports
    // itself compressed — which is what tells the drawing layer to add the 1 pt outer glow of
    // docs/UX.md §7.3, the only way to make something narrower than the floor visible without moving
    // it.
    let index = TimelineFixture.mockupIndex()
    let geometry = TimelineFixture.dayGeometry(index)
    let layout = TimelineBarLayout.lay(out: index, in: geometry)

    let alarm = try #require(layout.runs.first { $0.recordType == .alarm })
    #expect(alarm.isCompressed)
    #expect(alarm.width < TimelineBarLayout.defaultMinimumWidth)
    #expect(alarm.width >= alarm.exactWidth, "a run is never narrower than its true extent")
    #expect(alarm.x == geometry.x(at: index.segments[alarm.segmentIndex].start))

    // It grew as far as it honestly could: right up to the next run's left edge, no further.
    let position = try #require(layout.runs.firstIndex { $0.id == alarm.id })
    let next = layout.runs[position + 1]
    #expect(abs(alarm.maxX - next.x) < 1e-9,
            "the compressed run should take all the room available, and no more")
    #expect(layout.invariantFailures().isEmpty)
}

@Test func timelineBarLayoutNeverMovesARunsLeftEdgeAtAnyZoomOrWidth() throws {
    // The single most important invariant in the file: paint position and click position must agree.
    // Asserted across the whole matrix rather than at one zoom, because a displacement introduced to
    // make room would only show up where segments are dense.
    let index = TimelineFixture.mockupIndex()
    for width in [120.0, 600.0, 1_200.0, 2_400.0] {
        for zoom in TimelineZoom.allCases {
            let window = TimelineWindow.fitting(index.day, zoom: zoom)
            let geometry = TimelineGeometry(window: window, width: width)
            let layout = TimelineBarLayout.lay(out: index, in: geometry)
            for run in layout.runs {
                let segment = index.segments[run.segmentIndex]
                let expected = geometry.clampedX(at: max(segment.start, window.start))
                #expect(abs(run.x - expected) < 1e-9,
                        "run \(run.id) displaced at \(zoom)/\(width): \(run.x) vs \(expected)")
            }
        }
    }
}

@Test func timelineBarLayoutNeverPaintsOverARealGap() throws {
    // The requirement that fights the one above: a gap the user can see must survive every widening.
    let index = TimelineFixture.mockupIndex()
    for width in [200.0, 600.0, 1_200.0, 2_400.0] {
        for zoom in TimelineZoom.allCases {
            let window = TimelineWindow.fitting(index.day, zoom: zoom)
            let geometry = TimelineGeometry(window: window, width: width)
            let layout = TimelineBarLayout.lay(out: index, in: geometry)
            let failures = layout.invariantFailures()
            #expect(failures.isEmpty,
                    "zoom \(zoom) width \(width): \(failures.joined(separator: "; "))")
        }
    }
}

@Test func timelineBarLayoutKeepsAGapWideWhenBothNeighboursAreTiny() throws {
    // The adversarial case: two sub-pixel segments either side of a sub-pixel gap. Both want to grow
    // to the minimum; the gap must still be drawn or omitted honestly, never painted over.
    let clock = TimelineFixture.utcClock()
    let day = clock.today
    let raw = [
        TimelineFixture.segment(day: day, from: TimelineFixture.at(9, 0),
                                to: TimelineFixture.at(9, 0, 10), type: .alarm),
        // A 30-second gap, then another 10-second clip.
        TimelineFixture.segment(day: day, from: TimelineFixture.at(9, 0, 40),
                                to: TimelineFixture.at(9, 0, 50), type: .alarm),
    ]
    let index = TimelineSegmentIndex(raw: raw, day: day)
    let geometry = TimelineFixture.dayGeometry(index)   // 72 s per point
    let layout = TimelineBarLayout.lay(out: index, in: geometry)

    #expect(layout.runs.count == 2)
    #expect(layout.invariantFailures().isEmpty)
    // The two runs must not touch — the gap between them is real.
    let first = layout.runs[0]
    let second = layout.runs[1]
    #expect(first.maxX <= second.x, "the widened runs overlapped across a real gap")
    // At 72 s per point a 30 s gap is 0.42 pt, which is below the 1 pt minimum, so the segments could
    // not both reach 2 pt. They report themselves compressed rather than lying about their extent.
    #expect(first.isCompressed || first.width <= second.x - first.x)
}

@Test func timelineBarLayoutLetsAbuttingSegmentsTouchWithNoFalseSeam() throws {
    // The other direction of the same rule: two segments that abut in time must not be separated by a
    // 1 pt seam, because that would draw a break in a continuous recording.
    let clock = TimelineFixture.utcClock()
    let day = clock.today
    let raw = [
        TimelineFixture.segment(day: day, from: TimelineFixture.at(9, 0),
                                to: TimelineFixture.at(10, 0), type: .timing),
        TimelineFixture.segment(day: day, from: TimelineFixture.at(10, 0),
                                to: TimelineFixture.at(11, 0), type: .motion),
    ]
    let index = TimelineSegmentIndex(raw: raw, day: day)
    let geometry = TimelineFixture.dayGeometry(index)
    let layout = TimelineBarLayout.lay(out: index, in: geometry)

    #expect(layout.runs.count == 2)
    #expect(abs(layout.runs[0].maxX - layout.runs[1].x) < 1e-9,
            "abutting segments must meet exactly, with no gap and no overlap")
    // And no gap run is drawn between them.
    #expect(layout.gapRuns.allSatisfy { $0.x >= layout.runs[1].maxX - 1e-9
                                        || $0.maxX <= layout.runs[0].x + 1e-9 })
}

@Test func timelineBarLayoutClipsSegmentsToTheWindowAndFlagsThem() throws {
    let index = TimelineFixture.mockupIndex()
    // A window starting mid-segment: 10:15 is inside the 10:02–10:30 run.
    let window = TimelineWindow(start: index.day.instant(atOffset: TimelineFixture.at(10, 15)),
                                zoom: .thirtyMinutes).clamped(to: index.day)
    let geometry = TimelineGeometry(window: window, width: 1_200)
    let layout = TimelineBarLayout.lay(out: index, in: geometry)

    let first = try #require(layout.runs.first)
    #expect(first.isClippedAtStart, "the run straddling the left edge must say so")
    #expect(first.x == 0)
    for run in layout.runs {
        #expect(run.x >= -1e-9)
        #expect(run.maxX <= geometry.width + 1e-9)
    }
    #expect(layout.invariantFailures().isEmpty)
}

@Test func timelineBarLayoutOnAnEmptyDayDrawsOneFullWidthGapAndNoRuns() throws {
    let index = TimelineFixture.emptyIndex()
    let geometry = TimelineFixture.dayGeometry(index)
    let layout = TimelineBarLayout.lay(out: index, in: geometry)
    #expect(layout.runs.isEmpty)
    #expect(layout.gapRuns.count == 1)
    #expect(layout.gapRuns[0].x == 0)
    #expect(abs(layout.gapRuns[0].width - geometry.width) < 1e-9)
}

@Test func timelineBarLayoutOnAFullyRecordedDayDrawsOneFullWidthRunAndNoGap() throws {
    let index = TimelineFixture.continuousIndex()
    let geometry = TimelineFixture.dayGeometry(index)
    let layout = TimelineBarLayout.lay(out: index, in: geometry)
    #expect(layout.runs.count == 1)
    #expect(layout.runs[0].x == 0)
    #expect(abs(layout.runs[0].width - geometry.width) < 1e-9)
    #expect(layout.gapRuns.isEmpty, "a day recorded end to end must draw no gap at all")
    #expect(!layout.runs[0].isCompressed)
}

@Test func timelineBarLayoutRunIdentityIsUniqueUnlikeRecordSegmentID() throws {
    // RecordSegment.id is "track-startSecond", which COLLIDES for a continuous and a motion recording
    // opening in the same second — a real device shape. Duplicate ids in a ForEach are undefined
    // behaviour in SwiftUI, so the layout supplies its own index-based identity.
    let clock = TimelineFixture.utcClock()
    let day = clock.today
    let sameSecond = TimelineFixture.at(9, 0)
    let raw = [
        TimelineFixture.segment(day: day, from: sameSecond, to: TimelineFixture.at(9, 30),
                                type: .timing),
        TimelineFixture.segment(day: day, from: sameSecond, to: TimelineFixture.at(9, 5),
                                type: .motion),
    ]
    // The collision really exists on the underlying type — this is the fact that motivates the rule.
    #expect(raw[0].id == raw[1].id, "the premise of this test no longer holds; revisit run identity")

    let index = TimelineSegmentIndex(raw: raw, day: day)
    let layout = TimelineBarLayout.lay(out: index, in: TimelineFixture.dayGeometry(index))
    #expect(Set(layout.runs.map(\.id)).count == layout.runs.count,
            "run ids must be unique even when the segments' own ids collide")
}

#endif  // os(macOS)
