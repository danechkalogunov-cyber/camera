//
//  ConcurrencyLimiter.swift
//  VigilProtocols
//
//  FIFO, priority-aware permit gate. The replacement for DispatchSemaphore, which blocks
//  a cooperative thread and deadlocks the pool under Swift 6.
//
//  Implements docs/API_CONTRACT.md §3.15 (ruling R-72).
//

/// FIFO, priority-aware, cancellation-safe permit gate. Never `DispatchSemaphore`, which blocks a
/// cooperative thread and deadlocks the pool under Swift 6.
///
/// Waiters are served highest `StreamPriority` first and, within a priority, in arrival order — so
/// a burst of sidebar thumbnails cannot delay the focused tile, and no waiter at a given priority
/// can be overtaken by a later one at the same priority.
public actor ConcurrencyLimiter {

    private struct Waiter {
        let id: UInt64
        let priority: StreamPriority
        let continuation: CheckedContinuation<Bool, Never>
    }

    /// Identifies the gate in log lines and in the diagnostics bundle.
    public nonisolated let name: String

    private var limit: Int
    private var inFlightCount = 0
    private var waiters: [Waiter] = []
    private var nextWaiterID: UInt64 = 0

    /// `limit` below 1 is clamped to 1: a gate that admits nobody is a deadlock, and this is
    /// configuration, not a programming error worth trapping on.
    public init(limit: Int, name: String) {
        self.limit = Swift.max(1, limit)
        self.name = name
    }

    /// Runs `body` holding one permit, releasing it however `body` ends.
    ///
    /// **Cancellation.** A task cancelled while queued leaves the queue at once and runs `body`
    /// *without* a permit, so it can observe `Task.isCancelled` and return immediately instead of
    /// waiting behind work it is no longer interested in. The permit count is never exceeded and a
    /// cancelled waiter never strands one. Callers whose `body` ignores cancellation should check
    /// `Task.isCancelled` themselves before doing real work.
    public func withPermit<T: Sendable>(priority: StreamPriority = .visibleSmall,
                                        _ body: @Sendable () async throws -> T) async rethrows -> T {
        let granted = await acquire(priority: priority)
        defer { if granted { release() } }
        return try await body()
    }

    /// Changes the ceiling, waking waiters if it was raised. Lowering it never revokes a permit
    /// already held; the gate simply admits nobody new until enough are returned.
    public func setLimit(_ limit: Int) {
        self.limit = Swift.max(1, limit)
        while inFlightCount < self.limit, !waiters.isEmpty {
            let next = waiters.removeFirst()
            inFlightCount += 1
            next.continuation.resume(returning: true)
        }
    }

    /// Permits currently held.
    public var inFlight: Int { inFlightCount }

    /// Tasks waiting for a permit.
    public var queueDepth: Int { waiters.count }

    /// The ceiling in force right now.
    public var currentLimit: Int { limit }

    // MARK: - Internals

    private func acquire(priority: StreamPriority) async -> Bool {
        if Task.isCancelled { return false }
        // A free permit is taken only when nobody is queued, so an arriving low-priority caller
        // cannot jump a queue that is already forming.
        if inFlightCount < limit, waiters.isEmpty {
            inFlightCount += 1
            return true
        }
        let id = nextWaiterID
        nextWaiterID += 1
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                enqueue(Waiter(id: id, priority: priority, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Inserts after every waiter of equal or higher priority, which is priority order with FIFO
    /// within a priority.
    private func enqueue(_ waiter: Waiter) {
        var index = waiters.count
        while index > 0, waiters[index - 1].priority < waiter.priority {
            index -= 1
        }
        waiters.insert(waiter, at: index)
    }

    private func cancelWaiter(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    /// Hands the permit straight to the next waiter rather than returning it to the pool, so a
    /// steady stream of arrivals cannot starve the queue.
    private func release() {
        if waiters.isEmpty {
            inFlightCount -= 1
        } else {
            let next = waiters.removeFirst()
            next.continuation.resume(returning: true)
        }
    }
}
