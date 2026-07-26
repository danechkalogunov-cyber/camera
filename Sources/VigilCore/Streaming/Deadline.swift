//
//  Deadline.swift
//  VigilCore
//
//  One helper: run something, and give up on it after a while.
//  Supports the per-state budgets of docs/spec-core.md §7.4 and the R1.2 probe's per-candidate
//  timeout.
//

#if os(macOS)

import Foundation
import VigilProtocols

/// Runs `operation`, giving it `duration` to finish.
///
/// Returns `nil` when the deadline wins. The operation's task is cancelled at that point, so it
/// must be cancellation-safe: every use in this module awaits either a socket call that honours
/// cancellation or an `AsyncStream`, which resumes with `nil` when its task is cancelled. An
/// operation that awaited a bare `CheckedContinuation` would hang here, because cancelling a task
/// does not resume one — the task group cannot return until every child has.
///
/// The clock is injected, so every timeout is testable without waiting for it (spec-core §7.4:
/// "every timer is created from `dependencies.clock`").
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
