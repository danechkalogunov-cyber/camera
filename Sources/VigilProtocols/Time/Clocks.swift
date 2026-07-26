//
//  Clocks.swift
//  VigilProtocols
//
//  The two clock abstractions the whole app injects instead of reading time directly: `MonotonicClock`
//  for elapsed time, timeouts and scheduling, `WallClock` for display and NTP mapping only.
//  Implements docs/API_CONTRACT.md §3.2 and §2 R-07 (`VigilClock` does not exist).
//

import Foundation

// MARK: - MonotonicClock

/// Monotonic time source. The pure layer never calls this: it takes `now: MediaInstant` as a
/// parameter. Actors in `VigilTransport` / `VigilCore` / `VigilVideo` own a clock and pass its
/// readings down, which is what makes every pure state machine reproducible from a seed.
public protocol MonotonicClock: Sendable {

    /// The current reading. Successive calls never go backwards.
    func now() -> MediaInstant

    /// Cancellable sleep. Implementations MUST throw `CancellationError` on task cancellation
    /// and MUST NOT block a cooperative thread.
    func sleep(for duration: Duration) async throws

    /// Cancellable sleep until an absolute instant. Returns immediately if already past.
    func sleep(until deadline: MediaInstant) async throws
}

public extension MonotonicClock {

    /// Sleeps until `deadline`, measured on this clock.
    ///
    /// Returns without suspending — and therefore **without** a cancellation check — when the
    /// deadline has already passed, so a caller in a tight retry loop must check cancellation
    /// itself. A test clock that never advances therefore never sleeps, which is what makes
    /// deadline-driven state machines testable without wall-clock time.
    func sleep(until deadline: MediaInstant) async throws {
        let remaining = deadline - now()
        guard remaining > .zero else { return }
        try await sleep(for: remaining)
    }
}

// MARK: - WallClock

/// Wall-clock time. Used ONLY for display, for RTCP NTP mapping, and for parsed playback ranges.
/// Never for control flow, never for timeouts, never for elapsed-time measurement.
///
/// The distinction is not pedantic: wall time steps when NTP corrects it and when the user changes
/// the time zone, so a timeout measured against it can fire immediately or never.
public protocol WallClock: Sendable {

    /// The current wall-clock date. May jump forwards or backwards between two reads.
    var now: Date { get }
}

// MARK: - System implementations

/// Production clock. Uses `CLOCK_UPTIME_RAW` on Darwin and `CLOCK_MONOTONIC` on Linux, so it does
/// not advance across sleep on Darwin — which is what we want, because a camera that was
/// unreachable while the lid was shut has not been "timing out" for eight hours.
///
/// Both readings come from the stdlib's `SuspendingClock`, which is exactly those two OS clocks and
/// needs no platform import — `Darwin` and `Glibc` are both unavailable to a pure target that must
/// build on Linux and on macOS from the same source (API_CONTRACT §7.1).
///
/// `now()` is measured from a process-wide epoch captured the first time any `SystemMonotonicClock`
/// is read, so readings are small, stable for the life of the process, and comparable across every
/// instance of this type.
public struct SystemMonotonicClock: MonotonicClock {

    /// The process epoch. A `let`, initialised once on first use; never reset.
    private static let epoch = SuspendingClock.now

    public init() {}

    public func now() -> MediaInstant {
        MediaInstant(nanoseconds: (SuspendingClock.now - Self.epoch).wholeNanoseconds)
    }

    /// - Note: `Task.sleep(for:)` is a *static* suspension, not an unstructured `Task`, so this does
    ///   not breach the "no `Task` in the pure layer" rule (IMPL_RULES, API_CONTRACT §7.9). It
    ///   throws `CancellationError` when the calling task is cancelled.
    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

/// The production wall clock. The only sanctioned `Date()` call site in the pure layer: everything
/// else takes a `WallClock` (API_CONTRACT §7.6 forbids a bare `Date()` elsewhere).
public struct SystemWallClock: WallClock {

    public init() {}

    public var now: Date { Date() }
}
