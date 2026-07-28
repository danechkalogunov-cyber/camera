//
//  VTimelineMonthPicker.swift
//  VigilUI
//
//  The month calendar behind ⌘G: which days have footage, and jumping to one.
//  macOS-only. Implements docs/UX.md §7.2 (the day stepper's calendar popover) and §7.3's colours.
//

#if os(macOS)

import Foundation
import SwiftUI

import VigilISAPI

// MARK: - VTimelineMonthPicker

/// A month of days, coloured by what the device recorded on each.
///
/// **Why a calendar and not just the day stepper.** Stepping back through a week to find the day
/// something happened is six round trips and six redraws. The device answers a whole month in one
/// request (`/ContentMgmt/search/dailyDistribution`), so the calendar costs one call and turns
/// "when was it?" into a glance.
///
/// **A day the device did not mention is unknown, not empty**, and the two are drawn differently.
/// `MonthRecordCalendar` models that distinction — `DayState?` where `nil` means unanswered — and
/// losing it would tell the user "nothing was recorded on the 4th" when the truth is that the
/// camera did not say. `TimelineMonthGrid.unknownDayCount` is what the footnote counts.
@MainActor
package struct VTimelineMonthPicker: View {

    // MARK: - Stored Properties

    /// The month to draw.
    package let grid: TimelineMonthGrid

    /// The calendar and zone the day names are rendered in.
    package let clock: TimelineClock

    /// Whether the month's own index is still being fetched.
    package let isLoading: Bool

    /// Steps to the previous or next month.
    package let onSelectMonth: (Int, Int) -> Void

    /// Chooses a day. Never called for a blank cell or one in the future.
    ///
    /// ⚠️ Closing the picker is the **caller's** job, from inside this handler. The picker has no
    /// dismiss callback of its own on purpose: it is presented in a `.popover`, which already
    /// dismisses on Escape and on a click outside, and a second `.cancelAction` button in here
    /// would give Escape two claimants in the same responder chain.
    package let onSelectDay: (TimelineDay) -> Void

    // MARK: - Initialisation

    /// Creates the picker.
    package init(grid: TimelineMonthGrid,
                 clock: TimelineClock,
                 isLoading: Bool = false,
                 onSelectMonth: @escaping (Int, Int) -> Void,
                 onSelectDay: @escaping (TimelineDay) -> Void) {
        self.grid = grid
        self.clock = clock
        self.isLoading = isLoading
        self.onSelectMonth = onSelectMonth
        self.onSelectDay = onSelectDay
    }

    // MARK: - View

    package var body: some View {
        VStack(alignment: .leading, spacing: VTheme.Space.sm) {
            header
            weekdayRow
            ForEach(Array(grid.weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: VMonthMetrics.gap) {
                    ForEach(week) { cell in dayCell(cell) }
                }
            }
            footnote
        }
        .padding(VTheme.Space.md)
        .frame(width: VMonthMetrics.width)
        .background(VTheme.Color.Layer.surfaceRaised,
                    in: VTheme.Radius.shape(VTheme.Radius.lg))
        .overlay {
            VTheme.Radius.shape(VTheme.Radius.lg)
                .strokeBorder(VTheme.Color.Stroke.default)
        }
    }

    // MARK: - Private Helpers

    private var header: some View {
        HStack(spacing: VTheme.Space.xs) {
            VButton(symbol: VTheme.Symbol.stepBack,
                    style: .icon,
                    size: .sm,
                    accessibilityLabel: "Previous month",
                    action: { step(-1) })
            Text(verbatim: monthTitle)
                .vType(VTheme.Typography.headline)
                .foregroundStyle(VTheme.Color.Text.primary)
                .frame(maxWidth: .infinity)
            VButton(symbol: VTheme.Symbol.stepForward,
                    style: .icon,
                    size: .sm,
                    accessibilityLabel: "Next month",
                    action: { step(1) })
                // A month wholly in the future has nothing to show and never will.
                .disabled(isNextMonthInFuture)
        }
    }

    /// One-letter day names, in the calendar's own first-weekday order.
    ///
    /// Taken from `clock.calendar` rather than hard-coded: a Russian locale opens the week on
    /// Monday, and a grid whose header says Sunday while its cells start on Monday is off by one
    /// for every date in it.
    private var weekdayRow: some View {
        HStack(spacing: VMonthMetrics.gap) {
            ForEach(weekdaySymbols.indices, id: \.self) { index in
                Text(verbatim: weekdaySymbols[index])
                    .vType(VTheme.Typography.caption2)
                    .foregroundStyle(VTheme.Color.Text.tertiary)
                    .frame(width: VMonthMetrics.cell)
            }
        }
    }

    @ViewBuilder
    private func dayCell(_ cell: TimelineMonthCell) -> some View {
        if cell.isBlank {
            SwiftUI.Color.clear.frame(width: VMonthMetrics.cell, height: VMonthMetrics.cell)
        } else {
            Button {
                if let day = cell.timelineDay, !cell.isFuture { onSelectDay(day) }
            } label: {
                Text(verbatim: String(cell.day ?? 0))
                    .vType(VTheme.Typography.caption1Numeric)
                    .foregroundStyle(ink(for: cell))
                    .frame(width: VMonthMetrics.cell, height: VMonthMetrics.cell)
                    .background(fill(for: cell), in: VTheme.Radius.shape(VTheme.Radius.sm))
                    .overlay { selection(for: cell) }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(cell.isFuture)
            .accessibilityLabel(Text(accessibilityLabel(for: cell), bundle: .vigilUI))
        }
    }

    /// The day's fill: the dominant recording type's colour, faint enough to read a number on.
    ///
    /// ⛔ An **unknown** day gets no fill at all, not the empty day's. `hasFootage` is false for
    /// both, so keying on it alone would paint "the camera did not answer" as "nothing happened".
    private func fill(for cell: TimelineMonthCell) -> SwiftUI.Color {
        guard let type = cell.dominantType else { return .clear }
        return Self.colour(for: type).opacity(VMonthMetrics.fillOpacity)
    }

    private func ink(for cell: TimelineMonthCell) -> SwiftUI.Color {
        if cell.isFuture { return VTheme.Color.Text.disabled }
        if cell.hasFootage { return VTheme.Color.Text.primary }
        return VTheme.Color.Text.tertiary
    }

    @ViewBuilder
    private func selection(for cell: TimelineMonthCell) -> some View {
        if cell.isSelected {
            VTheme.Radius.shape(VTheme.Radius.sm)
                .strokeBorder(VTheme.Color.Semantic.accent, lineWidth: VTheme.Border.selected)
        } else if cell.isToday {
            VTheme.Radius.shape(VTheme.Radius.sm)
                .strokeBorder(VTheme.Color.Stroke.strong, lineWidth: VTheme.Border.thin)
        }
    }

    /// §7.3's own palette, so a day in the calendar and a band in the scrubber agree about what
    /// motion looks like.
    private static func colour(for type: RecordType) -> SwiftUI.Color {
        switch type {
        case .motion:           return VTheme.Color.Semantic.motion
        case .alarm:            return VTheme.Color.Semantic.danger
        default:                return VTheme.Color.Semantic.accent
        }
    }

    /// Says how many days the device would not answer for, rather than letting them read as empty.
    @ViewBuilder
    private var footnote: some View {
        if isLoading {
            Text("Reading the month…", bundle: .vigilUI)
                .vType(VTheme.Typography.caption2)
                .foregroundStyle(VTheme.Color.Text.tertiary)
        } else if grid.unknownDayCount > 0 {
            Text("Some days are unknown — the camera did not answer for them.", bundle: .vigilUI)
                .vType(VTheme.Typography.caption2)
                .foregroundStyle(VTheme.Color.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func step(_ months: Int) {
        let next = TimelineMonthGrid.stepped(year: grid.year, month: grid.month, by: months)
        onSelectMonth(next.year, next.month)
    }

    private var isNextMonthInFuture: Bool {
        let today = clock.calendar.dateComponents([.year, .month], from: clock.now)
        guard let year = today.year, let month = today.month else { return false }
        return grid.year > year || (grid.year == year && grid.month >= month)
    }

    private var monthTitle: String {
        guard let first = clock.day(year: grid.year, month: grid.month, day: 1) else { return "" }
        return VMonthChrome.monthAndYear.string(from: first.start)
    }

    private var weekdaySymbols: [String] {
        let symbols = clock.calendar.veryShortStandaloneWeekdaySymbols
        let first = clock.calendar.firstWeekday - 1
        guard symbols.count == 7, (0..<7).contains(first) else { return symbols }
        return Array(symbols[first...] + symbols[..<first])
    }

    /// What VoiceOver says for a day cell.
    ///
    /// A `LocalizedStringKey` and not a `String`: the glyph here is a bare number, so this sentence
    /// is the only thing a screen-reader user gets, and shipping it in English to a Russian locale
    /// would leave the calendar unusable for exactly the people who cannot see the colours it
    /// otherwise relies on.
    private func accessibilityLabel(for cell: TimelineMonthCell) -> LocalizedStringKey {
        guard let day = cell.day else { return "" }
        if cell.isKnownEmpty { return "\(day): nothing recorded" }
        if cell.hasFootage { return "\(day): footage" }
        return "\(day): unknown"
    }
}

// MARK: - VMonthChrome

/// Formatting for the picker. A namespace because a `DateFormatter` is expensive to rebuild.
private enum VMonthChrome {

    /// `July 2026`, in the user's own locale.
    static let monthAndYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMMy")
        return formatter
    }()
}

// MARK: - VMonthMetrics

/// The picker's sizes.
@MainActor
private enum VMonthMetrics {

    /// One day cell, square.
    static let cell: CGFloat = 30

    /// Between cells.
    static let gap: CGFloat = 4

    /// Seven cells plus their gaps plus the surrounding padding.
    static var width: CGFloat { cell * 7 + gap * 6 + VTheme.Space.md * 2 }

    /// How strongly a day's recording colour tints its cell. Faint on purpose: the number has to
    /// stay readable on top of it, and a calendar of saturated blocks is a heat map, not a date
    /// picker.
    static let fillOpacity: Double = 0.28
}

#endif  // os(macOS)
