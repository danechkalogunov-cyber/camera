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

// MARK: - TimelineHourPreference

/// Whether times are shown on a 12- or 24-hour clock.
///
/// docs/UX.md §14.1 rule 12 and the settings row at §12 make this a user preference with three
/// values, applying to "all timestamps, timeline ruler, exports". `system` is the default and is what
/// a Mac user expects: the same reading as every other app on their machine.
///
/// ⛔ Never decided by hand-formatting `HH:mm`. A US customer whose Mac shows `2 PM` everywhere else
/// must not find `14:00` here.
package enum TimelineHourPreference: Sendable, Hashable, CaseIterable {

    /// Follow the locale, which is what almost every user wants.
    case system

    /// Force 24-hour, for the operators who prefer it regardless of locale — the common request from
    /// security staff, whose written logs are 24-hour.
    case twentyFourHour

    /// Force 12-hour.
    case twelveHour

    /// The hour cycle to impose, or `nil` to leave the locale's own.
    var hourCycle: Locale.HourCycle? {
        switch self {
        case .system: nil
        case .twentyFourHour: .zeroToTwentyThree
        case .twelveHour: .oneToTwelve
        }
    }
}

// MARK: - TimelineClock

/// The archive timeline's only source of calendar facts, of "now", and of formatted local times.
///
/// Holds an injected `Calendar` — which carries the time zone the *device* records in, not
/// necessarily the viewer's — an injected instant standing for the present, and an injected `Locale`.
/// Nothing in `Timeline/` calls `Date()`, `Date.now`, reads `TimeZone.current`, or formats a time by
/// hand; they all ask this type.
///
/// A value type rather than a protocol: there is exactly one implementation, every method is a pure
/// function of the stored properties, and a test constructs one with the zone, locale and frozen
/// instant it wants.
package struct TimelineClock: Sendable {

    /// The calendar, carrying the time zone every local label and day boundary is computed in.
    package let calendar: Calendar

    /// The instant standing for "now". Injected so "is this day today" is deterministic.
    package let now: Date

    /// The locale every label is formatted in, with ``TimelineHourPreference`` already applied.
    ///
    /// Resolved once at initialisation rather than per label: applying an hour cycle builds a new
    /// `Locale` through `Locale.Components`, and doing that for each of the ruler's two dozen major
    /// ticks every redraw would be the most expensive thing on the frame path for no gain.
    package let locale: Locale

    /// The user's 12/24-hour preference, kept for the settings UI to read back.
    package let hourPreference: TimelineHourPreference

    // Format styles are built once and reused. Constructing a `Date.FormatStyle` is the costly half
    // of formatting — measured on this toolchain, reusing one style formats the ruler's 24 major
    // labels in 0.06 ms against docs/FEATURES.md §13's 4 ms redraw budget, and is very nearly twice
    // as fast as hand-assembling them from `Calendar.dateComponents`, which was the previous
    // implementation. Correct and cheaper.
    private let hourStyle: Date.FormatStyle
    private let hourMinuteStyle: Date.FormatStyle
    private let hourMinuteSecondStyle: Date.FormatStyle
    private let minuteSecondStyle: Date.FormatStyle
    private let timecodeStyle: Date.FormatStyle

    /// Creates a clock.
    ///
    /// - Parameters:
    ///   - calendar: the calendar *and* time zone to measure days in. The caller is expected to
    ///     pass the device's zone; a viewer in Berlin looking at a camera in New York must see the
    ///     camera's midnight, because that is where the device's own recording day breaks.
    ///   - now: the instant standing for the present.
    ///   - locale: the locale labels are formatted in. Defaults to the system's — this is the
    ///     injection boundary, so reading the environment *here* is legitimate in a way that reading
    ///     it inside the arithmetic never is. Every test passes one explicitly.
    ///   - hourPreference: the 12/24-hour setting.
    package init(calendar: Calendar, now: Date,
                 locale: Locale = .autoupdatingCurrent,
                 hourPreference: TimelineHourPreference = .system) {
        self.calendar = calendar
        self.now = now
        self.hourPreference = hourPreference

        var resolved = locale
        if let cycle = hourPreference.hourCycle {
            var components = Locale.Components(locale: locale)
            components.hourCycle = cycle
            resolved = Locale(components: components)
        }
        self.locale = resolved

        let base = Date.FormatStyle(locale: resolved, calendar: calendar,
                                    timeZone: calendar.timeZone)
        self.hourStyle = base.hour()
        self.hourMinuteStyle = base.hour().minute()
        self.hourMinuteSecondStyle = base.hour().minute().second()
        self.minuteSecondStyle = base
            .minute(Date.FormatStyle.Symbol.Minute.twoDigits)
            .second(Date.FormatStyle.Symbol.Second.twoDigits)
        self.timecodeStyle = base.hour().minute().second()
            .secondFraction(Date.FormatStyle.Symbol.SecondFraction.fractional(2))
    }

    /// A clock for a named time zone, falling back to UTC when the identifier is unknown.
    ///
    /// The fallback is deliberate and silent: a device that reports a zone name this build of
    /// Foundation does not know must still show a timeline, and UTC is the only defensible guess.
    /// The caller that cares can compare ``timeZone`` with what it asked for.
    package init(timeZoneIdentifier: String, now: Date,
                 locale: Locale = .autoupdatingCurrent,
                 hourPreference: TimelineHourPreference = .system) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(identifier: "UTC")
            ?? calendar.timeZone
        self.init(calendar: calendar, now: now, locale: locale, hourPreference: hourPreference)
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

    // MARK: Formatted local times

    /// The hour alone — `"09"`, or `"9 AM"` on a 12-hour clock. The 24 h zoom's ruler label.
    package func hour(_ instant: Date) -> String {
        instant.formatted(hourStyle)
    }

    /// Hour and minute — `"09:05"`, or `"9:05 AM"` on a 12-hour clock.
    ///
    /// Formatted through `Date.FormatStyle`, never assembled by hand, so it honours the locale's hour
    /// cycle and the user's ``TimelineHourPreference``. The previous implementation concatenated
    /// zero-padded components and always produced 24-hour output, which showed `14:00` to a customer
    /// whose Mac says `2 PM` everywhere else (UX.md §14.1 rule 12).
    package func hourMinute(_ instant: Date) -> String {
        instant.formatted(hourMinuteStyle)
    }

    /// Hour, minute and second — `"14:22:07"`, or `"2:22:07 PM"`.
    package func hourMinuteSecond(_ instant: Date) -> String {
        instant.formatted(hourMinuteSecondStyle)
    }

    /// Minute and second, both zero-padded — `"22:07"`. The 1 min zoom's ruler label, where the hour
    /// is already established by the lane header.
    ///
    /// Explicitly two-digit in both fields, because this label's whole job is to be comparable with
    /// the one beside it and a bare `"5:7"` is not.
    package func minuteSecond(_ instant: Date) -> String {
        instant.formatted(minuteSecondStyle)
    }

    /// The playhead bubble's timecode, to centiseconds — `"10:14:38.20"`.
    ///
    /// Centiseconds because that is what the approved mockup shows and because a frame at 25 fps is
    /// 40 ms: two decimals distinguish adjacent frames, three would imply a precision the archive
    /// seek does not have.
    ///
    /// ⚠️ On a 12-hour clock this reads `"10:14:38.20 AM"`, which is four characters wider than the
    /// 92 pt `VTheme.Typography.Reserved.timecode` field DESIGN.md §4.4 sizes for `HH:mm:ss.SS`. The
    /// reserved width is not ours to change; reported rather than silently truncated.
    package func timecode(_ instant: Date) -> String {
        instant.formatted(timecodeStyle)
    }

    /// The zoom control's readout — `"24h"`, `"30 мин"`.
    ///
    /// Delegates to ``TimelineZoom/label(locale:)``, which localises the unit through
    /// `Duration.UnitsFormatStyle` rather than hard-coding `h` and `m`.
    package func zoomLabel(_ zoom: TimelineZoom) -> String {
        zoom.label(locale: locale)
    }
}

#endif  // os(macOS)
