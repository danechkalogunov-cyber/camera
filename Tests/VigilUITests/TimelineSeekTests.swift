//
//  TimelineSeekTests.swift
//  VigilUITests
//
//  The seek arithmetic: gaps, both ends of the day, half-open boundaries, and the relative jumps.
//  macOS-only. Covers Sources/VigilUI/Timeline/TimelineSeek.swift and TimelineSegmentIndex.swift.
//
//  The ruling under test — a seek into a gap is HONOURED, not snapped — is argued in full at the top
//  of TimelineSeek.swift. These tests pin it in both directions: that the requested instant survives
//  untouched, and that playback is nonetheless armed for the next segment.
//

#if os(macOS)

import Foundation
import Testing

import VigilISAPI
import VigilProtocols

@testable import VigilUI

// MARK: - Inside a segment

@Test func timelineSeekResolvesAnInstantInsideASegmentToThatSegment() throws {
    let index = TimelineFixture.mockupIndex()
    let day = index.day
    // 09:05 is inside the first run, 09:00–09:12.
    let seek = TimelineSeek.resolve(day.instant(atOffset: TimelineFixture.at(9, 5)), in: index)

    guard case .footage(let segment, let offset) = seek.resolution else {
        Issue.record("expected footage, got \(seek.resolution)")
        return
    }
    #expect(index.segments[segment].recordType == .timing)
    #expect(offset == 300)                                  // five minutes into a 09:00 segment
    #expect(seek.resumesAt == seek.requested)
    #expect(seek.isPlayable)
    #expect(!seek.isDeferred)
    #expect(seek.deferralSeconds == 0)
}

@Test func timelineSeekPreservesTheRequestedInstantExactly() throws {
    let index = TimelineFixture.mockupIndex()
    // A deliberately awkward instant: 09:05:07.37, inside a segment.
    let requested = index.day.instant(atOffset: TimelineFixture.at(9, 5, 7) + 0.37)
    let seek = TimelineSeek.resolve(requested, in: index)
    #expect(seek.requested == requested)
}

// MARK: - THE GAP RULING

@Test func timelineSeekIntoAGapKeepsThePlayheadWhereTheUserPutIt() throws {
    let index = TimelineFixture.mockupIndex()
    let day = index.day
    // 09:16 is squarely inside the 09:14 → 09:20 gap, 120 s from either edge — far beyond the 6 pt
    // magnetism radius at any zoom, so this is a deliberate choice by the user.
    let requested = day.instant(atOffset: TimelineFixture.at(9, 16))
    let seek = TimelineSeek.resolve(requested, in: index)

    // THE RULING, first half: the playhead does not move.
    #expect(seek.requested == requested)

    guard case .gap(let gap) = seek.resolution else {
        Issue.record("expected a gap, got \(seek.resolution)")
        return
    }
    #expect(gap.start == day.instant(atOffset: TimelineFixture.at(9, 14)))
    #expect(gap.end == day.instant(atOffset: TimelineFixture.at(9, 20)))
    #expect(gap.duration == 360)
    #expect(gap.precedingSegment != nil)
    #expect(gap.followingSegment != nil)
}

@Test func timelineSeekIntoAGapArmsPlaybackAtTheFollowingSegment() throws {
    let index = TimelineFixture.mockupIndex()
    let day = index.day
    let requested = day.instant(atOffset: TimelineFixture.at(9, 16))
    let seek = TimelineSeek.resolve(requested, in: index)

    // THE RULING, second half: playback is armed forward, at the next segment's start — never
    // backward, and never at the requested instant, which the device would answer with RTSP 457.
    #expect(seek.resumesAt == day.instant(atOffset: TimelineFixture.at(9, 20)))
    #expect(seek.isPlayable)
    #expect(seek.isDeferred)
    #expect(seek.deferralSeconds == 240)                    // 09:16 → 09:20
    let segment = try #require(seek.playbackSegment)
    #expect(index.segments[segment].start == day.instant(atOffset: TimelineFixture.at(9, 20)))
}

@Test func timelineSeekIntoAGapIsIdempotentAndPixelStable() throws {
    // The property that makes the ruling defensible: the same request always gives the same answer,
    // so two clicks on the same pixel cannot disagree, and a click a pixel to the left cannot jump
    // in the opposite direction to one a pixel to the right.
    //
    // Deliberately at the ONE HOUR zoom, not the day zoom. At 24 h across 1 200 pt a point is 72 s,
    // so a ±5 pt sweep is ±6 minutes and would leave the six-minute gap entirely — the first draft of
    // this test did exactly that and failed, which is a fact about the fixture and not about the
    // code. At the hour zoom a point is 3 s and the gap is 120 pt wide, so the sweep stays inside it.
    let index = TimelineFixture.mockupIndex()
    let day = index.day
    let geometry = TimelineFixture.hourGeometry(index, hour: 9)
    #expect(geometry.secondsPerPoint == 3)
    let gapMiddleX = geometry.x(at: day.instant(atOffset: TimelineFixture.at(9, 17)))

    var previousResume: Date?
    for offset in -5...5 {
        let instant = geometry.instant(atX: gapMiddleX + Double(offset))
        let seek = TimelineSeek.resolve(instant, in: index)
        #expect(seek.requested == instant, "the playhead moved for offset \(offset)")
        if case .gap = seek.resolution {} else {
            Issue.record("offset \(offset) left the gap: \(seek.resolution)")
        }
        if let previousResume {
            // Every one of these is in the same gap, so they must all arm the same resume point.
            #expect(seek.resumesAt == previousResume)
        }
        previousResume = seek.resumesAt
        // Repeating the identical request must give the identical answer.
        #expect(TimelineSeek.resolve(instant, in: index) == seek)
    }
}

// MARK: - Before the first segment and past the last

@Test func timelineSeekBeforeTheFirstSegmentReportsBeforeFootageAndArmsTheFirst() throws {
    let index = TimelineFixture.mockupIndex()
    let day = index.day
    // The mockup day's footage starts at 09:00; 03:40 is long before it.
    let requested = day.instant(atOffset: TimelineFixture.at(3, 40))
    let seek = TimelineSeek.resolve(requested, in: index)

    guard case .beforeFootage(let first) = seek.resolution else {
        Issue.record("expected beforeFootage, got \(seek.resolution)")
        return
    }
    #expect(first == 0)
    #expect(seek.requested == requested)
    #expect(seek.resumesAt == day.instant(atOffset: TimelineFixture.at(9, 0)))
    #expect(seek.isPlayable)
    #expect(seek.isDeferred)
}

@Test func timelineSeekPastTheLastSegmentReportsAfterFootageAndArmsNothing() throws {
    let index = TimelineFixture.mockupIndex()
    let day = index.day
    // Footage ends at 11:00; 15:30 is past it.
    let requested = day.instant(atOffset: TimelineFixture.at(15, 30))
    let seek = TimelineSeek.resolve(requested, in: index)

    guard case .afterFootage(let last) = seek.resolution else {
        Issue.record("expected afterFootage, got \(seek.resolution)")
        return
    }
    #expect(last == index.segments.count - 1)
    #expect(seek.requested == requested)
    // Nothing is armed: a resume that can never fire would leave the transport waiting forever.
    #expect(seek.resumesAt == nil)
    #expect(!seek.isPlayable)
    #expect(seek.playbackSegment == nil)
    #expect(!seek.isDeferred)
}

@Test func timelineSeekClampsAnInstantBeyondTheDayIntoIt() throws {
    let index = TimelineFixture.mockupIndex()
    let day = index.day
    // A drag that ran off the right-hand edge of the bar.
    let seek = TimelineSeek.resolve(day.end.addingTimeInterval(9_999), in: index)
    #expect(seek.requested == day.end)
    // The day's end is past the last footage, so nothing plays — but it is not `outsideDay`, because
    // the user is still looking at this day.
    if case .afterFootage = seek.resolution {} else {
        Issue.record("expected afterFootage at the day's end, got \(seek.resolution)")
    }

    let early = TimelineSeek.resolve(day.start.addingTimeInterval(-9_999), in: index)
    #expect(early.requested == day.start)
}

// MARK: - Half-open boundaries: the off-by-one family

@Test func timelineSegmentIndexTreatsSegmentsAsHalfOpenAtTheirBoundaries() throws {
    let clock = TimelineFixture.utcClock()
    let day = clock.today
    // Two segments that abut exactly at 10:00:00 — the shape a device produces when it rolls a file.
    let raw = [
        TimelineFixture.segment(day: day, from: TimelineFixture.at(9, 0),
                                to: TimelineFixture.at(10, 0), type: .timing),
        TimelineFixture.segment(day: day, from: TimelineFixture.at(10, 0),
                                to: TimelineFixture.at(11, 0), type: .motion),
    ]
    let index = TimelineSegmentIndex(raw: raw, day: day)

    // No gap is invented between two segments that touch.
    #expect(index.gaps.filter { $0.duration > 0 && $0.start >= raw[0].start
                                && $0.end <= raw[1].end }.isEmpty)

    let boundary = day.instant(atOffset: TimelineFixture.at(10, 0))
    // The boundary instant belongs to the SECOND segment and to nothing in the first.
    let atBoundary = try #require(index.containing(boundary))
    #expect(index.segments[atBoundary].recordType == .motion)

    // One nanosecond earlier is still the first.
    let justBefore = try #require(index.containing(boundary.addingTimeInterval(-0.000_001)))
    #expect(index.segments[justBefore].recordType == .timing)

    // A seek exactly on the boundary lands at offset zero into the second segment — not at the very
    // end of the first, which would play nothing.
    let seek = TimelineSeek.resolve(boundary, in: index)
    guard case .footage(let segment, let offset) = seek.resolution else {
        Issue.record("expected footage at the boundary, got \(seek.resolution)")
        return
    }
    #expect(index.segments[segment].recordType == .motion)
    #expect(offset == 0)
}

@Test func timelineSegmentIndexReportsNoFootageInsideAZeroLengthSegment() throws {
    let clock = TimelineFixture.utcClock()
    let day = clock.today
    // Devices really do emit these: a recording stopped in the second it started.
    let instant = day.instant(atOffset: TimelineFixture.at(9, 0))
    let index = TimelineSegmentIndex(raw: [TimelineFixture.segment(from: instant, to: instant)],
                                    day: day)
    // The segment is kept — dropping it would make our count disagree with the device's own
    // numOfMatches — but half-open containment correctly finds nothing at that instant.
    #expect(index.segments.count == 1)
    #expect(index.containing(instant) == nil)
    let seek = TimelineSeek.resolve(instant, in: index)
    #expect(!seek.resolution.hasFootage)
}

// MARK: - Empty day, fully covered day

@Test func timelineSeekOnAnEmptyDayReportsEmptyDayAndPlaysNothing() throws {
    let index = TimelineFixture.emptyIndex()
    #expect(index.isEmpty)
    #expect(!index.isFullyCovered)
    // An empty day is ONE gap covering the whole day, not zero gaps — the bar must draw its dotted
    // baseline from end to end.
    #expect(index.gaps.count == 1)
    #expect(index.gaps[0].start == index.day.start)
    #expect(index.gaps[0].end == index.day.end)
    #expect(index.gaps[0].precedingSegment == nil)
    #expect(index.gaps[0].followingSegment == nil)
    #expect(index.coverageFraction == 0)

    let seek = TimelineSeek.resolve(index.day.instant(atOffset: TimelineFixture.at(12, 0)),
                                    in: index)
    #expect(seek.resolution == .emptyDay)
    #expect(seek.resumesAt == nil)
    #expect(!seek.isPlayable)
}

@Test func timelineSeekOnAFullyRecordedDayFindsFootageEverywhereAndHasNoGaps() throws {
    let index = TimelineFixture.continuousIndex()
    #expect(index.isFullyCovered)
    #expect(index.gaps.isEmpty, "a day recorded end to end must produce no gap, not a zero-width one")
    #expect(index.coverageFraction == 1)
    #expect(index.recordedSeconds == index.day.spanSeconds)

    // Every hour of the day has footage, including the first instant.
    for hour in 0..<24 {
        let instant = index.day.instant(atOffset: TimelineFixture.at(hour))
        #expect(index.containing(instant) != nil, "no footage at hour \(hour)")
    }
    #expect(index.containing(index.day.start) != nil)
    // The day's exclusive end has none — half-open to the last.
    #expect(index.containing(index.day.end) == nil)
}

// MARK: - Relative jumps

@Test func timelineSeekJumpsAreWallClockAndMayLandInAGap() throws {
    let index = TimelineFixture.mockupIndex()
    let day = index.day
    // 09:13:55, five seconds before the 09:14 gap opens.
    let start = TimelineSeek.resolve(day.instant(atOffset: TimelineFixture.at(9, 13, 55)),
                                     in: index)
    #expect(start.resolution.hasFootage)

    let forward = start.jumping(.tenSeconds(forward: true), in: index)
    // Ten seconds later is 09:14:05, which is in the gap. The jump is a WALL-CLOCK jump: it does not
    // skip the gap to find footage, because two presses must land twenty seconds apart and not at an
    // unpredictable distance.
    #expect(forward.requested == day.instant(atOffset: TimelineFixture.at(9, 14, 5)))
    if case .gap = forward.resolution {} else {
        Issue.record("expected the +10 s jump to land in the gap, got \(forward.resolution)")
    }
    #expect(forward.resumesAt == day.instant(atOffset: TimelineFixture.at(9, 20)))
}

@Test func timelineSeekFrameJumpUsesTheStreamRateAndSurvivesANonsenseRate() throws {
    let index = TimelineFixture.mockupIndex()
    let base = TimelineSeek.resolve(index.day.instant(atOffset: TimelineFixture.at(9, 5)), in: index)

    // Tolerance is one microsecond, not one nanosecond, and the reason is a property of `Date` rather
    // than of this code. `Date` stores a `Double` of seconds since 2001; in 2026 that magnitude is
    // ~7.9e8, where one unit in the last place is 2^29 × 2^-52 ≈ 119 ns. So no `Date` arithmetic
    // anywhere in this module can be asserted below ~1e-7 s, and a 1e-9 tolerance here fails on
    // correct code — the first draft of this test did. One microsecond is four orders of magnitude
    // below the 10 ms the playhead displays, so it is comfortably below anything a user can observe.
    let tolerance = 1e-6

    let at25 = base.jumping(.frame(forward: true, frameRate: 25), in: index)
    #expect(abs(at25.requested.timeIntervalSince(base.requested) - 0.04) < tolerance)

    // A rate of zero must not divide by zero; it degrades to 25 fps.
    let atZero = base.jumping(.frame(forward: true, frameRate: 0), in: index)
    #expect(abs(atZero.requested.timeIntervalSince(base.requested) - 0.04) < tolerance)
    let atNaN = base.jumping(.frame(forward: false, frameRate: .nan), in: index)
    #expect(abs(atNaN.requested.timeIntervalSince(base.requested) + 0.04) < tolerance)
}

@Test func timelineSegmentIndexEdgeNavigationWalksBothDirectionsWithoutSticking() throws {
    let index = TimelineFixture.mockupIndex()
    let day = index.day
    var seek = TimelineSeek.resolve(day.instant(atOffset: TimelineFixture.at(9, 5)), in: index)

    // Walking forward must strictly advance every time, and must terminate.
    var visited: [Date] = [seek.requested]
    for _ in 0..<64 {
        let next = seek.nextEdge(in: index)
        if next.requested == seek.requested { break }
        #expect(next.requested > seek.requested, "nextEdge went backwards or stalled")
        visited.append(next.requested)
        seek = next
    }
    #expect(visited.count > 4)
    // The last edge of the mockup day is 11:00.
    #expect(seek.requested == day.instant(atOffset: TimelineFixture.at(11, 0)))
    // At the final edge it is a fixed point rather than an error.
    #expect(seek.nextEdge(in: index).requested == seek.requested)

    // And back again.
    for _ in 0..<64 {
        let previous = seek.previousEdge(in: index)
        if previous.requested == seek.requested { break }
        #expect(previous.requested < seek.requested, "previousEdge went forwards or stalled")
        seek = previous
    }
    #expect(seek.requested == day.instant(atOffset: TimelineFixture.at(9, 0)))
}

// MARK: - Overlapping segments

@Test func timelineSegmentIndexDoesNotInventGapsBetweenOverlappingSegments() throws {
    let clock = TimelineFixture.utcClock()
    let day = clock.today
    // A long continuous run with a short motion clip nested inside it — two record types active at
    // once, which a Hikvision NVR really does return.
    let raw = [
        TimelineFixture.segment(day: day, from: TimelineFixture.at(9, 0),
                                to: TimelineFixture.at(10, 0), type: .timing),
        TimelineFixture.segment(day: day, from: TimelineFixture.at(9, 20),
                                to: TimelineFixture.at(9, 25), type: .motion),
    ]
    let index = TimelineSegmentIndex(raw: raw, day: day)
    // Exactly two gaps: before 09:00 and after 10:00. Nothing between.
    #expect(index.gaps.count == 2)
    #expect(index.gaps[0].end == day.instant(atOffset: TimelineFixture.at(9, 0)))
    #expect(index.gaps[1].start == day.instant(atOffset: TimelineFixture.at(10, 0)))
    // Coverage counts the overlap once.
    #expect(index.recordedSeconds == 3_600)
}

#endif  // os(macOS)
