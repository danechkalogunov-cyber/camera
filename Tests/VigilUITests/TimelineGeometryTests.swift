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

// MARK: - Ruler

@Test func timelineRulerPlacesTicksOnRoundLocalTimesNotOnTheWindowEdge() throws {
    let index = TimelineFixture.mockupIndex()
    let clock = TimelineFixture.utcClock()
    // A window starting at a deliberately unround time.
    let window = TimelineWindow(start: index.day.instant(atOffset: TimelineFixture.at(9, 3, 47)),
                                zoom: .hour).clamped(to: index.day)
    let geometry = TimelineGeometry(window: window, width: 1_200)
    let ticks = TimelineRuler.ticks(in: geometry, day: index.day, zoom: .hour, clock: clock)

    #expect(!ticks.isEmpty)
    // Every tick sits on a whole minute of the day, never at 09:03:47.
    for tick in ticks {
        let offset = index.day.offset(of: tick.instant)
        #expect(abs(offset.truncatingRemainder(dividingBy: 60)) < 1e-6,
                "tick at offset \(offset) is not on a whole minute")
        #expect(tick.x >= 0 && tick.x <= geometry.width)
        #expect(window.contains(tick.instant))
    }
    // Majors are labelled, minors are not.
    #expect(ticks.contains { $0.isMajor })
    #expect(ticks.allSatisfy { $0.isMajor == ($0.label != nil) })
    // Ascending, with unique ids for ForEach.
    #expect(zip(ticks, ticks.dropFirst()).allSatisfy { $0.instant < $1.instant })
    #expect(Set(ticks.map(\.id)).count == ticks.count)
}

@Test func timelineRulerLabelsTheFallBackHourTwiceWhichIsTheTruth() throws {
    let zone = try #require(TimelineTZ.newYork)
    let clock = TimelineClock(calendar: timelineCalendar(zone),
                              now: Date(timeIntervalSince1970: 0), locale: timelineTestLocale)
    let day = try #require(clock.day(year: 2026, month: 11, day: 1))
    #expect(day.spanSeconds == 90_000)

    let window = TimelineWindow.fitting(day, zoom: .day)
    let geometry = TimelineGeometry(window: window, width: 2_400)
    let majors = TimelineRuler.majorTicks(in: geometry, day: day, zoom: .day, clock: clock)

    // The `.day` stop labels every hour. A 25-hour day therefore has 25 hourly ticks, and the local
    // hour "01" genuinely occurs twice — the archive holds two distinct hours of footage that both
    // belong to it. Labelling one of them 02 would be the lie.
    let ones = majors.filter { $0.label == "01" }
    #expect(ones.count == 2, "expected the fall-back hour twice, got \(majors.compactMap(\.label))")
    // They are an hour apart on the bar, so they are visibly two different places.
    let separation = abs(ones[1].x - ones[0].x)
    #expect(separation > 1, "the two 01:00 ticks must not be drawn at the same point")
    #expect(abs(ones[1].instant.timeIntervalSince(ones[0].instant) - 3_600) < 1e-6)

    // Ticks stay strictly ascending across the transition — no duplicate positions, no skipped hour.
    #expect(zip(majors, majors.dropFirst()).allSatisfy { $0.x < $1.x })
}

@Test func timelineRulerSkipsNoHourOnTheSpringForwardDay() throws {
    let zone = try #require(TimelineTZ.newYork)
    let clock = TimelineClock(calendar: timelineCalendar(zone),
                              now: Date(timeIntervalSince1970: 0), locale: timelineTestLocale)
    let day = try #require(clock.day(year: 2026, month: 3, day: 8))
    let window = TimelineWindow.fitting(day, zoom: .day)
    let geometry = TimelineGeometry(window: window, width: 2_400)
    let majors = TimelineRuler.majorTicks(in: geometry, day: day, zoom: .day, clock: clock)

    // A 23-hour day: 23 hourly ticks, and local 02 never happens because the clock jumped 02:00→03:00.
    #expect(majors.count == 23, "got \(majors.compactMap(\.label))")
    #expect(!majors.contains { $0.label == "02" }, "02:00 does not exist on this day")
    #expect(majors.contains { $0.label == "01" })
    #expect(majors.contains { $0.label == "03" })
    #expect(zip(majors, majors.dropFirst()).allSatisfy { $0.x < $1.x })
}

@Test func timelineRulerIsBoundedAgainstAPathologicalWindow() throws {
    // A deep link can hand over a hand-written span the ladder does not offer. Generating 86 400 ticks
    // would stall the main thread, so the generator is bounded.
    let index = TimelineFixture.mockupIndex()
    let clock = TimelineFixture.utcClock()
    let window = TimelineWindow(start: index.day.start, spanSeconds: 86_400)
    let geometry = TimelineGeometry(window: window, width: 1_200)
    let ticks = TimelineRuler.ticks(in: geometry, day: index.day, zoom: .minute, clock: clock)
    #expect(ticks.count <= 4_000)
    #expect(!ticks.isEmpty)
}

// MARK: - Markers

@Test func timelineMarkerLayoutCollapsesOnlyMarkersNearTheClusterAnchor() throws {
    let index = TimelineFixture.mockupIndex()
    let day = index.day
    let geometry = TimelineFixture.hourGeometry(index, hour: 9)   // 3 s per point

    // A run of markers 7 s apart. At 3 s per point that is 2.33 pt each — inside the 8 pt collapse
    // distance from its predecessor, but the run spans far more than 8 pt in total. Chaining off the
    // previous marker would collapse the whole run into one cluster spanning the bar; anchoring on the
    // cluster's first member is what keeps them separable.
    let markers = (0..<12).map { step in
        TimelineMarker(id: UUID(), instant: day.instant(atOffset: TimelineFixture.at(9, 10)
                                                        + Double(step) * 7),
                       kind: .motion, label: "m\(step)")
    }
    let clusters = TimelineMarkerLayout.lay(out: markers, in: geometry)
    #expect(clusters.count > 1, "the run must not collapse into a single cluster")
    for cluster in clusters {
        let span = (cluster.markers.last?.instant.timeIntervalSince(cluster.markers[0].instant) ?? 0)
            * geometry.pointsPerSecond
        #expect(span <= TimelineMarkerLayout.clusterDistance + 1e-9,
                "cluster spans \(span) pt, wider than the collapse distance")
    }
    // Nothing lost, nothing duplicated.
    #expect(clusters.reduce(0) { $0 + $1.count } == markers.count)
    #expect(Set(clusters.flatMap { $0.markers.map(\.id) }).count == markers.count)
    // Ordered left to right, and each cluster sits on its FIRST member — never on a mean, which would
    // put the glyph at a time nothing happened.
    #expect(zip(clusters, clusters.dropFirst()).allSatisfy { $0.x < $1.x })
    for cluster in clusters {
        #expect(cluster.x == geometry.x(at: cluster.markers[0].instant))
    }
}

@Test func timelineMarkerClusterTakesTheMostSevereMemberColourAndIsOrderIndependent() throws {
    let index = TimelineFixture.mockupIndex()
    let day = index.day
    let geometry = TimelineFixture.dayGeometry(index)
    let instant = day.instant(atOffset: TimelineFixture.at(9, 10))
    let motion = TimelineMarker(id: UUID(), instant: instant, kind: .motion, label: "motion")
    let alarm = TimelineMarker(id: UUID(), instant: instant.addingTimeInterval(30),
                               kind: .alarm, label: "alarm")
    let crossing = TimelineMarker(id: UUID(), instant: instant.addingTimeInterval(60),
                                  kind: .lineCrossing, label: "line")

    // Same three markers, two input orders, must give the same clustering and the same colour — an
    // alarm hidden inside a cluster of motion events is exactly what a reviewer is looking for.
    let a = TimelineMarkerLayout.lay(out: [motion, alarm, crossing], in: geometry)
    let b = TimelineMarkerLayout.lay(out: [crossing, alarm, motion], in: geometry)
    #expect(a.count == b.count)
    #expect(a.map(\.count) == b.map(\.count))
    #expect(a[0].dominantKind == .alarm)
    #expect(b[0].dominantKind == .alarm)
    #expect(a[0].isCluster)
}

@Test func timelineMarkerSeekAppliesTheThreeSecondLeadIn() throws {
    let instant = Date(timeIntervalSince1970: 1_784_050_478)
    let marker = TimelineMarker(id: UUID(), instant: instant, kind: .motion, label: "m")
    // docs/FEATURES.md §13: clicking a timeline marker seeks to it minus 3 s, so the clip shows what
    // caused the detection rather than its aftermath.
    #expect(marker.seekInstant == instant.addingTimeInterval(-3))
    #expect(TimelineMarker.seekLeadSeconds == 3)
}

@Test func timelineMarkerNavigationFindsTheNextAndPreviousStrictly() throws {
    let index = TimelineFixture.mockupIndex()
    let day = index.day
    let markers = [9, 10, 11].map { hour in
        TimelineMarker(id: UUID(), instant: day.instant(atOffset: TimelineFixture.at(hour)),
                       kind: .motion, label: "\(hour)")
    }
    let ten = day.instant(atOffset: TimelineFixture.at(10))
    // Strictly after / strictly before: standing exactly on a marker must not find itself, or `.`
    // would never advance.
    #expect(TimelineMarkerLayout.next(after: ten, in: markers)?.label == "11")
    #expect(TimelineMarkerLayout.previous(before: ten, in: markers)?.label == "9")
    #expect(TimelineMarkerLayout.next(after: markers[2].instant, in: markers) == nil)
    #expect(TimelineMarkerLayout.previous(before: markers[0].instant, in: markers) == nil)
}

// MARK: - Magnetism

@Test func timelineGeometrySnapsInPixelSpaceSoToleranceMeansTheSameAtEveryZoom() throws {
    let index = TimelineFixture.mockupIndex()
    let day = index.day
    let edge = day.instant(atOffset: TimelineFixture.at(9, 20))     // a segment start

    for zoom in TimelineZoom.allCases {
        let window = TimelineWindow.fitting(day, zoom: zoom).centred(on: edge, in: day)
        let geometry = TimelineGeometry(window: window, width: 1_200)
        let edgeX = geometry.x(at: edge)

        // 5 pt away, inside the 6 pt radius: snaps, at every zoom.
        let snapped = geometry.snappedInstant(atX: edgeX + 5, candidates: [edge], tolerance: 6)
        #expect(snapped == edge, "failed to snap at \(zoom)")

        // 7 pt away, outside it: does not snap.
        let free = geometry.snappedInstant(atX: edgeX + 7, candidates: [edge], tolerance: 6)
        #expect(free != edge, "snapped from too far at \(zoom)")

        // ⌥ held — tolerance 0 — never snaps.
        let unsnapped = geometry.snappedInstant(atX: edgeX + 1, candidates: [edge], tolerance: 0)
        #expect(unsnapped == geometry.clampedInstant(atX: edgeX + 1))
    }
}

@Test func timelineGeometrySnapTiesResolveToTheEarlierCandidateNotToArrayOrder() throws {
    let index = TimelineFixture.mockupIndex()
    let geometry = TimelineFixture.hourGeometry(index, hour: 9)
    let middle = index.day.instant(atOffset: TimelineFixture.at(9, 30))
    let before = middle.addingTimeInterval(-6)      // 2 pt at this zoom
    let after = middle.addingTimeInterval(6)
    let x = geometry.x(at: middle)

    // Equidistant candidates must resolve identically whichever order they arrive in, or a re-sorted
    // marker list would move the playhead by a frame for no reason the user can see.
    let a = geometry.snappedInstant(atX: x, candidates: [before, after], tolerance: 6)
    let b = geometry.snappedInstant(atX: x, candidates: [after, before], tolerance: 6)
    #expect(a == b)
    #expect(a == before, "ties should go to the earlier instant")
}

@Test func timelineRulerWholeMinutesAreBoundedAndOnTheMinute() throws {
    let index = TimelineFixture.mockupIndex()
    let window = TimelineWindow.fitting(index.day, zoom: .day)
    let minutes = TimelineRuler.wholeMinutes(in: window, day: index.day)
    #expect(minutes.count <= TimelineRuler.magnetismCandidateLimit)
    #expect(!minutes.isEmpty)
    for instant in minutes {
        let offset = index.day.offset(of: instant)
        #expect(abs(offset.truncatingRemainder(dividingBy: 60)) < 1e-6)
    }
}

// MARK: - Playback rate

@Test func timelinePlaybackRateSliderMappingIsExactlyInvertible() throws {
    // A slider whose knob does not return to where it was put is the most visible kind of broken
    // control, so this round trip must be exact for every stop.
    for rate in TimelinePlaybackRate.forwardStops {
        let position = rate.sliderPosition
        #expect(position >= 0 && position <= 1)
        #expect(TimelinePlaybackRate(sliderPosition: position) == rate, "\(rate) round trip")
    }
    // The ends of the travel are the ends of the ladder.
    #expect(TimelinePlaybackRate(sliderPosition: 0) == .quarter)
    #expect(TimelinePlaybackRate(sliderPosition: 1) == .octuple)
    #expect(TimelinePlaybackRate.normal.sliderPosition == 0.4)
    // Nonsense and out-of-range positions degrade rather than trapping.
    #expect(TimelinePlaybackRate(sliderPosition: .nan) == .normal)
    #expect(TimelinePlaybackRate(sliderPosition: -5) == .quarter)
    #expect(TimelinePlaybackRate(sliderPosition: 99) == .octuple)
    // Equal spacing: every stop is equally easy to hit.
    let positions = TimelinePlaybackRate.forwardStops.map(\.sliderPosition)
    let gaps = zip(positions, positions.dropFirst()).map { $1 - $0 }
    #expect(gaps.allSatisfy { abs($0 - (gaps.first ?? 0)) < 1e-9 })
}

@Test func timelinePlaybackRateShuttleWalksTheLadderAndStopsAtBothEnds() throws {
    var rate = TimelinePlaybackRate.normal
    for _ in 0..<10 { rate = rate.shuttled(by: 1) }
    #expect(rate == .octuple)
    for _ in 0..<20 { rate = rate.shuttled(by: -1) }
    #expect(rate == .reverseEight)
    // The shuttle ladder deliberately omits ¼× and ½×; entering it from one of those goes to the
    // nearest stop rather than doing nothing.
    #expect(TimelinePlaybackRate.half.shuttled(by: 1) == .double)
    #expect(TimelinePlaybackRate.normal.shuttled(by: -1) == .reverseOne)
}

@Test func timelinePlaybackRateReportsMutingAndFrameDroppingHonestly() throws {
    // UX.md §7.5: above 2× audio mutes automatically. FEATURES.md §13: above 2× the decoder drops
    // non-reference frames.
    #expect(!TimelinePlaybackRate.normal.mutesAudio)
    #expect(!TimelinePlaybackRate.double.mutesAudio, "exactly 2× is not ABOVE 2×")
    #expect(TimelinePlaybackRate.quadruple.mutesAudio)
    #expect(TimelinePlaybackRate.reverseOne.mutesAudio, "reverse has no meaningful audio")
    #expect(!TimelinePlaybackRate.double.dropsNonReferenceFrames)
    #expect(TimelinePlaybackRate.quadruple.dropsNonReferenceFrames)
    #expect(TimelinePlaybackRate.reverseFour.dropsNonReferenceFrames)
    // Scales match the RTSP Scale: values FEATURES.md §13 lists.
    #expect(TimelinePlaybackRate.forwardStops.map(\.scale) == [0.25, 0.5, 1, 2, 4, 8])
    #expect(TimelinePlaybackRate.allCases.filter(\.isReverse).map(\.scale) == [-8, -4, -2, -1])
}

// MARK: - Month grid

@Test func timelineMonthGridAlignsWeeksAndKeepsUnknownDistinctFromEmpty() throws {
    let clock = TimelineFixture.clock(zone: TimelineTZ.utc, year: 2026, month: 7, day: 26)
    // Only some days reported: day 1 empty, day 2 recorded, the rest unknown. The three states must
    // stay distinguishable — spec-isapi.md §15.5 requires an unresolved day to render as "unknown",
    // never as "empty".
    var days = [MonthRecordCalendar.DayState?](repeating: nil, count: 31)
    days[0] = .empty
    days[1] = .recorded([.timing, .alarm])
    let calendar = MonthRecordCalendar(year: 2026, month: 7, track: TrackID(101), days: days)
    let grid = try #require(TimelineMonthGrid.build(year: 2026, month: 7, calendar: calendar,
                                                   selected: clock.today, clock: clock))

    #expect(grid.weeks.allSatisfy { $0.count == 7 }, "every row must have seven cells")
    #expect(grid.weeks.count >= 4 && grid.weeks.count <= 6)
    #expect(grid.days.count == 31, "July has 31 days")
    #expect(grid.days.map(\.day) == Array(1...31).map { Optional($0) })

    let first = try #require(grid.days.first)
    #expect(first.isKnownEmpty)
    #expect(!first.hasFootage)
    let second = grid.days[1]
    #expect(second.hasFootage)
    #expect(second.dominantType == .alarm, "the most severe type colours the dot")
    let third = grid.days[2]
    #expect(third.state == nil, "an unresolved day must stay unknown")
    #expect(!third.isKnownEmpty, "unknown must NOT read as empty")
    #expect(!third.hasFootage)

    // Exactly one selected cell, and it is the 26th.
    #expect(grid.days.filter(\.isSelected).count == 1)
    #expect(grid.days.first(where: \.isSelected)?.day == 26)
    #expect(grid.days.first(where: \.isToday)?.day == 26)
}

@Test func timelineMonthGridRespectsTheCalendarsFirstWeekday() throws {
    var sundayFirst = timelineCalendar(TimelineTZ.utc)
    sundayFirst.firstWeekday = 1
    var mondayFirst = timelineCalendar(TimelineTZ.utc)
    mondayFirst.firstWeekday = 2
    let now = Date(timeIntervalSince1970: 1_784_000_000)

    let sunday = try #require(TimelineMonthGrid.build(
        year: 2026, month: 7, calendar: nil, selected: nil,
        clock: TimelineClock(calendar: sundayFirst, now: now, locale: timelineTestLocale)))
    let monday = try #require(TimelineMonthGrid.build(
        year: 2026, month: 7, calendar: nil, selected: nil,
        clock: TimelineClock(calendar: mondayFirst, now: now, locale: timelineTestLocale)))

    // 1 July 2026 is a Wednesday: three blanks in a Sunday-first month, two in a Monday-first one.
    let sundayLeading = sunday.weeks[0].prefix { $0.isBlank }.count
    let mondayLeading = monday.weeks[0].prefix { $0.isBlank }.count
    #expect(sundayLeading == 3)
    #expect(mondayLeading == 2)
    // Blank ids must be distinct or SwiftUI collapses them and the month loses its shape.
    let blanks = sunday.weeks.flatMap { $0 }.filter(\.isBlank)
    #expect(Set(blanks.map(\.id)).count == blanks.count)
    #expect(TimelineMonthGrid.weekdayHeaders(
        clock: TimelineClock(calendar: mondayFirst, now: now, locale: timelineTestLocale)).count == 7)
}

@Test func timelineMonthGridHandlesFebruaryLeapYearsAndRejectsABadMonth() throws {
    let clock2028 = TimelineFixture.clock(zone: TimelineTZ.utc, year: 2028, month: 2, day: 1)
    let leap = try #require(TimelineMonthGrid.build(year: 2028, month: 2, calendar: nil,
                                                   selected: nil, clock: clock2028))
    #expect(leap.days.count == 29, "2028 is a leap year")

    let clock2026 = TimelineFixture.clock(zone: TimelineTZ.utc, year: 2026, month: 2, day: 1)
    let common = try #require(TimelineMonthGrid.build(year: 2026, month: 2, calendar: nil,
                                                     selected: nil, clock: clock2026))
    #expect(common.days.count == 28)

    #expect(TimelineMonthGrid.build(year: 2026, month: 0, calendar: nil, selected: nil,
                                    clock: clock2026) == nil)
    #expect(TimelineMonthGrid.build(year: 2026, month: 13, calendar: nil, selected: nil,
                                    clock: clock2026) == nil)
}

@Test func timelineMonthGridMarksFutureDaysAndFindsTheNearestFootage() throws {
    let clock = TimelineFixture.clock(zone: TimelineTZ.utc, year: 2026, month: 7, day: 26)
    var days = [MonthRecordCalendar.DayState?](repeating: .empty, count: 31)
    days[9] = .recorded([.timing])       // the 10th
    days[19] = .recorded([.motion])      // the 20th
    let calendar = MonthRecordCalendar(year: 2026, month: 7, track: TrackID(101), days: days)
    let grid = try #require(TimelineMonthGrid.build(year: 2026, month: 7, calendar: calendar,
                                                   selected: clock.today, clock: clock))

    // Today is the 26th, so the 27th onward are future and the 26th itself is not.
    #expect(grid.days.first(where: { $0.day == 26 })?.isFuture == false)
    #expect(grid.days.first(where: { $0.day == 27 })?.isFuture == true)
    #expect(grid.days.filter(\.isFuture).count == 5)

    // The empty-day empty state names the closest day with footage.
    #expect(grid.nearestDayWithFootage(to: 26)?.day == 20)
    #expect(grid.nearestDayWithFootage(to: 11)?.day == 10)
    // A tie goes to the earlier day: 15 is five from both the 10th and the 20th.
    #expect(grid.nearestDayWithFootage(to: 15)?.day == 10)
    #expect(grid.unknownDayCount == 0, "every non-future day was reported")
}

@Test func timelineMonthGridDistinguishesUnknownDaysFromEmptyOnes() throws {
    let clock = TimelineFixture.clock(zone: TimelineTZ.utc, year: 2026, month: 7, day: 26)
    // The device answered for the first ten days and said nothing about the rest.
    var days = [MonthRecordCalendar.DayState?](repeating: nil, count: 31)
    for index in 0..<10 { days[index] = .empty }
    days[3] = .recorded([.alarm])
    let calendar = MonthRecordCalendar(year: 2026, month: 7, track: TrackID(101), days: days)
    let grid = try #require(TimelineMonthGrid.build(year: 2026, month: 7, calendar: calendar,
                                                   selected: nil, clock: clock))

    // The 4th was answered and holds an alarm; the 5th was answered and holds nothing; the 11th
    // was not answered at all. All three are different, and only the middle one may be drawn as
    // "nothing recorded" — claiming that about the 11th would invent a fact about the camera.
    #expect(grid.days.first(where: { $0.day == 4 })?.hasFootage == true)
    #expect(grid.days.first(where: { $0.day == 4 })?.dominantType == .alarm)
    #expect(grid.days.first(where: { $0.day == 5 })?.isKnownEmpty == true)
    #expect(grid.days.first(where: { $0.day == 11 })?.isKnownEmpty == false)
    #expect(grid.days.first(where: { $0.day == 11 })?.hasFootage == false)
    #expect(grid.days.first(where: { $0.day == 11 })?.dominantType == nil)

    // Unanswered and not in the future: the 11th through the 26th, sixteen days. The five future
    // days are unanswered too but are not counted — the camera cannot have recorded tomorrow.
    #expect(grid.unknownDayCount == 16)
}

@Test func timelineMonthSteppingRollsTheYearInBothDirections() {
    // Compared field by field rather than as tuples: `#expect` expands its argument, and a tuple
    // `==` inside a macro is a needless thing to be clever about in a suite that has to compile
    // on someone else's machine.
    func step(_ year: Int, _ month: Int, by amount: Int) -> String {
        let next = TimelineMonthGrid.stepped(year: year, month: month, by: amount)
        return "\(next.year)-\(next.month)"
    }

    #expect(step(2026, 7, by: 1) == "2026-8")
    #expect(step(2026, 7, by: -1) == "2026-6")

    // The two boundaries. Stepping back from January is where a truncating `/` and a sign-taking
    // `%` both go wrong at once: `-1 / 12` truncates to 0 (keeping the year) and `-1 % 12` is -1
    // (making the month 0), so the naive version lands on a month `build` rejects.
    #expect(step(2026, 1, by: -1) == "2025-12")
    #expect(step(2026, 12, by: 1) == "2027-1")

    // Whole years and more, in both directions.
    #expect(step(2026, 1, by: -12) == "2025-1")
    #expect(step(2026, 1, by: -13) == "2024-12")
    #expect(step(2026, 12, by: 13) == "2028-1")
    #expect(step(2026, 7, by: 0) == "2026-7")

    // Every result is a month `build` will accept, from every starting month and every step in a
    // three-year range either way. This is the property that matters: the picker's arrows must
    // never produce a month the grid refuses, because that shows as a button that does nothing.
    for month in 1...12 {
        for step in -36...36 {
            let next = TimelineMonthGrid.stepped(year: 2026, month: month, by: step)
            #expect((1...12).contains(next.month),
                    "month \(month) stepped by \(step) gave \(next.month)")
            // The step is exactly `step` months away, counted in absolute months.
            #expect(next.year * 12 + next.month - 1 == 2026 * 12 + month - 1 + step)
        }
    }
}

#endif  // os(macOS)
