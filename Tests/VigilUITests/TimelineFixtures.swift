//
//  TimelineFixtures.swift
//  VigilUITests
//
//  Builders for the archive-timeline tests: synthesised segments, days in named time zones, and the
//  frozen clocks the DST cases need.
//  macOS-only. Supports Tests/VigilUITests/Timeline*.swift.
//
//  ⚠️ Every segment here is SYNTHESISED, not captured from hardware. The shapes are modelled on what
//  docs/spec-isapi.md §15 says a Hikvision search returns — a continuous run split into files, an
//  event clip a few seconds long, adjacent files that abut exactly — but no value in this file came
//  off a device and none should be cited as evidence about one. What the tests here verify is the
//  arithmetic, which is ours.
//

#if os(macOS)

import Foundation
import Testing

import VigilISAPI
import VigilProtocols

@testable import VigilUI

// MARK: - Time zones

/// Fixture time zones, resolved once.
enum TimelineTZ {

    /// A zone that observes daylight saving, for the DST cases. The customer's zone class.
    static let newYork = TimeZone(identifier: "America/New_York")

    /// A zone that does not, as the control.
    static let utc = TimeZone(identifier: "UTC")

    /// A southern-hemisphere DST zone, so the transition directions are exercised the other way
    /// round in the same calendar year.
    static let sydney = TimeZone(identifier: "Australia/Sydney")
}

/// A Gregorian calendar in `zone`, or in UTC when the identifier was unavailable.
///
/// A nil zone would make every DST assertion silently pass against UTC, so each DST test
/// `#require`s its zone before relying on it rather than trusting this fallback.
func timelineCalendar(_ zone: TimeZone?) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    if let zone { calendar.timeZone = zone }
    return calendar
}

/// The locale every fixture formats in unless a test says otherwise.
///
/// ⛔ Explicit, never `.current`. `TimelineClock`'s locale defaults to the system's, which is correct
/// for the app and fatal for a test: this container's locale decides 12- versus 24-hour output, so a
/// test that let it default would assert `"09:05"` here and `"9:05 AM"` on a US reviewer's machine.
/// Fixed at `en_GB`, which is 24-hour, with ``TimelineFixture/twelveHourClock(_:)`` for the other
/// path.
let timelineTestLocale = Locale(identifier: "en_GB")

// MARK: - TimelineFixture

/// Fixture builders.
enum TimelineFixture {

    /// A clock in `zone` whose "now" is the given local date and time.
    static func clock(zone: TimeZone?, year: Int, month: Int, day: Int,
                      hour: Int = 12, minute: Int = 0,
                      locale: Locale = timelineTestLocale,
                      hourPreference: TimelineHourPreference = .system) -> TimelineClock {
        let calendar = timelineCalendar(zone)
        var parts = DateComponents()
        parts.year = year
        parts.month = month
        parts.day = day
        parts.hour = hour
        parts.minute = minute
        let now = calendar.date(from: parts) ?? Date(timeIntervalSince1970: 0)
        return TimelineClock(calendar: calendar, now: now,
                             locale: locale, hourPreference: hourPreference)
    }

    /// A UTC clock at 2026-07-26 12:00, the mockup's day. The default for cases that do not care
    /// about the zone.
    static func utcClock() -> TimelineClock {
        clock(zone: TimelineTZ.utc, year: 2026, month: 7, day: 26)
    }

    /// The same clock forced onto a 12-hour cycle, for the hour-preference tests.
    static func twelveHourClock() -> TimelineClock {
        clock(zone: TimelineTZ.utc, year: 2026, month: 7, day: 26,
              locale: Locale(identifier: "en_US"), hourPreference: .twelveHour)
    }

    /// A Russian clock, for the localisation tests.
    static func russianClock() -> TimelineClock {
        clock(zone: TimelineTZ.utc, year: 2026, month: 7, day: 26,
              locale: Locale(identifier: "ru_RU"))
    }

    /// One synthesised segment, `start` and `end` given as seconds from `day`'s start.
    ///
    /// The locator is built by ``PlaybackLocator/init(track:start:end:)`` — the real synthesising
    /// initialiser the scrubber uses for direct seeks — so the segments carry genuine locators rather
    /// than doubles.
    static func segment(day: TimelineDay, from: Double, to: Double,
                        type: RecordType = .timing, track: Int = 101) -> RecordSegment {
        let start = day.instant(atOffset: from)
        let end = day.instant(atOffset: to)
        return RecordSegment(track: TrackID(track),
                             start: start,
                             end: end,
                             codec: VideoCodecWire(raw: "H.265"),
                             contentType: "video",
                             recordType: type,
                             locator: PlaybackLocator(track: TrackID(track), start: start, end: end))
    }

    /// A segment given as absolute instants, for the midnight-spanning cases.
    static func segment(from: Date, to: Date, type: RecordType = .timing,
                        track: Int = 101) -> RecordSegment {
        RecordSegment(track: TrackID(track),
                      start: from,
                      end: to,
                      codec: VideoCodecWire(raw: "H.265"),
                      contentType: "video",
                      recordType: type,
                      locator: PlaybackLocator(track: TrackID(track), start: from, end: to))
    }

    /// Hours and minutes as seconds, so the fixtures read like clock times.
    static func at(_ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Double {
        Double(hour) * 3_600 + Double(minute) * 60 + Double(second)
    }

    /// The mockup's day: 09:00–11:00 with the shape the approved design shows — continuous runs
    /// broken by motion, two real gaps, and a short alarm clip that is sub-pixel at a wide zoom.
    ///
    /// Offsets are seconds from the day's start, so this fixture is DST-agnostic and can be built on
    /// any day.
    static func mockupDay(_ day: TimelineDay) -> [RecordSegment] {
        [
            segment(day: day, from: at(9, 0), to: at(9, 12), type: .timing),
            segment(day: day, from: at(9, 12), to: at(9, 14), type: .motion),
            // Gap 09:14 → 09:20
            segment(day: day, from: at(9, 20), to: at(9, 22), type: .motion),
            segment(day: day, from: at(9, 22), to: at(9, 34), type: .timing),
            // A 20-second alarm: 0.28 pt at the 24 h zoom across 1 200 pt. The minimum-width rule
            // exists for exactly this segment.
            segment(day: day, from: at(9, 34), to: at(9, 34, 20), type: .alarm),
            segment(day: day, from: at(9, 35), to: at(9, 48), type: .timing),
            // Gap 09:48 → 10:02
            segment(day: day, from: at(10, 2), to: at(10, 30), type: .timing),
            segment(day: day, from: at(10, 30), to: at(10, 44), type: .motion),
            segment(day: day, from: at(10, 44), to: at(11, 0), type: .timing),
        ]
    }

    /// An index over ``mockupDay(_:)``.
    static func mockupIndex(clock: TimelineClock = utcClock()) -> TimelineSegmentIndex {
        let day = clock.today
        return TimelineSegmentIndex(raw: mockupDay(day), day: day)
    }

    /// A day that is one unbroken recording from its first instant to its last.
    static func continuousIndex(clock: TimelineClock = utcClock()) -> TimelineSegmentIndex {
        let day = clock.today
        let whole = segment(from: day.start, to: day.end, type: .timing)
        return TimelineSegmentIndex(raw: [whole], day: day)
    }

    /// A day with nothing on it.
    static func emptyIndex(clock: TimelineClock = utcClock()) -> TimelineSegmentIndex {
        TimelineSegmentIndex(raw: [], day: clock.today)
    }

    /// A geometry over the whole of `index`'s day at `width` points.
    static func dayGeometry(_ index: TimelineSegmentIndex,
                            width: Double = 1_200) -> TimelineGeometry {
        let window = TimelineWindow(start: index.day.start, zoom: .day).clamped(to: index.day)
        return TimelineGeometry(window: window, width: width)
    }

    /// A geometry over one hour of `index`'s day starting at `hour` local.
    static func hourGeometry(_ index: TimelineSegmentIndex, hour: Int,
                             width: Double = 1_200) -> TimelineGeometry {
        let window = TimelineWindow(start: index.day.instant(atOffset: at(hour)), zoom: .hour)
            .clamped(to: index.day)
        return TimelineGeometry(window: window, width: width)
    }
}

#endif  // os(macOS)
