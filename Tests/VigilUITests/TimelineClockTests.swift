//
//  TimelineClockTests.swift
//  VigilUITests
//
//  Day arithmetic across daylight saving, midnight, and a segment that spans it.
//  macOS-only. Covers Sources/VigilUI/Timeline/TimelineClock.swift and the day handling in
//  TimelineSegmentIndex.swift and TimelineWindow.swift.
//
//  THE BUG THESE TESTS EXIST TO PREVENT. A timeline that assumes a day is 86 400 s draws every
//  segment after a DST transition displaced by an hour, on two days a year, in every zone that
//  observes it. The customer is in such a zone. An hour of displacement in an archive scrubber is
//  indistinguishable from the camera having recorded the wrong thing, and the support call that
//  follows is expensive because nothing about it looks like a bug in a *timeline*.
//
//  US DST 2026: forward on 8 March (second Sunday), back on 1 November (first Sunday). Australian
//  DST 2026: back on 5 April, forward on 4 October. The tests assert the day LENGTH they got, so a
//  future tzdata change that moves a transition makes them fail loudly rather than quietly testing an
//  ordinary day.
//

#if os(macOS)

import Foundation
import Testing

import VigilISAPI
import VigilProtocols

@testable import VigilUI

// MARK: - Day length

@Test func timelineClockReportsATwentyThreeHourDayOnTheSpringForwardTransition() throws {
    let zone = try #require(TimelineTZ.newYork, "America/New_York must resolve for this test to mean anything")
    let clock = TimelineClock(calendar: timelineCalendar(zone), now: Date(timeIntervalSince1970: 0))
    let day = try #require(clock.day(year: 2026, month: 3, day: 8))

    #expect(day.spanSeconds == 82_800, "8 March 2026 in New York is 23 hours, not \(day.spanSeconds / 3600) h")
    #expect(day.hasDaylightSavingTransition)
    // Both ends are still local midnight.
    #expect(clock.wallClock(day.start).hour == 0)
    #expect(clock.wallClock(day.start).minute == 0)
    #expect(clock.wallClock(day.end).hour == 0)
    // And the day after is an ordinary one, so the transition is not leaking.
    let next = clock.day(day, offsetByDays: 1)
    #expect(next.spanSeconds == 86_400)
    #expect(next.start == day.end, "consecutive days must tile with no seam")
}

@Test func timelineClockReportsATwentyFiveHourDayOnTheFallBackTransition() throws {
    let zone = try #require(TimelineTZ.newYork)
    let clock = TimelineClock(calendar: timelineCalendar(zone), now: Date(timeIntervalSince1970: 0))
    let day = try #require(clock.day(year: 2026, month: 11, day: 1))

    #expect(day.spanSeconds == 90_000, "1 November 2026 in New York is 25 hours")
    #expect(day.hasDaylightSavingTransition)
    #expect(clock.wallClock(day.start).hour == 0)
    #expect(clock.wallClock(day.end).hour == 0)
    let previous = clock.day(day, offsetByDays: -1)
    #expect(previous.end == day.start)
}

@Test func timelineClockHandlesSouthernHemisphereTransitionsInBothDirections() throws {
    let zone = try #require(TimelineTZ.sydney)
    let clock = TimelineClock(calendar: timelineCalendar(zone), now: Date(timeIntervalSince1970: 0))
    // Sydney ends DST on 5 April 2026 (a 25-hour day) and starts it on 4 October (a 23-hour day) —
    // the opposite order to the northern hemisphere, which catches any code that assumed the sign.
    let april = try #require(clock.day(year: 2026, month: 4, day: 5))
    let october = try #require(clock.day(year: 2026, month: 10, day: 4))
    #expect(april.spanSeconds == 90_000)
    #expect(october.spanSeconds == 82_800)
}

@Test func timelineClockReportsExactlyTwentyFourHoursInAZoneWithoutDaylightSaving() throws {
    let zone = try #require(TimelineTZ.utc)
    let clock = TimelineClock(calendar: timelineCalendar(zone), now: Date(timeIntervalSince1970: 0))
    for month in 1...12 {
        let day = try #require(clock.day(year: 2026, month: month, day: 15))
        #expect(day.spanSeconds == 86_400, "UTC month \(month) should be 24 h")
        #expect(!day.hasDaylightSavingTransition)
    }
}

// MARK: - The window on a short day

@Test func timelineWindowClampsTheDayZoomToATwentyThreeHourDay() throws {
    let zone = try #require(TimelineTZ.newYork)
    let clock = TimelineClock(calendar: timelineCalendar(zone), now: Date(timeIntervalSince1970: 0))
    let day = try #require(clock.day(year: 2026, month: 3, day: 8))

    // The `.day` zoom's NOMINAL span is 86 400 s, which is an hour longer than this day.
    let window = TimelineWindow(start: day.start, zoom: .day).clamped(to: day)
    #expect(window.spanSeconds == 82_800, "the day zoom must narrow to the day's true length")
    #expect(window.start == day.start)
    #expect(window.end == day.end)

    // The consequence that matters: the LAST instant of the day maps to the right-hand edge of the
    // bar, not 4.3 % short of it. Uncorrected, every segment after 02:00 would be drawn an hour out.
    let geometry = TimelineGeometry(window: window, width: 1_200)
    #expect(geometry.x(at: day.end) == 1_200)
    #expect(geometry.x(at: day.start) == 0)
    // Local 12:00 on this day is 11 hours after midnight, not 12, because an hour was skipped.
    let noonish = day.instant(atOffset: 11 * 3_600)
    #expect(clock.wallClock(noonish).hour == 12)
}

@Test func timelineWindowClampsTheDayZoomToATwentyFiveHourDay() throws {
    let zone = try #require(TimelineTZ.newYork)
    let clock = TimelineClock(calendar: timelineCalendar(zone), now: Date(timeIntervalSince1970: 0))
    let day = try #require(clock.day(year: 2026, month: 11, day: 1))
    let window = TimelineWindow(start: day.start, zoom: .day).clamped(to: day)
    // The window WIDENS to 25 h here — the nominal 24 h would leave the last hour of the day
    // unreachable, so the day's final hour of footage could not be scrubbed to at all.
    #expect(window.spanSeconds == 90_000)
    #expect(window.end == day.end)
}

@Test func timelineWindowScrollStaysInsideAShortDay() throws {
    let zone = try #require(TimelineTZ.newYork)
    let clock = TimelineClock(calendar: timelineCalendar(zone), now: Date(timeIntervalSince1970: 0))
    let day = try #require(clock.day(year: 2026, month: 3, day: 8))
    var window = TimelineWindow(start: day.start, zoom: .hour).clamped(to: day)

    // Scroll hard right, well past the end of the day.
    for _ in 0..<40 {
        window = window.scrolled(byFractionOfSpan: 1, in: day)
    }
    #expect(window.end <= day.end)
    #expect(window.end == day.end, "scrolling to the end should rest exactly at the day's end")
    #expect(window.spanSeconds == 3_600)

    // And hard left.
    for _ in 0..<40 {
        window = window.scrolled(byFractionOfSpan: -1, in: day)
    }
    #expect(window.start == day.start)
}

// MARK: - Segments that span midnight

@Test func timelineSegmentIndexClipsASegmentSpanningMidnightOntoBothDays() throws {
    let zone = try #require(TimelineTZ.utc)
    let clock = TimelineClock(calendar: timelineCalendar(zone), now: Date(timeIntervalSince1970: 0))
    let first = try #require(clock.day(year: 2026, month: 7, day: 25))
    let second = clock.day(first, offsetByDays: 1)

    // One recording on the wire: 23:30 on the 25th to 00:30 on the 26th.
    let overnight = TimelineFixture.segment(from: first.instant(atOffset: TimelineFixture.at(23, 30)),
                                           to: second.instant(atOffset: TimelineFixture.at(0, 30)))

    let dayOne = TimelineSegmentIndex(raw: [overnight], day: first)
    let dayTwo = TimelineSegmentIndex(raw: [overnight], day: second)

    // It appears on BOTH days, clipped to each.
    #expect(dayOne.segments.count == 1)
    #expect(dayTwo.segments.count == 1)
    #expect(dayOne.segments[0].start == first.instant(atOffset: TimelineFixture.at(23, 30)))
    #expect(dayOne.segments[0].end == first.end, "the first day's half must stop at midnight")
    #expect(dayTwo.segments[0].start == second.start, "the second day's half must start at midnight")
    #expect(dayTwo.segments[0].end == second.instant(atOffset: TimelineFixture.at(0, 30)))

    // The two halves add up to the whole, with nothing lost or double-counted at the seam.
    #expect(dayOne.segments[0].duration + dayTwo.segments[0].duration == 3_600)

    // The locator is NOT rewritten by clipping — it still addresses the device's real range, because
    // PlaybackLocator's query is byte-verbatim by contract (API_CONTRACT R-29).
    #expect(dayOne.segments[0].locator == overnight.locator)
    #expect(dayTwo.segments[0].locator == overnight.locator)

    // Midnight itself belongs to the second day only — half-open, at the boundary that matters most.
    #expect(dayOne.containing(first.end) == nil)
    #expect(dayTwo.containing(second.start) != nil)
}

@Test func timelineSegmentIndexDropsSegmentsEntirelyOutsideTheDay() throws {
    let clock = TimelineFixture.utcClock()
    let day = clock.today
    let previousDay = clock.day(day, offsetByDays: -1)
    let raw = [
        // Ends exactly at this day's start: belongs to the previous day only.
        TimelineFixture.segment(from: previousDay.instant(atOffset: TimelineFixture.at(22, 0)),
                                to: day.start),
        TimelineFixture.segment(day: day, from: TimelineFixture.at(9, 0),
                                to: TimelineFixture.at(10, 0)),
    ]
    let index = TimelineSegmentIndex(raw: raw, day: day)
    #expect(index.segments.count == 1)
    #expect(index.segments[0].start == day.instant(atOffset: TimelineFixture.at(9, 0)))
}

@Test func timelineSegmentIndexCoversAShortDayCompletelyWhenFullyRecorded() throws {
    let zone = try #require(TimelineTZ.newYork)
    let clock = TimelineClock(calendar: timelineCalendar(zone), now: Date(timeIntervalSince1970: 0))
    let day = try #require(clock.day(year: 2026, month: 3, day: 8))
    let whole = TimelineFixture.segment(from: day.start, to: day.end)
    let index = TimelineSegmentIndex(raw: [whole], day: day)

    #expect(index.isFullyCovered)
    #expect(index.gaps.isEmpty)
    // 23 hours of footage on a 23-hour day is 100 % coverage, not 95.8 %. Dividing by a hard-coded
    // 86 400 here would produce the latter and would make the "23 h 00 m recorded" label disagree
    // with the coverage bar beside it.
    #expect(index.recordedSeconds == 82_800)
    #expect(index.coverageFraction == 1)
}

// MARK: - Local time rendering

@Test func timelineClockFormatsWallClockTimesZeroPaddedAndTwentyFourHour() throws {
    let clock = TimelineFixture.utcClock()
    let day = clock.today
    #expect(clock.hourMinute(day.instant(atOffset: TimelineFixture.at(9, 5))) == "09:05")
    #expect(clock.hourMinute(day.instant(atOffset: TimelineFixture.at(0, 0))) == "00:00")
    #expect(clock.hourMinute(day.instant(atOffset: TimelineFixture.at(23, 59))) == "23:59")
    #expect(clock.hourMinuteSecond(day.instant(atOffset: TimelineFixture.at(14, 22, 7)))
            == "14:22:07")
    // The mockup's playhead bubble: centiseconds.
    let instant = day.instant(atOffset: TimelineFixture.at(10, 14, 38) + 0.20)
    #expect(clock.timecode(instant) == "10:14:38.20")
}

@Test func timelineClockRendersTheSameInstantDifferentlyInTwoZones() throws {
    // The reason the calendar is injected rather than read from TimeZone.current: a viewer in one zone
    // reviewing a camera in another must see the CAMERA's clock, because that is where the device's
    // recording day breaks and what its own OSD burn-in says.
    let instant = Date(timeIntervalSince1970: 1_784_000_000)
    let utc = TimelineClock(calendar: timelineCalendar(TimelineTZ.utc), now: instant)
    let newYork = TimelineClock(calendar: timelineCalendar(TimelineTZ.newYork), now: instant)
    #expect(utc.hourMinuteSecond(instant) != newYork.hourMinuteSecond(instant))
    // And their days start at different absolute instants.
    #expect(utc.today.start != newYork.today.start)
}

@Test func timelineClockIdentifiesTodayFromTheInjectedNowAndNeverFromTheSystemClock() throws {
    let clock = TimelineFixture.clock(zone: TimelineTZ.utc, year: 2026, month: 7, day: 26, hour: 10)
    let today = clock.today
    #expect(clock.isToday(today))
    #expect(!clock.isToday(clock.day(today, offsetByDays: 1)))
    #expect(!clock.isToday(clock.day(today, offsetByDays: -1)))
    #expect(clock.localDate(today.start).day == 26)
    #expect(clock.localDate(today.start).month == 7)
    #expect(clock.localDate(today.start).year == 2026)
}

#endif  // os(macOS)
