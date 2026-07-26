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
    let clock = TimelineClock(calendar: timelineCalendar(zone), now: Date(timeIntervalSince1970: 0),
                              locale: timelineTestLocale)
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
    let clock = TimelineClock(calendar: timelineCalendar(zone), now: Date(timeIntervalSince1970: 0),
                              locale: timelineTestLocale)
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
    let clock = TimelineClock(calendar: timelineCalendar(zone), now: Date(timeIntervalSince1970: 0),
                              locale: timelineTestLocale)
    // Sydney ends DST on 5 April 2026 (a 25-hour day) and starts it on 4 October (a 23-hour day) —
    // the opposite order to the northern hemisphere, which catches any code that assumed the sign.
    let april = try #require(clock.day(year: 2026, month: 4, day: 5))
    let october = try #require(clock.day(year: 2026, month: 10, day: 4))
    #expect(april.spanSeconds == 90_000)
    #expect(october.spanSeconds == 82_800)
}

@Test func timelineClockReportsExactlyTwentyFourHoursInAZoneWithoutDaylightSaving() throws {
    let zone = try #require(TimelineTZ.utc)
    let clock = TimelineClock(calendar: timelineCalendar(zone), now: Date(timeIntervalSince1970: 0),
                              locale: timelineTestLocale)
    for month in 1...12 {
        let day = try #require(clock.day(year: 2026, month: month, day: 15))
        #expect(day.spanSeconds == 86_400, "UTC month \(month) should be 24 h")
        #expect(!day.hasDaylightSavingTransition)
    }
}

// MARK: - The window on a short day

@Test func timelineWindowClampsTheDayZoomToATwentyThreeHourDay() throws {
    let zone = try #require(TimelineTZ.newYork)
    let clock = TimelineClock(calendar: timelineCalendar(zone), now: Date(timeIntervalSince1970: 0),
                              locale: timelineTestLocale)
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

@Test func timelineWindowFitsTheDayZoomToATwentyFiveHourDay() throws {
    let zone = try #require(TimelineTZ.newYork)
    let clock = TimelineClock(calendar: timelineCalendar(zone), now: Date(timeIntervalSince1970: 0),
                              locale: timelineTestLocale)
    let day = try #require(clock.day(year: 2026, month: 11, day: 1))
    #expect(day.spanSeconds == 90_000)

    // `fitting` resolves the `.day` stop's nominal 86 400 s to the day's TRUE 90 000 s. Without it the
    // day's last hour of footage sits off the right-hand edge of a bar whose control says "24 h" and
    // whose ⌘0 claims to fit the day. This is the bug the first version of this test caught.
    let fitted = TimelineWindow.fitting(day, zoom: .day)
    #expect(fitted.spanSeconds == 90_000)
    #expect(fitted.start == day.start)
    #expect(fitted.end == day.end)

    let geometry = TimelineGeometry(window: fitted, width: 1_200)
    #expect(geometry.x(at: day.end) == 1_200)
    #expect(geometry.x(at: day.start) == 0)

    // And the distinction `clamped` deliberately keeps: a genuine 24-hour span on a 25-hour day is
    // NOT widened — it stays 24 hours and becomes scrollable by the spare hour, which is correct for a
    // span the caller actually asked for.
    let plain = TimelineWindow(start: day.start, spanSeconds: 86_400).clamped(to: day)
    #expect(plain.spanSeconds == 86_400)
    #expect(plain.end < day.end)
    #expect(plain.scrolled(bySeconds: 7_200, in: day).end == day.end,
            "the spare hour must be reachable by scrolling")
}

@Test func timelineWindowFitsTheDayZoomToEveryDayLengthAtBothTransitions() throws {
    let zone = try #require(TimelineTZ.newYork)
    let clock = TimelineClock(calendar: timelineCalendar(zone), now: Date(timeIntervalSince1970: 0),
                              locale: timelineTestLocale)
    // The invariant that matters, stated once for all three day lengths: fitting the `.day` stop
    // always spans exactly the day, so the bar's two ends are always the day's two ends.
    for (month, dayOfMonth, expected) in [(3, 8, 82_800.0), (7, 26, 86_400.0), (11, 1, 90_000.0)] {
        let day = try #require(clock.day(year: 2026, month: month, day: dayOfMonth))
        #expect(day.spanSeconds == expected, "\(month)/\(dayOfMonth) span")
        let window = TimelineWindow.fitting(day, zoom: .day)
        #expect(window.start == day.start)
        #expect(window.end == day.end)
        #expect(window.spanSeconds == expected)
        let geometry = TimelineGeometry(window: window, width: 1_000)
        #expect(geometry.x(at: day.start) == 0)
        #expect(geometry.x(at: day.end) == 1_000)
    }
}

@Test func timelineWindowScrollStaysInsideAShortDay() throws {
    let zone = try #require(TimelineTZ.newYork)
    let clock = TimelineClock(calendar: timelineCalendar(zone), now: Date(timeIntervalSince1970: 0),
                              locale: timelineTestLocale)
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
    let clock = TimelineClock(calendar: timelineCalendar(zone), now: Date(timeIntervalSince1970: 0),
                              locale: timelineTestLocale)
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
    let clock = TimelineClock(calendar: timelineCalendar(zone), now: Date(timeIntervalSince1970: 0),
                              locale: timelineTestLocale)
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
    let clock = TimelineFixture.utcClock()          // en_GB — a 24-hour locale
    let day = clock.today
    #expect(clock.hourMinute(day.instant(atOffset: TimelineFixture.at(9, 5))) == "09:05")
    #expect(clock.hourMinute(day.instant(atOffset: TimelineFixture.at(0, 0))) == "00:00")
    #expect(clock.hourMinute(day.instant(atOffset: TimelineFixture.at(23, 59))) == "23:59")
    #expect(clock.hourMinuteSecond(day.instant(atOffset: TimelineFixture.at(14, 22, 7)))
            == "14:22:07")
    #expect(clock.minuteSecond(day.instant(atOffset: TimelineFixture.at(14, 22, 7))) == "22:07")
    // The mockup's playhead bubble: centiseconds.
    let instant = day.instant(atOffset: TimelineFixture.at(10, 14, 38) + 0.20)
    #expect(clock.timecode(instant) == "10:14:38.20")
}

@Test func timelineClockHonoursTheTwelveHourPreferenceInEveryReadout() throws {
    // The defect this pins: labels were assembled by hand as `HH:mm` and were therefore 24-hour for
    // everyone, showing `14:00` to a customer whose Mac says `2 PM` everywhere else
    // (docs/UX.md §14.1 rule 12).
    //
    // ⚠️ Asserted piecewise rather than against a whole literal, because `Date.FormatStyle` separates
    // the time from the meridiem with U+202F NARROW NO-BREAK SPACE, not U+0020. A literal `"2:22 PM"`
    // typed with an ordinary space does not compare equal to the output — the first draft of this test
    // failed with two strings that printed identically, which is a genuinely nasty half-hour. Any
    // production code that compares a formatted time to a literal has the same trap waiting.
    let clock = TimelineFixture.twelveHourClock()
    let day = clock.today
    let afternoon = day.instant(atOffset: TimelineFixture.at(14, 22, 7))
    let narrowSpace = "\u{202F}"

    #expect(clock.hourMinute(afternoon) == "2:22\(narrowSpace)PM")
    #expect(clock.hourMinuteSecond(afternoon) == "2:22:07\(narrowSpace)PM")
    #expect(clock.hour(afternoon) == "2\(narrowSpace)PM")
    // The timecode too — and note it is now three characters wider than the 92 pt reserved field
    // DESIGN.md §4.4 sizes for `HH:mm:ss.SS`. Reported, not silently truncated.
    #expect(clock.timecode(day.instant(atOffset: TimelineFixture.at(10, 14, 38) + 0.20))
            == "10:14:38.20\(narrowSpace)AM")
}

@Test func timelineClockForcesTwentyFourHourOnATwelveHourLocaleWhenAsked() throws {
    // The other direction: an operator on a US Mac who wants 24-hour, which is the common request
    // from security staff whose written logs are 24-hour.
    let clock = TimelineFixture.clock(zone: TimelineTZ.utc, year: 2026, month: 7, day: 26,
                                      locale: Locale(identifier: "en_US"),
                                      hourPreference: .twentyFourHour)
    let afternoon = clock.today.instant(atOffset: TimelineFixture.at(14, 22, 7))
    #expect(clock.hourMinute(afternoon) == "14:22")
    #expect(clock.hourPreference == .twentyFourHour)

    // And `.system` on the same locale leaves it 12-hour, so the preference really is doing the work.
    let system = TimelineFixture.clock(zone: TimelineTZ.utc, year: 2026, month: 7, day: 26,
                                       locale: Locale(identifier: "en_US"),
                                       hourPreference: .system)
    #expect(system.hourMinute(afternoon) == "2:22\u{202F}PM")
}

@Test func timelineZoomLabelsLocaliseTheirUnitRatherThanHardCodingIt() throws {
    // The defect this pins: the ladder returned `"24 h"` / `"30 m"` as plain Strings with a comment
    // claiming they were "identical in every locale". Russian abbreviates hours as `ч` and minutes as
    // `мин`, so nine unit letters were unreachable from any .strings file.
    let english = Locale(identifier: "en_GB")
    let russian = Locale(identifier: "ru_RU")

    // English still reads as it did.
    #expect(TimelineZoom.day.label(locale: english).contains("24"))
    #expect(TimelineZoom.thirtyMinutes.label(locale: english).contains("30"))

    // Russian gets its own units, with no key to translate and no English fallback.
    let ruDay = TimelineZoom.day.label(locale: russian)
    let ruHalfHour = TimelineZoom.thirtyMinutes.label(locale: russian)
    #expect(ruDay.contains("ч"), "expected a Russian hour unit, got \(ruDay)")
    #expect(ruHalfHour.contains("мин"), "expected a Russian minute unit, got \(ruHalfHour)")
    #expect(ruDay != TimelineZoom.day.label(locale: english))

    // Every stop below an hour reads in minutes and every stop at or above one reads in hours, in
    // both locales — so no stop shows "0 h" or "60 m".
    for zoom in TimelineZoom.allCases {
        for locale in [english, russian] {
            let label = zoom.label(locale: locale)
            #expect(!label.isEmpty)
            #expect(!label.hasPrefix("0"), "\(zoom) formatted as \(label)")
        }
    }
    #expect(TimelineZoom.hour.label(locale: english) != TimelineZoom.minute.label(locale: english))
}

@Test func timelineRulerLabelsFollowTheClockLocaleAndHourCycle() throws {
    // The ruler is the surface UX.md §14.1 rule 12 names explicitly, so pin it end to end rather than
    // only at the formatter.
    let index = TimelineFixture.mockupIndex()
    let geometry = TimelineFixture.hourGeometry(index, hour: 9)

    let british = TimelineFixture.utcClock()
    let ticks24 = TimelineRuler.majorTicks(in: geometry, day: index.day, zoom: .hour, clock: british)
    #expect(!ticks24.isEmpty)
    #expect(ticks24.allSatisfy { ($0.label ?? "").contains(":") })
    #expect(ticks24.contains { $0.label == "09:10" })
    #expect(ticks24.allSatisfy { !($0.label ?? "").contains("AM") })

    let american = TimelineFixture.twelveHourClock()
    let ticks12 = TimelineRuler.majorTicks(in: geometry, day: index.day, zoom: .hour,
                                          clock: american)
    #expect(ticks12.count == ticks24.count, "the hour cycle must not change which ticks exist")
    #expect(ticks12.contains { $0.label == "9:10\u{202F}AM" })
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
