//
//  VirtualClock.swift
//  VigilTestKit
//
//  A monotonic clock whose only source of time is an explicit `advance(by:)`. It is what lets a
//  ten-minute soak run in milliseconds and what makes every timeout assertion exact rather than
//  flaky: nothing in a test ever waits.
//  Implements docs/API_CONTRACT.md §4.13 and §7.10.
//

import VigilProtocols

// MARK: - VirtualClock

/// A clock that advances only when a test says so.
///
/// `now()` is a plain read of the stored instant, so the type is a value: two copies advance
/// independently. That is deliberate — a harness that hands the same clock to two subsystems and
/// then advances one of them has a bug the compiler should not hide.
public struct VirtualClock: MonotonicClock {

    /// The current reading.
    public private(set) var instant: MediaInstant

    /// Creates a clock reading `start`, zero by default.
    public init(start: MediaInstant = .zero) {
        instant = start
    }

    /// The current reading. Never goes backwards, because ``advance(by:)`` refuses to.
    public func now() -> MediaInstant { instant }

    /// Moves the clock forward. A negative or zero duration is ignored, so a test cannot
    /// accidentally make a monotonic clock go backwards.
    public mutating func advance(by duration: Duration) {
        guard duration > .zero else { return }
        instant = instant + duration
    }

    /// Moves the clock forward by `nanoseconds`. Values at or below zero are ignored.
    public mutating func advance(nanoseconds: Int64) {
        guard nanoseconds > 0 else { return }
        instant = MediaInstant(nanoseconds: instant.nanoseconds &+ nanoseconds)
    }

    /// Returns immediately without suspending.
    ///
    /// A virtual clock has no way to make time pass on its own; anything that needs the clock to
    /// move must call ``advance(by:)``. Sleeping here instead would reintroduce exactly the
    /// wall-clock dependency this type exists to remove.
    public func sleep(for duration: Duration) async throws {}

    /// Returns immediately without suspending, for the same reason as ``sleep(for:)``.
    public func sleep(until deadline: MediaInstant) async throws {}
}
