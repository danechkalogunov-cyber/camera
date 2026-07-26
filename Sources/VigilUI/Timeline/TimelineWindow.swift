//
//  TimelineWindow.swift
//  VigilUI
//
//  The visible span of the archive scrubber: the zoom ladder, the window that slides along the day,
//  and the clamping that keeps it inside the day it belongs to.
//  macOS-only. Implements docs/UX.md §11 (playback) and docs/DESIGN.md §11.
//
//  The window is stored as (start, spanSeconds) rather than (start, end) because the zoom control
//  changes the span while holding a *focus* instant still, and that operation is far harder to get
//  right — and to test — when the span is implicit in two ends.
//

#if os(macOS)

import Foundation

// MARK: - TimelineZoom

/// The zoom ladder: the nine stops of docs/UX.md §7.3, widest first.
///
/// A ladder of named stops rather than a continuous scale, because the ruler's tick interval is a
/// function of the stop (``TimelineZoom/majorTickSeconds``) and a continuous scale would change it
/// under the user's hand mid-drag. Pinch still zooms continuously — see
/// ``TimelineWindow/zoomed(toSpanSeconds:holding:in:)`` — and snaps to a stop on release.
///
/// ⚠️ Nine stops, not six. docs/DESIGN.md §9.14 says six tiers and docs/FEATURES.md §13 says five;
/// UX.md §7.3 lists nine *and* ratifies them in its own invariant 11 ("Timeline zoom spans exactly
/// the 9 stops of §7.3"), and UX.md is the side R-34 made authoritative for structural numbers. The
/// approved mockup's `2 h` readout is on none of the three ladders — see the report; changing the
/// ladder is a one-line edit to ``allCases`` order and the three data tables below.
package enum TimelineZoom: Int, Sendable, Hashable, CaseIterable, Comparable {

    /// Stop 0 — the whole day. A *nominal* 24 h: ``TimelineWindow/clamped(to:)`` narrows it to the
    /// day's true length, which is what makes a 23-hour spring-forward day correct.
    case day

    /// Stop 1 — twelve hours.
    case twelveHours

    /// Stop 2 — six hours.
    case sixHours

    /// Stop 3 — three hours.
    case threeHours

    /// Stop 4 — one hour.
    case hour

    /// Stop 5 — thirty minutes.
    case thirtyMinutes

    /// Stop 6 — ten minutes.
    case tenMinutes

    /// Stop 7 — five minutes.
    case fiveMinutes

    /// Stop 8 — one minute. Tight enough to pick one frame out of an event.
    case minute

    /// The nominal span in seconds. UX.md §7.3, column "Visible span".
    package var spanSeconds: Double {
        switch self {
        case .day: 86_400
        case .twelveHours: 43_200
        case .sixHours: 21_600
        case .threeHours: 10_800
        case .hour: 3_600
        case .thirtyMinutes: 1_800
        case .tenMinutes: 600
        case .fiveMinutes: 300
        case .minute: 60
        }
    }

    /// Seconds between labelled (major) ticks. UX.md §7.3, column "Major tick".
    package var majorTickSeconds: Double {
        switch self {
        case .day: 3_600
        case .twelveHours: 3_600
        case .sixHours: 1_800
        case .threeHours: 900
        case .hour: 600
        case .thirtyMinutes: 300
        case .tenMinutes: 60
        case .fiveMinutes: 30
        case .minute: 10
        }
    }

    /// Seconds between unlabelled (minor) ticks. UX.md §7.3, column "Minor tick".
    package var minorTickSeconds: Double {
        switch self {
        case .day: 900
        case .twelveHours: 900
        case .sixHours: 600
        case .threeHours: 300
        case .hour: 60
        case .thirtyMinutes: 60
        case .tenMinutes: 15
        case .fiveMinutes: 10
        case .minute: 1
        }
    }

    /// How much of the clock a major tick's label spells out. UX.md §7.3, column "Label format".
    package var labelStyle: TimelineTickLabelStyle {
        switch self {
        case .day: .hour
        case .twelveHours, .sixHours, .threeHours, .hour, .thirtyMinutes, .tenMinutes: .hourMinute
        case .fiveMinutes: .hourMinuteSecond
        case .minute: .minuteSecond
        }
    }

    /// The span as a `Duration`, which is what makes the readout localisable.
    package var duration: Duration { .seconds(spanSeconds) }

    /// Whether this stop reads more naturally in minutes than in hours.
    var prefersMinutes: Bool { spanSeconds < 3_600 }

    /// The readout beside the zoom control, localised: `"24h"` in English, `"24 ч"` in Russian,
    /// `"30 мин"` for the half-hour stop.
    ///
    /// Localised through `Duration.UnitsFormatStyle` rather than through nine `.strings` keys. Two
    /// reasons for that choice over returning a `LocalizedStringKey`:
    ///
    /// * The unit abbreviation for a duration is precisely what this format style exists to produce,
    ///   and it is already correct for every locale — including ones this product does not yet ship —
    ///   whereas nine hand-written keys would need a translator per locale and would silently fall
    ///   back to English `h` and `m` until they arrived.
    /// * It keeps this file free of SwiftUI, so ``TimelineZoom`` stays a plain value whose label a
    ///   test can assert as a `String`. A `LocalizedStringKey` return type would make the label
    ///   opaque to the tests that check the ladder.
    ///
    /// The `.narrow` width is what fits the compact control beside the zoom slider; `.abbreviated`
    /// yields `"24 hrs"`, which does not.
    ///
    /// - Parameter locale: the locale to format in. Injected, never read from the environment here —
    ///   ``TimelineClock/zoomLabel(_:)`` is the call site that supplies it.
    package func label(locale: Locale) -> String {
        var style = Duration.UnitsFormatStyle(allowedUnits: prefersMinutes ? [.minutes] : [.hours],
                                              width: .narrow)
        style.locale = locale
        return duration.formatted(style)
    }

    /// The tightest zoom.
    package static let tightest = TimelineZoom.minute

    /// The widest zoom.
    package static let widest = TimelineZoom.day

    /// One stop tighter (a shorter span), or `self` when already tightest.
    ///
    /// Note the direction: stop 0 is the *widest*, so tightening increments the raw value. The two
    /// accessors exist precisely so no caller has to remember that.
    package var tighter: TimelineZoom {
        TimelineZoom(rawValue: rawValue + 1) ?? self
    }

    /// One stop wider (a longer span), or `self` when already widest.
    package var wider: TimelineZoom {
        TimelineZoom(rawValue: rawValue - 1) ?? self
    }

    /// Ordered by span, so `<` means "shows less time". Deliberately *not* the raw order, which runs
    /// the other way and would make `zoom < .hour` read as its own opposite at a call site.
    package static func < (a: Self, b: Self) -> Bool { a.spanSeconds < b.spanSeconds }

    /// The zoom whose span is nearest to `seconds`.
    ///
    /// Used when a window's span was clamped to a short day and the control has to show *something*
    /// — and by the pinch gesture, which produces a continuous span the ladder has to round.
    /// Nearest in log space, because the ladder is geometric: 900 s is as far from 3 600 s as
    /// 3 600 s is from 14 400 s to a user's eye, and linear nearest would bias every choice wide.
    package static func nearest(toSpanSeconds seconds: Double) -> TimelineZoom {
        guard seconds > 0 else { return .tightest }
        var best = TimelineZoom.tightest
        var bestDistance = Double.infinity
        for candidate in TimelineZoom.allCases {
            let distance = abs(log(candidate.spanSeconds) - log(seconds))
            if distance < bestDistance {
                bestDistance = distance
                best = candidate
            }
        }
        return best
    }
}

// MARK: - TimelineWindow

/// The visible slice of the day, as a start instant and a span.
///
/// Kept clamped inside one ``TimelineDay`` by ``clamped(to:)``: the archive bar shows one day at a
/// time — that is what the date navigator and the month calendar are for — so a window that could
/// drift into yesterday would show footage the day's own segment list does not contain.
package struct TimelineWindow: Sendable, Hashable {

    /// The instant at the left-hand edge of the bar.
    package var start: Date

    /// The span the bar covers, in seconds. Always > 0.
    package var spanSeconds: Double

    /// Creates a window. `spanSeconds` is floored at ``minimumSpanSeconds``, because a zero or
    /// negative span would make every pixel-to-time division a NaN and paint an empty bar with no
    /// diagnosis.
    package init(start: Date, spanSeconds: Double) {
        self.start = start
        self.spanSeconds = spanSeconds.isFinite
            ? max(Self.minimumSpanSeconds, spanSeconds)
            : TimelineZoom.hour.spanSeconds
    }

    /// Creates a window at a zoom stop, using the stop's *nominal* span.
    ///
    /// For every stop but ``TimelineZoom/day`` the nominal span is the real one. For `.day` prefer
    /// ``fitting(_:zoom:)``, which resolves the nominal 24 h to the day's true length.
    package init(start: Date, zoom: TimelineZoom) {
        self.init(start: start, spanSeconds: zoom.spanSeconds)
    }

    /// The window for `zoom` over `day`, anchored at `focus` and clamped inside the day.
    ///
    /// This is the constructor the zoom control and `⌘0` ("Fit the day") should use, because it is the
    /// one that gets a DST day right in **both** directions. ``clamped(to:)`` can only narrow a window;
    /// it cannot know that a 86 400 s span came from the `.day` stop and therefore means "all of it"
    /// rather than "exactly 24 hours".
    ///
    /// The distinction is not academic. On the 25-hour autumn-back day the `.day` stop's nominal
    /// 86 400 s is an hour *short*, so a bar built from the nominal span would leave the day's last
    /// hour of footage off the right-hand edge — reachable only by scrolling, from a control whose
    /// label says it is showing the whole day. A test caught exactly that.
    ///
    /// - Parameters:
    ///   - day: the day to fit inside.
    ///   - zoom: the stop. `.day` resolves to ``TimelineDay/spanSeconds``, whatever that is.
    ///   - focus: the instant to keep visible, centred where the span allows. Defaults to the day's
    ///     start.
    package static func fitting(_ day: TimelineDay, zoom: TimelineZoom,
                                focus: Date? = nil) -> TimelineWindow {
        let span = zoom == .day ? day.spanSeconds : zoom.spanSeconds
        guard let focus else {
            return TimelineWindow(start: day.start, spanSeconds: span).clamped(to: day)
        }
        return TimelineWindow(start: day.start, spanSeconds: span).centred(on: focus, in: day)
    }

    /// The narrowest window the arithmetic will represent: one second across the whole bar.
    ///
    /// Below this, a bar 1 200 pt wide would give more than a thousand points to a single second and
    /// the ruler would have no legible interval left to draw.
    package static let minimumSpanSeconds: Double = 1

    /// The instant at the right-hand edge. Exclusive, matching every other range here.
    package var end: Date { start.addingTimeInterval(spanSeconds) }

    /// Whether `instant` is visible in this window. Half-open.
    package func contains(_ instant: Date) -> Bool {
        instant >= start && instant < end
    }

    /// Whether any part of `range` is visible.
    ///
    /// Two half-open ranges overlap when each starts before the other ends. A segment that ends
    /// exactly at ``start`` is *not* visible, which is the correct half-open answer and the reason
    /// the bar does not paint a zero-width sliver at its left edge.
    package func intersects(from: Date, to: Date) -> Bool {
        from < end && to > start
    }

    // MARK: Clamping

    /// This window moved and, if necessary, narrowed so that it lies inside `day`.
    ///
    /// Three cases, in this order:
    ///
    /// 1. The span is at least as long as the day — including the nominal-24 h zoom on a 23-hour
    ///    spring-forward day, which is exactly why this case is first. The window becomes the whole
    ///    day, span and all. Without this, the `.day` zoom on a 23-hour day would show one hour of
    ///    the *next* day, and every segment would be drawn 4.3 % too far left.
    /// 2. The window hangs off the right-hand end: slide it left so it ends at the day's end.
    /// 3. The window starts before the day: slide it right to the day's start.
    ///
    /// ⚠️ This only ever **narrows**. A 24-hour window on a 25-hour day keeps its 24 hours and becomes
    /// scrollable by one hour, which is the right answer for a span the caller genuinely asked for.
    /// It is the wrong answer for the `.day` *stop*, whose meaning is "all of it" — use
    /// ``fitting(_:zoom:focus:)`` for that.
    package func clamped(to day: TimelineDay) -> TimelineWindow {
        let daySpan = day.spanSeconds
        guard daySpan > 0 else { return TimelineWindow(start: day.start, spanSeconds: spanSeconds) }
        if spanSeconds >= daySpan {
            return TimelineWindow(start: day.start, spanSeconds: daySpan)
        }
        let latestStart = day.end.addingTimeInterval(-spanSeconds)
        let clampedStart = min(max(start, day.start), latestStart)
        return TimelineWindow(start: clampedStart, spanSeconds: spanSeconds)
    }

    /// This window scrolled by `seconds`, then clamped into `day`.
    package func scrolled(bySeconds seconds: Double, in day: TimelineDay) -> TimelineWindow {
        guard seconds.isFinite else { return clamped(to: day) }
        return TimelineWindow(start: start.addingTimeInterval(seconds),
                              spanSeconds: spanSeconds).clamped(to: day)
    }

    /// This window scrolled by a fraction of its own span — what a trackpad swipe and the ‹ › keys
    /// produce. `+1` scrolls forward by exactly one screenful.
    package func scrolled(byFractionOfSpan fraction: Double, in day: TimelineDay) -> TimelineWindow {
        scrolled(bySeconds: fraction * spanSeconds, in: day)
    }

    // MARK: Zooming

    /// This window re-spanned to `zoom` while holding `focus` at the same *fractional* position
    /// across the bar, then clamped into `day`.
    ///
    /// Holding the fraction rather than the pixel is what makes zooming feel anchored: the instant
    /// under the pointer — or under the playhead, when the keyboard zooms — stays under it. When
    /// `focus` is outside the current window the fraction is clamped to `0...1`, so a zoom driven
    /// from a playhead that has scrolled out of view still lands somewhere sensible instead of
    /// throwing the window across the day.
    package func zoomed(to zoom: TimelineZoom, holding focus: Date,
                        in day: TimelineDay) -> TimelineWindow {
        zoomed(toSpanSeconds: zoom.spanSeconds, holding: focus, in: day)
    }

    /// The continuous form of ``zoomed(to:holding:in:)``, for a pinch gesture.
    package func zoomed(toSpanSeconds newSpan: Double, holding focus: Date,
                        in day: TimelineDay) -> TimelineWindow {
        guard newSpan.isFinite, newSpan > 0, spanSeconds > 0 else { return clamped(to: day) }
        let rawFraction = focus.timeIntervalSince(start) / spanSeconds
        let fraction = rawFraction.isFinite ? min(1, max(0, rawFraction)) : 0.5
        let newStart = focus.addingTimeInterval(-fraction * newSpan)
        return TimelineWindow(start: newStart, spanSeconds: newSpan).clamped(to: day)
    }

    /// This window re-spanned so `instant` sits at its centre, then clamped into `day`.
    ///
    /// What "follow the playhead" uses. The clamp means the playhead stops being centred near
    /// either end of the day, which is correct — the alternative is empty bar beyond midnight.
    package func centred(on instant: Date, in day: TimelineDay) -> TimelineWindow {
        TimelineWindow(start: instant.addingTimeInterval(-spanSeconds / 2),
                       spanSeconds: spanSeconds).clamped(to: day)
    }

    /// Whether `instant` lies within the middle `keepFraction` of the window.
    ///
    /// The follow-the-playhead rule: while the playhead is comfortably inside the bar the window
    /// stays put, and it is only re-centred when the playhead reaches the outer margin. Scrolling
    /// on every frame instead would make the whole bar creep continuously under a still pointer,
    /// which is both distracting and impossible to click on.
    package func isComfortablyInside(_ instant: Date, keepFraction: Double = 0.8) -> Bool {
        guard spanSeconds > 0 else { return false }
        let keep = min(1, max(0, keepFraction))
        let margin = spanSeconds * (1 - keep) / 2
        return instant >= start.addingTimeInterval(margin)
            && instant <= end.addingTimeInterval(-margin)
    }
}

#endif  // os(macOS)
