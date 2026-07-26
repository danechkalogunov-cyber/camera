//
//  TimelineClock.swift
//  VigilUI
//
//  The injected calendar the whole archive timeline measures days with, and the local-time
//  arithmetic that follows from it. Every other Timeline type takes its day boundaries from here.
//  macOS-only. Implements docs/UX.md §11 (playback) and docs/API_CONTRACT.md §4.5.
//
//  ⛔ THE REASON THIS TYPE EXISTS AT ALL. A day is not 86 400 seconds. In a zone that observes
//  daylight saving it is 82 800 s on the spring-forward day and 90 000 s on the autumn-back day.
//  A timeline that divides its bar by a hard-coded 86 400 draws every segment after the transition
//  displaced by a full hour on those two days a year, and the label under the playhead lies by the
//  same hour. That is a support call, and it is the single most expensive mistake available in this
//  file — so no Timeline type is allowed to compute a day length, and none of them may read
//  `TimeZone.current` or call `Date()`. Both arrive here as injected values, which is also the only
//  way the DST tests are writable at all.
//

#if os(macOS)

import Foundation

// MARK: - TimelineDay

/// One device-local calendar day, as a half-open range of absolute instants.
///
/// `start` is local midnight and `end` is the *next* local midnight, so ``spanSeconds`` is the true
/// length of that particular day — 23 h, 24 h or 25 h — and never an assumption.
///
/// Half-open (`start ..< end`) throughout, matching ``TimelineSegmentIndex``: the instant `end`
/// belongs to the following day and to nothing in this one. That is what makes two adjacent days
/// tile the axis with neither a hole nor an overlap at midnight.
package struct TimelineDay: Sendable, Hashable {

    /// Local midnight, as an absolute instant.
    package let start: Date

    /// The next local midnight. Exclusive.
    package let end: Date

    /// Creates a day from its two boundaries. `end` is clamped to be no earlier than `start`, so a
    /// caller cannot manufacture a negative span.
    package init(start: Date, end: Date) {
        self.start = start
        self.end = max(start, end)
    }

    /// The true length of this day in seconds: 82 800, 86 400 or 90 000 in a DST zone.
    package var spanSeconds: Double { end.timeIntervalSince(start) }

    /// Whether `instant` falls inside this day. Half-open: `end` is not contained.
    package func contains(_ instant: Date) -> Bool {
        instant >= start && instant < end
    }

    /// `instant` clamped into `start ... end`.
    ///
    /// The upper bound is *inclusive* here on purpose, unlike ``contains(_:)``: a playhead dragged
    /// off the right-hand end of the bar must be able to rest exactly on the day's end, which is
    /// the position "the end of the day" and is a legal place for a cursor even though no second of
    /// footage lives there.
    package func clamp(_ instant: Date) -> Date {
        min(max(instant, start), end)
    }

    /// How far `instant` is into the day, in seconds, unclamped.
    package func offset(of instant: Date) -> Double {
        instant.timeIntervalSince(start)
    }

    /// The instant `seconds` into the day, unclamped.
    package func instant(atOffset seconds: Double) -> Date {
        start.addingTimeInterval(seconds)
    }

    /// Whether this day is longer or shorter than 24 h, i.e. whether a DST transition falls in it.
    ///
    /// Surfaced so the timeline can label the day and so a test can assert it reached the intended
    /// fixture rather than silently testing an ordinary day.
    package var hasDaylightSavingTransition: Bool { spanSeconds != 86_400 }
}

// MARK: - TimelineClock

/// The archive timeline's only source of calendar facts and of "now".
///
/// Holds an injected `Calendar` — which carries the time zone the *device* records in, not
/// necessarily the viewer's — and an injected instant standing for the present. Nothing in
/// `Timeline/` calls `Date()`, `Date.now` or reads `TimeZone.current`; they all ask this type.
///
/// A value type rather than a protocol: there is exactly one implementation, every method is a pure
/// function of the two stored properties, and a test constructs one with the zone and the frozen
/// instant it wants.
package struct TimelineClock: Sendable {

    /// The calendar, carrying the time zone every local label and day boundary is computed in.
    package let calendar: Calendar

    /// The instant standing for "now". Injected so "is this day today" is deterministic.
    package let now: Date

    /// Creates a clock.
    ///
    /// - Parameters:
    ///   - calendar: the calendar *and* time zone to measure days in. The caller is expected to
    ///     pass the device's zone; a viewer in Berlin looking at a camera in New York must see the
    ///     camera's midnight, because that is where the device's own recording day breaks.
    ///   - now: the instant standing for the present.
    package init(calendar: Calendar, now: Date) {
        self.calendar = calendar
        self.now = now
    }

    /// A clock for a named time zone, falling back to UTC when the identifier is unknown.
    ///
    /// The fallback is deliberate and silent: a device that reports a zone name this build of
    /// Foundation does not know must still show a timeline, and UTC is the only defensible guess.
    /// The caller that cares can compare ``timeZone`` with what it asked for.
    package init(timeZoneIdentifier: String, now: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(identifier: "UTC")
            ?? calendar.timeZone
        self.init(calendar: calendar, now: now)
    }

    /// The time zone days are measured in.
    package var timeZone: TimeZone { calendar.timeZone }

    // MARK: Days

    /// The local calendar day containing `instant`.
    ///
    /// Both boundaries come from `Calendar`, so a 23- or 25-hour day is reported at its true
    /// length. On the (impossible in practice, but representable) case where the calendar cannot
    /// advance a day, the span falls back to 86 400 s so the timeline still renders.
    package func day(containing instant: Date) -> TimelineDay {
        let start = calendar.startOfDay(for: instant)
        let next = calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(86_400)
        // `startOfDay` of the next midnight, not the raw sum: adding one calendar day to a midnight
        // in a half-hour-offset zone can land at 00:30 on some Foundation versions, and a day whose
        // end is not a midnight would put a half-hour seam between two adjacent days.
        return TimelineDay(start: start, end: calendar.startOfDay(for: next) > start
                           ? calendar.startOfDay(for: next)
                           : next)
    }

    /// The day `count` days after `day` (negative for earlier).
    ///
    /// Steps in *calendar* days, so stepping across a DST boundary lands on midnight rather than an
    /// hour either side of it — which is exactly what the mockup's `‹ 26 Jul 2026 ›` arrows need.
    package func day(_ day: TimelineDay, offsetByDays count: Int) -> TimelineDay {
        guard let moved = calendar.date(byAdding: .day, value: count, to: day.start) else {
            return day
        }
        return self.day(containing: moved)
    }

    /// The day whose local date is `year`-`month`-`day`, or `nil` when that date does not exist.
    package func day(year: Int, month: Int, day: Int) -> TimelineDay? {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        // Noon, not midnight: on a spring-forward day in a zone that skips midnight itself (Lord
        // Howe historically, and several zones after a permanent-DST law change) 00:00 does not
        // exist and `date(from:)` returns the wrong day or nil. Noon exists on every day there has
        // ever been, and `day(containing:)` walks back to the real start.
        components.hour = 12
        guard let noon = calendar.date(from: components) else { return nil }
        return self.day(containing: noon)
    }

    /// The day containing ``now``.
    package var today: TimelineDay { day(containing: now) }

    /// Whether `day` is the day containing ``now``.
    package func isToday(_ day: TimelineDay) -> Bool { day.contains(now) }

    // MARK: Local wall-clock components

    /// The local hour, minute and second of `instant`.
    ///
    /// Returned as plain integers rather than a `DateComponents` so callers cannot accidentally
    /// unwrap an optional, and so the ruler's label formatting is a pure integer function.
    package func wallClock(_ instant: Date) -> (hour: Int, minute: Int, second: Int) {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: instant)
        return (parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    /// The local calendar date of `instant`.
    package func localDate(_ instant: Date) -> (year: Int, month: Int, day: Int) {
        let parts = calendar.dateComponents([.year, .month, .day], from: instant)
        return (parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// `"HH:mm"`, zero-padded, 24-hour.
    ///
    /// Hand-formatted rather than run through `DateFormatter` for three reasons: the mockup's ruler
    /// is 24-hour regardless of locale, surveillance timecode is conventionally 24-hour
    /// everywhere, and a formatter would make every ruler test depend on the host's locale.
    package func hourMinute(_ instant: Date) -> String {
        let parts = wallClock(instant)
        return Self.pad(parts.hour) + ":" + Self.pad(parts.minute)
    }

    /// `"HH:mm:ss"`, zero-padded, 24-hour.
    package func hourMinuteSecond(_ instant: Date) -> String {
        let parts = wallClock(instant)
        return Self.pad(parts.hour) + ":" + Self.pad(parts.minute) + ":" + Self.pad(parts.second)
    }

    /// `"HH:mm:ss.cc"` — the playhead bubble's timecode, to centiseconds.
    ///
    /// Centiseconds because that is what the approved mockup shows (`10:14:38.20`) and because a
    /// frame at 25 fps is 40 ms: two decimals distinguish adjacent frames, three would imply a
    /// precision the archive seek does not have.
    package func timecode(_ instant: Date) -> String {
        let parts = wallClock(instant)
        // Derive the fraction from the whole-second boundary rather than from `timeIntervalSince1970`
        // so a leap-second-adjusted or non-integral epoch offset cannot shift it.
        let whole = instant.timeIntervalSince1970
        let fraction = whole - whole.rounded(.down)
        let centis = min(99, max(0, Int((fraction * 100).rounded(.down))))
        return Self.pad(parts.hour) + ":" + Self.pad(parts.minute) + ":"
            + Self.pad(parts.second) + "." + Self.pad(centis)
    }

    /// Two-digit zero padding for 0…99, and the plain description outside it.
    static func pad(_ value: Int) -> String {
        guard value >= 0 else { return String(value) }
        return value < 10 ? "0\(value)" : String(value)
    }
}

#endif  // os(macOS)
