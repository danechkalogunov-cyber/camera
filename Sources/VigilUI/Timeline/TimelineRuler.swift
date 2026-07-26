//
//  TimelineRuler.swift
//  VigilUI
//
//  The tick marks and labels above the bar: which instants get a tick, which get a label, and what
//  that label says. DST-aware by construction.
//  macOS-only. Implements docs/UX.md §7.3 (the nine-stop tick table) and docs/DESIGN.md §9.14.
//
//  TICKS ARE STEPPED FROM LOCAL MIDNIGHT, NOT FROM THE WINDOW'S EDGE. Stepping from the window would
//  put the first tick wherever the window happens to start — 09:03:47 — and every label would be a
//  meaningless number. Stepping from the day's own start lands every tick on a round local time, and
//  the window then simply selects the ones it can see. It also makes the tick set independent of the
//  scroll position, so panning does not make labels dance.
//
//  On DST. Ticks advance by a fixed number of *seconds* from local midnight, and each label is then
//  rendered from the calendar. That combination is deliberate and has a visible consequence worth
//  stating: on the autumn-back day the 01:00 label appears twice, an hour apart on the bar. That is
//  correct — the local hour 01:00 genuinely happens twice that day, and the archive holds two
//  distinct hours of footage that both belong to it. Labelling one of them 02:00 would be the lie.
//  Stepping by *calendar* hour instead would produce two ticks at the same pixel, or skip one,
//  depending on which side Foundation resolves the ambiguity to.
//
//  The known limitation, stated rather than hidden: in a zone whose offset shifts by a fraction of an
//  hour (Lord Howe, +30 min), ticks after the transition land on :30 rather than :00 at the hourly
//  intervals. The seek arithmetic is unaffected — only the tick positions are — and no Hikvision
//  device has ever been deployed there in this product's target market. Fixing it needs
//  calendar-stepped ticks with non-uniform pixel spacing, which costs the property above.
//

#if os(macOS)

import Foundation

// MARK: - TimelineTickLabelStyle

/// How much of the clock a tick label spells out. The "Label format" column of UX.md §7.3.
package enum TimelineTickLabelStyle: Sendable, Hashable {

    /// `"09"` — the hour alone, at the 24 h zoom where there is no room for more.
    case hour

    /// `"09:15"` — the common case.
    case hourMinute

    /// `"09:15:30"` — at the 5 min zoom, where minutes alone would repeat.
    case hourMinuteSecond

    /// `"15:30"` — minutes and seconds, at the 1 min zoom where the hour is obvious from the header.
    case minuteSecond

    /// Renders `instant` in this style using `clock`'s calendar and time zone.
    package func label(_ instant: Date, clock: TimelineClock) -> String {
        let parts = clock.wallClock(instant)
        switch self {
        case .hour:
            return TimelineClock.pad(parts.hour)
        case .hourMinute:
            return TimelineClock.pad(parts.hour) + ":" + TimelineClock.pad(parts.minute)
        case .hourMinuteSecond:
            return TimelineClock.pad(parts.hour) + ":" + TimelineClock.pad(parts.minute)
                + ":" + TimelineClock.pad(parts.second)
        case .minuteSecond:
            return TimelineClock.pad(parts.minute) + ":" + TimelineClock.pad(parts.second)
        }
    }
}

// MARK: - TimelineTick

/// One tick on the ruler.
package struct TimelineTick: Sendable, Hashable, Identifiable {

    /// Identity for `ForEach`: the tick's whole-second offset from the day's start.
    ///
    /// Unique by construction within a day, and stable across a re-layout — so a pan does not make
    /// SwiftUI tear down and rebuild every label, which at the 1 min zoom is six of them a frame.
    package let id: Int

    /// The instant the tick marks.
    package let instant: Date

    /// Its position in points from the bar's leading edge.
    package let x: Double

    /// True for a labelled tick. Majors are taller and lighter — DESIGN.md §9.14: major 1 × 6 pt
    /// `white α 0.22`, minor 1 × 3 pt `white α 0.10`.
    package let isMajor: Bool

    /// The label, or `nil` on a minor tick.
    package let label: String?
}

// MARK: - TimelineRuler

/// Generates the ruler's ticks for a window.
package enum TimelineRuler {

    /// The ticks visible in `geometry`, minors and majors together, ordered left to right.
    ///
    /// - Parameters:
    ///   - geometry: the pixel mapping. Only instants inside its window are returned.
    ///   - day: the day, whose start every tick is stepped from.
    ///   - zoom: the stop, which chooses the two intervals and the label style.
    ///   - clock: the calendar the labels are rendered in.
    /// - Returns: ticks in ascending order. A tick that is both a major and minor multiple appears
    ///   once, as a major.
    package static func ticks(in geometry: TimelineGeometry, day: TimelineDay,
                             zoom: TimelineZoom, clock: TimelineClock) -> [TimelineTick] {
        let window = geometry.window
        let minor = zoom.minorTickSeconds
        let major = zoom.majorTickSeconds
        guard minor > 0, major > 0, window.spanSeconds > 0 else { return [] }

        // Start at the first minor multiple at or before the window's left edge, so a major tick
        // just off-screen still contributes nothing but a tick just inside is never missed.
        let firstOffset = day.offset(of: window.start)
        var step = (firstOffset / minor).rounded(.down) * minor
        let lastOffset = day.offset(of: window.end)

        var out: [TimelineTick] = []
        // Bound the loop independently of the arithmetic. A pathological zoom/window pair — a 1 s
        // minor interval across a 24 h window, which the ladder does not offer but a deep link with a
        // hand-written span could produce — would otherwise generate 86 400 ticks and stall the main
        // thread. 4 000 is far more than the ~600 a legible ruler can hold.
        let limit = 4_000
        while step <= lastOffset, out.count < limit {
            defer { step += minor }
            guard step >= firstOffset - minor else { continue }
            let instant = day.instant(atOffset: step)
            guard window.contains(instant) else { continue }
            // Majorness is decided on the offset from midnight, not on the instant, so it is exact
            // integer arithmetic rather than a floating-point remainder of an epoch time.
            let isMajor = Self.isMultiple(step, of: major)
            out.append(TimelineTick(id: Int(step.rounded()),
                                    instant: instant,
                                    x: geometry.x(at: instant),
                                    isMajor: isMajor,
                                    label: isMajor ? zoom.labelStyle.label(instant, clock: clock)
                                                   : nil))
        }
        return out
    }

    /// Only the labelled ticks — what the ruler's text layer iterates.
    package static func majorTicks(in geometry: TimelineGeometry, day: TimelineDay,
                                  zoom: TimelineZoom, clock: TimelineClock) -> [TimelineTick] {
        ticks(in: geometry, day: day, zoom: zoom, clock: clock).filter(\.isMajor)
    }

    /// Whole minutes inside the window, for scrub magnetism (DESIGN.md §7.4 #20 lists whole minutes
    /// alongside segment boundaries and event markers).
    ///
    /// Capped at ``magnetismCandidateLimit`` because at the 24 h zoom there are 1 440 of them and the
    /// snap search is linear; beyond about a minute per two points they are also indistinguishable,
    /// so the cap costs nothing a user can perceive.
    package static func wholeMinutes(in window: TimelineWindow, day: TimelineDay) -> [Date] {
        let minute: Double = 60
        let firstOffset = day.offset(of: window.start)
        var step = (firstOffset / minute).rounded(.up) * minute
        let lastOffset = day.offset(of: window.end)
        var out: [Date] = []
        while step <= lastOffset, out.count < magnetismCandidateLimit {
            out.append(day.instant(atOffset: step))
            step += minute
        }
        return out
    }

    /// The most magnetism candidates worth considering in one window.
    package static let magnetismCandidateLimit = 256

    /// Whether `value` is an integer multiple of `interval`, tolerantly.
    ///
    /// The tolerance is 1 ms of the interval rather than an absolute epsilon: the offsets are exact
    /// multiples of the minor interval by construction, but the *division* is floating point, and a
    /// 3 600 s major against a 900 s minor must not miss because 4.0 arrived as 3.9999999999999996.
    static func isMultiple(_ value: Double, of interval: Double) -> Bool {
        guard interval > 0 else { return false }
        let ratio = value / interval
        return abs(ratio - ratio.rounded()) < 1e-6
    }
}

#endif  // os(macOS)
