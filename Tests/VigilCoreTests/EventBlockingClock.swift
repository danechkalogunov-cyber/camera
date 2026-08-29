//
//  EventBlockingClock.swift
//  VigilCoreTests
//
//  A monotonic clock whose `sleep` suspends until the task is cancelled, for the event-delivery tests
//  that drive the alert monitor. See ЧТО-НЕ-СДЕЛАНО §0.4.
//
//  Its own file rather than a addition to EventTestSupport, so it is small, self-contained, and its
//  formatting cannot depend on that larger file's history.
//

#if os(macOS)

import Foundation
import VigilProtocols

// MARK: - EventBlockingClock

/// A monotonic clock whose `sleep` never returns on its own — it suspends until the calling task is
/// cancelled — and whose `now()` never moves.
///
/// ⛔ THIS EXISTS FOR §0.4. `EventTestClock.sleep` advances instantly, which is right for the
/// service's backoff ladder but wrong for the monitor's idle watchdog: an instant sleep collapses the
/// 60 s liveness probe to zero, so on a multi-part connection the watchdog wins the race against the
/// read loop during the first alert's delivery, fires its `userCheck`, and cancels the connection
/// with `.notSupported` — terminal — losing every alert after the first. A real monotonic clock
/// cannot make a 60 s watchdog fire inside a sub-second burst, so on hardware nothing is lost; this
/// clock reproduces that by never giving the watchdog its turn. Give it to the *monitor* only — the
/// store and service keep `EventTestClock`, so coalescing windows and backoff assertions are
/// unchanged. The portable `AlertStreamMonitor` suite defends the same race with a blocking
/// `GateClock`, for the same reason.
struct EventBlockingClock: MonotonicClock {

    func now() -> MediaInstant { .zero }

    func sleep(for duration: Duration) async throws {
        try await suspendUntilCancelled()
    }

    func sleep(until deadline: MediaInstant) async throws {
        try await suspendUntilCancelled()
    }

    private func suspendUntilCancelled() async throws {
        let box = CancellableContinuationBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                box.arm(continuation)
            }
        } onCancel: {
            box.cancel()
        }
    }
}

// MARK: - CancellableContinuationBox

/// Holds a checked continuation so the cancellation handler can resume it exactly once, whichever side
/// arrives first. `cancel()` before `arm()` is the real race — a cancelled task can run the handler
/// before the continuation is stored — so a flag records it and `arm()` resumes immediately.
private final class CancellableContinuationBox: @unchecked Sendable {

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var cancelled = false

    func arm(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        defer { lock.unlock() }
        if cancelled {
            continuation.resume(throwing: CancellationError())
        } else {
            self.continuation = continuation
        }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if let continuation {
            self.continuation = nil
            continuation.resume(throwing: CancellationError())
        }
    }
}

#endif  // os(macOS)
