//
//  MediaInstant.swift
//  VigilProtocols
//
//  The one monotonic instant type in Vigil, plus the `Duration` helpers every module uses to turn a
//  stdlib duration into the nanoseconds / milliseconds / seconds a log line or a statistic wants.
//  Implements docs/API_CONTRACT.md §3.2 and §2 R-07 (`RTSPInstant`, `RTSPDuration` and
//  `MonotonicTime` do not exist).
//
//  No `import` on purpose: `Int64`, `Double` and `Duration` are all stdlib.
//

// MARK: - MediaInstant

/// A monotonic instant: nanoseconds since an arbitrary, process-stable epoch.
///
/// Never wall-clock time. Never decreases. Never wraps within any plausible uptime
/// (`Int64.max` nanoseconds is 292 years). This is the *only* monotonic instant type in Vigil:
/// `RTSPInstant`, `RTSPDuration` and `MonotonicTime` do not exist (API_CONTRACT §2 R-07).
///
/// Durations are always `Swift.Duration`, which carries its unit in the type.
///
/// Two instants may only be compared or subtracted when they came from the *same* clock. Mixing
/// origins is meaningless, and it is why the pure layer never reads a clock itself: an owning actor
/// reads one clock and passes the reading down (API_CONTRACT §7.10).
public struct MediaInstant: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {

    // MARK: - Stored Properties

    /// Nanoseconds since this clock's epoch. Comparable only against instants from the same clock.
    public var nanoseconds: Int64

    // MARK: - Initialisation

    /// Wraps a raw nanosecond reading. Every `Int64` denotes some instant, so this cannot fail.
    public init(nanoseconds: Int64) { self.nanoseconds = nanoseconds }

    /// The zero instant. Useful as a test origin; meaningless as a real time.
    public static let zero = MediaInstant(nanoseconds: 0)

    // MARK: - Computed Properties

    /// The reading in seconds. Lossy above 2^53 ns (104 days of uptime) — use it for display, never
    /// as an intermediate in an elapsed-time calculation.
    @inlinable public var seconds: Double { Double(nanoseconds) / 1e9 }

    // MARK: - Public API

    /// Seconds elapsed from `earlier` to the receiver. Negative if the receiver is earlier.
    @inlinable public func seconds(since earlier: MediaInstant) -> Double {
        Double(nanoseconds - earlier.nanoseconds) / 1e9
    }

    /// Milliseconds elapsed from `earlier`. The unit every log line and statistic uses.
    @inlinable public func milliseconds(since earlier: MediaInstant) -> Double {
        Double(nanoseconds - earlier.nanoseconds) / 1e6
    }

    // MARK: - Comparable

    @inlinable public static func < (a: Self, b: Self) -> Bool { a.nanoseconds < b.nanoseconds }

    // MARK: - Arithmetic

    /// The instant `rhs` after `lhs`. Traps only on `Int64` overflow, which needs a 292-year offset.
    @inlinable public static func + (lhs: MediaInstant, rhs: Duration) -> MediaInstant {
        MediaInstant(nanoseconds: lhs.nanoseconds + rhs.wholeNanoseconds)
    }

    /// The instant `rhs` before `lhs`.
    @inlinable public static func - (lhs: MediaInstant, rhs: Duration) -> MediaInstant {
        MediaInstant(nanoseconds: lhs.nanoseconds - rhs.wholeNanoseconds)
    }

    /// The interval between two instants. Negative when `lhs` is the earlier one.
    @inlinable public static func - (lhs: MediaInstant, rhs: MediaInstant) -> Duration {
        .nanoseconds(lhs.nanoseconds - rhs.nanoseconds)
    }

    // MARK: - CustomStringConvertible

    /// Seconds with an `s` suffix, e.g. `"1.5s"`. Diagnostic only; not a stable format.
    public var description: String { "\(seconds)s" }
}

// MARK: - Duration

public extension Duration {

    /// Total nanoseconds, saturating rather than trapping. Attoseconds below 1 ns are truncated.
    ///
    /// Truncation is toward zero, matching `Int64` division: `1.9 ns` reads as `1`, `-1.9 ns` as
    /// `-1`. A duration too large to express in `Int64` nanoseconds (over ±292 years) saturates at
    /// `Int64.max` / `Int64.min`; it never wraps to the opposite sign.
    @inlinable var wholeNanoseconds: Int64 {
        let (s, a) = components
        let fromSeconds = s.multipliedReportingOverflow(by: 1_000_000_000)
        guard !fromSeconds.overflow else { return s > 0 ? .max : .min }
        // Attoseconds carry the same sign as seconds, so the sum can only overflow outward.
        let total = fromSeconds.partialValue.addingReportingOverflow(a / 1_000_000_000)
        guard !total.overflow else { return s > 0 ? .max : .min }
        return total.partialValue
    }

    /// Total milliseconds as a `Double`. The unit every latency figure and log line uses.
    @inlinable var milliseconds: Double { Double(wholeNanoseconds) / 1e6 }

    /// Total seconds as a `Double`. Display only — never rescale a media time through this.
    @inlinable var seconds: Double { Double(wholeNanoseconds) / 1e9 }
}
