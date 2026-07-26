//
//  TimelineGeometry.swift
//  VigilUI
//
//  The pixel-to-time mapping of the archive scrubber, in both directions, and the hit-testing that
//  depends on it. Pure arithmetic in `Double`: no SwiftUI, no CoreGraphics, no tokens.
//  macOS-only. Implements docs/UX.md §7.3 and docs/DESIGN.md §9.14.
//
//  This is the smallest file in the module and the one most worth getting exactly right. Every
//  visible artefact of the timeline is a consequence of it: where a segment is drawn, where the
//  playhead sits, and which instant a click means. An error of a single point at the 24 h zoom is
//  72 seconds of footage, which is the difference between landing on the event the user clicked and
//  landing on the empty minute after it.
//
//  Points, not pixels. `width` is in SwiftUI points; the backing scale never enters this
//  arithmetic, because the mapping the user's pointer obeys is the layout geometry, not the
//  framebuffer. Rounding to device pixels is the drawing layer's business and is done there.
//

#if os(macOS)

import Foundation

// MARK: - TimelineGeometry

/// The mapping between a horizontal position across the bar and an instant in the archive.
///
/// A value type recomputed per layout pass rather than a cached mutable object: it holds two
/// numbers, every method is a one-line division, and a stale copy of this is precisely the bug that
/// makes a scrubber land a second off.
package struct TimelineGeometry: Sendable, Hashable {

    /// The span of time the bar covers.
    package let window: TimelineWindow

    /// The bar's width in points. Guaranteed finite and > 0 — see ``init(window:width:)``.
    package let width: Double

    /// Creates a mapping.
    ///
    /// - Parameters:
    ///   - window: the visible span.
    ///   - width: the bar's width in points. A non-finite or non-positive width is replaced by
    ///     ``degenerateWidth``, which keeps every division defined and makes the whole bar collapse
    ///     to its left edge. SwiftUI really does propose a width of zero — during the first layout
    ///     pass of a `GeometryReader`, and in a collapsed split-view column — and a NaN escaping
    ///     from here reaches a `Path` and silently blanks the entire timeline, so it is trapped at
    ///     the boundary instead of guarded at forty call sites.
    package init(window: TimelineWindow, width: Double) {
        self.window = window
        self.width = width.isFinite && width > 0 ? width : Self.degenerateWidth
    }

    /// The width substituted for a zero or nonsense proposal. Small but non-zero so that no division
    /// by it can produce an infinity.
    package static let degenerateWidth: Double = 1

    // MARK: Forward — time to position

    /// How many seconds one point of the bar represents. Always finite and > 0.
    package var secondsPerPoint: Double { window.spanSeconds / width }

    /// How many points one second occupies. Always finite and > 0.
    package var pointsPerSecond: Double { width / window.spanSeconds }

    /// The horizontal position of `instant`, in points from the bar's leading edge.
    ///
    /// Unclamped: an instant outside the window maps to a negative x or one past ``width``, which is
    /// what the segment layout needs in order to clip correctly rather than to fold an off-screen
    /// segment onto the edge.
    package func x(at instant: Date) -> Double {
        instant.timeIntervalSince(window.start) / window.spanSeconds * width
    }

    /// ``x(at:)`` clamped into `0 ... width`, for drawing something that must stay on the bar.
    package func clampedX(at instant: Date) -> Double {
        min(max(x(at: instant), 0), width)
    }

    /// The width in points of the interval `from ..< to`. Negative when `to` precedes `from`.
    package func width(from: Date, to: Date) -> Double {
        to.timeIntervalSince(from) / window.spanSeconds * width
    }

    // MARK: Inverse — position to time

    /// The instant at `x` points from the bar's leading edge.
    ///
    /// Unclamped, and exact at both ends: `instant(atX: 0)` is bit-for-bit ``TimelineWindow/start``
    /// (the offset is `0 * span`, which is exactly zero) and `instant(atX: width)` is bit-for-bit
    /// ``TimelineWindow/end`` (the ratio is `width / width`, which IEEE-754 makes exactly 1). Those
    /// two exactnesses are the ones a user can see: they are the day's first and last instant, and
    /// the ends of the bar are where a drag is most often released.
    ///
    /// In between, ``x(at:)`` and this are inverses to within a few units in the last place — about
    /// a nanosecond over a 24 h span. See ``roundTripErrorSeconds(atX:)``, and the test that pins
    /// it: the product displays centiseconds, so an error twenty-three orders of magnitude below
    /// one display tick is not a correctness question but it is worth measuring rather than
    /// assuming.
    package func instant(atX x: Double) -> Date {
        guard x.isFinite else { return window.start }
        return window.start.addingTimeInterval(x / width * window.spanSeconds)
    }

    /// ``instant(atX:)`` with `x` first clamped to the bar, so a pointer dragged beyond either edge
    /// yields the edge's instant rather than a time outside the window.
    package func clampedInstant(atX x: Double) -> Date {
        instant(atX: min(max(x.isFinite ? x : 0, 0), width))
    }

    /// The absolute round-trip error, in seconds, of `x → instant → x` at `x`, expressed back in
    /// seconds of archive time.
    ///
    /// Exposed rather than left to a test-local helper because it is the honest way to state the
    /// mapping's precision: "exactly invertible" is not a property floating-point division has, and
    /// a number a test can assert an upper bound on is worth more than the adjective.
    package func roundTripErrorSeconds(atX x: Double) -> Double {
        let there = instant(atX: x)
        let back = self.x(at: there)
        return abs(back - x) * secondsPerPoint
    }

    // MARK: Hit testing

    /// Whether `x` is within `tolerance` points of `instant` — the playhead and marker grab test.
    package func isWithin(_ tolerance: Double, ofX x: Double, instant: Date) -> Bool {
        abs(self.x(at: instant) - x) <= tolerance
    }

    /// The instant `x` means once magnetism has been applied.
    ///
    /// Snapping happens in *pixel* space, not time space, which is the only way a 6 pt tolerance can
    /// mean the same thing at the 1 min zoom and the 24 h zoom (docs/DESIGN.md §7.4 #20). At 24 h
    /// across 1 200 pt those 6 pt are seven minutes of archive; at the 1 min zoom they are 0.3 s.
    ///
    /// - Parameters:
    ///   - x: the raw pointer position in points.
    ///   - candidates: the instants worth snapping to — segment boundaries, event markers and whole
    ///     minutes. Order is irrelevant; the nearest within tolerance wins, and ties go to the
    ///     earlier instant so the result does not depend on the array's order.
    ///   - tolerance: the snap radius in points. 6 pt per DESIGN.md §7.4 #20. Pass 0 to disable,
    ///     which is what holding ⌥ does.
    /// - Returns: the snapped instant, or the unsnapped one when nothing is near enough.
    package func snappedInstant(atX x: Double, candidates: [Date],
                                tolerance: Double) -> Date {
        let raw = clampedInstant(atX: x)
        guard tolerance > 0, !candidates.isEmpty else { return raw }
        var best: Date?
        var bestDistance = Double.infinity
        for candidate in candidates {
            let distance = abs(self.x(at: candidate) - x)
            guard distance <= tolerance else { continue }
            // Strictly less, plus an explicit earlier-wins tie-break: two candidates at the same
            // distance must not resolve by array order, or a re-sorted marker list would move the
            // playhead by a frame for no reason the user can see.
            if distance < bestDistance || (distance == bestDistance && candidate < (best ?? candidate)) {
                bestDistance = distance
                best = candidate
            }
        }
        return best ?? raw
    }
}

#endif  // os(macOS)
