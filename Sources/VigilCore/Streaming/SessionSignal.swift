//
//  SessionSignal.swift
//  VigilCore
//
//  A one-shot, cancellation-safe rendezvous: the byte pump, the timers and the session machine all
//  run as child tasks, and exactly one of them decides how the attempt ended.
//  Supports docs/spec-core.md §7.9 (the controller's task tree) and the R1.2 probe ladder.
//

#if os(macOS)

import Foundation
import VigilProtocols

/// Delivers the first value sent to whoever is waiting, once.
///
/// Why this exists rather than a bare `CheckedContinuation`: a continuation that is never resumed
/// leaks its task forever, and a task cancelled while awaiting one is **not** resumed by
/// cancellation. Every await here is wrapped in a cancellation handler that sends a caller-supplied
/// value instead, so a cancelled connect attempt always unwinds — which is what makes `stop()`
/// promptly stop things rather than merely intend to.
///
/// Later sends are ignored: the first outcome wins, so a socket error arriving after a `TEARDOWN`
/// completed cannot rewrite history.
actor SessionSignal<Value: Sendable> {

    private var value: Value?
    private var waiter: CheckedContinuation<Value, Never>?
    private var isSettled = false

    /// True once a value has been delivered or stored.
    var isFinished: Bool { isSettled }

    /// Delivers `newValue` to the waiter, or stores it for a waiter that has not arrived yet.
    /// Subsequent calls do nothing.
    func send(_ newValue: Value) {
        guard !isSettled else { return }
        isSettled = true
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: newValue)
        } else {
            value = newValue
        }
    }

    /// Waits for the first value.
    ///
    /// - Parameter cancelValue: what to settle on if the calling task is cancelled while waiting.
    ///   Evaluated at most once, and only on the cancellation path.
    func wait(cancelValue: @Sendable @escaping () -> Value) async -> Value {
        if let value { return value }
        if Task.isCancelled {
            let cancelled = cancelValue()
            send(cancelled)
            return cancelled
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Value, Never>) in
                if let value {
                    continuation.resume(returning: value)
                } else if isSettled {
                    // Settled with no stored value cannot happen — `send` always stores or
                    // resumes — but resuming here rather than storing a second waiter keeps the
                    // invariant "at most one waiter" true by construction.
                    continuation.resume(returning: cancelValue())
                } else {
                    waiter = continuation
                }
            }
        } onCancel: {
            Task { await self.send(cancelValue()) }
        }
    }
}

// MARK: - Deadlines

/// Runs `operation`, giving it `duration` to finish.
///
/// Returns `nil` when the deadline wins. The operation's task is cancelled at that point, so it
/// must be cancellation-safe — every await in this module either is a `SessionSignal.wait` (which
/// unwinds on cancellation) or is a plain clock sleep.
///
/// The clock is injected, so every timeout in the connect sequence is testable without waiting for
/// it (spec-core §7.4: "every timer is created from `dependencies.clock`").
func withDeadline<Value: Sendable>(_ duration: Duration,
                                   clock: any MonotonicClock,
                                   operation: @Sendable @escaping () async -> Value) async
    -> Value? {
    await withTaskGroup(of: Value?.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await clock.sleep(for: duration)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

#endif
