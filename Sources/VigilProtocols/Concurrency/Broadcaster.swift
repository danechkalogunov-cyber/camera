//
//  Broadcaster.swift
//  VigilProtocols
//
//  One bounded source, many consumers. Every AsyncStream accessor in Vigil is a factory
//  over one of these.
//
//  Implements docs/API_CONTRACT.md §3.15 (rulings R-27, R-65, R-72).
//

import Foundation

/// Multi-consumer fan-out over one bounded source. **Every** `AsyncStream` accessor in Vigil is a
/// factory over one of these; a stored `AsyncStream` property has exactly one consumer and the
/// second caller silently gets nothing (API_CONTRACT §2 R-27, R-65).
///
/// Back-pressure is per consumer: a slow consumer drops its own oldest elements under
/// `bufferingPolicy` and never stalls the producer or its siblings. That is the right trade for
/// telemetry and state changes, and it is why frames do **not** travel through a `Broadcaster`.
public actor Broadcaster<Element: Sendable> {

    /// Registration is asynchronous — `stream()` is `nonisolated` and synchronous by contract, so
    /// it hands the continuation to the actor in a detached step. An element yielded in that
    /// window reaches consumers registered so far but not the one still registering; construct the
    /// broadcaster with `replaysLatest: true` for state-shaped elements, where the newcomer must
    /// see the current value, and accept the gap for event-shaped ones, where it cannot matter.
    private nonisolated let replaysLatest: Bool
    private nonisolated let policy: AsyncStream<Element>.Continuation.BufferingPolicy

    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    private var latest: Element?
    private var isFinished = false

    public init(replaysLatest: Bool = false,
                bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy
                    = .bufferingNewest(64)) {
        self.replaysLatest = replaysLatest
        self.policy = bufferingPolicy
    }

    /// A fresh stream, registered as a new consumer. `onTermination` deregisters.
    ///
    /// Safe to call after `finish()`: the returned stream completes immediately rather than
    /// hanging, which is what a `for await` loop started during shutdown needs.
    public nonisolated func stream() -> AsyncStream<Element> {
        AsyncStream(Element.self, bufferingPolicy: policy) { continuation in
            let id = UUID()
            continuation.onTermination = { _ in
                Task { await self.deregister(id) }
            }
            Task { await self.register(id, continuation) }
        }
    }

    /// Delivers `element` to every registered consumer.
    public func yield(_ element: Element) {
        guard !isFinished else { return }
        if replaysLatest { latest = element }
        for continuation in continuations.values {
            continuation.yield(element)
        }
    }

    /// Completes every consumer's stream. Idempotent; further `yield`s are ignored.
    public func finish() {
        guard !isFinished else { return }
        isFinished = true
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
    }

    public var consumerCount: Int { continuations.count }

    private func register(_ id: UUID, _ continuation: AsyncStream<Element>.Continuation) {
        guard !isFinished else {
            continuation.finish()
            return
        }
        continuations[id] = continuation
        if replaysLatest, let latest {
            continuation.yield(latest)
        }
    }

    private func deregister(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
