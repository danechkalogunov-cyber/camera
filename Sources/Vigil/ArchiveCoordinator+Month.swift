//
//  ArchiveCoordinator+Month.swift
//  Vigil
//
//  The ⌘G calendar's data: a month of days, asked of every track the camera records to.
//  macOS-only. See docs/spec-isapi.md §15.5 and docs/UX.md §7.2.
//

#if os(macOS)

import Foundation

import VigilISAPI
import VigilProtocols
import VigilUI

// MARK: - The month calendar

/// ⚠️ `internal` rather than `private` where the class calls back in: Swift's `private` reaches a
/// type's extensions within one file only.
extension ArchiveCoordinator {

    /// Shows a month in the calendar popover, fetching it if it has not been read.
    ///
    /// **Publishes before it asks.** The grid goes up straight away — from the cache when the month
    /// has been seen, otherwise as an all-unknown month — and is replaced when the device answers.
    /// `TimelineMonthGrid` draws an unanswered day differently from an empty one, so an all-unknown
    /// grid is not a lie about the camera's contents; it says "not told yet", which is true.
    ///
    /// - Parameters:
    ///   - year: the calendar year.
    ///   - month: 1…12. Out of range is ignored rather than clamped — a caller stepping past
    ///     December should have rolled the year, and silently showing January of the same year
    ///     would hide that bug behind plausible output.
    ///   - selected: the day being reviewed, so one cell can be marked.
    ///   - clock: the calendar the grid is laid out in.
    func showMonth(year: Int, month: Int, selected: TimelineDay?, clock: TimelineClock) {
        guard (1...12).contains(month) else { return }
        let slot = MonthSlot(year: year, month: month)
        visibleMonth = slot
        publishMonth(slot, selected: selected, clock: clock)
        // Cleared first so stepping from a month still being fetched to one already cached does not
        // leave the previous month's spinner running over settled content.
        isLoadingMonth = false

        guard monthCalendars[slot] == nil, let session, !myTracks.isEmpty else { return }
        isLoadingMonth = true
        monthTask?.cancel()
        let tracks = myTracks
        monthTask = Task { [weak self] in
            await self?.readMonth(session: session, tracks: tracks, slot: slot,
                                  selected: selected, clock: clock)
        }
    }

    /// Rebuilds the visible grid because the selected day moved, without re-reading the month.
    ///
    /// Stepping a day with the calendar open has to move the ring; re-fetching the month to do it
    /// would spend a round trip on information already in hand.
    func remarkMonth(selected: TimelineDay?, clock: TimelineClock) {
        guard let slot = visibleMonth else { return }
        publishMonth(slot, selected: selected, clock: clock)
    }

    /// Reads one month's day distribution and republishes the grid.
    ///
    /// A refusal is not an error the user is shown: `dailyDistribution` is an optional endpoint and
    /// plenty of firmware lacks it. The grid simply stays all-unknown, which is what the popover's
    /// own footnote already explains — far better than an alert saying the camera is broken when it
    /// is merely older than the feature.
    /// Every track is asked, and the answers are merged the same way the day's segments are: a day
    /// with footage on **any** track has footage. Asking only the first track would grey out every
    /// day that lives on 103, which is the same bug as the day view had, one zoom level out.
    private func readMonth(session: ISAPIDeviceSession,
                           tracks: [TrackID],
                           slot: MonthSlot,
                           selected: TimelineDay?,
                           clock: TimelineClock) async {
        defer { if visibleMonth == slot { isLoadingMonth = false } }
        var merged: MonthRecordCalendar?
        for track in tracks {
            guard !Task.isCancelled else { return }
            do {
                let calendar = try await session.monthCalendar(track: track,
                                                               year: slot.year,
                                                               month: slot.month)
                merged = merged?.merging(calendar) ?? calendar
            } catch {
                logger.info(.isapi, "no day distribution on track \(track) for "
                    + "\(slot.year)-\(slot.month): " + String(describing: error))
            }
        }
        guard !Task.isCancelled, let merged else { return }
        monthCalendars[slot] = merged
        logger.info(.isapi, "month \(slot.year)-\(slot.month): "
            + "\(merged.days.compactMap { $0 }.count) of 31 days answered "
            + "across \(tracks.count) track(s)")
        guard visibleMonth == slot else { return }
        publishMonth(slot, selected: selected, clock: clock)
    }

    /// Builds and publishes the grid for a slot from whatever is cached for it.
    private func publishMonth(_ slot: MonthSlot, selected: TimelineDay?, clock: TimelineClock) {
        month = TimelineMonthGrid.build(year: slot.year,
                                        month: slot.month,
                                        calendar: monthCalendars[slot],
                                        selected: selected,
                                        clock: clock)
    }
}

#endif  // os(macOS)
