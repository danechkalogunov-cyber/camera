//
//  TimelineMonthGrid.swift
//  VigilUI
//
//  The month calendar behind the date navigator: a week-aligned grid of days, each carrying what is
//  known about that day's footage.
//  macOS-only. Implements docs/spec-isapi.md §15.5 and docs/UX.md §7.2 (the ⌘G popover).
//
//  THREE STATES, NOT TWO. spec-isapi.md §15.5 is explicit: "Days not yet resolved render as
//  'unknown' (a hairline outline), never as 'empty'." The month accelerator is allowed to answer
//  partially, and the lazy per-day fallback fills the rest in over two to four seconds — so during
//  that window most of the grid is *unknown*, and drawing it as "no footage" would tell the user
//  their archive is empty when it is merely unread. `MonthRecordCalendar.days` is `[DayState?]` for
//  exactly this reason and the optionality is carried all the way to the view.
//
//  The grid is week-aligned using the injected calendar's own `firstWeekday`, so a Russian or German
//  locale gets a Monday-first month without a second code path.
//

#if os(macOS)

import Foundation

import VigilISAPI

// MARK: - TimelineMonthCell

/// One box in the month grid.
package struct TimelineMonthCell: Sendable, Hashable, Identifiable {

    /// Identity for `ForEach`. Negative for the leading and trailing blanks, which must each be
    /// distinct or SwiftUI will collapse them into one and the month will lose its shape.
    package let id: Int

    /// The day of the month, 1…31, or `nil` for a blank padding cell.
    package let day: Int?

    /// The day itself, or `nil` for a blank.
    package let timelineDay: TimelineDay?

    /// What is known about the day's footage. `nil` means **not yet known** — a hairline outline, per
    /// spec-isapi.md §15.5 — and is different from `.empty`, which means the device said there is
    /// none.
    package let state: MonthRecordCalendar.DayState?

    /// Whether this is the day containing the clock's "now".
    package let isToday: Bool

    /// Whether this is the day currently being reviewed.
    package let isSelected: Bool

    /// Whether the day lies in the future, which cannot hold footage and is not selectable.
    package let isFuture: Bool

    /// Whether this cell is a blank spacer rather than a day.
    package var isBlank: Bool { day == nil }

    /// The record types present, or an empty set when the day is empty or unknown.
    ///
    /// The dot's colour comes from the most severe type present, matching the severity precedence
    /// `RecordDayIndex` uses for its minute bins (`alarm > motion > manual > command > timing`).
    package var recordTypes: Set<RecordType> {
        guard case .recorded(let types) = state else { return [] }
        return types
    }

    /// The most severe record type on the day, or `nil` when there is none.
    package var dominantType: RecordType? {
        recordTypes.max { $0.severity < $1.severity }
    }

    /// Whether the day is known to hold footage.
    package var hasFootage: Bool {
        if case .recorded = state { return true }
        return false
    }

    /// Whether the day is known to hold no footage. False while unknown.
    package var isKnownEmpty: Bool { state == .empty }
}

// MARK: - TimelineMonthGrid

/// A month, arranged into weeks for display.
package struct TimelineMonthGrid: Sendable, Hashable {

    package let year: Int
    package let month: Int

    /// The weeks, each of exactly seven cells, blanks included. Always at least four rows and at most
    /// six — a 31-day month starting on the last day of a week needs six.
    package let weeks: [[TimelineMonthCell]]

    /// Every real day, without the blanks.
    package var days: [TimelineMonthCell] { weeks.flatMap { $0 }.filter { !$0.isBlank } }

    /// How many days are still unresolved — what the popover's progress hairline reflects.
    package var unknownDayCount: Int {
        days.filter { $0.state == nil && !$0.isFuture }.count
    }

    /// Builds the grid.
    ///
    /// - Parameters:
    ///   - year: the calendar year.
    ///   - month: 1…12.
    ///   - calendar: the month's day states, or `nil` when nothing has been fetched yet — in which
    ///     case every day is unknown, which is the honest starting state.
    ///   - selected: the day being reviewed, so exactly one cell can be marked.
    ///   - clock: the calendar, time zone and "now".
    /// - Returns: the grid, or `nil` when `year`/`month` do not name a real month.
    package static func build(year: Int, month: Int,
                              calendar: MonthRecordCalendar?,
                              selected: TimelineDay?,
                              clock: TimelineClock) -> TimelineMonthGrid? {
        guard (1...12).contains(month) else { return nil }
        guard let first = clock.day(year: year, month: month, day: 1) else { return nil }
        guard let range = clock.calendar.range(of: .day, in: .month, for: first.start) else {
            return nil
        }
        let dayCount = range.count
        let firstWeekday = clock.calendar.component(.weekday, from: first.start)
        // `firstWeekday` is 1-based from Sunday; the calendar's own `firstWeekday` says which of those
        // opens a row. The modulo keeps the result in 0…6 for every combination.
        let leading = ((firstWeekday - clock.calendar.firstWeekday) + 7) % 7
        let today = clock.today

        var cells: [TimelineMonthCell] = []
        for blank in 0..<leading {
            // Negative, distinct ids: see TimelineMonthCell.id.
            cells.append(TimelineMonthCell(id: -1 - blank, day: nil, timelineDay: nil, state: nil,
                                           isToday: false, isSelected: false, isFuture: false))
        }
        for day in 1...dayCount {
            let timelineDay = clock.day(year: year, month: month, day: day)
            let state = calendar.flatMap { source -> MonthRecordCalendar.DayState? in
                guard source.year == year, source.month == month,
                      day - 1 < source.days.count else { return nil }
                return source.days[day - 1]
            }
            cells.append(TimelineMonthCell(
                id: day,
                day: day,
                timelineDay: timelineDay,
                state: state,
                isToday: timelineDay.map { $0.start == today.start } ?? false,
                isSelected: selected.map { $0.start == timelineDay?.start } ?? false,
                // Strictly after today's start: today itself is never "future" even though most of it
                // may be, because footage from this morning is real and selectable.
                isFuture: timelineDay.map { $0.start > today.start } ?? false))
        }
        // Trailing blanks to complete the last week, so every row has seven cells and the grid does
        // not have to special-case its last row.
        var trailing = 0
        while cells.count % 7 != 0 {
            cells.append(TimelineMonthCell(id: -100 - trailing, day: nil, timelineDay: nil,
                                           state: nil, isToday: false, isSelected: false,
                                           isFuture: false))
            trailing += 1
        }
        var weeks: [[TimelineMonthCell]] = []
        var index = 0
        while index < cells.count {
            weeks.append(Array(cells[index..<min(index + 7, cells.count)]))
            index += 7
        }
        return TimelineMonthGrid(year: year, month: month, weeks: weeks)
    }

    package init(year: Int, month: Int, weeks: [[TimelineMonthCell]]) {
        self.year = year
        self.month = month
        self.weeks = weeks
    }

    /// Steps a year and 1-based month by a whole number of months, rolling the year.
    ///
    /// Free-standing rather than inline in the picker's back/forward buttons so it can be tested:
    /// Swift's `%` takes the sign of the *dividend*, so stepping back from January gives `-1 % 12`
    /// = `-1`, and the naive `+ 1` turns that into month **0** — a value `build` rejects, which
    /// would show as a calendar button that does nothing on exactly one month of the year. The
    /// `+ 12` before the second `%` is what makes the result non-negative for any input.
    ///
    /// - Parameters:
    ///   - year: the calendar year.
    ///   - month: 1…12.
    ///   - months: how far to step; negative goes back. Any magnitude, not just ±1.
    /// - Returns: the year and 1-based month arrived at.
    package static func stepped(year: Int, month: Int,
                                by months: Int) -> (year: Int, month: Int) {
        let zeroBased = month - 1 + months
        // Floor division, not truncating: `-1 / 12` truncates to 0 and would leave January's
        // "previous month" in the same year as December of the year before.
        let yearsMoved = Int((Double(zeroBased) / 12).rounded(.down))
        return (year + yearsMoved, (zeroBased % 12 + 12) % 12 + 1)
    }

    /// The nearest day to `day` that is known to hold footage, searching outward.
    ///
    /// Answers the empty-day empty state, which names the closest day with footage
    /// ("The closest footage is on %@", UX.md §14.4 string 20). Ties go to the *earlier* day: a
    /// reviewer looking for something that has already happened is served better by going back.
    package func nearestDayWithFootage(to day: Int) -> TimelineMonthCell? {
        let candidates = days.filter(\.hasFootage)
        guard !candidates.isEmpty else { return nil }
        return candidates.min { a, b in
            let da = abs((a.day ?? 0) - day)
            let db = abs((b.day ?? 0) - day)
            if da != db { return da < db }
            return (a.day ?? 0) < (b.day ?? 0)
        }
    }

    /// The one-letter-or-two weekday headers, in the grid's column order.
    ///
    /// Taken from the calendar's `veryShortWeekdaySymbols` so they are localised, and rotated by
    /// `firstWeekday` so they line up with the columns rather than always starting at Sunday.
    package static func weekdayHeaders(clock: TimelineClock) -> [String] {
        let symbols = clock.calendar.veryShortWeekdaySymbols
        guard symbols.count == 7 else { return symbols }
        let offset = max(0, min(6, clock.calendar.firstWeekday - 1))
        return Array(symbols[offset...] + symbols[..<offset])
    }
}

#endif  // os(macOS)
