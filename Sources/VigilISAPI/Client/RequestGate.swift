//
//  RequestGate.swift
//  VigilISAPI
//
//  The per-lane permit gate: FIFO, cancellation-safe, and over-subscribable by exactly one slot for
//  PTZ and nothing else.
//  Implements docs/spec-isapi.md §4.3.
//
//  Never `DispatchSemaphore`: it blocks a cooperative thread and deadlocks the pool under Swift 6.
//  The counting is an actor-internal FIFO of continuations, which also makes cancellation exact —
//  a cancelled waiter leaves the queue immediately instead of holding a slot nobody wants.
//

import Foundation

// MARK: - RequestGate

/// A counting gate over one lane's concurrency budget.
///
/// Hikvision devices run a small HTTP worker pool: more than three concurrent control requests
/// reliably produces 503 `deviceBusy`, and on 5.4.x firmware it can stall the RTSP service for
/// seconds — so the gate is not a nicety, it is what keeps the video running while the app reads
/// configuration.
public actor RequestGate {

    /// One queued caller.
    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Bool, Never>
    }

    /// The ceiling. Never below one.
    private var limit: Int

    /// Permits currently held.
    private var held = 0

    /// Waiters in arrival order.
    private var waiters: [Waiter] = []

    /// Monotonic waiter identifier, so a cancelled waiter can be found without identity games.
    private var nextWaiterID: UInt64 = 0

    /// Creates a gate with `limit` permits.
    public init(limit: Int) {
        self.limit = Swift.max(1, limit)
    }

    /// Permits in use right now.
    public var inFlight: Int { held }

    /// Callers currently queued.
    public var queueDepth: Int { waiters.count }

    /// The ceiling in force.
    public var currentLimit: Int { limit }

    /// Changes the ceiling, admitting waiters when it rises.
    ///
    /// Lowering it never revokes a permit already held; the gate simply admits nobody new until
    /// enough come back. This is what `DeviceQuirks.maxConcurrentRequestsOverride` drives after a
    /// device answers `deviceBusy` three times in ten seconds.
    public func setLimit(_ newLimit: Int) {
        limit = Swift.max(1, newLimit)
        admitWaiters()
    }

    /// Acquires one permit, waiting in arrival order.
    ///
    /// - Parameter overSubscribeByOne: `true` only for PTZ. It raises this caller's ceiling by
    ///   exactly one slot, a documented over-subscription, because a dropped PTZ **stop** leaves a
    ///   camera spinning until someone walks over to it. Nothing else in the module passes `true`.
    /// - Throws: `CancellationError` when the calling task is cancelled while queued. A cancelled
    ///   waiter never strands a permit.
    public func acquire(overSubscribeByOne: Bool = false) async throws {
        if Task.isCancelled { throw CancellationError() }
        let ceiling = limit + (overSubscribeByOne ? 1 : 0)
        // A free permit is taken only when nobody is queued, so an arrival cannot jump the queue.
        if held < ceiling, waiters.isEmpty {
            held += 1
            return
        }
        let id = nextWaiterID
        nextWaiterID &+= 1
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            // The only `Task` in the module: `onCancel` is synchronous and non-isolated, so
            // reaching actor state to dequeue the waiter needs a hop. Spec-isapi §4.3 requires
            // exactly this behaviour.
            Task { await self.cancelWaiter(id) }
        }
        if !granted { throw CancellationError() }
    }

    /// Returns a permit, handing it straight to the next waiter when there is one.
    public func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.continuation.resume(returning: true)
        } else {
            held = Swift.max(0, held - 1)
        }
    }

    /// Runs `body` holding one permit, releasing it however `body` ends.
    public func withPermit<T: Sendable>(overSubscribeByOne: Bool = false,
                                        _ body: @Sendable () async throws -> T) async throws -> T {
        try await acquire(overSubscribeByOne: overSubscribeByOne)
        defer { release() }
        return try await body()
    }

    // MARK: Internals

    /// Removes a cancelled waiter and resumes it with a refusal.
    private func cancelWaiter(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    /// Admits queued waiters up to the ceiling.
    private func admitWaiters() {
        while held < limit, !waiters.isEmpty {
            let next = waiters.removeFirst()
            held += 1
            next.continuation.resume(returning: true)
        }
    }
}
